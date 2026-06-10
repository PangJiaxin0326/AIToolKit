import Foundation
import FoundationModels
import Testing
@testable import AIToolKit

private struct FindContactTool: Tool {
    @Generable
    struct Arguments { var query: String }

    @Generable
    struct Output {
        var contactID: String
        var displayName: String
    }

    let name = "find_contact"
    let description = "Finds a contact by (partial) name."

    func call(arguments: Arguments) async throws -> Output {
        Output(contactID: "c-42", displayName: "Bob Singh")
    }
}

private struct ShareDocumentTool: Tool {
    @Generable
    struct Arguments {
        var contactID: String
        var documentURL: String
        var note: String
    }

    @Generable
    struct Output {
        var delivered: Bool
        var receipt: String
    }

    let name = "share_document"
    let description = "Shares a document with a contact, with a short note."

    func call(arguments: Arguments) async throws -> Output {
        Output(
            delivered: true,
            receipt: "shared \(arguments.documentURL) with \(arguments.contactID): \(arguments.note)"
        )
    }
}

private struct OpenDocumentsHarvester: ContextHarvesting {
    let openDocuments: [HarvestedCandidate]

    func harvest(_ slots: [WorkflowContextSlot]) async -> ContextPacket {
        ContextPacket(slots: slots.map { slot in
            HarvestedSlot(
                slotID: slot.slotID,
                source: slot.source,
                status: openDocuments.isEmpty ? .missing : .resolved,
                candidates: openDocuments,
                required: slot.required
            )
        })
    }
}

/// Tests the unified `WorkflowTool`: one official tool covering the one-shot
/// path, the auto-bound path, and the two-round binding exchange carried by
/// the ordinary tool loop. No LLM / no network — model emissions are
/// simulated with literal JSON.
struct WorkflowToolTests {
    private static func document(
        _ id: String, _ label: String, url: String, isCurrent: Bool
    ) -> HarvestedCandidate {
        HarvestedCandidate(
            candidateID: id, label: label, kind: "document",
            value: .string(url), isCurrent: isCurrent
        )
    }

    private func makeTool(
        documents: [HarvestedCandidate]? = nil
    ) -> WorkflowTool {
        WorkflowTool(
            tools: [FindContactTool(), ShareDocumentTool()],
            harvester: documents.map(OpenDocumentsHarvester.init(openDocuments:)),
            sources: ["open_documents"]
        )
    }

    private func emit(_ json: String) throws -> GeneratedContent {
        try GeneratedContent(json: json)
    }

    // MARK: One-shot path

