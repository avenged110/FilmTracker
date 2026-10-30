// MARK: - GlobalUtilities.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Global utility functions for use throughout FilmTracker.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Stepper Enabled Fill

/// The background fill for every enabled Stepper chrome widget in the app: the custom
/// Stepper family in `91.00 InputUtilities.swift` (TimeStepper, DurationStepper,
/// CustomDateStepper) and `30.20 FSControlHelpers.swift` (StandardStepper,
/// HBRFValueStepper, RatingStepper). Differentiates an enabled Stepper's fill from the
/// surrounding CalendarPopover/FilmSheet/ReleaseCard background — and, when a Stepper
/// disables, from a disabled one, which reverts to `Color.clear` so the surrounding
/// background shows through unchanged.
///
/// A single `NSColor(name:dynamicProvider:)` rather than one of AppKit's own semantic
/// colors, because no built-in color combines the two halves this needs:
///   - Light mode wants a fill that reads as a shade *darker* than the surfaces around
///     it, the way `unemphasizedSelectedContentBackgroundColor` does (~0.86 white).
///     `underPageBackgroundColor`, used here previously, renders at ~0.59 white in light
///     mode regardless of appearance — visibly too dark against a light-mode card.
///   - Dark mode wants to stay close to `underPageBackgroundColor`'s own dark value
///     (~0.157 white): light enough to read as its own surface against
///     `controlBackgroundColor` (~0.118) and `windowBackgroundColor` (~0.196), but dark
///     enough that the low-alpha `tertiaryLabelColor` placeholder text every un-activated
///     Stepper shows stays legible against it.
///     `unemphasizedSelectedContentBackgroundColor`'s own dark value (~0.275) was tried
///     first and reads fine as a fill on its own, but it lightens that placeholder text
///     to the edge of legibility (contrast ratio ~1.55, down from ~2.0).
///
/// `NSColor(name:dynamicProvider:)` is what every system semantic color is itself built
/// from: the returned color carries both variants, and AppKit re-resolves it against the
/// current drawing appearance every time something asks it to render — the same pass
/// that repaints `.labelColor` or `.controlBackgroundColor` on an appearance change
/// repaints this fill too. There is no state to track and nothing to flicker: unlike a
/// value resolved once (e.g. against `NSApp.effectiveAppearance` at construction time)
/// and held in a stored property, this color is never "stale" between appearance
/// changes because it is never resolved until draw time.
///
/// Wrapped in `performAsCurrentDrawingAppearance` rather than reading
/// `.underPageBackgroundColor` / `.unemphasizedSelectedContentBackgroundColor` directly,
/// because the `appearance` the dynamicProvider closure receives is not otherwise
/// guaranteed to be the one in effect while those colors resolve themselves.
let stepperEnabledFillColor = Color(NSColor(name: nil) { appearance in
    var resolved = NSColor.underPageBackgroundColor
    appearance.performAsCurrentDrawingAppearance {
        resolved = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.underPageBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
    }
    return resolved
})

private let stepperBorderColor = Color(NSColor.quaternaryLabelColor)

extension View {
    /// The rounded chrome every Stepper widget wears — `stepperEnabledFillColor` when
    /// `filled`, clear otherwise, inside a 1 pt quaternary-label border. Three widgets in
    /// 30.20 FSControlHelpers and three in 91.00 InputUtilities each spelled these two
    /// modifiers out; this is the one definition.
    ///
    /// `filled` is the caller's: most pass a `@State` mirror of `isEnabled` rather than the
    /// live environment value, so the fill is not an animation dependency of `isEnabled`
    /// (see the note at each call site).
    func stepperChrome(filled: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: 8).fill(filled ? stepperEnabledFillColor : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stepperBorderColor, lineWidth: 1))
    }
}

// MARK: - Aspect Ratio Vocabulary
/// The aspect ratios offered anywhere in the app, in canonical (ascending) order.
///
/// The one stored vocabulary shared by BOTH model objects — `Film.aspectRatio` (a single
/// value, the ratio of the user's viewing copy) and `Release.releaseAspectRatio` (an
/// array, since one disc may carry several presentations). That is why it lives here
/// rather than in FilmObj or ReleaseObj: neither owns it, and putting it in one would
/// leave the other importing a vocabulary named for its neighbor.
///
/// The two fields are never compared against each other, so a divergence between the two
/// lists could not corrupt data — but it could silently leave a ratio selectable on a film
/// and not on its releases, and the lists were maintained as two byte-identical
/// twenty-element literals in two files with nothing tying them together.
///
/// ORDER IS LOAD-BEARING on the release side: `ReleaseOptionVocabulary` derives each tag's
/// rank from its position here and uses that rank to rebuild a stored selection in
/// canonical order. Adding a ratio means inserting it at the correct position, not
/// appending it.
enum AspectRatioVocabulary {
    /// The tags themselves. Consumed directly by the release card's multi-select control.
    static let all: [String] = [
        "1.33:1", "1.33:1 (Open matte)", "1.37:1",
        "1.37:1 (Open matte)", "1.60:1", "1.67:1", "1.78:1", "1.78:1 (Open matte)",
        "1.85:1", "1.85:1 (Open matte)", "2.00:1", "2.21:1", "2.25:1", "2.29:1", "2.35:1",
        "2.39:1", "2.55:1", "2.76:1", "2.89:1", "Hybrid",
    ]

    /// The single-select form used by the FilmSheet's Metadata tab, whose leading "" is
    /// the unset row. The release card needs no such entry: its control is multi-select,
    /// where "none selected" is the empty array rather than a tag.
    static let pickerOptions: [String] = [""] + all

    /// The qualifier a tag carries when the transfer is open-matte — "1.85:1 (Open matte)".
    /// Named once so the two PDF sections that treat an open-matte ratio specially match
    /// the vocabulary's own spelling rather than restating it.
    static let openMatteQualifier = "(Open matte)"
}

// MARK: - Viewing Version Enum
/// Represents the version/cut of a film that was viewed on a particular date.
/// Stored as a two-character code appended to viewing dates (e.g., "2026.01.24.TH").
/// When no version is specified, the date is stored without a code (e.g., "2026.01.24").
enum ViewingVersion: String, CaseIterable, Hashable {
    case none = ""          // No value / not specified (empty string)
    case theatrical = "TH"  // Theatrical
    case extended = "EX"    // Extended
    case directorsCut = "DC" // Director's Cut
    case specialEdition = "SE" // Special Edition
    case alternateEnding = "AE" // Alternate Ending
    case unrated = "UR"     // Unrated
    case televisionEdit = "TV" // Television Cut
    case workprint = "WP"   // Workprint
    case international = "IN" // International Cut
    case finalCut = "FC"    // "The Final Cut" (with quotes in display)
    case customEdit = "CE"  // Custom Edit
    case colorized = "CO"   // Colorized
    case blackAndWhite = "BW" // Black-and-white
    case other = "OT"       // Other
    
    /// User-facing display name for the version.
    /// Returns empty string for .none; Pickers should handle displaying "Select…" themselves.
    var displayName: String {
        switch self {
        case .none: return ""
        case .theatrical: return "Theatrical"
        case .extended: return "Extended"
        case .directorsCut: return "Director's Cut"
        case .specialEdition: return "Special Edition"
        case .alternateEnding: return "Alternate Ending"
        case .unrated: return "Unrated"
        case .televisionEdit: return "Television Cut"
        case .workprint: return "Workprint"
        case .international: return "International Cut"
        case .finalCut: return "\"The Final Cut\""
        case .customEdit: return "Custom Edit"
        case .colorized: return "Colorized"
        case .blackAndWhite: return "Black-and-white"
        case .other: return "Other"
        }
    }

    /// Every real version, in menu order — `allCases` without the `.none` placeholder.
    ///
    /// The single enumeration behind every version menu in the app. The release card's
    /// "Included Versions" control used to carry its own hand-written list of the same
    /// options, and the two had already drifted: that list offered "Television Edit" and
    /// "Colorized", which this enum did not, so the same logical choice was offerable on a
    /// release and unrepresentable on the film. Both menus now enumerate this, and a case
    /// added here appears in both by construction. See ReleaseOptionVocabulary.
    static let selectable: [ViewingVersion] = allCases.filter { $0 != .none }

    /// The display names of `selectable`, in the same order — what the release card's
    /// multi-select vocabulary stores and canonicalizes by.
    static let selectableNames: [String] = selectable.map(\.displayName)
}

// MARK: - Current Year
//
// The single, cheap source for "what year is it", behind a short-lived cache.
//
// MARK: Why a cache at all
//
// `Calendar.current.component(.year, from: Date())` is not a field read — it resolves the
// user's current calendar and performs a full date decomposition, and it was being spelled
// out independently by two types (FSTabReleases and CustomDateStepper) whose accessors are
// read on genuinely hot paths: the release card's purchase-year range is read per row
// evaluation and again inside every ordering-rule enforcement pass, and CustomDateStepper's
// `@State private var year` default expression is evaluated on EVERY construction of that
// view — SwiftUI re-runs a View's init on each parent body pass, and Swift evaluates a
// stored property's default expression even in an initializer that immediately overwrites
// it (verified, and true at -O). Three CustomDateSteppers are constructed per release card.
//
// MARK: Why a time window rather than a launch-time constant
//
// Both original accessors were deliberately computed rather than stored, with the same
// stated reason: an app session left running across midnight on December 31 must not keep
// reporting last year. That requirement is preserved — the value is simply allowed to be
// at most `maxAge` old, so the boundary is crossed within a minute of the actual rollover
// instead of instantly. Nothing in this app distinguishes those two, and every consumer
// (year ranges, new-release defaults) is a bound or a seed, not a timestamp.
//
// A negative age is treated as stale, so a clock moved backwards re-derives rather than
// serving a value from a future that no longer applies.
@MainActor
enum CurrentYear {
    /// How long a derived year may be reused before it is re-derived.
    private static let maxAge: TimeInterval = 60

    private static var cached: (year: Int, derivedAt: Date)?

    static var value: Int {
        let now = Date()
        if let cached {
            let age = now.timeIntervalSince(cached.derivedAt)
            if age >= 0 && age < maxAge { return cached.year }
        }
        // The pinned Gregorian calendar, not Calendar.current: every consumer bounds or seeds
        // a stored Gregorian year (see CustomDateStepper.calendar).
        let year = StorageDateFormatters.calendar.component(.year, from: now)
        cached = (year, now)
        return year
    }
}

// MARK: - Current Day
//
// The current calendar day as an observable value, for content that has to change when the
// day does — the release card's "Upcoming" badge and Unreleased availability, the sidebar's
// "Released on" / "Releases on" wording, and the new-release notification schedule.
//
// A view reading `today` re-renders on the day change and at no other time, so content that
// depends on the date stays current in a session left running for days without anything
// polling the clock. The value is the start of the day in the pinned Gregorian calendar the
// stored dates are written in (StorageDateFormatters.calendar).
//
// MARK: Why four signals
//
// `NSCalendarDayChanged` is the system's own day-change notice, and is also posted when the
// clock or time zone moves the day. The midnight task is the same check on this app's own
// timer, as SmartLists keeps one, in case a notice is missed. A Mac asleep at midnight wakes
// with the timer already overdue and the notice possibly not yet posted, so a wake re-checks
// too. Every signal runs the same idempotent `refresh()`, which publishes only an actual
// change, so a duplicate costs one date comparison.
@MainActor
@Observable
final class CurrentDay {
    static let shared = CurrentDay()

