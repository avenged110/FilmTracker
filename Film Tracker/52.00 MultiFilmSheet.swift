// MARK: - MultiFilmSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Observable view model for the MultiFilmSheet — the bulk editor opened by Edit Metadata…
// (⌘E, ⌘I) with more than one film selected. Every field opens to the value the films
// share, or blank (a checkbox, mixed) when they differ, and once changed is written to every
// film; Tags are appended instead. Owns the capacity checks, the
// confirmations and the save, which reuses the app's own list, Queue and Hall of Fame
// paths and one batched field write (DataCoordinator.applyBulkFieldEdit).

import SwiftUI

/// FilmSnapshot already has every field BulkFilmEdit reads and writes.
extension FilmSnapshot: BulkEditableFilm {}

@MainActor
@Observable
final class MultiFilmSheet: Identifiable, Loggable {
    nonisolated static let logTag = "[MultiFilmSheet]"

    let coordinator: DataCoordinator

    /// The films being edited, in the order the gallery showed them: what the sheet's table
    /// lists, and the order a Hall of Fame add ranks them in.
    let films: [FilmSnapshot]
    let filmIDs: [UUID]

    /// "Edit 5 Films" / "Update 5 Films". Fixed at open, as FilmSheet's titles are.
    let windowTitle: String
    let confirmButtonTitle: String

    // MARK: Tabs

    var selectedTab: MultiFilmTab = .details {
        didSet { appearedTabs.insert(selectedTab) }
    }
    /// Tabs built so far; each is built on its first visit and kept (FilmSheet.appearedTabs).
    private(set) var appearedTabs: Set<MultiFilmTab> = [.details]

    // MARK: Shared values

    /// What the films hold for each field as the sheet opened: what an unchanged control
    /// shows, and what choosing a value is compared with (choosing the shared value again is
    /// no change).
    struct Shared {
        var genre: BulkSharedValue<String> = .mixed
        var rating: BulkSharedValue<String> = .mixed
        var queueSection: BulkSharedValue<FilmQueueSection?> = .mixed
        var autoAddToQueueOnRotation: BulkSharedValue<Int?> = .mixed
        /// Whether automatic queueing is on, whatever the section: the row's checkbox.
        var autoAddEnabled: BulkSharedValue<Bool> = .mixed
        var userListIDs: BulkSharedValue<Set<UUID>> = .mixed
        var watched: BulkSharedValue<Bool> = .mixed
        var edited: BulkSharedValue<Bool> = .mixed
        var inHallOfFame: BulkSharedValue<Bool> = .mixed
        var infoComplete: BulkSharedValue<Bool> = .mixed
        var specialSorting: BulkSharedValue<Set<String>> = .mixed
        var rotationThresholdOverride: BulkSharedValue<Int?> = .mixed
        var notes: BulkSharedValue<String> = .mixed
    }

    let shared: Shared

    // MARK: Fields
    //
    // One tracked property per field rather than one BulkFilmEdit, so a row observes only
    // its own field: a keystroke in Notes re-evaluates the Notes row and the gutter, not
    // every row. `edit` assembles them when something needs the whole. Rows write them
    // through `assign(_:_:shared:)` (or a checkbox's click), so a field set back to the
    // films' shared value reads unchanged again.

    var genre: BulkField<String> = .unchanged
    var rating: BulkField<String> = .unchanged
    var queueSection: BulkField<FilmQueueSection?> = .unchanged
    var autoAddToQueueOnRotation: BulkField<Int?> = .unchanged
    var userListIDs: BulkField<Set<UUID>> = .unchanged
    var watched: BulkField<Bool> = .unchanged
    var edited: BulkField<Bool> = .unchanged
    var inHallOfFame: BulkField<Bool> = .unchanged
    var infoComplete: BulkField<Bool> = .unchanged
    var specialSorting: BulkField<Set<String>> = .unchanged {
        didSet { cascadeBlacklist(from: oldValue) }
    }
    var rotationThresholdOverride: BulkField<Int?> = .unchanged

    /// The Notes field's text: the films' shared notes as the sheet opens, else empty. See
    /// `notesEdit` for what it writes.
    var notes: String = ""

    /// The Tags field's entries, appended to each film's own. A plain array so the
    /// FilmSheet's own list row (FilmSheetListRow) can edit it by key path.
    var tags: [String] = []

