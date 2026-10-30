// MARK: - SortFilterMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Sort/filter menus that use ViewStateManager as the single source of truth.
//
// This file is the single "master" definition of what the Sort and Filter menus
// contain, and of what they must know about the view on screen to draw themselves.
//
// Two hosts present each menu: GalleryTitleBar's GallerySortMenu/GalleryFilterMenu
// (embedded directly in the live SwiftUI view hierarchy) and MenuBar's SortByMenu/
// FilterItemsMenu (bridged into the macOS menu bar via the Commands API). Three things
// live here so neither pair can diverge:
//
//   • WHAT THE MENUS CONTAIN — which toggles exist, how they're labeled, and which
//     blocks disable together — in SortMenuContent/FilterMenuContent. Each host supplies
//     only its own current value and a closure describing how to persist a change.
//   • WHAT THE MENUS NEED TO KNOW about the active view, in SortMenuInputs/
//     FilterMenuInputs: one derivation from (activeView, activeState, coordinator)
//     rather than one per host.
//   • The mutually-exclusive-group semantics, in FilterToggleLogic.
//
// What stays per-host is only how each obtains and refreshes those inputs. SortByMenu
// must mirror them into local @State and resync manually, because NSMenu-backed Commands
// items don't participate in SwiftUI's observation system. GalleryFilterMenu reads them
// live. GallerySortMenu also mirrors them, for a different reason spelled out at its own
// declaration: its inputs include a scan of the film set, and `Menu`'s content is
// materialized eagerly on every body evaluation.

import SwiftUI
import AppKit

// MARK: - Filter Menu Blocks

/// Discrete, independently-disable-able groups of related Filter menu items. Each
/// block is disabled as a whole — for example, disabling `.watched` disables both
/// the "Watched" and "Unwatched" toggles together, without affecting any other block
/// (e.g. `.color`).
enum FilterBlock: Sendable {
    case watched
    case color
    case purchase
    case dataComplete
    case genre
}

// MARK: - Sort Menu Inputs

/// Everything a Sort menu host must know about the view currently on screen, resolved in
/// one pass from the one place that knows it.
///
/// Both hosts — GallerySortMenu (the gallery toolbar) and SortByMenu (the macOS menu bar)
/// — need the identical seven values, all derived from the same three sources: the active
/// ViewIdentifier, the active ViewState, and the DataCoordinator. They used to derive them
/// separately, one as computed properties and the other as seven hand-refreshed `@State`
/// mirrors, which is what made SortByMenu's resync order load-bearing (`jumpTargets` is
/// gated on `showSectionDividers`, so the two had to be refreshed in the right order or
/// the submenu described the previous view for a pass). Resolved together here, that
/// ordering is structural rather than remembered, and there is one derivation for the two
/// hosts to agree on rather than two that happen to agree.
///
/// A plain value type, so the menu-bar host can mirror the whole thing in a single
/// `@State` — NSMenu-backed Commands items don't participate in SwiftUI's observation
/// system, so they must be pushed a value rather than reading one.
struct SortMenuInputs: Hashable, Sendable {
    /// The option the menu checks, or nil for none — see `displayedSortOption`.
    var sortOption: SortOption? = .title
    var sortDirection: SortDirection = .ascending

    /// Individual sort options that should be disabled (but still visible) for this view.
    /// No option is ever hidden: disabling keeps the menu's shape constant across views, so
    /// an option the user saw elsewhere is still there, dimmed, rather than gone without
    /// explanation. The rules live in `disabledSortOptions(smartListType:unwatchedCategory:
    /// filterOptions:)` below.
    var disabledSortOptions: Set<SortOption> = []

    var showSectionDividers: Bool = false
    /// Whether the Show/Hide pair is fixed for this view rather than the user's to set.
    /// See ViewStateKey.lockedSectionDividers for the rule and its one subject.
    var sectionDividersLocked: Bool = false

