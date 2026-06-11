import Foundation
import FoundationModels

/// The unified workflow tool: ONE official `FoundationModels.Tool` that
/// subsumes both the one-shot workflow layer and the two-round-trip layer.
///
/// The model-facing contract is a single tool whose *arguments schema* is the
/// available tools and their relationships — tool names as a string enum, data
/// edges as `$ref` JSON Pointers, local-context holes as `$slot`/`$bind`
/// markers inside each node's open `input`.
///
/// One `call(arguments:)` covers every path:
/// - self-contained plan            → validate + execute     (one-shot workflow)
/// - plan with deterministic slots  → harvest + auto-bind + execute (one call)
/// - plan with ambiguous slots      → output `needs_binding` + candidates (Round 1)
/// - follow-up call with `$bind`    → resolve + execute      (Round 2)
///
/// Round 2 rides the ordinary session tool loop: the `needs_binding` output
/// instructs the model to call the same tool again, so no bespoke runner is
/// needed. Hosts that require strict round isolation (planner and binder as
/// separate LLM requests with tailored instructions) can keep driving the pure
/// `WorkflowTwoRoundCompiler` from their own runner — this tool and that
/// runner share every validation and execution stage.
///
/// Recoverable model mistakes (bad refs, unknown tools, wrong candidates) are
/// returned as structured outputs (`invalid_plan` / `invalid_binding` /
/// `failed`) rather than thrown, so the model can self-correct within the
/// loop. Candidate *values* never enter the output — binding is by candidate
/// id, labels only, matching the two-round privacy posture.
public struct WorkflowTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = GeneratedContent

    public let name = WorkflowSpec.toolName
    public let description = """
        Run one workflow: a DAG of the available tools, executed locally. Use \
        this for multi-tool tasks, parallel independent lookups, ordered side \
        effects, or inputs that depend on earlier tool outputs. If it replies \
        with status "needs_binding", call it again binding each $slot to a \
        listed candidate via {"$bind":"<candidate_id>"}.
        """
    public let parameters: GenerationSchema

    private let descriptors: [ToolDescriptor]
    private let executor: WorkflowExecutor
    private let harvester: (any ContextHarvesting)?
    private let sources: [String]
    private let limits: WorkflowLimits
    private let onResult: (@Sendable (WorkflowResult) async -> Void)?
    private let pending = PendingBindings()

    /// - Parameters:
    ///   - tools: The workflow node tools, in the same `[any Tool]` currency a
    ///     `LanguageModelSession` takes. A nested `WorkflowTool` is ignored.
    ///   - harvester: Deterministic local resolver for declared context slots.
    ///     `nil` disables the slot vocabulary entirely: the schema and
    ///     instructions omit it, and a plan that still declares slots is
    ///     rejected as invalid.
    ///   - sources: The recognized harvest source names the model may declare
    ///     (ignored when `harvester` is nil).
    ///   - limits: Execution limits for the lowered spec. The default grants
    ///     the full validator-allowed deadline because nodes carry no
    ///     individual timeout.
    ///   - onResult: Host-side observer for the full `WorkflowResult` (node
    ///     outputs, trace) of every executed workflow; the model only sees the
    ///     final value.
    public init(
        tools: [any Tool],
        harvester: (any ContextHarvesting)? = nil,
        sources: [String] = [],
        limits: WorkflowLimits = WorkflowLimits(deadlineMS: 60_000),
        onResult: (@Sendable (WorkflowResult) async -> Void)? = nil
    ) {
        let leafTools = tools.filter { !($0 is WorkflowTool) }
        self.descriptors = leafTools
            .map { ToolDescriptor(tool: $0) }
            .sorted { $0.name < $1.name }
        self.executor = WorkflowExecutor(tools: leafTools)
        self.harvester = harvester
        self.sources = harvester == nil ? [] : sources.sorted()
        self.limits = limits
        self.onResult = onResult
        self.parameters = Self.parametersSchema(
            toolNames: descriptors.map(\.name),
            sources: self.sources
        )
    }

    // MARK: Call

    public func call(arguments: GeneratedContent) async throws -> GeneratedContent {
        // Round 2: this call binds candidates of a pending plan.
        if Self.containsBind(arguments) {
            return await bind(arguments)
        }

        // Round 1, or a plain one-shot plan.
        let plan: WorkflowPlan
        do {
            // Deterministic repairs first (mis-tagged node refs, forward
            // refs, inlined slot declarations) — no-ops on plans that would
            // already validate.
            plan = WorkflowTwoRoundCompiler.normalizePlan(
                try WorkflowPlan(arguments), recognizedSources: Set(sources))
            try WorkflowTwoRoundCompiler.validatePlan(
                plan,
                availableTools: Set(descriptors.map(\.name)),
                recognizedSources: Set(sources)
            )
        } catch {
            return Self.failure(
                status: "invalid_plan",
                error: error,
                instructions: "Correct the plan and call \(name) again with the full node list."
            )
        }

        switch plan.effectiveOutcome {
        case .cannotPlan:
            return .object([
                "status": .string("cannot_plan"),
                "message": .string(plan.message ?? ""),
            ])

        case .selfContained:
            return await run(plan.nodes)

        case .requiresBinding:
            guard let harvester else {
                return .object([
                    "status": .string("needs_clarification"),
                    "message": .string("""
                        No local context is available. Ask the user for the \
                        missing values, then call \(name) again with literals.
                        """),
                ])
            }
            let packet = await harvester.harvest(plan.contextSlots)
            let missing = packet.requiredMissingSlots
            guard missing.isEmpty else {
                return .object([
                    "status": .string("needs_clarification"),
                    "missing_slots": .array(missing.map { .string($0) }),
                    "message": .string("Required local context is missing. Ask the user."),
                ])
            }
            if let bound = WorkflowTwoRoundCompiler.autoBind(plan: plan, packet: packet) {
                return await run(bound)
            }
            let planID = await pending.add(plan: plan, packet: packet)
            return .object([
                "status": .string("needs_binding"),
                "plan_id": .string(planID),
                "context": .string(packet.renderForBinder()),
                "instructions": .string("""
                    Call \(name) again with plan_id "\(planID)" and the SAME \
                    nodes (same ids, tools, order). Replace every \
                    {"$slot":"<slot_id>"} with {"$bind":"<candidate_id>"} \
                    chosen from the context above, and write out any \
                    {{slot_id}} text yourself using the candidate labels. \
                    Change nothing else.
                    """),
            ])
        }
    }

    private func bind(_ arguments: GeneratedContent) async -> GeneratedContent {
        let requestedID = arguments.optionalString("plan_id")
        guard let (planID, plan, packet) = await pending.find(requestedID) else {
            return .object([
                "status": .string("stale_binding"),
                "message": .string("""
                    No pending plan to bind. Re-emit the full plan with $slot \
                    markers and declared context_slots.
                    """),
            ])
        }
        do {
            let binding = try WorkflowBinding(arguments)
            let nodes = try WorkflowTwoRoundCompiler.resolveBinding(
                binding, plan: plan, packet: packet
            )
            await pending.remove(planID)
            return await run(nodes)
        } catch {
            // The pending plan is kept so the model can retry the binding.
            return Self.failure(
                status: "invalid_binding",
                error: error,
                instructions: """
                    Bind again with plan_id "\(planID)": same nodes, and $bind \
                    values only from the listed candidates of each slot.
                    """
            )
        }
    }

    private func run(_ nodes: [WorkflowPlanNode]) async -> GeneratedContent {
        let lowered = nodes.map { WorkflowNode(id: $0.id, tool: $0.tool, input: $0.input) }
        let spec = WorkflowSpec(
            workflowID: "workflow_tool",
            intent: "",
            nodes: lowered,
            final: lowered.last.map { .nodeOutput($0.id) } ?? .message(""),
            limits: limits
        )
        do {
            let validated = try WorkflowValidator.validate(
                spec,
                policy: WorkflowValidationPolicy(descriptors: descriptors)
            )
            let result = try await executor.execute(validated)
            await onResult?(result)
            var payload: [String: GeneratedContent] = [
                "status": .string("completed"),
                "result": result.finalValue,
            ]
            if let text = result.finalText {
                payload["final_text"] = .string(text)
            }
            return .object(payload)
        } catch {
            return Self.failure(status: "failed", error: error, instructions: nil)
        }
    }

    private static func failure(
        status: String,
        error: any Error,
        instructions: String?
    ) -> GeneratedContent {
        var payload: [String: GeneratedContent] = [
            "status": .string(status),
            "error": .string(String(describing: error)),
        ]
        if let instructions {
            payload["instructions"] = .string(instructions)
        }
        return .object(payload)
    }

    private static func containsBind(_ arguments: GeneratedContent) -> Bool {
        guard let nodes = try? arguments.contentArray("nodes") else { return false }
        return nodes.contains { node in
            guard let input = node.property("input") else { return false }
            return !TwoRoundValue.bindIDs(in: input).isEmpty
        }
    }

    // MARK: Planning instructions

    /// Session instructions for this tool: the workflow contract, the tool
    /// manifest with schemas, and one fixed worked example. The example is
    /// measured to be **load-bearing** — the schema fixes *structure* but the
    /// example supplies *semantics* — so include this in the session
    /// instructions alongside the tool itself.
    public func instructions() -> String {
        let manifest = descriptors
            .map { descriptor in
                var line = "- \(descriptor.name): \(descriptor.description)"
                if let text = try? descriptor.argumentsSchema.jsonString() {
                    line += " Arguments schema: \(text)"
                }
                if let output = descriptor.outputSchema,
                   let text = try? output.jsonString() {
                    line += " Output schema: \(text)"
                }
                return line
            }
            .joined(separator: "\n")
        var sections: [String] = []
        sections.append("""
            For requests requiring tools, call the \(name) tool with one \
            workflow object. Do not call the other tools directly.

            A workflow is a topological DAG. Emit a `nodes` array; each node \
            has exactly three fields: id, tool, input — omit everything else \
            and keep node ids short. `input` holds ONLY that tool's own \
            parameters — never put id, tool, or depends_on inside input, and \
            omit optional parameters you don't use (no null filler). Put \
            independent source nodes first; a node depends on another only by \
            referencing its output in `input` with \
            {"$ref":"<node id>/<field>"} (id, then a JSON Pointer). Do not \
            copy intermediate outputs; reference them. The app executes the \
            DAG locally — ONCE, exactly as emitted. Include every node \
            needed to fully complete the request, ending with the action \
            node(s) the user asked for; a plan that stops after lookups \
            accomplishes nothing.
            """)
        if !sources.isEmpty {
            sections.append("""
                For a value that lives in local context (the open document, \
                the current selection), never invent it: declare a context \
                slot in `context_slots` as {"slot_id":"...","source":"..."} \
                (sources: \(sources.joined(separator: ", "))) and reference \
                it with {"$slot":"slot_id"}, or {{slot_id}} inside text you \
                are writing. If \(name) replies with status "needs_binding", \
                call it again with the returned plan_id and the SAME nodes, \
                replacing each $slot with {"$bind":"candidate_id"} from the \
                listed candidates.
                """)
        }
        sections.append("""
            Example workflow (general template — adapt the tools/values to \
            the actual request; never copy these literal values):
            {"nodes":[\
            {"id":"f","tool":"find_contact","input":{"query":"Bob Singh"}},\
            {"id":"send","tool":"send_message","input":{"contactID":\
            {"$ref":"f/contactID"},"body":"Hi Bob."}}\
            ]}
            """)
        if !sources.isEmpty {
            sections.append("""
                Example with a local-context slot:
                {"nodes":[\
                {"id":"share","tool":"share_document","input":{"documentURL":\
                {"$slot":"current_doc"},"note":"Here is {{current_doc}}."}}\
                ],"context_slots":[{"slot_id":"current_doc","source":"open_documents"}]}
                """)
        }
        sections.append("""
            Available workflow node tools:
            \(manifest)
            """)
        return sections.joined(separator: "\n\n")
    }

    // MARK: Arguments schema

    /// The unified call schema: Round-1 plans and Round-2 bindings share the
    /// lean `{nodes:[{id, tool, input}]}` shape; the value algebra
    /// (`$ref`/`$slot`/`$bind`/`{{label}}`) lives inside the open `input`.
    /// `context_slots`/`plan_id` are emitted only when harvesting is enabled.
    private static func parametersSchema(
        toolNames: [String],
        sources: [String]
    ) -> GenerationSchema {
        let node = DynamicGenerationSchema(
            name: "WorkflowToolNode",
            properties: [
                property("id", string, description: "Unique snake_case node id."),
                property("tool", stringEnum(toolNames.sorted())),
                property("input", jsonContent),
            ]
        )
        var rootProperties: [DynamicGenerationSchema.Property] = [
            property("nodes", array(of: node, minimumElements: 1, maximumElements: 24)),
        ]
        if !sources.isEmpty {
            let slot = DynamicGenerationSchema(
                name: "WorkflowToolContextSlot",
                properties: [
                    property(
                        "slot_id", string,
                        description: "Stable id referenced by {\"$slot\":...} / {{slot_id}}."
                    ),
                    property("source", stringEnum(sources.sorted())),
                ]
            )
            rootProperties.append(property(
                "context_slots", array(of: slot, maximumElements: 12), optional: true
            ))
            rootProperties.append(property(
                "plan_id", string,
                description: "Echo the plan_id from a needs_binding reply when binding.",
                optional: true
            ))
        }
        rootProperties.append(property("outcome", stringEnum(["cannot_plan"]), optional: true))
        rootProperties.append(property(
            "message", nullable("NullableWorkflowToolMessage", string), optional: true
        ))
        let root = DynamicGenerationSchema(name: "WorkflowToolCall", properties: rootProperties)
        do {
            return try GenerationSchema(root: root, dependencies: [])
        } catch {
            preconditionFailure("Invalid built-in WorkflowTool GenerationSchema: \(error)")
        }
    }
}

