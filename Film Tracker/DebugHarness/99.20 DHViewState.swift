// MARK: - DHViewState.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Harness coverage for per-view ViewState persistence, written for the move of the
// section-dividers setting out of a single global preference and into each view's own
// ViewState.
//
// Everything here drives the REAL ViewStateManager against the REAL Preferences store
// inside a debug sandbox — no reimplementation of the codec, no test double. The codec
// itself (ViewState.decoded(from:) / ViewState.encodedSettings) is deliberately never
// called directly: what matters is not that a pair of functions round-trip each
// other, but that a choice made through the same method the menu calls survives being
// written to disk and read back by the same method a view switch calls. Testing the
// public path is the only way to catch a defect that lives in the wiring between them.

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
        case "first-selection":     return await firstSelectionScenario(coordinator: coordinator)
        case "gallery-integrity":   return await galleryIntegrityScenario(coordinator: coordinator)
        case "coast-stop":          return await coastStopScenario(coordinator: coordinator)
        case "scroll-memory":       return await scrollMemoryScenario(coordinator: coordinator)
        case "queue-mixed-style":   return await queueMixedStyleScenario(coordinator: coordinator)
        case "upnext-slots":        return await upNextSlotsScenario(coordinator: coordinator)
        case "sidebar-tab-switch":  return await sidebarTabSwitchScenario(coordinator: coordinator)
        case "rsb-load":            return await rsbLoadScenario(coordinator: coordinator)
        case "rsb-modules":         return await rsbModulesScenario(coordinator: coordinator)
        case "rsb-cards":           return await rsbCardsScenario(coordinator: coordinator)
        case "rsb-rows":            return await rsbRowsScenario(coordinator: coordinator)
        case "rsb-crew-parity":     return await rsbCrewParityScenario()
        case "rsb-frames-parity":   return await rsbFramesParityScenario()
        case "rsb-metadata-shot":   return await rsbMetadataShotScenario(coordinator: coordinator)
        case "rsb-notes-shot":      return await rsbNotesShotScenario(coordinator: coordinator)
        case "rsb-releases-shot":   return await rsbReleasesShotScenario(coordinator: coordinator)
        case "rsb-glyph-shot":      return await rsbGlyphShotScenario(coordinator: coordinator)
        case "gallery-edit-refresh": return await galleryEditRefreshScenario(coordinator: coordinator)
        case "gallery-reload-economy": return await galleryReloadEconomyScenario(coordinator: coordinator)
        default:                    return nil
        }
    }

    /// Empties all three Film Queue sections, then fills them with the given films.
    ///
    /// Every Queue scenario seeds on top of whatever the sandbox already holds — a real-library
    /// copy, or an earlier scenario in the same run. "Up Next" refuses adds past
    /// FilmQueue.upNextCapacity, so seeding without clearing first silently left it full and
    /// failed checks that need a known vacancy (or a known count) for reasons unrelated to
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
        // The Queue's active tab is part of what this scenario manipulates (it selects the
        // storage slot .filmQueue resolves to), so it is restored alongside the
        // preferences. Assigned directly rather than through selectFilter throughout:
        // this scenario is asserting about storage and state resolution, and the public
        // switch additionally clears the selection, banks scroll origins and schedules a
        // deferred gallery reload — none of which this is testing.
        let queueFilterBefore = FilmQueueFilterState.shared.selectedFilter
        defer {
            Preferences.rememberSortFilterSelections = rememberBefore
            Preferences.viewSortStates = statesBefore
            FilmQueueFilterState.shared.selectedFilter = queueFilterBefore
        }
        Preferences.rememberSortFilterSelections = true

        // MARK: Decoding

        // Seed storage directly, then reach each view for the first time this run so the
        // load path — not the in-memory cache — is what answers. Distinct views are used
        // per case for exactly that reason: revisiting one would be served from the cache
        // and would assert nothing about decoding.
        Preferences.viewSortStates = [
            // A five-element entry with dividers ON.
            "smartList.\(SmartListType.allCases[0].rawValue)":
                ["title", "", "ascending", "", "dividers"],
            // A five-element entry with dividers explicitly OFF.
            "unwatched.\(UnwatchedCategory.unwatched.rawValue)":
                ["year", "", "descending", "list", ""],
            // A LEGACY four-element entry, exactly as every version before this change
            // wrote it. Must decode with dividers off and must not trap on the missing
            // element — this is the case that governs every existing user's first launch.
            "unwatched.\(UnwatchedCategory.notRated.rawValue)":
                ["title", "", "ascending", "list"],
            // A THREE-element entry, the even older format the codec also still claims to
            // read. Both trailing fields must fall back to their struct defaults. Filed
            // under the Queue's "Up Next" tab, which owns its slot like any other view.
            "filmQueue.upNext": ["duration", "", "descending"],
            // The Queue's "All" tab, seeded with dividers explicitly OFF. It must still
            // resolve to ON: that tab's bands are structural and its pair is locked, so
            // no stored value — including one written before the lock existed — may
            // present it as anything else.
            "filmQueue": ["title", "", "ascending", "", ""],
            // A malformed element [4]. Anything that is not exactly "dividers" means off;
            // it must not trap, and it must not be read as truthy for being non-empty.
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

        // The idempotence guard: a redundant set must not churn storage or reload.
        let beforeNoop = Preferences.viewSortStates
        manager.updateShowSectionDividers(true)
        await awaitDebouncedSave()
        r.check("mutator-idempotent", Preferences.viewSortStates == beforeNoop,
                "setting the value it already holds changed nothing")

        // MARK: Per-view isolation

        // The whole point of the change: All Films is on from the mutation above, and a
        // different view must be entirely unaffected by it — both in memory and on disk.
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

        // The Queue's four tabs share one ViewIdentifier and are told apart only by
        // ViewStateKey's sub-tab, so these are the checks that prove the key — not the
        // identifier — is what addresses storage.
        FilmQueueFilterState.shared.selectedFilter = .all
        manager.switchToViewSync(.filmQueue)
        r.check("queue-all-locked-on", manager.activeState.showSectionDividers,
                "the All tab resolves to dividers ON despite a stored OFF")
        r.check("queue-all-reports-locked", manager.sectionDividersLocked,
                "and reports itself as locked, which is what disables the menu pair")

        // The enforcement half of the lock: the mutator must refuse, so no code path can
        // write a value the tab cannot honor even with the menu pair disabled.
        manager.updateShowSectionDividers(false)
        r.check("queue-all-refuses-change", manager.activeState.showSectionDividers,
                "updateShowSectionDividers(false) was refused on the locked tab")

        // A section tab is free, defaults off like any other view, and is unaffected by
        // the All tab's permanent ON.
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

        // The two remaining section tabs must be untouched by all of the above — the
        // isolation the whole feature exists to provide.
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

        // And returning to All finds its own locked state, not the last section tab's.
        FilmQueueFilterState.shared.selectedFilter = .all
        manager.switchToViewSync(.filmQueue)
        r.check("queue-all-round-trip",
                manager.activeState.showSectionDividers && manager.sectionDividersLocked,
                "returning to All restores its locked ON")

        // MARK: Remember-preference governance

        // With the remember preference off, a divider choice must not reach storage — the
        // same rule every sibling field obeys, and what makes "defaults to off on the next
        // launch" true rather than merely intended.
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

        // Moving the control INTO the Sort menu makes the menu's own seal a correctness
        // question, not just a cosmetic one: a view whose Sort menu is fully disabled and
        // which currently has no bands would, under the old seal, offer no way to switch
        // dividers back ON — the state in which the user most needs the control. The
        // Recents tabs are exactly that shape (fixed sort, so the menu is always
        // "disabled", and no jump targets while dividers are off), so this is a live trap
        // rather than a hypothetical one. `supportsSectionDividers` is the third clause
        // that defeats it, and it must be true for every gallery-backed view.
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

        // The negative control. Without it every check above could pass on a capability
        // that is simply hard-wired true, asserting nothing.
        for (label, item) in [
            ("reports", SidebarItem.libraryItem(.reports)),
            ("imports", SidebarItem.libraryItem(.imports)),
        ] {
            r.check("not-reachable:\(label)", !item.capabilities.supportsSectionDividers,
                    "a view that is not gallery-backed still seals its Sort menu as before")
        }

        // And the clear that STabGeneral performs on disabling the preference must leave
        // nothing behind for a later launch to read back.
        Preferences.clearViewSortStates()
        r.check("cleared-storage-is-empty", Preferences.viewSortStates.isEmpty,
                "clearViewSortStates left no entry any view could inherit dividers from")

        return r
    }
}


// MARK: - Source for Viewing Ladder
//
// Proves the three-tier studio spelling in the RightSidebar's "Source for Viewing" field
// (ReleaseStudio: name / shorthand / abbreviated) and the ladder `fittingValueRow` is handed
// for it. Pure functions — RSBHelpers.sourceDisplay and SidebarTextAbbreviation.sourceValueLadder
// — driven through the same entry points WatchDetails uses.
extension DebugHarness {

