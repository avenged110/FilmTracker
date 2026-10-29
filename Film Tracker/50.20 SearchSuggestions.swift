// MARK: - SearchSuggestions.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The search field's value suggestions: the library vocabulary they draw on, the learned
// heuristics that rank them, and the ranking itself. All of it runs off the main actor;
// SearchController only asks for a ranked list and publishes it.

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

    static let empty = SearchVocabulary()

    /// The fields whose values come from the films themselves, so taste and context apply.
    static let libraryFields: Set<SearchField> = [
        .title, .cast, .directors, .producer, .executiveProducer, .screenwriter, .composer,
        .crew, .studio, .tags, .genre,
    ]

    /// Fixed keyword vocabularies for the fields whose values are not library text.
    private static let keywordTerms: [SearchField: [String]] = [
        .releases: ["upcoming", "purchased", "unpurchased", "wishlist", "4k", "native 4k",
                    "upscaled", "blu-ray", "dvd", "imported", "remastered", "hdr",
                    "dolby vision", "hdr10", "hdr10+", "combo-pack", "standalone", "multi-pack"],
        .rotationThreshold: ["default", "override"]
            + Preferences.rotationThresholdOptions.map { "\($0) months" },
        .lastWatched: ["today", "this week", "this month", "this year"],
        .dateAdded: ["today", "this week", "this month", "this year"],
        .flags: FilmFlag.terms.map(\.display),
    ]

    init() {}

    init(films: [UUID: FilmSnapshot], queued: Set<UUID>, today: Date) {
        struct Accumulator {
            var display: String
            var films: [Int32] = []
        }
        var byField: [SearchField: [String: Accumulator]] = [:]
        func add(_ value: String, to field: SearchField, film: Int32?) {
            let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { return }
            let key = SearchText.key(display)
            guard !key.isEmpty else { return }
            byField[field, default: [:]][key, default: Accumulator(display: display)]
                .films.append(contentsOf: film.map { [$0] } ?? [])
        }
        let people: [(SearchField, KeyPath<FilmSnapshot, [String]>)] = [
            (.cast, \.cast), (.directors, \.directors), (.producer, \.producers),
            (.executiveProducer, \.executiveProducers), (.screenwriter, \.screenwriters),
            (.composer, \.composer),
        ]
        var affinity: [Double] = []
        var titleKeys: [String] = []
        affinity.reserveCapacity(films.count)
        titleKeys.reserveCapacity(films.count)
        for film in films.values {
            if Task.isCancelled { return }
            let index = Int32(affinity.count)
            affinity.append(FilmSignals(film, queued: queued.contains(film.id), today: today).affinity)
            titleKeys.append(SearchText.key(film.name))
            add(film.name, to: .title, film: index)
            for (field, path) in people {
                // A person credited twice on one film still counts once for it.
                for name in Set(film[keyPath: path]) {
                    add(name, to: field, film: index)
                }
            }
            // Crew is the union of the six, so a person in two roles counts once here too.
            for name in Set(people.flatMap { film[keyPath: $0.1] }) { add(name, to: .crew, film: index) }
            for studio in Set(film.studio) { add(studio, to: .studio, film: index) }
            for tag in Set(film.tags) { add(tag, to: .tags, film: index) }
            // Genre is one string that may hold several, comma- or slash-separated.
            for genre in Set(film.genre.split(whereSeparator: { $0 == "," || $0 == "/" })) {
                add(String(genre), to: .genre, film: index)
            }
        }
        for (field, words) in Self.keywordTerms {
            for word in words { add(word, to: field, film: nil) }
        }
        for (field, byKey) in byField {
            var built: [Term] = byKey.map { key, acc in
                // Damped by √count: see the type's doc comment.
                let sum = acc.films.reduce(0.0) { $0 + affinity[Int($1)] }
                let taste = acc.films.isEmpty ? 0 : sum / Double(acc.films.count).squareRoot()
                return Term(display: acc.display, key: key, initials: Self.initials(of: key),
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
            termIndex[field] = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($1.key, $0) })
        }
        self.affinity = affinity
        self.titleKeys = titleKeys
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
/// • Wishlisted (0.05): any top-level release on the wishlist.
nonisolated struct FilmSignals {
    let affinity: Double

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

        // Viewing dates are stored "yyyy.MM.dd"; the year is read first so only the last two
        // years' entries pay for a full date parse.
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

        affinity = 0.35 * comingSoon + 0.25 * rating + 0.15 * recentlyWatched
            + 0.15 * rewatched + 0.10 * hallOfFame + 0.10 * (queued ? 1 : 0)
            + 0.10 * recentlyAdded + 0.05 * wishlisted
    }
}

