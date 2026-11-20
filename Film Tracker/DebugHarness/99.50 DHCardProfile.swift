// MARK: - DHCardProfile.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only scenarios for the FilmSheet (its Releases carousel, save path and keyboard rules),
/// the sheet and sidebar controls, the alert host, the Insights tables and the left sidebar's
/// disclosure rows. Most are in `all`; `reports-table-behavior` is in `ui`; `reports-hitch`
/// and `filmsheet-perf` are opt-in measurements; `jump-menu-width` and the two
/// `sidebar-expansion-*` launches are opt-in checks run by name.

#if DEBUG

import AppKit
import Combine
import SwiftUI

extension DebugHarness {

    /// Scenario names owned by this file that `all` runs.
    static var cardScenarios: [String] {
        ["card-focus", "segmented-equivalence", "currency-placeholder", "releases-settle", "release-duplicate",
         "filmsheet-save", "return-key-policy", "queue-add-confirm", "alert-host", "alert-collision", "tab-cycle",
         "report-gutter-deselect", "placeholder-anchor", "import-details-segments",
         "sidebar-disclosure"]
    }

    static func runCardProfileScenario(_ scenario: String,
                                       coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "card-focus": return await cardFocusScenario(coordinator: coordinator)
        case "segmented-equivalence": return await segmentedEquivalenceScenario()
        case "currency-placeholder": return await currencyPlaceholderScenario(coordinator: coordinator)
        case "reports-hitch": return await insightsHitchScenario(coordinator: coordinator)
        case "reports-table-behavior": return await insightsTableBehaviorScenario(coordinator: coordinator)
        case "report-lists-cost": return await reportListsCostScenario(coordinator: coordinator)
        case "releases-settle": return await releasesSettleScenario(coordinator: coordinator)
        case "release-duplicate": return await releaseDuplicateScenario(coordinator: coordinator)
        case "filmsheet-save": return await filmSheetSaveScenario(coordinator: coordinator)
        case "return-key-policy": return await returnKeyPolicyScenario(coordinator: coordinator)
        case "queue-add-confirm": return await queueAddConfirmScenario(coordinator: coordinator)
        case "alert-host": return await alertHostScenario(coordinator: coordinator)
        case "alert-collision": return await alertCollisionScenario(coordinator: coordinator)
        case "tab-cycle": return await tabCycleScenario(coordinator: coordinator)
        case "report-gutter-deselect": return await reportGutterDeselectScenario()
        case "placeholder-anchor": return await placeholderAnchorScenario()
        case "import-details-segments": return await importDetailsSegmentsScenario()
        case "sidebar-disclosure": return await sidebarDisclosureScenario()
        case "sidebar-expansion-seed": return sidebarExpansionSeedScenario()
        case "sidebar-expansion-restore": return await sidebarExpansionRestoreScenario()
        case "jump-menu-width": return await jumpMenuWidthScenario(coordinator: coordinator)
        case "filmsheet-perf": return await filmSheetPerfScenario(coordinator: coordinator)
        default:           return nil
        }
    }

    private static func threadCPUMilliseconds() -> Double {
        var ts = timespec()
        unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    }

    /// Makes `window` key, asking again every 100 ms for up to 3 s. One request can lose:
    /// activation is cooperative, and mid-suite another scenario's window may still be
    /// settling. The Return-key and tab-cycle checks depend on key status, so the request is
    /// repeated rather than made once.
    static func makeKey(_ window: NSWindow) async -> Bool {
        for _ in 0..<30 where !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return window.isKeyWindow
    }

    /// The reason a real-window keyboard scenario cannot run here, or nil if it can. Key
    /// status is the precondition every keystroke check rests on; without it they all fail
    /// together and say nothing about the code.
    static func keyWindowUnavailable(_ window: NSWindow) async -> String? {
        if await makeKey(window) { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
            ? "the screen is locked; re-run while someone is at the Mac"
            : "the window could not become key (another app holds focus?); re-run with the Mac idle"
    }

    private static func oneRunLoopTurn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    /// Wall time of the synchronous layout plus main-thread CPU over the following turn.
    private struct Sample {
        var layoutWall: Double
        var turnCPU: Double
        var total: Double { layoutWall + turnCPU }
    }

    private static func measure(_ work: () -> Void) async -> Sample {
        let cpu0 = threadCPUMilliseconds()
        let t0 = ContinuousClock.now
        work()
        let wall = milliseconds(ContinuousClock.now - t0)
        let cpuAfterWork = threadCPUMilliseconds()
        await oneRunLoopTurn()
        await oneRunLoopTurn()
        let cpu1 = threadCPUMilliseconds()
        _ = cpu0
        return Sample(layoutWall: wall, turnCPU: cpu1 - cpuAfterWork)
    }

    private static func census(_ root: NSView) -> (views: Int, focusable: Int) {
        var total = 0, focusable = 0
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            total += 1
            if v.acceptsFirstResponder { focusable += 1 }
            stack.append(contentsOf: v.subviews)
        }
        return (total, focusable)
    }

    static func stats(_ values: [Double]) -> (median: Double, max: Double, mean: Double) {
        let s = values.sorted()
        guard !s.isEmpty else { return (0, 0, 0) }
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return (median, s.last!, s.reduce(0, +) / Double(s.count))
    }

    private static func makeModel(format: ReleaseFormat, purchased: Bool, sortOrder: Int) -> ReleaseCardModel {
        let m = ReleaseCardModel(format: format.rawValue, sortOrder: sortOrder, filmReleaseYear: 1999)
        m.applyNewReleaseDefaults(for: format.rawValue)
        m.purchased = purchased
        /// Every fourth card names a studio outside the vocabulary, which routes the studio
        /// row to "Other" and puts its free-text field in the tree.
        m.studio = sortOrder % 4 == 1 ? "Indie Label \(sortOrder)"
                                     : ReleaseStudio.ordered[sortOrder % ReleaseStudio.ordered.count]
        m.initializeStudioUI()
        m.releaseYear = 2018 + sortOrder
        m.hasReleaseYear = true
        m.notes = "Release \(sortOrder)"
        if purchased {
            m.cost = 19.99 + Double(sortOrder)
            m.amountSpent = 14.5
            m.hasPurchaseDate = true
            m.independence = ReleaseIndependence.standalone
            m.hasArtwork = ReleaseArtwork.steelbook
        } else {
            m.lowestPrice = 9.99
            m.hasLowestPriceDate = true
        }
        return m
    }
}


// MARK: - Card Focus
///
/// Proves FilmSheetKeyLoop against the REAL carousel: FSTabReleasesView hosted in an
/// NSHostingView inside an off-screen window, with its neighbors mounted exactly as they are
/// in the sheet. The loop is exercised through the same `advance` the tab's key monitor calls
/// on a Tab press, and the window's first responder is read back after each step.
///
/// What it asserts is the contract the user experiences: from nothing focused, one step
/// lands on the card's first control; successive steps visit every control of the current
/// card in reading order and wrap; a backward step from the first wraps to the last; no step
/// ever lands on a control of a neighboring card, however many are mounted; and after a
/// navigation step the loop is the new card's. It also records what SwiftUI gave each
/// hosted control for `focusRingType`, which is what decides whether the ring the user is
/// supposed to see can be drawn at all.
extension DebugHarness {

    /// The real tab, as the sheet hosts it, with nothing around it.
    private struct CardFocusHost: View {
        let viewModel: FSTabReleases
        var body: some View {
            FSTabReleasesView(viewModel: viewModel)
                .frame(width: 700, height: 900)
        }
    }

    private static func describeControl(_ v: NSView) -> String {
        let name = String(describing: type(of: v)).replacingOccurrences(of: "SwiftUI.", with: "")
        let f = v.convert(v.bounds, to: nil)
        return unsafe String(format: "%@@(%.0f,%.0f)", name, f.minX, f.midY)
    }

    private static func cardFocusScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "card-focus")

        let sheet = FilmSheet(coordinator: coordinator)
        guard let vm = sheet.releasesTab else {
            r.check("view-model", false, "FilmSheet has no releases tab")
            return r
        }
        /// Three cards: purchased 4K (the date Stepper is on it), unpurchased Blu-ray, purchased
        /// DVD. All three are mounted once the carousel has hydrated around the first, so the
        /// confinement checks below have real neighbors to be confined from.
        let models = [makeModel(format: .uhd4K,  purchased: true,  sortOrder: 0),
                      makeModel(format: .bluRay, purchased: false, sortOrder: 1),
                      makeModel(format: .dvd,    purchased: true,  sortOrder: 2)]
        vm.releases = models

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CardFocusHost(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        /// The hydration ramp mounts the neighbors over several turns; give it room.
        for _ in 0..<12 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        await oneRunLoopTurn()

        let fka = NSApp.isFullKeyboardAccessEnabled
        log("card-focus: full keyboard access \(fka ? "ON" : "OFF")")

        let entries = vm.carouselEntries
        r.check("three-cards", entries.count == 3, "expected 3 cards, got \(entries.count)")
        guard entries.count == 3 else { return r }
        let current = entries[vm.currentCardIndex].id
        let loop = FilmSheetKeyLoop.shared.controls(inCard: current, in: window)
        log("card-focus: loop for card \(vm.currentCardIndex) (\(loop.count)): "
            + loop.map(describeControl).joined(separator: " | "))
        r.check("loop-nonempty", !loop.isEmpty, "the current card has no key-loop controls")
        guard !loop.isEmpty else { return r }

        /// A SheetCheckbox representable's NSButton, which SwiftUI wraps in a host named
        /// after the representable.
        func isSheetCheckbox(_ v: NSView?) -> Bool {
            guard v is NSButton else { return false }
            var ancestor = unsafe v?.superview
            while let a = ancestor {
                if String(describing: type(of: a)).contains("SheetCheckbox") { return true }
                ancestor = unsafe a.superview
            }
            return false
        }

        // MARK: Membership
        /// With Full Keyboard Access on, the Purchased checkbox is the first stop. Without it
        /// AppKit refuses first responder for every button, and only the text fields remain
        /// — which is the system's rule, not the loop's, so the check is conditional.
        if fka {
            r.check("first-is-purchased-checkbox", isSheetCheckbox(loop.first),
                    "first control is \(loop.first.map(describeControl) ?? "nil"), not the Purchased checkbox")
            r.check("stepper-in-loop", loop.contains { $0 is NSStepper },
                    "the purchased card's date Stepper is not in the loop")
            r.check("popups-in-loop", loop.contains { $0 is NSPopUpButton },
                    "no pop-up button made it into the loop")
        }
        r.check("textfields-in-loop", loop.contains { $0 is NSTextField },
                "no text field made it into the loop")

        /// Reading order: never a control ABOVE the previous one by more than a row.
        var orderedTopDown = true
        for i in 1..<loop.count {
            let a = loop[i - 1].convert(loop[i - 1].bounds, to: nil)
            let b = loop[i].convert(loop[i].bounds, to: nil)
            if b.midY > a.midY + 8 { orderedTopDown = false }
        }
        r.check("reading-order", orderedTopDown, "loop order climbs back up the card")

        /// Every control is fully visible — no clipped or zero-size stop the user cannot see.
        r.check("every-stop-visible",
                loop.allSatisfy { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor },
                "a loop stop is hidden or clipped")

        // MARK: Confinement
        /// The neighbors are mounted but hit-disabled, so the loop's own census sees nothing
        /// on them by design. Count them the way AppKit's key view loop would instead: every
        /// key view in the window whose center lies outside the current card's controls.
        let loopBounds = loop.map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        var neighborControls: [NSView] = []
        var census: [NSView] = [window.contentView!]
        while let v = census.popLast() {
            census.append(contentsOf: v.subviews)
            guard v is NSControl, v.canBecomeKeyView else { continue }
            let f = v.convert(v.bounds, to: nil)
            if !loopBounds.contains(NSPoint(x: f.midX, y: f.midY)) { neighborControls.append(v) }
        }
        r.check("neighbors-mounted", neighborControls.count >= 10,
                "only \(neighborControls.count) key views outside the card — confinement is untested")
        r.check("disjoint-from-neighbors",
                !loop.contains { c in neighborControls.contains { $0 === c } },
                "a neighbor's control is in the current card's loop")

        // MARK: Traversal
        window.makeFirstResponder(nil)
        var visited: [NSView] = []
        for _ in 0..<loop.count {
            let moved = FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: true)
            r.check("advance-moves", moved, "advance reported nothing to move to")
            if let focused = FilmSheetKeyLoop.focusedControl(in: window) {
                visited.append(focused)
            }
        }
        r.check("visits-every-control-in-order",
                visited.count == loop.count && zip(visited, loop).allSatisfy { $0 === $1 },
                "visited \(visited.map(describeControl)) vs loop \(loop.map(describeControl))")
        /// One more wraps to the first.
        FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: true)
        r.check("wraps-forward",
                FilmSheetKeyLoop.focusedControl(in: window) === loop[0],
                "did not wrap to the first control")
        /// Backward from the first wraps to the last.
        FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: false)
        r.check("wraps-backward",
                FilmSheetKeyLoop.focusedControl(in: window) === loop[loop.count - 1],
                "did not wrap to the last control")
        /// None of the visited controls belong to a neighbor.
        r.check("never-left-the-card",
                !visited.contains { c in neighborControls.contains { $0 === c } },
                "focus landed on a neighbor card")
        /// A tabbed-onto text field has its contents selected, as AppKit's own traversal does.
        if let fieldIndex = loop.firstIndex(where: { $0 is NSTextField }) {
            window.makeFirstResponder(nil)
            for _ in 0...fieldIndex { FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: true) }
            let field = loop[fieldIndex] as! NSTextField
            let editor = field.currentEditor()
            r.check("text-field-selected-on-arrival",
                    editor != nil && (field.stringValue.isEmpty || editor!.selectedRange.length == field.stringValue.count),
                    "tabbing onto a text field did not select its contents")
        }

        // MARK: Focus rings
        /// The ring is drawn by AppKit from `focusRingType`; a hosted control that SwiftUI
        /// set to `.none` can be focused but never show it. Every button, pop-up and stepper
        /// in the loop must be able to draw one.
        let ringless = loop.filter { $0.focusRingType == .none }
        log("card-focus: focusRingType == .none on: " + ringless.map(describeControl).joined(separator: " | "))
        r.check("focus-rings-drawable", ringless.isEmpty,
                "\(ringless.count) loop control(s) cannot draw a focus ring: "
                    + ringless.map(describeControl).joined(separator: ", "))

        // MARK: After a navigation step
        window.makeFirstResponder(nil)
        vm.nextCard()
        for _ in 0..<12 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        await oneRunLoopTurn()
        let after = entries[vm.currentCardIndex].id
        r.check("navigated", after != current, "nextCard did not change the current card")
        let loop2 = FilmSheetKeyLoop.shared.controls(inCard: after, in: window)
        log("card-focus: loop after step (\(loop2.count)): " + loop2.map(describeControl).joined(separator: " | "))
        r.check("loop-follows-navigation",
                !loop2.isEmpty && !loop2.contains { c in loop.contains { $0 === c } },
                "the loop after a step still contains the previous card's controls")
        FilmSheetKeyLoop.shared.advance(inCard: after, in: window, forward: true)
        r.check("first-step-lands-on-new-card",
                loop2.first.map { $0 === FilmSheetKeyLoop.focusedControl(in: window) } == true,
                "after a step, Tab did not land on the new card's first control")

        window.makeFirstResponder(nil)
        window.contentView = nil

        // MARK: Inside the whole sheet, with other tabs alive behind the card
        /// The sheet keeps every visited tab mounted behind the active one, hidden by
        /// opacity rather than isHidden. Their controls overlap the card and are key views
        /// by AppKit's reckoning — the invisible stops that made Tab take several presses
        /// between visible controls. Visit Details first so it is alive, then switch to
        /// Releases and require the loop to be the same sequence of controls the tab has
        /// on its own.
        let standalone = loop2.map { String(describing: type(of: $0)) }
        let sheet2 = FilmSheet(coordinator: coordinator)
        guard let vm2 = sheet2.releasesTab else {
            r.check("sheet-view-model", false, "second FilmSheet has no releases tab")
            return r
        }
        vm2.releases = models
        let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        sheetWindow.isReleasedWhenClosed = false
        let sheetHost = NSHostingView(rootView: FilmSheetView(owner: sheet2).frame(width: 900, height: 900))
        sheetHost.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        sheetWindow.contentView = sheetHost
        sheetHost.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await oneRunLoopTurn() }
        sheet2.selectedTab = .releases
        for _ in 0..<12 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(300))
        sheetHost.layoutSubtreeIfNeeded()
        sheetWindow.displayIfNeeded()
        await oneRunLoopTurn()
        let sheetEntries = vm2.carouselEntries
        r.check("sheet-three-cards", sheetEntries.count == 3, "expected 3 cards in the sheet, got \(sheetEntries.count)")
        if sheetEntries.count == 3 {
            /// The standalone loop above was taken after one navigation step (card 1); step
            /// the sheet's carousel the same way so the two describe the same card.
            vm2.nextCard()
            for _ in 0..<12 { await oneRunLoopTurn() }
            try? await Task.sleep(for: .milliseconds(600))
            sheetHost.layoutSubtreeIfNeeded()
            await oneRunLoopTurn()
            let inSheet = FilmSheetKeyLoop.shared.controls(inCard: sheetEntries[vm2.currentCardIndex].id, in: sheetWindow)
            let sheetClasses = inSheet.map { String(describing: type(of: $0)) }
            log("card-focus: loop inside the sheet (\(inSheet.count)): " + inSheet.map(describeControl).joined(separator: " | "))
            r.check("no-hidden-tab-stops", sheetClasses == standalone,
                    "loop inside the sheet differs from the tab alone: \(sheetClasses) vs \(standalone)")
            /// Every stop is the thing a click at its center would reach.
            let root = sheetWindow.contentView!
            let allOnTop = inSheet.allSatisfy { v in
                let f = v.convert(v.bounds, to: nil)
                let p = unsafe root.superview!.convert(NSPoint(x: f.midX, y: f.midY), from: nil)
                let hit = root.hitTest(p)
                return hit === v || (hit?.isDescendant(of: v) ?? false)
            }
            r.check("every-stop-clickable", allOnTop, "a loop stop is covered by something else")
        }
        // MARK: The other tabs
        /// Same sheet, same loop, tab domains. Details, Metadata and Notes scroll, so their
        /// loops must include controls scrolled out of view and Tab must bring them in; no
        /// stop may belong to a hidden tab (the Releases cards are alive behind these).
        func settle() async {
            for _ in 0..<6 { await oneRunLoopTurn() }
            try? await Task.sleep(for: .milliseconds(300))
            sheetHost.layoutSubtreeIfNeeded()
            sheetWindow.displayIfNeeded()
            await oneRunLoopTurn()
        }
        func isHiddenByAlpha(_ v: NSView) -> Bool {
            var a: NSView? = v
            while let x = a { if x.alphaValue == 0 { return true }; a = unsafe x.superview }
            return false
        }
        for tab in [FilmTab.details, .metadata, .notes] {
            sheet2.selectedTab = tab
            await settle()
            let name = String(describing: tab)
            let tabLoop = FilmSheetKeyLoop.shared.controls(inTab: tab, in: sheetWindow)
            log("card-focus: \(name) loop (\(tabLoop.count)): " + tabLoop.map(describeControl).joined(separator: " | "))
            r.check("\(name)-loop-nonempty", !tabLoop.isEmpty, "\(name) has no key-loop controls")
            r.check("\(name)-no-hidden-stops", !tabLoop.contains(where: isHiddenByAlpha),
                    "\(name) loop contains a control from a hidden tab")
            r.check("\(name)-no-containers",
                    !tabLoop.contains { $0 is NSScrollView || $0 is NSClipView || $0 is NSScroller
                        || String(describing: type(of: $0)).hasPrefix("NSHostingView") },
                    "\(name) loop contains a container: \(tabLoop.map(describeControl))")
            /// The sink took focus on activation; one step lands on the first control.
            r.check("\(name)-sink-holds-focus", sheetWindow.firstResponder is NSButton
                        && String(describing: type(of: sheetWindow.firstResponder!)).contains("SinkButton"),
                    "\(name): first responder after activation is \(String(describing: sheetWindow.firstResponder))")
            FilmSheetKeyLoop.shared.advance(inTab: tab, in: sheetWindow, forward: true)
            r.check("\(name)-first-step-lands-first",
                    tabLoop.first.map { $0 === FilmSheetKeyLoop.focusedControl(in: sheetWindow) } == true,
                    "\(name): first Tab landed on \(String(describing: FilmSheetKeyLoop.focusedControl(in: sheetWindow)))")
            /// Walk the whole loop; every stop must be visible once reached.
            var reached = 0
            var allScrolledIn = true
            for _ in 1..<tabLoop.count {
                FilmSheetKeyLoop.shared.advance(inTab: tab, in: sheetWindow, forward: true)
                if let f = FilmSheetKeyLoop.focusedControl(in: sheetWindow), tabLoop.contains(where: { $0 === f }) {
                    reached += 1
                    if f.visibleRect.isEmpty { allScrolledIn = false }
                }
            }
            r.check("\(name)-walks-every-stop", reached == tabLoop.count - 1,
                    "\(name): reached \(reached) of \(tabLoop.count - 1) further stops")
            r.check("\(name)-scrolls-stops-in", allScrolledIn, "\(name): a stop was focused while scrolled out of view")
            FilmSheetKeyLoop.shared.advance(inTab: tab, in: sheetWindow, forward: true)
            r.check("\(name)-wraps", tabLoop.first.map { $0 === FilmSheetKeyLoop.focusedControl(in: sheetWindow) } == true,
                    "\(name): did not wrap to the first control")
        }
        /// Details specifics: the Name field first; the checkboxes are AppKit stops.
        sheet2.selectedTab = .details
        await settle()
        let details = FilmSheetKeyLoop.shared.controls(inTab: .details, in: sheetWindow)
        r.check("details-first-is-text-field", details.first is NSTextField,
                "Details first stop is \(details.first.map(describeControl) ?? "nil")")
        if fka {
            r.check("details-has-checkboxes", details.filter(isSheetCheckbox).count >= 4,
                    "Details has \(details.filter(isSheetCheckbox).count) checkbox stops")
            r.check("details-has-steppers", details.contains { $0 is NSStepper }, "Details has no stepper stops")
        }
        sheet2.selectedTab = .metadata
        await settle()
        let metadata = FilmSheetKeyLoop.shared.controls(inTab: .metadata, in: sheetWindow)
        if fka {
            r.check("metadata-has-checkboxes", metadata.filter(isSheetCheckbox).count == 2,
                    "Metadata has \(metadata.filter(isSheetCheckbox).count) checkbox stops")
        }
        sheet2.selectedTab = .notes
        await settle()
        let notes = FilmSheetKeyLoop.shared.controls(inTab: .notes, in: sheetWindow)
        r.check("notes-has-text-views", notes.contains { $0 is NSTextView }, "Notes has no text view stops")

        sheetWindow.makeFirstResponder(nil)
        sheetWindow.contentView = nil
        return r
    }
}



