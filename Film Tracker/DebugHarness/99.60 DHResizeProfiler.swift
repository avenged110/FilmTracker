// MARK: - DHResizeProfiler.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only, opt-in profiler for a live window-resize drag. Armed with `-FTDebugLiveResize`;
// prints one report per completed drag and changes nothing about how the app behaves.
//
// WHY THIS IS NOT A DebugHarness SCENARIO
//
// Every scenario in DebugHarness is headless: it builds a corpus, drives production code, checks
// invariants, and exits. A resize cannot be measured that way. Driving `window.setFrame` from a
// Task reproduces the layout work but not the mechanism — AppKit's live resize runs its own
// event-tracking loop, the window server participates in every frame, and the frame CADENCE is
// set by neither the app nor the test. A synthetic sweep therefore measures how long the layout
// takes while saying nothing about whether the app is what limits the frame rate. This profiler
// is passive instead: it observes a real drag performed by a real person and reports what
// actually happened.
//
// WHAT IT MEASURES, AND WHY THAT PARTICULAR THING
//
// The naive metric — time spent inside `WidthObservingScrollView.layout()` — is worthless here,
// and measuring it was how this file's first version wasted a profiling run. That method returns
// long before the work it triggers is done: the collection view lays its cells out later in the
// same display cycle, and the compositor later still. The number it yields is ~0.01ms no matter
// how heavy the grid is.
//
// The two quantities that do answer the question are:
//
//   1. The INTERVAL between consecutive real geometry updates — the achieved update rate. Compare
//      it against the display's frame period (16.67ms at 60Hz) to see whether the gallery is
//      keeping up.
//
//   2. The main-thread DUTY CYCLE — what fraction of the drag the main thread was busy at all.
//      This is the one that decides what to do next, because the interval alone cannot
//      distinguish two opposite situations that look identical from the outside:
//
//        • ~100% busy → the main thread is saturated; it is the bottleneck, and making the app do
//          less work per frame will raise the frame rate.
//        • well below → the main thread finishes early and then waits for the next resize event.
//          The ceiling is somewhere else (compositing, event delivery), and optimizing app code
//          cannot move it, however much work is removed.
//
// TWO CORRECTIONS THAT THE RAW NUMBERS REQUIRE
//
// Idle gaps. A person dragging a window edge pauses — at a direction reversal, or just to look.
// While the mouse is still, no resize events arrive, no layout runs, and the gap between passes
// balloons to hundreds of milliseconds. Counted naively those pauses ARE the tail: they push p99
// to ~50ms and the maximum past 350ms, and they mean nothing at all. Gaps longer than 100ms are
// therefore excluded and reported separately, so the tail describes frames rather than hesitation.
//
// No-op passes. AppKit calls the scroll view's `layout()` about twice per actual width change;
// on the second call the width has not moved, `shouldInvalidateLayout(forBoundsChange:)` returns
// false, and `prepare()` never runs. Counting those as frames halves every interval and doubles
// the apparent frame rate. Passes are classified by whether the width actually moved, and only
// the ones that did are treated as geometry updates.

#if DEBUG

import AppKit
import Foundation

@MainActor
final class DebugLiveResizeProfiler {
    static let shared = DebugLiveResizeProfiler()