    @Test func selfContainedPlanExecutesInOneCall() async throws {
        let tool = makeTool()
        let output = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"find_bob","tool":"find_contact","input":{"query":"Bob Singh"}},
          {"id":"share","tool":"share_document","input":{
             "contactID":{"$ref":{"source":"node","node":"find_bob","path":"/contactID"}},
             "documentURL":"file:///Docs/Agenda.pages",
             "note":"Hi Bob."}}
        ]}
        """))
        #expect(output.optionalString("status") == "completed")
        let receipt = output.property("result")?.optionalString("receipt")
        #expect(receipt?.contains("c-42") == true)
    }

    @Test func invalidPlanReturnsStructuredErrorInsteadOfThrowing() async throws {
        let tool = makeTool()
        let output = try await tool.call(arguments: emit("""
        {"nodes":[{"id":"x","tool":"no_such_tool","input":{}}]}
        """))
        #expect(output.optionalString("status") == "invalid_plan")
        #expect(output.optionalString("instructions") != nil)
    }

    // MARK: Auto-bind path (two rounds collapsed into one call)

    @Test func deterministicSlotAutoBindsInOneCall() async throws {
        let tool = makeTool(documents: [
            Self.document(
                "doc_1", "Q3 Report.pages (current)",
                url: "file:///Docs/Q3.pages", isCurrent: true
            ),
        ])
        let output = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"find_bob","tool":"find_contact","input":{"query":"Bob"}},
          {"id":"share","tool":"share_document","input":{
             "contactID":{"$ref":{"source":"node","node":"find_bob","path":"/contactID"}},
             "documentURL":{"$slot":"current_doc"},
             "note":"Here is {{current_doc}}."}}
        ],
        "context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
        """))
        #expect(output.optionalString("status") == "completed")
        let receipt = output.property("result")?.optionalString("receipt")
        #expect(receipt?.contains("file:///Docs/Q3.pages") == true)
        #expect(receipt?.contains("Q3 Report.pages") == true)
    }

    // MARK: Two-round path via the tool loop

    @Test func ambiguousSlotNeedsBindingThenBindResolves() async throws {
        let tool = makeTool(documents: [
            Self.document("doc_1", "Q3 Report.pages (open)", url: "file:///Docs/Q3.pages", isCurrent: false),
            Self.document("doc_2", "Trip Plan.pages (open)", url: "file:///Docs/Trip.pages", isCurrent: false),
        ])
        let round1 = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"find_bob","tool":"find_contact","input":{"query":"Bob"}},
          {"id":"share","tool":"share_document","input":{
             "contactID":{"$ref":{"source":"node","node":"find_bob","path":"/contactID"}},
             "documentURL":{"$slot":"current_doc"},
             "note":"Here is {{current_doc}}."}}
        ],
        "context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
        """))
        #expect(round1.optionalString("status") == "needs_binding")
        #expect(round1.optionalString("context")?.contains("doc_2") == true)
        let planID = try #require(round1.optionalString("plan_id"))

        let round2 = try await tool.call(arguments: emit("""
        {"plan_id":"\(planID)","nodes":[
          {"id":"find_bob","tool":"find_contact","input":{"query":"Bob"}},
          {"id":"share","tool":"share_document","input":{
             "contactID":{"$ref":{"source":"node","node":"find_bob","path":"/contactID"}},
             "documentURL":{"$bind":"doc_2"},
             "note":"Here is Trip Plan.pages."}}
        ]}
        """))
        #expect(round2.optionalString("status") == "completed")
        let receipt = round2.property("result")?.optionalString("receipt")
        #expect(receipt?.contains("file:///Docs/Trip.pages") == true)
    }

    @Test func invalidBindingKeepsPendingPlanForRetry() async throws {
        let tool = makeTool(documents: [
            Self.document("doc_1", "A.pages (open)", url: "file:///A.pages", isCurrent: false),
            Self.document("doc_2", "B.pages (open)", url: "file:///B.pages", isCurrent: false),
        ])
        let round1 = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$slot":"current_doc"},
             "note":"Here."}}
        ],
        "context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
        """))
        let planID = try #require(round1.optionalString("plan_id"))

        // Bad bind: unknown candidate → structured error, plan stays pending.
        let badBind = try await tool.call(arguments: emit("""
        {"plan_id":"\(planID)","nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$bind":"doc_999"},
             "note":"Here."}}
        ]}
        """))
        #expect(badBind.optionalString("status") == "invalid_binding")

        // Retry with a valid candidate succeeds against the same plan.
        let retry = try await tool.call(arguments: emit("""
        {"plan_id":"\(planID)","nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$bind":"doc_1"},
             "note":"Here."}}
        ]}
        """))
        #expect(retry.optionalString("status") == "completed")
    }

    @Test func bindWithoutPendingPlanReturnsStaleBinding() async throws {
        let tool = makeTool(documents: [])
        let output = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$bind":"doc_1"},
             "note":"Here."}}
        ]}
        """))
        #expect(output.optionalString("status") == "stale_binding")
    }

    @Test func missingRequiredSlotReturnsNeedsClarification() async throws {
        let tool = makeTool(documents: [])
        let output = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$slot":"current_doc"},
             "note":"Here."}}
        ],
        "context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
        """))
        #expect(output.optionalString("status") == "needs_clarification")
        #expect(output.property("missing_slots")?.allStrings == ["current_doc"])
    }

    @Test func slotPlanWithoutHarvesterIsRejected() async throws {
        let tool = makeTool(documents: nil)
        let output = try await tool.call(arguments: emit("""
        {"nodes":[
          {"id":"share","tool":"share_document","input":{
             "contactID":"c-42",
             "documentURL":{"$slot":"current_doc"},
             "note":"Here."}}
        ],
        "context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
        """))
        #expect(output.optionalString("status") == "invalid_plan")
    }

    // MARK: Contract surface

    @Test func parametersSchemaEnumeratesLeafToolsAndRelationships() throws {
        let withSlots = makeTool(documents: [])
        let schema = try withSlots.parameters.jsonString()
        #expect(schema.contains("find_contact"))
        #expect(schema.contains("share_document"))
        #expect(schema.contains("context_slots"))
        #expect(schema.contains("plan_id"))

        let withoutSlots = makeTool(documents: nil)
        let lean = try withoutSlots.parameters.jsonString()
        #expect(!lean.contains("context_slots"))
        #expect(!lean.contains("plan_id"))
    }

    @Test func nestedWorkflowToolIsExcludedFromItsOwnContract() throws {
        let nested = WorkflowTool(tools: [FindContactTool()])
        let tool = WorkflowTool(tools: [FindContactTool(), nested])
        let schema = try tool.parameters.jsonString()
        #expect(!schema.contains(WorkflowSpec.toolName))
        #expect(!tool.instructions().contains("- \(WorkflowSpec.toolName):"))
    }

    @Test func instructionsIncludeSlotGuidanceOnlyWithHarvester() {
        let withSlots = makeTool(documents: [])
        #expect(withSlots.instructions().contains("$slot"))
        #expect(withSlots.instructions().contains("open_documents"))

        let withoutSlots = makeTool(documents: nil)
        #expect(!withoutSlots.instructions().contains("$slot"))
    }

    @Test func onResultObserverReceivesFullWorkflowResult() async throws {
        actor Captured {
            var results: [WorkflowResult] = []
            func append(_ result: WorkflowResult) { results.append(result) }
        }
        let captured = Captured()
        let tool = WorkflowTool(
            tools: [FindContactTool()],
            onResult: { await captured.append($0) }
        )
        let output = try await tool.call(arguments: emit("""
        {"nodes":[{"id":"find_bob","tool":"find_contact","input":{"query":"Bob"}}]}
        """))
        #expect(output.optionalString("status") == "completed")
        let results = await captured.results
        #expect(results.count == 1)
        #expect(results.first?.nodeOutputs.keys.contains("find_bob") == true)
    }
}
