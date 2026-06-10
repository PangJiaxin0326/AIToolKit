import Foundation
import FoundationModels

public struct GeneratedContentAccessError: Error, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension GenerationSchema {
    public func jsonString(encoder: JSONEncoder = JSONEncoder()) throws -> String {
        String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension GeneratedContent {
    public init(data: Data) throws {
        try self.init(json: String(decoding: data, as: UTF8.self))
    }

    public func data() -> Data {
        Data(jsonString.utf8)
    }

    public static func object(_ properties: [String: GeneratedContent]) -> GeneratedContent {
        GeneratedContent(
            kind: .structure(
                properties: properties,
                orderedKeys: properties.keys.sorted()
            )
        )
    }

    public static func array(_ values: [GeneratedContent]) -> GeneratedContent {
        GeneratedContent(kind: .array(values))
    }

    public static func bool(_ value: Bool) -> GeneratedContent {
        GeneratedContent(kind: .bool(value))
    }

    public static func int(_ value: Int) -> GeneratedContent {
        GeneratedContent(value)
    }

    public static func number(_ value: Double) -> GeneratedContent {
        GeneratedContent(kind: .number(value))
    }

    public static func string(_ value: String) -> GeneratedContent {
        GeneratedContent(value)
    }

    public static var nullContent: GeneratedContent {
        GeneratedContent(kind: .null)
    }

    public var objectValue: [String: GeneratedContent]? {
        if case .structure(let properties, _) = kind { return properties }
        return nil
    }

    public var arrayValue: [GeneratedContent]? {
        if case .array(let values) = kind { return values }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = kind { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = kind { return value }
        return nil
    }

    public var intValue: Int? {
        try? value(Int.self)
    }

    public var allStrings: [String] {
        switch kind {
        case .string(let value):
            return [value]
        case .array(let values):
            return values.flatMap(\.allStrings)
        case .structure(let properties, _):
            return properties.values.flatMap(\.allStrings)
        case .null, .bool, .number:
            return []
        @unknown default:
            return []
        }
    }

    public func property(_ name: String) -> GeneratedContent? {
        objectValue?[name]
    }

    public func requiredString(_ name: String) throws -> String {
        guard let value = try self.value(String?.self, forProperty: name) else {
            throw GeneratedContentAccessError("Missing string property \(name)")
        }
        return value
    }

    public func optionalString(_ name: String) -> String? {
        try? value(String?.self, forProperty: name)
    }

    public func optionalInt(_ name: String) -> Int? {
        try? value(Int?.self, forProperty: name)
    }

    public func optionalBool(_ name: String) -> Bool? {
        try? value(Bool?.self, forProperty: name)
    }

    public func contentArray(_ name: String) throws -> [GeneratedContent]? {
        guard let property = property(name) else { return nil }
        guard case .array(let values) = property.kind else {
            throw GeneratedContentAccessError("Expected array property \(name)")
        }
        return values
    }

    public func contentObject(_ name: String) throws -> [String: GeneratedContent]? {
        guard let property = property(name) else { return nil }
        guard case .structure(let properties, _) = property.kind else {
            throw GeneratedContentAccessError("Expected object property \(name)")
        }
        return properties
    }
}
