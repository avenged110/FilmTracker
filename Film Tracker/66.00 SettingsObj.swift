// MARK: - SettingsObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftData model to persist user preferences for backup/restore functionality.

import Foundation
import SwiftData

@Model
final class SettingsObject {
    // MARK: - Metadata
    @Attribute(.unique) var snapshotID: UUID
    var version: Int
    var lastSyncDate: Date
    
    // MARK: - General Preferences
    var confirmGalleryDelete: Bool?
    var confirmListEdits: Bool?
    var listEditScope: Int?
    var confirmReleaseDelete: Bool?
    var largeGalleryGrid: Bool?
    var showStatusBar: Bool?
    var rememberRightSidebarTab: Bool?
    var rememberRightSidebarReleasesFilter: Bool?
    var autoExpandRightSidebarTables: Bool?
    var additionalCalTableDetails: Bool?
    var showReleasesSummaryTable: Bool?
    var iCalIntegration: Bool?
    var manualExtQuery: Bool?
    var smartLists: Bool?
    var excludeQueuedFromUpForRotation: Bool?
    var maintainSelectionOnSearchExit: Bool?
    var showSearchSuggestions: Bool?
    var showRecentSearches: Bool?
    var showInfoComplete: Bool?
    var performBackupAtLaunch: Bool?
    var defaultRotationThreshold: Int?
    
    // MARK: - Import Preferences
    var importScanSubfolders: Bool?
    var fuzzyImportMatching: Bool?
    var fuzzyImportYearMatching: Bool?
    var overrideSortNameField: Bool?
    var allowUpdatesForDuplicateImports: Bool?
    var allowUpdatesForDuplicateRatings: Bool?
    
    // MARK: - Export Preferences
    var exportPosterImages: Bool?
    var prunePosterImages: Bool?
    var exportUserSettings: Bool?
    
    // MARK: - UI State Preferences
    var maintainScrollPositionOnViewSwitch: Bool?
    var rememberTabSelection: Bool?
    var tabRememberScope: Int?
    var lastRecentsCategory: String?
    var lastReportsCategory: String?
    var rememberImportsTab: Bool?
    var lastImportsCategory: String?
    var rememberSortFilterSelections: Bool?
    var confirmFilmQueueAdd: Bool?
    var notifyAboutNewReleases: Bool?
    var onlyNotifyForWishlisted: Bool?
    var queueIsDropTarget: Bool?
    var queueSectionOnDrop: Int?
    var strictFramesTableChecking: Bool?
    var showWatchDetailsAnnotationGlyphs: Bool?
    var atvq: Bool?
    
    // MARK: - Advanced Preferences
    var loggingEnabled: Bool?
    
    // MARK: - Complex Preferences (stored as JSON strings)
    var selectedSortOptionsJSON: String?
    var ignoredDuplicatePairsJSON: String?
    
    // MARK: - Initialization
    init(snapshotID: UUID = UUID(), version: Int = 1, lastSyncDate: Date = Date()) {
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
    
    // Override extractExportValues() to explicitly export all properties
    // The default Mirror-based implementation doesn't properly handle SwiftData optional properties
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
