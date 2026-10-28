// MARK: - GallerySections.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines GallerySection — the label a gallery divider band displays — and the
// derivation of those sections from the active sort option.
//
// The divider machinery itself (SmoothResizingGridLayout's SectionBreak / DividerRow
// geometry in GalleryViewUI.swift, and GalleryListView's interleaved `.divider` rows)
// predates this file: it was built for the Film Queue's three fixed sections and was
// therefore typed directly on FilmQueueSection. Nothing about that machinery is actually
// specific to the Film Queue — it needs a label and an equatable identity and nothing
// else — so it is now typed on GallerySection instead, and the Film Queue supplies its
// three sections through the bridging accessor below. That single change is what lets the
// same bands serve every other gallery view, gated by that view's ViewState.showSectionDividers.

import Foundation

// MARK: - Gallery Section

/// One labeled divider band's identity and display text.
///
/// `id` exists separately from `displayName` so two sections can never be conflated by a
/// coincidental label collision — the Title sort's "#" band and a hypothetical future
/// band that also renders as "#" would compare unequal — and so the run-contiguity check
/// in `GallerySectioning.sectionBreaks` compares identities rather than user-facing text.
/// Equatable is what SmoothResizingGridLayout.SectionBreak's own Equatable conformance
/// (and therefore the layout's "did the breaks actually change" guard) is built on.
struct GallerySection: Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
}

extension FilmQueueSection {
    /// The Film Queue's three fixed sections, expressed in the generic vocabulary the
    /// divider machinery now speaks. Namespaced so a queue section can never collide with
    /// a sort-derived one (e.g. a "Later" band would otherwise be indistinguishable from
    /// a Title-sort band for the letter run it shares no meaning with).
    var gallerySection: GallerySection {
        GallerySection(id: "queue.\(rawValue)", displayName: displayName)
    }
}

// MARK: - Gallery Section Key

/// What a loaded film set is actually ORDERED by — which is not always its `SortOption`.
///
/// For almost every view the two coincide, and `.sort` carries the option straight through.
/// The Recents tabs are the exception the abstraction exists for. Each of them reports a
/// fixed `SortOption` via `RecentsCategory.sortOption`, but "Recently Come Up for Rotation"
/// reports a `.dateAdded` placeholder while `MetadataCache` actually orders it by rotation
/// eligibility date, which no sort option expresses (see `RecentsCategory.dateType`, the
/// authoritative statement of what each tab is ordered by). "Recently Purchased" reported
/// the same placeholder until it was given `.datePurchased`, which it genuinely matches.
///
/// Deriving bands from the reported sort option there produced no bands at all: the
/// contiguity guard in `sectionBreaks` correctly observed that a Date Added band recurred
/// in a set that is not ordered by Date Added, and discarded the whole computation. The
/// user-visible result was a "Section Dividers" menu pair that silently did nothing on
/// exactly those tabs. Keying on the ordering rather than on the sort option makes the
/// bands describe the order the films are genuinely in.
///
/// The two remaining Recents tabs whose reported sort DOES match their ordering
/// (`.recentlyAdded` → `dateAdded`, `.recentlyUpdated` → `lastModified`, plus
/// `.recentlyViewed` → `lastWatched`) resolve through `.recentsDate` to the identical
/// bands — same parsed date field, same id prefix, same labels — that `.sort` produced for
/// them before, so their behavior is unchanged.
enum GallerySectionKey: Equatable, Sendable {
    /// Ordered by a standard sort option, which is also what the bands are derived from.
    /// `purchaseFormat` is the view's `ViewIdentifier.purchaseFormatScope`: the format whose
    /// purchases the Date Last Purchased sort ordered by, and so the one its bands must read.
    /// Every other option ignores it.
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

/// One entry in the Sort menu's "Jump to Section" submenu: a band, plus the film that
/// begins it. The film ID is the address — both gallery styles resolve a scroll target
/// from a film, and it survives a reload that changes indices, which a raw index would not.
struct GallerySectionJumpTarget: Identifiable, Hashable, Sendable {
    let section: GallerySection
    let firstFilmID: UUID