    /// The start of today. Changes only when the calendar day does.
    private(set) var today: Date

    /// Fires with the new `today` after each change, for non-view observers.
    @ObservationIgnored let dayChanged = PassthroughSubject<Date, Never>()

    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        today = Self.startOfToday()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CurrentDay.shared.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CurrentDay.shared.refresh() }
        })
        scheduleMidnightRefresh()
    }

    private static func startOfToday() -> Date {
        StorageDateFormatters.calendar.startOfDay(for: Date())
    }

    /// Re-reads the day and publishes it if it changed. Safe to call at any time.
    func refresh() {
        let day = Self.startOfToday()
        if day != today {
            today = day
            dayChanged.send(day)
        }
        scheduleMidnightRefresh()
    }

    /// Arms one task for the next midnight (a second past it, so the day has turned when it
    /// runs), replacing any earlier one.
    private func scheduleMidnightRefresh() {
        midnightTask?.cancel()
        let cal = StorageDateFormatters.calendar
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Self.startOfToday()) else { return }
        let interval = max(1, tomorrow.timeIntervalSinceNow + 1)
        midnightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            CurrentDay.shared.refresh()
        }
    }
}

// MARK: - Date Parsing and Formatting Utilities

// Cached DateFormatter for parseDate to avoid repeated allocations.
// DateFormatter creation is expensive (~0.5ms per instantiation).
// These formatters are written only once at initialization and are read-only thereafter.
// DateFormatter is Sendable in the macOS 15 SDK and is documented as safe for concurrent
// read access, so no nonisolated(unsafe) annotation is required — parseDate(from:) is a
// nonisolated global function and may be called from any thread or actor.
/// The two date spellings the database stores, configured once.
///
/// Both formats had accumulated a copy per reader and per writer — five of `.dot`
/// (here, `ViewingDatesTable.databaseFormatter`, `FSTabReleases.releaseDateFormatter`,
/// `WatchDetails.viewingDateFormatter`, `CalendarPopover.baseDateFormatter`) and three
/// of `.dash` (here, `FSTabDetails.releaseDateFormatter`, `FSTabNotes.editDateFormatter`),
/// every one of them the same four lines. The agreement between them is load-bearing —
/// the FilmSheet writes these strings and the sidebar, calendar and gallery parse them
/// back, and the comparisons between the two sides are plain string comparisons — so it
/// was being maintained by hand, with comments at most of those sites naming their
/// siblings and instructing the reader to keep the configurations in step.
///
/// Defining them once makes that agreement hold by construction rather than by
/// convention. The sites above keep their own named constants, because the name is what
/// says which of the two spellings a given call site means; they now alias these instead
/// of re-deriving them.
///
/// Locale and time zone are pinned so both always produce Gregorian dates regardless of
/// the user's locale. Neither is mutated after initialization, and `DateFormatter` is
/// documented as safe for concurrent read access (and is `Sendable` in the macOS 15 SDK),
/// so these are shared across actors exactly as the per-site copies already were.
enum StorageDateFormatters {
    /// `"yyyy.MM.dd"` — viewing-date (`calendarTable`) and release-purchase dates.
    nonisolated static let dot: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    /// `"yyyy-MM-dd"` — the film's release date and the Notes tab's edit date.
    nonisolated static let dash: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ISO 8601 with fractional seconds (`"2026-01-24T10:30:00.000Z"`) — the film's
    /// `lastModified` and `dateAdded` timestamps.
    ///
    /// The writers of those two fields — the FilmSheet save, WatchDetails' quick-add
    /// (via DataCoordinator), and both halves of the metadata importer — each carried a
    /// private copy of this configuration, with comments instructing the reader to keep
    /// them matching. The readers (`RSBHelpers.formatFullTimestamp`, `parseDate`) accept
    /// several spellings, so a drift would not have failed loudly; it would have produced
    /// two timestamp formats in one column. One definition, as with `dot` and `dash`.
    ///
    /// A Sendable value style, "2026-09-27T12:34:56.789Z". It truncates to the
    /// millisecond where the `ISO8601DateFormatter` it replaced (2026-09-27) rounded, so a
    /// value can read 1 ms earlier than the old spelling would have; order is unaffected
    /// (DevTools/ISO8601StyleEquivalence).
    static let timestamp = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)

    /// The calendar `dot` and `dash` parse with — Gregorian (what `en_US_POSIX` selects,
    /// whatever the system calendar is) in the time zone they were pinned to — for
    /// `canonicalStoredDay`, which must land on the same instant they would. Not
    /// `Calendar.current`: a Buddhist or Japanese system calendar would read the year in
    /// its own era, and `.current` re-snapshots the time zone on every call while the
    /// formatters hold theirs from first use.
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dot.timeZone
        return calendar
    }()
}

/// The calendar for everything computed from "now" or shown to the user: always
/// Gregorian, whatever calendar the Mac is set to.
///
/// `Calendar.current` follows System Settings › Language & Region › Calendar, so under a
/// Hebrew, Islamic, Buddhist or Japanese system calendar it counts years as 5787, 1448,
/// 2569 or 8, months as Tishri or Muharram, and every "this month" or "year 2026" in the
/// app would mean something else. Where the system calendar is already Gregorian this IS
/// `Calendar.current` — the same object, so nothing changes for those users. Otherwise it
/// is a Gregorian calendar carrying everything else `Calendar.current` would have: the
/// region's locale (so month names stay in English), time zone, first weekday and
/// minimum days in the first week. A Hebrew-calendar user in the UK therefore gets what
/// a Gregorian user in the UK gets — weeks from Monday, "27 October 2026" — checked
/// 2026-10-27 under Hebrew, Islamic, Buddhist and Japanese calendars in US, UK and Czech
/// regions.
///
/// Stored dates are a separate matter, parsed with `StorageDateFormatters.calendar`
/// (Gregorian, in the time zone the formatters were created in).
nonisolated enum AppCalendar {
    static var current: Calendar {
        let system = Calendar.current
        guard system.identifier != .gregorian else { return system }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = system.locale
        calendar.timeZone = system.timeZone
        calendar.firstWeekday = system.firstWeekday
        calendar.minimumDaysInFirstWeek = system.minimumDaysInFirstWeek
        return calendar
    }

    /// Gregorian with no other settings, for format styles and formatters whose locale
    /// is pinned already — a pinned locale does not pin the calendar ("en_US" alone still
    /// printed "16 Heshvan 5787" under a Hebrew system calendar).
    static let gregorian = Calendar(identifier: .gregorian)
}

/// Local midnight of a date written exactly as `yyyy?MM?dd` — eight ASCII digits with
/// `separator` in both positions — or nil for anything else, including a day the month
/// does not have, which the non-lenient formatters this stands in for also reject.
///
/// The fast path of `parseDate(from:)`. The database stores every viewing date, last-
/// watched date, purchase date and release date in one of these two shapes, and a
/// `DateFormatter` parse costs about 40 µs each (an ICU parse of the pattern against the
/// string) — the dominant cost of the Data Visualizations recalculation, of the sort
/// keys MetadataCache derives, and of every search over a date field. Reading the digits
/// and asking the pinned Gregorian calendar for that day costs a few microseconds and
/// yields the same instant: the day's first moment in the formatters' time zone. Any
/// string that is not exactly this shape (a one-digit month, a four-digit year below
/// 1000, a version suffix not yet stripped) is declined, so the formatters still decide
/// everything they used to.
///
/// The formatters are strict about midnight itself, and this reproduces that: in a zone
/// whose DST change falls at 00:00, a day with no midnight (the clocks jump to 01:00)
/// parses as nil rather than 01:00, a day with two midnights parses as the later one,
/// and a day a zone skipped outright parses as nil. The `date-semantics` harness scenario
/// proves agreement with the formatters on every day from 1888 to 2100 and every invalid
/// day in the current time zone, and on 1985–2035 in a set of zones with exactly those
/// transitions.
func canonicalStoredDay(_ text: Substring, separator: Character,
                        calendar: Calendar = StorageDateFormatters.calendar) -> Date? {
    let u = text.utf8
    guard u.count == 10 else { return nil }
    var digits = [Int](repeating: 0, count: 8)
    var n = 0
    for (i, byte) in u.enumerated() {
        if i == 4 || i == 7 {
            guard byte == separator.asciiValue else { return nil }
        } else {
            guard byte >= 48, byte <= 57 else { return nil }
            digits[n] = Int(byte) - 48
            n += 1
        }
    }
    let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
    let month = digits[4] * 10 + digits[5]
    let day = digits[6] * 10 + digits[7]
    guard year >= 1000, (1...12).contains(month), day >= 1, day <= gregorianDaysInMonth(month, year: year) else { return nil }
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
    // The calendar resolves a missing or skipped midnight by rolling forward; the
    // formatters do not. Wall-clock seconds since the epoch — offset arithmetic, no
    // calendar computation — say whether `date` really is 00:00 of the day asked for.
    let zone = calendar.timeZone
    func wallSeconds(_ t: Date) -> Int { Int(t.timeIntervalSince1970.rounded()) + zone.secondsFromGMT(for: t) }
    let midnight = wallSeconds(date)
    guard midnight == daysSinceEpoch(year: year, month: month, day: day) * 86_400 else { return nil }
    // A repeated midnight (the clocks fall back to 00:00): the formatters take the
    // later of the two instants, the calendar the earlier. One hour is every real DST
    // step but Lord Howe Island's, which is half an hour.
    for step in [3_600.0, 1_800.0] {
        let later = date.addingTimeInterval(step)
        if wallSeconds(later) == midnight { return later }
    }
    return date
}

