import Foundation

// MARK: - Two-round-trip workflow models & value algebra
//
// The two-round-trip compiler separates *graph planning* (Round 1) from
// *parameter binding* (Round 2) across two isolated LLM requests, with a
// deterministic local context harvest in between. It is built for tasks whose
// parameters depend on local/private state the planner must not see or invent
// (deictic references: "the document I have open").
//
// These types are the provider-agnostic core: the wire models, the node-input
// value algebra (extends `$ref`/`$literal` with `$slot`/`$bind`/`{{label}}`),
// the harvest packet, the harvesting protocol, and the plan cache. The
// orchestration (the two LLM calls) lives in the runtime layer; the pure
// validate/auto-bind/compile logic lives in `WorkflowTwoRoundCompiler`.
//
// The bound result is a plain `WorkflowSpec`, so the existing `WorkflowValidator`
// and `WorkflowExecutor` run unchanged.

public enum WorkflowTwoRound {
    /// Schema version stamped on the plan/binding wire shapes.
    public static let schemaVersion = "two_round_dag.v1"
}

// MARK: Value algebra (the markers the runtime resolves into literals/$refs)

/// Static helpers over a node-input `JSONValue` for the two-round markers:
///
/// - `{"$slot":"<id>"}` — Round-1 placeholder for a value from local context.
/// - `{"$bind":"<candidate_id>"}` — Round-2 selection of a harvested candidate.
/// - `"… {{slot_id}} …"` — substitute a harvested candidate's *label* into text.
///
/// `$ref`/`$literal` continue to be handled by `WorkflowReferenceResolver`.
public enum TwoRoundValue {
    /// Every `$slot` id referenced by a value.
    public static func slotIDs(in value: JSONValue) -> [String] {
        marker(value, key: "$slot")
    }

    /// Every `$bind` candidate id referenced by a value.
    public static func bindIDs(in value: JSONValue) -> [String] {
        marker(value, key: "$bind")
    }

    /// Node-output `$ref` source ids (for dependency edges / topo checks).
    public static func nodeRefIDs(in value: JSONValue) -> [String] {
        WorkflowReferenceResolver.references(in: value)
            .filter { $0.source == .node }
            .compactMap(\.node)
    }

    private static let markerKeys: Set<String> = ["$ref", "$literal", "$slot", "$bind"]

    private static func marker(_ value: JSONValue, key: String) -> [String] {
        switch value {
        case .object(let object):
            if object.count == 1, case .string(let id)? = object[key] { return [id] }
            // A single-key object that is some *other* marker is a leaf, not a
            // container — don't descend into it.
            if object.count == 1, let only = object.keys.first, markerKeys.contains(only) {
                return []
            }
            return object.values.flatMap { marker($0, key: key) }
        case .array(let values):
            return values.flatMap { marker($0, key: key) }
        default:
            return []
        }
    }

    /// Replaces every `{"$slot":"id"}` with `resolve(id)`. Leaves
    /// `$ref`/`$bind`/`$literal`/scalars intact.
    public static func resolveSlots(
        in value: JSONValue, resolve: (String) -> JSONValue
    ) -> JSONValue {
        replaceMarker(value, key: "$slot") { resolve($0) }
    }

    /// Replaces every `{"$bind":"id"}` with the literal `resolve` returns; throws
    /// if a referenced candidate can't be resolved.
    public static func resolveBinds(
        in value: JSONValue, resolve: (String) throws -> JSONValue
    ) rethrows -> JSONValue {
        try replaceMarkerThrowing(value, key: "$bind", resolve)
    }

    private static func replaceMarker(
        _ value: JSONValue, key: String, _ resolve: (String) -> JSONValue
    ) -> JSONValue {
        switch value {
        case .object(let object):
            if object.count == 1, case .string(let id)? = object[key] { return resolve(id) }
            if object.count == 1, (object["$ref"] != nil || object["$literal"] != nil
                || object["$slot"] != nil || object["$bind"] != nil) { return value }
            return .object(object.mapValues { replaceMarker($0, key: key, resolve) })
        case .array(let values):
            return .array(values.map { replaceMarker($0, key: key, resolve) })
        default:
            return value
        }
    }

    private static func replaceMarkerThrowing(
        _ value: JSONValue, key: String, _ resolve: (String) throws -> JSONValue
    ) rethrows -> JSONValue {
        switch value {
        case .object(let object):
            if object.count == 1, case .string(let id)? = object[key] { return try resolve(id) }
            if object.count == 1, (object["$ref"] != nil || object["$literal"] != nil
                || object["$slot"] != nil || object["$bind"] != nil) { return value }
            var out: [String: JSONValue] = [:]
            for (k, child) in object { out[k] = try replaceMarkerThrowing(child, key: key, resolve) }
            return .object(out)
        case .array(let values):
            return .array(try values.map { try replaceMarkerThrowing($0, key: key, resolve) })
        default:
            return value
        }
    }

    // MARK: `{{slot_id}}` label tokens

