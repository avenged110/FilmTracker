// MARK: - SavedSearchObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the SwiftData model for a saved search. The DataManager operations that read and
// write it live in DataManager.swift, beside its private commit().

import Foundation
import SwiftData

// MARK: - Model

/// A saved search as it is stored. Its own entity rather than a JSON preference, so it is
/// part of the library: every backup carries it whether or not "Export user settings" is
/// on, and a restore brings it back with the lists its `#list` tokens may name.
///
/// The query is one JSON string (SavedSearchCodec) rather than a relationship or a
/// Codable attribute: a token's shape can change without a SwiftData migration, and the
/// backup format sees a plain string property it already knows how to carry.
///
/// Every property has a default and none is unique-constrained, so adding the entity to
/// the schema is a lightweight migration of an existing store (as the optional Film
/// properties are — see FilmObj.swift).
@Model
final class SavedSearchObject {
    #Index<SavedSearchObject>([\.searchID])

    var searchID: UUID = UUID()
    var name: String = ""
    var queryJSON: String = ""
    var displayOrder: Int = 0
    var dateCreated: Date = Date()
    var dateModified: Date = Date()

    init(searchID: UUID, name: String, queryJSON: String, displayOrder: Int,
         dateCreated: Date, dateModified: Date) {
        self.searchID = searchID
        self.name = name
        self.queryJSON = queryJSON
        self.displayOrder = displayOrder
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    convenience init(_ search: SavedSearch) {
        self.init(searchID: search.id, name: search.name, queryJSON: SavedSearchCodec.encode(search.query),
                  displayOrder: search.displayOrder, dateCreated: search.dateCreated,
                  dateModified: search.dateModified)
    }

    /// Copies `search`'s values in, leaving the ID alone.
    func apply(_ search: SavedSearch) {
        name = search.name
        queryJSON = SavedSearchCodec.encode(search.query)
        displayOrder = search.displayOrder
        dateModified = search.dateModified
    }

    /// The value form, with any stored rules this build cannot read left out (`dropped`).
    /// A query that is not a JSON object at all (`isUnreadable`) loads as an empty one. Either
    /// way the row itself is left as it is, so nothing is lost until the user saves the search
    /// again; until then it needs review (SavedSearchStore.needsReview).
    var decoded: (search: SavedSearch, dropped: [StoredToken], isUnreadable: Bool) {
        let decoded = SavedSearchCodec.decode(queryJSON)
        let query = decoded?.query ?? SavedSearchQuery(tokens: [], text: "")
        let search = SavedSearch(id: searchID, name: name, query: query, displayOrder: displayOrder,
                                 dateCreated: dateCreated, dateModified: dateModified)
        return (search, decoded?.dropped ?? [], decoded == nil)
    }
}

// MARK: - Export

extension SavedSearchObject: ExportableModel {
    static var entityName: String { "SavedSearchObject" }

    static func fetchAll(in context: ModelContext) throws -> [SavedSearchObject] {
        try context.fetch(FetchDescriptor<SavedSearchObject>(sortBy: [SortDescriptor(\.displayOrder)]))
    }

    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        let props: [String: Any] = [
            "searchID": searchID,
            "name": name,
            "queryJSON": queryJSON,
            "displayOrder": displayOrder,
            "dateCreated": dateCreated,
            "dateModified": dateModified,
        ]
        return (properties: props, relationships: [:])
    }

    func exportStableID() -> String? { searchID.uuidString }
}
