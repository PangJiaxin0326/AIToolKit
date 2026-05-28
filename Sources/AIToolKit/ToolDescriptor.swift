import Foundation

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
