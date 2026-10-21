// MARK: - MetadataCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Persistent cache for derived film metadata: sorting keys, parsed dates, and recent-activity
// data. Sourced exclusively from FilmSnapshot value types; does not reference SwiftData.

import Foundation

// MARK: - Film Metadata Structure
struct FilmMetadata: Codable {
    let id: UUID
    
    // Sorting Data
    let titleKey: String
    let titleStartsWithNumber: Bool
    let year: String
    let duration: String
    // The duration value used for sort comparisons. When the film is marked as
    // edited and editedDuration resolves to a positive integer, this holds that
    // value; otherwise it mirrors `duration`. Stored as the raw millisecond string
    // so the sort case can parse it exactly as it does `duration`.
    let effectiveDuration: String
    let dateAddedRaw: String
    let lastWatchedRaw: String
    let rating: Int
    // Number of recorded viewings — the count of entries in the film's calendarTable,
    // the same figure the RightSidebar's "Watch Details" module shows as "Recorded
    // View Count". Backs the .viewCount sort option.
    let viewCount: Int
    let lastModifiedRaw: String
    // Parsed release date used as a secondary sort key within the .year sort option.
    // nil when the releaseDate field is absent, malformed, or does not contain a
    // well-formed "YYYY-MM-DD" prefix (dashes required). When nil, the .year sort
    // falls back directly to the title tiebreaker, exactly as before.
    let releaseDateParsed: Date?
    
    // Recents Data
    let dateAddedParsed: Date
    let lastWatchedParsed: Date
    let lastModifiedParsed: Date
    let rotationDate: Date?
    let mostRecentPurchaseDate: Date?
    
    // True if at least one Release object associated with this film is marked as purchased,
    // regardless of whether any of those releases carries a purchase date. Used by the
    // datePurchased sort to place "purchased but no date" films in their own middle tier,
    // between films that have a dated purchase and films with no purchase record at all.
    let hasPurchasedReleases: Bool

    // The two fields above, per release format, keyed by ReleaseFormat raw value: the most
    // recent usable purchase date among purchased releases of that format, and the formats
    // that have any purchased release at all. A combo-pack's Blu-ray child counts as a
    // Blu-ray here exactly as it does for "Purchased Blu-ray" membership (it carries its
    // parent's purchase date). Read through `mostRecentPurchaseDate(in:)` and
    // `hasPurchasedReleases(in:)`, which back the Date Last Purchased sort on the format lists.
    let mostRecentPurchaseDateByFormat: [String: Date]
    let purchasedFormats: Set<String>

    // Pre-formatted date strings for display
    let dateAddedFormatted: String
    let lastWatchedFormatted: String
    let lastModifiedFormatted: String
    let rotationDateFormatted: String?
    let purchaseDateFormatted: String?
    
    // Search Cache Data — each title in SearchText.key form, the form search compares in.
    // Alternate titles are joined by "\n", which no key contains, so a query can never
    // match across the boundary between two of them.
    let nameSearchKey: String
    let alternateTitleSearchKeys: String
    
    /// Creates a FilmMetadata entry from a FilmSnapshot.
    /// All data is sourced from value types; no SwiftData @Model objects are accessed.
    init(from snapshot: FilmSnapshot) {
        self.id = snapshot.id
        
        // Sorting Data
        let nameToSort = snapshot.sortName.isEmpty ? snapshot.name : snapshot.sortName
        let stripped = Self.stripArticles(nameToSort)
        self.titleKey = stripped
        self.titleStartsWithNumber = stripped.first?.isNumber ?? false
        
        self.year = snapshot.releaseYear
        self.duration = snapshot.duration
        // The effective sort duration — see FilmSnapshot.effectiveDuration.
        self.effectiveDuration = snapshot.effectiveDuration
        self.dateAddedRaw = snapshot.dateAdded
        self.lastWatchedRaw = snapshot.lastWatched
        self.rating = snapshot.userRating
        self.viewCount = snapshot.calendarTable.count
        self.lastModifiedRaw = snapshot.lastModified
        
        // Parse releaseDate as a secondary sort key for the .year sort option.
        // Requires a strictly well-formed "YYYY-MM-DD" prefix (dashes in positions 4 and 7).
        // Accepts both "YYYY-MM-DD" and "YYYY-MM-DDTHH:MM:SSZ" — the optional time suffix
        // is handled by trying the full ISO 8601 formatter first, then the date-only one.
        // Any other format (malformed, empty, missing dashes) yields nil.
        self.releaseDateParsed = Self.parseReleaseDate(snapshot.releaseDate)
        
        // Recents Data
        self.dateAddedParsed = Self.parseDate(snapshot.dateAdded)
        self.lastWatchedParsed = Self.parseDate(snapshot.lastWatched)
        self.lastModifiedParsed = Self.parseDate(snapshot.lastModified)
        
        self.dateAddedFormatted = Self.formatDate(self.dateAddedParsed, includeDay: true)
        self.lastWatchedFormatted = Self.formatDate(self.lastWatchedParsed, includeDay: true)
        self.lastModifiedFormatted = Self.formatDate(self.lastModifiedParsed, includeDay: true)
        
        // Rotation date, via the shared helper in GlobalUtilities: the viewing
        // anniversary rounded up to the 1st of the following month. Films with any
        // specialSorting value are excluded from rotation entirely.
        // Reuses the already-computed self.lastWatchedParsed — no second parse needed.
        //
        // Stored UNCONDITIONALLY — this is deliberately not gated on the date having
        // already arrived. Everything this entry holds must be a pure function of the
        // snapshot, because entries are persisted to disk and, on the common startup
        // path (cache present, count matching), are trusted wholesale and never
        // recomputed. A value that depends on `Date()` therefore freezes at whatever
        // was true when the entry was written: gating here meant a film that crossed
        // its rotation date after that point kept a nil rotation date, and stayed
        // absent from "Recently Come Up for Rotation", until something else happened
        // to touch that particular film. The "has it arrived yet" test now lives in
        // recentFilmIDs(for:), which re-evaluates `Date()` on every call.
        if !snapshot.lastWatched.isEmpty && snapshot.specialSorting.isEmpty {
            let eligibility = rotationEligibilityDate(
                from: self.lastWatchedParsed,
                months: snapshot.rotationThreshold
            )
            self.rotationDate = eligibility
            self.rotationDateFormatted = eligibility.map { Self.formatDate($0, includeDay: false) }
        } else {
            self.rotationDate = nil
            self.rotationDateFormatted = nil
        }
        
        // Find most recent purchase date from release snapshots.
        // Also record whether any release is marked purchased at all (even without a date),
        // so the datePurchased sort can distinguish "purchased, no date" from "not purchased".
        var mostRecent: Date? = nil
        var anyPurchased = false
        var mostRecentByFormat: [String: Date] = [:]
        var formats: Set<String> = []
        for release in snapshot.releases {
            guard release.purchased else { continue }
            anyPurchased = true
            formats.insert(release.format)
            guard !release.purchaseDate.isEmpty else { continue }

            // parseDate() reports failure as Date.distantPast, and that value must not be
            // adopted as a purchase date. Doing so promoted a release whose purchaseDate
            // was present but unparseable into the "has a dated purchase" tier, carrying a
            // date of the year 1, which then sorted it ahead of every genuine purchase in
            // ascending order — and displayed it, via purchaseDateFormatted, as a real
            // date the user never entered. A malformed value is not a date; skipping it
            // leaves the release counted in `anyPurchased` only, which is exactly the
            // "purchased, date unknown" tier that case belongs in.
            let purchaseDate = Self.parseDate(release.purchaseDate)
            guard purchaseDate > Date.distantPast else { continue }

            if let current = mostRecent {
                if purchaseDate > current { mostRecent = purchaseDate }
            } else {
                mostRecent = purchaseDate
            }
            if let current = mostRecentByFormat[release.format], current >= purchaseDate { continue }
            mostRecentByFormat[release.format] = purchaseDate
        }
        self.mostRecentPurchaseDate = mostRecent
        self.hasPurchasedReleases = anyPurchased
        self.mostRecentPurchaseDateByFormat = mostRecentByFormat
        self.purchasedFormats = formats
        self.purchaseDateFormatted = mostRecent.map { Self.formatDate($0, includeDay: true) }
        
        // Search Cache Data — precomputed so a keystroke never re-normalizes the library.
        self.nameSearchKey = SearchText.key(snapshot.name)
        self.alternateTitleSearchKeys = snapshot.alternateTitle.map(SearchText.key).joined(separator: "\n")
    }

    // MARK: - Format-Scoped Purchase Access

