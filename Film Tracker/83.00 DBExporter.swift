// MARK: - DBExporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Produces .ftbackup packages containing an XML export of all model types and
// optionally the posters folder. A manual export reads the database on the MainActor; the
// automatic background backup reads it on a background model actor. Packaging, poster
// pruning, and delivery to the destination run in background tasks via Task.detached.

import Foundation
import CoreData
import UniformTypeIdentifiers

/// A backup that was written but could not be read back.
///
/// The export pipeline and the import pipeline enforce different limits — the reader caps
/// file size, per-text-node size and object count, and the writer caps nothing — so there
/// are library shapes the application can WRITE and then refuse to READ. Before this error
/// existed, such an export reported success and the file failed at restore time, which is
/// the one moment the user needs it to work and the one moment they may no longer have the
/// data it was made from. Surfacing the disagreement at export time is strictly better:
/// the library is still there, and the message names what is wrong with it.
public enum DBExporterError: LocalizedError {
    /// The written package could not be parsed back at all.
    case verificationFailed(underlying: any Error)
    /// The written package parsed, but does not describe what was exported.
    case verificationMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let underlying):
            return "The backup was written but could not be read back, so it has been "
                + "discarded rather than presented as a usable backup. (\(underlying))"
        case .verificationMismatch(let detail):
            return "The backup was written but does not match the library it was made from, "
                + "so it has been discarded rather than presented as a usable backup. (\(detail))"
        }
    }
}

/// The name a new backup is written under: `FilmTrackerBackup-<timestamp>.ftbackup`, or
/// `FilmTrackerBackup-Auto-<timestamp>.ftbackup` for the background auto-backup.
///
/// The Export tab and the auto-backup each built this by hand from their own formatter,
/// with a comment asking one to mirror the other. The timestamp is ISO 8601 in the
/// user's time zone with its colons swapped for dashes, which Finder and other file
/// systems reject in a name.
///
/// A Sendable value style in the local time zone, safe from the auto-backup's background
/// thread. It truncates to the second where the old `ISO8601DateFormatter` rounded.
nonisolated enum BackupFilename {
    private static let timestampStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current)

    static func make(auto: Bool, date: Date = Date()) -> String {
        let timestamp = timestampStyle.format(date)
            .replacingOccurrences(of: ":", with: "-")
        return "FilmTrackerBackup-\(auto ? "Auto-" : "")\(timestamp).ftbackup"
    }
}

// MARK: - Package Handoff

/// Moves an `ExportPackage` into the packaging task so it is freed there (see createBackup).
/// Taken exactly once, by that task; the lock only makes the single hand-over explicit.
private final class ExportPackageHandoff: @unchecked Sendable {
    private var package: ExportPackage?
    private let lock = NSLock()

    init(_ package: consuming ExportPackage) { self.package = package }

    func take() -> ExportPackage {
        lock.lock(); defer { lock.unlock() }
        guard let package else { preconditionFailure("export package handed off twice") }
        self.package = nil
        return package
    }
}

@MainActor
public final class DBExporter: Loggable {
    // `public` because DBExporter itself is public and `Loggable` (the shared logging
    // utility) is a public protocol: a public type's witness must be at least as visible
    // as the requirement it satisfies.
    nonisolated public static let logTag = "[DBExporter]"

    public struct BackupResult: Sendable {
        // Where the .ftbackup package ended up: its delivered URL at the destination — whose
        // name carries a numeral when the plain one was taken — or, with no destination,
        // the package still in its staging directory.
        public let packageURL: URL
        // Whether the package was delivered to a destination.
        public let didCopyToDestination: Bool }

    private let persistentContainer: NSPersistentContainer
    private let packager: DBPackager

    // Returns all exportable model types in the FilmTracker.app database.
    // NOTE: SettingsObject is included automatically - settings are continuously synced
    // to the database by SettingsManager, so they're always current at export time.
    public static var allModelTypes: [any ExportableModel.Type] {
        return [Film.self,  ListObject.self, ListMembership.self, Release.self,
            ImportSession.self, SettingsObject.self, SavedSearchObject.self] }

