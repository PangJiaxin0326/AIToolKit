import Foundation
import FoundationModels

/// One-shot workflow IR for edge execution. The model emits one
/// `WorkflowSpec`, then the runtime validates and executes the DAG locally
/// without asking the model to observe intermediate tool outputs.
public struct WorkflowSpec: Sendable, Equatable {
    public static let schemaVersion = "workflow.v1"
    public static let toolName = "workflow_run"

    public var schemaVersion: String
    public var workflowID: String
    public var intent: String
    public var mode: WorkflowMode
    public var nodes: [WorkflowNode]
    public var final: WorkflowFinal
    public var limits: WorkflowLimits
    public var metadata: [String: GeneratedContent]

    public init(
        schemaVersion: String = Self.schemaVersion,
        workflowID: String,
        intent: String,
        mode: WorkflowMode = .execute,
        nodes: [WorkflowNode],
        final: WorkflowFinal,
        limits: WorkflowLimits = .default,
        metadata: [String: GeneratedContent] = [:]
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

    /// Lenient decoder: only `nodes` is required. Every other field falls back
    /// to a sane default so a model can emit a *minimal* spec (just the node
    /// list) and the runtime fills the rest. This is what lets the lean schema
    /// / minimal example cut output tokens — the synthesized decoder would
    /// otherwise demand every field. Full specs still decode unchanged.
    public init(_ content: GeneratedContent) throws {
        self.schemaVersion = content.optionalString("schema_version") ?? Self.schemaVersion
        self.workflowID = content.optionalString("workflow_id") ?? "wf"
        self.intent = content.optionalString("intent") ?? ""
        self.mode = content.optionalString("mode").flatMap(WorkflowMode.init(rawValue:)) ?? .execute
        self.nodes = try content.contentArray("nodes")?.map(WorkflowNode.init) ?? []
        self.limits = try content.property("limits").map(WorkflowLimits.init) ?? .default
        self.metadata = try content.contentObject("metadata") ?? [:]
        // `final` defaults to the last node's output (or an empty message for
        // an empty plan) so a spec that omits it still validates and renders.
        if let finalContent = content.property("final") {
            self.final = try WorkflowFinal(finalContent)
        } else if let last = self.nodes.last {
            self.final = .nodeOutput(last.id)
        } else {
            self.final = .message("")
        }
    }

    public static func decodeToolCallArguments(_ arguments: GeneratedContent) throws -> WorkflowSpec {
        let value: GeneratedContent
        if case .structure(let object, _) = arguments.kind,
           let wrapped = object["spec"] ?? object["workflow"] {
            value = wrapped
        } else {
            value = arguments
        }
        return try WorkflowSpec(value)
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

public struct WorkflowNode: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: WorkflowNodeKind
    public var tool: String?
    public var dependsOn: [String]
    public var input: GeneratedContent
    public var policy: WorkflowNodePolicy
    public var outputPolicy: WorkflowOutputPolicy

    public init(
        id: String,
        kind: WorkflowNodeKind = .tool,
        tool: String?,
        dependsOn: [String] = [],
        input: GeneratedContent = .object([:]),
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

    /// Lenient decoder: only `id` is required. `tool` may be absent (validated
    /// later), `depends_on` defaults to [] (dependencies are also derived from
    /// `$ref`s in `input`), and `policy`/`output_policy` default — so a node
    /// can be just `{id, tool, input}`.
    public init(_ content: GeneratedContent) throws {
        self.id = try content.requiredString("id")
        self.kind = content.optionalString("kind").flatMap(WorkflowNodeKind.init(rawValue:)) ?? .tool
        self.tool = content.optionalString("tool")
        self.dependsOn = try content.contentArray("depends_on")?.compactMap(\.stringValue) ?? []
        let rawInput = content.property("input") ?? .object([:])
        self.input = Self.sanitizedInput(rawInput)
        self.policy = try content.property("policy").map(WorkflowNodePolicy.init) ?? .default
        self.outputPolicy = try content.property("output_policy").map(WorkflowOutputPolicy.init) ?? .default
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
    private static func sanitizedInput(_ value: GeneratedContent) -> GeneratedContent {
        guard case .structure(var object, _) = value.kind else {
            return .object([:])
        }
        for key in reservedInputKeys { object.removeValue(forKey: key) }
        return .object(object)
    }
}

public struct WorkflowNodePolicy: Sendable, Equatable {
    public static let defaultTimeoutMS = 20_000

    public enum OnError: String, Sendable, Codable, Hashable {
        case abort
        case continueWithNull = "continue_with_null"
        case continueWithDefault = "continue_with_default"
        case skipDependents = "skip_dependents"
    }

    public var timeoutMS: Int
    public var retry: WorkflowRetryPolicy
    public var onError: OnError
    public var defaultOutput: GeneratedContent?

    public init(
        timeoutMS: Int = Self.defaultTimeoutMS,
        retry: WorkflowRetryPolicy = .default,
        onError: OnError = .abort,
        defaultOutput: GeneratedContent? = nil
    ) {
        self.timeoutMS = timeoutMS
        self.retry = retry
        self.onError = onError
        self.defaultOutput = defaultOutput
    }

    public static let `default` = WorkflowNodePolicy()

    public init(_ content: GeneratedContent) throws {
        self.timeoutMS = content.optionalInt("timeout_ms") ?? Self.defaultTimeoutMS
        self.retry = try content.property("retry").map(WorkflowRetryPolicy.init) ?? .default
        self.onError = content.optionalString("on_error").flatMap(OnError.init(rawValue:)) ?? .abort
        self.defaultOutput = content.property("default_output")
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

    public init(_ content: GeneratedContent) throws {
        self.maxAttempts = content.optionalInt("max_attempts") ?? 1
        self.backoffMS = content.optionalInt("backoff_ms") ?? 0
        self.retryOnlyIfToolErrorIsRetriable =
            content.optionalBool("retry_only_if_tool_error_is_retriable") ?? true
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

    public init(_ content: GeneratedContent) throws {
        self.store = content.optionalBool("store") ?? true
        self.exposeToFinal = content.optionalBool("expose_to_final") ?? true
        self.maxBytes = content.optionalInt("max_bytes") ?? 65_536
        self.redaction = content.optionalString("redaction").flatMap(Redaction.init(rawValue:)) ?? .toolDefault
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

    public init(_ content: GeneratedContent) throws {
        self.maxNodes = content.optionalInt("max_nodes") ?? 12
        self.maxParallelism = content.optionalInt("max_parallelism") ?? 4
        self.deadlineMS = content.optionalInt("deadline_ms") ?? 15_000
        self.maxOutputBytesPerNode = content.optionalInt("max_output_bytes_per_node") ?? 65_536
    }
}

public struct WorkflowFinal: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case value
        case template
        case nodeOutput = "node_output"
        case message
    }

    public var kind: Kind
    public var value: GeneratedContent?
    public var template: String?
    public var bindings: [String: GeneratedContent]
    public var node: String?
    public var path: String?
    public var message: String?

    public init(
        kind: Kind,
        value: GeneratedContent? = nil,
        template: String? = nil,
        bindings: [String: GeneratedContent] = [:],
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

    public init(_ content: GeneratedContent) throws {
        self.kind = content.optionalString("kind").flatMap(Kind.init(rawValue:)) ?? .message
        self.value = content.property("value")
        self.template = content.optionalString("template")
        self.bindings = try content.contentObject("bindings") ?? [:]
        self.node = content.optionalString("node")
        self.path = content.optionalString("path")
        self.message = content.optionalString("message")
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
