// MARK: - DVLibraryInsights.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The figures the redesigned Data Visualizations tab added on top of LibraryStatistics:
// LibraryInsights (all-time, derived across every date series the library stores —
// viewing history, purchase dates, lowest-price dates, date added) and
// ViewingPeriodStatistics (one calendar year of viewing, optionally to date, with the
// same span of the prior year beside it). Both are plain value types built in one
// pass over FilmSnapshots, like LibraryStatistics, with no I/O; DVDataset bundles one
// recalculation of all of them so the tab can run it off the main actor.

import Foundation

// MARK: - Shared Row Shapes

/// One labeled tally: a count and, where the caller supplies a denominator, its share.
struct DVTally: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let count: Int
    /// Whole-number share of the population the tally is drawn from; nil when the row
    /// has no meaningful denominator (a raw count).
    let percent: Int?

    init(_ label: String, _ count: Int, of total: Int? = nil) {
        self.label = label
        self.count = count
        if let total, total > 0 {
            self.percent = Int((Double(count) / Double(total) * 100).rounded())
        } else {
            self.percent = nil
        }
    }
}

/// One ranked row: a name and a preformatted value.
struct DVRank: Identifiable, Equatable {
    var id: String { name + "|" + value }
    let name: String
    let value: String
    /// Optional secondary columns (the Directors table prints rating and views per film).
    var extras: [String] = []
    /// The film's release year, shown in parentheses after `name` where relevant (the
    /// Most Rewatched card). Nil for a row this data does not apply to.
    var year: Int? = nil
}

/// One film in the rotation "Coming Up Next Month" list, with the figures that rank it
/// for the card's six slots: rating, then viewings, then purchased releases.
struct DVUpcomingRotation: Identifiable, Equatable {
    var id: UUID { filmID }
    let filmID: UUID
    let name: String
    var year: Int? = nil
    var rating = 0
    var viewings = 0
    var purchasedReleases = 0
    let titleSort: GalleryTitleKey

    init(filmID: UUID, name: String, sortName: String = "", year: Int? = nil, rating: Int = 0,
         viewings: Int = 0, purchasedReleases: Int = 0) {
        self.filmID = filmID
        self.name = name
        self.year = year
        self.rating = rating
        self.viewings = viewings
        self.purchasedReleases = purchasedReleases
        titleSort = GalleryTitleKey(name: name, sortName: sortName, year: year ?? 0, filmID: filmID)
    }

    /// The card's order: highest rating first, then most viewings, then most purchased
    /// releases, then the gallery's Title order.
    static func ranksBefore(_ a: DVUpcomingRotation, _ b: DVUpcomingRotation) -> Bool {
        if a.rating != b.rating { return a.rating > b.rating }
        if a.viewings != b.viewings { return a.viewings > b.viewings }
        if a.purchasedReleases != b.purchasedReleases { return a.purchasedReleases > b.purchasedReleases }
        // Then the gallery's Title order, which ends on the film id: two films of one name
        // cannot trade places between recalculations.
        return a.titleSort < b.titleSort
    }
}

/// One film behind a Needs Attention count — collected alongside the count itself in
/// the same pass over films, so a row's popover can list exactly the films its own
/// number came from with no second, separately-maintained predicate.
struct DVNamedFilm: Identifiable, Equatable {
    var id: UUID { filmID }
    let filmID: UUID
    let name: String
    /// The film's release year, shown after the name in the popover list.
    var year: Int? = nil
    /// Shown as a trailing "(purchased)" where a list mixes purchased and unpurchased
    /// releases (Recordable Discs, interlaced transfers).
    var purchased = false
    /// The film's place in the gallery's Title sort (see GalleryTitleKey). Precomputed:
    /// lists of these are sorted by it.
    private(set) var titleSort: GalleryTitleKey

    init(filmID: UUID, name: String, sortName: String = "", year: Int? = nil) {
        self.filmID = filmID
        self.name = name
        self.year = year
        self.titleSort = GalleryTitleKey(name: name, sortName: sortName, year: year ?? 0, filmID: filmID)
    }

    init(_ film: FilmSnapshot, purchased: Bool = false) {
        self.init(filmID: film.id, name: film.name, sortName: film.sortName, year: Int(film.releaseYear))
        self.purchased = purchased
    }

    /// True if `lhs` sorts before `rhs` in the gallery's Title order.
    static func compareTitles(_ lhs: DVNamedFilm, _ rhs: DVNamedFilm) -> Bool {
        lhs.titleSort < rhs.titleSort
    }

}

/// The Collection Growth card's two series: films by Date Added and purchased releases
/// (top-level, as everywhere on the tab) by purchase date, as running totals at the end of
/// every month from the first dated one through the current month.
struct DVGrowth: Equatable {
    /// The first month plotted, as `year * 12 + month - 1`.
    let firstMonth: Int
    let films: [Int]
    let purchases: [Int]
    /// Left off the chart for want of a readable date.
    let undatedFilms: Int
    let undatedPurchases: Int

    var isEmpty: Bool { films.isEmpty }

    /// - Parameters: months as `year * 12 + month - 1`. A month past `currentMonth` (a
    ///   typo, a preorder) counts in the current month, so the chart ends today.
    init(filmMonths: [Int], purchaseMonths: [Int], currentMonth: Int, undatedFilms: Int, undatedPurchases: Int) {
        self.undatedFilms = undatedFilms
        self.undatedPurchases = undatedPurchases
        guard let first = [filmMonths.min(), purchaseMonths.min()].compactMap({ $0 }).min() else {
            firstMonth = currentMonth
            films = []
            purchases = []
            return
        }
        let last = max(currentMonth, first)
        func runningTotals(_ months: [Int]) -> [Int] {
            var perMonth = [Int](repeating: 0, count: last - first + 1)
            for m in months { perMonth[min(m, last) - first] += 1 }
            var total = 0
            return perMonth.map { total += $0; return total }
        }
        firstMonth = first
        films = runningTotals(filmMonths)
        purchases = runningTotals(purchaseMonths)
    }

    private init(firstMonth: Int, films: [Int], purchases: [Int], undatedFilms: Int, undatedPurchases: Int) {
        self.firstMonth = firstMonth
        self.films = films
        self.purchases = purchases
        self.undatedFilms = undatedFilms
        self.undatedPurchases = undatedPurchases
    }

    /// The same chart cut to its last `years` years (the Past 5 Years scope): the running
    /// totals keep their all-time values, only the months before the cut are dropped.
    /// Unchanged when the span is already that short.
    func lastYears(_ years: Int) -> DVGrowth {
        let drop = films.count - 1 - years * 12
        guard drop > 0 else { return self }
        return DVGrowth(firstMonth: firstMonth + drop, films: Array(films.dropFirst(drop)),
                        purchases: Array(purchases.dropFirst(drop)),
                        undatedFilms: undatedFilms, undatedPurchases: undatedPurchases)
    }

    /// Each January in the span, by index, for the year labels (the first month's year
    /// when the span holds no January).
    var yearMarks: [(index: Int, year: Int)] {
        let marks = films.indices.compactMap { i in (firstMonth + i) % 12 == 0 ? (index: i, year: (firstMonth + i) / 12) : nil }
        return marks.isEmpty && !films.isEmpty ? [(index: 0, year: firstMonth / 12)] : marks
    }

    static func == (a: DVGrowth, b: DVGrowth) -> Bool {
        a.firstMonth == b.firstMonth && a.films == b.films && a.purchases == b.purchases
            && a.undatedFilms == b.undatedFilms && a.undatedPurchases == b.undatedPurchases
    }
}

/// One calendar year of dated, top-level purchases, for the Spending Trends card.
struct DVSpendingYear: Equatable {
    let year: Int
    var purchases = 0
    /// What was paid: the amount spent where one is entered, else the cost (as Total Spent).
    var spent = 0.0
    /// Entered costs above zero, for the average price (as the Average Cost tile).
    var costSum = 0.0
    var costed = 0
    /// The same figures cut off at today's month and day, so every year can be compared
    /// with this one over the same span.
    var spentByThisDate = 0.0
    var purchasesByThisDate = 0

    var averageCost: Double? { costed > 0 ? costSum / Double(costed) : nil }
}

// MARK: - Formatting Helpers

enum DVFormat {
    static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 2
        return f
    }()

    static let wholeCurrency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()

    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func money(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? Fmt.dollars(value)
    }

    static func wholeMoney(_ value: Double) -> String {
        wholeCurrency.string(from: NSNumber(value: value)) ?? "$\(Fmt.fixed(value, 0))"
    }

    static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1,027h 14m", "71h", "48m".
    static func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(count(h))h" }
        return "\(count(h))h \(m)m"
    }

    /// "1h 56m" style runtime: both units always shown ("2h 0m", "0h 48m").
    static func hoursMinutes(_ minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }

    static func percent(_ numerator: Int, of denominator: Int) -> Int {
        denominator > 0 ? Int((Double(numerator) / Double(denominator) * 100).rounded()) : 0
    }

    static let shortMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f
    }()


    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - Per-film Parsed Viewing Record

/// A film's viewing history parsed once, shared by both statistics types below so the
/// dates are not re-parsed per section.
struct DVFilmViewings: Sendable {
    let filmID: UUID
    let name: String
    let durationMinutes: Int?
    let rating: Int
    let releaseYear: Int?
    /// Whether the film is in color, for the Viewing History month chart's color/B&W
    /// split (see ViewingPeriodStatistics.byMonthColor).
    let isColor: Bool
    /// The film's genre ("" when none is set), for the month chart's Genre bands.
    let genre: String
    /// The entries `dates` and `versions` were parsed from, kept so a later
    /// recalculation can tell whether they are still current (see `init(_:calendar:reusing:)`).
    let calendarTable: [String]
    /// Ascending, in calendar order.
    let dates: [Date]
    let versions: [ViewingVersion]
    var first: Date? { dates.first }
    var last: Date? { dates.last }

    /// Parses the film's viewing history, or — when `previous` is this same film's record
    /// from an earlier recalculation and its history has not changed since — takes the
    /// already-parsed dates from it. Parsing is the recalculation's dominant cost, and a
    /// film event touches one film, so on every recalculation after the first nearly
    /// every record is a copy rather than a parse. The cheap fields are always refreshed
    /// from the snapshot: a rename or a new rating must not be missed just because the
    /// history stood still.
    init(_ film: FilmSnapshot, calendar: Calendar, reusing previous: DVFilmViewings? = nil) {
        filmID = film.id
        name = film.name
        durationMinutes = DurationHelpers.storedMinutes(film.duration)
        rating = film.userRating
        releaseYear = Int(film.releaseYear)
        isColor = film.color
        genre = film.genre
        calendarTable = film.calendarTable
        if let previous, previous.filmID == film.id, previous.calendarTable == film.calendarTable {
            dates = previous.dates
            versions = previous.versions
            return
        }
        var parsed: [(Date, ViewingVersion)] = []
        parsed.reserveCapacity(film.calendarTable.count)
        for entry in film.calendarTable {
            guard let parsedEntry = Self.parse(entry, calendar: calendar) else { continue }
            parsed.append(parsedEntry)
        }
        parsed.sort { $0.0 < $1.0 }
        dates = parsed.map(\.0)
        versions = parsed.map(\.1)
    }

    /// One viewing-history entry as (local midnight, version code), or nil when it holds
    /// no date. The canonical `yyyy.MM.dd` and `yyyy.MM.dd.XX` forms are read directly so
    /// the `startOfDay` the general path needs is skipped too (the fast day IS midnight);
    /// every other spelling goes through the app's general `parseDate(from:)`.
    static func parse(_ entry: String, calendar: Calendar) -> (Date, ViewingVersion)? {
        if entry.utf8.count == 10, let day = canonicalStoredDay(entry[...], separator: ".") {
            return (day, .none)
        }
        // A version code is exactly two ASCII letters or digits after the eleventh
        // character's dot. Anything else in that position (a dot, a non-ASCII character)
        // is left to the general parser, whose dot-splitting rules decide what it means.
        let bytes = Array(entry.utf8)
        if bytes.count == 13, bytes[10] == UInt8(ascii: "."), bytes[11].isASCIIAlphanumeric, bytes[12].isASCIIAlphanumeric,
           let day = canonicalStoredDay(entry.prefix(10), separator: ".") {
            return (day, ViewingVersion(rawValue: String(entry.suffix(2)).uppercased()) ?? .none)
        }
        guard let date = parseDate(from: entry) else { return nil }
        return (calendar.startOfDay(for: date), extractVersionCode(from: entry))
    }
}

private extension UInt8 {
    var isASCIIAlphanumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}

// MARK: - Recalculation Dataset

