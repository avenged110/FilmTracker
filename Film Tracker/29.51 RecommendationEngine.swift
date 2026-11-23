// MARK: - RecommendationEngine.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Behind `Preferences.recommendationsEnabled` (experiment flag + Settings checkbox). The engine behind the
/// Recommendations view (29.50 RecommendationsView.swift).
///
/// Everything here is a pure function of a `RecInput` snapshot: the library's films, Queue
/// sections, user-list names, the user's tuning and the feedback they gave in the view. It
/// runs off the main actor and touches no store, so a pass can be thrown away at any time.
///
/// ## The model, in one paragraph
/// Every film the user has an opinion about (a rating, a Hall of Fame place, a blacklist flag,
/// a "More/Less Like This" in the view, money spent, repeat viewings) becomes a labeled example
/// with a liking `y` in −1…1 and a confidence `w`. Each film is described by sparse features
/// (directors, writers, top-billed cast, composer, producers, studio, genre, decade,
/// certification, runtime band, the user's own tags and lists). A feature's affinity is the
/// confidence-weighted mean liking of the films that carry it, shrunk toward zero by a prior so
/// one film never makes a "favorite director". A candidate's taste score is the facet-weighted
/// mean of its features' affinities, leave-one-out, so a rated film never confirms itself.
/// On top of that come item-to-item connections (cosine over IDF-weighted features to the films
/// the user loves, and away from the ones they disliked), rewatch timing (rotation overdue,
/// personal rewatch cadence, Hall of Fame), the shelf (owned but unwatched, gathering dust,
/// freshly added, an unwatched 4K copy), timing (seasonal habits per film and per genre or tag,
/// release anniversaries, viewing anniversaries), and momentum (Queue sections, the release
/// wishlist, a current director or tag streak). Picks are chosen by maximal-marginal-relevance
/// re-ranking for variety, with a share of slots kept for deliberately unfamiliar wildcards.
///
/// ## Respecting the library's setup
/// A film is never offered when it carries any Special Sorting flag (the rotation lists' rule),
/// was watched inside its rotation threshold, is rated below the tuning's floor, sits in Up Next
/// (unless asked for), or was dismissed or snoozed in the view.

import Foundation
import Synchronization

// MARK: - Feature

/// One descriptive value of a film: a director, a tag, a decade, and so on.
nonisolated struct RecFeature: Hashable, Codable, Sendable {
    let facet: Facet
    /// Case- and diacritic-folded, so two spellings of one name are one feature.
    let key: String

    init(_ facet: Facet, _ value: String) {
        self.facet = facet
        self.key = Self.fold(value)
    }

    /// "director:sofia coppola": the feature as a stored dictionary key (RecFeedback.featureLeans).
    var storageKey: String { "\(facet.rawValue):\(key)" }

    init?(storageKey: String) {
        guard let colon = storageKey.firstIndex(of: ":"),
              let facet = Facet(rawValue: String(storageKey[..<colon])) else { return nil }
        let key = String(storageKey[storageKey.index(after: colon)...])
        guard !key.isEmpty else { return nil }
        self.facet = facet
        self.key = key
    }

    static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    enum Facet: String, Codable, CaseIterable, Sendable {
        case director, writer, cast, composer, producer, studio
        case genre, decade, certification, length, tag, list

        /// How much a shared value of this facet says about taste. A shared director says far
        /// more than a shared certification.
        var weight: Double {
            switch self {
            case .director:      return 1.0
            case .tag:           return 0.8
            case .writer:        return 0.7
            case .list:          return 0.6
            case .genre:         return 0.55
            case .cast:          return 0.5
            case .composer:      return 0.4
            case .decade:        return 0.35
            case .producer:      return 0.3
            case .studio:        return 0.25
            case .certification: return 0.12
            case .length:        return 0.12
            }
        }

        /// Whether a shared value ties two particular films together (a person, a tag, a list),
        /// as opposed to sorting them into a broad bucket (a genre, a decade).
        var isConnective: Bool {
            switch self {
            case .director, .writer, .cast, .composer, .producer, .tag, .list: return true
            case .studio, .genre, .decade, .certification, .length: return false
            }
        }

        var title: String {
            switch self {
            case .director:      return "Directors"
            case .writer:        return "Writers"
            case .cast:          return "Cast"
            case .composer:      return "Composers"
            case .producer:      return "Producers"
            case .studio:        return "Studios"
            case .genre:         return "Genres"
            case .decade:        return "Decades"
            case .certification: return "Certifications"
            case .length:        return "Lengths"
            case .tag:           return "Tags"
            case .list:          return "Lists"
            }
        }

        var glyph: String {
            switch self {
            case .director:      return "megaphone"
            case .writer:        return "pencil.and.scribble"
            case .cast:          return "person.2"
            case .composer:      return "music.note"
            case .producer:      return "briefcase"
            case .studio:        return "building.columns"
            case .genre:         return "theatermasks"
            case .decade:        return "calendar"
            case .certification: return "checkmark.shield"
            case .length:        return "clock"
            case .tag:           return "tag"
            case .list:          return "list.and.film"
            }
        }
    }
}

/// A feature the user steers toward, with the name to show for it.
nonisolated struct RecSteer: Hashable, Codable, Sendable {
    let feature: RecFeature
    let name: String
}

// MARK: - Tuning

/// Everything the user can set in the view. Persisted with the feedback (RecommendationsModel).
nonisolated struct RecTuning: Codable, Equatable, Sendable {
    enum Focus: String, Codable, CaseIterable, Sendable {
        case balanced, discover, revisit
        var title: String {
            switch self {
            case .balanced: return "Balanced"
            case .discover: return "Discover"
            case .revisit:  return "Revisit"
            }
        }
    }

    /// How much time there is. "Under" is strict, so the bands meet without overlapping: a film of
    /// exactly two hours is not under two hours. A film with no runtime passes every band.
    enum Length: String, Codable, CaseIterable, Sendable {
        case any, under90, under120, under150, atLeast150
        var title: String {
            switch self {
            case .any:        return "Any Length"
            case .under90:    return "Under 1½ Hours"
            case .under120:   return "Under 2 Hours"
            case .under150:   return "Under 2½ Hours"
            case .atLeast150: return "2½ Hours or More"
            }
        }
        func admits(_ minutes: Int?) -> Bool {
            guard let minutes else { return true }
            switch self {
            case .any:        return true
            case .under90:    return minutes < 90
            case .under120:   return minutes < 120
            case .under150:   return minutes < 150
            case .atLeast150: return minutes >= 150
            }
        }
    }

    /// The relative pull of each signal family. Each is set in five steps (`levels`) of its own
    /// default: Off, Light (half), Normal (the default), Strong (one and a half) and Dominant (double).
    struct Weights: Codable, Equatable, Sendable {
        var taste = 1.0
        var connections = 0.8
        var rewatch = 0.7
        var shelf = 0.5
        var timing = 0.5
        var momentum = 0.5

        /// The steps, as multiples of a family's default.
        static let levels: [Double] = [0, 0.5, 1, 1.5, 2]
        static let levelTitles = ["Off", "Light", "Normal", "Strong", "Dominant"]

        /// The step nearest a family's value.
        func level(_ path: WritableKeyPath<Weights, Double>) -> Int {
            Self.level(of: self[keyPath: path], baseline: Weights()[keyPath: path])
        }

        mutating func setLevel(_ level: Int, _ path: WritableKeyPath<Weights, Double>) {
            self[keyPath: path] = Self.value(level: level, baseline: Weights()[keyPath: path])
        }

        static func level(of value: Double, baseline: Double) -> Int {
            guard baseline > 0 else { return 2 }
            let ratio = value / baseline
            return levels.indices.min { abs(levels[$0] - ratio) < abs(levels[$1] - ratio) } ?? 2
        }

        static func value(level: Int, baseline: Double) -> Double {
            baseline * levels[min(levels.count - 1, max(0, level))]
        }
    }

    /// Adventurousness and variety are set in quarters (five steps).
    static func quarterStep(_ value: Double) -> Double { (min(1, max(0, value)) * 4).rounded() / 4 }

    var focus: Focus = .balanced
    var length: Length = .any
    /// Picks in all, the featured pick included.
    var pickCount = 12
    /// 0…1 in quarters: the share of slots given to wildcards (up to half of them).
    var adventurousness = 0.25
    /// 0…1 in quarters: how hard the picks are pushed apart from one another.
    var variety = 0.5
    /// A rated film below this is never resurfaced.
    var minimumRating = 6
    /// Up Next is the user's own choice already; offering it again is usually noise.
    var includeUpNext = false
    /// Only films with a viewing source or a purchased release.
    var onlyWatchable = false
    var showDoubleFeature = true
    var weights = Weights()
    var steer: [RecSteer] = []

    var wildcardCount: Int {
        guard pickCount > 2 else { return 0 }
        return min(pickCount / 2, Int((Double(pickCount) * adventurousness * 0.5).rounded()))
    }
}

// MARK: - Tolerant Decoding
/// Stored state outlives builds of this experiment. Each type decodes field by field with its
/// defaults, so a field added, renamed or retyped later costs only that field, never the whole
/// store (and with it everything the user taught the view).

extension RecTuning {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        focus = value(.focus, focus)
        length = value(.length, length)
        pickCount = min(24, max(4, value(.pickCount, pickCount)))
        adventurousness = RecTuning.quarterStep(value(.adventurousness, adventurousness))
        variety = RecTuning.quarterStep(value(.variety, variety))
        minimumRating = min(10, max(1, value(.minimumRating, minimumRating)))
        includeUpNext = value(.includeUpNext, includeUpNext)
        onlyWatchable = value(.onlyWatchable, onlyWatchable)
        showDoubleFeature = value(.showDoubleFeature, showDoubleFeature)
        weights = value(.weights, weights)
        steer = value(.steer, steer)
    }
}

extension RecTuning.Weights {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// Snapped to the nearest step of the family's default, as the Tune tab sets it.
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            let stored = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
            return Self.value(level: Self.level(of: stored, baseline: fallback), baseline: fallback)
        }
        taste = value(.taste, taste)
        connections = value(.connections, connections)
        rewatch = value(.rewatch, rewatch)
        shelf = value(.shelf, shelf)
        timing = value(.timing, timing)
        momentum = value(.momentum, momentum)
    }
}