    /// The band's own identity. Stable and unique within a single view's band list, since
    /// GallerySectioning rejects any film set in which a section identity recurs.
    var id: String { section.id }
}

// MARK: - Gallery Sectioning

/// Derives sort-based divider bands for every gallery view except the Film Queue's "All"
/// tab, which keeps its own fixed Up Next → Soon → Later bands (see
/// filmQueueSectionBreaks below).
///
/// Every section is resolved from MetadataCache's FilmMetadata rather than from the
/// FilmSnapshot directly, deliberately: FilmMetadata holds the exact derived values the
/// sort comparators use (`titleKey` with leading articles stripped, `effectiveDuration`
/// resolving edited runtimes, the three parsed dates), so a band boundary can never fall
/// anywhere the sort itself did not already place one.
@MainActor
enum GallerySectioning: Loggable {
    nonisolated static let logTag = "[GallerySectioning]"

    // MARK: - Displayed Bands

    /// The bands a gallery showing `films` should display, resolved through the two
    /// producers in strict priority order:
    ///
    ///   1. The Film Queue's full, unnarrowed union ("All") always gets its three fixed
    ///      Up Next / Soon / Later bands, regardless of the sorting-sections preference.
    ///      Those bands describe the view's own structure, not its ordering.
    ///   2. Every other film set gets bands derived from the sort option it was actually
    ///      ordered by, and only while `showSortingSections` — the viewing view's own
    ///      ViewState.showSectionDividers — is on. This deliberately
    ///      includes the Queue's three single-section tabs, whose films are sorted like
    ///      any other view's once the section grouping is narrowed away.
    ///
    /// This is the ONLY place that decision is made. The grid coordinator, the list
    /// coordinator, and the Sort menu's "Jump to Section" submenu all route through it, so
    /// the bands the two gallery styles draw and the entries the menu offers to jump to
    /// cannot describe different things — they are literally the same array, recomputed
    /// from the same inputs.
    ///
    /// `films` is a parameter rather than being read off the coordinator because each
    /// gallery style owns its own copy of the displayed array and must stay authoritative
    /// over it; passing the coordinator's `films` (as the menu does) is the correct call
    /// only for a caller that is not itself rendering them.
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

    /// The Film Queue sections' memberships, for the "All" tab only — the one banding input
    /// that no FilmSnapshot field reflects (see filmQueueSectionBreaks, which resolves each
    /// film's section through list membership). Both gallery styles fold this into the
    /// inputs that gate their banding rebuild, so the "All" tab skips the O(films) rescan on
    /// a pass where membership is unchanged, as every other view does. nil outside "All".
    ///
    /// Moving a film between sections changes these sets even where it leaves the films
    /// array byte-identical (the first "Soon" film promoted to "Up Next" keeps its place).
    /// Unchanged sets compare in O(1), as they share storage with MemoryStore's own.
    static func filmQueueMembership(for coordinator: DataCoordinator) -> [Set<UUID>]? {
        guard coordinator.loadedFilmQueueFilter == .all else { return nil }
        return FilmQueueSection.allCases.map { coordinator.getList($0.listID)?.filmIDs ?? [] }
    }

    /// What the coordinator's currently-loaded film set is ordered by, or nil before any
    /// load has completed.
    ///
    /// Both inputs are `loaded*` properties — written in the same synchronous statement
    /// group as `films` itself — rather than the `current*` values, which describe the last
    /// load REQUESTED and are already updated during a load that goes on to return early at
    /// the readiness gate. That is what makes this describe the ordering the array actually
    /// has rather than the one most recently asked for.
    ///
    /// The Recents check comes first because it is the more specific statement: on those
    /// tabs `loadedSortOption` is a fixed placeholder that, for Recently Come Up for
    /// Rotation, does not describe the real ordering at all. See `GallerySectionKey`.
    private static func orderingKey(for coordinator: DataCoordinator) -> GallerySectionKey? {
        if let category = coordinator.loadedRecentsCategory { return .recentsDate(category) }
        if coordinator.loadedUpcomingReleasesOrder { return .upcomingRelease }
        guard let sort = coordinator.loadedSortOption else { return nil }
        return .sort(sort, purchaseFormat: coordinator.loadedPurchaseFormat)
    }

    /// The Film Queue's three fixed bands. Scans the `films` array — already grouped by
    /// section, in queue order, by MemoryStore.getFilms(viewID: .filmQueue) — for
    /// section-boundary transitions between adjacent films, emitting a break at every
    /// transition plus a synthesized leading break at the first sectioned film so the very
    /// first section is labeled the same way every later one is.
    ///
    /// A film whose section cannot be resolved is skipped with `continue`, which leaves it
    /// grouped under the preceding band rather than manufacturing a spurious one — the same
    /// rule the sort-derived scan below follows.
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

