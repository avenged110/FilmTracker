// MARK: - DHFilmLinkMemory.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only harness scenario for the in-memory side of film links (Staging/FilmLinks/PLAN.md,
/// "Memory layer"): MemoryStore's link storage and readers, the snapshot cache's payload and
/// fingerprint, and DataCoordinator's write path with its per-pair rollback.
///
///   mem/*       an isolated MemoryStore: relations from both ends, pair lookup, the rule
///               check (including the pair's own link left out), replace on a pair, an ID
///               moved off another pair, removal, links of deleted films hidden and revived,
///               pruning, a cycle-safe walk, change notifications, and the reverse index
///               rebuilt from scratch after every step.
///   cache/*     the payload round trip (exact dates and kinds) and the fingerprint's link
///               layer: order-independent, and moved by every change a write can make.
///   live/*      the sandbox's own coordinator, against its library: memory and the store
///               hold the very same links (ID, ends, kind, date) after every case; the live
///               and stored fingerprints agree on the link layer; writes, a refused write, an
///               identical write that dispatches nothing, a rewrite, removal; persistence
///               failures (single, a failure followed by a success on the same pair and the
///               reverse, two failures in a row); a linked film's delete rolled back, two
///               linked films' deletes both rolled back, a delete that persists (its links
///               pruned); the launch cleanup bringing memory into line with damage injected
///               into the store; the next launch's fast path (the snapshot cache, links
///               included) and slow path (a store-only link left out), in a second MemoryStore.
///
/// The live cases link four real films and six probe films the scenario imports, and remove
/// every link and probe film before returning, so the sandbox library ends as it began.

#if DEBUG

import Foundation
import CoreData

extension DebugHarness {

