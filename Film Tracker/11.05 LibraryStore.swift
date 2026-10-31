// MARK: - LibraryStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Core Data stack: the library's managed object model (built in code), the persistent
// container, the context-backed executor that the persistence actors run on, and the fetch
// and predicate helpers the rest of the app uses.

import Foundation
import CoreData
import SQLite3
import CryptoKit

// MARK: - Store Location

enum LibraryStore: Loggable {
    nonisolated static let logTag = "[LibraryStore]"

    /// The store file's name. Deliberately not SwiftData's `default.store`: the Core Data
    /// build starts from an empty store and the library comes back by restoring a backup, so
    /// the store beside it is never opened, migrated or deleted — it stays a
    /// rollback until the user removes it.
    static let storeFileName = "FilmTracker.sqlite"

    /// Where the store lives: the debug sandbox's folder when one is active, otherwise
    /// Application Support (Preferences.dataFolderURL, which the sandbox also redirects).
    static var storeURL: URL? {
        if let sandbox = DebugSandbox.storeURL { return sandbox }
        return Preferences.dataFolderURL?.appendingPathComponent(storeFileName)
    }

    /// Opens a container on the store at `url`, or an in-memory one when `url` is nil.
    /// Every container shares `LibraryModel.shared`, so two of them in one process (the app's
    /// and a restore's) never register the classes twice.
    ///
    /// `singleFile` opens the store with SQLite's rollback journal instead of its WAL, so a
    /// closed store is one file with no -wal/-shm beside it. The staged restore store uses it
    /// (see PendingRestore); the library's own store keeps the default WAL.
    static func makeContainer(at url: URL?, readOnly: Bool = false,
                              singleFile: Bool = false) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "FilmTracker", managedObjectModel: LibraryModel.shared.model)
        let description = url.map { NSPersistentStoreDescription(url: $0) } ?? {
            let d = NSPersistentStoreDescription(); d.type = NSInMemoryStoreType; return d }()
        description.shouldAddStoreAsynchronously = false
        description.isReadOnly = readOnly
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        if singleFile {
            description.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
        }
        container.persistentStoreDescriptions = [description]

        // A fresh container has no Application Support folder yet. Core Data would recover by
        // creating it after a failed open; creating it first keeps that out of the log.
        if let url, !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }

        if let url, !readOnly { StoreDeduplicator.prepareForMigration(url) }

        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        // The view context is what SwiftData's mainContext was: main-queue, merging every
        // background save as it lands, no undo manager.
        let view = container.viewContext
        view.automaticallyMergesChangesFromParent = true
        view.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        view.undoManager = nil
        return container
    }

    /// Erases the store at `url` in place (all three SQLite files), the way Core Data wants
    /// it done: through a coordinator, which also handles a store another coordinator in the
    /// process still has open.
    static func destroyStore(at url: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.shared.model)
        try coordinator.destroyPersistentStore(at: url, type: .sqlite)
    }

    /// Copies the store at `source` over the store at `destination` (creating it if absent),
    /// through Core Data, which carries each side's -wal/-shm with it.
    static func replaceStore(at destination: URL, withStoreAt source: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.shared.model)
        try coordinator.replacePersistentStore(at: destination, withPersistentStoreFrom: source, type: .sqlite)
    }

    /// Opens the store at `url` in a container of its own, runs `body` on a fresh main-queue
    /// context, and closes the store again, so nothing is left holding the file.
    @MainActor
    static func withStore<T>(at url: URL, readOnly: Bool, singleFile: Bool,
                             _ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let container = try makeContainer(at: url, readOnly: readOnly, singleFile: singleFile)
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
        }
        return try body(container.makeMainContext())
    }

    /// The store file at `url` and its SQLite sidecars.
    static func storeFiles(_ url: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path(percentEncoded: false) + $0) }
    }
}

// MARK: - Duplicate IDs Before Migration

/// Removes rows that repeat another row's ID, in a store about to be migrated to a model that
/// constrains IDs to be unique. Core Data refuses that migration outright ("constraint
/// violation during attempted migration"), and the library would not open.
///
/// Looks only at tables that don't yet have the unique index the constraint creates (so a
/// store already migrated costs one read of sqlite_master) and changes nothing unless one of
/// them repeats an ID. Works in SQL on the store's own tables, before Core Data opens it: the
/// old schema's model no longer exists in this build. The first row of each ID (lowest Z_PK) is kept, and every reference to a removed row is
/// moved to the kept one first, so nothing is left pointing at a deleted row. A (film, list)
/// pair this leaves twice is removed by DataManager.cleanupOrphanedAndDuplicateMemberships.
enum StoreDeduplicator: Loggable {
    nonisolated static let logTag = "[StoreDeduplicator]"

    /// Table, ID column, and the (table, column) pairs that reference its rows.
    private static let keys: [(table: String, column: String, references: [(String, String)])] = [
        ("ZFILM", "ZID", [("ZRELEASE", "ZFILM"), ("ZLISTMEMBERSHIP", "ZFILM")]),
        ("ZLISTOBJECT", "ZLISTID", [("ZLISTMEMBERSHIP", "ZLIST")]),
        ("ZRELEASE", "ZID", [("ZRELEASE", "ZPARENTRELEASE")]),
        ("ZLISTMEMBERSHIP", "ZID", []),
        ("ZIMPORTSESSION", "ZID", []),
        ("ZSAVEDSEARCHOBJECT", "ZSEARCHID", []),
        ("ZSETTINGSOBJECT", "ZSNAPSHOTID", []),
    ]

    static func prepareForMigration(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }

