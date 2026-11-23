// MARK: - RecommendationsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// EXPERIMENT, behind `Preferences.recommendationsExperiment`. The Recommendations view: a
/// featured pick, a grid of picks, a few wildcards and a double feature, each with the reasons it
/// was chosen (29.51 RecommendationEngine.swift), plus the controls to steer and shuffle them.
/// The grid is the gallery's own (29.52 RecommendationsGrid.swift); rating, tuning and the
/// engine's findings live in the Recommendations sheet (29.53 RecommendationsSheet.swift).
///
/// Gated by `Preferences.recommendationsEnabled` (the experiment flag and the Settings checkbox).
/// While it is off nothing here runs and the model is never created. With it on, the model is
/// created at the end of launch (FilmTrackerApp, `prewarm`, overlapping the background launch work), or shortly after the checkbox is
/// turned on (`preferenceChanged`), and it alone reads and writes the experiment's stored state
/// (`RecommendationsModel.storageKey`). Turning the checkbox off cancels its work and drops its results.
///
/// Selecting a pick selects the film app-wide, so the RightSidebar shows it, and a secondary click
/// opens the gallery's contextual menu with the view's own feedback items appended.

import AppKit
import Combine
import SwiftUI

// MARK: - Glyph

extension ViewGlyphs {
    /// The Recommendations view: its sidebar row, its Left Sidebar menu item and its title bar.
    static let recommendations = Glyph.uniform("wand.and.sparkles.inverse")
}

// MARK: - Model

@MainActor
@Observable
final class RecommendationsModel: Loggable {
    nonisolated static let logTag = "[Recommendations]"

    /// Created on first use, so a gate that was never on never builds it (`preferenceChanged`).
    private static var instance: RecommendationsModel?
    static var shared: RecommendationsModel {
        if let instance { return instance }
        let model = RecommendationsModel()
        instance = model
        return model
    }

    /// The Settings checkbox changed. On: after a short debounce (a quick on-off-on is one pass), a
    /// low-priority pass brings the picks up to date. Off: in-flight and queued work is canceled
    /// and the results are dropped; stored state (tuning, feedback) is kept for the next time.
    static func preferenceChanged() {
        if Preferences.recommendationsEnabled {
            shared.refresh(after: .milliseconds(300), priority: .utility)
        } else {
            /// Leave the view first (as hiding Smart Lists does): suspend drops the results it
            /// shows. Done here, not in a sidebar observer, so it holds however the sidebar is shown.
            if let appState = AppDelegate.appState,
               appState.selectedSidebarItem == .libraryItem(.recommendations) {
                appState.navigate(to: .libraryItem(.allFilms))
            }
            instance?.suspend()
        }
    }

    /// The experiment's whole stored state, in the app's preferences store (a debug sandbox's own
    /// suite in a sandbox run). Not a setting: Settings, backups and SettingsManager never see it.
    private static let storageKey = "experiment.recommendations.v1"

    private(set) var result: RecResult?
    /// The Rate tab's catalog for the result's analysis (RecommendationEngine.catalog), worked out
    /// in the background after the picks are shown. The previous one stays until it is replaced.
    private(set) var catalog: [RecFeature.Facet: RecCatalogGroup]?
    private(set) var tuning: RecTuning
    private(set) var feedback: RecFeedback

