import Foundation
import FoundationModels

/// A provider-agnostic description of a tool, sent to the LLM so it can decide
/// when and how to call it. Mirrors the official `Tool` surface (name,
/// description, parameters) plus the output schema a `Generable` output
/// supplies.
///
/// `argumentsSchema` is the FoundationModels schema describing the tool's
/// arguments. Convert it to JSON only at provider communication boundaries.
public struct ToolDescriptor: Sendable, Identifiable {
    public var name: String
    public var description: String
    public var argumentsSchema: GenerationSchema
    public var outputSchema: GenerationSchema?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        argumentsSchema: GenerationSchema,
        outputSchema: GenerationSchema? = nil
    ) {
        self.name = name
        self.description = description
        self.argumentsSchema = argumentsSchema
        self.outputSchema = outputSchema
    }

    /// Derives a descriptor from any official FoundationModels tool, using the
    /// official surface (`name`, `description`, `parameters`). The output
    /// schema is included when the tool's `Output` is `Generable`.
    public init(tool: some FoundationModels.Tool) {
        self.init(
            name: tool.name,
            description: tool.description,
            argumentsSchema: tool.parameters,
            outputSchema: Self.outputSchema(of: tool)
        )
    }

    private static func outputSchema<T: FoundationModels.Tool>(of tool: T) -> GenerationSchema? {
        (T.Output.self as? any Generable.Type)?.generationSchema
    }
}