/// Everything one recalculation of the Data Visualizations tab produces, computed by one
/// function so the synchronous first-visit pass and the background passes that follow it
/// cannot drift apart. `Sendable` because the background pass builds it off the main
/// actor and hands it back.
struct DVDataset: Sendable {
    let stats: LibraryStatistics
    let insights: LibraryInsights
    /// Parsed viewing histories, kept so the year stepper can rebuild the period section
    /// without walking every film's calendar table again, and so the next recalculation
    /// can reuse them (see `DVFilmViewings.init(_:calendar:reusing:)`).
    let viewingRecords: [DVFilmViewings]
    /// Everything the figures above were computed from. Two passes with equal inputs
    /// produce equal figures, which is what lets `compute(films:previous:showInfoComplete:)`
    /// skip a pass (and the page skip re-rendering) when nothing has changed.
    let inputs: Inputs

    struct Inputs: Sendable, Equatable {
        let films: [FilmSnapshot]
        let showInfoComplete: Bool
        /// Read by `FilmSnapshot.rotationThreshold` for every film without an override,
        /// so the rotation figures move with it although no snapshot does.
        let defaultRotationThreshold: Int
        /// The figures are day-granular: "today" only ever enters them as its start of
        /// day, in this calendar.
        let day: Date
        let calendar: Calendar

        init(films: [FilmSnapshot], showInfoComplete: Bool, today: Date, calendar: Calendar) {
            self.films = films
            self.showInfoComplete = showInfoComplete
            defaultRotationThreshold = Preferences.defaultRotationThreshold
            day = calendar.startOfDay(for: today)
            self.calendar = calendar
        }
    }

    init(films: [FilmSnapshot], previousRecords: [DVFilmViewings], showInfoComplete: Bool,
         today: Date = Date(), calendar: Calendar = .current) {
        inputs = Inputs(films: films, showInfoComplete: showInfoComplete, today: today, calendar: calendar)
        let previous = Dictionary(previousRecords.map { ($0.filmID, $0) }, uniquingKeysWith: { first, _ in first })
        let records = films.map { DVFilmViewings($0, calendar: calendar, reusing: previous[$0.id]) }
        stats = LibraryStatistics(films: films, showInfoComplete: showInfoComplete)
        insights = LibraryInsights(films: films, viewings: records, today: today, calendar: calendar)
        viewingRecords = records
    }

    /// The same computation, awaited from the main actor: a nonisolated async function
    /// runs on the global executor, so the caller's actor is free for the duration.
    ///
    /// Returns nil when `previous` was computed from exactly these inputs — the common
    /// case for the reconcile that follows every mount from the cache — so the caller has
    /// nothing to apply and the page is not re-rendered for figures it already shows
    /// (`dataviz-perf` measures such an apply at ≈40 ms of main-thread time). The
    /// comparison runs here, off the main actor, and costs little when nothing has
    /// changed: the snapshot arrays mostly still share storage with the library's.
    nonisolated static func compute(films: [FilmSnapshot], previous: DVDataset?,
                                    showInfoComplete: Bool) async -> DVDataset? {
        let today = Date(), calendar = AppCalendar.current
        if let previous,
           previous.inputs == Inputs(films: films, showInfoComplete: showInfoComplete, today: today, calendar: calendar) {
            return nil
        }
        return DVDataset(films: films, previousRecords: previous?.viewingRecords ?? [],
                         showInfoComplete: showInfoComplete, today: today, calendar: calendar)
    }
}

// MARK: - Library Insights (all-time)

struct LibraryInsights {
    // MARK: Overview
    let totalRuntimeMinutes: Int
    let watchedFilms: Int
    let totalViewings: Int
    let firstViewingYear: Int?
    let unwatchedFilms: Int
    let unwatchedRuntimeMinutes: Int
    /// When the unwatched backlog would be cleared at the trailing-12-month first-time-
    /// watch pace; nil when there is no pace to project from.
    let backlogClearDate: Date?
    let hallOfFameFilms: Int
    let hallOfFameAverageRating: String
    let hallOfFameNotOnDisc: Int
    let hallOfFameUnwatchedOverYear: Int
    let alternateVersionFilms: Int
    let waitingForEdit: Int
    /// Films behind `waitingForEdit`, for the Needs Attention card's popover.
    let waitingForEditItems: [DVNamedFilm]
    /// The metadata field most often left blank, with its blank count.
    let emptiestField: (name: String, blank: Int)?
    /// Films missing at least one of the two external identifier targets (IMDb, Blu-ray.com).
    let missingExternalIdentifiers: Int
    /// Films behind `missingExternalIdentifiers`, for the Needs Attention card's popover.
    let missingExternalIdentifiersItems: [DVNamedFilm]
    let growth: DVGrowth

    // MARK: Rotation
    let rotationEligible: Int
    let overdue: Int
    let overdueItems: [DVNamedFilm]
    let overdueOverSixMonths: Int
    let dueWithin30Days: Int
    let dueWithin90Days: Int
    let onSchedule: Int
    let neverViewed: Int
    let viewedOverOneYearAgo: Int
    /// Every film due for rotation next calendar month, best ranked first
    /// (`DVUpcomingRotation.ranksBefore`).
    let comingUp: [DVUpcomingRotation]
    /// Every film due for rotation next calendar month, for the card's View All popover.
    let comingUpNextMonthItems: [DVNamedFilm]
    let medianGapMonths: Double?
    let medianThreshold: Int?
    let lastGapWithinThresholdPercent: Int?
    let thresholdOverrides: Int
    let autoAddToQueueEnabled: Int
    /// Films behind the Threshold Honesty counts, for each row's popover.
    let thresholdOverrideItems: [DVNamedFilm]
    let autoAddToQueueItems: [DVNamedFilm]
    let viewedOverOneYearAgoItems: [DVNamedFilm]
    let neverViewedItems: [DVNamedFilm]

    // MARK: Attention
    let unpurchasedOutOfPrint: Int
    let unpurchasedOutOfPrintItems: [DVNamedFilm]
    let purchasedNeverWatchedSince: Int
    let purchasedNeverWatchedSinceItems: [DVNamedFilm]
    let dvdOnlyWithUpgradeAvailable: Int
    let dvdOnlyFilms: Int
    let bluRayOnlyWith4KAvailable: Int
    let bluRayOnlyFilms: Int
    let digitalBelowBestDisc: Int
    let digitalBelowBestDiscItems: [DVNamedFilm]

    // MARK: Purchases & spending
    let physicalDiscs: Int
    let comboPacks: Int
    let totalSpent: Double
    let spentThisYear: Double
    let spentPriorYearSameSpan: Double
    let medianCost: Double?
    /// Median cost per format bucket, sampled exactly as LibraryStatistics samples each
    /// bucket's average: the bucket's films' own purchased top-level releases of that format.
    let medianCostByFormat: (fourK: Double?, bluRay: Double?, dvd: Double?)
    let usedShareByYearTrend: [(year: Int, percent: Int)]
    let hdrOnPurchased4K: [DVTally]
    /// HDR tagging across every 4K release entered on any film, purchased or not — the
    /// "All" tab of the 4K UHD and HDR card; `hdrOnPurchased4K` is that card's
    /// "Purchased Only" tab.
    let hdrOnAll4K: [DVTally]
    let busiestYear: (year: Int, count: Int, spent: Double)?
    let busiestMonth: (label: String, count: Int)?
    let averagePurchasesPerMonthTrailing12: Double
    let longestPurchaseGap: (days: Int, year: Int)?
    let paidAboveLowest: (count: Int, over: Double)
    let boughtAtLowest: Int
    let purchaseToFirstViewing: [DVTally]
    let purchaseToFirstViewingMedianDays: Int?
    let costPerViewing: Double?
    /// With the film's release year, shown after its name.
    let bestValue: (name: String, year: Int?, perViewing: Double)?
    let mostExpensiveUnwatchedSincePurchase: (name: String, year: Int?, cost: Double)?
    let spentNeverWatchedSincePurchase: Double
    let spentOnSecondCopies: (amount: Double, films: Int)
    let wishlistItems: Int
    let wishlistEstimatedCost: Double
    let wishlistByFormat: (fourK: Int, bluRay: Int, dvd: Int)
    let wishlistOutOfPrintOrImport: Int
    let wishlistTemporarilyUnavailable: Int
    let wishlistAddedLast90Days: Int
    /// Every year from the first dated purchase through the current one, oldest first,
    /// years without a purchase included.
    let spendingYears: [DVSpendingYear]
    /// The start of the day the figures were computed for, and how much of its year had
    /// passed (0…1), for the Spending Trends card's same-span comparison and projection.
    let spendingAsOf: Date
    let yearElapsedFraction: Double
    /// Films whose best purchased disc is a Blu-ray or DVD; of those, the ones with an
    /// unpurchased 4K release entered, and the ones with such a release entered in the
    /// last 90 days (with the cheapest entered cost of each, summed).
    let ownedBelowFourK: Int
    let ownedBelowFourKWithFourKEntered: Int
    let newFourKForOwnedBelowFourK: Int
    let newFourKForOwnedBelowFourKCost: Double

    // MARK: Collection structure
    let multiFormatFilms: Int
    let multiCopyReleases: Int
    let remasteredReleases: Int
    let ownedOutOfPrint: Int
    let steelbooks: Int
    let studios: [DVTally]
    let origins: [DVTally]
    /// Same breakdown as `studios`/`origins`, but over every top-level release regardless
    /// of purchase status — the Studios and Labels / Regions cards' "All" tab.
    /// `studios`/`origins` remain that pair's "Purchased Only" tab, unchanged.
    let studiosAll: [DVTally]
    let originsAll: [DVTally]
    /// Blu-ray-only region-lock breakdown — region free, A, B, B (loosely-locked), and
    /// Unknown (blank or unmapped) — for the Regions card's "Blu-ray region locks" bar.
    let blurayRegionLocks: [DVTally]
    let blurayRegionLocksAll: [DVTally]