extension RecFeedback {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        liked = value(.liked, liked)
        disliked = value(.disliked, disliked)
        snoozedUntil = value(.snoozedUntil, snoozedUntil)
        dismissed = value(.dismissed, dismissed)
        impressions = value(.impressions, impressions)
        cooldowns = value(.cooldowns, cooldowns)
        hits = value(.hits, hits)
        featureLeans = value(.featureLeans, featureLeans).filter { $0.value == 1 || $0.value == -1 }
        /// Builds before the three-way lean stored a 1…10 rating: 7 and up reads as a like, 4 and
        /// down as a dislike, and the middle as no lean.
        if (try? c.decodeIfPresent([String: Int].self, forKey: .featureLeans)) == nil,
           let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let ratings = try? legacy.decodeIfPresent([String: Int].self, forKey: .featureRatings) {
            featureLeans = ratings.compactMapValues { rating in
                (7...10).contains(rating) ? 1 : (1...4).contains(rating) ? -1 : nil
            }
        }
    }

    private enum LegacyKeys: String, CodingKey { case featureRatings }
}

// MARK: - Feedback

/// What the user told the view, plus what the engine observed (impressions and hits).
nonisolated struct RecFeedback: Codable, Equatable, Sendable {
    /// "More Like This" / "Less Like This": a pseudo-rating for the film's features.
    var liked: [UUID: Date] = [:]
    var disliked: [UUID: Date] = [:]
    /// "Not Now": hidden until the date.
    var snoozedUntil: [UUID: Date] = [:]
    /// "Never Recommend": hidden until restored.
    var dismissed: [UUID: Date] = [:]
    /// When each film was offered, for the cooldown and for counting hits.
    var impressions: [UUID: Impression] = [:]
    /// Films resting after being offered on `RecommendationEngine.cooldownShownDays` days without
    /// being watched. Not a judgment of the pick: when the rest ends the entry goes, and the film
    /// returns with no record of having been offered.
    var cooldowns: [UUID: Cooldown] = [:]
    /// Films watched within `RecommendationEngine.hitWindowDays` of being offered.
    var hits: [UUID: Date] = [:]
    /// The user's own lean toward a director, an actor, a genre and so on: 1 for like, −1 for
    /// dislike (no entry is neutral), keyed by RecFeature.storageKey. It outweighs what the engine
    /// infers from the films that carry it. Kept by Reset Learning: rating these is deliberate
    /// work, cleared on its own.
    var featureLeans: [String: Int] = [:]

    struct Impression: Codable, Equatable, Sendable {
        var firstShown: Date
        var lastShown: Date
        /// Distinct days it was offered.
        var days: Int
    }

    struct Cooldown: Codable, Equatable, Sendable {
        /// The impression's first day, kept so a viewing during the rest still counts as a hit.
        var firstShown: Date
        /// Offered again from this day (start of day).
        var until: Date
    }

    var isEmpty: Bool { liked.isEmpty && disliked.isEmpty && snoozedUntil.isEmpty && dismissed.isEmpty }
}

// MARK: - Input / Output

nonisolated struct RecInput: Sendable {
    let films: [FilmSnapshot]
    /// Each queued film's canonical section.
    let queue: [UUID: FilmQueueSection]
    /// Each film's user lists, by name (Queue lists excluded).
    let userLists: [UUID: [String]]
    var tuning: RecTuning
    let feedback: RecFeedback
    /// Films the user queued for Up Next from this view in this session: they stay on screen
    /// (marked "In Up Next") instead of vanishing the moment they are queued.
    let keepInUpNext: Set<UUID>
    /// Films Shuffle has already moved past today: pushed well down, so a shuffle brings new picks.
    var shuffledAway: Set<UUID> = []
    let today: Date
    var seed: UInt64
    /// The previous pass's analysis: reused whole when the library and the liked and disliked
    /// films are unchanged, and its library alone when only the liked or disliked films changed.
    var previous: RecAnalysis?
}

/// What a pass knows of the library alone (RecommendationEngine.buildLibrary): each film parsed,
/// its feature vector, the rating scale, viewing calendars and the counts behind every feature.
/// None of it depends on what the user liked or disliked in the view, so a More or Less Like This
/// keeps it; only a change to the films or their lists rebuilds it.
nonisolated struct RecLibrary: Sendable {
    struct Key: Equatable, Sendable {
        let films: [FilmSnapshot]
        let userLists: [UUID: [String]]

        init(_ input: RecInput) {
            films = input.films
            userLists = input.userLists
        }
    }

    let key: Key
    fileprivate let names: [RecFeature: String]
    /// Unlabeled (y and w are 0): RecAnalysis labels its own copy.
    fileprivate let facts: [RecommendationEngine.Facts]
    /// The counts that do not depend on labels (documents, films, ratings, viewings); sum, weight
    /// and labeled are 0 until RecAnalysis adds the labels.
    fileprivate let stats: [RecFeature: RecommendationEngine.FeatureStats]
    let mean: Double
    let spread: Double
    let hofCount: Int
    let ratedFilmCount: Int
    let viewingCount: Int
    let monthTotals: [Int]
    fileprivate let viewingDays: [[RecommendationEngine.ViewingDay]]
    /// The Rate tab's catalog in both orders, sorted the first time it is asked for
    /// (RecommendationEngine.catalog), after the picks, and kept while the library is unchanged.
    fileprivate let catalogOrder = LazyBox<[RecFeature.Facet: RecCatalogGroup]>()

    fileprivate init(key: Key, names: [RecFeature: String], facts: [RecommendationEngine.Facts],
                     stats: [RecFeature: RecommendationEngine.FeatureStats], mean: Double, spread: Double,
                     hofCount: Int, ratedFilmCount: Int, viewingCount: Int, monthTotals: [Int],
                     viewingDays: [[RecommendationEngine.ViewingDay]]) {
        self.key = key
        self.names = names
        self.facts = facts
        self.stats = stats
        self.mean = mean
        self.spread = spread
        self.hofCount = hofCount
        self.ratedFilmCount = ratedFilmCount
        self.viewingCount = viewingCount
        self.monthTotals = monthTotals
        self.viewingDays = viewingDays
    }
}

/// A value worked out once, on first request, by whichever pass asks first, and shared by every
/// pass holding the same library or analysis. Two passes asking at once may both work it out;
/// the results are identical, and the first stored is kept.
nonisolated final class LazyBox<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    func value(_ make: () -> Value) -> Value {
        if let value = stored.withLock({ $0 }) { return value }
        let made = make()
        return stored.withLock { current in
            if let current { return current }
            current = made
            return made
        }
    }

}

/// The analysis behind a pass (RecommendationEngine.analyze): the library (RecLibrary) labeled
/// with the user's liking of each film, and the anchors drawn from those labels. A pass that
/// changes only the tuning, the steering, the leans or the day reuses it and only rescores; a
/// More or Less Like This relabels the kept library.
nonisolated struct RecAnalysis: Sendable {
    struct Key: Equatable, Sendable {
        let liked: Set<UUID>
        let disliked: Set<UUID>

        init(_ input: RecInput) {
            liked = Set(input.feedback.liked.keys)
            disliked = Set(input.feedback.disliked.keys)
        }
    }

    let library: RecLibrary
    let key: Key
    fileprivate let facts: [RecommendationEngine.Facts]
    fileprivate let stats: [RecFeature: RecommendationEngine.FeatureStats]
    fileprivate let positiveIndex: [RecFeature: [Int]]
    fileprivate let negativeIndex: [RecFeature: [Int]]
    /// Each film's (by index in `facts`) nearest loved and disliked anchor and its pull, worked out
    /// the first time a pass needs it (only eligible films ever do) and kept for later passes,
    /// which share this analysis.
    private let nearestCache = NearestCache()
    /// The Rate tab's catalog with this analysis's figures (RecommendationEngine.catalog).
    fileprivate let catalog = LazyBox<[RecFeature.Facet: RecCatalogGroup]>()

    fileprivate init(library: RecLibrary, key: Key, facts: [RecommendationEngine.Facts],
                     stats: [RecFeature: RecommendationEngine.FeatureStats],
                     positiveIndex: [RecFeature: [Int]], negativeIndex: [RecFeature: [Int]]) {
        self.library = library
        self.key = key
        self.facts = facts
        self.stats = stats
        self.positiveIndex = positiveIndex
        self.negativeIndex = negativeIndex
    }

    /// Two passes share an analysis exactly when they hold the same one (copies share their caches).
    var identity: ObjectIdentifier { ObjectIdentifier(nearestCache) }

    typealias Pull = (anchor: Int, similarity: Double)

    func nearest(_ factIndex: Int) -> (positive: Pull?, negative: Pull?) {
        if let cached = nearestCache.entries.withLock({ $0[factIndex] }) { return cached }
        let fact = facts[factIndex]
        let value = (RecommendationEngine.nearest(fact, in: positiveIndex, facts: facts),
                     RecommendationEngine.nearest(fact, in: negativeIndex, facts: facts))
        nearestCache.entries.withLock { $0[factIndex] = value }
        return value
    }

    private final class NearestCache: Sendable {
        let entries = Mutex<[Int: (positive: Pull?, negative: Pull?)]>([:])
    }
}

nonisolated enum RecLane: String, Sendable {
    case match, connection, rewatch, shelf, fresh, timely, queue, steer, wildcard

    var title: String {
        switch self {
        case .match:      return "Taste Match"
        case .connection: return "Tied to a Favorite"
        case .rewatch:    return "Due for a Rewatch"
        case .shelf:      return "On Your Shelf"
        case .fresh:      return "Fresh Arrival"
        case .timely:     return "Timely"
        case .queue:      return "From Your Queue"
        case .steer:      return "Steered"
        case .wildcard:   return "Wildcard"
        }
    }

    var glyph: String {
        switch self {
        case .match:      return "sparkles"
        case .connection: return "link"
        case .rewatch:    return "arrow.counterclockwise"
        case .shelf:      return "opticaldisc"
        case .fresh:      return "shippingbox"
        case .timely:     return "calendar"
        case .queue:      return "text.line.last.and.arrowtriangle.forward"
        case .steer:      return "scope"
        case .wildcard:   return "dice"
        }
    }
}

nonisolated struct RecReason: Hashable, Sendable {
    let glyph: String
    let text: String
    let strength: Double
}

nonisolated struct RecPick: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let year: String
    let posterUID: String
    let runtimeMinutes: Int?
    let byline: String
    let certification: String
    let genre: String
    let synopsis: String
    let userRating: Int
    let queueSection: FilmQueueSection?
    let lane: RecLane
    /// 20…99: how well the film fits the learned taste (not its timing).
    let match: Int
    let score: Double
    let reasons: [RecReason]
}

nonisolated struct RecDoubleFeature: Equatable, Sendable {
    let first: RecPick
    let second: RecPick
    let link: String
    let linkGlyph: String
    let totalMinutes: Int?
}

