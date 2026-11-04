// MARK: - CalendarTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Viewing History table in RightSidebar's Details tab (module 03), in compact and detailed
/// forms. Both forms are built from one shared resolution of the viewing entries, which the PDF export also uses.

import SwiftUI

struct CalendarTable: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Binding var isTableExpanded: Bool
    @AppStorage(preference: Preferences.additionalCalTableDetailsKey) private var additionalCalTableDetails: Bool

    var body: some View {
        VStack(spacing: 6) {
            /// Title.
            RSBHelpers.moduleHeader("Viewing History")
            /// Table.
            if additionalCalTableDetails {
                ViewingHistoryDetailedTable(
                    isTableExpanded: $isTableExpanded,
                    calendarTable: film?.calendarTable ?? []
                )
            } else {
                ViewingHistoryTable(
                    isTableExpanded: $isTableExpanded,
                    calendarTable: film?.calendarTable ?? []
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Table Row Models

/// Row model for the compact viewing history table. `id` is derived from the stored entry,
/// not minted per rebuild; see `RowIdentityAllocator`.
private struct CalendarRow: Identifiable {
    let id: String
    let date: String
    let daysSince: String
}

/// Row model for the detailed viewing history table.
private struct DetailedCalendarRow: Identifiable {
    let id: String
    let date: String
    let daysSince: String
    let timeFromToday: String
    let version: String
}

// MARK: - Row Identity

/// Gives each row an identity derived from the stored entry, stable across rebuilds.
///
/// A fresh `UUID` per rebuild would give `CustomTable`'s `ForEach` identifiers that matched
/// nothing on screen, so every row would be recreated instead of updated. Matches
/// `CombinedListInfo` in ListTable.swift.
///
/// The entry (the raw `"yyyy.MM.dd"` string plus any version code) survives re-sorting, so it
/// is the natural key. Duplicates are a data anomaly, but `ForEach` misbehaves with duplicate
/// identifiers, so repeats get an occurrence suffix. The first occurrence keeps the bare entry.
private struct RowIdentityAllocator {
    private var occurrences: [String: Int] = [:]

    mutating func identity(for entry: String) -> String {
        let seen = occurrences[entry, default: 0]
        occurrences[entry] = seen + 1
        return seen == 0 ? entry : "\(entry)#\(seen)"
    }
}

// MARK: - Shared Entry Resolution

/// One viewing-history entry, resolved once for both tables.
///
/// Both tables show the same viewings, in the same order, with the same "Since Prior" gaps and
/// row identities. The detailed table adds two columns derived from fields carried here.
/// `viewingHistoryEntries(from:)` is the single definition of these rules.
///
/// Internal, not private: the PDF's "Viewing History" section (85.30 PDFSections.swift) is a
/// third consumer. A separate derivation there would be a fourth copy of these rules.
struct ViewingHistoryEntry {
    /// Content-derived row identity — see `RowIdentityAllocator`.
    let id: String
    /// The raw stored entry, version code and all. Retained because the detailed table's
    /// "Version" column reads it, and because it is what the identity is derived from.
    let original: String
    /// `original` parsed. Retained so the detailed table's "Time Ago" column does not
    /// have to parse it a second time.
    let date: Date
    /// "Month Day, Year", version code stripped.
    let formattedDate: String
    /// Days between this viewing and the next-older one, already pluralized. Empty for
    /// the oldest entry, which has no prior to measure against.
    let daysSincePrior: String
}

/// Resolves a stored `calendarTable` into the ordered, fully derived rows both tables use.
///
/// This is the one place that parses and sorts descending, allocates row identities, and
/// formats the gap to the next-older entry. Both tables only map these entries onto their own
/// rows, so they cannot disagree about which viewings appear, their order, or the gaps.
///
/// The PDF export calls this too (see `ViewingHistoryEntry`). Unparseable entries are dropped.
///
/// The gap uses the parsed `Date`s, not a second parse of the strings. It uses the same
/// calendar, `.day` component, and absolute value as the earlier per-table code. Every entry
/// that survives the `compactMap` parsed, so the day difference is always available.
func viewingHistoryEntries(from calendarTable: [String]) -> [ViewingHistoryEntry] {
    /// Sort dates from most to least recent.
    /// parseDate handles version codes by stripping them before parsing.
    let sorted = calendarTable
        .compactMap { dateString -> (original: String, date: Date)? in
            guard let date = parseDate(from: dateString) else { return nil }
            return (dateString, date)
        }
        .sorted { $0.date > $1.date }

    let calendar = AppCalendar.current
    /// Allocated in iteration order, so a repeated entry's occurrence suffix is assigned
    /// deterministically — `map` over `enumerated()` runs strictly in sequence.
    var identities = RowIdentityAllocator()

    return sorted.enumerated().map { index, item in
        let daysSincePrior: String
        if index < sorted.count - 1 {
            let days = abs(calendar.dateComponents(
                [.day], from: sorted[index + 1].date, to: item.date).day ?? 0)
            daysSincePrior = "\(days) day" + (days == 1 ? "" : "s")
        } else {
            daysSincePrior = ""
        }
        return ViewingHistoryEntry(
            id: identities.identity(for: item.original),
            original: item.original,
            date: item.date,
            /// Formatted from the parsed Date to avoid a second parse. `formatDateString` does the
            /// same after its own parse, so the output matches.
            formattedDate: formatDate(item.date),
            daysSincePrior: daysSincePrior)
    }
}

// MARK: - Standard Viewing History Table

struct ViewingHistoryTable: View {
    @Binding var isTableExpanded: Bool
    let calendarTable: [String]

    /// The rows, derived from `calendarTable` on each evaluation. Nothing here depends on the
    /// current date, so no invalidation is needed. A cache updated from `onChange` would first
    /// show the previous film's rows, which is why this is derived instead.
    private var tableData: [CalendarRow] {
        viewingHistoryEntries(from: calendarTable).map { entry in
            CalendarRow(id: entry.id,
                        date: entry.formattedDate,
                        daysSince: entry.daysSincePrior)
        }
    }

    var body: some View {
        CustomTable(
            tableData,
            columns: [
                CustomTableColumn("Date", minWidth: 148, maxWidth: 148),
                CustomTableColumn("Since Prior", minWidth: 70, maxWidth: 70)
            ],
            isExpanded: $isTableExpanded
        ) { row in
            CustomTableCell(row.date, minWidth: 148, maxWidth: 148)
            CustomTableCell(row.daysSince, minWidth: 70, maxWidth: 70)
        }
    }
}

// MARK: - Detailed Viewing History Table

/// Expanded table that adds "Time from Today" and "Version" columns with horizontal scrolling.
/// Gated by Preferences.additionalCalTableDetails. The "Time Ago" column is measured against
/// `CurrentDay.shared.today`, so it re-renders when the calendar day changes (at midnight, on
/// wake, or on a clock or time-zone change) and at no other time.
struct ViewingHistoryDetailedTable: View {
    @Binding var isTableExpanded: Bool
    let calendarTable: [String]

    /// The rows, derived from `calendarTable` and the current day. Reading
    /// `CurrentDay.shared.today` here is what re-renders the table when the day turns; the
    /// table keeps no state and schedules nothing of its own.
    private var tableData: [DetailedCalendarRow] {
        let calendar = AppCalendar.current
        let referenceDay = CurrentDay.shared.today
        return viewingHistoryEntries(from: calendarTable).map { entry in
            DetailedCalendarRow(
                id: entry.id,
                date: entry.formattedDate,
                daysSince: entry.daysSincePrior,
                /// "Time from Today" column.
                timeFromToday: Self.formatTimeFromToday(
                    from: calendar.startOfDay(for: entry.date), to: referenceDay),
                /// "Version" column, matching ViewingDatesTableContent in 30.20 FSControlHelpers.swift.
                version: extractVersionCode(from: entry.original).displayName)
        }
    }

    /// Column widths, fixed to fit the widest readouts.
    /// "Since Prior": 72 pt, 2 pt wider than the standard table's 70 pt.
    /// "Time from Today": the widest readout, "99 years, 11 months ago", is 23 characters.
    /// "Version": matches ViewingDatesTable in 30.20 FSControlHelpers.swift.
    private let dateColWidth: CGFloat = 148
    private let sinceColWidth: CGFloat = 72
    private let timeFromTodayColWidth: CGFloat = 160
    private let versionColWidth: CGFloat = 96

    var body: some View {
        CustomTable(
            tableData,
            columns: [
                CustomTableColumn("Date", minWidth: dateColWidth, maxWidth: dateColWidth),
                CustomTableColumn("Since Prior", minWidth: sinceColWidth, maxWidth: sinceColWidth),
                CustomTableColumn("Time Ago", minWidth: timeFromTodayColWidth, maxWidth: timeFromTodayColWidth),
                CustomTableColumn("Version", minWidth: versionColWidth, maxWidth: versionColWidth)
            ],
            isExpanded: $isTableExpanded,
            allowHorizontalScroll: true
        ) { row in
            CustomTableCell(row.date, minWidth: dateColWidth, maxWidth: dateColWidth)
            CustomTableCell(row.daysSince, minWidth: sinceColWidth, maxWidth: sinceColWidth)
            CustomTableCell(row.timeFromToday, minWidth: timeFromTodayColWidth, maxWidth: timeFromTodayColWidth)
            CustomTableCell(row.version, minWidth: versionColWidth, maxWidth: versionColWidth)
        }
    }

    // MARK: - Time-from-Today Formatting

    /// How long ago `viewingDay` was, relative to `today`: under one week in days, under one
    /// calendar month in weeks, and otherwise whole months, split into years and months.
    static func formatTimeFromToday(from viewingDay: Date, to today: Date) -> String {
        let calendar = AppCalendar.current

        /// Days difference (viewing dates should always be in the past).
        let daysDiff = calendar.dateComponents([.day], from: viewingDay, to: today).day ?? 0
        guard daysDiff >= 0 else { return "" }

        if daysDiff == 0 { return "Today" }

        /// Less than 1 week → days.
        if daysDiff < 7 {
            return "\(daysDiff) \(daysDiff == 1 ? "day" : "days") ago"
        }

        /// Whole calendar months, from the components below.
        let components = calendar.dateComponents([.year, .month, .day], from: viewingDay, to: today)
        let totalMonths = (components.year ?? 0) * 12 + (components.month ?? 0)

        if totalMonths < 1 {
            /// Fewer than 1 calendar month elapsed — use weeks.
            let weeks = daysDiff / 7
            return "\(weeks) \(weeks == 1 ? "week" : "weeks") ago"
        }

        /// ≥ 1 month → decompose into years + months.
        let years = totalMonths / 12
        let months = totalMonths % 12

        if years == 0 {
            return "\(months) \(months == 1 ? "month" : "months") ago"
        } else if months == 0 {
            return "\(years) \(years == 1 ? "year" : "years") ago"
        } else {
            let yearPart = "\(years) \(years == 1 ? "year" : "years")"
            let monthPart = "\(months) \(months == 1 ? "month" : "months")"
            return "\(yearPart), \(monthPart) ago"
        }
    }
}
