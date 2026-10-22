import Foundation

/// One control on the editor's surface panel.
///
/// Decoded from the daemon rather than written out here. The daemon that draws
/// an effect is the only thing that knows what the effect can be told, what
/// range it will actually honour, and what it does when nobody has said. A
/// second copy of that in Swift would be free to drift, and the first thing a
/// drifted copy does is offer a slider nothing reads.
struct KnobInfo: Decodable, Identifiable, Equatable {
    enum Control: String, Decodable {
        case range, choice, color, flag, pair, duration
    }

    let name: String
    let control: Control
    let min: Double
    let max: Double
    let step: Double
    /// Empty for everything but `choice`.
    let options: [String]
    /// What the knob is when nobody has set it.
    let preset: JSONValue
    /// The daemon's own one line, used when there is no translation.
    let says: String

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, control, min, max, step, options, preset, says
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        control = try values.decodeIfPresent(Control.self, forKey: .control) ?? .range
        min = try values.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try values.decodeIfPresent(Double.self, forKey: .max) ?? 1
        step = try values.decodeIfPresent(Double.self, forKey: .step) ?? 0.01
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
        preset = try values.decodeIfPresent(JSONValue.self, forKey: .preset) ?? .null
        says = try values.decodeIfPresent(String.self, forKey: .says) ?? ""
    }
}

extension KnobInfo {
    /// The name on the row, translated where we have it.
    var label: String { T("knob.\(name)", or: name.replacingOccurrences(of: "_", with: " ")) }

    /// The line under it, in the daemon's words until someone writes ours.
    var detail: String { T("knob.\(name).says", or: says) }

    /// Whether the default is "ask the effect" rather than a value of its own.
    /// `direction`, `mapping` and `fps` differ per effect, and the catalogue
    /// entry already carries each effect's answer.
    var followsEffect: Bool {
        if case .string("effect") = preset { return true }
        return false
    }

    var presetNumber: Double? {
        if case .number(let value) = preset { return value }
        return nil
    }

    var presetText: String? {
        if case .string(let value) = preset { return value }
        return nil
    }

    var presetFlag: Bool? {
        if case .bool(let value) = preset { return value }
        return nil
    }

    var presetPair: [Double]? {
        guard case .array(let items) = preset else { return nil }
        return items.compactMap { if case .number(let value) = $0 { return value } else { return nil } }
    }

    /// Whole numbers get no decimal point; everything else gets as few as its
    /// own step needs. A slider reading "1.0000001" is a slider you distrust.
    func reading(_ value: Double) -> String {
        if step >= 1 { return String(Int(value.rounded())) }
        return String(format: step >= 0.1 ? "%.1f" : "%.2f", value)
    }
}

/// One effect, as the daemon describes itself.
struct EffectInfo: Decodable, Identifiable, Equatable {
    let name: String
    let title: String
    let sentence: String
    let fps: Int
    let mapping: String
    let period: Double
    /// The axis this effect was designed around, which is what an unset
    /// `direction` means.
    let direction: String
    let knobs: [KnobInfo]

    var id: String { name }

    /// Translated where we have it, in the daemon's words otherwise.
    var shownTitle: String { T("effect.\(name)", or: title) }
    var shownSentence: String { T("effect.\(name).says", or: sentence) }

    /// What this effect answers for a knob whose default is "ask the effect".
    func own(_ knob: String) -> String? {
        switch knob {
        case "direction": return direction
        case "mapping": return mapping
        case "fps": return String(fps)
        default: return nil
        }
    }
}

/// The reply to `effects`.
struct Catalogue: Decodable {
    let effects: [EffectInfo]

    static let empty = Catalogue(effects: [])

    init(effects: [EffectInfo]) {
        self.effects = effects
    }

    func effect(_ name: String?) -> EffectInfo? {
        guard let name else { return nil }
        return effects.first { $0.name == name }
    }
}
