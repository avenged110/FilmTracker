// MARK: - ViewState.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Defines the core view-layer value types and enums: SortOption, SortDirection, FilterOption, ViewIdentifier,
/// ViewState, and the category enums (RecentsCategory, ImportsCategory, etc.) used to identify and
/// parameterize every navigable view in the app.

import Foundation
import CoreGraphics
import Combine

// MARK: - Sort Options
enum SortOption: String, CaseIterable, Codable, Sendable {
    case title
    /// Shown as "Release Date": ordered by the film's release year, then its full release date. The raw value
    /// stays "year" because it is what persisted view states store.
    case year
    case duration
    case dateAdded
    case dateModified
    /// Sorts by the most recent purchase date among the film's purchased releases — of the view's own format
    /// on the "Purchased 4K / Blu-ray / DVD" lists, of any format elsewhere (see
    /// ViewIdentifier.purchaseFormatScope). Always listed in the sort menu; disabled only where every film is
    /// unpurchased (see SortMenuInputs.disabledSortOptions).
    case datePurchased
    case lastViewed
    /// Sorts by the number of recorded viewings (the length of a film's calendarTable) — the same figure the
    /// RightSidebar's "Watch Details" module reports as "Recorded View Count". Ascending places films with no
    /// recorded viewings first.
    case viewCount
    case rating

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .year: return "Release Date"
        case .duration: return "Duration"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .datePurchased: return "Date Last Purchased"
        case .lastViewed: return "Last Viewed"
        case .viewCount: return "Recorded View Count"
        case .rating: return "Rating"
        }
    }
}

// MARK: - Sort Direction
enum SortDirection: String, CaseIterable, Codable, Sendable {
    case ascending
    case descending

    var displayName: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

// MARK: - Filter Options
enum FilterOption: String, CaseIterable, Hashable, Codable, Sendable {
    case none

    /// Watched filters (mutually exclusive)
    case watched
    case unwatched

    /// Color filters (mutually exclusive)
    case color
    case blackAndWhite

    /// Purchase filters (mutually exclusive)
    case purchased
    case unpurchased

    /// Data completion filters (mutually exclusive)
    case completeData
    case incompleteData

    /// Genre filters (multi-selection allowed)
    case actionAndAdventure
    case comedy
    case drama
    case horror
    case kidsAndFamily
    case sciFiAndFantasy
    case thriller

    var displayName: String {
        switch self {
        case .none: return "None"
        case .watched: return "Watched"
        case .unwatched: return "Unwatched"
        case .color: return "Color"
        case .blackAndWhite: return "Black and White"
        case .purchased: return "Purchased"
        case .unpurchased: return "Unpurchased"
        case .completeData: return "Complete Data"
        case .incompleteData: return "Incomplete Data"
        case .actionAndAdventure: return "Action and Adventure"
        case .comedy: return "Comedy"
        case .drama: return "Drama"
        case .horror: return "Horror"
        case .kidsAndFamily: return "Kids and Family"
        case .sciFiAndFantasy: return "Sci-Fi and Fantasy"
        case .thriller: return "Thriller"
        }
    }

    var isWatchedFilter: Bool {
        switch self {
        case .watched, .unwatched: return true
        default: return false
        }
    }

    var isColorFilter: Bool {
        switch self {
        case .color, .blackAndWhite: return true
        default: return false
        }
    }

    var isPurchaseFilter: Bool {
        switch self {
        case .purchased, .unpurchased: return true
        default: return false
        }
    }

    var isDataCompleteFilter: Bool {
        switch self {
        case .completeData, .incompleteData: return true
        default: return false
        }
    }

    var isGenre: Bool {
        switch self {
        case .actionAndAdventure, .comedy, .drama, .horror, .kidsAndFamily,
             .sciFiAndFantasy, .thriller: return true
        default: return false
        }
    }

    /// The genre filters in menu order. The single source of the app's canonical genre
    /// whitelist: `genreNames` (their display names) is what films store in `genre`.
    static let genreOptions: [FilterOption] = allCases.filter(\.isGenre)

    /// The canonical stored genre strings, in menu order.
    static let genreNames: [String] = genreOptions.map(\.displayName)
}

// MARK: - Recents Category
enum RecentsCategory: String, CaseIterable, Codable, Sendable {
    case recentlyViewed
    case recentlyRotated
    case recentlyAdded
    case recentlyUpdated
    case recentlyPurchased

    var displayName: String {
        switch self {
        case .recentlyViewed: return "Most Recently Viewed"
        case .recentlyRotated: return "Recently Come Up for Rotation"
        case .recentlyAdded: return "Recently Added"
        case .recentlyUpdated: return "Recently Updated"
        case .recentlyPurchased: return "Recently Purchased"
        }
    }

    /// Further full names a `#list` token accepts for this tab, beside `displayName`.
    var searchAliases: [String] {
        switch self {
        case .recentlyViewed: return ["Most Recently Watched", "Recently Watched", "Recently Viewed"]
        case .recentlyRotated: return ["Recently Up for Rotation"]
        case .recentlyAdded, .recentlyUpdated, .recentlyPurchased: return []
        }
    }

    var glyph: String {
        switch self {
        case .recentlyViewed: return ViewGlyphs.recentlyViewed.outline
        case .recentlyRotated: return ViewGlyphs.recentlyRotated.outline
        case .recentlyAdded: return ViewGlyphs.recentlyAdded.outline
        case .recentlyUpdated: return ViewGlyphs.recentlyUpdated.outline
        case .recentlyPurchased: return ViewGlyphs.recentlyPurchased.filled
        }
    }

    /// The fixed sort this tab's ViewState carries. MetadataCache.recentFilmIDs(for:) does the real ordering;
    /// this is what the Sort menu reports and what an in-place refresh (DataCoordinator.refreshFilms) sorts
    /// by until the next full load re-supplies it, so it names the matching option wherever one exists.
    ///
    /// Recently Purchased orders by the most recent purchase of any format, which is exactly Date Last
    /// Purchased with no format scope. Recently Come Up for Rotation orders by rotation eligibility date,
    /// which no option expresses: `.dateAdded` there is only a placeholder, and the Sort menu shows no
    /// checkmark for that tab (SortMenuInputs.displayedSortOption).
    var sortOption: SortOption {
        switch self {
        case .recentlyViewed: return .lastViewed
        case .recentlyRotated: return .dateAdded /// Placeholder; see above
        case .recentlyAdded: return .dateAdded
        case .recentlyUpdated: return .dateModified
        case .recentlyPurchased: return .datePurchased
        }
    }

    var dateType: MetadataCache.DateType {
        switch self {
        case .recentlyViewed: return .lastWatched
        case .recentlyRotated: return .rotationDate
        case .recentlyAdded: return .dateAdded
        case .recentlyUpdated: return .lastModified
        case .recentlyPurchased: return .purchaseDate
        }
    }

    /// The pre-sorted, category-ordered film ID list for this category, straight from MetadataCache. This is
    /// the single authoritative dispatch point from a category to its MetadataCache accessor — used by
    /// DataCoordinator.loadFilms to populate recents views and by MainView's search-exit membership check —
    /// so the two call sites can never diverge when a new category is added.
    @MainActor
    func orderedFilmIDs() -> [UUID] {
        MetadataCache.shared.recentFilmIDs(for: self)
    }
}

// MARK: - Imports Category
enum ImportsCategory: String, CaseIterable, Codable, Sendable {
    case metadata
    case ratings
    
    var displayName: String {
        switch self {
        case .metadata: return "Metadata"
        case .ratings: return "Ratings"
        }
    }
    
    var glyph: String {
        switch self {
        case .metadata: return ViewGlyphs.metadataImport.filled
        case .ratings: return ViewGlyphs.ratingsImport.filled
        }
    }
    
    var buttonTitle: String {
        switch self {
        case .metadata: return "Select Files"
        case .ratings: return "Select HTML File"
        }
    }
}

// MARK: - Effective Sort

extension ViewState {
    /// The sort this view is actually ordered by, and the one its Sort menu checks.
    ///
    /// Normally the user's chosen `sortOption`. When that option is disabled in this view as currently
    /// filtered (SortMenuInputs.disabledSortOptions) — Date Last Purchased under the "Unpurchased" filter,
    /// say — the view falls back to Title. The choice itself is left untouched in `sortOption`, which is
    /// persisted, so it acts as the memory: lift the filter and the option is enabled again, and both the
    /// order and the menu return to it. Choosing any other option meanwhile replaces that memory, as any
    /// choice does.
    ///
    /// Title because it is never disabled, and because it is what a disabled option's order already degrades
    /// to: every comparator ends in the title tiebreak, so a view "sorted by" Date Last Purchased with no
    /// purchases in it is in title order anyway. This makes the menu say so instead of claiming an ordering
    /// the view no longer has.
    func effectiveSortOption(in view: ViewIdentifier) -> SortOption {
        let disabled = SortMenuInputs.disabledSortOptions(
            smartListType: view.smartListType,
            unwatchedCategory: view.unwatchedCategory,
            filterOptions: filterOptions)
        return disabled.contains(sortOption) ? .title : sortOption
    }
}

// MARK: - View State
struct ViewState: Equatable, Sendable {
    /// The sort the user CHOSE for this view — persisted, and only ever changed by the user picking another
    /// option. What the view is actually ordered by is `effectiveSortOption(in:)`, which differs while this
    /// choice is disabled.
    var sortOption: SortOption = .title
    var filterOptions: Set<FilterOption> = []
    var sortDirection: SortDirection = .ascending
    var searchQuery: String = ""
    /// When true the gallery renders as a SwiftUI List instead of the NSCollectionView grid.
    var isListView: Bool = false
    /// When true this view inserts labeled divider bands from its active sort, and its Sort menu offers Jump
    /// to Section for them.
    ///
    /// It defaults to false for every view. There is no migration from the old global preference, because
    /// "off everywhere until chosen here" is the only starting point that is true for every view. The choice
    /// persists only while Preferences.rememberSortFilterSelections is on.
    var showSectionDividers: Bool = false
    /// Equatable synthesized by the compiler: all stored properties are Equatable, so no custom ==
    /// implementation is needed.
}

// MARK: - View State Persistence Codec
///
/// The on-disk form of a ViewState is a positional [String] array. It is stored under the view's
/// persistenceKey in Preferences.viewSortStates, and in ListObject.sortFilterOptions for user lists.
///
/// The codec lives on the type, not in ViewStateManager, because DataCoordinator's startup pre-warm also reads
/// it. The pre-warm must sort All Films with the saved settings before the view asks for them, so the cache
/// hits. One codec keeps the two in agreement.
extension ViewState {
    /// Decodes a stored settings array. Every element is optional and checked on its own. A short array, an
    /// unrecognized raw value, or an empty string leaves that field at its default, and the decode still
    /// succeeds. So old and new formats both load without a version tag.
    static func decoded(from settings: [String]) -> ViewState {
        var state = ViewState()

        if settings.count >= 1, let option = SortOption(rawValue: settings[0]) {
            state.sortOption = option
        }
        if settings.count >= 2, !settings[1].isEmpty {
            let filterStrings = settings[1].split(separator: ",").map(String.init)
            let filters = filterStrings.compactMap { FilterOption(rawValue: $0) }
            state.filterOptions = Set(filters.filter { $0 != .none })
        }
        if settings.count >= 3, let direction = SortDirection(rawValue: settings[2]) {
            state.sortDirection = direction
        }
        /// Element [3] is the list view style: "list" is true, and absent or empty is false. Older
        /// three-element arrays fall through here and get the grid.
        if settings.count >= 4 {
            state.isListView = settings[3] == "list"
        }
        /// Element [4] is the section dividers setting: "dividers" is true, and absent or empty is false.
        /// Shorter arrays take the default.
        if settings.count >= 5 {
            state.showSectionDividers = settings[4] == "dividers"
        }

        return state
    }

