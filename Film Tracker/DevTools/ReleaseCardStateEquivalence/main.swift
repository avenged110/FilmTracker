// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
import Foundation

// Every mutable field, as a named mutation applied to a model.
let mutators: [(String, (ReleaseCardModel) -> Void)] = [
    ("studio",             { $0.studio = $0.studio + "x" }),
    ("releaseYear",        { $0.releaseYear &+= 1 }),
    ("hasReleaseYear",     { $0.hasReleaseYear.toggle() }),
    ("baseReleaseYear",    { $0.baseReleaseYear &+= 1 }),
    ("hasBaseReleaseYear", { $0.hasBaseReleaseYear.toggle() }),
    ("purchased",          { $0.purchased.toggle() }),
    ("wishlist",           { $0.wishlist &+= 1 }),
    ("format",             { $0.format += "x" }),
    ("includedVersions",   { $0.includedVersions.append("v") }),
    ("independence",       { $0.independence += "x" }),
    ("videoFormat",        { $0.videoFormat += "x" }),
    ("releaseAspectRatio", { $0.releaseAspectRatio.append("a") }),
    ("scanningMethod",     { $0.scanningMethod += "x" }),
    ("audioFormat",        { $0.audioFormat += "x" }),
    ("audioChannels",      { $0.audioChannels += "x" }),
    ("hasSubtitles",       { $0.hasSubtitles.toggle() }),
    ("numberOfDiscs",      { $0.numberOfDiscs &+= 1 }),
    ("discMultiPack",      { $0.discMultiPack.toggle() }),
    ("hasArtwork",         { $0.hasArtwork += "x" }),
    ("remastered",         { $0.remastered.toggle() }),
    ("nationalOrigin",     { $0.nationalOrigin += "x" }),
    ("replicationType",    { $0.replicationType += "x" }),
    ("discCapacity",       { $0.discCapacity.append("c") }),
    ("hasHDR",             { $0.hasHDR += "x" }),
    ("masterType",         { $0.masterType += "x" }),
    ("regionLock",         { $0.regionLock += "x" }),
    ("regionLockBypass",   { $0.regionLockBypass.toggle() }),
    ("marketAvailability", { $0.marketAvailability.append("m") }),
    ("numberOfCopies",     { $0.numberOfCopies &+= 1 }),
    ("cost",               { $0.cost += 1 }),
    ("amountSpent",        { $0.amountSpent += 1 }),
    ("purchaseDate",       { $0.purchaseDate.addTimeInterval(86400) }),
    ("hasPurchaseDate",    { $0.hasPurchaseDate.toggle() }),
    ("lowestPrice",        { $0.lowestPrice += 1 }),
    ("lowestPriceDate",    { $0.lowestPriceDate.addTimeInterval(86400) }),
    ("hasLowestPriceDate", { $0.hasLowestPriceDate.toggle() }),
    ("condition",          { $0.condition += "x" }),
    ("notes",              { $0.notes += "x" }),
    ("sortOrder",          { $0.sortOrder &+= 1 }),
]

var rng = SystemRandomNumberGenerator()
func randomModel(id: UUID, dateAdded: Date) -> ReleaseCardModel {
    let m = ReleaseCardModel(id: id, studio: "S\(Int.random(in: 0...3))", dateAdded: dateAdded)
    m.releaseYear = Int.random(in: 1990...2030); m.hasReleaseYear = .random()
    m.baseReleaseYear = Int.random(in: 1990...2030); m.hasBaseReleaseYear = .random()
    m.purchased = .random(); m.wishlist = Int.random(in: 0...3)
    m.format = ["4K","BD","DVD"].randomElement()!
    m.includedVersions = (0..<Int.random(in: 0...2)).map { "v\($0)" }
    m.independence = ["A","B"].randomElement()!; m.videoFormat = ["x","y"].randomElement()!
    m.releaseAspectRatio = (0..<Int.random(in: 0...2)).map { "r\($0)" }
    m.scanningMethod = ["s","t"].randomElement()!; m.audioFormat = ["a","b"].randomElement()!
    m.audioChannels = ["5.1","2.0"].randomElement()!; m.hasSubtitles = .random()
    m.numberOfDiscs = Int.random(in: 0...4); m.discMultiPack = .random()
    m.hasArtwork = ["y","n"].randomElement()!; m.remastered = .random()
    m.nationalOrigin = ["US","UK"].randomElement()!; m.replicationType = ["p","q"].randomElement()!
    m.discCapacity = (0..<Int.random(in: 0...2)).map { "c\($0)" }
    m.hasHDR = ["h","n"].randomElement()!; m.masterType = ["m","n"].randomElement()!
    m.regionLock = ["A","B"].randomElement()!; m.regionLockBypass = .random()
    m.marketAvailability = (0..<Int.random(in: 0...2)).map { "k\($0)" }
    m.numberOfCopies = Int.random(in: 0...3)
    m.cost = Double(Int.random(in: 0...100)); m.amountSpent = Double(Int.random(in: 0...100))
    m.purchaseDate = Date(timeIntervalSince1970: Double(Int.random(in: 0...100)) * 86400)
    m.hasPurchaseDate = .random(); m.lowestPrice = Double(Int.random(in: 0...100))
    m.lowestPriceDate = Date(timeIntervalSince1970: Double(Int.random(in: 0...100)) * 86400)
    m.hasLowestPriceDate = .random(); m.condition = ["c","d"].randomElement()!
    m.notes = ["", "n"].randomElement()!; m.sortOrder = Int.random(in: 0...5)
    return m
}

