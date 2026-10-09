// MARK: - DHCardProfile.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only measurement scenario for the Releases carousel's card: what it costs to MOUNT a
// ReleaseCardView, to RE-POINT a mounted one at a different model in place (the merged combo
// pack's variant swap, and the operation a slot-recycling carousel would perform on every
// step), and to UNMOUNT one. Opt-in (`-FTDebugHarness card-perf`); not part of `all`, because
// its output is a measurement rather than a verdict.
//
// The card is hosted in a real NSHostingView inside an off-screen NSWindow, so every
// AppKit-backed control (NSPopUpButton, NSStepper, NSTextField, NSButton, NSSegmentedControl)
// is genuinely created, constrained and laid out — the census counts them afterward. The
// numbers are wall time around the synchronous layout call plus main-thread CPU across the
// run-loop turn that follows it, which is where SwiftUI and AppKit finish the work the
// synchronous call only started.

#if DEBUG

import AppKit
import Combine
import SwiftUI

extension DebugHarness {

    /// Scenario names owned by this file that `all` runs. `card-perf` is deliberately not
    /// among them: its output is a measurement, not a verdict.
    static var cardScenarios: [String] {
        ["card-focus", "segmented-equivalence", "currency-placeholder", "releases-settle",
         "filmsheet-save", "return-key-policy", "queue-add-confirm", "alert-host", "alert-collision", "tab-cycle",
         "report-gutter-deselect", "placeholder-anchor", "import-details-segments",
         "sidebar-disclosure"]
    }