    /// The section bands the gallery is currently drawing, in display order.
    var jumpTargets: [GallerySectionJumpTarget] = []

    /// Resolves every value above for the view on screen right now.
    ///
    /// `jumpTargets` comes from the same GallerySectioning.jumpTargets call the galleries'
    /// own bands come from, so no host can offer a band the gallery is not drawing. It is
    /// also the one expensive member — a scan of the loaded film set — which is why hosts
    /// mirror this struct rather than rebuilding it on every body evaluation.
    @MainActor
    static func current(coordinator: DataCoordinator) -> SortMenuInputs {
        let manager = ViewStateManager.shared
        let activeView = manager.activeView
        let state = manager.activeState

        return SortMenuInputs(
            sortOption: displayedSortOption(state.effectiveSortOption(in: activeView),
                                            recentsCategory: activeView.recentsCategory,
                                            smartListType: activeView.smartListType),
            sortDirection: state.sortDirection,
            disabledSortOptions: disabledSortOptions(
                smartListType: activeView.smartListType,
                unwatchedCategory: activeView.unwatchedCategory,
                filterOptions: state.filterOptions),
            showSectionDividers: state.showSectionDividers,
            sectionDividersLocked: manager.sectionDividersLocked,
            jumpTargets: GallerySectioning.jumpTargets(
                coordinator: coordinator,
                showSortingSections: state.showSectionDividers))
    }

    /// Whether the sort options and direction pair are locked (SortMenuContent's
    /// `isDisabled`) for the active view: a fixed-sort view (every Recents tab, "Upcoming
    /// Releases"), or an empty library. Never the Section Dividers pair or "Jump to
    /// Section", and never the menu itself — see SortMenuContent.
    ///
    /// Shared by GallerySortMenu's host and the MenuBar's SortByMenu so the two menus lock
    /// the same items. SortMenuContent being shared kept the items identical, but each host
    /// used to derive this flag (and its own outer `.disabled`) separately, which is where
    /// the two drifted apart.
    @MainActor
    static func optionsLocked(coordinator: DataCoordinator) -> Bool {
        ViewStateManager.shared.activeView.hasFixedSort || coordinator.totalFilmCount == 0
    }

    /// The option the menu checks for a view whose stored sort is `stored`.
    ///
    /// Nil — no checkmark — on Recently Come Up for Rotation, the one view whose ordering
    /// no option describes: it is ordered by rotation eligibility date, and its stored
    /// `.dateAdded` is a placeholder (see RecentsCategory.sortOption). Checking "Date Added"
    /// there, as the menu used to, stated an ordering the view does not have.
    ///
    /// Nil on "Upcoming Releases" for the same reason: it is ordered by each film's soonest
    /// upcoming release, and its stored `.title` is a placeholder.
    static func displayedSortOption(_ stored: SortOption,
                                    recentsCategory: RecentsCategory?,
                                    smartListType: SmartListType? = nil) -> SortOption? {
        recentsCategory == .recentlyRotated || smartListType == .upcomingReleases ? nil : stored
    }

