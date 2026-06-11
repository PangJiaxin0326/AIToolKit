import Foundation
import FoundationModels

/// The pure, LLM-free heart of the two-round-trip compiler: validate the
/// Round-1 plan, decide whether binding is deterministic (auto-bind), validate
/// and resolve a Round-2 binding, and lower the result to an executable
/// `WorkflowSpec`. The runtime layer adds only the two LLM calls and the
/// harvest; everything here is deterministic and unit-testable.
public enum WorkflowTwoRoundCompiler {
    public enum CompileError: Error, Sendable, CustomStringConvertible {
        case emptyPlan
        case duplicateNodeID(String)
        case invalidNodeID(String)
        case unavailableTool(node: String, tool: String)
        case missingTool(node: String)
        case forwardOrMissingRef(node: String, ref: String)
        case undeclaredSlot(node: String, slot: String)
        case unrecognizedSlotSource(slot: String, source: String)
        case graphMutated(String)
        case unboundSlot(node: String, slot: String)
        case unknownCandidate(node: String, candidate: String)
        case candidateWrongSlot(node: String, candidate: String, slot: String)

        public var description: String {
            switch self {
            case .emptyPlan: return "plan has no nodes"
            case .duplicateNodeID(let id): return "duplicate node id \(id)"
            case .invalidNodeID(let id): return "invalid node id \(id)"
            case .unavailableTool(let n, let t): return "node \(n) uses unavailable tool \(t)"
            case .missingTool(let n): return "node \(n) has no tool"
            case .forwardOrMissingRef(let n, let r): return "node \(n) refs \(r) which is not an earlier node"
            case .undeclaredSlot(let n, let s): return "node \(n) uses undeclared slot \(s)"
            case .unrecognizedSlotSource(let s, let src): return "slot \(s) declares unrecognized source \(src)"
            case .graphMutated(let why): return "binder mutated the graph: \(why)"
            case .unboundSlot(let n, let s): return "node \(n) still has unbound slot \(s)"
            case .unknownCandidate(let n, let c): return "node \(n) binds unknown candidate \(c)"
            case .candidateWrongSlot(let n, let c, let s): return "node \(n) binds candidate \(c) not of slot \(s)"
            }
        }
    }

    // MARK: Round-1 plan normalization (deterministic repairs, pre-validate)

