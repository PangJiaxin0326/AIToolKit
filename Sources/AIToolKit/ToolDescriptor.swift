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
}