var failures = 0
func expect(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { failures += 1; if failures <= 20 { print("FAIL: \(msg())") } }
}

// ── TEST 1: matches(state) ≡ (snapshot() == state), over random pairs ──────────
let sharedID = UUID(); let sharedDate = Date(timeIntervalSince1970: 12345)
for _ in 0..<200_000 {
    let a = randomModel(id: sharedID, dateAdded: sharedDate)
    let b = randomModel(id: Bool.random() ? sharedID : UUID(),
                        dateAdded: Bool.random() ? sharedDate : Date(timeIntervalSince1970: 999))
    let state = b.snapshot()
    expect(a.matches(state) == (a.snapshot() == state),
           "matches=\(a.matches(state)) snapEq=\(a.snapshot() == state)")
}
print("TEST 1 (matches ≡ snapshot==) done, failures so far: \(failures)")

// ── TEST 2: per-field sensitivity — old contentHash vs new ────────────────────
for (name, mutate) in mutators {
    for _ in 0..<400 {
        let m = randomModel(id: sharedID, dateAdded: sharedDate)
        let oldBefore = m.contentHash, newBefore = m.contentHashNew
        mutate(m)
        let oldChanged = m.contentHash != oldBefore
        let newChanged = m.contentHashNew != newBefore
        expect(oldChanged == newChanged,
               "contentHash sensitivity differs on '\(name)': old changed=\(oldChanged) new changed=\(newChanged)")
    }
}
print("TEST 2 (contentHash per-field sensitivity) done, failures so far: \(failures)")

// ── TEST 3: contentHash equality-relation equivalence over random pairs ───────
for _ in 0..<100_000 {
    let a = randomModel(id: sharedID, dateAdded: sharedDate)
    let b = randomModel(id: sharedID, dateAdded: sharedDate)
    expect((a.contentHash == b.contentHash) == (a.contentHashNew == b.contentHashNew),
           "contentHash relation differs")
}
print("TEST 3 (contentHash relation) done, failures so far: \(failures)")

// ── TEST 4: differingFields old ≡ Mirror-based new ────────────────────────────
for _ in 0..<200_000 {
    let a = randomModel(id: sharedID, dateAdded: sharedDate)
    let b = randomModel(id: sharedID, dateAdded: sharedDate)
    let sa = a.snapshot(), sb = b.snapshot()
    let o = sa.differingFields(from: sb), n = sa.differingFieldsNew(from: sb)
    expect(o == n, "differingFields mismatch\n  old: \(o)\n  new: \(n)")
}
print("TEST 4 (differingFields) done, failures so far: \(failures)")

// ── TEST 5: targeted edge cases ───────────────────────────────────────────────
// 5a: negative zero in a Double field (old hashes bitPattern, new hashes Double)
let z = randomModel(id: sharedID, dateAdded: sharedDate)
z.cost = 0.0
let zOld = z.contentHash, zNew = z.contentHashNew
z.cost = -0.0
print("5a  cost 0.0 -> -0.0 : old contentHash changed=\(z.contentHash != zOld), new changed=\(z.contentHashNew != zNew)")

// 5b: placeholder drift while the has-flag is false
let p = randomModel(id: sharedID, dateAdded: sharedDate)
p.hasReleaseYear = false
let pOld = p.contentHash, pNew = p.contentHashNew, pSnap = p.snapshot()
p.releaseYear &+= 5
print("5b  inactive releaseYear drift : old hash changed=\(p.contentHash != pOld), new hash changed=\(p.contentHashNew != pNew), snapshot changed=\(p.snapshot() != pSnap)")


// ── TEST 6: benchmark — matches() vs snapshot()== on the debounce-tick path ────
let bench = (0..<20).map { _ in randomModel(id: UUID(), dateAdded: sharedDate) }
let baselines = bench.map { $0.snapshot() }
var sink = 0
var t0 = Date()
for _ in 0..<50_000 { for (m, s) in zip(bench, baselines) where !m.matches(s) { sink += 1 } }
let tMatches = Date().timeIntervalSince(t0)
t0 = Date()
for _ in 0..<50_000 { for (m, s) in zip(bench, baselines) where m.snapshot() != s { sink += 1 } }
let tSnap = Date().timeIntervalSince(t0)
print(String(format: "TEST 6  20 releases, 50k ticks: matches()=%.3fs  snapshot()!==%.3fs  (sink %d)", tMatches, tSnap, sink))
print(String(format: "        per tick over 20 releases: matches()=%.2f\u{00B5}s  snapshot()!==%.2f\u{00B5}s",
             tMatches / 50_000 * 1e6, tSnap / 50_000 * 1e6))

print(failures == 0 ? "\n✅ ALL TESTS PASSED" : "\n❌ \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
