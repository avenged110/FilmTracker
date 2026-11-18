// MARK: - DHViewState.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Harness coverage for per-view ViewState persistence, including the section-dividers
/// setting, which is stored in each view's own ViewState.
///
/// Everything here drives the REAL ViewStateManager against the REAL Preferences store
/// inside a debug sandbox — no reimplementation of the codec, no test double. The codec
/// itself (ViewState.decoded(from:) / ViewState.encodedSettings) is deliberately never
/// called directly: what matters is not that a pair of functions round-trip each
/// other, but that a choice made through the same method the menu calls survives being
/// written to disk and read back by the same method a view switch calls. Testing the
/// public path is the only way to catch a defect that lives in the wiring between them.

#if DEBUG

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DebugHarness {

    /// Scenario names owned by this file, in the order `all` runs them.
    static var viewStateScenarios: [String] {
        ["view-state-dividers", "source-ladder", "gallery-focus-handoff"]
    }

    /// Dispatch hook called by `DebugHarness.run(_:coordinator:)` before its own switch.
    /// Returns nil for a scenario this file does not own, so the caller falls through.
    static func runViewStateScenario(_ scenario: String,
                                     coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "view-state-dividers": return await sectionDividersScenario()
        case "source-ladder":       return sourceLadderScenario()
        case "gallery-focus-handoff": return await galleryFocusHandoffScenario(coordinator: coordinator)
        case "view-switch-perf":    return await viewSwitchPerfScenario(coordinator: coordinator)
        case "gallery-reuse":       return await galleryReuseScenario(coordinator: coordinator)
        case "shared-search":       return await sharedSearchScenario(coordinator: coordinator)
        case "switch-coast":        return await switchCoastScenario(coordinator: coordinator)
        case "summary-lazy-rows":   return await summaryLazyRowsScenario(coordinator: coordinator)
        case "gallery-integrity":   return await galleryIntegrityScenario(coordinator: coordinator)
        case "coast-stop":          return await coastStopScenario(coordinator: coordinator)
        case "scroll-memory":       return await scrollMemoryScenario(coordinator: coordinator)
        case "queue-mixed-style":   return await queueMixedStyleScenario(coordinator: coordinator)
        case "upnext-slots":        return await upNextSlotsScenario(coordinator: coordinator)
        case "sidebar-tab-switch":  return await sidebarTabSwitchScenario(coordinator: coordinator)
        case "gallery-edit-refresh": return await galleryEditRefreshScenario(coordinator: coordinator)
        case "gallery-reload-economy": return await galleryReloadEconomyScenario(coordinator: coordinator)
        case "appkit-scroll-settle": return await appKitScrollSettleScenario()
        case "sidebar-tags":        return await sidebarTagsScenario(coordinator: coordinator)
        default:                    return nil
        }
    }

    /// Empties all three Film Queue sections, then fills them with the given films.
    ///
    /// Every Queue scenario seeds on top of whatever the sandbox already holds: a real-library
    /// copy, or an earlier scenario in the same run. "Up Next" refuses adds past
    /// FilmQueue.upNextCapacity, so seeding without clearing first can leave it full. Checks
    /// that need a known vacancy or a known count would then fail for reasons unrelated to
    /// the code under test.
    static func seedFilmQueue(_ coordinator: DataCoordinator,
                              upNext: some Collection<UUID>,
                              soon: some Collection<UUID> = [UUID](),
                              later: some Collection<UUID> = [UUID]()) {
        for section in FilmQueueSection.allCases {
            if let ids = coordinator.getList(section.listID)?.filmIDs, !ids.isEmpty {
                coordinator.removeFilmsFromList(filmIDs: ids, listID: section.listID)
            }
        }
        _ = coordinator.addFilmsToList(filmIDs: Set(upNext), listID: FilmQueueSection.upNext.listID)
        if !soon.isEmpty { _ = coordinator.addFilmsToList(filmIDs: Set(soon), listID: FilmQueueSection.soon.listID) }
        if !later.isEmpty { _ = coordinator.addFilmsToList(filmIDs: Set(later), listID: FilmQueueSection.later.listID) }
    }

    /// The save path is debounced (ViewStateManager.saveDebounceMs, 300ms) and runs on a
    /// detached Task, so a read of Preferences taken immediately after a mutation races it.
    /// Waiting out the window with margin is what makes the persistence checks below mean
    /// "the value was written" rather than "the value was written fast enough."
    private static func awaitDebouncedSave() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - Section Dividers

    /// Proves the per-view section-dividers setting: that it decodes from storage, that a
    /// choice round-trips through the public mutator, that one view's choice cannot leak
    /// into another's, that the pre-existing on-disk format still reads correctly, and that
    /// `rememberSortFilterSelections` governs it exactly as it governs every sibling field.
    private static func sectionDividersScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "view-state-dividers")

        let manager = ViewStateManager.shared
        let rememberBefore = Preferences.rememberSortFilterSelections
        let statesBefore = Preferences.viewSortStates
        /// The Queue's active tab is part of what this scenario manipulates (it selects the
        /// storage slot .filmQueue resolves to), so it is restored alongside the
        /// preferences. Assigned directly rather than through selectFilter throughout:
        /// this scenario is asserting about storage and state resolution, and the public
        /// switch additionally clears the selection, banks scroll origins and schedules a
        /// deferred gallery reload — none of which this is testing.
        let queueFilterBefore = FilmQueueFilterState.shared.selectedFilter
        defer {
            Preferences.rememberSortFilterSelections = rememberBefore
            Preferences.viewSortStates = statesBefore
            FilmQueueFilterState.shared.selectedFilter = queueFilterBefore
        }
        Preferences.rememberSortFilterSelections = true

        // MARK: Decoding

        /// Seed storage directly, then reach each view for the first time this run so the
        /// load path — not the in-memory cache — is what answers. Distinct views are used
        /// per case for exactly that reason: revisiting one would be served from the cache
        /// and would assert nothing about decoding.
        Preferences.viewSortStates = [
            /// A five-element entry with dividers ON.
            "smartList.\(SmartListType.allCases[0].rawValue)":
                ["title", "", "ascending", "", "dividers"],
            /// A five-element entry with dividers explicitly OFF.
            "unwatched.\(UnwatchedCategory.unwatched.rawValue)":
                ["year", "", "descending", "list", ""],
            /// A LEGACY four-element entry, the format without the dividers element. Must
            /// decode with dividers off and must not trap on the missing element. This is
            /// the case that governs stored state written before the element existed.
            "unwatched.\(UnwatchedCategory.notRated.rawValue)":
                ["title", "", "ascending", "list"],
            /// A THREE-element entry, the older format the codec still reads. Both trailing
            /// fields must fall back to their struct defaults. Filed
            /// under the Queue's "Up Next" tab, which owns its slot like any other view.
            "filmQueue.upNext": ["duration", "", "descending"],
            /// The Queue's "All" tab, seeded with dividers explicitly OFF. It must still
            /// resolve to ON: that tab's bands are structural and its pair is locked, so no
            /// stored value may present it as anything else.
            "filmQueue": ["title", "", "ascending", "", ""],
            /// A malformed element [4]. Anything that is not exactly "dividers" means off;
            /// it must not trap, and it must not be read as truthy for being non-empty.
            "allFilms": ["title", "", "ascending", "", "yes-please"],
        ]

        manager.switchToViewSync(.smartList(SmartListType.allCases[0]))
        r.check("decode-dividers-on", manager.activeState.showSectionDividers,
                "five-element entry with \"dividers\" decoded as on")

        manager.switchToViewSync(.unwatched(.unwatched))
        r.check("decode-dividers-off", !manager.activeState.showSectionDividers,
                "five-element entry with an empty slot decoded as off")
        r.check("decode-siblings-intact",
                manager.activeState.sortOption == .year
                    && manager.activeState.sortDirection == .descending
                    && manager.activeState.isListView,
                "the four fields ahead of the new one still decode correctly")

        manager.switchToViewSync(.unwatched(.notRated))
        r.check("decode-legacy-four-element", !manager.activeState.showSectionDividers,
                "a pre-change four-element entry decodes with dividers off")
        r.check("decode-legacy-four-element-siblings", manager.activeState.isListView,
                "and its own trailing field is still honored")

        FilmQueueFilterState.shared.selectedFilter = .upNext
        manager.switchToViewSync(.filmQueue)
        r.check("decode-legacy-three-element",
                !manager.activeState.showSectionDividers && !manager.activeState.isListView,
                "a three-element entry defaults both trailing fields")
        r.check("queue-tab-owns-its-slot", manager.activeState.sortOption == .duration,
                "the Queue's Up Next tab read its own key, not the flat filmQueue one")

        manager.switchToViewSync(.allFilms)
        r.check("decode-malformed-token", !manager.activeState.showSectionDividers,
                "an unrecognized element [4] is off, not truthy")

        // MARK: Encoding and round trip

        manager.updateShowSectionDividers(true)
        r.check("mutator-applies", manager.activeState.showSectionDividers,
                "updateShowSectionDividers(true) is reflected in activeState")

        await awaitDebouncedSave()
        let allFilmsEncoded = Preferences.viewSortStates["allFilms"] ?? []
        r.check("encode-arity", allFilmsEncoded.count == 5,
                "persisted \(allFilmsEncoded.count) elements: \(allFilmsEncoded)")
        r.check("encode-token", allFilmsEncoded.count == 5 && allFilmsEncoded[4] == "dividers",
                "element [4] is the dividers token")

        /// The idempotence guard: a redundant set must not churn storage or reload.
        let beforeNoop = Preferences.viewSortStates
        manager.updateShowSectionDividers(true)
        await awaitDebouncedSave()
        r.check("mutator-idempotent", Preferences.viewSortStates == beforeNoop,
                "setting the value it already holds changed nothing")

        // MARK: Per-view isolation

        /// The purpose of the per-view setting: All Films is on from the mutation above, and a
        /// different view must be entirely unaffected by it — both in memory and on disk.
        manager.switchToViewSync(.unwatched(.unwatched))
        r.check("isolation-other-view-unaffected", !manager.activeState.showSectionDividers,
                "a second view kept its own off setting while All Films is on")

        manager.updateShowSectionDividers(true)
        await awaitDebouncedSave()
        manager.switchToViewSync(.unwatched(.notRated))
        r.check("isolation-third-view-unaffected", !manager.activeState.showSectionDividers,
                "a third view is unaffected by either of the two now switched on")

        manager.switchToViewSync(.allFilms)
        r.check("isolation-round-trip-back", manager.activeState.showSectionDividers,
                "returning to All Films restores its own on setting")

        // MARK: Film Queue per-tab ownership and the "All" tab's lock

        /// The Queue's four tabs share one ViewIdentifier and are told apart only by
        /// ViewStateKey's sub-tab, so these are the checks that prove the key — not the
        /// identifier — is what addresses storage.
        FilmQueueFilterState.shared.selectedFilter = .all
        manager.switchToViewSync(.filmQueue)
        r.check("queue-all-locked-on", manager.activeState.showSectionDividers,
                "the All tab resolves to dividers ON despite a stored OFF")
        r.check("queue-all-reports-locked", manager.sectionDividersLocked,
                "and reports itself as locked, which is what disables the menu pair")

        /// The enforcement half of the lock: the mutator must refuse, so no code path can
        /// write a value the tab cannot honor even with the menu pair disabled.
        manager.updateShowSectionDividers(false)
        r.check("queue-all-refuses-change", manager.activeState.showSectionDividers,
                "updateShowSectionDividers(false) was refused on the locked tab")

        /// A section tab is free, defaults off like any other view, and is unaffected by
        /// the All tab's permanent ON.
        FilmQueueFilterState.shared.selectedFilter = .soon
        manager.switchToViewSync(.filmQueue)
        r.check("queue-section-not-locked", !manager.sectionDividersLocked,
                "a section tab leaves the pair free")
        r.check("queue-section-defaults-off", !manager.activeState.showSectionDividers,
                "an unconfigured section tab starts from the struct default, not the All tab's ON")

        manager.updateShowSectionDividers(true)
        manager.updateSortOption(.rating)
        await awaitDebouncedSave()
        r.check("queue-section-persists-separately",
                Preferences.viewSortStates["filmQueue.soon"]?.count == 5
                    && Preferences.viewSortStates["filmQueue.soon"]?[4] == "dividers"
                    && Preferences.viewSortStates["filmQueue.soon"]?[0] == SortOption.rating.rawValue,
                "the Soon tab wrote its own key: \(Preferences.viewSortStates["filmQueue.soon"] ?? [])")

        /// The two remaining section tabs must be untouched by all of the above — the
        /// isolation the whole feature exists to provide.
        FilmQueueFilterState.shared.selectedFilter = .later
        manager.switchToViewSync(.filmQueue)
        r.check("queue-sibling-unaffected",
                !manager.activeState.showSectionDividers
                    && manager.activeState.sortOption != .rating,
                "the Later tab kept its own defaults while Soon was configured")

        FilmQueueFilterState.shared.selectedFilter = .upNext
        manager.switchToViewSync(.filmQueue)
        r.check("queue-upnext-retained", manager.activeState.sortOption == .duration,
                "the Up Next tab still holds the state it decoded at the top of this run")

        /// And returning to All finds its own locked state, not the last section tab's.
        FilmQueueFilterState.shared.selectedFilter = .all
        manager.switchToViewSync(.filmQueue)
        r.check("queue-all-round-trip",
                manager.activeState.showSectionDividers && manager.sectionDividersLocked,
                "returning to All restores its locked ON")

        // MARK: Remember-preference governance

        /// With the remember preference off, a divider choice must not reach storage — the
        /// same rule every sibling field obeys, and what makes "defaults to off on the next
        /// launch" true rather than merely intended.
        Preferences.rememberSortFilterSelections = false
        manager.switchToViewSync(.smartList(SmartListType.allCases[0]))
        let storedBeforeUnremembered = Preferences.viewSortStates
        manager.updateShowSectionDividers(false)
        r.check("unremembered-applies-in-session", !manager.activeState.showSectionDividers,
                "the choice still takes effect for the running session")
        await awaitDebouncedSave()
        r.check("unremembered-not-persisted",
                Preferences.viewSortStates == storedBeforeUnremembered,
                "nothing was written while rememberSortFilterSelections was off")

        // MARK: Menu reachability

        /// The dividers pair lives inside the Sort menu, so the menu's own seal decides
        /// whether the control is reachable. A view whose Sort menu is fully disabled and
        /// which has no bands would offer no way to turn dividers back ON, which is the
        /// state in which the user most needs the control. The Recents tabs have that shape
        /// (fixed sort, so the menu is always "disabled", and no jump targets while dividers
        /// are off). `supportsSectionDividers` is the third clause that keeps the menu open,
        /// and it must be true for every gallery-backed view.
        for (label, item) in [
            ("allFilms", SidebarItem.libraryItem(.allFilms)),
            ("unwatched", SidebarItem.libraryItem(.unwatched)),
            ("recents", SidebarItem.libraryItem(.recents)),
            ("filmQueue", SidebarItem.libraryItem(.filmQueue)),
            ("search", SidebarItem.libraryItem(.search)),
            ("smartList", SidebarItem.smartList(SmartListType.allCases[0])),
            ("list", SidebarItem.list(UUID())),
        ] {
            r.check("reachable:\(label)", item.capabilities.supportsSectionDividers,
                    "gallery-backed view keeps its Sort menu openable for the dividers pair")
        }

        /// The negative control. Without it every check above could pass on a capability
        /// that is simply hard-wired true, asserting nothing.
        for (label, item) in [
            ("reports", SidebarItem.libraryItem(.reports)),
            ("imports", SidebarItem.libraryItem(.imports)),
        ] {
            r.check("not-reachable:\(label)", !item.capabilities.supportsSectionDividers,
                    "a view that is not gallery-backed still seals its Sort menu as before")
        }

        /// And the clear that STabGeneral performs on disabling the preference must leave
        /// nothing behind for a later launch to read back.
        Preferences.clearViewSortStates()
        r.check("cleared-storage-is-empty", Preferences.viewSortStates.isEmpty,
                "clearViewSortStates left no entry any view could inherit dividers from")

        return r
    }
}


// MARK: - Source for Viewing Ladder
///
/// Proves the three-tier studio spelling in the RightSidebar's "Source for Viewing" field
/// (ReleaseStudio: name / shorthand / abbreviated) and the ladder `fittingValueRow` is handed
/// for it. Pure functions — RSBHelpers.sourceDisplay and SidebarTextAbbreviation.sourceValueLadder
/// — driven through the same entry points WatchDetails uses.
extension DebugHarness {

    private static func sourceLadderScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "source-ladder")

        // MARK: The table
        r.check("shorthand-tier", ReleaseStudio.shorthand("Universal Studios") == "Universal",
                "shorthand for Universal Studios is '\(ReleaseStudio.shorthand("Universal Studios"))'")
        r.check("abbreviated-tier", ReleaseStudio.abbreviated("Universal Studios") == "Uni",
                "abbreviation for Universal Studios is '\(ReleaseStudio.abbreviated("Universal Studios"))'")
        /// A studio with a shorthand but no abbreviation abbreviates to its shorthand.
        r.check("abbreviated-falls-back-to-shorthand",
                ReleaseStudio.abbreviated("Sony Pictures") == ReleaseStudio.shorthand("Sony Pictures"),
                "abbreviated('Sony Pictures') should equal its shorthand")
        /// A studio with neither yields its name at both tiers; so does free text.
        for name in ["Criterion", "Some Boutique Label"] {
            r.check("no-tier-is-identity-\(name)",
                    ReleaseStudio.shorthand(name) == name && ReleaseStudio.abbreviated(name) == name,
                    "'\(name)' was altered by a tier it has no spelling for")
        }
        /// Each entry's tiers never get longer as they descend.
        let monotone = ReleaseStudio.entries.allSatisfy { e in
            let sh = e.shorthand ?? e.name
            let ab = e.abbreviated ?? sh
            return sh.count <= e.name.count && ab.count <= sh.count
        }
        r.check("tiers-never-lengthen", monotone, "a shorthand or abbreviation is longer than the tier above it")

        // MARK: The field
        /// Two purchased Blu-rays from different studios force the studio prefix; the
        /// Universal one scores best by being remastered. The Australian origin forces the
        /// origin token, so every ladder step has something to do.
        let uni = ReleaseSnapshot(studio: "Universal Studios", releaseDate: "2015", purchased: true,
                                  format: ReleaseFormat.bluRay.rawValue, remastered: true,
                                  nationalOrigin: "Australia")
        let wb  = ReleaseSnapshot(studio: "Warner Bros.", releaseDate: "2010", purchased: true,
                                  format: ReleaseFormat.bluRay.rawValue)
        let film = makeSnapshot(name: "Ladder", releases: [uni, wb])
        let display = RSBHelpers.sourceDisplay(for: film)
        log("source-ladder: value='\(display.value)' origin='\(display.originAbbreviatedValue ?? "nil")' "
            + "studio='\(display.studioAbbreviatedValue ?? "nil")' both='\(display.originAndStudioAbbreviatedValue ?? "nil")'")

        r.check("value-uses-shorthand",
                display.value.contains("Universal ") && !display.value.contains("Universal Studios") && !display.value.contains("Uni "),
                "value '\(display.value)' should carry the shorthand, not the name or the abbreviation")
        r.check("studio-alternate-uses-abbreviation",
                display.studioAbbreviatedValue?.contains("Uni ") == true
                    && display.studioAbbreviatedValue?.contains("Universal") == false,
                "studio alternate is '\(display.studioAbbreviatedValue ?? "nil")'")
        r.check("origin-alternate-compacts-origin",
                display.originAbbreviatedValue?.contains("AUS ") == true
                    && display.originAbbreviatedValue?.contains("Universal ") == true,
                "origin alternate is '\(display.originAbbreviatedValue ?? "nil")'")
        r.check("both-alternate-compacts-both",
                display.originAndStudioAbbreviatedValue?.contains("AUS Uni ") == true,
                "both alternate is '\(display.originAndStudioAbbreviatedValue ?? "nil")'")

        let ladder = SidebarTextAbbreviation.sourceValueLadder(
            full: display.value,
            originAbbreviated: display.originAbbreviatedValue,
            studioAbbreviated: display.studioAbbreviatedValue,
            originAndStudioAbbreviated: display.originAndStudioAbbreviatedValue)
        log("source-ladder: ladder = \(ladder)")
        r.check("ladder-has-seven-steps", ladder.count == 7, "ladder has \(ladder.count) steps: \(ladder)")
        r.check("ladder-fits-the-row", ladder.count <= RSBHelpers.maxAbbreviationCandidates,
                "ladder is longer than fittingValueRow can offer")
        r.check("ladder-is-distinct", Set(ladder).count == ladder.count && !ladder.contains(display.value),
                "ladder repeats a step or the full value")
        /// Order: singles, then pairs, then all three — each step gives up no less than the
        /// one before it, so the row never has to choose a bigger retreat over a smaller one.
        func retreats(_ s: String) -> Int {
            (s.contains("rem.") ? 1 : 0) + (s.contains("AUS ") ? 1 : 0) + (s.contains("Uni ") ? 1 : 0)
        }
        let counts = ladder.map(retreats)
        r.check("ladder-order-by-retreat", counts == counts.sorted() && counts.first == 1 && counts.last == 3,
                "ladder retreat counts \(counts) are not non-decreasing 1…3")
        r.check("ladder-studio-single-step", ladder.count > 2 && ladder[2] == display.studioAbbreviatedValue,
                "third step should be the studio alone: \(ladder)")

        /// A single domestic release shows no prefix, so every alternate is nil and the
        /// ladder is only the "remastered" step (or empty without it).
        let plain = makeSnapshot(name: "Plain", releases: [
            ReleaseSnapshot(studio: "Universal Studios", purchased: true, format: ReleaseFormat.bluRay.rawValue)])
        let plainDisplay = RSBHelpers.sourceDisplay(for: plain)
        r.check("no-prefix-no-alternates",
                plainDisplay.originAbbreviatedValue == nil && plainDisplay.studioAbbreviatedValue == nil
                    && plainDisplay.originAndStudioAbbreviatedValue == nil,
                "a single domestic release offered alternates: \(plainDisplay)")
        r.check("no-prefix-empty-ladder",
                SidebarTextAbbreviation.sourceValueLadder(full: plainDisplay.value, originAbbreviated: nil).isEmpty,
                "a value with nothing to shorten offered a ladder")

        /// A studio with no abbreviation contributes no studio step: the studio alternate is
        /// nil and the ladder collapses to the origin/remastered combinations.
        let sonyA = ReleaseSnapshot(studio: "Sony Pictures", releaseDate: "2015", purchased: true,
                                    format: ReleaseFormat.bluRay.rawValue)
        let sonyFilm = makeSnapshot(name: "Sony", releases: [sonyA, wb])
        let sonyDisplay = RSBHelpers.sourceDisplay(for: sonyFilm)
        r.check("no-abbreviation-no-studio-step",
                sonyDisplay.value.contains("Sony ") && sonyDisplay.studioAbbreviatedValue == nil,
                "Sony: value '\(sonyDisplay.value)', studio alternate '\(sonyDisplay.studioAbbreviatedValue ?? "nil")'")

        return r
    }
}


