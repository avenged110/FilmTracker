// MARK: - DVLibraryStats.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The whole-library statistics model behind the Data Visualizations report and the PDF's sheet: FormatBreakdownData,
/// FourKStatistics, PurchaseYearRow, and LibraryStatistics. The year-scoped and derived figures live in 27.43 DVLibraryInsights.swift.

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
/// One calendar year of purchasing, as the Purchases by Year chart draws it. The below-average percentage is a share of that year's
/// purchases, showing what the year was like rather than how big it was.
struct PurchaseYearRow: Sendable {
    let year: String
    /// Releases bought in this year.
    let count: Int
    let usedCount: Int
    let newCount: Int
    /// Purchases at or below the average price across the whole collection, not this year's own average. So the column answers
    /// "was this a good year to buy" rather than restating each year's midpoint.
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
    /// Films behind `missingArtwork`, for the Needs Attention popover.
    let missingArtworkItems: [DVNamedFilm]
    let colorFilms: Int
    let bwFilms: Int
    let editedFilms: Int
    let editedPercent: Int
    let infoComplete: Int
    let infoCompletePercent: Int
    /// Films not marked info complete, for the Needs Attention popover.
    let infoCompleteItems: [DVNamedFilm]
    
    /// Purchase statistics
    let hasPurchaseData: Bool
    let totalPurchasedReleases: Int
    let newReleases: Int
    let newReleasesPercent: Int
    let usedReleases: Int
    let usedReleasesPercent: Int
    let averageCost: String
    let missingReleaseArtwork: Int
    /// Films behind `missingReleaseArtwork`, for the Needs Attention popover.
    let missingReleaseArtworkItems: [DVNamedFilm]
    let lossyBDAudio: Int
    let lossyBDAudioPercent: Int
    /// Films behind `lossyBDAudio`, for the Needs Attention popover.
    let lossyBDAudioItems: [DVNamedFilm]
    
    /// Format breakdown
    let formatBreakdown: [FormatBreakdownData]
    /// The same per-format tally as `formatBreakdown`, over `unpurchasedOnDisc`'s films (a Release entered, none purchased).
    /// The priority rule where it is built keeps its three rows exclusive and summing to `unpurchasedOnDisc`.
    let unpurchasedFormatBreakdown: [FormatBreakdownData]

    /// 4K statistics
    let fourKStats: FourKStatistics
    
    /// The per-year purchase figures, one row per year with counts and percentages, newest year first. The Purchases by Year chart
    /// reads it, on the tab and in the PDF.
    let purchaseYearTable: [PurchaseYearRow]
    
    /// Films by decade
    let filmsByDecade: [(decade: String, count: Int)]
    /// Films per release year, from the oldest to the newest, with 0 for empty years.
    let filmsByYear: [(year: Int, count: Int)]
    
    /// Aspect ratio distribution
    let aspectRatioDistribution: [(ratio: String, count: Int, percent: Double)]
    
    /// Audio and source distribution
    let audioChannelDistribution: [(String, Int)]

    /// The population that `audioChannelDistribution` breaks down: purchased releases with an audio-channel tag.
    /// This is not `totalPurchasedReleases`, which counts top-level releases only. A combo pack is one release there, but its 4K and
    /// Blu-ray discs each carry their own audio mix, so both are tallied here. Dividing by the top-level count could report a share above 100%.
    /// Releases with no channel tag are excluded from both sides.
    let audioChannelDenominator: Int
    /// The same breakdown as `audioChannelDistribution`, over every release, purchased or not. It backs the Audio card's "All" tab.
    let audioChannelDistributionAll: [(String, Int)]
    let audioChannelDenominatorAll: Int
    /// Per-codec breakdown of `Release.audioFormat`, in `ReleaseAudioFormat.hdOptions` order. It covers purchased releases, and then all
    /// releases, for the Audio card's two tabs. A DVD's vocabulary is a subset of that list, so one order serves both formats.
    let audioCodecs: [DVTally]
    let audioCodecsAll: [DVTally]
    let sourceDistribution: [(String, Int)]
    /// Films with no Blu-ray or 4K UHD release entered. It is nil unless Info Complete is on and the library is over 99% complete,
    /// since only then does "not entered" mean "not available".
    let notAvailableOnBluRay: Int?
    
