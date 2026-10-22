import Foundation

/// What a scene paints with: six separate keys, or one drawing across the
/// whole dock.
///
/// Three properties are typed, because the app's structure turns on them —
/// keys or canvas, an effect or a file of your own. Every other setting lives
/// in `values`, by the name the daemon calls it.
///
/// That is deliberate, and it is the same decision as `Effect::knobs()` on the
/// daemon side. Thirty-five typed properties here would be a second copy of
/// that list, in another language, free to drift — and the first thing a
/// drifted copy does is show a slider the daemon stopped reading. Here the
/// daemon that draws the effect is also the only thing that says what the
/// effect can be told, and a knob it has never heard of survives a round trip
/// untouched rather than being deleted on the next save.
struct Surface: Codable, Equatable {
    /// `keys` or `canvas`.
    var kind: String = "keys"
    /// Which built-in motion. Ignored when `source` names a file.
    var effect: String?
    /// A file of your own, which wins over `effect`.
    var source: String?
    /// Every knob, by name.
    var values: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey { case kind, effect, source }

    private static let known: Set<String> = ["kind", "effect", "source"]

    init(kind: String = "keys", effect: String? = nil, source: String? = nil) {
        self.kind = kind
        self.effect = effect
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        kind = try fields.decodeIfPresent(String.self, forKey: .kind) ?? "keys"
        effect = try fields.decodeIfPresent(String.self, forKey: .effect)
        source = try fields.decodeIfPresent(String.self, forKey: .source)
        values = (try? decoder.container(keyedBy: AnyKey.self))?.unknown(except: Surface.known) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(kind, forKey: .kind)
        try fields.encodeIfPresent(effect, forKey: .effect)
        try fields.encodeIfPresent(source, forKey: .source)
        try encoder.encodeExtra(values)
    }
}

// MARK: - Reading and writing one knob

extension Surface {
    var isCanvas: Bool { kind == "canvas" }

    /// Whether this surface paints a file rather than a built-in motion. A
    /// source wins over an effect, because it is the more specific thing to
    /// have asked for.
    var paintsAFile: Bool { source?.isEmpty == false }

    func number(_ name: String) -> Double? {
        if case .number(let value) = values[name] { return value }
        return nil
    }

    func text(_ name: String) -> String? {
        if case .string(let value) = values[name] { return value }
        return nil
    }

    func flag(_ name: String) -> Bool? {
        if case .bool(let value) = values[name] { return value }
        return nil
    }

    /// A two-number knob: `origin` and `lobes`.
    func pair(_ name: String) -> [Double]? {
        guard case .array(let items) = values[name] else { return nil }
        let numbers = items.compactMap { item -> Double? in
            if case .number(let value) = item { return value }
            return nil
        }
        return numbers.count == items.count ? numbers : nil
    }

    /// Sets a knob, or clears it when `value` is nil.
    ///
    /// Clearing matters as much as setting: an absent knob means the effect's
    /// own choice, and the daemon writes back only what was actually set. That
    /// is what keeps a hand-written config readable instead of turning it into
    /// thirty-five lines of defaults the first time the editor touches it.
    mutating func set(_ name: String, _ value: JSONValue?) {
        if let value {
            values[name] = value
        } else {
            values.removeValue(forKey: name)
        }
    }

    mutating func set(_ name: String, number: Double?) {
        set(name, number.map { JSONValue.number($0) })
    }

    mutating func set(_ name: String, text: String?) {
        set(name, text.map { JSONValue.string($0) })
    }

    mutating func set(_ name: String, flag: Bool?) {
        set(name, flag.map { JSONValue.bool($0) })
    }

    mutating func set(_ name: String, pair: [Double]?) {
        set(name, pair.map { JSONValue.array($0.map { JSONValue.number($0) }) })
    }

    /// The JSON the daemon expects for `preview_canvas` and `try_canvas`.
    var payload: [String: Any] {
        var object: [String: Any] = ["kind": kind]
        if let effect { object["effect"] = effect }
        if let source { object["source"] = source }
        for (name, value) in values {
            object[name] = value.plain
        }
        return object
    }
}

extension JSONValue {
    /// The Foundation value behind this, for `JSONSerialization`.
    var plain: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map(\.plain)
        case .object(let fields): return fields.mapValues(\.plain)
        }
    }
}