    /// The rotation threshold the edit held when Special Sorting turned Blacklisted on, so
    /// turning it off again hands it back (the FilmSheet's Special Sorting row does the
    /// same for one film).
    @ObservationIgnored private var thresholdBeforeBlacklist: BulkField<Int?> = .unchanged

    /// Sets a field from its control: no change when it is the value every film shares.
    func assign<Value>(_ field: ReferenceWritableKeyPath<MultiFilmSheet, BulkField<Value>>,
                       _ value: Value, shared: BulkSharedValue<Value>) {
        self[keyPath: field] = shared.field(for: value)
    }

    /// A click on one of the flag checkboxes (BulkFilmEdit.checkboxClick).
    func clickCheckbox(_ field: ReferenceWritableKeyPath<MultiFilmSheet, BulkField<Bool>>,
                       shared: BulkSharedValue<Bool>) {
        self[keyPath: field] = BulkFilmEdit.checkboxClick(self[keyPath: field], shared: shared)
    }

    /// A click on the Hall of Fame checkbox. While the films would not fit (`hallOfFameBlocked`)
    /// the box skips "checked" — mixed → unchecked → mixed — so members can still be removed;
    /// otherwise it cycles as every flag does.
    func clickHallOfFameCheckbox() {
        let shared = shared.inHallOfFame
        guard hallOfFameBlocked else { return clickCheckbox(\.inHallOfFame, shared: shared) }
        inHallOfFame = shared.shown(inHallOfFame) == false ? .unchanged : shared.field(for: false)
    }

    /// The edit the fields make.
    var edit: BulkFilmEdit {
        var edit = BulkFilmEdit()
        edit.genre = genre
        edit.rating = rating
        edit.queueSection = queueSection
        edit.autoAddToQueueOnRotation = autoAddToQueueOnRotation
        edit.userListIDs = userListIDs
        edit.watched = watched
        edit.edited = edited
        edit.inHallOfFame = inHallOfFame
        edit.infoComplete = infoComplete
        edit.specialSorting = specialSorting
        edit.rotationThresholdOverride = rotationThresholdOverride
        edit.notes = notesEdit
        edit.tagsToAppend = tags
        return edit
    }

    /// What Notes writes. Its shared text, untouched, is no change. Over films whose notes
    /// differ, an empty field is no change too — so the sheet cannot clear a mix of notes
    /// it never showed, the costliest overwrite to make by accident. Clearing notes the films
    /// share, which the field showed, clears them.
    var notesEdit: BulkField<String> {
        let blank = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard case .same(let text) = shared.notes else { return blank ? .unchanged : .set(notes) }
        if notes == text { return .unchanged }
        if blank { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unchanged : .set("") }
        return .set(notes)
    }

    /// Puts Notes back to what it opened with.
    func revertNotes() {
        if case .same(let text) = shared.notes { notes = text } else { notes = "" }
    }

    // MARK: Shown values
    //
    // What the rows show for fields whose display depends on more than their own value.

    /// The automatic-queueing checkbox: nil while it is unchanged over a mix.
    var autoAddShownEnabled: Bool? {
        if case .set(let section) = autoAddToQueueOnRotation { return section != nil }
        return shared.autoAddEnabled.shown(.unchanged)
    }

    /// The automatic-queueing menu's section; nil shows "Select…".
    var autoAddShownSection: Int? {
        if case .set(let section?) = autoAddToQueueOnRotation { return section }
        if case .same(let section?) = shared.autoAddToQueueOnRotation { return section }
        return nil
    }

    func clickAutoAddCheckbox() {
        let shared = shared.autoAddToQueueOnRotation
        switch autoAddShownEnabled {
        case nil: autoAddToQueueOnRotation = shared.field(for: autoAddShownSection ?? 0)
        case true?: autoAddToQueueOnRotation = shared.field(for: nil)
        case false?:
            // Back to unchanged when that is where it came from: over a mix, or when every
            // film already queues automatically (to sections that may differ, which "Up
            // Next" would overwrite). Otherwise checking picks "Up Next", as the FilmSheet's
            // checkbox does, unless a section is already showing.
            let enabled = self.shared.autoAddEnabled
            autoAddToQueueOnRotation = enabled.isMixed || enabled == .same(true)
                ? .unchanged : shared.field(for: autoAddShownSection ?? 0)
        }
    }

    /// Whether the edit leaves every film blacklisted, so the Rotation Threshold row shows
    /// 60 and is disabled, as the FilmSheet's is for a blacklisted film.
    var rotationLocked: Bool {
        shared.specialSorting.shown(specialSorting)?.contains(FilmSpecialSorting.blacklisted) ?? false
    }

