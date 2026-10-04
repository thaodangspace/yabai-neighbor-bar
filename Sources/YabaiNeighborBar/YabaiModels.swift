import Foundation

/// Typed, validated view of the three yabai CLI queries used by the neighbor bar.
///
/// Only the fields required by the feature are modeled. Unknown fields emitted by
/// yabai (frame, uuid, app, title, …) are ignored by `Decodable`. Decoding is the
/// schema boundary: a missing or mistyped required field fails the whole snapshot
/// instead of silently producing a wrong UI.
///
/// Schema notes (verified against yabai v7.1.25, 2026-10-03):
/// - A Space has both an `id` (stable unique id) and an `index` (per-display
///   ordered position). `Display.spaces` and `Window.space` reference the
///   Space `index`, while `Space.display` references the Display `id`.
/// - Space `index` values are unique across the machine; the focused display's
///   spaces are still sorted explicitly by `index` for determinism.

struct YabaiDisplay: Equatable, Decodable, Sendable {
    let id: Int
    let index: Int
    let hasFocus: Bool

    enum CodingKeys: String, CodingKey {
        case id, index
        case hasFocus = "has-focus"
    }
}

struct YabaiSpace: Equatable, Decodable, Sendable {
    let id: Int
    let index: Int
    let display: Int
    let hasFocus: Bool
    let windows: [Int]

    enum CodingKeys: String, CodingKey {
        case id, index, display, windows
        case hasFocus = "has-focus"
    }
}

struct YabaiWindow: Equatable, Decodable, Sendable {
    let id: Int
    let pid: Int
    let space: Int

    enum CodingKeys: String, CodingKey {
        case id, pid, space
    }
}

struct YabaiSnapshot: Equatable, Sendable {
    let displays: [YabaiDisplay]
    let spaces: [YabaiSpace]
    let windows: [YabaiWindow]
}

/// Stable, typed decoding failure. Keeps the offending field name so callers can
/// log/attribute a bad snapshot without exposing any window titles.
enum YabaiDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedJSON
    case missingField(String)
    case typeMismatch(String)

    var description: String {
        switch self {
        case .malformedJSON:
            return "yabai returned malformed JSON"
        case let .missingField(field):
            return "yabai JSON is missing required field '\(field)'"
        case let .typeMismatch(field):
            return "yabai JSON field '\(field)' has an unexpected type"
        }
    }

    init(_ error: DecodingError) {
        switch error {
        case let .keyNotFound(key, _):
            self = .missingField(key.stringValue)
        case let .valueNotFound(_, context):
            self = .missingField(Self.path(context.codingPath))
        case let .typeMismatch(_, context):
            self = .typeMismatch(Self.path(context.codingPath))
        case .dataCorrupted:
            self = .malformedJSON
        @unknown default:
            self = .malformedJSON
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let joined = codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "root" : joined
    }
}

enum YabaiJSONDecoder {
    /// Decodes a yabai payload, translating `DecodingError` into
    /// `YabaiDecodingError` so callers never have to introspect Foundation errors.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw YabaiDecodingError(error)
        }
    }
}
