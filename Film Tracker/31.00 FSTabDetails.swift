// MARK: - FSTabDetails.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Observable view model for the "Details" tab of FilmSheet — owns all field
// state, change tracking, data load/save, and DTO assembly.

import SwiftUI

@MainActor
@Observable
final class FSTabDetails {
    weak var owner: FilmSheet?

    // Detail fields.
    var name: String = "" { didSet { checkForChanges() } }
    /// Backing store for the Release Date picker. Defaults to today's date, but
    /// is only meaningful when hasReleaseDate is true — see hasReleaseDate. Moved
    /// here from FSTabMetadata: releaseDate is now the master date value the user
    /// manages directly; releaseYear (below) is derived exclusively from it.
    var releaseDate: Date = Date() { didSet { checkForChanges(); propagateFilmReleaseYear() } }
    /// Whether the film has a recorded release date. false shows the picker's
    /// grayed-out placeholder state, matching the CustomDatePicker convention
    /// used elsewhere (e.g. FSTabNotes.hasEditDate).
    var hasReleaseDate: Bool = false { didSet { checkForChanges(); propagateFilmReleaseYear() } }

    /// Pushes the film's release year onto the Releases tab's cards.
    ///
    /// A release's selectable year range is floored at the film's own release year (a
    /// release cannot pre-date the film), and each card captured that floor when it was
    /// built. Since the user can edit the release date in this tab during the same sheet
    /// session, cards built before the edit would otherwise keep the old floor — leaving
    /// them disagreeing with a newly added card, and deferring any resulting conflict to
    /// the next open, where it surfaced as an unexplained correction.
    ///
    /// Skipped during the initial load: the Releases tab reads the same persisted value
    /// itself, and `loadExistingDetails` assigns both properties above while
    /// `isLoadingData` is set.
    ///
    /// `releasesTab` is bound as an explicit Optional rather than read through its
    /// implicitly-unwrapped declaration, because FilmSheet builds this tab FIRST — during
    /// FSTabDetails' own init it is genuinely nil, and a force-unwrap would trap.
    private func propagateFilmReleaseYear() {
        guard !isLoadingData else { return }
        let releasesTab: FSTabReleases? = owner?.releasesTab
        releasesTab?.updateFilmReleaseYear(releaseYear)
    }
    var userRating: Int = 0 { didSet { checkForChanges() } }
    var calendarTable: [String] = [] { didSet { checkForChanges() } }

    /// The film's release year, derived exclusively from the year component of
    /// releaseDate. No longer independently editable or stored — the user manages
    /// releaseDate alone, and this computed value is what gets persisted to the
    /// Film model's releaseYear field on save. Returns 0 when hasReleaseDate is
    /// false (mirrors the "absent" convention collectFilmFields() already used
    /// for an empty releaseYear string).
    ///
    /// Read through `StorageDateFormatters.calendar`, not `Calendar.current`: the date is
    /// SAVED through `releaseDateFormatter`, which is pinned Gregorian, so this has to read
    /// the year in that same calendar for the two stored fields to agree. Under a Buddhist
    /// or Japanese system calendar, `Calendar.current` gave 2569 or 8 for a 2026 release —
    /// persisted as releaseYear beside a "2026-…" releaseDate, and pushed onto every release
    /// card as its year floor.
    var releaseYear: Int {
        hasReleaseDate ? StorageDateFormatters.calendar.component(.year, from: releaseDate) : 0
    }

    /// Re-stamps a release date into the app's canonical "yyyy-MM-dd'T'12:00:00'Z'"
    /// storage format. Used by collectFilmFields() when saving.
    private static func releaseDateStorageString(from date: Date, hasValue: Bool) -> String {
        guard hasValue else { return "" }
        let day = releaseDateFormatter.string(from: date)
        return "\(day)T12:00:00Z"
    }

    // Duration fields.
    var durationHours: Int = 0 { didSet { checkForChanges() } }
    var durationMinutes: Int = 0 { didSet { checkForChanges() } }
    var hasDuration: Bool = false { didSet { checkForChanges() } }

    // Edited duration fields (parallel to duration; only relevant when edited == true).
    var editedDurationHours: Int = 0 { didSet { checkForChanges() } }
    var editedDurationMinutes: Int = 0 { didSet { checkForChanges() } }
    var hasEditedDuration: Bool = false { didSet { checkForChanges() } }