/// The instant a timestamp written exactly as `yyyy-MM-ddTHH:mm:ss.SSSZ` names — the
/// shape `StorageDateFormatters.timestamp` writes for `dateAdded` and `lastModified` — or
/// nil for anything else.
///
/// The second fast path of `parseDate(from:)`. Those strings decline every cheaper parser
/// in its chain and are read only by the `yyyy-MM-dd'T'HH:mm:ss.SSSZ` formatter, fifth in
/// line, after four failed ICU parses: about 140 µs each, which made the two fields most of
/// the cost of building MetadataCache (≈420 ms of a 500 ms full rebuild for 1,400 films)
/// and of every `#added` search. The string names a UTC instant, so no calendar or time
/// zone is involved: the digits are the whole answer. The value is built the way the
/// formatter builds it — whole milliseconds since 1970, divided once — so the two agree
/// bit for bit: checked 2026-10-27 against the formatter chain on every stored date
/// string of a 1,400-film library (8,344 strings, 2,799 of them timestamps; none
/// differed), at ~1 µs a timestamp against ~147 µs. A leap second, an
/// out-of-range field or any other shape is declined and goes to the formatters as before.
func canonicalStoredTimestamp(_ text: Substring) -> Date? {
    let u = Array(text.utf8)
    guard u.count == 24, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58,
          u[19] == 46, u[23] == 90 else { return nil }
    func number(_ range: Range<Int>) -> Int? {
        var value = 0
        for i in range {
            guard u[i] >= 48, u[i] <= 57 else { return nil }
            value = value * 10 + Int(u[i]) - 48
        }
        return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
          let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
          let millisecond = number(20..<23),
          year >= 1000, (1...12).contains(month), day >= 1, day <= gregorianDaysInMonth(month, year: year),
          hour < 24, minute < 60, second < 60 else { return nil }
    let seconds = daysSinceEpoch(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second
    return Date(timeIntervalSince1970: Double(seconds * 1_000 + millisecond) / 1_000)
}

/// Days from 1970-01-01 to the given proleptic-Gregorian date (negative before it).
private func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

func gregorianDaysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

private let dotDateFormatter = StorageDateFormatters.dot
private let dashDateFormatter = StorageDateFormatters.dash

// ISO8601 parse strategy for full timestamp strings (e.g., "2026-01-24T10:30:00Z").
// Date.ISO8601FormatStyle is a value type and fully Sendable — no nonisolated(unsafe)
// annotation is needed, unlike the legacy ISO8601DateFormatter class it replaces.
private let iso8601ParseStrategy = Date.ISO8601FormatStyle()

// Additional timestamp formatters for non-standard timestamp strings.
// Covers formats that Date.ISO8601FormatStyle doesn't handle (e.g., missing 'Z' timezone).
private let timestampDateFormatters: [DateFormatter] = {
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "MM/dd/yyyy",
        "M/d/yyyy"
    ]
    return formats.map { format in
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }
}()

// Output format style for date display (e.g., "November 4, 2025").
// Date.FormatStyle is a value type, fully Sendable, and backed by the same ICU
// infrastructure as DateFormatter — but without the bridging overhead or
// thread-safety constraints that required nonisolated(unsafe) on the old formatter.
// Locale is pinned to en_US to guarantee consistent English output regardless of
// the system language setting, matching the behavior of the previous DateFormatter, and
// the calendar to Gregorian, which the locale alone does not do (see AppCalendar).
private let displayDateStyle = Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: AppCalendar.gregorian)
    .month(.wide)
    .day(.defaultDigits)
    .year(.defaultDigits)

// Output format style for month+year display (e.g., "November 2026"), used by monthYearLabel(for:).
// Same Sendability and performance advantages as displayDateStyle above.
private let monthYearStyle = Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: AppCalendar.gregorian)
    .month(.wide)
    .year(.defaultDigits)

/// Strips trailing dot characters from a date string.
/// Handles malformed dates like "2026.01.24." that carry a spurious trailing dot.
/// This logic is shared by `extractDatePortion(from:)` and `extractVersionCode(from:)`.
/// Uses a backward index walk — one allocation rather than two reversed copies.
private func stripTrailingDots(_ string: String) -> String {
    guard string.hasSuffix(".") else { return string }
    var end = string.endIndex
    while end > string.startIndex {
        let prev = string.index(before: end)
        if string[prev] == "." {
            end = prev
        } else {
            break
        }
    }
    // If every character was a dot, end == startIndex; return empty string.
    return String(string[..<end])
}

/// Extracts the date portion from a date string that may contain a version code.
/// Handles both "YYYY.MM.DD" and "YYYY.MM.DD.XX" formats.
/// Also handles malformed dates with trailing dots (e.g., "2026.01.24.").
/// - Parameter dateString: The full date string (e.g., "2026.01.24" or "2026.01.24.TH").
/// - Returns: The date portion only (e.g., "2026.01.24").
func extractDatePortion(from dateString: String?) -> String? {
    guard let dateString = dateString else { return nil }
    let cleaned = stripTrailingDots(dateString)
    let components = cleaned.split(separator: ".")
    // If we have exactly 4 components and the last one is 2 characters (version code),
    // return the first 3 components joined.
    if components.count == 4 && components[3].count == 2 {
        return components[0...2].joined(separator: ".")
    }
    // Otherwise return as-is (already just a date or invalid format).
    return cleaned
}

/// Extracts the version code from a date string that may contain one.
/// Also handles malformed dates with trailing dots (e.g., "2026.01.24.").
/// - Parameter dateString: The full date string (e.g., "2026.01.24.TH").
/// - Returns: The ViewingVersion enum value, or .none if no valid code is present.
func extractVersionCode(from dateString: String?) -> ViewingVersion {
    guard let dateString = dateString else { return .none }
    let cleaned = stripTrailingDots(dateString)
    let components = cleaned.split(separator: ".")
    // If we have exactly 4 components and the last one is 2 characters, parse the code.
    if components.count == 4 && components[3].count == 2 {
        return ViewingVersion(rawValue: String(components[3]).uppercased()) ?? .none
    }
    return .none
}

/// Parses a date string and returns a Date object.
/// This is the canonical date parser for the entire application.
///
/// Handles all supported formats robustly:
/// - "YYYY.MM.DD" (primary/dot format)
/// - "YYYY.MM.DD.XX" (dot format with version code, e.g., ".TH")
/// - "YYYY-MM-DD" (dash format for compatibility)
/// - ISO8601 timestamps (e.g., "2026-01-24T10:30:00Z")
/// - Additional timestamp variants (with/without timezone)
/// - "MM/dd/yyyy" and "M/d/yyyy" (slash formats)
/// - Strings with trailing dots or other minor malformations
///
/// - Parameter dateString: A date string in any supported format.
/// - Returns: Date object if parsing succeeds, 'nil' otherwise.
func parseDate(from dateString: String?) -> Date? {
    guard let dateString = dateString, !dateString.isEmpty else { return nil }
    
    // Extract just the date portion (strips version codes and trailing dots)
    let datePortion = extractDatePortion(from: dateString) ?? dateString

    // The stored shapes, read directly (see canonicalStoredDay, canonicalStoredTimestamp). Anything declined
    // here goes through the formatters below exactly as it always did.
    if let date = canonicalStoredDay(datePortion[...], separator: ".")
        ?? canonicalStoredDay(datePortion[...], separator: "-")
        ?? canonicalStoredTimestamp(datePortion[...]) {
        return date
    }
    return parseDateWithFormatters(datePortion: datePortion, dateString: dateString)
}

/// The formatter chain `parseDate(from:)` ran before `canonicalStoredDay` was put in
/// front of it, and still runs for every string the fast path declines. Internal (not
/// private) so the `date-semantics` harness scenario can hold the fast path to it.
func parseDateWithFormatters(datePortion: String, dateString: String) -> Date? {
    // Try "yyyy.MM.dd" format first (primary format)
    if let date = dotDateFormatter.date(from: datePortion) {
        return date
    }
    
    // Try "yyyy-MM-dd" format for compatibility
    if let date = dashDateFormatter.date(from: datePortion) {
        return date
    }
    
    // Try ISO8601 for full timestamp strings (e.g., "2026-01-24T10:30:00Z")
    if let date = try? iso8601ParseStrategy.parse(dateString) {
        return date
    }
    
    // Try additional timestamp and date formats
    for formatter in timestampDateFormatters {
        if let date = formatter.date(from: dateString) {
            return date
        }
    }
    
    return nil
}

/// Formats a date string from "YYYY.MM.DD" (or "YYYY.MM.DD.XX") to "Month Day, Year" format.
/// Version codes are stripped before formatting.
/// - Parameter dateString: String in format "YYYY.MM.DD" or "YYYY.MM.DD.XX".
/// - Returns: Formatted string like "November 4, 2025".
func formatDateString(_ dateString: String?) -> String {
    guard let date = parseDate(from: dateString) else { return "Unknown date" }
    return formatDate(date)
}

/// Formats an ALREADY-PARSED date the way `formatDateString` formats a stored string —
/// "November 4, 2025" — for a caller that has the `Date` in hand.
///
/// `formatDateString` parses and then formats, which is right when a stored string is all
/// the caller has. A caller that parsed the string a moment ago — to sort by it, say —
/// would otherwise pay for a second parse it has no use for, and the viewing-history rows
/// did exactly that for every entry of every film in the library: parse to sort, then parse
/// again to print. At ten thousand entries, that second parse was most of the cost of
/// building the section.
func formatDate(_ date: Date) -> String {
    displayDateStyle.format(date)
}

/// Calculates the time elapsed from a date string to now, formatted
/// with granular recent time labels or "x year/s x month/s ago" for longer periods.
/// Handles version codes by stripping them before parsing.
/// - Parameter dateString: String in format "YYYY.MM.DD" or "YYYY.MM.DD.XX".
/// - Returns: Human-readable time difference (e.g., "Today", "Yesterday", "Last week",
///            "2 weeks ago", "3 weeks ago", "Less than a month ago", "3 months ago", "1 year 1 month ago").
func timeAgo(from dateString: String?) -> String {
    guard let date = parseDate(from: dateString) else { return "Unknown" }

    let calendar = AppCalendar.current
    let now = Date()
    
    // Calculate day difference first for recent dates
    let dayComponents = calendar.dateComponents([.day], from: date, to: now)
    guard let dayDiff = dayComponents.day else { return "Unknown" }
    
    // Guard against future dates — dayDiff is negative when date is ahead of now
    if dayDiff < 0 { return "In the future" }
    
    // Handle granular recent cases
    switch dayDiff {
    case 0:
        return "Today"
    case 1:
        return "Yesterday"
    case 2..<7:
        return "Less than a week ago"
    case 7..<14:
        return "Last week"
    case 14..<21:
        return "2 weeks ago"
    case 21..<30:
        return "3 weeks ago"
    default:
        break
    }
    
    // For dates 30+ days ago, use month/year formatting
    let components = calendar.dateComponents([.year, .month], from: date, to: now)
    guard let years = components.year, let months = components.month else {
        return "Unknown"
    }

    var parts: [String] = []
    if years > 0 { parts.append("\(years) year" + (years == 1 ? "" : "s")) }
    if months > 0 { parts.append("\(months) month" + (months == 1 ? "" : "s")) }
    if parts.isEmpty { return "Less than a month ago" }

    return parts.joined(separator: " ") + " ago"
}

/// Combines formatted date with time ago in parentheses.
/// Only appends timeAgo if the date is valid (not "Unknown date").
/// Handles version codes by stripping them before formatting.
/// - Parameter dateString: String in format "YYYY.MM.DD" or "YYYY.MM.DD.XX".
/// - Returns: Combined string like "November 04, 2025 (3 months ago)" or just "Unknown date".
func formatDateWithTimeAgo(_ dateString: String?) -> String {
    let formattedDate = formatDateString(dateString)
    
    // Only append timeAgo if we have a valid date
    if formattedDate != "Unknown date" {
        let timeAgoText = timeAgo(from: dateString)
        return "\(formattedDate) (\(timeAgoText))"
    }
    
    return formattedDate
}

// MARK: - Rotation Eligibility Dates
//
// Rotation is a MONTH-GRANULAR concept in this app: the user reads it as "this
// film comes up in September 2026," never "on September 6th." `rotationEligibilityDate`
// below is the single definition of that idea, and every rotation-derived value in
// the app is computed from its result — the "Next Up for Rotation" label in
// `WatchDetails`, that field's countdown and "Ready for viewing" switch, all four
// of `SmartLists`' rotation/one-year checkers, and the cached rotation date behind
// `MetadataCache`'s "Recently Come Up for Rotation" list and its subtitles.
//
// Routing all of them through one function is the whole point, not a style
// preference: the predecessor rounded the *label* up to the following month while
// every other consumer measured against the raw anniversary, producing
// "September 2026 (0 days away)" on August 5th — two different rules applied to
// one value. Splitting the rule again would reintroduce that bug spread across
// views instead of contained in one string: a film could sit in the "Up for
// Rotation" smart list and be auto-enqueued into Up Next while the sidebar
// simultaneously insisted it was three weeks away.