    /// The sort options that are meaningless in a view, and so render visible-but-locked
    /// there.
    ///
    /// "Date Last Purchased" is meaningful in any view that can hold a purchased film — an
    /// unpurchased film simply sorts ahead of the purchased ones in ascending order (see
    /// MetadataCache.comparePurchaseDates). It is disabled only where every film is
    /// unpurchased by definition: the "Unpurchased" smart list and its 4K / Blu-ray / DVD
    /// variants, and any view filtered to "Unpurchased". On the "Purchased 4K / Blu-ray /
    /// DVD" lists it reads that format's purchases only (ViewIdentifier.purchaseFormatScope).
    ///
    /// A view whose chosen sort becomes disabled — Date Last Purchased, then the "Unpurchased"
    /// filter — is ordered by, and checks, Title until the option is enabled again; the
    /// choice itself is remembered. See ViewState.effectiveSortOption(in:).
    ///
    /// "Last Viewed" is meaningless on the "Unwatched" tab: nothing there has ever been
    /// watched, so every film would sort identically. "Recorded View Count" is disabled
    /// there for exactly the same reason — every film's viewing count is 0. "Rating" is
    /// equally meaningless on the "Not Rated" tab, where every film's rating is 0 by
    /// definition.
    ///
    /// A plain `Set<SortOption>` rather than a wrapper type: the wrapper this replaces
    /// held exactly this one field and restated `contains` as `isDisabled(_:)`.
    static func disabledSortOptions(smartListType: SmartListType?,
                                    unwatchedCategory: UnwatchedCategory?,
                                    filterOptions: Set<FilterOption>) -> Set<SortOption> {
        var disabled: Set<SortOption> = []

        if smartListType?.isUnpurchasedFormat == true || filterOptions.contains(.unpurchased) {
            disabled.insert(.datePurchased)
        }

        switch unwatchedCategory {
        case .unwatched: disabled.formUnion([.lastViewed, .viewCount])
        case .notRated:  disabled.insert(.rating)
        case nil:        break
        }
        return disabled
    }
}

// MARK: - Filter Menu Inputs

/// Everything a Filter menu host must know about the view currently on screen — the
/// counterpart to SortMenuInputs above, and resolved the same way and for the same
/// reasons.
struct FilterMenuInputs: Hashable, Sendable {
    var filters: Set<FilterOption> = []
    /// Filter blocks that should be disabled (but still visible) for this view.
    var disabledBlocks: Set<FilterBlock> = []

    @MainActor
    static func current() -> FilterMenuInputs {
        let manager = ViewStateManager.shared
        let activeView = manager.activeView

        return FilterMenuInputs(
            filters: manager.activeState.filterOptions,
            disabledBlocks: disabledBlocks(smartListType: activeView.smartListType,
                                           recentsCategory: activeView.recentsCategory,
                                           unwatchedCategory: activeView.unwatchedCategory))
    }

    /// The blocks that are meaningless for a given view context, and so render
    /// visible-but-locked there.
    ///
    /// All three inputs are read off a single ViewIdentifier in `current()` above, through
    /// ViewIdentifier's own sub-case accessors, rather than one being handed down by a
    /// host while the other two are read live — which is what the gallery host used to do
    /// with `smartListType`, giving one call three inputs sourced two different ways.
    /// Whether the whole Filter menu is disabled for the active view: during initial
    /// loading, and when the view is empty for a reason filters did not cause. With filters
    /// active, an empty result is exactly when the menu must stay reachable so the user can
    /// clear them. Shared by GalleryFilterMenu's host and the MenuBar's FilterItemsMenu, for
    /// the reason `SortMenuInputs.optionsLocked` gives.
    @MainActor
    static func menuDisabled(coordinator: DataCoordinator) -> Bool {
        let hasActiveFilters = !ViewStateManager.shared.activeState.filterOptions.isEmpty
        return !coordinator.isInitialized || (coordinator.filmCount == 0 && !hasActiveFilters)
    }

    static func disabledBlocks(smartListType: SmartListType?,
                               recentsCategory: RecentsCategory?,
                               unwatchedCategory: UnwatchedCategory?) -> Set<FilterBlock> {
        var disabled: Set<FilterBlock> = []

        // Purchased/Unpurchased is meaningless when the view is already scoped to a
        // purchased or unpurchased smart list, or the "Recently Purchased" recents tab,
        // where every film is purchased (or unpurchased) by definition.
        let isViewingPurchasedSmartList = smartListType?.isPurchasedFormat == true
            || smartListType?.isUnpurchasedFormat == true
        if isViewingPurchasedSmartList || recentsCategory == .recentlyPurchased {
            disabled.insert(.purchase)
        }

        // Watched/Unwatched is meaningless on the "Most Recently Viewed" recents tab
        // (every film is watched by definition) and on the "Unwatched" tab of the
        // Unwatched view (every film there is, by definition, unwatched already).
        if recentsCategory == .recentlyViewed || unwatchedCategory == .unwatched {
            disabled.insert(.watched)
        }

        return disabled
    }
}

