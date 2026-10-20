// MARK: - DHStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only harness scenarios for the MemoryStore / DataCoordinator layer — the app's
// in-memory source of truth and the optimistic-update coordinator built on top of it.
//
// WHY THESE ARE STRUCTURAL RATHER THAN EXAMPLE-BASED
//
// The sort scenarios in DebugHarness could state an expected order literally, because a
// sort has one output. This layer does not: its correctness is a set of RELATIONSHIPS that
// must hold after any sequence of mutations, and the failures that actually occur here are
// not "the wrong answer" but "an answer that was right some mutations ago". So the checks
// are invariants and differentials:
//
//   • Invariants (`storeInvariants`) — the reverse membership index agrees with the list
//     memberships it indexes; no list references a film the store does not hold; the Hall
//     of Fame's derived order agrees with the stored positions and is dense 1..N. These are
//     asserted after EVERY mutation in a sequence, not once at the end, so a failure names
//     the operation that broke it rather than the operation that happened to be last.
//
//   • Differential (`differentialChecks`) — after a sequence of mutations, the store's
//     answers are compared against those of a FRESH store built from its own final films
//     and lists. The two must agree for every (view, sort, direction, filters) combination.
//     A fresh store has no view cache, so any disagreement is by construction a cache entry
//     that a mutation should have invalidated and did not. This is the property the layer's
//     one previously-known corruption (a poisoned empty view cached during startup) would
//     have failed, and no example-based check would have caught it.
//
// WHY MOST SCENARIOS USE AN ISOLATED STORE
//
// `MemoryStore.isolatedForTesting` gives each scenario a store that is a pure function of
// its own corpus — the same reasoning MetadataCache's isolated instance is built on. The
// exception is `store-coordinator`, which is testing DataCoordinator's own wiring (Film
// Queue exclusivity enforcement, published-state upkeep, list-cache synchronization) and
// therefore has to run against the real coordinator.
//
// SHARED METADATACACHE, AND WHY THAT IS ACCEPTABLE HERE
//
// MemoryStore names `MetadataCache.shared` directly, so an isolated store still sorts
// through the shared cache. Each scenario therefore registers its corpus there and removes
// it again on the way out. This is contained rather than ideal: the process is a sandbox
// instance with an empty library that exits seconds later, and every file the cache could
// write is inside the sandbox container. It is called out here so the coupling is a known
// limitation rather than a surprise — if MemoryStore ever takes an injected cache, these
// scenarios should stop touching the shared one.

#if DEBUG

import Foundation
import SwiftData
import SQLite3

extension DebugHarness {

    /// Scenario names owned by this file, in the order `all` runs them.
    static var storeScenarios: [String] {
        ["store-invariants", "store-hall-of-fame", "store-queue", "store-coordinator",
         "store-snapshot-mapping", "store-fingerprint-direct"]
    }

