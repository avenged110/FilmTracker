// MARK: - FilmQueue.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the "Film Queue" — three internal, application-owned lists ("Up Next",
// "Soon", "Later") that occupy a middle ground between user-generated lists and smart
// lists. A film's membership is set manually (via the FilmSheet Details tab), but the
// three lists themselves are created inherently at startup, can never be deleted, and
// are hidden from every user-facing list surface (the sidebar "Lists" section, the
// "Add to List" menus, the List Membership picker, and the Right Sidebar membership
// table). Internally each section is a normal ListObject / ListMembership pair, so the
// entire feature is automatically covered by the MemoryStore ↔ DataManager persistence
// pipeline, the snapshot-cache fingerprint, and the XML export / restore pipeline
// without any special-case handling in those subsystems.

import Foundation
import Observation

// MARK: - Up Next Section

/// The three mutually-exclusive time-based sections of the Film Queue. A film may
/// belong to exactly one section, or to none. Each case maps to a fixed, stable list
/// UUID so the internal ListObjects are identified deterministically across launches,
/// backups, and restores — independent of the list's (fixed) display name.
enum FilmQueueSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case upNext = "Up Next"
    case soon   = "Soon"
    case later  = "Later"

    var id: String { rawValue }

    /// The canonical display name for the section (identical to the raw value).
    var displayName: String { rawValue }

    /// Relative ordering of the section within the queue (Up Next → Soon → Later).
    /// Used to derive a stable, well-separated display order for the backing list and
    /// to pick a single canonical section deterministically if a film is ever found in
    /// more than one internal list (a corruption-recovery safeguard).
    var queueOrder: Int {
        switch self {
        case .upNext: return 0
        case .soon:   return 1
        case .later:  return 2
        }
    }

    /// The fixed, stable UUID of the backing internal list for this section.
    ///
    /// These literals are compile-time constants and are validated once at process
    /// launch. They are namespaced with a distinctive, all-but-collision-proof prefix
    /// so they can never clash with a randomly-generated user list UUID.
    var listID: UUID {
        switch self {
        case .upNext: return Self.upNextID
        case .soon:   return Self.soonID
        case .later:  return Self.laterID
        }
    }

    // Force-unwraps of fixed, valid UUID string literals. If a literal were ever mistyped
    // the app would trap immediately at first access during development — a loud, obvious
    // failure rather than a silent data-integrity problem.
    private static let upNextID = UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000001")!
    private static let soonID   = UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000002")!
    private static let laterID  = UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000003")!

    /// Resolves a list UUID back to its section, or nil if the UUID is not one of the
    /// three internal lists.
    init?(listID: UUID) {
        switch listID {
        case Self.upNextID: self = .upNext
        case Self.soonID:   self = .soon
        case Self.laterID:  self = .later
        default:            return nil
        }
    }
}

// MARK: - Film Queue Namespace

/// Central constants and helpers for the Film Queue feature. Consumers use these to
/// exclude the internal lists from user-facing enumerations and to detect / reserve the
/// internal list names.
enum FilmQueue {
    /// The set of all three internal list UUIDs, for fast membership tests.
    static let allListIDs: Set<UUID> = Set(FilmQueueSection.allCases.map { $0.listID })

    /// Returns true if the supplied list UUID belongs to one of the internal Up Next lists.
    static func isInternalList(_ listID: UUID) -> Bool {
        allListIDs.contains(listID)
    }

    /// The lowercased set of internal list names, used to reject user list names that would
    /// collide with (and be confused for) an internal Up Next list.
    static let reservedNames: Set<String> = Set(FilmQueueSection.allCases.map { $0.rawValue.lowercased() })

