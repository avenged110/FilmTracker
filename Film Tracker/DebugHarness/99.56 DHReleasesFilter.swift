// MARK: - DHReleasesFilter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only scenario for the right sidebar Releases tab's purchase filter animation
// (24.20 RTabReleases.swift).
//
// `releases-filter` drives the REAL main window: it selects a film whose disc releases are
// a mix of purchased and unpurchased, shows the Releases tab, and switches the filter
// through the same @State the segmented picker writes. While each switch runs, the sidebar
// scroll view's rectangle is filmed through the window server (the capture loop is
// `film(windowID:rect:origin:duration:)` from 99.54), and a 2 ms main-thread sampler records
// the AppKit geometry — the document view's height, the hosting view's frame and its
// intrinsic height, and the clip view's offset — so a jump in the pixels can be matched
// to the layer that moved.
//
// Each distinct frame is written as a PNG to `harness-reports/releases-filter/`, and the
// picker's on-screen displacement is measured per frame by matching the first frame's
// luminance profile of the picker's rows against every later frame. The picker must never
// move, so any nonzero displacement is reported as a failure.
//
// `details-expand` films the Details tab's Viewing History table expanding and collapsing
// (24.10 RTabDetails.swift) the same way, holding the Watch Details module above the table
// still. Its frames go to `harness-reports/details-expand/`.

#if DEBUG

import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// The harness's handle on RTabReleases' filter. Set while the tab is mounted; takes the
/// filter's raw value ("all", "purchased", "unpurchased").
@MainActor
enum ReleasesFilterProbe {
    static var select: ((String) -> Void)?
}

/// The harness's handle on the Details tab's table expansion flags (RTabDetailsContent).
/// Takes the table ("calendar" or "list") and the new value.
@MainActor
enum DetailsExpandProbe {
    static var set: ((String, Bool) -> Void)?
    /// The RTabDetailsContent instance that installed `set`; only it may clear it.
    static var owner: UUID?
}

extension DebugHarness {