    /// The stored durations exactly as loaded, in milliseconds (nil when absent).
    ///
    /// The pickers show whole hours and minutes, but imported runtimes carry seconds and
    /// milliseconds (1:26:46.785 is stored as "5206785"). Without these, every save of the
    /// film — a rating change, a new viewing date — rewrote the runtime truncated to the
    /// minute. `collectFilmFields()` writes the loaded value back untouched whenever the
    /// pickers still show what it loaded as, so only a real edit of the duration changes it.
    @ObservationIgnored private var loadedDurationMs: Int?
    @ObservationIgnored private var loadedEditedDurationMs: Int?

    /// The milliseconds a save should write for a picker showing `hours`:`minutes` — the
    /// loaded value when the picker still shows it, the picker's own value otherwise.
    private static func durationMilliseconds(hours: Int, minutes: Int, loaded: Int?) -> Int {
        if let loaded, DurationHelpers.millisecondsToHoursAndMinutes(loaded) == (hours, minutes) {
            return loaded
        }
        return DurationHelpers.hoursAndMinutesToMilliseconds(hours: hours, minutes: minutes)
    }

    // Track list membership changes for reconciliation on save.
    // NOTE: selectedListIDs holds USER-generated list memberships only; the internal
    // Film Queue membership is tracked separately via selectedFilmQueueSection so that
    // the List Membership picker and the Film Queue picker never interfere.
    var selectedListIDs: Set<UUID> = [] { didSet { checkForChanges() } }
    /// Exposed for FilmSheet.confirm() to compute list membership deltas for FilmChangeset.
    private(set) var originalListIDs: Set<UUID> = []

    // MARK: - Film Queue
    /// The film's currently-selected Film Queue section (nil = "None", i.e. not queued).
    /// Committed to the internal lists only when the sheet is saved.
    var selectedFilmQueueSection: FilmQueueSection? = nil { didSet { checkForChanges() } }
    /// The section the film occupied when the sheet opened (baseline for change detection).
    private(set) var originalFilmQueueSection: FilmQueueSection? = nil
    /// The exact set of internal Up Next list UUIDs the film belonged to at load time.
    /// Usually empty or a single element; capturing the full set lets confirm() compute a
    /// self-healing delta that removes the film from any stray internal list if data ever
    /// placed it in more than one section.
    private(set) var originalInternalListIDs: Set<UUID> = []

    /// Backing value for the "Automatically add to … Queue when coming up for rotation"
    /// checkbox row. nil means the checkbox is unchecked (feature disabled for this film);
    /// 0/1/2 means checked, identifying the target section (Up Next / Soon / Later,
    /// matching FilmQueueSection.queueOrder) written directly to Film.autoAddToQueueOnRotation.
    var autoAddToQueueOnRotation: Int? = nil { didSet { checkForChanges() } }

    // Metadata fields moved from FSTabMetadata.
    var genre: String = "" { didSet { checkForChanges() } }
    var rating: String = "" { didSet { checkForChanges() } }
    var descriptionText: String = "" { didSet { checkForChanges() } }

    // Library Information fields.
    var watched: Bool = true { didSet { checkForChanges() } }
    var edited: Bool = false { didSet { checkForChanges() } }
    var inHallOfFame: Bool = false { didSet { checkForChanges() } }
    var specialSorting: Set<String> = [] { didSet { checkForChanges() } }
    var rotationThresholdOverride: Int? = nil { didSet { checkForChanges() } }
    var externalIdentifiers: [String] = ["", ""] { didSet { checkForChanges() } }
    var infoComplete: Bool = false { didSet { checkForChanges() } }
    
    // Hall of Fame state
    var hallOfFameIsFull: Bool = false

    // Available lists for the List Membership picker.
    // Populated eagerly in init() from MemoryStore — moves the read off the
    // peak-render path (onAppear) and onto the pre-subscription init path, where
    // it competes with nothing. Refreshed in response to AppEventBus.listEvents
    // exactly as the prior onAppear + onReceive pair did, so live consistency is
    // maintained. Internal access so FSTabDetailsView can read it directly.
    //
    // Held as [MemoryList] — the type getAllLists() already returns — rather than
    // remapped into [ListInfo]. ListMembershipMenu reads only listID and listName,
    // so the mapping bought nothing and cost a per-list filmIDs.count on a value
    // no consumer ever read. ListInfo remains the sidebar's type, where filmCount
    // genuinely drives the row's contextual-menu enablement.
    var availableLists: [MemoryList] = []