/// The date on which a film becomes up for rotation: its viewing anniversary,
/// rounded up to midnight on the 1st of the following month.
///
/// The raw anniversary is `lastWatchedDate` plus `months`. `Calendar` clamps an
/// overflowing day to the target month's last day (e.g. Aug 31 + 6 months →
/// Feb 28/29), which is the correct behavior here; the round-up then moves the
/// result to the 1st regardless, so the clamping is invisible downstream.
///
/// Why round at all: the user-facing field names a month, and a film whose
/// anniversary falls mid-month would otherwise be described as coming up in a
/// month it is only eligible for part of. Rounding up makes the named month one
/// the film is available for in full, and makes the label, the countdown, the
/// smart lists, and the auto-enqueue all name the same instant.
///
/// The result is always midnight on a month boundary, which is what makes it
/// usable unchanged both as a `<=` eligibility comparison operand and as the
/// input to `monthYearLabel(for:)`.
///
/// - Parameters:
///   - lastWatchedDate: The parsed `lastWatched` date.
///   - months: The film's effective rotation threshold, in months.
///   - calendar: The calendar to compute against. Defaults to `.current`.
/// - Returns: Midnight on the 1st of the eligibility month, or `nil` if the
///   calendar arithmetic fails (which in practice it does not).
func rotationEligibilityDate(from lastWatchedDate: Date, months: Int, calendar: Calendar = AppCalendar.current) -> Date? {
    guard let anniversary = calendar.date(
        byAdding: .month, value: months, to: lastWatchedDate
    ) else { return nil }

    // Normalized to a day boundary first, so that an anniversary carrying a time
    // component on the 1st (e.g. 2026-09-01 14:00) is recognized as already being
    // on the boundary rather than being pushed a full month forward. Parsed
    // `lastWatched` dates are already midnight, but this function does not
    // require its caller to guarantee that.
    let dayStart = calendar.startOfDay(for: anniversary)

    guard let monthStart = calendar.dateInterval(of: .month, for: dayStart)?.start else {
        return nil
    }

    // The anniversary IS the 1st — the film's whole eligibility month is still
    // ahead of it, so there is nothing to round up to. Advancing here would cost
    // the user an entire month for the one calendar day per month that happens to
    // land exactly on the boundary.
    if monthStart == dayStart { return dayStart }

    return calendar.date(byAdding: .month, value: 1, to: monthStart)
}

/// Formats a date as "Month Year" (e.g. "November 2026") for rotation display.
///
/// Deliberately takes a `Date` rather than a date string: its callers have
/// already obtained the exact instant they intend to name from
/// `rotationEligibilityDate`, and re-deriving that instant from a string inside
/// the formatter is what previously allowed the label and the value it labeled
/// to be computed by two different rules.
///
/// - Parameter date: The date whose month should be named.
/// - Returns: Formatted string in the form of "November 2026".
func monthYearLabel(for date: Date) -> String {
    monthYearStyle.format(date)
}

/// Calculates the time distance from now to a future date, formatted with smart
/// granularity: "x year/s away", "x year/s y month/s away", "x month/s away",
/// "x week/s away" (for < 1 month), or "x day/s away" (for < 1 week).
///
/// Measurement basis: both endpoints are snapped to the start of their calendar
/// day first, so every tier is computed from an exact whole-day span. See the
/// note in the body for why — in short, `Calendar.dateComponents` truncates
/// toward zero, and against a midnight target that silently discarded the
/// remainder of the current day from every tier.
///
/// Rounding policy: round-half-up toward the nearest whole unit so the label
/// lands "closer to the middle" rather than at either extreme.
///
///   • Days (< 7)   — always exact; no rounding applied.
///   • Weeks (7–27) — split at the half-week (3.5 days, ceiling → 4).
///       Formula: `(dayDiff + 3) / 7`
///       e.g.  7 days = 1 wk,  10 days = 1 wk,  11 days = 2 wks,  25 days = 4 wks.
///   • Months (≥ 28) — uses `Calendar`'s real (variable-length) year/month
///       decomposition rather than a fixed 28-day approximation, matching the
///       methodology already used for "ago" calculations elsewhere in this file.
///       A fixed 28-day month is ~2.4 days shorter than a real calendar month
///       on average, and that shortfall compounds over multi-month/-year spans
///       — e.g. it could turn a ~2-year, few-week distance into a reported
///       "2 years 2 months away". Using Calendar's actual components eliminates
///       that drift. The trailing day remainder is still rounded half-up, but
///       against the true length of the specific partial month in question
///       (28, 29, 30, or 31 days) instead of a flat 28.
///
/// - Parameter futureDate: The target date in the future.
/// - Returns: Human-readable time distance (e.g., "1 year 11 months away", "3 months away", "2 weeks away").
func timeDistanceFromNow(to futureDate: Date) -> String {
    let calendar = AppCalendar.current

    // Both endpoints are normalized to the start of their calendar day before
    // anything is measured, and every tier below is computed from these two
    // values rather than from the raw `Date()`.
    //
    // This is the second half of the "September 2026 (0 days away)" fix. The
    // target is a parsed date, i.e. always midnight; "now" is whatever time of
    // day it happens to be. `Calendar.dateComponents` truncates toward zero, so
    // from 2026-08-05 at 2:00 PM to 2026-08-06 at midnight it returned 0 whole
    // days — the calculation reported "0 days away" for a date a full calendar
    // day in the future, and did so for the entire final day of every waiting
    // period regardless of threshold. The same truncation shaved up to a day off
    // the week and month tiers too, since both are measured from the same
    // endpoints; it simply went unnoticed there because a day is below their
    // display granularity.
    //
    // Comparing whole days is also the right unit for this field on its own
    // terms: the value it describes is a calendar date with no time component,
    // and the user reads it as "how many more days until this comes up".
    let now = calendar.startOfDay(for: Date())
    let target = calendar.startOfDay(for: futureDate)

    // Compute the total elapsed days from today to the future date. With both
    // endpoints on day boundaries this is now an exact whole-day count rather
    // than a floor of a partial-day span.
    let dayComponents = calendar.dateComponents([.day], from: now, to: target)
    guard let dayDiff = dayComponents.day else { return "Unknown" }

    // Guard against non-future dates. Reached only if a caller passes today or
    // earlier; `WatchDetails` never does, because a rotation date at or before
    // the current moment is answered with "Ready for viewing" before this
    // function is consulted. "Today" rather than "0 days away" so that, if some
    // future caller does land here, it reads as a statement of fact instead of
    // as the arithmetic failure the old wording was mistaken for.
    if dayDiff <= 0 { return "Today" }

    // ── Tier 1: Days (< 7) — exact, no rounding. ─────────────────────────────
    if dayDiff < 7 {
        return "\(dayDiff) day" + (dayDiff == 1 ? "" : "s") + " away"
    }

    // ── Tier 2: Weeks (7–27) — round-half-up at 3.5 days (ceiling → 4). ─────
    // (dayDiff + 3) / 7 is standard round-half-up integer division for unit 7.
    // The branch ends at 27 (< 28) so the maximum output is 4 weeks, which is
    // exactly one calendar month and cleanly abuts the months tier.
    if dayDiff < 28 {
        let weeks = (dayDiff + 3) / 7
        return "\(weeks) week" + (weeks == 1 ? "" : "s") + " away"
    }

    // ── Tier 3: Months (≥ 28) — real calendar year/month decomposition, ─────
    // rounded half-up against the true length of the trailing partial month.
    // Measured between the same two day-normalized endpoints as the tiers above,
    // so a single set of values drives all three and they cannot disagree about
    // where a tier boundary falls.
    let monthComponents = calendar.dateComponents([.year, .month, .day], from: now, to: target)
    guard var years = monthComponents.year,
          var months = monthComponents.month,
          let trailingDays = monthComponents.day else { return "Unknown" }

    // Anchor the start of the trailing partial month (i.e. "now" advanced by
    // the whole years/months already counted) so the remainder is measured
    // against that specific month's real length, not an assumed constant.
    if let partialMonthStart = calendar.date(
        byAdding: DateComponents(year: years, month: months), to: now),
       let daysInPartialMonth = calendar.range(of: .day, in: .month, for: partialMonthStart)?.count,
       trailingDays >= (daysInPartialMonth + 1) / 2 {
        months += 1
        if months == 12 {
            months = 0
            years += 1
        }
    }

    var parts: [String] = []
    if years  > 0 { parts.append("\(years) year"  + (years  == 1 ? "" : "s")) }
    if months > 0 { parts.append("\(months) month" + (months == 1 ? "" : "s")) }

    // dayDiff >= 28 should always yield at least one whole month once rounded;
    // this fallback only guards a theoretical Calendar edge case.
    if parts.isEmpty { return "1 month away" }

    return parts.joined(separator: " ") + " away"
}

// MARK: - "Add to List" Placeholder

/// The disabled placeholder row shown by every "Add to List" menu — the MenuBar's
/// "Film ▸ Add to List" (AddToListMenuItems), the GalleryTitleBar's SelectionMenuButton,
/// and the gallery contextual menu (GalleryContextMenu.makeAddToListSubmenu) — whenever
/// that menu has no list left to offer.
///
/// The two ways of having nothing to offer are genuinely different and must not share a
/// single string. With lists in the library and one film selected, an empty menu means
/// the film is already a member of every one of them. With no lists in the library at
/// all, it means there is nothing to add anything to yet — reporting that as "Already a
/// Member of All Lists" is simply false, and it was previously shown in exactly that
/// case by all three menus. "No Lists Available" matches the wording ListsMenu already
/// uses for the same empty-library state.
func addToListPlaceholderTitle(hasAnyLists: Bool) -> String {
    hasAnyLists ? "Already a Member of All Lists" : "No Lists Available"
}

// MARK: - List Name Truncation
// Maximum length for list names displayed in menus.
private let menuTitleMaxLength = 62
// Returns a version of the string truncated to 'maxLength' characters,
// appending an ellipsis if truncation was necessary. Ensures the ellipsis
// never follows a space character and trailing spaces are skipped.
// - Parameters:
//   - listName: The list name to truncate.
//   - maxLength: The maximum allowed length (default: 62 characters).
// - Returns: The truncated string with an ellipsis if necessary, or the
//            original string if it fits.
func truncateListName(_ listName: String, maxLength: Int = menuTitleMaxLength) -> String {
    // Only truncate when the *original* string exceeds the maximum length.
    guard listName.count > maxLength else { return listName }

    let maxChars = max(1, maxLength - 1) // leave room for the ellipsis

    // Initial cut point
    var endIndex = listName.index(listName.startIndex, offsetBy: maxChars)

    // Walk backwards skipping spaces so we never end with " …"
    while endIndex > listName.startIndex {
        let prevIndex = listName.index(before: endIndex)
        let char = listName[prevIndex]
        
        if char == " " { endIndex = prevIndex
        } else { break } }

    // If this was somehow walked all the way back (e.g. all spaces),
    // fall back to the naive cut at maxChars.
    if endIndex <= listName.startIndex {
        endIndex = listName.index(listName.startIndex, offsetBy: maxChars) }

    return String(listName[..<endIndex]) + "…"
}

