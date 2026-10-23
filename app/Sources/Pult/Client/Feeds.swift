import Foundation

/// What one feed has last said, as the daemon reports it.
///
/// Read from the daemon rather than worked out here. The daemon holds the
/// samples and does the polling; a second copy of "is this stale" in Swift
/// would be free to disagree with the dock, and the dock is the thing people
/// are looking at.
struct FeedStatus: Decodable, Identifiable, Equatable {
    let name: String
    /// `http` or `shell`.
    let kind: String
    /// The URL it fetches, or the command it runs.
    let source: String?
    let every: String
    let staleAfter: String?
    /// Seconds since it last answered. Absent means it never has.
    let age: Int?
    /// Whether that answer is past its own `stale_after`.
    let stale: Bool
    /// Why the last attempt failed, if it did. The last sample is kept either
    /// way, so this can be set while the fields below still hold numbers.
    let error: String?
    /// The values it last brought back, as text.
    let fields: [String: String]
    /// Each run of values it carries, and how long that run is.
    let series: [String: Int]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, kind, source, every, age, stale, error, fields, series
        case staleAfter = "stale_after"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "http"
        source = try values.decodeIfPresent(String.self, forKey: .source)
        every = try values.decodeIfPresent(String.self, forKey: .every) ?? ""
        staleAfter = try values.decodeIfPresent(String.self, forKey: .staleAfter)
        age = try values.decodeIfPresent(Int.self, forKey: .age)
        stale = try values.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        error = try values.decodeIfPresent(String.self, forKey: .error)
        fields = try values.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
        series = try values.decodeIfPresent([String: Int].self, forKey: .series) ?? [:]
    }

    /// Whether this feed has ever answered.
    var answered: Bool { age != nil }

    /// Where a feed stands, which is the one thing the row has to get right.
    enum Health {
        /// Answering, and believed.
        case fresh
        /// Answered once, and that answer is now too old to trust.
        case stale
        /// Has never answered.
        case silent
        /// The last attempt failed, though an older answer may still be shown.
        case failing
    }

    var health: Health {
        if !answered { return .silent }
        if error != nil { return .failing }
        return stale ? .stale : .fresh
    }

    /// The field names, in a stable order so the row does not shuffle.
    var fieldNames: [String] { fields.keys.sorted() }
}

/// Every feed, and where the readings are being asked for.
struct FeedReport: Decodable, Equatable {
    var feeds: [FeedStatus] = []
    /// What fills `{lat}` and `{lon}`. Empty means nobody has said where the
    /// dock is, which is a different problem from a host being down and has
    /// to read as one.
    var places: [String: String] = [:]
    /// Hours ahead of now the dock is currently reading; zero is the present.
    var hour: Int = 0

    static let empty = FeedReport()

    enum CodingKeys: String, CodingKey { case feeds, places, hour }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try values.decodeIfPresent([FeedStatus].self, forKey: .feeds) ?? []
        places = try values.decodeIfPresent([String: String].self, forKey: .places) ?? [:]
        hour = try values.decodeIfPresent(Int.self, forKey: .hour) ?? 0
    }

    /// Whether the dock knows where it is.
    var located: Bool { places["lat"] != nil && places["lon"] != nil }
}
