import Foundation
import FoundationModels

/// Process-wide tool registry. Allows per-view subsetting via the tool-name
/// set the host caller supplies (AIKitCapability's `ViewContext.toolNames`
/// drives this in the journal app).
public actor ToolRegistry {
    public static let shared = ToolRegistry()

    private struct Entry {
        let descriptor: ToolDescriptor
        let call: @Sendable (Data) async throws -> Data
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register<T: FoundationModels.Tool>(_ tool: T)
    where T.Arguments: Generable, T.Output: Generable {
        let descriptor = tool.descriptor
        let name = tool.name
        entries[name] = Entry(descriptor: descriptor) { data in
            let arguments: T.Arguments
            do {
                let content = try GeneratedContent(
                    json: String(decoding: data, as: UTF8.self)
                )
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

    /// Dispatches a call by name; decodes arguments and encodes output.
    public func call(
        name: String,
        jsonArguments: Data
    ) async throws -> Data {
        guard let entry = entries[name] else {
            throw ToolRegistryError.notRegistered(name)
        }
        return try await entry.call(jsonArguments)
    }

    public func call(_ call: ToolCall) async throws -> GeneratedContent {
        let data = call.arguments.data()
        let output = try await self.call(name: call.name, jsonArguments: data)
        return try GeneratedContent(data: output)
    }
}
