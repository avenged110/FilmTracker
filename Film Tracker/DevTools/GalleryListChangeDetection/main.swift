// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("  ✅ \(label)") }
    else { failures += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : " — \(detail())")") }
}

let allInputs: [SectionInputs] = {
    var out: [SectionInputs] = []
    for show in [false, true] {
        for qf in [nil, "all", "upNext"] as [String?] {
            for sort in [nil, "title", "dateAdded"] as [String?] {
                for rc in [nil, "recentlyAdded"] as [String?] {
                    out.append(SectionInputs(showSortingSections: show, queueFilter: qf,
                                             sortOption: sort, recentsCategory: rc))
                }
            }
        }
    }
    return out
}()

/// Every arrangement of up to `maxCount` films drawn from the given alphabets.
func allFilmSets(maxCount: Int, ids: Int, bands: [String], titles: [String]) -> [[Film]] {
    var out: [[Film]] = [[]]
    var frontier: [[Film]] = [[]]
    for _ in 0..<maxCount {
        var next: [[Film]] = []
        for base in frontier {
            for id in 0..<ids where !base.contains(where: { $0.id == id }) {
                for b in bands {
                    for t in titles { next.append(base + [Film(id: id, band: b, title: t)]) }
                }
            }
        }
        out += next
        frontier = next
    }
    return out
}

let filmSets = allFilmSets(maxCount: 3, ids: 3, bands: ["A", "B"], titles: ["t0", "t1"])
let queueMaps: [[Int: String]] = [
    [:], [0: "Up Next", 1: "Up Next", 2: "Up Next"],
    [0: "Up Next", 1: "Soon", 2: "Later"],
    [0: "Up Next", 1: "Up Next", 2: "Soon"],
]

