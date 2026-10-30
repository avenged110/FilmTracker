// MARK: - ListObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the Core Data model for a List object in the user's library.

import Foundation
import CoreData

@objc(ListObject)
final class ListObject: LibraryObject {
    // listID is indexed (LibraryModel): it is the target of every predicate-based fetch
    // that resolves a list in DataManager.

    // Primary stable id for the list.
    var listID: UUID { get { requiredUUID("listID") } set { setValue(newValue, forKey: "listID") } } // See requiredUUID.

    // MARK: - List Properties
    @NSManaged var listName: String
    @NSManaged var viewStyle: String
    @NSManaged var sortFilterOptions: [String]
    @NSManaged var displayOrder: Int

    // MARK: - Film Membership Relationship
    @NSManaged var memberships: Set<ListMembership>

    var id: UUID { listID }

    // MARK: - Initialization
    /// Every default; see LibraryObject.init(detached:).
    convenience init() { self.init(listID: UUID()) }

    convenience init(
        listID: UUID = UUID(),
        listName: String = "",
        viewStyle: String = "",
        sortFilterOptions: [String] = [],
        displayOrder: Int = 0) {
        self.init(detached: ())
        self.listID = listID
        self.listName = listName
        self.viewStyle = viewStyle
        self.sortFilterOptions = sortFilterOptions
        self.displayOrder = displayOrder }

    // MARK: - Relationship Helpers
    // Returns the film IDs in this list.
    var filmIDs: [UUID] {
        return memberships
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { $0.film?.id } }

    // Returns the film IDs as strings (for compatibility with existing code).
    var filmIDStrings: [String] { return filmIDs.map { $0.uuidString } }
}

// MARK: - ExportableModel Conformance for ListObject
extension ListObject: ExportableModel {

    static func fetchAll(in context: NSManagedObjectContext) throws -> [ListObject] {
        let desc = ListObject.request(sortedBy: [NSSortDescriptor(key: "listName", ascending: true)])
        return try context.fetch(desc) }

    func extractExportValues() -> (properties: [String: Any], relationships: [String : [Any]]) {
        var props: [String: Any] = [:]
        props["listID"] = self.listID
        props["listName"] = self.listName
        props["viewStyle"] = self.viewStyle
        props["sortFilterOptions"] = self.sortFilterOptions
        props["displayOrder"] = self.displayOrder

        // Export film membership as array of film IDs for backward compatibility
        props["containsFilms"] = self.filmIDStrings
        // Don't export memberships as a relationship array
        // These are handled via the ListMembership join entity
        let rels: [String: [Any]] = [:]
        return (properties: props, relationships: rels) }

    func exportStableID() -> String? { return self.listID.uuidString }
}
