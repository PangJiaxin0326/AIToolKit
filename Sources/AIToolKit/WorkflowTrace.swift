import Foundation

public enum WorkflowNodeStatus: String, Sendable, Codable, Hashable {
    case pending
    case running
    case succeeded
    case failedTerminal = "failed_terminal"
    case skipped
    case cancelled
}

public struct WorkflowNodeTrace: Sendable, Codable, Hashable {
    public var nodeID: String
    public var tool: String?
    public var status: WorkflowNodeStatus
    public var attempts: Int
    public var startedAt: Date?
    public var endedAt: Date?
    public var error: String?

    public init(
        nodeID: String,
        tool: String?,
        status: WorkflowNodeStatus,
        attempts: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        error: String? = nil
    ) {
        self.nodeID = nodeID
        self.tool = tool
        self.status = status
        self.attempts = attempts
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
    }
}

public struct WorkflowTrace: Sendable, Codable, Hashable {
    public var workflowID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var nodes: [WorkflowNodeTrace]

    public init(
        workflowID: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        nodes: [WorkflowNodeTrace] = []
    ) {
        self.workflowID = workflowID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.nodes = nodes
    }
}

public struct WorkflowResult: Sendable, Codable, Hashable {
    public var workflowID: String
    public var mode: WorkflowMode
    public var finalValue: JSONValue
    public var finalText: String?
    public var nodeOutputs: [String: JSONValue]
    public var trace: WorkflowTrace

    public init(
        workflowID: String,
        mode: WorkflowMode,
        finalValue: JSONValue,
        finalText: String? = nil,
        nodeOutputs: [String: JSONValue],
        trace: WorkflowTrace
    ) {
        self.workflowID = workflowID
        self.mode = mode
        self.finalValue = finalValue
        self.finalText = finalText
        self.nodeOutputs = nodeOutputs
        self.trace = trace
    }
}
