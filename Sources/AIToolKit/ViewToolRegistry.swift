import Foundation
import FoundationModels
import SwiftUI

/// Process-wide registry for `ViewTool`s. Data tools go straight into a
/// `LanguageModelSession` (or a `WorkflowTool`), but view tools cannot — their
/// output is a SwiftUI view, which is not prompt-representable — so they keep
/// a registry whose dispatch path produces an `AnyView` the host renders
/// directly.
///
/// Main-actor-isolated: SwiftUI view construction is main-isolated, and the
/// registry stays in step so registration and dispatch share the same
/// isolation as the rendering it produces.
@MainActor
public final class ViewToolRegistry {
    public static let shared = ViewToolRegistry()

    private struct Entry {
        let descriptor: ToolDescriptor
        let call: (Data) async throws -> AnyView
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register<T: ViewTool>(_ tool: T) where T.Arguments: Generable {
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
            let view = try await tool.call(arguments: arguments)
            return AnyView(view)
        }
    }

    public func unregister(name: String) {
        entries.removeValue(forKey: name)
    }

    public func registeredNames() -> Set<String> {
        Set(entries.keys)
    }

    public func registeredDescriptors() -> [ToolDescriptor] {
        entries.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    /// Returns the descriptors for the given subset (used by PromptBuilder).
    /// An empty `names` set returns no tools.
    public func manifest(for names: Set<String>) -> [ToolDescriptor] {
        names.compactMap { entries[$0]?.descriptor }.sorted { $0.name < $1.name }
    }

    /// Dispatch a call by name; decode the JSON arguments, run the tool,
    /// erase the resulting view to `AnyView`.
    public func call(
        name: String,
        jsonArguments: Data
    ) async throws -> AnyView {
        guard let entry = entries[name] else {
            throw ToolRegistryError.notRegistered(name)
        }
        return try await entry.call(jsonArguments)
    }
}
