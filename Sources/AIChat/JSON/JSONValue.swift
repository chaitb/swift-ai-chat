import Foundation

/// An arbitrary JSON value.
///
/// Tool inputs and outputs, data parts, message metadata and provider metadata are
/// untyped on the wire. `JSONValue` carries them losslessly, and ``decode(_:using:)``
/// turns them into your own `Decodable` types.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let integer = Self.exactInteger(value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func exactInteger(_ value: Double) -> Int64? {
        guard value.isFinite, value.rounded(.towardZero) == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int64(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, let integer = Self.exactInteger(value) { return Int(exactly: integer) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The member at `key` when this is an object.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The element at `index` when this is an array.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Deep-merges `other` into this value the way the AI SDK merges message metadata:
    /// nested objects merge key by key, everything else is replaced.
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(let base) = self, case .object(let overrides) = other else { return other }
        var result = base
        for (key, value) in overrides {
            if let existing = result[key], case .object = existing, case .object = value {
                result[key] = existing.merging(value)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}

extension JSONValue {
    /// Encodes any `Encodable` value as a `JSONValue`.
    public init<T: Encodable>(encoding value: T, using encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONValue(parsing: data)
    }

    /// Parses JSON text. Top-level fragments such as strings and numbers are accepted.
    public init(parsing data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let value = JSONValue(foundationObject: object) else {
            throw ChatError(kind: .decoding, message: "The JSON contains a value that can't be represented.")
        }
        self = value
    }

    /// Parses JSON text from a string.
    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    init?(foundationObject object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: jsonData())
    }

    /// The compact JSON encoding of this value, with sorted keys.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The compact JSON text of this value, with sorted keys.
    public var jsonString: String {
        guard let data = try? jsonData() else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Indented JSON text, useful for showing tool inputs and outputs.
    public var prettyJSONString: String {
        guard let data = try? jsonData(prettyPrinted: true) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString }
}