/// The one place that knows where Apple's private SF Symbols live (CoreGlyphsPrivate).
/// Access only — callers that need a size, weight or tint apply it themselves.
struct PrivateSymbol {
    /// Resolved once; nil on a system where the path has moved, which makes every lookup
    /// below fail cleanly rather than crash.
    nonisolated private static let bundle: Bundle? = Bundle(
        path: "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle")

    /// The private symbol as a template NSImage, or nil when it does not resolve.
    nonisolated static func nsImage(named name: String) -> NSImage? {
        guard let bundle,
              let image = NSImage(symbolName: name, bundle: bundle, variableValue: 0)
        else { return nil }
        image.isTemplate = true
        return image
    }

    /// Whether the private symbol resolves on this system.
    nonisolated static func exists(_ name: String) -> Bool {
        nsImage(named: name) != nil
    }

    /// The private symbol as an Image, or `questionmark.square.dashed` when it does not
    /// resolve, so a missing symbol is visibly missing rather than silently blank.
    static func image(named name: String) -> Image {
        guard let image = nsImage(named: name) else {
            return Image(systemName: "questionmark.square.dashed") }
        return Image(nsImage: image) }
}

// MARK: - Subcategory Picker

/// The shared shape of every sub-tab control in the app's title bars: a label-hidden
/// Picker over a fixed list of options, reporting one current value and handing a new one
/// back. Each concrete picker differs only in its option list, its style, and which shared
/// state object it reads and writes, so each is a thin wrapper supplying those.
///
/// Six wrappers use this today — the Recents, Unwatched, Film Queue and smart-list variant
/// pickers in GalleryTitleBar, plus the Reports and Imports tab pickers, which were
/// hand-written copies of this same shape before it moved here from GalleryTitleBar's
/// private scope.
///
/// Each wrapper keeps its own reference to its state object rather than letting the title
/// bar read the value and pass it down: the read then registers against the wrapper's
/// body, so changing a sub-tab re-renders that one picker rather than the whole title bar.
struct SubcategoryPicker<Value: Hashable & Sendable, Style: PickerStyle>: View {
    /// Accessibility label. Hidden visually by `labelsHidden`, but still read by
    /// VoiceOver, so every picker supplies a real one.
    let label: String
    let style: Style
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    /// `@MainActor` rather than a bare closure so it satisfies the `@Sendable` setter
    /// `Binding.init(get:set:)` requires: every caller's closure reaches into a
    /// main-actor-isolated state object, which is not Sendable on its own.
    let onSelect: @MainActor (Value) -> Void

    /// Menu-style pickers are an AppKit `NSPopUpButton` (`SheetPopUpButton`, 30.20), not
    /// SwiftUI's `Picker(.menu)`, because of WHEN each reports a choice.
    ///
    /// On selection a menu blinks the item, then fades its window out (≈180 ms of window-alpha
    /// steps driven by the menu's own tracking loop on the main thread). A plain NSPopUpButton
    /// sends its action only after that fade has finished and tracking has ended. SwiftUI's
    /// Picker instead calls its binding setter from INSIDE the tracking loop, ≈40 ms into the
    /// fade — so everything a sub-tab change triggers synchronously (the state write, the
    /// SwiftUI update pass it schedules, and any run-loop-deferred content swap) competes with
    /// the remaining fade frames, which is the "menu closes in three frames" stutter on the
    /// Reports tabs. Measured with a standalone probe sampling the menu window's alpha from the
    /// window server on a background thread: a 400 ms load in the Picker's setter froze the
    /// fade at alpha 0.38; the same load in an NSPopUpButton action left every frame intact.
    ///
    /// Because the action arrives after the fade, the menu-style wrappers ask their state
    /// objects to switch immediately (`immediate: true`) rather than two run-loop turns later.
    var body: some View {
        if style is MenuPickerStyle && !Self.forcesSwiftUIMenuPicker {
            SheetPopUpButton(
                selection: Binding(get: { selection }, set: onSelect),
                items: options.map { .option(tag: $0, title: title($0)) },
                reassertsSelectionAfterWrite: false)
            .frame(height: SheetPopUpButton<Value>.layoutHeight)
            .accessibilityLabel(label)
        } else {
            swiftUIPicker
        }
    }

    /// The `picker-dismissal` harness scenario's A/B switch (99.50): true restores the SwiftUI
    /// Picker for menu styles so the same run can measure the old control beside the new one.
    private static var forcesSwiftUIMenuPicker: Bool {
        #if DEBUG
        debugForcesSwiftUISubcategoryMenuPicker
        #else
        false
        #endif
    }

    private var swiftUIPicker: some View {
        Picker(label, selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(style)
        .labelsHidden()
    }
}

#if DEBUG
/// See `SubcategoryPicker.forcesSwiftUIMenuPicker`. Written only by the harness.
@MainActor var debugForcesSwiftUISubcategoryMenuPicker = false
#endif

// MARK: - Extensible GenericTitleBar Utility
struct GenericTitleBar<LeadingContent: View, TrailingButtons: View>: View {
    let glyph: String
    let leadingContent: LeadingContent
    let trailingButtons: TrailingButtons
    // Creates a generic title bar with custom glyph and button configuration.
    // - Parameters:
    //   - glyph: SF Symbol name for the left-aligned icon
    //   - leadingContent: Optional content to display after the glyph (e.g., category picker)
    //   - trailingButtons: Right-aligned button section
    init(
        glyph: String,
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingButtons: () -> TrailingButtons) {
        self.glyph = glyph
        self.leadingContent = leadingContent()
        self.trailingButtons = trailingButtons() }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left-aligned glyph.
                Image(systemName: glyph)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                    .padding(.leading, 18)
                // Optional leading content (e.g., Picker menu).
                leadingContent
                Spacer()
                // Right-aligned button section.
                trailingButtons }
            .padding(.vertical, 1)
            .frame(minHeight: 30, maxHeight: 30)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom) }
        // Disable animations on the entire VStack to prevent window chrome
        // from animating when sidebar opens/closes.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true } }
}

// MARK: - HelpPopoverButton
/// A macOS-standard "?" Help button that, when clicked, displays a popover anchored
/// to its trailing edge containing the provided help text. The popover auto-dismisses
/// after `autoDismissDuration` seconds (default: 10) if the user takes no action;
/// manual dismissal cancels the timer.
///
/// Usage:
///     HelpPopoverButton(helpText: "This list contains films which…")
///     HelpPopoverButton(helpText: "Long explanation…", autoDismissDuration: 60)
///     HelpPopoverButton(helpText: "…", dismissToken: AnyHashable(someIndex))
///
/// The button renders at a fixed 22×22 pt frame to match the intrinsic size of
/// NSButton with `.helpButton` bezel style and should be placed inline with other
/// toolbar controls. Callers are responsible for showing or hiding the button
/// entirely via conditional logic in their own view if context-sensitivity is required.
///
/// `dismissToken`: an optional opaque identity value supplied by the caller. When the
/// token changes (as detected by `.onChange`), any open popover is immediately dismissed.
/// This allows context-sensitive dismissal — e.g., closing the popover when the user
/// navigates to a different card in a carousel — without requiring the caller to manage
/// the `isShowingPopover` state directly. Defaults to `nil`; existing call sites that
/// omit this parameter are wholly unaffected.
@MainActor
struct HelpPopoverButton: View {
    /// The text to display inside the popover.
    let helpText: String
    /// How many seconds before the popover auto-dismisses. Defaults to 10.
    /// Pass a larger value for help text that requires more reading time.
    ///
    /// Seconds as a Double rather than an Int: the durations here are chosen by reading the
    /// text aloud, and that does not always land on a whole second. Integer literals at the
    /// existing call sites are unaffected.
    var autoDismissDuration: Double = 10
    /// Optional dismiss token. When this value changes, any open popover is immediately
    /// closed. Pass `AnyHashable(someEquatableValue)` to enable carousel-style dismissal.
    /// Defaults to `nil`; omitting it preserves the pre-existing behavior exactly.
    var dismissToken: AnyHashable? = nil

    @State private var isShowingPopover = false
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        HelpButtonRepresentable(isShowingPopover: $isShowingPopover)
            .frame(width: 22, height: 22)
            .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
                Text(helpText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(width: 260)
            }
            // Position-change dismissal: close an open popover whenever the button's
            // vertical position in global coordinates changes — i.e., the user scrolled
            // the enclosing container or the button's host view moved vertically.
            //
            // Implemented with the first-party onGeometryChange(for:of:action:) modifier
            // (macOS 15 SDK) rather than the previous background GeometryReader, which
            // was a greedy, layout-participating view: as a .background it added an
            // extra layout node to EVERY HelpPopoverButton, including one per release
            // card in the FilmSheet Releases carousel, contributing to the peak initial
            // layout pass that competes with the sheet presentation animation — the
            // same contention the sheet's other geometry consumers were rewritten to
            // avoid (ScrollActivityObserver in 30_20_FSControlHelpers.swift;
            // FSTabDetailsView's scroll anchor uses the same onGeometryChange
            // substitution). Its content closure also re-evaluated on EVERY geometry
            // change, including per-frame horizontal offsets during the carousel's
            // spring slide where minY never changes — pure per-frame overhead.
            // onGeometryChange computes only the reduced value (minY) and fires the
            // action solely when it changes, with no layout node and no view-tree work
            // during animation frames.
            //
            // Behavior is preserved exactly: any vertical movement (scrolling, card
            // fly-up) closes an open popover. Unlike the GeometryReader's onChange, the
            // action also fires once with the initial value on mount; the
            // isShowingPopover guard makes that a no-op, since @State isShowingPopover
            // always starts false for a new view identity. The transform closure
            // captures nothing, satisfying strict-concurrency requirements regardless
            // of the closure's Sendable annotation in the SDK.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minY
            } action: { _ in
                if isShowingPopover {
                    isShowingPopover = false
                }
            }
            .onChange(of: isShowingPopover) { _, newValue in
                if newValue {
                    scheduleAutoDismiss()
                } else {
                    cancelAutoDismiss()
                }
            }
            // Dismiss the popover whenever the caller-supplied dismiss token changes.
            // The guard on dismissToken != nil ensures this handler is a no-op for
            // every call site that omits the parameter (the default nil never changes,
            // so onChange never fires). Using AnyHashable lets callers pass any
            // Hashable value — Int carousel indices, UUIDs, enum cases — without
            // requiring a generic parameter on the struct.
            .onChange(of: dismissToken) { _, _ in
                if isShowingPopover {
                    isShowingPopover = false
                }
            }
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(autoDismissDuration))
                isShowingPopover = false
            } catch {
                // Task was canceled because the user dismissed manually; nothing to do.
            }
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
}

// MARK: - HelpButtonRepresentable
/// Wraps NSButton with the macOS-standard Help button bezel style.
/// The button's click is wired through a Coordinator target/action so that
/// AppKit's event handling is respected and the toggle reaches SwiftUI state.
struct HelpButtonRepresentable: NSViewRepresentable {
    @Binding var isShowingPopover: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.buttonClicked(_:)))
        button.bezelStyle = .helpButton
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        var parent: HelpButtonRepresentable
        init(_ parent: HelpButtonRepresentable) { self.parent = parent }

        @objc func buttonClicked(_ sender: NSButton) {
            parent.isShowingPopover.toggle()
        }
    }
}

