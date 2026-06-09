import Foundation
import FoundationModels

extension JSONValue {
    /// Converts official generated content into AIToolKit's JSON value type.
    public init(generatedContent content: GeneratedContent) throws {
        self = try JSONValue(data: Data(content.jsonString.utf8))
    }

    /// Converts this value into official Foundation Models generated content.
    public func generatedContent() throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: data(), as: UTF8.self))
    }
}

/// Adapts an existing AIToolKit `Tool` to the official Foundation Models
/// `Tool` protocol while preserving AIToolKit's contextual call path.
public struct FoundationToolAdapter<Base: Tool>: FoundationModels.Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    private let base: Base
    private let context: ToolContext

    public let parameters: GenerationSchema
    public var name: String { Base.name }
    public var description: String { Base.description }

    public init(
        _ base: Base,
        context: ToolContext = ToolContext()
    ) throws {
        self.base = base
        self.context = context
        self.parameters = try Base.inputSchema.generationSchema(
            title: "\(Base.name)Arguments"
        )
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let data = Data(arguments.jsonString.utf8)
        let decoder = JSONDecoder()
        let input: Base.Input
        do {
            input = try decoder.decode(Base.Input.self, from: data)
        } catch {
            throw ToolRegistryError.decodingFailed(
                name: Base.name,
                detail: String(describing: error)
            )
        }

        let output = try await base.call(input, in: context)
        do {
            return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        } catch {
            throw ToolRegistryError.encodingFailed(
                name: Base.name,
                detail: String(describing: error)
            )
        }
    }
}

extension Tool {
    /// Returns an official Foundation Models tool wrapper for this AIToolKit
    /// tool. The wrapper returns JSON text so the model sees the same value the
    /// registry would have encoded for existing AIToolKit callers.
    public func foundationTool(
        context: ToolContext = ToolContext()
    ) throws -> any FoundationModels.Tool {
        try FoundationToolAdapter(self, context: context)
    }

    /// Returns this tool's official transcript definition when its input schema
    /// can be represented as a Foundation Models `GenerationSchema`.
    public static func foundationToolDefinition() throws -> Transcript.ToolDefinition {
        try ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema.json,
            outputSchema: outputSchema.json,
            annotations: annotations,
            inputExamples: inputExamples
        ).foundationToolDefinition()
    }
}