// MARK: - Segmented control equivalence
///
/// Proves `SheetSegmentedControl` (30_20) is laid out and configured exactly as SwiftUI's
/// `Picker(.segmented)` was, for every proposal shape the sheet uses: unconstrained in a
/// stack (fills), `.fixedSize()` (ideal), a narrow `.frame(width:)` (clamped to the minimum),
/// a wide one (honored), a tall one (height ignored), and disabled. Two-, three- and
/// four-segment label sets, since the minimum-width rule depends on the labels.
extension DebugHarness {
    private struct SegmentedCase {
        let name: String
        let labels: [String]
        let width: CGFloat?
        let height: CGFloat?
        let fixed: Bool
        let disabled: Bool
    }

    private struct SegmentedReading: Equatable {
        var alignmentRect: CGRect
        var frame: CGRect
        var style: Int
        var tracking: Int
        var distribution: Int
        var controlSize: Int
        var font: String
        var hugH: Float
        var hugV: Float
        var crH: Float
        var enabled: Bool
        var acceptsFirstResponder: Bool
        var selected: Int
        var labels: [String]
        var description: String {
            "align=\(alignmentRect.integral) frame=\(frame.integral) style=\(style) track=\(tracking) dist=\(distribution) size=\(controlSize) font=\(font) hug=\(hugH)/\(hugV) cr=\(crH) enabled=\(enabled) afr=\(acceptsFirstResponder) sel=\(selected) labels=\(labels)"
        }
    }

    private static func segmentedCases() -> [SegmentedCase] {
        let two = ["New", "Used"]
        let three = ["Asterisk", "Caret", "Number"]
        let four = ["None", "Up Next", "Soon", "Later"]
        var cases: [SegmentedCase] = []
        for (n, labels) in [("2", two), ("3", three), ("4", four)] {
            cases.append(.init(name: "\(n)-fill", labels: labels, width: nil, height: nil, fixed: false, disabled: false))
            cases.append(.init(name: "\(n)-ideal", labels: labels, width: nil, height: nil, fixed: true, disabled: false))
            cases.append(.init(name: "\(n)-narrow", labels: labels, width: 10, height: nil, fixed: false, disabled: false))
            cases.append(.init(name: "\(n)-wide", labels: labels, width: 300, height: nil, fixed: false, disabled: false))
        }
        cases.append(.init(name: "3-165", labels: three, width: 165, height: nil, fixed: false, disabled: false))
        cases.append(.init(name: "2-tall", labels: two, width: nil, height: 40, fixed: false, disabled: false))
        cases.append(.init(name: "2-disabled", labels: two, width: nil, height: nil, fixed: false, disabled: true))
        cases.append(.init(name: "4-max320", labels: four, width: nil, height: nil, fixed: false, disabled: false))
        return cases
    }

    @ViewBuilder
    private static func sizedCase<V: View>(_ c: SegmentedCase, _ view: V) -> some View {
        let base = AnyView(view)
        let framed: AnyView = {
            if c.name == "4-max320" { return AnyView(base.frame(maxWidth: 320)) }
            if c.width != nil || c.height != nil { return AnyView(base.frame(width: c.width, height: c.height)) }
            return base
        }()
        let fixed: AnyView = c.fixed ? AnyView(framed.fixedSize()) : framed
        fixed.disabled(c.disabled)
    }

    private static func swiftUISegmented(_ c: SegmentedCase) -> some View {
        sizedCase(c, Picker("", selection: .constant(c.labels[0])) {
            ForEach(c.labels, id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.segmented).labelsHidden())
    }

    private static func appKitSegmented(_ c: SegmentedCase) -> some View {
        sizedCase(c, SheetSegmentedControl(selection: .constant(c.labels[0]),
                                           segments: c.labels.map { .init($0, $0) }))
    }

    private static func readSegmented(hosting view: AnyView, container: NSView) async -> SegmentedReading? {
        let host = NSHostingView(rootView: HStack(spacing: 0) { view; Spacer(minLength: 0) }.frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 60)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<2 { await oneRunLoopTurn() }
        defer { host.removeFromSuperview() }
        var stack: [NSView] = [host]
        while let v = stack.popLast() {
            if let seg = v as? NSSegmentedControl {
                let frame = host.convert(seg.bounds, from: seg)
                let align = seg.alignmentRect(forFrame: frame)
                return SegmentedReading(
                    alignmentRect: align, frame: frame,
                    style: Int(seg.segmentStyle.rawValue), tracking: Int(seg.trackingMode.rawValue),
                    distribution: Int(seg.segmentDistribution.rawValue),
                    controlSize: Int(seg.controlSize.rawValue),
                    font: seg.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil",
                    hugH: seg.contentHuggingPriority(for: .horizontal).rawValue,
                    hugV: seg.contentHuggingPriority(for: .vertical).rawValue,
                    crH: seg.contentCompressionResistancePriority(for: .horizontal).rawValue,
                    enabled: seg.isEnabled, acceptsFirstResponder: seg.acceptsFirstResponder,
                    selected: seg.selectedSegment,
                    labels: (0..<seg.segmentCount).map { seg.label(forSegment: $0) ?? "" })
            }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    private static func segmentedEquivalenceScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "segmented-equivalence")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(container)
        for c in segmentedCases() {
            let a = await readSegmented(hosting: AnyView(swiftUISegmented(c)), container: container)
            let b = await readSegmented(hosting: AnyView(appKitSegmented(c)), container: container)
            guard let a, let b else {
                r.check("segmented-\(c.name)", false, "control not found (swiftui \(a != nil), appkit \(b != nil))")
                continue
            }
            let same = a == b
            r.check("segmented-\(c.name)", same, same ? a.description : "SwiftUI \(a.description)\n   AppKit \(b.description)")
            log("segmented \(c.name): \(same ? "match" : "DIFFER") | SwiftUI \(a.description)\n   AppKit \(b.description)")
        }
        await renderSegmentedComparison(container: container)
        window.close()
        return r
    }

    /// Writes `segmented-comparison.png` into the sandbox: SwiftUI's Picker(.segmented) above
    /// SheetSegmentedControl for the sheet's three label sets, enabled and disabled, at 2x.
    private static func renderSegmentedComparison(container: NSView) async {
        let two = ["New", "Used"], three = ["Asterisk", "Caret", "Number"], four = ["None", "Up Next", "Soon", "Later"]
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach([two, three, four], id: \.self) { labels in
                HStack(spacing: 12) {
                    Text("SwiftUI:").frame(width: 70, alignment: .trailing)
                    Picker("", selection: .constant(labels[0])) {
                        ForEach(labels, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("", selection: .constant(labels[0])) {
                        ForEach(labels, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(true)
                }
                HStack(spacing: 12) {
                    Text("AppKit:").frame(width: 70, alignment: .trailing)
                    SheetSegmentedControl(selection: .constant(labels[0]), segments: labels.map { .init($0, $0) })
                        .fixedSize()
                    SheetSegmentedControl(selection: .constant(labels[0]), segments: labels.map { .init($0, $0) })
                        .fixedSize().disabled(true)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 220)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await oneRunLoopTurn() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]),
           let dir = DebugSandbox.rootURL {
            let url = dir.appendingPathComponent("segmented-comparison.png")
            try? data.write(to: url)
            log("segmented comparison written to \(url.path)")
        }
        host.removeFromSuperview()
        await oneRunLoopTurn()
    }
}


// MARK: - Placeholder anchor
///
/// `placeholder-anchor` (in `all`): renders StandardPlaceholder (90_00) through the window's
/// own display path with the same glyph, title, and first message line, and 1, 2, and 3
/// message lines, a message that wraps, and an action button. The pixel rows from the top of
/// the view through the bottom of the one-line message's ink must be identical in every
/// variant — the glyph, the title, and the first line never move — and each variant must
/// have ink below that, so the extra lines were drawn rather than clipped. A row is compared
/// by its ink extent: the rows that hold ink must be the same rows (any vertical move, even
/// one device pixel, changes them), and each row's leftmost and rightmost ink may differ by
/// one pixel. A wrapped message's Text is the full message width, so its centered first line
/// lands on a subpixel position that differs from a one-line Text's. That changes the
/// antialiasing but not the position.
///
/// `import-details-segments` (in `all`): hosts the real import Details popover (28_00) for a
/// session with additions and updates only, and reads its NSSegmentedControl back: All,
/// Added, Updated enabled, Errors and Duplicates disabled, out of the key view loop, and no
/// narrower than its labels need. Writes `import-details-segments.png` to the sandbox.
extension DebugHarness {

    /// Draws `view` at 640 × 480 in `window` and returns the bitmap (rows top-down).
    private static func renderPlaceholder(_ view: AnyView, in window: NSWindow) async -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await oneRunLoopTurn() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Each row's leftmost and rightmost pixel unlike the top-left corner's (nil: no ink),
    /// and the last row holding any.
    private static func inkRows(_ rep: NSBitmapImageRep) -> (rows: [ClosedRange<Int>?], lastInk: Int) {
        guard let base = unsafe rep.bitmapData else { return ([], -1) }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel, width = rep.pixelsWide
        var rows: [ClosedRange<Int>?] = []
        var lastInk = -1
        let background = unsafe Array(UnsafeBufferPointer(start: base, count: spp))
        for y in 0..<rep.pixelsHigh {
            let row = unsafe Data(bytes: base + y * bpr, count: width * spp)
            let inked = (0..<width).filter { x in
                (0..<min(3, spp)).contains { abs(Int(row[x * spp + $0]) - Int(background[$0])) > 8 }
            }
            if let first = inked.first, let last = inked.last {
                rows.append(first...last)
                lastInk = y
            } else {
                rows.append(nil)
            }
        }
        return (rows, lastInk)
    }

    private static func placeholderAnchorScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "placeholder-anchor")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = "Nothing to show here yet."
        let wrapping = "This sentence is long enough that, at the placeholder's message width, "
            + "it wraps onto a second line and then onto a third."
        func placeholder(_ message: String, action: Bool = false) -> AnyView {
            AnyView(StandardPlaceholder(glyph: "film", title: "No Films", message: message,
                                        actionTitle: action ? "Clear Filters" : nil,
                                        action: action ? {} : nil))
        }
        let variants: [(String, AnyView)] = [
            ("two-lines", placeholder(first + "\nA second line.")),
            ("three-lines", placeholder(first + "\nA second line.\nAnd a third.")),
            ("wrapped", placeholder(first + "\n" + wrapping)),
            ("with-action", placeholder(first, action: true)),
            ("three-lines-with-action", placeholder(first + "\nA second line.\nAnd a third.", action: true)),
        ]
        guard let baseRep = await renderPlaceholder(placeholder(first), in: window) else {
            r.check("render", false, "one-line placeholder did not render")
            window.close()
            return r
        }
        let base = inkRows(baseRep)
        let scale = baseRep.pixelsHigh / 480
        r.check("baseline-ink", base.lastInk > 0, "one-line ink ends at row \(base.lastInk) (\(scale)x)")
        for (name, view) in variants {
            guard let rep = await renderPlaceholder(view, in: window) else {
                r.check("anchor-\(name)", false, "did not render")
                continue
            }
            let other = inkRows(rep)
            func same(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>?) -> Bool {
                guard let a, let b else { return a == nil && b == nil }
                return abs(a.lowerBound - b.lowerBound) <= 1 && abs(a.upperBound - b.upperBound) <= 1
            }
            let firstDiff = (0...max(0, base.lastInk)).first { !same(base.rows[$0], other.rows[$0]) }
            r.check("anchor-\(name)", firstDiff == nil,
                    firstDiff.map { "rows differ from row \($0) (one-line ink ends at \(base.lastInk))" }
                        ?? "rows 0…\(base.lastInk) match the one-line placeholder")
            r.check("extends-down-\(name)", other.lastInk > base.lastInk + 4 * scale,
                    "ink ends at row \(other.lastInk), one-line at \(base.lastInk)")
            if let data = rep.representation(using: .png, properties: [:]), let dir = DebugSandbox.rootURL {
                try? data.write(to: dir.appendingPathComponent("placeholder-\(name).png"))
            }
        }
        if let data = baseRep.representation(using: .png, properties: [:]), let dir = DebugSandbox.rootURL {
            try? data.write(to: dir.appendingPathComponent("placeholder-one-line.png"))
        }
        window.contentView = nil
        await oneRunLoopTurn()
        window.close()
        return r
    }

    private static func importDetailsSegmentsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "import-details-segments")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = ImportSession(importType: "metadata", totalItems: 3, successCount: 2, updatedCount: 1,
                                    addedTitles: ["Alien", "Heat"], updatedTitles: ["Ran"],
                                    isCompleted: true)
        /// The popover draws no background of its own; the window's stands in for its material.
        let host = NSHostingView(rootView: DebugHarness.sessionDetailsPopover(session)
            .background(Color(NSColor.windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await oneRunLoopTurn() }

        var stack: [NSView] = [host]
        var found: NSSegmentedControl?
        while let v = stack.popLast(), found == nil {
            if let seg = v as? NSSegmentedControl { found = seg }
            stack.append(contentsOf: v.subviews)
        }
        guard let seg = found else {
            r.check("control-found", false, "no NSSegmentedControl in the popover")
            window.close()
            return r
        }
        let labels = (0..<seg.segmentCount).map { seg.label(forSegment: $0) ?? "" }
        let enabled = (0..<seg.segmentCount).map { seg.isEnabled(forSegment: $0) }
        r.check("labels", labels == ["All", "Added", "Updated", "Errors", "Duplicates"], "\(labels)")
        r.check("enabled", enabled == [true, true, true, false, false], "\(enabled)")
        r.check("selected-all", seg.selectedSegment == 0, "selected \(seg.selectedSegment)")
        r.check("refuses-first-responder", seg.refusesFirstResponder, "")

        /// Every label fits: the control is no narrower than its .fit width.
        let width = seg.frame.width
        seg.segmentDistribution = .fit
        seg.invalidateIntrinsicContentSize()
        let fitWidth = seg.intrinsicContentSize.width
        seg.segmentDistribution = .fillEqually
        seg.invalidateIntrinsicContentSize()
        r.check("labels-fit", width + 0.5 >= fitWidth, "frame \(Fmt.fixed(width, 1)) vs fit \(Fmt.fixed(fitWidth, 1))")

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]), let dir = DebugSandbox.rootURL {
                try? data.write(to: dir.appendingPathComponent("import-details-segments.png"))
            }
        }
        window.contentView = nil
        await oneRunLoopTurn()
        window.close()
        return r
    }
}


