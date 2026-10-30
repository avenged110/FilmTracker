// MARK: - ImportSessionObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Data model for tracking individual import sessions.

import Foundation
import CoreData

@objc(ImportSession)
final class ImportSession: LibraryObject {
    var id: UUID { get { requiredUUID("id") } set { setValue(newValue, forKey: "id") } } // See requiredUUID.
    @NSManaged var sessionDate: Date
    // Type of import: "metadata" or "ratings".
    @NSManaged var importType: String
    @NSManaged var totalItems: Int
    @NSManaged var successCount: Int
    @NSManaged var errorCount: Int
    @NSManaged var duplicateCount: Int
    // Items whose information was updated (duplicate matched with differing fields).
    @NSManaged var updatedCount: Int
    // For ratings imports: Films not in library.
    @NSManaged var notFoundCount: Int
    @NSManaged var errorFileNames: [String]
    // Titles (the value written to the imported Film model object's "name" field) for
    // films newly added during this session. Populated by MetaImporter/RatingsImporter
    // via ImportProgress and surfaced in the ImportsView "Details" popover's "Added" tab.
    @NSManaged var addedTitles: [String]
    // Titles of films whose existing library entry was updated during this session.
    // Surfaced in the "Updated" tab of the Details popover.
    @NSManaged var updatedTitles: [String]
    // Titles of films that were matched as duplicates and skipped during this session.
    // Surfaced in the "Duplicates" tab of the Details popover.
    @NSManaged var duplicateTitles: [String]
    @NSManaged var isCompleted: Bool
    @NSManaged var isCanceled: Bool

    convenience init(
        id: UUID = UUID(),
        sessionDate: Date = Date(),
        importType: String,
        totalItems: Int = 0,
        successCount: Int = 0,
        errorCount: Int = 0,
        duplicateCount: Int = 0,
        updatedCount: Int = 0,
        notFoundCount: Int = 0,
        errorFileNames: [String] = [],
        addedTitles: [String] = [],
        updatedTitles: [String] = [],
        duplicateTitles: [String] = [],
        isCompleted: Bool = false,
        isCanceled: Bool = false) {
        self.init(detached: ())
        self.id = id
        self.sessionDate = sessionDate
        self.importType = importType
        self.totalItems = totalItems
        self.successCount = successCount
        self.errorCount = errorCount
        self.duplicateCount = duplicateCount
        self.updatedCount = updatedCount
        self.notFoundCount = notFoundCount
        self.errorFileNames = errorFileNames
        self.addedTitles = addedTitles
        self.updatedTitles = updatedTitles
        self.duplicateTitles = duplicateTitles
        self.isCompleted = isCompleted
        self.isCanceled = isCanceled }

    // MARK: - Formatters
    // DateFormatter is expensive to construct; share a single instance per format.
    // DateFormatter is Sendable in the macOS 15 / Swift 6 SDK — no nonisolated(unsafe)
    // annotation is needed or appropriate.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.calendar = AppCalendar.gregorian  // the locale is the user's; the calendar is not (AppCalendar)
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var dateFormatted: String { Self.formattedDate(sessionDate) }

    var timeFormatted: String { Self.formattedTime(sessionDate) }

    /// The card header's date and time, for a session held as a value (ImportSessionRecord).
    static func formattedDate(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func formattedTime(_ date: Date) -> String { timeFormatter.string(from: date) }
}

// MARK: - ExportableModel Conformance
extension ImportSession: ExportableModel {
    // Custom implementation to ensure all properties are exported correctly.
    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var properties: [String: Any] = [:]
        
        // Explicitly export each property.
        properties["id"] = id
        properties["sessionDate"] = sessionDate
        properties["importType"] = importType
        properties["totalItems"] = totalItems
        properties["successCount"] = successCount
        properties["errorCount"] = errorCount
        properties["duplicateCount"] = duplicateCount
        properties["updatedCount"] = updatedCount
        properties["notFoundCount"] = notFoundCount
        properties["errorFileNames"] = errorFileNames
        properties["addedTitles"] = addedTitles
        properties["updatedTitles"] = updatedTitles
        properties["duplicateTitles"] = duplicateTitles
        properties["isCompleted"] = isCompleted
        properties["isCanceled"] = isCanceled
        
        // No relationships for ImportSession.
        let relationships: [String: [Any]] = [:]
        
        return (properties, relationships)
    }
    
    func exportStableID() -> String? {
        return id.uuidString
    }
}
