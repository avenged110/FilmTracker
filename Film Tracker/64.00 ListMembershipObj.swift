// MARK: - ListMembershipObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Join model tracking relationships between Film and ListObject with metadata.

import Foundation
import CoreData

@objc(ListMembership)
final class ListMembership: LibraryObject {
    // Primary stable id for the membership.
    var id: UUID { get { requiredUUID("id") } set { setValue(newValue, forKey: "id") } } // See requiredUUID.

    // MARK: - Metadata
    @NSManaged var dateAdded: Date
    // Position within the list for custom ordering.
    @NSManaged var sortOrder: Int

    // MARK: - Relationships
    @NSManaged var film: Film?
    @NSManaged var list: ListObject?

    // MARK: - Initialization
    convenience init(
        id: UUID = UUID(),
        film: Film,
        list: ListObject,
        dateAdded: Date = Date(),
        sortOrder: Int = 0) {
        self.init(detached: ())
        // Joined to the film's context before the relationships are set: Core Data refuses a
        // relationship between an object in a context and one in none.
        unsafe film.managedObjectContext?.insert(self)
        self.id = id
        self.film = film
        self.list = list
        self.dateAdded = dateAdded
        self.sortOrder = sortOrder }
}

// MARK: - ExportableModel Conformance for ListMembership
extension ListMembership: ExportableModel {

    static func fetchAll(in context: NSManagedObjectContext) throws -> [ListMembership] {
        let desc = ListMembership.request(sortedBy: [NSSortDescriptor(key: "dateAdded", ascending: true)])
        return try context.fetch(desc) }

    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var props: [String: Any] = [:]
        props["id"] = self.id
        props["dateAdded"] = self.dateAdded
        props["sortOrder"] = self.sortOrder

        // Export the related IDs for reconstruction during import.
        props["filmID"] = self.film?.id
        props["listID"] = self.list?.listID

        // No relationship arrays needed - relationships are via IDs.
        let rels: [String: [Any]] = [:]
        return (properties: props, relationships: rels) }

    func exportStableID() -> String? { return self.id.uuidString }
}