    /// Every `{{slot_id}}` token referenced anywhere in a value's strings.
    public static func labelTokens(in value: JSONValue) -> Set<String> {
        var out: Set<String> = []
        func walk(_ v: JSONValue) {
            switch v {
            case .string(let s): out.formUnion(tokenIDs(in: s))
            case .array(let a): a.forEach(walk)
            case .object(let o): o.values.forEach(walk)
            default: break
            }
        }
        walk(value)
        return out
    }

    /// Replaces each `{{slot_id}}` token in every string with `label(id)`; a
    /// token whose id has no label is left intact.
    public static func resolveLabels(
        in value: JSONValue, label: (String) -> String?
    ) -> JSONValue {
        switch value {
        case .string(let s): return .string(substitute(s, label: label))
        case .array(let a): return .array(a.map { resolveLabels(in: $0, label: label) })
        case .object(let o): return .object(o.mapValues { resolveLabels(in: $0, label: label) })
        default: return value
        }
    }

    /// Drops top-level input keys not declared in the tool's input-schema
    /// `properties`. Recovers a strict-input node from a leaked extra key (the
    /// model occasionally adds one). No-op on a non-strict / propertiless schema.
    public static func prune(_ value: JSONValue, toInputSchema schema: JSONValue) -> JSONValue {
        guard case .object(let object) = value,
              case .object(let schemaObject) = schema,
              case .object(let properties)? = schemaObject["properties"]
        else { return value }
        let allowed = Set(properties.keys)
        return .object(object.filter { allowed.contains($0.key) })
    }

    static func tokenIDs(in s: String) -> [String] {
        guard s.contains("{{") else { return [] }
        var ids: [String] = []
        var rest = Substring(s)
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let id = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ids.append(id) }
            rest = rest[close.upperBound...]
        }
        return ids
    }

    private static func substitute(_ s: String, label: (String) -> String?) -> String {
        guard s.contains("{{") else { return s }
        var result = ""
        var rest = Substring(s)
        while let open = rest.range(of: "{{") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                result += rest[open.lowerBound...]
                return result
            }
            let id = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += label(id) ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }
}

// MARK: Round-1 plan

/// One node of a plan/binding: `{id, tool, input}`. The decoder applies the same
/// input hygiene as `WorkflowNode` (null → `{}`, strip leaked node-structural
/// keys), so a model emitting `"input": null` or echoing `id`/`tool` into
/// `input` doesn't break the node.
public struct WorkflowPlanNode: Sendable, Hashable, Codable {
    public var id: String
    public var tool: String?
    public var input: JSONValue

    public init(id: String, tool: String?, input: JSONValue) {
        self.id = id
        self.tool = tool
        self.input = input
    }

    private enum CodingKeys: String, CodingKey { case id, tool, input }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool)
        let raw = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
        self.input = Self.sanitized(raw)
    }
    private static let reserved: Set<String> = [
        "id", "kind", "tool", "depends_on", "policy", "output_policy",
    ]
    private static func sanitized(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return .object([:]) }
        for key in reserved { object.removeValue(forKey: key) }
        return .object(object)
    }
}

/// A declared local-context slot the planner needs filled. `source` is an
/// app-defined harvest-source name (the harvester interprets it).
public struct WorkflowContextSlot: Sendable, Hashable, Codable {
    public var slotID: String
    public var source: String
    public var reason: String
    public var required: Bool

    public init(slotID: String, source: String, reason: String = "", required: Bool = true) {
        self.slotID = slotID
        self.source = source
        self.reason = reason
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case slotID = "slot_id"
        case source, reason, required
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.slotID = try c.decode(String.self, forKey: .slotID)
        self.source = try c.decode(String.self, forKey: .source)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

public struct WorkflowPlan: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case selfContained = "self_contained"
        case requiresBinding = "requires_binding"
        case cannotPlan = "cannot_plan"
    }

    public var schemaVersion: String
    public var outcome: Outcome
    public var intentSummary: String
    public var nodes: [WorkflowPlanNode]
    public var contextSlots: [WorkflowContextSlot]
    public var message: String?

    public init(
        schemaVersion: String = WorkflowTwoRound.schemaVersion,
        outcome: Outcome,
        intentSummary: String = "",
        nodes: [WorkflowPlanNode],
        contextSlots: [WorkflowContextSlot] = [],
        message: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.outcome = outcome
        self.intentSummary = intentSummary
        self.nodes = nodes
        self.contextSlots = contextSlots
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case outcome
        case intentSummary = "intent_summary"
        case nodes
        case contextSlots = "context_slots"
        case message
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? WorkflowTwoRound.schemaVersion
        self.outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .requiresBinding
        self.intentSummary = try c.decodeIfPresent(String.self, forKey: .intentSummary) ?? ""
        self.nodes = try c.decodeIfPresent([WorkflowPlanNode].self, forKey: .nodes) ?? []
        self.contextSlots = try c.decodeIfPresent([WorkflowContextSlot].self, forKey: .contextSlots) ?? []
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
    }

    /// Effective outcome derived from *structure* rather than the label: a plan
    /// with no slot placeholders/declarations is self-contained even if the
    /// model said "requires_binding". `cannot_plan` is always honoured.
    public var effectiveOutcome: Outcome {
        if outcome == .cannotPlan { return .cannotPlan }
        let hasSlots = !contextSlots.isEmpty
            || nodes.contains { !TwoRoundValue.slotIDs(in: $0.input).isEmpty }
        return hasSlots ? .requiresBinding : .selfContained
    }
}

