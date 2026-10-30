// MARK: - SettingsObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Core Data model to persist user preferences for backup/restore functionality.

import Foundation
import CoreData

@objc(SettingsObject)
final class SettingsObject: LibraryObject {
    // MARK: - Metadata
    var snapshotID: UUID { get { requiredUUID("snapshotID") } set { setValue(newValue, forKey: "snapshotID") } } // See requiredUUID.
    @NSManaged var version: Int
    @NSManaged var lastSyncDate: Date
    
    // MARK: - General Preferences
    var confirmGalleryDelete: Bool? {
        get { optionalBool("confirmGalleryDelete") }
        set { setOptionalBool(newValue, "confirmGalleryDelete") }
    }
    var confirmListEdits: Bool? {
        get { optionalBool("confirmListEdits") }
        set { setOptionalBool(newValue, "confirmListEdits") }
    }
    var listEditScope: Int? {
        get { optionalInt("listEditScope") }
        set { setOptionalInt(newValue, "listEditScope") }
    }
    var confirmReleaseDelete: Bool? {
        get { optionalBool("confirmReleaseDelete") }
        set { setOptionalBool(newValue, "confirmReleaseDelete") }
    }
    var largeGalleryGrid: Bool? {
        get { optionalBool("largeGalleryGrid") }
        set { setOptionalBool(newValue, "largeGalleryGrid") }
    }
    var showStatusBar: Bool? {
        get { optionalBool("showStatusBar") }
        set { setOptionalBool(newValue, "showStatusBar") }
    }
    var rememberRightSidebarTab: Bool? {
        get { optionalBool("rememberRightSidebarTab") }
        set { setOptionalBool(newValue, "rememberRightSidebarTab") }
    }
    var rememberRightSidebarReleasesFilter: Bool? {
        get { optionalBool("rememberRightSidebarReleasesFilter") }
        set { setOptionalBool(newValue, "rememberRightSidebarReleasesFilter") }
    }
    var autoExpandRightSidebarTables: Bool? {
        get { optionalBool("autoExpandRightSidebarTables") }
        set { setOptionalBool(newValue, "autoExpandRightSidebarTables") }
    }
    var additionalCalTableDetails: Bool? {
        get { optionalBool("additionalCalTableDetails") }
        set { setOptionalBool(newValue, "additionalCalTableDetails") }
    }
    var showReleasesSummaryTable: Bool? {
        get { optionalBool("showReleasesSummaryTable") }
        set { setOptionalBool(newValue, "showReleasesSummaryTable") }
    }
    var iCalIntegration: Bool? {
        get { optionalBool("iCalIntegration") }
        set { setOptionalBool(newValue, "iCalIntegration") }
    }
    var manualExtQuery: Bool? {
        get { optionalBool("manualExtQuery") }
        set { setOptionalBool(newValue, "manualExtQuery") }
    }
    var smartLists: Bool? {
        get { optionalBool("smartLists") }
        set { setOptionalBool(newValue, "smartLists") }
    }
    var excludeQueuedFromUpForRotation: Bool? {
        get { optionalBool("excludeQueuedFromUpForRotation") }
        set { setOptionalBool(newValue, "excludeQueuedFromUpForRotation") }
    }
    var maintainSelectionOnSearchExit: Bool? {
        get { optionalBool("maintainSelectionOnSearchExit") }
        set { setOptionalBool(newValue, "maintainSelectionOnSearchExit") }
    }
    var showSearchSuggestions: Bool? {
        get { optionalBool("showSearchSuggestions") }
        set { setOptionalBool(newValue, "showSearchSuggestions") }
    }
    var showRecentSearches: Bool? {
        get { optionalBool("showRecentSearches") }
        set { setOptionalBool(newValue, "showRecentSearches") }
    }
    var showInfoComplete: Bool? {
        get { optionalBool("showInfoComplete") }
        set { setOptionalBool(newValue, "showInfoComplete") }
    }
    var performBackupAtLaunch: Bool? {
        get { optionalBool("performBackupAtLaunch") }
        set { setOptionalBool(newValue, "performBackupAtLaunch") }
    }
    var defaultRotationThreshold: Int? {
        get { optionalInt("defaultRotationThreshold") }
        set { setOptionalInt(newValue, "defaultRotationThreshold") }
    }
    