        // Read-only, and not through Core Data, until a repeat is found. The harness erases a
        // store in place while another connection still has it open, and a connection that
        // can write (Core Data's metadata read is one) checkpoints that connection's stale WAL
        // back into the erased file when it closes, leaving it without its tables. A store
        // that needs the repair is one nothing has open yet (the launch, before the
        // container), where the repair's own checkpoint is harmless.
        var db: OpaquePointer?
        defer { unsafe sqlite3_close(db) }
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            log("WARNING: could not open the store to check for repeated IDs before migration")
            return
        }

        func count(_ sql: String) -> Int {
            var statement: OpaquePointer?
            defer { unsafe sqlite3_finalize(statement) }
            guard unsafe sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  unsafe sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(unsafe sqlite3_column_int64(statement, 0))
        }
        func exec(_ sql: String) -> Bool { unsafe sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
        func tableExists(_ table: String) -> Bool {
            count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") > 0
        }

        // A later row of a repeated ID: `t` is the table, aliased so the subquery can name it.
        func laterRows(_ table: String, _ column: String) -> String {
            "SELECT t.Z_PK FROM \(table) t WHERE t.\(column) IS NOT NULL AND t.Z_PK > "
                + "(SELECT MIN(k.Z_PK) FROM \(table) k WHERE k.\(column) = t.\(column))"
        }

        func uniqueIndexExists(_ table: String, _ column: String) -> Bool {
            count("""
                SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = '\(table)'
                AND sql LIKE 'CREATE UNIQUE INDEX %(\(column) %'
                """) > 0
        }

        let present = keys.filter { tableExists($0.table) && !uniqueIndexExists($0.table, $0.column) }
        let repeated = present.map { ($0, count("SELECT COUNT(*) FROM (\(laterRows($0.table, $0.column)))")) }
            .filter { $0.1 > 0 }
        guard !repeated.isEmpty else { return }

        unsafe sqlite3_close(db)
        unsafe db = nil
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            log("WARNING: could not open the store to remove repeated IDs; the migration may fail")
            return
        }
        unsafe sqlite3_busy_timeout(db, 5_000)
        guard exec("BEGIN IMMEDIATE") else {
            log("WARNING: could not lock the store to remove repeated IDs; the migration may fail")
            return
        }
        for (key, rows) in repeated {
            for (refTable, refColumn) in key.references where tableExists(refTable) {
                // Point each reference to a later row at the first row with the same ID.
                guard exec("""
                    UPDATE \(refTable) SET \(refColumn) = (
                        SELECT MIN(k.Z_PK) FROM \(key.table) k
                        WHERE k.\(key.column) = (SELECT d.\(key.column) FROM \(key.table) d WHERE d.Z_PK = \(refTable).\(refColumn)))
                    WHERE \(refColumn) IN (\(laterRows(key.table, key.column)))
                    """) else {
                    _ = exec("ROLLBACK")
                    log("WARNING: could not repoint \(refTable).\(refColumn); repeated IDs left in place")
                    return
                }
            }
            guard exec("DELETE FROM \(key.table) WHERE Z_PK IN (\(laterRows(key.table, key.column)))") else {
                _ = exec("ROLLBACK")
                log("WARNING: could not remove repeated IDs from \(key.table); left in place")
                return
            }
            log("Removed \(rows) row(s) of \(key.table) repeating another row's \(key.column) before migration")
        }
        if !exec("COMMIT") {
            _ = exec("ROLLBACK")
            log("WARNING: could not commit the repeated-ID repair; left in place")
        }
    }
}

// MARK: - Staged Restore

/// A restore never writes into the library's store while the app has it open. It builds the
/// restored library in a separate store beside it (`stagedStoreURL`), proves it, and leaves
/// a marker; the next launch swaps it in before anything opens the store
/// (`applyIfPending`, called from FilmTrackerApp.createModelContainer).
///
/// So nothing in the running session can reach the restored store: a late write from it
/// lands in the old store, which the swap sets aside as `rollbackStoreURL`. A restore that
/// fails before `commit` leaves the library exactly as it was.
///
/// What is proven, and when:
/// - `commit`: the staged store is closed, passes SQLite's integrity check, and is opened
///   again by a fresh container, whose contents must match what the restore built row for
///   row (`StoreInspection`), with no dangling relationship. The marker records that
///   digest and a hash of the closed file.
/// - Launch, before the swap: the file still hashes to what `commit` proved, so nothing
///   touched it since. Only then is the library replaced.
/// - Launch, after the swap: the store is opened the way the app is about to open it and
///   must hold that same digest. If it does not, the previous library is put back.
///
/// The swap is safe to interrupt and repeat: the marker records whether the rollback copy is
/// already taken (written before any file is moved), the staged store is copied (not moved)
/// into place, and only once that has succeeded and been checked is the marker removed,
/// then the staged files.
enum PendingRestore: Loggable {
    nonisolated static let logTag = "[PendingRestore]"

    /// The library's store, as LibraryStore resolves it.
    private static var liveStoreURL: URL? { LibraryStore.storeURL }
    private static var folderURL: URL? { liveStoreURL?.deletingLastPathComponent() }

    /// Where a restore builds the replacement library.
    static var stagedStoreURL: URL? { folderURL?.appendingPathComponent("FilmTracker-restore.sqlite") }
    /// Where the swap keeps the library it replaced: the most recent one only.
    static var rollbackStoreURL: URL? { folderURL?.appendingPathComponent("FilmTracker-pre-restore.sqlite") }
    private static var markerURL: URL? { folderURL?.appendingPathComponent("FilmTracker.pending-restore") }
    /// Where a restore stages the backup's posters. They move into the posters folder only
    /// once the swap has succeeded (see `applyRestoredExtras`).
    static var stagedPostersURL: URL? { folderURL?.appendingPathComponent("FilmTracker-restore-Posters", isDirectory: true) }

    private struct Marker: Codable {
        var stagedAt: Date
        /// True once the old store is set aside at the rollback location, so a repeated swap
        /// never overwrites that copy with the restored library.
        var rollbackSaved: Bool
        /// True when the old store could not be copied and its files were moved instead, so
        /// a failed swap knows the rollback files are this library's and puts them back.
        /// Written before the move starts, so an interrupted move knows it too.
        /// Optional so a marker written before it existed still decodes.
        var rollbackMoved: Bool?
        /// True when the swapped-in library's settings row should be applied to
        /// Preferences after the swap. Optional so an older marker still decodes.
        var applySettings: Bool?
        /// Whether a library existed when the swap set it aside: false means a failed swap
        /// leaves no store at all, rather than an older restore's rollback. Nil until the
        /// rollback is saved, and in a marker written before it existed.
        var previousExisted: Bool?
        /// What `commit` proved the staged store holds (StoreInspection), the model it was
        /// measured against, and the closed file's SHA-256. Nil in an older marker.
        var digest: [String: String]?
        var modelHash: String?
        var fileHash: String?
    }

