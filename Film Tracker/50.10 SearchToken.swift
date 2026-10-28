// MARK: - SearchToken.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Token data type for SwiftUI's native searchable token support.
// Tokens must conform to Identifiable for SwiftUI to render them.

import Foundation

// MARK: - Search Token
/// Represents a single search token that can be selected in the search field.
/// SwiftUI requires tokens to conform to Identifiable.
///
/// `Hashable`/`Equatable` are synthesized. The hand-written `==` and `hash(into:)`
/// that used to live here combined exactly the four stored properties the compiler
/// does, so they were pure duplication; `id` is computed and never participates.
struct SearchToken: Identifiable, Hashable {
    var id: String { "\(field.rawValue):\(value):\(isInverted):\(isOr)" }
    
    let field: SearchField
    let value: String
    let isInverted: Bool
    let isOr: Bool
    
    /// Display name shown in the token pill
    var displayName: String {
        var prefix = ""
        if isOr {
            prefix = "/"
        }
        if isInverted {
            prefix += "!"
        }
        
        if value.isEmpty {
            return "\(prefix)\(field.tokenPillLabel)"
        }
        return "\(prefix)\(field.tokenPillLabel): \(displayValue)"
    }
    
    /// The value string as it should appear in the token pill.
    /// For `.rotationThreshold`, any recognized trailing unit term is normalized
    /// to its compact abbreviation ("yr." or "mo.") to prevent macOS from
    /// truncating an otherwise-valid but overly long token label.
    /// Recognized year forms:  year, years, yr, yr.
    /// Recognized month forms: month, months, mo, mo.
    /// All other fields return the raw value unchanged.
    private var displayValue: String {
        // A list name can run long; the pill keeps its first 20 characters, as the
        // abbreviated field labels keep the pill itself compact.
        if field == .list {
            guard value.count > 20 else { return value }
            return value.prefix(20).trimmingCharacters(in: .whitespaces) + "…"
        }
        guard field == .rotationThreshold else { return value }
        // A single substitution pass per unit family is sufficient because the
        // patterns are mutually exclusive (no overlap between year and month terms).
        //
        // Each pattern matches a unit word at a left word boundary, consumes any trailing
        // period as PART of the match, and uses a negative look-ahead for a following
        // letter as the right-hand boundary. Consuming the period inside the match avoids
        // the double-period artifact a trailing \b produced for the already-abbreviated
        // forms (e.g. "3 yr." → "3 yr.."), since \b cannot match between a period and the
        // end of the string and the engine would otherwise match only "yr" and re-append
        // a period. The look-ahead still prevents the match from firing inside a longer
        // word such as "yearly".
        let abbreviated = value
            .replacingOccurrences(of: #"(?i)\b(?:years?|yr)\.?(?![a-z])"#,  with: "yr.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:months?|mo)\.?(?![a-z])"#, with: "mo.", options: .regularExpression)
        return abbreviated
    }
    
    init(field: SearchField, value: String = "", isInverted: Bool = false, isOr: Bool = false) {
        self.field = field
        self.value = value
        self.isInverted = isInverted
        self.isOr = isOr
    }
}

// MARK: - Search Field
/// Defines the searchable fields available as tokens.
enum SearchField: String, CaseIterable, Hashable {
    case title = "title"
    case crew = "crew"
    case cast = "cast"
    case directors = "directors"
    case producer = "producer"
    case executiveProducer = "executiveProducer"
    case screenwriter = "screenwriter"
    case composer = "composer"
    case genre = "genre"
    case studio = "studio"
    case tags = "tags"
    case notes = "notes"
    case synopsis = "synopsis"
    case year = "year"
    case duration = "duration"
    case rating = "rating"
    case lastWatched = "lastWatched"
    case dateAdded = "dateAdded"
    case list = "list"
    case releases = "releases"
    case rotationThreshold = "rotationThreshold"
    case flags = "flags"
    
    /// Human-readable display name
    var displayName: String {
        switch self {
        case .title: return "Title"
        case .crew: return "Crew"
        case .cast: return "Cast"
        case .directors: return "Director"
        case .producer: return "Producer"
        case .executiveProducer: return "Executive Producer"
        case .screenwriter: return "Screenwriter"
        case .composer: return "Composer"
        case .genre: return "Genre"
        case .studio: return "Studio"
        case .tags: return "Tags"
        case .notes: return "Notes"
        case .synopsis: return "Synopsis"
        case .year: return "Year"
        case .duration: return "Duration"
        case .rating: return "Rating"
        case .lastWatched: return "Last Watched"
        case .dateAdded: return "Date Added"
        case .list: return "List"
        case .releases: return "Release"
        case .rotationThreshold: return "Rotation Threshold"
        case .flags: return "Is"
        }
    }
    
    /// Abbreviated label shown in confirmed token pills.
    /// Fields without a specified abbreviation fall back to `displayName`.
    var tokenPillLabel: String {
        switch self {
        case .directors: return "Dir"
        case .producer: return "Pro"
        case .executiveProducer: return "ExPro"
        case .screenwriter: return "ScWtr"
        case .composer: return "Comp"
        case .duration: return "Dur"
        case .lastWatched: return "LstWch"
        case .rotationThreshold: return "RoThr"
        default: return displayName
        }
    }
    
