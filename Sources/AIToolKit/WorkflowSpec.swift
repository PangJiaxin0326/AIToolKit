import Foundation

/// One-shot workflow IR for edge execution. The model emits one
/// `WorkflowSpec`, then the runtime validates and executes the DAG locally
/// without asking the model to observe intermediate tool outputs.
public struct WorkflowSpec: Sendable, Codable, Hashable {
    public static let schemaVersion = "workflow.v1"
    public static let toolName = "workflow_run"

    public var schemaVersion: String
    public var workflowID: String
    public var intent: String
    public var mode: WorkflowMode
    public var nodes: [WorkflowNode]
    public var final: WorkflowFinal
    public var limits: WorkflowLimits
    public var metadata: [String: JSONValue]

    public init(
        schemaVersion: String = Self.schemaVersion,
        workflowID: String,
        intent: String,
        mode: WorkflowMode = .execute,
        nodes: [WorkflowNode],
        final: WorkflowFinal,
        limits: WorkflowLimits = .default,
        metadata: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.workflowID = workflowID
        self.intent = intent
        self.mode = mode
        self.nodes = nodes
        self.final = final
        self.limits = limits
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case workflowID = "workflow_id"
        case intent, mode, nodes, final, limits, metadata
    }

    public static func decodeToolCallInput(_ input: JSONValue) throws -> WorkflowSpec {
        let value: JSONValue
        if case .object(let object) = input,
           let wrapped = object["spec"] ?? object["workflow"] {
            value = wrapped
        } else {
            value = input
        }
        return try JSONDecoder().decode(WorkflowSpec.self, from: value.data())
    }
}

public enum WorkflowMode: String, Sendable, Codable, Hashable {
    case execute
    case dryRun = "dry_run"
    case needsClarification = "needs_clarification"
    case unsupported
}

public enum WorkflowNodeKind: String, Sendable, Codable, Hashable {
    case tool
}

public struct WorkflowNode: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var kind: WorkflowNodeKind
    public var tool: String?
    public var dependsOn: [String]
    public var input: JSONValue
    public var policy: WorkflowNodePolicy
    public var outputPolicy: WorkflowOutputPolicy

    public init(
        id: String,
        kind: WorkflowNodeKind = .tool,
        tool: String?,
        dependsOn: [String] = [],
        input: JSONValue = .object([:]),
        policy: WorkflowNodePolicy = .default,
        outputPolicy: WorkflowOutputPolicy = .default
    ) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.dependsOn = dependsOn
        self.input = input
        self.policy = policy
        self.outputPolicy = outputPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, tool
        case dependsOn = "depends_on"
        case input, policy
        case outputPolicy = "output_policy"
    }
}

public struct WorkflowNodePolicy: Sendable, Codable, Hashable {
    public enum OnError: String, Sendable, Codable, Hashable {
        case abort
        case continueWithNull = "continue_with_null"
        case continueWithDefault = "continue_with_default"
        case skipDependents = "skip_dependents"
    }

    public var timeoutMS: Int
    public var retry: WorkflowRetryPolicy
    public var onError: OnError
    public var defaultOutput: JSONValue?

    public init(
        timeoutMS: Int = 5_000,
        retry: WorkflowRetryPolicy = .default,
        onError: OnError = .abort,
        defaultOutput: JSONValue? = nil
    ) {
        self.timeoutMS = timeoutMS
        self.retry = retry
        self.onError = onError
        self.defaultOutput = defaultOutput
    }

    public static let `default` = WorkflowNodePolicy()

    private enum CodingKeys: String, CodingKey {
        case timeoutMS = "timeout_ms"
        case retry
        case onError = "on_error"
        case defaultOutput = "default_output"
    }
}

public struct WorkflowRetryPolicy: Sendable, Codable, Hashable {
    public var maxAttempts: Int
    public var backoffMS: Int
    public var retryOnlyIfToolErrorIsRetriable: Bool

    public init(
        maxAttempts: Int = 1,
        backoffMS: Int = 0,
        retryOnlyIfToolErrorIsRetriable: Bool = true
    ) {
        self.maxAttempts = maxAttempts
        self.backoffMS = backoffMS
        self.retryOnlyIfToolErrorIsRetriable = retryOnlyIfToolErrorIsRetriable
    }

    public static let `default` = WorkflowRetryPolicy()

    private enum CodingKeys: String, CodingKey {
        case maxAttempts = "max_attempts"
        case backoffMS = "backoff_ms"
        case retryOnlyIfToolErrorIsRetriable = "retry_only_if_tool_error_is_retriable"
    }
}

public struct WorkflowOutputPolicy: Sendable, Codable, Hashable {
    public enum Redaction: String, Sendable, Codable, Hashable {
        case none
        case toolDefault = "tool_default"
    }

    public var store: Bool
    public var exposeToFinal: Bool
    public var maxBytes: Int
    public var redaction: Redaction

    public init(
        store: Bool = true,
        exposeToFinal: Bool = true,
        maxBytes: Int = 65_536,
        redaction: Redaction = .toolDefault
    ) {
        self.store = store
        self.exposeToFinal = exposeToFinal
        self.maxBytes = maxBytes
        self.redaction = redaction
    }

    public static let `default` = WorkflowOutputPolicy()

    private enum CodingKeys: String, CodingKey {
        case store
        case exposeToFinal = "expose_to_final"
        case maxBytes = "max_bytes"
        case redaction
    }
}

public struct WorkflowLimits: Sendable, Codable, Hashable {
    public var maxNodes: Int
    public var maxParallelism: Int
    public var deadlineMS: Int
    public var maxOutputBytesPerNode: Int

    public init(
        maxNodes: Int = 12,
        maxParallelism: Int = 4,
        deadlineMS: Int = 15_000,
        maxOutputBytesPerNode: Int = 65_536
    ) {
        self.maxNodes = maxNodes
        self.maxParallelism = maxParallelism
        self.deadlineMS = deadlineMS
        self.maxOutputBytesPerNode = maxOutputBytesPerNode
    }

    public static let `default` = WorkflowLimits()

    private enum CodingKeys: String, CodingKey {
        case maxNodes = "max_nodes"
        case maxParallelism = "max_parallelism"
        case deadlineMS = "deadline_ms"
        case maxOutputBytesPerNode = "max_output_bytes_per_node"
    }
}

public struct WorkflowFinal: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case value
        case template
        case nodeOutput = "node_output"
        case message
    }

    public var kind: Kind
    public var value: JSONValue?
    public var template: String?
    public var bindings: [String: JSONValue]
    public var node: String?
    public var path: String?
    public var message: String?

    public init(
        kind: Kind,
        value: JSONValue? = nil,
        template: String? = nil,
        bindings: [String: JSONValue] = [:],
        node: String? = nil,
        path: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.template = template
        self.bindings = bindings
        self.node = node
        self.path = path
        self.message = message
    }

    public static func nodeOutput(_ node: String, path: String = "") -> WorkflowFinal {
        WorkflowFinal(kind: .nodeOutput, node: node, path: path)
    }

    public static func message(_ text: String) -> WorkflowFinal {
        WorkflowFinal(kind: .message, message: text)
    }
}

public struct WorkflowReference: Sendable, Codable, Hashable {
    public enum Source: String, Sendable, Codable, Hashable {
        case node
        case context
        case userInput = "user_input"
        case item
    }

    public var source: Source
    public var node: String?
    public var path: String

    public init(source: Source, node: String? = nil, path: String = "") {
        self.source = source
        self.node = node
        self.path = path
    }
}