    // MARK: - Import Preferences
    var importScanSubfolders: Bool? {
        get { optionalBool("importScanSubfolders") }
        set { setOptionalBool(newValue, "importScanSubfolders") }
    }
    var fuzzyImportMatching: Bool? {
        get { optionalBool("fuzzyImportMatching") }
        set { setOptionalBool(newValue, "fuzzyImportMatching") }
    }
    var fuzzyImportYearMatching: Bool? {
        get { optionalBool("fuzzyImportYearMatching") }
        set { setOptionalBool(newValue, "fuzzyImportYearMatching") }
    }
    var overrideSortNameField: Bool? {
        get { optionalBool("overrideSortNameField") }
        set { setOptionalBool(newValue, "overrideSortNameField") }
    }
    var allowUpdatesForDuplicateImports: Bool? {
        get { optionalBool("allowUpdatesForDuplicateImports") }
        set { setOptionalBool(newValue, "allowUpdatesForDuplicateImports") }
    }
    var allowUpdatesForDuplicateRatings: Bool? {
        get { optionalBool("allowUpdatesForDuplicateRatings") }
        set { setOptionalBool(newValue, "allowUpdatesForDuplicateRatings") }
    }
    
    // MARK: - Export Preferences
    var exportPosterImages: Bool? {
        get { optionalBool("exportPosterImages") }
        set { setOptionalBool(newValue, "exportPosterImages") }
    }
    var prunePosterImages: Bool? {
        get { optionalBool("prunePosterImages") }
        set { setOptionalBool(newValue, "prunePosterImages") }
    }
    var exportUserSettings: Bool? {
        get { optionalBool("exportUserSettings") }
        set { setOptionalBool(newValue, "exportUserSettings") }
    }
    
    // MARK: - UI State Preferences
    var maintainScrollPositionOnViewSwitch: Bool? {
        get { optionalBool("maintainScrollPositionOnViewSwitch") }
        set { setOptionalBool(newValue, "maintainScrollPositionOnViewSwitch") }
    }
    var rememberTabSelection: Bool? {
        get { optionalBool("rememberTabSelection") }
        set { setOptionalBool(newValue, "rememberTabSelection") }
    }
    var tabRememberScope: Int? {
        get { optionalInt("tabRememberScope") }
        set { setOptionalInt(newValue, "tabRememberScope") }
    }
    @NSManaged var lastRecentsCategory: String?
    @NSManaged var lastReportsCategory: String?
    var rememberImportsTab: Bool? {
        get { optionalBool("rememberImportsTab") }
        set { setOptionalBool(newValue, "rememberImportsTab") }
    }
    @NSManaged var lastImportsCategory: String?
    var rememberSortFilterSelections: Bool? {
        get { optionalBool("rememberSortFilterSelections") }
        set { setOptionalBool(newValue, "rememberSortFilterSelections") }
    }
    var confirmFilmQueueAdd: Bool? {
        get { optionalBool("confirmFilmQueueAdd") }
        set { setOptionalBool(newValue, "confirmFilmQueueAdd") }
    }
    var notifyAboutNewReleases: Bool? {
        get { optionalBool("notifyAboutNewReleases") }
        set { setOptionalBool(newValue, "notifyAboutNewReleases") }
    }
    var onlyNotifyForWishlisted: Bool? {
        get { optionalBool("onlyNotifyForWishlisted") }
        set { setOptionalBool(newValue, "onlyNotifyForWishlisted") }
    }
    var queueIsDropTarget: Bool? {
        get { optionalBool("queueIsDropTarget") }
        set { setOptionalBool(newValue, "queueIsDropTarget") }
    }
    var queueSectionOnDrop: Int? {
        get { optionalInt("queueSectionOnDrop") }
        set { setOptionalInt(newValue, "queueSectionOnDrop") }
    }
    var strictFramesTableChecking: Bool? {
        get { optionalBool("strictFramesTableChecking") }
        set { setOptionalBool(newValue, "strictFramesTableChecking") }
    }
    var showWatchDetailsAnnotationGlyphs: Bool? {
        get { optionalBool("showWatchDetailsAnnotationGlyphs") }
        set { setOptionalBool(newValue, "showWatchDetailsAnnotationGlyphs") }
    }
    var atvq: Bool? {
        get { optionalBool("atvq") }
        set { setOptionalBool(newValue, "atvq") }
    }
    
    // MARK: - Advanced Preferences
    var loggingEnabled: Bool? {
        get { optionalBool("loggingEnabled") }
        set { setOptionalBool(newValue, "loggingEnabled") }
    }
    
    // MARK: - Complex Preferences (stored as JSON strings)
    @NSManaged var selectedSortOptionsJSON: String?
    @NSManaged var ignoredDuplicatePairsJSON: String?
    
    // MARK: - Initialization
    /// Every default; see LibraryObject.init(detached:).
    convenience init() { self.init(snapshotID: UUID()) }

    convenience init(snapshotID: UUID = UUID(), version: Int = 1, lastSyncDate: Date = Date()) {
        self.init(detached: ())
        self.snapshotID = snapshotID
        self.version = version
        self.lastSyncDate = lastSyncDate
    }
    
    // MARK: - Constants
    static let currentVersion = 1
    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

// MARK: - Exportable Protocol Conformance
extension SettingsObject: ExportableModel {
    // DBReader uses exportStableID() to get the object's UUID
    // If this returns nil, DBReader generates a random UUID for export!
    func exportStableID() -> String? {
        return snapshotID.uuidString
    }
    
