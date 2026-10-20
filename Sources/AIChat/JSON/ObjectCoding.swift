import Foundation

/// Reads typed fields out of a JSON object while remembering which keys were
/// consumed, so unknown keys can be carried along untouched.
struct ObjectReader {
    private(set) var remaining: [String: JSONValue]
    let context: String

    init(_ object: [String: JSONValue], context: String) {
        remaining = object
        self.context = context
    }

    mutating func take(_ key: String) -> JSONValue? {
        remaining.removeValue(forKey: key)
    }

    mutating func string(_ key: String) throws(ChatError) -> String {
        guard let value = take(key)?.stringValue else {
            throw ChatError(kind: .decoding, message: "\(context) is missing the string field \"\(key)\".")
        }
        return value
    }

    mutating func optionalString(_ key: String) -> String? {
        take(key)?.stringValue
    }

    mutating func optionalBool(_ key: String) -> Bool? {
        take(key)?.boolValue
    }

    mutating func optionalInt(_ key: String) -> Int? {
        take(key)?.intValue
    }

    /// The value at `key`, where `null` and a missing key both read as `nil`.
    mutating func optionalValue(_ key: String) -> JSONValue? {
        guard let value = take(key), !value.isNull else { return nil }
        return value
    }

    /// The value at `key`, keeping an explicit `null`. A missing key reads as `nil`.
    mutating func presentValue(_ key: String) -> JSONValue? {
        take(key)
    }

    mutating func optionalObject(_ key: String) -> [String: JSONValue]? {
        take(key)?.objectValue
    }

    mutating func requiredValue(_ key: String) throws(ChatError) -> JSONValue {
        guard let value = take(key) else {
            throw ChatError(kind: .decoding, message: "\(context) is missing the field \"\(key)\".")
        }
        return value
    }
}

/// Builds a JSON object, skipping absent optional fields.
struct ObjectWriter {
    private(set) var object: [String: JSONValue]

    init(extra: [String: JSONValue] = [:]) {
        object = extra
    }

    mutating func set(_ key: String, _ value: String?) {
        if let value { object[key] = .string(value) }
    }

    mutating func set(_ key: String, _ value: Bool?) {
        if let value { object[key] = .bool(value) }
    }

    mutating func set(_ key: String, _ value: Int?) {
        if let value { object[key] = .number(Double(value)) }
    }

    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { object[key] = value }
    }

    mutating func set(_ key: String, _ value: [String: JSONValue]?) {
        if let value { object[key] = .object(value) }
    }
}

/// A value that maps to and from a JSON object, keeping unknown keys so newer
/// protocol fields survive a round trip through an older client.
public protocol JSONObjectConvertible: Codable, Sendable {
    init(jsonObject: [String: JSONValue]) throws(ChatError)
    var jsonObject: [String: JSONValue] { get }
}

extension JSONObjectConvertible {
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a JSON object."))
        }
        do {
            try self.init(jsonObject: object)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message, underlyingError: error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONValue.object(jsonObject).encode(to: encoder)
    }

    /// Parses this value from JSON data.
    public init(jsonData: Data) throws(ChatError) {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: jsonData)
        } catch {
            throw ChatError.from(error)
        }
        guard let object = value.objectValue else {
            throw ChatError(kind: .decoding, message: "Expected a JSON object.")
        }
        try self.init(jsonObject: object)
    }

    /// The JSON encoding of this value, with sorted keys.
    public func jsonData() throws -> Data {
        try JSONValue.object(jsonObject).jsonData()
    }

    public var jsonValue: JSONValue { .object(jsonObject) }
}
