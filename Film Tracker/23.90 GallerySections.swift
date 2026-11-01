// MARK: - GallerySections.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// GallerySection, the label a gallery divider band displays, and the derivation of those
// bands from the active sort option.
//
// The divider machinery (SmoothResizingGridLayout's SectionBreak and DividerRow in
// GalleryViewUI.swift, and GalleryListView's `.divider` rows) was first built for the Film
// Queue's three fixed sections, so it was typed on FilmQueueSection. It needs only a label and
// an equatable identity, so it uses GallerySection. The Film Queue supplies its three
// sections through the accessor below. This lets every gallery view show bands, gated by its
// ViewState.showSectionDividers.

import Foundation

// MARK: - Gallery Section

/// One labeled divider band's identity and display text.
///
/// `id` is separate from `displayName`, so two bands cannot merge because their labels happen
/// to match (for example, the Title sort's "#" band and a future band also labeled "#"). The
/// contiguity check in `GallerySectioning.sectionBreaks` compares ids for the same reason.
/// Equatable also drives SmoothResizingGridLayout.SectionBreak's equality, which the layout
/// uses to detect whether the breaks changed.
struct GallerySection: Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
}

extension FilmQueueSection {
    /// The Film Queue's three fixed sections in the generic band vocabulary. The "queue." id
    /// prefix keeps a queue band from matching a sort-derived band with the same label.
    var gallerySection: GallerySection {
        GallerySection(id: "queue.\(rawValue)", displayName: displayName)
    }
}

// MARK: - Gallery Section Key

/// What a loaded film set is actually ordered by, which is not always its `SortOption`.
///
/// For most views the two coincide, and `.sort` carries the option through. The Recents tabs
/// are the exception. Each reports a fixed `SortOption` via `RecentsCategory.sortOption`, but
/// "Recently Come Up for Rotation" reports a `.dateAdded` placeholder while `MetadataCache`
/// orders it by rotation eligibility date. `RecentsCategory.dateType` is the authoritative
/// statement of each tab's ordering.
///
/// Bands derived from the reported option were rejected by the contiguity guard in
/// `sectionBreaks`, so the Section Dividers menu silently did nothing on those tabs. Keying on
/// the real ordering fixes that.
///
/// Recents tabs whose reported sort already matches their ordering resolve through
/// `.recentsDate` to identical bands.
enum GallerySectionKey: Equatable, Sendable {
    /// Ordered by a standard sort option. `purchaseFormat` is the view's
    /// `ViewIdentifier.purchaseFormatScope`, the format whose purchases the Date Last Purchased
    /// sort ordered by, so the bands must read the same format. Other options ignore it.
    case sort(SortOption, purchaseFormat: ReleaseFormat? = nil)
    /// Ordered by a Recents tab's own date type (`RecentsCategory.dateType`).
    case recentsDate(RecentsCategory)
    /// "Upcoming Releases", ordered by each film's soonest upcoming release.
    case upcomingRelease

    /// Human-readable name of the ordering, used only in the contiguity guard's log line.
    var displayName: String {
        switch self {
        case .sort(let option, _): return option.displayName
        case .recentsDate(let category): return category.displayName
        case .upcomingRelease: return "Upcoming Release"
        }
    }
}

// MARK: - Gallery Section Jump Target

/// One entry in the Sort menu's "Jump to Section" submenu: a band and the film that begins it.
/// The film ID is the address. Both gallery styles resolve a scroll target from a film, and
/// unlike an index, the ID survives a reload that changes indices.
struct GallerySectionJumpTarget: Identifiable, Hashable, Sendable {
    let section: GallerySection
    let firstFilmID: UUID

    /// The band's identity. Unique within one view's band list, because GallerySectioning
    /// rejects any film set in which a section identity recurs.
    var id: String { section.id }
}

// MARK: - Gallery Sectioning

