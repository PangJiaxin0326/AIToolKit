import Foundation
import FoundationModels

public struct WorkflowValidationPolicy: Sendable {
    public var availableTools: Set<String>
    public var descriptors: [String: ToolDescriptor]
    public var maxNodes: Int
    public var maxParallelism: Int
    public var maxDeadlineMS: Int
    public var maxOutputBytesPerNode: Int
    public var allowApprovalRequiredTools: Bool

    public init(
        availableTools: Set<String>,
        descriptors: [String: ToolDescriptor] = [:],
        maxNodes: Int = 24,
        maxParallelism: Int = 8,
        maxDeadlineMS: Int = 60_000,
        maxOutputBytesPerNode: Int = 262_144,
        allowApprovalRequiredTools: Bool = false
    ) {
        self.availableTools = availableTools
        self.descriptors = descriptors
        self.maxNodes = maxNodes
        self.maxParallelism = maxParallelism
        self.maxDeadlineMS = maxDeadlineMS
        self.maxOutputBytesPerNode = maxOutputBytesPerNode
        self.allowApprovalRequiredTools = allowApprovalRequiredTools
    }

    public init(
        descriptors: [ToolDescriptor],
        maxNodes: Int = 24,
        maxParallelism: Int = 8,
        maxDeadlineMS: Int = 60_000,
        maxOutputBytesPerNode: Int = 262_144,
        allowApprovalRequiredTools: Bool = false
    ) {
        self.init(
            availableTools: Set(descriptors.map(\.name)),
            descriptors: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) }),
            maxNodes: maxNodes,
            maxParallelism: maxParallelism,
            maxDeadlineMS: maxDeadlineMS,
            maxOutputBytesPerNode: maxOutputBytesPerNode,
            allowApprovalRequiredTools: allowApprovalRequiredTools
        )
    }
}

public struct ValidatedWorkflow: Sendable {
    public var spec: WorkflowSpec
    public var dependencies: [String: Set<String>]
    public var levels: [[WorkflowNode]]
    public var descriptors: [String: ToolDescriptor]

    public init(
        spec: WorkflowSpec,
        dependencies: [String: Set<String>],
        levels: [[WorkflowNode]],
        descriptors: [String: ToolDescriptor] = [:]
    ) {
        self.spec = spec
        self.dependencies = dependencies
        self.levels = levels
        self.descriptors = descriptors
    }
}