    /// Dispatch hook called by `DebugHarness.run(_:coordinator:)` before its own switch.
    /// Returns nil for a scenario this file does not own, so the caller falls through.
    static func runStoreScenario(_ scenario: String,
                                 coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "store-invariants":    return await storeInvariantsScenario()
        case "store-hall-of-fame":  return await hallOfFameScenario()
        case "store-queue":         return await queueScenario()
        case "store-coordinator":   return await coordinatorScenario(coordinator: coordinator)
        case "store-snapshot-mapping": return snapshotMappingScenario()
        case "store-fingerprint-direct": return await fingerprintDirectReadScenario()
        case "datamanager-thread": return await dataManagerThreadScenario(coordinator: coordinator)
        default:                    return nil
        }
    }

    // MARK: - Shared Invariants

    /// The properties that must hold of a MemoryStore after any mutation whatsoever.
    ///
    /// - Parameter expectQueueExclusivity: false only for the corruption-recovery cases,
    ///   which deliberately place one film in two internal Film Queue lists to prove the
    ///   read paths survive it. Everywhere else a film in two sections is a genuine defect.
    static func storeInvariants(_ store: MemoryStore, _ label: String,
                                expectQueueExclusivity: Bool = true) -> [HarnessCheck] {
        var checks: [HarnessCheck] = []
        let films = store.getAllFilmsMap()
        let lists = store.allListsForTesting
        let reverse = store.filmToListsForTesting

        // 1. Forward → reverse. Every membership recorded on a list must be recorded on the
        //    film. A gap here makes getListIDs(forFilm:) — which drives the sidebar's
        //    membership table, the Film Queue section resolution, and updateFilm's cache
        //    invalidation — silently under-report.
        var forwardMissing: [String] = []
        for list in lists {
            for filmID in list.filmIDs where !(reverse[filmID]?.contains(list.listID) ?? false) {
                forwardMissing.append("\(filmID) ∈ '\(list.listName)' but not in reverse index")
            }
        }
        checks.append(HarnessCheck(name: "\(label)/reverse-index-complete",
                                   passed: forwardMissing.isEmpty,
                                   detail: forwardMissing.prefix(3).joined(separator: "; ")))

        // 2. Reverse → forward. A reverse entry with no corresponding membership is the more
        //    dangerous direction: it survives list deletion and keeps a film "in" a list that
        //    no longer contains it.
        var reverseStale: [String] = []
        let listsByID = Dictionary(uniqueKeysWithValues: lists.map { ($0.listID, $0) })
        for (filmID, listIDs) in reverse {
            for listID in listIDs {
                guard let list = listsByID[listID] else {
                    reverseStale.append("\(filmID) → deleted list \(listID)")
                    continue
                }
                if !list.filmIDs.contains(filmID) {
                    reverseStale.append("\(filmID) → '\(list.listName)' which does not contain it")
                }
            }
        }
        checks.append(HarnessCheck(name: "\(label)/reverse-index-not-stale",
                                   passed: reverseStale.isEmpty,
                                   detail: reverseStale.prefix(3).joined(separator: "; ")))

        // 3. No phantom memberships. A list holding an ID for a film the store no longer has
        //    inflates getFilmCount(viewID:) — which counts raw filmIDs — without producing a
        //    visible row, so the count and the grid disagree until the next full reload.
        var phantoms: [String] = []
        for list in lists {
            for filmID in list.filmIDs where films[filmID] == nil {
                phantoms.append("'\(list.listName)' holds unknown film \(filmID)")
            }
        }
        checks.append(HarnessCheck(name: "\(label)/no-phantom-memberships",
                                   passed: phantoms.isEmpty,
                                   detail: phantoms.prefix(3).joined(separator: "; ")))

        // 4. Reverse index holds no entry for a film that has been deleted.
        let orphanedReverse = reverse.keys.filter { films[$0] == nil }
        checks.append(HarnessCheck(name: "\(label)/no-orphaned-reverse-entries",
                                   passed: orphanedReverse.isEmpty,
                                   detail: "\(orphanedReverse.count) orphan(s)"))

        // 5. Hall of Fame: the derived ordered list must name exactly the ranked films, in
        //    stored-position order, with positions forming an unbroken 1..N sequence. Every
        //    consumer of hallOfFameIsFull and getNextHallOfFamePosition depends on this.
        let ranked = films.values.filter { $0.hofPosition > 0 }
        let ordered = store.hallOfFameFilms
        checks.append(HarnessCheck(
            name: "\(label)/hof-list-matches-ranked-films",
            passed: Set(ordered) == Set(ranked.map(\.id)) && ordered.count == ranked.count,
            detail: "ordered \(ordered.count), ranked \(ranked.count)"))

        let positions = ordered.compactMap { films[$0]?.hofPosition }
        let dense = positions.isEmpty || positions == Array(1...positions.count)
        checks.append(HarnessCheck(name: "\(label)/hof-positions-dense",
                                   passed: dense,
                                   detail: positions.isEmpty ? "empty" : "\(positions.prefix(12))…"))

        // 6. Film Queue mutual exclusivity — a film in two sections would appear once in the
        //    grid (the grouping dedupes) but be counted once per section by any caller that
        //    sums section membership, and would flip section on any change to the queue.
        if expectQueueExclusivity {
            let multi = films.keys.filter {
                (reverse[$0] ?? []).intersection(FilmQueue.allListIDs).count > 1
            }
            checks.append(HarnessCheck(name: "\(label)/queue-exclusive",
                                       passed: multi.isEmpty,
                                       detail: "\(multi.count) film(s) in more than one section"))
        }

        return checks.map(classify)
    }

    /// The (view, sort, direction, filters) matrix every differential is evaluated over.
    /// Deliberately covers the three structurally distinct base-ID paths in
    /// `MemoryStore.getFilms` — whole-library, a single list, and the section-grouped Film
    /// Queue — rather than every ViewIdentifier case, since the rest resolve to the same
    /// whole-library path.
    private static func viewMatrix(listIDs: [UUID]) -> [ViewIdentifier] {
        [.allFilms, .search, .filmQueue, .unwatched(.unwatched)] + listIDs.map { .list($0) }
    }

    private static let sortMatrix: [SortOption] = [.title, .rating, .viewCount, .lastViewed]
    private static let filterMatrix: [Set<FilterOption>] = [
        [], [.watched], [.unwatched], [.purchased], [.unpurchased], [.watched, .purchased],
    ]

    /// Compares a mutated store against a fresh one built from its own final state.
    ///
    /// The fresh store has an empty view cache by construction, so it can only answer from
    /// the underlying dictionaries. Any combination where the two disagree is therefore a
    /// stale cache entry in the mutated store — a missed invalidation — and not a
    /// disagreement about what the correct answer is.
    static func differentialChecks(_ store: MemoryStore, _ label: String) -> [HarnessCheck] {
        let fresh = MemoryStore.isolatedForTesting(
            films: Array(store.getAllFilmsMap().values), lists: store.allListsForTesting)

        let listIDs = store.allListsForTesting
            .filter { !FilmQueue.isInternalList($0.listID) }
            .map(\.listID)
            .sorted { $0.uuidString < $1.uuidString }

        var mismatches: [String] = []
        var comparisons = 0
        for viewID in viewMatrix(listIDs: listIDs) {
            for option in sortMatrix {
                for direction in SortDirection.allCases {
                    for filters in filterMatrix {
                        let cached = store.getFilms(viewID: viewID, sortOption: option,
                                                    direction: direction, filterOptions: filters)
                        let reference = fresh.getFilms(viewID: viewID, sortOption: option,
                                                       direction: direction, filterOptions: filters)
                        comparisons += 1
                        if cached.map(\.id) != reference.map(\.id) {
                            mismatches.append("\(viewID.description)/\(option.rawValue)/"
                                + "\(direction.rawValue)/\(filters.count)f: "
                                + "\(cached.count) vs \(reference.count)")
                        } else if zip(cached, reference).contains(where: { $0.0.name != $0.1.name }) {
                            // Same ordering of IDs but different snapshot content: the cached
                            // array holds pre-mutation VALUES. MemoryStore caches
                            // [FilmSnapshot], not [UUID], so a missed invalidation can leave
                            // the right films in the right order carrying stale fields.
                            mismatches.append("\(viewID.description)/\(option.rawValue): stale snapshot values")
                        }
                    }
                }
            }
        }

        return [classify(HarnessCheck(
            name: "\(label)/matches-fresh-store",
            passed: mismatches.isEmpty,
            detail: mismatches.isEmpty
                ? "\(comparisons) view combinations identical to a store with no cache"
                : "\(mismatches.count) of \(comparisons) differ — " + mismatches.prefix(4).joined(separator: " | ")))]
    }

    // MARK: - Corpus

    /// A corpus plus the lists it is distributed across: three user lists and the three
    /// internal Film Queue sections, which is the shape of a real library rather than a
    /// bare film collection.
    private static func storeCorpus(count: Int, seed: UInt64)
        -> (films: [FilmSnapshot], lists: [MemoryList]) {
        let films = standardCorpus(count: count, seed: seed)
        var generator = SeededGenerator(seed: seed &+ 1)

        var lists: [MemoryList] = []
        for index in 0..<3 {
            var members = Set<UUID>()
            for film in films where Int.random(in: 0...4, using: &generator) == 0 {
                members.insert(film.id)
            }
            lists.append(MemoryList(listID: UUID(), listName: "User List \(index)",
                                    displayOrder: index, sortFilterOptions: [], filmIDs: members))
        }

        // Queue membership is built exclusively — one section per film — because that is the
        // invariant every add path enforces, and seeding a violation would make the baseline
        // check fail for a reason the corpus, not the code, is responsible for.
        var claimed = Set<UUID>()
        for section in FilmQueueSection.allCases {
            var members = Set<UUID>()
            for film in films where !claimed.contains(film.id)
                && Int.random(in: 0...9, using: &generator) == 0 {
                members.insert(film.id)
                claimed.insert(film.id)
            }
            lists.append(MemoryList(listID: section.listID, listName: section.displayName,
                                    displayOrder: FilmQueue.displayOrder(for: section),
                                    sortFilterOptions: [], filmIDs: members))
        }
        return (films, lists)
    }

    /// Registers a corpus with the shared MetadataCache so sorts can resolve it, and returns
    /// a closure that removes it again. See the file header on why the shared instance.
    private static func registerMetadata(_ films: [FilmSnapshot]) -> () -> Void {
        for film in films { MetadataCache.shared.addFilm(film) }
        let ids = Set(films.map(\.id))
        return { MetadataCache.shared.removeFilms(ids) }
    }

    // MARK: - Scenario: Store Invariants

    /// Drives a realistic mutation sequence through the real store methods, asserting the
    /// structural invariants after every step and the differential after each phase.
    private static func storeInvariantsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-invariants")

        let (corpus, lists) = storeCorpus(count: 400, seed: 0x5707_0001)
        let cleanup = registerMetadata(corpus)
        defer { cleanup() }

        let store = MemoryStore.isolatedForTesting(films: corpus, lists: lists)
        let userListIDs = lists.filter { !FilmQueue.isInternalList($0.listID) }.map(\.listID)

        r.checks.append(contentsOf: storeInvariants(store, "baseline"))
        r.checks.append(contentsOf: differentialChecks(store, "baseline"))

        // --- Readiness gate ------------------------------------------------------------
        // A store that has not finished Phase 2 must answer empty AND must not cache that
        // answer. Caching it was a session-long corruption: nothing invalidates a view cache
        // on initialization, so the poisoned entry outlived the condition that created it.
        let cold = MemoryStore()
        let coldResult = cold.getFilms(viewID: .allFilms, sortOption: .title,
                                       direction: .ascending, filterOptions: [])
        r.check("uninitialized-returns-empty", coldResult.isEmpty, "\(coldResult.count) films")
        r.check("uninitialized-does-not-cache", cold.cachedViewCountForTesting == 0,
                "\(cold.cachedViewCountForTesting) cache entries written before readiness")

        // --- Warm the cache, then mutate -------------------------------------------------
        // Every combination is requested first so that each subsequent mutation is being
        // checked against a fully populated cache. A missed invalidation is invisible against
        // a cold cache, which is exactly why the mutation tests below are ordered this way.
        _ = differentialChecks(store, "warm-up")
        let warmEntries = store.cachedViewCountForTesting
        r.metric("view-cache-entries-after-full-matrix", Double(warmEntries), "count")

        // The cache has no eviction policy: an entry is created per distinct (view, sort,
        // direction, filters) request and removed only by a mutation that invalidates it. It
        // holds [FilmSnapshot] — VALUES, not IDs — so each entry costs one inline copy of the
        // struct per film on top of the shared String/Array storage. Recorded as numbers
        // rather than asserted: the ceiling depends on how many combinations a session
        // actually visits, which is a usage question, not a correctness one. The figures are
        // here so the cost is visible if a library or a session ever makes it matter.
        r.metric("film-snapshot-inline-size", Double(MemoryLayout<FilmSnapshot>.stride), "bytes")
        r.metric("view-cache-inline-bytes-after-full-matrix",
                 Double(warmEntries * store.totalFilmCount * MemoryLayout<FilmSnapshot>.stride),
                 "bytes")

        // 1. Scalar edit to a sort key. Must reorder every whole-library view.
        if var film = store.getAllFilmsMap().values.first(where: { $0.userRating < 5 }) {
            film.userRating = 5
            film.name = "ZZZ Renamed Specimen"
            store.updateFilm(film)
            r.checks.append(contentsOf: storeInvariants(store, "after-update"))
            r.checks.append(contentsOf: differentialChecks(store, "after-update"))

            let byRating = store.getFilms(viewID: .allFilms, sortOption: .rating,
                                          direction: .descending, filterOptions: [])
            r.check("update-visible-in-sorted-view",
                    byRating.first(where: { $0.id == film.id })?.userRating == 5,
                    "edited film carries its new rating in a cached view")
        } else {
            r.check("update-specimen-available", false, "no film with rating < 5 in corpus")
        }

        // 2. List membership add/remove, including a stale ID.
        let listID = userListIDs[0]
        let candidates = Array(store.getAllFilmsMap().keys.prefix(20))
        store.addFilmsToList(filmIDs: Set(candidates), listID: listID)
        r.checks.append(contentsOf: storeInvariants(store, "after-list-add"))
        r.checks.append(contentsOf: differentialChecks(store, "after-list-add"))

        let phantomID = UUID()
        let beforePhantom = store.getList(listID)?.filmIDs.count ?? 0
        store.addFilmsToList(filmIDs: [phantomID], listID: listID)
        r.check("phantom-film-id-rejected",
                store.getList(listID)?.filmIDs.contains(phantomID) == false
                    && store.getList(listID)?.filmIDs.count == beforePhantom,
                "a stale ID from a deferred add never enters a list")

        // A phantom mixed in with real IDs must not take the valid ones down with it — the
        // guard filters rather than aborts, and this is the case that separates the two.
        let mixed = Set(store.getAllFilmsMap().keys.prefix(3)).union([UUID()])
        store.addFilmsToList(filmIDs: mixed, listID: userListIDs[1])
        let addedReal = mixed.filter { store.getAllFilmsMap()[$0] != nil }
        r.check("phantom-does-not-block-valid-adds",
                addedReal.allSatisfy { store.filmExists(filmID: $0, inList: userListIDs[1]) },
                "\(addedReal.count) valid ID(s) added alongside one phantom")

        store.removeFilmsFromList(filmIDs: Set(candidates.prefix(10)), listID: listID)
        r.checks.append(contentsOf: storeInvariants(store, "after-list-remove"))
        r.checks.append(contentsOf: differentialChecks(store, "after-list-remove"))

        // 3. List rename must be visible through getAllLists immediately — the sorted-lists
        //    cache holds value-type copies, so a missed invalidation leaves the sidebar
        //    showing the old name until the next unrelated mutation.
        store.updateList(listID: listID, name: "Renamed List", displayOrder: nil,
                         sortFilterOptions: nil)
        r.check("list-rename-visible",
                store.getAllLists().first(where: { $0.listID == listID })?.listName == "Renamed List",
                "getAllLists reflects the rename without an intervening mutation")

        // 4. Film deletion — the operation that touches the most derived state at once.
        let doomed = Set(store.getAllFilmsMap().keys.prefix(25))
        let countBefore = store.totalFilmCount
        store.deleteFilms(ids: doomed)
        r.check("delete-count", store.totalFilmCount == countBefore - doomed.count,
                "\(countBefore) → \(store.totalFilmCount)")
        r.checks.append(contentsOf: storeInvariants(store, "after-delete"))
        r.checks.append(contentsOf: differentialChecks(store, "after-delete"))
        r.check("deleted-films-absent-from-views",
                store.getFilms(viewID: .allFilms, sortOption: .title, direction: .ascending,
                               filterOptions: []).allSatisfy { !doomed.contains($0.id) },
                "no deleted film survives in a cached view")

        // 5. Deleting a film a second time, and deleting an unknown ID, must both be inert.
        let stableCount = store.totalFilmCount
        store.deleteFilms(ids: doomed)
        store.deleteFilms(ids: [UUID()])
        r.check("delete-is-idempotent", store.totalFilmCount == stableCount,
                "\(stableCount) → \(store.totalFilmCount)")
        r.checks.append(contentsOf: storeInvariants(store, "after-redundant-delete"))

        // 6. Updating a film the store does not hold must not create it. `updateFilm` is
        //    reached from rollback paths where the film may have been deleted in between.
        let ghost = makeSnapshot(name: "Ghost")
        let preGhost = store.totalFilmCount
        store.updateFilm(ghost)
        r.check("update-of-unknown-film-is-inert",
                store.totalFilmCount == preGhost && store.getFilm(ghost.id) == nil,
                "\(preGhost) → \(store.totalFilmCount)")

        // 7. List deletion must leave no reverse-index residue.
        store.deleteList(listID: userListIDs[2])
        r.check("deleted-list-unreachable", store.getList(userListIDs[2]) == nil, "")
        r.checks.append(contentsOf: storeInvariants(store, "after-list-delete"))
        r.checks.append(contentsOf: differentialChecks(store, "after-list-delete"))

        // 8. Restoring a deleted list — the rollback path — must rebuild the reverse index.
        //    Restored with its ORIGINAL membership, which by now includes films that have
        //    since been deleted: that is exactly the state a rollback arriving after an
        //    unrelated deletion produces, and the invariants must survive it.
        if let original = lists.first(where: { $0.listID == userListIDs[2] }) {
            store.restoreList(original)
            let restoredPhantoms = (store.getList(userListIDs[2])?.filmIDs ?? [])
                .filter { store.getFilm($0) == nil }
            r.check("restored-list-carries-no-phantoms", restoredPhantoms.isEmpty,
                    restoredPhantoms.isEmpty
                        ? "restore filtered membership against the current film set"
                        : "\(restoredPhantoms.count) membership(s) for film(s) deleted while the list was gone — "
                            + "inflates getFilmCount(viewID:) with rows that cannot render")
            r.checks.append(contentsOf: storeInvariants(store, "after-list-restore"))
        }

        // 9. restoreFilm — the update-rollback path. It replaces a whole snapshot, hofPosition
        //    included, so it must reconcile the derived Hall of Fame list rather than assume
        //    no caller ever rolls a rank back through it.
        if var ranked = store.getAllFilmsMap().values.first(where: { $0.hofPosition == 0 }) {
            let id = ranked.id
            _ = store.addToHallOfFame(id)
            let preRestore = store.hallOfFameFilms.count
            ranked.hofPosition = 0
            store.restoreFilm(filmID: id, from: ranked)
            r.check("restore-film-reconciles-hof",
                    store.hallOfFameFilms.count == preRestore - 1
                        && !store.hallOfFameFilms.contains(id),
                    "\(preRestore) → \(store.hallOfFameFilms.count) after a snapshot restore that cleared a rank")
            r.checks.append(contentsOf: storeInvariants(store, "after-restore-film"))
        }

        // 10. Pre-warm agreement. finalizeInitialization pre-sorts the first view off
        //     MainActor and writes it straight into the view cache, then publishes it as
        //     `films` without going through performLoad. If that entry disagreed with what
        //     the same request computes normally, the first frame would show one ordering and
        //     the first navigation another — and because the entry is cached, the wrong one
        //     would persist. The key it writes must also be the key the next request builds.
        let prewarmStore = MemoryStore.isolatedForTesting(
            films: Array(store.getAllFilmsMap().values), lists: store.allListsForTesting)
        let prewarmed = await prewarmStore.prewarmInitialView(
            sortOption: .rating, direction: .descending, filterOptions: [.watched])
        let entriesAfterPrewarm = prewarmStore.cachedViewCountForTesting
        let requested = prewarmStore.getFilms(viewID: .allFilms, sortOption: .rating,
                                              direction: .descending, filterOptions: [.watched])
        r.check("prewarm-matches-equivalent-request",
                prewarmed.map(\.id) == requested.map(\.id),
                "\(prewarmed.count) pre-warmed vs \(requested.count) requested")
        r.check("prewarm-key-is-hit-not-recomputed",
                prewarmStore.cachedViewCountForTesting == entriesAfterPrewarm,
                "the follow-up request added \(prewarmStore.cachedViewCountForTesting - entriesAfterPrewarm) cache entry(ies); "
                    + "a non-zero value means the pre-warm wrote a key the request does not build")
        let prewarmReference = MemoryStore.isolatedForTesting(
            films: Array(store.getAllFilmsMap().values), lists: store.allListsForTesting)
        r.check("prewarm-matches-fresh-store",
                prewarmed.map(\.id) == prewarmReference.getFilms(
                    viewID: .allFilms, sortOption: .rating, direction: .descending,
                    filterOptions: [.watched]).map(\.id),
                "the published first frame is the ordering a normal load produces")

        r.metric("view-cache-entries-final", Double(store.cachedViewCountForTesting), "count")
        r.metric("films-final", Double(store.totalFilmCount), "count")
        return r
    }

    // MARK: - Scenario: Hall of Fame

    /// The Hall of Fame is the store's only ordered, densely-numbered collection, and the
    /// only place where a derived array and a stored scalar must be kept in agreement by
    /// hand. Every method that writes a position is exercised here, including the ones
    /// reached only from rollback.
    private static func hallOfFameScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-hall-of-fame")

        let corpus = standardCorpus(count: 260, seed: 0x40F_0002)
        let cleanup = registerMetadata(corpus)
        defer { cleanup() }
        let store = MemoryStore.isolatedForTesting(films: corpus, lists: [])
        let ids = corpus.map(\.id)

        // --- Add ------------------------------------------------------------------------
        var assigned: [Int] = []
        for id in ids.prefix(12) {
            if let position = store.addToHallOfFame(id) { assigned.append(position) }
        }
        r.check("add-assigns-sequential-positions", assigned == Array(1...12), "\(assigned)")
        r.check("add-order-preserved", Array(store.hallOfFameFilms) == Array(ids.prefix(12)), "")
        r.checks.append(contentsOf: storeInvariants(store, "hof-after-add"))

        // Re-adding a ranked film must be refused: it would occupy a second slot while
        // keeping the first, gapping the sequence and making the next add collide.
        let readd = store.addToHallOfFame(ids[0])
        r.check("re-add-refused", readd == nil, "returned \(String(describing: readd))")
        r.check("re-add-changed-nothing", store.hallOfFameFilms.count == 12,
                "\(store.hallOfFameFilms.count) members")

        // An unknown film cannot be ranked.
        r.check("add-unknown-film-refused", store.addToHallOfFame(UUID()) == nil, "")

        // --- Batch remove from the middle -----------------------------------------------
        let removed: Set<UUID> = [ids[2], ids[5], ids[6]]
        let shifted = store.removeFromHallOfFame(removed)
        r.check("remove-reports-shifted-survivors", shifted != nil,
                "returned \(shifted?.count ?? -1) shifted survivor(s)")
        r.check("remove-preserves-relative-order",
                store.hallOfFameFilms == ids.prefix(12).filter { !removed.contains($0) },
                "survivors keep their relative ranking after compaction")
        r.checks.append(contentsOf: storeInvariants(store, "hof-after-remove"))

        // Removing films that hold no position must report "nothing written" rather than an
        // empty shift list — the caller uses that distinction to decide whether to persist.
        r.check("remove-of-unranked-returns-nil",
                store.removeFromHallOfFame(Set(ids.suffix(3))) == nil, "")

        // Removing the LAST member shifts nobody; the empty array must not be confused with
        // nil, or a real removal would skip its own persistence.
        if let last = store.hallOfFameFilms.last {
            let tailShift = store.removeFromHallOfFame(last)
            r.check("remove-last-returns-empty-not-nil", tailShift?.isEmpty == true,
                    "returned \(String(describing: tailShift?.count))")
        }

        // --- Reorder, with a hostile request ---------------------------------------------
        // Duplicates, an unknown UUID, and an unranked film are all things a stale or buggy
        // caller can hand this method. None may promote, drop, or duplicate a member.
        let ranked = store.hallOfFameFilms
        let hostile = [ranked[3], ranked[0], ranked[0], UUID(), ids[250], ranked[1]]
        let applied = store.reorderHallOfFame(hostile)
        r.check("reorder-drops-unknown-and-unranked",
                Set(applied) == Set(ranked),
                "membership unchanged: \(applied.count) vs \(ranked.count)")
        r.check("reorder-collapses-duplicates",
                Set(applied).count == applied.count, "no film appears twice")
        // The requested films keep their requested RELATIVE order. Their absolute positions
        // are not asserted, and deliberately so: a partial request renumbers only the films
        // it names, so an omitted member retains a position that can now collide with a
        // newly-assigned one, and compaction resolves that collision by UUID. That is the
        // documented self-healing behavior — a stale caller loses its interleaving, not its
        // members — and every real caller passes the complete order.
        let requestedInOrder = [ranked[3], ranked[0], ranked[1]]
        let appliedIndices = requestedInOrder.compactMap { applied.firstIndex(of: $0) }
        r.check("reorder-honors-requested-relative-order",
                appliedIndices.count == 3
                    && zip(appliedIndices, appliedIndices.dropFirst()).allSatisfy { $0 < $1 },
                "explicitly ordered films appear in the requested order at \(appliedIndices)")
        r.check("reorder-leads-with-requested-films",
                Array(applied.prefix(2)) == [ranked[3], ranked[0]],
                "the first requested films take the first slots outright")
        r.check("reorder-retains-omitted-members",
                applied.count == ranked.count,
                "a ranked film absent from the request is placed by its retained position, not dropped")
        r.checks.append(contentsOf: storeInvariants(store, "hof-after-reorder"))

        // Determinism: the same hostile request applied to the same state must produce the
        // same order every time. Compaction breaks position collisions by UUID precisely so
        // that it does — a rule that fell back on an unstable sort would reshuffle rows for
        // no visible reason between two identical operations.
        let repeated = store.reorderHallOfFame(hostile)
        r.check("reorder-is-deterministic", repeated == applied,
                "identical request over identical state yields an identical ranking")

        // An empty reorder is a no-op that must return the current order, not clear it.
        r.check("empty-reorder-is-noop",
                store.reorderHallOfFame([]) == store.hallOfFameFilms, "")

        // --- Deleting a ranked film -------------------------------------------------------
        let victim = store.hallOfFameFilms[2]
        let preDelete = store.hallOfFameFilms
        let compacted = store.deleteFilms(ids: [victim])
        r.check("delete-compacts-ranking",
                store.hallOfFameFilms == preDelete.filter { $0 != victim },
                "deleted member leaves no phantom in the ordered list")
        r.check("delete-reports-compacted-ids", !compacted.isEmpty || preDelete.last == victim,
                "\(compacted.count) survivor position(s) reported for persistence")
        r.checks.append(contentsOf: storeInvariants(store, "hof-after-delete"))

        // --- Restore (the deletion-rollback path) -----------------------------------------
        var restore: [UUID: Int] = [:]
        for (index, id) in preDelete.enumerated() { restore[id] = index + 1 }
        store.addFilm(corpus.first { $0.id == victim }!)
        store.restoreHofPositions(restore)
        r.check("restore-reinstates-exact-ranking", store.hallOfFameFilms == preDelete,
                "the pre-deletion ranking is recoverable exactly")
        r.checks.append(contentsOf: storeInvariants(store, "hof-after-restore"))

        // --- Capacity ----------------------------------------------------------------------
        // The 200-member cap and the density rule interact: a deletion that left the count
        // inflated would disable the FilmSheet's toggle permanently.
        let fresh = MemoryStore.isolatedForTesting(films: corpus, lists: [])
        for id in ids.prefix(200) { _ = fresh.addToHallOfFame(id) }
        r.check("full-at-200", fresh.hallOfFameIsFull, "\(fresh.hallOfFameFilms.count) members")
        r.check("add-refused-when-full", fresh.addToHallOfFame(ids[200]) == nil, "")
        fresh.deleteFilms(ids: [ids[7]])
        r.check("not-full-after-deleting-a-member", !fresh.hallOfFameIsFull,
                "\(fresh.hallOfFameFilms.count) members after one deletion")
        let readmitted = fresh.addToHallOfFame(ids[200])
        r.check("slot-reusable-after-deletion", readmitted == 200,
                "next position = \(String(describing: readmitted)), expected 200")
        r.checks.append(contentsOf: storeInvariants(fresh, "hof-capacity"))

        return r
    }

    // MARK: - Scenario: Film Queue

    /// The Film Queue is the one view whose ordering is not a plain sort: films are grouped
    /// into sections, and the same canonical-section rule is implemented twice — once in
    /// MemoryStore for the grouping, once in DataCoordinator for the divider break points.
    /// The two disagreeing would draw section labels over the wrong films.
    private static func queueScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-queue")

        let (corpus, lists) = storeCorpus(count: 300, seed: 0x9_0EE3)
        let cleanup = registerMetadata(corpus)
        defer { cleanup() }
        let store = MemoryStore.isolatedForTesting(films: corpus, lists: lists)

        // Grouping: every queued film appears exactly once, sections appear in queue order,
        // and each section's interior is sorted by the requested key.
        for option in sortMatrix {
            for direction in SortDirection.allCases {
                let grouped = store.filmQueueSectionGroupedIDs(sortOption: option, direction: direction)
                let union = store.filmQueueFilmIDs()
                let label = "\(option.rawValue)/\(direction.rawValue)"
                r.check("queue-grouping-complete:\(label)",
                        Set(grouped) == union && grouped.count == union.count,
                        "\(grouped.count) grouped, \(union.count) in union, \(Set(grouped).count) unique")

                // Section order: the sequence of section indices must be non-decreasing.
                let sections = grouped.map { id -> Int in
                    let internalIDs = (store.filmToListsForTesting[id] ?? []).intersection(FilmQueue.allListIDs)
                    return internalIDs.compactMap { FilmQueueSection(listID: $0)?.queueOrder }.min() ?? 99
                }
                r.check("queue-sections-in-order:\(label)",
                        zip(sections, sections.dropFirst()).allSatisfy { $0 <= $1 },
                        "section indices must never go backwards")

                // Interior ordering: each section, taken alone, must equal the flat sort of
                // its own members. A grouping that merely concatenated sets would fail here.
                var index = 0
                var interiorOK = true
                for section in FilmQueueSection.allCases.sorted(by: { $0.queueOrder < $1.queueOrder }) {
                    let members = grouped[index...].prefix { id in
                        let internalIDs = (store.filmToListsForTesting[id] ?? [])
                            .intersection(FilmQueue.allListIDs)
                        return internalIDs.compactMap { FilmQueueSection(listID: $0)?.queueOrder }.min()
                            == section.queueOrder
                    }
                    if Array(members) != MetadataCache.shared.sort(Array(members), by: option, direction: direction) {
                        interiorOK = false
                    }
                    index += members.count
                }
                r.check("queue-section-interiors-sorted:\(label)", interiorOK,
                        "each section is internally ordered by the requested key")
            }
        }

        // Count agreement: the Film Queue's reported count must equal the number of rows the
        // grouped view actually produces.
        r.check("queue-count-matches-grouping",
                store.filmQueueFilmIDs().count
                    == store.filmQueueSectionGroupedIDs(sortOption: .title, direction: .ascending).count,
                "count \(store.filmQueueFilmIDs().count)")

        // --- Corruption recovery -----------------------------------------------------------
        // A restore from a pre-exclusivity backup can place one film in two sections. Both
        // resolvers must agree on a single canonical section, and the film must still render
        // exactly once. This is the case the two implementations are documented to survive.
        guard let dual = store.getList(FilmQueueSection.later.listID)?.filmIDs.first else {
            r.check("corruption-specimen-available", false, "no film in the Later section")
            return r
        }
        store.addFilmsToList(filmIDs: [dual], listID: FilmQueueSection.upNext.listID)
        r.checks.append(contentsOf: storeInvariants(store, "queue-corrupted",
                                                    expectQueueExclusivity: false))

        let groupedCorrupt = store.filmQueueSectionGroupedIDs(sortOption: .title, direction: .ascending)
        r.check("dual-membership-renders-once",
                groupedCorrupt.filter { $0 == dual }.count == 1,
                "\(groupedCorrupt.filter { $0 == dual }.count) occurrence(s)")
        r.check("dual-membership-count-agrees",
                store.filmQueueFilmIDs().count == groupedCorrupt.count,
                "count \(store.filmQueueFilmIDs().count) vs \(groupedCorrupt.count) rows")

        // The canonical section is the lowest queueOrder among the film's memberships. This
        // is the rule DataCoordinator.filmQueueSection(forFilm:) implements independently.
        let canonical = (store.filmToListsForTesting[dual] ?? [])
            .intersection(FilmQueue.allListIDs)
            .compactMap { FilmQueueSection(listID: $0) }
            .min { $0.queueOrder < $1.queueOrder }
        r.check("canonical-section-is-lowest-order", canonical == .upNext,
                "resolved to \(canonical?.displayName ?? "nil")")

        // Removing the queue's own list must not strand the reverse index.
        store.removeFilmsFromList(filmIDs: [dual], listID: FilmQueueSection.upNext.listID)
        r.checks.append(contentsOf: storeInvariants(store, "queue-after-heal"))
        r.check("heal-restores-single-section",
                (store.filmToListsForTesting[dual] ?? []).intersection(FilmQueue.allListIDs).count == 1,
                "back to exactly one section")

        r.checks.append(contentsOf: differentialChecks(store, "queue"))
        return r
    }

    // MARK: - Scenario: Coordinator

    /// Exercises DataCoordinator's own wiring against the live sandbox library: the published
    /// state it maintains alongside the store, its Film Queue exclusivity enforcement, and
    /// the list cache the sidebar reads. Runs against the real coordinator because that
    /// wiring is precisely what an isolated store cannot exercise.
    ///
    /// Every film it creates is deleted before it returns, so the sandbox library ends the
    /// run in the state it began — which matters because the sandbox container persists
    /// between runs and a leftover corpus would silently change the next run's baseline.
    private static func coordinatorScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-coordinator")

        let store = coordinator.memoryStoreForTesting
        let baselineFilms = store.totalFilmCount
        r.check("coordinator-initialized", coordinator.isInitialized, "")
        r.check("library-state-reliable", !coordinator.isLibraryStateUnreliable,
                "a scenario run against an unreliable store would prove nothing")

        // The three internal Film Queue lists must exist by the time initialization finishes:
        // the FilmSheet's picker writes to them directly and has no create path of its own.
        for section in FilmQueueSection.allCases {
            r.check("queue-list-bootstrapped:\(section.rawValue)",
                    coordinator.getList(section.listID) != nil, "")
        }
        r.check("internal-lists-hidden-from-user-enumeration",
                coordinator.getAllLists().allSatisfy { !FilmQueue.isInternalList($0.listID) },
                "\(coordinator.getAllLists().count) user list(s) visible")

        // --- Corpus ------------------------------------------------------------------------
        let corpus = standardCorpus(count: 40, seed: 0xC007_D1AA)
        let corpusIDs = Set(corpus.map(\.id))
        for film in corpus { store.addFilm(film) }

        r.check("published-total-tracks-store",
                store.totalFilmCount == baselineFilms + corpus.count,
                "\(baselineFilms) + \(corpus.count) = \(store.totalFilmCount)")

        // --- Film Queue exclusivity, through the coordinator ---------------------------------
        // The synchronous drag-and-drop entry point, which is the path that previously allowed
        // a dropped film to occupy two sections at once.
        let subject = corpus[0].id
        _ = coordinator.addFilmsToList(filmIDs: [subject], listID: FilmQueueSection.later.listID)
        r.check("queue-add-lands-in-requested-section",
                coordinator.filmQueueSection(forFilm: subject) == .later,
                "resolved to \(coordinator.filmQueueSection(forFilm: subject)?.displayName ?? "nil")")

        _ = coordinator.addFilmsToList(filmIDs: [subject], listID: FilmQueueSection.upNext.listID)
        r.check("queue-add-enforces-exclusivity",
                coordinator.filmQueueListIDs(forFilm: subject).count == 1,
                "\(coordinator.filmQueueListIDs(forFilm: subject).count) section membership(s) after a cross-section add")
        r.check("queue-add-moves-rather-than-duplicates",
                coordinator.filmQueueSection(forFilm: subject) == .upNext,
                "the film moved to the newly requested section")

        // Both resolvers must agree — MemoryStore's grouping and the coordinator's per-film
        // section, which the gallery uses to place its divider bands.
        let grouped = store.filmQueueSectionGroupedIDs(sortOption: .title, direction: .ascending)
        let disagreements = grouped.filter { id in
            let fromStore = (store.filmToListsForTesting[id] ?? [])
                .intersection(FilmQueue.allListIDs)
                .compactMap { FilmQueueSection(listID: $0) }
                .min { $0.queueOrder < $1.queueOrder }
            return fromStore != coordinator.filmQueueSection(forFilm: id)
        }
        r.check("section-resolvers-agree", disagreements.isEmpty,
                "\(disagreements.count) of \(grouped.count) films resolve differently in the two implementations")

        // --- Sidebar list cache -------------------------------------------------------------
        // cachedLists carries the film counts the sidebar renders and the context menu gates
        // on; it is rebuilt by hand at every mutation site rather than derived on read.
        let cachedCounts = Dictionary(uniqueKeysWithValues:
            coordinator.cachedLists.map { ($0.listID, $0.filmCount) })
        let liveCounts = Dictionary(uniqueKeysWithValues:
            coordinator.getAllLists().map { ($0.listID, $0.filmIDs.count) })
        r.check("cached-list-counts-match-store", cachedCounts == liveCounts,
                "cached \(cachedCounts.count) list(s), live \(liveCounts.count)")

        // --- Deletion, through the coordinator ------------------------------------------------
        await coordinator.deleteFilms(withIDs: corpusIDs)
        r.check("delete-restores-baseline-count",
                store.totalFilmCount == baselineFilms,
                "\(store.totalFilmCount) vs baseline \(baselineFilms)")
        r.check("delete-clears-queue-membership",
                coordinator.filmQueueListIDs(forFilm: subject).isEmpty,
                "a deleted film leaves no queue membership behind")
        r.check("delete-published-flag-consistent",
                coordinator.totalFilmCount == store.totalFilmCount,
                "published \(coordinator.totalFilmCount), store \(store.totalFilmCount)")

        let cachedAfter = Dictionary(uniqueKeysWithValues:
            coordinator.cachedLists.map { ($0.listID, $0.filmCount) })
        let liveAfter = Dictionary(uniqueKeysWithValues:
            coordinator.getAllLists().map { ($0.listID, $0.filmIDs.count) })
        r.check("cached-list-counts-match-after-delete", cachedAfter == liveAfter,
                "a deletion that empties a list must not leave a stale sidebar count")

        // --- Settings debounce flush ------------------------------------------------------
        // SettingsManager writes on a five-second debounce. The quit path calls
        // flushPendingSettingsSync() to force a pending write out, because a preference
        // changed inside that window otherwise never reached SettingsObject — leaving the
        // next export/backup carrying the stale value and a restore from it silently
        // reverting the setting. Asserted here end to end: change a preference, flush well
        // inside the debounce window, and read the row back out of the database.
        //
        // Must be a member of Preferences.rotationThresholdOptions; the setter silently
        // clamps anything else to 12.
        let originalThreshold = Preferences.defaultRotationThreshold
        let probeThreshold = (originalThreshold == 36) ? 60 : 36

        // A film with no override follows the default, so its cached rotation date must
        // follow a change to it — the same preferencesChanged event drives the refresh.
        let rotationProbe = makeSnapshot(name: "Rotation Probe", lastWatched: "2020.03.15")
        store.addFilm(rotationProbe)
        func cachedRotationMatches(_ months: Int) -> (Bool, String) {
            let expected = parseDate(from: rotationProbe.lastWatched)
                .flatMap { rotationEligibilityDate(from: $0, months: months) }
            let cached = MetadataCache.shared.metadata[rotationProbe.id]?.rotationDate
            return (expected != nil && cached == expected,
                    "cached \(String(describing: cached)), expected \(String(describing: expected)) for \(months) months")
        }
        let before = cachedRotationMatches(originalThreshold)
        r.check("rotation-cache-follows-default:before", before.0, before.1)

        Preferences.defaultRotationThreshold = probeThreshold
        // postPreferenceChangedEvent hops through a Task, and the Combine sink that arms
        // the debounce runs on the turn after that, so give both a moment to land. The
        // refresh they start builds its entries off the main actor; wait for it to finish.
        try? await Task.sleep(for: .milliseconds(120))
        await coordinator.awaitRotationThresholdRefreshForTesting()
        let after = cachedRotationMatches(probeThreshold)
        r.check("rotation-cache-follows-default:changed", after.0, after.1)
        await coordinator.flushPendingSettingsSync()

        let flushed = try? await coordinator.loadSettings()
        r.check("settings-flush-persists-pending-change",
                flushed?.defaultRotationThreshold == probeThreshold,
                "database holds \(String(describing: flushed?.defaultRotationThreshold)), "
                    + "expected \(probeThreshold) — a pending debounced write was lost")

        // Restore the session value, and flush that too so nothing is left pending for a
        // later scenario to trip over.
        Preferences.defaultRotationThreshold = originalThreshold
        try? await Task.sleep(for: .milliseconds(120))
        await coordinator.awaitRotationThresholdRefreshForTesting()
        let reverted = cachedRotationMatches(originalThreshold)
        r.check("rotation-cache-follows-default:reverted", reverted.0, reverted.1)
        _ = store.deleteFilms(ids: [rotationProbe.id])
        await coordinator.flushPendingSettingsSync()
        let restored = try? await coordinator.loadSettings()
        r.check("settings-flush-restores-session-value",
                restored?.defaultRotationThreshold == originalThreshold,
                "database holds \(String(describing: restored?.defaultRotationThreshold)), "
                    + "expected \(originalThreshold)")

        // A flush with nothing pending must be a no-op rather than a redundant write —
        // this is the fingerprint dirty-check in syncToDatabase.
        await coordinator.flushPendingSettingsSync()
        let idle = try? await coordinator.loadSettings()
        r.check("settings-flush-idle-is-stable",
                idle?.defaultRotationThreshold == originalThreshold,
                "an idle flush changed the persisted value")

        r.checks.append(contentsOf: storeInvariants(store, "coordinator-final"))
        return r
    }
}