    /// The most recent usable purchase date among this film's purchased releases of
    /// `format`, or of every format when `format` is nil.
    func mostRecentPurchaseDate(in format: ReleaseFormat?) -> Date? {
        guard let format else { return mostRecentPurchaseDate }
        return mostRecentPurchaseDateByFormat[format.rawValue]
    }

    /// Whether any release of `format` (of any format when nil) is marked purchased, dated
    /// or not.
    func hasPurchasedReleases(in format: ReleaseFormat?) -> Bool {
        guard let format else { return hasPurchasedReleases }
        return purchasedFormats.contains(format.rawValue)
    }

    // MARK: - Private Helpers
    
    // ISO 8601 formatter for "YYYY-MM-DDTHH:MM:SSZ" (full datetime, UTC).
    private static let releaseDateTimeStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
    
    // ISO 8601 formatter for "YYYY-MM-DD" (date-only, UTC).
    private static let releaseDateOnlyStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon).year().month().day()
    
    /// Parses a film's `releaseDate` field into a `Date` for use as a secondary sort
    /// key within the `.year` sort option. Returns `nil` if the value is empty,
    /// does not begin with a well-formed `YYYY-MM-DD` prefix (dashes required at
    /// positions 4 and 7), or cannot be decoded by either ISO 8601 style.
    ///
    /// Both "YYYY-MM-DD" and "YYYY-MM-DDTHH:MM:SSZ" are accepted; the time
    /// component is discarded for comparison purposes (only the calendar day matters).
    private static func parseReleaseDate(_ raw: String) -> Date? {
        guard raw.count >= 10 else { return nil }
        
        // Validate the "YYYY-MM-DD" prefix strictly: characters at index 4 and 7
        // must be dashes, and all digit positions must be ASCII digits.
        let chars = Array(raw.unicodeScalars)
        let isDigit: (Unicode.Scalar) -> Bool = { $0.value >= 48 && $0.value <= 57 }
        guard isDigit(chars[0]), isDigit(chars[1]), isDigit(chars[2]), isDigit(chars[3]),
              chars[4].value == 45,   // '-'
              isDigit(chars[5]), isDigit(chars[6]),
              chars[7].value == 45,   // '-'
              isDigit(chars[8]), isDigit(chars[9])
        else { return nil }
        
        // Attempt full datetime parse first (handles the "T12:00:00Z" suffix),
        // then fall back to the date-only formatter.
        if raw.count > 10, let date = try? releaseDateTimeStyle.parse(raw) {
            return date
        }
        // Use only the first 10 characters so a partially-malformed suffix after
        // the date segment (e.g. "1990-10-02 extra") doesn't cause a spurious failure.
        let dateOnly = String(raw.prefix(10))
        return try? releaseDateOnlyStyle.parse(dateOnly)
    }
    
    /// The one title sort key rule: leading punctuation and whitespace removed, then one
    /// leading article ("The ", "A ", "An ", any case) dropped. Shared by the Reports and
    /// DataViz sorts so every title ordering in the app agrees with the gallery's.
    static func stripArticles(_ title: String) -> String {
        // Strip any leading punctuation characters in a single pass — one allocation
        // rather than one per character. drop(while:) produces a Substring (no copy);
        // trimmingCharacters materializes a new String only once at the end.
        let specialChars = CharacterSet(charactersIn: "[]():.,-—")
        var result = String(
            title
                .unicodeScalars
                .drop(while: { specialChars.contains($0) || CharacterSet.whitespaces.contains($0) })
        )
        // After stripping leading punctuation, strip any residual leading whitespace
        // that separated punctuation from the first real character (e.g. "[ Title").
        // The drop(while:) above handles contiguous punctuation+space runs, but a
        // string like "(  Title" could leave a leading space. One trim is sufficient.
        result = result.trimmingCharacters(in: .whitespaces)

        for article in ["The ", "A ", "An "] {
            if let range = result.range(of: article, options: [.anchored, .caseInsensitive]) {
                return String(result[range.upperBound...])
            }
        }
        return result
    }
    
    // Reusable formatters (created once per call, not per film)
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()
    
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
    
    private static func formatDate(_ date: Date, includeDay: Bool) -> String {
        guard date > Date.distantPast else { return "" }
        return includeDay ? dayFormatter.string(from: date) : monthFormatter.string(from: date)
    }
    
    // Date parsing delegates to GlobalUtilities' canonical parseDate(from:) for
    // consistent format handling across the entire application.
    private static func parseDate(_ dateString: String) -> Date {
        guard !dateString.isEmpty else { return Date.distantPast }
        return Film_Tracker.parseDate(from: dateString) ?? Date.distantPast
    }
}

// MARK: - Sort Projection

extension FilmMetadata {
    /// The stored fields `MetadataCache.compare(_:_:by:purchaseFormat:)` reads, directly or
    /// through `mostRecentPurchaseDate(in:)` / `hasPurchasedReleases(in:)`.
    static let sortFieldNames: Set<String> = [
        "id", "titleKey", "titleStartsWithNumber", "year", "releaseDateParsed",
        "effectiveDuration", "dateAddedParsed", "lastWatchedParsed", "lastModifiedParsed",
        "rating", "viewCount", "mostRecentPurchaseDate", "hasPurchasedReleases",
        "mostRecentPurchaseDateByFormat", "purchasedFormats",
    ]

    /// Every other stored field: display strings, raw inputs and dates no comparator reads.
    /// The harness checks that the two sets together name every stored property exactly
    /// once, so a field added to the struct must be classified before that check passes.
    static let nonSortFieldNames: Set<String> = [
        "duration", "dateAddedRaw", "lastWatchedRaw", "lastModifiedRaw", "rotationDate",
        "dateAddedFormatted", "lastWatchedFormatted", "lastModifiedFormatted",
        "rotationDateFormatted", "purchaseDateFormatted", "nameSearchKey",
        "alternateTitleSearchKeys",
    ]

    /// True when every field in `sortFieldNames` is equal, so this entry and `other`
    /// compare identically against any third entry under every sort option. A change
    /// between two such entries cannot move the film in any library order (see
    /// `MetadataCache.reconcileLibraryOrders`).
    func sortsIdentically(to other: FilmMetadata) -> Bool {
        id == other.id
            && titleKey == other.titleKey
            && titleStartsWithNumber == other.titleStartsWithNumber
            && year == other.year
            && releaseDateParsed == other.releaseDateParsed
            && effectiveDuration == other.effectiveDuration
            && dateAddedParsed == other.dateAddedParsed
            && lastWatchedParsed == other.lastWatchedParsed
            && lastModifiedParsed == other.lastModifiedParsed
            && rating == other.rating
            && viewCount == other.viewCount
            && mostRecentPurchaseDate == other.mostRecentPurchaseDate
            && hasPurchasedReleases == other.hasPurchasedReleases
            && mostRecentPurchaseDateByFormat == other.mostRecentPurchaseDateByFormat
            && purchasedFormats == other.purchasedFormats
    }
}

// MARK: - Cache File Envelope
/// The on-disk representation of the metadata cache.
///
/// `FilmMetadata` holds values DERIVED from `FilmSnapshot` — parsed dates, sort
/// keys, pre-formatted display strings, rotation eligibility dates. When the rule
/// producing any of those changes, every entry already on disk is silently wrong,
/// and on the common startup path (cache present, entry count matching the film
/// count) nothing recomputes it: the file is trusted wholesale. Before this
/// envelope existed there was no way for the app to notice.
///
/// `schemaVersion` is that mechanism. Bump `currentSchemaVersion` whenever a
/// derived field's meaning changes, and the next launch discards the file and
/// performs a full rebuild from live snapshots — which `MemoryStore`'s existing
/// `cacheCount == 0` branch already does, with no special-case migration code.
///
/// Version 1 is the first envelope. Files written before it have a bare
/// `[UUID: FilmMetadata]` root and simply fail to decode as this type, taking the
/// same discard-and-rebuild path, which is exactly what they need: they predate
/// the month-rounding of rotation eligibility dates.
struct FilmMetadataCacheFile: Codable {
    /// Bump when any derived value in `FilmMetadata` changes meaning.
    /// Version 2 adds `viewCount` (recorded-viewing count) to every entry; files
    /// written at version 1 have no such field and cannot be decoded into the
    /// current type at all, so they take the discard-and-rebuild path.
    ///
    /// Version 3 changes the MEANING of an existing field rather than adding one:
    /// `mostRecentPurchaseDate` no longer absorbs an unparseable `purchaseDate` as
    /// `Date.distantPast`, so an entry written at version 2 can hold a year-1 purchase
    /// date that the current rule would never produce. This is the case the envelope
    /// exists for — nothing about such a file fails to decode, so without the version
    /// number it would be loaded and trusted, and the affected films would keep sorting
    /// and displaying wrongly until something else happened to touch them.
    ///
    /// Version 4 forces a one-time rebuild: `rotationDate` for films without an override
    /// follows Preferences.defaultRotationThreshold, and until the default-threshold
    /// refresh existed, changing that preference left every such entry on disk computed
    /// from the old default.
    ///
    /// Version 5: `titleKey` strips leading articles case-insensitively ("THE", "the").
    ///
    /// Version 6 adds `mostRecentPurchaseDateByFormat` and `purchasedFormats`, which the
    /// Date Last Purchased sort reads on the "Purchased 4K / Blu-ray / DVD" lists.
    ///
    /// Version 7 replaces the lowercased search strings with `SearchText.key` forms
    /// (`nameSearchKey`, `alternateTitleSearchKeys`), which fold diacritics and drop
    /// punctuation so a typed hyphen or a missing colon still finds the title.
    static let currentSchemaVersion = 7