    /// Encodes this state for storage. Filters are sorted so a given set always produces byte-identical
    /// output, which keeps the debounced writes idempotent.
    var encodedSettings: [String] {
        let filterStr = filterOptions.isEmpty ? ""
            : filterOptions.map(\.rawValue).sorted().joined(separator: ",")
        let listViewStr = isListView ? "list" : ""
        let dividersStr = showSectionDividers ? "dividers" : ""
        return [sortOption.rawValue, filterStr, sortDirection.rawValue,
                listViewStr, dividersStr]
    }
}

// MARK: - View Identifier
enum ViewIdentifier: Hashable, CustomStringConvertible, Sendable {
    case allFilms
    case list(UUID)
    case filmQueue
    case unwatched(UnwatchedCategory)
    case recents(RecentsCategory)
    case reports(ReportsCategory)
    case imports(ImportsCategory)
    case smartList(SmartListType)
    case search
    case savedSearch(UUID)

    /// There is no `listID` accessor. Consumers that need a list ID already match `case .list(let id)` in a
    /// switch, so an accessor would add nothing.

    var recentsCategory: RecentsCategory? {
        if case .recents(let category) = self { return category }
        return nil
    }

    var unwatchedCategory: UnwatchedCategory? {
        if case .unwatched(let category) = self { return category }
        return nil
    }
    
    var smartListType: SmartListType? {
        if case .smartList(let type) = self { return type }
        return nil
    }

    /// True for the views whose order is part of what they are, so their Sort menu's options and direction
    /// are locked: every Recents tab, and "Upcoming Releases", which lists the soonest release first
    /// (DataCoordinator.performLoad). Filters, style and section dividers stay the user's to set.
    var hasFixedSort: Bool {
        switch self {
        case .recents: return true
        case .smartList(let type): return type == .upcomingReleases
        default: return false
        }
    }

    /// The release format that this view's Date Last Purchased sort and section bands read purchases from.
    /// nil means every format. It is set only on the Purchased 4K, Blu-ray, and DVD lists, where a purchase
    /// of another format does not belong. For example, a Blu-ray bought last year must not band a film into
    /// Past Year in Purchased 4K when its 4K copy was bought in 2020.
    var purchaseFormatScope: ReleaseFormat? { smartListType?.purchaseFormat }

    /// The SF Symbol for the GalleryTitleBar glyph of this view. Recents uses its active category's glyph.
    /// Reports and Imports never show this glyph, but the switch is exhaustive, and the compiler checks it.
    var glyph: String {
        switch self {
        case .allFilms: return ViewGlyphs.allFilms.filled
        case .smartList: return ViewGlyphs.smartList.filled
        case .list: return ViewGlyphs.userList.outline
        case .search: return ViewGlyphs.search.outline
        case .savedSearch: return ViewGlyphs.savedSearch.outline
        case .recents(let category): return category.glyph
        case .filmQueue: return ViewGlyphs.filmQueue.outline
        case .unwatched: return ViewGlyphs.unwatched.filled
        case .reports: return ViewGlyphs.reports.filled
        case .imports: return ViewGlyphs.importsTitleBarFallback.outline
        }
    }

    /// The key under which this view's sort and filter state is stored in Preferences.viewSortStates, or nil
    /// for views that do not store it. Those are `.list` (persisted in the database, under its own rules),
    /// `.reports` and `.imports` (not gallery-backed), and `.search` (always transient). loadStateSync,
    /// saveStateImmediately, and snapshotAllViewSortStates all use this key.
    ///
    /// This is the base key only. The Film Queue's four tabs narrow the films without changing the
    /// ViewIdentifier, but each has its own state. ViewStateKey.persistenceKey adds the tab's token to this
    /// base. Callers go through a ViewStateKey, never this property.
    var persistenceKey: String? {
        switch self {
        case .allFilms: return "allFilms"
        case .unwatched(let category): return "unwatched.\(category.rawValue)"
        case .recents(let category): return "recents.\(category.rawValue)"
        case .smartList(let type): return "smartList.\(type.rawValue)"
        case .filmQueue: return "filmQueue"
        case .savedSearch(let id): return "savedSearch.\(id.uuidString)"
        case .list, .reports, .imports, .search: return nil
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }

    /// Whether an empty result is a normal state for this view, shown with its own placeholder in
    /// GalleryView, rather than an empty library. The rule follows the view that the film pipeline currently
    /// reflects, not the sidebar item, because during a search exit the two briefly differ. This is the only
    /// home of the rule. Being exhaustive, with no default, forces an update when a new ViewIdentifier case
    /// is added.
    var treatsEmptyAsValidState: Bool {
        switch self {
        case .recents, .smartList, .filmQueue, .unwatched, .savedSearch:
            return true
        case .allFilms, .list, .reports, .imports, .search:
            return false
        }
    }

    var description: String {
        switch self {
        case .allFilms: return "AllFilms"
        case .list(let id): return "List(\(id.uuidString.prefix(8)))"
        case .filmQueue: return "FilmQueue"
        case .unwatched(let category): return "Unwatched(\(category.rawValue))"
        case .recents(let category): return "Recents(\(category.rawValue))"
        case .reports(let category): return "Reports(\(category.rawValue))"
        case .imports(let category): return "Imports(\(category.rawValue))"
        case .smartList(let type): return "SmartList(\(type.rawValue))"
        case .search: return "Search"
        case .savedSearch(let id): return "SavedSearch(\(id.uuidString.prefix(8)))"
        }
    }

    // MARK: - Canonical SidebarItem Translation
    ///
    /// Single authoritative conversion from a SidebarItem to the corresponding ViewIdentifier, including
    /// resolution of all sub-variant states (recents category, rotation variant, purchased/unpurchased format,
    /// sorting state).
    ///
    /// All callers — GalleryView, MainView, and any future additions — must use this method so that adding a
    /// new SidebarItem case or smart list variant only requires updating this one location.
    @MainActor
    static func from(_ item: SidebarItem) -> ViewIdentifier {
        switch item {
        case .libraryItem(.allFilms):   return .allFilms
        case .libraryItem(.search):     return .search
        case .libraryItem(.unwatched):  return .unwatched(UnwatchedState.shared.selectedCategory)
        case .libraryItem(.recents):    return .recents(RecentsState.shared.selectedCategory)
        case .libraryItem(.reports):    return .reports(ReportsState.shared.selectedCategory)
        case .libraryItem(.imports):    return .imports(ImportsState.shared.selectedCategory)
        case .libraryItem(.filmQueue): return .filmQueue
        case .list(let id):             return .list(id)
        case .savedSearch(let id):      return .savedSearch(id)
        case .smartList(let type):
            /// The sidebar row names the family; its state names the variant on screen. A type with no
            /// variants of its own is its own family, so this resolves to the type itself — which is what the
            /// five per-family branches this replaced did case by case, plus a `default` for the thirteen
            /// sub-variants that never appear as a SidebarItem in the first place.
            return .smartList(SmartListVariantState.shared(for: type).selected)
        }
    }
}

// MARK: - View State Key

/// The storage identity under which a view's ViewState is cached in memory and saved to
/// Preferences.viewSortStates.
///
/// For most views the ViewIdentifier is the whole key, and subTab is nil. The Film Queue is the exception.
/// Its four tabs share one identifier, and subTab selects the tab's section filter, so each tab keeps its own
/// sort, filters, style, and dividers. This is the counterpart of GalleryScrollKey, which does the same job
/// for scroll origins.
struct ViewStateKey: Hashable, Sendable {
    let viewID: ViewIdentifier
    /// Distinguishes sub-tabs that share a ViewIdentifier. It is set only on the Film Queue's three section
    /// tabs. The All tab has nil (see FilmQueueFilter.persistenceToken), and so does every other view.
    let subTab: String?

    init(viewID: ViewIdentifier, subTab: String? = nil) {
        self.viewID = viewID
        self.subTab = subTab
    }

    /// The key for `viewID` as it stands right now, using the Film Queue's live sub-tab from
    /// FilmQueueFilterState. Every reader and writer derives its key through this function, so they all map
    /// views to storage the same way.
    ///
    /// Code that must address a tab other than the live one, such as the Film Queue's own tab switch when it
    /// saves the outgoing tab, uses init(viewID:subTab:) instead.
    @MainActor
    static func current(for viewID: ViewIdentifier) -> ViewStateKey {
        if case .filmQueue = viewID {
            return ViewStateKey(viewID: viewID,
                                subTab: FilmQueueFilterState.shared.selectedFilter.persistenceToken)
        }
        return ViewStateKey(viewID: viewID)
    }

    /// The key under which this state is saved in Preferences.viewSortStates, or nil for views that do not
    /// save it (see ViewIdentifier.persistenceKey). The sub-tab token, when present, follows the same
    /// `base.variant` shape as the Recents, Unwatched, and smart-list keys, so the saved dictionary keeps one
    /// flat namespace.
    var persistenceKey: String? {
        guard let base = viewID.persistenceKey else { return nil }
        guard let subTab else { return base }
        return "\(base).\(subTab)"
    }

