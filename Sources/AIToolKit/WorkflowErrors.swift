import Foundation

public enum WorkflowError: Error, Sendable, Hashable, CustomStringConvertible {
    case unsupportedSchemaVersion(String)
    case unsupportedMode(WorkflowMode)
    case unsupportedNodeKind(id: String, kind: WorkflowNodeKind)
    case invalidWorkflowID(String)
    case invalidNodeID(String)
    case duplicateNodeID(String)
    case nodeLimitExceeded(count: Int, limit: Int)
    case maxParallelismInvalid(Int)
    case deadlineExceededLimit(Int)
    case outputLimitExceeded(nodeID: String, bytes: Int, limit: Int)
    case workflowTimedOut(deadlineMS: Int)
    case nodeTimedOut(nodeID: String, timeoutMS: Int)
    case missingTool(nodeID: String)
    case unavailableTool(nodeID: String, tool: String)
    case unknownDependency(nodeID: String, dependency: String)
    case selfDependency(nodeID: String)
    case nonTopologicalOrder(nodeID: String, dependency: String)
    case cyclicDependency([String])
    case invalidReference(nodeID: String, reason: String)
    case unresolvedReference(nodeID: String, reference: String)
    case unsupportedFinal(WorkflowFinal.Kind)
    case nodeFailed(nodeID: String, message: String)
    case executionSkipped(mode: WorkflowMode)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let value):
            "Unsupported workflow schema version: \(value)"
        case .unsupportedMode(let mode):
            "Workflow mode is not executable: \(mode.rawValue)"
        case .unsupportedNodeKind(let id, let kind):
            "Node \(id) has unsupported kind \(kind.rawValue)"
        case .invalidWorkflowID(let id):
            "Invalid workflow id: \(id)"
        case .invalidNodeID(let id):
            "Invalid node id: \(id)"
        case .duplicateNodeID(let id):
            "Duplicate workflow node id: \(id)"
        case .nodeLimitExceeded(let count, let limit):
            "Workflow has \(count) nodes, exceeding limit \(limit)"
        case .maxParallelismInvalid(let value):
            "Invalid max_parallelism: \(value)"
        case .deadlineExceededLimit(let value):
            "Workflow deadline exceeds allowed limit: \(value)ms"
        case .outputLimitExceeded(let nodeID, let bytes, let limit):
            "Node \(nodeID) output is \(bytes) bytes, exceeding limit \(limit)"
        case .workflowTimedOut(let deadlineMS):
            "Workflow timed out after \(deadlineMS)ms"
        case .nodeTimedOut(let nodeID, let timeoutMS):
            "Node \(nodeID) timed out after \(timeoutMS)ms"
        case .missingTool(let nodeID):
            "Tool node \(nodeID) is missing a tool name"
        case .unavailableTool(let nodeID, let tool):
            "Node \(nodeID) references unavailable tool \(tool)"
        case .unknownDependency(let nodeID, let dependency):
            "Node \(nodeID) depends on unknown node \(dependency)"
        case .selfDependency(let nodeID):
            "Node \(nodeID) depends on itself"
        case .nonTopologicalOrder(let nodeID, let dependency):
            "Node \(nodeID) depends on later node \(dependency)"
        case .cyclicDependency(let path):
            "Workflow contains a cycle: \(path.joined(separator: " -> "))"
        case .invalidReference(let nodeID, let reason):
            "Node \(nodeID) has invalid reference: \(reason)"
        case .unresolvedReference(let nodeID, let reference):
            "Node \(nodeID) could not resolve reference \(reference)"
        case .unsupportedFinal(let kind):
            "Unsupported workflow final kind \(kind.rawValue)"
        case .nodeFailed(let nodeID, let message):
            "Node \(nodeID) failed: \(message)"
        case .executionSkipped(let mode):
            "Workflow mode \(mode.rawValue) does not execute tools"
        }
    }
}