// MARK: - Gallery Focus Handoff
///
/// Proves GalleryFocusIntent end to end for both gallery styles: the REAL GallerySubview
/// (grid) and GalleryListView (list), hosted in an off-screen window, claim first responder
/// for their content view when — and only when — an intent addressed to their view is
/// pending at mount. The search-exit path in MainView is the only producer; what it produces
/// is exercised here exactly as the destination gallery consumes it.
extension DebugHarness {

    private struct GridHost: View {
        let coordinator: DataCoordinator
        var body: some View {
            GallerySubview(scrollRequest: nil, activeViewID: .allFilms,
                           subtitleProvider: nil, showSectionDividers: false,
                           statusBarHeight: StatusBarLayout.resolve(for: .libraryItem(.allFilms),
                                                                    showStatusBar: Preferences.showStatusBar).height)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    private struct ListHost: View {
        let coordinator: DataCoordinator
        var body: some View {
            GalleryListView(activeViewID: .allFilms, scrollRequest: nil,
                            subtitleProvider: nil, showSectionDividers: false,
                            statusBarHeight: StatusBarLayout.resolve(for: .libraryItem(.allFilms),
                                                                     showStatusBar: Preferences.showStatusBar).height)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    /// Mounts `content` in a fresh off-screen window, runs display passes until `settled`
    /// holds (up to 2 s), and reports the first responder that results. A view claims focus
    /// in viewWillDraw and defers the claim a turn further, so the number of turns needed
    /// varies. The claim cases therefore wait on the first responder itself. The intent is
    /// consumed in makeNSView, so waiting on the intent alone stops at the three-turn minimum.
    @MainActor
    private static func mountAndDraw<V: View>(_ content: V, until settled: (NSWindow) -> Bool = { _ in true })
        async -> (window: NSWindow, responder: NSResponder?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        /// viewWillDraw runs in the display pass, not layout; the claim itself is deferred
        /// one further turn from there.
        window.displayIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        var turns = 0
        while turns < 3 || (!settled(window) && Date() < deadline) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
            window.displayIfNeeded()
            turns += 1
        }
        return (window, window.firstResponder)
    }

    private static func galleryFocusHandoffScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "gallery-focus-handoff")
        ViewStateManager.shared.switchToViewSync(.allFilms)

        // MARK: Grid, intent addressed to this view
        GalleryFocusIntent.shared.set(targetViewID: .allFilms)
        var (window, responder) = await mountAndDraw(GridHost(coordinator: coordinator)) {
            $0.firstResponder is GalleryCollectionView
        }
        r.check("grid-claims-focus", responder is GalleryCollectionView,
                "grid first responder is \(String(describing: responder))")
        r.check("grid-consumed-intent", GalleryFocusIntent.shared.targetViewID == nil,
                "intent still pending after the grid mounted")
        window.makeFirstResponder(nil); window.contentView = nil

        // MARK: Grid, intent addressed elsewhere — must be left alone
        GalleryFocusIntent.shared.set(targetViewID: .recents(.recentlyAdded))
        (window, responder) = await mountAndDraw(GridHost(coordinator: coordinator))
        r.check("grid-ignores-foreign-intent", !(responder is GalleryCollectionView),
                "grid took focus from an intent addressed to another view")
        r.check("foreign-intent-survives", GalleryFocusIntent.shared.targetViewID == .recents(.recentlyAdded),
                "an intent addressed elsewhere was consumed")
        GalleryFocusIntent.shared.clear()
        window.makeFirstResponder(nil); window.contentView = nil

        // MARK: Grid, no intent
        (window, responder) = await mountAndDraw(GridHost(coordinator: coordinator))
        r.check("grid-no-intent-no-claim", !(responder is GalleryCollectionView),
                "grid claimed focus with no intent pending")
        window.makeFirstResponder(nil); window.contentView = nil

        // MARK: List, intent addressed to this view
        GalleryFocusIntent.shared.set(targetViewID: .allFilms)
        (window, responder) = await mountAndDraw(ListHost(coordinator: coordinator)) {
            $0.firstResponder is DraggableListTableView
        }
        r.check("list-claims-focus", responder is DraggableListTableView,
                "list first responder is \(String(describing: responder))")
        r.check("list-consumed-intent", GalleryFocusIntent.shared.targetViewID == nil,
                "intent still pending after the list mounted")
        window.makeFirstResponder(nil); window.contentView = nil

        // MARK: Invalidation on a navigation elsewhere
        GalleryFocusIntent.shared.set(targetViewID: .allFilms)
        GalleryFocusIntent.shared.clear(unlessTargeting: .recents(.recentlyAdded))
        r.check("cleared-unless-targeting", GalleryFocusIntent.shared.targetViewID == nil,
                "intent survived a navigation it was not addressed to")
        GalleryFocusIntent.shared.set(targetViewID: .allFilms)
        GalleryFocusIntent.shared.clear(unlessTargeting: .allFilms)
        r.check("kept-when-targeting", GalleryFocusIntent.shared.targetViewID == .allFilms,
                "intent was dropped by the navigation it was addressed to")
        GalleryFocusIntent.shared.clear()

        return r
    }
}

// MARK: - View Switch Probe

/// DEBUG-only event log for the view-switch pipeline: gallery mounts and reloads, and
/// DataCoordinator loads, in the order they happen. Written by probes in 11.00, 23.00,
/// 23.20, 23.30 and 23.60; read by `view-switch-perf`. Inert unless a scenario enables it.
@MainActor
enum ViewSwitchProbe {
    static var isEnabled = false
    private(set) static var events: [String] = []

    static func record(_ event: @autoclosure () -> String) {
        guard isEnabled else { return }
        events.append(event())
    }

    static func reset() { events.removeAll() }
}

// MARK: - Gallery Reuse

/// `gallery-reuse` (opt-in, real main window, reportsCorpus): what the shared gallery (GalleryReuse)
/// must do exactly as the remount it replaced did. Launch with `open -g -n`.
extension DebugHarness {
    static func galleryReuseScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "gallery-reuse")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else {
            r.check("real-window", false, "no app state or main window")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let manager = ViewStateManager.shared
        let maintainBefore = Preferences.maintainScrollPositionOnViewSwitch
        Preferences.maintainScrollPositionOnViewSwitch = true
        defer { Preferences.maintainScrollPositionOnViewSwitch = maintainBefore }

        func grid() -> GalleryCollectionView? { findView(GalleryCollectionView.self, in: window.contentView) }
        func table() -> DraggableListTableView? { findView(DraggableListTableView.self, in: window.contentView) }
        func gridFilmIDs() -> [UUID]? { (grid()?.dataSource as? GallerySubview.Coordinator)?.films.map(\.id) }
        func y() -> CGFloat { (grid()?.enclosingScrollView ?? table()?.enclosingScrollView)?.documentVisibleRect.minY ?? -1 }
        func go(_ item: SidebarItem, _ ms: Int = 900) async { appState.navigate(to: item); await settle(ms) }
        func setStyle(_ list: Bool) async -> Bool {
            let was = manager.activeState.isListView
            if was != list { manager.updateListViewStyle(list); await settle(600) }
            return was
        }

        /// Styles touched below, restored at the end.
        var restoreStyles: [(SidebarItem, Bool)] = []
        await go(.libraryItem(.unwatched))
        restoreStyles.append((.libraryItem(.unwatched), await setStyle(false)))
        await go(.libraryItem(.allFilms))
        restoreStyles.append((.libraryItem(.allFilms), await setStyle(false)))

        // MARK: Instance and content
        let before = grid().map(ObjectIdentifier.init)
        await go(.libraryItem(.unwatched))
        let after = grid().map(ObjectIdentifier.init)
        r.check("instance", before != nil && after != nil && before == after, "grid kept: \(before == after)")
        r.check("content-unwatched", gridFilmIDs() == coordinator.films.map(\.id) && !coordinator.films.isEmpty,
                "grid \(gridFilmIDs()?.count ?? -1) films, coordinator \(coordinator.films.count), view \(manager.activeView)")
        await go(.libraryItem(.allFilms))
        r.check("content-all-films", gridFilmIDs() == coordinator.films.map(\.id) && manager.activeView == .allFilms,
                "grid \(gridFilmIDs()?.count ?? -1) films, coordinator \(coordinator.films.count)")

        // MARK: Keyboard focus leaves with the view
        if let cv = grid() { window.makeFirstResponder(cv) }
        await settle(300)
        SelectionState.shared.selectImmediate(Set<UUID>())
        let hadFocus = window.firstResponder is GalleryCollectionView
        await go(.libraryItem(.unwatched))
        let responder = window.firstResponder
        r.check("focus-released", hadFocus && !(responder is GalleryCollectionView) && !(responder is DraggableListTableView),
                "had focus \(hadFocus), after \(String(describing: responder.map { type(of: $0) }))")
        await go(.libraryItem(.allFilms))

        // MARK: A post-edit scroll target does not follow the switch
        /// Unwatched is banked at the top. An edit to a film deep in it, announced in the same turn
        /// as the switch, must not scroll the destination to that film.
        await go(.libraryItem(.unwatched))
        if let sv = grid()?.enclosingScrollView {
            sv.contentView.setBoundsOrigin(.zero); sv.reflectScrolledClipView(sv.contentView)
        }
        await settle(300)
        let unwatchedIDs = coordinator.films.map(\.id)
        await go(.libraryItem(.allFilms))
        if unwatchedIDs.count > 60 {
            let deep = unwatchedIDs[unwatchedIDs.count * 3 / 4]
            AppEventBus.shared.send(.film(.updated(filmID: deep)))
            appState.navigate(to: .libraryItem(.unwatched))
            await settle(1000)
            r.check("edit-target-dropped", abs(y()) < 1, "unwatched opened at y \(y()) (expected 0)")
            await go(.libraryItem(.allFilms))
        } else {
            r.skip("edit-target-dropped", "unwatched has \(unwatchedIDs.count) films")
        }

        // MARK: Show in List across sidebar items
        let allIDs = coordinator.films.map(\.id)
        let listID = coordinator.createList(name: "Gallery Reuse Probe", displayOrder: 9_000)
        _ = coordinator.addFilmsToList(filmIDs: Set(allIDs.prefix(700)), listID: listID)
        await settle(400)
        await go(.list(listID))
        restoreStyles.append((.list(listID), await setStyle(false)))
        let listOrder = coordinator.films.map(\.id)
        await go(.libraryItem(.allFilms))

        func showInList(_ label: String, filmAt fraction: Double) async {
            guard listOrder.count > 100 else { r.skip(label, "list has \(listOrder.count) films"); return }
            let film = listOrder[Int(Double(listOrder.count) * fraction)]
            SelectionState.shared.selectImmediate([film])
            await settle(300)
            ShowInListNavigation.navigate(to: .list(listID), preserving: film)
            await settle(1200)
            let selected = SelectionState.shared.selectedFilmIDs == [film]
            let onList = manager.activeView == .list(listID)
            var placement = "no gallery"
            var top = false
            if let index = coordinator.films.firstIndex(where: { $0.id == film }) {
                if let cv = grid(), let sv = cv.enclosingScrollView,
                   let frame = cv.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                    let vis = sv.documentVisibleRect
                    top = frame.minY >= vis.minY - 1 && frame.minY - vis.minY < frame.height * 0.6
                    placement = "grid item y \(frame.minY) visible y \(vis.minY)"
                } else if let tv = table(), let sv = tv.enclosingScrollView,
                          tv.numberOfRows == coordinator.films.count {
                    /// No divider rows, so the row is the film's index.
                    let row = tv.rect(ofRow: index)
                    let vis = sv.documentVisibleRect
                    top = row.height > 0 && row.minY >= vis.minY - 1 && row.minY - vis.minY < row.height * 0.6
                    placement = "list row y \(row.minY) visible y \(vis.minY)"
                }
            }
            r.check(label, selected && onList && top && GalleryScrollIntent.shared.filmID == nil,
                    "selected \(selected), on list \(onList), \(placement), intent left \(GalleryScrollIntent.shared.filmID != nil)")
            SelectionState.shared.selectImmediate(Set<UUID>())
            await go(.libraryItem(.allFilms))
        }
        /// Grid to grid: the kept gallery with the flag, a fresh one without.
        await showInList("show-in-list grid→grid", filmAt: 0.66)
        /// Grid to list: a fresh list in both.
        await go(.list(listID)); _ = await setStyle(true); await go(.libraryItem(.allFilms))
        await showInList("show-in-list grid→list", filmAt: 0.5)
        /// List to list: the kept table with the flag.
        _ = await setStyle(true)
        await showInList("show-in-list list→list", filmAt: 0.4)
        _ = await setStyle(false)

        // MARK: Prune flag does not carry to the next view
        /// A selected film removed from the list on screen clears the selection. The grid remembers that, so a
        /// focus return does not reseed item 0 over the clear. The next view must start without it: focusing
        /// All Films' grid with nothing selected seeds its first film.
        await go(.list(listID)); _ = await setStyle(false)
        if let victim = coordinator.films.first?.id {
            SelectionState.shared.selectImmediate([victim])
            await settle(300)
            coordinator.removeFilmsFromList(filmIDs: [victim], listID: listID)
            await settle(800)
            let pruned = SelectionState.shared.selectedFilmIDs.isEmpty
            await go(.libraryItem(.allFilms))
            window.makeFirstResponder(nil)
            await settle(200)
            if let cv = grid() { window.makeFirstResponder(cv) }
            await settle(500)
            let seeded = coordinator.films.first.map { SelectionState.shared.selectedFilmIDs == [$0.id] } ?? false
            r.check("prune-flag-reset", pruned && seeded,
                    "pruned \(pruned), seeded first film on focus \(seeded) (selection \(SelectionState.shared.selectedFilmIDs.count))")
            window.makeFirstResponder(nil)
            SelectionState.shared.selectImmediate(Set<UUID>())
            await settle(300)
        }

        // MARK: An empty list shows its placeholder, not the spinner
        let emptyID = coordinator.createList(name: "Gallery Reuse Empty", displayOrder: 9_001)
        await settle(300)
        await go(.list(emptyID))
        let spinner = findView(NSProgressIndicator.self, in: window.contentView) { !$0.isHiddenOrHasHiddenAncestor }
        r.check("empty-list-placeholder", grid() == nil && table() == nil && spinner == nil && coordinator.films.isEmpty,
                "gallery \(grid() != nil || table() != nil), spinner \(spinner != nil), films \(coordinator.films.count)")
        await go(.libraryItem(.allFilms))
        r.check("after-empty-list", gridFilmIDs() == coordinator.films.map(\.id) && !coordinator.films.isEmpty,
                "grid \(gridFilmIDs()?.count ?? -1) films after leaving an empty list")

        // MARK: Recents summary and back
        await go(.libraryItem(.recents))
        await go(.libraryItem(.allFilms))
        r.check("after-recents", gridFilmIDs() == coordinator.films.map(\.id),
                "grid \(gridFilmIDs()?.count ?? -1) films after Recents")

        // MARK: The scroll-position provider survives another gallery's teardown
        /// An off-screen gallery registers as the provider and clears it when it goes. A remount re-registered at the
        /// next navigation; the shared gallery must too, or the next navigate(to:) banks nothing and a stale origin
        /// comes back (the `scroll-memory` T2 case).
        do {
            let (foreign, _) = await mountAndDraw(GridHost(coordinator: coordinator))
            foreign.contentView = nil
            await settle(200)
            ViewStateManager.shared.switchToViewSync(.allFilms)
            if let sv = grid()?.enclosingScrollView {
                sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: 6000)); sv.reflectScrolledClipView(sv.contentView)
            }
            await settle(300)
            await go(.libraryItem(.unwatched))
            await go(.libraryItem(.allFilms), 1000)
            let restored = y()
            if let sv = grid()?.enclosingScrollView {
                sv.contentView.setBoundsOrigin(.zero); sv.reflectScrolledClipView(sv.contentView)
            }
            await settle(300)
            await go(.libraryItem(.reports), 1000)
            await go(.libraryItem(.allFilms), 1000)
            r.check("provider-after-foreign-gallery", abs(restored - 6000) < 1 && y() < 1,
                    "restored \(restored), back from Reports at \(y()) (expected 0; 6000 = stale bank)")
        }

        // MARK: Clean up
        for (item, wasList) in restoreStyles.reversed() {
            if item == .list(listID) { continue }
            await go(item, 600)
            _ = await setStyle(wasList)
        }
        await go(.libraryItem(.allFilms), 600)
        coordinator.deleteList(listID: listID)
        coordinator.deleteList(listID: emptyID)
        await settle(400)
        return r
    }
}

// MARK: - Switch Coast

