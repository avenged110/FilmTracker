// MARK: - ListObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the SwiftData model for a List object in the user's library.

import Foundation
import SwiftData

@Model
final class ListObject: Identifiable {
    // Index on the custom UUID primary key.
    // ListObject.listID is the target of every predicate-based fetch that
    // resolves a list in DataManager. The index converts those lookups from
    // full-table scans to O(log n), with the same non-destructive migration
    // semantics as the corresponding index on Film.id.
    #Index<ListObject>([\.listID])

    // Primary stable id for the list.
    var listID: UUID

    // MARK: - List Properties
    var listName: String
    var viewStyle: String
    var sortFilterOptions: [String]
    var displayOrder: Int

    // MARK: - Film Membership Relationship
    @Relationship(deleteRule: .cascade, inverse: \ListMembership.list)
    var memberships: [ListMembership] = []

    var id: UUID { listID }

    // MARK: - Initialization
    init(
        listID: UUID = UUID(),
        listName: String = "",
        viewStyle: String = "",
        sortFilterOptions: [String] = [],
        displayOrder: Int = 0) {
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
    static var entityName: String { "ListObject" }

    static func fetchAll(in context: ModelContext) throws -> [ListObject] {
        let desc = FetchDescriptor<ListObject>(sortBy: [SortDescriptor(\.listName)])
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
