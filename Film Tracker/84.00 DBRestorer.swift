// MARK: - DBRestorer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Restores SwiftData database from a parsed backup file package.

import Foundation
import SwiftData

public enum DBRestorerError: Error {
    case invalidBackupStructure(String)
    case restorationFailed(String)
    case notAPackage(URL)
    case missingXML(URL)
    case storeRebuildFailed(String)
}

@MainActor
final class DBRestorer: Loggable {
    nonisolated static let logTag = "[DBRestorer]"

    // Track schema evolution for logging.
    private var missingFieldsDetected: Set<String> = []
    private var schemaEvolutionOccurred: Bool = false

    /// Lowercased names already assigned to user lists during this restore, so two lists in
    /// the same backup can never come back sharing one name. See `resolveListName`.
    private var claimedListNames: Set<String> = []

    private let container: ModelContainer
    private let importer: DBImporter
    private let dataCoordinator: DataCoordinator?
    private var settingsWereRestored = false

    /// Non-fatal warning surfaced after a successful restore when settings were
    /// restored to the database but could not be applied to UserDefaults. The DB
    /// contents are intact; only the in-memory Preferences state is stale, which
    /// the user's post-restore relaunch will normally resolve. UI layers may inspect
    /// this after `restoreFromBackup` returns to include an informational note in
    /// the completion alert. `nil` means no warning was raised.
    public private(set) var settingsApplyFailure: String?

    /// True once `restoreFromBackup` has destroyed the app's persistent store and opened a
    /// fresh one in its place.
    ///
    /// The point of no return. Everything the restore does BEFORE this flag is raised —
    /// package validation, XML parsing, structural checks — leaves the existing database
    /// untouched, so a failure there is recoverable and the session can simply carry on.
    /// Everything AFTER it runs against a store whose files have already been unlinked
    /// from under the app's original ModelContainer: that container's SQLite connection
    /// now addresses a deleted inode, so any subsequent save in this session writes into a
    /// file nothing will ever open again. A failure past this point is therefore NOT
    /// recoverable in-session however harmless its message reads, and the UI must require
    /// the same restart a successful restore does rather than offering a plain "OK".
    public private(set) var storeWasRebuilt = false

    init(container: ModelContainer, dataCoordinator: DataCoordinator? = nil,
        importer: DBImporter = DBImporter()) {
        self.container = container
        self.dataCoordinator = dataCoordinator
        self.importer = importer }

