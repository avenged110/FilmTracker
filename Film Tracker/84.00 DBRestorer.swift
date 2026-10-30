// MARK: - DBRestorer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Restores the Core Data database from a parsed backup file package.

import Foundation
import CoreData

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

    private let container: NSPersistentContainer
    private let importer: DBImporter
    private let dataCoordinator: DataCoordinator?
    private var settingsWereRestored = false

    /// True once the restored library is committed (PendingRestore.commit): the next launch
    /// swaps it in, so the session must relaunch.
    ///
    /// Everything the restore does BEFORE this — parsing, staging the posters, building and
    /// checking the staged store — leaves the library untouched, so a failure there is
    /// recoverable and the session simply carries on. Nothing after it can fail: the
    /// settings, posters and rotation baseline are applied by the launch that swaps the
    /// library in (PendingRestore.applyRestoredExtras), and only if that swap succeeds.
    public private(set) var requiresRestart = false

    init(container: NSPersistentContainer, dataCoordinator: DataCoordinator? = nil,
        importer: DBImporter = DBImporter()) {
        self.container = container
        self.dataCoordinator = dataCoordinator
        self.importer = importer }

    // Restore database from backup package with progress reporting.
    //
    // The restored library is built in a staged store beside the library's own (see
    // PendingRestore) and swapped in at the next launch, so nothing here writes to the store
    // the app has open. A failure before the commit discards the staged store and leaves
    // the library as it was.
    //
    // Not cancellable: the UI's confirmation alert is the last decision point, and the
    // progress sheet that follows has no Cancel button. A hard failure (power loss, kill)
    // before the commit leaves only a staged store, which the next restore discards; after
    // it, the next launch completes the swap.
    @MainActor
    public func restoreFromBackup(
        at packageURL: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        // Reset schema evolution tracking
        missingFieldsDetected.removeAll()
        schemaEvolutionOccurred = false
        settingsWereRestored = false
        requiresRestart = false
        claimedListNames.removeAll()

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

        // Phases 2-4, attempted twice. Every attempt starts from an empty staged store and
        // the parsed backup, so a failure that was transient (a disk hiccup, a check that
        // caught a bad write) heals on the second; one that repeats is reported, and either
        // way nothing has touched the library.
        var lastError: (any Error)?
        for attempt in 1...2 {
            if attempt > 1 {
                Self.log("WARNING: Restore attempt \(attempt - 1) failed (\(lastError.map { "\($0)" } ?? "?")) — rebuilding the staged library from the backup")
                missingFieldsDetected.removeAll()
                schemaEvolutionOccurred = false
                settingsWereRestored = false
                claimedListNames.removeAll()
            }
            do {
                try await stageAndCommit(backup, postersURL: hasPosters ? postersURL : nil, progress: progress)
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        requiresRestart = true

        // The derived caches on disk describe the store about to be replaced, and the live
        // MemoryStore still holds it in memory. Silence the latter first so no throttled
        // save can recreate the files, then delete them so the relaunch reads the new store
        // in full rather than validating a cache the fingerprint cannot tell apart from it.
        // See MemoryStoreCache.invalidateOnDisk.
        (dataCoordinator ?? AppDelegate.dataCoordinator)?
            .suspendCachePersistence(reason: "a restored library replaces this one at relaunch")
        MemoryStoreCache.shared.invalidateOnDisk()

        // Log schema evolution summary if detected
        if schemaEvolutionOccurred {
            Self.log("Schema evolution detected during restoration - older backup successfully migrated")
            Self.log("Missing fields populated with defaults: \(missingFieldsDetected.sorted().joined(separator: ", "))")
        }

        progress?(1.0, "Restoration complete!")
    }

    /// Phase 2, then 3 and 4: opens an empty staged store, stages the posters, and fills,
    /// proves and commits the store. Anything that fails discards the staged store and the
    /// staged posters with it. Posters are staged first so that, once the commit has
    /// happened, nothing is left that can fail.
    private func stageAndCommit(_ backup: ParsedBackup, postersURL: URL?,
                                progress: (@Sendable (Double, String) -> Void)?) async throws {
        // Always a brand-new store with the current model, so a backup restores whatever
        // state the library's own store is in.
        progress?(0.25, "Rebuilding database store...")
        let restoreContainer: NSPersistentContainer
        do {
            restoreContainer = try PendingRestore.makeStagingContainer()
            Self.log("Staged store opened at: \(restoreContainer.storeURL?.lastPathComponent ?? "?")")
        } catch {
            PendingRestore.discard()
            throw DBRestorerError.storeRebuildFailed(
                "Failed to create the restore's store: \(error.localizedDescription)")
        }
        do {
            if let postersURL {
                try await stagePosterImages(from: postersURL, progress: progress)
            }
            try await populateAndCommit(backup, into: restoreContainer, progress: progress)
        } catch {
            PendingRestore.discard()
            throw error
        }
    }

    /// Deletes inserted list memberships missing their film or list and releases missing
    /// their film, and unlinks a release whose parent belongs to another film or has a
    /// parent of its own. Each is logged.
    private func repairStructure(in context: NSManagedObjectContext) {
        var removed = 0, unlinked = 0
        for object in context.insertedObjects where !object.isDeleted {
            if let membership = object as? ListMembership, membership.film == nil || membership.list == nil {
                context.delete(membership); removed += 1
            } else if let release = object as? Release, release.film == nil {
                context.delete(release); removed += 1
            }
        }
        for object in context.insertedObjects where !object.isDeleted {
            guard let release = object as? Release, let parent = release.parentRelease else { continue }
            if parent === release || parent.isDeleted || parent.parentRelease != nil || parent.film !== release.film {
                release.parentRelease = nil; unlinked += 1
            }
        }
        if removed + unlinked > 0 {
            Self.log("WARNING: Repaired the restored library before saving: \(removed) object(s) without their film or list removed, \(unlinked) release link(s) cleared")
        }
    }

    /// Phases 3 and 4: fills the staged store from the parsed backup, saves it, checks what
    /// landed against what was inserted, and commits it.
    private func populateAndCommit(_ backup: ParsedBackup, into restoreContainer: NSPersistentContainer,
                                   progress: (@Sendable (Double, String) -> Void)?) async throws {
        progress?(0.3, "Creating new objects...")

        // Phase 3: Create new context and insert objects (30-70%)
        // The context is opened against the empty staged store, guaranteeing a clean
        // schema and no residual data from the previous database.
        // Main-queue, as this method is MainActor: the population passes below use it
        // directly. Nothing is saved until the single save in Phase 4. Its merge policy
        // resolves SettingsObject's uniqueness constraint: a backup carrying two settings
        // rows restores as one, as the SwiftData model's unique attribute did.
        let context = restoreContainer.makeMainContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        // Lookup dictionaries keyed directly by the model's own UUID. The second pass
        // reads the filmID / listID properties off ParsedObjects, which are UUIDs —
        // keying the dicts by UUID removes the need to reconstruct string prefixes
        // like "Film-<uuid>" at lookup time.
        var filmByID: [UUID: Film] = [:]
        var listByID: [UUID: ListObject] = [:]
        // Populated during the second pass for use in the third-pass hierarchy link step.
        var releaseByID: [UUID: Release] = [:]
        // The IDs restored so far of the entities nothing looks up by ID.
        var sessionIDs: Set<UUID> = []
        var membershipIDs: Set<UUID> = []
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
                    guard keepFirst(film, filmByID[film.id] == nil, film.id, context: context) else { continue }
                    filmByID[film.id] = film
                } catch {
                    Self.log("WARNING: Skipping malformed Film object \(obj.exportID): \(error.localizedDescription)")
                    // Continue processing other objects
                }

            case "ListObject":
                do {
                    let list = try createListObject(from: obj, context: context)
                    guard keepFirst(list, listByID[list.listID] == nil, list.listID, context: context) else { continue }
                    listByID[list.listID] = list
                    // Claimed only for a list that is kept: a repeated ID's copy, taken back
                    // out above, must not push a later list's name to " 1".
                    if FilmQueueSection(listID: list.listID) == nil {
                        claimedListNames.insert(list.listName.lowercased())
                    }
                } catch {
                    Self.log("WARNING: Skipping malformed ListObject \(obj.exportID): \(error.localizedDescription)")
                }

            case "ImportSession":
                do {
                    let session = try createImportSession(from: obj, context: context)
                    _ = keepFirst(session, sessionIDs.insert(session.id).inserted, session.id, context: context)
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
                    if let membership = try createListMembership(from: obj, context: context, filmByID: filmByID, listByID: listByID) {
                        _ = keepFirst(membership, membershipIDs.insert(membership.id).inserted, membership.id, context: context)
                    }
                } catch {
                    Self.log("WARNING: Skipping malformed ListMembership \(obj.exportID): \(error.localizedDescription)")
                }

            case "Release":
                do {
                    if let release = try createRelease(from: obj, context: context, filmByID: filmByID),
                       keepFirst(release, releaseByID[release.id] == nil, release.id, context: context) {
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

            // Core Data fills in the inverse, parentRelease.childReleases, which the
            // FilmSheet's combo-pack logic reads. (The SwiftData build had to append to it
            // by hand: there the inverse could come back empty after a batch of links to
            // unsaved objects.)
            childRelease.parentRelease = parentRelease
        }

        progress?(0.7, "Saving restored data...")

        // Repairs what no valid library holds, before the save makes it permanent. The
        // passes above already refuse to create these; this is the guarantee, so commit's
        // structural check can only fail on something the store itself did.
        repairStructure(in: context)

        // What the passes above inserted, per entity, for the check after the save.
        // Processed first, so a repeated ID that keepFirst took back out is no longer counted.
        context.processPendingChanges()
        var inserted: [String: Int] = [:]
        for object in context.insertedObjects { inserted[object.entity.name ?? "", default: 0] += 1 }

        // Phase 4: Save the new data (70-80%)
        do {
            try context.save()
            Self.log("Restored data saved successfully")
        } catch {
            throw DBRestorerError.restorationFailed("Failed to save restored data: \(error.localizedDescription)")
        }

        // Read back through a fresh context: every inserted row must be in the store.
        // SettingsObject may come back with fewer, by its uniqueness constraint.
        let verify = restoreContainer.makeMainContext()
        for (entity, expected) in inserted {
            let request = NSFetchRequest<any NSFetchRequestResult>(entityName: entity)
            let stored = (try? verify.count(for: request)) ?? -1
            let ok = entity == SettingsObject.entityName ? (1...expected).contains(stored) : stored == expected
            guard ok else {
                throw DBRestorerError.restorationFailed(
                    "The restored library is incomplete: \(stored) of \(expected) \(entity) row(s) were saved.")
            }
        }
        // Settings reach Preferences at the relaunch, after the swap, and only when a
        // coordinator asked for this restore: the harness restores without one so that its
        // live Preferences stay as later scenarios expect them.
        let applySettings = settingsWereRestored && dataCoordinator != nil
        if settingsWereRestored && !applySettings {
            Self.log("NOTE: Settings were restored to the staged store; no coordinator, so they are not applied to Preferences")
        } else if !settingsWereRestored {
            Self.log("NOTE: No settings found in backup or settings were malformed - current settings unchanged")
        }

        do {
            try PendingRestore.commit(restoreContainer, filledBy: context, applySettings: applySettings)
        } catch {
            throw DBRestorerError.restorationFailed(
                "The restored library could not be finalized: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Fresh Database (Public Entry Point)
    /// Stages a fresh, empty store to replace the library's at the next launch. This is the
    /// public entry point used by the "Create New Library" recovery flow when the database
    /// is broken at launch. After this returns successfully the app must restart, which swaps
    /// the empty store in (the broken one is kept as the rollback copy, or moved there).
    ///
    /// - Throws: `DBRestorerError.storeRebuildFailed` if the empty store cannot be staged.
    @MainActor
    public func createFreshDatabase() async throws {
        requiresRestart = false
        do {
            try PendingRestore.commit(try PendingRestore.makeStagingContainer())
        } catch {
            PendingRestore.discard()
            throw DBRestorerError.storeRebuildFailed(
                "Failed to create a new library: \(error.localizedDescription)")
        }
        requiresRestart = true
        (dataCoordinator ?? AppDelegate.dataCoordinator)?
            .suspendCachePersistence(reason: "a new library replaces this one at relaunch")
        MemoryStoreCache.shared.invalidateOnDisk()
        // The rotation baseline is cleared by the launch that swaps the empty store in.
        Self.log("Fresh empty database staged via createFreshDatabase()")
    }

    // MARK: - Poster Restoration
    /// Copies the backup's posters into PendingRestore's staging folder. The launch that
    /// swaps the restored library in moves them into the posters folder; until then the
    /// running library's posters are untouched, and a restore that fails discards them.
    @MainActor
    private func stagePosterImages(
        from sourceURL: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        guard Preferences.posterImagesFolderURL != nil else {
            Self.log("No poster images destination configured, skipping poster restoration")
            return
        }
        guard let destinationURL = PendingRestore.stagedPostersURL else {
            throw DBRestorerError.storeRebuildFailed("Could not resolve the folder to stage posters in.")
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
                let fileProgress = 0.25 + (0.05 * Double(index + 1) / Double(totalFiles))
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

            let fileProgress = 0.25 + (0.05 * Double(index + 1) / Double(totalFiles))
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
    private func createFilm(from parsed: ParsedObject, context: NSManagedObjectContext) throws -> Film {
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

    private func createListObject(from parsed: ParsedObject, context: NSManagedObjectContext) throws -> ListObject {
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
    /// in this same pass. The caller claims the result once the list is kept.
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

        return resolved
    }

    private func createImportSession(from parsed: ParsedObject, context: NSManagedObjectContext) throws -> ImportSession {
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

    /// True when `object` is the first of its ID in this restore. Otherwise it is taken back
    /// out of the context and false is returned: every ID is unique in the store, and a backup
    /// written before that was enforced may repeat one. The first occurrence is restored, as
    /// StoreDeduplicator keeps the first, and the restore's row-count check
    /// then counts only what was kept.
    private func keepFirst(_ object: NSManagedObject, _ isFirst: Bool, _ id: UUID,
                           context: NSManagedObjectContext) -> Bool {
        guard !isFirst else { return true }
        Self.log("WARNING: Skipping \(object.entity.name ?? "object") \(id): the backup repeats this ID")
        context.delete(object)
        return false
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
    private func createSavedSearches(from objects: [ParsedObject], lists: [ListObject], context: NSManagedObjectContext) {
        guard !objects.isEmpty else { return }
        let coordinator = dataCoordinator ?? AppDelegate.dataCoordinator
        var claims = coordinator?.listNameClaims(includingUserLists: false) ?? DataCoordinator.builtInNameClaims
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
                                   context: NSManagedObjectContext) throws -> SavedSearchObject? {
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
    private func createSettingsObject(from obj: ParsedObject, context: NSManagedObjectContext) throws -> SettingsObject {
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
        context: NSManagedObjectContext,
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
        context: NSManagedObjectContext,
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
                // `Int(exactly:)`, not `Int(_:)`: a legacy backup's text field holding a
                // number too large for Int (a 20-digit serial in notes) reaches here as a
                // Double, and `Int(_:)` traps on it.
                if let i = Int(exactly: d) {
                    return String(i)
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
            
            // Handle double conversion (truncate). Out of Int's range, or NaN, is malformed
            // rather than a trap.
            if let d = value as? Double, let i = Int(exactly: d.rounded(.towardZero)) {
                return i
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
    /// "Create New Library" completion flow (`DatabaseErrorAlertModifier`) after staging a
    /// new store; the relaunch swaps it in (PendingRestore.applyIfPending). The `exit(0)`
    /// bypass is intentional — the normal AppKit termination path would flush caches that
    /// describe the library about to be replaced. Spawning a new instance via `open` before
    /// exit ensures the application reopens cleanly against the restored store.
    @MainActor
    static func restartApplication() {
        let bundlePath = Bundle.main.bundlePath
        // `open` only activates an app that is still running, so the relaunch waits for this
        // process to be gone (up to 10 s) rather than guessing how long exit takes.
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "for _ in $(seq 200); do kill -0 \(pid) 2>/dev/null || break; sleep 0.05; done; open \"\(bundlePath)\""]
        do {
            try task.run()
        } catch {
            log("Failed to initiate relaunch: \(error)")
        }
        // Again, immediately before exit: both callers staged a replacement store, and a cache
        // write already in flight when they invalidated could have landed since. Suspension
        // there guarantees no new one has started.
        MemoryStoreCache.shared.invalidateOnDisk()
        // Bypass the normal AppKit termination flow, which would attempt to access
        // stale model objects and flush caches against the replaced store.
        exit(0)
    }
}

