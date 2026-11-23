// MARK: - DHFilmLinks.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only harness scenario for the FilmLink entity (Staging/FilmLinks/PLAN.md): the
/// migration that adds it, its rules, its write API, the delete cascade, the launch cleanup
/// and the backup round trip, all against real films.
///
/// Everything runs on copies inside `<sandbox>/film-links-probe/`, never on the sandbox's own
/// library store, so later scenarios see the library as it was:
///
///   • migrated.sqlite — the pre-migration store named by `-FTFilmLinksPremigration <path>`
///     (a copy of the live library taken before this build ever opened it), opened once with
///     this model so the inferred migration runs exactly as it would at the user's launch, then
///     closed. Staging/FilmLinks/compare_stores.py compares it with the original afterwards.
///     Without the argument, the sandbox's own (already migrated) store is used instead.
///   • probe.sqlite — a copy of migrated.sqlite that every behavior case writes to.
///
/// The cases, each a named check:
///   migration/*   the store opens, ZFILMLINK has its columns, no link rows, every other
///                 entity's count unchanged, the deduplicator's column names are real.
///   rules/*       self-link, empty kind, missing film, same-kind cycle (case-insensitive),
///                 a different kind across the same chain allowed; every refusal leaves the
///                 store byte-for-byte as it was (digest).
///   pair/*        a second link on a linked pair rewrites it (same ID, new kind/direction).
///   persist/*     links read back identically after a relaunch.
///   edits/*       film edits (single, batch-update path, fetched path, FilmSheet changeset with
///                 list changes) leave every link alone.
///   delete/*      deleting a film deletes its links in both directions and nothing else:
///                 after a relaunch, in the session that created them, and when another
///                 context created the link this context never loaded.
///   remove/*      removeFilmLink and removeFilmLinks(between:).
///   cleanup/*     injected orphan, self-link, repeated pair and same-kind cycle are reported
///                 by StoreInspection, removed by cleanupFilmLinks (oldest kept), and a second
///                 cleanup removes nothing.
///   backup/*      export → restore → the relaunch swap: links identical, dates exact (a
///                 link carries dateAddedExact beside the whole-second dateAdded); a backup carrying bad links (hand-made
///                 XML: self, repeated pair, cycle, repeated ID, unknown film, malformed ID,
///                 empty kind) restores only the valid ones and passes the commit's structural
///                 check.
///   old-backup/*  the same export with its links and their manifest entry removed (what an
///                 older build writes) restores every other row, no link, and the restored
///                 library takes a link that survives a relaunch and the launch cleanup.
///   real-old-backup/*  the same, for a real backup an earlier build wrote
///                 (`-FTFilmLinksOldBackup <package>`), against its own manifest.
///   old-staged/*  a restore an older build staged (old schema, rollback journal, its marker
///                 digest without FilmLink) is migrated, checked by row counts and swapped in
///                 by this build's launch, with every row kept (needs -FTFilmLinksPremigration).
///   untouched     every non-link entity's digest on the probe is what it was before the
///                 link cases, apart from the films the cases edited or deleted on purpose.

#if DEBUG

import Foundation
import CoreData
import SQLite3
import CryptoKit

extension DebugHarness {