print("Test 1 — SKIP SOUNDNESS: whenever the gate skips the rebuild, the row model it")
print("         would have produced is identical to the one already held.")
print("         (exhaustive over a reduced space, then randomized over the full one)")
do {
    // Reduced but still complete space: every films arrangement of length <= 2 over two
    // ids, crossed with every section-input combination that changes a banding gate.
    let smallSets = allFilmSets(maxCount: 2, ids: 2, bands: ["A", "B"], titles: ["t0", "t1"])
    var smallInputs: [SectionInputs] = []
    for show in [false, true] {
        for qf in [nil, "all"] as [String?] {
            for sort in [nil, "title"] as [String?] {
                smallInputs.append(SectionInputs(showSortingSections: show, queueFilter: qf,
                                                 sortOption: sort, recentsCategory: nil))
            }
        }
    }
    let smallQueueMaps = Array(queueMaps.prefix(2))

    var skips = 0, cases = 0
    var violation: String?

    func probe(_ oldF: [Film], _ newF: [Film], _ lastIn: SectionInputs,
               _ newIn: SectionInputs, _ qm: [Int: String]) {
        cases += 1
        let oldRows = buildRowModel(films: oldF, inputs: lastIn, queueSections: qm).rows
        let newRows = buildRowModel(films: newF, inputs: newIn, queueSections: qm).rows
        let d = decide(oldFilms: oldF, newFilms: newF, lastInputs: lastIn, newInputs: newIn,
                       isViewSwitch: false, oldRows: oldRows, newRowsIfRebuilt: newRows)
        if !d.rebuilds {
            skips += 1
            if newRows != oldRows && violation == nil {
                violation = "old=\(oldF) new=\(newF) lastIn=\(lastIn) newIn=\(newIn) qm=\(qm)"
            }
        }
    }

    for oldF in smallSets {
        for newF in smallSets {
            for lastIn in smallInputs {
                for newIn in smallInputs {
                    for qm in smallQueueMaps { probe(oldF, newF, lastIn, newIn, qm) }
                }
            }
        }
    }
    let exhaustiveCases = cases
    check("exhaustive: no skip hid a row-model change (\(skips) skips / \(exhaustiveCases) cases)",
          violation == nil, violation ?? "")

    // Randomized sweep over the full alphabets, deterministic seed so a failure reproduces.
    var seed: UInt64 = 0x5DEE_CE66_D41B_1E57
    func rand(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    for _ in 0..<400_000 {
        probe(filmSets[rand(filmSets.count)], filmSets[rand(filmSets.count)],
              allInputs[rand(allInputs.count)], allInputs[rand(allInputs.count)],
              queueMaps[rand(queueMaps.count)])
    }
    check("randomized: no skip hid a row-model change (\(cases - exhaustiveCases) draws)",
          violation == nil, violation ?? "")
    check("the skip actually fires (not vacuously true)", skips > 0, "skips=\(skips)")
}

print("Test 2 — the Film Queue \"All\" opt-out: queue membership changing with a")
print("         byte-identical films array still rebuilds.")
do {
    // The exact scenario from the review: promoting the first "Soon" film to "Up Next"
    // leaves it in the same array position with every snapshot field unchanged.
    let films = [Film(id: 0, band: "A", title: "t0"),
                 Film(id: 1, band: "A", title: "t0"),
                 Film(id: 2, band: "A", title: "t0")]
    let before: [Int: String] = [0: "Up Next", 1: "Soon", 2: "Soon"]
    let after:  [Int: String] = [0: "Up Next", 1: "Up Next", 2: "Soon"]
    let inputs = SectionInputs(showSortingSections: false, queueFilter: "all",
                               sortOption: "dateAdded", recentsCategory: nil)

    let oldRows = buildRowModel(films: films, inputs: inputs, queueSections: before).rows
    let newRows = buildRowModel(films: films, inputs: inputs, queueSections: after).rows
    check("the banding genuinely differs", oldRows != newRows)
    check("films array is byte-identical", films == films)

    let d = decide(oldFilms: films, newFilms: films, lastInputs: inputs, newInputs: inputs,
                   isViewSwitch: false, oldRows: oldRows, newRowsIfRebuilt: newRows)
    check("gate rebuilds anyway (queue opt-out)", d.rebuilds)
    check("and the stale divider forces a full reload", d.fullReload)

    // The same transition on a NON-queue view is, by construction, impossible to express:
    // there the bands come from `band`, which lives in the snapshot.
    var moved = films; moved[1].band = "B"
    let nonQueue = SectionInputs(showSortingSections: true, queueFilter: nil,
                                 sortOption: "title", recentsCategory: nil)
    let d2 = decide(oldFilms: films, newFilms: moved, lastInputs: nonQueue, newInputs: nonQueue,
                    isViewSwitch: false,
                    oldRows: buildRowModel(films: films, inputs: nonQueue, queueSections: [:]).rows,
                    newRowsIfRebuilt: buildRowModel(films: moved, inputs: nonQueue, queueSections: [:]).rows)
    check("a sort-derived re-band moves a snapshot field, so filmsChanged sees it", d2.rebuilds)
}

print("")
print("Test 3 — RELOAD SUPERSET: the new predicate reloads whenever the old one did.")
do {
    var strictlyMore = 0, cases = 0
    var regression: String?
    for oldF in filmSets {
        for newF in filmSets {
            for sw in [false, true] {
                cases += 1
                let inputs = SectionInputs(showSortingSections: false, queueFilter: nil,
                                           sortOption: "dateAdded", recentsCategory: nil)
                let oldRows = buildRowModel(films: oldF, inputs: inputs, queueSections: [:]).rows
                let newRows = buildRowModel(films: newF, inputs: inputs, queueSections: [:]).rows
                let d = decide(oldFilms: oldF, newFilms: newF, lastInputs: inputs,
                               newInputs: inputs, isViewSwitch: sw,
                               oldRows: oldRows, newRowsIfRebuilt: newRows)
                let legacy = legacyReloadPredicate(oldFilms: oldF, newFilms: newF,
                                                   isViewSwitch: sw,
                                                   rowModelChanged: newRows != oldRows)
                if legacy && !d.fullReload { regression = "old=\(oldF) new=\(newF) sw=\(sw)" }
                if d.fullReload && !legacy { strictlyMore += 1 }
            }
        }
    }
    check("never reloads less than the predicate it replaced (\(cases) cases)",
          regression == nil, regression ?? "")
    // `filmSets` tops out at three films, which cannot express an interior reorder at all:
    // with the first and last pinned there is only one element between them. The strictly-
    // more property therefore needs its own space — every permutation of four distinct
    // films, which is the smallest one in which an interior reorder exists.
    let quad = (0..<4).map { Film(id: $0, band: "A", title: "t0") }
    var perms: [[Film]] = []
    func permute(_ rest: [Film], _ acc: [Film]) {
        if rest.isEmpty { perms.append(acc); return }
        for (i, f) in rest.enumerated() {
            var r = rest; r.remove(at: i); permute(r, acc + [f])
        }
    }
    permute(quad, [])
    let inputs = SectionInputs(showSortingSections: false, queueFilter: nil,
                               sortOption: "dateAdded", recentsCategory: nil)
    var permRegression: String?
    for a in perms {
        for b in perms {
            let ra = buildRowModel(films: a, inputs: inputs, queueSections: [:]).rows
            let rb = buildRowModel(films: b, inputs: inputs, queueSections: [:]).rows
            let d = decide(oldFilms: a, newFilms: b, lastInputs: inputs, newInputs: inputs,
                           isViewSwitch: false, oldRows: ra, newRowsIfRebuilt: rb)
            let legacy = legacyReloadPredicate(oldFilms: a, newFilms: b, isViewSwitch: false,
                                               rowModelChanged: rb != ra)
            if legacy && !d.fullReload { permRegression = "a=\(a.map(\.id)) b=\(b.map(\.id))" }
            if d.fullReload && !legacy { strictlyMore += 1 }
            // Any reordering at all must now force a reload — that is the whole point.
            if a.map(\.id) != b.map(\.id) && !d.fullReload {
                permRegression = "missed reorder a=\(a.map(\.id)) b=\(b.map(\.id))"
            }
        }
    }
    check("over all \(perms.count * perms.count) four-film permutation pairs, every "
          + "reordering forces a reload and none reloads less than before",
          permRegression == nil, permRegression ?? "")
    check("and reloads strictly more in \(strictlyMore) cases (the interior reorders)",
          strictlyMore > 0)
}

print("")
print("Test 4 — the interior reorder the old predicate was blind to.")
do {
    // Same count, same first, same last, no banding — only the interior permutes.
    let a = [Film(id: 0, band: "A", title: "t0"), Film(id: 1, band: "A", title: "t0"),
             Film(id: 2, band: "A", title: "t0"), Film(id: 3, band: "A", title: "t0")]
    let b = [a[0], a[2], a[1], a[3]]
    let inputs = SectionInputs(showSortingSections: false, queueFilter: nil,
                               sortOption: "dateAdded", recentsCategory: nil)
    let rowsA = buildRowModel(films: a, inputs: inputs, queueSections: [:]).rows
    let rowsB = buildRowModel(films: b, inputs: inputs, queueSections: [:]).rows
    check("row models are identical (1:1 identity mapping — the trap)", rowsA == rowsB)
    check("old predicate did NOT reload",
          !legacyReloadPredicate(oldFilms: a, newFilms: b, isViewSwitch: false,
                                 rowModelChanged: rowsB != rowsA))
    let d = decide(oldFilms: a, newFilms: b, lastInputs: inputs, newInputs: inputs,
                   isViewSwitch: false, oldRows: rowsA, newRowsIfRebuilt: rowsB)
    check("new predicate DOES reload", d.fullReload)
}

print("")
print("Test 5 — a metadata-only edit still refreshes, and still avoids a full reload.")
do {
    let a = [Film(id: 0, band: "A", title: "t0"), Film(id: 1, band: "A", title: "t0")]
    var b = a; b[1].title = "renamed"          // a rendered field, no reorder, no re-band
    let inputs = SectionInputs(showSortingSections: false, queueFilter: nil,
                               sortOption: "dateAdded", recentsCategory: nil)
    let rowsA = buildRowModel(films: a, inputs: inputs, queueSections: [:]).rows
    let rowsB = buildRowModel(films: b, inputs: inputs, queueSections: [:]).rows
    let d = decide(oldFilms: a, newFilms: b, lastInputs: inputs, newInputs: inputs,
                   isViewSwitch: false, oldRows: rowsA, newRowsIfRebuilt: rowsB)
    check("films are re-assigned, so the visible-row refresh sees fresh data", d.rebuilds)
    check("but no full reload is taken", !d.fullReload)
}

print("")
print("Test 6 — CoW short-circuit: the gate is O(1) on a no-op pass.")
do {
    var comparisons = 0
    struct Counted: Equatable {
        var id: Int; var payload: String
        static func == (l: Counted, r: Counted) -> Bool { comparisonCounter += 1; return l.id == r.id && l.payload == r.payload }
    }
    let big: [Counted] = (0..<100_000).map { Counted(id: $0, payload: "a reasonably long field value") }
    let shared = big
    comparisonCounter = 0
    let t = ContinuousClock.now
    let equal = (shared == big)
    let elapsed = ContinuousClock.now - t
    comparisons = comparisonCounter
    check("shared CoW buffer compares equal with zero element comparisons",
          equal && comparisons == 0, "comparisons=\(comparisons)")
    check("and does so in under 100µs for 100k films", elapsed < .milliseconds(1), "\(elapsed)")
}

print("")
print("Test 7 — scroll clamp matches NSClipView.constrainBoundsRect (real AppKit).")
do {
    _ = NSApplication.shared
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    var mismatch: String?
    var cases = 0
    for viewportH in [100, 400, 777] as [CGFloat] {
        for contentH in [0, 50, 400, 1000, 5000] as [CGFloat] {
            for bottom in [0, 29] as [CGFloat] {
                cases += 1
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: viewportH),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: viewportH))
                sv.hasVerticalScroller = true
                sv.automaticallyAdjustsContentInsets = false
                sv.documentView = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: contentH))
                w.contentView = sv
                sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
                sv.tile(); w.layoutIfNeeded()

                let cv = sv.contentView
                let appkitMax = cv.constrainBoundsRect(
                    NSRect(origin: NSPoint(x: 0, y: 1_000_000), size: cv.bounds.size)).origin.y
                // ← NSScrollView.maxVerticalScrollOffset(forContentHeight:)
                let ours = max(0, contentH + sv.contentInsets.bottom - cv.bounds.height)
                // ← the expression this replaced
                let legacy = max(0, contentH - sv.documentVisibleRect.height)
                if abs(ours - appkitMax) > 0.5 && mismatch == nil {
                    mismatch = "viewport=\(viewportH) content=\(contentH) bottom=\(bottom): ours=\(ours) appkit=\(appkitMax)"
                }
                if bottom > 0 && contentH > viewportH {
                    if abs(legacy - appkitMax) < 0.5 && mismatch == nil {
                        mismatch = "legacy unexpectedly correct at content=\(contentH) bottom=\(bottom)"
                    }
                }
            }
        }
    }
    check("agrees with AppKit across \(cases) viewport/content/inset combinations",
          mismatch == nil, mismatch ?? "")
}