// MARK: - Sidebar disclosure
///
/// `sidebar-disclosure` (in `all`): drives the smart list disclosure rows in the REAL main
/// window's sidebar (22_00). Expanding and collapsing go through the rows' own disclosure
/// buttons, and row selection through NSOutlineView.selectRowIndexes, which posts the same
/// selection-change notification a click does. Checks, against the Purchased family: a
/// variant chosen from the title bar while collapsed leaves nothing highlighted, expanding
/// reveals it highlighted, collapsing neither navigates nor moves the highlight to the
/// parent, a child row selects its variant within the family and from another view, the
/// parent row returns to the parent list, and the expansion is written to Preferences.
///
/// `sidebar-expansion-seed` then `sidebar-expansion-restore` (opt-in, two launches on ONE
/// container): the first saves Unpurchased and Filtered Library as expanded, the second
/// checks that exactly those two families launch expanded.
extension DebugHarness {

    private static let seededExpansion: Set<SmartListType> = [.unpurchased, .filteredLibrary]

    private static func sidebarExpansionSeedScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sidebar-expansion-seed")
        Preferences.expandedSmartListFamilies = seededExpansion
        r.check("seeded", Preferences.expandedSmartListFamilies == seededExpansion, "\(Preferences.expandedSmartListFamilies)")
        return r
    }

    private static func sidebarExpansionRestoreScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sidebar-expansion-restore")
        guard let outline = sidebarOutline() else { r.check("outline-found", false, ""); return r }
        let titles = rowTitles(outline)
        let expanded = SmartListType.sidebarCases.filter { family in
            guard let row = titles.firstIndex(of: family.rawValue) else { return false }
            return outline.isItemExpanded(outline.item(atRow: row))
        }
        r.check("restored", Set(expanded) == seededExpansion && !titles.contains("?"),
                "expanded \(expanded.map(\.rawValue)), rows \(titles)")
        return r
    }

    private static func sidebarOutline() -> NSOutlineView? {
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        var stack: [NSView] = window?.contentView.map { [$0] } ?? []
        while let v = stack.popLast() {
            if let outline = v as? NSOutlineView { return outline }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    /// Row titles, by row index, named from the outline's structure: SwiftUI's sidebar rows
    /// expose no readable text (no AX client is attached to a harness run). Built from the same
    /// sources LeftSidebar draws from, so a section or family added there is named here too:
    /// level-0 rows are the section headers (Smart Lists only while enabled, Saved Searches only
    /// once one exists); the Library rows are All Films, the grouped families, Imports and the
    /// Queue, each family's level-2 rows its `childTabs`; a Smart Lists level-1 row is the next
    /// of `sidebarCases` and its level-2 rows that family's variants; the Lists and Saved
    /// Searches rows are `cachedLists` and the saved searches in order. Any row the structure
    /// does not account for is named "?", which the scenario's row-count checks catch.
    private static func rowTitles(_ outline: NSOutlineView) -> [String] {
        let libraryFamilies: [SidebarLibraryFamily?] =
            [nil] + SidebarLibraryFamily.grouped.map(Optional.some) + [nil, .queue]
        let library = [LibraryItem.allFilms.title] + SidebarLibraryFamily.grouped.map(\.title)
            + [LibraryItem.imports.title, SidebarLibraryFamily.queue.title]
        let lists = AppDelegate.dataCoordinator?.cachedLists.map(\.listName) ?? []
        let searches = SavedSearchStore.shared.searches.map(\.name)
        var sections: [(header: String, rows: [String])] = [("§Library", library)]
        if Preferences.smartLists { sections.append(("§Smart Lists", SmartListType.sidebarCases.map(\.rawValue))) }
        sections.append(("§Lists", lists))
        if !searches.isEmpty { sections.append(("§Saved Searches", searches)) }

        var titles: [String] = []
        var section = -1
        var level1 = 0
        var level2 = 0
        var children: [String] = []
        for row in 0..<outline.numberOfRows {
            switch outline.level(forRow: row) {
            case 0:
                section += 1; level1 = 0
                titles.append(sections.indices.contains(section) ? sections[section].header : "?")
            case 1:
                let names = sections.indices.contains(section) ? sections[section].rows : []
                titles.append(names.indices.contains(level1) ? names[level1] : "?")
                children = []
                switch sections.indices.contains(section) ? sections[section].header : "" {
                case "§Library":
                    if libraryFamilies.indices.contains(level1), let family = libraryFamilies[level1] {
                        children = family.childTabs.map(\.title)
                    }
                case "§Smart Lists":
                    if SmartListType.sidebarCases.indices.contains(level1) {
                        children = SmartListType.sidebarCases[level1].familyVariants.dropFirst().map(\.rawValue)
                    }
                default: break
                }
                level1 += 1; level2 = 0
            default:
                titles.append(children.indices.contains(level2) ? children[level2] : "?")
                level2 += 1
            }
        }
        return titles
    }

    private static func row(_ title: String, in outline: NSOutlineView) -> Int? {
        rowTitles(outline).firstIndex(of: title)
    }

    private static func highlighted(_ outline: NSOutlineView) -> String {
        let titles = rowTitles(outline)
        let rows = outline.selectedRowIndexes.map { titles.indices.contains($0) ? titles[$0] : "#\($0)" }
        return rows.isEmpty ? "<none>" : rows.joined(separator: ", ")
    }

    private static func disclosureButton(row: Int, in outline: NSOutlineView) -> NSButton? {
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: true) else { return nil }
        var stack: [NSView] = [rowView]
        while let v = stack.popLast() {
            if let b = v as? NSButton, b.identifier == NSOutlineView.disclosureButtonIdentifier { return b }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    private static func sidebarDisclosureScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sidebar-disclosure")
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }
        guard let outline = sidebarOutline() else { r.check("outline-found", false, "no NSOutlineView in the main window"); return r }
        let state = SmartListVariantState.shared(for: .purchased)
        let views = ViewStateManager.shared

        func toggle(_ title: String) async -> Bool {
            guard let row = row(title, in: outline), let button = disclosureButton(row: row, in: outline) else { return false }
            button.performClick(nil)
            await settle()
            return true
        }
        func click(_ title: String) async -> Bool {
            guard let row = row(title, in: outline) else { return false }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            await settle(400)
            return true
        }
        func snapshot() -> String {
            "highlight \(highlighted(outline)), sidebar \(appState.selectedSidebarItem), view \(views.activeView), picker \(state.selected.rawValue)"
        }

        /// The Smart Lists section is what this drives, so it must be showing.
        let smartListsWereShown = Preferences.smartLists
        if !smartListsWereShown { Preferences.smartLists = true; await settle(400) }
        defer { if !smartListsWereShown { Preferences.smartLists = false } }

        /// Start collapsed, on the parent.
        Preferences.expandedSmartListFamilies = []
        appState.navigate(to: .libraryItem(.allFilms))
        await settle()
        appState.navigate(to: .smartList(.purchased))
        await settle(400)
        let titles = rowTitles(outline)
        log("sidebar-disclosure rows: \(titles)")
        r.check("rows-accounted", !titles.contains("?") && titles.contains("Purchased"), "\(titles)")
        r.check("collapsed-no-children", !titles.contains("Purchased 4K"), "\(titles)")
        r.check("parent-highlighted", highlighted(outline) == "Purchased", snapshot())

        /// Title-bar picker (or shortcut) while collapsed: the highlight goes away.
        state.select(.purchased4K, immediate: true)
        await settle(400)
        r.check("variant-collapsed-unhighlighted", highlighted(outline) == "<none>" && views.activeView == .smartList(.purchased4K), snapshot())

        /// The shortcuts' deferred path ends the same way.
        state.select(.purchasedBluray)
        await settle(600)
        r.check("variant-deferred-unhighlighted", highlighted(outline) == "<none>" && views.activeView == .smartList(.purchasedBluray), snapshot())

        /// Expanding reveals the variant already highlighted.
        r.check("expand-button", await toggle("Purchased"), "no disclosure button on Purchased")
        let expandedTitles = rowTitles(outline)
        r.check("expanded-children", expandedTitles.count == titles.count + 3 && !expandedTitles.contains("?")
                    && outline.level(forRow: row("Purchased 4K", in: outline) ?? 0) == 2, "\(expandedTitles)")
        r.check("expanded-variant-highlighted", highlighted(outline) == "Purchased Blu-ray", snapshot())
        r.check("expansion-saved", Preferences.expandedSmartListFamilies == [.purchased], "\(Preferences.expandedSmartListFamilies)")

        /// Collapsing hides the highlight and changes nothing else.
        r.check("collapse-button", await toggle("Purchased"), "")
        await settle(300)
        r.check("collapse-keeps-view", views.activeView == .smartList(.purchasedBluray) && state.selected == .purchasedBluray
                    && appState.selectedSidebarItem == .smartList(.purchased), snapshot())
        r.check("collapse-unhighlighted", highlighted(outline) == "<none>", snapshot())
        r.check("collapse-saved", Preferences.expandedSmartListFamilies.isEmpty, "\(Preferences.expandedSmartListFamilies)")

        /// Expand again; the highlight is back on the variant.
        _ = await toggle("Purchased")
        r.check("re-expand-highlighted", highlighted(outline) == "Purchased Blu-ray", snapshot())

        /// A child row within the family.
        r.check("child-click-found", await click("Purchased DVD"), "")
        r.check("child-click-in-family", views.activeView == .smartList(.purchasedDVD) && state.selected == .purchasedDVD
                    && appState.selectedSidebarItem == .smartList(.purchased) && highlighted(outline) == "Purchased DVD", snapshot())

        /// The parent row returns to the parent list.
        _ = await click("Purchased")
        r.check("parent-click-in-family", views.activeView == .smartList(.purchased) && state.selected == .purchased
                    && highlighted(outline) == "Purchased", snapshot())

        /// A child row from another view.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(400)
        r.check("elsewhere-highlight", highlighted(outline) == "All Films", snapshot())
        _ = await click("Purchased 4K")
        r.check("child-click-from-elsewhere", views.activeView == .smartList(.purchased4K) && state.selected == .purchased4K
                    && appState.selectedSidebarItem == .smartList(.purchased) && highlighted(outline) == "Purchased 4K", snapshot())

        /// The parent row from another view resets the family.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(400)
        _ = await click("Purchased")
        r.check("parent-click-from-elsewhere", views.activeView == .smartList(.purchased) && state.selected == .purchased
                    && highlighted(outline) == "Purchased", snapshot())

        /// Leave it as found.
        _ = await toggle("Purchased")
        Preferences.expandedSmartListFamilies = []
        appState.navigate(to: .libraryItem(.allFilms))
        await settle()
        return r
    }
}


// MARK: - Insights-shaped corpus

extension DebugHarness {
    /// `standardCorpus` gives every Insights table tab NOTHING to show — its purchases carry no
    /// cost, nothing has a lowest price, a Hall of Fame position or a wishlist flag — so the
    /// tabs render their "No Data" placeholders and measure as cheap. This one fills all four
    /// the way a real library does: 1,400 films with one or two releases each, about 70%
    /// purchased with costs, the rest tracking a lowest price, 200 Hall of Fame positions, and
    /// every eighth film wishlisting its unpurchased release.
    static func reportsCorpus() -> [FilmSnapshot] {
        var generator = SeededGenerator(seed: 0x4E7)
        let formats = [ReleaseFormat.bluRay, .uhd4K, .dvd].map(\.rawValue)
        let studios = ["Criterion", "Arrow Video", "Warner Bros.", "Kino Lorber", "Shout! Factory"]
        var wishlistOrder = 0
        var hofPosition = 0
        return standardCorpus(count: 1400, seed: 0xD15).enumerated().map { index, film in
            var f = film
            let count = Int.random(in: 1...2, using: &generator)
            f.releases = (0..<count).map { i in
                let month = 1 + Int.random(in: 0...11, using: &generator)
                let year = 2016 + Int.random(in: 0...9, using: &generator)
                let day = "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(1 + (index + i) % 27, 2))"
                let studio = studios[(index + i) % studios.count]
                let format = formats[Int.random(in: 0...2, using: &generator)]
                if Int.random(in: 0...9, using: &generator) < 7 {
                    let cost = Double(Int.random(in: 5...45, using: &generator)) + 0.99
                    return ReleaseSnapshot(studio: studio, purchased: true, format: format,
                                           cost: cost, amountSpent: cost - 2, purchaseDate: day,
                                           sortOrder: i)
                }
                var wishlist = 0
                if index % 8 == 0 { wishlistOrder += 1; wishlist = wishlistOrder }
                return ReleaseSnapshot(studio: studio, purchased: false, wishlist: wishlist, format: format,
                                       lowestPrice: Double(Int.random(in: 8...30, using: &generator)) + 0.49,
                                       lowestPriceDate: day, sortOrder: i)
            }
            if index % 7 == 0 && hofPosition < 200 { hofPosition += 1; f.hofPosition = hofPosition }
            return f
        }
    }
}

// MARK: - Insights hitch, in the real window
///
/// `reports-hitch` (opt-in, a measurement): the sub-tab switch as the user sees it, in the app's
/// REAL main window (the harness runs after MainView is up) — so drawing, the right sidebar,
/// the status bar and the CoreAnimation commit are all included. Launch with `open -g -n` so the window is shown without
/// activating the app. A run-loop observer ordered after CoreAnimation's commit records every
/// busy stretch (after-waiting → before-waiting) of the main thread; per switch it reports the
/// first stretch (the delay until the frame carrying the new content is committed), the total
/// busy time, and the longest stretch, over 800 ms. The same measurement is taken for the
/// sub-tab switches the user compares Insights against: Recents categories and smart-list
/// variants (their menu-style pickers call exactly these methods).
extension DebugHarness {

    @MainActor final class RunLoopBusyRecorder {
        private(set) var events: [(time: Double, idle: Bool)] = []
        private var observer: CFRunLoopObserver?

        func start() {
            let o = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true, CFIndex(Int32.max)) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    self?.events.append((CACurrentMediaTime() * 1000, activity == .beforeWaiting))
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            observer = o
        }

        func stop() { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }
        func reset() { events.removeAll(keepingCapacity: true) }

        struct Reading { var first = 0.0; var busy = 0.0; var longest = 0.0; var stretches = 0 }

