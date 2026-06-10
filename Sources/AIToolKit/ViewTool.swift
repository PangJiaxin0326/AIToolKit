import FoundationModels
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
/// `Arguments` typically carry a model selector (e.g. `"contacts"`) plus
/// view-specific configuration (sort order, column count, chart kind, ...).
///
/// Why a separate protocol from `Tool`: `FoundationModels.Tool.Output` must be
/// prompt-representable so it can round-trip back to the model. A SwiftUI
/// `View` is neither, and is meaningless to round-trip — the host renders it.
///
/// The interface follows FoundationModels naming: tools expose `parameters`
/// and are executed with `call(arguments:)`.
public protocol ViewTool: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Body: View

    var name: String { get }
    var description: String { get }
    var parameters: GenerationSchema { get }

    /// Produce the view for the given arguments. Runs on the main actor because
    /// SwiftUI view construction is main-isolated.
    @MainActor
    func call(arguments: Arguments) async throws -> Body
}

extension ViewTool {
    /// Callable shorthand for direct use outside a registry.
    @MainActor
    public func callAsFunction(_ arguments: Arguments) async throws -> Body {
        try await call(arguments: arguments)
    }
}

extension ViewTool where Arguments: Generable {
    public var parameters: GenerationSchema { Arguments.generationSchema }

    /// Provider-facing descriptor derived from the tool's static metadata.
    /// Shares its shape with `Tool.descriptor` so a host can mix both
    /// families in one manifest sent to the model.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            argumentsSchema: parameters
        )
    }
}
