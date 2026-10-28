// MARK: - DVLibraryStats.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The whole-library statistics model behind the Data Visualizations report and the
// PDF's Data Visualizations sheet: FormatBreakdownData, FourKStatistics, PurchaseYearRow
// and LibraryStatistics itself. Moved here verbatim from 27.40 RPTabDataViz.swift when
// that file became the tab's view layer alone; the year-scoped and derived figures the
// redesigned tab added live beside it in 27.43 LibraryInsights.swift.

import Foundation

// MARK: - Format Breakdown Data
struct FormatBreakdownData {
    let format: String
    let count: Int
    let percent: Double
    let avgCost: String
}

// MARK: - 4K Statistics
struct FourKStatistics {
    let filmsWithFourK: Int
    let filmsWithFourKPercent: Int
    let filmsWithNativeFourK: Int
    let filmsWithUpscaledFourK: Int
    
    let filmsWithPurchasedFourK: Int
    let filmsWithPurchasedNativeFourK: Int
    let filmsWithPurchasedUpscaledFourK: Int
    
    let fourKPurchaseRate: Int
}

// MARK: - Library Statistics
/// One calendar year of purchasing, as the Purchases by Year chart draws it.
///
/// The below-average percentage is a share of THAT YEAR's purchases — "what did this year
/// look like" rather than "how big was it".
struct PurchaseYearRow: Sendable {
    let year: String
    /// Releases bought in this year.
    let count: Int
    let usedCount: Int
    let newCount: Int
    /// Purchases at or below the all-time average price. The comparison is against the
    /// average across the WHOLE collection, not this year's own average, so the column
    /// answers "was this a good year to buy" rather than restating each year's midpoint.
    let atOrBelowAverageCount: Int
    let atOrBelowAveragePercentOfYear: Double
}

struct LibraryStatistics {
    let totalFilms: Int
    let filmsOnDisc: Int
    let filmsOnDiscPercent: Int
    let unpurchasedOnDisc: Int
    let digitalOnlyFilms: Int
    let missingArtwork: Int
    let missingArtworkPercent: Int
    /// Films behind `missingArtwork`, for the Needs Attention card's popover.
    let missingArtworkItems: [DVNamedFilm]
    let colorFilms: Int
    let bwFilms: Int
    let editedFilms: Int
    let editedPercent: Int
    let infoComplete: Int
    let infoCompletePercent: Int
    /// Films not marked info complete, for the Needs Attention card's popover.
    let infoCompleteItems: [DVNamedFilm]
    
    // Purchase statistics
    let hasPurchaseData: Bool
    let totalPurchasedReleases: Int
    let newReleases: Int
    let newReleasesPercent: Int
    let usedReleases: Int
    let usedReleasesPercent: Int
    let averageCost: String
    let missingReleaseArtwork: Int
    /// Films behind `missingReleaseArtwork`, for the Needs Attention card's popover.
    let missingReleaseArtworkItems: [DVNamedFilm]
    let lossyBDAudio: Int
    let lossyBDAudioPercent: Int
    /// Films behind `lossyBDAudio`, for the Needs Attention card's popover.
    let lossyBDAudioItems: [DVNamedFilm]
    
    // Format breakdown
    let formatBreakdown: [FormatBreakdownData]
    /// The same per-format tallying as `formatBreakdown`, but over `unpurchasedOnDisc`'s
    /// population — films with a Release entered and none of them purchased — instead of
    /// the purchased one. See where it's built for the priority rule that keeps its three
    /// rows mutually exclusive and summing to `unpurchasedOnDisc`.
    let unpurchasedFormatBreakdown: [FormatBreakdownData]

    // 4K statistics
    let fourKStats: FourKStatistics
    
    /// The per-year purchase picture as ONE row per year, counts and percentages together,
    /// newest year first. The Purchases by Year chart reads it (on the tab and, through the
    /// same builders, in the PDF). (Two chart-shaped arrays, `purchasesByYear` and `purchasesByYearDetailed`,
    /// used to be derived beside it from the same aggregation; nothing read them.)
    let purchaseYearTable: [PurchaseYearRow]
    
    // Films by decade
    let filmsByDecade: [(decade: String, count: Int)]
    /// Films per release year, every year from the oldest to the newest (empty years 0).
    let filmsByYear: [(year: Int, count: Int)]
    
    // Aspect ratio distribution
    let aspectRatioDistribution: [(ratio: String, count: Int, percent: Double)]
    
    // Audio and source distribution
    let audioChannelDistribution: [(String, Int)]