        /// Busy stretches in [t0, t0 + window]; the switch itself starts mid-stretch at t0.
        func reading(from t0: Double, window: Double) -> Reading {
            var r = Reading()
            var busySince: Double? = t0
            for e in events where e.time >= t0 && e.time <= t0 + window {
                if e.idle, let since = busySince {
                    let d = e.time - since
                    if r.stretches == 0 { r.first = d }
                    r.busy += d; r.longest = max(r.longest, d); r.stretches += 1
                    busySince = nil
                } else if !e.idle {
                    busySince = e.time
                }
            }
            return r
        }
    }

    static func insightsHitchScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-hitch")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        r.check("real-window", window != nil,
                window.map { "frame \($0.frame), occlusion visible \($0.occlusionState.contains(.visible))" } ?? "none")

        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        var byKind: [String: [RunLoopBusyRecorder.Reading]] = [:]
        func measure(_ kind: String, _ action: () -> Void) async {
            await settle(500)
            recorder.reset()
            let t0 = CACurrentMediaTime() * 1000
            action()
            await settle(800)
            byKind[kind, default: []].append(recorder.reading(from: t0, window: 800))
        }

        /// Insights: the four table tabs among themselves, then into and out of Visualizations.
        appState.navigate(to: .libraryItem(.insights))
        let reports = InsightsState.shared
        reports.selectCategory(.costTracker, immediate: true)
        await settle(1500)
        let tables: [InsightsCategory] = [.priceTracker, .hallOfFame, .releaseWishlist, .costTracker]
        for _ in 0..<3 {
            for t in tables { await measure("reports-table→table") { reports.selectCategory(t, immediate: true) } }
        }
        for _ in 0..<3 {
            await measure("reports-table→dataviz") { reports.selectCategory(.insights, immediate: true) }
            await measure("reports-dataviz→table") { reports.selectCategory(.hallOfFame, immediate: true) }
        }

        /// Recents: one mounted gallery, reloaded per category.
        appState.navigate(to: .libraryItem(.recents))
        await settle(1500)
        for _ in 0..<3 {
            for c in RecentsCategory.sections {
                await measure("recents-category") { RecentsState.shared.selectCategory(c, immediate: true) }
            }
        }

        /// Smart-list variants of the first family with more than one variant.
        if let parent = SmartListType.sidebarCases.first(where: { $0.familyVariants.count > 1 }) {
            appState.navigate(to: .smartList(parent))
            await settle(1500)
            let state = SmartListVariantState.shared(for: parent)
            for _ in 0..<3 {
                for v in parent.familyVariants.dropFirst() + [parent] {
                    await measure("smartlist-variant") { state.select(v, immediate: true) }
                }
            }
        }

        /// Full sidebar switches between two gallery views, for scale.
        for _ in 0..<3 {
            await measure("sidebar-gallery→gallery") { appState.navigate(to: .libraryItem(.allFilms)) }
            await measure("sidebar-gallery→gallery") { appState.navigate(to: .libraryItem(.filmQueue)) }
        }

        for (kind, readings) in byKind.sorted(by: { $0.key < $1.key }) {
            r.metric("\(kind)-first-median", stats(readings.map(\.first)).median, "ms")
            r.metric("\(kind)-first-max", stats(readings.map(\.first)).max, "ms")
            r.metric("\(kind)-busy-median", stats(readings.map(\.busy)).median, "ms")
            r.metric("\(kind)-longest-median", stats(readings.map(\.longest)).median, "ms")
            r.metric("\(kind)-samples", Double(readings.count), "n")
        }
        return r
    }
}

// MARK: - Insights table behavior, in the real window
///
/// `reports-table-behavior` (opt-in): the AppKit InsightsTable (27.01) does what the SwiftUI Table
/// and List it replaced did, driven through the table itself in the real window — selection into
/// SelectionState and back out, header sorting onto the tracker's KeyPathComparator order (and
/// InsightsState's saved order), multi-selection, and a Hall of Fame reorder through the table's
/// drop path into the store. Launch with `open -g -n`.
extension DebugHarness {
    static func insightsTableBehaviorScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-table-behavior")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else { r.check("setup", false, ""); return r }
        func settle(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
        func reportTable<Row>(_: Row.Type) -> (NSTableView, InsightsTable<Row>.Coordinator)? {
            for t in tables(in: window.contentView!) {
                if let c = t.dataSource as? InsightsTable<Row>.Coordinator { return (t, c) }
            }
            return nil
        }
        let selection = SelectionState.shared
        let reports = InsightsState.shared

        // MARK: Cost tracker — selection, sort
        appState.navigate(to: .libraryItem(.insights))
        reports.selectCategory(.costTracker, immediate: true)
        await settle(1200)
        guard let (costTable, _) = reportTable(ReleaseData.self) else {
            r.check("cost-table-found", false, "no InsightsTable<ReleaseData> in the window")
            return r
        }
        let costRows = ReleaseData.costTrackerRows(films: coordinator.getAllFilms())
        r.check("cost-row-count", costTable.numberOfRows == costRows.count,
                "table \(costTable.numberOfRows), expected \(costRows.count) (no 50-row window)")
        r.check("cost-header-shows-default-sort",
                costTable.sortDescriptors.first?.key == "purchaseDate" && costTable.sortDescriptors.first?.ascending == false,
                "\(costTable.sortDescriptors)")

        costTable.selectRowIndexes([3], byExtendingSelection: false)
        await settle()
        let sorted = ReleaseData.sorted(costRows, using: ReleaseData.costTrackerDefaultSort)
        r.check("select-reaches-selection-state", selection.selectedFilmIDs == [sorted[3].filmID],
                "selected \(selection.selectedFilmIDs.count) film(s)")

        costTable.selectRowIndexes([0, 1, 2], byExtendingSelection: false)
        await settle()
        let expectedMulti = Set(sorted.prefix(3).map(\.filmID))
        r.check("multi-select-reaches-selection-state", selection.selectedFilmIDs == expectedMulti,
                "\(selection.selectedFilmIDs.count) of \(expectedMulti.count)")

        selection.clearImmediate()
        await settle()
        r.check("external-clear-deselects-table", costTable.selectedRowIndexes.isEmpty,
                "\(costTable.selectedRowIndexes.count) rows still selected")

        /// A header click is NSTableView replacing its sortDescriptors; the delegate reports it.
        costTable.sortDescriptors = [NSSortDescriptor(key: "filmTitle", ascending: true)] + costTable.sortDescriptors
        await settle()
        let titleOrder = ReleaseData.comparators(forHeaderSort: [("filmTitle", true), ("purchaseDate", false)])
        let byTitle = ReleaseData.sorted(costRows, using: titleOrder)
        let saved = reports.savedSortOrder(for: .costTracker)
        r.check("header-sort-saved-as-comparators", saved == titleOrder, "\(String(describing: saved))")
        costTable.selectRowIndexes([0], byExtendingSelection: false)
        await settle()
        r.check("header-sort-reorders-rows", selection.selectedFilmIDs == [byTitle[0].filmID], "")
        /// Restore the default so a later visit starts where a user's would.
        costTable.sortDescriptors = [NSSortDescriptor(key: "purchaseDate", ascending: false)]
        await settle()
        selection.clearImmediate()

        // MARK: Hall of Fame — selection, reorder
        reports.selectCategory(.hallOfFame, immediate: true)
        await settle(800)
        guard let (hofTable, hofCoordinator) = reportTable(HallOfFameFilm.self) else {
            r.check("hof-table-found", false, "")
            return r
        }
        let before = coordinator.hallOfFameFilms
        r.check("hof-row-count", hofTable.numberOfRows == before.count, "\(hofTable.numberOfRows) vs \(before.count)")
        hofTable.selectRowIndexes([1], byExtendingSelection: false)
        await settle()
        r.check("hof-select-reaches-selection-state", selection.selectedFilmIDs == [before[1]], "")
        selection.clearImmediate()
        await settle()

        /// Drag rows 0 and 2 to above row 5: SwiftUI onMove / Array.move semantics.
        var expected = before
        expected.move(fromOffsets: [0, 2], toOffset: 5)
        let reloadsBefore = (hofTable as? InsightsNSTableView)?.fullReloadCount
        let moved = hofCoordinator.move([0, 2], to: 5)
        /// The table shows the new order at once (the rows slide there), before the store
        /// answers.
        r.check("hof-reorder-shown-immediately", Array(hofCoordinator.rowIDs.prefix(8)) == Array(expected.prefix(8)), "")
        await settle(600)
        r.check("hof-reorder-accepted", moved, "")
        /// The renumbered rows that come back refresh cells in place: a full reload would
        /// snap the rows instead of letting them slide.
        let reloadsAfter = (hofTable as? InsightsNSTableView)?.fullReloadCount
        r.check("hof-reorder-no-full-reload", reloadsBefore != nil && reloadsBefore == reloadsAfter,
                "full reloads \(String(describing: reloadsBefore)) → \(String(describing: reloadsAfter))")
        if let reportTable = hofTable as? InsightsNSTableView, reportTable.numberOfRows > 3 {
            reportTable.showDropIndicator(aboveRow: 3)
            let shown = reportTable.dropIndicator
            r.check("hof-drop-indicator-shown", shown.map { $0.isHidden == false && reportTable.subviews.contains($0) } == true, "")
            r.check("hof-drop-indicator-on-boundary", shown.map { abs($0.frame.midY - reportTable.rect(ofRow: 3).minY) < 0.5 } == true,
                    "midY \(String(describing: shown?.frame.midY)) vs \(reportTable.rect(ofRow: 3).minY)")
            reportTable.hideDropIndicator()
            r.check("hof-drop-indicator-hidden", reportTable.dropIndicator?.isHidden == true, "")
        }
        r.check("hof-reorder-table-matches-store",
                Array(hofCoordinator.rowIDs.prefix(8)) == Array(coordinator.hallOfFameFilms.prefix(8)), "")
        r.check("hof-reorder-reaches-store", Array(coordinator.hallOfFameFilms.prefix(8)) == Array(expected.prefix(8)),
                "store head \(coordinator.hallOfFameFilms.prefix(4).map { $0.uuidString.prefix(4) })")
        let firstCell = hofTable.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityValue() as? String
        r.check("hof-positions-renumbered", firstCell == "1.", "first position cell \(String(describing: firstCell))")


        // MARK: Wishlist — rows present
        reports.selectCategory(.releaseWishlist, immediate: true)
        await settle(800)
        let wishRows = WishlistRelease.rows(pairs: coordinator.getWishlistReleases())
        let wish = reportTable(WishlistRelease.self)
        r.check("wishlist-row-count", wish?.0.numberOfRows == wishRows.count,
                "\(String(describing: wish?.0.numberOfRows)) vs \(wishRows.count)")
        return r
    }
}

// MARK: - report-lists-cost
///
/// `report-lists-cost` (opt-in, real window, run on a library copy): what the Hall of Fame and Release
/// Wishlist tabs cost the main thread, to judge which of their loads are worth running off it.
///   • The pieces of one reload, timed on the main thread (median of 30): the ranked fetch and row
///     build, the library scan and row build, and the change-guard compares.
///   • Revisits of each tab (busy time over 800 ms), with the mount reconcile off the main thread as
///     shipped, beside what the same reconcile costs when run on it.
///   • A drag through each table's drop path: the synchronous cost of the drop (which posts one film
///     event per moved film), the busy time after it, and that the rows slid rather than reloaded and
///     ended in the store's order. The old per-event reload is priced as events × one reload.
extension DebugHarness {
    static func reportListsCostScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "report-lists-cost")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else { r.check("setup", false, "no real window"); return r }
        func settle(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
        func reportTable<Row>(_: Row.Type) -> (NSTableView, InsightsTable<Row>.Coordinator)? {
            for t in tables(in: window.contentView!) {
                if let c = t.dataSource as? InsightsTable<Row>.Coordinator { return (t, c) }
            }
            return nil
        }
        func time(_ runs: Int = 30, _ body: () -> Void) -> Double {
            var samples: [Double] = []
            for _ in 0..<runs {
                let t0 = CACurrentMediaTime()
                body()
                samples.append((CACurrentMediaTime() - t0) * 1000)
            }
            return stats(samples).median
        }

        let months = Preferences.defaultRotationThreshold
        let hofRows = HallOfFameFilm.rows(films: coordinator.getHallOfFameFilms(), rotationMonths: months)
        let wishRows = WishlistRelease.rows(pairs: coordinator.getWishlistReleases())
        r.metric("films", Double(coordinator.getAllFilms().count), "n")
        r.metric("hof-rows", Double(hofRows.count), "n")
        r.metric("wish-rows", Double(wishRows.count), "n")

        // MARK: Pieces of one reload
        var sink = 0
        let hofFetch = time { sink &+= coordinator.getHallOfFameFilms().count }
        let ranked = coordinator.getHallOfFameFilms()
        let hofBuild = time { sink &+= HallOfFameFilm.rows(films: ranked, rotationMonths: months).count }
        let hofCopy = hofRows.map { $0 }
        let hofCompare = time { sink &+= (hofCopy == hofRows) ? 1 : 0 }
        let hofTotals = time { sink &+= HallOfFameTotals(rows: hofRows).total }
        let wishScan = time { sink &+= coordinator.getWishlistReleases().count }
        let pairs = coordinator.getWishlistReleases()
        let wishBuild = time { sink &+= WishlistRelease.rows(pairs: pairs).count }
        let wishCopy = wishRows.map { $0 }
        let wishCompare = time { sink &+= (wishCopy == wishRows) ? 1 : 0 }
        let mapCapture = time { sink &+= coordinator.getAllFilmsMap().count }
        /// Where the time goes inside each build.
        r.metric("split-hof-build-no-rotation-ms",
                 time { sink &+= HallOfFameFilm.rows(films: ranked, rotationMonths: nil).count }, "ms")
        let watched = ranked.map(\.lastWatched)
        r.metric("split-hof-parse-dates-ms", time { sink &+= watched.compactMap { parseDate(from: $0) }.count }, "ms")
        let dates = watched.compactMap { parseDate(from: $0) }
        r.metric("split-hof-eligibility-ms",
                 time { sink &+= dates.compactMap { rotationEligibilityDate(from: $0, months: months) }.count }, "ms")
        r.metric("split-hof-purchase-ms",
                 time { sink &+= ranked.map { HallOfFamePurchase.forReleases($0.releases) }.count }, "ms")
        r.metric("split-wish-copy-values-ms", time { sink &+= coordinator.getAllFilms().count }, "ms")
        let allFilms = coordinator.getAllFilms()
        r.metric("split-wish-filter-ms", time { sink &+= DataCoordinator.wishlistPairs(in: allFilms).count }, "ms")
        let filmsMap = coordinator.getAllFilmsMap()
        r.metric("split-wish-map-scan-ms", time {
            var n = 0
            for film in filmsMap.values where film.releases.contains(where: { $0.wishlist > 0 && $0.isTopLevel }) { n += 1 }
            sink &+= n
        }, "ms")
        let hofReload = hofFetch + hofBuild + hofCompare * 2 + hofTotals
        let wishReload = wishScan + wishBuild + wishCompare * 2
        r.metric("hof-fetch-ms", hofFetch, "ms")
        r.metric("hof-build-ms", hofBuild, "ms")
        r.metric("hof-compare-ms", hofCompare, "ms")
        r.metric("hof-totals-ms", hofTotals, "ms")
        r.metric("hof-one-reload-ms", hofReload, "ms")
        r.metric("wish-scan-ms", wishScan, "ms")
        r.metric("wish-build-ms", wishBuild, "ms")
        r.metric("wish-compare-ms", wishCompare, "ms")
        r.metric("wish-one-reload-ms", wishReload, "ms")
        /// What the reconciles do on the main thread before handing off: HoF copies the ranked films, the Wishlist retains the map.
        r.metric("reconcile-main-capture-hof-ms", hofFetch, "ms")
        r.metric("reconcile-main-capture-wish-ms", mapCapture, "ms")
        r.metric("reconcile-if-on-main-hof-ms", hofFetch + hofBuild + hofCompare, "ms")
        r.metric("reconcile-if-on-main-wish-ms", wishScan + wishBuild + wishCompare, "ms")

        // MARK: Revisits
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        let reports = InsightsState.shared
        appState.navigate(to: .libraryItem(.insights))
        reports.selectCategory(.costTracker, immediate: true)
        await settle(1500)
        reports.selectCategory(.hallOfFame, immediate: true)
        await settle(800)
        reports.selectCategory(.releaseWishlist, immediate: true)
        await settle(800)
        var revisits: [String: [RunLoopBusyRecorder.Reading]] = [:]
        for _ in 0..<5 {
            for (name, category) in [("hof", InsightsCategory.hallOfFame), ("wish", .releaseWishlist), ("cost", .costTracker)] {
                await settle(500)
                recorder.reset()
                let t0 = CACurrentMediaTime() * 1000
                reports.selectCategory(category, immediate: true)
                await settle(800)
                revisits[name, default: []].append(recorder.reading(from: t0, window: 800))
            }
        }
        for (name, readings) in revisits.sorted(by: { $0.key < $1.key }) {
            r.metric("revisit-\(name)-busy-median", stats(readings.map(\.busy)).median, "ms")
            r.metric("revisit-\(name)-first-median", stats(readings.map(\.first)).median, "ms")
            r.metric("revisit-\(name)-longest-median", stats(readings.map(\.longest)).median, "ms")
        }

        // MARK: Drags
        func drag<Row: Identifiable & Equatable>(_ label: String, _: Row.Type, category: InsightsCategory,
                                                 storeOrder: () -> [UUID], moves: [(IndexSet, Int)]) async where Row.ID == UUID {
            reports.selectCategory(category, immediate: true)
            await settle(1000)
            guard let (table, tableCoordinator) = reportTable(Row.self), table.numberOfRows > 2 else {
                r.skip("\(label)-drag", "table missing or under three rows")
                return
            }
            var syncMs: [Double] = []
            var busy: [Double] = []
            var events: [Int] = []
            for (source, destination) in moves {
                let reloadsBefore = (table as? InsightsNSTableView)?.fullReloadCount
                var expected = tableCoordinator.rowIDs
                expected.move(fromOffsets: source, toOffset: destination)
                var posted = 0
                let counter = AppEventBus.shared.filmEvents.sink { _ in posted += 1 }
                await settle(300)
                recorder.reset()
                let t0 = CACurrentMediaTime()
                let moved = tableCoordinator.move(source, to: destination)
                let sync = (CACurrentMediaTime() - t0) * 1000
                let shownAtOnce = tableCoordinator.rowIDs == expected
                await settle(800)
                counter.cancel()
                syncMs.append(sync)
                busy.append(recorder.reading(from: t0 * 1000, window: 800).busy)
                events.append(posted)
                let reloadsAfter = (table as? InsightsNSTableView)?.fullReloadCount
                r.check("\(label)-drag-accepted", moved, "")
                r.check("\(label)-drag-shown-immediately", shownAtOnce, "")
                r.check("\(label)-drag-no-full-reload", reloadsBefore != nil && reloadsBefore == reloadsAfter,
                        "full reloads \(String(describing: reloadsBefore)) → \(String(describing: reloadsAfter))")
                r.check("\(label)-drag-table-matches-store", tableCoordinator.rowIDs == storeOrder(), "")
            }
            r.metric("\(label)-drag-events-median", stats(events.map(Double.init)).median, "n")
            r.metric("\(label)-drag-sync-median", stats(syncMs).median, "ms")
            r.metric("\(label)-drag-sync-max", stats(syncMs).max, "ms")
            r.metric("\(label)-drag-busy-median", stats(busy).median, "ms")
        }
        let hofCount = coordinator.hallOfFameFilms.count
        await drag("hof", HallOfFameFilm.self, category: .hallOfFame,
                   storeOrder: { coordinator.hallOfFameFilms },
                   moves: [([0], hofCount), ([hofCount - 1], 0), ([0], hofCount), ([hofCount - 1], 0),
                           ([0], 5), ([4], 0)])
        let wishCount = coordinator.getWishlistReleases().count
        await drag("wish", WishlistRelease.self, category: .releaseWishlist,
                   storeOrder: { WishlistRelease.rows(pairs: coordinator.getWishlistReleases()).map(\.id) },
                   moves: [([0], wishCount), ([wishCount - 1], 0), ([0], wishCount), ([wishCount - 1], 0),
                           ([0], 3), ([2], 0)])
        /// The drop's synchronous part, split: delivering one film event to every subscriber in the app (HoF tab mounted),
        /// and the coordinator's reorder (store write plus those events) without the table.
        reports.selectCategory(.hallOfFame, immediate: true)
        await settle(1000)
        let members = coordinator.hallOfFameFilms
        var fanOut: [Double] = []
        var reorderOnly: [Double] = []
        for _ in 0..<5 {
            await settle(300)
            let t0 = CACurrentMediaTime()
            for id in members { AppEventBus.shared.send(.film(.updated(filmID: id))) }
            fanOut.append((CACurrentMediaTime() - t0) * 1000 / Double(max(members.count, 1)))
            await settle(300)
            var rotated = coordinator.hallOfFameFilms
            rotated.append(rotated.removeFirst())
            let t1 = CACurrentMediaTime()
            coordinator.reorderHallOfFame(rotated)
            reorderOnly.append((CACurrentMediaTime() - t1) * 1000)
        }
        let isolated = MemoryStore.isolatedForTesting(films: coordinator.getAllFilms(), lists: [])
        var storeOnly: [Double] = []
        for _ in 0..<5 {
            var rotated = isolated.hallOfFameFilms
            rotated.append(rotated.removeFirst())
            let t = CACurrentMediaTime()
            _ = isolated.reorderHallOfFame(rotated)
            storeOnly.append((CACurrentMediaTime() - t) * 1000)
        }
        r.metric("split-drop-store-reorder-ms", stats(storeOnly).median, "ms")
        r.metric("split-drop-baseline-reads-ms", time(5) {
            for id in members { sink &+= coordinator.getFilm(id)?.hofPosition ?? 0 }
        }, "ms")
        r.metric("split-drop-event-fanout-per-event-ms", stats(fanOut).median, "ms")
        r.metric("split-drop-reorder-198-ms", stats(reorderOnly).median, "ms")
        var wishReorder: [Double] = []
        for _ in 0..<5 {
            await settle(300)
            var rotated = WishlistRelease.rows(pairs: coordinator.getWishlistReleases()).map { (filmID: $0.filmID, releaseID: $0.releaseID) }
            guard rotated.count > 1 else { break }
            rotated.append(rotated.removeFirst())
            let t = CACurrentMediaTime()
            coordinator.reorderWishlist(rotated)
            wishReorder.append((CACurrentMediaTime() - t) * 1000)
        }
        r.metric("split-drop-wish-reorder-ms", stats(wishReorder).median, "ms")
        r.metric("old-hof-drag-reload-estimate-ms", hofReload * Double(hofCount), "ms")
        r.metric("old-wish-drag-reload-estimate-ms", wishReload * Double(wishCount), "ms")
        r.metric("sink", Double(sink & 1), "n")
        return r
    }
}