// MARK: - Heuristics

/// A small store of what the user searches for, weighted by how often and how recently.
///
/// Each record adds 1 to a value's weight; weights halve every `halfLifeDays`, so habits
/// that stop fade on their own. Values are grouped by scope (a token field's raw value, or
/// "text" for freeform searches). The store is bounded per scope and saved as one small
/// JSON file, written at most once per `saveDelay` and never on the main actor.
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

    static let textScope = "text"
    static let halfLifeDays = 30.0
    private static let maxEntriesPerScope = 200
    private static let minimumWeight = 0.05
    private static let saveDelay: Duration = .seconds(5)

    /// scope → value key → entry.
    private var scopes: [String: [String: Entry]] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("search-heuristics.json")
    }

    /// Records one use of `display` in `scope`.
    func record(_ display: String, scope: String, at date: Date = Date()) {
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchText.key(display)
        guard !key.isEmpty else { return }
        loadIfNeeded()
        var entries = scopes[scope] ?? [:]
        let prior = entries[key]?.weight(at: date) ?? 0
        entries[key] = Entry(display: display, weight: prior + 1, updated: date)
        if entries.count > Self.maxEntriesPerScope {
            // Drop the weakest so the store stays bounded however long it is used.
            let keep = entries.sorted { $0.value.weight(at: date) > $1.value.weight(at: date) }
                .prefix(Self.maxEntriesPerScope)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        scopes[scope] = entries
        scheduleSave()
    }

    /// The current weight of every value in `scope`, keyed by value key.
    func weights(scope: String, at date: Date = Date()) -> [String: (display: String, weight: Double)] {
        loadIfNeeded()
        var result: [String: (display: String, weight: Double)] = [:]
        for (key, entry) in scopes[scope] ?? [:] {
            let weight = entry.weight(at: date)
            if weight >= Self.minimumWeight { result[key] = (entry.display, weight) }
        }
        return result
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: Entry]].self, from: data)
        else { return }
        // Faded entries are dropped on load rather than carried forward forever.
        let now = Date()
        scopes = decoded.mapValues { $0.filter { $0.value.weight(at: now) >= Self.minimumWeight } }
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
        guard let url = fileURL, let data = try? JSONEncoder().encode(scopes) else { return }
        try? data.write(to: url, options: .atomic)
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
}