    /// Repairs model output that is malformed but *unambiguously
    /// interpretable* — the same repair-or-fail philosophy as the runner's
    /// brace-repairing extractor. Two normalizations, both no-ops on plans
    /// that would already validate:
    ///
    /// 1. **Mis-tagged node references.** `{"$slot":"<node id>/<path>"}` where
    ///    the prefix is an existing node id can only mean the compact `$ref`
    ///    form (a slot id cannot contain `/`); rewrite it to
    ///    `{"$ref":"<node id>/<path>"}`. A weak planner mixes the two markers
    ///    when it wants a searched entity's field in an input.
    /// 2. **Forward references.** A `$ref` to a node that appears *later* is
    ///    reordered away with a stable topological sort (Kahn, original order
    ///    as tie-break). The DAG was correct; only the emission order was
    ///    wrong. A cyclic or dangling ref is left for `validatePlan` to
    ///    reject.
    /// 3. **Inlined slot declarations.** A used-but-undeclared slot whose id
    ///    is *exactly* a recognized source name has only one possible
    ///    reading — `{slot_id: X, source: X}` — so the missing declaration is
    ///    appended (requires `recognizedSources`). An undeclared slot with
    ///    any other id stays undeclared for `validatePlan` to reject.
    /// 4. **Mis-spelled node-output text tokens.** A `{{…}}` token that spells
    ///    a node reference (`{{$ref.d1.hits.0.title}}`, `{{d1.hits.0.title}}`)
    ///    is canonicalized to `{{d1/hits/0/title}}` — the executor's
    ///    text-interpolation form. A `$slot` whose id carries a `$ref` prefix
    ///    or dotted node path is likewise read as the `$ref` it can only be.
    /// 5. **Slot text tokens with a path.** `{{<declared slot>/<path>}}`
    ///    (`{{open_doc/title}}`) collapses to `{{<declared slot>}}`: a slot
    ///    has exactly one textual rendering in authored text — the bound
    ///    candidate's display label (its title/name); values never enter
    ///    text. Same for a *dotted* slot path (`{{open_doc.title}}`).
    /// 6. **Derived slot sources.** A declared `source` of the form
    ///    `<recognized>/<suffix>` or `<recognized>.<suffix>`
    ///    (`foreground_document/title`) can only mean the recognized source —
    ///    the suffix is the model reaching for a field the harvest protocol
    ///    doesn't have; the candidates carry their labels regardless
    ///    (requires `recognizedSources`).
    public static func normalizePlan(
        _ plan: WorkflowPlan,
        recognizedSources: Set<String>? = nil
    ) -> WorkflowPlan {
        var plan = plan
        if let recognizedSources {
            plan.contextSlots = plan.contextSlots.map { slot in
                var slot = slot
                if let separator = slot.source.firstIndex(where: { $0 == "/" || $0 == "." }),
                   recognizedSources.contains(String(slot.source[..<separator])) {
                    slot.source = String(slot.source[..<separator])
                }
                return slot
            }
        }
        let ids = Set(plan.nodes.map(\.id))
        plan.nodes = plan.nodes.map { node in
            var input = rewriteNodePathSlots(node.input, nodeIDs: ids)
            input = TwoRoundValue.canonicalizeNodeTokens(in: input, nodeIDs: ids)
            return WorkflowPlanNode(id: node.id, tool: node.tool, input: input)
        }
        plan.nodes = stableTopologicalOrder(plan.nodes)
        if let recognizedSources {
            let declared = Set(plan.contextSlots.map(\.slotID))
            // Slot ids used by $slot markers, plus the heads of slot text
            // tokens (`{{X}}` / `{{X/title}}` where X is not a node id).
            var used = Set(plan.nodes.flatMap { TwoRoundValue.slotIDs(in: $0.input) })
            for node in plan.nodes {
                for token in TwoRoundValue.labelTokens(in: node.input)
                where !TwoRoundValue.isNodeOutputToken(token, nodeIDs: ids) {
                    let head = token.firstIndex { $0 == "/" || $0 == "." }
                        .map { String(token[..<$0]) } ?? token
                    used.insert(head)
                }
            }
            for slot in used.subtracting(declared).intersection(recognizedSources).sorted() {
                plan.contextSlots.append(WorkflowContextSlot(slotID: slot, source: slot))
            }
        }
        // Collapse against the final declared set, so a just-declared
        // source-named slot's path tokens collapse too.
        let declaredSlots = Set(plan.contextSlots.map(\.slotID))
        plan.nodes = plan.nodes.map { node in
            WorkflowPlanNode(
                id: node.id, tool: node.tool,
                input: collapseSlotPathTokens(in: node.input, declaredSlots: declaredSlots)
            )
        }
        return plan
    }

    /// `{{<declared slot>/<path>}}` / `{{<declared slot>.<path>}}` →
    /// `{{<declared slot>}}` (normalization #5). Node ids take precedence —
    /// this runs after node-token canonicalization and only touches tokens
    /// whose head is a declared slot.
    private static func collapseSlotPathTokens(
        in value: GeneratedContent, declaredSlots: Set<String>
    ) -> GeneratedContent {
        guard !declaredSlots.isEmpty else { return value }
        return TwoRoundValue.resolveLabels(in: value) { raw in
            guard let separator = raw.firstIndex(where: { $0 == "/" || $0 == "." }),
                  declaredSlots.contains(String(raw[..<separator])) else { return nil }
            return "{{\(String(raw[..<separator]))}}"
        }
    }