    enum Failure: Error, LocalizedError {
        case noStoreLocation
        case verificationFailed(String)
        var errorDescription: String? {
            switch self {
            case .noStoreLocation: "Could not resolve the library folder."
            case .verificationFailed(let detail): "The restored library failed its check: \(detail)"
            }
        }
    }

    // MARK: Restore Side

    /// A fresh, empty store at the staging location, discarding anything a previous attempt
    /// left there. Single-file, so `commit` can verify it with nothing in a WAL.
    static func makeStagingContainer() throws -> NSPersistentContainer {
        guard let staged = stagedStoreURL else { throw Failure.noStoreLocation }
        discard()
        return try LibraryStore.makeContainer(at: staged, singleFile: true)
    }

    /// Proves the staged store, then writes the marker that has the next launch swap it in.
    /// From here on the restore is committed: the session must relaunch.
    ///
    /// `context`: the context that filled the store, saved; its objects are what the store
    /// must hold. Nil for a store left empty (the container's view context is used).
    /// `applySettings`: whether the launch applies the restored settings row to Preferences
    /// once the swap succeeds.
    @MainActor
    static func commit(_ container: NSPersistentContainer, filledBy context: NSManagedObjectContext? = nil,
                       applySettings: Bool = false) throws {
        guard let staged = stagedStoreURL, let marker = markerURL else { throw Failure.noStoreLocation }

        // What was built, read from the context that built it, while the store is open.
        let expected = try StoreInspection.inspect(context ?? container.viewContext)
        guard expected.problems.isEmpty else {
            throw Failure.verificationFailed(expected.problems.joined(separator: "; "))
        }

        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }

        let result = integrityCheck(staged)
        guard result == "ok" else { throw Failure.verificationFailed(result) }

        // What landed, read back through a container that has never seen the objects.
        let found = try LibraryStore.withStore(at: staged, readOnly: true, singleFile: true) {
            try StoreInspection.inspect($0)
        }
        if let mismatch = StoreInspection.mismatch(expected: expected.digest, found: found, countsOnly: false) {
            throw Failure.verificationFailed(mismatch)
        }