    // MARK: Decades, runtime & picture
    let oldestYear: Int?
    let newestYear: Int?
    let bestRatedDecade: (label: String, average: Double)?
    /// Every decade with at least `minimumRatedFilmsPerDecade` rated films, best average first
    /// (ties: the earlier decade), with the number of rated films behind each average.
    let decadesByRating: [(label: String, average: Double, rated: Int)]
    static let minimumRatedFilmsPerDecade = 3
    /// The minimum spelled out for prose ("three"); US English pinned, as the sentence around it is.
    static let minimumRatedFilmsPerDecadeWords: String = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: minimumRatedFilmsPerDecade)) ?? "\(minimumRatedFilmsPerDecade)"
    }()
    let runtimeBuckets: [DVTally]
    let averageRuntimeMinutes: Int?
    let longestFilm: (name: String, minutes: Int)?
    let editedTrimmedMinutes: Int
    let frameRates: [DVTally]

    // MARK: People & genres
    let directors: [DVRank]
    let cast: [DVRank]
    let composers: [DVRank]
    let screenwriters: [DVRank]
    let genres: [DVRank]
    let contentRatings: [DVTally]
    let tags: [DVTally]

    // MARK: Technical
    let filmsOnBDOr4K: Int
    let videoCodecs: [DVTally]
    /// Same breakdown as `videoCodecs`, over every release rather than purchased ones
    /// only — the Subtitles and Encoding card's "All" tab.
    let videoCodecsAll: [DVTally]
    /// Releases (every disc, purchased or not) with an interlaced transfer, and the films
    /// they belong to — the Needs Attention card's row and its popover.
    let interlacedAll: Int
    let interlacedAllItems: [DVNamedFilm]
    /// Recordable (BD-R / DVD-R) releases: every one, the purchased ones, and the films
    /// they belong to ("(purchased)" appended where one is purchased) — the Recordable
    /// Discs tile and its popover.
    let recordable: Int
    let recordableAll: Int
    let recordableAllItems: [DVNamedFilm]
    let handbrakeRF: [DVTally]
    /// Same breakdown as `handbrakeRF`, but over every film with an RF value regardless
    /// of purchase status — the Subtitles and Encoding card's "All" tab.
    let handbrakeRFAll: [DVTally]
    /// Strictly `FilmSubtitles.yes` — not "On-disc only" or "Digital rip only", which are
    /// their own rows in the Subtitles bar. Purchased-only: at least one purchased disc.
    let subtitlesYes: Int
    let subtitlesOnDiscOnly: Int
    let subtitlesDigitalRipOnly: Int
    /// Same three rows and the same "purchased" gate as `subtitlesYes`/
    /// `subtitlesOnDiscOnly`/`subtitlesDigitalRipOnly`, but over every film regardless of
    /// purchase status — the Subtitles and Encoding card's "All" tab.
    let subtitlesYesAll: Int
    let subtitlesOnDiscOnlyAll: Int
    let subtitlesDigitalRipOnlyAll: Int
    /// Denominator for the purchased-only Subtitles bar: films with at least one
    /// purchased disc release. The "All" tab's denominator is `totalFilms`.
    let subtitlesPurchasedFilmCount: Int

    // MARK: All-time viewing
    let mostRewatchedAllTime: [DVRank]
    let rewatchesByRatingBand: [DVTally]
    /// Average viewings per calendar month across every recorded year, Jan…Dec, ×100.
    let seasonality: [Double]
    let seasonalityLeader: String?
    let viewingYears: [Int]
    /// Collector habits over the whole library: discovery against revisiting, film age
    /// at viewing, purchases by calendar month, price and format by rating, 4K upgrades by
    /// rating, and ownership by release decade.
    let habits: DVHabits

    // MARK: - Init

    /// - Parameter viewings: The films' parsed viewing histories, one per film, when the
    ///   caller already has them (the tab keeps them for the period section); parsed here
    ///   otherwise. Parsing is the expensive half of this initializer, and the tab used to
    ///   pay it twice per recalculation — once here and once for its own copy.
    init(films: [FilmSnapshot], viewings: [DVFilmViewings]? = nil, today: Date = Date(), calendar: Calendar = .current) {
        let currentYear = calendar.component(.year, from: today)
        let todayStart = calendar.startOfDay(for: today)
        let viewings = viewings ?? films.map { DVFilmViewings($0, calendar: calendar) }
        let viewingsByID = Dictionary(uniqueKeysWithValues: viewings.map { ($0.filmID, $0) })

        // MARK: Overview
        var runtimeTotal = 0, unwatchedRuntime = 0, unwatched = 0, watched = 0
        var viewingCount = 0
        var firstYear: Int?
        var hof = 0, hofRatingSum = 0, hofRated = 0, hofNotOnDisc = 0, hofStale = 0
        var altVersions = 0, waitingForEdit = 0, missingExtIDs = 0
        var waitingForEditItems: [DVNamedFilm] = []
        var missingExtIDsItems: [DVNamedFilm] = []
        var blanks: [String: Int] = [:]
        var addedMonths: [Int] = []
        var undatedFilms = 0
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: todayStart) ?? todayStart

        for film in films {
            let minutes = DurationHelpers.storedMinutes(film.duration) ?? 0
            runtimeTotal += minutes
            if film.watched { watched += 1 } else { unwatched += 1; unwatchedRuntime += minutes }
            let v = viewingsByID[film.id]!
            viewingCount += v.dates.count
            if let first = v.first {
                let y = calendar.component(.year, from: first)
                firstYear = min(firstYear ?? y, y)
            }
            if film.hofPosition > 0 {
                hof += 1
                if film.userRating > 0 { hofRatingSum += film.userRating; hofRated += 1 }
                if !film.releases.contains(where: { $0.purchased }) { hofNotOnDisc += 1 }
                if let last = v.last, last < oneYearAgo { hofStale += 1 }
            }
            if SmartLists.hasAlternateVersions(film) { altVersions += 1 }
            if film.specialSorting.contains(FilmSpecialSorting.waitingForEdit) {
                waitingForEdit += 1
                waitingForEditItems.append(DVNamedFilm(film))
            }
            let hasIMDb = QueryTarget.imdb.identifierIndex < film.externalIdentifiers.count
                && !film.externalIdentifiers[QueryTarget.imdb.identifierIndex].trimmingCharacters(in: .whitespaces).isEmpty
            let hasBluRay = QueryTarget.bluray.identifierIndex < film.externalIdentifiers.count
                && !film.externalIdentifiers[QueryTarget.bluray.identifierIndex].trimmingCharacters(in: .whitespaces).isEmpty
            if !hasIMDb || !hasBluRay {
                missingExtIDs += 1
                missingExtIDsItems.append(DVNamedFilm(film))
            }
            if film.genre.isEmpty { blanks["Genre", default: 0] += 1 }
            if film.rating.isEmpty { blanks["Content rating", default: 0] += 1 }
            if film.studio.isEmpty { blanks["Studio", default: 0] += 1 }
            if film.cast.isEmpty { blanks["Cast", default: 0] += 1 }
            if film.directors.isEmpty { blanks["Directors", default: 0] += 1 }
            if film.producers.isEmpty { blanks["Producers", default: 0] += 1 }
            if film.screenwriters.isEmpty { blanks["Screenwriters", default: 0] += 1 }
            if film.composer.isEmpty { blanks["Composer", default: 0] += 1 }
            if film.descriptionText.isEmpty { blanks["Synopsis", default: 0] += 1 }
            if film.aspectRatio.isEmpty { blanks["Aspect ratio", default: 0] += 1 }
            if film.duration.isEmpty { blanks["Duration", default: 0] += 1 }
            if let month = Self.addedMonth(film.dateAdded, calendar: calendar) { addedMonths.append(month) } else { undatedFilms += 1 }
        }
        totalRuntimeMinutes = runtimeTotal
        watchedFilms = watched
        totalViewings = viewingCount
        firstViewingYear = firstYear
        unwatchedFilms = unwatched
        unwatchedRuntimeMinutes = unwatchedRuntime
        hallOfFameFilms = hof
        hallOfFameAverageRating = hofRated > 0 ? Fmt.fixed(Double(hofRatingSum) / Double(hofRated), 1) : "—"
        hallOfFameNotOnDisc = hofNotOnDisc
        hallOfFameUnwatchedOverYear = hofStale
        alternateVersionFilms = altVersions
        self.waitingForEdit = waitingForEdit
        self.waitingForEditItems = waitingForEditItems
        missingExternalIdentifiers = missingExtIDs
        missingExternalIdentifiersItems = missingExtIDsItems
        emptiestField = blanks.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
            .map { (name: $0.key, blank: $0.value) }

        // First-time watches in the trailing 12 months → pace → backlog projection.
        var firstTimeTrailing = 0
        for v in viewings {
            if let first = v.first, first > oneYearAgo, first <= todayStart { firstTimeTrailing += 1 }
        }
        if firstTimeTrailing > 0, unwatched > 0 {
            let months = Double(unwatched) / (Double(firstTimeTrailing) / 12.0)
            backlogClearDate = calendar.date(byAdding: .day, value: Int((months * 30.44).rounded()), to: todayStart)
        } else {
            backlogClearDate = nil
        }

        // MARK: Rotation
        var eligible = 0, overdue = 0, overdue6 = 0, due30 = 0, due90 = 0, onSchedule = 0
        var never = 0, staleYear = 0, overrides = 0, autoAdd = 0
        var overdueItems: [DVNamedFilm] = []
        var overrideItems: [DVNamedFilm] = [], autoAddItems: [DVNamedFilm] = []
        var staleYearItems: [DVNamedFilm] = [], neverItems: [DVNamedFilm] = []
        var upcoming: [DVUpcomingRotation] = []
        var nextMonthItems: [DVNamedFilm] = []
        var gaps: [Double] = []
        var thresholds: [Double] = []
        var lastGapWithin = 0, lastGapMeasured = 0
        let in30 = calendar.date(byAdding: .day, value: 30, to: todayStart) ?? todayStart
        let in90 = calendar.date(byAdding: .day, value: 90, to: todayStart) ?? todayStart
        let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: todayStart) ?? todayStart
        let monthStart = calendar.dateInterval(of: .month, for: todayStart)?.start ?? todayStart
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? todayStart
        let nextMonthEnd = calendar.date(byAdding: .month, value: 2, to: monthStart) ?? todayStart

        for film in films {
            if film.rotationThresholdOverride != nil { overrides += 1; overrideItems.append(DVNamedFilm(film)) }
            if film.autoAddToQueueOnRotation != nil { autoAdd += 1; autoAddItems.append(DVNamedFilm(film)) }
            guard let lastWatched = parseDate(from: film.lastWatched) else { never += 1; neverItems.append(DVNamedFilm(film)); continue }
            if let yearLater = rotationEligibilityDate(from: lastWatched, months: 12, calendar: calendar),
               yearLater <= todayStart {
                staleYear += 1
                staleYearItems.append(DVNamedFilm(film))
            }
            guard film.specialSorting.isEmpty else { continue }
            eligible += 1
            thresholds.append(Double(film.rotationThreshold))
            guard let due = rotationEligibilityDate(from: lastWatched, months: film.rotationThreshold, calendar: calendar)
            else { continue }
            if due <= todayStart {
                overdue += 1
                overdueItems.append(DVNamedFilm(film))
                if due <= sixMonthsAgo { overdue6 += 1 }
            } else if due <= in30 {
                due30 += 1
            } else if due <= in90 {
                due90 += 1
            } else {
                onSchedule += 1
            }
            let v = viewingsByID[film.id]!
            if due >= nextMonthStart, due < nextMonthEnd {
                upcoming.append(DVUpcomingRotation(filmID: film.id, name: film.name, sortName: film.sortName,
                                                   year: Int(film.releaseYear), rating: film.userRating,
                                                   viewings: v.dates.count,
                                                   purchasedReleases: film.releases.filter { $0.purchased && $0.isTopLevel }.count))
                nextMonthItems.append(DVNamedFilm(film))
            }
            if v.dates.count >= 2 {
                let days = calendar.dateComponents([.day], from: v.dates[v.dates.count - 2], to: v.dates[v.dates.count - 1]).day ?? 0
                gaps.append(Double(days) / 30.44)
                lastGapMeasured += 1
                if Double(days) <= Double(film.rotationThreshold) * 30.44 { lastGapWithin += 1 }
            }
        }
        rotationEligible = eligible
        self.overdue = overdue
        self.overdueItems = overdueItems
        overdueOverSixMonths = overdue6
        dueWithin30Days = due30
        dueWithin90Days = due90
        self.onSchedule = onSchedule
        neverViewed = never
        viewedOverOneYearAgo = staleYear
        comingUp = upcoming.sorted(by: DVUpcomingRotation.ranksBefore)
        comingUpNextMonthItems = nextMonthItems
        medianGapMonths = DVFormat.median(gaps)
        medianThreshold = DVFormat.median(thresholds).map { Int($0.rounded()) }
        lastGapWithinThresholdPercent = lastGapMeasured > 0 ? DVFormat.percent(lastGapWithin, of: lastGapMeasured) : nil
        thresholdOverrides = overrides
        autoAddToQueueEnabled = autoAdd
        thresholdOverrideItems = overrideItems
        autoAddToQueueItems = autoAddItems
        viewedOverOneYearAgoItems = staleYearItems
        neverViewedItems = neverItems

        // MARK: Attention + purchases + structure (one pass over films and releases)
        var unpurchasedOOP = 0, neverWatchedSince = 0, dvdOnly = 0, dvdUpgrade = 0
        var unpurchasedOOPItems: [DVNamedFilm] = []
        var neverWatchedSinceItems: [DVNamedFilm] = []
        var interlacedItems: [DVNamedFilm] = []
        var recordableItems: [DVNamedFilm] = []
        var digitalBelowItems: [DVNamedFilm] = []
        var bdOnly = 0, bdUpgrade = 0, digitalBelow = 0
        var belowFourK = 0, belowFourKWith4K = 0, newFourK = 0, newFourKCost = 0.0
        var spendingByYear: [Int: DVSpendingYear] = [:]
        var discs = 0, combos = 0, spent = 0.0, spentYear = 0.0, spentPriorSpan = 0.0
        var costs: [Double] = []
        var bucketCosts: (fourK: [Double], bluRay: [Double], dvd: [Double]) = ([], [], [])
        var costByYear: [Int: (used: Int, total: Int, spent: Double)] = [:]
        var hdr: [String: Int] = [:]
        var hdrAll: [String: Int] = [:]
        var purchased4K = 0
        var all4K = 0
        var purchasesByMonth: [String: Int] = [:]
        var purchaseDates: [Date] = []
        var aboveLowest = 0, overpay = 0.0, atLowest = 0
        var p2vBuckets = [0, 0, 0, 0, 0, 0]
        var p2vDays: [Double] = []
        var viewingsSincePurchase = 0, costedForValue = 0.0
        var bestValue: (String, Double)?
        var bestValueYear: Int?, mostExpensiveUnwatchedYear: Int?
        var mostExpensiveUnwatched: (String, Double)?
        var spentUnwatched = 0.0, secondCopySpend = 0.0, multiFormat = 0, multiCopy = 0
        var remastered = 0, ownedOOP = 0, steelbooks = 0
        var studioCounts: [String: Int] = [:]
        var originCounts: [String: Int] = [:]
        var studioCountsAll: [String: Int] = [:]
        var originCountsAll: [String: Int] = [:]
        var topLevelCountAll = 0
        var bdFree = 0, bdA = 0, bdB = 0, bdBLoose = 0, bdUnknown = 0
        var bdFreeAll = 0, bdAAll = 0, bdBAll = 0, bdBLooseAll = 0, bdUnknownAll = 0
        // Blu-ray-only region-lock bucket, shared by the "All" and "Purchased Only" tallies
        // below so the two cannot classify a tag differently.
        func bdRegionBucket(_ tag: String) -> Int {
            if tag == ReleaseRegionRules.regionFree { return 0 }
            if tag == ReleaseRegionRules.regionA { return 1 }
            if tag == ReleaseRegionRules.looselyLockedTag { return 2 }
            if ReleaseRegionRules.regionBTags.contains(tag) { return 3 }
            return 4 // Unknown: blank or unmapped.
        }
        var wishItems = 0, wishCost = 0.0, wish4K = 0, wishBD = 0, wishDVD = 0
        var wishOOP = 0, wishTemp = 0, wishRecent = 0
        var onBD = 0
        var codecs: [String: Int] = [:]
        var recordable = 0, purchasedCount = 0
        var interlacedAll = 0, recordableAll = 0
        var codecsAll: [String: Int] = [:]
        var subsYes = 0, subsDisc = 0, subsRip = 0
        var subsYesAll = 0, subsDiscAll = 0, subsRipAll = 0
        var purchasedFilmCount = 0
        var years: [Int] = []
        var decadeRatings: [Int: (sum: Int, n: Int)] = [:]
        var runtime = [0, 0, 0, 0, 0, 0]
        var runtimeSum = 0, runtimeN = 0
        var longest: (String, Int)?
        var trimmed = 0
        var frameRates: [String: Int] = [:]
        var rf: [String: Int] = [:]
        var rfAll: [String: Int] = [:]
        var genreStats: [String: (n: Int, ratingSum: Int, rated: Int)] = [:]
        var contentRatings: [String: Int] = [:]
        var tagCounts: [String: Int] = [:]
        var directorStats: [String: (n: Int, ratingSum: Int, rated: Int, views: Int)] = [:]
        var castStats = directorStats, composerStats = directorStats, writerStats = directorStats

        let ninetyDaysAgo = calendar.date(byAdding: .day, value: -90, to: todayStart) ?? todayStart
        let yearStart = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1)) ?? todayStart
        let priorYearStart = calendar.date(from: DateComponents(year: currentYear - 1, month: 1, day: 1)) ?? todayStart
        let priorYearCutoff = calendar.date(byAdding: .year, value: -1, to: todayStart) ?? todayStart
        let todayParts = calendar.dateComponents([.month, .day], from: todayStart)
        let todayMonthDay = (todayParts.month ?? 1, todayParts.day ?? 1)

        for film in films {
            let v = viewingsByID[film.id]!
            let purchasedReleases = film.releases.filter { $0.purchased }
            let hasPurchased = !purchasedReleases.isEmpty
            let has4K = film.releases.contains { $0.format == ReleaseFormat.uhd4K.rawValue }
            let hasBD = film.releases.contains { $0.format == ReleaseFormat.bluRay.rawValue }
            let purchased4KHere = purchasedReleases.contains { $0.format == ReleaseFormat.uhd4K.rawValue }
            let purchasedBDHere = purchasedReleases.contains { $0.format == ReleaseFormat.bluRay.rawValue }
            let purchasedDVDHere = purchasedReleases.contains { $0.format == ReleaseFormat.dvd.rawValue }

            if !hasPurchased, film.releases.contains(where: { ReleaseMarketAvailability.isUnobtainable($0.marketAvailability) }) {
                unpurchasedOOP += 1
                unpurchasedOOPItems.append(DVNamedFilm(film))
            }
            if !purchased4KHere, !purchasedBDHere, purchasedDVDHere {
                dvdOnly += 1
                if has4K || hasBD {
                    dvdUpgrade += 1
                }
            }
            if !purchased4KHere, purchasedBDHere {
                bdOnly += 1
                if has4K { bdUpgrade += 1 }
            }
            if !purchased4KHere, purchasedBDHere || purchasedDVDHere {
                belowFourK += 1
                let unbought4K = film.releases.filter { !$0.purchased && $0.isTopLevel && $0.format == ReleaseFormat.uhd4K.rawValue }
                if !unbought4K.isEmpty {
                    belowFourKWith4K += 1
                    if unbought4K.contains(where: { $0.dateAdded >= ninetyDaysAgo }) {
                        newFourK += 1
                        newFourKCost += unbought4K.filter { $0.cost > 0 }.map(\.cost).min() ?? 0
                    }
                }
            }
            // The same three-way film bucketing as LibraryStatistics.formatBreakdown, so
            // the medians sit beside averages drawn from the same samples.
            let bucketFormat: ReleaseFormat? = purchased4KHere ? .uhd4K : (purchasedBDHere ? .bluRay : (purchasedDVDHere ? .dvd : nil))
            if let bucketFormat {
                for r in purchasedReleases where r.isTopLevel && r.format == bucketFormat.rawValue && r.cost > 0 {
                    switch bucketFormat {
                    case .uhd4K: bucketCosts.fourK.append(r.cost)
                    case .bluRay: bucketCosts.bluRay.append(r.cost)
                    case .dvd: bucketCosts.dvd.append(r.cost)
                    }
                }
            }
            if Self.digitalSourceBelowBestDisc(film, purchased4K: purchased4KHere,
                                               purchasedBD: purchasedBDHere, purchasedDVD: purchasedDVDHere) {
                digitalBelow += 1
                digitalBelowItems.append(DVNamedFilm(film))
            }
            if has4K || hasBD { onBD += 1 }
            let interlacedHere = film.releases.filter { $0.scanningMethod == ReleaseScanningMethod.interlaced }
            if !interlacedHere.isEmpty {
                interlacedItems.append(DVNamedFilm(film, purchased: interlacedHere.contains { $0.purchased }))
            }
            let recordableHere = film.releases.filter { $0.replicationType == ReleaseReplicationType.recordable }
            if !recordableHere.isEmpty {
                recordableItems.append(DVNamedFilm(film, purchased: recordableHere.contains { $0.purchased }))
            }

            // Ownership in more than one format, and the money on the extra copies.
            let purchasedFormats = Set(purchasedReleases.filter(\.isTopLevel).map(\.format))
            if purchasedFormats.count > 1 {
                multiFormat += 1
                // Cheapest-format copies count as "second": everything except the best format.
                let best = purchasedReleases.filter(\.isTopLevel)
                    .min { ReleaseFormat.displayRank(for: $0.format) < ReleaseFormat.displayRank(for: $1.format) }
                for r in purchasedReleases where r.isTopLevel && r.id != best?.id { secondCopySpend += r.amountSpent > 0 ? r.amountSpent : r.cost }
            }

            var filmNeverWatchedSince = false
            for r in film.releases {
                // Top-level only, as the Release Wishlist report lists them: a combo child
                // mirrors its parent's wishlist position and cost, so counting it would show
                // the pack twice here and once on the report this card opens.
                if r.wishlist > 0, r.isTopLevel {
                    wishItems += 1
                    wishCost += r.cost
                    switch r.format {
                    case ReleaseFormat.uhd4K.rawValue: wish4K += 1
                    case ReleaseFormat.bluRay.rawValue: wishBD += 1
                    case ReleaseFormat.dvd.rawValue: wishDVD += 1
                    default: break
                    }
                    if ReleaseMarketAvailability.isUnobtainable(r.marketAvailability)
                        || ReleaseMarketAvailability.isImport(r.marketAvailability) { wishOOP += 1 }
                    if ReleaseMarketAvailability.status(r.marketAvailability)
                        == ReleaseMarketAvailability.temporarilyUnavailable { wishTemp += 1 }
                    if r.dateAdded >= ninetyDaysAgo { wishRecent += 1 }
                }
                if r.format == ReleaseFormat.uhd4K.rawValue {
                    all4K += 1
                    hdrAll[r.hasHDR.isEmpty ? ReleaseHDR.noneTag : r.hasHDR, default: 0] += 1
                }
                if !r.videoFormat.isEmpty { codecsAll[r.videoFormat, default: 0] += 1 }
                if r.scanningMethod == ReleaseScanningMethod.interlaced { interlacedAll += 1 }
                if r.replicationType == ReleaseReplicationType.recordable { recordableAll += 1 }
                if r.format == ReleaseFormat.bluRay.rawValue {
                    switch bdRegionBucket(r.regionLock) {
                    case 0: bdFreeAll += 1
                    case 1: bdAAll += 1
                    case 2: bdBLooseAll += 1
                    case 3: bdBAll += 1
                    default: bdUnknownAll += 1
                    }
                }
                if r.isTopLevel {
                    topLevelCountAll += 1
                    if !r.studio.isEmpty { studioCountsAll[r.studio, default: 0] += 1 }
                    if !r.nationalOrigin.isEmpty { originCountsAll[r.nationalOrigin, default: 0] += 1 }
                }
                guard r.purchased else { continue }
                // Disc-level tallies count every purchased disc, combo children included.
                if r.format == ReleaseFormat.uhd4K.rawValue {
                    purchased4K += 1
                    hdr[r.hasHDR.isEmpty ? ReleaseHDR.noneTag : r.hasHDR, default: 0] += 1
                }
                if !r.videoFormat.isEmpty { codecs[r.videoFormat, default: 0] += 1 }
                if r.replicationType == ReleaseReplicationType.recordable { recordable += 1 }
                if r.remastered { remastered += 1 }
                if r.format == ReleaseFormat.bluRay.rawValue {
                    switch bdRegionBucket(r.regionLock) {
                    case 0: bdFree += 1
                    case 1: bdA += 1
                    case 2: bdBLoose += 1
                    case 3: bdB += 1
                    default: bdUnknown += 1
                    }
                }
                guard r.isTopLevel else { continue }
                // Package-level tallies: one per acquisition.
                purchasedCount += 1
                discs += max(r.numberOfDiscs, 1) * max(r.numberOfCopies, 1)
                if ReleaseIndependence.isComboPack(r.independence) { combos += 1 }
                if r.numberOfCopies > 1 { multiCopy += 1 }
                if ReleaseMarketAvailability.isUnobtainable(r.marketAvailability) { ownedOOP += 1 }
                if r.notes.lowercased().contains("steelbook") || r.hasArtwork == ReleaseArtwork.steelbook { steelbooks += 1 }
                if !r.studio.isEmpty { studioCounts[r.studio, default: 0] += 1 }
                if !r.nationalOrigin.isEmpty { originCounts[r.nationalOrigin, default: 0] += 1 }

                let paid = r.amountSpent > 0 ? r.amountSpent : r.cost
                spent += paid
                if r.cost > 0 { costs.append(r.cost) }
                if r.lowestPrice > 0, r.cost > 0 {
                    if r.cost > r.lowestPrice + 0.005 { aboveLowest += 1; overpay += r.cost - r.lowestPrice }
                    else { atLowest += 1 }
                }
                let purchaseDate = LibraryStatistics.purchaseDay(r.purchaseDate, calendar: calendar)
                if let d = purchaseDate {
                    purchaseDates.append(d)
                    let parts = calendar.dateComponents([.year, .month, .day], from: d)
                    let y = parts.year ?? currentYear
                    var spending = spendingByYear[y] ?? DVSpendingYear(year: y)
                    spending.purchases += 1
                    spending.spent += paid
                    if r.cost > 0 { spending.costSum += r.cost; spending.costed += 1 }
                    if (parts.month ?? 1, parts.day ?? 1) <= todayMonthDay {
                        spending.spentByThisDate += paid
                        spending.purchasesByThisDate += 1
                    }
                    spendingByYear[y] = spending
                    var row = costByYear[y] ?? (0, 0, 0)
                    if r.condition.lowercased() == ReleaseCondition.used.lowercased() { row.used += 1 }
                    row.total += 1
                    row.spent += paid
                    costByYear[y] = row
                    purchasesByMonth[DVFormat.monthYear.string(from: d), default: 0] += 1
                    if d >= yearStart { spentYear += paid }
                    if d >= priorYearStart, d <= priorYearCutoff { spentPriorSpan += paid }

                    // Purchase → first viewing on or after the purchase.
                    let viewsSince = v.dates.filter { $0 >= d }
                    if let firstSince = viewsSince.first {
                        let days = calendar.dateComponents([.day], from: d, to: firstSince).day ?? 0
                        p2vDays.append(Double(days))
                        switch days {
                        case ..<30: p2vBuckets[0] += 1
                        case 30...90: p2vBuckets[1] += 1
                        case 91...180: p2vBuckets[2] += 1
                        case 181...365: p2vBuckets[3] += 1
                        default: p2vBuckets[4] += 1
                        }
                    } else {
                        p2vBuckets[5] += 1
                        filmNeverWatchedSince = true
                        spentUnwatched += paid
                        if Self.prefer(paid, film.name, over: mostExpensiveUnwatched) {
                            mostExpensiveUnwatched = (film.name, paid)
                            mostExpensiveUnwatchedYear = Int(film.releaseYear)
                        }
                    }
                    if paid > 0 {
                        viewingsSincePurchase += viewsSince.count
                        costedForValue += paid
                        if !viewsSince.isEmpty {
                            let per = paid / Double(viewsSince.count)
                            if Self.prefer(-per, film.name, over: bestValue.map { ($0.0, -$0.1) }) {
                                bestValue = (film.name, per)
                                bestValueYear = Int(film.releaseYear)
                            }
                        }
                    }
                }
            }
            if filmNeverWatchedSince {
                neverWatchedSince += 1
                neverWatchedSinceItems.append(DVNamedFilm(film))
            }

            // Library metadata.
            if hasPurchased { purchasedFilmCount += 1 }
            if FilmSubtitles.matches(film.subtitles, FilmSubtitles.yes) {
                subsYesAll += 1
                if hasPurchased { subsYes += 1 }
            }
            if FilmSubtitles.matches(film.subtitles, FilmSubtitles.onDiscOnly) {
                subsDiscAll += 1
                if hasPurchased { subsDisc += 1 }
            }
            if FilmSubtitles.matches(film.subtitles, FilmSubtitles.digitalRipOnly) {
                subsRipAll += 1
                if hasPurchased { subsRip += 1 }
            }
            if let y = Int(film.releaseYear), y >= 1888 {
                years.append(y)
                if film.userRating > 0 {
                    var d = decadeRatings[(y / 10) * 10] ?? (0, 0)
                    d.sum += film.userRating; d.n += 1
                    decadeRatings[(y / 10) * 10] = d
                }
            }
            if let minutes = DurationHelpers.storedMinutes(film.duration) {
                runtimeSum += minutes; runtimeN += 1
                switch minutes {
                case ..<90: runtime[0] += 1
                case 90..<105: runtime[1] += 1
                case 105..<120: runtime[2] += 1
                case 120..<150: runtime[3] += 1
                case 150..<180: runtime[4] += 1
                default: runtime[5] += 1
                }
                if Self.prefer(Double(minutes), film.name, over: longest.map { ($0.0, Double($0.1)) }) { longest = (film.name, minutes) }
                if film.edited, let edited = DurationHelpers.storedMinutes(film.editedDuration), edited < minutes {
                    trimmed += minutes - edited
                }
            }
            if film.frameRate > 0 {
                // Always three decimal places, whole rates included ("24.000"), so the
                // legend reads as one consistent column of figures.
                let label = Fmt.fixed(film.frameRate, 3)
                frameRates[label, default: 0] += 1
            }
            if film.libraryHBRFValue > 0 {
                let band: String
                switch film.libraryHBRFValue {
                case ..<19: band = "≤18"
                case 19...22: band = "19–22"
                default: band = "23+"
                }
                rfAll[band, default: 0] += 1
                if hasPurchased { rf[band, default: 0] += 1 }
            }
            if !film.genre.isEmpty {
                var g = genreStats[film.genre] ?? (0, 0, 0)
                g.n += 1
                if film.userRating > 0 { g.ratingSum += film.userRating; g.rated += 1 }
                genreStats[film.genre] = g
            }
            if !film.rating.isEmpty { contentRatings[film.rating, default: 0] += 1 }
            for tag in film.tags where !tag.isEmpty { tagCounts[tag, default: 0] += 1 }
            func tally(_ names: [String], into stats: inout [String: (n: Int, ratingSum: Int, rated: Int, views: Int)]) {
                for name in names where !name.isEmpty {
                    var s = stats[name] ?? (0, 0, 0, 0)
                    s.n += 1
                    if film.userRating > 0 { s.ratingSum += film.userRating; s.rated += 1 }
                    s.views += v.dates.count
                    stats[name] = s
                }
            }
            tally(film.directors, into: &directorStats)
            tally(film.cast, into: &castStats)
            tally(film.composer, into: &composerStats)
            tally(film.screenwriters, into: &writerStats)
        }

        unpurchasedOutOfPrint = unpurchasedOOP
        unpurchasedOutOfPrintItems = unpurchasedOOPItems
        purchasedNeverWatchedSince = neverWatchedSince
        purchasedNeverWatchedSinceItems = neverWatchedSinceItems
        dvdOnlyWithUpgradeAvailable = dvdUpgrade
        interlacedAllItems = interlacedItems
        recordableAllItems = recordableItems
        dvdOnlyFilms = dvdOnly
        bluRayOnlyWith4KAvailable = bdUpgrade
        bluRayOnlyFilms = bdOnly
        digitalBelowBestDisc = digitalBelow
        digitalBelowBestDiscItems = digitalBelowItems

        physicalDiscs = discs
        comboPacks = combos
        totalSpent = spent
        spentThisYear = spentYear
        spentPriorYearSameSpan = spentPriorSpan
        medianCost = DVFormat.median(costs)
        medianCostByFormat = (DVFormat.median(bucketCosts.fourK), DVFormat.median(bucketCosts.bluRay), DVFormat.median(bucketCosts.dvd))
        usedShareByYearTrend = costByYear.keys.sorted().suffix(3).compactMap { y in
            guard let row = costByYear[y], row.total > 0 else { return nil }
            return (year: y, percent: DVFormat.percent(row.used, of: row.total))
        }
        hdrOnPurchased4K = [ReleaseHDR.dolbyVision, ReleaseHDR.hdr10Plus, ReleaseHDR.hdr10, ReleaseHDR.noneTag]
            .map { DVTally($0, hdr[$0] ?? 0, of: purchased4K) }
        hdrOnAll4K = [ReleaseHDR.dolbyVision, ReleaseHDR.hdr10Plus, ReleaseHDR.hdr10, ReleaseHDR.noneTag]
            .map { DVTally($0, hdrAll[$0] ?? 0, of: all4K) }
        busiestYear = costByYear.max { a, b in a.value.total != b.value.total ? a.value.total < b.value.total : a.key < b.key }
            .map { (year: $0.key, count: $0.value.total, spent: $0.value.spent) }
        busiestMonth = purchasesByMonth.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }
            .map { (label: $0.key, count: $0.value) }
        let trailing = purchaseDates.filter { $0 > priorYearCutoff && $0 <= todayStart }.count
        averagePurchasesPerMonthTrailing12 = Double(trailing) / 12.0
        var longestGap: (Int, Int)?
        let sortedPurchases = purchaseDates.sorted()
        if sortedPurchases.count >= 2 {
            for i in 1..<sortedPurchases.count {
                let days = calendar.dateComponents([.day], from: sortedPurchases[i - 1], to: sortedPurchases[i]).day ?? 0
                if days > (longestGap?.0 ?? -1) {
                    longestGap = (days, calendar.component(.year, from: sortedPurchases[i]))
                }
            }
        }
        longestPurchaseGap = longestGap.map { (days: $0.0, year: $0.1) }
        paidAboveLowest = (aboveLowest, overpay)
        boughtAtLowest = atLowest
        let p2vTotal = p2vBuckets.reduce(0, +)
        purchaseToFirstViewing = zip(["<30 d", "30–90", "91–180", "181–365", "366+", "Never"], p2vBuckets)
            .map { DVTally($0.0, $0.1, of: p2vTotal) }
        purchaseToFirstViewingMedianDays = DVFormat.median(p2vDays).map { Int($0.rounded()) }
        costPerViewing = viewingsSincePurchase > 0 ? costedForValue / Double(viewingsSincePurchase) : nil
        self.bestValue = bestValue.map { (name: $0.0, year: bestValueYear, perViewing: $0.1) }
        mostExpensiveUnwatchedSincePurchase = mostExpensiveUnwatched.map { (name: $0.0, year: mostExpensiveUnwatchedYear, cost: $0.1) }
        spentNeverWatchedSincePurchase = spentUnwatched
        spentOnSecondCopies = (secondCopySpend, multiFormat)
        wishlistItems = wishItems
        wishlistEstimatedCost = wishCost
        wishlistByFormat = (wish4K, wishBD, wishDVD)
        wishlistOutOfPrintOrImport = wishOOP
        wishlistTemporarilyUnavailable = wishTemp
        wishlistAddedLast90Days = wishRecent
        // Future years (a mistyped date) are left out: the card compares years up to this one.
        if let firstYear = spendingByYear.keys.min(), firstYear <= currentYear {
            spendingYears = (firstYear...currentYear).map { spendingByYear[$0] ?? DVSpendingYear(year: $0) }
        } else {
            spendingYears = []
        }
        spendingAsOf = todayStart
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: todayStart) ?? 1
        let daysInYear = calendar.range(of: .day, in: .year, for: todayStart)?.count ?? 365
        yearElapsedFraction = Double(dayOfYear) / Double(max(daysInYear, 1))
        ownedBelowFourK = belowFourK
        ownedBelowFourKWithFourKEntered = belowFourKWith4K
        newFourKForOwnedBelowFourK = newFourK
        newFourKForOwnedBelowFourKCost = newFourKCost
        let monthOf = { (d: Date) -> Int in
            let parts = calendar.dateComponents([.year, .month], from: d)
            return (parts.year ?? currentYear) * 12 + (parts.month ?? 1) - 1
        }
        growth = DVGrowth(filmMonths: addedMonths, purchaseMonths: purchaseDates.map(monthOf),
                          currentMonth: monthOf(todayStart), undatedFilms: undatedFilms,
                          undatedPurchases: purchasedCount - purchaseDates.count)

        multiFormatFilms = multiFormat
        multiCopyReleases = multiCopy
        remasteredReleases = remastered
        ownedOutOfPrint = ownedOOP
        self.steelbooks = steelbooks
        studios = Self.topTallies(studioCounts, top: 11, of: purchasedCount, label: ReleaseStudio.shorthand)
        origins = Self.topTallies(originCounts, top: 6, of: purchasedCount) { $0 }
        studiosAll = Self.topTallies(studioCountsAll, top: 11, of: topLevelCountAll, label: ReleaseStudio.shorthand)
        originsAll = Self.topTallies(originCountsAll, top: 6, of: topLevelCountAll) { $0 }
        let bdTotal = bdFree + bdA + bdB + bdBLoose + bdUnknown
        blurayRegionLocks = [
            DVTally("Region free", bdFree, of: bdTotal),
            DVTally("Region A", bdA, of: bdTotal),
            DVTally("Region B", bdB, of: bdTotal),
            DVTally("Region B (loosely-locked)", bdBLoose, of: bdTotal),
            DVTally("Unknown", bdUnknown, of: bdTotal),
        ]
        let bdTotalAll = bdFreeAll + bdAAll + bdBAll + bdBLooseAll + bdUnknownAll
        blurayRegionLocksAll = [
            DVTally("Region free", bdFreeAll, of: bdTotalAll),
            DVTally("Region A", bdAAll, of: bdTotalAll),
            DVTally("Region B", bdBAll, of: bdTotalAll),
            DVTally("Region B (loosely-locked)", bdBLooseAll, of: bdTotalAll),
            DVTally("Unknown", bdUnknownAll, of: bdTotalAll),
        ]

        oldestYear = years.min()
        newestYear = years.max()
        decadesByRating = decadeRatings.filter { $0.value.n >= Self.minimumRatedFilmsPerDecade }
            .map { (label: "\($0.key)s", average: Double($0.value.sum) / Double($0.value.n), rated: $0.value.n) }
            .sorted { $0.average != $1.average ? $0.average > $1.average : $0.label < $1.label }
        bestRatedDecade = decadesByRating.first.map { (label: $0.label, average: $0.average) }
        runtimeBuckets = zip(["<1:30", "1:30–1:44", "1:45–1:59", "2:00–2:29", "2:30–2:59", "3:00+"], runtime)
            .map { DVTally($0.0, $0.1, of: runtimeN) }
        averageRuntimeMinutes = runtimeN > 0 ? runtimeSum / runtimeN : nil
        longestFilm = longest.map { (name: $0.0, minutes: $0.1) }
        editedTrimmedMinutes = trimmed
        let frameTotal = frameRates.values.reduce(0, +)
        self.frameRates = frameRates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4).map { DVTally($0.key, $0.value, of: frameTotal) }

        func people(_ stats: [String: (n: Int, ratingSum: Int, rated: Int, views: Int)]) -> [DVRank] {
            stats.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }
                .prefix(7)
                .map { entry in
                    let avg = entry.value.rated > 0 ? Fmt.fixed(Double(entry.value.ratingSum) / Double(entry.value.rated), 1) : "—"
                    let views = Fmt.fixed(Double(entry.value.views) / Double(entry.value.n), 1)
                    return DVRank(name: entry.key, value: String(entry.value.n), extras: [avg, views])
                }
        }
        directors = people(directorStats)
        cast = people(castStats)
        composers = people(composerStats)
        screenwriters = people(writerStats)
        let genreTotal = genreStats.values.reduce(0) { $0 + $1.n }
        var genreRows = genreStats.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }
            .prefix(7)
            .map { entry -> DVRank in
                let avg = entry.value.rated > 0 ? Fmt.fixed(Double(entry.value.ratingSum) / Double(entry.value.rated), 1) : ""
                // Display-only shorthand: the stored genre string ("Action and Adventure")
                // is unchanged everywhere else in the app, but it is the longest of the
                // seven fixed genres and truncates first in this card's narrow name column.
                let name = entry.key == "Action and Adventure" ? "Action and Adv." : entry.key
                return DVRank(name: name, value: String(entry.value.n), extras: [avg, String(DVFormat.percent(entry.value.n, of: genreTotal))])
            }
        let otherGenres = genreTotal - genreRows.reduce(0) { $0 + (Int($1.value) ?? 0) }
        if otherGenres > 0 {
            genreRows.append(DVRank(name: "Other", value: String(otherGenres), extras: ["", String(DVFormat.percent(otherGenres, of: genreTotal))]))
        }
        genres = genreRows
        let ratingTotal = contentRatings.values.reduce(0, +)
        self.contentRatings = Self.orderedContentRatings(contentRatings).map { DVTally($0.0, $0.1, of: ratingTotal) }
        // The MPAA Ratings and Tags card shows nine.
        tags = tagCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(9).map { DVTally($0.key, $0.value) }

        filmsOnBDOr4K = onBD
        let codecTotal = codecs.values.reduce(0, +)
        videoCodecs = [ReleaseVideoFormat.hevc, ReleaseVideoFormat.avc, ReleaseVideoFormat.vc1, ReleaseVideoFormat.mpeg2]
            .map { DVTally($0, codecs[$0] ?? 0, of: codecTotal) }
        let codecTotalAll = codecsAll.values.reduce(0, +)
        videoCodecsAll = [ReleaseVideoFormat.hevc, ReleaseVideoFormat.avc, ReleaseVideoFormat.vc1, ReleaseVideoFormat.mpeg2]
            .map { DVTally($0, codecsAll[$0] ?? 0, of: codecTotalAll) }
        self.interlacedAll = interlacedAll
        self.recordable = recordable
        self.recordableAll = recordableAll
        let rfTotal = rf.values.reduce(0, +)
        handbrakeRF = ["≤18", "19–22", "23+"].map { DVTally($0, rf[$0] ?? 0, of: rfTotal) }
        let rfAllTotal = rfAll.values.reduce(0, +)
        handbrakeRFAll = ["≤18", "19–22", "23+"].map { DVTally($0, rfAll[$0] ?? 0, of: rfAllTotal) }
        subtitlesYes = subsYes
        subtitlesOnDiscOnly = subsDisc
        subtitlesDigitalRipOnly = subsRip
        subtitlesYesAll = subsYesAll
        subtitlesOnDiscOnlyAll = subsDiscAll
        subtitlesDigitalRipOnlyAll = subsRipAll
        subtitlesPurchasedFilmCount = purchasedFilmCount

        // MARK: All-time viewing
        mostRewatchedAllTime = viewings.filter { $0.dates.count >= 2 }
            .sorted { ($1.dates.count, $0.name, $0.filmID.uuidString) < ($0.dates.count, $1.name, $1.filmID.uuidString) }
            .prefix(10)
            .map { DVRank(name: $0.name, value: "×\($0.dates.count)", year: $0.releaseYear) }
        let bands: [(String, ClosedRange<Int>)] = [("≤5", 1...5), ("6–7", 6...7), ("8", 8...8), ("9", 9...9), ("10", 10...10)]
        rewatchesByRatingBand = bands.map { band in
            let inBand = viewings.filter { band.1.contains($0.rating) }
            let avg = inBand.isEmpty ? 0.0 : Double(inBand.reduce(0) { $0 + $1.dates.count }) / Double(inBand.count)
            return DVTally(band.0, Int((avg * 100).rounded()))
        }
        var monthTotals = [Int](repeating: 0, count: 12)
        var yearSet = Set<Int>()
        for v in viewings {
            for d in v.dates {
                monthTotals[calendar.component(.month, from: d) - 1] += 1
                yearSet.insert(calendar.component(.year, from: d))
            }
        }
        viewingYears = yearSet.sorted()
        habits = DVHabits(films: films, viewingsByID: viewingsByID, calendar: calendar)
        let yearCount = max(yearSet.count, 1)
        seasonality = monthTotals.map { Double($0) / Double(yearCount) }
        if let lead = monthTotals.enumerated().max(by: { $0.element < $1.element }), lead.element > 0 {
            seasonalityLeader = calendar.monthSymbols[lead.offset]
        } else {
            seasonalityLeader = nil
        }
    }

    // MARK: - Rules

    /// Whether a candidate with `value` should replace the current best (a larger value
    /// wins; on a tie the earlier name). `getAllFilms()` hands films over in Dictionary
    /// order, which changes from launch to launch, so a strict comparison alone would name
    /// whichever tied film happened to come first — and the figure would change between
    /// two launches on an unchanged library.
    private static func prefer(_ value: Double, _ name: String, over current: (String, Double)?) -> Bool {
        guard let current else { return true }
        return value != current.1 ? value > current.1 : name < current.0
    }

    /// The month a film's Date Added falls in, as `year * 12 + month - 1`. The stored form
    /// is an ISO 8601 timestamp in UTC (StorageDateFormatters.timestamp), which the general
    /// parser reads only through its slowest formatter; a timestamp's own year and month
    /// are the local ones whenever its day is 2…27 (no offset moves a date a whole day), so
    /// only the days at a month's edges take the parser, which knows the time zone.
    static func addedMonth(_ text: String, calendar: Calendar) -> Int? {
        let u = Array(text.utf8.prefix(11))
        if u.count == 11, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"), u[10] == UInt8(ascii: "T") {
            var digits: [Int] = []
            for i in [0, 1, 2, 3, 5, 6, 8, 9] where u[i] >= 48 && u[i] <= 57 { digits.append(Int(u[i]) - 48) }
            if digits.count == 8 {
                let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
                let month = digits[4] * 10 + digits[5], day = digits[6] * 10 + digits[7]
                if (1...12).contains(month), (2...27).contains(day) { return year * 12 + month - 1 }
            }
        }
        guard let date = parseDate(from: text) else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return year * 12 + month - 1
    }

    /// True when the film's digital copy is a lower tier than the best disc it owns:
    /// a 4K disc wants a 4K download; a Blu-ray wants a Blu-ray rip or a 1080p download;
    /// a DVD wants a DVD rip or anything 480p and up. An empty source is unknown, not
    /// below. The comparison is what makes "rip backlog" a list rather than a guess.
    /// The remastered flag says nothing about the tier, so it is decoded off first: a
    /// "Remastered 4K download" is a 4K download (read whole, it fell through to the
    /// lowest tier and put the film in the backlog of a 4K owner).
    private static func digitalSourceBelowBestDisc(_ film: FilmSnapshot, purchased4K: Bool,
                                                   purchasedBD: Bool, purchasedDVD: Bool) -> Bool {
        let source = FilmDigitalSource.decompose(film.digitalSource).source
        guard !source.isEmpty else { return false }
        let tier: Int
        if source == FilmDigitalSource.download4K { tier = 4 }
        else if source == FilmDigitalSource.blurayDisc || source == FilmDigitalSource.download1080p { tier = 3 }
        else if source == FilmDigitalSource.dvd || source == FilmDigitalSource.download720p
                    || source == FilmDigitalSource.download540p || source == FilmDigitalSource.download480p { tier = 2 }
        else { tier = 1 }
        if purchased4K { return tier < 4 }
        if purchasedBD { return tier < 3 }
        if purchasedDVD { return tier < 2 }
        return false
    }

    private static func topTallies(_ counts: [String: Int], top: Int, of total: Int,
                                   label: (String) -> String) -> [DVTally] {
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var rows = sorted.prefix(top).map { DVTally(label($0.key), $0.value, of: total) }
        let rest = sorted.dropFirst(top)
        let restCount = rest.reduce(0) { $0 + $1.value }
        if restCount > 0 { rows.append(DVTally("Other (\(rest.count))", restCount, of: total)) }
        return rows
    }

    /// MPAA order first, anything else after in descending count.
    private static func orderedContentRatings(_ counts: [String: Int]) -> [(String, Int)] {
        let known = ["G", "PG", "PG-13", "R", "NC-17", "Unrated", "Not Rated", "NR"]
        var rows: [(String, Int)] = []
        for k in known { if let c = counts[k], c > 0 { rows.append((k, c)) } }
        let rest = counts.filter { !known.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        rows.append(contentsOf: rest.prefix(3).map { ($0.key, $0.value) })
        return rows
    }
}