    private static func sourceLadderScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "source-ladder")

        // MARK: The table
        r.check("shorthand-tier", ReleaseStudio.shorthand("Universal Studios") == "Universal",
                "shorthand for Universal Studios is '\(ReleaseStudio.shorthand("Universal Studios"))'")
        r.check("abbreviated-tier", ReleaseStudio.abbreviated("Universal Studios") == "Uni",
                "abbreviation for Universal Studios is '\(ReleaseStudio.abbreviated("Universal Studios"))'")
        // A studio with a shorthand but no abbreviation abbreviates to its shorthand.
        r.check("abbreviated-falls-back-to-shorthand",
                ReleaseStudio.abbreviated("Sony Pictures") == ReleaseStudio.shorthand("Sony Pictures"),
                "abbreviated('Sony Pictures') should equal its shorthand")
        // A studio with neither yields its name at both tiers; so does free text.
        for name in ["Criterion", "Some Boutique Label"] {
            r.check("no-tier-is-identity-\(name)",
                    ReleaseStudio.shorthand(name) == name && ReleaseStudio.abbreviated(name) == name,
                    "'\(name)' was altered by a tier it has no spelling for")
        }
        // Every entry's tiers get no longer as they descend.
        let monotone = ReleaseStudio.entries.allSatisfy { e in
            let sh = e.shorthand ?? e.name
            let ab = e.abbreviated ?? sh
            return sh.count <= e.name.count && ab.count <= sh.count
        }
        r.check("tiers-never-lengthen", monotone, "a shorthand or abbreviation is longer than the tier above it")

        // MARK: The field
        // Two purchased Blu-rays from different studios force the studio prefix; the
        // Universal one scores best by being remastered. The Australian origin forces the
        // origin token, so every ladder step has something to do.
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
        // Order: singles, then pairs, then all three — each step gives up no less than the
        // one before it, so the row never has to choose a bigger retreat over a smaller one.
        func retreats(_ s: String) -> Int {
            (s.contains("rem.") ? 1 : 0) + (s.contains("AUS ") ? 1 : 0) + (s.contains("Uni ") ? 1 : 0)
        }
        let counts = ladder.map(retreats)
        r.check("ladder-order-by-retreat", counts == counts.sorted() && counts.first == 1 && counts.last == 3,
                "ladder retreat counts \(counts) are not non-decreasing 1…3")
        r.check("ladder-studio-single-step", ladder.count > 2 && ladder[2] == display.studioAbbreviatedValue,
                "third step should be the studio alone: \(ladder)")

        // A single domestic release shows no prefix, so every alternate is nil and the
        // ladder is only the "remastered" step (or empty without it).
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

        // A studio with no abbreviation contributes no studio step: the studio alternate is
        // nil and the ladder collapses to the origin/remastered combinations.
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
//
// Proves GalleryFocusIntent end to end for both gallery styles: the REAL GallerySubview
// (grid) and GalleryListView (list), hosted in an off-screen window, claim first responder
// for their content view when — and only when — an intent addressed to their view is
// pending at mount. The search-exit path in MainView is the only producer; what it produces
// is exercised here exactly as the destination gallery consumes it.
extension DebugHarness {

    private struct GridHost: View {
        let coordinator: DataCoordinator
        var body: some View {
            GallerySubview(scrollRequest: nil, activeViewID: .allFilms,
                           subtitleProvider: nil, showSectionDividers: false)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    private struct ListHost: View {
        let coordinator: DataCoordinator
        var body: some View {
            GalleryListView(activeViewID: .allFilms, scrollRequest: nil,
                            subtitleProvider: nil, showSectionDividers: false)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    /// Mounts `content` in a fresh off-screen window, runs the display pass that fires
    /// viewWillDraw, and reports the first responder that results.
    @MainActor
    /// Mounts `content`, then runs display passes until `settled` holds (up to 2 s). A view
    /// claims focus in viewWillDraw and defers the claim a turn further, so how many turns
    /// that takes varies; a fixed three turns made `list-claims-focus` fail intermittently.
    /// The claim cases therefore wait on the first responder itself: the intent is consumed
    /// in makeNSView, at mount, so waiting on it still left only the three-turn minimum and
    /// failed the list case about one run in eight (measured 2026-09-25).
    private static func mountAndDraw<V: View>(_ content: V, until settled: (NSWindow) -> Bool = { _ in true })
        async -> (window: NSWindow, responder: NSResponder?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // viewWillDraw runs in the display pass, not layout; the claim itself is deferred
        // one further turn from there.
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

// MARK: - View Switch Perf

// `view-switch-perf` (opt-in, a measurement): sidebar navigation between gallery-backed views
// in the REAL main window, on a library-sized corpus. Per switch it records the main-thread
// busy stretches (same recorder as `reports-hitch`) and the probe event sequence: which
// gallery style mounted, for which view, holding how many films, and how many loads and
// reloads the switch cost. Launch with `open -g -n`.
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
        // Put one destination in list style so grid⟷list crossings are measured too.
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

        // In-place sub-tab switches: the gallery stays mounted and must reload exactly once.
        await measure("to-recents", to: .libraryItem(.recents))
        var previousWasEmpty = coordinator.films.isEmpty
        for c in RecentsCategory.allCases.reversed() {
            await settle(400)
            ViewSwitchProbe.reset()
            RecentsState.shared.selectCategory(c, persist: false, immediate: true)
            await settle(500)
            let reloads = ViewSwitchProbe.events.filter { $0.hasPrefix("grid.reload") || $0.hasPrefix("list.reload") }
            let makes = ViewSwitchProbe.events.filter { $0.contains(".make") }
            // A category with no films shows a placeholder and unmounts the gallery, so
            // the next non-empty one legitimately mounts a fresh one.
            r.check("recents-subtab-single-reload \(c.rawValue)", reloads.count <= 1 && (makes.isEmpty || previousWasEmpty),
                    ViewSwitchProbe.events.joined(separator: " | "))
            let loadMs = ViewSwitchProbe.events.first { $0.hasPrefix("load ") }
                .flatMap { $0.split(separator: " ").last }.map(String.init) ?? "?"
            r.check("recents-load-time \(c.rawValue)", true, "films=\(coordinator.films.count) \(loadMs)")
            previousWasEmpty = coordinator.films.isEmpty
        }

        // Scroll-origin round trip, long view → short view → back, with the preference on.
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

            // Through a search session: entry replaces the films under the still-mounted
            // All Films grid, which must not bank a viewport clamped to the results.
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


// MARK: - Gallery Integrity
//
// `gallery-integrity` (opt-in; seeds 60 films, so it is kept out of `all`): behaviors of
// both gallery styles that no other scenario reaches, each driven through the REAL
// GallerySubview / GalleryListView hosted in an off-screen window —
//
//   • Cmd+A delivered straight to the gallery honors ViewCapabilities.supportsMultiSelection
//     (KeyboardManager passes the key through, and the menu item is disabled, in views that
//     do not support it, so the gallery's own keyDown is the last line).
//   • A dismantled gallery's selection-observation loop never acts again.
//   • The grid tile's placeholder fill and the divider band's rule follow appearance changes.
//   • Keyboard focus never seeds item 0 over a selection that landed in the same turn.
//   • Cmd+L places the topmost selected film in the top row in BOTH styles.
extension DebugHarness {

    private struct IntegrityGridHost: View {
        let coordinator: DataCoordinator
        let viewID: ViewIdentifier
        var body: some View {
            GallerySubview(scrollRequest: nil, activeViewID: viewID,
                           subtitleProvider: nil, showSectionDividers: false)
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
                            subtitleProvider: nil, showSectionDividers: false)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(width: 900, height: 700)
        }
    }

    private static func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = findView(type, in: sub) { return found } }
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

        // MARK: Cmd+A in a view without multi-selection
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
                // Every gallery view supports Select All; the grid's own Cmd+A must agree.
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
            if let tv = findView(DraggableListTableView.self, in: host), let event = cmdAEvent(window) {
                tv.keyDown(with: event)
                await drainTurns(window)
                r.check("list-direct-cmd-a-inert",
                        selection.selectedFilmIDs.count <= 1 && tv.selectedRowIndexes.count <= 1,
                        "model \(selection.selectedFilmIDs.count), list \(tv.selectedRowIndexes.count) of \(tv.numberOfRows)")
            } else {
                r.check("list-direct-cmd-a-inert", false, "no list mounted")
            }
            await unmount(window, host)
        } else {
            r.check("cmd-a-view-unsupported", false, "no unsupported view had films")
        }

        // Positive control: where Select All IS supported, the gallery's own Cmd+A still works.
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

                // Control: focus with no selection at all still seeds item 0.
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
        // With the main window on Imports no gallery of its own is mounted, so the only
        // thing that could prune a selection naming a film no gallery holds is the
        // dismantled one. Its collection/table view is held alive on purpose: that is the
        // condition under which a loop that outlived its dismantle would still act.
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

// MARK: - First selection

// `first-selection` (opt-in, a measurement; run it ALONE so nothing earlier warms the
// sidebar): the first film selection of a session against later ones, in the real main
// window. Each selection starts from an empty selection, as the first one after launch
// does, and is read with the reports-hitch recorder: `first` is the busy stretch until the
// frame carrying the sidebar content is committed. The launch-time SidebarPrewarm runs as
// in production; FT_NO_SIDEBAR_PREWARM=1 turns it off to measure the cold path.
#if DEBUG
extension DebugHarness {
    static func firstSelectionScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "first-selection")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(2000)
        // A fresh sandbox is empty at launch, so the launch-time call found no film; make
        // it here, where the library now looks as a real one does at launch.
        SidebarPrewarm.runIfIdle(dataCoordinator: coordinator)
        await settle(1000)
        let films = coordinator.films
        guard films.count > 40 else { r.check("films", false, "\(films.count)"); return r }
        let selection = SelectionState.shared
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        // FT_FIRST_SELECTION_ARM=1 announces the pid and holds, so an external `sample`
        // can be attached before the first selection.
        if ProcessInfo.processInfo.environment["FT_FIRST_SELECTION_ARM"] == "1" {
            FileHandle.standardError.write("FIRST-SELECTION-ARMED \(getpid())\n".data(using: .utf8)!)
            await settle(4000)
        }
        for i in 0..<8 {
            selection.selectImmediate(nil as UUID?)
            await settle(700)
            recorder.reset()
            // Main-thread CPU beside wall time: a gap between them is time spent blocked.
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let t0 = CACurrentMediaTime() * 1000
            selection.selectImmediate(films[5 + i * 4].id)
            await settle(1200)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            let reading = recorder.reading(from: t0, window: 1200)
            r.check("select-\(Fmt.int(i))", true,
                    "first \(Fmt.fixed(reading.first, 1)) ms, busy \(Fmt.fixed(reading.busy, 1)) ms, cpu \(Fmt.fixed(cpu, 1)) ms, longest \(Fmt.fixed(reading.longest, 1)) ms, stretches \(Fmt.int(reading.stretches))")
        }
        return r
    }
}

// MARK: - Coast Stop
//
// `coast-stop` (opt-in; seeds 600 films and puts a window on screen for a few seconds, so
// it is kept out of `all`): Cmd+L during a coasting scroll lands on the selection and the
// content stays there, in both gallery styles — CoastingScrollStopper (23.20).
//
// A real trackpad coast cannot be synthesized: AppKit tracks it on a background thread fed
// straight from the window server. AppKit's own automated live scroll (`_automateLiveScroll`)
// is the stand-in. It runs on the same concurrent scrolling behavior, overruns a
// programmatic jump exactly as a coast does (the control checks prove the scenario sees
// the bug), and ends on `_stopGestureScrollTracking` with didEndLiveScroll arriving after
// the call — the stopper's deferred path. The synchronous path and real flicks were
// verified by hand on 2026-10-04. The window must be on screen: the automation is driven
// by the display link.
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
            // The coast is the precondition, not the subject: act as soon as it is visibly
            // under way rather than after a fixed delay, which a short coast could outlast.
            func awaitCoastUnderway() async {
                for _ in 0..<15 where !(probe.isLive && y() > 40) { await wait(20) }
            }

