import Foundation
import FoundationModels

/// Process-wide tool registry. Allows per-view subsetting via the tool-name
/// set the host caller supplies (AIKitCapability's `ViewContext.toolNames`
/// drives this in the journal app).
public actor ToolRegistry {
    public static let shared = ToolRegistry()

    private struct Entry {
        let descriptor: ToolDescriptor
        let foundationTool: @Sendable (ToolContext) throws -> any FoundationModels.Tool
        let call: @Sendable (Data, ToolContext) async throws -> Data
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register<T: Tool>(_ tool: T) {
        let descriptor = T.descriptor
        let name = T.name
        entries[name] = Entry(
            descriptor: descriptor,
            foundationTool: { context in
                try FoundationToolAdapter(tool, context: context)
            }
        ) { data, context in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let input: T.Input
            do {
                input = try decoder.decode(T.Input.self, from: data)
            } catch {
                throw ToolRegistryError.decodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }
            let output = try await tool.call(input, in: context)
            do {
                return try encoder.encode(output)
            } catch {
                throw ToolRegistryError.encodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }
        }
    }

    public func register<T: FoundationModels.Tool>(
        _ tool: T,
        outputSchema: JSONValue? = nil,
        annotations: ToolAnnotations? = nil,
        inputExamples: [JSONValue]? = nil
    ) where T.Output: ConvertibleToGeneratedContent {
        let descriptor = ToolDescriptor(
            tool: tool,
            outputSchema: outputSchema,
            annotations: annotations,
            inputExamples: inputExamples
        )
        let name = tool.name
        entries[name] = Entry(
            descriptor: descriptor,
            foundationTool: { _ in tool }
        ) { data, _ in
            let content: GeneratedContent
            do {
                content = try GeneratedContent(json: String(decoding: data, as: UTF8.self))
            } catch {
                throw ToolRegistryError.decodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }

            let arguments: T.Arguments
            do {
                arguments = try T.Arguments(content)
            } catch {
                throw ToolRegistryError.decodingFailed(
                    name: name,
                    detail: String(describing: error)
                )
            }

            let output = try await tool.call(arguments: arguments)
            return Data(output.generatedContent.jsonString.utf8)
        }
    }

    public func unregister(name: String) {
        entries.removeValue(forKey: name)
    }

    public func registeredNames() -> Set<String> {
        Set(entries.keys)
    }

    /// Returns the schema bundle for every registered tool.
    public func registeredDescriptors() -> [ToolDescriptor] {
        entries.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    public func registeredFoundationTools(
        context: ToolContext = ToolContext()
    ) throws -> [any FoundationModels.Tool] {
        try entries.values
            .sorted { $0.descriptor.name < $1.descriptor.name }
            .map { try $0.foundationTool(context) }
    }

    public func descriptor(for name: String) -> ToolDescriptor? {
        entries[name]?.descriptor
    }

    public func contains(name: String) -> Bool {
        entries[name] != nil
    }

    /// Returns the schema bundle for the given subset (used by PromptBuilder).
    /// An empty `names` set returns no tools.
    public func manifest(for names: Set<String>) -> [ToolDescriptor] {
        names.compactMap { entries[$0]?.descriptor }.sorted { $0.name < $1.name }
    }

    public func foundationTools(
        for names: Set<String>,
        context: ToolContext = ToolContext()
    ) throws -> [any FoundationModels.Tool] {
        try names
            .compactMap { entries[$0] }
            .sorted { $0.descriptor.name < $1.descriptor.name }
            .map { try $0.foundationTool(context) }
    }

    /// Dispatches a call by name; decodes input, encodes output.
    public func call(
        name: String,
        jsonInput: Data,
        context: ToolContext
    ) async throws -> Data {
        guard let entry = entries[name] else {
            throw ToolRegistryError.notRegistered(name)
        }
        return try await entry.call(jsonInput, context)
    }

    public func call(
        _ call: ToolCall,
        context: ToolContext
    ) async throws -> JSONValue {
        let data = try call.input.data()
        let output = try await self.call(
            name: call.name,
            jsonInput: data,
            context: context
        )
        return (try? JSONValue(data: output))
            ?? .string(String(decoding: output, as: UTF8.self))
    }
}