    // Restore database from backup package with progress reporting.
    //
    // DELIBERATELY NOT CANCELLABLE. Past `destroyAndRecreatePersistentStore()` the user's
    // old database no longer exists, so there is no state to return to: an abort part-way
    // through the three population passes would leave a store holding an arbitrary prefix
    // of the backup — films without their releases, memberships pointing at lists that were
    // never created — which is strictly worse than either finishing or failing outright.
    // The UI reflects this: the confirmation alert is the last decision point, and the
    // progress sheet that follows is an indeterminate spinner with no Cancel button.
    //
    // The passes below therefore carry no `Task.checkCancellation()` calls. They used to,
    // and nothing ever canceled the enclosing task — which made them both dead and
    // misleading, since they advertised a safe abort at exactly the points where aborting
    // is least safe. A genuine hard failure (power loss, kill) is covered by the same
    // recovery the UI already offers: relaunch, and run the restore again.
    @MainActor
    public func restoreFromBackup(
        at packageURL: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        // Reset schema evolution tracking
        missingFieldsDetected.removeAll()
        schemaEvolutionOccurred = false
        settingsWereRestored = false
        settingsApplyFailure = nil
        storeWasRebuilt = false

        // Validate it's a .ftbackup package.
        guard packageURL.pathExtension == "ftbackup" else {
            throw DBRestorerError.notAPackage(packageURL) }

        guard packageURL.isExistingDirectory else {
            throw DBRestorerError.notAPackage(packageURL) }

        // Locate XML file inside package.
        let xmlURL = packageURL.appendingPathComponent("backup.xml")
        guard FileManager.default.fileExists(atPath: xmlURL.path(percentEncoded: false)) else {
            throw DBRestorerError.missingXML(packageURL) }

        // Check for Posters folder.
        let postersURL = packageURL.appendingPathComponent("Posters")
        let hasPosters = FileManager.default.fileExists(atPath: postersURL.path(percentEncoded: false))

        // Phase 1: Parse and validate XML (0-20%).
        progress?(0.0, "Reading backup file...")
        let backup = try await importer.parseBackupFile(at: xmlURL)

        progress?(0.1, "Validating backup structure...")
        try validateBackup(backup)

        progress?(0.2, "Preparing restoration...")

        // Phase 2: Destroy and recreate the persistent store (20-30%).
        //
        // Rather than deleting rows entity-by-entity inside the existing store, we
        // physically delete the SwiftData store files and open a brand-new, empty store
        // at the same location. This unconditionally resolves schema-mismatch errors that
        // arise when a new model field is added without a versioned migration: the old
        // .store file carries the previous schema and cannot be safely cleared or written
        // to by the current app binary, so the entity-deletion approach would fail even
        // after the files are replaced unless the store itself is rebuilt from scratch.
        //
        // A post-restore application restart is already mandatory (enforced by the UI),
        // so the original ModelContainer held by the app is intentionally orphaned for
        // the remainder of this session. All subsequent restore operations use the fresh
        // container returned by this call.
        progress?(0.25, "Rebuilding database store...")
        let restoreContainer: ModelContainer
        do {
            restoreContainer = try await destroyAndRecreatePersistentStore()
            Self.log("Persistent store destroyed and recreated successfully")
        } catch let error as DBRestorerError {
            throw error
        } catch {
            throw DBRestorerError.storeRebuildFailed(
                "Failed to rebuild persistent store: \(error.localizedDescription)")
        }

        progress?(0.3, "Creating new objects...")

        // Phase 3: Create new context and insert objects (30-70%)
        // The context is opened against the freshly-created store, guaranteeing a clean
        // schema and no residual data from the previous database.
        let context = ModelContext(restoreContainer)
        context.autosaveEnabled = false  // Disable autosave during bulk operations

        // Lookup dictionaries keyed directly by the model's own UUID. The second pass
        // reads the filmID / listID properties off ParsedObjects, which are UUIDs —
        // keying the dicts by UUID removes the need to reconstruct string prefixes
        // like "Film-<uuid>" at lookup time.
        var filmByID: [UUID: Film] = [:]
        var listByID: [UUID: ListObject] = [:]
        // Populated during the second pass for use in the third-pass hierarchy link step.
        var releaseByID: [UUID: Release] = [:]
        // Created after the first pass, once every list has its final name: a saved
        // search's name must not be one a list already answers to (createSavedSearches).
        var savedSearchObjects: [ParsedObject] = []

        let totalObjects = backup.objects.count
        var processedObjects = 0

        // First pass: Create all standalone objects (Films, Lists, ImportSessions)
        for obj in backup.objects {
            switch obj.entityName {
            case "Film":
                do {
                    let film = try createFilm(from: obj, context: context)
                    filmByID[film.id] = film
                } catch {
                    Self.log("WARNING: Skipping malformed Film object \(obj.exportID): \(error.localizedDescription)")
                    // Continue processing other objects
                }

            case "ListObject":
                do {
                    let list = try createListObject(from: obj, context: context)
                    listByID[list.listID] = list
                } catch {
                    Self.log("WARNING: Skipping malformed ListObject \(obj.exportID): \(error.localizedDescription)")
                }

            case "ImportSession":
                do {
                    _ = try createImportSession(from: obj, context: context)
                } catch {
                    Self.log("WARNING: Skipping malformed ImportSession \(obj.exportID): \(error.localizedDescription)")
                    // ImportSession is optional metadata, safe to skip
                }

            case "SavedSearchObject":
                savedSearchObjects.append(obj)

            case "SettingsObject":
                do {
                    _ = try createSettingsObject(from: obj, context: context)
                    // NOTE: Not tracking in a map since it's a singleton
                    settingsWereRestored = true
                    Self.log("Settings restored from backup")
                } catch {
                    Self.log("WARNING: Skipping malformed SettingsObject \(obj.exportID): \(error.localizedDescription)")
                    // Settings are optional - if malformed, just skip
                }

            default:
                // Unknown entity type - log and skip (forward compatibility)
                Self.log("INFO: Skipping unknown entity type '\(obj.entityName)' (ID: \(obj.exportID))")
                break
            }

            processedObjects += 1
            let objectProgress = 0.3 + (0.2 * Double(processedObjects) / Double(totalObjects))
            progress?(objectProgress, "Creating objects... \(processedObjects)/\(totalObjects)")
        }

        createSavedSearches(from: savedSearchObjects, lists: Array(listByID.values), context: context)

        // Second pass: Create join entities now that parent objects exist
        for obj in backup.objects {
            switch obj.entityName {
            case "ListMembership":
                do {
                    _ = try createListMembership(from: obj, context: context, filmByID: filmByID, listByID: listByID)
                } catch {
                    Self.log("WARNING: Skipping malformed ListMembership \(obj.exportID): \(error.localizedDescription)")
                }

            case "Release":
                do {
                    if let release = try createRelease(from: obj, context: context, filmByID: filmByID) {
                        releaseByID[release.id] = release
                    }
                } catch {
                    Self.log("WARNING: Skipping malformed Release \(obj.exportID): \(error.localizedDescription)")
                }

            default:
                break
            }
        }

        // Third pass: Link release parent-child hierarchy.
        // Both the parent and child releases are guaranteed to exist in releaseByID at
        // this point (they were all created in the second pass above). The parentReleaseID
        // field is optional — old backups that predate this feature simply won't have it,
        // in which case SafeValueParser.parseOptionalUUID returns nil and no link is made,
        // leaving the release as an independent top-level release.
        //
        // Implementation uses two sub-passes to be resilient against arbitrary XML object
        // ordering. A single-pass approach could silently produce illegal 3-level chains if
        // a grandchild object appeared before its grandparent in the XML (because the
        // grandparent's own parentRelease pointer would still be nil at the time the
        // grandchild's link was evaluated, defeating the depth guard).
        //
        // Sub-pass A: collect every (childUUID, parentUUID) pair that has a parentReleaseID.
        // Sub-pass B: apply links, enforcing three constraints against the COLLECTED
        //             CANDIDATES rather than against the partially-built object graph —
        //             which is what actually makes the result independent of XML order:
        //               • the parent must exist in this backup,
        //               • the parent must not itself name a parent (depth, and self-links),
        //               • the parent must belong to the same film as the child.
        //             A link failing any of them is dropped; both releases are still
        //             restored, the child simply as a top-level release.
        //
        // Splitting the passes was necessary but not sufficient: the depth check used to
        // read `parentRelease.parentRelease`, which reports whether the parent's own link
        // has been APPLIED yet rather than whether one exists, so ordering still defeated
        // it inside sub-pass B. See `releasesNamingAParent` below.

        // Sub-pass A: collect candidate links.
        // UUID fields are parsed through SafeValueParser to guarantee consistent handling
        // of NSNull, whitespace, type mismatches, and malformed strings — the same guarantee
        // provided to every other field in the restore pipeline.
        // `id` is a required field: a Release without a parseable id cannot be looked up in
        // releaseByID and is therefore meaningless for hierarchy linking; we skip and log.
        // `parentReleaseID` is optional: absent or null means a top-level release, which
        // is the correct interpretation for any backup that predates the hierarchy feature.
        struct HierarchyLink { let childUUID: UUID; let parentUUID: UUID }
        var candidateLinks: [HierarchyLink] = []

        for obj in backup.objects where obj.entityName == "Release" {
            var linkParser = SafeValueParser(
                properties: obj.properties,
                entityName: "Release (hierarchy)",
                logMalformed: { [weak self] in self?.logMalformed($0) },
                recordMissing: { [weak self] in self?.recordMissingField($0) },
                checkExists: { [weak self] in self?.propertyExists($0, in: obj.properties) ?? false }
            )

            // Parse the release's own id — required for the releaseByID lookup.
            let releaseUUID: UUID
            do {
                releaseUUID = try linkParser.parseRequiredUUID("id")
            } catch {
                Self.log("WARNING: Release object \(obj.exportID) has unparseable id — skipping hierarchy link: \(error.localizedDescription)")
                continue
            }

            // Parse parentReleaseID — optional; nil means this is a top-level release.
            guard let parentUUID = linkParser.parseOptionalUUID("parentReleaseID") else {
                // Absent or null — top-level release, no link needed.
                continue
            }

            candidateLinks.append(HierarchyLink(childUUID: releaseUUID, parentUUID: parentUUID))
        }

        // Every release that names a parent anywhere in this backup. A designated parent
        // appearing in this set is itself a child, so linking to it would build a chain at
        // least three deep — and a release naming ITSELF appears here as its own parent,
        // so the same test rejects a self-link.
        //
        // This is the depth check, and it is deliberately made against the collected
        // candidates rather than against `parentRelease.parentRelease`. That object-graph
        // form was order-dependent despite the comment above claiming otherwise: it reads
        // whether the parent's OWN link has been applied yet, not whether one exists. Given
        // candidates ordered [(C,B), (B,A)], the C→B link was evaluated while B was still
        // parentless, passed, and B→A was then applied on top of it — producing exactly the
        // three-level chain the guard exists to prevent. A set built from all candidates up
        // front cannot be outrun by ordering.
        //
        // Conservative in one direction on purpose: if a middle link is itself dropped (say
        // its parent is missing from the backup), the deeper link is still refused even
        // though it would then have been legal. That errs toward the behavior this whole
        // pass already takes in every ambiguous case — keep both releases, drop the link.
        let releasesNamingAParent = Set(candidateLinks.map(\.childUUID))

        // Sub-pass B: apply links now that every candidate is collected.
        for link in candidateLinks {
            guard let childRelease = releaseByID[link.childUUID] else {
                Self.log("WARNING: Could not find release \(link.childUUID) in releaseByID for hierarchy linking")
                continue
            }

            guard let parentRelease = releaseByID[link.parentUUID] else {
                Self.log("WARNING: parentReleaseID \(link.parentUUID) not found for release \(link.childUUID) — restoring as top-level")
                continue
            }

            // Enforce the one-level-deep constraint, and with it the no-self-link rule. If
            // the backup contains a deeper chain or a release naming itself (a future
            // schema version, or manual XML editing), skip the link and restore the child
            // as an independent top-level release. Both releases remain in the database;
            // only the hierarchy link is dropped. See `releasesNamingAParent` for why the
            // test is against the collected candidates rather than the object graph.
            if releasesNamingAParent.contains(link.parentUUID) {
                Self.log("WARNING: parentReleaseID \(link.parentUUID) is itself a child release (or is the release's own id) — skipping hierarchy link for \(link.childUUID) (restoring as top-level)")
                continue
            }

            // Guard the same-film constraint. `releaseByID` spans the WHOLE restore, not
            // one film, so without this a backup naming a parent that belongs to a
            // different film would be linked across films — the child would then name a
            // parent that is absent from its own `film.releases`, which is precisely the
            // "orphaned child" state every other writer in the app makes impossible.
            // DataManager step 6.5 cannot produce it (its lookup is built from
            // `film.releases` alone) and the `.nullify` delete rule cannot either, so this
            // was the one remaining way in — reachable only from a hand-edited or corrupt
            // XML, but reachable, and the sidebar's release cards no longer carry the
            // branch that used to cope with it.
            //
            // Compared by film identity rather than by object reference so a nil film on
            // either side (a release whose film failed to resolve) also fails the test
            // rather than matching another nil.
            guard let childFilmID = childRelease.film?.id,
                  let parentFilmID = parentRelease.film?.id,
                  childFilmID == parentFilmID else {
                Self.log("WARNING: parentReleaseID \(link.parentUUID) belongs to a different film than release \(link.childUUID) — skipping hierarchy link (restoring as top-level)")
                continue
            }

            childRelease.parentRelease = parentRelease
            // Populate the inverse explicitly rather than relying on SwiftData to do it.
            // Every link in a restore is applied to freshly inserted, unsaved objects in
            // one batch before a single context.save(), which is precisely the shape in
            // which an inverse array has been observed to come back empty — leaving each
            // child correctly naming its parent while no parent claims any child. The
            // FilmSheet's combo-pack logic reads the parent side, so a restore in that
            // state silently disables the child-deletion confirmation and the combined
            // parent/child carousel card across the whole restored library. The contains
            // check keeps this a no-op whenever the inverse did follow.
            if !parentRelease.childReleases.contains(where: { $0.id == childRelease.id }) {
                parentRelease.childReleases.append(childRelease)
            }
        }

        progress?(0.7, "Saving restored data...")

        // Phase 4: Save the new data (70-80%)
        do {
            try context.save()
            Self.log("Restored data saved successfully")
        } catch {
            throw DBRestorerError.restorationFailed("Failed to save restored data: \(error.localizedDescription)")
        }

        progress?(0.8, "Database restoration complete")

        // The library's film identities have just been wholesale replaced. The "known up for
        // rotation" baseline in UserDefaults describes the PREVIOUS library, so measured
        // against the restored one it would report a large set of false "newly up for
        // rotation" films and auto-enqueue them into the Film Queue — overwriting the queue
        // arrangement that was itself just restored from this very backup.
        //
        // Clearing it returns SmartLists to its unestablished state, where the first full
        // recalculation after the mandatory post-restore relaunch adopts the computed
        // membership as the new baseline without enqueueing anything.
        //
        // Done here rather than alongside the settings restore below because that block is
        // conditional on the backup actually containing settings — a settings-less backup
        // still replaces every film, and would otherwise leave the stale baseline in place.
        Preferences.resetKnownUpForRotationFilmIDs()
        Self.log("Cleared Up for Rotation baseline — restored library has new film identities")

        // Log schema evolution summary if detected
        if schemaEvolutionOccurred {
            Self.log("Schema evolution detected during restoration - older backup successfully migrated")
            Self.log("Missing fields populated with defaults: \(missingFieldsDetected.sorted().joined(separator: ", "))")
        }
        
        // Apply restored settings to UserDefaults if settings were restored AND DataCoordinator available
        if settingsWereRestored {
            if let coordinator = dataCoordinator {
                progress?(0.85, "Applying restored settings...")
                do {
                    try await coordinator.loadSettingsFromDatabase()
                    Self.log("Settings restored and applied to UserDefaults")
                } catch {
                    // Record the failure so the UI layer can surface a non-fatal
                    // notice in the completion alert. We intentionally do not throw:
                    // the database restore itself already succeeded, and failing the
                    // whole operation here would be disproportionate — the user's
                    // post-restore relaunch will normally pick up the new settings
                    // from the database on next launch.
                    let message = error.localizedDescription
                    settingsApplyFailure = message
                    Self.log("WARNING: Failed to apply restored settings: \(message)")
                }
            } else {
                Self.log("NOTE: Settings were restored to database. Caller should call dataCoordinator.loadSettingsFromDatabase()")
            }
        } else {
            Self.log("NOTE: No settings found in backup or settings were malformed - current settings unchanged")
        }

        // Phase 5: Restore poster images if present (80-100%)
        if hasPosters {
            try await restorePosterImages(from: postersURL, progress: progress)
        }

        progress?(1.0, "Restoration complete!")
    }

