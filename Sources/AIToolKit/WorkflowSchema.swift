import Foundation
import FoundationModels

public enum WorkflowSchema {
    public static func descriptor(
        availableTools: [ToolDescriptor],
        minimal: Bool = false
    ) -> ToolDescriptor {
        ToolDescriptor(
            name: WorkflowSpec.toolName,
            description: """
            Execute one validated AI tool workflow. Use this for multi-tool \
            tasks, parallel independent lookups, ordered side effects, or \
            inputs that depend on earlier tool outputs. The app executes the \
            workflow DAG locally and does not call the model again.
            """,
            argumentsSchema: minimal
                ? minimalSpecSchema(availableTools: availableTools)
                : specSchema(availableTools: availableTools),
            outputSchema: GeneratedContent.generationSchema,
            annotations: ToolAnnotations(
                isReadOnly: false,
                isIdempotent: false,
                sideEffect: .unknown,
                requiresUserApproval: false,
                allowedWithoutNetwork: true,
                resultSummaryHint: "Workflow execution result."
            )
        )
    }

    public static func specSchema(availableTools: [ToolDescriptor]) -> GenerationSchema {
        let toolNames = availableTools.map(\.name).sorted()
        let retry = DynamicGenerationSchema(
            name: "WorkflowRetryPolicy",
            properties: [
                property("max_attempts", integer),
                property("backoff_ms", integer),
                property("retry_only_if_tool_error_is_retriable", boolean),
            ]
        )
        let policy = DynamicGenerationSchema(
            name: "WorkflowNodePolicy",
            properties: [
                property("timeout_ms", integer),
                property("retry", retry),
                property("on_error", stringEnum(["abort", "continue_with_null", "continue_with_default", "skip_dependents"])),
                property("default_output", nullable("NullableDefaultOutput", jsonContent)),
            ]
        )
        let outputPolicy = DynamicGenerationSchema(
            name: "WorkflowOutputPolicy",
            properties: [
                property("store", boolean),
                property("expose_to_final", boolean),
                property("max_bytes", integer),
                property("redaction", stringEnum(["none", "tool_default"])),
            ]
        )
        let node = DynamicGenerationSchema(
            name: "WorkflowNode",
            properties: [
                property("id", string, description: "Unique snake_case node id."),
                property("kind", stringEnum(["tool"])),
                property("tool", stringEnum(toolNames)),
                property("depends_on", array(of: string, maximumElements: 12)),
                property("input", jsonContent),
                property("policy", policy),
                property("output_policy", outputPolicy),
            ]
        )
        let final = DynamicGenerationSchema(
            name: "WorkflowFinal",
            properties: [
                property("kind", stringEnum(["value", "template", "node_output", "message"])),
                property("value", nullable("NullableFinalValue", jsonContent)),
                property("template", nullable("NullableFinalTemplate", string), description: "Template with {{binding}} placeholders."),
                property("bindings", jsonContent),
                property("node", nullable("NullableFinalNode", string), description: "Node id for node_output final."),
                property("path", nullable("NullableFinalPath", string), description: "JSON Pointer path for node_output final."),
                property("message", nullable("NullableFinalMessage", string), description: "Message for clarification/unsupported mode."),
            ]
        )
        let limits = DynamicGenerationSchema(
            name: "WorkflowLimits",
            properties: [
                property("max_nodes", integer),
                property("max_parallelism", integer),
                property("deadline_ms", integer),
                property("max_output_bytes_per_node", integer),
            ]
        )
        let root = DynamicGenerationSchema(
            name: "WorkflowSpec",
            properties: [
                property("schema_version", stringEnum([WorkflowSpec.schemaVersion])),
                property("workflow_id", string, description: "Stable workflow id for tracing."),
                property("intent", string, description: "Human-readable workflow summary."),
                property("mode", stringEnum(["execute", "dry_run", "needs_clarification", "unsupported"])),
                property("nodes", array(of: node, minimumElements: 1, maximumElements: 24)),
                property("final", final),
                property("limits", limits),
                property("metadata", jsonContent),
            ]
        )
        return generationSchema(root)
    }

    /// Minimal output-token schema for `response_format`. Constrains the model
    /// to emit ONLY `{schema_version, nodes:[{id, tool, input}]}` — no policy,
    /// output_policy, limits, final, metadata, intent, mode, workflow_id, or
    /// even depends_on. The runtime fills every omitted field with a default
    /// (see `WorkflowSpec.init(from:)`), and node dependencies are derived
    /// from `$ref`s in `input` (see `WorkflowValidator`). Pairs with a minimal
    /// worked example so the generated DAG is as compact as the task allows.
    public static func minimalSpecSchema(availableTools: [ToolDescriptor]) -> GenerationSchema {
        let toolNames = availableTools.map(\.name).sorted()
        let node = DynamicGenerationSchema(
            name: "MinimalWorkflowNode",
            properties: [
                property("id", string, description: "Unique snake_case node id."),
                property("tool", stringEnum(toolNames)),
                property("input", jsonContent),
            ]
        )
        let root = DynamicGenerationSchema(
            name: "MinimalWorkflowSpec",
            properties: [
                property("schema_version", stringEnum([WorkflowSpec.schemaVersion])),
                property("nodes", array(of: node, minimumElements: 1, maximumElements: 24)),
            ]
        )
        return generationSchema(root)
    }
}