    /// Returns true if the supplied name (after trimming + lowercasing) matches an internal
    /// Up Next list name.
    static func isReservedName(_ name: String) -> Bool {
        reservedNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The base display-order value assigned to the internal lists. Chosen far above any
    /// realistic user list count so that, even though the internal lists are excluded from
    /// every user-facing enumeration, any incidental ordering places them last.
    static let baseDisplayOrder = 1_000_000

    /// The display order for a given section's backing list.
    static func displayOrder(for section: FilmQueueSection) -> Int {
        baseDisplayOrder + section.queueOrder
    }

    // MARK: Add confirmation

    /// Whether adding `filmIDs` to the queue must be confirmed first: the preference is on
    /// and at least one of the films carries a special-sorting tag ("Ignore",
    /// "Blacklisted", …). The rule behind the sidebar drop and the "Add to Queue" menus.
    /// The FilmSheet picker applies the same test to the sheet's unsaved tags itself,
    /// since those are not in the coordinator yet.
    @MainActor
    static func addNeedsConfirmation(_ filmIDs: Set<UUID>, coordinator: DataCoordinator) -> Bool {
        Preferences.confirmFilmQueueAdd
            && filmIDs.contains { !(coordinator.getFilm($0)?.specialSorting.isEmpty ?? true) }
    }

    /// The confirmation message for adding one film that carries `tags`. Shared by the
    /// FilmSheet picker's alert and AlertHostView's single-film drop/menu alert, which
    /// must read the same; tags are quoted in `FilmSpecialSorting.canonicalOrder`.
    static func addConfirmationMessage(flaggedWith tags: some Collection<String>) -> String {
        let activeTags = FilmSpecialSorting.canonicalOrder.filter { tags.contains($0) }
        let isPlural = activeTags.count != 1
        let quoted = activeTags.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Are you sure you want to add this film to the Queue? "
            + "It is flagged with the special sorting parameter\(isPlural ? "s" : "") \(quoted)."
    }
}

// MARK: - Up Next Capacity

/// "Up Next" holds at most eight films — the number of slots ATVQ shows, and the number of
/// placeholder slots the Queue's "All" tab draws (UpNextSlots.swift). Every path that can
/// add a film to "Up Next" asks `upNextOverflow` first and, when the add would not fit,
/// refuses it whole (never a partial add) with `upNextFullNotice`:
///   • the LeftSidebar Queue row drop (LeftSidebar.RowDragProxyView), whose alert also
///     offers to add the films to "Soon" instead
///   • the "Add to Queue" menus (FilmQueueAssignment.toggle) and their special-sorting
///     confirmation (AlertHostView)
///   • the FilmSheet's Queue Membership picker (DetailsView, backed by
///     FSTabDetails.filmQueueDelta)
///   • the empty slots' drop targets and slot sheet (UpNextSlots.swift)
/// The rotation auto-enqueue, which has no user to tell, sends what doesn't fit to "Soon"
/// instead (DataCoordinator.autoEnqueueFilmsNewlyUpForRotation), and
/// DataCoordinator.addFilmsToList refuses an overflowing add as a last line of defense.
/// A restored backup is taken as it is.
extension FilmQueue {
    static let upNextCapacity = 8

    /// The films in "Up Next" right now.
    @MainActor
    static func upNextFilmIDs(coordinator: DataCoordinator) -> Set<UUID> {
        coordinator.getList(FilmQueueSection.upNext.listID)?.filmIDs ?? []
    }

    /// How many more films "Up Next" can take.
    @MainActor
    static func upNextVacancies(coordinator: DataCoordinator) -> Int {
        max(0, upNextCapacity - upNextFilmIDs(coordinator: coordinator).count)
    }

    /// How many of `filmIDs` would not fit if they were added to "Up Next" (films already
    /// there take no new slot); 0 when the add fits. An add with no newcomers always fits,
    /// even while a restored backup leaves "Up Next" over capacity — otherwise the menus
    /// would disable the checked "Up Next" item and the films could not be unchecked.
    @MainActor
    static func upNextOverflow(adding filmIDs: Set<UUID>, coordinator: DataCoordinator) -> Int {
        let current = upNextFilmIDs(coordinator: coordinator)
        let incoming = filmIDs.subtracting(current).count
        guard incoming > 0 else { return 0 }
        return max(0, current.count + incoming - upNextCapacity)
    }

    static let upNextFullTitle = "\"Up Next\" Queue Full"

    /// The refusal message for adding `adding` new films when `vacancies` slots are open.
    static func upNextFullMessage(adding: Int, vacancies: Int) -> String {
        if vacancies == 0 {
            return "Your \"Up Next\" Queue already contains the maximum of eight films. "
                + "Remove a film from it before adding another."
        }
        return "Your \"Up Next\" Queue can hold a maximum of eight films and only has room for "
            + "\(vacancies) more, so the \(adding) films you tried to add were not added. "
            + "Add fewer films, or remove some from \"Up Next\" first."
    }