    /// Ratings statistics
    let notYetRatedFilms: Int
    let notYetRatedPercent: Int
    /// Films behind `notYetRatedFilms`, for the Needs Attention card's popover.
    let notYetRatedFilmsItems: [DVNamedFilm]
    let averageRating: String
    let ratingsBreakdown: [(rating: Int, count: Int, percent: Double)]
    
    /// Local midnight of a stored purchase date, or nil when the field is empty or not a real day. Dates are stored as `yyyy.MM.dd`
    /// (`StorageDateFormatters.dot`), and the app's shared `parseDate` reads that form, along with the dash and slash spellings.
    static func purchaseDay(_ text: String, calendar: Calendar) -> Date? {
        guard !text.isEmpty else { return nil }
        return parseDate(from: text).map { calendar.startOfDay(for: $0) }
    }

    /// - Parameter showInfoComplete: Whether the "Not available on Blu-ray" row may be vended. It needs the Info Complete preference and a 99%
    ///   complete library. It is passed in, not read from `Preferences`, so this initializer can run off the main actor.
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

        /// Purchased releases with an audio-channel tag, which is the population `audioCounts` breaks down, and so the only correct denominator.
        /// See `audioChannelDenominator`.
        var audioTaggedReleaseCount = 0
        var audioTaggedReleaseCountAll = 0

        /// Films with at least one purchased top-level release. `missingReleaseArtworkCount` counts films, so this is its denominator, not `totalPurchasedReleases`,
        /// which counts releases.
        var filmsWithPurchasedReleasesCount = 0

        /// 4K statistics — accumulated in the main loop to avoid extra array passes.
        var fourKFilmCount = 0
        var nativeFourKFilmCount = 0
        var upscaledFourKFilmCount = 0
        var purchasedFourKFilmCount = 0
        var purchasedNativeFourKFilmCount = 0
        var purchasedUpscaledFourKFilmCount = 0
        
        var notAvailableOnBluRayCount = 0
        