/// Derives sort-based divider bands for every gallery view except the Film Queue's "All" tab,
/// which keeps its own fixed Up Next, Soon, and Later bands (see filmQueueSectionBreaks).
///
/// Bands come from MetadataCache's FilmMetadata, not from FilmSnapshot. FilmMetadata holds the
/// exact values the sort comparators use (`titleKey` with leading articles stripped,
/// `effectiveDuration` with edited runtimes, and the three parsed dates), so a band boundary
/// can only fall where the sort already places one.
@MainActor
enum GallerySectioning: Loggable {
    nonisolated static let logTag = "[GallerySectioning]"

    // MARK: - Displayed Bands

    /// The bands a gallery showing `films` should display, from two producers in strict
    /// priority order:
    ///
    ///   1. The Film Queue's unnarrowed "All" tab always gets its three fixed Up Next, Soon,
    ///      and Later bands, whatever the sections preference. They describe the view's
    ///      structure, not its ordering.
    ///   2. Every other film set gets bands derived from the sort it is ordered by, but only
    ///      while `showSortingSections` (the view's ViewState.showSectionDividers) is on. This
    ///      includes the Queue's three single-section tabs, whose films are sorted like any
    ///      other view's once the grouping is narrowed away.
    ///
    /// This is the only place that decision is made. The grid, the list, and the Sort menu's
    /// "Jump to Section" submenu all route through it, so the bands drawn and the jump entries
    /// offered come from the same inputs.
    ///
    /// `films` is a parameter because each gallery style owns its displayed array. Passing the
    /// coordinator's `films` is correct only for a caller that does not render them itself.
    static func displayedSectionBreaks(films: [FilmSnapshot],
                                       coordinator: DataCoordinator,
                                       showSortingSections: Bool) -> [(index: Int, section: GallerySection)] {
        guard !films.isEmpty else { return [] }

        guard coordinator.loadedFilmQueueFilter == .all else {
            guard showSortingSections, let key = orderingKey(for: coordinator) else { return [] }
            return sectionBreaks(for: films, key: key)
        }

        return filmQueueSectionBreaks(for: films, coordinator: coordinator)
    }

    /// The Film Queue sections' memberships, for the "All" tab only. No FilmSnapshot field
    /// reflects these (see filmQueueSectionBreaks, which resolves each film's section through
    /// list membership). Both gallery styles fold this into the inputs that gate their banding
    /// rebuild, so the "All" tab skips the O(films) rescan when membership is unchanged. nil
    /// outside "All".
    ///
    /// Moving a film between sections changes these sets even when the films array is
    /// unchanged (for example, the first "Soon" film promoted to "Up Next" keeps its place).
    /// Unchanged sets compare in O(1) when they share storage.
    static func filmQueueMembership(for coordinator: DataCoordinator) -> [Set<UUID>]? {
        guard coordinator.loadedFilmQueueFilter == .all else { return nil }
        return FilmQueueSection.allCases.map { coordinator.getList($0.listID)?.filmIDs ?? [] }
    }

    /// What the coordinator's loaded film set is ordered by, or nil before any load completes.
    ///
    /// Reads the `loaded*` properties, which are set together with `films`. The `current*`
    /// values describe the last load requested, and a load that returns early at the readiness
    /// gate has already updated them. The Recents check comes first because it is more specific.
    /// On those tabs `loadedSortOption` is a placeholder, and for "Recently Come Up for Rotation"
    /// it does not describe the real ordering. See `GallerySectionKey`.
    private static func orderingKey(for coordinator: DataCoordinator) -> GallerySectionKey? {
        if let category = coordinator.loadedRecentsCategory { return .recentsDate(category) }
        if coordinator.loadedUpcomingReleasesOrder { return .upcomingRelease }
        guard let sort = coordinator.loadedSortOption else { return nil }
        return .sort(sort, purchaseFormat: coordinator.loadedPurchaseFormat)
    }

