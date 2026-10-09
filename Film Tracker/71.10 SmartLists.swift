// MARK: - SmartLists.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Manages computed "smart lists" that automatically populate based on film properties.

import SwiftUI
import Combine

// MARK: - Smart List Types
enum SmartListType: String, CaseIterable, Identifiable, Sendable {
    case upForRotation = "Up for Rotation"
    case viewedOverOneYearAgo = "Viewed Over One Year Ago"
    case purchased = "Purchased"
    case purchased4K = "Purchased 4K"
    case purchasedBluray = "Purchased Blu-ray"
    case purchasedDVD = "Purchased DVD"
    case unpurchased = "Unpurchased"
    case unpurchased4K = "Unpurchased 4K"
    case unpurchasedBluray = "Unpurchased Blu-ray"
    case unpurchasedDVD = "Unpurchased DVD"
    case edited = "Edited"
    case alternateVersions = "Alternate Versions"
    case filteredLibrary = "Filtered Library"
    case waitingForEdit = "Waiting for Edit"
    case temporarilyOnHold = "Temporarily On Hold"
    case indefinitelyOnHold = "Indefinitely On Hold"
    case ignore = "Ignore"
    case blacklisted = "Blacklisted"
    
    var id: String { rawValue }
    
    var icon: String { ViewGlyphs.smartList.outline }

    /// The title and body of the placeholder GalleryView shows when this smart list is
    /// open and empty. Pure per-case copy, so it lives here beside the case it describes
    /// rather than as an eighteen-arm `switch` in the view: the placeholder builder is
    /// then one `StandardPlaceholder` for every list, and adding a smart list is a compile
    /// error here until its copy is written — which the view-side switch could only
    /// achieve by being exhaustive over an enum it does not own.
    var emptyState: (title: String, message: String) {
        switch self {
        case .upForRotation:
            return ("No Films Up for Rotation",
                    "Films will appear here when their last watched date exceeds the rotation threshold.")
        case .viewedOverOneYearAgo:
            return ("No Films Viewed Over a Year Ago",
                    "Films will appear here when their last watched date is one year or more in the past.")
        case .purchased:
            return ("No Purchased Films",
                    "Add releases to films which you have purchased to populate this list.")
        case .purchased4K:
            return ("No Films Purchased in 4K UHD",
                    "Add 4K UHD releases to films which you have purchased to populate this list.")
        case .purchasedBluray:
            return ("No Films Purchased on Blu-ray",
                    "Add Blu-ray releases to films which you have purchased to populate this list.")
        case .purchasedDVD:
            return ("No Films Purchased on DVD",
                    "Add DVD releases to films which you have purchased to populate this list.")
        case .unpurchased:
            return ("No Unpurchased Films",
                    "Add releases to films which you haven't purchased yet to populate this list.")
        case .unpurchased4K:
            return ("No Unpurchased Films on 4K UHD",
                    "Add 4K UHD releases to films which you haven't purchased yet to populate this list.")
        case .unpurchasedBluray:
            return ("No Unpurchased Films on Blu-ray",
                    "Add Blu-ray releases to films which you haven't purchased yet to populate this list.")
        case .unpurchasedDVD:
            return ("No Unpurchased Films on DVD",
                    "Add DVD releases to films which you haven't purchased yet to populate this list.")
        case .edited:
            return ("No Edited Films",
                    "Mark films as edited to populate this list.")
        case .alternateVersions:
            return ("No Alternate Versions",
                    "Add releases with director's cuts, extended editions, or other versions to populate this list.")
        case .filteredLibrary:
            return ("No Films Deemed Watchable",
                    "Films will appear here when they are marked as watched and not given any special sorting parameter.")
        case .waitingForEdit:
            return ("No Films Waiting to Be Edited",
                    "Mark films as waiting for edit to populate this list.")
        case .temporarilyOnHold:
            return ("No Films Temporarily on Hold",
                    "Mark films as temporarily on hold to populate this list.")
        case .indefinitelyOnHold:
            return ("No Films Placed on Hold Indefinitely",
                    "Mark films as indefinitely on hold to populate this list.")
        case .ignore:
            return ("No Ignored Films",
                    "Mark films as ignored to populate this list.")
        case .blacklisted:
            return ("No Blacklisted Films",
                    "Mark films as blacklisted to populate this list.")
        }
    }
    
    /// The five types that get a sidebar row of their own, in declaration order.
    /// Computed once and cached: both LeftSidebar's "Smart Lists" section and MenuBar's
    /// smart-list menu enumerate this on every body evaluation, and re-running the
    /// `showsInSidebar` filter across all eighteen cases each time is pure waste.
    static let sidebarCases: [SmartListType] = allCases.filter { $0.showsInSidebar }

    /// Returns true if this list type should appear in the sidebar
    var showsInSidebar: Bool {
        switch self {
        case .upForRotation, .purchased, .unpurchased, .alternateVersions, .filteredLibrary:
            return true
        case .viewedOverOneYearAgo:
            return false // Accessed via Picker in the Up for Rotation view
        case .purchased4K, .purchasedBluray, .purchasedDVD:
            return false // These are accessed via Picker in the Purchased view
        case .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD:
            return false // These are accessed via Picker in the Unpurchased view
        case .edited:
            return false // Accessed via Picker in the Alternate Versions view
        case .waitingForEdit, .temporarilyOnHold, .indefinitelyOnHold, .ignore, .blacklisted:
            return false // These are accessed via Picker in the Filtered Library view
        }
    }
    
    // MARK: - Family Membership Tests
    //
    // Each of these asks the same question — "is this type a member of family X?" — and
    // each is answered by `sidebarParent`, the one exhaustive switch below that assigns
    // every smart list to its family. They used to be four hand-written exhaustive
    // switches of their own, which meant a newly added smart list had to be spelled out
    // in five places that all had to agree; now `sidebarParent` is the only place that
    // has to know, and the compiler still forces it to be updated there.

    /// True for "Purchased" and its 4K / Blu-ray / DVD format variants.
    var isPurchasedFormat: Bool { sidebarParent == .purchased }

    /// True for "Unpurchased" and its 4K / Blu-ray / DVD format variants.
    var isUnpurchasedFormat: Bool { sidebarParent == .unpurchased }

    /// True for "Up for Rotation" and "Viewed Over One Year Ago".
    var isRotationVariant: Bool { sidebarParent == .upForRotation }

    /// True for "Alternate Versions" and "Edited".
    var isAlternateVersionsVariant: Bool { sidebarParent == .alternateVersions }

