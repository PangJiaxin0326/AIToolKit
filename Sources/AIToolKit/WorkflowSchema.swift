import Foundation

public enum WorkflowSchema {
    public static func descriptor(availableTools: [ToolDescriptor]) -> ToolDescriptor {
        ToolDescriptor(
            name: WorkflowSpec.toolName,
            description: """
            Execute one validated AI tool workflow. Use this for multi-tool \
            tasks, parallel independent lookups, ordered side effects, or \
            inputs that depend on earlier tool outputs. The app executes the \
            workflow DAG locally and does not call the model again.
            """,
            inputSchema: specSchema(availableTools: availableTools).json,
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
}

public enum WorkflowPromptBuilder {
    public static func planningInstruction(toolManifest: [ToolDescriptor]) -> String {
        let tools = toolManifest
            .map { descriptor in
                var line = "- \(descriptor.name): \(descriptor.description)"
                if let output = descriptor.outputSchema,
                   let text = jsonString(output) {
                    line += " Output schema: \(text)"
                }
                if let annotations = descriptor.annotations {
                    line += " Side effect: \(annotations.sideEffect.rawValue)."
                }
                return line
            }
            .joined(separator: "\n")
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