/// Round-1 plans awaiting a Round-2 binding, keyed by the `plan_id` echoed in
/// the `needs_binding` output. Bounded: the oldest pending plan is evicted
/// when a new one would exceed capacity, so an abandoned binding cannot leak.
private actor PendingBindings {
    private var entries: [(id: String, plan: WorkflowPlan, packet: ContextPacket)] = []
    private let capacity = 4

    /// Stores a pending plan and returns its generated id.
    func add(plan: WorkflowPlan, packet: ContextPacket) -> String {
        let id = "plan_" + UUID().uuidString.prefix(8).lowercased()
        entries.append((id, plan, packet))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return id
    }

    /// Looks up by id, or returns the most recent pending plan when the model
    /// omitted `plan_id`. Non-consuming: the entry stays until the binding
    /// resolves, so the model can retry an invalid binding.
    func find(_ id: String?) -> (id: String, plan: WorkflowPlan, packet: ContextPacket)? {
        if let id {
            return entries.last { $0.id == id }
        }
        return entries.last
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }
}

private let string = DynamicGenerationSchema(type: String.self)
private let jsonContent = DynamicGenerationSchema(type: GeneratedContent.self)

private func property(
    _ name: String,
    _ schema: DynamicGenerationSchema,
    description: String? = nil,
    optional: Bool = false
) -> DynamicGenerationSchema.Property {
    DynamicGenerationSchema.Property(
        name: name,
        description: description,
        schema: schema,
        isOptional: optional
    )
}

private func stringEnum(_ values: [String]) -> DynamicGenerationSchema {
    DynamicGenerationSchema(name: "StringEnum", anyOf: values)
}

private func nullable(
    _ name: String,
    _ schema: DynamicGenerationSchema
) -> DynamicGenerationSchema {
    DynamicGenerationSchema(name: name, anyOf: [schema, .null])
}

private func array(
    of itemSchema: DynamicGenerationSchema,
    minimumElements: Int? = nil,
    maximumElements: Int? = nil
) -> DynamicGenerationSchema {
    DynamicGenerationSchema(
        arrayOf: itemSchema,
        minimumElements: minimumElements,
        maximumElements: maximumElements
    )
}