        let data = try JSONEncoder().encode(Marker(stagedAt: Date(), rollbackSaved: false,
                                                    applySettings: applySettings,
                                                    digest: expected.digest,
                                                    modelHash: StoreInspection.modelHash,
                                                    fileHash: try fileHash(staged)))
        try data.write(to: marker, options: .atomic)
        log("Staged restore verified (\(StoreInspection.summary(expected.digest))) and committed; it is swapped in at the next launch")
    }

    /// Deletes the marker, the staged store and the staged posters: a restore that failed
    /// before committing, leftovers from one that never will, or one the launch finished.
    /// The marker goes first, so an interruption can only leave unreferenced files (which
    /// the next restore clears), never a marker that points at nothing.
    static func discard() {
        let fm = FileManager.default
        if let marker = markerURL { try? fm.removeItem(at: marker) }
        if let staged = stagedStoreURL {
            for file in LibraryStore.storeFiles(staged) where fm.fileExists(atPath: file.path(percentEncoded: false)) {
                try? fm.removeItem(at: file)
            }
        }
        if let posters = stagedPostersURL { try? fm.removeItem(at: posters) }
    }

    /// Whether a committed restore is waiting for the next launch.
    static var isPending: Bool {
        guard let marker = markerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    // MARK: Launch Side

    enum Outcome: Equatable {
        case nothingPending
        case swapped
        /// The swap failed and the previous library was kept; the message says why.
        case failed(String)
    }

    /// Swaps a committed restore into place. Called once at launch, before any container
    /// opens the library's store, so no connection can be holding either file.
    ///
    /// `target` replaces the library's store as the destination. DEBUG harness only: it
    /// swaps into a store no connection has open, since the running app has the real one
    /// open and the launch never does.
    @MainActor
    @discardableResult
    static func applyIfPending(into target: URL? = nil) -> Outcome {
        guard let markerURL, let live = target ?? liveStoreURL, let staged = stagedStoreURL,
              let rollback = rollbackStoreURL,
              let data = try? Data(contentsOf: markerURL) else { return .nothingPending }
        let fm = FileManager.default

        guard var marker = try? JSONDecoder().decode(Marker.self, from: data) else {
            log("WARNING: Unreadable pending-restore marker — discarding the staged restore")
            discard()
            return .failed("The restore's record could not be read.")
        }
        guard fm.fileExists(atPath: staged.path(percentEncoded: false)) else {
            // discard() removes the marker before the staged store, so a marker without one
            // was not left by a finished swap: nothing proves this restore was applied.
            log("ERROR: The marker names a staged store that is missing — keeping the current library")
            discard()
            return .failed("The restored library could not be found.")
        }
        // Checked again here, not only at commit: replacePersistentStore copies whatever file
        // it is given, so a staged store damaged since (disk error, a file touched by hand)
        // would otherwise replace a healthy library with one that cannot open.
        let check = integrityCheck(staged)
        guard check == "ok" else {
            log("ERROR: The staged store failed its check at launch (\(check)) — keeping the current library")
            discard()
            return .failed(Failure.verificationFailed(check).localizedDescription)
        }
        if let expectedHash = marker.fileHash {
            guard let hash = try? fileHash(staged), hash == expectedHash else {
                log("ERROR: The staged store changed after it was verified — keeping the current library")
                discard()
                return .failed(Failure.verificationFailed("the file changed after it was saved").localizedDescription)
            }
        }

        var settings: SettingsSnapshot?
        do {
            if !marker.rollbackSaved {
                // Each step is recorded only once the marker carrying it is written, so the
                // marker never claims more than happened.
                var next = marker
                next.previousExisted = fm.fileExists(atPath: live.path(percentEncoded: false))
                next.rollbackSaved = true
                if next.previousExisted == true, !copyRollback(of: live, to: rollback) {
                    // Recorded before the move, so an interrupted move still knows the
                    // rollback files are this library's.
                    next.rollbackMoved = true
                    try write(next, to: markerURL)
                    marker = next
                    try moveStoreFiles(from: live, to: rollback)
                } else {
                    try write(next, to: markerURL)
                    marker = next
                }
            }
            try LibraryStore.replaceStore(at: live, withStoreAt: staged)
            settings = try verifySwapped(live, against: marker)
        } catch {
            log("ERROR: Could not swap in the restored library: \(error)")
            putBackPrevious(live: live, rollback: rollback, marker: marker)
            discard()
            return .failed(error.localizedDescription)
        }

        applyRestoredExtras(settings: settings)
        discard()
        log("Restored library swapped in and verified (staged \(marker.stagedAt))")
        return .swapped
    }

    /// Opens the swapped-in store the way the app is about to, and checks it holds what
    /// `commit` proved the staged store held. Returns the restored settings row when the
    /// marker asks for it, read in the same pass so a store that cannot yield them fails
    /// here, while the previous library can still be put back.
    ///
    /// When the model changed between the commit and this launch (an update installed in
    /// between), the store has just been migrated and the attribute digest no longer
    /// applies; the row counts still must match.
    @MainActor
    private static func verifySwapped(_ live: URL, against marker: Marker) throws -> SettingsSnapshot? {
        try LibraryStore.withStore(at: live, readOnly: false, singleFile: false) { context in
            let found = try StoreInspection.inspect(context)
            if let expected = marker.digest {
                let countsOnly = marker.modelHash != StoreInspection.modelHash
                if countsOnly { log("NOTE: The model changed since the restore was staged; checking row counts only") }
                if let mismatch = StoreInspection.mismatch(expected: expected, found: found, countsOnly: countsOnly) {
                    throw Failure.verificationFailed(mismatch)
                }
            } else if !found.problems.isEmpty {
                throw Failure.verificationFailed(found.problems.joined(separator: "; "))
            }
            guard marker.applySettings == true else { return nil }
            let request = SettingsObject.request(.equals("snapshotID", SettingsObject.singletonID))
            guard let row = try context.fetch(request).first else {
                log("NOTE: The restored library carries no settings — current settings kept")
                return nil
            }
            return SettingsSnapshot(from: row)
        }
    }

    /// After a failed swap, puts the library the swap set aside back where it was. Does
    /// nothing unless the marker shows the rollback files are this swap's: files from an
    /// earlier restore describe an older library.
    private static func putBackPrevious(live: URL, rollback: URL, marker: Marker) {
        let fm = FileManager.default
        func removeLive() {
            for file in LibraryStore.storeFiles(live) where fm.fileExists(atPath: file.path(percentEncoded: false)) {
                try? fm.removeItem(at: file)
            }
        }
        guard marker.rollbackSaved else { return }
        if marker.rollbackMoved == true {
            guard fm.fileExists(atPath: rollback.path(percentEncoded: false)) else {
                log("ERROR: The previous library's files are missing from \(rollback.lastPathComponent)")
                return
            }
            // Whatever the failed swap left at the live location goes; the moved files
            // are the library.
            removeLive()
            do {
                try moveStoreFiles(from: rollback, to: live)
                log("Previous library moved back into place")
            } catch {
                log("ERROR: Could not move the previous library back: \(error.localizedDescription) — it is kept at \(rollback.lastPathComponent)")
            }
        } else if marker.previousExisted == true {
            do {
                try LibraryStore.replaceStore(at: live, withStoreAt: rollback)
                log("Previous library copied back into place")
            } catch {
                log("ERROR: Could not copy the previous library back: \(error.localizedDescription) — it is kept at \(rollback.lastPathComponent)")
            }
        } else if marker.previousExisted == false {
            // There was no library before the swap; leave none rather than a bad one.
            removeLive()
        }
    }

    /// What a restore changes outside the store, done only once the swap has succeeded and
    /// been verified, so a swap that fails leaves the previous library exactly as it was,
    /// settings and posters included. Repeatable: an interrupted launch swaps and applies
    /// again.
    ///
    /// - The backup's posters move from `stagedPostersURL` into the posters folder.
    /// - The restored settings row, when the marker asked for it (`settings`), is applied
    ///   to Preferences; the launch's settings sync then writes them back into the store
    ///   unchanged.
    /// - The Up for Rotation baseline is cleared: it names the replaced library's films, and
    ///   measured against the restored one it would enqueue a flood of false newcomers.
    ///   Cleared even for a settings-less backup, which still replaces every film.
    @MainActor
    private static func applyRestoredExtras(settings: SettingsSnapshot?) {
        let fm = FileManager.default

        if let staged = stagedPostersURL, let destination = Preferences.posterImagesFolderURL,
           let files = try? fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) {
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            var moved = 0
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: target)
                do {
                    try fm.moveItem(at: file, to: target)
                    moved += 1
                } catch {
                    log("WARNING: Could not move restored poster \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            log("Restored posters moved into place: \(moved) of \(files.count)")
        }

        if let settings {
            SettingsManager.applySnapshotToPreferences(settings)
            log("Restored settings applied to Preferences")
        }

        Preferences.resetKnownUpForRotationFilmIDs()
    }

    /// Copies the store about to be replaced to the rollback location. Returns false when
    /// Core Data cannot copy it (a store it cannot read, such as the one a "Create New
    /// Library" replaces); the caller then moves the files instead.
    private static func copyRollback(of live: URL, to rollback: URL) -> Bool {
        let fm = FileManager.default
        for file in LibraryStore.storeFiles(rollback) { try? fm.removeItem(at: file) }
        do {
            try LibraryStore.replaceStore(at: rollback, withStoreAt: live)
            log("Previous library kept at \(rollback.lastPathComponent)")
            return true
        } catch {
            log("WARNING: Could not copy the previous library (\(error.localizedDescription)) — moving its files instead")
            // A copy that failed partway can leave files the move would collide with.
            for file in LibraryStore.storeFiles(rollback) { try? fm.removeItem(at: file) }
            return false
        }
    }

    /// Moves a store's file and sidecars, replacing any at the destination. All or none: a
    /// move that fails puts back the ones already moved, then throws. Nothing has either
    /// file open at launch, so moving is safe.
    private static func moveStoreFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var moved: [(from: URL, to: URL)] = []
        for (from, to) in zip(LibraryStore.storeFiles(source), LibraryStore.storeFiles(destination))
        where fm.fileExists(atPath: from.path(percentEncoded: false)) {
            do {
                if fm.fileExists(atPath: to.path(percentEncoded: false)) { try fm.removeItem(at: to) }
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            } catch {
                for file in moved.reversed() { try? fm.moveItem(at: file.to, to: file.from) }
                throw error
            }
        }
    }

    private static func write(_ marker: Marker, to url: URL) throws {
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
    }

    /// The SHA-256 of a closed store file, read in chunks.
    private static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return StoreInspection.hex(hasher.finalize())
    }

    /// SQLite's `PRAGMA integrity_check` on a closed store file: "ok", or what it found.
    private static func integrityCheck(_ url: URL) -> String {
        var db: OpaquePointer?
        defer { unsafe sqlite3_close(db) }
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return "could not open the staged store"
        }
        var statement: OpaquePointer?
        defer { unsafe sqlite3_finalize(statement) }
        guard unsafe sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              unsafe sqlite3_step(statement) == SQLITE_ROW,
              let text = unsafe sqlite3_column_text(statement, 0) else { return "the check did not run" }
        return unsafe String(cString: text)
    }
}

