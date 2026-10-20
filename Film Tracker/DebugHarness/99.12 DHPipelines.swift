// MARK: - DHPipelines.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only harness scenarios for the two pipelines that exist to protect the user's data
// when something goes wrong: the optimistic-write rollback infrastructure, and the
// export / restore round trip.
//
// WHY A FAULT INJECTOR RATHER THAN INSPECTION
//
// Every mutation in DataCoordinator is optimistic: MemoryStore is updated immediately and
// the database write is dispatched to the background, with a rollback closure that is
// supposed to put memory back exactly as it was if that write fails. Those closures are the
// least-exercised code in the application — they run only when persistence fails, which
// essentially never happens during development — and they are hand-written per call site,
// so "looks right" is worth very little. `DebugPersistenceFault` makes the failure happen on
// demand, at the trackOperation boundary every path funnels through.
//
// The assertion is a whole-store DIGEST comparison, not a field spot-check: the store's
// films (including Hall of Fame positions and release arrays) and every list's membership
// are serialized before the mutation and again after the rollback, and the two must be
// byte-identical. A rollback that restores the film but forgets its list membership, or
// restores the ranking but not the compaction applied to survivors, fails this — which is
// exactly the class of omission a per-case assertion tends to miss.
//
// Each case also asserts that the injector actually fired. Without that control, a path
// that silently dispatched no work at all would "pass" its rollback test vacuously.
//
// WHAT THE ROUND-TRIP SCENARIOS ARE FOR
//
// The export pipeline reflects @Model objects into an untyped [String: Any] bag, writes it
// as XML, and the import pipeline guesses each value's type back from its text. That guess
// is the interesting part: nothing in the file records whether a field was a String or an
// Int, so a string-typed field whose CONTENT looks numeric, boolean, or array-shaped is
// reconstructed as the wrong type. `export-roundtrip` puts values of exactly that shape
// into string fields and checks what comes back, and `restore-endtoend` carries the same
// corpus through the real DBRestorer and re-reads the rebuilt store.
//
// ORDERING: `restore-endtoend` DESTROYS the sandbox store — that is what a restore does —
// so it runs last, after every scenario that needs a live library.

#if DEBUG

import Foundation
import SwiftData

extension DebugHarness {

    /// Scenario names owned by this file. `restore-endtoend` must remain last: it deletes
    /// and rebuilds the sandbox store, orphaning the coordinator's container.
    static var pipelineScenarios: [String] {
        ["rollback-integrity", "export-roundtrip", "export-malformed", "audit-fixes",
         "film-field-merge", "restore-endtoend", "release-date-rules"]
    }