    static func runCardProfileScenario(_ scenario: String,
                                       coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "card-perf":  return await cardProfileScenario(coordinator: coordinator)
        case "card-focus": return await cardFocusScenario(coordinator: coordinator)
        case "segmented-equivalence": return await segmentedEquivalenceScenario()
        case "currency-placeholder": return await currencyPlaceholderScenario(coordinator: coordinator)
        case "picker-dismissal": return await pickerDismissalScenario(coordinator: coordinator)
        case "reports-tab-perf": return await reportsTabPerfScenario(coordinator: coordinator)
        case "reports-hitch": return await reportsHitchScenario(coordinator: coordinator)
        case "sheet-hitch": return await sheetHitchScenario(coordinator: coordinator)
        case "reports-frames": return await reportsFramesScenario(coordinator: coordinator)
        case "reports-loop": return await reportsLoopScenario(coordinator: coordinator)
        case "dataviz-measure": return await dataVizMeasureScenario(coordinator: coordinator)
        case "dataviz-window": return await dataVizWindowScenario(coordinator: coordinator)
        case "reports-table-behavior": return await reportsTableBehaviorScenario(coordinator: coordinator)
        case "releases-settle": return await releasesSettleScenario(coordinator: coordinator)
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
        default:           return nil
        }
    }

    /// Mirrors the carousel's mounted/unmounted branch exactly: a model renders the real card
    /// behind `.equatable()`, nil renders the inert spacer that stands in for an unmounted one.
    private struct CardSlot: View {
        let model: ReleaseCardModel?
        let displayIndex: Int
        let viewModel: FSTabReleases

        var body: some View {
            if let model {
                ReleaseCardView(model: model,
                                badgeFormat: model.format,
                                displayIndex: displayIndex,
                                onDelete: {},
                                viewModel: viewModel)
                    .equatable()
                    .frame(width: 536)
            } else {
                Color.clear.frame(width: 536, height: 1)
            }
        }
    }

    private static func threadCPUMilliseconds() -> Double {
        var ts = timespec()
        unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    }

    /// Makes `window` key, asking again every 100 ms for up to 3 s. One request can lose:
    /// activation is cooperative, and mid-suite another scenario's window may still be
    /// settling. Asked once, the Return-key and tab-cycle checks failed intermittently.
    static func makeKey(_ window: NSWindow) async -> Bool {
        for _ in 0..<30 where !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return window.isKeyWindow
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
        // Every fourth card names a studio outside the vocabulary, which routes the studio
        // row to "Other" and puts its free-text field in the tree.
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

    private static func cardProfileScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "card-perf")

        // An add-mode sheet: no film needed, and its Releases view model is what the card
        // requires for wishlist and combo-pack callbacks (none of which fire here).
        let sheet = FilmSheet(coordinator: coordinator)
        guard let vm = sheet.releasesTab else {
            r.check("view-model", false, "FilmSheet has no releases tab")
            return r
        }

        let formats: [ReleaseFormat] = [.uhd4K, .bluRay, .dvd]
        let models: [ReleaseCardModel] = (0..<12).map { i in
            makeModel(format: formats[i % 3], purchased: i % 2 == 0, sortOrder: i)
        }
        vm.releases = models

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        window.contentView = container
        // `-FTDebugCardPerfVisible` orders the window in (parked below the screen's bottom
        // edge, at 10% alpha) so the numbers can be compared against an off-screen window.
        if ProcessInfo.processInfo.arguments.contains("-FTDebugCardPerfVisible") {
            window.setFrameOrigin(NSPoint(x: 100, y: -880))
            window.alphaValue = 0.1
            window.orderFront(nil)
            for _ in 0..<5 { await oneRunLoopTurn() }
            log("card-perf: window ordered in at \(window.frame), onScreen=\(window.isOnActiveSpace)")
        }

        // Ordered on screen? No — but the window has to exist for AppKit to install the
        // platform views, and layoutSubtreeIfNeeded runs the hosting view's update pass.
        typealias Host = NSHostingView<CardSlot>

        var mount: [Sample] = [], swap: [Sample] = [], swapSameFormat: [Sample] = []
        var unmount: [Sample] = [], remount: [Sample] = []
        var viewCount = 0, focusableCount = 0
        let trials = 14
        let warmup = 3

        for trial in 0..<trials {
            let a = models[trial % models.count]
            // A model of a DIFFERENT format and purchase state: the branchiest swap.
            let b = models[(trial + 1) % models.count]
            // Same format, same purchase state: the in-place update with nothing structural.
            let c = models[(trial + 6) % models.count]

            let host = Host(rootView: CardSlot(model: nil, displayIndex: 1, viewModel: vm))
            host.frame = NSRect(x: 50, y: 50, width: 536, height: 800)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            await oneRunLoopTurn()

            let m = await measure {
                host.rootView = CardSlot(model: a, displayIndex: 1, viewModel: vm)
                host.layoutSubtreeIfNeeded()
            }
            if trial == warmup {
                (viewCount, focusableCount) = census(host)
                // Card heights for every format × purchased state, the geometry that has to
                // survive any change to the card's controls.
                for m in models.prefix(6) {
                    host.rootView = CardSlot(model: m, displayIndex: 1, viewModel: vm)
                    host.layoutSubtreeIfNeeded()
                    await oneRunLoopTurn()
                    let h = host.fittingSize.height
                    r.metric("card.height.\(m.format).\(m.purchased ? "purchased" : "unpurchased")", h, "pt")
                    unsafe log(String(format: "card fitting height %.2f pt (%@, purchased %d)", h, m.format, m.purchased ? 1 : 0))
                }
                // Every AppKit control's frame in host coordinates, for a before/after diff of
                // the card's geometry (`-FTDebugCardPerfFrames` prints it).
                if ProcessInfo.processInfo.arguments.contains("-FTDebugCardPerfFrames") {
                    for m in models.prefix(2) {
                        host.rootView = CardSlot(model: m, displayIndex: 1, viewModel: vm)
                        host.layoutSubtreeIfNeeded()
                        await oneRunLoopTurn()
                        var stack: [NSView] = [host]
                        var lines: [String] = []
                        while let v = stack.popLast() {
                            if v is NSControl {
                                let f = host.convert(v.bounds, from: v)
                                unsafe lines.append(String(format: "%@ %.1f,%.1f %.1fx%.1f", String(describing: type(of: v)).replacingOccurrences(of: "SwiftUI", with: ""), f.origin.x, f.origin.y, f.width, f.height))
                            }
                            stack.append(contentsOf: v.subviews)
                        }
                        log("FRAMES \(m.format)/\(m.purchased): " + lines.sorted().joined(separator: " | "))
                    }
                }
                host.rootView = CardSlot(model: a, displayIndex: 1, viewModel: vm)
                host.layoutSubtreeIfNeeded()
                await oneRunLoopTurn()
            }

            let s = await measure {
                host.rootView = CardSlot(model: b, displayIndex: 1, viewModel: vm)
                host.layoutSubtreeIfNeeded()
            }
            let s2 = await measure {
                host.rootView = CardSlot(model: c, displayIndex: 1, viewModel: vm)
                host.layoutSubtreeIfNeeded()
            }
            let u = await measure {
                host.rootView = CardSlot(model: nil, displayIndex: 1, viewModel: vm)
                host.layoutSubtreeIfNeeded()
            }
            // Mount again into the same slot, as a navigation step does after an unmount.
            let rm = await measure {
                host.rootView = CardSlot(model: a, displayIndex: 2, viewModel: vm)
                host.layoutSubtreeIfNeeded()
            }
            host.removeFromSuperview()
            await oneRunLoopTurn()

            if trial >= warmup {
                mount.append(m); swap.append(s); swapSameFormat.append(s2)
                unmount.append(u); remount.append(rm)
            }
        }

        func report(_ name: String, _ samples: [Sample], into r: inout HarnessScenarioResult) {
            let t = stats(samples.map(\.total))
            let w = stats(samples.map(\.layoutWall))
            r.metric("\(name).total.median", t.median, "ms")
            r.metric("\(name).total.max", t.max, "ms")
            r.metric("\(name).layout.median", w.median, "ms")
            unsafe log(String(format: "%@: total median %.2f ms (max %.2f) | sync layout median %.2f ms",
                       name, t.median, t.max, w.median))
        }
        // MARK: Two more card-level probes
        //
        // swap-identical: the root view is reassigned with the SAME model. `.equatable()`
        // declines the body, so what remains is the fixed cost of a hosting-view update.
        // field-write: one property is written on the mounted model, which is the per-keystroke
        // path — Observation invalidates the one row that reads it.
        var identical: [Sample] = [], fieldWrite: [Sample] = [], purchasedToggle: [Sample] = []
        var unmountedWrite: [Sample] = [], discsWrite: [Sample] = [], audioWrite: [Sample] = []
        do {
            let host = Host(rootView: CardSlot(model: models[0], displayIndex: 1, viewModel: vm))
            host.frame = NSRect(x: 50, y: 50, width: 536, height: 800)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            await oneRunLoopTurn()
            for trial in 0..<trials {
                let i = await measure {
                    host.rootView = CardSlot(model: models[0], displayIndex: 1, viewModel: vm)
                    host.layoutSubtreeIfNeeded()
                }
                let f = await measure {
                    models[0].notes = "typed \(trial)"
                    host.layoutSubtreeIfNeeded()
                }
                let p = await measure {
                    models[0].purchased.toggle()
                    host.layoutSubtreeIfNeeded()
                }
                let un = await measure {
                    models[1].notes = "typed \(trial)"   // NOT mounted: observer cost alone
                    host.layoutSubtreeIfNeeded()
                }
                let dw = await measure {
                    models[0].numberOfDiscs = trial % 9 + 1
                    host.layoutSubtreeIfNeeded()
                }
                let aw = await measure {
                    models[0].audioChannels = trial % 2 == 0 ? "5.1" : "2.0"
                    host.layoutSubtreeIfNeeded()
                }
                if trial >= warmup {
                    identical.append(i); fieldWrite.append(f); purchasedToggle.append(p)
                    unmountedWrite.append(un); discsWrite.append(dw); audioWrite.append(aw)
                }
            }
            host.removeFromSuperview()
            await oneRunLoopTurn()
        }
        report("swap-identical", identical, into: &r)
        report("field-write-notes", fieldWrite, into: &r)
        report("purchased-toggle", purchasedToggle, into: &r)
        report("field-write-unmounted-model", unmountedWrite, into: &r)
        report("field-write-discs", discsWrite, into: &r)
        report("field-write-audioChannels", audioWrite, into: &r)
        report("mount", mount, into: &r)
        report("remount", remount, into: &r)
        report("swap-cross-format", swap, into: &r)
        report("swap-same-format", swapSameFormat, into: &r)
        report("unmount", unmount, into: &r)
        r.metric("card.nsviews", Double(viewCount), "views")
        r.metric("card.focusable", Double(focusableCount), "views")
        log("card census: \(viewCount) NSViews, \(focusableCount) accept first responder")

        // MARK: Model-side costs, for scale
        let model = models[0]
        let hashIterations = 2000
        let t0 = ContinuousClock.now
        var acc = 0
        for _ in 0..<hashIterations { acc &+= model.contentHash }
        let hashUS = milliseconds(ContinuousClock.now - t0) * 1000 / Double(hashIterations)
        let base = model.snapshot()
        let t1 = ContinuousClock.now
        var eq = 0
        for _ in 0..<hashIterations { if model.snapshot() == base { eq += 1 } }
        let snapUS = milliseconds(ContinuousClock.now - t1) * 1000 / Double(hashIterations)
        r.metric("contentHash", hashUS, "us")
        r.metric("snapshot-compare", snapUS, "us")
        log("contentHash \(Fmt.fixed(hashUS, 2)) us | snapshot+compare \(Fmt.fixed(snapUS, 2)) us (acc \(Fmt.int(acc & 1)) eq \(Fmt.int(eq)))")

        await controlTable(into: &r, container: container)
        await describeSwiftUIPopUp(container: container)
        await carouselStep(into: &r, container: container, coordinator: coordinator)

        r.check("measured", mount.count == trials - warmup, "\(mount.count) samples")
        window.close()
        return r
    }

    // MARK: - A real navigation step
    //
    // Hosts the actual FSTabReleasesView over ten releases, lets it hydrate, then asks the
    // view model for one step and records main-thread CPU per run-loop turn for the next
    // second. The heaviest turn is Phase A's mount; the turns after it are the spring.
    private static func carouselStep(into r: inout HarnessScenarioResult, container: NSView,
                                     coordinator: DataCoordinator) async {
        let sheet = FilmSheet(coordinator: coordinator, initialTab: .releases)
        guard let vm = sheet.releasesTab else { return }
        let formats: [ReleaseFormat] = [.uhd4K, .bluRay, .dvd]
        vm.releases = (0..<10).map { i in makeModel(format: formats[i % 3], purchased: i % 2 == 0, sortOrder: i) }

        let host = NSHostingView(rootView: FSTabReleasesView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 850)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        // Hydration takes a few turns; give it plenty.
        for _ in 0..<30 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(200))
        let (views, focusable) = census(host)
        log("carousel at rest (10 releases, index 0): \(views) NSViews, \(focusable) focusable")
        r.metric("carousel.rest.nsviews", Double(views), "views")

        func stepAndSample(_ label: String, _ action: () -> Void) async -> [Double] {
            var perTurn: [Double] = []
            action()
            var last = threadCPUMilliseconds()
            let start = ContinuousClock.now
            while milliseconds(ContinuousClock.now - start) < 900 {
                await oneRunLoopTurn()
                let now = threadCPUMilliseconds()
                perTurn.append(now - last)
                last = now
            }
            let total = perTurn.reduce(0, +)
            let top = perTurn.sorted(by: >).prefix(4)
            unsafe log(String(format: "%@: %.1f ms main-thread CPU over the step; heaviest turns %@",
                       label, total, top.map { Fmt.fixed($0, 1) }.joined(separator: ", ")))
            return perTurn
        }
        // The first step also pays for whatever the hydration ramp left; take three.
        var totals: [Double] = []
        for i in 1...3 {
            let t = await stepAndSample("step \(i) (next)") { vm.nextCard() }
            totals.append(t.reduce(0, +))
            let peak = t.max() ?? 0
            r.metric("carousel.step\(i).cpu", t.reduce(0, +), "ms")
            r.metric("carousel.step\(i).peakTurn", peak, "ms")
        }
        host.removeFromSuperview()
        await oneRunLoopTurn()
    }

    // MARK: - What SwiftUI's Picker(.menu) actually builds
    private static func describeSwiftUIPopUp(container: NSView) async {
        let host = NSHostingView(rootView: AnyView(
            VStack {
                TaggedPicker(selection: .constant("Canada"),
                             options: ReleaseOrigin.names.map { ReleaseOption($0) },
                             placeholder: "Select Country…")
                Picker("", selection: .constant("MGM")) {
                    Text("Select Studio…").tag("")
                    ForEach(ReleaseStudio.ordered, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Other").tag("Other")
                }.pickerStyle(.menu).labelsHidden().frame(width: 144)
                MenuProbeLabel()
            }.frame(width: 536)))
        host.frame = NSRect(x: 0, y: 0, width: 536, height: 300)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await oneRunLoopTurn() }
        await renderComparison(container: container)
        var stack: [NSView] = [host]
        var found = 0
        while let v = stack.popLast() {
            if let p = v as? NSPopUpButton {
                found += 1
                let cell = p.cell as? NSPopUpButtonCell
                var desc = "NSPopUpButton #\(found): class=\(type(of: p)) pullsDown=\(p.pullsDown) "
                desc += "bezel=\(p.bezelStyle.rawValue) bordered=\(p.isBordered) controlSize=\(p.controlSize.rawValue) "
                desc += "font=\(p.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil") "
                desc += "focusRing=\(p.focusRingType.rawValue) refusesFR=\(p.refusesFirstResponder) "
                desc += "arrowPos=\(cell?.arrowPosition.rawValue ?? 99) prefEdge=\(cell?.preferredEdge.rawValue ?? 0) "
                desc += "imagePos=\(p.imagePosition.rawValue) alignment=\(p.alignment.rawValue) "
                desc += "frame=\(p.frame) intrinsic=\(p.intrinsicContentSize) items=\(p.numberOfItems) "
                desc += "autoenables=\(p.menu?.autoenablesItems ?? false) menuDelegate=\(p.menu?.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                desc += unsafe "selected='\(p.titleOfSelectedItem ?? "")' superview=\(type(of: p.superview!))"
                log(desc)
                if let items = p.menu?.items {
                    let sample = items.prefix(3).map { "'\($0.title)' view=\($0.view.map { String(describing: type(of: $0)) } ?? "nil") attr=\($0.attributedTitle != nil) state=\($0.state.rawValue) sep=\($0.isSeparatorItem)" }
                    log("   items: " + sample.joined(separator: " | "))
                }
            }
            stack.append(contentsOf: v.subviews)
        }
        host.removeFromSuperview()
        await oneRunLoopTurn()
    }

    /// Writes `popup-comparison.png` into the sandbox: SwiftUI's Picker(.menu) above
    /// ReleasePopUpButton with the same selection, enabled and disabled, at 2x.
    private static func renderComparison(container: NSView) async {
        let countries = ReleaseOrigin.names.map { ReleaseOption($0) }
        let items = ReleasePopUpButton.items(placeholder: "Select Country…", options: countries)
        let view = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("SwiftUI:").frame(width: 70, alignment: .trailing)
                Picker("", selection: .constant("Canada")) {
                    Text("Select Country…").tag("")
                    ForEach(countries, id: \.tag) { Text($0.title).tag($0.tag) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 144, alignment: .leading)
                Picker("", selection: .constant("")) {
                    Text("Select Country…").tag("")
                    ForEach(countries, id: \.tag) { Text($0.title).tag($0.tag) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 144, alignment: .leading).disabled(true)
            }
            HStack(spacing: 12) {
                Text("AppKit:").frame(width: 70, alignment: .trailing)
                ReleasePopUpButton(selection: .constant("Canada"), items: items)
                    .frame(width: 144, height: ReleaseCardMetrics.popUpLayoutHeight, alignment: .leading)
                ReleasePopUpButton(selection: .constant(""), items: items)
                    .frame(width: 144, height: ReleaseCardMetrics.popUpLayoutHeight, alignment: .leading)
                    .disabled(true)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 90)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await oneRunLoopTurn() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]),
           let dir = DebugSandbox.rootURL {
            let url = dir.appendingPathComponent("popup-comparison.png")
            try? data.write(to: url)
            log("popup comparison written to \(url.path)")
        }
        host.removeFromSuperview()
        await oneRunLoopTurn()
    }

    private struct MenuProbeLabel: View {
        var body: some View {
            Menu { Toggle(isOn: .constant(true)) { Text("A") } } label: { Text("Menu label") }
                .frame(width: 144)
        }
    }

    // MARK: - Per-control costs
    //
    // Each control kind is hosted ten-up in a VStack so the hosting view's own overhead is
    // amortized, mounted, then updated by reassigning the root view with a different value
    // (the same diff the card's in-place swap performs). Per-instance figures are the
    // ten-up total divided by ten.

    private struct Probe {
        let name: String
        let make: (Int) -> AnyView   // value index → view (ten stacked)
    }

    private static func tenUp<V: View>(_ index: Int, @ViewBuilder _ item: @escaping (Int) -> V) -> AnyView {
        AnyView(VStack(spacing: 4) {
            ForEach(0..<10, id: \.self) { row in item(index + row) }
        }.frame(width: 536))
    }

    /// A hand-driven NSPopUpButton, as ReleaseJumpMenu is. `lazy` keeps only the selected
    /// title in the menu and fills the rest in `menuNeedsUpdate`, which AppKit calls just
    /// before the menu opens.
    private struct PopUpProbe: NSViewRepresentable {
        let titles: [String]
        let selected: Int
        let lazy: Bool

        final class Coordinator: NSObject, NSMenuDelegate {
            var titles: [String] = []
            var selected = 0
            func menuNeedsUpdate(_ menu: NSMenu) {
                menu.removeAllItems()
                for t in titles { menu.addItem(withTitle: t, action: nil, keyEquivalent: "") }
            }
        }
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSPopUpButton {
            let b = NSPopUpButton(frame: .zero, pullsDown: false)
            b.controlSize = .regular
            let menu = NSMenu()
            if lazy { menu.delegate = context.coordinator }
            b.menu = menu
            return b
        }
        func updateNSView(_ b: NSPopUpButton, context: Context) {
            context.coordinator.titles = titles
            context.coordinator.selected = selected
            guard let menu = b.menu else { return }
            if lazy {
                if menu.numberOfItems != 1 || menu.item(at: 0)?.title != titles[selected] {
                    menu.removeAllItems()
                    menu.addItem(withTitle: titles[selected], action: nil, keyEquivalent: "")
                }
                b.selectItem(at: 0)
            } else {
                if menu.numberOfItems != titles.count {
                    menu.removeAllItems()
                    for t in titles { menu.addItem(withTitle: t, action: nil, keyEquivalent: "") }
                }
                b.selectItem(at: selected)
            }
        }
    }

    private static func controlTable(into r: inout HarnessScenarioResult, container: NSView) async {
        let countries = ReleaseOrigin.names.map { ReleaseOption($0) }
        let studios   = ReleaseStudio.ordered
        let aspects   = AspectRatioVocabulary.all

        let probes: [Probe] = [
            Probe(name: "text-only") { v in tenUp(v) { i in Text("Label \(i)").frame(width: 140) } },
            Probe(name: "button-plain") { v in tenUp(v) { i in
                Button(action: {}) { Circle().fill(.red).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).id(i) } },
            Probe(name: "picker-menu-12") { v in tenUp(v) { i in
                TaggedPicker(selection: .constant(countries[i % countries.count].tag),
                             options: countries, placeholder: "Select Country…") } },
            Probe(name: "picker-menu-25") { v in tenUp(v) { i in
                Picker("", selection: .constant(studios[i % studios.count])) {
                    Text("Select Studio…").tag("")
                    ForEach(studios, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Other").tag("Other")
                }.pickerStyle(.menu).labelsHidden().frame(width: 144) } },
            Probe(name: "nspopup-eager-25") { v in tenUp(v) { i in
                PopUpProbe(titles: studios, selected: i % studios.count, lazy: false).frame(width: 144, height: 22) } },
            Probe(name: "nspopup-lazy-25") { v in tenUp(v) { i in
                PopUpProbe(titles: studios, selected: i % studios.count, lazy: true).frame(width: 144, height: 22) } },
            Probe(name: "picker-menu-3") { v in tenUp(v) { i in
                Picker("", selection: .constant(["A","B","C"][i % 3])) {
                    ForEach(["A","B","C"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 144) } },
            Probe(name: "picker-segmented-2") { v in tenUp(v) { i in
                Picker("", selection: .constant(i % 2 == 0 ? "New" : "Used")) {
                    Text("New").tag("New"); Text("Used").tag("Used")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 144) } },
            Probe(name: "menu-20-toggles") { v in tenUp(v) { i in
                Menu {
                    ForEach(aspects, id: \.self) { option in
                        Toggle(isOn: .constant(option == aspects[i % aspects.count])) { Text(option) }
                    }
                } label: { Text(aspects[i % aspects.count]).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: 144) } },
            Probe(name: "textfield-rounded") { v in tenUp(v) { i in
                TextField("Notes", text: .constant("note \(i)")).textFieldStyle(.roundedBorder) } },
            Probe(name: "toggle-checkbox") { v in tenUp(v) { i in
                Toggle("", isOn: .constant(i % 2 == 0)).labelsHidden() } },
            Probe(name: "stepper-swiftui") { v in tenUp(v) { i in
                Stepper(value: .constant(i % 10 + 1), in: 1...10) { Text("\(i % 10 + 1)").frame(width: 41) } } },
            Probe(name: "standard-stepper") { v in tenUp(v) { i in
                StandardStepper(value: .constant(i % 10 + 1), in: 1...10) } },
            Probe(name: "datepicker-year") { v in tenUp(v) { i in
                CustomDatePicker(year: .constant(2000 + i % 20), hasValue: .constant(true),
                                 yearRange: 1990...2026) {} } },
            Probe(name: "datepicker-full") { v in tenUp(v) { i in
                CustomDatePicker(date: .constant(Date(timeIntervalSince1970: Double(i) * 86_400 * 40)),
                                 hasValue: .constant(true), yearRange: 1990...2026) {} } },
            Probe(name: "currency-field") { v in tenUp(v) { i in
                CurrencyInputField(value: .constant(Double(i) + 0.5)) } },
            Probe(name: "help-button") { v in tenUp(v) { i in
                HelpPopoverButton(helpText: "Help \(i)", autoDismissDuration: 10) } },
        ]

        for probe in probes {
            var mountS: [Sample] = [], updateS: [Sample] = [], unmountS: [Sample] = []
            var views = 0, focusable = 0
            let trials = 8, warmup = 2
            for trial in 0..<trials {
                let host = NSHostingView(rootView: AnyView(Color.clear.frame(width: 536, height: 1)))
                host.frame = NSRect(x: 50, y: 50, width: 536, height: 800)
                container.addSubview(host)
                host.layoutSubtreeIfNeeded()
                await oneRunLoopTurn()
                let m = await measure {
                    host.rootView = probe.make(trial * 10)
                    host.layoutSubtreeIfNeeded()
                }
                if trial == warmup { (views, focusable) = census(host) }
                let u = await measure {
                    host.rootView = probe.make(trial * 10 + 1)
                    host.layoutSubtreeIfNeeded()
                }
                let d = await measure {
                    host.rootView = AnyView(Color.clear.frame(width: 536, height: 1))
                    host.layoutSubtreeIfNeeded()
                }
                host.removeFromSuperview()
                await oneRunLoopTurn()
                if trial >= warmup { mountS.append(m); updateS.append(u); unmountS.append(d) }
            }
            let m = stats(mountS.map(\.total)).median / 10
            let u = stats(updateS.map(\.total)).median / 10
            let d = stats(unmountS.map(\.total)).median / 10
            r.metric("control.\(probe.name).mount", m, "ms/each")
            r.metric("control.\(probe.name).update", u, "ms/each")
            r.metric("control.\(probe.name).unmount", d, "ms/each")
            unsafe log(String(format: "control %-20@ mount %6.2f  update %6.2f  unmount %6.2f  ms each | %3d views, %2d focusable (per 10)",
                       probe.name, m, u, d, views, focusable))
        }
    }
}


// MARK: - Card Focus
//
// Proves FilmSheetKeyLoop against the REAL carousel: FSTabReleasesView hosted in an
// NSHostingView inside an off-screen window, with its neighbors mounted exactly as they are
// in the sheet. The loop is exercised through the same `advance` the tab's key monitor calls
// on a Tab press, and the window's first responder is read back after each step.
//
// What it asserts is the contract the user experiences: from nothing focused, one step
// lands on the card's first control; successive steps visit every control of the current
// card in reading order and wrap; a backward step from the first wraps to the last; no step
// ever lands on a control of a neighboring card, however many are mounted; and after a
// navigation step the loop is the new card's. It also records what SwiftUI gave each
// hosted control for `focusRingType`, which is what decides whether the ring the user is
// supposed to see can be drawn at all.
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
        // Three cards: purchased 4K (the date Stepper is on it), unpurchased Blu-ray, purchased
        // DVD. All three are mounted once the carousel has hydrated around the first, so the
        // confinement checks below have real neighbors to be confined from.
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
        // The hydration ramp mounts the neighbors over several turns; give it room.
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

        // A SheetCheckbox representable's NSButton, which SwiftUI wraps in a host named
        // after the representable.
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
        // With Full Keyboard Access on, the Purchased checkbox is the first stop. Without it
        // AppKit refuses first responder for every button, and only the text fields remain
        // — which is the system's rule, not the loop's, so the check is conditional.
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

        // Reading order: never a control ABOVE the previous one by more than a row.
        var orderedTopDown = true
        for i in 1..<loop.count {
            let a = loop[i - 1].convert(loop[i - 1].bounds, to: nil)
            let b = loop[i].convert(loop[i].bounds, to: nil)
            if b.midY > a.midY + 8 { orderedTopDown = false }
        }
        r.check("reading-order", orderedTopDown, "loop order climbs back up the card")

        // Every control is fully visible — no clipped or zero-size stop the user cannot see.
        r.check("every-stop-visible",
                loop.allSatisfy { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor },
                "a loop stop is hidden or clipped")

        // MARK: Confinement
        // The neighbors are mounted but hit-disabled, so the loop's own census sees nothing
        // on them by design. Count them the way AppKit's key view loop would instead: every
        // key view in the window whose center lies outside the current card's controls.
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
        // One more wraps to the first.
        FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: true)
        r.check("wraps-forward",
                FilmSheetKeyLoop.focusedControl(in: window) === loop[0],
                "did not wrap to the first control")
        // Backward from the first wraps to the last.
        FilmSheetKeyLoop.shared.advance(inCard: current, in: window, forward: false)
        r.check("wraps-backward",
                FilmSheetKeyLoop.focusedControl(in: window) === loop[loop.count - 1],
                "did not wrap to the last control")
        // None of the visited controls belong to a neighbor.
        r.check("never-left-the-card",
                !visited.contains { c in neighborControls.contains { $0 === c } },
                "focus landed on a neighbor card")
        // A tabbed-onto text field has its contents selected, as AppKit's own traversal does.
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
        // The ring is drawn by AppKit from `focusRingType`; a hosted control that SwiftUI
        // set to `.none` can be focused but never show it. Every button, pop-up and stepper
        // in the loop must be able to draw one.
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
        // The sheet keeps every visited tab mounted behind the active one, hidden by
        // opacity rather than isHidden. Their controls overlap the card and are key views
        // by AppKit's reckoning — the invisible stops that made Tab take several presses
        // between visible controls. Visit Details first so it is alive, then switch to
        // Releases and require the loop to be the same sequence of controls the tab has
        // on its own.
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
            // The standalone loop above was taken after one navigation step (card 1); step
            // the sheet's carousel the same way so the two describe the same card.
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
            // Every stop is the thing a click at its center would reach.
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
        // Same sheet, same loop, tab domains. Details, Metadata and Notes scroll, so their
        // loops must include controls scrolled out of view and Tab must bring them in; no
        // stop may belong to a hidden tab (the Releases cards are alive behind these).
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
            // The sink took focus on activation; one step lands on the first control.
            r.check("\(name)-sink-holds-focus", sheetWindow.firstResponder is NSButton
                        && String(describing: type(of: sheetWindow.firstResponder!)).contains("SinkButton"),
                    "\(name): first responder after activation is \(String(describing: sheetWindow.firstResponder))")
            FilmSheetKeyLoop.shared.advance(inTab: tab, in: sheetWindow, forward: true)
            r.check("\(name)-first-step-lands-first",
                    tabLoop.first.map { $0 === FilmSheetKeyLoop.focusedControl(in: sheetWindow) } == true,
                    "\(name): first Tab landed on \(String(describing: FilmSheetKeyLoop.focusedControl(in: sheetWindow)))")
            // Walk the whole loop; every stop must be visible once reached.
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
        // Details specifics: the Name field first; the checkboxes are AppKit stops.
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
//
// Proves `SheetSegmentedControl` (30_20) is laid out and configured exactly as SwiftUI's
// `Picker(.segmented)` was, for every proposal shape the sheet uses: unconstrained in a
// stack (fills), `.fixedSize()` (ideal), a narrow `.frame(width:)` (clamped to the minimum),
// a wide one (honored), a tall one (height ignored), and disabled. Two-, three- and
// four-segment label sets, since the minimum-width rule depends on the labels.
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
//
// `placeholder-anchor` (in `all`): renders StandardPlaceholder (90_00) through the window's
// own display path with the same glyph, title, and first message line, and 1, 2, and 3
// message lines, a message that wraps, and an action button. The pixel rows from the top of
// the view through the bottom of the one-line message's ink must be identical in every
// variant — the glyph, the title, and the first line never move — and each variant must
// have ink below that, so the extra lines were drawn rather than clipped. A row is compared
// by its ink extent: the rows that hold ink must be the same rows (any vertical move, even
// one device pixel, changes them), and each row's leftmost and rightmost ink may differ by
// one pixel. A wrapped message's Text is the full message width, and its centered first
// line lands on a different subpixel from a one-line Text's (measured: half a point left,
// rows identical), which changes the antialiasing but not the position.
//
// `import-details-segments` (in `all`): hosts the real import Details popover (28_00) for a
// session with additions and updates only, and reads its NSSegmentedControl back: All,
// Added, Updated enabled, Errors and Duplicates disabled, out of the key view loop, and no
// narrower than its labels need. Writes `import-details-segments.png` to the sandbox.
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
        // The popover draws no background of its own; the window's stands in for its material.
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

        // Every label fits: the control is no narrower than its .fit width.
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
//
// `sidebar-disclosure` (in `all`): drives the smart list disclosure rows in the REAL main
// window's sidebar (22_00). Expanding and collapsing go through the rows' own disclosure
// buttons, and row selection through NSOutlineView.selectRowIndexes, which posts the same
// selection-change notification a click does. Checks, against the Purchased family: a
// variant chosen from the title bar while collapsed leaves nothing highlighted, expanding
// reveals it highlighted, collapsing neither navigates nor moves the highlight to the
// parent, a child row selects its variant within the family and from another view, the
// parent row returns to the parent list, and the expansion is written to Preferences.
//
// `sidebar-expansion-seed` then `sidebar-expansion-restore` (opt-in, two launches on ONE
// container): the first saves Unpurchased and Filtered Library as expanded, the second
// checks that exactly those two families launch expanded.
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
    /// expose no readable text (no AX client is attached to a harness run). Level-0 rows are
    /// the three section headers; the Library rows are LeftSidebar's six in order; a Smart
    /// Lists level-1 row is the next of `sidebarCases` and its level-2 rows that family's
    /// variants; the Lists rows are `cachedLists` in order. Any row the structure does not
    /// account for is named "?", which the scenario's row-count checks catch.
    private static func rowTitles(_ outline: NSOutlineView) -> [String] {
        let library = ["All Films", "Unwatched", "Recents", "Reports", "Imports", "Queue"]
        let lists = AppDelegate.dataCoordinator?.cachedLists.map(\.listName) ?? []
        var titles: [String] = []
        var section = -1
        var level1 = 0
        var level2 = 0
        var family: SmartListType?
        for row in 0..<outline.numberOfRows {
            switch outline.level(forRow: row) {
            case 0:
                section += 1; level1 = 0
                titles.append(["§Library", "§Smart Lists", "§Lists"].indices.contains(section)
                              ? ["§Library", "§Smart Lists", "§Lists"][section] : "?")
            case 1:
                let names: [String]
                switch section {
                case 0: names = library
                case 1: names = SmartListType.sidebarCases.map(\.rawValue)
                default: names = lists
                }
                titles.append(names.indices.contains(level1) ? names[level1] : "?")
                family = section == 1 && SmartListType.sidebarCases.indices.contains(level1)
                    ? SmartListType.sidebarCases[level1] : nil
                level1 += 1; level2 = 0
            default:
                let variants = family.map { Array($0.familyVariants.dropFirst()) } ?? []
                titles.append(variants.indices.contains(level2) ? variants[level2].rawValue : "?")
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

        // Start collapsed, on the parent.
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

        // Title-bar picker (or shortcut) while collapsed: the highlight goes away.
        state.select(.purchased4K, immediate: true)
        await settle(400)
        r.check("variant-collapsed-unhighlighted", highlighted(outline) == "<none>" && views.activeView == .smartList(.purchased4K), snapshot())

        // The shortcuts' deferred path ends the same way.
        state.select(.purchasedBluray)
        await settle(600)
        r.check("variant-deferred-unhighlighted", highlighted(outline) == "<none>" && views.activeView == .smartList(.purchasedBluray), snapshot())

        // Expanding reveals the variant already highlighted.
        r.check("expand-button", await toggle("Purchased"), "no disclosure button on Purchased")
        let expandedTitles = rowTitles(outline)
        r.check("expanded-children", expandedTitles.count == titles.count + 3 && !expandedTitles.contains("?")
                    && outline.level(forRow: row("Purchased 4K", in: outline) ?? 0) == 2, "\(expandedTitles)")
        r.check("expanded-variant-highlighted", highlighted(outline) == "Purchased Blu-ray", snapshot())
        r.check("expansion-saved", Preferences.expandedSmartListFamilies == [.purchased], "\(Preferences.expandedSmartListFamilies)")

        // Collapsing hides the highlight and changes nothing else.
        r.check("collapse-button", await toggle("Purchased"), "")
        await settle(300)
        r.check("collapse-keeps-view", views.activeView == .smartList(.purchasedBluray) && state.selected == .purchasedBluray
                    && appState.selectedSidebarItem == .smartList(.purchased), snapshot())
        r.check("collapse-unhighlighted", highlighted(outline) == "<none>", snapshot())
        r.check("collapse-saved", Preferences.expandedSmartListFamilies.isEmpty, "\(Preferences.expandedSmartListFamilies)")

        // Expand again; the highlight is back on the variant.
        _ = await toggle("Purchased")
        r.check("re-expand-highlighted", highlighted(outline) == "Purchased Blu-ray", snapshot())

        // A child row within the family.
        r.check("child-click-found", await click("Purchased DVD"), "")
        r.check("child-click-in-family", views.activeView == .smartList(.purchasedDVD) && state.selected == .purchasedDVD
                    && appState.selectedSidebarItem == .smartList(.purchased) && highlighted(outline) == "Purchased DVD", snapshot())

        // The parent row returns to the parent list.
        _ = await click("Purchased")
        r.check("parent-click-in-family", views.activeView == .smartList(.purchased) && state.selected == .purchased
                    && highlighted(outline) == "Purchased", snapshot())

        // A child row from another view.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(400)
        r.check("elsewhere-highlight", highlighted(outline) == "All Films", snapshot())
        _ = await click("Purchased 4K")
        r.check("child-click-from-elsewhere", views.activeView == .smartList(.purchased4K) && state.selected == .purchased4K
                    && appState.selectedSidebarItem == .smartList(.purchased) && highlighted(outline) == "Purchased 4K", snapshot())

        // The parent row from another view resets the family, as before.
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(400)
        _ = await click("Purchased")
        r.check("parent-click-from-elsewhere", views.activeView == .smartList(.purchased) && state.selected == .purchased
                    && highlighted(outline) == "Purchased", snapshot())

        // Leave it as found.
        _ = await toggle("Purchased")
        Preferences.expandedSmartListFamilies = []
        appState.navigate(to: .libraryItem(.allFilms))
        await settle()
        return r
    }
}


// MARK: - Picker menu dismissal
//
// `picker-dismissal` (opt-in; ACTIVATES the app and puts a real window and real menus on
// screen for about a minute, taking keyboard and mouse focus from whatever the user is doing —
// warn before running it, and never while the user is working): opens the Reports
// title bar's sub-tab pop-up in a titled window, chooses each tab through REAL menu tracking
// (arrow and Return key events posted into the tracking loop), and samples the menu window's
// alpha from the window server on a background thread every 3 ms. The main thread cannot be
// asked how the fade went — it is the thing being measured — but the window server sees every
// alpha step the menu's tracking loop commits.
//
// Run twice in one process: once with SwiftUI's `Picker(.menu)` (the control before
// 2026-09-23, restored through `debugForcesSwiftUISubcategoryMenuPicker`) and once with the
// shipping NSPopUpButton. A leg's fade is healthy when it steps down to zero without a gap
// longer than a few frames; the SwiftUI leg is expected to report the selection landing
// mid-fade and is recorded as metrics, while the checks gate only the shipping control.
extension DebugHarness {

    /// Background sampler of this process's pop-up-menu windows (window level ≥ 101).
    private final class MenuFadeSampler: Thread, @unchecked Sendable {
        struct Sample { let time: Double; let alpha: Double? }   // nil: no menu window on screen
        private let lock = NSLock()
        private var samples: [Sample] = []
        private var marks: [(time: Double, label: String)] = []
        private let pid = getpid()
        private let origin = CACurrentMediaTime()

        func now() -> Double { (CACurrentMediaTime() - origin) * 1000 }

        func mark(_ label: String) {
            let t = now()
            lock.lock(); marks.append((t, label)); lock.unlock()
        }

        override func main() {
            while !isCancelled {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                var alpha: Double?
                for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid
                    && (w[kCGWindowLayer as String] as? Int ?? 0) >= 101 {
                    alpha = max(alpha ?? 0, w[kCGWindowAlpha as String] as? Double ?? 0)
                }
                let t = now()
                lock.lock(); samples.append(Sample(time: t, alpha: alpha)); lock.unlock()
                usleep(3000)
            }
        }

        func reset() { lock.lock(); samples.removeAll(); marks.removeAll(); lock.unlock() }

        func snapshot() -> (samples: [Sample], marks: [(time: Double, label: String)]) {
            lock.lock(); defer { lock.unlock() }
            return (samples, marks)
        }
    }

    private struct ReportsHost: View {
        let coordinator: DataCoordinator
        let appState: AppState
        var body: some View {
            ReportsView()
                .environment(SelectionState.shared)
                .environment(appState)
                .environment(coordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One analyzed selection.
    private struct FadeReading {
        var fadeFrames = 0              // distinct alpha values between 1 and 0
        var fadeDuration = 0.0          // first step below 1 → alpha 0 (or vanish)
        var longestStall = 0.0          // longest interval with no alpha change during the fade
        var lastAlphaBeforeVanish = 1.0 // > 0 means the window was pulled mid-fade
        var selectionAfterFadeEnd = 0.0 // negative: the selection landed inside the fade
        var contentSwapAfterSelection = 0.0
        var switched = false
        var trackingDuration = 0.0      // open → performClick returned; ≈3000 means the backstop fired
        var keysPosted = false
        var buttonTitleAfter = ""
    }

    static func pickerDismissalScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "picker-dismissal")
        coordinator.importFilms(reportsCorpus())
        let appState = AppState(modelContainer: coordinator.modelContainer, dataCoordinator: coordinator)
        let state = ReportsState.shared
        state.selectCategory(.costTracker, persist: false)

        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1148, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "picker-dismissal harness"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let sampler = MenuFadeSampler()
        sampler.start()
        defer { sampler.cancel() }

        func popUp(in view: NSView) -> NSPopUpButton? {
            if let p = view as? NSPopUpButton { return p }
            for sub in view.subviews { if let p = popUp(in: sub) { return p } }
            return nil
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        /// Observation callbacks fire on willSet, on the mutating (main) thread.
        func armMark(_ label: String, _ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { sampler.mark(label) }
        }

        /// `load`: milliseconds of synchronous main-thread work attached to the selection
        /// change itself (an observation callback, which fires inside the setter). It stands in
        /// for what the real window's update pass does on a sub-tab change — the main menu's
        /// Commands checkmarks, the status bar, the title glyph — which a bare ReportsView
        /// host does not have. Wherever the control reports the choice, this lands.
        func choose(_ target: ReportsCategory, load: Double) async -> FadeReading {
            var reading = FadeReading()
            let all = ReportsCategory.allCases
            guard let button = window.contentView.flatMap(popUp(in:)),
                  let from = all.firstIndex(of: state.selectedCategory),
                  let to = all.firstIndex(of: target) else { return reading }
            sampler.reset()
            // One callback, mark first: two separate callbacks run in no guaranteed order.
            withObservationTracking { _ = state.selectedCategory } onChange: {
                sampler.mark("selected")
                let end = CACurrentMediaTime() + load / 1000
                while CACurrentMediaTime() < end {}
            }
            armMark("displayed") { _ = state.displayedCategory }

            let steps = to - from
            let key: (code: UInt16, chars: String) = steps >= 0 ? (125, "\u{F701}") : (126, "\u{F700}")
            let windowNumber = window.windowNumber
            let poster = Timer(timeInterval: 0.35, repeats: false) { _ in MainActor.assumeIsolated {
                sampler.mark("keys")
                var events: [(UInt16, String)] = Array(repeating: (key.code, key.chars), count: abs(steps))
                events.append((36, "\r"))
                for (code, chars) in events {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: windowNumber, context: nil,
                                                    characters: chars, charactersIgnoringModifiers: chars,
                                                    isARepeat: false, keyCode: code) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                }
            } }
            // Backstop: a menu that ignored the keys must not hang the run.
            let backstop = Timer(timeInterval: 3, repeats: false) { _ in
                MainActor.assumeIsolated { button.menu?.cancelTracking() }
            }
            // Keys go in only once the menu is tracking (plus a settle for its open animation):
            // on a fixed timer from performClick, the first menu after a remount sometimes
            // began tracking late and lost them.
            // Timer is not Sendable; the observer runs on the main thread (menu tracking
            // posts it there), so handing the timer across is safe.
            nonisolated(unsafe) let pendingPoster = poster
            let began = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: button.menu, queue: nil) { _ in
                MainActor.assumeIsolated { unsafe RunLoop.main.add(pendingPoster, forMode: .common) }
            }
            RunLoop.main.add(backstop, forMode: .common)
            sampler.mark("open")
            button.performClick(nil)          // runs the menu's tracking loop to completion
            sampler.mark("tracking-returned")
            NotificationCenter.default.removeObserver(began)
            poster.invalidate()
            backstop.invalidate()
            reading.buttonTitleAfter = button.titleOfSelectedItem ?? ""
            await settle(900)
            reading.switched = state.displayedCategory == target

            let (samples, marks) = sampler.snapshot()
            func markTime(_ label: String) -> Double? { marks.first { $0.label == label }?.time }
            if let open = markTime("open"), let returned = markTime("tracking-returned") {
                reading.trackingDuration = returned - open
            }
            reading.keysPosted = markTime("keys") != nil
            guard let keys = markTime("keys") else { return reading }
            let after = samples.filter { $0.time >= keys }
            guard let start = after.first(where: { ($0.alpha ?? 1) < 0.99 }) else { return reading }
            let vanish = after.first { $0.time > start.time && $0.alpha == nil }
            let zero = after.first { $0.time > start.time && ($0.alpha ?? 1) <= 0.005 }
            let end = [zero?.time, vanish?.time].compactMap { $0 }.min() ?? start.time
            let during = after.filter { $0.time >= start.time && $0.time <= end && $0.alpha != nil }
            var lastChange = start.time
            var lastAlpha = start.alpha ?? 1
            var distinct = 1
            for s in during.dropFirst() {
                guard let a = s.alpha else { continue }
                if abs(a - lastAlpha) > 0.001 {
                    reading.longestStall = max(reading.longestStall, s.time - lastChange)
                    lastChange = s.time; lastAlpha = a; distinct += 1
                }
            }
            // A window pulled before its alpha reached zero stalled from its last step until
            // then; one ordered out after reaching zero (the normal case, ~40 ms later) did not.
            if let vanish, zero == nil || vanish.time < zero!.time {
                reading.longestStall = max(reading.longestStall, vanish.time - lastChange)
                reading.lastAlphaBeforeVanish = samples.last { $0.time < vanish.time && $0.alpha != nil }?.alpha ?? 1
            } else if zero != nil {
                reading.lastAlphaBeforeVanish = 0
            }
            reading.fadeFrames = distinct
            reading.fadeDuration = end - start.time
            if let selected = markTime("selected") {
                reading.selectionAfterFadeEnd = selected - end
                if let displayed = markTime("displayed") { reading.contentSwapAfterSelection = displayed - selected }
            }
            return reading
        }

        let route: [ReportsCategory] = [.dataVisualizations, .hallOfFame, .priceTracker,
                                        .releaseWishlist, .dataVisualizations, .costTracker]
        // (name, SwiftUI picker?, synthetic load in ms). Checks gate the AppKit legs only.
        let legs: [(String, Bool, Double)] = [("swiftui", true, 0), ("swiftui-loaded", true, 120),
                                              ("appkit", false, 0), ("appkit-loaded", false, 120)]
        for (leg, swiftUI, load) in legs {
            debugForcesSwiftUISubcategoryMenuPicker = swiftUI
            state.selectCategory(.costTracker, persist: false)
            let host = NSHostingView(rootView: ReportsHost(coordinator: coordinator, appState: appState))
            window.contentView = host
            await settle(1200)
            let expectedClass = swiftUI ? "SwiftUIPopupButton" : "NSPopUpButton"
            let buttonClass = window.contentView.flatMap(popUp(in:)).map { String(describing: type(of: $0)) } ?? "none"
            r.check("\(leg)-control-class", buttonClass == expectedClass, buttonClass)

            for target in route {
                let from = state.selectedCategory
                let reading = await choose(target, load: load)
                let name = "\(leg)-\(from.rawValue)→\(target.rawValue)"
                r.metric("\(name)-fade-frames", Double(reading.fadeFrames), "frames")
                r.metric("\(name)-fade-duration", reading.fadeDuration, "ms")
                r.metric("\(name)-longest-stall", reading.longestStall, "ms")
                r.metric("\(name)-alpha-at-vanish", reading.lastAlphaBeforeVanish, "alpha")
                r.metric("\(name)-selection-minus-fade-end", reading.selectionAfterFadeEnd, "ms")
                r.metric("\(name)-swap-after-selection", reading.contentSwapAfterSelection, "ms")
                r.metric("\(name)-switched", reading.switched ? 1 : 0, "bool")
                if !swiftUI {
                    r.check("\(name)-switched", reading.switched,
                            "displayed \(state.displayedCategory.rawValue); button shows '\(reading.buttonTitleAfter)'; keys posted \(reading.keysPosted); tracking \(Int(reading.trackingDuration)) ms")
                    let detail = "\(reading.fadeFrames) frames over \(Int(reading.fadeDuration)) ms, longest stall \(Int(reading.longestStall)) ms, alpha at vanish \(reading.lastAlphaBeforeVanish), selection \(Int(reading.selectionAfterFadeEnd)) ms after fade end"
                    r.check("\(name)-fade-completes", reading.fadeFrames >= 6 && reading.lastAlphaBeforeVanish <= 0.02, detail)
                    r.check("\(name)-fade-unstalled", reading.longestStall < 50, detail)
                    r.check("\(name)-selection-after-fade", reading.selectionAfterFadeEnd >= -5, detail)
                }
            }
            window.contentView = nil
            await settle(300)
        }
        debugForcesSwiftUISubcategoryMenuPicker = false
        window.close()
        await settle(200)
        return r
    }
}


// MARK: - Reports tab switch cost
//
// `reports-tab-perf` (opt-in, a measurement): what one Reports sub-tab switch costs the main
// thread, as the title-bar pop-up performs it (`selectCategory(_:immediate: true)`), on a
// library-sized corpus. The view is hosted in a window that is never ordered in and the app is
// never activated, so the scenario takes no focus. Per switch: the synchronous part (state
// write plus the hosting view's layout — the frame the new tab first appears in), then the
// main-thread CPU of the next two turns (the tabs' deferred reconcile, DataViz's second
// mount stage) and of the four after those. Every route is walked three times; first
// visits are reported apart from later ones, because several tabs seed from a cache after
// their first load.
extension DebugHarness {

    static func reportsTabPerfScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-tab-perf")
        coordinator.importFilms(reportsCorpus())
        r.metric("films", Double(coordinator.totalFilmCount), "films")
        let appState = AppState(modelContainer: coordinator.modelContainer, dataCoordinator: coordinator)
        let state = ReportsState.shared
        state.selectCategory(.costTracker, persist: false, immediate: true)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1148, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReportsHost(coordinator: coordinator, appState: appState))
        host.frame = NSRect(x: 0, y: 0, width: 1148, height: 760)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { await oneRunLoopTurn() }
        try? await Task.sleep(for: .milliseconds(300))

        // Every ordered pair (from → to), twice, after one warm-up lap that absorbs first-visit
        // costs. A switch's cost is the outgoing tab's teardown plus the incoming tab's mount;
        // the pair matrix separates the two (a row that is high whatever the destination is
        // teardown, a column that is high whatever the source is mount).
        let all = ReportsCategory.allCases
        func switchCost(to target: ReportsCategory) async -> Double {
            let cpu1 = threadCPUMilliseconds()
            state.selectCategory(target, persist: false, immediate: true)
            host.layoutSubtreeIfNeeded()
            await oneRunLoopTurn(); await oneRunLoopTurn()
            host.layoutSubtreeIfNeeded()
            for _ in 0..<4 { await oneRunLoopTurn() }
            host.layoutSubtreeIfNeeded()
            let cost = threadCPUMilliseconds() - cpu1
            r.check("switched-\(target.rawValue)", state.displayedCategory == target, "")
            // Let background passes (DataViz recalculation, tracker reloads) land between
            // switches, as they would while a user reads the tab.
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<4 { await oneRunLoopTurn() }
            return cost
        }
        for target in all.dropFirst() + [all[0]] {
            r.metric("first-visit-\(target.rawValue)", await switchCost(to: target), "ms")
        }
        var pairs: [String: [Double]] = [:]
        for _ in 0..<2 {
            for from in all {
                for to in all where to != from {
                    if state.displayedCategory != from { _ = await switchCost(to: from) }
                    pairs["\(from.rawValue)→\(to.rawValue)", default: []].append(await switchCost(to: to))
                }
            }
        }
        for from in all {
            for to in all where to != from {
                let key = "\(from.rawValue)→\(to.rawValue)"
                r.metric(key, stats(pairs[key] ?? []).median, "ms")
            }
        }
        window.contentView = nil
        window.close()
        await oneRunLoopTurn()
        return r
    }
}