    /// Aliases that can be used to reference this field
    var aliases: [String] {
        switch self {
        case .title: return ["title", "name"]
        case .crew: return ["crew", "crewman", "crewmen", "people", "person"]
        case .cast: return ["cast", "actor", "actors", "actress"]
        case .directors: return ["director", "directors", "dir"]
        case .producer: return ["producer", "producers", "prod"]
        case .executiveProducer: return ["executiveproducer", "executiveproducers", "execproducer", "exprod", "exp"]
        case .screenwriter: return ["screenwriter", "screenwriters", "scrwr", "writer", "writers"]
        case .composer: return ["composer", "composers", "comp", "music"]
        case .genre: return ["genre", "genres"]
        case .studio: return ["studio", "company", "group"]
        case .tags: return ["tag", "tags"]
        case .notes: return ["note", "notes"]
        case .synopsis: return ["synopsis", "plot", "description"]
        case .year: return ["year", "years", "releaseyear", "date"]
        case .duration: return ["duration", "runtime", "length", "time"]
        case .rating: return ["rating", "userrating", "rate", "score"]
        case .lastWatched: return ["lastwatched", "lastviewed", "watched", "viewed", "lv"]
        case .dateAdded: return ["dateadded", "added", "imported"]
        case .list: return ["list", "lists"]
        case .releases: return ["release", "releases", "rel"]
        case .rotationThreshold: return ["rotationthreshold", "rotation", "threshold", "roth"]
        case .flags: return ["is", "flag", "flags"]
        }
    }
    
    /// Find field from alias string.
    /// O(1) dictionary lookup via the statically-built alias map — avoids the previous
    /// O(cases × aliases) linear scan that ran on every token parse.
    static func from(alias: String) -> SearchField? {
        let normalized = alias.lowercased().trimmingCharacters(in: .whitespaces)
        return aliasLookup[normalized]
    }
    
    /// The field whose two-word display name ("Date Added", "Last Watched") the two words
    /// spell when run together, compared case-insensitively.
    static func from(twoWordName name: String) -> SearchField? {
        twoWordNameLookup[name.lowercased()]
    }
    
    private static let twoWordNameLookup: [String: SearchField] = {
        var map: [String: SearchField] = [:]
        for field in Self.allCases where field.displayName.split(separator: " ").count == 2 {
            map[field.displayName.replacingOccurrences(of: " ", with: "").lowercased()] = field
        }
        return map
    }()
    