nonisolated struct RecProfile: Sendable {
    struct Entry: Identifiable, Sendable {
        var id: RecFeature { feature }
        let feature: RecFeature
        let name: String
        /// −1…1.
        let affinity: Double
        /// Labeled films carrying the feature.
        let count: Int
        let averageRating: Double?
        /// The user's own lean (1 like, −1 dislike), when they gave one.
        var userLean: Int? = nil
    }
    struct Group: Identifiable, Sendable {
        var id: RecFeature.Facet { facet }
        let facet: RecFeature.Facet
        let entries: [Entry]
    }
    let groups: [Group]
    let dislikes: [Entry]
}

nonisolated struct RecStats: Sendable {
    struct Exclusion: Identifiable, Sendable {
        var id: String { label }
        let label: String
        let count: Int
    }
    let filmCount: Int
    let ratedCount: Int
    let viewingCount: Int
    let meanRating: Double
    let hallOfFameCount: Int
    let labeledCount: Int
    let eligibleCount: Int
    let exclusions: [Exclusion]
    let streak: String?
}

/// One value of a facet as the Rating tab lists it: every director, actor, genre and so on in
/// the library, with what the engine inferred about it.
nonisolated struct RecCatalogEntry: Identifiable, Sendable {
    /// RecFeature.storageKey, built once: the Rate tab compares and looks up rows by it.
    let id: String
    let feature: RecFeature
    let name: String
    /// Films carrying it, and how many of those the user rated.
    let filmCount: Int
    let ratedCount: Int
    let averageRating: Double?
    /// The films carrying it, for the Rate tab's films popover.
    let filmIDs: [UUID]
    /// Its films with a taste label (rated, watched, Hall of Fame, …). Set per analysis
    /// (RecommendationEngine.catalog); the library's sorted catalog leaves it 0.
    fileprivate(set) var labeled: Int
    /// −1…1, from the films alone (the user's own rating of the feature left out); nil when fewer
    /// than `RecommendationEngine.confidentFilms` of its films say anything about taste. Set per
    /// analysis, as `labeled` is.
    fileprivate(set) var inferred: Double?
    /// The name folded for the Rate tab's filter, and its sort key there (people by last name).
    let foldedName: String
    let sortName: String

    init(feature: RecFeature, name: String, filmCount: Int, ratedCount: Int, averageRating: Double?,
         filmIDs: [UUID], labeled: Int, inferred: Double?) {
        self.id = feature.storageKey
        self.feature = feature
        self.name = name
        self.filmCount = filmCount
        self.ratedCount = ratedCount
        self.averageRating = averageRating
        self.filmIDs = filmIDs
        self.labeled = labeled
        self.inferred = inferred
        self.foldedName = RecFeature.fold(name)
        self.sortName = Self.sortKey(name, facet: feature.facet)
    }

    private static let personFacets: Set<RecFeature.Facet> = [.director, .writer, .cast, .composer, .producer]
    private static let nameSuffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
    /// The Length facet's values, shortest first, for its by-name order.
    private static let lengthOrder = ["Under 90 Minutes", "90–120 Minutes", "2–2½ Hours", "Over 2½ Hours"]

    /// A person sorts by the last word of their name, a trailing "Jr.", "Sr." or numeral aside:
    /// "Robert Downey Jr." sorts as "Downey Robert Jr.". Anything else sorts by its name.
    static func sortKey(_ name: String, facet: RecFeature.Facet) -> String {
        guard personFacets.contains(facet) else { return name }
        let words = name.split(separator: " ").map(String.init)
        var end = words.count
        while end > 1, nameSuffixes.contains(words[end - 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
            end -= 1
        }
        guard end > 1 else { return name }
        let given = words[..<(end - 1)].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
        return ([words[end - 1]] + given + Array(words[end...])).joined(separator: " ")
    }

    /// By name: people by last name, the Length facet shortest first.
    static func byName(_ a: RecCatalogEntry, _ b: RecCatalogEntry) -> Bool {
        if a.feature.facet == .length {
            return (lengthOrder.firstIndex(of: a.name) ?? 9) < (lengthOrder.firstIndex(of: b.name) ?? 9)
        }
        for (x, y) in [(a.sortName, b.sortName), (a.name, b.name)] {
            let order = x.localizedStandardCompare(y)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return a.id < b.id
    }
}

/// One facet's values in the Rate tab's two stored orders, sorted off the main actor with the
/// rest of a pass, so the tab only filters (and, for Your Choices First, partitions) on screen.
nonisolated struct RecCatalogGroup: Sendable {
    /// Most films first, then by name.
    let byFilms: [RecCatalogEntry]
    let byName: [RecCatalogEntry]

    init(byFilms: [RecCatalogEntry], byName: [RecCatalogEntry]) {
        self.byFilms = byFilms
        self.byName = byName
    }

    init(_ entries: [RecCatalogEntry]) {
        byName = entries.sorted(by: RecCatalogEntry.byName)
        byFilms = byName.enumerated()
            .sorted { $0.element.filmCount != $1.element.filmCount
                ? $0.element.filmCount > $1.element.filmCount : $0.offset < $1.offset }
            .map(\.element)
    }
}

nonisolated struct RecSteerGroup: Identifiable, Sendable {
    var id: RecFeature.Facet { facet }
    let facet: RecFeature.Facet
    let options: [RecSteer]
}

nonisolated struct RecResult: Sendable {
    let hero: RecPick?
    let picks: [RecPick]
    let wildcards: [RecPick]
    let doubleFeature: RecDoubleFeature?
    let profile: RecProfile
    let stats: RecStats
    let steerGroups: [RecSteerGroup]
    let newHits: [UUID: Date]
    /// Films this pass moved into their cooldown (RecFeedback.cooldowns); their impressions go.
    let newCooldowns: [UUID: RecFeedback.Cooldown]
    /// Films with an impression or cooldown watched since first offered: their record starts over.
    let watchedSinceOffered: Set<UUID>
    let milliseconds: Int
    /// For the next pass (RecInput.previous), and for the Rate tab's catalog
    /// (RecommendationEngine.catalog), built from it after the picks are shown.
    let analysis: RecAnalysis

    var allPickIDs: [UUID] {
        var ids = (hero.map { [$0.id] } ?? []) + picks.map(\.id) + wildcards.map(\.id)
        if let doubleFeature { ids += [doubleFeature.first.id, doubleFeature.second.id] }
        return ids
    }
}

// MARK: - Engine

nonisolated enum RecommendationEngine {
    /// A film watched this many days after first being offered counts as a hit.
    static let hitWindowDays = 45
    /// A pick offered on this many days and not watched rests for `cooldownDays`, then returns fresh.
    static let cooldownShownDays = 4
    static let cooldownDays = 14

    /// Shrinks a feature's affinity toward zero: a director with one 10 is a hint, not a favorite.
    private static let affinityPrior = 1.5
    /// Films with a taste label a feature needs before its affinity counts in full, earns a badge on
    /// the Rate tab, a reason, or a place in the profile. One well-rated film says little about an
    /// actor; below this, the affinity is only a speculative nudge at `speculativeShare` strength.
    static let confidentFilms = 3
    private static let speculativeShare = 0.25
    /// How much of a rated feature's affinity is the user's own lean; its films decide the rest.
    private static let userRatingShare = 0.85
    /// The affinity a like (or, negated, a dislike) stands for: a clear favorite, as a film rated
    /// well above the user's average reads, without claiming the extreme.
    private static let leanAffinity = 0.7
    private static let castLimit = 6
    private static let writerLimit = 4
    private static let producerLimit = 3

    // MARK: Facts

    /// One film, parsed once.
    fileprivate struct Facts {
        let film: FilmSnapshot
        let features: [RecFeature]
        let runtime: Int?
        let year: Int?
        /// Ascending.
        let viewings: [Date]
        let lastWatched: Date?
        let added: Date?
        let originalRelease: Date?
        let purchased: Bool
        let ownsUHD: Bool
        let uhdPurchase: Date?
        let spent: Double
        let wishlisted: Bool
        let watchable: Bool
        /// Liking (−1…1) and its confidence; w == 0 means unlabeled.
        var y = 0.0
        var w = 0.0
        /// Weighted, IDF-scaled feature vector and its norm, filled after document frequencies.
        var vector: [RecFeature: Double] = [:]
        var norm = 0.0
        /// The same, over connective features only (people, tags, lists): what ties two films
        /// together, as opposed to sharing a genre or a decade with hundreds of others.
        var links: [RecFeature: Double] = [:]
        var linkNorm = 0.0

        var id: UUID { film.id }
        var rating: Int { film.userRating }
    }

    private static func makeFacts(_ film: FilmSnapshot, lists: [String],
                                  names: inout [RecFeature: String]) -> Facts {
        var features: [RecFeature] = []
        var seen = Set<RecFeature>()
        func add(_ facet: RecFeature.Facet, _ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let feature = RecFeature(facet, value)
            guard !feature.key.isEmpty, seen.insert(feature).inserted else { return }
            features.append(feature)
            if names[feature] == nil { names[feature] = value }
        }
        film.directors.forEach { add(.director, $0) }
        film.screenwriters.prefix(writerLimit).forEach { add(.writer, $0) }
        film.cast.prefix(castLimit).forEach { add(.cast, $0) }
        film.composer.forEach { add(.composer, $0) }
        film.producers.prefix(producerLimit).forEach { add(.producer, $0) }
        film.studio.forEach { add(.studio, $0) }
        add(.genre, film.genre)
        add(.certification, film.rating)
        film.tags.forEach { add(.tag, $0) }
        lists.forEach { add(.list, $0) }

        let year = Int(film.releaseYear.prefix(4))
        if let year, year >= DateFloor.year { add(.decade, "\(year / 10 * 10)s") }
        let runtime = DurationHelpers.storedMinutes(film.effectiveDuration).flatMap { $0 > 0 ? $0 : nil }
        if let runtime {
            switch runtime {
            case ..<90:    add(.length, "Under 90 Minutes")
            case 90..<120: add(.length, "90–120 Minutes")
            case 120..<150: add(.length, "2–2½ Hours")
            default:       add(.length, "Over 2½ Hours")
            }
        }

        let viewings = film.calendarTable.compactMap { parseDate(from: $0) }.sorted()
        /// The later of the stored last viewing and the viewing history, so a film is never offered
        /// on the strength of a stale "last watched" when the history records a newer viewing.
        let lastWatched = [parseDate(from: film.lastWatched), viewings.last].compactMap { $0 }.max()

        var purchased = false
        var ownsUHD = false
        var uhdPurchase: Date?
        var spent = 0.0
        var wishlisted = false
        for release in film.releases where release.isTopLevel {
            if release.wishlist > 0 { wishlisted = true }
            guard release.purchased else { continue }
            purchased = true
            spent += release.amountSpent > 0 ? release.amountSpent : release.cost
            if release.format == ReleaseFormat.uhd4K.rawValue {
                ownsUHD = true
                if let date = parseDate(from: release.purchaseDate) {
                    uhdPurchase = max(uhdPurchase ?? date, date)
                }
            }
        }

        return Facts(
            film: film, features: features, runtime: runtime, year: year,
            viewings: viewings, lastWatched: lastWatched,
            added: parseDate(from: film.dateAdded),
            originalRelease: parseDate(from: film.releaseDate),
            purchased: purchased, ownsUHD: ownsUHD, uhdPurchase: uhdPurchase, spent: spent,
            wishlisted: wishlisted,
            watchable: purchased || !film.digitalSource.isEmpty)
    }

    // MARK: Labels

    /// The film's liking and confidence. Ratings are standardized against the user's own scale,
    /// so a 7 from someone who rates everything 8–10 reads as lukewarm.
    private static func label(_ facts: Facts, mean: Double, spread: Double, hofCount: Int,
                              feedback: RecFeedback) -> (y: Double, w: Double) {
        let film = facts.film
        var y = 0.0
        var w = 0.0
        if film.userRating > 0 {
            y = clamp((Double(film.userRating) - mean) / spread / 2, -1, 1)
            w = 1
        } else if film.watched {
            y = 0.05
            w = 0.15
        }
        if film.hofPosition > 0 {
            let rank = hallOfFameRank(film.hofPosition, of: hofCount)
            y = max(y, 0.7 + 0.3 * (1 - rank))
            w = max(w, 1.5)
        }
        if facts.viewings.count >= 2 {
            y += 0.12 * log2(Double(facts.viewings.count))
            w = max(w, 0.5)
        }
        if facts.purchased, film.userRating == 0 {
            y += facts.ownsUHD ? 0.15 : 0.08
            w = max(w, 0.3)
        }
        if film.specialSorting.contains(FilmSpecialSorting.blacklisted) {
            y = -1
            w = max(w, 0.8)
        } else if film.specialSorting.contains(FilmSpecialSorting.ignore) {
            y = min(y, -0.3)
            w = max(w, 0.3)
        }
        if feedback.liked[film.id] != nil { y = max(y, 0.8); w = max(w, 1) }
        if feedback.disliked[film.id] != nil { y = min(y, -0.8); w = max(w, 1) }
        return (clamp(y, -1, 1), w)
    }

    // MARK: Feature Statistics

    fileprivate struct FeatureStats {
        var sum = 0.0
        var weight = 0.0
        var labeled = 0
        var ratingSum = 0
        var rated = 0
        var documents = 0
        /// Viewings by month (1…12), for seasonal habits of genres and tags.
        var monthViewings = [Int](repeating: 0, count: 13)
        var viewings = 0
        var filmIDs: [UUID] = []

        mutating func addLabel(y: Double, w: Double) {
            sum += w * y
            weight += w
            labeled += 1
        }

        mutating func addViewings(_ days: [ViewingDay]) {
            for day in days { monthViewings[day.month] += 1 }
            viewings += days.count
        }
    }

    /// A viewing's calendar year, month and day of the year, in the engine's calendar.
    struct ViewingDay {
        let year: Int
        let month: Int
        /// Nil only where the calendar cannot place the date, as `ordinality` allows.
        let ordinal: Int?

        init(_ date: Date, calendar: Calendar) {
            let parts = calendar.dateComponents([.year, .month], from: date)
            year = parts.year ?? 0
            month = parts.month ?? 0
            ordinal = calendar.ordinality(of: .day, in: .year, for: date)
        }
    }

    /// Steps 1–3 of a pass (see `run`), the part that depends on the library alone: the facts, the
    /// rating scale, each feature's counts and each film's feature vector.
    private static func buildLibrary(_ input: RecInput, key: RecLibrary.Key, calendar: Calendar) -> RecLibrary {
        // 1. Facts
        /// In a fixed order: the store hands films over in an order that changes from launch to
        /// launch, and every tie below (the anchor cut, equal pulls, floating-point sums) would
        /// otherwise follow it, so the same day's picks could differ after a relaunch.
        /// Keyed once: building each UUID's string inside the comparator allocated two per comparison.
        let films = input.films.map { ($0.id.uuidString, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        var names: [RecFeature: String] = [:]
        var facts: [Facts] = []
        facts.reserveCapacity(films.count)
        for film in films {
            facts.append(makeFacts(film, lists: input.userLists[film.id] ?? [], names: &names))
        }

        // 2. The user's rating scale
        let ratings = facts.compactMap { $0.rating > 0 ? Double($0.rating) : nil }
        let mean = ratings.isEmpty ? 7 : ratings.reduce(0, +) / Double(ratings.count)
        let variance = ratings.isEmpty ? 1 : ratings.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ratings.count)
        let spread = max(1, variance.squareRoot())
        let hofCount = facts.reduce(0) { $0 + ($1.film.hofPosition > 0 ? 1 : 0) }

        // 3. Feature counts (labels come later, in `analyze`)
        var stats: [RecFeature: FeatureStats] = [:]
        var monthTotals = [Int](repeating: 0, count: 13)
        var viewingCount = 0
        /// Each film's viewings as calendar days, worked out once: the month totals, the genre and
        /// tag seasons, and the timing signals below all read them.
        var viewingDays: [[ViewingDay]] = []
        viewingDays.reserveCapacity(facts.count)
        /// Updated in place through the dictionary's default subscript. Copying an entry out and
        /// storing it back left the dictionary holding a second reference to its film list, so
        /// every append copied the whole list: quadratic in a common genre's film count.
        func record(_ entry: inout FeatureStats, _ fact: Facts) {
            entry.documents += 1
            entry.filmIDs.append(fact.film.id)
            if fact.rating > 0 {
                entry.ratingSum += fact.rating
                entry.rated += 1
            }
        }
        for fact in facts {
            let days = fact.viewings.map { ViewingDay($0, calendar: calendar) }
            viewingDays.append(days)
            viewingCount += days.count
            for day in days { monthTotals[day.month] += 1 }
            for feature in fact.features {
                record(&stats[feature, default: FeatureStats()], fact)
                if feature.facet == .genre || feature.facet == .tag, !days.isEmpty {
                    stats[feature, default: FeatureStats()].addViewings(days)
                }
            }
        }
        let documentCount = Double(max(1, facts.count))
        func idf(_ feature: RecFeature) -> Double {
            log(1 + documentCount / Double(max(1, stats[feature]?.documents ?? 1)))
        }
        for index in facts.indices {
            var vector: [RecFeature: Double] = [:]
            var links: [RecFeature: Double] = [:]
            var squares = 0.0
            var linkSquares = 0.0
            for feature in facts[index].features {
                let value = feature.facet.weight * idf(feature)
                vector[feature] = value
                squares += value * value
                if feature.facet.isConnective {
                    links[feature] = value
                    linkSquares += value * value
                }
            }
            facts[index].vector = vector
            facts[index].norm = squares.squareRoot()
            facts[index].links = links
            facts[index].linkNorm = linkSquares.squareRoot()
        }

        return RecLibrary(key: key, names: names, facts: facts, stats: stats, mean: mean, spread: spread,
                          hofCount: hofCount, ratedFilmCount: ratings.count, viewingCount: viewingCount,
                          monthTotals: monthTotals, viewingDays: viewingDays)
    }

    /// Step 4 of a pass: the library labeled with the user's liking of each film (its feature
    /// statistics' sums with it), and the anchors drawn from those labels. Works on copies of the
    /// library's facts and statistics, which only gain their label fields.
    private static func analyze(_ library: RecLibrary, key: RecAnalysis.Key, feedback: RecFeedback) -> RecAnalysis {
        var facts = library.facts
        var stats = library.stats
        for index in facts.indices {
            let (y, w) = label(facts[index], mean: library.mean, spread: library.spread,
                               hofCount: library.hofCount, feedback: feedback)
            facts[index].y = y
            facts[index].w = w
            guard w > 0 else { continue }
            for feature in facts[index].features {
                stats[feature, default: FeatureStats()].addLabel(y: y, w: w)
            }
        }

        // Anchors: the films the user loves and the ones they turned away from
        let positiveAnchors = facts.indices
            .filter { facts[$0].w > 0 && facts[$0].y >= 0.45 && facts[$0].linkNorm > 0 }
            .sorted { lhs, rhs in
                let a = facts[lhs].y * facts[lhs].w, b = facts[rhs].y * facts[rhs].w
                return a != b ? a > b : lhs < rhs
            }
            .prefix(250)
        let negativeAnchors = facts.indices
            .filter { facts[$0].w > 0 && facts[$0].y <= -0.45 && facts[$0].linkNorm > 0 }
            .sorted { lhs, rhs in facts[lhs].y != facts[rhs].y ? facts[lhs].y < facts[rhs].y : lhs < rhs }
            .prefix(150)
        func invertedIndex(_ anchors: some Sequence<Int>) -> [RecFeature: [Int]] {
            var index: [RecFeature: [Int]] = [:]
            for anchor in anchors {
                for feature in facts[anchor].links.keys { index[feature, default: []].append(anchor) }
            }
            return index
        }

        return RecAnalysis(library: library, key: key, facts: facts, stats: stats,
                           positiveIndex: invertedIndex(positiveAnchors),
                           negativeIndex: invertedIndex(negativeAnchors))
    }

    /// The Rate tab's catalog for an analysis: every feature value in the library, by facet, in
    /// both orders, with what this analysis infers about each. The sort, most of the cost, depends
    /// on the library alone and is done once per library; each analysis only fills in its figures.
    /// Called off the main actor after the picks are shown, so a pass never waits on it.
    static func catalog(for analysis: RecAnalysis) -> [RecFeature.Facet: RecCatalogGroup] {
        analysis.catalog.value {
            let library = analysis.library
            let sorted = library.catalogOrder.value {
                let entries = library.stats.map { feature, entry in
                    RecCatalogEntry(feature: feature, name: library.names[feature] ?? feature.key,
                                    filmCount: entry.documents, ratedCount: entry.rated,
                                    averageRating: entry.rated > 0 ? Double(entry.ratingSum) / Double(entry.rated) : nil,
                                    filmIDs: entry.filmIDs, labeled: 0, inferred: nil)
                }
                return Dictionary(grouping: entries, by: \.feature.facet).mapValues(RecCatalogGroup.init)
            }
            let stats = analysis.stats
            func figured(_ entries: [RecCatalogEntry]) -> [RecCatalogEntry] {
                entries.map { entry in
                    var entry = entry
                    if let stat = stats[entry.feature] {
                        entry.labeled = stat.labeled
                        entry.inferred = stat.labeled >= confidentFilms ? stat.sum / (stat.weight + affinityPrior) : nil
                    }
                    return entry
                }
            }
            return sorted.mapValues { RecCatalogGroup(byFilms: figured($0.byFilms), byName: figured($0.byName)) }
        }
    }

    /// The anchor most like `fact` by its connective features, weighted by how much the anchor is
    /// liked (or disliked).
    fileprivate static func nearest(_ fact: Facts, in index: [RecFeature: [Int]],
                                    facts: [Facts]) -> (anchor: Int, similarity: Double)? {
        guard fact.linkNorm > 0 else { return nil }
        var dots: [Int: Double] = [:]
        /// Walked in the film's own feature order, not the dictionary's, so the sums (and so
        /// any tie between anchors) come out the same on every launch.
        for feature in fact.features {
            guard let value = fact.links[feature], let anchors = index[feature] else { continue }
            for anchor in anchors where facts[anchor].id != fact.id {
                dots[anchor, default: 0] += value * (facts[anchor].links[feature] ?? 0)
            }
        }
        var best: (Int, Double)?
        for (anchor, dot) in dots {
            let cosine = dot / (fact.linkNorm * facts[anchor].linkNorm)
            let pull = cosine * abs(facts[anchor].y)
            if pull > (best?.1 ?? 0) || (pull == best?.1 && anchor < (best?.0 ?? .max)) { best = (anchor, pull) }
        }
        return best
    }

    // MARK: Run

    static func run(_ input: RecInput) -> RecResult {
        let started = Date()
        let calendar = AppCalendar.current
        let today = calendar.startOfDay(for: input.today)
        let tuning = input.tuning
        let feedback = input.feedback
        let weights = tuning.weights

        // 1–4. The library (facts, the rating scale, feature counts, vectors) and its analysis (labels,
        /// feature statistics, anchors and each film's nearest anchors). Neither depends on the tuning,
        /// steering, leans, impressions or the day, so a pass that changes only those reuses the
        /// previous pass's; one that changes only the liked or disliked films reuses its library.
        /// A More or Less Like This keeps the library and only relabels it.
        let libraryKey = RecLibrary.Key(input)
        let analysisKey = RecAnalysis.Key(input)
        let previous = input.previous.flatMap { $0.library.key == libraryKey ? $0 : nil }
        let analysis = previous.flatMap { $0.key == analysisKey ? $0 : nil }
            ?? analyze(previous?.library ?? buildLibrary(input, key: libraryKey, calendar: calendar),
                       key: analysisKey, feedback: feedback)
        let library = analysis.library
        let names = library.names, facts = analysis.facts, stats = analysis.stats
        let mean = library.mean, spread = library.spread, hofCount = library.hofCount
        let ratedFilmCount = library.ratedFilmCount, viewingCount = library.viewingCount
        let monthTotals = library.monthTotals, viewingDays = library.viewingDays
        let totalViewings = max(1, monthTotals.reduce(0, +))
        let documentCount = Double(max(1, facts.count))
        func idf(_ feature: RecFeature) -> Double {
            log(1 + documentCount / Double(max(1, stats[feature]?.documents ?? 1)))
        }

        /// The user's own leans toward features: a like is a clear favorite, a dislike its opposite.
        var rated: [RecFeature: (y: Double, lean: Int)] = [:]
        for (storageKey, lean) in feedback.featureLeans {
            guard lean == 1 || lean == -1, let feature = RecFeature(storageKey: storageKey) else { continue }
            rated[feature] = (Double(lean) * leanAffinity, lean)
        }

        /// The feature's affinity from its films, without `fact`'s own contribution.
        func learnedAffinity(_ feature: RecFeature, excluding fact: Facts?) -> (value: Double, labeled: Int) {
            guard let entry = stats[feature] else { return (0, 0) }
            var sum = entry.sum, weight = entry.weight, labeled = entry.labeled
            if let fact, fact.w > 0 {
                sum -= fact.w * fact.y
                weight -= fact.w
                labeled -= 1
            }
            guard labeled > 0 else { return (0, 0) }
            let value = sum / (max(0, weight) + affinityPrior)
            return (labeled >= confidentFilms ? value : value * speculativeShare, labeled)
        }

        /// The feature's affinity. The user's own rating of it, where there is one, outweighs what
        /// its films suggest: it is the nuance the films cannot show (an actor in mostly poor films
        /// whom the user still likes). The films keep a small say.
        func affinity(_ feature: RecFeature, excluding fact: Facts?) -> (value: Double, labeled: Int) {
            let learned = learnedAffinity(feature, excluding: fact)
            guard let own = rated[feature] else { return learned }
            return (userRatingShare * own.y + (1 - userRatingShare) * learned.value, max(1, learned.labeled))
        }

        func cosine(_ a: Facts, _ b: Facts) -> Double {
            guard a.norm > 0, b.norm > 0 else { return 0 }
            let (small, large) = a.vector.count <= b.vector.count ? (a, b) : (b, a)
            var dot = 0.0
            for feature in small.features {
                if let value = small.vector[feature], let other = large.vector[feature] { dot += value * other }
            }
            return dot / (a.norm * b.norm)
        }

        // 5. Recent viewing: a streak of one director or tag in the last 60 days
        /// The last year's viewing diet: which features the user has actually been watching. A
        /// wildcard is a film whose director, decade, genre and tags are absent from it.
        let yearCutoff = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        var recentDiet: [RecFeature: Int] = [:]
        /// `lastWatched` is the later of the viewing history and the stored last viewing, so a film
        /// whose recent viewing is recorded only in the field still counts as watched this year.
        for fact in facts where (fact.lastWatched ?? .distantPast) >= yearCutoff {
            for feature in fact.features { recentDiet[feature, default: 0] += 1 }
        }
        let noveltyFacets: Set<RecFeature.Facet> = [.director, .decade, .genre, .tag, .cast, .writer]
        let recentCutoff = calendar.date(byAdding: .day, value: -60, to: today) ?? today
        var recentCounts: [RecFeature: Int] = [:]
        for fact in facts {
            guard let last = fact.lastWatched, last >= recentCutoff else { continue }
            for feature in fact.features where feature.facet.isConnective && feature.facet != .list {
                recentCounts[feature, default: 0] += 1
            }
        }
        let streak = recentCounts
            .filter { $0.value >= 2 && ($0.key.facet == .director || $0.key.facet == .tag || $0.key.facet == .cast) }
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                if lhs.key.facet.weight != rhs.key.facet.weight { return lhs.key.facet.weight < rhs.key.facet.weight }
                return lhs.key.key > rhs.key.key
            }

        // 6. Eligibility and scoring
        let currentMonth = calendar.component(.month, from: today)
        let currentYear = calendar.component(.year, from: today)
        let monthName = calendar.monthSymbols[currentMonth - 1]
        let todayOrdinal = calendar.ordinality(of: .day, in: .year, for: today) ?? 1
        let steerFeatures = Set(tuning.steer.map(\.feature))

        var exclusions: [String: Int] = [:]
        var candidates: [Candidate] = []
        var newHits: [UUID: Date] = [:]
        var newCooldowns: [UUID: RecFeedback.Cooldown] = [:]
        var watchedSinceOffered: Set<UUID> = []

        for (factIndex, fact) in facts.enumerated() {
            let film = fact.film

            /// Hits: watched after being offered.
            /// A film in its cooldown keeps its first day there.
            if let firstShown = feedback.impressions[film.id]?.firstShown ?? feedback.cooldowns[film.id]?.firstShown,
               let last = fact.lastWatched, last >= calendar.startOfDay(for: firstShown) {
                watchedSinceOffered.insert(film.id)
            }
            if let firstShown = feedback.impressions[film.id]?.firstShown ?? feedback.cooldowns[film.id]?.firstShown,
               feedback.hits[film.id] == nil,
               let last = fact.lastWatched,
               last >= calendar.startOfDay(for: firstShown),
               let window = calendar.date(byAdding: .day, value: hitWindowDays, to: firstShown),
               last <= window {
                newHits[film.id] = last
            }

            // Hard rules first.
            if !film.specialSorting.isEmpty { exclusions["Special Sorting (blacklisted, on hold, …)", default: 0] += 1; continue }
            if feedback.dismissed[film.id] != nil { exclusions["Never recommend", default: 0] += 1; continue }
            if let until = feedback.snoozedUntil[film.id], until > input.today { exclusions["Snoozed", default: 0] += 1; continue }
            /// Cooldown: offered on its full run of days (the last one over) and not watched since
            /// it was first offered. A rest, not a penalty: nothing about the film's score changes.
            if let cooldown = feedback.cooldowns[film.id], cooldown.until > today, !watchedSinceOffered.contains(film.id) {
                exclusions["Cooling down", default: 0] += 1; continue
            }
            if let impression = feedback.impressions[film.id], impression.days >= cooldownShownDays,
               calendar.startOfDay(for: impression.lastShown) < today,
               (fact.lastWatched ?? .distantPast) < calendar.startOfDay(for: impression.firstShown),
               let until = calendar.date(byAdding: .day, value: cooldownDays + 1,
                                         to: calendar.startOfDay(for: impression.lastShown)) {
                newCooldowns[film.id] = RecFeedback.Cooldown(firstShown: impression.firstShown, until: until)
                if until > today { exclusions["Cooling down", default: 0] += 1; continue }
            }
            if film.userRating > 0, film.userRating < tuning.minimumRating {
                exclusions["Rated below \(tuning.minimumRating)", default: 0] += 1; continue
            }
            var monthsSince: Double?
            if film.watched, let last = fact.lastWatched {
                if let eligible = rotationEligibilityDate(from: last, months: film.rotationThreshold), eligible > today {
                    exclusions["Watched within its rotation threshold", default: 0] += 1; continue
                }
                monthsSince = Double(calendar.dateComponents([.day], from: last, to: today).day ?? 0) / 30.44
            }
            let queueSection = input.queue[film.id]
            if queueSection == .upNext, !tuning.includeUpNext, !input.keepInUpNext.contains(film.id) { exclusions["Already in Up Next", default: 0] += 1; continue }
            switch tuning.focus {
            case .balanced: break
            case .discover where film.watched, .revisit where !film.watched:
                exclusions["Outside the current focus", default: 0] += 1; continue
            default: break
            }
            if !tuning.length.admits(fact.runtime) { exclusions["Outside the chosen length", default: 0] += 1; continue }
            if tuning.onlyWatchable, !fact.watchable { exclusions["No viewing source", default: 0] += 1; continue }

            var reasons: [RecReason] = []

            // Taste (leave-one-out).
            var facetSums: [RecFeature.Facet: (sum: Double, count: Int)] = [:]
            var bestFeature: (feature: RecFeature, pull: Double, labeled: Int)?
            for feature in fact.features {
                let (value, labeled) = affinity(feature, excluding: fact)
                guard labeled > 0 else { continue }
                facetSums[feature.facet, default: (0, 0)].sum += value
                facetSums[feature.facet, default: (0, 0)].count += 1
                let pull = value * feature.facet.weight
                let minimum = rated[feature] != nil ? 1 : confidentFilms
                if labeled >= minimum, pull > (bestFeature?.pull ?? 0.04) {
                    bestFeature = (feature, pull, labeled)
                }
            }
            var tasteNumerator = 0.0
            var tasteDenominator = 0.0
            for facet in RecFeature.Facet.allCases {
                guard let entry = facetSums[facet] else { continue }
                tasteNumerator += facet.weight * entry.sum / Double(entry.count)
                tasteDenominator += facet.weight
            }
            let taste = tasteDenominator > 0 ? tasteNumerator / tasteDenominator : 0
            var novelWeight = 0.0
            var noveltyWeight = 0.0
            for feature in fact.features where noveltyFacets.contains(feature.facet) {
                noveltyWeight += feature.facet.weight
                if recentDiet[feature] == nil { novelWeight += feature.facet.weight }
            }
            let novelty = noveltyWeight > 0 ? novelWeight / noveltyWeight : 0
            if let best = bestFeature, let name = names[best.feature] {
                reasons.append(RecReason(glyph: best.feature.facet.glyph,
                                         text: tasteText(best.feature, name: name, stats: stats[best.feature],
                                                         userLean: rated[best.feature]?.lean),
                                         strength: best.pull * 1.4))
            }

            // Connections.
            var connection = 0.0
            let pulls = analysis.nearest(factIndex)
            if let (anchor, pull) = pulls.positive, pull > 0.08 {
                connection = min(1, pull * 1.6)
                let anchorFacts = facts[anchor]
                /// "Because you put “Heat,” which is also directed by Michael Mann, in your Hall of Fame".
                let clause = strongestShared(fact, anchorFacts, names: names)
                let title = anchorFacts.film.name
                let named = clause.map { "“\(title),” which \($0)," } ?? "“\(title)”"
                let text: String
                if feedback.liked[anchorFacts.id] != nil { text = "Because you asked for more like \(named)" }
                else if anchorFacts.film.hofPosition > 0 { text = "Because you put \(named) in your Hall of Fame" }
                else if anchorFacts.rating >= 9 { text = "Because you loved \(named)" }
                else { text = "Because you enjoyed \(named)" }
                /// A clause closing the sentence loses its trailing comma.
                let sentence = text.hasSuffix(",") ? String(text.dropLast()) : text
                reasons.append(RecReason(glyph: "link", text: sentence, strength: connection * 1.2))
            }
            var aversion = 0.0
            if let (_, pull) = pulls.negative { aversion = min(1, pull * 1.6) }

            // Rewatch.
            var rewatch = 0.0
            if film.watched {
                if film.userRating > 0 {
                    let z = (Double(film.userRating) - mean) / spread
                    rewatch += 0.5 * clamp(0.5 + 0.25 * z, 0, 1)
                    if film.userRating >= 8 {
                        reasons.append(RecReason(glyph: "star.fill", text: "You rated it \(film.userRating)",
                                                 strength: 0.3 + 0.1 * Double(film.userRating - 8)))
                    }
                } else {
                    rewatch += 0.5 * 0.35
                }
                if let monthsSince {
                    let ratio = monthsSince / Double(max(1, film.rotationThreshold))
                    rewatch += 0.35 * min(1, 0.4 + 0.4 * log2(max(1, ratio)))
                    reasons.append(RecReason(glyph: "clock.arrow.circlepath",
                                             text: "Last watched \(span(months: monthsSince)) ago",
                                             strength: 0.2 + 0.1 * min(3, ratio)))
                    if fact.viewings.count >= 3 {
                        var gaps: [Double] = []
                        for (older, newer) in zip(fact.viewings, fact.viewings.dropFirst()) {
                            gaps.append(Double(calendar.dateComponents([.day], from: older, to: newer).day ?? 0) / 30.44)
                        }
                        let cadence = gaps.sorted()[gaps.count / 2]
                        if cadence >= 1, monthsSince >= cadence * 0.9 {
                            rewatch += 0.25
                            reasons.append(RecReason(glyph: "repeat",
                                                     text: "You come back to it about every \(span(months: cadence))",
                                                     strength: 0.55))
                        }
                    }
                }
                if film.hofPosition > 0 {
                    let rank = hallOfFameRank(film.hofPosition, of: hofCount)
                    rewatch += 0.25 + 0.35 * (1 - rank)
                    reasons.append(RecReason(glyph: "trophy.fill", text: "No. \(film.hofPosition) in your Hall of Fame",
                                             strength: 0.7 + 0.3 * (1 - rank)))
                }
                if fact.viewings.count >= 3 {
                    rewatch += 0.1
                    reasons.append(RecReason(glyph: "eye", text: "You’ve watched it \(fact.viewings.count) times",
                                             strength: 0.25))
                }
            }

            // Shelf.
            var shelf = 0.0
            var isFresh = false
            let daysOwned = fact.added.map { Double(calendar.dateComponents([.day], from: $0, to: today).day ?? 0) }
            if !film.watched {
                if fact.purchased {
                    shelf += 0.55 + (fact.ownsUHD ? 0.15 : 0) + min(0.15, fact.spent / 150)
                    reasons.append(RecReason(glyph: "opticaldisc",
                                             text: fact.ownsUHD ? "You own it on 4K UHD and haven’t watched it yet"
                                                                : "You bought it and haven’t watched it yet",
                                             strength: 0.5))
                }
                if let days = daysOwned {
                    if days <= 45 {
                        isFresh = true
                        shelf += 0.45
                        reasons.append(RecReason(glyph: "shippingbox",
                                                 text: days < 1 ? "Added to your library today"
                                                                : "Added to your library \(span(months: days / 30.44)) ago",
                                                 strength: 0.5))
                    } else if days >= 365 {
                        shelf += min(0.35, 0.1 * days / 365)
                        reasons.append(RecReason(glyph: "hourglass",
                                                 text: "Unwatched in your library for \(span(months: days / 30.44))",
                                                 strength: 0.25 + min(0.25, 0.05 * days / 365)))
                    }
                }
            } else if fact.ownsUHD, let bought = fact.uhdPurchase, let last = fact.lastWatched, bought > last {
                shelf += 0.4
                reasons.append(RecReason(glyph: "4k.tv", text: "You haven’t watched your 4K UHD copy yet",
                                         strength: 0.55))
            }

            // Timing.
            var timing = 0.0
            /// The film's own time of year: past years in which it was watched within two weeks of
            /// today's date (either side, across New Year), weighed by how close each came. A film
            /// watched around the same date in several years, as on a holiday, is offered as that
            /// date comes round. It stands in for the coarser month and this-week signals below,
            /// which say the same thing less precisely.
            let days = viewingDays[factIndex]
            let habit = seasonalHabit(days, todayOrdinal: todayOrdinal, currentYear: currentYear)
            if let habit {
                timing += (0.5 + 0.7 * habit.share) * habit.closeness
                reasons.append(RecReason(glyph: "calendar.badge.clock",
                                         text: "You’ve watched it around this time of year in \(habit.years) of \(habit.ofYears) years",
                                         strength: 0.5 + 0.4 * habit.share))
            }
            let pastSameMonth = habit != nil ? 0 : days.reduce(0) {
                $0 + ($1.month == currentMonth && $1.year < currentYear ? 1 : 0)
            }
            if pastSameMonth >= 2 {
                timing += 0.45
                reasons.append(RecReason(glyph: "calendar",
                                         text: "You’ve watched it in \(monthName) \(pastSameMonth) times",
                                         strength: 0.6))
            }
            var bestLift: (name: String, lift: Double)?
            for feature in fact.features where feature.facet == .genre || feature.facet == .tag {
                guard let entry = stats[feature], entry.viewings >= 8, entry.monthViewings[currentMonth] >= 3 else { continue }
                let share = Double(entry.monthViewings[currentMonth]) / Double(entry.viewings)
                let base = Double(max(1, monthTotals[currentMonth])) / Double(totalViewings)
                let lift = share / base
                if lift >= 1.6, lift > (bestLift?.lift ?? 0), let name = names[feature] {
                    bestLift = (feature.facet == .tag ? "“\(name)”" : name, lift)
                }
            }
            if let bestLift {
                timing += min(0.35, (bestLift.lift - 1) * 0.2)
                reasons.append(RecReason(glyph: "leaf",
                                         text: "You watch more \(bestLift.name) films in \(monthName)",
                                         strength: 0.35))
            }
            if let release = fact.originalRelease,
               let ordinal = calendar.ordinality(of: .day, in: .year, for: release) {
                let distance = min(abs(ordinal - todayOrdinal), 365 - abs(ordinal - todayOrdinal))
                let years = currentYear - calendar.component(.year, from: release)
                if distance <= 3, years >= 1 {
                    let milestone = years >= 10 && years % 5 == 0
                    timing += milestone ? 0.6 : 0.35
                    reasons.append(RecReason(glyph: "birthday.cake",
                                             text: milestone ? "Its \(ordinalText(years)) anniversary is this week"
                                                             : "Released \(Fmt.count(years, "year")) ago this week",
                                             strength: milestone ? 0.9 : 0.5))
                }
            }
            /// From the viewings' calendar days, worked out once per analysis, not per pass.
            if film.watched, habit == nil,
               let memory = days.last(where: {
                   let ordinal = $0.ordinal ?? 0
                   return $0.year < currentYear
                       && min(abs(ordinal - todayOrdinal), 365 - abs(ordinal - todayOrdinal)) <= 3
               }) {
                timing += 0.15
                reasons.append(RecReason(glyph: "clock.badge.checkmark",
                                         text: "You watched it this week in \(memory.year)",
                                         strength: 0.3))
            }

            // Momentum.
            var momentum = 0.0
            switch queueSection {
            case .upNext?:
                momentum += 0.8
                reasons.append(RecReason(glyph: ViewGlyphs.queueUpNext.outline, text: "It’s already in your “Up Next” Queue", strength: 0.4))
            case .soon?:
                momentum += 0.6
                reasons.append(RecReason(glyph: ViewGlyphs.queueSoon.outline, text: "It’s already in your “Soon” Queue", strength: 0.5))
            case .later?:
                momentum += 0.35
                reasons.append(RecReason(glyph: ViewGlyphs.queueLater.outline, text: "It’s already in your “Later” Queue", strength: 0.35))
            case nil:
                break
            }
            if fact.wishlisted {
                momentum += 0.3
                reasons.append(RecReason(glyph: "gift", text: "A release of it is on your wishlist", strength: 0.3))
            }
            if feedback.liked[film.id] != nil {
                momentum += 0.4
                reasons.append(RecReason(glyph: "hand.thumbsup", text: "You asked for more like this", strength: 0.45))
            }
            if let streak, fact.features.contains(streak.key), let name = names[streak.key] {
                momentum += 0.3
                let label = streak.key.facet == .tag ? "“\(name)”" : name
                reasons.append(RecReason(glyph: "flame", text: "Keeps your \(label) streak going", strength: 0.55))
            }

            // Steering.
            var steer = 0.0
            if !steerFeatures.isEmpty {
                let matches = fact.features.filter { steerFeatures.contains($0) }
                if matches.isEmpty {
                    steer = -1
                } else {
                    steer = 0.8 * Double(matches.count)
                    let label = matches.compactMap { names[$0] }.prefix(2).joined(separator: ", ")
                    reasons.append(RecReason(glyph: "scope", text: "Matches your steer: \(label)", strength: 1.0))
                }
            }


            let jitter = (unit(film.id, input.seed, salt: 1) - 0.5) * 0.15
            let contributions: [(RecLane, Double)] = [
                (.match, weights.taste * 0.9 * max(0, taste)),
                (.connection, weights.connections * 1.2 * connection),
                (.rewatch, weights.rewatch * rewatch),
                (isFresh ? .fresh : .shelf, weights.shelf * shelf),
                (.timely, weights.timing * timing),
                (.queue, weights.momentum * momentum),
                (.steer, max(0, steer)),
            ]
            let score = weights.taste * 0.9 * taste + weights.connections * 1.2 * connection
                - weights.taste * 0.8 * aversion
                + weights.rewatch * rewatch + weights.shelf * shelf + weights.timing * timing
                + weights.momentum * momentum + steer + jitter
                - (input.shuffledAway.contains(film.id) ? 0.9 : 0)
            let lane = contributions.max { $0.1 < $1.1 }.map { $0.1 > 0.05 ? $0.0 : .match } ?? .match

            let ownBoost = film.userRating > 0 ? 0.15 * clamp((Double(film.userRating) - mean) / spread, -1, 1.5) : 0
            let match = Int(clamp(50 + 49 * tanh(1.6 * (0.9 * taste + 1.1 * connection - 0.6 * aversion + ownBoost)), 20, 99).rounded())

            candidates.append(Candidate(
                factsIndex: factIndex,
                score: score, taste: taste, aversion: aversion, novelty: novelty,
                lane: lane, match: match, reasons: reasons, queueSection: queueSection))
        }
        // 7. Selection
        let ranked = candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.factsIndex < $1.factsIndex }
        let wildcardCount = tuning.wildcardCount
        let mainCount = max(1, tuning.pickCount - wildcardCount)
        let pool = Array(ranked.prefix(max(150, mainCount * 8)))
        var chosen: [Candidate] = []
        var chosenIDs = Set<UUID>()
        func factsOf(_ candidate: Candidate) -> Facts { facts[candidate.factsIndex] }
        /// In Balanced focus neither unwatched nor watched films may take more than 60% of the picks,
        /// as long as the pool holds both. Steering lifts the cap: the steer is the user's intent.
        let watchedCap = Int((Double(mainCount) * 0.6).rounded(.up))
        let poolHasBoth = pool.contains { factsOf($0).film.watched } && pool.contains { !factsOf($0).film.watched }
        /// Each candidate's greatest similarity to the picks so far (0 before any), raised as each
        /// pick is made: one cosine per candidate per pick, not one per pick already made.
        func raise(_ similarity: inout [Double], of candidates: [Candidate], toward picked: Candidate) {
            let pickedFacts = factsOf(picked)
            for index in candidates.indices where !chosenIDs.contains(factsOf(candidates[index]).id) {
                similarity[index] = max(similarity[index], cosine(factsOf(candidates[index]), pickedFacts))
            }
        }

        var poolSimilarity = [Double](repeating: 0, count: pool.count)
        var watchedChosen = 0
        func bestNext(capped: Bool) -> Int? {
            let unwatchedChosen = chosen.count - watchedChosen
            var best: (index: Int, value: Double)?
            for (index, candidate) in pool.enumerated() where !chosenIDs.contains(factsOf(candidate).id) {
                if capped {
                    let watched = factsOf(candidate).film.watched
                    if watched, watchedChosen >= watchedCap { continue }
                    if !watched, unwatchedChosen >= watchedCap { continue }
                }
                let value = candidate.score - tuning.variety * 1.2 * poolSimilarity[index]
                if value > (best?.value ?? -.infinity) { best = (index, value) }
            }
            return best?.index
        }
        while chosen.count < mainCount {
            /// The cap yields once one side runs out, so the picks are never cut short.
            let capped = tuning.focus == .balanced && poolHasBoth && steerFeatures.isEmpty
            guard let index = bestNext(capped: capped) ?? (capped ? bestNext(capped: false) : nil) else { break }
            let best = pool[index]
            chosen.append(best)
            chosenIDs.insert(factsOf(best).id)
            if factsOf(best).film.watched { watchedChosen += 1 }
            if chosen.count < mainCount { raise(&poolSimilarity, of: pool, toward: best) }
        }

        var wild: [Candidate] = []
        if wildcardCount > 0 {
            let streakFeature = streak?.key
            let wildPool = candidates.filter { candidate in
                /// Unfamiliar, not unwanted: a fair taste fit and a positive score, and never the
                /// current streak, which is the opposite of a change of pace.
                let features = factsOf(candidate).features
                return !chosenIDs.contains(factsOf(candidate).id) && candidate.taste > -0.2 && candidate.aversion < 0.35
                    && candidate.match >= 50 && candidate.score > 0 && candidate.novelty >= 0.25
                    && !(streakFeature.map { features.contains($0) } ?? false)
            }
            /// The part of each wildcard's value that does not depend on the picks made, worked out once.
            let wildBase = wildPool.map { candidate -> Double in
                let fact = factsOf(candidate)
                let quality: Double
                if fact.rating > 0 { quality = clamp((Double(fact.rating) - mean) / spread * 0.25 + 0.5, 0, 1) }
                else { quality = fact.purchased ? 0.55 : 0.3 }
                return 0.55 * candidate.novelty + 0.25 * quality + 0.2 * max(0, candidate.taste)
                    + 0.35 * unit(fact.id, input.seed, salt: 2)
            }
            /// Similarity to the main picks, then raised by each wildcard as it is chosen.
            var wildSimilarity = [Double](repeating: 0, count: wildPool.count)
            for picked in chosen { raise(&wildSimilarity, of: wildPool, toward: picked) }
            while wild.count < wildcardCount {
                var best: (index: Int, value: Double)?
                for (index, candidate) in wildPool.enumerated() where !chosenIDs.contains(factsOf(candidate).id) {
                    let value = wildBase[index] - 0.5 * wildSimilarity[index]
                    if value > (best?.value ?? -.infinity) { best = (index, value) }
                }
                guard let best else { break }
                let picked = wildPool[best.index]
                wild.append(picked)
                chosenIDs.insert(factsOf(picked).id)
                if wild.count < wildcardCount { raise(&wildSimilarity, of: wildPool, toward: picked) }
            }
        }

        func makePick(_ candidate: Candidate, wildcard: Bool = false) -> RecPick {
            let fact = factsOf(candidate)
            let film = fact.film
            var reasons = candidate.reasons.sorted { $0.strength > $1.strength }
            if wildcard {
                let order: [RecFeature.Facet] = [.decade, .genre, .director, .tag, .writer, .cast]
                /// A writer-director is named once.
                var named = Set<String>()
                let novel = fact.features
                    .filter { noveltyFacets.contains($0.facet) && recentDiet[$0] == nil }
                    .sorted { (order.firstIndex(of: $0.facet) ?? 9) < (order.firstIndex(of: $1.facet) ?? 9) }
                    .compactMap { feature in names[feature].map { feature.facet == .tag ? "“\($0)”" : $0 } }
                    .filter { named.insert(RecFeature.fold($0)).inserted }
                    .prefix(3)
                let text = novel.isEmpty ? "A change of pace from what you usually reach for"
                                         : "Nothing like it in your past year: " + serialList(Array(novel))
                reasons.insert(RecReason(glyph: "dice", text: text, strength: 2), at: 0)
            }
            var seen = Set<String>()
            reasons = reasons.filter { seen.insert($0.text).inserted }
            let byline = film.directors.isEmpty ? "" : "Directed by " + film.directors.prefix(2).joined(separator: " & ")
            return RecPick(
                id: film.id, name: film.name, year: film.releaseYear, posterUID: film.posterUID,
                runtimeMinutes: fact.runtime, byline: byline, certification: film.rating, genre: film.genre,
                synopsis: film.descriptionText, userRating: film.userRating,
                queueSection: candidate.queueSection,
                lane: wildcard ? .wildcard : candidate.lane, match: candidate.match, score: candidate.score,
                reasons: Array(reasons.prefix(4)))
        }

        let mainPicks = chosen.map { makePick($0) }
        let hero = mainPicks.first
        let picks = Array(mainPicks.dropFirst())
        let wildcards = wild.map { makePick($0, wildcard: true) }

        // 8. Double feature: two more strong candidates, tied by a person, tag or list.
        var doubleFeature: RecDoubleFeature?
        if tuning.showDoubleFeature {
            let shortlist = ranked.filter { candidate in
                candidate.score > 0 && !chosenIDs.contains(factsOf(candidate).id)
                    && (steerFeatures.isEmpty || factsOf(candidate).features.contains { steerFeatures.contains($0) })
            }.prefix(60)
            var best: (Candidate, Candidate, Double, RecFeature)?
            for (i, a) in shortlist.enumerated() {
                let factA = factsOf(a)
                for b in shortlist.dropFirst(i + 1) {
                    let factB = factsOf(b)
                    if let ra = factA.runtime, let rb = factB.runtime, ra + rb > 280 { continue }
                    guard let link = strongestSharedFeature(factA, factB, idf: idf) else { continue }
                    let value = a.score + b.score + 2 * cosine(factA, factB)
                    if value > (best?.2 ?? -.infinity) { best = (a, b, value, link) }
                }
            }
            if let (a, b, _, link) = best, let name = names[link] {
                let (first, second) = (factsOf(a).year ?? 0) <= (factsOf(b).year ?? 0) ? (a, b) : (b, a)
                let total: Int? = {
                    guard let x = factsOf(first).runtime, let y = factsOf(second).runtime else { return nil }
                    return x + y
                }()
                doubleFeature = RecDoubleFeature(first: makePick(first), second: makePick(second),
                                                 link: pairText(link, name: name), linkGlyph: link.facet.glyph,
                                                 totalMinutes: total)
            }
        }

        // 9. Profile, steering options, statistics
        let profileFacets: [RecFeature.Facet] = [.director, .writer, .cast, .composer, .genre, .decade, .tag, .studio]
        var groups: [RecProfile.Group] = []
        var everything: [RecProfile.Entry] = []
        for facet in profileFacets {
            let minimum = confidentFilms
            let entries = stats
                .filter { $0.key.facet == facet && ($0.value.labeled >= minimum || rated[$0.key] != nil) }
                .map { feature, entry in
                    RecProfile.Entry(feature: feature, name: names[feature] ?? feature.key,
                                     affinity: affinity(feature, excluding: nil).value, count: entry.labeled,
                                     averageRating: entry.rated > 0 ? Double(entry.ratingSum) / Double(entry.rated) : nil,
                                     userLean: rated[feature]?.lean)
                }
            everything += entries
            let top = entries.filter { $0.affinity > 0.05 }
                .sorted { $0.affinity != $1.affinity ? $0.affinity > $1.affinity : $0.name < $1.name }
                .prefix(6)
            if !top.isEmpty { groups.append(RecProfile.Group(facet: facet, entries: Array(top))) }
        }
        let dislikes = Array(everything.filter { $0.affinity < -0.1 }
            .sorted { $0.affinity != $1.affinity ? $0.affinity < $1.affinity : $0.name < $1.name }
            .prefix(6))

        let steerFacets: [RecFeature.Facet] = [.director, .cast, .writer, .genre, .decade, .tag]
        var steerCounts: [RecFeature: Int] = [:]
        for candidate in candidates {
            for feature in factsOf(candidate).features
            where steerFacets.contains(feature.facet) {
                steerCounts[feature, default: 0] += 1
            }
        }
        for steer in tuning.steer where steerCounts[steer.feature] == nil { steerCounts[steer.feature] = 0 }
        let steerGroups: [RecSteerGroup] = steerFacets.compactMap { facet in
            let options = steerCounts
                .filter { $0.key.facet == facet && ($0.value >= 2 || steerFeatures.contains($0.key)) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : (names[$0.key] ?? "") < (names[$1.key] ?? "") }
                .prefix(10)
                .map { RecSteer(feature: $0.key, name: names[$0.key] ?? $0.key.key) }
            return options.isEmpty ? nil : RecSteerGroup(facet: facet, options: Array(options))
        }

        let streakText = streak.flatMap { entry in
            names[entry.key].map { name in
                let label = entry.key.facet == .tag ? "“\(name)”" : name
                return "\(label): \(Fmt.count(entry.value, "film")) watched in the last 60 days"
            }
        }
        let summary = RecStats(
            filmCount: facts.count, ratedCount: ratedFilmCount, viewingCount: viewingCount,
            meanRating: mean, hallOfFameCount: hofCount,
            labeledCount: facts.reduce(0) { $0 + ($1.w > 0 ? 1 : 0) },
            eligibleCount: candidates.count,
            exclusions: exclusions.map { RecStats.Exclusion(label: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label },
            streak: streakText)

        return RecResult(
            hero: hero, picks: picks, wildcards: wildcards, doubleFeature: doubleFeature,
            profile: RecProfile(groups: groups, dislikes: dislikes), stats: summary,
            steerGroups: steerGroups, newHits: newHits, newCooldowns: newCooldowns, watchedSinceOffered: watchedSinceOffered,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000), analysis: analysis)
    }

    // MARK: Candidate

    private struct Candidate {
        let factsIndex: Int
        let score: Double
        let taste: Double
        let aversion: Double
        /// 0…1: how much of the film is absent from the last year's viewing.
        let novelty: Double
        let lane: RecLane
        let match: Int
        let reasons: [RecReason]
        let queueSection: FilmQueueSection?
    }

    // MARK: Seasonal Habit

    /// A film's habit of being watched around this date: among the past years it was watched in,
    /// those with a viewing within `habitWindowDays` of today's day of the year. At least two such
    /// years, and at least a third of the years it was watched in, make a habit; `closeness` is
    /// 1 on the day and falls to 0 at the window's edge (the best viewing in each year counts).
    static let habitWindowDays = 14

    static func seasonalHabit(_ viewings: [Date], calendar: Calendar, todayOrdinal: Int,
                              currentYear: Int) -> (years: Int, ofYears: Int, share: Double, closeness: Double)? {
        seasonalHabit(viewings.map { ViewingDay($0, calendar: calendar) },
                      todayOrdinal: todayOrdinal, currentYear: currentYear)
    }

    static func seasonalHabit(_ days: [ViewingDay], todayOrdinal: Int,
                              currentYear: Int) -> (years: Int, ofYears: Int, share: Double, closeness: Double)? {
        var watchedYears = Set<Int>()
        var bestByYear: [Int: Double] = [:]
        for day in days {
            let year = day.year
            guard year < currentYear, let ordinal = day.ordinal else { continue }
            watchedYears.insert(year)
            let distance = min(abs(ordinal - todayOrdinal), 365 - abs(ordinal - todayOrdinal))
            guard distance <= habitWindowDays else { continue }
            let closeness = 1 - Double(distance) / Double(habitWindowDays + 1)
            bestByYear[year] = max(bestByYear[year] ?? 0, closeness)
        }
        let years = bestByYear.count
        guard years >= 2, years * 3 >= watchedYears.count else { return nil }
        let closeness = bestByYear.values.reduce(0, +) / Double(years)
        return (years, watchedYears.count, Double(years) / Double(watchedYears.count), closeness)
    }

    // MARK: Text

    private static func tasteText(_ feature: RecFeature, name: String, stats: FeatureStats?,
                                  userLean: Int?) -> String {
        let average = stats.flatMap { $0.rated >= 2 ? Double($0.ratingSum) / Double($0.rated) : nil }
        let rated: String
        if let userLean {
            /// "Stars Tom Hanks, whom you like": "whom", as the object of "like".
            let isPerson = [.director, .writer, .cast, .composer, .producer].contains(feature.facet)
            let verb = userLean > 0 ? "like" : "dislike"
            rated = isPerson ? ", whom you \(verb)" : " (you \(verb) it)"
        }
        else { rated = average.map { " (Average: \(Fmt.fixed($0, 1)))" } ?? "" }
        switch feature.facet {
        case .director:      return "Directed by \(name)\(rated)"
        case .writer:        return "Written by \(name)\(rated)"
        case .cast:          return "Stars \(name)\(rated)"
        case .composer:      return "Score by \(name)\(rated)"
        case .producer:      return "Produced by \(name)\(rated)"
        case .studio:        return "From \(name)\(rated)"
        case .genre:         return "\(name) is one of your strongest genres\(rated)"
        case .decade:        return "You favor films from the \(name)\(rated)"
        case .certification: return "Rated \(name), which suits you\(rated)"
        case .length:        return "\(name), a length you rate highly\(rated)"
        case .tag:           return "Tagged “\(name)”\(rated)"
        case .list:          return "On your “\(name)” list\(rated)"
        }
    }

    /// "A", "A and B", "A, B, and C".
    static func serialList(_ items: [String]) -> String {
        switch items.count {
        case 0, 1: return items.first ?? ""
        case 2:    return "\(items[0]) and \(items[1])"
        default:   return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }

    private static func pairText(_ feature: RecFeature, name: String) -> String {
        switch feature.facet {
        case .director:      return "Both directed by \(name)"
        case .writer:        return "Both written by \(name)"
        case .cast:          return "Both star \(name)"
        case .composer:      return "Both scored by \(name)"
        case .producer:      return "Both produced by \(name)"
        case .tag:           return "Both tagged “\(name)”"
        case .list:          return "Both on your “\(name)” list"
        case .studio, .genre, .decade, .certification, .length: return "Both \(name)"
        }
    }

    /// The most telling connective feature two films share, phrased for a reason line.
    private static func strongestShared(_ a: Facts, _ b: Facts, names: [RecFeature: String]) -> String? {
        let shared = a.features.filter { $0.facet.isConnective && b.vector[$0] != nil }
        guard let best = shared.max(by: { (a.vector[$0] ?? 0) < (a.vector[$1] ?? 0) }),
              let name = names[best] else { return nil }
        switch best.facet {
        case .director: return "is also directed by \(name)"
        case .writer:   return "is also written by \(name)"
        case .cast:     return "also stars \(name)"
        case .composer: return "is also scored by \(name)"
        case .producer: return "is also produced by \(name)"
        case .tag:      return "is also tagged “\(name)”"
        case .list:     return "is also on “\(name)”"
        case .studio, .genre, .decade, .certification, .length: return nil
        }
    }

    private static func strongestSharedFeature(_ a: Facts, _ b: Facts,
                                               idf: (RecFeature) -> Double) -> RecFeature? {
        a.features
            .filter { $0.facet.isConnective && b.vector[$0] != nil }
            .max { $0.facet.weight * idf($0) < $1.facet.weight * idf($1) }
    }

    /// "8 days", "5 months", "3 years".
    static func span(months: Double) -> String {
        if months < 1.5 { return Fmt.count(max(1, Int((months * 30.44).rounded())), "day") }
        if months < 24 { return Fmt.count(Int(months.rounded()), "month") }
        return Fmt.count(Int((months / 12).rounded()), "year")
    }

    private static func ordinalText(_ value: Int) -> String {
        let tens = value % 100
        let suffix: String
        if (11...13).contains(tens) { suffix = "th" }
        else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }

    // MARK: Math

    /// 0 for the top of the Hall of Fame, 1 for the bottom. Clamped: a restored backup can leave
    /// positions gapped or duplicated, so a position can exceed the count.
    private static func hallOfFameRank(_ position: Int, of count: Int) -> Double {
        guard count > 1 else { return 0 }
        return clamp(Double(position - 1) / Double(count - 1), 0, 1)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }

    /// A stable 0…1 value per film and seed: the same picks all day, new ones on Shuffle.
    static func unit(_ id: UUID, _ seed: UInt64, salt: UInt64) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed ^ (salt &* 0x9E37_79B9_7F4A_7C15)
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        hash ^= hash >> 33
        hash = hash &* 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        hash = hash &* 0xC4CE_B9FE_1A85_EC53
        hash ^= hash >> 33
        return Double(hash >> 11) / Double(UInt64(1) << 53)
    }
}
