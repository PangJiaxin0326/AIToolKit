import Foundation

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
            case .graphMutated(let why): return "binder mutated the graph: \(why)"
            case .unboundSlot(let n, let s): return "node \(n) still has unbound slot \(s)"
            case .unknownCandidate(let n, let c): return "node \(n) binds unknown candidate \(c)"
            case .candidateWrongSlot(let n, let c, let s): return "node \(n) binds candidate \(c) not of slot \(s)"
            }
        }
    }

    // MARK: Round-1 plan validation (structural, pre-harvest)

    /// Validates node ids (unique, well-formed), tool availability, that every
    /// `$ref` points to an *earlier* node, and that every `$slot` / `{{label}}`
    /// token names a declared slot (so the harvester fetches it and no token
    /// leaks as literal text). O(N).
    public static func validatePlan(
        _ plan: WorkflowPlan, availableTools: Set<String>
    ) throws {
        guard !plan.nodes.isEmpty else { throw CompileError.emptyPlan }
        let declared = Set(plan.contextSlots.map(\.slotID))
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
        let slotRefs = Set(plan.nodes.flatMap { TwoRoundValue.slotIDs(in: $0.input) })
        let labelRefs = Set(plan.nodes.flatMap { TwoRoundValue.labelTokens(in: $0.input) })
        let referenced = slotRefs.union(labelRefs)
        for requirement in plan.contextSlots where !referenced.contains(requirement.slotID) {
            return nil
        }
        var value: [String: JSONValue] = [:]
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
            let withIDs = TwoRoundValue.resolveSlots(in: node.input) { value[$0] ?? .null }
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
        // Safety net: resolve any residual `{{slot_id}}` tokens the Binder passed
        // through, using the best (current/sole) candidate per slot.
        let labelForSlot = Dictionary(packet.slots.compactMap { slot -> (String, String)? in
            let pick = slot.candidates.first(where: \.isCurrent) ?? slot.candidates.first
            return pick.map { (slot.slotID, $0.displayLabel) }
        }, uniquingKeysWith: { a, _ in a })
        return resolved.map { node in
            WorkflowPlanNode(
                id: node.id, tool: node.tool,
                input: TwoRoundValue.resolveLabels(in: node.input) { labelForSlot[$0] })
        }
    }

    // MARK: Lowering to an executable WorkflowSpec

    /// Lowers fully-resolved plan nodes (literals + node `$ref`s only) to a
    /// `WorkflowSpec`, pruning each node's stray input keys to its tool schema
    /// first. Dependencies are derived from `$ref`s, so `depends_on` is empty.
    public static func buildSpec(
        from nodes: [WorkflowPlanNode],
        descriptors: [String: ToolDescriptor],
        workflowID: String = "two_round",
        intent: String = "two-round bound workflow"
    ) -> WorkflowSpec {
        let pruned = nodes.map { node -> WorkflowNode in
            let input: JSONValue
            if let tool = node.tool, let schema = descriptors[tool]?.inputSchema {
                input = TwoRoundValue.prune(node.input, toInputSchema: schema)
            } else {
                input = node.input
            }
            return WorkflowNode(id: node.id, tool: node.tool, dependsOn: [], input: input)
        }
        return WorkflowSpec(
            workflowID: workflowID, intent: intent, nodes: pruned, final: .message("Done.")
        )
    }
}