// MARK: - Reports-shaped corpus

extension DebugHarness {
    /// `standardCorpus` gives every Reports table tab NOTHING to show — its purchases carry no
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

// MARK: - Reports hitch, in the real window
//
// `reports-hitch` (opt-in, a measurement): the sub-tab switch as the user sees it, in the app's
// REAL main window (the harness runs after MainView is up) — so drawing, the right sidebar,
// the status bar and the CoreAnimation commit are all included, which `reports-tab-perf`'s
// never-ordered-in window leaves out. Launch with `open -g -n` so the window is shown without
// activating the app. A run-loop observer ordered after CoreAnimation's commit records every
// busy stretch (after-waiting → before-waiting) of the main thread; per switch it reports the
// first stretch (the delay until the frame carrying the new content is committed), the total
// busy time, and the longest stretch, over 800 ms. The same measurement is taken for the
// sub-tab switches the user compares Reports against: Recents categories and smart-list
// variants (their menu-style pickers call exactly these methods).
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

    static func reportsHitchScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
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

        // Reports: the four table tabs among themselves, then into and out of Visualizations.
        appState.navigate(to: .libraryItem(.reports))
        let reports = ReportsState.shared
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1500)
        let tables: [ReportsCategory] = [.priceTracker, .hallOfFame, .releaseWishlist, .costTracker]
        for _ in 0..<3 {
            for t in tables { await measure("reports-table→table") { reports.selectCategory(t, persist: false, immediate: true) } }
        }
        for _ in 0..<3 {
            await measure("reports-table→dataviz") { reports.selectCategory(.dataVisualizations, persist: false, immediate: true) }
            await measure("reports-dataviz→table") { reports.selectCategory(.hallOfFame, persist: false, immediate: true) }
        }

        // Recents: one mounted gallery, reloaded per category.
        appState.navigate(to: .libraryItem(.recents))
        await settle(1500)
        for _ in 0..<3 {
            for c in RecentsCategory.allCases {
                await measure("recents-category") { RecentsState.shared.selectCategory(c, persist: false, immediate: true) }
            }
        }

        // Smart-list variants of the first family with more than one variant.
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

        // Full sidebar switches between two gallery views, for scale.
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

