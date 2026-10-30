// MARK: - FilmSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Observable view model for the FilmSheet — owns all tab sub-view-models,
// change tracking, validation, and the confirm/cancel save flow.

import SwiftUI

// Errors that confirm() can throw.
enum FilmSheetError: LocalizedError {
    case filmNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .filmNotFound(let id):
            return "Film \(id) was not found in the database and cannot be edited."
        }
    }
}

// Maximum number of characters of the film's name shown in the FilmSheet titlebar
// before truncation with a trailing ellipsis.
private let filmSheetTitleMaxLength = 60

@MainActor
@Observable
final class FilmSheet: Identifiable, Loggable {
    nonisolated static let logTag = "[FilmSheet]"

    // Sub-tab view models — NOT lazy, deliberately.
    //
    // With lazy vars, allocation defers until first read, which happens inside
    // FilmSheetView.body's initial render. Each tab's init assigns 20–30 tracked
    // @Observable properties from the MemoryStore snapshot; firing that many
    // invalidations while SwiftUI subscribers already exist mid-render forces
    // extra invalidation cycles before the first frame commits — a small but
    // real stutter. Initializing eagerly in FilmSheet.init, before any view has
    // subscribed via withObservationTracking, means the view sees already-final
    // state and renders in one pass.
    //
    // Declared as IUOs and assigned at the end of init: Swift's two-phase
    // initializer rule prevents passing `self` before all stored properties are set.
    private(set) var detailsTab: FSTabDetails!
    private(set) var releasesTab: FSTabReleases!
    private(set) var metadataTab: FSTabMetadata!
    private(set) var notesTab: FSTabNotes!
    private(set) var posterTab: FSTabPoster!

    // DataCoordinator for all database operations.
    let coordinator: DataCoordinator

    // Identifier for editing an existing film.
    let filmID: UUID
    // Track whether the user is editing an existing film or creating a new one.
    let isEditMode: Bool

    // Sheet state.
    //
    // `appearedTabs` is updated from this property's own didSet rather than from an
    // `onChange` inside FilmSheetTabContent, and that placement is the whole point.
    // When the view owned the set as @State, activating a tab took two render passes:
    // the first built the tab (the view's body unions the current selection in, so the
    // tab does render immediately), and the `onChange` that recorded it then wrote
    // @State and forced a second pass. That second pass diffs to a structurally
    // identical tree, but it still reaches AppKitScrollNSView.updateNSView, which
    // reassigns NSHostingView.rootView and makes Auto Layout re-measure the entire tab
    // that was just built — a fixed, content-independent cost paid on every first
    // activation. Writing both values here means SwiftUI observes one coalesced change
    // and renders the newly built tab exactly once.
    var selectedTab: FilmTab = .details {
        didSet { appearedTabs.insert(selectedTab) }
    }

    /// Tabs that have been selected at least once, and are therefore built and kept
    /// alive (hidden) rather than collapsed to a placeholder. Seeded in init with the
    /// starting tab — assignments made inside an initializer do not fire didSet, which
    /// is why `initialTab` is an init parameter instead of a post-init assignment: a
    /// caller opening the sheet straight onto Releases must not also cause Details to
    /// be built and laid out for a tab the user never asked for.
    private(set) var appearedTabs: Set<FilmTab> = [.details]

    // Save error state — shown as alert on FilmSheetView if confirm() encounters an error.
    // Covers errors during poster processing or FilmChangeset assembly; signals the film
    // may be in a partial or unexpected state.
    var showingSaveError: Bool = false

    // Full, uncapped fault text behind showingSaveError. Shown (elided) in the alert when
    // debug logging is off, since there is then no log for the alert to point at, and
    // copied whole by that alert's "Copy Error" button.
    var saveErrorDetail: String?

    // Change tracking for edit mode.
    private(set) var hasChanges: Bool = false

    // Validation state - published so button can observe it.
    private(set) var canConfirm: Bool = false

