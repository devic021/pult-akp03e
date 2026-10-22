import Foundation

/// A JSON value of any shape.
///
/// Every type the app exchanges with the daemon keeps one of these per unknown
/// key. Without it the app is a lossy filter: its `CodingKeys` list what this
/// version knows, the synthesised encoder writes only those, and the first save
/// from the editor would quietly delete anything a newer daemon had written —
/// a feed, a surface, a binding. Reading and writing back what we do not
/// understand costs a few lines and removes a whole class of data loss.
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? value.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "unrecognised JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A coding key built at run time, for reading keys we have no case for.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Everything in this container except the keys the type already handles.
    func unknown(except known: Set<String>) -> [String: JSONValue] {
        var extra: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                extra[key.stringValue] = value
            }
        }
        return extra
    }
}

extension Encoder {
    /// Writes back the keys this version did not understand.
    func encodeExtra(_ extra: [String: JSONValue]) throws {
        guard !extra.isEmpty else { return }
        var container = self.container(keyedBy: AnyKey.self)
        for (name, value) in extra {
            try container.encode(value, forKey: AnyKey(name))
        }
    }
}