// MARK: - Scenario: Snapshot ↔ Model Mapping

/// Proves the note at the top of 60.00 Snapshots.swift — "FilmSnapshot, ReleaseSnapshot, and
/// SettingsSnapshot must be kept in sync with their corresponding @Model counterparts" — for
/// every field, rather than leaving it a comment.
///
/// The compiler checks the snapshot's own initializer, but not `apply(to:)` or
/// `init(from:)`: a field missing from `apply(to:)` compiles and then silently never saves.
///
/// For each type: take a default snapshot, give EVERY field a distinct non-default value,
/// `apply(to:)` it onto a fresh model, read it back with `init(from:)`, and require each
/// field to come back unchanged.
///
/// The field list is not written here. It comes from the synthesized `Codable` keys, which
/// are exactly the stored properties, so a field added later is covered without editing
/// this scenario. Values are chosen by type: each candidate below is tried until one
/// decodes, since `JSONDecoder` rejects a value of the wrong type. That also works for
/// settings optionals, which encode as `null` and so do not reveal their type.
///
/// `excluded` holds the fields each `apply(to:)` documents as handled elsewhere: identity,
/// and the release hierarchy / film→releases relationship.
extension DebugHarness {
    @MainActor
    static func snapshotMappingScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-snapshot-mapping")