    /// Whether the Section Dividers Show and Hide pair is fixed for the tab this key names. It is true for
    /// one tab only, the Film Queue's unnarrowed All tab. Its three Up Next, Soon, and Later bands describe
    /// the view's structure, and GallerySectioning.displayedSectionBreaks always draws them, so no Show or
    /// Hide choice could remove them. Locking the pair On keeps the menu accurate. Every other tab, including
    /// the Queue's three section tabs, keeps the pair free.
    ///
    /// Two places enforce the lock and must agree. loadStateSync forces the stored value On for this key, and
    /// updateShowSectionDividers refuses any change to it. The menu reads the same property, so the display
    /// and the manager follow one rule.
    var lockedSectionDividers: Bool {
        if case .filmQueue = viewID { return subTab == nil }
        return false
    }
}

// MARK: - View Capabilities
///
/// Centralizes every question of the form "does this view support X". Before this, the answers were spread
/// across hand-synced switches in MainView, MenuBar, KeyboardManager, and GalleryView. Now one exhaustive
/// switch, below, defines them, and the consumers read the precomputed flags. Each flag asks a distinct
/// question. Several happen to agree today, but they stay separate so a future view can differ on one without
/// affecting the others. coincidence, and collapsing them would silently reintroduce the same
/// one-flag-serves-two-purposes coupling this type exists to avoid.
struct ViewCapabilities: Sendable {
    /// Whether the RightSidebar and StatusBar chrome is shown beside this view's content. Reports hides it
    /// while its Data Visualizations tab is displayed, and Imports never shows it.
    var showsGalleryChrome: Bool = true
    /// Whether this view can be a destination for search-exit selection preservation
    /// (MainView.handleSearchContentChange). It must be a gallery-backed view whose membership can be checked
    /// directly. Search, Reports, and Imports are excluded.
    var isValidSearchExitDestination: Bool = true
    /// There is no treatsEmptyAsValidState flag here. ViewIdentifier.treatsEmptyAsValidState answers that
    /// question, keyed off the view the pipeline reflects rather than the sidebar item. A copy here would be
    /// set but never read.
    /// Whether the GalleryTitleBar trash menu shows Remove from List, alongside Remove from All Lists and
    /// Delete from Library. It is true for a user list or the Film Queue, where removing from this list is a
    /// distinct operation from removing from every list.
    var showsRemoveFromListInTrashMenu: Bool = false
    /// Whether the grid and list view-style toggle is available for this view.
    var supportsListGridToggle: Bool = true
    /// Whether the Sort menu is disabled as a whole for this view. Per-option disabling, such as Unwatched's
    /// Last Viewed and Rating, is separate and handled by SortMenuInputs.disabledSortOptions.
    var sortMenuFullyDisabled: Bool = false
    /// Whether the Filter menu is disabled in its entirety for this view.
    var filterMenuFullyDisabled: Bool = false
    /// Whether this view can draw sort-derived section dividers, and so whether its Show and Hide pair means
    /// anything. It is false only for Reports and Imports, which are not gallery-backed. They have no film
    /// list to band and no ViewState to store the choice in. Every gallery-backed view, including the
    /// fixed-sort Recents tabs, is true.
    var supportsSectionDividers: Bool = true
    /// Whether Cmd+A and Select All select every film in this view. It is true for every gallery-backed view,
    /// and false for Reports and Imports.
    var supportsMultiSelection: Bool = true
    /// Whether Tab-key focus routing targets this view's gallery grid/list directly.
    var routesTabFocusToGallery: Bool = true
}

extension SidebarItem {
    /// The single source of truth for every capability above. A new SidebarItem case updates this switch,
    /// which is exhaustive, so the compiler makes sure no case is missed. The consumers elsewhere update
    /// automatically.
    @MainActor
    var capabilities: ViewCapabilities {
        switch self {
        case .libraryItem(.allFilms):
            return ViewCapabilities()

        case .libraryItem(.search):
            return ViewCapabilities(isValidSearchExitDestination: false)

        case .savedSearch:
            return ViewCapabilities()

        case .libraryItem(.unwatched):
            return ViewCapabilities()

        case .libraryItem(.recents):
            return ViewCapabilities(
                sortMenuFullyDisabled: true)

        case .libraryItem(.reports):
            return ViewCapabilities(
                showsGalleryChrome: ReportsState.shared.displayedCategory != .dataVisualizations,
                isValidSearchExitDestination: false,
                supportsListGridToggle: false,
                sortMenuFullyDisabled: true,
                filterMenuFullyDisabled: true,
                supportsSectionDividers: false,
                supportsMultiSelection: false,
                routesTabFocusToGallery: false)

        case .libraryItem(.imports):
            return ViewCapabilities(
                showsGalleryChrome: false,
                isValidSearchExitDestination: false,
                supportsListGridToggle: false,
                sortMenuFullyDisabled: true,
                filterMenuFullyDisabled: true,
                supportsSectionDividers: false,
                supportsMultiSelection: false,
                routesTabFocusToGallery: false)

        case .libraryItem(.filmQueue):
            return ViewCapabilities(
                showsRemoveFromListInTrashMenu: true,
                routesTabFocusToGallery: false)

        case .smartList(let type):
            return ViewCapabilities(sortMenuFullyDisabled: ViewIdentifier.smartList(type).hasFixedSort)

        case .list:
            return ViewCapabilities(showsRemoveFromListInTrashMenu: true)
        }
    }
}

// MARK: - Subcategory View State

/// Conformed to by every singleton (RecentsState, UnwatchedState, and any future addition) that manages a
/// sidebar item's own set of sub-tabs and needs its initial-load/reset lifecycle synchronized with sidebar
/// navigation.
///
/// GalleryView.handleSidebarChange loops over every conforming state once, so each state's
/// `was<X>`/`is<X>` booleans and its ensureInitialViewLoad/resetInitialization call are
/// written in one place. Adding a subcategory-tab view means adding the state to that array
/// (see GalleryView's `subcategoryStates`); the loop itself does not change.
@MainActor
protocol SubcategoryViewState: AnyObject {
    /// The SidebarItem this state's sub-tabs are scoped to (e.g. .libraryItem(.recents)).
    var scopedSidebarItem: SidebarItem { get }
    /// Called when the sidebar switches INTO this state's scoped view, if this is the first visit since the
    /// state was last reset — ensures the initial sub-tab's view actually loads (mirrors the
    /// RecentsCategory/UnwatchedCategory pattern where the ViewIdentifier sub-case, not the SidebarItem,
    /// drives the load).
    func ensureInitialViewLoad()
    /// Called when the sidebar switches AWAY from this state's scoped view, so the next visit triggers
    /// ensureInitialViewLoad() again.
    func resetInitialization()
}

// MARK: - Gallery Scroll Position Handoff (Search Exit / Grid ⟷ List Toggle)
///
/// Lets ViewStateManager ask the gallery style on screen which film is topmost in its viewport, so a style
/// toggle can hand that film to the new style and keep the relative scroll position. It is declared here so
/// this file stays AppKit-free. The two conforming coordinators, in GallerySubview and GalleryListView, live
/// beside their own NSView code.

/// A gallery style's coordinator conforms to this, so ViewStateManager can ask what is on top without
/// importing AppKit.
@MainActor
protocol GalleryScrollPositionProviding: AnyObject {
    /// Returns the film ID that is topmost, and for a multi-column grid row leftmost, in the viewport. It
    /// returns nil if no films are laid out yet, such as an empty view or unavailable geometry.
    func topmostVisibleFilmID() -> UUID?

    /// Returns the scroll key of what this gallery is displaying (see `displayedScrollKey`) and its live
    /// scroll position. It returns nil if the coordinator has not yet rendered a view.
    ///
    /// Both halves matter. The origin is banked for the outgoing view at the moment of a switch (see
    /// prepareScrollHandoff). The view identity verifies that banking. SwiftUI can mount the destination
    /// gallery before the outgoing one is dismantled, and an unverified read would file the destination's
    /// zero under the outgoing key. Returning nil before the first update pass avoids the same problem, since
    /// a new coordinator's default currentViewID must never be trusted.
    func currentScrollState() -> (key: GalleryScrollKey, position: GalleryScrollPosition)?

    /// Scrolls so the section band that begins with `firstFilmID` sits at the top of the viewport. It backs
    /// the Jump to Section submenu.
    ///
    /// The band is addressed by its first film, because both styles can resolve a film, and that holds even
    /// if the films reload between the menu being built and an item chosen. Each style places the band at the
    /// top, or the film if no band precedes it, such as when bands were turned off in between.
    func scrollToSectionBand(firstFilmID: UUID)
}

// MARK: - Gallery Scroll Key
/// The storage identity under which a gallery's scroll origin is banked and restored. It works like
/// ViewStateKey. For most views the ViewIdentifier alone is the key. The Film Queue's four tabs share one
/// identifier, and they narrow the films without changing the active view. Keyed on the identifier alone, all
/// four would share one slot and swap offsets. So subTab carries the section filter, and each tab gets its
/// own slot.

/// The storage identity under which a gallery's scroll origin is banked and restored.
///
/// For every view whose sub-tabs are distinct `ViewIdentifier` cases — the Recents categories, both Unwatched
/// tabs, and every smart-list variant — this is just the view identifier and `subTab` is nil. The Film Queue
/// is the one view whose user-facing tabs (All / Up Next / Soon / Later) all share the single `.filmQueue`
/// identifier: they narrow the loaded film set without ever changing the active view, so keying on the
/// identifier alone made all four sections share one slot and hand each other's offsets back and forth.
/// `subTab` carries the active section filter for that view, and only that view, so each Queue tab gets its
/// own slot exactly like every other sub-tab in the app.
struct GalleryScrollKey: Hashable, Sendable {
    let viewID: ViewIdentifier
    /// Distinguishes sub-tabs that share a single ViewIdentifier. It is set only for `.filmQueue`, and nil
    /// for every other view.
    let subTab: String?

    init(viewID: ViewIdentifier, subTab: String? = nil) {
        self.viewID = viewID
        self.subTab = subTab
    }

    /// The key for `viewID` as it stands right now, resolving the Film Queue's sub-tab from the live
    /// FilmQueueFilterState. Used by the switch side (switchToViewSync, the style toggle). The galleries do
    /// NOT use it: they key by what they are displaying (`displayedScrollKey`, built from the filter their
    /// films were loaded with), because the live filter flips two turns before the films it selects arrive.
    ///
    /// Callers that must key against a sub-tab OTHER than the live one — the Film Queue's own tab switch,
    /// which has to bank the outgoing section before flipping the filter — construct the key explicitly via
    /// `init(viewID:subTab:)` instead.
    @MainActor
    static func current(for viewID: ViewIdentifier) -> GalleryScrollKey {
        if case .filmQueue = viewID {
            return GalleryScrollKey(viewID: viewID,
                                    subTab: FilmQueueFilterState.shared.selectedFilter.rawValue)
        }
        return GalleryScrollKey(viewID: viewID)
    }
}

/// A banked gallery scroll position: the viewport origin and the film it was anchored on.
///
/// The origin alone is a pixel offset, and it means something only for the same geometry. The grid's column
/// count depends on the window width and the Large Grid preference, so a raw offset restored after a column
/// change lands on different films. Films added or removed while away shift it too. So the anchor records the
/// topmost visible film, its index, how many films there were, and where the viewport began within that
/// film's frame. The restore is laid out again against the current geometry. See `restoreY`. Both gallery
/// styles capture and resolve it through their coordinators.
struct GalleryScrollPosition: Equatable, Sendable {
    let origin: CGPoint
    /// nil when nothing was laid out, or the view was at the top (which needs no anchor).
    let anchor: Anchor?

