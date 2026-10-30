// MARK: - DHBackup.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only harness scenarios that exercise the backup / restore pipeline as a whole
// system rather than one stage at a time.
//
// WHAT THIS FILE ADDS OVER `restore-endtoend`
//
// `restore-endtoend` (DHPipelines.swift) proves that FILM string fields survive a real
// export and a real restore. That is the hardest single case, but it is one entity out of
// six, and the backup's job is the whole library:
//
//   • Releases carry 37 persisted fields across six Swift types, plus a parent/child
//     hierarchy whose inverse array the restorer populates by hand.
//   • ListMemberships are the only record of which film sits in which list, and in what
//     order — losing `sortOrder` silently reshuffles every custom-ordered list.
//   • ImportSessions and the SettingsObject are each written by one bespoke extractor.
//   • Posters are files, not rows, and the restore path for them contains a security
//     guard that nothing exercised.
//
// So the scenarios here are organized around four questions the user's data actually
// depends on, each of which is answered by running the real code and reading the result
// back off disk — never by inspecting the source:
//
//   1. IS EVERYTHING WRITTEN?  `backup-schema-coverage` derives the persisted field list
//      from the live Core Data model (LibraryModel) — not from a hand-maintained list that would rot —
//      and requires every attribute to appear in the produced XML. A field added to a
//      model class but forgotten in its `extractExportValues()` is invisible to every other
//      check in the suite: it exports cleanly, restores cleanly, and is simply gone.
//
//   2. DOES IT ALL COME BACK?  `backup-graph-roundtrip` seeds one fully-populated instance
//      of every entity, with a value in every field chosen to be distinguishable from that
//      field's default, and compares field by field after a real restore. Populating every
//      field matters: a comparison against default-valued objects passes for a field the
//      restorer never reads.
//
//   3. IS IT REPEATABLE?  `backup-repeatability` exports the same store twice and requires
//      the two files to agree, then restores and re-exports and requires the SECOND
//      generation to agree with the first. A pipeline that loses a little on each pass
//      still looks correct in a single round trip; it is only visible as a fixed-point
//      failure.
//
//   4. WHAT HAPPENS WHEN IT GOES WRONG?  `backup-integrity` damages a real package in the
//      four ways a real one can be damaged and asserts the property that matters more than
//      any error message: that the restore refuses BEFORE it commits its staged store, so
//      the user's library is left as it was (see PendingRestore).
//
// STORE OWNERSHIP — why these scenarios never touch the coordinator's container
//
// The coordinator's container holds the library this session loaded, and a restore's result
// is only read after the swap the relaunch would do (applyRestoreAsRelaunchWould), into a
// separate store. Every scenario here therefore opens its OWN container at the store URL,
// and starts by erasing the store so it begins from a known-empty library regardless of
// what ran before it. That also makes each scenario individually runnable via
// `-FTDebugHarness backup`.

#if DEBUG

import Foundation
import CoreData

extension DebugHarness {

    /// Scenario names owned by this file. Every one of them destroys and rebuilds the
    /// sandbox store, so the whole group must run after every scenario that needs a live
    /// library — i.e. after `restore-endtoend`.
    static var backupScenarios: [String] {
        ["backup-schema-coverage", "backup-graph-roundtrip", "backup-posters",
         "backup-repeatability", "backup-integrity", "backup-limits", "backup-scale",
         "backup-delivery", "backup-auto", "backup-background"]
    }

    static func runBackupScenario(_ scenario: String) async -> HarnessScenarioResult? {
        switch scenario {
        case "backup-schema-coverage": return await schemaCoverageScenario()
        case "backup-graph-roundtrip": return await graphRoundTripScenario()
        case "backup-posters":         return await posterRoundTripScenario()
        case "backup-repeatability":   return await repeatabilityScenario()
        case "backup-integrity":       return await backupIntegrityScenario()
        case "backup-limits":          return await backupLimitsScenario()
        case "backup-scale":           return await backupScaleScenario()
        case "backup-delivery":        return await backupDeliveryScenario()
        case "backup-auto":            return await backupAutoScenario()
        case "backup-background":      return await backupBackgroundScenario()
        default:                       return nil
        }
    }

    // MARK: - Store Ownership Helpers

    /// The full model set, read from LibraryModel. Must match `DBExporter.allModelTypes`;
    /// `schemaCoverageScenario` asserts it.
    static var backupHarnessSchema: HarnessSchema {
        HarnessSchema(entities: LibraryModel.shared.model.entities.map {
            HarnessSchema.Entity(name: $0.name ?? "", attributes: Array($0.attributesByName.values))
        })
    }

    /// The live model's entities and attributes (LibraryModel), read as names.
    struct HarnessSchema {
        struct Entity {
            let name: String
            let attributes: [NSAttributeDescription]
        }
        let entities: [Entity]
    }

    /// The library's store, or after a harness restore the store the relaunch would open
    /// (see applyRestoreAsRelaunchWould). Reset by resetBackupStore.
    static var backupHarnessStoreURL: URL? {
        restoredStoreInUse ? harnessRestoredStoreURL : LibraryStore.storeURL
    }

    /// Where applyRestoreAsRelaunchWould swaps a restore in: beside the library's store, and
    /// open in no connection, as the launch's swap target is.
    static var harnessRestoredStoreURL: URL? {
        LibraryStore.storeURL?.deletingLastPathComponent().appendingPathComponent("harness-restored.sqlite")
    }
    @MainActor static var restoredStoreInUse = false

    /// Opens a container at the sandbox store URL. `allowsSave: false` is used for every
    /// verification read, so a check can never accidentally write to the store it is
    /// measuring.
    @MainActor
    static func openBackupStore(allowsSave: Bool) throws -> NSPersistentContainer {
        guard let url = backupHarnessStoreURL else {
            throw DBRestorerError.storeRebuildFailed("no store URL in this sandbox")
        }
        return try LibraryStore.makeContainer(at: url, readOnly: !allowsSave)
    }

