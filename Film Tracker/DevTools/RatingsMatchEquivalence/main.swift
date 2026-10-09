// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Drives the ratings-import matching equivalence harness.
//
// Randomized corpora are generated to hit every branch the two implementations
// share — exact hits, near-miss titles that only fuzzy matching resolves, ±1 year
// drift, alternate-title-only hits, films sharing a name, films with no rating,
// films whose rating already equals the incoming one, empty titles/years — and
// each corpus is run under all eight combinations of the three preferences.

import Foundation

var checked = 0
var failures = 0
var seenOutcomes = Set<String>()

// Deterministic PRNG so a failure is always reproducible from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let baseTitles = [
    "Heat", "The Thing", "Alien", "Aliens", "Blade Runner", "Blade Runner 2049",
    "Dune", "Dune Part Two", "Solaris", "Stalker", "Ran", "Ikiru", "Amélie",
    "Se7en", "Seven Samurai", "The Ring", "The Lord of the Rings", "Up", "M",
    "", "Léon", "Leon", "Whiplash", "Whiplasch", "Casino", "Casino Royale",
]

func mutate(_ s: String, _ rng: inout SplitMix64) -> String {
    guard !s.isEmpty else { return s }
    switch Int.random(in: 0..<5, using: &rng) {
    case 0: return s                                   // identical
    case 1: return s.lowercased()                      // case-only difference
    case 2: return String(s.dropLast())                // one deletion (near miss)
    case 3: return s + "!"                             // one insertion
    default: return s + " " + s                        // far miss
    }
}

func makeCorpus(seed: UInt64, filmCount: Int, ratingCount: Int)
    -> (films: [FilmRow], ratings: [ParsedRating]) {
    var rng = SplitMix64(seed: seed)
    var films: [FilmRow] = []
    for _ in 0..<filmCount {
        let name = baseTitles.randomElement(using: &rng)!
        // 0-2 alternate titles, sometimes colliding with another film's name.
        let altCount = Int.random(in: 0...2, using: &rng)
        let alts = (0..<altCount).map { _ in
            mutate(baseTitles.randomElement(using: &rng)!, &rng) }
        let year: String = {
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: return ""                    // missing year
            case 1: return "n/a"                 // non-numeric year
            default: return String(Int.random(in: 1995...2024, using: &rng))
            }
        }()
        films.append(FilmRow(id: UUID(), name: name, alternateTitles: alts,
            year: year, existingRating: Int.random(in: 0...10, using: &rng)))
    }

    var ratings: [ParsedRating] = []
    for _ in 0..<ratingCount {
        // Half the ratings are derived from a real film (so exact / fuzzy / year-drift
        // paths fire), half are drawn free-hand (so the not-found path fires).
        if let f = films.randomElement(using: &rng), Bool.random(using: &rng) {
            let source = Bool.random(using: &rng)
                ? f.name : (f.alternateTitles.randomElement(using: &rng) ?? f.name)
            let drift = [-1, 0, 0, 1, 5].randomElement(using: &rng)!
            let year = Int(f.year).map { String($0 + drift) } ?? f.year
            ratings.append(ParsedRating(title: mutate(source, &rng), year: year,
                rating: Int.random(in: 1...10, using: &rng)))
        } else {
            ratings.append(ParsedRating(
                title: mutate(baseTitles.randomElement(using: &rng)!, &rng),
                year: String(Int.random(in: 1994...2025, using: &rng)),
                rating: Int.random(in: 1...10, using: &rng)))
        }
    }
    return (films, ratings)
}

let allPrefs: [Prefs] = [false, true].flatMap { a in
    [false, true].flatMap { t in [false, true].map { y in
        Prefs(allowUpdates: a, fuzzyTitle: t, fuzzyYear: y) } } }

func compare(_ films: [FilmRow], _ ratings: [ParsedRating], _ prefs: Prefs, label: String) {
    checked += 1
    let old = Old.run(ratings: ratings, films: films, prefs: prefs)
    let new = New.run(ratings: ratings, films: films, prefs: prefs)
    // Record which outcome buckets the corpus actually exercised, so a "pass" that
    // only ever compared two empty results can't hide behind the count.
    if old.imported > 0 { seenOutcomes.insert("imported") }
    if old.updated > 0 { seenOutcomes.insert("updated") }
    if old.notFound > 0 { seenOutcomes.insert("notFound") }
    if old.duplicateSkipped > 0 { seenOutcomes.insert("duplicateSkipped") }
    guard old != new else { return }
    failures += 1
    if failures <= 10 {
        print("❌ \(label) [allowUpdates=\(prefs.allowUpdates) fuzzyTitle=\(prefs.fuzzyTitle) fuzzyYear=\(prefs.fuzzyYear)]")
        print("   old: imported=\(old.imported) updated=\(old.updated) notFound=\(old.notFound) dup=\(old.duplicateSkipped)")
        print("   new: imported=\(new.imported) updated=\(new.updated) notFound=\(new.notFound) dup=\(new.duplicateSkipped)")
        if old.writes != new.writes { print("   writes differ: \(old.writes.count) vs \(new.writes.count)") }
        if old.addedTitles != new.addedTitles { print("   addedTitles differ") }
        if old.updatedTitles != new.updatedTitles { print("   updatedTitles differ") }
        if old.duplicateTitles != new.duplicateTitles { print("   duplicateTitles differ") }
    }
}