// MARK: - Filter Toggle Logic

/// Encodes the mutually-exclusive-group semantics shared by every Filter menu host:
/// selecting one member of a pair (Watched/Unwatched, Color/Black and White,
/// Purchased/Unpurchased, Complete Data/Incomplete Data) clears its counterpart.
/// Genre options are multi-select and unaffected by this clearing behavior.
enum FilterToggleLogic {
    /// Returns the filter set that results from toggling `filterOption` on or off,
    /// starting from `currentFilters`. Callers are responsible for persisting the
    /// result (e.g. via `ViewStateManager.updateFilterOptions`).
    static func applying(_ filterOption: FilterOption, isOn: Bool, to currentFilters: Set<FilterOption>) -> Set<FilterOption> {
        var filters = currentFilters
        if isOn {
            if filterOption.isWatchedFilter {
                filters.remove(.watched)
                filters.remove(.unwatched)
            }
            if filterOption.isColorFilter {
                filters.remove(.color)
                filters.remove(.blackAndWhite)
            }
            if filterOption.isPurchaseFilter {
                filters.remove(.purchased)
                filters.remove(.unpurchased)
            }
            if filterOption.isDataCompleteFilter {
                filters.remove(.completeData)
                filters.remove(.incompleteData)
            }
            filters.insert(filterOption)
        } else {
            filters.remove(filterOption)
        }
        return filters
    }
}

// MARK: - SortMenuContent (Master Definition)

/// The single, master definition of the Sort menu's contents: the sort-option
/// toggles and the Ascending/Descending direction toggles. Both GallerySortMenu
/// (GalleryTitleBar) and SortByMenu (MenuBar) embed this directly inside their own
/// `Menu { }` so the visual definition and disabling behavior can never diverge
/// between the two hosts — only how each host sources its current value and
/// persists a new selection differs, via the closures below.
@MainActor
struct SortMenuContent: View {
    /// Disables every toggle — used when the menu as a whole shouldn't be interactive
    /// (e.g. no films loaded, or a view whose sorting is fixed by definition).
    ///
    /// Checkmarks are deliberately NOT suppressed along with interactivity. A view with
    /// a fixed sort — "Most Recently Viewed" is only what it claims to be when sorted by
    /// Last Viewed — is still sorted by something, and the reason the options are locked
    /// is precisely that the answer is already decided. Blanking the checkmark there
    /// would withhold the one piece of information the menu still exists to convey,
    /// leaving the user unable to tell how the view is ordered. The item renders
    /// checked-but-dimmed, which reads correctly as "this is the sort, and you cannot
    /// change it."
    let isDisabled: Bool
    /// Per-item disabling, layered on top of `isDisabled`. Defaults to no additional
    /// disabling; callers opt in as needed (typically from
    /// `SortMenuInputs.disabledSortOptions`).
    var disabledSortOptions: Set<SortOption> = []

    /// Nil checks no option (see `SortMenuInputs.displayedSortOption`).
    let currentSortOption: SortOption?
    let currentSortDirection: SortDirection
    let onSelectSortOption: (SortOption) -> Void
    let onSelectSortDirection: (SortDirection) -> Void

    /// This view's current section-dividers setting, driving the mutually-exclusive
    /// Show/Hide pair below the direction options.
    let currentShowSectionDividers: Bool
    /// Persists a new section-dividers choice for the host's view.
    let onSelectShowSectionDividers: (Bool) -> Void
    /// Disables the Show/Hide pair — used for a view whose dividers are fixed by
    /// definition rather than chosen. Exactly one view is: the Film Queue's unnarrowed
    /// "All" tab (see ViewStateKey.lockedSectionDividers).
    ///
    /// Checkmarks are deliberately NOT suppressed along with interactivity, for the same
    /// reason they survive `isDisabled` on the sort options above: a fixed setting is
    /// still a setting, and the checked-but-dimmed "Show" is exactly the statement the
    /// menu needs to make — the bands are on, and that is not yours to change.
    var sectionDividersLocked: Bool = false

