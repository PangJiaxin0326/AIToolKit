import Foundation
import OSLog

/// A typed, declarative unit of work the LLM can call.
///
/// AIToolKit defines the standard so any Swift package can ship `Tool`s
/// without depending on the rest of AIKit. The hosting app wires them into an
/// `AIKitCapability.ToolRegistry` and runs them through `AIKitRuntime`.
///
/// The interface follows Claude SDK / MCP naming: tools expose an
/// `inputSchema` and are executed with `call(_:in:)`.
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolSchema { get }
    static var outputSchema: ToolSchema { get }
    static var annotations: ToolAnnotations { get }
    static var inputExamples: [JSONValue] { get }

    func call(_ input: Input, in context: ToolContext) async throws -> Output
}

extension Tool {
    public static var outputSchema: ToolSchema { .unknownObject }
    public static var annotations: ToolAnnotations { .default }
    public static var inputExamples: [JSONValue] { [] }

    /// Callable shorthand for direct use outside a registry.
    public func callAsFunction(
        _ input: Input,
        in context: ToolContext = ToolContext()
    ) async throws -> Output {
        try await call(input, in: context)
    }

    /// The provider-facing descriptor derived from the tool's static metadata.
    public static var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema.json,
            outputSchema: outputSchema.json,
            annotations: annotations,
            inputExamples: inputExamples
        )
    }
}

public struct ToolAnnotations: Sendable, Codable, Hashable {
    public enum SideEffect: String, Sendable, Codable, Hashable {
        case none
        case localWrite = "local_write"
        case networkRead = "network_read"
        case networkWrite = "network_write"
        case destructive
        case externalMessage = "external_message"
        case payment
        case auth
        case unknown
    }

    public enum SensitiveOutput: String, Sendable, Codable, Hashable {
        case none
        case personal
        case credentials
        case privateContent = "private_content"
        case unknown
    }

    public enum CachePolicy: String, Sendable, Codable, Hashable {
        case none
        case memory
        case disk
        case session
    }

    public var isReadOnly: Bool
    public var isIdempotent: Bool
    public var sideEffect: SideEffect
    public var requiresUserApproval: Bool
    public var allowedWithoutNetwork: Bool
    public var defaultTimeoutMS: Int
    public var maxOutputBytes: Int
    public var sensitiveOutput: SensitiveOutput
    public var cachePolicy: CachePolicy
    public var resultSummaryHint: String?

    public init(
        isReadOnly: Bool = false,
        isIdempotent: Bool = false,
        sideEffect: SideEffect = .unknown,
        requiresUserApproval: Bool = false,
        allowedWithoutNetwork: Bool = true,
        defaultTimeoutMS: Int = 5_000,
        maxOutputBytes: Int = 65_536,
        sensitiveOutput: SensitiveOutput = .unknown,
        cachePolicy: CachePolicy = .none,
        resultSummaryHint: String? = nil
    ) {
        self.isReadOnly = isReadOnly
        self.isIdempotent = isIdempotent
        self.sideEffect = sideEffect
        self.requiresUserApproval = requiresUserApproval
        self.allowedWithoutNetwork = allowedWithoutNetwork
        self.defaultTimeoutMS = defaultTimeoutMS
        self.maxOutputBytes = maxOutputBytes
        self.sensitiveOutput = sensitiveOutput
        self.cachePolicy = cachePolicy
        self.resultSummaryHint = resultSummaryHint
    }

    public static let `default` = ToolAnnotations()
}

/// Ambient state handed to a tool during invocation.
///
/// Kept deliberately small so AIToolKit can stand alone: the view id is a
/// bare `String` (the host runtime supplies the leaf view's id) and richer
/// dependencies — memory stores, persistence handles, network clients — are
/// held on the conforming tool itself, injected at construction.
public struct ToolContext: Sendable {
    /// The leaf view's id (`ViewContext.ID.rawValue` when AIKitCapability is
    /// driving). Empty when no view is in scope.
    public let viewID: String
    /// Free-form context the host wants the tool to see (e.g. the foreground
    /// entry id). Sub-string lookup only — keep keys stable.
    public let metadata: [String: String]
    public let logger: Logger

    public init(
        viewID: String = "",
        metadata: [String: String] = [:],
        logger: Logger = Self.defaultLogger
    ) {
        self.viewID = viewID
        self.metadata = metadata
        self.logger = logger
    }

    public static let defaultLogger = Logger(
        subsystem: "com.aikit.toolkit", category: "tool"
    )
}

/// Errors thrown by tools carry retriability so the ErrorHandler can decide
/// whether to loop back.
public protocol ToolError: Error, Sendable {
    var isRetriable: Bool { get }
}

/// A general-purpose `ToolError` for simple cases.
public struct GenericToolError: ToolError {
    public let message: String
    public let isRetriable: Bool

    public init(message: String, isRetriable: Bool = false) {
        self.message = message
        self.isRetriable = isRetriable
    }
}

/// A parsed request from the model to call a tool.
public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String
    public var input: JSONValue

    public init(id: String? = nil, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Errors from the registry dispatch path itself.
public enum ToolRegistryError: Error, Sendable {
    case notRegistered(String)
    case decodingFailed(name: String, detail: String)
    case encodingFailed(name: String, detail: String)
}
