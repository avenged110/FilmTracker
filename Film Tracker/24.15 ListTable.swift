// MARK: - ListTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "Details" tab, module 04.
// List table displaying list membership.

import SwiftUI
import SwiftData

struct ListTable: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Binding var isTableExpanded: Bool

    /// Bumped by the events that change list membership or list metadata.
    ///
    /// The memberships below are derived rather than cached, so a film change recomputes
    /// them for free — but they read through `MemoryStore`, which is a plain class and
    /// not `@Observable`, so a membership change that leaves the film value untouched
    /// registers no dependency and would otherwise never schedule a re-render. This is
    /// the same reason the `@State` caches they replace needed `onReceive` invalidation;
    /// what changes is that the events now invalidate rather than recompute, which is
    /// both less code and impossible to get out of step with the render.
    @State private var externalRefreshToken = 0

    /// Regular (user-generated) list memberships.
    ///
    /// `userLists(forFilm:)` excludes the internal Film Queue lists — the membership
    /// table shows only the user-generated lists the film belongs to — and returns them
    /// in the canonical list order, the same accessor the "Show in List" menus read, so
    /// this table cannot present two equally-ordered lists differently from them or from
    /// the sidebar.
    private var regularListMemberships: [CombinedListInfo] {
        guard let filmID = film?.id else { return [] }
        return dataCoordinator.userLists(forFilm: filmID)
            .map { CombinedListInfo(listName: $0.listName, displayOrder: $0.displayOrder, isSmartList: false) }
    }

    /// Film Queue (internal list) membership.
    ///
    /// Section exclusivity is enforced elsewhere in the Film Queue subsystem, so a film
    /// belongs to at most one of the three internal lists at any time — but all three are
    /// checked independently here rather than assuming that invariant holds. Each entry
    /// carries its own queueOrder so a film that (through corruption) is in two sections
    /// still lists them in queue order — see combinedLists below.
    private var queueMemberships: [CombinedListInfo] {
        guard let filmID = film?.id else { return [] }
        return FilmQueueSection.allCases
            .filter { dataCoordinator.filmExists(filmID: filmID, inList: $0.listID) }
            .map { CombinedListInfo(listName: $0.rawValue, displayOrder: $0.queueOrder,
                                    isSmartList: false, isQueueList: true) }
    }

    // Smart list memberships are read directly in body so SwiftUI's @Observable tracking
    // on SmartLists fires automatic re-renders whenever SmartLists recalculates — no events
    // needed. Reading them through a cached @State variable broke this and was the root cause
    // of smart list memberships not updating in real time after the DTO architectural shift.
    // The two membership sets above are now derived for the same reason, differing only in
    // that MemoryStore grants them no observation, so they still need event invalidation.
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

    // Combined and sorted list for display. Called directly in body so all three sources
    // are consumed together in one render pass.
    // Queue memberships always sort to the top, ahead of both regular and smart lists.
    // Queue memberships first, then regular lists, then smart lists. Within each group
    // the comparison is total, so the result is fully determined by the data rather than
    // by the (unspecified) order Swift's non-stable sort happens to leave equal elements
    // in: queue entries carry their section's queueOrder, regular lists carry the same
    // displayOrder the sidebar orders by, and smart lists compare by name.
    private var combinedLists: [CombinedListInfo] {
        (queueMemberships + regularListMemberships + smartListMemberships).sorted { lhs, rhs in
            if lhs.isQueueList != rhs.isQueueList { return lhs.isQueueList }
            if lhs.isSmartList != rhs.isSmartList { return rhs.isSmartList }
            if lhs.isSmartList {
                return lhs.listName.localizedCaseInsensitiveCompare(rhs.listName) == .orderedAscending
            }
            // Both queue entries and regular lists land here. Two queue entries are only
            // reachable at all through a corrupted or pre-exclusivity restore that left a
            // film in more than one section; ordering them by queueOrder presents that in
            // the same Up Next → Soon → Later order the Film Queue itself uses, rather
            // than the arbitrary order the previous shared -1 sentinel produced — and
            // because those orders are distinct, queue entries never reach the tiebreak.
            //
            // The name tiebreak is what makes the regular-list comparison total. Feeding
            // this sort an already-canonically-ordered array is not enough on its own:
            // Swift's sort is not guaranteed stable, so two lists sharing a displayOrder
            // could still swap between renders. User list names are uniquified
            // case-insensitively on create and rename, so this resolves every such tie
            // that the app itself can produce (a restored backup carrying two identically
            // named lists is no worse off than before).
            if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
            return lhs.listName.localizedCaseInsensitiveCompare(rhs.listName) == .orderedAscending
        }
    }

    var body: some View {
        // Establishes the dependency described on `externalRefreshToken`.
        let _ = externalRefreshToken

        VStack(spacing: 6) {
            // Title.
            RSBHelpers.moduleHeader("List Membership")
            // combinedLists is evaluated here inside body, which registers SwiftUI observation
            // on dataCoordinator.smartLists — so smart list changes re-render automatically.
            ListMembershipTable(
                isTableExpanded: $isTableExpanded,
                listTable: combinedLists
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No `onChange(of: film)` handler: the memberships are derived, so a film change
        // already re-renders this view and recomputes them. That also removes the
        // first-frame blank-row flash the old handler's `initial: true` existed to
        // suppress — there is no window in which the values can be unpopulated.
        .onReceive(AppEventBus.shared.filmEvents) { event in
            if case .updated(let updatedFilmID) = event,
               updatedFilmID == film?.id {
                externalRefreshToken &+= 1
            }
        }
        .onReceive(AppEventBus.shared.listEvents) { event in
            guard film?.id != nil else { return }
            switch event {
            case .membershipChanged:
                // Always refresh on any membership change. The previous approach checked
                // whether the film was currently a member of the changed list, but that
                // test always fails for removal events because MemoryStore is updated before
                // the event fires — so the film is already gone from the list by the time
                // this handler runs. Refreshing unconditionally is correct and inexpensive.
                externalRefreshToken &+= 1
            case .updated, .deleted:
                // Refresh to catch name/order changes or deletions.
                externalRefreshToken &+= 1
            default:
                break
            }
        }
    }

}

// MARK: - Combined List Info
// Represents list information that can be either a regular list, a smart list, or an
// internal Film Queue section membership.
struct CombinedListInfo: Identifiable {
    /// Stable, content-derived identity.
    ///
    /// A freshly-generated `UUID` per instance would be wrong here: `combinedLists`
    /// is assembled inside `ListTable.body`, and `smartListMemberships` is a computed
    /// property evaluated on *every* body pass (that is deliberate — it is what
    /// registers SwiftUI's `@Observable` dependency on `dataCoordinator.smartLists`).
    /// With per-instance UUIDs, every one of those passes handed `CustomTable`'s
    /// `ForEach` a set of never-before-seen ids for the smart-list rows, so SwiftUI
    /// tore down and rebuilt them instead of diffing them in place.
    ///
    /// The kind prefix keeps the three sources in separate id namespaces, so a
    /// user-generated list that happens to share a name with a Film Queue section or
    /// a smart list can never collide with it; `displayOrder` further disambiguates
    /// regular lists.
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
// CombinedListInfo is used directly as the row model, eliminating a redundant
// per-render mapping step. CombinedListInfo is already Identifiable.
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
            // Use styled Text for smart lists, glyph-prefixed Text for Film Queue
            // memberships, and plain Text for regular lists.
            if row.isSmartList {
                CustomTableCell(
                    Text(row.listName)
                        .italic()
                        .foregroundStyle(.secondary),
                    minWidth: 234,
                    maxWidth: 234
                )
            } else if row.isQueueList {
                // The glyph is inlined as a Text attachment so it participates in the
                // text's own layout flow rather than a separate HStack element. See
                // RSBHelpers.glyphPrefixedText.
                //
                // Pinned to the size the same symbol is drawn at in the "Watch Details"
                // module's queue-membership row. Left to inherit this cell's font it rendered
                // noticeably larger — an inline attachment takes the size of the text around
                // it, and this table's text is larger than a sidebar row's glyph. The two are
                // the same mark meaning the same thing, one module apart, so they should not
                // differ in size; asking glyphPointSize(for:) rather than restating a number
                // keeps them matched if that scale is ever retuned.
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