    /// The section bands currently drawn in the gallery, in display order, for the "Jump to
    /// Section" submenu. Empty renders no submenu, and no divider above it, at all — which
    /// covers every case where there are no bands to jump to: this view's section-dividers
    /// setting off, a sort option with no sectioning rule, or no films loaded.
    ///
    /// Supplied by the host rather than computed here because only the host has the
    /// DataCoordinator — but every host derives it from the same
    /// GallerySectioning.jumpTargets call the galleries' own bands come from, so the submenu
    /// cannot list a band the gallery is not drawing.
    ///
    /// Deliberately NOT gated on `isDisabled`. A locked sort menu still describes a real
    /// gallery with real sections in it, and navigating to one changes nothing about the
    /// sort — which is exactly why the host is expected to leave the menu itself openable
    /// and lock only the options above.
    var jumpTargets: [GallerySectionJumpTarget] = []
    var onJumpToSection: ((GallerySectionJumpTarget) -> Void)? = nil

    var body: some View {
        // Sort options — every one, in every view. An option that means nothing here is
        // disabled through `disabledSortOptions`, never left out, so the menu keeps one
        // shape and a missing item never has to be explained.
        ForEach(SortOption.allCases, id: \.self) { option in
            Toggle(isOn: Binding(
                get: {
                    // Reported even while disabled — see `isDisabled`. A locked item can
                    // still be the selected one, and that is worth showing.
                    currentSortOption == option
                },
                set: { isOn in
                    if isOn {
                        onSelectSortOption(option)
                    }
                })) {
                Text(option.displayName)
            }
            .disabled(isDisabled || disabledSortOptions.contains(option))
        }

        Divider()

        // Direction options
        ForEach([SortDirection.ascending, SortDirection.descending], id: \.self) { direction in
            Toggle(isOn: Binding(
                get: {
                    // Reported even while disabled, for the same reason as the sort
                    // options above: a fixed direction is still a direction.
                    currentSortDirection == direction
                },
                set: { isOn in
                    if isOn {
                        onSelectSortDirection(direction)
                    }
                })) {
                Text(direction.displayName)
            }
            // No view has ever needed the direction pair disabled on its own: the
            // only reason to lock a direction is a fixed sort, and that locks the whole
            // menu through `isDisabled`. A per-direction counterpart to
            // `disabledSortOptions` existed here but nothing ever set it.
            .disabled(isDisabled)
        }

        Divider()

        // A descriptive header, styled rather than disabled — the same treatment, and for
        // the same reason, as the "Sort By:" header each host puts above this content.
        Text("Section Dividers:").foregroundStyle(.secondary)

        // Mutually exclusive by construction: each Toggle reports on only when the state
        // matches it, and acts only on being switched ON. Switching the already-on member
        // off is not a state the pair can express — the same shape the direction pair
        // above uses — so there is no way to reach a "neither" reading.
        //
        // ONE VIEW WHERE THE PAIR IS NOT THE USER'S TO SET: the Film Queue's unnarrowed
        // "All" tab draws its three fixed Up Next / Soon / Later bands unconditionally,
        // because those describe the view's own structure rather than its ordering (see
        // GallerySectioning.displayedSectionBreaks). No choice made here could remove them,
        // so that tab locks the pair ON via `sectionDividersLocked` — which is also what
        // keeps "Jump to Section" permanently available for those three bands, since that
        // submenu is gated on the same value. The Queue's three section tabs sort like any
        // other view once the grouping is narrowed away, and each holds its own ViewState,
        // so all three leave the pair free and independent of one another.
        ForEach([true, false], id: \.self) { showDividers in
            Toggle(isOn: Binding(
                get: { currentShowSectionDividers == showDividers },
                set: { isOn in
                    if isOn {
                        onSelectShowSectionDividers(showDividers)
                    }
                })) {
                Text(showDividers ? "Show" : "Hide")
            }
            .disabled(sectionDividersLocked)
            // Deliberately NOT gated on `isDisabled`, for the same reason "Jump to
            // Section" below is not: `isDisabled` means this view's ORDERING is fixed or
            // there is nothing loaded to order, and neither makes the question of whether
            // to label the bands that ordering produces any less the user's to answer. A
            // fixed-sort view still has sections; hiding the control there would strand
            // whatever the setting already is with no way to change it.
        }

        if !jumpTargets.isEmpty, let onJumpToSection {
            Divider()

            Menu("Jump to Section") {
                ForEach(jumpTargets) { target in
                    Button(target.section.displayName) { onJumpToSection(target) }
                }
            }
        }
    }
}