    /// True when this film was already in the Hall of Fame when the sheet was opened.
    /// Used by the view to exempt existing members from the full-list lockout: a user
    /// editing a current member should always be free to uncheck (and re-check) the
    /// box, because doing so won't exceed the 200-film limit — it will actually reduce
    /// it by one if saved. The lockout applies only to films that were *not* members
    /// at load time and therefore would consume a new slot on commit.
    var wasOriginallyInHallOfFame: Bool { originalInHallOfFame }

    // Baseline captured after the initial load in edit mode: the exact same
    // `FilmDetailsFields` value that `collectFilmFields()` produces, so "has anything
    // changed?" is a single `==` against what a save would actually write. Identical in
    // shape to FSTabMetadata's and FSTabNotes' baselines — all three tabs now answer the
    // question the same way, with one field list each instead of two.
    //
    // MARK: What the parallel snapshot this replaces got wrong
    //
    // This used to be `OriginalDetails`, a second 23-field struct mirroring the tab's
    // stored properties rather than its output, compared field-by-field against the live
    // values. Two field lists to keep in step, and they disagreed in three places — each
    // one reporting an unsaved change for an edit that could not be persisted:
    //
    //   • `durationHours`/`durationMinutes` were compared even while `hasDuration` was
    //     false, a state in which `collectFilmFields()` writes "" regardless.
    //   • `editedDuration*` likewise, and additionally while `edited` was false — the
    //     state in which the UI hides that picker entirely and the save writes "".
    //   • `releaseDate` needed a bespoke day-precision comparison (and a three-term
    //     special case for the has-value flag) to avoid a Date's time component
    //     manufacturing a phantom change. `collectFilmFields()` already renders it as the
    //     stored day-precision string, so comparing the collected value gets that for
    //     free.
    //
    // This is exactly the argument FSTabMetadata makes about `isRemastered`: comparing
    // the value a save would WRITE collapses, by construction, every difference that is a
    // no-op on disk. The special cases are not reimplemented here — they cease to exist.
    //
    // Two things live outside the collected fields and are therefore compared separately
    // in `computeHasChanges()`: Hall of Fame membership (which `collectFilmFields()` does
    // not carry, because it is committed through its own coordinator path rather than
    // through the changeset) and the two list-membership selections.
    private var original: FilmDetailsFields?

    /// Hall of Fame membership as it stood when the sheet opened.
    ///
    /// Separate from `original` because `FilmDetailsFields` deliberately does not carry
    /// it — `FilmSheet.confirm()` commits a HoF change through `addToHallOfFame` /
    /// `removeFromHallOfFame`, not through the changeset, so it is not one of the fields
    /// a save writes from this tab. It is still a user edit, so change detection has to
    /// see it.
    private var originalInHallOfFame: Bool = false

    // Day-precision formatter for the Release Date field, used to build the canonical
    // storage string on save.
    //
    // It no longer participates in change detection: the baseline above holds the
    // collected fields, whose `releaseDate` is already this formatter's output, so the
    // day-precision comparison happens by construction rather than as a special case at
    // the comparison site.
    //
    // The shared "yyyy-MM-dd" storage formatter; see StorageDateFormatters for why the
    // configuration lives there rather than being restated here.
    // Moved here from FSTabMetadata as part of the releaseDate field's relocation.
    nonisolated static let releaseDateFormatter = StorageDateFormatters.dash

    // Change tracking.
    var hasChanges: Bool = false
    
    // Flag to suppress change tracking during initial data load.
    private var isLoadingData: Bool = false

    // Cached validation result. Updated by checkForChanges() so that
    // owner.updateCanConfirm() is only called when the validation state
    // actually transitions (true↔false). This eliminates the Task spawn
    // that previously fired on every keystroke across all fields in
    // add mode — only changes to `name` or `hasReleaseDate` can flip
    // this value, and the remaining fields skip the call entirely.
    private var lastIsValid: Bool = false