        /// Process each film
        for film in films {
            /// Films on disc: a film with at least one PURCHASED release, not just any entered release. Wishlist and pre-order entries are not owned,
            /// and the format rows below are purchase-gated too. A film with several purchased releases still counts once.
            if film.releases.contains(where: { $0.purchased }) {
                onDiscCount += 1
            } else if !film.releases.isEmpty {
                /// Has a Release entered, none purchased. This is the population for "Unpurchased Films Available on Disc". It is exclusive
                /// of the branch above, since a film with a purchased release goes there.
                unpurchasedOnDiscCount += 1
            }
            
            /// Missing poster artwork
            if film.posterUID.isEmpty {
                missingArtworkCount += 1
                missingArtworkItems.append(DVNamedFilm(film))
            }

            /// Missing release artwork - check if any purchased release has missing artwork
            /// Artwork belongs to the whole release container, since a 4K parent and its bundled Blu-ray ship together. So only top-level releases count.
            let hasMissingReleaseArtwork = film.releases.contains { release in
                release.isTopLevel && release.purchased && release.hasArtwork.lowercased().contains("no")
            }
            if hasMissingReleaseArtwork {
                missingReleaseArtworkCount += 1
                missingReleaseArtworkItems.append(DVNamedFilm(film))
            }

            /// Lossy BD Audio - check if any release is 4K UHD or Blu-ray with lossy audio
            let hasLossyBDAudio = film.releases.contains { release in
                (release.format == ReleaseFormat.uhd4K.rawValue || release.format == ReleaseFormat.bluRay.rawValue) &&
                ReleaseAudioFormat.isLossyOnHDDisc(release.audioFormat)
            }
            if hasLossyBDAudio {
                lossyBDAudioCount += 1
                lossyBDAudioItems.append(DVNamedFilm(film))
            }
            
            /// Color films
            if film.color {
                colorCount += 1
            }
            
            /// Edited films
            if film.edited {
                editedCount += 1
            }
            
            /// Info complete
            if film.infoComplete {
                completeCount += 1
            } else {
                incompleteItems.append(DVNamedFilm(film))
            }
            
            /// Decade distribution
            if !film.releaseYear.isEmpty,
               let year = Int(film.releaseYear),
               year >= 1900 {
                let decade = (year / 10) * 10
                let decadeStr = "\(decade)s"
                decadeCounts[decadeStr, default: 0] += 1
                yearCounts[year, default: 0] += 1
            }
            
            /// Aspect ratio distribution
            if !film.aspectRatio.isEmpty {
                /// An open-matte tag ("1.78:1 (Open matte)") has the same numeric ratio as its bare form, so the qualifier is stripped before
                /// parsing. Otherwise `extractRatio` would fail and every open-matte film would fall into "Other".
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
            
            /// Collect audio channels and codecs. The "All" tallies cover every release. The purchased-only tallies below feed the "Purchased Only" tab.
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
            
            /// Source distribution
            if !film.digitalSource.isEmpty {
                sourceCounts[film.digitalSource, default: 0] += 1
            }
            
            /// Collect purchased top-level releases for the purchased-release total, average cost, and new/used tallies. A combo child mirrors its
            /// parent's purchase, cost, and condition, so counting it would double those figures.
            let purchasedCountBefore = purchasedReleases.count
            for release in film.releases where release.purchased && release.isTopLevel {
                purchasedReleases.append(release)
            }
            if purchasedReleases.count > purchasedCountBefore {
                filmsWithPurchasedReleasesCount += 1
            }
            
            /// Not available on Blu-ray - films without any Blu-ray or 4K UHD release
            let hasBluRayOrFourK = film.releases.contains { release in
                release.format == ReleaseFormat.bluRay.rawValue || release.format == ReleaseFormat.uhd4K.rawValue
            }
            if !hasBluRayOrFourK {
                notAvailableOnBluRayCount += 1
            }
            
            /// 4K and BD statistics, accumulated here to avoid extra passes after the loop.
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
        
        /// Calculate derived statistics
        self.filmsOnDisc = onDiscCount
        self.filmsOnDiscPercent = totalFilms > 0 ? Int((Double(onDiscCount) / Double(totalFilms) * 100).rounded()) : 0

        self.unpurchasedOnDisc = unpurchasedOnDiscCount

        /// "Digital Only" is every film with no Release object at all. Subtracting both on-disc counts keeps an unpurchased film with a Release
        /// record out of the digital-only figure.
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
        
        /// Films by decade
        self.filmsByDecade = decadeCounts.sorted { $0.key < $1.key }.map { (decade: $0.key, count: $0.value) }
        if let first = yearCounts.keys.min(), let last = yearCounts.keys.max() {
            self.filmsByYear = (first...last).map { (year: $0, count: yearCounts[$0] ?? 0) }
        } else {
            self.filmsByYear = []
        }
        
        /// Aspect ratio distribution
        let totalWithRatio = ratioCounts.values.reduce(0, +)
        /// Ties are broken on the class name, not left to `ratioCounts`'s own iteration order.
        /// Swift seeds Dictionary hashing per process, so without this tiebreak, classes with equal
        /// counts would sort differently on each launch. The PDF's Aspect Ratios tile and the on-screen
        /// chart would then reorder between exports of an unchanged library. Every other order in this
        /// export has an explicit total order for the same reason.
        self.aspectRatioDistribution = ratioCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map {
            let percent = totalWithRatio > 0 ? Double($0.value) / Double(totalWithRatio) * 100 : 0
            return (ratio: $0.key, count: $0.value, percent: percent)
        }
        
        /// Audio channel distribution with custom ordering - always show all options.
        /// Matches `audioChannelDistributionAll`'s row set exactly (differing only in
        /// counts): object-based mixes are a format flag, not a channel count, and are
        /// already broken out in `audioCodecs`, so they do not belong in this bar.
        var orderedAudioChannels: [(String, Int)] = []

        /// Add combined channels in order - always show all, even with 0 count
        /// The row LABELS are display copy, but the subscripts are STORED values — they key
        /// into counts tallied from release.audioChannels — so they come from the
        /// vocabulary rather than being respelled here.
        func channelCount(_ tags: String...) -> Int {
            tags.reduce(0) { $0 + (audioCounts[$1] ?? 0) }
        }
        orderedAudioChannels.append(("7.1 / 6.1 / 6.0",
            channelCount(ReleaseAudioChannels.surround71, ReleaseAudioChannels.surround61, ReleaseAudioChannels.surround60)))
        orderedAudioChannels.append(("5.1 / 5.0 / 4.0",
            channelCount(ReleaseAudioChannels.surround51, ReleaseAudioChannels.surround50,
                         ReleaseAudioChannels.surround40)))
        orderedAudioChannels.append(("3.0 / 2.0",
            channelCount(ReleaseAudioChannels.surround30, ReleaseAudioChannels.stereo20)))
        orderedAudioChannels.append(("2.0 Mono / 1.0",
            channelCount(ReleaseAudioChannels.mono20, ReleaseAudioChannels.mono10)))
        
        self.audioChannelDistribution = orderedAudioChannels

        /// The same four rows over every release, for the Audio card's "All" scope.
        func channelCountAll(_ tags: String...) -> Int {
            tags.reduce(0) { $0 + (audioCountsAll[$1] ?? 0) }
        }
        self.audioChannelDistributionAll = [
            ("7.1 / 6.1 / 6.0", channelCountAll(ReleaseAudioChannels.surround71, ReleaseAudioChannels.surround61, ReleaseAudioChannels.surround60)),
            ("5.1 / 5.0 / 4.0", channelCountAll(ReleaseAudioChannels.surround51, ReleaseAudioChannels.surround50,
                                                ReleaseAudioChannels.surround40)),
            ("3.0 / 2.0", channelCountAll(ReleaseAudioChannels.surround30, ReleaseAudioChannels.stereo20)),
            ("2.0 Mono / 1.0", channelCountAll(ReleaseAudioChannels.mono20, ReleaseAudioChannels.mono10)),
        ]
        self.audioChannelDenominatorAll = audioTaggedReleaseCountAll

        self.audioCodecs = ReleaseAudioFormat.hdOptions.map { DVTally($0, codecCounts[$0] ?? 0, of: codecCounts.values.reduce(0, +)) }
        self.audioCodecsAll = ReleaseAudioFormat.hdOptions.map { DVTally($0, codecCountsAll[$0] ?? 0, of: codecCountsAll.values.reduce(0, +)) }

        /// Source distribution, ordered by quality, descending. These are stored values used as dictionary keys, so the remastered
        /// forms are composed through FilmDigitalSource to match the FilmSheet byte for byte. The picker's list ascends.
        let remasteredDVD = FilmDigitalSource.compose(source: FilmDigitalSource.dvd,
                                                      remastered: true)
        let sourceOrder = [
            FilmDigitalSource.compose(source: FilmDigitalSource.blurayDisc, remastered: true),
            FilmDigitalSource.blurayDisc,
            remasteredDVD, /// Only shown if it has items
            FilmDigitalSource.dvd,
            FilmDigitalSource.download4K,
            FilmDigitalSource.download1080p,
            FilmDigitalSource.download720p,
            FilmDigitalSource.download540p,
            FilmDigitalSource.download480p,
            FilmDigitalSource.download360p
        ]

        var orderedSources: [(String, Int)] = []

        /// Add sources in order
        for source in sourceOrder {
            if source == remasteredDVD {
                /// Only add Remastered DVD if it has items
                if let count = sourceCounts[source], count > 0 {
                    orderedSources.append((source, count))
                }
            } else {
                let count = sourceCounts[source] ?? 0
                orderedSources.append((source, count))
            }
            
            /// Add divider after DVD
            if source == FilmDigitalSource.dvd {
                orderedSources.append(("---", 0))
            }
        }

        /// Any other value goes after the ladder. The field is an open vocabulary, and a film left out here would count as having no source.
        let listed = Set(sourceOrder)
        orderedSources += sourceCounts
            .filter { !listed.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        self.sourceDistribution = orderedSources
        
        self.notAvailableOnBluRay = showInfoComplete && infoCompletePercent > 99 ? notAvailableOnBluRayCount : nil

        /// Purchase statistics
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
        
        /// Average cost, in display and numeric form. The per-year "at or below average" column uses the numeric form.
        let costValues = purchasedReleases.compactMap { $0.cost > 0 ? $0.cost : nil }
        let numericAvgCost = costValues.isEmpty
            ? 0
            : costValues.reduce(0, +) / Double(costValues.count)
        self.averageCost = costValues.isEmpty ? "—" : Fmt.dollars(numericAvgCost)

        self.missingReleaseArtwork = missingReleaseArtworkCount
        self.missingReleaseArtworkItems = missingReleaseArtworkItems

        /// Lossy BD audio counts films. A film counts once if any 4K or Blu-ray release has a lossy track.
        /// The denominator is the films with a 4K or Blu-ray release, which is the complement of
        /// `notAvailableOnBluRayCount`. Counting releases here could push the share above 100%.
        let filmsWithBluRayOrFourK = totalFilms - notAvailableOnBluRayCount
        self.lossyBDAudio = lossyBDAudioCount
        self.lossyBDAudioItems = lossyBDAudioItems
        self.lossyBDAudioPercent = filmsWithBluRayOrFourK > 0 ?
            Int((Double(lossyBDAudioCount) / Double(filmsWithBluRayOrFourK) * 100).rounded()) : 0

        /// The population the audio-channel breakdown is a share of. See
        /// `audioTaggedReleaseCount`.
        self.audioChannelDenominator = audioTaggedReleaseCount
        
        /// Format breakdown: one pass over films, bucketed so the three rows are exclusive and sum to `onDiscCount`. Counting releases would
        /// double-count films with several purchased discs, and would count a combo pack's Blu-ray child again.
        ///
        /// The rows are asymmetric by design. "4K" counts every film with a purchased 4K release, even one that also has a Blu-ray or DVD, since
        /// a combo pack's Blu-ray is expected overlap. "Blu-ray only" skips films with a purchased 4K, but ignores DVD. "DVD only" requires no purchased
        /// 4K and no purchased Blu-ray. Each film lands in exactly one bucket.
        var fourKTally    = (count: 0, costTotal: 0.0, costCount: 0)
        var bluRayTally   = (count: 0, costTotal: 0.0, costCount: 0)
        var dvdTally      = (count: 0, costTotal: 0.0, costCount: 0)

        /// Adds one film to a bucket. The film counts once. Its cost sample comes from its purchased top-level releases in `format`, matching
        /// `purchasedReleases`. A combo child's cost is locked to its parent's, so children do not contribute.
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

        /// Builds one breakdown row. `total` is `onDiscCount` for the purchased breakdown, and `unpurchasedOnDiscCount` for the unpurchased one.
        /// Each is a film tally of its own population, so the three percentages sum to that population's share.
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

        /// Order follows `ReleaseFormat.displayRank` (4K, Blu-ray, DVD), the app's one format ladder.
        self.formatBreakdown = [
            breakdownRow(.uhd4K, label: "Purchased \(ReleaseFormat.uhd4K.rawValue)", total: onDiscCount, fourKTally),
            breakdownRow(.bluRay, label: "Purchased \(ReleaseFormat.bluRay.rawValue) only", total: onDiscCount, bluRayTally),
            breakdownRow(.dvd, label: "Purchased \(ReleaseFormat.dvd.rawValue) only", total: onDiscCount, dvdTally),
        ]

        // MARK: Unpurchased format breakdown
        ///
        /// The same exclusive bucketing as the purchased breakdown, over films with a Release entered and none purchased. Every release here is
        /// unpurchased, so "has a 4K release" stands in for "has a purchased 4K release". No cost is averaged, since an unpurchased release's cost
        /// is a wishlist figure, not a price paid. `avgCost` therefore always reads "—".
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

        /// 4K statistics. The counts are accumulated in the main loop above.
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
        
        /// Purchases by year, in one pass over the purchase dates.
        var yearDetailedData: [String: (newCount: Int, usedCount: Int, belowAvgCount: Int, totalCount: Int)] = [:]

        let calendar = AppCalendar.current
        for release in purchasedReleases where !release.purchaseDate.isEmpty {
            if let date = Self.purchaseDay(release.purchaseDate, calendar: calendar) {
                let year = calendar.component(.year, from: date)
                let yearStr = String(year)

                var yearData = yearDetailedData[yearStr] ?? (newCount: 0, usedCount: 0, belowAvgCount: 0, totalCount: 0)

                /// Count by condition
                if release.condition.lowercased() == "new" {
                    yearData.newCount += 1
                } else if release.condition.lowercased() == "used" {
                    yearData.usedCount += 1
                }

                /// Count if at or below the average cost, computed once above and shared with `averageCost`.
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
        
        /// Ratings statistics
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
        
        /// Films not yet rated
        let notRatedCount = totalFilms - filmsWithRatings
        self.notYetRatedFilms = notRatedCount
        self.notYetRatedFilmsItems = notYetRatedItems
        self.notYetRatedPercent = totalFilms > 0 ? Int((Double(notRatedCount) / Double(totalFilms) * 100).rounded()) : 0
        
        /// Average rating
        if filmsWithRatings > 0 {
            let average = Double(totalRatingsSum) / Double(filmsWithRatings)
            self.averageRating = Fmt.fixed(average, 2)
        } else {
            self.averageRating = "—"
        }
        
        /// Ratings breakdown (ratings 1-10 with counts and percentages)
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