// MARK: - FilterMenuContent (Master Definition)

/// The single, master definition of the Filter menu's contents: the "None" item and
/// every filter block (Watched/Unwatched, Color/Black and White, Purchased/
/// Unpurchased, Complete Data/Incomplete Data, and Genre). Both GalleryFilterMenu
/// (GalleryTitleBar) and FilterItemsMenu (MenuBar) embed this directly inside their
/// own `Menu { }` so the visual definition and disabling behavior can never diverge
/// between the two hosts — only how each host sources its current filter set and
/// persists a change differs, via the closures below.
@MainActor
struct FilterMenuContent: View {
    let currentFilters: Set<FilterOption>
    /// Disables every toggle and suppresses checkmarks — used when the menu as a
    /// whole shouldn't be interactive yet (e.g. no films loaded).
    let isDisabled: Bool
    /// Per-block disabling, layered on top of `isDisabled`. Defaults to no additional
    /// disabling; callers opt in as needed (typically from
    /// `FilterMenuInputs.disabledBlocks`).
    var disabledBlocks: Set<FilterBlock> = []

    let onClearFilters: () -> Void
    let onToggleFilter: (FilterOption, Bool) -> Void

    var body: some View {
        // "None" option
        Toggle(isOn: Binding(
            get: {
                // Don't show checkmarks when menu is disabled
                guard !isDisabled else { return false }
                return currentFilters.isEmpty
            },
            set: { isOn in
                if isOn {
                    onClearFilters()
                }
            })) {
            Text("None")
        }
        Divider()

        // Watched filters (mutually exclusive). Disabled as a block — rather than
        // hidden — on the "Most Recently Viewed" tab of RecentsView: every film there
        // is watched by definition, so this pair would always produce either the full
        // list (watched) or an empty list (unwatched) and is therefore never useful.
        filterToggle(.watched, label: "Watched", block: .watched)
        filterToggle(.unwatched, label: "Unwatched", block: .watched)
        Divider()

        // Color filters (mutually exclusive)
        filterToggle(.color, label: "Color", block: .color)
        filterToggle(.blackAndWhite, label: "Black and White", block: .color)

        // Purchase filters (mutually exclusive). Disabled as a block — rather than
        // hidden — when viewing any purchased/unpurchased smart list (already scoped
        // by definition) and on the "Recently Purchased" tab of RecentsView for the
        // same reason.
        Divider()
        filterToggle(.purchased, label: "Purchased", block: .purchase)
        filterToggle(.unpurchased, label: "Unpurchased", block: .purchase)

        // Data completion filters (mutually exclusive) - only shown if feature is
        // enabled. This visibility gate is a global user-facing feature toggle
        // (Settings), not a per-view concern, so it remains a show/hide rather than a
        // disabled block.
        if Preferences.showInfoComplete {
            Divider()
            filterToggle(.completeData, label: "Complete Data", block: .dataComplete)
            filterToggle(.incompleteData, label: "Incomplete Data", block: .dataComplete)
        }

        Divider()

        // Genre filters (multi-selection allowed), treated as a single block
        ForEach(FilterOption.genreOptions, id: \.self) { genreOption in
            filterToggle(genreOption, label: genreOption.displayName, block: .genre)
        }
    }