// MARK: - Reports table behavior, in the real window
//
// `reports-table-behavior` (opt-in): the AppKit ReportTable (27.01) does what the SwiftUI Table
// and List it replaced did, driven through the table itself in the real window — selection into
// SelectionState and back out, header sorting onto the tracker's KeyPathComparator order (and
// ReportsState's saved order), multi-selection, and a Hall of Fame reorder through the table's
// drop path into the store. Launch with `open -g -n`.
extension DebugHarness {
    static func reportsTableBehaviorScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-table-behavior")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) })
        else { r.check("setup", false, ""); return r }
        func settle(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
        func reportTable<Row>(_: Row.Type) -> (NSTableView, ReportTable<Row>.Coordinator)? {
            for t in tables(in: window.contentView!) {
                if let c = t.dataSource as? ReportTable<Row>.Coordinator { return (t, c) }
            }
            return nil
        }
        let selection = SelectionState.shared
        let reports = ReportsState.shared

        // MARK: Cost tracker — selection, sort
        appState.navigate(to: .libraryItem(.reports))
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1200)
        guard let (costTable, _) = reportTable(ReleaseData.self) else {
            r.check("cost-table-found", false, "no ReportTable<ReleaseData> in the window")
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

        // A header click is NSTableView replacing its sortDescriptors; the delegate reports it.
        costTable.sortDescriptors = [NSSortDescriptor(key: "filmTitle", ascending: true)] + costTable.sortDescriptors
        await settle()
        let titleOrder = [KeyPathComparator(\ReleaseData.titleSort, order: .forward), KeyPathComparator(\ReleaseData.purchaseDate, order: .reverse)]
        let byTitle = ReleaseData.sorted(costRows, using: titleOrder)
        let saved = reports.savedSortOrder(for: .costTracker)
        r.check("header-sort-saved-as-comparators", saved == titleOrder, "\(String(describing: saved))")
        costTable.selectRowIndexes([0], byExtendingSelection: false)
        await settle()
        r.check("header-sort-reorders-rows", selection.selectedFilmIDs == [byTitle[0].filmID], "")
        // Restore the default so a later visit starts where a user's would.
        costTable.sortDescriptors = [NSSortDescriptor(key: "purchaseDate", ascending: false)]
        await settle()
        selection.clearImmediate()

        // MARK: Hall of Fame — selection, reorder
        reports.selectCategory(.hallOfFame, persist: false, immediate: true)
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

        // Drag rows 0 and 2 to above row 5: SwiftUI onMove / Array.move semantics.
        var expected = before
        expected.move(fromOffsets: [0, 2], toOffset: 5)
        let moved = hofCoordinator.move([0, 2], to: 5)
        await settle(600)
        r.check("hof-reorder-accepted", moved, "")
        r.check("hof-reorder-reaches-store", Array(coordinator.hallOfFameFilms.prefix(8)) == Array(expected.prefix(8)),
                "store head \(coordinator.hallOfFameFilms.prefix(4).map { $0.uuidString.prefix(4) })")
        let firstCell = hofTable.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityValue() as? String
        r.check("hof-positions-renumbered", firstCell == "1.", "first position cell \(String(describing: firstCell))")

        // MARK: Wishlist — rows present
        reports.selectCategory(.releaseWishlist, persist: false, immediate: true)
        await settle(800)
        let wishRows = WishlistRelease.rows(pairs: coordinator.getWishlistReleases())
        let wish = reportTable(WishlistRelease.self)
        r.check("wishlist-row-count", wish?.0.numberOfRows == wishRows.count,
                "\(String(describing: wish?.0.numberOfRows)) vs \(wishRows.count)")
        return r
    }
}

