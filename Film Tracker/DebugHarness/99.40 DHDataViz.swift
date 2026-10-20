// MARK: - DHDataViz.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Harness scenarios for the redesigned Data Visualizations tab.
//
//   dataviz-insights — LibraryInsights and ViewingPeriodStatistics against a hand-built
//                      fixture with known answers (a fixed `today`, so rotation, year-to-
//                      date and purchase→viewing arithmetic are reproducible), then
//                      structural invariants over a large seeded corpus.
//   dataviz-render   — draws the canvas page off-screen at the minimum content width, a
//                      mid width and past the 1500pt cap, in both appearances, writes
//                      each as a PNG under the sandbox root, checks each fits its width
//                      and repeats exactly, and that print blocks match screen sections.
//   dataviz-tab      — mounts the real DataVisualizationsView against the coordinator:
//                      the synchronous first visit, a film-event burst driving one
//                      background recalculation that lands in the page and the cache, a
//                      remount seeded from the cache and reconciled in the background,
//                      and an unmount with a pass still in flight.
//   dataviz-pdf      — the Visualizations and Insights sheet of the library PDF: the two
//                      tables, then every print block of the page, drawn as vector
//                      content (no bitmap anywhere in the file) with every scope and
//                      role printed; writes dataviz-sheet.pdf under the sandbox root.
//   dataviz-perf     — measurements (not in `all`): the recalculation pipeline on a
//                      library-sized corpus.

#if DEBUG
import SwiftUI
import AppKit
import PDFKit

extension DebugHarness {

    static let dataVizScenarios = ["dataviz-insights", "dataviz-render", "dataviz-tab", "dataviz-pdf"]
    /// A measurement, not a verdict (like `sort-perf`): in `dataviz` and `full`, not `all`.
    static let dataVizPerfScenarios = ["dataviz-perf"]