            // Control: without the stop, a programmatic jump during the coast does not stick.
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

            // Cmd+L during the coast.
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

            // The viewport-jump tracer: silent for Cmd+L (an app move), and still flags a
            // large move nobody claimed (positive control).
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
//
// `scroll-memory` (opt-in, real main window, 1,400-film reportsCorpus): the remembered-scroll-
// position bugs found by the 2026-10-04 audit, each driven through real navigation with
// maintainScrollPositionOnViewSwitch on. Every check failed before its fix:
//
//   • T1 Film Queue tab restore in LIST style (the list applied the incoming tab's origin to
//     the outgoing tab's rows, then zeroed) — galleries now key by the loaded filter.
//   • T2 Reports / Imports round trip after a wheel scroll to the top (stale deeper origin;
//     raced on whether the outgoing GalleryView's onChange switched views) — navigate banks.
//   • T3 search exit with a preserved selection puts the film's row at the top (as far as the
//     content allows), wherever it stood — cut off at the bottom edge, mid-viewport, near the end.
//   • T6 a filter that empties the gallery, then cleared (fresh remount restored a stale
//     origin) — the emptying pass banks.
//   • T7 an order-preserving Film Queue section move consumes its scroll intent in place.
//   • T5 an empty Queue tab is not credited with the previous tab's position (guard).
//   • T10/T11 restores are film-anchored: a narrower window (fewer columns) or a row of films
//     inserted above while away still opens on the same top film (pixel restores did not).
//   • T12 an anchor film that moved on its own does not drag the view after it.
//   • T13 with maintainSelectionOnSearchExit off, a search exit preserves and scrolls nothing.
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
                let rows = tv.rows(in: tv.visibleRect)   // All Films, dividers off: row == film index
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

        // ---- P1 + T2: grid, wheel scroll to top, Reports round trip
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

        // Same, but leaving via a sidebar switch (prepareScrollHandoff path) as a control.
        setY(6000); await settle(200)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        setY(0); await settle(200)
        appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
        appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
        r.check("T2-control-sidebar-round-trip-keeps-top", y() < 1, "y \(y())")

        // ---- T3: search exit with a preserved selection always puts the film's row at the
        // top of the viewport — as far as the content allows — wherever the film stood in the
        // view the user returns to: cut off at the bottom edge, fully visible mid-viewport, or
        // near the end of the content. In a user list, in both styles. (Was: left alone when
        // visible, which could return a film half outside the viewport.)
        let probeListID = coordinator.createList(name: "Scroll Probe", displayOrder: 990)
        _ = coordinator.addFilmsToList(filmIDs: Set(coordinator.films.prefix(600).map(\.id)), listID: probeListID)
        // The film's content frame and the viewport, for whichever style is mounted.
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
                // Bank this position, so the return restores it before placing the film.
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

        // ---- T10–T13: film-anchored restores, and the search-exit preference gate.
        manager.updateShowSectionDividers(false); await settle(400)

        // T10: the column count changes while away (the window is narrowed).
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

        // T11: films inserted above the viewport while away, both styles.
        var inserted = 0
        for listStyle in [false, true] {
            manager.updateListViewStyle(listStyle); await settle(800)
            setY(6000); await settle(300)
            guard let before = topFilm() else { r.check("T11-top-film", false, ""); continue }
            appState.navigate(to: .libraryItem(.unwatched)); await settle(800)
            // Titles beginning with a digit sort last; these sort ahead of every corpus title.
            // One full grid row's worth, so a pixel restore would leave the top film a row down.
            let insertCount = listStyle ? 3 : max(1, columns())
            let names = (0..<insertCount).map { _ in inserted += 1; return "AAAA Inserted \(inserted)" }
            coordinator.importFilms(names.map { makeSnapshot(name: $0) })
            await settle(500)
            appState.navigate(to: .libraryItem(.allFilms)); await settle(1000)
            let after = topFilm()
            let above = coordinator.films.indices.filter { names.contains(coordinator.films[$0].name) }
                .allSatisfy { $0 < (after?.index ?? 0) }
            // Grid: the anchor film is back in the top row (it may sit further along the row).
            let kept = listStyle ? after?.id == before.id : topRowFilmIDs().contains(before.id)
            r.check("T11-\(listStyle ? "list" : "grid")-insertions-keep-top-film", above && kept,
                    "inserted \(insertCount) above \(above); top film index \(before.index) → \(after?.index ?? -1); anchor film in top row \(kept)")
        }
        manager.updateListViewStyle(false); await settle(800)

        // T12: the anchor film itself moves far away (renamed to sort last) — stay in region.
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

        // T13: with the preference off, a search exit preserves nothing and scrolls nowhere.
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

        // ---- T6: same-view remount (filter empties the gallery, then cleared) after a
        // non-gesture scroll to the top. Bank 6000 first via a sidebar round trip.
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
        // Same with the arrow keys as the scroll input.
        await bankDeep()
        await keysToTop()
        let keyedTop = y()
        manager.updateFilterOptions([.color, .blackAndWhite]); await settle(700)
        manager.clearFilters(); await settle(1000)
        r.check("T6-keys-filter-round-trip-keeps-top", keyedTop < 1 && y() < 1,
                "at top after keys \(keyedTop), after round trip \(y())")

        // ---- T1: Film Queue tab restore, grid and list
        // "Up Next" holds at most FilmQueue.upNextCapacity films, so it gets one fewer than
        // that — leaving the vacancy T7's move into it needs — and "Soon" is the long,
        // scrollable section T1 restores.
        let all = coordinator.films.map(\.id)
        let upNextSeed = FilmQueue.upNextCapacity - 1
        seedFilmQueue(coordinator, upNext: all[0..<upNextSeed], soon: all[upNextSeed..<600])
        appState.navigate(to: .libraryItem(.filmQueue)); await settle(1000)
        let fq = FilmQueueFilterState.shared

        // ---- T5: empty Queue tab. "Later" is empty; leaving "All" (at 4000) for it must not
        // file All's position under Later's key.
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
        // ---- T7: a Film Queue section move that leaves the All tab's order unchanged must
        // not leave its post-move scroll intent pending (grid style).
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
            // Restores are film-anchored: a film added or removed above Soon's top film moves
            // that film by one place, and the restore follows it. Intact = it is still the
            // top row's film (the bug opened Soon at 0).
            let topRowIDs = topRowFilmIDs()
            r.check("T7-\(label)-soon-restore-intact",
                    y() > 0 && soonTop.map { topRowIDs.contains($0.id) } == true,
                    "soon saved \(soonSaved) opened at \(y()); saved top film in top row \(soonTop.map { topRowIDs.contains($0.id) } ?? false)")
            GalleryScrollIntent.shared.clear()
            // Undo the move.
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
//
// `queue-mixed-style` (opt-in, real main window): a Film Queue tab switch between two tabs of
// DIFFERENT grid/list styles. Samples every committed frame (a run-loop observer after Core
// Animation's commit) for the mounted style and its film count. Before the fix (2026-10-04)
// the incoming style was built around the outgoing tab's films and committed that way — the
// grid holding Up Next's 8 films under "All", the list holding All's 900 under "Up Next" —
// then reloaded; and the outgoing style's last pass could commit the incoming films in the
// outgoing style. GalleryView now presents ViewStateManager.displayedGalleryState, and both
// styles skip a Queue pass whose presented style is not theirs.
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
        // "Up Next" is capped at FilmQueue.upNextCapacity (8); "Soon" takes the rest.
        let upNextSeed = FilmQueue.upNextCapacity
        seedFilmQueue(coordinator, upNext: all[0..<upNextSeed], soon: all[upNextSeed..<600], later: all[600..<900])
        appState.navigate(to: .libraryItem(.filmQueue)); await settle(1000)
        let fq = FilmQueueFilterState.shared
        fq.selectFilter(.all); await settle(700); manager.updateListViewStyle(false); await settle(700)
        fq.selectFilter(.upNext); await settle(700); manager.updateListViewStyle(true); await settle(700)
        fq.selectFilter(.all); await settle(900)

        // What each committed frame holds: mounted style and displayed film count.
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
            // start from the opposite tab
            await settle(600)
            frames = [snapshot()]
            ViewSwitchProbe.isEnabled = true; ViewSwitchProbe.reset()
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            fq.selectFilter(target)
            await settle(800)
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let events = ViewSwitchProbe.events
            ViewSwitchProbe.isEnabled = false
            // Every committed frame must pair a style with ITS tab's films, judged by what the
            // view displays: All (grid) holds 900 films, Up Next (list) 8 rows. The outgoing
            // tab may stay on screen in its own style while the deferred reload is pending;
            // never both styles at once, never a style around the other tab's films.
            let targetStyle = target == .upNext ? "list" : "grid"
            let wrong = frames.filter { f in
                f.contains("+") || f.hasPrefix("grid:\(upNextSeed)/") || f.hasPrefix("list:9")
            }
            r.check("\(label)-no-wrong-content-frame", wrong.isEmpty && frames.count >= 2,
                    "frames \(frames)")
            // The incoming style is built once, around the incoming films, and that is the only
            // reload: the outgoing style skips the pass SwiftUI may still give it (its style
            // guard), which otherwise reloaded it with the incoming films and could commit.
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
//
// `upnext-slots` (opt-in, real main window): the "Up Next" cap and its empty slots
// (UpNextSlots.swift). The Queue's "All" tab draws one slot per vacancy after the "Up Next"
// films, in both gallery styles, numbered from the first vacancy; a row of nothing but slots
// is skipped by Up/Down; a full "Up Next" draws none; an empty one draws its own band and
// all eight. Adds past the cap are refused with an alert. The slot sheet searches with its
// own SearchController and leaves the gallery's search alone. Window snapshots go to the
// sandbox's `upnext-slots/` folder for a visual check.
extension DebugHarness {
    static func upNextSlotsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "upnext-slots")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else { r.check("window", false, ""); return r }
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