// MARK: - DataViz page measurements per mount
//
// `dataviz-measure` (opt-in, diagnostic): opens Visualizations and Insights from a table tab in
// the real window and prints every width the page laid out at (`DVCanvasPageView.
// debugLayoutLog`) with its time relative to the switch, plus the run-loop busy stretches,
// then does the same for leaving the tab. Launch with `open -g -n`.
extension DebugHarness {
    static func dataVizMeasureScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-measure")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else { return r }
        let reports = ReportsState.shared
        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        appState.navigate(to: .libraryItem(.reports))
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1200)
        // Warm: one visit so the cache-seeded path (the common one) is what gets measured.
        DVCanvasPageView.debugLayoutLog.removeAll()
        reports.selectCategory(.dataVisualizations, persist: false, immediate: true)
        await settle(1500)
        // Every visit, the first included, lays the page out at one width: the page is sized
        // to its clip view, so with "Show scroll bars: Always" it never lays out full-width
        // first and squeezes by the scroller's width afterward.
        func widths() -> Set<CGFloat> { Set(DVCanvasPageView.debugLayoutLog.map(\.width)) }
        let firstVisit = widths()
        r.check("first-visit-one-width", firstVisit.count == 1,
                "\(firstVisit.sorted()) (scroller style \(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay"))")
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1200)

        for pass in 0..<2 {
            DVCanvasPageView.debugLayoutLog.removeAll()
            recorder.reset()
            let t0 = CACurrentMediaTime()
            reports.selectCategory(.dataVisualizations, persist: false, immediate: true)
            await settle(1500)
            r.check("open\(pass)-one-width", widths().count == 1, "\(widths().sorted())")
            let stretches = recorder.reading(from: t0 * 1000, window: 1500)
            r.metric("open\(pass)-first-stretch", stretches.first, "ms")
            r.metric("open\(pass)-busy", stretches.busy, "ms")
            r.metric("open\(pass)-longest", stretches.longest, "ms")
            r.metric("open\(pass)-stretches", Double(stretches.stretches), "n")
            r.check("open\(pass)-log", true, DVCanvasPageView.debugLayoutLog.map {
                "+\(Fmt.fixed(($0.time - t0) * 1000, 0))ms w=\(Fmt.fixed($0.width, 0))"
            }.joined(separator: " | "))

            recorder.reset()
            let t1 = CACurrentMediaTime()
            reports.selectCategory(.costTracker, persist: false, immediate: true)
            await settle(1200)
            let closing = recorder.reading(from: t1 * 1000, window: 1200)
            r.metric("close\(pass)-first-stretch", closing.first, "ms")
            r.metric("close\(pass)-busy", closing.busy, "ms")
        }
        return r
    }
}

// MARK: - Reports loop, for an external profiler
//
// `reports-loop` (opt-in, no verdict): cycles the four Reports table tabs in the real window
// every 400 ms for ~20 s, so `sample <pid>` or Instruments can attach and profile the switch.
// Prints "REPORTS-LOOP START" to stdout when the cycling begins.
extension DebugHarness {
    static func reportsLoopScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-loop")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else { return r }
        appState.navigate(to: .libraryItem(.reports))
        let reports = ReportsState.shared
        // `-FTDebugReportsLoop dataviz` alternates Cost Tracker ↔ Visualizations instead.
        let dataviz = UserDefaults.standard.string(forKey: "FTDebugReportsLoop") == "dataviz"
        let tables: [ReportsCategory] = dataviz ? [.costTracker, .dataVisualizations]
                                                : [.costTracker, .priceTracker, .hallOfFame, .releaseWishlist]
        for t in tables { reports.selectCategory(t, persist: false, immediate: true); try? await Task.sleep(for: .milliseconds(500)) }
        print("REPORTS-LOOP START"); unsafe fflush(stdout)
        var switches = 0
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            for t in tables {
                reports.selectCategory(t, persist: false, immediate: true)
                switches += 1
                try? await Task.sleep(for: .milliseconds(dataviz ? 900 : 400))
            }
        }
        r.metric("switches", Double(switches), "n")
        return r
    }
}