    /// What every film's threshold will be while Rotation Threshold is unchanged: the shared
    /// threshold — except that films which all opened blacklisted, and which the edit
    /// un-blacklists, go back to the default (BulkFilmEdit.applyFields).
    var rotationBaseline: BulkSharedValue<Int?> {
        let blacklisted = FilmSpecialSorting.blacklisted
        if let sorting = specialSorting.value, !sorting.contains(blacklisted),
           case .same(let opened) = shared.specialSorting, opened.contains(blacklisted) {
            return .same(nil)
        }
        return shared.rotationThresholdOverride
    }

    // MARK: Lists

    /// User lists for the List Membership menu, refreshed on list events (as FSTabDetails').
    var availableLists: [MemoryList] = []

    func refreshAvailableLists() {
        availableLists = coordinator.getAllLists()
    }

    // MARK: Capacity, as the sheet opened
    //
    // Fixed for the sheet's life, as FSTabDetails.upNextWasFullAtOpen is: they decide
    // whether the "Up Next" segment and the Hall of Fame checkbox can be used at all, from
    // the first frame. Nothing else can change either while the sheet is up except the
    // midnight auto-enqueue, which confirm() re-checks against.

    /// Selected films not yet in "Up Next" — the slots choosing it would take.
    let upNextIncoming: Int
    /// Open "Up Next" slots.
    let upNextVacancies: Int
    /// Choosing "Up Next" would overfill it: its segment is disabled.
    var upNextBlocked: Bool { upNextIncoming > upNextVacancies }

    /// Selected films not in the Hall of Fame — the places checking it would take.
    let hallOfFameIncoming: Int
    /// Open Hall of Fame places.
    let hallOfFameVacancies: Int
    /// Checking Hall of Fame would overfill it: the checkbox is disabled.
    var hallOfFameBlocked: Bool { hallOfFameIncoming > hallOfFameVacancies }

    /// Films blacklisted as the sheet opened. Their rotation threshold stays at 60 unless
    /// Special Sorting un-blacklists them (BulkFilmEdit.applyFields).
    let blacklistedCount: Int

    // MARK: Sheet state

    private(set) var isConfirming = false
    var showingSaveError = false
    var saveErrorDetail: String?
    /// A refusal or confirmation raised by confirm(), shown by the button bar.
    var pendingAlert: ConfirmAlert?
    /// The user agreed to replace other notes; reset whenever Notes changes again.
    @ObservationIgnored private var notesReplacementConfirmed: String?

    var dismissHandler: (() -> Void)?

    /// Whether Update (and Return) may save.
    var canConfirm: Bool { !edit.isEmpty && !isConfirming }

    enum ConfirmAlert: Identifiable, Equatable {
        case upNextFull(message: String)
        case hallOfFameFull(message: String)
        case replaceNotes(count: Int)
        /// Notes the films all shared, emptied.
        case clearNotes(count: Int)

        var id: String {
            switch self {
            case .upNextFull: return "upNextFull"
            case .hallOfFameFull: return "hallOfFameFull"
            case .replaceNotes: return "replaceNotes"
            case .clearNotes: return "clearNotes"
            }
        }
    }

    // MARK: Initialization