    // Re-entrancy guard for confirm(). Set to true at the start of the async
    // confirm Task and cleared when the Task exits (success, error, or dismissal).
    // Prevents a rapid double-tap of the confirm button — or a held Return key —
    // from queuing two Tasks that would each call saveFilmChangeset(), which in
    // add mode creates a duplicate film and in edit mode issues two identical writes.
    // canConfirm is set to false during the in-flight window as an additional UI lock.
    private(set) var isConfirming: Bool = false

    // Dismissal handler (can be assigned when presenting).
    var dismissHandler: (() -> Void)?

    // The two bases of confirm()'s three-way merge, edit mode only (see FilmField.merge).
    // `storedFilm` is the MemoryStore snapshot the sheet opened on; `loadedFilm` is what
    // the tabs collected from it before any edit. Set once in init, never observed.
    @ObservationIgnored private var storedFilm: FilmSnapshot?
    @ObservationIgnored private var loadedFilm: FilmSnapshot?

    // MARK: - Initialization
    /// - Parameter initialTab: The tab the sheet opens on. Set here rather than by
    ///   assigning `selectedTab` after construction so that `appearedTabs` is seeded
    ///   with this tab alone; see `appearedTabs`.
    init(coordinator: DataCoordinator, filmID: UUID? = nil, initialTab: FilmTab = .details) {
        self.coordinator = coordinator
        if let existingID = filmID {
            // Edit Mode: User is editing an existing film.
            self.filmID = existingID
            self.isEditMode = true
        } else {
            // Create Mode: User is adding a new film.
            self.filmID = UUID()
            self.isEditMode = false
        }
        // In edit mode, include the film's name in the titlebar: Edit “Film Name”.
        // Resolved once here from the MemoryStore snapshot (via the coordinator) so the
        // title remains a `let` — see the note on `windowTitle` below. The name is clamped
        // to `filmSheetTitleMaxLength` characters with a trailing ellipsis using the shared
        // truncation helper,
        // which also avoids leaving the ellipsis after a space. If the snapshot is missing
        // or its name is blank, fall back to the plain "Edit Film" label.
        if self.isEditMode,
           let filmName = coordinator.getFilm(self.filmID)?.name
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !filmName.isEmpty {
            self.windowTitle = "Edit “\(truncateListName(filmName, maxLength: filmSheetTitleMaxLength))”"
        } else {
            self.windowTitle = self.isEditMode ? "Edit Film" : "Add New Film"
        }
        self.confirmButtonTitle = self.isEditMode ? "Update" : "Add"

        // Initialize all tab view models now, before any SwiftUI view subscribes.
        // Each tab's init loads its data from MemoryStore synchronously; all
        // tracked-property mutations happen here while there are no observation
        // subscribers, so no redundant SwiftUI invalidation cycles are scheduled.
        self.detailsTab  = FSTabDetails(owner: self)
        self.releasesTab = FSTabReleases(owner: self)
        self.metadataTab = FSTabMetadata(owner: self)
        self.notesTab    = FSTabNotes(owner: self)
        self.posterTab   = FSTabPoster(owner: self)

        // The merge bases, taken now while the tabs hold exactly what they loaded.
        if self.isEditMode, let stored = coordinator.getFilm(self.filmID) {
            self.storedFilm = stored
            self.loadedFilm = assembleFilm(id: self.filmID,
                                           posterUID: stored.posterUID,
                                           existingFilm: stored,
                                           lastModified: stored.lastModified)
        }

        // Written last, and in this order. Both properties are @Observable-tracked, so
        // assigning them goes through their generated setters and requires `self` to be
        // fully initialized. Assigning `selectedTab` also fires its didSet, which inserts
        // into `appearedTabs`; overwriting `appearedTabs` immediately afterward is what
        // discards the `.details` seed so that a sheet opened straight onto Releases
        // builds only Releases.
        self.selectedTab  = initialTab
        self.appearedTabs = [initialTab]
    }

