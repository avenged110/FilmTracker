// MARK: - Preferences.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized preferences wrapper used across Film Tracker.app, providing
// a single place to read/write UserDefaults-backed settings.

import Foundation
import SwiftUI

struct Preferences: Loggable {
    nonisolated static let logTag = "[Preferences]"
    // UserDefaults is documented thread-safe but not marked Sendable, so the store is
    // held in `SharedDefaults`, the one place that vouches for it — accessors read it as
    // an ordinary Sendable `let` rather than through a `nonisolated(unsafe)` escape.
    //
    // In a debug sandbox run this resolves to a private suite instead, so a throwaway
    // instance neither reads nor writes the user's real preferences. Resolved once, in a
    // lazy static, and derived purely from launch arguments — see DebugSandbox for why
    // that removes any initialization-order concern. If the suite cannot be opened
    // (a malformed suite name is the only realistic cause, and the name is sanitized),
    // the fallback is `.standard`; the sandbox-integrity harness scenario asserts against
    // that outcome rather than letting it pass unnoticed.
    //
    // The registered defaults are installed HERE, inside the same initializer, so there is
    // no way to reach the suite without them: every accessor below goes through `defaults`,
    // and a lazy static runs its initializer to completion before the first access
    // returns. Registration used to be a separate lazy static that each SETTER forced and
    // only some getters did, which left the guarantee resting on AppDelegate calling
    // ensureDefaultsRegistered() before any early read — a `bool(forKey:)` issued before
    // that returns false for a preference whose registered default is true.
    private static var defaults: UserDefaults { shared.store }
    private static let shared = SharedDefaults({
        let resolved: UserDefaults
        #if DEBUG
        if let suiteName = DebugSandbox.userDefaultsSuiteName,
           let suite = UserDefaults(suiteName: suiteName) {
            resolved = suite
        } else {
            resolved = UserDefaults.standard
        }
        #else
        resolved = UserDefaults.standard
        #endif
        resolved.register(defaults: registered.values)
        return resolved
    }())

    /// The registered defaults, held for `registeredDefault(_:orFallback:)` as well as
    /// registration.
    private static let registered = RegisteredDefaults(registeredDefaults())

