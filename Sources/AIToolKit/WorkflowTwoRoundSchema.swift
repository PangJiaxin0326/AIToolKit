import Foundation

/// Strict, *lean* JSON schemas for the two round trips (for providers that
/// support `response_format: json_schema`). Lean = only the fields the runtime
/// can't default, so output tokens stay minimal; `input` is an open object (the
/// value algebra lives inside it). Freeform + a worked example is usually as
/// reliable and cheaper — see `WorkflowTwoRoundPrompt`.
public enum WorkflowTwoRoundSchema {
    /// Round-1 Planner response schema. `sources` = the recognized context
    /// source names the planner may declare.
    public static func planner(toolNames: [String], sources: [String]) -> JSONValue {
        let node = ToolSchema.strictObject(
            properties: [
                "id": .string(description: "Unique snake_case node id."),
                "tool": .stringEnum(toolNames.sorted()),
                "input": .unknownObject,
            ],
            required: ["id", "tool", "input"]
        )
        // Lean slot: {slot_id, source} only. `reason`/`required` are derivable
        // (required defaults true) and were pure output tokens — dropped so the
        // strict schema can't force them. `intent_summary` likewise dropped (v2.1).
        let slot = ToolSchema.strictObject(
            properties: [
                "slot_id": .string(description: "Stable id referenced by {\"$slot\":…} / {{slot_id}}."),
                "source": .stringEnum(sources.sorted()),
            ],
            required: ["slot_id", "source"]
        )
        return ToolSchema.strictObject(
            properties: [
                "outcome": .stringEnum(["self_contained", "requires_binding", "cannot_plan"]),
                "nodes": .array(of: node, maxItems: 24),
                "context_slots": .array(of: slot, maxItems: 12),
                "message": .nullable(.string),
            ],
            required: ["outcome", "nodes", "context_slots", "message"]
        ).json
    }

    /// Round-2 Binder response schema (Schema A: the full bound node list).
    public static func binder(toolNames: [String]) -> JSONValue {
        let node = ToolSchema.strictObject(
            properties: [
                "id": .string(description: "Must match the plan node id."),
                "tool": .stringEnum(toolNames.sorted()),
                "input": .unknownObject,
            ],
            required: ["id", "tool", "input"]
        )
        return ToolSchema.strictObject(
            properties: [
                "binding_status": .stringEnum(["complete", "cannot_bind"]),
                "nodes": .array(of: node, maxItems: 24),
                "missing_slots": .array(of: .string, maxItems: 12),
                "message": .nullable(.string),
            ],
            required: ["binding_status", "nodes", "missing_slots", "message"]
        ).json
    }
}