// MARK: - Reports frames, as composited
//
// `reports-frames` (opt-in, diagnostic): what actually reaches the screen after a sub-tab switch.
// A background thread grabs the real main window's composited image from the window server
// every ~4 ms for 400 ms and keeps each frame that differs from the one before; the distinct
// frames are written as PNGs (named by milliseconds after the switch) under
// `<sandbox>/reports-frames/<switch>/`. A switch that is visually one step produces one new
// frame; staged content (placeholder → rows, a second reload, a layout shift) produces several.
// Launch with `open -g -n`, like `reports-hitch`.
extension DebugHarness {

    /// `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK but still answers for the
    /// process's own windows; reached through dlsym so the harness can use it.
    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    nonisolated private static let windowImage: WindowImageFn? = {
        guard let sym = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafe unsafeBitCast(sym, to: WindowImageFn.self)
    }()

    private final class FrameGrabber: Thread, @unchecked Sendable {
        let windowID: UInt32
        let origin: Double
        let duration: Double
        private let lock = NSLock()
        private var frames: [(time: Double, image: CGImage)] = []
        private var grabCount = 0
        /// Read under the lock: the harness reads it after a fixed settle, not a join, so a
        /// slow last grab can still be counting.
        var grabs: Int { lock.withLock { grabCount } }

        init(windowID: UInt32, origin: Double, duration: Double) {
            self.windowID = windowID; self.origin = origin; self.duration = duration
        }

        /// A coarse fingerprint: every 97th byte of the bitmap.
        private static func fingerprint(_ image: CGImage) -> [UInt8] {
            guard let data = image.dataProvider?.data, let bytes = unsafe CFDataGetBytePtr(data) else { return [] }
            let n = CFDataGetLength(data)
            return stride(from: 0, to: n, by: 97).map { unsafe bytes[$0] }
        }

        override func main() {
            guard let grab = unsafe DebugHarness.windowImage else { return }
            var last: [UInt8] = []
            while CACurrentMediaTime() * 1000 - origin < duration {
                // listOption 8 = optionIncludingWindow; imageOption 1|16 = boundsIgnoreFraming|nominalResolution
                if let image = unsafe grab(.null, 8, windowID, 1 | 16)?.takeRetainedValue() {
                    lock.withLock { grabCount += 1 }
                    let print = Self.fingerprint(image)
                    if print != last {
                        last = print
                        let t = CACurrentMediaTime() * 1000 - origin
                        lock.lock(); frames.append((t, image)); lock.unlock()
                    }
                }
                usleep(4000)
            }
        }

        func result() -> [(time: Double, image: CGImage)] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// `dataviz-window` (opt-in, visual): Visualizations and Insights in the real main window,
    /// captured to PNGs under `<sandbox>/dataviz-window/` at the top, scrolled, immediately
    /// after and settled after a width change, in dark appearance, and after a scope click.
    /// Launch with `open -g -n` (no focus needed); pass `-FTDebugDVCanvas YES` for the canvas.
    static func dataVizWindowScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "dataviz-window")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }),
              let grab = unsafe windowImage,
              let root = DebugSandbox.rootURL?.appendingPathComponent("dataviz-window") else {
            r.check("setup", false, ""); return r
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func shot(_ name: String) {
            if let image = unsafe grab(.null, 8, UInt32(window.windowNumber), 1 | 16)?.takeRetainedValue() {
                writePNG(image, to: root.appendingPathComponent("\(name).png"))
            }
        }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let startFrame = window.frame
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.minY, width: 1320, height: 860), display: true)
        appState.navigate(to: .libraryItem(.reports))
        ReportsState.shared.selectCategory(.dataVisualizations, persist: false, immediate: true)
        await settle(3000)
        shot("1-top")
        // A left-opening popover's arrow tip (the window's trailing edge, less its 1 pt
        // margin) on the content's leading edge — not 20 pt short of it, as when the
        // hosting controller's default size settled after the popover was shown.
        if let page = views(window.contentView!).compactMap({ $0 as? DVCanvasPageView }).first,
           let (popWindow, anchor) = page.debugShowFirstPopover() {
            await settle(800)
            r.check("popover-arrow-on-anchor", popWindow.frame.maxX <= anchor.minX + 0.5 && popWindow.frame.maxX >= anchor.minX - 2,
                    "popover \(popWindow.frame), anchor \(anchor)")
            shot("0-popover")
            popWindow.close()
            await settle(300)
        } else {
            r.check("popover-arrow-on-anchor", false, "no popover hotspot")
        }
        let scrollView = views(window.contentView!).compactMap { $0 as? NSScrollView }
            .filter { $0.documentView != nil }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        r.check("page-scroll-view", scrollView != nil, "")
        if let scrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1150))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await settle(40)
            shot("2-scrolled-immediate")
            await settle(500)
            shot("3-scrolled")
        }
        var f = window.frame; f.size.width -= 360
        window.setFrame(f, display: true)
        shot("4-narrow-immediate")
        await settle(600)
        shot("5-narrow")
        window.appearance = NSAppearance(named: .darkAqua)
        await settle(600)
        shot("6-dark")
        if let seg = views(window.contentView!).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.label(forSegment: 0) == "This Year" }) {
            seg.selectedSegment = 0
            seg.sendAction(seg.action, to: seg.target)
            await settle(600)
            shot("7-this-year")
            r.check("scope-segmented-found", true, "")
        } else {
            r.check("scope-segmented-found", false, "")
        }
        if let scrollView {
            // The lower sections, a screen at a time.
            for (i, y) in [2300.0, 3000, 3700, 4400, 5100].enumerated() {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                await settle(400)
                shot("7\(["a", "b", "c", "d", "e"][i])-lower-\(Int(y))")
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        if let scrollView {
            // The Viewing History controls row sits just under its band.
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1010))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        await settle(700)
        shot("8-light-controls")
        window.appearance = nil
        window.setFrame(startFrame, display: true)
        return r
    }

    static func reportsFramesScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-frames")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }),
              let root = DebugSandbox.rootURL?.appendingPathComponent("reports-frames") else {
            r.check("setup", false, "no app state, window or sandbox root")
            return r
        }
        unsafe r.check("window-image-available", windowImage != nil, "")
        try? FileManager.default.removeItem(at: root)
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        func capture(_ name: String, _ action: () -> Void) async {
            await settle(700)
            let origin = CACurrentMediaTime() * 1000
            let grabber = FrameGrabber(windowID: UInt32(window.windowNumber), origin: origin, duration: 400)
            grabber.start()
            try? await Task.sleep(for: .milliseconds(30))   // a baseline frame before the switch
            let t0 = CACurrentMediaTime() * 1000 - origin
            action()
            await settle(450)
            let frames = grabber.result()
            let dir = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var times: [String] = []
            for f in frames {
                let rel = Int((f.time - t0).rounded())
                times.append("\(rel)")
                unsafe writePNG(f.image, to: dir.appendingPathComponent(String(format: "%+05d.png", rel)))
            }
            r.metric("\(name)-distinct-frames", Double(frames.count), "frames")
            r.check("\(name)-frames", !frames.isEmpty, "grabs \(grabber.grabs); distinct frames at ms " + times.joined(separator: ", "))
        }

        appState.navigate(to: .libraryItem(.reports))
        let reports = ReportsState.shared
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1500)
        // Warm every tab once so the captures show revisits, the common case.
        for t in ReportsCategory.allCases.dropFirst() + [.costTracker] {
            reports.selectCategory(t, persist: false, immediate: true); await settle(600)
        }
        await capture("reports-cost-to-price") { reports.selectCategory(.priceTracker, persist: false, immediate: true) }
        await capture("reports-price-to-halloffame") { reports.selectCategory(.hallOfFame, persist: false, immediate: true) }
        await capture("reports-halloffame-to-wishlist") { reports.selectCategory(.releaseWishlist, persist: false, immediate: true) }
        await capture("reports-wishlist-to-cost") { reports.selectCategory(.costTracker, persist: false, immediate: true) }

        appState.navigate(to: .libraryItem(.recents))
        await settle(1500)
        let recents = RecentsCategory.allCases
        await capture("recents-1") { RecentsState.shared.selectCategory(recents[1], persist: false, immediate: true) }
        await capture("recents-2") { RecentsState.shared.selectCategory(recents[2], persist: false, immediate: true) }

        if let parent = SmartListType.sidebarCases.first(where: { $0.familyVariants.count > 1 }) {
            appState.navigate(to: .smartList(parent))
            await settle(1500)
            await capture("smartlist-variant") { SmartListVariantState.shared(for: parent).select(parent.familyVariants[1], immediate: true) }
        }
        r.metric("written-to-\(root.path)", 0, "path")
        return r
    }
}

// MARK: - releases-settle
//
// The Releases tab's deferred work against a save, and the load repairs a save must carry.
// Headless on purpose: every behavior checked here now lives in FSTabReleases, and proving it
// runs with NO card mounted is the point of moving the independence cascade off the view.
//
//   • delete-settle      — a save mid-fly-up deletes the release, and the fly-up's own
//                          completion afterwards changes nothing.
//   • combo-settle       — a save inside the 120 ms reconciliation window creates the child,
//                          exactly once.
//   • cascade-headless   — the Type change's dependent fields move with no card mounted.
//   • orphan-children    — a Standalone 4K holding a child: retyping removes it (the
//                          alert's promise), via the save-time settle.
//   • confirmed-settle   — a confirmed type-change alert whose write is still deferred is
//                          carried by a save landing in that turn, and not applied twice.
//   • load-repairs       — Case C / D repairs reach `toUpdate` with no user edit; an
//                          unrepaired release does not.
//   • display-numbers    — per-format card numbering, children unnumbered.
extension DebugHarness {

    /// A combo child whose every user-editable field matches a freshly created one, so
    /// retyping its parent needs no confirmation.
    private static func pristineChildSnapshot(id: UUID, parent: UUID, sortOrder: Int) -> ReleaseSnapshot {
        ReleaseSnapshot(id: id, format: ReleaseFormat.bluRay.rawValue,
                        independence: ReleaseIndependence.comboPack,
                        scanningMethod: ReleaseScanningMethod.progressive,
                        audioFormat: "DTS-HD MA", hasSubtitles: true,
                        nationalOrigin: ReleaseOrigin.domestic,
                        replicationType: ReleaseReplicationType.pressed,
                        regionLock: ReleaseRegionRules.regionFree,
                        marketAvailability: [ReleaseMarketAvailability.comboPackOnly],
                        condition: ReleaseCondition.new,
                        sortOrder: sortOrder, parentReleaseID: parent)
    }

    static func releasesSettleScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "releases-settle")
        let bd = ReleaseFormat.bluRay.rawValue, uhd = ReleaseFormat.uhd4K.rawValue

        // --- fixtures -------------------------------------------------------------------
        let a = UUID(), b = UUID()
        let fDelete = makeSnapshot(name: "Settle Delete", releases: [
            ReleaseSnapshot(id: a, format: bd, independence: ReleaseIndependence.standalone, sortOrder: 0),
            ReleaseSnapshot(id: b, format: bd, independence: ReleaseIndependence.standalone, sortOrder: 1)])

        let p = UUID()
        let fCombo = makeSnapshot(name: "Settle Combo", releases: [
            ReleaseSnapshot(id: p, format: uhd, independence: ReleaseIndependence.standalone,
                            hasArtwork: "Yes", sortOrder: 0)])

        let q = UUID(), c = UUID()
        let fOrphan = makeSnapshot(name: "Settle Orphan", releases: [
            ReleaseSnapshot(id: q, format: uhd, independence: ReleaseIndependence.standalone,
                            sortOrder: 0, childReleaseIDs: [c]),
            pristineChildSnapshot(id: c, parent: q, sortOrder: 1)])

        let rep = UUID(), repChild = UUID(), inverted = UUID(), clean = UUID()
        let fRepair = makeSnapshot(name: "Settle Repair", releases: [
            // Case D: says dual BD, holds one child.
            ReleaseSnapshot(id: rep, format: uhd, independence: ReleaseIndependence.comboPackDualBD,
                            sortOrder: 0, childReleaseIDs: [repChild]),
            pristineChildSnapshot(id: repChild, parent: rep, sortOrder: 1),
            // Case C: base year after the release year.
            ReleaseSnapshot(id: inverted, releaseYear: "2010", baseReleaseYear: "2012", format: bd,
                            independence: ReleaseIndependence.standalone, sortOrder: 2),
            ReleaseSnapshot(id: clean, releaseYear: "2010", format: bd,
                            independence: ReleaseIndependence.standalone, sortOrder: 3)])

        let fixtures = [fDelete, fCombo, fOrphan, fRepair]
        coordinator.importFilms(fixtures)

        // --- delete-settle --------------------------------------------------------------
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
            // A second delete still works after the settled one.
            vm.deleteRelease(id: b)
            try? await Task.sleep(for: .milliseconds(450))
            r.check("delete-settle/next-delete-completes", vm.releases.isEmpty, "\(vm.releases.count) left")
        }

        // --- combo-settle + cascade-headless -------------------------------------------
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

            // confirmed-settle: edit the child so the downgrade must be confirmed.
            let child = vm.model(created[0].id)!
            child.notes = "edited"
            vm.requestIndependenceChange(on: parent, to: ReleaseIndependence.multiPack)
            r.check("confirmed-settle/not-written-before-confirm",
                    parent.independence == ReleaseIndependence.comboPack, parent.independence)
            // The confirmation presents as a sheet on the key window (NSAlert presenter),
            // so one is supplied; it is answered through the alert's own completion handler.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(250))
            r.check("confirmed-settle/prompt-presented", vm.isConfirmationPresented,
                    "attached sheet: \(window.attachedSheet != nil)")
            if let alertSheet = window.attachedSheet {
                // First button == the confirm button ("Change and Remove").
                window.endSheet(alertSheet, returnCode: .alertFirstButtonReturn)
            } else if vm.isConfirmationPresented {
                vm.confirmation.isPresented = false
                vm.confirmation.resolve(confirmed: true)
            }
            r.check("confirmed-settle/answered-synchronously", !vm.isConfirmationPresented, "")
            let after = vm.buildReleaseDeltas()      // same turn as the confirmation
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
            window.close()
        }

        // --- orphan-children (3b) ----------------------------------------------------------
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

        // --- load-repairs ----------------------------------------------------------------
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
//
// FilmSheet save-path and load-path invariants that need no view:
//
//   • disc-total        — a save landing mid-fly-up of a purchased release's delete stores
//                         a disc total that excludes it (FilmSheet.confirm settles the
//                         Releases tab before assembling the film).
//   • frame-rate        — an out-of-vocabulary stored frame rate survives the Metadata
//                         tab's load unchanged; a near-miss snaps to its option.
//   • release-year      — the Details tab's derived release year agrees with the year the
//                         saved release date string carries.
//   • frames-pad        — a padded half of a frames row repeats the other half's flags.
//   • duration          — a stored runtime with seconds survives a save that did not
//                         edit it; editing the minutes writes the picker's value.
//   • list-settle       — a list commit still held for its popover's close animation
//                         lands in a save that starts inside the hold, exactly once; one
//                         that stopped at its duplicate prompt blocks the save instead;
//                         and an unsettled commit still runs on its own timer, as before.
extension DebugHarness {