// MARK: - Store Inspection

/// A digest of everything a store holds, independent of how it was written: per entity, the
/// row count and a SHA-256 over every row's attributes and to-one relationships (named by
/// the target's ID, not its row number), sorted so order does not matter. Two stores with
/// equal digests hold the same library. To-many relationships are the inverses of the
/// to-one sides, so they are covered without being read.
///
/// Also reports structural problems no valid library has: a membership without its film
/// or list, a release without its film, and a release hierarchy that crosses films or runs
/// deeper than one level.
enum StoreInspection {
    struct Report {
        var digest: [String: String]
        var problems: [String]
    }

    /// The model the digests are measured against: a digest from another model (an update
    /// installed between commit and launch) is compared by row counts only.
    static let modelHash: String = {
        var hasher = SHA256()
        for (name, hash) in LibraryModel.shared.model.entityVersionHashesByName.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: hash)
        }
        return StoreInspection.hex(hasher.finalize())
    }()

    /// A digest as lowercase hex. Built with `String(_:radix:)`, not `String(format:)`,
    /// whose C variadic arguments strict memory safety flags as unsafe.
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { byte in
            let text = String(byte, radix: 16)
            return byte < 0x10 ? "0" + text : text
        }.joined()
    }

    /// Reads every row through `context` (a main-queue context, on the main actor). Faults
    /// nothing: relationships are read as object IDs.
    @MainActor
    static func inspect(_ context: NSManagedObjectContext) throws -> Report {
        let entities = LibraryModel.shared.model.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }
        var rows: [String: [NSManagedObject]] = [:]
        var identity: [NSManagedObjectID: String] = [:]
        for entity in entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.returnsObjectsAsFaults = false
            request.includesSubentities = false
            let objects = try context.fetch(request)
            rows[name] = objects
            let key = identityKey(of: entity)
            for object in objects {
                identity[object.objectID] = key.map { normalized(object.value(forKey: $0), entity.attributesByName[$0]) } ?? "?"
            }
        }

        var report = Report(digest: [:], problems: [])
        for entity in entities {
            guard let name = entity.name, let objects = rows[name] else { continue }
            let attributes = entity.attributesByName.sorted { $0.key < $1.key }
            let toOne = entity.relationshipsByName.keys.filter { !entity.relationshipsByName[$0]!.isToMany }.sorted()
            var lines: [String] = []
            lines.reserveCapacity(objects.count)
            for object in objects {
                var line = ""
                func field(_ key: String, _ value: String) { line += "\(key)=\(value.utf8.count):\(value)|" }
                for (key, attribute) in attributes { field(key, normalized(object.value(forKey: key), attribute)) }
                for key in toOne {
                    let target = object.objectIDs(forRelationshipNamed: key).first
                    field(key, target.map { identity[$0] ?? "?" } ?? "-")
                }
                lines.append(line)
            }
            lines.sort()
            var hasher = SHA256()
            for line in lines { hasher.update(data: Data(line.utf8)); hasher.update(data: Data([0x0A])) }
            report.digest[name] = "\(objects.count):" + StoreInspection.hex(hasher.finalize())
        }

        report.problems = structuralProblems(rows)
        return report
    }

    /// Nil when `found` holds what `expected` describes; otherwise what differs. With
    /// `countsOnly`, only each entity's row count is compared.
    static func mismatch(expected: [String: String], found: Report, countsOnly: Bool) -> String? {
        if !found.problems.isEmpty { return found.problems.joined(separator: "; ") }
        func count(_ entry: String?) -> String { entry?.split(separator: ":").first.map(String.init) ?? "0" }
        var differences: [String] = []
        for name in Set(expected.keys).union(found.digest.keys).sorted() {
            let want = expected[name], got = found.digest[name]
            if count(want) != count(got) {
                differences.append("\(name): \(count(got)) of \(count(want)) row(s)")
            } else if !countsOnly, want != got {
                differences.append("\(name): row contents differ")
            }
        }
        return differences.isEmpty ? nil : differences.joined(separator: "; ")
    }

    /// "Film 1200, Release 3400, …" for the log.
    static func summary(_ digest: [String: String]) -> String {
        digest.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.split(separator: ":").first ?? "0")" }
            .joined(separator: ", ")
    }

    private static func structuralProblems(_ rows: [String: [NSManagedObject]]) -> [String] {
        var problems: [String] = []
        let memberships = rows["ListMembership"] ?? []
        let orphanMemberships = memberships.filter {
            $0.objectIDs(forRelationshipNamed: "film").isEmpty || $0.objectIDs(forRelationshipNamed: "list").isEmpty
        }.count
        if orphanMemberships > 0 { problems.append("\(orphanMemberships) list membership(s) without their film or list") }

        let releases = rows["Release"] ?? []
        var filmOf: [NSManagedObjectID: NSManagedObjectID] = [:]
        var parentOf: [NSManagedObjectID: NSManagedObjectID] = [:]
        for release in releases {
            if let film = release.objectIDs(forRelationshipNamed: "film").first { filmOf[release.objectID] = film }
            if let parent = release.objectIDs(forRelationshipNamed: "parentRelease").first { parentOf[release.objectID] = parent }
        }
        let filmless = releases.count - filmOf.count
        if filmless > 0 { problems.append("\(filmless) release(s) without their film") }
        let badLinks = parentOf.filter { child, parent in
            child == parent || parentOf[parent] != nil || filmOf[child] == nil || filmOf[child] != filmOf[parent]
        }.count
        if badLinks > 0 { problems.append("\(badLinks) release link(s) across films or deeper than one level") }
        return problems
    }

    private static func identityKey(of entity: NSEntityDescription) -> String? {
        switch entity.uniquenessConstraints.first?.first {
        case let name as String: name
        case let attribute as NSAttributeDescription: attribute.name
        default: nil
        }
    }

    /// One attribute's value as text that is equal exactly when the stored values are.
    private static func normalized(_ value: Any?, _ attribute: NSAttributeDescription?) -> String {
        guard let value, !(value is NSNull) else { return "-" }
        switch attribute?.attributeType {
        case .stringAttributeType?: return value as? String ?? "\(value)"
        case .integer16AttributeType?, .integer32AttributeType?, .integer64AttributeType?:
            return (value as? NSNumber).map { String($0.int64Value) } ?? "\(value)"
        case .booleanAttributeType?: return (value as? NSNumber).map { $0.boolValue ? "1" : "0" } ?? "\(value)"
        case .doubleAttributeType?, .floatAttributeType?:
            return (value as? NSNumber).map { String($0.doubleValue.bitPattern, radix: 16) } ?? "\(value)"
        case .dateAttributeType?:
            return (value as? Date).map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16) } ?? "\(value)"
        case .UUIDAttributeType?: return (value as? UUID)?.uuidString ?? "\(value)"
        case .transformableAttributeType?:
            guard let array = value as? [Any] else { return "\(value)" }
            return array.map { "\("\($0)".utf8.count):\($0)" }.joined(separator: ",")
        default: return "\(value)"
        }
    }
}