public enum WorkflowValidator {
    public static func validate(
        _ spec: WorkflowSpec,
        policy: WorkflowValidationPolicy
    ) throws -> ValidatedWorkflow {
        var spec = spec
        guard spec.schemaVersion == WorkflowSpec.schemaVersion else {
            throw WorkflowError.unsupportedSchemaVersion(spec.schemaVersion)
        }
        guard isValidWorkflowID(spec.workflowID) else {
            throw WorkflowError.invalidWorkflowID(spec.workflowID)
        }
        // The model's self-declared `limits.max_nodes` is advisory, not a
        // safety bound. Small models routinely low-ball it — emitting
        // `max_nodes: 1` for a two-node plan — which under a `min(spec, policy)`
        // rule would reject their own otherwise-valid workflow. The host's
        // `policy.maxNodes` is the real ceiling; normalize the declared limit
        // up to at least the node count so a self-contradictory value can't
        // fail validation.
        spec.limits.maxNodes = max(spec.limits.maxNodes, spec.nodes.count)
        guard spec.nodes.count <= policy.maxNodes else {
            throw WorkflowError.nodeLimitExceeded(
                count: spec.nodes.count,
                limit: policy.maxNodes
            )
        }
        guard spec.limits.maxParallelism > 0,
              spec.limits.maxParallelism <= policy.maxParallelism else {
            throw WorkflowError.maxParallelismInvalid(spec.limits.maxParallelism)
        }
        guard spec.limits.deadlineMS > 0,
              spec.limits.deadlineMS <= policy.maxDeadlineMS else {
            throw WorkflowError.deadlineExceededLimit(spec.limits.deadlineMS)
        }

        var byID: [String: WorkflowNode] = [:]
        var indexByID: [String: Int] = [:]
        for (index, node) in spec.nodes.enumerated() {
            guard isValidNodeID(node.id) else {
                throw WorkflowError.invalidNodeID(node.id)
            }
            guard byID[node.id] == nil else {
                throw WorkflowError.duplicateNodeID(node.id)
            }
            guard node.kind == .tool else {
                throw WorkflowError.unsupportedNodeKind(id: node.id, kind: node.kind)
            }
            guard let tool = node.tool, !tool.isEmpty else {
                throw WorkflowError.missingTool(nodeID: node.id)
            }
            guard policy.availableTools.contains(tool) else {
                throw WorkflowError.unavailableTool(nodeID: node.id, tool: tool)
            }
            if let descriptor = policy.descriptors[tool],
               descriptor.annotations?.requiresUserApproval == true,
               !policy.allowApprovalRequiredTools {
                throw WorkflowError.unavailableTool(nodeID: node.id, tool: tool)
            }
            guard node.policy.timeoutMS >= 0,
                  node.policy.timeoutMS <= policy.maxDeadlineMS else {
                throw WorkflowError.deadlineExceededLimit(node.policy.timeoutMS)
            }
            guard node.policy.retry.maxAttempts >= 0,
                  node.policy.retry.maxAttempts <= 5 else {
                throw WorkflowError.nodeFailed(
                    nodeID: node.id,
                    message: "retry max_attempts must be in 0...5"
                )
            }
            guard node.outputPolicy.maxBytes >= 0,
                  node.outputPolicy.maxBytes <= policy.maxOutputBytesPerNode,
                  node.outputPolicy.maxBytes <= spec.limits.maxOutputBytesPerNode else {
                throw WorkflowError.outputLimitExceeded(
                    nodeID: node.id,
                    bytes: node.outputPolicy.maxBytes,
                    limit: min(policy.maxOutputBytesPerNode, spec.limits.maxOutputBytesPerNode)
                )
            }
            byID[node.id] = node
            indexByID[node.id] = index
        }

        var dependencies: [String: Set<String>] = [:]
        for (index, node) in spec.nodes.enumerated() {
            var nodeDependencies = Set(node.dependsOn)
            for reference in WorkflowReferenceResolver.references(in: node.input) {
                try validate(reference: reference, currentNodeID: node.id, byID: byID)
                if reference.source == .node, let referencedNode = reference.node {
                    nodeDependencies.insert(referencedNode)
                    try validateOutputPath(
                        reference.path,
                        referencedNodeID: referencedNode,
                        currentNodeID: node.id,
                        byID: byID,
                        descriptors: policy.descriptors
                    )
                }
            }
            for dependency in nodeDependencies {
                guard dependency != node.id else {
                    throw WorkflowError.selfDependency(nodeID: node.id)
                }
                guard byID[dependency] != nil else {
                    throw WorkflowError.unknownDependency(
                        nodeID: node.id, dependency: dependency
                    )
                }
                if let dependencyIndex = indexByID[dependency],
                   dependencyIndex >= index {
                    throw WorkflowError.nonTopologicalOrder(
                        nodeID: node.id, dependency: dependency
                    )
                }
            }
            dependencies[node.id] = nodeDependencies
        }

        try validateFinal(spec.final, byID: byID, descriptors: policy.descriptors)
        let levels = try topologicalLevels(nodes: spec.nodes, dependencies: dependencies)
        return ValidatedWorkflow(
            spec: spec,
            dependencies: dependencies,
            levels: levels,
            descriptors: policy.descriptors
        )
    }

    private static func validate(
        reference: WorkflowReference,
        currentNodeID: String,
        byID: [String: WorkflowNode]
    ) throws {
        switch reference.source {
        case .node:
            guard let node = reference.node, byID[node] != nil else {
                throw WorkflowError.invalidReference(
                    nodeID: currentNodeID,
                    reason: "node reference must name an existing node"
                )
            }
            try validateJSONPointerPath(reference.path, nodeID: currentNodeID)
        case .context, .userInput:
            try validateJSONPointerPath(reference.path, nodeID: currentNodeID)
        case .item:
            throw WorkflowError.invalidReference(
                nodeID: currentNodeID,
                reason: "item references require fanout support"
            )
        }
    }