// MARK: - Viewing Period Statistics

/// One calendar year of viewing, optionally cut off at today's month and day, with the
/// same span of the year before beside it for the delta chips and the ghost bars.
struct ViewingPeriodStatistics {
    let year: Int
    let yearToDate: Bool
    let compareYear: Int
    let spanLabel: String
    let comparisonLabel: String

    let viewings: Int
    let distinctFilms: Int
    let firstTimeWatches: Int
    let rewatches: Int
    let hoursWatchedMinutes: Int
    /// Viewings of a film with a recorded runtime — the ones `hoursWatchedMinutes` sums,
    /// and so the divisor of the span's average runtime.
    let timedViewings: Int
    let averageRating: Double?
    let projectedYearEnd: Int?

    let priorViewings: Int
    let priorDistinctFilms: Int
    let priorFirstTimeWatches: Int
    let priorRewatches: Int
    let priorHoursWatchedMinutes: Int
    let priorAverageRating: Double?

    /// Jan…Dec counts for the year and the prior year (full months; the in-progress
    /// month is flagged by `currentMonthIndex`).
    let byMonth: [Int]
    let priorByMonth: [Int]
    /// Of `byMonth`/`priorByMonth`, how many of that month's viewings were of a
    /// color film — the month chart's per-bar color/black-and-white split.
    let byMonthColor: [Int]
    let priorByMonthColor: [Int]
    /// Of `byMonth`/`priorByMonth`, each month's viewings by the film's release decade
    /// (`DVFormat`-style "1980s", or "Unknown") and by genre ("" when none is set) — the
    /// month chart's Release Decade and Genre bands.
    let byMonthDecade: [[String: Int]]
    let priorByMonthDecade: [[String: Int]]
    let byMonthGenre: [[String: Int]]
    let priorByMonthGenre: [[String: Int]]
    let currentMonthIndex: Int?
    let mostRewatched: [DVRank]
    let versionsWatched: [DVTally]
    let decadeShare: [DVTally]

