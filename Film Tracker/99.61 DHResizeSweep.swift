// MARK: - DHResizeSweep.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only measurement scenario for the gallery grid under a synthetic window-width sweep.
// Opt-in (`-FTDebugHarness resize-perf`); not part of `all`, because its output is a
// measurement rather than a verdict.
//
// Complements DHResizeProfiler (99.30), which observes a REAL drag and answers "is the app
// the bottleneck?". A synthetic sweep cannot answer that (see the long note at the top of
// 99.30) -- but it CAN answer the narrower question this file exists for: how much
// main-thread work does one width step cost, and how does that cost differ between the two
// geometric regimes the grid has?
//
//   • RESIZE regime  -- window narrower than the grid's maximum width: every tile changes
//     size on every step.
//   • TRANSLATE regime -- window wider than the maximum: tiles keep their size and the whole
//     grid re-centers, so every tile only moves.
//
// The real grid (GallerySubview -> NSCollectionView -> GalleryItem cells) is hosted in a
// window whose content size is stepped 2pt at a time through each regime; per step the
// synchronous layout wall time plus main-thread CPU over the following run-loop turns is
// recorded, exactly as card-perf measures. Posters are synthesized into the sandbox's poster
// folder so cells carry real image layers, not placeholders.
//
// Baseline (2026-09-19, 24 visible cells, 2pt steps, Debug build): RESIZE median ~2.9ms /
// p90 ~3.5ms; TRANSLATE median ~1.8ms / p90 ~2.3ms. In the TRANSLATE regime no per-cell
// layout runs at all (prepare() once per step; GalleryItem.viewDidLayout and
// GalleryTileContentView.layout() never fire, verified with temporary counters) -- the cost
// is the collection view re-issuing attributes plus the Core Animation commit. The
// `translate-not-heavier` check turns a regression of that property into a failure.

#if DEBUG

import AppKit
import SwiftUI

extension DebugHarness {

    static func runResizeSweepScenario(_ scenario: String,
                                       coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        guard scenario == "resize-perf" else { return nil }
        return await resizeSweepScenario(coordinator: coordinator)
    }

    private struct SweepHost: View {
        let coordinator: DataCoordinator
        var body: some View {
            GallerySubview(forceReloadID: UUID(), scrollRequest: nil, activeViewID: .allFilms,
                           subtitleProvider: nil, showSectionDividers: false)
                .environment(coordinator)
                .environment(SelectionState.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func threadCPUMs() -> Double {
        var ts = timespec()
        unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    }

    private static func turn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    /// Writes `count` 400x600 JPEGs (a two-tone gradient, distinct per file) into the
    /// sandbox poster folder and returns their UIDs.
    private static func synthesizePosters(count: Int) -> [String] {
        guard let folder = Preferences.posterImagesFolderURL else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var uids: [String] = []
        for i in 0..<count {
            let uid = UUID().uuidString
            let w = 400, h = 600
            guard let ctx = unsafe CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let hue = CGFloat(i % 12) / 12
            let top = NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor
            let bottom = NSColor(hue: (hue + 0.4).truncatingRemainder(dividingBy: 1),
                                 saturation: 0.7, brightness: 0.35, alpha: 1).cgColor
            let gradient = unsafe CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [top, bottom] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }
            let url = folder.appendingPathComponent("\(uid).jpg")
            guard (try? data.write(to: url)) != nil else { continue }
            uids.append(uid)
        }
        return uids
    }

    private struct Stats {
        let median: Double, p90: Double, max: Double, mean: Double
        init(_ values: [Double]) {
            let s = values.sorted()
            func q(_ f: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * f))] }
            median = q(0.5); p90 = q(0.9); max = s.last ?? 0
            mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
        }
        var text: String {
            "median \(Fmt.fixed(median, 2))ms  p90 \(Fmt.fixed(p90, 2))ms  max \(Fmt.fixed(max, 2))ms  mean \(Fmt.fixed(mean, 2))ms"
        }
    }

    private static func resizeSweepScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "resize-perf")

        // MARK: Corpus with real posters
        let uids = synthesizePosters(count: 120)
        r.check("posters-synthesized", uids.count == 120, "only \(uids.count) posters written")
        let store = coordinator.memoryStoreForTesting
        for (i, uid) in uids.enumerated() {
            var film = makeSnapshot(name: "Sweep", sortIndex: i)
            film.posterUID = uid
            store.addFilm(film)
        }
        await PosterCache.shared.addPosters(uids)
        ViewStateManager.shared.switchToViewSync(.allFilms)
        coordinator.refreshFilms()
        r.check("films-loaded", coordinator.films.count >= 120,
                "coordinator holds \(coordinator.films.count) films")

        // MARK: Window
        let height: CGFloat = 900
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SweepHost(coordinator: coordinator))
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: height)
        window.contentView = host
        // Parked below the screen at low alpha so Core Animation commits are real ones.
        window.setFrameOrigin(NSPoint(x: 100, y: -(height + 40)))
        window.alphaValue = 0.1
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<10 { await turn() }

        let visibleCells = host.firstDescendant(GalleryCollectionView.self)?.visibleItems().count ?? -1
        log("resize-perf: \(visibleCells) visible cells at 1000pt")

        // MARK: Sweep
        @MainActor func sweep(_ label: String, from: CGFloat, to: CGFloat, step: CGFloat) async -> Stats {
            var samples: [Double] = []
            var w = from
            // Warm the regime first so cell creation is not in the numbers.
            window.setContentSize(NSSize(width: from, height: height))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            for _ in 0..<5 { await turn() }
            while (step > 0 && w <= to) || (step < 0 && w >= to) {
                let cpu0 = threadCPUMs()
                window.setContentSize(NSSize(width: w, height: height))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await turn(); await turn()
                samples.append(threadCPUMs() - cpu0)
                w += step
            }
            let s = Stats(samples)
            log("resize-perf: \(label) \(Int(from))->\(Int(to)) (\(samples.count) steps): \(s.text)")
            return s
        }

        let resize = await sweep("RESIZE   ", from: 1100, to: 1500, step: 2)
        let translate = await sweep("TRANSLATE", from: 1600, to: 2000, step: 2)
        let resizeBack = await sweep("RESIZE  <", from: 1500, to: 1100, step: -2)
        let translateBack = await sweep("TRANSLATE<", from: 2000, to: 1600, step: -2)

        r.check("resize-measured", resize.median > 0, "no samples")
        r.check("translate-measured", translate.median > 0, "no samples")
        r.check("translate-not-heavier",
                translate.median <= resize.median * 1.2,
                "translate median \(Fmt.fixed(translate.median, 2))ms vs resize median \(Fmt.fixed(resize.median, 2))ms")
        _ = resizeBack; _ = translateBack

        window.orderOut(nil)
        window.contentView = nil
        return r
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        var stack: [NSView] = [self]
        while let v = stack.popLast() {
            if let t = v as? T { return t }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }
}

#endif
