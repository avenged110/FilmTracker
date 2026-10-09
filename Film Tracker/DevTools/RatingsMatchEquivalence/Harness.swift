// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ratings-import matching equivalence harness — shared model + the two algorithms.
//
// `Old` is a faithful transcription of the two hand-written matching passes that
// lived in "81.00 RatingsImporter.swift" before the consolidation (each pass had
// its own copy of the exact-dictionary lookup, the fuzzy fallback, and the
// existing-rating/allowUpdates outcome ladder). `New` is a transcription of the
// consolidated `findMatch`/`recordMatch` pair that replaced them.
//
// Everything unrelated to matching — MainActor hops, progress throttling, the
// 100/50-rating sync cadence, cancellation — is omitted: none of it can change
// which film a rating lands on or which bucket the outcome is counted in, which
// is the whole of what this harness compares.

import Foundation

// MARK: - Shared value types

struct ParsedRating: Sendable { let title: String; let year: String; let rating: Int }

struct FilmRow: Sendable {
    let id: UUID
    let name: String
    let alternateTitles: [String]
    let year: String
    let existingRating: Int
}

/// The full outcome of a matching run: every counter and every title list the
/// importer reports to ImportProgress, plus the queued (filmID, rating) writes in
/// the order they were produced.
struct Outcome: Equatable {
    var imported = 0
    var updated = 0
    var notFound = 0
    var duplicateSkipped = 0
    var addedTitles: [String] = []
    var updatedTitles: [String] = []
    var duplicateTitles: [String] = []
    var writes: [String] = []   // "uuid=rating", in queue order
}

struct Prefs { let allowUpdates: Bool; let fuzzyTitle: Bool; let fuzzyYear: Bool }

// MARK: - Matching primitives (identical to the app; shared by both algorithms)

// FilmComparison.yearsMatch(_:_:allowFuzzy:). The old RatingsImporter had its own
// private copy of this; the consolidation deleted it in favor of FilmComparison's.
// Both spellings are reproduced below and cross-checked by main.swift.
enum Years {
    static func filmComparison(_ y1: String, _ y2: String, allowFuzzy: Bool) -> Bool {
        if y1.isEmpty && y2.isEmpty { return true }
        if y1.isEmpty || y2.isEmpty { return false }
        if y1 == y2 { return true }
        if allowFuzzy, let a = Int(y1), let b = Int(y2) { return abs(a - b) <= 1 }
        return false
    }
    static func ratingsImporterCopy(_ y1: String, _ y2: String, allowFuzzy: Bool) -> Bool {
        if y1 == y2 { return true }
        guard allowFuzzy else { return false }
        guard let a = Int(y1), let b = Int(y2) else { return false }
        return abs(a - b) <= 1
    }
}

// Stand-in for FilmTitleComparison.titlesAreSimilar. The real implementation is a
// Levenshtein-based score; what matters to this harness is only that both
// algorithms consult the SAME similarity relation, and that it is neither trivially
// true nor trivially false over the corpus. A normalized edit-distance ratio with
// the app's 0.80 threshold gives exactly that.
enum Titles {
    static func similar(_ a: String, _ b: String) -> Bool { score(a, b) >= 0.80 }