    init(viewings all: [DVFilmViewings], year: Int, yearToDate: Bool, compareYear: Int? = nil, today: Date, calendar: Calendar) {
        self.year = year
        self.yearToDate = yearToDate
        let todayStart = calendar.startOfDay(for: today)
        let currentYear = calendar.component(.year, from: today)
        let isCurrent = year == currentYear
        let ytd = yearToDate && isCurrent
        let compareYear = compareYear ?? (year - 1)
        self.compareYear = compareYear

        func span(_ y: Int) -> (start: Date, end: Date) {
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
            var end: Date
            if ytd {
                // The same month and day in year `y`, clamped to that month's length:
                // `date(from:)` never fails on an out-of-range day, it rolls over, so on
                // Feb 29 an unclamped comparison span ran through Mar 1 of a common year.
                let m = calendar.component(.month, from: todayStart), d = calendar.component(.day, from: todayStart)
                let first = calendar.date(from: DateComponents(year: y, month: m, day: 1))!
                let length = calendar.range(of: .day, in: .month, for: first)?.count ?? d
                end = calendar.date(from: DateComponents(year: y, month: m, day: min(d, length)))!
            } else {
                end = calendar.date(from: DateComponents(year: y, month: 12, day: 31))!
            }
            return (start, end)
        }
        let cur = span(year), prior = span(compareYear)
        spanLabel = ytd
            ? "Jan 1 – \(DVFormat.shortMonthDay.string(from: cur.end)), \(year)"
            : "Jan 1 – Dec 31, \(year)"
        comparisonLabel = ytd ? "the same span of \(compareYear)" : "\(compareYear)"

        struct Acc {
            var viewings = 0, distinct = 0, firstTime = 0, minutes = 0, timed = 0, ratingSum = 0, rated = 0
            var byMonth = [Int](repeating: 0, count: 12)
            var byMonthColor = [Int](repeating: 0, count: 12)
            var byMonthDecade = [[String: Int]](repeating: [:], count: 12)
            var byMonthGenre = [[String: Int]](repeating: [:], count: 12)
            var perFilm: [(id: UUID, name: String, count: Int, year: Int?)] = []
            var versions: [ViewingVersion: Int] = [:]
            var decades: [String: Int] = [:]
        }
        func accumulate(_ range: (start: Date, end: Date)) -> Acc {
            var a = Acc()
            for v in all {
                var n = 0
                for (i, d) in v.dates.enumerated() where d >= range.start && d <= range.end {
                    n += 1
                    if i == 0 { a.firstTime += 1 }
                    // Runs on the main thread on every stepper click.
                    let month = calendar.component(.month, from: d) - 1
                    a.byMonth[month] += 1
                    if v.isColor { a.byMonthColor[month] += 1 }
                    a.versions[v.versions[i], default: 0] += 1
                    let decade = v.releaseYear.flatMap { $0 >= 1888 ? "\(($0 / 10) * 10)s" : nil } ?? "Unknown"
                    a.decades[decade, default: 0] += 1
                    a.byMonthDecade[month][decade, default: 0] += 1
                    a.byMonthGenre[month][v.genre, default: 0] += 1
                    if let duration = v.durationMinutes { a.minutes += duration; a.timed += 1 }
                    if v.rating > 0 { a.ratingSum += v.rating; a.rated += 1 }
                }
                if n > 0 { a.viewings += n; a.distinct += 1; a.perFilm.append((v.filmID, v.name, n, v.releaseYear)) }
            }
            return a
        }
        let a = accumulate(cur), p = accumulate(prior)

        viewings = a.viewings
        distinctFilms = a.distinct
        firstTimeWatches = a.firstTime
        rewatches = a.viewings - a.firstTime
        hoursWatchedMinutes = a.minutes
        timedViewings = a.timed
        averageRating = a.rated > 0 ? Double(a.ratingSum) / Double(a.rated) : nil
        if ytd, a.viewings > 0 {
            let dayOfYear = calendar.ordinality(of: .day, in: .year, for: todayStart) ?? 1
            let daysInYear = calendar.range(of: .day, in: .year, for: todayStart)?.count ?? 365
            projectedYearEnd = Int((Double(a.viewings) / Double(dayOfYear) * Double(daysInYear)).rounded())
        } else {
            projectedYearEnd = nil
        }
        priorViewings = p.viewings
        priorDistinctFilms = p.distinct
        priorFirstTimeWatches = p.firstTime
        priorRewatches = p.viewings - p.firstTime
        priorHoursWatchedMinutes = p.minutes
        priorAverageRating = p.rated > 0 ? Double(p.ratingSum) / Double(p.rated) : nil
        byMonth = a.byMonth
        priorByMonth = p.byMonth
        byMonthColor = a.byMonthColor
        priorByMonthColor = p.byMonthColor
        byMonthDecade = a.byMonthDecade
        priorByMonthDecade = p.byMonthDecade
        byMonthGenre = a.byMonthGenre
        priorByMonthGenre = p.byMonthGenre
        currentMonthIndex = ytd ? calendar.component(.month, from: todayStart) - 1 : nil

        // Ties by name, then by film id, so two films of one name keep one order.
        mostRewatched = a.perFilm.filter { $0.count >= 2 }
            .sorted { ($1.count, $0.name, $0.id.uuidString) < ($0.count, $1.name, $1.id.uuidString) }
            .prefix(10)
            .map { DVRank(name: $0.name, value: "×\($0.count)", year: $0.year) }
        // Untagged entries read as Theatrical, the default the picker stores as an empty code.
        var versionCounts = a.versions
        versionCounts[.theatrical, default: 0] += versionCounts.removeValue(forKey: .none) ?? 0
        let versionRows = versionCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        var versionsOut = versionRows.prefix(3).map { DVTally($0.key.displayName, $0.value, of: a.viewings) }
        let otherVersions = versionRows.dropFirst(3).reduce(0) { $0 + $1.value }
        if otherVersions > 0 { versionsOut.append(DVTally("Other", otherVersions, of: a.viewings)) }
        versionsWatched = versionsOut
        let decadeRows = a.decades.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var decadesOut = decadeRows.prefix(4).map { DVTally($0.key, $0.value, of: a.viewings) }
        let otherDecades = decadeRows.dropFirst(4).reduce(0) { $0 + $1.value }
        if otherDecades > 0 { decadesOut.append(DVTally("Other", otherDecades, of: a.viewings)) }
        decadeShare = decadesOut
    }
}

