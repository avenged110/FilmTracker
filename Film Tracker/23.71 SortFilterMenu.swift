// MARK: - SortFilterMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Sort and filter menus that use ViewStateManager as the single source of truth.
///
/// This file defines what the Sort and Filter menus contain, and what they need to know about the view on
/// screen. Two hosts present each menu: GalleryTitleBar's GallerySortMenu and GalleryFilterMenu, and MenuBar's
/// SortByMenu and FilterItemsMenu. Three things live here, so neither pair can diverge:
///
///   • The menu contents, meaning the toggles, their labels, and which blocks disable together. These are in
///     SortMenuContent and FilterMenuContent. Each host supplies only its current value and a persist closure.
///   • What the menus need to know about the active view, in SortMenuInputs and FilterMenuInputs. They derive it once from
///     (activeView, activeState, coordinator).
///   • The mutually exclusive group rules, in FilterToggleLogic.
///
/// Each host only chooses how it obtains and refreshes those inputs. SortByMenu mirrors them into @State and
/// resyncs them, because NSMenu-backed Commands items do not take part in SwiftUI observation.
/// GalleryFilterMenu reads them live. GallerySortMenu also mirrors them, because its inputs include a scan of
/// the film set, and Menu evaluates its content eagerly.

import SwiftUI
import AppKit

// MARK: - Filter Menu Blocks

/// Groups of related Filter menu items. Each block is disabled as a whole. For example, disabling `.watched`
/// disables both the Watched and Unwatched toggles, and no other block.
enum FilterBlock: Sendable {
    case watched
    case color
    case purchase
    case dataComplete
    case genre
}

// MARK: - Sort Menu Inputs

/// Everything a Sort menu host needs to know about the view on screen, resolved in one pass from one source.
///
/// The two hosts, GallerySortMenu and SortByMenu, need the same seven values, all derived from the active
/// ViewIdentifier, the active ViewState, and the DataCoordinator. Resolving them together makes the order of
/// updates structural. SortByMenu's manual resync order matters, since `jumpTargets` depends on
/// `showSectionDividers`.
///
/// It is a plain value type, so the menu-bar host can mirror it in one @State. Commands items do not observe
/// SwiftUI state, so they need the value pushed to them.
struct SortMenuInputs: Hashable, Sendable {
    /// The option the menu checks, or nil for none. See `displayedSortOption`.
    var sortOption: SortOption? = .title
    var sortDirection: SortDirection = .ascending

    /// Sort options that are disabled, but still visible, for this view. Options are never hidden, so the
    /// menu keeps its shape across views. The rules are in
    /// `disabledSortOptions(smartListType:unwatchedCategory:filterOptions:)`.
    var disabledSortOptions: Set<SortOption> = []

    var showSectionDividers: Bool = false
    /// Whether the Show/Hide pair is fixed for this view rather than the user's to set. See
    /// ViewStateKey.lockedSectionDividers for the rule and its one subject.
    var sectionDividersLocked: Bool = false

    /// The section bands the gallery is currently drawing, in display order.
    var jumpTargets: [GallerySectionJumpTarget] = []

    /// Resolves every value above for the view on screen right now.
    ///
    /// `jumpTargets` comes from the same GallerySectioning call as the galleries' bands, so no host can offer
    /// a band that the gallery does not draw. It is also the expensive member, since it scans the loaded
    /// films, which is why hosts mirror this struct and do not rebuild it on every evaluation.
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

    /// Whether the sort options and direction pair are locked for the active view. That happens for a
    /// fixed-sort view (every Recents tab and Upcoming Releases) or an empty library. The Section Dividers
    /// pair, Jump to Section, and the menu itself are never locked.
    ///
    /// Both hosts use this, so they lock the same items. Computing it per host is how they drifted.
    @MainActor
    static func optionsLocked(coordinator: DataCoordinator) -> Bool {
        ViewStateManager.shared.activeView.hasFixedSort || coordinator.totalFilmCount == 0
    }

    /// The option the menu checks for a view whose stored sort is `stored`.
    ///
    /// It is nil on Recently Come Up for Rotation, which no option describes. That view is ordered by
    /// rotation eligibility date, and its stored `.dateAdded` is a placeholder (see
    /// RecentsCategory.sortOption). Upcoming Releases is also nil, since its ordering is the soonest upcoming
    /// release, and its stored `.title` is a placeholder.
    static func displayedSortOption(_ stored: SortOption,
                                    recentsCategory: RecentsCategory?,
                                    smartListType: SmartListType? = nil) -> SortOption? {
        recentsCategory == .recentlyRotated || smartListType == .upcomingReleases ? nil : stored
    }

