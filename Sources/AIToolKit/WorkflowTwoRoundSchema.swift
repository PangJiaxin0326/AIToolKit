import Foundation

/// Strict, lean JSON schemas for hosts that explicitly opt into provider
/// `response_format: json_schema`. The validated v2.1 recipe leaves the planner
/// freeform, but this schema mirrors the same lean contract instead of the
/// legacy verbose envelope. `input` stays open because the value algebra lives
/// inside it.
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
        let slot = ToolSchema.strictObject(
            properties: [
                "slot_id": .string(description: "Stable id referenced by {\"$slot\":...} / {{slot_id}}."),
                "source": .stringEnum(sources.sorted()),
            ],
            required: ["slot_id", "source"]
        )
        return ToolSchema.strictObject(
            properties: [
                "nodes": .array(of: node, maxItems: 24),
                "context_slots": .array(of: slot, maxItems: 12),
                "outcome": .stringEnum(["cannot_plan"]),
                "message": .nullable(.string),
            ],
            required: ["nodes", "context_slots"]
        ).json
    }

    /// Round-2 Binder response schema (full bound node list).
    /// AIKit's v2.1 runner keeps the Binder freeform; this schema is retained as
    /// a library asset for hosts that experiment outside the validated recipe.
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