    /// - Parameter filmIDs: The selection, in gallery order. Films no longer in the store
    ///   are dropped.
    init(coordinator: DataCoordinator, filmIDs: [UUID]) {
        self.coordinator = coordinator
        let films = filmIDs.compactMap { coordinator.getFilm($0) }
        self.films = films
        self.filmIDs = films.map(\.id)
        let count = films.count
        // Singular only if films were deleted between the selection and the open.
        let noun = count == 1 ? "1 Film" : "\(count) Films"
        windowTitle = "Edit \(noun)"
        confirmButtonTitle = "Update \(noun)"

        let upNext = FilmQueue.upNextFilmIDs(coordinator: coordinator)
        upNextIncoming = Set(self.filmIDs).subtracting(upNext).count
        upNextVacancies = FilmQueue.upNextVacancies(coordinator: coordinator)
        let hallOfFameCount = coordinator.getHallOfFameFilms().count
        hallOfFameIncoming = films.filter { $0.hofPosition == 0 }.count
        hallOfFameVacancies = max(0, BulkFilmEdit.hallOfFameCapacity - hallOfFameCount)
        blacklistedCount = films.filter { $0.specialSorting.contains(FilmSpecialSorting.blacklisted) }.count

        let queueIDs = FilmQueue.allListIDs
        var shared = Shared()
        shared.genre = BulkSharedValue(films.lazy.map(\.genre))
        shared.rating = BulkSharedValue(films.lazy.map(\.rating))
        shared.watched = BulkSharedValue(films.lazy.map(\.watched))
        shared.edited = BulkSharedValue(films.lazy.map(\.edited))
        shared.inHallOfFame = BulkSharedValue(films.lazy.map { $0.hofPosition > 0 })
        shared.infoComplete = BulkSharedValue(films.lazy.map(\.infoComplete))
        // As a set: the menu compares sets, and stored order is not the user's choice.
        shared.specialSorting = BulkSharedValue(films.lazy.map { Set($0.specialSorting) })
        shared.rotationThresholdOverride = BulkSharedValue(films.lazy.map(\.rotationThresholdOverride))
        shared.autoAddToQueueOnRotation = BulkSharedValue(films.lazy.map(\.autoAddToQueueOnRotation))
        shared.autoAddEnabled = BulkSharedValue(films.lazy.map { $0.autoAddToQueueOnRotation != nil })
        shared.notes = BulkSharedValue(films.lazy.map(\.notes))
        var userLists: [Set<UUID>] = []
        var sections: [FilmQueueSection?] = []
        var damagedQueue = false
        for film in films {
            let lists = coordinator.getListIDs(forFilm: film.id)
            userLists.append(lists.subtracting(queueIDs))
            let queued = lists.intersection(queueIDs)
            // A film in two sections (a damaged restore) shares no section with anything.
            if queued.count > 1 { damagedQueue = true }
            sections.append(queued.first.flatMap(FilmQueueSection.init(listID:)))
        }
        shared.userListIDs = BulkSharedValue(userLists)
        shared.queueSection = damagedQueue ? .mixed : BulkSharedValue(sections)
        self.shared = shared
        if case .same(let text) = shared.notes { notes = text }

        #if DEBUG
        assert(BulkFilmEdit.tagLimit == ReorderableStringList.maxItems,
               "BulkFilmEdit.tagLimit must match the Tags list's own limit")
        assert(BulkFilmEdit.hallOfFameCapacity == MemoryStore.hallOfFameCapacity,
               "BulkFilmEdit.hallOfFameCapacity must match MemoryStore.hallOfFameCapacity")
        #endif

        // As FSTabDetails does: the read can rebuild the store's sorted lists, which is
        // work better kept off the presentation animation's first frames. The menu's
        // label does not need the lists, and its contents cannot open before this runs.
        Task { @MainActor [weak self] in
            self?.refreshAvailableLists()
        }
        Self.log("Opened for \(count) film(s); Up Next room \(upNextVacancies) for \(upNextIncoming), Hall of Fame room \(hallOfFameVacancies) for \(hallOfFameIncoming)")
    }

    // MARK: Cascades

    /// Blacklisting forces the threshold to 60 and disables its picker; un-blacklisting
    /// hands back what the edit held before — the Special Sorting row's rule (DetailsView),
    /// applied to the edit rather than to one film. "Blacklisted" here is what the row
    /// shows, so films that all opened blacklisted start locked.
    private func cascadeBlacklist(from oldValue: BulkField<Set<String>>) {
        let blacklisted = FilmSpecialSorting.blacklisted
        let was = shared.specialSorting.shown(oldValue)?.contains(blacklisted) ?? false
        let isNow = shared.specialSorting.shown(specialSorting)?.contains(blacklisted) ?? false
        if isNow && !was {
            thresholdBeforeBlacklist = rotationThresholdOverride
            rotationThresholdOverride = .unchanged
        } else if was && !isNow {
            rotationThresholdOverride = thresholdBeforeBlacklist
            thresholdBeforeBlacklist = .unchanged
        }
    }

    /// Films that keep their 60-month threshold whatever the Rotation Threshold row says:
    /// blacklisted now, and not un-blacklisted by this edit.
    var filmsKeepingBlacklistThreshold: Int {
        guard !rotationLocked else { return 0 }
        if specialSorting.isSet { return 0 }
        return blacklistedCount
    }

    // MARK: Queue