    /// `upNextFullMessage` for an add of `filmIDs` given "Up Next" as it stands now.
    @MainActor
    static func upNextFullDropMessage(_ filmIDs: Set<UUID>, coordinator: DataCoordinator) -> String {
        upNextFullMessage(adding: filmIDs.subtracting(upNextFilmIDs(coordinator: coordinator)).count,
                          vacancies: upNextVacancies(coordinator: coordinator))
    }

    /// Checks an add of `filmIDs` to "Up Next" and, when it would not fit, posts the
    /// refusal alert and returns true. `afterDragSession` defers the alert past the end of
    /// a drag, for callers inside performDragOperation.
    @MainActor
    static func refuseUpNextAddIfFull(_ filmIDs: Set<UUID>, coordinator: DataCoordinator,
                                      afterDragSession: Bool = false) -> Bool {
        guard upNextOverflow(adding: filmIDs, coordinator: coordinator) > 0 else { return false }
        AppEventBus.shared.sendAlert(.showNotice(
            title: upNextFullTitle,
            message: upNextFullDropMessage(filmIDs, coordinator: coordinator),
            afterDragSession: afterDragSession))
        return true
    }
}

// MARK: - Film Queue Assignment

/// The single shared entry point behind every "Add to Queue" menu — the gallery
/// contextual menu (23_80_GalleryMenu.swift), the MenuBar's "Film" menu
/// (12_00_MenuBar.swift), and the GalleryTitleBar's selection menu button
/// (23_70_GalleryTitleBar.swift). Centralizing it here guarantees the three surfaces
/// cannot diverge in how they resolve membership, enforce mutual exclusivity, or defer
/// their work, exactly as FilmRemoval does for the three removal commands.
@MainActor
enum FilmQueueAssignment: Loggable {
    nonisolated static let logTag = "[FilmQueueAssignment]"

    /// True when EVERY supplied film already occupies `section` and no other — i.e. the
    /// assignment would be a complete no-op. Drives the menus' checkmark state, and is
    /// re-evaluated inside `assign` immediately before any mutation so a stale menu can
    /// never cause redundant work.
    ///
    /// The test is `== [section.listID]` rather than a plain `contains`, so a film left
    /// in two sections by a corrupted or pre-exclusivity backup restore still reports as
    /// needing reconciliation and gets healed by the add path below.
    static func allFilmsAreInSection(_ filmIDs: Set<UUID>,
                                     section: FilmQueueSection,
                                     coordinator: DataCoordinator) -> Bool {
        guard !filmIDs.isEmpty else { return false }
        let target: Set<UUID> = [section.listID]
        return filmIDs.allSatisfy { coordinator.filmQueueListIDs(forFilm: $0) == target }
    }

