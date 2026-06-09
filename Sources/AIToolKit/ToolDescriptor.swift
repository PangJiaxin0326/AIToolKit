import Foundation
import FoundationModels

/// A provider-agnostic description of a tool, sent to the LLM so it can decide
/// when and how to call it.
///
/// `inputSchema` is a JSON Schema object describing the tool's input. Capability
/// layer types (e.g. `ToolSchema`) produce these descriptors.
public struct ToolDescriptor: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: ToolAnnotations?
    public var inputExamples: [JSONValue]?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: ToolAnnotations? = nil,
        inputExamples: [JSONValue]? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.inputExamples = inputExamples
    }
}

extension ToolDescriptor {
    /// Creates an AIToolKit descriptor from an official Foundation Models tool.
    public init<T: FoundationModels.Tool>(
        tool: T,
        outputSchema: JSONValue? = nil,
        annotations: ToolAnnotations? = nil,
        inputExamples: [JSONValue]? = nil
    ) {
        self.init(
            name: tool.name,
            description: tool.description,
            inputSchema: ToolSchema.jsonValue(for: tool.parameters),
            outputSchema: outputSchema,
            annotations: annotations,
            inputExamples: inputExamples
        )
    }

    /// Converts this descriptor into the official transcript tool definition.
    public func foundationToolDefinition() throws -> Transcript.ToolDefinition {
        try Transcript.ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema(json: inputSchema).generationSchema(
                title: "\(name)Arguments"
            )
        )
    }
}