    static func runReleasesFilterScenario(_ scenario: String,
                                          coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "releases-filter": return await releasesFilterScenario(coordinator: coordinator)
        case "details-expand":  return await detailsExpandScenario(coordinator: coordinator)
        default: return nil
        }
    }

    /// One main-thread geometry sample.
    private struct GeometrySample {
        let ms: Double
        let documentHeight: CGFloat
        let hostY: CGFloat
        let hostHeight: CGFloat
        let intrinsicHeight: CGFloat
        let clipY: CGFloat
    }

    private static func releasesFilterScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "releases-filter")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard (session?["CGSSessionScreenIsLocked"] as? Bool) != true else {
            r.skip("screen-unlocked", "the screen is locked; re-run while someone is at the Mac")
            return r
        }
        guard unsafe windowImageFunction != nil else {
            r.check("capture-available", false, "CGWindowListCreateImage did not resolve")
            return r
        }
        if let reason = await keyWindowUnavailable(window) {
            r.skip("window-key", reason)
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        // A film with few disc releases, at least one purchased and one not — the case the
        // filter visibly changes. Fewest first, so the whole stack fits the viewport.
        func discReleases(_ film: FilmSnapshot) -> [ReleaseSnapshot] {
            film.releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
        }
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        let candidates = coordinator.films.filter { film in
            let discs = discReleases(film)
            return discs.count >= 3 && discs.contains(where: \.purchased) && discs.contains { !$0.purchased }
        }
        guard let subject = candidates.min(by: { discReleases($0).count < discReleases($1).count }) else {
            r.check("film", false, "no film with 3+ disc releases mixing purchased and unpurchased")
            return r
        }
        let discs = discReleases(subject)
        r.check("film", true, "\(subject.name): \(Fmt.int(discs.count)) disc releases, "
                + "\(Fmt.int(discs.filter(\.purchased).count)) purchased")

        ViewStateManager.shared.setRightSidebarTab(.releases)
        SelectionState.shared.selectImmediate(subject.id)
        await settle(1500)

        guard let sv = sidebarScrollView(in: window, hosting: "RTabReleasesContent") else {
            r.check("mounted", false, "Releases scroll view not found")
            return r
        }
        guard let select = ReleasesFilterProbe.select else {
            r.check("probe", false, "ReleasesFilterProbe.select not set")
            return r
        }
        select("all")
        sv.contentView.scroll(to: .zero)
        sv.reflectScrolledClipView(sv.contentView)
        await settle(800)

        let rect = captureRect(of: sv, in: window)
        let outDir = frameDirectory("releases-filter")

        // Three configurations: cards alone; the summary table above them, collapsed (a
        // fixed height); and the table auto-expanded, so its own height follows the filter
        // too. Preferences are the sandbox's, restored afterward.
        let store = Preferences.store
        let savedTable = store.object(forKey: Preferences.showReleasesSummaryTableKey)
        let savedExpand = store.object(forKey: Preferences.autoExpandRightSidebarTablesKey)
        defer {
            store.set(savedTable, forKey: Preferences.showReleasesSummaryTableKey)
            store.set(savedExpand, forKey: Preferences.autoExpandRightSidebarTablesKey)
        }
        let passes: [(name: String, table: Bool, expand: Bool)] = [
            ("cards", false, false), ("table", true, false), ("table-expanded", true, true)]
        let steps = ["purchased", "all", "unpurchased", "all"]
        for pass in passes {
            store.set(pass.table, forKey: Preferences.showReleasesSummaryTableKey)
            store.set(pass.expand, forKey: Preferences.autoExpandRightSidebarTablesKey)
            await settle(800)
            for (index, filter) in steps.enumerated() {
                let label = "\(pass.name)-\(Fmt.int(index + 1))-to-\(filter)"
                await settle(600)
                await recordStep(&r, label: label, window: window, scrollView: sv, rect: rect, outDir: outDir,
                                 trackedRows: 0..<44, trackedName: "picker") { select(filter) }
            }
        }

        // Switches faster than the fade: cards leave and come back mid-fade, and a film change
        // lands mid-fade. Once settled, every card shown is fully opaque, none is left fading,
        // and the stack holds one card per group.
        store.set(false, forKey: Preferences.showReleasesSummaryTableKey)
        let groupCount = releasesGroupedByHierarchy(discs).count
        let other = coordinator.films.first { f in f.id != subject.id
            && f.releases.contains { ReleaseFormat(rawValue: $0.format) != nil } }
        let bursts: [(name: String, steps: [String], gap: Int, film: Bool)] = [
            ("back-and-forth", ["purchased", "all", "purchased", "all"], 60, false),
            ("all-three", ["unpurchased", "purchased", "all", "unpurchased", "all"], 90, false),
            ("film-mid-fade", ["purchased"], 0, true)]
        for burst in bursts {
            await settle(800)
            for filter in burst.steps {
                select(filter)
                await settle(burst.gap)
            }
            if burst.film, let other {
                await settle(100)
                SelectionState.shared.selectImmediate(other.id)
                await settle(1200)
                SelectionState.shared.selectImmediate(subject.id)
            }
            await settle(1200)
            var pending: [NSView] = [sv]
            var found: RSBCardStackView?
            while found == nil, let view = pending.popLast() {
                found = view as? RSBCardStackView
                pending.append(contentsOf: view.subviews)
            }
            guard let stack = found else {
                r.check("burst-\(burst.name)", false, "no RSBCardStackView")
                continue
            }
            let state = stack.debugState
            // A film change returns the filter to All unless the preference keeps it.
            let kept = burst.film && store.bool(forKey: Preferences.rememberRightSidebarReleasesFilterKey)
            let expected = kept ? releasesGroupedByHierarchy(discs.filter(\.purchased)).count : groupCount
            r.check("burst-\(burst.name)", state.shown == expected && state.leaving == 0 && state.minOpacity > 0.999
                    && state.drawnHidden == 0,
                    "\(Fmt.int(state.shown)) shown of \(Fmt.int(expected)) groups\(kept ? " (filter kept)" : ""), \(Fmt.int(state.leaving)) leaving, "
                    + "lowest opacity \(Fmt.fixed(Double(state.minOpacity), 3)), \(Fmt.int(state.drawnHidden)) undrawn cards on screen")
        }

        // A row's text selected (the window's field editor showing it), then a new film: the
        // recycled label must show the new film's text, not the field editor's old copy.
        select("all")
        await settle(1200)
        func fields(_ root: NSView) -> [NSTextField] {
            var out: [NSTextField] = [], pending: [NSView] = [root]
            while let view = pending.popLast() {
                if let field = view as? NSTextField, field.isSelectable, !field.isHiddenOrHasHiddenAncestor { out.append(field) }
                pending.append(contentsOf: view.subviews)
            }
            return out
        }
        if let other, let field = fields(sv).first(where: { $0.stringValue.count > 8 }) {
            let before = field.stringValue
            window.makeKeyAndOrderFront(nil)
            field.selectText(nil)
            await settle(200)
            let editing = field.currentEditor() != nil
            SelectionState.shared.selectImmediate(other.id)
            await settle(1200)
            let stale = fields(sv).filter { f in f.currentEditor().map { $0.string != f.stringValue } ?? false }
            r.check("selection-then-new-film", editing && stale.isEmpty,
                    "editing \(editing), selected '\(before.prefix(30))', now '\(field.stringValue.prefix(30))', "
                    + "stale editors: \(stale.map { "'\($0.currentEditor()?.string.prefix(30) ?? "")' over '\($0.stringValue.prefix(30))'" })")
            window.makeFirstResponder(nil)
            SelectionState.shared.selectImmediate(subject.id)
            await settle(900)
        }
        select("all")
        return r
    }

    /// Films one animated change of a sidebar tab and checks that `trackedRows` (viewport
    /// rows that must not move) stay put in every frame. Logs the AppKit geometry timeline
    /// and writes each distinct frame as a PNG to `outDir`.
    /// Returns the document heights from the action onward — the height at the action
    /// first, then each one it changed to, in order.
    @discardableResult
    private static func recordStep(_ r: inout HarnessScenarioResult, label: String, window: NSWindow,
                                   scrollView sv: NSScrollView, rect: CGRect, outDir: URL?,
                                   trackedRows: Range<Int>, trackedName: String,
                                   action: () -> Void) async -> [CGFloat] {
        guard let document = sv.documentView, let host = document.subviews.first else {
            r.check("\(label)/mounted", false, "no hosting view")
            return []
        }
        var samples: [GeometrySample] = []
        let origin = ContinuousClock.now + .milliseconds(60)
        let sampler = Timer(timeInterval: 0.002, repeats: true) { _ in
            MainActor.assumeIsolated {
                samples.append(GeometrySample(
                    ms: signedMs(from: origin),
                    documentHeight: document.frame.height,
                    hostY: host.frame.minY,
                    hostHeight: host.frame.height,
                    intrinsicHeight: host.intrinsicContentSize.height,
                    clipY: sv.contentView.bounds.origin.y))
            }
        }
        RunLoop.main.add(sampler, forMode: .common)
        async let filmed = film(windowID: CGWindowID(window.windowNumber), rect: rect,
                                origin: origin, duration: .milliseconds(700))
        try? await Task.sleep(until: origin, clock: .continuous)
        action()
        let frames = await filmed
        sampler.invalidate()

        // Geometry: report each distinct value change, so the log reads as a timeline.
        var timeline: [String] = []
        var last: GeometrySample?
        for s in samples {
            if let l = last, l.documentHeight == s.documentHeight, l.hostY == s.hostY,
               l.hostHeight == s.hostHeight, l.intrinsicHeight == s.intrinsicHeight, l.clipY == s.clipY { continue }
            timeline.append("\(Fmt.fixed(s.ms, 1))ms doc \(Fmt.fixed(s.documentHeight, 1)) "
                            + "host y \(Fmt.fixed(s.hostY, 1)) h \(Fmt.fixed(s.hostHeight, 1)) "
                            + "intrinsic \(Fmt.fixed(s.intrinsicHeight, 1)) clip \(Fmt.fixed(s.clipY, 1))")
            last = s
        }
        r.check("\(label)/geometry", true, timeline.joined(separator: " | "))
        var heights: [CGFloat] = []
        for s in samples where s.ms >= 0 && heights.last != s.documentHeight { heights.append(s.documentHeight) }

        // Pixels: the tracked rows, frame by frame, against the SETTLED last frame — a
        // control in them (the filter picker) may change its look with the action, so the
        // first frame does not always match the later ones.
        guard let settled = frames.last, let settledProfile = rowProfile(settled.image) else {
            r.check("\(label)/frames", false, "no frames captured")
            return heights
        }
        let rows = trackedRows.clamped(to: 0..<settledProfile.count)
        var shifts: [String] = []
        var worst = 0
        for (n, frame) in frames.enumerated() {
            // Frames from before the action still show the old state.
            if frame.milliseconds < 0 { continue }
            if let outDir {
                writePNG(frame.image, to: outDir.appendingPathComponent(
                    unsafe "\(label)-\(String(format: "%03d", n))-\(Fmt.fixed(frame.milliseconds, 0))ms.png"))
            }
            guard let profile = rowProfile(frame.image) else { continue }
            let shift = profileShift(source: settledProfile, rows: rows, target: profile)
            worst = max(worst, abs(shift))
            shifts.append("\(Fmt.fixed(frame.milliseconds, 0)):\(Fmt.int(shift))")
        }
        r.check("\(label)/\(trackedName)-still", worst == 0,
                "\(Fmt.int(frames.count)) frames; worst \(trackedName) shift \(Fmt.int(worst)) pt; "
                + shifts.joined(separator: " "))
        return heights
    }

    /// The sidebar tab scroll view whose hosting view carries `contentType`.
    private static func sidebarScrollView(in window: NSWindow, hosting contentType: String) -> NSScrollView? {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let v = stack.popLast() {
            if let sv = v as? NSScrollView,
               let host = sv.documentView?.subviews.first,
               String(describing: type(of: host)).contains(contentType) { return sv }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    /// `rect` for the window server: the view's bounds in global, top-left coordinates.
    private static func captureRect(of view: NSView, in window: NSWindow) -> CGRect {
        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: onScreen.minX, y: screenHeight - onScreen.maxY,
                      width: onScreen.width, height: onScreen.height)
    }

    /// A fresh, empty frame directory under the sandbox's harness reports.
    private static func frameDirectory(_ name: String) -> URL? {
        let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/\(name)", isDirectory: true)
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: details-expand

    /// `details-expand`: the Details tab's Viewing History table expanding through the
    /// flag "Show All" writes. Everything above the table (Watch Details) must stay put;
    /// the modules below should only slide down to make room.
    private static func detailsExpandScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "details-expand")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard (session?["CGSSessionScreenIsLocked"] as? Bool) != true else {
            r.skip("screen-unlocked", "the screen is locked; re-run while someone is at the Mac")
            return r
        }
        if let reason = await keyWindowUnavailable(window) {
            r.skip("window-key", reason)
            return r
        }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        // Auto-expand would hold the tables open, leaving nothing to animate.
        let defaults = Preferences.store
        let savedAutoExpand = defaults.object(forKey: Preferences.autoExpandRightSidebarTablesKey)
        defaults.set(false, forKey: Preferences.autoExpandRightSidebarTablesKey)
        defer { defaults.set(savedAutoExpand, forKey: Preferences.autoExpandRightSidebarTablesKey) }

        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)
        // A viewing history long enough to overflow the collapsed six rows, but short
        // enough that the expanded table and the module below it fit the viewport.
        let candidates = coordinator.films.filter { (10...16).contains($0.calendarTable.count) }
        guard let subject = candidates.first ?? coordinator.films.max(by: { $0.calendarTable.count < $1.calendarTable.count }),
              subject.calendarTable.count > 6 else {
            r.check("film", false, "no film with more than six viewings")
            return r
        }
        r.check("film", true, "\(subject.name): \(Fmt.int(subject.calendarTable.count)) viewings")

        ViewStateManager.shared.setRightSidebarTab(.details)
        SelectionState.shared.selectImmediate(subject.id)
        await settle(1500)
        guard let sv = sidebarScrollView(in: window, hosting: "RTabDetailsContent") else {
            r.check("mounted", false, "Details scroll view not found")
            return r
        }
        guard let set = DetailsExpandProbe.set else {
            r.check("probe", false, "DetailsExpandProbe.set not set")
            return r
        }
        set("calendar", false)
        sv.contentView.scroll(to: .zero)
        sv.reflectScrolledClipView(sv.contentView)
        await settle(800)
        let rect = captureRect(of: sv, in: window)
        let outDir = frameDirectory("details-expand")

        // Rows 0–100: Watch Details, above the table.
        for (index, expand) in [true, false, true].enumerated() {
            await settle(600)
            await recordStep(&r, label: "\(Fmt.int(index + 1))-\(expand ? "expand" : "collapse")",
                             window: window, scrollView: sv, rect: rect, outDir: outDir,
                             trackedRows: 0..<100, trackedName: "above-table") { set("calendar", expand) }
        }

        // A new selection while the table is expanded: RightSidebar resets the flag, which
        // must reach the table unanimated and in the same pass as the new film — the
        // document going straight to the new film's collapsed height, never through the
        // new film with its table still expanded.
        let other = candidates.first(where: { $0.id != subject.id })
            ?? coordinator.films.first(where: { $0.id != subject.id && $0.calendarTable.count > 6 })
        if let other {
            set("calendar", true)
            await settle(900)
            let heights = await recordStep(&r, label: "4-new-film-while-expanded", window: window, scrollView: sv,
                                           rect: rect, outDir: outDir, trackedRows: 0..<0,
                                           trackedName: "none") { SelectionState.shared.selectImmediate(other.id) }
            // `heights` starts with the height before the selection, so one change is two entries.
            r.check("4-new-film-while-expanded/one-step", heights.count <= 2,
                    "\(other.name) (\(Fmt.int(other.calendarTable.count)) viewings); document heights after the "
                    + "selection: " + heights.map { Fmt.fixed($0, 1) }.joined(separator: " → "))
            // Already collapsed: collapsing it again must not change the document's height.
            await settle(600)
            let settledHeight = sv.documentView?.frame.height ?? 0
            set("calendar", false)
            await settle(900)
            let collapsedHeight = sv.documentView?.frame.height ?? 0
            r.check("4-new-film-while-expanded/collapsed", abs(settledHeight - collapsedHeight) < 0.5,
                    "height after the selection \(Fmt.fixed(settledHeight, 1)), collapsed \(Fmt.fixed(collapsedHeight, 1))")
            SelectionState.shared.selectImmediate(subject.id)
            await settle(900)
        }
        set("calendar", false)
        return r
    }

    nonisolated private static func signedMs(from origin: ContinuousClock.Instant) -> Double {
        let now = ContinuousClock.now
        let parts = (now < origin ? origin - now : now - origin).components
        let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        return now < origin ? -ms : ms
    }

    /// Mean luminance of each pixel row across the middle half of the image's width.
    private static func rowProfile(_ image: CGImage) -> [Double]? {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = unsafe buffer.withUnsafeMutableBytes { raw in
            guard let context = unsafe CGContext(data: raw.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let xs = Array(stride(from: width / 4, to: width * 3 / 4, by: 2))
        return (0..<height).map { y in
            xs.reduce(0.0) { sum, x in
                let i = (y * width + x) * 4
                return sum + (Double(buffer[i]) + Double(buffer[i + 1]) + Double(buffer[i + 2])) / 3
            } / Double(xs.count)
        }
    }

    /// The displacement (in rows) that best maps `source[rows]` onto `target`, within ±600.
    private static func profileShift(source: [Double], rows: Range<Int>, target: [Double]) -> Int {
        var best = (shift: 0, cost: Double.infinity)
        for s in -600...600 {
            var total = 0.0, count = 0
            for y in rows where y + s >= 0 && y + s < target.count {
                total += abs(target[y + s] - source[y])
                count += 1
            }
            guard count >= rows.count * 8 / 10 else { continue }
            let cost = total / Double(count)
            // Ties go to the smaller displacement.
            if cost < best.cost - 0.01 || (abs(cost - best.cost) <= 0.01 && abs(s) < abs(best.shift)) {
                best = (s, cost)
            }
        }
        return best.shift
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

#endif
