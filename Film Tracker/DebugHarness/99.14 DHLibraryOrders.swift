// MARK: - DHLibraryOrders.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Harness coverage for MetadataCache's library orders: the background-built, incrementally
// repaired per-option orders that let sort() answer a view by filtering instead of sorting.
//
// The claim under test is EXACT equivalence: for every input sort() accepts, the array it
// returns through a library order is the array the full sort (`_performSort`) returns for
// the same input against the same metadata. Every check below compares against that full
// sort — reached through `MetadataCache.referenceSort`, which calls it directly — rather
// than against a restated rule, so a defect in the orders cannot be mirrored by the check.
//
//   library-order-fields       FilmMetadata's sort projection names every stored field
//   library-order-equivalence  orders vs the full sort, many corpora, subsets and shapes
//   library-order-mutations    a long seeded mutation run; the repaired orders must equal
//                              a fresh full sort after every step, and the build/mutation
//                              race must still install exact orders
//   load-pipeline-equivalence  every gallery view × sort × direction × filter through the
//                              REAL DataCoordinator.loadFilms, orders on vs off, then a run
//                              of real edits; with timings (run on a copy of a real library
//                              for realistic numbers)

#if DEBUG

import Foundation

extension DebugHarness {

    /// Scenario names owned by this file, in the order `all` runs them. The pipeline
    /// scenario reloads the live gallery and edits films, so it is opt-in.
    static var libraryOrderScenarios: [String] {
        ["library-order-fields", "library-order-equivalence", "library-order-mutations"]
    }

