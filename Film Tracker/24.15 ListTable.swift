// MARK: - ListTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The List Membership table in RightSidebar's Details tab (module 04). It combines regular,
/// Film Queue, and smart list memberships into one sorted list.

import SwiftUI

struct ListTable: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Binding var isTableExpanded: Bool

    /// Bumped by the events that change list membership or metadata.
    ///
    /// The memberships are derived on each render. They read through `MemoryStore`, which is
    /// not `@Observable`, so a membership change that leaves the film unchanged would not
    /// trigger a re-render. Bumping this token does.
    @State private var externalRefreshToken = 0

    /// Regular (user-generated) list memberships, in canonical order. `userLists(forFilm:)` is
    /// the accessor the "Show in List" menus and the sidebar also use, so the orders agree.
    private var regularListMemberships: [CombinedListInfo] {
        guard let filmID = film?.id else { return [] }
        return dataCoordinator.userLists(forFilm: filmID)
            .map { CombinedListInfo(listName: $0.listName, displayOrder: $0.displayOrder, isSmartList: false) }
    }

    /// Film Queue (internal list) membership. Exclusivity is enforced elsewhere, but all three
    /// sections are checked here, so a corrupted film in two sections still lists both, in queue order.
    private var queueMemberships: [CombinedListInfo] {
        guard let filmID = film?.id else { return [] }
        return FilmQueueSection.allCases
            .filter { dataCoordinator.filmExists(filmID: filmID, inList: $0.listID) }
            .map { CombinedListInfo(listName: $0.rawValue, displayOrder: $0.queueOrder,
                                    isSmartList: false, isQueueList: true) }
    }

    /// Smart list memberships are read in body, so SwiftUI's @Observable tracking on SmartLists
    /// re-renders this view whenever SmartLists recalculates. A cached @State copy would not update.
    /// The other two sets need event invalidation, because MemoryStore is not observable.
    private var smartListMemberships: [CombinedListInfo] {
        guard Preferences.smartLists, let filmID = film?.id else { return [] }
        return SmartListType.allCases
            .compactMap { type -> CombinedListInfo? in
                guard dataCoordinator.smartLists.filmIDs(for: type).contains(filmID) else { return nil }
                return CombinedListInfo(
                    listName: type.rawValue,
                    displayOrder: 10000,
                    isSmartList: true
                )
            }
    }

    /// Queue memberships first, then regular lists, then smart lists. Each group uses a total
    /// order, so the result does not depend on how the non-stable sort orders equal elements.
    private var combinedLists: [CombinedListInfo] {
        (queueMemberships + regularListMemberships + smartListMemberships).sorted { lhs, rhs in
            if lhs.isQueueList != rhs.isQueueList { return lhs.isQueueList }
            if lhs.isSmartList != rhs.isSmartList { return rhs.isSmartList }
            if lhs.isSmartList {
                return lhs.listName.englishCaseInsensitiveCompare(rhs.listName) == .orderedAscending
            }
            /// Queue entries and regular lists both reach here. Two queue entries occur only after
            /// a corrupted restore that put a film in two sections. Ordering by queueOrder matches
            /// the Film Queue's Up Next, Soon, Later order, and the distinct orders never reach the tiebreak.
            ///
            /// The name tiebreak makes the regular-list order total, since Swift's sort is not
            /// stable and two lists with equal displayOrder could swap between renders. The app
            /// uniquifies list names case-insensitively on create and rename, so only a restored
            /// backup with duplicate names can still tie.
            if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
            return lhs.listName.englishCaseInsensitiveCompare(rhs.listName) == .orderedAscending
        }
    }

    var body: some View {
        /// Reads the token so the dependency described on it is established.
        let _ = externalRefreshToken

        VStack(spacing: 6) {
            /// Title.
            RSBHelpers.moduleHeader("List Membership")
            /// Evaluating combinedLists here in body registers observation on dataCoordinator.smartLists.
            ListMembershipTable(
                isTableExpanded: $isTableExpanded,
                listTable: combinedLists
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        /// No onChange(of: film) handler. A film change re-renders and recomputes the memberships,
        /// so the table never shows an empty first frame.
        .onReceive(AppEventBus.shared.filmEvents) { event in
            if case .updated(let updatedFilmID) = event,
               updatedFilmID == film?.id {
                externalRefreshToken &+= 1
            }
        }
        /// Smart list membership also changes without any film or list event: the midnight
        /// recalculation (date-based lists such as Up for Rotation and Upcoming Releases),
        /// turning smart lists on, and Queue-exclusion changes all announce themselves only
        /// through smartListsRecalculated.
        .onReceive(AppEventBus.shared.viewEvents) { event in
            guard case .smartListsRecalculated = event, film?.id != nil else { return }
            externalRefreshToken &+= 1
        }
        .onReceive(AppEventBus.shared.listEvents) { event in
            guard film?.id != nil else { return }
            switch event {
            case .membershipChanged:
                /// Refresh on every membership change. A membership check would fail for removals,
                /// because MemoryStore is updated before the event fires. Refreshing is cheap.
                externalRefreshToken &+= 1
            case .updated, .deleted:
                /// Refresh to catch name/order changes or deletions.
                externalRefreshToken &+= 1
            default:
                break
            }
        }
    }

}

// MARK: - Combined List Info
/// Represents list information that can be either a regular list, a smart list, or an
/// internal Film Queue section membership.
struct CombinedListInfo: Identifiable {
    /// Stable, content-derived identity. `ListTable.body` rebuilds these on every pass, so a
    /// fresh `UUID` each time would make `CustomTable` recreate the rows instead of updating them.
    ///
    /// The kind prefix keeps the three sources in separate namespaces, so a user list can never
    /// collide with a Film Queue section or smart list of the same name. `displayOrder` further
    /// separates regular lists.
    var id: String {
        if isQueueList { return "queue|\(listName)" }
        if isSmartList { return "smart|\(listName)" }
        return "list|\(displayOrder)|\(listName)"
    }

    let listName: String
    let displayOrder: Int
    let isSmartList: Bool
    var isQueueList: Bool = false
}

// MARK: - List Membership Table
/// CombinedListInfo is the row model directly, with no per-render mapping step.
struct ListMembershipTable: View {
    @Binding var isTableExpanded: Bool
    let listTable: [CombinedListInfo]

    var body: some View {
        CustomTable(
            listTable,
            columns: [
                CustomTableColumn("List Name", minWidth: 234, maxWidth: 234)
            ],
            isExpanded: $isTableExpanded
        ) { row in
            /// Smart lists are italic, Film Queue rows get a glyph, and regular lists are plain.
            if row.isSmartList {
                CustomTableCell(
                    Text(row.listName)
                        .italic()
                        .foregroundStyle(.secondary),
                    minWidth: 234,
                    maxWidth: 234
                )
            } else if row.isQueueList {
                /// The glyph is an inline Text attachment (see RSBHelpers.glyphPrefixedText). It is
                /// sized to match the same symbol in the Watch Details row. An inline attachment
                /// otherwise takes this table's larger text size. glyphPointSize(for:) keeps the two matched.
                CustomTableCell(
                    RSBHelpers.glyphPrefixedText(
                        RSBHelpers.queueMembershipGlyph, row.listName,
                        pointSize: RSBHelpers.glyphPointSize(
                            for: RSBHelpers.queueMembershipGlyph)),
                    minWidth: 234,
                    maxWidth: 234
                )
            } else {
                CustomTableCell(row.listName, minWidth: 234, maxWidth: 234)
            }
        }
    }
}