    private static func validateFinal(
        _ final: WorkflowFinal,
        byID: [String: WorkflowNode],
        descriptors: [String: ToolDescriptor]
    ) throws {
        switch final.kind {
        case .value:
            guard let value = final.value else {
                throw WorkflowError.unsupportedFinal(final.kind)
            }
            for reference in WorkflowReferenceResolver.references(in: value) {
                try validate(reference: reference, currentNodeID: "final", byID: byID)
                try validateFinalReference(reference, byID: byID, descriptors: descriptors)
            }
        case .template:
            guard final.template != nil else {
                throw WorkflowError.unsupportedFinal(final.kind)
            }
            for binding in final.bindings.values {
                for reference in WorkflowReferenceResolver.references(in: binding) {
                    try validate(reference: reference, currentNodeID: "final", byID: byID)
                    try validateFinalReference(reference, byID: byID, descriptors: descriptors)
                }
            }
        case .nodeOutput:
            guard let node = final.node, byID[node] != nil else {
                throw WorkflowError.unsupportedFinal(final.kind)
            }
            try validateNodeExposedToFinal(node, byID: byID)
            try validateOutputPath(
                final.path ?? "",
                referencedNodeID: node,
                currentNodeID: "final",
                byID: byID,
                descriptors: descriptors
            )
            if let path = final.path, !path.isEmpty, !path.hasPrefix("/") {
                throw WorkflowError.invalidReference(
                    nodeID: "final",
                    reason: "node_output path must be JSON Pointer"
                )
            }
        case .message:
            guard final.message != nil else {
                throw WorkflowError.unsupportedFinal(final.kind)
            }
        }
    }

    private static func topologicalLevels(
        nodes: [WorkflowNode],
        dependencies: [String: Set<String>]
    ) throws -> [[WorkflowNode]] {
        var remaining = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var satisfied = Set<String>()
        var levels: [[WorkflowNode]] = []

        while !remaining.isEmpty {
            let ready = nodes.filter { node in
                remaining[node.id] != nil
                    && (dependencies[node.id] ?? []).isSubset(of: satisfied)
            }
            guard !ready.isEmpty else {
                throw WorkflowError.cyclicDependency(Array(remaining.keys).sorted())
            }
            levels.append(ready)
            for node in ready {
                remaining.removeValue(forKey: node.id)
                satisfied.insert(node.id)
            }
        }
        return levels
    }

    private static func validateFinalReference(
        _ reference: WorkflowReference,
        byID: [String: WorkflowNode],
        descriptors: [String: ToolDescriptor]
    ) throws {
        guard reference.source == .node, let node = reference.node else { return }
        try validateNodeExposedToFinal(node, byID: byID)
        try validateOutputPath(
            reference.path,
            referencedNodeID: node,
            currentNodeID: "final",
            byID: byID,
            descriptors: descriptors
        )
    }

    private static func validateNodeExposedToFinal(
        _ nodeID: String,
        byID: [String: WorkflowNode]
    ) throws {
        guard byID[nodeID]?.outputPolicy.exposeToFinal == true else {
            throw WorkflowError.invalidReference(
                nodeID: "final",
                reason: "node \(nodeID) output is not exposed to final rendering"
            )
        }
    }

    private static func validateOutputPath(
        _ path: String,
        referencedNodeID: String,
        currentNodeID: String,
        byID: [String: WorkflowNode],
        descriptors: [String: ToolDescriptor]
    ) throws {
        _ = referencedNodeID
        _ = byID
        _ = descriptors
        try validateJSONPointerPath(path, nodeID: currentNodeID)
    }

    private static func validateJSONPointerPath(_ path: String, nodeID: String) throws {
        guard path.isEmpty || path.hasPrefix("/") else {
            throw WorkflowError.invalidReference(
                nodeID: nodeID,
                reason: "path must be JSON Pointer"
            )
        }
    }

    private static func isValidWorkflowID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
    }

    public static func isValidNodeID(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first.value >= 97 && first.value <= 122,
              value.count <= 64
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar.value == 95
        }
    }
}