    /// Sort options that are meaningless in a view. They stay visible but locked.
    ///
    /// Date Last Purchased applies to any view that can hold a purchased film. An unpurchased film sorts
    /// ahead in ascending order (see MetadataCache.comparePurchaseDates). It is disabled only where every
    /// film is unpurchased: the Unpurchased lists and their variants, and any view filtered to Unpurchased.
    /// On the Purchased 4K, Blu-ray, and DVD lists it reads only that format's purchases.
    ///
    /// A disabled sort falls back to Title in ordering and checkmark, but the stored choice is kept. See
    /// ViewState.effectiveSortOption(in:).
    ///
    /// Last Viewed is meaningless on the Unwatched tab, and Recorded View Count is disabled there too, since
    /// every film is at 0. Rating is meaningless on the Not Rated tab, where every rating is 0.
    ///
    /// It is a plain Set<SortOption>.
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

/// Everything a Filter menu host needs to know about the view on screen. It is the counterpart to
/// SortMenuInputs.
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

    /// The blocks that are meaningless for a given view context, and so render visible-but-locked there.
    ///
    /// All three inputs are read off a single ViewIdentifier in `current()` above, through ViewIdentifier's
    /// own sub-case accessors, rather than one being handed down by a host while the other two are read live
    /// — which would give one call three inputs sourced
    /// two different ways. Whether the whole Filter menu is disabled for the active view: during initial
    /// loading, and when the view is empty for a reason filters did not cause. With filters active, an empty
    /// result is exactly when the menu must stay reachable so the user can clear them. Shared by
    /// GalleryFilterMenu's host and the MenuBar's FilterItemsMenu, for the reason
    /// `SortMenuInputs.optionsLocked` gives.
    @MainActor
    static func menuDisabled(coordinator: DataCoordinator) -> Bool {
        let hasActiveFilters = !ViewStateManager.shared.activeState.filterOptions.isEmpty
        return !coordinator.isInitialized || (coordinator.filmCount == 0 && !hasActiveFilters)
    }

    static func disabledBlocks(smartListType: SmartListType?,
                               recentsCategory: RecentsCategory?,
                               unwatchedCategory: UnwatchedCategory?) -> Set<FilterBlock> {
        var disabled: Set<FilterBlock> = []

        /// Purchased and Unpurchased are meaningless in a view already scoped to a purchased or unpurchased
        /// smart list, or in the Recently Purchased tab, where every film is purchased (or unpurchased) by
        /// definition.
        let isViewingPurchasedSmartList = smartListType?.isPurchasedFormat == true
            || smartListType?.isUnpurchasedFormat == true
        if isViewingPurchasedSmartList || recentsCategory == .recentlyPurchased {
            disabled.insert(.purchase)
        }

        /// Watched and Unwatched are meaningless on the Most Recently Viewed tab, where every film is watched,
        /// and on the Unwatched tab, where every film is unwatched.
        if recentsCategory == .recentlyViewed || unwatchedCategory == .unwatched {
            disabled.insert(.watched)
        }

        return disabled
    }
}

// MARK: - Filter Toggle Logic

/// The mutually exclusive group rules shared by every Filter menu host. Picking one member of a pair
/// (Watched/Unwatched, Color/Black and White, Purchased/Unpurchased, Complete Data/Incomplete Data) clears
/// its counterpart. Genre is multi-select.
enum FilterToggleLogic {
    /// Returns the filter set that results from toggling `filterOption` on or off, starting from
    /// `currentFilters`. Callers are responsible for persisting the result (e.g. via
    /// `ViewStateManager.updateFilterOptions`).
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

/// The master definition of the Sort menu's contents: the sort-option toggles and the Ascending and
/// Descending toggles. Both GallerySortMenu and SortByMenu embed it, so the look and the disabling cannot
/// diverge. The hosts differ only in how they read the current value and persist a change, through the
/// closures below.
@MainActor
struct SortMenuContent: View {
    /// Disables every toggle, for when the menu should not be interactive, such as with no films loaded or a
    /// view whose sort is fixed.
    ///
    /// Checkmarks stay visible. A fixed-sort view is still sorted by something, and the locked checkmark
    /// tells the user how the view is ordered. It renders checked but dimmed.
    let isDisabled: Bool
    /// Per-item disabling, layered on top of `isDisabled`. It defaults to none, and callers supply it,
    /// typically from SortMenuInputs.disabledSortOptions.
    var disabledSortOptions: Set<SortOption> = []