        let context: ModelContext
        do {
            let schema = backupHarnessSchema
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                   cloudKitDatabase: .none)
            context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        } catch {
            r.check("in-memory-container", false, "\(error)")
            return r
        }

        mappingRoundTrip(FilmSnapshot.self, label: "film", excluded: ["id", "releases"],
                         base: FilmSnapshot(from: Film()), into: &r) { filled in
            let model = Film()
            context.insert(model)
            filled.apply(to: model)
            return FilmSnapshot(from: model)
        }

        mappingRoundTrip(ReleaseSnapshot.self, label: "release",
                         excluded: ["id", "parentReleaseID", "childReleaseIDs"],
                         base: ReleaseSnapshot(), into: &r) { filled in
            let model = Release(independence: "")
            context.insert(model)
            filled.apply(to: model)
            return ReleaseSnapshot(from: model)
        }

        mappingRoundTrip(SettingsSnapshot.self, label: "settings", excluded: [],
                         base: SettingsSnapshot(), into: &r) { filled in
            let model = SettingsObject()
            context.insert(model)
            filled.apply(to: model)
            return SettingsSnapshot(from: model)
        }
        return r
    }

    @MainActor
    private static func mappingRoundTrip<T: Codable>(
        _ type: T.Type, label: String, excluded: Set<String>, base: T,
        into r: inout HarnessScenarioResult, roundTrip: (T) -> T
    ) {
        func object(_ value: T) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func decode(_ dict: [String: Any]) -> T? {
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        // The key list comes from the Mirror, not the encoded dictionary: the synthesized
        // encoder omits a nil optional (`encodeIfPresent`), and the Mirror lists every
        // stored property, nil or not. Stored properties are exactly the Codable keys.
        let keys = Mirror(reflecting: base).children.compactMap(\.label)
        guard var dict = object(base) else {
            r.check("\(label)-encodes", false, "default \(label) snapshot did not encode")
            return
        }

        var unfilled: [String] = []
        for (index, key) in keys.enumerated() where !excluded.contains(key) {
            let current = dict[key]
            var candidates: [Any] = []
            if let flag = current as? Bool, CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID() {
                candidates.append(!flag)
            } else {
                candidates.append(true)
            }
            candidates += [
                41 + index,                                   // Int, Double, Date
                "value-\(key)",                               // String
                UUID().uuidString,                            // UUID
                ["first-\(key)", "second-\(key)"],             // [String]
                [UUID().uuidString],                          // [UUID]
            ]
            var chosen = false
            for candidate in candidates {
                var trial = dict
                trial[key] = candidate
                guard decode(trial) != nil else { continue }
                // Must differ from the default, or the round trip proves nothing.
                if let current, (current as AnyObject).isEqual(candidate) { continue }
                dict = trial
                chosen = true
                break
            }
            if !chosen { unfilled.append(key) }
        }
        r.check("\(label)-every-field-filled", unfilled.isEmpty,
                unfilled.isEmpty ? "\(keys.count - excluded.count) fields given non-default values"
                                 : "no non-default value found for: \(unfilled.joined(separator: ", "))")

        guard let filled = decode(dict), let sent = object(filled),
              let returned = object(roundTrip(filled)) else {
            r.check("\(label)-round-trip-runs", false, "could not encode/decode the filled snapshot")
            return
        }

        var lost: [String] = []
        for key in keys where !excluded.contains(key) {
            let a = sent[key] as AnyObject?
            let b = returned[key] as AnyObject?
            let same = (a == nil && b == nil) || (a != nil && b != nil && a!.isEqual(b!))
            if !same { lost.append("\(key) (sent \(a.map { "\($0)" } ?? "nil"), got \(b.map { "\($0)" } ?? "nil"))") }
        }
        r.check("\(label)-apply-then-read-back", lost.isEmpty,
                lost.isEmpty ? "all \(keys.count - excluded.count) fields survived apply(to:) → init(from:)"
                             : "fields not carried: \(lost.joined(separator: "; "))")
    }
}

