import Foundation
import FoundationModels
import Testing
@testable import AIToolKit

/// Captures the resolved input the executor handed a node.
private actor SeenBody {
    private(set) var value: GeneratedContent?
    func record(_ input: GeneratedContent) { value = input }
}

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

    // MARK: value algebra

    @Test func slotAndBindAndLabelDetection() {
        let input: GeneratedContent = .object([
            "contactID": .object(["$slot": .string("current_contact")]),
            "body": .string("Reminder about {{foreground_document}}."),
        ])
        #expect(TwoRoundValue.slotIDs(in: input) == ["current_contact"])
        #expect(TwoRoundValue.labelTokens(in: input) == ["foreground_document"])
        #expect(TwoRoundValue.bindIDs(in: input).isEmpty)
    }

    @Test func resolveLabelsSubstitutesAndLeavesUnknown() {
        let v: GeneratedContent = .string("A {{doc}} and {{missing}}")
        let out = TwoRoundValue.resolveLabels(in: v) { $0 == "doc" ? "Memo" : nil }
        #expect(out == .string("A Memo and {{missing}}"))
    }

    // MARK: plan validation

    @Test func validatePlanRejectsUndeclaredLabelToken() throws {
        // {{foreground_document}} used but NOT declared → must be rejected, not
        // silently leaked as literal text (the bug this guards).
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": .string("current_contact")]),
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

    // MARK: normalization (deterministic repairs)

    @Test func normalizeReordersForwardRefTopologically() throws {
        let plan = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "a", tool: "send_message", input: .object([
                "contactID": .object(["$ref": .string("b/id")]),
                "body": .string("x"),
            ])),
            WorkflowPlanNode(id: "b", tool: "find_contact", input: .object(["query": .string("x")])),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(plan)
        #expect(normalized.nodes.map(\.id) == ["b", "a"])
        try WorkflowTwoRoundCompiler.validatePlan(
            normalized, availableTools: ["send_message", "find_contact"]
        )
    }

    @Test func normalizeLeavesValidOrderUntouched() {
        let plan = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "b", tool: "find_contact", input: .object(["query": .string("x")])),
            WorkflowPlanNode(id: "a", tool: "send_message", input: .object([
                "contactID": .object(["$ref": .string("b/id")]),
                "body": .string("x"),
            ])),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(plan)
        #expect(normalized.nodes == plan.nodes)
    }

    @Test func normalizeDeclaresSlotNamedAfterRecognizedSource() throws {
        // A planner inlines the declaration: uses {"$slot":"current_contact"}
        // (a recognized source name) without declaring it. The only possible
        // reading is {slot_id: X, source: X}.
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("current_contact")]),
                "body": .string("hi"),
            ])),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(
            plan, recognizedSources: ["current_contact", "foreground_document"]
        )
        #expect(normalized.contextSlots.map(\.slotID) == ["current_contact"])
        try WorkflowTwoRoundCompiler.validatePlan(
            normalized, availableTools: ["send_message"],
            recognizedSources: ["current_contact", "foreground_document"]
        )
        // A non-source undeclared slot stays undeclared (validate rejects).
        let bad = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("whatever")]),
                "body": .string("hi"),
            ])),
        ])
        let badNormalized = WorkflowTwoRoundCompiler.normalizePlan(
            bad, recognizedSources: ["current_contact"]
        )
        #expect(badNormalized.contextSlots.isEmpty)
    }

    @Test func normalizeRewritesNodePathSlotToRef() throws {
        // A weak planner mis-tags a node reference as a slot:
        // {"$slot":"search/hits/0/title"} where "search" is a plan node.
        let plan = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "search", tool: "find_contact", input: .object(["query": .string("x")])),
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("search/contactID")]),
                "body": .string("x"),
            ])),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(plan)
        let input = normalized.nodes[1].input
        #expect(TwoRoundValue.slotIDs(in: input).isEmpty)
        #expect(TwoRoundValue.nodeRefIDs(in: input) == ["search"])
        try WorkflowTwoRoundCompiler.validatePlan(
            normalized, availableTools: ["send_message", "find_contact"]
        )
        // A genuine slot id (no node prefix) is untouched.
        #expect(normalized.effectiveOutcome == .selfContained)
    }

    // MARK: `{{node/path}}` text tokens (node-output interpolation)

    @Test func normalizeCanonicalizesRefSpelledTextTokens() throws {
        // Observed pro emissions: a node reference spelled inside a {{ }}
        // token, in $ref-prefixed or dotted form. Each has exactly one
        // reading; all canonicalize to {{d1/hits/0/title}}.
        for spelled in ["{{$ref.d1/hits/0/title}}", "{{$ref:d1/hits/0/title}}",
                        "{{$ref.d1.hits.0.title}}", "{{d1.hits.0.title}}"] {
            let plan = WorkflowPlan(outcome: .selfContained, nodes: [
                WorkflowPlanNode(id: "d1", tool: "search_documents",
                                 input: .object(["query": .string("x")])),
                WorkflowPlanNode(id: "s1", tool: "send_message", input: .object([
                    "contactID": .string("c_1"),
                    "body": .string("Reminder: \(spelled)."),
                ])),
            ])
            let normalized = WorkflowTwoRoundCompiler.normalizePlan(plan)
            #expect(normalized.nodes[1].input.optionalString("body")
                == "Reminder: {{d1/hits/0/title}}.")
            try WorkflowTwoRoundCompiler.validatePlan(
                normalized, availableTools: ["send_message", "search_documents"]
            )
        }
    }

    @Test func normalizeRewritesRefSpelledSlotMarker() throws {
        // {"$slot":"$ref:d1/hits/0/documentID"} can only mean the $ref.
        let plan = WorkflowPlan(outcome: .selfContained, nodes: [
            WorkflowPlanNode(id: "d1", tool: "search_documents",
                             input: .object(["query": .string("x")])),
            WorkflowPlanNode(id: "s1", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("$ref:d1/hits/0/documentID")]),
                "body": .string("x"),
            ])),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(plan)
        let input = normalized.nodes[1].input
        #expect(TwoRoundValue.slotIDs(in: input).isEmpty)
        #expect(TwoRoundValue.nodeRefIDs(in: input) == ["d1"])
    }

    @Test func normalizeCollapsesSlotPathTokensAndDerivedSources() throws {
        // Observed regression shapes (pro/lite, context suite): the model
        // appends a path to a SLOT token — {{open_doc/title}} — or declares a
        // derived source — "foreground_document/title". A slot has exactly
        // one textual rendering (the candidate's label) and the source can
        // only mean its recognized head, so both collapse deterministically.
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "d", tool: "create_email_draft", input: .object([
                "recipientContactID": .string("c_1"),
                "subject": .string("About {{open_doc/title}}"),
                "bodyDocumentID": .object(["$slot": .string("open_doc")]),
            ])),
        ], contextSlots: [
            WorkflowContextSlot(slotID: "open_doc", source: "foreground_document/title"),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(
            plan, recognizedSources: ["foreground_document"])
        #expect(normalized.contextSlots.first?.source == "foreground_document")
        #expect(normalized.nodes[0].input.optionalString("subject") == "About {{open_doc}}")
        try WorkflowTwoRoundCompiler.validatePlan(
            normalized, availableTools: ["create_email_draft"],
            recognizedSources: ["foreground_document"])
    }

    @Test func normalizeDeclaresAndCollapsesSourceNamedSlotPathToken() throws {
        // {{foreground_document/title}} with NO declaration at all: the head
        // is a recognized source, so the declaration is appended (repair #3
        // extended to token heads) and the path collapses to the label token.
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "m", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("current_contact")]),
                "body": .string("Reminder about {{foreground_document/title}}."),
            ])),
        ], contextSlots: [
            WorkflowContextSlot(slotID: "current_contact", source: "current_contact"),
        ])
        let normalized = WorkflowTwoRoundCompiler.normalizePlan(
            plan, recognizedSources: ["current_contact", "foreground_document"])
        #expect(Set(normalized.contextSlots.map(\.slotID))
            == ["current_contact", "foreground_document"])
        #expect(normalized.nodes[0].input.optionalString("body")
            == "Reminder about {{foreground_document}}.")
        try WorkflowTwoRoundCompiler.validatePlan(
            normalized, availableTools: ["send_message"],
            recognizedSources: ["current_contact", "foreground_document"])
    }

    @Test func validatePlanAcceptsEarlierNodeTextTokenRejectsForward() {
        let body: GeneratedContent = .object([
            "contactID": .string("c_1"),
            "body": .string("About {{d1/hits/0/title}}"),
        ])
        let search = WorkflowPlanNode(
            id: "d1", tool: "search_documents", input: .object(["query": .string("x")]))
        let send = WorkflowPlanNode(id: "s1", tool: "send_message", input: body)
        let ordered = WorkflowPlan(outcome: .selfContained, nodes: [search, send])
        #expect(throws: Never.self) {
            try WorkflowTwoRoundCompiler.validatePlan(
                ordered, availableTools: ["send_message", "search_documents"])
        }
        let forward = WorkflowPlan(outcome: .selfContained, nodes: [send, search])
        #expect(throws: WorkflowTwoRoundCompiler.CompileError.self) {
            try WorkflowTwoRoundCompiler.validatePlan(
                forward, availableTools: ["send_message", "search_documents"])
        }
        // effectiveOutcome: a node-output token is not a context slot.
        #expect(ordered.effectiveOutcome == .selfContained)
    }

    @Test func executorInterpolatesNodeOutputTokenIntoText() async throws {
        let spec = WorkflowSpec(
            workflowID: "t", intent: "",
            nodes: [
                WorkflowNode(id: "d1", tool: "search_documents",
                             input: .object(["query": .string("q3")])),
                WorkflowNode(id: "s1", tool: "send_message", input: .object([
                    "body": .string("About {{d1/hits/0/title}} (see {{d1/hits/0/title}})"),
                    "missing": .string("kept {{d1/hits/9/nope}}"),
                ])),
            ],
            final: .message("Done."),
            limits: WorkflowLimits(deadlineMS: 60_000)
        )
        let validated = try WorkflowValidator.validate(
            spec,
            policy: WorkflowValidationPolicy(
                availableTools: ["search_documents", "send_message"])
        )
        // The token edge alone must order s1 after d1.
        #expect(validated.dependencies["s1"] == ["d1"])
        let seen = SeenBody()
        let executor = WorkflowExecutor { node, input, _ in
            if node.id == "d1" {
                return .object(["hits": .array([
                    .object(["title": .string("Q3 Product Plan")]),
                ])])
            }
            await seen.record(input)
            return .object(["ok": .bool(true)])
        }
        _ = try await executor.execute(validated)
        let input = await seen.value
        #expect(input?.optionalString("body")
            == "About Q3 Product Plan (see Q3 Product Plan)")
        // An unresolvable token degrades to literal text, never throws.
        #expect(input?.optionalString("missing") == "kept {{d1/hits/9/nope}}")
    }

    // MARK: auto-bind

    @Test func autoBindResolvesUnambiguousSlotAndLabel() throws {
        let plan = WorkflowPlan(
            outcome: .requiresBinding, nodes: [
                WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                    "contactID": .object(["$slot": .string("current_contact")]),
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
                    "contactID": .object(["$slot": .string("current_contact")]), "body": .string("hi"),
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
                    "contactID": .object(["$slot": .string("current_contact")]),
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
                "contactID": .object(["$slot": .string("current_contact")]), "body": .string("hi"),
            ])),
        ], contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")])
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$bind": .string("ctx_current_contact_0")]), "body": .string("hi"),
            ])),
        ])
        let resolved = try WorkflowTwoRoundCompiler.resolveBinding(binding, plan: plan, packet: packet())
        #expect(resolved[0].input == .object(["contactID": .string("c_person_0"), "body": .string("hi")]))
    }

    @Test func resolveBindingRejectsCandidateFromWrongSlot() {
        let plan = WorkflowPlan(outcome: .requiresBinding, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$slot": .string("current_contact")]), "body": .string("hi"),
            ])),
        ], contextSlots: [WorkflowContextSlot(slotID: "current_contact", source: "current_contact")])
        // Binds the document candidate into the contact field → must be rejected.
        let binding = WorkflowBinding(status: .complete, nodes: [
            WorkflowPlanNode(id: "send", tool: "send_message", input: .object([
                "contactID": .object(["$bind": .string("ctx_foreground_document_0")]), "body": .string("hi"),
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
        let value = try GeneratedContent(json: rendered)
        guard case .structure(let object, _) = value.kind,
              case .structure(let input, _)? = object["input"]?.kind
        else {
            Issue.record("rendered node must be valid JSON object")
            return
        }
        #expect(object["id"]?.stringValue == "send")
        #expect(object["tool"]?.stringValue == "send_\"message")
        #expect(input["body"]?.stringValue == "Line 1\nLine 2 \"quoted\"")
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
            WorkflowPlanNode(id: "a", tool: "t", input: .object(["x": .object(["$slot": .string("s")])])),
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
