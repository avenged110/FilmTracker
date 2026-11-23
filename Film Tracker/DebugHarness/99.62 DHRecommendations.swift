// MARK: - DHRecommendations.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only scenario `recommendations`: runs the Recommendations experiment's engine
/// (29.51 RecommendationEngine.swift) against the sandbox library under several tunings, checks
/// the rules it promises to keep, and writes every pick with its reasons to
/// `harness-reports/recommendations.txt` for reading. Not in any suite; run by name. It calls
/// the engine directly, so it runs whatever `Preferences.recommendationsExperiment` says.
///
///   • rules/*        — no pick carries Special Sorting, is rated below the floor, was watched
///                      inside its rotation threshold, or sits in Up Next; focus and length hold.
///   • picks/*        — no film appears twice; the requested count is met when films allow.
///   • seed/*         — one seed gives the same picks; Shuffle replaces at least half of them.
///   • feedback/*     — Never Recommend and Not Now remove a film; Less Like This on a steered
///                      pick lowers the match of the films that share the steer.
///   • steer/*        — steering toward a feature fills the picks with films that carry it.
///   • analysis/*     — a reused analysis, or a relabeled library, gives a fresh pass's results.
///   • decoding/*     — stored state from another build falls back field by field.

#if DEBUG
import Foundation

