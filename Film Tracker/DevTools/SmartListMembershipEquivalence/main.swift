// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
import Foundation

var failures = 0
var checked = 0

let today = Calendar.current.startOfDay(for: Date())

func check(_ film: FilmSnapshot, _ label: @autoclosure () -> String) {
    checked += 1
    let targeted = Old.targetedMembership(film, today: today)
    let bulk     = Old.bulkMembership(film, today: today)
    let new      = New.membership(of: film, today: today)
    if targeted != new || bulk != new {
        failures += 1
        if failures <= 25 {
            print("❌ \(label())")
            print("   old-targeted: \(targeted.map(\.rawValue).sorted())")
            print("   old-bulk    : \(bulk.map(\.rawValue).sorted())")
            print("   new         : \(new.map(\.rawValue).sorted())")
        }
    }
}

// ── Dimension values ─────────────────────────────────────────────────────────
// Every subset of the five special-sorting tags, including combinations the UI
// makes mutually exclusive — the predicates make no such assumption, so neither
// does this.
let sortingSubsets: [[String]] = (0..<32).map { mask in
    FilmSpecialSorting.all.enumerated().compactMap { (i, tag) in mask & (1 << i) != 0 ? tag : nil }
}

// Dates chosen around the month-boundary rounding the rotation helper performs:
// the 1st, mid-month, and month-end, at thresholds that land on/near today.
let cal = Calendar.current
var dateStrings: [String] = ["", "not a date", "2020.13.45", "1999-01-01"]
for monthsAgo in [0, 1, 5, 6, 7, 11, 12, 13, 23, 24, 25, 36] {
    guard let base = cal.date(byAdding: .month, value: -monthsAgo, to: today) else { continue }
    for dayOffset in [-1, 0, 1] {
        guard let d = cal.date(byAdding: .day, value: dayOffset, to: base) else { continue }
        dateStrings.append(dotDateFormatter.string(from: d))
        dateStrings.append(dashDateFormatter.string(from: d))
    }
}
// Explicit first/mid/last-of-month probes across a two-year window.
for yearsAgo in [1, 2] {
    guard let y = cal.date(byAdding: .year, value: -yearsAgo, to: today) else { continue }
    let c = cal.dateComponents([.year], from: y)
    for m in 1...12 {
        for day in [1, 15, 28] {
            if let d = cal.date(from: DateComponents(year: c.year, month: m, day: day)) {
                dateStrings.append(dotDateFormatter.string(from: d))
            }
        }
    }
}

let thresholds = [0, 1, 3, 6, 12, 18, 24, 36]

let versionSets: [[String]] = [
    [], ["Theatrical"], ["Director's Cut"], ["Theatrical", "Director's Cut"],
    ["Extended"], ["Theatrical", "Theatrical"]
]

// Every release list of length 0…2 over (format × purchased × versionSet),
// plus a few length-3 lists mixing all three formats.
var releaseAtoms: [ReleaseSnapshot] = []
for f in ReleaseFormat.allCases {
    for p in [true, false] {
        for v in versionSets {
            releaseAtoms.append(ReleaseSnapshot(format: f.rawValue, purchased: p, includedVersions: v))
        }
    }
}
// An unknown format exercises the "release exists but matches no format list" path.
releaseAtoms.append(ReleaseSnapshot(format: "Laserdisc", purchased: true, includedVersions: ["Theatrical"]))
releaseAtoms.append(ReleaseSnapshot(format: "Laserdisc", purchased: false, includedVersions: []))

var releaseLists: [[ReleaseSnapshot]] = [[]]
for a in releaseAtoms { releaseLists.append([a]) }
for a in releaseAtoms { for b in releaseAtoms { releaseLists.append([a, b]) } }

let filmID = UUID()

// ── TEST 1: exhaustive over release lists × sorting subsets × watched × edited ──
// (rotation dimensions pinned to a value that qualifies, so rotation is live here too)
let liveDate = dotDateFormatter.string(from: cal.date(byAdding: .month, value: -30, to: today)!)
for releases in releaseLists {
    for sorting in sortingSubsets {
        for watched in [true, false] {
            for edited in [true, false] {
                check(FilmSnapshot(id: filmID, name: "F", lastWatched: liveDate,
                                   rotationThreshold: 12, specialSorting: sorting,
                                   watched: watched, edited: edited, releases: releases),
                      "releases=\(releases.count) sorting=\(sorting) watched=\(watched) edited=\(edited)")
            }
        }
    }
}
print("TEST 1  release × sorting × watched × edited: \(checked) combinations")