        // ---- Grid: three films, five slots numbered 4–8, laid out as the next cells.
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
        // Up/Down skip a row of nothing but slots. With 3 films in a row of ≥ 6 columns the
        // slots spill into a second, slot-only row (8 > columns); a narrower grid has none.
        let slotOnlyRows = (0..<12).filter { layout.isSlotOnlyRow($0) }
        let expectSlotOnly = layout.columnsPerRow < 8 && (3 + 5) > layout.columnsPerRow
            && ((3 + 5 + layout.columnsPerRow - 1) / layout.columnsPerRow) > ((3 + layout.columnsPerRow - 1) / layout.columnsPerRow)
        r.check("grid/slot-only-rows", expectSlotOnly == !slotOnlyRows.isEmpty,
                "slot-only rows \(slotOnlyRows), columns \(layout.columnsPerRow)")
        snapshot("grid-3-films")

        // ---- List: the same slots as rows, after the "Up Next" films, before "Soon".
        manager.updateListViewStyle(true); await settle(1000)
        if let table = allViews(window.contentView!).compactMap({ $0 as? DraggableListTableView }).first {
            // 3 bands + 33 films + 5 slots.
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

        // ---- The cap: an add past eight is refused whole, with an alert.
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

        // ---- Full: no slots. Empty: its own band and all eight.
        FilmQueueAssignment.toggle(five, section: .upNext, coordinator: coordinator); await settle(1200)
        slots = slotViews()
        r.check("full/no-slots", FilmQueue.upNextFilmIDs(coordinator: coordinator).count == 8 && slots.isEmpty,
                "\(FilmQueue.upNextFilmIDs(coordinator: coordinator).count) in Up Next, \(slots.count) slot(s)")
        FilmManager.removeFromFilmQueue(upNext.union(five), coordinator: coordinator); await settle(1200)
        slots = slotViews()
        r.check("empty/all-eight", slots.map(\.slotNumber) == Array(1...8), "\(slots.map(\.slotNumber))")
        let bands = allViews(window.contentView!).compactMap { $0 as? SectionDividerDecorationView }
        r.check("empty/own-band", bands.count >= 2, "\(bands.count) bands")
        snapshot("grid-empty-up-next")
        _ = coordinator.addFilmsToList(filmIDs: upNext, listID: upNextID); await settle(900)

        // ---- The slot sheet: its own search, leaving the gallery's alone.
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
//
// `sidebar-tab-switch` (opt-in, a measurement): what a RightSidebar tab change costs once
// the selected film's neighbor tabs are resident — the common "select a film, then look at
// its Releases" path. Each step reads AppKitScrollHandoffProbe (how many hosting views had
// their rootView reassigned, each a full re-measure of that tab's tree) and the run-loop
// busy time. Switches by button (instant) and by swipe (animated) are measured separately.
// Uses the sandbox's own library when it has one, so a real-data copy gives real tab weight.
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
        // The heaviest Releases tab available, so the measurement is not of an empty tree.
        let film = films.max { $0.releases.count < $1.releases.count } ?? films[0]
        let manager = ViewStateManager.shared
        manager.setRightSidebarTab(.details)
        SelectionState.shared.selectImmediate(film.id)
        // Past the 180 ms neighbor-arming quiet window, with margin.
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
            // Exactly one of the resident tab scroll views may take clicks at rest; the
            // others sit off the plane and must be gated (hitTest returns nil).
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

// MARK: - Right Sidebar Load
//
// `rsb-load` (opt-in, a measurement; not in any suite): what one film-to-film selection
// costs the right sidebar on the main thread, split into the visible tab's build (the busy
// stretches within 150 ms of the selection) and the neighbor-tab arming that follows the
// 180 ms quiet window (every stretch after that). Run once per starting tab, since the
// middle tab (Releases) arms two neighbors and the end tabs one. Films with notes are used
// so Notes is never disabled. Launch flags for A/B runs: see RSBProfileFlags (24.00).
//
// FT_RSB_LOOP_SECONDS=<n> then re-selects films on the Releases tab for n seconds, after
// writing "RSB-LOOP-ARMED <pid>" to stderr and holding 3 s, so `sample` can be attached.
#if DEBUG
extension DebugHarness {
    static func rsbLoadScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-load")
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        if !coordinator.hasDatabaseFilms { coordinator.importFilms(reportsCorpus()) }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(2000)

        let withNotes = coordinator.films.filter(\.hasNotesContent)
        guard withNotes.count >= 8 else {
            r.check("films", false, "\(withNotes.count) films with notes")
            return r
        }
        // Evenly spaced through the gallery order, so the set is not all one kind of film.
        let count = min(17, withNotes.count)
        let films = (0..<count).map { withNotes[$0 * withNotes.count / count] }
        r.check("films", true, "\(Fmt.int(count)) of \(Fmt.int(withNotes.count)) films with notes; flags: "
                + "allAtOnce \(RSBProfileFlags.neighborsAllAtOnce), noTopPinned \(RSBProfileFlags.noTopPinnedLayout), "
                + "noViewport \(RSBProfileFlags.noViewport)")

        let selection = SelectionState.shared
        let manager = ViewStateManager.shared
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }

        /// The busy stretches in [t0, t0 + window], as (start offset, duration) in ms.
        func stretches(from t0: Double, window: Double) -> [(start: Double, duration: Double)] {
            var out: [(Double, Double)] = []
            var busySince: Double? = t0
            for e in recorder.events where e.time >= t0 && e.time <= t0 + window {
                if e.idle, let since = busySince {
                    out.append((since - t0, e.time - since))
                    busySince = nil
                } else if !e.idle {
                    busySince = e.time
                }
            }
            return out
        }

        for tab in [RightSidebarTab.details, .releases, .notes] {
            manager.setRightSidebarTab(tab)
            selection.selectImmediate(films[0].id)
            await settle(1500)
            var visible: [Double] = [], neighborTotal: [Double] = [], neighborLongest: [Double] = []
            var neighborCounts: [Double] = [], cpus: [Double] = []
            for film in films.dropFirst() {
                recorder.reset()
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let t0 = CACurrentMediaTime() * 1000
                selection.selectImmediate(film.id)
                await settle(1000)
                cpus.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6)
                let all = stretches(from: t0, window: 1000)
                let early = all.filter { $0.start < 150 }
                let late = all.filter { $0.start >= 150 && $0.duration >= 1 }
                visible.append(early.reduce(0) { $0 + $1.duration })
                neighborTotal.append(late.reduce(0) { $0 + $1.duration })
                neighborLongest.append(late.map(\.duration).max() ?? 0)
                neighborCounts.append(Double(late.count))
            }
            let name = tab.rawValue
            r.metric("\(name)-visible-median", median(visible), "ms")
            r.metric("\(name)-neighbors-total-median", median(neighborTotal), "ms")
            r.metric("\(name)-neighbors-longest-median", median(neighborLongest), "ms")
            r.metric("\(name)-cpu-median", median(cpus), "ms")
            r.check(name, true,
                    "visible \(Fmt.fixed(median(visible), 1)) ms (max \(Fmt.fixed(visible.max() ?? 0, 1))), "
                    + "neighbors total \(Fmt.fixed(median(neighborTotal), 1)) ms, "
                    + "longest \(Fmt.fixed(median(neighborLongest), 1)) ms (max \(Fmt.fixed(neighborLongest.max() ?? 0, 1))), "
                    + "stretches \(Fmt.fixed(median(neighborCounts), 0)), cpu \(Fmt.fixed(median(cpus), 1)) ms")
        }

        if let seconds = Double(ProcessInfo.processInfo.environment["FT_RSB_LOOP_SECONDS"] ?? "") {
            manager.setRightSidebarTab(.releases)
            FileHandle.standardError.write("RSB-LOOP-ARMED \(getpid())\n".data(using: .utf8)!)
            await settle(3000)
            let end = CACurrentMediaTime() + seconds
            var i = 0
            while CACurrentMediaTime() < end {
                selection.selectImmediate(films[i % films.count].id)
                i += 1
                await settle(450)
            }
            r.check("loop", true, "\(Fmt.int(i)) selections")
        }
        selection.selectImmediate(nil as UUID?)
        return r
    }
}
#endif

// MARK: - Right Sidebar Modules
//
// `rsb-modules` (opt-in, a measurement): what each right sidebar module costs to re-point
// at a new film, measured alone. Each module is hosted in its own NSHostingView in an
// off-screen window, at the width the sidebar gives it, with the environment RightSidebar
// injects; a film change is a rootView hand-off plus layoutSubtreeIfNeeded, and the cost is
// main-thread CPU across that call and the two run-loop turns after it. The same films as
// `rsb-load`. Whole tabs are measured too, scroll view included.
#if DEBUG
extension DebugHarness {
    static func rsbModulesScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-modules")
        func turn() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
        func cpuMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

        let withNotes = coordinator.films.filter(\.hasNotesContent)
        guard withNotes.count >= 8 else {
            r.check("films", false, "\(withNotes.count) films with notes")
            return r
        }
        let count = min(17, withNotes.count)
        let films = (0..<count).map { withNotes[$0 * withNotes.count / count] }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        window.contentView = container

