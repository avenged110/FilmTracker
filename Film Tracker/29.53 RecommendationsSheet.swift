// MARK: - RecommendationsSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Behind `Preferences.recommendationsEnabled` (experiment flag + Settings checkbox). The Recommendations sheet, opened from
/// the view's title bar (29.50 RecommendationsView.swift): the app's standard 600 × 600 sheet with
/// three tabs.
///  • Rate: every director, actor, writer, genre, decade, tag, and so on in the library, each with a
///    like, neutral, or dislike. A lean outweighs what the engine infers from the films that carry it
///    (RecFeedback.featureLeans), which is how a nuance the films cannot show gets in.
///  • Tune: how much each kind of evidence counts, how many picks, and the rules.
///  • Learn: what the engine has learned, what is held back today, and what the user has told it.
/// Every change applies at once, as in Settings; Close dismisses. The bottom bar's resets ask first, in
/// an alert.
///
/// KEYBOARD. As the FilmSheet: a zero-height FilmSheetFocusSink takes AppKit's automatic first
/// responder, so no focus ring shows until Tab is pressed, once, to reach the first control. Option-1
/// to Option-3 and Command-Up/Down switch tabs (KeyboardManager, through RecSheetNavigation).
///
/// OPENING COST. Only the Rate tab is built as the sheet opens. Tune and Learn are built hidden,
/// one per frame, once the sheet's animation has ended (a Task cannot run during it), and then kept,
/// so switching to them never waits on a first build. A hidden tab is disabled, which keeps its
/// controls out of the key-view loop.

import AppKit
import SwiftUI

// MARK: - Tabs

enum RecSheetTab: String, CaseIterable, Identifiable, CustomTab {
    case rate = "Rate"
    case tune = "Tune"
    case learn = "Learn"
    case cooldown = "Cool Down"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var iconName: String {
        switch self {
        case .rate:  return "star.leadinghalf.filled"
        case .tune:  return "slider.horizontal.3"
        case .learn: return "brain"
        case .cooldown: return "hourglass"
        }
    }
}

// MARK: - Navigation

/// The sheet's selected tab, where KeyboardManager can reach it for Option-digit and Command-Up/Down.
@MainActor
@Observable
final class RecSheetNavigation {
    static let shared = RecSheetNavigation()
    var tab: RecSheetTab = .rate

    func select(number: Int) -> Bool {
        let tabs = RecSheetTab.allCases
        guard (1...tabs.count).contains(number) else { return false }
        tab = tabs[number - 1]
        return true
    }

    func cycle(forward: Bool) {
        let tabs = RecSheetTab.allCases
        let index = tabs.firstIndex(of: tab) ?? 0
        tab = tabs[(index + (forward ? 1 : -1) + tabs.count) % tabs.count]
    }
}

// MARK: - Sheet

struct RecommendationsSheet: View {
    @Environment(SheetCoordinator.self) private var sheetCoordinator
    @Environment(DataCoordinator.self) private var dataCoordinator
    private var navigation = RecSheetNavigation.shared
    @State private var rateState = RecRateState()
    /// Tabs built so far; Rate at open, the others after the animation (see OPENING COST).
    @State private var builtTabs: Set<RecSheetTab> = [.rate]
    /// A list made from a Rate row's films popover, over this sheet.
    @State private var listCreation: RecListCreation?
    /// The reset awaiting the user's answer in an alert.
    @State private var pendingReset: RecReset?
    private var model = RecommendationsModel.shared

    /// What a bottom-bar reset will clear, frozen when it is asked, so the alert acts on what it says.
    enum RecReset: Identifiable {
        case clearRatings(RecFeature.Facet, count: Int)
        case restoreDefaults
        case resetLearning

        var id: String {
            switch self {
            case .clearRatings(let facet, _): return "ratings.\(facet.rawValue)"
            case .restoreDefaults:            return "defaults"
            case .resetLearning:              return "learning"
            }
        }

        var title: String {
            switch self {
            case .clearRatings:    return "Clear Ratings?"
            case .restoreDefaults: return "Restore Default Tuning?"
            case .resetLearning:   return "Reset Learning?"
            }
        }

        var confirmTitle: String {
            switch self {
            case .clearRatings:    return "Clear Ratings"
            case .restoreDefaults: return "Restore Defaults"
            case .resetLearning:   return "Reset Learning"
            }
        }