nonisolated enum SearchSuggestionRanker {
    /// The weights of the score's parts. Match quality is deliberately the heaviest by a
    /// wide margin: what the user is typing is the best evidence there is. Every other part
    /// is capped, together at 13.25 (match tiers are 40, 20, 10, 8, 6 and 5), so they
    /// reorder candidates of similar quality and can lift a word-start match past a weak
    /// match at the value's start, but nothing past a whole-value match, and nothing that
    /// matches only mid-word past a match at the value's start.
    private enum Weight {
        static let match = 10.0
        static let learned = 4.0
        static let context = 3.0
        static let taste = 3.0
        static let count = 0.5
    }

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
    /// • how many films carry it.
    /// Learned values the library does not hold — a year range, a rating — are candidates
    /// too, so habits surface for every field.
    static func rank(
        _ request: SearchSuggestionRequest,
        vocabulary: SearchVocabulary,
        learned: [String: (display: String, weight: Double)],
        limit: Int
    ) -> [SearchSuggestion] {
        guard limit > 0 else { return [] }
        let typed = SearchText.key(request.typed)
        // Freeform suggestions wait for something to be typed; an empty field has its own
        // drop-down (recent searches).
        if request.field == nil && typed.isEmpty { return [] }
        let field = request.field ?? .title
        let typedWords = typed.split(separator: " ").map(String.init)
        let present = request.context.present[field] ?? []

        struct Candidate {
            let display: String
            let key: String
            let initials: String
            let count: Int
            let taste: Double
            let films: [Int32]
            let group: Int
            let prefix: String
        }
        // Films the context points at, each with the weight of the strongest value
        // pointing at it.
        let contextFilms = SearchVocabulary.libraryFields.contains(field)
            ? Self.contextFilms(request.context, vocabulary: vocabulary) : [:]

        var scored: [(candidate: Candidate, score: Double)] = []
        var considered = 0
        // Scores one candidate, or passes over it. False once the request is superseded —
        // the next keystroke's — so a run over a field of ten thousand names stops there
        // instead of finishing for nothing.
        func consider(_ candidate: Candidate) -> Bool {
            considered += 1
            if considered % 1024 == 0, Task.isCancelled { return false }
            // A value holding "#" would read as a new token once it is in the field.
            guard !candidate.display.contains("#"), !present.contains(candidate.key),
                  let quality = matchQuality(key: candidate.key, initials: candidate.initials,
                                                      typed: typed, words: typedWords) else { return true }
            var related = 0.0
            if !contextFilms.isEmpty && !candidate.films.isEmpty {
                let sum = candidate.films.reduce(0.0) { $0 + (contextFilms[$1] ?? 0) }
                // Damped by √count, as taste is, so a value on every film in the library
                // does not relate to everything.
                related = min(1, sum / Double(candidate.films.count).squareRoot())
            }
            let score = Weight.match * quality
                + Weight.learned * min(1.5, log1p(learned[candidate.key]?.weight ?? 0))
                + Weight.context * related
                + Weight.taste * candidate.taste
                + Weight.count * min(2.5, log1p(Double(candidate.count)))
            scored.append((candidate, score))
            return true
        }

        // Each key is a candidate once. The vocabulary's are unique per field already, so
        // they are read straight from it rather than gathered into a dictionary first.
        if field == .list {
            var seen: Set<String> = []
            for list in request.lists {
                let key = SearchText.key(list.name)
                // A user list sharing a smart list's name keeps the first group's row.
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
                                         taste: term.taste, films: term.films, group: 0, prefix: ""))
                else { return [] }
            }
            let termIndex = vocabulary.termIndex[field] ?? [:]
            for (key, entry) in learned where termIndex[key] == nil {
                guard consider(Candidate(display: entry.display, key: key,
                                         initials: SearchVocabulary.initials(of: key), count: 0,
                                         taste: 0, films: [], group: 0, prefix: "")) else { return [] }
            }
        }
        scored.sort {
            if $0.candidate.group != $1.candidate.group { return $0.candidate.group < $1.candidate.group }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.candidate.key < $1.candidate.key
        }
        // Two films can share a title, and a value can be learned under a spelling the
        // library also holds; one row per shown value.
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
        // Bytewise when both are ASCII (see SearchText.contains), where the byte before the
        // match is the Character before it. The match is not at the start: hasPrefix failed.
        switch SearchText.offset(of: typed, in: key) {
        case .some(.some(let offset)):
            return offset > 0 && key.utf8.dropFirst(offset - 1).first == UInt8(ascii: " ") ? 1 : 0.5
        case .some(.none):
            break
        case .none:
            if let range = key.range(of: typed) {
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
                // A value on a large share of the library ("Drama") says little about
                // which films are meant; it points at them more weakly.
                let weight = value.weight / max(1, log10(Double(term.films.count)))
                for film in term.films { mark(film, weight) }
            } else {
                // Freeform text points at the films whose titles hold it.
                for (index, title) in vocabulary.titleKeys.enumerated() where title.contains(value.key) {
                    mark(Int32(index), value.weight)
                }
            }
        }
        return films
    }

    private static func prefix(for kind: SearchListCatalog.Kind) -> String {
        switch kind {
        case .report: return "Report: "
        case .recents: return "Recents: "
        case .smart: return "Smart List: "
        case .saved: return "Saved Search: "
        case .user: return ""
        }
    }
}
