import Foundation
import FoundationModels

/// A small JSON Schema builder for describing tool inputs.
public struct ToolSchema: Sendable, Hashable {
    public var json: JSONValue

    public init(json: JSONValue) {
        self.json = json
    }

    public static let string = ToolSchema(json: .object(["type": .string("string")]))
    public static let number = ToolSchema(json: .object(["type": .string("number")]))
    public static let integer = ToolSchema(json: .object(["type": .string("integer")]))
    public static let boolean = ToolSchema(json: .object(["type": .string("boolean")]))
    public static let any = ToolSchema(json: .object([:]))
    public static let unknownObject = ToolSchema.object(properties: [:])

    public static func string(description: String) -> ToolSchema {
        ToolSchema(json: .object([
            "type": .string("string"),
            "description": .string(description),
        ]))
    }

    public static func stringEnum(
        _ values: [String],
        description: String? = nil
    ) -> ToolSchema {
        var object: [String: JSONValue] = [
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ]
        if let description { object["description"] = .string(description) }
        return ToolSchema(json: .object(object))
    }

    public static func integerEnum(
        _ values: [Int],
        description: String? = nil
    ) -> ToolSchema {
        var object: [String: JSONValue] = [
            "type": .string("integer"),
            "enum": .array(values.map(JSONValue.int)),
        ]
        if let description { object["description"] = .string(description) }
        return ToolSchema(json: .object(object))
    }

    public static func constant(_ value: JSONValue, description: String? = nil) -> ToolSchema {
        var object: [String: JSONValue] = ["const": value]
        if let description { object["description"] = .string(description) }
        return ToolSchema(json: .object(object))
    }

    public static func nullable(_ schema: ToolSchema) -> ToolSchema {
        guard case .object(var object) = schema.json else {
            return ToolSchema(json: .object([
                "anyOf": .array([schema.json, .object(["type": .string("null")])]),
            ]))
        }
        if let type = object["type"] {
            object["type"] = .array([type, .string("null")])
        } else {
            object["anyOf"] = .array([schema.json, .object(["type": .string("null")])])
        }
        return ToolSchema(json: .object(object))
    }

    public static func array(
        of element: ToolSchema,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> ToolSchema {
        var object: [String: JSONValue] = [
            "type": .string("array"),
            "items": element.json,
        ]
        if let description { object["description"] = .string(description) }
        if let minItems { object["minItems"] = .int(minItems) }
        if let maxItems { object["maxItems"] = .int(maxItems) }
        return ToolSchema(json: .object(object))
    }

    public static func object(
        properties: [String: ToolSchema],
        required: [String] = [],
        description: String? = nil
    ) -> ToolSchema {
        let props = properties.mapValues(\.json)
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map(JSONValue.string)),
        ]
        if let description { object["description"] = .string(description) }
        return ToolSchema(json: .object(object))
    }

    public static func strictObject(
        properties: [String: ToolSchema],
        required: [String],
        description: String? = nil
    ) -> ToolSchema {
        var schema = object(
            properties: properties,
            required: required,
            description: description
        )
        if case .object(var object) = schema.json {
            object["additionalProperties"] = .bool(false)
            schema.json = .object(object)
        }
        return schema
    }
}

extension ToolSchema {
    /// Creates a schema from an official Foundation Models `GenerationSchema`.
    public init(generationSchema: GenerationSchema) {
        self.init(json: Self.jsonValue(for: generationSchema))
    }

    /// Creates a schema from a `Generable` type's official generation schema.
    public init<Value: Generable>(
        type: Value.Type,
        description: String? = nil
    ) {
        var json = Self.jsonValue(for: Value.generationSchema)
        if let description {
            json = Self.addingDescription(description, to: json)
        }
        self.init(json: json)
    }

    /// Shorthand for `ToolSchema(type:)`.
    public static func generable<Value: Generable>(
        _ type: Value.Type,
        description: String? = nil
    ) -> ToolSchema {
        ToolSchema(type: type, description: description)
    }

    /// Converts this JSON-schema subset into Foundation Models' official
    /// `GenerationSchema` representation.
    public func generationSchema(title: String = "Arguments") throws -> GenerationSchema {
        let normalized = Self.normalizedForFoundation(json, title: title)
        return try JSONDecoder().decode(GenerationSchema.self, from: normalized.data())
    }

    static func jsonValue(for schema: GenerationSchema) -> JSONValue {
        do {
            return try JSONValue(data: JSONEncoder().encode(schema))
        } catch {
            preconditionFailure("GenerationSchema failed to encode: \(error)")
        }
    }

    private static func addingDescription(_ description: String, to json: JSONValue) -> JSONValue {
        guard case .object(var object) = json else { return json }
        object["description"] = .string(description)
        return .object(object)
    }

    private static func normalizedForFoundation(_ json: JSONValue, title: String) -> JSONValue {
        switch json {
        case .object(var object):
            if case .string("object") = object["type"] {
                let properties = object["properties"]?.objectValue ?? [:]
                let orderedKeys = properties.keys.sorted()
                object["title"] = object["title"] ?? .string(title)
                object["properties"] = .object(Dictionary(
                    uniqueKeysWithValues: properties.map { key, value in
                        (key, normalizedForFoundation(value, title: key))
                    }
                ))
                object["required"] = object["required"] ?? .array([])
                object["x-order"] = object["x-order"]
                    ?? .array(orderedKeys.map(JSONValue.string))
                object["additionalProperties"] = object["additionalProperties"] ?? .bool(false)
            } else {
                if case .array(let values) = object["anyOf"] {
                    object["anyOf"] = .array(values.map {
                        normalizedForFoundation($0, title: title)
                    })
                }
                if let items = object["items"] {
                    object["items"] = normalizedForFoundation(items, title: "\(title)Item")
                }
            }
            return .object(object)
        case .array(let values):
            return .array(values.map { normalizedForFoundation($0, title: title) })
        case .null, .bool, .int, .number, .string:
            return json
        }
    }
}