    struct Anchor: Equatable, Sendable {
        let filmID: UUID
        /// The film's index in the displayed films when the position was taken.
        let index: Int
        /// How many films were displayed then.
        let filmCount: Int
        /// Where the viewport began, relative to the film's frame and in units of its height: 0 at its top
        /// edge, negative when the viewport began in the gap above it.
        let fraction: CGFloat
    }

    init(origin: CGPoint, anchor: Anchor? = nil) {
        self.origin = origin
        self.anchor = anchor
    }

    /// The content y to restore to, unclamped. The caller clamps it to the scroll range.
    ///
    /// 1. A view left at the top reopens at the top. 2. The anchor film, if it sits where films added or
    /// removed around it would put it. This keeps the same films after an import,
    ///    a deletion, or a column change.
    /// 3. Otherwise the film now at the saved index, which keeps the same region. If the anchor film moved on
    /// its own, such as after
    ///    an edit re-sorted it, following it would carry the user elsewhere.
    /// 4. The raw origin, when no film can be measured.
    ///
    /// - Parameters:
    ///   - filmCount: Films displayed now.
    ///   - indexOf: A film's index in the displayed films now, or nil if absent.
    ///   - frameOfFilm: The content-space frame of the film at an index, or nil.
    func restoreY(filmCount: Int, indexOf: (UUID) -> Int?, frameOfFilm: (Int) -> CGRect?) -> CGFloat {
        guard origin.y > 0 else { return 0 }
        guard let anchor, filmCount > 0 else { return origin.y }
        let index: Int
        if let current = indexOf(anchor.filmID),
           abs(current - anchor.index) <= abs(filmCount - anchor.filmCount) {
            index = current
        } else {
            index = min(anchor.index, filmCount - 1)
        }
        guard let frame = frameOfFilm(index), frame.height > 0 else { return origin.y }
        return frame.minY + anchor.fraction * frame.height
    }
}

/// How the list places its pending scroll target once it resolves in viewWillDraw(). `.forceTop` puts the
/// film's row at the top of the viewport, as far as the content allows, even if it was visible. That is the
/// rule for Cmd+L and every handoff. `.ifNeeded` moves the film only if it is off screen. It is used for the
/// list's post-edit keep-in-view, so a visible film is not moved. The grid always places handoffs at the top,
/// and does its post-edit check inline.
enum PendingScrollBehavior: Sendable {
    case ifNeeded
    case forceTop
}

/// Records a film that the next gallery scroll view mounted for the addressed view should place in the top
/// row of its viewport. It goes as far up as the content allows, as Cmd+L does, even if the film was visible.
/// Producers:
///
///   • Search exit with a preserved selection (MainView.handleSearchContentChange), set just before the sidebar flips.
///   • The grid-list toggle (ViewStateManager.updateListViewStyle), set just before isListView flips.
///   • Show in List (ShowInListNavigation) and the Film Queue's post-move scroll.
///
/// The targetViewID address is essential. During a search exit, the still-mounted search gallery can update
/// with the full library before MainView's handler runs, and an unaddressed intent would be consumed by that
/// wrong instance. Matching by film ID alone works only in All Films, where the two film sets happen to match
/// without the address. Consumption passes the film ID to the destination's scroll view, which
/// resolves it in its own viewWillDraw() once geometry exists.
@MainActor
final class GalleryScrollIntent {
    static let shared = GalleryScrollIntent()
    private(set) var filmID: UUID?
    private(set) var targetViewID: ViewIdentifier?
    /// Whether an already-mounted gallery's updateNSView may consume this intent, rather than only a fresh
    /// makeNSView.
    ///
    /// It is false for producers that navigate between sidebar items, such as search exit and the grid-list
    /// toggle. Each destination gets a fresh gallery, and the outgoing gallery can still get one update
    /// carrying the destination's activeViewID. That instance must not consume the intent (see
    /// GallerySubview.updateNSView).
    ///
    /// It is true for two producers, where no navigation happens. The single mounted gallery is the
    /// destination, so no other instance can claim the intent:
    ///
    ///   • ShowInListNavigation redirecting to a smart-list sub-variant of the parent being viewed, such as Purchased to Purchased 4K.
    ///   • FilmQueueAssignment.toggle, which places films back in view after a section move reorders the gallery underneath.
    private(set) var consumableOnReuse: Bool = false
    private init() {}

    func set(filmID: UUID,
             targetViewID: ViewIdentifier,
             consumableOnReuse: Bool = false) {
        self.filmID = filmID
        self.targetViewID = targetViewID
        self.consumableOnReuse = consumableOnReuse
    }

    /// Consumes the intent from an already-mounted gallery's update pass, but only if it was explicitly
    /// marked `consumableOnReuse`. Every other intent is left untouched so it survives to the destination's
    /// own makeNSView. See `consumableOnReuse`.
    func consumeOnReuse(ifTargeting viewID: ViewIdentifier) -> UUID? {
        guard consumableOnReuse else { return nil }
        return consume(ifTargeting: viewID)
    }

    /// Consumes and returns the pending film ID if the intent is addressed to `viewID`; otherwise leaves the
    /// intent untouched (so a not-yet-rendered destination can still find it later in the same pass) and
    /// returns nil.
    func consume(ifTargeting viewID: ViewIdentifier) -> UUID? {
        guard let filmID, targetViewID == viewID else { return nil }
        clear()
        return filmID
    }

    /// Discards any pending intent unconditionally. Called at search entry and on the standard
    /// (non-preservation) search-exit path, so an intent that was never consumed (e.g. its destination was
    /// never rendered) cannot linger and trigger an unexpected scroll on a later, unrelated visit to the
    /// targeted view.
    func clear() {
        filmID = nil
        targetViewID = nil
        consumableOnReuse = false
    }

    /// Discards any pending intent NOT addressed to `viewID`. Called from GalleryView.handleSidebarChange
    /// with the destination of a genuine navigation: a stale intent addressed elsewhere (e.g. a view-style
    /// toggle whose destination style never mounted) is invalidated, while an intent addressed to the
    /// destination itself — the search-exit handoff, set immediately before the sidebar flip that triggers
    /// that handler — survives to be consumed by the destination gallery's makeNSView.
    func clear(unlessTargeting viewID: ViewIdentifier) {
        guard targetViewID != viewID else { return }
        clear()
    }
}

/// Records that the next gallery mounted for the addressed view should take keyboard focus — become its
/// window's first responder — as soon as it is on screen.
///
/// One producer: search exit with a preserved selection (MainView.handleSearchContentChange). Before the
/// search the user was navigating the gallery with the keyboard; the search results are a gallery too, and
/// the film they settled on is carried back into the destination as its selection. To the user the gallery
/// never lost focus — a film is highlighted in it — yet the destination is a FRESH gallery instance, and
/// nothing made it first responder: focus stayed wherever the exit left it (the toolbar search field,
/// usually), so the arrow keys did nothing until a Tab press moved focus to where it already appeared to be.
/// This closes that gap: the destination claims focus itself, from the same pre-draw hook that positions its
/// scroll, so keyboard navigation works without any further ado.
///
/// Deliberately separate from `GalleryScrollIntent` rather than a flag on it: the scroll intent has producers
/// that must not move focus (the grid⟷list toggle, Show in List, the Film Queue's post-move scroll), and its
/// reuse path is consumed by an already-mounted gallery's update pass, which must never claim first
/// responder. It is addressed to a ViewIdentifier for the same reason the scroll intent is — the outgoing
/// search gallery can still receive an update pass carrying the destination's activeViewID, and must not be
/// the instance that claims it.
///
/// Consumed by the destination's makeNSView (grid or list, whichever style is active) and honored by that
/// scroll view's viewWillDraw(), once it has a window. Cleared at search entry and on the non-preserving exit
/// path exactly as the scroll intent is, and invalidated by GalleryView.handleSidebarChange for any
/// navigation it is not addressed to, so a request whose destination never mounted cannot steal focus on a
/// later visit.
@MainActor
final class GalleryFocusIntent {
    static let shared = GalleryFocusIntent()
    private(set) var targetViewID: ViewIdentifier?
    private init() {}

    func set(targetViewID: ViewIdentifier) {
        self.targetViewID = targetViewID
    }

    /// Consumes the request if it is addressed to `viewID`; otherwise leaves it untouched and returns false.
    func consume(ifTargeting viewID: ViewIdentifier) -> Bool {
        guard targetViewID == viewID else { return false }
        targetViewID = nil
        return true
    }

    func clear() {
        targetViewID = nil
    }

    func clear(unlessTargeting viewID: ViewIdentifier) {
        guard targetViewID != viewID else { return }
        clear()
    }
}

// MARK: - View State Manager
@MainActor
@Observable
final class ViewStateManager: Loggable {
    nonisolated static let logTag = "[ViewStateManager]"

    static let shared = ViewStateManager()

    // MARK: - Published State
    private(set) var activeView: ViewIdentifier = .allFilms
    private(set) var activeState: ViewState = ViewState()

    // MARK: - Right Sidebar Tab State
    /// Global state for the currently selected right sidebar tab
    var selectedRightSidebarTab: RightSidebarTab = RightSidebarTab.details

    // MARK: - Private Storage
    /// Keyed by ViewStateKey rather than ViewIdentifier so the Film Queue's four segmented tabs each get their
    /// own slot — see ViewStateKey's doc comment.
    private var viewStates: [ViewStateKey: ViewState] = [:]
    private weak var coordinator: DataCoordinator?
    /// One pending debounced save per storage slot, so a change in a second view (or Film
    /// Queue tab) within the debounce window does not cancel the first view's save.
    @ObservationIgnored private var saveTasks: [ViewStateKey: Task<Void, Never>] = [:]
    private let saveDebounceMs: Int = 300

    /// Per-view saved scroll positions (see GalleryScrollPosition) for the maintainScrollPositionOnViewSwitch
    /// feature. Lives here (not in GallerySubview.Coordinator) so it survives the destruction and recreation
    /// of GalleryView instances that occurs on every view switch. Keyed by GalleryScrollKey rather than
    /// ViewIdentifier so the Film Queue's four segmented sections each get their own slot — see
    /// GalleryScrollKey's doc comment.
    ///
    /// Ignored by Observation, as is pendingOriginRestore below: no view renders from either, and every reader
    /// is a gallery coordinator that consults them imperatively. Tracked, they subscribed whichever
    /// updateNSView last read them (the list reads the pending restore on every pass), so each bank or retire
    /// scheduled another gallery update pass for nothing.
    @ObservationIgnored private var savedScrollOrigins: [GalleryScrollKey: GalleryScrollPosition] = [:]