    static func runLibraryOrderScenario(_ scenario: String,
                                        coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "library-order-fields":      return libraryOrderFieldsScenario()
        case "library-order-equivalence": return await libraryOrderEquivalenceScenario()
        case "library-order-mutations":   return await libraryOrderMutationsScenario()
        case "load-pipeline-equivalence": return await loadPipelineEquivalenceScenario(coordinator: coordinator)
        default:                          return nil
        }
    }

    // MARK: - Shared

    /// Every library-order key sort() can be asked for.
    private static var allOrderKeys: [MetadataCache.LibraryOrderKey] {
        var keys = SortOption.allCases.map { MetadataCache.LibraryOrderKey($0) }
        for format in ReleaseFormat.allCases {
            keys.append(MetadataCache.LibraryOrderKey(.datePurchased, purchaseFormat: format))
        }
        return keys
    }

    /// An isolated cache over `films` with library orders on and every order built.
    private static func orderedCache(_ films: [FilmSnapshot], tag: String) async -> MetadataCache {
        let cache = MetadataCache(isolatedForTesting: FileManager.default.temporaryDirectory
            .appendingPathComponent("library-orders-\(tag).bin"))
        await cache.rebuild(from: Dictionary(uniqueKeysWithValues: films.map { ($0.id, $0) }))
        cache.usesLibraryOrders = true
        await cache.buildLibraryOrdersForTesting()
        return cache
    }

    private static func reference(_ ids: [UUID], _ key: MetadataCache.LibraryOrderKey,
                                  _ direction: SortDirection, _ cache: MetadataCache) -> [UUID] {
        MetadataCache.referenceSort(ids, by: key.option, direction: direction,
                                    purchaseFormat: key.purchaseFormat, using: cache.metadata)
    }

    /// Titles and keys built to stress the comparators' tiebreaks: case and diacritic
    /// variants, leading articles and punctuation, numerals, scripts beyond Latin, empty and
    /// whitespace names, duplicate titles with equal years (resolved only by the film ID),
    /// and purchases spread across formats and tiers.
    private static func tieHeavyCorpus(count: Int, seed: UInt64) -> [FilmSnapshot] {
        var generator = SeededGenerator(seed: seed)
        let titles = ["The Thing", "the thing", "THE THING", "Thing", "Thîng", "Thing 2", "Thing 10",
                      "Thing 1", "10 Things", "2 Things", "100", "A Thing", "An Thing", "(Thing)",
                      "...Thing", "[Thing]", "Ångström", "Angstrom", "Zebra", "zebra", "Éclair",
                      "Eclair", "東京物語", "Сталкер", "🎬 Film", "", " ", "Ⅷ", "ǅungla", "ß", "ss"]
        let formats = ReleaseFormat.allCases.map(\.rawValue) + ["VHS"]
        return (0..<count).map { _ in
            let title = titles[Int.random(in: 0..<titles.count, using: &generator)]
            let purchases: [ReleaseSnapshot] = (0..<Int.random(in: 0...3, using: &generator)).map { _ in
                let format = formats[Int.random(in: 0..<formats.count, using: &generator)]
                let dated = Int.random(in: 0...2, using: &generator)
                return ReleaseSnapshot(purchased: Int.random(in: 0...4, using: &generator) > 0,
                                       format: format,
                                       purchaseDate: dated == 0 ? "" : dated == 1 ? "2021.05.0\(Int.random(in: 1...3, using: &generator))" : "garbage")
            }
            var film = makeSnapshot(
                name: title,
                releaseYear: ["1999", "2000", "", "abc"][Int.random(in: 0...3, using: &generator)],
                rating: Int.random(in: 0...2, using: &generator),
                duration: ["5400000", "5430000", "0", "", "x", "5459999"][Int.random(in: 0...5, using: &generator)],
                lastWatched: Int.random(in: 0...1, using: &generator) == 0 ? "" : "2023.06.1\(Int.random(in: 0...2, using: &generator))",
                dateAdded: ["", "2020.01.01", "2020.01.02", "99.99.99"][Int.random(in: 0...3, using: &generator)],
                lastModified: ["", "2024.01.01", "2024.01.01", "2024-13-45"][Int.random(in: 0...3, using: &generator)],
                releaseDate: ["", "1999-05-01", "1999-05-01T12:00:00Z", "1999/05/01"][Int.random(in: 0...3, using: &generator)],
                calendarTable: viewingDates(count: Int.random(in: 0...2, using: &generator)),
                releases: purchases)
            if Int.random(in: 0...5, using: &generator) == 0 {
                film.sortName = titles[Int.random(in: 0..<titles.count, using: &generator)]
            }
            if Int.random(in: 0...6, using: &generator) == 0 {
                film.edited = true
                film.editedDuration = ["3600000", "", "-5"][Int.random(in: 0...2, using: &generator)]
            }
            return film
        }
    }

    // MARK: - Fields

    /// The sort projection must classify every stored property of FilmMetadata exactly
    /// once. A field added to the struct and read by a comparator but missing from
    /// `sortsIdentically` would let a repair skip a film that moved; this is what forces
    /// the classification to be made.
    private static func libraryOrderFieldsScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "library-order-fields")
        let sample = FilmMetadata(from: makeSnapshot(name: "Sample"))
        let labels = Set(Mirror(reflecting: sample).children.compactMap(\.label))
        let sortFields = FilmMetadata.sortFieldNames
        let otherFields = FilmMetadata.nonSortFieldNames
        r.check("fields-disjoint", sortFields.isDisjoint(with: otherFields),
                "\(sortFields.intersection(otherFields).sorted())")
        r.check("fields-cover-struct", labels == sortFields.union(otherFields),
                "unclassified \(labels.subtracting(sortFields.union(otherFields)).sorted()), "
                    + "stale \(sortFields.union(otherFields).subtracting(labels).sorted())")

        // Each sort field, changed alone, must make sortsIdentically false: proves the
        // function reads every field it claims to (a dropped comparison would pass the
        // coverage check above and still skip real moves).
        let base = makeSnapshot(name: "Base", releaseYear: "2000", rating: 1, duration: "5400000",
                                lastWatched: "2023.06.15", dateAdded: "2020.01.01",
                                lastModified: "2024.01.01", releaseDate: "2000-01-01",
                                calendarTable: viewingDates(count: 1),
                                releases: [ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue,
                                                           purchaseDate: "2021.05.04")])
        let baseEntry = FilmMetadata(from: base)
        var variants: [String: FilmSnapshot] = [:]
        func variant(_ field: String, _ change: (inout FilmSnapshot) -> Void) {
            var copy = base; change(&copy); variants[field] = copy
        }
        variant("titleKey") { $0.name = "Other" }
        variant("titleStartsWithNumber") { $0.name = "9 Base" }
        variant("year") { $0.releaseYear = "2001" }
        variant("releaseDateParsed") { $0.releaseDate = "2000-02-02" }
        variant("effectiveDuration") { $0.duration = "5500000" }
        variant("dateAddedParsed") { $0.dateAdded = "2020.01.02" }
        variant("lastWatchedParsed") { $0.lastWatched = "2023.06.16" }
        variant("lastModifiedParsed") { $0.lastModified = "2024.01.02" }
        variant("rating") { $0.userRating = 2 }
        variant("viewCount") { $0.calendarTable = viewingDates(count: 2) }
        variant("mostRecentPurchaseDate") {
            $0.releases = [ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue, purchaseDate: "2021.05.05")]
        }
        variant("hasPurchasedReleases") { $0.releases = [] }
        variant("mostRecentPurchaseDateByFormat") {
            $0.releases = [ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue, purchaseDate: "2021.05.04"),
                           ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue, purchaseDate: "2020.01.01")]
        }
        variant("purchasedFormats") {
            $0.releases = [ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue, purchaseDate: "2021.05.04"),
                           ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue, purchaseDate: "")]
        }
        for (field, snapshot) in variants.sorted(by: { $0.key < $1.key }) {
            let entry = FilmMetadata(from: snapshot)
            r.check("detects \(field)", !entry.sortsIdentically(to: baseEntry), "")
        }
        // `id` cannot be varied through the snapshot of the same film; a different film
        // with identical fields must still differ.
        var twin = base
        twin = FilmSnapshot(copying: twin, id: UUID())
        r.check("detects id", !FilmMetadata(from: twin).sortsIdentically(to: baseEntry), "")
        r.check("variants cover every sort field",
                Set(variants.keys).union(["id"]) == sortFields,
                "missing \(sortFields.subtracting(variants.keys).subtracting(["id"]).sorted())")

        // And a change to non-sort data alone must leave it true.
        var notesOnly = base
        notesOnly.notes = "changed"
        notesOnly.rotationThresholdOverride = 3
        r.check("ignores non-sort change",
                FilmMetadata(from: notesOnly).sortsIdentically(to: baseEntry), "")
        return r
    }

    // MARK: - Equivalence

    private static func libraryOrderEquivalenceScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "library-order-equivalence")
        var generator = SeededGenerator(seed: 0x0DE5_0001)

        let corpora: [(String, [FilmSnapshot])] = [
            ("standard-700", standardCorpus(count: 700, seed: 0x0DE5_0002)),
            ("tie-heavy-600", tieHeavyCorpus(count: 600, seed: 0x0DE5_0003)),
            ("tie-heavy-49", tieHeavyCorpus(count: 49, seed: 0x0DE5_0004)),
            ("standard-48", standardCorpus(count: 48, seed: 0x0DE5_0005)),
        ]
        for (name, films) in corpora {
            let cache = await orderedCache(films, tag: name)
            let hitsBefore = cache.libraryOrderHitsForTesting
            var expectedHits = 0
            let all = Array(cache.metadata.keys)
            var built = 0, comparisons = 0, mismatches: [String] = []

            for key in allOrderKeys {
                guard let order = cache.libraryOrderForTesting(key) else {
                    mismatches.append("\(key.option)/\(key.purchaseFormat?.rawValue ?? "-"): no order built")
                    continue
                }
                built += 1
                if order != reference(all, key, .ascending, cache) {
                    mismatches.append("\(key.option)/\(key.purchaseFormat?.rawValue ?? "-"): order ≠ full sort")
                }
                for direction in [SortDirection.ascending, .descending] {
                    // Subset sizes on both sides of the threshold, the whole library, and
                    // the whole library minus one (the count-equality shortcut's neighbor).
                    var sizes = [0, 1, 2, 47, 48, 49, all.count / 2, all.count - 1, all.count]
                    sizes = sizes.filter { $0 >= 0 && $0 <= all.count }
                    for size in sizes {
                        let subset = Array(all.shuffled(using: &generator).prefix(size))
                        comparisons += 1
                        if size >= 48 { expectedHits += 1 }
                        let got = cache.sort(subset, by: key.option, direction: direction,
                                             purchaseFormat: key.purchaseFormat)
                        if got != reference(subset, key, direction, cache) {
                            mismatches.append("\(key.option)/\(key.purchaseFormat?.rawValue ?? "-") \(direction) size \(size)")
                        }
                    }
                    // Inputs sort() must refuse to answer from an order: a duplicate ID,
                    // and an ID with no metadata. The full sort's answer must come back.
                    if all.count >= 60 {
                        var withDuplicate = Array(all.prefix(59))
                        withDuplicate.append(withDuplicate[3])
                        var withUnknown = Array(all.prefix(59))
                        withUnknown.insert(UUID(), at: 10)
                        // Same length as the library: the shortcut must not take it.
                        var fullWithUnknown = all
                        fullWithUnknown[fullWithUnknown.count - 1] = UUID()
                        var fullWithDuplicate = all
                        fullWithDuplicate[fullWithDuplicate.count - 1] = fullWithDuplicate[0]
                        for (label, input) in [("duplicate", withDuplicate), ("unknown", withUnknown),
                                               ("full-unknown", fullWithUnknown), ("full-duplicate", fullWithDuplicate)] {
                            comparisons += 1
                            let got = cache.sort(input, by: key.option, direction: direction,
                                                 purchaseFormat: key.purchaseFormat)
                            if got != reference(input, key, direction, cache) {
                                mismatches.append("\(key.option) \(direction) \(label)")
                            }
                        }
                    }
                }
            }
            r.check("\(name) orders built", built == allOrderKeys.count, "\(built)/\(allOrderKeys.count)")
            // Not vacuous: the comparisons at or above the threshold went through the orders.
            let hits = cache.libraryOrderHitsForTesting - hitsBefore
            // Exactly the valid inputs at or above the threshold; never a duplicate- or
            // unknown-ID input.
            r.check("\(name) answered from orders", hits == expectedHits && hits > 0,
                    "\(hits) order hits, \(expectedHits) expected")
            r.check("\(name) equals full sort", mismatches.isEmpty,
                    "\(comparisons) comparisons; " + mismatches.prefix(8).joined(separator: "; "))
        }

        // Adoption: with no orders built, a full-library sort() must leave behind an order
        // equal to the full sort, in either direction it was asked in.
        let films = standardCorpus(count: 300, seed: 0x0DE5_0006)
        let cache = MetadataCache(isolatedForTesting: FileManager.default.temporaryDirectory
            .appendingPathComponent("library-orders-adopt.bin"))
        await cache.rebuild(from: Dictionary(uniqueKeysWithValues: films.map { ($0.id, $0) }))
        cache.usesLibraryOrders = true
        let all = Array(cache.metadata.keys)
        _ = cache.sort(all, by: .rating, direction: .descending)
        let adopted = cache.libraryOrderForTesting(MetadataCache.LibraryOrderKey(.rating))
        let adoptedMatches = adopted == reference(all, .init(.rating), .ascending, cache)
        r.check("adopts full-library sort", adoptedMatches,
                adopted == nil ? "no order" : adoptedMatches ? "" : "order differs")
        // A partial sort must not be adopted as a library order.
        _ = cache.sort(Array(all.prefix(200)), by: .year, direction: .ascending)
        r.check("does not adopt partial sort", cache.libraryOrderForTesting(.init(.year)) == nil, "")
        return r
    }

    // MARK: - Mutations

    /// A long seeded run of every mutation path, with the repaired orders compared to a
    /// fresh full sort after each step.
    private static func libraryOrderMutationsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "library-order-mutations")
        var generator = SeededGenerator(seed: 0x0DE5_1001)
        var films = Dictionary(uniqueKeysWithValues:
            (standardCorpus(count: 400, seed: 0x0DE5_1002) + tieHeavyCorpus(count: 200, seed: 0x0DE5_1003))
                .map { ($0.id, $0) })
        let cache = await orderedCache(Array(films.values), tag: "mutations")

        func randomFilm() -> FilmSnapshot {
            films.values.randomElement(using: &generator)!
        }
        func perturb(_ film: FilmSnapshot) -> FilmSnapshot {
            var copy = film
            switch Int.random(in: 0...11, using: &generator) {
            case 0: copy.name = ["Zed", "Alpha", "the alpha", "10", "Ω", "Thing"].randomElement(using: &generator)!
            case 1: copy.releaseYear = String(Int.random(in: 1950...2030, using: &generator))
            case 2: copy.userRating = Int.random(in: 0...5, using: &generator)
            case 3: copy.duration = String(Int.random(in: 0...9_000_000, using: &generator))
            case 4: copy.dateAdded = "20\(Int.random(in: 10...24, using: &generator)).0\(Int.random(in: 1...9, using: &generator)).11"
            case 5: copy.lastModified = "2025.0\(Int.random(in: 1...9, using: &generator)).0\(Int.random(in: 1...9, using: &generator))"
            case 6: copy.calendarTable = viewingDates(count: Int.random(in: 0...4, using: &generator))
                    copy.lastWatched = copy.calendarTable.last ?? ""
            case 7: copy.releases = [ReleaseSnapshot(purchased: true,
                                                     format: ReleaseFormat.allCases.randomElement(using: &generator)!.rawValue,
                                                     purchaseDate: "2022.0\(Int.random(in: 1...9, using: &generator)).01")]
            case 8: copy.sortName = ["", "Aardvark", "Zulu"].randomElement(using: &generator)!
            case 9: copy.releaseDate = "19\(Int.random(in: 50...99, using: &generator))-01-01"
            case 10: copy.notes = "non-sort \(Int.random(in: 0...999, using: &generator))"   // must not move it
            default: copy.rotationThresholdOverride = Int.random(in: 1...24, using: &generator)  // nor this
            }
            return copy
        }

        var mismatches: [String] = []
        var stepsWithOrders = 0, rebuilds = 0, drops = 0
        // Every step is checked against a full reference sort of every order, so the walk's
        // cost is linear in its length; `all` takes a shorter walk, `full` the long one.
        let steps = isThorough ? 900 : 250
        for step in 0..<steps {
            let op = Int.random(in: 0...99, using: &generator)
            let label: String
            switch op {
            case 0..<55:                       // one film edited
                let edited = perturb(randomFilm())
                films[edited.id] = edited
                cache.updateFilm(edited)
                label = "update"
            case 55..<65:                      // one film added
                let added = tieHeavyCorpus(count: 1, seed: UInt64(step) &+ 0xAD)[0]
                films[added.id] = added
                cache.addFilm(added)
                label = "add"
            case 65..<75:                      // one to three films removed
                let removed = Set((0..<Int.random(in: 1...3, using: &generator)).map { _ in randomFilm().id })
                for id in removed { films.removeValue(forKey: id) }
                cache.removeFilms(removed)
                label = "remove \(removed.count)"
            case 75..<85:                      // a small batch, with a repeated film
                var batch = (0..<Int.random(in: 2...8, using: &generator)).map { _ in perturb(randomFilm()) }
                let again = perturb(batch[0])
                batch.append(again)
                for film in batch { films[film.id] = film }
                cache.setEntries(batch.map(FilmMetadata.init(from:)))
                label = "batch \(batch.count)"
            case 85..<90:                      // a large batch: must drop, not repair
                let batch = (0..<80).map { _ in perturb(randomFilm()) }
                for film in batch { films[film.id] = film }
                cache.setEntries(batch.map(FilmMetadata.init(from:)))
                label = "large batch"
            case 90..<93:                      // a batch of non-sort changes only: keeps orders
                let batch = (0..<200).map { _ -> FilmSnapshot in
                    var film = randomFilm(); film.notes = "n\(step)"; return film
                }
                for film in batch { films[film.id] = film }
                let hadOrders = cache.libraryOrderForTesting(.init(.title)) != nil
                cache.setEntries(batch.map(FilmMetadata.init(from:)))
                if hadOrders && cache.libraryOrderForTesting(.init(.title)) == nil {
                    mismatches.append("step \(step): non-sort batch dropped the orders")
                }
                label = "non-sort batch"
            default:                           // the background rebuild lands
                await cache.buildLibraryOrdersForTesting()
                rebuilds += 1
                label = "rebuild"
            }

            // The cache must agree with the model of the library this run keeps.
            if Set(cache.metadata.keys) != Set(films.keys) {
                mismatches.append("step \(step) \(label): metadata out of step with the model")
            }
            let all = Array(cache.metadata.keys)
            var anyOrder = false
            for key in allOrderKeys {
                guard let order = cache.libraryOrderForTesting(key) else { continue }
                anyOrder = true
                if order != reference(all, key, .ascending, cache) {
                    mismatches.append("step \(step) \(label): \(key.option)/\(key.purchaseFormat?.rawValue ?? "-") order ≠ full sort")
                }
            }
            if anyOrder { stepsWithOrders += 1 } else { drops += 1 }
            // And through sort() itself, on a view-sized subset.
            let subset = Array(all.shuffled(using: &generator).prefix(Int.random(in: 48...all.count, using: &generator)))
            let key = allOrderKeys.randomElement(using: &generator)!
            let direction: SortDirection = Bool.random(using: &generator) ? .ascending : .descending
            if cache.sort(subset, by: key.option, direction: direction, purchaseFormat: key.purchaseFormat)
                != reference(subset, key, direction, cache) {
                mismatches.append("step \(step) \(label): sort() ≠ full sort for \(key.option) \(direction)")
            }
            if mismatches.count > 12 { break }
        }
        r.check("repaired orders equal full sort", mismatches.isEmpty, mismatches.prefix(12).joined(separator: "; "))
        // Not vacuous: a substantial share of steps must have run against live orders, so the
        // repair path (not the full-sort fallback) is what was compared. About half do; the
        // exact share depends on where the walk's rebuilds land, so the bar sits well below it.
        r.check("repair path exercised", stepsWithOrders >= steps / 4,
                "\(stepsWithOrders) of \(steps) steps had current orders; \(drops) without; \(rebuilds) rebuilds")
        r.metric("steps-with-orders", Double(stepsWithOrders), "steps")

        // The build/mutation race: a film changes after the detached build has sorted its
        // snapshot and before the result is installed. The installed orders must describe
        // the metadata as it is at install time, not the snapshot.
        cache.dropLibraryOrders(reason: nil)
        var raced: [UUID] = []
        cache.libraryOrderBuildDidFinishForTesting = {
            for _ in 0..<5 {
                let edited = perturb(randomFilm())
                films[edited.id] = edited
                cache.updateFilm(edited)
                raced.append(edited.id)
            }
            let added = tieHeavyCorpus(count: 1, seed: 0xFACE)[0]
            films[added.id] = added
            cache.addFilm(added)
            let gone = randomFilm().id
            films.removeValue(forKey: gone)
            cache.removeFilms([gone])
        }
        await cache.buildLibraryOrdersForTesting()
        cache.libraryOrderBuildDidFinishForTesting = nil
        let all = Array(cache.metadata.keys)
        var raceMismatches: [String] = []
        var raceOrders = 0
        for key in allOrderKeys {
            guard let order = cache.libraryOrderForTesting(key) else { continue }
            raceOrders += 1
            if order != reference(all, key, .ascending, cache) { raceMismatches.append("\(key.option)") }
        }
        r.check("race: orders installed", raceOrders == allOrderKeys.count, "\(raceOrders)/\(allOrderKeys.count)")
        r.check("race: installed orders equal full sort", raceMismatches.isEmpty && raced.count == 5,
                raceMismatches.joined(separator: ", "))

        // A burst of single-film edits beyond the repair budget drops the orders (bounding
        // the main-thread cost of an import), and the fallback still answers exactly.
        await cache.buildLibraryOrdersForTesting()
        // Rating changes always move a film under .rating, so each counts against the budget.
        for index in 0..<70 {
            var edited = randomFilm()
            edited.userRating = (edited.userRating + 1 + index % 4) % 6
            films[edited.id] = edited
            cache.updateFilm(edited)
        }
        r.check("burst beyond budget drops orders",
                allOrderKeys.allSatisfy { cache.libraryOrderForTesting($0) == nil }, "")
        let burstAll = Array(cache.metadata.keys)
        r.check("fallback after burst equals full sort",
                cache.sort(burstAll, by: .title, direction: .descending) == reference(burstAll, .init(.title), .descending, cache), "")
        return r
    }

    // MARK: - Load Pipeline

    /// Every gallery view through the real DataCoordinator.loadFilms with the library
    /// orders on and off. The result arrays must be identical; the timings show what the
    /// orders save on the main thread.
    private static func loadPipelineEquivalenceScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "load-pipeline-equivalence")
        let store = coordinator.memoryStoreForTesting
        let cache = MetadataCache.shared
        let ordersBefore = cache.usesLibraryOrders
        defer { cache.usesLibraryOrders = ordersBefore }
        if coordinator.getAllFilms().count < 200 {
            coordinator.importFilms(standardCorpus(count: 800, seed: 0x0DE5_2001)
                                    + tieHeavyCorpus(count: 200, seed: 0x0DE5_2002))
            // A user list holding a slice of the corpus, so the list path is covered.
            let listID = coordinator.createList(name: "Library Order Harness", displayOrder: 999)
            _ = coordinator.addFilmsToList(filmIDs: Set(coordinator.getAllFilms().prefix(300).map(\.id)), listID: listID)
        }
        // Smart-list memberships come from a background calculation.
        coordinator.smartLists.forceFullRecalculation()
        try? await Task.sleep(for: .seconds(2))
        r.metric("library-films", Double(coordinator.getAllFilms().count), "films")

        var views: [ViewIdentifier] = [.allFilms, .filmQueue, .search]
        views += UnwatchedCategory.allCases.map { .unwatched($0) }
        views += SmartListType.allCases.map { .smartList($0) }
        views += coordinator.getAllLists().map { .list($0.listID) }
        let filterSets: [Set<FilterOption>] = [[]] + FilterOption.allCases.filter { $0 != .none }.map { [$0] }
            + [[.watched, .purchased], [.unwatched, .drama]]

        func runAll(ordersOn: Bool) -> (results: [String: [UUID]], milliseconds: [Double], slowest: String) {
            cache.usesLibraryOrders = ordersOn
            var results: [String: [UUID]] = [:]
            var times: [Double] = []
            var timed: [(Double, String)] = []
            for view in views {
                for option in SortOption.allCases {
                    for direction in [SortDirection.ascending, .descending] {
                        for filters in filterSets {
                            store.clearViewCacheForTesting()
                            let start = ContinuousClock.now
                            coordinator.loadFilms(viewID: view, sortOption: option,
                                                  filterOptions: filters, direction: direction)
                            let elapsed = milliseconds(ContinuousClock.now - start)
                            times.append(elapsed)
                            let label = "\(view)|\(option)|\(direction)|\(filters.map(\.rawValue).sorted())"
                            timed.append((elapsed, label))
                            results[label] = coordinator.films.map(\.id)
                        }
                    }
                }
            }
            let slowest = timed.sorted { $0.0 > $1.0 }.prefix(5)
                .map { "\(Fmt.fixed($0.0, 1))ms \($0.1)" }.joined(separator: "; ")
            return (results, times, slowest)
        }

        let legacy = runAll(ordersOn: false)
        cache.usesLibraryOrders = true
        await cache.buildLibraryOrdersForTesting()
        let hitsBefore = cache.libraryOrderHitsForTesting
        let ordered = runAll(ordersOn: true)
        r.check("orders answered the loads", cache.libraryOrderHitsForTesting - hitsBefore > legacy.results.count / 2,
                "\(cache.libraryOrderHitsForTesting - hitsBefore) order hits over \(ordered.results.count) loads")
        r.check("slowest loads (legacy)", true, legacy.slowest)
        r.check("slowest loads (orders)", true, ordered.slowest)
        let differing = legacy.results.keys.filter { legacy.results[$0] != ordered.results[$0] }.sorted()
        let nonEmpty = legacy.results.values.filter { !$0.isEmpty }.count
        r.check("every view identical", differing.isEmpty && legacy.results.count == ordered.results.count,
                "\(legacy.results.count) loads (\(nonEmpty) non-empty); differing: \(differing.prefix(6).joined(separator: "; "))")
        func p90(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        }
        r.metric("cold-load-median-legacy", stats(legacy.milliseconds).median, "ms")
        r.metric("cold-load-median-orders", stats(ordered.milliseconds).median, "ms")
        r.metric("cold-load-p90-legacy", p90(legacy.milliseconds), "ms")
        r.metric("cold-load-p90-orders", p90(ordered.milliseconds), "ms")
        r.metric("cold-load-max-legacy", legacy.milliseconds.max() ?? 0, "ms")
        r.metric("cold-load-max-orders", ordered.milliseconds.max() ?? 0, "ms")

        // Real edits through the coordinator, as the FilmSheet makes them. After each, the
        // refreshed gallery (served from the repaired orders) must equal what the full sort
        // produces for the same view.
        var generator = SeededGenerator(seed: 0x0DE5_2003)
        var editMismatches: [String] = []
        var refreshOrders: [Double] = [], refreshLegacy: [Double] = []
        let editViews: [(ViewIdentifier, SortOption, SortDirection)] = [
            (.allFilms, .title, .ascending), (.allFilms, .rating, .descending),
            (.allFilms, .year, .ascending), (.smartList(SmartListType.allCases[0]), .dateModified, .descending),
            (.unwatched(UnwatchedCategory.allCases[0]), .duration, .ascending), (.search, .lastViewed, .descending),
        ]
        for step in 0..<36 {
            let (view, option, direction) = editViews[step % editViews.count]
            coordinator.loadFilms(viewID: view, sortOption: option, filterOptions: [], direction: direction)
            guard var film = coordinator.getAllFilms().randomElement(using: &generator) else { break }
            switch step % 4 {
            case 0: film.userRating = (film.userRating + 1) % 6
            case 1: film.sortName = film.sortName.isEmpty ? "Zz \(step)" : ""
            case 2: film.releaseYear = String((Int(film.releaseYear) ?? 1990) + 1)
            default: film.notes += " ·"
            }
            let start = ContinuousClock.now
            await coordinator.updateFilm(film)   // refreshes the gallery synchronously first
            refreshOrders.append(milliseconds(ContinuousClock.now - start))
            let viaOrders = coordinator.films.map(\.id)

            cache.usesLibraryOrders = false
            store.clearViewCacheForTesting()
            let legacyStart = ContinuousClock.now
            coordinator.refreshFilms()
            refreshLegacy.append(milliseconds(ContinuousClock.now - legacyStart))
            let viaFullSort = coordinator.films.map(\.id)
            cache.usesLibraryOrders = true
            if viaOrders != viaFullSort { editMismatches.append("step \(step) \(view) \(option)") }
            if cache.libraryOrderForTesting(.init(option)) == nil && step % 4 != 3 {
                editMismatches.append("step \(step): \(option) order not current after a single edit")
            }
        }
        r.check("edits: refreshed gallery equals full sort", editMismatches.isEmpty,
                editMismatches.prefix(8).joined(separator: "; "))

        // Every other path the app mutates films through, each followed by the same
        // comparison and an audit of the shared orders.
        var pathMismatches: [String] = []
        func compareAfter(_ label: String) {
            // Refreshed here because not every path refreshes the gallery itself (a ratings
            // import leaves it to the per-film events), and a stale gallery says nothing
            // about the orders. The view cache is left as the mutation left it.
            coordinator.refreshFilms()
            let viaOrders = coordinator.films.map(\.id)
            cache.usesLibraryOrders = false
            store.clearViewCacheForTesting()
            coordinator.refreshFilms()
            let viaFullSort = coordinator.films.map(\.id)
            cache.usesLibraryOrders = true
            if viaOrders != viaFullSort { pathMismatches.append("\(label): gallery differs") }
            pathMismatches += auditSharedLibraryOrders().mismatches.map { "\(label): \($0)" }
        }
        await cache.buildLibraryOrdersForTesting()
        coordinator.loadFilms(viewID: .allFilms, sortOption: .lastViewed, filterOptions: [], direction: .descending)
        if let film = coordinator.getAllFilms().randomElement(using: &generator) {
            let dates = film.calendarTable + ["2026.10.1\(Int.random(in: 0...8, using: &generator))"]
            coordinator.updateViewingDates(filmID: film.id, calendarTable: dates, lastWatched: dates.last!, watched: true)
            compareAfter("updateViewingDates")
        }
        coordinator.loadFilms(viewID: .allFilms, sortOption: .rating, filterOptions: [], direction: .descending)
        let rated = coordinator.getAllFilms().shuffled(using: &generator).prefix(12)
        coordinator.applyImportedRatingUpdates(rated.map { (filmID: $0.id, rating: ($0.userRating + 2) % 6) })
        compareAfter("applyImportedRatingUpdates (12)")
        coordinator.loadFilms(viewID: .allFilms, sortOption: .title, filterOptions: [], direction: .ascending)
        coordinator.importFilms(tieHeavyCorpus(count: 3, seed: 0x0DE5_2004))
        compareAfter("importFilms (3)")
        let doomed = Set(coordinator.getAllFilms().shuffled(using: &generator).prefix(2).map(\.id))
        await coordinator.deleteFilms(withIDs: doomed)
        compareAfter("deleteFilms (2)")
        // A changed default rotation threshold rewrites ~every entry, but only `rotationDate`
        // moves: the orders must survive it (the threshold change is what made this work
        // necessary) and still equal the full sort afterward.
        let thresholdBefore = Preferences.defaultRotationThreshold
        let nextThreshold = Preferences.rotationThresholdOptions.first { $0 != thresholdBefore } ?? thresholdBefore
        Preferences.defaultRotationThreshold = nextThreshold
        coordinator.handleDefaultRotationThresholdChangeIfNeeded()
        try? await Task.sleep(for: .seconds(1))
        r.check("threshold change keeps orders", cache.libraryOrderForTesting(.init(.title)) != nil,
                "default \(thresholdBefore) → \(nextThreshold)")
        compareAfter("default rotation threshold")
        Preferences.defaultRotationThreshold = thresholdBefore
        coordinator.handleDefaultRotationThresholdChangeIfNeeded()
        try? await Task.sleep(for: .seconds(1))
        r.check("other mutation paths: gallery and orders equal full sort", pathMismatches.isEmpty,
                pathMismatches.prefix(8).joined(separator: "; "))
        // The main-thread price of repairing every order for one edit, on its own: the
        // metadata write for a film whose title moved, with orders current.
        await cache.buildLibraryOrdersForTesting()
        var repairs: [Double] = []
        for index in 0..<40 {
            guard var film = coordinator.getAllFilms().randomElement(using: &generator) else { break }
            film.sortName = "Repair \(index) \(film.name)"
            let start = ContinuousClock.now
            cache.updateFilm(film)
            repairs.append(milliseconds(ContinuousClock.now - start))
            // Written straight to the cache, so put the store's own entry back.
            if let original = coordinator.getFilm(film.id) { cache.updateFilm(original) }
            if cache.libraryOrderForTesting(.init(.title)) == nil { break }
        }
        r.metric("order-repair-per-edit-median", stats(repairs).median, "ms")
        r.metric("order-repair-per-edit-max", stats(repairs).max, "ms")
        r.metric("edit-refresh-median-orders", stats(refreshOrders).median, "ms")
        r.metric("edit-refresh-median-legacy", stats(refreshLegacy).median, "ms")

        cache.usesLibraryOrders = ordersBefore
        ViewStateManager.shared.forceReload()
        return r
    }
}

extension DebugHarness {
    /// Compares every current shared library order with a fresh full sort of the shared
    /// metadata. Run after every harness scenario (see DebugHarness.run), which makes the
    /// whole suite — imports, restores, rollbacks, deletions — a test of order upkeep.
    static func auditSharedLibraryOrders() -> (current: Int, mismatches: [String]) {
        let cache = MetadataCache.shared
        let all = Array(cache.metadata.keys)
        var current = 0
        var mismatches: [String] = []
        for key in allOrderKeys {
            guard let order = cache.libraryOrderForTesting(key) else { continue }
            current += 1
            if order != MetadataCache.referenceSort(all, by: key.option, direction: .ascending,
                                                    purchaseFormat: key.purchaseFormat, using: cache.metadata) {
                mismatches.append("\(key.option)/\(key.purchaseFormat?.rawValue ?? "-") order ≠ full sort")
            }
        }
        return (current, mismatches)
    }
}

private extension FilmSnapshot {
    /// The same snapshot under another film ID.
    init(copying other: FilmSnapshot, id: UUID) {
        let data = try! JSONEncoder().encode(other)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["id"] = id.uuidString
        self = try! JSONDecoder().decode(FilmSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

#endif