// MARK: - Spending Trends

/// One statement on the Spending Trends card: a kicker, a headline, a line of detail and a
/// small chart. Built once here, from the figures alone; the tab and the PDF draw it with the
/// same canvas builder (DVK.highlightRow).
struct DVHighlight {
    enum Tint { case blue, green, purple, indigo }
    enum Chart {
        /// Columns, oldest first; the highlighted one full strength, the rest dimmed.
        case bars([DVMiniBar])
        /// One line across `values`, labeled at its two ends.
        case line(values: [Double], firstLabel: String, lastLabel: String)
        /// A fill bar of `part` over `whole`, captioned.
        case share(part: Int, whole: Int, caption: String)
        case none
    }
    let kicker: String
    let headline: String
    let detail: String
    let tint: Tint
    let chart: Chart
}

struct DVMiniBar {
    let label: String
    let value: Double
    var valueLabel: String? = nil
    var highlighted = false
}

enum DVSpendingTrends {
    static let emptyText = "No purchased release has a purchase date yet."

    /// The card's statements, in order: this year against the others, the average price
    /// year over year, the long run, and new 4K releases for films owned below 4K. Empty
    /// when no purchase has a date.
    static func highlights(stats: LibraryStatistics, insights: LibraryInsights) -> [DVHighlight] {
        let years = insights.spendingYears
        guard let current = years.last else { return [] }
        let earlier = Array(years.dropLast())
        var result = [thisYear(current, earlier, insights)]
        if let price = averagePrice(years, current: current, stats: stats) { result.append(price) }
        result.append(longTerm(years, earlier))
        if let upgrades = upgrades(insights) { result.append(upgrades) }
        return result
    }