// MARK: - PathBarView
// Reusable path bar component for displaying file/folder paths in SettingsSheet.swift
// with middle-truncation for long paths.
// Example usage:
// PathBarView(
//     pathComponents: ["Users", "john", "Documents", "file.txt"],
//     icon: Image(systemName: "doc.fill"))
struct PathBarView: View {
    let pathComponents: [String]
    let icon: Image
    
    // Joins path components with the separator character
    private var joinedPath: String { pathComponents.joined(separator: " › ") }
    
    var body: some View {
        HStack(spacing: 6) {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.accentColor)
            Text(joinedPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer() }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)) }
}

// MARK: - Export Staging

/// Where every export is built before it is handed to the user.
///
/// Backups and library PDFs are assembled under `<Application Support>/ExportStaging/<UUID>/`,
/// inside the sandbox container, and only a COMPLETE item ever leaves it. A failure or a
/// cancel at any point before delivery is cleaned up entirely inside the container: nothing
/// in the user's chosen folder is created, replaced or removed on the way to a failure.
///
/// Delivery never replaces anything either. When the name is taken, ` 1`, ` 2`, … is
/// appended before the extension, as Finder does. The check and the claim are one step —
/// an exclusive rename the kernel refuses with EEXIST, for plain files, packages, empty
/// folders and symbolic links alike — so there is no window between "the name is free" and
/// "the item is there" in which a file the user just made could be overwritten. See
/// `deliver`.
///
/// Rooted in `Preferences.dataFolderURL`, so a debug-sandbox run stages inside its own
/// throwaway root like every other disk consumer.
nonisolated enum ExportStaging: Loggable {
    nonisolated static let logTag = "[ExportStaging]"

    /// The folder every export's private staging directory lives under.
    static var rootURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("ExportStaging", isDirectory: true) }

    /// A new, empty, uniquely named directory for one export. Unique so two exports that
    /// would produce the same filename cannot race for one path.
    static func makeDirectory() throws -> URL {
        guard let root = rootURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Staged exports are transient and can be gigabytes with posters: keep them out of
        // Time Machine, as the temporary directory they used to be built in was.
        var rootForValues = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootForValues.setResourceValues(values)
        return directory }

    /// Removes one export's staging directory, whatever it still holds.
    static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory) }

    /// Removes staging directories that a crash or a force quit stranded mid-export.
    /// Launch-time only: called while an export is running, it would pull that export's
    /// directory out from under it.
    static func purgeLeftovers() {
        guard let root = rootURL,
              FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: root)
            log("Removed leftover export staging folder")
        } catch {
            log("WARNING: Could not remove leftover export staging folder: \(error.localizedDescription)") } }

    /// Moves a finished `item` out of staging into `folder` as `name`, or as the first free
    /// `name 1`, `name 2`, … when that is taken. Returns where it landed. Throws, having
    /// created nothing under a visible name, when it cannot deliver.
    ///
    /// The caller holds any security scope `folder` needs.
    ///
    /// Not `FileManager.moveItem`: that checks for an existing item and then calls plain
    /// `rename(2)`, which REPLACES a file or an empty folder created in between. A
    /// RENAME_EXCL rename refuses instead, and the kernel honors it on APFS, HFS+, FAT32 and
    /// exFAT alike (verified 2026-10-04).
    static func deliver(_ item: URL, into folder: URL, as name: String) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func numbered(_ n: Int) -> String {
            n == 0 ? name : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)") }

        // The common case: one exclusive rename, which either lands the whole item or
        // changes nothing at all.
        if let delivered = try claimName(for: item, in: folder, numbered: numbered) {
            return delivered }

        // The rename cannot cross to the destination — another volume, or a sandbox that
        // refuses it. Copy to a private, hidden, UUID-named path in the destination first,
        // then claim the real name with the same exclusive rename, now on one volume. The
        // destination never holds a partial item under a name the user would open.
        let fm = FileManager.default
        let partial = folder.appendingPathComponent(".\(name).\(UUID().uuidString).partial")
        do {
            try fm.copyItem(at: item, to: partial)
        } catch {
            // Only ever this export's own UUID-named path.
            if (error as? CocoaError)?.code != .fileWriteFileExists { try? fm.removeItem(at: partial) }
            throw error }
        do {
            if let delivered = try claimName(for: partial, in: folder, numbered: numbered) {
                return delivered }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: folder])
        } catch {
            try? fm.removeItem(at: partial)
            throw error }
    }

    /// Renames `source` into `folder` under the first free name `numbered(0)`, `numbered(1)`,
    /// …. Returns nil when the rename itself is impossible — a different volume, or a
    /// permission refusal the copy path may not share — so the caller can copy instead.
    private static func claimName(for source: URL, in folder: URL,
                                  numbered: (Int) -> String) throws -> URL? {
        let from = source.path(percentEncoded: false)
        for n in 0...9_999 {
            let target = folder.appendingPathComponent(numbered(n))
            let to = target.path(percentEncoded: false)
            // RENAME_EXCL makes "is the name free" and "take it" one step in the kernel:
            // it fails with EEXIST rather than replace anything — a file, a package, an
            // empty folder or a symbolic link.
            if unsafe renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return claimed(target, n) }
            var code = errno
            if code == ENOTSUP || code == EINVAL {
                // A file system that cannot honor RENAME_EXCL. Check, then rename: the one
                // shape with a window, and only on such volumes. lstat, so a dangling
                // symbolic link still counts as taken.
                var info = stat()
                if unsafe lstat(to, &info) == 0 { continue }
                if unsafe rename(from, to) == 0 { return claimed(target, n) }
                code = errno }
            switch code {
            case EEXIST, ENOTEMPTY:
                continue
            case EXDEV, EPERM, EACCES:
                return nil
            default:
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: folder])
    }

    private static func claimed(_ target: URL, _ n: Int) -> URL {
        if n > 0 { log("Requested name was taken at the destination — delivered as '\(target.lastPathComponent)'") }
        return target }
}

// MARK: - StandardPlaceholder
// Reusable placeholder component with consistent spacing and positioning.
// Usage (Only the glyph is required):
// Full placeholder with optional action button
// StandardPlaceholder(
//     glyph: "magnifyingglass",
//     title: "No Results",
//     message: "Try adjusting your search query.",
//     actionTitle: "Clear Query",
//     action: { clearSearch() } )
struct StandardPlaceholder: View {
    // MARK: - Properties
    // SF Symbol name for the glyph.
    let glyph: String
    // Optional title text displayed below the glyph.
    let title: String?
    // Optional message text displayed below the title.
    let message: String?
    // Optional action button title.
    let actionTitle: String?
    // Optional action button handler.
    let action: (() -> Void)?

    // MARK: - Layout Constants
    // Fixed height for glyph container to prevent shifting with different glyph sizes.
    private let glyphContainerHeight: CGFloat = 100
    // Glyph size.
    private let glyphSize: CGFloat = 64
    // Spacing between glyph and title.
    private let glyphToTitleSpacing: CGFloat = 16
    // Spacing between title and message.
    private let titleToMessageSpacing: CGFloat = 8
    // Spacing between message and action button.
    private let messageToActionSpacing: CGFloat = 16
    // Maximum width for message text.
    private let messageMaxWidth: CGFloat = 320

    // MARK: - Initializers
    // Creates a placeholder with all optional elements.
    init(
        glyph: String,
        title: String? = nil,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action }

    // MARK: - Body
    // Every placeholder sits at one fixed position, whatever it holds. What is centered
    // is not the content but a hidden strut behind it: the layout of a placeholder with
    // a title and a ONE-line message. Content and strut share a top edge, and the frame
    // centers the STRUT's center (the `anchor` guide) rather than the content's, so the
    // glyph, the title, and the message's first line land on the same points in every
    // placeholder; a message that wraps to more lines, and the action button, only
    // extend downward. (Centering the content itself moved all of it up by half of
    // every extra line.) Both stay inside the ZStack's bounds, so the button hit-tests
    // normally.
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: glyphContainerHeight)
                titleText("X")
                    .padding(.top, glyphToTitleSpacing)
                messageText("X")
                    .padding(.top, titleToMessageSpacing) }
            .hidden()
            .alignmentGuide(Self.anchor) { $0[VerticalAlignment.center] }
            content }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: Alignment(horizontal: .center, vertical: Self.anchor))
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5)) }

    /// The strut's vertical center; the frame's own value is its center.
    private enum Anchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center] } }
    private static let anchor = VerticalAlignment(Anchor.self)

    private var content: some View {
        VStack(spacing: 0) {
            // Fixed-height container for glyph ensures consistent positioning.
            VStack {
                Image(systemName: glyph)
                    .font(.system(size: glyphSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary) }
            .frame(height: glyphContainerHeight)
            // Title (if present).
            if let title = title {
                titleText(title)
                    .padding(.top, glyphToTitleSpacing) }
            // Message (if present).
            if let message = message {
                messageText(message)
                    .padding(.top, title != nil ? titleToMessageSpacing : glyphToTitleSpacing) }
            // Action button (if present).
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, messageToActionSpacing) } } }

    // The strut and the content share these, so the strut's lines are exactly as tall.
    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.title2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary) }

    private func messageText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: messageMaxWidth) }
}

// MARK: - WindowAccessor
// Helper NSViewRepresentable to capture the hosting NSWindow from SwiftUI views.
// Usage:
//   @State private var hostingWindow: NSWindow?
//
//   var body: some View {
//       MyView()
//           .background(WindowAccessor(window: $hostingWindow))
//   }
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer the binding write one run-loop turn so the NSView is fully inserted
        // into the window hierarchy before we read view.window. Using Task @MainActor
        // keeps this on the main actor and avoids mixing GCD and Swift concurrency.
        Task { @MainActor in
            self.window = unsafe view.window
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Only update the binding when the window reference actually changes.
        // updateNSView is called on every SwiftUI render pass; unconditionally
        // writing the binding triggers unnecessary objectWillChange notifications.
        let current = unsafe nsView.window
        if current !== self.window {
            Task { @MainActor in
                self.window = current
            }
        }
    }
}

// MARK: - Rounded-Rect Path
extension CGPath {
    /// A rounded rectangle with the system's CONTINUOUS ("squircle") corner curve — the path
    /// counterpart of `layer.cornerCurve = .continuous`, so shadows and strokes built from it
    /// match the posters they follow. Core Graphics' own rounded-rect APIs
    /// (`CGPath(roundedRect:…)`, `CGMutablePath.addRoundedRect`) only draw circular arcs, so the
    /// curve comes from SwiftUI's `RoundedRectangle(style: .continuous)`, used purely as a
    /// geometry calculator (see `GalleryItem.updateRingPath(posterRect:)`). Also memory-safe:
    /// unlike `CGPath(roundedRect:cornerWidth:cornerHeight:transform:)` it takes no
    /// `UnsafePointer`, so it needs no `unsafe` marker.
    static func continuousRoundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath
    }

    /// A pill (fully rounded ends) with the continuous corner curve — the path counterpart of
    /// SwiftUI's `Capsule(style: .continuous)`, which the app's own SwiftUI badges use. A square
    /// rect still yields a circle.
    static func continuousCapsule(_ rect: CGRect) -> CGPath {
        Capsule(style: .continuous).path(in: rect).cgPath
    }
}

