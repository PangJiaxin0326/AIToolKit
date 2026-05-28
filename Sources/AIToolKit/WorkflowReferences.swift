import Foundation

public enum WorkflowReferenceResolver {
    public static func references(in value: JSONValue) -> [WorkflowReference] {
        switch value {
        case .object(let object):
            if let reference = referenceObject(object) {
                return [reference]
            }
            if object.count == 1, object["$literal"] != nil {
                return []
            }
            return object.values.flatMap(references)
        case .array(let values):
            return values.flatMap(references)
        case .null, .bool, .int, .number, .string:
            return []
        }
    }

    public static func resolve(
        _ value: JSONValue,
        outputs: [String: JSONValue],
        context: JSONValue = .object([:]),
        userInput: JSONValue = .object([:]),
        currentNodeID: String
    ) throws -> JSONValue {
        switch value {
        case .object(let object):
            if let literal = object["$literal"], object.count == 1 {
                return literal
            }
            if let reference = referenceObject(object) {
                return try resolve(
                    reference,
                    outputs: outputs,
                    context: context,
                    userInput: userInput,
                    currentNodeID: currentNodeID
                )
            }
            var resolved: [String: JSONValue] = [:]
            for (key, child) in object {
                resolved[key] = try resolve(
                    child,
                    outputs: outputs,
                    context: context,
                    userInput: userInput,
                    currentNodeID: currentNodeID
                )
            }
            return .object(resolved)
        case .array(let values):
            return .array(try values.map {
                try resolve(
                    $0,
                    outputs: outputs,
                    context: context,
                    userInput: userInput,
                    currentNodeID: currentNodeID
                )
            })
        case .null, .bool, .int, .number, .string:
            return value
        }
    }

    public static func resolve(
        _ reference: WorkflowReference,
        outputs: [String: JSONValue],
        context: JSONValue = .object([:]),
        userInput: JSONValue = .object([:]),
        currentNodeID: String
    ) throws -> JSONValue {
        let root: JSONValue?
        switch reference.source {
        case .node:
            guard let node = reference.node, !node.isEmpty else {
                throw WorkflowError.invalidReference(
                    nodeID: currentNodeID,
                    reason: "node source requires node id"
                )
            }
            root = outputs[node]
        case .context:
            root = context
        case .userInput:
            root = userInput
        case .item:
            throw WorkflowError.invalidReference(
                nodeID: currentNodeID,
                reason: "item references require fanout support"
            )
        }
        guard let root else {
            throw WorkflowError.unresolvedReference(
                nodeID: currentNodeID,
                reference: display(reference)
            )
        }
        return try resolvePointer(
            reference.path,
            in: root,
            currentNodeID: currentNodeID,
            display: display(reference)
        )
    }

    static func referenceObject(_ object: [String: JSONValue]) -> WorkflowReference? {
        guard object.count == 1,
              case .object(let raw)? = object["$ref"],
              case .string(let sourceRaw)? = raw["source"],
              let source = WorkflowReference.Source(rawValue: sourceRaw)
        else { return nil }
        let node = raw["node"]?.stringValue
        let path = raw["path"]?.stringValue ?? ""
        return WorkflowReference(source: source, node: node, path: path)
    }

    static func display(_ reference: WorkflowReference) -> String {
        switch reference.source {
        case .node:
            return "node:\(reference.node ?? "")\(reference.path)"
        case .context:
            return "context:\(reference.path)"
        case .userInput:
            return "user_input:\(reference.path)"
        case .item:
            return "item:\(reference.path)"
        }
    }

    public static func resolvePointer(
        _ pointer: String,
        in value: JSONValue,
        currentNodeID: String,
        display: String
    ) throws -> JSONValue {
        if pointer.isEmpty { return value }
        guard pointer.hasPrefix("/") else {
            throw WorkflowError.invalidReference(
                nodeID: currentNodeID,
                reason: "JSON Pointer must be empty or start with /: \(pointer)"
            )
        }
        var current = value
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let object):
                guard let next = object[String(token)] else {
                    throw WorkflowError.unresolvedReference(
                        nodeID: currentNodeID, reference: display
                    )
                }
                current = next
            case .array(let values):
                guard let index = Int(token), values.indices.contains(index) else {
                    throw WorkflowError.unresolvedReference(
                        nodeID: currentNodeID, reference: display
                    )
                }
                current = values[index]
            case .null, .bool, .int, .number, .string:
                throw WorkflowError.unresolvedReference(
                    nodeID: currentNodeID, reference: display
                )
            }
        }
        return current
    }
}