    static func runDataVizScenario(_ scenario: String, coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "dataviz-insights": return await MainActor.run { dataVizInsightsScenario() }
        case "dataviz-render":   return await dataVizCanvasScenario(fidelityOnly: true)
        case "dataviz-tab":      return await dataVizTabScenario(coordinator: coordinator)
        case "dataviz-pdf":      return await dataVizPDFScenario()
        case "dataviz-perf":     return await dataVizPerfScenario()
        case "dataviz-canvas":   return await dataVizCanvasScenario(fidelityOnly: false)
        default: return nil
        }
    }

    // MARK: - Fixture

    /// A fixed "today" so every date-relative figure has one right answer.
    static let fixtureToday: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 21
        return Calendar.current.date(from: c)!
    }()

    private static func release(_ format: ReleaseFormat, purchased: Bool = true, cost: Double = 0,
                                spent: Double = 0, date: String = "", condition: String = ReleaseCondition.new,
                                lowest: Double = 0, hdr: String = "", master: String = "",
                                audio: String = ReleaseAudioFormat.dtsHDMA, channels: String = ReleaseAudioChannels.surround51,
                                video: String = ReleaseVideoFormat.avc, studio: String = "", origin: String = "",
                                region: String = "", availability: [String] = [], wishlist: Int = 0,
                                source: String = "", copies: Int = 1, discs: Int = 1, notes: String = "") -> ReleaseSnapshot {
        ReleaseSnapshot(studio: studio, purchased: purchased, wishlist: wishlist, format: format.rawValue,
                        videoFormat: video, audioFormat: audio, audioChannels: channels,
                        numberOfDiscs: discs, hasArtwork: "Yes", nationalOrigin: origin,
                        hasHDR: hdr, masterType: master, regionLock: region,
                        marketAvailability: availability, numberOfCopies: copies,
                        cost: cost, amountSpent: spent, purchaseDate: date,
                        lowestPrice: lowest, condition: condition, notes: notes)
    }

    private static func film(_ name: String, year: String = "1988", rating: Int = 8, minutes: Int = 110,
                             viewings: [String] = [], lastWatched: String? = nil, threshold: Int? = 12,
                             special: [String] = [], source: String = "", genre: String = "Action",
                             directors: [String] = [], tags: [String] = [], contentRating: String = "R",
                             hof: Int = 0, releases: [ReleaseSnapshot] = [], edited: Bool = false,
                             editedMinutes: Int? = nil, rf: Int = 0) -> FilmSnapshot {
        var snapshot = makeSnapshot(name: name, releaseYear: year, rating: rating,
                                    duration: String(minutes * 60_000),
                                    lastWatched: lastWatched ?? (viewings.last.map { String($0.prefix(10)) } ?? ""),
                                    calendarTable: viewings, releases: releases)
        snapshot.rotationThresholdOverride = threshold
        snapshot.specialSorting = special
        snapshot.digitalSource = source
        snapshot.genre = genre
        snapshot.directors = directors
        snapshot.tags = tags
        snapshot.rating = contentRating
        snapshot.hofPosition = hof
        snapshot.edited = edited
        snapshot.editedDuration = editedMinutes.map { String($0 * 60_000) } ?? ""
        snapshot.libraryHBRFValue = rf
        return snapshot
    }

    /// Every film here exists to pin one figure. Names say which.
    static func fixtureFilms() -> [FilmSnapshot] {
        [
            // Rotation: last watched 2025.01.15, 12-month threshold → due 2026-02-01, which
            // is more than six months before 2026-09-21. Two prior viewings a year apart.
            film("Overdue Six", viewings: ["2024.01.10", "2025.01.15"], directors: ["A. Director"],
                 releases: [release(.bluRay, cost: 20, date: "2024.02.01", lowest: 15, studio: "Criterion", origin: "United States", region: ReleaseRegionRules.regionA)]),
            // Due 2026-10-01: within 30 days.
            film("Due Thirty", viewings: ["2025.09.25"], source: FilmDigitalSource.download4K,
                 directors: ["A. Director"], tags: ["Halloween"],
                 releases: [release(.uhd4K, cost: 30, date: "2025.09.20", hdr: ReleaseHDR.dolbyVision, master: ReleaseMasterType.nativeFourK, video: ReleaseVideoFormat.hevc, studio: "Criterion", origin: "United States")]),
            // Due 2026-11-01: within 90 days but not 30.
            film("Due Ninety", viewings: ["2025.10.10.DC"], source: FilmDigitalSource.dvd, directors: ["B. Director"],
                 releases: [release(.bluRay, cost: 25, date: "2025.11.01", lowest: 25, studio: "Arrow Video", origin: "United Kingdom", region: ReleaseRegionRules.regionB)]),
            // Due 2027-07-01: on schedule. Rated 10; viewed twice in 2026 (first time in 2026).
            film("On Schedule", rating: 10, viewings: ["2026.03.03", "2026.06.01"], source: FilmDigitalSource.download1080p,
                 directors: ["B. Director"], hof: 1,
                 releases: [release(.dvd, cost: 8, date: "2026.02.15", condition: ReleaseCondition.used, studio: "Warner Bros.", origin: "United States", region: "Region 1"),
                            release(.uhd4K, purchased: false, cost: 35, availability: [ReleaseMarketAvailability.oopCheap], wishlist: 1)]),
            // Special sorting excludes it from rotation entirely, though it has a date.
            film("Held", viewings: ["2020.05.05"], special: [FilmSpecialSorting.temporarilyOnHold], genre: "Drama"),
            // Never viewed, no releases: digital only, unwatched backlog.
            film("Never Viewed", rating: 0, minutes: 90, genre: "Comedy", contentRating: "PG"),
            // Purchased 2026-03-01 and never watched since (last viewing 2025).
            film("Shelf Of Shame", viewings: ["2025.04.04"], genre: "Horror",
                 releases: [release(.bluRay, cost: 40, spent: 40, date: "2026.03.01", audio: ReleaseAudioFormat.dolbyDigital, studio: "Shout Factory", origin: "United States")],
                 edited: true, editedMinutes: 100, rf: 20),
            // Unpurchased and out of print.
            film("Unobtainable", rating: 0, viewings: [], genre: "Sci-Fi",
                 releases: [release(.bluRay, purchased: false, cost: 60, availability: [ReleaseMarketAvailability.oopExpensive], wishlist: 2)]),
        ]
    }

    // MARK: - Scenario: Insights

    @MainActor
    private static func dataVizInsightsScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-insights")
        let calendar = Calendar.current
        let films = fixtureFilms()
        let insights = LibraryInsights(films: films, today: fixtureToday, calendar: calendar)
        let stats = LibraryStatistics(films: films)

        // MARK: Needs Attention item lists (LibraryStatistics side)
        // Same equivalence property as the insights.*Items checks below: each Needs
        // Attention popover's item list must be exactly as large as the count on its card.
        r.check("not-yet-rated-items-match-count", stats.notYetRatedFilmsItems.count == stats.notYetRatedFilms,
                "\(stats.notYetRatedFilmsItems.count) items, expected \(stats.notYetRatedFilms)")
        r.check("missing-artwork-items-match-count", stats.missingArtworkItems.count == stats.missingArtwork,
                "\(stats.missingArtworkItems.count) items, expected \(stats.missingArtwork)")
        r.check("missing-release-artwork-items-match-count",
                stats.missingReleaseArtworkItems.count == stats.missingReleaseArtwork,
                "\(stats.missingReleaseArtworkItems.count) items, expected \(stats.missingReleaseArtwork)")
        r.check("lossy-bd-audio-items-match-count", stats.lossyBDAudioItems.count == stats.lossyBDAudio,
                "\(stats.lossyBDAudioItems.count) items, expected \(stats.lossyBDAudio)")

        // MARK: Overview
        r.check("total-viewings", insights.totalViewings == 8, "\(insights.totalViewings), expected 8")
        r.check("first-viewing-year", insights.firstViewingYear == 2020, "\(String(describing: insights.firstViewingYear))")
        r.check("watched-unwatched-partition", insights.watchedFilms + insights.unwatchedFilms == films.count,
                "\(insights.watchedFilms) + \(insights.unwatchedFilms) ≠ \(films.count)")
        r.check("unwatched-runtime", insights.unwatchedRuntimeMinutes == 90 + 110,
                "\(insights.unwatchedRuntimeMinutes), expected 200 (Never Viewed 90 + Unobtainable 110)")
        r.check("hof-count", insights.hallOfFameFilms == 1 && insights.hallOfFameAverageRating == "10.0",
                "\(insights.hallOfFameFilms) / \(insights.hallOfFameAverageRating)")
        r.check("edited-trimmed", insights.editedTrimmedMinutes == 10, "\(insights.editedTrimmedMinutes), expected 10")
        r.check("waiting-for-edit-items-match-count", insights.waitingForEditItems.count == insights.waitingForEdit,
                "\(insights.waitingForEditItems.count) items, expected \(insights.waitingForEdit)")

        // MARK: Rotation
        r.check("rotation-eligible-excludes-held-and-never",
                insights.rotationEligible == 5, "\(insights.rotationEligible), expected 5")
        r.check("rotation-overdue", insights.overdue == 2 && insights.overdueOverSixMonths == 1,
                "overdue \(insights.overdue) (expected 2: Overdue Six, Shelf Of Shame) · >6mo \(insights.overdueOverSixMonths) (expected 1)")
        // Needs Attention popovers show `insights.overdueItems` etc. for `insights.overdue`
        // etc.; these checks are the equivalence proof that each item list names exactly
        // the films its sibling count was drawn from — same size, same names, same order
        // as the fixture comments the count checks above already pin.
        r.check("rotation-overdue-items", Set(insights.overdueItems.map(\.name)) == ["Overdue Six", "Shelf Of Shame"],
                "\(insights.overdueItems.map(\.name))")
        r.check("rotation-due-30", insights.dueWithin30Days == 1, "\(insights.dueWithin30Days), expected 1 (Due Thirty)")
        r.check("rotation-due-90", insights.dueWithin90Days == 1, "\(insights.dueWithin90Days), expected 1 (Due Ninety)")
        r.check("rotation-on-schedule", insights.onSchedule == 1, "\(insights.onSchedule), expected 1 (On Schedule)")
        r.check("rotation-buckets-partition-eligible",
                insights.overdue + insights.dueWithin30Days + insights.dueWithin90Days + insights.onSchedule == insights.rotationEligible,
                "buckets do not sum to eligible")
        // Next calendar month (October 2026) only: Due Thirty (due 2026-10-01). Due Ninety
        // (2026-11-01) is two months out.
        r.check("rotation-coming-up-next-month",
                insights.comingUp.map(\.name) == ["Due Thirty"] && insights.comingUpNextMonthItems.map(\.name) == ["Due Thirty"],
                "\(insights.comingUp.map(\.name)) / \(insights.comingUpNextMonthItems.map(\.name))")
        let ranked = [DVUpcomingRotation(filmID: UUID(), name: "B", rating: 8, viewings: 2, purchasedReleases: 1),
                      DVUpcomingRotation(filmID: UUID(), name: "A", rating: 8, viewings: 2, purchasedReleases: 1),
                      DVUpcomingRotation(filmID: UUID(), name: "C", rating: 8, viewings: 2, purchasedReleases: 2),
                      DVUpcomingRotation(filmID: UUID(), name: "D", rating: 8, viewings: 5, purchasedReleases: 0),
                      DVUpcomingRotation(filmID: UUID(), name: "E", rating: 9, viewings: 0, purchasedReleases: 0)]
            .sorted(by: DVUpcomingRotation.ranksBefore).map(\.name)
        r.check("rotation-coming-up-ranking", ranked == ["E", "D", "C", "A", "B"], "\(ranked)")
        r.check("rotation-never-viewed", insights.neverViewed == 2, "\(insights.neverViewed), expected 2")
        // Two eligible films have two viewings: Overdue Six (371 days ≈ 12.2 months) and
        // On Schedule (90 days ≈ 3.0 months); the median of two values is their mean.
        r.check("rotation-median-gap",
                insights.medianGapMonths.map { abs($0 - 7.57) < 0.1 } ?? false,
                "\(String(describing: insights.medianGapMonths)), expected ≈ 7.57")
        r.check("rotation-last-gap-within", insights.lastGapWithinThresholdPercent == 50,
                "\(String(describing: insights.lastGapWithinThresholdPercent)), expected 50")

        // MARK: Attention
        r.check("unpurchased-oop", insights.unpurchasedOutOfPrint == 1, "\(insights.unpurchasedOutOfPrint), expected 1 (Unobtainable; On Schedule owns a DVD)")
        r.check("unpurchased-oop-items", insights.unpurchasedOutOfPrintItems.map(\.name) == ["Unobtainable"],
                "\(insights.unpurchasedOutOfPrintItems.map(\.name))")
        // Due Ninety's only viewing (2025.10.10) precedes its 2025-11-01 purchase, so it
        // counts alongside Shelf Of Shame.
        r.check("never-watched-since-purchase", insights.purchasedNeverWatchedSince == 2,
                "\(insights.purchasedNeverWatchedSince), expected 2 (Due Ninety, Shelf Of Shame)")
        r.check("never-watched-since-purchase-items",
                Set(insights.purchasedNeverWatchedSinceItems.map(\.name)) == ["Due Ninety", "Shelf Of Shame"],
                "\(insights.purchasedNeverWatchedSinceItems.map(\.name))")
        r.check("spent-never-watched", insights.spentNeverWatchedSincePurchase == 65,
                "\(insights.spentNeverWatchedSincePurchase), expected 65")
        // Value Realized names carry the film's release year (every fixture film is 1988).
        r.check("value-realized-years", insights.mostExpensiveUnwatchedSincePurchase?.year == 1988 && insights.bestValue?.year == 1988,
                "\(String(describing: insights.mostExpensiveUnwatchedSincePurchase)) / \(String(describing: insights.bestValue))")
        r.check("priciest-never-watched", insights.mostExpensiveUnwatchedSincePurchase?.name == "Shelf Of Shame",
                "\(String(describing: insights.mostExpensiveUnwatchedSincePurchase))")
        r.check("dvd-only-upgrade", insights.dvdOnlyFilms == 1 && insights.dvdOnlyWithUpgradeAvailable == 1,
                "\(insights.dvdOnlyWithUpgradeAvailable) of \(insights.dvdOnlyFilms)")
        r.check("digital-below-best-disc", insights.digitalBelowBestDisc == 1,
                "\(insights.digitalBelowBestDisc), expected 1 (Due Ninety: DVD rip of an owned Blu-ray)")
        r.check("digital-below-best-disc-items", insights.digitalBelowBestDiscItems.map(\.name) == ["Due Ninety"],
                "\(insights.digitalBelowBestDiscItems.map(\.name))")

        // MARK: Money
        r.check("total-spent", insights.totalSpent == 20 + 30 + 25 + 8 + 40, "\(insights.totalSpent), expected 123")
        r.check("spent-this-year", insights.spentThisYear == 8 + 40, "\(insights.spentThisYear), expected 48")
        r.check("spent-prior-span", insights.spentPriorYearSameSpan == 30,
                "\(insights.spentPriorYearSameSpan), expected 30 (Due Thirty on 2025-09-20; Due Ninety's 2025-11-01 is past the span)")
        r.check("median-cost", insights.medianCost == 25, "\(String(describing: insights.medianCost)), expected 25")
        r.check("paid-above-lowest", insights.paidAboveLowest.count == 1 && insights.paidAboveLowest.over == 5 && insights.boughtAtLowest == 1,
                "\(insights.paidAboveLowest) / at lowest \(insights.boughtAtLowest)")
        // <30 d: Due Thirty (5 days), On Schedule (16 days). 181–365: Overdue Six (349 days).
        // never: Due Ninety, Shelf Of Shame.
        r.check("purchase-to-viewing-buckets",
                insights.purchaseToFirstViewing.map(\.count) == [2, 0, 0, 1, 0, 2]
                    && insights.purchaseToFirstViewing.map(\.label) == ["<30 d", "30–90", "91–180", "181–365", "366+", "Never"],
                "\(insights.purchaseToFirstViewing.map { "\($0.label)=\($0.count)" }), expected [2, 0, 0, 1, 0, 2]")
        r.check("wishlist", insights.wishlistItems == 2 && insights.wishlistEstimatedCost == 95 && insights.wishlistOutOfPrintOrImport == 2,
                "\(insights.wishlistItems) / \(insights.wishlistEstimatedCost) / \(insights.wishlistOutOfPrintOrImport)")
        // A combo pack is one acquisition: its child mirrors the parent's wishlist slot,
        // price and purchase date (FSTabReleases.syncComboChild), and must not count again —
        // the Wishlist card must agree with the Release Wishlist report, which lists
        // top-level releases only, and Purchases by Month with Purchase Facts.
        func combo(purchased: Bool, wishlist: Int) -> [ReleaseSnapshot] {
            let parentID = UUID()
            let shared = (cost: 40.0, date: purchased ? "2025.05.10" : "")
            return [ReleaseSnapshot(id: parentID, purchased: purchased, wishlist: wishlist, format: ReleaseFormat.uhd4K.rawValue,
                                    cost: shared.cost, purchaseDate: shared.date),
                    ReleaseSnapshot(purchased: purchased, wishlist: wishlist, format: ReleaseFormat.bluRay.rawValue,
                                    cost: shared.cost, purchaseDate: shared.date, parentReleaseID: parentID)]
        }
        let comboInsights = LibraryInsights(films: [film("Wished Combo", releases: combo(purchased: false, wishlist: 1)),
                                                    film("Owned Combo", releases: combo(purchased: true, wishlist: 0))],
                                            today: fixtureToday, calendar: calendar)
        let ch = comboInsights.habits
        r.check("combo-counts-once",
                comboInsights.wishlistItems == 1 && comboInsights.wishlistEstimatedCost == 40
                    && comboInsights.wishlistByFormat == (1, 0, 0)
                    && ch.datedPurchases == 1 && ch.purchasesByMonth[4] == 1 && ch.averagePaidByMonth[4] == 40,
                "wishlist \(comboInsights.wishlistItems) / \(comboInsights.wishlistEstimatedCost) / \(comboInsights.wishlistByFormat); "
                + "dated \(ch.datedPurchases), May \(ch.purchasesByMonth[4])")
        // MARK: Collection Growth
        // Every fixture film was added 2020-01-01 (makeSnapshot's default); the five dated
        // purchases fall in 2024-02, 2025-09, 2025-11, 2026-02 and 2026-03. The span runs
        // from 2020-01 through 2026-09: 81 months.
        let g = insights.growth
        r.check("growth-span", g.firstMonth == 2020 * 12 && g.films.count == 81 && g.purchases.count == 81,
                "first \(g.firstMonth / 12)-\(g.firstMonth % 12 + 1), \(g.films.count) months")
        r.check("growth-films", g.films.allSatisfy { $0 == 8 }, "\(Set(g.films))")
        r.check("growth-purchases", [48, 49, 67, 68, 69, 70, 72, 73, 74, 80].map { g.purchases[$0] } == [0, 1, 1, 2, 2, 3, 3, 4, 5, 5],
                "\([48, 49, 67, 68, 69, 70, 72, 73, 74, 80].map { g.purchases[$0] })")
        r.check("growth-undated", g.undatedFilms == 0 && g.undatedPurchases == 0, "\(g.undatedFilms) / \(g.undatedPurchases)")
        r.check("growth-year-marks", g.yearMarks.map(\.year) == Array(2020...2026) && g.yearMarks.map(\.index) == [0, 12, 24, 36, 48, 60, 72],
                "\(g.yearMarks.map { "\($0.year)@\($0.index)" })")
        // Past 5 Years: 2021-09 through 2026-09, totals carried over from before the cut.
        let recent = g.lastYears(5)
        r.check("growth-past-5-years", recent.firstMonth == 2021 * 12 + 8 && recent.films.count == 61
                    && recent.purchases == Array(g.purchases.suffix(61)) && g.lastYears(10) == g,
                "first \(recent.firstMonth / 12)-\(recent.firstMonth % 12 + 1), \(recent.films.count) months")
        let clamped = DVGrowth(filmMonths: [10, 30], purchaseMonths: [12], currentMonth: 20, undatedFilms: 1, undatedPurchases: 2)
        r.check("growth-future-months-count-now", clamped.films == [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2] && clamped.purchases.last == 1,
                "\(clamped.films) / \(clamped.purchases)")
        // The Date Added fast path must name the month the full parser does, at every hour
        // of every day of two years (the month edges are where a UTC timestamp's own date
        // and the local one part).
        var addedDisagreements: [String] = []
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        for hour in stride(from: 0, to: 2 * 366 * 24, by: 1) {
            let date = start.addingTimeInterval(Double(hour) * 3600 + 1234.5)
            let text = StorageDateFormatters.timestamp.format(date)
            let parsed = parseDate(from: text).map { calendar.dateComponents([.year, .month], from: $0) }
            let expected = parsed.map { $0.year! * 12 + $0.month! - 1 }
            if LibraryInsights.addedMonth(text, calendar: calendar) != expected, addedDisagreements.count < 5 { addedDisagreements.append(text) }
        }
        for text in ["", "not a date", "2026.01.24", "2026-01-24", "2026-13-05T00:00:00.000Z", "2026-02-15"] {
            let expected = parseDate(from: text).map { d -> Int in let c = calendar.dateComponents([.year, .month], from: d); return c.year! * 12 + c.month! - 1 }
            if LibraryInsights.addedMonth(text, calendar: calendar) != expected { addedDisagreements.append(text.isEmpty ? "(empty)" : text) }
        }
        r.check("growth-added-month-matches-parser", addedDisagreements.isEmpty, addedDisagreements.isEmpty ? "\(2 * 366 * 24) hours + 6 spellings" : "\(addedDisagreements)")

        // MARK: Spending Trends
        // 2024: Overdue Six $20. 2025: Due Thirty $30 (Sep 20, by this date) + Due Ninety
        // $25 (Nov 1, after it). 2026: On Schedule $8 + Shelf Of Shame $40.
        let sy = insights.spendingYears
        r.check("spending-years", sy.map(\.year) == [2024, 2025, 2026] && sy.map(\.spent) == [20, 55, 48]
                    && sy.map(\.purchases) == [1, 2, 2], "\(sy.map { "\($0.year) \($0.purchases) \($0.spent)" })")
        r.check("spending-by-this-date", sy.map(\.spentByThisDate) == [20, 30, 48] && sy.map(\.purchasesByThisDate) == [1, 1, 2],
                "\(sy.map(\.spentByThisDate)) / \(sy.map(\.purchasesByThisDate))")
        r.check("spending-average-cost", sy.map(\.averageCost) == [20, 27.5, 24], "\(sy.map(\.averageCost))")
        r.check("spending-year-elapsed", abs(insights.yearElapsedFraction - 264.0 / 365) < 1e-9, "\(insights.yearElapsedFraction)")
        // On Schedule owns a DVD and has an unbought $35 4K entered (the fixture's release
        // snapshots are dated now); the three Blu-ray-only films have no 4K entered.
        r.check("owned-below-4k", insights.ownedBelowFourK == 4 && insights.ownedBelowFourKWithFourKEntered == 1
                    && insights.newFourKForOwnedBelowFourK == 1 && insights.newFourKForOwnedBelowFourKCost == 35,
                "\(insights.ownedBelowFourK) / \(insights.ownedBelowFourKWithFourKEntered) / \(insights.newFourKForOwnedBelowFourK) / \(insights.newFourKForOwnedBelowFourKCost)")
        // Projection: 2025 (weight 3) spent $25 after Sep 21 of $55, 2024 (weight 2) $0 of
        // $20 → rest $15; by this date (3·30 + 2·20) / 5 = $26, so pace 48 / 26; 48 + 15·48/26 ≈ $75.69.
        let projected = DVSpendingTrends.projectedYearEnd(sy[2], Array(sy.prefix(2)), yearElapsed: insights.yearElapsedFraction)
        r.check("spending-projection-history", abs((projected ?? 0) - (48 + 15 * 48.0 / 26)) < 1e-9, "\(String(describing: projected))")
        var lone = DVSpendingYear(year: 2026); lone.spentByThisDate = 30; lone.purchases = 1
        r.check("spending-projection-linear-without-history",
                DVSpendingTrends.projectedYearEnd(lone, [], yearElapsed: 0.5) == 60
                    && DVSpendingTrends.projectedYearEnd(lone, [], yearElapsed: 0.05) == nil, "")
        var slow = DVSpendingYear(year: 2025); slow.purchases = 1; slow.spent = 110; slow.spentByThisDate = 10
        r.check("spending-projection-pace-clamped", DVSpendingTrends.projectedYearEnd(lone, [slow], yearElapsed: 0.5) == 30 + 100 * 2,
                "\(String(describing: DVSpendingTrends.projectedYearEnd(lone, [slow], yearElapsed: 0.5))), expected 230 (pace 3× clamped to 2×)")
        // MARK: Collector habits (every fixture film is from 1988; rating 8 unless noted)
        // Viewings: 2020 Held; 2024 Overdue Six; 2025 Overdue Six again + Due Thirty, Due Ninety,
        // Shelf Of Shame firsts; 2026 On Schedule twice. Busiest year 4, so every year (≥ 1) is tracked;
        // 2021–2023 have none and still appear, at zero.
        let h = insights.habits
        r.check("habits-viewing-years",
                h.trackedFrom == 2020 && !h.hasSparseEarlierYears
                    && h.viewingYears.map { [$0.year, $0.firstTime, $0.rewatches] } == [[2020, 1, 0], [2021, 0, 0], [2022, 0, 0], [2023, 0, 0], [2024, 1, 0], [2025, 3, 1], [2026, 1, 1]],
                "\(h.viewingYears.map { "\($0.year) \($0.firstTime)/\($0.rewatches)" })")
        // Ages 32, 36, 37×4, 38×2: all in 31–50; median 37.
        r.check("habits-viewing-age", h.viewingAgeBuckets.map(\.count) == [0, 0, 0, 0, 0, 8, 0] && h.medianViewingAge == 37,
                "\(h.viewingAgeBuckets.map(\.count)) median \(String(describing: h.medianViewingAge))")
        // Purchases: Feb (Overdue Six $20, On Schedule $8), Mar ($40), Sep ($30), Nov ($25).
        r.check("habits-purchases-by-month", h.purchasesByMonth == [0, 2, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0] && h.datedPurchases == 5,
                "\(h.purchasesByMonth)")
        r.check("habits-busiest-month-sentence",
                h.busiestMonthSentence == "February accounts for 40% of dated purchases, averaging \(DVFormat.money(14)) a release against \(DVFormat.money(95.0 / 3)) the rest of the year.",
                h.busiestMonthSentence ?? "nil")
        // Rated 8 and owned: Overdue Six, Due Thirty (4K), Due Ninety, Shelf Of Shame → $28.75, 25% on 4K.
        // Rated 10: On Schedule, a $8 DVD, no 4K owned.
        r.check("habits-price-by-rating",
                h.averagePaidByRating[7] == 28.75 && h.fourKShareByRating[7] == 25 && h.averagePaidByRating[9] == 8
                    && h.fourKShareByRating[9] == 0 && h.averagePaidByRating[0] == nil && h.filmsByRating[7] == 4,
                "\(h.averagePaidByRating) / \(h.fourKShareByRating)")
        r.check("habits-rating-band", h.ratingBand(9...10).averagePaid == 8 && h.ratingBand(9...10).fourKPercent == 0
                    && h.ratingBand(1...5).averagePaid == nil, "")
        // On Schedule (10) has an unbought 4K and owns none.
        r.check("habits-4k-upgrades", h.fourKUpgrades.map { "\($0.film.name) \($0.rating)" } == ["On Schedule 10"],
                "\(h.fourKUpgrades.map { "\($0.film.name) \($0.rating)" })")
        // All eight films are from the 1980s; five own a purchased release.
        r.check("habits-ownership-by-decade", h.ownershipByDecade.map { "\($0.decade) \($0.films)/\($0.owned)" } == ["1980s 8/5"],
                "\(h.ownershipByDecade.map { "\($0.decade) \($0.films)/\($0.owned)" })")
        // DVFitRows: 20 rows 10 tall and a 20-tall View All, 4 apart. Its own height is 7 items,
        // 6 rows + the button (6·10 + 20 + 6·4 = 104); 200 holds 12 rows + the button (14·12 + 20 = 188);
        // 300 holds all 20 without it (20·10 + 19·4 = 276).
        let fit = DVFitRows(rows: (0..<20).map { _ in DVBox(height: 10) { _, _ in } }, more: DVBox(height: 20) { _, _ in })
        r.check("fit-rows-count", fit.height(200) == 104 && fit.fittingCount(CGRect(x: 0, y: 0, width: 200, height: 200)) == 12
                    && fit.fittingCount(CGRect(x: 0, y: 0, width: 200, height: 300)) == 20,
                "\(fit.height(200)) / \(fit.fittingCount(CGRect(x: 0, y: 0, width: 200, height: 200))) / \(fit.fittingCount(CGRect(x: 0, y: 0, width: 200, height: 300)))")
        // Decades ranked by average rating: the fixture's six rated films are all 1988 (50 / 6).
        let fixtureDecades = insights.decadesByRating
        r.check("decade-rating-fixture", fixtureDecades.count == 1 && fixtureDecades[0].label == "1980s"
                    && fixtureDecades[0].rated == 6 && abs(fixtureDecades[0].average - 50.0 / 6.0) < 1e-9,
                "\(fixtureDecades)")
        // 1950s 9,9,8 (8.67); 1970s 10,8,8 (8.67, ties go to the earlier decade); 1990s 6,6,6 (6.0);
        // 2000s 10,10 (too few); 2010s unrated films don't count; unknown-year film is ignored.
        let rankFilms = [film("a", year: "1951", rating: 9), film("b", year: "1959", rating: 9), film("c", year: "1955", rating: 8),
                         film("d", year: "1971", rating: 10), film("e", year: "1979", rating: 8), film("f", year: "1975", rating: 8),
                         film("g", year: "1990", rating: 6), film("h", year: "1991", rating: 6), film("i", year: "1999", rating: 6),
                         film("j", year: "2001", rating: 10), film("k", year: "2002", rating: 10),
                         film("l", year: "2011", rating: 0), film("m", year: "2012", rating: 0), film("n", year: "2013", rating: 0),
                         film("o", year: "", rating: 10)]
        let decadeRanked = LibraryInsights(films: rankFilms, today: fixtureToday, calendar: calendar)
        r.check("decade-rating-ranking", decadeRanked.decadesByRating.map(\.label) == ["1950s", "1970s", "1990s"]
                    && decadeRanked.decadesByRating.map(\.rated) == [3, 3, 3] && decadeRanked.bestRatedDecade?.label == "1950s",
                "\(decadeRanked.decadesByRating)")
        r.check("runtime-bucket-labels", insights.runtimeBuckets.map(\.label) == ["<1:30", "1:30–1:44", "1:45–1:59", "2:00–2:29", "2:30–2:59", "3:00+"],
                "\(insights.runtimeBuckets.map(\.label))")
        let trends = DVSpendingTrends.highlights(stats: stats, insights: insights)
        r.check("trends-count", trends.count == 4, "\(trends.map(\.kicker))")
        if trends.count == 4 {
            r.check("trends-this-year", trends[0].headline == "You've spent $48 on 2 releases so far in 2026, $18 more than by this date in 2025."
                        && trends[0].detail == "Your biggest start to a year yet. At this pace, 2026 is projected to end with a total spend around $76. Bars compare each year-to-date.",
                    "\(trends[0].headline) | \(trends[0].detail)")
            r.check("trends-average-price",
                    trends[1].headline == "Your average purchase price so far in 2026 is $24.00, down 13% from $27.50 in 2025.",
                    trends[1].headline)
            // 2025 ($55) beat the current 2026 ($48): a past year, so "was".
            r.check("trends-biggest-year-tense", trends[2].detail.contains("Your biggest spending year was 2025 with a total of $55."),
                    trends[2].detail)
            r.check("trends-long-term", trends[2].headline == "Across 3 years of dated purchases you've spent $123 on 5 releases.",
                    trends[2].headline)
            if case .line(let values, let first, let last) = trends[2].chart {
                r.check("trends-long-term-line", values == [20, 55] && first == "2024" && last == "2025", "\(values) \(first)–\(last)")
            } else {
                r.check("trends-long-term-line", false, "not a line")
            }
            r.check("trends-upgrades", trends[3].headline == "1 film you own on Blu-ray or DVD gained a 4K release in the last 90 days.",
                    trends[3].headline)
        }
        // A run: three rising years read as one.
        let rising = LibraryInsights(films: ["2023.03.03", "2024.03.03", "2025.03.03"].enumerated().map { i, date in
            film("Rising \(i)", releases: [release(.bluRay, cost: Double(10 + 5 * i), date: date)])
        }, today: fixtureToday, calendar: calendar)
        let risingTrends = DVSpendingTrends.highlights(stats: LibraryStatistics(films: []), insights: rising)
        r.check("trends-price-run", risingTrends.count > 1
                    && risingTrends[1].headline == "Your average purchase price has risen two years running: $10.00 → $15.00 → $20.00.",
                risingTrends.count > 1 ? risingTrends[1].headline : "\(risingTrends.count) highlights")

        r.check("hdr-sums-to-purchased-4k", insights.hdrOnPurchased4K.reduce(0) { $0 + $1.count } == 1
                && insights.hdrOnPurchased4K.first?.count == 1, "\(insights.hdrOnPurchased4K.map { "\($0.label)=\($0.count)" })")

        // MARK: Structure & metadata
        r.check("studios-shorthand", insights.studios.first?.label == "Criterion" && insights.studios.first?.count == 2,
                "\(insights.studios.map { "\($0.label)=\($0.count)" })")
        r.check("region-b-locked", insights.blurayRegionLocks.first { $0.label == "Region B" }?.count == 1,
                "\(insights.blurayRegionLocks.map { "\($0.label)=\($0.count)" })")

        // MARK: Digital sources
        // Every recorded source is on the Digital Sources card — the "4K download" tier
        // (Due Thirty) included — so its "no source recorded" subtitle is exact.
        let sourceRows = stats.sourceDistribution.filter { $0.0 != "---" }
        r.check("sources-include-4k-download", sourceRows.contains { $0.0 == FilmDigitalSource.download4K && $0.1 == 1 },
                "\(sourceRows)")
        r.check("sources-cover-every-recorded-source",
                sourceRows.reduce(0) { $0 + $1.1 } == films.filter { !$0.digitalSource.isEmpty }.count,
                "\(sourceRows.reduce(0) { $0 + $1.1 }) listed, \(films.filter { !$0.digitalSource.isEmpty }.count) recorded")
        // A remastered download is its tier, for the rip backlog, and still listed.
        let remasteredDownload = FilmDigitalSource.compose(source: FilmDigitalSource.download4K, remastered: true)
        let remasteredFilms = [film("Remastered Download", source: remasteredDownload, releases: [release(.uhd4K, cost: 30)])]
        let remasteredInsights = LibraryInsights(films: remasteredFilms, today: fixtureToday, calendar: calendar)
        r.check("remastered-download-keeps-its-tier", remasteredInsights.digitalBelowBestDisc == 0,
                "\(remasteredInsights.digitalBelowBestDisc), expected 0 (a 4K download of an owned 4K)")
        r.check("remastered-download-listed",
                LibraryStatistics(films: remasteredFilms).sourceDistribution.contains { $0.0 == remasteredDownload && $0.1 == 1 },
                "\(LibraryStatistics(films: remasteredFilms).sourceDistribution)")
        r.check("directors-ranked", insights.directors.map(\.name) == ["A. Director", "B. Director"]
                && insights.directors.first?.extras == ["8.0", "1.5"],
                "\(insights.directors.map { "\($0.name) \($0.value) \($0.extras)" })")
        r.check("genres-ranked", insights.genres.first?.name == "Action" && insights.genres.first?.value == "4",
                "\(insights.genres.map { "\($0.name)=\($0.value)" })")
        r.check("content-ratings-ordered", insights.contentRatings.map(\.label) == ["PG", "R"],
                "\(insights.contentRatings.map(\.label))")
        // The Audio card's codec bands replaced the old binary Lossless/Lossy split;
        // the same five purchased discs carrying an audio-format tag should land
        // somewhere across the eight bands, and "All" (every release, not just
        // purchased) can only be at least as large a population.
        r.check("audio-codecs-purchased-total", stats.audioCodecs.reduce(0) { $0 + $1.count } == 5,
                "\(stats.audioCodecs.map { "\($0.label)=\($0.count)" })")
        r.check("audio-codecs-all-covers-purchased",
                stats.audioCodecsAll.reduce(0) { $0 + $1.count } >= stats.audioCodecs.reduce(0) { $0 + $1.count },
                "\(stats.audioCodecsAll.reduce(0) { $0 + $1.count }) < \(stats.audioCodecs.reduce(0) { $0 + $1.count })")
        r.check("handbrake-rf", insights.handbrakeRF.map(\.count) == [0, 1, 0], "\(insights.handbrakeRF.map(\.count))")
        r.check("most-rewatched", insights.mostRewatchedAllTime.map(\.name) == ["On Schedule", "Overdue Six"],
                "\(insights.mostRewatchedAllTime.map(\.name))")
        r.check("seasonality-twelve", insights.seasonality.count == 12 && insights.viewingYears == [2020, 2024, 2025, 2026],
                "\(insights.viewingYears)")

        // MARK: Period (2026 year to date on 2026-09-21)
        let records = films.map { DVFilmViewings($0, calendar: calendar) }
        let p = ViewingPeriodStatistics(viewings: records, year: 2026, yearToDate: true, today: fixtureToday, calendar: calendar)
        r.check("period-viewings", p.viewings == 2 && p.distinctFilms == 1, "\(p.viewings) / \(p.distinctFilms)")
        r.check("period-first-time-vs-rewatch", p.firstTimeWatches == 1 && p.rewatches == 1, "\(p.firstTimeWatches) / \(p.rewatches)")
        r.check("period-prior-span", p.priorViewings == 2 && p.priorFirstTimeWatches == 1,
                "prior \(p.priorViewings) (expected 2: Overdue Six 2025.01.15, Shelf Of Shame 2025.04.04; Due Thirty 2025.09.25 is past Sep 21) / first-time \(p.priorFirstTimeWatches) (Shelf Of Shame)")
        r.check("period-months", p.byMonth.reduce(0, +) == p.viewings && p.byMonth[2] == 1 && p.byMonth[5] == 1,
                "\(p.byMonth)")
        r.check("period-current-month-flag", p.currentMonthIndex == 8, "\(String(describing: p.currentMonthIndex))")
        r.check("period-hours", p.hoursWatchedMinutes == 220, "\(p.hoursWatchedMinutes)")
        r.check("period-projection", (p.projectedYearEnd ?? 0) >= 2, "\(String(describing: p.projectedYearEnd))")
        r.check("period-most-rewatched", p.mostRewatched.map(\.name) == ["On Schedule"], "\(p.mostRewatched.map(\.name))")
        r.check("period-versions", p.versionsWatched.first?.label == "Theatrical" && p.versionsWatched.first?.count == 2,
                "\(p.versionsWatched.map { "\($0.label)=\($0.count)" })")
        r.check("period-span-label", p.spanLabel == "Jan 1 – Sep 21, 2026", p.spanLabel)
        let full2025 = ViewingPeriodStatistics(viewings: records, year: 2025, yearToDate: true, today: fixtureToday, calendar: calendar)
        r.check("period-past-year-is-full-year", full2025.viewings == 4 && full2025.spanLabel == "Jan 1 – Dec 31, 2025",
                "\(full2025.viewings) · \(full2025.spanLabel)")
        r.check("period-version-code", full2025.versionsWatched.contains { $0.label == ViewingVersion.directorsCut.displayName && $0.count == 1 },
                "\(full2025.versionsWatched.map { "\($0.label)=\($0.count)" })")
        r.check("period-timed-viewings", p.timedViewings == p.viewings, "\(p.timedViewings) of \(p.viewings)")
        // The span's average runtime divides by the viewings that HAVE a runtime: two of
        // a 110-minute film and one of a film with none average 110, not 73.
        let untimed = [film("Timed", viewings: ["2026.03.03", "2026.06.01"]),
                       film("Untimed", minutes: 0, viewings: ["2026.04.01"])].map { DVFilmViewings($0, calendar: calendar) }
        let untimedPeriod = ViewingPeriodStatistics(viewings: untimed, year: 2026, yearToDate: true, today: fixtureToday, calendar: calendar)
        r.check("period-average-runtime-over-timed-viewings",
                untimedPeriod.viewings == 3 && untimedPeriod.timedViewings == 2 && untimedPeriod.hoursWatchedMinutes == 220,
                "\(untimedPeriod.viewings) viewings, \(untimedPeriod.timedViewings) timed, \(untimedPeriod.hoursWatchedMinutes) min")

        // On Feb 29 the year-to-date comparison span of a common year ends Feb 28 — not
        // Mar 1, where `date(from:)` rolls an unclamped Feb 29 over to.
        var leapParts = DateComponents(); leapParts.year = 2028; leapParts.month = 2; leapParts.day = 29
        let leapDay = calendar.date(from: leapParts)!
        let leapRecords = [film("Leap", viewings: ["2027.02.28", "2027.03.01", "2028.02.29"])].map { DVFilmViewings($0, calendar: calendar) }
        let leap = ViewingPeriodStatistics(viewings: leapRecords, year: 2028, yearToDate: true, compareYear: 2027,
                                           today: leapDay, calendar: calendar)
        r.check("period-leap-day-comparison-span", leap.viewings == 1 && leap.priorViewings == 1,
                "\(leap.viewings) / prior \(leap.priorViewings), expected 1 / 1 (2027.03.01 is past the span)")

        // MARK: The tab's own entry parser ≡ the formatter chain
        // `DVFilmViewings.parse` reads canonical entries directly (skipping `startOfDay`),
        // so it is held to the formatter chain `parseDate` used to be — the app-wide
        // fast path has its own exhaustive proof in the `date-semantics` scenario.
        var parseAgreements = 0, parseDisagreements: [String] = []
        for year in stride(from: 1888, through: 2100, by: 3) {
            for month in 0...13 {
                for day in [0, 1, 15, 28, 29, 30, 31] {
                    let dot = "\(Fmt.padded(year, 4)).\(Fmt.padded(month, 2)).\(Fmt.padded(day, 2))"
                    let expected = parseDateWithFormatters(datePortion: dot, dateString: dot).map { calendar.startOfDay(for: $0) }
                    let fast = DVFilmViewings.parse(dot, calendar: calendar)?.0
                    if expected == fast { parseAgreements += 1 } else if parseDisagreements.count < 5 {
                        parseDisagreements.append("\(dot): formatters \(String(describing: expected)) fast \(String(describing: fast))")
                    }
                    // Purchase dates: the stored dot form and the legacy dash form alike.
                    let dash = "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(day, 2))"
                    for purchase in [dot, dash] {
                        let expectedPurchase = parseDateWithFormatters(datePortion: purchase, dateString: purchase)
                            .map { calendar.startOfDay(for: $0) }
                        let fastPurchase = LibraryStatistics.purchaseDay(purchase, calendar: calendar)
                        if expectedPurchase == fastPurchase { parseAgreements += 1 } else if parseDisagreements.count < 5 {
                            parseDisagreements.append("purchase \(purchase): formatters \(String(describing: expectedPurchase)) fast \(String(describing: fastPurchase))")
                        }
                    }
                }
            }
        }
        r.check("entry-parse-agrees-with-formatters", parseDisagreements.isEmpty,
                "\(parseAgreements) agreements; first disagreements: \(parseDisagreements)")
        // Version codes and malformed spellings: the entry parser must either agree with
        // the formatter chain or decline to it, never answer differently.
        let odd = ["2024.01.10.DC", "2024.01.10.th", "2024.01.10.", "2024.01.10..", "2024.1.10", "2024.01.1", "2024-01-10",
                   "2024.01.10.DCX", "2024/01/10", " 2024.01.10", "2024.01.10 ", "", "abcd.ef.gh", "2024.01.10.D", "9999.12.31",
                   "0999.01.01", "2024.02.29", "2023.02.29", "2024-02-30", "1888.01.01.TH", "2026-09-21T10:30:00Z",
                   // Thirteen bytes that are not a date plus a two-character code.
                   "2024.01.10.É", "2024.01.10..A", "2024.01.10.A.", "2024.01.10.-A", "2024.01.10.zz", "2024.01.10.T.",
                   "2024.01.1０.TH", "２024.01.10", "2024.01.10.dc", "2024.01.10.99"]
        var oddDisagreements: [String] = []
        for entry in odd {
            let portion = extractDatePortion(from: entry) ?? entry
            let expected = parseDateWithFormatters(datePortion: portion, dateString: entry)
                .map { (calendar.startOfDay(for: $0), extractVersionCode(from: entry)) }
            let fast = DVFilmViewings.parse(entry, calendar: calendar)
            if expected?.0 != fast?.0 || expected?.1 != fast?.1 {
                oddDisagreements.append("\(entry): formatters \(String(describing: expected)) fast \(String(describing: fast))")
            }
        }
        r.check("entry-parse-agrees-on-odd-spellings", oddDisagreements.isEmpty, "\(oddDisagreements)")

        // MARK: Record reuse across recalculations
        let reusedFrom = DVFilmViewings(films[0], calendar: calendar)
        var renamed = films[0]; renamed.name = "Renamed"; renamed.userRating = 3
        let reused = DVFilmViewings(renamed, calendar: calendar, reusing: reusedFrom)
        r.check("reuse-keeps-parsed-dates-refreshes-fields",
                reused.dates == reusedFrom.dates && reused.versions == reusedFrom.versions && reused.name == "Renamed" && reused.rating == 3, "")
        var extended = films[0]; extended.calendarTable.append("2026.09.20")
        let reparsed = DVFilmViewings(extended, calendar: calendar, reusing: reusedFrom)
        r.check("reuse-reparses-when-history-changes", reparsed.dates.count == reusedFrom.dates.count + 1, "\(reparsed.dates.count)")
        let other = DVFilmViewings(films[1], calendar: calendar, reusing: reusedFrom)
        r.check("reuse-ignores-another-film", other.dates == DVFilmViewings(films[1], calendar: calendar).dates, "")
        // A dataset built from a previous dataset's records must equal one built cold.
        let cold = DVDataset(films: films, previousRecords: [], showInfoComplete: true, today: fixtureToday, calendar: calendar)
        let warm = DVDataset(films: films, previousRecords: cold.viewingRecords, showInfoComplete: true, today: fixtureToday, calendar: calendar)
        r.check("dataset-warm-equals-cold",
                warm.viewingRecords.map(\.dates) == cold.viewingRecords.map(\.dates)
                    && warm.insights.totalViewings == cold.insights.totalViewings
                    && warm.insights.mostRewatchedAllTime == cold.insights.mostRewatchedAllTime
                    && warm.stats.totalPurchasedReleases == cold.stats.totalPurchasedReleases, "")

        // MARK: Invariants over a large corpus
        let corpus = standardCorpus(count: 600, seed: 0xDA7A)
        let big = LibraryInsights(films: corpus, today: fixtureToday, calendar: calendar)
        let bigStats = LibraryStatistics(films: corpus)
        r.check("corpus-ownership-partition",
                bigStats.filmsOnDisc + bigStats.unpurchasedOnDisc + bigStats.digitalOnlyFilms == corpus.count, "")
        r.check("corpus-rotation-partition",
                big.overdue + big.dueWithin30Days + big.dueWithin90Days + big.onSchedule == big.rotationEligible,
                "\(big.overdue)+\(big.dueWithin30Days)+\(big.dueWithin90Days)+\(big.onSchedule) ≠ \(big.rotationEligible)")
        r.check("corpus-rotation-plus-never-plus-held",
                big.rotationEligible + big.neverViewed <= corpus.count, "")
        r.check("corpus-p2v-partition",
                big.purchaseToFirstViewing.reduce(0) { $0 + $1.count }
                    == corpus.flatMap(\.releases).filter { $0.purchased && $0.isTopLevel && !$0.purchaseDate.isEmpty }.count, "")
        r.check("corpus-runtime-partition",
                big.runtimeBuckets.reduce(0) { $0 + $1.count } == corpus.filter { DurationHelpers.storedMinutes($0.duration) != nil }.count, "")
        r.check("corpus-tally-percent-bounds",
                (big.runtimeBuckets + big.hdrOnPurchased4K + big.blurayRegionLocks + big.videoCodecs).allSatisfy { ($0.percent ?? 0) <= 100 }, "")
        let bigPeriod = ViewingPeriodStatistics(viewings: corpus.map { DVFilmViewings($0, calendar: calendar) },
                                                year: 1991, yearToDate: false, today: fixtureToday, calendar: calendar)
        r.check("corpus-period-partition",
                bigPeriod.firstTimeWatches + bigPeriod.rewatches == bigPeriod.viewings
                    && bigPeriod.byMonth.reduce(0, +) == bigPeriod.viewings
                    && bigPeriod.priorByMonth.reduce(0, +) == bigPeriod.priorViewings, "")
        let bandSums = (0..<3).allSatisfy { mode in
            let bands = DVCanvasSections.monthBands(bigPeriod, mode: mode, compare: true)
            return bands.current.map { $0.reduce(0, +) } == bigPeriod.byMonth
                && bands.prior.map { $0.reduce(0, +) } == bigPeriod.priorByMonth
                && bands.current.allSatisfy { $0.count == bands.keys.count } && bands.paints.count == bands.keys.count
        }
        r.check("corpus-month-bands-partition", bandSums, "chroma, release decade and genre bands each sum to the month")
        let bh = big.habits
        r.check("corpus-habits-partition",
                bh.viewingYears.reduce(0) { $0 + $1.total } <= big.totalViewings
                    && bh.viewingYears.count <= DVHabits.maxViewingYears
                    && zip(bh.viewingYears, bh.viewingYears.dropFirst()).allSatisfy { $1.year == $0.year + 1 }
                    && bh.viewingAgeBuckets.reduce(0) { $0 + $1.count } <= big.totalViewings
                    && bh.ownershipByDecade.allSatisfy { $0.owned <= $0.films }
                    && bh.fourKUpgrades.allSatisfy { $0.rating >= DVHabits.upgradeMinimumRating }
                    && bh.purchasesByMonth.reduce(0, +) == bh.datedPurchases, "")
        r.check("corpus-no-trap", big.seasonality.count == 12 && bigStats.totalFilms == 600, "")
        return r
    }

    // MARK: - Scenario: PDF

    private static func dataVizPDFScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-pdf")
        let films = fixtureFilms() + standardCorpus(count: 160, seed: 0xB00C)
        let dataset = DVDataset(films: films, previousRecords: [], showInfoComplete: true, today: fixtureToday)
        let data = ReportsExportData(category: .dataVisualizations, hallOfFameFilms: nil,
                                     visualizations: dataset)
        guard let root = DebugSandbox.rootURL else {
            r.check("sandbox-root", false, "no sandbox root")
            return r
        }
        guard case let .stack(stack)? = ReportsPDFExporter.sheet(for: data) else {
            r.check("sheet-is-stack", false, "the sheet is missing or not a stack")
            return r
        }
        // Overview 4 (one row per growth scope), Viewing 5 (Release Decade and Genre month charts, then the
        // all-time habits row), Rotation 1, Purchases 7 (likewise per year-chart scope, then the habits row),
        // Collection 2, Decades 3 (the release-year chart first), People 2, Technical 2.
        r.check("block-count", stack.blocks.count == 26, "\(stack.blocks.count) blocks")
        r.check("blocks-laid-out-at-print-width",
                stack.blocks.allSatisfy { abs($0.size.width - DVPrintLayout.width) < 0.5 && $0.size.height > 40 },
                "sizes \(stack.blocks.map { "\(Int($0.size.width))×\(Int($0.size.height))" })")

        let url = root.appendingPathComponent("dataviz-sheet.pdf")
        let geometry = LibraryTableLayout.standard.geometry
        var mediaBox = CGRect(origin: .zero, size: geometry.pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            r.check("pdf-context", false, "could not open \(url.path)")
            return r
        }
        let builder = PDFDocumentBuilder(context: context, producedAt: fixtureToday)
        builder.add(.stack(stack), geometry: geometry)
        let pages = (try? await builder.finish()) ?? 0
        log("dataviz sheet written to \(url.path)")
        r.metric("pages", Double(pages), "pages")

        guard let document = PDFDocument(url: url) else {
            r.check("pdf-readable", false, "the written file does not open")
            return r
        }
        r.check("page-count", document.pageCount == pages && pages >= 3, "\(document.pageCount) pages, builder said \(pages)")

        // Text, not pixels: the cards' own words are selectable in the file, including
        // the captions printed in place of the controls.
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let expected = ["Library Overview", "Past 5 Years", "Needs Attention",
                        "Collection Growth", "Spending Trends",
                        "Viewing History", "Rotation", "Purchases and Spending", "Collection Structure",
                        "Release Decades, Runtime, and Picture", "People and Genres", "Audio, Sources, and Technical",
                        "Ownership", "Most Rewatched", "This Year", "All Time", "Purchased Only",
                        "Directors", "Cast", "Composers", "Screenwriters", "Subtitles and Encoding",
                        "Studios and Labels", "Regions", "4K UHD and HDR"]
        let missing = expected.filter { !text.localizedCaseInsensitiveContains($0) }
        r.check("text-present", missing.isEmpty, missing.isEmpty ? "all \(expected.count) present" : "missing \(missing)")
        let retired = ["Purchase statistics", "Library overview", "Ratings breakdown", "Purchase overview", "Miscellaneous", "Films by release decade"]
            .filter { text.contains($0) }
        r.check("old-tiles-retired", retired.isEmpty, retired.isEmpty ? "none printed" : "still printed: \(retired)")

        // Vector throughout: no image XObject on any page, at any depth, beyond the brand
        // mark every page carries — symbols included, which drawn as images would embed
        // one each (see DVSymbol's vector path).
        var extraImages: [Int] = []
        if let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0 {
            for index in 1...cg.numberOfPages {
                let images = cg.page(at: index)?.dictionary.map { imageCount(inResourcesOf: $0, depth: 0) } ?? 0
                if images > 1 { extraImages.append(index) }
            }
        }
        r.check("no-bitmaps", extraImages.isEmpty,
                extraImages.isEmpty ? "only the brand mark on each page" : "bitmaps beyond the brand mark on pages \(extraImages)")
        r.metric("file-size", Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_000_000, "MB")
        return r
    }

    /// Image XObjects in a page's (or form's) resources, recursing into forms.
    private static func imageCount(inResourcesOf dictionary: CGPDFDictionaryRef, depth: Int) -> Int {
        guard depth < 8 else { return 0 }
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard unsafe CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              unsafe CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return 0 }
        final class Tally { var count = 0; var forms: [CGPDFDictionaryRef] = [] }
        let tally = Tally()
        unsafe CGPDFDictionaryApplyBlock(xObjects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard unsafe CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<Int8>?
            let tally = unsafe Unmanaged<Tally>.fromOpaque(info!).takeUnretainedValue()
            if unsafe CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype = unsafe subtype {
                switch unsafe String(cString: subtype) {
                case "Image": tally.count += 1
                case "Form": tally.forms.append(streamDictionary)
                default: break
                }
            }
            return true
        }, unsafe Unmanaged.passUnretained(tally).toOpaque())
        return tally.count + tally.forms.reduce(0) { $0 + imageCount(inResourcesOf: $1, depth: depth + 1) }
    }

    // MARK: - Scenario: Tab

    private struct TabHost: View {
        let coordinator: DataCoordinator
        let appState: AppState
        var body: some View {
            DataVisualizationsView()
                .environment(coordinator)
                .environment(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The tab as the app mounts it, through every path its recalculation can take.
    @MainActor
    private static func dataVizTabScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-tab")
        var generator = SeededGenerator(seed: 0x7AB)
        func moreFilms(_ n: Int, _ tag: String) -> [FilmSnapshot] {
            (0..<n).map { i in
                film("\(tag) \(i)", viewings: ["2026.0\(1 + Int.random(in: 0...8, using: &generator)).1\(i % 9)"],
                     releases: [release(.bluRay, cost: 20, date: "2026-01-0\(1 + i % 9)")])
            }
        }
        coordinator.importFilms(fixtureFilms() + standardCorpus(count: 160, seed: 0x7AB1))
        let seeded = coordinator.totalFilmCount
        r.check("tab-seeded", seeded >= 168, "\(seeded) films")

        // MARK: A pass whose inputs match the dataset on screen computes nothing; a
        // change to any one input (a film, the Info Complete setting, the default
        // rotation threshold) computes again.
        do {
            let films = coordinator.getAllFilms()
            let current = DVDataset(films: films, previousRecords: [], showInfoComplete: true)
            let same = await DVDataset.compute(films: films, previous: current, showInfoComplete: true)
            let otherSetting = await DVDataset.compute(films: films, previous: current, showInfoComplete: false)
            var edited = films
            edited[0].userRating = edited[0].userRating % 10 + 1
            let otherFilm = await DVDataset.compute(films: edited, previous: current, showInfoComplete: true)
            let savedThreshold = Preferences.defaultRotationThreshold
            Preferences.defaultRotationThreshold = savedThreshold == 12 ? 24 : 12
            let otherThreshold = await DVDataset.compute(films: films, previous: current, showInfoComplete: true)
            Preferences.defaultRotationThreshold = savedThreshold
            let noPrevious = await DVDataset.compute(films: films, previous: nil, showInfoComplete: true)
            r.check("tab-unchanged-inputs-skip", same == nil, "")
            r.check("tab-changed-setting-recomputes", otherSetting?.stats.totalFilms == films.count, "")
            r.check("tab-changed-film-recomputes", otherFilm?.stats.totalFilms == films.count, "")
            r.check("tab-changed-threshold-recomputes", otherThreshold?.stats.totalFilms == films.count, "")
            r.check("tab-first-pass-computes", noPrevious?.stats.totalFilms == films.count, "")
        }

        let appState = AppState(modelContainer: coordinator.modelContainer, dataCoordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1148, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews { if let sv = findScrollView(sub) { return sv } }
            return nil
        }
        func documentHeight(_ host: NSView) -> CGFloat {
            findScrollView(host).flatMap { $0.documentView?.frame.height } ?? 0
        }
        func mount() async -> NSHostingView<TabHost> {
            let host = NSHostingView(rootView: TabHost(coordinator: coordinator, appState: appState))
            host.frame = NSRect(x: 0, y: 0, width: 1148, height: 700)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Wait for the page to stop growing rather than a fixed number of turns.
            var height = documentHeight(host), steady = 0
            for _ in 0..<80 where steady < 6 {
                await oneTurn(); host.layoutSubtreeIfNeeded()
                let now = documentHeight(host)
                steady = now == height ? steady + 1 : 0
                height = now
            }
            return host
        }
        /// Waits until the mount cache reports `count` films, or gives up after ~3 s.
        func waitForCache(_ count: Int) async -> Bool {
            for _ in 0..<300 {
                if ReportsState.shared.cachedVisualizations?.stats.totalFilms == count { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        // MARK: First visit: synchronous, so the page is there on the first layout.
        let wasCached = ReportsState.shared.cachedVisualizations != nil
        // Implicitly unwrapped so it can be released: a hosting view taken out of the window
        // but still referenced keeps its tab alive, subscribed to film events and applying
        // passes, which the app's own view switch never does.
        var host: NSHostingView<TabHost>! = await mount()
        r.check("tab-first-visit-renders", documentHeight(host) > 2000, "document height \(documentHeight(host))")
        r.check("tab-first-visit-populates-cache",
                await waitForCache(seeded), "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms)) (was cached before mount: \(wasCached))")

        // MARK: The page's AppKit-backed controls write through to the tab's state: the
        // Compare checkbox turns the comparison off (so its year pop-up disables) and on
        // again, and a scope control's new segment survives the update its write causes.
        do {
            func controls<T: NSControl>(_ type: T.Type) -> [T] {
                var found: [T] = [], stack: [NSView] = [host]
                while let view = stack.popLast() {
                    if let control = view as? T { found.append(control) }
                    stack.append(contentsOf: view.subviews)
                }
                return found
            }
            let checkbox = controls(NSButton.self).first { $0.title == "Compare with" }
            let yearPopUp = controls(NSPopUpButton.self).first { $0.itemTitles.allSatisfy { Int($0) != nil } }
            r.check("tab-controls-found", checkbox != nil && yearPopUp != nil,
                    "checkbox \(checkbox != nil), year pop-up \(yearPopUp != nil)")
            if let checkbox, let yearPopUp {
                let enabledBefore = yearPopUp.isEnabled
                checkbox.performClick(nil)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                let afterOff = (checkbox.state, yearPopUp.isEnabled)
                checkbox.performClick(nil)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                r.check("tab-compare-checkbox-round-trip",
                        enabledBefore && afterOff == (.off, false) && checkbox.state == .on && yearPopUp.isEnabled,
                        "before enabled \(enabledBefore); off → state \(afterOff.0.rawValue), pop-up \(afterOff.1); on → state \(checkbox.state.rawValue), pop-up \(yearPopUp.isEnabled)")
            }
            if let scope = controls(NSSegmentedControl.self).first(where: { $0.label(forSegment: 1) == "Purchased Only" }) {
                scope.selectedSegment = 1
                _ = scope.sendAction(scope.action, to: scope.target)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                let held = scope.selectedSegment
                scope.selectedSegment = 0
                _ = scope.sendAction(scope.action, to: scope.target)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                r.check("tab-scope-segment-round-trip", held == 1 && scope.selectedSegment == 0,
                        "after choosing Purchased Only \(held), after All \(scope.selectedSegment)")
            } else {
                r.check("tab-scope-segment-round-trip", false, "no scope control found")
            }
        }

        // MARK: An update that changes nothing the page shows rebuilds nothing: the
        // representable is handed the same revision (see DVCanvasModel.revision).
        do {
            DVCanvasPageView.rebuilds = 0
            host.rootView = TabHost(coordinator: coordinator, appState: appState)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); await oneTurn() }
            r.check("tab-unrelated-update-rebuilds-nothing", DVCanvasPageView.rebuilds == 0,
                    "\(DVCanvasPageView.rebuilds) rebuilds")
        }

        // MARK: A Needs Attention card opens its popover.
        if let page = findScrollView(host)?.documentView as? DVCanvasPageView {
            // A popover shows only from a window that is ordered in: far off every screen,
            // never key, so no focus is taken.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
            await oneTurn()
            r.check("tab-attention-popover-opens", page.debugOpenFirstAttentionPopover(), "")
            window.orderOut(nil)
        } else {
            r.check("tab-attention-popover-opens", false, "no canvas page")
        }

        // MARK: A burst of film events → one background pass → page and cache updated.
        DVCanvasPageView.rebuilds = 0
        let heightBefore = documentHeight(host)
        coordinator.importFilms(moreFilms(5, "Burst"))
        let landed = await waitForCache(seeded + 5)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); await oneTurn() }
        r.check("tab-event-burst-recalculates-in-background", landed,
                "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms)), wanted \(seeded + 5)")
        // The five films' new counts, tags and Coming Up candidate touch several sections;
        // SwiftUI re-evaluates only the ones whose inputs it cannot prove unchanged. A page
        // height delta used to be checked here too, but several cards were since given a
        // fixed or capped height specifically so their size no longer drifts with content
        // (the Most Rewatched card, the two-line stat-tile footnotes) — a burst that only
        // adds rows within those now-stable bounds can legitimately leave document height
        // unchanged even though the page content plainly did change, which
        // `tab-cached-count-matches-library` below verifies directly.
        r.check("tab-event-burst-rerenders-page", DVCanvasPageView.rebuilds >= 1,
                "\(DVCanvasPageView.rebuilds) page rebuilds after the pass; height \(heightBefore) → \(documentHeight(host))")
        r.check("tab-event-burst-page-intact", documentHeight(host) > 2000, "document height \(documentHeight(host))")
        r.check("tab-cached-count-matches-library",
                ReportsState.shared.cachedVisualizations?.insights.totalViewings ==
                    LibraryInsights(films: coordinator.getAllFilms()).totalViewings, "")

        // MARK: Remount: seeded from the cache at once, reconciled in the background.
        window.contentView = nil
        host = nil
        await oneTurn()
        coordinator.importFilms(moreFilms(1, "WhileAway"))
        // The view is gone, so the event it just missed leaves the cache one film behind.
        r.check("tab-unmounted-view-ignores-events", ReportsState.shared.cachedVisualizations?.stats.totalFilms == seeded + 5,
                "\(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms))")
        DVCanvasPageView.rebuilds = 0
        DataVisualizationsView.applications = 0
        host = await mount()
        r.check("tab-remount-seeds-from-cache", documentHeight(host) > 2000 && DVCanvasPageView.rebuilds >= 1,
                "document height \(documentHeight(host)), \(DVCanvasPageView.rebuilds) rebuilds")
        r.check("tab-remount-reconciles-in-background", await waitForCache(seeded + 6),
                "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms)), wanted \(seeded + 6)")
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); await oneTurn() }
        r.check("tab-remount-page-intact", documentHeight(host) > 2000, "document height \(documentHeight(host))")
        // The cache seed, then the reconcile's result: the library moved while away.
        r.check("tab-changed-remount-applies-twice", DataVisualizationsView.applications == 2,
                "\(DataVisualizationsView.applications) applications")

        // MARK: Unmount with a pass in flight: the cache still lands; nothing else does.
        coordinator.importFilms(moreFilms(1, "InFlight"))
        await oneTurn()   // the coalescing hop: the pass is now running
        window.contentView = nil
        r.check("tab-inflight-result-refreshes-cache", await waitForCache(seeded + 7),
                "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms)), wanted \(seeded + 7)")
        for _ in 0..<10 { await oneTurn() }
        r.check("tab-inflight-no-trap", true, "")

        // MARK: Remount with nothing changed since the cache was filled: the cache is
        // applied, the reconcile finds equal inputs, and nothing is applied after it.
        host = nil
        await oneTurn()
        DataVisualizationsView.applications = 0
        host = await mount()
        try? await Task.sleep(for: .milliseconds(1500))
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); await oneTurn() }
        r.check("tab-unchanged-remount-applies-once", DataVisualizationsView.applications == 1,
                "\(DataVisualizationsView.applications) applications")
        r.check("tab-unchanged-remount-page-intact", documentHeight(host) > 2000, "document height \(documentHeight(host))")
        window.contentView = nil
        await oneTurn()

        // MARK: The launch prefetch fills an empty cache off the main thread, and never
        // replaces one a visit has already filled.
        do {
            ReportsState.shared.debugResetVisualizations()
            ReportsState.shared.prefetchVisualizations(films: coordinator.getAllFilms())
            r.check("tab-prefetch-fills-cache", await waitForCache(seeded + 7),
                    "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms)), wanted \(seeded + 7)")
            ReportsState.shared.prefetchVisualizations(films: Array(coordinator.getAllFilms().dropLast()))
            try? await Task.sleep(for: .milliseconds(500))
            r.check("tab-prefetch-leaves-filled-cache", ReportsState.shared.cachedVisualizations?.stats.totalFilms == seeded + 7,
                    "cache holds \(String(describing: ReportsState.shared.cachedVisualizations?.stats.totalFilms))")
        }

        // MARK: A width change keeps the section at the top of the viewport where it was
        // on screen, whatever the sections above it did (every step of a drag does this).
        do {
            DataVisualizationsView.applications = 0
            host = await mount()
            if let scrollView = findScrollView(host), let page = scrollView.documentView as? DVCanvasPageView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2600))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                let before = page.sectionTops(width: page.bounds.width)
                let viewTop = scrollView.contentView.bounds.minY
                let anchor = before.indices.last { before[$0] <= viewTop } ?? 0
                let onScreenBefore = before[anchor] - viewTop
                window.setContentSize(NSSize(width: 860, height: 700))
                host.frame.size.width = 860
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await oneTurn() }
                let after = page.sectionTops(width: page.bounds.width)
                let onScreenAfter = after[anchor] - scrollView.contentView.bounds.minY
                r.check("tab-resize-keeps-viewport-section", abs(onScreenAfter - onScreenBefore) < 0.5 && after[anchor] != before[anchor],
                        "section \(anchor): \(onScreenBefore) pt from the viewport top before, \(onScreenAfter) after; page top \(before[anchor]) → \(after[anchor])")
            } else {
                r.check("tab-resize-keeps-viewport-section", false, "no canvas page")
            }
            window.contentView = nil
            host = nil
            await oneTurn()
        }
        return r
    }

    // MARK: - Scenario: Perf

    /// A library-sized corpus (about 1,400 films, 1.6 releases each, most purchased and
    /// dated, a few viewings apiece — the shape of the real library on 2026-09-21).
    static func librarySizedCorpus() -> [FilmSnapshot] {
        var generator = SeededGenerator(seed: 0x5EED)
        return standardCorpus(count: 1400, seed: 0xC0DE).map { film in
            var f = film
            let n = Int.random(in: 1...2, using: &generator)
            f.releases = (0..<n).map { i in
                let format: ReleaseFormat = [.uhd4K, .bluRay, .dvd][Int.random(in: 0...2, using: &generator)]
                let year = 2015 + Int.random(in: 0...11, using: &generator)
                let month = 1 + Int.random(in: 0...11, using: &generator)
                return release(format, purchased: Int.random(in: 0...24, using: &generator) > 0,
                               cost: Double(Int.random(in: 5...45, using: &generator)),
                               date: "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(1 + i, 2))",
                               lowest: 10, hdr: format == .uhd4K ? ReleaseHDR.hdr10 : "",
                               studio: ["Criterion", "Arrow Video", "Warner Bros."][i % 3], origin: "United States")
            }
            f.genre = ["Action", "Drama", "Horror"][Int.random(in: 0...2, using: &generator)]
            f.directors = ["D \(Int.random(in: 0...80, using: &generator))"]
            f.cast = ["C \(Int.random(in: 0...300, using: &generator))", "C \(Int.random(in: 0...300, using: &generator))"]
            return f
        }
    }

    @MainActor
    private static func dataVizPerfScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-perf")
        let calendar = Calendar.current
        let films = librarySizedCorpus()
        r.metric("perf-corpus-films", Double(films.count), "films")
        r.metric("perf-corpus-releases", Double(films.reduce(0) { $0 + $1.releases.count }), "releases")
        r.metric("perf-corpus-viewings", Double(films.reduce(0) { $0 + $1.calendarTable.count }), "viewings")

        func timed(_ name: String, runs: Int = 5, _ body: () -> Void) {
            body() // warm
            var best = Double.infinity
            for _ in 0..<runs {
                let start = ContinuousClock.now
                body()
                best = min(best, milliseconds(ContinuousClock.now - start))
            }
            r.metric(name, (best * 100).rounded() / 100, "ms")
        }

        timed("perf-library-statistics") { _ = LibraryStatistics(films: films, showInfoComplete: true) }
        let records = films.map { DVFilmViewings($0, calendar: calendar) }
        timed("perf-viewing-records-cold") { _ = films.map { DVFilmViewings($0, calendar: calendar) } }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.filmID, $0) })
        timed("perf-viewing-records-reused") { _ = films.map { DVFilmViewings($0, calendar: calendar, reusing: byID[$0.id]) } }
        timed("perf-library-insights") { _ = LibraryInsights(films: films, viewings: records, today: fixtureToday, calendar: calendar) }
        timed("perf-viewing-period") {
            _ = ViewingPeriodStatistics(viewings: records, year: 1991, yearToDate: false, today: fixtureToday, calendar: calendar)
        }
        // The two passes the tab actually runs: the synchronous first visit (no records to
        // reuse) and every pass after it (the previous records on hand).
        timed("perf-recalculation-first-visit", runs: 3) {
            _ = DVDataset(films: films, previousRecords: [], showInfoComplete: true, today: fixtureToday, calendar: calendar)
        }
        timed("perf-recalculation-steady-state", runs: 3) {
            _ = DVDataset(films: films, previousRecords: records, showInfoComplete: true, today: fixtureToday, calendar: calendar)
        }
        // Main-thread cost of a background pass: gathering the inputs and applying the
        // result, with the computation itself awaited off the main actor.
        do {
            // A previous pass over all but one film: every record but one is reused, and
            // the inputs differ, so the pass really computes.
            let previous = DVDataset(films: Array(films.dropLast()), previousRecords: records, showInfoComplete: true)
            var ts = timespec(); unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            let before = Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
            let dataset = await DVDataset.compute(films: films, previous: previous, showInfoComplete: true)
            unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            let after = Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
            r.metric("perf-background-pass-main-thread-cpu", (after - before).rounded(), "ms")
            r.check("perf-background-pass-computes", dataset?.stats.totalFilms == films.count, "")
        }

        // The page's own costs (mount, resize, scroll, a year step) are `dataviz-canvas`'s.
        return r
    }

    static func oneTurn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }
}

