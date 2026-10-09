// MARK: - CalendarTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "Details" tab, module 03.
// Calendar table displaying viewing history.

import SwiftUI

struct CalendarTable: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Binding var isTableExpanded: Bool
    @AppStorage(preference: Preferences.additionalCalTableDetailsKey) private var additionalCalTableDetails: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Title.
            RSBHelpers.moduleHeader("Viewing History")
            // Table.
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

/// Row model for the standard (compact) viewing history table.
///
/// `id` is derived from the stored calendar entry the row was built from rather
/// than freshly minted per rebuild — see `RowIdentityAllocator` below.
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

/// Assigns each row an identity derived from the calendar entry it was built from,
/// stable across rebuilds.
///
/// **Why not `UUID()`**
///
/// Both row models previously minted a fresh `UUID` per instance, so every rebuild
/// of the cached array handed `CustomTable`'s `ForEach` a set of identifiers that
/// matched nothing it was already showing. Adding one viewing date, or the detailed
/// table's midnight recalculation of its "Time Ago" column, therefore tore down and
/// recreated every row rather than updating the one or two that actually changed.
/// Deriving identity from content matches `CombinedListInfo` in ListTable.swift,
/// which documents the same correction.
///
/// The source entry — the raw `"yyyy.MM.dd"` string plus any version code — is the
/// natural key: it is what the row is a rendering of, and it survives re-sorting.
/// Duplicate entries would be a data anomaly rather than a normal state, but a
/// `ForEach` fed duplicate identifiers behaves unpredictably, so repeats are
/// disambiguated with an occurrence suffix instead of being allowed to collide.
/// The first occurrence keeps the bare entry, so the common (unique) case produces
/// exactly the source string.
private struct RowIdentityAllocator {
    private var occurrences: [String: Int] = [:]

    mutating func identity(for entry: String) -> String {
        let seen = occurrences[entry, default: 0]
        occurrences[entry] = seen + 1
        return seen == 0 ? entry : "\(entry)#\(seen)"
    }
}

// MARK: - Shared Entry Resolution

/// One viewing-history entry, resolved once for whichever of the two tables is drawing.
///
/// Both tables render the same set of viewings in the same order with the same "Since
/// Prior" gaps and the same row identities; they differ only in that the detailed table
/// adds two further columns derived from fields already carried here. Keeping the common
/// four on one model is what lets `viewingHistoryEntries(from:)` below be the single
/// definition of all of it.
/// Internal rather than private because the PDF stack is a THIRD consumer: the library
/// export's "Viewing History" section (85.30) lists the same viewings, in the same order,
/// with the same "since prior" gaps and the same version labels as the sidebar table it is
/// a paper copy of. A separate derivation there would have been a fourth copy of the rules
/// this type exists to state once.
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

/// Resolves a stored `calendarTable` into the ordered, fully-derived rows both viewing
/// history tables are built from.
///
/// This replaces two verbatim copies of the same three rules — parse-and-sort
/// descending, allocate a stable row identity, and format the gap to the next-older
/// entry — that sat in `ViewingHistoryTable.updateCachedTableData()` and
/// `ViewingHistoryDetailedTable.buildTableData(referenceDay:)`. The tables' remaining
/// builders now do nothing but map these entries onto their own row models, so the two
/// presentations are structurally incapable of disagreeing about which viewings appear,
/// in what order, or what gap is printed beside them.
///
/// The PDF export's viewing-history section calls this too — see `ViewingHistoryEntry`.
///
/// Unparseable entries are dropped, exactly as before — both copies already filtered
/// them out in their `compactMap` and neither had any way to display one.
///
/// The gap is computed from the parsed `Date`s rather than by handing the raw strings
/// back to `daysBetween(from:to:)`, which would parse both a second and third time. The
/// arithmetic is that function's own — same calendar, same single `.day` component, same
/// absolute value — applied to the very Dates it would have recovered. Its nil result
/// (the old `daysSince = ""` fallback) was unreachable here: every entry that survives
/// the `compactMap` above parsed successfully, so the re-parse inside it could not fail.
func viewingHistoryEntries(from calendarTable: [String]) -> [ViewingHistoryEntry] {
    // Sort dates from most to least recent.
    // parseDate handles version codes by stripping them before parsing.
    let sorted = calendarTable
        .compactMap { dateString -> (original: String, date: Date)? in
            guard let date = parseDate(from: dateString) else { return nil }
            return (dateString, date)
        }
        .sorted { $0.date > $1.date }

    let calendar = Calendar.current
    // Allocated in iteration order, so a repeated entry's occurrence suffix is assigned
    // deterministically — `map` over `enumerated()` runs strictly in sequence.
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
            // Formatted from the Date parsed above rather than from the stored string,
            // which would parse it a second time. Same output — `formatDateString` is this
            // call after its own parse — and the version code the stored string carries
            // was already stripped by the parse.
            formattedDate: formatDate(item.date),
            daysSincePrior: daysSincePrior)
    }
}

// MARK: - Standard Viewing History Table

struct ViewingHistoryTable: View {
    @Binding var isTableExpanded: Bool
    let calendarTable: [String]