    static func filmSheetSaveScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "filmsheet-save")
        let bd = ReleaseFormat.bluRay.rawValue

        // --- fixtures -------------------------------------------------------------------
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

        // 1:26:46.785 and 1:59:59.000 — seconds the whole-minute pickers cannot show.
        var fDuration = makeSnapshot(name: "Save Duration Precise")
        fDuration.duration = "5206785"
        fDuration.edited = true
        fDuration.editedDuration = "7199000"

        let fSettle = makeSnapshot(name: "Save List Settle")
        let fPrompt = makeSnapshot(name: "Save List Prompt")

        let fixtures = [fDiscs, fOddRate, fNearRate, fDate, fDuration, fSettle, fPrompt]
        coordinator.importFilms(fixtures)

        // --- disc-total -----------------------------------------------------------------
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

        // --- frame-rate -----------------------------------------------------------------
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

        // --- release-year ---------------------------------------------------------------
        do {
            let details = FilmSheet(coordinator: coordinator, filmID: fDate.id).detailsTab!
            let fields = details.collectFilmFields()
            r.check("release-year/derived", details.releaseYear == 2026, "releaseYear \(details.releaseYear)")
            r.check("release-year/matches-saved-date",
                    fields.releaseYear == String(fields.releaseDate.prefix(4)),
                    "releaseYear \(fields.releaseYear) vs releaseDate \(fields.releaseDate)")
        }

        // --- duration -------------------------------------------------------------------
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

            // A real save of an unrelated edit must not touch either runtime.
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

        // --- list-settle ----------------------------------------------------------------
        //
        // The commits below are what the three tables hand `ListPopoverDismissal`: a write
        // through the tab's view model, held for the popover's close animation (220 ms).
        do {
            // No leftovers from anything earlier in the run.
            ListPopoverDismissal.settlePending()

            // Timer path unchanged: a commit nobody settles runs by itself, once.
            var timerRuns = 0
            ListPopoverDismissal.afterClose { timerRuns += 1 }
            r.check("list-settle/held-until-close", timerRuns == 0 && ListPopoverDismissal.pendingCount == 1,
                    "runs \(timerRuns), pending \(ListPopoverDismissal.pendingCount)")
            for _ in 0..<50 where timerRuns == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(100))
            r.check("list-settle/timer-runs-once", timerRuns == 1 && ListPopoverDismissal.pendingCount == 0,
                    "runs \(timerRuns), pending \(ListPopoverDismissal.pendingCount)")

            // Order: settled in the order scheduled, and a settled commit's timer is inert.
            var order: [Int] = []
            ListPopoverDismissal.afterClose { order.append(1) }
            ListPopoverDismissal.nextTurn { order.append(2) }
            ListPopoverDismissal.afterClose { order.append(3) }
            let promptedOrder = ListPopoverDismissal.settlePending()
            r.check("list-settle/scheduling-order", order == [1, 2, 3] && !promptedOrder, "\(order)")
            try? await Task.sleep(for: .milliseconds(300))
            r.check("list-settle/no-second-run", order == [1, 2, 3], "\(order)")

            // The race itself: an add still held when the save starts is in the saved film.
            let sheet = FilmSheet(coordinator: coordinator, filmID: fSettle.id)
            let notes = sheet.notesTab!
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            notes.tools = ["Edited"]   // the sheet's other change, so it is saveable
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

            // A commit parked behind its duplicate prompt: nothing to save yet, so no save.
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
            // Once the prompt is answered the next save goes through.
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

        // --- frames-pad -----------------------------------------------------------------
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

        // Let the save's background persist land before the fixtures are removed.
        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: Set(fixtures.map(\.id))) {}
        return r
    }
}

// MARK: - return-key-policy
//
// The FilmSheet's Return rule, driven with genuine key events through NSApp against the real
// FilmSheetView in a key window: an active text field takes Return first — the first press
// finishes editing and saves nothing — and the next press, with no field active, saves.
// Needs an unlocked screen (a key window); see the harness-needs-unlocked-screen note.
//
// KeyboardManager's intercept needs a presented sheet and is not exercised; the save on the
// second press here comes from the sheet's default-action button, which applies the same
// canConfirm test.
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
            let isKey = await makeKey(window)
            for _ in 0..<6 { await oneRunLoopTurn() }
            try? await Task.sleep(for: .milliseconds(250))   // deferred Synopsis wave
            host.layoutSubtreeIfNeeded()

            sheet.detailsTab.userRating = sheet.detailsTab.userRating == 5 ? 6 : 5
            try? await Task.sleep(for: .milliseconds(100))
            let target = focus(window, host)
            try? await Task.sleep(for: .milliseconds(100))
            r.check("\(label)/window-key", isKey && window.isKeyWindow, "screen locked?")
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


// MARK: - Sheet hitch, in the real window
//
// `sheet-hitch` (opt-in, a measurement): presents the List Manager and Settings over
// Visualizations and Insights, over a Reports table tab and over Recents, in the real main
// window, and counts the animation frames the window server actually showed. AppKit runs a
// sheet's slide inside one long run-loop pass, so run-loop stretches cannot see it; instead a
// background thread polls CGWindowListCopyWindowInfo every 2 ms for 700 ms and counts the
// distinct (bounds, alpha) states of the app's windows — each one is a frame that reached the
// screen. A smooth ~0.25 s slide shows tens; a stuttering one, a handful. Also reports the
// DataViz section body evaluations per presentation. The app is activated first: the stutter
// depends on the main window giving up key status to the sheet.
extension DebugHarness {

    private final class WindowStatePoller: Thread, @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String] = []
        private var times: [Double] = []
        private var running = true
        override func main() {
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            var last = ""
            while lock.withLock({ running }) {
                let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
                let key = mine.map { "\($0[kCGWindowNumber as String] ?? 0):\($0[kCGWindowBounds as String] ?? ""):\($0[kCGWindowAlpha as String] ?? "")" }
                    .sorted().joined(separator: "|")
                if key != last { let t = CACurrentMediaTime(); lock.withLock { states.append(key); times.append(t) }; last = key }
                usleep(2000)
            }
        }
        func finish() -> Int { lock.withLock { running = false; return states.count } }
        /// The longest wait between two consecutive window states while the animation ran
        /// (from the first change to the last), in ms: a frame the screen did not get.
        func maxGapMs() -> Double {
            lock.withLock {
                guard times.count > 2 else { return 0 }
                return zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.max() ?? 0
            }
        }
        /// The wait from the request to the first changed window state: latency, not stutter.
        func firstFrameMs() -> Double {
            lock.withLock { times.count > 1 ? (times[1] - times[0]) * 1000 : 0 }
        }
        /// The longest wait between window states once the first change has shown: the
        /// stutter inside the animation itself.
        func maxGapAfterFirstMs() -> Double {
            lock.withLock {
                guard times.count > 3 else { return 0 }
                let later = Array(times.dropFirst())
                return zip(later.dropFirst(), later).map { ($0 - $1) * 1000 }.max() ?? 0
            }
        }
    }

    /// The main thread's CPU time so far, in ms. Called on the main thread.
    private static func mainThreadCPUms() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { unsafe mach_port_deallocate(mach_task_self_, port) }
        let kr = unsafe withUnsafeMutablePointer(to: &info) {
            unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { unsafe thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    static func sheetHitchScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "sheet-hitch")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        NSApp.activate()
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        await settle(800)
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
        r.check("real-window-key", window?.isKeyWindow == true, "key \(String(describing: window?.isKeyWindow))")
        let sheets = appState.sheetCoordinator
        let filmIDs = Set(coordinator.getAllFilms().prefix(40).map(\.id))

        var frames: [String: [Int]] = [:]
        var draws: [String: [Int]] = [:]
        var cpu: [String: [Double]] = [:]
        var gaps: [String: [Double]] = [:]
        var firsts: [String: [Double]] = [:]
        var inGaps: [String: [Double]] = [:]
        DVCanvasPageView.drawCalls = 0
        func timed(_ kind: String, _ action: () -> Void) async {
            let poller = WindowStatePoller()
            poller.start()
            let d0 = DVCanvasPageView.drawCalls
            let c0 = mainThreadCPUms()
            action()
            await settle(700)
            cpu[kind, default: []].append(mainThreadCPUms() - c0)
            frames[kind, default: []].append(poller.finish())
            gaps[kind, default: []].append(poller.maxGapMs())
            firsts[kind, default: []].append(poller.firstFrameMs())
            inGaps[kind, default: []].append(poller.maxGapAfterFirstMs())
            draws[kind, default: []].append(DVCanvasPageView.drawCalls - d0)
        }
        func present(_ kind: String, _ request: () -> Void) async {
            await settle(600)
            await timed("\(kind)-open", request)
            await timed("\(kind)-close") { sheets.activeSheet = nil }
            await settle(400)
        }
        func round(_ background: String) async {
            for _ in 0..<3 {
                await present("\(background)-list") {
                    AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs, prefillName: "Probe"))
                }
                await present("\(background)-settings") { AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .general)) }
                // The Needs Attention path: a popover (key while shown) closes in the same
                // turn the List Manager is requested, as DVAttentionPopover's button does.
                guard let anchor = window?.contentView else { continue }
                let popover = NSPopover()
                popover.behavior = .transient
                popover.contentViewController = NSHostingController(rootView: Text("Probe").frame(width: 300, height: 400))
                popover.show(relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1), of: anchor, preferredEdge: .maxY)
                unsafe popover.contentViewController?.view.window?.makeKey()
                await present("\(background)-popover-list") {
                    AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs, prefillName: "Probe"))
                    popover.performClose(nil)
                }
            }
        }

        let reports = ReportsState.shared
        appState.navigate(to: .libraryItem(.reports))
        reports.selectCategory(.dataVisualizations, persist: false, immediate: true)
        await settle(2500)
        if let loop = UserDefaults.standard.string(forKey: "FTDebugSheetLoop") {
            if loop == "table" { reports.selectCategory(.costTracker, persist: false, immediate: true) }
            if loop == "recents" { appState.navigate(to: .libraryItem(.recents)) }
            await settle(1500)
            print("SHEET-LOOP START"); unsafe fflush(stdout)
            let end = ContinuousClock.now + .seconds(25)
            while ContinuousClock.now < end {
                await present("loop") {
                    AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs, prefillName: "Probe"))
                }
            }
            return r
        }
        let canvasDraws0 = DVCanvasPageView.drawCalls
        await round("dataviz")
        r.metric("dataviz-canvas-draw-calls-during-sheets", Double(DVCanvasPageView.drawCalls - canvasDraws0), "n")
        reports.selectCategory(.costTracker, persist: false, immediate: true)
        await settle(1500)
        await round("table")
        appState.navigate(to: .libraryItem(.recents))
        await settle(1500)
        await round("recents")

        for (kind, counts) in frames.sorted(by: { $0.key < $1.key }) {
            r.metric("\(kind)-main-cpu-median", stats(cpu[kind] ?? []).median, "ms")
            r.metric("\(kind)-frames", counts.map(Double.init).sorted()[counts.count / 2], "n")
            r.metric("\(kind)-max-frame-gap-median", stats(gaps[kind] ?? []).median, "ms")
            r.metric("\(kind)-first-frame-median", stats(firsts[kind] ?? []).median, "ms")
            r.metric("\(kind)-gap-in-animation-median", stats(inGaps[kind] ?? []).median, "ms")
            r.check("\(kind)-frames-all", true, counts.map(String.init).joined(separator: ","))
            // The page draws nothing when a sheet or popover changes the window's key state.
            if kind.hasPrefix("dataviz") {
                r.check("\(kind)-page-draws-nothing", (draws[kind] ?? []).allSatisfy { $0 == 0 },
                        (draws[kind] ?? []).map(String.init).joined(separator: ","))
            }
        }
        return r
    }
}