// MARK: - Scenario: Canvas page

// `dataviz-render` (in `all`): the tab's page (27.44/27.45) rendered at 1148 pt (light and
// dark), 820 (light) and 1808 (dark), written to the sandbox root as
// canvas-<width>-<appearance>.png for inspection; each render must fit its width and repeat
// pixel for pixel. It also holds the print form to the screen form: a section with no
// controls prints exactly as tall as it draws on screen, less the band's 24 pt top spacing,
// because both come from the same builders.
// `dataviz-canvas` (opt-in, a measurement): the same, then the page's cost on the
// 1,400-film corpus — mount, teardown, a scroll sweep, a live-resize sweep, a year step — as
// main-thread CPU with layout, display and the Core Animation commit included, against an
// empty scroll view for the floor. `-FTDebugCanvasResizeLoop <kind>` loops resizes for
// `sample`. Off screen (windows far outside every display, never key): takes no focus.
extension DebugHarness {

    private struct CanvasHarnessSUIHost: View {
        let page: AnyView
        var body: some View {
            AppKitScrollView(modifier: EmptyModifier(), alwaysOverflows: true) { page }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    static func dataVizCanvasScenario(fidelityOnly: Bool) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: fidelityOnly ? "dataviz-render" : "dataviz-canvas")
        let calendar = Calendar.current
        func cpu() -> Double {
            var ts = timespec(); unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func p90(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, v.count * 9 / 10)] }
        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        // MARK: Card heights
        do {
            func model(_ films: [FilmSnapshot]) -> DVCanvasModel {
                DVCanvasModel(stats: LibraryStatistics(films: films), insights: LibraryInsights(films: films, today: fixtureToday, calendar: calendar),
                              period: nil, navigation: DVNavigation(appState: nil), showInfoComplete: true,
                              selectedYear: .constant(2026), yearToDate: .constant(true), compare: .constant(true), compareYear: .constant(2025))
            }
            let base = fixtureFilms() + standardCorpus(count: 160, seed: 0xB00C)
            // Eight more films due 2026-10-01 (viewed September 2025, 12-month threshold):
            // all ranked; the card shows what fits, and the list must not make the Rotation row any taller.
            let extra = (1...8).map { film("October \($0)", rating: $0, viewings: ["2025.09.0\($0)"]) }
            let crowded = model(base + extra)
            r.check("coming-up-ranks-every-film", crowded.insights.comingUp.count == crowded.insights.comingUpNextMonthItems.count
                        && crowded.insights.comingUpNextMonthItems.count >= 8
                        && zip(crowded.insights.comingUp, crowded.insights.comingUp.dropFirst()).allSatisfy { $0.rating >= $1.rating },
                    "\(crowded.insights.comingUp.map(\.name)) of \(crowded.insights.comingUpNextMonthItems.count)")
            let sparse = model(base)
            let pageView = DVCanvasPageView(frame: .zero)
            for w: CGFloat in [760, 1100, 1452] {
                let a = DVCanvasSections.rotation(sparse, .screen(pageView)).rows[0].height(w), b = DVCanvasSections.rotation(crowded, .screen(pageView)).rows[0].height(w)
                r.check("coming-up-view-all-keeps-row-height-\(Int(w))", a == b, "\(a) → \(b)")
            }
            // The Digital Sources, Audio and Subtitles and Encoding cards: one height in both
            // scopes at every width, however the row wraps (print builds every scope).
            let print = DVCanvasSections.technical(crowded, .print).rows.compactMap { $0 as? DVFlow }.flatMap(\.children)
            var unequal: [String] = []
            for w: CGFloat in stride(from: 220, through: 520, by: 20) {
                let hs = Set(print.map { $0.height(w) }.filter { $0 > 0 })
                if hs.count != 1 { unequal.append("\(Int(w)): \(hs.sorted())") }
            }
            // Scroll restore: a banked anchor lands in the first sizing with real geometry,
            // before anything is drawn, at the same section and offset — and reads back.
            let scroll = DVCanvasScrollNSView(frame: .zero)
            scroll.pendingAnchor = DVScrollAnchor(section: 3, offset: 40)
            scroll.page.model = crowded
            scroll.sizePage()
            let restoredBeforeGeometry = scroll.contentView.bounds.minY
            scroll.frame = NSRect(x: 0, y: 0, width: 1148, height: 700)
            scroll.tile()
            let top3 = scroll.page.sectionTops(width: scroll.contentView.bounds.width)[3]
            r.check("scroll-anchor-restored-at-first-sizing",
                    restoredBeforeGeometry == 0 && scroll.contentView.bounds.minY == top3 + 40 && scroll.pendingAnchor == nil
                        && scroll.currentAnchor() == DVScrollAnchor(section: 3, offset: 40),
                    "y \(scroll.contentView.bounds.minY), section top \(top3), anchor \(String(describing: scroll.currentAnchor()))")
            r.check("technical-cards-one-height", unequal.isEmpty && print.count == 6, unequal.joined(separator: "; "))
        }