    // The exporter is constructed from the NSPersistentContainer rather than a long-lived
    // NSManagedObjectContext. A fresh NSManagedObjectContext is created per export inside createBackup so
    // that every read reflects the current persisted state. See the read phase below
    // for the full rationale.
    public init(persistentContainer: NSPersistentContainer, packager: DBPackager = DBPackager()) {
        self.persistentContainer = persistentContainer
        self.packager = packager }

    // MARK: - Public API
    // NOTE: This function runs on the MainActor to keep NSManagedObjectContext fetches safe.
    // Packaging (writing into the sandbox) is executed off the MainActor in a detached Task.
    //
    // posterUIDs: Optional set of valid poster UIDs for orphan pruning. When provided,
    // PosterPruner uses these directly (sourced from MemoryStore) instead of querying
    // the database. This eliminates unnecessary NSManagedObjectContext access and allows the pruner
    // to run without thread-safety concerns. Callers should provide this from
    // DataCoordinator.getAllPosterUIDs() when poster pruning is enabled.
    //
    // posterUIDsTakenAt: when that set was read. The pruner keeps every file written
    // since, which a poster saved during a long export needs (see
    // PosterPruner.pruneOrphanedPosters). The default — the moment of the call — is
    // right for a caller that reads the set in its own argument list.
    @MainActor
    public func createBackup(types: [any ExportableModel.Type], filename: String,
        destinationURL: URL? = nil,
        isBackgroundExport: Bool = false,
        includePosters: Bool? = nil,
        posterUIDs: Set<String>? = nil,
        posterUIDsTakenAt: Date = Date(),
        progress: (@Sendable (Double) -> Void)? = nil) async throws -> BackupResult {

        // A caller-supplied value wins; nil falls back to the stored preference. The
        // Export tab passes its session-scoped picker selection here, which is
        // deliberately NOT written back to Preferences — see ExportViewModel.
        let includePostersResolved = includePosters ?? Preferences.exportPosterImages

        // Report initial progress immediately
        progress?(0.0)

        Self.log("Starting export: \(types.count) type(s), filename='\(filename)', destination=\(destinationURL?.lastPathComponent ?? "none (staging only)"), background=\(isBackgroundExport)")

        // --------------------
        // PHASE 1: Read / Export (MAIN ACTOR)
        // --------------------
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let shouldPrunePosters = includePostersResolved && Preferences.prunePosterImages

        // NOTE: Settings and other debounced writes are not flushed here — DBExporter
        // doesn't touch DataCoordinator. Both app callers run
        // DataCoordinator.commitPendingWritesForExport() first; the export then includes
        // whatever SettingsObject is in the database.
        
        // reader.exportAll runs on MainActor because this function is @MainActor.
        // Read through a freshly created NSManagedObjectContext (created here, on the MainActor)
        // rather than the app's long-lived viewContext. A brand-new context has no
        // previously-registered objects, so each fetch materializes every object
        // directly from the persistent store. This guarantees the export reflects the
        // current persisted state — including in-session scalar edits applied through
        // DataManager's background context — independent of any cross-context merge
        // behavior. Reusing the launch-loaded viewContext could otherwise return stale
        // snapshots for objects that were registered at load time and later edited in
        // the background context. The context is read-only here (never saved) and is
        // discarded when this method returns.
        //
        // The automatic backup reads on a background executor instead (see
        // BackgroundExportReader), with its own equally fresh context. Before, its read ran
        // here on the MainActor like the manual one: each entity's fetch materialized the
        // whole table in one blocking call — seconds on a large library, during which the
        // UI could not respond — and every object's conversion followed on the main thread
        // too. (Created inside a detached task, which the SwiftData build needed because it
        // served a model actor's context on the queue it was created on.)
        let exportPackage: ExportPackage
        if isBackgroundExport {
            let container = persistentContainer
            let modelTypes = ExportModelTypes(types: types)
            let read = Task.detached(priority: .low) {
                try await BackgroundExportReader(persistentContainer: container).exportAll(
                    types: modelTypes, appVersion: appVersion) { @Sendable p in progress?(p * 0.35) }
            }
            // A detached task does not inherit cancellation, and quitting cancels the
            // automatic backup (applicationShouldTerminate). Forwarded explicitly so the read
            // still stops at its next cancellation check, as it did on the MainActor.
            exportPackage = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
        } else {
            let reader = DBReader(context: persistentContainer.makeMainContext())
            // Pass a progress callback (safe since we're already on MainActor)
            exportPackage = try await reader.exportAll(
                types: types, appVersion: appVersion, isBackgroundExport: false) { @Sendable p in
                progress?(p * 0.35)
            }
        }

        try Task.checkCancellation()

        Self.log("Read phase complete: \(exportPackage.objects.count) object(s) across \(exportPackage.manifest.count) entity type(s)")
        
        // --------------------
        // PHASE 1.5: Prune posters AFTER data export (if enabled)
        // PosterPruner is a pure file-system utility that accepts a Set<String> of valid
        // posterUIDs. It does NOT access NSManagedObjectContext. The posterUIDs are sourced from
        // MemoryStore (via the caller) or, if not provided, pruning is skipped.
        // --------------------
        if shouldPrunePosters {
            progress?(0.35)
            if let uids = posterUIDs {
                Self.log("Pruning orphaned posters before packaging (\(uids.count) valid poster UID(s) known)")
                // Run pruning on a background thread — it's pure file I/O, no actor constraints.
                let priority: TaskPriority = isBackgroundExport ? .low : .utility
                await Task.detached(priority: priority) {
                    PosterPruner.pruneOrphanedPosters(validPosterUIDs: uids,
                                                      snapshotTakenAt: posterUIDsTakenAt)
                }.value
            } else {
                Self.log("NOTE: Poster pruning enabled but no posterUIDs were provided — skipping prune")
            }
            progress?(0.40)
        }

        // --------------------
        // PHASE 2: Create file package and write XML (BACKGROUND)
        //
        // The package is assembled in its own `ExportStaging` directory inside the sandbox
        // container, and nothing reaches the destination until it is complete and verified
        // — see `ExportStaging`. Every failure and cancel below is cleaned up inside the
        // container. When no destination is provided, the staging dir is kept in place and
        // its URL is returned; the next launch's purge reclaims it.
        // --------------------
        let packager = self.packager
        // The package's ownership is handed to the packaging task rather than shared with
        // it. Freeing an export package — tens of thousands of dictionaries on a large
        // library — takes tens of milliseconds, and whichever thread drops the last
        // reference pays it. Kept here, that was the main thread, as this function
        // returned: the one hitch the automatic backup still caused once its read had moved
        // off the main thread. Only the two figures verification needs are kept.
        let expectedObjects = exportPackage.objects.count
        let expectedManifest = exportPackage.manifest
        let handoff = ExportPackageHandoff(consume exportPackage)
        let shouldExportPosters = includePostersResolved
        let postersFolderURL = Preferences.posterImagesFolderURL

        let priority: TaskPriority = isBackgroundExport ? .low : .utility
        let (packageURL, stagingDir): (URL, URL) = try await Task.detached(priority: priority) {
            let stagingDir = try ExportStaging.makeDirectory()

            let packageName = filename.hasSuffix(".ftbackup") ? filename : "\(filename).ftbackup"
            let packagePath = stagingDir.appendingPathComponent(packageName)

            let fm = FileManager.default

            // A failure or cancel anywhere in packaging discards the whole staging
            // directory, not just the packager's own temp file.
            do {
                // Create package directory (inside staging).
                try fm.createDirectory(at: packagePath, withIntermediateDirectories: true)

                Self.log("Packaging into staging directory: \(stagingDir.lastPathComponent)")

                // Write XML file inside package.
                //
                // The packager's own 0…1 is mapped into this phase's slice of the export's bar
                // rather than discarded. Writing the XML is the longest single step of a large
                // export, and dropping its progress left the bar parked at 40% for the whole of
                // it and then jumping to 85% — the one stretch where an export looks stalled is
                // the one stretch that already knows exactly how far along it is.
                let xmlFilename = "backup.xml"
                let pkg = handoff.take()
                _ = try await packager.package( exportPackage: pkg, filename: xmlFilename,
                    folderURL: packagePath, isBackgroundExport: isBackgroundExport,
                    progress: { p in progress?(0.40 + p * 0.45) })

                // Copy posters (if requested).
                if shouldExportPosters, let postersSource = postersFolderURL {
                    let postersDestination = packagePath.appendingPathComponent("Posters")

                    if fm.fileExists(atPath: postersSource.path(percentEncoded: false)) {
                        try fm.copyItem(at: postersSource, to: postersDestination)
                        Self.log("Posters folder copied into package")
                    } else {
                        Self.log("NOTE: Poster export enabled but no posters folder exists at source — skipping poster copy")
                    }
                } else if shouldExportPosters {
                    Self.log("NOTE: Poster export enabled but no posters folder URL is configured — skipping poster copy")
                }
            } catch {
                ExportStaging.discard(stagingDir)
                throw error }

            return (packagePath, stagingDir) }.value

        // --------------------
        // PHASE 2.5: Verify the written package (BACKGROUND)
        //
        // Read the file back through the SAME importer a restore uses, and require it to
        // describe what was just exported. Nothing else in the pipeline does this: the
        // packager's `write` calls not throwing was previously the whole of the evidence
        // that a usable backup existed, and that evidence is weaker than it sounds. It does
        // not cover a truncated write, and — the case that motivated this phase — it does
        // not cover the reader and the writer disagreeing about what is acceptable at all.
        // `DBImporter` refuses a text node over 4 MiB, a file over 512 MiB, and more than
        // 100 000 objects; the writer enforces none of those, so a single oversized notes
        // field or a large enough library produced a backup that reported success and could
        // never be restored.
        //
        // Verification is by re-parse plus a count comparison rather than a full field-level
        // diff. The re-parse is what catches every "written but unreadable" shape at once,
        // including ones no future limit change would have to be remembered here; the counts
        // then catch a file that parses but lost rows. A field-by-field comparison would cost
        // roughly a restore's worth of work on every export for a class of failure the XML
        // writer — which only ever concatenates text it was handed — cannot produce.
        //
        // The package is discarded on failure. A file that cannot be read back is not a
        // backup, and leaving it in place under a plausible name is worse than having none:
        // it is the file the user would reach for.
        do {
            let xmlURL = packageURL.appendingPathComponent("backup.xml")
            // Parsed, counted, and freed in a background task, for the same reason as the
            // handoff above: only the counts come back to this actor.
            let verified = try await Task.detached(priority: priority) {
                let parsed = try await DBImporter().parseBackupFile(at: xmlURL)
                return (objectCount: parsed.objects.count, manifest: parsed.manifest)
            }.value

            if verified.objectCount != expectedObjects {
                throw DBExporterError.verificationMismatch(
                    "wrote \(expectedObjects) object(s), read back \(verified.objectCount)")
            }
            if verified.manifest != expectedManifest {
                throw DBExporterError.verificationMismatch(
                    "manifest written as \(expectedManifest.sorted(by: { $0.key < $1.key })), "
                        + "read back as \(verified.manifest.sorted(by: { $0.key < $1.key }))")
            }
            Self.log("Verification passed: package re-parsed to \(verified.objectCount) object(s)")
        } catch let error as DBExporterError {
            Self.log("WARNING: Export verification failed — discarding package: \(error.errorDescription ?? "\(error)")")
            ExportStaging.discard(stagingDir)
            throw error
        } catch {
            Self.log("WARNING: Export verification could not read the package back — discarding it: \(error)")
            ExportStaging.discard(stagingDir)
            throw DBExporterError.verificationFailed(underlying: error)
        }

        progress?(0.85)

        // Cancellation after staging succeeded — clean up the staging dir before throwing.
        do {
            try Task.checkCancellation()
        } catch {
            Self.log("NOTE: Export canceled after staging — removing staging directory \(stagingDir.lastPathComponent)")
            ExportStaging.discard(stagingDir)
            throw error
        }

        // --------------------
        // PHASE 3: Move package to destination (if provided) (BACKGROUND)
        //
        // Never over anything: `ExportStaging.deliver` takes the first free name —
        // `FilmTrackerBackup-….ftbackup`, then `… 1.ftbackup`, … — and nothing already at
        // the destination is ever removed or replaced. The automatic backup comes through
        // here too, delivering into the container's own Backups folder.
        // --------------------
        if let dest = destinationURL {
            let packageName = packageURL.lastPathComponent
            let sourceURL = packageURL
            // Scope is opened on the URL the CALLER named — the one a bookmark was resolved
            // for — not on the delivered path. A sandbox extension belongs to the bookmarked
            // item rather than to paths beneath it, so a child path that does not exist yet
            // returns false. Scoping `dest` stays harmless when the caller has already opened
            // it, since extensions are reference-counted per URL.
            let scopeURL = dest

            // Perform the move off the MainActor; Only capture Sendable immutable values (URLs).
            let deliveredURL: URL
            do {
                deliveredURL = try await Task.detached(priority: priority) {
                    let started = scopeURL.startAccessingSecurityScopedResource()
                    defer { if started { scopeURL.stopAccessingSecurityScopedResource() } }
                    // `dest` must be an existing folder. Every caller passes one; a folder
                    // that has since vanished is an error, never a cue to write beside it.
                    guard scopeURL.isExistingDirectory else {
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: scopeURL]) }
                    return try ExportStaging.deliver(sourceURL, into: scopeURL, as: packageName)
                }.value
            } catch {
                Self.log("WARNING: Failed to move package to destination '\(packageName)': \(error.localizedDescription)")
                ExportStaging.discard(stagingDir)
                throw error
            }

