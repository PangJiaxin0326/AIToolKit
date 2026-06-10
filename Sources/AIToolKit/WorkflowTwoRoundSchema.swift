import Foundation
import FoundationModels

/// Strict, lean schemas for hosts that explicitly opt into provider
/// `response_format`. The validated v2.1 recipe leaves the planner freeform,
/// but these schemas mirror the same lean contract instead of the legacy
/// verbose envelope. `input` stays open because the value algebra lives inside
/// it.
public enum WorkflowTwoRoundSchema {
    /// Round-1 Planner response schema. `sources` = the recognized context
    /// source names the planner may declare.
    public static func planner(toolNames: [String], sources: [String]) -> GenerationSchema {
        let node = DynamicGenerationSchema(
            name: "TwoRoundPlannerNode",
            properties: [
                twoRoundProperty("id", twoRoundString, description: "Unique snake_case node id."),
                twoRoundProperty("tool", twoRoundStringEnum(toolNames.sorted())),
                twoRoundProperty("input", twoRoundJSONContent),
            ]
        )
        let slot = DynamicGenerationSchema(
            name: "TwoRoundContextSlot",
            properties: [
                twoRoundProperty("slot_id", twoRoundString, description: "Stable id referenced by {\"$slot\":...} / {{slot_id}}."),
                twoRoundProperty("source", twoRoundStringEnum(sources.sorted())),
            ]
        )
        return twoRoundGenerationSchema(DynamicGenerationSchema(
            name: "TwoRoundPlannerResponse",
            properties: [
                twoRoundProperty("nodes", twoRoundArray(of: node, maximumElements: 24)),
                twoRoundProperty("context_slots", twoRoundArray(of: slot, maximumElements: 12)),
                twoRoundProperty("outcome", twoRoundStringEnum(["cannot_plan"]), optional: true),
                twoRoundProperty("message", twoRoundNullable("NullablePlannerMessage", twoRoundString), optional: true),
            ]
        ))
    }

    /// Round-2 Binder response schema (full bound node list).
    /// AIKit's v2.1 runner keeps the Binder freeform; this schema is retained as
    /// a library asset for hosts that experiment outside the validated recipe.
    public static func binder(toolNames: [String]) -> GenerationSchema {
        let node = DynamicGenerationSchema(
            name: "TwoRoundBinderNode",
            properties: [
                twoRoundProperty("id", twoRoundString, description: "Must match the plan node id."),
                twoRoundProperty("tool", twoRoundStringEnum(toolNames.sorted())),
                twoRoundProperty("input", twoRoundJSONContent),
            ]
        )
        return twoRoundGenerationSchema(DynamicGenerationSchema(
            name: "TwoRoundBinderResponse",
            properties: [
                twoRoundProperty("binding_status", twoRoundStringEnum(["complete", "cannot_bind"])),
                twoRoundProperty("nodes", twoRoundArray(of: node, maximumElements: 24)),
                twoRoundProperty("missing_slots", twoRoundArray(of: twoRoundString, maximumElements: 12)),
                twoRoundProperty("message", twoRoundNullable("NullableBinderMessage", twoRoundString)),
            ]
        ))
    }
}

private let twoRoundString = DynamicGenerationSchema(type: String.self)
private let twoRoundJSONContent = DynamicGenerationSchema(type: GeneratedContent.self)

private func twoRoundProperty(
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

private func twoRoundStringEnum(_ values: [String]) -> DynamicGenerationSchema {
    DynamicGenerationSchema(name: "TwoRoundStringEnum", anyOf: values)
}

private func twoRoundNullable(
    _ name: String,
    _ schema: DynamicGenerationSchema
) -> DynamicGenerationSchema {
    DynamicGenerationSchema(name: name, anyOf: [schema, .null])
}

private func twoRoundArray(
    of itemSchema: DynamicGenerationSchema,
    maximumElements: Int? = nil
) -> DynamicGenerationSchema {
    DynamicGenerationSchema(arrayOf: itemSchema, maximumElements: maximumElements)
}

private func twoRoundGenerationSchema(_ root: DynamicGenerationSchema) -> GenerationSchema {
    do {
        return try GenerationSchema(root: root, dependencies: [])
    } catch {
        preconditionFailure("Invalid built-in two-round GenerationSchema: \(error)")
    }
}