        /// `width` is what the module is offered: 268 inside a tab's 16 pt insets, 300 for a tab.
        func profile(_ name: String, width: CGFloat, height: CGFloat? = nil,
                     _ make: @escaping (FilmSnapshot) -> AnyView) async {
            func root(_ film: FilmSnapshot) -> AnyView {
                AnyView(make(film)
                    .frame(width: width, height: height)
                    .environment(\.sidebarFilm, film)
                    .environment(coordinator))
            }
            let host = NSHostingView(rootView: root(films[0]))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 800)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            await turn(); await turn()
            var costs: [Double] = []
            for (i, film) in films.enumerated() where i > 0 {
                let c0 = cpuMS()
                host.rootView = root(film)
                host.layoutSubtreeIfNeeded()
                await turn(); await turn()
                costs.append(cpuMS() - c0)
                if name == "metadata" {
                    let rows = film.cast.count + film.directors.count + film.producers.count
                        + film.executiveProducers.count + film.screenwriters.count + film.composer.count
                        + film.studio.count
                    r.check("metadata-film-\(Fmt.int(i))", true, "\(Fmt.fixed(costs.last!, 2)) ms, crew rows \(Fmt.int(rows)), "
                            + "tags \(Fmt.int(film.tags.count)), alt \(Fmt.int(film.alternateTitle.count)), "
                            + "notes \(Fmt.int(film.notes.count)) ch, comments \(Fmt.int(film.comments.count)) ch")
                }
                if name == "tab-releases" {
                    r.check("releases-film-\(Fmt.int(i))", true, "\(Fmt.fixed(costs.last!, 2)) ms, releases "
                            + "\(Fmt.int(film.releases.count)), summary table \(Preferences.showReleasesSummaryTable)")
                }
                if name == "tab-notes" {
                    let text = film.warning.count + film.notesOnAudioTiming.count + film.specialAudioNotes.count
                        + film.notesArray.count + film.tools.count
                    r.check("notes-film-\(Fmt.int(i))", true, "\(Fmt.fixed(costs.last!, 2)) ms, frames rows "
                            + "\(Fmt.int(film.handbrakeFrames.count + film.correspondingTimecodes.count)), "
                            + "text entries \(Fmt.int(text))")
                }
            }
            // FT_RSB_MODULE_LOOP=<name> keeps re-pointing that one module for 12 s, after
            // writing "RSB-LOOP-ARMED <pid>" to stderr and holding 3 s, for `sample`.
            if ProcessInfo.processInfo.environment["FT_RSB_MODULE_LOOP"] == name {
                FileHandle.standardError.write("RSB-LOOP-ARMED \(getpid())\n".data(using: .utf8)!)
                try? await Task.sleep(for: .seconds(3))
                let end = CACurrentMediaTime() + 12
                var i = 0
                while CACurrentMediaTime() < end {
                    host.rootView = root(films[i % films.count])
                    host.layoutSubtreeIfNeeded()
                    await turn()
                    i += 1
                }
            }
            // The first switches warm caches; report the rest.
            let steady = Array(costs.dropFirst(2))
            r.metric("\(name)-median", median(steady), "ms")
            r.check(name, true, "median \(Fmt.fixed(median(steady), 2)) ms, max \(Fmt.fixed(steady.max() ?? 0, 2)) ms")
            host.removeFromSuperview()
        }

        let collapsed = Binding.constant(false)
        await profile("header", width: 268) { AnyView(Header(filmID: $0.id)) }
        await profile("watch-details", width: 268) { _ in AnyView(WatchDetails()) }
        await profile("calendar-table", width: 268) { _ in AnyView(CalendarTable(isTableExpanded: collapsed)) }
        await profile("list-table", width: 268) { _ in AnyView(ListTable(isTableExpanded: collapsed)) }
        await profile("synopsis", width: 268) { _ in AnyView(Synopsis()) }
        await profile("metadata", width: 268) { _ in AnyView(Metadata()) }
        await profile("tab-details", width: 300, height: 700) { _ in
            AnyView(RTabDetails(calendarTableExpanded: collapsed, listTableExpanded: collapsed)) }
        await profile("tab-releases", width: 300, height: 700) { _ in
            AnyView(RTabReleases(releasesSummaryExpanded: collapsed, purchaseFilter: .constant(.all))) }
        await profile("tab-notes", width: 300, height: 700) { _ in AnyView(RTabNotes()) }
        window.close()
        return r
    }
}
#endif

// MARK: - Release Card Cost
//
// `rsb-cards` (opt-in, a measurement): what one release card costs, measured as `rsb-modules`
// measures the Releases tab, across three sets of real films — one single card, one two-disc
// combo-pack card, and no card at all (the tab's own cost, to subtract).
#if DEBUG
extension DebugHarness {
    static func rsbCardsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-cards")
        func turn() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
        func cpuMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func groups(_ f: FilmSnapshot) -> [[ReleaseSnapshot]] {
            releasesGroupedByHierarchy(f.releases.filter { ReleaseFormat(rawValue: $0.format) != nil })
        }
        func spread(_ v: [FilmSnapshot]) -> [FilmSnapshot] {
            let n = min(13, v.count)
            return (0..<n).map { v[$0 * v.count / n] }
        }
        let singles = spread(coordinator.films.filter { let g = groups($0); return g.count == 1 && g[0].count == 1 })
        let combos = spread(coordinator.films.filter { let g = groups($0); return g.count == 1 && g[0].count == 2 })
        let empty = spread(coordinator.films.filter { groups($0).isEmpty })
        guard singles.count >= 6, combos.count >= 6, empty.count >= 6 else {
            r.check("films", false, "singles \(singles.count), combos \(combos.count), empty \(empty.count)")
            return r
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        window.contentView = container
        let collapsed = Binding.constant(false)

        func profile(_ name: String, _ films: [FilmSnapshot]) async {
            func root(_ film: FilmSnapshot) -> AnyView {
                AnyView(RTabReleases(releasesSummaryExpanded: collapsed, purchaseFilter: .constant(.all))
                    .frame(width: 300, height: 700)
                    .environment(\.sidebarFilm, film)
                    .environment(coordinator))
            }
            // Each set alternates with a film from `empty`, so every measured step builds its
            // card from nothing, as a new selection does, rather than re-pointing a card.
            let host = NSHostingView(rootView: root(empty[0]))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            await turn(); await turn()
            var costs: [Double] = []
            // Per build: the rootView hand-off, the layout pass, the two turns after it, and
            // what the AppKit rows did (CardRowsProbe).
            var handOff: [Double] = [], layout: [Double] = [], after: [Double] = []
            var ours: [Double] = [], created: [Double] = []
            for round in 0..<2 {
                for (i, film) in films.enumerated() {
                    host.rootView = root(empty[(i + 1) % empty.count])
                    host.layoutSubtreeIfNeeded()
                    await turn(); await turn()
                    CardRowsProbe.reset()
                    let c0 = cpuMS()
                    host.rootView = root(film)
                    let c1 = cpuMS()
                    host.layoutSubtreeIfNeeded()
                    let c2 = cpuMS()
                    let before = (CardRowsProbe.layouts, CardRowsProbe.rowsCreated)
                    await turn(); await turn()
                    let c3 = cpuMS()
                    let afterCalls = (CardRowsProbe.layouts - before.0, CardRowsProbe.rowsCreated - before.1)
                    if round == 1 {
                        costs.append(c3 - c0)
                        handOff.append(c1 - c0); layout.append(c2 - c1); after.append(c3 - c2)
                        ours.append(CardRowsProbe.layoutTime * 1000)
                        created.append(Double(CardRowsProbe.rowsCreated))
                        if i < 3 {
                            let sv = findView(NSScrollView.self, in: host, where: { _ in true })
                            r.check("\(name)-film-\(i)-scroll", true, "scroller style \(sv?.scrollerStyle.rawValue ?? -1), "
                                    + "vertical shown \(sv.map { !($0.verticalScroller?.isHidden ?? true) } ?? false), "
                                    + "document \(sv?.documentView?.frame.size ?? .zero), clip \(sv?.contentView.bounds.size ?? .zero)")
                            r.check("\(name)-film-\(i)-rows", true, "row layouts \(CardRowsProbe.rowLayouts), label moves \(CardRowsProbe.labelMoves), "
                                    + "row layout time \(Fmt.fixed(CardRowsProbe.rowLayoutTime * 1000, 2)) ms")
                            r.check("\(name)-film-\(i)", true, "\(Fmt.fixed(c3 - c0, 2)) ms; in layout: \(before.0) layouts, \(before.1) rows made; "
                                    + "after: \(afterCalls.0) layouts, \(afterCalls.1) rows made")
                        }
                    }
                }
            }
            r.check("\(name)-phases", true, "hand-off \(Fmt.fixed(median(handOff), 2)), layout \(Fmt.fixed(median(layout), 2)), "
                    + "after \(Fmt.fixed(median(after), 2)) ms; AppKit rows' own code \(Fmt.fixed(median(ours), 2)) ms, "
                    + "\(Fmt.fixed(median(created), 0)) rows made")
            // FT_RSB_MODULE_LOOP=<name> repeats the set for 12 s, for `sample`.
            if ProcessInfo.processInfo.environment["FT_RSB_MODULE_LOOP"] == name {
                FileHandle.standardError.write("RSB-LOOP-ARMED \(getpid())\n".data(using: .utf8)!)
                try? await Task.sleep(for: .seconds(3))
                let end = CACurrentMediaTime() + 12
                var i = 0
                while CACurrentMediaTime() < end {
                    host.rootView = root(i % 2 == 0 ? films[(i / 2) % films.count] : empty[(i / 2) % empty.count])
                    host.layoutSubtreeIfNeeded()
                    await turn()
                    i += 1
                }
            }
            r.metric("\(name)-median", median(costs), "ms")
            r.check(name, true, "median \(Fmt.fixed(median(costs), 2)) ms, min \(Fmt.fixed(costs.min() ?? 0, 2)), "
                    + "max \(Fmt.fixed(costs.max() ?? 0, 2)) ms over \(costs.count) films")
            host.removeFromSuperview()
        }
        await profile("empty", empty)
        await profile("single", singles)
        await profile("combo", combos)
        window.close()
        return r
    }
}
#endif