    /// Immutable after init and holding only value types (Bool, Int, String and
    /// collections of them), which is the whole of what `@unchecked Sendable` asserts.
    private final class RegisteredDefaults: @unchecked Sendable {
        let values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }
    }

    /// The value `key` is registered with — the one place a preference's default is
    /// written; every other default (an `@AppStorage`'s initial value, a decode fallback)
    /// is read from here. A key that is unregistered or registered as another type is a
    /// programming error: DEBUG stops on it, Release falls back to `fallback`.
    static func registeredDefault<T>(_ key: String, orFallback fallback: T) -> T {
        guard let value = registered.values[key] as? T else {
            assertionFailure("No registered \(T.self) default for '\(key)'")
            return fallback
        }
        return value
    }

    /// The case an Int-backed enum preference is registered with, for a stored raw value
    /// that no longer names a case. The master list writes each of these as
    /// `SomeEnum.someCase.rawValue`, so the lookup cannot fail short of a mistake there.
    private static func registeredCase<E: RawRepresentable>(_ key: String) -> E
    where E.RawValue == Int {
        guard let value = E(rawValue: registeredDefault(key, orFallback: Int.min)) else {
            preconditionFailure("'\(key)' is not registered as a \(E.self) raw value")
        }
        return value
    }

    /// `UserDefaults` is thread-safe (Apple: "you can use a single defaults object from
    /// any thread"), which is the whole of what `@unchecked Sendable` asserts here: the
    /// wrapper adds no state of its own and `store` never changes after init.
    private final class SharedDefaults: @unchecked Sendable {
        let store: UserDefaults
        init(_ store: UserDefaults) { self.store = store }
    }

    /// True when `defaults` is backed by a debug sandbox suite rather than `.standard`.
    /// Exposed so the harness can verify the redirect actually took effect instead of
    /// inferring it from the launch arguments it already knows about.
    static var isUsingSandboxDefaults: Bool {
        #if DEBUG
        return defaults !== UserDefaults.standard
        #else
        return false
        #endif
    }

    /// The store every preference lives in — `.standard`, or a debug sandbox's own suite.
    /// Every `@AppStorage` binds through it via `AppStorage(preference:)` (end of file).
    /// Without it SwiftUI reads and writes `.standard`, so in a sandbox run a Settings
    /// toggle would land in the user's real preferences, views would show the real values
    /// while these statics returned the sandbox's, and the registered defaults (installed
    /// on this store only) would not apply. Named per declaration rather than through
    /// `.defaultAppStorage(_:)`, which reaches neither menu-bar commands nor views hosted
    /// by AppKit.
    static var store: UserDefaults { defaults }

    // MARK: - Internal Testing Switches
    // Every hardcoded behavior toggle in the app, gathered so a testing pass is a set of
    // edits to ONE file rather than a hunt throughout the project. These are build-time
    // constants, not user preferences: nothing in Settings writes them, they are never
    // persisted to UserDefaults, and flipping any of them requires a rebuild.

    /// Reserves the full two lines of the RightSidebar header's film title at all times, so
    /// nothing below it shifts when a title's length changes. `false` keeps the existing
    /// behavior: the title occupies one line and grows to a second only when it wraps.
    /// Implemented in 24.11 Header.swift (RSBHeader's title Text).
    static let reserveTwoLineSidebarTitle = true

    /// `true` makes the FilmSheet Details tab ignore the auto-expand preference and always
    /// load the Viewing Dates table collapsed. `false` honors the preference.
    /// Implemented in 31.10 DetailsView.swift (FSTabDetailsView).
    static let overrideAutoExpandingTablePref = false

    /// Whether the RightSidebar's tab bar draws icons alongside its labels.
    /// Implemented in 24.00 RightSidebar.swift (RightSidebar).
    static let showRightSidebarTabIcons = true

    /// Whether ANY CustomTabs tab bar (RightSidebar, FilmSheet, SettingsSheet) draws icons.
    /// `false` turns them off everywhere, overriding each bar's own `showIcons` (including
    /// `showRightSidebarTabIcons`). Implemented in 94.00 CustomTabs.swift.
    static let showCustomTabIcons = true

    /// TRIAL SWITCH. Caps the "Watch Details" glyph tints at `.secondary`: a glyph beside
    /// primary text is drawn secondary instead of matching it, while one beside tertiary
    /// (placeholder) text stays tertiary. `false` restores the original rule, where a glyph
    /// always takes the exact color of the text it precedes.
    ///
    /// The `opticaldisc.fill` glyph is exempt and stays primary — it denotes a purchased
    /// release, which is a fact about the film rather than decoration on the row.
    /// Implemented in 24.12 WatchDetails.swift (`glyphTint`).
    static let capWatchDetailsGlyphColorAtSecondary = true

    /// Exempts the "Source for Viewing" disc glyph from the user's
    /// `showWatchDetailsAnnotationGlyphs` preference: when `true` the `opticaldisc.fill`
    /// symbol marking a purchased disc-based source is shown whatever that preference says.
    /// When `false` the disc follows the preference like every other glyph in the module.
    ///
    /// The disc is the one glyph that predates the rest — it marked a purchased disc long
    /// before the module had a glyph vocabulary — so it is the one worth being able to keep
    /// while the newer ones are turned off. Implemented in 24.12 WatchDetails.swift
    /// (`sourceValueGlyph`).
    static let purchasedDiscGlyphVisibilityOverride = true

    /// Verbose per-film logging during a ratings import. Enabling it measurably slows the
    /// import. Implemented in 81.00 RatingsImporter.swift.
    static let importRatingsDebugLogging = false

    // MARK: - Centralized Internal Constants
    // Gallery items
    static let cornerRadius: CGFloat = 12
    static let selectionLineWidth: CGFloat = 5
    // Gallery grid column geometry, read by SmoothResizingGridLayout (GalleryViewUI.swift).
    // Narrowest a column may be before the layout drops a column.
    static let galleryMinItemWidth: CGFloat = 130
    // Column-count ceiling: the default, and the one the largeGalleryGrid preference selects.
    static let galleryMaxColumns: Int = 8
    static let galleryMaxColumnsLargeGrid: Int = 6
    // The grid stops widening beyond this and centers itself in the remaining space.
    static let galleryMaxGridWidth: CGFloat = 1500
    // Fixed label-column width for FilmSheet rows (hard-clipped; not a minimum)
    static let filmSheetLabelWidth: CGFloat = 128
    static let filmSheetReleasesLabelWidth: CGFloat = 122
    static let standardPickerWidth: CGFloat = 180
    static let spacingBeforeCheckbox: CGFloat = 20 // Space between Picker/Stepper and checkbox
    static let spacingAfterCheckbox: CGFloat = 6   // Space between checkbox and label text
    // Normalized poster sizes and quality.
    static let normalizedPosterWidth: CGFloat = 120
    static let normalizedPosterHeight: CGFloat = 180
    static let normalizedPosterQuality: CGFloat = 0.9
    // MainWindow dimension parameters.
    // NOTE: Both are applied directly to the main content area's frame instead of the
    // NavigationSplitView's to avoid layout bugs when unhiding the left sidebar.
    static let minimumWidth: CGFloat = 820
    static let minimumHeight: CGFloat = 600
    // Consistent sheet dimensions.
    static let sheetSize: CGFloat = 600
    // Button sizing constants.
    static let buttonWidth: CGFloat = 30
    static let buttonSpacing: CGFloat = 30
    // Shared chrome width for the "Select Destination…" (Export tab) and "Select Backup
    // File…" (Restore tab) buttons, so the two carry identical widths despite their labels
    // measuring subtly differently — "Select Destination…" 121pt, "Select Backup File…" 122pt.
    static let settingsSelectButtonWidth: CGFloat = 122
    // Consistent custom colors for UI chrome.
    static let green = Color(red: 0.2, green: 0.7, blue: 0.2)
    static let red = Color(red: 0.7, green: 0, blue: 0)
    static let orange = Color(red: 0.8, green: 0.5, blue: 0.1)
    static let darkGray = Color(red: 0.34, green: 0.34, blue: 0.35)
    // "Source for Viewing" field in the RSB's "Watch Details" module: whether a known
    // studio is shown by its shorthand ("Universal"), retreating to its abbreviation
    // ("Uni") only when the row would otherwise wrap — see ReleaseStudio for the tiers.
    // Off, the full stored name is shown and the field never shortens a studio.
    static let abbreviateSourceStudio = true
    
    // MARK: - Keys
    // Keys used for UserDefaults.
    private enum Keys {
        static let loggingEnabled =
            "preferences.loggingEnabled"
        static let confirmGalleryDelete =
            "preferences.confirmGalleryDelete"
        static let confirmListEdits =
            "preferences.confirmListEdits"
        static let listEditScope =
            "preferences.listEditScope"
        static let confirmReleaseDelete =
            "preferences.confirmReleaseDelete"
        static let largeGalleryGrid =
            "preferences.largeGalleryGrid"
        static let showStatusBar =
            "preferences.showStatusBar"
        static let rememberRightSidebarTab =
            "preferences.rememberRightSidebarTab"
        static let rememberRightSidebarReleasesFilter =
            "preferences.rememberRightSidebarReleasesFilter"
        static let autoExpandRightSidebarTables =
            "preferences.autoExpandRightSidebarTables"
        static let additionalCalTableDetails =
            "preferences.additionalCalTableDetails"
        static let showReleasesSummaryTable =
            "preferences.showReleasesSummaryTable"
        static let iCalIntegration =
            "preferences.iCalIntegration"
        static let manualExtQuery =
            "preferences.manualExtQuery"
        static let smartLists =
            "preferences.smartLists"
        static let excludeQueuedFromUpForRotation =
            "preferences.excludeQueuedFromUpForRotation"
        static let maintainSelectionOnSearchExit =
            "preferences.maintainSelectionOnSearchExit"
        static let showSearchSuggestions =
            "preferences.showSearchSuggestions"
        static let showRecentSearches =
            "preferences.showRecentSearches"
        static let showInfoComplete =
            "preferences.showInfoComplete"
        static let importScanSubfolders =
            "preferences.importScanSubfolders"
        static let fuzzyImportMatching =
            "preferences.fuzzyImportMatching"
        static let fuzzyImportYearMatching =
            "preferences.fuzzyImportYearMatching"
        static let overrideSortNameField =
            "preferences.overrideSortNameField"
        static let allowUpdatesForDuplicateImports =
            "preferences.allowUpdatesForDuplicateImports"
        static let allowUpdatesForDuplicateRatings =
            "preferences.allowUpdatesForDuplicateRatings"
        static let selectedSortOptions =
            "preferences.selectedSortOptions"
        static let maintainScrollPositionOnViewSwitch =
            "preferences.maintainScrollPositionOnViewSwitch"
        static let rememberTabSelection =
            "preferences.rememberTabSelection"
        static let tabRememberScope =
            "preferences.tabRememberScope"
        static let lastRecentsCategory =
            "preferences.lastRecentsCategory"
        static let lastReportsCategory =
            "preferences.lastReportsCategory"
        static let rememberImportsTab =
            "preferences.rememberImportsTab"
        static let lastImportsCategory =
            "preferences.lastImportsCategory"
        static let prunePosterImages =
            "preferences.prunePosterImages"
        static let performBackupAtLaunch =
            "preferences.performBackupAtLaunch"
        static let exportPosterImages =
            "preferences.exportPosterImages"
        static let exportUserSettings =
            "preferences.exportUserSettings"
        static let defaultRotationThreshold =
            "preferences.defaultRotationThreshold"
        static let exportPathBookmark =
            "preferences.exportPathBookmark"
        static let ignoredDuplicatePairs =
            "preferences.ignoredDuplicatePairs"
        static let rememberSortFilterSelections =
            "preferences.rememberSortFilterSelections"
        static let confirmFilmQueueAdd =
            "preferences.confirmFilmQueueAdd"
        static let notifyAboutNewReleases =
            "preferences.notifyAboutNewReleases"
        static let onlyNotifyForWishlisted =
            "preferences.onlyNotifyForWishlisted"
        static let queueIsDropTarget =
            "preferences.queueIsDropTarget"
        static let queueSectionOnDrop =
            "preferences.queueSectionOnDrop"
        static let strictFramesTableChecking =
            "preferences.strictFramesTableChecking"
        static let showWatchDetailsAnnotationGlyphs =
            "preferences.showWatchDetailsAnnotationGlyphs"
        static let atvq =
            "preferences.atvq"
        static let overrideDateClamp =
            "preferences.overrideDateClamp"
        // Internal state, not a user-facing preference. See the accessor below.
        static let knownUpForRotationFilmIDs =
            "preferences.knownUpForRotationFilmIDs"
        // Internal state, not a user-facing preference. See the accessor below.
        static let expandedSmartListFamilies =
            "preferences.expandedSmartListFamilies" }

    // Expose the key strings for use by other modules that need to post/update.
    // (This keeps a single canonical definition of the key names.)
    // Declared as `let` constants rather than computed `var`s — they simply re-expose
    // string literals from the private Keys enum and are immutable by nature. `let`
    // allows the compiler to inline them; computed `var` would add a getter call site
    // on every access with no benefit.
    static let loggingEnabledKey                     = Keys.loggingEnabled
    static let confirmGalleryDeleteKey               = Keys.confirmGalleryDelete
    static let confirmListEditsKey                   = Keys.confirmListEdits
    static let listEditScopeKey                      = Keys.listEditScope
    static let confirmReleaseDeleteKey               = Keys.confirmReleaseDelete
    static let largeGalleryGridKey                   = Keys.largeGalleryGrid
    static let showStatusBarKey                      = Keys.showStatusBar
    static let rememberRightSidebarTabKey            = Keys.rememberRightSidebarTab
    static let rememberRightSidebarReleasesFilterKey = Keys.rememberRightSidebarReleasesFilter
    static let autoExpandRightSidebarTablesKey       = Keys.autoExpandRightSidebarTables
    static let additionalCalTableDetailsKey          = Keys.additionalCalTableDetails
    static let showReleasesSummaryTableKey           = Keys.showReleasesSummaryTable
    static let iCalIntegrationKey                    = Keys.iCalIntegration
    static let manualExtQueryKey                     = Keys.manualExtQuery
    static let smartListsKey                         = Keys.smartLists
    static let excludeQueuedFromUpForRotationKey     = Keys.excludeQueuedFromUpForRotation
    static let maintainSelectionOnSearchExitKey      = Keys.maintainSelectionOnSearchExit
    static let showSearchSuggestionsKey              = Keys.showSearchSuggestions
    static let showRecentSearchesKey                 = Keys.showRecentSearches
    static let showInfoCompleteKey                   = Keys.showInfoComplete
    static let importScanSubfoldersKey               = Keys.importScanSubfolders
    static let fuzzyImportMatchingKey                = Keys.fuzzyImportMatching
    static let fuzzyImportYearMatchingKey            = Keys.fuzzyImportYearMatching
    static let overrideSortNameFieldKey              = Keys.overrideSortNameField
    static let allowUpdatesForDuplicateImportsKey    = Keys.allowUpdatesForDuplicateImports
    static let allowUpdatesForDuplicateRatingsKey    = Keys.allowUpdatesForDuplicateRatings
    static let maintainScrollPositionOnViewSwitchKey = Keys.maintainScrollPositionOnViewSwitch
    static let rememberTabSelectionKey               = Keys.rememberTabSelection
    static let tabRememberScopeKey                   = Keys.tabRememberScope
    static let prunePosterImagesKey                  = Keys.prunePosterImages
    static let performBackupAtLaunchKey              = Keys.performBackupAtLaunch
    static let defaultRotationThresholdKey           = Keys.defaultRotationThreshold
    static let rememberSortFilterSelectionsKey       = Keys.rememberSortFilterSelections
    static let confirmFilmQueueAddKey                = Keys.confirmFilmQueueAdd
    static let notifyAboutNewReleasesKey             = Keys.notifyAboutNewReleases
    static let onlyNotifyForWishlistedKey            = Keys.onlyNotifyForWishlisted
    static let queueIsDropTargetKey                  = Keys.queueIsDropTarget
    static let queueSectionOnDropKey                 = Keys.queueSectionOnDrop
    // Unlike overrideDateClampKey below, this one IS a durable preference: it
    // describes how the user wants to enter data, not a one-session escape
    // hatch, so it participates in SettingsManager's export/restore pipeline and
    // in SettingsObject's persisted schema exactly like every key above it.
    static let strictFramesTableCheckingKey          = Keys.strictFramesTableChecking
    static let showWatchDetailsAnnotationGlyphsKey   = Keys.showWatchDetailsAnnotationGlyphs
    static let atvqKey                               = Keys.atvq
    // NOTE: overrideDateClampKey is intentionally NOT included in SettingsManager's
    // export/restore pipeline or SettingsObject's persisted schema. See the
    // overrideDateClamp property below for the full rationale — this preference
    // always resets to false on quit, so persisting its state would be pointless.
    static let overrideDateClampKey            = Keys.overrideDateClamp

    // Sane defaults for every key — THE master list. Registered by the `defaults`
    // initializer above so no caller needs special 'nil' checks, and read back through
    // registeredDefault(_:orFallback:) by everything else that needs a default. A
    // function rather than a stored `[String: Any]`, which strict concurrency rejects as
    // shared mutable state; it is called exactly once, by `registered`.
    private static func registeredDefaults() -> [String: Any] {
        return [
            Keys.loggingEnabled: false,
            Keys.confirmGalleryDelete: true,
            Keys.confirmListEdits: true,
            Keys.listEditScope: ListEditScope.both.rawValue,
            Keys.confirmReleaseDelete: true,
            Keys.largeGalleryGrid: true,
            Keys.showStatusBar: true,
            Keys.rememberRightSidebarTab: true,
            Keys.rememberRightSidebarReleasesFilter: true,
            Keys.autoExpandRightSidebarTables: false,
            Keys.additionalCalTableDetails: false,
            Keys.showReleasesSummaryTable: false,
            Keys.iCalIntegration: false,
            Keys.manualExtQuery: true,
            Keys.smartLists: true,
            Keys.excludeQueuedFromUpForRotation: true,
            Keys.maintainSelectionOnSearchExit: true,
            Keys.showSearchSuggestions: true,
            Keys.showRecentSearches: true,
            Keys.showInfoComplete: false,
            Keys.importScanSubfolders: true,
            Keys.fuzzyImportMatching: true,
            Keys.fuzzyImportYearMatching: true,
            Keys.overrideSortNameField: false,
            Keys.allowUpdatesForDuplicateImports: false,
            Keys.allowUpdatesForDuplicateRatings: true,
            Keys.selectedSortOptions: [String: [String]](),
            Keys.maintainScrollPositionOnViewSwitch: false,
            Keys.rememberTabSelection: false,
            Keys.tabRememberScope: TabRememberScope.both.rawValue,
            Keys.rememberImportsTab: false,
            Keys.prunePosterImages: true,
            Keys.performBackupAtLaunch: true,
            Keys.exportPosterImages: true,
            Keys.exportUserSettings: true,
            Keys.defaultRotationThreshold: 24,
            Keys.ignoredDuplicatePairs: [],
            Keys.rememberSortFilterSelections: true,
            Keys.confirmFilmQueueAdd: true,
            Keys.notifyAboutNewReleases: false,
            Keys.onlyNotifyForWishlisted: false,
            Keys.queueIsDropTarget: true,
            Keys.queueSectionOnDrop: QueueDropSection.upNext.rawValue,
            Keys.strictFramesTableChecking: true,
            Keys.showWatchDetailsAnnotationGlyphs: false,
            Keys.atvq: false,
            Keys.overrideDateClamp: false ] }

    /// Forces the `defaults` static — and with it the registration — to initialize.
    /// Registration is a property of `defaults` itself now, so every accessor is covered
    /// whether or not this is called; AppDelegate still calls it at launch so the suite is
    /// resolved before any I/O-dependent subsystem runs.
    static func ensureDefaultsRegistered() { _ = defaults }

    // MARK: - Toggles
    static var loggingEnabled: Bool {
        get {
            // A sandbox run starts from a fresh defaults suite, where this would be false —
            // leaving a harness run with no application log at all, which removes most of
            // its diagnostic value. Forced on instead. The log lands in the sandbox's own
            // folder (LoggerCore derives its path from dataFolderURL), so the user's
            // FilmTracker.log is neither read nor appended to.
            #if DEBUG
            if DebugSandbox.isActive { return true }
            #endif
            return defaults.bool(forKey: Keys.loggingEnabled)
        }
        set {
            setIfChanged(newValue, forKey: Keys.loggingEnabled,
                logMessage: "loggingEnabled set to \(newValue)") } }

    static var confirmGalleryDelete: Bool {
        get { return defaults.bool(forKey: Keys.confirmGalleryDelete) }
        set {
            setIfChanged(newValue, forKey: Keys.confirmGalleryDelete,
                logMessage: "confirmGalleryDelete set to \(newValue)") } }

    static var confirmListEdits: Bool {
        get { return defaults.bool(forKey: Keys.confirmListEdits) }
        set {
            setIfChanged(newValue, forKey: Keys.confirmListEdits,
                logMessage: "confirmListEdits set to \(newValue)") } }

    // MARK: - List Edit Scope
    // Governs which class of user-generated list changes triggers a confirmation alert
    // when confirmListEdits is enabled. The scope has no effect when confirmListEdits is false.
    //
    // .both        → alerts for all list-related changes (default; matches prior behavior)
    // .listOnly    → alerts only for changes to the list itself (delete, rename, duplicate)
    // .contentsOnly → alerts only for changes to list contents (remove, clear)
    enum ListEditScope: Int {
        case both         = 0   // Warn for all list-related changes
        case listOnly     = 1   // Warn only for list-structure changes
        case contentsOnly = 2   // Warn only for list-contents changes
    }

    static var listEditScope: ListEditScope {
        get {
            let raw = defaults.integer(forKey: Keys.listEditScope)
            return ListEditScope(rawValue: raw) ?? registeredCase(Keys.listEditScope)
        }
        set {
            setIfChanged(newValue.rawValue, forKey: Keys.listEditScope,
                logMessage: "listEditScope set to \(newValue.rawValue)") } }

    // Convenience: returns true when the user should be presented with a confirmation
    // alert for a list-structure change (delete, rename, duplicate).
    static var shouldConfirmListStructure: Bool {
        guard confirmListEdits else { return false }
        switch listEditScope {
        case .both, .listOnly: return true
        case .contentsOnly:    return false } }

    // Convenience: returns true when the user should be presented with a confirmation
    // alert for a list-contents change (remove film(s), clear list).
    static var shouldConfirmListContents: Bool {
        guard confirmListEdits else { return false }
        switch listEditScope {
        case .both, .contentsOnly: return true
        case .listOnly:            return false } }

    static var confirmReleaseDelete: Bool {
        get { return defaults.bool(forKey: Keys.confirmReleaseDelete) }
        set {
            setIfChanged(newValue, forKey: Keys.confirmReleaseDelete,
                logMessage: "confirmReleaseDelete set to \(newValue)") } }

    // Governs whether the user is shown a confirmation alert before adding a film that
    // carries a special sorting parameter (e.g. "Ignore", "Blacklisted") to the Up Next
    // Queue via the FilmSheet Details tab's segmented Picker. When false, films are added
    // to the queue without any warning regardless of their special sorting state.
    static var confirmFilmQueueAdd: Bool {
        get { return defaults.bool(forKey: Keys.confirmFilmQueueAdd) }
        set {
            setIfChanged(newValue, forKey: Keys.confirmFilmQueueAdd,
                logMessage: "confirmFilmQueueAdd set to \(newValue)") } }

    // MARK: - New-Release Notifications
    // Whether Film Tracker posts a notification on the release date of each release that was
    // cataloged with a date still ahead (see ReleaseNotifications), and whether that is
    // limited to wishlisted releases. The scope has no effect when notifications are off.
    static var notifyAboutNewReleases: Bool {
        get { return defaults.bool(forKey: Keys.notifyAboutNewReleases) }
        set {
            setIfChanged(newValue, forKey: Keys.notifyAboutNewReleases,
                logMessage: "notifyAboutNewReleases set to \(newValue)") } }

    static var onlyNotifyForWishlisted: Bool {
        get { return defaults.bool(forKey: Keys.onlyNotifyForWishlisted) }
        set {
            setIfChanged(newValue, forKey: Keys.onlyNotifyForWishlisted,
                logMessage: "onlyNotifyForWishlisted set to \(newValue)") } }

    // Governs whether the "Film Queue" sidebar item accepts film drops. When true,
    // dragging a selection of films onto the sidebar's "Film Queue" row adds them to
    // whichever of the three internal Film Queue lists is selected via
    // queueSectionOnDrop below.
    static var queueIsDropTarget: Bool {
        get { return defaults.bool(forKey: Keys.queueIsDropTarget) }
        set {
            setIfChanged(newValue, forKey: Keys.queueIsDropTarget,
                logMessage: "queueIsDropTarget set to \(newValue)") } }

    // MARK: - Queue Section On Drop
    // Determines which of the three internal Film Queue lists receives films dragged
    // onto the "Film Queue" sidebar item when queueIsDropTarget is enabled. Has no
    // effect when queueIsDropTarget is false.
    enum QueueDropSection: Int, CaseIterable {
        case upNext = 0   // "Up Next" section
        case soon   = 1   // "Soon" section
        case later  = 2   // "Later" section

        // Maps this preference-facing case to the corresponding FilmQueueSection used by
        // the Film Queue's underlying internal list implementation (FilmQueue.swift).
        var filmQueueSection: FilmQueueSection {
            switch self {
            case .upNext: return .upNext
            case .soon:   return .soon
            case .later:  return .later } }
    }

    static var queueSectionOnDrop: QueueDropSection {
        get {
            let raw = defaults.integer(forKey: Keys.queueSectionOnDrop)
            return QueueDropSection(rawValue: raw) ?? registeredCase(Keys.queueSectionOnDrop)
        }
        set {
            setIfChanged(newValue.rawValue, forKey: Keys.queueSectionOnDrop,
                logMessage: "queueSectionOnDrop set to \(newValue.rawValue)") } }

    // MARK: - Gallery Sorting Sections
    // NOTE: there is no preference here any more. Whether a gallery inserts labeled
    // divider bands derived from its active sort option — alphabetical letters for Title,
    // one band per year for Year, runtime brackets for Duration, relative-age brackets for
    // the three date sorts, and one band per discrete step for Rating and Recorded View
    // Count (see GallerySections.swift for the per-option derivation) — is per-view state,
    // stored as ViewState.showSectionDividers in the viewSortStates dictionary below and
    // chosen from each view's own Sort menu. The global `showGallerySortingSections`
    // preference this replaced is gone entirely, including from the backup schema; a
    // restored pre-change backup simply carries no value for it, and every view starts
    // from the same `false` default it always shipped with.

    static var largeGalleryGrid: Bool {
        get { return defaults.bool(forKey: Keys.largeGalleryGrid) }
        set {
            setIfChanged(newValue, forKey: Keys.largeGalleryGrid,
                logMessage: "largeGalleryGrid set to \(newValue)") } }

    static var showStatusBar: Bool {
        get { return defaults.bool(forKey: Keys.showStatusBar) }
        set {
            setIfChanged(newValue, forKey: Keys.showStatusBar,
                logMessage: "showStatusBar set to \(newValue)") } }

    static var rememberRightSidebarTab: Bool {
        get { return defaults.bool(forKey: Keys.rememberRightSidebarTab) }
        set {
            setIfChanged(newValue, forKey: Keys.rememberRightSidebarTab,
                logMessage: "rememberRightSidebarTab set to \(newValue)") } }

    static var rememberRightSidebarReleasesFilter: Bool {
        get { return defaults.bool(forKey: Keys.rememberRightSidebarReleasesFilter) }
        set {
            setIfChanged(newValue, forKey: Keys.rememberRightSidebarReleasesFilter,
                logMessage: "rememberRightSidebarReleasesFilter set to \(newValue)") } }

    static var autoExpandRightSidebarTables: Bool {
        get { return defaults.bool(forKey: Keys.autoExpandRightSidebarTables) }
        set {
            setIfChanged(newValue, forKey: Keys.autoExpandRightSidebarTables,
                logMessage: "autoExpandRightSidebarTables set to \(newValue)") } }

    static var additionalCalTableDetails: Bool {
        get { return defaults.bool(forKey: Keys.additionalCalTableDetails) }
        set {
            setIfChanged(newValue, forKey: Keys.additionalCalTableDetails,
                logMessage: "additionalCalTableDetails set to \(newValue)") } }

    // Governs whether the right sidebar's "Releases" tab prepends the summary table
    // (DiscReleasesTable) above the release cards. The table is an addition to that
    // tab, not a replacement for anything in it: when this is false the section is
    // never constructed, so it costs nothing. The identical table shown in the
    // "Details" tab is unaffected by this preference.
    static var showReleasesSummaryTable: Bool {
        get { return defaults.bool(forKey: Keys.showReleasesSummaryTable) }
        set {
            setIfChanged(newValue, forKey: Keys.showReleasesSummaryTable,
                logMessage: "showReleasesSummaryTable set to \(newValue)") } }

    static var iCalIntegration: Bool {
        get { return defaults.bool(forKey: Keys.iCalIntegration) }
        set {
            setIfChanged(newValue, forKey: Keys.iCalIntegration,
                logMessage: "iCalIntegration set to \(newValue)") } }

    static var manualExtQuery: Bool {
        get { return defaults.bool(forKey: Keys.manualExtQuery) }
        set {
            setIfChanged(newValue, forKey: Keys.manualExtQuery,
                logMessage: "manualExtQuery set to \(newValue)") } }

    static var smartLists: Bool {
        get { return defaults.bool(forKey: Keys.smartLists) }
        set {
            setIfChanged(newValue, forKey: Keys.smartLists,
                logMessage: "smartLists set to \(newValue)") } }

    // Governs whether films that are already present on any of the three internal Film
    // Queue lists (Up Next, Soon, Later) are hidden from the "Up for Rotation" smart list.
    // This is purely a presentation-layer filter — it has no effect on whether a film
    // actually qualifies as up for rotation, nor on its Film Queue membership. Has no
    // effect when Preferences.smartLists is false, since the smart list itself is hidden
    // in that case.
    static var excludeQueuedFromUpForRotation: Bool {
        get { return defaults.bool(forKey: Keys.excludeQueuedFromUpForRotation) }
        set {
            setIfChanged(newValue, forKey: Keys.excludeQueuedFromUpForRotation,
                logMessage: "excludeQueuedFromUpForRotation set to \(newValue)") } }

    static var maintainSelectionOnSearchExit: Bool {
        get { return defaults.bool(forKey: Keys.maintainSelectionOnSearchExit) }
        set {
            setIfChanged(newValue, forKey: Keys.maintainSelectionOnSearchExit,
                logMessage: "maintainSelectionOnSearchExit set to \(newValue)") } }

    /// Library-based suggestions in the search field's drop-down, and the search
    /// heuristics that rank them. The "#field" suggestions are shown regardless.
    static var showSearchSuggestions: Bool {
        get { return defaults.bool(forKey: Keys.showSearchSuggestions) }
        set {
            setIfChanged(newValue, forKey: Keys.showSearchSuggestions,
                logMessage: "showSearchSuggestions set to \(newValue)") } }

    /// The session's recent searches, shown when the empty search field is selected.
    /// Nested under showSearchSuggestions in Settings, and only in effect while it is on.
    static var showRecentSearches: Bool {
        get { return defaults.bool(forKey: Keys.showRecentSearches) }
        set {
            setIfChanged(newValue, forKey: Keys.showRecentSearches,
                logMessage: "showRecentSearches set to \(newValue)") } }

    static var showInfoComplete: Bool {
        get { return defaults.bool(forKey: Keys.showInfoComplete) }
        set {
            setIfChanged(newValue, forKey: Keys.showInfoComplete,
                logMessage: "showInfoComplete set to \(newValue)") } }

    static var importScanSubfolders: Bool {
        get { return defaults.bool(forKey: Keys.importScanSubfolders) }
        set {
            setIfChanged(newValue, forKey: Keys.importScanSubfolders,
                logMessage: "importScanSubfolders set to \(newValue)") } }

    static var fuzzyImportMatching: Bool {
        get { return defaults.bool(forKey: Keys.fuzzyImportMatching) }
        set {
            setIfChanged(newValue, forKey: Keys.fuzzyImportMatching,
                logMessage: "fuzzyImportMatching set to \(newValue)") } }

    static var fuzzyImportYearMatching: Bool {
        get { return defaults.bool(forKey: Keys.fuzzyImportYearMatching) }
        set {
            setIfChanged(newValue, forKey: Keys.fuzzyImportYearMatching,
                logMessage: "fuzzyImportYearMatching set to \(newValue)") } }

    static var overrideSortNameField: Bool {
        get { return defaults.bool(forKey: Keys.overrideSortNameField) }
        set {
            setIfChanged(newValue, forKey: Keys.overrideSortNameField,
                logMessage: "overrideSortNameField set to \(newValue)") } }

    static var allowUpdatesForDuplicateImports: Bool {
        get { return defaults.bool(forKey: Keys.allowUpdatesForDuplicateImports) }
        set {
            setIfChanged(newValue, forKey: Keys.allowUpdatesForDuplicateImports,
                logMessage: "allowUpdatesForDuplicateImports set to \(newValue)") } }

    static var allowUpdatesForDuplicateRatings: Bool {
        get { return defaults.bool(forKey: Keys.allowUpdatesForDuplicateRatings) }
        set {
            setIfChanged(newValue, forKey: Keys.allowUpdatesForDuplicateRatings,
                logMessage: "allowUpdatesForDuplicateRatings set to \(newValue)") } }

    static var maintainScrollPositionOnViewSwitch: Bool {
        get { return defaults.bool(forKey: Keys.maintainScrollPositionOnViewSwitch) }
        set {
            setIfChanged(newValue, forKey: Keys.maintainScrollPositionOnViewSwitch,
                logMessage: "maintainScrollPositionOnViewSwitch set to \(newValue)") } }

    // MARK: - Tab Remember Scope
    // Governs which tab(s) — Recents, Reports, or both — have their last-selected
    // sub-tab remembered across sessions. Mirrors the confirmListEdits/ListEditScope
    // design: rememberTabSelection is the master on/off switch, and tabRememberScope
    // refines which tab(s) it applies to when enabled. Turning rememberTabSelection
    // off has no effect on which scope is remembered — it merely stops applying
    // whichever scope is currently selected, without disturbing that selection.
    enum TabRememberScope: Int {
        case recents = 0   // Remember Recents' last-selected sub-tab only
        case reports = 1   // Remember Reports' last-selected sub-tab only
        case both    = 2   // Remember both (default; matches prior behavior)
    }

    static var rememberTabSelection: Bool {
        get { return defaults.bool(forKey: Keys.rememberTabSelection) }
        set {
            setIfChanged(newValue, forKey: Keys.rememberTabSelection,
                logMessage: "rememberTabSelection set to \(newValue)") } }

    static var tabRememberScope: TabRememberScope {
        get {
            let raw = defaults.integer(forKey: Keys.tabRememberScope)
            return TabRememberScope(rawValue: raw) ?? registeredCase(Keys.tabRememberScope)
        }
        set {
            setIfChanged(newValue.rawValue, forKey: Keys.tabRememberScope,
                logMessage: "tabRememberScope set to \(newValue.rawValue)") } }

    // Convenience per-tab accessors, derived from the consolidated pair above.
    // Preserved so existing call sites (RecentsView, ReportsView, and the
    // SettingsManager restore path) can keep reading/writing per-tab granularity
    // as a plain Bool without needing to know about the combined representation.
    // Setting one tab's Bool only ever adjusts the scope enough to reflect the
    // requested state for that tab, leaving the other tab's current state intact.
    static var rememberRecentsTab: Bool {
        get { rememberTabSelection && (tabRememberScope == .recents || tabRememberScope == .both) }
        set {
            if newValue {
                rememberTabSelection = true
                if tabRememberScope == .reports { tabRememberScope = .both }
            } else {
                switch tabRememberScope {
                case .recents: rememberTabSelection = false
                case .both:    tabRememberScope = .reports
                case .reports: break // Recents wasn't enabled; nothing to change
                }
            } } }

    static var lastRecentsCategory: String? {
        get { return defaults.string(forKey: Keys.lastRecentsCategory) }
        set {
            // Written directly to UserDefaults without firing postPreferenceChangedEvent.
            // This is a high-frequency UI state value (fires on every tab switch) that no
            // other subsystem needs to react to — it is only read back at the next launch.
            // Routing through setIfChanged → postPreferenceChangedEvent → SettingsManager
            // sync would introduce a 4–6 second write delay, causing the value to be lost
            // if the user quits before the background sync completes.
            //
            // synchronize() forces an immediate flush of the UserDefaults in-memory state
            // to the backing plist file. Without it, macOS batches the write lazily and
            // may not flush before the user quits, reproducing the same lost-on-quit
            // symptom. synchronize() is technically deprecated for general use (the OS
            // handles flushing automatically in most cases), but it is the correct and
            // intentional tool when quit-safe persistence is required — exactly this scenario.
            if let value = newValue {
                guard defaults.string(forKey: Keys.lastRecentsCategory) != value else { return }
                defaults.set(value, forKey: Keys.lastRecentsCategory)
                defaults.synchronize()
                log("lastRecentsCategory set to \(value)")
            } else {
                defaults.removeObject(forKey: Keys.lastRecentsCategory)
                defaults.synchronize() } } }

    static var rememberReportsTab: Bool {
        get { rememberTabSelection && (tabRememberScope == .reports || tabRememberScope == .both) }
        set {
            if newValue {
                rememberTabSelection = true
                if tabRememberScope == .recents { tabRememberScope = .both }
            } else {
                switch tabRememberScope {
                case .reports: rememberTabSelection = false
                case .both:    tabRememberScope = .recents
                case .recents: break // Reports wasn't enabled; nothing to change
                }
            } } }

    static var lastReportsCategory: String? {
        get { return defaults.string(forKey: Keys.lastReportsCategory) }
        set {
            // Written directly to UserDefaults without firing postPreferenceChangedEvent.
            // Same rationale as lastRecentsCategory: high-frequency UI state, no downstream
            // subscribers, and delay-free persistence is required for correct quit behavior.
            if let value = newValue {
                guard defaults.string(forKey: Keys.lastReportsCategory) != value else { return }
                defaults.set(value, forKey: Keys.lastReportsCategory)
                defaults.synchronize()
                log("lastReportsCategory set to \(value)")
            } else {
                defaults.removeObject(forKey: Keys.lastReportsCategory)
                defaults.synchronize() } } }

    static var rememberImportsTab: Bool {
        get { return defaults.bool(forKey: Keys.rememberImportsTab) }
        set {
            setIfChanged(newValue, forKey: Keys.rememberImportsTab,
                logMessage: "rememberImportsTab set to \(newValue)") } }
    
    static var lastImportsCategory: String? {
        get { return defaults.string(forKey: Keys.lastImportsCategory) }
        set {
            // Written directly to UserDefaults without firing postPreferenceChangedEvent.
            // Same rationale as lastRecentsCategory and lastReportsCategory.
            if let value = newValue {
                guard defaults.string(forKey: Keys.lastImportsCategory) != value else { return }
                defaults.set(value, forKey: Keys.lastImportsCategory)
                defaults.synchronize()
                log("lastImportsCategory set to \(value)")
            } else {
                defaults.removeObject(forKey: Keys.lastImportsCategory)
                defaults.synchronize() } } }
    
    static var prunePosterImages: Bool {
        get { return defaults.bool(forKey: Keys.prunePosterImages) }
        set {
            setIfChanged(newValue, forKey: Keys.prunePosterImages,
                logMessage: "prunePosterImages set to \(newValue)") } }

    static var performBackupAtLaunch: Bool {
        get { return defaults.bool(forKey: Keys.performBackupAtLaunch) }
        set {
            setIfChanged(newValue, forKey: Keys.performBackupAtLaunch,
                logMessage: "performBackupAtLaunch set to \(newValue)") } }

    static var exportPosterImages: Bool {
        get { return defaults.bool(forKey: Keys.exportPosterImages) }
        set {
            setIfChanged(newValue, forKey: Keys.exportPosterImages,
                logMessage: "exportPosterImages set to \(newValue)") } }

    static var exportUserSettings: Bool {
        get { return defaults.bool(forKey: Keys.exportUserSettings) }
        set {
            setIfChanged(newValue, forKey: Keys.exportUserSettings,
                logMessage: "exportUserSettings set to \(newValue)") } }

    // MARK: - Rotation Threshold
    /// All valid rotation threshold options in months.
    static let rotationThresholdOptions: [Int] = [12, 18, 24, 36, 48, 60]

    /// The registered threshold. Its fallback — the first option — is reached only if the
    /// master list lost the key, which DEBUG stops on.
    private static var registeredRotationThreshold: Int {
        registeredDefault(Keys.defaultRotationThreshold, orFallback: rotationThresholdOptions[0])
    }
    
    static var defaultRotationThreshold: Int {
        get {
            let value = defaults.integer(forKey: Keys.defaultRotationThreshold)
            // Validate that the value is one of the allowed options.
            if rotationThresholdOptions.contains(value) {
                return value }
            // Fall back to the registered default if invalid.
            return registeredRotationThreshold }
        set {
            // Only allow values in rotationThresholdOptions; anything else stores the
            // registered default.
            let validValue = rotationThresholdOptions.contains(newValue)
                ? newValue : registeredRotationThreshold
            setIfChanged(validValue, forKey: Keys.defaultRotationThreshold,
                logMessage: "defaultRotationThreshold set to \(validValue)") } }

    // MARK: - View Sort States Dictionary
    // Consolidated sort/filter state for all non-user-generated-list views that persist
    // selection across launches. Stored under the same UserDefaults key as the legacy
    // selectedSortOptions array so the backup XML attribute name is unchanged.
    //
    // Keys:
    //   "allFilms"              → All Films view
    //   "unwatched.<rawValue>"  → One entry per UnwatchedCategory
    //   "recents.<rawValue>"    → One entry per RecentsCategory
    //   "smartList.<rawValue>"  → One entry per SmartListType
    //
    // Each value is a five-element [String] array:
    //   [sortOption, filterString, sortDirection, listViewStyle, sectionDividers]
    // where filterString is comma-separated FilterOption raw values (or "" for none),
    // listViewStyle is "list" or "", and sectionDividers is "dividers" or "". Shorter
    // arrays written by earlier versions are read positionally and the missing trailing
    // elements take their ViewState defaults — see ViewState.parseSettings.
    //
    // Backward compatibility: old backups store a flat [String] under this key.
    // SettingsManager.applySnapshotToPreferences() handles the [String] fallback gracefully
    // (the old allFilms-only data is silently dropped), so restores never crash or corrupt.
    static var viewSortStates: [String: [String]] {
        get {
            // Attempt to read as the new [String:[String]] dictionary format.
            if let dict = defaults.dictionary(forKey: Keys.selectedSortOptions) as? [String: [String]] {
                return dict
            }
            // Key is absent or holds the legacy flat-array format — return empty dictionary
            // so all views fall back to their built-in defaults. The legacy value is never
            // re-written in the new format until the user triggers a state change.
            return [:]
        }
        set {
            setIfChanged(newValue, forKey: Keys.selectedSortOptions,
                logMessage: "viewSortStates updated (\(newValue.count) entries)")
        }
    }

    // MARK: - Ignored Duplicate Pairs
    // Array of ignored duplicate film pairs, stored as "UUID1-UUID2" strings
    // where UUID1 < UUID2 alphabetically for consistent ordering.
    static var ignoredDuplicatePairs: [String] {
        get {
            return defaults.array(forKey: Keys.ignoredDuplicatePairs) as? [String] ?? [] }
        set {
            setIfChanged(newValue, forKey: Keys.ignoredDuplicatePairs,
                logMessage: "ignoredDuplicatePairs updated (count: \(newValue.count))") } }

    // Helper to generate a consistent pair key from two film UUIDs.
    static func makeDuplicatePairKey(film1ID: UUID, film2ID: UUID) -> String {
        let id1 = film1ID.uuidString
        let id2 = film2ID.uuidString
        return id1 < id2 ? "\(id1)-\(id2)" : "\(id2)-\(id1)" }

    // Reset all ignored duplicate pairs.
    static func resetIgnoredDuplicatePairs() {
        defaults.removeObject(forKey: Keys.ignoredDuplicatePairs)
        log("Reset all ignored duplicate pairs")
        postPreferenceChangedEvent() }

    // MARK: - Known "Up for Rotation" Membership (internal state)
    //
    // The set of film IDs that were already up for rotation the last time SmartLists
    // evaluated the library. This is NOT a user-facing preference and is deliberately
    // excluded from the settings export/restore pipeline and from the registered defaults.
    //
    // It exists so that "newly up for rotation" means genuinely newly up for rotation
    // ACROSS LAUNCHES, not merely "present in a freshly populated in-memory set". Without
    // it, every launch treated the entire rotation list as new and re-ran auto-enqueue over
    // the whole library — silently undoing any Film Queue placement the user had made by
    // hand in a previous session.
    //
    // `nil` (key absent) is meaningful and distinct from an empty set: it means "no baseline
    // has been established", which happens on the first launch after this feature was added
    // and after a database restore. In that state SmartLists adopts whatever it computes
    // without auto-enqueueing anything, because it has no prior state to legitimately
    // compare against and must not act on a difference it cannot verify.
    static var knownUpForRotationFilmIDs: Set<UUID>? {
        get {
            guard let raw = defaults.array(forKey: Keys.knownUpForRotationFilmIDs) as? [String] else {
                return nil
            }
            return Set(raw.compactMap { UUID(uuidString: $0) })
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.knownUpForRotationFilmIDs)
                return
            }
            // Written directly rather than through setIfChanged() on purpose: this is
            // high-frequency internal bookkeeping, and setIfChanged() posts
            // preferencesChanged, which SmartLists itself subscribes to. Routing this
            // through that path would feed SmartLists' own writes back into its listener.
            defaults.set(newValue.map(\.uuidString), forKey: Keys.knownUpForRotationFilmIDs)
        }
    }

    // MARK: - Expanded Smart List Families
    // Which smart list families are expanded in the left sidebar, by their parent's raw
    // value. Internal state, not a user-facing preference: never shown in Settings, not in
    // the registered defaults (absent means all collapsed), and not exported or restored.
    // Written directly rather than through setIfChanged() for the same reason as the
    // rotation baseline above — it is UI bookkeeping, and nothing listens for it.
    static var expandedSmartListFamilies: Set<SmartListType> {
        get {
            let raw = defaults.array(forKey: Keys.expandedSmartListFamilies) as? [String] ?? []
            return Set(raw.compactMap(SmartListType.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Keys.expandedSmartListFamilies)
        }
    }

    /// Clears the rotation baseline, returning it to the "not established" state.
    /// Called after a database restore: the restored library's film IDs bear no relationship
    /// to the ones recorded against the previous library, so the stale baseline would report
    /// large numbers of false "newly up for rotation" films and auto-enqueue over the queue
    /// state that was itself just restored from the backup.
    static func resetKnownUpForRotationFilmIDs() {
        defaults.removeObject(forKey: Keys.knownUpForRotationFilmIDs)
        log("Reset known Up for Rotation baseline") }

    // MARK: - Remember Sort/Filter Selections
    // Controls whether user-selected sort and filter options for the All Films, Recents,
    // and smart list views are persisted across application launches.
    //
    // When true (default): runtime changes are written to selectedSortOptions as usual.
    // When false: writes to selectedSortOptions are skipped for all affected views, so
    //   upon the next launch those views return to their built-in default selections.
    //   Additionally, the existing selectedSortOptions data is cleared immediately when
    //   the preference is set to false so that current runtime state becomes ephemeral.
    //
    // When re-enabled from false: the caller (STabGeneral) is responsible for capturing
    //   the live runtime state from ViewStateManager and writing it back into
    //   selectedSortOptions so the current session's selections survive the next restart.
    static var rememberSortFilterSelections: Bool {
        get {
            return defaults.bool(forKey: Keys.rememberSortFilterSelections) }
        set {
            setIfChanged(newValue, forKey: Keys.rememberSortFilterSelections,
                logMessage: "rememberSortFilterSelections set to \(newValue)") } }

    // Removes all persisted sort/filter state from selectedSortOptions, effectively
    // making any runtime selections ephemeral. Called when the user disables the
    // rememberSortFilterSelections preference.
    static func clearViewSortStates() {
        defaults.removeObject(forKey: Keys.selectedSortOptions)
        log("Cleared all persisted view sort states (rememberSortFilterSelections disabled)")
        postPreferenceChangedEvent() }

    // MARK: - Strict Frames Table Checking
    // Governs how the FilmSheet Notes tab's frames table (ReorderableFramesList)
    // collects a row's frame number and time code. When false, each is a single
    // free-text field that accepts anything the user types. When true, each row is
    // collected as a validated range — two equal-width fields separated by a dash,
    // digits only, with the time-code halves formatted and completed as ##:##:## —
    // and the two halves are joined into the same single string the permissive
    // fields would have produced.
    //
    // This affects data ENTRY only. The storage format, the bulk-import popover,
    // and every record already on disk are untouched by it, which is what makes the
    // preference safe to turn on or off at any time.
    static var strictFramesTableChecking: Bool {
        get { return defaults.bool(forKey: Keys.strictFramesTableChecking) }
        set {
            setIfChanged(newValue, forKey: Keys.strictFramesTableChecking,
                logMessage: "strictFramesTableChecking set to \(newValue)") } }

    // MARK: - Show Watch Details Glyphs
    // Draws an inline SF Symbol ahead of the value and annotation rows in the RightSidebar's
    // "Watch Details" module — the Last Watched, Next Up for Rotation, Recorded View Count,
    // Duration and Source for Viewing values, the special-sorting and Film Queue notes, and
    // the purchase-availability note. When false those rows render as text alone.
    //
    // Purely presentational: it changes no stored value and nothing downstream reads it, so
    // it is safe to toggle at any time. Views observe it through @AppStorage rather than this
    // accessor, which is what makes a change in Settings redraw an open sidebar immediately.
    //
    // Was an internal testing constant before it was promoted here; see
    // Preferences.purchasedDiscGlyphVisibilityOverride, which still governs whether the
    // "Source for Viewing" disc glyph answers to this preference at all.
    static var showWatchDetailsAnnotationGlyphs: Bool {
        get { return defaults.bool(forKey: Keys.showWatchDetailsAnnotationGlyphs) }
        set {
            setIfChanged(newValue, forKey: Keys.showWatchDetailsAnnotationGlyphs,
                logMessage: "showWatchDetailsAnnotationGlyphs set to \(newValue)") } }

    // MARK: - ATVQ Integration
    // Dispatches the "Up Next" Queue to the ATVQ app on an Apple TV (or its Deployer
    // relay). Off, nothing ATVQ-related runs — no Bonjour browsing, no connections, and so
    // no Local Network prompt. See ATVQIntegration.swift.
    static var atvq: Bool {
        get { return defaults.bool(forKey: Keys.atvq) }
        set {
            setIfChanged(newValue, forKey: Keys.atvq,
                logMessage: "atvq set to \(newValue)") } }

    // MARK: - Override Date Clamp
    // Temporarily allows a user to enter a past viewing event dated prior to a film's
    // release date. The CustomDateStepper instances in CalendarPopover and
    // ViewingDatesTable's add/edit popovers normally clamp their lower bound to the
    // film's release date; when this preference is true, that clamp is skipped.
    //
    // IMPORTANT — this preference always resets to false on application quit
    // (see FilmTrackerApp.applicationShouldTerminate). It is a session-only,
    // "at your own risk" override, not a persistent setting: it deliberately does
    // NOT appear in SettingsObject's schema or SettingsManager's export/restore
    // pipeline, since there would be no point in saving a value that is guaranteed
    // to be false again the next time the app launches.
    static var overrideDateClamp: Bool {
        get { return defaults.bool(forKey: Keys.overrideDateClamp) }
        set {
            setIfChanged(newValue, forKey: Keys.overrideDateClamp,
                logMessage: "overrideDateClamp set to \(newValue)") } }

    // MARK: - Stored properties
    // User-selected export location (bookmark-backed).
    static var exportPathURL: URL? {
        get { return resolveBookmark(forKey: Keys.exportPathBookmark) }
        set {
            if let url = newValue {
                saveBookmark(url, forKey: Keys.exportPathBookmark,
                    logMessage: "lastFolder set to \(url.path(percentEncoded: false))")
            } else {
                defaults.removeObject(forKey: Keys.exportPathBookmark)
                postPreferenceChangedEvent() } } }

    // Persistent "Application Support" folder (fixed sandbox path).
    static var dataFolderURL: URL? { computedApplicationSupportURL }

    // Persistent "Backups" folder (fixed sandbox path).
    static var backupFolderURL: URL? {
        guard let base = computedApplicationSupportURL else { return nil }
        return base.appendingPathComponent("Backups", isDirectory: true) }

    // Persistent "PosterImages" folder (fixed sandbox path).
    static var posterImagesFolderURL: URL? {
        guard let base = computedApplicationSupportURL else { return nil }
        return base.appendingPathComponent("PosterImages", isDirectory: true) }

    // MARK: — URL Helpers
    // Lazily compute a default "Application Support" URL. This function is only called
    // on demand from the property getters — avoiding being invoked during static init().
    private static var computedApplicationSupportURL: URL? {
        // Debug sandbox: relocate the entire derived-data footprint in one place.
        // dataFolderURL, backupFolderURL, and posterImagesFolderURL are all defined in
        // terms of this property, and every disk consumer in the app (MetadataCache,
        // MemStoreCache, PosterCache, PosterUtilities, DBExporter/DBPackager,
        // DBRestorer, LoggerCore) is defined in terms of those three — so this single
        // branch redirects all of them, with no per-call-site opt-in to forget.
        #if DEBUG
        if DebugSandbox.isActive { return DebugSandbox.rootURL }
        #endif
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first?.standardizedFileURL else { return nil }
        return appSupport }

    // MARK: — Bookmark Helpers
    private static func saveBookmark(_ url: URL, forKey key: String, logMessage: String? = nil) {
        do {
            let standardized = url.standardizedFileURL
            // Do NOT call startAccessingSecurityScopedResource() here.
            //
            // This function has two callers:
            //   1. exportPathURL.set — the URL comes directly from NSOpenPanel.
            //      NSOpenPanel returns a powerbox-granted URL whose sandbox extension is
            //      already active for the duration of the call. Calling
            //      startAccessingSecurityScopedResource() on a URL that does not yet have
            //      a persisted security-scoped bookmark is incorrect — it returns false and
            //      the OS refuses the subsequent open() syscall, producing:
            //        NSCocoaErrorDomain Code=256 "Could not open() the item"
            //      Calling bookmarkData(options:.withSecurityScope) directly on the
            //      powerbox URL is the correct approach.
            //   2. resolveBookmark stale-refresh — the URL was just resolved from an
            //      existing bookmark via URL(resolvingBookmarkData:options:.withSecurityScope).
            //      The sandbox extension for that resolved URL is implicitly active through
            //      the resolve call; no explicit start/stop is needed here either.
            let data = try standardized.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                relativeTo: nil)
            defaults.set(data, forKey: key)
            if let msg = logMessage { log(msg) }
            postPreferenceChangedEvent()
        } catch { log("Failed to create bookmark for \(url): \(error)") } }

    private static func resolveBookmark(forKey key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveBookmark(url, forKey: key) }
            return url
        } catch {
            log("Failed to resolve bookmark for key '\(key)': \(error)")
            return nil } }

    // MARK: – Event Bus handling
    // Post preferences-changed event via AppEventBus
    private static func postPreferenceChangedEvent() {
        Task { @MainActor in AppEventBus.shared.preferencesChanged() } }

    // Change Guard: Sets a value only if it actually differs, logs, and posts an event.
    private static func setIfChanged<T: Equatable>(_ value: T, forKey key: String,
        logMessage: String? = nil) {
        // Compare current value using typed accessors where possible so registered
        // defaults (registered via register(defaults:)) are respected.
        var isSame = false

        if let v = value as? Bool { isSame = defaults.bool(forKey: key) == v
        } else if let v = value as? Int { isSame = defaults.integer(forKey: key) == v
        } else if let v = value as? Double { isSame = defaults.double(forKey: key) == v
        } else if let v = value as? String { isSame = defaults.string(forKey: key) == v
        } else if let v = value as? [String] {
            if let current = defaults.array(forKey: key) as? [String] { isSame = current == v
            } else { isSame = false }
        } else if let v = value as? [String: [String]] {
            if let dict = defaults.dictionary(forKey: key) as? [String: [String]] { isSame = dict == v
            } else { isSame = false }
        } else if let v = value as? [Double] {
            if let arr = defaults.array(forKey: key) as? [Double] { isSame = arr == v
            } else if let arrn = defaults.array(
                forKey: key) as? [NSNumber] { isSame = arrn.map { $0.doubleValue } == v
            } else { isSame = false }
        } else if let v = value as? [String: Bool] {
            if let dict = defaults.dictionary(forKey: key) {
                var normalized: [String: Bool] = [:]
                for (k, anyv) in dict {
                    if let b = anyv as? Bool { normalized[k] = b }
                    else if let num = anyv as? NSNumber { normalized[k] = num.boolValue } }
                isSame = normalized == v
            } else { isSame = false }
        } else {
            // Fallback for other Equatable types (may fail for bridged/unexpected types).
            let current: T? = defaults.object(forKey: key) as? T
            isSame = (current == value) }

        if isSame { return }

        defaults.set(value, forKey: key)
        if let message = logMessage { log(message) }
        postPreferenceChangedEvent() }
}

// MARK: - @AppStorage Binding
// How every view binds a preference: `@AppStorage(preference: Preferences.fooKey)` with
// the property's type written out and no initial value. The store is always
// `Preferences.store` (see its doc comment for why that matters in a debug sandbox) and
// the initial value is the registered default, so a declaration can disagree with
// neither. Bool and Int cover every preference a view binds.
extension AppStorage where Value == Bool {
    init(preference key: String) {
        self.init(wrappedValue: Preferences.registeredDefault(key, orFallback: false), key,
                  store: Preferences.store)
    }
}

extension AppStorage where Value == Int {
    init(preference key: String) {
        self.init(wrappedValue: Preferences.registeredDefault(key, orFallback: 0), key,
                  store: Preferences.store)
    }
}