    /// Flat dictionary mapping every alias string to its owning SearchField.
    /// Built once at app launch; never mutated.
    private static let aliasLookup: [String: SearchField] = {
        var map: [String: SearchField] = [:]
        for field in Self.allCases {
            for alias in field.aliases {
                map[alias] = field
            }
        }
        return map
    }()
}

// MARK: - Film Flags

/// The yes/no properties of a film that the Is token (`#is`) tests.
///
/// An Is value is a comma-separated list of terms, every one of which must hold:
/// `#is owned 4k, unsorted, !edited`. A term is negated by a leading "!" or "not ".
/// Each term names one flag, either way round: "unsorted" is `sorted` negated, so the
/// matcher in SearchController has one test per flag and the opposites cost nothing.
///
/// These are tests on the film itself, not on smart-list membership, so none carries a
/// smart list's side conditions: "unsorted" is only "no special sorting", where the
/// Filtered Library list also requires the film to be watched.
nonisolated enum FilmFlag: CaseIterable {
    case edited, watched, rated, complete
    case sorted, waitingForEdit, onHold, temporarilyOnHold, indefinitelyOnHold, ignored, blacklisted
    case owned, owned4K, ownedBluray, ownedDVD, unowned, noReleases, wishlisted, upcoming
    case alternateVersions, hallOfFame

    /// One spelling a user can type, and the flag it names.
    struct Term {
        /// The form suggestions show and the guide documents.
        let display: String
        /// Further accepted spellings.
        let aliases: [String]
        let flag: FilmFlag
        /// True when the term asks for the flag to be absent ("unedited").
        let negated: Bool
    }

    static let terms: [Term] = [
        Term(display: "edited", aliases: [], flag: .edited, negated: false),
        Term(display: "unedited", aliases: ["not edited"], flag: .edited, negated: true),
        Term(display: "watched", aliases: ["seen", "viewed"], flag: .watched, negated: false),
        Term(display: "unwatched", aliases: ["unseen", "unviewed", "never watched"], flag: .watched, negated: true),
        Term(display: "rated", aliases: [], flag: .rated, negated: false),
        Term(display: "unrated", aliases: [], flag: .rated, negated: true),
        Term(display: "complete", aliases: ["info complete"], flag: .complete, negated: false),
        Term(display: "incomplete", aliases: ["info incomplete"], flag: .complete, negated: true),
        Term(display: "sorted", aliases: ["special sorting", "specially sorted"], flag: .sorted, negated: false),
        Term(display: "unsorted", aliases: ["no special sorting"], flag: .sorted, negated: true),
        Term(display: "waiting for edit", aliases: ["waiting"], flag: .waitingForEdit, negated: false),
        Term(display: "on hold", aliases: ["held"], flag: .onHold, negated: false),
        Term(display: "temporarily on hold", aliases: ["temp on hold"], flag: .temporarilyOnHold, negated: false),
        Term(display: "indefinitely on hold", aliases: [], flag: .indefinitelyOnHold, negated: false),
        Term(display: "ignored", aliases: ["ignore"], flag: .ignored, negated: false),
        Term(display: "blacklisted", aliases: [], flag: .blacklisted, negated: false),
        Term(display: "owned", aliases: ["purchased"], flag: .owned, negated: false),
        Term(display: "owned 4k", aliases: ["owned uhd", "purchased 4k"], flag: .owned4K, negated: false),
        Term(display: "owned blu-ray", aliases: ["owned 2k", "purchased blu-ray"], flag: .ownedBluray, negated: false),
        Term(display: "owned dvd", aliases: ["purchased dvd"], flag: .ownedDVD, negated: false),
        Term(display: "unowned", aliases: ["unpurchased"], flag: .unowned, negated: false),
        Term(display: "no releases", aliases: ["no releases added"], flag: .noReleases, negated: false),
        Term(display: "wishlisted", aliases: ["on wishlist", "wishlist"], flag: .wishlisted, negated: false),
        Term(display: "upcoming", aliases: [], flag: .upcoming, negated: false),
        Term(display: "alternate versions", aliases: ["alt versions", "alternates"], flag: .alternateVersions, negated: false),
        Term(display: "hall of fame", aliases: ["hof"], flag: .hallOfFame, negated: false),
    ]

    /// Every spelling, in `SearchText.key` form, to its flag and polarity.
    private static let lookup: [String: (flag: FilmFlag, negated: Bool)] = {
        var map: [String: (flag: FilmFlag, negated: Bool)] = [:]
        for term in terms {
            for spelling in [term.display] + term.aliases {
                map[SearchText.key(spelling)] = (term.flag, term.negated)
            }
        }
        return map
    }()

    /// The tests an Is value asks for, or nil when any term in it is not recognized —
    /// a misspelled term matches nothing rather than being silently dropped, which would
    /// widen the search without saying so. Empty terms (a trailing comma) are skipped.
    static func parse(_ value: String) -> [(flag: FilmFlag, negated: Bool)]? {
        var tests: [(flag: FilmFlag, negated: Bool)] = []
        for segment in value.split(separator: ",") {
            var text = segment.trimmingCharacters(in: .whitespaces)
            var negated = false
            while text.hasPrefix("!") {
                negated.toggle()
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            var key = SearchText.key(text)
            guard !key.isEmpty else { continue }
            if key.hasPrefix("not "), lookup[key] == nil {
                negated.toggle()
                key = String(key.dropFirst(4))
            }
            guard let hit = lookup[key] else { return nil }
            tests.append((hit.flag, hit.negated != negated))
        }
        return tests.isEmpty ? nil : tests
    }

    /// An Is value being typed, split at its last comma: the finished terms before it
    /// (with the comma and one space, or "" when there are none), the "!" typed ahead of
    /// the term in progress, and that term. Suggestions complete only the last term.
    static func splitLast(_ value: String) -> (head: String, negation: String, term: String) {
        var head = ""
        var rest = Substring(value)
        if let comma = value.lastIndex(of: ",") {
            head = value[..<comma].trimmingCharacters(in: .whitespaces) + ", "
            rest = value[value.index(after: comma)...]
        }
        var term = rest.trimmingCharacters(in: .whitespaces)
        var negation = ""
        while term.hasPrefix("!") {
            negation += "!"
            term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return (head, negation, term)
    }
}

// MARK: - Search Text Normalization

/// The one form search compares text in, on both sides of every match.
///
/// Folds case, diacritics and full-width forms, drops punctuation and symbols, and
/// collapses every run of whitespace to a single space. Each piece answers a way a typed
/// query used to miss a title it plainly named:
///   • "amelie" now finds "Amélie".
///   • A hyphen finds an en dash, and "mission impossible" finds
///     "Mission: Impossible – Fallout". The library's own titles use typographic dashes
///     and colons that the keyboard does not, and a plain substring test held them to the
///     exact character.
///   • "schindlers list" and "schindler's list" find "Schindler’s List" whichever
///     apostrophe either side was written with.
///
/// Punctuation is dropped rather than turned into a space, so "u.s.a." finds "U.S.A."
/// and "spiderman" finds "Spider-Man". A separator surrounded by spaces (" – ") still
/// leaves exactly one space, through the whitespace collapse.
///
/// `nonisolated` because FilmMetadata builds its stored keys with it off the main actor.
nonisolated enum SearchText {
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            }
            // Anything else — punctuation, symbols, combining marks the fold left
            // behind — is dropped without separating the letters either side of it.
        }
        return String(result)
    }
}