    /// The rows, derived directly from the only input this table has.
    ///
    /// Previously an `@State` cache written from `onChange(of: calendarTable)`, which
    /// meant a new film rendered this table twice — once with the previous film's rows,
    /// then again once the handler replaced them. Deriving removes that second pass and
    /// the possibility of the two ever disagreeing. Unlike ViewingHistoryDetailedTable
    /// below, nothing here depends on the current date, so there is no invalidation to
    /// arrange: the value is a pure function of `calendarTable`.
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
/// Gated by Preferences.additionalCalTableDetails. Dates-from-today are recalculated once per
/// day at midnight (mirroring the SmartLists daily sentinel pattern) and upon first appearance.
/// @MainActor is required so the midnight-scheduling Task can capture `self` without triggering
/// a Sendable warning — SwiftUI View bodies are implicitly main-actor, but the struct type is not
/// unless explicitly annotated.
@MainActor
struct ViewingHistoryDetailedTable: View {
    @Binding var isTableExpanded: Bool
    let calendarTable: [String]

    /// The calendar day the "Time Ago" column is measured against.
    ///
    /// This is the one input to the rows that is not derivable from `calendarTable`, so
    /// it is the only piece of state this table keeps. The rows themselves are derived
    /// (see `tableData`), which is what removes the second render pass a new film used
    /// to cost — the old `@State` cache was rewritten from `onChange(of: calendarTable)`
    /// on every film transition, and the `lastCalendarTable` / `lastTodayStart` pair
    /// existed solely to decide whether that rewrite could be skipped. Deriving the rows
    /// makes both mirrors unnecessary: there is nothing to keep in step.
    @State private var referenceDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var midnightTask: Task<Void, Never>?

    /// The rows, derived from `calendarTable` and `referenceDay`.
    private var tableData: [DetailedCalendarRow] {
        let calendar = Calendar.current
        return viewingHistoryEntries(from: calendarTable).map { entry in
            DetailedCalendarRow(
                id: entry.id,
                date: entry.formattedDate,
                daysSince: entry.daysSincePrior,
                // "Time from Today" column.
                timeFromToday: Self.formatTimeFromToday(
                    from: calendar.startOfDay(for: entry.date), to: referenceDay),
                // "Version" column — mirrors ViewingDatesTableContent in FSTabDetails.
                version: extractVersionCode(from: entry.original).displayName)
        }
    }

    /// Advances `referenceDay` when, and only when, the calendar day has actually
    /// changed. The guard is what keeps this from costing a render: SwiftUI does not
    /// dedupe a `@State` write against its current value, so an unguarded assignment
    /// would invalidate the view on every call — reintroducing, on each film change,
    /// exactly the second pass this conversion removes.
    private func refreshReferenceDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if referenceDay != today { referenceDay = today }
    }

    // Column widths — fixed to accommodate widest possible readouts.
    // "Since Prior": same as standard table.
    // "Time from Today": widest possible value is "99 years, 11 months ago" (19 chars).
    // "Version": matches ViewingDatesTable in FSTabDetails.
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
        // The rows no longer need populating here — they are derived. What this still
        // covers is a stale reference day: if the app has been running across a midnight
        // and the scheduled task has not yet fired (or was delayed by sleep), the next
        // film change corrects the "Time Ago" column, exactly as the old rebuild did.
        // The write inside is guarded, so on any ordinary day this is a no-op.
        .onChange(of: calendarTable, initial: true) { _, _ in
            refreshReferenceDayIfNeeded()
        }
        .onAppear {
            scheduleDaily()
        }
        .onDisappear {
            midnightTask?.cancel()
            midnightTask = nil
        }
    }

    // MARK: - Midnight Scheduling

    /// Schedules a single task that fires at the next midnight, rebuilds against the
    /// new calendar day, then re-schedules itself for the following midnight. This mirrors the pattern
    /// used by SmartLists.scheduleRotationRefresh(). Capturing 'self' is safe here
    /// because the struct is annotated @MainActor. The task is stored in midnightTask
    /// so it can be canceled on view destruction to avoid resource leaks.
    private func scheduleDaily() {
        midnightTask?.cancel()
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return
        }
        let interval = midnight.timeIntervalSince(now)
        midnightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            refreshReferenceDayIfNeeded()
            scheduleDaily()
        }
    }

    // MARK: - Time-from-Today Formatting

    /// Computes a user-friendly string representing how long ago `viewingDay` is relative to `today`.
    /// Rounding rules:
    ///   ≥ 1 month  → rounded to nearest month (with year decomposition if applicable)
    ///   < 1 month  → expressed in weeks
    ///   < 1 week   → expressed in days
    static func formatTimeFromToday(from viewingDay: Date, to today: Date) -> String {
        let calendar = Calendar.current

        // Days difference (viewing dates should always be in the past).
        let daysDiff = calendar.dateComponents([.day], from: viewingDay, to: today).day ?? 0
        guard daysDiff >= 0 else { return "" }

        if daysDiff == 0 { return "Today" }

        // Less than 1 week → days.
        if daysDiff < 7 {
            return "\(daysDiff) \(daysDiff == 1 ? "day" : "days") ago"
        }

        // Less than ~1 month (< 30 days) → weeks.
        // We use calendar components to determine if a full month has elapsed.
        let components = calendar.dateComponents([.year, .month, .day], from: viewingDay, to: today)
        let totalMonths = (components.year ?? 0) * 12 + (components.month ?? 0)

        if totalMonths < 1 {
            // Fewer than 1 calendar month elapsed — use weeks.
            let weeks = daysDiff / 7
            return "\(weeks) \(weeks == 1 ? "week" : "weeks") ago"
        }

        // ≥ 1 month → decompose into years + months.
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