    /// The population `audioChannelDistribution`'s channel rows are a breakdown of: the
    /// number of purchased releases that carried an audio-channel tag.
    ///
    /// A separate figure from `totalPurchasedReleases` because the two count different
    /// things. `totalPurchasedReleases` counts purchased TOP-LEVEL releases — a combo pack
    /// is one release there, because its purchase, cost and condition belong to the package
    /// as a whole. Audio channels do not: the 4K disc and the Blu-ray inside one package
    /// carry their own mixes, so both are tallied. Dividing the channel counts by
    /// `totalPurchasedReleases`, as the PDF export did, measured them against a population
    /// they were not drawn from and could report a share above 100% for any library
    /// holding combo packs.
    ///
    /// Releases with no channel tag are excluded from both sides, so the channel rows are
    /// shares of what is actually known rather than of what was bought.
    ///
    let audioChannelDenominator: Int
    /// Same breakdown and shape as `audioChannelDistribution`, over every release
    /// (purchased or not) — the Audio card's "All" tab; `audioChannelDistribution`
    /// itself is that card's "Purchased Only" tab.
    let audioChannelDistributionAll: [(String, Int)]
    let audioChannelDenominatorAll: Int
    /// Per-codec breakdown of `Release.audioFormat`, in `ReleaseAudioFormat.hdOptions`
    /// order, over purchased releases and over every release respectively — the Audio
    /// card's two tabs. A DVD's narrower vocabulary is a subset of the same list, so one
    /// ordering serves both formats.
    let audioCodecs: [DVTally]
    let audioCodecsAll: [DVTally]
    let sourceDistribution: [(String, Int)]
    /// Films with no Blu-ray or 4K UHD release entered, or nil unless Info Complete is on
    /// and the library is over 99% complete: only then is "not entered" trustworthy as
    /// "not available".
    let notAvailableOnBluRay: Int?
    
    // Ratings statistics
    let notYetRatedFilms: Int
    let notYetRatedPercent: Int
    /// Films behind `notYetRatedFilms`, for the Needs Attention card's popover.
    let notYetRatedFilmsItems: [DVNamedFilm]
    let averageRating: String
    let ratingsBreakdown: [(rating: Int, count: Int, percent: Double)]
    
    /// Local midnight of a stored purchase date, or nil when the field is empty or not a
    /// real day.
    ///
    /// Read with the app's one date parser. The Releases tab writes purchase dates as
    /// `yyyy.MM.dd` (`StorageDateFormatters.dot`), but this used to accept `yyyy-MM-dd`
    /// only — so every real purchase date came back nil and the purchase-by-year and
    /// spending-by-year figures were built from none of them. `parseDate` takes the dot
    /// form on its fast path and still accepts the dash and slash spellings.
    static func purchaseDay(_ text: String, calendar: Calendar) -> Date? {
        guard !text.isEmpty else { return nil }
        return parseDate(from: text).map { calendar.startOfDay(for: $0) }
    }