// MARK: - Fingerprint direct read

// `store-fingerprint-direct`: the snapshot-cache fingerprint's film layer, read straight from
// the store file by DirectStoreReader, must equal the SwiftData fetch it stands in for — on an
// empty store, after seeding, after each kind of change the fingerprint exists to see, and
// after a delete. The duplicate-release probe must answer no, then yes once a same-UUID row
// exists, then no after cleanupDuplicateReleases removes it; and the reader must decline (so
// the fetch runs) for an in-memory container, a missing file, and a row it cannot read
// exactly. Runs on its own store file, so the coordinator's library is untouched.
extension DebugHarness {
    static func fingerprintDirectReadScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "store-fingerprint-direct")
        guard let root = Preferences.dataFolderURL else {
            r.check("data-folder", false, "no data folder")
            return r
        }
        let url = root.appendingPathComponent("fingerprint-direct.store")
        func removeStoreFiles() {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path(percentEncoded: false) + suffix)
            }
        }
        removeStoreFiles()
        defer { removeStoreFiles() }

        let schema = backupHarnessSchema
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)])
        } catch {
            r.check("open-store", false, "\(error)")
            return r
        }
        let manager = DataManager(modelContainer: container)
        let context = ModelContext(container)

        func agree(_ label: String) async -> FilmLayerDigest? {
            let (direct, fetched) = await manager.filmLayerDigestsForTesting()
            r.check("\(label)-direct-answers", direct != nil)
            r.check("\(label)-matches-fetch", direct != nil && direct == fetched,
                    "direct \(direct.map { "\($0.filmCount) films, max '\($0.maxLastModified)'" } ?? "nil"); "
                    + "fetched \(fetched.map { "\($0.filmCount) films, max '\($0.maxLastModified)'" } ?? "nil")")
            return direct
        }
        func save(_ label: String) -> Bool {
            do { try context.save(); return true } catch {
                r.check("\(label)-save", false, "\(error)")
                return false
            }
        }

        _ = await agree("empty")

        for snapshot in standardCorpus(count: 200, seed: 0xF1D0_0001) { context.insert(snapshot.toFilm()) }
        guard save("seed") else { return r }
        let seeded = await agree("seeded")
        r.check("seeded-count", seeded?.filmCount == 200, "\(seeded?.filmCount ?? -1)")

        // Every field the digest covers, including the values most likely to trip a direct
        // decode: the empty "never modified" sentinel, a non-ASCII string, negative and
        // 64-bit extreme integers, and both lastModified spellings the writers use.
        let films = (try? context.fetch(FetchDescriptor<Film>(sortBy: [SortDescriptor(\.name)]))) ?? []
        guard films.count >= 10 else {
            r.check("fetch-films", false, "\(films.count)")
            return r
        }
        films[0].hofPosition = 7
        films[1].hofPosition = 3
        films[2].userRating = 9
        films[3].userRating = -1
        films[4].lastModified = ""
        films[5].lastModified = "2099.12.31"
        films[6].lastModified = "2026-09-25T08:37:19.070Z"
        films[7].lastModified = "2026‐09‐25 é 映画"
        films[8].hofPosition = Int.max
        films[9].userRating = Int.min
        guard save("edits") else { return r }
        let edited = await agree("edited")
        r.check("edits-change-digest", edited != nil && edited != seeded)

        // The reorder a sum-based digest would miss: two ranks exchanged.
        (films[0].hofPosition, films[1].hofPosition) = (films[1].hofPosition, films[0].hofPosition)
        guard save("swap") else { return r }
        let swapped = await agree("rank-swap")
        r.check("rank-swap-changes-digest", swapped != nil && swapped != edited)

        context.delete(films[2])
        guard save("delete") else { return r }
        let deleted = await agree("deleted")
        r.check("deleted-count", deleted?.filmCount == 199, "\(deleted?.filmCount ?? -1)")

        // Duplicate-release probe, and the cleanup it gates. The corpus carries no Release
        // rows, so a few are attached here.
        for film in films[3..<10] {
            context.insert(Release(format: "Blu-ray", independence: "Standalone", film: film))
        }
        guard save("releases") else { return r }
        let releases = (try? context.fetch(FetchDescriptor<Release>())) ?? []
        r.check("corpus-has-releases", !releases.isEmpty, "\(releases.count)")
        if let existing = releases.first {
            let before = releases.count
            r.check("probe-no-duplicates", await manager.duplicateReleaseProbeForTesting() == false)
            do { try await manager.cleanupDuplicateReleases() } catch {
                r.check("cleanup-clean-store", false, "\(error)")
            }
            let untouched = (try? context.fetchCount(FetchDescriptor<Release>())) ?? -1
            r.check("cleanup-leaves-clean-store", untouched == before, "\(untouched) vs \(before)")

            context.insert(Release(id: existing.id, independence: "Standalone"))
            if save("duplicate") {
                r.check("probe-sees-duplicate", await manager.duplicateReleaseProbeForTesting() == true)
                do { try await manager.cleanupDuplicateReleases() } catch {
                    r.check("cleanup-duplicate", false, "\(error)")
                }
                r.check("probe-clear-after-cleanup", await manager.duplicateReleaseProbeForTesting() == false)
                let after = (try? ModelContext(container).fetchCount(FetchDescriptor<Release>())) ?? -1
                r.check("cleanup-removed-one", after == before, "\(after) vs \(before)")
            }
        }

        // Concurrency: direct reads hammering the store from another thread while DataManager
        // commits, as the duplicate-release probe can overlap a tracked write. The store must
        // stay intact and the two paths must still agree afterwards.
        let reader = Task.detached { () -> Int in
            var answered = 0
            for _ in 0..<150 {
                if DirectStoreReader.filmLayerDigest(storeURL: url) != nil { answered += 1 }
                _ = DirectStoreReader.hasDuplicateReleaseIDs(storeURL: url)
            }
            return answered
        }
        var stressSnapshots = films[20..<60].map { FilmSnapshot(from: $0) }
        for round in 0..<25 {
            for i in stressSnapshots.indices { stressSnapshots[i].userRating = round % 11 }
            do { try await manager.updateFilms(stressSnapshots) } catch {
                r.check("stress-write", false, "\(error)")
                break
            }
        }
        let answered = await reader.value
        r.check("stress-reads-answered", answered > 0, "\(answered)/150 direct reads answered")
        var integrityDB: OpaquePointer?
        var integrity = "not run"
        if unsafe sqlite3_open_v2(url.path(percentEncoded: false), &integrityDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var statement: OpaquePointer?
            if unsafe sqlite3_prepare_v2(integrityDB, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
               unsafe sqlite3_step(statement) == SQLITE_ROW, let text = unsafe sqlite3_column_text(statement, 0) {
                integrity = unsafe String(cString: text)
            }
            unsafe sqlite3_finalize(statement)
        }
        unsafe sqlite3_close(integrityDB)
        r.check("stress-integrity", integrity == "ok", integrity)
        _ = await agree("after-stress")
        r.check("stress-fetch-works", ((try? ModelContext(container).fetchCount(FetchDescriptor<Film>())) ?? -1) == 199)

        // Production builds the configuration with no URL; the reader depends on SwiftData
        // resolving it to the store in Application Support. Constructing it opens nothing.
        let production = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                            allowsSave: true, cloudKitDatabase: .none)
        let expected = DebugSandbox.productionApplicationSupportURL?.appendingPathComponent("default.store")
        r.check("production-store-url", production.url.standardizedFileURL == expected?.standardizedFileURL,
                "\(production.url.path(percentEncoded: false)) vs \(expected?.path(percentEncoded: false) ?? "nil")")

        // Declines, each leaving the SwiftData fetch to answer.
        if let memory = try? ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]) {
            let (direct, fetched) = await DataManager(modelContainer: memory).filmLayerDigestsForTesting()
            r.check("in-memory-declines", direct == nil && fetched != nil)
        }
        r.check("missing-file-declines",
                DirectStoreReader.filmLayerDigest(storeURL: root.appendingPathComponent("no-such.store")) == nil)
        r.check("non-store-file-declines",
                DirectStoreReader.filmLayerDigest(storeURL: root.appendingPathComponent("FilmTracker.log")) == nil)

        // A row outside the expected shape — here a NULL lastModified, which SwiftData never
        // writes — makes the reader decline rather than guess. Written with raw SQL, last,
        // because it leaves this throwaway store in a state SwiftData does not produce.
        var db: OpaquePointer?
        if unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            let rc = unsafe sqlite3_exec(db, "UPDATE ZFILM SET ZLASTMODIFIED = NULL WHERE Z_PK = (SELECT MIN(Z_PK) FROM ZFILM)", nil, nil, nil)
            r.check("null-row-written", rc == SQLITE_OK, "rc \(rc)")
        }
        unsafe sqlite3_close(db)
        r.check("unexpected-row-declines", DirectStoreReader.filmLayerDigest(storeURL: url) == nil)
        return r
    }
}