    let schemaVersion: Int
    let entries: [UUID: FilmMetadata]
}

// MARK: - Metadata Cache
@MainActor
final class MetadataCache: Loggable {
    nonisolated static let logTag = "[MetadataCache]"
    
    static let shared = MetadataCache()
    
    // MARK: - Properties
    
    private(set) var metadata: [UUID: FilmMetadata] = [:] {
        didSet { metadataGeneration &+= 1 }
    }
    private let cacheURL: URL

    // MARK: - Library Orders
    //
    // Every comparator ends in a title tiebreak that ends in the film ID, so each sort
    // option is a strict TOTAL order over metadata entries. Under a total order, sorting
    // any subset of the library yields exactly the subsequence of the sorted library, and
    // the descending result is exactly the ascending one reversed. So each option's
    // ascending order over the whole library is built once, off the main actor, and every
    // later sort() of a view's films is a filter of it: O(N) instead of an
    // O(N log N) sort whose title comparisons (localizedStandardCompare) cost ~33 ms per
    // 1,400 films on the main thread, after every edit.
    //
    // Correctness rests on one rule: an order is used only while it describes the
    // CURRENT metadata. `metadataGeneration` moves on every mutation of `metadata` (the
    // didSet above, so no mutation path can miss it), and the orders are usable only when
    // `libraryOrdersGeneration` equals it. The single-film mutation paths repair the orders
    // in place (reconcileLibraryOrders) and bring the generation forward; any other
    // mutation leaves them stale, which sends sort() back to the full sort until a
    // background rebuild lands. A stale order is never read.

    /// One library order: a sort option, plus the purchase format for Date Last Purchased (the
    /// only option that reads it; nil for every other option, so they share one order).
    struct LibraryOrderKey: Hashable, Sendable {
        let option: SortOption
        let purchaseFormat: ReleaseFormat?

        init(_ option: SortOption, purchaseFormat: ReleaseFormat? = nil) {
            self.option = option
            self.purchaseFormat = option == .datePurchased ? purchaseFormat : nil
        }
    }

    /// Bumped by every mutation of `metadata`.
    private var metadataGeneration: UInt64 = 0
    /// The `metadataGeneration` every order in `libraryOrders` describes.
    private var libraryOrdersGeneration: UInt64 = .max
    /// Ascending orders over every film in `metadata`, by key.
    private var libraryOrders: [LibraryOrderKey: [UUID]] = [:]
    private var libraryOrderBuild: Task<Void, Never>?
    private var localeObserver: (any NSObjectProtocol)?

    /// Off for harness-isolated instances, whose sort scenarios exist to exercise the
    /// comparators directly (a permutation-invariance check served from a cached order
    /// would pass vacuously). Scenarios that test the orders turn it on.
    var usesLibraryOrders: Bool

    /// Below this many films the full sort is already cheap, and filtering a library-sized
    /// order would cost more than it saves. Either path yields the same array.
    private static let minimumIDsForLibraryOrder = 48
    /// The most sort-relevant film changes repaired in place between two builds, whether
    /// in one batch or across many mutations (an import adds films one at a time). Past it
    /// the orders are dropped and rebuilt in the background, which bounds the main-thread
    /// cost of a burst at a few milliseconds.
    private static let maximumReconciledChanges = 64
    /// Sort-relevant film changes repaired in place since the orders were last built.
    private var reconciledChangesSinceBuild = 0
    /// How long a rebuild waits for a burst of mutations to settle before starting.
    private static let libraryOrderBuildDelay: Duration = .milliseconds(400)

    private var libraryOrdersAreCurrent: Bool { libraryOrdersGeneration == metadataGeneration }
    
    private let maxFilmsPerSection = 200
    private let purchaseWindowDays = 90
    // Rotation window (days): how far back recentFilmIDs(for:) looks when building
    // the "Recently Come Up for Rotation" list, measured from each film's rotation
    // eligibility date. This is the sole owner of that cutoff — no other component
    // applies a second rotation-recency filter to these results, so there is nothing
    // for it to be kept in sync with.
    private let recentlyRotatedWindowDays = 60

    // MARK: - Recents Result Cache
    // Caches the sorted [UUID] result for each RecentsCategory so that repeated
    // navigation to the same category — and category picker changes — return instantly
    // without re-iterating the full metadata dictionary each time.
    // Invalidated whenever any film metadata entry changes (add, update, remove).
    private var recentsCategoryCache: [RecentsCategory: [UUID]] = [:]
    // The calendar day the cached results were computed on. The rotation and purchase
    // tabs filter against `Date()`, so their results expire at
    // midnight even when no film changes; cachedRecents(_:) drops the whole cache the
    // first time it is read on a later day.
    private var recentsCacheDay: Date?
    
    // MARK: - Initialization
    private init() {
        guard let dataFolder = Preferences.dataFolderURL else {
            // dataFolderURL is nil only if FileManager cannot resolve Application Support,
            // which cannot occur in a sandboxed app after ensureRequiredDirectoriesExist()
            // has run. Fall back to Application Support directly as a last resort.
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.cacheURL = appSupport.appendingPathComponent("metadata-cache.bin")
            self.usesLibraryOrders = Self.libraryOrdersEnabledAtLaunch
            observeLocaleChanges()
            return
        }
        self.cacheURL = dataFolder.appendingPathComponent("metadata-cache.bin")
        self.usesLibraryOrders = Self.libraryOrdersEnabledAtLaunch
        observeLocaleChanges()
    }

    /// DEBUG builds honor `-FTDisableLibraryOrders`, so a harness run can be repeated with
    /// every sort taking the full sort, for A/B comparison against the same suite.
    private static var libraryOrdersEnabledAtLaunch: Bool {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("-FTDisableLibraryOrders")
        #else
        return true
        #endif
    }