    /// The one release format a "Purchased <format>" list is about, or nil for every other
    /// list — "Purchased" itself included, which spans all formats.
    ///
    /// The single source of the format-to-list pairing: membership (`purchasedFormatLists`)
    /// is derived from it, and so is the Date Purchased sort's format scope (see
    /// `ViewIdentifier.purchaseFormatScope`), so a film can never sit in "Purchased 4K"
    /// while being ordered there by its Blu-ray purchase.
    var purchaseFormat: ReleaseFormat? {
        switch self {
        case .purchased4K:     return .uhd4K
        case .purchasedBluray: return .bluRay
        case .purchasedDVD:    return .dvd
        default:               return nil
        }
    }

    /// The sidebar row that represents this smart list.
    ///
    /// Every smart list is reachable from the sidebar, but only the five parents actually
    /// have a row of their own (`showsInSidebar`); the remaining thirteen are sub-variants
    /// selected via a picker inside their parent's view. This maps each type to the row
    /// that must be highlighted while it is displayed, and is the inverse of the
    /// `isRotationVariant` / `isPurchasedFormat` / `isUnpurchasedFormat` /
    /// `isAlternateVersionsVariant` family above, all four of which are now derived
    /// from it rather than restating it.
    ///
    /// Used by ShowInListNavigation (GlobalUtilities.swift) to pin `selectedSidebarItem`
    /// to the correct row when navigating directly to a sub-variant, and by
    /// GalleryView.handleSidebarChange to decide whether the smart list currently loaded
    /// belongs to the family whose row is being switched to. Exhaustive by design: adding
    /// a new smart list is a compile error here until its parent is declared.
    var sidebarParent: SmartListType {
        switch self {
        case .upForRotation, .viewedOverOneYearAgo:
            return .upForRotation
        case .purchased, .purchased4K, .purchasedBluray, .purchasedDVD:
            return .purchased
        case .unpurchased, .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD:
            return .unpurchased
        case .alternateVersions, .edited:
            return .alternateVersions
        case .filteredLibrary, .waitingForEdit, .temporarilyOnHold,
             .indefinitelyOnHold, .ignore, .blacklisted:
            return .filteredLibrary
        }
    }

    /// This type's family in picker display order: the parent first, then its
    /// sub-variants in declaration order. The inverse of `sidebarParent`, and the single
    /// source of truth both for what each gallery sub-variant picker offers and for the
    /// Cmd+<digit> sub-tab order that selects the same variants from the keyboard — so the
    /// two can no longer disagree, as they could while each spelled its own list out by
    /// hand. A parent's own family is itself plus its variants; a sub-variant returns the
    /// same list its parent does.
    ///
    /// Cached per parent rather than recomputed: the pickers enumerate it on every body
    /// evaluation, and re-filtering all eighteen cases each time is pure waste — the same
    /// reasoning as `sidebarCases` above.
    var familyVariants: [SmartListType] { Self.familyVariantsByParent[sidebarParent]! }

    private static let familyVariantsByParent: [SmartListType: [SmartListType]] =
        sidebarCases.reduce(into: [:]) { result, parent in
            result[parent] = [parent] + allCases.filter { $0.sidebarParent == parent && $0 != parent }
        }

    /// The canonical set of all smart list names, lowercased, used for collision detection.
    /// Derived once from 'allCases' so it is always automatically in sync with the enum.
    /// Consumers should cache this value rather than recomputing it on every call.
    static let reservedNames: Set<String> = Set(allCases.map { $0.rawValue.lowercased() })

    /// Returns true if the supplied name (after lowercasing) matches any smart list name.
    static func isReservedName(_ name: String) -> Bool {
        reservedNames.contains(name.lowercased())
    }
}

// MARK: - Smart List Variant State

/// Tracks which sub-variant of a smart list family is currently displayed — the
/// selection behind the picker at the top of the gallery for "Up for Rotation",
/// "Purchased", "Unpurchased", "Alternate Versions", and "Filtered Library".
///
/// One instance exists per family, keyed by the family's parent SmartListType. Each
/// family previously had its own hand-written @Observable singleton (PurchasedFormatState,
/// RotationVariantState, …) *and* its own mirror enum (PurchasedFormat, RotationVariant,
/// SortingCategory, …) whose cases, raw strings, and ordering duplicated the family's
/// SmartListTypes exactly and had to be kept in step with them by hand, along with a
/// per-family `smartListType` mapping in each direction. The SmartListType is the
/// selection now, so the five families differ only in data — `parent` — and the five
/// call sites that had to name all five states one after another (GalleryView,
/// ShowInListNavigation, MenuBar, KeyboardManager, ViewIdentifier.from) each collapse
/// to a single call that cannot fall out of step with the others.
@MainActor
@Observable
final class SmartListVariantState {
    /// The parent smart list whose family this state tracks. Also the family's default
    /// selection, and the sidebar row that stays highlighted for every variant in it.
    let parent: SmartListType

    /// The variant currently displayed. Always a member of `parent`'s family.
    private(set) var selected: SmartListType

    private init(parent: SmartListType) {
        self.parent = parent
        self.selected = parent
    }

    /// The variants this state can select, in picker display order.
    var variants: [SmartListType] { parent.familyVariants }

    /// Selects a variant and navigates to it — the path taken by the gallery picker and
    /// by the Cmd+<digit> sub-tab shortcuts alike. A type outside this family is ignored.
    /// - Parameter immediate: Switch views in this turn; see SubcategoryNavigation.performSwitch.
    func select(_ type: SmartListType, immediate: Bool = false) {
        guard type.sidebarParent == parent, selected != type else { return }
        // `selected` updates synchronously so the picker label reflects the new choice
        // immediately; SubcategoryNavigation clears the selection, pins the sidebar
        // highlight to the parent item, and defers the view switch past the menu-dismissal
        // animation (see its doc comment for the full rationale). This applies to the
        // Filtered Library family too: despite the "sorting" name, its variants (Waiting
        // for Edit, Temporarily On Hold, …) are genuinely distinct film-status subsets,
        // not a reordering of one set.
        selected = type
        SubcategoryNavigation.performSwitch(
            parentSidebarItem: .smartList(parent),
            to: .smartList(type),
            immediate: immediate)
    }

    /// Resyncs the picker to a view that some other navigation path has already switched
    /// to. A type outside this family is ignored, which is what lets `syncAll` below hand
    /// the same type to every family unconditionally.
    func updateFromView(_ type: SmartListType) {
        guard type.sidebarParent == parent, selected != type else { return }
        selected = type
    }