            // The package has left staging — the now-empty staging dir is no longer needed.
            ExportStaging.discard(stagingDir)

            progress?(1.0)
            Self.log("Export complete: Package delivered to destination as '\(deliveredURL.lastPathComponent)'")
            return BackupResult(packageURL: deliveredURL, didCopyToDestination: true) }

        // No destination provided - return the staging package URL. The caller owns
        // the returned file until the next launch purges `ExportStaging`.
        progress?(1.0)
        Self.log("Export complete: No destination provided, package left in staging directory '\(stagingDir.lastPathComponent)'")
        return BackupResult(packageURL: packageURL, didCopyToDestination: false) }

    // Convenience method to create a complete database backup with all entity types.
    //
    // includeSettings: When false, SettingsObject is excluded from the export so the
    // resulting .ftbackup contains no user settings. This drives the manual "Include
    // user settings" toggle. The automatic launch backup leaves this at its default of
    // true so disaster-recovery backups always capture the full database. Because the
    // export's manifest and object list are built solely from the supplied `types`
    // array, omitting SettingsObject here is sufficient — no other layer needs changing,
    // and the restore pipeline already tolerates backups that contain no SettingsObject.
    @MainActor
    public func createCompleteBackup(filename: String,
        destinationURL: URL? = nil,
        isBackgroundExport: Bool = false,
        includeSettings: Bool = true,
        includePosters: Bool? = nil,
        posterUIDs: Set<String>? = nil,
        posterUIDsTakenAt: Date = Date(),
        progress: (@Sendable (Double) -> Void)? = nil) async throws -> BackupResult {

        let types = includeSettings
            ? Self.allModelTypes
            : Self.allModelTypes.filter {
                ObjectIdentifier($0) != ObjectIdentifier(SettingsObject.self) }

        if !includeSettings {
            Self.log("User settings excluded from export by preference")
        }

        return try await createBackup(
            types: types,
            filename: filename,
            destinationURL: destinationURL,
            isBackgroundExport: isBackgroundExport,
            includePosters: includePosters,
            posterUIDs: posterUIDs,
            posterUIDsTakenAt: posterUIDsTakenAt,
            progress: progress) }
}