    /// Opt-in, and deliberately NOT gated on `DebugSandbox.isActive`: the point is to profile a
    /// real library on real hardware, and this type only reads clocks and prints. It never
    /// touches the store, the caches, or any view state.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-FTDebugLiveResize")
    }

    private init() {}

    /// One `WidthObservingScrollView.layout()` pass observed during a drag.
    private struct Pass {
        /// Wall time since the previous pass began, in milliseconds.
        let interval: Double
        /// Main-thread CPU consumed over that same interval, in milliseconds. Sampling CPU at
        /// each pass boundary (rather than around the pass body) is what makes the duty cycle
        /// computable: the difference covers the whole frame, including the cell layout and
        /// commit that happen after `layout()` has returned.
        let cpuSincePrevious: Double
        /// False when the width did not move — see "No-op passes" above.
        let widthChanged: Bool
    }

    private var recording = false
    private var installed = false
    private var passes: [Pass] = []
    private var lastTick: CFAbsoluteTime = 0
    private var lastCPU: Double = 0
    private var lastWidth: CGFloat = -1

    /// Gaps longer than this are treated as the mouse standing still, not as a slow frame.
    private static let idleGapThresholdMs = 100.0
    /// The 60Hz frame period. Reported as a reference point, not enforced as a threshold.
    private static let frameBudgetMs = 16.7

    private func threadCPUMilliseconds() -> Double {
        var ts = timespec()
        unsafe clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    }

    /// Subscribes to live-resize begin/end for every window in the process. Idempotent, and a
    /// no-op unless the launch argument is present, so the call site in FilmTrackerApp costs one
    /// Bool read on a normal launch.
    func installIfNeeded() {
        guard Self.isEnabled, !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.begin() }
            }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.report() }
            }
        printToStandardError("[DebugLiveResize] armed — drag a window edge to profile\n")
    }

    private func begin() {
        recording = true
        lastTick = 0
        lastCPU = 0
        lastWidth = -1
        passes.removeAll(keepingCapacity: true)
    }

    /// Called from `WidthObservingScrollView.layout()`. Records the interval and CPU consumed
    /// since the previous pass, and whether this one represents a real width change.
    func beginPass(width: CGFloat) {
        guard recording else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let cpu = threadCPUMilliseconds()
        // The first pass of a drag has no predecessor to measure against, so it seeds the
        // baselines rather than producing a sample.
        if lastTick > 0 {
            passes.append(Pass(interval: (now - lastTick) * 1000.0,
                               cpuSincePrevious: cpu - lastCPU,
                               widthChanged: abs(width - lastWidth) > 0.01))
        }
        lastTick = now
        lastCPU = cpu
        lastWidth = width
    }

    // MARK: - Reporting

    private func report() {
        recording = false
        guard passes.count > 3 else {
            printToStandardError("[DebugLiveResize] drag too short to report\n")
            return
        }

        let realUpdates = passes.filter(\.widthChanged)
        let noOpPasses = passes.count - realUpdates.count

        // Interval between consecutive REAL updates. A run of no-op passes between two real ones
        // contributes its time to the enclosing interval rather than splitting it, which is why
        // this accumulates rather than reading `interval` off the real passes directly.
        var intervals: [Double] = []
        var excludedIdleGaps = 0
        var accumulated = 0.0
        for pass in passes {
            accumulated += pass.interval
            guard pass.widthChanged else { continue }
            if accumulated > Self.idleGapThresholdMs {
                excludedIdleGaps += 1
            } else {
                intervals.append(accumulated)
            }
            accumulated = 0
        }

        let active = passes.filter { $0.interval <= Self.idleGapThresholdMs }
        let wallTotal = active.reduce(0.0) { $0 + $1.interval }
        let cpuTotal = active.reduce(0.0) { $0 + $1.cpuSincePrevious }
        let perUpdateCPU = realUpdates
            .filter { $0.interval <= Self.idleGapThresholdMs }
            .map(\.cpuSincePrevious)

        var out = "\n===LIVE-RESIZE-REPORT===\n"
        out += "scroll-view layout passes: \(Fmt.int(passes.count)) (\(Fmt.int(realUpdates.count)) moved the width, \(Fmt.int(noOpPasses)) were no-ops)\n"

        out += "interval between real geometry updates (ms), idle gaps removed:\n"
        out += "  " + Self.distribution(intervals) + "\n"
        out += "  excluded \(Fmt.int(excludedIdleGaps)) gap(s) over \(Fmt.fixed(Self.idleGapThresholdMs, 0))ms (mouse held still)\n"
        if !intervals.isEmpty {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            out += "  effective update rate: \(Fmt.fixed(1000.0 / mean, 0)) fps (60Hz frame period is \(Fmt.fixed(Self.frameBudgetMs, 2))ms)\n"
        }

        if wallTotal > 0 {
            out += "main-thread duty cycle: \(Fmt.fixed(100.0 * cpuTotal / wallTotal, 1))% busy (\(Fmt.fixed(cpuTotal, 0))ms CPU over \(Fmt.fixed(wallTotal, 0))ms of dragging)\n"
            out += "  near 100% = CPU-bound, doing less work per frame will help\n"
            out += "  well below = main thread idle between events, app-side optimization will not\n"
        }
        out += "main-thread CPU per real geometry update (ms):\n"
        out += "  " + Self.distribution(perUpdateCPU) + "\n"
        out += "===LIVE-RESIZE-REPORT-END===\n"
        printToStandardError(out)
    }

    /// Percentiles rather than a mean alone: resize smoothness is a tail property, and a mean
    /// comfortably inside the frame budget routinely hides a p90 that is not.
    private static func distribution(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n=0" }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return unsafe String(format: "n=%4d  mean %6.2f  p50 %6.2f  p90 %6.2f  p99 %6.2f  max %7.2f",
                      sorted.count,
                      values.reduce(0, +) / Double(values.count),
                      percentile(0.50), percentile(0.90), percentile(0.99),
                      sorted.last ?? 0)
    }
}

#endif