    // Validation - separate from canConfirm to avoid confusion.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        hasReleaseDate
    }
    
    // "Genre" field options (from FilterOption in ViewState)
    // Static: allocated once at class load time, never per-sheet-open.
    static let genreOptions = ["", "Action and Adventure", "Comedy", "Drama", "Horror",
                        "Kids and Family", "Sci-Fi and Fantasy", "Thriller"]
    
    // "Rating" field options
    static let ratingOptions = ["", "G", "PG", "PG-13", "R", "NR", "Unrated"]

    // MARK: - Initialization
    init(owner: FilmSheet) {
        self.owner = owner
        
        // Snapshot the Hall of Fame capacity at init time. This value is not a live
        // binding — it reflects the HoF state at the moment the sheet opens. If
        // another sheet session adds a film to the HoF concurrently (between when
        // this sheet opens and when the user clicks the HoF checkbox), the snapshot
        // may be stale. The risk is narrow under @MainActor serialization, and the
        // persisted state stays authoritative regardless: confirm() commits the change
        // through addToHallOfFame / removeFromHallOfFame, which enforce the limit
        // themselves. (This snapshot is not refreshed after that call — the sheet is
        // dismissed on the same pass and never renders it again.)
        hallOfFameIsFull = owner.coordinator.hallOfFameIsFull
        
        // Defer the available-lists sort+map until after the first cooperative
        // suspension point. FilmSheet.init runs while CoreAnimation is handing the
        // presentation animation its first frame budget; the read below returns the
        // store's sorted-lists array, which it may have to rebuild — work that
        // competes with that animation if run synchronously here.
        //
        // Starting with an empty array is safe: ListMembershipMenu's label text
        // derives from selectedListIDs.count alone (showing "None", "1 selected", or
        // "Multiple"), so it is correct with an empty availableLists array. The menu
        // *contents* (the full dropdown) are only built when the user opens the menu,
        // which cannot happen before the animation completes and the Task below has
        // already fired. refreshAvailableLists() on listEvents still handles live
        // consistency exactly as before.
        let capturedCoordinator = owner.coordinator
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.availableLists = capturedCoordinator.getAllLists()
        }
        
        // Only preload if editing an existing film.
        if owner.isEditMode {
            loadExistingDetails(with: owner.filmID)
            captureOriginalValues()
        }

        // Seed the cached validation state after all fields are populated.
        // In edit mode this reflects the loaded data; in add mode it reflects
        // the declaration defaults (name is empty → isValid is false).
        lastIsValid = isValid
    }
    
    // MARK: - Change Tracking

    /// Whether this tab currently differs from the state it loaded in.
    ///
    /// Three terms, because a save from this tab commits through three routes:
    ///
    ///   1. The collected fields, which are what the FilmChangeset carries. One `==`
    ///      against the baseline — see `original` for why comparing the OUTPUT rather
    ///      than the stored properties is what retired this tab's special cases.
    ///   2. Hall of Fame, committed through its own coordinator calls and therefore
    ///      absent from the collected fields.
    ///   3. The two list-membership selections, reconciled as changeset membership
    ///      deltas rather than as fields on the film.
    ///
    /// `false` when there is no baseline, which is add mode — where nothing is a
    /// "change" because there is nothing to have changed from.
    private func computeHasChanges() -> Bool {
        guard let orig = original else { return false }
        return collectFilmFields() != orig
            || inHallOfFame != originalInHallOfFame
            || selectedListIDs != originalListIDs
            || selectedFilmQueueSection != originalFilmQueueSection
    }

    private func checkForChanges() {
        // Don't track changes during initial data load.
        guard !isLoadingData else { return }

        // Resolve owner once — avoids repeated weak-reference loads below.
        guard let owner = owner else { return }

        // Recompute validation state once. Only `name` and `hasReleaseDate` can move it,
        // so tracking the transition here is what keeps every OTHER field's keystroke
        // from waking FilmSheet through updateCanConfirm().
        let currentIsValid = isValid
        let validityChanged = currentIsValid != lastIsValid
        if validityChanged { lastIsValid = currentIsValid }

        // Add mode has no baseline, so this is always false and the branch below resolves
        // to the validity-only path — which is the whole of what add mode needs, since
        // canConfirm there is `isValid` alone.
        let changed = owner.isEditMode ? computeHasChanges() : false

        // Only write hasChanges — and only call owner.notifyChanges() — when the
        // aggregated result actually differs from the last known value. Skipping
        // the no-op path keeps every keystroke in edit mode from waking FilmSheet
        // once hasChanges has already latched to its steady-state value.
        // Mirrors the identical pattern in FSTabReleases.checkForChanges().
        if hasChanges != changed {
            hasChanges = changed
            // notifyChanges() re-derives canConfirm through
            // performCanConfirmUpdate(), which consults isValid, so a validity
            // transition occurring on this same edit is covered by this branch.
            owner.notifyChanges()
        } else if validityChanged {
            // hasChanges did not move, so notifyChanges() was not called — but the
            // validation state just flipped and canConfirm is derived from BOTH.
            // Without this branch, clearing "Name" (or the Release Date) in edit
            // mode after some other field had already latched hasChanges to true
            // left canConfirm stranded at true: the Update button stayed enabled
            // on an invalid film, the "required fields" hint stayed hidden, and
            // Return, which reads the same stored canConfirm, committed with it.
            // updateCanConfirm() has its own no-delta fast path, so this costs
            // nothing on the far more common non-transitioning edits.
            //
            // This is also the path add mode always takes: `changed` is false there and
            // `hasChanges` is already false, so the first branch never fires and a
            // validity flip reaches updateCanConfirm() exactly as it did when add mode
            // had a dedicated early return.
            owner.updateCanConfirm()
        }
    }

    // MARK: - Load Details from Database
    private func loadExistingDetails(with id: UUID) {
        guard let owner = owner else { return }

        // Set flag to suppress change tracking during load.
        isLoadingData = true
        defer { isLoadingData = false }

        // Get film from DataCoordinator's memory store (instant)
        guard let film = owner.coordinator.getFilm(id) else {
            owner.log("ERROR: Film \(id) not found in memory store")
            return
        }

        // Load all fields from the FilmSnapshot.
        name = film.name
        // The stored value is "yyyy-MM-dd'T'12:00:00'Z'" — a local calendar day with a
        // fixed UTC-noon suffix, not a real UTC instant. Parsing the day portion with the
        // dash formatter (which reads in TimeZone.current) recovers that same local day
        // regardless of the reader's UTC offset. Falling through to parseDate(from:) for
        // the full string would instead read the suffix as UTC noon, which rolls forward
        // to the next local day for any zone at UTC+12 or later.
        // A non-empty but unparseable legacy value still activates the picker
        // (hasReleaseDate = true) rather than silently hiding it as unset —
        // matching the precedent in FSTabNotes.editDate's load path. Moved here
        // from FSTabMetadata as part of the releaseDate field's relocation.
        if let dayOnly = Self.releaseDateFormatter.date(from: String(film.releaseDate.prefix(10))) {
            releaseDate = dayOnly
            hasReleaseDate = true
        } else if let parsed = parseDate(from: film.releaseDate) {
            releaseDate = parsed
            hasReleaseDate = true
        } else {
            releaseDate = Date()
            hasReleaseDate = !film.releaseDate.isEmpty
            if hasReleaseDate {
                owner.log("WARNING: Film \(id) has an unparseable releaseDate '\(film.releaseDate)' — the picker opens on today's date and will overwrite it if the sheet is saved.")
            }
        }
        userRating = film.userRating
        calendarTable = film.calendarTable

        // Get list memberships from coordinator's memory store (instant)
        // Get list memberships from coordinator's memory store (instant).
        // The raw set includes any internal Film Queue membership; split it so the
        // List Membership picker sees only user lists and the Up Next picker sees the section.
        let allMemberships = owner.coordinator.getListIDs(forFilm: id)
        let internalIDs = allMemberships.intersection(FilmQueue.allListIDs)
        originalInternalListIDs = internalIDs
        // Resolve a single canonical section deterministically (by queue order) in the
        // unexpected case that a film is in more than one internal list.
        let resolvedSection = internalIDs
            .compactMap { FilmQueueSection(listID: $0) }
            .sorted { $0.queueOrder < $1.queueOrder }
            .first
        selectedFilmQueueSection = resolvedSection
        originalFilmQueueSection = resolvedSection
        // User-generated lists only.
        selectedListIDs = allMemberships.subtracting(FilmQueue.allListIDs)
        originalListIDs = selectedListIDs
        owner.log("Loaded \(selectedListIDs.count) user list membership(s) and Up Next section \(resolvedSection?.displayName ?? "None") for film from memory store")
        
        // Parse duration field (stored in milliseconds).
        // A non-empty string that cannot be parsed, or a zero value, both mean no duration.
        loadedDurationMs = nil
        loadedEditedDurationMs = nil
        if let durationMs = film.duration.isEmpty ? nil : Int(film.duration), durationMs > 0 {
            loadedDurationMs = durationMs
            hasDuration = true
            let (hours, minutes) = DurationHelpers.millisecondsToHoursAndMinutes(durationMs)
            durationHours = hours
            durationMinutes = minutes
        } else {
            durationHours = 0
            durationMinutes = 0
            hasDuration = false
        }

        // Parse editedDuration field (same storage convention as duration: milliseconds).
        if let editedMs = film.editedDuration.isEmpty ? nil : Int(film.editedDuration), editedMs > 0 {
            loadedEditedDurationMs = editedMs
            hasEditedDuration = true
            let (hours, minutes) = DurationHelpers.millisecondsToHoursAndMinutes(editedMs)
            editedDurationHours = hours
            editedDurationMinutes = minutes
        } else {
            editedDurationHours = 0
            editedDurationMinutes = 0
            hasEditedDuration = false
        }

        genre = film.genre
        rating = film.rating
        descriptionText = film.descriptionText
        watched = film.watched
        edited = film.edited
        inHallOfFame = film.hofPosition > 0
        specialSorting = Set(film.specialSorting)
        rotationThresholdOverride = film.rotationThresholdOverride
        // Ensure the array always has exactly two slots (IMDb at [0], Blu-ray at [1]).
        let ids = film.externalIdentifiers
        externalIdentifiers = [
            ids.count > 0 ? ids[0] : "",
            ids.count > 1 ? ids[1] : ""
        ]
        infoComplete = film.infoComplete
        autoAddToQueueOnRotation = film.autoAddToQueueOnRotation
    }

    // genre and rating are loaded as-is, with no normalization: a stored value outside
    // the picker's vocabulary (an older vocabulary, a restore, an import, or a hand-edited
    // database) is carried straight to SheetPopUpButton, whose effectiveItems gives any
    // out-of-vocabulary tag its own menu row rather than rendering blank — the same
    // policy FSTabMetadata already follows for aspectRatio, subtitles, and digitalSource.
    // Nothing is lost until the user actively picks a different option.

    // Capture original state after loading.
    //
    // One line rather than a 22-argument initializer, and it is the same line
    // FSTabMetadata and FSTabNotes use. The baseline IS what a save would write, so it
    // cannot fall out of step with `collectFilmFields()` — there is no second field list
    // to update when a field is added. Hall of Fame is captured alongside it because it
    // is committed by a different route and so is not one of the collected fields; see
    // `originalInHallOfFame`.
    private func captureOriginalValues() {
        original = collectFilmFields()
        originalInHallOfFame = inHallOfFame
    }

    // MARK: - Film Queue Delta
    /// Computes the internal-list membership changes needed to move the film into the
    /// selected Up Next section (or out of the queue entirely). Returned sets are folded
    /// into the FilmChangeset's listsToAdd / listsToRemove by FilmSheet.confirm().
    ///
    /// The delta is derived against `originalInternalListIDs` (the film's actual internal
    /// memberships at load), so it is self-healing: selecting a section removes the film
    /// from every other internal list it may have been in, and selecting "None" removes it
    /// from all of them.
    func filmQueueDelta() -> (add: Set<UUID>, remove: Set<UUID>) {
        var target: Set<UUID> = []
        if let section = selectedFilmQueueSection { target.insert(section.listID) }
        let add = target.subtracting(originalInternalListIDs)
        let remove = originalInternalListIDs.subtracting(target)
        return (add: add, remove: remove)
    }

    // MARK: - Available Lists
    // Called by the deferred Task in init() and by FSTabDetailsView's listEvents
    // handler to keep the picker in sync after list creates, updates, or deletes.
    // buildAvailableLists is static to avoid an implicit self capture in the Task
    // closure and in refreshAvailableLists, keeping both call sites clean.
    // getAllLists() is already sorted in the canonical list order (displayOrder,
    // tie-broken on listID) and already excludes the internal Film Queue lists, so it
    // is used verbatim. The re-sort that used to sit here compared displayOrder ALONE
    // and Swift's sort is not guaranteed stable, so for two lists sharing a
    // displayOrder — reachable from a restored backup, or from two createList calls
    // that each read maxOrder before either awaited — it discarded the tiebreak the
    // store applies precisely to keep that case deterministic, letting this picker
    // order those lists differently from the sidebar and differently between openings.
    func refreshAvailableLists() {
        guard let coordinator = owner?.coordinator else { return }
        availableLists = coordinator.getAllLists()
    }

    // MARK: - DTO Support
    // Collects all details tab fields into a plain Sendable struct for FilmChangeset assembly.
    // Called by FilmSheet.confirm() when building the DTO-based save path.
    // Does NOT require a live Film @Model – all data is drawn from local tracked properties.
    func collectFilmFields() -> FilmDetailsFields {
        let durationStr: String
        if hasDuration {
            let ms = Self.durationMilliseconds(hours: durationHours, minutes: durationMinutes,
                                               loaded: loadedDurationMs)
            durationStr = "\(ms)"
        } else {
            durationStr = ""
        }
        let editedDurationStr: String
        // Guard on `edited` first: if the film is not marked as edited, the
        // editedDuration field must be blank regardless of what the stepper
        // fields currently hold. The UI hides the second DurationPicker when
        // edited == false, so those fields are stale state that must not be
        // persisted to the database.
        if edited && hasEditedDuration {
            let ms = Self.durationMilliseconds(hours: editedDurationHours, minutes: editedDurationMinutes,
                                               loaded: loadedEditedDurationMs)
            editedDurationStr = "\(ms)"
        } else {
            editedDurationStr = ""
        }
        // Re-stamp the picker's Date value into the app's canonical
        // "yyyy-MM-dd'T'12:00:00'Z'" storage format via the shared helper — see
        // releaseDateStorageString's doc comment for the full rationale. Moved
        // here from FSTabMetadata as part of the releaseDate field's relocation.
        let releaseDateString = Self.releaseDateStorageString(from: releaseDate, hasValue: hasReleaseDate)
        return FilmDetailsFields(
            name: name,
            releaseYear: hasReleaseDate ? "\(releaseYear)" : "",
            releaseDate: releaseDateString,
            userRating: userRating,
            calendarTable: calendarTable,
            duration: durationStr,
            editedDuration: editedDurationStr,
            genre: genre,
            rating: rating,
            descriptionText: descriptionText,
            watched: watched,
            edited: edited,
            specialSorting: FilmSpecialSorting.canonicalOrder.filter { specialSorting.contains($0) },
            rotationThresholdOverride: rotationThresholdOverride,
            externalIdentifiers: externalIdentifiers,
            infoComplete: infoComplete,
            autoAddToQueueOnRotation: autoAddToQueueOnRotation
        )
    }

}

// MARK: - FilmDetailsFields
/// Plain Sendable struct carrying the details-tab contribution to a FilmChangeset.
/// All fields correspond directly to Film model properties managed by this tab.
///
/// `Equatable` so it can serve as the tab's change-detection baseline as well as its
/// save payload — the same double duty `FilmMetadataFields` and `FilmNotesFields`
/// already perform for their tabs. Every member is a value type with value semantics,
/// so the synthesized `==` compares exactly the bytes a save would write.
struct FilmDetailsFields: Sendable, Equatable {
    let name: String
    let releaseYear: String
    let releaseDate: String
    let userRating: Int
    let calendarTable: [String]
    let duration: String
    let editedDuration: String
    let genre: String
    let rating: String
    let descriptionText: String
    let watched: Bool
    let edited: Bool
    let specialSorting: [String]
    let rotationThresholdOverride: Int?
    let externalIdentifiers: [String]
    let infoComplete: Bool
    let autoAddToQueueOnRotation: Int?
}