    /// Toggles every supplied film's membership in `section`: if every film already
    /// occupies exactly that section, removes them from the Film Queue entirely; otherwise
    /// assigns them all to `section`, moving any that currently occupy a different one.
    /// Films already in `section` alongside films that are not are treated as the "not yet
    /// unanimous" case and are unified into `section`, exactly as the old assign-only
    /// behavior did — only a selection that is ALREADY entirely in `section` reads as a
    /// request to remove it, which is what turns the menu item into a checkbox-style toggle.
    ///
    /// The add reconciliation itself is not performed here: it lives in
    /// DataCoordinator.enforceFilmQueueExclusivity, which every add path already routes
    /// through, so a single call covers "remove from the other two sections" and "add to
    /// this one" as one coherent operation with a single rollback. FilmManager.addFilmsToList
    /// is synchronous — the whole mutation is an in-memory update plus a background persist
    /// — which keeps the Film Queue's own on-screen refresh in the same run loop turn as the
    /// membership change: no intermediate frame in which a moved film has left its old
    /// section but not yet arrived in its new one.
    ///
    /// The removal branch reuses FilmManager.removeFromFilmQueue, which resolves each
    /// film's actual queue membership independently rather than assuming `section` is the
    /// only list involved — the same corruption-proofing it already provides for the
    /// "Remove from All Lists" / confirm-Queue-removal paths.
    ///
    /// The work is deferred past the menu's dismissal animation for the same reason every
    /// other reload-triggering menu action in the app is (see deferPastMenuDismissal):
    /// when the Film Queue is the view on screen, this triggers a collection-view reload
    /// that would otherwise compete with CoreAnimation's menu teardown frames.
    static func toggle(_ filmIDs: Set<UUID>,
                       section: FilmQueueSection,
                       coordinator: DataCoordinator) {
        guard !filmIDs.isEmpty else { return }

        deferPastMenuDismissal {
            // Re-checked here rather than at call time: the menu may have been built
            // against membership that has since changed (a FilmSheet save, a drag onto
            // the sidebar's Queue row, the midnight auto-enqueue).
            if Self.allFilmsAreInSection(filmIDs, section: section, coordinator: coordinator) {
                Self.log("Removing \(filmIDs.count) film(s) from Queue section '\(section.displayName)'")
                Task {
                    FilmManager.removeFromFilmQueue(filmIDs, coordinator: coordinator)
                }
                return
            }

            // "Up Next" is capped at eight; an add that would not fit is refused whole.
            if section == .upNext,
               FilmQueue.refuseUpNextAddIfFull(filmIDs, coordinator: coordinator) {
                Self.log("Refused add of \(filmIDs.count) film(s) to 'Up Next' — not enough room")
                return
            }

            // Special-sorting confirmation gate, matching the LeftSidebar drop and the
            // FilmSheet picker. Only the add branch is gated — removing is never confirmed.
            if FilmQueue.addNeedsConfirmation(filmIDs, coordinator: coordinator) {
                Self.log("Deferring add of \(filmIDs.count) film(s) to Queue section '\(section.displayName)' pending special-sorting confirmation")
                AppEventBus.shared.sendAlert(.confirmFilmQueueAddFromMenu(filmIDs: filmIDs,
                                                                          listID: section.listID))
                return
            }

            Self.log("Adding \(filmIDs.count) film(s) to Queue section '\(section.displayName)'")
            FilmManager.addFilmsToList(filmIDs, listID: section.listID,
                                       coordinator: coordinator)
            Self.armPostMoveScroll(filmIDs, coordinator: coordinator)
        }
    }

    /// Places the moved films back in view after a section change.
    ///
    /// A section move reorders the Film Queue's film array without changing its contents,
    /// so the moved film keeps its selection but can land anywhere — commonly far below the
    /// viewport, since "Later" sits at the end of a queue of any size. Nothing repositioned
    /// the gallery for it: the grid's post-edit scroll (GallerySubview's Priority 1 branch)
    /// is driven by `.film(.updated)`, and a membership change posts `.list` events instead,
    /// so both gallery styles simply redrew around a selection the user could no longer see.
    ///
    /// The fix routes through GalleryScrollIntent rather than a new event, because both
    /// styles already implement the reuse-path branch that consumes one — and this is
    /// exactly the situation `consumableOnReuse` describes: no navigation occurs, so the
    /// single mounted gallery IS the destination and no fresh makeNSView will ever run to
    /// claim the intent instead.
    ///
    /// Called AFTER the mutation, deliberately: `addFilmsToList` reaches
    /// `DataCoordinator.refreshFilms()` synchronously, so `coordinator.films` already holds
    /// the post-move order here and the topmost moved film can simply be read off it rather
    /// than predicted. With a multi-film selection that topmost film is the right anchor —
    /// the moved films are contiguous within their new section, so placing the first at the
    /// top brings as many of the others into view as will fit.
    static func armPostMoveScroll(_ filmIDs: Set<UUID>, coordinator: DataCoordinator) {
        // Only the Film Queue's own gallery can be showing the move. Any other view either
        // does not contain these films or does not order them by queue section, and an
        // intent addressed elsewhere would sit unconsumed until an unrelated visit.
        guard case .filmQueue = ViewStateManager.shared.activeView else { return }
        // Nothing to place when the queue is filtered to a single section and the films
        // just left it — they are no longer part of the displayed set at all.
        guard let target = coordinator.films.first(where: { filmIDs.contains($0.id) }) else { return }

        GalleryScrollIntent.shared.set(filmID: target.id,
                                       targetViewID: .filmQueue,
                                       consumableOnReuse: true)
        Self.log("Post-move scroll armed for film \(target.id) in the Film Queue")
    }
}

// MARK: - Film Queue Filter

/// Display filter for the Film Queue gallery's segmented picker: either all three sections
/// together (with divider bands separating them), or a single section shown alone with no
/// dividers. This is purely a presentation concern — it never affects section membership,
/// list contents, or any persisted state; it only narrows which films are loaded into the
/// gallery and whether GallerySubview computes section-divider breaks.
enum FilmQueueFilter: String, CaseIterable, Hashable, Sendable {
    case all = "All"
    case upNext = "Up Next"
    case soon = "Soon"
    case later = "Later"