    /// The Film Queue's three fixed bands. Scans `films` (already grouped by section, in queue
    /// order, by MemoryStore.getFilms(viewID: .filmQueue)) for section transitions between
    /// adjacent films. It emits a break at each transition, plus a leading break at the first
    /// sectioned film so the first band is labeled like the rest.
    ///
    /// A film with no resolvable section is skipped with `continue`, so it stays under the
    /// preceding band rather than starting a spurious one. The sort-derived scan follows the
    /// same rule.
    private static func filmQueueSectionBreaks(
        for films: [FilmSnapshot],
        coordinator: DataCoordinator) -> [(index: Int, section: GallerySection)] {
        var breaks: [(index: Int, section: GallerySection)] = []
        var lastSection: FilmQueueSection?
        for (index, film) in films.enumerated() {
            guard let section = coordinator.filmQueueSection(forFilm: film.id) else { continue }
            if lastSection != section {
                breaks.append((index, section.gallerySection))
            }
            lastSection = section
        }
        return breaks
    }

    /// The entries the Sort menu's "Jump to Section" submenu offers, in display order. Derived
    /// from `displayedSectionBreaks`, the same call both gallery styles make, so the menu lists
    /// only bands that are on screen, in the order the gallery uses.
    ///
    /// Recomputed each time the menu is built rather than cached. A menu is built when it opens,
    /// so an on-demand read cannot be stale.
    ///
    /// `showSortingSections` is a parameter, not a state read here, and it gates the whole
    /// submenu, including the Film Queue's fixed bands. Reading the setting inside a menu builder
    /// gave SwiftUI nothing to observe, so a submenu built while it was on could outlive it being
    /// turned off. Each host sources the value observably (GallerySortMenu from @Observable
    /// ViewState, SortByMenu from a @State mirror resynced as the menu bar opens) and passes it
    /// down. Gating the whole submenu keeps one switch in charge of the sections feature.
    static func jumpTargets(coordinator: DataCoordinator,
                            showSortingSections: Bool) -> [GallerySectionJumpTarget] {
        guard showSortingSections else { return [] }
        let films = coordinator.films
        return displayedSectionBreaks(
            films: films, coordinator: coordinator,
            showSortingSections: showSortingSections)
            .compactMap { brk in
                guard brk.index >= 0, brk.index < films.count else { return nil }
                return GallerySectionJumpTarget(section: brk.section,
                                                firstFilmID: films[brk.index].id)
            }
    }

    // MARK: - Band Spans

    /// The number of films in one band: from its first film's index to the next band's, or to
    /// `totalCount` for the last band. Defined once so the grid and the list derive per-band
    /// counts the same way. It takes start and next indices, so callers need not build an
    /// index array: the grid passes adjacent `DividerRow.itemIndex` values, and the list passes
    /// adjacent break indices.
    static func bandFilmCount(from startIndex: Int, nextBandIndex: Int?, totalCount: Int) -> Int {
        max(0, (nextBandIndex ?? totalCount) - startIndex)
    }

    // MARK: - Break Computation

    /// Scans `films`, already in display order, for section transitions between adjacent films.
    /// It emits a break at each transition, plus a leading break at the first resolvable film,
    /// as the Film Queue's break computation does. A film whose section cannot be resolved (no
    /// metadata, or a sort with no sectioning rule) is skipped with `continue`, so it stays
    /// under the preceding band.
    ///
    /// **Contiguity is verified, not assumed.** Bands make sense only when the display order
    /// matches the sort key. Some views order films another way (Hall of Fame keeps its own
    /// stored order, for example). Listing those views here would rot as views are added, so
    /// this detects the mismatch directly. If a section id reappears after a different one, the
    /// order is not grouped by this key, and the function returns no breaks. The result is "no
    /// dividers", never repeated bands.
    ///
    /// `metadata` defaults to the shared cache's records.
    static func sectionBreaks(for films: [FilmSnapshot],
                              key: GallerySectionKey,
                              metadata: [UUID: FilmMetadata] = MetadataCache.shared.metadata)
        -> [(index: Int, section: GallerySection)] {
        guard !films.isEmpty else { return [] }

        let context = SectionContext()

        var breaks: [(index: Int, section: GallerySection)] = []
        var seen: Set<String> = []
        var lastSection: GallerySection?

        for (index, film) in films.enumerated() {
            guard let data = metadata[film.id],
                  let section = section(for: data, film: film, key: key, context: context) else { continue }
            if lastSection != section {
                guard seen.insert(section.id).inserted else {
                    Self.log("Sectioning disabled for this film set — section '\(section.displayName)' recurs, so the display order is not grouped by \(key.displayName)")
                    return []
                }
                breaks.append((index, section))
            }
            lastSection = section
        }

        return breaks
    }