        // MARK: Renders
        do {
            let films = fixtureFilms() + standardCorpus(count: 160, seed: 0xB00C)
            let stats = LibraryStatistics(films: films)
            let insights = LibraryInsights(films: films, today: fixtureToday, calendar: calendar)
            let records = films.map { DVFilmViewings($0, calendar: calendar) }
            let period = ViewingPeriodStatistics(viewings: records, year: 2026, yearToDate: true, today: fixtureToday, calendar: calendar)
            let model = DVCanvasModel(stats: stats, insights: insights, period: period, navigation: DVNavigation(appState: nil),
                                      showInfoComplete: true, selectedYear: .constant(2026), yearToDate: .constant(true),
                                      compare: .constant(true), compareYear: .constant(2025))
            let root = DebugSandbox.rootURL
            for (width, name) in [(1148, NSAppearance.Name.aqua), (1148, .darkAqua), (820, .aqua), (1808, .darkAqua)] {
                let w = CGFloat(width)
                let canvas = DVCanvasPageView(frame: .zero)
                canvas.appearance = NSAppearance(named: name)
                canvas.model = model
                let h = canvas.fittingHeight(width: w)
                let label = "\(width)-\(name == .aqua ? "light" : "dark")"
                r.metric("render-\(label)-height", Double(h), "pt")
                // The canvas draws into plain CALayers, which cacheDisplay does not capture:
                // render its drawing directly, over the window background, with its controls.
                func render() -> NSBitmapImageRep? {
                    canvas.frame = NSRect(x: 0, y: 0, width: w, height: h)
                    canvas.layoutSubtreeIfNeeded()
                    guard let ctx = unsafe CGContext(data: nil, width: Int(w * 2), height: Int(h * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    ctx.scaleBy(x: 2, y: 2)
                    ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        CGRect(x: 0, y: 0, width: w, height: h).fill()
                        canvas.drawPage(CGRect(x: 0, y: 0, width: w, height: h), in: ctx)
                        for sub in canvas.subviews where !sub.isHidden {
                            ctx.saveGState()
                            ctx.translateBy(x: sub.frame.minX, y: sub.frame.minY)
                            sub.appearance = NSAppearance(named: name)
                            sub.displayIgnoringOpacity(sub.bounds, in: NSGraphicsContext.current!)
                            ctx.restoreGState()
                        }
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    return ctx.makeImage().map { NSBitmapImageRep(cgImage: $0) }
                }
                guard let first = render(), let second = render(),
                      let a = first.representation(using: .png, properties: [:]),
                      let b = second.representation(using: .png, properties: [:]) else {
                    r.check("render-\(label)-bitmap", false, ""); continue
                }
                r.check("render-\(label)-fits-width", h > 2000 && first.pixelsWide == width * 2, "height \(h), \(first.pixelsWide) px wide")
                r.check("render-\(label)-repeats", a == b, "two renders of one model differ")
                if let root { try? a.write(to: root.appendingPathComponent("canvas-\(label).png")) }
            }

            // A card with an action (the Wishlist card on the tab) is one clickable region, its
            // title row ending in a chevron; drawn as linked-card.png for inspection.
            let linked = DVK.card(title: "Wishlist", action: {}, [DVK.factRow(label: "Items", value: "2")])
            var spots: [DVHotspot] = []
            let cardRect = CGRect(x: 0, y: 0, width: 320, height: linked.height(320))
            linked.hotspots(cardRect, into: &spots)
            r.check("linked-card-is-one-pointer-region", spots.count == 1 && spots[0].pointer && spots[0].rect == cardRect,
                    "\(spots.map { "\($0.rect) pointer \($0.pointer)" })")
            if let root, let ctx = unsafe CGContext(data: nil, width: 640, height: Int(cardRect.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: 2, y: 2); ctx.translateBy(x: 0, y: cardRect.height); ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill(); cardRect.fill()
                    linked.draw(DVGraphics(ctx: ctx, scale: 2, dirty: .infinite), cardRect)
                }
                NSGraphicsContext.restoreGraphicsState()
                if let image = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: root.appendingPathComponent("linked-card.png"))
                }
            }