/// `switch-coast` (opt-in, real main window, reportsCorpus): a trackpad coast in flight when the view changes must stop
/// there. The incoming view opens at its own position (the top, or its remembered origin) and stays put; the outgoing view
/// keeps the position it was left at. The coast is AppKit's own automated live scroll, the one `coast-stop` uses.
///
/// Each case also runs once without a coast, which gives the position the incoming view should open at. Every gallery
/// switch now reuses the gallery, which coasted on before the stop.
/// `-FTNoSwitchCoastStop` turns the stop off, as a negative control: the reused cases should then fail. Launch with `open -g -n`.
extension DebugHarness {
    static func switchCoastScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "switch-coast")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else {
            r.check("real-window", false, "no app state or main window")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let manager = ViewStateManager.shared
        let maintainBefore = Preferences.maintainScrollPositionOnViewSwitch
        Preferences.maintainScrollPositionOnViewSwitch = true
        defer { Preferences.maintainScrollPositionOnViewSwitch = maintainBefore }

        func sv() -> NSScrollView? {
            findView(GalleryCollectionView.self, in: window.contentView)?.enclosingScrollView
                ?? findView(DraggableListTableView.self, in: window.contentView)?.enclosingScrollView
        }
        func y() -> CGFloat { sv()?.documentVisibleRect.minY ?? -1 }
        func setY(_ v: CGFloat) {
            guard let s = sv() else { return }
            s.contentView.setBoundsOrigin(NSPoint(x: 0, y: v)); s.reflectScrolledClipView(s.contentView)
        }
        func go(_ item: SidebarItem, _ ms: Int = 900) async { appState.navigate(to: item); await settle(ms) }
        func setStyle(_ list: Bool) async -> Bool {
            let was = manager.activeState.isListView
            if was != list { manager.updateListViewStyle(list); await settle(700) }
            return was
        }

        /// One case: `leave` switches from the view on screen to the incoming one, `back` returns. The incoming view's
        /// remembered origin is set to `incomingY` first.
        func runCase(_ label: String, incomingY: CGFloat,
                     leave: () async -> Void, back: () async -> Void) async {
            /// Bank the incoming view's origin, then come back to the outgoing view at a depth.
            await leave(); setY(incomingY); await settle(300); await back()

            /// Without a coast: where the incoming view should open.
            await leave()
            let expected = y()
            await back()
            /// AppKit's automated coast starts from the top.
            setY(0); await settle(400)

            guard let source = sv(), source.responds(to: automateSelector) else {
                r.check("\(label)", false, "no scroll view or no automation")
                return
            }
            let probe = LiveScrollProbe(source)
            defer { probe.detach() }
            _ = unsafe source.perform(automateSelector)
            for _ in 0..<40 where !(probe.isLive && y() > 300) { await settle(20) }
            let coasting = probe.isLive
            let atSwitch = y()
            await leave()
            let target = sv()
            func ty() -> CGFloat { target?.documentVisibleRect.minY ?? -1 }
            await settle(10)
            let y0 = ty()
            await settle(150)
            let y150 = ty()
            await settle(600)
            let y750 = ty()
            let sameScrollView = target === source
            r.check("\(label) coast-running", coasting && atSwitch > 300,
                    "live \(coasting), y \(atSwitch) at the switch")
            r.check("\(label) incoming-holds", abs(y150 - expected) < 1 && abs(y750 - expected) < 1,
                    "expected \(expected); y \(y0) → \(y150) → \(y750) (reused scroll view \(sameScrollView))")
            r.check("\(label) coast-ended", !probe.isLive || !sameScrollView, "live \(probe.isLive)")
            if probe.isLive { stopAutomatedCoast(source) }
            await settle(300)
            await back()
            let returned = y()
            r.check("\(label) outgoing-kept", abs(returned - atSwitch) < 400 && returned > 100,
                    "left at about \(atSwitch), back at \(returned)")
        }

        await go(.libraryItem(.unwatched))
        let unwatchedWasList = await setStyle(false)
        await go(.libraryItem(.allFilms))
        let allWasList = await setStyle(false)

        /// Sidebar, grid to grid: the shared gallery.
        for incoming in [CGFloat(0), 1500] {
            await runCase("sidebar-grid incoming \(Int(incoming))", incomingY: incoming,
                          leave: { await go(.libraryItem(.unwatched)) },
                          back: { await go(.libraryItem(.allFilms)) })
        }

        /// Sidebar, list to list.
        await go(.libraryItem(.unwatched)); _ = await setStyle(true)
        await go(.libraryItem(.allFilms)); _ = await setStyle(true)
        await runCase("sidebar-list incoming 600", incomingY: 600,
                      leave: { await go(.libraryItem(.unwatched)) },
                      back: { await go(.libraryItem(.allFilms)) })
        await go(.libraryItem(.unwatched)); _ = await setStyle(unwatchedWasList)
        await go(.libraryItem(.allFilms)); _ = await setStyle(allWasList)

        /// Sub-tab: two Unwatched tabs, the same gallery in both settings. The outgoing tab needs depth to coast.
        let tabs = UnwatchedCategory.allCases
        await go(.libraryItem(.unwatched))
        var counts: [(UnwatchedCategory, Int)] = []
        for tab in tabs {
            UnwatchedState.shared.selectCategory(tab, immediate: true); await settle(500)
            counts.append((tab, coordinator.films.count))
        }
        let deep = counts.sorted { $0.1 > $1.1 }
        if deep.count >= 2, deep[0].1 > 150, deep[1].1 > 0 {
            let (outTab, inTab) = (deep[0].0, deep[1].0)
            await runCase("subtab \(outTab.rawValue) → \(inTab.rawValue)", incomingY: 0,
                          leave: { UnwatchedState.shared.selectCategory(inTab, immediate: true); await settle(900) },
                          back: { UnwatchedState.shared.selectCategory(outTab, immediate: true); await settle(900) })
            UnwatchedState.shared.selectCategory(tabs[0], immediate: true); await settle(400)
        } else {
            r.skip("subtab", "Unwatched tabs too short: \(counts.map { "\($0.0.rawValue)=\($0.1)" })")
        }
        await go(.libraryItem(.allFilms), 600)
        return r
    }
}

// MARK: - View Switch Perf

/// `view-switch-perf` (opt-in, a measurement): sidebar navigation between gallery-backed views
/// in the REAL main window, on a library-sized corpus. Per switch it records the main-thread
/// busy stretches (same recorder as `reports-hitch`) and the probe event sequence: which
/// gallery style mounted, for which view, holding how many films, and how many loads and
/// reloads the switch cost. Launch with `open -g -n`.
extension DebugHarness {
    static func viewSwitchPerfScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "view-switch-perf")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        r.check("real-window", window != nil, "")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        let manager = ViewStateManager.shared
        let smart: SidebarItem = .smartList(SmartListType.sidebarCases.first!)
        /// Put one destination in list style so grid⟷list crossings are measured too.
        appState.navigate(to: smart)
        await settle(800)
        let smartWasList = manager.activeState.isListView
        manager.updateListViewStyle(true)
        await settle(800)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(800)
        let allWasList = manager.activeState.isListView
        manager.updateListViewStyle(false)
        await settle(800)

        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        ViewSwitchProbe.isEnabled = true
        defer { ViewSwitchProbe.isEnabled = false }

        /// FT_VS_LOOP=<grid|list|recents> and FT_VS_LOOP_SECONDS=n (default 20): before measuring, switch between All
        /// Films and that destination for n seconds, for `sample` or Instruments to profile the switch alone.
        if let loop = ProcessInfo.processInfo.environment["FT_VS_LOOP"] {
            let seconds = Double(ProcessInfo.processInfo.environment["FT_VS_LOOP_SECONDS"] ?? "") ?? 20
            let target: SidebarItem
            switch loop {
            case "list": target = smart
            case "recents": target = .libraryItem(.recents)
            default: target = .libraryItem(.unwatched)
            }
            let end = CACurrentMediaTime() + seconds
            var count = 0
            while CACurrentMediaTime() < end {
                appState.navigate(to: target); await settle(250)
                appState.navigate(to: .libraryItem(.allFilms)); await settle(250)
                count += 2
            }
            r.check("loop \(loop)", true, "\(count) switches in \(seconds) s")
        }

        var byKind: [String: [RunLoopBusyRecorder.Reading]] = [:]
        var sequences: [String: String] = [:]
        func measure(_ kind: String, to item: SidebarItem) async {
            await settle(500)
            recorder.reset()
            ViewSwitchProbe.reset()
            let t0 = CACurrentMediaTime() * 1000
            appState.navigate(to: item)
            await settle(800)
            byKind[kind, default: []].append(recorder.reading(from: t0, window: 800))
            sequences[kind] = ViewSwitchProbe.events.joined(separator: " | ")
        }

        for _ in 0..<3 {
            await measure("grid→grid", to: .libraryItem(.unwatched))
            await measure("grid→grid(back)", to: .libraryItem(.allFilms))
            await measure("grid→list", to: smart)
            await measure("list→grid", to: .libraryItem(.allFilms))
        }

        /// What reusing one gallery across views would save: an in-place switch (a Recents tab to another, the
        /// gallery kept and reloaded) against a remount of about the same size (All Films to Unwatched).
        RecentsState.shared.selectCategory(.recentlyAdded, immediate: true)
        appState.navigate(to: .libraryItem(.recents))
        await settle(800)
        for _ in 0..<4 {
            for category in [RecentsCategory.recentlyViewed, .recentlyAdded] {
                await settle(500)
                recorder.reset()
                let t0 = CACurrentMediaTime() * 1000
                RecentsState.shared.selectCategory(category, immediate: true)
                await settle(800)
                byKind["inplace-recents", default: []].append(recorder.reading(from: t0, window: 800))
            }
        }
        r.check("inplace-films", true, "recents tab films \(coordinator.films.count)")
        /// Back to the summary tab while here, then away, so "to-recents" below opens the summary as before.
        RecentsState.shared.selectCategory(.summary, immediate: true)
        await settle(600)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(800)

        /// In-place sub-tab switches: the gallery stays mounted and must reload exactly once.
        await measure("to-recents", to: .libraryItem(.recents))
        /// The summary tab mounts its own view, so the first category tab legitimately mounts a fresh gallery.
        var previousWasEmpty = true
        /// The category tabs only. The summary tab mounts a different view (RecentsSummaryView).
        for c in RecentsCategory.sections.reversed() {
            await settle(400)
            ViewSwitchProbe.reset()
            RecentsState.shared.selectCategory(c, immediate: true)
            await settle(500)
            let reloads = ViewSwitchProbe.events.filter { $0.hasPrefix("grid.reload") || $0.hasPrefix("list.reload") }
            let makes = ViewSwitchProbe.events.filter { $0.contains(".make") }
            /// A category with no films shows a placeholder and unmounts the gallery, so
            /// the next non-empty one legitimately mounts a fresh one.
            r.check("recents-subtab-single-reload \(c.rawValue)", reloads.count <= 1 && (makes.isEmpty || previousWasEmpty),
                    ViewSwitchProbe.events.joined(separator: " | "))
            let loadMs = ViewSwitchProbe.events.first { $0.hasPrefix("load ") }
                .flatMap { $0.split(separator: " ").last }.map(String.init) ?? "?"
            r.check("recents-load-time \(c.rawValue)", true, "films=\(coordinator.films.count) \(loadMs)")
            previousWasEmpty = coordinator.films.isEmpty
        }

        /// Scroll-origin round trip, long view → short view → back, with the preference on.
        let maintainBefore = Preferences.maintainScrollPositionOnViewSwitch
        Preferences.maintainScrollPositionOnViewSwitch = true
        defer { Preferences.maintainScrollPositionOnViewSwitch = maintainBefore }
        func galleryScrollView() -> NSScrollView? {
            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView, s.documentView is GalleryCollectionView { return s }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            return window?.contentView.flatMap(find)
        }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(800)
        if let sv = galleryScrollView() {
            let target = NSPoint(x: 0, y: 6000)
            sv.contentView.scroll(to: target)
            sv.reflectScrolledClipView(sv.contentView)
            await settle(300)
            let before = sv.documentVisibleRect.origin.y
            appState.navigate(to: .libraryItem(.unwatched))
            await settle(800)
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(1000)
            let after = galleryScrollView()?.documentVisibleRect.origin.y ?? -1
            r.check("origin-round-trip", abs(after - before) < 1, "before \(before) after \(after)")

            /// Through a search session: entry replaces the films under the still-mounted
            /// All Films grid, which must not bank a viewport clamped to the results.
            if let sv2 = galleryScrollView() {
                sv2.contentView.scroll(to: NSPoint(x: 0, y: 6000))
                sv2.reflectScrolledClipView(sv2.contentView)
            }
            await settle(300)
            let beforeSearch = galleryScrollView()?.documentVisibleRect.origin.y ?? -1
            SearchController.shared.searchText = "a"
            await settle(1200)
            let inSearch = appState.selectedSidebarItem == .libraryItem(.search)
            let resultCount = coordinator.films.count
            SearchController.shared.clearSearch()
            await settle(1200)
            let afterSearch = galleryScrollView()?.documentVisibleRect.origin.y ?? -1
            r.check("origin-search-round-trip", inSearch && abs(afterSearch - beforeSearch) < 1,
                    "entered search \(inSearch), before \(beforeSearch) after \(afterSearch), results \(resultCount)")
        } else {
            r.check("origin-round-trip", false, "no grid scroll view found")
        }

        for (kind, readings) in byKind.sorted(by: { $0.key < $1.key }) {
            r.metric("\(kind)-first-median", stats(readings.map(\.first)).median, "ms")
            r.metric("\(kind)-busy-median", stats(readings.map(\.busy)).median, "ms")
            r.metric("\(kind)-longest-median", stats(readings.map(\.longest)).median, "ms")
            r.check("sequence \(kind)", true, sequences[kind] ?? "")
        }

        appState.navigate(to: smart); await settle(500)
        manager.updateListViewStyle(smartWasList); await settle(500)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(500)
        manager.updateListViewStyle(allWasList); await settle(500)
        return r
    }
}


// MARK: - Shared Search Gallery

/// `shared-search` (opt-in, real main window, reportsCorpus): search entry and exit through the shared gallery
/// (GalleryReuse). Search is an in-place view switch: the gallery stays mounted on entry, exit and token entry,
/// and the scroll and focus handoffs land on its update pass. Launch with `open -g -n`.
extension DebugHarness {
    static func sharedSearchScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "shared-search")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else {
            r.check("real-window", false, "no app state or main window")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let manager = ViewStateManager.shared
        let search = SearchController.shared
        let maintainBefore = Preferences.maintainScrollPositionOnViewSwitch
        let preserveBefore = Preferences.maintainSelectionOnSearchExit
        Preferences.maintainScrollPositionOnViewSwitch = true
        defer {
            Preferences.maintainScrollPositionOnViewSwitch = maintainBefore
            Preferences.maintainSelectionOnSearchExit = preserveBefore
        }

        func grid() -> GalleryCollectionView? { findView(GalleryCollectionView.self, in: window.contentView) }
        func table() -> DraggableListTableView? { findView(DraggableListTableView.self, in: window.contentView) }
        func galleryID() -> ObjectIdentifier? { grid().map(ObjectIdentifier.init) ?? table().map(ObjectIdentifier.init) }
        func gridFilmIDs() -> [UUID]? { (grid()?.dataSource as? GallerySubview.Coordinator)?.films.map(\.id) }
        func scrollView() -> NSScrollView? { grid()?.enclosingScrollView ?? table()?.enclosingScrollView }
        func y() -> CGFloat { scrollView()?.documentVisibleRect.minY ?? -1 }
        func scroll(to y: CGFloat) {
            guard let sv = scrollView() else { return }
            sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
        }
        func go(_ item: SidebarItem, _ ms: Int = 900) async { appState.navigate(to: item); await settle(ms) }
        func setStyle(_ list: Bool) async -> Bool {
            let was = manager.activeState.isListView
            if was != list { manager.updateListViewStyle(list); await settle(600) }
            return was
        }
        func enter(_ query: String = "e", _ ms: Int = 1200) async { search.searchText = query; await settle(ms) }
        func exit(_ ms: Int = 1200) async { search.clearSearch(); await settle(ms) }
        var inSearch: Bool { appState.selectedSidebarItem == .libraryItem(.search) && manager.activeView == .search }
        /// Whether `film` sits in the top row of the gallery on screen.
        func atTop(_ film: UUID) -> (Bool, String) {
            guard let index = coordinator.films.firstIndex(where: { $0.id == film }) else { return (false, "film not loaded") }
            if let cv = grid(), let sv = cv.enclosingScrollView,
               let frame = cv.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                let vis = sv.documentVisibleRect
                return (frame.minY >= vis.minY - 1 && frame.minY - vis.minY < frame.height * 0.6,
                        "grid item y \(frame.minY) visible y \(vis.minY)")
            }
            if let tv = table(), let sv = tv.enclosingScrollView, tv.numberOfRows == coordinator.films.count {
                let row = tv.rect(ofRow: index)
                let vis = sv.documentVisibleRect
                return (row.height > 0 && row.minY >= vis.minY - 1 && row.minY - vis.minY < row.height * 0.6,
                        "list row y \(row.minY) visible y \(vis.minY)")
            }
            return (false, "no gallery")
        }
        var galleryHasFocus: Bool {
            window.firstResponder is GalleryCollectionView || window.firstResponder is DraggableListTableView
        }

        await go(.libraryItem(.allFilms))
        let allWasList = await setStyle(false)
        ViewSwitchProbe.isEnabled = true
        defer { ViewSwitchProbe.isEnabled = false }

        // MARK: Entry: instance, content, one reload
        scroll(to: 6000); await settle(300)
        let bankedY = y()
        let before = galleryID()
        ViewSwitchProbe.reset()
        await enter()
        let entryEvents = ViewSwitchProbe.events
        let after = galleryID()
        let entryMakes = entryEvents.filter { $0.contains(".make") }.count
        let entryReloads = entryEvents.filter { $0.hasPrefix("grid.reload") || $0.hasPrefix("list.reload") }.count
        r.check("entered", inSearch && coordinator.films.count > 50, "in search \(inSearch), results \(coordinator.films.count)")
        r.check("instance", before != nil && before == after, "gallery kept \(before == after)")
        r.check("content-search", gridFilmIDs() == coordinator.films.map(\.id), "grid \(gridFilmIDs()?.count ?? -1), coordinator \(coordinator.films.count)")
        r.check("entry-one-reload", entryMakes == 0 && entryReloads == 1,
                "makes \(entryMakes), reloads \(entryReloads): \(entryEvents.joined(separator: " | "))")
        r.check("search-starts-at-top", abs(y()) < 1, "search opened at y \(y())")

        // MARK: Typing narrows in place
        let typingBefore = galleryID()
        await enter("ea", 900)
        r.check("typing-in-place", inSearch && galleryID() == typingBefore && gridFilmIDs() == coordinator.films.map(\.id),
                "gallery kept \(galleryID() == typingBefore), results \(coordinator.films.count)")

        // MARK: Plain exit restores the banked origin and clears the selection
        Preferences.maintainSelectionOnSearchExit = false
        if let some = coordinator.films.first?.id { SelectionState.shared.selectImmediate([some]) }
        await settle(200)
        await exit()
        r.check("exit-plain", manager.activeView == .allFilms && gridFilmIDs() == coordinator.films.map(\.id)
                    && SelectionState.shared.selectedFilmIDs.isEmpty,
                "view \(manager.activeView), selection \(SelectionState.shared.selectedFilmIDs.count)")
        r.check("exit-origin-restored", abs(y() - bankedY) < 1, "y \(y()), banked \(bankedY)")

        // MARK: Exit with a preserved selection: top row and keyboard focus, grid
        func preservingExit(_ label: String) async {
            Preferences.maintainSelectionOnSearchExit = true
            await enter()
            let results = coordinator.films.map(\.id)
            guard results.count > 40 else { r.skip(label, "\(results.count) results"); return }
            let film = results[results.count * 3 / 4]
            SelectionState.shared.selectImmediate([film])
            /// Focus in the search field, as after typing: nothing in the gallery holds it.
            window.makeFirstResponder(nil)
            await settle(300)
            ViewSwitchProbe.reset()
            await exit(1500)
            let (top, placement) = atTop(film)
            let selected = SelectionState.shared.selectedFilmIDs == [film]
            r.check(label, manager.activeView == .allFilms && selected && top && galleryHasFocus
                        && GalleryScrollIntent.shared.filmID == nil && GalleryFocusIntent.shared.targetViewID == nil,
                    "selected \(selected), \(placement), focus \(String(describing: window.firstResponder.map { type(of: $0) })), "
                    + "intents left \(GalleryScrollIntent.shared.filmID != nil)/\(GalleryFocusIntent.shared.targetViewID != nil); "
                    + ViewSwitchProbe.events.joined(separator: " | "))
            SelectionState.shared.selectImmediate(Set<UUID>())
            window.makeFirstResponder(nil)
            scroll(to: 0)
            await settle(300)
        }
        await preservingExit("exit-preserve grid")

        // MARK: List style: the seed and the preserved exit
        _ = await setStyle(true)
        let listBefore = galleryID()
        await enter()
        r.check("style-seeded-list", inSearch && table() != nil && manager.activeState.isListView
                    && galleryID() == listBefore,
                "table \(table() != nil), list \(manager.activeState.isListView), kept \(galleryID() == listBefore)")
        await exit()
        await preservingExit("exit-preserve list")
        _ = await setStyle(false)

        // MARK: Token entry keeps the gallery mounted and shows the placeholder state
        func postTab() {
            if let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "\t", charactersIgnoringModifiers: "\t",
                                          isARepeat: false, keyCode: 48) {
                NSApp.postEvent(tab, atStart: false)
            }
        }
        await enter()
        /// Positive control: with results showing, Tab (KeyboardManager's route) focuses the gallery. Without it the
        /// token-entry Tab check below proves nothing (a background launch has no key window, so the route is off).
        window.makeFirstResponder(nil)
        postTab(); await settle(400)
        let tabReachesGallery = galleryHasFocus
        window.makeFirstResponder(nil)
        SelectionState.shared.selectImmediate(Set<UUID>())
        await settle(200)
        let tokenBefore = galleryID()
        search.searchText = "#ti"
        await settle(600)
        let entering = search.isEnteringFirstToken
        r.check("token-entry", inSearch && entering && galleryID() != nil && galleryID() == tokenBefore,
                "entering \(entering), gallery \(galleryID() != nil), kept \(galleryID() == tokenBefore)")
        /// The hidden gallery must take no clicks or scrolls: a hit test at its center lands outside it.
        if let sv = scrollView(), let content = window.contentView {
            let center = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
            let hit = content.hitTest(content.convert(center, from: nil).applying(.identity))
            let lands = hit.map { $0 === sv || $0.isDescendant(of: sv) } ?? false
            r.check("token-entry-no-hits", !lands, "hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        } else {
            r.check("token-entry-no-hits", false, "no gallery mounted")
        }
        /// The predicate KeyboardManager's Tab route and the cover both read: on for search during token entry only.
        r.check("token-entry-hidden-predicate", GalleryReuse.hidesForTokenEntry(.libraryItem(.search))
                    && !GalleryReuse.hidesForTokenEntry(.libraryItem(.allFilms)),
                "search \(GalleryReuse.hidesForTokenEntry(.libraryItem(.search))), all films \(GalleryReuse.hidesForTokenEntry(.libraryItem(.allFilms)))")
        /// Tab must not focus the hidden gallery (and so seed a selection nobody can see).
        if tabReachesGallery {
            postTab(); await settle(400)
            r.check("token-entry-tab-inert", !galleryHasFocus && SelectionState.shared.selectedFilmIDs.isEmpty,
                    "focus \(String(describing: window.firstResponder.map { type(of: $0) })), selection \(SelectionState.shared.selectedFilmIDs.count)")
            window.makeFirstResponder(nil)
        } else {
            r.skip("token-entry-tab-inert", "Tab does not reach the visible gallery here (no key window)")
        }
        search.searchText = "e"
        await settle(900)
        let stillHidden = GalleryReuse.hidesForTokenEntry(.libraryItem(.search))
        r.check("token-entry-predicate-off", !stillHidden, "hidden after the token entry ended: \(stillHidden)")
        r.check("token-entry-back", inSearch && gridFilmIDs() == coordinator.films.map(\.id),
                "grid \(gridFilmIDs()?.count ?? -1), results \(coordinator.films.count)")
        /// Text before the "#" has already narrowed the results: token entry keeps them in view, uncovered.
        let narrowed = coordinator.films.map(\.id)
        search.searchText = "e #ti"
        await settle(600)
        let coveredAfterText = GalleryReuse.hidesForTokenEntry(.libraryItem(.search))
        r.check("token-entry-after-text-shown", search.isEnteringToken && !coveredAfterText
                    && gridFilmIDs() == narrowed,
                "entering \(search.isEnteringToken), covered \(coveredAfterText), grid \(gridFilmIDs()?.count ?? -1), held \(narrowed.count)")
        search.searchText = "e"
        await settle(600)
        await exit()

        // MARK: Show in List from search
        /// The list is built from the search results, so the film is in both whatever the library holds
        /// (scenarios run before this one import the corpus again).
        await enter()
        let searchResults = coordinator.films.map(\.id)
        await exit()
        let listID = coordinator.createList(name: "Shared Search Probe", displayOrder: 9_002)
        _ = coordinator.addFilmsToList(filmIDs: Set(searchResults.prefix(600)), listID: listID)
        await settle(400)
        await go(.list(listID)); let listWasList = await setStyle(false)
        let listOrder = coordinator.films.map(\.id)
        await go(.libraryItem(.allFilms))
        await enter()
        if listOrder.count > 300, let film = Optional(listOrder[listOrder.count * 2 / 3]),
           coordinator.films.contains(where: { $0.id == film }) {
            SelectionState.shared.selectImmediate([film])
            await settle(300)
            ShowInListNavigation.navigate(to: .list(listID), preserving: film)
            await settle(1400)
            let (top, placement) = atTop(film)
            r.check("show-in-list from search", manager.activeView == .list(listID) && SelectionState.shared.selectedFilmIDs == [film]
                        && top && GalleryScrollIntent.shared.filmID == nil,
                    "view \(manager.activeView), \(placement), intent left \(GalleryScrollIntent.shared.filmID != nil)")
            SelectionState.shared.selectImmediate(Set<UUID>())
        } else {
            r.skip("show-in-list from search", "no deep list film in the results")
        }
        search.clearSearch(); await settle(600)

        // MARK: From and back to Reports
        await go(.libraryItem(.reports), 1200)
        await enter()
        r.check("from-reports", inSearch && gridFilmIDs() == coordinator.films.map(\.id),
                "in search \(inSearch), grid \(gridFilmIDs()?.count ?? -1)")
        await exit()
        r.check("back-to-reports", appState.selectedSidebarItem == .libraryItem(.reports) && grid() == nil && table() == nil,
                "item \(appState.selectedSidebarItem)")
        await go(.libraryItem(.allFilms))
        r.check("after-reports", gridFilmIDs() == coordinator.films.map(\.id), "grid \(gridFilmIDs()?.count ?? -1)")

        // MARK: Timing
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        var entries: [Double] = [], exits: [Double] = []
        for _ in 0..<5 {
            await settle(500)
            recorder.reset()
            var t0 = CACurrentMediaTime() * 1000
            search.searchText = "e"
            await settle(1000)
            entries.append(recorder.reading(from: t0, window: 1000).first)
            await settle(400)
            recorder.reset()
            t0 = CACurrentMediaTime() * 1000
            search.clearSearch()
            await settle(1000)
            exits.append(recorder.reading(from: t0, window: 1000).first)
        }
        recorder.stop()
        r.metric("entry-first-median", stats(entries).median, "ms")
        r.metric("exit-first-median", stats(exits).median, "ms")
        r.check("timings", true, "entry \(entries.map { Int($0) }), exit \(exits.map { Int($0) })")

        // MARK: Clean up
        await go(.list(listID), 600); _ = await setStyle(listWasList)
        await go(.libraryItem(.allFilms), 600); _ = await setStyle(allWasList)
        coordinator.deleteList(listID: listID)
        await settle(400)
        return r
    }
}