    static func runPipelineScenario(_ scenario: String,
                                    coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "rollback-integrity": return await rollbackScenario(coordinator: coordinator)
        case "export-roundtrip":   return await exportRoundTripScenario(coordinator: coordinator)
        case "export-malformed":   return await malformedBackupScenario()
        case "audit-fixes":        return await auditFixesScenario(coordinator: coordinator)
        case "film-field-merge":   return await filmFieldMergeScenario(coordinator: coordinator)
        case "restore-endtoend":   return await restoreEndToEndScenario(coordinator: coordinator)
        case "release-date-rules": return releaseDateRulesScenario()
        default:                   return nil
        }
    }

    // MARK: - Rollback Support

    /// A stable, complete serialization of everything MemoryStore holds.
    ///
    /// Sorted at every level and encoded with `.sortedKeys`, so two digests differ only when
    /// the state differs — never because a dictionary iterated in a different order.
    /// Deliberately includes the Hall of Fame ordering: it is derived state that several
    /// rollback paths have to reconcile by hand, and a digest built only from the films
    /// would not notice a ranking left in the post-mutation order.
    static func storeDigest(_ store: MemoryStore) -> String {
        struct ListDigest: Codable {
            let listID: String, name: String, order: Int, films: [String], options: [String]
        }
        struct Digest: Codable {
            let films: [FilmSnapshot]
            let lists: [ListDigest]
            let hallOfFame: [String]
        }

        let films = store.getAllFilmsMap().values.sorted { $0.id.uuidString < $1.id.uuidString }
        let lists = store.allListsForTesting
            .sorted { $0.listID.uuidString < $1.listID.uuidString }
            .map { ListDigest(listID: $0.listID.uuidString, name: $0.listName,
                              order: $0.displayOrder,
                              films: $0.filmIDs.map(\.uuidString).sorted(),
                              options: $0.sortFilterOptions) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Digest(films: Array(films), lists: lists,
                            hallOfFame: store.hallOfFameFilms.map(\.uuidString))
        guard let data = try? encoder.encode(digest) else { return "<encode failed>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for every tracked background operation to finish, so the rollback the failure
    /// triggers has actually run before anything is asserted.
    private static func drainOperations(_ coordinator: DataCoordinator,
                                        timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while coordinator.hasPendingOperations {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // One more turn so any MainActor continuation queued by the final operation
        // (the rollback closure itself) has run before the digest is taken.
        await Task.yield()
        return true
    }

    /// Runs one mutation with persistence forced to fail, then asserts the store came back
    /// to exactly where it started and that the published state agrees with it.
    private static func rollbackCase(_ name: String,
                                     coordinator: DataCoordinator,
                                     into r: inout HarnessScenarioResult,
                                     settle: Duration? = nil,
                                     mutate: () async -> Void) async {
        let store = coordinator.memoryStoreForTesting
        let before = storeDigest(store)
        let injectedBefore = DebugPersistenceFault.injectedCount

        DebugPersistenceFault.mode = .beforeWork
        await mutate()
        // Debounced paths (Hall of Fame and wishlist reorders) do not dispatch until their
        // quiet window expires, so those cases ask for an explicit settle period.
        if let settle { try? await Task.sleep(for: settle) }
        let drained = await drainOperations(coordinator)
        DebugPersistenceFault.mode = .none

        r.check("\(name)/dispatched-a-tracked-write",
                DebugPersistenceFault.injectedCount > injectedBefore,
                "\(DebugPersistenceFault.injectedCount - injectedBefore) injected failure(s) — "
                    + "zero would mean this case never reached persistence and proves nothing")
        r.check("\(name)/operations-drained", drained, "no operation left pending")

        let after = storeDigest(store)
        r.check("\(name)/store-restored", after == before,
                after == before ? "byte-identical to the pre-mutation state"
                                : firstDifference(before, after))

        // The published array is what the gallery draws. A rollback that fixes the store but
        // leaves `films` holding the mutated snapshots repaints nothing, so the user keeps
        // seeing an edit that was never persisted and has already been undone underneath.
        let mismatched = coordinator.films.filter { published in
            store.getFilm(published.id) != published
        }
        r.check("\(name)/published-films-agree-with-store", mismatched.isEmpty,
                "\(mismatched.count) of \(coordinator.films.count) published snapshot(s) differ from the store")
        r.check("\(name)/published-count-agrees",
                coordinator.totalFilmCount == store.totalFilmCount,
                "published \(coordinator.totalFilmCount), store \(store.totalFilmCount)")

        // cachedLists drives the sidebar's per-list film counts.
        let cached = Dictionary(uniqueKeysWithValues: coordinator.cachedLists.map { ($0.listID, $0.filmCount) })
        let live = Dictionary(uniqueKeysWithValues: coordinator.getAllLists().map { ($0.listID, $0.filmIDs.count) })
        r.check("\(name)/published-list-counts-agree", cached == live,
                "cached \(cached.count) entries, live \(live.count)")

        r.checks.append(contentsOf: storeInvariants(store, name))
    }

    // MARK: - Persisted List Membership

    /// The film IDs actually stored as `ListMembership` rows for `listID`, read through a
    /// fresh `ModelContext` on the coordinator's own container.
    ///
    /// Deliberately a whole-table fetch filtered in Swift, rather than the targeted
    /// ListObject fetch `DataManager.batchRemoveFilmsFromLists` performs: the check must not
    /// share its reasoning with the code it is checking, or a mistake in "which rows belong
    /// to this list" would be invisible to both. Returns an array, not a Set, so a duplicate
    /// row for one (film, list) pair is still countable.
    @MainActor
    private static func persistedMembershipFilmIDs(_ coordinator: DataCoordinator,
                                                   listID: UUID) -> [UUID] {
        let context = ModelContext(coordinator.modelContainer)
        let rows = (try? context.fetch(FetchDescriptor<ListMembership>())) ?? []
        return rows.compactMap { $0.list?.listID == listID ? $0.film?.id : nil }
    }

    /// Drives adds and removes through the coordinator's real entry points and asserts, after
    /// each one has drained to the background writer, that the persistent store holds exactly
    /// the membership rows MemoryStore claims — no missing rows, no duplicates, and no rows
    /// belonging to films the operation never named.
    ///
    /// Uses a probe list of its own so the surrounding rollback cases keep the corpus they
    /// were written against; the list survives into the baseline digest as ordinary state.
    private static func membershipPersistenceChecks(coordinator: DataCoordinator,
                                                    corpus: [FilmSnapshot]) async -> [HarnessCheck] {
        var checks: [HarnessCheck] = []
        let store = coordinator.memoryStoreForTesting

        let listID = coordinator.createList(name: "Persistence Probe", displayOrder: 902)
        _ = await drainOperations(coordinator)

        let added = Set(corpus.prefix(8).map(\.id))
        coordinator.addFilmsToList(filmIDs: added, listID: listID)
        _ = await drainOperations(coordinator)

        var rows = persistedMembershipFilmIDs(coordinator, listID: listID)
        checks.append(HarnessCheck(
            name: "membership-persistence/add-writes-every-row",
            passed: Set(rows) == added,
            detail: "persisted \(Set(rows).count) of \(added.count) requested membership(s); "
                + "missing \(added.subtracting(rows).count), unexpected \(Set(rows).subtracting(added).count)"))
        checks.append(HarnessCheck(
            name: "membership-persistence/add-writes-no-duplicate-row",
            passed: rows.count == Set(rows).count,
            detail: "\(rows.count) row(s) for \(Set(rows).count) distinct film(s)"))

        // A repeat add of the identical set must insert nothing: the dedupe is what the
        // existing-membership lookup at the top of batchAddFilmsToLists exists to provide,
        // and it is the part of that method this audit rewrote.
        coordinator.addFilmsToList(filmIDs: added, listID: listID)
        _ = await drainOperations(coordinator)
        rows = persistedMembershipFilmIDs(coordinator, listID: listID)
        checks.append(HarnessCheck(
            name: "membership-persistence/re-add-inserts-nothing",
            passed: rows.count == added.count && Set(rows) == added,
            detail: "\(rows.count) row(s) after re-adding the same \(added.count) film(s)"))

        // A partial removal must delete exactly the named pairs and leave the rest standing.
        let removed = Set(corpus.prefix(3).map(\.id))
        coordinator.removeFilmsFromList(filmIDs: removed, listID: listID)
        _ = await drainOperations(coordinator)
        rows = persistedMembershipFilmIDs(coordinator, listID: listID)
        let expected = added.subtracting(removed)
        checks.append(HarnessCheck(
            name: "membership-persistence/remove-deletes-exactly-the-named-rows",
            passed: Set(rows) == expected && rows.count == expected.count,
            detail: "\(rows.count) row(s) remain, expected \(expected.count)"))

        // Removing films that are not members must not disturb the ones that are — the
        // targeted fetch must not widen to rows the caller never named.
        coordinator.removeFilmsFromList(
            filmIDs: Set(corpus.suffix(4).map(\.id)), listID: listID)
        _ = await drainOperations(coordinator)
        rows = persistedMembershipFilmIDs(coordinator, listID: listID)
        checks.append(HarnessCheck(
            name: "membership-persistence/remove-of-non-members-is-inert",
            passed: Set(rows) == expected && rows.count == expected.count,
            detail: "\(rows.count) row(s) remain, expected \(expected.count)"))

        // The whole point: what is on disk and what the UI reads must be the same set.
        let inMemory = store.getList(listID)?.filmIDs ?? []
        checks.append(HarnessCheck(
            name: "membership-persistence/agrees-with-memory-store",
            passed: Set(rows) == inMemory,
            detail: "store holds \(Set(rows).count), MemoryStore holds \(inMemory.count)"))

        // --- Film Queue section move ----------------------------------------------------
        // A move is an exclusivity removal plus an add. Both halves now ride in one tracked
        // operation and one database transaction, so the assertion is on the committed
        // result: the film holds a membership row in its new section and in NO other.
        let mover = corpus[12].id
        _ = coordinator.addFilmsToList(filmIDs: [mover],
                                                listID: FilmQueueSection.later.listID)
        _ = await drainOperations(coordinator)
        _ = coordinator.addFilmsToList(filmIDs: [mover],
                                                listID: FilmQueueSection.upNext.listID)
        _ = await drainOperations(coordinator)

        let sectionsHolding = FilmQueueSection.allCases.filter {
            persistedMembershipFilmIDs(coordinator, listID: $0.listID).contains(mover)
        }
        checks.append(HarnessCheck(
            name: "membership-persistence/queue-move-lands-in-exactly-one-section",
            passed: sectionsHolding == [.upNext],
            detail: "persisted section(s): "
                + (sectionsHolding.isEmpty ? "none — the move committed its removal but not its add"
                                           : sectionsHolding.map(\.displayName).joined(separator: ", "))))
        checks.append(HarnessCheck(
            name: "membership-persistence/queue-move-agrees-with-memory-store",
            passed: Set(sectionsHolding.map { $0.listID }) == coordinator.filmQueueListIDs(forFilm: mover),
            detail: "store says \(sectionsHolding.count) section(s), MemoryStore says "
                + "\(coordinator.filmQueueListIDs(forFilm: mover).count)"))

        return checks
    }

    /// Two user-generated lists must never share a name, in any casing. Creating one has
    /// always uniquified; renaming onto an existing name used to be the one path that did
    /// not, which made a rename the only way to produce a duplicate — and a duplicate is
    /// indistinguishable from its twin in every surface that shows a list by name.
    ///
    /// Driven through `ListManager`, not `DataCoordinator`, because that is where the rule
    /// lives and where the UI enters. The coordinator's own `createList` / `updateList`
    /// write verbatim by design, which is what lets the restore scenario seed collisions.
    private static func listNamingChecks(coordinator: DataCoordinator) async -> [HarnessCheck] {
        var checks: [HarnessCheck] = []

        func name(of listID: UUID) -> String { coordinator.getList(listID)?.listName ?? "<missing>" }

        guard let first = ListManager.createList(baseName: "Naming Probe",
                                                       coordinator: coordinator),
              let second = ListManager.createList(baseName: "Naming Probe",
                                                        coordinator: coordinator) else {
            return [HarnessCheck(name: "list-naming/probe-lists-created", passed: false,
                                 detail: "createList returned nil — nothing below could run")]
        }
        _ = await drainOperations(coordinator)

        // Control: the pre-existing create-time behavior, so a failure below can be read as
        // a rename defect rather than a collapse of uniquification generally.
        checks.append(HarnessCheck(
            name: "list-naming/create-uniquifies",
            passed: name(of: first) == "Naming Probe" && name(of: second) == "Naming Probe 1",
            detail: "'\(name(of: first))' and '\(name(of: second))'"))

        // Rename onto an existing name — the case this audit fixed.
        _ = ListManager.updateListName(second, newName: "Naming Probe",
                                             coordinator: coordinator)
        _ = await drainOperations(coordinator)
        checks.append(HarnessCheck(
            name: "list-naming/rename-onto-existing-name-uniquifies",
            passed: name(of: second) == "Naming Probe 1",
            detail: "second list is now '\(name(of: second))', expected 'Naming Probe 1'"))

        // Case-insensitivity: the comparison must not be fooled by casing, or the duplicate
        // simply comes back in a different shape.
        _ = ListManager.updateListName(second, newName: "naming probe",
                                             coordinator: coordinator)
        _ = await drainOperations(coordinator)
        checks.append(HarnessCheck(
            name: "list-naming/rename-collision-is-case-insensitive",
            passed: name(of: second).lowercased() != "naming probe",
            detail: "second list is now '\(name(of: second))'"))

        // A list must still be able to keep its own name: excluding the list being renamed
        // from the comparison set is what stops a re-save turning "Alpha" into "Alpha 1".
        _ = ListManager.updateListName(first, newName: "Naming Probe",
                                             coordinator: coordinator)
        _ = await drainOperations(coordinator)
        checks.append(HarnessCheck(
            name: "list-naming/rename-to-own-name-is-inert",
            passed: name(of: first) == "Naming Probe",
            detail: "first list is now '\(name(of: first))', expected 'Naming Probe'"))

        // Recasing a list's own name must be honored, not treated as a self-collision.
        _ = ListManager.updateListName(first, newName: "NAMING PROBE",
                                             coordinator: coordinator)
        _ = await drainOperations(coordinator)
        checks.append(HarnessCheck(
            name: "list-naming/recasing-own-name-is-applied",
            passed: name(of: first) == "NAMING PROBE",
            detail: "first list is now '\(name(of: first))', expected 'NAMING PROBE'"))

        return checks
    }

    /// Locates the first differing region of two digests, so a failure reports what changed
    /// rather than dumping two multi-megabyte JSON strings.
    private static func firstDifference(_ lhs: String, _ rhs: String) -> String {
        let a = Array(lhs), b = Array(rhs)
        var index = 0
        while index < min(a.count, b.count), a[index] == b[index] { index += 1 }
        let start = max(0, index - 60)
        let window = { (chars: [Character]) -> String in
            String(chars[start..<min(chars.count, index + 120)])
        }
        return "diverges at offset \(index) of \(a.count)/\(b.count):\n  before: …\(window(a))…\n  after:  …\(window(b))…"
    }

    // MARK: - Scenario: Audit Fixes

    /// Pins the fixes from the 2026-09-28 audit, each against the persisted store as well as
    /// memory — the gaps they close were all invisible in memory alone:
    ///   - the "Add Viewing Event" quick-add derives `viewCount` (it left the stored count stale);
    ///   - a wishlist reorder carries each position down to the release's combo-pack children;
    ///   - `commitPendingWritesForExport` commits what is still inside a debounce window —
    ///     a Hall of Fame / wishlist reorder and a settings change — so an export sees it;
    ///   - search upper bounds (`<`, `N-`) no longer match films that have no value at all.
    private static func auditFixesScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "audit-fixes")
        let store = coordinator.memoryStoreForTesting
        DebugPersistenceFault.reset()

        // A fresh context per read, so every value comes from the store rather than from
        // objects some earlier fetch registered.
        func persistedFilm(_ id: UUID) -> Film? {
            let context = ModelContext(coordinator.modelContainer)
            return try? context.fetch(FetchDescriptor<Film>(predicate: #Predicate { $0.id == id })).first
        }
        func persistedRelease(_ id: UUID) -> Release? {
            let context = ModelContext(coordinator.modelContainer)
            return try? context.fetch(FetchDescriptor<Release>(predicate: #Predicate { $0.id == id })).first
        }
        func saveNew(_ film: FilmSnapshot) {
            var film = film
            film.lastModified = "2020.01.01"
            film.numberOfDiscs = "0"
            coordinator.saveFilmChangeset(FilmChangeset(
                filmID: film.id, isNewFilm: true, filmSnapshot: film,
                releasesToCreate: film.releases, releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [], listsToRemove: []))
        }

        // --- Quick-add viewing derives viewCount ----------------------------------------------
        // Dates well in the past, so the Film Queue auto-removal (today/yesterday) stays out.
        let viewer = makeSnapshot(name: "Audit Viewer", lastWatched: "2020.05.01",
                                  calendarTable: ["2020.05.01"])
        saveNew(viewer)
        _ = await drainOperations(coordinator)
        coordinator.updateViewingDates(filmID: viewer.id,
                                       calendarTable: ["2020.05.01", "2020.06.01"],
                                       lastWatched: "2020.06.01", watched: true)
        _ = await drainOperations(coordinator)
        let memoryViews = store.getFilm(viewer.id)?.viewCount ?? -1
        let storedViews = persistedFilm(viewer.id)?.viewCount ?? -1
        r.check("viewing-dates/viewcount-in-memory", memoryViews == 2,
                "memory holds \(memoryViews), expected 2 (two calendar entries)")
        r.check("viewing-dates/viewcount-persisted", storedViews == 2,
                "store holds \(storedViews), expected 2 — backups export this value verbatim")

        // --- Wishlist reorder reaches combo-pack children, and the export flush commits it ------
        let parentID = UUID(), childID = UUID()
        let pack = makeSnapshot(name: "Audit Pack", releases: [
            ReleaseSnapshot(id: parentID, wishlist: 1, format: ReleaseFormat.uhd4K.rawValue,
                            independence: ReleaseIndependence.comboPack, sortOrder: 0,
                            childReleaseIDs: [childID]),
            ReleaseSnapshot(id: childID, wishlist: 1, format: ReleaseFormat.bluRay.rawValue,
                            independence: ReleaseIndependence.comboPack, sortOrder: 1,
                            parentReleaseID: parentID),
        ])
        let soloID = UUID()
        let solo = makeSnapshot(name: "Audit Solo", releases: [
            ReleaseSnapshot(id: soloID, wishlist: 2, format: ReleaseFormat.bluRay.rawValue),
        ])
        saveNew(pack)
        saveNew(solo)
        _ = await drainOperations(coordinator)

        // Solo first, so the pack's parent moves from 1 to 2 and its child must follow.
        coordinator.reorderWishlist([(filmID: solo.id, releaseID: soloID),
                                     (filmID: pack.id, releaseID: parentID)])
        let childInMemory = store.getFilm(pack.id)?.releases.first { $0.id == childID }?.wishlist ?? -1
        r.check("wishlist-reorder/child-mirrors-parent-in-memory", childInMemory == 2,
                "child holds \(childInMemory), expected the parent's new position 2")

        // Committed well inside the one-second debounce: only the flush can have written it.
        await coordinator.commitPendingWritesForExport()
        let parentStored = persistedRelease(parentID)?.wishlist ?? -1
        let childStored = persistedRelease(childID)?.wishlist ?? -1
        r.check("export-flush/wishlist-reorder-committed", parentStored == 2,
                "store holds parent position \(parentStored), expected 2 before the debounce expired")
        r.check("wishlist-reorder/child-mirrors-parent-persisted", childStored == 2,
                "store holds child position \(childStored), expected 2")

        // --- The export flush commits a pending Hall of Fame reorder ---------------------------
        for film in [viewer, pack, solo] where store.hallOfFameFilms.count < 2 {
            coordinator.addToHallOfFame(film.id)
        }
        _ = await drainOperations(coordinator)
        coordinator.reorderHallOfFame(store.hallOfFameFilms.reversed())
        await coordinator.commitPendingWritesForExport()
        let mismatchedRanks = store.hallOfFameFilms.filter {
            persistedFilm($0)?.hofPosition != store.getFilm($0)?.hofPosition
        }
        r.check("export-flush/hof-reorder-committed",
                store.hallOfFameFilms.count >= 2 && mismatchedRanks.isEmpty,
                "\(mismatchedRanks.count) of \(store.hallOfFameFilms.count) ranked film(s) differ between store and memory")

        // --- The export flush commits a debounced settings change -----------------------------
        let originalFuzzy = Preferences.fuzzyImportMatching
        Preferences.fuzzyImportMatching = !originalFuzzy
        // The setter posts preferencesChanged from a Task; let it arm the debounce.
        for _ in 0..<3 { await Task.yield() }
        await coordinator.commitPendingWritesForExport()
        let storedFuzzy = (try? await coordinator.loadSettings())?.fuzzyImportMatching
        r.check("export-flush/settings-committed", storedFuzzy == !originalFuzzy,
                "stored fuzzyImportMatching is \(String(describing: storedFuzzy)), expected \(!originalFuzzy)")
        Preferences.fuzzyImportMatching = originalFuzzy
        for _ in 0..<3 { await Task.yield() }
        await coordinator.commitPendingWritesForExport()

        // A write the way @AppStorage makes it: straight to the defaults suite, with no
        // preferencesChanged event, so nothing is ever marked pending. Most Settings
        // toggles work this way; the export must still carry their values.
        if let suite = DebugSandbox.userDefaultsSuiteName.flatMap({ UserDefaults(suiteName: $0) }) {
            let originalConfirm = Preferences.confirmReleaseDelete
            suite.set(!originalConfirm, forKey: Preferences.confirmReleaseDeleteKey)
            await coordinator.commitPendingWritesForExport()
            let storedConfirm = (try? await coordinator.loadSettings())?.confirmReleaseDelete
            r.check("export-flush/silent-appstorage-write-committed", storedConfirm == !originalConfirm,
                    "stored confirmReleaseDelete is \(String(describing: storedConfirm)), expected \(!originalConfirm)")
            suite.set(originalConfirm, forKey: Preferences.confirmReleaseDeleteKey)
            await coordinator.commitPendingWritesForExport()
        } else {
            r.check("export-flush/silent-appstorage-write-committed", false, "sandbox defaults suite unavailable")
        }

        // --- Search upper bounds skip films with no value ---------------------------------------
        // A private controller: SearchController.shared drives the live search UI.
        // (updateSearchQuery is ignored outside the search view, which the harness never opens.)
        let blank = makeSnapshot(name: "Audit Blank", releaseYear: "", rating: 0, duration: "")
        let valued = makeSnapshot(name: "Audit Valued", releaseYear: "1990", rating: 5,
                                  duration: "5400000")
        let search = SearchController()
        for (field, value) in [(SearchField.year, "<2020"), (.duration, "<200"),
                               (.rating, "<9"), (.rating, "8-")] {
            search.currentTokens = [SearchToken(field: field, value: value,
                                                isInverted: false, isOr: false)]
            let matched = search.filterFilms([blank, valued]) { _ in [] }.map(\.name)
            r.check("search-bounds/\(field.rawValue)\(value)", matched == [valued.name],
                    "matched \(matched), expected only '\(valued.name)'")
        }
        search.currentTokens = [SearchToken(field: .rating, value: "0", isInverted: false, isOr: false)]
        let unrated = search.filterFilms([blank, valued]) { _ in [] }.map(\.name)
        r.check("search-bounds/exact-zero-still-finds-unrated", unrated == [blank.name],
                "matched \(unrated), expected only '\(blank.name)'")
        search.clearSearch()

        // --- Rotation threshold keywords test the override, not the effective value ------------
        let defaultMonths = Preferences.defaultRotationThreshold
        let otherMonths = Preferences.rotationThresholdOptions.first { $0 != defaultMonths } ?? defaultMonths
        let noOverride = makeSnapshot(name: "Rot NoOverride")
        var sameAsDefault = makeSnapshot(name: "Rot SameAsDefault")
        sameAsDefault.rotationThresholdOverride = defaultMonths
        var differs = makeSnapshot(name: "Rot Differs")
        differs.rotationThresholdOverride = otherMonths
        let rotFilms = [noOverride, sameAsDefault, differs]
        func rotation(_ value: String, inverted: Bool = false) -> Set<String> {
            search.currentTokens = [SearchToken(field: .rotationThreshold, value: value,
                                                isInverted: inverted, isOr: false)]
            return Set(search.filterFilms(rotFilms) { _ in [] }.map(\.name))
        }
        let everyOverride: Set = [sameAsDefault.name, differs.name]
        r.check("rotation-keywords/default-is-no-override", rotation("default") == [noOverride.name],
                "matched \(rotation("default")), expected only '\(noOverride.name)'")
        r.check("rotation-keywords/override", rotation("override") == everyOverride,
                "matched \(rotation("override")), expected \(everyOverride)")
        r.check("rotation-keywords/custom", rotation("CUSTOM") == everyOverride,
                "matched \(rotation("CUSTOM")), expected \(everyOverride)")
        r.check("rotation-keywords/inverted-default", rotation("default", inverted: true) == everyOverride,
                "matched \(rotation("default", inverted: true)), expected \(everyOverride)")
        r.check("rotation-keywords/number-spans-override-and-default",
                rotation("\(defaultMonths)") == [noOverride.name, sameAsDefault.name],
                "matched \(rotation("\(defaultMonths)")), expected the no-override and same-as-default films")
        search.clearSearch()

        // --- Ranges, unparseable dates, and the synopsis token ---------------------------------
        func ids(_ field: SearchField, _ value: String, in films: [FilmSnapshot], inverted: Bool = false) -> Set<String> {
            search.currentTokens = [SearchToken(field: field, value: value, isInverted: inverted, isOr: false)]
            return Set(search.filterFilms(films) { _ in [] }.map(\.name))
        }
        let band = (1...10).map { makeSnapshot(name: "Band \($0)", releaseYear: "\(1990 + $0)",
                                               rating: $0, duration: "\($0 * 20 * 60_000)") }
        func names(_ range: ClosedRange<Int>) -> Set<String> { Set(range.map { "Band \($0)" }) }
        r.check("range/rating-7-9", ids(.rating, "7-9", in: band) == names(7...9), "\(ids(.rating, "7-9", in: band))")
        r.check("range/rating-open-8-is-still-at-most",
                ids(.rating, "8-", in: band) == names(1...8), "\(ids(.rating, "8-", in: band))")
        r.check("range/rating-reversed-matches-nothing", ids(.rating, "9-7", in: band).isEmpty, "reversed range matched")
        r.check("range/duration-60-120",   // minutes: Band n runs n * 20
                ids(.duration, "60-120", in: band) == names(3...6), "\(ids(.duration, "60-120", in: band))")
        r.check("range/year-unchanged", ids(.year, "1992-1994", in: band) == names(2...4), "\(ids(.year, "1992-1994", in: band))")
        r.check("range/duration-skips-no-duration",
                ids(.duration, "0-500", in: [blank]).isEmpty, "a film with no duration matched a range")

        var watchedFilm = makeSnapshot(name: "Dated", lastWatched: "2023.05.10")
        watchedFilm.dateAdded = "2023.05.10"
        let dated = [watchedFilm, makeSnapshot(name: "Undated")]
        for field in [SearchField.lastWatched, .dateAdded] {
            for junk in ["garbage", ">2020.13.45", "<notadate", "1899", "any"] {
                r.check("date-unparseable/\(field.rawValue)/\(junk)", ids(field, junk, in: dated).isEmpty,
                        "matched \(ids(field, junk, in: dated))")
            }
        }
        r.check("date-unparseable/inverted-returns-everything",
                ids(.lastWatched, "garbage", in: dated, inverted: true) == ["Dated", "Undated"], "inverted junk")
        r.check("date-valid-still-works", ids(.lastWatched, ">2022", in: dated) == ["Dated"], "\(ids(.lastWatched, ">2022", in: dated))")

        // "none" and bare calendar years.
        var y2025 = makeSnapshot(name: "Y2025", lastWatched: "2025.12.31")
        y2025.dateAdded = "2025.12.31"
        let y2024 = makeSnapshot(name: "Y2024", lastWatched: "2024.12.31")
        let y2026 = makeSnapshot(name: "Y2026", lastWatched: "2026.01.01")
        let undatedFilm = makeSnapshot(name: "Never")
        let years = [y2025, y2024, y2026, undatedFilm]
        r.check("date-none/lastWatched", ids(.lastWatched, "none", in: years) == ["Never"], "\(ids(.lastWatched, "none", in: years))")
        r.check("date-none/inverted", ids(.lastWatched, "NONE", in: years, inverted: true) == ["Y2025", "Y2024", "Y2026"], "inverted none")
        r.check("date-year/2025-spans-the-whole-year", ids(.lastWatched, "2025", in: years) == ["Y2025"],
                "\(ids(.lastWatched, "2025", in: years)); Dec 31 2024 and Jan 1 2026 must be outside")
        r.check("date-year/2024-includes-last-day", ids(.lastWatched, "2024", in: years) == ["Y2024"], "\(ids(.lastWatched, "2024", in: years))")

        // Duration follows the edited runtime when the film has one.
        var edited = makeSnapshot(name: "Edited", duration: "\(150 * 60_000)")
        edited.edited = true
        edited.editedDuration = "\(146 * 60_000)"
        var staleEdit = makeSnapshot(name: "StaleEdit", duration: "\(150 * 60_000)")
        staleEdit.editedDuration = "\(100 * 60_000)"      // not marked edited: ignored
        let runtimes = [edited, staleEdit]
        r.check("duration-effective/at-least-uses-edited", ids(.duration, "150", in: runtimes) == ["StaleEdit"],
                "\(ids(.duration, "150", in: runtimes))")
        r.check("duration-effective/range-uses-edited", ids(.duration, "140-148", in: runtimes) == ["Edited"],
                "\(ids(.duration, "140-148", in: runtimes))")
        r.check("duration-effective/less-than-uses-edited", ids(.duration, "<147", in: runtimes) == ["Edited"],
                "\(ids(.duration, "<147", in: runtimes))")

        var seven = makeSnapshot(name: "Seven")
        seven.descriptionText = "Detective Mills investigates a series of gruesome murders based on the seven deadly sins."
        var other = makeSnapshot(name: "Other")
        other.descriptionText = "A detective retires to the country."
        let plots = [seven, other]
        r.check("synopsis/words-any-order", ids(.synopsis, "detective sins mills", in: plots) == ["Seven"],
                "\(ids(.synopsis, "detective sins mills", in: plots))")
        r.check("synopsis/case-and-spacing", ids(.synopsis, "  SINS    Detective ", in: plots) == ["Seven"], "case/spacing")
        r.check("synopsis/every-word-required", ids(.synopsis, "detective vampire", in: plots).isEmpty, "a missing word still matched")
        r.check("synopsis/single-word-spans-films", ids(.synopsis, "detective", in: plots) == ["Seven", "Other"], "single word")
        r.check("synopsis/inverted", ids(.synopsis, "mills", in: plots, inverted: true) == ["Other"], "inverted")
        r.check("synopsis/aliases", ["synopsis", "plot", "description"].allSatisfy { SearchField.from(alias: $0) == .synopsis },
                "an alias does not resolve to .synopsis")
        search.clearSearch()

        // Leave the library as found for the scenarios that follow.
        await coordinator.deleteFilms(withIDs: [viewer.id, pack.id, solo.id])
        _ = await drainOperations(coordinator)
        return r
    }

    // MARK: - Scenario: Rollback Integrity

    private static func rollbackScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rollback-integrity")
        let store = coordinator.memoryStoreForTesting

        // The corpus is seeded through the COORDINATOR's own entry points, not by writing to
        // the store directly. That matters: the coordinator maintains published state
        // (totalFilmCount, cachedLists, films) alongside the store, and a scenario that
        // seeded behind its back would start with those already disagreeing — every
        // published-state assertion below would then fail on the setup rather than on
        // anything a rollback did.
        let corpus = standardCorpus(count: 30, seed: 0x1201_1BAC)
        coordinator.importFilms(corpus)
        let listID = coordinator.createList(name: "Rollback Target", displayOrder: 900)
        coordinator.addFilmsToList(filmIDs: Set(corpus.prefix(6).map(\.id)), listID: listID)

        // Three ranked films, so the Hall of Fame paths have a real ranking to compact and
        // restore rather than trivially operating on an empty list.
        coordinator.addToHallOfFame(corpus[0].id)
        coordinator.addToHallOfFame(corpus[1].id)
        coordinator.addToHallOfFame(corpus[2].id)

        // Some films carry an override and an infoComplete flag before any case runs, so the
        // two library-wide reset paths have work to do without seeding state inside their own
        // mutation closure — which would put that state outside the case's own baseline.
        for index in [4, 5, 6] {
            var film = store.getFilm(corpus[index].id) ?? corpus[index]
            film.rotationThresholdOverride = 24
            await coordinator.updateFilm(film)
        }
        for index in [7, 8] {
            var film = store.getFilm(corpus[index].id) ?? corpus[index]
            film.infoComplete = true
            await coordinator.updateFilm(film)
        }

        // Give a few releases real wishlist positions, for the same reason.
        let wishlistFilms = corpus.filter { $0.releases.contains { $0.isTopLevel } }.prefix(3)
        for (index, film) in wishlistFilms.enumerated() {
            guard var updated = store.getFilm(film.id) else { continue }
            updated.releases = updated.releases.enumerated().map { offset, release in
                offset == 0 ? release.withWishlist(index + 1) : release
            }
            await coordinator.updateFilm(updated)
        }

        // One film starts in the "Later" queue section, so the exclusivity case below has a
        // real cross-section move to make rather than a plain add.
        _ = coordinator.addFilmsToList(filmIDs: [corpus[21].id],
                                                listID: FilmQueueSection.later.listID)

        _ = await drainOperations(coordinator)
        coordinator.refreshFilms()

        // --- Persisted list membership -------------------------------------------------
        // Runs BEFORE any fault is injected, and is the only part of this scenario that
        // reads SwiftData rather than MemoryStore.
        //
        // Every other list assertion in this harness compares MemoryStore against itself
        // or against the coordinator's published copies of it. That is the right shape for
        // rollback, but it is blind in one specific direction: DataCoordinator's list
        // mutations are optimistic, so memory is correct the instant they are called and
        // stays correct whether or not the background write did anything at all. A
        // batchAddFilmsToLists that inserted no rows, or a batchRemoveFilmsFromLists that
        // matched none, would pass every existing check and only surface on the next cold
        // launch, as list memberships that silently vanished.
        r.checks.append(contentsOf: await membershipPersistenceChecks(coordinator: coordinator,
                                                                     corpus: corpus))
        r.checks.append(contentsOf: await listNamingChecks(coordinator: coordinator))

        _ = await drainOperations(coordinator)
        coordinator.refreshFilms()

        let baseline = storeDigest(store)
        DebugPersistenceFault.reset()

        // --- Scalar edit ---------------------------------------------------------------
        await rollbackCase("update-film", coordinator: coordinator, into: &r) {
            var edited = corpus[10]
            edited.name = "Rolled Back Title"
            edited.userRating = 5
            await coordinator.updateFilm(edited)
        }

        // --- Viewing dates (also the queue auto-removal trigger) -------------------------
        await rollbackCase("update-viewing-dates", coordinator: coordinator, into: &r) {
            let today = DateFormatter()
            today.dateFormat = "yyyy.MM.dd"
            let stamp = today.string(from: Date())
            coordinator.updateViewingDates(
                filmID: corpus[11].id,
                calendarTable: corpus[11].calendarTable + [stamp],
                lastWatched: stamp, watched: true)
        }

        // --- Deletion of an unranked film -------------------------------------------------
        await rollbackCase("delete-film", coordinator: coordinator, into: &r) {
            await coordinator.deleteFilms(withIDs: [corpus[12].id])
        }

        // --- Deletion of a film that is in a list ------------------------------------------
        await rollbackCase("delete-film-in-list", coordinator: coordinator, into: &r) {
            await coordinator.deleteFilms(withIDs: [corpus[0].id, corpus[3].id])
        }

        // --- Deletion of a RANKED film: the ranking compaction must be undone too -----------
        await rollbackCase("delete-ranked-film", coordinator: coordinator, into: &r) {
            await coordinator.deleteFilms(withIDs: [corpus[1].id])
        }

        // --- deleteFilms(onPersisted:) contract ------------------------------------------
        // FilmManager hangs irreversible poster teardown (cache eviction + file removal)
        // off this callback. The whole point is that it must fire ONLY when the deletion
        // actually commits: on the rollback path the films come back, and artwork erased
        // in the meantime could not come back with them. Both directions are asserted
        // because only the pair proves the contract — a callback that never fires would
        // pass the negative case on its own.
        let persistedProbe = OnPersistedProbe()

        await rollbackCase("delete-film-onpersisted-suppressed",
                           coordinator: coordinator, into: &r) {
            await coordinator.deleteFilms(withIDs: [corpus[14].id]) { persistedProbe.fired += 1 }
        }
        r.check("delete-film-onpersisted-suppressed/callback-not-invoked",
                persistedProbe.fired == 0,
                "onPersisted ran \(persistedProbe.fired) time(s) on a rolled-back deletion — "
                    + "irreversible cleanup would have run against films that were restored")

        // The committing case. Run with fault injection off, then the deletion is undone by
        // re-importing the snapshot so the digest baseline the remaining cases rely on is
        // left exactly as it was found.
        let committedSubject = corpus[14]
        DebugPersistenceFault.mode = .none
        await coordinator.deleteFilms(withIDs: [committedSubject.id]) { persistedProbe.fired += 1 }
        let committedDrained = await drainOperations(coordinator)
        r.check("delete-film-onpersisted-committed/operations-drained", committedDrained,
                "no operation left pending")
        r.check("delete-film-onpersisted-committed/callback-invoked",
                persistedProbe.fired == 1,
                "onPersisted ran \(persistedProbe.fired) time(s) on a committed deletion — "
                    + "expected exactly 1, or poster cleanup never happens at all")
        coordinator.importFilms([committedSubject])
        _ = await drainOperations(coordinator)

        // --- FilmSheet save: scalars + releases + list membership in one changeset ----------
        await rollbackCase("save-changeset-existing", coordinator: coordinator, into: &r) {
            var edited = corpus[13]
            edited.name = "Changeset Edit"
            edited.notes = "changed"
            edited.lastModified = "2026.01.01"
            let changeset = FilmChangeset(
                filmID: edited.id, isNewFilm: false, filmSnapshot: edited,
                releasesToCreate: [], releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [listID], listsToRemove: [])
            coordinator.saveFilmChangeset(changeset)
        }

        // --- FilmSheet save of a NEW film: the rollback must remove it entirely --------------
        await rollbackCase("save-changeset-new-film", coordinator: coordinator, into: &r) {
            var fresh = makeSnapshot(name: "Brand New Film")
            fresh.lastModified = "2026.01.01"
            fresh.numberOfDiscs = "0"
            let changeset = FilmChangeset(
                filmID: fresh.id, isNewFilm: true, filmSnapshot: fresh,
                releasesToCreate: [], releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [], listsToRemove: [])
            coordinator.saveFilmChangeset(changeset)
        }

        // --- List membership ------------------------------------------------------------------
        await rollbackCase("add-films-to-list", coordinator: coordinator, into: &r) {
            coordinator.addFilmsToList(
                filmIDs: Set(corpus.suffix(5).map(\.id)), listID: listID)
        }
        await rollbackCase("remove-films-from-list", coordinator: coordinator, into: &r) {
            coordinator.removeFilmsFromList(
                filmIDs: Set(corpus.prefix(3).map(\.id)), listID: listID)
        }
        await rollbackCase("add-films-to-list-immediate", coordinator: coordinator, into: &r) {
            _ = coordinator.addFilmsToList(
                filmIDs: [corpus[20].id], listID: FilmQueueSection.soon.listID)
        }

        // --- Film Queue exclusivity: a cross-section add is an enforcement removal PLUS an
        //     add, and both now ride in ONE tracked write against one database transaction
        //     (DataManager.moveFilmsBetweenLists), with one composed rollback. The
        //     dispatched-a-tracked-write check below therefore expects a single injected
        //     failure, not two — a second would mean the halves had come apart again, which
        //     is what used to let a committed removal survive a failed add and leave the
        //     film in no section at all. The film's initial section was established during
        //     setup, before the baseline digest, so it is part of the state the whole
        //     sequence must return to. ------------------------------------------------------
        await rollbackCase("queue-exclusivity-move", coordinator: coordinator, into: &r) {
            _ = coordinator.addFilmsToList(filmIDs: [corpus[21].id],
                                                    listID: FilmQueueSection.upNext.listID)
        }

        // --- List lifecycle -----------------------------------------------------------------
        await rollbackCase("create-list", coordinator: coordinator, into: &r) {
            _ = coordinator.createList(name: "Ephemeral", displayOrder: 950)
        }
        await rollbackCase("update-list", coordinator: coordinator, into: &r) {
            coordinator.updateList(listID: listID, name: "Renamed Target",
                                              displayOrder: 901, sortFilterOptions: ["x"])
        }
        await rollbackCase("delete-list", coordinator: coordinator, into: &r) {
            coordinator.deleteList(listID: listID)
        }
        await rollbackCase("batch-update-list-orders", coordinator: coordinator, into: &r) {
            coordinator.batchUpdateListOrders([(listID: listID, displayOrder: 42)])
        }

        // --- Hall of Fame ---------------------------------------------------------------------
        await rollbackCase("hof-add", coordinator: coordinator, into: &r) {
            coordinator.addToHallOfFame(corpus[15].id)
        }
        await rollbackCase("hof-remove", coordinator: coordinator, into: &r) {
            coordinator.removeFromHallOfFame(Set([corpus[0].id, corpus[2].id]))
        }
        // The reorder is debounced by one second before it dispatches.
        await rollbackCase("hof-reorder", coordinator: coordinator, into: &r,
                           settle: .milliseconds(1400)) {
            coordinator.reorderHallOfFame(store.hallOfFameFilms.reversed())
        }

        // --- Wishlist reorder (also debounced) --------------------------------------------------
        if wishlistFilms.count >= 2 {
            let pairs = wishlistFilms.compactMap { film -> (filmID: UUID, releaseID: UUID)? in
                guard let release = film.releases.first else { return nil }
                return (filmID: film.id, releaseID: release.id)
            }
            await rollbackCase("wishlist-reorder", coordinator: coordinator, into: &r,
                               settle: .milliseconds(1400)) {
                coordinator.reorderWishlist(pairs.reversed())
            }
        } else {
            r.check("wishlist-specimen-available", false, "corpus produced no wishlistable releases")
        }

        // --- Import paths --------------------------------------------------------------------
        await rollbackCase("import-films", coordinator: coordinator, into: &r) {
            let imported = standardCorpus(count: 5, seed: 0xBEEF_0001)
            coordinator.importFilms(imported)
        }
        await rollbackCase("imported-rating-updates", coordinator: coordinator, into: &r) {
            coordinator.applyImportedRatingUpdates(
                corpus.prefix(4).map { (filmID: $0.id, rating: ($0.userRating + 3) % 6) })
        }

        // --- Library-wide resets ------------------------------------------------------------
        await rollbackCase("reset-rotation-overrides", coordinator: coordinator, into: &r) {
            coordinator.resetAllRotationThresholdOverrides()
        }
        await rollbackCase("reset-info-complete", coordinator: coordinator, into: &r) {
            coordinator.resetAllInfoCompleteFlags()
        }

        // --- Whole-sequence check --------------------------------------------------------------
        // Every case above restored individually. This asserts they also compose: after the
        // full sequence the store is where it started, so no case left a residue that a
        // later case's baseline silently absorbed.
        r.check("sequence-composes", storeDigest(store) == baseline,
                storeDigest(store) == baseline
                    ? "\(DebugPersistenceFault.injectedCount) injected failures later, the store is byte-identical to its baseline"
                    : firstDifference(baseline, storeDigest(store)))
        r.metric("injected-failures", Double(DebugPersistenceFault.injectedCount), "count")

        // --- The other failure shape: the write COMMITTED and still reported failure ---------
        // Every rollback closure above is written for "nothing was persisted". Several
        // DataManager methods commit in batches (batchAddFilmsToLists,
        // batchRemoveFilmsFromLists and batchInsertFilms all call save() per batch), so a
        // failure or cancellation partway through leaves earlier batches committed while the rollback restores ALL of memory.
        // This case does not assert that the outcome is correct — it cannot be, by
        // construction — it pins the fact that the rollback runs identically in both cases,
        // which is what makes the divergence silent.
        let preAfterWork = storeDigest(store)
        DebugPersistenceFault.mode = .afterWork
        var edited = corpus[25]
        edited.name = "Committed Then Failed"
        await coordinator.updateFilm(edited)
        _ = await drainOperations(coordinator)
        DebugPersistenceFault.mode = .none
        r.check("after-work-failure-still-rolls-memory-back",
                storeDigest(store) == preAfterWork,
                "memory is restored even though the write had already committed — the "
                    + "rollback cannot distinguish the two cases, so a partially-committed "
                    + "batch write leaves the database ahead of memory with nothing to detect it")

        DebugPersistenceFault.reset()

        // Clean up so the following scenarios see the library they expect.
        store.deleteFilms(ids: Set(corpus.map(\.id)))
        store.deleteList(listID: listID)
        coordinator.refreshFilms()
        return r
    }

    // MARK: - Round-Trip Support

    /// Films whose STRING fields carry values that look like other types. Nothing in the
    /// backup format records a field's declared type, so these are the values whose
    /// reconstruction is a guess.
    private static func adversarialExportCorpus() -> [FilmSnapshot] {
        var films: [FilmSnapshot] = []
        func add(_ name: String, _ mutate: (inout FilmSnapshot) -> Void) {
            var film = makeSnapshot(name: name)
            mutate(&film)
            films.append(film)
        }

        add("RT LeadingZero") { $0.numberOfDiscs = "007"; $0.sortName = "007" }
        add("RT TrailingZeroDecimal") { $0.aspectRatio = "2.00" }
        add("RT PlainDecimal") { $0.aspectRatio = "1.85" }
        add("RT BooleanText") { $0.notes = "true"; $0.comments = "false" }
        add("RT ArrayShapedText") { $0.notes = #"["not","an","array"]"# }
        add("RT BracketText") { $0.notes = "[REC]" }
        add("RT NumericName") { $0.sortName = "1917" }
        add("RT PlusPrefixed") { $0.numberOfDiscs = "+5" }
        add("RT Whitespace") { $0.notes = "  padded  " }
        add("RT XMLSpecials") { $0.notes = "a < b & c > d \"quoted\" 'single'" }
        add("RT CDATATerminator") { $0.notes = "closing ]]> sequence" }
        add("RT ControlChars") { $0.notes = "bell\u{0007}and\u{0001}nul-ish" }
        add("RT Unicode") { $0.notes = "émoji 🎬 中文 ünïcödé"; $0.alternateTitle = ["Ünterwelt", "映画"] }
        add("RT EmptyVsAbsent") { $0.notes = ""; $0.comments = "" }
        add("RT ArrayWithSpecials") {
            $0.cast = ["D'Onofrio, Vincent", "a & b", "<tag>", "]]>", "quote\"inside"]
        }
        add("RT LongText") { $0.descriptionText = String(repeating: "long ", count: 2000) + "end" }
        add("RT UUIDShapedText") { $0.notes = "12345678-1234-1234-1234-123456789abc" }
        add("RT NegativeNumberText") { $0.numberOfDiscs = "-3" }
        add("RT ScientificText") { $0.aspectRatio = "1e3" }
        add("RT RankedAndRated") { $0.hofPosition = 3; $0.userRating = 4; $0.watched = true }
        // APPENDED, not inserted: the round-trip checks below index this array positionally,
        // so a new case belongs at the end where it shifts nothing.
        //
        // Array elements whose own TEXT is entity-shaped. XMLParser hands the writer's JSON
        // back with every entity already resolved, so the importer's array branch used to
        // unescape a SECOND time: "&amp;" came back as "&", "&lt;p&gt;" as "<p>", and the
        // "&quot;" case produced bare quotes that broke the JSON outright — losing the WHOLE
        // field rather than one element. Distinct from RT ArrayWithSpecials, which carries
        // the raw characters and always round-tripped correctly.
        add("RT ArrayWithEntityText") {
            $0.cast = ["Tom &amp; Jerry", "&lt;p&gt;", "&#65;", "plain"]
            $0.tags = ["He said &quot;hi&quot;"]
            $0.alternateTitle = ["R&amp;B &apos;74"]
        }
        // A LITERAL backslash before an apostrophe, in both a String field and an array
        // element. DBPackager used to run a `\'` → `'` cleanup over every outgoing string,
        // and it damaged each of these differently:
        //   • notes lost its backslashes outright, unrecoverably.
        //   • cast arrives at the packager as JSON in which the backslash is already
        //     encoded as `\\`; the cleanup matched the `\'` inside that `\\'` and produced
        //     `\'`, which is not a legal JSON escape. The array then failed to decode on
        //     restore and the WHOLE field came back empty — one apostrophe losing an entire
        //     cast list. Distinct from RT ArrayWithSpecials, whose D'Onofrio carries a bare
        //     apostrophe and always round-tripped correctly.
        // The read-side counterpart in DBImporter.decodeArray is unaffected and still
        // repairs genuinely legacy files that carry the invalid escape.
        add("RT BackslashApostrophe") {
            $0.notes = #"He said \'hi\' about D\'Onofrio"#
            $0.cast = [#"D\'Onofrio, Vincent"#, "plain"]
            $0.comments = #"path C:\'temp'"#
        }
        return films
    }

    /// Inserts a corpus into the sandbox store through the real model types, so the export
    /// reads exactly what the app would have written.
    @MainActor
    private static func seedStore(_ films: [FilmSnapshot],
                                  container: ModelContainer) throws -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for film in films { context.insert(film.toFilm()) }
        try context.save()
        return context
    }

    /// Runs a real export and returns the package URL, or nil with the failure recorded.
    @MainActor
    private static func runExport(coordinator: DataCoordinator,
                                  filename: String) async -> URL? {
        let exporter = DBExporter(modelContainer: coordinator.modelContainer)
        do {
            let result = try await exporter.createCompleteBackup(
                filename: filename,
                destinationURL: DebugSandbox.rootURL,
                isBackgroundExport: false,
                includeSettings: true,
                posterUIDs: Set(coordinator.getAllPosterUIDs()))
            return result.packageURL
        } catch {
            Self.log("Export failed in harness: \(error)")
            return nil
        }
    }

    // MARK: - Scenario: Export Round Trip

    /// Exports a corpus of type-ambiguous values and reads the backup back, comparing every
    /// string field against what was written. Stops at the parse layer — the restore's own
    /// field mapping is covered end to end by `restore-endtoend`.
    private static func exportRoundTripScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "export-roundtrip")

        let corpus = adversarialExportCorpus()
        do {
            _ = try seedStore(corpus, container: coordinator.modelContainer)
        } catch {
            r.check("seed-store", false, "\(error)")
            return r
        }
        r.check("seed-store", true, "\(corpus.count) adversarial film(s) inserted")

        guard let packageURL = await runExport(coordinator: coordinator, filename: "roundtrip") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        r.check("export-succeeds", true, packageURL.lastPathComponent)

        let xmlURL = packageURL.appendingPathComponent("backup.xml")
        r.check("package-contains-xml",
                FileManager.default.fileExists(atPath: xmlURL.path(percentEncoded: false)), "")
        if let size = (try? xmlURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            r.metric("backup-xml-size", Double(size), "bytes")
        }

        let parsed: ParsedBackup
        do {
            parsed = try await DBImporter().parseBackupFile(at: xmlURL)
        } catch {
            r.check("backup-parses", false, "\(error)")
            return r
        }
        r.check("backup-parses", true, "\(parsed.objects.count) object(s)")

        // Every film written must come back. A film silently dropped by the reflection-based
        // extractor is the worst possible export failure and the cheapest thing to check.
        let filmObjects = parsed.objects.filter { $0.entityName == "Film" }
        let parsedByID: [String: ParsedObject] = Dictionary(
            filmObjects.compactMap { object -> (String, ParsedObject)? in
                guard let id = object.properties["id"] as? String else { return nil }
                return (id.uppercased(), object)
            }, uniquingKeysWith: { first, _ in first })

        let missing = corpus.filter { parsedByID[$0.id.uuidString.uppercased()] == nil }
        r.check("every-film-survives-export", missing.isEmpty,
                "\(missing.count) of \(corpus.count) film(s) absent from the backup: "
                    + missing.prefix(3).map(\.name).joined(separator: ", "))

        r.check("manifest-counts-films",
                parsed.manifest["Film"] ?? 0 >= corpus.count,
                "manifest says \(parsed.manifest["Film"] ?? 0), corpus was \(corpus.count)")

        // --- Field-level fidelity ---------------------------------------------------------
        // Each check names one film and one field, so a failure states exactly which value
        // did not survive rather than "something changed".
        func stringField(_ film: FilmSnapshot, _ key: String) -> (parsed: Any?, expected: String)? {
            guard let object = parsedByID[film.id.uuidString.uppercased()] else { return nil }
            let expected: String
            switch key {
            case "notes":          expected = film.notes
            case "comments":       expected = film.comments
            case "aspectRatio":    expected = film.aspectRatio
            case "numberOfDiscs":  expected = film.numberOfDiscs
            case "sortName":       expected = film.sortName
            case "name":           expected = film.name
            case "descriptionText": expected = film.descriptionText
            default:               expected = ""
            }
            return (object.properties[key], expected)
        }

        /// A string field round-trips only when the parsed value is a String equal to what
        /// was written. A parsed Int64/Double/Bool/array means the type guess reinterpreted
        /// it, which is where the restore's `parseString` then has to convert it back — or
        /// give up and substitute a default.
        func checkStringField(_ film: FilmSnapshot, _ key: String, _ label: String) {
            guard let (value, expected) = stringField(film, key) else {
                r.check("field:\(label)", false, "film missing from backup")
                return
            }
            let asString = value as? String
            let survived = asString == expected
            let describedType = value.map { String(describing: type(of: $0)) } ?? "absent"
            r.check("field:\(label)", survived,
                    survived
                        ? "String round-tripped exactly"
                        : "wrote String \(String(reflecting: expected)) → parsed \(describedType) "
                            + String(describing: value ?? "nil")
                            + " — the format records no type, so the reader must guess")
        }

        checkStringField(corpus[0], "numberOfDiscs", "leading-zero-numeric-string")
        checkStringField(corpus[1], "aspectRatio", "trailing-zero-decimal-string")
        checkStringField(corpus[2], "aspectRatio", "plain-decimal-string")
        checkStringField(corpus[3], "notes", "boolean-text-string")
        checkStringField(corpus[4], "notes", "array-shaped-text-string")
        checkStringField(corpus[5], "notes", "bracketed-text-string")
        checkStringField(corpus[6], "sortName", "numeric-name-string")
        checkStringField(corpus[7], "numberOfDiscs", "plus-prefixed-string")
        checkStringField(corpus[9], "notes", "xml-special-characters")
        checkStringField(corpus[10], "notes", "cdata-terminator")
        checkStringField(corpus[12], "notes", "unicode-text")
        checkStringField(corpus[8], "notes", "leading-trailing-whitespace")
        checkStringField(corpus[15], "descriptionText", "very-long-text")
        checkStringField(corpus[16], "notes", "uuid-shaped-text")
        checkStringField(corpus[17], "numberOfDiscs", "negative-number-string")
        checkStringField(corpus[18], "aspectRatio", "scientific-notation-string")

        // Control characters are stripped on write by design (they are illegal in XML 1.0).
        // Asserted as the documented behavior rather than as fidelity, so the deliberate
        // loss is recorded rather than mistaken for a bug later.
        if let object = parsedByID[corpus[11].id.uuidString.uppercased()],
           let notes = object.properties["notes"] as? String {
            r.check("field:control-characters-stripped",
                    !notes.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D },
                    "illegal XML scalars removed on write (documented, lossy): \(String(reflecting: notes))")
        }

        // Arrays are JSON-encoded, which is the one field kind that carries its own type.
        if let object = parsedByID[corpus[14].id.uuidString.uppercased()] {
            let parsedCast = object.properties["cast"] as? [String]
            r.check("field:string-array-round-trips", parsedCast == corpus[14].cast,
                    "expected \(corpus[14].cast), got \(String(describing: parsedCast))")
        }
        if let object = parsedByID[corpus[12].id.uuidString.uppercased()] {
            let parsed = object.properties["alternateTitle"] as? [String]
            r.check("field:unicode-array-round-trips", parsed == corpus[12].alternateTitle,
                    "expected \(corpus[12].alternateTitle), got \(String(describing: parsed))")
        }
        // Entity-shaped element TEXT — the double-unescape case. The third field is the
        // severe one: unescaping "&quot;" into a bare quote invalidates the JSON, and the
        // importer's decode failure drops the entire array rather than one element.
        if let object = parsedByID[corpus[20].id.uuidString.uppercased()] {
            let cast = object.properties["cast"] as? [String]
            r.check("field:entity-text-array-round-trips", cast == corpus[20].cast,
                    "expected \(corpus[20].cast), got \(String(describing: cast))")
            let tags = object.properties["tags"] as? [String]
            r.check("field:entity-quote-array-survives", tags == corpus[20].tags,
                    "expected \(corpus[20].tags), got \(String(describing: tags))")
            let alt = object.properties["alternateTitle"] as? [String]
            r.check("field:entity-mixed-array-round-trips", alt == corpus[20].alternateTitle,
                    "expected \(corpus[20].alternateTitle), got \(String(describing: alt))")
        }

        // Scalars whose declared type matches their shape are the control group: if these
        // failed, the problem would be the pipeline as a whole rather than the type guess.
        if let object = parsedByID[corpus[19].id.uuidString.uppercased()] {
            let rank = object.properties["hofPosition"]
            let rating = object.properties["userRating"]
            let watched = object.properties["watched"]
            r.check("field:int-round-trips", (rank as? Int64).map(Int.init) == 3,
                    "hofPosition → \(String(describing: rank))")
            r.check("field:rating-round-trips", (rating as? Int64).map(Int.init) == 4,
                    "userRating → \(String(describing: rating))")
            r.check("field:bool-round-trips", watched as? Bool == true,
                    "watched → \(String(describing: watched))")
        }

        // An empty String stays an empty String rather than collapsing to a null. Before the
        // declared-type attribute the two were indistinguishable on read (both are an empty
        // element), which was harmless only because every String field on these models is
        // non-optional and defaults to "" anyway. Pinned here so the distinction is not lost
        // again the moment an optional String field is added.
        if let object = parsedByID[corpus[13].id.uuidString.uppercased()] {
            r.check("field:empty-string-stays-a-string",
                    object.properties["notes"] as? String == "",
                    "notes → \(String(describing: object.properties["notes"]))")
        }

        return r
    }

    // MARK: - Scenario: Malformed Backups

    /// The importer is the only thing standing between a corrupt or hostile file and a
    /// restore that has already deleted the user's library. Each case asserts the specific
    /// error, not merely that something was thrown: "rejected for the wrong reason" is how a
    /// validation gap hides.
    private static func malformedBackupScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "export-malformed")

        let root = DebugSandbox.rootURL ?? FileManager.default.temporaryDirectory
        let scratch = root.appendingPathComponent("harness-malformed", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func write(_ name: String, _ contents: String) -> URL? {
            let url = scratch.appendingPathComponent(name)
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch { return nil }
        }

        func parse(_ url: URL) async -> Result<ParsedBackup, any Error> {
            do { return .success(try await DBImporter().parseBackupFile(at: url)) }
            catch { return .failure(error) }
        }

        let header = #"<?xml version="1.0" encoding="utf-8"?>"#

        // Absent file.
        let absent = scratch.appendingPathComponent("does-not-exist.xml")
        if case .failure(let error) = await parse(absent) {
            if case DBImporterError.fileNotFound = error {
                r.check("rejects:absent-file", true, "")
            } else {
                r.check("rejects:absent-file", false, "wrong error: \(error)")
            }
        } else {
            r.check("rejects:absent-file", false, "parsed a nonexistent file")
        }

        // Not XML at all.
        if let url = write("garbage.xml", "this is not xml at all"),
           case .failure(let error) = await parse(url) {
            r.check("rejects:non-xml", error is DBImporterError, "\(error)")
        } else {
            r.check("rejects:non-xml", false, "accepted non-XML content")
        }

        // Truncated mid-object — the shape a copy interrupted by a full disk produces.
        let truncated = header + """
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z">
          <Objects>
            <Object id="Film-1" entity="Film">
              <Properties>
                <Property name="name">Half a f
        """
        if let url = write("truncated.xml", truncated), case .failure(let error) = await parse(url) {
            r.check("rejects:truncated", error is DBImporterError, "\(error)")
        } else {
            r.check("rejects:truncated", false, "accepted a truncated file")
        }

        // Wrong format marker — a different app's XML, or a renamed file.
        let wrongFormat = header + """
        <FilmTrackerBackup format="SomeOtherApp" version="1" created="2026-01-01T00:00:00Z">
          <Objects></Objects>
        </FilmTrackerBackup>
        """
        if let url = write("wrong-format.xml", wrongFormat), case .failure(let error) = await parse(url) {
            if case DBImporterError.unsupportedFormat = error {
                r.check("rejects:wrong-format", true, "")
            } else {
                r.check("rejects:wrong-format", false, "wrong error: \(error)")
            }
        } else {
            r.check("rejects:wrong-format", false, "accepted a foreign format")
        }

        // A future version this build cannot interpret.
        let futureVersion = header + """
        <FilmTrackerBackup format="FilmTrackerXML" version="99" created="2026-01-01T00:00:00Z">
          <Objects></Objects>
        </FilmTrackerBackup>
        """
        if let url = write("future-version.xml", futureVersion), case .failure(let error) = await parse(url) {
            if case DBImporterError.unsupportedVersion = error {
                r.check("rejects:future-version", true, "")
            } else {
                r.check("rejects:future-version", false, "wrong error: \(error)")
            }
        } else {
            r.check("rejects:future-version", false, "accepted a newer format version")
        }

        // Missing required root attributes.
        let noVersion = header + """
        <FilmTrackerBackup format="FilmTrackerXML" created="2026-01-01T00:00:00Z">
          <Objects></Objects>
        </FilmTrackerBackup>
        """
        if let url = write("no-version.xml", noVersion), case .failure(let error) = await parse(url) {
            if case DBImporterError.missingRequiredElement = error {
                r.check("rejects:missing-version", true, "")
            } else {
                r.check("rejects:missing-version", false, "wrong error: \(error)")
            }
        } else {
            r.check("rejects:missing-version", false, "accepted a file with no version")
        }

        // Nesting bomb — must be refused by the depth cap rather than recursing.
        let depth = 80
        let nested = header
            + "<FilmTrackerBackup format=\"FilmTrackerXML\" version=\"1\" created=\"2026-01-01T00:00:00Z\">"
            + String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
            + "</FilmTrackerBackup>"
        if let url = write("deep.xml", nested), case .failure(let error) = await parse(url) {
            r.check("rejects:excessive-nesting", error is DBImporterError, "\(error)")
        } else {
            r.check("rejects:excessive-nesting", false, "accepted \(depth)-level nesting")
        }

        // An object with no id attribute is dropped rather than restored half-formed.
        let anonymous = header + """
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z">
          <Objects>
            <Object entity="Film">
              <Properties><Property name="name">No ID</Property></Properties>
            </Object>
            <Object id="Film-A" entity="Film">
              <Properties><Property name="name">Has ID</Property></Properties>
            </Object>
          </Objects>
        </FilmTrackerBackup>
        """
        if let url = write("anonymous.xml", anonymous), case .success(let backup) = await parse(url) {
            r.check("drops:object-without-id", backup.objects.count == 1,
                    "\(backup.objects.count) object(s) kept of 2")
        } else {
            r.check("drops:object-without-id", false, "file failed to parse")
        }

        // A well-formed but empty backup is valid: restoring it yields an empty library,
        // which is a legitimate thing to have backed up.
        let empty = header + """
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z">
          <Manifest></Manifest>
          <Objects></Objects>
        </FilmTrackerBackup>
        """
        if let url = write("empty.xml", empty), case .success(let backup) = await parse(url) {
            r.check("accepts:empty-backup", backup.objects.isEmpty, "\(backup.objects.count) objects")
        } else {
            r.check("accepts:empty-backup", false, "a valid empty backup was rejected")
        }

        // A CDATA section carrying its own terminator, written the way DBPackager writes it.
        // If the split-and-rejoin were wrong the file would not parse at all.
        let cdata = header + """
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z">
          <Objects>
            <Object id="Film-B" entity="Film">
              <Properties><Property name="notes"><![CDATA[closing ]]]]><![CDATA[> sequence]]></Property></Properties>
            </Object>
          </Objects>
        </FilmTrackerBackup>
        """
        if let url = write("cdata.xml", cdata), case .success(let backup) = await parse(url) {
            let notes = backup.objects.first?.properties["notes"] as? String
            r.check("accepts:split-cdata", notes == "closing ]]> sequence",
                    "got \(String(describing: notes))")
        } else {
            r.check("accepts:split-cdata", false, "split CDATA failed to parse")
        }

        return r
    }

    // MARK: - Scenario: End-to-End Restore

    /// The whole pipeline against the real DBRestorer: seed → export → mutate the live
    /// library → restore → re-read the rebuilt store and compare field by field.
    ///
    /// DESTRUCTIVE: this deletes and recreates the sandbox store, which orphans the
    /// coordinator's container. It runs last for that reason.
    private static func restoreEndToEndScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "restore-endtoend")

        // A distinctive settings value, so the scenario can tell restored settings apart from
        // whatever the session happens to be carrying. Both MUST be members of
        // Preferences.rotationThresholdOptions — the setter silently replaces anything else
        // with the registered default, which would make this check report a failure that is
        // entirely its own doing.
        let backupThreshold = 48
        let sessionThreshold = 18
        do {
            try await coordinator.saveSettings(
                SettingsSnapshot(defaultRotationThreshold: backupThreshold))
        } catch {
            r.check("seed-settings", false, "\(error)")
        }

        let corpus = adversarialExportCorpus()
        do {
            _ = try seedStore(corpus, container: coordinator.modelContainer)
        } catch {
            r.check("seed-store", false, "\(error)")
            return r
        }

        // --- Poisoned list names --------------------------------------------------------
        // Written straight into the container, bypassing ListManager's uniquification, so
        // the backup carries exactly what a hand-edited file, a merge of two libraries, or
        // a build that predated the rename guard could: user lists sharing one name (in two
        // different casings, since the comparison is case-insensitive) and one squatting on
        // a smart list's name. A backup is not a trusted input, and a restore is the one
        // moment the app can correct this quietly; the checks after the restore below are
        // what hold it to that.
        do {
            let context = ModelContext(coordinator.modelContainer)
            context.autosaveEnabled = false
            for (index, name) in ["Collision", "Collision", "collision",
                                  SmartListType.purchased.rawValue,
                                  FilmQueueSection.upNext.displayName].enumerated() {
                context.insert(ListObject(listID: UUID(), listName: name, viewStyle: "",
                                          sortFilterOptions: [], displayOrder: 700 + index))
            }
            try context.save()
        } catch {
            r.check("seed-poisoned-list-names", false, "\(error)")
        }

        guard let packageURL = await runExport(coordinator: coordinator, filename: "endtoend") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        r.check("export-succeeds", true, packageURL.lastPathComponent)

        // The library moves on after the backup: a film is deleted, another edited, and the
        // session's settings are changed. A correct restore reverses all of it.
        let deletedID = corpus[0].id
        let editedID = corpus[1].id
        do {
            let context = ModelContext(coordinator.modelContainer)
            context.autosaveEnabled = false
            let films = try context.fetch(FetchDescriptor<Film>())
            for film in films where film.id == deletedID { context.delete(film) }
            for film in films where film.id == editedID { film.name = "Edited After Backup" }
            try context.save()
            Preferences.defaultRotationThreshold = sessionThreshold
            try await coordinator.saveSettings(
                SettingsSnapshot(defaultRotationThreshold: sessionThreshold))
            r.check("session-settings-seeded",
                    Preferences.defaultRotationThreshold == sessionThreshold,
                    "Preferences holds \(Preferences.defaultRotationThreshold), expected \(sessionThreshold) — "
                        + "a clamped value here would invalidate the restored-settings check below")
        } catch {
            r.check("post-backup-mutation", false, "\(error)")
        }

        // --- The restore itself -------------------------------------------------------------
        // The snapshot cache is written first, so the invalidation checks below have files
        // to prove gone: a cache left in place would validate against the restored store
        // whenever the two differ only outside the fingerprint (see MemoryStoreCache.invalidateOnDisk).
        let cacheFiles = ["memorystore-fingerprint.bin", "memorystore-cache.bin"]
            .compactMap { Preferences.dataFolderURL?.appendingPathComponent($0) }
        let cacheExists = { cacheFiles.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } }
        await coordinator.saveImmediately()
        r.check("restore-cache/seeded-before-restore", cacheExists().allSatisfy { $0 },
                "cache files present: \(cacheExists())")

        let restorer = DBRestorer(container: coordinator.modelContainer, dataCoordinator: coordinator)
        do {
            try await restorer.restoreFromBackup(at: packageURL) { _, _ in }
            r.check("restore-completes", true, "")
        } catch {
            r.check("restore-completes", false, "\(error)")
            return r
        }

        r.check("restore-cache/invalidated", !cacheExists().contains(true),
                "cache files present after restore: \(cacheExists())")
        // The session's memory still describes the pre-restore library; a flush now must not
        // put that back on disk before the relaunch.
        await coordinator.saveImmediately()
        r.check("restore-cache/not-rewritten-by-session", !cacheExists().contains(true),
                "cache files present after a post-restore flush: \(cacheExists())")
        r.check("restore-reports-no-settings-failure", restorer.settingsApplyFailure == nil,
                restorer.settingsApplyFailure ?? "settings applied without error")

        // --- Re-read the rebuilt store --------------------------------------------------------
        guard let storeURL = Preferences.dataFolderURL?.appendingPathComponent("default.store") else {
            r.check("restored-store-readable", false, "could not resolve store URL")
            return r
        }
        let restored: [Film]
        let restoredLists: [ListObject]
        do {
            let schema = Schema([Film.self, ListObject.self, ListMembership.self,
                                 Release.self, ImportSession.self, SettingsObject.self])
            let configuration = ModelConfiguration(schema: schema, url: storeURL,
                                                   allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            restored = try context.fetch(FetchDescriptor<Film>())
            restoredLists = try context.fetch(FetchDescriptor<ListObject>())
        } catch {
            r.check("restored-store-readable", false, "\(error)")
            return r
        }
        r.check("restored-store-readable", true, "\(restored.count) film(s), \(restoredLists.count) list(s)")

        // --- List names came back unambiguous -------------------------------------------
        // The counterpart to the poisoned names seeded before the export. Distinctness is
        // asserted case-insensitively because that is the comparison every other naming
        // path in the app uses, and because two lists differing only in case are exactly as
        // indistinguishable in a menu as two spelled identically.
        let restoredNames = restoredLists.map { $0.listName }
        let loweredNames = restoredNames.map { $0.lowercased() }
        r.check("restored-list-names-are-unique",
                Set(loweredNames).count == loweredNames.count,
                "\(loweredNames.count) list(s), \(Set(loweredNames).count) distinct name(s): "
                    + restoredNames.sorted().joined(separator: ", "))

        // The three internal Film Queue lists legitimately carry reserved names — they are
        // matched by their fixed UUIDs and restored verbatim — so only user lists are held
        // to this. A user list squatting on a reserved name would shadow a smart list or a
        // Queue section everywhere both are listed.
        let restoredUserLists = restoredLists.filter { FilmQueueSection(listID: $0.listID) == nil }
        let squatters = restoredUserLists.filter {
            SmartListType.isReservedName($0.listName) || FilmQueue.isReservedName($0.listName)
        }
        r.check("restored-user-lists-avoid-reserved-names", squatters.isEmpty,
                squatters.isEmpty
                    ? "\(restoredUserLists.count) user list(s), none on a reserved name"
                    : "reserved name(s) still held by a user list: "
                        + squatters.map { $0.listName }.joined(separator: ", "))

        // Every seeded collision must still be PRESENT, just renamed — resolving a clash by
        // dropping a list would pass the distinctness check above while losing user data.
        let collisionVariants = restoredNames.filter { $0.lowercased().hasPrefix("collision") }
        r.check("restored-colliding-lists-are-all-kept", collisionVariants.count == 3,
                "\(collisionVariants.count) of 3 seeded 'Collision' list(s) survived: "
                    + collisionVariants.sorted().joined(separator: ", "))

        let restoredByID = Dictionary(restored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        r.check("deleted-film-comes-back", restoredByID[deletedID] != nil,
                "a film deleted after the backup must exist again after the restore")
        r.check("post-backup-edit-reverted",
                restoredByID[editedID]?.name == corpus[1].name,
                "expected \(String(reflecting: corpus[1].name)), got "
                    + String(reflecting: restoredByID[editedID]?.name ?? "<absent>"))
        r.check("film-count-matches-backup", restored.count >= corpus.count,
                "\(restored.count) restored vs \(corpus.count) in the corpus")

        // Field-by-field fidelity through the complete pipeline. This is the assertion that
        // matters: everything before it tests a stage, this tests the promise.
        var lost: [String] = []
        for original in corpus {
            guard let film = restoredByID[original.id] else {
                lost.append("\(original.name): film absent")
                continue
            }
            func compare(_ label: String, _ got: String, _ expected: String) {
                if got != expected {
                    lost.append("\(original.name).\(label): wrote \(String(reflecting: expected)) → restored \(String(reflecting: got))")
                }
            }
            compare("name", film.name, original.name)
            compare("sortName", film.sortName, original.sortName)
            compare("aspectRatio", film.aspectRatio, original.aspectRatio)
            compare("numberOfDiscs", film.numberOfDiscs, original.numberOfDiscs)
            compare("comments", film.comments, original.comments)
            compare("releaseYear", film.releaseYear, original.releaseYear)
            compare("duration", film.duration, original.duration)
            if film.userRating != original.userRating {
                lost.append("\(original.name).userRating: \(original.userRating) → \(film.userRating)")
            }
            if film.hofPosition != original.hofPosition {
                lost.append("\(original.name).hofPosition: \(original.hofPosition) → \(film.hofPosition)")
            }
            if film.watched != original.watched {
                lost.append("\(original.name).watched: \(original.watched) → \(film.watched)")
            }
            if film.cast != original.cast {
                lost.append("\(original.name).cast: \(original.cast) → \(film.cast)")
            }
            if film.alternateTitle != original.alternateTitle {
                lost.append("\(original.name).alternateTitle: \(original.alternateTitle) → \(film.alternateTitle)")
            }
        }
        // `notes` is compared separately: the control-character specimen is expected to lose
        // its illegal scalars (stripped on write, by design and documented), so folding it in
        // with the rest would make a deliberate behavior read as a defect.
        for original in corpus where !original.notes.unicodeScalars.contains(where: {
            $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D }) {
            if let film = restoredByID[original.id], film.notes != original.notes {
                lost.append("\(original.name).notes: wrote \(String(reflecting: original.notes)) → restored \(String(reflecting: film.notes))")
            }
        }

        r.check("all-fields-survive-restore", lost.isEmpty,
                lost.isEmpty
                    ? "\(corpus.count) film(s) restored with every compared field intact"
                    : "\(lost.count) field(s) changed: " + lost.prefix(8).joined(separator: " | "))
        r.metric("fields-lost-in-restore", Double(lost.count), "count")

        // --- Restored settings ------------------------------------------------------------------
        // The backup carries defaultRotationThreshold = 48; the session was moved to 18 after
        // the backup was taken. A restore that applies the backup's settings leaves 48 — even
        // though the session's own value was not the default.
        let appliedThreshold = Preferences.defaultRotationThreshold
        r.check("restored-settings-applied", appliedThreshold == backupThreshold,
                appliedThreshold == backupThreshold
                    ? "Preferences carries the backup's value (\(backupThreshold))"
                    : "Preferences carries \(appliedThreshold), the backup carried \(backupThreshold) — "
                        + "the settings applied after a restore are read through DataCoordinator's "
                        + "ORIGINAL container, whose store files this restore just deleted, not "
                        + "through the freshly restored store")

        // And the value that actually landed in the restored database, which is what the
        // mandatory post-restore relaunch will read.
        do {
            let schema = Schema([Film.self, ListObject.self, ListMembership.self,
                                 Release.self, ImportSession.self, SettingsObject.self])
            let configuration = ModelConfiguration(schema: schema, url: storeURL,
                                                   allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let settings = try context.fetch(FetchDescriptor<SettingsObject>())
            r.check("restored-database-carries-backup-settings",
                    settings.first?.defaultRotationThreshold == backupThreshold,
                    "database holds \(String(describing: settings.first?.defaultRotationThreshold)), "
                        + "backup held \(backupThreshold)")
        } catch {
            r.check("restored-database-carries-backup-settings", false, "\(error)")
        }

        // --- Backward compatibility with backups written before the declared-type attribute ----
        //
        // Runs LAST: it restores a package containing no SettingsObject, which wipes the
        // settings the checks above assert on.
        //
        // Every .ftbackup the user already owns was written without `type="string"`, so those
        // files still take the original inference path. This restores a hand-written legacy
        // package to prove two things at once: that such a file still restores at all, and
        // that the values inference misreads are no longer ERASED — the boolean- and
        // array-shaped strings that previously came back as "" now come back as text.
        let legacyID = UUID()
        let legacyURL = (DebugSandbox.rootURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("legacy.ftbackup", isDirectory: true)
        let legacyXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2024-01-01T00:00:00Z" appVersion="1.0">
          <Manifest><Entity name="Film" count="1" /></Manifest>
          <Objects>
            <Object id="Film-\(legacyID.uuidString)" entity="Film">
              <Properties>
                <Property name="id">\(legacyID.uuidString)</Property>
                <Property name="name">Legacy Specimen</Property>
                <Property name="notes">true</Property>
                <Property name="comments">["alpha","beta"]</Property>
                <Property name="numberOfDiscs">007</Property>
                <Property name="userRating">4</Property>
                <Property name="watched">true</Property>
                <Property name="cast">["Real","Array"]</Property>
                <Property name="directors">["D\\'Onofrio, Vincent"]</Property>
              </Properties>
              <Relationships></Relationships>
            </Object>
          </Objects>
        </FilmTrackerBackup>
        """
        do {
            try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
            try legacyXML.write(to: legacyURL.appendingPathComponent("backup.xml"),
                                atomically: true, encoding: .utf8)
            let legacyRestorer = DBRestorer(container: coordinator.modelContainer,
                                            dataCoordinator: nil)
            try await legacyRestorer.restoreFromBackup(at: legacyURL) { _, _ in }
            r.check("legacy-backup-restores", true, "a pre-attribute backup still restores")

            let schema = Schema([Film.self, ListObject.self, ListMembership.self,
                                 Release.self, ImportSession.self, SettingsObject.self])
            let configuration = ModelConfiguration(schema: schema, url: storeURL,
                                                   allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let films = try context.fetch(FetchDescriptor<Film>())
            guard let film = films.first(where: { $0.id == legacyID }) else {
                r.check("legacy-film-present", false, "\(films.count) film(s) restored, none matching")
                return r
            }
            r.check("legacy-film-present", true, film.name)
            r.check("legacy-scalars-intact",
                    film.userRating == 4 && film.watched && film.name == "Legacy Specimen",
                    "rating \(film.userRating), watched \(film.watched), name \(film.name)")
            r.check("legacy-real-array-intact", film.cast == ["Real", "Array"],
                    "cast → \(film.cast)")

            // The apostrophe fallback in DBImporter.decodeArray, which now runs only AFTER
            // a verbatim decode fails. This legacy array carries the invalid `\\'` escape, so
            // the verbatim decode fails and the fallback repairs it — exactly as before the
            // ordering change. A correctly written backup never reaches that path, which is
            // what stopped it corrupting valid JSON (see RT BackslashApostrophe).
            r.check("legacy-apostrophe-escape-repaired",
                    film.directors == ["D'Onofrio, Vincent"],
                    "directors → \(film.directors)")

            // The two shapes that used to be erased. Inference still misreads them in a
            // legacy file — nothing in it says they are strings — but the restore now
            // reconstructs the text instead of substituting an empty string.
            r.check("legacy-boolean-text-not-erased", film.notes == "true",
                    "notes → \(String(reflecting: film.notes)) (was \"\" before the fix)")
            r.check("legacy-array-text-not-erased", film.comments == #"["alpha","beta"]"#,
                    "comments → \(String(reflecting: film.comments)) (was \"\" before the fix)")

            // Numeric reformatting is NOT fixed for legacy files and cannot be: the file
            // records no type, so "007" is indistinguishable from the integer 7. Pinned as
            // the known, documented residue rather than left unstated.
            r.check("legacy-numeric-string-reformatted-not-lost",
                    film.numberOfDiscs == "7",
                    "numberOfDiscs → \(String(reflecting: film.numberOfDiscs)) — a legacy file "
                        + "cannot distinguish \"007\" from 7; content survives, formatting does not")
        } catch {
            r.check("legacy-backup-restores", false, "\(error)")
        }

        // --- A backup carrying an unorderable base release year -------------------------------
        //
        // `baseReleaseYear` is meaningful only as a value strictly BELOW the release year, and
        // the FilmSheet's Steppers cannot produce anything else. A backup can: hand-edited
        // XML, a record written before the ordering rule existed, or an interrupted export.
        // DBRestorer.createRelease drops the base year in both bad shapes rather than letting
        // an impossible pair into the store, where the sidebar, the releases table, and the
        // reports would read it directly.
        //
        // Three releases in one file: the two defects and a well-ordered control, so a guard
        // that simply blanked every base year would fail this scenario rather than pass it.
        //
        // Those three carry the pre-rename `releaseYear` key, as every backup written before
        // full release dates does, so they also prove the legacy key is still read. Two more
        // carry the current `releaseDate` key with a full date — one well-ordered, one
        // inverted — proving the guard compares the base year against the date's YEAR. A
        // sixth is a Blu-ray full date before the 2006 Blu-ray floor: restore drops the date,
        // and the base year beside it, then orphaned, with it.
        let guardFilmID  = UUID()
        let orphanID     = UUID()
        let invertedID   = UUID()
        let wellOrderedID = UUID()
        let fullDateOrderedID  = UUID()
        let fullDateInvertedID = UUID()
        let belowFloorID       = UUID()
        let guardURL = (DebugSandbox.rootURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("base-year-guard.ftbackup", isDirectory: true)
        func releaseXML(_ id: UUID, _ releaseDate: String, _ baseReleaseYear: String,
                        key: String = "releaseYear") -> String {
            """
              <Object id="Release-\(id.uuidString)" entity="Release">
                <Properties>
                  <Property name="id" type="string">\(id.uuidString)</Property>
                  <Property name="format" type="string">Blu-ray</Property>
                  <Property name="\(key)" type="string">\(releaseDate)</Property>
                  <Property name="baseReleaseYear" type="string">\(baseReleaseYear)</Property>
                  <!-- A Release names its film through a filmID PROPERTY, not a
                       <Relationship> element — see DBReader's export note. -->
                  <Property name="filmID" type="string">\(guardFilmID.uuidString)</Property>
                </Properties>
                <Relationships></Relationships>
              </Object>
            """
        }
        let guardXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z" appVersion="1.0">
          <Manifest><Entity name="Film" count="1" /><Entity name="Release" count="6" /></Manifest>
          <Objects>
            <Object id="Film-\(guardFilmID.uuidString)" entity="Film">
              <Properties>
                <Property name="id" type="string">\(guardFilmID.uuidString)</Property>
                <Property name="name" type="string">Base Year Guard Specimen</Property>
                <Property name="releaseYear" type="string">1980</Property>
              </Properties>
              <Relationships></Relationships>
            </Object>
        \(releaseXML(orphanID, "", "2009"))
        \(releaseXML(invertedID, "2010", "2012"))
        \(releaseXML(wellOrderedID, "2010", "2009"))
        \(releaseXML(fullDateOrderedID, "2010.05.04", "2009", key: "releaseDate"))
        \(releaseXML(fullDateInvertedID, "2010.05.04", "2010", key: "releaseDate"))
        \(releaseXML(belowFloorID, "2001.05.05", "2000", key: "releaseDate"))
          </Objects>
        </FilmTrackerBackup>
        """
        do {
            try FileManager.default.createDirectory(at: guardURL, withIntermediateDirectories: true)
            try guardXML.write(to: guardURL.appendingPathComponent("backup.xml"),
                               atomically: true, encoding: .utf8)
            let guardRestorer = DBRestorer(container: coordinator.modelContainer,
                                           dataCoordinator: nil)
            try await guardRestorer.restoreFromBackup(at: guardURL) { _, _ in }

            let schema = Schema([Film.self, ListObject.self, ListMembership.self,
                                 Release.self, ImportSession.self, SettingsObject.self])
            let configuration = ModelConfiguration(schema: schema, url: storeURL,
                                                   allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let releases = try context.fetch(FetchDescriptor<Release>())
            let byID = Dictionary(releases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            r.check("base-year-guard-releases-restored", byID.count >= 6,
                    "\(byID.count) release(s) restored of 6")

            if let orphan = byID[orphanID] {
                r.check("drops:orphaned-base-year",
                        orphan.baseReleaseYear.isEmpty && orphan.releaseDate.isEmpty,
                        "releaseDate \(String(reflecting: orphan.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: orphan.baseReleaseYear))")
            } else {
                r.check("drops:orphaned-base-year", false, "release absent from the restore")
            }

            if let inverted = byID[invertedID] {
                r.check("drops:inverted-base-year",
                        inverted.baseReleaseYear.isEmpty && inverted.releaseDate == "2010",
                        "releaseDate \(String(reflecting: inverted.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: inverted.baseReleaseYear))")
            } else {
                r.check("drops:inverted-base-year", false, "release absent from the restore")
            }

            if let ordered = byID[wellOrderedID] {
                r.check("keeps:well-ordered-base-year",
                        ordered.baseReleaseYear == "2009" && ordered.releaseDate == "2010",
                        "releaseDate \(String(reflecting: ordered.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: ordered.baseReleaseYear))")
            } else {
                r.check("keeps:well-ordered-base-year", false, "release absent from the restore")
            }

            if let fullOrdered = byID[fullDateOrderedID] {
                r.check("keeps:base-year-before-full-date",
                        fullOrdered.baseReleaseYear == "2009" && fullOrdered.releaseDate == "2010.05.04",
                        "releaseDate \(String(reflecting: fullOrdered.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: fullOrdered.baseReleaseYear))")
            } else {
                r.check("keeps:base-year-before-full-date", false, "release absent from the restore")
            }

            if let fullInverted = byID[fullDateInvertedID] {
                r.check("drops:base-year-at-full-date-year",
                        fullInverted.baseReleaseYear.isEmpty && fullInverted.releaseDate == "2010.05.04",
                        "releaseDate \(String(reflecting: fullInverted.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: fullInverted.baseReleaseYear))")
            } else {
                r.check("drops:base-year-at-full-date-year", false, "release absent from the restore")
            }

            if let belowFloor = byID[belowFloorID] {
                r.check("drops:full-date-below-format-floor",
                        belowFloor.releaseDate.isEmpty && belowFloor.baseReleaseYear.isEmpty,
                        "releaseDate \(String(reflecting: belowFloor.releaseDate)), "
                            + "baseReleaseYear \(String(reflecting: belowFloor.baseReleaseYear))")
            } else {
                r.check("drops:full-date-below-format-floor", false, "release absent from the restore")
            }
        } catch {
            r.check("base-year-guard-backup-restores", false, "\(error)")
        }

        return r
    }
}

/// Mutable counter for the deleteFilms(onPersisted:) contract checks in rollbackScenario.
/// A reference type because the callback is concurrently-executing code and cannot capture
/// a local `var`; @MainActor because that is the isolation the callback is delivered on.
@MainActor
private final class OnPersistedProbe {
    var fired: Int = 0
}

// MARK: - film-field-merge
//
// FilmSheet saves as a three-way merge with the film as it stands at save time, and
// DataManager writes only the merged delta (FilmField / FilmChangeset.changedFields).
//
//   • table/*      — FilmField covers every stored FilmSnapshot property exactly once, and
//                    each case's key paths touch its own property and nothing else, on
//                    both the snapshot and the Film model.
//   • rule/*       — the merge rule, exhaustively per field over every combination of
//                    sheet / loaded / stored / current drawn from three distinct values.
//   • identity/*   — with nothing changed while the sheet was open, the merge returns the
//                    sheet exactly: the whole-object save it replaced, bit for bit.
//   • e2e/*        — the real FilmSheet against the store: background changes survive a
//                    save that did not edit them, conflicts go to the user, derived
//                    fields follow the merged calendar, and the store is written as a delta.
//   • perf         — merge and delta-apply cost against the full apply it replaces.
extension DebugHarness {

    static func filmFieldMergeScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "film-field-merge")
        let store = coordinator.memoryStoreForTesting
        DebugPersistenceFault.reset()

        // --- Variants: three snapshots of one film where every field differs -------------
        // (Bool fields have only two values, so variant 2 repeats variant 0 there; the
        // rule table below detects that per field and enumerates two values instead.)
        let base = makeSnapshot(name: "Merge Base")
        func variant(_ k: Int) -> FilmSnapshot {
            let t = "v\(k)"
            var s = base
            s.posterUID = "poster-\(t)"; s.name = "Name \(t)"; s.releaseYear = "\(2000 + k)"
            s.userRating = k + 1; s.lastWatched = "2020.0\(k + 1).01"
            s.rotationThresholdOverride = k == 0 ? nil : k * 3
            s.duration = "\(5_400_000 + k)"; s.viewCount = 10 + k; s.calendarTable = ["2020.0\(k + 1).01"]
            s.autoAddToQueueOnRotation = k == 0 ? nil : k
            s.digitalSource = "src-\(t)"; s.digitalVersion = "ver-\(t)"; s.subtitles = "sub-\(t)"
            s.notes = "notes-\(t)"; s.numberOfDiscs = "\(k + 1)"; s.aspectRatio = "ar-\(t)"
            s.color = k % 2 == 1; s.edited = k % 2 == 1; s.editedDuration = "\(7_000_000 + k)"
            s.frameRate = 23.98 + Double(k); s.tags = ["tag-\(t)"]; s.externalIdentifiers = ["ext-\(t)"]
            s.dateAdded = "2019.0\(k + 1).01"; s.lastModified = "2021.0\(k + 1).01"
            s.watched = k % 2 == 1; s.specialSorting = ["ss-\(t)"]; s.alternateTitle = ["alt-\(t)"]
            s.hofPosition = k; s.infoComplete = k % 2 == 1; s.comments = "com-\(t)"
            s.genre = "gen-\(t)"; s.releaseDate = "2000-0\(k + 1)-01T12:00:00Z"
            s.descriptionText = "desc-\(t)"; s.rating = "rat-\(t)"; s.studio = ["stu-\(t)"]
            s.cast = ["cast-\(t)"]; s.directors = ["dir-\(t)"]; s.producers = ["pro-\(t)"]
            s.executiveProducers = ["ep-\(t)"]; s.screenwriters = ["sw-\(t)"]
            s.encodingTool = ["enc-\(t)"]; s.libraryHBRFValue = 20 + k; s.composer = ["comp-\(t)"]
            s.sortName = "sort-\(t)"; s.releaseUsed = "ru-\(t)"; s.tools = ["tool-\(t)"]
            s.editedHBRFValue = 30 + k; s.editDate = "2022.0\(k + 1).01"; s.warning = ["warn-\(t)"]
            s.descriptionNotes = "dn-\(t)"; s.notesOnAudioTiming = ["nat-\(t)"]
            s.specialAudioNotes = ["san-\(t)"]; s.notesArray = ["na-\(t)"]
            s.handbrakeFrames = ["hf-\(t)"]; s.correspondingTimecodes = ["tc-\(t)"]
            return s
        }
        let v = [variant(0), variant(1), variant(2)]
        let fields = FilmField.allCases

        // --- table/coverage --------------------------------------------------------------
        let stored = Set(Mirror(reflecting: base).children.compactMap(\.label))
            .subtracting(["id", "releases"])
        let named = Set(fields.map(\.rawValue))
        r.check("table/covers-every-snapshot-field", stored == named && named.count == fields.count,
                "missing \(stored.subtracting(named).sorted()), extra \(named.subtracting(stored).sorted())")
        r.check("table/variants-differ-everywhere",
                fields.allSatisfy { $0.differs(v[0], v[1]) },
                "same in v0/v1: \(fields.filter { !$0.differs(v[0], v[1]) }.map(\.rawValue))")

        // --- table/isolation: each case moves its own property and no other --------------
        var leaks: [String] = []
        for f in fields {
            let moved = f.copy(from: v[1], into: v[0])
            let touched = fields.filter { $0.differs(moved, v[0]) }
            if touched != [f] { leaks.append("\(f.rawValue)→\(touched.map(\.rawValue))") }
        }
        r.check("table/snapshot-keypaths-isolated", leaks.isEmpty, leaks.joined(separator: "; "))

        // --- table/film-apply: per-field apply matches FilmSnapshot.apply(to:) ------------
        do {
            let whole = Film(); v[1].apply(to: whole)
            let piecewise = Film()
            for f in fields { f.apply(v[1], to: piecewise) }
            let a = FilmSnapshot(from: whole), b = FilmSnapshot(from: piecewise)
            r.check("table/film-apply-all-equals-whole-apply",
                    fields.allSatisfy { !$0.differs(a, b) },
                    "differ: \(fields.filter { $0.differs(a, b) }.map(\.rawValue))")
            var filmLeaks: [String] = []
            for f in fields {
                let film = Film(); v[0].apply(to: film)
                f.apply(v[1], to: film)
                let got = FilmSnapshot(from: film)
                let touched = fields.filter { $0.differs(got, v[0]) }
                if touched != [f] { filmLeaks.append("\(f.rawValue)→\(touched.map(\.rawValue))") }
            }
            r.check("table/film-keypaths-isolated", filmLeaks.isEmpty, filmLeaks.joined(separator: "; "))
        }

        // --- rule/*: exhaustive per-field truth table -------------------------------------
        // Every (sheet, loaded, stored, current) over the field's distinct values, with the
        // other 55 fields held at independent values so cross-talk would show. Expected
        // outcome from indices alone: edited → sheet; untouched elsewhere → sheet; else current.
        var ruleCases = 0
        var ruleFailures: [String] = []
        for f in fields {
            let n = f.differs(v[0], v[2]) ? 3 : 2
            for si in 0..<n { for li in 0..<n { for sti in 0..<n { for ci in 0..<n {
                // Every other field: unedited on the sheet (sheet = loaded = 0) and changed
                // in the background (stored 2 → current 1), so each must keep current's 1.
                // (For a Bool, 2 is 0, which still differs from 1.)
                let sheet   = f.copy(from: v[si],  into: v[0])
                let loaded  = f.copy(from: v[li],  into: v[0])
                let stored  = f.copy(from: v[sti], into: v[2])
                let current = f.copy(from: v[ci],  into: v[1])
                let result = FilmField.merge(sheet: sheet, loaded: loaded, stored: stored, current: current)
                let expected = (si != li || sti == ci) ? si : ci
                // A coupled partner of an edited field follows it to the sheet (value 0);
                // every other field keeps current's 1.
                let partners = FilmField.coupled.first { $0.contains(f) }?.subtracting([f]) ?? []
                let pulled = si != li ? partners : []
                ruleCases += 1
                let valueOK = !f.differs(result.merged, v[expected])
                let expectedDelta = (expected != ci ? Set([f]) : [])
                    .union(pulled.filter { $0.differs(v[0], v[1]) })
                let deltaOK = result.changed == expectedDelta
                let othersOK = fields.allSatisfy { g in
                    g == f || !g.differs(result.merged, v[pulled.contains(g) ? 0 : 1])
                }
                if !(valueOK && deltaOK && othersOK), ruleFailures.count < 10 {
                    ruleFailures.append("\(f.rawValue) s\(si) l\(li) st\(sti) c\(ci): value \(valueOK) delta \(deltaOK) others \(othersOK)")
                }
            }}}}
        }
        r.check("rule/exhaustive-truth-table", ruleFailures.isEmpty,
                "\(ruleCases) cases; " + ruleFailures.joined(separator: "; "))

        // --- coupled/*: pairs the sheet derives together are never split ------------------
        do {
            // The user re-dates within the same year (releaseYear itself unedited) while a
            // background write changed the year: both come from the sheet.
            var loaded = v[0], sheet = v[0], stored = v[0], current = v[0]
            sheet.releaseDate = "2000-06-15T12:00:00Z"
            current.releaseYear = "1999"
            _ = stored
            let r1 = FilmField.merge(sheet: sheet, loaded: loaded, stored: stored, current: current)
            r.check("coupled/release-pair-follows-user-edit",
                    r1.merged.releaseDate == sheet.releaseDate && r1.merged.releaseYear == sheet.releaseYear
                        && r1.changed == [.releaseDate, .releaseYear],
                    "\(r1.merged.releaseDate) / \(r1.merged.releaseYear), wrote \(r1.changed.map(\.rawValue).sorted())")
            // Neither edited, background changed the date: both keep current's.
            current = v[0]; current.releaseDate = "2000-09-09T12:00:00Z"; current.releaseYear = "2000"
            sheet = v[0]; loaded = v[0]
            let r2 = FilmField.merge(sheet: sheet, loaded: loaded, stored: stored, current: current)
            r.check("coupled/unedited-pair-keeps-background",
                    r2.merged.releaseDate == current.releaseDate && r2.changed.isEmpty,
                    "\(r2.merged.releaseDate), wrote \(r2.changed.map(\.rawValue))")
            // The user edits the edited runtime while the background flips `edited`:
            // the flag comes with it, so the runtime is never saved under edited == false.
            sheet = v[1]; loaded = v[1]; current = v[1]
            sheet.editedDuration = "7777777"
            current.edited = false
            let r3 = FilmField.merge(sheet: sheet, loaded: loaded, stored: v[1], current: current)
            r.check("coupled/edited-flag-follows-runtime",
                    r3.merged.edited && r3.merged.editedDuration == "7777777",
                    "edited \(r3.merged.edited) runtime \(r3.merged.editedDuration)")
            // Frames rows: editing one column takes the other with it.
            sheet = v[0]; loaded = v[0]; current = v[0]
            sheet.handbrakeFrames = ["1", "2"]; sheet.correspondingTimecodes = ["a", "b"]
            loaded.handbrakeFrames = ["1"]; loaded.correspondingTimecodes = ["a", "b"]
            current.correspondingTimecodes = ["z"]
            let r4 = FilmField.merge(sheet: sheet, loaded: loaded, stored: loaded, current: current)
            r.check("coupled/frames-rows-stay-paired",
                    r4.merged.handbrakeFrames == ["1", "2"] && r4.merged.correspondingTimecodes == ["a", "b"],
                    "\(r4.merged.handbrakeFrames) / \(r4.merged.correspondingTimecodes)")
            r.check("coupled/groups-are-disjoint",
                    FilmField.coupled.reduce(0) { $0 + $1.count } == Set(FilmField.coupled.flatMap { $0 }).count, "")
        }

        // --- identity/*: nothing changed underneath → the merge IS the old whole save ------
        do {
            var rng = SeededGenerator(seed: 0x5EED_F11E)
            var mismatches = 0, iterations = 0
            for _ in 0..<500 {
                // Random per-field mix of the three variants for each role, with
                // current == stored (no background change).
                func mix() -> FilmSnapshot {
                    fields.reduce(v[0]) { $1.copy(from: v[Int.random(in: 0..<3, using: &rng)], into: $0) }
                }
                let sheet = mix(), loaded = mix(), stored = mix()
                let result = FilmField.merge(sheet: sheet, loaded: loaded, stored: stored, current: stored)
                iterations += 1
                let expectedDelta = Set(fields.filter { $0.differs(sheet, stored) })
                if fields.contains(where: { $0.differs(result.merged, sheet) }) || result.changed != expectedDelta {
                    mismatches += 1
                }
            }
            r.check("identity/no-background-change-equals-whole-save", mismatches == 0,
                    "\(mismatches) of \(iterations) random saves differ from the sheet")
            let sameAll = FilmField.merge(sheet: v[1], loaded: v[1], stored: v[1], current: v[1])
            r.check("identity/unchanged-save-writes-nothing", sameAll.changed.isEmpty,
                    "\(sameAll.changed.map(\.rawValue))")
        }

        // --- perf ------------------------------------------------------------------------
        do {
            let reps = 2_000
            let clock = ContinuousClock()
            var sink = 0
            let mergeTime = clock.measure {
                for i in 0..<reps {
                    let res = FilmField.merge(sheet: v[i % 3], loaded: v[0], stored: v[1], current: v[2])
                    sink &+= res.changed.count
                }
            }
            let film = Film()
            let fullTime = clock.measure { for i in 0..<reps { v[i % 3].apply(to: film) } }
            let delta: [FilmField] = [.name, .userRating, .comments, .lastWatched, .viewCount, .lastModified]
            let deltaTime = clock.measure {
                for i in 0..<reps { for f in delta { f.apply(v[i % 3], to: film) } }
            }
            func us(_ d: Duration) -> Double {
                Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
            }
            let mergeUS = us(mergeTime) / Double(reps)
            let fullUS = us(fullTime) / Double(reps), deltaUS = us(deltaTime) / Double(reps)
            r.metric("perf/merge-per-save", mergeUS, "µs")
            r.metric("perf/full-apply-per-save", fullUS, "µs")
            r.metric("perf/delta-apply-6-fields", deltaUS, "µs")
            r.check("perf/merge-under-1ms", mergeUS < 1_000, "\(mergeUS) µs (sink \(sink))")
            r.check("perf/delta-apply-cheaper-than-full", deltaUS < fullUS,
                    "delta \(deltaUS) µs vs full \(fullUS) µs")
        }

        // --- e2e: the real FilmSheet against the store ------------------------------------
        func persistedFilm(_ id: UUID) -> FilmSnapshot? {
            let context = ModelContext(coordinator.modelContainer)
            return (try? context.fetch(FetchDescriptor<Film>(predicate: #Predicate { $0.id == id })).first)
                .map { FilmSnapshot(from: $0) }
        }
        func save(_ sheet: FilmSheet) async -> Bool {
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            sheet.confirm()
            for _ in 0..<250 where !dismissed && !sheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = await drainOperations(coordinator)
            return dismissed
        }
        /// Both copies — memory and store — must satisfy `ok`.
        func both(_ name: String, _ id: UUID, _ ok: (FilmSnapshot) -> Bool,
                  _ show: (FilmSnapshot) -> String) {
            let mem = store.getFilm(id), db = persistedFilm(id)
            r.check("\(name)-memory", mem.map(ok) ?? false, mem.map(show) ?? "missing")
            r.check("\(name)-persisted", db.map(ok) ?? false, db.map(show) ?? "missing")
        }

        func fixture(_ name: String, _ tweak: (inout FilmSnapshot) -> Void = { _ in }) -> FilmSnapshot {
            var s = makeSnapshot(name: name, calendarTable: ["2020.01.10"])
            s.lastWatched = "2020.01.10"; s.viewCount = 1; s.userRating = 3
            s.comments = "original"
            tweak(&s)
            return s
        }
        let fBackground = fixture("Merge Background")
        let fConflict   = fixture("Merge Conflict")
        let fCalendar   = fixture("Merge Calendar")
        let fCalBoth    = fixture("Merge Calendar Both")
        let fRevert     = fixture("Merge Revert")
        let fHoF        = fixture("Merge HoF")
        let fRepair     = fixture("Merge Repair") { $0.frameRate = 23.976 }
        // numberOfDiscs agrees with the sheet's derived "0", so saving it is not a repair.
        let fDelta      = fixture("Merge Delta") { $0.numberOfDiscs = "0" }
        let fCross      = fixture("Merge Cross Tab")
        coordinator.importFilms([fBackground, fConflict, fCalendar, fCalBoth,
                                 fRevert, fHoF, fRepair, fDelta, fCross])
        _ = await drainOperations(coordinator)

        // 1. A background rating change survives a save that edited only the name.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fBackground.id)
            var bg = store.getFilm(fBackground.id)!; bg.userRating = 5
            await coordinator.updateFilm(bg)
            _ = await drainOperations(coordinator)
            sheet.detailsTab.name = "Merge Background Renamed"
            // Negative control: the sheet itself still holds the stale rating, so the old
            // whole-object save would have written 3 over the import's 5.
            r.check("e2e/background/sheet-holds-stale-value",
                    sheet.detailsTab.collectFilmFields().userRating == 3,
                    "sheet rating \(sheet.detailsTab.collectFilmFields().userRating)")
            r.check("e2e/background/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/background/rating-survives", fBackground.id, { $0.userRating == 5 }, { "rating \($0.userRating)" })
            both("e2e/background/edit-written", fBackground.id,
                 { $0.name == "Merge Background Renamed" }, { $0.name })
        }

        // 2. Both changed the same field: the user's edit wins.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fConflict.id)
            var bg = store.getFilm(fConflict.id)!; bg.userRating = 5
            await coordinator.updateFilm(bg)
            _ = await drainOperations(coordinator)
            sheet.detailsTab.userRating = 1
            r.check("e2e/conflict/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/conflict/user-wins", fConflict.id, { $0.userRating == 1 }, { "rating \($0.userRating)" })
        }

        // 3. A background viewing added while the sheet edits the name: the calendar and
        //    both derived fields keep the background's values.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fCalendar.id)
            coordinator.updateViewingDates(filmID: fCalendar.id,
                                           calendarTable: ["2020.01.10", "2020.02.20"],
                                           lastWatched: "2020.02.20", watched: true)
            _ = await drainOperations(coordinator)
            sheet.detailsTab.name = "Merge Calendar Renamed"
            r.check("e2e/calendar/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/calendar/background-viewing-survives", fCalendar.id,
                 { $0.calendarTable == ["2020.01.10", "2020.02.20"] && $0.lastWatched == "2020.02.20"
                     && $0.viewCount == 2 && $0.name == "Merge Calendar Renamed" },
                 { "\($0.calendarTable) last \($0.lastWatched) count \($0.viewCount) name \($0.name)" })
        }

        // 4. Both changed the calendar: the user's calendar wins and lastWatched/viewCount
        //    are derived from it, never mixed with the background's.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fCalBoth.id)
            coordinator.updateViewingDates(filmID: fCalBoth.id,
                                           calendarTable: ["2020.01.10", "2020.09.09"],
                                           lastWatched: "2020.09.09", watched: true)
            _ = await drainOperations(coordinator)
            sheet.detailsTab.calendarTable = ["2020.01.10", "2020.03.03", "2020.04.04"]
            r.check("e2e/calendar-both/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/calendar-both/derived-from-user-calendar", fCalBoth.id,
                 { $0.calendarTable == ["2020.01.10", "2020.03.03", "2020.04.04"]
                     && $0.lastWatched == "2020.04.04" && $0.viewCount == 3 },
                 { "\($0.calendarTable) last \($0.lastWatched) count \($0.viewCount)" })
        }

        // 5. An edit reverted before saving counts as no edit: the background value stays.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fRevert.id)
            var bg = store.getFilm(fRevert.id)!; bg.genre = "Background Genre"
            await coordinator.updateFilm(bg)
            _ = await drainOperations(coordinator)
            let loadedGenre = sheet.detailsTab.genre
            sheet.detailsTab.genre = "Temporary"
            sheet.detailsTab.genre = loadedGenre
            sheet.detailsTab.name = "Merge Revert Renamed"
            r.check("e2e/revert/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/revert/background-survives", fRevert.id,
                 { $0.genre == "Background Genre" }, { "genre \($0.genre)" })
        }

        // 6. A Hall of Fame entry made while the sheet is open keeps its position.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fHoF.id)
            coordinator.addToHallOfFame(fHoF.id)
            _ = await drainOperations(coordinator)
            let position = store.getFilm(fHoF.id)?.hofPosition ?? 0
            r.check("e2e/hof/background-entered", position > 0, "position \(position)")
            sheet.metadataTab.comments = "hof edit"
            r.check("e2e/hof/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/hof/position-kept", fHoF.id, { $0.hofPosition == position && $0.comments == "hof edit" },
                 { "position \($0.hofPosition) comments \($0.comments)" })
        }

        // 6b. The user switches Hall of Fame off on the sheet: it is removed.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fHoF.id)
            sheet.detailsTab.inHallOfFame = false
            r.check("e2e/hof-off/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/hof-off/removed", fHoF.id, { $0.hofPosition == 0 }, { "position \($0.hofPosition)" })
        }

        // 6c. Switched on by the user AND entered in the background meanwhile: entered
        //     once, not twice (the position must not move past the background's).
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fHoF.id)
            coordinator.addToHallOfFame(fHoF.id)
            _ = await drainOperations(coordinator)
            let position = store.getFilm(fHoF.id)?.hofPosition ?? 0
            let count = store.getAllFilms().filter { $0.hofPosition > 0 }.count
            sheet.detailsTab.inHallOfFame = true
            r.check("e2e/hof-both/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/hof-both/position-kept", fHoF.id, { $0.hofPosition == position },
                 { "position \($0.hofPosition), expected \(position)" })
            let after = store.getAllFilms().filter { $0.hofPosition > 0 }.count
            r.check("e2e/hof-both/entered-once", after == count, "\(count) → \(after)")
        }

        // 7. A value the tabs normalize on load is still written when nothing else
        //    changed it — the repair the whole-object save made, kept.
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fRepair.id)
            sheet.detailsTab.name = "Merge Repair Renamed"
            r.check("e2e/repair/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/repair/normalized-value-written", fRepair.id,
                 { $0.frameRate == 23.98 }, { "frameRate \($0.frameRate)" })
        }

        // 8. The store is written as a delta: a value present only in the store (behind
        //    MemoryStore's back) survives a save that did not change that field, while
        //    the edited field and lastModified are written.
        do {
            let context = ModelContext(coordinator.modelContainer)
            let id = fDelta.id
            if let film = try? context.fetch(FetchDescriptor<Film>(predicate: #Predicate { $0.id == id })).first {
                film.comments = "store-only"
                film.numberOfDiscs = "42"
                try? context.save()
            }
            let sheet = FilmSheet(coordinator: coordinator, filmID: fDelta.id)
            sheet.detailsTab.name = "Merge Delta Renamed"
            r.check("e2e/delta/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            let db = persistedFilm(fDelta.id)
            r.check("e2e/delta/unedited-field-not-rewritten", db?.comments == "store-only",
                    "comments \(db?.comments ?? "nil")")
            r.check("e2e/delta/unchanged-derived-not-rewritten", db?.numberOfDiscs == "42",
                    "numberOfDiscs \(db?.numberOfDiscs ?? "nil")")
            r.check("e2e/delta/edited-field-written", db?.name == "Merge Delta Renamed", db?.name ?? "nil")
            r.check("e2e/delta/last-modified-stamped", db.map { $0.lastModified != fDelta.lastModified } ?? false,
                    db?.lastModified ?? "nil")
        }

        // 9. Edits on three tabs with no background change: the saved film equals
        //    what the whole-object save would have written, field for field.
        do {
            // `expected` is the sheet's own whole-object assembly, taken just before the
            // save — exactly what the save wrote before it merged, load repairs included.
            let sheet = FilmSheet(coordinator: coordinator, filmID: fCross.id)
            sheet.detailsTab.name = "Merge Cross Renamed"
            sheet.metadataTab.studio = ["Cross Studio"]
            sheet.metadataTab.comments = "cross comments"
            sheet.detailsTab.userRating = 4
            let expected = sheet.assembledSnapshotForTesting()
            r.check("e2e/cross/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            let mem = store.getFilm(fCross.id), db = persistedFilm(fCross.id)
            let ignore: Set<FilmField> = [.lastModified]
            for (label, got) in [("memory", mem), ("persisted", db)] {
                let diff = got.map { g in fields.filter { !ignore.contains($0) && $0.differs(g, expected) } }
                r.check("e2e/cross/matches-whole-save-\(label)", diff?.isEmpty ?? false,
                        "differ: \(diff?.map(\.rawValue) ?? ["missing"])")
            }
            r.check("e2e/cross/memory-equals-store",
                    mem.flatMap { m in db.map { d in fields.allSatisfy { !$0.differs(m, d) } } } ?? false,
                    "differ: \(mem.flatMap { m in db.map { d in fields.filter { $0.differs(m, d) }.map(\.rawValue) } } ?? [])")
        }

        // 10. Add mode still writes the whole film.
        do {
            let sheet = FilmSheet(coordinator: coordinator)
            sheet.detailsTab.name = "Merge Added Film"
            sheet.detailsTab.hasReleaseDate = true
            sheet.metadataTab.comments = "added comments"
            r.check("e2e/add/saved", await save(sheet), sheet.saveErrorDetail ?? "")
            both("e2e/add/whole-film-written", sheet.filmID,
                 { $0.name == "Merge Added Film" && $0.comments == "added comments" && !$0.releaseYear.isEmpty },
                 { "\($0.name) / \($0.comments) / \($0.releaseYear)" })
        }

        return r
    }
}


// MARK: - release-date-rules
//
// The rules the release card, the sidebar and release-day notifications build on the full
// release date:
//
//   • upcoming/*    — ReleaseDateValue.isUpcoming: a full date after today, or a year-only
//                     value in a later year; today itself is not upcoming.
//   • latest/*      — the picker's ceiling is one year ahead, less a day.
//   • text/*        — "Month Day, Year" for the sidebar row and tooltip.
//   • card/*        — the card model's release-date range, its picker bridges, and the
//                     ordering rule under a release year past the current year.
//   • notify/*      — ReleaseNotifications.plan: what is scheduled, for whom, and when.
extension DebugHarness {
    @MainActor
    static func releaseDateRulesScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "release-date-rules")
        let cal = StorageDateFormatters.calendar
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d))!
        }
        func value(_ s: String, _ format: ReleaseFormat = .bluRay) -> ReleaseDateValue? {
            ReleaseDateValue(s, format: format.rawValue)
        }
        func key(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return "\(c.year!).\(c.month!).\(c.day!)"
        }

        // upcoming/*
        let today = day(2026, 10, 17)
        r.check("upcoming/tomorrow", value("2026.10.18")?.isUpcoming(today: today) == true)
        r.check("upcoming/today-is-not", value("2026.10.17")?.isUpcoming(today: today) == false)
        r.check("upcoming/yesterday-is-not", value("2026.10.16")?.isUpcoming(today: today) == false)
        r.check("upcoming/next-year-start", value("2027.01.01")?.isUpcoming(today: day(2026, 12, 31)) == true)
        r.check("upcoming/year-only-later-year", value("2027")?.isUpcoming(today: today) == true)
        r.check("upcoming/year-only-this-year-is-not", value("2026")?.isUpcoming(today: today) == false)
        // Any moment of the day reads as that day.
        r.check("upcoming/late-in-the-day", value("2026.10.18")?.isUpcoming(
            today: today.addingTimeInterval(23 * 3600 + 59 * 60)) == true)

        // latest/*
        r.check("latest/spec-example", key(ReleaseDateValue.latestSelectableDay(today: today)) == "2027.10.16",
                key(ReleaseDateValue.latestSelectableDay(today: today)))
        r.check("latest/new-years-eve", key(ReleaseDateValue.latestSelectableDay(today: day(2026, 12, 31))) == "2027.12.30")
        r.check("latest/jan-1", key(ReleaseDateValue.latestSelectableDay(today: day(2027, 1, 1))) == "2027.12.31")
        r.check("latest/leap-day", key(ReleaseDateValue.latestSelectableDay(today: day(2028, 2, 29))) == "2029.2.27",
                key(ReleaseDateValue.latestSelectableDay(today: day(2028, 2, 29))))
        r.check("latest/not-upcoming-past-it", value("2027.10.17").map {
            $0.sortKey > (value("2027.10.16")?.sortKey ?? 0) } == true)

        // text/*
        r.check("text/full", value("2026.10.17")?.displayText == "October 17, 2026")
        r.check("text/single-digit-day", value("2026.03.05")?.displayText == "March 5, 2026")
        r.check("text/year-only", value("2014")?.displayText == "2014")
        r.check("text/day", value("2026.10.17")?.day == day(2026, 10, 17))
        r.check("text/year-only-has-no-day", value("2014")?.day == nil)

        // card/*
        let realToday = CurrentDay.shared.today
        let currentYear = cal.component(.year, from: realToday)
        let latestYear = cal.component(.year, from: ReleaseDateValue.latestSelectableDay(today: realToday))
        let m = ReleaseCardModel(format: ReleaseFormat.uhd4K.rawValue)
        r.check("card/range", m.releaseDateYearRange(today: realToday) == 2016...latestYear,
                "\(m.releaseDateYearRange(today: realToday))")
        r.check("card/floor", key(m.releaseDateFloor) == "2016.1.1")
        r.check("card/base-range-unchanged", m.purchaseYearRange == 2016...currentYear)

        m.hasReleaseYear = true
        m.releaseYear = 2014
        m.releaseMonthDay = nil
        let shown = cal.dateComponents([.year, .month, .day], from: m.releaseDatePickerValue)
        let now = cal.dateComponents([.month, .day], from: Date())
        r.check("card/year-only-shows-today-in-its-year",
                shown.year == 2014 && shown.month == now.month
                    && shown.day == min(now.day!, gregorianDaysInMonth(now.month!, year: 2014)))
        m.endYearOnlyReleaseDate()
        r.check("card/end-year-only-fills-today", m.releaseMonthDay?.month == now.month && m.releaseYear == 2014)
        m.setReleaseDate(day(2027, 1, 5))
        r.check("card/set", m.releaseYear == 2027 && m.releaseMonthDay == ReleaseMonthDay(month: 1, day: 5))
        r.check("card/saves-full-date", m.releaseDateStorageString == "2027.01.05", m.releaseDateStorageString)
        m.releaseYear = 2027
        m.releaseMonthDay = ReleaseMonthDay(month: 2, day: 29)
        r.check("card/feb-29-clamped-in-picker", key(m.releaseDatePickerValue) == "2027.2.28")
        m.hasReleaseYear = false
        r.check("card/clearing-drops-month-day", m.releaseMonthDay == nil)

        // The ordering rule under a release year past the current year: the base year is
        // pulled beneath it but never past the current year.
        let o = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue)
        o.hasReleaseYear = true
        o.releaseYear = currentYear + 1
        o.hasBaseReleaseYear = true
        o.baseReleaseYear = currentYear + 1
        o.enforceReleaseYearOrder()
        r.check("card/order-future-release", o.hasBaseReleaseYear && o.baseReleaseYear == currentYear,
                "\(o.hasBaseReleaseYear) \(o.baseReleaseYear)")
        // A range collapsed to the current year (a film released this year) still leaves the
        // current year as a legal base year beneath an upcoming release.
        let c = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue, filmReleaseYear: currentYear)
        c.hasReleaseYear = true
        c.releaseYear = currentYear + 1
        c.hasBaseReleaseYear = true
        c.baseReleaseYear = currentYear
        c.enforceReleaseYearOrder()
        r.check("card/order-collapsed-range-future-release", c.hasBaseReleaseYear && c.baseReleaseYear == currentYear)
        c.releaseYear = currentYear
        c.enforceReleaseYearOrder()
        r.check("card/order-collapsed-range-current-release", !c.hasBaseReleaseYear)
        // The previous behavior, unchanged: a release year inside the range.
        let p = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue)
        p.hasReleaseYear = true
        p.releaseYear = 2010
        p.hasBaseReleaseYear = true
        p.baseReleaseYear = 2012
        p.enforceReleaseYearOrder()
        r.check("card/order-in-range", p.hasBaseReleaseYear && p.baseReleaseYear == 2009)
        p.releaseYear = 2006
        p.enforceReleaseYearOrder()
        r.check("card/order-on-floor-clears", !p.hasBaseReleaseYear)

        let u = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue)
        u.hasReleaseYear = true
        u.setReleaseDate(cal.date(byAdding: .day, value: 1, to: realToday)!)
        r.check("card/upcoming", u.isUpcomingRelease(today: realToday))
        u.setReleaseDate(realToday)
        r.check("card/today-not-upcoming", !u.isUpcomingRelease(today: realToday))
        u.setReleaseDate(cal.date(byAdding: .day, value: 1, to: realToday)!)
        u.hasReleaseYear = false
        r.check("card/no-date-not-upcoming", !u.isUpcomingRelease(today: realToday))

        // notify/*
        let prefix = ReleaseNotifications.identifierPrefix
        let parent = UUID()
        let rTomorrow = ReleaseSnapshot(studio: "Criterion", releaseDate: "2026.10.18", format: "4K UHD")
        let rWished = ReleaseSnapshot(releaseDate: "2026.10.20", wishlist: 3, format: "Blu-ray")
        let rChild = ReleaseSnapshot(releaseDate: "2026.10.18", format: "Blu-ray", parentReleaseID: parent)
        let rTodayNew = ReleaseSnapshot(releaseDate: "2026.10.17", format: "Blu-ray")
        let rTodayPending = ReleaseSnapshot(releaseDate: "2026.10.17", format: "DVD")
        let rYearOnly = ReleaseSnapshot(releaseDate: "2027", format: "Blu-ray")
        let rPast = ReleaseSnapshot(releaseDate: "2026.10.16", format: "Blu-ray")
        let rNextYear = ReleaseSnapshot(releaseDate: "2027.01.01", format: "Blu-ray")
        let film = makeSnapshot(name: "Notify Film", releases: [
            rTomorrow, rWished, rChild, rTodayNew, rTodayPending, rYearOnly, rPast, rNextYear])
        func id(_ release: ReleaseSnapshot) -> String { prefix + release.id.uuidString }
        let early = today.addingTimeInterval(3600)   // 01:00 local-ish, before delivery
        let all = ReleaseNotifications.plan(films: [film], pendingIDs: [id(rTodayPending)],
                                            today: today, now: early, wishlistedOnly: false)
        r.check("notify/upcoming-scheduled", all[id(rTomorrow)] != nil)
        r.check("notify/wishlisted-scheduled", all[id(rWished)] != nil)
        r.check("notify/child-skipped", all[id(rChild)] == nil)
        r.check("notify/cataloged-today-skipped", all[id(rTodayNew)] == nil)
        r.check("notify/pending-today-kept", all[id(rTodayPending)] != nil)
        r.check("notify/year-only-skipped", all[id(rYearOnly)] == nil)
        r.check("notify/past-skipped", all[id(rPast)] == nil)
        r.check("notify/next-year-scheduled", all[id(rNextYear)] != nil)
        r.check("notify/count", all.count == 4, "\(all.count)")
        if let planned = all[id(rTomorrow)] {
            r.check("notify/title", planned.title == "Notify Film")
            r.check("notify/body", planned.body == "The 4K UHD release from Criterion is out today.", planned.body)
            r.check("notify/trigger", planned.trigger.year == 2026 && planned.trigger.month == 10
                    && planned.trigger.day == 18 && planned.trigger.hour == ReleaseNotifications.deliveryHour)
        }
        if let planned = all[id(rWished)] {
            r.check("notify/body-wishlisted", planned.body.hasSuffix("It's on your wishlist."), planned.body)
        }
        let wished = ReleaseNotifications.plan(films: [film], pendingIDs: [id(rTodayPending)],
                                               today: today, now: early, wishlistedOnly: true)
        r.check("notify/wishlisted-only", Set(wished.keys) == [id(rWished)], "\(wished.keys)")
        // After the delivery hour on the release day, today's request is no longer wanted.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let late = local.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23))!
        let after = ReleaseNotifications.plan(films: [film], pendingIDs: [id(rTodayPending)],
                                              today: today, now: late, wishlistedOnly: false)
        r.check("notify/today-after-delivery-dropped", after[id(rTodayPending)] == nil)

        // The cap keeps the soonest.
        let many = (1...75).map { i in
            ReleaseSnapshot(releaseDate: StorageDateFormatters.dot.string(
                from: cal.date(byAdding: .day, value: i, to: today)!), format: "Blu-ray")
        }
        let capped = ReleaseNotifications.plan(films: [makeSnapshot(name: "Many", releases: many)],
                                               pendingIDs: [], today: today, now: early,
                                               wishlistedOnly: false)
        r.check("notify/capped", capped.count == ReleaseNotifications.maxScheduled, "\(capped.count)")
        r.check("notify/soonest-kept", capped[id(many[0])] != nil && capped[id(many[74])] == nil)

        // short/* — the wishlist report's form.
        r.check("short/full", value("2027.01.15")?.shortDisplayText == "Jan 15, 2027")
        r.check("short/year-only", value("2014")?.shortDisplayText == "2014")

        // avail/* — an upcoming release's availability is cleared, the combo lock kept.
        let a = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue)
        a.hasReleaseYear = true
        a.marketAvailability = [ReleaseMarketAvailability.available]
        a.setReleaseDate(cal.date(byAdding: .month, value: 2, to: realToday)!)
        r.check("avail/cleared-when-upcoming", a.marketAvailability.isEmpty, "\(a.marketAvailability)")
        a.marketAvailability = [ReleaseMarketAvailability.available]
        a.setReleaseDate(cal.date(byAdding: .day, value: -1, to: realToday)!)
        r.check("avail/kept-when-released", a.marketAvailability == [ReleaseMarketAvailability.available])
        a.independence = ReleaseIndependence.comboPack
        a.marketAvailability = [ReleaseMarketAvailability.comboPackOnly]
        a.setReleaseDate(cal.date(byAdding: .month, value: 2, to: realToday)!)
        r.check("avail/combo-lock-kept", a.marketAvailability == [ReleaseMarketAvailability.comboPackOnly])
        let y = ReleaseCardModel(format: ReleaseFormat.bluRay.rawValue)
        y.hasReleaseYear = true
        y.releaseYear = currentYear + 1
        y.marketAvailability = [ReleaseMarketAvailability.available]
        y.endYearOnlyReleaseDate()
        r.check("avail/cleared-on-year-only-activation", y.marketAvailability.isEmpty)

        // floor/* — the film's own release day floors the picker.
        let f = ReleaseCardModel(format: ReleaseFormat.uhd4K.rawValue, filmReleaseYear: 2019,
                                 filmReleaseDay: day(2019, 5, 3))
        r.check("floor/film-day", key(f.releaseDateFloor) == "2019.5.3")
        let g = ReleaseCardModel(format: ReleaseFormat.uhd4K.rawValue, filmReleaseYear: 2010,
                                 filmReleaseDay: day(2010, 5, 3))
        r.check("floor/format-floor-wins", key(g.releaseDateFloor) == "2016.1.1")
        let h = ReleaseCardModel(format: ReleaseFormat.uhd4K.rawValue)
        r.check("floor/no-film-date", key(h.releaseDateFloor) == "2016.1.1")

        // defaults/* — new-release picker values.
        let k4 = ReleaseFormat.newReleaseDefaults(for: ReleaseFormat.uhd4K.rawValue)
        r.check("defaults/4k", k4.audioFormat == ReleaseAudioFormat.dtsHDMA
                && k4.audioChannels == ReleaseAudioChannels.surround51 && k4.hasHDR == ReleaseHDR.dolbyVision)
        let bd = ReleaseFormat.newReleaseDefaults(for: ReleaseFormat.bluRay.rawValue)
        r.check("defaults/bluray", bd.audioChannels == ReleaseAudioChannels.surround51)

        // search/* — the release token's date forms.
        func matches(_ q: String, _ stored: String) -> Bool? {
            let monthYear: (String) -> Date? = { text in
                let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "MMMM yyyy"
                return fmt.date(from: text)
            }
            guard let m = SearchController.releaseDateMatcher(q, parseMonthYear: monthYear),
                  let v = value(stored) else { return nil }
            return m(v)
        }
        r.check("search/year", matches("2027", "2027.03.14") == true && matches("2027", "2027") == true
                && matches("2027", "2026.12.31") == false)
        r.check("search/range", matches("2020-2027", "2024.01.01") == true && matches("2020-2027", "2019") == false)
        r.check("search/after-year", matches(">2026", "2027.01.01") == true && matches(">2026", "2026.12.31") == false)
        r.check("search/before-day", matches("<2026.06.01", "2026.05.31") == true
                && matches("<2026.06.01", "2026.06.01") == false && matches("<2026.06.01", "2026") == false
                && matches("<2026.06.01", "2025") == true)
        r.check("search/exact-day", matches("2027.03.14", "2027.03.14") == true && matches("2027.03.14", "2027") == false)
        r.check("search/month", matches("march 2027", "2027.03.01") == true && matches("march 2027", "2027.04.01") == false)
        r.check("search/studio-not-a-date", SearchController.releaseDateMatcher("criterion", parseMonthYear: { _ in nil }) == nil
                && SearchController.releaseDateMatcher("88 films", parseMonthYear: { _ in nil }) == nil)

        // smart/* — Upcoming Releases membership.
        let upFilm = makeSnapshot(name: "Up", releases: [ReleaseSnapshot(releaseDate: "2026.10.18", format: "Blu-ray")])
        let outFilm = makeSnapshot(name: "Out", releases: [ReleaseSnapshot(releaseDate: "2026.10.17", format: "Blu-ray")])
        r.check("smart/upcoming", SmartLists.membership(of: upFilm, today: today).contains(.upcomingReleases))
        r.check("smart/released-not", !SmartLists.membership(of: outFilm, today: today).contains(.upcomingReleases))
        r.check("smart/sidebar-row", SmartListType.sidebarCases.contains(.upcomingReleases)
                && SmartListType.upcomingReleases.familyVariants == [.upcomingReleases])
        r.check("smart/cmd-9", TopLevelSidebarShortcut(smartListType: .upcomingReleases)?.rawValue == 9
                && TopLevelSidebarShortcut(smartListType: .alternateVersions) == nil)
        return r
    }
}

#endif