// MARK: - Array Chunking
// Unified chunked(into:) extension used by DataManager, PosterCache, and DBReader
// for batch processing of large collections. Internal access allows all files in the
// module to use it without isolation concerns (Array is a value type).
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - UUID Placeholder Label
// Single source of truth for the short identifier printed over a film's placeholder
// poster art — the gallery tile (GalleryItemView) and the RightSidebar Header both
// render it, and both must produce the identical string for the same film.
extension UUID {
    /// The last 10 characters of this UUID's canonical string form, uppercase.
    ///
    /// Ten characters is what fits on one line, untruncated, at the placeholder label's
    /// intended text size — long enough to tell two placeholder items apart at a glance.
    ///
    /// Built straight from the UUID's final five bytes rather than via
    /// `String(uuidString.suffix(10))`. The canonical form is 8-4-4-4-12, so its last
    /// 12 characters are the hex of bytes 10...15 and its last 10 are the hex of bytes
    /// 11...15 — no separator can fall inside that span, which makes the byte-wise
    /// construction exactly equivalent. The suffix spelling would allocate and format a
    /// full 36-character string and then a second string to slice 10 characters back out
    /// of it; this writes the 10 characters it needs and nothing else. That matters here
    /// because the gallery calls this per tile during scrolling and reconfiguration.
    var placeholderIDSuffix: String {
        let b = self.uuid
        // ASCII digit for one hex nibble: '0'...'9' = 48...57, 'A'...'F' = 65...70.
        func hex(_ nibble: UInt8) -> UInt8 { nibble < 10 ? 48 + nibble : 55 + nibble }
        // Writes the 10 ASCII bytes straight into the String's own storage: one
        // allocation total, no intermediate array, and the result is all-ASCII so it
        // stays in the small (inline) UTF-8 representation — 10 bytes fits comfortably
        // inside String's 15-byte small-string capacity, so in practice this heap-
        // allocates nothing at all.
        return unsafe String(unsafeUninitializedCapacity: 10) { buffer in
            // Unrolled deliberately: five fixed tuple members cannot be iterated without
            // first materializing them into a collection, which is the one allocation
            // this whole spelling exists to avoid.
            func write(_ byte: UInt8, at i: Int) {
                unsafe buffer[i] = hex(byte >> 4)
                unsafe buffer[i + 1] = hex(byte & 0x0F)
            }
            write(b.11, at: 0)
            write(b.12, at: 2)
            write(b.13, at: 4)
            write(b.14, at: 6)
            write(b.15, at: 8)
            return 10
        }
    }
}

// MARK: - Standard Error

/// Writes `message` to standard error as-is (no newline added). The same unbuffered write as
/// `fputs(message, stderr)`, without touching the C `stderr` global, which Strict Memory
/// Safety flags as unsafe; a closed stderr is ignored, as `fputs` ignored it. Mirrors
/// DebugLogKit's private helper of the same purpose.
nonisolated func printToStandardError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
}

// MARK: - TaskHandle
/// A lightweight RAII wrapper that cancels its wrapped Task when deallocated.
///
/// **Why this exists:**
/// Swift 6 prohibits both `nonisolated` and `nonisolated(unsafe)` on mutable stored
/// properties in actor-isolated types:
///   - `nonisolated` is only valid on immutable (`let`) stored properties.
///   - `nonisolated(unsafe)` has no effect when the property type is `Sendable`
///     (e.g., `Task<Void, Never>`), so the compiler rejects it as meaningless.
///
/// `TaskHandle` resolves this by being non-`Sendable` itself. Storing a `TaskHandle`
/// as a plain `private var` on an `@Observable` class requires no special annotations —
/// the property is actor-isolated like any other stored property — yet cancellation is
/// still guaranteed: when the owner is deallocated its `deinit` releases the
/// `TaskHandle`, which in turn cancels the underlying `Task` from its own `deinit`.
/// The `[weak self]` captures inside the wrapped Tasks prevent resurrection.
final class TaskHandle {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }
}

// MARK: - Menu-Dismissal-Deferred Execution

/// Runs `block` two run-loop cycles from now — after CoreAnimation has committed the
/// current cycle's menu/picker dismissal animation.
///
/// Rationale (shared by every picker-driven view switch and reload in the app): a
/// Picker/Menu/segmented-control action handler fires synchronously inside the AppKit
/// event callback. Work that triggers an NSCollectionView/NSTableView reloadData in
/// that same run loop cycle competes with CoreAnimation's dismissal animation frames —
/// and a single async hop (Task or DispatchQueue.main.async) still runs in the same
/// cycle before CA commits, providing no relief. The double hop guarantees the block
/// runs in the NEXT run loop cycle, after CA has already committed the first animation
/// frame and the dismissal is in motion.
///
/// Callers must update any state that drives the picker's own label/checkmark
/// synchronously BEFORE calling this, so the control reflects the new choice
/// immediately with no visual flicker; only the heavy reload work is deferred.
///
/// DispatchQueue.main.async is used rather than Task { @MainActor in } because these
/// deferrals originate from AppKit event callbacks delivered at User-Interactive QoS:
/// DispatchQueue.main.async inherits the caller's QoS automatically, whereas a bare
/// Task defaults to .default QoS and produces the "Thread running at User-interactive
/// quality-of-service class waiting on a lower QoS thread" priority-inversion warning.
@MainActor
func deferPastMenuDismissal(_ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        DispatchQueue.main.async {
            block()
        }
    }
}

// MARK: - Sub-Category Navigation

/// Shared tail for every sub-category picker selection: the Recents categories, the
/// purchased/unpurchased format variants, the rotation and alternate-versions variants,
/// and the Filtered Library sorting variants.
///
/// These transitions change the underlying film set exactly as much as switching to a
/// different sidebar item does, but `appState.selectedSidebarItem` stays pinned to the
/// parent item throughout (or, for Recents, never changes at all), so
/// AppState.navigate(to:) — the single authoritative location for selection clearing on
/// ordinary sidebar navigation — either no-ops or never runs for them. The selection clear
/// therefore happens here instead, so a selected film doesn't silently survive into an
/// unrelated sub-category whenever the same film ID happens to also appear there.
///
/// Note the ordering below matches navigate(to:)'s: clear first, switch second, so the
/// sub-category's first painted frame already shows no focus ring.
@MainActor
enum SubcategoryNavigation {

    /// Performs the standard sub-category switch sequence: clear the current selection
    /// (when the sub-category genuinely changed), pin the sidebar highlight to the
    /// parent item, and defer the actual view switch past the menu-dismissal animation.
    ///
    /// The caller must update its own `selectedX` property synchronously BEFORE calling
    /// this, so the picker label reflects the new choice immediately; only the view
    /// switch itself — whose reload would compete with the dismissal animation — is
    /// deferred (see `deferPastMenuDismissal`).
    ///
    /// - Parameters:
    ///   - clearingSelection: Pass `false` when the sub-category did not genuinely
    ///     change (e.g. re-pressing the same Recents category's shortcut, where the
    ///     switch is still wanted for its reload side effect but nothing has left the
    ///     view). Defaults to `true` — callers that guard on a genuine change before
    ///     calling can rely on the default.
    ///   - parentSidebarItem: The sidebar item to pin highlighting to, or `nil` to
    ///     leave `selectedSidebarItem` untouched (the Recents case, where the sidebar
    ///     item is already correct). `AppDelegate.appState` is set at process init,
    ///     before any UI interaction, so it is always available here.
    ///   - viewID: The destination view for the deferred `switchToViewSync`.
    ///   - immediate: Switch in this turn instead of deferring. Passed by the title bar's
    ///     menu-style pickers: they are NSPopUpButtons, which send their action only after
    ///     the menu's fade has finished (see SubcategoryPicker), so the deferral would
    ///     protect nothing and only split the switch across two update passes. Segmented
    ///     pickers, shortcuts and menu-bar commands keep the deferral.
    static func performSwitch(clearingSelection: Bool = true,
                              parentSidebarItem: SidebarItem? = nil,
                              to viewID: ViewIdentifier,
                              immediate: Bool = false) {
        if clearingSelection {
            SelectionState.shared.clearImmediate()
        }
        if let parentSidebarItem {
            AppDelegate.appState?.navigate(to: parentSidebarItem)
        }
        if immediate {
            ViewStateManager.shared.switchToViewSync(viewID)
        } else {
            deferPastMenuDismissal {
                ViewStateManager.shared.switchToViewSync(viewID)
            }
        }
    }
}

// MARK: - "Show in List" Navigation

/// The shared implementation behind every "Show in List ▸" menu entry — the MenuBar's
/// "Film" menu (ShowInListMenuItems) and the gallery contextual menu
/// (GalleryContextMenu.makeShowInListSubmenu) — covering both the user-generated lists
/// and the "Smart Lists" sub-menu.
///
/// Beyond performing the view switch, this preserves the single selected film across the
/// transition and places it in the topmost row of the destination's viewport. That is a
/// deliberate, narrow exception to the "always clear selection on view change" rule
/// enforced by AppState.navigate(to:): the user is navigating *to* a film's
/// membership, so losing that film on arrival — and landing at the top of an unrelated
/// stretch of the list — defeats the point of the command.
///
/// The sequence below is ordered the way it is for three separate reasons, none of them
/// interchangeable:
///
///  1. **Sub-variant pickers first.** A smart-list destination may be a sub-variant with
///     no sidebar row of its own ("Purchased 4K", "Viewed Over One Year Ago", "Blacklisted"
///     …). `selectedSidebarItem` must be pinned to the parent row, so the picker states are
///     resolved up front — which also makes `ViewIdentifier.from(parentItem)` already
///     evaluate to the true destination for anything that consults it mid-transition
///     (notably GalleryView.handleSidebarChange's `clear(unlessTargeting:)`, which would
///     otherwise discard the scroll intent as misaddressed).
///  2. **Pre-load before the sidebar flip.** `switchToViewSync` is called first so
///     `dataCoordinator.films` already holds the destination's real, fully filtered and
///     sorted film set before SwiftUI renders the destination gallery. This is the same
///     pre-load MainView performs on search exit, and it exists for the same two reasons:
///     the destination's first `updateNSView` sees correct data (no multi-frame blank gap),
///     and the membership test below becomes exact rather than approximate — a film
///     excluded by the destination's own active filters must NOT be preserved as selected,
///     or SelectionState and the right sidebar end up pointing at a film the user can
///     neither see nor deselect.
///  3. **Sidebar flip last.** `appState.navigate(to:)` is what consumes the
///     selection-preservation token (deciding, synchronously and ahead of the flip,
///     whether to clear) and what triggers the destination gallery's mount (whose
///     makeNSView consumes the scroll intent).
@MainActor
enum ShowInListNavigation: Loggable {
    nonisolated static let logTag = "[ShowInListNavigation]"

    // MARK: - Destination

    /// Where a "Show in List" entry navigates to. Deliberately narrower than SidebarItem:
    /// these are the only two kinds of list membership a film can have, and modeling them
    /// explicitly keeps callers from having to know that a smart-list sub-variant and its
    /// sidebar row are different things.
    enum Destination: Equatable {
        case list(UUID)
        case smartList(SmartListType)
    }

    // MARK: - Selection Preservation Token