    // MARK: - UI Labels
    // Stored as `let` constants — both are resolved once in init from `isEditMode` (a `let`)
    // and, for `windowTitle` in edit mode, the film's name as it stands when the sheet opens.
    // Neither changes afterward, so the titlebar `Text` node stays stable for the life of the
    // sheet (a live-updating title would re-render the titlebar on every keystroke in the
    // Details tab's name field). Mirrors the existing `FSTabPoster.titleText` pattern.
    let windowTitle: String
    let confirmButtonTitle: String

    // MARK: - Change Tracking

    /// Whether any tab currently holds unsaved edits.
    ///
    /// The single place the five tabs are polled. Not a tracked stored property —
    /// reading it subscribes to each tab's `hasChanges`, so it must not be read from
    /// a view `body`. The stored `hasChanges` below is what views observe.
    private var aggregateHasChanges: Bool {
        detailsTab.hasChanges
            || releasesTab.hasChanges
            || metadataTab.hasChanges
            || notesTab.hasChanges
            || posterTab.hasChanges
    }

    /// The confirm-button predicate, in one place.
    ///
    /// Every path that needs to know whether confirming is permitted — the two fast
    /// paths below, the deferred write in `performCanConfirmUpdate()`, and the
    /// stored `canConfirm` that both the button and KeyboardManager's Return intercept
    /// read — resolves it through here, so the button and the Return key can never
    /// disagree. Takes the
    /// dirty flag as a parameter rather than reading `hasChanges`, because the fast
    /// paths need to evaluate it against a value that has not been stored yet.
    ///
    /// `isConfirming` is deliberately *not* consulted here: it gates the action, not
    /// the predicate, and each caller applies it at the point where it applies.
    private func resolvedCanConfirm(hasChanges: Bool) -> Bool {
        // Must have title and release date filled in.
        guard detailsTab.isValid else { return false }
        // In add mode, that is the whole requirement. In edit mode there must also
        // be something to save.
        return isEditMode ? hasChanges : true
    }