        var message: String {
            switch self {
            case .clearRatings(let facet, let count):
                return "Your \(Fmt.count(count, "rating")) of \(facet.title.lowercased()) will be cleared. What the engine infers from your films is untouched. This action cannot be undone."
            case .restoreDefaults:
                return "The signals, the number of picks, adventurousness, variety, and the rules return to their defaults. Steering is left as it is."
            case .resetLearning:
                return "Every More Like This, Less Like This, Not Now, and Never Recommend will be cleared. Your ratings, your library, and the Rate tab are untouched. This action cannot be undone."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar("Tune Your Recommendations")

            CustomTabHeader(selectedTab: navigation.tab, showIcons: true) { newTab in
                navigation.tab = newTab
            }
            .sheetTabHeaderBand()

            /// Recreated for each tab, so it takes first responder again on every switch.
            FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: true)
                .frame(height: 0)
                .clipped()
                .id(navigation.tab)

            ZStack {
                ForEach(RecSheetTab.allCases) { tab in
                    if builtTabs.contains(tab) || navigation.tab == tab {
                        let isShown = navigation.tab == tab
                        tabContent(tab, isShown: isShown)
                            .opacity(isShown ? 1 : 0)
                            .allowsHitTesting(isShown)
                            .disabled(!isShown)
                            .accessibilityHidden(!isShown)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                bottomBarAction
                Spacer()
                Button {
                    sheetCoordinator.dismissSheet()
                } label: {
                    Text("Close").sheetButtonLabel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .sheetBottomBar()
        }
        .sheetFrame()
        .onAppear {
            navigation.tab = .rate
            if model.result == nil { model.refresh() }
        }
        /// After the opening animation (no Task runs during it), one tab per frame.
        .task {
            for tab in RecSheetTab.allCases where !builtTabs.contains(tab) {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                builtTabs.insert(tab)
            }
        }
        .onChange(of: navigation.tab) { _, tab in builtTabs.insert(tab) }
        .sheet(item: $listCreation) { request in
            ListManagerSheet(mode: .create, filmIDs: request.filmIDs, prefillName: request.name)
                .environment(dataCoordinator)
        }
        .alert(pendingReset?.title ?? "", isPresented: Binding(
            get: { pendingReset != nil },
            set: { if !$0 { pendingReset = nil } }
        ), presenting: pendingReset) { reset in
            Button("Cancel", role: .cancel) { }
            Button(reset.confirmTitle, role: .destructive) { perform(reset) }
        } message: { reset in
            Text(reset.message)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: RecSheetTab, isShown: Bool) -> some View {
        switch tab {
        case .rate:
            RecRateTab(model: model, state: rateState, isShown: isShown) { filmIDs, name in
                listCreation = RecListCreation(filmIDs: filmIDs, name: name)
            }
        case .tune:  RecTuneTab(model: model)
        case .learn: RecLearnTab(model: model)
        case .cooldown: RecCooldownTab(model: model)
        }
    }

    private func perform(_ reset: RecReset) {
        switch reset {
        case .clearRatings(let facet, _): model.clearFeatureRatings(facet)
        case .restoreDefaults:            model.restoreDefaultTuning()
        case .resetLearning:              model.resetLearning()
        }
    }

    @ViewBuilder
    private var bottomBarAction: some View {
        switch navigation.tab {
        case .rate:
            let facet = rateState.facet
            let count = model.ratedCount(facet)
            resetButton("Clear Ratings…",
                        help: "Clears your own ratings of \(facet.title.lowercased()). The engine’s inferences are untouched.",
                        disabled: count == 0, reset: .clearRatings(facet, count: count))
        case .tune:
            /// Restore Defaults leaves steering alone, so the comparison does too.
            resetButton("Restore Defaults…",
                        help: "Returns every setting on this tab to its default. Steering is left as it is.",
                        disabled: model.tuning == RecTuning(steer: model.tuning.steer), reset: .restoreDefaults)
        case .learn:
            resetButton("Reset Learning…",
                        help: "Clears every More Like This, Less Like This, Not Now, and Never Recommend. Your ratings, your library, and the Rate tab are untouched.",
                        disabled: model.feedback.isEmpty, reset: .resetLearning)
        case .cooldown:
            EmptyView()
        }
    }

    private func resetButton(_ title: String, help: String, disabled: Bool, reset: RecReset) -> some View {
        Button {
            pendingReset = reset
        } label: {
            Text(title).sheetButtonLabel()
        }
        .help(help)
        .disabled(disabled)
    }
}

// MARK: - Rate

/// The Rate tab's choices, kept across tab switches while the sheet is open.
@MainActor
@Observable
final class RecRateState {
    var facet: RecFeature.Facet = .director
    var search = ""
    var order: Order = .films

    enum Order: Hashable { case films, name, rated }
}

struct RecListCreation: Identifiable {
    let id = UUID()
    let filmIDs: Set<UUID>
    let name: String
}

private struct RecRateTab: View {
    var model: RecommendationsModel
    @Bindable var state: RecRateState
    let isShown: Bool
    let onCreateList: (Set<UUID>, String) -> Void
    @Environment(DataCoordinator.self) private var dataCoordinator

    /// People first, then the broad buckets, then the user's own vocabulary.
    private static let facets: [RecFeature.Facet] = [.director, .writer, .cast, .composer, .producer, .studio,
                                                     .genre, .decade, .certification, .length, .tag, .list]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Like or dislike anything the engine weighs. Your choice outweighs what it infers from the films themselves, such as an actor you like whose films you mostly rate poorly. Leave a value neutral to let the engine decide.")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SheetMenuPicker(selection: $state.facet, items: facetItems, width: 170)
                    RoundedTextField(text: $state.search, placeholder: "Filter \(state.facet.title)")
                    SheetMenuPicker(selection: $state.order, items: [
                        .option(tag: RecRateState.Order.films, title: "Most Films First"),
                        .option(tag: .name, title: "By Name"),
                        .option(tag: .rated, title: "Your Choices First"),
                    ], width: 160)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let catalog = model.catalog {
                let rows = rows(from: catalog)
                if rows.isEmpty {
                    SheetPlaceholder(state.search.isEmpty
                                     ? "Your library has no \(state.facet.title.lowercased()) yet."
                                     : "No \(state.facet.title.lowercased()) match “\(state.search)”.")
                } else {
                    RecRateTable(rows: rows, leans: model.feedback.featureLeans, isShown: isShown,
                                 model: model, dataCoordinator: dataCoordinator, onCreateList: onCreateList)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var facetItems: [SheetPopUpButton<RecFeature.Facet>.Item] {
        let counts = model.ratedCounts()
        return Self.facets.map { facet in
            let rated = counts[facet] ?? 0
            return .option(tag: facet, title: rated > 0 ? "\(facet.title) (\(Fmt.int(rated)) rated)" : facet.title)
        }
    }

    /// The catalog arrives sorted both ways (RecCatalogGroup), so this only filters, and for
    /// Your Choices First moves the likes and then the dislikes ahead, in Most Films First order.
    private func rows(from catalog: [RecFeature.Facet: RecCatalogGroup]) -> [RecCatalogEntry] {
        guard let group = catalog[state.facet] else { return [] }
        let query = RecFeature.fold(state.search)
        let base = state.order == .name ? group.byName : group.byFilms
        let entries = query.isEmpty ? base : base.filter { $0.foldedName.contains(query) }
        guard state.order == .rated else { return entries }
        let leans = model.feedback.featureLeans
        var liked: [RecCatalogEntry] = [], disliked: [RecCatalogEntry] = [], rest: [RecCatalogEntry] = []
        for entry in entries {
            switch leans[entry.id] {
            case 1:  liked.append(entry)
            case -1: disliked.append(entry)
            default: rest.append(entry)
            }
        }
        return liked + disliked + rest
    }
}

// MARK: - Tune

private struct RecTuneTab: View {
    var model: RecommendationsModel

    var body: some View {
        let tuning = model.tuning
        ScrollView(.vertical) {
            SettingsPage(padding: 0) {
                SettingsRow("Signals", description: "How much each kind of evidence counts, in five steps. Off ignores it; Dominant doubles it.")
                VStack(alignment: .leading, spacing: 12) {
                    weight("Taste Match", "People, genres, eras, and tags you rate highly, and those you rated on the Rate tab", \.taste)
                    weight("Connections", "Close ties to particular films you love", \.connections)
                    weight("Rewatch Timing", "Overdue favorites, your rewatch rhythm, the Hall of Fame", \.rewatch)
                    weight("Your Shelf", "Bought but unwatched, gathering dust, freshly added", \.shelf)
                    weight("Seasons & Anniversaries", "What you watch this time of year; release anniversaries", \.timing)
                    weight("Queue & Momentum", "Soon and Later, the wishlist, your current streak", \.momentum)
                }
                .settingsChildRowInset()

                Divider()

                SettingsRow("Number of picks:", description: "Picks in all, the featured pick and the wildcards included.") {
                    StandardStepper(value: binding(\.pickCount), in: 4...24)
                }
                SettingsRow("Adventurousness:",
                            description: "\(Fmt.count(tuning.wildcardCount, "pick")) of \(tuning.pickCount) go to wildcards: Films unlike anything you watched in the past year.") {
                    EmptyView()
                } accessory: {
                    quarterSlider(\.adventurousness, low: "Familiar", high: "Adventurous")
                }
                SettingsRow("Variety between picks:", description: "How far apart the picks are pushed from one another.") {
                    EmptyView()
                } accessory: {
                    quarterSlider(\.variety, low: "Similar", high: "Varied")
                }

                Divider()

                SettingsRow("Resurface rated films from:",
                            description: "A film you rated lower than this is never offered again.") {
                    StandardStepper(value: binding(\.minimumRating), in: 1...10)
                }
                SettingsDescribedToggle("Include films already in Up Next",
                                        description: "Up Next is your own choice already, so it is usually left out.",
                                        isOn: binding(\.includeUpNext))
                SettingsDescribedToggle("Only films you can watch now",
                                        description: "Films with a viewing source or a purchased release.",
                                        isOn: binding(\.onlyWatchable))
                SettingsDescribedToggle("Show a double feature",
                                        description: "Two more strong picks tied by a person, a tag, or a list.",
                                        isOn: binding(\.showDoubleFeature))

                Text("Films with any Special Sorting flag, or watched inside their rotation threshold, are never offered.")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.tertiary)
            }
            .padding(Preferences.sheetContentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weight(_ title: String, _ detail: String,
                        _ path: WritableKeyPath<RecTuning.Weights, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(RecTuning.Weights.levelTitles[model.tuning.weights.level(path)])
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
            RecTickSlider(index: Binding(
                get: { model.tuning.weights.level(path) },
                set: { level in model.updateTuning { $0.weights.setLevel(level, path) } }),
                          count: RecTuning.Weights.levels.count)
        }
        .frame(maxWidth: 460)
    }

    /// A 0…1 setting in quarters, between its two ends' names.
    private func quarterSlider(_ path: WritableKeyPath<RecTuning, Double>, low: String, high: String) -> some View {
        HStack(spacing: 8) {
            Text(low).font(.system(size: 10)).foregroundStyle(.secondary)
            RecTickSlider(index: Binding(
                get: { Int((model.tuning[keyPath: path] * 4).rounded()) },
                set: { index in model.updateTuning { $0[keyPath: path] = Double(index) / 4 } }),
                          count: 5)
            Text(high).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360)
    }

    private func binding<Value>(_ path: WritableKeyPath<RecTuning, Value>) -> Binding<Value> {
        Binding(get: { model.tuning[keyPath: path] },
                set: { value in model.updateTuning { $0[keyPath: path] = value } })
    }
}

// MARK: - Learn

private struct RecLearnTab: View {
    var model: RecommendationsModel
    @Environment(DataCoordinator.self) private var dataCoordinator

    var body: some View {
        if let result = model.result {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    statsRow(result.stats)
                    ForEach(result.profile.groups) { group in
                        profileGroup(group.facet.title, glyph: group.facet.glyph, entries: group.entries)
                    }
                    if !result.profile.dislikes.isEmpty {
                        profileGroup("Not Your Thing", glyph: "hand.thumbsdown", entries: result.profile.dislikes)
                    }
                    if let streak = result.stats.streak {
                        labeled("Current Streak", glyph: "flame") { Text(streak).foregroundStyle(.secondary) }
                    }
                    if !result.stats.exclusions.isEmpty {
                        labeled("Held Back Today", glyph: "hand.raised") {
                            ForEach(result.stats.exclusions) { exclusion in
                                HStack {
                                    Text(exclusion.label)
                                    Spacer()
                                    Text(Fmt.int(exclusion.count)).monospacedDigit()
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    taught
                    Text("Learned from \(Fmt.count(result.stats.labeledCount, "film")) and \(Fmt.count(result.stats.viewingCount, "viewing")); \(Fmt.int(result.stats.eligibleCount)) of \(Fmt.int(result.stats.filmCount)) films eligible today; computed in \(result.milliseconds) ms.")
                        .font(.system(size: NSFont.smallSystemFontSize))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .padding(Preferences.sheetContentMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statsRow(_ stats: RecStats) -> some View {
        HStack(spacing: 0) {
            stat(Fmt.int(stats.filmCount), "films")
            stat(Fmt.int(stats.ratedCount), "rated")
            stat(Fmt.int(stats.viewingCount), "viewings")
            stat(Fmt.fixed(stats.meanRating, 1), "avg. rating")
            stat(Fmt.int(model.feedback.featureLeans.count), "your choices")
            stat(Fmt.int(model.feedback.hits.count), "picks watched")
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func profileGroup(_ title: String, glyph: String, entries: [RecProfile.Entry]) -> some View {
        labeled(title, glyph: glyph) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.name)
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    GeometryReader { geometry in
                        let width = geometry.size.width * min(1, abs(entry.affinity) / 0.8)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule()
                                .fill(entry.affinity >= 0 ? Color.accentColor : Color.orange)
                                .frame(width: max(4, width))
                        }
                    }
                    .frame(height: 6)
                    Group {
                        if let own = entry.userLean {
                            Image(systemName: own > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .help(own > 0 ? "You like this, on the Rate tab" : "You dislike this, on the Rate tab")
                        } else {
                            Text(entry.averageRating.map { "★ " + Fmt.fixed($0, 1) } ?? "—")
                        }
                    }
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                    Text("\(entry.count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
                .help("\(entry.name): Learned from \(Fmt.count(entry.count, "film"))")
            }
        }
    }

    @ViewBuilder
    private var taught: some View {
        let rows = taughtRows
        if !rows.isEmpty {
            labeled("What You’ve Told It", glyph: "bubble.left") {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.glyph).frame(width: 16).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.name).lineLimit(1)
                            Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") {
                            if row.isLike { model.forget(row.filmID) } else { model.restore(row.filmID) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private struct TaughtRow: Identifiable {
        var id: String { "\(filmID.uuidString)|\(glyph)" }
        let filmID: UUID
        let name: String
        let glyph: String
        let detail: String
        var isLike: Bool { glyph == "hand.thumbsup" }
    }

    private var taughtRows: [TaughtRow] {
        let feedback = model.feedback
        func rows(_ ids: some Sequence<UUID>, _ glyph: String, _ detail: (UUID) -> String) -> [TaughtRow] {
            ids.compactMap { id in
                dataCoordinator.getFilm(id).map { TaughtRow(filmID: id, name: $0.name, glyph: glyph, detail: detail(id)) }
            }
        }
        let snoozed = feedback.snoozedUntil.keys.filter { feedback.disliked[$0] == nil && feedback.dismissed[$0] == nil }
        return (rows(feedback.liked.keys, "hand.thumbsup") { _ in "More like this" }
            + rows(feedback.disliked.keys, "hand.thumbsdown") { _ in "Less like this" }
            + rows(feedback.dismissed.keys, "xmark") { _ in "Never recommend" }
            + rows(snoozed, "moon.zzz") { "Not now, until " + formatDate(feedback.snoozedUntil[$0] ?? Date()) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func labeled<Content: View>(_ title: String, glyph: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: glyph)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }
}

// MARK: - Tick Slider

/// A small NSSlider with a tick mark per step that only rests on a tick: the steps are the setting's
/// only values, so the control shows exactly where each one is.
private struct RecTickSlider: NSViewRepresentable {
    @Binding var index: Int
    let count: Int

    func makeCoordinator() -> Coordinator { Coordinator(index: $index) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(index), minValue: 0, maxValue: Double(max(1, count - 1)),
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.controlSize = .small
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.index = $index
        if slider.integerValue != index { slider.integerValue = index }
    }

    @MainActor
    final class Coordinator: NSObject {
        var index: Binding<Int>

        init(index: Binding<Int>) { self.index = index }

        /// Only a move to another tick writes, so a drag changes the setting once per step.
        @objc func changed(_ slider: NSSlider) {
            let value = Int(slider.doubleValue.rounded())
            if index.wrappedValue != value { index.wrappedValue = value }
        }
    }
}

// MARK: - Cool Down

/// Films resting after being offered without being watched (RecFeedback.cooldowns), soonest back first.
private struct RecCooldownTab: View {
    var model: RecommendationsModel
    @Environment(DataCoordinator.self) private var dataCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A pick offered for \(RecommendationEngine.cooldownShownDays) days without being watched rests here for \(RecommendationEngine.cooldownDays) days, so new picks get a turn. This is not a judgment of the film or a sign you didn’t want it: its score is unchanged, and when the cool down ends, it returns to the pool as if it had never been ignored.")
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            let films = films
            if films.isEmpty {
                SheetPlaceholder("No films are cooling down.")
            } else {
                /// Read-only: nothing acts on a row here.
                UpNextResultsTable(films: films)
            }
        }
    }

    /// Only the cooldowns still running: a finished one is pruned on the next pass.
    private var films: [FilmSnapshot] {
        let today = AppCalendar.current.startOfDay(for: Date())
        return model.feedback.cooldowns
            .filter { $0.value.until > today }
            .sorted { ($0.value.until, $0.key.uuidString) < ($1.value.until, $1.key.uuidString) }
            .compactMap { dataCoordinator.getFilm($0.key) }
    }
}

// MARK: - Rate Table

/// The Rate tab's list: a view-based NSTableView, because a category can hold thousands of values
/// and each row carries two real controls. The table builds rows only for what is on screen (about
/// eight at the sheet's height) and reuses them as the list scrolls, so the number of controls stays
/// the same whatever the category's size: everything visible is built as the sheet opens, nothing
/// is built ahead in batches, and nothing fills in where the user can see it.
private struct RecRateTable: NSViewRepresentable {
    let rows: [RecCatalogEntry]
    let leans: [String: Int]
    let isShown: Bool
    let model: RecommendationsModel
    let dataCoordinator: DataCoordinator
    let onCreateList: (Set<UUID>, String) -> Void

    func makeCoordinator() -> RecRateTableCoordinator { RecRateTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.headerView = nil
        /// As the gallery's list view: inset, so each alternating fill is a rounded shape inside the
        /// edge padding, and the backdrop is the first fill color.
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.rowHeight = RecRateRowView.rowHeight
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scrollView.documentView = table

        let coordinator = context.coordinator
        coordinator.attach(table: table, scrollView: scrollView)
        apply(to: coordinator)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        apply(to: context.coordinator)
        /// Hidden while another tab shows, which also takes its controls out of the key-view loop.
        if scrollView.isHidden == isShown { scrollView.isHidden = !isShown }
    }

    private func apply(to coordinator: RecRateTableCoordinator) {
        coordinator.model = model
        coordinator.dataCoordinator = dataCoordinator
        coordinator.onCreateList = onCreateList
        coordinator.update(rows: rows, leans: leans)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: RecRateTableCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class RecRateTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    weak var model: RecommendationsModel?
    weak var dataCoordinator: DataCoordinator?
    var onCreateList: ((Set<UUID>, String) -> Void)?
    fileprivate private(set) var rows: [RecCatalogEntry] = []
    private var leans: [String: Int] = [:]
    private weak var table: NSTableView?
    private weak var scrollView: NSScrollView?
    private var boundsObserver: (any NSObjectProtocol)?
    private var lastClipOrigin: NSPoint?

    /// The open films popover, the row value it lists, and the last one to close (for the toggle).
    private var popover: NSPopover?
    private var popoverKey: String?
    private var lastClosed: (key: String, at: TimeInterval)?

    func attach(table: NSTableView, scrollView: NSScrollView) {
        self.table = table
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        lastClipOrigin = clip.bounds.origin
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipBoundsChanged() }
        }
    }

    func detach() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        popover?.close()
    }

    /// As every popover in a scrolling list does: a scroll closes it; a resize does not.
    private func clipBoundsChanged() {
        guard let origin = scrollView?.contentView.bounds.origin, origin != lastClipOrigin else { return }
        lastClipOrigin = origin
        if popover?.isShown == true { popover?.close() }
    }

    /// New rows reload the table. The same rows with a changed lean, or with new figures (a Learn tab
    /// Undo or Reset Learning changes what the engine infers, and so each value's inferred lean),
    /// only reconfigure the rows on screen.
    func update(rows: [RecCatalogEntry], leans: [String: Int]) {
        let sameRows = rows.count == self.rows.count && zip(rows, self.rows).allSatisfy { $0.id == $1.id }
        let figuresChanged = sameRows && zip(rows, self.rows).contains { !Self.sameFigures($0, $1) }
        self.rows = rows
        let leansChanged = leans != self.leans
        self.leans = leans
        guard let table else { return }
        if !sameRows {
            popover?.close()
            table.reloadData()
            table.scrollRowToVisible(0)
        } else if leansChanged || figuresChanged {
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecRateRowView)
                    .map { configure($0, row: row) }
            }
        }
    }

    /// Everything a row shows of one value, its films included (the films popover lists them).
    private static func sameFigures(_ a: RecCatalogEntry, _ b: RecCatalogEntry) -> Bool {
        a.name == b.name && a.filmCount == b.filmCount && a.ratedCount == b.ratedCount
            && a.averageRating == b.averageRating && a.labeled == b.labeled && a.inferred == b.inferred
            && a.filmIDs == b.filmIDs
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = (tableView.makeView(withIdentifier: RecRateRowView.identifier, owner: nil) as? RecRateRowView)
            ?? RecRateRowView()
        configure(view, row: row)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func configure(_ view: RecRateRowView, row: Int) {
        guard rows.indices.contains(row) else { return }
        let entry = rows[row]
        view.configure(entry: entry, lean: leans[entry.id] ?? 0,
                       onLean: { [weak self] lean in self?.model?.setFeatureLean(entry.feature, lean) },
                       onShowFilms: { [weak self] button in self?.showFilms(for: entry, from: button) })
    }

    // MARK: Films Popover

    /// The TagSheet's films popover (DVAttentionPopover) for a value. A second click on its button
    /// closes it, whichever way AppKit delivers that click (as DVCanvasPageView's popovers do).
    private func showFilms(for entry: RecCatalogEntry, from anchor: NSView) {
        if let popover, popover.isShown, popoverKey == entry.id {
            popover.performClose(nil)
            return
        }
        if let closed = lastClosed, closed.key == entry.id,
           let clickTime = NSApp.currentEvent?.timestamp, closed.at >= clickTime {
            return
        }
        guard let dataCoordinator else { return }
        let films = entry.filmIDs.compactMap { dataCoordinator.getFilm($0).map { DVNamedFilm($0) } }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let name = entry.name
        popover.contentViewController = NSHostingController(rootView: DVAttentionPopover(
            label: name, items: films,
            dismiss: { [weak popover] in popover?.performClose(nil) },
            onCreateList: { [weak self, weak popover] filmIDs in
                popover?.performClose(nil)
                self?.onCreateList?(filmIDs, name)
            }))
        popover.contentSize = DVAttentionPopover.size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        self.popover = popover
        popoverKey = entry.id
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover, let popoverKey else { return }
        lastClosed = (popoverKey, ProcessInfo.processInfo.systemUptime)
        self.popoverKey = nil
    }
}

/// One value as a plain list row: its name, its films, what the engine inferred, the three-way lean
/// (an NSSegmentedControl) and the film.stack button. Reused by the table as rows scroll.
private final class RecRateRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("RecRateRow")
    static let rowHeight: CGFloat = 70
    /// Segment order, left to right, and the lean each stands for.
    private static let segmentLeans = [1, 0, -1]

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let leanImage = NSImageView()
    private let leanLabel = NSTextField(labelWithString: "")
    private let segmented = NSSegmentedControl()
    private let filmsButton = NSButton()
    private var onLean: ((Int) -> Void)?
    private var onShowFilms: ((NSView) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        leanLabel.font = .systemFont(ofSize: 11)
        leanImage.imageScaling = .scaleNone
        for label in [nameLabel, detailLabel, leanLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        segmented.segmentCount = 3
        segmented.trackingMode = .selectOne
        for (index, help) in ["Like", "Neutral: The engine decides", "Dislike"].enumerated() {
            segmented.setImage(Self.segmentImages[index].plain, forSegment: index)
            segmented.setToolTip(help, forSegment: index)
            segmented.setWidth(30, forSegment: index)
        }
        segmented.target = self
        segmented.action = #selector(leanChosen)

        filmsButton.bezelStyle = .push
        filmsButton.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Show Films")
        filmsButton.imagePosition = .imageOnly
        filmsButton.toolTip = "Show the films with this value"
        filmsButton.target = self
        filmsButton.action = #selector(filmsClicked)

        for view in [nameLabel, detailLabel, leanImage, leanLabel, segmented, filmsButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            filmsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filmsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            filmsButton.widthAnchor.constraint(equalToConstant: 30),
            segmented.trailingAnchor.constraint(equalTo: filmsButton.leadingAnchor, constant: -8),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: segmented.leadingAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: segmented.leadingAnchor, constant: -12),
            leanImage.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            leanImage.centerYAnchor.constraint(equalTo: leanLabel.centerYAnchor),
            leanImage.widthAnchor.constraint(equalToConstant: 14),
            leanLabel.leadingAnchor.constraint(equalTo: leanImage.trailingAnchor, constant: 4),
            leanLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 2),
            leanLabel.trailingAnchor.constraint(lessThanOrEqualTo: segmented.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Each segment's glyph: outlined while unchosen; the like and dislike segments fill in green
    /// and red once chosen. Built once and shared by every row.
    private static let segmentImages: [(plain: NSImage?, chosen: NSImage?)] = {
        func image(_ name: String, _ description: String, color: NSColor?) -> NSImage? {
            let base = NSImage(systemSymbolName: name, accessibilityDescription: description)
            guard let color else { return base }
            /// Not a template, or the control would tint it like the others.
            let colored = base?.withSymbolConfiguration(.init(paletteColors: [color]))
            colored?.isTemplate = false
            return colored
        }
        return [
            (image("hand.thumbsup", "Like", color: nil), image("hand.thumbsup.fill", "Liked", color: .systemGreen)),
            (image("minus", "Neutral", color: nil), image("minus", "Neutral", color: nil)),
            (image("hand.thumbsdown", "Dislike", color: nil), image("hand.thumbsdown.fill", "Disliked", color: .systemRed)),
        ]
    }()

    func configure(entry: RecCatalogEntry, lean: Int, onLean: @escaping (Int) -> Void,
                   onShowFilms: @escaping (NSView) -> Void) {
        self.onLean = onLean
        self.onShowFilms = onShowFilms
        nameLabel.stringValue = entry.name

        var parts = [Fmt.count(entry.filmCount, "film")]
        if entry.ratedCount > 0 { parts.append("\(Fmt.int(entry.ratedCount)) rated") }
        if let average = entry.averageRating { parts.append("Average: \(Fmt.fixed(average, 1))") }
        detailLabel.stringValue = parts.joined(separator: " · ")

        let (glyph, text, color): (String, String, NSColor) = {
            guard let inferred = entry.inferred else {
                let text = entry.labeled == 0 ? "Nothing to infer from yet"
                    : "Too few films to infer a lean (\(RecommendationEngine.confidentFilms) needed)"
                return ("circle.dashed", text, .secondaryLabelColor)
            }
            switch inferred {
            case 0.25...:      return ("hand.thumbsup.fill", "Inferred: A strong favorite", .controlAccentColor)
            case 0.08..<0.25:  return ("hand.thumbsup", "Inferred: You tend to like these", .controlAccentColor)
            case ..<(-0.25):   return ("hand.thumbsdown.fill", "Inferred: Not your thing", .systemOrange)
            case ..<(-0.08):   return ("hand.thumbsdown", "Inferred: You tend not to like these", .systemOrange)
            default:           return ("minus.circle", "Inferred: No clear lean", .secondaryLabelColor)
            }
        }()
        leanImage.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        leanImage.contentTintColor = color
        leanLabel.stringValue = text
        leanLabel.textColor = color

        let segment = Self.segmentLeans.firstIndex(of: lean) ?? 1
        if segmented.selectedSegment != segment { segmented.selectedSegment = segment }
        for index in Self.segmentImages.indices {
            let images = Self.segmentImages[index]
            let image = index == segment ? images.chosen : images.plain
            if segmented.image(forSegment: index) !== image { segmented.setImage(image, forSegment: index) }
        }
        segmented.setAccessibilityLabel("Your lean toward \(entry.name)")
        filmsButton.isEnabled = !entry.filmIDs.isEmpty
    }

    @objc private func leanChosen() {
        let index = segmented.selectedSegment
        guard Self.segmentLeans.indices.contains(index) else { return }
        onLean?(Self.segmentLeans[index])
    }

    @objc private func filmsClicked() { onShowFilms?(filmsButton) }
}
