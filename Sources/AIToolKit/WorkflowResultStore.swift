import Foundation

public actor WorkflowResultStore {
    private var outputs: [String: JSONValue] = [:]

    public init() {}

    public func set(_ output: JSONValue, for nodeID: String) {
        outputs[nodeID] = output
    }

    public func output(for nodeID: String) -> JSONValue? {
        outputs[nodeID]
    }

    public func snapshot() -> [String: JSONValue] {
        outputs
    }
}

public enum WorkflowFinalRenderer {
    public static func render(
        _ final: WorkflowFinal,
        outputs: [String: JSONValue],
        context: JSONValue = .object([:]),
        userInput: JSONValue = .object([:])
    ) throws -> (value: JSONValue, text: String?) {
        switch final.kind {
        case .value:
            let value = try WorkflowReferenceResolver.resolve(
                final.value ?? .null,
                outputs: outputs,
                context: context,
                userInput: userInput,
                currentNodeID: "final"
            )
            return (value, displayString(value))
        case .template:
            let text = try renderTemplate(
                final.template ?? "",
                bindings: final.bindings,
                outputs: outputs,
                context: context,
                userInput: userInput
            )
            return (.string(text), text)
        case .nodeOutput:
            let node = final.node ?? ""
            let root = outputs[node]
            guard let root else {
                throw WorkflowError.unresolvedReference(
                    nodeID: "final",
                    reference: "node:\(node)"
                )
            }
            let value = try WorkflowReferenceResolver.resolvePointer(
                final.path ?? "",
                in: root,
                currentNodeID: "final",
                display: "node:\(node)\(final.path ?? "")"
            )
            return (value, displayString(value))
        case .message:
            let text = final.message ?? ""
            return (.string(text), text)
        }
    }

    private static func renderTemplate(
        _ template: String,
        bindings: [String: JSONValue],
        outputs: [String: JSONValue],
        context: JSONValue,
        userInput: JSONValue
    ) throws -> String {
        var resolvedBindings: [String: String] = [:]
        for (name, value) in bindings {
            let resolved = try WorkflowReferenceResolver.resolve(
                value,
                outputs: outputs,
                context: context,
                userInput: userInput,
                currentNodeID: "final"
            )
            resolvedBindings[name] = displayString(resolved)
        }
        var result = template
        for (name, value) in resolvedBindings {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    public static func displayString(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .number(let value):
            return String(value)
        case .string(let value):
            return value
        case .array, .object:
            guard let data = try? value.data(),
                  let text = String(data: data, encoding: .utf8)
            else { return "\(value)" }
            return text
        }
    }
}