    /// Title comparisons are locale-dependent (localizedStandardCompare), so orders built
    /// under the previous locale are dropped and rebuilt.
    private func observeLocaleChanges() {
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MetadataCache.shared.dropLibraryOrders(reason: "locale changed") }
        }
    }

    #if DEBUG
    /// Creates an isolated instance for harness use, disconnected from `shared`.
    ///
    /// The harness needs to load a synthetic corpus and sort it through the real
    /// production code path — `rebuild(from:)` then `sort(_:by:direction:)` — without
    /// that corpus displacing the live `shared.metadata` the rest of the app is reading,
    /// and without any possibility of it reaching `metadata-cache.bin`. An isolated
    /// instance gives both: nothing else holds a reference to it, `load()` is never
    /// called on it, and `save()` is never called on it either (this class owns no
    /// timer — every persistence path in the app runs through MemoryStore, which knows
    /// only about `shared`). `cacheURL` is still assigned because it is a `let`; it
    /// points at a file this instance will never open.
    init(isolatedForTesting cacheURL: URL) {
        self.cacheURL = cacheURL
        self.usesLibraryOrders = false
    }
    #endif
    
    // MARK: - Load/Save
    // STARTUP: Disk I/O and plist decoding now run on a background
    // thread via Task.detached, enabling true parallelism with other startup work.
    /// Set once load() has run, whatever the outcome. Guards against a second call
    /// overwriting `metadata` with on-disk content — which, if it arrived after
    /// validateCacheAndFinalize() had already rebuilt the dictionary from fresh snapshots,
    /// would replace correct derived data with the stale copy the rebuild just superseded.
    private var hasLoadedFromDisk = false

    /// The cache file's read and decode, started by beginEarlyLoad and consumed by load().
    private var earlyRead: Task<([UUID: FilmMetadata]?, String?), Never>?

    /// Starts load()'s read and decode now, off the main thread, so it overlaps the AppKit
    /// launch work before `initializeApp()` runs. Only the read moves: every assignment and
    /// log line still happens in load(), and nothing writes the file before load() runs,
    /// so an early read reads the same bytes. Called once, from FilmTrackerApp.init.
    func beginEarlyLoad() {
        guard earlyRead == nil, !hasLoadedFromDisk else { return }
        let url = cacheURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        earlyRead = Task.detached(priority: .userInitiated) { Self.readCacheFile(at: url) }
    }

    /// Reads and decodes the cache file. Returns a tuple so the actual error description
    /// is available on the MainActor side for logging. Returning only `nil`
    /// (the prior approach) silently discarded the failure reason, making
    /// cache corruption or decode errors impossible to diagnose from logs.
    /// A tuple is used rather than Result<_, String> because Result requires
    /// its Failure type to conform to Error, which String does not.
    private nonisolated static func readCacheFile(at url: URL) -> ([UUID: FilmMetadata]?, String?) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let file = try decoder.decode(FilmMetadataCacheFile.self, from: data)

            // A file written by a build with a different notion of what the
            // derived fields mean is not usable, and is not repairable either —
            // every entry in it would have to be recomputed, which is precisely
            // what a full rebuild does. Reported as an error string so the caller
            // logs the reason and leaves `metadata` empty, which routes into
            // MemoryStore's existing "no existing MetadataCache" rebuild branch.
            guard file.schemaVersion == FilmMetadataCacheFile.currentSchemaVersion else {
                return (nil, "schema version \(file.schemaVersion) ≠ expected \(FilmMetadataCacheFile.currentSchemaVersion) — discarding for rebuild")
            }

            return (file.entries, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func load() async {
        guard !hasLoadedFromDisk else {
            Self.log("Cache already loaded — skipping")
            return
        }
        hasLoadedFromDisk = true

        let start = Date()
        let url = cacheURL
        
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Self.log("No existing cache file")
            return
        }
        
        // Usually already under way since FilmTrackerApp.init (see beginEarlyLoad).
        let read = earlyRead ?? Task.detached(priority: .userInitiated) { Self.readCacheFile(at: url) }
        earlyRead = nil
        let (loaded, loadError) = await read.value
        
        if let loaded {
            self.metadata = loaded
            // Assigning `metadata` wholesale is exactly the kind of mutation the recents
            // invalidation contract covers, and it was the one assignment that omitted it.
            // rebuild(from:) and incrementalUpdate(from:) both invalidate; this path did
            // not, which left a real hole: recentsCategoryCache memoizes per-category
            // results and is otherwise cleared only by film-level mutations, so any
            // recentFilmIDs(for:) call that landed before this load completed cached an EMPTY
            // ordering that survived for the remainder of the session. That is reachable
            // during the startup window, when the window is on screen and interactive
            // while the caches are still loading.
            //
            // DataCoordinator.loadFilms now gates ahead of RecentsCategory.orderedFilmIDs()
            // so the primary caller can no longer reach it early; this invalidation is the
            // self-healing backstop that makes the cache correct by construction for any
            // caller, present or future, rather than by the discipline of its callers.
            invalidateRecentsCache()
            dropLibraryOrders(reason: "cache loaded")
            let duration = Date().timeIntervalSince(start)
            Self.log("Loaded cache with \(loaded.count) entries in \(Fmt.fixed(duration * 1000, 1))ms")
        } else {
            Self.log("ERROR: Failed to load cache — \(loadError ?? "unknown error")")
        }
    }
    
    func save() async {
        let start = Date()

        // Capture value-type copies before leaving MainActor so the detached
        // task has no shared-mutable-state access to self.
        let snapshot = metadata
        let url = cacheURL

        // The detached task returns a tuple so the actual error description
        // is available on the MainActor side for logging, matching the same
        // pattern used by load(). Returning only a Bool discarded the failure
        // reason, making encode/write errors impossible to diagnose from logs.
        // A tuple is used rather than Result<_, String> because Result requires
        // its Failure type to conform to Error, which String does not.
        let (saveSuccess, saveError): (Bool, String?) = await Task.detached(priority: .utility) {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let file = FilmMetadataCacheFile(
                    schemaVersion: FilmMetadataCacheFile.currentSchemaVersion,
                    entries: snapshot
                )
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
                return (true, nil)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value

        let duration = Date().timeIntervalSince(start)
        if saveSuccess {
            Self.log("Saved cache with \(snapshot.count) entries in \(Fmt.fixed(duration * 1000, 1))ms")
        } else {
            Self.log("ERROR: Failed to save cache — \(saveError ?? "unknown error")")
        }
    }
    
    // NOTE: This class does NOT own a throttled-save timer. The unified throttled save
    // lives in MemoryStore.scheduleThrottledSave(), which flushes both MetadataCache and
    // MemoryStoreCache together on every mutation. A dedicated timer here would create
    // two independent 2-second throttles writing to metadata-cache.bin, producing
    // redundant disk I/O and a race window at shutdown where either timer could wake
    // after the final flush and overwrite it. All MetadataCache mutation paths
    // (addFilm, updateFilm, removeFilm, removeFilms, rebuild, incrementalUpdate) have
    // a corresponding MemoryStore mutation path that invokes the unified throttled save,
    // so persistence is always scheduled in lockstep.
    //
    // For shutdown, AppDelegate.performGracefulShutdown() calls
    // DataCoordinator.saveImmediately() → MemoryStore.saveImmediately(), which calls
    // MetadataCache.shared.save() directly (no throttle involved).
    
    // MARK: - Build from Snapshots
    
    /// Full rebuild from a dictionary of FilmSnapshots.
    /// Called at startup when no cache exists or when counts are severely mismatched.
    /// Heavy construction work (date parsing, string ops) runs on a background thread;
    /// only the final dictionary assignment touches MainActor state.
    func rebuild(from snapshots: [UUID: FilmSnapshot]) async {
        let start = Date()

        // Capture the snapshots dictionary as a value (FilmSnapshot is Sendable).
        // The entire construction loop runs detached so MainActor is not blocked.
        let newCache = await Task.detached(priority: .userInitiated) {
            var result: [UUID: FilmMetadata] = [:]
            result.reserveCapacity(snapshots.count)
            for (id, snapshot) in snapshots {
                result[id] = FilmMetadata(from: snapshot)
            }
            return result
        }.value

        self.metadata = newCache
        invalidateRecentsCache()
        dropLibraryOrders(reason: "cache rebuilt")

        let duration = Date().timeIntervalSince(start)
        Self.log("Rebuilt cache with \(newCache.count) entries in \(Fmt.fixed(duration * 1000, 1))ms")
    }
    
    /// Incremental update: adds missing entries and removes stale ones.
    /// Much faster than a full rebuild when only a small delta has changed.
    ///
    /// New `FilmMetadata` entries are constructed on a background thread so that
    /// date parsing and string operations do not block `MainActor`. Only the final
    /// dictionary mutation — which touches `self.metadata`, an actor-isolated property —
    /// runs back on `MainActor`.
    func incrementalUpdate(from snapshots: [UUID: FilmSnapshot]) async {
        let start = Date()

        let existingKeys = Set(metadata.keys)
        let snapshotKeys = Set(snapshots.keys)

        // Remove entries for deleted films (cheap dictionary mutation, stays on MainActor).
        let toRemove = existingKeys.subtracting(snapshotKeys)
        for id in toRemove {
            metadata.removeValue(forKey: id)
        }

        // Build new entries for films that have no existing metadata entry.
        let toAddIDs = snapshotKeys.subtracting(existingKeys)
        if !toAddIDs.isEmpty {
            // Extract only the snapshots that actually need new metadata entries.
            // Passing the full `snapshots` dictionary to the detached task would copy
            // every FilmSnapshot across an actor boundary even though only the `toAddIDs`
            // subset is used inside the task. For a library with many films this is a
            // substantial unnecessary copy; slicing first keeps the transfer lean.
            var toAddSnapshots: [UUID: FilmSnapshot] = [:]
            toAddSnapshots.reserveCapacity(toAddIDs.count)
            for id in toAddIDs {
                if let snapshot = snapshots[id] {
                    toAddSnapshots[id] = snapshot
                }
            }

            let newEntries = await Task.detached(priority: .userInitiated) {
                var result: [UUID: FilmMetadata] = [:]
                result.reserveCapacity(toAddSnapshots.count)
                for (id, snapshot) in toAddSnapshots {
                    result[id] = FilmMetadata(from: snapshot)
                }
                return result
            }.value

            // Merge the newly-built entries back into the actor-isolated dictionary.
            for (id, entry) in newEntries {
                metadata[id] = entry
            }
        }

        if !toRemove.isEmpty || !toAddIDs.isEmpty {
            invalidateRecentsCache()
            dropLibraryOrders(reason: "incremental update")
        }

        let duration = Date().timeIntervalSince(start)
        Self.log("Incremental update: +\(toAddIDs.count) -\(toRemove.count) in \(Fmt.fixed(duration * 1000, 1))ms (total: \(metadata.count))")
    }
    
    // MARK: - Recents Cache Invalidation
    
    /// Clears all cached recents category results. Must be called after any metadata mutation
    /// (add, update, remove) so that the next recents lookup re-computes from current data.
    private func invalidateRecentsCache() {
        recentsCategoryCache.removeAll()
    }

    /// The cached result for `category`, or nil when it must be recomputed — including
    /// when the cache was filled on an earlier calendar day.
    private func cachedRecents(_ category: RecentsCategory) -> [UUID]? {
        let today = Calendar.current.startOfDay(for: Date())
        if recentsCacheDay != today {
            recentsCategoryCache.removeAll()
            recentsCacheDay = today
        }
        return recentsCategoryCache[category]
    }
    
    // MARK: - Update Operations
    
    func addFilm(_ snapshot: FilmSnapshot) {
        store([FilmMetadata(from: snapshot)])
    }
    
    func updateFilm(_ snapshot: FilmSnapshot) {
        store([FilmMetadata(from: snapshot)])
    }
    
    /// Stores entries built elsewhere, for rare batch refreshes whose inputs live outside
    /// the snapshot (a changed global preference). The caller builds them off the main
    /// actor and drops any whose film changed meanwhile, which `rebuild(from:)` cannot do.
    func setEntries(_ entries: [FilmMetadata]) {
        store(entries)
    }

    func removeFilms(_ ids: Set<UUID>) {
        let ordersWereCurrent = libraryOrdersAreCurrent
        var changes: [LibraryOrderChange] = []
        for id in ids {
            if let old = metadata.removeValue(forKey: id) {
                changes.append(LibraryOrderChange(id: id, old: old, new: nil))
            }
        }
        invalidateRecentsCache()
        reconcileLibraryOrders(changes, ordersWereCurrent: ordersWereCurrent)
    }

    /// Writes `entries` and repairs the library orders for them.
    private func store(_ entries: [FilmMetadata]) {
        let ordersWereCurrent = libraryOrdersAreCurrent
        var changes: [LibraryOrderChange] = []
        changes.reserveCapacity(entries.count)
        for entry in entries {
            let old = metadata.updateValue(entry, forKey: entry.id)
            changes.append(LibraryOrderChange(id: entry.id, old: old, new: entry))
        }
        invalidateRecentsCache()
        reconcileLibraryOrders(changes, ordersWereCurrent: ordersWereCurrent)
    }

    // MARK: - Library Order Maintenance

    /// One film's entry before and after a mutation; nil where the film was absent.
    struct LibraryOrderChange {
        let id: UUID
        let old: FilmMetadata?
        let new: FilmMetadata?

        var movesFilm: Bool {
            guard let old, let new else { return true }
            return !old.sortsIdentically(to: new)
        }
    }

    /// Brings every library order forward across `changes`, which have already been
    /// applied to `metadata`. Called by every single-film mutation path.
    ///
    /// Each changed film is removed and re-inserted by binary search. Every other film's
    /// entry is unchanged, so the rest of the order is still sorted under the current
    /// comparator, and under a total order there is exactly one position the film can
    /// occupy: the result is the array a full sort would produce. A change that leaves
    /// every sort field equal (`sortsIdentically`) cannot move the film, and is skipped.
    ///
    /// Orders that were already stale before the mutation, or a batch too large to repair
    /// cheaply, are dropped and rebuilt in the background instead.
    private func reconcileLibraryOrders(_ changes: [LibraryOrderChange], ordersWereCurrent: Bool) {
        guard usesLibraryOrders else { return }
        guard ordersWereCurrent, !libraryOrders.isEmpty else {
            dropLibraryOrders(reason: nil)
            return
        }
        let moving = Set(changes.filter(\.movesFilm).map(\.id))
        guard reconciledChangesSinceBuild + moving.count <= Self.maximumReconciledChanges else {
            dropLibraryOrders(reason: "\(reconciledChangesSinceBuild + moving.count) film changes since the last build")
            return
        }
        if !moving.isEmpty {
            guard let repaired = Self.repositioning(moving, in: libraryOrders, using: metadata) else {
                dropLibraryOrders(reason: "order missing an entry")
                return
            }
            libraryOrders = repaired
            reconciledChangesSinceBuild += moving.count
        }
        libraryOrdersGeneration = metadataGeneration
    }

    /// `orders` with every film in `changedIDs` moved to where `metadata` now sorts it:
    /// all of them removed first (a changed film left at its old position would break the
    /// sortedness the binary search relies on), then each one still in `metadata`
    /// inserted at its one sorted position under its CURRENT entry. Nil when an order holds
    /// an ID `metadata` has no entry for, which would mean it no longer describes `metadata`.
    nonisolated private static func repositioning(_ changedIDs: Set<UUID>,
                                                  in orders: [LibraryOrderKey: [UUID]],
                                                  using metadata: [UUID: FilmMetadata]) -> [LibraryOrderKey: [UUID]]? {
        var result: [LibraryOrderKey: [UUID]] = [:]
        for (key, order) in orders {
            var updated: [UUID]
            if changedIDs.count == 1, let id = changedIDs.first {
                updated = order
                if let index = updated.firstIndex(of: id) { updated.remove(at: index) }
            } else {
                updated = order.filter { !changedIDs.contains($0) }
            }
            for id in changedIDs {
                guard let entry = metadata[id] else { continue }
                // First position whose film does not sort before the new entry.
                var low = 0, high = updated.count
                while low < high {
                    let mid = (low + high) / 2
                    guard let other = metadata[updated[mid]] else { return nil }
                    if compare(other, entry, by: key.option, purchaseFormat: key.purchaseFormat) {
                        low = mid + 1
                    } else {
                        high = mid
                    }
                }
                updated.insert(entry.id, at: low)
            }
            result[key] = updated
        }
        return result
    }

    /// Discards every order and schedules a rebuild. Safe to call at any time: until the
    /// rebuild lands, sort() takes the full sort.
    func dropLibraryOrders(reason: String?) {
        guard usesLibraryOrders else { return }
        if !libraryOrders.isEmpty, let reason {
            Self.log("Library orders dropped (\(reason)) — rebuilding in the background")
        }
        libraryOrders.removeAll()
        libraryOrdersGeneration = .max
        reconciledChangesSinceBuild = 0
        scheduleLibraryOrderBuild()
    }

    /// Starts a background build of every wanted order not already current, unless one is
    /// already pending. Coalesces bursts: the build waits `libraryOrderBuildDelay` first.
    private func scheduleLibraryOrderBuild() {
        guard usesLibraryOrders, libraryOrderBuild == nil else { return }
        libraryOrderBuild = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.libraryOrderBuildDelay)
            guard let self, !Task.isCancelled else { return }
            let again = await self.buildLibraryOrders()
            self.libraryOrderBuild = nil
            if again { self.scheduleLibraryOrderBuild() }
        }
    }

    /// The keys a build covers: every option over all formats, and Date Last Purchased scoped
    /// to each format (the "Purchased 4K / Blu-ray / DVD" lists).
    private static let wantedLibraryOrderKeys: Set<LibraryOrderKey> =
        Set(SortOption.allCases.map { LibraryOrderKey($0) })
            .union(ReleaseFormat.allCases.map { LibraryOrderKey(.datePurchased, purchaseFormat: $0) })

    /// Builds the missing orders off the main actor and installs them. Returns true when
    /// another pass is needed (the library changed too much while this one ran).
    private func buildLibraryOrders() async -> Bool {
        let installed = libraryOrdersAreCurrent ? Set(libraryOrders.keys) : []
        let missing = Self.wantedLibraryOrderKeys.subtracting(installed)
        guard !missing.isEmpty, !metadata.isEmpty else { return false }

        let snapshot = metadata
        let builtGeneration = metadataGeneration
        let start = Date()
        let built: [LibraryOrderKey: [UUID]] = await Task.detached(priority: .utility) {
            var result: [LibraryOrderKey: [UUID]] = [:]
            for key in missing {
                result[key] = snapshot.keys.sorted {
                    Self.compare(snapshot[$0]!, snapshot[$1]!, by: key.option, purchaseFormat: key.purchaseFormat)
                }
            }
            return result
        }.value

        #if DEBUG
        libraryOrderBuildDidFinishForTesting?()
        #endif
        guard usesLibraryOrders else { return false }
        var orders = built
        if builtGeneration != metadataGeneration {
            // The library changed while the build ran. Bring the new orders forward by
            // the difference between the snapshot they were built from and `metadata` now,
            // exactly as a mutation would have.
            var changed: Set<UUID> = []
            for (id, entry) in metadata {
                if let old = snapshot[id], old.sortsIdentically(to: entry) { continue }
                changed.insert(id)
            }
            for id in snapshot.keys where metadata[id] == nil { changed.insert(id) }
            guard changed.count <= Self.maximumReconciledChanges,
                  let repaired = Self.repositioning(changed, in: built, using: metadata) else {
                return true
            }
            orders = repaired
        }
        // Orders that are current stay (they agree with these: one total order, one
        // array); stale ones are discarded.
        if !libraryOrdersAreCurrent { libraryOrders.removeAll() }
        libraryOrders.merge(orders) { _, new in new }
        libraryOrdersGeneration = metadataGeneration
        reconciledChangesSinceBuild = 0
        Self.log("Built \(orders.count) library order(s) over \(snapshot.count) films in \(Fmt.fixed(Date().timeIntervalSince(start) * 1000, 1))ms")
        return false
    }

    /// `filmIDs` in the order `key` sorts them, read from the library order, or nil when
    /// that order cannot answer: none is current, `filmIDs` is too short to gain from it,
    /// holds a duplicate, or holds an ID with no metadata entry (the full sort orders
    /// those by a degenerate rule an order does not encode).
    private func sortFromLibraryOrder(_ filmIDs: [UUID], key: LibraryOrderKey,
                                      direction: SortDirection) -> [UUID]? {
        guard usesLibraryOrders, filmIDs.count >= Self.minimumIDsForLibraryOrder,
              libraryOrdersAreCurrent, let order = libraryOrders[key] else { return nil }
        let ascending: [UUID]
        if filmIDs.count == order.count {
            // Possibly the whole library: then the order is the answer as it stands.
            let members = Set(filmIDs)
            guard members.count == filmIDs.count,
                  filmIDs.allSatisfy({ metadata[$0] != nil }) else { return nil }
            ascending = order
        } else {
            let members = Set(filmIDs)
            guard members.count == filmIDs.count else { return nil }
            let filtered = order.filter { members.contains($0) }
            // Shorter only when some ID has no entry (the order holds every entry).
            guard filtered.count == filmIDs.count else { return nil }
            ascending = filtered
        }
        #if DEBUG
        libraryOrderHitsForTesting += 1
        #endif
        return direction == .ascending ? ascending : ascending.reversed()
    }

    /// After a full sort: keeps its result as the library order when it sorted the whole
    /// library, and otherwise makes sure a background build is on its way.
    private func adoptLibraryOrder(_ sorted: [UUID], from filmIDs: [UUID],
                                   key: LibraryOrderKey, direction: SortDirection) {
        guard usesLibraryOrders else { return }
        if filmIDs.count == metadata.count, Set(filmIDs).count == filmIDs.count,
           filmIDs.allSatisfy({ metadata[$0] != nil }) {
            if !libraryOrdersAreCurrent {
                libraryOrders.removeAll()
                libraryOrdersGeneration = metadataGeneration
                reconciledChangesSinceBuild = 0
            }
            libraryOrders[key] = direction == .ascending ? sorted : sorted.reversed()
        }
        // Small sorts (a Film Queue section, Up Next) land here on every refresh; only an
        // order actually missing is worth a build.
        if !libraryOrdersAreCurrent || libraryOrders.count < Self.wantedLibraryOrderKeys.count {
            scheduleLibraryOrderBuild()
        }
    }

    #if DEBUG
    /// Harness hook: runs after a build's detached sort returns and before its result is
    /// installed, so a scenario can mutate the library in exactly that window.
    var libraryOrderBuildDidFinishForTesting: (() -> Void)?

    /// Harness access: how many sort() calls a library order answered.
    var libraryOrderHitsForTesting = 0

    /// Harness access: the current order for `key`, or nil when there is none or it is stale.
    func libraryOrderForTesting(_ key: LibraryOrderKey) -> [UUID]? {
        libraryOrdersAreCurrent ? libraryOrders[key] : nil
    }

    /// Harness access: builds every wanted order now, as the background rebuild would.
    func buildLibraryOrdersForTesting() async {
        libraryOrderBuild?.cancel()
        libraryOrderBuild = nil
        while await buildLibraryOrders() {}
    }

    /// Harness access: the comparator itself, for reference sorts.
    nonisolated static func referenceSort(_ ids: [UUID], by option: SortOption, direction: SortDirection,
                                          purchaseFormat: ReleaseFormat?,
                                          using metadata: [UUID: FilmMetadata]) -> [UUID] {
        _performSort(ids, by: option, direction: direction, purchaseFormat: purchaseFormat, using: metadata)
    }
    #endif
    
    // MARK: - Sorting Operations
    
    nonisolated private static func compareTitles(_ data1: FilmMetadata, _ data2: FilmMetadata) -> Bool {
        if data1.titleStartsWithNumber != data2.titleStartsWithNumber {
            return !data1.titleStartsWithNumber
        }
        
        let cmp = data1.titleKey.localizedStandardCompare(data2.titleKey)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        
        // If titles are identical, use year as the next tiebreaker
        let year1 = Int(data1.year) ?? 0
        let year2 = Int(data2.year) ?? 0
        if year1 != year2 { return year1 < year2 }

        // Same title, same year (a deliberate Film1/Film2 pair, or a true duplicate):
        // the film ID is the last resort, so every comparator ending here is a TOTAL
        // order. Without it such a pair compared equal and kept whatever relative order
        // the caller passed in — and callers pass `Array(films.keys)` or a list's ID
        // set, whose iteration order is reseeded every launch, so the pair swapped
        // places from one launch to the next.
        return data1.id.uuidString < data2.id.uuidString
    }
    
    /// Compares two films by a date field, falling back to a title comparison when the
    /// dates are equal. Used by the dateAdded, lastViewed, and dateModified sort cases so
    /// the three share one definition.
    ///
    /// A film with no date carries `Date.distantPast`, and this function deliberately does
    /// NOT special-case it: "no date" simply IS the earliest possible value, and it sorts
    /// that way. Ascending therefore leads with the films that have never been watched /
    /// added / modified and ends with the most recent; descending reverses that completely,
    /// putting the most recent first and the dateless ones at the end. That is the behavior
    /// a user reads off the direction label, and it needs no sentinel rule to produce.
    ///
    /// This replaces an earlier design that pinned undated films to the end in BOTH
    /// directions. That rule did not survive contact with `_performSort`, which reversed
    /// direction by negating this function's result — negation inverted the sentinel along
    /// with everything else, so undated films actually LED in descending order, the exact
    /// opposite of what the rule intended and of what its comment claimed. Both halves are
    /// now gone: the sentinel here, and the negation there.
    ///
    /// The title tiebreak is applied unconditionally, including when both dates are absent.
    /// It previously returned a bare `false` for that case, which left every undated film
    /// equivalent to every other and their relative order therefore unspecified — it varied
    /// with whatever order the caller happened to pass the IDs in. Every sibling comparator
    /// ends in `compareTitles`; this one now does too.
    ///
    /// - Parameters:
    ///   - date1: Parsed date for the first film (`Date.distantPast` means "no date").
    ///   - date2: Parsed date for the second film (`Date.distantPast` means "no date").
    ///   - data1: Full metadata record for the first film (used for title tiebreak).
    ///   - data2: Full metadata record for the second film (used for title tiebreak).
    /// - Returns: `true` if film 1 sorts before film 2 in ASCENDING order. Descending is
    ///   produced by the caller swapping the operands, never by negating this result.
    nonisolated private static func compareDates(
        _ date1: Date, _ date2: Date,
        tiebreak data1: FilmMetadata, _ data2: FilmMetadata
    ) -> Bool {
        if date1 != date2 { return date1 < date2 }
        return compareTitles(data1, data2)
    }

    /// Compares two films for the datePurchased sort option.
    ///
    /// Purchase state forms three ordered tiers, read as "how recently was this acquired":
    ///
    ///   Tier 0 — no purchased releases at all      (never acquired → earliest)
    ///   Tier 1 — purchased, but no usable date     (acquired at some unknown past point)
    ///   Tier 2 — purchased with a date             (ordered among themselves by that date)
    ///
    /// Ascending runs 0 → 1 → 2, ending with the most recent purchase. Descending reverses
    /// the whole sequence, so the newest purchases lead and the never-purchased films trail.
    /// This is the same principle `compareDates` applies to an absent date, extended to the
    /// two distinct kinds of absence a purchase record can have.
    ///
    /// This replaces an earlier design in which the tier boundaries were fixed — dated
    /// purchases led in both directions, and only the ordering within that tier reversed.
    /// That rule was deliberate, but it made this the one sort option whose direction
    /// control did not reverse what the user could see at the top of the grid, and it
    /// required an early return that bypassed `_performSort`'s direction handling. Neither
    /// is needed now: this is an ordinary ascending comparator like every other, and
    /// direction is applied uniformly by the caller.
    ///
    /// Every tier and date is read within `format` — only purchases of that release format
    /// count — or across all formats when it is nil. A "Purchased 4K" list passes `.uhd4K`,
    /// so a film whose 4K copy was bought in 2020 and a Blu-ray last month sorts, and bands,
    /// as a 2020 purchase there (see ViewIdentifier.purchaseFormatScope).
    ///
    /// - Returns: `true` if film 1 sorts before film 2 in ASCENDING order.
    nonisolated private static func comparePurchaseDates(
        _ data1: FilmMetadata, _ data2: FilmMetadata, in format: ReleaseFormat?
    ) -> Bool {
        let tier1 = purchaseTier(data1, in: format)
        let tier2 = purchaseTier(data2, in: format)
        if tier1 != tier2 { return tier1 < tier2 }

        // Same tier. Only tier 2 carries a value to order by; the other two are
        // distinguished by nothing but their titles.
        if tier1 == 2,
           let date1 = data1.mostRecentPurchaseDate(in: format),
           let date2 = data2.mostRecentPurchaseDate(in: format),
           date1 != date2 {
            return date1 < date2
        }
        return compareTitles(data1, data2)
    }

    /// The purchase tier a film belongs to within `format` (all formats when nil):
    /// 0 = never purchased, 1 = purchased with no usable date, 2 = purchased with a date.
    ///
    /// Non-private so the debug harness asserts tier ordering against this exact definition
    /// rather than re-deriving it from `mostRecentPurchaseDate`/`hasPurchasedReleases` on
    /// its own. A test that restates the rule it is checking will agree with a broken
    /// implementation as readily as a correct one.
    nonisolated static func purchaseTier(_ data: FilmMetadata, in format: ReleaseFormat? = nil) -> Int {
        if data.mostRecentPurchaseDate(in: format) != nil { return 2 }
        return data.hasPurchasedReleases(in: format) ? 1 : 0
    }

    /// Synchronous sort — used for interactive reloads and cache-hit paths.
    ///
    /// Answered from the library order for `option` when one is current (a filter of it,
    /// identical to the full sort; see Library Orders above), and by the full sort
    /// otherwise.
    ///
    /// `purchaseFormat` scopes the Date Last Purchased option to one release format (the view's
    /// `ViewIdentifier.purchaseFormatScope`); every other option ignores it.
    func sort(_ filmIDs: [UUID], by option: SortOption, direction: SortDirection,
              purchaseFormat: ReleaseFormat? = nil) -> [UUID] {
        guard !filmIDs.isEmpty else { return [] }
        let start = Date()
        let key = LibraryOrderKey(option, purchaseFormat: purchaseFormat)
        let sorted: [UUID]
        if let ordered = sortFromLibraryOrder(filmIDs, key: key, direction: direction) {
            sorted = ordered
        } else {
            sorted = Self._performSort(filmIDs, by: option, direction: direction,
                                       purchaseFormat: purchaseFormat, using: metadata)
            adoptLibraryOrder(sorted, from: filmIDs, key: key, direction: direction)
        }
        let duration = Date().timeIntervalSince(start)
        if duration > 0.01 {
            Self.log("Sorted \(filmIDs.count) IDs in \(Fmt.fixed(duration * 1000, 1))ms")
        }
        return sorted
    }

    /// Async sort — used at startup to keep MainActor free during the initial view pre-warm.
    /// Captures metadata as a lightweight value copy on MainActor, then sorts on a background
    /// thread so the main thread is not blocked while waiting for the result.
    /// Its only caller is the All Films pre-warm, which has no purchase format scope.
    func sortAsync(_ filmIDs: [UUID], by option: SortOption, direction: SortDirection) async -> [UUID] {
        guard !filmIDs.isEmpty else { return [] }
        // Copy the dictionary header on MainActor (O(1) for Swift's CoW dicts).
        // The actual element data is shared until the detached task modifies it,
        // which it never does — it only reads, so no copy-on-write is triggered.
        let metadataSnapshot = metadata
        let generation = metadataGeneration
        let start = Date()
        let sorted = await Task.detached(priority: .userInitiated) {
            Self._performSort(filmIDs, by: option, direction: direction,
                              purchaseFormat: nil, using: metadataSnapshot)
        }.value
        // Sorted against the metadata as it was; only that metadata may adopt it.
        if generation == metadataGeneration {
            adoptLibraryOrder(sorted, from: filmIDs, key: LibraryOrderKey(option), direction: direction)
        }
        let duration = Date().timeIntervalSince(start)
        if duration > 0.01 {
            Self.log("Async-sorted \(filmIDs.count) IDs in \(Fmt.fixed(duration * 1000, 1))ms")
        }
        return sorted
    }

    /// Shared sort implementation — pure function, works on any metadata snapshot.
    /// Separated so both sync and async paths share the same logic with no duplication.
    /// Marked nonisolated so that sortAsync's Task.detached can call it without
    /// hopping back to MainActor — otherwise the background sort would silently
    /// re-acquire MainActor, defeating the purpose of the detached task.
    nonisolated private static func _performSort(_ filmIDs: [UUID], by option: SortOption,
                                     direction: SortDirection,
                                     purchaseFormat: ReleaseFormat?,
                                     using metadata: [UUID: FilmMetadata]) -> [UUID] {
        return filmIDs.sorted { id1, id2 in
            guard let data1 = metadata[id1], let data2 = metadata[id2] else {
                // Degenerate path: an ID with no metadata entry. Ordered by UUID purely so
                // the predicate stays a valid ordering rather than because the result means
                // anything. Left outside the direction handling below deliberately — there
                // is no meaningful "reverse" of an arbitrary tiebreak, and involving it
                // would only make an already-impossible state harder to reason about.
                return id1.uuidString < id2.uuidString
            }

            // Direction is applied by SWAPPING THE OPERANDS, never by negating the result.
            //
            // The two are equivalent for any pair the comparator considers distinct, but
            // they differ precisely where it considers them equal: negation turns
            // "a is not before b" into "a is before b", so for an equivalent pair both
            // less(a, b) and less(b, a) come back true — and less(a, a) comes back true as
            // well. That is an asymmetric, non-irreflexive predicate, which violates the
            // strict-weak-ordering contract `Array.sorted(by:)` documents as a requirement
            // and whose result it leaves unspecified when unmet.
            //
            // Swapping is exact instead of approximate: comparing (b, a) is the definition
            // of reversal, it preserves the tiebreak reversal the old negation produced for
            // distinct elements, and equal elements correctly compare false in both
            // directions. It also removes the need for any comparator to bypass this step —
            // `comparePurchaseDates` previously returned early to protect a tier rule from
            // the negation, and no longer has to.
            return direction == .ascending
                ? compare(data1, data2, by: option, purchaseFormat: purchaseFormat)
                : compare(data2, data1, by: option, purchaseFormat: purchaseFormat)
        }
    }

    /// The single ascending comparison for every sort option: `true` when `data1` sorts
    /// before `data2`. Direction is not a parameter and must not become one — reversal is
    /// the caller's job, performed by swapping arguments (see `_performSort`). Keeping this
    /// function direction-blind is what guarantees every option reverses identically and
    /// that none can quietly opt out of the rule.
    nonisolated private static func compare(_ data1: FilmMetadata, _ data2: FilmMetadata,
                                            by option: SortOption,
                                            purchaseFormat: ReleaseFormat?) -> Bool {
        switch option {
        case .title:
            return compareTitles(data1, data2)

        case .year:
            let year1 = Int(data1.year) ?? 0
            let year2 = Int(data2.year) ?? 0
            if year1 != year2 {
                return year1 < year2
            } else if let rd1 = data1.releaseDateParsed, let rd2 = data2.releaseDateParsed {
                // Both films have a parseable releaseDate — use it as the intermediate
                // tiebreaker within the same releaseYear, falling back to title if equal.
                return rd1 != rd2 ? rd1 < rd2 : compareTitles(data1, data2)
            } else if data1.releaseDateParsed != nil {
                // Only film 1 has a releaseDate — it sorts before the undated film 2.
                return true
            } else if data2.releaseDateParsed != nil {
                // Only film 2 has a releaseDate — it sorts before the undated film 1.
                return false
            } else {
                // Neither film has a parseable releaseDate — fall back to title sort.
                return compareTitles(data1, data2)
            }

        case .duration:
            // effectiveDuration resolves to editedDuration when the film is marked
            // as edited and that field holds a valid positive value; otherwise it
            // mirrors the regular duration field. The sort therefore naturally
            // reflects the runtime the user actually experiences.
            //
            // Compared in WHOLE MINUTES, not raw milliseconds, so the title tiebreak
            // below is actually reachable. Durations are stored in milliseconds but the
            // app is a minute-granularity application throughout: every duration entered
            // through the UI is built by DurationHelpers.hoursAndMinutesToMilliseconds
            // (an exact multiple of 60,000), and every duration displayed is truncated to
            // hours and minutes by RSBHelpers.formattedDuration. Only IMPORTED metadata
            // carries sub-minute precision — and comparing on it meant a dozen films all
            // showing "1 hour 19 minutes" were ordered by a residue of milliseconds the
            // user cannot see and did not choose, which reads as no ordering at all.
            // Truncating to the granularity the app itself presents makes films that
            // display the same runtime genuinely equal here, so they fall through to the
            // title comparison exactly as films sharing a rating or a view count do.
            let ms1 = Int(data1.effectiveDuration) ?? 0
            let ms2 = Int(data2.effectiveDuration) ?? 0

            // Films with no recorded runtime at all form their own leading tier, ahead of
            // the minute comparison rather than inside it. Truncating to minutes would
            // otherwise make a film whose duration was never filled in exactly equal to a
            // 40-second one, interleaving the two by title — and the duration divider bands
            // label those two things differently ("No Duration" vs "Under 1:00"), so an
            // interleaved run would break the contiguity GallerySectioning requires and cost
            // the view its bands entirely. The tier keeps sort and bands describing the same
            // partition. Like every other rule here it is direction-blind: _performSort
            // reverses by swapping operands, so undated films lead ascending and trail
            // descending, exactly as compareDates' undated films do.
            if (ms1 <= 0) != (ms2 <= 0) { return ms1 <= 0 }

            let dur1 = ms1 / 60_000
            let dur2 = ms2 / 60_000
            return dur1 != dur2 ? dur1 < dur2 : compareTitles(data1, data2)

        case .dateAdded:
            return compareDates(data1.dateAddedParsed, data2.dateAddedParsed,
                                tiebreak: data1, data2)

        case .lastViewed:
            return compareDates(data1.lastWatchedParsed, data2.lastWatchedParsed,
                                tiebreak: data1, data2)

        case .viewCount:
            // Mirrors the .rating case: a plain integer comparison with a title
            // tiebreak, so ascending places films with no recorded viewings first
            // and the most-watched films at the end of the grid.
            return data1.viewCount != data2.viewCount
                ? data1.viewCount < data2.viewCount
                : compareTitles(data1, data2)

        case .rating:
            return data1.rating != data2.rating ? data1.rating < data2.rating : compareTitles(data1, data2)

        case .dateModified:
            return compareDates(data1.lastModifiedParsed, data2.lastModifiedParsed,
                                tiebreak: data1, data2)

        case .datePurchased:
            return comparePurchaseDates(data1, data2, in: purchaseFormat)
        }
    }
    
    // MARK: - Recents Query Operations

    /// The films one Recents tab shows, newest first and capped at `maxFilmsPerSection`.
    /// Memoized per category until the next metadata mutation or midnight (see
    /// `cachedRecents`); every other ordering rule lives in `newestFirst`.
    func recentFilmIDs(for category: RecentsCategory) -> [UUID] {
        if let cached = cachedRecents(category) { return cached }
        let start = Date()
        let now = Date()

        let result: [UUID]
        switch category {
        case .recentlyAdded:
            result = newestFirst { $0.dateAddedParsed > .distantPast ? $0.dateAddedParsed : nil }

        case .recentlyUpdated:
            result = newestFirst { $0.lastModifiedParsed > .distantPast ? $0.lastModifiedParsed : nil }

        case .recentlyViewed:
            // Same-day viewings fall back to the most recent edit before the title.
            result = newestFirst({ $0.lastWatchedParsed > .distantPast ? $0.lastWatchedParsed : nil },
                                 tiebreak: {
                                     $0.lastModifiedParsed != $1.lastModifiedParsed
                                         ? $0.lastModifiedParsed > $1.lastModifiedParsed
                                         : Self.compareTitles($0, $1)
                                 })

        case .recentlyRotated:
            guard let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -recentlyRotatedWindowDays,
                                                     to: now) else { return [] }
            // The cached rotation date is the film's eligibility date whether or not it
            // has arrived (see FilmMetadata.init). Both halves of the window are therefore
            // applied here, against a `Date()` read on this call: not yet arrived →
            // excluded; arrived more than `recentlyRotatedWindowDays` ago → no longer
            // "recent". Rotation dates are always the 1st of a month, so ties are the norm
            // rather than the exception; the title tiebreak is what gives each month an order.
            result = newestFirst { data in
                data.rotationDate.flatMap { $0 <= now && $0 >= cutoff ? $0 : nil }
            }

        case .recentlyPurchased:
            guard let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -purchaseWindowDays,
                                                     to: now) else { return [] }
            result = newestFirst { data in
                data.mostRecentPurchaseDate.flatMap { $0 >= cutoff ? $0 : nil }
            }
        }

        recentsCategoryCache[category] = result
        let duration = Date().timeIntervalSince(start)
        Self.log("Recents \(category.rawValue): \(result.count) films in \(Fmt.fixed(duration * 1000, 1))ms")
        return result
    }

    /// Every film `date` returns a value for, ordered by that value newest first (then by
    /// `tiebreak`, which defaults to the title order), capped at `maxFilmsPerSection`.
    private func newestFirst(
        _ date: (FilmMetadata) -> Date?,
        tiebreak: (FilmMetadata, FilmMetadata) -> Bool = MetadataCache.compareTitles
    ) -> [UUID] {
        let dated = metadata.values.compactMap { data in date(data).map { (data, $0) } }
        return Array(dated
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : tiebreak($0.0, $1.0) }
            .prefix(maxFilmsPerSection)
            .map { $0.0.id })
    }

    // MARK: - Formatted Date Access
    
    /// `String`-backed and `Hashable` so callers can use a case as a stable,
    /// comparable key rather than only as a switch subject. `GalleryView` builds
    /// `GallerySubtitleProvider.kind` from the raw value, which is what lets
    /// `GallerySubview` tell one KIND of subtitle from another across a Recents
    /// sub-tab switch (the provider stays non-nil throughout, so nil-ness alone
    /// cannot distinguish them). Raw values are the case names verbatim; nothing
    /// persists them, so they carry no compatibility obligation.
    enum DateType: String, Hashable, Sendable {
        case dateAdded
        case lastWatched
        case lastModified
        case rotationDate
        case purchaseDate
    }
    
    func getFormattedDate(for filmID: UUID, type: DateType) -> String? {
        guard let data = metadata[filmID] else { return nil }
        
        switch type {
        case .dateAdded:
            return data.dateAddedFormatted.isEmpty ? nil : data.dateAddedFormatted
        case .lastWatched:
            return data.lastWatchedFormatted.isEmpty ? nil : data.lastWatchedFormatted
        case .lastModified:
            return data.lastModifiedFormatted.isEmpty ? nil : data.lastModifiedFormatted
        case .rotationDate:
            return data.rotationDateFormatted
        case .purchaseDate:
            return data.purchaseDateFormatted
        }
    }
    
    // MARK: - Preference Change Handling
    //
    // `rotationDate` depends on Preferences.defaultRotationThreshold for every film
    // without an override, so a change to that default makes those entries stale.
    // DataCoordinator.handleDefaultRotationThresholdChangeIfNeeded() refreshes them
    // through MemoryStore.refreshRotationDerivedMetadata() → setEntries(_:).
    
    // MARK: - Search Cache Access
    
    /// A film's title and alternate titles in `SearchText.key` form, or nil if the film
    /// is not in the cache.
    func getSearchKeys(for filmID: UUID) -> (name: String, alternateTitles: String)? {
        guard let data = metadata[filmID] else { return nil }
        return (name: data.nameSearchKey, alternateTitles: data.alternateTitleSearchKeys)
    }
}
