// MARK: - SearchSuggestions.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The search field's value suggestions: the library vocabulary they draw on, the learned
/// heuristics that rank them, and the ranking itself. All of it runs off the main actor;
/// SearchController only asks for a ranked list and publishes it.

import Foundation

// MARK: - Suggestion

/// One value row in the search field's drop-down.
struct SearchSuggestion: Hashable, Sendable {
    /// The token field the value is for, or nil for freeform text (a title).
    let field: SearchField?
    /// The value as it is inserted and shown.
    let value: String
    /// The secondary prefix shown before the value ("Smart List: "), or "".
    let prefix: String
}

/// The most rows the drop-down shows at once, across every kind of suggestion.
nonisolated enum SearchSuggestionLimits {
    static let menuRows = 30
    static let recentSearches = 10
}

// MARK: - Vocabulary

/// Everything in the library a suggestion can offer, and what the library says about how
/// the user relates to it. Built off the main actor from one copy of the films map;
/// immutable once built.
///
/// Two library-derived signals come out of the build, beside the plain value counts:
///
/// • Film affinity — how likely the user is to be looking for a film right now, from what
///   they have entered about it (see `FilmSignals.affinity`).
/// • Taste — per value, how much the films carrying it matter to the user: the affinity
///   of its films, summed and damped by the square root of their count, so a director of
///   five much-loved films outranks one of fifty never-watched ones, and both outrank a
///   name on a single forgotten film. Normalized per field to 0...1.
///
/// Each value also keeps the films that carry it (its postings), which is what lets the
/// ranker relate a candidate to the search already in progress (see SearchContext).
nonisolated struct SearchVocabulary: Sendable {
    struct Term: Sendable {
        let display: String
        let key: String
        /// The first letters of the value's words ("tdk" for "The Dark Knight").
        let initials: String
        /// How many films carry the value.
        let count: Int
        /// 0...1, see the type's doc comment.
        let taste: Double
        /// Indices into `affinity` of the films that carry the value.
        let films: [Int32]
    }

    private(set) var terms: [SearchField: [Term]] = [:]
    /// Field → value key → index in `terms[field]`, for resolving context values.
    private(set) var termIndex: [SearchField: [String: Int]] = [:]
    /// Per film, in the order postings index them.
    private(set) var affinity: [Double] = []
    /// Per film: its title key, for resolving freeform context text.
    private(set) var titleKeys: [String] = []
    /// Per film: in the Queue. Read when the search starts from the Queue (SearchFocus).
    private(set) var queued: [Bool] = []
    /// Per film: a release due within the year ahead, or one on the wishlist. Read when the
    /// search starts from a release smart list (SearchFocus).
    private(set) var releaseInterest: [Bool] = []
    /// Per film, 0...1: how much more the user watches the film's genres in this month than
    /// in an average one, from the whole library's viewing calendar (see `seasonalLift`).
    private(set) var seasonal: [Double] = []

    static let empty = SearchVocabulary()

    /// Nothing built yet: the empty vocabulary, before the first build.
    var isEmpty: Bool { titleKeys.isEmpty && terms.isEmpty }

    /// The fields whose values come from the films themselves, so taste and context apply.
    static let libraryFields: Set<SearchField> = [
        .title, .cast, .directors, .producer, .executiveProducer, .screenwriter, .composer,
        .crew, .studio, .source, .tags, .genre,
    ]

    /// Fixed keyword vocabularies for the fields whose values are not library text.
    private static let keywordTerms: [SearchField: [String]] = [
        .releases: ["upcoming", "purchased", "unpurchased", "wishlist", "4k", "native 4k",
                    "upscaled", "blu-ray", "dvd", "imported", "remastered", "hdr",
                    "dolby vision", "hdr10", "hdr10+", "combo-pack", "standalone", "multi-pack",
                    "available", "out of print", "temporarily unavailable", "unavailable",
                    "cheap", "reasonable", "exorbitant"],
        .rotationThreshold: RuleValues.rotationValues,
        .lastWatched: ["today", "this week", "this month", "this year"],
        .dateAdded: ["today", "this week", "this month", "this year"],
        .flags: FilmFlag.terms.map(\.display),
        .source: ["none"],
    ]

    init() {}

    init(films: [UUID: FilmSnapshot], queued: Set<UUID>, today: Date) {
        /// One value's films and spellings. A film is counted once however many spellings of the
        /// value it carries, and the value is shown in its most-used spelling (ties go to the
        /// alphabetically first), as the sidebar's Tags and ValueSuggestions show theirs: the
        /// first spelling met depended on the films dictionary's order, which varies by launch.
        struct Accumulator {
            /// The first spelling met, and the films it was met on.
            let first: String
            var firstUses = 0
            /// Every other spelling's films; nil until a second spelling appears, which is rare.
            var others: [String: Int]?
            let key: String
            var films: [Int32] = []

            init(display: String, key: String) {
                first = display
                self.key = key
            }

            mutating func add(_ spelling: String, film: Int32?) {
                guard let film else { return }
                /// A film's values are all added before the next film's, so a repeat is the last.
                guard films.last != film else { return }
                films.append(film)
                if spelling == first {
                    firstUses += 1
                } else {
                    if others == nil { others = [:] }
                    others?[spelling, default: 0] += 1
                }
            }

            var display: String {
                guard let others else { return first }
                var best = first, bestUses = firstUses
                for (spelling, uses) in others where uses > bestUses || (uses == bestUses && spelling < best) {
                    best = spelling
                    bestUses = uses
                }
                return best
            }
        }
        /// Field → slot → value. A library value's slot is its key, so spellings that
        /// normalize alike ("Amélie", "amelie") are one value. A keyword's slot is its own
        /// spelling: two keywords can share a key and still mean different things ("hdr10"
        /// takes HDR10+ too, "hdr10+" only it), and one slot would keep only the first.
        var byField: [SearchField: [String: Accumulator]] = [:]
        func add(_ value: String, to field: SearchField, film: Int32?, keyword: Bool = false) {
            let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { return }
            let key = SearchText.key(display)
            guard !key.isEmpty else { return }
            byField[field, default: [:]][keyword ? display : key, default: Accumulator(display: display, key: key)]
                .add(display, film: film)
        }
        let people: [(SearchField, KeyPath<FilmSnapshot, [String]>)] = [
            (.cast, \.cast), (.directors, \.directors), (.producer, \.producers),
            (.executiveProducer, \.executiveProducers), (.screenwriter, \.screenwriters),
            (.composer, \.composer),
        ]
        var affinity: [Double] = []
        var titleKeys: [String] = []
        var queuedFlags: [Bool] = []
        var releaseInterest: [Bool] = []
        /// Per film, its genre keys; per genre key, its viewings by month (1...12).
        var filmGenres: [[String]] = []
        var genreMonths: [String: [Int]] = [:]
        affinity.reserveCapacity(films.count)
        titleKeys.reserveCapacity(films.count)
        for film in films.values {
            if Task.isCancelled { return }
            let index = Int32(affinity.count)
            let isQueued = queued.contains(film.id)
            let signals = FilmSignals(film, queued: isQueued, today: today)
            affinity.append(signals.affinity)
            queuedFlags.append(isQueued)
            releaseInterest.append(signals.releaseInterest)
            titleKeys.append(SearchText.key(film.name))
            /// Viewing dates are stored "yyyy.MM.dd"; the month is read straight from them.
            let genreKeys = Array(Set(film.genre.split(whereSeparator: { $0 == "," || $0 == "/" })
                .map { SearchText.key($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }))
            filmGenres.append(genreKeys)
            if !genreKeys.isEmpty {
                for entry in film.calendarTable {
                    let parts = entry.split(separator: ".")
                    guard parts.count >= 2, let month = Int(parts[1]), (1...12).contains(month) else { continue }
                    for genre in genreKeys { genreMonths[genre, default: Array(repeating: 0, count: 13)][month] += 1 }
                }
            }
            add(film.name, to: .title, film: index)
            for (field, path) in people {
                /// A person credited twice on one film still counts once for it.
                for name in Set(film[keyPath: path]) {
                    add(name, to: field, film: index)
                }
            }
            /// Crew is the union of the six, so a person in two roles counts once here too.
            for name in Set(people.flatMap { film[keyPath: $0.1] }) { add(name, to: .crew, film: index) }
            for studio in Set(film.studio) { add(studio, to: .studio, film: index) }
            for tag in Set(film.tags) { add(tag, to: .tags, film: index) }
            add(film.digitalSource, to: .source, film: index)
            /// Genre is one string that may hold several, comma- or slash-separated.
            for genre in Set(film.genre.split(whereSeparator: { $0 == "," || $0 == "/" })) {
                add(String(genre), to: .genre, film: index)
            }
        }
        for (field, words) in Self.keywordTerms {
            for word in words { add(word, to: field, film: nil, keyword: true) }
        }
        for (field, bySlot) in byField {
            var built: [Term] = bySlot.values.map { acc in
                /// Damped by √count: see the type's doc comment.
                let sum = acc.films.reduce(0.0) { $0 + affinity[Int($1)] }
                let taste = acc.films.isEmpty ? 0 : sum / Double(acc.films.count).squareRoot()
                return Term(display: acc.display, key: acc.key, initials: Self.initials(of: acc.key),
                            count: acc.films.count, taste: taste, films: acc.films)
            }
            let maxTaste = built.map(\.taste).max() ?? 0
            if maxTaste > 0 {
                built = built.map {
                    Term(display: $0.display, key: $0.key, initials: $0.initials, count: $0.count,
                         taste: $0.taste / maxTaste, films: $0.films)
                }
            }
            terms[field] = built
            /// Two keywords can share a key (see `byField`); either resolves a context value,
            /// since keywords carry no films.
            termIndex[field] = Dictionary(built.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
        self.affinity = affinity
        self.titleKeys = titleKeys
        self.queued = queuedFlags
        self.releaseInterest = releaseInterest
        let month = StorageDateFormatters.calendar.component(.month, from: today)
        let lift = genreMonths.mapValues { Self.seasonalLift($0, month: month) }
        self.seasonal = filmGenres.map { genres in genres.map { lift[$0] ?? 0 }.max() ?? 0 }
    }

    /// How much more a genre is watched in `month` than in an average month, 0...1, from its
    /// viewings by month (index 1...12). The month itself counts in full and its neighbors
    /// at half, so a habit that straddles two months still registers. A genre needs a dozen
    /// viewings before it says anything; twice the average month or more is full marks.
    static func seasonalLift(_ byMonth: [Int], month: Int) -> Double {
        let total = byMonth.reduce(0, +)
        guard total >= 12 else { return 0 }
        let previous = month == 1 ? 12 : month - 1
        let next = month == 12 ? 1 : month + 1
        let near = Double(byMonth[month]) + 0.5 * Double(byMonth[previous] + byMonth[next])
        /// The window spans two months' worth of weight.
        let ratio = near / (2 * Double(total) / 12)
        return min(1, max(0, ratio - 1))
    }

    static func initials(of key: String) -> String {
        String(key.split(separator: " ").compactMap(\.first))
    }
}

// MARK: - Film Signals

/// What the library records about one film that says how likely the user is to be
/// looking for it, folded into one affinity score.
///
/// Every component is scaled to 0...1 and weighted; the weights sum to a little over 1,
/// and no single habit can carry a film on its own. The parts, heaviest first:
///
/// • Coming soon (0.35): a release dated within the year ahead, decaying with a 30-day
///   half-life, so next week's disc is near the top and next spring's barely registers.
///   Wishlisted releases count in full, others at 70%. A release known only by its year
///   adds a little.
/// • Rating (0.25): the user's own 0–10 rating. An unrated film reads as a middling 4, so
///   rating a film low still marks it down against one never rated.
/// • Recently watched (0.15): the last viewing, decaying with a 90-day half-life.
/// • Rewatched (0.15): viewings in the past year (4 or more is full marks), with the
///   all-time view count as a smaller part, so a habit outweighs a single old binge.
/// • Hall of Fame (0.10): any ranked position, the top ranks a little more.
/// • In the Queue (0.10): the user has said they mean to watch it.
/// • Recently added (0.10): the film's added date, decaying with a 30-day half-life.
/// • Recently edited (0.10): the film's last modification, decaying with a 14-day
///   half-life — a film just worked on is likely to be looked for again.
/// • Wishlisted (0.05): any top-level release on the wishlist.
nonisolated struct FilmSignals {
    let affinity: Double
    /// A release due within the year ahead, or any top-level release on the wishlist.
    let releaseInterest: Bool

    init(_ film: FilmSnapshot, queued: Bool, today: Date) {
        func decay(daysSince days: Double, halfLife: Double) -> Double {
            days < 0 ? 0 : pow(0.5, days / halfLife)
        }
        func daysBetween(_ date: Date?, _ later: Date) -> Double? {
            date.map { later.timeIntervalSince($0) / 86_400 }
        }

        var comingSoon = 0.0
        for release in film.releases where release.isTopLevel {
            guard let value = ReleaseDateValue(release.releaseDate, format: release.format),
                  value.isUpcoming(today: today) else { continue }
            let share = release.wishlist > 0 ? 1.0 : 0.7
            if let day = value.day, let ahead = daysBetween(today, day), ahead <= 365 {
                comingSoon = max(comingSoon, share * decay(daysSince: ahead, halfLife: 30))
            } else {
                comingSoon = max(comingSoon, share * 0.1)
            }
        }

        let rating = film.userRating > 0 ? Double(min(film.userRating, 10)) / 10 : 0.4

        let watchedDaysAgo = daysBetween(parseDate(from: film.lastWatched), today)
        let recentlyWatched = watchedDaysAgo.map { decay(daysSince: $0, halfLife: 90) } ?? 0

        /// Viewing dates are stored "yyyy.MM.dd"; the year is read first so only the last two
        /// years' entries pay for a full date parse.
        let thisYear = StorageDateFormatters.calendar.component(.year, from: today)
        let viewingsThisYear = film.calendarTable.reduce(0) { count, entry in
            if let year = Int(entry.prefix(4)), year < thisYear - 1 { return count }
            guard let days = daysBetween(parseDate(from: entry), today), days >= 0, days <= 365
            else { return count }
            return count + 1
        }
        let rewatched = 0.7 * min(1, Double(viewingsThisYear) / 4)
            + 0.3 * min(1, log1p(Double(max(0, film.viewCount))) / log1p(10))

        let hallOfFame = film.hofPosition > 0 ? (film.hofPosition <= 10 ? 1 : 0.7) : 0

        let addedDaysAgo = daysBetween(parseDate(from: film.dateAdded), today)
        let recentlyAdded = addedDaysAgo.map { decay(daysSince: $0, halfLife: 30) } ?? 0

        let wishlisted = film.releases.contains { $0.wishlist > 0 && $0.isTopLevel } ? 1.0 : 0

        let editedDaysAgo = daysBetween(parseDate(from: film.lastModified), today)
        let recentlyEdited = editedDaysAgo.map { decay(daysSince: $0, halfLife: 14) } ?? 0

        releaseInterest = comingSoon > 0 || wishlisted > 0
        affinity = 0.35 * comingSoon + 0.25 * rating + 0.15 * recentlyWatched
            + 0.15 * rewatched + 0.10 * hallOfFame + 0.10 * (queued ? 1 : 0)
            + 0.10 * recentlyAdded + 0.10 * recentlyEdited + 0.05 * wishlisted
    }
}

// MARK: - Heuristics

/// A small store of what the user searches for and opens, weighted by how often and how
/// recently, in three parts:
///
/// • Use, per scope (a token field's raw value; titles share `SearchField.title`'s): each
///   record adds its amount to a value's weight. Freeform text is never recorded as typed —
///   a search left at "man on fir" says nothing — only the film it led to.
/// • Input history, per scope: what was typed when a value was picked or a film opened
///   ("ma" → The Matrix). Typing that again, or anything it starts with, brings the value
///   up first. The closest thing to a typed shortcut, learned from use.
/// • Skips, per scope: rows shown above the one picked. A row passed over again and again
///   sinks a little; picking it clears its skips.
///
/// Weights halve every `halfLifeDays`, so habits that stop fade on their own. Each part is
/// bounded and saved as one small JSON file, written at most once per `saveDelay` and never
/// on the main actor.
actor SearchHeuristics {
    static let shared = SearchHeuristics()

    struct Entry: Codable, Sendable {
        var display: String
        var weight: Double
        var updated: Date

        func weight(at date: Date) -> Double {
            let days = max(0, date.timeIntervalSince(updated) / 86_400)
            return weight * pow(0.5, days / SearchHeuristics.halfLifeDays)
        }
    }

    /// What the ranker learns from, for one request.
    struct Learned: Sendable {
        /// Value key → its display and use weight.
        var use: [String: (display: String, weight: Double)] = [:]
        /// Value key → the summed weight of every past input related to what is typed.
        var inputs: [String: Double] = [:]
        /// Value key → how often it was passed over, decayed.
        var skips: [String: Double] = [:]
    }

    /// The scope freeform searches and `#title` share: both name films by title.
    static let titleScope = SearchField.title.rawValue
    static let halfLifeDays = 30.0
    private static let maxEntriesPerScope = 200
    private static let maxInputsPerScope = 300
    private static let maxValuesPerInput = 8
    private static let minimumWeight = 0.05
    private static let saveDelay: Duration = .seconds(5)
    private static let skipPrefix = "skip:"

    /// scope → value key → entry. Skips live here too, under "skip:<scope>".
    private var scopes: [String: [String: Entry]] = [:]
    /// scope → input key → value key → entry.
    private var inputs: [String: [String: [String: Entry]]] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("search-heuristics.json")
    }
    private var inputsURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("search-input-history.json")
    }

    /// Records `amount` uses of `display` in `scope`.
    func record(_ display: String, scope: String, amount: Double = 1, at date: Date = Date()) {
        loadIfNeeded()
        add(display, amount: amount, to: scope, at: date)
        scheduleSave()
    }

    /// Records that typing `typed` in `scope` led to `display`: picked from the drop-down, or
    /// the film opened from the results. Clears the value's skips.
    func recordInput(_ typed: String, value display: String, scope: String, at date: Date = Date()) {
        let inputKey = SearchText.key(typed)
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueKey = SearchText.key(display)
        guard !inputKey.isEmpty, !valueKey.isEmpty, inputKey != valueKey else { return }
        loadIfNeeded()
        var byInput = inputs[scope] ?? [:]
        var values = byInput[inputKey] ?? [:]
        let prior = values[valueKey]?.weight(at: date) ?? 0
        values[valueKey] = Entry(display: display, weight: prior + 1, updated: date)
        if values.count > Self.maxValuesPerInput {
            values = Self.strongest(values, count: Self.maxValuesPerInput, at: date)
        }
        byInput[inputKey] = values
        if byInput.count > Self.maxInputsPerScope {
            let ranked = byInput.map { ($0.key, $0.value.values.reduce(0) { $0 + $1.weight(at: date) }) }
                .sorted { $0.1 > $1.1 }.prefix(Self.maxInputsPerScope)
            byInput = Dictionary(uniqueKeysWithValues: ranked.map { ($0.0, byInput[$0.0]!) })
        }
        inputs[scope] = byInput
        scopes[Self.skipPrefix + scope]?.removeValue(forKey: valueKey)
        scheduleSave()
    }

    /// Records that each of `displays` was shown above the row picked in `scope`.
    func recordSkips(_ displays: [String], scope: String, at date: Date = Date()) {
        guard !displays.isEmpty else { return }
        loadIfNeeded()
        for display in displays { add(display, amount: 1, to: Self.skipPrefix + scope, at: date) }
        scheduleSave()
    }

    /// The current weight of every value in `scope`, keyed by value key.
    func weights(scope: String, at date: Date = Date()) -> [String: (display: String, weight: Double)] {
        loadIfNeeded()
        return current(scopes[scope] ?? [:], at: date)
    }

    /// Everything the ranker reads for `typed` in `scope`. A past input counts when either it
    /// or what is typed starts with the other: "ma" helps "m" and "mat" alike.
    func learned(scope: String, typed: String, at date: Date = Date()) -> Learned {
        loadIfNeeded()
        var result = Learned()
        result.use = current(scopes[scope] ?? [:], at: date)
        result.skips = current(scopes[Self.skipPrefix + scope] ?? [:], at: date).mapValues(\.weight)
        let typedKey = SearchText.key(typed)
        guard !typedKey.isEmpty else { return result }
        for (inputKey, values) in inputs[scope] ?? [:]
        where inputKey.hasPrefix(typedKey) || typedKey.hasPrefix(inputKey) {
            for (valueKey, entry) in values {
                let weight = entry.weight(at: date)
                if weight >= Self.minimumWeight { result.inputs[valueKey, default: 0] += weight }
            }
        }
        return result
    }

    private func add(_ display: String, amount: Double, to scope: String, at date: Date) {
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchText.key(display)
        guard !key.isEmpty, amount > 0 else { return }
        var entries = scopes[scope] ?? [:]
        let prior = entries[key]?.weight(at: date) ?? 0
        entries[key] = Entry(display: display, weight: prior + amount, updated: date)
        if entries.count > Self.maxEntriesPerScope {
            /// Drop the weakest so the store stays bounded however long it is used.
            entries = Self.strongest(entries, count: Self.maxEntriesPerScope, at: date)
        }
        scopes[scope] = entries
    }

    private func current(_ entries: [String: Entry], at date: Date) -> [String: (display: String, weight: Double)] {
        var result: [String: (display: String, weight: Double)] = [:]
        for (key, entry) in entries {
            let weight = entry.weight(at: date)
            if weight >= Self.minimumWeight { result[key] = (entry.display, weight) }
        }
        return result
    }

    private static func strongest(_ entries: [String: Entry], count: Int, at date: Date) -> [String: Entry] {
        let keep = entries.sorted { $0.value.weight(at: date) > $1.value.weight(at: date) }.prefix(count)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        /// Faded entries are dropped on load rather than carried forward forever.
        let now = Date()
        func live(_ entries: [String: Entry]) -> [String: Entry] {
            entries.filter { $0.value.weight(at: now) >= Self.minimumWeight }
        }
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) {
            /// "text" held freeform searches as typed, fragments and all ("man on fir", "t"),
            /// before only the films they led to were learned. It is dropped, not migrated.
            scopes = decoded.filter { $0.key != "text" }.mapValues(live)
        }
        if let url = inputsURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: [String: Entry]]].self, from: data) {
            inputs = decoded.mapValues { $0.mapValues(live).filter { !$0.value.isEmpty } }
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task(priority: .background) {
            try? await Task.sleep(for: Self.saveDelay)
            self.save()
        }
    }

    private func save() {
        saveTask = nil
        if let url = fileURL, let data = try? JSONEncoder().encode(scopes) {
            try? data.write(to: url, options: .atomic)
        }
        if let url = inputsURL, let data = try? JSONEncoder().encode(inputs) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Context

/// The search the user is building, and the ones they ran this session: what a new
/// suggestion should relate to. Each value carries a weight — the pills already in the
/// field in full, then each recent search less than the one after it.
struct SearchContext: Sendable {
    struct Value: Sendable {
        let field: SearchField?
        let key: String
        let weight: Double
    }
    var values: [Value] = []
    /// Values already in the field as pills, by field: never suggested again.
    var present: [SearchField: Set<String>] = [:]
}

// MARK: - Ranking

/// What the field holds when suggestions are asked for.
struct SearchSuggestionRequest: Sendable {
    /// The token field whose value is being typed, or nil for freeform text.
    let field: SearchField?
    /// The value typed so far (after "#field "), or the freeform text.
    let typed: String
    /// For `.list`: every searchable list name with its group, in catalog order.
    let lists: [(name: String, kind: SearchListCatalog.Kind)]
    let context: SearchContext
    /// The view the search was started from, when it says which films are on the user's mind.
    var focus: SearchFocus = .none
}

/// What the view a search starts from says about the films being looked for.
enum SearchFocus: Sendable, Equatable {
    case none
    /// The Queue: queued films.
    case queue
    /// A release smart list (Upcoming Releases, the Purchased and Unpurchased lists): films
    /// with a release coming or wishlisted.
    case releases
    /// A tag's view: the films carrying the tag, by key.
    case tag(String)
}

nonisolated enum SearchSuggestionRanker {
    /// The weights of the score's parts. Match quality is deliberately the heaviest by a
    /// wide margin: what the user is typing is the best evidence there is. Every other part
    /// is capped, together at 13.25 (match tiers are 40, 20, 10, 8, 6 and 5), so they
    /// reorder candidates of similar quality and can lift a word-start match past a weak
    /// match at the value's start, but nothing past a whole-value match, and nothing that
    /// matches only mid-word past a match at the value's start.
    ///
    /// Two exceptions, both about short input. The match weight grows with what is typed —
    /// a quarter at one letter, full from four — because a letter or two matches hundreds of
    /// values about equally well, and only the user's habits can tell them apart. And input
    /// history (what was typed before, and what it led to) is worth a start-of-value match
    /// on its own: it is the user saying which value those letters mean.
    private enum Weight {
        static let match = 10.0
        static let input = 20.0
        static let learned = 4.0
        static let context = 3.0
        static let taste = 3.0
        static let focus = 3.0
        static let season = 1.5
        static let skip = 3.0
        static let count = 0.5
    }

    /// The shortest value worth suggesting. A value of a letter or two is quicker to type
    /// than to pick. Fixed keywords ("4k", "hdr") are exempt: they are terms, not text.
    static let minimumValueLength = 3

    /// The ranked suggestions for `request`, at most `limit` of them.
    ///
    /// A candidate qualifies when the typed text matches it (see `matchQuality`), or when
    /// nothing is typed yet. Its score adds, weighted:
    /// • match quality;
    /// • the learned heuristics for the value in this field;
    /// • context — how many of the films carrying it are films the current pills and this
    ///   session's searches point at (sharing a director, a tag, a title), so after
    ///   `#director nolan`, typing `#cast ` puts his regular cast first;
    /// • taste — what the library says about the films carrying it (SearchVocabulary);
    /// • input history — past input related to what is typed that led to this value;
    /// • focus — its films' share of those the starting view points at (SearchFocus);
    /// • season — how much its films' genres are watched at this time of year;
    /// • less, for each time it was shown and passed over;
    /// • how many films carry it.
    ///
    /// Never suggested: what is already typed, a value shorter than `minimumValueLength`,
    /// and, in fields drawn from the library, a learned value the library no longer holds.
    /// Learned values of other fields — a year range, a rating — are candidates, so habits
    /// surface there too.
    static func rank(
        _ request: SearchSuggestionRequest,
        vocabulary: SearchVocabulary,
        learned: SearchHeuristics.Learned,
        limit: Int
    ) -> [SearchSuggestion] {
        guard limit > 0 else { return [] }
        let typed = SearchText.key(request.typed)
        /// Freeform suggestions wait for something to be typed; an empty field has its own
        /// drop-down (recent searches).
        if request.field == nil && typed.isEmpty { return [] }
        let field = request.field ?? .title
        let typedWords = typed.split(separator: " ").map(String.init)
        let present = request.context.present[field] ?? []
        let isLibraryField = SearchVocabulary.libraryFields.contains(field)
        let matchWeight = Weight.match * min(1, Double(typed.count) / 4)
        /// Per film, how strongly the starting view points at it.
        let focusFilms: (Int32) -> Bool
        switch request.focus {
        case .none:
            focusFilms = { _ in false }
        case .queue:
            let flags = vocabulary.queued
            focusFilms = { flags.indices.contains(Int($0)) && flags[Int($0)] }
        case .releases:
            let flags = vocabulary.releaseInterest
            focusFilms = { flags.indices.contains(Int($0)) && flags[Int($0)] }
        case .tag(let key):
            let films = vocabulary.termIndex[.tags]?[key].flatMap { vocabulary.terms[.tags]?[$0].films }
            let set = Set(films ?? [])
            focusFilms = { set.contains($0) }
        }
        let hasFocus = request.focus != .none && isLibraryField

        struct Candidate {
            let display: String
            let key: String
            let initials: String
            let count: Int
            let taste: Double
            let films: [Int32]
            let group: Int
            let prefix: String
            /// A fixed keyword of a token field, exempt from the minimum length.
            var isKeyword = false
        }
        /// Films the context points at, each with the weight of the strongest value
        /// pointing at it.
        let contextFilms = SearchVocabulary.libraryFields.contains(field)
            ? Self.contextFilms(request.context, vocabulary: vocabulary) : [:]

        var scored: [(candidate: Candidate, score: Double)] = []
        var considered = 0
        /// Scores one candidate, or passes over it. False once the request is superseded —
        /// the next keystroke's — so a run over a field of ten thousand names stops there
        /// instead of finishing for nothing.
        func consider(_ candidate: Candidate) -> Bool {
            considered += 1
            if considered % 1024 == 0, Task.isCancelled { return false }
            /// The match first: it turns away most candidates once anything is typed, so the
            /// other two tests run only on the few that match. A value holding "#" would read
            /// as a new token once it is in the field.
            guard let quality = matchQuality(key: candidate.key, initials: candidate.initials,
                                             typed: typed, words: typedWords),
                  /// With a letter or two typed, a match inside a word is noise.
                  typed.count > 2 || quality >= 0.6,
                  candidate.key != typed,
                  candidate.isKeyword || candidate.key.count >= minimumValueLength,
                  !present.contains(candidate.key), !candidate.display.contains("#") else { return true }
            var related = 0.0
            if !contextFilms.isEmpty && !candidate.films.isEmpty {
                let sum = candidate.films.reduce(0.0) { $0 + (contextFilms[$1] ?? 0) }
                /// Damped by √count, as taste is, so a value on every film in the library
                /// does not relate to everything.
                related = min(1, sum / Double(candidate.films.count).squareRoot())
            }
            var focus = 0.0
            var season = 0.0
            if !candidate.films.isEmpty {
                let root = Double(candidate.films.count).squareRoot()
                if hasFocus {
                    focus = min(1, Double(candidate.films.reduce(0) { $0 + (focusFilms($1) ? 1 : 0) }) / root)
                }
                if isLibraryField {
                    let seasonal = vocabulary.seasonal
                    let sum = candidate.films.reduce(0.0) {
                        $0 + (seasonal.indices.contains(Int($1)) ? seasonal[Int($1)] : 0)
                    }
                    season = min(1, sum / root)
                }
            }
            let input: Double = Weight.input * min(1.5, log1p(learned.inputs[candidate.key] ?? 0))
            let use: Double = Weight.learned * min(1.5, log1p(learned.use[candidate.key]?.weight ?? 0))
            let skipped: Double = Weight.skip * min(1, log1p(learned.skips[candidate.key] ?? 0) / log1p(4))
            let count: Double = Weight.count * min(2.5, log1p(Double(candidate.count)))
            var score: Double = matchWeight * quality + input + use
            score += Weight.context * related + Weight.taste * candidate.taste
            score += Weight.focus * focus + Weight.season * season + count - skipped
            scored.append((candidate, score))
            return true
        }

        /// Each key is a candidate once. The vocabulary's are unique per field already, so
        /// they are read straight from it rather than gathered into a dictionary first.
        if field == .list {
            var seen: Set<String> = []
            for list in request.lists {
                let key = SearchText.key(list.name)
                /// A user list sharing a smart list's name keeps the first group's row.
                guard seen.insert(key).inserted else { continue }
                guard consider(Candidate(display: list.name, key: key,
                                         initials: SearchVocabulary.initials(of: key), count: 0,
                                         taste: 0, films: [], group: list.kind.rawValue,
                                         prefix: prefix(for: list.kind))) else { return [] }
            }
        } else {
            for term in vocabulary.terms[field] ?? [] {
                guard consider(Candidate(display: term.display, key: term.key,
                                         initials: term.initials, count: term.count,
                                         taste: term.taste, films: term.films, group: 0, prefix: "",
                                         isKeyword: term.films.isEmpty && !isLibraryField))
                else { return [] }
            }
            /// A learned value the library does not hold is a candidate only in a field whose
            /// values are not library text: in a library field it names nothing any more.
            let termIndex = vocabulary.termIndex[field] ?? [:]
            for (key, entry) in isLibraryField ? [:] : learned.use where termIndex[key] == nil {
                guard consider(Candidate(display: entry.display, key: key,
                                         initials: SearchVocabulary.initials(of: key), count: 0,
                                         taste: 0, films: [], group: 0, prefix: "")) else { return [] }
            }
        }
        /// Each key and spelling is one candidate (keys repeat only between keywords such as
        /// "hdr10" and "hdr10+"), so this is a total order and the rows below are the same
        /// however the leading entries are found.
        func precedes(_ a: (candidate: Candidate, score: Double), _ b: (candidate: Candidate, score: Double)) -> Bool {
            if a.candidate.group != b.candidate.group { return a.candidate.group < b.candidate.group }
            if a.score != b.score { return a.score > b.score }
            if a.candidate.key != b.candidate.key { return a.candidate.key < b.candidate.key }
            return a.candidate.display < b.candidate.display
        }
        scored = leading(scored, distinctBy: \.candidate.display, count: limit, by: precedes)
        /// Two films can share a title, and a value can be learned under a spelling the
        /// library also holds; one row per shown value.
        var shown: Set<String> = []
        var result: [SearchSuggestion] = []
        for entry in scored where shown.insert(entry.candidate.display).inserted {
            result.append(SearchSuggestion(field: request.field, value: entry.candidate.display,
                                           prefix: entry.candidate.prefix))
            if result.count == limit { break }
        }
        return result
    }

    /// How well `typed` matches a candidate, best first:
    /// 4 — the whole value; 2 — the value's start; 1 — a word's start;
    /// 0.8 — every typed word starts a word of the value, in any order ("hanks tom");
    /// 0.6 — the typed letters start the value's initials ("tdk" → The Dark Knight);
    /// 0.5 — anywhere inside the value; nil — no match. Anything matches before a value is
    /// typed, at 0.
    private static func matchQuality(key: String, initials: String, typed: String, words: [String]) -> Double? {
        if typed.isEmpty { return 0 }
        if key == typed { return 4 }
        if key.hasPrefix(typed) { return 2 }
        /// Bytewise when both are ASCII (see SearchText.contains), where the byte before the
        /// match is the Character before it. The match is not at the start: hasPrefix failed.
        switch SearchText.offset(of: typed, in: key) {
        case .some(.some(let offset)):
            return offset > 0 && key.utf8.dropFirst(offset - 1).first == UInt8(ascii: " ") ? 1 : 0.5
        case .some(.none):
            break
        case .none:
            /// Foundation's range(of:) and Swift's hasPrefix match by different rules, so a
            /// match at the very start is possible here; index(before:) would trap on it.
            if let range = key.range(of: typed) {
                guard range.lowerBound > key.startIndex else { return 2 }
                return key[key.index(before: range.lowerBound)] == " " ? 1 : 0.5
            }
        }
        if words.count > 1 {
            let keyWords = key.split(separator: " ")
            if words.allSatisfy({ word in keyWords.contains { $0.hasPrefix(word) } }) { return 0.8 }
        } else if typed.count >= 2, !typed.contains(" "), initials.hasPrefix(typed) {
            return 0.6
        }
        return nil
    }

    /// The films the context points at, film index → weight.
    private static func contextFilms(_ context: SearchContext, vocabulary: SearchVocabulary) -> [Int32: Double] {
        var films: [Int32: Double] = [:]
        func mark(_ film: Int32, _ weight: Double) {
            films[film] = max(films[film] ?? 0, weight)
        }
        for value in context.values {
            if let field = value.field {
                guard let index = vocabulary.termIndex[field]?[value.key],
                      let term = vocabulary.terms[field]?[index] else { continue }
                /// A value on a large share of the library ("Drama") says little about
                /// which films are meant; it points at them more weakly.
                let weight = value.weight / max(1, log10(Double(term.films.count)))
                for film in term.films { mark(film, weight) }
            } else {
                /// Freeform text points at the films whose titles hold it. Both are keys, so
                /// SearchText.contains gives the answer `contains` does, by a byte search.
                for (index, title) in vocabulary.titleKeys.enumerated() where SearchText.contains(title, value.key) {
                    mark(Int32(index), value.weight)
                }
            }
        }
        return films
    }

    /// The entries a full sort of `items` by `precedes` would put first, in that order: enough
    /// to hold `count` distinct `distinctBy` values, or every entry, sorted, when there are
    /// not that many. The rows taken from the front of either are the rows a full sort gives.
    ///
    /// A request can score every name in a field (fourteen thousand for Crew, before anything
    /// is typed), and only the first `count` distinct values are shown. So the best
    /// `2 × count` are kept in a bounded heap rather than all of them sorted. Those are
    /// exactly the front of the full order; should they hold fewer than `count` distinct
    /// values (titles shared by many films), everything is sorted after all.
    private static func leading<T>(_ items: [T], distinctBy value: (T) -> String, count: Int,
                                   by precedes: (T, T) -> Bool) -> [T] {
        let bound = count * 2
        guard items.count > bound else { return items.sorted(by: precedes) }
        /// A max-heap under `precedes`: the root is the entry kept that sorts last.
        var heap: [T] = []
        heap.reserveCapacity(bound)
        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { return }
                heap.swapAt(parent, child)
                child = parent
            }
        }
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                guard left < heap.count else { return }
                var last = left
                if left + 1 < heap.count, precedes(heap[left], heap[left + 1]) { last = left + 1 }
                guard precedes(heap[parent], heap[last]) else { return }
                heap.swapAt(parent, last)
                parent = last
            }
        }
        for item in items {
            if heap.count < bound {
                heap.append(item)
                siftUp(heap.count - 1)
            } else if precedes(item, heap[0]) {
                heap[0] = item
                siftDown(0)
            }
        }
        let kept = heap.sorted(by: precedes)
        var seen: Set<String> = []
        for item in kept where seen.insert(value(item)).inserted && seen.count == count { return kept }
        return items.sorted(by: precedes)
    }

    private static func prefix(for kind: SearchListCatalog.Kind) -> String {
        switch kind {
        case .report: return "Report: "
        case .recents: return "Recents: "
        case .smart: return "Smart List: "
        case .queue: return "Queue: "
        case .saved: return "Saved Search: "
        case .user: return ""
        }
    }
}