    private static func rewriteNodePathSlots(
        _ value: GeneratedContent,
        nodeIDs: Set<String>
    ) -> GeneratedContent {
        switch value.kind {
        case .structure(let object, _):
            if object.count == 1,
               case .string(let slot)? = object["$slot"]?.kind,
               let canonical = TwoRoundValue.canonicalNodePath(slot, nodeIDs: nodeIDs) {
                return .object(["$ref": .string(canonical)])
            }
            var rewritten: [String: GeneratedContent] = [:]
            for (key, child) in object {
                rewritten[key] = rewriteNodePathSlots(child, nodeIDs: nodeIDs)
            }
            return .object(rewritten)
        case .array(let values):
            return .array(values.map { rewriteNodePathSlots($0, nodeIDs: nodeIDs) })
        default:
            return value
        }
    }

    private static func stableTopologicalOrder(
        _ nodes: [WorkflowPlanNode]
    ) -> [WorkflowPlanNode] {
        let ids = Set(nodes.map(\.id))
        let position = Dictionary(
            nodes.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        // Only reorder when some ref actually points forward; otherwise keep
        // the emission byte-identical.
        let hasForwardRef = nodes.enumerated().contains { index, node in
            var refs = TwoRoundValue.nodeRefIDs(in: node.input)
            refs += TwoRoundValue.nodeOutputTokens(in: node.input, nodeIDs: ids)
                .compactMap { token in
                    token.firstIndex(of: "/").map { String(token[..<$0]) }
                }
            return refs.contains { ref in
                ids.contains(ref) && (position[ref] ?? 0) > index
            }
        }
        guard hasForwardRef else { return nodes }
        var dependencies: [String: Set<String>] = [:]
        for node in nodes {
            var refs = Set(TwoRoundValue.nodeRefIDs(in: node.input).filter(ids.contains))
            // `{{node/path}}` text tokens are dependency edges too.
            for token in TwoRoundValue.nodeOutputTokens(in: node.input, nodeIDs: ids) {
                if let slash = token.firstIndex(of: "/") {
                    refs.insert(String(token[..<slash]))
                }
            }
            dependencies[node.id] = refs
        }
        var ordered: [WorkflowPlanNode] = []
        var placed = Set<String>()
        var remaining = nodes
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { node in
                (dependencies[node.id] ?? []).subtracting(placed).isEmpty
            }) else {
                // Cycle — leave the rest in emission order for validatePlan
                // to reject with a precise error.
                return ordered + remaining
            }
            let node = remaining.remove(at: index)
            ordered.append(node)
            placed.insert(node.id)
        }
        return ordered
    }

    // MARK: Round-1 plan validation (structural, pre-harvest)

    /// Validates node ids (unique, well-formed), tool availability, that every
    /// `$ref` points to an *earlier* node, and that every `$slot` / `{{label}}`
    /// token names a declared slot (so the harvester fetches it and no token
    /// leaks as literal text). O(N).
    ///
    /// When `recognizedSources` is non-nil, also enforces the v2.1 guard rail
    /// that every declared slot's `source` is one of the recognized harvest
    /// sources — promoting a prompt clause to a hard guarantee, so a planner that
    /// invents a derived source (e.g. `foreground_document.title`) fails fast
    /// here instead of silently as a harvest "missing" later. Pass `nil` to skip
    /// (back-compatible).
    public static func validatePlan(
        _ plan: WorkflowPlan,
        availableTools: Set<String>,
        recognizedSources: Set<String>? = nil
    ) throws {
        guard !plan.nodes.isEmpty else { throw CompileError.emptyPlan }
        if let recognizedSources {
            for slot in plan.contextSlots where !recognizedSources.contains(slot.source) {
                throw CompileError.unrecognizedSlotSource(slot: slot.slotID, source: slot.source)
            }
        }
        let declared = Set(plan.contextSlots.map(\.slotID))
        let allNodeIDs = Set(plan.nodes.map(\.id))
        var prior = Set<String>()
        for node in plan.nodes {
            guard WorkflowValidator.isValidNodeID(node.id) else {
                throw CompileError.invalidNodeID(node.id)
            }
            guard !prior.contains(node.id) else { throw CompileError.duplicateNodeID(node.id) }
            guard let tool = node.tool, !tool.isEmpty else { throw CompileError.missingTool(node: node.id) }
            guard availableTools.contains(tool) else {
                throw CompileError.unavailableTool(node: node.id, tool: tool)
            }
            for ref in TwoRoundValue.nodeRefIDs(in: node.input) where !prior.contains(ref) {
                throw CompileError.forwardOrMissingRef(node: node.id, ref: ref)
            }
            for slot in TwoRoundValue.slotIDs(in: node.input) where !declared.contains(slot) {
                throw CompileError.undeclaredSlot(node: node.id, slot: slot)
            }
            for token in TwoRoundValue.labelTokens(in: node.input) where !declared.contains(token) {
                // A `{{node/path}}` token is a node-output text reference, not
                // a slot — valid when it points at an EARLIER node, like $ref.
                if TwoRoundValue.isNodeOutputToken(token, nodeIDs: allNodeIDs) {
                    let head = String(token[..<token.firstIndex(of: "/")!])
                    guard prior.contains(head) else {
                        throw CompileError.forwardOrMissingRef(node: node.id, ref: token)
                    }
                    continue
                }
                throw CompileError.undeclaredSlot(node: node.id, slot: token)
            }
            prior.insert(node.id)
        }
    }

    // MARK: Auto-bind (skip Round 2 when binding is deterministic)

    /// Returns the slot-resolved nodes when binding is fully deterministic, or
    /// `nil` when the Binder is genuinely needed. Deterministic means: every
    /// declared slot is *referenced* (by `$slot` or a `{{label}}` token) — an
    /// unreferenced declared slot signals free-text authoring the Binder must
    /// phrase — and each referenced slot resolves to a single candidate (sole,
    /// or unique foreground/current). Ambiguity returns `nil`.
    public static func autoBind(plan: WorkflowPlan, packet: ContextPacket) -> [WorkflowPlanNode]? {
        let nodeIDs = Set(plan.nodes.map(\.id))
        let slotRefs = Set(plan.nodes.flatMap { TwoRoundValue.slotIDs(in: $0.input) })
        // `{{node/path}}` text tokens resolve at execution, not bind time.
        let labelRefs = Set(plan.nodes.flatMap { TwoRoundValue.labelTokens(in: $0.input) })
            .filter { !TwoRoundValue.isNodeOutputToken($0, nodeIDs: nodeIDs) }
        let referenced = slotRefs.union(labelRefs)
        for requirement in plan.contextSlots where !referenced.contains(requirement.slotID) {
            return nil
        }
        var value: [String: GeneratedContent] = [:]
        var label: [String: String] = [:]
        for slotID in referenced {
            guard let slot = packet.slot(slotID), slot.status == .resolved else { return nil }
            let pick: HarvestedCandidate?
            if slot.candidates.count == 1 {
                pick = slot.candidates.first
            } else {
                let currents = slot.candidates.filter(\.isCurrent)
                pick = currents.count == 1 ? currents.first : nil
            }
            guard let pick else { return nil }
            value[slotID] = pick.value
            label[slotID] = pick.displayLabel
        }
        return plan.nodes.map { node in
            let withIDs = TwoRoundValue.resolveSlots(in: node.input) { value[$0] ?? .nullContent }
            let withLabels = TwoRoundValue.resolveLabels(in: withIDs) { label[$0] }
            return WorkflowPlanNode(id: node.id, tool: node.tool, input: withLabels)
        }
    }

    // MARK: Round-2 binding validation + resolution

    /// Validates the Binder preserved the graph shape (same ids/tools/order),
    /// left no raw `$slot`, and bound every `$bind` to a candidate **of that
    /// slot**; then resolves `$bind` → the candidate's literal value and any
    /// residual `{{label}}` token → the candidate's label.
    public static func resolveBinding(
        _ binding: WorkflowBinding, plan: WorkflowPlan, packet: ContextPacket
    ) throws -> [WorkflowPlanNode] {
        guard binding.nodes.count == plan.nodes.count else {
            throw CompileError.graphMutated("node count \(binding.nodes.count) ≠ \(plan.nodes.count)")
        }
        let byID = packet.candidatesByID
        var resolved: [WorkflowPlanNode] = []
        for (planNode, boundNode) in zip(plan.nodes, binding.nodes) {
            guard planNode.id == boundNode.id else {
                throw CompileError.graphMutated("id \(boundNode.id) ≠ \(planNode.id)")
            }
            guard planNode.tool == boundNode.tool else {
                throw CompileError.graphMutated("tool for \(planNode.id) changed")
            }
            let nodeSlots = Set(TwoRoundValue.slotIDs(in: planNode.input))
            let allowed = Set(nodeSlots.flatMap { packet.candidateIDs(forSlot: $0) })
            if let slot = TwoRoundValue.slotIDs(in: boundNode.input).first {
                throw CompileError.unboundSlot(node: boundNode.id, slot: slot)
            }
            for candidate in TwoRoundValue.bindIDs(in: boundNode.input) {
                guard byID[candidate] != nil else {
                    throw CompileError.unknownCandidate(node: boundNode.id, candidate: candidate)
                }
                guard allowed.contains(candidate) else {
                    throw CompileError.candidateWrongSlot(
                        node: boundNode.id, candidate: candidate,
                        slot: nodeSlots.sorted().joined(separator: "|"))
                }
            }
            let input = try TwoRoundValue.resolveBinds(in: boundNode.input) { id in
                guard let candidate = byID[id] else {
                    throw CompileError.unknownCandidate(node: boundNode.id, candidate: id)
                }
                return candidate.value
            }
            resolved.append(WorkflowPlanNode(id: boundNode.id, tool: boundNode.tool, input: input))
        }
        // Safety net: resolve residual `{{slot_id}}` tokens the Binder passed
        // through only when the packet makes the label deterministic.
        // `{{node/path}}` text tokens are NOT slot labels — they stay intact
        // for the executor's text interpolation.
        let nodeIDs = Set(plan.nodes.map(\.id))
        let labelForSlot = Dictionary(packet.slots.compactMap { slot -> (String, String)? in
            let pick: HarvestedCandidate?
            if slot.candidates.count == 1 {
                pick = slot.candidates.first
            } else {
                let currents = slot.candidates.filter(\.isCurrent)
                pick = currents.count == 1 ? currents.first : nil
            }
            return pick.map { (slot.slotID, $0.displayLabel) }
        }, uniquingKeysWith: { a, _ in a })
        return try resolved.map { node in
            for token in TwoRoundValue.labelTokens(in: node.input)
            where labelForSlot[token] == nil
                && !TwoRoundValue.isNodeOutputToken(token, nodeIDs: nodeIDs) {
                throw CompileError.unboundSlot(node: node.id, slot: token)
            }
            return WorkflowPlanNode(
                id: node.id, tool: node.tool,
                input: TwoRoundValue.resolveLabels(in: node.input) { labelForSlot[$0] })
        }
    }

    // MARK: Lowering to an executable WorkflowSpec

    /// Lowers fully-resolved plan nodes (literals + node `$ref`s only) to a
    /// `WorkflowSpec`. Dependencies are derived from `$ref`s, so `depends_on`
    /// is empty.
    public static func buildSpec(
        from nodes: [WorkflowPlanNode],
        descriptors: [String: ToolDescriptor],
        workflowID: String = "two_round",
        intent: String = "two-round bound workflow"
    ) -> WorkflowSpec {
        let pruned = nodes.map { node -> WorkflowNode in
            WorkflowNode(id: node.id, tool: node.tool, dependsOn: [], input: node.input)
        }
        // This spec is host-built (the planner emits only {id, tool, input}
        // nodes), so give it the full validator-allowed deadline: nodes carry
        // no individual timeout, and a slow-but-legitimate node (e.g. a
        // model-backed tool) must not be killed by the lean model-facing
        // default.
        return WorkflowSpec(
            workflowID: workflowID, intent: intent, nodes: pruned,
            final: .message("Done."),
            limits: WorkflowLimits(deadlineMS: 60_000)
        )
    }
}