    // MARK: - Create Fresh Database (Public Entry Point)
    /// Destroys the existing persistent store and creates a fresh, empty one. This is the
    /// public entry point used by the "Create New Library" recovery flow when the database
    /// is broken at launch. After this returns successfully the app must restart — the
    /// in-memory container that was opened as a fallback is orphaned, and the next launch
    /// will open the newly created persistent store cleanly.
    ///
    /// - Throws: `DBRestorerError.storeRebuildFailed` if the store cannot be rebuilt.
    @MainActor
    public func createFreshDatabase() async throws {
        storeWasRebuilt = false
        _ = try await destroyAndRecreatePersistentStore()
        // No films exist any more, so any retained rotation baseline is entirely phantom IDs.
        Preferences.resetKnownUpForRotationFilmIDs()
        Self.log("Fresh empty database created via createFreshDatabase()")
    }

    // MARK: - Store Destruction and Recreation
    /// Destroys the existing SwiftData persistent store files on disk and opens a fresh,
    /// empty store at the same location by constructing a new ModelContainer.
    ///
    /// This is the correct clearing strategy for restore operations because it handles
    /// both the healthy-store case (row-level deletion would also work) and the
    /// broken-schema case. When the schema has changed without a versioned migration,
    /// `createModelContainer()` in `FilmTrackerApp` fails to open the persistent store
    /// and silently falls back to an in-memory container for the current session.
    /// `container.configurations.first?.url` therefore yields a null or meaningless URL
    /// (as confirmed by log output "Could not delete null"), so the store files would
    /// never be touched. The fix is to resolve the store path independently — directly
    /// from the app's known Application Support directory — which is always correct
    /// regardless of whether the active container is persistent or in-memory.
    ///
    /// The caller (`restoreFromBackup` and `createFreshDatabase`) uses the returned
    /// ModelContainer for all subsequent insert and save operations. The original
    /// container is orphaned for the remainder of the session, which is safe because
    /// a mandatory application restart follows every operation that calls this method.
    ///
    /// - Returns: A new, empty `ModelContainer` opened at the correct store URL.
    /// - Throws: `DBRestorerError.storeRebuildFailed` if the store path cannot be
    ///   resolved, the files cannot be deleted, or the new container cannot be opened.
    @MainActor
    private func destroyAndRecreatePersistentStore() async throws -> ModelContainer {
        // Step 0: let tracked writes finish first. They run off the main thread (see
        // DataCoordinator.runOffMainActor), so without this one could be mid-commit against
        // the old store at the moment its files are unlinked below. Nothing between the
        // last check and the unlink suspends, and only the main actor dispatches tracked
        // work, so none can start in between. Bounded like the shutdown drain.
        if let coordinator = dataCoordinator ?? AppDelegate.dataCoordinator,
           coordinator.hasPendingOperations {
            Self.log("Waiting for pending database writes before rebuilding the store")
            let deadline = ContinuousClock.now + .seconds(10)
            while coordinator.hasPendingOperations, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if coordinator.hasPendingOperations {
                Self.log("WARNING: Pending writes still running after 10s — rebuilding the store anyway")
            }
        }

        // Step 1: Resolve the store path from the app's known Application Support
        // directory. SwiftData's default store name is "default.store" and it lives
        // directly inside Application Support (not in a subdirectory), which is exactly
        // what Preferences.dataFolderURL points to. This path is always correct whether
        // or not the current session's ModelContainer opened the store successfully —
        // critically, it is correct even when the app fell back to an in-memory container
        // due to a schema migration failure, in which case container.configurations would
        // give a null URL and the store files would never be found or deleted.
        guard let appSupportURL = Preferences.dataFolderURL else {
            throw DBRestorerError.storeRebuildFailed(
                "Could not resolve Application Support directory — cannot locate store files.")
        }

        let storeName = "default.store"
        let storeURL  = appSupportURL.appendingPathComponent(storeName)
        let walURL    = appSupportURL.appendingPathComponent("\(storeName)-wal")
        let shmURL    = appSupportURL.appendingPathComponent("\(storeName)-shm")

        Self.log("Targeting store files at: \(appSupportURL.path(percentEncoded: false))")

        // Step 2: Delete the three SQLite store files.
        // SwiftData (via Core Data) creates:
        //   • default.store      — the main SQLite database
        //   • default.store-wal  — the write-ahead log (in-flight transactions)
        //   • default.store-shm  — the shared memory file (WAL index)
        // All three must be removed so the new ModelContainer opens a truly empty store
        // with no uncommitted WAL entries from the previous session.
        // Sidecar files may legitimately be absent if WAL mode was not active, so
        // individual deletion failures are logged but do not abort the operation.
        // A failure to delete the main .store file will surface naturally when Step 3
        // attempts to open a new ModelContainer at the same path.
        // Raised BEFORE the first unlink, not after the new container opens: the moment
        // the main .store file is gone the session is committed to a restart, including
        // when Step 3 below then fails to reopen it. See `storeWasRebuilt`.
        storeWasRebuilt = true

        // The derived caches on disk describe the store about to be deleted, and the live
        // MemoryStore still holds it in memory. Silence the latter first so no throttled
        // save can recreate the files, then delete them so the relaunch reads the new store
        // in full rather than validating a cache the fingerprint cannot tell apart from it.
        // See MemoryStoreCache.invalidateOnDisk.
        (dataCoordinator ?? AppDelegate.dataCoordinator)?
            .suspendCachePersistence(reason: "persistent store is being replaced")
        MemoryStoreCache.shared.invalidateOnDisk()

        let fm = FileManager.default
        for fileURL in [storeURL, walURL, shmURL] {
            if fm.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                do {
                    try fm.removeItem(at: fileURL)
                    Self.log("Deleted store file: \(fileURL.lastPathComponent)")
                } catch {
                    Self.log("WARNING: Could not delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Step 3: Open a new ModelContainer at the same store URL.
        // Because the store files were just deleted, SwiftData creates a fresh, empty
        // store at the configured URL with the current model schema. This container is
        // used exclusively by the restore operation; the app-level container is
        // intentionally orphaned for the remainder of this session.
        let schema = Schema([
            Film.self,
            ListObject.self,
            ListMembership.self,
            Release.self,
            ImportSession.self,
            SettingsObject.self,
            SavedSearchObject.self
        ])

        let freshConfig = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            let freshContainer = try ModelContainer(for: schema, configurations: [freshConfig])
            freshContainer.mainContext.autosaveEnabled = false
            freshContainer.mainContext.undoManager = nil
            Self.log("Fresh ModelContainer opened at: \(storeURL.lastPathComponent)")
            return freshContainer
        } catch {
            throw DBRestorerError.storeRebuildFailed(
                "Failed to open fresh ModelContainer after store deletion: \(error.localizedDescription)")
        }
    }

    // MARK: - Poster Restoration
    @MainActor
    private func restorePosterImages(
        from sourceURL: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        guard let destinationURL = Preferences.posterImagesFolderURL else {
            Self.log("No poster images destination configured, skipping poster restoration")
            return
        }

        // The enumeration and every copy run off the main actor: a full library is
        // thousands of files, and on the main actor the restore sheet's spinner froze for
        // the whole pass. Nothing here touches actor state; `progress` is @Sendable.
        try await Task.detached(priority: .userInitiated) {
            try Self.copyPosterImages(from: sourceURL, to: destinationURL, progress: progress)
        }.value
    }

    private nonisolated static func copyPosterImages(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        let fm = FileManager.default

        // Ensure destination exists
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        // Enumerate files, skipping hidden items and sub-directories.
        guard let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            Self.log("Could not enumerate poster files at \(sourceURL.path(percentEncoded: false))")
            return
        }

        let files = enumerator.allObjects.compactMap { $0 as? URL }
        let totalFiles = files.count

        guard totalFiles > 0 else {
            Self.log("No poster files found in backup")
            return
        }

        Self.log("Restoring \(totalFiles) poster images...")

        var copiedCount = 0
        var skippedCount = 0

        for (index, fileURL) in files.enumerated() {
            let filename = fileURL.lastPathComponent

            // --- Path-traversal guard ---
            // A well-formed poster filename is exactly "<UUID>.jpg" where the UUID
            // portion is a canonical UUID string (36 chars, 4 hyphens, hex digits).
            // Filenames that do not match — including any containing path separators,
            // dot-dot sequences, or non-JPEG extensions — are silently skipped.
            // This prevents a crafted backup from writing arbitrary files outside the
            // PosterImages directory.
            let ext = fileURL.pathExtension.lowercased()
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            guard ext == "jpg",
                  UUID(uuidString: baseName) != nil,
                  !filename.contains("/"),
                  !filename.contains("\\") else {
                Self.log("WARNING: Skipping poster file with unexpected name '\(filename)' — must be <UUID>.jpg")
                skippedCount += 1
                let fileProgress = 0.8 + (0.2 * Double(index + 1) / Double(totalFiles))
                progress?(fileProgress, "Restoring poster images... \(index + 1)/\(totalFiles)")
                continue
            }

            // Build destination using only the validated filename component — never
            // using the source URL's full path — so the destination is always inside
            // the PosterImages folder regardless of the source structure.
            let destFileURL = destinationURL.appendingPathComponent(filename)

            // Remove existing file if present
            if fm.fileExists(atPath: destFileURL.path(percentEncoded: false)) {
                try? fm.removeItem(at: destFileURL)
            }

            // Copy file
            do {
                try fm.copyItem(at: fileURL, to: destFileURL)
                copiedCount += 1
            } catch {
                Self.log("WARNING: Failed to copy poster '\(filename)': \(error.localizedDescription)")
                skippedCount += 1
            }

            let fileProgress = 0.8 + (0.2 * Double(index + 1) / Double(totalFiles))
            progress?(fileProgress, "Restoring poster images... \(index + 1)/\(totalFiles)")
        }

        Self.log("Poster restore complete: \(copiedCount) copied, \(skippedCount) skipped")
    }

    // MARK: - Validation
    private func validateBackup(_ backup: ParsedBackup) throws {
        // NOTE: Format and version are already validated by DBImporter.parseBackupFile —
        // it throws DBImporterError.unsupportedFormat / .unsupportedVersion before a
        // ParsedBackup is ever constructed. The checks here would be unreachable.
        // This method now focuses on the one useful structural check: manifest vs actual counts.

        // Verify object counts match manifest (warn on mismatches, don't throw)
        var actualCounts: [String: Int] = [:]
        for obj in backup.objects {
            actualCounts[obj.entityName, default: 0] += 1
        }

        var hasMismatch = false
        for (entity, expectedCount) in backup.manifest {
            let actualCount = actualCounts[entity] ?? 0
            if actualCount != expectedCount {
                Self.log("WARNING: Object count mismatch for \(entity): expected \(expectedCount), found \(actualCount)")
                hasMismatch = true
            }
        }
        
        if hasMismatch {
            Self.log("Continuing restoration despite manifest mismatches (may skip malformed objects)")
        }
    }

    // MARK: - Object Creation
    private func createFilm(from parsed: ParsedObject, context: ModelContext) throws -> Film {
        let props = parsed.properties
        
        // Create safe parser with entity context
        var parser = SafeValueParser(
            properties: props,
            entityName: "Film",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )

        // Parse lastWatched and ensure version codes are stripped
        // (they should never be in lastWatched, only in calendarTable)
        let rawLastWatched = parser.parseString("lastWatched")
        let cleanedLastWatched = extractDatePortion(from: rawLastWatched) ?? rawLastWatched
        
        let film = Film(
            id: try parser.parseRequiredUUID("id"),
            posterUID: parser.parseString("posterUID"),
            name: parser.parseString("name"),
            releaseYear: parser.parseString("releaseYear"),
            userRating: parser.parseInt("userRating"),
            lastWatched: cleanedLastWatched,
            rotationThresholdOverride: parser.parseOptionalInt("rotationThresholdOverride"),
            duration: parser.parseString("duration"),
            viewCount: parser.parseInt("viewCount"),
            calendarTable: parser.parseStringArray("calendarTable"),
            autoAddToQueueOnRotation: parser.parseOptionalInt("autoAddToQueueOnRotation"),
            digitalSource: parser.parseString("digitalSource"),
            digitalVersion: parser.parseString("digitalVersion"),
            subtitles: parser.parseString("subtitles"),
            notes: parser.parseString("notes"),
            numberOfDiscs: parser.parseString("numberOfDiscs"),
            aspectRatio: parser.parseString("aspectRatio"),
            color: parser.parseBool("color", default: true),
            edited: parser.parseBool("edited"),
            editedDuration: parser.parseString("editedDuration"),
            frameRate: parser.parseDouble("frameRate"),
            tags: parser.parseStringArray("tags"),
            externalIdentifiers: parser.parseStringArray("externalIdentifiers"),
            dateAdded: parser.parseString("dateAdded"),
            lastModified: parser.parseString("lastModified"),
            watched: parser.parseBool("watched", default: true),
            specialSorting: parser.parseStringArray("specialSorting"),
            alternateTitle: parser.parseStringArray("alternateTitle"),
            hofPosition: parser.parseInt("hofPosition"),
            infoComplete: parser.parseBool("infoComplete"),
            comments: parser.parseString("comments"),
            genre: parser.parseString("genre"),
            releaseDate: parser.parseString("releaseDate"),
            descriptionText: parser.parseString("descriptionText"),
            rating: parser.parseString("rating"),
            studio: parser.parseStringArray("studio"),
            cast: parser.parseStringArray("cast"),
            directors: parser.parseStringArray("directors"),
            producers: parser.parseStringArray("producers"),
            executiveProducers: parser.parseStringArray("executiveProducers"),
            screenwriters: parser.parseStringArray("screenwriters"),
            encodingTool: parser.parseStringArray("encodingTool"),
            libraryHBRFValue: parser.parseInt("libraryHBRFValue"),
            composer: parser.parseStringArray("composer"),
            sortName: parser.parseString("sortName"),
            releaseUsed: parser.parseString("releaseUsed"),
            tools: parser.parseStringArray("tools"),
            editedHBRFValue: parser.parseInt("editedHBRFValue"),
            editDate: parser.parseString("editDate"),
            warning: parser.parseStringArray("warning"),
            descriptionNotes: parser.parseString("descriptionNotes"),
            notesOnAudioTiming: parser.parseStringArray("notesOnAudioTiming"),
            specialAudioNotes: parser.parseStringArray("specialAudioNotes"),
            notesArray: parser.parseStringArray("notesArray"),
            handbrakeFrames: parser.parseStringArray("handbrakeFrames"),
            correspondingTimecodes: parser.parseStringArray("correspondingTimecodes")
        )

        context.insert(film)

        // Log any fields present in the backup that were not consumed by the
        // current schema. These are legacy fields dropped during schema evolution.
        // No action is required — they are silently discarded.
        let droppedFields = props.keys.filter { !parser.accessedKeys.contains($0) }
            .sorted()
        if !droppedFields.isEmpty {
            Self.log("Schema evolution: dropping \(droppedFields.count) unrecognized field(s) from Film '\(parser.parseString("name"))': \(droppedFields.joined(separator: ", "))")
        }

        return film
    }

    private func createListObject(from parsed: ParsedObject, context: ModelContext) throws -> ListObject {
        let props = parsed.properties
        
        var parser = SafeValueParser(
            properties: props,
            entityName: "ListObject",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )

        let listID = try parser.parseRequiredUUID("listID")
        let rawName = parser.parseString("listName")

        // Internal Film Queue lists are identified by their fixed UUIDs. Restore them
        // with their canonical name and display order verbatim, bypassing the reserved-name
        // renaming below (which is intended only for user lists that happen to collide).
        let resolvedName: String
        let displayOrder: Int
        if let section = FilmQueueSection(listID: listID) {
            resolvedName = section.displayName
            displayOrder = FilmQueue.displayOrder(for: section)
        } else {
            // Resolve the list name, renaming if it collides with a smart list name, an
            // internal Film Queue name, or a list already restored from this same backup.
            resolvedName = resolveListName(rawName)
            if resolvedName != rawName {
                Self.log("NOTE: Restored list '\(rawName)' renamed to '\(resolvedName)' to avoid a list name collision")
            }
            displayOrder = parser.parseInt("displayOrder")
        }

        let list = ListObject(
            listID: listID,
            listName: resolvedName,
            viewStyle: parser.parseString("viewStyle"),
            sortFilterOptions: parser.parseStringArray("sortFilterOptions"),
            displayOrder: displayOrder
        )

        context.insert(list)
        return list
    }

    /// Returns a list name that collides with nothing: not a smart list name, not an
    /// internal Film Queue name, and not a name already claimed by a list restored earlier
    /// in this same pass.
    ///
    /// The duplicate-name half matters because a backup is not a trusted input. It may have
    /// been written by a build that allowed duplicate names, hand-edited, or merged from
    /// two libraries — and two user lists sharing a name are indistinguishable in every
    /// surface that shows a list by name ("Add to List", "Show in List", the Right
    /// Sidebar's List Membership table, the sidebar rows). Restoring is the one moment the
    /// app can quietly correct that, so it does, using the same " 1", " 2" progression
    /// `ListManager.generateUniqueName` applies when a user creates or renames a list.
    ///
    /// A restore rebuilds the store from empty, so the only names that can be in the way
    /// are the reserved ones and the ones this pass has already assigned — hence the
    /// per-instance claim set rather than a lookup against a live library.
    ///
    /// The three internal Film Queue lists never reach this method (they are matched by
    /// their fixed UUIDs and keep their canonical names verbatim), and they do not need to
    /// register a claim: `FilmQueue.isReservedName` rejects their names here regardless of
    /// the order the backup happens to list its objects in.
    private func resolveListName(_ name: String) -> String {
        func isTaken(_ candidate: String) -> Bool {
            SmartListType.isReservedName(candidate)
                || FilmQueue.isReservedName(candidate)
                || claimedListNames.contains(candidate.lowercased())
        }

        var resolved = name
        if isTaken(resolved) {
            var counter = 1
            repeat {
                resolved = "\(name) \(counter)"
                counter += 1
            } while isTaken(resolved)
        }

        claimedListNames.insert(resolved.lowercased())
        return resolved
    }

    private func createImportSession(from parsed: ParsedObject, context: ModelContext) throws -> ImportSession {
        let props = parsed.properties
        
        var parser = SafeValueParser(
            properties: props,
            entityName: "ImportSession",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )

        let session = ImportSession(
            id: try parser.parseRequiredUUID("id"),
            sessionDate: parser.parseDate("sessionDate"),
            importType: parser.parseString("importType"),
            totalItems: parser.parseInt("totalItems"),
            successCount: parser.parseInt("successCount"),
            errorCount: parser.parseInt("errorCount"),
            duplicateCount: parser.parseInt("duplicateCount"),
            updatedCount: parser.parseInt("updatedCount"),
            notFoundCount: parser.parseInt("notFoundCount"),
            errorFileNames: parser.parseStringArray("errorFileNames"),
            addedTitles: parser.parseStringArray("addedTitles"),
            updatedTitles: parser.parseStringArray("updatedTitles"),
            duplicateTitles: parser.parseStringArray("duplicateTitles"),
            isCompleted: parser.parseBool("isCompleted"),
            isCanceled: parser.parseBool("isCanceled")
        )

        context.insert(session)
        return session
    }

    /// Restores the saved searches, in backup order, once every list has its final name.
    ///
    /// A saved search's name is a `#list` target, in one namespace with every list, smart
    /// list, Queue section, Recents tab and report (SavedSearchName), and two entries with
    /// one key would both answer the same token. The app refuses such a name when a search
    /// is saved; a backup is not a trusted input, and one made before a built-in name
    /// existed can hold a search that now takes it. Lists keep their names (resolveListName
    /// has settled them) and the search is renamed instead, " 2", " 3"… as the Save sheet
    /// names one. A second row with an ID already restored is skipped.
    ///
    /// The stored query is kept exactly as backed up, rules this version cannot read
    /// included: they are logged here, and the search needs review (SavedSearchStore) at
    /// every launch until the user saves it, which is what replaces them.
    private func createSavedSearches(from objects: [ParsedObject], lists: [ListObject], context: ModelContext) {
        guard !objects.isEmpty else { return }
        let coordinator = dataCoordinator ?? AppDelegate.dataCoordinator
        var claims = coordinator?.listNameClaims(includingUserLists: false)
            ?? SmartListType.allCases.map { .init(name: $0.rawValue, kind: .smartList) }
                + FilmQueueSection.allCases.map { .init(name: $0.rawValue, kind: .filmQueue) }
        claims += lists.map { .init(name: $0.listName, kind: .userList) }
        var restoredIDs: Set<UUID> = []

        for obj in objects {
            do {
                guard let search = try createSavedSearch(from: obj, claims: claims, skipping: restoredIDs,
                                                         context: context) else { continue }
                restoredIDs.insert(search.searchID)
                claims.append(.init(name: search.name, kind: .savedSearch))
            } catch {
                Self.log("WARNING: Skipping malformed SavedSearchObject \(obj.exportID): \(error.localizedDescription)")
            }
        }
    }

    /// The restored row, or nil (logged) when its ID is in `restoredIDs` already.
    private func createSavedSearch(from parsed: ParsedObject, claims: [SavedSearchName.Claim],
                                   skipping restoredIDs: Set<UUID>,
                                   context: ModelContext) throws -> SavedSearchObject? {
        let props = parsed.properties
        var parser = SafeValueParser(
            properties: props,
            entityName: "SavedSearchObject",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )
        let searchID = try parser.parseRequiredUUID("searchID")
        guard !restoredIDs.contains(searchID) else {
            Self.log("WARNING: Skipping SavedSearchObject \(parsed.exportID): its ID was already restored")
            return nil
        }
        let rawName = parser.parseString("name")
        let name = SavedSearchName.available(rawName, claims: claims)
        if name != rawName {
            Self.log("NOTE: Restored saved search \"\(rawName)\" renamed to \"\(name)\" — its name is already a #list target")
        }
        let queryJSON = parser.parseString("queryJSON")
        if let decoded = SavedSearchCodec.decode(queryJSON) {
            for token in decoded.dropped {
                Self.log("Saved search \"\(name)\": kept \(token.syntax), which this version cannot read — the search needs review")
            }
        } else {
            Self.log("Saved search \"\(name)\": kept an unreadable query — the search needs review")
        }
        let search = SavedSearchObject(
            searchID: searchID,
            name: name,
            queryJSON: queryJSON,
            displayOrder: parser.parseInt("displayOrder"),
            dateCreated: parser.parseDate("dateCreated"),
            dateModified: parser.parseDate("dateModified"))
        context.insert(search)
        return search
    }

    // MARK: - Settings Creation
    // Creates a SettingsObject from parsed backup data with robust error handling.
    // This method handles schema evolution gracefully - missing fields get defaults,
    // extra fields are ignored, malformed data is caught and logged.
    private func createSettingsObject(from obj: ParsedObject, context: ModelContext) throws -> SettingsObject {
        let props = obj.properties
        
        var parser = SafeValueParser(
            properties: props,
            entityName: "SettingsObject",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )
        
        // Create settings object with singleton ID
        let settings = SettingsObject(
            snapshotID: SettingsObject.singletonID,
            version: SettingsObject.currentVersion,
            lastSyncDate: Date()  // Use current date for restoration
        )
        
        // GENERAL PREFERENCES
        settings.confirmGalleryDelete = parser.parseOptionalBool("confirmGalleryDelete")
        settings.confirmListEdits = parser.parseOptionalBool("confirmListEdits")
        settings.listEditScope = parser.parseOptionalInt("listEditScope")
        settings.confirmReleaseDelete = parser.parseOptionalBool("confirmReleaseDelete")
        settings.largeGalleryGrid = parser.parseOptionalBool("largeGalleryGrid")
        settings.showStatusBar = parser.parseOptionalBool("showStatusBar")
        settings.rememberRightSidebarTab = parser.parseOptionalBool("rememberRightSidebarTab")
        settings.rememberRightSidebarReleasesFilter = parser.parseOptionalBool("rememberRightSidebarReleasesFilter")
        settings.autoExpandRightSidebarTables = parser.parseOptionalBool("autoExpandRightSidebarTables")
        settings.additionalCalTableDetails = parser.parseOptionalBool("additionalCalTableDetails")
        settings.showReleasesSummaryTable = parser.parseOptionalBool("showReleasesSummaryTable")
        settings.iCalIntegration = parser.parseOptionalBool("iCalIntegration")
        settings.manualExtQuery = parser.parseOptionalBool("manualExtQuery")
        settings.smartLists = parser.parseOptionalBool("smartLists")
        settings.excludeQueuedFromUpForRotation = parser.parseOptionalBool("excludeQueuedFromUpForRotation")
        settings.maintainSelectionOnSearchExit = parser.parseOptionalBool("maintainSelectionOnSearchExit")
        settings.showSearchSuggestions = parser.parseOptionalBool("showSearchSuggestions")
        settings.showRecentSearches = parser.parseOptionalBool("showRecentSearches")
        settings.showInfoComplete = parser.parseOptionalBool("showInfoComplete")
        settings.performBackupAtLaunch = parser.parseOptionalBool("performBackupAtLaunch")
        settings.defaultRotationThreshold = parser.parseOptionalInt("defaultRotationThreshold")
        
        // IMPORT PREFERENCES
        settings.importScanSubfolders = parser.parseOptionalBool("importScanSubfolders")
        settings.fuzzyImportMatching = parser.parseOptionalBool("fuzzyImportMatching")
        settings.fuzzyImportYearMatching = parser.parseOptionalBool("fuzzyImportYearMatching")
        settings.overrideSortNameField = parser.parseOptionalBool("overrideSortNameField")
        settings.allowUpdatesForDuplicateImports = parser.parseOptionalBool("allowUpdatesForDuplicateImports")
        settings.allowUpdatesForDuplicateRatings = parser.parseOptionalBool("allowUpdatesForDuplicateRatings")
        
        // EXPORT PREFERENCES
        settings.exportPosterImages = parser.parseOptionalBool("exportPosterImages")
        settings.prunePosterImages = parser.parseOptionalBool("prunePosterImages")
        settings.exportUserSettings = parser.parseOptionalBool("exportUserSettings")
        
        // UI STATE PREFERENCES
        settings.maintainScrollPositionOnViewSwitch = parser.parseOptionalBool("maintainScrollPositionOnViewSwitch")
        settings.rememberTabSelection = parser.parseOptionalBool("rememberTabSelection")
        settings.tabRememberScope = parser.parseOptionalInt("tabRememberScope")
        // Note: "rememberRecentsTab" and "rememberReportsTab" are intentionally not
        // restored — they were superseded by rememberTabSelection/tabRememberScope
        // above. Backups containing these keys (exported prior to consolidation) are
        // silently forward-compatible; the keys are simply ignored during restore.
        settings.lastRecentsCategory = parser.parseOptionalString("lastRecentsCategory")
        settings.lastReportsCategory = parser.parseOptionalString("lastReportsCategory")
        settings.rememberImportsTab = parser.parseOptionalBool("rememberImportsTab")
        settings.lastImportsCategory = parser.parseOptionalString("lastImportsCategory")
        settings.rememberSortFilterSelections = parser.parseOptionalBool("rememberSortFilterSelections")
        settings.confirmFilmQueueAdd = parser.parseOptionalBool("confirmFilmQueueAdd")
        settings.notifyAboutNewReleases = parser.parseOptionalBool("notifyAboutNewReleases")
        settings.onlyNotifyForWishlisted = parser.parseOptionalBool("onlyNotifyForWishlisted")
        settings.queueIsDropTarget = parser.parseOptionalBool("queueIsDropTarget")
        settings.queueSectionOnDrop = parser.parseOptionalInt("queueSectionOnDrop")
        settings.strictFramesTableChecking = parser.parseOptionalBool("strictFramesTableChecking")
        settings.showWatchDetailsAnnotationGlyphs = parser.parseOptionalBool("showWatchDetailsAnnotationGlyphs")
        settings.atvq = parser.parseOptionalBool("atvq")
        // Note: "rememberWindowDimensions" is intentionally not restored — the preference
        // was never implemented and has been removed. Backups containing this key are
        // silently forward-compatible; the key is simply ignored during restore.
        
        // ADVANCED PREFERENCES
        settings.loggingEnabled = parser.parseOptionalBool("loggingEnabled")
        
        // COMPLEX PREFERENCES (JSON)
        settings.selectedSortOptionsJSON = parser.parseOptionalString("selectedSortOptionsJSON")
        settings.ignoredDuplicatePairsJSON = parser.parseOptionalString("ignoredDuplicatePairsJSON")
        
        context.insert(settings)
        return settings
    }

    private func createListMembership(
        from parsed: ParsedObject,
        context: ModelContext,
        filmByID: [UUID: Film],
        listByID: [UUID: ListObject]
    ) throws -> ListMembership? {
        let props = parsed.properties
        
        var parser = SafeValueParser(
            properties: props,
            entityName: "ListMembership",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )

        // Resolve filmID and listID through SafeValueParser so that NSNull, whitespace,
        // and type-mismatch cases are all caught, logged, and handled consistently.
        let filmUUID: UUID
        let listUUID: UUID
        do {
            filmUUID = try parser.parseRequiredRelationshipUUID("filmID")
            listUUID = try parser.parseRequiredRelationshipUUID("listID")
        } catch {
            logMalformed("ListMembership \(parsed.exportID) has invalid filmID or listID — skipping: \(error.localizedDescription)")
            return nil
        }

        // Look up the actual film and list objects by UUID.
        guard let film = filmByID[filmUUID],
              let list = listByID[listUUID] else {
            // Referenced objects absent from this backup — skip silently (not a data error).
            return nil
        }

        // Create membership with actual objects
        let membership = ListMembership(
            id: try parser.parseRequiredUUID("id"),
            film: film,
            list: list,
            dateAdded: parser.parseDate("dateAdded"),
            sortOrder: parser.parseInt("sortOrder")
        )

        context.insert(membership)
        return membership
    }

    private func createRelease(
        from parsed: ParsedObject,
        context: ModelContext,
        filmByID: [UUID: Film]
    ) throws -> Release? {
        let props = parsed.properties
        
        var parser = SafeValueParser(
            properties: props,
            entityName: "Release",
            logMalformed: { [weak self] in self?.logMalformed($0) },
            recordMissing: { [weak self] in self?.recordMissingField($0) },
            checkExists: { [weak self] in self?.propertyExists($0, in: props) ?? false }
        )

        // Resolve filmID through SafeValueParser so that NSNull, whitespace,
        // and type-mismatch cases are all caught and logged consistently.
        let filmUUID: UUID
        do {
            filmUUID = try parser.parseRequiredRelationshipUUID("filmID")
        } catch {
            logMalformed("Release \(parsed.exportID) has invalid filmID — skipping: \(error.localizedDescription)")
            return nil
        }

        // Look up the actual film object by UUID.
        guard let film = filmByID[filmUUID] else {
            // Referenced film absent from this backup — skip silently (not a data error).
            return nil
        }

        // MARK: Base release year — dropped unless it can be ordered
        //
        // `baseReleaseYear` names the earliest permutation the release reissues, so it is
        // meaningful only as a value strictly BELOW the release date's year. Two shapes a backup can
        // carry are not: a base year with no release year to qualify (orphaned), and a base
        // year at or after its release year (inverted). Neither is producible by the Steppers
        // — see _ReleaseYearRow — but a hand-edited XML, a record written before the ordering
        // rule existed, or a partially-written export can all present one.
        //
        // Dropped HERE, at the boundary, rather than only repaired later. The FilmSheet's
        // loadExistingReleases repairs both shapes when a card is built, but that runs only
        // for a film whose sheet is opened, and its correction is not persisted unless the
        // user saves — meanwhile the right sidebar, the releases table, and the reports read
        // the stored value directly and would show a year the app itself calls impossible.
        // Refusing the value at parse time keeps a single answer in the store from the moment
        // the restore lands. The card-layer repair stays as the backstop for records already
        // in a library.
        //
        // Only the optional field is dropped; `releaseDate` is preserved verbatim, exactly as
        // the ordering rule treats the pair everywhere else. Non-numeric or empty values fall
        // through untouched — `parseString` has already normalized those to "", and a
        // malformed year is not this guard's business.
        //
        // `releaseDate` was `releaseYear` until full release dates were introduced. A backup
        // written before then carries the old key, whose every value is a valid year-only
        // release date, so it is taken as-is. Like every other string field, the value is
        // otherwise preserved verbatim; ReleaseDateValue decides how each reader interprets it.
        //
        // The one exception: a well-formed full date before its format's floor (a Blu-ray
        // dated 2001.05.05) is dropped here, so the library never holds a date the app itself
        // calls impossible — the same reasoning as the base-year guard below. Year-only values
        // are exempt; see ReleaseDateValue, "Validity is per format". Dropped BEFORE the
        // base-year guard, so a base year left with nothing to qualify is dropped with it.
        let parsedFormat          = parser.parseString("format")
        let rawReleaseDate        = parser.parseString("releaseDate", legacyName: "releaseYear")
        let parsedReleaseDate: String = {
            guard ReleaseDateValue.isFullDateBelowFloor(rawReleaseDate, format: parsedFormat) else {
                return rawReleaseDate
            }
            logMalformed(
                "Release \(parsed.exportID) has release date \(rawReleaseDate), before the " +
                "\(ReleaseFormat.yearFloor(for: parsedFormat)) floor for its format " +
                "'\(parsedFormat)' — release date dropped."
            )
            return ""
        }()
        let parsedBaseReleaseYear = parser.parseString("baseReleaseYear")
        let baseReleaseYear: String = {
            guard let base = Int(parsedBaseReleaseYear) else { return parsedBaseReleaseYear }
            // The ordering is between YEARS: the base year against the release date's year,
            // whichever shape the date takes. (`Int(_:)` on a full date is nil, and would
            // drop every base year beside one as orphaned.)
            guard let year = ReleaseDateValue.year(of: parsedReleaseDate, format: parsedFormat) else {
                logMalformed(
                    "Release \(parsed.exportID) has base release year \(base) but no release " +
                    "year — base year dropped."
                )
                return ""
            }
            guard base >= year else { return parsedBaseReleaseYear }
            logMalformed(
                "Release \(parsed.exportID) has base release year \(base) at or after its " +
                "release year \(year) — base year dropped."
            )
            return ""
        }()

        let release = Release(
            id: try parser.parseRequiredUUID("id"),
            studio: parser.parseString("studio"),
            releaseDate: parsedReleaseDate,
            baseReleaseYear: baseReleaseYear,
            purchased: parser.parseBool("purchased"),
            wishlist: parser.parseInt("wishlist", default: 0),
            format: parsedFormat,
            includedVersions: parser.parseStringArray("includedVersions"),
            independence: parser.parseString("independence"),
            videoFormat: parser.parseString("videoFormat"),
            releaseAspectRatio: parser.parseStringArray("releaseAspectRatio"),
            scanningMethod: parser.parseString("scanningMethod"),
            audioFormat: parser.parseString("audioFormat"),
            audioChannels: parseAudioChannels(props),  // Handles numeric type coercion from DBImporter
            hasSubtitles: parser.parseBool("hasSubtitles"),
            numberOfDiscs: parser.parseInt("numberOfDiscs", default: 1),
            discMultiPack: parser.parseBool("discMultiPack"),
            hasArtwork: parser.parseString("hasArtwork"),
            remastered: parser.parseBool("remastered"),
            nationalOrigin: parser.parseString("nationalOrigin"),
            replicationType: parser.parseString("replicationType"),
            discCapacity: parser.parseStringArray("discCapacity"),
            hasHDR: parser.parseString("hasHDR"),
            masterType: parser.parseString("masterType"),
            regionLock: parser.parseString("regionLock"),
            regionLockBypass: parser.parseBool("regionLockBypass"),
            // Backups written before the two-component format hold one legacy tag.
            marketAvailability: ReleaseMarketAvailability.migrated(
                parser.parseStringArray("marketAvailability")),
            numberOfCopies: parser.parseInt("numberOfCopies"),
            cost: parser.parseDouble("cost"),
            amountSpent: parser.parseDouble("amountSpent"),
            purchaseDate: parser.parseString("purchaseDate"),
            lowestPrice: parser.parseDouble("lowestPrice"),
            lowestPriceDate: parser.parseString("lowestPriceDate"),
            condition: parser.parseString("condition"),
            notes: parser.parseString("notes"),
            dateAdded: parser.parseDate("dateAdded"),
            sortOrder: parser.parseInt("sortOrder"),
            film: film
        )

        context.insert(release)
        return release
    }

    // MARK: - Parsing Helpers
    /// Records when a field is missing from the backup (for schema evolution tracking).
    private func recordMissingField(_ fieldName: String) {
        missingFieldsDetected.insert(fieldName)
        schemaEvolutionOccurred = true
    }

    /// Checks if a property key exists in the properties dictionary.
    /// Returns true if the key exists (even if value is nil/empty), false if key is absent.
    /// This correctly distinguishes between:
    /// - Field present with empty value (key exists in dict) -> returns true
    /// - Field completely missing from backup (key not in dict) -> returns false
    private func propertyExists(_ key: String, in properties: [String: Any]) -> Bool {
        return properties.keys.contains(key)
    }
    
    /// Logs malformed data warnings
    private func logMalformed(_ message: String) {
        Self.log("WARNING: \(message)")
    }
    
    // MARK: - Safe Value Parser
    /// Centralized parser for robust schema evolution support.
    /// Handles missing fields, malformed data, and type mismatches gracefully.
    /// `accessedKeys` accumulates every field name that was read during parsing;
    /// the caller can diff this against the raw properties dictionary to identify
    /// fields present in the backup that the current schema no longer recognizes.
    private struct SafeValueParser {
        let properties: [String: Any]
        let entityName: String
        let logMalformed: (String) -> Void
        let recordMissing: (String) -> Void
        let checkExists: (String) -> Bool

        /// Every key that any parse method has been called with, regardless of
        /// whether the key existed in `properties`. Populated by every mutating
        /// parse call so the caller can detect unrecognized/dropped fields.
        private(set) var accessedKeys: Set<String> = []
        
        // Static ISO 8601 style for date parsing within this nested struct (a Sendable
        // value). Cannot access DBRestorer's instance property from a nested type.
        private static let iso8601Style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
        
        /// The value the defaulted parsers read for `fieldName`, or nil when they should
        /// fall back to their default. Records the key as accessed and, when it is absent
        /// from the backup altogether, as missing (schema evolution). An explicit NSNull
        /// counts as no value.
        private mutating func presentValue(_ fieldName: String) -> Any? {
            accessedKeys.insert(fieldName)
            guard checkExists(fieldName) else {
                recordMissing(fieldName)
                return nil
            }
            guard let value = properties[fieldName], !(value is NSNull) else { return nil }
            return value
        }

        /// The value the optional parsers read for `fieldName`, or nil. An absent key is
        /// not recorded as missing — the field is legitimately optional (or simply
        /// predates this backup) — and a key present but null is the normal representation
        /// of a nil optional: exported as an empty string, parsed back as NSNull by
        /// DBImporter.
        private mutating func optionalValue(_ fieldName: String) -> Any? {
            accessedKeys.insert(fieldName)
            guard let value = properties[fieldName], !(value is NSNull) else { return nil }
            return value
        }

        /// Parse a required UUID - throws if missing or malformed
        mutating func parseRequiredUUID(_ fieldName: String) throws -> UUID {
            accessedKeys.insert(fieldName)
            guard let value = properties[fieldName] else {
                throw DBRestorerError.invalidBackupStructure(
                    "Missing required UUID field '\(fieldName)' in \(entityName)"
                )
            }
            
            if value is NSNull {
                throw DBRestorerError.invalidBackupStructure(
                    "Required UUID field '\(fieldName)' is null in \(entityName)"
                )
            }
            
            // Handle UUID objects directly
            if let uuid = value as? UUID {
                return uuid
            }
            
            // Handle string values
            if let s = value as? String {
                let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let uuid = UUID(uuidString: cleaned) {
                    return uuid
                }
                throw DBRestorerError.invalidBackupStructure(
                    "Invalid UUID format for '\(fieldName)' in \(entityName): '\(cleaned)'"
                )
            }
            
            throw DBRestorerError.invalidBackupStructure(
                "Invalid UUID type for '\(fieldName)' in \(entityName): expected String or UUID, got \(type(of: value))"
            )
        }
        
        /// Parses a field that was renamed: `fieldName` when the backup carries it, else the
        /// pre-rename `legacyName`, else `fieldName`'s default (recorded as missing under the
        /// current name). Whichever key is read is marked accessed, so an older backup's
        /// legacy key is not reported as an unrecognized field — and neither name is recorded
        /// as missing when the other is present, which a renamed field is not.
        mutating func parseString(_ fieldName: String, legacyName: String) -> String {
            if !checkExists(fieldName), checkExists(legacyName) {
                return parseString(legacyName)
            }
            return parseString(fieldName)
        }

        /// Parse string with fallback to default
        mutating func parseString(_ fieldName: String, default defaultValue: String = "") -> String {
            guard let value = presentValue(fieldName) else { return defaultValue }
            
            // Handle string type
            if let s = value as? String {
                return s
            }
            
            // Handle numeric types with conversion
            if let i = value as? Int {
                return String(i)
            }
            if let i64 = value as? Int64 {
                return String(i64)
            }
            if let d = value as? Double {
                if d.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(Int(d))
                }
                return String(d)
            }

            // Booleans and string arrays reaching a String field mean the reader's type
            // inference misread the text — a String field whose content was "true" or
            // "[\"a\",\"b\"]". Backups written by a build that records the declared type no
            // longer land here at all, but every backup written before it still can, and the
            // previous behavior was to fall through to the default and REPLACE the field with
            // an empty string. Reconstructing the text loses nothing but the original
            // formatting, which is strictly better than losing the content.
            if let b = value as? Bool {
                return b ? "true" : "false"
            }
            if let array = value as? [String] {
                if let data = try? JSONEncoder().encode(array),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
            }

            // Malformed data - log and use default
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using default '\(defaultValue)'")
            return defaultValue
        }
        
        /// Parse integer with fallback to default
        mutating func parseInt(_ fieldName: String, default defaultValue: Int = 0) -> Int {
            guard let value = presentValue(fieldName) else { return defaultValue }
            
            // Handle integer types
            if let i = value as? Int {
                return i
            }
            if let i64 = value as? Int64 {
                return Int(i64)
            }
            
            // Handle boolean coercion (schema evolution: field changed from Bool to Int).
            // DBImporter.parsePropertyValue returns a native Bool for "true"/"false" literals,
            // so an old backup restoring into a new Int field lands here. true → 1, false → 0.
            // The direction (Int from Bool) is the only one that needs handling here; the
            // reverse (parseBool receiving an Int) is already covered in parseBool.
            if let b = value as? Bool {
                return b ? 1 : 0
            }
            
            // Handle string conversion
            if let s = value as? String {
                if let i = Int(s) {
                    return i
                }
                // Invalid string format - log and use default
                logMalformed("Field '\(fieldName)' in \(entityName) has invalid integer format '\(s)', using default \(defaultValue)")
                return defaultValue
            }
            
            // Handle double conversion (truncate)
            if let d = value as? Double {
                return Int(d)
            }
            
            // Malformed data - log and use default
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using default \(defaultValue)")
            return defaultValue
        }
        
        /// Parse double with fallback to default
        mutating func parseDouble(_ fieldName: String, default defaultValue: Double = 0.0) -> Double {
            guard let value = presentValue(fieldName) else { return defaultValue }
            
            // Handle double type
            if let d = value as? Double {
                return d
            }
            
            // Handle integer conversion
            if let i = value as? Int {
                return Double(i)
            }
            if let i64 = value as? Int64 {
                return Double(i64)
            }
            
            // Handle string conversion
            if let s = value as? String {
                if let d = Double(s) {
                    return d
                }
                // Invalid string format - log and use default
                logMalformed("Field '\(fieldName)' in \(entityName) has invalid double format '\(s)', using default \(defaultValue)")
                return defaultValue
            }
            
            // Malformed data - log and use default
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using default \(defaultValue)")
            return defaultValue
        }
        
        /// Parse boolean with fallback to default
        mutating func parseBool(_ fieldName: String, default defaultValue: Bool = false) -> Bool {
            guard let value = presentValue(fieldName) else { return defaultValue }
            
            // Handle boolean type
            if let b = value as? Bool {
                return b
            }
            
            // Handle string conversion
            if let s = value as? String {
                if s == "true" || s == "1" {
                    return true
                }
                if s == "false" || s == "0" {
                    return false
                }
                // Invalid string format - log and use default
                logMalformed("Field '\(fieldName)' in \(entityName) has invalid boolean format '\(s)', using default \(defaultValue)")
                return defaultValue
            }
            
            // Handle integer conversion
            if let i = value as? Int {
                return i != 0
            }
            if let i64 = value as? Int64 {
                return i64 != 0
            }
            
            // Malformed data - log and use default
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using default \(defaultValue)")
            return defaultValue
        }
        
        /// Parse string array with fallback to empty array
        mutating func parseStringArray(_ fieldName: String) -> [String] {
            guard let value = presentValue(fieldName) else { return [] }
            
            // Handle array type
            if let arr = value as? [String] {
                return arr
            }
            
            // Handle string representation of array
            if let s = value as? String {
                if s.isEmpty || s == "[]" {
                    return []
                }
                
                // Try to decode JSON array
                if s.hasPrefix("[") && s.hasSuffix("]") {
                    if let data = s.data(using: .utf8),
                       let arr = try? JSONDecoder().decode([String].self, from: data) {
                        return arr
                    }
                    // Invalid JSON - log and use single-element array
                    logMalformed("Field '\(fieldName)' in \(entityName) has invalid JSON array format, treating as single element")
                }
                
                // Fallback: single non-empty string becomes single-element array
                return [s]
            }
            
            // Malformed data - log and use empty array
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using empty array")
            return []
        }
        
        /// Parse date with fallback to current date
        mutating func parseDate(_ fieldName: String) -> Date {
            guard let value = presentValue(fieldName) else { return Date() }
            
            // Handle Date type directly
            if let date = value as? Date {
                return date
            }
            
            // Handle string with ISO8601 parsing
            if let s = value as? String {
                // Leading whitespace skipped, as the ISO8601DateFormatter this replaced skipped it.
                if let date = try? Self.iso8601Style.parse(String(s.drop(while: \.isWhitespace))) {
                    return date
                }
                // Invalid date format - log and use current date
                logMalformed("Field '\(fieldName)' in \(entityName) has invalid date format '\(s)', using current date")
                return Date()
            }
            
            // Malformed data - log and use current date
            logMalformed("Field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using current date")
            return Date()
        }
        
        /// Parse optional integer - returns nil for missing/malformed
        mutating func parseOptionalInt(_ fieldName: String) -> Int? {
            guard let value = optionalValue(fieldName) else { return nil }
            
            if let i = value as? Int {
                return i
            }
            if let i64 = value as? Int64 {
                return Int(i64)
            }
            if let s = value as? String {
                if s.isEmpty || s == "null" || s == "nil" {
                    return nil
                }
                if let i = Int(s) {
                    return i
                }
                // Invalid format - log and return nil
                logMalformed("Optional field '\(fieldName)' in \(entityName) has invalid integer format '\(s)', using nil")
                return nil
            }
            
            // Malformed data - log and return nil
            logMalformed("Optional field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using nil")
            return nil
        }
        
        /// Parse optional boolean - returns nil for missing/malformed
        mutating func parseOptionalBool(_ fieldName: String) -> Bool? {
            guard let value = optionalValue(fieldName) else { return nil }
            
            if let b = value as? Bool {
                return b
            }
            if let s = value as? String {
                if s == "true" || s == "1" {
                    return true
                }
                if s == "false" || s == "0" {
                    return false
                }
                // Invalid format or null string - return nil
                if s.isEmpty || s == "null" || s == "nil" {
                    return nil
                }
                // Invalid format - log and return nil
                logMalformed("Optional field '\(fieldName)' in \(entityName) has invalid boolean format '\(s)', using nil")
                return nil
            }
            if let i = value as? Int {
                return i != 0
            }
            
            // Malformed data - log and return nil
            logMalformed("Optional field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using nil")
            return nil
        }
        
        /// Parse optional string - returns nil for missing/empty
        mutating func parseOptionalString(_ fieldName: String) -> String? {
            guard let value = optionalValue(fieldName) else { return nil }
            
            if let s = value as? String {
                return s.isEmpty ? nil : s
            }
            
            // Malformed data - log and return nil
            logMalformed("Optional field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)), using nil")
            return nil
        }

        /// Parse an optional UUID — returns nil when the field is absent or null (e.g., parentReleaseID
        /// on a top-level release), and logs a warning when the field is present but malformed.
        /// Unlike parseRequiredUUID, both absence and null are valid "no value" signals.
        mutating func parseOptionalUUID(_ fieldName: String) -> UUID? {
            guard let value = optionalValue(fieldName) else { return nil }

            if let uuid = value as? UUID { return uuid }

            if let s = value as? String {
                let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty { return nil }
                if let uuid = UUID(uuidString: cleaned) { return uuid }
                logMalformed("Optional UUID field '\(fieldName)' in \(entityName) has invalid format '\(cleaned)' — treating as absent")
                return nil
            }

            logMalformed("Optional UUID field '\(fieldName)' in \(entityName) has unexpected type \(type(of: value)) — treating as absent")
            return nil
        }

        /// Parse a required cross-entity reference UUID (e.g., filmID, listID, parentReleaseID
        /// when the presence of the field is non-optional in context). Throws on missing or
        /// malformed values, identical to parseRequiredUUID.
        /// Kept as a separate method because relationship reference fields are semantically
        /// distinct from primary-key fields: they are foreign keys whose validity must be
        /// verified against a lookup map by the caller and are never persisted directly on
        /// the entity being built.
        mutating func parseRequiredRelationshipUUID(_ fieldName: String) throws -> UUID {
            accessedKeys.insert(fieldName)
            guard let value = properties[fieldName] else {
                throw DBRestorerError.invalidBackupStructure(
                    "Missing required relationship UUID '\(fieldName)' in \(entityName)")
            }

            if value is NSNull {
                throw DBRestorerError.invalidBackupStructure(
                    "Required relationship UUID '\(fieldName)' is null in \(entityName)")
            }

            if let uuid = value as? UUID { return uuid }

            if let s = value as? String {
                let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let uuid = UUID(uuidString: cleaned) { return uuid }
                throw DBRestorerError.invalidBackupStructure(
                    "Invalid UUID format for relationship field '\(fieldName)' in \(entityName): '\(cleaned)'")
            }

            throw DBRestorerError.invalidBackupStructure(
                "Invalid type for relationship UUID '\(fieldName)' in \(entityName): expected String, got \(type(of: value))")
        }
    }
    
