import Foundation
import FoundationModels
import OSLog

/// AIToolKit uses FoundationModels' official tool protocol as its tool base.
///
/// A tool is fully described by the official surface — `name`, `description`,
/// and `parameters` (`GenerationSchema`) — plus the `outputSchema` derived from
/// a `Generable` `Output`. Anything a tool needs at call time (stores,
/// clients, coordinators) is injected at construction.
///
/// Ambient per-call state uses FoundationModels' session-property system, not
/// a custom context type: hosts declare values with `@SessionPropertyEntry` on
/// `SessionPropertyValues` and tools read them with `@Tool.SessionProperty`
/// when they run inside a `LanguageModelSession` driven by a `DynamicProfile`.
public typealias Tool = FoundationModels.Tool

extension FoundationModels.Tool {
    /// Provider-facing descriptor derived from this tool's official surface.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(tool: self)
    }

    /// Callable shorthand matching Swift's call-as-function convention.
    public func callAsFunction(_ arguments: Arguments) async throws -> Output {
        try await call(arguments: arguments)
    }
}

extension FoundationModels.Tool where Arguments: Generable, Output: Generable {
    public static var argumentsSchema: GenerationSchema { Arguments.generationSchema }
    public static var outputSchema: GenerationSchema { Output.generationSchema }
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

/// Errors from registry dispatch paths (`ViewToolRegistry`). Data tools no
/// longer use a registry: pass them to a `LanguageModelSession` directly.
public enum ToolRegistryError: Error, Sendable {
    case notRegistered(String)
    case decodingFailed(name: String, detail: String)
}