    /// Nil checks no option (see `SortMenuInputs.displayedSortOption`).
    let currentSortOption: SortOption?
    let currentSortDirection: SortDirection
    let onSelectSortOption: (SortOption) -> Void
    let onSelectSortDirection: (SortDirection) -> Void

    /// The current section-dividers setting, which drives the Show and Hide pair below the direction options.
    let currentShowSectionDividers: Bool
    /// Persists a new section-dividers choice for the host's view.
    let onSelectShowSectionDividers: (Bool) -> Void
    /// Disables the Show and Hide pair. That applies to a view whose dividers are fixed, which is only the
    /// Film Queue's unnarrowed All tab (see ViewStateKey.lockedSectionDividers). Checkmarks stay visible, as
    /// with the sort options, since the bands are on and not the user's to change.
    var sectionDividersLocked: Bool = false

    /// The section bands currently drawn in the gallery, in display order, for the Jump to Section submenu.
    /// The submenu is empty (and not shown) when dividers are off, when the sort has no sectioning rule, or
    /// when no films are loaded.
    ///
    /// The host supplies it, since only the host has the DataCoordinator. Every host uses
    /// GallerySectioning.jumpTargets, the same call the galleries use for their bands, so the submenu never
    /// lists a band the gallery is not drawing.
    ///
    /// It is not gated on `isDisabled`. A locked sort still has real sections, and jumping to one does not
    /// change the sort. So the host leaves the menu openable and locks only the options.
    var jumpTargets: [GallerySectionJumpTarget] = []
    var onJumpToSection: ((GallerySectionJumpTarget) -> Void)? = nil

