// MARK: - SettingsObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Core Data model to persist user preferences for backup/restore functionality.

import Foundation
import CoreData

@objc(SettingsObject)
final class SettingsObject: LibraryObject {
    // MARK: - Metadata
    var snapshotID: UUID { get { requiredUUID("snapshotID") } set { setValue(newValue, forKey: "snapshotID") } } /// See requiredUUID.
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
    var recommendations: Bool? {
        get { optionalBool("recommendations") }
        set { setOptionalBool(newValue, "recommendations") }
    }
    var showTagsInSidebar: Int? {
        get { optionalInt("showTagsInSidebar") }
        set { setOptionalInt(newValue, "showTagsInSidebar") }
    }
    var sidebarTagOrder: Int? {
        get { optionalInt("sidebarTagOrder") }
        set { setOptionalInt(newValue, "sidebarTagOrder") }
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
    var confirmSpecialSortingAddForQueued: Bool? {
        get { optionalBool("confirmSpecialSortingAddForQueued") }
        set { setOptionalBool(newValue, "confirmSpecialSortingAddForQueued") }
    }
    var confirmChangesBeforeDisappear: Bool? {
        get { optionalBool("confirmChangesBeforeDisappear") }
        set { setOptionalBool(newValue, "confirmChangesBeforeDisappear") }
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
    @NSManaged var pinnedTagsJSON: String?
    @NSManaged var tagUsesJSON: String?
    
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
    /// DBReader uses exportStableID() to get the object's UUID
    /// If this returns nil, DBReader generates a random UUID for export!
    func exportStableID() -> String? {
        return snapshotID.uuidString
    }
    
    /// Exports the metadata, then every preference column the model declares
    /// (`LibraryModel.settingsObjectAttributes`), so a preference added to the model is backed up
    /// with no change here. An unset optional is left out.
    ///
    /// Each value is read through the accessor for its kind, never as the raw stored NSNumber:
    /// the backup writer tests `as? Bool` before `as? Int`, and an NSNumber holding an Int 0 or 1
    /// would pass the Bool test and be written as a Bool.
    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var props: [String: Any] = [:]
        
        /// Metadata (always present)
        props["snapshotID"] = snapshotID
        props["version"] = version
        props["lastSyncDate"] = lastSyncDate
        
        /// Preferences: every attribute of an optional kind. The three metadata columns above
        /// are the only others.
        for (name, kind) in LibraryModel.settingsObjectAttributes {
            switch kind {
            case .optionalBool:   if let val = optionalBool(name) { props[name] = val }
            case .optionalInt:    if let val = optionalInt(name) { props[name] = val }
            case .optionalString: if let val = value(forKey: name) as? String { props[name] = val }
            case .string, .int, .bool, .double, .date, .uuid, .strings: break
            }
        }
        
        /// No relationships for SettingsObject
        return (props, [:])
    }
}