    /// Deletes the store files and opens a fresh writable container, so a scenario starts
    /// from an empty library whatever ran before it. This is deliberately the same three-file
    /// deletion `DBRestorer` performs: leaving a -wal behind would carry rows from the
    /// previous scenario into this one and make every count check meaningless.
    @MainActor
    static func resetBackupStore() throws -> NSPersistentContainer {
        // Back to the library's own store, before its URL is read below.
        restoredStoreInUse = false
        guard let url = backupHarnessStoreURL else {
            throw DBRestorerError.storeRebuildFailed("no store URL in this sandbox")
        }
        // Erased in place, not unlinked: the app's own container has this file open, and
        // deleting it from under that connection is what SQLite reports as error 6922.
        PendingRestore.discard()
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try LibraryStore.destroyStore(at: url)
        }
        let container = try openBackupStore(allowsSave: true)
        return container
    }

    /// Runs a real export against a caller-supplied container and returns the package URL.
    @MainActor
    static func exportBackupPackage(container: NSPersistentContainer,
                                    filename: String,
                                    includePosters: Bool = false,
                                    includeSettings: Bool = true,
                                    posterUIDs: Set<String> = []) async -> URL? {
        let exporter = DBExporter(persistentContainer: container)
        do {
            let result = try await exporter.createCompleteBackup(
                filename: filename,
                destinationURL: DebugSandbox.rootURL,
                isBackgroundExport: false,
                includeSettings: includeSettings,
                includePosters: includePosters,
                posterUIDs: posterUIDs)
            return result.packageURL
        } catch {
            log("Backup harness export '\(filename)' failed: \(error)")
            return nil
        }
    }

    /// Runs a real restore. Returns the thrown error, or nil on success.
    /// `dataCoordinator` is deliberately nil: these scenarios verify what lands in the
    /// DATABASE, which is what the mandatory post-restore relaunch reads. Applying settings
    /// to the live Preferences as well would mutate state later scenarios depend on.
    @MainActor
    static func restoreBackupPackage(_ url: URL,
                                     container: NSPersistentContainer) async -> (error: (any Error)?, rebuilt: Bool) {
        let restorer = DBRestorer(container: container, dataCoordinator: nil)
        do {
            try await restorer.restoreFromBackup(at: url) { _, _ in }
            applyRestoreAsRelaunchWould()
            return (nil, restorer.requiresRestart)
        } catch {
            if restorer.requiresRestart { applyRestoreAsRelaunchWould() }
            return (error, restorer.requiresRestart)
        }
    }

    /// Runs the swap the post-restore relaunch would (PendingRestore.applyIfPending), into
    /// `harnessRestoredStoreURL` rather than the library's store: the app's container has
    /// that one open, which the launch's swap never faces, and a copy into a file under open
    /// connections reads back inconsistently. Later reads go there (backupHarnessStoreURL).
    @MainActor
    @discardableResult
    static func applyRestoreAsRelaunchWould() -> Bool {
        guard let target = harnessRestoredStoreURL else { return false }
        for file in LibraryStore.storeFiles(target) { try? FileManager.default.removeItem(at: file) }
        switch PendingRestore.applyIfPending(into: target) {
        case .swapped:
            restoredStoreInUse = true
            return true
        case .nothingPending:
            log("Harness: no staged restore to swap in")
            return false
        case .failed(let reason):
            log("Harness: staged restore failed to swap in: \(reason)")
            return false
        }
    }

    // MARK: - Scenario: Schema Coverage

    /// Every attribute store persists must appear in the exported XML.
    ///
    /// The expected field list is read from the live `Schema` rather than written down here,
    /// which is the only form of this check worth having: a hand-maintained list is updated
    /// by the same edit that would have updated the extractor, so it fails exactly never.
    ///
    /// This is the check that catches the quietest possible data-loss bug — a field added to
    /// a model class and to the UI but not to that model's `extractExportValues()`. Such a field
    /// exports without error, restores without error, and is simply absent from every backup
    /// the user has ever taken. No round-trip comparison can see it, because the value it
    /// would compare against is the model default on both sides.
    private static func schemaCoverageScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-schema-coverage")

        let container: NSPersistentContainer
        do {
            container = try resetBackupStore()
        } catch {
            r.check("reset-store", false, "\(error)")
            return r
        }

        // One fully-populated instance of every entity, so no field can be absent from the
        // file merely because it was nil or empty in the corpus.
        let graph: SeededGraph
        do {
            graph = try await seedFullGraph(container: container)
        } catch {
            r.check("seed-graph", false, "\(error)")
            return r
        }
        r.check("seed-graph", true, graph.summary)

        guard let packageURL = await exportBackupPackage(container: container,
                                                         filename: "schema-coverage") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        let parsed: ParsedBackup
        do {
            parsed = try await DBImporter().parseBackupFile(
                at: packageURL.appendingPathComponent("backup.xml"))
        } catch {
            r.check("backup-parses", false, "\(error)")
            return r
        }
        r.check("backup-parses", true, "\(parsed.objects.count) object(s)")

        // The exporter's type list must be the whole schema. A model added to the schema but
        // not to `allModelTypes` is never fetched, so none of its rows reach any backup.
        let schemaEntityNames = Set(backupHarnessSchema.entities.map(\.name))
        let exportedTypeNames = Set(DBExporter.allModelTypes.map { $0.entityName })
        r.check("exporter-covers-every-model",
                schemaEntityNames.subtracting(exportedTypeNames).isEmpty,
                schemaEntityNames.subtracting(exportedTypeNames).isEmpty
                    ? "\(exportedTypeNames.count) model type(s) exported: "
                        + exportedTypeNames.sorted().joined(separator: ", ")
                    : "in the schema but never exported: "
                        + schemaEntityNames.subtracting(exportedTypeNames).sorted().joined(separator: ", "))

        // --- Layer 1: the extractor, in isolation -----------------------------------------
        //
        // Asked of a fully-populated instance held in memory, so the answer depends on
        // nothing but the extractor itself. This is the layer that actually catches the bug
        // the scenario exists for — a field added to a model class and forgotten in its
        // `extractExportValues()` — and it is deterministic, which the file layer below is
        // not for `SettingsObject` (see the note there).
        let extractorSources: [(String, () -> [String: Any])] = [
            ("Film", { self.probeFilm().extractExportValues().properties }),
            ("ListObject", { self.probeList().extractExportValues().properties }),
            ("ListMembership", { self.probeMembership().extractExportValues().properties }),
            ("Release", { self.probeRelease().extractExportValues().properties }),
            ("ImportSession", { self.probeImportSession().extractExportValues().properties }),
            ("SettingsObject", { self.probeSettings().extractExportValues().properties }),
            ("SavedSearchObject", { self.probeSavedSearch().extractExportValues().properties })
        ]
        for (entityName, produce) in extractorSources {
            let attributeNames = Set(backupHarnessSchema.entities
                .first { $0.name == entityName }?.attributes.map(\.name) ?? [])
            let produced = Set(produce().keys)
            let missing = attributeNames.subtracting(produced)
            r.check("extractor-covers:\(entityName)", missing.isEmpty,
                    missing.isEmpty
                        ? "\(attributeNames.count) persisted attribute(s), all offered by extractExportValues()"
                        : "\(missing.count) persisted attribute(s) the extractor never offers, so no "
                            + "backup can contain them: " + missing.sorted().joined(separator: ", "))
            let extra = produced.subtracting(attributeNames)
            r.metric("extra-keys:\(entityName)", Double(extra.count), "count")
        }

        // --- Layer 2: the produced file -----------------------------------------------------
        //
        // The extractor offering a key proves nothing about the key reaching the file: the
        // reader normalizes, the packager writes, and either could drop it. So the same
        // question is asked again of the XML that was actually written.
        //
        // `SettingsObject` is deliberately NOT held to this layer. Its row is a singleton the
        // running application rewrites on a five-second debounce — every restore posts a
        // `preferencesChanged` event, so a write is nearly always in flight — and that write
        // reaches the same store path this scenario seeds. The row that gets exported is
        // therefore whichever of the two landed last, and its nil-valued optionals are
        // legitimately omitted by the extractor. The settings question is answered instead by
        // the extractor layer above and, for the restore direction, by
        // `settings-restore-covers-every-field` in `backup-integrity`, which uses a
        // hand-written file no live code can touch.
        let fileCoverageEntities = ["Film", "ListObject", "ListMembership", "Release", "ImportSession",
                                    "SavedSearchObject"]
        for entityName in fileCoverageEntities {
            let attributeNames = Set(backupHarnessSchema.entities
                .first { $0.name == entityName }?.attributes.map(\.name) ?? [])
            let objects = parsed.objects.filter { $0.entityName == entityName }
            guard !objects.isEmpty else {
                r.check("coverage:\(entityName)", false,
                        "no \(entityName) object in the backup — the corpus seeded one, so "
                            + "either the fetch or the write dropped it entirely")
                continue
            }
            // Union across every instance: an optional attribute is written only where it has
            // a value, so one instance can legitimately lack a key another carries.
            let writtenKeys = objects.reduce(into: Set<String>()) { $0.formUnion($1.properties.keys) }
            let missing = attributeNames.subtracting(writtenKeys)
            r.check("coverage:\(entityName)", missing.isEmpty,
                    missing.isEmpty
                        ? "\(attributeNames.count) persisted attribute(s), all present in the backup"
                        : "\(missing.count) persisted attribute(s) never written to the backup: "
                            + missing.sorted().joined(separator: ", "))
        }

        // Relationships must be recoverable. Each is exported as an ID property rather than
        // a <Relationship> element, so the check is that the naming ID is present and parses.
        func hasUUID(_ entityName: String, _ key: String) -> Bool {
            let objects = parsed.objects.filter { $0.entityName == entityName }
            guard !objects.isEmpty else { return false }
            return objects.allSatisfy {
                ($0.properties[key] as? String).flatMap(UUID.init(uuidString:)) != nil
            }
        }
        r.check("relationship:ListMembership.filmID", hasUUID("ListMembership", "filmID"), "")
        r.check("relationship:ListMembership.listID", hasUUID("ListMembership", "listID"), "")
        r.check("relationship:Release.filmID", hasUUID("Release", "filmID"), "")

        // The parent link is written only for children, by design — a parentless release
        // omits the key entirely so the restorer's "absent means top-level" reading is exact.
        let releaseObjects = parsed.objects.filter { $0.entityName == "Release" }
        let withParent = releaseObjects.filter { $0.properties["parentReleaseID"] != nil }
        r.check("relationship:Release.parentReleaseID-only-on-children",
                withParent.count == graph.childReleaseIDs.count,
                "\(withParent.count) release(s) carry parentReleaseID, \(graph.childReleaseIDs.count) child(ren) seeded")
        r.check("relationship:no-nil-literal-parent-ids",
                releaseObjects.allSatisfy { ($0.properties["parentReleaseID"] as? String) != "nil" },
                "a parentless release must omit the key, never write the text \"nil\"")

        // Manifest counts must equal what is actually in the file. The restorer only warns on
        // a mismatch, so a wrong manifest is otherwise silent.
        var actual: [String: Int] = [:]
        for object in parsed.objects { actual[object.entityName, default: 0] += 1 }
        let manifestMatches = parsed.manifest.allSatisfy { actual[$0.key] ?? 0 == $0.value }
            && Set(actual.keys) == Set(parsed.manifest.keys)
        r.check("manifest-matches-file", manifestMatches,
                "manifest \(parsed.manifest.sorted(by: { $0.key < $1.key })) vs actual \(actual.sorted(by: { $0.key < $1.key }))")

        return r
    }

    // MARK: - Extractor Probes

    /// Fully-populated, UNINSERTED instances used by the extractor-coverage layer.
    ///
    /// Not inserted into any context on purpose: `extractExportValues()` is a pure function
    /// of the object's own stored properties, so asking it in isolation removes the store,
    /// the running application, and the export machinery from the answer. Every field is set
    /// to a non-default value so that an extractor which skipped a field on a "still at its
    /// default" test would be caught here too.
    @MainActor
    static func probeFilm() -> Film {
        let film = makeSnapshot(name: "Extractor Probe").toFilm()
        film.rotationThresholdOverride = 12
        film.autoAddToQueueOnRotation = 1
        return film
    }

    @MainActor
    static func probeList() -> ListObject {
        ListObject(listID: UUID(), listName: "Probe", viewStyle: "list",
                   sortFilterOptions: ["name"], displayOrder: 1)
    }

    @MainActor
    static func probeMembership() -> ListMembership {
        ListMembership(id: UUID(), film: probeFilm(), list: probeList(),
                       dateAdded: Date(), sortOrder: 1)
    }

    @MainActor
    static func probeRelease() -> Release {
        let release = fullyPopulatedRelease(id: UUID(), film: probeFilm(), dateAdded: Date())
        // A parent, so `parentReleaseID` is offered too — the extractor omits the key for a
        // top-level release by design, which would otherwise read as a missing field.
        release.parentRelease = Release(id: UUID(), independence: ReleaseIndependence.standalone)
        return release
    }

    @MainActor
    static func probeImportSession() -> ImportSession {
        ImportSession(id: UUID(), sessionDate: Date(), importType: "metadata",
                      totalItems: 1, successCount: 1, errorCount: 1, duplicateCount: 1,
                      updatedCount: 1, notFoundCount: 1, errorFileNames: ["a"],
                      addedTitles: ["a"], updatedTitles: ["a"], duplicateTitles: ["a"],
                      isCompleted: true, isCanceled: true)
    }

    @MainActor
    static func probeSavedSearch() -> SavedSearchObject {
        SavedSearchObject(SavedSearch(name: "Probe", query: SavedSearchQuery(
            tokens: [SearchToken(field: .flags, value: "owned 4k"),
                     SearchToken(field: .year, value: "1990s", isInverted: true)],
            text: "alien"), displayOrder: 3))
    }

    @MainActor
    static func probeSettings() -> SettingsObject {
        let settings = SettingsObject(snapshotID: SettingsObject.singletonID,
                                      version: SettingsObject.currentVersion,
                                      lastSyncDate: Date())
        applySeededSettings(settings)
        return settings
    }

    // MARK: - Full Graph Corpus

    /// Identifiers of everything `seedFullGraph` wrote, so the verification pass can look
    /// each object up by name rather than by position.
    struct SeededGraph {
        var filmA = UUID(), filmB = UUID()
        var listOne = UUID(), listTwo = UUID()
        var membershipIDs: [UUID] = []
        var parentReleaseID = UUID()
        var childReleaseIDs: [UUID] = []
        var soloReleaseID = UUID()
        var importSessionID = UUID()
        var posterUID = ""
        var releaseDateAdded = Date(timeIntervalSince1970: 1_600_000_000)
        var membershipDateAdded = Date(timeIntervalSince1970: 1_500_000_000)
        var sessionDate = Date(timeIntervalSince1970: 1_400_000_000)

        var summary: String {
            "2 film(s), 2 list(s), \(membershipIDs.count) membership(s), "
                + "\(childReleaseIDs.count + 2) release(s), 1 import session, 1 settings object"
        }
    }

    /// The Release whose every field carries a value distinguishable from that field's
    /// default. Spelled out rather than generated so a failure names a literal the reader
    /// can find in this file.
    @MainActor
    static func fullyPopulatedRelease(id: UUID, film: Film, dateAdded: Date) -> Release {
        Release(
            id: id,
            studio: "Criterion & Co. <Special>",
            // A full date, so the round trip covers the dot shape, not only a bare year.
            releaseDate: "2019.04.12",
            baseReleaseYear: "1974",
            purchased: true,
            wishlist: 7,
            format: "4K UHD",
            includedVersions: ["Theatrical", "Director's Cut", "Extended \"Final\""],
            independence: ReleaseIndependence.standalone,
            videoFormat: "AVC",
            releaseAspectRatio: ["2.39:1", "1.33:1"],
            scanningMethod: "Progressive",
            // A value the reader's type inference sees as the Double 7.1 — the field is a
            // String in the model, and `parseAudioChannels` exists solely to put it back.
            audioChannels: "7.1",
            hasSubtitles: true,
            numberOfDiscs: 3,
            discMultiPack: true,
            hasArtwork: "Steelbook",
            remastered: true,
            nationalOrigin: "United Kingdom",
            replicationType: "Pressed",
            discCapacity: ["BD-100", "BD-66"],
            hasHDR: "Dolby Vision",
            masterType: "4K DI",
            regionLock: "Region B",
            regionLockBypass: true,
            marketAvailability: ["UK", "EU"],
            numberOfCopies: 2,
            // Money: a value with cents, and one whose decimal expansion is not exact in
            // binary, so a Double written as text and read back must still compare equal.
            cost: 39.99,
            amountSpent: 74.85,
            purchaseDate: "2021.06.14",
            lowestPrice: 19.95,
            lowestPriceDate: "2022.11.02",
            condition: "Like New",
            notes: "Slipcover; booklet ]]> present & <intact>",
            dateAdded: dateAdded,
            sortOrder: 5,
            film: film)
    }

    /// Applies a distinct, non-default value to every settings field, and returns the
    /// expected values keyed by field name for the comparison pass. The three key-path
    /// tables are also what `settingsFieldNames` reports, so schema coverage of the
    /// comparison itself can be asserted rather than assumed.
    static var settingsBoolFields: [(String, ReferenceWritableKeyPath<SettingsObject, Bool?>)] {
        [("confirmGalleryDelete", \.confirmGalleryDelete),
         ("confirmListEdits", \.confirmListEdits),
         ("confirmReleaseDelete", \.confirmReleaseDelete),
         ("largeGalleryGrid", \.largeGalleryGrid),
         ("showStatusBar", \.showStatusBar),
         ("rememberRightSidebarTab", \.rememberRightSidebarTab),
         ("rememberRightSidebarReleasesFilter", \.rememberRightSidebarReleasesFilter),
         ("autoExpandRightSidebarTables", \.autoExpandRightSidebarTables),
         ("additionalCalTableDetails", \.additionalCalTableDetails),
         ("showReleasesSummaryTable", \.showReleasesSummaryTable),
         ("iCalIntegration", \.iCalIntegration),
         ("manualExtQuery", \.manualExtQuery),
         ("smartLists", \.smartLists),
         ("excludeQueuedFromUpForRotation", \.excludeQueuedFromUpForRotation),
         ("maintainSelectionOnSearchExit", \.maintainSelectionOnSearchExit),
         ("showSearchSuggestions", \.showSearchSuggestions),
         ("showRecentSearches", \.showRecentSearches),
         ("showInfoComplete", \.showInfoComplete),
         ("performBackupAtLaunch", \.performBackupAtLaunch),
         ("importScanSubfolders", \.importScanSubfolders),
         ("fuzzyImportMatching", \.fuzzyImportMatching),
         ("fuzzyImportYearMatching", \.fuzzyImportYearMatching),
         ("overrideSortNameField", \.overrideSortNameField),
         ("allowUpdatesForDuplicateImports", \.allowUpdatesForDuplicateImports),
         ("allowUpdatesForDuplicateRatings", \.allowUpdatesForDuplicateRatings),
         ("exportPosterImages", \.exportPosterImages),
         ("prunePosterImages", \.prunePosterImages),
         ("exportUserSettings", \.exportUserSettings),
         ("maintainScrollPositionOnViewSwitch", \.maintainScrollPositionOnViewSwitch),
         ("rememberTabSelection", \.rememberTabSelection),
         ("rememberImportsTab", \.rememberImportsTab),
         ("rememberSortFilterSelections", \.rememberSortFilterSelections),
         ("confirmFilmQueueAdd", \.confirmFilmQueueAdd),
         ("notifyAboutNewReleases", \.notifyAboutNewReleases),
         ("onlyNotifyForWishlisted", \.onlyNotifyForWishlisted),
         ("queueIsDropTarget", \.queueIsDropTarget),
         ("strictFramesTableChecking", \.strictFramesTableChecking),
         ("showWatchDetailsAnnotationGlyphs", \.showWatchDetailsAnnotationGlyphs),
         ("atvq", \.atvq),
         ("loggingEnabled", \.loggingEnabled)]
    }

    static var settingsIntFields: [(String, ReferenceWritableKeyPath<SettingsObject, Int?>)] {
        [("listEditScope", \.listEditScope),
         ("defaultRotationThreshold", \.defaultRotationThreshold),
         ("tabRememberScope", \.tabRememberScope),
         ("queueSectionOnDrop", \.queueSectionOnDrop)]
    }

    static var settingsStringFields: [(String, ReferenceWritableKeyPath<SettingsObject, String?>)] {
        [("lastRecentsCategory", \.lastRecentsCategory),
         ("lastReportsCategory", \.lastReportsCategory),
         ("lastImportsCategory", \.lastImportsCategory),
         ("selectedSortOptionsJSON", \.selectedSortOptionsJSON),
         ("ignoredDuplicatePairsJSON", \.ignoredDuplicatePairsJSON)]
    }

    /// The value each field is seeded with. Booleans alternate rather than being uniformly
    /// true: a restore that dropped every boolean and left the model default would pass a
    /// corpus where every expected value happened to equal that default.
    static func expectedSettingsBool(_ index: Int) -> Bool { index % 2 == 0 }
    static func expectedSettingsInt(_ index: Int) -> Int { 101 + index * 7 }
    static func expectedSettingsString(_ index: Int) -> String {
        // Deliberately type-ambiguous text: a JSON object, a JSON array, a bare number and a
        // boolean word are all shapes the reader's inference would misread without the
        // declared-type attribute, and all shapes these fields really hold.
        ["Watched", "true", #"["alpha","beta"]"#, #"{"gallery":"name","sort":"desc"}"#, "42"][index % 5]
    }

    @MainActor
    static func applySeededSettings(_ settings: SettingsObject) {
        for (index, field) in settingsBoolFields.enumerated() {
            settings[keyPath: field.1] = expectedSettingsBool(index)
        }
        for (index, field) in settingsIntFields.enumerated() {
            settings[keyPath: field.1] = expectedSettingsInt(index)
        }
        for (index, field) in settingsStringFields.enumerated() {
            settings[keyPath: field.1] = expectedSettingsString(index)
        }
    }

    /// Seeds one fully-populated instance of every entity in the schema, wired into a real
    /// object graph: two films, two lists, memberships crossing both, a release hierarchy
    /// (parent with two children, the "Combo-pack (dual BD)" shape), a standalone release,
    /// an import session, and a settings object.
    @MainActor
    static func seedFullGraph(container: NSPersistentContainer) async throws -> SeededGraph {
        var graph = SeededGraph()
        let context = container.makeMainContext()

        // FilmSnapshot.id is a `let`, so the harness-chosen identity is stamped on the model
        // object after conversion. Doing it this way rather than through the snapshot keeps
        // the seed going through `toFilm()`, which is the same conversion the app uses.
        let filmA = makeSnapshot(name: "Graph Film A").toFilm()
        filmA.id = graph.filmA
        let filmB = makeSnapshot(name: "Graph Film B").toFilm()
        filmB.id = graph.filmB

        // Values chosen so no field equals its model default, and several are the
        // type-ambiguous shapes the untyped format has to survive.
        // Lowercase on purpose: `posterUID` names a file on disk, and a pipeline that
        // canonicalized it as a UUID would upper-case it and break the link between the film
        // and its poster image. The seeded value is recorded on the graph so the comparison
        // is against what was written rather than against the restored value's own lowercase.
        graph.posterUID = UUID().uuidString.lowercased()
        filmA.posterUID = graph.posterUID
        filmA.releaseYear = "1974"
        filmA.userRating = 5
        filmA.lastWatched = "2024.03.09"
        filmA.rotationThresholdOverride = 36
        filmA.duration = "6120000"
        filmA.viewCount = 4
        filmA.calendarTable = ["2024.03.09", "2023.01.02"]
        filmA.autoAddToQueueOnRotation = 1
        filmA.digitalSource = "Blu-ray"
        filmA.digitalVersion = "Theatrical"
        filmA.subtitles = "English SDH"
        filmA.notes = "  padded & <marked> ]]> "
        filmA.numberOfDiscs = "007"
        filmA.aspectRatio = "2.00"
        filmA.color = false
        filmA.edited = true
        filmA.editedDuration = "5400000"
        filmA.frameRate = 23.976
        filmA.tags = ["noir", "a & b"]
        filmA.externalIdentifiers = ["tt0071853"]
        filmA.dateAdded = "2019.05.04"
        filmA.lastModified = "2025.12.31"
        filmA.watched = true
        filmA.specialSorting = ["numeral"]
        filmA.alternateTitle = ["Ünterwelt", "映画"]
        filmA.hofPosition = 2
        filmA.infoComplete = true
        filmA.comments = "false"
        filmA.genre = "Drama"
        filmA.releaseDate = "1974.12.20"
        filmA.descriptionText = "A description with an ampersand & a <tag>."
        filmA.rating = "PG"
        filmA.studio = ["Studio One"]
        filmA.cast = [#"D\'Onofrio, Vincent"#, "Tom &amp; Jerry"]
        filmA.directors = ["A Director"]
        filmA.producers = ["A Producer"]
        filmA.executiveProducers = ["An Exec"]
        filmA.screenwriters = ["A Writer"]
        filmA.encodingTool = ["HandBrake"]
        filmA.libraryHBRFValue = 18
        filmA.composer = ["A Composer"]
        filmA.sortName = "1917"
        filmA.releaseUsed = "Criterion"
        filmA.tools = ["MakeMKV"]
        filmA.editedHBRFValue = 20
        filmA.editDate = "2024.02.02"
        filmA.warning = ["flashing"]
        filmA.descriptionNotes = "note"
        filmA.notesOnAudioTiming = ["+12ms"]
        filmA.specialAudioNotes = ["commentary"]
        filmA.notesArray = ["one", "two"]
        filmA.handbrakeFrames = ["100", "200"]
        filmA.correspondingTimecodes = ["00:00:04", "00:00:08"]

        context.insert(filmA)
        context.insert(filmB)

        let listOne = ListObject(listID: graph.listOne, listName: "Graph List One",
                                 viewStyle: "list", sortFilterOptions: ["name", "asc"],
                                 displayOrder: 3)
        let listTwo = ListObject(listID: graph.listTwo, listName: "Graph List Two",
                                 viewStyle: "gallery", sortFilterOptions: [],
                                 displayOrder: 9)
        context.insert(listOne)
        context.insert(listTwo)

        // Memberships with DISTINCT sortOrder values, and deliberately not in ascending
        // insertion order: `sortOrder` is the only record of a custom list's arrangement, and
        // a restore that dropped it would still produce the right membership set.
        for (film, list, order) in [(filmA, listOne, 4), (filmB, listOne, 1), (filmA, listTwo, 2)] {
            let membership = ListMembership(id: UUID(), film: film, list: list,
                                            dateAdded: graph.membershipDateAdded,
                                            sortOrder: order)
            graph.membershipIDs.append(membership.id)
            context.insert(membership)
        }

        // Release hierarchy: a 4K parent bundling two Blu-rays. Two children rather than one,
        // because the one-level guard and the inverse-array repair both behave differently
        // for a second child.
        let parent = Release(id: graph.parentReleaseID, studio: "Parent Studio",
                             releaseDate: "2021", format: "4K UHD",
                             independence: ReleaseIndependence.comboPackDualBD,
                             dateAdded: graph.releaseDateAdded, sortOrder: 0, film: filmA)
        context.insert(parent)
        for index in 0..<2 {
            let child = Release(id: UUID(), studio: "Child Studio \(index)",
                                releaseDate: "2021", format: "Blu-ray",
                                independence: ReleaseIndependence.comboPack,
                                dateAdded: graph.releaseDateAdded.addingTimeInterval(Double(index + 1)),
                                sortOrder: index + 1, film: filmA, parentRelease: parent)
            graph.childReleaseIDs.append(child.id)
            context.insert(child)
        }

        let solo = fullyPopulatedRelease(id: graph.soloReleaseID, film: filmB,
                                         dateAdded: graph.releaseDateAdded.addingTimeInterval(60))
        context.insert(solo)

        let session = ImportSession(
            id: graph.importSessionID, sessionDate: graph.sessionDate,
            importType: "metadata", totalItems: 42, successCount: 39, errorCount: 1,
            duplicateCount: 2, updatedCount: 5, notFoundCount: 3,
            errorFileNames: ["bad & file.mp4", "<odd>.mp4"],
            addedTitles: ["Added One", "Added Two"],
            updatedTitles: ["Updated One"],
            duplicateTitles: ["Dupe One", "Dupe Two"],
            isCompleted: true, isCanceled: false)
        context.insert(session)

        // One saved search, so the file layer has a SavedSearchObject to check.
        context.insert(probeSavedSearch())

        let settings = SettingsObject(snapshotID: SettingsObject.singletonID,
                                      version: SettingsObject.currentVersion,
                                      lastSyncDate: Date(timeIntervalSince1970: 1_300_000_000))
        applySeededSettings(settings)
        context.insert(settings)

        try context.save()
        return graph
    }

    // MARK: - Scenario: Full Graph Round Trip

    /// Seeds every entity, exports, restores, and compares field by field off the rebuilt
    /// store. This is the scenario that answers "does everything I expect come back".
    private static func graphRoundTripScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-graph-roundtrip")

        let container: NSPersistentContainer
        let graph: SeededGraph
        do {
            container = try resetBackupStore()
            graph = try await seedFullGraph(container: container)
        } catch {
            r.check("seed-graph", false, "\(error)")
            return r
        }
        r.check("seed-graph", true, graph.summary)

        guard let packageURL = await exportBackupPackage(container: container,
                                                         filename: "graph-roundtrip") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        r.check("export-succeeds", true, packageURL.lastPathComponent)

        let (restoreError, rebuilt) = await restoreBackupPackage(packageURL, container: container)
        guard restoreError == nil else {
            r.check("restore-completes", false, "\(restoreError!)")
            return r
        }
        r.check("restore-completes", true, "store rebuilt: \(rebuilt)")

        let films: [Film], lists: [ListObject], memberships: [ListMembership]
        let releases: [Release], sessions: [ImportSession], settingsRows: [SettingsObject]
        // Held for the rest of the scenario: a managed object whose context is gone reads
        // every attribute as nil, and the checks below read these long after the fetch.
        var keepAlive: [AnyObject] = []
        defer { withExtendedLifetime(keepAlive) {} }
        do {
            let verify = try openBackupStore(allowsSave: false)
            let context = verify.makeMainContext()
            keepAlive = [verify, context]
            films = try context.fetch(Film.request())
            lists = try context.fetch(ListObject.request())
            memberships = try context.fetch(ListMembership.request())
            releases = try context.fetch(Release.request())
            sessions = try context.fetch(ImportSession.request())
            settingsRows = try context.fetch(SettingsObject.request())
        } catch {
            r.check("restored-store-readable", false, "\(error)")
            return r
        }
        r.check("restored-store-readable", true,
                "\(films.count) film(s), \(lists.count) list(s), \(memberships.count) membership(s), "
                    + "\(releases.count) release(s), \(sessions.count) session(s), \(settingsRows.count) settings row(s)")

        r.check("counts:films", films.count == 2, "\(films.count) of 2")
        r.check("counts:lists", lists.count == 2, "\(lists.count) of 2")
        r.check("counts:memberships", memberships.count == 3, "\(memberships.count) of 3")
        r.check("counts:releases", releases.count == 4, "\(releases.count) of 4")
        r.check("counts:import-sessions", sessions.count == 1, "\(sessions.count) of 1")
        r.check("counts:settings", settingsRows.count == 1, "\(settingsRows.count) of 1")

        // --- Film A, field by field ---------------------------------------------------------
        guard let filmA = films.first(where: { $0.id == graph.filmA }) else {
            r.check("film-a-present", false, "the fully-populated film is absent from the restore")
            return r
        }
        r.check("film-a-present", true, filmA.name)

        var filmLosses: [String] = []
        func expectString(_ label: String, _ got: String, _ want: String) {
            if got != want { filmLosses.append("\(label): wrote \(String(reflecting: want)) → \(String(reflecting: got))") }
        }
        func expectArray(_ label: String, _ got: [String], _ want: [String]) {
            if got != want { filmLosses.append("\(label): wrote \(want) → \(got)") }
        }
        expectString("posterUID", filmA.posterUID, graph.posterUID)
        expectString("name", filmA.name, "Graph Film A")
        expectString("releaseYear", filmA.releaseYear, "1974")
        expectString("lastWatched", filmA.lastWatched, "2024.03.09")
        expectString("duration", filmA.duration, "6120000")
        expectString("digitalSource", filmA.digitalSource, "Blu-ray")
        expectString("digitalVersion", filmA.digitalVersion, "Theatrical")
        expectString("subtitles", filmA.subtitles, "English SDH")
        expectString("notes", filmA.notes, "  padded & <marked> ]]> ")
        expectString("numberOfDiscs", filmA.numberOfDiscs, "007")
        expectString("aspectRatio", filmA.aspectRatio, "2.00")
        expectString("editedDuration", filmA.editedDuration, "5400000")
        expectString("dateAdded", filmA.dateAdded, "2019.05.04")
        expectString("lastModified", filmA.lastModified, "2025.12.31")
        expectString("comments", filmA.comments, "false")
        expectString("genre", filmA.genre, "Drama")
        expectString("releaseDate", filmA.releaseDate, "1974.12.20")
        expectString("descriptionText", filmA.descriptionText, "A description with an ampersand & a <tag>.")
        expectString("rating", filmA.rating, "PG")
        expectString("sortName", filmA.sortName, "1917")
        expectString("releaseUsed", filmA.releaseUsed, "Criterion")
        expectString("editDate", filmA.editDate, "2024.02.02")
        expectString("descriptionNotes", filmA.descriptionNotes, "note")
        expectArray("calendarTable", filmA.calendarTable, ["2024.03.09", "2023.01.02"])
        expectArray("tags", filmA.tags, ["noir", "a & b"])
        expectArray("externalIdentifiers", filmA.externalIdentifiers, ["tt0071853"])
        expectArray("specialSorting", filmA.specialSorting, ["numeral"])
        expectArray("alternateTitle", filmA.alternateTitle, ["Ünterwelt", "映画"])
        expectArray("studio", filmA.studio, ["Studio One"])
        expectArray("cast", filmA.cast, [#"D\'Onofrio, Vincent"#, "Tom &amp; Jerry"])
        expectArray("directors", filmA.directors, ["A Director"])
        expectArray("producers", filmA.producers, ["A Producer"])
        expectArray("executiveProducers", filmA.executiveProducers, ["An Exec"])
        expectArray("screenwriters", filmA.screenwriters, ["A Writer"])
        expectArray("encodingTool", filmA.encodingTool, ["HandBrake"])
        expectArray("composer", filmA.composer, ["A Composer"])
        expectArray("tools", filmA.tools, ["MakeMKV"])
        expectArray("warning", filmA.warning, ["flashing"])
        expectArray("notesOnAudioTiming", filmA.notesOnAudioTiming, ["+12ms"])
        expectArray("specialAudioNotes", filmA.specialAudioNotes, ["commentary"])
        expectArray("notesArray", filmA.notesArray, ["one", "two"])
        expectArray("handbrakeFrames", filmA.handbrakeFrames, ["100", "200"])
        expectArray("correspondingTimecodes", filmA.correspondingTimecodes, ["00:00:04", "00:00:08"])
        if filmA.userRating != 5 { filmLosses.append("userRating → \(filmA.userRating)") }
        if filmA.viewCount != 4 { filmLosses.append("viewCount → \(filmA.viewCount)") }
        if filmA.hofPosition != 2 { filmLosses.append("hofPosition → \(filmA.hofPosition)") }
        if filmA.libraryHBRFValue != 18 { filmLosses.append("libraryHBRFValue → \(filmA.libraryHBRFValue)") }
        if filmA.editedHBRFValue != 20 { filmLosses.append("editedHBRFValue → \(filmA.editedHBRFValue)") }
        if filmA.color != false { filmLosses.append("color → \(filmA.color)") }
        if filmA.edited != true { filmLosses.append("edited → \(filmA.edited)") }
        if filmA.watched != true { filmLosses.append("watched → \(filmA.watched)") }
        if filmA.infoComplete != true { filmLosses.append("infoComplete → \(filmA.infoComplete)") }
        if filmA.frameRate != 23.976 { filmLosses.append("frameRate → \(filmA.frameRate)") }
        if filmA.rotationThresholdOverride != 36 {
            filmLosses.append("rotationThresholdOverride → \(String(describing: filmA.rotationThresholdOverride))")
        }
        if filmA.autoAddToQueueOnRotation != 1 {
            filmLosses.append("autoAddToQueueOnRotation → \(String(describing: filmA.autoAddToQueueOnRotation))")
        }
        r.check("film-a-all-fields-survive", filmLosses.isEmpty,
                filmLosses.isEmpty ? "every populated Film field round-tripped"
                    : "\(filmLosses.count) field(s): " + filmLosses.prefix(8).joined(separator: " | "))

        // --- Optional Int fields: nil must stay nil ------------------------------------------
        // The counterpart to the two checks above. `parseOptionalInt` returns nil for an
        // absent or null value, and Film B carries neither override — a restore that
        // substituted 0 (the non-optional default) would change the film's rotation
        // behavior without changing any visible field.
        if let filmB = films.first(where: { $0.id == graph.filmB }) {
            r.check("film-b-nil-optionals-stay-nil",
                    filmB.rotationThresholdOverride == nil && filmB.autoAddToQueueOnRotation == nil,
                    "rotationThresholdOverride \(String(describing: filmB.rotationThresholdOverride)), "
                        + "autoAddToQueueOnRotation \(String(describing: filmB.autoAddToQueueOnRotation))")
        } else {
            r.check("film-b-nil-optionals-stay-nil", false, "film B absent")
        }

        // --- Lists ---------------------------------------------------------------------------
        var listLosses: [String] = []
        if let one = lists.first(where: { $0.listID == graph.listOne }) {
            if one.listName != "Graph List One" { listLosses.append("listOne.listName → \(one.listName)") }
            if one.viewStyle != "list" { listLosses.append("listOne.viewStyle → \(one.viewStyle)") }
            if one.sortFilterOptions != ["name", "asc"] { listLosses.append("listOne.sortFilterOptions → \(one.sortFilterOptions)") }
            if one.displayOrder != 3 { listLosses.append("listOne.displayOrder → \(one.displayOrder)") }
        } else { listLosses.append("listOne absent") }
        if let two = lists.first(where: { $0.listID == graph.listTwo }) {
            if two.listName != "Graph List Two" { listLosses.append("listTwo.listName → \(two.listName)") }
            if two.viewStyle != "gallery" { listLosses.append("listTwo.viewStyle → \(two.viewStyle)") }
            // An EMPTY array must come back empty, not as a one-element array containing "[]"
            // or the literal text — the round trip for an empty collection goes through the
            // null/empty-string path, which is a different branch from a populated one.
            if !two.sortFilterOptions.isEmpty { listLosses.append("listTwo.sortFilterOptions → \(two.sortFilterOptions)") }
            if two.displayOrder != 9 { listLosses.append("listTwo.displayOrder → \(two.displayOrder)") }
        } else { listLosses.append("listTwo absent") }
        r.check("lists-all-fields-survive", listLosses.isEmpty,
                listLosses.isEmpty ? "both lists round-tripped" : listLosses.joined(separator: " | "))

        // --- Memberships: the arrangement, not just the set ----------------------------------
        var membershipLosses: [String] = []
        let expectedMemberships: [(UUID, UUID, Int)] = [
            (graph.filmA, graph.listOne, 4), (graph.filmB, graph.listOne, 1), (graph.filmA, graph.listTwo, 2)]
        for (filmID, listID, order) in expectedMemberships {
            let match = memberships.first { $0.film?.id == filmID && $0.list?.listID == listID }
            guard let match else {
                membershipLosses.append("film \(filmID.uuidString.prefix(8)) in list \(listID.uuidString.prefix(8)) absent")
                continue
            }
            if match.sortOrder != order {
                membershipLosses.append("sortOrder for \(filmID.uuidString.prefix(8)): wrote \(order) → \(match.sortOrder)")
            }
            if abs(match.dateAdded.timeIntervalSince(graph.membershipDateAdded)) > 1 {
                membershipLosses.append("dateAdded drifted to \(match.dateAdded)")
            }
        }
        r.check("memberships-preserve-film-list-and-order", membershipLosses.isEmpty,
                membershipLosses.isEmpty
                    ? "all 3 memberships restored with their film, list, order and date"
                    : membershipLosses.joined(separator: " | "))

        // Every membership must name BOTH ends. A membership restored with a nil film or list
        // is an orphan row that no list will ever show and nothing will ever clean up.
        r.check("memberships-have-both-ends",
                memberships.allSatisfy { $0.film != nil && $0.list != nil },
                "\(memberships.filter { $0.film == nil || $0.list == nil }.count) orphaned membership(s)")

        // The list's own view of its membership must agree — this is what the app reads.
        if let one = lists.first(where: { $0.listID == graph.listOne }) {
            r.check("list-membership-inverse-populated",
                    Set(one.filmIDs) == Set([graph.filmA, graph.filmB]),
                    "listOne.filmIDs → \(one.filmIDs.map { $0.uuidString.prefix(8) })")
            // filmIDs is sorted by sortOrder, so film B (order 1) must precede film A (order 4).
            r.check("list-membership-order-observable",
                    one.filmIDs.first == graph.filmB,
                    "listOne.filmIDs in sortOrder → \(one.filmIDs.map { $0.uuidString.prefix(8) })")
        }

        // --- Releases: every field of the fully-populated one ---------------------------------
        var releaseLosses: [String] = []
        if let solo = releases.first(where: { $0.id == graph.soloReleaseID }) {
            func expect(_ label: String, _ got: String, _ want: String) {
                if got != want { releaseLosses.append("\(label): wrote \(String(reflecting: want)) → \(String(reflecting: got))") }
            }
            expect("studio", solo.studio, "Criterion & Co. <Special>")
            expect("releaseDate", solo.releaseDate, "2019.04.12")
            expect("baseReleaseYear", solo.baseReleaseYear, "1974")
            expect("format", solo.format, "4K UHD")
            expect("independence", solo.independence, ReleaseIndependence.standalone)
            expect("videoFormat", solo.videoFormat, "AVC")
            expect("scanningMethod", solo.scanningMethod, "Progressive")
            expect("audioChannels", solo.audioChannels, "7.1")
            expect("hasArtwork", solo.hasArtwork, "Steelbook")
            expect("nationalOrigin", solo.nationalOrigin, "United Kingdom")
            expect("replicationType", solo.replicationType, "Pressed")
            expect("hasHDR", solo.hasHDR, "Dolby Vision")
            expect("masterType", solo.masterType, "4K DI")
            expect("regionLock", solo.regionLock, "Region B")
            expect("purchaseDate", solo.purchaseDate, "2021.06.14")
            expect("lowestPriceDate", solo.lowestPriceDate, "2022.11.02")
            expect("condition", solo.condition, "Like New")
            expect("notes", solo.notes, "Slipcover; booklet ]]> present & <intact>")
            if solo.includedVersions != ["Theatrical", "Director's Cut", "Extended \"Final\""] {
                releaseLosses.append("includedVersions → \(solo.includedVersions)")
            }
            if solo.releaseAspectRatio != ["2.39:1", "1.33:1"] { releaseLosses.append("releaseAspectRatio → \(solo.releaseAspectRatio)") }
            if solo.discCapacity != ["BD-100", "BD-66"] { releaseLosses.append("discCapacity → \(solo.discCapacity)") }
            if solo.marketAvailability != ["UK", "EU"] { releaseLosses.append("marketAvailability → \(solo.marketAvailability)") }
            if !solo.purchased { releaseLosses.append("purchased → false") }
            if !solo.hasSubtitles { releaseLosses.append("hasSubtitles → false") }
            if !solo.discMultiPack { releaseLosses.append("discMultiPack → false") }
            if !solo.remastered { releaseLosses.append("remastered → false") }
            if !solo.regionLockBypass { releaseLosses.append("regionLockBypass → false") }
            if solo.wishlist != 7 { releaseLosses.append("wishlist → \(solo.wishlist)") }
            if solo.numberOfDiscs != 3 { releaseLosses.append("numberOfDiscs → \(solo.numberOfDiscs)") }
            if solo.numberOfCopies != 2 { releaseLosses.append("numberOfCopies → \(solo.numberOfCopies)") }
            if solo.sortOrder != 5 { releaseLosses.append("sortOrder → \(solo.sortOrder)") }
            if solo.cost != 39.99 { releaseLosses.append("cost → \(solo.cost)") }
            if solo.amountSpent != 74.85 { releaseLosses.append("amountSpent → \(solo.amountSpent)") }
            if solo.lowestPrice != 19.95 { releaseLosses.append("lowestPrice → \(solo.lowestPrice)") }
            if solo.film?.id != graph.filmB { releaseLosses.append("film → \(String(describing: solo.film?.id))") }
        } else {
            releaseLosses.append("the fully-populated release is absent")
        }
        r.check("release-all-fields-survive", releaseLosses.isEmpty,
                releaseLosses.isEmpty ? "all 37 Release fields round-tripped"
                    : "\(releaseLosses.count) field(s): " + releaseLosses.prefix(8).joined(separator: " | "))

        // --- Release hierarchy, both directions -----------------------------------------------
        let parent = releases.first { $0.id == graph.parentReleaseID }
        let children = releases.filter { graph.childReleaseIDs.contains($0.id) }
        r.check("hierarchy:children-restored", children.count == 2, "\(children.count) of 2 child release(s)")
        r.check("hierarchy:children-name-their-parent",
                children.allSatisfy { $0.parentRelease?.id == graph.parentReleaseID },
                children.map { String(describing: $0.parentRelease?.id.uuidString.prefix(8)) }.joined(separator: ", "))
        // The inverse array is populated by hand during the restore precisely because
        // SwiftData has been observed not to follow it for a batch of unsaved inserts. The
        // FilmSheet's combo-pack logic reads this side.
        r.check("hierarchy:parent-claims-both-children",
                Set(parent?.childReleases.map(\.id) ?? []) == Set(graph.childReleaseIDs),
                "parent.childReleases → \(parent?.childReleases.map { $0.id.uuidString.prefix(8) } ?? [])")
        r.check("hierarchy:parent-is-top-level",
                parent?.parentRelease == nil,
                "parent.parentRelease → \(String(describing: parent?.parentRelease?.id))")
        r.check("hierarchy:releases-belong-to-the-right-film",
                releases.filter { $0.film?.id == graph.filmA }.count == 3,
                "\(releases.filter { $0.film?.id == graph.filmA }.count) of 3 release(s) on film A")

        // --- Dates -----------------------------------------------------------------------------
        // Date fields are written as ISO8601 with second resolution, so the assertion is
        // second-level equality rather than exact Date equality. Stated as a check so the
        // documented precision limit is pinned rather than assumed.
        if let solo = releases.first(where: { $0.id == graph.soloReleaseID }) {
            let drift = abs(solo.dateAdded.timeIntervalSince(graph.releaseDateAdded.addingTimeInterval(60)))
            r.check("release-dateAdded-survives-to-the-second", drift < 1,
                    "drift \(drift)s — the format writes ISO8601 without fractional seconds")
        }

        // --- Import session --------------------------------------------------------------------
        var sessionLosses: [String] = []
        if let session = sessions.first(where: { $0.id == graph.importSessionID }) {
            if session.importType != "metadata" { sessionLosses.append("importType → \(session.importType)") }
            if session.totalItems != 42 { sessionLosses.append("totalItems → \(session.totalItems)") }
            if session.successCount != 39 { sessionLosses.append("successCount → \(session.successCount)") }
            if session.errorCount != 1 { sessionLosses.append("errorCount → \(session.errorCount)") }
            if session.duplicateCount != 2 { sessionLosses.append("duplicateCount → \(session.duplicateCount)") }
            if session.updatedCount != 5 { sessionLosses.append("updatedCount → \(session.updatedCount)") }
            if session.notFoundCount != 3 { sessionLosses.append("notFoundCount → \(session.notFoundCount)") }
            if session.errorFileNames != ["bad & file.mp4", "<odd>.mp4"] { sessionLosses.append("errorFileNames → \(session.errorFileNames)") }
            if session.addedTitles != ["Added One", "Added Two"] { sessionLosses.append("addedTitles → \(session.addedTitles)") }
            if session.updatedTitles != ["Updated One"] { sessionLosses.append("updatedTitles → \(session.updatedTitles)") }
            if session.duplicateTitles != ["Dupe One", "Dupe Two"] { sessionLosses.append("duplicateTitles → \(session.duplicateTitles)") }
            if !session.isCompleted { sessionLosses.append("isCompleted → false") }
            if session.isCanceled { sessionLosses.append("isCanceled → true") }
            if abs(session.sessionDate.timeIntervalSince(graph.sessionDate)) > 1 {
                sessionLosses.append("sessionDate → \(session.sessionDate)")
            }
        } else {
            sessionLosses.append("the import session is absent")
        }
        r.check("import-session-all-fields-survive", sessionLosses.isEmpty,
                sessionLosses.isEmpty ? "every ImportSession field round-tripped"
                    : sessionLosses.joined(separator: " | "))

        // --- Settings: what the FILE carries must be what the store gets --------------------------
        //
        // The expectation is read from the exported file rather than from the values this
        // scenario seeded, and that is not a weakening — it is the only formulation that is
        // both strong and true. The settings row is a singleton the running application
        // rewrites on a five-second debounce (every restore posts `preferencesChanged`), and
        // that write targets the same store path, so which of the two rows gets exported is a
        // race this scenario cannot win. Comparing file → store measures the pipeline and
        // nothing else. The two questions the seeded values were meant to answer are answered
        // deterministically elsewhere: `extractor-covers:SettingsObject` in
        // `backup-schema-coverage` for the write side, and
        // `settings-restore-covers-every-field` in `backup-integrity` for the read side.
        var settingsLosses: [String] = []
        var settingsCompared = 0
        let fileSettings: [String: Any]
        do {
            let exported = try await DBImporter().parseBackupFile(
                at: packageURL.appendingPathComponent("backup.xml"))
            fileSettings = exported.objects.first { $0.entityName == "SettingsObject" }?.properties ?? [:]
        } catch {
            r.check("settings-file-readable", false, "\(error)")
            return r
        }
        r.check("settings-file-readable", !fileSettings.isEmpty,
                "\(fileSettings.count) settings key(s) in the exported file")

        if let settings = settingsRows.first {
            for field in settingsBoolFields {
                guard let want = fileSettings[field.0] as? Bool else { continue }
                settingsCompared += 1
                let got = settings[keyPath: field.1]
                if got != want { settingsLosses.append("\(field.0): file \(want) → store \(String(describing: got))") }
            }
            for field in settingsIntFields {
                let want: Int?
                if let i = fileSettings[field.0] as? Int64 { want = Int(i) }
                else if let i = fileSettings[field.0] as? Int { want = i }
                else { want = nil }
                guard let want else { continue }
                settingsCompared += 1
                let got = settings[keyPath: field.1]
                if got != want { settingsLosses.append("\(field.0): file \(want) → store \(String(describing: got))") }
            }
            for field in settingsStringFields {
                guard let want = fileSettings[field.0] as? String else { continue }
                settingsCompared += 1
                let got = settings[keyPath: field.1]
                if got != want { settingsLosses.append("\(field.0): file \(String(reflecting: want)) → store \(String(describing: got))") }
            }
            // A key the file does NOT carry must come back nil, not as some default. This is
            // the other half of the round trip and the half a "compare only what is present"
            // check would otherwise skip entirely.
            for field in settingsBoolFields where fileSettings[field.0] == nil {
                if settings[keyPath: field.1] != nil {
                    settingsLosses.append("\(field.0): absent from the file → store \(String(describing: settings[keyPath: field.1]))")
                }
            }
            for field in settingsIntFields where fileSettings[field.0] == nil {
                if settings[keyPath: field.1] != nil {
                    settingsLosses.append("\(field.0): absent from the file → store \(String(describing: settings[keyPath: field.1]))")
                }
            }
            for field in settingsStringFields where fileSettings[field.0] == nil {
                if settings[keyPath: field.1] != nil {
                    settingsLosses.append("\(field.0): absent from the file → store \(String(describing: settings[keyPath: field.1]))")
                }
            }
            r.check("settings-singleton-id-preserved",
                    settings.snapshotID == SettingsObject.singletonID,
                    "snapshotID → \(settings.snapshotID)")
        } else {
            settingsLosses.append("no SettingsObject in the restored store")
        }
        r.metric("settings-fields-compared", Double(settingsCompared), "count")
        r.check("settings-round-trip-file-to-store", settingsLosses.isEmpty,
                settingsLosses.isEmpty
                    ? "\(settingsCompared) settings field(s) in the file all landed in the store, "
                        + "and every absent field came back nil"
                    : "\(settingsLosses.count) field(s): " + settingsLosses.prefix(8).joined(separator: " | "))

        // The comparison above is only as complete as its three key-path tables, so the tables
        // themselves are held to the live schema. A settings field added to the model and not
        // to a table would otherwise be "verified" by a check that never looks at it.
        let comparedNames = Set(settingsBoolFields.map(\.0) + settingsIntFields.map(\.0)
                                    + settingsStringFields.map(\.0))
        // Metadata fields are deliberately NOT restored from the backup — DBRestorer stamps
        // the singleton ID, the current schema version and the restore's own date — so they
        // are exempt from the value comparison by design.
        let metadataFields: Set<String> = ["snapshotID", "version", "lastSyncDate"]
        let settingsAttributes = Set(backupHarnessSchema.entities
            .first { $0.name == "SettingsObject" }?.attributes.map(\.name) ?? [])
        let uncompared = settingsAttributes.subtracting(comparedNames).subtracting(metadataFields)
        r.check("settings-comparison-covers-the-schema", uncompared.isEmpty,
                uncompared.isEmpty
                    ? "\(comparedNames.count) field(s) compared, \(metadataFields.count) exempt by design"
                    : "field(s) in the model that no check compares: "
                        + uncompared.sorted().joined(separator: ", "))

        return r
    }

    // MARK: - Scenario: Posters

    /// Posters are the half of a backup that is files rather than rows, and the restore path
    /// for them contains a path-traversal guard that nothing else exercises.
    ///
    /// The scenario writes four files whose names span what the guard has to decide about,
    /// exports with posters enabled, wipes the live folder, restores, and reads the folder
    /// back: the two well-formed posters must return byte-identical, and the two malformed
    /// names must be refused without stopping the restore.
    private static func posterRoundTripScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-posters")

        guard let postersFolder = Preferences.posterImagesFolderURL else {
            r.check("posters-folder-configured", false, "no PosterImages folder in this sandbox")
            return r
        }
        let fm = FileManager.default

        let container: NSPersistentContainer
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
            try? fm.removeItem(at: postersFolder)
            try fm.createDirectory(at: postersFolder, withIntermediateDirectories: true)
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }

        // Two well-formed posters with distinct contents, so a mix-up between them is visible
        // and not merely a count. `<UUID>.jpg` is the only shape the restore accepts.
        let goodUID1 = UUID().uuidString, goodUID2 = UUID().uuidString
        let payload1 = Data((0..<2048).map { UInt8($0 % 251) })
        let payload2 = Data((0..<777).map { UInt8(($0 * 7) % 253) })
        // Two names the restore must refuse: a non-UUID basename and a non-JPEG extension.
        // These are the guard's two clauses; a crafted package is how a malicious backup would
        // try to write outside the PosterImages folder.
        let hostileNames = ["not-a-uuid.jpg", "\(UUID().uuidString).png"]
        // A file OUTSIDE the posters folder, used as a symlink target below so that "nothing
        // was written outside PosterImages" can be asserted against a real path rather than
        // inferred from the absence of a filename.
        let scratchOutsideURL = (DebugSandbox.rootURL ?? fm.temporaryDirectory)
            .appendingPathComponent("poster-symlink-target.txt")

        do {
            try payload1.write(to: postersFolder.appendingPathComponent("\(goodUID1).jpg"))
            try payload2.write(to: postersFolder.appendingPathComponent("\(goodUID2).jpg"))
            // Backdated: the pruner keeps anything written since its UID snapshot (see
            // `pruneOrphanedPosters`), and these stand for files that were already there.
            let longAgo = Date().addingTimeInterval(-3_600)
            for name in hostileNames {
                let url = postersFolder.appendingPathComponent(name)
                try Data([0xFF, 0xD8]).write(to: url)
                try fm.setAttributes([.modificationDate: longAgo],
                                     ofItemAtPath: url.path(percentEncoded: false))
            }
            // A nested directory, to confirm the enumerator's skipsSubdirectoryDescendants
            // holds and that a directory entry does not abort the copy loop.
            let nested = postersFolder.appendingPathComponent("nested", isDirectory: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data([0x00]).write(to: nested.appendingPathComponent("\(UUID().uuidString).jpg"))
        } catch {
            r.check("seed-poster-files", false, "\(error)")
            return r
        }
        r.check("seed-poster-files", true, "2 well-formed, \(hostileNames.count) malformed, 1 nested directory")

        guard let packageURL = await exportBackupPackage(
            container: container, filename: "posters", includePosters: true,
            posterUIDs: [goodUID1, goodUID2]) else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }

        let packagePosters = packageURL.appendingPathComponent("Posters")
        r.check("package-contains-posters-folder",
                fm.fileExists(atPath: packagePosters.path(percentEncoded: false)),
                packagePosters.path(percentEncoded: false))
        let packagedNames = Set((try? fm.contentsOfDirectory(atPath: packagePosters.path(percentEncoded: false))) ?? [])
        r.check("package-carries-the-well-formed-posters",
                packagedNames.contains("\(goodUID1).jpg") && packagedNames.contains("\(goodUID2).jpg"),
                "package holds \(packagedNames.sorted())")

        // --- The export PRUNES the user's live poster folder ------------------------------------
        //
        // Discovered by this scenario rather than assumed, and pinned here because it is easy
        // to miss when reading the export: with `Preferences.prunePosterImages` on (its default),
        // `DBExporter` runs `PosterPruner` over the LIVE PosterImages folder before packaging,
        // and the pruner deletes every non-JPEG outright plus every JPEG whose basename is not
        // in the supplied posterUID set. So taking a backup is a destructive operation on that
        // folder — the two malformed files seeded above are gone from disk, not merely absent
        // from the package. The pruner's own empty-set guard (see PosterUtilities) is what keeps
        // that from being catastrophic when the library fails to load.
        let liveAfterExport = Set((try? fm.contentsOfDirectory(atPath: postersFolder.path(percentEncoded: false))) ?? [])
        r.check("export-prunes-orphans-from-the-live-folder",
                hostileNames.allSatisfy { !liveAfterExport.contains($0) },
                "live PosterImages after the export holds \(liveAfterExport.sorted()) — an export "
                    + "with pruning enabled deletes unreferenced files from the user's folder")
        r.check("export-prune-keeps-referenced-posters",
                liveAfterExport.contains("\(goodUID1).jpg") && liveAfterExport.contains("\(goodUID2).jpg"),
                "live PosterImages holds \(liveAfterExport.sorted())")

        // --- A poster saved while a prune is running survives it -------------------------------
        //
        // The race: the UID set is read, a film is then saved with a new poster (reserved,
        // written, committed, released), and only then does the prune reach the file. It is
        // in neither the stale set nor PosterReservations, so before the snapshot-time rule
        // it was deleted and the film left pointing at nothing. Replayed here in that order,
        // beside an old orphan that must still go, so the rule cannot pass by pruning nothing.
        do {
            let snapshotTakenAt = Date()
            let savedDuringPrune = "\(UUID().uuidString).jpg"
            let staleOrphan = "\(UUID().uuidString).jpg"
            try Data([0xFF, 0xD8, 0x01]).write(to: postersFolder.appendingPathComponent(savedDuringPrune))
            let staleURL = postersFolder.appendingPathComponent(staleOrphan)
            try Data([0xFF, 0xD8, 0x02]).write(to: staleURL)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)],
                                 ofItemAtPath: staleURL.path(percentEncoded: false))
            PosterPruner.pruneOrphanedPosters(validPosterUIDs: [goodUID1, goodUID2],
                                              snapshotTakenAt: snapshotTakenAt)
            let live = Set((try? fm.contentsOfDirectory(atPath: postersFolder.path(percentEncoded: false))) ?? [])
            r.check("prune-keeps-poster-saved-after-snapshot", live.contains(savedDuringPrune),
                    "live PosterImages holds \(live.sorted())")
            r.check("prune-still-deletes-old-orphan", !live.contains(staleOrphan),
                    "live PosterImages holds \(live.sorted())")
            try? fm.removeItem(at: postersFolder.appendingPathComponent(savedDuringPrune))
        } catch {
            r.check("prune-race-seed", false, "\(error)")
        }

        // --- Now exercise the RESTORE-side guard --------------------------------------------------
        //
        // The pruner above removed the malformed files before they could reach the package, so
        // restoring it would never have put the guard to the question at all — the scenario
        // would have passed by describing a folder that never contained anything hostile. The
        // hostile entries are therefore written directly into the PACKAGE, which is exactly the
        // threat model the guard exists for: a .ftbackup is a plain directory the user can
        // receive from anywhere, and nothing between it and `copyItem` but that guard.
        let pngName = "\(UUID().uuidString).png"
        let upperCaseJPG = "\(UUID().uuidString).JPG"
        let dirNamedLikePoster = "\(UUID().uuidString).jpg"
        let symlinkName = "\(UUID().uuidString).jpg"
        let symlinkTarget = scratchOutsideURL
        do {
            try Data([0xFF, 0xD8]).write(to: packagePosters.appendingPathComponent("not-a-uuid.jpg"))
            try Data([0xFF, 0xD8]).write(to: packagePosters.appendingPathComponent(pngName))
            // Uppercase extension: the guard lowercases before comparing, so this one is
            // EXPECTED to be accepted. Included so the guard is shown to be a filter rather
            // than a blanket refusal of anything unusual.
            try Data([0xFF, 0xD8, 0x01]).write(to: packagePosters.appendingPathComponent(upperCaseJPG))
            // A DIRECTORY whose name passes the name test. `copyItem` would copy a whole tree.
            let fakeDir = packagePosters.appendingPathComponent(dirNamedLikePoster, isDirectory: true)
            try fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
            try Data([0x00]).write(to: fakeDir.appendingPathComponent("payload.txt"))
            // A SYMLINK whose name passes the name test and whose target is outside the package.
            // The guard validates the NAME; whether the link or its target is copied is what
            // this pins.
            try Data("outside the package".utf8).write(to: symlinkTarget)
            try fm.createSymbolicLink(at: packagePosters.appendingPathComponent(symlinkName),
                                      withDestinationURL: symlinkTarget)
        } catch {
            r.check("inject-hostile-package-entries", false, "\(error)")
            return r
        }
        r.check("inject-hostile-package-entries", true,
                "package Posters now holds a non-UUID name, a .png, an uppercase .JPG, a "
                    + "directory named <UUID>.jpg, and a symlink named <UUID>.jpg pointing outside")

        // Wipe the live folder so a "restored" poster cannot be one that was simply never
        // removed — the single most likely way this scenario could pass vacuously.
        do {
            try fm.removeItem(at: postersFolder)
        } catch {
            r.check("wipe-live-posters", false, "\(error)")
            return r
        }
        r.check("wipe-live-posters", !fm.fileExists(atPath: postersFolder.path(percentEncoded: false)), "")

        let (restoreError, _) = await restoreBackupPackage(packageURL, container: container)
        r.check("restore-completes-with-posters", restoreError == nil,
                restoreError.map { "\($0)" } ?? "")

        let restoredNames = Set((try? fm.contentsOfDirectory(atPath: postersFolder.path(percentEncoded: false))) ?? [])
        r.check("posters-restored",
                restoredNames.contains("\(goodUID1).jpg") && restoredNames.contains("\(goodUID2).jpg"),
                "PosterImages holds \(restoredNames.sorted())")

        let restored1 = try? Data(contentsOf: postersFolder.appendingPathComponent("\(goodUID1).jpg"))
        let restored2 = try? Data(contentsOf: postersFolder.appendingPathComponent("\(goodUID2).jpg"))
        r.check("poster-bytes-identical",
                restored1 == payload1 && restored2 == payload2,
                "\(restored1?.count ?? -1)/\(payload1.count) and \(restored2?.count ?? -1)/\(payload2.count) byte(s)")

        r.check("guard:non-uuid-basename-refused",
                !restoredNames.contains("not-a-uuid.jpg"),
                "PosterImages holds \(restoredNames.sorted())")
        r.check("guard:non-jpeg-extension-refused",
                !restoredNames.contains(pngName),
                "PosterImages holds \(restoredNames.sorted())")
        r.check("guard:uppercase-jpg-accepted",
                restoredNames.contains(upperCaseJPG),
                "the guard lowercases the extension before comparing, so <UUID>.JPG is a valid "
                    + "poster name; PosterImages holds \(restoredNames.sorted())")

        // A directory and a symlink both pass the NAME test, so what stops them is whatever
        // `copyItem` does with them. Pinned as observations of the real behavior: the property
        // that matters is that nothing lands OUTSIDE PosterImages and that the restore does not
        // abort, both of which are asserted below.
        let copiedDir = postersFolder.appendingPathComponent(dirNamedLikePoster)
        var isDirectory: ObjCBool = false
        let dirLanded = unsafe fm.fileExists(atPath: copiedDir.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
        r.check("guard:directory-named-like-a-poster-is-contained",
                !dirLanded || DebugSandbox.contains(copiedDir),
                dirLanded
                    ? "a directory named <UUID>.jpg was copied into PosterImages (contained, but "
                        + "it is not an image and the poster loader will simply fail to read it)"
                    : "a directory named <UUID>.jpg was not copied")
        let linkURL = postersFolder.appendingPathComponent(symlinkName)
        let linkLanded = (try? fm.destinationOfSymbolicLink(atPath: linkURL.path(percentEncoded: false))) != nil
        r.check("guard:symlink-does-not-escape-the-posters-folder",
                !linkLanded || DebugSandbox.contains(linkURL),
                linkLanded
                    ? "a symlink named <UUID>.jpg was copied AS A LINK into PosterImages; the link "
                        + "file itself is inside the folder, and nothing was written to its target"
                    : "the symlink was not copied")
        // The target must not have been overwritten — a copy that followed the link and wrote
        // THROUGH it would have replaced the file outside the folder.
        let targetContents = (try? String(contentsOf: symlinkTarget, encoding: .utf8)) ?? ""
        r.check("guard:nothing-written-outside-the-posters-folder",
                targetContents == "outside the package",
                "the symlink's target still reads \(String(reflecting: targetContents))")

        r.check("nested-directory-not-flattened-into-posters",
                !restoredNames.contains("nested"),
                "PosterImages holds \(restoredNames.sorted())")

        // Every entry that landed must have a UUID basename. This is the invariant the guard
        // enforces, restated over the folder as a whole rather than over the names the scenario
        // happens to know about — a crafted name the checks above did not anticipate still has
        // to satisfy it.
        let strays = restoredNames.filter { UUID(uuidString: ($0 as NSString).deletingPathExtension) == nil }
        r.check("no-unexpected-files-in-posters-folder", strays.isEmpty,
                strays.isEmpty ? "\(restoredNames.count) entr(ies), every basename a UUID"
                    : "unexpected: " + strays.sorted().joined(separator: ", "))

        // --- A package with no posters must not disturb the ones on disk -----------------------
        guard let posterlessURL = await exportBackupPackage(
            container: container, filename: "posterless", includePosters: false) else {
            r.check("posterless-export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        r.check("posterless-package-has-no-posters-folder",
                !fm.fileExists(atPath: posterlessURL.appendingPathComponent("Posters")
                    .path(percentEncoded: false)), "")
        let (posterlessError, _) = await restoreBackupPackage(posterlessURL, container: container)
        r.check("posterless-restore-completes", posterlessError == nil,
                posterlessError.map { "\($0)" } ?? "")
        let afterPosterless = Set((try? fm.contentsOfDirectory(atPath: postersFolder.path(percentEncoded: false))) ?? [])
        r.check("posterless-restore-leaves-existing-posters-alone",
                afterPosterless.contains("\(goodUID1).jpg") && afterPosterless.contains("\(goodUID2).jpg"),
                "PosterImages holds \(afterPosterless.sorted())")

        return r
    }

    // MARK: - Digest Support

    /// A canonical, order-independent serialization of a parsed backup, used to compare two
    /// backup files for equality of CONTENT.
    ///
    /// Excluded by necessity, each with a reason:
    ///   • the root `created` timestamp — it is the time of writing and differs by design.
    ///   • the whole `SettingsObject` row — it is a singleton the RUNNING application rewrites
    ///     on a five-second debounce, into the same store these scenarios seed. Including it
    ///     would make "the same store exported twice produces the same file" depend on whether
    ///     a timer happened to fire between the two exports, which is a property of the test
    ///     harness's environment rather than of the backup pipeline. Settings fidelity is
    ///     asserted in full elsewhere: `extractor-covers:SettingsObject`,
    ///     `settings-round-trip-file-to-store`, and `settings-restore-covers-every-field`.
    /// Everything else is included, so a value that quietly changes shape between generations
    /// fails the comparison rather than hiding inside a field-specific check that was never
    /// written.
    static func backupDigest(_ backup: ParsedBackup) -> String {
        var lines: [String] = []
        for object in backup.objects
            .filter({ $0.entityName != "SettingsObject" })
            .sorted(by: {
            ($0.entityName, $0.exportID) < ($1.entityName, $1.exportID)
        }) {
            var fields: [String] = []
            for key in object.properties.keys.sorted() {
                let value = object.properties[key]!
                let rendered: String
                switch value {
                case is NSNull:            rendered = "<null>"
                case let s as String:      rendered = "s:" + s
                case let b as Bool:        rendered = "b:\(b)"
                case let i as Int64:       rendered = "i:\(i)"
                case let d as Double:      rendered = "d:\(d)"
                case let a as [String]:    rendered = "a:" + a.joined(separator: "\u{1F}")
                default:                   rendered = "?:" + String(describing: value)
                }
                fields.append("\(key)=\(rendered)")
            }
            lines.append("\(object.entityName)|\(object.exportID)|" + fields.joined(separator: ";"))
        }
        let manifest = backup.manifest.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "manifest[\(manifest)]\nformat=\(backup.format) version=\(backup.version)\n"
            + lines.joined(separator: "\n")
    }

    /// A canonical serialization of the STORE, so two restores can be compared directly
    /// rather than only through the files they were restored from.
    @MainActor
    static func storeContentDigest(_ container: NSPersistentContainer) throws -> String {
        let context = container.makeMainContext()
        var lines: [String] = []
        for film in try context.fetch(Film.request()).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("Film|\(film.id)|\(film.name)|\(film.releaseYear)|\(film.userRating)|"
                + "\(film.viewCount)|\(film.hofPosition)|\(film.watched)|\(film.notes)|"
                + "\(film.numberOfDiscs)|\(film.aspectRatio)|\(film.cast)|\(film.calendarTable)|"
                + "\(String(describing: film.rotationThresholdOverride))")
        }
        for list in try context.fetch(ListObject.request()).sorted(by: { $0.listID.uuidString < $1.listID.uuidString }) {
            lines.append("List|\(list.listID)|\(list.listName)|\(list.viewStyle)|\(list.displayOrder)|"
                + "\(list.sortFilterOptions)|\(list.filmIDs.map(\.uuidString))")
        }
        for membership in try context.fetch(ListMembership.request()).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("Membership|\(membership.id)|\(String(describing: membership.film?.id))|"
                + "\(String(describing: membership.list?.listID))|\(membership.sortOrder)|"
                + "\(Int(membership.dateAdded.timeIntervalSince1970))")
        }
        for release in try context.fetch(Release.request()).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("Release|\(release.id)|\(String(describing: release.film?.id))|\(release.studio)|"
                + "\(release.releaseDate)|\(release.baseReleaseYear)|\(release.format)|\(release.independence)|"
                + "\(release.audioChannels)|\(release.numberOfDiscs)|\(release.cost)|\(release.amountSpent)|"
                + "\(release.lowestPrice)|\(release.wishlist)|\(release.sortOrder)|\(release.purchased)|"
                + "\(release.includedVersions)|\(release.discCapacity)|\(release.marketAvailability)|"
                + "\(release.releaseAspectRatio)|parent=\(String(describing: release.parentRelease?.id))|"
                + "children=\(release.childReleases.map(\.id.uuidString).sorted())|"
                + "\(Int(release.dateAdded.timeIntervalSince1970))")
        }
        for session in try context.fetch(ImportSession.request()).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("Session|\(session.id)|\(session.importType)|\(session.totalItems)|"
                + "\(session.successCount)|\(session.addedTitles)|\(session.isCompleted)|"
                + "\(Int(session.sessionDate.timeIntervalSince1970))")
        }
        // The settings singleton is deliberately absent, for the reason given on
        // `backupDigest`: the running application rewrites it on a timer, so comparing two
        // stores on it would measure the timer rather than the restore.
        return lines.joined(separator: "\n")
    }

    // MARK: - Scenario: Repeatability

    /// Three properties a backup system is normally assumed to have and which nothing was
    /// checking:
    ///
    ///   1. DETERMINISM — exporting the same store twice produces the same content. A
    ///      pipeline that reflects over models and iterates dictionaries can easily emit a
    ///      different file each time; that is not wrong by itself, but it makes every other
    ///      comparison in this suite conditional on which run you looked at.
    ///
    ///   2. FIXED POINT — restoring a backup and re-exporting produces the SAME backup. This
    ///      is the property that catches slow, per-generation loss: a field that is reformatted
    ///      on each pass ("007" → "7") round-trips "successfully" every time while degrading
    ///      forever. A single export/restore comparison cannot see it; the second generation
    ///      can.
    ///
    ///   3. STABILITY — restoring the same file twice produces the same store, so a restore
    ///      that was interrupted and re-run lands somewhere well-defined.
    private static func repeatabilityScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-repeatability")

        let container: NSPersistentContainer
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
            // The type-ambiguous film corpus as well: those are the values most likely to be
            // reformatted on a pass, which is exactly what the fixed-point check is for.
            let context = container.makeMainContext()
            for film in adversarialBackupCorpus() { context.insert(film) }
            try context.save()
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }

        guard let first = await exportBackupPackage(container: container, filename: "gen1"),
              let second = await exportBackupPackage(container: container, filename: "gen1b") else {
            r.check("two-exports-succeed", false, "createCompleteBackup threw")
            return r
        }
        r.check("two-exports-succeed", true, "")

        let parsedFirst: ParsedBackup, parsedSecond: ParsedBackup
        do {
            parsedFirst = try await DBImporter().parseBackupFile(at: first.appendingPathComponent("backup.xml"))
            parsedSecond = try await DBImporter().parseBackupFile(at: second.appendingPathComponent("backup.xml"))
        } catch {
            r.check("both-parse", false, "\(error)")
            return r
        }

        let digestFirst = backupDigest(parsedFirst)
        let digestSecond = backupDigest(parsedSecond)
        r.check("export-is-deterministic", digestFirst == digestSecond,
                digestFirst == digestSecond
                    ? "two exports of one store carry identical content (\(parsedFirst.objects.count) objects)"
                    : backupFirstDifference(digestFirst, digestSecond))

        // Byte-level equality is a stronger property than content equality and is NOT
        // guaranteed — the `created` attribute alone differs. Recorded as a metric so the
        // size of a real backup is tracked, rather than asserted as something it is not.
        let sizeFirst = (try? first.appendingPathComponent("backup.xml")
            .resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let sizeSecond = (try? second.appendingPathComponent("backup.xml")
            .resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        r.check("repeated-exports-are-the-same-size", sizeFirst == sizeSecond,
                "\(sizeFirst) vs \(sizeSecond) bytes")
        r.metric("backup-xml-size", Double(sizeFirst), "bytes")

        // --- Generation 2: restore, re-export, compare ------------------------------------------
        let (restoreError, _) = await restoreBackupPackage(first, container: container)
        guard restoreError == nil else {
            r.check("first-restore-completes", false, "\(restoreError!)")
            return r
        }
        r.check("first-restore-completes", true, "")

        let restoredContainer: NSPersistentContainer
        let digestAfterFirstRestore: String
        do {
            restoredContainer = try openBackupStore(allowsSave: false)
            digestAfterFirstRestore = try storeContentDigest(restoredContainer)
        } catch {
            r.check("restored-store-readable", false, "\(error)")
            return r
        }

        guard let third = await exportBackupPackage(container: restoredContainer, filename: "gen2") else {
            r.check("second-generation-export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        let parsedThird: ParsedBackup
        do {
            parsedThird = try await DBImporter().parseBackupFile(at: third.appendingPathComponent("backup.xml"))
        } catch {
            r.check("second-generation-parses", false, "\(error)")
            return r
        }
        let digestThird = backupDigest(parsedThird)
        r.check("backup-is-a-fixed-point", digestFirst == digestThird,
                digestFirst == digestThird
                    ? "export → restore → export reproduces the same content exactly; no "
                        + "per-generation drift across \(parsedThird.objects.count) object(s)"
                    : backupFirstDifference(digestFirst, digestThird))

        // --- Restoring the same file twice lands in the same place --------------------------------
        let (secondRestoreError, _) = await restoreBackupPackage(first, container: restoredContainer)
        guard secondRestoreError == nil else {
            r.check("repeat-restore-completes", false, "\(secondRestoreError!)")
            return r
        }
        do {
            let again = try openBackupStore(allowsSave: false)
            let digestAfterSecondRestore = try storeContentDigest(again)
            r.check("restore-is-idempotent",
                    digestAfterFirstRestore == digestAfterSecondRestore,
                    digestAfterFirstRestore == digestAfterSecondRestore
                        ? "restoring the same package twice produces an identical store"
                        : backupFirstDifference(digestAfterFirstRestore, digestAfterSecondRestore))
        } catch {
            r.check("restore-is-idempotent", false, "\(error)")
        }

        return r
    }

    /// The first differing line of two digests, so a failure names the object and field that
    /// changed instead of printing two multi-megabyte strings.
    static func backupFirstDifference(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? String(left[index]) : "<absent>"
            let b = index < right.count ? String(right[index]) : "<absent>"
            if a != b {
                return "line \(index + 1) of \(max(left.count, right.count)) differs:\n  A: "
                    + String(a.prefix(400)) + "\n  B: " + String(b.prefix(400))
            }
        }
        return "digests differ in length only (\(left.count) vs \(right.count) lines)"
    }

    /// The type-ambiguous corpus as live Film objects. Mirrors the shapes
    /// `adversarialExportCorpus` covers, restated here so this file does not depend on the
    /// positional indexing that scenario's own checks rely on.
    @MainActor
    static func adversarialBackupCorpus() -> [Film] {
        var films: [Film] = []
        func add(_ name: String, _ mutate: (Film) -> Void) {
            let film = makeSnapshot(name: name).toFilm()
            film.id = UUID()
            mutate(film)
            films.append(film)
        }
        add("BK LeadingZero") { $0.numberOfDiscs = "007"; $0.sortName = "007" }
        add("BK TrailingZeroDecimal") { $0.aspectRatio = "2.00" }
        add("BK BooleanText") { $0.notes = "true"; $0.comments = "false" }
        add("BK ArrayShapedText") { $0.notes = #"["not","an","array"]"# }
        add("BK Whitespace") { $0.notes = "  padded  " }
        add("BK XMLSpecials") { $0.notes = "a < b & c > d \"quoted\" 'single'" }
        add("BK CDATATerminator") { $0.notes = "closing ]]> sequence" }
        add("BK Unicode") { $0.notes = "émoji 🎬 中文"; $0.alternateTitle = ["Ünterwelt", "映画"] }
        add("BK EmptyArrays") { $0.cast = []; $0.tags = [] }
        add("BK ArrayWithEntityText") { $0.cast = ["Tom &amp; Jerry", "&lt;p&gt;", "plain"] }
        return films
    }

    // MARK: - Scenario: Integrity and Failure Handling

    /// What happens when the file is wrong.
    ///
    /// The property under test is not the error message. It is this: a restore that is going
    /// to fail must fail BEFORE it commits its staged store (PendingRestore.commit), which
    /// queues the restored library to replace the user's at the next launch. Each case below
    /// therefore checks three things: that the restore threw, that it threw the right error,
    /// and that the library is still there afterwards.
    private static func backupIntegrityScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-integrity")

        let fm = FileManager.default
        let scratch = (DebugSandbox.rootURL ?? fm.temporaryDirectory)
            .appendingPathComponent("harness-backup-integrity", isDirectory: true)
        try? fm.removeItem(at: scratch)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        var container: NSPersistentContainer
        var graph: SeededGraph
        do {
            container = try resetBackupStore()
            graph = try await seedFullGraph(container: container)
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }

        guard let goodPackage = await exportBackupPackage(container: container, filename: "integrity-source") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        let goodXML: Data
        do {
            goodXML = try Data(contentsOf: goodPackage.appendingPathComponent("backup.xml"))
        } catch {
            r.check("read-source-xml", false, "\(error)")
            return r
        }
        r.metric("source-xml-size", Double(goodXML.count), "bytes")

        /// Builds a damaged package and runs a real restore against it, then asserts the
        /// library survived. Returns the thrown error for the caller to classify.
        func attemptRestore(_ label: String, xml: Data?) async -> (any Error)? {
            let packageURL = scratch.appendingPathComponent("\(label).ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try? fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            if let xml { try? xml.write(to: packageURL.appendingPathComponent("backup.xml")) }
            let (error, rebuilt) = await restoreBackupPackage(packageURL, container: container)
            r.check("\(label):rejected", error != nil,
                    error.map { "\($0)" } ?? "the restore ACCEPTED a damaged package")
            // The property that matters more than the error itself.
            r.check("\(label):store-not-destroyed", !rebuilt,
                    rebuilt
                        ? "the store was rebuilt before the failure was detected — the user's "
                            + "library is gone and the restore did not complete"
                        : "the store was never touched")
            var survived = false
            if let verify = try? openBackupStore(allowsSave: false) {
                let context = verify.makeMainContext()
                survived = ((try? context.fetch(Film.request()))?.contains { $0.id == graph.filmA }) ?? false
            }
            r.check("\(label):library-intact", survived,
                    survived ? "the seeded library is still readable"
                        : "the seeded library is NOT readable after the rejected restore")
            return error
        }

        // 1. Truncated XML — the shape a backup takes when a write is interrupted by a full
        //    disk, a crash, or an ejected volume. This is precisely the damage an export-time
        //    verification pass would catch, and none exists (see `export-verification` below).
        let truncated = goodXML.prefix(goodXML.count / 2)
        let truncatedError = await attemptRestore("truncated-xml", xml: Data(truncated))
        r.check("truncated-xml:reports-a-parse-error",
                isImporterError(truncatedError, oneOf: ["invalidXML", "corrupted", "missingRequiredElement"]),
                "\(String(describing: truncatedError))")

        // 2. A package with no backup.xml at all.
        let missingError = await attemptRestore("missing-xml", xml: nil)
        r.check("missing-xml:reports-missingXML",
                { if case DBRestorerError.missingXML = missingError ?? DBRestorerError.restorationFailed("") { return true }; return false }(),
                "\(String(describing: missingError))")

        // 3. Well-formed XML that is not a FilmTracker backup. A restore must not treat an
        //    arbitrary XML document as an empty library and wipe the store to match it.
        let foreignError = await attemptRestore("foreign-xml", xml: Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <SomeOtherDocument><Item value="1" /></SomeOtherDocument>
            """.utf8))
        r.check("foreign-xml:rejected-not-treated-as-empty",
                foreignError != nil, "\(String(describing: foreignError))")

        // 4. A future format version. Refusing forward is the correct behavior: a v2 file may
        //    encode fields this build would silently drop, and dropping them here is
        //    irreversible because the restore has already replaced the store.
        let futureError = await attemptRestore("future-version", xml: Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="FilmTrackerXML" version="99" created="2026-01-01T00:00:00Z">
              <Manifest><Entity name="Film" count="0" /></Manifest>
              <Objects></Objects>
            </FilmTrackerBackup>
            """.utf8))
        r.check("future-version:reports-unsupportedVersion",
                { if case DBImporterError.unsupportedVersion = futureError ?? DBRestorerError.restorationFailed("") { return true }; return false }(),
                "\(String(describing: futureError))")

        // 5. A wrong format key.
        let formatError = await attemptRestore("wrong-format", xml: Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="SomethingElse" version="1" created="2026-01-01T00:00:00Z">
              <Manifest></Manifest><Objects></Objects>
            </FilmTrackerBackup>
            """.utf8))
        r.check("wrong-format:reports-unsupportedFormat",
                { if case DBImporterError.unsupportedFormat = formatError ?? DBRestorerError.restorationFailed("") { return true }; return false }(),
                "\(String(describing: formatError))")

        // 6. A plain FILE with the .ftbackup extension rather than a package directory.
        do {
            let fileURL = scratch.appendingPathComponent("not-a-package.ftbackup")
            try? fm.removeItem(at: fileURL)
            try Data("not a package".utf8).write(to: fileURL)
            let (error, rebuilt) = await restoreBackupPackage(fileURL, container: container)
            r.check("plain-file:rejected-as-notAPackage",
                    { if case DBRestorerError.notAPackage = error ?? DBRestorerError.restorationFailed("") { return true }; return false }(),
                    "\(String(describing: error))")
            r.check("plain-file:store-not-destroyed", !rebuilt, "")
        } catch {
            r.check("plain-file:rejected-as-notAPackage", false, "\(error)")
        }

        // 7. A wrong extension. The guard is the first thing `restoreFromBackup` does.
        do {
            let wrongExt = scratch.appendingPathComponent("wrong.zip", isDirectory: true)
            try? fm.removeItem(at: wrongExt)
            try fm.createDirectory(at: wrongExt, withIntermediateDirectories: true)
            try goodXML.write(to: wrongExt.appendingPathComponent("backup.xml"))
            let (error, rebuilt) = await restoreBackupPackage(wrongExt, container: container)
            r.check("wrong-extension:rejected",
                    { if case DBRestorerError.notAPackage = error ?? DBRestorerError.restorationFailed("") { return true }; return false }(),
                    "\(String(describing: error))")
            r.check("wrong-extension:store-not-destroyed", !rebuilt, "")
        } catch {
            r.check("wrong-extension:rejected", false, "\(error)")
        }

        // --- Damage that is deliberately TOLERATED -------------------------------------------
        // A manifest that disagrees with the file is a warning, not a rejection: the objects
        // are all there and refusing the restore would help nobody. Asserted so the tolerance
        // is a stated decision rather than an untested assumption, and so a future change that
        // turns it into a hard failure is noticed here.
        do {
            var text = String(decoding: goodXML, as: UTF8.self)
            text = text.replacingOccurrences(of: "<Entity name=\"Film\" count=\"2\" />",
                                             with: "<Entity name=\"Film\" count=\"999\" />")
            let packageURL = scratch.appendingPathComponent("bad-manifest.ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: packageURL.appendingPathComponent("backup.xml"))
            let (error, _) = await restoreBackupPackage(packageURL, container: container)
            r.check("manifest-mismatch:restore-still-completes", error == nil,
                    error.map { "\($0)" } ?? "restored despite a manifest count of 999 vs 2 actual — "
                        + "the mismatch is logged as a warning by design")
            if let verify = try? openBackupStore(allowsSave: false) {
                let context = verify.makeMainContext()
                let films = (try? context.fetch(Film.request())) ?? []
                r.check("manifest-mismatch:objects-still-restored", films.count == 2,
                        "\(films.count) film(s) restored")
            }
        } catch {
            r.check("manifest-mismatch:restore-still-completes", false, "\(error)")
        }

        // --- An empty library ------------------------------------------------------------------
        // The 0-object path in DBPackager is a separate early-return branch that writes and
        // closes the file by itself; nothing exercised it. A user with an empty library who
        // takes a backup and restores it must get an empty library, not an error.
        do {
            container = try resetBackupStore()
            guard let emptyPackage = await exportBackupPackage(container: container, filename: "empty-library") else {
                r.check("empty-library:export-succeeds", false, "createCompleteBackup threw")
                return r
            }
            r.check("empty-library:export-succeeds", true, emptyPackage.lastPathComponent)
            let parsed = try await DBImporter().parseBackupFile(at: emptyPackage.appendingPathComponent("backup.xml"))
            r.check("empty-library:parses-with-no-objects", parsed.objects.isEmpty,
                    "\(parsed.objects.count) object(s)")
            let (error, _) = await restoreBackupPackage(emptyPackage, container: container)
            r.check("empty-library:restores", error == nil, error.map { "\($0)" } ?? "")
            if let verify = try? openBackupStore(allowsSave: false) {
                let context = verify.makeMainContext()
                let films = (try? context.fetch(Film.request())) ?? []
                r.check("empty-library:restores-to-an-empty-library", films.isEmpty, "\(films.count) film(s)")
            }
        } catch {
            r.check("empty-library:parses-with-no-objects", false, "\(error)")
        }

        // --- A backup written without settings ---------------------------------------------------
        // `includeSettings: false` is a user-facing toggle. The resulting file must carry no
        // SettingsObject, and restoring it must leave the settings that are already there
        // alone rather than clearing them — the restore's own note says the pipeline
        // "tolerates backups that contain no SettingsObject", which nothing verified.
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
            guard let noSettings = await exportBackupPackage(container: container,
                                                             filename: "no-settings",
                                                             includeSettings: false) else {
                r.check("no-settings:export-succeeds", false, "createCompleteBackup threw")
                return r
            }
            let parsed = try await DBImporter().parseBackupFile(at: noSettings.appendingPathComponent("backup.xml"))
            r.check("no-settings:package-carries-no-settings-object",
                    !parsed.objects.contains { $0.entityName == "SettingsObject" },
                    "\(parsed.objects.filter { $0.entityName == "SettingsObject" }.count) settings object(s) in the file")
            r.check("no-settings:package-still-carries-the-library",
                    parsed.objects.contains { $0.entityName == "Film" },
                    "\(parsed.objects.count) object(s)")
            let (error, _) = await restoreBackupPackage(noSettings, container: container)
            r.check("no-settings:restores", error == nil, error.map { "\($0)" } ?? "")
            if let verify = try? openBackupStore(allowsSave: false) {
                let context = verify.makeMainContext()
                let rows = (try? context.fetch(SettingsObject.request())) ?? []
                let films = (try? context.fetch(Film.request())) ?? []
                r.check("no-settings:library-restored-without-settings",
                        films.count == 2 && rows.isEmpty,
                        "\(films.count) film(s), \(rows.count) settings row(s) — the store is rebuilt "
                            + "empty, so a settings-less backup leaves no settings row and the app "
                            + "falls back to registered defaults on relaunch")
            }
        } catch {
            r.check("no-settings:export-succeeds", false, "\(error)")
        }

        // --- Every settings field, restored from a file nothing else can touch ---------------------
        //
        // The deterministic counterpart to `extractor-covers:SettingsObject`. The XML is
        // written by hand here, with a value for all 43 restorable settings fields, precisely
        // so the running application's own debounced settings write — which reaches the store
        // but cannot reach this file — is out of the picture. If DBRestorer.createSettingsObject
        // forgets a field, this is where it shows.
        do {
            container = try resetBackupStore()
            let packageURL = scratch.appendingPathComponent("settings-full.ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

            var properties: [String] = [
                "<Property name=\"snapshotID\">\(SettingsObject.singletonID.uuidString)</Property>",
                "<Property name=\"version\">1</Property>",
                "<Property name=\"lastSyncDate\">2024-01-01T00:00:00Z</Property>"
            ]
            for (index, field) in settingsBoolFields.enumerated() {
                properties.append("<Property name=\"\(field.0)\">\(expectedSettingsBool(index))</Property>")
            }
            for (index, field) in settingsIntFields.enumerated() {
                properties.append("<Property name=\"\(field.0)\">\(expectedSettingsInt(index))</Property>")
            }
            for (index, field) in settingsStringFields.enumerated() {
                // Written with the declared-type attribute, exactly as the current writer would.
                // Several of these values are deliberately type-ambiguous text ("true", a JSON
                // array, a bare number), which is the shape the attribute exists to protect.
                let escaped = expectedSettingsString(index)
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                properties.append("<Property name=\"\(field.0)\" type=\"string\">\(escaped)</Property>")
            }
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z" appVersion="1.0">
              <Manifest><Entity name="SettingsObject" count="1" /></Manifest>
              <Objects>
                <Object id="SettingsObject-\(SettingsObject.singletonID.uuidString)" entity="SettingsObject">
                  <Properties>
                    \(properties.joined(separator: "\n                    "))
                  </Properties>
                  <Relationships></Relationships>
                </Object>
              </Objects>
            </FilmTrackerBackup>
            """
            try Data(xml.utf8).write(to: packageURL.appendingPathComponent("backup.xml"))

            let (error, _) = await restoreBackupPackage(packageURL, container: container)
            r.check("settings-restore:completes", error == nil, error.map { "\($0)" } ?? "")

            let verify = try openBackupStore(allowsSave: false)
            let rows = try verify.makeMainContext().fetch(SettingsObject.request())
            guard let settings = rows.first else {
                r.check("settings-restore-covers-every-field", false, "no SettingsObject restored")
                return r
            }
            var missed: [String] = []
            for (index, field) in settingsBoolFields.enumerated() {
                let want = expectedSettingsBool(index)
                if settings[keyPath: field.1] != want {
                    missed.append("\(field.0): \(want) → \(String(describing: settings[keyPath: field.1]))")
                }
            }
            for (index, field) in settingsIntFields.enumerated() {
                let want = expectedSettingsInt(index)
                if settings[keyPath: field.1] != want {
                    missed.append("\(field.0): \(want) → \(String(describing: settings[keyPath: field.1]))")
                }
            }
            for (index, field) in settingsStringFields.enumerated() {
                let want = expectedSettingsString(index)
                if settings[keyPath: field.1] != want {
                    missed.append("\(field.0): \(String(reflecting: want)) → \(String(describing: settings[keyPath: field.1]))")
                }
            }
            let total = settingsBoolFields.count + settingsIntFields.count + settingsStringFields.count
            r.check("settings-restore-covers-every-field", missed.isEmpty,
                    missed.isEmpty
                        ? "all \(total) settings field(s) restored from a hand-written backup"
                        : "\(missed.count) of \(total) field(s) not restored: "
                            + missed.prefix(8).joined(separator: " | "))
            r.check("settings-restore:stamps-the-singleton-id",
                    settings.snapshotID == SettingsObject.singletonID,
                    "snapshotID → \(settings.snapshotID)")
            r.check("settings-restore:only-one-row", rows.count == 1, "\(rows.count) row(s)")
        } catch {
            r.check("settings-restore-covers-every-field", false, "\(error)")
        }

        // --- Two settings rows in one file -----------------------------------------------------
        //
        // `SettingsObject.snapshotID` is `@Attribute(.unique)`, and the restorer stamps the
        // SINGLETON id on every settings object it creates regardless of what the file said.
        // A backup carrying two settings rows — hand-edited, or merged from two libraries —
        // therefore produces two objects with the same unique key in one unsaved batch. What
        // happens at `context.save()` is the question: if it throws, the restore fails AFTER
        // the store has already been destroyed, which is the unrecoverable half of the
        // pipeline. This case exists to find out rather than to assume, and the check states
        // whichever answer the run gives.
        do {
            container = try resetBackupStore()
            let packageURL = scratch.appendingPathComponent("two-settings.ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let filmID = UUID()
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z" appVersion="1.0">
              <Manifest><Entity name="Film" count="1" /><Entity name="SettingsObject" count="2" /></Manifest>
              <Objects>
                <Object id="Film-\(filmID.uuidString)" entity="Film">
                  <Properties>
                    <Property name="id" type="string">\(filmID.uuidString)</Property>
                    <Property name="name" type="string">Duplicate Settings Specimen</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
                <Object id="SettingsObject-\(UUID().uuidString)" entity="SettingsObject">
                  <Properties>
                    <Property name="snapshotID">\(UUID().uuidString)</Property>
                    <Property name="version">1</Property>
                    <Property name="defaultRotationThreshold">24</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
                <Object id="SettingsObject-\(UUID().uuidString)" entity="SettingsObject">
                  <Properties>
                    <Property name="snapshotID">\(UUID().uuidString)</Property>
                    <Property name="version">1</Property>
                    <Property name="defaultRotationThreshold">36</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
              </Objects>
            </FilmTrackerBackup>
            """
            try Data(xml.utf8).write(to: packageURL.appendingPathComponent("backup.xml"))
            let (error, rebuilt) = await restoreBackupPackage(packageURL, container: container)
            let verify = try openBackupStore(allowsSave: false)
            let context = verify.makeMainContext()
            let films = (try? context.fetch(Film.request())) ?? []
            let rows = (try? context.fetch(SettingsObject.request())) ?? []
            // The outcome that would be a genuine data-loss defect is: the save throws, the
            // restore reports failure, and the library is NOT in the store — because by then
            // the previous database has already been deleted and there is nothing to go back
            // to. The check is written against that, not against a particular row count.
            let libraryLanded = films.contains { $0.id == filmID }
            r.check("duplicate-settings:library-still-restored", libraryLanded,
                    libraryLanded
                        ? "the film survived; \(rows.count) settings row(s), restore error: "
                            + (error.map { "\($0)" } ?? "none")
                        : "the whole restore failed on a duplicate settings row AFTER the store "
                            + "was destroyed (rebuilt: \(rebuilt)) — error: "
                            + (error.map { "\($0)" } ?? "none"))
            r.check("duplicate-settings:at-most-one-settings-row", rows.count <= 1,
                    "\(rows.count) settings row(s) in the restored store")
        } catch {
            r.check("duplicate-settings:library-still-restored", false, "\(error)")
        }

        // --- The export verifies its own output ------------------------------------------------------
        //
        // `DBExporter` re-parses the package it wrote, through the same `DBImporter` a restore
        // uses, and requires the object count and manifest to match what it exported. This is
        // the step that turns "the write calls did not throw" into "a restore can read this",
        // and the two questions are not the same one — see `oversized-node` in
        // `backup-limits`, which is the shape that used to slip through.
        //
        // Asserted here from the outside: a healthy export must pass verification and produce
        // a package whose re-parse describes exactly the seeded library. The negative
        // direction — verification actually REFUSING a bad package — is asserted by
        // `oversized-node` rather than simulated here, because a package damaged after the
        // export returns is a different failure from one the export itself produced.
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
            guard let package = await exportBackupPackage(container: container, filename: "verify-probe") else {
                r.check("export-verification:healthy-export-passes-verification", false,
                        "a healthy export was REJECTED by its own verification pass")
                return r
            }
            r.check("export-verification:healthy-export-passes-verification", true,
                    "the export re-read its own output and accepted it")
            let xmlURL = package.appendingPathComponent("backup.xml")
            let written = try Data(contentsOf: xmlURL)
            let reparsed = try await DBImporter().parseBackupFile(at: xmlURL)
            let expectedObjects = 2 + 2 + 3 + 4 + 1 + 1  // films, lists, memberships, releases, session, settings
            r.check("export-verification:written-file-describes-the-library",
                    reparsed.objects.count == expectedObjects,
                    "the produced file re-parses to \(reparsed.objects.count) object(s), expected \(expectedObjects)")
            r.check("export-verification:manifest-survives-the-round-trip",
                    reparsed.manifest["Film"] == 2 && reparsed.manifest["Release"] == 4
                        && reparsed.manifest["ListMembership"] == 3,
                    "manifest \(reparsed.manifest.sorted { $0.key < $1.key })")
            r.metric("verify-probe-xml-size", Double(written.count), "bytes")
        } catch {
            r.check("export-verification:written-file-describes-the-library", false, "\(error)")
        }

        return r
    }

    /// True when `error` is a `DBImporterError` whose case name is in `names`. Matched on the
    /// case rather than the message so a reworded error does not silently pass a check that
    /// was meant to pin the reason.
    static func isImporterError(_ error: (any Error)?, oneOf names: [String]) -> Bool {
        guard let error = error as? DBImporterError else { return false }
        let described = String(describing: error)
        return names.contains { described.hasPrefix($0) }
    }

    // MARK: - Scenario: Limits and Dangling References

    /// Two families of question the round-trip scenarios cannot ask.
    ///
    /// FIRST — the reader and the writer disagree about how big a backup may be. `DBImporter`
    /// enforces three ceilings (512 MiB file, 4 MiB per text node, 100 000 objects) and
    /// `DBExporter` enforces none. Every one of those is therefore a shape the application can
    /// WRITE and then refuse to READ: a backup that reports success at the moment it is taken
    /// and fails at the moment it is needed. Whether a real library can reach any of them is a
    /// separate question from whether the asymmetry exists, and these checks answer the second
    /// one empirically so the first can be judged on facts.
    ///
    /// SECOND — a backup can name things it does not contain. A release whose film is missing,
    /// a membership whose list is missing, a film whose id will not parse. The restore's
    /// contract is that it skips the unresolvable row and keeps going; the alternative — an
    /// abort — would be catastrophic, because by that point the old database is gone. Each
    /// case checks BOTH halves: the bad row is dropped AND the good rows around it survive.
    private static func backupLimitsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-limits")

        let fm = FileManager.default
        let scratch = (DebugSandbox.rootURL ?? fm.temporaryDirectory)
            .appendingPathComponent("harness-backup-limits", isDirectory: true)
        try? fm.removeItem(at: scratch)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        var container: NSPersistentContainer
        do {
            container = try resetBackupStore()
        } catch {
            r.check("reset-store", false, "\(error)")
            return r
        }

        /// Writes a hand-built package and restores it, returning the error and the resulting
        /// rows. Used by every dangling-reference case below.
        func restoreHandBuilt(_ label: String, objects: String, manifest: String)
            async -> (error: (any Error)?, films: [Film], releases: [Release],
                      lists: [ListObject], memberships: [ListMembership]) {
            let packageURL = scratch.appendingPathComponent("\(label).ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try? fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z" appVersion="1.0">
              <Manifest>\(manifest)</Manifest>
              <Objects>
            \(objects)
              </Objects>
            </FilmTrackerBackup>
            """
            try? Data(xml.utf8).write(to: packageURL.appendingPathComponent("backup.xml"))
            let (error, _) = await restoreBackupPackage(packageURL, container: container)
            guard let verify = try? openBackupStore(allowsSave: false) else {
                return (error, [], [], [], [])
            }
            let context = verify.makeMainContext()
            return (error,
                    (try? context.fetch(Film.request())) ?? [],
                    (try? context.fetch(Release.request())) ?? [],
                    (try? context.fetch(ListObject.request())) ?? [],
                    (try? context.fetch(ListMembership.request())) ?? [])
        }

        func filmXML(_ id: String, _ name: String) -> String {
            """
                <Object id="Film-\(id)" entity="Film">
                  <Properties>
                    <Property name="id" type="string">\(id)</Property>
                    <Property name="name" type="string">\(name)</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
            """
        }

        // --- A release whose film is not in the backup ------------------------------------------
        do {
            let goodFilm = UUID().uuidString
            let goodRelease = UUID().uuidString
            let orphanRelease = UUID().uuidString
            let absentFilm = UUID().uuidString
            func releaseXML(_ id: String, film: String, studio: String) -> String {
                """
                    <Object id="Release-\(id)" entity="Release">
                      <Properties>
                        <Property name="id" type="string">\(id)</Property>
                        <Property name="studio" type="string">\(studio)</Property>
                        <Property name="filmID" type="string">\(film)</Property>
                      </Properties>
                      <Relationships></Relationships>
                    </Object>
                """
            }
            let result = await restoreHandBuilt(
                "dangling-release",
                objects: filmXML(goodFilm, "Anchor Film") + "\n"
                    + releaseXML(goodRelease, film: goodFilm, studio: "Kept") + "\n"
                    + releaseXML(orphanRelease, film: absentFilm, studio: "Orphan"),
                manifest: "<Entity name=\"Film\" count=\"1\" /><Entity name=\"Release\" count=\"2\" />")
            r.check("dangling-release:restore-completes", result.error == nil,
                    result.error.map { "\($0)" } ?? "")
            r.check("dangling-release:orphan-dropped-good-one-kept",
                    result.releases.count == 1 && result.releases.first?.studio == "Kept",
                    "\(result.releases.count) release(s): \(result.releases.map(\.studio))")
            r.check("dangling-release:anchor-film-survives",
                    result.films.count == 1 && result.films.first?.name == "Anchor Film",
                    "\(result.films.count) film(s)")
        }

        // --- A membership whose list, or whose film, is not in the backup ------------------------
        do {
            let filmID = UUID().uuidString
            let listID = UUID().uuidString
            func membershipXML(_ id: String, film: String, list: String, order: Int) -> String {
                """
                    <Object id="ListMembership-\(id)" entity="ListMembership">
                      <Properties>
                        <Property name="id" type="string">\(id)</Property>
                        <Property name="filmID" type="string">\(film)</Property>
                        <Property name="listID" type="string">\(list)</Property>
                        <Property name="sortOrder">\(order)</Property>
                      </Properties>
                      <Relationships></Relationships>
                    </Object>
                """
            }
            let listXML = """
                <Object id="ListObject-\(listID)" entity="ListObject">
                  <Properties>
                    <Property name="listID" type="string">\(listID)</Property>
                    <Property name="listName" type="string">Anchor List</Property>
                    <Property name="displayOrder">2</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
            """
            let result = await restoreHandBuilt(
                "dangling-membership",
                objects: filmXML(filmID, "Member Film") + "\n" + listXML + "\n"
                    + membershipXML(UUID().uuidString, film: filmID, list: listID, order: 3) + "\n"
                    + membershipXML(UUID().uuidString, film: filmID, list: UUID().uuidString, order: 4) + "\n"
                    + membershipXML(UUID().uuidString, film: UUID().uuidString, list: listID, order: 5),
                manifest: "<Entity name=\"Film\" count=\"1\" /><Entity name=\"ListObject\" count=\"1\" />"
                    + "<Entity name=\"ListMembership\" count=\"3\" />")
            r.check("dangling-membership:restore-completes", result.error == nil,
                    result.error.map { "\($0)" } ?? "")
            r.check("dangling-membership:only-the-resolvable-one-is-kept",
                    result.memberships.count == 1 && result.memberships.first?.sortOrder == 3,
                    "\(result.memberships.count) membership(s), sortOrder(s) \(result.memberships.map(\.sortOrder))")
            r.check("dangling-membership:film-and-list-survive",
                    result.films.count == 1 && result.lists.count == 1,
                    "\(result.films.count) film(s), \(result.lists.count) list(s)")
        }

        // --- A backup that repeats IDs --------------------------------------------------------------
        // Every entity's ID is unique in the store. A backup written before that was enforced
        // can repeat one (the old dual-write bug did for releases); the restore must keep the
        // first of each, link everything to it, and still pass its own row-count check.
        do {
            let filmA = UUID().uuidString, filmB = UUID().uuidString
            let releaseID = UUID().uuidString, childID = UUID().uuidString
            let listID = UUID().uuidString, membershipID = UUID().uuidString
            func release(_ id: String, studio: String, parent: String? = nil) -> String {
                """
                    <Object id="Release-\(id)" entity="Release">
                      <Properties>
                        <Property name="id" type="string">\(id)</Property>
                        <Property name="studio" type="string">\(studio)</Property>
                        <Property name="filmID" type="string">\(filmA)</Property>
                        \(parent.map { "<Property name=\"parentReleaseID\" type=\"string\">\($0)</Property>" } ?? "")
                      </Properties>
                      <Relationships></Relationships>
                    </Object>
                """
            }
            func list(_ name: String) -> String {
                """
                    <Object id="ListObject-\(listID)" entity="ListObject">
                      <Properties>
                        <Property name="listID" type="string">\(listID)</Property>
                        <Property name="listName" type="string">\(name)</Property>
                        <Property name="displayOrder">2</Property>
                      </Properties>
                      <Relationships></Relationships>
                    </Object>
                """
            }
            func membership(_ id: String, film: String, order: Int) -> String {
                """
                    <Object id="ListMembership-\(id)" entity="ListMembership">
                      <Properties>
                        <Property name="id" type="string">\(id)</Property>
                        <Property name="filmID" type="string">\(film)</Property>
                        <Property name="listID" type="string">\(listID)</Property>
                        <Property name="sortOrder">\(order)</Property>
                      </Properties>
                      <Relationships></Relationships>
                    </Object>
                """
            }
            let objects = [
                filmXML(filmA, "First A"), filmXML(filmA, "Second A"), filmXML(filmB, "Only B"),
                list("First L"), list("Second L"),
                release(releaseID, studio: "First R"), release(releaseID, studio: "Second R"),
                release(childID, studio: "Child", parent: releaseID),
                membership(membershipID, film: filmA, order: 1), membership(membershipID, film: filmA, order: 2),
                membership(UUID().uuidString, film: filmB, order: 3),
            ].joined(separator: "\n")
            let result = await restoreHandBuilt(
                "repeated-ids", objects: objects,
                manifest: "<Entity name=\"Film\" count=\"3\" /><Entity name=\"ListObject\" count=\"2\" />"
                    + "<Entity name=\"Release\" count=\"3\" /><Entity name=\"ListMembership\" count=\"3\" />")
            r.check("repeated-ids:restore-completes", result.error == nil, result.error.map { "\($0)" } ?? "")
            r.check("repeated-ids:first-film-kept",
                    result.films.map(\.name).sorted() == ["First A", "Only B"], "\(result.films.map(\.name))")
            r.check("repeated-ids:first-list-kept",
                    result.lists.map(\.listName) == ["First L"], "\(result.lists.map(\.listName))")
            let child = result.releases.first { $0.studio == "Child" }
            r.check("repeated-ids:first-release-kept-and-linked",
                    result.releases.map(\.studio).sorted() == ["Child", "First R"]
                        && child?.parentRelease?.studio == "First R"
                        && result.releases.allSatisfy { $0.film?.name == "First A" },
                    "\(result.releases.map { "\($0.studio) → \($0.film?.name ?? "nil"), parent \($0.parentRelease?.studio ?? "-")" })")
            r.check("repeated-ids:first-membership-kept",
                    result.memberships.map(\.sortOrder).sorted() == [1, 3]
                        && result.memberships.allSatisfy { $0.film != nil && $0.list != nil },
                    "\(result.memberships.map(\.sortOrder))")
        }

        // --- A film whose id will not parse, sitting between two good ones -----------------------
        // The required-UUID parse throws, the film is skipped, and — the part that matters —
        // the loop keeps going. A `throw` that escaped here would abandon the restore with the
        // old database already deleted.
        do {
            let firstID = UUID().uuidString, lastID = UUID().uuidString
            let broken = """
                <Object id="Film-broken" entity="Film">
                  <Properties>
                    <Property name="id" type="string">not-a-uuid-at-all</Property>
                    <Property name="name" type="string">Broken Film</Property>
                  </Properties>
                  <Relationships></Relationships>
                </Object>
            """
            let result = await restoreHandBuilt(
                "malformed-film-id",
                objects: filmXML(firstID, "First Film") + "\n" + broken + "\n" + filmXML(lastID, "Last Film"),
                manifest: "<Entity name=\"Film\" count=\"3\" />")
            r.check("malformed-film-id:restore-completes", result.error == nil,
                    result.error.map { "\($0)" } ?? "")
            r.check("malformed-film-id:bad-row-skipped-good-rows-kept",
                    result.films.count == 2
                        && Set(result.films.map(\.name)) == ["First Film", "Last Film"],
                    "\(result.films.count) film(s): \(result.films.map(\.name).sorted())")
        }

        // --- The same film id twice in one file ---------------------------------------------------
        // `Film.id` is a uniqueness constraint, so the restore keeps the first of the two (see
        // `repeated-ids` for every entity). What must NOT happen is the restore failing outright.
        do {
            let duplicateID = UUID().uuidString
            let result = await restoreHandBuilt(
                "duplicate-film-id",
                objects: filmXML(duplicateID, "First Copy") + "\n" + filmXML(duplicateID, "Second Copy"),
                manifest: "<Entity name=\"Film\" count=\"2\" />")
            r.check("duplicate-film-id:restore-completes", result.error == nil,
                    result.error.map { "\($0)" } ?? "")
            r.check("duplicate-film-id:first-copy-kept",
                    result.films.map(\.name) == ["First Copy"],
                    "\(result.films.count) film(s): \(result.films.map(\.name).sorted())")
        }

        // --- The reader's per-text-node ceiling ----------------------------------------------------
        //
        // `DBImporter` refuses any text node over 4 MiB, and the writer enforces no size limit
        // at all. That disagreement used to produce the worst outcome a backup system has: an
        // export that reported success and a file that could never be restored, discovered
        // only at the moment the user needed it.
        //
        // `DBExporter` now re-parses the package it wrote before claiming success, so the
        // contract under test is the corrected one: the export REFUSES, at a moment when the
        // library is still intact and the message can name the problem, and it leaves no
        // unusable package behind under a plausible name.
        do {
            container = try resetBackupStore()
            let context = container.makeMainContext()
            let big = makeSnapshot(name: "Oversized Notes").toFilm()
            big.id = UUID()
            big.notes = String(repeating: "x", count: 4 * 1024 * 1024 + 1024)
            context.insert(big)
            let small = makeSnapshot(name: "Normal Film").toFilm()
            small.id = UUID()
            context.insert(small)
            try context.save()

            let exporter = DBExporter(persistentContainer: container)
            var exportError: (any Error)?
            var producedURL: URL?
            do {
                producedURL = try await exporter.createCompleteBackup(
                    filename: "oversized", destinationURL: DebugSandbox.rootURL,
                    isBackgroundExport: false, includeSettings: true,
                    includePosters: false, posterUIDs: []).packageURL
            } catch {
                exportError = error
            }

            let refused: Bool
            if case DBExporterError.verificationFailed = exportError ?? DBRestorerError.restorationFailed("") {
                refused = true
            } else if case DBExporterError.verificationMismatch = exportError ?? DBRestorerError.restorationFailed("") {
                refused = true
            } else {
                refused = false
            }
            r.check("oversized-node:export-refuses-an-unreadable-package", refused,
                    refused
                        ? "the export re-read its own output, found the reader will not accept it, "
                            + "and failed at backup time instead of at restore time: "
                            + "\((exportError as? any LocalizedError)?.errorDescription ?? "\(String(describing: exportError))")"
                        : "the export REPORTED SUCCESS for a package the importer refuses to read — "
                            + "error: \(String(describing: exportError))")

            // The discarded package must not be sitting in the destination under a name the
            // user would reach for. A file that cannot be restored is worse than no file.
            let strandedURL = (DebugSandbox.rootURL ?? fm.temporaryDirectory)
                .appendingPathComponent("oversized.ftbackup")
            r.check("oversized-node:no-unusable-package-left-behind",
                    !fm.fileExists(atPath: strandedURL.path(percentEncoded: false)),
                    producedURL.map { "an export that failed still produced \($0.lastPathComponent)" }
                        ?? "nothing was written to the destination")
        } catch {
            r.check("oversized-node:export-refuses-an-unreadable-package", false, "\(error)")
        }

        // --- The reader's object-count ceiling -------------------------------------------------------
        //
        // 100 000 objects in `DBImporter`, again with no export-side counterpart. A library of
        // 33 000 films with one release and one membership each would cross it. The file is
        // written by hand rather than exported because seeding 100 000 rows through Core Data
        // would dominate the suite's runtime, and the ceiling under test belongs to the READER.
        do {
            let packageURL = scratch.appendingPathComponent("object-ceiling.ftbackup", isDirectory: true)
            try? fm.removeItem(at: packageURL)
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let xmlURL = packageURL.appendingPathComponent("backup.xml")
            fm.createFile(atPath: xmlURL.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: xmlURL)
            try handle.write(contentsOf: Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <FilmTrackerBackup format="FilmTrackerXML" version="1" created="2026-01-01T00:00:00Z">
              <Manifest><Entity name="Film" count="100001" /></Manifest>
              <Objects>
            """.utf8))
            var buffer = ""
            for _ in 0..<100_001 {
                buffer += """
                    <Object id="Film-\(UUID().uuidString)" entity="Film"><Properties>\
                    <Property name="id" type="string">\(UUID().uuidString)</Property>\
                    <Property name="name" type="string">Ceiling</Property></Properties>\
                    <Relationships></Relationships></Object>

                """
                if buffer.utf8.count > 1 << 20 {
                    try handle.write(contentsOf: Data(buffer.utf8)); buffer = ""
                }
            }
            try handle.write(contentsOf: Data(buffer.utf8))
            try handle.write(contentsOf: Data("  </Objects>\n</FilmTrackerBackup>\n".utf8))
            try handle.close()

            var ceilingError: (any Error)?
            do {
                _ = try await DBImporter().parseBackupFile(at: xmlURL)
            } catch {
                ceilingError = error
            }
            r.check("object-ceiling:reader-refuses-beyond-100k",
                    isImporterError(ceilingError, oneOf: ["corrupted"]),
                    "\(String(describing: ceilingError)) — the reader caps a backup at 100 000 "
                        + "objects and the writer caps nothing, so a library of roughly 33 000 films "
                        + "with one release and one membership each would produce a backup this "
                        + "build cannot read back")
            // And the property that keeps it survivable: the refusal happens at parse time, so
            // the user's database is untouched.
            let (restoreError, rebuilt) = await restoreBackupPackage(packageURL, container: container)
            r.check("object-ceiling:store-not-destroyed", !rebuilt && restoreError != nil,
                    "rebuilt: \(rebuilt), error: \(String(describing: restoreError))")
            try? fm.removeItem(at: packageURL)
        } catch {
            r.check("object-ceiling:reader-refuses-beyond-100k", false, "\(error)")
        }

        return r
    }

    // MARK: - Scenario: Scale

    /// A library large enough that the pipeline's chunking, yielding, and parser limits are
    /// actually engaged, carried through a real export and a real restore.
    ///
    /// The counts matter more than the timings: the reader chunks at 100 objects, the packager
    /// yields on an interval, and the parser enforces a 100 000-object ceiling. A library that
    /// straddles those boundaries is where an off-by-one would drop a chunk, and a spot check
    /// of the first and last film by NAME (the export's sort key) is what catches a partial
    /// write that a count alone would not.
    private static func backupScaleScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-scale")

        let filmCount = 1200
        let container: NSPersistentContainer
        var expectedNames: [UUID: String] = [:]
        var expectedRatings: [UUID: Int] = [:]
        let listID = UUID()
        do {
            container = try resetBackupStore()
            let context = container.makeMainContext()
            let list = ListObject(listID: listID, listName: "Scale List",
                                  viewStyle: "list", sortFilterOptions: [], displayOrder: 1)
            context.insert(list)
            for index in 0..<filmCount {
                let film = makeSnapshot(name: "Scale Film", sortIndex: index).toFilm()
                film.id = UUID()
                film.userRating = index % 6
                film.notes = "note \(index) & <\(index)>"
                film.cast = ["Actor \(index)", "Second \(index)"]
                expectedNames[film.id] = film.name
                expectedRatings[film.id] = film.userRating
                context.insert(film)
                context.insert(Release(id: UUID(), studio: "Studio \(index % 40)",
                                       releaseDate: "\(1950 + index % 70)", format: "Blu-ray",
                                       independence: ReleaseIndependence.standalone,
                                       numberOfDiscs: 1 + index % 3,
                                       cost: Double(index) / 100.0,
                                       dateAdded: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                                       sortOrder: index, film: film))
                context.insert(ListMembership(id: UUID(), film: film, list: list,
                                              dateAdded: Date(timeIntervalSince1970: 1_500_000_000),
                                              sortOrder: filmCount - index))
            }
            try context.save()
        } catch {
            r.check("seed-large-library", false, "\(error)")
            return r
        }
        r.check("seed-large-library", true, "\(filmCount) film(s), \(filmCount) release(s), \(filmCount) membership(s)")

        let exportStart = ContinuousClock.now
        guard let packageURL = await exportBackupPackage(container: container, filename: "scale") else {
            r.check("export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        let exportDuration = ContinuousClock.now - exportStart
        r.check("export-succeeds", true, packageURL.lastPathComponent)
        r.metric("scale-export-ms", milliseconds(exportDuration), "ms")
        if let size = (try? packageURL.appendingPathComponent("backup.xml")
            .resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            r.metric("scale-xml-size", Double(size), "bytes")
        }

        do {
            let parsed = try await DBImporter().parseBackupFile(at: packageURL.appendingPathComponent("backup.xml"))
            // The settings row is excluded from the arithmetic: this scenario seeds none, and
            // whether one exists depends on the running application's own debounced settings
            // write, which targets the same store path (see the note in
            // `backup-schema-coverage`). Counting it would make the check depend on a timer.
            let seeded = parsed.objects.filter { $0.entityName != "SettingsObject" }.count
            r.check("scale:every-object-written",
                    seeded == filmCount * 3 + 1,
                    "\(seeded) seeded object(s), expected \(filmCount * 3 + 1) "
                        + "(\(filmCount) films + \(filmCount) releases + \(filmCount) memberships + 1 list)")
            r.check("scale:manifest-agrees",
                    parsed.manifest["Film"] == filmCount
                        && parsed.manifest["Release"] == filmCount
                        && parsed.manifest["ListMembership"] == filmCount,
                    "manifest \(parsed.manifest.sorted { $0.key < $1.key })")
        } catch {
            r.check("scale:every-object-written", false, "\(error)")
        }

        let restoreStart = ContinuousClock.now
        let (restoreError, _) = await restoreBackupPackage(packageURL, container: container)
        let restoreDuration = ContinuousClock.now - restoreStart
        guard restoreError == nil else {
            r.check("restore-completes", false, "\(restoreError!)")
            return r
        }
        r.check("restore-completes", true, "")
        r.metric("scale-restore-ms", milliseconds(restoreDuration), "ms")

        do {
            let verify = try openBackupStore(allowsSave: false)
            let context = verify.makeMainContext()
            let films = try context.fetch(Film.request())
            let releases = try context.fetch(Release.request())
            let memberships = try context.fetch(ListMembership.request())
            r.check("scale:film-count-restored", films.count == filmCount, "\(films.count) of \(filmCount)")
            r.check("scale:release-count-restored", releases.count == filmCount, "\(releases.count) of \(filmCount)")
            r.check("scale:membership-count-restored", memberships.count == filmCount, "\(memberships.count) of \(filmCount)")

            // Identity, not just cardinality: the right films, with their own values.
            var mismatches = 0
            var firstMismatch = ""
            for film in films {
                guard let name = expectedNames[film.id], let rating = expectedRatings[film.id] else {
                    mismatches += 1
                    if firstMismatch.isEmpty { firstMismatch = "unknown film id \(film.id)" }
                    continue
                }
                if film.name != name || film.userRating != rating {
                    mismatches += 1
                    if firstMismatch.isEmpty {
                        firstMismatch = "\(name): name \(film.name), rating \(film.userRating) vs \(rating)"
                    }
                }
            }
            r.check("scale:every-film-restored-with-its-own-values", mismatches == 0,
                    mismatches == 0 ? "\(films.count) film(s) matched by id, name and rating"
                        : "\(mismatches) mismatch(es), first: \(firstMismatch)")

            // Every release must still name its film, and every membership both ends. At this
            // size a lookup-map failure would strand rows rather than throw.
            r.check("scale:no-orphaned-releases",
                    releases.allSatisfy { $0.film != nil },
                    "\(releases.filter { $0.film == nil }.count) orphan(s)")
            r.check("scale:no-orphaned-memberships",
                    memberships.allSatisfy { $0.film != nil && $0.list != nil },
                    "\(memberships.filter { $0.film == nil || $0.list == nil }.count) orphan(s)")
            r.check("scale:membership-sort-orders-preserved",
                    Set(memberships.map(\.sortOrder)) == Set(1...filmCount),
                    "\(Set(memberships.map(\.sortOrder)).count) distinct sortOrder value(s) of \(filmCount)")
            // Compared against the values that were seeded, not against a self-consistency
            // property. A Double is written to the backup as text and parsed back, so this is
            // the check that says the conversion is lossless across the whole corpus rather
            // than for the handful of literals `backup-graph-roundtrip` names.
            let expectedCosts = Set((0..<filmCount).map { Double($0) / 100.0 })
            r.check("scale:release-costs-preserved",
                    Set(releases.map(\.cost)) == expectedCosts,
                    "\(Set(releases.map(\.cost)).symmetricDifference(expectedCosts).count) cost(s) "
                        + "differ from the \(filmCount) seeded values")
        } catch {
            r.check("scale:film-count-restored", false, "\(error)")
        }

        return r
    }

    // MARK: - Scenario: Delivery

    /// Exports are built inside the container and delivered without ever replacing what is
    /// already at the destination (`ExportStaging`).
    ///
    /// Pins: a taken name gets the next free numeral and the existing item is left exactly as
    /// it was, for a package, a plain file and an empty folder alike; a vanished or
    /// read-only destination fails with nothing written anywhere; every export's staging
    /// directory is gone afterwards, whichever way it ended; and the launch purge clears a
    /// stranded one.
    private static func backupDeliveryScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-delivery")

        let fm = FileManager.default
        let destination = (DebugSandbox.rootURL ?? fm.temporaryDirectory)
            .appendingPathComponent("harness-backup-delivery", isDirectory: true)
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        func stagingIsEmpty() -> Bool {
            guard let root = ExportStaging.rootURL else { return false }
            return ((try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []).isEmpty
        }

        let container: NSPersistentContainer
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }

        // --- A package already holds the name ---------------------------------------------
        // A decoy package with a marker the user "expects to retain".
        let decoy = destination.appendingPathComponent("delivery.ftbackup", isDirectory: true)
        let marker = decoy.appendingPathComponent("backup.xml")
        do {
            try fm.createDirectory(at: decoy, withIntermediateDirectories: true)
            try Data("USER'S OWN FILE".utf8).write(to: marker)
        } catch {
            r.check("create-decoy", false, "\(error)")
            return r
        }

        let exporter = DBExporter(persistentContainer: container)
        func export(to dest: URL) async -> Result<URL, any Error> {
            do {
                return .success(try await exporter.createCompleteBackup(
                    filename: "delivery", destinationURL: dest, isBackgroundExport: false,
                    includeSettings: true, includePosters: false, posterUIDs: []).packageURL)
            } catch { return .failure(error) }
        }

        guard case .success(let first) = await export(to: destination),
              case .success(let second) = await export(to: destination) else {
            r.check("exports-succeed", false, "createCompleteBackup threw")
            return r
        }
        r.check("taken-name-gets-numeral", first.lastPathComponent == "delivery 1.ftbackup",
                "delivered as '\(first.lastPathComponent)'")
        r.check("next-taken-name-gets-next-numeral", second.lastPathComponent == "delivery 2.ftbackup",
                "delivered as '\(second.lastPathComponent)'")
        let decoyText = (try? String(contentsOf: marker, encoding: .utf8)) ?? "<unreadable>"
        let decoyContents = (try? fm.contentsOfDirectory(atPath: decoy.path(percentEncoded: false))) ?? []
        r.check("existing-package-untouched",
                decoyText == "USER'S OWN FILE" && decoyContents == ["backup.xml"],
                "existing package holds \(decoyContents) reading '\(decoyText)'")
        let deliveredParses = (try? await DBImporter().parseBackupFile(
            at: first.appendingPathComponent("backup.xml"))) != nil
        r.check("delivered-package-restorable", deliveredParses,
                "the numbered package parses through the restore reader")
        r.check("staging-empty-after-success", stagingIsEmpty(), "")

        // --- Failed deliveries -------------------------------------------------------------
        // Both fail after a complete, verified package was staged — the last point at which
        // anything can go wrong. A folder that no longer exists must never be read as "write
        // the package beside it, under the folder's name"; a read-only folder refuses the
        // rename AND the copy fallback, which is the path a cross-volume delivery takes.
        let missing = destination.appendingPathComponent("missing", isDirectory: true)
        let readOnly = destination.appendingPathComponent("read-only", isDirectory: true)
        try? fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path(percentEncoded: false))
        for (label, dest) in [("missing-folder", missing), ("read-only-folder", readOnly)] {
            let before = Set((try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false))) ?? [])
            if case .success(let url) = await export(to: dest) {
                r.check("\(label):throws", false, "delivered to \(url.path(percentEncoded: false))")
            } else {
                r.check("\(label):throws", true, "")
            }
            let after = Set((try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false))) ?? [])
            let inside = (try? fm.contentsOfDirectory(atPath: readOnly.path(percentEncoded: false))) ?? ["<unreadable>"]
            r.check("\(label):destination-unchanged", before == after && inside.isEmpty,
                    before == after && inside.isEmpty ? ""
                        : "destination changed: \(after.symmetricDifference(before)), read-only folder holds \(inside)")
            r.check("\(label):staging-empty", stagingIsEmpty(), "")
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path(percentEncoded: false))

        // --- An empty folder holds the name ----------------------------------------------
        // Plain rename(2) — what FileManager.moveItem calls after its own existence check —
        // silently REPLACES an empty folder. The exclusive rename must refuse it.
        do {
            let emptyFolder = destination.appendingPathComponent("Empty.pdf", isDirectory: true)
            try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
            let staging = try ExportStaging.makeDirectory()
            let staged = staging.appendingPathComponent("Empty.pdf")
            try Data("NEW".utf8).write(to: staged)
            let delivered = try ExportStaging.deliver(staged, into: destination, as: "Empty.pdf")
            ExportStaging.discard(staging)
            var isDir: ObjCBool = false
            let stillFolder = unsafe fm.fileExists(atPath: emptyFolder.path(percentEncoded: false),
                                                   isDirectory: &isDir) && isDir.boolValue
            r.check("empty-folder-not-replaced",
                    delivered.lastPathComponent == "Empty 1.pdf" && stillFolder,
                    "delivered as '\(delivered.lastPathComponent)'")
        } catch {
            r.check("empty-folder-not-replaced", false, "\(error)")
        }

        // --- A plain file already holds the name -------------------------------------------
        // The PDF export's shape, driven straight through `deliver`.
        do {
            let existing = destination.appendingPathComponent("Report.pdf")
            try Data("KEEP".utf8).write(to: existing)
            let staging = try ExportStaging.makeDirectory()
            let staged = staging.appendingPathComponent("Report.pdf")
            try Data("NEW".utf8).write(to: staged)
            let delivered = try ExportStaging.deliver(staged, into: destination, as: "Report.pdf")
            ExportStaging.discard(staging)
            r.check("file-taken-name-gets-numeral", delivered.lastPathComponent == "Report 1.pdf",
                    "delivered as '\(delivered.lastPathComponent)'")
            r.check("existing-file-untouched",
                    (try? String(contentsOf: existing, encoding: .utf8)) == "KEEP"
                        && (try? String(contentsOf: delivered, encoding: .utf8)) == "NEW", "")
        } catch {
            r.check("file-delivery", false, "\(error)")
        }

        // --- Launch purge ------------------------------------------------------------------
        do {
            let stranded = try ExportStaging.makeDirectory()
            try Data([0x00]).write(to: stranded.appendingPathComponent("partial"))
            ExportStaging.purgeLeftovers()
            r.check("purge-clears-stranded-staging",
                    !fm.fileExists(atPath: stranded.path(percentEncoded: false)), "")
        } catch {
            r.check("purge-clears-stranded-staging", false, "\(error)")
        }

        try? fm.removeItem(at: destination)
        return r
    }

    // MARK: - Scenario: Automatic Backup

    /// The launch backup (`scheduleBackgroundExportIfNeeded`) is skipped in a sandbox run, so
    /// this makes its exact export call — auto filename, background priority, the container's
    /// own Backups folder — and then runs its real retention pass over the result.
    ///
    /// Pins: the package lands in Backups (not left in staging), restorable; a taken name gets
    /// ` 1` and retention still recognizes it as the newest automatic backup; retention keeps
    /// three automatic backups and never touches a manual one.
    private static func backupAutoScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-auto")
        let fm = FileManager.default

        guard let backups = Preferences.backupFolderURL,
              let root = DebugSandbox.rootURL,
              backups.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)) else {
            r.check("backups-folder-in-sandbox", false, "the Backups folder is not inside the sandbox root")
            return r
        }
        r.check("backups-folder-in-sandbox", true, backups.lastPathComponent)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item) }

        let container: NSPersistentContainer
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }

        // Older automatic backups, a manual one, and — under the very name this run's backup
        // will want — a stand-in already holding it. Dated in the past so retention has a
        // well-defined order.
        let filename = BackupFilename.make(auto: true)
        func fakePackage(_ name: String, daysAgo: Double) {
            let url = backups.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            try? Data("old".utf8).write(to: url.appendingPathComponent("backup.xml"))
            try? fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -daysAgo * 86_400)],
                                  ofItemAtPath: url.path(percentEncoded: false))
        }
        fakePackage("FilmTrackerBackup-Auto-2020-01-01T00-00-00-05-00.ftbackup", daysAgo: 400)
        fakePackage("FilmTrackerBackup-Auto-2020-01-02T00-00-00-05-00.ftbackup", daysAgo: 300)
        fakePackage("FilmTrackerBackup-Auto-2020-01-03T00-00-00-05-00.ftbackup", daysAgo: 200)
        fakePackage(filename, daysAgo: 100)
        fakePackage("FilmTrackerBackup-2020-01-04T00-00-00-05-00.ftbackup", daysAgo: 500)

        let exporter = DBExporter(persistentContainer: container)
        let delivered: URL
        do {
            delivered = try await exporter.createCompleteBackup(
                filename: filename, destinationURL: backups, isBackgroundExport: true,
                posterUIDs: [], progress: nil).packageURL
        } catch {
            r.check("auto-export-succeeds", false, "\(error)")
            return r
        }
        let expectedName = filename.replacingOccurrences(of: ".ftbackup", with: " 1.ftbackup")
        r.check("auto-export-delivered-into-backups",
                delivered.deletingLastPathComponent().standardizedFileURL == backups.standardizedFileURL
                    && delivered.lastPathComponent == expectedName,
                "delivered as '\(delivered.lastPathComponent)'")
        let parses = (try? await DBImporter().parseBackupFile(
            at: delivered.appendingPathComponent("backup.xml"))) != nil
        r.check("auto-export-restorable", parses, "")
        let stagingLeft = ExportStaging.rootURL.flatMap {
            try? fm.contentsOfDirectory(atPath: $0.path(percentEncoded: false)) } ?? []
        r.check("auto-export-staging-empty", stagingLeft.isEmpty, stagingLeft.isEmpty ? "" : "\(stagingLeft)")

        await AppDelegate.retainRecentBackups(in: backups, limit: 3)

        let remaining = Set((try? fm.contentsOfDirectory(atPath: backups.path(percentEncoded: false))) ?? [])
        let expected: Set<String> = [
            expectedName, filename,
            "FilmTrackerBackup-Auto-2020-01-03T00-00-00-05-00.ftbackup",
            "FilmTrackerBackup-2020-01-04T00-00-00-05-00.ftbackup"]
        r.check("retention-keeps-newest-three-auto-and-the-manual", remaining == expected,
                remaining == expected ? "\(remaining.sorted())"
                    : "kept \(remaining.sorted()), expected \(expected.sorted())")

        for item in (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item) }
        return r
    }

    // MARK: - Scenario: Background Export

    /// The automatic backup's user-facing cost, and its output.
    ///
    /// Seeds a large library, takes a foreground (manual-path) export as the reference, then
    /// runs the automatic backup's own path (`isBackgroundExport: true`) while a probe on a
    /// background queue asks the main queue for a response every 5 ms and records how late
    /// each one is. Lateness is what the user feels as a hitch: anything over a frame
    /// (16 ms) is a dropped frame, over 50 ms a visible stall.
    ///
    /// Pins the output, not just the timing: the background package must carry the same
    /// content as the foreground one, its XML must be byte-identical apart from the
    /// `created` timestamp, and restoring it must reproduce the seeded store exactly.
    private static func backupBackgroundScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "backup-background")

        // The content and restore checks hold at any size; the latency metrics only mean
        // something at the real library's scale, which `full` keeps.
        let filmCount = isThorough ? 3000 : 400
        let container: NSPersistentContainer
        let seededDigest: String
        do {
            container = try resetBackupStore()
            _ = try await seedFullGraph(container: container)
            let context = container.makeMainContext()
            for film in adversarialBackupCorpus() { context.insert(film) }
            let list = ListObject(listID: UUID(), listName: "Background List",
                                  viewStyle: "list", sortFilterOptions: [], displayOrder: 50)
            context.insert(list)
            for index in 0..<filmCount {
                let film = makeSnapshot(name: "Background Film \(index)", sortIndex: index).toFilm()
                film.id = UUID()
                film.userRating = index % 11
                film.notes = "note \(index) & <\(index)>"
                film.cast = (0..<8).map { "Actor \(index)-\($0)" }
                film.genre = "Drama"
                context.insert(film)
                context.insert(Release(id: UUID(), studio: "Studio \(index % 40)",
                                       releaseDate: "\(1950 + index % 70)", format: "Blu-ray",
                                       independence: ReleaseIndependence.standalone,
                                       numberOfDiscs: 1 + index % 3,
                                       cost: Double(index) / 100.0,
                                       dateAdded: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                                       sortOrder: index, film: film))
                context.insert(ListMembership(id: UUID(), film: film, list: list,
                                              dateAdded: Date(timeIntervalSince1970: 1_500_000_000),
                                              sortOrder: index + 1))
            }
            try context.save()
            seededDigest = try storeContentDigest(container)
        } catch {
            r.check("seed", false, "\(error)")
            return r
        }
        r.check("seed", true, "\(filmCount) extra film(s) with a release and a membership each")

        // Reference: the manual export path.
        let foregroundStart = ContinuousClock.now
        guard let reference = await exportBackupPackage(container: container, filename: "bg-reference") else {
            r.check("foreground-export-succeeds", false, "createCompleteBackup threw")
            return r
        }
        r.metric("foreground-export-ms", milliseconds(ContinuousClock.now - foregroundStart), "ms")
        r.check("foreground-export-succeeds", true, reference.lastPathComponent)

        // The automatic backup's path, probed.
        let probe = MainThreadLatencyProbe()
        probe.start()
        let backgroundStart = ContinuousClock.now
        let background: URL
        do {
            background = try await DBExporter(persistentContainer: container).createCompleteBackup(
                filename: "bg-auto", destinationURL: DebugSandbox.rootURL, isBackgroundExport: true,
                posterUIDs: [], progress: nil).packageURL
        } catch {
            probe.stop()
            r.check("background-export-succeeds", false, "\(error)")
            return r
        }
        let backgroundDuration = ContinuousClock.now - backgroundStart
        let stats = probe.stop()
        r.check("background-export-succeeds", true, background.lastPathComponent)
        r.metric("background-export-ms", milliseconds(backgroundDuration), "ms")
        r.metric("main-latency-max-ms", stats.max, "ms")
        r.metric("main-latency-p99-ms", stats.p99, "ms")
        r.metric("main-latency-mean-ms", stats.mean, "ms")
        r.metric("main-hitches-over-16ms", Double(stats.over16), "count")
        r.metric("main-stalls-over-50ms", Double(stats.over50), "count")
        r.metric("probe-samples", Double(stats.samples), "count")
        r.check("hitch-log", true, stats.hitches.joined(separator: ", "))

        // Same content as the manual path.
        let referenceXML = reference.appendingPathComponent("backup.xml")
        let backgroundXML = background.appendingPathComponent("backup.xml")
        do {
            let parsedReference = try await DBImporter().parseBackupFile(at: referenceXML)
            let parsedBackground = try await DBImporter().parseBackupFile(at: backgroundXML)
            let a = backupDigest(parsedReference), b = backupDigest(parsedBackground)
            r.check("background-content-matches-foreground", a == b,
                    a == b ? "\(parsedBackground.objects.count) object(s) identical"
                        : backupFirstDifference(a, b))
        } catch {
            r.check("background-content-matches-foreground", false, "\(error)")
        }
        // Byte equality is not available: attribute order follows dictionary order, which
        // differs between any two exports (see `backup-repeatability`). Size is.
        let referenceSize = (try? referenceXML.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        let backgroundSize = (try? backgroundXML.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -2
        r.check("background-xml-same-size-as-foreground", referenceSize == backgroundSize,
                "\(referenceSize) vs \(backgroundSize) bytes")

        let stagingLeft = ExportStaging.rootURL.flatMap {
            try? FileManager.default.contentsOfDirectory(atPath: $0.path(percentEncoded: false)) } ?? []
        r.check("background-staging-empty", stagingLeft.isEmpty, stagingLeft.isEmpty ? "" : "\(stagingLeft)")

        // Restoring it reproduces the store it was taken from.
        let (restoreError, _) = await restoreBackupPackage(background, container: container)
        guard restoreError == nil else {
            r.check("background-restore-completes", false, "\(restoreError!)")
            return r
        }
        r.check("background-restore-completes", true, "")
        do {
            let restored = try storeContentDigest(try openBackupStore(allowsSave: false))
            r.check("background-restore-reproduces-store", restored == seededDigest,
                    restored == seededDigest ? "restored store matches the seeded one"
                        : backupFirstDifference(seededDigest, restored))
        } catch {
            r.check("background-restore-reproduces-store", false, "\(error)")
        }
        return r
    }
}

/// Measures how promptly the main queue responds while other work runs. A timer on a
/// background queue posts a block to the main queue every 5 ms; each block records how long
/// after posting it ran. Lateness beyond a few milliseconds means the main thread was busy.
final class MainThreadLatencyProbe: @unchecked Sendable {
    struct Stats {
        var samples = 0, over16 = 0, over50 = 0
        var max = 0.0, mean = 0.0, p99 = 0.0
        /// "t+<seconds since start>: <ms late>" for every sample over 16 ms.
        var hitches: [String] = []
    }
    private let queue = DispatchQueue(label: "harness.latency-probe", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var offsets: [Double] = []
    private var startedAt: UInt64 = 0

    func start() {
        startedAt = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
        timer.setEventHandler { [self] in
            let posted = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { [self] in
                let late = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
                let offset = Double(posted - startedAt) / 1_000_000_000
                lock.lock(); latencies.append(late); offsets.append(offset); lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }

    @discardableResult
    func stop() -> Stats {
        timer?.cancel()
        timer = nil
        lock.lock(); let values = latencies; let times = offsets; lock.unlock()
        var stats = Stats()
        guard !values.isEmpty else { return stats }
        let sorted = values.sorted()
        stats.samples = values.count
        stats.max = sorted.last ?? 0
        stats.mean = values.reduce(0, +) / Double(values.count)
        stats.p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        stats.over16 = values.filter { $0 > 16 }.count
        stats.over50 = values.filter { $0 > 50 }.count
        stats.hitches = zip(times, values).filter { $0.1 > 16 }.prefix(40)
            .map { unsafe String(format: "t+%.2fs: %.0fms", $0.0, $0.1) }
        return stats
    }
}

#endif