    @ViewBuilder
    private func filterToggle(_ option: FilterOption, label: String, block: FilterBlock) -> some View {
        Toggle(isOn: Binding(
            get: {
                // Don't show checkmarks when menu is disabled
                guard !isDisabled else { return false }
                return currentFilters.contains(option)
            },
            set: { isOn in onToggleFilter(option, isOn) })) {
            Text(label)
        }
        .disabled(isDisabled || disabledBlocks.contains(block))
    }
}

// MARK: - GallerySortMenu (Sort Options + Direction)
@MainActor
struct GallerySortMenu: View {
    let isDisabled: Bool
    /// Source for the Sort menu's inputs — the "Jump to Section" entries in particular,
    /// which are a scan of the loaded film set.
    let coordinator: DataCoordinator

    /// Mirror of everything this menu displays, refreshed at the points below.
    ///
    /// Deliberately a pushed mirror rather than a live read, even though this host — unlike
    /// SortByMenu — does participate in SwiftUI's observation system. `Menu`'s content is
    /// a non-escaping `() -> Content` whose result is materialized immediately, so every
    /// argument passed to SortMenuContent is evaluated whenever this body runs, menu open
    /// or not. Reading `ViewStateManager.activeState` live registered this view against
    /// that single stored property, which every field of ViewState shares — including
    /// `searchQuery`, written on each keystroke by `updateSearchQuery`. The result was a
    /// full film scan for `jumpTargets` per character typed into the search field, for a
    /// menu nobody had opened. (An earlier comment here and in SortByMenu asserted this
    /// body was "built only when the user clicks the toolbar button"; it never was.)
    ///
    /// The refresh points are SortByMenu's, plus two that together make this mirror at
    /// least as fresh as the live read it replaces, without depending on the menu-tracking
    /// notification to catch anything:
    ///
    ///   • The film COUNT. `updateSearchQuery` reloads the film set without going through
    ///     commitActiveStateChange, so it emits no viewStateChanged event to ride — and
    ///     every bulk path (import, restore, deletion) moves the count too. Reading
    ///     `coordinator.films.count` in the body is what registers this view against the
    ///     film set at all; it is O(1), unlike the scan it now gates.
    ///   • Per-film metadata and release edits, which are the only way a band boundary can
    ///     move while the count stays put (a film's release year changing its band under a
    ///     release-year sort). User-paced, so this is not a bulk-operation cost; additions
    ///     and deletions are deliberately left to the count above rather than double-firing
    ///     here. Refreshed a turn after the event, once the edited films are loaded.
    ///
    /// Everything else — the sort, the direction, the dividers setting and its lock, and
    /// the per-view disabling — changes only through a ViewStateManager mutator or a view
    /// switch, and both broadcast viewStateChanged (switchToViewSync fires it on every
    /// `isViewChange`, prepareSubTabStateHandoff unconditionally).
    @State private var inputs = SortMenuInputs()