extension NSPersistentContainer {
    /// The SQLite file behind this container, or nil for an in-memory one.
    var storeURL: URL? {
        guard let store = persistentStoreCoordinator.persistentStores.first,
              store.type == NSSQLiteStoreType else { return nil }
        return store.url
    }

    /// A new, empty main-queue context: for a MainActor read that must see the store as it
    /// is now rather than what the view context has registered (a manual export). Merges
    /// like every other context, which SettingsObject's uniqueness constraint needs.
    func makeMainContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }

    /// A new private-queue context on this container, configured for the persistence actors.
    func makeBackgroundContext() -> NSManagedObjectContext {
        let context = newBackgroundContext()
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }
}

// MARK: - Context Executor

/// Runs an actor's jobs on its managed object context's private queue — what SwiftData's
/// `DefaultSerialModelExecutor` did for `@ModelActor`. Because every job runs inside
/// `perform`, the actor's methods use its context directly, with no `perform` of their own,
/// and the queue confinement Core Data requires holds by construction.
final class ContextExecutor: SerialExecutor, @unchecked Sendable {
    /// @unchecked Sendable: `context` is a let, and it is only ever touched on its own
    /// queue — by the jobs this executor runs there.
    let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) { self.context = context }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = unsafe asUnownedSerialExecutor()
        context.perform { unsafe job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { unsafe UnownedSerialExecutor(ordinary: self) }
}

// MARK: - Model Base Class

/// The base of every library entity: entity lookup by class name and typed fetch requests.
class LibraryObject: NSManagedObject {
    /// The entity this class is mapped to; the model names each entity after its class.
    class var entityName: String { String(describing: self) }

    /// A new object of this class, not yet in any context. `context.insert(_:)` adds it,
    /// exactly as SwiftData's model inits worked. Every model init starts here.
    ///
    /// Labeled, never a bare `init()`: Swift resolves `Film()` to the zero-argument init with
    /// the fewest defaulted parameters, so a bare one here would win over a model's
    /// all-defaults init and skip its defaults. A model whose init is all defaults declares
    /// its own `init()` forwarding to it, which also hides NSObject's.
    convenience init(detached: Void) {
        self.init(entity: LibraryModel.shared.entity(Self.entityName), insertInto: nil)
    }

    /// A required UUID attribute (every entity's ID). The model marks UUIDs optional, so a
    /// row can hold none — a damaged store, or one a failed write left behind. An
    /// `@NSManaged` UUID would trap reading it; this reads it as a UUID derived from the
    /// row's object ID instead, stable for that row, and logs it.
    final func requiredUUID(_ key: String) -> UUID {
        if let id = value(forKey: key) as? UUID { return id }
        let digest = Insecure.MD5.hash(data: Data((objectID.uriRepresentation().absoluteString + key).utf8))
        let id = unsafe digest.withUnsafeBytes { unsafe UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        LibraryStore.log("WARNING: \(entity.name ?? "?").\(key) is empty — reading it as \(id)", level: .warning)
        return id
    }

    // Optional scalars, stored as NSNumber/NSString, read and written as Swift optionals.
    final func optionalInt(_ key: String) -> Int? { (value(forKey: key) as? NSNumber)?.intValue }
    final func setOptionalInt(_ value: Int?, _ key: String) { setValue(value.map { NSNumber(value: $0) }, forKey: key) }
    final func optionalBool(_ key: String) -> Bool? { (value(forKey: key) as? NSNumber)?.boolValue }
    final func setOptionalBool(_ value: Bool?, _ key: String) { setValue(value.map { NSNumber(value: $0) }, forKey: key) }
}

/// Typed fetch requests for every LibraryObject subclass. A protocol, because only a
/// protocol extension can return `NSFetchRequest<Self>` for a class hierarchy.
protocol LibraryEntity: LibraryObject {}
extension LibraryObject: LibraryEntity {}

extension LibraryEntity {
    /// `NSFetchRequest` for this class: SwiftData's `FetchDescriptor`.
    static func request(_ predicate: NSPredicate? = nil, sortedBy sort: [NSSortDescriptor] = [],
                        limit: Int = 0) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        request.sortDescriptors = sort.isEmpty ? nil : sort
        request.fetchLimit = limit
        return request
    }
}