    static func filmLinksMemoryScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "film-links-memory")
        isolatedFilmLinkCases(&r)
        filmLinkCacheCases(&r)
        await liveFilmLinkCases(&r, coordinator: coordinator)
        return r
    }

    // MARK: - Helpers

    /// Whether `filmToLinks` is exactly what `filmLinks` implies, built from scratch.
    private static func linkIndexIsConsistent(_ store: MemoryStore) -> Bool {
        var rebuilt: [UUID: Set<UUID>] = [:]
        for link in store.filmLinksForTesting.values {
            rebuilt[link.sourceID, default: []].insert(link.id)
            rebuilt[link.targetID, default: []].insert(link.id)
        }
        return rebuilt == store.filmToLinksForTesting
    }

    private static func link(_ source: UUID, _ target: UUID, _ kind: String = FilmLinkKind.sequel,
                             id: UUID = UUID(), at seconds: Double) -> FilmLinkSnapshot {
        FilmLinkSnapshot(id: id, kind: kind, sourceID: source, targetID: target,
                         dateAdded: Date(timeIntervalSinceReferenceDate: seconds))
    }

    // MARK: - Isolated MemoryStore

    private static func isolatedFilmLinkCases(_ r: inout HarnessScenarioResult) {
        let films = (0..<8).map { makeSnapshot(name: "Link Probe", sortIndex: $0) }
        let a = films.map(\.id)
        let store = MemoryStore.isolatedForTesting(films: films, lists: [])
        var notified = 0
        store.filmLinksDidChange = { notified += 1 }
        var consistent = true
        func step() { consistent = consistent && linkIndexIsConsistent(store) }

        let l1 = link(a[1], a[0], at: 1_000)
        let l2 = link(a[2], a[1], at: 2_000)
        let l3 = link(a[3], a[0], FilmLinkKind.remake, at: 3_000)
        for l in [l1, l2, l3] { store.setFilmLinks(onPair: l.pair, to: [l]); step() }
        r.check("mem/set-notifies-each", notified == 3, "\(notified) notification(s) for 3 writes")

        let from0 = store.filmLinkRelations(forFilm: a[0])
        r.check("mem/relations-target-side",
                from0.map(\.id) == [l1.id, l3.id] && from0.allSatisfy { !$0.isSource }
                    && from0.map(\.otherFilmID) == [a[1], a[3]],
                "\(from0.map { "\($0.kind) other=\($0.otherFilmID == a[1] ? "a1" : "a3") source=\($0.isSource)" })")
        let from1 = store.filmLinkRelations(forFilm: a[1])
        r.check("mem/relations-own-sentence-first",
                from1.map(\.id) == [l1.id, l2.id] && from1.map(\.isSource) == [true, false],
                "\(from1.map(\.isSource))")
        r.check("mem/pair-lookup-either-way",
                store.filmLink(between: a[0], and: a[1]) == l1 && store.filmLink(between: a[1], and: a[0]) == l1
                    && store.filmLink(between: a[0], and: a[0]) == nil && store.filmLink(between: a[0], and: a[5]) == nil, "")
        r.check("mem/all-oldest-first", store.allFilmLinks() == [l1, l2, l3] && store.filmLinkCount == 3, "")
        r.check("mem/connected-films", store.linkedFilmIDs(connectedTo: a[0]) == [a[1], a[2], a[3]]
                    && store.linkedFilmIDs(connectedTo: a[5]).isEmpty, "")

        /// The rule check: the same answers DataManager gives against the store.
        let ghost = UUID()
        r.check("mem/problem-cycle-any-case", store.filmLinkProblem(source: a[0], target: a[2], kind: "sequel") == .cycle, "")
        r.check("mem/problem-other-kind-allowed", store.filmLinkProblem(source: a[0], target: a[2], kind: FilmLinkKind.prequel) == nil, "")
        r.check("mem/problem-self", store.filmLinkProblem(source: a[4], target: a[4], kind: "Sequel") == .selfLink, "")
        r.check("mem/problem-empty-kind", store.filmLinkProblem(source: a[4], target: a[5], kind: " \n") == .emptyKind, "")
        r.check("mem/problem-missing-film", store.filmLinkProblem(source: a[4], target: ghost, kind: "Sequel") == .filmNotFound(ghost), "")
        /// Reversing a1 → a0 would be a cycle if the pair's own link stayed in the test.
        r.check("mem/problem-pair-link-left-out", store.filmLinkProblem(source: a[0], target: a[1], kind: "Sequel") == nil, "")

        /// Replace on a pair: same ID kept by the caller, new kind and direction.
        let rewritten = link(a[0], a[1], FilmLinkKind.reboot, id: l1.id, at: 1_000)
        let replaced = store.setFilmLinks(onPair: rewritten.pair, to: [rewritten]); step()
        r.check("mem/rewrite-in-place", replaced == [l1] && store.filmLink(between: a[0], and: a[1]) == rewritten
                    && store.filmLinkCount == 3, "")
        let fresh = link(a[0], a[1], at: 4_000)
        store.setFilmLinks(onPair: fresh.pair, to: [fresh]); step()
        r.check("mem/one-link-per-pair", store.filmLinkCount == 3 && store.filmLinksForTesting[l1.id] == nil
                    && store.filmLink(between: a[1], and: a[0]) == fresh, "")

        /// An ID that sits on another pair moves: memory never holds two links with one ID.
        let moved = link(a[4], a[5], id: l3.id, at: 3_000)
        store.setFilmLinks(onPair: moved.pair, to: [moved]); step()
        r.check("mem/id-moves-off-other-pair", store.filmLink(between: a[3], and: a[0]) == nil
                    && store.filmLink(between: a[4], and: a[5]) == moved && store.filmLinkCount == 3, "")

        let beforeRemove = notified
        let cleared = store.setFilmLinks(onPair: moved.pair, to: []); step()
        let byID = store.removeFilmLinks(ids: [l2.id, ghost]); step()
        let nothing = store.setFilmLinks(onPair: FilmLinkRules.Pair(a[6], a[7]), to: []); step()
        r.check("mem/remove", cleared == [moved] && byID == [l2] && nothing.isEmpty
                    && store.allFilmLinks() == [fresh] && notified == beforeRemove + 2,
                "\(notified - beforeRemove) notification(s) for 2 removals and a no-op")

        /// Links of a deleted film: hidden while it is gone, live again when it is put back,
        /// dropped by pruning only. A film with no links notifies nothing.
        let other = MemoryStore.isolatedForTesting(films: films, lists: [],
                                                   links: [link(a[1], a[0], at: 1), link(a[2], a[1], at: 2), link(a[4], a[3], at: 3)])
        let held = other.allFilmLinks()
        var otherNotified = 0
        other.filmLinksDidChange = { otherNotified += 1 }
        other.deleteFilms(ids: [a[1]])
        r.check("mem/deleted-film-links-hidden",
                other.allFilmLinks() == [held[2]] && other.filmLinkCount == 1
                    && other.filmLinkRelations(forFilm: a[0]).isEmpty && other.filmLinkRelations(forFilm: a[1]).isEmpty
                    && other.filmLink(between: a[0], and: a[1]) == nil && other.linkedFilmIDs(connectedTo: a[0]).isEmpty
                    && other.filmLinksForTesting.count == 3 && otherNotified == 1,
                "\(other.filmLinkCount) live, \(other.filmLinksForTesting.count) held, \(otherNotified) notification(s)")
        other.deleteFilms(ids: [a[5]])
        r.check("mem/unlinked-delete-silent", otherNotified == 1, "\(otherNotified)")
        other.addFilms([films[1]], recordingTagUses: false)
        r.check("mem/put-back-revives", other.allFilmLinks() == held && otherNotified == 2, "")
        other.deleteFilms(ids: [a[1]])
        let pruned = other.pruneDanglingFilmLinks()
        r.check("mem/prune", pruned == 2 && other.filmLinksForTesting.count == 1
                    && other.filmToLinksForTesting[a[0]] == nil && other.filmToLinksForTesting[a[2]] == nil
                    && linkIndexIsConsistent(other) && otherNotified == 3,
                "\(pruned) pruned, \(other.filmLinksForTesting.count) held")
        other.addFilms([films[1]], recordingTagUses: false)
        r.check("mem/pruned-stay-gone", other.allFilmLinks() == [held[2]], "")
        /// MetadataCache is shared: take the probe film back out of it.
        other.deleteFilms(ids: [a[1]])

        /// A cycle (only ever transient, while writes are pending; see MemoryStore.filmLinks)
        /// cannot loop the walk. Written past the rules on purpose.
        let looped = MemoryStore.isolatedForTesting(films: films, lists: [],
                                                    links: [link(a[0], a[1], at: 1), link(a[1], a[2], at: 2), link(a[2], a[0], at: 3)])
        r.check("mem/walk-survives-cycle", looped.linkedFilmIDs(connectedTo: a[0]) == [a[1], a[2]], "")
        r.check("mem/index-consistent-throughout", consistent, "")

        ruleGraphCases(&r, films: films)
    }

    /// `filmLinkProblem` answers from a graph cached until memory changes: every change that
    /// moves what the rules see (a link written or removed, a film deleted or put back) must
    /// move the answer at once, and the pair's own link must still be left out.
    private static func ruleGraphCases(_ r: inout HarnessScenarioResult, films: [FilmSnapshot]) {
        let a = films.map(\.id)
        let store = MemoryStore.isolatedForTesting(films: films, lists: [],
                                                   links: [link(a[1], a[0], at: 1), link(a[2], a[1], at: 2)])
        func problem(_ s: Int, _ t: Int, _ kind: String = FilmLinkKind.sequel) -> FilmLinkError? {
            store.filmLinkProblem(source: a[s], target: a[t], kind: kind)
        }
        r.check("graph/cycle", problem(0, 2) == .cycle && problem(0, 3) == nil, "")
        let l3 = link(a[3], a[2], at: 3)
        store.setFilmLinks(onPair: l3.pair, to: [l3])
        r.check("graph/sees-new-link", problem(0, 3) == .cycle, "\(String(describing: problem(0, 3)))")
        store.setFilmLinks(onPair: l3.pair, to: [])
        r.check("graph/sees-removal", problem(0, 3) == nil, "")
        store.deleteFilms(ids: [a[1]])
        r.check("graph/sees-delete", problem(0, 2) == nil, "")
        store.addFilms([films[1]], recordingTagUses: false)
        r.check("graph/sees-put-back", problem(0, 2) == .cycle, "")
        /// The pair's own link: reversing a1 → a0 is allowed; so is any kind on it.
        r.check("graph/pair-link-left-out", problem(0, 1) == nil && problem(1, 0, FilmLinkKind.remake) == nil
                    && problem(0, 2) == .cycle, "")
        /// The same answers as the uncached rule check over the live links, film by film.
        let edges = store.allFilmLinks()
        var agree = true
        for s in a.indices { for t in a.indices where s != t {
            let pair = FilmLinkRules.Pair(a[s], a[t])
            let expected = FilmLinkRules.closesCycle(source: a[s], target: a[t], kind: FilmLinkKind.sequel,
                                                     in: edges.filter { $0.pair != pair }.map(\.edge))
            agree = agree && ((problem(s, t) == .cycle) == expected)
        } }
        r.check("graph/matches-uncached", agree, "")
        /// MetadataCache is shared: take the probe film back out of it.
        store.deleteFilms(ids: [a[1]])

        /// Pair and the tie-break order UUIDs by bytes, which must be the uuidString order.
        var sameOrder = true
        for _ in 0..<2_000 {
            let x = UUID(), y = UUID()
            sameOrder = sameOrder && FilmLinkRules.uuidPrecedes(x, y) == (x.uuidString < y.uuidString)
                && FilmLinkRules.Pair(x, y) == FilmLinkRules.Pair(y, x)
        }
        let low = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        let high = UUID(uuidString: "00000000-0000-0000-0001-000000000000")!
        r.check("graph/uuid-order-is-string-order", sameOrder && FilmLinkRules.uuidPrecedes(low, high)
                    && !FilmLinkRules.uuidPrecedes(high, low) && !FilmLinkRules.uuidPrecedes(low, low)
                    && FilmLinkRules.Pair(high, low).low == low, "")

        /// A picker's worth of checks: 1,400 targets against 300 links, in one release-
        /// independent bound (Debug is slower; this guards against the per-check rebuild).
        /// Source many[0]; many[1] → many[0] is the pair's own link (left out), and
        /// many[1002] → many[1001] → many[1] → many[0] makes 1001 and 1002 reach it: three
        /// refusals with the self-link.
        let pickerFilms = (0..<1_400).map { makeSnapshot(name: "Picker Probe", sortIndex: $0) }
        let many = pickerFilms.map(\.id)
        let kinds = FilmLinkKind.all
        var pickerLinks: [FilmLinkSnapshot] = (0..<300).map { (i: Int) -> FilmLinkSnapshot in
            link(many[i * 2 + 1], many[i * 2], kinds[i % kinds.count], at: Double(i))
        }
        pickerLinks.append(link(many[1001], many[1], at: 301))
        pickerLinks.append(link(many[1002], many[1001], at: 302))
        let picker = MemoryStore.isolatedForTesting(films: pickerFilms, lists: [], links: pickerLinks)
        let start = ContinuousClock.now
        var refused: Set<UUID> = []
        for target in many where picker.filmLinkProblem(source: many[0], target: target, kind: FilmLinkKind.sequel) != nil {
            refused.insert(target)
        }
        let elapsed = ContinuousClock.now - start
        r.check("graph/picker-1400x302", refused == [many[0], many[1001], many[1002]] && elapsed < .milliseconds(100),
                "\(refused.count) refused in \(elapsed.formattedMilliseconds)")
        r.metric("graph/picker-1400x302", Double(elapsed.components.attoseconds) / 1e15, "ms")
    }

    // MARK: - Snapshot Cache

    private static func filmLinkCacheCases(_ r: inout HarnessScenarioResult) {
        let films = (0..<4).map { makeSnapshot(name: "Cache Link Probe", sortIndex: $0) }
        let a = films.map(\.id)
        let t1 = 123_456.789_012_345
        let l1 = link(a[1], a[0], at: t1)
        let l2 = link(a[2], a[1], "Spin-off ✦", at: -0.000_1)
        let decoded = MemoryStoreCache.payloadRoundTripForTesting(films: films, lists: [], links: [l1, l2])
        r.check("cache/payload-roundtrip-exact", decoded == [l1, l2],
                "dates \(decoded?.map(\.dateAdded.timeIntervalSinceReferenceDate) ?? [])")

        let filmMap = Dictionary(uniqueKeysWithValues: films.map { ($0.id, $0) })
        func fp(_ links: [FilmLinkSnapshot]) -> StoreFingerprint {
            MemoryStoreCache.shared.fingerprintForTesting(films: filmMap, lists: [:], links: links)
        }
        let base = fp([l1, l2])
        r.check("cache/fingerprint-order-independent", base == fp([l2, l1]) && base.linkCount == 2, "")
        /// Each variant changes one thing about l1 (or the set), so each proves that one thing
        /// is in the digest.
        r.check("cache/fingerprint-variant-baseline", fp([link(a[1], a[0], id: l1.id, at: t1), l2]) == base, "")
        let variants: [(String, [FilmLinkSnapshot])] = [
            ("kind", [link(a[1], a[0], FilmLinkKind.remake, id: l1.id, at: t1), l2]),
            ("kind-case", [link(a[1], a[0], "sequel", id: l1.id, at: t1), l2]),
            ("ends-swapped", [link(a[0], a[1], id: l1.id, at: t1), l2]),
            ("other-target", [link(a[1], a[3], id: l1.id, at: t1), l2]),
            ("id", [link(a[1], a[0], at: t1), l2]),
            ("date", [link(a[1], a[0], id: l1.id, at: t1.nextUp), l2]),
            ("removed", [l2]),
            ("added", [l1, l2, link(a[3], a[2], at: 0)]),
            ("kinds-traded", [link(a[1], a[0], l2.kind, id: l1.id, at: t1), link(a[2], a[1], l1.kind, id: l2.id, at: -0.000_1)]),
            ("dates-traded", [link(a[1], a[0], id: l1.id, at: -0.000_1), link(a[2], a[1], l2.kind, id: l2.id, at: t1)]),
        ]
        for (name, links) in variants {
            r.check("cache/fingerprint-moves:\(name)", fp(links) != base, "")
        }
        r.check("cache/kind-hash-stable",
                FilmLinkLayerDigest.stableHash("") == 0xCBF2_9CE4_8422_2325
                    && FilmLinkLayerDigest.stableHash("a") == 0xAF63_DC4C_8601_EC8C,
                "FNV-1a reference values")
    }

    // MARK: - Live Coordinator

    /// Waits for every tracked operation to finish, rollbacks and `settled` included.
    private static func drainLinkOperations(_ coordinator: DataCoordinator) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while coordinator.hasPendingOperations {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await Task.yield()
        return true
    }

    private static func liveFilmLinkCases(_ r: inout HarnessScenarioResult, coordinator: DataCoordinator) async {
        guard coordinator.isInitialized else { r.check("live/initialized", false, ""); return }
        let memory = coordinator.memoryStoreForTesting
        let reader = DataManager(persistentContainer: coordinator.persistentContainer)
        _ = await drainLinkOperations(coordinator)
        DebugPersistenceFault.reset()

        /// Memory and the store hold the same links, field for field.
        func parity(_ name: String) async {
            let stored = (try? await reader.fetchFilmLinks()) ?? [FilmLinkSnapshot(id: UUID(), kind: "<fetch failed>",
                                                                                   sourceID: UUID(), targetID: UUID(), dateAdded: .distantPast)]
            let held = memory.allFilmLinks()
            r.check("live/\(name)/memory-matches-store", Set(held) == Set(stored) && held.count == stored.count,
                    "memory \(held.count), store \(stored.count)"
                        + (Set(held) == Set(stored) ? "" : "; only in memory \(Set(held).subtracting(stored).map(\.kind)), only in store \(Set(stored).subtracting(held).map(\.kind))"))
            r.check("live/\(name)/index-consistent", linkIndexIsConsistent(memory), "")
        }
        /// The link layer of the fingerprint the next launch would compare.
        func fingerprintParity(_ name: String) async {
            guard let live = await reader.computeStoreFingerprint() else {
                r.check("live/\(name)/fingerprint", false, "live fingerprint unavailable"); return
            }
            let lists = Dictionary(uniqueKeysWithValues: memory.allListsForTesting.map { ($0.listID, $0) })
            let stored = MemoryStoreCache.shared.fingerprintForTesting(films: memory.getAllFilmsMap(), lists: lists,
                                                                       links: memory.allFilmLinks())
            r.check("live/\(name)/fingerprint-link-layer",
                    live.linkCount == stored.linkCount && live.linkFingerprint == stored.linkFingerprint,
                    "live \(live.linkCount) link(s), stored \(stored.linkCount)")
        }
        func settle(_ name: String) async {
            r.check("live/\(name)/drained", await drainLinkOperations(coordinator), "")
        }

        await parity("start")
        await fingerprintParity("start")
        let startLinks = memory.allFilmLinks()

        /// Probe films, imported through the coordinator as an import would.
        let probes = (0..<6).map { makeSnapshot(name: "Film Link Memory Probe", sortIndex: $0) }
        let s = probes.map(\.id)
        coordinator.importFilms(probes)
        await settle("import")
        /// Four real films, chosen by ID so a rerun picks the same ones.
        let real = memory.getAllFilms().map(\.id).filter { !s.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        guard real.count >= 4 else { r.check("live/enough-films", false, "\(real.count) real film(s)"); return }
        let f = Array(real.prefix(4))

        func set(_ source: UUID, _ target: UUID, _ kind: String) -> FilmLinkSnapshot? {
            do { return try coordinator.setFilmLink(source: source, target: target, kind: kind) }
            catch { r.check("live/unexpected-refusal", false, "\(error)"); return nil }
        }

        // MARK: Writes
        let revisionBefore = coordinator.filmLinksRevision
        let l1 = set(f[1], f[0], FilmLinkKind.sequel)
        _ = set(f[2], f[1], "  Sequel ")
        _ = set(f[3], f[0], FilmLinkKind.remake)
        r.check("live/revision-moves", coordinator.filmLinksRevision > revisionBefore, "")
        r.check("live/kind-trimmed-in-memory", coordinator.filmLink(between: f[1], and: f[2])?.kind == "Sequel", "")
        await settle("writes")
        await parity("writes")
        await fingerprintParity("writes")

        // MARK: Relaunch
        /// The next launch, both ways, in a second MemoryStore against this store. Fast path:
        /// the snapshot cache written from memory now (links included) must match the store's
        /// fingerprint and load the links back exactly. Slow path: a rule-breaking link written
        /// into the store behind memory's back moves only the link layer, so the cache misses,
        /// and the store read leaves that link out as the launch cleanup would.
        let lists = Dictionary(uniqueKeysWithValues: memory.allListsForTesting.map { ($0.listID, $0) })
        let live = await reader.computeStoreFingerprint()
        let stored = MemoryStoreCache.shared.fingerprintForTesting(films: memory.getAllFilmsMap(), lists: lists,
                                                                   links: memory.allFilmLinks())
        if live != stored {
            /// Only a difference outside the link layer gets here (the link layer is checked
            /// above): this library copy would take the slow path whatever links did.
            r.skip("live/relaunch", "the store differs from memory outside the link layer (memberships, ranks or ratings), so no cache could hit")
        } else {
            await MemoryStoreCache.shared.save(films: memory.getAllFilmsMap(), lists: lists, links: memory.allFilmLinks(),
                                               contentVersion: 0, metadataFileID: Task { nil })
            let fast = MemoryStore()
            await fast.loadFromDatabase(persistentContainer: coordinator.persistentContainer, dataManager: reader)
            r.check("live/relaunch/fast-path-hit", fast.loadPathForTesting == "snapshot cache", fast.loadPathForTesting)
            r.check("live/relaunch/fast-path-links", fast.allFilmLinks() == memory.allFilmLinks()
                        && fast.filmLinksForTesting.count == memory.allFilmLinks().count && linkIndexIsConsistent(fast),
                    "\(fast.filmLinkCount) loaded, \(memory.filmLinkCount) held")

            var injected: UUID?
            do {
                let context = coordinator.persistentContainer.makeMainContext()
                if let film = try context.fetch(Film.request(.equals("id", f[3]))).first {
                    injected = FilmLink(kind: FilmLinkKind.sequel, source: film, target: film).id
                    try context.save()
                }
            } catch {
                r.check("live/relaunch/inject", false, "\(error)")
            }
            let slow = MemoryStore()
            await slow.loadFromDatabase(persistentContainer: coordinator.persistentContainer, dataManager: reader)
            r.check("live/relaunch/slow-path-after-store-only-link", injected != nil && slow.loadPathForTesting == "store",
                    slow.loadPathForTesting)
            r.check("live/relaunch/slow-path-sieves", slow.allFilmLinks() == memory.allFilmLinks()
                        && injected.map { slow.filmLinksForTesting[$0] == nil } == true && linkIndexIsConsistent(slow),
                    "\(slow.filmLinkCount) loaded, \(memory.filmLinkCount) held")
            await coordinator.cleanupFilmLinks()
            await parity("relaunch")
        }

        do {
            _ = try coordinator.setFilmLink(source: f[0], target: f[2], kind: "sequel")
            r.check("live/refused-cycle", false, "was accepted")
        } catch {
            r.check("live/refused-cycle", error == .cycle && !coordinator.hasPendingOperations, "\(error)")
        }
        let same = set(f[1], f[0], FilmLinkKind.sequel)
        r.check("live/identical-write-dispatches-nothing", same == l1 && !coordinator.hasPendingOperations, "")

        let flipped = set(f[0], f[1], FilmLinkKind.reboot)
        r.check("live/rewrite-keeps-id-and-date", flipped?.id == l1?.id && flipped?.dateAdded == l1?.dateAdded, "")
        let removed = coordinator.removeFilmLink(between: f[1], and: f[2])
        r.check("live/remove-returns-link", removed?.sourceID == f[2], "")
        await settle("rewrite-remove")
        await parity("rewrite-remove")
        await fingerprintParity("rewrite-remove")

        // MARK: Failures
        /// One failed write: the pair goes back to what the store holds (nothing).
        DebugPersistenceFault.failurePlan = [true]
        _ = set(s[0], s[1], FilmLinkKind.sequel)
        await settle("fail-new")
        r.check("live/fail-new/pair-empty", coordinator.filmLink(between: s[0], and: s[1]) == nil, "")
        await parity("fail-new")

        let kept = set(s[0], s[1], FilmLinkKind.sequel)
        await settle("kept")
        DebugPersistenceFault.failurePlan = [true]
        _ = set(s[1], s[0], FilmLinkKind.remake)
        await settle("fail-rewrite")
        r.check("live/fail-rewrite/back-to-stored", coordinator.filmLink(between: s[0], and: s[1]) == kept, "")
        DebugPersistenceFault.failurePlan = [true]
        coordinator.removeFilmLink(between: s[0], and: s[1])
        r.check("live/fail-remove/hidden-while-pending", coordinator.filmLink(between: s[0], and: s[1]) == nil, "")
        await settle("fail-remove")
        r.check("live/fail-remove/back", coordinator.filmLink(between: s[0], and: s[1]) == kept, "")
        await parity("fail-rewrite-remove")

        /// Two writes to one pair: the failure of the first must not undo the second, and the
        /// failure of the second must restore the store's value, not the first write's.
        DebugPersistenceFault.failurePlan = [true, false]
        _ = set(s[2], s[3], FilmLinkKind.sequel)
        let second = set(s[2], s[3], FilmLinkKind.remake)
        await settle("fail-then-succeed")
        r.check("live/fail-then-succeed/second-stands", coordinator.filmLink(between: s[2], and: s[3]) == second, "")
        await parity("fail-then-succeed")

        DebugPersistenceFault.failurePlan = [false, true]
        let first = set(s[2], s[3], FilmLinkKind.prequel)
        _ = set(s[3], s[2], FilmLinkKind.reboot)
        await settle("succeed-then-fail")
        r.check("live/succeed-then-fail/first-stands", coordinator.filmLink(between: s[2], and: s[3]) == first, "")
        await parity("succeed-then-fail")

        DebugPersistenceFault.failurePlan = [true, true]
        _ = set(s[4], s[5], FilmLinkKind.sequel)
        _ = set(s[4], s[5], FilmLinkKind.remake)
        await settle("fail-twice")
        r.check("live/fail-twice/pair-empty", coordinator.filmLink(between: s[4], and: s[5]) == nil, "")
        await parity("fail-twice")
        DebugPersistenceFault.failurePlan = []

        // MARK: Film deletes
        /// A linked film's delete fails: the film comes back and so does its link, unchanged.
        DebugPersistenceFault.failurePlan = [true]
        let revisionBeforeDelete = coordinator.filmLinksRevision
        await coordinator.deleteFilms(withIDs: [s[1]])
        r.check("live/delete-rollback/hidden-while-pending",
                coordinator.filmLink(between: s[0], and: s[1]) == nil && coordinator.filmLinkRelations(forFilm: s[0]).isEmpty
                    && coordinator.filmLinksRevision > revisionBeforeDelete, "")
        await settle("delete-rollback")
        r.check("live/delete-rollback/link-back", coordinator.filmLink(between: s[0], and: s[1]) == kept, "")
        await parity("delete-rollback")

        /// Two linked films deleted by two operations that both fail: the link between them is
        /// back too (the case a captured-and-restored link list could not cover).
        let across = set(s[2], s[4], FilmLinkKind.spinOff)
        await settle("across")
        DebugPersistenceFault.failurePlan = [true, true]
        await coordinator.deleteFilms(withIDs: [s[2]])
        await coordinator.deleteFilms(withIDs: [s[4]])
        await settle("delete-rollback-twice")
        r.check("live/delete-rollback-twice/link-back", coordinator.filmLink(between: s[2], and: s[4]) == across, "")
        await parity("delete-rollback-twice")

        /// A delete that persists: the store cascades, memory prunes once nothing is pending.
        let doomed = set(s[5], s[4], FilmLinkKind.sequel)
        await settle("doomed")
        await coordinator.deleteFilms(withIDs: [s[5]])
        await settle("delete-persists")
        r.check("live/delete-persists/pruned",
                doomed.map { memory.filmLinksForTesting[$0.id] == nil } == true && memory.filmToLinksForTesting[s[5]] == nil, "")
        await parity("delete-persists")
        await fingerprintParity("delete-persists")

        // MARK: Launch cleanup
        /// Damage written straight into the store, behind memory's back: a self-link, an older
        /// second link on a linked pair (the cleanup keeps the oldest, so memory's link is the
        /// one removed) and an orphan. The cleanup must leave memory equal to the store.
        do {
            let context = coordinator.persistentContainer.makeMainContext()
            let stored = try context.fetch(Film.request(.in("id", [s[0], s[1], s[3]])))
            guard let p0 = stored.first(where: { $0.id == s[0] }), let p1 = stored.first(where: { $0.id == s[1] }),
                  let p3 = stored.first(where: { $0.id == s[3] }) else { throw CocoaError(.coderValueNotFound) }
            _ = FilmLink(kind: FilmLinkKind.sequel, source: p3, target: p3, dateAdded: Date(timeIntervalSinceReferenceDate: 5))
            _ = FilmLink(kind: FilmLinkKind.prequel, source: p0, target: p1, dateAdded: Date(timeIntervalSinceReferenceDate: 6))
            let orphan = FilmLink(kind: FilmLinkKind.sequel, source: p0, target: p3, dateAdded: Date(timeIntervalSinceReferenceDate: 7))
            orphan.targetFilm = nil
            try context.save()
        } catch {
            r.check("live/cleanup/inject", false, "\(error)")
        }
        await coordinator.cleanupFilmLinks()
        r.check("live/cleanup/older-link-wins", coordinator.filmLink(between: s[0], and: s[1])?.kind == FilmLinkKind.prequel, "")
        await parity("cleanup")
        await fingerprintParity("cleanup")

        // MARK: Leave the library as found
        for link in memory.allFilmLinks() where !startLinks.contains(link) {
            coordinator.removeFilmLink(between: link.sourceID, and: link.targetID)
        }
        await settle("cleanup-links")
        await coordinator.deleteFilms(withIDs: Set(s).intersection(memory.getAllFilmsMap().keys))
        await settle("cleanup-films")
        r.check("live/restored", memory.allFilmLinks() == startLinks && s.allSatisfy { memory.getFilm($0) == nil }, "")
        await parity("end")
        await fingerprintParity("end")
        DebugPersistenceFault.reset()
    }
}

#endif