    // MARK: - Family Registry

    private static let states: [SmartListType: SmartListVariantState] =
        Dictionary(uniqueKeysWithValues: SmartListType.sidebarCases.map {
            ($0, SmartListVariantState(parent: $0))
        })

    /// The state governing `type`'s family. Total: `sidebarParent` maps every
    /// SmartListType onto one of `sidebarCases`, which is exactly the registry's key set,
    /// and both are exhaustive switches the compiler keeps that way.
    static func shared(for type: SmartListType) -> SmartListVariantState {
        states[type.sidebarParent]!
    }

    /// Resyncs every family to `type`. Only the one family that owns `type` changes;
    /// the rest ignore it. Callers that have just navigated to some smart list use this
    /// rather than dispatching on the family, which is exactly as correct and has one
    /// fewer place to get out of step.
    static func syncAll(to type: SmartListType) {
        for state in states.values { state.updateFromView(type) }
    }
}

// MARK: - Smart Lists Manager
@MainActor
@Observable
final class SmartLists: Loggable {
    nonisolated static let logTag = "[SmartLists]"
    
    private let coordinator: DataCoordinator
    
    /// Every smart list's computed membership, keyed by type. A missing key and an empty
    /// set mean the same thing (see `ids(_:)`), so nothing has to seed all eighteen keys.
    ///
    /// This was eighteen separate `Set<UUID>` properties, which forced every operation over
    /// "all the lists" — the bulk apply, the clear, the deletion sweep, the public lookup —
    /// to spell all eighteen names out again in the same order, and made adding a smart list
    /// a six-file edit with nothing checking that any of the six lists were complete. Keying
    /// by `SmartListType` lets each of those become one loop over `allCases`, which is
    /// exhaustive by construction.
    private(set) var sets: [SmartListType: Set<UUID>] = [:]

    /// Reads one list's raw membership. Distinct from the public `filmIDs(for:)`, which
    /// additionally applies the rotation family's presentation-layer queue exclusion.
    private func ids(_ type: SmartListType) -> Set<UUID> { sets[type] ?? [] }

    /// The raw "Up for Rotation" membership. Named because the rotation baseline and
    /// auto-enqueue logic below refer to it constantly.
    private var upForRotation: Set<UUID> { ids(.upForRotation) }
    
    // Tracks whether calculateAllLists() has been called at least once this session.
    // Used by recalculateIfNeeded() to distinguish "never calculated" from "calculated
    // but all lists are genuinely empty" — the emptiness check alone cannot make that
    // distinction and would trigger repeated full recalculations for libraries where
    // no film qualifies for any smart list (no purchases, no watch history, etc.).
    private var hasCalculated: Bool = false

    // Cache for "Up for Rotation" to avoid recalculating multiple times per day
    private var lastRotationCalculationDate: Date?

    // Stored handle for the daily midnight rotation refresh Task.
    // Retained so it can be canceled when smart lists are cleared/disabled,
    // preventing an untracked chain from persisting past the feature's lifetime.
    private var rotationRefreshTask: Task<Void, Never>?
    
    // Combine cancellables for event subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    // Tracks the last-known value of excludeQueuedFromUpForRotation so the
    // preferencesChanged listener (which fires for ANY preference change) can detect
    // whether this specific preference actually changed, and avoid needlessly
    // re-broadcasting smartListsRecalculated for unrelated preference edits.
    private var lastKnownExcludeQueuedFromUpForRotation: Bool = Preferences.excludeQueuedFromUpForRotation

    // Tracks the last-known value of the master Smart Lists toggle so the preferencesChanged
    // listener can distinguish an actual on/off transition from the many unrelated preference
    // edits that also post that event.
    private var lastKnownSmartListsEnabled: Bool = Preferences.smartLists

    // MARK: - Full-Recalculation Race Protection
    //
    // calculateAllLists() snapshots the film array on @MainActor, computes every list on a
    // background thread, then wholesale-overwrites every set back on @MainActor. Any targeted
    // per-film recalculation that lands in that window operates on the live sets, but is then
    // silently discarded when the bulk result is applied — because that result was computed
    // from a film array captured *before* the edit.
    //
    // These two properties close that hole: while a full calculation is in flight, every film
    // touched by a targeted path is recorded here, and applySmartListSets replays those films
    // (or removes them, if they were deleted) immediately after applying the bulk result.
    private var isFullCalculationInFlight: Bool = false
    private var filmsTouchedDuringFullCalculation: Set<UUID> = []

    // MARK: - Rotation Baseline (auto-enqueue transition tracking)
    //
    // The membership of `upForRotation` as of the last evaluation, persisted across launches.
    // `nil` means no baseline has been established yet (first launch after this was added, or
    // after a database restore invalidated it).
    //
    // Auto-enqueue must fire only on a genuine transition — a film that was NOT up for
    // rotation and now is. Comparing against the in-memory `upForRotation` alone cannot
    // establish that, because that set starts empty every launch, which made the entire
    // rotation list look "new" and re-ran auto-enqueue over the whole library on every start.
    private var knownUpForRotation: Set<UUID>?

    // Debounce handle for the baseline's UserDefaults write. See setRotationBaseline.
    private var rotationBaselinePersistTask: Task<Void, Never>?

    /// The single point through which a wholesale replacement of `upForRotation` must go.
    /// Assigns the new membership, records the new baseline, and returns the films that
    /// genuinely transitioned into rotation since the last evaluation.
    ///
    /// The caller is responsible for passing the returned set to
    /// `coordinator.autoEnqueueFilmsNewlyUpForRotation`. That is deliberately left to the
    /// caller rather than done here: auto-enqueue mutates Film Queue lists, which posts list
    /// events and can drive a gallery reload, so it must not run while the surrounding smart
    /// list assignments are only half-applied.
    @discardableResult
    private func applyUpForRotationMembership(_ newSet: Set<UUID>) -> Set<UUID> {
        sets[.upForRotation] = newSet

        guard let baseline = knownUpForRotation else {
            // No baseline to compare against. Adopt silently — acting on a difference we
            // cannot verify risks enqueueing films the user already removed by hand, and
            // an unwanted queue mutation is far more costly than a deferred one. The next
            // genuine transition, evaluated against the baseline recorded here, is honored.
            Self.log("Rotation baseline not established — adopting \(newSet.count) film(s) without auto-enqueue")
            setRotationBaseline(newSet)
            return []
        }

        setRotationBaseline(newSet)

        let newlyUpForRotation = newSet.subtracting(baseline)
        if !newlyUpForRotation.isEmpty {
            Self.log("\(newlyUpForRotation.count) film(s) newly up for rotation since last evaluation")
        }
        return newlyUpForRotation
    }

