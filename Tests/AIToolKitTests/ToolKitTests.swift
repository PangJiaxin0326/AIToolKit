import Foundation
import SwiftUI
import Testing
@testable import AIToolKit

private struct EchoTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var echoed: String }

    static let name = "echo"
    static let description = "Echoes input back."
    static let inputSchema = ToolSchema.object(
        properties: ["text": .string(description: "anything")],
        required: ["text"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(echoed: "\(context.viewID):\(input.text)")
    }
}

private struct UppercaseTool: Tool {
    struct Input: Codable, Sendable { var text: String }
    struct Output: Codable, Sendable { var uppercased: String }

    static let name = "uppercase"
    static let description = "Uppercases input text."
    static let inputSchema = ToolSchema.object(
        properties: ["text": .string(description: "text to uppercase")],
        required: ["text"]
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        Output(uppercased: input.text.uppercased() + (context.metadata["suffix"] ?? ""))
    }
}

private struct LabelViewTool: ViewTool {
    struct Input: Codable, Sendable { var title: String }

    static let name = "label"
    static let description = "Builds a label view."
    static let inputSchema = ToolSchema.object(
        properties: ["title": .string(description: "label title")],
        required: ["title"]
    )

    @MainActor
    func call(_ input: Input, in context: ToolContext) async throws -> Text {
        Text("\(context.viewID):\(input.title)")
    }
}

@Suite struct ToolKitRegistryTests {
    @Test func registerAndCall() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let context = ToolContext(viewID: "home")
        let input = try JSONEncoder().encode(EchoTool.Input(text: "hi"))
        let outData = try await registry.call(
            name: "echo", jsonInput: input, context: context
        )
        let output = try JSONDecoder().decode(EchoTool.Output.self, from: outData)
        #expect(output.echoed == "home:hi")
    }

    @Test func manifestSubsetting() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let subset = await registry.manifest(for: ["echo"])
        #expect(subset.map(\.name) == ["echo"])
        let empty = await registry.manifest(for: [])
        #expect(empty.isEmpty)
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistryError.self) {
            try await registry.call(
                name: "nope",
                jsonInput: Data("{}".utf8),
                context: ToolContext(viewID: "v")
            )
        }
    }

    @Test func descriptorPreservesNameAndSchema() {
        let descriptor = EchoTool.descriptor
        #expect(descriptor.name == EchoTool.name)
        #expect(descriptor.description == EchoTool.description)
        #expect(descriptor.inputSchema == EchoTool.inputSchema.json)
    }

    @Test func toolCanUseCallAsFunction() async throws {
        let output = try await EchoTool().callAsFunction(
            EchoTool.Input(text: "hi"),
            in: ToolContext(viewID: "home")
        )
        #expect(output.echoed == "home:hi")
    }

    @Test func toolRegistersAndUsesCallAsFunction() async throws {
        let registry = ToolRegistry()
        await registry.register(UppercaseTool())
        let input = try JSONEncoder().encode(UppercaseTool.Input(text: "hi"))
        let outData = try await registry.call(
            name: "uppercase",
            jsonInput: input,
            context: ToolContext(metadata: ["suffix": "!"])
        )
        let output = try JSONDecoder().decode(UppercaseTool.Output.self, from: outData)
        #expect(output.uppercased == "HI!")

        let callableOutput = try await UppercaseTool().callAsFunction(
            UppercaseTool.Input(text: "go"),
            in: ToolContext(metadata: ["suffix": "."])
        )
        #expect(callableOutput.uppercased == "GO.")
    }

    @Test func toolSchemaObjectHasRequiredFields() {
        let schema = ToolSchema.object(
            properties: ["a": .string],
            required: ["a"]
        )
        guard case let .object(fields) = schema.json else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["type"] == .string("object"))
        #expect(fields["required"] == .array([.string("a")]))
    }
}

@MainActor
@Suite struct ViewToolTests {
    @Test func viewToolRegistryCallsTool() async throws {
        let registry = ViewToolRegistry()
        registry.register(LabelViewTool())
        let input = try JSONEncoder().encode(LabelViewTool.Input(title: "Hello"))
        let view = try await registry.call(
            name: "label",
            jsonInput: input,
            context: ToolContext(viewID: "view")
        )
        _ = view
    }

    @Test func viewToolCanUseCallAsFunction() async throws {
        let tool = LabelViewTool()
        let callableView = try await tool.callAsFunction(
            LabelViewTool.Input(title: "World"),
            in: ToolContext(viewID: "view")
        )
        _ = callableView
    }
}

@Suite struct ToolContextTests {
    @Test func defaultsAreEmpty() {
        let context = ToolContext()
        #expect(context.viewID == "")
        #expect(context.metadata.isEmpty)
    }

    @Test func metadataRoundTrips() {
        let context = ToolContext(viewID: "x", metadata: ["entryID": "1"])
        #expect(context.metadata["entryID"] == "1")
    }
}