    /// Shuffle's counter, reset each day so a new day brings new picks without a click.
    @ObservationIgnored private var shuffleNonce: Int
    @ObservationIgnored private var shuffleDay: Int
    /// Today's picks that Shuffle moved past (RecInput.shuffledAway); cleared each new day.
    @ObservationIgnored private var shuffledAway: Set<UUID>
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Films queued for Up Next from this view since launch (RecInput.keepInUpNext).
    @ObservationIgnored private var queuedHere: Set<UUID> = []
    /// The last pass's analysis: a pass that changes only the tuning, steering, leans or the day
    /// reuses it and only rescores; a More or Less Like This reuses its library (RecInput.previous).
    @ObservationIgnored private var lastAnalysis: RecAnalysis?
    /// The view is on screen. Picks count as shown (impressions) only while it is, so a pass
    /// run ahead of time, at launch, marks nothing.
    @ObservationIgnored private var isShown = false
    /// The picks for every other Length and Focus choice, worked out in the background after each
    /// pass (`precomputeSpeculation`), so choosing one shows its picks at once (`updateTuning`).
    /// Valid until anything else changes: every `refresh` clears them.
    @ObservationIgnored private var alternates: [(tuning: RecTuning, result: RecResult)] = []
    /// Alternates being worked out now, so a second request does not start them again.
    @ObservationIgnored private var alternatesInFlight: [RecTuning] = []
    /// Generate New Picks worked out in advance for the result on screen (`shuffle`).
    @ObservationIgnored private var nextShuffle: RecResult?
    /// Moves on whenever the speculative results above stop being valid; a background pass that
    /// finishes after that is dropped.
    @ObservationIgnored private var speculation = 0
    /// Moves on with every result applied: the precomputed shuffle belongs to one result.
    @ObservationIgnored private var shuffleBasis = 0
    /// The analysis the catalog belongs to (held, so its identity cannot be reused) and its task.
    @ObservationIgnored private var catalogAnalysis: RecAnalysis?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    /// Library, list, rotation-threshold and day changes seen; `resultBasis` says how many of
    /// them the result on screen includes (`isOutOfDate`).
    @ObservationIgnored private var changes = 0
    /// The default rotation threshold as of the last settings event: the one setting that changes
    /// what can be picked, so only a move in it counts as a change.
    @ObservationIgnored private var knownRotationThreshold = Preferences.defaultRotationThreshold
    @ObservationIgnored private var resultBasis: Basis?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

    /// What the result on screen was worked out from, as far as `isOutOfDate` needs to know.
    private struct Basis {
        /// `changes` when its input was taken.
        let changes: Int
        let taken: Date
        /// DataCoordinator.filmsVersion then: a safety net for a film write that posts no event.
        let filmsVersion: UInt64
        /// The first snooze still running then: when it ends its film is due back.
        let snoozeEnd: Date?
    }

    private struct Stored: Codable {
        var tuning = RecTuning()
        var feedback = RecFeedback()
        var shuffleDay = 0
        var shuffleNonce = 0
        var shuffledAway: Set<UUID> = []

        init(tuning: RecTuning = RecTuning(), feedback: RecFeedback = RecFeedback(), shuffleDay: Int = 0,
             shuffleNonce: Int = 0, shuffledAway: Set<UUID> = []) {
            self.tuning = tuning
            self.feedback = feedback
            self.shuffleDay = shuffleDay
            self.shuffleNonce = shuffleNonce
            self.shuffledAway = shuffledAway
        }

