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
        }
    }
    
    /// Find field from alias string.
    /// O(1) dictionary lookup via the statically-built alias map — avoids the previous
    /// O(cases × aliases) linear scan that ran on every token parse.
    static func from(alias: String) -> SearchField? {
        let normalized = alias.lowercased().trimmingCharacters(in: .whitespaces)
        return aliasLookup[normalized]
    }
    
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
