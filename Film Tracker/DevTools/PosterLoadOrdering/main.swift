// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Test driver for the poster-load ordering harness. See README.md.

import Foundation

/// Tally for the whole run. A type rather than three top-level `var`s: top-level
/// code cannot carry a global actor, and these are only ever touched from the
/// main actor.
@MainActor
enum Tally {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
}

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        Tally.passed += 1
        print("  ✅ \(name)")
    } else {
        Tally.failed += 1
        let d = detail()
        Tally.failures.append(d.isEmpty ? name : "\(name) — \(d)")
        print("  ❌ \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

@MainActor
func section(_ title: String) {
    print("\n\(title)")
    print(String(repeating: "─", count: title.count))
}

// MARK: - Test 1 — the ordering bug itself
//
// Two rapid film changes, both cache misses, whose disk loads complete in the
// REVERSE of the order they were requested. This is the scenario the audit
// identified: PosterCache.getImageAsync genuinely awaits disk I/O, so nothing
// guarantees that the first request finishes first.

@MainActor
func testOutOfOrderCompletion(_ implementation: HeaderModel.Implementation,
                              _ semantics: EnvironmentSemantics) async -> (displayed: String?, stamped: String?) {
    let cache = StubPosterCache()
    cache.onDisk = ["A", "B"]
    let header = HeaderModel(implementation: implementation,
                             environmentSemantics: semantics,
                             cache: cache)

    header.request("A")
    await settle()
    header.request("B")
    await settle()

    // Both loads are now suspended. Release the OLDER one last.
    cache.release("B")
    await settle()
    cache.release("A")
    await settle()

    return (header.displayedImage, header.lastLoadedPosterUID)
}

// MARK: - Test 2 — behavior preservation
//
// Every path the shipped implementation already had, asserted on the NEW model so
// the fix is shown to change ordering and nothing else.

@MainActor
func testPreservedBehaviors() async {
    // Cache hit is synchronous — no async load is ever started.
    do {
        let cache = StubPosterCache()
        cache.resident = ["A"]
        let h = HeaderModel(implementation: .new, cache: cache)
        h.request("A")
        check("cache hit displays synchronously",
              h.displayedImage == "A" && h.lastLoadedPosterUID == "A",
              "displayed=\(String(describing: h.displayedImage))")
        check("cache hit starts no async load", cache.asyncLoadsStarted.isEmpty,
              "started=\(cache.asyncLoadsStarted)")
    }

    // A nil or empty UID clears immediately.
    for empty in [nil, ""] as [String?] {
        let cache = StubPosterCache()
        cache.resident = ["A"]
        let h = HeaderModel(implementation: .new, cache: cache)
        h.request("A")
        h.request(empty)
        check("no-poster (\(empty.map { "\"\($0)\"" } ?? "nil")) clears immediately",
              h.displayedImage == nil && h.lastLoadedPosterUID == nil)
    }

    // Re-requesting the UID already displayed is a no-op, not a reload.
    do {
        let cache = StubPosterCache()
        cache.resident = ["A"]
        let h = HeaderModel(implementation: .new, cache: cache)
        h.request("A")
        let historyAfterFirst = h.displayHistory.count
        h.request("A")
        check("duplicate request does not re-publish",
              h.displayHistory.count == historyAfterFirst,
              "history=\(h.displayHistory)")
    }

    // A miss that resolves with nothing on disk publishes nil, exactly as before —
    // the placeholder is the correct outcome for a film whose poster file is gone.
    do {
        let cache = StubPosterCache()   // "A" is neither resident nor on disk
        let h = HeaderModel(implementation: .new, cache: cache)
        h.request("A")
        await settle()
        cache.release("A")
        await settle()
        check("miss with no file on disk publishes nil",
              h.displayedImage == nil && h.lastLoadedPosterUID == "A",
              "displayed=\(String(describing: h.displayedImage))")
    }

    // The ordinary single-selection case still ends up showing the right poster.
    do {
        let cache = StubPosterCache()
        cache.onDisk = ["A"]
        let h = HeaderModel(implementation: .new, cache: cache)
        h.request("A")
        await settle()
        cache.release("A")
        await settle()
        check("single miss displays its own poster", h.displayedImage == "A")
    }
}