extension DebugHarness {
    static func recommendationsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "recommendations")
        let films = coordinator.getAllFilms()
        guard !films.isEmpty else {
            r.check("library", false, "the sandbox library is empty")
            return r
        }
        let byID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var queue: [UUID: FilmQueueSection] = [:]
        for section in FilmQueueSection.allCases.sorted(by: { $0.queueOrder > $1.queueOrder }) {
            for filmID in coordinator.getList(section.listID)?.filmIDs ?? [] { queue[filmID] = section }
        }
        var lists: [UUID: [String]] = [:]
        for list in coordinator.getAllLists() where !FilmQueue.isInternalList(list.listID) {
            for filmID in list.filmIDs { lists[filmID, default: []].append(list.listName) }
        }
        let now = Date()
        func input(_ tuning: RecTuning = RecTuning(), feedback: RecFeedback = RecFeedback(),
                   seed: UInt64 = 42, shuffledAway: Set<UUID> = []) -> RecInput {
            RecInput(films: films, queue: queue, userLists: lists, tuning: tuning, feedback: feedback,
                     keepInUpNext: [], shuffledAway: shuffledAway, today: now, seed: seed)
        }
        func run(_ input: RecInput) async -> RecResult {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: RecommendationEngine.run(input))
                }
            }
        }
        func mainIDs(_ result: RecResult) -> [UUID] { (result.hero.map { [$0.id] } ?? []) + result.picks.map(\.id) }

        var text = "Recommendations engine — \(films.count) films, \(ISO8601DateFormatter().string(from: now))\n"

        /// Rules every pick of `result` must keep under `tuning`.
        func checkRules(_ label: String, _ result: RecResult, _ tuning: RecTuning) {
            let ids = result.allPickIDs
            let today = AppCalendar.current.startOfDay(for: now)
            var broken: [String] = []
            for id in ids {
                guard let film = byID[id] else { broken.append("unknown film \(id)"); continue }
                if !film.specialSorting.isEmpty { broken.append("\(film.name): special sorting \(film.specialSorting)") }
                if film.userRating > 0, film.userRating < tuning.minimumRating {
                    broken.append("\(film.name): rated \(film.userRating)")
                }
                if film.watched,
                   let last = ([parseDate(from: film.lastWatched)] + film.calendarTable.map { parseDate(from: $0) })
                       .compactMap({ $0 }).max(),
                   let eligible = rotationEligibilityDate(from: last, months: film.rotationThreshold),
                   eligible > today {
                    broken.append("\(film.name): watched \(film.lastWatched), inside rotation")
                }
                if queue[id] == .upNext, !tuning.includeUpNext { broken.append("\(film.name): in Up Next") }
                if tuning.focus == .discover, film.watched { broken.append("\(film.name): watched in Discover") }
                if tuning.focus == .revisit, !film.watched { broken.append("\(film.name): unwatched in Revisit") }
                if !tuning.length.admits(DurationHelpers.storedMinutes(film.effectiveDuration).flatMap { $0 > 0 ? $0 : nil }) {
                    broken.append("\(film.name): outside length \(tuning.length.title)")
                }
            }
            r.check("rules/\(label)", broken.isEmpty, broken.isEmpty ? "\(ids.count) picks keep every rule"
                                                                    : broken.prefix(8).joined(separator: "; "))
            let main = mainIDs(result) + result.wildcards.map(\.id)
            r.check("picks/\(label)/unique", Set(main).count == main.count, "\(main.count) main + wildcard picks")
            let expected = min(tuning.pickCount, result.stats.eligibleCount)
            r.check("picks/\(label)/count", main.count == expected,
                    "\(main.count) picks, \(expected) expected (\(result.stats.eligibleCount) eligible)")
            if let pair = result.doubleFeature {
                r.check("picks/\(label)/double-feature-distinct",
                        !main.contains(pair.first.id) && !main.contains(pair.second.id) && pair.first.id != pair.second.id,
                        "\(pair.first.name) + \(pair.second.name)")
            }
        }

        func dump(_ label: String, _ result: RecResult) {
            text += "\n══════ \(label) — \(result.milliseconds) ms, \(result.stats.eligibleCount) eligible ══════\n"
            func line(_ pick: RecPick, _ prefix: String) {
                let film = byID[pick.id]
                let watched = film?.watched == true ? "watched \(film?.lastWatched ?? "")" : "unwatched"
                text += "\(prefix) \(pick.name) (\(pick.year)) — \(pick.lane.title), \(pick.match)% match, score \(Fmt.fixed(pick.score, 2)), ★\(pick.userRating), \(watched)\n"
                for reason in pick.reasons { text += "      · \(reason.text)\n" }
            }
            if let hero = result.hero { line(hero, "HERO") }
            for pick in result.picks { line(pick, "  •") }
            for pick in result.wildcards { line(pick, "  ?") }
            if let pair = result.doubleFeature {
                text += "  ⧉ Double feature: \(pair.first.name) + \(pair.second.name) — \(pair.link)\n"
            }
        }

        // Default tuning, with the profile and statistics.
        let base = await run(input())
        r.metric("default-ms", Double(base.milliseconds), "ms")
        r.metric("eligible", Double(base.stats.eligibleCount), "films")
        checkRules("default", base, RecTuning())
        dump("Default (Balanced)", base)
        text += "\n── Stats ──\nrated \(base.stats.ratedCount), labeled \(base.stats.labeledCount), viewings \(base.stats.viewingCount), mean rating \(Fmt.fixed(base.stats.meanRating, 2)), HoF \(base.stats.hallOfFameCount)\n"
        if let streak = base.stats.streak { text += "streak: \(streak)\n" }
        for exclusion in base.stats.exclusions { text += "held back: \(exclusion.label) — \(exclusion.count)\n" }
        text += "\n── Profile ──\n"
        for group in base.profile.groups {
            text += "\(group.facet.title): " + group.entries.map {
                "\($0.name) \(Fmt.fixed($0.affinity, 2)) (n\($0.count)\($0.averageRating.map { ", ★" + Fmt.fixed($0, 1) } ?? ""))"
            }.joined(separator: " | ") + "\n"
        }
        text += "Not your thing: " + base.profile.dislikes.map { "\($0.name) \(Fmt.fixed($0.affinity, 2))" }.joined(separator: " | ") + "\n"
        let lanes = Dictionary(grouping: mainIDs(base).compactMap { id in ([base.hero].compactMap { $0 } + base.picks).first { $0.id == id }?.lane }, by: { $0 })
        text += "lanes: " + lanes.map { "\($0.key.title) \($0.value.count)" }.sorted().joined(separator: ", ") + "\n"
        let watchedShare = mainIDs(base).filter { byID[$0]?.watched == true }.count
        text += "watched among main picks: \(watchedShare) of \(mainIDs(base).count)\n"

        // Determinism and shuffle.
        let again = await run(input())
        r.check("seed/stable", mainIDs(again) == mainIDs(base), "same seed, same picks")
        /// The store's film order changes between launches; the picks, scores and reasons must not.
        let reversed = await run(RecInput(films: films.reversed(), queue: queue, userLists: lists, tuning: RecTuning(),
                                          feedback: RecFeedback(), keepInUpNext: [], today: now, seed: 42))
        func signature(_ result: RecResult) -> [String] {
            ([result.hero].compactMap { $0 } + result.picks + result.wildcards).map {
                "\($0.id)|\($0.score)|\($0.match)|\($0.reasons.map(\.text))"
            } + result.profile.groups.flatMap { $0.entries.map(\.name) }
        }
        let same = signature(reversed) == signature(base)
        r.check("seed/order-independent", same,
                same ? "reversed film order gives identical picks, scores and reasons"
                     : "differs: \(Set(signature(reversed)).symmetricDifference(signature(base)).prefix(3))")
        /// A pass reusing the previous pass's library analysis (as a tuning change does in the
        /// view) gives exactly the same picks, and only rescores.
        var reusing = input()
        reusing.previous = base.analysis
        let reused = await run(reusing)
        /// The Rate tab's catalog in both orders, with every figure a row shows.
        func catalogSignature(_ result: RecResult) -> [RecFeature.Facet: [String]] {
            RecommendationEngine.catalog(for: result.analysis).mapValues { group in
                (group.byFilms + group.byName).map {
                    "\($0.id)|\($0.filmCount)|\($0.ratedCount)|\($0.labeled)|\(String(describing: $0.inferred))"
                }
            }
        }
        let catalogStarted = Date()
        let baseCatalog = catalogSignature(base)
        let catalogMilliseconds = Int(Date().timeIntervalSince(catalogStarted) * 1000)
        let reuseSame = signature(reused) == signature(base) && catalogSignature(reused) == baseCatalog
        r.check("analysis/reuse", reuseSame,
                "\(reuseSame ? "identical picks, scores, reasons and catalog" : "differs") — full pass \(base.milliseconds) ms, reusing \(reused.milliseconds) ms, catalog after the picks \(catalogMilliseconds) ms")
        /// A More Like This (a liked film changes) keeps the library and only relabels it: the same
        /// picks and catalog as a pass that works everything out afresh with that like.
        if let liked = mainIDs(base).last {
            var feedback = RecFeedback()
            feedback.liked[liked] = now
            var relabeling = input(feedback: feedback)
            relabeling.previous = base.analysis
            let relabeled = await run(relabeling)
            let fresh = await run(input(feedback: feedback))
            let relabelSame = signature(relabeled) == signature(fresh)
                && catalogSignature(relabeled) == catalogSignature(fresh)
            r.check("analysis/relabel", relabelSame,
                    "\(relabelSame ? "identical picks, scores, reasons and catalog figures" : "differs") — fresh pass \(fresh.milliseconds) ms, keeping the library \(relabeled.milliseconds) ms")
        }
        /// Shuffle as the model does it: a new seed, with everything shown pushed down.
        let shuffled = await run(input(seed: 43, shuffledAway: Set(base.allPickIDs)))
        let overlap = Set(mainIDs(shuffled)).intersection(mainIDs(base)).count
        r.check("seed/shuffle-changes", overlap * 2 <= mainIDs(base).count,
                "\(overlap) of \(mainIDs(base).count) picks kept after a shuffle")
        dump("Shuffled (seed 43)", shuffled)

        // Focus, length and adventurousness.
        for (label, change) in [
            ("discover", { (t: inout RecTuning) in t.focus = .discover }),
            ("revisit", { (t: inout RecTuning) in t.focus = .revisit }),
            ("under90", { (t: inout RecTuning) in t.length = .under90 }),
            ("adventurous", { (t: inout RecTuning) in t.adventurousness = 1; t.pickCount = 16 }),
            ("strict-rating", { (t: inout RecTuning) in t.minimumRating = 9; t.includeUpNext = true }),
        ] as [(String, (inout RecTuning) -> Void)] {
            var tuning = RecTuning()
            change(&tuning)
            let result = await run(input(tuning))
            checkRules(label, result, tuning)
            dump(label.capitalized, result)
        }

        // Feedback.
        if let hero = base.hero {
            var feedback = RecFeedback()
            feedback.dismissed[hero.id] = now
            let dismissed = await run(input(feedback: feedback))
            r.check("feedback/never", !dismissed.allPickIDs.contains(hero.id), "\(hero.name) dismissed")
            feedback = RecFeedback()
            feedback.snoozedUntil[hero.id] = now.addingTimeInterval(86_400 * 30)
            let snoozed = await run(input(feedback: feedback))
            r.check("feedback/not-now", !snoozed.allPickIDs.contains(hero.id), "\(hero.name) snoozed")
        }

        // Steering toward the most common steer option.
        if let option = base.steerGroups.first(where: { $0.facet == .director })?.options.first
            ?? base.steerGroups.first?.options.first {
            var tuning = RecTuning()
            tuning.steer = [option]
            let steered = await run(input(tuning))
            let carrying = mainIDs(steered).filter { id in
                guard let film = byID[id] else { return false }
                let values: [String]
                switch option.feature.facet {
                case .director: values = film.directors
                case .cast: values = Array(film.cast.prefix(6))
                case .writer: values = Array(film.screenwriters.prefix(4))
                case .genre: values = [film.genre]
                case .tag: values = film.tags
                case .decade: values = [Int(film.releaseYear.prefix(4)).map { "\($0 / 10 * 10)s" } ?? ""]
                default: values = []
                }
                return values.contains { RecFeature.fold($0) == option.feature.key }
            }
            let carryingCount = carrying.count
            let available = option.feature.facet == .decade ? mainIDs(steered).count : min(mainIDs(steered).count, 3)
            r.check("steer/\(option.name)", carryingCount >= min(available, 3),
                    "\(carryingCount) of \(mainIDs(steered).count) picks carry \(option.name)")
            dump("Steered toward \(option.name)", steered)

            /// Less Like This on the steered featured pick: the other films that carry the steer
            /// should fit the learned taste less well than they did.
            if let hero = steered.hero, carrying.count > 1 {
                var feedback = RecFeedback()
                feedback.disliked[hero.id] = now
                feedback.snoozedUntil[hero.id] = now.addingTimeInterval(86_400 * 90)
                let after = await run(input(tuning, feedback: feedback))
                let beforeMatch = Dictionary((steered.picks + steered.wildcards).map { ($0.id, $0.match) },
                                             uniquingKeysWith: { first, _ in first })
                let afterMatch = Dictionary(([after.hero].compactMap { $0 } + after.picks + after.wildcards).map { ($0.id, $0.match) },
                                            uniquingKeysWith: { first, _ in first })
                let shared = carrying.filter { $0 != hero.id && beforeMatch[$0] != nil && afterMatch[$0] != nil }
                let drop = shared.reduce(0) { $0 + (beforeMatch[$1] ?? 0) - (afterMatch[$1] ?? 0) }
                r.check("feedback/less-like-this", !shared.isEmpty && drop > 0 && !after.allPickIDs.contains(hero.id),
                        "\(shared.count) films carrying \(option.name): match fell by \(drop) points in all after Less Like This on \(hero.name)")
                dump("After Less Like This on \(hero.name)", after)
            }
        }

        // The Rate tab: liking an actor the films give little or no credit
        // raises the match of the films that carry them.
        /// The first actor with a weak or negative inferred affinity (lowest first) whose films reach the
        /// steered picks. An actor the films say the user dislikes usually has no eligible film (those
        /// films are rated below the minimum), and one whose films are all held back cannot move any
        /// shown match.
        let actors = (RecommendationEngine.catalog(for: base.analysis)[.cast]?.byFilms ?? [])
            .filter { $0.filmCount >= 3 && ($0.inferred ?? 1) < 0.15 }
            .sorted { ($0.inferred ?? 0, $0.name) < ($1.inferred ?? 0, $1.name) }
        func matches(_ result: RecResult) -> [UUID: Int] {
            Dictionary(([result.hero].compactMap { $0 } + result.picks + result.wildcards).map { ($0.id, $0.match) },
                       uniquingKeysWith: { first, _ in first })
        }
        var tested: (actor: RecCatalogEntry, before: RecResult)?
        for actor in actors.prefix(40) {
            var tuning = RecTuning()
            tuning.steer = [RecSteer(feature: actor.feature, name: actor.name)]
            let before = await run(input(tuning))
            if !Set(actor.filmIDs).isDisjoint(with: matches(before).keys) { tested = (actor, before); break }
        }
        if let (actor, before) = tested {
            var tuning = RecTuning()
            tuning.steer = [RecSteer(feature: actor.feature, name: actor.name)]
            var feedback = RecFeedback()
            feedback.featureLeans[actor.feature.storageKey] = 1
            let after = await run(input(tuning, feedback: feedback))
            let old = matches(before), new = matches(after)
            let shared = Set(actor.filmIDs).filter { old[$0] != nil && new[$0] != nil }
            let rise = shared.reduce(0) { $0 + (new[$1] ?? 0) - (old[$1] ?? 0) }
            r.check("rating/raises-match", !shared.isEmpty && rise > 0,
                    "\(actor.name) (inferred \(Fmt.fixed(actor.inferred ?? 0, 2)) over \(actor.filmCount) films) liked: match rose by \(rise) points over \(shared.count) of their films")
            r.check("rating/storage-key", RecFeature(storageKey: actor.feature.storageKey) == actor.feature,
                    actor.feature.storageKey)
            dump("After liking \(actor.name)", after)
        } else {
            r.check("rating/raises-match", false, "no actor in 3+ films with a weak inferred affinity has films among the picks")
        }

        // Stored state from another build: out-of-range, unknown and missing fields fall back
        // field by field instead of discarding everything.
        let tuningJSON = #"{"pickCount": 99, "focus": "bogus", "variety": "x", "weights": {"taste": 5, "shelf": 0.25}, "futureField": 1}"#
        if let tuning = try? JSONDecoder().decode(RecTuning.self, from: Data(tuningJSON.utf8)) {
            r.check("decoding/tuning", tuning.pickCount == 24 && tuning.focus == .balanced && tuning.variety == RecTuning().variety
                        && tuning.weights.taste == 2 && tuning.weights.shelf == 0.25 && tuning.weights.rewatch == RecTuning.Weights().rewatch,
                    "pickCount \(tuning.pickCount), focus \(tuning.focus), taste \(tuning.weights.taste), shelf \(tuning.weights.shelf)")
        } else {
            r.check("decoding/tuning", false, "decode threw")
        }
        var taught = RecFeedback()
        taught.dismissed[films[0].id] = now
        if let encoded = try? JSONEncoder().encode(taught),
           var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            object["liked"] = "not a dictionary"
            object["featureLeans"] = ["director:a": 3, "director:b": -1]
            object["futureField"] = [1, 2]
            let mangled = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let decoded = try? JSONDecoder().decode(RecFeedback.self, from: mangled)
            r.check("decoding/feedback", decoded?.dismissed[films[0].id] != nil && decoded?.liked.isEmpty == true
                        && decoded?.featureLeans == ["director:b": -1],
                    "a broken field is dropped; Never Recommend survives; an out-of-range lean is dropped")
            /// A store from before the three-way lean: its 1…10 ratings carry over.
            object.removeValue(forKey: "featureLeans")
            object["featureRatings"] = ["director:a": 9, "director:b": 5, "director:c": 2]
            let legacy = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let migrated = try? JSONDecoder().decode(RecFeedback.self, from: legacy)
            r.check("decoding/legacy-ratings", migrated?.featureLeans == ["director:a": 1, "director:c": -1],
                    "9 → like, 5 → no lean, 2 → dislike: \(migrated?.featureLeans ?? [:])")
        } else {
            r.check("decoding/feedback", false, "could not build the test payload")
        }

        // A film's own time of year: watched around July 4 in three of four years.
        do {
            let calendar = AppCalendar.current
            func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
                calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? now
            }
            let viewings = [day(2020, 7, 4), day(2021, 11, 20), day(2022, 7, 3), day(2023, 7, 6)]
            func habit(on date: Date) -> (years: Int, ofYears: Int, share: Double, closeness: Double)? {
                RecommendationEngine.seasonalHabit(viewings, calendar: calendar,
                                                   todayOrdinal: calendar.ordinality(of: .day, in: .year, for: date) ?? 1,
                                                   currentYear: 2026)
            }
            let july = habit(on: day(2026, 7, 2)), november = habit(on: day(2026, 11, 20))
            r.check("timing/seasonal-habit", july?.years == 3 && july?.ofYears == 4 && november == nil,
                    "early July: \(july.map { "\($0.years) of \($0.ofYears), closeness \(Fmt.fixed($0.closeness, 2))" } ?? "none"); late November: \(november == nil ? "none" : "habit")")
        }

        if let root = DebugSandbox.rootURL {
            let reports = root.appendingPathComponent("harness-reports", isDirectory: true)
            try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let url = reports.appendingPathComponent("recommendations.txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                r.check("dump", true, url.path)
            } catch {
                r.check("dump", false, error.localizedDescription)
            }
        }
        return r
    }
}
#endif
