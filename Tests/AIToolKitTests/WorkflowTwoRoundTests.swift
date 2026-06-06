import Foundation
import Testing
@testable import AIToolKit

/// Tests the pure two-round compiler: value algebra, plan validation, auto-bind,
/// and binding resolution. No LLM / no network.
struct WorkflowTwoRoundTests {
    // A small packet: a single foreground contact + a single open document.
    private func packet(
        contactCurrent: Bool = true,
        contactCount: Int = 1,
        withDoc: Bool = true
    ) -> ContextPacket {
        var slots: [HarvestedSlot] = []
        let contacts = (0..<contactCount).map { i in
            HarvestedCandidate(
                candidateID: "ctx_current_contact_\(i)",
                label: "Person \(i) (open in contact view)",
                kind: "contact_id",
                value: .string("c_person_\(i)"),
                isCurrent: contactCurrent && i == 0
            )
        }
        slots.append(HarvestedSlot(slotID: "current_contact", source: "current_contact",
                                   status: contacts.isEmpty ? .missing : .resolved,
                                   candidates: contacts, required: true))
        if withDoc {
            slots.append(HarvestedSlot(
                slotID: "foreground_document", source: "foreground_document", status: .resolved,
                candidates: [HarvestedCandidate(
                    candidateID: "ctx_foreground_document_0",
                    label: "FY26 Budget Memo (open in editor)",
                    kind: "document_id", value: .string("d_budget"), isCurrent: true)],
                required: true))
        }
        return ContextPacket(slots: slots)
    }

    private let sendSchema = ToolSchema.strictObject(
        properties: ["contactID": .string, "body": .string],
        required: ["contactID", "body"]).json

    // MARK: value algebra

    @Test func slotAndBindAndLabelDetection() {
        let input: JSONValue = .object([
            "contactID": .object(["$slot": "current_contact"]),
            "body": .string("Reminder about {{foreground_document}}."),
        ])
        #expect(TwoRoundValue.slotIDs(in: input) == ["current_contact"])
        #expect(TwoRoundValue.labelTokens(in: input) == ["foreground_document"])
        #expect(TwoRoundValue.bindIDs(in: input).isEmpty)
    }

    @Test func resolveLabelsSubstitutesAndLeavesUnknown() {
        let v: JSONValue = .string("A {{doc}} and {{missing}}")
        let out = TwoRoundValue.resolveLabels(in: v) { $0 == "doc" ? "Memo" : nil }
        #expect(out == .string("A Memo and {{missing}}"))
    }

    @Test func pruneDropsStrayKeys() {
        let input: JSONValue = .object([
            "contactID": .string("c1"), "body": .string("hi"), "message": .string("leak"),
        ])
        let pruned = TwoRoundValue.prune(input, toInputSchema: sendSchema)
        #expect(pruned == .object(["contactID": .string("c1"), "body": .string("hi")]))
    }

    // MARK: plan validation