// MARK: - Gallery Integrity
///
/// `gallery-integrity` (opt-in; seeds 60 films, so it is kept out of `all`): behaviors of
/// both gallery styles that no other scenario reaches, each driven through the REAL
/// GallerySubview / GalleryListView hosted in an off-screen window —
///
///   • Cmd+A delivered straight to either gallery style selects every film in a sub-tab view
///     (Unwatched, Recents), as ViewCapabilities.supportsMultiSelection says every gallery view does.
///   • A dismantled gallery's selection-observation loop never acts again.
///   • The grid tile's placeholder fill and the divider band's rule follow appearance changes.
///   • Keyboard focus never seeds item 0 over a selection that landed in the same turn.
///   • Cmd+L places the topmost selected film in the top row in BOTH styles.
extension DebugHarness {

    private struct IntegrityGridHost: View {
        let coordinator: DataCoordinator
        let viewID: ViewIdentifier
        var body: some View {
            GallerySubview(scrollRequest: nil, activeViewID: viewID,
                           subtitleProvider: nil, showSectionDividers: false,
                           statusBarHeight: StatusBarLayout.resolve(for: .libraryItem(.allFilms),
                                                                    showStatusBar: Preferences.showStatusBar).height)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    private struct IntegrityListHost: View {
        let coordinator: DataCoordinator
        let viewID: ViewIdentifier
        var body: some View {
            GalleryListView(activeViewID: viewID, scrollRequest: nil,
                            subtitleProvider: nil, showSectionDividers: false,
                            statusBarHeight: StatusBarLayout.resolve(for: .libraryItem(.allFilms),
                                                                     showStatusBar: Preferences.showStatusBar).height)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    // MARK: - Scenario: Sidebar Tags

    /// The sidebar's Tags section on the sandbox library, in the real main window. Not in any
    /// suite; run by name.
    ///
    /// - Every tag's films (SidebarTags.filmIDs, read from MetadataCache's stored keys) and the
    ///   ranking (SidebarTags.mostUsed) equal a naive recount that folds every tag afresh.
    /// - A tag's view shows exactly its films.
    /// - Respelling a tag on every film that carries it (a case-only change) while its view is
    ///   open keeps the view, its sidebar highlight and its films; navigating to the new
    ///   spelling is no transition (SidebarTag compares by key).
    /// - A film that loses the tag leaves the open view; hiding the section returns to All Films.
    /// - Metrics: the cached-key and naive costs of a membership and a ranking, on this library.
    static func sidebarTagsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sidebar-tags")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else {
            r.check("real-window", false, "no app state or main window")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func ms(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            return milliseconds(ContinuousClock.now - start)
        }
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            (0..<runs).map { _ in ms(body) }.sorted()[runs / 2]
        }
        let countBefore = Preferences.showTagsInSidebar
        Preferences.showTagsInSidebar = .ten
        defer { Preferences.showTagsInSidebar = countBefore }
        await settle(600)

        /// The rule, folded afresh: a film carries a tag when one of its tags has its key.
        func naiveIDs(_ key: String, _ films: [FilmSnapshot]) -> Set<UUID> {
            Set(films.filter { $0.tags.contains { SearchText.key($0) == key } }.map(\.id))
        }
        func naiveRanking(_ films: [FilmSnapshot]) -> [String] {
            var spellings: [String: [String: Int]] = [:]
            for film in films {
                var seen: Set<String> = []
                for tag in film.tags {
                    let key = SearchText.key(tag)
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    spellings[key, default: [:]][tag.trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
                }
            }
            var counted: [(key: String, display: String, uses: Int)] = []
            for (key, uses) in spellings {
                let best = uses.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                counted.append((key, best?.key ?? key, uses.values.reduce(0, +)))
            }
            counted.sort { $0.uses != $1.uses ? $0.uses > $1.uses : $0.key < $1.key }
            return counted.map(\.display)
        }

        // Correctness on the whole library.
        let films = coordinator.getAllFilms()
        let tagged = films.filter { !$0.tags.isEmpty }
        let uncached = tagged.filter { film in
            guard let keys = MetadataCache.shared.getTextSearchKeys(for: film.id)?.tags else { return true }
            return keys.split(separator: "\n", omittingEmptySubsequences: false).count != film.tags.count
        }
        r.check("library/has-tags", !tagged.isEmpty, "\(films.count) films, \(tagged.count) tagged")
        r.check("library/cache-covers-tagged-films", uncached.isEmpty,
                "\(uncached.count) tagged film(s) fall back to folding")
        let ranking = SidebarTags.mostUsed(Int.max, in: coordinator)
        r.check("ranking/equals-naive", ranking == naiveRanking(films), "\(ranking.count) tags")
        var mismatched: [String] = []
        for name in ranking {
            let tag = SidebarTag(name)
            if SidebarTags.filmIDs(taggedWith: tag, in: films) != naiveIDs(tag.key, films) { mismatched.append(name) }
        }
        r.check("membership/every-tag-equals-naive", mismatched.isEmpty,
                mismatched.isEmpty ? "\(ranking.count) tags" : mismatched.prefix(5).joined(separator: ", "))
        r.check("identity/persistence-key-shared",
                ViewIdentifier.tag(SidebarTag("Film Noir")).persistenceKey == ViewIdentifier.tag(SidebarTag(" FILM  noir ")).persistenceKey
                    && SidebarItem.tag(SidebarTag("Noir")) == SidebarItem.tag(SidebarTag("NOIR")))

        // Costs.
        if let top = ranking.first {
            let tag = SidebarTag(top)
            r.metric("membership/cached-keys", median(7) { _ = SidebarTags.filmIDs(taggedWith: tag, in: films) }, "ms")
            r.metric("membership/naive-fold", median(7) { _ = naiveIDs(tag.key, films) }, "ms")
            r.metric("membership/resolve-full", median(7) { _ = coordinator.viewHasFilmsBeforeFilters(.tag(tag)) }, "ms")
        }
        r.metric("ranking/naive-fold", median(5) { _ = naiveRanking(films) }, "ms")
        r.metric("ranking/cached-hit", median(7) { _ = SidebarTags.mostUsed(10, in: coordinator) }, "ms")

        // The drift subject: a top-ten tag in one spelling on few enough films to respell quickly.
        let top10 = Array(ranking.prefix(10))
        func carriers(_ key: String) -> [FilmSnapshot] {
            coordinator.getAllFilms().filter { $0.tags.contains { SearchText.key($0) == key } }
        }
        guard let subject = top10.reversed().first(where: { name in
                  let list = carriers(SidebarTag(name).key)
                  return list.count <= 80 && list.count >= 2
                      && name.uppercased() != name
                      && list.allSatisfy { $0.tags.contains(name) }
              })
        else {
            r.skip("drift", "no top-ten tag in one spelling on 2–80 films")
            return r
        }
        let tag = SidebarTag(subject)
        let respelled = subject.uppercased()
        r.metric("drift/subject-films", Double(carriers(tag.key).count), "films")

        // Open the tag's view.
        appState.navigate(to: .tag(tag))
        await settle(1200)
        let expected = SidebarTags.filmIDs(taggedWith: tag, in: coordinator.getAllFilms())
        r.check("view/opened", ViewStateManager.shared.activeView == .tag(tag), "\(ViewStateManager.shared.activeView)")
        r.check("view/shows-its-films", Set(coordinator.films.map(\.id)) == expected,
                "shown \(coordinator.films.count), expected \(expected.count)")
        let outline = findView(NSOutlineView.self, in: window.contentView)
        /// The row the sidebar should highlight for `name`: the Tags section is last, its rows in
        /// mostUsed order. The rows are scrolled into view first, since a lazy List row that has
        /// never been drawn cannot take a programmatic selection (seen for every section).
        func tagRowCheck(_ label: String, _ name: String) async {
            guard let outline else { r.check(label, false, "no sidebar outline"); return }
            outline.scrollRowToVisible(outline.numberOfRows - 1)
            await settle(400)
            let shown = SidebarTags.mostUsed(10, in: coordinator)
            guard let index = shown.firstIndex(of: name) else { r.check(label, false, "\(name) not listed"); return }
            let expectedRow = outline.numberOfRows - shown.count + index
            r.check(label, outline.selectedRow == expectedRow,
                    "highlight \(outline.selectedRow), expected \(expectedRow) of \(outline.numberOfRows)")
        }
        /// Control: programmatic navigation to the lowest row above the Tags section (a saved
        /// search or user list) from the top, to tell a tag-only highlight problem from a List one.
        if let outline {
            let lowItem: SidebarItem? = SavedSearchStore.shared.searches.last.map { .savedSearch($0.id) }
                ?? coordinator.cachedLists.last.map { .list($0.listID) }
            if let lowItem {
                appState.navigate(to: .libraryItem(.allFilms))
                outline.scrollRowToVisible(0)
                await settle(900)
                appState.navigate(to: lowItem)
                await settle(1200)
                r.check("control/low-row-programmatic", true,
                        "\(lowItem) → highlight \(outline.selectedRow) of \(outline.numberOfRows)")
            }
            /// Then open the tag as a user does: a click on its row.
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(900)
            outline.scrollRowToVisible(outline.numberOfRows - 1)
            await settle(400)
            let shown = SidebarTags.mostUsed(10, in: coordinator)
            if let index = shown.firstIndex(of: subject) {
                outline.selectRowIndexes([outline.numberOfRows - shown.count + index], byExtendingSelection: false)
            }
            await settle(1200)
        }
        r.check("click/opens-tag", appState.selectedSidebarItem == .tag(tag), "\(appState.selectedSidebarItem)")
        await tagRowCheck("sidebar/row-highlighted", subject)

        // Respell it on every film carrying it.
        for var film in carriers(tag.key) {
            film.tags = film.tags.map { SearchText.key($0) == tag.key ? respelled : $0 }
            await coordinator.updateFilm(film)
        }
        await settle(1500)
        let afterRanking = SidebarTags.mostUsed(10, in: coordinator)
        r.check("drift/row-respelled", afterRanking.contains(respelled) && !afterRanking.contains(subject),
                afterRanking.joined(separator: ", "))
        if case .tag(let open) = appState.selectedSidebarItem {
            r.check("drift/view-kept", open.name == subject && ViewStateManager.shared.activeView == .tag(tag),
                    "open \(open.name), active \(ViewStateManager.shared.activeView)")
        } else {
            r.check("drift/view-kept", false, "left for \(appState.selectedSidebarItem)")
        }
        r.check("drift/films-kept", Set(coordinator.films.map(\.id)) == expected,
                "shown \(coordinator.films.count), expected \(expected.count)")
        await tagRowCheck("drift/row-still-highlighted", respelled)
        appState.navigate(to: .tag(SidebarTag(respelled)))
        await settle(600)
        if case .tag(let open) = appState.selectedSidebarItem {
            r.check("drift/new-spelling-is-same-view", open.name == subject, "open \(open.name)")
        }

        // A film that loses the tag leaves the open view.
        if var leaver = carriers(tag.key).first {
            leaver.tags.removeAll { SearchText.key($0) == tag.key }
            await coordinator.updateFilm(leaver)
            await settle(900)
            r.check("edit/film-leaves-view", !coordinator.films.contains { $0.id == leaver.id }
                        && coordinator.films.count == expected.count - 1,
                    "shown \(coordinator.films.count), expected \(expected.count - 1)")
        }

        // Hiding the section leaves the tag for All Films.
        Preferences.showTagsInSidebar = .hidden
        await settle(900)
        r.check("hide/returns-to-all-films", appState.selectedSidebarItem == .libraryItem(.allFilms),
                "\(appState.selectedSidebarItem)")
        return r
    }

    /// The first view of `type` under `view`, depth first, that satisfies `test`.
    static func findView<T: NSView>(_ type: T.Type, in view: NSView?,
                                    where test: (T) -> Bool = { _ in true }) -> T? {
        guard let view else { return nil }
        if let match = view as? T, test(match) { return match }
        for sub in view.subviews { if let found = findView(type, in: sub, where: test) { return found } }
        return nil
    }

    /// Main-queue turns with a display pass after each, so viewWillDraw, deferred claims,
    /// Combine `receive(on: RunLoop.main)` deliveries and the observation Tasks all drain.
    private static func drainTurns(_ window: NSWindow?, _ count: Int = 4) async {
        for _ in 0..<count {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
            window?.displayIfNeeded()
        }
    }

    private static func makeIntegrityWindow<V: View>(_ content: V) async -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(content))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await drainTurns(window)
        return (window, host)
    }

    /// Removes the gallery from the SwiftUI graph (so dismantleNSView runs) and detaches
    /// the host. Never closes the window — see harness-never-kill-instances.
    private static func unmount(_ window: NSWindow, _ host: NSHostingView<AnyView>) async {
        window.makeFirstResponder(nil)
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        await drainTurns(window)
        window.contentView = nil
    }

    private static func cmdAEvent(_ window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "a", charactersIgnoringModifiers: "a",
                         isARepeat: false, keyCode: 0)
    }

    /// sRGB components, so two resolutions of one dynamic color compare regardless of the
    /// color space each happened to come back in.
    private static func srgb(_ color: CGColor?) -> [CGFloat] {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let comps = converted.components else { return [] }
        return comps
    }

    private static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> [CGFloat] {
        var cg: CGColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return srgb(cg)
    }

    private static func sameColor(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && !a.isEmpty && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    static func galleryIntegrityScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "gallery-integrity")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        coordinator.importFilms(Array(reportsCorpus().prefix(60)))
        let selection = SelectionState.shared
        let manager = ViewStateManager.shared
        func settle(_ ms: Int = 600) async { try? await Task.sleep(for: .milliseconds(ms)) }

        // MARK: Cmd+A in a sub-tab view
        var unsupported: SidebarItem?
        for candidate: SidebarItem in [.libraryItem(.unwatched), .libraryItem(.recents)] {
            appState.navigate(to: candidate)
            await settle()
            if !coordinator.films.isEmpty { unsupported = candidate; break }
        }
        if let unsupported {
            let capability = unsupported.capabilities.supportsMultiSelection
            r.check("cmd-a-view-supported", capability, "\(unsupported) films=\(coordinator.films.count)")

            selection.selectImmediate(Set<UUID>())
            var (window, host) = await makeIntegrityWindow(
                IntegrityGridHost(coordinator: coordinator, viewID: manager.activeView))
            if let cv = findView(GalleryCollectionView.self, in: host), let event = cmdAEvent(window) {
                cv.keyDown(with: event)
                await drainTurns(window)
                /// Every gallery view supports Select All; the grid's own Cmd+A must agree.
                r.check("grid-cmd-a-subtab-view-selects-all",
                        selection.selectedFilmIDs.count == coordinator.films.count,
                        "model \(selection.selectedFilmIDs.count), grid \(cv.selectionIndexPaths.count) of \(cv.numberOfItems(inSection: 0))")
            } else {
                r.check("grid-cmd-a-unsupported-no-select-all", false, "no grid mounted")
            }
            await unmount(window, host)

            selection.selectImmediate(Set<UUID>())
            (window, host) = await makeIntegrityWindow(
                IntegrityListHost(coordinator: coordinator, viewID: manager.activeView))
            /// The list takes Cmd+A only in a key window; without one the check says nothing.
            if let reason = await keyWindowUnavailable(window) {
                r.skip("list-cmd-a-subtab-view-selects-all", reason)
            } else if let tv = findView(DraggableListTableView.self, in: host), let event = cmdAEvent(window) {
                tv.keyDown(with: event)
                await drainTurns(window)
                r.check("list-cmd-a-subtab-view-selects-all",
                        selection.selectedFilmIDs.count == coordinator.films.count
                            && tv.selectedRowIndexes.count == tv.numberOfRows,
                        "model \(selection.selectedFilmIDs.count), list \(tv.selectedRowIndexes.count) of \(tv.numberOfRows)")
            } else {
                r.check("list-cmd-a-subtab-view-selects-all", false, "no list mounted")
            }
            await unmount(window, host)
        } else {
            r.check("cmd-a-view-unsupported", false, "no unsupported view had films")
        }