// MARK: - Right Sidebar Row Variants
//
// `rsb-rows` (opt-in, a measurement): which part of a Metadata crew row costs what. The same
// twelve-name list is built several ways and re-pointed across real films' casts, measured
// as `rsb-modules` measures a module.
#if DEBUG
extension DebugHarness {
    private struct RowVariantList: View {
        let names: [String]
        let selectable: Bool
        let button: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .modifier(OptionalSelection(on: selectable))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if button {
                            Button {} label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                        }
                    }
                    .sidebarRowContainer(glyph: "person", glyphColor: .secondary)
                }
            }
        }
    }

    private struct OptionalSelection: ViewModifier {
        let on: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if on { content.textSelection(.enabled) } else { content }
        }
    }

    static func rsbRowsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-rows")
        func turn() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
        func cpuMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

        // `-FTRowsVarying`: each list takes a different length (4 to 20 names), as a real
        // film's crew sections do, so rows are inserted and removed rather than only updated.
        let varying = ProcessInfo.processInfo.arguments.contains("-FTRowsVarying")
        let lengths = [12, 5, 18, 9, 20, 4, 14, 7, 16, 11, 19, 6, 13, 8, 17, 10, 15]
        let pool = coordinator.films.flatMap(\.cast)
        let casts: [[String]] = pool.count < 400 ? [] : (0..<17).map { i in
            Array(pool[(i * 20)..<(i * 20 + (varying ? lengths[i] : 12))]) }
        guard casts.count >= 8 else { r.check("films", false, "\(pool.count) cast names"); return r }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        window.contentView = container

        func profile(_ name: String, _ make: @escaping ([String]) -> AnyView) async {
            func root(_ names: [String]) -> AnyView { AnyView(make(names).frame(width: 268)) }
            let host = NSHostingView(rootView: root(casts[0]))
            host.frame = NSRect(x: 0, y: 0, width: 268, height: 800)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            await turn(); await turn()
            var costs: [Double] = []
            for names in casts.dropFirst() {
                let c0 = cpuMS()
                host.rootView = root(names)
                host.layoutSubtreeIfNeeded()
                await turn(); await turn()
                costs.append(cpuMS() - c0)
            }
            let steady = Array(costs.dropFirst(2))
            r.metric("\(name)-median", median(steady), "ms")
            r.check(name, true, "median \(Fmt.fixed(median(steady), 2)) ms, max \(Fmt.fixed(steady.max() ?? 0, 2)) ms")
            host.removeFromSuperview()
        }

        await profile("current") { AnyView(RowVariantList(names: $0, selectable: true, button: true)) }
        await profile("no-selection") { AnyView(RowVariantList(names: $0, selectable: false, button: true)) }
        await profile("no-button") { AnyView(RowVariantList(names: $0, selectable: true, button: false)) }
        await profile("text-only") { AnyView(RowVariantList(names: $0, selectable: false, button: false)) }
        await profile("metadata-section") { names in
            AnyView(RSBHelpers.searchableItemSection(title: "Cast", items: names, field: .cast,
                                                     glyph: "person", glyphColor: .secondary))
        }
        window.close()
        return r
    }
}
#endif

// MARK: - Crew Row Parity
//
// `rsb-crew-parity` (opt-in; puts a window on screen): CrewRowList's AppKit rows against
// SearchableItemRow, the SwiftUI rows they stand in for. Both are drawn in one window from
// the same names, light and dark, captured through the window server at full resolution,
// and compared pixel by pixel. The captures and a diff image (differing pixels in red) go
// to `harness-reports/crew-parity/`. Also logs the view tree of the SwiftUI row, so the
// AppKit row's controls can be matched to what SwiftUI actually builds.
#if DEBUG
extension DebugHarness {
    private struct CrewParityContent: View {
        let names: [String]
        let glyph: String?
        var tint: Color = .secondary
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        SearchableItemRow(item: name, field: .cast, glyph: glyph, glyphColor: tint)
                    }
                }
                .frame(width: 268)
                CrewRowList(items: names, field: .cast, glyph: glyph, glyphColor: tint)
                    .frame(width: 268)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    static func rsbCrewParityScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-crew-parity")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let grab = unsafe windowImageFunction else {
            r.check("capture-available", false, "CGWindowListCreateImage did not resolve")
            return r
        }
        let names = ["Tom Hanks", "Catherine Zeta-Jones", "A Remarkably Long Name That Has To Truncate Here"]
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CrewParityContent(names: names, glyph: "person"))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle(800)

        // What SwiftUI builds for one row.
        var lines: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            var line = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)"
            if let b = v as? NSButton {
                line += " bezel \(b.bezelStyle.rawValue) size \(b.controlSize.rawValue) bordered \(b.isBordered) "
                    + "image \(b.image?.size ?? .zero) imagePos \(b.imagePosition.rawValue) font \(b.font?.pointSize ?? 0) "
                    + "symbolConfig \(String(describing: b.symbolConfiguration)) title '\(b.title)'"
            }
            if let t = v as? NSTextField { line += " font \(t.font?.pointSize ?? 0) '\(t.stringValue)'" }
            lines.append(line)
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(host, 0)
        log("CREW-PARITY TREE\n" + lines.joined(separator: "\n"))

        guard let list = findView(CrewRowListView.self, in: host) else {
            r.check("mounted", false, "no CrewRowListView")
            return r
        }

        // Behavior: each row's button sends the token search for its own name, and its name
        // is selectable, with the SwiftUI row's tooltip.
        var received: [String] = []
        let subscription = AppEventBus.shared.uiCommands.sink { command in
            if case .activateTokenSearch(let field, let value) = command { received.append("\(field.rawValue):\(value)") }
        }
        var buttons: [NSButton] = [], labels: [NSTextField] = []
        var stack: [NSView] = [list]
        while let v = stack.popLast() {
            if let b = v as? NSButton { buttons.append(b) }
            if let t = v as? NSTextField { labels.append(t) }
            stack.append(contentsOf: v.subviews.reversed())
        }
        for b in buttons { b.performClick(nil) }
        await settle(100)
        subscription.cancel()
        r.check("search-buttons", received == names.map { "cast:\($0)" }, received.joined(separator: " | "))
        r.check("selectable-names", !labels.isEmpty && labels.allSatisfy { $0.isSelectable && !$0.isEditable },
                "\(labels.count) labels")
        r.check("tooltips", !buttons.isEmpty && buttons.allSatisfy { $0.toolTip == "Perform a token-based search for this name" },
                "\(buttons.count) buttons")
        let listFrame = list.convert(list.bounds, to: nil)   // window coordinates, bottom-left
        r.check("heights", true, "AppKit list \(Fmt.fixed(listFrame.height, 2)) pt, row \(Fmt.fixed(CrewRowView.height, 2)) pt")

        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/crew-parity", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func png(_ image: CGImage, _ name: String) {
            guard let dir, let dest = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        func rgba(_ image: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = unsafe CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buf
        }

        // Every crew glyph, glyphs off, and the primary tint (the glyph-tint preference).
        let configs: [(String, String?, Color)] = [
            ("person", "person", .secondary), ("movieclapper", "movieclapper", .secondary),
            ("megaphone", "megaphone", .secondary), ("chair", "chair", .secondary),
            ("book", "book.pages", .secondary), ("music", "music.quarternote.3", .secondary),
            ("studio", "building.columns", .secondary), ("noglyph", nil, .secondary),
            ("primary", "person", .primary)]
        for (configName, glyph, tint) in configs {
        host.rootView = CrewParityContent(names: names, glyph: glyph, tint: tint)
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let mode = "\(configName)-\(appearanceName)"
            window.appearance = NSAppearance(named: appearance)
            await settle(600)
            // The SwiftUI rows sit 24 pt above the AppKit list and are as tall as it should be;
            // 4 pt of margin catches the shadows.
            let margin: CGFloat = 4
            let appkitRect = listFrame.insetBy(dx: -margin, dy: -margin)
            let swiftRect = appkitRect.offsetBy(dx: 0, dy: listFrame.height + 24)
            func screenRect(_ rect: CGRect) -> CGRect {
                let onScreen = window.convertToScreen(rect)
                let h = NSScreen.screens.first?.frame.height ?? 0
                return CGRect(x: onScreen.minX, y: h - onScreen.maxY, width: onScreen.width, height: onScreen.height)
            }
            guard let a = unsafe grab(screenRect(swiftRect), 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                  let b = unsafe grab(screenRect(appkitRect), 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                  a.width == b.width, a.height == b.height else {
                r.check("\(mode)-capture", false, "capture failed or sizes differ")
                continue
            }
            png(a, "\(mode)-swiftui.png")
            png(b, "\(mode)-appkit.png")
            let pa = rgba(a), pb = rgba(b)
            var diff = pa
            var differing = 0, maxDelta = 0
            for i in stride(from: 0, to: pa.count, by: 4) {
                let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i+1]) - Int(pb[i+1])), abs(Int(pa[i+2]) - Int(pb[i+2])))
                maxDelta = max(maxDelta, d)
                if d > 8 {
                    differing += 1
                    diff[i] = 255; diff[i+1] = 0; diff[i+2] = 0; diff[i+3] = 255
                }
            }
            let ctx = unsafe CGContext(data: &diff, width: a.width, height: a.height, bitsPerComponent: 8,
                                bytesPerRow: a.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let img = ctx.makeImage() { png(img, "\(mode)-diff.png") }
            r.metric("\(mode)-differing-pixels", Double(differing), "px")
            // A glyph is rasterized by NSImageView and drawn as a vector path by SwiftUI, so
            // its edge pixels may differ slightly; anything past 48/255 is a real difference.
            r.check("\(mode)-pixels", maxDelta <= 48,
                    "\(Fmt.int(differing)) of \(Fmt.int(a.width * a.height)) pixels differ by more than 8/255 (max \(Fmt.int(maxDelta)))")
        }
        }
        return r
    }
}
#endif