    @Test func validatePlanRejectsUndeclaredLabelToken() throws {
        // {{foreground_document}} used but NOT declared → must be rejected, not
        // silently leaked as literal text (the bug this guards).
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": "current_contact"]),
                    "body": .string("About {{foreground_document}}"),
                ])),
            ],
            contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")]
        )
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.validatePlan(plan, availableTools: ["send_message"])
        }
    }

    @Test func validatePlanRejectsForwardRef() {
        let plan = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "a", tool: "send_message", input: .object([
                "contactID": .object(["$ref": .object([
                    "source": .string("node"), "node": .string("b"), "path": .string("/id")])]),
                "body": .string("x"),
            ])),
            WorkflowPlanNode(id: "b", tool: "find_contact", input: .object(["query": .string("x")])),
        ])
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.validatePlan(plan, availableTools: ["send_message", "find_contact"])
        }
    }

    // MARK: auto-bind

    @Test func autoBindResolvesUnambiguousSlotAndLabel() throws {
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": "current_contact"]),
                    "body": .string("About {{foreground_document}}"),
                ])),
            ],
            contextSlots: [
                WorkflowContextSlot(slotID: "current_contact", source: "current_contact"),
                WorkflowContextSlot(slotID: "foreground_document", source: "foreground_document"),
            ]
        )
        let nodes = try #require(WorkflowTwoRoundCompiler.autoBind(plan: plan, packet: packet()))
        #expect(nodes[0].input == .object([
            "contactID": .string("c_person_0"),
            "body": .string("About FY26 Budget Memo"),
        ]))
    }

    @Test func autoBindDefersOnAmbiguity() {
        // Two contacts, none current → not deterministic → defer to Binder.
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": "current_contact"]), "body": .string("hi"),
                ])),
            ],
            contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")]
        )
        let ambiguous = packet(contactCurrent: false, contactCount: 2, withDoc: false)
        #expect(WorkflowTwoRoundCompiler.autoBind(plan: plan, packet: ambiguous) == nil)
    }

    @Test func autoBindDefersWhenSlotDeclaredButUnreferenced() {
        // foreground_document declared (for authoring) but never referenced →
        // free-text authoring signal → defer to Binder.
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": "current_contact"]),
                    "body": .string("a reminder"),
                ])),
            ],
            contextSlots: [
                WorkflowContextSlot(slotID: "current_contact", source: "current_contact"),
                WorkflowContextSlot(slotID: "foreground_document", source: "foreground_document"),
            ]
        )
        #expect(WorkflowTwoRoundCompiler.autoBind(plan: plan, packet: packet()) == nil)
    }

    // MARK: binding resolution

    @Test func resolveBindingValidatesShapeAndResolves() throws {
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": "current_contact"]), "body": .string("hi"),
            ])),
        ], contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")])
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$bind": "ctx_current_contact_0"]), "body": .string("hi"),
            ])),
        ])
        let resolved = try WorkflowTwoRoundCompiler.resolveBinding(binding, plan: plan, packet: packet())
        #expect(resolved[0].input == .object(["contactID": .string("c_person_0"), "body": .string("hi")]))
    }

    @Test func resolveBindingRejectsCandidateFromWrongSlot() {
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": "current_contact"]), "body": .string("hi"),
            ])),
        ], contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")])
        // Binds the document candidate into the contact field → must be rejected.
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$bind": "ctx_foreground_document_0"]), "body": .string("hi"),
            ])),
        ])
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.resolveBinding(binding, plan: plan, packet: packet())
        }
    }

    @Test func resolveBindingRejectsGraphMutation() {
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object(["body": .string("hi")])),
        ], contextSlots: [])
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object(["body": .string("hi")])),
            WorkflowPlanNode(id: "extra", tool: "send_message", input: .object(["body": .string("x")])),
        ])
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.resolveBinding(binding, plan: plan, packet: packet())
        }
    }

    @Test func resolveBindingRejectsAmbiguousResidualLabelToken() {
        let plan = WorkflowPlan(
            outcome: .requiresBinding,
            nodes: [
                WorkflowPlanNode(
                    id: "send",
                    tool: "send_message",
                    input: .object(["body": .string("About {{foreground_document}}")])
                ),
            ],
            contextSlots: [
                WorkflowContextSlot(slotID: "foreground_document", source: "foreground_document"),
            ]
        )
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(
                id: "send",
                tool: "send_message",
                input: .object(["body": .string("About {{foreground_document}}")])
            ),
        ])
        let ambiguousPacket = ContextPacket(slots: [
            HarvestedSlot(
                slotID: "foreground_document",
                source: "foreground_document",
                status: .resolved,
                candidates: [
                    HarvestedCandidate(
                        candidateID: "ctx_foreground_document_0",
                        label: "Budget Memo",
                        kind: "document_id",
                        value: .string("d_budget"),
                        isCurrent: false
                    ),
                    HarvestedCandidate(
                        candidateID: "ctx_foreground_document_1",
                        label: "Roadmap Memo",
                        kind: "document_id",
                        value: .string("d_roadmap"),
                        isCurrent: false
                    ),
                ],
                required: true
            ),
        ])
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.resolveBinding(
                binding,
                plan: plan,
                packet: ambiguousPacket
            )
        }
    }

    @Test func renderPlanNodesEscapesJSONScalars() throws {
        let rendered = WorkflowTwoRoundPrompt.renderPlanNodes([
            WorkflowPlanNode(
                id: "send",
                tool: "send_\"message",
                input: .object(["body": .string("Line 1\nLine 2 \"quoted\"")])
            ),
        ])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(rendered.utf8))
        guard case .object(let object) = value,
              case .object(let input)? = object["input"]
        else {
            Issue.record("rendered node must be valid JSON object")
            return
        }
        #expect(object["id"] == .string("send"))
        #expect(object["tool"] == .string("send_\"message"))
        #expect(input["body"] == .string("Line 1\nLine 2 \"quoted\""))
    }

    // MARK: plan cache

    @Test func planCacheHitsOnRepeatIntent() async {
        let cache = WorkflowPlanCache()
        let key = WorkflowPlanCache.key(intent: "  Send  Bob a Hello ", toolNames: ["send_message"])
        let key2 = WorkflowPlanCache.key(intent: "send bob a hello", toolNames: ["send_message"])
        #expect(key == key2)  // normalized
        #expect(await cache.lookup(key) == nil)
        await cache.store(WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "a", tool: "send_message", input: .object([:])),
        ]), for: key)
        #expect(await cache.lookup(key2) != nil)
        #expect(await cache.hits == 1)
        #expect(await cache.misses == 1)
    }

    // MARK: effective outcome

    @Test func effectiveOutcomeFromStructure() {
        let withSlot = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "a", tool: "t", input: .object(["x": .object(["$slot": "s"])])),
        ], contextSlots: [WorkflowContextSlot(slotID: "s", source: "src")])
        #expect(withSlot.effectiveOutcome == .requiresBinding)  // overrides mislabel

        let plain = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "a", tool: "t", input: .object(["x": .string("lit")])),
        ])
        #expect(plain.effectiveOutcome == .selfContained)

        let withLabelToken = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(
                id: "a",
                tool: "t",
                input: .object(["x": .string("About {{foreground_document}}")])
            ),
        ])
        #expect(withLabelToken.effectiveOutcome == .requiresBinding)
    }
}