    // MARK: - Per-Option Section Resolution

    /// Values shared by every film in one `sectionBreaks` pass. The relative date boundaries
    /// must be computed once. Computing them per film would let "now" advance mid-scan and
    /// put two films of the same age in different bands, which the contiguity guard would then
    /// reject, dropping every band in the view.
    private struct SectionContext {
        let calendar = AppCalendar.current
        let weekAgo: Date
        let monthAgo: Date
        let twoMonthsAgo: Date
        let sixMonthsAgo: Date
        let yearAgo: Date
        /// The day "upcoming" is judged against, as SmartLists and DataCoordinator do.
        let today: Date

        init() {
            let now = Date()
            let cal = AppCalendar.current
            // `?? now` is unreachable on the Gregorian calendar. It only makes each boundary
            // non-optional. Collapsing to `now` would put every dated film in a per-year band.
            weekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
            monthAgo = cal.date(byAdding: .month, value: -1, to: now) ?? now
            twoMonthsAgo = cal.date(byAdding: .month, value: -2, to: now) ?? now
            sixMonthsAgo = cal.date(byAdding: .month, value: -6, to: now) ?? now
            yearAgo = cal.date(byAdding: .year, value: -1, to: now) ?? now
            today = StorageDateFormatters.calendar.startOfDay(for: now)
        }
    }

    private static func section(for data: FilmMetadata, film: FilmSnapshot, key: GallerySectionKey,
                                context: SectionContext) -> GallerySection? {
        switch key {
        case .sort(let option, let purchaseFormat):
            return sortSection(for: data, option: option, purchaseFormat: purchaseFormat,
                               context: context)
        case .recentsDate(let category):
            return recentsSection(for: data, category: category, context: context)
        case .upcomingRelease:
            return upcomingReleaseSection(for: film, context: context)
        }
    }

    /// The band for "Upcoming Releases": the month of the film's soonest upcoming release
    /// ("November 2026"), or the year alone for a year-only date. A year-only date sorts as day
    /// zero of its year, so its band comes just before that year's first month band, keeping
    /// bands contiguous.
    private static func upcomingReleaseSection(for film: FilmSnapshot,
                                               context: SectionContext) -> GallerySection {
        guard let next = SmartLists.nextUpcomingRelease(of: film, today: context.today) else {
            return GallerySection(id: "upcoming.none", displayName: "Released")
        }
        guard let monthDay = next.monthDay else {
            return GallerySection(id: "upcoming.\(next.year)", displayName: String(next.year))
        }
        return GallerySection(id: "upcoming.\(next.year).\(monthDay.month)",
                              displayName: "\(ReleaseDateValue.monthName(monthDay.month)) \(next.year)")
    }