    // MARK: - Release Parsing Helpers

    /// Parses audioChannels, handling the case where DBImporter converts numeric-looking
    /// strings like "5.1" or "7.1" to Double values rather than preserving them as strings.
    private func parseAudioChannels(_ props: [String: Any]) -> String {
        // Try new audioChannels field first
        // Note: DBImporter may have converted numeric-looking strings (e.g., "5.1", "7.1")
        // to Double values, so we need to handle both String and numeric types
        if let audioChannels = props["audioChannels"] {
            // Handle String type directly
            if let stringValue = audioChannels as? String, !stringValue.isEmpty {
                return stringValue
            }
            // Handle Double type (e.g., 5.1, 7.1 parsed as numbers).
            // Fmt.fixed formats without a locale, so the decimal separator is always "."
            // whatever the user's system locale ("5,1" would corrupt the field).
            if let doubleValue = audioChannels as? Double {
                return Fmt.fixed(doubleValue, 1)
            }
            // Handle Int64 type (e.g., 5, 7 parsed as integers)
            if let intValue = audioChannels as? Int64 {
                return String(intValue)
            }
            // Handle Int type
            if let intValue = audioChannels as? Int {
                return String(intValue)
            }
        }
        return ""
    }

    // MARK: - Application Restart
    /// Relaunches the application and exits the current process immediately via exit(0).
    ///
    /// Used by both the "Restore from Backup" completion flow (`RestoreViewModel`) and the
    /// "Create New Library" completion flow (`DatabaseErrorAlertModifier`) after writing a
    /// new persistent store to disk. The `exit(0)` bypass is intentional — the normal
    /// AppKit termination path would attempt to save stale SwiftData objects and flush
    /// caches that reference the old, now-replaced store, which is both incorrect and
    /// potentially harmful. Spawning a new instance via `open` before exit ensures the
    /// application reopens cleanly against the freshly written store.
    @MainActor
    static func restartApplication() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "sleep 0.1; open \"\(bundlePath)\""]
        do {
            try task.run()
        } catch {
            log("Failed to initiate relaunch: \(error)")
        }
        // Again, immediately before exit: both callers replaced the store, and a cache write
        // already in flight when destroyAndRecreatePersistentStore invalidated could have
        // landed since. Suspension there guarantees no new one has started.
        MemoryStoreCache.shared.invalidateOnDisk()
        // Bypass the normal AppKit termination flow, which would attempt to access
        // stale SwiftData objects and flush caches against the replaced store.
        exit(0)
    }
}

