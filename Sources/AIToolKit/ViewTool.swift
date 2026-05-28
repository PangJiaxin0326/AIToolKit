import SwiftUI

/// A typed, declarative *view-producing* tool the LLM can call.
///
/// `ViewTool` is the sibling of `Tool` for the case where the right answer
/// is *a piece of UI*, not a JSON-serialized value. The host typically
/// registers one `ViewTool` per UI template (list, grid, chart, ...) and
/// supplies the closure that turns a model query into a concrete view.
///
/// Mental model: the LLM acts as a **UI router** (picks which `ViewTool` to
/// call) and a **model picker** (decides what data to feed it). The tool's
/// `Input` typically carries a model selector (e.g. `"contacts"`) plus
/// view-specific configuration (sort order, column count, chart kind, ...).
///
/// Why a separate protocol from `Tool`: `Tool.Output` must be `Codable &
/// Sendable` so it can round-trip back to the model as text. A SwiftUI
/// `View` is neither, and is meaningless to round-trip — the host renders it.
///
/// The interface follows Claude SDK / MCP naming: tools expose an
/// `inputSchema` and are executed with `call(_:in:)`.
public protocol ViewTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Body: View

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolSchema { get }

    /// Produce the view for the given input. Runs on the main actor because
    /// SwiftUI view construction is main-isolated.
    @MainActor
    func call(_ input: Input, in context: ToolContext) async throws -> Body
}

extension ViewTool {
    /// Callable shorthand for direct use outside a registry.
    @MainActor
    public func callAsFunction(
        _ input: Input,
        in context: ToolContext = ToolContext()
    ) async throws -> Body {
        try await call(input, in: context)
    }

    /// Provider-facing descriptor derived from the tool's static metadata.
    /// Shares its shape with `Tool.descriptor` so a host can mix both
    /// families in one manifest sent to the model.
    public static var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema.json
        )
    }
}
