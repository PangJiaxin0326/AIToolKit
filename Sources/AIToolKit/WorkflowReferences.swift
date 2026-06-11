import Foundation
import FoundationModels

public enum WorkflowReferenceResolver {
    public static func references(in value: GeneratedContent) -> [WorkflowReference] {
        switch value.kind {
        case .structure(let object, _):
            if let reference = referenceObject(object) {
                return [reference]
            }
            if object.count == 1, object["$literal"] != nil {
                return []
            }
            return object.values.flatMap(references)
        case .array(let values):
            return values.flatMap(references)
        case .null, .bool, .number, .string:
            return []
        @unknown default:
            return []
        }
    }

    public static func resolve(
        _ value: GeneratedContent,
        outputs: [String: GeneratedContent],
        context: GeneratedContent = .object([:]),
        userInput: GeneratedContent = .object([:]),
        currentNodeID: String
    ) throws -> GeneratedContent {
        switch value.kind {
        case .structure(let object, _):
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
            var resolved: [String: GeneratedContent] = [:]
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
        case .string(let s):
            // Text interpolation: a `{{<node id>/<path>}}` token embeds an
            // earlier node's output *inside* a string (a `$ref` can only
            // replace the whole field). Tokens that don't resolve — not a
            // node output, bad pointer — are left intact rather than thrown:
            // by execution time any slot tokens were already substituted at
            // bind, so an unresolved token degrades to literal text instead
            // of failing the node.
            guard s.contains("{{") else { return value }
            return TwoRoundValue.resolveLabels(in: value) { token in
                guard let slash = token.firstIndex(of: "/") else { return nil }
                guard let root = outputs[String(token[..<slash])] else { return nil }
                let resolved = try? resolvePointer(
                    String(token[slash...]),
                    in: root,
                    currentNodeID: currentNodeID,
                    display: "node:\(token)"
                )
                guard let resolved else { return nil }
                return WorkflowFinalRenderer.displayString(resolved)
            }
        case .null, .bool, .number:
            return value
        @unknown default:
            return value
        }
    }

    public static func resolve(
        _ reference: WorkflowReference,
        outputs: [String: GeneratedContent],
        context: GeneratedContent = .object([:]),
        userInput: GeneratedContent = .object([:]),
        currentNodeID: String
    ) throws -> GeneratedContent {
        let root: GeneratedContent?
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

    static func referenceObject(_ object: [String: GeneratedContent]) -> WorkflowReference? {
        guard object.count == 1, let ref = object["$ref"] else { return nil }
        switch ref.kind {
        case .string(let compact):
            // Compact node reference (the v2.2 planner contract's taught
            // form): "<node id>/<json pointer>" — "f/contactID" means node
            // "f", path "/contactID"; a bare "f" means the whole output.
            guard !compact.isEmpty, !compact.hasPrefix("/") else { return nil }
            if let slash = compact.firstIndex(of: "/") {
                let node = String(compact[..<slash])
                let path = String(compact[slash...])
                guard !node.isEmpty else { return nil }
                return WorkflowReference(source: .node, node: node, path: path)
            }
            return WorkflowReference(source: .node, node: compact, path: "")
        case .structure(let raw, _):
            // Canonical object form. `source` defaults to "node" — the
            // overwhelmingly common case, and the one the lean planner
            // contract omits to save output tokens. A `$ref` with neither
            // `source` nor `node` is not a reference.
            let source: WorkflowReference.Source
            if case .string(let sourceRaw)? = raw["source"]?.kind {
                guard let parsed = WorkflowReference.Source(rawValue: sourceRaw) else { return nil }
                source = parsed
            } else if raw["node"] != nil {
                source = .node
            } else {
                return nil
            }
            let node = raw["node"]?.stringValue
            let path = raw["path"]?.stringValue ?? ""
            return WorkflowReference(source: source, node: node, path: path)
        default:
            return nil
        }
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
        in value: GeneratedContent,
        currentNodeID: String,
        display: String
    ) throws -> GeneratedContent {
        // Models frequently emit "/" to mean "the root", which is technically
        // not RFC 6901 ("/" is the empty-string-keyed property of the root).
        // Treat it as an alias for "" — the alternative is a hard failure on
        // an LLM convention that's effectively impossible to coach away.
        if pointer.isEmpty || pointer == "/" { return value }
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
            switch current.kind {
            case .structure(let object, _):
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
            case .null, .bool, .number, .string:
                throw WorkflowError.unresolvedReference(
                    nodeID: currentNodeID, reference: display
                )
            @unknown default:
                throw WorkflowError.unresolvedReference(
                    nodeID: currentNodeID, reference: display
                )
            }
        }
        return current
    }
}
