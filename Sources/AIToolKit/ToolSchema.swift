import Foundation

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