    // Exports every property explicitly; an unset optional is left out.
    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var props: [String: Any] = [:]
        
        // Metadata (always present)
        props["snapshotID"] = snapshotID
        props["version"] = version
        props["lastSyncDate"] = lastSyncDate
        
        // General Preferences - explicitly check each optional
        if let val = confirmGalleryDelete { props["confirmGalleryDelete"] = val }
        if let val = confirmListEdits { props["confirmListEdits"] = val }
        if let val = listEditScope { props["listEditScope"] = val }
        if let val = confirmReleaseDelete { props["confirmReleaseDelete"] = val }
        if let val = largeGalleryGrid { props["largeGalleryGrid"] = val }
        if let val = showStatusBar { props["showStatusBar"] = val }
        if let val = rememberRightSidebarTab { props["rememberRightSidebarTab"] = val }
        if let val = rememberRightSidebarReleasesFilter { props["rememberRightSidebarReleasesFilter"] = val }
        if let val = autoExpandRightSidebarTables { props["autoExpandRightSidebarTables"] = val }
        if let val = additionalCalTableDetails { props["additionalCalTableDetails"] = val }
        if let val = showReleasesSummaryTable { props["showReleasesSummaryTable"] = val }
        if let val = iCalIntegration { props["iCalIntegration"] = val }
        if let val = manualExtQuery { props["manualExtQuery"] = val }
        if let val = smartLists { props["smartLists"] = val }
        if let val = excludeQueuedFromUpForRotation { props["excludeQueuedFromUpForRotation"] = val }
        if let val = maintainSelectionOnSearchExit { props["maintainSelectionOnSearchExit"] = val }
        if let val = showSearchSuggestions { props["showSearchSuggestions"] = val }
        if let val = showRecentSearches { props["showRecentSearches"] = val }
        if let val = showInfoComplete { props["showInfoComplete"] = val }
        if let val = performBackupAtLaunch { props["performBackupAtLaunch"] = val }
        if let val = defaultRotationThreshold { props["defaultRotationThreshold"] = val }
        
        // Import Preferences
        if let val = importScanSubfolders { props["importScanSubfolders"] = val }
        if let val = fuzzyImportMatching { props["fuzzyImportMatching"] = val }
        if let val = fuzzyImportYearMatching { props["fuzzyImportYearMatching"] = val }
        if let val = overrideSortNameField { props["overrideSortNameField"] = val }
        if let val = allowUpdatesForDuplicateImports { props["allowUpdatesForDuplicateImports"] = val }
        if let val = allowUpdatesForDuplicateRatings { props["allowUpdatesForDuplicateRatings"] = val }
        
        // Export Preferences
        if let val = exportPosterImages { props["exportPosterImages"] = val }
        if let val = prunePosterImages { props["prunePosterImages"] = val }
        if let val = exportUserSettings { props["exportUserSettings"] = val }
        
        // UI State Preferences
        if let val = maintainScrollPositionOnViewSwitch { props["maintainScrollPositionOnViewSwitch"] = val }
        if let val = rememberTabSelection { props["rememberTabSelection"] = val }
        if let val = tabRememberScope { props["tabRememberScope"] = val }
        if let val = lastRecentsCategory { props["lastRecentsCategory"] = val }
        if let val = lastReportsCategory { props["lastReportsCategory"] = val }
        if let val = rememberImportsTab { props["rememberImportsTab"] = val }
        if let val = lastImportsCategory { props["lastImportsCategory"] = val }
        if let val = rememberSortFilterSelections { props["rememberSortFilterSelections"] = val }
        if let val = confirmFilmQueueAdd { props["confirmFilmQueueAdd"] = val }
        if let val = notifyAboutNewReleases { props["notifyAboutNewReleases"] = val }
        if let val = onlyNotifyForWishlisted { props["onlyNotifyForWishlisted"] = val }
        if let val = queueIsDropTarget { props["queueIsDropTarget"] = val }
        if let val = queueSectionOnDrop { props["queueSectionOnDrop"] = val }
        if let val = strictFramesTableChecking { props["strictFramesTableChecking"] = val }
        if let val = showWatchDetailsAnnotationGlyphs { props["showWatchDetailsAnnotationGlyphs"] = val }
        if let val = atvq { props["atvq"] = val }
        
        // Advanced Preferences
        if let val = loggingEnabled { props["loggingEnabled"] = val }
        
        // Complex Preferences (JSON strings)
        if let val = selectedSortOptionsJSON { props["selectedSortOptionsJSON"] = val }
        if let val = ignoredDuplicatePairsJSON { props["ignoredDuplicatePairsJSON"] = val }
        
        // No relationships for SettingsObject
        return (props, [:])
    }
}