    /// Called by tab view models when their data changes.
    /// This method defers state updates to the next run loop so that writes to
    /// hasChanges / canConfirm do not cascade into dependent SwiftUI views that
    /// are still mid-render from the originating tracked-property mutation.
    ///
    /// Coalescing: the aggregated hasChanges result is computed synchronously
    /// before the Task hop. If the result matches the current stored value and
    /// canConfirm would not change, the Task is skipped entirely — eliminating
    /// the majority of deferred Tasks spawned during rapid typing in edit mode
    /// (where hasChanges is already true from the first keystroke) and ALL Tasks
    /// in add mode (where hasChanges is always false). Structural mutations in
    /// FSTabReleases (add, delete) that flip hasChanges between values always
    /// produce a delta and are never skipped.
    func notifyChanges() {
        let newHasChanges = aggregateHasChanges

        // Fast path: if the aggregated result matches and canConfirm would resolve
        // to the same value, skip the deferred Task entirely.
        //
        // isConfirming overrides canConfirm during the in-flight save window; if that
        // window is active, skip the canConfirm check entirely since confirm() manages
        // canConfirm directly via its own defer block.
        if newHasChanges == hasChanges,
           isConfirming || resolvedCanConfirm(hasChanges: newHasChanges) == canConfirm {
            return
        }

        // The result changed (or canConfirm needs updating) — defer the write.
        //
        // The deferred body RE-DERIVES the aggregate rather than storing
        // `newHasChanges`, and that distinction is load-bearing. The fast path above
        // compares against the STORED `hasChanges`, which a Task queued on this same
        // turn has not written yet, so a second mutation landing before that Task runs
        // can be skipped as a no-op against a value that is about to change underneath
        // it:
        //
        //   1. hasChanges == false. An edit makes the aggregate true → Task queued.
        //   2. Before it runs, a second mutation reverts the aggregate to false. The
        //      fast path sees false == false (stored) and returns, queueing nothing.
        //   3. The Task from step 1 runs and writes the captured `true`.
        //
        // The sheet is then dirty with nothing to save and Update is enabled on a clean
        // film. Two mutations in one turn are reachable — every multi-field cascade in
        // the sheet produces them (SpecialSortingMenu's blacklist onChange writing
        // rotationThresholdOverride, enforceReleaseYearOrder's corrective writes,
        // syncComboChildFields). Reading the tabs again here costs five Bool loads and
        // makes the stored value a function of the state at write time rather than at
        // schedule time, so a superseded Task settles on the truth instead of an
        // obsolete snapshot of it.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Gated on an actual delta, matching every tab's checkForChanges(): a
            // superseded Task that re-derives the value it already holds must not fire
            // an @Observable invalidation for a write of no consequence.
            let resolved = self.aggregateHasChanges
            if self.hasChanges != resolved { self.hasChanges = resolved }
            self.performCanConfirmUpdate()
        }
    }

    /// Called by tabs (especially FSTabDetails) when validation state changes
    /// but not necessarily due to data changes.
    /// This method defers state updates to the next run loop.
    func updateCanConfirm() {
        // Fast path: skip the Task if nothing would change. This eliminates ~20 Tasks
        // per keystroke in add mode for non-validation fields (everything except name
        // and hasReleaseDate).
        guard !isConfirming,
              resolvedCanConfirm(hasChanges: hasChanges) != canConfirm else { return }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.performCanConfirmUpdate()
        }
    }

    /// Internal method that actually updates canConfirm.
    /// Called from deferred Tasks only, never during view updates.
    private func performCanConfirmUpdate() {
        canConfirm = resolvedCanConfirm(hasChanges: hasChanges)
    }

    // MARK: - Sheet Actions
    func cancel() {
        // Do not allow cancellation while a confirm Task is in flight.
        // The confirm Task suspends across real async work — poster resize, JPEG
        // encode, and file write, all on a background Task — so there is a genuine
        // window between isConfirming going true and the sheet dismissing, even
        // though it is short. Dismissing during that window would:
        //   1. Call dismissHandler while the Task is still running.
        //   2. Let the Task subsequently call coordinator.saveFilmChangeset() against
        //      an already-dismissed sheet, then call dismissHandler a second time,
        //      causing a double-dismiss against an already-nil activeSheet.
        // The Cancel button is also .disabled during this window (see FilmSheetView),
        // but Escape is handled by .keyboardShortcut(.cancelAction) independently,
        // so this guard is the authoritative re-entrancy barrier for both paths.
        guard !isConfirming else {
            Self.log("Cancel ignored — confirm is in progress")
            return
        }

        // Nothing was written to disk before save, and a canceled FilmSheet is never
        // reused (dismissHandler drops it), so there is no pending per-tab state that
        // needs unwinding here — it goes away with the sheet.
        Self.log("Canceling sheet")

        dismissHandler?()
    }

    // Confirms and saves all changes to the film via the Sendable DTO / changeset path.
    //
    // Flow:
    //   1. Process poster (async file I/O, no Film managed object needed)
    //   2. Collect all form data from tabs as plain Sendable values
    //   3. Derive lastWatched, viewCount, lastModified
    //   4. Preserve fields that tabs do not own (dateAdded, hofPosition)
    //   5. Build FilmSnapshot, three-way merge it with the film as it stands now (edit
    //      mode), then build the FilmChangeset (fully Sendable) carrying the merged delta
    //   6. coordinator.saveFilmChangeset() — instant MemoryStore update + background persist
    //   7. Post list membership events (handled inside saveFilmChangeset)
    //   8. Handle Hall of Fame changes via dedicated coordinator methods
    //   9. Dismiss
    //
    // No viewContext access or context.save() calls occur here — persistence is owned entirely
    // by DataManager via the background NSManagedObjectContext in DataCoordinator.saveFilmChangeset().
    func confirm() {
        // Re-entrancy guard: a confirm Task is already in flight (e.g. slow poster
        // file-write polling), so ignore this invocation entirely.
        guard !isConfirming else { return }
        // Land any list commit still held for its popover's close animation before
        // anything reads the tabs — the same settle `releasesTab.settlePendingWork()`
        // performs below for the Releases tab. If one stopped at its duplicate
        // confirmation instead of writing, its value is not in the model yet: leave the
        // prompt up and do not save without it. See `ListPopoverDismissal.settlePending`.
        if ListPopoverDismissal.settlePending() { return }
        isConfirming = true
        canConfirm   = false

        Task { @MainActor in
            // Always clear the guard on exit, regardless of success or failure.
            defer {
                self.isConfirming = false
                // Re-evaluate canConfirm so the button re-enables if the sheet is
                // still open (e.g. after a save error the user may want to retry).
                self.performCanConfirmUpdate()
            }

            do {
                let id = self.filmID
                let now = Date()
                let lastModifiedStr = StorageDateFormatters.timestamp.format(now)
                let modeLabel = isEditMode ? "edit" : "add"
                Self.log("Starting DTO-based confirm for film \(modeLabel) mode — id: \(id)")

                // ── Step 1: Process poster ──────────────────────────────────────────────
                // Must happen first — it's async (file I/O) and we need the final UID
                // before building the snapshot. processPendingPoster() handles cache updates
                // and returns the final posterUID without touching any managed object.
                let existingFilm: FilmSnapshot? = isEditMode ? coordinator.getFilm(id) : nil
                let originalPosterUID = existingFilm?.posterUID ?? ""

                if isEditMode && existingFilm == nil {
                    Self.log("ERROR: Cannot edit film; \(id) not found in MemoryStore.")
                    throw FilmSheetError.filmNotFound(id)
                }

                let finalPosterUID = try await posterTab.processPendingPoster(
                    filmID: id,
                    originalUID: originalPosterUID
                )
                Self.log("Poster resolved: '\(finalPosterUID)'")

                // Complete the Releases tab's deferred work — a delete mid-fly-up, a combo-pack
                // reconciliation or confirmed Type change still in its settle window — BEFORE
                // anything reads `releasesTab.releases`. Step 6's buildReleaseDeltas() settles
                // too, but assembleFilm() below sums the purchased discs first: a save landing
                // inside the 300 ms fly-up used to count the deleted release's discs into the
                // film's total while the release itself was correctly deleted, and
                // saveFilmChangeset persists that total verbatim. Idempotent, so the second
                // settle inside buildReleaseDeltas() finds nothing left to do.
                releasesTab.settlePendingWork()

                // ── Steps 2-5: Assemble the film snapshot ───────────────────────────────
                // Collecting three tabs' fields, deriving the values computed from them,
                // carrying forward the two fields no tab owns, and filling FilmSnapshot's
                // 56 arguments is field plumbing with no decisions in it. Extracted whole
                // so this method reads as the ten-step flow its header describes rather
                // than as one 70-line assignment with the flow buried in it.
                //
                // Re-read the film here rather than reusing `existingFilm`: the poster step
                // above suspends, and a background import or reorder can land meanwhile.
                // It supplies the fields no tab owns and the merge's `current`.
                let currentFilm = isEditMode ? (coordinator.getFilm(id) ?? existingFilm) : nil
                let assembled = assembleFilm(id: id,
                                             posterUID: finalPosterUID,
                                             existingFilm: currentFilm,
                                             lastModified: lastModifiedStr)
                let merged = mergeWithCurrent(assembled, current: currentFilm,
                                              lastModified: lastModifiedStr)
                let snapshot = merged.snapshot

                // ── Step 6: Build release deltas ────────────────────────────────────────
                // For add mode, originalReleases is empty so all current releases go into
                // releasesToCreate automatically.
                let releaseDeltas = releasesTab.buildReleaseDeltas()
                Self.log("Release deltas — create: \(releaseDeltas.create.count), update: \(releaseDeltas.update.count), delete: \(releaseDeltas.delete.count)")

                // ── Step 7: Compute list membership deltas ──────────────────────────────
                let listDeltas = listMembershipDeltas()

                // ── Step 8: Dispatch FilmChangeset ──────────────────────────────────────
                // saveFilmChangeset() is synchronous on MainActor:
                //   • Immediately applies snapshot to MemoryStore (Film managed object in the view context)
                //   • Immediately applies list membership deltas to MemoryStore indices
                //   • Reloads the gallery view
                //   • Posts .film(.added / .updated) and .film(.releaseChanged) events
                //   • Queues background DataManager persist with automatic rollback on failure
                let changeset = FilmChangeset(
                    filmID: id,
                    isNewFilm: !isEditMode,
                    filmSnapshot: snapshot,
                    releasesToCreate: releaseDeltas.create,
                    releasesToUpdate: releaseDeltas.update,
                    releasesToDelete: releaseDeltas.delete,
                    listsToAdd: listDeltas.add,
                    listsToRemove: listDeltas.remove,
                    changedFields: merged.changed
                )
                coordinator.saveFilmChangeset(changeset)
                Self.log("FilmChangeset dispatched to coordinator for film \(id)")

                // The film now references the poster from MemoryStore, so the pruner
                // will keep the file on its own; the reservation Step 1 took (inside
                // PosterConverter) can go. A no-op when no new poster was written.
                if !finalPosterUID.isEmpty { PosterReservations.release(finalPosterUID) }

                // ── Step 9: Handle Hall of Fame changes ────────────────────────────────
                // HoF management adjusts positions across multiple films, so it goes through
                // its own dedicated coordinator path rather than through FilmChangeset.
                // Called AFTER saveFilmChangeset so the film exists in MemoryStore.
                //
                // Three-way, like the fields: act only when the user toggled it (the
                // toggle differs from what the sheet loaded) AND the film is not already
                // there. Comparing against the film at save time instead would read a
                // Hall of Fame entry made elsewhere while the sheet was open as the user
                // switching it off, and remove it.
                let loadedInHallOfFame = isEditMode ? ((storedFilm?.hofPosition ?? 0) > 0) : false
                let currentInHallOfFame = isEditMode
                    ? ((coordinator.getFilm(id)?.hofPosition ?? 0) > 0) : false
                if detailsTab.inHallOfFame != loadedInHallOfFame,
                   detailsTab.inHallOfFame != currentInHallOfFame {
                    if detailsTab.inHallOfFame {
                        coordinator.addToHallOfFame(id)
                        Self.log("Added film \(id) to Hall of Fame")
                    } else {
                        coordinator.removeFromHallOfFame(id)
                        Self.log("Removed film \(id) from Hall of Fame")
                    }
                    // Not re-read into detailsTab.hallOfFameIsFull here: nothing between this
                    // point and the unconditional dismiss below can throw, so this sheet
                    // instance is always on its way out and never renders this value again.
                }

                // ── Step 10: Dismiss ─────────────────────────────────────────────────────
                dismissHandler?()
                Self.log("Sheet dismissed successfully for film \(id)")

            } catch {
                Self.log("ERROR: Film confirm failed: \(error)")
                self.saveErrorDetail = AlertErrorDetail.full(error)
                self.showingSaveError = true
            }
        }
    }

    // MARK: - Snapshot Assembly

    /// Builds the film snapshot a save writes, from the three field-collecting tabs.
    ///
    /// Pure assembly: it reads the tabs and `existingFilm` and returns a value. Nothing
    /// here mutates anything, throws, or suspends — which is what makes it safe to lift
    /// out of the middle of `confirm()`'s Task without disturbing that method's ordering
    /// guarantees.
    ///
    /// - Parameters:
    ///   - existingFilm: The MemoryStore snapshot for edit mode, `nil` in add mode. It
    ///     supplies only the two fields no tab owns; see below.
    private func assembleFilm(id: UUID,
                              posterUID: String,
                              existingFilm: FilmSnapshot?,
                              lastModified: String) -> FilmSnapshot {
        // ── Collect tab form data ───────────────────────────────────────────────────
        let detailsFields  = detailsTab.collectFilmFields()
        let metadataFields = metadataTab.collectFilmFields()
        let notesFields    = notesTab.collectFilmFields()

        // ── Derive computed fields ──────────────────────────────────────────────────
        // lastWatched is the most recent viewing date, and the calendar entries sort
        // lexicographically in the same order they sort chronologically because they are
        // stored zero-padded ("yyyy.MM.dd"), optionally with a version-code suffix that
        // extractDatePortion strips off.
        let calendarTable = detailsFields.calendarTable
        let (lastWatched, viewCount) = Self.viewingDerivatives(of: calendarTable)

        // The film's disc count is the sum over the releases the user actually owns, so
        // an unpurchased or wishlisted release contributes nothing.
        let totalDiscs = releasesTab.releases
            .filter { $0.purchased }
            .reduce(0) { $0 + $1.numberOfDiscs }
        let numberOfDiscs = "\(totalDiscs)"

        // ── Preserve fields no tab owns ─────────────────────────────────────────────
        // dateAdded and hofPosition are not editable in any FilmSheet tab. In edit mode
        // they carry forward from the existing film; in add mode they take safe defaults.
        //
        // hofPosition is preserved UNCHANGED even when the user toggled Hall of Fame on
        // this sheet: `confirm()` Step 9 commits that through addToHallOfFame /
        // removeFromHallOfFame, which adjust positions across multiple films and queue
        // their own persist. Writing a position here would fight them.
        let dateAdded: String
        let hofPosition: Int
        if isEditMode, let film = existingFilm {
            dateAdded   = film.dateAdded
            hofPosition = film.hofPosition
        } else {
            dateAdded   = lastModified
            hofPosition = 0
        }

        // ── Build FilmSnapshot ──────────────────────────────────────────────────────
        return FilmSnapshot(
            id: id,
            posterUID: posterUID,
            name: detailsFields.name,
            releaseYear: detailsFields.releaseYear,
            userRating: detailsFields.userRating,
            lastWatched: lastWatched,
            rotationThresholdOverride: detailsFields.rotationThresholdOverride,
            duration: detailsFields.duration,
            viewCount: viewCount,
            calendarTable: calendarTable,
            autoAddToQueueOnRotation: detailsFields.autoAddToQueueOnRotation,
            digitalSource: metadataFields.digitalSource,
            digitalVersion: metadataFields.digitalVersion,
            subtitles: metadataFields.subtitles,
            notes: metadataFields.notes,
            numberOfDiscs: numberOfDiscs,
            aspectRatio: metadataFields.aspectRatio,
            color: metadataFields.color,
            edited: detailsFields.edited,
            editedDuration: detailsFields.editedDuration,
            frameRate: metadataFields.frameRate,
            tags: metadataFields.tags,
            externalIdentifiers: detailsFields.externalIdentifiers,
            dateAdded: dateAdded,
            lastModified: lastModified,
            watched: detailsFields.watched,
            specialSorting: detailsFields.specialSorting,
            alternateTitle: metadataFields.alternateTitle,
            hofPosition: hofPosition,
            infoComplete: detailsFields.infoComplete,
            comments: metadataFields.comments,
            genre: detailsFields.genre,
            releaseDate: detailsFields.releaseDate,
            descriptionText: detailsFields.descriptionText,
            rating: detailsFields.rating,
            studio: metadataFields.studio,
            cast: metadataFields.cast,
            directors: metadataFields.directors,
            producers: metadataFields.producers,
            executiveProducers: metadataFields.executiveProducers,
            screenwriters: metadataFields.screenwriters,
            encodingTool: metadataFields.encodingTool,
            libraryHBRFValue: metadataFields.libraryHBRFValue,
            composer: metadataFields.composer,
            sortName: metadataFields.sortName,
            releaseUsed: notesFields.releaseUsed,
            tools: notesFields.tools,
            editedHBRFValue: notesFields.editedHBRFValue,
            editDate: notesFields.editDate,
            warning: notesFields.warning,
            descriptionNotes: notesFields.descriptionNotes,
            notesOnAudioTiming: notesFields.notesOnAudioTiming,
            specialAudioNotes: notesFields.specialAudioNotes,
            notesArray: notesFields.notesArray,
            handbrakeFrames: notesFields.handbrakeFrames,
            correspondingTimecodes: notesFields.correspondingTimecodes
        )
    }

    #if DEBUG
    /// The whole-object snapshot the sheet would save before the merge — what the save
    /// wrote before it merged. For the `film-field-merge` harness's equivalence check.
    func assembledSnapshotForTesting() -> FilmSnapshot {
        let current = isEditMode ? coordinator.getFilm(filmID) : nil
        return assembleFilm(id: filmID, posterUID: current?.posterUID ?? "",
                            existingFilm: current, lastModified: "")
    }
    #endif

    /// `lastWatched` and `viewCount` as a calendar table implies them.
    ///
    /// lastWatched is the most recent viewing date. The entries sort lexicographically in
    /// the same order they sort chronologically because they are stored zero-padded
    /// ("yyyy.MM.dd"), optionally with a version-code suffix that extractDatePortion
    /// strips off.
    static func viewingDerivatives(of calendarTable: [String]) -> (lastWatched: String, viewCount: Int) {
        guard let latest = calendarTable.max() else { return ("", 0) }
        return (extractDatePortion(from: latest) ?? latest, calendarTable.count)
    }

    /// The save's snapshot after the three-way merge, and the fields it writes.
    ///
    /// In add mode, or without merge bases, the assembled snapshot is the whole save and
    /// `changed` is nil (write every field). In edit mode the assembled snapshot is laid
    /// over `current` by `FilmField.merge`, so a field the user left alone keeps a value
    /// something else committed while the sheet was open. The viewing derivatives are then
    /// recomputed from the MERGED calendar table — merging them field by field could pair
    /// the user's calendar with a lastWatched that came from someone else's — and
    /// lastModified is stamped whatever else changed, since the save itself is a change.
    private func mergeWithCurrent(_ sheet: FilmSnapshot, current: FilmSnapshot?,
                                  lastModified: String) -> (snapshot: FilmSnapshot, changed: Set<FilmField>?) {
        guard isEditMode, let current, let stored = storedFilm, let loaded = loadedFilm else {
            return (sheet, nil)
        }
        let result = FilmField.merge(sheet: sheet, loaded: loaded, stored: stored, current: current)
        var merged = result.merged
        var changed = result.changed
        let derived = Self.viewingDerivatives(of: merged.calendarTable)
        merged.lastWatched  = derived.lastWatched
        merged.viewCount    = derived.viewCount
        merged.lastModified = lastModified
        for field in [FilmField.lastWatched, .viewCount, .lastModified] where field.differs(merged, current) {
            changed.insert(field)
        }
        let taken = FilmField.allCases.filter { changed.contains($0) }.map(\.rawValue)
        Self.log("Three-way merge writes \(changed.count) field(s): \(taken.joined(separator: ", "))")
        return (merged, changed)
    }

    /// The list-membership changes a save applies, user lists and Film Queue together.
    ///
    /// Both are carried by the same FilmChangeset membership fields, so DataManager
    /// persists them atomically with the rest of the save. In add mode there is no prior
    /// membership, so every selection is an addition and nothing is removed.
    private func listMembershipDeltas() -> (add: Set<UUID>, remove: Set<UUID>) {
        var add: Set<UUID>
        var remove: Set<UUID>
        if isEditMode {
            add    = detailsTab.selectedListIDs.subtracting(detailsTab.originalListIDs)
            remove = detailsTab.originalListIDs.subtracting(detailsTab.selectedListIDs)
        } else {
            add    = detailsTab.selectedListIDs
            remove = []
        }
        // The Film Queue section, folded in. filmQueueDelta() is self-healing against the
        // film's ACTUAL internal memberships at load, so selecting a section removes the
        // film from any other internal list it was stray in, and "None" removes it from
        // all of them.
        let queueDelta = detailsTab.filmQueueDelta()
        add.formUnion(queueDelta.add)
        remove.formUnion(queueDelta.remove)
        return (add: add, remove: remove)
    }
}