    /// The band for a Recents tab, derived from the tab's `dateType`, which is what
    /// `MetadataCache` actually orders the tab by.
    ///
    /// The first three branches match the corresponding `SortOption` branches below: same
    /// parsed date, same id prefix, same undated label. So the tabs whose reported sort already
    /// matched their ordering see no change.
    ///
    /// Both dates are optional on
    /// `FilmMetadata`, and `dateSection` uses `Date.distantPast` as its "no date" sentinel, so
    /// nil maps to it and gets a leading band. Neither undated band normally shows, because
    /// `MetadataCache.recentFilmIDs(for:)` drops films without a rotation or purchase date from
    /// those tabs. The bands are still defined, so the sectioning stays correct if that rule
    /// is widened.
    private static func recentsSection(for data: FilmMetadata, category: RecentsCategory,
                                       context: SectionContext) -> GallerySection? {
        switch category.dateType {
        case .dateAdded:
            return dateSection(data.dateAddedParsed, prefix: "dateAdded",
                               undatedLabel: "No Date Added", context: context)
        case .lastModified:
            return dateSection(data.lastModifiedParsed, prefix: "dateModified",
                               undatedLabel: "No Date Modified", context: context)
        case .lastWatched:
            return dateSection(data.lastWatchedParsed, prefix: "lastViewed",
                               undatedLabel: "Never Viewed", context: context)
        case .rotationDate:
            return dateSection(data.rotationDate ?? .distantPast, prefix: "rotationDate",
                               undatedLabel: "No Rotation Date", context: context)
        case .purchaseDate:
            return dateSection(data.mostRecentPurchaseDate ?? .distantPast,
                               prefix: "purchaseDate",
                               undatedLabel: "No Purchase Date", context: context)
        }
    }

    private static func sortSection(for data: FilmMetadata, option: SortOption,
                                    purchaseFormat: ReleaseFormat?,
                                    context: SectionContext) -> GallerySection? {
        switch option {
        case .title:
            return titleSection(data)

        case .year:
            let year = Int(data.year) ?? 0
            return year > 0
                ? GallerySection(id: "year.\(year)", displayName: String(year))
                : GallerySection(id: "year.none", displayName: "No Release Date")

        case .duration:
            return durationSection(Int(data.effectiveDuration) ?? 0)

        case .dateAdded:
            return dateSection(data.dateAddedParsed, prefix: "dateAdded",
                               undatedLabel: "No Date Added", context: context)

        case .dateModified:
            return dateSection(data.lastModifiedParsed, prefix: "dateModified",
                               undatedLabel: "No Date Modified", context: context)

        case .lastViewed:
            return dateSection(data.lastWatchedParsed, prefix: "lastViewed",
                               undatedLabel: "Never Viewed", context: context)

        case .viewCount:
            let count = max(0, data.viewCount)
            let label = count == 0 ? "No Recorded Viewings"
                                   : "\(count) Viewing\(count == 1 ? "" : "s")"
            return GallerySection(id: "viewCount.\(count)", displayName: label)

        case .rating:
            let rating = data.rating
            return rating > 0
                ? GallerySection(id: "rating.\(rating)", displayName: "Rating: \(rating)")
                : GallerySection(id: "rating.none", displayName: "No Rating")

        case .datePurchased:
            // Purchases sort in three tiers: never purchased, purchased undated, and purchased
            // dated (see MetadataCache.comparePurchaseDates). The two undated tiers are adjacent,
            // so they fold into one "No Purchase Date" band at the end. The dated tier uses the
            // date the bands are cut from, within the release format scope. With no scope this
            // matches the Recently Purchased tab's bands (see recentsSection).
            return dateSection(data.mostRecentPurchaseDate(in: purchaseFormat) ?? .distantPast,
                               prefix: "purchaseDate",
                               undatedLabel: "No Purchase Date", context: context)
        }
    }

    // MARK: - Title