        /// Field by field (see RecTuning's tolerant decoding): one unreadable part never costs the rest.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tuning = (try? c.decodeIfPresent(RecTuning.self, forKey: .tuning)) ?? RecTuning()
            feedback = (try? c.decodeIfPresent(RecFeedback.self, forKey: .feedback)) ?? RecFeedback()
            shuffleDay = (try? c.decodeIfPresent(Int.self, forKey: .shuffleDay)) ?? 0
            shuffleNonce = (try? c.decodeIfPresent(Int.self, forKey: .shuffleNonce)) ?? 0
            shuffledAway = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .shuffledAway)) ?? []
        }
    }

    private init() {
        var stored = Stored()
        if let data = Preferences.store.data(forKey: Self.storageKey) {
            do { stored = try JSONDecoder().decode(Stored.self, from: data) }
            catch { Self.log("Stored state unreadable, starting fresh: \(error.localizedDescription)") }
        }
        tuning = stored.tuning
        feedback = stored.feedback
        shuffleDay = stored.shuffleDay
        shuffleNonce = stored.shuffleNonce
        shuffledAway = stored.shuffledAway
        subscribe()
    }

    /// Listened to here, not in the view, so the picks stay current while the view is away and are
    /// ready when it opens. Every event passes through `libraryChanged`, which waits for a burst to end.
    private func subscribe() {
        AppEventBus.shared.filmEvents
            .sink { [weak self] _ in self?.libraryChanged() }
            .store(in: &subscriptions)
        AppEventBus.shared.listEvents
            .filter { event in
                switch event {
                case .membershipChanged, .updated, .deleted: return true
                case .created, .operationStarted, .operationCompleted, .queueAdditionCompleted: return false
                }
            }
            .sink { [weak self] _ in self?.libraryChanged() }
            .store(in: &subscriptions)
        CurrentDay.shared.dayChanged
            .sink { [weak self] _ in self?.libraryChanged(immediately: true) }
            .store(in: &subscriptions)
        /// The default rotation threshold changes what is eligible with no film event (read live by
        /// FilmSnapshot.rotationThreshold); no other setting reaches the engine. Settings events
        /// are posted for every setting, so only a real move in the threshold counts, and it is
        /// handled as a library change: away, a background pass once the stepper goes quiet.
        AppEventBus.shared.viewEvents
            .filter { $0 == .preferencesChanged }
            .sink { [weak self] _ in
                guard let self else { return }
                let threshold = Preferences.defaultRotationThreshold
                guard threshold != self.knownRotationThreshold else { return }
                self.knownRotationThreshold = threshold
                self.libraryChanged()
            }
            .store(in: &subscriptions)
    }

    /// A film, a list, or the day changed. On screen: a pass shortly, as before. Away: a low-priority
    /// pass once a burst of edits (a bulk edit, an import) has been quiet for two seconds.
    private func libraryChanged(immediately: Bool = false) {
        guard Preferences.recommendationsEnabled else { return }
        changes += 1
        if isShown {
            refresh(after: immediately ? .zero : .milliseconds(350))
        } else {
            refresh(after: immediately ? .zero : .seconds(2), priority: .utility)
        }
    }

    /// Coalesces a slider drag's stream of tuning changes into one write.
    private func schedulePersist() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        pendingSave?.cancel()
        pendingSave = nil
        let stored = Stored(tuning: tuning, feedback: feedback, shuffleDay: shuffleDay,
                            shuffleNonce: shuffleNonce, shuffledAway: shuffledAway)
        do { Preferences.store.set(try JSONEncoder().encode(stored), forKey: Self.storageKey) }
        catch { log("Could not save state: \(error.localizedDescription)") }
    }

    // MARK: Refresh

    /// Recomputes off the main actor, keeping the current result on screen until the new one is
    /// ready. Bursts (a bulk edit posts one event per film) collapse into one pass.
    func refresh(after delay: Duration = .zero, priority: TaskPriority = .userInitiated) {
        guard Preferences.recommendationsEnabled else { return }
        discardSpeculation()
        pending?.cancel()
        generation += 1
        let generation = generation
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            guard Preferences.recommendationsEnabled, let input = self.makeInput() else {
                if generation == self.generation { self.pending = nil }
                return
            }
            let basis = Basis(changes: self.changes, taken: input.today,
                              filmsVersion: AppDelegate.dataCoordinator?.filmsVersion ?? 0,
                              snoozeEnd: input.feedback.snoozedUntil.values.filter { $0 > input.today }.min())
            let result = await Task.detached(priority: priority) { RecommendationEngine.run(input) }.value
            guard generation == self.generation, Preferences.recommendationsEnabled else { return }
            self.pending = nil
            self.apply(result, basis: basis)
        }
    }

    /// The alternates and the precomputed shuffle no longer match what a pass would give: drop
    /// them, and any still being worked out.
    private func discardSpeculation() {
        speculation += 1
        alternates = []
        alternatesInFlight = []
        nextShuffle = nil
    }

    /// The gate turned off. The engine has no cancellation points, so a pass already running
    /// finishes its (sub-second) work, but its result is discarded (the generation moves on);
    /// a queued pass and the alternates (a series of passes) stop at once. A pending save is
    /// written now rather than lost.
    private func suspend() {
        pending?.cancel()
        pending = nil
        discardSpeculation()
        catalogTask?.cancel()
        catalogTask = nil
        catalogAnalysis = nil
        catalog = nil
        generation += 1
        if pendingSave != nil { persist() }
        result = nil
        resultBasis = nil
        lastAnalysis = nil
        isShown = false
        log("Disabled: work canceled, results dropped")
    }

    private func makeInput() -> RecInput? {
        guard let coordinator = AppDelegate.dataCoordinator else { return nil }
        let now = Date()
        let day = Self.day(of: now)
        if day != shuffleDay {
            shuffleDay = day
            shuffleNonce = 0
            shuffledAway = []
        }

        /// Each film's canonical section: the lowest queue order wins, as filmQueueSection(forFilm:) rules.
        var queue: [UUID: FilmQueueSection] = [:]
        for section in FilmQueueSection.allCases.sorted(by: { $0.queueOrder > $1.queueOrder }) {
            for filmID in coordinator.getList(section.listID)?.filmIDs ?? [] { queue[filmID] = section }
        }
        var lists: [UUID: [String]] = [:]
        for list in coordinator.getAllLists() where !FilmQueue.isInternalList(list.listID) {
            for filmID in list.filmIDs { lists[filmID, default: []].append(list.listName) }
        }
        return RecInput(films: coordinator.getAllFilms(), queue: queue, userLists: lists,
                        tuning: tuning, feedback: feedback, keepInUpNext: queuedHere,
                        shuffledAway: shuffledAway, today: now, seed: seed(nonce: shuffleNonce),
                        previous: lastAnalysis)
    }

    /// Today's seed (`shuffleDay`) for a Shuffle count.
    private func seed(nonce: Int) -> UInt64 {
        UInt64(truncatingIfNeeded: shuffleDay) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: nonce)
    }

    private static func day(of date: Date) -> Int {
        Int(AppCalendar.current.startOfDay(for: date).timeIntervalSince1970 / 86_400)
    }

    /// Computes the picks ahead of time, at low priority, so the view has them the first time it
    /// opens. Called once after launch (FilmTrackerApp); does nothing once a pass has run or begun.
    func prewarm() {
        guard result == nil, pending == nil else { return }
        refresh(priority: .utility)
    }

    /// The view appeared: what it now shows counts as shown. The picks were kept current while it
    /// was away, so a pass runs only if they are out of date (a change still waiting out its
    /// delay, a setting, a new day, a snooze that ended); otherwise the speculative results are
    /// kept, and any not yet worked out are started.
    func viewAppeared() {
        isShown = true
        let outOfDate = isOutOfDate
        if let result { recordImpressions(of: result) }
        if outOfDate {
            refresh()
        } else {
            precomputeSpeculation()
        }
    }

    /// Whether a pass now could give other picks than the result on screen, for a reason other
    /// than the model's own changes (each of which starts a pass itself). Also guards the results
    /// worked out ahead: they share the result's inputs, so they are out of date with it.
    private var isOutOfDate: Bool {
        guard result != nil, let basis = resultBasis, basis.changes == changes,
              basis.filmsVersion == (AppDelegate.dataCoordinator?.filmsVersion ?? 0) else { return true }
        let now = Date()
        if Self.day(of: basis.taken) != Self.day(of: now) { return true }
        if let end = basis.snoozeEnd, end <= now { return true }
        return false
    }

    func viewDisappeared() { isShown = false }

    /// Shows a result, with what its input was taken from (`isOutOfDate`). A result worked out
    /// ahead shares the shown result's inputs and keeps its basis.
    private func apply(_ result: RecResult, basis: Basis?) {
        withAnimation(.easeInOut(duration: 0.25)) { self.result = result }
        lastAnalysis = result.analysis
        resultBasis = basis
        log("Computed \(result.allPickIDs.count) picks from \(result.stats.eligibleCount) eligible films in \(result.milliseconds) ms")
        recordImpressions(of: result)
        /// The precomputed shuffle pushed down the picks that were on screen, so it belongs to them.
        nextShuffle = nil
        shuffleBasis += 1
        buildCatalog(for: result.analysis)
        precomputeSpeculation()
    }

    /// The Rate tab's catalog, after the picks: the result is never held up by it. Only when the
    /// analysis changed (a tuning change shares it, and with it the catalog).
    private func buildCatalog(for analysis: RecAnalysis) {
        guard catalogAnalysis?.identity != analysis.identity else { return }
        catalogAnalysis = analysis
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) { RecommendationEngine.catalog(for: analysis) }.value
            guard !Task.isCancelled, let self, self.catalogAnalysis?.identity == analysis.identity else { return }
            self.catalog = catalog
            self.catalogTask = nil
        }
    }

    /// The current tuning with each other Length, and with each other Focus.
    private static func alternateTunings(of tuning: RecTuning) -> [RecTuning] {
        let lengths = RecTuning.Length.allCases.filter { $0 != tuning.length }.map { length -> RecTuning in
            var alternate = tuning
            alternate.length = length
            return alternate
        }
        let focuses = RecTuning.Focus.allCases.filter { $0 != tuning.focus }.map { focus -> RecTuning in
            var alternate = tuning
            alternate.focus = focus
            return alternate
        }
        return lengths + focuses
    }

    /// The passes a likely next click needs, worked out ahead at low priority, all at once (each in
    /// its own background task, so they share the cores): every alternate not already done or under
    /// way, and Generate New Picks for the result on screen. Each reuses the analysis, so each only
    /// rescores. Dropped when anything else changes (`discardSpeculation`).
    private func precomputeSpeculation() {
        guard Preferences.recommendationsEnabled, pending == nil, !isOutOfDate else { return }
        let wanted = Self.alternateTunings(of: tuning).filter { tuning in
            !alternates.contains { $0.tuning == tuning } && !alternatesInFlight.contains(tuning)
        }
        let shufflePicks = nextShuffle == nil ? result?.allPickIDs : nil
        guard !wanted.isEmpty || shufflePicks != nil, let base = makeInput() else { return }
        let speculation = speculation
        for tuning in wanted {
            alternatesInFlight.append(tuning)
            var input = base
            input.tuning = tuning
            let job = Task.detached(priority: .utility) { RecommendationEngine.run(input) }
            Task { [weak self] in
                let result = await job.value
                guard let self, speculation == self.speculation else { return }
                self.alternatesInFlight.removeAll { $0 == tuning }
                self.alternates.append((tuning, result))
            }
        }
        if let shufflePicks {
            var input = base
            input.seed = seed(nonce: shuffleNonce + 1)
            input.shuffledAway = shuffledAway.union(shufflePicks)
            let basis = shuffleBasis
            let job = Task.detached(priority: .utility) { RecommendationEngine.run(input) }
            Task { [weak self] in
                let result = await job.value
                guard let self, speculation == self.speculation, basis == self.shuffleBasis else { return }
                self.nextShuffle = result
            }
        }
    }

    /// Hits, cooldowns, impressions (at most one new day per film per day, and only while the view
    /// is shown), and pruning of old impressions, finished cooldowns, and snoozes.
    private func recordImpressions(of result: RecResult) {
        var updated = feedback
        let calendar = AppCalendar.current
        let now = Date()
        /// A watched pick starts over: no impression and no cooldown.
        for (filmID, date) in result.newHits { updated.hits[filmID] = date }
        for filmID in result.watchedSinceOffered {
            updated.impressions[filmID] = nil
            updated.cooldowns[filmID] = nil
        }
        for (filmID, cooldown) in result.newCooldowns {
            updated.cooldowns[filmID] = cooldown
            updated.impressions[filmID] = nil
        }
        /// A finished cooldown leaves no trace, so the film returns as if never offered.
        let today = calendar.startOfDay(for: now)
        updated.cooldowns = updated.cooldowns.filter { $0.value.until > today }
        for filmID in isShown ? result.allPickIDs : [] {
            if var impression = updated.impressions[filmID] {
                if !calendar.isDate(impression.lastShown, inSameDayAs: now) {
                    impression.days += 1
                    impression.lastShown = now
                    updated.impressions[filmID] = impression
                }
            } else {
                updated.impressions[filmID] = RecFeedback.Impression(firstShown: now, lastShown: now, days: 1)
            }
        }
        let cutoff = calendar.date(byAdding: .day, value: -120, to: now) ?? now
        updated.impressions = updated.impressions.filter { $0.value.lastShown >= cutoff }
        updated.snoozedUntil = updated.snoozedUntil.filter { $0.value > now }
        if updated != feedback {
            feedback = updated
            persist()
        }
    }

    // MARK: Tuning

    func updateTuning(_ change: (inout RecTuning) -> Void) {
        var updated = tuning
        change(&updated)
        guard updated != tuning else { return }
        let previous = tuning
        tuning = updated
        schedulePersist()
        /// Already worked out in the background: shown at once, with no pass. The result it
        /// replaces becomes an alternate itself, so going back is instant too.
        if pending == nil, !isOutOfDate, let index = alternates.firstIndex(where: { $0.tuning == updated }) {
            let ready = alternates.remove(at: index).result
            if let current = result { alternates.append((previous, current)) }
            generation += 1
            apply(ready, basis: resultBasis)
            return
        }
        /// A click (Length, Focus, a steer) runs at once; a slider waits for the drag to settle.
        var clickOnly = updated
        clickOnly.length = previous.length
        clickOnly.focus = previous.focus
        clickOnly.steer = previous.steer
        refresh(after: clickOnly == previous ? .zero : .milliseconds(180))
    }

    func restoreDefaultTuning() {
        let steer = tuning.steer
        updateTuning { $0 = RecTuning(); $0.steer = steer }
    }

    /// New picks: everything on screen now is pushed down for the rest of the day.
    func shuffle() {
        /// Worked out in advance (`precomputeSpeculation`) for exactly this seed and these picks,
        /// today, from the shown result's inputs.
        let ready = pending == nil && !isOutOfDate && Self.day(of: Date()) == shuffleDay ? nextShuffle : nil
        if let result { shuffledAway.formUnion(result.allPickIDs) }
        shuffleNonce += 1
        persist()
        if let ready {
            let basis = resultBasis
            discardSpeculation()
            generation += 1
            apply(ready, basis: basis)
        } else {
            refresh()
        }
    }

    func isSteering(_ steer: RecSteer) -> Bool { tuning.steer.contains { $0.feature == steer.feature } }

    func toggleSteer(_ steer: RecSteer) {
        updateTuning { tuning in
            if let index = tuning.steer.firstIndex(where: { $0.feature == steer.feature }) {
                tuning.steer.remove(at: index)
            } else {
                tuning.steer.append(steer)
            }
        }
    }

    // MARK: Queue

    func addToUpNext(_ filmID: UUID, coordinator: DataCoordinator) {
        /// The assignment toggles: for a film already in Up Next it removes. The card's button reads
        /// "In Up Next" only once the pass this add starts returns, so a second click before then
        /// (a double-click) would take the film straight back out.
        guard !FilmQueue.upNextFilmIDs(coordinator: coordinator).contains(filmID) else { return }
        queuedHere.insert(filmID)
        FilmQueueAssignment.toggle([filmID], section: .upNext, coordinator: coordinator)
    }

    // MARK: Feedback

    func moreLikeThis(_ filmID: UUID) {
        changeFeedback {
            $0.liked[filmID] = Date()
            $0.disliked[filmID] = nil
        }
    }

    /// Also snoozes the film itself: its own features are learned from, but it should leave the picks.
    func lessLikeThis(_ filmID: UUID) {
        deselect(filmID)
        changeFeedback {
            $0.disliked[filmID] = Date()
            $0.liked[filmID] = nil
            $0.snoozedUntil[filmID] = AppCalendar.current.date(byAdding: .day, value: 90, to: Date())
        }
    }

    func notNow(_ filmID: UUID) {
        deselect(filmID)
        changeFeedback { $0.snoozedUntil[filmID] = AppCalendar.current.date(byAdding: .day, value: 30, to: Date()) }
    }

    func neverRecommend(_ filmID: UUID) {
        deselect(filmID)
        changeFeedback { $0.dismissed[filmID] = Date() }
    }

    func restore(_ filmID: UUID) {
        changeFeedback {
            $0.dismissed[filmID] = nil
            $0.snoozedUntil[filmID] = nil
            $0.disliked[filmID] = nil
        }
    }

    func forget(_ filmID: UUID) {
        changeFeedback {
            $0.liked[filmID] = nil
            $0.disliked[filmID] = nil
        }
    }

    /// Clears what the user taught the view. Impressions and hits are the engine's own record and stay.
    func resetLearning() {
        changeFeedback {
            $0.liked = [:]
            $0.disliked = [:]
            $0.snoozedUntil = [:]
            $0.dismissed = [:]
        }
    }

    /// A pick leaving the view takes the selection (and so the RightSidebar) with it.
    private func deselect(_ filmID: UUID) {
        if SelectionState.shared.selectedFilmIDs == [filmID] { SelectionState.shared.clearImmediate() }
    }

    // MARK: Feature Leans

    /// 1 like, −1 dislike, 0 neutral (no lean).
    func featureLean(_ feature: RecFeature) -> Int { feedback.featureLeans[feature.storageKey] ?? 0 }

    /// 0 clears the lean. Several clicks in a row recompute once.
    func setFeatureLean(_ feature: RecFeature, _ lean: Int) {
        changeFeedback(refreshDelay: .milliseconds(300)) {
            $0.featureLeans[feature.storageKey] = lean == 1 || lean == -1 ? lean : nil
        }
    }

    func ratedCount(_ facet: RecFeature.Facet) -> Int { ratedCounts()[facet] ?? 0 }

    /// Every facet's count of likes and dislikes, in one pass over the stored leans.
    func ratedCounts() -> [RecFeature.Facet: Int] {
        var counts: [RecFeature.Facet: Int] = [:]
        for key in feedback.featureLeans.keys {
            if let facet = RecFeature(storageKey: key)?.facet { counts[facet, default: 0] += 1 }
        }
        return counts
    }

    func clearFeatureRatings(_ facet: RecFeature.Facet) {
        changeFeedback {
            $0.featureLeans = $0.featureLeans.filter { RecFeature(storageKey: $0.key)?.facet != facet }
        }
    }

    private func changeFeedback(refreshDelay: Duration = .zero, _ change: (inout RecFeedback) -> Void) {
        var updated = feedback
        change(&updated)
        guard updated != feedback else { return }
        feedback = updated
        persist()
        refresh(after: refreshDelay)
    }

    // MARK: Menu Items

    /// The view's own items, appended to the gallery contextual menu.
    func menuItems(for filmID: UUID) -> [NSMenuItem] {
        let header = NSMenuItem.sectionHeader(title: "Recommendations")
        let liked = feedback.liked[filmID] != nil
        return [
            .separator(), header,
            RecMenuAction.item(liked ? "Forget “More Like This”" : "More Like This") { [weak self] in
                liked ? self?.forget(filmID) : self?.moreLikeThis(filmID)
            },
            RecMenuAction.item("Less Like This") { [weak self] in self?.lessLikeThis(filmID) },
            RecMenuAction.item("Not Now (30 Days)") { [weak self] in self?.notNow(filmID) },
            RecMenuAction.item("Never Recommend") { [weak self] in self?.neverRecommend(filmID) },
        ]
    }
}