// MARK: - releases-settle
///
/// The Releases tab's deferred work against a save, and the load repairs a save must carry.
/// Headless on purpose. Every behavior checked here lives in FSTabReleases, and the checks prove
/// it runs with no card mounted. The independence cascade belongs to the view model, not the card.
///
///   • delete-settle      — a save mid-fly-up deletes the release, and the fly-up's own
///                          completion afterwards changes nothing.
///   • combo-settle       — a save inside the 120 ms reconciliation window creates the child,
///                          exactly once.
///   • cascade-headless   — the Type change's dependent fields move with no card mounted.
///   • orphan-children    — a Standalone 4K holding a child: retyping removes it (the
///                          alert's promise), via the save-time settle.
///   • confirmed-settle   — a confirmed type-change alert whose write is still deferred is
///                          carried by a save landing in that turn, and not applied twice.
///   • load-repairs       — Case C / D repairs reach `toUpdate` with no user edit; an
///                          unrepaired release does not.
///   • display-numbers    — per-format card numbering, children unnumbered.
extension DebugHarness {

    /// A combo child whose every user-editable field matches a freshly created one, so
    /// retyping its parent needs no confirmation.
    ///
    /// The format-default fields are read from `ReleaseFormat.newReleaseDefaults`, the same
    /// source `FSTabReleases.makeComboChild` applies, rather than restated here. A restated copy
    /// would drift: a pristine child missing a default such as video format or included
    /// versions would count as edited, and the reduction would prompt instead of deleting.
    private static func pristineChildSnapshot(id: UUID, parent: UUID, sortOrder: Int) -> ReleaseSnapshot {
        let defaults = ReleaseFormat.newReleaseDefaults(for: ReleaseFormat.bluRay.rawValue)
        return ReleaseSnapshot(id: id, format: ReleaseFormat.bluRay.rawValue,
                        includedVersions: defaults.includedVersions,
                        independence: ReleaseIndependence.comboPack,
                        videoFormat: defaults.videoFormat,
                        scanningMethod: defaults.scanningMethod,
                        audioFormat: defaults.audioFormat, audioChannels: defaults.audioChannels,
                        hasSubtitles: defaults.hasSubtitles,
                        nationalOrigin: defaults.nationalOrigin,
                        replicationType: ReleaseReplicationType.pressed,
                        regionLock: defaults.regionLock,
                        marketAvailability: [ReleaseMarketAvailability.comboPackOnly],
                        condition: ReleaseCondition.new,
                        sortOrder: sortOrder, parentReleaseID: parent)
    }

    static func releasesSettleScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "releases-settle")
        let bd = ReleaseFormat.bluRay.rawValue, uhd = ReleaseFormat.uhd4K.rawValue

        /// --- fixtures -------------------------------------------------------------------
        let a = UUID(), b = UUID()
        let fDelete = makeSnapshot(name: "Settle Delete", releases: [
            ReleaseSnapshot(id: a, format: bd, independence: ReleaseIndependence.standalone, sortOrder: 0),
            ReleaseSnapshot(id: b, format: bd, independence: ReleaseIndependence.standalone, sortOrder: 1)])

        let p = UUID()
        let fCombo = makeSnapshot(name: "Settle Combo", releases: [
            ReleaseSnapshot(id: p, format: uhd, independence: ReleaseIndependence.standalone,
                            hasArtwork: ReleaseArtwork.standard, sortOrder: 0)])

        let q = UUID(), c = UUID()
        let fOrphan = makeSnapshot(name: "Settle Orphan", releases: [
            ReleaseSnapshot(id: q, format: uhd, independence: ReleaseIndependence.standalone,
                            sortOrder: 0, childReleaseIDs: [c]),
            pristineChildSnapshot(id: c, parent: q, sortOrder: 1)])

        let rep = UUID(), repChild = UUID(), inverted = UUID(), clean = UUID()
        let fRepair = makeSnapshot(name: "Settle Repair", releases: [
            /// Case D: says dual BD, holds one child.
            ReleaseSnapshot(id: rep, format: uhd, independence: ReleaseIndependence.comboPackDualBD,
                            sortOrder: 0, childReleaseIDs: [repChild]),
            pristineChildSnapshot(id: repChild, parent: rep, sortOrder: 1),
            /// Case C: base year after the release year.
            ReleaseSnapshot(id: inverted, releaseDate: "2010", baseReleaseYear: "2012", format: bd,
                            independence: ReleaseIndependence.standalone,
                            dateAdded: Date(timeIntervalSinceReferenceDate: 0), sortOrder: 3),
            /// Already where a save's re-sort puts it (same release date, created later, so
            /// ahead of `inverted`), so nothing about it changes. See savedSortOrders.
            ReleaseSnapshot(id: clean, releaseDate: "2010", format: bd,
                            independence: ReleaseIndependence.standalone,
                            dateAdded: Date(timeIntervalSinceReferenceDate: 1000), sortOrder: 2)])

        let fixtures = [fDelete, fCombo, fOrphan, fRepair]
        coordinator.importFilms(fixtures)

        /// --- delete-settle --------------------------------------------------------------
        do {
            let vm = FilmSheet(coordinator: coordinator, filmID: fDelete.id).releasesTab!
            vm.deleteRelease(id: a)
            r.check("delete-settle/fly-up-started", vm.dismissingCardID == a, "dismissing \(String(describing: vm.dismissingCardID))")
            let deltas = vm.buildReleaseDeltas()
            r.check("delete-settle/deleted-in-deltas", deltas.delete == [a], "delete \(deltas.delete)")
            r.check("delete-settle/removed-now", vm.releases.map(\.id) == [b], "\(vm.releases.map(\.id))")
            r.check("delete-settle/fly-up-cleared", vm.dismissingCardID == nil && !vm.isTransitioning, "")
            try? await Task.sleep(for: .milliseconds(450))
            r.check("delete-settle/late-completion-inert",
                    vm.releases.map(\.id) == [b] && vm.dismissingCardID == nil, "\(vm.releases.count) releases")
            /// A second delete still works after the settled one.
            vm.deleteRelease(id: b)
            try? await Task.sleep(for: .milliseconds(450))
            r.check("delete-settle/next-delete-completes", vm.releases.isEmpty, "\(vm.releases.count) left")
        }

        /// --- combo-settle + cascade-headless -------------------------------------------
        do {
            let vm = FilmSheet(coordinator: coordinator, filmID: fCombo.id).releasesTab!
            let parent = vm.model(p)!
            vm.requestIndependenceChange(on: parent, to: ReleaseIndependence.comboPack)
            r.check("cascade-headless/artwork-reset", parent.hasArtwork == "", "hasArtwork \(parent.hasArtwork)")
            r.check("cascade-headless/multipack-flag", parent.discMultiPack == false, "")
            let deltas = vm.buildReleaseDeltas()
            let created = deltas.create
            r.check("combo-settle/child-created-by-save",
                    created.count == 1 && created.first?.parentReleaseID == p && created.first?.format == bd,
                    "create \(created.map { ($0.format, String(describing: $0.parentReleaseID)) })")
            r.check("combo-settle/parent-links-child", parent.childReleaseIDs == created.map(\.id), "")
            r.check("combo-settle/child-synced",
                    created.first?.marketAvailability == [ReleaseMarketAvailability.comboPackOnly]
                        && created.first?.independence == ReleaseIndependence.comboPack, "")
            try? await Task.sleep(for: .milliseconds(300))
            r.check("combo-settle/no-duplicate-child-after-window",
                    vm.releases.count == 2 && parent.childReleaseIDs.count == 1,
                    "\(vm.releases.count) releases, \(parent.childReleaseIDs.count) child id(s)")
            r.check("display-numbers/merged-card-numbered-once",
                    vm.carouselEntries.count == 1 && vm.displayNumbers[p] == 1
                        && vm.displayNumbers[created.first?.id ?? UUID()] == nil,
                    "\(vm.displayNumbers)")

            /// confirmed-settle: edit the child so the downgrade must be confirmed.
            /// The confirmation presents as a sheet on the key window (NSAlert presenter), so
            /// one is supplied, and made key BEFORE the request, then waited for: late in a
            /// long run, focus can take a moment to arrive. It is answered through the alert's
            /// own completion handler.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if let reason = await keyWindowUnavailable(window) {
                r.skip("confirmed-settle/window-key", reason)
            } else {
                let child = vm.model(created[0].id)!
                child.notes = "edited"
                vm.requestIndependenceChange(on: parent, to: ReleaseIndependence.multiPack)
                r.check("confirmed-settle/not-written-before-confirm",
                        parent.independence == ReleaseIndependence.comboPack, parent.independence)
                for _ in 0..<40 where !vm.isConfirmationPresented || window.attachedSheet == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                r.check("confirmed-settle/prompt-presented", vm.isConfirmationPresented,
                        "attached sheet: \(window.attachedSheet != nil)")
                if let alertSheet = window.attachedSheet {
                    /// First button == the confirm button ("Change and Remove").
                    window.endSheet(alertSheet, returnCode: .alertFirstButtonReturn)
                } else if vm.isConfirmationPresented {
                    vm.confirmation.isPresented = false
                    vm.confirmation.resolve(confirmed: true)
                }
                r.check("confirmed-settle/answered-synchronously", !vm.isConfirmationPresented, "")
                let after = vm.buildReleaseDeltas()      /// same turn as the confirmation
                r.check("confirmed-settle/written-by-save",
                        parent.independence == ReleaseIndependence.multiPack && parent.discMultiPack,
                        parent.independence)
                r.check("confirmed-settle/child-removed-by-save",
                        parent.childReleaseIDs.isEmpty && vm.releases.map(\.id) == [p]
                            && after.create.isEmpty,
                        "\(vm.releases.count) releases, create \(after.create.count)")
                try? await Task.sleep(for: .milliseconds(300))
                r.check("confirmed-settle/deferred-write-inert",
                        parent.independence == ReleaseIndependence.multiPack && vm.releases.count == 1, "")
            }
            window.close()
        }

        /// --- orphan-children (3b) ----------------------------------------------------------
        do {
            let vm = FilmSheet(coordinator: coordinator, filmID: fOrphan.id).releasesTab!
            let parent = vm.model(q)!
            r.check("orphan-children/merged-at-load",
                    parent.childReleaseIDs == [c] && vm.carouselEntries.count == 1, "")
            vm.requestIndependenceChange(on: parent, to: ReleaseIndependence.multiPack)
            let deltas = vm.buildReleaseDeltas()
            r.check("orphan-children/child-removed", deltas.delete == [c] && parent.childReleaseIDs.isEmpty,
                    "delete \(deltas.delete)")
        }

        /// --- load-repairs ----------------------------------------------------------------
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fRepair.id)
            let vm = sheet.releasesTab!
            try? await Task.sleep(for: .milliseconds(250))
            r.check("load-repairs/opens-clean", !vm.hasChanges, "")
            let updated = Set(vm.buildReleaseDeltas().update.map(\.id))
            r.check("load-repairs/case-d-persisted", updated.contains(rep)
                        && vm.model(rep)?.independence == ReleaseIndependence.comboPack, "")
            r.check("load-repairs/case-c-persisted", updated.contains(inverted)
                        && vm.model(inverted)?.baseReleaseYear == 2009, "")
            r.check("load-repairs/clean-release-untouched", !updated.contains(clean), "\(updated)")
        }

        await coordinator.deleteFilms(withIDs: Set(fixtures.map(\.id))) {}
        return r
    }
}

// MARK: - filmsheet-save
///
/// FilmSheet save-path and load-path invariants that need no view:
///
///   • disc-total        — a save landing mid-fly-up of a purchased release's delete stores
///                         a disc total that excludes it (FilmSheet.confirm settles the
///                         Releases tab before assembling the film).
///   • frame-rate        — an out-of-vocabulary stored frame rate survives the Metadata
///                         tab's load unchanged; a near-miss snaps to its option.
///   • release-year      — the Details tab's derived release year agrees with the year the
///                         saved release date string carries.
///   • frames-pad        — a padded half of a frames row repeats the other half's flags.
///   • duration          — a stored runtime with seconds survives a save that did not
///                         edit it; editing the minutes writes the picker's value.
///   • list-settle       — a list commit still held for its popover's close animation
///                         lands in a save that starts inside the hold, exactly once; one
///                         that stopped at its duplicate prompt blocks the save instead;
///                         and an unsettled commit still runs on its own timer.
extension DebugHarness {