    /// One-shot token read by AppState.navigate(to:) to suppress its selection clear for
    /// exactly the one transition this type initiates.
    ///
    /// Kept here rather than on AppState because the producers are an AppKit contextual
    /// menu and a SwiftUI command menu, and this type already owns the rest of the
    /// transition's sequencing. It is armed only immediately before the sidebar flip, and
    /// `consumePreservedFilmID()` clears it unconditionally on the very next navigate(to:)
    /// that changes the item, so it cannot bleed into a later, unrelated transition even if
    /// the one it was armed for is abandoned.
    private static var preservedFilmID: UUID?

    /// Returns and clears the pending preservation token. Always call this exactly once
    /// per item-changing navigate(to:), regardless of whether the value ends up being used.
    static func consumePreservedFilmID() -> UUID? {
        defer { preservedFilmID = nil }
        return preservedFilmID
    }

    // MARK: - Navigation

    /// Navigates to `destination`, keeping `filmID` selected and scrolled to the top of
    /// the destination viewport.
    ///
    /// Callers must have established that `filmID` is the sole current selection. A no-op
    /// when the destination view is already the one being displayed, matching the existing
    /// behavior of re-choosing the checkmarked entry.
    static func navigate(to destination: Destination, preserving filmID: UUID) {
        guard let appState = AppDelegate.appState,
              let coordinator = AppDelegate.dataCoordinator else { return }

        let targetViewID: ViewIdentifier
        let sidebarItem: SidebarItem
        switch destination {
        case .list(let listID):
            targetViewID = .list(listID)
            sidebarItem  = .list(listID)
        case .smartList(let type):
            // The exact variant is the view; its parent is the row that highlights.
            targetViewID = .smartList(type)
            sidebarItem  = .smartList(type.sidebarParent)
        }

        // Already showing exactly this view — nothing to navigate to, and nothing to
        // preserve or scroll. Clearing any stale token here keeps this early return from
        // leaving one armed for some later, unrelated view change.
        if appState.selectedSidebarItem == sidebarItem,
           ViewStateManager.shared.activeView == targetViewID {
            preservedFilmID = nil
            return
        }

        // Step 1 — resolve the sub-variant picker to the destination. syncAll hands the
        // type to every family; only the one that owns it changes. Mirrors the identical
        // call in GalleryView.handleSidebarChange.
        if case .smartList(let type) = destination {
            SmartListVariantState.syncAll(to: type)
        }

        // A sub-variant switch within the smart list already on screen changes the view
        // without changing the sidebar row. That distinction drives three decisions below:
        // no selection clear will fire (so no token is needed), no fresh gallery will
        // mount (so the scroll intent must be consumable on the reuse path), and the
        // sidebar assignment itself must be skipped.
        let isSidebarChange = appState.selectedSidebarItem != sidebarItem

        // Step 2 — pre-load the destination's films. Any intent left over from an earlier,
        // abandoned transition is discarded first so it cannot outrank this one.
        GalleryScrollIntent.shared.clear()
        preservedFilmID = nil
        ViewStateManager.shared.switchToViewSync(targetViewID)

        // Step 3 — preserve and arm the scroll, but only if the film genuinely survives
        // into the destination's loaded set (see the pre-load rationale above). When it
        // does not, the standard clear-on-view-change behavior applies unchanged.
        if coordinator.films.contains(where: { $0.id == filmID }) {
            if isSidebarChange {
                preservedFilmID = filmID
            }
            // Placed in the top row, not merely made visible — the whole point of the
            // feature — and, unlike the search-exit handoff, never gated by a preference.
            GalleryScrollIntent.shared.set(filmID: filmID,
                                           targetViewID: targetViewID,
                                           consumableOnReuse: !isSidebarChange)
            Self.log("Navigating to \(targetViewID) with film \(filmID) preserved and pinned to top")
        } else {
            Self.log("NOTE: film \(filmID) is not present in \(targetViewID) after load — navigating without preservation")
        }

        // Step 4 — flip the sidebar last.
        if isSidebarChange {
            appState.navigate(to: sidebarItem)
        }
    }
}

// MARK: - Diagnostic Timing
//
// Formatting helpers for the startup-breakdown logging in MemoryStoreCache, DataManager,
// PosterCache, DataCoordinator, and FilmTrackerApp. These exist so those measurements can
// be expressed with `ContinuousClock` rather than `Date()`.
//
// `ContinuousClock` is the correct tool for measuring elapsed time: it is monotonic, so it
// cannot be perturbed by a system clock adjustment. That is not a hypothetical concern for
// startup measurements specifically — a network time sync landing during launch is exactly
// the kind of event that can make a wall-clock delta negative or wildly wrong, and the
// numbers being collected here are single-digit-to-hundreds of milliseconds, well inside
// the range such a correction would corrupt.
extension Duration {
    /// This duration expressed as a floating-point count of milliseconds.
    ///
    /// `components` yields whole seconds plus a remainder in attoseconds (1e-18 s); one
    /// millisecond is therefore 1e15 attoseconds.
    var diagnosticMilliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    /// Log-friendly rendering, e.g. `"12.4ms"`. Deliberately not named `milliseconds`,
    /// which is already taken by the standard library's `Duration.milliseconds(_:)` factory.
    var formattedMilliseconds: String {
        "\(Fmt.fixed(diagnosticMilliseconds, 1))ms"
    }
}

// MARK: - Alert Error Detail
// Surfacing raw error text in the failure alerts that would otherwise send the user to
// a log they almost certainly do not have. Debug logging is off by default and is only
// ever turned on deliberately, so "check the log" is, in practice, advice to consult a
// file that was never written. The detail therefore travels in the alert payload itself.
enum AlertErrorDetail {
    /// Longest detail string an alert will show. Long enough for the message and the
    /// leading type information that identifies the fault; short enough that a verbose
    /// Core Data error cannot grow the alert past the screen.
    static let maxLength = 200

    /// Renders an error as the full, uncapped detail string carried in alert payloads.
    ///
    /// Uses `String(describing:)` rather than `localizedDescription` deliberately. For
    /// Core Data errors `localizedDescription` is routinely the useless
    /// "The operation couldn't be completed"; the interpolated form is what carries the
    /// underlying type and reason, and is what the log statements at these call sites
    /// already capture.
    ///
    /// Payloads hold this rather than the capped form so "Copy Error" can hand over the
    /// whole fault; `cap(_:)` elides it only at the moment of display.
    static func full(_ error: any Error) -> String {
        String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Elides a detail string to `maxLength` for display in an alert message.
    static func cap(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let cut = text.index(text.startIndex, offsetBy: maxLength - 1)
        return String(text[..<cut]) + "…"
    }

    /// Places the untruncated detail on the general pasteboard, so the copy the user
    /// sends on is the whole error rather than the elided form they were shown.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Directory Checks

nonisolated extension URL {
    /// Whether a directory (a package counts) exists at this file URL, following symbolic
    /// links as `FileManager.fileExists(atPath:isDirectory:)` does. The URL resource-value
    /// spelling of that check, without its `ObjCBool` out-pointer.
    var isExistingDirectory: Bool {
        (try? resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

// MARK: - Fixed-Format Numbers

/// Typed front ends for the printf patterns the app uses everywhere. `String(format:)`
/// takes C varargs, so nothing checks that an argument matches its specifier: a `%d`
/// handed a `Double`, or a `%d` (32-bit) handed a 64-bit `Int` past 2³¹, reads the wrong
/// bits. Here the specifier and the Swift parameter type are fixed together, which is what
/// makes the one `unsafe` call inside each safe to call from anywhere. Output is
/// byte-identical to the `String(format:)` calls they replace: same C formatting, no locale.
nonisolated enum Fmt {
    /// `%.<places>f` — e.g. `fixed(2.345, 2)` → "2.35" (C rounding of the binary value).
    static func fixed(_ value: Double, _ places: Int) -> String {
        unsafe String(format: "%.\(places)f", value)
    }

    /// `$%.2f` — a dollar amount to the cent.
    static func dollars(_ value: Double) -> String {
        "$" + fixed(value, 2)
    }

    /// `%d` — an integer, with the argument held to `Int`.
    static func int(_ value: Int) -> String {
        String(value)
    }

    /// `%0<width>d` — an integer left-padded with zeros to `width` characters.
    ///
    /// Built from `String(_:)` rather than `String(format:)`, with printf's exact rules: the
    /// sign counts toward `width` and the zeros go between it and the digits ("-0012" for
    /// `padded(-12, 5)`), and a value already `width` long or longer is never truncated.
    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        let zeros = max(0, width - sign.count - digits.count)
        return sign + String(repeating: "0", count: zeros) + digits
    }
}

// MARK: - English Comparison Rules

/// The rules every sort and text comparison in the app uses: English, whatever the
/// system's language.
///
/// `localizedStandardCompare` and its kin follow the FIRST PREFERRED LANGUAGE in System
/// Settings — not the app's own language, and not the Region setting. An English-only app
/// still reports an English `Locale.current` ("en_CZ") while those calls apply Czech rules
/// ("ch" after "h"), so a Czech, Lithuanian or Estonian first language reorders hundreds of
/// a library's titles, Swedish and Danish move Å/Ä/Ö/Ø past Z, and Turkish changes how
/// "I" folds. Pinning the locale keeps Film Tracker's order one order everywhere.
///
/// Measured 2026-10-27 on an English system: identical results to the calls they replace
/// on 400,000 random pairs (letters each language treats specially, accents, ligatures,
/// fullwidth digits, punctuation) and on the full title order of a 1,400-film library;
/// under Czech, Swedish, Turkish, Lithuanian, Danish and Spanish first languages these
/// still give the English results where the old calls did not. An `NSLocale` held once and
/// handed to `NSString.compare` costs the same as `localizedStandardCompare` (6.5 vs 6.6 ms
/// to sort 1,400 titles); bridging a Swift `Locale` on every call cost 8.8 ms.
nonisolated enum EnglishText {
    static let locale = Locale(identifier: "en_US")
    fileprivate static let nsLocale = NSLocale(localeIdentifier: "en_US")
    /// The options `localizedStandardCompare` documents itself as (Finder-like order).
    static let standardOptions: String.CompareOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]
    /// `localizedStandardCompare` as a `SortComparator`, for `KeyPathComparator` columns
    /// (whose default for a String is `.localizedStandard`, the system-language rules).
    static let standardComparator = String.Comparator(options: standardOptions, locale: locale)
}

nonisolated extension String {
    /// `localizedStandardCompare(_:)` under English rules.
    func englishStandardCompare(_ other: String) -> ComparisonResult {
        let text = self as NSString
        return text.compare(other, options: EnglishText.standardOptions,
                            range: NSRange(location: 0, length: text.length), locale: EnglishText.nsLocale)
    }

    /// `localizedCaseInsensitiveCompare(_:)` under English rules.
    func englishCaseInsensitiveCompare(_ other: String) -> ComparisonResult {
        let text = self as NSString
        return text.compare(other, options: .caseInsensitive,
                            range: NSRange(location: 0, length: text.length), locale: EnglishText.nsLocale)
    }

    /// `localizedCaseInsensitiveContains(_:)` under English rules.
    func englishCaseInsensitiveContains(_ other: String) -> Bool {
        range(of: other, options: .caseInsensitive, locale: EnglishText.locale) != nil
    }
}
