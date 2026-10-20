// MARK: - ListMembershipObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Join model tracking relationships between Film and ListObject with metadata.

import Foundation
import SwiftData

@Model
final class ListMembership {
    // Primary stable id for the membership.
    var id: UUID

    // MARK: - Metadata
    var dateAdded: Date
    // Position within the list for custom ordering.
    var sortOrder: Int

    // MARK: - Relationships
    var film: Film?
    var list: ListObject?

    // MARK: - Initialization
    init(
        id: UUID = UUID(),
        film: Film,
        list: ListObject,
        dateAdded: Date = Date(),
        sortOrder: Int = 0) {
        self.id = id
        self.film = film
        self.list = list
        self.dateAdded = dateAdded
        self.sortOrder = sortOrder }
}

// MARK: - ExportableModel Conformance for ListMembership
extension ListMembership: ExportableModel {
    static var entityName: String { "ListMembership" }

    static func fetchAll(in context: ModelContext) throws -> [ListMembership] {
        let desc = FetchDescriptor<ListMembership>(sortBy: [SortDescriptor(\.dateAdded)])
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