    static func runFilmLinkScenario(_ scenario: String, coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "film-links": return await filmLinksScenario(coordinator: coordinator)
        case "film-links-memory": return await filmLinksMemoryScenario(coordinator: coordinator)
        default: return nil
        }
    }

    // MARK: - SQL Helpers

    /// Runs `sql` against the file at `url` and returns every row as text, or nil when the file
    /// or the statement fails. `writable` is for a copy in WAL mode with no -shm beside it, which
    /// a read-only connection cannot open (the pre-migration copy); the statements are reads.
    private static func sqlRows(_ url: URL, _ sql: String, writable: Bool = false) -> [[String]]? {
        var db: OpaquePointer?
        defer { unsafe sqlite3_close(db) }
        let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, flags, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { unsafe sqlite3_finalize(statement) }
        guard unsafe sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var rows: [[String]] = []
        while unsafe sqlite3_step(statement) == SQLITE_ROW {
            let columns = unsafe sqlite3_column_count(statement)
            rows.append((0..<columns).map { index in
                guard let text = unsafe sqlite3_column_text(statement, index) else { return "" }
                return unsafe String(cString: text)
            })
        }
        return rows
    }

    /// Closes every store `container` has open, so the file can be copied or read raw.
    private static func close(_ container: NSPersistentContainer) {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
    }

    /// Per-entity row counts read through Core Data.
    private static func entityCounts(_ container: NSPersistentContainer) -> [String: Int] {
        let context = container.makeMainContext()
        var counts: [String: Int] = [:]
        for entity in LibraryModel.shared.model.entities {
            guard let name = entity.name else { continue }
            counts[name] = (try? context.count(for: NSFetchRequest<any NSFetchRequestResult>(entityName: name))) ?? -1
        }
        return counts
    }

    /// The links as comparable text, "source>target:kind@id", sorted; with `withDates`, each
    /// date's exact bits too.
    private static func linkLines(_ links: [FilmLinkSnapshot], withDates: Bool = false) -> [String] {
        links.map { link in
            let date = withDates ? "#\(String(link.dateAdded.timeIntervalSinceReferenceDate.bitPattern, radix: 16))" : ""
            return "\(link.sourceID)>\(link.targetID):\(link.kind)@\(link.id)\(date)"
        }.sorted()
    }

    // MARK: - Scenario

    private static func filmLinksScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "film-links")
        guard let libraryURL = LibraryStore.storeURL else {
            r.check("store-folder", false, "no store URL in this sandbox"); return r
        }
        let folder = libraryURL.deletingLastPathComponent().appendingPathComponent("film-links-probe", isDirectory: true)
        let migratedURL = folder.appendingPathComponent("migrated.sqlite")
        let probeURL = folder.appendingPathComponent("probe.sqlite")
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // MARK: Migration
        let arguments = ProcessInfo.processInfo.arguments
        let premigration = arguments.firstIndex(of: "-FTFilmLinksPremigration")
            .flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        do {
            if let premigration {
                /// A plain file copy: the pre-migration store is a single checkpointed file
                /// (SQLite backup API), and Core Data must not touch the original.
                try fm.copyItem(at: premigration, to: migratedURL)
                /// The source is kept read-only so nothing can migrate it; the copy must be writable.
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: migratedURL.path(percentEncoded: false))
                let before = sqlRows(migratedURL, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'", writable: true)
                let named = Set((before ?? []).compactMap(\.first))
                r.check("migration/premigration-has-no-link-table", before != nil && named.contains("ZFILM") && !named.contains("ZFILMLINK"),
                        before == nil ? "unreadable" : named.contains("ZFILMLINK") ? "the store named is already migrated"
                            : "\(premigration.lastPathComponent): \(named.count) table(s), no ZFILMLINK")
                let counts: [String: Int] = Dictionary(uniqueKeysWithValues: [
                    ("Film", "ZFILM"), ("ListObject", "ZLISTOBJECT"), ("ListMembership", "ZLISTMEMBERSHIP"),
                    ("Release", "ZRELEASE"), ("ImportSession", "ZIMPORTSESSION"),
                    ("SettingsObject", "ZSETTINGSOBJECT"), ("SavedSearchObject", "ZSAVEDSEARCHOBJECT"),
                ].map { ($0.0, Int(sqlRows(migratedURL, "SELECT COUNT(*) FROM \($0.1)", writable: true)?.first?.first ?? "") ?? -1) })

                let start = ContinuousClock.now
                let container = try LibraryStore.makeContainer(at: migratedURL)
                r.metric("migration-open", milliseconds(ContinuousClock.now - start), "ms")
                let after = entityCounts(container)
                let report = try StoreInspection.inspect(container.makeMainContext())
                close(container)
                var drift: [String] = []
                for (name, count) in counts where after[name] != count {
                    drift.append("\(name) \(count) → \(after[name] ?? -1)")
                }
                r.check("migration/opens-with-counts-unchanged", drift.isEmpty,
                        drift.isEmpty ? counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                                      : drift.joined(separator: "; "))
                r.check("migration/no-link-rows", after["FilmLink"] == 0, "FilmLink \(after["FilmLink"] ?? -1)")
                r.check("migration/no-structural-problems", report.problems.isEmpty, report.problems.joined(separator: "; "))
            } else {
                r.skip("migration/premigration-has-no-link-table", "no -FTFilmLinksPremigration; using the sandbox store")
                try LibraryStore.replaceStore(at: migratedURL, withStoreAt: libraryURL)
            }
            let columns = Set((sqlRows(migratedURL, "PRAGMA table_info(ZFILMLINK)") ?? []).map { $0[1] })
            let wanted: Set<String> = ["Z_PK", "Z_ENT", "Z_OPT", "ZID", "ZKIND", "ZDATEADDED", "ZSOURCEFILM", "ZTARGETFILM"]
            r.check("migration/link-table-columns", wanted.isSubset(of: columns),
                    "missing: \(wanted.subtracting(columns).sorted()); have: \(columns.sorted())")
            let indexes = (sqlRows(migratedURL, "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='ZFILMLINK'") ?? [])
                .map { $0.first ?? "" }
            r.check("migration/link-id-unique-index",
                    indexes.contains { $0.hasPrefix("CREATE UNIQUE INDEX") && $0.contains("(ZID") },
                    indexes.joined(separator: " | "))
            try LibraryStore.replaceStore(at: probeURL, withStoreAt: migratedURL)
        } catch {
            r.check("migration/open", false, "threw: \(error)")
            return r
        }

        // MARK: Rule scale
        /// The launch cleanup and the restore run every link through FilmLinkRules.sieve, whose
        /// loop test walks the chain of one kind a new link joins. Links are added newest-end
        /// first, the order that makes every test walk the whole chain built so far.
        ///   • realistic: 200 franchises of 25 films each (5,000 links) plus a closing link per
        ///     franchise; every closing link refused, and quick.
        ///   • pathological: one 2,500-film chain of one kind (no real library has one); cost is
        ///     quadratic in the chain's length, so this only proves it finishes.
        func chains(count: Int, length: Int) -> [(UUID, UUID, String)] {
            var items: [(UUID, UUID, String)] = []
            for _ in 0..<count {
                let chain = (0...length).map { _ in UUID() }
                for index in stride(from: length - 1, through: 0, by: -1) { items.append((chain[index], chain[index + 1], "Sequel")) }
                items.append((chain[length], chain[0], "sequel"))
            }
            return items
        }
        for (name, count, length, limit) in [("realistic", 200, 25, 250.0), ("pathological", 1, 2_500, 10_000.0)] {
            let items = chains(count: count, length: length)
            let start = ContinuousClock.now
            let (kept, rejected) = FilmLinkRules.sieve(items, ends: { ($0.0, $0.1) }, kind: { $0.2 })
            let elapsed = milliseconds(ContinuousClock.now - start)
            r.metric("sieve-\(name)-\(items.count)-links", elapsed, "ms")
            r.check("rules/sieve-\(name)",
                    rejected.count == count && rejected.allSatisfy { $0.1 == .cycle && $0.0.2 == "sequel" }
                        && kept.count == count * length && elapsed < limit,
                    "\(kept.count) kept, \(rejected.count) closing link(s) refused, \(Int(elapsed)) ms (limit \(Int(limit)))")
        }

        // MARK: Probe stack
        var container: NSPersistentContainer
        var dm: DataManager
        do {
            container = try LibraryStore.makeContainer(at: probeURL)
            dm = DataManager(persistentContainer: container)
        } catch {
            r.check("probe/open", false, "threw: \(error)"); return r
        }
        func relaunch() throws {
            close(container)
            container = try LibraryStore.makeContainer(at: probeURL)
            dm = DataManager(persistentContainer: container)
        }
        func digest() -> [String: String] {
            (try? StoreInspection.inspect(container.makeMainContext()).digest) ?? [:]
        }
        func problems() -> [String] {
            (try? StoreInspection.inspect(container.makeMainContext()).problems) ?? ["unreadable"]
        }

        /// Real films, in a fixed order: the oldest-added first, then by ID.
        let films: [UUID] = {
            let request = NSFetchRequest<NSDictionary>(entityName: Film.entityName)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "name"]
            let rows = (try? container.makeMainContext().fetch(request)) ?? []
            return rows.compactMap { row -> (UUID, String)? in
                guard let id = row["id"] as? UUID else { return nil }
                return (id, row["name"] as? String ?? "")
            }.sorted { ($0.1, $0.0.uuidString) < ($1.1, $1.0.uuidString) }.map(\.0)
        }()
        guard films.count >= 30 else {
            r.check("probe/enough-films", false, "\(films.count) film(s); the cases need 30"); return r
        }
        r.check("probe/enough-films", true, "\(films.count) real film(s)")
        let f = Array(films.prefix(30))
        let startDigest = digest()
        let startCounts = entityCounts(container)
        /// The films the delete cases remove, and what cascades with them.
        let deletedFilms: Set<UUID> = [f[4], f[8], f[11], f[24], f[25]]
        let goneWithThem: [String: Int] = {
            let context = container.makeMainContext()
            return [
                "Release": (try? context.count(for: Release.request(.in("film.id", deletedFilms)))) ?? -1,
                "ListMembership": (try? context.count(for: ListMembership.request(.in("film.id", deletedFilms)))) ?? -1,
            ]
        }()

        do {
            // MARK: Rules
            let a = try await dm.setFilmLink(source: f[1], target: f[0], kind: FilmLinkKind.sequel)
            let b = try await dm.setFilmLink(source: f[2], target: f[1], kind: "  Sequel ")
            let c = try await dm.setFilmLink(source: f[3], target: f[0], kind: FilmLinkKind.remake)
            r.check("rules/created", b.kind == "Sequel" && a.sourceID == f[1] && a.targetID == f[0] && c.kind == "Remake",
                    "kind trimmed to '\(b.kind)'")
            var links = try await dm.fetchFilmLinks()
            r.check("rules/fetch", Set(links) == [a, b, c], "\(links.count) link(s)")
            let forFilm = try await dm.fetchFilmLinks(for: f[0])
            r.check("rules/fetch-for-film", Set(forFilm) == [a, c], "\(forFilm.count) link(s) on film 0")

            let beforeRefusals = digest()
            func expect(_ name: String, _ error: FilmLinkError, _ body: () async throws -> Void) async {
                do {
                    try await body()
                    r.check("rules/\(name)", false, "accepted")
                } catch let thrown as FilmLinkError {
                    r.check("rules/\(name)", thrown == error, "threw \(thrown)")
                } catch {
                    r.check("rules/\(name)", false, "threw \(error)")
                }
            }
            await expect("self-link", .selfLink) { try await dm.setFilmLink(source: f[4], target: f[4], kind: "Sequel") }
            await expect("empty-kind", .emptyKind) { try await dm.setFilmLink(source: f[4], target: f[5], kind: " \n") }
            let ghost = UUID()
            await expect("missing-film", .filmNotFound(ghost)) { try await dm.setFilmLink(source: f[4], target: ghost, kind: "Sequel") }
            await expect("cycle", .cycle) { try await dm.setFilmLink(source: f[0], target: f[2], kind: "Sequel") }
            await expect("cycle-any-case", .cycle) { try await dm.setFilmLink(source: f[0], target: f[2], kind: "sequel") }
            r.check("rules/refusals-change-nothing", digest() == beforeRefusals, "store digest compared")

            let crossKind = try await dm.setFilmLink(source: f[0], target: f[2], kind: FilmLinkKind.prequel)
            r.check("rules/other-kind-across-chain", crossKind.kind == "Prequel", "a loop of mixed kinds is allowed")
            /// Rewriting that pair to Sequel would close the sequel loop: refused, and the
            /// Prequel link it would have replaced stays as it was.
            await expect("rewrite-into-cycle", .cycle) { try await dm.setFilmLink(source: f[0], target: f[2], kind: "Sequel") }
            links = try await dm.fetchFilmLinks()
            r.check("rules/refused-rewrite-keeps-link", links.contains(crossKind), "\(links.count) link(s)")

            // MARK: Pair
            let flipped = try await dm.setFilmLink(source: f[0], target: f[3], kind: FilmLinkKind.reboot)
            links = try await dm.fetchFilmLinks()
            r.check("pair/rewrites-in-place",
                    flipped.id == c.id && flipped.sourceID == f[0] && flipped.targetID == f[3]
                        && flipped.kind == "Reboot" && links.count == 4 && flipped.dateAdded == c.dateAdded,
                    "\(links.count) link(s); id kept: \(flipped.id == c.id)")
            /// Reversing b (f2 → f1) to f1 → f2: b is the link being rewritten, so it is left
            /// out of the loop test, and f1 → f2 beside a (f1 → f0) closes nothing.
            let reversed = try await dm.setFilmLink(source: f[1], target: f[2], kind: "Sequel")
            r.check("pair/reverse-direction", reversed.id == b.id && reversed.sourceID == f[1], "same ID, reversed")

            // MARK: Persist
            let beforeRelaunch = linkLines(try await dm.fetchFilmLinks(), withDates: true)
            try relaunch()
            let afterRelaunch = linkLines(try await dm.fetchFilmLinks(), withDates: true)
            r.check("persist/relaunch", beforeRelaunch == afterRelaunch, "\(afterRelaunch.count) link(s)")

            // MARK: Edits
            let linksBeforeEdits = linkLines(try await dm.fetchFilmLinks())
            let context = container.makeMainContext()
            let edited = try context.fetch(Film.request(.in("id", [f[0], f[1], f[2]])))
            var snapshots = edited.map { FilmSnapshot(from: $0) }
            snapshots[0].name += " (edited)"
            try await dm.updateFilm(snapshots[0])
            if let genre = FilmField(rawValue: "genre") {
                for index in snapshots.indices { snapshots[index].genre = "Film Link Probe" }
                try await dm.applyFilmFields(snapshots, fields: [genre])          /// the batch-update path
            }
            if let tags = FilmField(rawValue: "tags") {
                for index in snapshots.indices { snapshots[index].tags.append("link-probe-\(index)") }
                try await dm.applyFilmFields(snapshots, fields: [tags])           /// the fetched path
            }
            let listID = UUID()
            try await dm.createList(listID: listID, name: "Film Link Probe", displayOrder: 900)
            try await dm.applyFilmChangeset(FilmChangeset(
                filmID: snapshots[1].id, isNewFilm: false, filmSnapshot: snapshots[1],
                releasesToCreate: [], releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [listID], listsToRemove: []))
            try await dm.applyFilmChangeset(FilmChangeset(
                filmID: snapshots[1].id, isNewFilm: false, filmSnapshot: snapshots[1],
                releasesToCreate: [], releasesToUpdate: [], releasesToDelete: [],
                listsToAdd: [], listsToRemove: [listID]))
            try await dm.deleteList(listID: listID)
            r.check("edits/links-unchanged", linkLines(try await dm.fetchFilmLinks()) == linksBeforeEdits,
                    "single, batch, fetched and changeset edits on linked films")

            // MARK: Delete
            /// After a relaunch: the deleting context never loaded these links.
            try await dm.setFilmLink(source: f[5], target: f[4], kind: "Sequel")
            try await dm.setFilmLink(source: f[4], target: f[6], kind: "Remake")
            try await dm.setFilmLink(source: f[7], target: f[6], kind: "Spin-off")
            try relaunch()
            try await dm.deleteFilms(withIDs: [f[4]])
            links = try await dm.fetchFilmLinks()
            let filmsLeft = try container.makeMainContext().count(for: Film.request(.in("id", [f[5], f[6], f[7]])))
            r.check("delete/after-relaunch",
                    !links.contains { $0.sourceID == f[4] || $0.targetID == f[4] }
                        && links.contains { $0.sourceID == f[7] && $0.targetID == f[6] } && filmsLeft == 3,
                    "both of film 4's links gone; film 7 → 6 kept; \(filmsLeft) of 3 other films kept")

            /// In the session that created them.
            try await dm.setFilmLink(source: f[8], target: f[9], kind: "Sequel")
            try await dm.setFilmLink(source: f[10], target: f[8], kind: "Sequel")
            try await dm.deleteFilms(withIDs: [f[8]])
            links = try await dm.fetchFilmLinks()
            r.check("delete/same-session", !links.contains { $0.sourceID == f[8] || $0.targetID == f[8] },
                    "\(links.count) link(s) left")

            /// Created by another context after this one loaded the film.
            _ = try await dm.fetchFilmLinks(for: f[11])
            let other = container.makeMainContext()
            if let s = try other.fetch(Film.request(.equals("id", f[12]))).first,
               let t = try other.fetch(Film.request(.equals("id", f[11]))).first {
                _ = FilmLink(kind: "Sequel", source: s, target: t)
                try other.commit()
            }
            try await dm.deleteFilms(withIDs: [f[11]])
            let otherLeft = try container.makeMainContext().count(for: FilmLink.request(.equals("targetFilm.id", f[11])))
            let orphansLeft = try container.makeMainContext().count(for: FilmLink.request(NSPredicate(format: "sourceFilm == nil OR targetFilm == nil")))
            r.check("delete/link-from-other-context", otherLeft == 0 && orphansLeft == 0,
                    "\(otherLeft) link(s) to the deleted film, \(orphansLeft) orphan(s)")
            r.check("delete/no-structural-problems", problems().isEmpty, problems().joined(separator: "; "))

            /// Both ends in one delete: the two cascades reach the same link.
            try await dm.setFilmLink(source: f[24], target: f[25], kind: "Sequel")
            try await dm.setFilmLink(source: f[26], target: f[24], kind: "Sequel")
            try relaunch()
            try await dm.deleteFilms(withIDs: [f[24], f[25]])
            links = try await dm.fetchFilmLinks()
            let survivor = try container.makeMainContext().count(for: Film.request(.equals("id", f[26])))
            r.check("delete/both-ends-one-call",
                    !links.contains { [f[24], f[25]].contains($0.sourceID) || [f[24], f[25]].contains($0.targetID) }
                        && survivor == 1 && problems().isEmpty,
                    "\(links.count) link(s) left; film 26 kept: \(survivor == 1)")

            // MARK: Damaged pair
            /// Two links on one pair, which only a store the cleanup has not repaired holds.
            /// Setting the pair must leave exactly one (the oldest, rewritten), and the newer
            /// one, pointing back, must not count as a loop against the link replacing it.
            do {
                let raw = container.makeMainContext()
                let a = try raw.fetch(Film.request(.equals("id", f[27]))).first!
                let b = try raw.fetch(Film.request(.equals("id", f[28]))).first!
                let older = FilmLink(kind: "Remake", source: a, target: b, dateAdded: Date(timeIntervalSinceReferenceDate: 600_000_000))
                _ = FilmLink(kind: "Sequel", source: b, target: a, dateAdded: Date(timeIntervalSinceReferenceDate: 600_000_100))
                try raw.commit()
                let set = try await dm.setFilmLink(source: f[27], target: f[28], kind: "Sequel")
                let onPair = try await dm.fetchFilmLinks().filter { FilmLinkRules.Pair($0.sourceID, $0.targetID) == FilmLinkRules.Pair(f[27], f[28]) }
                r.check("pair/damaged-pair-repaired", onPair == [set] && set.id == older.id && set.kind == "Sequel",
                        "\(onPair.count) link(s) on the pair; oldest kept: \(set.id == older.id)")
            } catch {
                r.check("pair/damaged-pair-repaired", false, "threw: \(error)")
            }

            // MARK: Remove
            let removable = try await dm.setFilmLink(source: f[13], target: f[14], kind: "Sequel")
            let removed = try await dm.removeFilmLink(id: removable.id)
            let removedAgain = try await dm.removeFilmLink(id: removable.id)
            try await dm.setFilmLink(source: f[15], target: f[14], kind: "Remake")
            let between = try await dm.removeFilmLinks(between: f[14], and: f[15])
            links = try await dm.fetchFilmLinks()
            r.check("remove/by-id-and-pair", removed && !removedAgain && between == 1
                        && !links.contains { [f[13], f[14], f[15]].contains($0.sourceID) },
                    "by id: \(removed), again: \(removedAgain), between: \(between)")

            // MARK: Cleanup
            /// Rows only a damaged store holds, written past the rules through a raw context,
            /// with dates so the oldest-first choice is known.
            let raw = container.makeMainContext()
            func film(_ id: UUID) throws -> Film { try raw.fetch(Film.request(.equals("id", id))).first! }
            let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
            let orphan = FilmLink(kind: "Sequel", source: try film(f[16]), target: try film(f[17]), dateAdded: base)
            orphan.targetFilm = nil
            let selfLink = FilmLink(kind: "Sequel", source: try film(f[17]), target: try film(f[17]), dateAdded: base)
            let pairOld = FilmLink(kind: "Remake", source: try film(f[18]), target: try film(f[19]), dateAdded: base)
            let pairNew = FilmLink(kind: "Sequel", source: try film(f[19]), target: try film(f[18]), dateAdded: base + 60)
            let cycle1 = FilmLink(kind: "Reboot", source: try film(f[20]), target: try film(f[21]), dateAdded: base)
            let cycle2 = FilmLink(kind: "Reboot", source: try film(f[21]), target: try film(f[22]), dateAdded: base + 1)
            let cycle3 = FilmLink(kind: "reboot", source: try film(f[22]), target: try film(f[20]), dateAdded: base + 2)
            let blank = FilmLink(kind: "", source: try film(f[23]), target: try film(f[16]), dateAdded: base)
            try raw.commit()
            let keptIDs: Set<UUID> = [pairOld.id, cycle1.id, cycle2.id]
            let doomedIDs: Set<UUID> = [orphan.id, selfLink.id, pairNew.id, cycle3.id, blank.id]
            let flagged = problems()
            r.check("cleanup/inspection-flags-damage",
                    flagged.contains { $0.contains("without both films") } && flagged.contains { $0.contains("to itself") }
                        && flagged.contains { $0.contains("already linked") },
                    flagged.joined(separator: "; "))
            let firstResult = try await dm.cleanupFilmLinks()
            let firstPass = firstResult.counts
            let secondPass = try await dm.cleanupFilmLinks().counts
            let afterCleanup = Set(try container.makeMainContext().fetch(FilmLink.request()).map(\.id))
            r.check("cleanup/removes-exactly-the-damage",
                    afterCleanup.isDisjoint(with: doomedIDs) && keptIDs.isSubset(of: afterCleanup)
                        && firstPass == [.orphan: 1, .selfLink: 1, .repeatedPair: 1, .cycle: 1, .emptyKind: 1],
                    "removed \(firstPass.map { "\($0.key.rawValue): \($0.value)" }.sorted().joined(separator: ", "))")
            r.check("cleanup/reports-removed-ids", firstResult.removedIDs == doomedIDs,
                    "\(firstResult.removedIDs.count) ID(s) reported, \(doomedIDs.count) expected")
            r.check("cleanup/idempotent", secondPass.isEmpty, "second pass removed \(secondPass.values.reduce(0, +))")
            r.check("cleanup/no-structural-problems", problems().isEmpty, problems().joined(separator: "; "))

            // MARK: Untouched
            /// Lists, import sessions, settings and saved searches exactly as before (the cases
            /// created and deleted one list). Films, releases and memberships short by exactly
            /// the five deleted films and what cascaded with them, and nothing else.
            let endDigest = digest()
            let endCounts = entityCounts(container)
            let exact = ["ListObject", "ImportSession", "SettingsObject", "SavedSearchObject"]
            let changed = exact.filter { endDigest[$0] != startDigest[$0] }
            let expected: [String: Int] = [
                "Film": (startCounts["Film"] ?? 0) - deletedFilms.count,
                "Release": (startCounts["Release"] ?? 0) - (goneWithThem["Release"] ?? 0),
                "ListMembership": (startCounts["ListMembership"] ?? 0) - (goneWithThem["ListMembership"] ?? 0),
            ]
            let miscounted = expected.filter { endCounts[$0.key] != $0.value }
            r.check("untouched/other-entities", changed.isEmpty && miscounted.isEmpty,
                    "unchanged: \(exact.joined(separator: ", ")); "
                        + expected.sorted { $0.key < $1.key }.map { "\($0.key) \(startCounts[$0.key] ?? -1) → \(endCounts[$0.key] ?? -1) (want \($0.value))" }.joined(separator: ", ")
                        + (changed.isEmpty ? "" : "; changed: \(changed)"))
        } catch {
            r.check("cases", false, "threw: \(error)")
            close(container)
            return r
        }

        // MARK: Backup round trip
        await backupRoundTrip(&r, container: container, folder: folder)
        await oldStagedRestoreCase(&r, premigration: premigration)
        close(container)
        restoredStoreInUse = false
        return r
    }

    /// Exports the probe, restores it as the app would (staged store, structural check,
    /// relaunch swap) and compares links; then restores a hand-edited copy carrying bad links.
    private static func backupRoundTrip(_ r: inout HarnessScenarioResult, container: NSPersistentContainer, folder: URL) async {
        let dm = DataManager(persistentContainer: container)
        guard let source = try? await dm.fetchFilmLinks(), !source.isEmpty else {
            r.check("backup/source-links", false, "no links to round-trip"); return
        }
        let sourceCounts = entityCounts(container)
        /// Without a fraction of a second somewhere, "exact dates" below would prove nothing
        /// a whole-second backup date does not.
        let fractional = source.filter { $0.dateAdded.timeIntervalSinceReferenceDate.rounded(.down) != $0.dateAdded.timeIntervalSinceReferenceDate }
        r.check("backup/source-has-fractional-dates", !fractional.isEmpty, "\(fractional.count) of \(source.count) link date(s) fall within a second")
        guard let package = await exportBackupPackage(container: container, filename: "film-links-roundtrip") else {
            r.check("backup/export", false, "export failed"); return
        }
        defer { try? FileManager.default.removeItem(at: package) }
        let xmlURL = package.appendingPathComponent("backup.xml")
        let xml = (try? String(contentsOf: xmlURL, encoding: .utf8)) ?? ""
        let exported = xml.components(separatedBy: "entity=\"FilmLink\"").count - 1
        r.check("backup/exported", exported == source.count, "\(exported) of \(source.count) link object(s) in backup.xml")

        let (error, _) = await restoreBackupPackage(package, container: container)
        guard error == nil, restoredStoreInUse, let restoredURL = harnessRestoredStoreURL else {
            r.check("backup/restore", false, "\(error.map { "\($0)" } ?? "no swap")"); return
        }
        do {
            let restored = try LibraryStore.makeContainer(at: restoredURL)
            defer { close(restored) }
            let restoredLinks = try await DataManager(persistentContainer: restored).fetchFilmLinks()
            r.check("backup/links-identical", linkLines(restoredLinks, withDates: true) == linkLines(source, withDates: true),
                    "\(restoredLinks.count) of \(source.count) link(s), ends, kinds, IDs and exact dates")
            let restoredCounts = entityCounts(restored)
            let differing = sourceCounts.keys.filter { $0 != "SettingsObject" && restoredCounts[$0] != sourceCounts[$0] }
            r.check("backup/entity-counts", differing.isEmpty,
                    differing.isEmpty ? "every entity" : differing.map { "\($0) \(sourceCounts[$0]!) → \(restoredCounts[$0] ?? -1)" }.joined(separator: ", "))
        } catch {
            r.check("backup/restored-open", false, "threw: \(error)"); return
        }

        // MARK: Bad links in a backup
        /// Templated from a real exported link object, so the XML is exactly what the
        /// packager writes; only the property values change.
        guard let openTag = xml.range(of: "<Object id=\"FilmLink-"),
              let closeTag = xml.range(of: "</Object>", range: openTag.upperBound..<xml.endIndex) else {
            r.check("backup/bad-template", false, "no FilmLink object in backup.xml"); return
        }
        let lineStart = xml[..<openTag.lowerBound].lastIndex(of: "\n").map { xml.index(after: $0) } ?? openTag.lowerBound
        let template = String(xml[lineStart..<closeTag.upperBound]) + "\n"
        func property(_ name: String) -> String? {
            guard let range = template.range(of: "<Property name=\"\(name)\"[^>]*>[^<]*</Property>", options: .regularExpression) else { return nil }
            return String(template[range])
        }
        func object(id: String, kind: String, source: String, target: String, date: String) -> String {
            var text = template
            func replace(_ name: String, _ value: String) {
                guard let old = property(name),
                      let gt = old.firstIndex(of: ">") else { return }
                let opening = old[...gt]
                text = text.replacingOccurrences(of: old, with: "\(opening)\(value)</Property>")
            }
            replace("id", id); replace("kind", kind); replace("sourceFilmID", source)
            replace("targetFilmID", target); replace("dateAdded", date)
            if let range = text.range(of: "<Object id=\"FilmLink-[^\"]*\"", options: .regularExpression) {
                text.replaceSubrange(range, with: "<Object id=\"FilmLink-\(id)\"")
            }
            return text
        }
        let filmIDs = Array(Set(source.flatMap { [$0.sourceID, $0.targetID] }).sorted { $0.uuidString < $1.uuidString })
        guard filmIDs.count >= 3, let dateValue = property("dateAdded").flatMap({ p -> String? in
            guard let gt = p.firstIndex(of: ">"), let lt = p.lastIndex(of: "<") else { return nil }
            return String(p[p.index(after: gt)..<lt])
        }) else {
            r.check("backup/bad-template", false, "template incomplete"); return
        }
        let x = filmIDs[0].uuidString, y = filmIDs[1].uuidString
        let existing = source[0]
        let good = UUID()
        let bad: [(String, String)] = [
            ("self", object(id: UUID().uuidString, kind: "Sequel", source: x, target: x, date: dateValue)),
            ("repeated-pair", object(id: UUID().uuidString, kind: "Remake", source: existing.targetID.uuidString,
                                     target: existing.sourceID.uuidString, date: "2099-01-01T00:00:00Z")),
            ("repeated-id", object(id: existing.id.uuidString, kind: "Sequel", source: x, target: y, date: "2099-01-01T00:00:00Z")),
            ("unknown-film", object(id: UUID().uuidString, kind: "Sequel", source: x, target: UUID().uuidString, date: dateValue)),
            ("malformed-id", object(id: "not-a-uuid", kind: "Sequel", source: x, target: y, date: dateValue)),
            ("empty-kind", object(id: UUID().uuidString, kind: "", source: x, target: y, date: dateValue)),
            /// An older copy of the valid addition's ID that breaks a rule: it must not take the
            /// ID from the valid copy below.
            ("repeated-id-first-broken", object(id: good.uuidString, kind: "Sequel", source: x, target: x,
                                                date: "2000-01-01T00:00:00Z")),
        ]
        r.check("backup/injected-dates-parse",
                (try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon).parse("2000-01-01T00:00:00Z")) != nil,
                "the older copy really is older, so the case above is not vacuous")
        /// Valid new links the restore must keep, on films no source link touches: one on its
        /// own, and a two-link chain of one kind whose newer closing link (same kind, other
        /// case) is the cycle the restore must drop.
        let allFilms: [UUID] = ((try? container.makeMainContext().fetch(Film.request())) ?? []).map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        let free = allFilms.filter { film in !source.contains { $0.sourceID == film || $0.targetID == film } }
        guard free.count >= 5 else {
            r.check("backup/bad-template", false, "\(free.count) unlinked film(s); the valid cases need 5"); return
        }
        let (freeA, freeB, chainP, chainQ, chainS) = (free[0], free[free.count - 1], free[1], free[2], free[3])
        let chainFirst = UUID(), chainSecond = UUID()
        let valid = object(id: good.uuidString, kind: "Spin-off", source: freeA.uuidString, target: freeB.uuidString, date: dateValue)
            + object(id: chainFirst.uuidString, kind: "Sequel", source: chainP.uuidString, target: chainQ.uuidString, date: dateValue)
            + object(id: chainSecond.uuidString, kind: "Sequel", source: chainQ.uuidString, target: chainS.uuidString, date: dateValue)
        let cycle = ("cycle", object(id: UUID().uuidString, kind: "sequel", source: chainS.uuidString, target: chainP.uuidString,
                                     date: "2099-01-01T00:00:00Z"))
        let dropped = bad + [cycle]
        let injected = (dropped.map(\.1) + [valid]).joined()
        let edited = xml.replacingOccurrences(of: "  </Objects>\n", with: injected + "  </Objects>\n")
        do {
            try edited.write(to: xmlURL, atomically: true, encoding: .utf8)
        } catch {
            r.check("backup/bad-write", false, "\(error)"); return
        }
        let (badError, _) = await restoreBackupPackage(package, container: container)
        guard badError == nil, let restoredURL = harnessRestoredStoreURL else {
            r.check("backup/bad-links-restore", false, "restore refused: \(badError.map { "\($0)" } ?? "no swap")"); return
        }
        do {
            let restored = try LibraryStore.makeContainer(at: restoredURL)
            defer { close(restored) }
            let restoredLinks = try await DataManager(persistentContainer: restored).fetchFilmLinks()
            let date = Date()
            let expected = source + [
                FilmLinkSnapshot(id: good, kind: "Spin-off", sourceID: freeA, targetID: freeB, dateAdded: date),
                FilmLinkSnapshot(id: chainFirst, kind: "Sequel", sourceID: chainP, targetID: chainQ, dateAdded: date),
                FilmLinkSnapshot(id: chainSecond, kind: "Sequel", sourceID: chainQ, targetID: chainS, dateAdded: date),
            ]
            r.check("backup/bad-links-dropped", linkLines(restoredLinks) == linkLines(expected),
                    "\(restoredLinks.count) link(s) restored, expected \(expected.count): the source's plus the three valid additions; "
                        + "dropped: \(dropped.map(\.0).joined(separator: ", "))")
            let report = try StoreInspection.inspect(restored.makeMainContext())
            r.check("backup/bad-links-structure", report.problems.isEmpty, report.problems.joined(separator: "; "))
        } catch {
            r.check("backup/bad-links-open", false, "threw: \(error)")
        }

        // MARK: A backup from before film links
        /// The shape an older build writes: no FilmLink object and no FilmLink manifest entry.
        /// Made from this run's own export (the untouched `xml`), so everything else matches the
        /// probe exactly.
        var stripped = xml.replacingOccurrences(
            of: "(?s)[ \\t]*<Object id=\"FilmLink-[^\"]*\" entity=\"FilmLink\">.*?</Object>\\n", with: "", options: .regularExpression)
        stripped = stripped.replacingOccurrences(
            of: "[ \\t]*<Entity name=\"FilmLink\" count=\"[0-9]+\" />\\n", with: "", options: .regularExpression)
        r.check("old-backup/has-no-links", !stripped.contains("FilmLink") && stripped.count < xml.count,
                "\(xml.count - stripped.count) character(s) of link objects and manifest removed")
        var expected = sourceCounts.filter { $0.key != "FilmLink" }
        expected["FilmLink"] = 0
        if let old = writePackage(named: "pre-film-links", xml: stripped, in: folder) {
            let (oldError, _) = await restoreBackupPackage(old, container: container)
            r.check("old-backup/restores", oldError == nil && restoredStoreInUse, oldError.map { "\($0)" } ?? "restored and swapped in")
            await checkRestoredWithoutLinks(&r, "old-backup", expected: expected)
        } else {
            r.check("old-backup/write", false, "could not write the package")
        }

        // MARK: A real backup from before film links
        /// `-FTFilmLinksOldBackup <package>`: a backup an earlier build wrote. Only its XML is
        /// copied (posters are not this test's subject); every entity must come back at its
        /// manifest's count.
        let arguments = ProcessInfo.processInfo.arguments
        guard let oldPackage = arguments.firstIndex(of: "-FTFilmLinksOldBackup")
                .flatMap({ arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }) else {
            r.skip("real-old-backup/restores", "no -FTFilmLinksOldBackup")
            return
        }
        do {
            let realXML = try String(contentsOf: oldPackage.appendingPathComponent("backup.xml"), encoding: .utf8)
            let parsed = try await DBImporter().parseBackupFile(at: oldPackage.appendingPathComponent("backup.xml"))
            let linkObjects = parsed.objects.filter { $0.entityName == "FilmLink" }.count
            r.check("real-old-backup/predates-links", parsed.manifest["FilmLink"] == nil && linkObjects == 0,
                    "app \(parsed.appVersion ?? "?"), made \(parsed.createdISO8601); manifest: "
                        + parsed.manifest.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            var wanted = parsed.manifest
            wanted["FilmLink"] = 0
            guard let copy = writePackage(named: "real-pre-film-links", xml: realXML, in: folder) else {
                r.check("real-old-backup/write", false, "could not write the package"); return
            }
            let (realError, _) = await restoreBackupPackage(copy, container: container)
            r.check("real-old-backup/restores", realError == nil && restoredStoreInUse,
                    realError.map { "\($0)" } ?? "restored and swapped in")
            await checkRestoredWithoutLinks(&r, "real-old-backup", expected: wanted)
        } catch {
            r.check("real-old-backup/read", false, "threw: \(error)")
        }
    }

    /// A backup package holding only `xml`, in `folder`, or nil when it cannot be written.
    private static func writePackage(named name: String, xml: String, in folder: URL) -> URL? {
        let package = folder.appendingPathComponent("\(name).\(BackupFilename.fileExtension)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try xml.write(to: package.appendingPathComponent("backup.xml"), atomically: true, encoding: .utf8)
            return package
        } catch {
            return nil
        }
    }

    /// After a restore that brought no film links: the swapped-in store holds `expected` rows
    /// per entity (SettingsObject at most its count) and no structural problem, and it takes a
    /// link write that survives a relaunch and the launch cleanup.
    private static func checkRestoredWithoutLinks(_ r: inout HarnessScenarioResult, _ prefix: String,
                                                  expected: [String: Int]) async {
        guard restoredStoreInUse, let url = harnessRestoredStoreURL else {
            r.check("\(prefix)/swapped", false, "no restored store"); return
        }
        do {
            var restored = try LibraryStore.makeContainer(at: url)
            defer { close(restored) }
            let counts = entityCounts(restored)
            let differing = expected.filter { name, want in
                name == SettingsObject.entityName ? !(0...want).contains(counts[name] ?? -1) : counts[name] != want
            }
            r.check("\(prefix)/counts", differing.isEmpty,
                    differing.isEmpty ? expected.sorted { $0.key < $1.key }.map { "\($0.key) \(counts[$0.key] ?? -1)" }.joined(separator: ", ")
                                      : differing.sorted { $0.key < $1.key }.map { "\($0.key) \(counts[$0.key] ?? -1) (want \($0.value))" }.joined(separator: ", "))
            let report = try StoreInspection.inspect(restored.makeMainContext())
            r.check("\(prefix)/no-structural-problems", report.problems.isEmpty, report.problems.joined(separator: "; "))

            let films = try restored.makeMainContext().fetch(Film.request()).map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard films.count >= 2 else {
                r.check("\(prefix)/takes-a-link", false, "\(films.count) film(s)"); return
            }
            let written = try await DataManager(persistentContainer: restored)
                .setFilmLink(source: films[0], target: films[1], kind: FilmLinkKind.remake)
            close(restored)
            restored = try LibraryStore.makeContainer(at: url)
            let dm = DataManager(persistentContainer: restored)
            let cleanup = try await dm.cleanupFilmLinks().counts
            let read = try await dm.fetchFilmLinks()
            r.check("\(prefix)/takes-a-link", linkLines(read, withDates: true) == linkLines([written], withDates: true) && cleanup.isEmpty,
                    "\(read.count) link(s) after a relaunch; the cleanup removed \(cleanup.values.reduce(0, +))")
        } catch {
            r.check("\(prefix)/open", false, "threw: \(error)")
        }
    }

    /// A restore an older build staged and committed, swapped in by this one at launch: its
    /// store has the old schema (no ZFILMLINK table) and its marker a digest from the old model,
    /// which has no FilmLink entry. The swap must migrate it, check it by row counts and keep
    /// every row. Built from the pre-migration copy, converted to the rollback journal an older
    /// build's staged store uses, with the marker that build writes.
    private static func oldStagedRestoreCase(_ r: inout HarnessScenarioResult, premigration: URL?) async {
        guard let premigration else {
            r.skip("old-staged/swaps-in", "no -FTFilmLinksPremigration"); return
        }
        guard let staged = PendingRestore.stagedStoreURL, let markerURL = PendingRestore.markerURL else {
            r.check("old-staged/paths", false, "no store folder"); return
        }
        /// The marker an older build writes; the same fields and encoding as PendingRestore's.
        struct OlderMarker: Codable {
            var stagedAt: Date
            var rollbackSaved: Bool
            var applySettings: Bool?
            var digest: [String: String]?
            var modelHash: String?
            var fileHash: String?
        }
        let tables: [(String, String)] = [
            ("Film", "ZFILM"), ("ListObject", "ZLISTOBJECT"), ("ListMembership", "ZLISTMEMBERSHIP"),
            ("Release", "ZRELEASE"), ("ImportSession", "ZIMPORTSESSION"),
            ("SettingsObject", "ZSETTINGSOBJECT"), ("SavedSearchObject", "ZSAVEDSEARCHOBJECT"),
        ]
        let fm = FileManager.default
        /// Stages the old store with its marker; `miscount` adds to the marker's Film count,
        /// for the control below. Returns the staged rows per entity.
        func stage(miscount: Int) throws -> [String: Int] {
            PendingRestore.discard()
            try fm.copyItem(at: premigration, to: staged)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path(percentEncoded: false))
            let mode = sqlRows(staged, "PRAGMA journal_mode=DELETE", writable: true)?.first?.first ?? "?"
            let named = Set((sqlRows(staged, "SELECT name FROM sqlite_master WHERE type='table'") ?? []).compactMap(\.first))
            var counts: [String: Int] = [:]
            for (name, table) in tables {
                counts[name] = Int(sqlRows(staged, "SELECT COUNT(*) FROM \(table)")?.first?.first ?? "") ?? -1
            }
            if miscount == 0 {
                r.check("old-staged/staged-has-old-schema", mode == "delete" && named.contains("ZFILM") && !named.contains("ZFILMLINK")
                            && counts.values.allSatisfy { $0 >= 0 },
                        "journal \(mode); " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            let handle = try FileHandle(forReadingFrom: staged)
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            try handle.close()
            var claimed = counts
            claimed["Film", default: 0] += miscount
            let marker = OlderMarker(stagedAt: Date(), rollbackSaved: false, applySettings: false,
                                     digest: claimed.mapValues { "\($0):digest-from-the-older-model" },
                                     modelHash: "the-older-model", fileHash: StoreInspection.hex(hasher.finalize()))
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            return counts
        }

        var expected: [String: Int]
        do {
            expected = try stage(miscount: 0)
        } catch {
            r.check("old-staged/stage", false, "threw: \(error)")
            PendingRestore.discard()
            return
        }
        let swapped = applyRestoreAsRelaunchWould()
        r.check("old-staged/swaps-in", swapped, swapped ? "migrated, checked by row counts and swapped in" : "refused (see the log)")
        expected["FilmLink"] = 0
        if swapped { await checkRestoredWithoutLinks(&r, "old-staged", expected: expected) }

        /// Control: the same staging whose marker claims one film more than the store holds
        /// must be refused, so the pass above is the row-count check passing, not skipped.
        do {
            _ = try stage(miscount: 1)
            restoredStoreInUse = false
            let refused = !applyRestoreAsRelaunchWould()
            r.check("old-staged/control-miscount-refused", refused && !restoredStoreInUse,
                    refused ? "a marker claiming one more film is refused" : "was swapped in")
        } catch {
            r.check("old-staged/control-stage", false, "threw: \(error)")
        }
        PendingRestore.discard()
    }
}

#endif