    static func filmSheetSaveScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "filmsheet-save")
        let bd = ReleaseFormat.bluRay.rawValue

        /// --- fixtures -------------------------------------------------------------------
        let a = UUID(), b = UUID()
        let fDiscs = makeSnapshot(name: "Save Discs", releases: [
            ReleaseSnapshot(id: a, purchased: true, format: bd,
                            independence: ReleaseIndependence.standalone,
                            numberOfDiscs: 2, sortOrder: 0),
            ReleaseSnapshot(id: b, purchased: true, format: bd,
                            independence: ReleaseIndependence.standalone,
                            numberOfDiscs: 3, sortOrder: 1)])
        var fOddRate = makeSnapshot(name: "Save Rate Odd")
        fOddRate.frameRate = 119.88
        var fNearRate = makeSnapshot(name: "Save Rate Near")
        fNearRate.frameRate = 23.976
        let fDate = makeSnapshot(name: "Save Release Date", releaseDate: "2026-03-04T12:00:00Z")

        /// 1:26:46.785 and 1:59:59.000 — seconds the whole-minute pickers cannot show.
        var fDuration = makeSnapshot(name: "Save Duration Precise")
        fDuration.duration = "5206785"
        fDuration.edited = true
        fDuration.editedDuration = "7199000"

        let fSettle = makeSnapshot(name: "Save List Settle")
        let fPrompt = makeSnapshot(name: "Save List Prompt")

        let fixtures = [fDiscs, fOddRate, fNearRate, fDate, fDuration, fSettle, fPrompt]
        coordinator.importFilms(fixtures)

        /// --- disc-total -----------------------------------------------------------------
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fDiscs.id)
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            sheet.releasesTab.deleteRelease(id: a)
            r.check("disc-total/fly-up-in-progress", sheet.releasesTab.dismissingCardID == a,
                    "dismissing \(String(describing: sheet.releasesTab.dismissingCardID))")
            sheet.confirm()
            for _ in 0..<100 where !dismissed && !sheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let saved = coordinator.getFilm(fDiscs.id)
            r.check("disc-total/saved", dismissed, "save error: \(sheet.saveErrorDetail ?? "none")")
            r.check("disc-total/release-deleted", saved?.releases.map(\.id) == [b],
                    "\(saved?.releases.map(\.id) ?? [])")
            r.check("disc-total/excludes-deleted-release", saved?.numberOfDiscs == "3",
                    "numberOfDiscs \(saved?.numberOfDiscs ?? "nil")")
        }

        /// --- frame-rate -----------------------------------------------------------------
        do {
            let odd = FilmSheet(coordinator: coordinator, filmID: fOddRate.id).metadataTab!
            r.check("frame-rate/out-of-vocabulary-kept", odd.frameRate == 119.88,
                    "loaded \(odd.frameRate)")
            r.check("frame-rate/out-of-vocabulary-collected", odd.collectFilmFields().frameRate == 119.88,
                    "collected \(odd.collectFilmFields().frameRate)")
            r.check("frame-rate/opens-clean", !odd.hasChanges, "")
            let near = FilmSheet(coordinator: coordinator, filmID: fNearRate.id).metadataTab!
            r.check("frame-rate/near-miss-snaps", near.frameRate == 23.98, "loaded \(near.frameRate)")
            r.check("frame-rate/zero-stays-zero", FSTabMetadata.normalizeFrameRate(0) == 0, "")
        }

        /// --- release-year ---------------------------------------------------------------
        do {
            let details = FilmSheet(coordinator: coordinator, filmID: fDate.id).detailsTab!
            let fields = details.collectFilmFields()
            r.check("release-year/derived", details.releaseYear == 2026, "releaseYear \(details.releaseYear)")
            r.check("release-year/matches-saved-date",
                    fields.releaseYear == String(fields.releaseDate.prefix(4)),
                    "releaseYear \(fields.releaseYear) vs releaseDate \(fields.releaseDate)")
        }

        /// --- duration -------------------------------------------------------------------
        do {
            let sheet = FilmSheet(coordinator: coordinator, filmID: fDuration.id)
            let details = sheet.detailsTab!
            r.check("duration/opens-clean", !details.hasChanges, "")
            r.check("duration/collected-untouched",
                    details.collectFilmFields().duration == "5206785"
                        && details.collectFilmFields().editedDuration == "7199000",
                    "\(details.collectFilmFields().duration) / \(details.collectFilmFields().editedDuration)")
            details.durationMinutes += 1
            r.check("duration/edit-writes-picker-value", details.collectFilmFields().duration == "5220000",
                    details.collectFilmFields().duration)
            details.durationMinutes -= 1
            r.check("duration/revert-restores-stored", details.collectFilmFields().duration == "5206785"
                        && !details.hasChanges, details.collectFilmFields().duration)

            /// A real save of an unrelated edit must not touch either runtime.
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            details.userRating = 4
            sheet.confirm()
            for _ in 0..<100 where !dismissed && !sheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let saved = coordinator.getFilm(fDuration.id)
            r.check("duration/unrelated-save-keeps-seconds",
                    dismissed && saved?.userRating == 4 && saved?.duration == "5206785"
                        && saved?.editedDuration == "7199000",
                    "saved \(dismissed), rating \(saved?.userRating ?? -1), duration \(saved?.duration ?? "nil"), edited \(saved?.editedDuration ?? "nil")")
        }

        /// --- list-settle ----------------------------------------------------------------
        ///
        /// The commits below are what the three tables hand `ListPopoverDismissal`: a write
        /// through the tab's view model, held for the popover's close animation (220 ms).
        do {
            /// No leftovers from anything earlier in the run.
            ListPopoverDismissal.settlePending()

            /// Timer path: a commit nobody settles runs by itself, once.
            var timerRuns = 0
            ListPopoverDismissal.afterClose { timerRuns += 1 }
            r.check("list-settle/held-until-close", timerRuns == 0 && ListPopoverDismissal.pendingCount == 1,
                    "runs \(timerRuns), pending \(ListPopoverDismissal.pendingCount)")
            for _ in 0..<50 where timerRuns == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(100))
            r.check("list-settle/timer-runs-once", timerRuns == 1 && ListPopoverDismissal.pendingCount == 0,
                    "runs \(timerRuns), pending \(ListPopoverDismissal.pendingCount)")

            /// Order: settled in the order scheduled, and a settled commit's timer is inert.
            var order: [Int] = []
            ListPopoverDismissal.afterClose { order.append(1) }
            ListPopoverDismissal.nextTurn { order.append(2) }
            ListPopoverDismissal.afterClose { order.append(3) }
            let promptedOrder = ListPopoverDismissal.settlePending()
            r.check("list-settle/scheduling-order", order == [1, 2, 3] && !promptedOrder, "\(order)")
            try? await Task.sleep(for: .milliseconds(300))
            r.check("list-settle/no-second-run", order == [1, 2, 3], "\(order)")

            /// The race itself: an add still held when the save starts is in the saved film.
            let sheet = FilmSheet(coordinator: coordinator, filmID: fSettle.id)
            let notes = sheet.notesTab!
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            notes.tools = ["Edited"]   /// the sheet's other change, so it is saveable
            ListPopoverDismissal.afterClose { notes.warning.append("Held Warning") }
            sheet.confirm()
            for _ in 0..<100 where !dismissed && !sheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let saved = coordinator.getFilm(fSettle.id)
            r.check("list-settle/held-commit-saved",
                    dismissed && saved?.warning == ["Held Warning"] && saved?.tools == ["Edited"],
                    "saved \(dismissed), warning \(saved?.warning ?? []), tools \(saved?.tools ?? [])")
            try? await Task.sleep(for: .milliseconds(300))
            r.check("list-settle/held-commit-once", notes.warning == ["Held Warning"], "\(notes.warning)")

            /// A commit parked behind its duplicate prompt: nothing to save yet, so no save.
            let promptSheet = FilmSheet(coordinator: coordinator, filmID: fPrompt.id)
            var promptDismissed = false
            promptSheet.dismissHandler = { promptDismissed = true }
            promptSheet.notesTab.tools = ["Edited"]
            ListPopoverDismissal.afterClose { ListPopoverDismissal.noteDeferredPrompt() }
            promptSheet.confirm()
            try? await Task.sleep(for: .milliseconds(400))
            r.check("list-settle/prompt-blocks-save",
                    !promptDismissed && coordinator.getFilm(fPrompt.id)?.tools == [],
                    "dismissed \(promptDismissed), tools \(coordinator.getFilm(fPrompt.id)?.tools ?? [])")
            /// Once the prompt is answered the next save goes through.
            promptSheet.confirm()
            for _ in 0..<100 where !promptDismissed && !promptSheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            r.check("list-settle/save-after-prompt", promptDismissed
                        && coordinator.getFilm(fPrompt.id)?.tools == ["Edited"],
                    "dismissed \(promptDismissed)")
            r.check("list-settle/nothing-left-pending", ListPopoverDismissal.pendingCount == 0,
                    "\(ListPopoverDismissal.pendingCount)")
        }

        /// --- frames-pad -----------------------------------------------------------------
        do {
            let flagged = PairedFramesRecord.make("00:01:00", mark: .asterisk, fadeIn: .scurve, fadeOut: .linear)
            let plain = PairedFramesRecord.make("00:02:00", mark: .none, fadeIn: .none, fadeOut: .none)
            let first = PairedFramesRecord.make("100", mark: .none, fadeIn: .none, fadeOut: .none)
            let padded = ReorderableFramesList.padded([first], to: 4, flagsFrom: [plain, flagged, plain])
            let dash = PairedFramesRecord.missingText
            r.check("frames-pad/length", padded.count == 4, "\(padded.count)")
            r.check("frames-pad/existing-untouched", padded.first == first, "")
            r.check("frames-pad/inherits-row-flags",
                    padded[1] == PairedFramesRecord.make(dash, mark: .asterisk, fadeIn: .scurve, fadeOut: .linear),
                    padded[1])
            r.check("frames-pad/plain-when-unannotated", padded[2] == "\(dash), no, none, none", padded[2])
            r.check("frames-pad/plain-past-counterpart", padded[3] == "\(dash), no, none, none", padded[3])
            r.check("frames-pad/no-op-when-long-enough",
                    ReorderableFramesList.padded([first], to: 1, flagsFrom: []) == [first], "")
        }

        /// Let the save's background persist land before the fixtures are removed.
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: Set(fixtures.map(\.id))) {}
        return r
    }
}

// MARK: - return-key-policy
///
/// The FilmSheet's Return rule, driven with genuine key events through NSApp against the real
/// FilmSheetView in a key window: an active text field takes Return first — the first press
/// finishes editing and saves nothing — and the next press, with no field active, saves.
/// Needs an unlocked screen (a key window); see the harness-needs-unlocked-screen note.
///
/// KeyboardManager's intercept needs a presented sheet and is not exercised; the save on the
/// second press here comes from the sheet's default-action button, which applies the same
/// canConfirm test.
extension DebugHarness {

    static func returnKeyPolicyScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "return-key-policy")
        let film = makeSnapshot(name: "Return Policy", releaseDate: "2020-01-01T12:00:00Z")
        coordinator.importFilms([film])

        func allViews(_ root: NSView) -> [NSView] {
            var out: [NSView] = []; var stack = [root]
            while let v = stack.popLast() { out.append(v); stack.append(contentsOf: v.subviews) }
            return out
        }

        func sendReturn(to window: NSWindow) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
                NSApp.sendEvent(e)
            }
        }

        /// One case: fresh sheet and window, an edit so Update is enabled, focus placed by
        /// `focus`, then Return twice.
        func run(_ label: String, focus: (NSWindow, NSView) -> NSView?) async {
            let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
            var saved = false
            sheet.dismissHandler = { saved = true }
            let size = Preferences.sheetSize
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size, height: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: FilmSheetView(owner: sheet))
            host.frame = NSRect(x: 0, y: 0, width: size, height: size)
            window.contentView = host
            if let reason = await keyWindowUnavailable(window) {
                r.skip("\(label)/window-key", reason); window.orderOut(nil); return
            }
            for _ in 0..<6 { await oneRunLoopTurn() }
            try? await Task.sleep(for: .milliseconds(250))   /// deferred Synopsis wave
            host.layoutSubtreeIfNeeded()

            sheet.detailsTab.userRating = sheet.detailsTab.userRating == 5 ? 6 : 5
            try? await Task.sleep(for: .milliseconds(100))
            let target = focus(window, host)
            try? await Task.sleep(for: .milliseconds(100))
            r.check("\(label)/window-key", window.isKeyWindow, "lost key status while settling")
            r.check("\(label)/field-focused", target != nil && window.firstResponder is NSTextView,
                    "responder \(String(describing: window.firstResponder.map { type(of: $0) }))")

            sendReturn(to: window)
            try? await Task.sleep(for: .milliseconds(300))
            r.check("\(label)/first-return-does-not-save", !saved && !sheet.isConfirming, "")
            r.check("\(label)/first-return-ends-editing", !(window.firstResponder is NSTextView),
                    "responder \(String(describing: window.firstResponder.map { type(of: $0) }))")

            sendReturn(to: window)
            try? await Task.sleep(for: .milliseconds(400))
            r.check("\(label)/second-return-saves", saved || sheet.isConfirming, "")

            window.orderOut(nil)
            window.close()
        }

        await run("single-line") { window, host in
            guard let f = allViews(host).compactMap({ $0 as? NSTextField })
                .first(where: { $0.placeholderString == "Film Title" }) else { return nil }
            window.makeFirstResponder(f); return f
        }
        await run("multi-line") { window, host in
            guard let t = allViews(host).first(where: {
                String(describing: type(of: $0)).contains("InnerTextView") }) else { return nil }
            window.makeFirstResponder(t); return t
        }

        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [film.id]) {}
        return r
    }
}


// MARK: - queue-add-confirm, tab-cycle, report-gutter-deselect, jump-menu-width
///
/// queue-add-confirm: the "Add to Queue" menus' single entry point (FilmQueueAssignment.toggle)
/// honors Preferences.confirmFilmQueueAdd — a flagged film raises the alert in the real main
/// window instead of being added, "Add Anyway" adds it, and an unflagged film or a disabled
/// preference adds straight through.
/// tab-cycle: Cmd+Down/Up posted through the event queue (so KeyboardManager's local monitor
/// sees them) steps a view's own tabs (Recents, Unwatched, the six-variant Filtered Library),
/// wraps, and passes through while a text field is editing; the FilmSheet cycle command steps
/// and wraps.
/// report-gutter-deselect: a click in a InsightsTable's inset margin clears the selection.
/// jump-menu-width (opt-in, not in `all`): the Releases jump menu keeps one width with and
/// without the cart glyph. The width checks need a purchased row, so the precondition check
/// fails when the run has none.
/// All four need an unlocked screen (a key window).
extension DebugHarness {

    private static func harnessViews(_ root: NSView) -> [NSView] {
        var out: [NSView] = []; var stack = [root]
        while let v = stack.popLast() { out.append(v); stack.append(contentsOf: v.subviews) }
        return out
    }

