// MARK: - MetadataCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Persistent cache of metadata derived from FilmSnapshot values, such as sort keys, parsed dates, and
// recent-activity data. It also maintains the library orders that make sorting fast.


import Foundation
import os

// MARK: - Film Metadata Structure
struct FilmMetadata: Codable {
    let id: UUID
    
    // Sorting Data
    let titleKey: String
    let titleStartsWithNumber: Bool
    let year: String
    let duration: String
    // The duration the duration sort reads: editedDuration when set, otherwise `duration`. Raw milliseconds.
    let effectiveDuration: String
    let dateAddedRaw: String
    let lastWatchedRaw: String
    let rating: Int
    // Number of recorded viewings (calendarTable entries). Backs the .viewCount sort.
    let viewCount: Int
    let lastModifiedRaw: String
    // Parsed releaseDate, a secondary key for the .year sort. Nil when absent or not a well-formed "YYYY-MM-DD" prefix.
    let releaseDateParsed: Date?
    
    // Recents Data
    let dateAddedParsed: Date
    let lastWatchedParsed: Date
    let lastModifiedParsed: Date
    let rotationDate: Date?
    let mostRecentPurchaseDate: Date?
    
    // True if any release is marked purchased, dated or not. The datePurchased sort uses it to rank undated
    // purchases between dated ones and never-purchased films.

    let hasPurchasedReleases: Bool

    // Purchase data per release format, keyed by ReleaseFormat raw value. Read through mostRecentPurchaseDate(in:)
    // and hasPurchasedReleases(in:). A combo pack's Blu-ray child counts as Blu-ray, as it does for Purchased Blu-ray.
    let mostRecentPurchaseDateByFormat: [String: Date]
    let purchasedFormats: Set<String>

    // Pre-formatted date strings for display
    let dateAddedFormatted: String
    let lastWatchedFormatted: String
    let lastModifiedFormatted: String
    let rotationDateFormatted: String?
    let purchaseDateFormatted: String?
    
    // Search keys, in SearchText.key form. Alternate titles are joined by a newline, which no key contains, so a
    // query cannot match across two titles.
    let nameSearchKey: String
    let alternateTitleSearchKeys: String
    /// The synopsis (`descriptionText`) in the same form, for the `#synopsis` token.
    let synopsisSearchKey: String
    /// The credits, studios, tags, genre and notes in the same form, for the text tokens.
    let textSearchKeys: FilmTextSearchKeys

    /// Creates a FilmMetadata entry from a FilmSnapshot.
    /// All data is sourced from value types; no model objects are accessed.
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
        
        // Parse releaseDate for the .year sort's secondary key.
        self.releaseDateParsed = Self.parseReleaseDate(snapshot.releaseDate)
        
        // Recents Data
        self.dateAddedParsed = Self.parseDate(snapshot.dateAdded)
        self.lastWatchedParsed = Self.parseDate(snapshot.lastWatched)
        self.lastModifiedParsed = Self.parseDate(snapshot.lastModified)
        
        self.dateAddedFormatted = Self.formatDate(self.dateAddedParsed, includeDay: true)
        self.lastWatchedFormatted = Self.formatDate(self.lastWatchedParsed, includeDay: true)
        self.lastModifiedFormatted = Self.formatDate(self.lastModifiedParsed, includeDay: true)
        
        // Rotation eligibility date: the viewing anniversary rounded up to the 1st of the next month. Films with a
        // specialSorting value are excluded. It is stored unconditionally and never gated on `Date()`, because entries
        // are persisted and trusted at startup. recentFilmIDs(for:) checks whether the date has arrived.
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

            // parseDate() returns Date.distantPast on failure. A malformed purchase date must not be adopted, or it
            // would sort as year 1. Such a release still counts in anyPurchased.
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
        self.synopsisSearchKey = SearchText.key(snapshot.descriptionText)
        self.textSearchKeys = FilmTextSearchKeys(snapshot)
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
    