// MARK: - Frames Row Parity
//
// `rsb-frames-parity` (opt-in; on screen): FramesRowList beside a VStack of FrameEntryRow,
// for plain frames, aligned time-code ranges (with a value that falls back to the plain run),
// every mark and fade glyph, and a value long enough to truncate, light and dark. Captures go
// to `harness-reports/frames-parity/`, and the SwiftUI rows' view tree is logged.
#if DEBUG
extension DebugHarness {
    private struct FramesParityContent: View {
        let entries: [String]
        let alignsRanges: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: FrameEntryRow.spacing) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        FrameEntryRow(index: i + 1, entry: entry, alignsRanges: alignsRanges)
                    }
                }
                .frame(width: 252)
                FramesRowList(entries: entries, alignsRanges: alignsRanges)
                    .frame(width: 252)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    static func rsbFramesParityScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-frames-parity")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let grab = unsafe windowImageFunction else {
            r.check("capture-available", false, "CGWindowListCreateImage did not resolve")
            return r
        }
        let plain = ["1234", "56789, yes, none, none", "101112, caret, linear, none",
                     "131415, number, none, scurve", "161718, no, plus, minus",
                     "A remarkably long frames note that has to truncate here, yes, linear, scurve",
                     "22, no, none, none"]
        let ranges = ["00:01:02 – 00:03:04", "01:11:11 – 04:44:48, yes, minus, plus",
                      "00:00:00 – 12:34:56, no, scurve, linear", "not a range at all",
                      "1:2 – 3:4, caret, none, none", "00:10:00 – 00:20:00, number, plus, none"]
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FramesParityContent(entries: ranges, alignsRanges: true))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle(800)

        var lines: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            var line = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)"
            if let t = v as? NSTextField { line += " font \(t.font?.pointSize ?? 0) sel \(t.isSelectable) '\(t.stringValue)'" }
            lines.append(line)
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(host, 0)
        log("FRAMES-PARITY TREE\n" + lines.joined(separator: "\n"))

        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/frames-parity", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func png(_ image: CGImage, _ name: String) {
            guard let dir, let dest = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        func rgba(_ image: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = unsafe CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return buf
        }

        for (configName, entries, aligns) in [("plain", plain, false), ("ranges", ranges, true)] {
            host.rootView = FramesParityContent(entries: entries, alignsRanges: aligns)
            await settle(400)
            guard let list = findView(FramesRowListView.self, in: host) else {
                r.check("\(configName)-mounted", false, "no FramesRowListView")
                continue
            }
            // Behavior: the values are selectable and the index is not, as in FrameEntryRow.
            var labels: [NSTextField] = []
            var stack: [NSView] = [list]
            while let v = stack.popLast() {
                if let t = v as? NSTextField, !t.isHidden { labels.append(t) }
                stack.append(contentsOf: v.subviews.reversed())
            }
            let indexes = labels.filter { $0.stringValue.hasSuffix(".") && $0.stringValue.count == 3 }
            let values = labels.filter { !indexes.contains($0) }
            r.check("\(configName)-selection", !values.isEmpty && values.allSatisfy { $0.isSelectable && !$0.isEditable }
                    && indexes.allSatisfy { !$0.isSelectable },
                    "\(values.count) selectable values, \(indexes.count) indexes")
            let listFrame = list.convert(list.bounds, to: nil)
            r.check("\(configName)-heights", true, "AppKit list \(Fmt.fixed(listFrame.height, 2)) pt, row \(Fmt.fixed(FramesRowView.height, 2)) pt")

            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let mode = "\(configName)-\(appearanceName)"
                window.appearance = NSAppearance(named: appearance)
                await settle(600)
                let margin: CGFloat = 4
                let appkitRect = listFrame.insetBy(dx: -margin, dy: -margin)
                let swiftRect = appkitRect.offsetBy(dx: 0, dy: listFrame.height + 24)
                func screenRect(_ rect: CGRect) -> CGRect {
                    let onScreen = window.convertToScreen(rect)
                    let h = NSScreen.screens.first?.frame.height ?? 0
                    return CGRect(x: onScreen.minX, y: h - onScreen.maxY, width: onScreen.width, height: onScreen.height)
                }
                guard let a = unsafe grab(screenRect(swiftRect), 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                      let b = unsafe grab(screenRect(appkitRect), 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                      a.width == b.width, a.height == b.height else {
                    r.check("\(mode)-capture", false, "capture failed or sizes differ")
                    continue
                }
                png(a, "\(mode)-swiftui.png")
                png(b, "\(mode)-appkit.png")
                let pa = rgba(a), pb = rgba(b)
                var diff = pa
                var differing = 0, maxDelta = 0
                for i in stride(from: 0, to: pa.count, by: 4) {
                    let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i+1]) - Int(pb[i+1])), abs(Int(pa[i+2]) - Int(pb[i+2])))
                    maxDelta = max(maxDelta, d)
                    if d > 8 {
                        differing += 1
                        diff[i] = 255; diff[i+1] = 0; diff[i+2] = 0; diff[i+3] = 255
                    }
                }
                let ctx = unsafe CGContext(data: &diff, width: a.width, height: a.height, bitsPerComponent: 8,
                                    bytesPerRow: a.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                if let img = ctx.makeImage() { png(img, "\(mode)-diff.png") }
                r.metric("\(mode)-differing-pixels", Double(differing), "px")
                // Glyph edges are vector in SwiftUI and raster here, as in rsb-crew-parity.
                r.check("\(mode)-pixels", maxDelta <= 48,
                        "\(Fmt.int(differing)) of \(Fmt.int(a.width * a.height)) pixels differ by more than 8/255 (max \(Fmt.int(maxDelta)))")
            }
        }
        return r
    }
}
#endif