// MARK: Harvest packet

public struct HarvestedCandidate: Sendable, Hashable {
    public let candidateID: String
    public let label: String
    public let kind: String
    public let value: JSONValue
    public let isCurrent: Bool

    public init(candidateID: String, label: String, kind: String, value: JSONValue, isCurrent: Bool) {
        self.candidateID = candidateID
        self.label = label
        self.kind = kind
        self.value = value
        self.isCurrent = isCurrent
    }

    /// The bare display name for `{{slot}}` substitution — the label minus a
    /// trailing provenance hint ("(open in editor)").
    public var displayLabel: String {
        guard let paren = label.firstIndex(of: "(") else { return label }
        return String(label[..<paren]).trimmingCharacters(in: .whitespaces)
    }
}

public struct HarvestedSlot: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable { case resolved, missing }
    public let slotID: String
    public let source: String
    public let status: Status
    public let candidates: [HarvestedCandidate]
    public let required: Bool

    public init(slotID: String, source: String, status: Status, candidates: [HarvestedCandidate], required: Bool) {
        self.slotID = slotID
        self.source = source
        self.status = status
        self.candidates = candidates
        self.required = required
    }
}

public struct ContextPacket: Sendable, Hashable {
    public var slots: [HarvestedSlot]
    public init(slots: [HarvestedSlot]) { self.slots = slots }

    public var candidatesByID: [String: HarvestedCandidate] {
        Dictionary(slots.flatMap(\.candidates).map { ($0.candidateID, $0) }, uniquingKeysWith: { a, _ in a })
    }
    public func candidateIDs(forSlot slotID: String) -> Set<String> {
        Set(slots.first { $0.slotID == slotID }?.candidates.map(\.candidateID) ?? [])
    }
    public func slot(_ slotID: String) -> HarvestedSlot? {
        slots.first { $0.slotID == slotID }
    }
    public var requiredMissingSlots: [String] {
        slots.filter { $0.required && $0.status == .missing }.map(\.slotID)
    }

    /// A human-readable rendering for the Binder prompt (candidate ids + labels;
    /// values are *not* shown — the Binder binds by candidate id).
    public func renderForBinder() -> String {
        var lines: [String] = []
        for slot in slots {
            if slot.status == .missing {
                lines.append("- slot \"\(slot.slotID)\" (\(slot.source)): MISSING — no candidate available.")
                continue
            }
            lines.append("- slot \"\(slot.slotID)\" (\(slot.source)):")
            for c in slot.candidates {
                let marker = c.isCurrent ? " [current/foreground]" : ""
                lines.append("    • candidate_id \"\(c.candidateID)\": \(c.label)\(marker)")
            }
        }
        return lines.isEmpty ? "(no context slots)" : lines.joined(separator: "\n")
    }
}

/// A deterministic, local-only resolver of declared context slots. Implementors
/// read trusted local state (current selection, foreground doc, defaults), rank
/// the foreground/current candidate first, cap the count, and report missing —
/// never fabricate. NO LLM, NO side-effecting tools.
public protocol ContextHarvesting: Sendable {
    func harvest(_ slots: [WorkflowContextSlot]) async -> ContextPacket
}

// MARK: Round-2 binding

public struct WorkflowBinding: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case complete
        case cannotBind = "cannot_bind"
    }
    public var status: Status
    public var nodes: [WorkflowPlanNode]
    public var missingSlots: [String]
    public var message: String?

    public init(status: Status, nodes: [WorkflowPlanNode], missingSlots: [String] = [], message: String? = nil) {
        self.status = status
        self.nodes = nodes
        self.missingSlots = missingSlots
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case status = "binding_status"
        case nodes
        case missingSlots = "missing_slots"
        case message
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .complete
        self.nodes = try c.decodeIfPresent([WorkflowPlanNode].self, forKey: .nodes) ?? []
        self.missingSlots = try c.decodeIfPresent([String].self, forKey: .missingSlots) ?? []
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

// MARK: Plan cache

/// Caches the LLM-produced Round-1 plan keyed on `(normalized intent · tool set ·
/// schema version)`. A repeat of an intent reuses the plan and skips the planner
/// call; harvest + bind still re-run against the *current* context, so the result
/// stays fresh. A hit is re-validated, so it is never less reliable than a miss.
public actor WorkflowPlanCache {
    private var entries: [String: WorkflowPlan] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    public static func key(intent: String, toolNames: Set<String>) -> String {
        let normalized = intent
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let tools = toolNames.sorted().joined(separator: ",")
        return "\(WorkflowTwoRound.schemaVersion)|\(tools)|\(normalized)"
    }

    public func lookup(_ key: String) -> WorkflowPlan? {
        if let plan = entries[key] { hits += 1; return plan }
        misses += 1
        return nil
    }

    public func store(_ plan: WorkflowPlan, for key: String) {
        entries[key] = plan
    }
}