    /// The entries the Sort menu's "Jump to Section" submenu should offer, in display
    /// order. Derived from `displayedSectionBreaks` — the same call both gallery styles
    /// make — so the menu can only ever list bands that are actually on screen, and can
    /// never list them in an order the gallery does not use.
    ///
    /// Recomputed each time the menu is built rather than cached and published: a menu is
    /// constructed at the moment it opens, so an on-demand read is both the cheapest option
    /// and the one with no window in which it can be stale.
    ///
    /// `showSortingSections` is a PARAMETER rather than a state read performed here, and it
    /// gates the whole submenu rather than only the sort-derived bands. Both are deliberate.
    /// Reading the setting imperatively inside a menu builder gave SwiftUI nothing to
    /// observe, so the host's body had no reason to re-evaluate when it changed and a
    /// submenu built while it was on could outlive it being turned off; each host now
    /// sources it observably — GallerySortMenu from @Observable ViewState, SortByMenu from
    /// a @State mirror it resyncs as the menu bar opens — and hands it down. And gating the
    /// whole submenu — including the Film Queue's three fixed bands, which are otherwise
    /// independent of this setting — keeps one switch in charge of the entire sections
    /// feature, so "dividers are off for this view" and "there is no Jump to Section menu"
    /// are the same statement everywhere rather than almost everywhere.
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

    /// The number of films belonging to one band: the span from that band's own first
    /// film index to the next band's, or to `totalCount` for the last band.
    ///
    /// Trivial arithmetic, but deliberately defined once. Both gallery styles display a
    /// per-band film count and each derived it independently — the grid from its
    /// `dividerRows`, the list from its `breaks` array — with a comment on each stating
    /// that the two are "identical in derivation." That is agreement by convention, which
    /// is precisely what the rest of this file exists to replace with agreement by
    /// construction. Expressed as start/next rather than as an array lookup so neither
    /// caller has to materialize an index array it does not already hold: the grid passes
    /// its adjacent `DividerRow.itemIndex` values, the list its adjacent break indices.
    static func bandFilmCount(from startIndex: Int, nextBandIndex: Int?, totalCount: Int) -> Int {
        max(0, (nextBandIndex ?? totalCount) - startIndex)
    }

    // MARK: - Break Computation

    /// Scans `films` — already in the order the gallery displays them — for section
    /// transitions between adjacent films, emitting a break at every transition plus a
    /// synthesized leading break at the first resolvable film, exactly as the Film Queue's
    /// own break computation does. A film whose section cannot be resolved (no metadata
    /// entry, or a sort option with no sectioning rule) is skipped with `continue`, which
    /// leaves it grouped under the preceding band rather than manufacturing a spurious
    /// one — again matching the queue's behavior.
    ///
    /// **Contiguity is verified, not assumed.** Sectioning is only meaningful when the
    /// film order actually agrees with the sort key the sections are derived from, and a
    /// handful of views order their films by something else entirely (Hall of Fame's
    /// stored positions, for instance). Rather than enumerate those views here — a list
    /// that would silently rot as views are added — this detects the disagreement
    /// directly: if a section identity reappears after a different one intervened, the
    /// order is not grouped by this key, and the whole computation returns no breaks at
    /// all. That degrades to "no dividers", never to a grid strewn with repeated bands.
    ///
    /// `metadata` defaults to the shared cache; the debug harness passes an isolated
    /// cache's records so it can band a fixture set the shared cache has never seen.
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

    /// Values shared across every film in a single `sectionBreaks` pass. The relative date
    /// boundaries in particular must be computed exactly once: deriving them per film
    /// would let "now" advance mid-scan and place two films of identical age in different
    /// bands, which is precisely the non-contiguity the guard above would then react to by
    /// discarding every band in the view.
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
            // `?? now` cannot be reached with these components on the Gregorian calendar;
            // it exists so a non-optional boundary can be stored, and collapsing every
            // boundary to `now` would simply place all dated films in the per-year bands.
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

    /// The band a film belongs to in "Upcoming Releases": the month of its soonest
    /// upcoming release ("November 2026"), or just the year for a year-only date. A
    /// year-only value orders as day zero of its year, so its band always comes directly
    /// before that year's first month band and every band stays contiguous.
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

