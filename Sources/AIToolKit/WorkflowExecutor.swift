import Foundation

public struct WorkflowExecutionContext: Sendable {
    public var toolContext: ToolContext
    public var context: JSONValue
    public var userInput: JSONValue

    public init(
        toolContext: ToolContext = ToolContext(),
        context: JSONValue = .object([:]),
        userInput: JSONValue = .object([:])
    ) {
        self.toolContext = toolContext
        self.context = context
        self.userInput = userInput
    }
}

public struct WorkflowExecutor: Sendable {
    public typealias Dispatch = @Sendable (
        _ node: WorkflowNode,
        _ resolvedInput: JSONValue,
        _ context: WorkflowExecutionContext
    ) async throws -> JSONValue

    public var dispatch: Dispatch

    public init(dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    public init(registry: ToolRegistry) {
        self.dispatch = { node, input, context in
            guard let tool = node.tool else {
                throw WorkflowError.missingTool(nodeID: node.id)
            }
            return try await registry.call(
                ToolCall(id: "workflow-\(node.id)", name: tool, input: input),
                context: context.toolContext
            )
        }
    }

    public func execute(
        _ validated: ValidatedWorkflow,
        context: WorkflowExecutionContext = WorkflowExecutionContext()
    ) async throws -> WorkflowResult {
        let spec = validated.spec
        guard spec.mode == .execute else {
            if spec.mode == .needsClarification || spec.mode == .unsupported {
                let rendered = try WorkflowFinalRenderer.render(
                    spec.final,
                    outputs: [:],
                    context: context.context,
                    userInput: context.userInput
                )
                return WorkflowResult(
                    workflowID: spec.workflowID,
                    mode: spec.mode,
                    finalValue: rendered.value,
                    finalText: rendered.text,
                    nodeOutputs: [:],
                    trace: WorkflowTrace(
                        workflowID: spec.workflowID,
                        startedAt: Date(),
                        endedAt: Date()
                    )
                )
            }
            throw WorkflowError.executionSkipped(mode: spec.mode)
        }

        let store = WorkflowResultStore()
        var trace = WorkflowTrace(workflowID: spec.workflowID)
        for level in validated.levels {
            try Task.checkCancellation()
            for chunk in chunks(level, size: max(1, spec.limits.maxParallelism)) {
                let snapshot = await store.snapshot()
                let results = try await runChunk(
                    chunk,
                    snapshot: snapshot,
                    context: context
                )
                for result in results {
                    await store.set(result.output, for: result.node.id)
                    trace.nodes.append(result.trace)
                }
            }
        }

        let outputs = await store.snapshot()
        let rendered = try WorkflowFinalRenderer.render(
            spec.final,
            outputs: outputs,
            context: context.context,
            userInput: context.userInput
        )
        trace.endedAt = Date()
        return WorkflowResult(
            workflowID: spec.workflowID,
            mode: spec.mode,
            finalValue: rendered.value,
            finalText: rendered.text,
            nodeOutputs: outputs,
            trace: trace
        )
    }

    private struct NodeRunResult: Sendable {
        let node: WorkflowNode
        let output: JSONValue
        let trace: WorkflowNodeTrace
    }

    private func runChunk(
        _ nodes: [WorkflowNode],
        snapshot: [String: JSONValue],
        context: WorkflowExecutionContext
    ) async throws -> [NodeRunResult] {
        try await withThrowingTaskGroup(of: NodeRunResult.self) { group in
            for node in nodes {
                group.addTask {
                    try await runNode(node, snapshot: snapshot, context: context)
                }
            }
            var results: [NodeRunResult] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.node.id < $1.node.id }
        }
    }

    private func runNode(
        _ node: WorkflowNode,
        snapshot: [String: JSONValue],
        context: WorkflowExecutionContext
    ) async throws -> NodeRunResult {
        let started = Date()
        let resolvedInput = try WorkflowReferenceResolver.resolve(
            node.input,
            outputs: snapshot,
            context: context.context,
            userInput: context.userInput,
            currentNodeID: node.id
        )

        let maxAttempts = max(1, node.policy.retry.maxAttempts)
        var attempts = 0
        var lastError: (any Error)?
        while attempts < maxAttempts {
            attempts += 1
            do {
                try Task.checkCancellation()
                let output = try await dispatch(node, resolvedInput, context)
                try validateOutputSize(output, node: node)
                return NodeRunResult(
                    node: node,
                    output: node.outputPolicy.store ? output : .null,
                    trace: WorkflowNodeTrace(
                        nodeID: node.id,
                        tool: node.tool,
                        status: .succeeded,
                        attempts: attempts,
                        startedAt: started,
                        endedAt: Date()
                    )
                )
            } catch {
                lastError = error
                guard attempts < maxAttempts, shouldRetry(error, policy: node.policy.retry)
                else { break }
                if node.policy.retry.backoffMS > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(node.policy.retry.backoffMS) * 1_000_000
                    )
                }
            }
        }

        switch node.policy.onError {
        case .continueWithNull:
            return NodeRunResult(
                node: node,
                output: .null,
                trace: failedTrace(node: node, attempts: attempts, started: started, error: lastError)
            )
        case .continueWithDefault:
            if let defaultOutput = node.policy.defaultOutput {
                return NodeRunResult(
                    node: node,
                    output: defaultOutput,
                    trace: failedTrace(node: node, attempts: attempts, started: started, error: lastError)
                )
            }
            fallthrough
        case .abort, .skipDependents:
            throw WorkflowError.nodeFailed(
                nodeID: node.id,
                message: lastError.map { String(describing: $0) } ?? "unknown"
            )
        }
    }

    private func failedTrace(
        node: WorkflowNode,
        attempts: Int,
        started: Date,
        error: (any Error)?
    ) -> WorkflowNodeTrace {
        WorkflowNodeTrace(
            nodeID: node.id,
            tool: node.tool,
            status: .failedTerminal,
            attempts: attempts,
            startedAt: started,
            endedAt: Date(),
            error: error.map { String(describing: $0) }
        )
    }

    private func shouldRetry(_ error: any Error, policy: WorkflowRetryPolicy) -> Bool {
        if !policy.retryOnlyIfToolErrorIsRetriable { return true }
        return (error as? any ToolError)?.isRetriable == true
    }

    private func validateOutputSize(_ output: JSONValue, node: WorkflowNode) throws {
        let bytes = (try? output.data().count) ?? 0
        guard bytes <= node.outputPolicy.maxBytes else {
            throw WorkflowError.outputLimitExceeded(
                nodeID: node.id,
                bytes: bytes,
                limit: node.outputPolicy.maxBytes
            )
        }
    }

    private func chunks(_ values: [WorkflowNode], size: Int) -> [[WorkflowNode]] {
        stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }
}
