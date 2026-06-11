import Foundation
import FoundationModels
import SwiftUI
import Testing
@testable import AIToolKit

private struct EchoTool: Tool {
    @Generable
    struct Arguments { var text: String }

    @Generable
    struct Output { var echoed: String }

    let name = "echo"
    let description = "Echoes input back."

    func call(arguments: Arguments) async throws -> Output {
        Output(echoed: arguments.text)
    }
}

private struct UppercaseTool: Tool {
    @Generable
    struct Arguments { var text: String }

    @Generable
    struct Output { var uppercased: String }

    let name = "uppercase"
    let description = "Uppercases input text."

    func call(arguments: Arguments) async throws -> Output {
        Output(uppercased: arguments.text.uppercased())
    }
}

private struct SeedTool: Tool {
    @Generable
    struct Arguments { var value: String }

    @Generable
    struct Output { var value: String }

    let name = "seed"
    let description = "Returns a seed value."

    func call(arguments: Arguments) async throws -> Output {
        Output(value: arguments.value)
    }
}

private struct JoinTool: Tool {
    @Generable
    struct Arguments { var left: String; var right: String }

    @Generable
    struct Output { var combined: String }

    let name = "join"
    let description = "Joins two strings."

    func call(arguments: Arguments) async throws -> Output {
        Output(combined: "\(arguments.left)-\(arguments.right)")
    }
}

@Generable
private struct StringValueOutput {
    var value: String
}

private struct LabelViewTool: ViewTool {
    @Generable
    struct Arguments { var title: String }

    let name = "label"
    let description = "Builds a label view."

    @MainActor
    func call(arguments: Arguments) async throws -> Text {
        Text(arguments.title)
    }
}

private func jsonData(_ value: some ConvertibleToGeneratedContent) -> Data {
    Data(value.generatedContent.jsonString.utf8)
}

@Suite struct ToolDispatchTests {
    @Test func descriptorsDeriveFromHeterogeneousOfficialTools() {
        let tools: [any Tool] = [UppercaseTool(), EchoTool()]
        let descriptors = tools
            .map { ToolDescriptor(tool: $0) }
            .sorted { $0.name < $1.name }
        #expect(descriptors.map(\.name) == ["echo", "uppercase"])
        #expect(descriptors.allSatisfy { $0.outputSchema != nil })
    }

    @Test func descriptorPreservesNameAndSchema() throws {
        let tool = EchoTool()
        let descriptor = tool.descriptor
        #expect(descriptor.name == tool.name)
        #expect(descriptor.description == tool.description)
        #expect(try descriptor.argumentsSchema.jsonString().contains("\"text\""))
        guard let outputSchema = descriptor.outputSchema else {
            Issue.record("descriptor must include output schema")
            return
        }
        #expect(try outputSchema.jsonString().contains("\"echoed\""))
    }

    @Test func toolCanUseCallAsFunction() async throws {
        let output = try await EchoTool().callAsFunction(
            EchoTool.Arguments(text: "hi")
        )
        #expect(output.echoed == "hi")
    }

    @Test func generationSchemaObjectHasRequiredFields() throws {
        let schema = try GeneratedContent(json: EchoTool.Arguments.generationSchema.jsonString())
        guard case let .structure(fields, _) = schema.kind else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["type"]?.stringValue == "object")
        #expect(fields["required"]?.allStrings == ["text"])
    }

    @Test func generationSchemaDisallowsAdditionalProperties() throws {
        let schema = try GeneratedContent(json: EchoTool.Arguments.generationSchema.jsonString())
        guard case let .structure(fields, _) = schema.kind else {
            Issue.record("schema must be an object")
            return
        }
        #expect(fields["additionalProperties"]?.boolValue == false)
    }

    @Test func generatedContentIntValueRejectsUnsafeNumbers() {
        #expect(GeneratedContent.number(42.0).intValue == 42)
        #expect(GeneratedContent.number(42.5).intValue == nil)
        #expect(GeneratedContent.number(Double.greatestFiniteMagnitude).intValue == nil)
    }

}

@MainActor
@Suite struct ViewToolTests {
    @Test func viewToolRegistryCallsTool() async throws {
        let registry = ViewToolRegistry()
        registry.register(LabelViewTool())
        let input = jsonData(LabelViewTool.Arguments(title: "Hello"))
        let view = try await registry.call(name: "label", jsonArguments: input)
        _ = view
    }

    @Test func viewToolCanUseCallAsFunction() async throws {
        let tool = LabelViewTool()
        let callableView = try await tool.callAsFunction(
            LabelViewTool.Arguments(title: "World")
        )
        _ = callableView
    }
}