        /// Positive control: where Select All IS supported, the gallery's own Cmd+A still works.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle()
        selection.selectImmediate(Set<UUID>())
        do {
            let (window, host) = await makeIntegrityWindow(
                IntegrityGridHost(coordinator: coordinator, viewID: .allFilms))
            if let cv = findView(GalleryCollectionView.self, in: host), let event = cmdAEvent(window) {
                cv.keyDown(with: event)
                await drainTurns(window)
                r.check("grid-cmd-a-supported-selects-all",
                        selection.selectedFilmIDs.count == coordinator.films.count && !coordinator.films.isEmpty,
                        "model \(selection.selectedFilmIDs.count) of \(coordinator.films.count)")
            } else {
                r.check("grid-cmd-a-supported-selects-all", false, "no grid mounted")
            }
            await unmount(window, host)
        }

        // MARK: Keyboard focus must not seed item 0 over a same-turn selection
        selection.selectImmediate(Set<UUID>())
        do {
            let (window, host) = await makeIntegrityWindow(
                IntegrityGridHost(coordinator: coordinator, viewID: .allFilms))
            if let cv = findView(GalleryCollectionView.self, in: host), coordinator.films.count > 6 {
                let target = coordinator.films[5].id
                window.makeFirstResponder(nil)
                await drainTurns(window, 2)
                window.makeFirstResponder(cv)
                selection.selectImmediate([target])
                await drainTurns(window)
                r.check("focus-seed-keeps-same-turn-selection", selection.selectedFilmIDs == [target],
                        "model \(selection.selectedFilmIDs.map { $0 == target ? "target" : "other" })")

                /// Control: focus with no selection at all still seeds item 0.
                window.makeFirstResponder(nil)
                selection.selectImmediate(Set<UUID>())
                await drainTurns(window, 2)
                window.makeFirstResponder(cv)
                await drainTurns(window)
                r.check("focus-seed-still-seeds-empty", selection.selectedFilmIDs == [coordinator.films[0].id],
                        "model count \(selection.selectedFilmIDs.count)")
            } else {
                r.check("focus-seed-keeps-same-turn-selection", false, "no grid / too few films")
            }
            await unmount(window, host)
        }

        // MARK: Cmd+L places the selection in the top row, in both styles
        for style in ["grid", "list"] {
            selection.selectImmediate(Set<UUID>())
            let content: AnyView = style == "grid"
                ? AnyView(IntegrityGridHost(coordinator: coordinator, viewID: .allFilms))
                : AnyView(IntegrityListHost(coordinator: coordinator, viewID: .allFilms))
            let (window, host) = await makeIntegrityWindow(content)
            guard coordinator.films.count > 45 else {
                r.check("\(style)-cmd-l-top-row", false, "too few films")
                await unmount(window, host)
                continue
            }
            let targetIndex = 40
            selection.selectImmediate([coordinator.films[targetIndex].id])
            await drainTurns(window)
            AppEventBus.shared.sendCommand(.scrollToSelection)
            await drainTurns(window)
            if style == "grid", let cv = findView(GalleryCollectionView.self, in: host),
               let sv = cv.enclosingScrollView,
               let layout = cv.collectionViewLayout as? SmoothResizingGridLayout,
               let frame = layout.layoutAttributesForItem(at: IndexPath(item: targetIndex, section: 0))?.frame {
                let visible = sv.documentVisibleRect
                let maxY = max(0, layout.collectionViewContentSize.height - visible.height)
                let expected = min(max(0, frame.minY - layout.lineSpacing), maxY)
                r.check("grid-cmd-l-top-row", abs(visible.minY - expected) < 1,
                        "visible \(visible.minY) expected \(expected)")
            } else if style == "list", let tv = findView(DraggableListTableView.self, in: host),
                      let sv = tv.enclosingScrollView {
                let rowY = tv.rect(ofRow: targetIndex).minY
                let visible = sv.documentVisibleRect
                let maxY = max(0, tv.bounds.height + sv.contentInsets.bottom - sv.contentView.bounds.height)
                let expected = min(rowY, maxY)
                r.check("list-cmd-l-top-row", abs(visible.minY - expected) < 1,
                        "visible \(visible.minY) expected \(expected) row \(rowY)")
            } else {
                r.check("\(style)-cmd-l-top-row", false, "no \(style) mounted")
            }
            await unmount(window, host)
        }

        // MARK: A dismantled gallery's observation loop stays inert
        /// With the main window on Imports no gallery of its own is mounted, so the only
        /// thing that could prune a selection naming a film no gallery holds is the
        /// dismantled one. Its collection/table view is held alive on purpose: that is the
        /// condition under which a loop that outlived its dismantle would still act.
        appState.navigate(to: .libraryItem(.imports))
        await settle()
        for style in ["grid", "list"] {
            selection.selectImmediate(Set<UUID>())
            let content: AnyView = style == "grid"
                ? AnyView(IntegrityGridHost(coordinator: coordinator, viewID: .allFilms))
                : AnyView(IntegrityListHost(coordinator: coordinator, viewID: .allFilms))
            let (window, host) = await makeIntegrityWindow(content)
            let kept: NSView? = style == "grid"
                ? findView(GalleryCollectionView.self, in: host)
                : findView(DraggableListTableView.self, in: host)
            await unmount(window, host)
            let probe = UUID()
            selection.selectImmediate([probe])
            await drainTurns(nil, 6)
            r.check("\(style)-dismantled-loop-inert",
                    unsafe kept != nil && kept?.window == nil && selection.selectedFilmIDs == [probe],
                    unsafe "kept \(kept != nil), detached \(kept?.window == nil), selection intact \(selection.selectedFilmIDs == [probe])")
            withExtendedLifetime(kept) {}
        }
        selection.selectImmediate(Set<UUID>())

        // MARK: Appearance-dependent layer colors re-resolve
        do {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            window.contentView = root

            let tile = GalleryTileContentView(frame: NSRect(x: 0, y: 0, width: 120, height: 180))
            root.addSubview(tile)
            tile.configure(image: nil, filmID: UUID(), subtitle: nil)
            let band = SectionDividerDecorationView(frame: NSRect(x: 0, y: 200, width: 300, height: 46))
            root.addSubview(band)

            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                root.appearance = NSAppearance(named: name)
                root.layoutSubtreeIfNeeded()
                await drainTurns(window, 2)
                let tileFill = srgb(tile.subviews.first?.layer?.backgroundColor)
                r.check("tile-placeholder-fill-\(name.rawValue)",
                        sameColor(tileFill, resolved(.windowBackgroundColor, in: name)),
                        "fill \(tileFill) expected \(resolved(.windowBackgroundColor, in: name))")
                let rule = srgb(band.subviews.last?.layer?.backgroundColor)
                r.check("divider-rule-\(name.rawValue)",
                        sameColor(rule, resolved(.separatorColor, in: name)),
                        "rule \(rule) expected \(resolved(.separatorColor, in: name))")
            }
            window.contentView = nil
        }

        appState.navigate(to: .libraryItem(.allFilms))
        await settle()
        return r
    }
}

#endif

#if DEBUG
// MARK: - Coast Stop
///
/// `coast-stop` (opt-in; seeds 600 films and puts a window on screen for a few seconds, so
/// it is kept out of `all`): Cmd+L during a coasting scroll lands on the selection and the
/// content stays there, in both gallery styles — CoastingScrollStopper (23.20).
///
/// A real trackpad coast cannot be synthesized: AppKit tracks it on a background thread fed
/// straight from the window server. AppKit's own automated live scroll (`_automateLiveScroll`)
/// is the stand-in. It runs on the same concurrent scrolling behavior, overruns a
/// programmatic jump exactly as a coast does (the control checks prove the scenario sees
/// the bug), and ends on `_stopGestureScrollTracking` with didEndLiveScroll arriving after
/// the call — the stopper's deferred path. The synchronous path and real flicks are not
/// covered here and are checked by hand. The window must be on screen: the automation is
/// driven by the display link.
extension DebugHarness {

    /// Follows one scroll view's live-scroll notifications.
    private final class LiveScrollProbe: NSObject {
        private(set) var isLive = false
        init(_ scrollView: NSScrollView) {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(started(_:)),
                name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(ended(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }
        func detach() { NotificationCenter.default.removeObserver(self) }
        @objc private func started(_ n: Notification) { isLive = true }
        @objc private func ended(_ n: Notification) { isLive = false }
    }

    private static let automateSelector = NSSelectorFromString("_automateLiveScroll")
    private static let stopTrackingSelector = NSSelectorFromString("_stopGestureScrollTracking")

    /// Ends the automation directly, for the control's cleanup — independent of the code
    /// under test.
    static func stopAutomatedCoast(_ scrollView: NSScrollView) {
        guard let ivar = unsafe class_getInstanceVariable(NSScrollView.self, "_scrollingBehavior"),
              let behavior = unsafe object_getIvar(scrollView, ivar) as? NSObject,
              behavior.responds(to: stopTrackingSelector) else { return }
        _ = unsafe behavior.perform(stopTrackingSelector)
    }

    static func coastStopScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "coast-stop")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        coordinator.importFilms(Array(reportsCorpus().prefix(600)))
        appState.navigate(to: .libraryItem(.allFilms))
        try? await Task.sleep(for: .milliseconds(600))
        let selection = SelectionState.shared
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        for style in ["grid", "list"] {
            selection.selectImmediate(Set<UUID>())
            let content: AnyView = style == "grid"
                ? AnyView(IntegrityGridHost(coordinator: coordinator, viewID: .allFilms))
                : AnyView(IntegrityListHost(coordinator: coordinator, viewID: .allFilms))
            let (window, host) = await makeIntegrityWindow(content)
            window.orderFrontRegardless()
            await drainTurns(window)

            let targetIndex = 300
            let scrollView: NSScrollView?
            let expectedY: () -> CGFloat?
            if style == "grid", let cv = findView(GalleryCollectionView.self, in: host),
               let layout = cv.collectionViewLayout as? SmoothResizingGridLayout {
                scrollView = cv.enclosingScrollView
                expectedY = {
                    guard let sv = cv.enclosingScrollView,
                          let frame = layout.layoutAttributesForItem(at: IndexPath(item: targetIndex, section: 0))?.frame
                    else { return nil }
                    let maxY = max(0, layout.collectionViewContentSize.height - sv.documentVisibleRect.height)
                    return min(max(0, frame.minY - layout.lineSpacing), maxY)
                }
            } else if style == "list", let tv = findView(DraggableListTableView.self, in: host) {
                scrollView = tv.enclosingScrollView
                expectedY = {
                    guard let sv = tv.enclosingScrollView else { return nil }
                    let maxY = max(0, tv.bounds.height + sv.contentInsets.bottom - sv.contentView.bounds.height)
                    return min(tv.rect(ofRow: targetIndex).minY, maxY)
                }
            } else {
                scrollView = nil
                expectedY = { nil }
            }
            guard let sv = scrollView, coordinator.films.count > targetIndex,
                  sv.responds(to: automateSelector) else {
                r.check("\(style)-mounted", false, "no \(style) scroll view, too few films, or no automation")
                window.orderOut(nil)
                await unmount(window, host)
                continue
            }
            let probe = LiveScrollProbe(sv)
            func y() -> CGFloat { sv.documentVisibleRect.minY }
            func scrollToTop() {
                sv.contentView.setBoundsOrigin(.zero)
                sv.reflectScrolledClipView(sv.contentView)
            }
            /// The coast is the precondition, not the subject: act as soon as it is visibly
            /// under way rather than after a fixed delay, which a short coast could outlast.
            func awaitCoastUnderway() async {
                for _ in 0..<15 where !(probe.isLive && y() > 40) { await wait(20) }
            }

            /// Control: without the stop, a programmatic jump during the coast does not stick.
            scrollToTop()
            await drainTurns(window)
            _ = unsafe sv.perform(automateSelector)
            await awaitCoastUnderway()
            r.check("\(style)-control-coast-running", probe.isLive && y() > 0,
                    "live \(probe.isLive) y \(y())")
            scrollToTop()
            await wait(300)
            r.check("\(style)-control-jump-overrun", y() > 0,
                    "y \(y()) 300 ms after jumping to 0 (the coast should carry on)")
            stopAutomatedCoast(sv)
            await wait(300)
            r.check("\(style)-control-coast-ended", !probe.isLive, "live \(probe.isLive)")

            /// Cmd+L during the coast.
            scrollToTop()
            selection.selectImmediate([coordinator.films[targetIndex].id])
            await drainTurns(window)
            _ = unsafe sv.perform(automateSelector)
            await awaitCoastUnderway()
            let coastY = y()
            r.check("\(style)-coast-running", probe.isLive && coastY > 0,
                    "live \(probe.isLive) y \(coastY)")
            let flaggedBefore = ViewportJumpTracer.jumpsFlagged
            AppEventBus.shared.sendCommand(.scrollToSelection)
            await wait(150)
            let landedY = y()
            await wait(500)
            let laterY = y()
            r.check("\(style)-cmd-l-ends-coast", !probe.isLive, "live \(probe.isLive)")
            r.check("\(style)-cmd-l-stays-put", landedY == laterY,
                    "y \(landedY) then \(laterY) 500 ms later")
            if let expected = expectedY() {
                r.check("\(style)-cmd-l-on-target", abs(laterY - expected) < 1,
                        "y \(laterY) expected \(expected) (coast was at \(coastY))")
            } else {
                r.check("\(style)-cmd-l-on-target", false, "no geometry for film \(targetIndex)")
            }

            /// The viewport-jump tracer: silent for Cmd+L (an app move), and still flags a
            /// large move nobody claimed (positive control).
            r.check("\(style)-tracer-quiet-for-cmd-l", ViewportJumpTracer.jumpsFlagged == flaggedBefore,
                    "flagged \(ViewportJumpTracer.jumpsFlagged - flaggedBefore)")
            if probe.isLive { stopAutomatedCoast(sv) }
            let flaggedBeforeControl = ViewportJumpTracer.jumpsFlagged
            scrollToTop()
            r.check("\(style)-tracer-flags-unclaimed-jump", ViewportJumpTracer.jumpsFlagged == flaggedBeforeControl + 1,
                    "flagged \(ViewportJumpTracer.jumpsFlagged - flaggedBeforeControl) for \(laterY) -> 0")
            probe.detach()
            window.orderOut(nil)
            await unmount(window, host)
        }
        return r
    }
}
#endif