    private static func money(_ v: Double) -> String { DVFormat.wholeMoney(v) }
    private static func plural(_ n: Int, _ word: String) -> String { "\(DVFormat.count(n)) \(word)\(n == 1 ? "" : "s")" }
    private static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(n) ? words[n] : DVFormat.count(n)
    }

    /// This year's projected total. With history: what was spent so far, plus the rest of
    /// the year as the last three earlier years with purchases spent it (weighted 3:2:1,
    /// most recent first, so a trend in recent years carries), scaled by this year's pace
    /// against those same years' spending by this date (clamped to ½×–2× so one big or
    /// small start cannot run away with it). Without history: the year so far extrapolated
    /// linearly, once a tenth of the year has passed. Nil when nothing is spent yet.
    static func projectedYearEnd(_ current: DVSpendingYear, _ earlier: [DVSpendingYear], yearElapsed: Double) -> Double? {
        let spent = current.spentByThisDate
        guard spent > 0 else { return nil }
        // A gap year is not a habit: only years something was bought in.
        let recent = Array(earlier.filter { $0.purchases > 0 }.suffix(3).reversed())
        guard !recent.isEmpty else { return yearElapsed >= 0.1 ? spent / yearElapsed : nil }
        let weights = [3.0, 2.0, 1.0].prefix(recent.count)
        let total = weights.reduce(0, +)
        let rest = zip(recent, weights).reduce(0.0) { $0 + ($1.0.spent - $1.0.spentByThisDate) * $1.1 } / total
        let byThisDate = zip(recent, weights).reduce(0.0) { $0 + $1.0.spentByThisDate * $1.1 } / total
        let pace = byThisDate > 0 ? min(2, max(0.5, spent / byThisDate)) : 1
        return spent + rest * pace
    }

    /// Spending so far this year against the same span of every earlier year.
    private static func thisYear(_ current: DVSpendingYear, _ earlier: [DVSpendingYear], _ insights: LibraryInsights) -> DVHighlight {
        let spent = current.spentByThisDate
        let headline: String
        var detail: [String] = []
        if let prior = earlier.last {
            let diff = spent - prior.spentByThisDate
            let comparison = abs(diff) < 0.5
                ? "the same as by this date in \(prior.year)"
                : "\(money(abs(diff))) \(diff > 0 ? "more" : "less") than by this date in \(prior.year)"
            headline = "You've spent \(money(spent)) on \(plural(current.purchasesByThisDate, "release")) so far in \(current.year), \(comparison)."
            let beaten = earlier.filter { $0.spentByThisDate < spent - 0.005 }.count
            if earlier.count >= 2, beaten == earlier.count {
                detail.append("Your biggest start to a year yet.")
            } else if earlier.count >= 2, beaten == 0, earlier.allSatisfy({ $0.spentByThisDate > spent + 0.005 }) {
                detail.append("Your smallest start to a year since \(earlier[0].year).")
            } else {
                detail.append("More than by this date in \(beaten) of \(plural(earlier.count, "earlier year")).")
            }
            if let projected = projectedYearEnd(current, earlier, yearElapsed: insights.yearElapsedFraction) {
                detail.append("At this pace, \(current.year) is projected to end with a total spend around \(money(projected)).")
            }
        } else {
            headline = "You've spent \(money(spent)) on \(plural(current.purchasesByThisDate, "release")) so far in \(current.year)."
            detail.append("Your first year of dated purchases; comparisons start next year.")
        }
        detail.append("Bars compare each year-to-date.")
        let bars = (earlier.suffix(7) + [current]).map {
            DVMiniBar(label: String($0.year), value: $0.spentByThisDate,
                      valueLabel: $0.year == current.year ? money(spent) : nil, highlighted: $0.year == current.year)
        }
        return DVHighlight(kicker: "THIS YEAR VERSUS PRIOR YEARS", headline: headline, detail: detail.joined(separator: " "),
                           tint: .blue, chart: .bars(bars))
    }

    /// The average entered cost per year with priced purchases: a run of rises or falls
    /// when there is one, the latest change when there is not.
    private static func averagePrice(_ years: [DVSpendingYear], current: DVSpendingYear, stats: LibraryStatistics) -> DVHighlight? {
        let priced = years.filter { $0.averageCost != nil }
        guard let last = priced.last, let lastAverage = last.averageCost else { return nil }
        let bars = priced.suffix(6).map {
            DVMiniBar(label: String($0.year), value: $0.averageCost ?? 0, valueLabel: money($0.averageCost ?? 0),
                      highlighted: $0.year == last.year)
        }
        let span = last.year == current.year ? "so far in \(last.year)" : "in \(last.year)"
        guard priced.count >= 2 else {
            return DVHighlight(kicker: "AVERAGE PRICE (YEAR-OVER-YEAR)",
                               headline: "Your average purchase price \(span) is \(DVFormat.money(lastAverage)).",
                               detail: "Year-over-year comparisons start once a second year has priced purchases.",
                               tint: .green, chart: .bars(bars))
        }
        let averages = priced.compactMap(\.averageCost)
        var run = 0, direction = 0
        for i in stride(from: averages.count - 1, to: 0, by: -1) {
            let change = averages[i] - averages[i - 1]
            let sign = abs(change) < 0.005 ? 0 : (change > 0 ? 1 : -1)
            if sign == 0 || (direction != 0 && sign != direction) { break }
            direction = sign
            run += 1
        }
        let previous = priced[priced.count - 2]
        let headline: String
        if run >= 2 {
            let chain = priced.suffix(min(run, 3) + 1)
            let consecutive = chain.last!.year - chain.first!.year == chain.count - 1
            headline = "Your average purchase price has \(direction > 0 ? "risen" : "fallen") "
                + (consecutive || run > 3 ? "\(number(run)) years running" : "\(number(run)) times in a row")
                + ": " + chain.compactMap { $0.averageCost.map(DVFormat.money) }.joined(separator: " → ") + "."
        } else {
            let prior = previous.averageCost ?? 0
            let change = prior > 0 ? Int(((lastAverage - prior) / prior * 100).rounded()) : 0
            let movement = change == 0 ? "level with" : "\(change > 0 ? "up" : "down") \(abs(change))% from"
            headline = "Your average purchase price \(span) is \(DVFormat.money(lastAverage)), \(movement) \(DVFormat.money(prior)) in \(previous.year)."
        }
        var detail = "All-time average: \(stats.averageCost)."
        let shares = Dictionary(stats.purchaseYearTable.map { ($0.year, Int($0.atOrBelowAveragePercentOfYear.rounded())) },
                                uniquingKeysWith: { first, _ in first })
        if let now = shares[String(last.year)], let before = shares[String(previous.year)] {
            detail += " \(now)% of \(last.year)'s purchases came in at-or-below this average, versus \(before)% in \(previous.year)."
        }
        return DVHighlight(kicker: "AVERAGE PRICE (YEAR-OVER-YEAR)", headline: headline, detail: detail, tint: .green, chart: .bars(bars))
    }

    /// The last three complete years against the three before them, and the whole history.
    private static func longTerm(_ years: [DVSpendingYear], _ complete: [DVSpendingYear]) -> DVHighlight {
        let total = years.reduce(0) { $0 + $1.spent }
        let bought = years.reduce(0) { $0 + $1.purchases }
        var headline = "Across \(plural(years.count, "year")) of dated purchases you've spent \(money(total)) on \(plural(bought, "release"))."
        let recent = complete.suffix(3), before = complete.dropLast(3).suffix(3)
        let recentBought = recent.reduce(0) { $0 + $1.purchases }, beforeBought = before.reduce(0) { $0 + $1.purchases }
        if before.count == 3, recentBought > 0, beforeBought > 0 {
            let r = Double(recentBought) / 3, b = Double(beforeBought) / 3
            let countPhrase = abs(r - b) <= max(1, b * 0.05)
                ? "about as many releases a year (\(Int(r.rounded())))"
                : "\(r > b ? "more" : "fewer") releases per year (\(Int(r.rounded())) vs. \(Int(b.rounded())))"
            func average(_ ys: ArraySlice<DVSpendingYear>) -> Double? {
                let n = ys.reduce(0) { $0 + $1.costed }
                return n > 0 ? ys.reduce(0) { $0 + $1.costSum } / Double(n) : nil
            }
            var pricePhrase = ""
            if let ra = average(recent), let ba = average(before) {
                pricePhrase = abs(ra - ba) <= ba * 0.05
                    ? " and paid about the same for each (\(DVFormat.money(ra)))"
                    : " and paid \(ra > ba ? "more" : "less") for each (\(DVFormat.money(ra)) vs. \(DVFormat.money(ba)))"
            }
            headline = "Over the last three years, you've purchased \(countPhrase)\(pricePhrase), compared with the three years prior."
        }
        var detail: [String] = []
        if !complete.isEmpty {
            let perYear = complete.reduce(0) { $0 + $1.spent } / Double(complete.count)
            let perYearCount = Double(complete.reduce(0) { $0 + $1.purchases }) / Double(complete.count)
            detail.append("You've averaged about \(money(perYear)) and \(Int(perYearCount.rounded())) releases per year since \(complete[0].year).")
        }
        if let biggest = years.max(by: { $0.spent != $1.spent ? $0.spent < $1.spent : $0.year > $1.year }), biggest.spent > 0 {
            detail.append("Your biggest spending year \(biggest.year == years.last?.year ? "is" : "was") \(biggest.year) with a total of \(money(biggest.spent)).")
        }
        if before.count < 3 { detail.append("Three-year comparisons start after six complete years of purchases.") }
        let chart: DVHighlight.Chart = complete.count >= 2
            ? .line(values: complete.map(\.spent), firstLabel: String(complete[0].year), lastLabel: String(complete[complete.count - 1].year))
            : .none
        return DVHighlight(kicker: "LONG-TERM", headline: headline, detail: detail.joined(separator: " "), tint: .purple, chart: chart)
    }

    /// Films owned only below 4K for which a 4K release was entered in the last 90 days.
    private static func upgrades(_ insights: LibraryInsights) -> DVHighlight? {
        let owned = insights.ownedBelowFourK
        guard owned > 0 else { return nil }
        let fresh = insights.newFourKForOwnedBelowFourK
        let entered = insights.ownedBelowFourKWithFourKEntered
        let headline = fresh > 0
            ? "\(plural(fresh, "film")) you own on Blu-ray or DVD gained a 4K release in the last 90 days."
            : "No 4K release was entered in the last 90 days for a film you own on Blu-ray or DVD."
        var detail = "\(DVFormat.count(entered)) of the \(plural(owned, "film")) you own only on Blu-ray or DVD have a 4K release entered, but not purchased"
        if fresh > 0, insights.newFourKForOwnedBelowFourKCost > 0 {
            detail += "; the newly entered ones come to \(money(insights.newFourKForOwnedBelowFourKCost)) at their cheapest entered prices."
        } else {
            detail += "."
        }
        return DVHighlight(kicker: "NEW 4K RELEASES AVAILABLE AS UPGRADES", headline: headline, detail: detail, tint: .indigo,
                           chart: .share(part: entered, whole: owned, caption: "\(DVFormat.count(entered)) of \(DVFormat.count(owned)) have a 4K release entered"))
    }
}

