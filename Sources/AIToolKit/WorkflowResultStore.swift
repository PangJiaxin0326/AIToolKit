import Foundation
import FoundationModels

public actor WorkflowResultStore {
    private var outputs: [String: GeneratedContent] = [:]

    public init() {}

    public func set(_ output: GeneratedContent, for nodeID: String) {
        outputs[nodeID] = output
    }

    public func output(for nodeID: String) -> GeneratedContent? {
        outputs[nodeID]
    }

    public func snapshot() -> [String: GeneratedContent] {
        outputs
    }
}

public enum WorkflowFinalRenderer {
    public static func render(
        _ final: WorkflowFinal,
        outputs: [String: GeneratedContent],
        context: GeneratedContent = .object([:]),
        userInput: GeneratedContent = .object([:])
    ) throws -> (value: GeneratedContent, text: String?) {
        switch final.kind {
        case .value:
            let value = try WorkflowReferenceResolver.resolve(
                final.value ?? .nullContent,
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
        bindings: [String: GeneratedContent],
        outputs: [String: GeneratedContent],
        context: GeneratedContent,
        userInput: GeneratedContent
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

    public static func displayString(_ value: GeneratedContent) -> String {
        switch value.kind {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return String(value)
        case .string(let value):
            return value
        case .array, .structure:
            return value.jsonString
        @unknown default:
            return value.jsonString
        }
    }
}