    /// The origin restore armed by the most recent view/sub-tab switch, addressed to the destination's scroll
    /// key. See prepareScrollHandoff for why this exists rather than having the gallery layer infer the switch
    /// for itself. A named type rather than a tuple so it reads clearly at every use site and stays a plain
    /// stored property of this @Observable class.
    private struct PendingOriginRestore {
        let key: GalleryScrollKey
        let position: GalleryScrollPosition
    }
    @ObservationIgnored private var pendingOriginRestore: PendingOriginRestore?

    /// Whichever gallery style (grid or list) currently has its NSViewRepresentable mounted for the active
    /// view. Registered/unregistered by GallerySubview.Coordinator and GalleryListView's Coordinator as they
    /// mount/dismantle — see registerScrollPositionProvider
    /// / unregisterScrollPositionProvider below. Used solely by updateListViewStyle to capture
    /// a grid⟷list scroll-position handoff target; unrelated to savedScrollOrigins above.
    private weak var scrollPositionProvider: (any GalleryScrollPositionProviding)?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        /// Reclaim the two per-view dictionaries above (savedScrollOrigins, viewStates) for a deleted list's
        /// ViewIdentifier. Without this, AppEventBus.listDeleted had no subscriber anywhere in the app, so
        /// every list a user ever created and later deleted left a permanent, unreclaimed CGPoint/ViewState
        /// entry behind for the remainder of the app session — a small but genuine leak for anyone who creates
        /// and prunes lists over time. Both dictionaries are keyed by ViewIdentifier, and
        /// ViewIdentifier.list(_:) is the only case referencing a UUID that can actually be deleted
        /// (recents/reports/imports/smartList cases enumerate fixed, non-deletable categories), so this is a
        /// straightforward, safe removal — the active view is never left mid-display of a list that was just
        /// deleted, since ListManager.deleteList already switches away from it first when it was the one being
        /// viewed.
        AppEventBus.shared.listEvents
            .compactMap { event -> UUID? in
                guard case .deleted(let listID) = event else { return nil }
                return listID
            }
            .sink { [weak self] listID in
                guard let self else { return }
                let viewID = ViewIdentifier.list(listID)
                /// savedScrollOrigins is keyed by GalleryScrollKey; a user list never has a sub-tab, so this
                /// removes the single entry that can exist for it while remaining correct if a future view
                /// gains sub-tabs.
                self.savedScrollOrigins = self.savedScrollOrigins.filter { $0.key.viewID != viewID }
                if self.pendingOriginRestore?.key.viewID == viewID {
                    self.pendingOriginRestore = nil
                }
                /// viewStates is keyed by ViewStateKey; a user list never has a sub-tab, so this removes the
                /// single entry that can exist for it while remaining correct if a future view gains sub-tabs.
                self.viewStates = self.viewStates.filter { $0.key.viewID != viewID }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func setCoordinator(_ coordinator: DataCoordinator) {
        guard self.coordinator == nil else {
            Self.log("Coordinator already registered, ignoring duplicate call")
            return
        }
        self.coordinator = coordinator
        Self.log("DataCoordinator registered")
    }

    // MARK: - Scroll Origin Persistence

    /// Records the scroll origin for the given view so it can be restored on return. Called by both gallery
    /// styles from three points: the end of a user-driven live scroll, the in-place view transition detected
    /// in updateNSView, and dismantleNSView while the scroll view is still live.
    ///
    /// `.search` is refused outright. Search is transient by contract — every entry starts a fresh session
    /// with a different result set — but the gallery that renders its results is an ordinary
    /// GallerySubview/DraggableListView whose currentViewID is `.search`, so without this guard each session
    /// recorded an origin that the NEXT session's fresh mount then restored, dropping the user into the
    /// middle of an unrelated result list. Refusing here — inside the single write path
    /// bankScrollOrigin(_:under:) below, which every save funnels through — keeps the rule in one place
    /// rather than at each of the call sites.
    ///
    /// Takes the gallery's DISPLAYED key rather than a view identifier. For the Film Queue the live filter
    /// flips before the films it selects are loaded, so a key resolved from it described the incoming tab
    /// while the gallery still showed the outgoing one.
    func saveScrollPosition(_ position: GalleryScrollPosition, under key: GalleryScrollKey) {
        bankScrollOrigin(position, under: key)
    }

    /// Banks the on-screen gallery's position under its displayed key. Called by AppState.navigate before
    /// every sidebar flip, while the outgoing gallery is certainly still mounted. A switch banks the same
    /// way, but not every departure switches in time: Reports is switched to by the outgoing GalleryView's
    /// onChange, which SwiftUI does not always run before removing it, and Imports switches from its own
    /// onAppear, after the gallery is gone. Without this, those departures fell back to dismantleNSView,
    /// which cannot record a position at the very top.
    func bankDisplayedScrollPosition() {
        guard let state = scrollPositionProvider?.currentScrollState() else { return }
        bankScrollOrigin(state.position, under: state.key)
    }

    /// The single write path into the origin bank, enforcing the one invariant every caller depends on: a key
    /// whose own restore is still outstanding is never overwritten.
    ///
    /// Between the moment a switch arms a restore and the moment the destination gallery actually applies it,
    /// that gallery's live viewport does NOT represent the user's position for that view — it is sitting at
    /// the zero the pre-reload scroll reset left behind. Any save that reads the live viewport during that
    /// window (a rapid second switch banking the outgoing view, a teardown before the first draw, a search
    /// entered before the destination painted) would therefore bank a synthetic zero directly over the very
    /// value the pending restore is holding, and the position would be lost for good. Refusing the write is
    /// always correct here: the banked value and the pending restore are the same number, so there is nothing
    /// the live viewport could contribute.
    ///
    /// The one caller that legitimately supersedes a pending restore — the live-scroll recorder, where the
    /// user has taken the viewport over by hand — retires the intent FIRST and then saves, so it passes this
    /// guard rather than being blocked by it.
    ///
    /// Inert whenever the preference is off, since nothing is ever armed then and this reduces to the plain
    /// assignment it replaced.
    private func bankScrollOrigin(_ position: GalleryScrollPosition, under key: GalleryScrollKey) {
        guard !key.viewID.isSearch else { return }
        guard pendingOriginRestore?.key != key else { return }
        savedScrollOrigins[key] = position
    }

    /// There is deliberately no public read accessor for the origin bank. A restore is obtained only through
    /// pendingScrollOriginRestore(for:), so only an origin a switch has actually armed can be applied. A direct
    /// read would let callers apply a saved origin at any time, which is the misuse this section prevents.

    /// Discards the saved scroll origin for the given view. Private, and deliberately so: its one and only
    /// legitimate use is updateListViewStyle invalidating an origin measured in the outgoing style's geometry
    /// (see its call site). Every other way to retire a banked origin goes through the handoff machinery
    /// above, which keeps the bank and the pending restore consistent; a public unbanking entry point would
    /// invite exactly the ad-hoc use that discipline exists to prevent.
    private func clearSavedScrollOrigin(for viewID: ViewIdentifier) {
        savedScrollOrigins.removeValue(forKey: GalleryScrollKey.current(for: viewID))
    }

    // MARK: - Scroll-Position Handoff (View and Sub-Tab Switches)
    ///
    /// The gallery layer does not infer view switches from film-array heuristics. That inference worked for a
    /// fresh mount, but not for a sub-tab switch, where the same gallery is reused and the transition and the
    /// film reload may fall on different passes. These two methods record both facts where they are known.
    /// Every switch funnels through prepareScrollHandoff, which banks the outgoing position and arms the
    /// incoming one in one step. The gallery layer only asks whether a restore is addressed to what it
    /// displays, and reports back once it has applied one. A restore therefore survives any number of passes
    /// and is never applied twice.

    /// Banks the outgoing view's live scroll origin and arms the incoming view's saved origin for restore.
    /// Call immediately BEFORE the switch is enacted, while the outgoing gallery is still the registered
    /// scroll-position provider.
    ///
    /// - Parameters:
    ///   - fromKey: The key of the view/sub-tab being left, or nil when there is nothing to
    ///     bank (no prior view).
    ///   - toKey: The key of the view/sub-tab being entered.
    func prepareScrollHandoff(fromKey: GalleryScrollKey?, toKey: GalleryScrollKey) {
        /// Bank the outgoing position, but only on the provider's own word that it is in fact displaying the
        /// view we think we are leaving. See currentScrollState's doc comment for the mount-ordering hazard
        /// this verification closes.
        if let fromKey, !fromKey.viewID.isSearch,
           let state = scrollPositionProvider?.currentScrollState(),
           state.key == fromKey {
            bankScrollOrigin(state.position, under: fromKey)
        }

        /// Arm the incoming restore. Reading the preference here rather than in the gallery layer makes this
        /// the single gate for the whole feature: when it is off, nothing is ever armed and every consumer is
        /// inert without needing its own check.
        guard !toKey.viewID.isSearch,
              Preferences.maintainScrollPositionOnViewSwitch,
              let position = savedScrollOrigins[toKey] else {
            pendingOriginRestore = nil
            return
        }
        pendingOriginRestore = PendingOriginRestore(key: toKey, position: position)
        /// Kept deliberately. This line pairs with the gallery's "armed" and "applied" logs to form a
        /// three-stage trace: banked, armed, and applied. Banked and armed without applied means the origin
        /// reached the scroll view but was never resolved.
        Self.log("Scroll handoff armed for \(toKey.viewID): \(position.origin)")
    }

    /// Arms a restore for a gallery mounting fresh into `viewID`, when no switch-driven intent is already
    /// outstanding.
    ///
    /// Not every arrival passes through switchToViewSync as a real change. Reports is switched to only by the
    /// outgoing GalleryView's onChange, which SwiftUI does not always run before removing that view. So a
    /// round trip can return to a view that is still considered active, and nothing gets armed. A gallery
    /// remounting in its own view, such as a filter that emptied it and was then cleared, is another such
    /// arrival. This covers both.
    ///
    /// The pendingOriginRestore == nil check keeps this subordinate. An intent armed by an in-flight switch
    /// is authoritative, so it is never overwritten.
    func armScrollOriginRestoreOnMount(for key: GalleryScrollKey) {
        guard !key.viewID.isSearch,
              Preferences.maintainScrollPositionOnViewSwitch,
              pendingOriginRestore == nil else { return }
        guard let position = savedScrollOrigins[key] else { return }
        pendingOriginRestore = PendingOriginRestore(key: key, position: position)
        Self.log("Scroll restore armed on fresh mount for \(key.viewID): \(position.origin)")
    }

    /// Returns the pending restore origin if one is addressed to `key`, WITHOUT consuming it. Deliberately
    /// non-consuming: the gallery arms the value on its scroll view, but the scroll view resolves it later,
    /// pre-draw, and only once real geometry exists. Leaving the intent in place until then means an
    /// intervening reload that resets the viewport is simply re-armed on the next pass rather than silently
    /// losing the restore.
    func pendingScrollOriginRestore(for key: GalleryScrollKey) -> GalleryScrollPosition? {
        /// Re-checked here, not only at arming time. The gallery styles do not observe the preference
        /// themselves, so without this a restore armed before the user turned the preference off could still
        /// fire. This costs one UserDefaults read, and only on passes that reload.
        guard Preferences.maintainScrollPositionOnViewSwitch else { return nil }
        guard let pending = pendingOriginRestore, pending.key == key else { return nil }
        return pending.position
    }

    /// Retires the pending restore for `key` — because it has been applied, because the user has taken the
    /// viewport over with a scroll of their own, or because a film-target handoff supersedes it. Addressed,
    /// so a call from a view the intent was not meant for is a no-op and cannot cancel another view's
    /// restore.
    func finishScrollOriginRestore(for key: GalleryScrollKey) {
        guard let pending = pendingOriginRestore, pending.key == key else { return }
        pendingOriginRestore = nil
    }

    /// Discards any pending restore unconditionally. Private for the same reason as clearSavedScrollOrigin
    /// above: its sole caller is the grid⟷list style toggle, where the film-based handoff replaces origin
    /// restoration entirely. The gallery layer retires a restore through the ADDRESSED
    /// finishScrollOriginRestore(for:) instead, so a call from a view the intent was not meant for cannot
    /// cancel another view's restore.
    private func cancelPendingScrollOriginRestore() {
        pendingOriginRestore = nil
    }

    // MARK: - Scroll Position Provider Registration

    /// Routes a "Jump to Section" choice to whichever gallery style is currently mounted.
    ///
    /// Deferred past the menu's dismissal animation for the same reason every other
    /// reload-or-scroll-triggering menu action in the app is (see deferPastMenuDismissal): the scroll
    /// retargets the clip view and repaints a full viewport of poster tiles, which would otherwise compete
    /// with CoreAnimation's menu teardown frames.
    func jumpToSectionBand(_ target: GallerySectionJumpTarget) {
        Self.log("Jump to section '\(target.section.displayName)'")
        deferPastMenuDismissal { [weak self] in
            self?.scrollPositionProvider?.scrollToSectionBand(firstFilmID: target.firstFilmID)
        }
    }

    /// Registers the currently-mounted gallery style's coordinator as the source for "what's on top" queries.
    /// Called from makeNSView in both GallerySubview and GalleryListView. Unconditional overwrite is correct
    /// here: whichever style mounts most recently is, by definition, the one currently on screen.
    func registerScrollPositionProvider(_ provider: any GalleryScrollPositionProviding) {
        scrollPositionProvider = provider
    }

    /// Unregisters a gallery style's coordinator, but only if it is still the currently-registered provider.
    /// Called from dismantleNSView in both GallerySubview and GalleryListView. The identity check makes this
    /// safe regardless of whether SwiftUI mounts the new style before or after dismantling the old one: if
    /// the new style already registered itself, the old style's dismantle must not clear it.
    func unregisterScrollPositionProvider(_ provider: any GalleryScrollPositionProviding) {
        if scrollPositionProvider === provider {
            scrollPositionProvider = nil
        }
    }

    // MARK: - Right Sidebar Tab Functions

    /// Update the selected right sidebar tab
    func setRightSidebarTab(_ tab: RightSidebarTab) {
        guard selectedRightSidebarTab != tab else { return }
        Self.log("Setting right sidebar tab: \(selectedRightSidebarTab.rawValue) → \(tab.rawValue)")
        selectedRightSidebarTab = tab
    }

    /// Reset right sidebar tab to default (Details)
    func resetRightSidebarTab() {
        guard selectedRightSidebarTab != RightSidebarTab.details else { return }
        Self.log("Resetting right sidebar tab to Details")
        selectedRightSidebarTab = RightSidebarTab.details
    }

    // MARK: - View Switching

    /// Synchronous view switching with state restoration.
    /// - Parameters:
    ///   - viewID: Target view to switch to.
    ///   - sourceViewID: Only consulted when `viewID` is `.search`. The view being left,
    ///     whose grid/list style is used to seed the search session's initial style — see
    ///     the `.search` branch below for the full rationale. Ignored for any other `viewID`.
    func switchToViewSync(_ viewID: ViewIdentifier, matchingStyleOf sourceViewID: ViewIdentifier? = nil) {
        #if DEBUG
        ViewSwitchProbe.record("switch \(activeView) → \(viewID)")
        #endif
        let isViewChange = activeView != viewID
        let oldActiveView = activeView

        /// Bank the outgoing view's scroll position and arm the incoming view's, before anything below can
        /// disturb either. This runs first specifically because it is the last moment at which the outgoing
        /// gallery is unambiguously the one on screen: the reload triggered further down replaces
        /// dataCoordinator.films, after which the still-mounted gallery's viewport no longer describes the
        /// view being left.
        ///
        /// This is the single arming point for every switch that reaches this method — sidebar navigation and
        /// every sub-tab picker alike, since Recents, Unwatched and the smart-list variants all route through
        /// SubcategoryNavigation.performSwitch to get here. (The Film Queue's segmented filter does not change
        /// the active view at all, so it arms its own handoff directly — see
        /// FilmQueueFilterState.selectFilter.)
        if isViewChange {
            prepareScrollHandoff(fromKey: .current(for: oldActiveView),
                                 toKey: .current(for: viewID))
        }

        /// Capture start time only for view changes; non-view-change refreshes are not timed.
        let viewSwitchStartTime: Date? = isViewChange ? Date() : nil

        /// Resolve the new state. Search view intentionally never reads from nor writes to the per-view state
        /// cache: each entry into search starts from defaults, and there is no value in caching a state that
        /// resets on every visit. All other views use the in-memory cache when available, falling back to
        /// storage or defaults.
        let newState: ViewState
        let stateKey = ViewStateKey.current(for: viewID)
        if viewID.isSearch {
            var state = loadStateSync(for: stateKey)

            /// Seeds the grid or list style from the view being left, so search results open in the same style
            /// as the view the user returns to. It is a one-time seed. Search state is never cached, so the
            /// style can still be toggled within the session. viewStates[source] is read first, and
            /// loadStateSync is the fallback for a source not yet visited this session.
            ///
            /// A .search source is ignored and treated as no source. Its slot is always empty, so seeding from
            /// it would reset an in-session toggle. That happens when the RightSidebar's Search button is
            /// pressed while search is already showing.
            if let sourceViewID, !sourceViewID.isSearch {
                let sourceKey = ViewStateKey.current(for: sourceViewID)
                let sourceState = viewStates[sourceKey] ?? loadStateSync(for: sourceKey)
                state.isListView = sourceState.isListView
            } else if activeView.isSearch {
                /// No explicit source was given, but a search session is already active — this is a redundant,
                /// re-entrant call (e.g. the embedded GalleryView's own onAppear-triggered
                /// switchToViewSync(.search), which always fires shortly after MainView's own seeding call
                /// above, once activeView is already .search). Preserve whatever style is currently live —
                /// either the seed the earlier call just set, or an in-session toggle the user already made —
                /// instead of silently reverting to the grid default that loadStateSync always returns for
                /// .search. Sort/filter/query below still resolve fresh every call, matching the existing
                /// "transient" contract for everything except style.
                state.isListView = activeState.isListView
            }

            /// Inject the current SearchController query directly at view-switch time.
            ///
            /// Race condition this fixes: SearchController.triggerSearch() calls updateSearchQuery() which
            /// guards `activeView.isSearch`. When the debounced Task fires before switchToViewSync has
            /// promoted activeView to .search (which happens ~50% of the time on a loaded system), the guard
            /// drops the query silently. The search view then appears but shows no results and never loads.
            ///
            /// By pulling the live query here — while we are already promoting activeView to .search — the
            /// initial state always carries the correct query regardless of whether the debounce Task fires
            /// before or after this call. The subsequent updateSearchQuery() call from the debounce Task
            /// becomes a harmless no-op (guarded by `activeState.searchQuery != query`).
            let pendingQuery = SearchController.shared.getCurrentQuery()
            if !pendingQuery.isEmpty {
                state.searchQuery = pendingQuery
                Self.log("Injected pending search query at view-switch time: \"\(pendingQuery)\"")
            }
            newState = state
            /// Do not cache: search state is always transient.
        } else if let cached = viewStates[stateKey] {
            newState = cached
        } else {
            newState = loadStateSync(for: stateKey)
            viewStates[stateKey] = newState
        }

        /// Discard cached search state when leaving the search view, so a stale .search entry cannot be
        /// served on re-entry.
        if isViewChange && oldActiveView.isSearch {
            viewStates.removeValue(forKey: ViewStateKey(viewID: .search))
        }

        let stateChanged = activeState != newState

        /// Update active view and state.
        activeView = viewID
        activeState = newState

        if isViewChange {
            Self.log("View switch: \(oldActiveView) → \(viewID)")
        }
        if stateChanged {
            Self.log("State change: sort=\(newState.sortOption), filters=\(newState.filterOptions.count), dir=\(newState.sortDirection)")
        }

        /// Reloads when the view changed, the state changed, or the view is in its initial state. The initial
        /// case covers startup, when nothing is loaded yet, and the view is already .allFilms, so neither flag
        /// is set. Without this, the spinner would never clear.
        ///
        /// Empty films alone do not qualify. An empty result is also a valid answer for a view, and re-entrant
        /// navigation calls would reload it again. So the films must also not have been loaded for this view.
        ///
        /// This check runs after activeView and activeState are updated above, since it reads the current
        /// view.
        let needsInitialLoad = coordinator.map { $0.films.isEmpty && $0.loadedViewID != viewID } ?? false
        if isViewChange || stateChanged || needsInitialLoad {
            triggerReloadSync()
        }

        /// Broadcasts on a state change as well as a view change. The MenuBar's Sort By, Filter, and View As
        /// List items each keep a local mirror of activeState. They refresh only from this event, from menu
        /// tracking, and from onAppear. Without this, a launch-time state change that is not a view change
        /// left the mirrors at their defaults. For View As List, the action negates the mirror, so the
        /// shortcut then requested the style already in effect and did nothing.
        ///
        /// stateChanged compares against the value before the assignment, so the event fires only when
        /// something actually differs. The View As List action now also reads the live value, so the two fixes
        /// are independent.
        if isViewChange || stateChanged {
            AppEventBus.shared.viewStateChanged()
        }

        if isViewChange {
            if let start = viewSwitchStartTime {
                let duration = Date().timeIntervalSince(start)
                if duration > 0.001 {
                    Self.log("View switch completed in \(Fmt.fixed(duration * 1000, 1))ms")
                }
            }
        }
    }

    // MARK: - State Updates

    /// Shared tail for the active-state mutators. Caches the mutated state under the active view, schedules a
    /// debounced persist, optionally reloads the film list, and broadcasts the change. Callers mutate
    /// `activeState` first, then invoke this.
    ///
    /// - Parameter reload: Whether to trigger a film reload. The grid/list display
    ///   toggle (`updateListViewStyle`) passes `false` because it reuses the films
    ///   already loaded; all sort/filter mutators use the default `true`.
    private func commitActiveStateChange(reload: Bool = true) {
        viewStates[ViewStateKey.current(for: activeView)] = activeState
        saveStateDebounced()
        if reload { triggerReloadSync() }
        AppEventBus.shared.viewStateChanged()
    }

    /// Banks the outgoing sub-tab's ViewState and promotes the incoming one's, for a transition that changes
    /// the storage slot without changing the active ViewIdentifier.
    ///
    /// Only the Film Queue's segmented picker does this. Its four tabs share one identifier, so
    /// switchToViewSync is never called for them. This is the counterpart of the prepareScrollHandoff call
    /// made for scroll origins.
    ///
    /// Both keys are passed in, since this runs before the filter flips and ViewStateKey.current still names
    /// the outgoing tab.
    ///
    /// No save is scheduled. Each mutation saved itself under its own key when made. This only keeps the
    /// in-memory cache correct for the tab being left.
    func prepareSubTabStateHandoff(fromKey: ViewStateKey, toKey: ViewStateKey) {
        guard fromKey != toKey else { return }
        guard fromKey.viewID == activeView else {
            /// The Queue is not the view on screen, so `activeState` describes something else entirely and
            /// must not be filed under a Queue tab. The incoming tab's state will be resolved by the
            /// switchToViewSync that navigates to the Queue.
            return
        }

        viewStates[fromKey] = activeState

        let incoming = viewStates[toKey] ?? loadStateSync(for: toKey)
        viewStates[toKey] = incoming

        activeState = incoming
        Self.log("Sub-tab state handoff: \(fromKey.subTab ?? "—") → \(toKey.subTab ?? "—")")
        /// Broadcast for the same reason switchToViewSync does on a state change: the MenuBar's Sort By /
        /// Filter / View As List mirrors refresh only on this event. No reload is triggered here — the
        /// caller's own deferred forceReload covers it, and it must run after the filter itself has flipped.
        ///
        /// Unconditional rather than gated on `activeState != incoming`, unlike the equivalent broadcast in
        /// switchToViewSync: the MenuBar also mirrors whether the dividers pair is LOCKED, which is a property
        /// of the tab rather than of its state, and two tabs can hold identical states while differing on it
        /// (the "All" tab locked ON, a section tab the user has set to Show). Gating on the state alone would
        /// leave that mirror describing the tab just left.
        AppEventBus.shared.viewStateChanged()
    }

    /// Records the user's chosen sort. Choosing an option while a fallback is in effect replaces the
    /// remembered choice (see ViewState.effectiveSortOption(in:)); re-clicking the checked fallback is not a
    /// choice — the menu's Toggle never reports it — so the memory survives that.
    func updateSortOption(_ option: SortOption) {
        guard activeState.sortOption != option else { return }
        Self.log("Updating sort option: \(activeState.sortOption) → \(option)")

        activeState.sortOption = option
        commitActiveStateChange()
    }

    func updateFilterOptions(_ filters: Set<FilterOption>) {
        guard activeState.filterOptions != filters else { return }
        Self.log("Updating filters: \(activeState.filterOptions) → \(filters)")

        activeState.filterOptions = filters
        commitActiveStateChange()
    }

    func updateSortDirection(_ direction: SortDirection) {
        guard activeState.sortDirection != direction else { return }
        Self.log("Updating direction: \(activeState.sortDirection) → \(direction)")

        activeState.sortDirection = direction
        commitActiveStateChange()
    }

    func updateListViewStyle(_ isListView: Bool) {
        guard activeState.isListView != isListView else { return }
        Self.log("Updating list view style: \(activeState.isListView) → \(isListView)")

        /// Capture the film currently topmost in the outgoing style's viewport, addressed to the view being
        /// toggled, so the newly-mounted style can restore the same relative scroll position. This MUST run
        /// before flipping isListView below — scrollPositionProvider still points at the outgoing style at
        /// this instant, since SwiftUI hasn't re-rendered yet. A nil result (no provider registered, no films
        /// laid out, or a zero-height viewport) simply means no restoration target is set; the new style then
        /// mounts at its default scroll origin, exactly as it always has.
        if let topFilmID = scrollPositionProvider?.topmostVisibleFilmID() {
            GalleryScrollIntent.shared.set(filmID: topFilmID, targetViewID: activeView)
        }

        /// A saved origin was measured in the outgoing style's geometry. A variable-height grid and a
        /// fixed-height table give different y values for the same place. Both styles share one key per view,
        /// so a style toggle is the one transition that can leave a mismatched origin. The film-based handoff
        /// is the correct cross-style mechanism. Where it cannot run, the new style opens at the top.
        ///
        /// The outgoing style's dismantle may save again under this key. That save is harmless, because it
        /// saves only a non-zero origin, which implies a laid-out viewport where the handoff intent is armed
        /// and takes precedence.
        clearSavedScrollOrigin(for: activeView)

        /// For the same reason, retires any restore that a just-completed switch armed for this view. Its
        /// origin was measured in the outgoing style's geometry, so it must not resolve against the incoming
        /// one.
        cancelPendingScrollOriginRestore()

        activeState.isListView = isListView
        /// No reload needed — the list view reads the same dataCoordinator.films array that the grid already
        /// uses. The view switch is driven by the @Observable property change alone.
        commitActiveStateChange(reload: false)
    }

    /// Forces `showSectionDividers` on for a tab whose dividers are locked, leaving every other tab's stored
    /// value untouched.
    ///
    /// Applied on the way OUT of storage rather than on the way in, deliberately: a stored value written
    /// before the lock existed (or by a build in which this tab was still free) must not be able to present
    /// the locked tab as anything other than locked, and re-deriving it on every read is what guarantees that
    /// without a migration.
    private static func applyingDividerLock(_ state: ViewState, for key: ViewStateKey) -> ViewState {
        guard key.lockedSectionDividers else { return state }
        var locked = state
        locked.showSectionDividers = true
        return locked
    }

    /// The state the gallery should be PRESENTED with: the state of the films it is actually showing. That is
    /// `activeState` everywhere except the Film Queue's tab switch, where selectFilter promotes the incoming
    /// tab's state at once (so the segmented control, the menus and their mirrors follow the click) but
    /// defers the reload that installs its films past the control's animation. Presenting `activeState` in
    /// that window built the incoming tab's grid/list style around the outgoing tab's films — a committed
    /// frame of the wrong content, then a second full reload — and drew its divider setting over them. Until
    /// the films land, the outgoing tab's banked state (prepareSubTabStateHandoff filed it under its own key)
    /// describes them; style and films then change together in one update.
    func displayedGalleryState(loadedQueueFilter: FilmQueueFilter?) -> ViewState {
        if case .filmQueue = activeView, let loaded = loadedQueueFilter,
           loaded != FilmQueueFilterState.shared.selectedFilter,
           let shown = viewStates[ViewStateKey(viewID: .filmQueue, subTab: loaded.persistenceToken)] {
            return shown
        }
        return activeState
    }

    /// The Film Queue "All" tab's view state as it stands this session, wherever the user is: the live state
    /// while that tab is on screen, else the copy banked in memory, else what it would load. For ATVQ's
    /// dispatch order, which must match that tab even when nothing is persisted (rememberSortFilterSelections
    /// off).
    func filmQueueAllTabState() -> ViewState {
        let key = ViewStateKey(viewID: .filmQueue)
        if ViewStateKey.current(for: activeView) == key { return activeState }
        return viewStates[key] ?? loadStateSync(for: key)
    }

    /// Whether the "Section Dividers" Show/Hide pair is fixed for the tab currently on screen — see
    /// ViewStateKey.lockedSectionDividers for the rule and its one subject. Both Sort menu hosts read this to
    /// disable the pair, so what they present and what `updateShowSectionDividers` will accept can never
    /// disagree.
    var sectionDividersLocked: Bool {
        ViewStateKey.current(for: activeView).lockedSectionDividers
    }

    /// Shows or hides this view's sort-derived section dividers.
    ///
    /// Passes `reload: false` for the same reason `updateListViewStyle` does: the bands are computed from the
    /// films already loaded, in the order they are already in, so nothing about the film set or its ordering
    /// changes. Both gallery styles recompute their bands from this value on the update pass the state change
    /// itself triggers, and the Sort menu's "Jump to Section" submenu is rebuilt from the same value the next
    /// time it opens.
    func updateShowSectionDividers(_ showDividers: Bool) {
        /// Refused outright on a tab whose dividers are locked. The menu already disables the pair there, so
        /// this is unreachable through the UI; it is the enforcement half of the rule regardless, so no future
        /// caller can write a value the view cannot honor.
        guard !sectionDividersLocked else {
            Self.log("Ignoring section-dividers change — locked for \(activeView.description)")
            return
        }
        guard activeState.showSectionDividers != showDividers else { return }
        Self.log("Updating section dividers: \(activeState.showSectionDividers) → \(showDividers)")

        activeState.showSectionDividers = showDividers
        commitActiveStateChange(reload: false)
    }

    func updateSearchQuery(_ query: String) {
        /// Only update search query if we're in the search view. This prevents unnecessary reloads and
        /// placeholder flashing when switching away from search.
        guard activeView.isSearch else {
            Self.log("Ignoring search query update - not in search view (current: \(activeView))")
            return
        }
        
        guard activeState.searchQuery != query else { return }
        activeState.searchQuery = query
        viewStates[ViewStateKey.current(for: activeView)] = activeState
        triggerReloadSync()
    }

    func clearFilters() {
        guard !activeState.filterOptions.isEmpty else { return }
        activeState.filterOptions = []
        commitActiveStateChange()
    }

    func clearSearch() {
        guard !activeState.searchQuery.isEmpty else { return }

        if activeView.isSearch {
            /// Reset the search view to defaults so the next search starts fresh — but deliberately carry the
            /// grid/list style across, rather than taking ViewState()'s grid default for it.
            ///
            /// Style is the one field of a search session's state that is not transient by contract.
            /// switchToViewSync seeds it from the view being left, precisely so results appear in the same
            /// style as the destination the user returns to on exit, and preserves it across a re-entrant
            /// switch so an in-session toggle survives. Resetting it here contradicted both: clearing the
            /// query from the No Results placeholder while in list style flipped the gallery to grid for the
            /// frames between this call and the search-exit navigation that follows. Sort, filters, dividers
            /// and the query itself are genuinely transient and are still reset.
            let preservedStyle = activeState.isListView
            activeState = ViewState()
            activeState.isListView = preservedStyle
            Self.log("Search cleared - reset search view to defaults (style preserved: isListView=\(preservedStyle))")
        } else {
            /// For other views, just clear the search query.
            activeState.searchQuery = ""
        }

        /// Routed through the shared tail rather than a bare triggerReloadSync(), so this broadcasts
        /// viewStateChanged() like every other mutator. Without it the MenuBar's Sort By / Filter / View As
        /// List mirrors — which refresh only on that event, on NSMenu.didBeginTracking, and on their own
        /// onAppear — kept describing the state this method had just discarded. See the broadcast rationale in
        /// switchToViewSync.
        commitActiveStateChange()
    }

    /// Clears this view's filters AND its search query in a single committed change.
    ///
    /// The "No Results" placeholder's Clear Query action needs both. Calling `clearFilters()` and
    /// `clearSearch()` in sequence performed the work correctly but committed twice, costing two full
    /// `loadFilms` passes for one click — on top of the third the ensuing search-exit navigation triggers.
    /// Mutating both fields before the single commit collapses that to one.
    func clearFiltersAndSearch() {
        let hadFilters = !activeState.filterOptions.isEmpty
        let hadQuery = !activeState.searchQuery.isEmpty
        guard hadFilters || hadQuery else { return }

        /// A query clear on the search view resets that view wholesale (style excepted), so it already
        /// subsumes the filter clear; delegate to keep that rule in one place.
        guard !(hadQuery && activeView.isSearch) else {
            clearSearch()
            return
        }

        activeState.filterOptions = []
        activeState.searchQuery = ""
        commitActiveStateChange()
    }

    func forceReload() {
        triggerReloadSync()
    }

    /// Replays the film load for the active view once DataCoordinator finishes initializing. It is called
    /// once, from finalizeInitialization().
    ///
    /// Nothing can load while MemoryStore is still building, so performLoad refuses early requests. That
    /// window is short, but the user can already navigate or search during it. The manager is then pointed at
    /// the destination with the correct state, and only the load is outstanding. This completes it, so an
    /// in-flight search resolves as soon as the library is ready.
    ///
    /// All Films is excluded. finalizeInitialization has already published its pre-warmed content, and
    /// activeState has not yet been resolved from storage. Reloading here would use the default sort and
    /// briefly show All Films in the wrong order. The view's switchToViewSync applies the saved state. Any
    /// other view has already been switched to explicitly, so its state is resolved.
    func resyncAfterInitialization() {
        guard activeView != .allFilms else { return }
        Self.log("Initialization completed while \(activeView.description) was active — replaying deferred load")
        triggerReloadSync()
    }

    /// Returns an encoded snapshot of all currently-loaded view sort/filter states in the same
    /// [String:[String]] format written to Preferences.viewSortStates. Only views that have been visited (and
    /// thus loaded into the in-memory cache) during the current session are included. User-created list states
    /// are excluded intentionally — they are persisted independently in the database and are unaffected by
    /// rememberSortFilterSelections.
    ///
    /// Called by STabGeneral when the rememberSortFilterSelections preference is re-enabled so that the
    /// current runtime selections survive the next restart.
    func snapshotAllViewSortStates() -> [String: [String]] {
        var result = [String: [String]]()
        for (stateKey, state) in viewStates {
            guard let key = stateKey.persistenceKey else { continue }
            result[key] = state.encodedSettings
        }
        Self.log("snapshotAllViewSortStates: captured \(result.count) entries")
        return result
    }

    // MARK: - Private Methods

    private func loadStateSync(for stateKey: ViewStateKey) -> ViewState {
        let viewID = stateKey.viewID
        switch viewID {
        case .list(let listID):
            guard let coordinator = coordinator else {
                Self.log("WARNING: No coordinator, using defaults for list \(listID)")
                return ViewState()
            }
            if let list = coordinator.getList(listID) {
                return ViewState.decoded(from: list.sortFilterOptions)
            } else {
                Self.log("WARNING: List \(listID) not found, using defaults")
                return ViewState()
            }

        case .recents(let category):
            /// Recents views have fixed sorting (per-category sortOption, always descending). However, filter
            /// selections and the list view style ARE user-configurable and must survive re-launches. Load
            /// persisted options for this category from the consolidated view-sort-states dictionary, but
            /// always enforce the fixed sort option and direction so stored data can never overwrite them.
            var state = ViewState()
            state.sortOption = category.sortOption
            state.sortDirection = .descending /// Most recent first
            if let key = stateKey.persistenceKey, let stored = Preferences.viewSortStates[key] {
                /// The decode populates all fields; we take filterOptions, isListView and showSectionDividers,
                /// then immediately overwrite sort/direction to enforce the fixed values. The dividers flag
                /// belongs with the user-configurable three: a Recents view's sort is fixed, but the bands
                /// that sort produces are still the user's to show or hide.
                let parsed = ViewState.decoded(from: stored)
                state.filterOptions = parsed.filterOptions
                state.isListView = parsed.isListView
                state.showSectionDividers = parsed.showSectionDividers
            }
            return state

        case .smartList(.upcomingReleases):
            /// Fixed like Recents: ordered by each film's soonest upcoming release, which no SortOption
            /// expresses, so `.title` is stored as a placeholder (the order ties fall back to) and the Sort
            /// menu checks nothing (see SortMenuInputs.displayedSortOption). Ascending, soonest first. The
            /// other fields are the user's and persist as they do for any smart list.
            var state = ViewState()
            if let key = stateKey.persistenceKey, let stored = Preferences.viewSortStates[key] {
                state = ViewState.decoded(from: stored)
            }
            state.sortOption = .title
            state.sortDirection = .ascending
            return state

        case .reports, .imports, .search:
            /// These views don't use persisted ViewState: Reports and Imports are not gallery-backed and
            /// manage their own data independently, and Search is always transient (in-session changes are
            /// allowed but never persisted).
            return ViewState()

        case .allFilms, .unwatched, .smartList, .filmQueue, .savedSearch:
            /// Persisted per-view (allFilms), per-tab (unwatched, filmQueue), or per-type (smartList) in the
            /// consolidated view-sort-states dictionary, via the shared ViewStateKey.persistenceKey.
            /// Membership for unwatched/smartList is always computed at runtime, and the Film Queue's section
            /// membership is resolved at runtime too — neither is affected by this stored sort/filter state.
            /// (The Queue's segmented section filter, by contrast, is exactly what selects which of its four
            /// slots is being read here.)
            guard let key = stateKey.persistenceKey,
                  let stored = Preferences.viewSortStates[key] else {
                return Self.applyingDividerLock(ViewState(), for: stateKey)
            }
            return Self.applyingDividerLock(ViewState.decoded(from: stored), for: stateKey)
        }
    }

    private func saveStateDebounced() {
        /// Capture the storage key and state at the moment the debounce is requested, not when the async block
        /// eventually fires. Without this capture, a view switch that occurs within the debounce window would
        /// cause saveStateImmediately() to read the NEW view's activeView/activeState and persist it under the
        /// PREVIOUS view's storage key — silently corrupting both views' saved state. Capturing a ViewStateKey
        /// rather than a ViewIdentifier extends that protection to a Film Queue TAB switch, which changes the
        /// storage slot without changing the view.
        let capturedKey = ViewStateKey.current(for: activeView)
        let capturedState = activeState
        saveTasks[capturedKey]?.cancel()
        saveTasks[capturedKey] = Task { [capturedKey, capturedState] in
            try? await Task.sleep(for: .milliseconds(saveDebounceMs))
            guard !Task.isCancelled else { return }
            saveTasks[capturedKey] = nil
            saveStateImmediately(key: capturedKey, state: capturedState)
        }
    }

    private func saveStateImmediately(key stateKey: ViewStateKey, state: ViewState) {
        let settings = state.encodedSettings
        let view = stateKey.viewID

        switch view {
        case .list(let listID):
            /// User-created list state is always persisted to the database regardless of
            /// rememberSortFilterSelections; it is governed independently by the list object.
            guard let coordinator = coordinator else {
                Self.log("WARNING: No coordinator, cannot save list settings")
                return
            }
            coordinator.updateList(
                listID: listID,
                name: nil,
                displayOrder: nil,
                sortFilterOptions: settings
            )
            Self.log("Saved list \(listID.uuidString.prefix(8)) state: \(settings)")

        case .reports, .imports:
            /// Reports and Imports are not gallery-backed and manage their own data / ordering; there is no
            /// per-view sort/filter state to persist here.
            break

        case .search:
            /// Search state is always transient and is never persisted.
            Self.log("Skipping save for search view (transient state)")

        case .allFilms, .unwatched, .recents, .smartList, .filmQueue, .savedSearch:
            /// All five view kinds persist to the consolidated view-sort-states dictionary via the shared
            /// persistenceKey, governed uniformly by rememberSortFilterSelections. (Recents only has filter
            /// options and list-view style genuinely at stake — sort/direction are fixed by category and are
            /// simply ignored on read-back — but the full encoded settings array is still stored so the
            /// on-disk format stays consistent across every governed view kind.)
            guard let key = stateKey.persistenceKey else {
                Self.log("WARNING: Expected a persistence key for \(view), found none")
                return
            }
            guard Preferences.rememberSortFilterSelections else {
                Self.log("Skipping \(view) save (rememberSortFilterSelections disabled)")
                return
            }
            persistViewSortState(key: key, settings: settings, logLabel: "\(view)")
        }
    }

    /// Atomically merges one key/value into the consolidated view-sort-states dictionary and writes it back
    /// to Preferences. All persisted view categories (.allFilms, .unwatched, .recents, .smartList, .filmQueue)
    /// share this single read-modify-write path.
    private func persistViewSortState(key: String, settings: [String], logLabel: String) {
        var dict = Preferences.viewSortStates
        dict[key] = settings
        Preferences.viewSortStates = dict
        Self.log("Saved \(logLabel) state: \(settings)")
    }

    /// Reload trigger. Delegates the full load to DataCoordinator.loadFilms, which resolves every per-view
    /// membership input itself — recents ordering from MetadataCache (via RecentsCategory.orderedFilmIDs),
    /// smart-list membership from the SmartLists manager, and the Film Queue's single-section display filter
    /// from FilmQueueFilterState — so this layer only supplies the view identity and the user's sort/filter
    /// state.
    private func triggerReloadSync() {
        guard let coordinator = coordinator else {
            Self.log("WARNING: No coordinator, cannot trigger reload")
            return
        }

        /// Imports and Reports views manage their own data independently of the film-loading pipeline. Calling
        /// loadFilms for these views is a no-op that unnecessarily clobbers coordinator.films/filmCount and
        /// produces a misleading "Loaded 0 films" log entry.
        if case .imports = activeView { return }
        if case .reports = activeView { return }

        coordinator.loadFilms(
            viewID: activeView,
            sortOption: activeState.effectiveSortOption(in: activeView),
            filterOptions: activeState.filterOptions,
            direction: activeState.sortDirection
        )
    }
}
