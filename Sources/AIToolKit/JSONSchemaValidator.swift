import Foundation

public struct JSONSchemaValidationError: Error, Sendable, Hashable, CustomStringConvertible {
    public var location: String
    public var message: String

    public init(location: String, message: String) {
        self.location = location
        self.message = message
    }

    public var description: String {
        "\(location): \(message)"
    }
}

public enum JSONSchemaValidator {
    public static func validate(
        _ value: JSONValue,
        schema: JSONValue,
        location: String = "$"
    ) throws {
        guard case .object(let object) = schema else { return }

        if case .array(let variants)? = object["anyOf"] {
            for variant in variants {
                if (try? validate(value, schema: variant, location: location)) != nil {
                    return
                }
            }
            throw JSONSchemaValidationError(
                location: location,
                message: "value did not match any allowed schema"
            )
        }

        if let constant = object["const"], value != constant {
            throw JSONSchemaValidationError(
                location: location,
                message: "expected constant \(constant)"
            )
        }

        if case .array(let allowed)? = object["enum"],
           !allowed.contains(value) {
            throw JSONSchemaValidationError(
                location: location,
                message: "value is not in enum"
            )
        }

        if let rawType = object["type"] {
            let types: [String]
            switch rawType {
            case .string(let type):
                types = [type]
            case .array(let values):
                types = values.compactMap(\.stringValue)
            default:
                types = []
            }
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                throw JSONSchemaValidationError(
                    location: location,
                    message: "expected type \(types.joined(separator: "|"))"
                )
            }
        }

        if case .object(let valueObject) = value {
            try validateObject(valueObject, schema: object, location: location)
        }
        if case .array(let values) = value {
            try validateArray(values, schema: object, location: location)
        }
    }

    public static func referencePathExists(
        _ pointer: String,
        in schema: JSONValue
    ) -> Bool? {
        // Accept the LLM-flavored "/" as root, matching `resolvePointer`.
        if pointer.isEmpty || pointer == "/" { return true }
        guard pointer.hasPrefix("/") else { return false }
        var current = schema
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case .object(let object) = current else { return nil }
            let unwrapped = nonNullSchema(object)
            guard case .object(let concrete) = unwrapped else { return nil }
            if isArraySchema(concrete), let items = concrete["items"] {
                guard let index = Int(token), index >= 0 else { return false }
                current = items
                continue
            }
            guard isObjectSchema(concrete) else { return nil }
            guard case .object(let properties)? = concrete["properties"] else { return nil }
            if let next = properties[String(token)] {
                current = next
            } else if case .bool(false)? = concrete["additionalProperties"] {
                return false
            } else {
                return nil
            }
        }
        return true
    }

    public static func isUnknownObject(_ schema: JSONValue?) -> Bool {
        guard case .object(let object)? = schema,
              case .string("object")? = object["type"],
              case .object(let properties)? = object["properties"],
              properties.isEmpty,
              object["additionalProperties"] == nil
        else { return false }
        return true
    }

    private static func validateObject(
        _ value: [String: JSONValue],
        schema object: [String: JSONValue],
        location: String
    ) throws {
        if case .array(let required)? = object["required"] {
            for key in required.compactMap(\.stringValue) where value[key] == nil {
                throw JSONSchemaValidationError(
                    location: location,
                    message: "missing required property \(key)"
                )
            }
        }

        let properties: [String: JSONValue]
        if case .object(let raw)? = object["properties"] {
            properties = raw
        } else {
            properties = [:]
        }

        for (key, schema) in properties {
            if let child = value[key] {
                try validate(child, schema: schema, location: "\(location).\(key)")
            }
        }

        if case .bool(false)? = object["additionalProperties"] {
            let extras = Set(value.keys).subtracting(properties.keys)
            if let extra = extras.sorted().first {
                throw JSONSchemaValidationError(
                    location: location,
                    message: "unexpected property \(extra)"
                )
            }
        } else if let additional = object["additionalProperties"],
                  case .bool = additional {
            return
        } else if let additional = object["additionalProperties"] {
            for (key, child) in value where properties[key] == nil {
                try validate(child, schema: additional, location: "\(location).\(key)")
            }
        }
    }

    private static func validateArray(
        _ values: [JSONValue],
        schema object: [String: JSONValue],
        location: String
    ) throws {
        if let minItems = object["minItems"]?.intValue, values.count < minItems {
            throw JSONSchemaValidationError(
                location: location,
                message: "expected at least \(minItems) items"
            )
        }
        if let maxItems = object["maxItems"]?.intValue, values.count > maxItems {
            throw JSONSchemaValidationError(
                location: location,
                message: "expected at most \(maxItems) items"
            )
        }
        guard let itemSchema = object["items"] else { return }
        for (index, child) in values.enumerated() {
            try validate(child, schema: itemSchema, location: "\(location)[\(index)]")
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.null, "null"),
             (.bool, "boolean"),
             (.string, "string"),
             (.array, "array"),
             (.object, "object"):
            return true
        case (.int, "integer"):
            return true
        case (.number(let number), "integer"):
            return number.isFinite && number.rounded() == number
        case (.int, "number"):
            return true
        case (.number(let number), "number"):
            return number.isFinite
        default:
            return false
        }
    }

    private static func nonNullSchema(_ object: [String: JSONValue]) -> JSONValue {
        if case .array(let variants)? = object["anyOf"] {
            return variants.first { variant in
                guard case .object(let child) = variant else { return true }
                return child["type"] != .string("null")
            } ?? .object(object)
        }
        return .object(object)
    }

    private static func isObjectSchema(_ object: [String: JSONValue]) -> Bool {
        switch object["type"] {
        case .string("object")?:
            return true
        case .array(let values)?:
            return values.contains(.string("object"))
        default:
            return false
        }
    }

    private static func isArraySchema(_ object: [String: JSONValue]) -> Bool {
        switch object["type"] {
        case .string("array")?:
            return true
        case .array(let values)?:
            return values.contains(.string("array"))
        default:
            return false
        }
    }
}