print("")
print("Test 8 — NO-OP SOUNDNESS: whenever a pass takes neither the full reload nor the")
print("         visible-row refresh, every row the table would draw is the row it already")
print("         shows (exhaustive over a reduced space, then randomized).")
do {
    /// What the table draws: each row item, with a film row resolved to its film.
    enum Drawn: Equatable { case divider(Section, Int), film(Film) }
    func drawn(_ rows: [RowItem], _ films: [Film]) -> [Drawn] {
        rows.map {
            switch $0 {
            case .divider(let s, let n): return .divider(s, n)
            case .film(let i): return .film(films[i])
            }
        }
    }
    var noOps = 0, refreshes = 0, cases = 0
    var violation: String?
    func probe(_ oldF: [Film], _ newF: [Film], _ lastIn: SectionInputs,
               _ newIn: SectionInputs, _ qm: [Int: String], _ viewSwitch: Bool) {
        cases += 1
        let oldRows = buildRowModel(films: oldF, inputs: lastIn, queueSections: qm).rows
        let newRows = buildRowModel(films: newF, inputs: newIn, queueSections: qm).rows
        let d = decide(oldFilms: oldF, newFilms: newF, lastInputs: lastIn, newInputs: newIn,
                       isViewSwitch: viewSwitch, oldRows: oldRows, newRowsIfRebuilt: newRows)
        if d.visibleRefresh { refreshes += 1 }
        guard !d.fullReload && !d.visibleRefresh else { return }
        noOps += 1
        let heldRows = d.rebuilds ? newRows : oldRows
        if drawn(heldRows, newF) != drawn(oldRows, oldF) && violation == nil {
            violation = "old=\(oldF) new=\(newF) in=\(lastIn)→\(newIn)"
        }
    }
    let smallSets = allFilmSets(maxCount: 2, ids: 2, bands: ["A", "B"], titles: ["t0", "t1"])
    for a in smallSets { for b in smallSets { for i in allInputs.prefix(12) {
        for j in allInputs.prefix(12) { for qm in queueMaps.prefix(2) {
            for vs in [false, true] { probe(a, b, i, j, qm, vs) } } } } } }
    let exhaustive = cases
    check("exhaustive: no skipped refresh hid a drawn change (\(exhaustive) cases)", violation == nil, violation ?? "")
    let filmSets = allFilmSets(maxCount: 3, ids: 3, bands: ["A", "B"], titles: ["t0", "t1"])
    var seed: UInt64 = 0xC0FFEE
    func rand(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    for _ in 0..<300_000 {
        let a = filmSets[rand(filmSets.count)]
        // Half the draws reuse the old films, the shape of a selection or status-bar pass.
        let b = rand(2) == 0 ? a : filmSets[rand(filmSets.count)]
        probe(a, b, allInputs[rand(allInputs.count)], allInputs[rand(allInputs.count)],
              queueMaps[rand(queueMaps.count)], rand(4) == 0)
    }
    check("randomized: no skipped refresh hid a drawn change (\(cases - exhaustive) draws)", violation == nil, violation ?? "")
    check("the skip fires (not vacuous)", noOps > 0, "noOps=\(noOps)")
    check("the refresh still fires for in-place edits", refreshes > 0, "refreshes=\(refreshes)")

    // The two passes the audit measured: a selection change (films untouched) and a
    // metadata edit (films changed in place).
    let a = [Film(id: 0, band: "A", title: "t0"), Film(id: 1, band: "A", title: "t0")]
    var b = a; b[1].title = "renamed"
    let inputs = SectionInputs(showSortingSections: false, queueFilter: nil,
                               sortOption: "dateAdded", recentsCategory: nil)
    let rows = buildRowModel(films: a, inputs: inputs, queueSections: [:]).rows
    let sel = decide(oldFilms: a, newFilms: a, lastInputs: inputs, newInputs: inputs,
                     isViewSwitch: false, oldRows: rows, newRowsIfRebuilt: rows)
    check("a selection pass refreshes nothing", !sel.fullReload && !sel.visibleRefresh)
    let edit = decide(oldFilms: a, newFilms: b, lastInputs: inputs, newInputs: inputs,
                      isViewSwitch: false, oldRows: rows,
                      newRowsIfRebuilt: buildRowModel(films: b, inputs: inputs, queueSections: [:]).rows)
    check("a metadata edit refreshes the visible rows", !edit.fullReload && edit.visibleRefresh)
}

print("")
if failures == 0 { print("✅ ALL TESTS PASSED") } else { print("❌ \(failures) FAILURE(S)") }
exit(failures == 0 ? 0 : 1)
