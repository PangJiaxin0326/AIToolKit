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

    /// Lenient decoder: only `nodes` is required. Every other field falls back
    /// to a sane default so a model can emit a *minimal* spec (just the node
    /// list) and the runtime fills the rest. This is what lets the lean schema
    /// / minimal example cut output tokens — the synthesized decoder would
    /// otherwise demand every field. Full specs still decode unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? Self.schemaVersion
        self.workflowID = try c.decodeIfPresent(String.self, forKey: .workflowID) ?? "wf"
        self.intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? ""
        self.mode = try c.decodeIfPresent(WorkflowMode.self, forKey: .mode) ?? .execute
        self.nodes = try c.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        self.limits = try c.decodeIfPresent(WorkflowLimits.self, forKey: .limits) ?? .default
        self.metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        // `final` defaults to the last node's output (or an empty message for
        // an empty plan) so a spec that omits it still validates and renders.
        if let f = try c.decodeIfPresent(WorkflowFinal.self, forKey: .final) {
            self.final = f
        } else if let last = self.nodes.last {
            self.final = .nodeOutput(last.id)
        } else {
            self.final = .message("")
        }
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

    /// Lenient decoder: only `id` is required. `tool` may be absent (validated
    /// later), `depends_on` defaults to [] (dependencies are also derived from
    /// `$ref`s in `input`), and `policy`/`output_policy` default — so a node
    /// can be just `{id, tool, input}`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decodeIfPresent(WorkflowNodeKind.self, forKey: .kind) ?? .tool
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool)
        self.dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        let rawInput = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
        self.input = Self.sanitizedInput(rawInput)
        self.policy = try c.decodeIfPresent(WorkflowNodePolicy.self, forKey: .policy) ?? .default
        self.outputPolicy = try c.decodeIfPresent(WorkflowOutputPolicy.self, forKey: .outputPolicy) ?? .default
    }

    /// Node-level field names a model must NOT place inside `input` — but
    /// smaller planners routinely do (e.g. echoing `"id"`/`"tool"` into a
    /// node's `input`). Left there, those stray keys make the per-node input
    /// fail the tool's strict input-schema validation at execution time, so
    /// the node — and the whole workflow side effect — silently fails.
    private static let reservedInputKeys: Set<String> = [
        "id", "kind", "tool", "depends_on", "policy", "output_policy",
    ]

    /// Defensive input normalization applied at decode time:
    /// - a `null` (or non-object) input becomes an empty object, so a
    ///   model that emits `"input": null` doesn't crash the node; and
    /// - any node-structural keys that leaked into `input` are stripped, so
    ///   the tool sees only its own parameters.
    /// Tool parameters in practice never use these structural names, so this
    /// is safe and turns a common malformed-plan failure into a success.
    private static func sanitizedInput(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else {
            return .object([:])
        }
        for key in reservedInputKeys { object.removeValue(forKey: key) }
        return .object(object)
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timeoutMS = try c.decodeIfPresent(Int.self, forKey: .timeoutMS) ?? 5_000
        self.retry = try c.decodeIfPresent(WorkflowRetryPolicy.self, forKey: .retry) ?? .default
        self.onError = try c.decodeIfPresent(OnError.self, forKey: .onError) ?? .abort
        self.defaultOutput = try c.decodeIfPresent(JSONValue.self, forKey: .defaultOutput)
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 1
        self.backoffMS = try c.decodeIfPresent(Int.self, forKey: .backoffMS) ?? 0
        self.retryOnlyIfToolErrorIsRetriable = try c.decodeIfPresent(Bool.self, forKey: .retryOnlyIfToolErrorIsRetriable) ?? true
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.store = try c.decodeIfPresent(Bool.self, forKey: .store) ?? true
        self.exposeToFinal = try c.decodeIfPresent(Bool.self, forKey: .exposeToFinal) ?? true
        self.maxBytes = try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 65_536
        self.redaction = try c.decodeIfPresent(Redaction.self, forKey: .redaction) ?? .toolDefault
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxNodes = try c.decodeIfPresent(Int.self, forKey: .maxNodes) ?? 12
        self.maxParallelism = try c.decodeIfPresent(Int.self, forKey: .maxParallelism) ?? 4
        self.deadlineMS = try c.decodeIfPresent(Int.self, forKey: .deadlineMS) ?? 15_000
        self.maxOutputBytesPerNode = try c.decodeIfPresent(Int.self, forKey: .maxOutputBytesPerNode) ?? 65_536
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

    private enum CodingKeys: String, CodingKey {
        case kind, value, template, bindings, node, path, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .message
        self.value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        self.template = try c.decodeIfPresent(String.self, forKey: .template)
        self.bindings = try c.decodeIfPresent([String: JSONValue].self, forKey: .bindings) ?? [:]
        self.node = try c.decodeIfPresent(String.self, forKey: .node)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
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
