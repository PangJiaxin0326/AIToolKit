import Foundation

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
            inputSchema: (minimal
                ? minimalSpecSchema(availableTools: availableTools)
                : specSchema(availableTools: availableTools)).json,
            outputSchema: ToolSchema.unknownObject.json,
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

    public static func specSchema(availableTools: [ToolDescriptor]) -> ToolSchema {
        let toolNames = availableTools.map(\.name).sorted()
        let retry = ToolSchema.strictObject(
            properties: [
                "max_attempts": .integer,
                "backoff_ms": .integer,
                "retry_only_if_tool_error_is_retriable": .boolean,
            ],
            required: ["max_attempts", "backoff_ms", "retry_only_if_tool_error_is_retriable"]
        )
        let policy = ToolSchema.strictObject(
            properties: [
                "timeout_ms": .integer,
                "retry": retry,
                "on_error": .stringEnum(["abort", "continue_with_null", "continue_with_default", "skip_dependents"]),
                "default_output": .nullable(.unknownObject),
            ],
            required: ["timeout_ms", "retry", "on_error", "default_output"]
        )
        let outputPolicy = ToolSchema.strictObject(
            properties: [
                "store": .boolean,
                "expose_to_final": .boolean,
                "max_bytes": .integer,
                "redaction": .stringEnum(["none", "tool_default"]),
            ],
            required: ["store", "expose_to_final", "max_bytes", "redaction"]
        )
        let node = ToolSchema.strictObject(
            properties: [
                "id": .string(description: "Unique snake_case node id."),
                "kind": .stringEnum(["tool"]),
                "tool": .stringEnum(toolNames),
                "depends_on": .array(of: .string, maxItems: 12),
                "input": .unknownObject,
                "policy": policy,
                "output_policy": outputPolicy,
            ],
            required: ["id", "kind", "tool", "depends_on", "input", "policy", "output_policy"]
        )
        let final = ToolSchema.strictObject(
            properties: [
                "kind": .stringEnum(["value", "template", "node_output", "message"]),
                "value": .nullable(.any),
                "template": .nullable(.string(description: "Template with {{binding}} placeholders.")),
                "bindings": .unknownObject,
                "node": .nullable(.string(description: "Node id for node_output final.")),
                "path": .nullable(.string(description: "JSON Pointer path for node_output final.")),
                "message": .nullable(.string(description: "Message for clarification/unsupported mode.")),
            ],
            required: ["kind", "value", "template", "bindings", "node", "path", "message"]
        )
        let limits = ToolSchema.strictObject(
            properties: [
                "max_nodes": .integer,
                "max_parallelism": .integer,
                "deadline_ms": .integer,
                "max_output_bytes_per_node": .integer,
            ],
            required: ["max_nodes", "max_parallelism", "deadline_ms", "max_output_bytes_per_node"]
        )
        return .strictObject(
            properties: [
                "schema_version": .constant(.string(WorkflowSpec.schemaVersion)),
                "workflow_id": .string(description: "Stable workflow id for tracing."),
                "intent": .string(description: "Human-readable workflow summary."),
                "mode": .stringEnum(["execute", "dry_run", "needs_clarification", "unsupported"]),
                "nodes": .array(of: node, minItems: 1, maxItems: 24),
                "final": final,
                "limits": limits,
                "metadata": .unknownObject,
            ],
            required: ["schema_version", "workflow_id", "intent", "mode", "nodes", "final", "limits", "metadata"]
        )
    }

    /// Minimal output-token schema for `response_format`. Constrains the model
    /// to emit ONLY `{schema_version, nodes:[{id, tool, input}]}` — no policy,
    /// output_policy, limits, final, metadata, intent, mode, workflow_id, or
    /// even depends_on. The runtime fills every omitted field with a default
    /// (see `WorkflowSpec.init(from:)`), and node dependencies are derived
    /// from `$ref`s in `input` (see `WorkflowValidator`). Pairs with a minimal
    /// worked example so the generated DAG is as compact as the task allows.
    public static func minimalSpecSchema(availableTools: [ToolDescriptor]) -> ToolSchema {
        let toolNames = availableTools.map(\.name).sorted()
        let node = ToolSchema.strictObject(
            properties: [
                "id": .string(description: "Unique snake_case node id."),
                "tool": .stringEnum(toolNames),
                "input": .unknownObject,
            ],
            required: ["id", "tool", "input"]
        )
        return .strictObject(
            properties: [
                "schema_version": .constant(.string(WorkflowSpec.schemaVersion)),
                "nodes": .array(of: node, minItems: 1, maxItems: 24),
            ],
            required: ["schema_version", "nodes"]
        )
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
                if let text = jsonString(descriptor.inputSchema) {
                    line += " Input schema: \(text)"
                }
                if let output = descriptor.outputSchema,
                   let text = jsonString(output) {
                    line += " Output schema: \(text)"
                }
                if let examples = descriptor.inputExamples,
                   !examples.isEmpty,
                   let text = jsonString(.array(examples)) {
                    line += " Input examples: \(text)"
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

    private static func jsonString(_ value: JSONValue) -> String? {
        guard let data = try? value.data() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