    var body: some View {
        Menu {
            menuContents
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
        }
        .menuIndicator(.hidden)
        .help("Change the sorting order")
        .onAppear { refreshInputs() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            refreshInputs()
        }
        .onViewStateChanged { refreshInputs() }
        .onChange(of: coordinator.films.count) { _, _ in refreshInputs() }
        .onFilmEvent { event in
            switch event {
            // One turn later: the event is delivered synchronously, and its sender reloads
            // the films only after posting it (DataCoordinator.reloadCurrentView), so a
            // refresh made here would scan the films as they were before the edit.
            case .updated, .releaseChanged: DispatchQueue.main.async { refreshInputs() }
            case .added, .deleted: break
            }
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        // A descriptive header, not an item — so it is styled rather than disabled.
        // `.disabled(true)` was redundant (a bare Text in a menu is not selectable to
        // begin with) and actively misleading once the options below it can be disabled
        // as a block: the header rendered in the identical gray and read as one more
        // unavailable row rather than as the label for them. `.secondary` keeps it
        // distinct from the selectable items without ever matching the disabled ones.
        Text("Sort By:").foregroundStyle(.secondary)
        SortMenuContent(
            isDisabled: isDisabled,
            disabledSortOptions: inputs.disabledSortOptions,
            currentSortOption: inputs.sortOption,
            currentSortDirection: inputs.sortDirection,
            onSelectSortOption: { ViewStateManager.shared.updateSortOption($0) },
            onSelectSortDirection: { ViewStateManager.shared.updateSortDirection($0) },
            currentShowSectionDividers: inputs.showSectionDividers,
            onSelectShowSectionDividers: { ViewStateManager.shared.updateShowSectionDividers($0) },
            sectionDividersLocked: inputs.sectionDividersLocked,
            jumpTargets: inputs.jumpTargets,
            onJumpToSection: { ViewStateManager.shared.jumpToSectionBand($0) }
        )
    }

    /// Every setter above writes through ViewStateManager, whose change emits
    /// viewStateChanged and so refreshes this mirror on its own — no setter needs to
    /// realign it by hand the way SortByMenu's do, because this host is re-rendered by
    /// that event rather than merely notified of it.
    @MainActor
    private func refreshInputs() {
        inputs = SortMenuInputs.current(coordinator: coordinator)
    }
}

// MARK: - GalleryFilterMenu (All Filter Options)
@MainActor
struct GalleryFilterMenu: View {
    let isDisabled: Bool

    var viewStateManager = ViewStateManager.shared

    /// Every input this menu needs, resolved in one call from the active view — including
    /// the smart-list type, which used to arrive as a parameter from GalleryTitleBar while
    /// the recents and unwatched categories beside it were read live. GalleryTitleBar is
    /// constructed as `GalleryTitleBar(viewIdentifier: viewStateManager.activeView)`, so
    /// the parameter was a hand-carried copy of the value read here anyway; sourcing all
    /// three the same way leaves nothing for the two spellings to drift between.
    ///
    /// Read live rather than mirrored, unlike GallerySortMenu above: nothing here scans
    /// the film set, so a body evaluation is cheap and staying observation-driven is
    /// strictly the fresher option.
    private var inputs: FilterMenuInputs { FilterMenuInputs.current() }

    var hasActiveFilters: Bool {
        !viewStateManager.activeState.filterOptions.isEmpty
    }

    var body: some View {
        Menu {
            // A descriptive header, not an item — the exact counterpart to
            // GallerySortMenu's "Sort By:" above, and styled the same way and for the
            // same reasons: a bare Text in a menu is already unselectable, so
            // `.disabled(true)` would add nothing but the disabled gray, which would make
            // the header read as one more unavailable row alongside the filter blocks
            // that genuinely do disable as a block. `.secondary` keeps it distinct from
            // both the selectable items and the disabled ones.
            Text("Filter:").foregroundStyle(.secondary)
            let inputs = self.inputs
            FilterMenuContent(
                currentFilters: inputs.filters,
                isDisabled: isDisabled,
                disabledBlocks: inputs.disabledBlocks,
                onClearFilters: { viewStateManager.clearFilters() },
                onToggleFilter: { option, isOn in
                    let updated = FilterToggleLogic.applying(
                        option, isOn: isOn, to: viewStateManager.activeState.filterOptions)
                    viewStateManager.updateFilterOptions(updated)
                }
            )
        } label: {
            // Show the filled badge only when filters are active AND the button is enabled.
            // Showing the badge on a disabled button is misleading — the user cannot interact
            // with it, and on initial load the saved filters aren't yet actionable.
            Image(systemName: !isDisabled && hasActiveFilters ?
                "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
        }
        .menuIndicator(.hidden)
        .help("Apply filters")
    }
}