    private static func mainHarnessWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) && !$0.isSheet }
    }

    static func queueAddConfirmScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "queue-add-confirm")
        var flagged = makeSnapshot(name: "Queue Confirm Flagged")
        flagged.specialSorting = ["Ignore"]
        let plain = makeSnapshot(name: "Queue Confirm Plain")
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        /// Each case adds one film to "Up Next", which a real-library copy often has full.
        let room = await makeRoom(coordinator, upNext: 1)
        coordinator.importFilms([flagged, plain])
        try? await Task.sleep(for: .milliseconds(500))
        let saved = Preferences.confirmFilmQueueAdd
        defer { Preferences.confirmFilmQueueAdd = saved }

        var received: [(Set<UUID>, UUID)] = []
        let sub = AppEventBus.shared.alertCommands.sink { command in
            if case .confirmFilmQueueAddFromMenu(let ids, let listID) = command { received.append((ids, listID)) }
        }
        defer { sub.cancel() }
        func inQueue(_ id: UUID) -> Bool { !coordinator.filmQueueListIDs(forFilm: id).isEmpty }
        let section = FilmQueueSection.upNext

        /// Flagged film, preference on: deferred to the alert, nothing added yet.
        Preferences.confirmFilmQueueAdd = true
        FilmQueueAssignment.toggle([flagged.id], section: section, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(900))
        r.check("flagged/alert-event", received.count == 1 && received.first?.0 == [flagged.id]
                && received.first?.1 == section.listID, "\(received.count) event(s)")
        r.check("flagged/not-added-yet", !inQueue(flagged.id), "")
        let sheet = window.attachedSheet
        r.check("flagged/alert-presented", sheet != nil, "no sheet on the main window")
        let addAnyway = sheet.flatMap { s in
            harnessViews(s.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Add Anyway" }
        }
        r.check("flagged/add-anyway-button", addAnyway != nil, "")
        addAnyway?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(700))
        r.check("flagged/added-after-confirm", coordinator.filmQueueListIDs(forFilm: flagged.id) == [section.listID], "")
        r.check("flagged/alert-dismissed", window.attachedSheet == nil, "")
        FilmManager.removeFromFilmQueue([flagged.id], coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(300))

        /// Unflagged film, preference on: straight through.
        received.removeAll()
        FilmQueueAssignment.toggle([plain.id], section: section, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(900))
        r.check("plain/no-alert", received.isEmpty && window.attachedSheet == nil, "")
        r.check("plain/added", inQueue(plain.id), "")
        FilmManager.removeFromFilmQueue([plain.id], coordinator: coordinator)

        /// Flagged film, preference off: straight through.
        Preferences.confirmFilmQueueAdd = false
        received.removeAll()
        FilmQueueAssignment.toggle([flagged.id], section: section, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(900))
        r.check("pref-off/no-alert", received.isEmpty && window.attachedSheet == nil, "")
        r.check("pref-off/added", inQueue(flagged.id), "")
        FilmManager.removeFromFilmQueue([flagged.id], coordinator: coordinator)

        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [flagged.id, plain.id]) {}
        await restoreRoom(room, coordinator: coordinator)
        return r
    }

    /// alert-host: AlertHostView in the real main window. Any of its alerts raises
    /// AppState.isHostAlertActive (the MenuBar lock), "Library Could Not Be Read" included;
    /// a confirmed removal clears the selection only when its sender asked; the Queue alert
    /// uses the FilmSheet's title and wording, tags in canonical order; a drop arriving under
    /// an open Queue alert cannot retarget it; a backup-open under another alert is dropped.
    static func alertHostScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "alert-host")
        var flagged = makeSnapshot(name: "Alert Host Flagged")
        flagged.specialSorting = [FilmSpecialSorting.canonicalOrder[1], FilmSpecialSorting.canonicalOrder[0]]
        let a = makeSnapshot(name: "Alert Host A")
        let b = makeSnapshot(name: "Alert Host B")
        coordinator.importFilms([flagged, a, b])
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        try? await Task.sleep(for: .milliseconds(300))
        let selection = SelectionState.shared
        let listID = coordinator.createList(name: "Alert Host List", displayOrder: 9_999)

        func button(_ title: String) -> NSButton? {
            window.attachedSheet.flatMap { s in
                harnessViews(s.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }
            }
        }
        func texts() -> [String] {
            window.attachedSheet.map { s in
                harnessViews(s.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            } ?? []
        }
        func settle(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }

        r.check("idle/flag-clear", !appState.isHostAlertActive, "")

        /// Confirmed removal, sender asked NOT to clear (MenuBar / Opt+Delete).
        for (clearing, tag) in [(false, "keep"), (true, "clear")] {
            coordinator.addFilmsToList(filmIDs: [a.id], listID: listID)
            selection.selectImmediate([a.id])
            AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: clearing))
            await settle()
            r.check("\(tag)/presented", window.attachedSheet != nil, "")
            r.check("\(tag)/menu-locked", appState.isHostAlertActive, "")
            button("Remove")?.performClick(nil)
            await settle(900)
            r.check("\(tag)/removed", !coordinator.getListIDs(forFilm: a.id).contains(listID), "")
            r.check("\(tag)/selection", selection.selectedFilmIDs == (clearing ? [] : [a.id]),
                    "\(selection.selectedFilmIDs.count) selected")
            r.check("\(tag)/menu-unlocked", !appState.isHostAlertActive && window.attachedSheet == nil, "")
        }

        /// Library read failure locks the menu too; Continue Anyway releases it.
        AppEventBus.shared.sendAlert(.showLibraryReadFailure)
        await settle()
        r.check("read-failure/menu-locked", appState.isHostAlertActive && window.attachedSheet != nil, "")
        /// A backup-open arriving under it is dropped rather than queued behind it.
        AppEventBus.shared.sendAlert(.showBackupRestoreAlert(type: "restore",
                                                            file: URL(fileURLWithPath: "/tmp/none.ftbackup")))
        await settle(300)
        button("Continue Anyway")?.performClick(nil)
        await settle(1_200)
        r.check("read-failure/released", !appState.isHostAlertActive, "")
        r.check("backup-open/not-queued", window.attachedSheet == nil, "a sheet surfaced after dismissal")

        /// Queue alert: FilmSheet title and wording, canonical tag order; a drop under it is ignored.
        let saved = Preferences.confirmFilmQueueAdd
        defer { Preferences.confirmFilmQueueAdd = saved }
        Preferences.confirmFilmQueueAdd = true
        let section = FilmQueueSection.upNext
        FilmQueueAssignment.toggle([flagged.id], section: section, coordinator: coordinator)
        await settle(900)
        let shown = texts()
        let tags = FilmSpecialSorting.canonicalOrder.prefix(2).map { "\"\($0)\"" }.joined(separator: ", ")
        let expected = "This film is flagged with the special sorting parameters \(tags)."
        r.check("queue/title", shown.contains("Add to Queue?"), shown.joined(separator: " | "))
        r.check("queue/message", shown.contains(expected), shown.joined(separator: " | "))
        AppEventBus.shared.sendAlert(.confirmFilmQueueAddOnDrop(filmIDs: [b.id], listID: section.listID))
        await settle(300)
        button("Add Anyway")?.performClick(nil)
        await settle(900)
        r.check("queue/added-original", !coordinator.filmQueueListIDs(forFilm: flagged.id).isEmpty, "")
        r.check("queue/drop-did-not-retarget", coordinator.filmQueueListIDs(forFilm: b.id).isEmpty, "")
        r.check("queue/menu-unlocked", !appState.isHostAlertActive, "")

        FilmManager.removeFromFilmQueue([flagged.id, b.id], coordinator: coordinator)
        _ = ListManager.deleteList(listID, coordinator: coordinator)
        selection.clearImmediate()
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [flagged.id, a.id, b.id]) {}
        return r
    }

    /// alert-collision: requests that arrive while an AlertHostView alert is open. Each waits
    /// its turn in arrival order and acts on its OWN payload. A second request must neither
    /// retarget the open alert nor lose itself, so each alert carries its own payload rather
    /// than sharing fields. The menu stays locked across the hand-off between them, and a burst
    /// of one notice is a single alert carrying the latest detail.
    static func alertCollisionScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "alert-collision")
        let a = makeSnapshot(name: "Collision A")
        let b = makeSnapshot(name: "Collision B")
        coordinator.importFilms([a, b])
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        let listL = coordinator.createList(name: "Collision L", displayOrder: 9_998)
        let listM = coordinator.createList(name: "Collision M", displayOrder: 9_999)

        func settle(_ ms: Int = 800) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func texts() -> [String] {
            window.attachedSheet.map { s in
                harnessViews(s.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            } ?? []
        }
        func showing(_ title: String) -> Bool { texts().contains(title) }
        func click(_ title: String) {
            window.attachedSheet.flatMap { s in
                harnessViews(s.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }
            }?.performClick(nil)
        }
        func lists(_ id: UUID) -> Set<UUID> { coordinator.getListIDs(forFilm: id).intersection([listL, listM]) }
        func reset() {
            for id in [a.id, b.id] {
                for l in [listL, listM] where coordinator.getList(l) != nil && !lists(id).contains(l) {
                    coordinator.addFilmsToList(filmIDs: [id], listID: l)
                }
            }
        }
        /// Answers whatever is left, so one case cannot leak an alert into the next.
        func clearAll() async {
            for _ in 0..<5 where window.attachedSheet != nil {
                for t in ["Cancel", "OK", "Continue Anyway"] { click(t) }
                await settle(900)
            }
        }

        /// 1. A background error under a confirmation waits; the confirmation acts first.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "collision fault"))
        await settle()
        r.check("error-under-confirm/confirm-stays", showing("Remove from All Lists?"), texts().joined(separator: " | "))
        click("Remove")
        await settle(150)
        r.check("error-under-confirm/menu-locked-across-hand-off", appState.isHostAlertActive, "")
        await settle(1_100)
        r.check("error-under-confirm/error-follows", showing("Database Write Failed"), texts().joined(separator: " | "))
        r.check("error-under-confirm/confirm-acted", lists(a.id).isEmpty && lists(b.id).count == 2, "")
        click("OK")
        await settle(900)
        r.check("error-under-confirm/all-answered", window.attachedSheet == nil && !appState.isHostAlertActive, "")
        await clearAll()

        /// 2. A different confirmation under a confirmation: both, in order, each on its own films.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.confirmRemoveFromList(filmIDs: [b.id], listID: listL,
                                                            listName: "Collision L", clearingSelection: false))
        await settle()
        r.check("two-kinds/first-shown", showing("Remove from All Lists?"), texts().joined(separator: " | "))
        click("Remove")
        await settle(1_200)
        r.check("two-kinds/second-shown", showing("Remove from List?"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("two-kinds/each-acted", lists(a.id).isEmpty && lists(b.id) == [listM],
                "A in \(lists(a.id).count), B in \(lists(b.id).count)")
        await clearAll()

        /// 3. The same confirmation twice: the open alert keeps its films; the second waits.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [b.id], clearingSelection: false))
        await settle()
        click("Remove")
        await settle(1_200)
        r.check("same-kind/first-acts-on-its-own-films", lists(a.id).isEmpty && lists(b.id).count == 2,
                "A in \(lists(a.id).count), B in \(lists(b.id).count)")
        r.check("same-kind/second-shown", showing("Remove from All Lists?"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("same-kind/second-acts", lists(b.id).isEmpty, "B in \(lists(b.id).count)")
        await clearAll()

        /// 4. "Remove from List" then "Remove List": no shared list context between them.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromList(filmIDs: [a.id], listID: listL,
                                                            listName: "Collision L", clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.confirmRemoveList(listID: listM, listName: "Collision M"))
        await settle()
        click("Remove")
        await settle(1_200)
        r.check("list-context/removal-hits-named-list", lists(a.id) == [listM],
                "A in \(lists(a.id).count) (expected only M)")
        r.check("list-context/second-shown", showing("Remove List?"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("list-context/list-removed", coordinator.getList(listM) == nil, "")
        await clearAll()

        /// 5. A burst of one notice is one alert, carrying the latest detail.
        /// The alert reads the stored switch, not Preferences.loggingEnabled (forced on in a
        /// sandbox); with it off, the detail is in the message.
        let detailShown = !Preferences.store.bool(forKey: Preferences.loggingEnabledKey)
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "first fault"))
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "second fault"))
        await settle()
        let burst = texts().joined(separator: " | ")
        r.check("burst/latest-detail",
                detailShown ? burst.contains("second fault") && !burst.contains("first fault")
                            : burst.contains("Database Write Failed"), burst)
        click("OK")
        await settle(1_200)
        r.check("burst/single-alert", window.attachedSheet == nil && !appState.isHostAlertActive,
                texts().joined(separator: " | "))
        await clearAll()

        /// 6. A later failure while the first is ON SCREEN does not stack a second alert.
        /// The open alert keeps the text it was drawn with, because SwiftUI does not redraw
        /// an open alert.
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "early fault"))
        await settle()
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "later fault"))
        await settle()
        click("OK")
        await settle(1_200)
        r.check("burst/open-alert-single", window.attachedSheet == nil && !appState.isHostAlertActive,
                texts().joined(separator: " | "))
        await clearAll()

        /// 7. A second backup-open while the restore prompt is ON SCREEN retargets it: Open
        /// Settings opens the second file. The Settings sheet this opens is closed again.
        var opened: [URL?] = []
        let sub = AppEventBus.shared.uiCommands.sink { command in
            if case .openSettingsWithBackup(let file) = command { opened.append(file) }
        }
        let first = URL(fileURLWithPath: "/tmp/collision-first.ftbackup")
        let second = URL(fileURLWithPath: "/tmp/collision-second.ftbackup")
        AppEventBus.shared.sendAlert(.showBackupRestoreAlert(type: "restore", file: first))
        await settle()
        AppEventBus.shared.sendAlert(.showBackupRestoreAlert(type: "restore", file: second))
        await settle()
        r.check("backup/prompt-shown", showing("Restore from Backup?"), texts().joined(separator: " | "))
        click("Open Settings")
        await settle(1_200)
        sub.cancel()
        r.check("backup/retargeted", opened == [second], "\(opened.map { $0?.lastPathComponent ?? "nil" })")
        if appState.sheetCoordinator.activeSheet != nil {
            appState.sheetCoordinator.dismissSheet()
            await settle(1_200)
        }
        r.check("backup/settings-closed", appState.sheetCoordinator.activeSheet == nil, "")
        await clearAll()

        for l in [listL, listM] where coordinator.getList(l) != nil { _ = ListManager.deleteList(l, coordinator: coordinator) }
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [a.id, b.id]) {}
        return r
    }

    static func tabCycleScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "tab-cycle")
        let film = makeSnapshot(name: "Tab Cycle")
        coordinator.importFilms([film])
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        try? await Task.sleep(for: .milliseconds(200))

        func postArrow(down: Bool) async {
            let key = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
            let chars = String(Character(UnicodeScalar(key)!))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero,
                                         modifierFlags: [.command, .numericPad, .function],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: down ? 125 : 126)!
                NSApp.postEvent(e, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        let savedItem = appState.selectedSidebarItem

        /// Recents: seven tabs, forward from the first category through the rest and back around to the summary.
        let recents = RecentsState.shared
        appState.navigate(to: .libraryItem(.recents))
        try? await Task.sleep(for: .milliseconds(400))
        recents.selectCategory(.recentlyViewed)
        try? await Task.sleep(for: .milliseconds(200))
        var seen: [RecentsCategory] = []
        for _ in 0..<7 { await postArrow(down: true); seen.append(recents.selectedCategory) }
        r.check("recents/down-steps-and-wraps",
                seen == [.recentlyRotated, .recentlyAdded, .recentlyUpdated, .recentlyPurchased,
                         .recentDiscRelease, .summary, .recentlyViewed],
                seen.map { "\($0)" }.joined(separator: ","))
        await postArrow(down: false)
        r.check("recents/up-wraps", recents.selectedCategory == .summary, "\(recents.selectedCategory)")

        /// Text editing owns Cmd+Up/Down (move to beginning/end of document).
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        window.contentView?.addSubview(field)
        /// Re-keyed first: navigation can leave the window unkeyed, and the text-input test
        /// (like the user's typing) only applies to the key/main window.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(200))
        r.check("recents/field-editing", window.firstResponder is NSTextView && window.isKeyWindow,
                "responder \(String(describing: window.firstResponder.map { type(of: $0) })), key \(window.isKeyWindow)")
        let beforeEditingKey = recents.selectedCategory
        await postArrow(down: true)
        r.check("recents/text-editing-passes-through", recents.selectedCategory == beforeEditingKey,
                "\(beforeEditingKey) → \(recents.selectedCategory)")
        window.makeFirstResponder(nil)
        field.removeFromSuperview()

        /// Unwatched: two tabs.
        let unwatched = UnwatchedState.shared
        appState.navigate(to: .libraryItem(.unwatched))
        try? await Task.sleep(for: .milliseconds(400))
        unwatched.selectCategory(.unwatched)
        await postArrow(down: true)
        r.check("unwatched/down", unwatched.selectedCategory == .notRated, "\(unwatched.selectedCategory)")
        await postArrow(down: true)
        r.check("unwatched/wraps", unwatched.selectedCategory == .unwatched, "\(unwatched.selectedCategory)")

        /// Filtered Library: six variants, all reachable (Opt+Cmd+# stops at five).
        appState.navigate(to: .smartList(.filteredLibrary))
        try? await Task.sleep(for: .milliseconds(400))
        let family = SmartListType.filteredLibrary.familyVariants
        let variantState = SmartListVariantState.shared(for: .filteredLibrary)
        variantState.select(family[0])
        try? await Task.sleep(for: .milliseconds(200))
        var variants: [SmartListType] = []
        for _ in family { await postArrow(down: true); variants.append(variantState.selected) }
        r.check("smart-list/visits-every-variant-and-wraps",
                variants == Array(family.dropFirst()) + [family[0]] && family.count == 6,
                variants.map(\.rawValue).joined(separator: ","))
        await postArrow(down: false)
        r.check("smart-list/up-wraps-to-last", variantState.selected == family.last, variantState.selected.rawValue)
        variantState.select(family[0])

        /// Opt+Cmd+N selects tab N in every tabbed view — every tab has its own digit.
        func postDigit(_ digit: Int) async {
            let chars = String(digit)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command, .option],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: [18, 19, 20, 21, 23, 22, 26, 28, 25][digit - 1])!
                NSApp.postEvent(e, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        func checkDigits<T: Equatable>(_ label: String, _ item: SidebarItem, _ tabs: [T],
                                       _ current: () -> T) async {
            appState.navigate(to: item)
            try? await Task.sleep(for: .milliseconds(400))
            var got: [String] = []
            var ok = true
            /// Backward, so a tab already selected on arrival cannot pass vacuously.
            for digit in stride(from: tabs.count, through: 1, by: -1) {
                await postDigit(digit)
                let now = current()
                ok = ok && now == tabs[digit - 1]
                got.append("\(digit)→\(now)")
            }
            r.check("opt-cmd-digits/\(label)", ok, got.joined(separator: " "))
        }
        await checkDigits("unwatched", .libraryItem(.unwatched), [UnwatchedCategory.unwatched, .notRated]) {
            UnwatchedState.shared.selectedCategory }
        await checkDigits("recents", .libraryItem(.recents),
                          RecentsCategory.allCases) {
            RecentsState.shared.selectedCategory }
        await checkDigits("reports", .libraryItem(.insights), InsightsCategory.allCases) {
            InsightsState.shared.selectedCategory }
        await checkDigits("imports", .libraryItem(.imports), [ImportsCategory.metadata, .ratings]) {
            ImportsState.shared.selectedCategory }
        await checkDigits("film-queue", .libraryItem(.filmQueue), [FilmQueueFilter.all, .upNext, .soon, .later]) {
            FilmQueueFilterState.shared.selectedFilter }
        var parents: [SmartListType] = []
        for type in SmartListType.allCases where !type.familyVariants.isEmpty {
            let parent = type.familyVariants[0]
            guard !parents.contains(parent) else { continue }
            parents.append(parent)
            let state = SmartListVariantState.shared(for: parent)
            await checkDigits("smart-list/\(parent.rawValue)", .smartList(parent), parent.familyVariants) { state.selected }
            state.select(parent)
        }
        r.check("opt-cmd-digits/no-family-over-nine", parents.allSatisfy { $0.familyVariants.count <= 9 },
                parents.map { "\($0.rawValue):\($0.familyVariants.count)" }.joined(separator: " "))

        appState.navigate(to: savedItem)
        try? await Task.sleep(for: .milliseconds(300))

        /// FilmSheet: the cycle command the sheet branch sends.
        let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
        let size = Preferences.sheetSize
        let sheetWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size, height: size),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        sheetWindow.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FilmSheetView(owner: sheet))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        sheetWindow.contentView = host
        sheetWindow.orderFront(nil)
        for _ in 0..<6 { await oneRunLoopTurn() }
        var visited: [FilmTab] = []
        for _ in FilmTab.allCases {
            AppEventBus.shared.sendCommand(.cycleFilmSheetTab(forward: true))
            try? await Task.sleep(for: .milliseconds(150))
            visited.append(sheet.selectedTab)
        }
        r.check("filmsheet/forward-steps-and-wraps",
                visited == [.metadata, .releases, .notes, .poster, .details], visited.map(\.rawValue).joined(separator: ","))
        AppEventBus.shared.sendCommand(.cycleFilmSheetTab(forward: false))
        try? await Task.sleep(for: .milliseconds(150))
        r.check("filmsheet/backward-wraps", sheet.selectedTab == .poster, sheet.selectedTab.rawValue)
        sheetWindow.orderOut(nil)
        sheetWindow.close()

        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [film.id]) {}
        return r
    }

    private struct GutterRow: Identifiable, Equatable { let id = UUID(); let name: String }

    static func reportGutterDeselectScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "report-gutter-deselect")
        final class Box { var selection: Set<UUID> = [] }
        let box = Box()
        let rows = (0..<5).map { GutterRow(name: "Row \($0)") }
        let table = InsightsTable(rows: rows,
                                columns: [InsightsTableColumn(id: "name", title: "Name", width: 200,
                                                            minWidth: 100, maxWidth: 1000,
                                                            content: .text { $0.name })],
                                selection: Binding(get: { box.selection }, set: { box.selection = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: table.frame(width: 500, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = host
        /// Row clicks go through NSTableView's own tracking, which needs the window key.
        if let reason = await keyWindowUnavailable(window) {
            r.skip("window-key", reason); window.close(); return r
        }
        for _ in 0..<6 { await oneRunLoopTurn() }
        host.layoutSubtreeIfNeeded()
        guard let tv = harnessViews(host).compactMap({ $0 as? InsightsNSTableView }).first else {
            r.check("table-found", false, ""); window.close(); return r
        }
        box.selection = [rows[1].id, rows[2].id]
        tv.selectRowIndexes([1, 2], byExtendingSelection: false)
        let rowRect = tv.rect(ofRow: 1)
        let firstColumn = tv.rect(ofColumn: 0)
        r.check("inset-margin-exists", firstColumn.minX > 2, "column minX \(firstColumn.minX)")

        func click(atTable point: NSPoint) {
            let inWindow = tv.convert(point, to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 0)!
            /// Queued first, so NSTableView's own tracking loop (row clicks) finds its mouseUp.
            NSApp.postEvent(up, atStart: false)
            tv.mouseDown(with: down)
        }

        click(atTable: NSPoint(x: 1, y: rowRect.midY))
        await oneRunLoopTurn()
        r.check("left-margin-clears", box.selection.isEmpty && tv.selectedRowIndexes.isEmpty,
                "\(box.selection.count) selected")

        box.selection = [rows[3].id]
        tv.selectRowIndexes([3], byExtendingSelection: false)
        click(atTable: NSPoint(x: tv.bounds.maxX - 1, y: tv.rect(ofRow: 3).midY))
        await oneRunLoopTurn()
        r.check("right-margin-clears", box.selection.isEmpty, "\(box.selection.count) selected")

        click(atTable: NSPoint(x: firstColumn.midX, y: tv.rect(ofRow: 4).midY))
        /// The selection binding is written on a later turn; wait for it rather than a fixed time.
        for _ in 0..<20 where box.selection != [rows[4].id] {
            try? await Task.sleep(for: .milliseconds(50))
        }
        r.check("row-click-still-selects", box.selection == [rows[4].id], "\(box.selection.count) selected")

        window.orderOut(nil)
        window.close()
        return r
    }

    static func jumpMenuWidthScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "jump-menu-width")
        let film = makeSnapshot(name: "Jump Width", releases: [
            ReleaseSnapshot(purchased: false, purchaseDate: ""),
            ReleaseSnapshot(purchased: true, purchaseDate: "2020.01.01"),
            ReleaseSnapshot(purchased: false, purchaseDate: ""),
        ])
        coordinator.importFilms([film])
        let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
        let size = Preferences.sheetSize
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size, height: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FilmSheetView(owner: sheet))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sheet.selectedTab = .releases
        for _ in 0..<6 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        guard let popup = harnessViews(host).compactMap({ $0 as? NSPopUpButton })
            .first(where: { String(describing: type(of: $0)).contains("AppearanceTrackingPopUp") }) else {
            r.check("popup-found", false, ""); window.close(); return r
        }
        var widths: [String] = []
        var distinct = Set<CGFloat>()
        func hasCart(_ index: Int) -> Bool {
            popup.item(at: index)?.attributedTitle?.containsAttachments ?? false
        }
        /// One purchased row and one unpurchased row, whichever indexes the sort put them at,
        /// each visited by waiting for the carousel to actually arrive there.
        /// The rows are rebuilt as the sheet's releases finish loading; wait until the menu
        /// shows all three and has held still for half a second.
        var lastTitles: [String] = [], stableFor = 0
        for _ in 0..<50 where stableFor < 5 {
            try? await Task.sleep(for: .milliseconds(100))
            let titles = popup.itemArray.map { "\($0.title)\($0.attributedTitle?.containsAttachments == true)" }
            stableFor = (titles == lastTitles && titles.count == 3) ? stableFor + 1 : 0
            lastTitles = titles
        }
        let purchased = (0..<popup.numberOfItems).first(where: hasCart)
        let unpurchased = (0..<popup.numberOfItems).first { !hasCart($0) }
        for index in [unpurchased, purchased, unpurchased].compactMap({ $0 }) {
            popup.selectItem(at: index)
            popup.sendAction(popup.action, to: popup.target)
            for _ in 0..<30 where popup.indexOfSelectedItem != index {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let glyph = hasCart(popup.indexOfSelectedItem)
            /// The alignment rect is what SwiftUI sizes; the frame adds the bezel's insets.
            let width = popup.alignmentRect(forFrame: popup.frame).width
            widths.append("\(popup.indexOfSelectedItem)\(glyph ? "+cart" : ""):\(width)")
            distinct.insert(width)
        }
        r.check("visited-a-purchased-row", widths.contains { $0.contains("+cart") }, widths.joined(separator: " "))
        r.check("one-width", distinct.count == 1, widths.joined(separator: " "))
        r.check("width-is-header-width", distinct == [170], widths.joined(separator: " "))
        window.orderOut(nil)
        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [film.id]) {}
        return r
    }
}