// MARK: - Metadata Screenshots
//
// `rsb-metadata-shot` (opt-in; drives the real main window): the Details tab of several real
// films, scrolled to the bottom so the Metadata module is in view, captured through the
// window server at full resolution into `harness-reports/metadata-shot/`, light and dark.
// Run it twice, with and without `-FTRSBSwiftUICrewRows`, and compare the two directories:
// the crew rows are the only thing the flag changes.
#if DEBUG
extension DebugHarness {
    static func rsbMetadataShotScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-metadata-shot")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }),
              let grab = unsafe windowImageFunction else {
            r.check("main-window", false, "no main window or capture")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        // Films whose crew sections differ in length, and one with no producers at all.
        let films = coordinator.films.filter { $0.cast.count >= 3 }
        guard films.count >= 4 else { r.check("films", false, "\(films.count)"); return r }
        let picks = [films[0], films[films.count / 3], films[2 * films.count / 3], films[films.count - 1]]
        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/metadata-shot", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        ViewStateManager.shared.setRightSidebarTab(.details)
        // App-wide: the main window is SwiftUI's scene window (see sidebarTabShots).
        let saved = NSApp.appearance
        let store = Preferences.store
        let savedGlyphs = store.object(forKey: Preferences.showWatchDetailsAnnotationGlyphsKey)
        defer {
            NSApp.appearance = saved
            store.set(savedGlyphs, forKey: Preferences.showWatchDetailsAnnotationGlyphsKey)
        }
        for (glyphs, glyphMode) in [(false, "plain"), (true, "glyphs")] {
        store.set(glyphs, forKey: Preferences.showWatchDetailsAnnotationGlyphsKey)
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (filmIndex, film) in picks.enumerated() {
            // Three scroll positions from the bottom, which between them cover the crew block.
            for (offsetIndex, fromBottom) in [CGFloat(0), 500, 1000].enumerated() {
                let mode = "\(glyphMode)-\(appearanceName)"
                let i = filmIndex * 3 + offsetIndex
                SelectionState.shared.selectImmediate(film.id)
                await settle(1200)
                guard let sv = findView(NSScrollView.self, in: window.contentView, where: { sv in
                    guard let doc = sv.documentView, unsafe sv.window != nil else { return false }
                    var stack: [NSView] = [doc]
                    while let v = stack.popLast() {
                        if String(describing: type(of: v)).contains("RTabDetailsContent"), unsafe sv.hitTest(sv.convert(NSPoint(x: 10, y: 10), to: sv.superview)) != nil { return true }
                        stack.append(contentsOf: v.subviews)
                    }
                    return false
                }) else {
                    r.check("\(mode)-\(i)-scroll", false, "Details scroll view not found")
                    continue
                }
                if let doc = sv.documentView {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - sv.contentView.bounds.height - fromBottom)))
                    sv.reflectScrolledClipView(sv.contentView)
                }
                await settle(500)
                let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
                let h = NSScreen.screens.first?.frame.height ?? 0
                let rect = CGRect(x: onScreen.minX, y: h - onScreen.maxY, width: onScreen.width - 20, height: onScreen.height)
                guard let image = unsafe grab(rect, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                      let dir, let dest = CGImageDestinationCreateWithURL(
                        dir.appendingPathComponent("\(mode)-\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { r.check("\(mode)-\(i)-capture", false, ""); continue }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                r.check("\(mode)-\(i)", true, "\(film.name): cast \(film.cast.count), producers \(film.producers.count), \(image.width)x\(image.height)")
            }
            }
        }
        }
        SelectionState.shared.selectImmediate(nil as UUID?)
        return r
    }

    /// `rsb-notes-shot` (opt-in; drives the real main window): the Notes tab of the films with
    /// the longest frames tables, plus one with only a few entries, captured top to bottom one
    /// viewport at a time into `harness-reports/notes-shot/`, light and dark. Run it twice, with
    /// and without `-FTRSBSwiftUIFramesRows`, and compare the two directories: the frames rows
    /// are the only thing the flag changes.
    static func rsbNotesShotScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        func frames(_ f: FilmSnapshot) -> Int { f.handbrakeFrames.count + f.correspondingTimecodes.count }
        let byFrames = coordinator.films.filter { frames($0) > 0 }.sorted { frames($0) > frames($1) }
        // The longest tables, the longest with any mark or fade glyph, and a short one.
        var picks = Array(byFrames.prefix(2))
        if let glyphs = byFrames.first(where: { f in !picks.contains { $0.id == f.id }
            && (FramesEntryParser.containsLegendGlyphs(f.handbrakeFrames)
                || FramesEntryParser.containsLegendGlyphs(f.correspondingTimecodes)) }) { picks.append(glyphs) }
        if let short = byFrames.last(where: { f in frames(f) >= 4 && !picks.contains { $0.id == f.id } }) { picks.append(short) }
        return await sidebarTabShots(scenario: "rsb-notes-shot", tab: .notes, folder: "notes-shot", films: picks,
                                     enough: byFrames.count >= 6) { film in
            "frames \(film.handbrakeFrames.count) + time codes \(film.correspondingTimecodes.count), "
                + "rows \(RSBProfileFlags.swiftUIFramesRows ? "SwiftUI" : "AppKit")"
        }
    }

    /// `rsb-releases-shot` (opt-in; drives the real main window): the Releases tab of the films
    /// with the most cards, the one with the most combo packs, and one with a single card,
    /// into `harness-reports/releases-shot/`, as `rsb-notes-shot` captures the Notes tab, for
    /// comparing two builds' directories.
    static func rsbReleasesShotScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        func groups(_ f: FilmSnapshot) -> [[ReleaseSnapshot]] {
            releasesGroupedByHierarchy(f.releases.filter { ReleaseFormat(rawValue: $0.format) != nil })
        }
        let withCards = coordinator.films.filter { !groups($0).isEmpty }
        let byCards = withCards.sorted { groups($0).count > groups($1).count }
        var picks = Array(byCards.prefix(2))
        let combos = withCards.sorted { groups($0).filter { $0.count > 1 }.count > groups($1).filter { $0.count > 1 }.count }
        if let combo = combos.first(where: { f in !picks.contains { $0.id == f.id } }) { picks.append(combo) }
        if let single = withCards.first(where: { f in groups(f).count == 1 && groups(f)[0].count == 1
            && !picks.contains { $0.id == f.id } }) { picks.append(single) }
        return await sidebarTabShots(scenario: "rsb-releases-shot", tab: .releases, folder: "releases-shot", films: picks,
                                     enough: withCards.count >= 6) { film in
            let g = groups(film)
            return "\(g.count) cards, \(g.filter { $0.count > 1 }.count) combo packs"
        }
    }

    /// One sidebar tab of each film, captured top to bottom one viewport at a time, light and
    /// dark, into `harness-reports/<folder>/`.
    private static func sidebarTabShots(scenario: String, tab: RightSidebarTab, folder: String, films picks: [FilmSnapshot],
                                        enough: Bool, describe: (FilmSnapshot) -> String) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: scenario)
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }),
              let grab = unsafe windowImageFunction else {
            r.check("main-window", false, "no main window or capture")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        guard enough else { r.check("films", false, "too few films"); return r }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/\(folder)", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        ViewStateManager.shared.setRightSidebarTab(tab)
        // App-wide, as a system appearance change reaches the app: the main window is
        // SwiftUI's scene window, which ignores an appearance set on it, and the scene's
        // content keeps the color scheme SwiftUI derived (an appearance set on the window left
        // every "dark" capture light).
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        /// The sidebar's visible tab: the scroll view in the window's right third that its own
        /// center hit-tests into.
        func tabScrollView() -> NSScrollView? {
            let width = window.contentView?.bounds.width ?? 0
            return findView(NSScrollView.self, in: window.contentView, where: { sv in
                guard unsafe sv.window != nil, sv.documentView != nil else { return false }
                let frame = sv.convert(sv.bounds, to: nil)
                guard frame.minX > width * 0.6, frame.width > 200 else { return false }
                let center = NSPoint(x: frame.midX, y: frame.midY)
                guard let hit = window.contentView?.hitTest(window.contentView!.convert(center, from: nil)) else { return false }
                return hit.isDescendant(of: sv)
            })
        }
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await settle(600)
            for (filmIndex, film) in picks.enumerated() {
                SelectionState.shared.selectImmediate(film.id)
                await settle(1200)
                guard let sv = tabScrollView(), let doc = sv.documentView else {
                    r.check("\(appearanceName)-\(filmIndex)-scroll", false, "\(tab.rawValue) scroll view not found")
                    continue
                }
                let page = sv.contentView.bounds.height
                let maxY = max(0, doc.frame.height - page)
                var offsets: [CGFloat] = stride(from: 0, to: maxY, by: page - 40).map { $0 }
                offsets.append(maxY)
                for (step, y) in offsets.enumerated() {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                    await settle(400)
                    let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
                    let h = NSScreen.screens.first?.frame.height ?? 0
                    // The scroller's 20 pt strip is left out: it fades on its own clock.
                    let rect = CGRect(x: onScreen.minX, y: h - onScreen.maxY, width: onScreen.width - 20, height: onScreen.height)
                    let name = "\(appearanceName)-\(filmIndex)-\(step).png"
                    guard let image = unsafe grab(rect, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(),
                          let dir, let dest = CGImageDestinationCreateWithURL(
                            dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
                    else { r.check("\(name)-capture", false, ""); continue }
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
                r.check("\(appearanceName)-\(filmIndex)", true, "\(film.name): \(describe(film)), \(offsets.count) captures")
            }
        }
        SelectionState.shared.selectImmediate(nil as UUID?)
        return r
    }

    /// The first view of `type` under `view`, depth first, that satisfies `test`.
    private static func findView<T: NSView>(_ type: T.Type, in view: NSView?, where test: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let match = view as? T, test(match) { return match }
        for sub in view.subviews { if let found = findView(type, in: sub, where: test) { return found } }
        return nil
    }
}
#endif

// MARK: - Gallery Edit Refresh
//
// `gallery-edit-refresh` (opt-in, a measurement plus correctness checks): what a same-order
// film edit and a gallery view switch cost in each style, read from GalleryRefreshProbe and
// the run-loop busy time. In the grid, with no section dividers, it counts the forced
// divider-relabel layouts each update pays (or skips). In the list, it counts the rows
// refreshed and the row hosting views actually re-rendered, and checks that an edited film's
// row shows the new rating both in the viewport and in a row prepared just below it.
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

        // Grid: edits and view switches.
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

        // List: edits of a visible row and of a prepared, off-screen row.
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

        // Restore what this run changed.
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
//
// `gallery-reload-economy` (opt-in, a measurement plus checks): how many film loads and gallery
// update passes a film change costs while a gallery is on screen, read from ViewSwitchProbe.
// One edit, a burst of per-film update events, an import and a deletion should each cost
// exactly one load (and an edit or a burst at most one grid pass); a change to films the view does not show should cost no gallery pass;
// an edit that takes a film out of the view should take it out in that one load; and
// visiting an empty view should load it once. Also checks that grid selection rings stay
// right through in-place reconfigures and cell recycling, and counts how often they are
// re-stroked.
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

        // One same-order edit.
        ViewSwitchProbe.reset()
        let edited = coordinator.films[12]
        await coordinator.updateFilm(rated(edited, edited.userRating == 7 ? 8 : 7))
        await settle(700)
        r.check("edit-one-load", count("load ") == 1 && count("grid.update") <= 1, summary())

        // A burst of per-film update events in one turn — the shape a Hall of Fame reorder or
        // a ratings-import rollback posts.
        ViewSwitchProbe.reset()
        for film in coordinator.films[20..<40] {
            AppEventBus.shared.send(.film(.updated(filmID: film.id)))
        }
        await settle(700)
        r.check("burst-one-load", count("load ") == 1 && count("grid.update") <= 1, summary())

        // An edit that takes a film out of the view: rating a film in Unwatched ▸ Not Rated.
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

        // Import and delete with a gallery on screen.
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

        // Changes to films the view does not show cost no gallery pass.
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

        // Visiting an empty view loads it once, like any other.
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

        // Selection rings through an in-place reconfigure and through cell recycling.
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

            // Recycle every visible cell: far down and back.
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

        // Restore what this run changed.
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


// MARK: - Sidebar Glyph Shots
//
// `rsb-glyph-shot` (opt-in; on screen): the Details, Releases and Notes tabs of one film each,
// every tab in a sidebar-sized window of its own, captured through the window server at the
// display's scale into `harness-reports/glyph-shot/`, light and dark. The PNGs carry the
// display's DPI, so they open at on-screen size. Details and Notes are scrolled to the
// bottom, where the crew rows and frames tables are; annotation glyphs are on. For comparing the sidebar's AppKit SF Symbol glyphs between two builds.
#if DEBUG
extension DebugHarness {
    static func rsbGlyphShotScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "rsb-glyph-shot")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let grab = unsafe windowImageFunction else {
            r.check("capture-available", false, "CGWindowListCreateImage did not resolve")
            return r
        }
        let films = coordinator.films
        let cardFilm = films.first { $0.name == "Secret Window" } ?? films.first
        let notesFilm = films.max { $0.handbrakeFrames.count < $1.handbrakeFrames.count }
        guard let cardFilm, let notesFilm else { r.check("films", false, "none"); return r }
        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/glyph-shot", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func png(_ image: CGImage, _ name: String) {
            guard let dir, let dest = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            let dpi = 72 * scale
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        // The crew glyphs follow the annotation-glyph preference.
        let store = Preferences.store
        let savedGlyphs = store.object(forKey: Preferences.showWatchDetailsAnnotationGlyphsKey)
        store.set(true, forKey: Preferences.showWatchDetailsAnnotationGlyphsKey)
        defer { store.set(savedGlyphs, forKey: Preferences.showWatchDetailsAnnotationGlyphsKey) }
        let height: CGFloat = 1100
        let tabs: [(String, FilmSnapshot, AnyView)] = [
            ("details", cardFilm, AnyView(RTabDetails(calendarTableExpanded: .constant(false), listTableExpanded: .constant(false)))),
            ("releases", cardFilm, AnyView(RTabReleases(releasesSummaryExpanded: .constant(false), purchaseFilter: .constant(.all)))),
            ("notes", notesFilm, AnyView(RTabNotes()))]
        for (name, film, tab) in tabs {
            let content = tab
                .frame(width: RightSidebar.sidebarWidth, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.sidebarFilm, film)
                .environment(coordinator)
                .environment(SelectionState.shared)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: RightSidebar.sidebarWidth, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content)
            window.contentView = host
            window.orderFrontRegardless()
            await settle(1000)
            if name != "releases", let scroll = findView(NSScrollView.self, in: host), let doc = scroll.documentView {
                let clip = scroll.contentView
                let y = doc.isFlipped ? max(0, doc.bounds.height - clip.bounds.height) : 0
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
            }
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                await settle(700)
                let frame = window.frame
                let h = NSScreen.screens.first?.frame.height ?? 0
                let rect = CGRect(x: frame.minX, y: h - frame.maxY, width: frame.width, height: frame.height)
                guard let image = unsafe grab(rect, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
                    r.check("\(name)-\(appearanceName)-capture", false, "capture failed")
                    continue
                }
                png(image, "\(name)-\(appearanceName).png")
                r.check("\(name)-\(appearanceName)-capture", true, "\(film.name), \(image.width)x\(image.height) px")
            }
            window.orderOut(nil)
            window.contentView = nil
        }
        return r
    }
}
#endif