    /// Films the queue choice `section` would newly add, as they would be flagged after
    /// this edit: the special-sorting confirmation's subjects (FilmQueue.addNeedsConfirmation,
    /// which reads the films' stored tags, cannot see the sheet's unsaved ones).
    func flaggedFilmsNewlyQueued(in section: FilmQueueSection) -> (adding: Int, flagged: [[String]]) {
        let edit = edit
        let lists = queueListsByFilm()
        let adding = edit.filmsNewlyQueued(in: section, filmIDs: filmIDs, queueListsByFilm: lists)
        let flagged = adding.compactMap { id -> [String]? in
            guard let film = coordinator.getFilm(id) else { return nil }
            let tags = edit.resultingSpecialSorting(of: film.specialSorting)
            return tags.isEmpty ? nil : tags
        }
        return (adding.count, flagged)
    }

    /// The live "Up Next" overflow of the current queue choice; 0 unless it is "Up Next".
    func liveUpNextOverflow() -> Int {
        guard case .set(.upNext?) = queueSection else { return 0 }
        return FilmQueue.upNextOverflow(adding: Set(filmIDs), coordinator: coordinator)
    }

    private func queueListsByFilm() -> [UUID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: filmIDs.map { ($0, coordinator.filmQueueListIDs(forFilm: $0)) })
    }

    // MARK: Gutter

    /// Films that cannot take every new tag (they would pass the per-film limit).
    var filmsOverTagLimit: Int {
        let edit = edit
        guard !edit.appendedTags.isEmpty else { return 0 }
        return films.filter { edit.tags(appendedTo: $0.tags).dropped > 0 }.count
    }

    /// The line beside Update: what will happen, or what will not.
    var gutterNote: String {
        let edit = edit
        if edit.isEmpty { return "Change a field to update every selected film." }
        let fields = edit.changeCount == 1 ? "1 field" : "\(edit.changeCount) fields"
        let over = filmsOverTagLimit
        if over > 0 {
            let films = over == 1 ? "1 film has" : "\(over) films have"
            return "\(fields) will change. \(films) too many tags to take them all."
        }
        return "\(fields) will change."
    }

    // MARK: Actions

    func cancel() {
        guard !isConfirming else {
            Self.log("Cancel ignored — confirm is in progress")
            return
        }
        Self.log("Canceling sheet")
        dismissHandler?()
    }

    /// Re-checks the capacities live, asks about replacing other films' notes, then saves.
    func confirm() {
        guard !isConfirming else { return }
        // A Tags entry still held for its popover's close animation lands first, as in
        // FilmSheet.confirm(); one stopped at its duplicate prompt leaves the save for later.
        if ListPopoverDismissal.settlePending() { return }
        let edit = edit
        guard !edit.isEmpty else { return }

        // "Up Next" can fill while the sheet is open (the midnight auto-enqueue); the add
        // is refused whole, as every other add to it is.
        if liveUpNextOverflow() > 0 {
            pendingAlert = .upNextFull(message: FilmQueue.upNextFullDropMessage(Set(filmIDs), coordinator: coordinator))
            Self.log("Refused: 'Up Next' has no room for the selection")
            return
        }
        if case .set(true) = inHallOfFame {
            let members = coordinator.getHallOfFameFilms().count
            let incoming = filmIDs.filter { (coordinator.getFilm($0)?.hofPosition ?? 0) == 0 }.count
            if BulkFilmEdit.hallOfFameOverflow(adding: incoming, memberCount: members) > 0 {
                pendingAlert = .hallOfFameFull(message: Self.hallOfFameFullMessage(
                    incoming: incoming, vacancies: max(0, BulkFilmEdit.hallOfFameCapacity - members)))
                Self.log("Refused: the Hall of Fame has no room for the selection")
                return
            }
        }
        if case .set(let text) = edit.notes, notesReplacementConfirmed != text {
            let replacing = filmIDs.filter {
                guard let notes = coordinator.getFilm($0)?.notes else { return false }
                return !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && notes != text
            }.count
            if replacing > 0 {
                pendingAlert = text.isEmpty ? .clearNotes(count: replacing) : .replaceNotes(count: replacing)
                return
            }
        }
        save(edit)
    }

    /// The Replace Notes alert's confirming button.
    func confirmNotesReplacement() {
        notesReplacementConfirmed = edit.notes.value
        confirm()
    }

    /// Applies the edit: memberships first, so the field events that follow see the films
    /// where they now are (saveFilmChangeset's order); then the fields; then the Hall of
    /// Fame, whose add reads the snapshots the field write just stored.
    private func save(_ edit: BulkFilmEdit) {
        isConfirming = true
        defer { isConfirming = false }

        // Re-read now: a film can have been deleted, or moved, since the sheet opened.
        let ids = filmIDs.filter { coordinator.getFilm($0) != nil }
        guard !ids.isEmpty else { dismissHandler?(); return }
        let queueIDs = FilmQueue.allListIDs
        var userLists: [UUID: Set<UUID>] = [:]
        var queueLists: [UUID: Set<UUID>] = [:]
        var positions: [UUID: Int] = [:]
        for id in ids {
            let all = coordinator.getListIDs(forFilm: id)
            userLists[id] = all.subtracting(queueIDs)
            queueLists[id] = all.intersection(queueIDs)
            positions[id] = coordinator.getFilm(id)?.hofPosition ?? 0
        }
        let existingLists = Set(coordinator.getAllLists().map(\.listID))

        let memberships = edit.membershipChanges(filmIDs: ids, userListsByFilm: userLists,
                                                 queueListsByFilm: queueLists,
                                                 existingUserLists: existingLists)
        let hallOfFame = edit.hallOfFameChanges(filmIDs: ids, positions: positions)
        Self.log("Saving \(edit.changeCount) field(s) for \(ids.count) film(s): \(memberships.additions.count) list add(s), \(memberships.removals.count) list removal(s), queue \(memberships.queueAddition.map { "\($0.films.count) → \($0.section.displayName)" } ?? "unchanged"), Hall of Fame +\(hallOfFame.add.count)/−\(hallOfFame.remove.count)")

        #if DEBUG
        var phase = ContinuousClock.now
        func mark(_ name: String) {
            BulkSaveProbe.record("save/\(name)", since: phase)
            phase = ContinuousClock.now
        }
        mark("prepare")
        #endif

        // ── Memberships ─────────────────────────────────────────────────────────────
        for (listID, films) in memberships.additions {
            FilmManager.addFilmsToList(films, listID: listID, coordinator: coordinator)
        }
        if let move = memberships.queueAddition {
            FilmManager.addFilmsToList(move.films, listID: move.section.listID, coordinator: coordinator)
        }
        if !memberships.removals.isEmpty {
            FilmManager.removeFilmsFromLists(memberships.removals, coordinator: coordinator)
        }

        #if DEBUG
        mark("memberships")
        #endif

        // ── Fields ──────────────────────────────────────────────────────────────────
        // Every film the edit touches is stamped modified, as a FilmSheet save stamps its
        // film whatever it changed.
        let touched = memberships.films.union(hallOfFame.add).union(hallOfFame.remove)
        coordinator.applyBulkFieldEdit(edit, filmIDs: ids, alsoTouched: touched,
                                       explicitQueueFilmIDs: memberships.queueFilms(queueListIDs: queueIDs))

        #if DEBUG
        mark("fields")
        #endif

        // ── Hall of Fame ────────────────────────────────────────────────────────────
        if !hallOfFame.remove.isEmpty { coordinator.removeFromHallOfFame(hallOfFame.remove) }
        if !hallOfFame.add.isEmpty { coordinator.addToHallOfFame(hallOfFame.add) }

        dismissHandler?()
    }

    static func hallOfFameFullMessage(incoming: Int, vacancies: Int) -> String {
        if vacancies == 0 {
            return "The Hall of Fame may only contain at most 200 films. You must first remove an existing entry before you can add more."
        }
        return "The Hall of Fame may only contain at most 200 films and only has room for \(vacancies) more, but \(incoming) of the selected films are not in it. Select fewer films, or remove some entries first."
    }

    static func upNextBlockedMessage(incoming: Int, vacancies: Int) -> String {
        if vacancies == 0 {
            return "Your \"Up Next\" Queue contains the maximum of eight films. You must remove one or more films from it before you can add another."
        }
        let room = vacancies == 1 ? "1 more film" : "\(vacancies) more films"
        return "Your \"Up Next\" Queue has room for \(room), but \(incoming) of the selected films are not in it. Select fewer films, or remove some from \"Up Next\" first."
    }
}

#if DEBUG
/// Phase timings of the last MultiFilmSheet save, read by the `bulk-edit-perf` harness
/// scenario (DHBulkEdit), which empties it before each save.
@MainActor
enum BulkSaveProbe {
    static var phases: [(name: String, milliseconds: Double)] = []

    static func record(_ name: String, since start: ContinuousClock.Instant) {
        phases.append((name, DebugHarness.milliseconds(ContinuousClock.now - start)))
    }
}
#endif