#if DEBUG
// MARK: - Scroll Memory
///
/// `scroll-memory` (opt-in, real main window, 1,400-film reportsCorpus): remembered scroll
/// position through real navigation, with maintainScrollPositionOnViewSwitch on. Covered
/// behaviors:
///
///   • T1 A Film Queue tab restore in LIST style applies that tab's own origin. The list
///     must not apply the incoming tab's origin to the outgoing tab's rows. Galleries key
///     their origin by the loaded filter.
///   • T2 A Reports / Imports round trip after a wheel scroll to the top returns to the
///     banked origin. The navigation banks the origin before the switch.
///   • T3 A search exit with a preserved selection puts the film's row at the top, as far as
///     the content allows, wherever it stood: at the bottom edge, mid-viewport, or near the end.
///   • T6 A filter that empties the gallery, then cleared, restores the banked origin. The
///     emptying pass banks it.
///   • T7 An order-preserving Film Queue section move consumes its scroll intent in place.
///   • T5 An empty Queue tab does not take the previous tab's position.
///   • T10/T11 Restores are film-anchored. A narrower window (fewer columns) or a row of films
///     inserted above while away still opens on the same top film.
///   • T12 An anchor film that moves on its own does not drag the view after it.
///   • T13 With maintainSelectionOnSearchExit off, a search exit preserves and scrolls nothing.
extension DebugHarness {
    @MainActor
    private final class OriginTrail: NSObject {
        private(set) var ys: [CGFloat] = []
        private weak var sv: NSScrollView?
        init(_ sv: NSScrollView) {
            self.sv = sv
            super.init()
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved(_:)),
                name: NSView.boundsDidChangeNotification, object: sv.contentView)
        }
        func detach() { NotificationCenter.default.removeObserver(self) }
        @objc private func moved(_ n: Notification) {
            if let sv { let y = sv.documentVisibleRect.minY; if ys.last != y { ys.append(y) } }
        }
    }

    static func scrollMemoryScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "scroll-memory")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        r.check("real-window", window != nil, "")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let manager = ViewStateManager.shared
        let maintainBefore = Preferences.maintainScrollPositionOnViewSwitch
        let selBefore = Preferences.maintainSelectionOnSearchExit
        Preferences.maintainScrollPositionOnViewSwitch = true
        Preferences.maintainSelectionOnSearchExit = true
        defer {
            Preferences.maintainScrollPositionOnViewSwitch = maintainBefore
            Preferences.maintainSelectionOnSearchExit = selBefore
        }
        func gridSV() -> NSScrollView? { findView(GalleryCollectionView.self, in: window?.contentView)?.enclosingScrollView }
        func listSV() -> NSScrollView? { findView(DraggableListTableView.self, in: window?.contentView)?.enclosingScrollView }
        func anySV() -> NSScrollView? { gridSV() ?? listSV() }
        func y() -> CGFloat { anySV()?.documentVisibleRect.minY ?? -1 }
        func setY(_ v: CGFloat) {
            guard let sv = anySV() else { return }
            sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: v))
            sv.reflectScrolledClipView(sv.contentView)
        }
        func wheel(_ sv: NSScrollView, lines: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: lines, wheel2: 0, wheel3: 0),
                  let ev = NSEvent(cgEvent: cg) else { return }
            sv.scrollWheel(with: ev)
        }

        func wheelToTop() async {
            guard let sv = anySV() else { return }
            var n = 0
            while sv.documentVisibleRect.minY > 0 && n < 600 {
                wheel(sv, lines: 10); n += 1
                try? await Task.sleep(for: .milliseconds(8))
            }
            await settle(300)
        }
        func keysToTop() async {
            guard let cv = findView(GalleryCollectionView.self, in: window?.contentView),
                  let sv = cv.enclosingScrollView,
                  let layout = cv.collectionViewLayout as? SmoothResizingGridLayout else { return }
            let vis = sv.documentVisibleRect
            guard let top = layout.layoutAttributesForElements(in: vis)
                    .filter({ $0.representedElementCategory == .item && vis.contains($0.frame) })
                    .compactMap({ $0.indexPath }).min() else { return }
            SelectionState.shared.selectImmediate([coordinator.films[top.item].id])
            await settle(200)
            for _ in 0..<60 where sv.documentVisibleRect.minY > 0 {
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                             context: nil, characters: "\u{F700}",
                                             charactersIgnoringModifiers: "\u{F700}",
                                             isARepeat: false, keyCode: 126) {
                    cv.keyDown(with: ev)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            await settle(300)
            SelectionState.shared.selectImmediate(Set<UUID>())
        }
        func bankDeep() async {
            setY(6000); await settle(300)
            appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
            appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        }

        func topFilm() -> (id: UUID, index: Int)? {
            if let cv = findView(GalleryCollectionView.self, in: window?.contentView),
               let sv = cv.enclosingScrollView,
               let layout = cv.collectionViewLayout as? SmoothResizingGridLayout {
                let vis = sv.documentVisibleRect
                guard let ip = layout.layoutAttributesForElements(in: vis)
                        .filter({ $0.representedElementCategory == .item }).compactMap({ $0.indexPath }).min(),
                      ip.item < coordinator.films.count else { return nil }
                return (coordinator.films[ip.item].id, ip.item)
            }
            if let tv = findView(DraggableListTableView.self, in: window?.contentView) {
                let rows = tv.rows(in: tv.visibleRect)   /// All Films, dividers off: row == film index
                guard rows.length > 0, rows.location < coordinator.films.count else { return nil }
                return (coordinator.films[rows.location].id, rows.location)
            }
            return nil
        }
        func topRowFilmIDs() -> Set<UUID> {
            guard let cv = findView(GalleryCollectionView.self, in: window?.contentView),
                  let sv = cv.enclosingScrollView,
                  let layout = cv.collectionViewLayout as? SmoothResizingGridLayout else { return [] }
            let items = layout.layoutAttributesForElements(in: sv.documentVisibleRect)
                .filter { $0.representedElementCategory == .item }
            guard let top = items.map(\.frame.minY).min() else { return [] }
            return Set(items.filter { $0.frame.minY == top }.compactMap { $0.indexPath?.item }
                .filter { $0 < coordinator.films.count }.map { coordinator.films[$0].id })
        }

        /// ---- P1 + T2: grid, wheel scroll to top, Reports round trip
        appState.navigate(to: .libraryItem(.allFilms)); await settle(800)
        manager.updateListViewStyle(false); await settle(600)
        setY(6000); await settle(300)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        r.check("T2-sanity-bank-6000", abs(y() - 6000) < 1, "y \(y())")
        if let sv = gridSV() {
            let trail = OriginTrail(sv)
            var n = 0
            while sv.documentVisibleRect.minY > 0 && n < 600 {
                wheel(sv, lines: 10); n += 1
                try? await Task.sleep(for: .milliseconds(8))
            }
            await settle(600)
            trail.detach()
            r.check("wheel-reached-top", sv.documentVisibleRect.minY == 0,
                    "y \(sv.documentVisibleRect.minY) after \(n) wheel events, \(trail.ys.count) moves")
        }
        appState.navigate(to: .libraryItem(.reports)); await settle(1000)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        r.check("T2-reports-round-trip-keeps-top", y() < 1, "y \(y()) (expected 0; 6000 = stale bank restored)")
        for i in 1...3 {
            for dest in [SidebarItem.libraryItem(.reports), .libraryItem(.imports)] {
                await bankDeep()
                await wheelToTop()
                let atTop = y()
                appState.navigate(to: dest); await settle(900)
                appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
                r.check("T2-repeat\(i)-\(dest == .libraryItem(.reports) ? "reports" : "imports")-keeps-top",
                        atTop < 1 && y() < 1, "at top before leaving \(atTop), back at \(y())")
            }
        }

        /// Same, but leaving via a sidebar switch (prepareScrollHandoff path) as a control.
        setY(6000); await settle(200)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        setY(0); await settle(200)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        r.check("T2-control-sidebar-round-trip-keeps-top", y() < 1, "y \(y())")

        /// ---- T3: search exit with a preserved selection always puts the film's row at the
        /// top of the viewport — as far as the content allows — wherever the film stood in the
        /// view the user returns to: cut off at the bottom edge, fully visible mid-viewport, or
        /// near the end of the content. In a user list, in both styles.
        let probeListID = coordinator.createList(name: "Scroll Probe", displayOrder: 990)
        _ = coordinator.addFilmsToList(filmIDs: Set(coordinator.films.prefix(600).map(\.id)), listID: probeListID)
        /// The film's content frame and the viewport, for whichever style is mounted.
        func frameAndViewport(_ id: UUID) -> (frame: CGRect, visible: CGRect, maxY: CGFloat, spacing: CGFloat)? {
            guard let index = coordinator.films.firstIndex(where: { $0.id == id }) else { return nil }
            if let cv = findView(GalleryCollectionView.self, in: window?.contentView),
               let layout = cv.collectionViewLayout as? SmoothResizingGridLayout, let sv = cv.enclosingScrollView,
               let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                return (frame, sv.documentVisibleRect,
                        max(0, layout.collectionViewContentSize.height - sv.documentVisibleRect.height), layout.lineSpacing)
            }
            if let tv = findView(DraggableListTableView.self, in: window?.contentView), let sv = tv.enclosingScrollView {
                return (tv.rect(ofRow: index), sv.documentVisibleRect,
                        max(0, tv.bounds.height + sv.contentInsets.bottom - sv.contentView.bounds.height), 0)
            }
            return nil
        }
        func searchExit(selecting id: UUID, name: String) async -> Bool {
            SearchController.shared.searchText = name
            await settle(1300)
            guard appState.selectedSidebarItem == .libraryItem(.search),
                  coordinator.films.contains(where: { $0.id == id }) else { return false }
            SelectionState.shared.selectImmediate([id])
            await settle(300)
            SearchController.shared.clearSearch()
            await settle(1300)
            return SelectionState.shared.selectedFilmIDs == [id]
        }
        for listStyle in [false, true] {
            let style = listStyle ? "list" : "grid"
            appState.navigate(to: .list(probeListID)); await settle(900)
            manager.updateListViewStyle(listStyle); await settle(800)
            for placement in ["cut-off-at-bottom", "mid-viewport", "near-end"] {
                SelectionState.shared.selectImmediate(Set<UUID>())
                if placement == "near-end" { setY(1_000_000) } else { setY(4000) }
                await settle(300)
                /// Bank this position, so the return restores it before placing the film.
                appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
                appState.navigate(to: .list(probeListID)); await settle(1000)
                guard let probe = frameAndViewport(coordinator.films[0].id) else {
                    r.check("T3-\(style)-\(placement)", false, "no gallery"); continue
                }
                let vis = probe.visible
                let candidate = coordinator.films.first { film in
                    guard let f = frameAndViewport(film.id)?.frame else { return false }
                    switch placement {
                    case "cut-off-at-bottom": return f.minY < vis.maxY && f.maxY > vis.maxY
                    case "mid-viewport":      return vis.contains(f) && f.minY > vis.minY + vis.height * 0.4
                    default:                  return vis.contains(f) && f.minY > vis.minY + 1
                    }
                }
                guard let film = candidate else { r.check("T3-\(style)-\(placement)", false, "no candidate film"); continue }
                let selected = await searchExit(selecting: film.id, name: film.name)
                guard let after = frameAndViewport(film.id) else { r.check("T3-\(style)-\(placement)", false, "no gallery after"); continue }
                let topTarget = min(max(0, after.frame.minY - after.spacing), after.maxY)
                let atTop = abs(after.visible.minY - topTarget) < 1
                let fullyVisible = after.visible.contains(after.frame)
                r.check("T3-\(style)-\(placement)-film-row-at-top",
                        selected && atTop && fullyVisible,
                        "selected \(selected); film minY \(after.frame.minY), viewport \(vis.minY) → \(after.visible.minY), top target \(topTarget) (max \(after.maxY)), fully visible \(fullyVisible)")
            }
        }
        SelectionState.shared.selectImmediate(Set<UUID>())
        manager.updateListViewStyle(false); await settle(600)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(900)

        /// ---- T10–T13: film-anchored restores, and the search-exit preference gate.
        manager.updateShowSectionDividers(false); await settle(400)

        /// T10: the column count changes while away (the window is narrowed).
        func columns() -> Int {
            (findView(GalleryCollectionView.self, in: window?.contentView)?.collectionViewLayout
                as? SmoothResizingGridLayout)?.columnsPerRow ?? 0
        }
        await bankDeep()
        if let window, let before = topFilm() {
            let frameBefore = window.frame
            let columnsBefore = columns()
            appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
            var narrow = frameBefore
            narrow.size.width = max(window.minSize.width, frameBefore.width * 0.7)
            window.setFrame(narrow, display: true); await settle(600)
            appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
            let columnsAfter = columns()
            let after = topFilm()
            r.check("T10-column-change-keeps-top-film", columnsAfter != columnsBefore && topRowFilmIDs().contains(before.id),
                    "columns \(columnsBefore) → \(columnsAfter); top film index \(before.index) → \(after?.index ?? -1) (same film \(after?.id == before.id)); y \(y())")
            window.setFrame(frameBefore, display: true); await settle(600)
        } else { r.check("T10-top-film", false, "") }

        /// T11: films inserted above the viewport while away, both styles.
        var inserted = 0
        for listStyle in [false, true] {
            manager.updateListViewStyle(listStyle); await settle(800)
            setY(6000); await settle(300)
            guard let before = topFilm() else { r.check("T11-top-film", false, ""); continue }
            appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
            /// The inserted titles sort ahead of every corpus title. The count is one full grid
            /// row, so a pixel restore would leave the top film a row down.
            let insertCount = listStyle ? 3 : max(1, columns())
            let names = (0..<insertCount).map { _ in inserted += 1; return "AAAA Inserted \(inserted)" }
            coordinator.importFilms(names.map { makeSnapshot(name: $0) })
            await settle(500)
            appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
            let after = topFilm()
            let above = coordinator.films.indices.filter { names.contains(coordinator.films[$0].name) }
                .allSatisfy { $0 < (after?.index ?? 0) }
            /// Grid: the anchor film is back in the top row (it may sit further along the row).
            let kept = listStyle ? after?.id == before.id : topRowFilmIDs().contains(before.id)
            r.check("T11-\(listStyle ? "list" : "grid")-insertions-keep-top-film", above && kept,
                    "inserted \(insertCount) above \(above); top film index \(before.index) → \(after?.index ?? -1); anchor film in top row \(kept)")
        }
        manager.updateListViewStyle(false); await settle(800)

        /// T12: the anchor film itself moves far away (renamed to sort last) — stay in region.
        setY(6000); await settle(300)
        if let before = topFilm(), let film = coordinator.films.first(where: { $0.id == before.id }) {
            let yBefore = y()
            appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
            var moved = film; moved.name = "zzzz Moved Far"
            await coordinator.updateFilm(moved); await settle(500)
            appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
            let after = topFilm()
            let movedIndex = coordinator.films.firstIndex { $0.id == before.id } ?? -1
            r.check("T12-moved-anchor-stays-in-region", after?.index == before.index && abs(y() - yBefore) < 1,
                    "anchor moved \(before.index) → \(movedIndex); top index now \(after?.index ?? -1); y \(yBefore) → \(y())")
        } else { r.check("T12-top-film", false, "") }

        /// T13: with the preference off, a search exit preserves nothing and scrolls nowhere.
        Preferences.maintainSelectionOnSearchExit = false
        await bankDeep()
        if let pick = coordinator.films.dropFirst(20).first {
            let beforeY = y()
            SearchController.shared.searchText = pick.name
            await settle(1300)
            SelectionState.shared.selectImmediate([pick.id])
            await settle(300)
            SearchController.shared.clearSearch()
            await settle(1300)
            r.check("T13-pref-off-no-preserve-no-scroll",
                    SelectionState.shared.selectedFilmIDs.isEmpty && GalleryScrollIntent.shared.filmID == nil
                        && abs(y() - beforeY) < 1,
                    "selected \(SelectionState.shared.selectedFilmIDs.count), y \(beforeY) → \(y())")
        }
        Preferences.maintainSelectionOnSearchExit = true

        /// ---- T6: same-view remount (filter empties the gallery, then cleared) after a
        /// non-gesture scroll to the top. Bank 6000 first via a sidebar round trip.
        setY(6000); await settle(300)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        await wheelToTop()
        var emptied = false
        let combos: [Set<FilterOption>] = [[.color, .blackAndWhite], [.watched, .unwatched],
                                           [.purchased, .unpurchased], [.completeData, .incompleteData]]
        for combo in combos {
            manager.updateFilterOptions(combo); await settle(600)
            if coordinator.films.isEmpty { emptied = true; break }
        }
        r.check("T6-filter-emptied", emptied, "films \(coordinator.films.count) filters \(manager.activeState.filterOptions)")
        manager.clearFilters(); await settle(1000)
        r.check("T6-filter-round-trip-keeps-top", y() < 1, "y \(y()) (6000 = stale bank restored on remount)")
        /// Same with the arrow keys as the scroll input.
        await bankDeep()
        await keysToTop()
        let keyedTop = y()
        manager.updateFilterOptions([.color, .blackAndWhite]); await settle(700)
        manager.clearFilters(); await settle(1000)
        r.check("T6-keys-filter-round-trip-keeps-top", keyedTop < 1 && y() < 1,
                "at top after keys \(keyedTop), after round trip \(y())")

        /// ---- T1: Film Queue tab restore, grid and list
        /// "Up Next" holds at most FilmQueue.upNextCapacity films, so it gets one fewer than
        /// that — leaving the vacancy T7's move into it needs — and "Soon" is the long,
        /// scrollable section T1 restores.
        let all = coordinator.films.map(\.id)
        let upNextSeed = FilmQueue.upNextCapacity - 1
        seedFilmQueue(coordinator, upNext: all[0..<upNextSeed], soon: all[upNextSeed..<600])
        appState.navigate(to: .libraryItem(.filmQueue)); await settle(1000)
        let fq = FilmQueueFilterState.shared

        /// ---- T5: empty Queue tab. "Later" is empty; leaving "All" (at 4000) for it must not
        /// file All's position under Later's key.
        fq.selectFilter(.all); await settle(700)
        manager.updateListViewStyle(false); await settle(700)
        setY(4000); await settle(300)
        fq.selectFilter(.later); await settle(900)
        r.check("T5-later-empty", coordinator.films.isEmpty, "films \(coordinator.films.count)")
        fq.selectFilter(.upNext); await settle(900)
        _ = coordinator.addFilmsToList(filmIDs: Set(all[600..<900]), listID: FilmQueueSection.later.listID)
        await settle(500)
        fq.selectFilter(.later); await settle(900)
        r.check("T5-empty-tab-not-misbanked", y() < 1, "later opened at \(y()) (never scrolled; 4000 = All's position mis-filed)")
        for style in ["grid", "list"] {
            let wantList = style == "list"
            fq.selectFilter(.all); await settle(700)
            manager.updateListViewStyle(wantList); await settle(700)
            fq.selectFilter(.soon); await settle(700)
            manager.updateListViewStyle(wantList); await settle(700)
            setY(2000); await settle(300)
            let soonY = y()
            fq.selectFilter(.all); await settle(800)
            setY(5000); await settle(300)
            let allY = y()
            guard let sv = anySV() else { r.check("T1-\(style)-sv", false, ""); continue }
            let trail = OriginTrail(sv)
            fq.selectFilter(.soon); await settle(900)
            trail.detach()
            let restoredSoon = y()
            r.check("T1-\(style)-queue-tab-restore", abs(restoredSoon - soonY) < 1,
                    "soon saved \(soonY) restored \(restoredSoon); trail \(trail.ys)")
            fq.selectFilter(.all); await settle(900)
            r.check("T1-\(style)-queue-tab-restore-back", abs(y() - allY) < 1, "all saved \(allY) restored \(y())")
        }
        /// ---- T7: a Film Queue section move that leaves the All tab's order unchanged must
        /// not leave its post-move scroll intent pending (grid style).
        for (label, moveFirstSoon) in [("first-soon-to-upnext", true), ("last-upnext-to-soon", false)] {
            fq.selectFilter(.soon); await settle(800)
            manager.updateListViewStyle(false); await settle(600)
            setY(1500); await settle(300)
            let soonSaved = y()
            let soonTop = topFilm()
            fq.selectFilter(.all); await settle(800)
            manager.updateListViewStyle(false); await settle(600)
            let ids = coordinator.films.map(\.id)
            func section(_ id: UUID) -> UUID? { coordinator.filmQueueListIDs(forFilm: id).first }
            guard let b = ids.indices.first(where: { $0 > 0 && section(ids[$0]) == FilmQueueSection.soon.listID
                                                     && section(ids[$0 - 1]) == FilmQueueSection.upNext.listID }) else {
                r.check("T7-\(label)-boundary", false, "no up next / soon boundary"); continue
            }
            let mover = moveFirstSoon ? ids[b] : ids[b - 1]
            FilmQueueAssignment.toggle([mover], section: moveFirstSoon ? .upNext : .soon, coordinator: coordinator)
            await settle(800)
            let sameOrder = coordinator.films.map(\.id) == ids
            let lingering = GalleryScrollIntent.shared.filmID != nil
            r.check("T7-\(label)-intent-consumed", !lingering,
                    "order unchanged \(sameOrder), intent still pending \(lingering)")
            fq.selectFilter(.soon); await settle(900)
            /// Restores are film-anchored: a film added or removed above Soon's top film moves
            /// that film by one place, and the restore follows it. The restore is intact when
            /// the saved top film is still in the top row.
            let topRowIDs = topRowFilmIDs()
            r.check("T7-\(label)-soon-restore-intact",
                    y() > 0 && soonTop.map { topRowIDs.contains($0.id) } == true,
                    "soon saved \(soonSaved) opened at \(y()); saved top film in top row \(soonTop.map { topRowIDs.contains($0.id) } ?? false)")
            GalleryScrollIntent.shared.clear()
            /// Undo the move.
            FilmQueueAssignment.toggle([mover], section: moveFirstSoon ? .soon : .upNext, coordinator: coordinator)
            await settle(600)
            GalleryScrollIntent.shared.clear()
        }

        fq.selectFilter(.all); await settle(500)
        manager.updateListViewStyle(false); await settle(500)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(500)
        return r
    }
}


// MARK: - Queue Mixed Style
///
/// `queue-mixed-style` (opt-in, real main window): a Film Queue tab switch between two tabs of
/// DIFFERENT grid/list styles. Samples every committed frame (a run-loop observer after Core
/// Animation's commit) for the mounted style and its film count. A committed frame must never
/// pair one tab's style with another tab's films. The incoming style must not be built around
/// the outgoing tab's films, and the outgoing style's last pass must not commit the incoming
/// films. GalleryView presents ViewStateManager.displayedGalleryState, and both styles skip a
/// Queue pass whose presented style is not theirs.
extension DebugHarness {
    static func queueMixedStyleScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "queue-mixed-style")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        let manager = ViewStateManager.shared
        appState.navigate(to: .libraryItem(.allFilms)); await settle(800)
        let all = coordinator.films.map(\.id)
        /// "Up Next" is capped at FilmQueue.upNextCapacity (8); "Soon" takes the rest.
        let upNextSeed = FilmQueue.upNextCapacity
        seedFilmQueue(coordinator, upNext: all[0..<upNextSeed], soon: all[upNextSeed..<600], later: all[600..<900])
        appState.navigate(to: .libraryItem(.filmQueue)); await settle(1000)
        let fq = FilmQueueFilterState.shared
        fq.selectFilter(.all); await settle(700); manager.updateListViewStyle(false); await settle(700)
        fq.selectFilter(.upNext); await settle(700); manager.updateListViewStyle(true); await settle(700)
        fq.selectFilter(.all); await settle(900)

        /// What each committed frame holds: mounted style and displayed film count.
        var frames: [String] = []
        func snapshot() -> String {
            let grid = findView(GalleryCollectionView.self, in: window?.contentView)
            let list = findView(DraggableListTableView.self, in: window?.contentView)
            let g = grid.map { "grid:\($0.numberOfSections > 0 ? $0.numberOfItems(inSection: 0) : 0)" }
            let l = list.map { "list:\($0.numberOfRows)" }
            return [g, l].compactMap { $0 }.joined(separator: "+") + "/tab=\(fq.selectedFilter.rawValue)/loaded=\(coordinator.loadedFilmQueueFilter?.rawValue ?? "-")"
        }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { _, _ in
            MainActor.assumeIsolated {
                let s = snapshot()
                if frames.last != s { frames.append(s) }
            }
        }
        for (label, target) in [("all-grid→upnext-list", FilmQueueFilter.upNext), ("upnext-list→all-grid", .all),
                                ("all-grid→upnext-list#2", .upNext), ("upnext-list→all-grid#2", .all)] {
            /// start from the opposite tab
            await settle(600)
            frames = [snapshot()]
            ViewSwitchProbe.isEnabled = true; ViewSwitchProbe.reset()
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            fq.selectFilter(target)
            await settle(800)
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let events = ViewSwitchProbe.events
            ViewSwitchProbe.isEnabled = false
            /// Every committed frame must pair a style with ITS tab's films, judged by what the
            /// view displays: All (grid) holds 900 films, Up Next (list) 8 rows. The outgoing
            /// tab may stay on screen in its own style while the deferred reload is pending;
            /// never both styles at once, never a style around the other tab's films.
            let targetStyle = target == .upNext ? "list" : "grid"
            let wrong = frames.filter { f in
                f.contains("+") || f.hasPrefix("grid:\(upNextSeed)/") || f.hasPrefix("list:9")
            }
            r.check("\(label)-no-wrong-content-frame", wrong.isEmpty && frames.count >= 2,
                    "frames \(frames)")
            /// The incoming style is built once, around the incoming films, and that is the only
            /// reload. The outgoing style skips any pass SwiftUI still gives it, through its
            /// style guard, so it cannot reload with the incoming films or commit them.
            let makes = events.filter { $0.contains(".make") }
            let reloads = events.filter { $0.contains(".reload") }
            let targetCount = coordinator.films.count
            r.check("\(label)-single-build-with-target-films",
                    makes.count == 1 && makes[0].hasPrefix(targetStyle) && makes[0].hasSuffix("films=\(targetCount)")
                        && reloads.count == 1 && reloads[0].hasPrefix(targetStyle),
                    events.joined(separator: " | "))
        }
        fq.selectFilter(.all); await settle(500)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(500)
        return r
    }
}