public enum WorkflowPromptBuilder {
    /// One fixed, general, lean worked example. Measured to be **load-bearing**:
    /// the schema fixes *structure*, but the example supplies *semantics* (which
    /// tools, how to wire `$ref`, that a plan ends in an action) — without it
    /// even a strong model emits structurally-valid-but-empty plans, and a
    /// strict `response_format` cannot substitute for it. Use the SAME example
    /// every request; do not tailor it per task. The names are illustrative —
    /// the model adapts them to the actual manifest.
    public static func workedExample() -> String {
        """
        Example WorkflowSpec (general template — adapt the tools/values to the \
        actual request; never copy these literal values):
        {"schema_version":"\(WorkflowSpec.schemaVersion)","nodes":[\
        {"id":"find_bob","tool":"find_contact","input":{"query":"Bob Singh"}},\
        {"id":"send","tool":"send_message","input":{"contactID":{"$ref":{"source":"node","node":"find_bob","path":"/contactID"}},"body":"Hi Bob."}}\
        ]}
        """
    }

    /// - Parameter includeExample: append the load-bearing `workedExample()`.
    ///   Recommended (and the default) for the lean `minimal` path.
    public static func planningInstruction(
        toolManifest: [ToolDescriptor],
        minimal: Bool = false,
        includeExample: Bool = true
    ) -> String {
        let tools = toolManifest
            .map { descriptor in
                var line = "- \(descriptor.name): \(descriptor.description)"
                if let text = try? descriptor.argumentsSchema.jsonString() {
                    line += " Arguments schema: \(text)"
                }
                if let output = descriptor.outputSchema,
                   let text = try? output.jsonString() {
                    line += " Output schema: \(text)"
                }
                if let examples = descriptor.argumentExamples,
                   !examples.isEmpty,
                   let text = jsonString(.array(examples)) {
                    line += " Argument examples: \(text)"
                }
                if let annotations = descriptor.annotations {
                    line += " Side effect: \(annotations.sideEffect.rawValue)."
                }
                return line
            }
            .joined(separator: "\n")
        if minimal {
            let example = includeExample ? "\n\n" + workedExample() : ""
            return """
            For requests requiring tools, call the synthetic \
            \(WorkflowSpec.toolName) tool with one WorkflowSpec object. Do not \
            emit separate tool calls.

            WorkflowSpec is a topological DAG. Emit only \
            schema_version "\(WorkflowSpec.schemaVersion)" and a `nodes` array. \
            Each node has exactly three fields: id, tool, input — omit \
            everything else (no kind, depends_on, policy, output_policy, \
            limits, final, intent, metadata). `input` holds ONLY that tool's own \
            parameters — never put id, tool, or depends_on inside input. Put \
            independent source nodes first; a node depends on another only by \
            referencing its output in `input` with {"$ref":{"source":"node",\
            "node":"node_id","path":"/field"}} (JSON Pointer). Do not copy \
            intermediate outputs; reference them. The app fills all omitted \
            fields and executes the DAG locally.

            Available workflow node tools:
            \(tools)\(example)
            """
        }
        return """
        For requests requiring tools, emit one WorkflowSpec JSON object, a \
        fenced `workflow` block containing that object, or call the synthetic \
        \(WorkflowSpec.toolName) tool with that object. Do not emit separate \
        tool calls. Use schema_version "\(WorkflowSpec.schemaVersion)".

        WorkflowSpec is a topological DAG. Put independent read/source nodes \
        first, then later nodes with inputs using {"$ref":{"source":"node",\
        "node":"node_id","path":"/field"}}. Use JSON Pointer paths. Do not \
        copy intermediate tool outputs into the plan; reference them. Include \
        every required field: workflow_id, intent, mode, nodes, final, limits, \
        metadata. The app executes the DAG locally and does not call the model \
        again, so final must be deterministic: node_output, value, template, \
        or message.

        Available workflow node tools:
        \(tools)
        """
    }

    private static func jsonString(_ value: GeneratedContent) -> String? {
        value.jsonString
    }
}

private let string = DynamicGenerationSchema(type: String.self)
private let integer = DynamicGenerationSchema(type: Int.self)
private let boolean = DynamicGenerationSchema(type: Bool.self)
private let jsonContent = DynamicGenerationSchema(type: GeneratedContent.self)

private func property(
    _ name: String,
    _ schema: DynamicGenerationSchema,
    description: String? = nil
) -> DynamicGenerationSchema.Property {
    DynamicGenerationSchema.Property(
        name: name,
        description: description,
        schema: schema
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

private func generationSchema(_ root: DynamicGenerationSchema) -> GenerationSchema {
    do {
        return try GenerationSchema(root: root, dependencies: [])
    } catch {
        preconditionFailure("Invalid built-in workflow GenerationSchema: \(error)")
    }
}