// MARK: - queue-add-confirm, tab-cycle, report-gutter-deselect, jump-menu-width
//
// queue-add-confirm: the "Add to Queue" menus' single entry point (FilmQueueAssignment.toggle)
// honors Preferences.confirmFilmQueueAdd — a flagged film raises the alert in the real main
// window instead of being added, "Add Anyway" adds it, and an unflagged film or a disabled
// preference adds straight through.
// tab-cycle: Cmd+Down/Up posted through the event queue (so KeyboardManager's local monitor
// sees them) steps a view's own tabs (Recents, Unwatched, the six-variant Filtered Library),
// wraps, and passes through while a text field is editing; the FilmSheet cycle command steps
// and wraps.
// report-gutter-deselect: a click in a ReportTable's inset margin clears the selection.
// jump-menu-width (opt-in, not in `all`): the Releases jump menu keeps one width with and
// without the cart glyph. Its width checks have always passed, but about one run in four
// never sees a purchased row, so its precondition check fails intermittently.
// All four need an unlocked screen (a key window).
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
        coordinator.importFilms([flagged, plain])
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        // Flagged film, preference on: deferred to the alert, nothing added yet.
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

        // Unflagged film, preference on: straight through.
        received.removeAll()
        FilmQueueAssignment.toggle([plain.id], section: section, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(900))
        r.check("plain/no-alert", received.isEmpty && window.attachedSheet == nil, "")
        r.check("plain/added", inQueue(plain.id), "")
        FilmManager.removeFromFilmQueue([plain.id], coordinator: coordinator)

        // Flagged film, preference off: straight through.
        Preferences.confirmFilmQueueAdd = false
        received.removeAll()
        FilmQueueAssignment.toggle([flagged.id], section: section, coordinator: coordinator)
        try? await Task.sleep(for: .milliseconds(900))
        r.check("pref-off/no-alert", received.isEmpty && window.attachedSheet == nil, "")
        r.check("pref-off/added", inQueue(flagged.id), "")
        FilmManager.removeFromFilmQueue([flagged.id], coordinator: coordinator)

        try? await Task.sleep(for: .milliseconds(300))
        await coordinator.deleteFilms(withIDs: [flagged.id, plain.id]) {}
        return r
    }

    // alert-host: AlertHostView in the real main window. Any of its alerts raises
    // AppState.isHostAlertActive (the MenuBar lock), "Library Could Not Be Read" included;
    // a confirmed removal clears the selection only when its sender asked; the Queue alert
    // uses the FilmSheet's title and wording, tags in canonical order; a drop arriving under
    // an open Queue alert cannot retarget it; a backup-open under another alert is dropped.
    static func alertHostScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "alert-host")
        var flagged = makeSnapshot(name: "Alert Host Flagged")
        flagged.specialSorting = [FilmSpecialSorting.canonicalOrder[1], FilmSpecialSorting.canonicalOrder[0]]
        let a = makeSnapshot(name: "Alert Host A")
        let b = makeSnapshot(name: "Alert Host B")
        coordinator.importFilms([flagged, a, b])
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        let isKey = await makeKey(window)
        try? await Task.sleep(for: .milliseconds(300))
        r.check("window-key", isKey, "screen locked?")
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

        // Confirmed removal, sender asked NOT to clear (MenuBar / Opt+Delete).
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

        // Library read failure locks the menu too; Continue Anyway releases it.
        AppEventBus.shared.sendAlert(.showLibraryReadFailure)
        await settle()
        r.check("read-failure/menu-locked", appState.isHostAlertActive && window.attachedSheet != nil, "")
        // A backup-open arriving under it is dropped rather than queued behind it.
        AppEventBus.shared.sendAlert(.showBackupRestoreAlert(type: "restore",
                                                            file: URL(fileURLWithPath: "/tmp/none.ftbackup")))
        await settle(300)
        button("Continue Anyway")?.performClick(nil)
        await settle(1_200)
        r.check("read-failure/released", !appState.isHostAlertActive, "")
        r.check("backup-open/not-queued", window.attachedSheet == nil, "a sheet surfaced after dismissal")

        // Queue alert: FilmSheet title and wording, canonical tag order; a drop under it is ignored.
        let saved = Preferences.confirmFilmQueueAdd
        defer { Preferences.confirmFilmQueueAdd = saved }
        Preferences.confirmFilmQueueAdd = true
        let section = FilmQueueSection.upNext
        FilmQueueAssignment.toggle([flagged.id], section: section, coordinator: coordinator)
        await settle(900)
        let shown = texts()
        let tags = FilmSpecialSorting.canonicalOrder.prefix(2).map { "\"\($0)\"" }.joined(separator: ", ")
        let expected = "Are you sure you want to add this film to the Queue? It is flagged with the special sorting parameters \(tags)."
        r.check("queue/title", shown.contains("Add to Queue"), shown.joined(separator: " | "))
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

    // alert-collision: requests that arrive while an AlertHostView alert is open. Each waits
    // its turn in arrival order and acts on its OWN payload — a second request can neither
    // retarget the open alert nor lose itself (both happened when every alert was a flag
    // over shared payload fields); the menu stays locked across the hand-off between
    // them; and a burst of one notice is a single alert carrying the latest detail.
    static func alertCollisionScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "alert-collision")
        let a = makeSnapshot(name: "Collision A")
        let b = makeSnapshot(name: "Collision B")
        coordinator.importFilms([a, b])
        guard let appState = AppDelegate.appState else { r.check("app-state", false, ""); return r }
        guard let window = mainHarnessWindow() else { r.check("main-window", false, ""); return r }
        let isKey = await makeKey(window)
        r.check("window-key", isKey, "screen locked?")
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

        // 1. A background error under a confirmation waits; the confirmation acts first.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "collision fault"))
        await settle()
        r.check("error-under-confirm/confirm-stays", showing("Remove from All Lists"), texts().joined(separator: " | "))
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

        // 2. A different confirmation under a confirmation: both, in order, each on its own films.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.confirmRemoveFromList(filmIDs: [b.id], listID: listL,
                                                            listName: "Collision L", clearingSelection: false))
        await settle()
        r.check("two-kinds/first-shown", showing("Remove from All Lists"), texts().joined(separator: " | "))
        click("Remove")
        await settle(1_200)
        r.check("two-kinds/second-shown", showing("Remove from List"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("two-kinds/each-acted", lists(a.id).isEmpty && lists(b.id) == [listM],
                "A in \(lists(a.id).count), B in \(lists(b.id).count)")
        await clearAll()

        // 3. The same confirmation twice: the open alert keeps its films; the second waits.
        reset()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [a.id], clearingSelection: false))
        await settle()
        AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: [b.id], clearingSelection: false))
        await settle()
        click("Remove")
        await settle(1_200)
        r.check("same-kind/first-acts-on-its-own-films", lists(a.id).isEmpty && lists(b.id).count == 2,
                "A in \(lists(a.id).count), B in \(lists(b.id).count)")
        r.check("same-kind/second-shown", showing("Remove from All Lists"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("same-kind/second-acts", lists(b.id).isEmpty, "B in \(lists(b.id).count)")
        await clearAll()

        // 4. "Remove from List" then "Remove List": no shared list context between them.
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
        r.check("list-context/second-shown", showing("Remove List"), texts().joined(separator: " | "))
        click("Remove")
        await settle(900)
        r.check("list-context/list-removed", coordinator.getList(listM) == nil, "")
        await clearAll()

        // 5. A burst of one notice is one alert, carrying the latest detail.
        // The alert reads the stored switch, not Preferences.loggingEnabled (forced on in a
        // sandbox); with it off, the detail is in the message.
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

        // 6. A later failure while the first is ON SCREEN does not stack a second alert.
        // (The open alert keeps the text it was drawn with; SwiftUI does not redraw an
        // open alert, and never did here.)
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "early fault"))
        await settle()
        AppEventBus.shared.sendAlert(.showPersistenceFailure(error: "later fault"))
        await settle()
        click("OK")
        await settle(1_200)
        r.check("burst/open-alert-single", window.attachedSheet == nil && !appState.isHostAlertActive,
                texts().joined(separator: " | "))
        await clearAll()

        // 7. A second backup-open while the restore prompt is ON SCREEN retargets it: Open
        // Settings opens the second file. The Settings sheet this opens is closed again.
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
        r.check("backup/prompt-shown", showing("Restore from Backup"), texts().joined(separator: " | "))
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
        let isKey = await makeKey(window)
        try? await Task.sleep(for: .milliseconds(200))
        r.check("window-key", isKey && window.isKeyWindow, "screen locked?")

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

        // Recents: five tabs, forward through all of them and back around.
        let recents = RecentsState.shared
        appState.navigate(to: .libraryItem(.recents))
        try? await Task.sleep(for: .milliseconds(400))
        recents.selectCategory(.recentlyViewed)
        try? await Task.sleep(for: .milliseconds(200))
        var seen: [RecentsCategory] = []
        for _ in 0..<5 { await postArrow(down: true); seen.append(recents.selectedCategory) }
        r.check("recents/down-steps-and-wraps",
                seen == [.recentlyRotated, .recentlyAdded, .recentlyUpdated, .recentlyPurchased, .recentlyViewed],
                seen.map { "\($0)" }.joined(separator: ","))
        await postArrow(down: false)
        r.check("recents/up-wraps", recents.selectedCategory == .recentlyPurchased, "\(recents.selectedCategory)")

        // Text editing owns Cmd+Up/Down (move to beginning/end of document).
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        window.contentView?.addSubview(field)
        // Re-keyed first: navigation can leave the window unkeyed, and the text-input test
        // (like the user's typing) only applies to the key/main window.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(200))
        r.check("recents/field-editing", window.firstResponder is NSTextView && window.isKeyWindow,
                "responder \(String(describing: window.firstResponder.map { type(of: $0) })), key \(window.isKeyWindow)")
        await postArrow(down: true)
        r.check("recents/text-editing-passes-through", recents.selectedCategory == .recentlyPurchased,
                "\(recents.selectedCategory)")
        window.makeFirstResponder(nil)
        field.removeFromSuperview()

        // Unwatched: two tabs.
        let unwatched = UnwatchedState.shared
        appState.navigate(to: .libraryItem(.unwatched))
        try? await Task.sleep(for: .milliseconds(400))
        unwatched.selectCategory(.unwatched)
        await postArrow(down: true)
        r.check("unwatched/down", unwatched.selectedCategory == .notRated, "\(unwatched.selectedCategory)")
        await postArrow(down: true)
        r.check("unwatched/wraps", unwatched.selectedCategory == .unwatched, "\(unwatched.selectedCategory)")

        // Filtered Library: six variants, all reachable (Opt+Cmd+# stops at five).
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

        // Opt+Cmd+N selects tab N in every tabbed view — every tab has its own digit.
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
            // Backward, so a tab already selected on arrival cannot pass vacuously.
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
                          [RecentsCategory.recentlyViewed, .recentlyRotated, .recentlyAdded, .recentlyUpdated, .recentlyPurchased]) {
            RecentsState.shared.selectedCategory }
        await checkDigits("reports", .libraryItem(.reports),
                          [ReportsCategory.costTracker, .priceTracker, .hallOfFame, .releaseWishlist, .dataVisualizations]) {
            ReportsState.shared.selectedCategory }
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

        // FilmSheet: the cycle command the sheet branch sends.
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
        let table = ReportTable(rows: rows,
                                columns: [ReportTableColumn(id: "name", title: "Name", width: 200,
                                                            minWidth: 100, maxWidth: 1000,
                                                            content: .text { $0.name })],
                                selection: Binding(get: { box.selection }, set: { box.selection = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: table.frame(width: 500, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<6 { await oneRunLoopTurn() }
        host.layoutSubtreeIfNeeded()
        guard let tv = harnessViews(host).compactMap({ $0 as? ReportNSTableView }).first else {
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
            // Queued first, so NSTableView's own tracking loop (row clicks) finds its mouseUp.
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
        try? await Task.sleep(for: .milliseconds(100))
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
        // One purchased row and one unpurchased row, whichever indexes the sort put them at,
        // each visited by waiting for the carousel to actually arrive there.
        // The rows are rebuilt as the sheet's releases finish loading; wait until the menu
        // shows all three and has held still for half a second.
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
            // The alignment rect is what SwiftUI sizes; the frame adds the bezel's insets.
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

#endif