extension NSPredicate {
    /// `key == value`
    static func equals(_ key: String, _ value: UUID) -> NSPredicate {
        NSPredicate(format: "%K == %@", key, value as NSUUID)
    }

    /// `key == value`
    static func equals(_ key: String, _ value: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", key, value)
    }

    /// `key IN values`
    static func `in`<S: Sequence>(_ key: String, _ values: S) -> NSPredicate where S.Element == UUID {
        NSPredicate(format: "%K IN %@", key, values.map { $0 as NSUUID } as NSArray)
    }
}

extension NSManagedObjectContext {
    /// Saves, discarding every staged change if the save fails — see DataManager.commit().
    func commit() throws {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}

// MARK: - Managed Object Model

/// The library's one `NSManagedObjectModel`, built in code from the tables below.
///
/// @unchecked Sendable: the model is immutable once built, and Core Data reads a model in
/// use from any thread.
final class LibraryModel: @unchecked Sendable {
    static let shared = LibraryModel()

    let model: NSManagedObjectModel

    func entity(_ name: String) -> NSEntityDescription {
        guard let entity = model.entitiesByName[name] else { fatalError("No entity named \(name)") }
        return entity
    }

    enum Kind {
        case string, int, bool, double, date, uuid
        /// `[String]`, archived as an NSArray of NSString.
        case strings
        case optionalInt, optionalBool, optionalString
    }
    typealias Attribute = (name: String, kind: Kind)

    private init() {
        // `unique`: the entity's identifier, as a uniqueness constraint. The store backs it
        // with a unique index, so it is also the index every lookup by ID uses, and a second
        // row with the same ID can never be written. A context that inserts one anyway
        // resolves the conflict with mergeByPropertyObjectTrump: the insert updates the
        // existing row's attributes, and the row's relationships are kept.
        func entity(_ name: String, _ attributes: [Attribute], unique key: String) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = name
            entity.properties = attributes.map(Self.attribute)
            entity.uniquenessConstraints = [[key]]
            return entity
        }

        let film = entity("Film", Self.filmAttributes, unique: "id")
        let list = entity("ListObject", Self.listObjectAttributes, unique: "listID")
        let membership = entity("ListMembership", Self.listMembershipAttributes, unique: "id")
        let release = entity("Release", Self.releaseAttributes, unique: "id")
        let session = entity("ImportSession", Self.importSessionAttributes, unique: "id")
        // The SwiftData model's @Attribute(.unique): one settings row. Contexts that may
        // insert a second (the restore's) resolve it with mergeByPropertyObjectTrump.
        let settings = entity("SettingsObject", Self.settingsObjectAttributes, unique: "snapshotID")
        let search = entity("SavedSearchObject", Self.savedSearchObjectAttributes, unique: "searchID")

        // Relationships, with SwiftData's delete rules. Every to-many side is optional, as
        // Core Data expects (and as its batch delete requires).
        Self.relate(film, "memberships", toMany: true, .cascadeDeleteRule,
                    membership, "film", toMany: false, .nullifyDeleteRule)
        Self.relate(film, "releases", toMany: true, .cascadeDeleteRule,
                    release, "film", toMany: false, .nullifyDeleteRule)
        Self.relate(list, "memberships", toMany: true, .cascadeDeleteRule,
                    membership, "list", toMany: false, .nullifyDeleteRule)
        Self.relate(release, "parentRelease", toMany: false, .nullifyDeleteRule,
                    release, "childReleases", toMany: true, .nullifyDeleteRule)

        let model = NSManagedObjectModel()
        model.entities = [film, list, membership, release, session, settings, search]
        self.model = model
    }