    /// Parses `releaseDate` for the `.year` sort's secondary key. Returns nil for an empty value, a malformed
    /// "YYYY-MM-DD" prefix, or an undecodable value. Any time part is ignored.
    private static func parseReleaseDate(_ raw: String) -> Date? {
        guard raw.count >= 10 else { return nil }
        
        // Require a strict "YYYY-MM-DD" prefix: digits, with dashes at indexes 4 and 7.
        let chars = Array(raw.unicodeScalars)
        let isDigit: (Unicode.Scalar) -> Bool = { $0.value >= 48 && $0.value <= 57 }
        guard isDigit(chars[0]), isDigit(chars[1]), isDigit(chars[2]), isDigit(chars[3]),
              chars[4].value == 45,   // '-'
              isDigit(chars[5]), isDigit(chars[6]),
              chars[7].value == 45,   // '-'
              isDigit(chars[8]), isDigit(chars[9])
        else { return nil }
        
        // Try the full datetime first, then the date-only style.
        if raw.count > 10, let date = try? releaseDateTimeStyle.parse(raw) {
            return date
        }
        // Only the first 10 characters are used for date-only parsing.
        let dateOnly = String(raw.prefix(10))
        return try? releaseDateOnlyStyle.parse(dateOnly)
    }
    
    /// The one title sort key rule: leading punctuation and whitespace removed, then one
    /// leading article ("The ", "A ", "An ", any case) dropped. Shared by the Reports and
    /// DataViz sorts so every title ordering in the app agrees with the gallery's.
    static func stripArticles(_ title: String) -> String {
        // Strip leading punctuation and whitespace in one pass.
        let specialChars = CharacterSet(charactersIn: "[]():.,-—")
        var result = String(
            title
                .unicodeScalars
                .drop(while: { specialChars.contains($0) || CharacterSet.whitespaces.contains($0) })
        )
        // Trim any whitespace left after the punctuation.
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
    
    // Delegates to the shared parseDate(from:) in GlobalUtilities, so formats are handled consistently.
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
        "alternateTitleSearchKeys", "synopsisSearchKey", "textSearchKeys",
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
/// The on-disk form of the metadata cache.
///
/// `FilmMetadata` holds values derived from `FilmSnapshot`. If the rule producing a value changes, entries already on
/// disk are wrong, and the common startup path trusts the file without recomputing. `schemaVersion` guards against
/// this: bump `currentSchemaVersion` whenever a derived field's meaning changes. The next launch then discards the file
/// and rebuilds from live snapshots, using MemoryStore's existing rebuild path.
///
/// Version 1 is the first envelope. Older files have a bare dictionary root, fail to decode, and are rebuilt.
struct FilmMetadataCacheFile: Codable {
    /// Bump when any derived value in `FilmMetadata` changes meaning. Each version below forces a rebuild.
    ///
    /// v2 adds `viewCount`. v3: `mostRecentPurchaseDate` no longer absorbs an unparseable purchase date as
    /// `Date.distantPast`. v4: `rotationDate` follows the default rotation threshold. v5: `titleKey` strips leading
    /// articles case-insensitively. v6 adds `mostRecentPurchaseDateByFormat` and `purchasedFormats`. v7: search keys
    /// use `SearchText.key` forms. v8 adds `synopsisSearchKey`. v9: `rotationDate` is computed in the Gregorian calendar,
    /// and the file gains `libraryOrders`. v10 adds `textSearchKeys`.
    static let currentSchemaVersion = 10

    let schemaVersion: Int
    let entries: [UUID: FilmMetadata]
    /// Saved library orders for `entries`, keyed by `LibraryOrderKey.storageName`. They are never trusted as read:
    /// `MetadataCache.validatedOrders` keeps only those that match a fresh build. Optional, so older files still load.
    var libraryOrders: [String: Data]? = nil
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
    // Every comparator ends in a title tiebreak and then the film ID, so each sort option is a strict total order.
    // Under a total order, sorting any subset yields the subsequence of the full sorted library, and descending is the
    // ascending order reversed. So each option's ascending order over the whole library is built once, off the main
    // actor. Later sort() calls filter that order, which is O(N) instead of a full sort.
    //
    // An order is used only while it matches the current metadata. `metadataGeneration` advances on every change to
    // `metadata`, and an order is usable only when `libraryOrdersGeneration` equals it. Single-film mutations repair
    // the orders in place (reconcileLibraryOrders). Other mutations leave them stale, so sort() falls back to the full
    // sort until a background rebuild lands. A stale order is never read.

    /// One library order: a sort option, plus the purchase format for Date Last Purchased (the
    /// only option that reads it; nil for every other option, so they share one order).
    struct LibraryOrderKey: Hashable, Sendable {
        let option: SortOption
        let purchaseFormat: ReleaseFormat?

        init(_ option: SortOption, purchaseFormat: ReleaseFormat? = nil) {
            self.option = option
            self.purchaseFormat = option == .datePurchased ? purchaseFormat : nil
        }

        /// How the key is written in the cache file: the option's raw value, and for a
        /// format-scoped Date Last Purchased, "|" and the format's.
        var storageName: String {
            purchaseFormat.map { "\(option.rawValue)|\($0.rawValue)" } ?? option.rawValue
        }

        /// The key `storageName` names, or nil for anything this build does not write
        /// (an option or format since renamed, or a format on an option that ignores it).
        init?(storageName: String) {
            let parts = storageName.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let option = SortOption(rawValue: String(parts[0])) else { return nil }
            var format: ReleaseFormat?
            if parts.count == 2 {
                guard let parsed = ReleaseFormat(rawValue: String(parts[1])) else { return nil }
                format = parsed
            }
            self.init(option, purchaseFormat: format)
            guard self.storageName == storageName else { return nil }
        }
    }

    /// Bumped by every mutation of `metadata`.
    private var metadataGeneration: UInt64 = 0
    /// The `metadataGeneration` every order in `libraryOrders` describes.
    private var libraryOrdersGeneration: UInt64 = .max
    /// Ascending orders over every film in `metadata`, by key.
    private var libraryOrders: [LibraryOrderKey: [UUID]] = [:]
    private var libraryOrderBuild: Task<Void, Never>?

    /// Disabled for harness-isolated instances, which exercise the comparators directly. Harness scenarios that test
    /// the orders turn it on.
    var usesLibraryOrders: Bool

    /// Below this many films the full sort is already cheap, and filtering a library-sized
    /// order would cost more than it saves. Either path yields the same array.
    private static let minimumIDsForLibraryOrder = 48
    /// Maximum sort-relevant changes repaired in place between builds. Past this, the orders are dropped and rebuilt.
    private static let maximumReconciledChanges = 64
    /// Sort-relevant film changes repaired in place since the orders were last built.
    private var reconciledChangesSinceBuild = 0
    /// How long a rebuild waits for a burst of mutations to settle before starting.
    private static let libraryOrderBuildDelay: Duration = .milliseconds(400)

    private var libraryOrdersAreCurrent: Bool { libraryOrdersGeneration == metadataGeneration }
    
    private let maxFilmsPerSection = 200
    private let purchaseWindowDays = 90
    // Days back from now that the Recently Come Up for Rotation list covers. This is the only place that cutoff is set.
    private let recentlyRotatedWindowDays = 60

    // MARK: - Recents Result Cache
    // Sorted [UUID] results per RecentsCategory, so repeated navigation returns at once. Cleared on any metadata change.
    private var recentsCategoryCache: [RecentsCategory: [UUID]] = [:]
    // Day the cached results were computed on. Rotation and purchase results depend on `Date()`, so they expire at midnight.
    private var recentsCacheDay: Date?
    
    // MARK: - Initialization
    private init() {
        guard let dataFolder = Preferences.dataFolderURL else {
            // Fallback for an unavailable data folder, which is not expected once launch setup has run.
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.cacheURL = appSupport.appendingPathComponent("metadata-cache.bin")
            self.usesLibraryOrders = Self.libraryOrdersEnabledAtLaunch
            return
        }
        self.cacheURL = dataFolder.appendingPathComponent("metadata-cache.bin")
        self.usesLibraryOrders = Self.libraryOrdersEnabledAtLaunch
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

    #if DEBUG
    /// Creates an instance for harness use, disconnected from `shared`. It never loads or saves the real cache, and
    /// `cacheURL` is only a placeholder that it never opens.
    ///
    /// The harness loads a synthetic corpus and sorts it through the production `rebuild(from:)` and `sort`, without
    /// affecting `shared`.
    init(isolatedForTesting cacheURL: URL) {
        self.cacheURL = cacheURL
        self.usesLibraryOrders = false
    }
    #endif
    
    // MARK: - Load/Save
    // STARTUP: disk I/O and plist decoding run on a background task, in parallel with other startup work.
    /// Set once load() has run, whatever the outcome. A second call must not overwrite `metadata` with stale disk content.
    private var hasLoadedFromDisk = false

    /// The cache file's read and decode, started by beginEarlyLoad and consumed by load().
    private var earlyRead: Task<CacheFileRead, Never>?

    /// Starts the read and decode early, off the main thread, so they overlap AppKit's launch work. Called once, from
    /// FilmTrackerApp.init. Only the read moves. Nothing writes the file before load() runs, so the bytes read are the same.
    func beginEarlyLoad() {
        guard earlyRead == nil, !hasLoadedFromDisk else { return }
        let url = cacheURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        earlyRead = Task.detached(priority: .userInitiated) { Self.readCacheFile(at: url) }
    }

    /// The early read's start and end, in LaunchTimeline milliseconds, set by the read.
    private nonisolated static let readStamps = OSAllocatedUnfairLock<(start: Double, end: Double)?>(initialState: nil)

    /// Reads and decodes the cache file. The result carries any error text, so the caller can log why a read failed.
    private nonisolated static func readCacheFile(at url: URL) -> CacheFileRead {
        let start = LaunchTimeline.now()
        defer { readStamps.withLock { $0 = (start, LaunchTimeline.now()) } }
        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let file = try decoder.decode(FilmMetadataCacheFile.self, from: data)

            // A file with a different schema version cannot be repaired, so it is discarded and rebuilt. Returning an
            // error leaves `metadata` empty, which routes to MemoryStore's rebuild branch.
            guard file.schemaVersion == FilmMetadataCacheFile.currentSchemaVersion else {
                return CacheFileRead(error: "schema version \(file.schemaVersion) ≠ expected \(FilmMetadataCacheFile.currentSchemaVersion) — discarding for rebuild")
            }

            // Validated here, on the read's background thread, which launch does not wait on.
            let validationStart = ContinuousClock.now
            let validated = validatedOrders(file.libraryOrders ?? [:], for: file.entries)
            return CacheFileRead(entries: file.entries, orders: validated.orders,
                                 rejectedOrders: validated.rejected,
                                 validation: ContinuousClock.now - validationStart)
        } catch {
            return CacheFileRead(error: error.localizedDescription)
        }
    }

    /// What `readCacheFile` hands back: the entries, the saved library orders that proved
    /// valid for them, how many saved orders did not, and why the read failed if it did.
    private struct CacheFileRead: Sendable {
        var entries: [UUID: FilmMetadata]?
        var orders: [LibraryOrderKey: [UUID]] = [:]
        var rejectedOrders = 0
        var validation: Duration = .zero
        var error: String?
    }

    /// The saved orders that exactly match what `compare` builds over `entries`.
    ///
    /// Each must hold every entry once, and each adjacent pair must compare in order. Because `compare` is a strict total
    /// order, a match proves equality rather than suggesting it. Orders from a build with a different comparator, title
    /// rules, or collation fail and are rebuilt.
    nonisolated private static func validatedOrders(_ stored: [String: Data],
                                                    for entries: [UUID: FilmMetadata]) -> (orders: [LibraryOrderKey: [UUID]], rejected: Int) {
        var orders: [LibraryOrderKey: [UUID]] = [:]
        var rejected = 0
        for (name, data) in stored {
            guard let key = LibraryOrderKey(storageName: name), wantedLibraryOrderKeys.contains(key),
                  orders[key] == nil, let ids = unpackedIDs(data), ids.count == entries.count,
                  Set(ids).count == ids.count, isStrictlyAscending(ids, by: key, in: entries) else {
                rejected += 1
                continue
            }
            orders[key] = ids
        }
        return (orders, rejected)
    }

    nonisolated private static func isStrictlyAscending(_ ids: [UUID], by key: LibraryOrderKey,
                                                        in entries: [UUID: FilmMetadata]) -> Bool {
        var previous: FilmMetadata?
        for id in ids {
            guard let entry = entries[id] else { return false }
            if let previous, !compare(previous, entry, by: key.option, purchaseFormat: key.purchaseFormat) {
                return false
            }
            previous = entry
        }
        return true
    }

    /// Film IDs as 16 raw bytes each, read back without parsing.
    nonisolated private static func packedIDs(_ ids: [UUID]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(ids.count * 16)
        for id in ids {
            let u = id.uuid
            bytes += [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        }
        return Data(bytes)
    }

    nonisolated private static func unpackedIDs(_ data: Data) -> [UUID]? {
        guard data.count % 16 == 0 else { return nil }
        let b = [UInt8](data)
        var ids: [UUID] = []
        ids.reserveCapacity(b.count / 16)
        var i = 0
        while i < b.count {
            ids.append(UUID(uuid: (b[i], b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], b[i + 6], b[i + 7],
                                   b[i + 8], b[i + 9], b[i + 10], b[i + 11], b[i + 12], b[i + 13], b[i + 14], b[i + 15])))
            i += 16
        }
        return ids
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
        let result = await read.value
        let loaded = result.entries, loadError = result.error
        if let stamps = Self.readStamps.withLock({ $0 }) {
            LaunchTimeline.mark("metadataReadStart", at: stamps.start)
            LaunchTimeline.mark("metadataReadDone", at: stamps.end)
        }
        
        if let loaded {
            self.metadata = loaded
            onDiskGeneration = metadataGeneration
            onDiskOrderKeys = Set(result.orders.keys)
            // Assigning `metadata` wholesale needs the same Recents invalidation as rebuild(from:). Without it, a Recents
            // query made before this load finished could cache an empty result for the rest of the session. DataCoordinator
            // also gates Recents loads, so this is a backstop.
            invalidateRecentsCache()
            installSavedLibraryOrders(result.orders, rejected: result.rejectedOrders, validation: result.validation)
            let duration = Date().timeIntervalSince(start)
            Self.log("Loaded cache with \(loaded.count) entries in \(Fmt.fixed(duration * 1000, 1))ms")
        } else {
            Self.log("ERROR: Failed to load cache — \(loadError ?? "unknown error")")
        }
    }
    
    /// Writes `metadata` to disk, unless the file already holds this generation. A quit with no edits writes nothing.
    ///
    /// Saves run one at a time, in call order, so an older write cannot land after a newer one.
    func save() async {
        let previous = saveInFlight
        let current = Task {
            await previous?.value
            await self.write()
        }
        saveInFlight = current
        await current.value
    }

    /// The `metadataGeneration` the file on disk holds, or nil when that is not known
    /// (nothing loaded or saved yet, or a save failed or is under way).
    private var onDiskGeneration: UInt64?
    /// The library orders the file holds for `onDiskGeneration` (valid ones, as read).
    private var onDiskOrderKeys: Set<LibraryOrderKey> = []
    private var saveInFlight: Task<Void, Never>?

    private func write() async {
        let start = Date()

        // Captured together, on MainActor: the generation names exactly these entries, and
        // the orders are saved only while they describe them.
        let generation = metadataGeneration
        let orders = libraryOrdersAreCurrent ? libraryOrders : [:]
        let orderKeys = Set(orders.keys)
        let url = cacheURL
        // The file must still exist. Orders built since the last save are also changes.
        if generation == onDiskGeneration, orderKeys.isSubset(of: onDiskOrderKeys),
           FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            Self.log("Save skipped: cache on disk is current (\(metadata.count) entries)")
            return
        }
        onDiskGeneration = nil

        // Capture value-type copies before leaving MainActor so the detached
        // task has no shared-mutable-state access to self.
        let snapshot = metadata

        // The detached task returns the error text, so the caller can log why a write failed.
        let (saveSuccess, saveError): (Bool, String?) = await Task.detached(priority: .utility) {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let file = FilmMetadataCacheFile(
                    schemaVersion: FilmMetadataCacheFile.currentSchemaVersion,
                    entries: snapshot,
                    libraryOrders: Dictionary(orders.map { ($0.key.storageName, Self.packedIDs($0.value)) }, uniquingKeysWith: { first, _ in first })
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
            onDiskGeneration = generation
            onDiskOrderKeys = orderKeys
            Self.log("Saved cache with \(snapshot.count) entries and \(orders.count) library order(s) in \(Fmt.fixed(duration * 1000, 1))ms")
        } else {
            Self.log("ERROR: Failed to save cache — \(saveError ?? "unknown error")")
        }
    }
    
    // This class has no throttled-save timer. MemoryStore.scheduleThrottledSave() saves MetadataCache and
    // MemoryStoreCache together, so there is one timer and no write race at shutdown. AppDelegate.performGracefulShutdown()
    // calls DataCoordinator.saveImmediately(), which reaches save() through MemoryStore.

    // MARK: - Build from Snapshots
    
    /// Rebuilds all entries from `snapshots`. Called when the cache is empty, or after a slow-path load. Entries are
    /// built off the main actor, and only the final assignment runs on it.
    func rebuild(from snapshots: [UUID: FilmSnapshot]) async {
        let start = Date()

        // Built off MainActor, across the cores (see buildEntries).
        let newCache = await Self.buildEntries(snapshots)

        self.metadata = newCache
        invalidateRecentsCache()
        dropLibraryOrders(reason: "cache rebuilt")

        let duration = Date().timeIntervalSince(start)
        Self.log("Rebuilt cache with \(newCache.count) entries in \(Fmt.fixed(duration * 1000, 1))ms")
    }
    
    /// Builds an entry for every snapshot, off MainActor, in parallel chunks.
    ///
    /// Builds an entry for each snapshot in parallel chunks, off the main actor. `FilmMetadata(from:)` is a pure function
    /// of its snapshot, so this is safe. Chunks of at least 64 films keep task overhead small.
    nonisolated private static func buildEntries(_ snapshots: [UUID: FilmSnapshot]) async -> [UUID: FilmMetadata] {
        let pairs = Array(snapshots)
        let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, max(1, pairs.count / 64))
        let chunkSize = (pairs.count + chunkCount - 1) / max(1, chunkCount)
        return await withTaskGroup(of: [(UUID, FilmMetadata)].self) { group in
            for start in stride(from: 0, to: pairs.count, by: max(1, chunkSize)) {
                let range = start..<min(start + chunkSize, pairs.count)
                group.addTask(priority: .userInitiated) {
                    pairs[range].map { ($0.key, FilmMetadata(from: $0.value)) }
                }
            }
            var result = [UUID: FilmMetadata](minimumCapacity: pairs.count)
            for await chunk in group {
                for (id, entry) in chunk { result[id] = entry }
            }
            return result
        }
    }

    /// The synchronous counterpart of `buildEntries`, for batches the caller needs before it returns, such as
    /// MemoryStore.updateFilms. It builds across the cores with `concurrentPerform`, and inline below 128 films.
    nonisolated private static func buildEntriesNow(_ snapshots: [FilmSnapshot]) -> [FilmMetadata] {
        guard snapshots.count >= 128 else { return snapshots.map { FilmMetadata(from: $0) } }
        let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, snapshots.count / 64)
        let chunkSize = (snapshots.count + chunkCount - 1) / chunkCount
        let chunks = OSAllocatedUnfairLock<[[FilmMetadata]]>(initialState: Array(repeating: [], count: chunkCount))
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let range = (chunk * chunkSize)..<min((chunk + 1) * chunkSize, snapshots.count)
            let built = snapshots[range].map { FilmMetadata(from: $0) }
            chunks.withLock { $0[chunk] = built }
        }
        return chunks.withLock { $0.flatMap { $0 } }
    }

    /// Adds entries for new films and removes entries for deleted ones. New entries are built off the main actor.
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
            // Pass only the snapshots that need new entries, to avoid copying the rest across the actor boundary.
            var toAddSnapshots: [UUID: FilmSnapshot] = [:]
            toAddSnapshots.reserveCapacity(toAddIDs.count)
            for id in toAddIDs {
                if let snapshot = snapshots[id] {
                    toAddSnapshots[id] = snapshot
                }
            }

            let newEntries = await Self.buildEntries(toAddSnapshots)

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
        let today = AppCalendar.current.startOfDay(for: Date())
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

    /// Batch counterpart of updateFilm(_:), with one library-order repair for the whole batch.
    func updateFilms(_ snapshots: [FilmSnapshot]) {
        store(Self.buildEntriesNow(snapshots))
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

    /// Updates every library order for `changes`, which are already applied to `metadata`. Each changed film is removed
    /// and reinserted by binary search. A change that leaves every sort field equal (`sortsIdentically`) cannot move the
    /// film, so it is skipped. Stale orders, and batches too large to repair cheaply, are dropped and rebuilt.
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

    /// Adopts the saved orders, already validated against the entries. Launch starts with current orders instead of
    /// sorting on the startup path.
    private func installSavedLibraryOrders(_ orders: [LibraryOrderKey: [UUID]], rejected: Int, validation: Duration) {
        guard usesLibraryOrders else { return }
        libraryOrders = orders
        libraryOrdersGeneration = metadataGeneration
        reconciledChangesSinceBuild = 0
        Self.log("Installed \(orders.count) saved library order(s)\(rejected > 0 ? ", \(rejected) rejected" : "") — validated in \(validation.formattedMilliseconds)")
        if orders.count < Self.wantedLibraryOrderKeys.count { scheduleLibraryOrderBuild() }
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
    nonisolated private static let wantedLibraryOrderKeys: Set<LibraryOrderKey> =
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
            // The library changed during the build, so the built orders are brought forward by the difference.
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
        // Current orders agree with the built ones, since each order is unique. Stale orders are discarded.
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
        // Small sorts land here on every refresh. Only a missing order is worth building.
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
        
        let cmp = data1.titleKey.englishStandardCompare(data2.titleKey)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        
        // If titles are identical, use year as the next tiebreaker
        let year1 = Int(data1.year) ?? 0
        let year2 = Int(data2.year) ?? 0
        if year1 != year2 { return year1 < year2 }

        // Same title and year. The film ID is the last tiebreak, which keeps the comparison total. Caller order is
        // not stable across launches, so it cannot be used.
        return data1.id.uuidString < data2.id.uuidString
    }
    
    /// Compares two films by a date field, falling back to the title. Used by the dateAdded, lastViewed, and
    /// dateModified sort cases.
    ///
    /// A film with no date carries `Date.distantPast`, which is the earliest value. Ascending therefore puts undated
    /// films first, and descending puts them last. No sentinel rule is needed.
    ///
    /// The title tiebreak always applies, including when both dates are absent, so every undated film has a defined position.
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
    /// Compares films for the datePurchased sort. Purchase state forms three tiers:
    ///
    ///   Tier 0: never purchased (earliest)
    ///   Tier 1: purchased, with no usable date
    ///   Tier 2: purchased with a date, ordered by that date
    ///
    /// Tiers and dates are read within `format`, or across all formats when nil. A "Purchased 4K" list therefore sorts
    /// by 4K purchases only (see ViewIdentifier.purchaseFormatScope).
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
    /// Internal, not private, so the debug harness checks ordering against this definition rather than a restated copy.
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
        // A current order answers without sorting — at launch, the one saved with the cache.
        if let ordered = sortFromLibraryOrder(filmIDs, key: LibraryOrderKey(option), direction: direction) {
            return ordered
        }
        // Copy the metadata on MainActor. Copy-on-write means the detached task reads it without copying.
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

    /// The shared sort. It is a pure function over any metadata snapshot, and nonisolated, so sortAsync's detached task
    /// can call it without returning to MainActor.
    nonisolated private static func _performSort(_ filmIDs: [UUID], by option: SortOption,
                                     direction: SortDirection,
                                     purchaseFormat: ReleaseFormat?,
                                     using metadata: [UUID: FilmMetadata]) -> [UUID] {
        return filmIDs.sorted { id1, id2 in
            let entry1 = metadata[id1], entry2 = metadata[id2]
            guard let data1 = entry1, let data2 = entry2 else {
                // Degenerate path: an ID with no metadata entry. Such IDs sort after every
                // film that has one, and by UUID among themselves. Comparing only the two
                // UUIDs whenever EITHER entry was missing mixed two unrelated orderings —
                // not a strict weak ordering — so the sort could scatter them arbitrarily.
                // Left outside the direction handling below deliberately — there is no
                // meaningful "reverse" of an arbitrary tiebreak.
                if (entry1 == nil) != (entry2 == nil) { return entry2 == nil }
                return id1.uuidString < id2.uuidString
            }

            // Direction is applied by swapping operands, never by negating the result. Negation breaks the strict weak
            // ordering that sorted(by:) requires, because equal elements would compare as less than themselves.
            return direction == .ascending
                ? compare(data1, data2, by: option, purchaseFormat: purchaseFormat)
                : compare(data2, data1, by: option, purchaseFormat: purchaseFormat)
        }
    }

    /// The single ascending comparison for every sort option. The caller applies direction (see _performSort). This
    /// function stays direction-blind, so every option reverses the same way.
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
            // Compared in whole minutes, because the UI shows minutes. Otherwise films that look identical would be ordered
            // by milliseconds the user cannot see, and the title tiebreak would never apply.
            let ms1 = Int(data1.effectiveDuration) ?? 0
            let ms2 = Int(data2.effectiveDuration) ?? 0

            // Films with no runtime form a leading tier. Truncating to minutes would otherwise place them among short films,
            // which would break the duration divider bands. Like every other rule, the tier is direction-blind.
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
            // An integer comparison with a title tiebreak.
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
            guard let cutoff = AppCalendar.current.date(byAdding: .day,
                                                     value: -recentlyRotatedWindowDays,
                                                     to: now) else { return [] }
            // The rotation date is the eligibility date, whether or not it has arrived. Both bounds are checked against
            // the current `Date()`: a date not yet reached is excluded, and so is one more than `recentlyRotatedWindowDays` ago.
            // Rotation dates fall on the 1st of a month, so ties are common, and the title tiebreak orders them.
            result = newestFirst { data in
                data.rotationDate.flatMap { $0 <= now && $0 >= cutoff ? $0 : nil }
            }

        case .recentlyPurchased:
            guard let cutoff = AppCalendar.current.date(byAdding: .day,
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
    
    /// String-backed and Hashable, so a case can serve as a stable key. GallerySubtitleProvider.kind is built from the
    /// raw value, which lets GallerySubview tell subtitle kinds apart across a Recents sub-tab switch.
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

    /// A film's synopsis in `SearchText.key` form, or nil if the film is not in the cache.
    func getSynopsisSearchKey(for filmID: UUID) -> String? {
        metadata[filmID]?.synopsisSearchKey
    }

    /// A film's credits, studios, tags, genre and notes in `SearchText.key` form, or nil if
    /// the film is not in the cache.
    func getTextSearchKeys(for filmID: UUID) -> FilmTextSearchKeys? {
        metadata[filmID]?.textSearchKeys
    }

    /// A film's date added or last watched as `parseDate(from:)` reads the stored string —
    /// nil inside when there is none or it does not parse — or nil when the film is not in
    /// the cache. The entries hold `Date.distantPast` for "no date"; that is turned back
    /// into nil here.
    func getParsedDate(for filmID: UUID, type: DateType) -> Date?? {
        guard let data = metadata[filmID] else { return nil }
        let date: Date
        switch type {
        case .dateAdded: date = data.dateAddedParsed
        case .lastWatched: date = data.lastWatchedParsed
        case .lastModified, .rotationDate, .purchaseDate: return nil
        }
        return .some(date == .distantPast ? nil : date)
    }
}
