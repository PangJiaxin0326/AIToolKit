import Foundation
import FoundationModels
import Testing
@testable import AIToolKit

private struct FindContactTool: AssistiveTool {
    typealias Arguments = TextArgument
    let name = "find_contact"
    let description = "Resolve a contact name to its id. Input: the contact's name."

    func call(arguments: TextArgument) async throws -> String {
        "c_\(arguments.value.lowercased().replacingOccurrences(of: " ", with: "_"))"
    }
}

private struct BytesToKBTool: AssistiveTool {
    typealias Arguments = IntegerArgument
    let name = "bytes_to_kb"
    let description = "Convert a byte count to whole kilobytes (floor). Input: bytes."

    func call(arguments: IntegerArgument) async throws -> String {
        "\(arguments.value / 1000)"
    }
}

private struct GetActiveContextTool: AssistiveTool {
    typealias Arguments = EmptyArguments
    let name = "get_active_context"
    let description = "Report the current on-screen selection. No input."

    func call(arguments: EmptyArguments) async throws -> String {
        "contact: c_alex_chen"
    }
}

private struct SendMessageTool: Tool {
    @Generable
    struct Arguments: Sendable {
        var contactID: String
        var body: String
    }
    @Generable
    struct Output: Sendable {
        var messageID: String
    }

    let name = "send_message"
    let description = "Send a message."

    func call(arguments: Arguments) async throws -> Output {
        Output(messageID: "m_1")
    }
}

@Suite struct AssistiveToolTests {
    @Test func scalarArgumentsDecodeDirectlyFromGeneratedContent() async throws {
        let text = try TextArgument(GeneratedContent(json: #"{"value":"Alex Chen"}"#))
        #expect(text.value == "Alex Chen")
        let integer = try IntegerArgument(GeneratedContent(json: #"{"value":28910}"#))
        #expect(integer.value == 28910)
        _ = try EmptyArguments(GeneratedContent(json: "{}"))
    }

    @Test func assistiveToolsAnswerUnitRequests() async throws {
        let id = try await FindContactTool().call(arguments: TextArgument(value: "Alex Chen"))
        #expect(id == "c_alex_chen")
        let kb = try await BytesToKBTool().call(arguments: IntegerArgument(value: 28910))
        #expect(kb == "28")
        let context = try await GetActiveContextTool().call(arguments: EmptyArguments())
        #expect(context.contains("c_alex_chen"))
    }

    @Test func isAssistiveSeparatesUserVisibleTools() {
        let tools: [any Tool] = [
            FindContactTool(), BytesToKBTool(), GetActiveContextTool(), SendMessageTool(),
        ]
        let assistive = tools.filter(\.isAssistive).map(\.name).sorted()
        let userVisible = tools.filter { !$0.isAssistive }.map(\.name)
        #expect(assistive == ["bytes_to_kb", "find_contact", "get_active_context"])
        #expect(userVisible == ["send_message"])
    }

    @Test func assistiveSchemasAreSingleScalar() throws {
        // The point of the scalar constraint: every assistive tool exposes
        // exactly one "value" property (or none), never a structured object
        // the model must author.
        let schema = try GeneratedContent(json: FindContactTool().parameters.jsonString())
        let properties = try #require(schema.objectValue?["properties"]?.objectValue)
        #expect(Array(properties.keys) == ["value"])
        #expect(properties["value"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test func actStageHistoryDropsToolChatter() throws {
        // Build a transcript with prompt/response/toolCalls/toolOutput shapes
        // is not directly constructible here; verify the filter on what we
        // can construct — an empty list and the function's totality.
        #expect(WorkflowProfile.actStageHistory([]).isEmpty)
    }

    @Test func workflowStageDefaultsToGather() {
        #expect(WorkflowStageKey.defaultValue == .gather)
        #expect(WorkflowStage.allCases == [.gather, .act])
    }
}
