// MARK: - DHImportsRemoval.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only scenario for the Imports view's card-removal animation (28_00, with the
// scroll view's shrink hold in 92_00).
//
// `imports-removal` drives the REAL main window: it seeds the sandbox store with bogus
// metadata ImportSessions, navigates to Imports, and clears cards through the same call the
// context menu's "Clear This Item" makes. While each removal runs, a background thread films
// the scroll view's rectangle through the window server — the pixels the person actually
// sees, Core Animation's included — about once every two milliseconds, far faster than the
// display refreshes; identical frames are then collapsed.
//
// Each distinct frame is read two ways:
//   • A luminance profile down the card column (one value per pixel row, averaged across
//     the cards' width). The cards above the removed one, and those below it, each move as
//     a rigid block, so matching the first frame's profile of each block against every later
//     frame gives that block's on-screen displacement over time. A displacement that leaps
//     further in one display frame than the spring can travel is a jump; one that reverses
//     is a judder; one that never passes through intermediate values is a snap.
//   • The card color down one pixel column inside the cards' left padding, where no text
//     is drawn: in the rows of the removed card that are still on screen and not yet
//     covered by the card sliding up over it, that gives its visible opacity frame by frame.
//
// Before the 2026-10-05 fix, a removal while scrolled to the bottom of a list taller than
// the window failed here: the document shrank in one step, NSClipView clamped the offset in
// the same frame, every card leapt down a full card height, and the bottom card's fade
// happened entirely below the viewport.

#if DEBUG

import AppKit
import SwiftUI
import SwiftData
import Synchronization

/// The harness's handle on ImportSessionList's removal entry point. Set while the list is on
/// screen; nil otherwise.
@MainActor
enum ImportsRemovalProbe {
    static var beginRemoval: ((UUID) -> Void)?
}

extension DebugHarness {