    /// The band a film belongs to on a Recents tab, derived from that tab's own
    /// `dateType` — the authoritative statement of what `MetadataCache` actually ordered
    /// the tab by.
    ///
    /// The first three branches deliberately reproduce, field for field, the bands the
    /// corresponding `SortOption` branches below produce: same parsed date, same id prefix,
    /// same undated label. That equality is the whole reason the three tabs whose reported
    /// sort already matched their ordering see no behavioral change from this routing.
    ///
    /// The last two are the ones that previously had no working sectioning at all. Both
    /// dates are Optional on `FilmMetadata` (a film may have no rotation eligibility date
    /// and no purchased release), and `dateSection` expects `Date.distantPast` as its
    /// "no date" sentinel, so nil is mapped onto it — giving those films a dedicated
    /// leading band exactly as an unparseable date gets elsewhere. In practice neither
    /// undated band appears on its own tab: `MetadataCache.recentFilmIDs(for:)` drops films
    /// with no rotation or purchase date from those two tabs before the list is built. The
    /// bands are still defined rather than returning nil, so the sectioning stays correct
    /// if either tab's membership rule is ever widened.
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
            // The purchase sort orders by three tiers (never purchased / purchased undated /
            // purchased dated — see MetadataCache.comparePurchaseDates). The two undated
            // tiers are adjacent in that order, so both fold into one "No Purchase Date"
            // band at the undated end and stay contiguous; the dated tier is ordered by
            // the same date the bands are cut from — within the same release format, on
            // the "Purchased 4K / Blu-ray / DVD" lists. With no format scope this is
            // identical to the Recently Purchased tab's bands (see recentsSection), so one
            // purchase date bands one way.
            return dateSection(data.mostRecentPurchaseDate(in: purchaseFormat) ?? .distantPast,
                               prefix: "purchaseDate",
                               undatedLabel: "No Purchase Date", context: context)
        }
    }

    // MARK: - Title

    /// The alphabetical band a title belongs to, derived from `titleKey` — the same
    /// article-stripped string `compareTitles` sorts on, so a band boundary always falls
    /// exactly where the sort's own first-character comparison does.
    ///
    /// Diacritics are folded (and case normalized) so "Éclair" bands with "E" rather than
    /// opening a second, separate "É" band that `englishStandardCompare` would have
    /// interleaved among the "E" titles — a non-contiguous split that would cost the view
    /// its dividers entirely. A first character that is neither a digit nor a letter keeps
    /// its own band rather than being swept into "#": such titles sort among the letters,
    /// not with the numerals, so folding them into the numeral band would break contiguity
    /// for exactly the same reason.
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

    /// Runtime bands every ten minutes from 1:00 to 2:00 — where the bulk of any library
    /// sits, and where a twenty-minute band is too coarse to tell a tight feature from a
    /// long one — then at 2:30, 3:00, and 4:00. `milliseconds` is
    /// the raw `effectiveDuration` figure, which resolves to a film's edited runtime when
    /// it has one — so the bands reflect the runtime the user actually experiences, the
    /// same value the duration sort orders by.
    ///
    /// Films with no usable duration parse to 0 and get their own leading band rather than
    /// padding out "Under 1:00": they all share the sort's minimum key and are therefore
    /// contiguous, and a genuinely 20-minute short reads very differently from a film whose
    /// runtime was simply never filled in.
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

    /// Relative-age bands — Past Week, Past Month, Past 2 Months, Past Six Months, Past
    /// Year — followed by one band per calendar year for anything older. Each relative band
    /// excludes the ones nearer to now, so "Past Year" holds only what falls between six
    /// months and a year ago, and the first per-year band holds only the part of that year
    /// that predates the one-year boundary. The bands are contiguous ranges in date space, which is what makes
    /// them contiguous runs in a date-sorted film set regardless of sort direction.
    ///
    /// A film with no date carries `Date.distantPast` (MetadataCache.parseDate's value for
    /// an absent or malformed field) and gets a dedicated band. It cannot simply fall
    /// through to the per-year branch: year 1 is a real calendar year and would produce a
    /// band labeled "1".
    private static func dateSection(_ date: Date, prefix: String, undatedLabel: String,
                                    context: SectionContext) -> GallerySection {
        guard date > Date.distantPast else {
            return GallerySection(id: "\(prefix).none", displayName: undatedLabel)
        }
        // A future date (a manually entered viewing, say) is newer than every boundary and
        // lands in "Past Week" — the nearest band to now, and the only one that can hold it
        // without opening a band above the range the user was offered.
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