    static func score(_ a: String, _ b: String) -> Double {
        let s1 = normalize(a), s2 = normalize(b)
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }
        if s1 == s2 { return 1.0 }
        let d = Double(levenshtein(Array(s1), Array(s2)))
        return 1.0 - d / Double(max(s1.count, s2.count))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - OLD: the two hand-written passes

enum Old {
    static func run(ratings: [ParsedRating], films: [FilmRow], prefs: Prefs) -> Outcome {
        var o = Outcome()
        var unmatched: [ParsedRating] = []

        var filmsByName: [String: [FilmRow]] = [:]
        for f in films { filmsByName[f.name, default: []].append(f) }

        var filmsByAlt: [String: [FilmRow]] = [:]
        for f in films where !f.alternateTitles.isEmpty {
            for alt in f.alternateTitles { filmsByAlt[alt, default: []].append(f) }
        }

        // ---- FIRST PASS: primary names ----
        for rating in ratings {
            var matched: FilmRow?
            if let candidates = filmsByName[rating.title],
               let exact = candidates.first(where: {
                   Years.ratingsImporterCopy($0.year, rating.year, allowFuzzy: prefs.fuzzyYear) }) {
                matched = exact
            } else if prefs.fuzzyTitle {
                if let fuzzy = films.first(where: { film in
                    guard Years.ratingsImporterCopy(film.year, rating.year,
                        allowFuzzy: prefs.fuzzyYear) else { return false }
                    return Titles.similar(film.name, rating.title)
                }) { matched = fuzzy }
            }

            if let m = matched {
                let existing = m.existingRating
                if existing != 0 {
                    if prefs.allowUpdates && existing != rating.rating {
                        o.writes.append("\(m.id)=\(rating.rating)")
                        o.updated += 1
                        o.updatedTitles.append(m.name)
                    } else {
                        o.duplicateSkipped += 1
                        o.duplicateTitles.append(m.name)
                    }
                } else {
                    o.writes.append("\(m.id)=\(rating.rating)")
                    o.imported += 1
                    o.addedTitles.append(m.name)
                }
            } else {
                unmatched.append(rating)
            }
        }

        // ---- SECOND PASS: alternate titles ----
        for rating in unmatched {
            var matched: FilmRow?
            if let candidates = filmsByAlt[rating.title],
               let exact = candidates.first(where: {
                   Years.ratingsImporterCopy($0.year, rating.year, allowFuzzy: prefs.fuzzyYear) }) {
                matched = exact
            } else if prefs.fuzzyTitle {
                if let fuzzy = films.first(where: { film in
                    guard !film.alternateTitles.isEmpty else { return false }
                    guard Years.ratingsImporterCopy(film.year, rating.year,
                        allowFuzzy: prefs.fuzzyYear) else { return false }
                    return film.alternateTitles.contains(where: { Titles.similar($0, rating.title) })
                }) { matched = fuzzy }
            }

            if let m = matched {
                let existing = m.existingRating
                if existing != 0 {
                    if prefs.allowUpdates && existing != rating.rating {
                        o.writes.append("\(m.id)=\(rating.rating)")
                        o.updated += 1
                        o.updatedTitles.append(m.name)
                    } else {
                        o.duplicateSkipped += 1
                        o.duplicateTitles.append(m.name)
                    }
                } else {
                    o.writes.append("\(m.id)=\(rating.rating)")
                    o.imported += 1
                    o.addedTitles.append(m.name)
                }
            } else {
                o.notFound += 1
            }
        }
        return o
    }
}

// MARK: - NEW: the consolidated findMatch / recordMatch pair

enum New {
    struct MatchPass {
        let label: String
        let index: [String: [FilmRow]]
        let matchesFuzzily: (FilmRow, String) -> Bool
        let logsAlternateTitles: Bool
    }

    static func run(ratings: [ParsedRating], films: [FilmRow], prefs: Prefs) -> Outcome {
        var o = Outcome()

        var filmsByName: [String: [FilmRow]] = [:]
        for f in films { filmsByName[f.name, default: []].append(f) }

        var filmsByAlt: [String: [FilmRow]] = [:]
        for f in films {
            for alt in f.alternateTitles { filmsByAlt[alt, default: []].append(f) }
        }

        let namePass = MatchPass(
            label: "primary name", index: filmsByName,
            matchesFuzzily: { Titles.similar($0.name, $1) },
            logsAlternateTitles: false)
        let altTitlePass = MatchPass(
            label: "alternateTitle", index: filmsByAlt,
            matchesFuzzily: { film, title in
                film.alternateTitles.contains { Titles.similar($0, title) } },
            logsAlternateTitles: true)

        func findMatch(for rating: ParsedRating,
            using pass: MatchPass) -> (film: FilmRow, wasFuzzy: Bool)? {
            if let candidates = pass.index[rating.title],
               let exact = candidates.first(where: {
                   Years.filmComparison($0.year, rating.year, allowFuzzy: prefs.fuzzyYear) }) {
                return (exact, false)
            }
            guard prefs.fuzzyTitle else { return nil }
            if let fuzzy = films.first(where: { film in
                Years.filmComparison(film.year, rating.year, allowFuzzy: prefs.fuzzyYear)
                    && pass.matchesFuzzily(film, rating.title)
            }) { return (fuzzy, true) }
            return nil
        }

        func recordMatch(_ match: (film: FilmRow, wasFuzzy: Bool), for rating: ParsedRating) {
            let film = match.film
            let existing = film.existingRating
            if existing != 0 && !(prefs.allowUpdates && existing != rating.rating) {
                o.duplicateSkipped += 1
                o.duplicateTitles.append(film.name)
                return
            }
            o.writes.append("\(film.id)=\(rating.rating)")
            if existing != 0 {
                o.updated += 1
                o.updatedTitles.append(film.name)
            } else {
                o.imported += 1
                o.addedTitles.append(film.name)
            }
        }

        var unmatched: [ParsedRating] = []
        for rating in ratings {
            if let m = findMatch(for: rating, using: namePass) {
                recordMatch(m, for: rating)
            } else {
                unmatched.append(rating)
            }
        }
        for rating in unmatched {
            if let m = findMatch(for: rating, using: altTitlePass) {
                recordMatch(m, for: rating)
            } else {
                o.notFound += 1
            }
        }
        return o
    }
}