    var displayName: String { rawValue }

    /// The token that distinguishes this tab's persisted ViewState slot from its
    /// siblings', or nil for `.all`.
    ///
    /// nil for `.all` deliberately: the Queue's unnarrowed tab keeps the flat,
    /// unqualified "filmQueue" persistence key it has always used, so every sort, filter
    /// and grid/list choice a user made there before the three section tabs gained slots
    /// of their own is still read back into the tab they made it on. The three section
    /// tabs each append their token and therefore start from ViewState's own defaults,
    /// which is the correct starting point for a tab the user has not yet configured.
    ///
    /// Deliberately NOT the raw value: these tokens become dictionary keys inside a
    /// persisted preference, so they must stay stable even if a section's display name is
    /// ever reworded. See ViewStateKey.persistenceKey.
    var persistenceToken: String? {
        switch self {
        case .all:    return nil
        case .upNext: return "upNext"
        case .soon:   return "soon"
        case .later:  return "later"
        }
    }

    /// The single section this filter isolates, or nil for `.all` (no restriction).
    var section: FilmQueueSection? {
        switch self {
        case .all:    return nil
        case .upNext: return .upNext
        case .soon:   return .soon
        case .later:  return .later
        }
    }
}

// MARK: - Film Queue Filter State

/// Tracks the currently selected Film Queue display filter and drives the real-time gallery
/// refresh when the user changes it via the segmented picker in GalleryTitleBar. Mirrors the
/// pattern used by RecentsState / SmartListVariantState, but deliberately does NOT change the
/// active ViewIdentifier — the Film Queue remains a single view; only the loaded film set and
/// the section-divider computation respond to this filter.
@MainActor
@Observable
final class FilmQueueFilterState {
    static let shared = FilmQueueFilterState()

    var selectedFilter: FilmQueueFilter = .all

    private init() {}

    func selectFilter(_ filter: FilmQueueFilter) {
        guard selectedFilter != filter else { return }

        // Clear the current selection exactly as SubcategoryNavigation.performSwitch does
        // for every other sub-tab transition (Recents categories, rotation/alternate
        // variants, Filtered Library sorting variants). The Film Queue's three sections
        // deliberately share a single ViewIdentifier, so performSwitch itself is never
        // invoked here and MainView.handleViewChange never fires either — without this
        // explicit clear, a selected film would silently survive into an unrelated Queue
        // section whenever the same film ID happens to also appear there.
        SelectionState.shared.clearImmediate()

        // Bank this section's scroll position and arm the incoming section's, exactly as
        // ViewStateManager.switchToViewSync does for every other sub-tab. The Queue needs
        // its own call because its sections deliberately share a single ViewIdentifier —
        // switchToViewSync is never invoked for this transition — and the keys are built
        // explicitly rather than through GalleryScrollKey.current(for:) because this must
        // run BEFORE selectedFilter flips below, while `selectedFilter` still names the
        // outgoing section.
        ViewStateManager.shared.prepareScrollHandoff(
            fromKey: GalleryScrollKey(viewID: .filmQueue, subTab: selectedFilter.rawValue),
            toKey: GalleryScrollKey(viewID: .filmQueue, subTab: filter.rawValue))

        // Bank this tab's sort/filter/style/dividers state and promote the incoming tab's,
        // for exactly the same reason and with exactly the same timing constraint as the
        // scroll handoff above: the Queue's four tabs each own their view preferences, and
        // switchToViewSync — which performs this promotion for every other sub-tab in the
        // app — is never invoked for a transition that does not change the ViewIdentifier.
        // Also runs BEFORE selectedFilter flips, while the outgoing tab is still current.
        ViewStateManager.shared.prepareSubTabStateHandoff(
            fromKey: ViewStateKey(viewID: .filmQueue, subTab: selectedFilter.persistenceToken),
            toKey: ViewStateKey(viewID: .filmQueue, subTab: filter.persistenceToken))

        // selectedFilter updates synchronously so the segmented control reflects the
        // new choice immediately; the reload is deferred past the control's selection
        // animation (see deferPastMenuDismissal for the full timing rationale).
        selectedFilter = filter
        deferPastMenuDismissal {
            ViewStateManager.shared.forceReload()
        }
    }
}