/// An NSMenuItem target running a closure, retained through `representedObject`, as the
/// gallery menu's own GalleryMenuAction is (that one is private to 23.80 GalleryMenu.swift).
/// AppKit sends menu actions on the main thread.
@MainActor
private final class RecMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    private init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc private func fire(_ sender: Any?) {
        let handler = self.handler
        deferPastMenuDismissal { handler() }
    }

    static func item(_ title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = RecMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

// MARK: - View

struct RecommendationsView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    private var model = RecommendationsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            GenericTitleBar(
                glyph: ViewGlyphs.recommendations.filled,
                leadingContent: {
                    SubcategoryPicker(
                        label: "Focus",
                        style: .segmented,
                        options: RecTuning.Focus.allCases,
                        selection: model.tuning.focus,
                        title: \.title,
                        onSelect: { focus in model.updateTuning { $0.focus = focus } })
                    .frame(width: GalleryTitleBar.pickerWidth)
                    .padding(.leading, GalleryTitleBar.pickerLeading)
                    .help("Balanced mixes new films and rewatches; Discover offers only unwatched films; Revisit only watched ones")
                },
                trailingButtons: { RecTitleBarButtons(model: model) })

            if !model.tuning.steer.isEmpty {
                RecSteeringBar(model: model)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            /// As Imports does (ImportsState.selectCategory): the active view is this one, so nothing
            /// judges a FilmSheet save against the gallery view the user came from.
            ViewStateManager.shared.switchToViewSync(.recommendations)
            model.viewAppeared()
        }
        /// Film, list and day changes reach the model itself (RecommendationsModel.subscribe).
        .onDisappear { model.viewDisappeared() }
    }

    @ViewBuilder
    private var content: some View {
        if dataCoordinator.totalFilmCount == 0 {
            StandardPlaceholder(glyph: ViewGlyphs.recommendations.outline,
                                title: "No Films",
                                message: "Add films to your library, and rate a few, to get recommendations.")
        } else if let result = model.result {
            if result.hero != nil {
                RecGridView(content: RecGridContent(result: result, liked: Set(model.feedback.liked.keys)),
                            selectedIDs: selectionState.selectedFilmIDs,
                            model: model,
                            dataCoordinator: dataCoordinator)
            } else {
                StandardPlaceholder(
                    glyph: ViewGlyphs.recommendations.outline,
                    title: "Nothing to Recommend",
                    message: "Every film is held back by the current focus, length, or steering, or by your library’s own rules.",
                    actionTitle: "Clear Focus, Length, and Steering",
                    action: {
                        model.updateTuning {
                            $0.focus = .balanced
                            $0.length = .any
                            $0.steer = []
                        }
                    })
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - Title Bar Buttons

/// Laid out as GalleryTitleBar.buttonSection is: the same row spacing, trailing inset and per-button
/// frame chains (see the sizing note there), with the Length pop-up leading the row.
private struct RecTitleBarButtons: View {
    var model: RecommendationsModel

    var body: some View {
        HStack(spacing: 8) {
            SubcategoryPicker(
                label: "Length",
                style: .menu,
                options: RecTuning.Length.allCases,
                selection: model.tuning.length,
                title: \.title,
                onSelect: { length in model.updateTuning { $0.length = length } })
            .frame(width: 150)
            .help("How much time you have")

            picksMenu
                .frame(maxWidth: Preferences.buttonWidth)
                .fixedSize()
                .frame(width: Preferences.buttonSpacing)

            Button {
                /// Through SheetHostView, as every view outside a sheet opens one: the
                /// SheetCoordinator lives in that host's environment, not in MainView's.
                AppEventBus.shared.sendCommand(.showRecommendationsSheet)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .frame(width: 14)
            }
            .frame(maxWidth: Preferences.buttonWidth)
            .fixedSize()
            .frame(width: Preferences.buttonSpacing)
            .help("Rate, tune, and see what the engine has learned")
        }
        .focusable(false)
        .padding(.trailing, 18)
    }

    /// New picks and steering, in one button: Generate New Picks is the old shuffle, and Steer
    /// Recommendations the old steering button's menu, as a submenu.
    private var picksMenu: some View {
        Menu {
            Menu("Steer Recommendations") { steerItems }
            Button("Generate New Picks") { model.shuffle() }
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
                .foregroundStyle(model.tuning.steer.isEmpty ? Color.primary : Color.accentColor)
        }
        .menuIndicator(.hidden)
        .help("Steer the picks toward a director, actor, writer, genre, decade, or tag, or generate new ones")
    }

    @ViewBuilder
    private var steerItems: some View {
        let groups = model.result?.steerGroups ?? []
        if groups.isEmpty {
            Text("Nothing to steer toward yet").disabled(true)
        }
        ForEach(groups) { group in
            Section(group.facet.title) {
                ForEach(group.options, id: \.self) { option in
                    Toggle(option.name, isOn: Binding(
                        get: { model.isSteering(option) },
                        set: { _ in model.toggleSteer(option) }))
                }
            }
        }
        if !model.tuning.steer.isEmpty {
            Divider()
            Button("Clear Steering") { model.updateTuning { $0.steer = [] } }
        }
    }
}

// MARK: - Steering Bar

private struct RecSteeringBar: View {
    var model: RecommendationsModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
            Text("Steering toward")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tuning.steer, id: \.self) { steer in
                        Button {
                            model.toggleSteer(steer)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: steer.feature.facet.glyph)
                                Text(steer.name)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help("Stop steering toward \(steer.name)")
                    }
                }
            }
            Button("Clear") { model.updateTuning { $0.steer = [] } }
                .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}
