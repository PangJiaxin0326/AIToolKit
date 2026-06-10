import Foundation
import FoundationModels
import OSLog

/// AIToolKit uses FoundationModels' official tool protocol as its tool base.
public typealias Tool = FoundationModels.Tool

public protocol ToolMetadataProviding: Sendable {
    var annotations: ToolAnnotations { get }
    var argumentExamples: [GeneratedContent] { get }
}

extension ToolMetadataProviding {
    public var annotations: ToolAnnotations { .default }
    public var argumentExamples: [GeneratedContent] { [] }
}

extension FoundationModels.Tool where Arguments: Generable, Output: Generable {
    public static var argumentsSchema: GenerationSchema { Arguments.generationSchema }
    public static var outputSchema: GenerationSchema { Output.generationSchema }

    /// Provider-facing descriptor derived from this tool's FoundationModels
    /// metadata and the `GenerationSchema`s supplied by its types.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            argumentsSchema: parameters,
            outputSchema: Self.outputSchema,
            annotations: (self as? any ToolMetadataProviding)?.annotations,
            argumentExamples: (self as? any ToolMetadataProviding)?.argumentExamples
        )
    }

    /// Callable shorthand matching Swift's call-as-function convention.
    public func callAsFunction(_ arguments: Arguments) async throws -> Output {
        try await call(arguments: arguments)
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
public struct ToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var arguments: GeneratedContent

    public init(id: String? = nil, name: String, arguments: GeneratedContent) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Errors from the registry dispatch path itself.
public enum ToolRegistryError: Error, Sendable {
    case notRegistered(String)
    case decodingFailed(name: String, detail: String)
}