// ── TEST 2: exhaustive over date × threshold × sorting subsets ────────────────
let t2Start = checked
for date in dateStrings {
    for threshold in thresholds {
        for sorting in sortingSubsets {
            for watched in [true, false] {
                check(FilmSnapshot(id: filmID, name: "F", lastWatched: date,
                                   rotationThreshold: threshold, specialSorting: sorting,
                                   watched: watched, edited: false, releases: []),
                      "date=\(date) threshold=\(threshold) sorting=\(sorting)")
            }
        }
    }
}
print("TEST 2  date × threshold × sorting × watched: \(checked - t2Start) combinations")

// ── TEST 3: randomized full-shape sweep ───────────────────────────────────────
let t3Start = checked
var rng = SystemRandomNumberGenerator()
for _ in 0..<300_000 {
    let n = Int.random(in: 0...4, using: &rng)
    let releases = (0..<n).map { _ in releaseAtoms.randomElement(using: &rng)! }
    check(FilmSnapshot(id: filmID, name: "F",
                       lastWatched: dateStrings.randomElement(using: &rng)!,
                       rotationThreshold: thresholds.randomElement(using: &rng)!,
                       specialSorting: sortingSubsets.randomElement(using: &rng)!,
                       watched: Bool.random(using: &rng),
                       edited: Bool.random(using: &rng),
                       releases: releases),
          "random")
}
print("TEST 3  randomized sweep: \(checked - t3Start) combinations")

// ── TEST 4: scope tables match what the old code updated per path ─────────────
// The old recalculateReleaseBasedListsForFilm touched exactly these nine lists.
let oldReleaseScope: Set<SmartListType> = [
    .purchased, .purchased4K, .purchasedBluray, .purchasedDVD,
    .unpurchased, .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD,
    .alternateVersions
]
// The new code derives it: isPurchasedFormat || isUnpurchasedFormat || .alternateVersions,
// where the two is* tests are `sidebarParent == .purchased / .unpurchased`.
func sidebarParent(_ t: SmartListType) -> SmartListType {
    switch t {
    case .upForRotation, .viewedOverOneYearAgo: return .upForRotation
    case .purchased, .purchased4K, .purchasedBluray, .purchasedDVD: return .purchased
    case .unpurchased, .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD: return .unpurchased
    case .alternateVersions, .edited: return .alternateVersions
    case .filteredLibrary, .waitingForEdit, .temporarilyOnHold, .indefinitelyOnHold, .ignore, .blacklisted:
        return .filteredLibrary
    }
}
let newReleaseScope = Set(SmartListType.allCases.filter {
    sidebarParent($0) == .purchased || sidebarParent($0) == .unpurchased || $0 == .alternateVersions
})
if oldReleaseScope != newReleaseScope {
    failures += 1
    print("❌ release-based scope differs: old=\(oldReleaseScope) new=\(newReleaseScope)")
}
print("TEST 4  release-based scope: \(oldReleaseScope == newReleaseScope ? "identical (9 lists)" : "DIFFERS")")

// ── TEST 5: the four family tests, derived vs the deleted hand-written switches ─
var familyFailures = 0
for t in SmartListType.allCases {
    let oldPurchased: Bool = [.purchased, .purchased4K, .purchasedBluray, .purchasedDVD].contains(t)
    let oldUnpurchased: Bool = [.unpurchased, .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD].contains(t)
    let oldRotation: Bool = [.upForRotation, .viewedOverOneYearAgo].contains(t)
    let oldAltVersions: Bool = [.alternateVersions, .edited].contains(t)
    let oldSorting: Bool = [.filteredLibrary, .waitingForEdit, .temporarilyOnHold,
                            .indefinitelyOnHold, .ignore, .blacklisted].contains(t)
    let pairs = [(oldPurchased, sidebarParent(t) == .purchased, "isPurchasedFormat"),
                 (oldUnpurchased, sidebarParent(t) == .unpurchased, "isUnpurchasedFormat"),
                 (oldRotation, sidebarParent(t) == .upForRotation, "isRotationVariant"),
                 (oldAltVersions, sidebarParent(t) == .alternateVersions, "isAlternateVersionsVariant"),
                 (oldSorting, sidebarParent(t) == .filteredLibrary, "isSortingVariant (deleted)")]
    for (old, new, name) in pairs where old != new {
        familyFailures += 1; failures += 1
        print("❌ \(name) differs for \(t.rawValue): old=\(old) new=\(new)")
    }
}
print("TEST 5  family tests derived from sidebarParent: \(familyFailures == 0 ? "all 5 × 18 identical" : "\(familyFailures) DIFFER")")

print("\nTotal membership comparisons: \(checked)")
print(failures == 0 ? "✅ ALL TESTS PASSED" : "❌ \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
