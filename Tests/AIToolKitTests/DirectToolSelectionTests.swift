import Foundation
import FoundationModels
import Testing
@testable import AIToolKit

/// A finishing-tool stand-in with typed arguments and real validation —
/// the shape `WorkflowDirectCall.invoke` must drive end to end.
private struct DirectSendTool: Tool {
    @Generable
    struct Arguments: Sendable {
        var contactID: String
        var body: String
    }

    let name = "send_message"
    let description = "Send a short chat message to a contact."

    func call(arguments: Arguments) async throws -> String {
        guard arguments.contactID.hasPrefix("c_") else {
            throw DirectSendError(reason: "unknown contact id '\(arguments.contactID)'")
        }
        return "m_1 → \(arguments.contactID): \(arguments.body)"
    }
}

private struct DirectSendError: Error {
    let reason: String
}

@Suite struct DirectToolSelectionTests {
    @Test func parsesSelectionWithEmbeddedArguments() throws {
        let content = try GeneratedContent(json: """
        {"toolNames": ["send_message"], \
         "arguments": {"contactID": "c_1", "body": "On my way"}}
        """)
        let selection = try DirectToolSelection(content)
        #expect(selection.toolNames == ["send_message"])
        let arguments = try #require(selection.arguments)
        #expect(try arguments.value(String.self, forProperty: "contactID") == "c_1")
    }

    @Test func parsesSelectionWithoutArguments() throws {
        let content = try GeneratedContent(json: #"{"toolNames": ["send_message"]}"#)
        let selection = try DirectToolSelection(content)
        #expect(selection.toolNames == ["send_message"])
        #expect(selection.arguments == nil)
    }

    @Test func nullAndNonObjectArgumentsAreDropped() throws {
        for json in [
            #"{"toolNames": ["send_message"], "arguments": null}"#,
            #"{"toolNames": ["send_message"], "arguments": "c_1"}"#,
        ] {
            let selection = try DirectToolSelection(GeneratedContent(json: json))
            #expect(selection.arguments == nil, "arguments survived: \(json)")
        }
    }

    @Test func validatesAgainstCatalogueLikePlainSelection() throws {
        let selection = DirectToolSelection(toolNames: ["Send_Message", "made_up"])
        #expect(selection.validated(against: ["send_message", "schedule_event"])
            == ["send_message"])
    }

    @Test func invokeDecodesTypedArgumentsAndRunsTheTool() async throws {
        let arguments = try GeneratedContent(
            json: #"{"contactID": "c_1", "body": "On my way"}"#
        )
        let output = try await WorkflowDirectCall.invoke(
            DirectSendTool(), arguments: arguments
        )
        #expect(output == "m_1 → c_1: On my way")
    }

    @Test func invokeThrowsOnMissingRequiredProperty() async throws {
        let arguments = try GeneratedContent(json: #"{"contactID": "c_1"}"#)
        await #expect(throws: (any Error).self) {
            try await WorkflowDirectCall.invoke(DirectSendTool(), arguments: arguments)
        }
    }

    @Test func invokePropagatesTheToolsOwnValidation() async throws {
        let arguments = try GeneratedContent(
            json: #"{"contactID": "Bob Singh", "body": "hi"}"#
        )
        await #expect(throws: DirectSendError.self) {
            try await WorkflowDirectCall.invoke(DirectSendTool(), arguments: arguments)
        }
    }
}