            // Print and screen share their builders: Rotation and Release Decades carry no
            // control, so each prints as one block exactly as tall as its screen section at
            // the print width, less the 24 pt the band keeps above a section that follows another.
            let screen = DVCanvasPageView(frame: .zero)
            screen.model = model
            let screenHeights = screen.debugSectionHeights(width: DVPrintLayout.width + 48)
            let printSections = DVCanvasSections.sections(model, .print)
            let blocks = DVCanvasSections.printBlocks(model)
            for (title, key) in [("Rotation", "rotation"), ("Release Decades, Runtime, and Picture", "decades")] {
                guard let index = printSections.firstIndex(where: { $0.title == title }), screenHeights.indices.contains(index) else {
                    r.check("print-matches-screen-\(key)", false, "no section"); continue
                }
                // A section of several rows prints one block per row, the stack's gap between them.
                let start = printSections.prefix(index).reduce(0) { $0 + $1.rows.count }
                let rows = printSections[index].rows.count
                let printed = blocks[start..<(start + rows)].reduce(0) { $0 + $1.height(DVPrintLayout.width) } + DVStyle.gap * CGFloat(rows - 1)
                r.check("print-matches-screen-\(key)", printed == screenHeights[index] - 24,
                        "print \(printed), screen \(screenHeights[index]) − 24")
            }
        }

        if fidelityOnly || UserDefaults.standard.bool(forKey: "FTDebugCanvasFidelityOnly") { return r }

        // MARK: Cost
        let films = librarySizedCorpus()
        let dataset = DVDataset(films: films, previousRecords: [], showInfoComplete: true, today: fixtureToday, calendar: calendar)
        func period(_ year: Int) -> ViewingPeriodStatistics {
            ViewingPeriodStatistics(viewings: dataset.viewingRecords, year: year, yearToDate: false, today: fixtureToday, calendar: calendar)
        }
        let basePeriod = period(1991)
        func canvasRoot(_ p: ViewingPeriodStatistics) -> AnyView {
            AnyView(DVCanvasScrollView(model: DVCanvasModel(
                stats: dataset.stats, insights: dataset.insights, period: p, navigation: DVNavigation(appState: nil),
                showInfoComplete: true, selectedYear: .constant(p.year), yearToDate: .constant(false),
                compare: .constant(true), compareYear: .constant(p.compareYear), revision: p.year))
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews { if let sv = findScrollView(sub) { return sv } }
            return nil
        }
        func viewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = unsafe withUnsafeMutablePointer(to: &info) {
                unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }

        for (kind, make) in [("canvas", { (p: ViewingPeriodStatistics) in canvasRoot(p) }),
                             // The floor: an empty scroll view, for what AppKit itself costs.
                             ("empty", { (_: ViewingPeriodStatistics) in AnyView(CanvasHarnessSUIHost(page: AnyView(Color.clear.frame(height: 2072)))) })] {
            // A titled window far off every screen: drawn and committed like a real one,
            // never visible, never key.
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1148, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            func settle() async {
                for _ in 0..<6 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    CATransaction.flush()
                    await oneTurn()
                }
            }
            await settle()
            let baseFootprint = footprintMB()

            // Mount / teardown, five times each.
            var mounts: [Double] = [], teardowns: [Double] = []
            var host: NSHostingView<AnyView>!
            for i in 0..<5 {
                host = NSHostingView(rootView: make(basePeriod))
                host.frame = NSRect(x: 0, y: 0, width: 1148, height: 700)
                DVCanvasPageView.drawCalls = 0
                let t0 = cpu()
                window.contentView = host
                await settle()
                mounts.append(cpu() - t0)
                if i == 4 { break }
                let t1 = cpu()
                window.contentView = nil
                await settle()
                teardowns.append(cpu() - t1)
                host = nil
            }
            r.metric("\(kind)-mount-median", round1(median(mounts)), "ms")
            r.metric("\(kind)-teardown-median", round1(median(teardowns)), "ms")
            if kind == "canvas" { r.metric("canvas-mount-draw-calls", Double(DVCanvasPageView.drawCalls), "n") }
            r.metric("\(kind)-view-count", Double(viewCount(host)), "views")
            r.metric("\(kind)-footprint-with-page", round1(footprintMB() - baseFootprint), "MB")
            guard let scrollView = findScrollView(host) else { r.check("\(kind)-scroll-view", false, ""); continue }
            r.metric("\(kind)-document-height", Double(scrollView.documentView?.frame.height ?? 0), "pt")

            // Scroll: 150 steps of 12 pt, each laid out, drawn and committed.
            DVCanvasPageView.drawCalls = 0; DVCanvasPageView.drawnArea = 0; DVCanvasPageView.drawMs = 0
            var scrolls: [Double] = []
            for step in 1...150 {
                let t = cpu()
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 12))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                window.displayIfNeeded()
                CATransaction.flush()
                scrolls.append(cpu() - t)
                await oneTurn()
            }
            r.metric("\(kind)-scroll-step-median", round1(median(scrolls) * 100) / 100, "ms")
            r.metric("\(kind)-scroll-step-p90", round1(p90(scrolls) * 100) / 100, "ms")
            if kind == "canvas" {
                if let page = scrollView.documentView as? DVCanvasPageView {
                    r.metric("canvas-strip-backing-after-scroll", page.debugStripBackingMB, "MB")
                }
                r.metric("canvas-scroll-draw-calls", Double(DVCanvasPageView.drawCalls), "n")
                r.metric("canvas-scroll-drawn-area-per-step", Double(DVCanvasPageView.drawnArea / 150), "pt²")
                r.metric("canvas-scroll-draw-ms-per-step", DVCanvasPageView.drawMs / 150, "ms")
            }
            // Full sweep down and back up at 40 pt a frame (a brisk flick): the worst
            // step, which a median hides, and the worst single strip draw — after the page
            // has sat at rest long enough for the idle prefetch to finish.
            DVCanvasPageView.prefetches = 0
            let restEnd = CACurrentMediaTime() + 1.5
            while CACurrentMediaTime() < restEnd { await oneTurn() }
            if kind == "canvas", let page = scrollView.documentView as? DVCanvasPageView {
                r.metric("canvas-idle-prefetches", Double(DVCanvasPageView.prefetches), "n")
                r.metric("canvas-strip-backing-after-prefetch", round1(page.debugStripBackingMB), "MB")
            }
            DVCanvasPageView.drawMaxMs = 0; DVCanvasPageView.drawCalls = 0
            var sweepSteps: [Double] = [], sweepWall: [Double] = []
            let docHeight = (scrollView.documentView?.frame.height ?? 0) - 700
            let downs = Array(stride(from: 0.0, through: Double(docHeight), by: 40))
            for y in downs + downs.reversed() {
                let t = cpu(), w0 = CACurrentMediaTime()
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                window.displayIfNeeded()
                CATransaction.flush()
                sweepSteps.append(cpu() - t)
                sweepWall.append((CACurrentMediaTime() - w0) * 1000)
                await oneTurn()
            }
            r.metric("\(kind)-sweep-wall-max", round1(sweepWall.max() ?? 0), "ms")
            r.metric("\(kind)-sweep-step-max", round1(sweepSteps.max() ?? 0), "ms")
            r.metric("\(kind)-sweep-step-p99", round1(sweepSteps.sorted()[min(sweepSteps.count - 1, sweepSteps.count * 99 / 100)]), "ms")
            r.metric("\(kind)-sweep-steps-over-4ms", Double(sweepSteps.filter { $0 > 4 }.count), "n")
            if kind == "canvas" {
                r.metric("canvas-sweep-strip-draw-max", round1(DVCanvasPageView.drawMaxMs), "ms")
                r.metric("canvas-sweep-draw-calls", Double(DVCanvasPageView.drawCalls), "n")
                if !DVCanvasPageView.debugNoPrefetch {
                    r.check("canvas-sweep-draws-nothing-after-prefetch", DVCanvasPageView.drawCalls == 0,
                            "\(DVCanvasPageView.drawCalls) strip draws during a full sweep")
                }
            }

            // `-FTDebugCanvasResizeLoop <kind>`: resize sweeps for 15 s, for `sample`.
            if UserDefaults.standard.string(forKey: "FTDebugCanvasResizeLoop") == kind {
                DVCanvasPageView.debugLiveResize = true
                print("RESIZE-LOOP START"); unsafe fflush(stdout)
                let end = CACurrentMediaTime() + 15
                var w: CGFloat = 1148, dir: CGFloat = -2
                while CACurrentMediaTime() < end {
                    w += dir; if w < 900 || w > 1148 { dir = -dir }
                    window.setContentSize(NSSize(width: w, height: 700))
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    CATransaction.flush()
                    await oneTurn()
                }
                print("RESIZE-LOOP END"); unsafe fflush(stdout)
                DVCanvasPageView.debugLiveResize = false
            }
            // Live resize: 2 pt steps from 1148 to 900 and back, the page mid-scroll.
            DVCanvasPageView.debugLiveResize = true
            await settle()
            DVCanvasPageView.drawMs = 0; DVCanvasPageView.layoutMs = 0
            var resizes: [Double] = []
            let sweep = Array(stride(from: 1146.0, through: 900.0, by: -2.0)) + Array(stride(from: 902.0, through: 1148.0, by: 2.0))
            for w in sweep {
                let t = cpu()
                window.setContentSize(NSSize(width: w, height: 700))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                resizes.append(cpu() - t)
                await oneTurn()
            }
            DVCanvasPageView.debugLiveResize = false
            await settle()
            r.metric("\(kind)-resize-step-median", round1(median(resizes)), "ms")
            r.metric("\(kind)-resize-step-p90", round1(p90(resizes)), "ms")
            if kind == "canvas" {
                r.metric("canvas-resize-draw-ms-per-step", DVCanvasPageView.drawMs / Double(sweep.count), "ms")
                r.metric("canvas-resize-layout-ms-per-step", DVCanvasPageView.layoutMs / Double(sweep.count), "ms")
            }

            // Year step: the period section rebuilt for another year, four times.
            var steps: [Double] = []
            for y in [1992, 1993, 1994, 1995] {
                let p = period(y)
                let t = cpu()
                host.rootView = make(p)
                await settle()
                steps.append(cpu() - t)
            }
            r.metric("\(kind)-year-step-median", round1(median(steps)), "ms")

            window.contentView = nil
            await settle()
            window.orderOut(nil)
            window.close()
        }
        return r
    }

}

#endif