// MARK: - DataManager thread

// `datamanager-thread`: drives the everyday write paths through the coordinator's public API —
// FilmSheet saves, direct film updates, a Hall of Fame add, a batch list add and remove, and a
// delete — and reads DataManagerThreadProbe to see which thread each DataManager method ran on
// and what it cost there. `writes-off-main` fails if any probed write ran on the main thread.
// On a seeded copy of a real library the metrics are the realistic costs; on an empty sandbox
// a corpus is imported first.
extension DebugHarness {
    static func dataManagerThreadScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "datamanager-thread")
        func drain() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(20)
            while coordinator.hasPendingOperations {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await Task.yield()
            return true
        }

        if coordinator.getAllFilms().count < 100 {
            coordinator.importFilms(standardCorpus(count: 400, seed: 0xDA7A_0001))
            r.check("seed-drained", await drain())
        }
        let films = coordinator.getAllFilms().sorted { $0.id.uuidString < $1.id.uuidString }
        guard films.count >= 100 else {
            r.check("films", false, "\(films.count)")
            return r
        }

        DataManagerThreadProbe.isEnabled = true
        defer { DataManagerThreadProbe.isEnabled = false }

        // FilmSheet saves (applyFilmChangeset), one at a time as a user would make them.
        for film in films[0..<6] {
            var edited = film
            edited.notes = film.notes + " (thread probe)"
            edited.lastModified = "2026-09-25T12:00:00.000Z"
            coordinator.saveFilmChangeset(FilmChangeset(
                filmID: edited.id, isNewFilm: false, filmSnapshot: edited,
                releasesToCreate: [], releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [], listsToRemove: []))
            r.check("changeset-drained", await drain())
        }

        // Single-film updates (updateFilm) and a Hall of Fame add.
        for film in films[6..<10] {
            var edited = film
            edited.notes = film.notes + " (update probe)"
            await coordinator.updateFilm(edited)
            r.check("update-drained", await drain())
        }
        if let unranked = films[10..<60].first(where: { $0.hofPosition == 0 }) {
            coordinator.addToHallOfFame(unranked.id)
            r.check("hof-drained", await drain())
        }

        // Batch list add and remove, 60 films into a fresh list.
        let listID = coordinator.createList(name: "Thread Probe", displayOrder: 999)
        let members = Set(films[20..<80].map(\.id))
        coordinator.addFilmsToList(filmIDs: members, listID: listID)
        r.check("list-add-drained", await drain())
        coordinator.removeFilmsFromList(filmIDs: members, listID: listID)
        r.check("list-remove-drained", await drain())

        // Delete.
        await coordinator.deleteFilms(withIDs: Set(films[90..<93].map(\.id)))
        r.check("delete-drained", await drain())

        // Deferred launch maintenance's membership cleanup, reached as AppState reaches it:
        // from a detached task, through the coordinator. An orphan is planted first so the
        // pass has something to delete: a canceled pass must leave it (shutdown cancels
        // maintenance), and an uncanceled one must remove it.
        let container = coordinator.modelContainer
        func orphanCount() -> Int {
            (try? ModelContext(container).fetchCount(FetchDescriptor<ListMembership>(
                predicate: #Predicate<ListMembership> { $0.film == nil }))) ?? -1
        }
        let plant = ModelContext(container)
        if let film = try? plant.fetch(FetchDescriptor<Film>()).first,
           let list = try? plant.fetch(FetchDescriptor<ListObject>()).first {
            let membership = ListMembership(film: film, list: list)
            plant.insert(membership)
            membership.film = nil
            try? plant.save()
        }
        let planted = orphanCount()
        r.check("orphan-planted", planted >= 1, "\(planted)")
        let canceled = Task.detached { await coordinator.cleanupOrphanedAndDuplicateMemberships() }
        canceled.cancel()
        await canceled.value
        r.check("canceled-cleanup-keeps-orphan", orphanCount() == planted, "\(orphanCount()) vs \(planted)")
        await Task.detached { await coordinator.cleanupOrphanedAndDuplicateMemberships() }.value
        r.check("cleanup-removes-orphan", orphanCount() == 0, "\(orphanCount()) left")

        // Mutual exclusion: SwiftData's executor runs a job on the thread that enqueued it,
        // so prove calls arriving from several threads at once still never overlap.
        let manager = DataManager(modelContainer: coordinator.modelContainer)
        let detached = (0..<6).map { _ in
            Task.detached { await manager.exclusionProbeForTesting(milliseconds: 30) }
        }
        // Enqueued from the main thread while the detached calls are in flight.
        var intervals = [await manager.exclusionProbeForTesting(milliseconds: 30)]
        for task in detached { intervals.append(await task.value) }
        intervals.sort { $0.start < $1.start }
        let overlaps = zip(intervals, intervals.dropFirst()).filter { $0.end > $1.start }.count
        r.check("executor-mutually-exclusive", overlaps == 0,
                "\(overlaps) overlapping pair(s) among \(intervals.count) calls, "
                + "\(intervals.filter(\.onMain).count) on main")

        let records = DataManagerThreadProbe.records
        r.check("probe-recorded", !records.isEmpty, "\(records.count) records")
        var onMainTotal = 0.0
        for method in Array(Set(records.map(\.method))).sorted() {
            let rows = records.filter { $0.method == method }
            let main = rows.filter(\.onMainThread)
            let walls = rows.map(\.wallMilliseconds).sorted()
            let cpus = rows.map(\.threadCPUMilliseconds).sorted()
            onMainTotal += main.map(\.wallMilliseconds).reduce(0, +)
            r.metric("\(method)-calls", Double(rows.count), "count")
            r.metric("\(method)-on-main", Double(main.count), "count")
            r.metric("\(method)-wall-median", walls[walls.count / 2], "ms")
            r.metric("\(method)-wall-max", walls.last ?? 0, "ms")
            r.metric("\(method)-cpu-median", cpus[cpus.count / 2], "ms")
            unsafe log(String(format: "THREAD PROBE %@: %d call(s), %d on main, wall median %.1f max %.1f ms, cpu median %.1f ms",
                       method, rows.count, main.count, walls[walls.count / 2], walls.last ?? 0, cpus[cpus.count / 2]))
        }
        r.metric("main-thread-wall-total", onMainTotal, "ms")
        let offenders = records.filter(\.onMainThread).map(\.method)
        r.check("writes-off-main", offenders.isEmpty,
                offenders.isEmpty ? "" : "ran on main: \(Array(Set(offenders)).sorted().joined(separator: ", ")) — \(Fmt.fixed(onMainTotal, 0)) ms")
        return r
    }
}

#endif