    static func runImportsRemovalScenario(_ scenario: String,
                                          coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "imports-removal": return await importsRemovalScenario(coordinator: coordinator)
        case "imports-seed": return importsSeedScenario(coordinator: coordinator)
        default: return nil
        }
    }

    // MARK: Window-server capture

    /// `CGWindowListCreateImage`, looked up at run time: the macOS 15 SDK marks it
    /// unavailable, but it still ships, and it needs no screen-recording permission for the
    /// calling process's own windows.
    typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static let windowImageFunction: WindowImageFunction? = {
        guard let handle = unsafe dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = unsafe dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafe unsafeBitCast(symbol, to: WindowImageFunction.self)
    }()

    /// One captured frame: milliseconds since the first removal was triggered, and the pixels.
    struct RemovalFrame: @unchecked Sendable {
        let milliseconds: Double
        let image: CGImage
    }

    /// Captures `rect` (global display coordinates, top-left origin) of `windowID` as fast as
    /// the window server allows, off the main thread, from `origin - lead` until `origin +
    /// duration`. Consecutive identical frames are kept once, at their first time.
    static func film(windowID: CGWindowID, rect: CGRect, origin: ContinuousClock.Instant,
                             duration: Duration) async -> [RemovalFrame] {
        guard let capture = unsafe windowImageFunction else { return [] }
        let frames = Mutex<[RemovalFrame]>([])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                let end = origin + duration
                var previous: Data?
                var lastCapture = ContinuousClock.now
                var longestGap = 0.0
                defer { DebugHarness.log("capture: longest gap between captures \(Fmt.fixed(longestGap, 1)) ms") }
                while ContinuousClock.now < end {
                    let gap = DebugHarness.signedMilliseconds(from: lastCapture)
                    longestGap = max(longestGap, gap)
                    lastCapture = ContinuousClock.now
                    // Including-window (1 << 3); bounds ignore framing (1 << 0), nominal
                    // resolution (1 << 4) — one pixel per point.
                    guard let image = unsafe capture(rect, 1 << 3, windowID, (1 << 0) | (1 << 4))?.takeRetainedValue()
                    else { continue }
                    let bytes = image.dataProvider?.data as Data?
                    if let bytes, bytes == previous { continue }
                    previous = bytes
                    let ms = DebugHarness.signedMilliseconds(from: origin)
                    frames.withLock { $0.append(RemovalFrame(milliseconds: ms, image: image)) }
                }
                done.resume()
            }
        }
        return frames.withLock { $0 }
    }

    /// Milliseconds from `origin` to now; negative before it.
    nonisolated private static func signedMilliseconds(from origin: ContinuousClock.Instant) -> Double {
        let now = ContinuousClock.now
        let parts = (now < origin ? origin - now : now - origin).components
        let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        return now < origin ? -ms : ms
    }

    /// Fires every 4 ms on the main run loop (common modes) and remembers the longest gap.
    @MainActor
    final class MainHeartbeat {
        private var timer: Timer?
        private var last = ContinuousClock.now
        private let origin = ContinuousClock.now
        private(set) var longestGap = 0.0
        /// Milliseconds after the heartbeat was created (80 ms before the first removal).
        private(set) var gapAt = 0.0

        func start() {
            last = ContinuousClock.now
            let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func beat() {
            let now = ContinuousClock.now
            let gap = DebugHarness.milliseconds(now - last)
            if gap > longestGap {
                longestGap = gap
                gapAt = DebugHarness.milliseconds(now - origin)
            }
            last = now
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Pixel reading

    /// RGBA8 copy of a frame, rows top-down.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = unsafe buffer.withUnsafeMutableBytes { raw in
                guard let context = unsafe CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                                     bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                     space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            bytes = buffer
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
        }
    }

    /// Mean luminance of each row across `xs`.
    private static func profile(_ px: Pixels, xs: [Int]) -> [Double] {
        (0..<px.height).map { y in xs.reduce(0) { $0 + px.luminance($1, y) } / Double(xs.count) }
    }

    /// Per row, where the `column` pixel sits between the page background (0, read at
    /// `gutter`) and the card color (1).
    private static func cardness(_ px: Pixels, column: Int, gutter: Int, card: Double) -> [Double] {
        (0..<px.height).map { y in
            let background = px.luminance(gutter, y)
            let span = card - background
            guard abs(span) > 2 else { return 0 }
            return (px.luminance(column, y) - background) / span
        }
    }

    /// Runs of rows whose cardness exceeds one half: the cards, top to bottom.
    private static func cardRuns(_ t: [Double]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for (y, value) in t.enumerated() {
            if value > 0.5 {
                if start == nil { start = y }
            } else if let s = start {
                runs.append(s...(y - 1))
                start = nil
            }
        }
        if let s = start { runs.append(s...(t.count - 1)) }
        return runs.filter { $0.count >= 20 }
    }

    /// The displacement `s` for which `target[y + s]` best matches `source[y]` over `rows`,
    /// searched within `radius` of `around` first and over ±`fullRadius` if that finds
    /// nothing good. Returns nil when no shift leaves at least 40 rows overlapping.
    private static func bestShift(source: [Double], rows: Range<Int>, target: [Double], excluding: Range<Int>?,
                                  around: Int, radius: Int = 40, fullRadius: Int = 500) -> (shift: Int, cost: Double)? {
        func cost(_ s: Int) -> Double? {
            var total = 0.0, count = 0
            for y in rows where y + s >= 0 && y + s < target.count && !(excluding?.contains(y + s) ?? false) {
                total += abs(target[y + s] - source[y])
                count += 1
            }
            // Most of the block must still be compared: a sliver of flat page or card
            // padding matches anywhere, which is how a degenerate shift wins.
            return count >= max(40, rows.count * 6 / 10) ? total / Double(count) : nil
        }
        func search(_ range: ClosedRange<Int>) -> (Int, Double)? {
            var best: (Int, Double)?
            for s in range {
                guard let c = cost(s) else { continue }
                if best == nil || c < best!.1 { best = (s, c) }
            }
            return best
        }
        // The block normally moves a few pixels a frame, so the local answer stands unless
        // it is poor AND a shift elsewhere is decisively better — a real leap, not noise.
        let local = search((around - radius)...(around + radius))
        if let local, local.1 < 2.0 { return local }
        guard let full = search(-fullRadius...fullRadius) else { return local }
        guard let local else { return full }
        return full.1 < local.1 / 2 ? full : local
    }

    // MARK: Cases

    private enum ScrollSpot { case top, bottom, aboveBottom(CGFloat) }

    private struct RemovalCase {
        let label: String
        let count: Int
        var canceled: Set<Int> = []
        let scroll: ScrollSpot
        /// Card indices (0 = newest, at the top) to clear, and when, in ms after the first.
        let removals: [(index: Int, at: Int)]
    }

    // MARK: Scenario

    private static func importsRemovalScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-removal")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        // With the session locked (or the display asleep behind the lock), no window can
        // become key and the window server composites nothing new: every capture would be
        // the same stale frame. Say so once instead of failing every case.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard (session?["CGSSessionScreenIsLocked"] as? Bool) != true else {
            r.skip("screen-unlocked", "the screen is locked; re-run while someone is at the Mac")
            return r
        }
        guard unsafe windowImageFunction != nil else {
            r.check("capture-available", false, "CGWindowListCreateImage did not resolve")
            return r
        }
        let context = coordinator.modelContainer.mainContext
        let savedFrame = window.frame
        // As tall as the screen allows, up to 1100 pt: a frame the window server would
        // shrink to fit is one it keeps re-placing, and steadyWindow would fight it.
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: visible.minX + 80, y: visible.minY,
                           width: min(1200, visible.width - 80), height: min(1100, visible.height))
        window.setFrame(frame, display: true)
        if let reason = await keyWindowUnavailable(window) {
            window.setFrame(savedFrame, display: true)
            r.skip("window-key", reason)
            return r
        }

        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        /// The window server can still re-place a window for a moment after it is sized
        /// and activated (seen on the first cases of a run: the window slid sideways
        /// mid-capture, out from under the fixed capture rectangle). Re-asserts the
        /// frame until it has held still across five reads 100 ms apart.
        func steadyWindow() async -> Bool {
            var still = 0
            for _ in 0..<40 where still < 5 {
                if window.frame != frame {
                    window.setFrame(frame, display: true)
                    still = 0
                } else {
                    still += 1
                }
                await settle(100)
            }
            return still >= 5
        }
        r.check("window-steady", await steadyWindow(), "\(window.frame)")

        func clearStore() {
            for s in (try? context.fetch(FetchDescriptor<ImportSession>())) ?? [] { context.delete(s) }
            try? context.save()
        }

        /// Replaces every ImportSession with `count` metadata sessions, newest first, and
        /// mounts a fresh Imports view on them. Canceled cards are shorter, so the stack is
        /// not periodic and a jump of exactly one card cannot pass for no motion at all.
        func seed(_ c: RemovalCase) async -> [UUID] {
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(250)
            clearStore()
            let now = Date()
            var ids: [UUID] = []
            for i in 0..<c.count {
                let isCanceled = c.canceled.contains(i)
                let s = ImportSession(sessionDate: now.addingTimeInterval(-Double(i) * 86_400 - 600),
                                      importType: "metadata", totalItems: 20 + i * 7,
                                      successCount: isCanceled ? 0 : 20 + i * 7,
                                      isCompleted: !isCanceled, isCanceled: isCanceled)
                context.insert(s)
                ids.append(s.id)
            }
            try? context.save()
            ImportsState.shared.selectCategory(.metadata, persist: false)
            appState.navigate(to: .libraryItem(.imports))
            await settle(700)
            return ids
        }

        func importsScrollView() -> NSScrollView? {
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let v = stack.popLast() {
                if let sv = v as? NSScrollView,
                   let host = sv.documentView?.subviews.first,
                   String(describing: type(of: host)).contains("ImportSessionList") { return sv }
                stack.append(contentsOf: v.subviews)
            }
            return nil
        }

        func storedIDs() -> Set<UUID> {
            Set(((try? context.fetch(FetchDescriptor<ImportSession>())) ?? []).map(\.id))
        }

        func scroll(_ sv: NSScrollView, to spot: ScrollSpot) {
            let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
            let y: CGFloat
            switch spot {
            case .top: y = 0
            case .bottom: y = maxY
            case .aboveBottom(let gap): y = max(0, maxY - gap)
            }
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }

        /// Clears `c.removals` from the mounted list (already seeded with `ids`) and checks
        /// every frame of what the window showed.
        func run(_ c: RemovalCase, ids: [UUID], label: String) async {
            guard let sv = importsScrollView(), let document = sv.documentView else {
                r.check("\(label)/mounted", false, "Imports scroll view not found")
                return
            }
            _ = await steadyWindow()
            scroll(sv, to: c.scroll)
            await settle(450)   // let the overlay scroller fade after the programmatic scroll
            let frameBefore = window.frame
            let docBefore = document.frame.height
            let originBefore = sv.contentView.bounds.origin.y
            let storedBefore = storedIDs()
            let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let rect = CGRect(x: onScreen.minX, y: screenHeight - onScreen.maxY,
                              width: onScreen.width, height: onScreen.height)
            // The window server may not have the freshly mounted list yet (seen on the first
            // case after launch): wait until a capture shows card pixels down the card column.
            var drawn = false
            for _ in 0..<30 where !drawn {
                if let capture = unsafe windowImageFunction,
                   let image = unsafe capture(rect, 1 << 3, CGWindowID(window.windowNumber), (1 << 0) | (1 << 4))?.takeRetainedValue(),
                   let px = Pixels(image) {
                    let column = max(40, (px.width - 1000) / 2) + 12, gutter = column / 4
                    drawn = (0..<px.height).filter { abs(px.luminance(column, $0) - px.luminance(gutter, $0)) > 3 }.count > 100
                }
                if !drawn { await settle(100) }
            }
            r.check("\(label)/drawn", drawn, "cards visible to the window server before the removal")

            let origin = ContinuousClock.now + .milliseconds(80)
            // Main-thread heartbeat across the capture: a stall here is a hitch the person
            // would see, whatever the frames say about the animation.
            let beats = MainHeartbeat()
            beats.start()
            defer { beats.stop() }
            async let filmed = film(windowID: CGWindowID(window.windowNumber), rect: rect,
                                    origin: origin, duration: .milliseconds(1400))
            try? await Task.sleep(until: origin, clock: .continuous)
            var removed: [UUID] = []
            for removal in c.removals {
                if removal.at > 0 { try? await Task.sleep(until: origin + .milliseconds(removal.at), clock: .continuous) }
                let id = ids[removal.index]
                guard let begin = ImportsRemovalProbe.beginRemoval else {
                    r.check("\(label)/probe", false, "probe missing")
                    _ = await filmed
                    return
                }
                begin(id)
                removed.append(id)
            }
            let frames = await filmed
            beats.stop()
            r.metric("\(label)/longest-main-thread-gap", beats.longestGap, "ms")
            r.check("\(label)/main-thread-responsive", beats.longestGap < 100,
                    "longest gap between 4 ms heartbeats: \(Fmt.fixed(beats.longestGap, 1)) ms at \(Fmt.fixed(beats.gapAt, 0)) ms")
            // A window that moved under the capture rectangle invalidates every frame.
            r.check("\(label)/window-still", window.frame == frameBefore,
                    "\(frameBefore) → \(window.frame)")
            await settle(200)

            // The store and the scroll view after everything settled.
            let storedAfter = storedIDs()
            r.check("\(label)/deleted", storedAfter == storedBefore.subtracting(removed),
                    "store \(storedBefore.count) → \(storedAfter.count)")
            let lastCard = c.count == c.removals.count
            let svAfter = importsScrollView()
            let docAfter = svAfter?.documentView?.frame.height ?? 0
            let originAfter = svAfter?.contentView.bounds.origin.y ?? 0
            let travel = originBefore - originAfter
            if let svAfter {
                let maxY = max(0, docAfter - svAfter.contentView.bounds.height)
                r.check("\(label)/offset-in-range", originAfter <= maxY + 0.5,
                        "offset \(Fmt.fixed(originAfter, 1)) of max \(Fmt.fixed(maxY, 1))")
            } else {
                r.check("\(label)/placeholder-after-last", lastCard, "list gone with cards left")
            }

            analyze(frames, case: c, label: label, docBefore: docBefore, docAfter: lastCard ? nil : docAfter,
                    travel: lastCard ? 0 : travel)
        }

        func analyze(_ frames: [RemovalFrame], case c: RemovalCase, label: String,
                     docBefore: CGFloat, docAfter: CGFloat?, travel: CGFloat) {
            r.metric("\(label)/distinct-frames", Double(frames.count), "frames")
            // `-FTDebugImportsDumpFrames YES` writes every distinct frame, named by time.
            if UserDefaults.standard.bool(forKey: "FTDebugImportsDumpFrames"), let dir = DebugSandbox.rootURL {
                let folder = dir.appendingPathComponent("frames-\(label)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for f in frames {
                    let data = NSBitmapImageRep(cgImage: f.image).representation(using: .png, properties: [:])
                    try? data?.write(to: folder.appendingPathComponent(unsafe String(format: "%07.1f.png", f.milliseconds + 1000)))
                }
            }
            guard frames.count >= 3, let first = frames.first, let base = Pixels(first.image) else {
                r.check("\(label)/filmed", false, "\(frames.count) distinct frames")
                return
            }
            let width = base.width, height = base.height
            let cardLeft = max(40, (width - 1000) / 2)
            let cardWidth = width - 2 * cardLeft
            let column = cardLeft + 12, gutter = cardLeft / 3
            let xs = Array(stride(from: cardLeft + 16, to: cardLeft + cardWidth - 16, by: 3))

            // Card color: the median of the column wherever it differs from the gutter.
            let differing = (0..<height).compactMap { y -> Double? in
                let v = base.luminance(column, y)
                return abs(v - base.luminance(gutter, y)) > 3 ? v : nil
            }.sorted()
            guard !differing.isEmpty else {
                r.check("\(label)/cards-found", false, "no card pixels in the first frame")
                return
            }
            let card = differing[differing.count / 2]
            let runs0 = cardRuns(cardness(base, column: column, gutter: gutter, card: card))

            // Which run is the (first) removed card: counted from the top when scrolled to
            // the top, from the bottom otherwise (the last card is then the last run).
            let firstIndex = c.removals[0].index
            let lowestIndex = c.removals.map(\.index).min() ?? firstIndex
            let runOf: (Int) -> Int?
            switch c.scroll {
            case .top: runOf = { $0 < runs0.count ? $0 : nil }
            default:
                let visible = c.count
                runOf = { i in
                    let k = runs0.count - (visible - i)
                    return k >= 0 && k < runs0.count ? k : nil
                }
            }
            guard let removedRun = runOf(firstIndex), let topRun = runOf(lowestIndex) else {
                r.check("\(label)/removed-card-on-screen", false, "\(runs0.count) cards on screen")
                return
            }
            let removed = runs0[removedRun]
            let hasNext = removedRun + 1 < runs0.count
            /// A card's share of the stack: its height plus the 12-pt spacing.
            func pitch(ofRun k: Int) -> Int {
                k + 1 < runs0.count ? runs0[k + 1].lowerBound - runs0[k].lowerBound : runs0[k].count + 12
            }
            let removedRuns = c.removals.compactMap { runOf($0.index) }
            let pitch = removedRuns.reduce(0) { $0 + pitch(ofRun: $1) }

            // The document shrank by exactly the removed cards: the hold was released.
            if let docAfter {
                let shrink = docBefore - docAfter
                r.check("\(label)/document-shrank-by-cards", abs(shrink - CGFloat(pitch)) <= 2,
                        "document \(Fmt.fixed(docBefore, 1)) → \(Fmt.fixed(docAfter, 1)); card pitch \(pitch)")
            }

            let profiles = frames.compactMap { Pixels($0.image) }
            let profile0 = profile(base, xs: xs)
            let above = 0..<max(0, runs0[topRun].lowerBound - 8)
            // Starts at the next card's own top edge: the gap above it lies over the fading
            // card as soon as the card below begins to slide.
            let below = (hasNext ? runs0[removedRun + 1].lowerBound + 2 : removed.upperBound + 8)..<height
            // Below the lowest removed card there is either another card or only empty page.
            let tracksBelow = hasNext
            let expectedAbove = Int(travel.rounded())
            let expectedBelow = Int(travel.rounded()) - pitch

            /// The displacement of `rows` in every frame, or nil where it cannot be found.
            /// `hide` gives, per frame, rows to ignore: where the fading card is drawn.
            func track(_ rows: Range<Int>, hide: (Int) -> Range<Int>? = { _ in nil }) -> [Int?] {
                var around = 0
                return profiles.enumerated().map { i, px in
                    guard let best = bestShift(source: profile0, rows: rows, target: profile(px, xs: xs),
                                               excluding: hide(i), around: around)
                    else { return nil }
                    around = best.shift
                    return best.cost < 2.5 ? best.shift : nil
                }
            }

            /// Jump-free, monotone, animated, and ending where the geometry says it must.
            /// A block may not reverse, or stray from rest, by more than 2 px (the spring
            /// itself overshoots by about 0.6%).
            func judge(_ shifts: [Int?], expected: Int, block: String, minTracked: Double = 0.9) {
                let points = zip(frames, shifts).compactMap { f, s in s.map { (f.milliseconds, $0) } }
                guard let last = points.last else {
                    r.check("\(label)/\(block)-tracked", false, "block never matched")
                    return
                }
                r.check("\(label)/\(block)-tracked", Double(points.count) >= Double(frames.count) * minTracked,
                        "\(points.count) of \(frames.count) frames matched")
                r.check("\(label)/\(block)-ends-in-place", abs(last.1 - expected) <= 1,
                        "final displacement \(last.1) px, expected \(expected)")
                var worstLeap = 0.0, leapDetail = "none"
                var reversal = 0
                for (a, b) in zip(points, points.dropFirst()) {
                    // Spring peak speed here is ~1.3 px/ms; one display frame is 16.7 ms.
                    let allowed = 2.2 * max(b.0 - a.0, 16.7) + 3
                    let step = Double(abs(b.1 - a.1))
                    if step / allowed > worstLeap {
                        worstLeap = step / allowed
                        leapDetail = "\(b.1 - a.1) px between \(Fmt.fixed(a.0, 0)) and \(Fmt.fixed(b.0, 0)) ms"
                    }
                    if expected != 0, (b.1 - a.1) * expected.signum() < 0 { reversal = max(reversal, abs(b.1 - a.1)) }
                    if expected == 0 { reversal = max(reversal, abs(b.1)) }
                }
                r.check("\(label)/\(block)-no-jump", worstLeap <= 1, "largest step \(leapDetail)")
                r.check("\(label)/\(block)-no-reversal", reversal <= 2,
                        expected == 0 ? "strayed up to \(reversal) px from rest" : "reversed by up to \(reversal) px")
                if abs(expected) >= 20 {
                    let between = points.filter {
                        let p = Double($0.1) / Double(expected)
                        return p > 0.1 && p < 0.9
                    }
                    r.check("\(label)/\(block)-animated", between.count >= 3,
                            "\(between.count) frames between 10% and 90% of \(expected) px")
                }
            }

            var shiftsAbove: [Int?] = Array(repeating: 0, count: frames.count)
            if above.count >= 40 {
                shiftsAbove = track(above)
                judge(shiftsAbove, expected: expectedAbove, block: "above")
            } else {
                r.check("\(label)/no-travel-without-above", expectedAbove == 0, "travel \(expectedAbove) px")
            }
            /// The removed card's mean cardness over its rows still on screen and not yet
            /// covered by the next card (at displacement `sb`), or nil if too few remain.
            func visibleOpacity(_ i: Int, below sb: Int?) -> Double? {
                guard let sa = shiftsAbove[i] else { return nil }
                var bottom = min(height - 1, removed.upperBound + sa - 6)
                if hasNext {
                    guard let sb else { return nil }
                    bottom = min(bottom, runs0[removedRun + 1].lowerBound + sb - 10)
                }
                let top = max(0, removed.lowerBound + sa + 6)
                guard bottom - top >= 8 else { return nil }
                let rows = cardness(profiles[i], column: column, gutter: gutter, card: card)[top...bottom]
                return rows.reduce(0, +) / Double(rows.count)
            }

            var shiftsBelow: [Int?] = Array(repeating: nil, count: frames.count)
            if tracksBelow, below.count >= 40 {
                // The removed card travels with the block above it, and while it fades it
                // passes behind the next card, which hides it.
                shiftsBelow = track(below)
                judge(shiftsBelow, expected: expectedBelow, block: "below", minTracked: 0.9)
            }

            // The removed card's visible opacity (single removals; with two, the second
            // card's fade overlaps the first's and the blocks are judged instead).
            guard c.removals.count == 1 else {
                writeFilmStrip(frames, name: "imports-removal-\(label)")
                return
            }
            let fade: [(Double, Double)] = frames.indices.compactMap { i in
                visibleOpacity(i, below: shiftsBelow[i]).map { (frames[i].milliseconds, $0) }
            }
            if let dir = DebugSandbox.rootURL {
                var lines: [String] = ["runs0 \(runs0.map { "\($0.lowerBound)-\($0.upperBound)" }) removed run \(removedRun) travel \(travel)"]
                for (i, f) in frames.enumerated() {
                    let o = fade.first { $0.0 == f.milliseconds }?.1
                    lines.append("\(Fmt.fixed(f.milliseconds, 1)) above \(shiftsAbove[i].map(String.init) ?? "-") below \(shiftsBelow[i].map(String.init) ?? "-") fade \(o.map { Fmt.fixed($0, 3) } ?? "-")")
                }
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("imports-removal-\(label).txt"),
                                                         atomically: true, encoding: .utf8)
            }
            let opaqueAtStart = (fade.first?.1 ?? 0) >= 0.9
            let midway = fade.filter { $0.1 > 0.15 && $0.1 < 0.85 }
            var rise = 0.0
            for (a, b) in zip(fade, fade.dropFirst()) { rise = max(rise, b.1 - a.1) }
            r.check("\(label)/fade-starts-opaque", opaqueAtStart,
                    "first visible opacity \(Fmt.fixed(fade.first?.1 ?? -1, 2))")
            r.check("\(label)/fade-seen", midway.count >= 3,
                    "\(midway.count) on-screen frames part-way faded"
                    + (midway.isEmpty ? "" : " (\(Fmt.fixed(midway.first!.0, 0))–\(Fmt.fixed(midway.last!.0, 0)) ms)"))
            // One luminance level is a large step of cardness when card and page are close
            // (about 0.1 in the dark appearance); a rise of one level is rounding, not a flicker.
            let quantum = 1 / max(1, abs(card - (base.luminance(gutter, removed.lowerBound + 20))))
            r.check("\(label)/fade-monotone", rise <= quantum * 1.5 + 0.02,
                    "largest rise \(Fmt.fixed(rise, 2)) (one level = \(Fmt.fixed(quantum, 2)))")
            if let end = fade.last, end.0 > 300 {
                r.check("\(label)/fade-complete", end.1 <= 0.1, "opacity \(Fmt.fixed(end.1, 2)) at \(Fmt.fixed(end.0, 0)) ms")
            }
            writeFilmStrip(frames, name: "imports-removal-\(label)")
        }

        let cases: [RemovalCase] = [
            RemovalCase(label: "short-top", count: 3, scroll: .top, removals: [(0, 0)]),
            RemovalCase(label: "short-middle", count: 3, scroll: .top, removals: [(1, 0)]),
            RemovalCase(label: "short-bottom", count: 3, canceled: [1], scroll: .top, removals: [(2, 0)]),
            RemovalCase(label: "only-card", count: 1, scroll: .top, removals: [(0, 0)]),
            RemovalCase(label: "long-top-at-top", count: 8, canceled: [2, 5], scroll: .top, removals: [(0, 0)]),
            RemovalCase(label: "long-bottom-at-bottom", count: 8, canceled: [2, 5], scroll: .bottom, removals: [(7, 0)]),
            RemovalCase(label: "long-middle-at-bottom", count: 8, canceled: [2, 5], scroll: .bottom, removals: [(6, 0)]),
            RemovalCase(label: "long-near-bottom", count: 8, canceled: [2, 5], scroll: .aboveBottom(60), removals: [(6, 0)]),
            RemovalCase(label: "rapid-pair-at-bottom", count: 8, canceled: [2, 5], scroll: .bottom, removals: [(7, 0), (6, 120)]),
            // Sixty cards: only a window near the viewport is mounted, with a spacer
            // standing in above it (scrolled down) or below it (at the top).
            RemovalCase(label: "windowed-top", count: 60, canceled: [2, 13, 30, 44], scroll: .top,
                        removals: [(1, 0)]),
            RemovalCase(label: "windowed-bottom", count: 60, canceled: [2, 13, 30, 44, 57], scroll: .bottom,
                        removals: [(59, 0)]),
            RemovalCase(label: "windowed-near-bottom", count: 60, canceled: [2, 13, 30, 44, 57], scroll: .aboveBottom(60),
                        removals: [(57, 0)]),
            RemovalCase(label: "windowed-rapid-pair", count: 60, canceled: [2, 13, 30, 44, 57], scroll: .bottom,
                        removals: [(59, 0), (58, 120)]),
        ]
        // `-FTDebugImportsCases a,b` runs only those cases (and `repeat` for the repeat run).
        let only = UserDefaults.standard.string(forKey: "FTDebugImportsCases")
            .map { Set($0.split(separator: ",").map(String.init)) }
        for c in cases where only?.contains(c.label) ?? true {
            let ids = await seed(c)
            await run(c, ids: ids, label: c.label)
        }

        // Repeatability: clear the bottom card again and again, staying at the bottom, until
        // the list is empty — the clamped cases first, then the short ones.
        let repeatCount = only == nil || only!.contains("repeat") ? 7 : 0
        let repeatCase = RemovalCase(label: "repeat", count: repeatCount, canceled: [3], scroll: .bottom, removals: [])
        let repeatIDs = repeatCount > 0 ? await seed(repeatCase) : []
        for k in 0..<repeatCount {
            let index = repeatCount - 1 - k
            let c = RemovalCase(label: "repeat-\(k + 1)", count: index + 1, canceled: [3], scroll: .bottom,
                                removals: [(index, 0)])
            await run(c, ids: repeatIDs, label: c.label)
        }

        clearStore()
        window.setFrame(savedFrame, display: true)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(200)
        return r
    }

    // MARK: Seed for hand-testing

    /// `imports-seed` (opt-in): replaces the container's ImportSessions with 110 metadata and
    /// 12 ratings sessions — some canceled, some with errors — and leaves them there, so the
    /// same container can then be opened without `-FTDebugHarness` and cleared by hand.
    private static func importsSeedScenario(coordinator: DataCoordinator) -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-seed")
        let context = coordinator.modelContainer.mainContext
        for s in (try? context.fetch(FetchDescriptor<ImportSession>())) ?? [] { context.delete(s) }
        let now = Date()
        func add(_ i: Int, type: String, canceled: Bool = false, errors: Int = 0) {
            let total = 12 + i * 5
            context.insert(ImportSession(
                sessionDate: now.addingTimeInterval(-Double(i) * 86_400 - 600), importType: type,
                totalItems: total, successCount: canceled ? 0 : total - errors, errorCount: errors,
                errorFileNames: (0..<errors).map { "Broken File \($0 + 1).m4v" },
                addedTitles: canceled ? [] : (0..<(total - errors)).map { "Seeded Film \(i)-\($0 + 1)" },
                isCompleted: !canceled, isCanceled: canceled))
        }
        for i in 0..<110 { add(i, type: "metadata", canceled: i % 9 == 3, errors: i % 7 == 5 ? 2 : 0) }
        for i in 0..<12 { add(i, type: "ratings", canceled: i % 5 == 2) }
        r.check("seeded", (try? context.save()) != nil,
                "\((try? context.fetchCount(FetchDescriptor<ImportSession>())) ?? -1) sessions")
        return r
    }

    // MARK: Film strip

    /// Up to 24 frames at half size in capture order, for eyeballing a failure.
    private static func writeFilmStrip(_ frames: [RemovalFrame], name: String) {
        guard let dir = DebugSandbox.rootURL, let first = frames.first else { return }
        let picked = stride(from: 0, to: frames.count, by: max(1, frames.count / 24)).map { frames[$0] }
        let w = first.image.width / 2, h = first.image.height / 2
        let columns = 8
        let rows = (picked.count + columns - 1) / columns
        guard let ctx = unsafe CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w * columns, height: h * rows))
        for (i, frame) in picked.enumerated() {
            let x = (i % columns) * w
            let y = (rows - 1 - i / columns) * h
            ctx.draw(frame.image, in: CGRect(x: x + 1, y: y + 1, width: w - 2, height: h - 2))
        }
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        log("\(name): \(frames.count) distinct frames; strip shows "
            + picked.map { Fmt.fixed($0.milliseconds, 0) }.joined(separator: " ") + " ms")
    }
}

#endif