// MARK: - Up Next Slots
///
/// `upnext-slots` (opt-in, real main window): the "Up Next" cap and its empty slots
/// (UpNextSlots.swift). The Queue's "All" and "Up Next" tabs draw one slot per vacancy after the "Up Next"
/// films, in both gallery styles, numbered from the first vacancy; a row of nothing but slots
/// is skipped by Up/Down; a full "Up Next" draws none; an empty one draws its own band and
/// all eight. Adds past the cap are refused with an alert. The slot sheet searches with its
/// own SearchController and leaves the gallery's search alone. Window snapshots go to the
/// sandbox's `upnext-slots/` folder for a visual check.
extension DebugHarness {
    static func upNextSlotsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "upnext-slots")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else { r.check("window", false, ""); return r }
        /// The cap alert and the slot sheet present on the key window.
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        let manager = ViewStateManager.shared
        let upNextID = FilmQueueSection.upNext.listID
        let snapshots = Preferences.posterImagesFolderURL?.deletingLastPathComponent()
            .appendingPathComponent("upnext-slots", isDirectory: true)
        if let snapshots { try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        func snapshot(_ name: String, _ w: NSWindow = window) {
            guard let snapshots, let view = w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: snapshots.appendingPathComponent("\(name).png"))
        }
        func slotViews() -> [UpNextSlotDecorationView] {
            allViews(window.contentView!).compactMap { $0 as? UpNextSlotDecorationView }
                .filter { unsafe !$0.isHidden && $0.superview != nil }
                .sorted { $0.slotNumber < $1.slotNumber }
        }

        appState.navigate(to: .libraryItem(.allFilms)); await settle(800)
        let all = coordinator.films.map(\.id)
        let upNext = Set(all[0..<3])
        seedFilmQueue(coordinator, upNext: upNext, soon: all[3..<23], later: all[23..<33])
        appState.navigate(to: .libraryItem(.filmQueue)); await settle(1000)
        FilmQueueFilterState.shared.selectFilter(.all); await settle(800)
        manager.updateListViewStyle(false); await settle(900)

        /// ---- Grid: three films, five slots numbered 4–8, laid out as the next cells.
        guard let grid = allViews(window.contentView!).compactMap({ $0 as? GalleryCollectionView }).first,
              let layout = grid.collectionViewLayout as? SmoothResizingGridLayout else {
            r.check("grid", false, "no grid"); return r
        }
        var slots = slotViews()
        r.check("grid/slot-count", slots.map(\.slotNumber) == [4, 5, 6, 7, 8], "slots \(slots.map(\.slotNumber))")
        let cell0 = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame ?? .zero
        let firstSoon = layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame ?? .zero
        if let slot4 = slots.first {
            r.check("grid/slot-is-cell-sized", abs(slot4.frame.width - cell0.width) < 1 && abs(slot4.frame.height - cell0.height) < 1,
                    "slot \(slot4.frame) cell \(cell0)")
            r.check("grid/slot-follows-films", layout.columnsPerRow < 4 || abs(slot4.frame.minY - cell0.minY) < 1,
                    "slot 4 at \(slot4.frame.minY), first row at \(cell0.minY), \(layout.columnsPerRow) columns")
        }
        r.check("grid/soon-below-slots", slots.allSatisfy { $0.frame.maxY < firstSoon.minY },
                "first Soon film at \(firstSoon.minY), last slot ends \(slots.map(\.frame.maxY).max() ?? 0)")
        r.check("grid/items-are-films-only", grid.numberOfItems(inSection: 0) == 33, "\(grid.numberOfItems(inSection: 0)) items")
        /// Up/Down skip a row of nothing but slots. With 3 films in a row of ≥ 6 columns the
        /// slots spill into a second, slot-only row (8 > columns); a narrower grid has none.
        let slotOnlyRows = (0..<12).filter { layout.isSlotOnlyRow($0) }
        let expectSlotOnly = layout.columnsPerRow < 8 && (3 + 5) > layout.columnsPerRow
            && ((3 + 5 + layout.columnsPerRow - 1) / layout.columnsPerRow) > ((3 + layout.columnsPerRow - 1) / layout.columnsPerRow)
        r.check("grid/slot-only-rows", expectSlotOnly == !slotOnlyRows.isEmpty,
                "slot-only rows \(slotOnlyRows), columns \(layout.columnsPerRow)")
        snapshot("grid-3-films")

        /// ---- List: the same slots as rows, after the "Up Next" films, before "Soon".
        manager.updateListViewStyle(true); await settle(1000)
        if let table = allViews(window.contentView!).compactMap({ $0 as? DraggableListTableView }).first {
            /// 3 bands + 33 films + 5 slots.
            r.check("list/row-count", table.numberOfRows == 41, "\(table.numberOfRows) rows")
            let cells = (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? UpNextSlotListCell }
            r.check("list/slot-rows", cells.map(\.slotNumber) == [4, 5, 6, 7, 8], "\(cells.map(\.slotNumber))")
            let firstSlotRow = (0..<table.numberOfRows).first { table.view(atColumn: 0, row: $0, makeIfNecessary: true) is UpNextSlotListCell }
            r.check("list/slots-after-up-next", firstSlotRow == 4, "first slot row \(firstSlotRow ?? -1)")
            r.check("list/slots-unselectable",
                    table.delegate?.tableView?(table, shouldSelectRow: firstSlotRow ?? 0) == false, "")
        } else { r.check("list/table", false, "no table") }
        snapshot("list-3-films")
        manager.updateListViewStyle(false); await settle(900)

        /// ---- The cap: an add past eight is refused whole, with an alert.
        let five = Set(all[3..<8]), six = Set(all[3..<9])
        r.check("cap/overflow-math", FilmQueue.upNextOverflow(adding: five, coordinator: coordinator) == 0
                && FilmQueue.upNextOverflow(adding: six, coordinator: coordinator) == 1, "")
        r.check("cap/backstop", !coordinator.addFilmsToList(filmIDs: six, listID: upNextID)
                && FilmQueue.upNextFilmIDs(coordinator: coordinator) == upNext, "")
        FilmQueueAssignment.toggle(six, section: .upNext, coordinator: coordinator)
        await settle(900)
        r.check("cap/menu-refused", FilmQueue.upNextFilmIDs(coordinator: coordinator) == upNext, "")
        let alert = window.attachedSheet
        let ok = alert.flatMap { s in allViews(s.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" } }
        r.check("cap/alert", ok != nil, "attached sheet \(alert != nil)")
        if alert != nil { snapshot("cap-alert", alert!) }
        ok?.performClick(nil); await settle(700)

        /// ---- Full: no slots. Empty: its own band and all eight.
        /// Straight to the list: the menu path (covered by `cap/*` above) would stop at the
        /// "Add to Queue?" confirmation for any of these films that a real library has flagged.
        _ = coordinator.addFilmsToList(filmIDs: five, listID: upNextID); await settle(1200)
        slots = slotViews()
        r.check("full/no-slots", FilmQueue.upNextFilmIDs(coordinator: coordinator).count == 8 && slots.isEmpty,
                "\(FilmQueue.upNextFilmIDs(coordinator: coordinator).count) in Up Next, \(slots.count) slot(s)")
        FilmManager.removeFromFilmQueue(upNext.union(five), coordinator: coordinator); await settle(1200)
        slots = slotViews()
        r.check("empty/all-eight", slots.map(\.slotNumber) == Array(1...8), "\(slots.map(\.slotNumber))")
        let bands = allViews(window.contentView!).compactMap { $0 as? SectionDividerDecorationView }
        r.check("empty/own-band", bands.count >= 2, "\(bands.count) bands")
        snapshot("grid-empty-up-next")

        /// ---- The "Up Next" tab draws the same slots: all eight while it is empty (the gallery
        /// mounts for them alone, in place of the empty-section placeholder), then the open ones
        /// after its films, in both styles.
        FilmQueueFilterState.shared.selectFilter(.upNext); await settle(1000)
        slots = slotViews()
        r.check("tab/empty-all-eight", slots.map(\.slotNumber) == Array(1...8), "\(slots.map(\.slotNumber))")
        snapshot("tab-grid-empty")
        _ = coordinator.addFilmsToList(filmIDs: upNext, listID: upNextID); await settle(1000)
        slots = slotViews()
        r.check("tab/grid-slots", slots.map(\.slotNumber) == [4, 5, 6, 7, 8], "\(slots.map(\.slotNumber))")
        if let grid = allViews(window.contentView!).compactMap({ $0 as? GalleryCollectionView }).first,
           let layout = grid.collectionViewLayout as? SmoothResizingGridLayout,
           let last = layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame,
           let slot4 = slots.first {
            r.check("tab/slots-follow-films", slot4.frame.minY >= last.minY - 1, "slot 4 at \(slot4.frame.minY), film 3 at \(last.minY)")
        }
        snapshot("tab-grid-3-films")
        manager.updateListViewStyle(true); await settle(1000)
        if let table = allViews(window.contentView!).compactMap({ $0 as? DraggableListTableView }).first {
            let cells = (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? UpNextSlotListCell }
            r.check("tab/list-slot-rows", cells.map(\.slotNumber) == [4, 5, 6, 7, 8], "\(cells.map(\.slotNumber))")
        } else { r.check("tab/list-table", false, "no table") }
        snapshot("tab-list-3-films")
        manager.updateListViewStyle(false); await settle(900)
        FilmQueueFilterState.shared.selectFilter(.all); await settle(900)

        /// ---- The slot sheet: its own search, leaving the gallery's alone.
        AppEventBus.shared.sendCommand(.openUpNextSlot); await settle(1200)
        if let sheet = window.attachedSheet,
           let field = allViews(sheet.contentView!).compactMap({ $0 as? NSSearchField }).first {
            snapshot("sheet-open", sheet)
            let target = coordinator.getFilm(all[30])?.name ?? ""
            field.stringValue = target
            field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            await settle(900)
            snapshot("sheet-results", sheet)
            r.check("sheet/gallery-search-untouched", SearchController.shared.searchText.isEmpty
                    && manager.activeState.searchQuery.isEmpty, "")
            field.stringValue = "zzzzzzzz"
            field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            await settle(700)
            snapshot("sheet-no-results", sheet)
            appState.sheetCoordinator.dismissSheet(); await settle(900)
            r.check("sheet/dismissed", window.attachedSheet == nil, "")
        } else { r.check("sheet/presented", false, "no slot sheet") }

        FilmManager.removeFromFilmQueue(Set(all[0..<33]), coordinator: coordinator); await settle(600)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(500)
        return r
    }
}
#endif

// MARK: - Sidebar Tab Switch
///
/// `sidebar-tab-switch` (opt-in, a measurement): what a RightSidebar tab change costs once
/// the selected film's neighbor tabs are resident — the common "select a film, then look at
/// its Releases" path. Each step reads AppKitScrollHandoffProbe (how many hosting views had
/// their rootView reassigned, each a full re-measure of that tab's tree) and the run-loop
/// busy time. Switches by button (instant) and by swipe (animated) are measured separately.
/// Uses the sandbox's own library when it has one, so a real-data copy gives real tab weight.
#if DEBUG
extension DebugHarness {
    /// The RightSidebar's tab scroll views (AppKitScrollView's gated scroll views at exactly
    /// the sidebar's width), and how many of them currently answer a hit-test.
    private static func sidebarTabHitTestGates() -> (total: Int, open: Int) {
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        var total = 0, open = 0
        func visit(_ view: NSView) {
            if let sv = view as? NSScrollView,
               String(describing: type(of: sv)).contains("HitTestGatedScrollView"),
               abs(sv.frame.width - RightSidebar.sidebarWidth) < 1 {
                total += 1
                if sv.hitTest(NSPoint(x: sv.frame.midX, y: sv.frame.midY)) != nil { open += 1 }
            }
            view.subviews.forEach(visit)
        }
        if let root = window?.contentView { visit(root) }
        return (total, open)
    }

    static func sidebarTabSwitchScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sidebar-tab-switch")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        if !coordinator.hasDatabaseFilms { coordinator.importFilms(reportsCorpus()) }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(2000)
        let films = coordinator.films
        guard films.count > 10 else { r.check("films", false, "\(films.count)"); return r }
        /// The heaviest Releases tab available, so the measurement is not of an empty tree.
        let film = films.max { $0.releases.count < $1.releases.count } ?? films[0]
        let manager = ViewStateManager.shared
        manager.setRightSidebarTab(.details)
        SelectionState.shared.selectImmediate(film.id)
        /// Past the 180 ms neighbor-arming quiet window, with margin.
        await settle(1500)

        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        func measure(_ label: String, _ action: () -> Void) async {
            AppKitScrollHandoffProbe.applied = 0
            AppKitScrollHandoffProbe.newRevisions = 0
            recorder.reset()
            let t0 = CACurrentMediaTime() * 1000
            action()
            await settle(900)
            let reading = recorder.reading(from: t0, window: 900)
            /// Exactly one of the resident tab scroll views may take clicks at rest; the
            /// others sit off the plane and must be gated (hitTest returns nil).
            let gates = sidebarTabHitTestGates()
            r.check("\(label)-hit-test", gates.total >= 2 && gates.open == 1,
                    "\(Fmt.int(gates.open)) of \(Fmt.int(gates.total)) tab scroll views hit-testable")
            r.check(label, true,
                    "handoffs \(Fmt.int(AppKitScrollHandoffProbe.applied)), revisions \(Fmt.int(AppKitScrollHandoffProbe.newRevisions)), busy \(Fmt.fixed(reading.busy, 1)) ms, longest \(Fmt.fixed(reading.longest, 1)) ms")
        }
        for i in 0..<4 {
            await measure("button-\(Fmt.int(i))-releases") { manager.setRightSidebarTab(.releases) }
            await measure("button-\(Fmt.int(i))-details") { manager.setRightSidebarTab(.details) }
        }
        for i in 0..<3 {
            await measure("swipe-\(Fmt.int(i))-forward") { AppEventBus.shared.rightSidebarSwipe(.forward) }
            await measure("swipe-\(Fmt.int(i))-backward") { AppEventBus.shared.rightSidebarSwipe(.backward) }
        }
        r.check("film", true, "\(film.name), \(Fmt.int(film.releases.count)) releases")
        SelectionState.shared.selectImmediate(nil as UUID?)
        return r
    }
}
#endif

// MARK: - Gallery Edit Refresh
///
/// `gallery-edit-refresh` (opt-in, a measurement plus correctness checks): what a same-order
/// film edit and a gallery view switch cost in each style, read from GalleryRefreshProbe and
/// the run-loop busy time. In the grid, with no section dividers, it counts the forced
/// divider-relabel layouts each update pays (or skips). In the list, it counts the rows
/// refreshed and the row hosting views actually re-rendered, and checks that an edited film's
/// row shows the new rating both in the viewport and in a row prepared just below it.
#if DEBUG
extension DebugHarness {
    static func galleryEditRefreshScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "gallery-edit-refresh")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        if !coordinator.hasDatabaseFilms { coordinator.importFilms(reportsCorpus()) }
        let manager = ViewStateManager.shared
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        let saved = manager.activeState
        manager.updateSortOption(.title)
        manager.updateSortDirection(.ascending)
        manager.updateShowSectionDividers(false)
        manager.updateListViewStyle(false)
        await settle(1200)
        guard coordinator.films.count > 60 else { r.check("films", false, "\(coordinator.films.count)"); return r }

        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        func resetProbes() {
            GalleryRefreshProbe.forcedDividerLayouts = 0
            GalleryRefreshProbe.skippedDividerLayouts = 0
            GalleryRefreshProbe.listRowsRefreshed = 0
            GalleryRefreshProbe.listRowRootViewAssignments = 0
            recorder.reset()
        }
        var originals: [UUID: FilmSnapshot] = [:]
        /// Changes one film's rating (not a sort key under the title sort, so the order holds)
        /// and returns the new value.
        func editRating(_ film: FilmSnapshot) async -> Int {
            if originals[film.id] == nil { originals[film.id] = film }
            var edited = film
            edited.userRating = film.userRating == 7 ? 8 : 7
            await coordinator.updateFilm(edited)
            return edited.userRating
        }

        /// Grid: edits and view switches.
        for i in 0..<4 {
            resetProbes()
            let t0 = CACurrentMediaTime() * 1000
            _ = await editRating(coordinator.films[10 + i])
            await settle(700)
            let reading = recorder.reading(from: t0, window: 700)
            r.check("grid-edit-\(Fmt.int(i))", true,
                    "forced layouts \(Fmt.int(GalleryRefreshProbe.forcedDividerLayouts)), skipped \(Fmt.int(GalleryRefreshProbe.skippedDividerLayouts)), busy \(Fmt.fixed(reading.busy, 1)) ms")
        }
        for i in 0..<3 {
            for item in [SidebarItem.libraryItem(.unwatched), .libraryItem(.allFilms)] {
                resetProbes()
                let t0 = CACurrentMediaTime() * 1000
                appState.navigate(to: item)
                await settle(900)
                let reading = recorder.reading(from: t0, window: 900)
                r.check("grid-switch-\(Fmt.int(i))-\(item == .libraryItem(.allFilms) ? "all" : "unwatched")", true,
                        "forced layouts \(Fmt.int(GalleryRefreshProbe.forcedDividerLayouts)), skipped \(Fmt.int(GalleryRefreshProbe.skippedDividerLayouts)), busy \(Fmt.fixed(reading.busy, 1)) ms, longest \(Fmt.fixed(reading.longest, 1)) ms")
            }
        }

        /// List: edits of a visible row and of a prepared, off-screen row.
        manager.updateListViewStyle(true)
        await settle(1500)
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        guard let table = findView(DraggableListTableView.self, in: window?.contentView) else {
            r.check("list-table", false, "no list table found")
            return r
        }
        table.scroll(.zero)
        await settle(600)
        let visibleRows = table.rows(in: table.visibleRect)
        let visible = Set(visibleRows.location..<(visibleRows.location + visibleRows.length))
        let available = Set(table.debugDisplayedRatings().keys)
        let prepared = available.subtracting(visible).filter { $0 > (visible.max() ?? 0) }.sorted()
        r.check("list-rows", !visible.isEmpty,
                "visible \(Fmt.int(visible.count)), prepared below \(Fmt.int(prepared.count))")
        var targets: [(String, Int)] = [("visible", visible.sorted()[min(3, visible.count - 1)])]
        if let row = prepared.first { targets.append(("prepared", row)) }
        for (kind, row) in targets {
            for i in 0..<2 {
                resetProbes()
                let t0 = CACurrentMediaTime() * 1000
                let newRating = await editRating(coordinator.films[row])
                await settle(700)
                let reading = recorder.reading(from: t0, window: 700)
                let shown = table.debugDisplayedRatings()[row]
                r.check("list-edit-\(kind)-\(Fmt.int(i))", shown == nil || shown == newRating,
                        "row \(Fmt.int(row)) shows \(shown.map { Fmt.int($0) } ?? "no view") (want \(Fmt.int(newRating))), rows refreshed \(Fmt.int(GalleryRefreshProbe.listRowsRefreshed)), re-rendered \(Fmt.int(GalleryRefreshProbe.listRowRootViewAssignments)), busy \(Fmt.fixed(reading.busy, 1)) ms")
            }
        }

        /// Restore what this run changed.
        for film in originals.values { await coordinator.updateFilm(film) }
        manager.updateListViewStyle(saved.isListView)
        manager.updateShowSectionDividers(saved.showSectionDividers)
        manager.updateSortOption(saved.sortOption)
        manager.updateSortDirection(saved.sortDirection)
        await settle(500)
        return r
    }
}
#endif