// MARK: - FilmSheet Perf
///
/// `filmsheet-perf` (opt-in, a measurement): what the FilmSheet costs to OPEN onto its Details
/// tab, to SWITCH tabs once each tab is built, and what one discrete edit on the Details tab
/// re-evaluates. The sheet is hosted at its real size in a window parked below the screen's
/// bottom edge (ordered in, so SwiftUI and AppKit run their real display-cycle work), on the
/// sandbox library's heaviest film — most releases, then most viewing dates — so a real-data
/// copy gives real weight.
///
/// Every step reports FilmSheetBodyProbe's per-view body counts and AppKitScrollHandoffProbe's
/// hand-offs (each a full re-measure of one scroll tab's hosted tree), plus run-loop busy time.
extension DebugHarness {
    static func filmSheetPerfScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "filmsheet-perf")
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        if !coordinator.hasDatabaseFilms { coordinator.importFilms(reportsCorpus()) }
        guard let film = coordinator.getAllFilms().max(by: {
            ($0.releases.count, $0.calendarTable.count) < ($1.releases.count, $1.calendarTable.count)
        }) else {
            r.check("film", false, "no films")
            return r
        }
        r.check("film", true, "\(film.name): \(Fmt.int(film.releases.count)) releases, \(Fmt.int(film.calendarTable.count)) viewing dates")

        let size = Preferences.sheetSize
        func host(_ sheet: FilmSheet) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: 100, y: -size + 20))
            window.alphaValue = 0.1
            let view = NSHostingView(rootView: FilmSheetView(owner: sheet).frame(width: size, height: size))
            view.frame = NSRect(x: 0, y: 0, width: size, height: size)
            window.contentView = view
            window.orderFront(nil)
            return window
        }
        func counts() -> String {
            FilmSheetBodyProbe.counts.sorted { $0.key < $1.key }
                .map { "\($0.key) \(Fmt.int($0.value))" }.joined(separator: ", ")
        }
        func resetProbes() {
            FilmSheetBodyProbe.counts = [:]
            AppKitScrollHandoffProbe.applied = 0
            AppKitScrollHandoffProbe.newRevisions = 0
        }
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }

        /// ── Open ────────────────────────────────────────────────────────────────────────
        /// Tab view models, each built alone against a throwaway sheet, so the open's
        /// synchronous model cost can be attributed.
        do {
            let probe = FilmSheet(coordinator: coordinator, filmID: film.id)
            var tabInit: [String: [Double]] = [:]
            for _ in 0..<20 {
                func time(_ name: String, _ build: () -> AnyObject) {
                    let t0 = CACurrentMediaTime()
                    _ = build()
                    tabInit[name, default: []].append((CACurrentMediaTime() - t0) * 1000)
                }
                time("details")  { FSTabDetails(owner: probe) }
                time("metadata") { FSTabMetadata(owner: probe) }
                time("releases") { FSTabReleases(owner: probe) }
                time("notes")    { FSTabNotes(owner: probe) }
                time("poster")   { FSTabPoster(owner: probe) }
            }
            for (name, values) in tabInit.sorted(by: { $0.key < $1.key }) {
                r.metric("open.init.\(name)-median", stats(values).median, "ms")
            }
            await settle(300)
        }

        /// `-FTDebugFilmSheetOpenLoop`: open and close the sheet onto Details for 15 s, for a
        /// sampler attached from outside, then end the scenario.
        if ProcessInfo.processInfo.arguments.contains("-FTDebugFilmSheetOpenLoop") {
            print("OPEN-LOOP START"); unsafe fflush(stdout)
            let end = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < end {
                let window = host(FilmSheet(coordinator: coordinator, filmID: film.id))
                window.contentView?.layoutSubtreeIfNeeded()
                await settle(250)
                window.orderOut(nil)
                window.contentView = nil
                await settle(50)
            }
            return r
        }

        var initMs: [Double] = [], layoutMs: [Double] = [], busyMs: [Double] = [], longestMs: [Double] = []
        var detailsBodies: [Double] = []
        var openCounts = ""
        let trials = 8
        for trial in 0...trials {
            resetProbes()
            recorder.reset()
            let t0 = CACurrentMediaTime() * 1000
            let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
            let t1 = CACurrentMediaTime() * 1000
            let window = host(sheet)
            window.contentView?.layoutSubtreeIfNeeded()
            let t2 = CACurrentMediaTime() * 1000
            await settle(800)
            let reading = recorder.reading(from: t0, window: 800)
            if trial > 0 {  /// trial 0 warms caches
                initMs.append(t1 - t0)
                layoutMs.append(t2 - t1)
                busyMs.append(reading.busy)
                longestMs.append(reading.longest)
                detailsBodies.append(Double(FilmSheetBodyProbe.counts["details", default: 0]))
                openCounts = "\(counts()); handoffs \(Fmt.int(AppKitScrollHandoffProbe.applied)), revisions \(Fmt.int(AppKitScrollHandoffProbe.newRevisions))"
            }
            window.orderOut(nil)
            window.contentView = nil
            await settle(200)
        }
        r.metric("open.sheet-init-median", stats(initMs).median, "ms")
        r.metric("open.first-layout-median", stats(layoutMs).median, "ms")
        r.metric("open.busy-median", stats(busyMs).median, "ms")
        r.metric("open.longest-stretch-median", stats(longestMs).median, "ms")
        r.metric("open.details-bodies-median", stats(detailsBodies).median, "n")
        r.check("open-counts", true, openCounts)

        /// ── Tab switches, then Details edits, on one sheet ──────────────────────────────
        let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
        let window = host(sheet)
        window.contentView?.layoutSubtreeIfNeeded()
        await settle(1000)
        func measure(_ label: String, settleMs: Int = 700, _ action: () -> Void) async {
            resetProbes()
            recorder.reset()
            let t0 = CACurrentMediaTime() * 1000
            action()
            await settle(settleMs)
            let reading = recorder.reading(from: t0, window: Double(settleMs))
            r.check(label, true, "\(counts()); handoffs \(Fmt.int(AppKitScrollHandoffProbe.applied)), revisions \(Fmt.int(AppKitScrollHandoffProbe.newRevisions)), busy \(Fmt.fixed(reading.busy, 1)) ms, longest \(Fmt.fixed(reading.longest, 1)) ms")
        }
        /// `-FTDebugFilmSheetSwitchLoop`: flip between two built tabs for 15 s, for a sampler
        /// attached from outside, then end the scenario.
        if ProcessInfo.processInfo.arguments.contains("-FTDebugFilmSheetSwitchLoop") {
            for tab in [FilmTab.metadata, .releases, .notes, .poster, .details] {
                sheet.selectedTab = tab
                await settle(400)
            }
            print("SWITCH-LOOP START"); unsafe fflush(stdout)
            let end = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < end {
                sheet.selectedTab = sheet.selectedTab == .details ? .notes : .details
                await settle(120)
            }
            return r
        }
        /// The floor every reading below sits on: a step that changes nothing.
        await measure("idle") { }
        let order: [FilmTab] = [.metadata, .releases, .notes, .poster, .details]
        for pass in 0..<2 {
            for tab in order {
                await measure("switch-\(pass == 0 ? "first" : "again")-\(tab.rawValue.lowercased())") {
                    sheet.selectedTab = tab
                }
            }
        }

        let details = sheet.detailsTab!
        /// The first keystroke dirties the sheet, so it also animates the button bar; the
        /// second is the steady state of typing.
        await measure("edit-name-keystroke", settleMs: 300) { details.name += "x" }
        await measure("edit-name-second-keystroke", settleMs: 300) { details.name += "y" }
        await measure("edit-name-revert", settleMs: 300) { details.name.removeLast(2) }
        await measure("edit-release-date-step", settleMs: 300) {
            details.releaseDate = StorageDateFormatters.calendar.date(byAdding: .day, value: 1, to: details.releaseDate) ?? details.releaseDate
        }
        await measure("edit-edited-toggle", settleMs: 300) { details.edited.toggle() }
        await measure("edit-edited-toggle-back", settleMs: 300) { details.edited.toggle() }
        await measure("edit-hall-of-fame-toggle", settleMs: 300) { details.inHallOfFame.toggle() }
        await measure("edit-hall-of-fame-toggle-back", settleMs: 300) { details.inHallOfFame.toggle() }
        await measure("edit-auto-add-toggle", settleMs: 300) {
            details.autoAddToQueueOnRotation = details.autoAddToQueueOnRotation == nil ? 0 : nil
        }
        await measure("edit-special-sorting-toggle", settleMs: 300) {
            if details.specialSorting.contains(FilmSpecialSorting.blacklisted) {
                details.specialSorting.remove(FilmSpecialSorting.blacklisted)
            } else {
                details.specialSorting.insert(FilmSpecialSorting.blacklisted)
            }
        }
        await measure("edit-lists-refresh", settleMs: 300) { details.refreshAvailableLists() }
        await measure("edit-viewing-date-add", settleMs: 300) { details.calendarTable.append("2001.01.01") }

        sheet.selectedTab = .metadata
        await settle(500)
        let metadata = sheet.metadataTab!
        await measure("edit-metadata-sort-name-keystroke", settleMs: 300) { metadata.sortName += "x" }
        await measure("edit-metadata-color-toggle", settleMs: 300) { metadata.color.toggle() }
        await measure("edit-metadata-cast-add", settleMs: 300) { metadata.cast.append("Probe") }

        sheet.selectedTab = .notes
        await settle(500)
        let notes = sheet.notesTab!
        await measure("edit-notes-release-keystroke", settleMs: 300) { notes.releaseUsed += "x" }
        await measure("edit-notes-description-keystroke", settleMs: 300) { notes.descriptionNotes += "x" }
        await measure("edit-notes-frames-add", settleMs: 300) {
            notes.handbrakeFrames.append("1")
            notes.correspondingTimecodes.append("00:00:01")
        }

        window.orderOut(nil)
        window.contentView = nil
        return r
    }
}

#endif