// MARK: - Test 3 — a superseded load is abandoned, not merely ignored
//
// The old code let an obsolete disk load run to completion and then (at best)
// discarded the result. The new one cancels it, so the wasted read+decode is not
// paid for every film the user passes through.

@MainActor
func testSupersededLoadIsCanceled() async {
    let cache = StubPosterCache()
    cache.onDisk = ["A", "B"]
    let h = HeaderModel(implementation: .new, cache: cache)

    h.request("A")
    await settle()
    let taskForA = h.posterLoadTask
    h.request("B")
    await settle()

    check("superseding a load cancels the previous task",
          taskForA?.isCancelled == true,
          "isCancelled=\(String(describing: taskForA?.isCancelled))")

    // Clearing the poster entirely must cancel too — a no-poster transition can
    // supersede an in-flight miss just as another miss can.
    let taskForB = h.posterLoadTask
    h.request(nil)
    check("clearing the poster cancels the in-flight load",
          taskForB?.isCancelled == true,
          "isCancelled=\(String(describing: taskForB?.isCancelled))")

    // And the abandoned loads must not paint over the cleared state.
    cache.release("A")
    cache.release("B")
    await settle()
    check("abandoned loads never publish after a clear",
          h.displayedImage == nil,
          "displayed=\(String(describing: h.displayedImage))")
}

// MARK: - Test 4 — three-deep churn
//
// Scrolling through several films quickly. Only the last request may ever reach
// the screen, whatever order the disk answers in.

@MainActor
func testDeepChurn() async {
    for releaseOrder in [["A", "B", "C"], ["C", "B", "A"], ["B", "A", "C"]] {
        let cache = StubPosterCache()
        cache.onDisk = ["A", "B", "C"]
        let h = HeaderModel(implementation: .new, cache: cache)

        for uid in ["A", "B", "C"] {
            h.request(uid)
            await settle()
        }
        for uid in releaseOrder {
            cache.release(uid)
            await settle()
        }

        check("churn A→B→C, disk answers \(releaseOrder.joined(separator: "→")): shows C",
              h.displayedImage == "C" && h.lastLoadedPosterUID == "C",
              "displayed=\(String(describing: h.displayedImage))")
        check("churn \(releaseOrder.joined(separator: "→")): never showed a superseded poster",
              !h.displayHistory.contains("A") && !h.displayHistory.contains("B"),
              "history=\(h.displayHistory)")
    }
}

// MARK: - Driver

@MainActor
func run() async {
    print("Poster-Load Ordering Harness")
    print("============================")
    print("Models Header.loadImageFromCache(_:) before and after the ordering fix.")

    section("1. Out-of-order completion (the reported defect)")
    for semantics in EnvironmentSemantics.allCases {
        let old = await testOutOfOrderCompletion(.old, semantics)
        let new = await testOutOfOrderCompletion(.new, semantics)

        let oldCorrect = (old.displayed == "B" && old.stamped == "B")
        print("  · OLD under \(semantics.rawValue): displays " +
              "\(old.displayed.map { "\"\($0)\"" } ?? "nil"), " +
              "stamps \(old.stamped.map { "\"\($0)\"" } ?? "nil") " +
              "— \(oldCorrect ? "correct" : "WRONG (superseded poster on screen)")")

        check("NEW under \(semantics.rawValue): displays the current film's poster",
              new.displayed == "B" && new.stamped == "B",
              "displayed=\(String(describing: new.displayed)) stamped=\(String(describing: new.stamped))")
    }

    section("2. Preserved behaviors (NEW model)")
    await testPreservedBehaviors()

    section("3. Superseded loads are canceled")
    await testSupersededLoadIsCanceled()

    section("4. Three-deep churn under every completion order")
    await testDeepChurn()

    print("\n" + String(repeating: "=", count: 60))
    if Tally.failed == 0 {
        print("✅ ALL TESTS PASSED — \(Tally.passed) assertions")
    } else {
        print("❌ \(Tally.failed) FAILED, \(Tally.passed) passed")
        for f in Tally.failures { print("   • \(f)") }
    }
    print(String(repeating: "=", count: 60))
    exit(Tally.failed == 0 ? 0 : 1)
}

await run()