// MARK: - Collector habits

/// All-time figures about how the library is watched and bought, each computed in one
/// pass over the films (DVHabits.init). Every figure here ignores the Viewing History
/// stepper.
struct DVHabits {
    /// One calendar year of viewings, split by whether each was the film's first.
    struct ViewingYear: Equatable {
        let year: Int
        let firstTime: Int
        let rewatches: Int
        var total: Int { firstTime + rewatches }
        var rewatchPercent: Int { DVFormat.percent(rewatches, of: total) }
    }
    /// Years from the first well-recorded one on (`trackedFrom`), oldest first, at most
    /// `maxViewingYears` of them (the latest).
    let viewingYears: [ViewingYear]
    static let maxViewingYears = 12
    /// The first year with at least a quarter of the busiest year's viewings: before it,
    /// the history is too sparse to compare (tracking had not begun in earnest), so the
    /// trend starts there. Nil with no viewings.
    let trackedFrom: Int?
    /// Whether any viewings fall before `trackedFrom` (and are left off the trend).
    let hasSparseEarlierYears: Bool

    /// Every viewing by how old the film was (viewing year − release year), in
    /// `ageBucketLabels` order; viewings of films without a release year are left out.
    let viewingAgeBuckets: [DVTally]
    let medianViewingAge: Int?
    static let ageBucketLabels = ["≤1", "2–5", "6–10", "11–20", "21–30", "31–50", "51+"]

    /// Dated purchased top-level releases (one per acquisition, as Purchase Facts counts)
    /// per calendar month Jan…Dec, and what each month's averaged paid.
    let purchasesByMonth: [Int]
    let averagePaidByMonth: [Double?]
    let datedPurchases: Int
    /// What the months' priced purchases came to, and how many there were, for averages
    /// over several months.
    private let paidSumByMonth: [Double]
    private let pricedByMonth: [Int]

    /// Rating 1…10 (index 0 = rating 1): the average paid per purchased release of films
    /// at that rating, and the share of those films whose best purchased disc is 4K.
    let averagePaidByRating: [Double?]
    let pricedByRating: [Int]
    let fourKShareByRating: [Int?]
    let filmsByRating: [Int]
    let fourKFilmsByRating: [Int]

    /// Films rated `upgradeMinimumRating` or higher with a 4K release entered but none
    /// purchased: best rated first, then by title. `rating` is the film's own.
    let fourKUpgrades: [(film: DVNamedFilm, rating: Int)]
    static let upgradeMinimumRating = 8

    /// Per release decade, oldest first: cataloged films and those with a purchased release.
    let ownershipByDecade: [(decade: String, films: Int, owned: Int)]

    init(films: [FilmSnapshot], viewingsByID: [UUID: DVFilmViewings], calendar: Calendar) {
        var first: [Int: Int] = [:], again: [Int: Int] = [:]
        var ages: [Int] = []
        var byMonth = [Int](repeating: 0, count: 12)
        var paidByMonth = [Double](repeating: 0, count: 12), paidCountByMonth = [Int](repeating: 0, count: 12)
        var dated = 0
        var paidByRating = [Double](repeating: 0, count: 10), paidCountByRating = [Int](repeating: 0, count: 10)
        var ratedFilms = [Int](repeating: 0, count: 10), fourKFilms = [Int](repeating: 0, count: 10)
        var upgrades: [(film: DVNamedFilm, rating: Int)] = []
        var decades: [Int: (films: Int, owned: Int)] = [:]

        for film in films {
            let release = Int(film.releaseYear).flatMap { $0 >= 1888 ? $0 : nil }
            if let v = viewingsByID[film.id] {
                for (i, d) in v.dates.enumerated() {
                    let y = calendar.component(.year, from: d)
                    if i == 0 { first[y, default: 0] += 1 } else { again[y, default: 0] += 1 }
                    if let release { ages.append(max(0, y - release)) }
                }
            }
            let purchased = film.releases.filter(\.purchased)
            // One per acquisition: a combo child mirrors its parent's purchase date and price,
            // so counting it would put the pack in its month twice and weight every average
            // toward combo packs.
            for r in purchased where r.isTopLevel {
                let paid = r.amountSpent > 0 ? r.amountSpent : r.cost
                if let d = LibraryStatistics.purchaseDay(r.purchaseDate, calendar: calendar) {
                    let m = calendar.component(.month, from: d) - 1
                    byMonth[m] += 1
                    dated += 1
                    if paid > 0 { paidByMonth[m] += paid; paidCountByMonth[m] += 1 }
                }
                if (1...10).contains(film.userRating), paid > 0 {
                    paidByRating[film.userRating - 1] += paid
                    paidCountByRating[film.userRating - 1] += 1
                }
            }
            let owns4K = purchased.contains { $0.format == ReleaseFormat.uhd4K.rawValue }
            if (1...10).contains(film.userRating), !purchased.isEmpty {
                ratedFilms[film.userRating - 1] += 1
                if owns4K { fourKFilms[film.userRating - 1] += 1 }
            }
            if film.userRating >= Self.upgradeMinimumRating, !owns4K,
               film.releases.contains(where: { !$0.purchased && $0.isTopLevel && $0.format == ReleaseFormat.uhd4K.rawValue }) {
                upgrades.append((DVNamedFilm(film), film.userRating))
            }
            if let release {
                var row = decades[(release / 10) * 10] ?? (0, 0)
                row.films += 1
                if !purchased.isEmpty { row.owned += 1 }
                decades[(release / 10) * 10] = row
            }
        }

        let years = Set(first.keys).union(again.keys).sorted()
        let busiest = years.map { (first[$0] ?? 0) + (again[$0] ?? 0) }.max() ?? 0
        let tracked = years.first { 4 * ((first[$0] ?? 0) + (again[$0] ?? 0)) >= busiest }
        trackedFrom = tracked
        hasSparseEarlierYears = years.first.map { $0 < (tracked ?? $0) } ?? false
        // Every year from the first tracked to the latest, a year without viewings included,
        // at most the latest `maxViewingYears` of them.
        viewingYears = (tracked.flatMap { t in years.last.map { Array(t...$0).suffix(Self.maxViewingYears) } } ?? [])
            .map { ViewingYear(year: $0, firstTime: first[$0] ?? 0, rewatches: again[$0] ?? 0) }

        var buckets = [Int](repeating: 0, count: Self.ageBucketLabels.count)
        for a in ages {
            let i: Int
            switch a {
            case ...1: i = 0
            case 2...5: i = 1
            case 6...10: i = 2
            case 11...20: i = 3
            case 21...30: i = 4
            case 31...50: i = 5
            default: i = 6
            }
            buckets[i] += 1
        }
        viewingAgeBuckets = zip(Self.ageBucketLabels, buckets).map { DVTally($0.0, $0.1, of: ages.count) }
        medianViewingAge = DVFormat.median(ages.map(Double.init)).map { Int($0.rounded()) }

        purchasesByMonth = byMonth
        paidSumByMonth = paidByMonth
        pricedByMonth = paidCountByMonth
        averagePaidByMonth = (0..<12).map { paidCountByMonth[$0] > 0 ? paidByMonth[$0] / Double(paidCountByMonth[$0]) : nil }
        datedPurchases = dated
        averagePaidByRating = (0..<10).map { paidCountByRating[$0] > 0 ? paidByRating[$0] / Double(paidCountByRating[$0]) : nil }
        fourKShareByRating = (0..<10).map { ratedFilms[$0] > 0 ? DVFormat.percent(fourKFilms[$0], of: ratedFilms[$0]) : nil }
        filmsByRating = ratedFilms
        fourKFilmsByRating = fourKFilms
        pricedByRating = paidCountByRating
        fourKUpgrades = upgrades.sorted { $0.rating != $1.rating ? $0.rating > $1.rating : DVNamedFilm.compareTitles($0.film, $1.film) }
        ownershipByDecade = decades.keys.sorted().map { ("\($0)s", decades[$0]!.films, decades[$0]!.owned) }
    }

    /// The busiest purchase month's share of dated purchases and how its prices compare.
    var busiestMonthSentence: String? {
        guard datedPurchases > 0, let m = (0..<12).max(by: { purchasesByMonth[$0] < purchasesByMonth[$1] }), purchasesByMonth[m] > 0 else { return nil }
        let name = AppCalendar.current.monthSymbols[m]
        var text = "\(name) accounts for \(DVFormat.percent(purchasesByMonth[m], of: datedPurchases))% of dated purchases"
        let rest = (0..<12).filter { $0 != m }
        let restCount = rest.reduce(0) { $0 + pricedByMonth[$1] }
        let restSum = rest.reduce(0.0) { $0 + paidSumByMonth[$1] }
        if let here = averagePaidByMonth[m], restCount > 0 {
            text += ", averaging \(DVFormat.money(here)) a release against \(DVFormat.money(restSum / Double(restCount))) the rest of the year"
        }
        return text + "."
    }

    /// The average paid per release and the share of films owned on 4K across a band of
    /// ratings (1-based, inclusive); nil when the band has nothing to average.
    func ratingBand(_ ratings: ClosedRange<Int>) -> (averagePaid: Double?, fourKPercent: Int?) {
        let idx = ratings.map { $0 - 1 }
        let n = idx.reduce(0) { $0 + pricedByRating[$1] }
        let sum = idx.reduce(0.0) { $0 + (averagePaidByRating[$1] ?? 0) * Double(pricedByRating[$1]) }
        let films = idx.reduce(0) { $0 + filmsByRating[$1] }, fourK = idx.reduce(0) { $0 + fourKFilmsByRating[$1] }
        return (n > 0 ? sum / Double(n) : nil, films > 0 ? DVFormat.percent(fourK, of: films) : nil)
    }
}
