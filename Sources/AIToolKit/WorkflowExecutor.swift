import Foundation
import FoundationModels

public struct WorkflowExecutionContext: Sendable {
    public var context: GeneratedContent
    public var userInput: GeneratedContent

    public init(
        context: GeneratedContent = .object([:]),
        userInput: GeneratedContent = .object([:])
    ) {
        self.context = context
        self.userInput = userInput
    }
}

public struct WorkflowExecutor: Sendable {
    public typealias Dispatch = @Sendable (
        _ node: WorkflowNode,
        _ resolvedInput: GeneratedContent,
        _ context: WorkflowExecutionContext
    ) async throws -> GeneratedContent

    public var dispatch: Dispatch

    public init(dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    /// Dispatches workflow nodes by name to official FoundationModels tools —
    /// the same `[any Tool]` currency a `LanguageModelSession` takes. With
    /// duplicate names, the first tool wins.
    public init(tools: [any Tool]) {
        let toolsByName: [String: any Tool] = Dictionary(
            tools.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.dispatch = { node, input, _ in
            guard let name = node.tool else {
                throw WorkflowError.missingTool(nodeID: node.id)
            }
            guard let tool = toolsByName[name] else {
                throw WorkflowError.unavailableTool(nodeID: node.id, tool: name)
            }
            return try await WorkflowExecutor.callTool(tool, with: input)
        }
    }

    /// Runs one official tool with `GeneratedContent` arguments: opens the
    /// existential, performs the strict typed-argument decode (a mismatched
    /// input fails here, before the tool runs), and re-encodes the output so
    /// later nodes can `$ref` into it. The output must convert to
    /// `GeneratedContent` — every `Generable` output (including `String` and
    /// other standard types) qualifies; a prompt-only output is rejected
    /// because it cannot be wired into a DAG.
    public static func callTool<T: Tool>(
        _ tool: T,
        with input: GeneratedContent
    ) async throws -> GeneratedContent {
        let arguments: T.Arguments
        do {
            arguments = try T.Arguments(input)
        } catch {
            throw GenericToolError(
                message: "Arguments for tool \(tool.name) failed to decode: \(error)"
            )
        }
        let output = try await tool.call(arguments: arguments)
        guard let convertible = output as? any ConvertibleToGeneratedContent else {
            throw GenericToolError(
                message: """
                Output of tool \(tool.name) does not convert to GeneratedContent; \
                workflow node tools need structured (Generable) outputs.
                """
            )
        }
        return convertible.generatedContent
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
        let workflowDeadline = ContinuousClock.now.advanced(
            by: .milliseconds(spec.limits.deadlineMS)
        )
        var skipped = Set<String>()
        for level in validated.levels {
            try Task.checkCancellation()
            try checkWorkflowDeadline(workflowDeadline, spec: spec)
            for chunk in chunks(level, size: max(1, spec.limits.maxParallelism)) {
                let runnable = chunk.filter {
                    (validated.dependencies[$0.id] ?? []).isDisjoint(with: skipped)
                }
                let skippedNodes = chunk.filter { node in
                    !((validated.dependencies[node.id] ?? []).isDisjoint(with: skipped))
                }
                for node in skippedNodes {
                    skipped.insert(node.id)
                    trace.nodes.append(WorkflowNodeTrace(
                        nodeID: node.id,
                        tool: node.tool,
                        status: .skipped,
                        endedAt: Date(),
                        error: "Skipped because a dependency was skipped."
                    ))
                }
                guard !runnable.isEmpty else { continue }
                let snapshot = await store.snapshot()
                let results = try await runChunk(
                    runnable,
                    snapshot: snapshot,
                    context: context,
                    descriptors: validated.descriptors,
                    workflowDeadline: workflowDeadline,
                    workflowDeadlineMS: spec.limits.deadlineMS
                )
                for result in results {
                    await store.set(result.output, for: result.node.id)
                    trace.nodes.append(result.trace)
                    if result.skipDependents {
                        skipped.insert(result.node.id)
                    }
                }
            }
        }

        let outputs = await store.snapshot()
        let exposedOutputs: [String: GeneratedContent] = Dictionary(
            uniqueKeysWithValues: outputs.compactMap { id, output -> (String, GeneratedContent)? in
            guard spec.nodes.first(where: { $0.id == id })?.outputPolicy.exposeToFinal == true
            else { return nil }
            return (id, output)
            }
        )
        let rendered = try WorkflowFinalRenderer.render(
            spec.final,
            outputs: exposedOutputs,
            context: context.context,
            userInput: context.userInput
        )
        trace.endedAt = Date()
        return WorkflowResult(
            workflowID: spec.workflowID,
            mode: spec.mode,
            finalValue: rendered.value,
            finalText: rendered.text,
            nodeOutputs: exposedOutputs,
            trace: trace
        )
    }

    private struct NodeRunResult: Sendable {
        let node: WorkflowNode
        let output: GeneratedContent
        let trace: WorkflowNodeTrace
        let skipDependents: Bool
    }

    private func runChunk(
        _ nodes: [WorkflowNode],
        snapshot: [String: GeneratedContent],
        context: WorkflowExecutionContext,
        descriptors: [String: ToolDescriptor],
        workflowDeadline: ContinuousClock.Instant,
        workflowDeadlineMS: Int
    ) async throws -> [NodeRunResult] {
        try await withThrowingTaskGroup(of: NodeRunResult.self) { group in
            for node in nodes {
                group.addTask {
                    try await runNode(
                        node,
                        snapshot: snapshot,
                        context: context,
                        descriptors: descriptors,
                        workflowDeadline: workflowDeadline,
                        workflowDeadlineMS: workflowDeadlineMS
                    )
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
        snapshot: [String: GeneratedContent],
        context: WorkflowExecutionContext,
        descriptors: [String: ToolDescriptor],
        workflowDeadline: ContinuousClock.Instant,
        workflowDeadlineMS: Int
    ) async throws -> NodeRunResult {
        let started = Date()
        try checkWorkflowDeadline(workflowDeadline, specDeadlineMS: workflowDeadlineMS)
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
                try checkWorkflowDeadline(workflowDeadline, specDeadlineMS: workflowDeadlineMS)
                let output = try await withNodeTimeout(
                    node,
                    workflowDeadline: workflowDeadline,
                    workflowDeadlineMS: workflowDeadlineMS
                ) {
                    try await dispatch(node, resolvedInput, context)
                }
                try validateOutputSize(output, node: node)
                return NodeRunResult(
                    node: node,
                    output: node.outputPolicy.store ? output : .nullContent,
                    trace: WorkflowNodeTrace(
                        nodeID: node.id,
                        tool: node.tool,
                        status: .succeeded,
                        attempts: attempts,
                        startedAt: started,
                        endedAt: Date()
                    ),
                    skipDependents: false
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
                output: .nullContent,
                trace: failedTrace(node: node, attempts: attempts, started: started, error: lastError),
                skipDependents: false
            )
        case .continueWithDefault:
            if let defaultOutput = node.policy.defaultOutput {
                return NodeRunResult(
                    node: node,
                    output: defaultOutput,
                    trace: failedTrace(node: node, attempts: attempts, started: started, error: lastError),
                    skipDependents: false
                )
            }
            fallthrough
        case .skipDependents:
            return NodeRunResult(
                node: node,
                output: .nullContent,
                trace: failedTrace(node: node, attempts: attempts, started: started, error: lastError),
                skipDependents: true
            )
        case .abort:
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

    private func validateOutputSize(_ output: GeneratedContent, node: WorkflowNode) throws {
        let bytes = output.jsonString.utf8.count
        guard bytes <= node.outputPolicy.maxBytes else {
            throw WorkflowError.outputLimitExceeded(
                nodeID: node.id,
                bytes: bytes,
                limit: node.outputPolicy.maxBytes
            )
        }
    }

    private func checkWorkflowDeadline(
        _ deadline: ContinuousClock.Instant,
        spec: WorkflowSpec
    ) throws {
        try checkWorkflowDeadline(deadline, specDeadlineMS: spec.limits.deadlineMS)
    }

    private func checkWorkflowDeadline(
        _ deadline: ContinuousClock.Instant,
        specDeadlineMS: Int
    ) throws {
        if ContinuousClock.now >= deadline {
            throw WorkflowError.workflowTimedOut(deadlineMS: specDeadlineMS)
        }
    }

    private func withNodeTimeout<T: Sendable>(
        _ node: WorkflowNode,
        workflowDeadline: ContinuousClock.Instant,
        workflowDeadlineMS: Int,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let now = ContinuousClock.now
        let nodeDeadline: ContinuousClock.Instant?
        if node.policy.timeoutMS > 0 {
            nodeDeadline = now.advanced(by: .milliseconds(node.policy.timeoutMS))
        } else {
            nodeDeadline = nil
        }
        let deadline = nodeDeadline.map { min($0, workflowDeadline) } ?? workflowDeadline
        let isWorkflowDeadline = deadline == workflowDeadline
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
                if isWorkflowDeadline {
                    throw WorkflowError.workflowTimedOut(deadlineMS: workflowDeadlineMS)
                }
                throw WorkflowError.nodeTimedOut(
                    nodeID: node.id,
                    timeoutMS: node.policy.timeoutMS
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WorkflowError.nodeTimedOut(
                    nodeID: node.id,
                    timeoutMS: node.policy.timeoutMS
                )
            }
            return result
        }
    }

    private func chunks(_ values: [WorkflowNode], size: Int) -> [[WorkflowNode]] {
        stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }
}