    var body: some View {
        /// Sort options: every one, in every view. An option that means nothing here is disabled, never
        /// removed, so the menu keeps one shape and no item needs explaining.
        ForEach(SortOption.allCases, id: \.self) { option in
            Toggle(isOn: Binding(
                get: {
                    /// The checkmark is reported even while disabled, so a locked selected item still shows.
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

        /// Direction options
        ForEach([SortDirection.ascending, SortDirection.descending], id: \.self) { direction in
            Toggle(isOn: Binding(
                get: {
                    /// Reported even while disabled, as with the sort options. A fixed direction is still a
                    /// direction.
                    currentSortDirection == direction
                },
                set: { isOn in
                    if isOn {
                        onSelectSortDirection(direction)
                    }
                })) {
                Text(direction.displayName)
            }
            /// Nothing disables the direction pair on its own. A fixed sort locks the whole menu through
            /// `isDisabled`. A per-direction counterpart to `disabledSortOptions` existed but was never used.
            .disabled(isDisabled)
        }

        Divider()

        /// A descriptive header, styled rather than disabled, as the "Sort By:" header is in each host. A
        /// disabled header would look like another unavailable row.
        Text("Section Dividers:").foregroundStyle(.secondary)

        /// Mutually exclusive by construction. Each Toggle is on only when the state matches it, and it acts
        /// only when switched on. Switching the on member off cannot be expressed, so no "neither" state is
        /// reachable.
        ///
        /// One view does not let the user choose: the Film Queue's unnarrowed All tab always draws its three
        /// bands, which describe its structure, not its ordering (see
        /// GallerySectioning.displayedSectionBreaks). That tab locks the pair On through
        /// `sectionDividersLocked`, and Jump to Section stays available. The three section tabs sort like any
        /// other view once narrowed, and each keeps its own ViewState, so they are independent.
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
            /// Not gated on `isDisabled`, for the same reason as Jump to Section. A fixed-sort view still has
            /// sections, and hiding the control would leave the current setting with no way to change it.
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

/// The master definition of the Filter menu's contents: the None item and every filter block (Watched, Color,
/// Purchased, Complete Data, and Genre). GalleryFilterMenu and FilterItemsMenu both embed it, so they cannot
/// diverge. The hosts differ only in how they read the current set and persist a change, through the closures
/// below.
@MainActor
struct FilterMenuContent: View {
    let currentFilters: Set<FilterOption>
    /// Disables every toggle and suppresses checkmarks, for when the menu should not be interactive yet, such
    /// as with no films loaded.
    let isDisabled: Bool
    /// Per-block disabling, layered on top of `isDisabled`. It defaults to none, and callers typically supply
    /// FilterMenuInputs.disabledBlocks.
    var disabledBlocks: Set<FilterBlock> = []

    let onClearFilters: () -> Void
    let onToggleFilter: (FilterOption, Bool) -> Void

    var body: some View {
        /// "None" option
        Toggle(isOn: Binding(
            get: {
                /// Don't show checkmarks when menu is disabled
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

        /// Watched filters, mutually exclusive. Disabled as a block, not hidden, on the Most Recently Viewed
        /// tab, where every film is watched. Either choice would show all films or none, so the pair is never
        /// useful there.
        filterToggle(.watched, label: "Watched", block: .watched)
        filterToggle(.unwatched, label: "Unwatched", block: .watched)
        Divider()

        /// Color filters (mutually exclusive)
        filterToggle(.color, label: "Color", block: .color)
        filterToggle(.blackAndWhite, label: "Black and White", block: .color)

        /// Purchase filters, mutually exclusive. Disabled as a block, not hidden, in purchased or unpurchased
        /// smart lists and on the Recently Purchased tab, for the same reason.
        Divider()
        filterToggle(.purchased, label: "Purchased", block: .purchase)
        filterToggle(.unpurchased, label: "Unpurchased", block: .purchase)

        /// Data completion filters, mutually exclusive. They appear only when the feature is enabled in
        /// Settings. That is a global toggle, not a per-view rule, so it is a show or hide and not a disabled
        /// block.
        if Preferences.showInfoComplete {
            Divider()
            filterToggle(.completeData, label: "Complete Data", block: .dataComplete)
            filterToggle(.incompleteData, label: "Incomplete Data", block: .dataComplete)
        }

        Divider()

        /// Genre filters (multi-selection allowed), treated as a single block
        ForEach(FilterOption.genreOptions, id: \.self) { genreOption in
            filterToggle(genreOption, label: genreOption.displayName, block: .genre)
        }
    }

    @ViewBuilder
    private func filterToggle(_ option: FilterOption, label: String, block: FilterBlock) -> some View {
        Toggle(isOn: Binding(
            get: {
                /// Don't show checkmarks when menu is disabled
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
    /// The source of the Sort menu's inputs. The Jump to Section entries, in particular, scan the loaded
    /// films.
    let coordinator: DataCoordinator

    /// A pushed mirror of everything this menu displays, refreshed at the points below. Unlike SortByMenu,
    /// this host can observe SwiftUI state, but a live read is still a problem. Menu materializes its content
    /// on every body evaluation, so every argument is computed even when the menu is closed. Reading
    /// ViewStateManager.activeState registered this view against searchQuery, which changes on every
    /// keystroke. That caused a film scan per keystroke for a menu nobody had opened.
    ///
    /// The refresh points are SortByMenu's, plus two that keep the mirror as fresh as a live read:
    ///
    ///   • The film count. updateSearchQuery reloads films without a viewStateChanged event, and bulk paths move the count too.
    ///     Reading coordinator.films.count registers the view against the film set, and it is O(1).
    ///   • Per-film metadata and release edits, the only way a band boundary moves while the count stays the same. Refreshed a turn
    ///     after the event, once the edited films are loaded. Additions and deletions are left to the count.
    ///
    /// The sort, direction, dividers setting, and per-view disabling change only through a ViewStateManager
    /// mutator or a view switch. Both broadcast viewStateChanged.
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
            /// One turn later. The event is delivered synchronously, but its sender reloads the films only
            /// after posting it, so a refresh here would scan the old films.
            case .updated, .releaseChanged: DispatchQueue.main.async { refreshInputs() }
            case .added, .deleted: break
            }
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        /// A descriptive header, styled rather than disabled. A bare Text in a menu is already unselectable,
        /// and .disabled would make it look like an unavailable row beside the options it labels.
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

    /// Every setter writes through ViewStateManager, which emits viewStateChanged. That event re-renders this
    /// host, so no setter needs to refresh the mirror by hand.
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

    /// Every input this menu needs, resolved in one call from the active view. All three inputs come from the same ViewIdentifier, so they
    /// cannot drift apart.
    ///
    /// It is read live, not mirrored, since nothing here scans the films. A body evaluation is cheap, so the
    /// observation-driven read is the fresher choice.
    private var inputs: FilterMenuInputs { FilterMenuInputs.current() }

    var hasActiveFilters: Bool {
        !viewStateManager.activeState.filterOptions.isEmpty
    }

    var body: some View {
        Menu {
            /// A descriptive header, styled rather than disabled, as the Sort menu header is. A disabled
            /// header would read as another unavailable row beside the filter blocks that do disable.
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
            /// The filled badge shows only when filters are active and the button is enabled. A badge on a
            /// disabled button would mislead, because the user cannot interact with it, and the saved filters
            /// are not yet actionable during initial load.
            Image(systemName: !isDisabled && hasActiveFilters ?
                "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
        }
        .menuIndicator(.hidden)
        .help("Apply filters")
    }
}