// MARK: - Gallery Reload Economy
///
/// `gallery-reload-economy` (opt-in, a measurement plus checks): how many film loads and gallery
/// update passes a film change costs while a gallery is on screen, read from ViewSwitchProbe.
/// One edit, a burst of per-film update events, an import and a deletion should each cost
/// exactly one load (and an edit or a burst at most one grid pass). A change to films the view
/// does not show should cost no gallery pass. An edit that takes a film out of the view should
/// take it out in that one load, and visiting an empty view should load it once. Also checks that grid selection rings stay
/// right through in-place reconfigures and cell recycling, and counts how often they are
/// re-stroked.
#if DEBUG
extension DebugHarness {
    static func galleryReloadEconomyScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "gallery-reload-economy")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        if !coordinator.hasDatabaseFilms { coordinator.importFilms(reportsCorpus()) }
        let manager = ViewStateManager.shared
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        let saved = manager.activeState
        manager.updateSortOption(.title)
        manager.updateSortDirection(.ascending)
        manager.updateShowSectionDividers(false)
        manager.updateListViewStyle(false)
        await settle(1200)
        guard coordinator.films.count > 60 else { r.check("films", false, "\(coordinator.films.count)"); return r }

        ViewSwitchProbe.isEnabled = true
        defer { ViewSwitchProbe.isEnabled = false }
        func count(_ prefix: String) -> Int { ViewSwitchProbe.events.filter { $0.hasPrefix(prefix) }.count }
        func summary() -> String {
            "loads \(Fmt.int(count("load "))), grid passes \(Fmt.int(count("grid.update"))), list passes \(Fmt.int(count("list.update")))"
        }
        var originals: [UUID: FilmSnapshot] = [:]
        func rated(_ film: FilmSnapshot, _ rating: Int) -> FilmSnapshot {
            if originals[film.id] == nil { originals[film.id] = film }
            var edited = film
            edited.userRating = rating
            return edited
        }

        /// One same-order edit.
        ViewSwitchProbe.reset()
        let edited = coordinator.films[12]
        await coordinator.updateFilm(rated(edited, edited.userRating == 7 ? 8 : 7))
        await settle(700)
        r.check("edit-one-load", count("load ") == 1 && count("grid.update") <= 1, summary())

        /// A burst of per-film update events in one turn — the shape a Hall of Fame reorder or
        /// a ratings-import rollback posts.
        ViewSwitchProbe.reset()
        for film in coordinator.films[20..<40] {
            AppEventBus.shared.send(.film(.updated(filmID: film.id)))
        }
        await settle(700)
        r.check("burst-one-load", count("load ") == 1 && count("grid.update") <= 1, summary())

        /// An edit that takes a film out of the view: rating a film in Unwatched ▸ Not Rated.
        appState.navigate(to: .libraryItem(.unwatched))
        await settle(900)
        UnwatchedState.shared.selectCategory(.notRated)
        await settle(900)
        if let unrated = coordinator.films.first(where: { $0.userRating == 0 }) {
            ViewSwitchProbe.reset()
            await coordinator.updateFilm(rated(unrated, 6))
            let goneAtOnce = !coordinator.films.contains { $0.id == unrated.id }
            await settle(700)
            let goneAfter = !coordinator.films.contains { $0.id == unrated.id }
            r.check("membership-edit-one-load", count("load ") == 1 && count("grid.update") <= 1 && goneAtOnce && goneAfter,
                    "\(summary()), left the view at once \(goneAtOnce), afterward \(goneAfter)")
        } else {
            r.check("membership-edit-one-load", true, "skipped: no unrated film")
        }
        UnwatchedState.shared.selectCategory(.unwatched)
        await settle(600)

        /// Import and delete with a gallery on screen.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(900)
        let fresh = (0..<4).map { makeSnapshot(name: "Economy Probe \($0)") }
        ViewSwitchProbe.reset()
        coordinator.importFilms(fresh)
        await settle(700)
        let freshIDs = Set(fresh.map(\.id))
        r.check("import-one-load", count("load ") == 1 && coordinator.films.filter { freshIDs.contains($0.id) }.count == 4,
                summary())
        ViewSwitchProbe.reset()
        await FilmManager.deleteFilms(freshIDs, coordinator: coordinator)
        await settle(700)
        r.check("delete-one-load", count("load ") == 1 && !coordinator.films.contains { freshIDs.contains($0.id) },
                summary())

        /// Changes to films the view does not show cost no gallery pass.
        let listID = coordinator.createList(name: "Economy Probe List", displayOrder: 991)
        FilmManager.addFilmsToList(Set(coordinator.films[0..<3].map(\.id)), listID: listID, coordinator: coordinator)
        await settle(500)
        appState.navigate(to: .list(listID))
        await settle(900)
        let outsider = makeSnapshot(name: "Economy Outsider")
        ViewSwitchProbe.reset()
        coordinator.importFilms([outsider])
        await settle(700)
        r.check("unrelated-add-no-pass", count("grid.update") == 0, summary())
        ViewSwitchProbe.reset()
        await FilmManager.deleteFilms([outsider.id], coordinator: coordinator)
        await settle(700)
        r.check("unrelated-delete-no-pass", count("grid.update") == 0, summary())

        /// Visiting an empty view loads it once, like any other.
        let emptyID = coordinator.createList(name: "Economy Empty List", displayOrder: 992)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(900)
        ViewSwitchProbe.reset()
        appState.navigate(to: .list(emptyID))
        await settle(900)
        r.check("empty-view-one-load", count("load ") == 1 && coordinator.films.isEmpty, summary())
        ViewSwitchProbe.reset()
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(900)
        r.check("full-view-one-load", count("load ") == 1, summary())

        /// Selection rings through an in-place reconfigure and through cell recycling.
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        if let cv = findView(GalleryCollectionView.self, in: window?.contentView),
           let scrollView = cv.enclosingScrollView {
            func ring(_ index: Int) -> Bool? {
                (cv.item(at: IndexPath(item: index, section: 0)) as? GalleryItem)?.debugRingShowsSelection
            }
            func ringedCount() -> Int {
                cv.visibleItems().filter { ($0 as? GalleryItem)?.debugRingShowsSelection == true }.count
            }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await settle(400)
            let selected = coordinator.films[5]
            SelectionState.shared.selectImmediate([selected.id])
            await settle(500)
            r.check("ring-on-select", ring(5) == true && ringedCount() == 1, "ringed \(Fmt.int(ringedCount()))")

            GalleryRefreshProbe.ringRefreshes = 0
            let other = coordinator.films[8]
            await coordinator.updateFilm(rated(other, other.userRating == 7 ? 8 : 7))
            await settle(700)
            r.check("ring-after-in-place-edit", ring(5) == true && ringedCount() == 1,
                    "ringed \(Fmt.int(ringedCount())), ring re-strokes \(Fmt.int(GalleryRefreshProbe.ringRefreshes))")

            /// Recycle every visible cell: far down and back.
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, cv.frame.height - scrollView.documentVisibleRect.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await settle(500)
            let ringedAtBottom = ringedCount()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await settle(500)
            r.check("ring-after-recycling", ringedAtBottom == 0 && ring(5) == true && ringedCount() == 1,
                    "ringed at bottom \(Fmt.int(ringedAtBottom)), at top \(Fmt.int(ringedCount()))")

            SelectionState.shared.selectImmediate([])
            await settle(500)
            r.check("ring-on-deselect", ring(5) == false && ringedCount() == 0, "ringed \(Fmt.int(ringedCount()))")
        } else {
            r.check("ring-grid", false, "no grid collection view found")
        }

        /// Restore what this run changed.
        for film in originals.values { await coordinator.updateFilm(film) }
        _ = ListManager.deleteList(listID, coordinator: coordinator)
        _ = ListManager.deleteList(emptyID, coordinator: coordinator)
        manager.updateListViewStyle(saved.isListView)
        manager.updateShowSectionDividers(saved.showSectionDividers)
        manager.updateSortOption(saved.sortOption)
        manager.updateSortDirection(saved.sortDirection)
        await settle(500)
        return r
    }
}
#endif


// MARK: - Summary Lazy Rows

/// `summary-lazy-rows` (opt-in; drives the real main window): the Recents summary's lazy rows
/// (RecentsSummaryView.Coordinator.deferOffscreenRows). Checks that a fresh summary holds back the rows off screen
/// and attaches them all shortly after, in document order; that the arrow keys walk every row from the first
/// turn, before the deferred rows attach; and that row and page scroll positions survive leaving and returning.
#if DEBUG
extension DebugHarness {
    static func summaryLazyRowsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "summary-lazy-rows")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }) else {
            r.check("main-window", false, "no main window")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        let savedMaintain = Preferences.maintainScrollPositionOnViewSwitch
        defer { Preferences.maintainScrollPositionOnViewSwitch = savedMaintain }
        func document() -> NSView? {
            findView(NSView.self, in: window.contentView, where: { String(describing: type(of: $0)) == "SummaryDocumentView" })
        }
        func outerScroll() -> NSScrollView? { document()?.enclosingScrollView }
        /// The document's subviews, by kind, in order: "H" a band, "R" a row's cells, "L" a placeholder line.
        func layoutString() -> String {
            (document()?.subviews ?? []).compactMap { v -> String? in
                switch String(describing: type(of: v)) {
                case "SummaryHeaderView": return "H"
                case "SummaryRowScrollView": return "R"
                case "NSTextField": return "L"
                default: return nil
                }
            }.joined()
        }
        func rowScrollViews() -> [NSScrollView] {
            (document()?.subviews ?? []).compactMap { $0 as? NSScrollView }
        }
        let categoriesWithFilms = RecentsCategory.sections.filter { !$0.orderedFilmIDs().isEmpty }

        func openSummary() async {
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(600)
            RecentsState.shared.selectCategory(.summary, immediate: true)
            appState.navigate(to: .libraryItem(.recents))
        }

        // 1. Deferral and attachment.
        Preferences.maintainScrollPositionOnViewSwitch = false
        SummaryLazyProbe.cellsMade = 0
        await openSummary()
        await settle(1)
        let atMount = SummaryLazyProbe.attachedAtMount
        await settle(800)
        let cellsTotal = SummaryLazyProbe.cellsMade
        let pageFits = (outerScroll().map { $0.documentView!.frame.height <= $0.contentView.bounds.height + 1 }) ?? true
        r.check("deferred-at-mount", pageFits || atMount.count < categoriesWithFilms.count,
                "attached at mount \(atMount.map(\.rawValue)) of \(categoriesWithFilms.count); cells at first frame \(SummaryLazyProbe.cellsAtFirstFrame), after \(cellsTotal)")
        let expected = RecentsCategory.sections.map { categoriesWithFilms.contains($0) ? "HR" : "HL" }.joined()
        r.check("all-attached-in-order", layoutString() == expected, "document \(layoutString()), expected \(expected)")

        // 2. Arrow keys from the first turn: focus the first row and step down through every row at once.
        await openSummary()
        await settle(1)
        if let first = rowScrollViews().first?.documentView {
            window.makeFirstResponder(first)
            func key(_ code: UInt16, _ chars: String) {
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                window.sendEvent(e)
            }
            key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
            /// Step i must land in row i. A film can head two rows (say, recently added and recently
            /// updated), so each step is matched against the row it should be in, not searched for.
            var misses: [String] = []
            for category in categoriesWithFilms {
                let selected = SelectionState.shared.untrackedSelectedFilmIDs
                let rowFilms = Set(category.orderedFilmIDs().prefix(RecentsCategory.summaryRowLimit))
                if selected.isEmpty || !rowFilms.isSuperset(of: selected) {
                    misses.append("\(category.rawValue) (\(selected.count) selected)")
                }
                key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            }
            r.check("arrow-keys-walk-rows", misses.isEmpty, "steps off their row: \(misses)")
        } else {
            r.check("arrow-keys-walk-rows", false, "no first row")
        }
        await settle(600)

        // 3. Scroll positions survive leaving and returning.
        Preferences.maintainScrollPositionOnViewSwitch = true
        await openSummary()
        await settle(800)
        /// The row with the most to scroll, moved to a reachable offset: a row whose films fit its width
        /// cannot scroll, and an elastic overscroll past the end is not a position to remember.
        func scrollRange(_ sv: NSScrollView) -> CGFloat {
            max(0, (sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width)
        }
        if let outer = outerScroll(), let last = rowScrollViews().max(by: { scrollRange($0) < scrollRange($1) }),
           scrollRange(last) >= 50 {
            last.contentView.scroll(to: NSPoint(x: min(600, scrollRange(last)).rounded(), y: 0))
            last.reflectScrolledClipView(last.contentView)
            let maxY = max(0, outer.documentView!.frame.height - outer.contentView.bounds.height)
            outer.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            outer.reflectScrolledClipView(outer.contentView)
            await settle(300)
            let beforeRow = last.contentView.bounds.origin.x, beforeY = outer.contentView.bounds.origin.y
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(700)
            RecentsState.shared.selectCategory(.summary, immediate: true)
            appState.navigate(to: .libraryItem(.recents))
            await settle(900)
            let rowIndex = rowScrollViews().firstIndex { $0 === last }
            let afterRow = rowIndex.flatMap { i in rowScrollViews().indices.contains(i) ? rowScrollViews()[i] : nil }?
                .contentView.bounds.origin.x ?? -1
            let afterY = outerScroll()?.contentView.bounds.origin.y ?? -1
            r.check("scroll-restored", abs(afterRow - beforeRow) < 1 && abs(afterY - beforeY) < 1,
                    "row \(beforeRow) → \(afterRow), page \(beforeY) → \(afterY)")
        } else {
            r.check("scroll-restored", false, "no summary row with films to scroll")
        }
        Preferences.maintainScrollPositionOnViewSwitch = false

        appState.navigate(to: .libraryItem(.allFilms))
        return r
    }
}
#endif

// MARK: - AppKitScrollView settle and safe area

/// `appkit-scroll-settle` (opt-in): checks the two scroll-time changes to AppKitScrollView (UtilityKit).
///
///   1. Settle delay. A content hand-off that arrives during a live scroll is buffered, and applied
///      `kAppKitScrollSettleDelay` (0.15 s) after the scroll ends, not at its end. A scroll that
///      begins inside the delay carries the buffer to its own end, an update that arrives inside the
///      delay waits with it, and a scroll view torn down inside the delay applies nothing afterward.
///      Driven by posting the live-scroll notifications on a real AppKitScrollView in an off-screen
///      window, and counted through AppKitScrollHandoffProbe.applied.
///   2. Safe area. A replica of the utility's hosting stack (NSScrollView → flipped document →
///      NSHostingView) in a window whose content runs under the titlebar, scrolled in steps with
///      `safeAreaRegions` = .all and then []: how many steps changed the hosted tree's safe area (as
///      SwiftUI sees it) and what each step's layout and display cost. Also confirms the real utility's
///      hosting view reports zero insets under the titlebar, and lists which of the main window's
///      AppKitScrollViews sit under its toolbar.
#if DEBUG
@MainActor @Observable
private final class SettleHarnessModel {
    var value = 0
}

private struct SettleHarnessHost: View {
    let model: SettleHarnessModel
    var body: some View {
        let value = model.value
        AppKitScrollView(modifier: EmptyModifier()) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<80, id: \.self) { i in Text("Row \(i) · \(value)").frame(height: 22) }
            }
        }
    }
}

@MainActor
private final class SafeAreaChangeCounter {
    var changes = 0
}

private struct SafeAreaReplicaContent: View {
    let counter: SafeAreaChangeCounter
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<300, id: \.self) { i in
                HStack {
                    Image(systemName: "film")
                    Text("Replica row \(i)").font(.body)
                    Spacer()
                    Text("\(i * 7)").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
            }
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { _ in counter.changes += 1 }
    }
}

private final class SafeAreaReplicaDocument: NSView {
    override var isFlipped: Bool { true }
}

extension DebugHarness {
    /// Opens the first session card's Details popover through accessibility, scrolls the Imports list 40 pt,
    /// and checks that the popover closed (ImportSessionCard's ScrollActivityObserver).
    private static func importsPopoverScrollDismissCheck(_ r: inout HarnessScenarioResult) async {
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil
                  && $0.frame.minX > -10000 }) else {
            r.check("imports-popover-window", false, "no main window")
            return
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("imports-popover", reason); return }
        ImportsState.shared.selectCategory(.metadata, persist: false)
        appState.navigate(to: .libraryItem(.imports))
        await settle(1200)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        var list: NSScrollView?
        while let v = stack.popLast(), list == nil {
            if let sv = v as? NSScrollView, let host = sv.documentView?.subviews.first,
               String(describing: type(of: host)).contains("ImportSessionList") { list = sv }
            stack.append(contentsOf: v.subviews)
        }
        guard let sv = list, let host = sv.documentView?.subviews.first else {
            r.check("imports-popover-list", false, "Imports list not found")
            return
        }
        /// SwiftUI builds no accessibility tree without an assistive client, so the button cannot be pressed
        /// from here. What can be checked: every Details card carries a ScrollActivityObserver, and each one
        /// sits in (and so observes the clip view of) the Imports list's own scroll view.
        var observers: [NSView] = []
        var pending: [NSView] = [host]
        while let v = pending.popLast() {
            if String(describing: type(of: v)) == "ObservingView" { observers.append(v) }
            pending.append(contentsOf: v.subviews)
        }
        let mounted = ImportsSwitchProbe.mountedCount?() ?? -1
        r.metric("imports-scroll-observers", Double(observers.count), "views")
        r.metric("imports-mounted-cards", Double(mounted), "cards")
        r.check("imports-observers-present", !observers.isEmpty, "no ScrollActivityObserver in the Imports list")
        r.check("imports-observers-in-list", observers.allSatisfy { $0.enclosingScrollView === sv },
                "an observer is attached to a different scroll view")
    }

    static func appKitScrollSettleScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "appkit-scroll-settle")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func scrollViews(in view: NSView?) -> [NSScrollView] {
            guard let view else { return [] }
            return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        func isUtilityHost(_ view: NSView) -> Bool {
            String(describing: type(of: view)).contains("AppKitScrollContentWrapper")
        }
        func utilityHost(in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if isUtilityHost(view) { return view }
            for sub in view.subviews { if let found = utilityHost(in: sub) { return found } }
            return nil
        }

        // MARK: 1. Settle delay
        let model = SettleHarnessModel()
        var window: NSWindow? = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 320),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false
        window?.contentView = NSHostingView(rootView: SettleHarnessHost(model: model))
        window?.orderFrontRegardless()
        await settle(300)
        guard let scrollView = scrollViews(in: window?.contentView).first else {
            r.check("utility-scroll-view", false, "no AppKitScrollView in the test window")
            window?.close()
            return r
        }
        let center = NotificationCenter.default
        func startScroll() { center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView) }
        func endScroll() { center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView) }
        var mark = AppKitScrollHandoffProbe.applied
        func applied() -> Int {
            defer { mark = AppKitScrollHandoffProbe.applied }
            return AppKitScrollHandoffProbe.applied - mark
        }
        _ = applied()

        model.value += 1
        await settle(120)
        r.check("at-rest-applies-at-once", applied() == 1, "a hand-off with no scroll should apply in its own update")

        startScroll()
        model.value += 1
        await settle(120)
        r.check("buffered-during-scroll", applied() == 0, "applied mid-scroll")
        endScroll()
        await settle(60)
        r.check("held-while-settling", applied() == 0, "applied within 60 ms of the scroll's end")
        await settle(200)
        r.check("flushed-after-settle", applied() == 1, "expected exactly one hand-off ~150 ms after the end")

        startScroll()
        model.value += 1
        await settle(80)
        endScroll()
        await settle(60)
        startScroll()
        await settle(250)
        r.check("new-scroll-cancels-flush", applied() == 0, "the first scroll's settle timer flushed during the second scroll")
        endScroll()
        await settle(250)
        r.check("flushed-after-second-scroll", applied() == 1, "the buffer should apply once the second scroll settles")

        startScroll()
        endScroll()
        model.value += 1
        await settle(50)
        r.check("update-during-settle-waits", applied() == 0, "an update inside the settle delay applied at once")
        await settle(250)
        r.check("update-during-settle-flushes", applied() == 1, "expected one hand-off after the delay")

        startScroll()
        model.value += 1
        await settle(50)
        endScroll()
        window?.contentView = nil
        window?.close()
        window = nil
        await settle(300)
        r.check("teardown-inside-delay", applied() == 0, "a dismantled scroll view applied a hand-off afterward")

        // MARK: 2. Safe area
        let titled = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titled.isReleasedWhenClosed = false
        titled.titlebarAppearsTransparent = true
        titled.orderFrontRegardless()
        defer { titled.close() }
        let titlebarHeight = titled.frame.height - titled.contentLayoutRect.height
        r.metric("titlebar-height", Double(titlebarHeight), "pt")

        for (label, regions) in [("all", SafeAreaRegions.all), ("none", SafeAreaRegions())] {
            let counter = SafeAreaChangeCounter()
            let scroll = NSScrollView(frame: titled.contentView?.bounds ?? .zero)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
            scroll.wantsLayer = true
            let document = SafeAreaReplicaDocument()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.wantsLayer = true
            scroll.documentView = document
            let host = NSHostingView(rootView: SafeAreaReplicaContent(counter: counter))
            host.sizingOptions = [.intrinsicContentSize]
            host.safeAreaRegions = regions
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            document.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                host.topAnchor.constraint(equalTo: document.topAnchor),
                host.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            ])
            titled.contentView?.addSubview(scroll)
            for _ in 0..<4 {
                titled.contentView?.layoutSubtreeIfNeeded(); titled.displayIfNeeded(); CATransaction.flush()
                await oneTurn()
            }
            counter.changes = 0
            let steps = 80
            var stepMs: [Double] = []
            for step in 1...steps {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 6))
                scroll.reflectScrolledClipView(scroll.contentView)
                let t0 = CACurrentMediaTime()
                titled.contentView?.layoutSubtreeIfNeeded()
                titled.displayIfNeeded()
                CATransaction.flush()
                stepMs.append((CACurrentMediaTime() - t0) * 1000)
                await oneTurn()
            }
            let sorted = stepMs.sorted()
            r.metric("replica-\(label)-safe-area-changes", Double(counter.changes), "of \(steps) steps")
            r.metric("replica-\(label)-step-median", sorted[sorted.count / 2], "ms")
            r.metric("replica-\(label)-step-p95", sorted[Int(Double(sorted.count) * 0.95)], "ms")
            r.metric("replica-\(label)-host-top-inset", Double(host.safeAreaInsets.top), "pt")
            if label == "none" {
                r.check("replica-none-stable", counter.changes == 0,
                        "\(counter.changes) safe-area changes reached SwiftUI with safeAreaRegions = []")
            }
            scroll.removeFromSuperview()
        }

        /// The real utility under the same titlebar: its hosting view should report no inset.
        let realModel = SettleHarnessModel()
        let realHost = NSHostingView(rootView: SettleHarnessHost(model: realModel))
        realHost.frame = titled.contentView?.bounds ?? .zero
        realHost.autoresizingMask = [.width, .height]
        titled.contentView?.addSubview(realHost)
        await settle(300)
        if let sv = scrollViews(in: realHost).first, let host = utilityHost(in: sv) {
            sv.contentView.scroll(to: NSPoint(x: 0, y: 120))
            sv.reflectScrolledClipView(sv.contentView)
            titled.contentView?.layoutSubtreeIfNeeded()
            r.check("utility-host-no-inset", host.safeAreaInsets.top == 0,
                    "utility hosting view top inset \(host.safeAreaInsets.top) under a \(titlebarHeight) pt titlebar")
        } else {
            r.check("utility-host-no-inset", false, "no utility hosting view found")
        }
        realHost.removeFromSuperview()

        // MARK: 3. Imports Details popover closes on scroll
        await importsPopoverScrollDismissCheck(&r)

        /// Which of the main window's AppKitScrollViews reach under its toolbar.
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== titled }) {
            let safeTop = main.contentLayoutRect.maxY
            var under = 0, total = 0
            for sv in scrollViews(in: main.contentView) where utilityHost(in: sv) != nil {
                total += 1
                if sv.convert(sv.bounds, to: nil).maxY > safeTop + 0.5 { under += 1 }
            }
            r.metric("main-window-utility-scroll-views", Double(total), "count")
            r.metric("main-window-utility-scroll-views-under-toolbar", Double(under), "count")
        }
        return r
    }
}
#endif