    private static func attribute(_ spec: Attribute) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = spec.name
        // Required unless the Swift property is optional. A UUID has no meaningful default,
        // so it is optional in the model; every init assigns one.
        a.isOptional = false
        switch spec.kind {
        case .string: a.attributeType = .stringAttributeType; a.defaultValue = ""
        case .int: a.attributeType = .integer64AttributeType; a.defaultValue = 0
        case .bool: a.attributeType = .booleanAttributeType; a.defaultValue = false
        case .double: a.attributeType = .doubleAttributeType; a.defaultValue = 0.0
        case .date: a.attributeType = .dateAttributeType; a.defaultValue = Date(timeIntervalSinceReferenceDate: 0)
        case .uuid: a.attributeType = .UUIDAttributeType; a.isOptional = true
        case .strings:
            a.attributeType = .transformableAttributeType
            a.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
            a.attributeValueClassName = NSStringFromClass(NSArray.self)
            a.defaultValue = NSArray()
        case .optionalInt: a.attributeType = .integer64AttributeType; a.isOptional = true
        case .optionalBool: a.attributeType = .booleanAttributeType; a.isOptional = true
        case .optionalString: a.attributeType = .stringAttributeType; a.isOptional = true
        }
        return a
    }

    private static func relate(_ a: NSEntityDescription, _ aName: String, toMany aMany: Bool, _ aRule: NSDeleteRule,
                               _ b: NSEntityDescription, _ bName: String, toMany bMany: Bool, _ bRule: NSDeleteRule) {
        func side(_ name: String, _ destination: NSEntityDescription, _ many: Bool, _ rule: NSDeleteRule) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name
            unsafe r.destinationEntity = destination
            r.minCount = 0
            r.maxCount = many ? 0 : 1
            r.deleteRule = rule
            r.isOptional = true
            return r
        }
        let forward = side(aName, b, aMany, aRule)
        let inverse = side(bName, a, bMany, bRule)
        unsafe forward.inverseRelationship = inverse
        unsafe inverse.inverseRelationship = forward
        a.properties.append(forward)
        b.properties.append(inverse)
    }

    // MARK: Attribute Tables
    // One row per stored property of each model class (61–67), in declaration order.

    static let filmAttributes: [Attribute] = [
        ("id", .uuid), ("posterUID", .string), ("name", .string),
        ("releaseYear", .string), ("userRating", .int), ("lastWatched", .string),
        ("duration", .string), ("viewCount", .int), ("calendarTable", .strings),
        ("autoAddToQueueOnRotation", .optionalInt), ("rotationThresholdOverride", .optionalInt), ("digitalSource", .string),
        ("digitalVersion", .string), ("subtitles", .string), ("notes", .string),
        ("numberOfDiscs", .string), ("aspectRatio", .string), ("color", .bool),
        ("edited", .bool), ("editedDuration", .string), ("frameRate", .double),
        ("tags", .strings), ("externalIdentifiers", .strings), ("dateAdded", .string),
        ("lastModified", .string), ("watched", .bool), ("specialSorting", .strings),
        ("alternateTitle", .strings), ("hofPosition", .int), ("infoComplete", .bool),
        ("comments", .string), ("genre", .string), ("releaseDate", .string),
        ("descriptionText", .string), ("rating", .string), ("studio", .strings),
        ("cast", .strings), ("directors", .strings), ("producers", .strings),
        ("executiveProducers", .strings), ("screenwriters", .strings), ("encodingTool", .strings),
        ("libraryHBRFValue", .int), ("composer", .strings), ("sortName", .string),
        ("releaseUsed", .string), ("tools", .strings), ("editedHBRFValue", .int),
        ("editDate", .string), ("warning", .strings), ("descriptionNotes", .string),
        ("notesOnAudioTiming", .strings), ("specialAudioNotes", .strings), ("notesArray", .strings),
        ("handbrakeFrames", .strings), ("correspondingTimecodes", .strings),
    ]

    static let listObjectAttributes: [Attribute] = [
        ("listID", .uuid), ("listName", .string), ("viewStyle", .string),
        ("sortFilterOptions", .strings), ("displayOrder", .int),
    ]

    static let releaseAttributes: [Attribute] = [
        ("id", .uuid), ("studio", .string), ("releaseDate", .string),
        ("baseReleaseYear", .string), ("purchased", .bool), ("wishlist", .int),
        ("format", .string), ("includedVersions", .strings), ("independence", .string),
        ("videoFormat", .string), ("releaseAspectRatio", .strings), ("scanningMethod", .string),
        ("audioFormat", .string), ("audioChannels", .string), ("hasSubtitles", .bool),
        ("numberOfDiscs", .int), ("discMultiPack", .bool), ("hasArtwork", .string),
        ("remastered", .bool), ("nationalOrigin", .string), ("replicationType", .string),
        ("discCapacity", .strings), ("hasHDR", .string), ("masterType", .string),
        ("regionLock", .string), ("regionLockBypass", .bool), ("marketAvailability", .strings),
        ("numberOfCopies", .int), ("cost", .double), ("amountSpent", .double),
        ("purchaseDate", .string), ("lowestPrice", .double), ("lowestPriceDate", .string),
        ("condition", .string), ("notes", .string), ("dateAdded", .date),
        ("sortOrder", .int),
    ]

    static let listMembershipAttributes: [Attribute] = [
        ("id", .uuid), ("dateAdded", .date), ("sortOrder", .int),
    ]

    static let importSessionAttributes: [Attribute] = [
        ("id", .uuid), ("sessionDate", .date), ("importType", .string),
        ("totalItems", .int), ("successCount", .int), ("errorCount", .int),
        ("duplicateCount", .int), ("updatedCount", .int), ("notFoundCount", .int),
        ("errorFileNames", .strings), ("addedTitles", .strings), ("updatedTitles", .strings),
        ("duplicateTitles", .strings), ("isCompleted", .bool), ("isCanceled", .bool),
    ]

    static let settingsObjectAttributes: [Attribute] = [
        ("snapshotID", .uuid), ("version", .int), ("lastSyncDate", .date),
        ("confirmGalleryDelete", .optionalBool), ("confirmListEdits", .optionalBool), ("listEditScope", .optionalInt),
        ("confirmReleaseDelete", .optionalBool), ("largeGalleryGrid", .optionalBool), ("showStatusBar", .optionalBool),
        ("rememberRightSidebarTab", .optionalBool), ("rememberRightSidebarReleasesFilter", .optionalBool), ("autoExpandRightSidebarTables", .optionalBool),
        ("additionalCalTableDetails", .optionalBool), ("showReleasesSummaryTable", .optionalBool), ("iCalIntegration", .optionalBool),
        ("manualExtQuery", .optionalBool), ("smartLists", .optionalBool), ("excludeQueuedFromUpForRotation", .optionalBool),
        ("maintainSelectionOnSearchExit", .optionalBool), ("showSearchSuggestions", .optionalBool), ("showRecentSearches", .optionalBool),
        ("showInfoComplete", .optionalBool), ("performBackupAtLaunch", .optionalBool), ("defaultRotationThreshold", .optionalInt),
        ("importScanSubfolders", .optionalBool), ("fuzzyImportMatching", .optionalBool), ("fuzzyImportYearMatching", .optionalBool),
        ("overrideSortNameField", .optionalBool), ("allowUpdatesForDuplicateImports", .optionalBool), ("allowUpdatesForDuplicateRatings", .optionalBool),
        ("exportPosterImages", .optionalBool), ("prunePosterImages", .optionalBool), ("exportUserSettings", .optionalBool),
        ("maintainScrollPositionOnViewSwitch", .optionalBool), ("rememberTabSelection", .optionalBool), ("tabRememberScope", .optionalInt),
        ("lastRecentsCategory", .optionalString), ("lastReportsCategory", .optionalString), ("rememberImportsTab", .optionalBool),
        ("lastImportsCategory", .optionalString), ("rememberSortFilterSelections", .optionalBool), ("confirmFilmQueueAdd", .optionalBool),
        ("notifyAboutNewReleases", .optionalBool), ("onlyNotifyForWishlisted", .optionalBool), ("queueIsDropTarget", .optionalBool),
        ("queueSectionOnDrop", .optionalInt), ("strictFramesTableChecking", .optionalBool), ("showWatchDetailsAnnotationGlyphs", .optionalBool),
        ("atvq", .optionalBool), ("loggingEnabled", .optionalBool), ("selectedSortOptionsJSON", .optionalString),
        ("ignoredDuplicatePairsJSON", .optionalString),
    ]

    static let savedSearchObjectAttributes: [Attribute] = [
        ("searchID", .uuid), ("name", .string), ("queryJSON", .string),
        ("displayOrder", .int), ("dateCreated", .date), ("dateModified", .date),
    ]

}