    /// Records the rotation baseline in memory and schedules it to be persisted.
    ///
    /// The in-memory value is authoritative and updated synchronously; the UserDefaults write
    /// is coalesced. Persisting on every call would be wasteful in the paths that matter most:
    /// a bulk import posts one `.added` event per film, so a large import with watch history
    /// would rebuild and rewrite an ever-growing ID array once per qualifying film — quadratic
    /// work on the main actor for a value only ever read at launch.
    private func setRotationBaseline(_ newSet: Set<UUID>) {
        guard knownUpForRotation != newSet else { return }
        knownUpForRotation = newSet
        scheduleRotationBaselinePersist()
    }

    /// Debounces the UserDefaults write. Repeated changes within the window collapse into a
    /// single write of the final value.
    private func scheduleRotationBaselinePersist() {
        rotationBaselinePersistTask?.cancel()
        rotationBaselinePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushRotationBaseline()
        }
    }

    /// Writes the pending baseline immediately. Called by the debounce and directly at quit.
    ///
    /// Losing a pending write to an abrupt termination is benign: the only consequence is that
    /// a film which entered rotation just before quitting is absent from the baseline and
    /// therefore looks newly qualified next launch. That film was already enqueued at the
    /// moment it transitioned, so the "already in the Film Queue" guard in
    /// `autoEnqueueFilmsNewlyUpForRotation` prevents any duplicate or relocating add.
    func flushRotationBaseline() {
        rotationBaselinePersistTask?.cancel()
        rotationBaselinePersistTask = nil
        guard let baseline = knownUpForRotation else { return }
        Preferences.knownUpForRotationFilmIDs = baseline
    }

    /// Incrementally adjusts the baseline for a single-film transition or a deletion.
    ///
    /// Deliberately a no-op while the baseline is unestablished: materializing a baseline
    /// from one film would make every OTHER rotation-eligible film look newly qualified to
    /// the next full calculation, producing exactly the library-wide auto-enqueue this
    /// mechanism exists to prevent. Only a full calculation may establish a baseline.
    private func updateRotationBaseline(inserting: Set<UUID> = [], removing: Set<UUID> = []) {
        guard var baseline = knownUpForRotation else { return }
        baseline.formUnion(inserting)
        baseline.subtract(removing)
        setRotationBaseline(baseline)
    }

    init(coordinator: DataCoordinator) {
        self.coordinator = coordinator
        self.knownUpForRotation = Preferences.knownUpForRotationFilmIDs
        setupEventListeners()
        
        // STARTUP: Don't calculate lists eagerly in init().
        // DataCoordinator.initializeMemoryStore() calls recalculateIfNeeded()
        // as a deferred background task after the UI is responsive. This avoids
        // the previous pattern where SmartLists.init() calculated every list
        // immediately (even before films were loaded), and then DataCoordinator
        // triggered a second full calculation via recalculateIfNeeded() - doubling
        // the work and blocking the main thread during startup.
        if Preferences.smartLists {
            Self.log("Smart Lists enabled - calculation deferred until after UI ready")
        } else {
            Self.log("Smart Lists disabled - skipping calculation")
        }
    }
    
    // MARK: - Event Listening
    
    private func setupEventListeners() {
        // Listen for film updates
        AppEventBus.shared.filmEvents
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .updated(let filmID):
                    self.handleFilmUpdate(filmID)
                case .added(let filmID):
                    // Recalculate smart list membership for the newly added film.
                    // Without this, films added via FilmSheet or single-film import
                    // show no smart list memberships until a subsequent edit fires .updated.
                    self.handleFilmAdded(filmID)
                case .deleted(let filmIDs):
                    self.handleFilmsDeletion(filmIDs)
                case .releaseChanged(let filmID):
                    self.handleReleaseChange(filmID)
                }
            }
            .store(in: &cancellables)

        // Listen for preference changes so that enabling smart lists mid-session
        // triggers an immediate full recalculation. Without this, all lists remain
        // empty after the user toggles the feature on — films only trickle in as
        // subsequent .updated or .added events fire for individual films.
        AppEventBus.shared.viewEvents
            .sink { [weak self] event in
                guard case .preferencesChanged = event else { return }
                guard let self = self else { return }

                // Detect an actual transition of the master Smart Lists toggle.
                // preferencesChanged fires for every preference edit, so compare against
                // the last-known value rather than acting on every notification.
                let smartListsEnabled = Preferences.smartLists
                if smartListsEnabled != self.lastKnownSmartListsEnabled {
                    self.lastKnownSmartListsEnabled = smartListsEnabled
                    if smartListsEnabled {
                        // Re-enabled. A full recalculation is mandatory, not optional: while
                        // the feature was off, handleFilmUpdate/handleFilmAdded/handleFilmsDeletion
                        // all returned early, so every film change made in that period was
                        // dropped. Going through clearAllLists() first resets hasCalculated
                        // and invalidates any stale in-flight result, so calculateAllLists()
                        // rebuilds from the current library rather than trusting sets that
                        // silently stopped tracking edits.
                        Self.log("Smart Lists re-enabled — clearing stale sets and recalculating")
                        self.clearAllLists()
                        self.calculateAllLists()
                    } else {
                        // Disabled. Empty the sets and cancel the midnight timer so nothing
                        // keeps running or serving membership data behind a hidden feature.
                        Self.log("Smart Lists disabled — clearing all lists")
                        self.clearAllLists()
                    }
                } else if smartListsEnabled && !self.hasCalculated {
                    // Safety net for the case where the feature is on and enabled but the
                    // initial deferred calculation never ran.
                    Self.log("Smart Lists enabled but not yet calculated — triggering full recalculation")
                    self.calculateAllLists()
                }
                // excludeQueuedFromUpForRotation is a pure presentation-layer filter applied
                // on read (see filmIDs(for:)) — the underlying rotation sets themselves
                // never change, so toggling the preference does not go through
                // calculateAllLists(). Instead, re-broadcast smartListsRecalculated so any
                // gallery currently viewing "Up for Rotation" or "Viewed Over One Year Ago"
                // re-reads filmIDs(for:) and reflects the new filter state immediately.
                // Only do this when the preference actually changed, since
                // preferencesChanged fires for every preference edit and most are
                // irrelevant to this filter.
                let currentValue = Preferences.excludeQueuedFromUpForRotation
                if currentValue != self.lastKnownExcludeQueuedFromUpForRotation {
                    self.lastKnownExcludeQueuedFromUpForRotation = currentValue
                    Self.log("excludeQueuedFromUpForRotation changed to \(currentValue) — refreshing rotation-family display filters")
                    AppEventBus.shared.smartListsRecalculated()
                }
            }
            .store(in: &cancellables)

        // Listen for Film Queue membership changes (adding/removing films to/from the
        // three internal Queue lists) so an open "Up for Rotation" or "Viewed Over One
        // Year Ago" gallery immediately reflects films entering or leaving the
        // excludeQueuedFromUpForRotation filter, without waiting for an unrelated film
        // event or the midnight rotation refresh.
        AppEventBus.shared.listEvents
            .compactMap { event -> UUID? in
                guard case .membershipChanged(let listID) = event else { return nil }
                return listID
            }
            .sink { listID in
                guard Preferences.excludeQueuedFromUpForRotation,
                      FilmQueue.isInternalList(listID) else { return }
                Self.log("Film Queue membership changed — refreshing rotation-family display filters")
                AppEventBus.shared.smartListsRecalculated()
            }
            .store(in: &cancellables)
        
        // Check rotation status at midnight each day
        scheduleRotationRefresh()
    }
    
    private func handleFilmAdded(_ filmID: UUID) {
        guard Preferences.smartLists else { return }
        
        Self.log("Film added: \(filmID) - evaluating smart list membership")
        recalculateForFilm(filmID)
    }
    
    private func handleFilmUpdate(_ filmID: UUID) {
        guard Preferences.smartLists else { return }
        
        Self.log("Film updated: \(filmID) - recalculating affected lists")
        recalculateForFilm(filmID)
    }
    
    private func handleReleaseChange(_ filmID: UUID) {
        guard Preferences.smartLists else { return }
        
        Self.log("Film releases changed: \(filmID) - recalculating release-based lists")
        recalculateReleaseBasedListsForFilm(filmID)
    }
    
    private func handleFilmsDeletion(_ filmIDs: Set<UUID>) {
        guard Preferences.smartLists else { return }
        
        Self.log("Films deleted: \(filmIDs.count) - removing from smart lists")
        removeFilmsFromLists(filmIDs)
    }
    
    // MARK: - Daily Rotation Refresh
    
    private func scheduleRotationRefresh() {
        // Cancel any previously scheduled task before creating a new one.
        // Prevents a stale chain from persisting if this is called more than once
        // (e.g., after a forceFullRecalculation mid-day) or after clearAllLists().
        rotationRefreshTask?.cancel()

        // Calculate time until next midnight.
        let calendar = Calendar.current
        let now = Date()
        
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return
        }
        
        let timeInterval = midnight.timeIntervalSince(now)
        
        // Guard against negative or zero intervals (e.g., clock skew).
        guard timeInterval > 0 else {
            Self.log("WARNING: Non-positive rotation refresh interval (\(timeInterval)s) — skipping schedule")
            return
        }

        // Use Duration-based sleep to avoid manual UInt64 nanosecond arithmetic,
        // which is less readable and requires its own overflow guard.
        let duration = Duration.seconds(timeInterval)

        rotationRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Preferences.smartLists {
                    Self.log("Daily rotation refresh triggered")
                    self.calculateUpForRotation()
                }
                // Schedule next refresh.
                self.scheduleRotationRefresh()
            }
        }
    }
    
    // MARK: - Full Recalculation

    /// Monotonically-increasing generation counter used to discard stale task results.
    /// Incremented each time a new full-recalculation task is launched. When the task
    /// completes and attempts to apply its results, it first verifies that the counter
    /// still matches the value captured at launch; if not, a newer task has superseded it
    /// and the stale result is silently dropped. Wrapping addition (&+=) prevents overflow
    /// for sessions that trigger an extreme number of recalculations.
    private var calculationGeneration: Int = 0

    func calculateAllLists() {
        guard Preferences.smartLists else {
            clearAllLists()
            return
        }
        
        // Clear the rotation sentinel so the midnight scheduler is not blocked
        // if a full recalculation runs mid-day (e.g. after a database restore).
        // forceFullRecalculation() already does this explicitly; clearing it here
        // ensures calculateAllLists() is always safe to call from any path.
        lastRotationCalculationDate = nil

        // If smart lists were previously disabled, clearAllLists() will have canceled
        // the rotation refresh task. Re-arm it now so the daily refresh resumes.
        if rotationRefreshTask == nil || rotationRefreshTask!.isCancelled {
            scheduleRotationRefresh()
        }

        // Fetch the full film list once on MainActor (required — coordinator is @MainActor).
        let allFilms = coordinator.getAllFilms()

        // Mark as calculated eagerly so that recalculateIfNeeded() does not fire
        // a second task before this one completes.
        hasCalculated = true

        // Advance the generation counter so any in-flight task from a previous call
        // knows its result is stale and should not be applied.
        calculationGeneration &+= 1
        let capturedGeneration = calculationGeneration
        let today = Calendar.current.startOfDay(for: Date())

        // Open the race-protection window. Any targeted recalculation that arrives before the
        // background result is applied will record its film ID so it can be replayed after.
        // Reset the accumulator here rather than on completion so a superseding call starts
        // clean while still capturing edits made during its own window.
        isFullCalculationInFlight = true
        filmsTouchedDuringFullCalculation.removeAll()

        Self.log("Calculating all smart lists (\(allFilms.count) films) [generation \(capturedGeneration)]")

        // Dispatch the O(N × predicates) computation to a utility-priority background
        // thread. All inputs ([FilmSnapshot], Date) are Sendable. The returned
        // SmartListSets struct contains only Set<UUID> values, which are also Sendable.
        // Results are applied back on @MainActor via a weak-self capture so that a
        // deallocated SmartLists instance is silently ignored.
        Task.detached(priority: .utility) { [weak self] in
            let sets = SmartLists.computeSmartListSets(allFilms, today: today)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop results produced by an older call that was superseded by a
                // newer calculateAllLists() invocation.
                guard self.calculationGeneration == capturedGeneration else {
                    Self.log("Discarding stale smart list result [generation \(capturedGeneration), current \(self.calculationGeneration)]")
                    return
                }
                self.applySmartListSets(sets, today: today)
                Self.log("All smart lists calculated [generation \(capturedGeneration)]")
            }
        }
    }
    
    /// Public method to trigger recalculation after initial data load
    func recalculateIfNeeded() {
        guard Preferences.smartLists else { return }
        guard !hasCalculated else { return }

        Self.log("Films loaded and smart lists not yet calculated — calculating now")
        calculateAllLists()
    }
    
    /// Forces a full recalculation of all smart lists, bypassing the daily rotation cache.
    ///
    /// Used after bulk mutations that affect rotation threshold values (e.g. resetting all
    /// per-film overrides), where the "Up for Rotation" membership may change on the same
    /// calendar day the daily sentinel was already set.
    func forceFullRecalculation() {
        guard Preferences.smartLists else { return }
        Self.log("forceFullRecalculation: recalculating all lists")
        calculateAllLists()
    }
    
    private func clearAllLists() {
        // Cancel the pending midnight rotation refresh — the chain must not fire
        // while all lists are cleared (e.g., when smart lists are disabled).
        rotationRefreshTask?.cancel()
        rotationRefreshTask = nil

        // Invalidate any full calculation still in flight. Without this, a background
        // computation launched before the clear would pass its generation check on
        // completion and re-populate every list that was just emptied.
        calculationGeneration &+= 1
        isFullCalculationInFlight = false
        filmsTouchedDuringFullCalculation.removeAll()
        lastRotationCalculationDate = nil

        sets.removeAll()
        hasCalculated = false
    }
    
    // MARK: - Individual List Calculations

    /// No-arg wrapper for the daily rotation scheduler.
    /// Fetches its own film list since it runs independently of calculateAllLists.
    /// Refreshes both rotation-group lists in a single pass.
    private func calculateUpForRotation() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let lastCalc = lastRotationCalculationDate,
           calendar.isDate(lastCalc, inSameDayAs: today) {
            Self.log("Rotation already calculated today - skipping")
            return
        }
        let allFilms = coordinator.getAllFilms()
        var rotationIDs: Set<UUID> = []
        var oneYearIDs: Set<UUID> = []
        for film in allFilms {
            let member = Self.membership(of: film, today: today)
            if member.contains(.upForRotation) { rotationIDs.insert(film.id) }
            if member.contains(.viewedOverOneYearAgo) { oneYearIDs.insert(film.id) }
        }
        // Applied through the choke point so the daily refresh honors the same
        // cross-launch baseline every other rotation path uses.
        let newlyUpForRotation = applyUpForRotationMembership(rotationIDs)
        sets[.viewedOverOneYearAgo] = oneYearIDs
        lastRotationCalculationDate = today
        Self.log("Up for Rotation: \(rotationIDs.count) films | Viewed Over One Year Ago: \(oneYearIDs.count) films")

        // Enqueued after both rotation sets are assigned, for the same reason as in
        // applySmartListSets: auto-enqueue can drive a gallery reload.
        if !newlyUpForRotation.isEmpty {
            coordinator.autoEnqueueFilmsNewlyUpForRotation(newlyUpForRotation)
        }

        // This recalculation runs on its own midnight timer, independent of any specific
        // film event. Without this notification, a gallery already open on "Up for Rotation"
        // or "Viewed Over One Year Ago" at the moment the clock passes midnight would keep
        // showing yesterday's membership until some unrelated film event (or a manual
        // navigation away and back) happened to trigger a reload.
        AppEventBus.shared.smartListsRecalculated()
    }
    
    // MARK: - Membership Computation

    /// Every smart list `film` belongs to as of `today` — the single definition of what
    /// each smart list means.
    ///
    /// `nonisolated static` so the full recalculation can call it from a background Task
    /// without hopping to @MainActor; it reads only the Sendable value types it is handed
    /// and touches no actor-isolated state.
    ///
    /// Both the bulk path (`computeSmartListSets`) and the targeted per-film path
    /// (`applyMembership`) go through here. They previously carried a complete second copy
    /// of every predicate — a `nonisolated static _isUpForRotation` beside a @MainActor
    /// `isUpForRotation`, and so on for all seven rules — which the comments on them
    /// correctly described as having to stay "byte-for-byte equivalent", because a film's
    /// membership otherwise flips depending on which path last evaluated it. One
    /// definition removes the obligation rather than restating it.
    ///
    /// `parseDate(from:)` (GlobalUtilities.swift) is a nonisolated global reading
    /// file-scope `DateFormatter`s that are configured once at initialization and never
    /// mutated; `DateFormatter` is Sendable in the macOS 15 SDK and documented as safe for
    /// concurrent reads, so calling it from the background path is safe.
    /// `rotationEligibilityDate` is likewise a nonisolated global over value types.
    ///
    /// Internal rather than private so the debug harness can select films by the real rule
    /// (`sort-purchase-format`) instead of restating it.
    nonisolated static func membership(
        of film: FilmSnapshot,
        today: Date
    ) -> Set<SmartListType> {
        var types: Set<SmartListType> = []

        // --- Rotation ---
        // Parsed once and shared by both rotation checks. A film with no watch date is
        // simply not in either list; a non-empty date that will not parse is a data
        // problem worth reporting.
        let lastWatchedDate = parseDate(from: film.lastWatched)
        if lastWatchedDate == nil && !film.lastWatched.isEmpty {
            log("WARNING: Could not parse lastWatched date '\(film.lastWatched)' for film '\(film.name)'")
        }
        // Films carrying any specialSorting parameter are excluded from both rotation
        // lists. Thresholds are rounded up to the 1st of the following month by the shared
        // helper, so membership turns over on exactly the date the sidebar's "Next Up for
        // Rotation" field names and counts down to. "Viewed Over One Year Ago" is expressed
        // as 12 months through that same helper rather than as a raw anniversary so the two
        // sibling lists round identically and a film on the default 12-month threshold
        // enters both on the same day.
        if film.specialSorting.isEmpty, let lastWatchedDate {
            if let threshold = rotationEligibilityDate(from: lastWatchedDate, months: film.rotationThreshold),
               threshold <= today {
                types.insert(.upForRotation)
            }
            if let oneYearLater = rotationEligibilityDate(from: lastWatchedDate, months: 12),
               oneYearLater <= today {
                types.insert(.viewedOverOneYearAgo)
            }
        }

        // --- Purchases ---
        // "Purchased X" means at least one purchased release of that format.
        if film.releases.contains(where: { $0.purchased }) { types.insert(.purchased) }
        for (format, type) in Self.purchasedFormatLists
        where film.releases.contains(where: { $0.format == format && $0.purchased }) {
            types.insert(type)
        }

        // --- Unpurchased ---
        // "Unpurchased X" means at least one release of that format and none of them
        // purchased — a film with no releases at all qualifies for none of these.
        if !film.releases.isEmpty, film.releases.allSatisfy({ !$0.purchased }) {
            types.insert(.unpurchased)
        }
        for (format, type) in Self.unpurchasedFormatLists {
            let formatReleases = film.releases.filter { $0.format == format }
            if !formatReleases.isEmpty, formatReleases.allSatisfy({ !$0.purchased }) {
                types.insert(type)
            }
        }

        // --- Metadata ---
        if film.edited { types.insert(.edited) }
        if Self.hasAlternateVersions(film) { types.insert(.alternateVersions) }

        // --- Special Sorting ---
        // specialSorting is an array, so a film can carry more than one tag at once (e.g.
        // "Waiting for edit" + "Temporarily on hold"). Each list is therefore an
        // independent membership test rather than an arm of a single-value switch.
        // "Filtered Library" is the complement: watched, and carrying no tag at all — so it
        // is mutually exclusive with the five tag lists by construction, not by ordering.
        if film.watched && film.specialSorting.isEmpty {
            types.insert(.filteredLibrary)
        } else {
            for (tag, type) in Self.specialSortingLists where film.specialSorting.contains(tag) {
                types.insert(type)
            }
        }

        return types
    }

    /// Release format → the "Purchased <format>" list it populates. Derived from
    /// `purchaseFormat` so membership and the Date Purchased sort's scope share one pairing.
    nonisolated private static let purchasedFormatLists: [(String, SmartListType)] =
        SmartListType.allCases.compactMap { type in type.purchaseFormat.map { ($0.rawValue, type) } }

    /// Release format → the "Unpurchased <format>" list it populates.
    nonisolated private static let unpurchasedFormatLists: [(String, SmartListType)] = [
        (ReleaseFormat.uhd4K.rawValue,  .unpurchased4K),
        (ReleaseFormat.bluRay.rawValue, .unpurchasedBluray),
        (ReleaseFormat.dvd.rawValue,    .unpurchasedDVD),
    ]

    /// Special-sorting tag → the smart list it populates.
    nonisolated private static let specialSortingLists: [(String, SmartListType)] = [
        (FilmSpecialSorting.waitingForEdit,     .waitingForEdit),
        (FilmSpecialSorting.temporarilyOnHold,  .temporarilyOnHold),
        (FilmSpecialSorting.indefinitelyOnHold, .indefinitelyOnHold),
        (FilmSpecialSorting.ignore,             .ignore),
        (FilmSpecialSorting.blacklisted,        .blacklisted),
    ]

    /// True if any purchased release carries an included version beyond a lone "Theatrical"
    /// — either a non-Theatrical version, or Theatrical alongside others. An empty version
    /// list does not count.
    ///
    /// Not private: the Reports tab's alternate-versions count (DVLibraryInsights) reads
    /// this same rule, so the count and the "Alternate Versions" smart list cannot disagree.
    nonisolated static func hasAlternateVersions(_ film: FilmSnapshot) -> Bool {
        for release in film.releases where release.purchased {
            let versions = release.includedVersions
            guard !versions.isEmpty else { continue }
            if versions == [ViewingVersion.theatrical.displayName] { continue }
            return true
        }
        return false
    }

    // MARK: - Full-Recalculation Stages

    /// Builds every smart list's membership in a single pass over `allFilms`. Called
    /// exclusively by `calculateAllLists()`.
    ///
    /// Previously ran synchronously on @MainActor (~200ms for 1,300 films × 18 predicates).
    /// Now split into this pure computation stage — `nonisolated`, safe to call from a
    /// background thread, taking and returning only Sendable values — and the @MainActor
    /// application stage `applySmartListSets` below.
    nonisolated private static func computeSmartListSets(
        _ allFilms: [FilmSnapshot],
        today: Date
    ) -> [SmartListType: Set<UUID>] {
        var sets: [SmartListType: Set<UUID>] = [:]
        for film in allFilms {
            for type in membership(of: film, today: today) {
                sets[type, default: []].insert(film.id)
            }
        }
        return sets
    }

    /// Applies a pre-computed result to the @MainActor-isolated `sets`, then reconciles
    /// anything that changed while it was being computed.
    /// Also stamps `lastRotationCalculationDate` so the daily scheduler guard is set correctly.
    private func applySmartListSets(_ newSets: [SmartListType: Set<UUID>], today: Date) {
        // Rotation membership is applied through applyUpForRotationMembership, which compares
        // against the persisted cross-launch baseline to decide what is genuinely newly up
        // for rotation. The resulting delta is enqueued further below, after every other set
        // has been assigned.
        let newlyUpForRotation = applyUpForRotationMembership(newSets[.upForRotation] ?? [])

        // Assigned rather than merged, and over allCases rather than over newSets' keys, so
        // that a list nothing qualified for this pass is emptied rather than left holding
        // its previous membership.
        for type in SmartListType.allCases where type != .upForRotation {
            sets[type] = newSets[type] ?? []
        }
        lastRotationCalculationDate = today

        // Close the race-protection window BEFORE replaying, so the replayed targeted
        // recalculations below do not re-record themselves into the accumulator.
        let touchedFilmIDs = filmsTouchedDuringFullCalculation
        isFullCalculationInFlight = false
        filmsTouchedDuringFullCalculation.removeAll()

        // Replay every film that was added, updated, or deleted while the background
        // computation was running. The bulk result above was computed from a film array
        // captured before those changes, so without this replay each of those films would
        // silently revert to its pre-edit membership (and deleted films would linger as
        // phantom IDs) until the next time that specific film happened to change again.
        if !touchedFilmIDs.isEmpty {
            Self.log("Replaying \(touchedFilmIDs.count) film(s) changed during full recalculation")
            var vanishedFilmIDs: Set<UUID> = []
            for filmID in touchedFilmIDs {
                if coordinator.getFilm(filmID) == nil {
                    vanishedFilmIDs.insert(filmID)
                } else {
                    recalculateForFilm(filmID)
                }
            }
            if !vanishedFilmIDs.isEmpty {
                removeFilmsFromLists(vanishedFilmIDs)
            }
        }

        // Every set is now assigned and the replay has reconciled anything that changed
        // mid-flight, so the smart list state is fully consistent. Only now is it safe to
        // mutate Film Queue membership, which posts list events and can drive a reload.
        //
        // Re-intersected with the live set on purpose. `newlyUpForRotation` was computed from
        // the background result, which predates the replay above. If the user marked one of
        // those films watched while the calculation was running, the replay has just removed
        // it from rotation — enqueueing it now would add a film the user had, moments earlier,
        // told the app they had just watched. Only films that are still up for rotation after
        // reconciliation are eligible.
        let enqueueCandidates = newlyUpForRotation.intersection(upForRotation)
        if !enqueueCandidates.isEmpty {
            coordinator.autoEnqueueFilmsNewlyUpForRotation(enqueueCandidates)
        }

        // A full recalculation replaces the membership of every smart list, not just the
        // rotation pair. Any gallery currently displaying a smart list is holding film IDs
        // that were resolved before this ran, so it must be told to re-read them — otherwise
        // the view stays stale until the user navigates away and back. This matters most on
        // the paths that trigger a full recalculation while a smart list is already on screen:
        // startup's deferred calculation, enabling the feature mid-session, a database
        // restore/import, and forceFullRecalculation() after bulk threshold resets.
        AppEventBus.shared.smartListsRecalculated()
    }

    // MARK: - Targeted Recalculation

    /// Every smart list — the scope a general film change reconsiders. A stored constant
    /// so the common per-film update path does not build the set on each call.
    private static let allLists: Set<SmartListType> = Set(SmartListType.allCases)

    /// The smart lists whose membership is determined solely by a film's releases — the
    /// scope a `.releaseChanged` event needs to reconsider. Derived from the two
    /// purchase-format families plus "Alternate Versions" rather than listed by hand.
    private static let releaseBasedLists: Set<SmartListType> =
        Set(SmartListType.allCases.filter {
            $0.isPurchasedFormat || $0.isUnpurchasedFormat || $0 == .alternateVersions
        })

    /// Re-evaluates every smart list for one film.
    private func recalculateForFilm(_ filmID: UUID) {
        // If a full recalculation is mid-flight, its result was computed from a film array
        // captured before this change and will overwrite the mutations below. Record the film
        // so applySmartListSets can replay it once the bulk result has been applied.
        if isFullCalculationInFlight {
            filmsTouchedDuringFullCalculation.insert(filmID)
        }

        guard let film = coordinator.getFilm(filmID) else { return }
        applyMembership(of: film, scope: Self.allLists)
    }

    /// Re-evaluates only the release-derived smart lists for one film — the response to a
    /// `.releaseChanged` event, which cannot affect any other list.
    private func recalculateReleaseBasedListsForFilm(_ filmID: UUID) {
        // Same rationale as recalculateForFilm. Recorded here as well because .releaseChanged
        // events reach this method directly, without passing through recalculateForFilm.
        if isFullCalculationInFlight {
            filmsTouchedDuringFullCalculation.insert(filmID)
        }

        guard let film = coordinator.getFilm(filmID) else { return }
        applyMembership(of: film, scope: Self.releaseBasedLists)
    }

    /// Brings `sets` into agreement with `film`'s current membership, for the lists in
    /// `scope`. Lists outside `scope` are left untouched.
    ///
    /// This replaces eighteen hand-written "was it in? should it be in? insert or remove"
    /// blocks spread over three methods, each of which restated one predicate that
    /// `membership(of:today:)` already owns.
    ///
    /// Iterates `allCases` rather than `scope` so the visiting order is the enum's
    /// declaration order, which puts "Up for Rotation" — the only list whose changes have
    /// side effects outside `sets` — first, exactly as before.
    private func applyMembership(of film: FilmSnapshot, scope: Set<SmartListType>) {
        let filmID = film.id
        let today = Calendar.current.startOfDay(for: Date())
        let member = Self.membership(of: film, today: today)

        for type in SmartListType.allCases where scope.contains(type) {
            let shouldBeIn = member.contains(type)
            guard ids(type).contains(filmID) != shouldBeIn else { continue }

            if shouldBeIn {
                sets[type, default: []].insert(filmID)
            } else {
                sets[type]?.remove(filmID)
            }

            guard type == .upForRotation else { continue }
            if shouldBeIn {
                // Auto-enqueue only if this film was not already up for rotation as of the
                // last evaluation. `knownUpForRotation` may be nil (baseline unestablished),
                // in which case the optional comparison below is false and nothing is
                // enqueued — consistent with applyUpForRotationMembership's policy of never
                // acting on a difference it cannot verify.
                if knownUpForRotation?.contains(filmID) == false {
                    coordinator.autoEnqueueFilmsNewlyUpForRotation([filmID])
                }
                updateRotationBaseline(inserting: [filmID])
            } else {
                // Drop it from the baseline too, so that if the film later re-qualifies
                // that genuinely counts as a new rotation cycle and is honored.
                updateRotationBaseline(removing: [filmID])
            }
        }
    }

    private func removeFilmsFromLists(_ filmIDs: Set<UUID>) {
        // Deletions are the most damaging case to lose to an in-flight full calculation: the
        // bulk result still contains these films (they existed when its input array was
        // captured), so re-applying it would resurrect them as phantom IDs that no longer
        // resolve to any film. Record them so applySmartListSets strips them again.
        if isFullCalculationInFlight {
            filmsTouchedDuringFullCalculation.formUnion(filmIDs)
        }

        // Deleted films must also leave the rotation baseline, otherwise their IDs persist
        // in UserDefaults indefinitely as phantom entries.
        updateRotationBaseline(removing: filmIDs)

        for type in SmartListType.allCases {
            sets[type]?.subtract(filmIDs)
        }
    }

    // MARK: - Public Access

    /// The films in `type`, as displayed.
    ///
    /// For the two rotation lists this applies the presentation-layer exclusion of films
    /// already in the Film Queue when `Preferences.excludeQueuedFromUpForRotation` is on.
    /// The exclusion is applied on read only: the stored sets are untouched, so an excluded
    /// film still fully qualifies as up for rotation for auto-enqueue purposes and is
    /// merely hidden from these two lists' presentation. Toggling the preference therefore
    /// changes nothing that needs recalculating — which is why the listener in
    /// `setupEventListeners` re-broadcasts rather than recalculating.
    func filmIDs(for type: SmartListType) -> Set<UUID> {
        let stored = ids(type)
        guard type.isRotationVariant, Preferences.excludeQueuedFromUpForRotation else {
            return stored
        }
        return stored.subtracting(coordinator.getFilmQueueFilmIDs())
    }
}