    /// - Parameter showInfoComplete: Whether the "Not available on Blu-ray" row may be
    ///   vended (it is only trustworthy once every film's releases are entered, so it is
    ///   gated on the Info Complete preference plus a 99% complete library). Passed in
    ///   rather than read from `Preferences` here so this initializer can run off the
    ///   main actor; `Preferences` is read on the main actor only, by convention.
    init(films: [FilmSnapshot], showInfoComplete: Bool = Preferences.showInfoComplete) {
        let totalFilms = films.count
        self.totalFilms = totalFilms
        
        var onDiscCount = 0
        var unpurchasedOnDiscCount = 0
        var missingArtworkCount = 0
        var missingArtworkItems: [DVNamedFilm] = []
        var missingReleaseArtworkCount = 0
        var missingReleaseArtworkItems: [DVNamedFilm] = []
        var lossyBDAudioCount = 0
        var lossyBDAudioItems: [DVNamedFilm] = []
        var colorCount = 0
        var editedCount = 0
        var completeCount = 0
        var incompleteItems: [DVNamedFilm] = []
        var decadeCounts: [String: Int] = [:]
        var yearCounts: [Int: Int] = [:]
        var ratioCounts: [String: Int] = [:]
        var audioCounts: [String: Int] = [:]
        var audioCountsAll: [String: Int] = [:]
        var codecCounts: [String: Int] = [:]
        var codecCountsAll: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var purchasedReleases: [ReleaseSnapshot] = []

        /// Purchased releases that actually carried an audio-channel tag — the population
        /// `audioCounts` is a breakdown OF, and therefore the only correct denominator for
        /// it. It is deliberately not `totalPurchasedReleases`: this tally counts a combo
        /// pack's child disc (which has its own channel tag) while `purchasedReleases`
        /// counts top-level releases only, so dividing one by the other measured a count
        /// against a population it was not drawn from and could report a share above 100%.
        /// See `audioChannelDenominator`.
        var audioTaggedReleaseCount = 0
        var audioTaggedReleaseCountAll = 0

        /// Films with at least one purchased top-level release — the population
        /// `missingReleaseArtworkCount` is drawn from, and so its denominator. That count
        /// is a count of FILMS; it used to be divided by `totalPurchasedReleases`, a count
        /// of RELEASES, which is a different population and larger than the numerator's own
        /// only by coincidence.
        var filmsWithPurchasedReleasesCount = 0

        // 4K statistics — accumulated in the main loop to avoid extra array passes.
        var fourKFilmCount = 0
        var nativeFourKFilmCount = 0
        var upscaledFourKFilmCount = 0
        var purchasedFourKFilmCount = 0
        var purchasedNativeFourKFilmCount = 0
        var purchasedUpscaledFourKFilmCount = 0
        
        var notAvailableOnBluRayCount = 0
        
        // Process each film
        for film in films {
            // Films on disc: a film with at least one PURCHASED release, not merely one
            // that has a release entered at all. A release can be logged before it's
            // actually owned (wishlist entries, upcoming pre-orders), and counting those
            // here is what let this figure disagree with the three format rows below it,
            // which have always been purchase-gated. Multiple purchased releases (a 4K
            // combo pack plus a separately-owned DVD, say) still count the film once.
            if film.releases.contains(where: { $0.purchased }) {
                onDiscCount += 1
            } else if !film.releases.isEmpty {
                // Has at least one Release entered, but none of them purchased — the
                // population "Unpurchased Films Available on Disc" is drawn from.
                // Mutually exclusive with the branch above by construction: a film with
                // any purchased release goes there instead, never both.
                unpurchasedOnDiscCount += 1
            }
            
            // Missing poster artwork
            if film.posterUID.isEmpty {
                missingArtworkCount += 1
                missingArtworkItems.append(DVNamedFilm(film))
            }

            // Missing release artwork - check if any purchased release has missing artwork
            // Artwork is a trait of the overall release container (the 4K parent and its
            // bundled Blu-ray child ship in one package), so only the top-level release counts.
            let hasMissingReleaseArtwork = film.releases.contains { release in
                release.isTopLevel && release.purchased && release.hasArtwork.lowercased().contains("no")
            }
            if hasMissingReleaseArtwork {
                missingReleaseArtworkCount += 1
                missingReleaseArtworkItems.append(DVNamedFilm(film))
            }

            // Lossy BD Audio - check if any release is 4K UHD or Blu-ray with lossy audio
            let hasLossyBDAudio = film.releases.contains { release in
                (release.format == ReleaseFormat.uhd4K.rawValue || release.format == ReleaseFormat.bluRay.rawValue) &&
                ReleaseAudioFormat.isLossyOnHDDisc(release.audioFormat)
            }
            if hasLossyBDAudio {
                lossyBDAudioCount += 1
                lossyBDAudioItems.append(DVNamedFilm(film))
            }
            
            // Color films
            if film.color {
                colorCount += 1
            }
            
            // Edited films
            if film.edited {
                editedCount += 1
            }
            
            // Info complete
            if film.infoComplete {
                completeCount += 1
            } else {
                incompleteItems.append(DVNamedFilm(film))
            }
            
            // Decade distribution
            if !film.releaseYear.isEmpty,
               let year = Int(film.releaseYear),
               year >= 1900 {
                let decade = (year / 10) * 10
                let decadeStr = "\(decade)s"
                decadeCounts[decadeStr, default: 0] += 1
                yearCounts[year, default: 0] += 1
            }
            
            // Aspect ratio distribution
            if !film.aspectRatio.isEmpty {
                // An open-matte tag ("1.78:1 (Open matte)") carries the same numeric
                // ratio as its bare form and belongs in the same band — the qualifier
                // describes how the transfer was framed, not a different width-to-height
                // value, so it is stripped before parsing rather than left to make
                // `extractRatio` fail and fall into "Other" (which is what happened
                // before this stripped it: EVERY open-matte film landed there,
                // regardless of its actual ratio).
                let ratio = film.aspectRatio
                    .replacingOccurrences(of: AspectRatioVocabulary.openMatteQualifier, with: "")
                    .trimmingCharacters(in: .whitespaces)
                let category: String
                if ratio.lowercased().contains("hybrid") {
                    category = "Hybrid"
                } else if let ratioValue = Self.extractRatio(ratio) {
                    if ratioValue < 1.5 {
                        category = "Pillarboxed"
                    } else if ratioValue < 2.0 {
                        category = "Fullscreen"
                    } else {
                        category = "Letterboxed"
                    }
                } else {
                    category = "Other"
                }
                ratioCounts[category, default: 0] += 1
            }
            
            // Also collect audio channels and codecs from releases, and count object-based
            // mixes. The "All" tallies run over every release; the purchased-gated ones
            // beneath them are the "Purchased Only" tab's population.
            for release in film.releases {
                if !release.audioChannels.isEmpty {
                    audioCountsAll[release.audioChannels, default: 0] += 1
                    audioTaggedReleaseCountAll += 1
                }
                if !release.audioFormat.isEmpty {
                    codecCountsAll[release.audioFormat, default: 0] += 1
                }
                guard release.purchased else { continue }
                if !release.audioChannels.isEmpty {
                    audioCounts[release.audioChannels, default: 0] += 1
                    audioTaggedReleaseCount += 1
                }
                if !release.audioFormat.isEmpty {
                    codecCounts[release.audioFormat, default: 0] += 1
                }
            }
            
            // Source distribution
            if !film.digitalSource.isEmpty {
                sourceCounts[film.digitalSource, default: 0] += 1
            }
            
            // Collect purchased releases (top-level only): this collection feeds the total
            // purchased-release count, average cost, and new/used tallies. A combo child mirrors
            // its parent's purchase/cost/condition, so counting it would double those figures.
            let purchasedCountBefore = purchasedReleases.count
            for release in film.releases where release.purchased && release.isTopLevel {
                purchasedReleases.append(release)
            }
            if purchasedReleases.count > purchasedCountBefore {
                filmsWithPurchasedReleasesCount += 1
            }
            
            // Not available on Blu-ray - films without any Blu-ray or 4K UHD release
            let hasBluRayOrFourK = film.releases.contains { release in
                release.format == ReleaseFormat.bluRay.rawValue || release.format == ReleaseFormat.uhd4K.rawValue
            }
            if !hasBluRayOrFourK {
                notAvailableOnBluRayCount += 1
            }
            
            // 4K and BD statistics — accumulated here to avoid extra array passes after the loop.
            var filmHasFourK = false
            var filmHasNativeFourK = false
            var filmHasUpscaledFourK = false
            var filmHasPurchasedFourK = false
            var filmHasPurchasedNativeFourK = false
            var filmHasPurchasedUpscaledFourK = false
            for release in film.releases {
                if release.format == ReleaseFormat.uhd4K.rawValue {
                    filmHasFourK = true
                    if release.masterType == ReleaseMasterType.nativeFourK { filmHasNativeFourK = true }
                    if release.masterType == ReleaseMasterType.upscaled    { filmHasUpscaledFourK = true }
                    if release.purchased {
                        filmHasPurchasedFourK = true
                        if release.masterType == ReleaseMasterType.nativeFourK { filmHasPurchasedNativeFourK = true }
                        if release.masterType == ReleaseMasterType.upscaled    { filmHasPurchasedUpscaledFourK = true }
                    }
                }
            }
            if filmHasFourK              { fourKFilmCount += 1 }
            if filmHasNativeFourK        { nativeFourKFilmCount += 1 }
            if filmHasUpscaledFourK      { upscaledFourKFilmCount += 1 }
            if filmHasPurchasedFourK     { purchasedFourKFilmCount += 1 }
            if filmHasPurchasedNativeFourK  { purchasedNativeFourKFilmCount += 1 }
            if filmHasPurchasedUpscaledFourK { purchasedUpscaledFourKFilmCount += 1 }
        }
        
        // Calculate derived statistics
        self.filmsOnDisc = onDiscCount
        self.filmsOnDiscPercent = totalFilms > 0 ? Int((Double(onDiscCount) / Double(totalFilms) * 100).rounded()) : 0

        self.unpurchasedOnDisc = unpurchasedOnDiscCount

        // "Digital Only" is every film with NEITHER a purchased release NOR an unpurchased
        // one entered — i.e. no Release object at all. Subtracting only `onDiscCount` here
        // (as this used to) double-counted an unpurchased-but-entered film as "digital
        // only" once `onDiscCount` narrowed to purchases alone; it has always had a Release
        // record, just not a purchased one, so it belongs to neither on-disc row's
        // complement.
        let digitalOnlyCount = totalFilms - onDiscCount - unpurchasedOnDiscCount
        self.digitalOnlyFilms = digitalOnlyCount

        self.missingArtwork = missingArtworkCount
        self.missingArtworkItems = missingArtworkItems
        self.missingArtworkPercent = totalFilms > 0 ? Int((Double(missingArtworkCount) / Double(totalFilms) * 100).rounded()) : 0
        
        self.colorFilms = colorCount
        self.bwFilms = totalFilms - colorCount
        
        self.editedFilms = editedCount
        self.editedPercent = totalFilms > 0 ? Int((Double(editedCount) / Double(totalFilms) * 100).rounded()) : 0
        
        self.infoComplete = completeCount
        self.infoCompletePercent = totalFilms > 0 ? Int((Double(completeCount) / Double(totalFilms) * 100).rounded()) : 0
        self.infoCompleteItems = incompleteItems
        
        // Films by decade
        self.filmsByDecade = decadeCounts.sorted { $0.key < $1.key }.map { (decade: $0.key, count: $0.value) }
        if let first = yearCounts.keys.min(), let last = yearCounts.keys.max() {
            self.filmsByYear = (first...last).map { (year: $0, count: yearCounts[$0] ?? 0) }
        } else {
            self.filmsByYear = []
        }
        
        // Aspect ratio distribution
        let totalWithRatio = ratioCounts.values.reduce(0, +)
        // Ties broken on the class name, not left to `ratioCounts`'s own iteration order.
        // Swift seeds Dictionary hashing per process, so two classes holding the same count
        // came out in a different order on every launch — which put the rows of the PDF's
        // Aspect Ratios tile, and the bars of the on-screen chart, in an order that changed
        // between two exports of an unchanged library. Everything else this export orders
        // already carries an explicit total order for exactly that reason.
        self.aspectRatioDistribution = ratioCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map {
            let percent = totalWithRatio > 0 ? Double($0.value) / Double(totalWithRatio) * 100 : 0
            return (ratio: $0.key, count: $0.value, percent: percent)
        }
        
        // Audio channel distribution with custom ordering - always show all options.
        // Matches `audioChannelDistributionAll`'s row set exactly (differing only in
        // counts): object-based mixes are a format flag, not a channel count, and are
        // already broken out in `audioCodecs`, so they do not belong in this bar.
        var orderedAudioChannels: [(String, Int)] = []

        // Add combined channels in order - always show all, even with 0 count
        // The row LABELS are display copy, but the subscripts are STORED values — they key
        // into counts tallied from release.audioChannels — so they come from the
        // vocabulary rather than being respelled here.
        func channelCount(_ tags: String...) -> Int {
            tags.reduce(0) { $0 + (audioCounts[$1] ?? 0) }
        }
        orderedAudioChannels.append(("7.1 / 6.1",
            channelCount(ReleaseAudioChannels.surround71, ReleaseAudioChannels.surround61)))
        orderedAudioChannels.append(("5.1 / 5.0 / 4.0",
            channelCount(ReleaseAudioChannels.surround51, ReleaseAudioChannels.surround50,
                         ReleaseAudioChannels.surround40)))
        orderedAudioChannels.append(("3.0 / 2.0",
            channelCount(ReleaseAudioChannels.surround30, ReleaseAudioChannels.stereo20)))
        orderedAudioChannels.append(("2.0 Mono / 1.0",
            channelCount(ReleaseAudioChannels.mono20, ReleaseAudioChannels.mono10)))
        
        self.audioChannelDistribution = orderedAudioChannels

        // The same four rows over every release, for the Audio card's "All" scope.
        func channelCountAll(_ tags: String...) -> Int {
            tags.reduce(0) { $0 + (audioCountsAll[$1] ?? 0) }
        }
        self.audioChannelDistributionAll = [
            ("7.1 / 6.1", channelCountAll(ReleaseAudioChannels.surround71, ReleaseAudioChannels.surround61)),
            ("5.1 / 5.0 / 4.0", channelCountAll(ReleaseAudioChannels.surround51, ReleaseAudioChannels.surround50,
                                                ReleaseAudioChannels.surround40)),
            ("3.0 / 2.0", channelCountAll(ReleaseAudioChannels.surround30, ReleaseAudioChannels.stereo20)),
            ("2.0 Mono / 1.0", channelCountAll(ReleaseAudioChannels.mono20, ReleaseAudioChannels.mono10)),
        ]
        self.audioChannelDenominatorAll = audioTaggedReleaseCountAll

        self.audioCodecs = ReleaseAudioFormat.hdOptions.map { DVTally($0, codecCounts[$0] ?? 0, of: codecCounts.values.reduce(0, +)) }
        self.audioCodecsAll = ReleaseAudioFormat.hdOptions.map { DVTally($0, codecCountsAll[$0] ?? 0, of: codecCountsAll.values.reduce(0, +)) }

        // Source distribution with custom ordering
        // These are STORED values used as dictionary keys into sourceCounts, not display
        // labels — the remastered forms must be byte-identical to what the FilmSheet
        // writes, so they are composed through FilmDigitalSource rather than spelled out.
        // Descending by quality here; the picker's own list ascends. Both orderings are
        // built from the one vocabulary.
        let remasteredDVD = FilmDigitalSource.compose(source: FilmDigitalSource.dvd,
                                                      remastered: true)
        let sourceOrder = [
            FilmDigitalSource.compose(source: FilmDigitalSource.blurayDisc, remastered: true),
            FilmDigitalSource.blurayDisc,
            remasteredDVD, // Only shown if it has items
            FilmDigitalSource.dvd,
            FilmDigitalSource.download4K,
            FilmDigitalSource.download1080p,
            FilmDigitalSource.download720p,
            FilmDigitalSource.download540p,
            FilmDigitalSource.download480p,
            FilmDigitalSource.download360p
        ]

        var orderedSources: [(String, Int)] = []

        // Add sources in order
        for source in sourceOrder {
            if source == remasteredDVD {
                // Only add Remastered DVD if it has items
                if let count = sourceCounts[source], count > 0 {
                    orderedSources.append((source, count))
                }
            } else {
                let count = sourceCounts[source] ?? 0
                orderedSources.append((source, count))
            }
            
            // Add divider after DVD
            if source == FilmDigitalSource.dvd {
                orderedSources.append(("---", 0))
            }
        }

        // Every other value a film holds, after the ladder: the field is an open
        // vocabulary (a remastered download, a value from an older build), and a film
        // left out here would be counted as having no source at all — which is how the
        // "4K download" tier, the metadata importer's default for anything above 1080p,
        // went missing from this list and from the PDF's Digital sources tile.
        let listed = Set(sourceOrder)
        orderedSources += sourceCounts
            .filter { !listed.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        self.sourceDistribution = orderedSources
        
        self.notAvailableOnBluRay = showInfoComplete && infoCompletePercent > 99 ? notAvailableOnBluRayCount : nil

        // Purchase statistics
        self.hasPurchaseData = !purchasedReleases.isEmpty
        self.totalPurchasedReleases = purchasedReleases.count
        
        let newCount = purchasedReleases.filter { $0.condition.lowercased() == "new" }.count
        self.newReleases = newCount
        self.newReleasesPercent = totalPurchasedReleases > 0 ?
            Int((Double(newCount) / Double(totalPurchasedReleases) * 100).rounded()) : 0
        
        let usedCount = purchasedReleases.filter { $0.condition.lowercased() == "used" }.count
        self.usedReleases = usedCount
        self.usedReleasesPercent = totalPurchasedReleases > 0 ?
            Int((Double(usedCount) / Double(totalPurchasedReleases) * 100).rounded()) : 0
        
        // Average cost. Computed ONCE, here, in both the display form and the numeric form
        // the per-year "at or below average" column compares against below. The two used to
        // be derived from two separate `filter { $0.cost > 0 }` passes over the same array
        // — duplicated work, and two definitions of one number that nothing kept in step.
        let costValues = purchasedReleases.compactMap { $0.cost > 0 ? $0.cost : nil }
        let numericAvgCost = costValues.isEmpty
            ? 0
            : costValues.reduce(0, +) / Double(costValues.count)
        self.averageCost = costValues.isEmpty ? "—" : Fmt.dollars(numericAvgCost)

        self.missingReleaseArtwork = missingReleaseArtworkCount
        self.missingReleaseArtworkItems = missingReleaseArtworkItems

        // Lossy BD audio — a count of FILMS (a film counts once if any of its
        // 4K UHD or Blu-ray releases carries a lossy track), so measured against the films
        // that have such a release at all. That population is the complement of
        // `notAvailableOnBluRayCount`, already tallied in the loop above, so it costs
        // nothing to derive.
        //
        // The denominator used to be a count of top-level 4K/Blu-ray RELEASES, which is
        // neither the numerator's population nor a superset of it: a film whose only
        // lossy-audio disc is a combo pack's child release incremented the numerator
        // without contributing to that denominator at all, so the reported share could
        // exceed 100%.
        let filmsWithBluRayOrFourK = totalFilms - notAvailableOnBluRayCount
        self.lossyBDAudio = lossyBDAudioCount
        self.lossyBDAudioItems = lossyBDAudioItems
        self.lossyBDAudioPercent = filmsWithBluRayOrFourK > 0 ?
            Int((Double(lossyBDAudioCount) / Double(filmsWithBluRayOrFourK) * 100).rounded()) : 0

        // The population the audio-channel breakdown is a share of. See
        // `audioTaggedReleaseCount`.
        self.audioChannelDenominator = audioTaggedReleaseCount
        
        // Format breakdown — one pass over FILMS, not releases, and bucketed so the three
        // rows are mutually exclusive and sum to `onDiscCount` (the "Films on Disc" row
        // they hang under).
        //
        // Counting purchased RELEASES instead — the former approach — over- and
        // double-counted: a film with two purchased Blu-ray editions inflated the Blu-ray
        // row by one, and a 4K combo pack's bundled Blu-ray child counted the same film
        // again under Blu-ray, so the three rows never actually summed to the parent row's
        // total. Bucketing FILMS avoids the first; the priority order below avoids the
        // second by giving each film to exactly one row.
        //
        // The three rows are not symmetric, by design (this mirrors the request that
        // introduced them): "4K" counts every film with a purchased 4K release, whether or
        // not it also has a purchased Blu-ray or DVD — a combo pack's bundled Blu-ray is
        // expected overlap, not a separate acquisition. "Blu-ray only" excludes a film with
        // a purchased 4K (so a combo pack is not also counted here) but does NOT look at
        // DVD — a film with both a purchased Blu-ray and a purchased DVD, neither a 4K, is
        // still "Blu-ray only" in the sense that its non-4K, non-overlapping-with-4K
        // purchase is a Blu-ray. "DVD only" is the strictest: no purchased 4K AND no
        // purchased Blu-ray at all. That asymmetry is what makes every film land in
        // exactly one bucket.
        var fourKTally    = (count: 0, costTotal: 0.0, costCount: 0)
        var bluRayTally   = (count: 0, costTotal: 0.0, costCount: 0)
        var dvdTally      = (count: 0, costTotal: 0.0, costCount: 0)

        /// Accumulates one film's contribution to a bucket: the film itself counts once,
        /// and its average-cost sample comes from that film's own purchased top-level
        /// releases in `format` (a combo child's cost is locked to its parent's — one
        /// price paid once — so only top-level releases contribute here — matching how
        /// `purchasedReleases`, gathered the same way just above, feeds every other
        /// average-cost figure in this initializer).
        func accumulate(_ tally: inout (count: Int, costTotal: Double, costCount: Int),
                        film: FilmSnapshot, format: ReleaseFormat) {
            tally.count += 1
            for release in film.releases
            where release.purchased && release.isTopLevel && release.format == format.rawValue {
                if release.cost > 0 {
                    tally.costTotal += release.cost
                    tally.costCount += 1
                }
            }
        }

        for film in films {
            let hasPurchasedFourK = film.releases.contains {
                $0.purchased && $0.format == ReleaseFormat.uhd4K.rawValue
            }
            let hasPurchasedBluRay = film.releases.contains {
                $0.purchased && $0.format == ReleaseFormat.bluRay.rawValue
            }
            let hasPurchasedDVD = film.releases.contains {
                $0.purchased && $0.format == ReleaseFormat.dvd.rawValue
            }

            if hasPurchasedFourK {
                accumulate(&fourKTally, film: film, format: .uhd4K)
            } else if hasPurchasedBluRay {
                accumulate(&bluRayTally, film: film, format: .bluRay)
            } else if hasPurchasedDVD {
                accumulate(&dvdTally, film: film, format: .dvd)
            }
        }

        /// The three rows' shared denominator: `total` is `onDiscCount` for the purchased
        /// breakdown and `unpurchasedOnDiscCount` for the unpurchased one below — each is
        /// a film tally of that row's own population, so its three percentages sum to that
        /// population's own share of the library for the same reason its three counts sum
        /// to the population's own count. Bound to a local for the same
        /// definite-initialization reason `purchasedReleaseTotal` used to be.
        func breakdownRow(_ format: ReleaseFormat, label: String, total: Int,
                          _ tally: (count: Int, costTotal: Double, costCount: Int)) -> FormatBreakdownData {
            FormatBreakdownData(
                format: label,
                count: tally.count,
                percent: total > 0 ? Double(tally.count) / Double(total) * 100 : 0,
                avgCost: tally.costCount > 0
                    ? Fmt.dollars(tally.costTotal / Double(tally.costCount))
                    : "—")
        }

        // Order is `ReleaseFormat.displayRank` — 4K, Blu-ray, DVD — the app's one format
        // ladder, rather than a hand-written sequence that could drift from it.
        self.formatBreakdown = [
            breakdownRow(.uhd4K, label: "Purchased \(ReleaseFormat.uhd4K.rawValue)", total: onDiscCount, fourKTally),
            breakdownRow(.bluRay, label: "Purchased \(ReleaseFormat.bluRay.rawValue) only", total: onDiscCount, bluRayTally),
            breakdownRow(.dvd, label: "Purchased \(ReleaseFormat.dvd.rawValue) only", total: onDiscCount, dvdTally),
        ]

        // MARK: Unpurchased format breakdown
        //
        // The same three-way, mutually-exclusive bucketing as the purchased breakdown
        // above, over the OTHER population: a film with a Release entered but none of
        // them purchased. Since every release on such a film is by definition
        // unpurchased, "has a 4K release at all" is what stands in for "has a purchased
        // 4K release" in the priority test — there is no purchased/unpurchased
        // distinction left to make within this population, only which format(s) it has
        // entered.
        //
        // No cost is accumulated: an unpurchased release's `cost` is a wishlist figure,
        // not an acquisition price, and averaging it here would answer a question this
        // row was never meant to ask. `avgCost` therefore always reads "—".
        var unpurchasedFourKTally  = (count: 0, costTotal: 0.0, costCount: 0)
        var unpurchasedBluRayTally = (count: 0, costTotal: 0.0, costCount: 0)
        var unpurchasedDVDTally   = (count: 0, costTotal: 0.0, costCount: 0)

        for film in films {
            guard !film.releases.contains(where: { $0.purchased }), !film.releases.isEmpty
            else { continue }

            let hasFourK  = film.releases.contains { $0.format == ReleaseFormat.uhd4K.rawValue }
            let hasBluRay = film.releases.contains { $0.format == ReleaseFormat.bluRay.rawValue }
            let hasDVD    = film.releases.contains { $0.format == ReleaseFormat.dvd.rawValue }

            if hasFourK {
                unpurchasedFourKTally.count += 1
            } else if hasBluRay {
                unpurchasedBluRayTally.count += 1
            } else if hasDVD {
                unpurchasedDVDTally.count += 1
            }
        }

        self.unpurchasedFormatBreakdown = [
            breakdownRow(.uhd4K, label: "Unpurchased \(ReleaseFormat.uhd4K.rawValue)",
                        total: unpurchasedOnDiscCount, unpurchasedFourKTally),
            breakdownRow(.bluRay, label: "Unpurchased \(ReleaseFormat.bluRay.rawValue) only",
                        total: unpurchasedOnDiscCount, unpurchasedBluRayTally),
            breakdownRow(.dvd, label: "Unpurchased \(ReleaseFormat.dvd.rawValue) only",
                        total: unpurchasedOnDiscCount, unpurchasedDVDTally),
        ]

        // 4K Statistics — all counts were accumulated in the main loop above, so no
        // extra array passes are needed here.
        let fourKPurchaseRate = fourKFilmCount > 0 ?
            Int((Double(purchasedFourKFilmCount) / Double(fourKFilmCount) * 100).rounded()) : 0
        
        self.fourKStats = FourKStatistics(
            filmsWithFourK: fourKFilmCount,
            filmsWithFourKPercent: totalFilms > 0 ? Int((Double(fourKFilmCount) / Double(totalFilms) * 100).rounded()) : 0,
            filmsWithNativeFourK: nativeFourKFilmCount,
            filmsWithUpscaledFourK: upscaledFourKFilmCount,
            filmsWithPurchasedFourK: purchasedFourKFilmCount,
            filmsWithPurchasedNativeFourK: purchasedNativeFourKFilmCount,
            filmsWithPurchasedUpscaledFourK: purchasedUpscaledFourKFilmCount,
            fourKPurchaseRate: fourKPurchaseRate
        )
        
        // Purchases by year — one aggregation, one pass over the purchase dates.
        var yearDetailedData: [String: (newCount: Int, usedCount: Int, belowAvgCount: Int, totalCount: Int)] = [:]

        let calendar = AppCalendar.current
        for release in purchasedReleases where !release.purchaseDate.isEmpty {
            if let date = Self.purchaseDay(release.purchaseDate, calendar: calendar) {
                let year = calendar.component(.year, from: date)
                let yearStr = String(year)

                var yearData = yearDetailedData[yearStr] ?? (newCount: 0, usedCount: 0, belowAvgCount: 0, totalCount: 0)

                // Count by condition
                if release.condition.lowercased() == "new" {
                    yearData.newCount += 1
                } else if release.condition.lowercased() == "used" {
                    yearData.usedCount += 1
                }

                // Count if below or equal to the all-time average cost (computed once,
                // above, and shared with `averageCost`).
                if release.cost > 0 && release.cost <= numericAvgCost {
                    yearData.belowAvgCount += 1
                }

                yearData.totalCount += 1
                yearDetailedData[yearStr] = yearData
            }
        }

        let sortedDetailedYears = yearDetailedData.sorted { $0.key > $1.key }

        self.purchaseYearTable = sortedDetailedYears.map { entry in
            let yearTotal = Double(entry.value.totalCount)
            func shareOfYear(_ value: Int) -> Double {
                yearTotal > 0 ? Double(value) / yearTotal * 100 : 0
            }
            return PurchaseYearRow(
                year: entry.key,
                count: entry.value.totalCount,
                usedCount: entry.value.usedCount,
                newCount: entry.value.newCount,
                atOrBelowAverageCount: entry.value.belowAvgCount,
                atOrBelowAveragePercentOfYear: shareOfYear(entry.value.belowAvgCount))
        }
        
        // Ratings statistics
        var ratingCounts: [Int: Int] = [:]
        var totalRatingsSum = 0
        var filmsWithRatings = 0
        var notYetRatedItems: [DVNamedFilm] = []

        for film in films {
            let rating = film.userRating
            if rating > 0 && rating <= 10 {
                ratingCounts[rating, default: 0] += 1
                totalRatingsSum += rating
                filmsWithRatings += 1
            } else {
                notYetRatedItems.append(DVNamedFilm(film))
            }
        }
        
        // Not-yet-rated films
        let notRatedCount = totalFilms - filmsWithRatings
        self.notYetRatedFilms = notRatedCount
        self.notYetRatedFilmsItems = notYetRatedItems
        self.notYetRatedPercent = totalFilms > 0 ? Int((Double(notRatedCount) / Double(totalFilms) * 100).rounded()) : 0
        
        // Average rating
        if filmsWithRatings > 0 {
            let average = Double(totalRatingsSum) / Double(filmsWithRatings)
            self.averageRating = Fmt.fixed(average, 2)
        } else {
            self.averageRating = "—"
        }
        
        // Ratings breakdown (ratings 1-10 with counts and percentages)
        var breakdown: [(rating: Int, count: Int, percent: Double)] = []
        for rating in 1...10 {
            let count = ratingCounts[rating] ?? 0
            let percent = filmsWithRatings > 0 ? Double(count) / Double(filmsWithRatings) * 100 : 0
            breakdown.append((rating: rating, count: count, percent: percent))
        }
        self.ratingsBreakdown = breakdown
    }
    
    private static func extractRatio(_ ratioString: String) -> Double? {
        let components = ratioString.components(separatedBy: ":")
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              height > 0 else {
            return nil
        }
        return width / height
    }
    
}