// ── 1. Randomized corpora ────────────────────────────────────────────────────
print("1. Randomized corpora (2000 seeds × 8 preference combinations)")
for seed in 0..<2000 {
    let (films, ratings) = makeCorpus(seed: UInt64(seed) &* 0x9E37_79B9,
        filmCount: 1 + seed % 24, ratingCount: 12)
    for prefs in allPrefs { compare(films, ratings, prefs, label: "seed \(seed)") }
}

// ── 2. Degenerate corpora ────────────────────────────────────────────────────
print("2. Degenerate corpora (empty library, empty ratings, empty strings)")
let emptyLibrary: [FilmRow] = []
let someRatings = [ParsedRating(title: "Heat", year: "1995", rating: 8),
                   ParsedRating(title: "", year: "", rating: 3)]
for prefs in allPrefs {
    compare(emptyLibrary, someRatings, prefs, label: "empty library")
    compare([FilmRow(id: UUID(), name: "Heat", alternateTitles: [], year: "1995",
        existingRating: 0)], [], prefs, label: "no ratings")
}

// A film whose name is "" and a rating whose title is "": the exact-match
// dictionary keys on "" in both implementations, so both must match it.
let emptyNamed = [FilmRow(id: UUID(), name: "", alternateTitles: [""], year: "",
    existingRating: 0)]
for prefs in allPrefs {
    compare(emptyNamed, [ParsedRating(title: "", year: "", rating: 7)],
        prefs, label: "empty name and year")
}

// ── 3. Order sensitivity: duplicate names, first-wins ────────────────────────
print("3. Duplicate names and alternate-title collisions (first-match-wins order)")
let a = FilmRow(id: UUID(), name: "Dune", alternateTitles: ["Duna"], year: "1984", existingRating: 0)
let b = FilmRow(id: UUID(), name: "Dune", alternateTitles: ["Duna"], year: "2021", existingRating: 6)
let c = FilmRow(id: UUID(), name: "Duna", alternateTitles: ["Dune"], year: "2021", existingRating: 0)
for perm in [[a, b, c], [c, b, a], [b, a, c], [a, c, b], [b, c, a], [c, a, b]] {
    for prefs in allPrefs {
        compare(perm, [ParsedRating(title: "Dune", year: "2021", rating: 6),
                       ParsedRating(title: "Dune", year: "2022", rating: 9),
                       ParsedRating(title: "Duna", year: "1984", rating: 4),
                       ParsedRating(title: "Dune", year: "n/a", rating: 2)],
            prefs, label: "permutation")
    }
}

// ── 4. The deleted year-matching copy ────────────────────────────────────────
// The consolidation deleted RatingsImporter's private yearsMatch in favor of
// FilmComparison's. They are only interchangeable if they agree everywhere.
print("4. yearsMatch: RatingsImporter's deleted copy vs FilmComparison's")
let yearInputs = ["", " ", "0", "1899", "1999", "2000", "2001", "2024", "n/a", "19999", "-1", "2 0 2 0"]
var yearChecks = 0
for y1 in yearInputs {
    for y2 in yearInputs {
        for fuzzy in [false, true] {
            yearChecks += 1
            let old = Years.ratingsImporterCopy(y1, y2, allowFuzzy: fuzzy)
            let new = Years.filmComparison(y1, y2, allowFuzzy: fuzzy)
            if old != new {
                failures += 1
                print("❌ yearsMatch disagreement: '\(y1)' vs '\(y2)' fuzzy=\(fuzzy): old=\(old) new=\(new)")
            }
        }
    }
}

print("")
print("Compared \(checked) matching runs and \(yearChecks) year-match pairs.")
print("Outcome buckets exercised: \(seenOutcomes.sorted().joined(separator: ", "))")
if seenOutcomes.count < 4 {
    print("⚠️  Not all four outcome buckets were exercised — corpus is too narrow.")
    exit(1)
}
if failures == 0 {
    print("✅ PASS — the consolidated matcher is behaviorally identical to the two passes it replaced.")
} else {
    print("❌ FAIL — \(failures) disagreement(s).")
    exit(1)
}