    /// The alphabetical band for a title, from `titleKey`: the article-stripped string
    /// `compareTitles` sorts on. A boundary therefore falls where the sort's first-character
    /// comparison does.
    ///
    /// Diacritics are folded and case normalized, so "Éclair" joins "E" rather than opening a
    /// separate "É" band that would split the "E" titles. A first character that is neither a
    /// digit nor a letter keeps its own band rather than joining "#". Such titles sort among the
    /// letters, so folding them into the numeral band would break contiguity.
    private static func titleSection(_ data: FilmMetadata) -> GallerySection {
        if data.titleStartsWithNumber {
            return GallerySection(id: "title.#", displayName: "#")
        }
        guard let first = data.titleKey.first else {
            return GallerySection(id: "title.untitled", displayName: "Untitled")
        }
        let folded = String(first)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: EnglishText.locale)
            .uppercased()
        let key = folded.first.map(String.init) ?? String(first)
        return GallerySection(id: "title.\(key)", displayName: key)
    }

    // MARK: - Duration

    /// Runtime bands: every ten minutes from 1:00 to 2:00, where most films fall, since a
    /// twenty-minute band would be too coarse there. Then bands at 2:30, 3:00, and 4:00.
    /// `milliseconds` is `effectiveDuration`, which reflects an edited runtime when there is
    /// one, so the bands match the duration sort.
    ///
    /// Films with no usable duration get their own leading band rather than padding "Under
    /// 1:00". They share the sort's minimum key, so they stay contiguous. A real 20-minute short
    /// should not look like a film whose runtime was never entered.
    private static func durationSection(_ milliseconds: Int) -> GallerySection {
        guard milliseconds > 0 else {
            return GallerySection(id: "duration.none", displayName: "No Duration")
        }
        let minutes = milliseconds / 60_000
        switch minutes {
        case ..<60:  return GallerySection(id: "duration.0", displayName: "Under 1:00")
        case ..<70:  return GallerySection(id: "duration.60", displayName: "1:00 – 1:10")
        case ..<80:  return GallerySection(id: "duration.70", displayName: "1:10 – 1:20")
        case ..<90:  return GallerySection(id: "duration.80", displayName: "1:20 – 1:30")
        case ..<100: return GallerySection(id: "duration.90", displayName: "1:30 – 1:40")
        case ..<110: return GallerySection(id: "duration.100", displayName: "1:40 – 1:50")
        case ..<120: return GallerySection(id: "duration.110", displayName: "1:50 – 2:00")
        case ..<150: return GallerySection(id: "duration.120", displayName: "2:00 – 2:30")
        case ..<180: return GallerySection(id: "duration.150", displayName: "2:30 – 3:00")
        case ..<240: return GallerySection(id: "duration.180", displayName: "3:00 – 4:00")
        default:     return GallerySection(id: "duration.240", displayName: "4:00 and Over")
        }
    }

    // MARK: - Dates

    /// Relative-age bands (Past Week, Past Month, Past 2 Months, Past Six Months, Past Year),
    /// then one band per calendar year for anything older. Each relative band excludes the nearer
    /// ones, so "Past Year" holds only what falls between six months and a year ago. The first
    /// per-year band holds only the part of its year before the one-year boundary. The bands are
    /// contiguous ranges in date space, so they are contiguous in a date-sorted set in either
    /// direction.
    ///
    /// A film with no date carries `Date.distantPast` (MetadataCache.parseDate's value for an
    /// absent or malformed field) and gets its own band. It cannot fall through to the per-year
    /// branch, because year 1 is a real calendar year and would be labeled "1".
    private static func dateSection(_ date: Date, prefix: String, undatedLabel: String,
                                    context: SectionContext) -> GallerySection {
        guard date > Date.distantPast else {
            return GallerySection(id: "\(prefix).none", displayName: undatedLabel)
        }
        // A future date (for example, a manually entered viewing) falls in "Past Week", the band
        // nearest now.
        if date >= context.weekAgo {
            return GallerySection(id: "\(prefix).week", displayName: "Past Week")
        }
        if date >= context.monthAgo {
            return GallerySection(id: "\(prefix).month", displayName: "Past Month")
        }
        if date >= context.twoMonthsAgo {
            return GallerySection(id: "\(prefix).twoMonths", displayName: "Past 2 Months")
        }
        if date >= context.sixMonthsAgo {
            return GallerySection(id: "\(prefix).sixMonths", displayName: "Past Six Months")
        }
        if date >= context.yearAgo {
            return GallerySection(id: "\(prefix).year", displayName: "Past Year")
        }
        let year = context.calendar.component(.year, from: date)
        return GallerySection(id: "\(prefix).\(year)", displayName: String(year))
    }
}
