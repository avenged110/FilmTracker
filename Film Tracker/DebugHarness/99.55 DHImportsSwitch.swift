// MARK: - DHImportsSwitch.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only measurement of switching into and out of the Imports view (28_00).
//
// `imports-switch-perf` (opt-in) drives the REAL main window on the 1,400-film reportsCorpus.
// For each import-history size it seeds the sandbox store with that many ImportSessions and
// times, with the same run-loop busy recorder `view-switch-perf` uses:
//   • enter      — All Films → Imports,
//   • leave      — Imports → All Films, after the list has settled (its window grown),
//   • tab        — Metadata ⟷ Ratings inside the view,
//   • scroll     — a programmatic scroll down the list, per 16 ms step.
// A gallery → gallery sidebar switch is measured on the same corpus for scale. The goal it
// pins: entering and leaving cost the same whatever the history size.
//
// `-FTDebugImportsSizes 0,1,20,1000` picks the history sizes (that is the default);
// `-FTDebugImportsReps N` the repetitions per measurement (default 5).
//
// `imports-window` (in the `imports` suite) checks what makes those costs flat:
//   • ImportHistory (28_20) matches the store after main-context inserts and updates —
//     synchronously, before `save()` returns — and after DataManager's deletes;
//   • ImportSessionList mounts only a window of a long list, and what the window
//     shows is pixel-identical to the full stack at offsets throughout it, to within one
//     8-bit level of compositing rounding (`window-identical`), scroller strip left out;
//   • every card shape keeps its height at the window's minimum width, which the windowed
//     layout's spacers rely on.

#if DEBUG

import AppKit
import SwiftUI
import CoreData

/// The harness's handle on ImportSessionList's card counts. Set while the list is on
/// screen; nil otherwise.
@MainActor
enum ImportsSwitchProbe {
    /// Sessions listed.
    static var visibleCount: (() -> Int)?
    /// Cards actually mounted (the rest of the listed ones are spacer).
    static var mountedCount: (() -> Int)?
}

extension DebugHarness {

    static func runImportsSwitchScenario(_ scenario: String,
                                         coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "imports-switch-perf": return await importsSwitchPerfScenario(coordinator: coordinator)
        case "imports-window": return await importsWindowScenario(coordinator: coordinator)
        case "imports-qos": return await importsQoSScenario(coordinator: coordinator)
        case "imports-scroll": return await importsScrollScenario(coordinator: coordinator)
        default: return nil
        }
    }

    private static func clearImportSessions(_ context: NSManagedObjectContext) {
        for s in (try? context.fetch(ImportSession.request())) ?? [] { context.delete(s) }
        try? context.save()
    }

    /// Replaces every session with `count` new ones, nine metadata to every ratings one,
    /// newest first; every ninth canceled, every seventh with errors, each naming the films
    /// it touched. Returns how many are metadata.
    @discardableResult
    private static func seedImportSessions(_ count: Int, _ context: NSManagedObjectContext) -> Int {
        clearImportSessions(context)
        let now = Date()
        for i in 0..<count {
            let type = i % 10 == 9 ? ImportsCategory.ratings.rawValue : ImportsCategory.metadata.rawValue
            let canceled = i % 9 == 3
            let errors = i % 7 == 5 ? 2 : 0
            let total = 6 + i % 15
            context.insert(ImportSession(
                sessionDate: now.addingTimeInterval(-Double(i) * 3_600 - 600), importType: type,
                totalItems: total, successCount: canceled ? 0 : total - errors, errorCount: errors,
                updatedCount: canceled ? 0 : i % 3,
                errorFileNames: (0..<errors).map { "Broken File \($0 + 1).m4v" },
                addedTitles: canceled ? [] : (0..<(total - errors)).map { "Seeded Film \(i)-\($0 + 1)" },
                updatedTitles: canceled ? [] : (0..<(i % 3)).map { "Updated Film \(i)-\($0 + 1)" },
                isCompleted: !canceled, isCanceled: canceled))
        }
        try? context.save()
        return (0..<count).filter { $0 % 10 != 9 }.count
    }

    private static func importsSwitchPerfScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-switch-perf")
        coordinator.importFilms(reportsCorpus())
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        let context = coordinator.persistentContainer.viewContext
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        let sizes = (UserDefaults.standard.string(forKey: "FTDebugImportsSizes") ?? "0,1,20,1000")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let reps = max(1, UserDefaults.standard.integer(forKey: "FTDebugImportsReps").nonZero ?? 5)

        let recorder = RunLoopBusyRecorder()
        recorder.start()
        defer { recorder.stop() }
        var byKind: [(String, [RunLoopBusyRecorder.Reading])] = []
        func record(_ kind: String, _ reading: RunLoopBusyRecorder.Reading) {
            if let i = byKind.firstIndex(where: { $0.0 == kind }) { byKind[i].1.append(reading) }
            else { byKind.append((kind, [reading])) }
        }
        /// `window` must outlast the slowest stretch: one still running at its end is not counted.
        func measure(_ kind: String, window: Int = 1500, _ action: () -> Void) async {
            await settle(600)
            recorder.reset()
            let t0 = CACurrentMediaTime() * 1000
            action()
            await settle(window)
            record(kind, recorder.reading(from: t0, window: Double(window)))
        }

        func clearStore() { clearImportSessions(context) }
        func seed(_ count: Int) { seedImportSessions(count, context) }
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


        ImportsState.shared.selectCategory(.metadata, persist: false)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(1500)

        // `-FTDebugImportsFetch YES`: what the fetch variants cost on the largest size.
        if UserDefaults.standard.bool(forKey: "FTDebugImportsFetch") {
            seed(sizes.max() ?? 1000)
            let type = ImportsCategory.metadata.rawValue
            func time(_ label: String, _ body: () -> Int) {
                var samples: [Double] = []
                var n = 0
                for _ in 0..<7 {
                    let t = ContinuousClock.now
                    n = body()
                    samples.append(milliseconds(ContinuousClock.now - t))
                }
                r.metric("fetch \(label) (\(n))", stats(samples).median, "ms")
            }
            time("full") { (try? context.fetch(ImportSession.request(sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)])))?.count ?? -1 }
            time("full+filter") {
                let all = (try? context.fetch(ImportSession.request(sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)]))) ?? []
                return all.filter { $0.importType == type }.count
            }
            time("predicate") {
                (try? context.fetch(ImportSession.request(.equals("importType", type),
                                                           sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)])))?.count ?? -1
            }
            time("predicate+scalars") {
                let d = ImportSession.request(.equals("importType", type),
                                              sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)])
                d.propertiesToFetch = ["id", "sessionDate", "importType", "totalItems", "successCount", "errorCount",
                                       "duplicateCount", "updatedCount", "notFoundCount", "isCompleted", "isCanceled"]
                return (try? context.fetch(d))?.count ?? -1
            }
            time("predicate+limit12") {
                let d = ImportSession.request(.equals("importType", type),
                                              sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)], limit: 12)
                return (try? context.fetch(d))?.count ?? -1
            }
            time("count") {
                (try? context.count(for: ImportSession.request(.equals("importType", type)))) ?? -1
            }
            clearStore()
            return r
        }

        // `-FTDebugImportsLoop enter|tab|leave-all` (for `sample`): repeats one transition on
        // the first history size for 30 s, between LOOP-BEGIN and LOOP-END lines on stdout.
        if let loop = UserDefaults.standard.string(forKey: "FTDebugImportsLoop") {
            seed(sizes.first ?? 1000)
            await settle(500)
            print("LOOP-BEGIN \(loop)"); unsafe fflush(stdout)
            let end = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < end {
                switch loop {
                case "tab":
                    appState.navigate(to: .libraryItem(.imports))
                    ImportsState.shared.selectCategory(.ratings, persist: false); await settle(400)
                    ImportsState.shared.selectCategory(.metadata, persist: false); await settle(400)
                default:
                    appState.navigate(to: .libraryItem(.imports)); await settle(400)
                    appState.navigate(to: .libraryItem(.allFilms)); await settle(400)
                }
            }
            print("LOOP-END"); unsafe fflush(stdout)
            clearStore()
            return r
        }

        // Scale: the same corpus, gallery to gallery.
        for _ in 0..<reps {
            await measure("gallery→gallery") { appState.navigate(to: .libraryItem(.unwatched)) }
            await measure("gallery→gallery(back)") { appState.navigate(to: .libraryItem(.allFilms)) }
        }

        for size in sizes {
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(300)
            seed(size)
            ImportsState.shared.selectCategory(.metadata, persist: false)
            await settle(500)
            let metadataCount = (0..<size).filter { $0 % 10 != 9 }.count

            for _ in 0..<reps {
                await measure("enter@\(size)") { appState.navigate(to: .libraryItem(.imports)) }
                await measure("leave@\(size)") { appState.navigate(to: .libraryItem(.allFilms)) }
            }

            appState.navigate(to: .libraryItem(.imports))
            await settle(800)
            r.check("cards-listed@\(size)", (ImportsSwitchProbe.visibleCount?() ?? 0) == metadataCount,
                    "listed \(ImportsSwitchProbe.visibleCount?() ?? -1) of \(metadataCount)")
            r.metric("mounted-at-rest@\(size)", Double(ImportsSwitchProbe.mountedCount?() ?? 0), "cards")
            for _ in 0..<reps {
                await measure("tab→ratings@\(size)") { ImportsState.shared.selectCategory(.ratings, persist: false) }
                await measure("tab→metadata@\(size)") { ImportsState.shared.selectCategory(.metadata, persist: false) }
            }

            // Scrolling down the list, 60 pt per 16 ms step (a brisk trackpad scroll):
            // main-thread busy time per step and the longest.
            if metadataCount > 10, let sv = importsScrollView() {
                await settle(600)
                recorder.reset()
                let t0 = CACurrentMediaTime() * 1000
                let steps = 150
                for k in 1...steps {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(k) * 60))
                    sv.reflectScrolledClipView(sv.contentView)
                    await settle(16)
                }
                let span = CACurrentMediaTime() * 1000 - t0 + 200
                await settle(200)
                let reading = recorder.reading(from: t0, window: span)
                record("scroll-per-step@\(size)", RunLoopBusyRecorder.Reading(
                    first: reading.busy / Double(steps), busy: reading.busy / Double(steps), longest: reading.longest))
            }
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(300)
        }

        for (kind, readings) in byKind {
            r.metric("\(kind)-first-median", stats(readings.map(\.first)).median, "ms")
            r.metric("\(kind)-busy-median", stats(readings.map(\.busy)).median, "ms")
            r.metric("\(kind)-longest-median", stats(readings.map(\.longest)).median, "ms")
        }

        clearStore()
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(200)
        return r
    }
}

// MARK: - Imports Window

extension DebugHarness {

    private static func importsWindowScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-window")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        let container = coordinator.persistentContainer
        let context = container.viewContext
        let history = ImportHistory.shared
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        defer { ImportsListDebug.windows = true }

        ImportsState.shared.selectCategory(.metadata, persist: false)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(800)

        // MARK: Index

        /// What a fresh context reads from the store, as the index would group it.
        func stored() -> [String: [ImportSessionRecord]] {
            let all = (try? container.makeMainContext().fetch(
                ImportSession.request(sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)]))) ?? []
            return Dictionary(grouping: all.map(ImportSessionRecord.init), by: \.importType)
        }
        func indexed() -> [String: [ImportSessionRecord]] {
            var map: [String: [ImportSessionRecord]] = [:]
            for c in ImportsCategory.allCases {
                let records = history.records(for: c, in: container)
                if !records.isEmpty { map[c.rawValue] = records }
            }
            return map
        }
        func describe(_ map: [String: [ImportSessionRecord]]) -> String {
            map.keys.sorted().map { "\($0) \(map[$0]!.count)" }.joined(separator: ", ")
        }
        /// Polls for up to three seconds, until the store shows `done` and the index matches
        /// it: DataManager's deletes run in its own context, after a hop off the main actor,
        /// and reach the index after another hop back.
        func eventuallyMatches(_ done: ([String: [ImportSessionRecord]]) -> Bool) async -> Bool {
            for _ in 0..<60 {
                let store = stored()
                if done(store), indexed() == store { return true }
                await settle(50)
            }
            return false
        }

        // Inserts and an update saved on the main context are in the index before save() returns.
        seedImportSessions(120, context)
        r.check("index-after-insert", indexed() == stored(), "index \(describe(indexed())); store \(describe(stored()))")
        let target = (try? context.fetch(ImportSession.request(sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)])))?[4]
        target?.errorCount = 3
        target?.errorFileNames = ["A.m4v", "B.m4v", "C.m4v"]
        target?.isCanceled = false
        try? context.save()
        let updated = target.map { t in history.records(for: .metadata, in: container).first { $0.id == t.id } } ?? nil
        r.check("index-after-update", indexed() == stored() && updated?.errorCount == 3,
                "updated record errors \(updated?.errorCount ?? -1)")
        // Deletes saved by DataManager's own context, as "Clear This Item" and "Clear All" make them.
        let deleteIDs = history.records(for: .metadata, in: container).prefix(3).map(\.id)
        for id in deleteIDs { coordinator.deleteImportSession(id: id) }
        let afterDelete = await eventuallyMatches { store in
            !(store[ImportsCategory.metadata.rawValue] ?? []).contains { deleteIDs.contains($0.id) }
        }
        r.check("index-after-delete", afterDelete && !history.records(for: .metadata, in: container).contains { deleteIDs.contains($0.id) },
                "index \(describe(indexed())); store \(describe(stored()))")
        coordinator.deleteAllImportSessions(ofType: ImportsCategory.ratings.rawValue)
        let afterDeleteAll = await eventuallyMatches { $0[ImportsCategory.ratings.rawValue] == nil }
        r.check("index-after-delete-all", afterDeleteAll && history.records(for: .ratings, in: container).isEmpty,
                "index \(describe(indexed())); store \(describe(stored()))")

        // MARK: Windowed list

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
        /// The scroll view's pixels at full resolution, without the scroller's strip (an
        /// overlay scroller fades on its own clock after a programmatic scroll).
        ///
        /// The window server can re-place the window (or someone can move it) between
        /// working out the rectangle and grabbing it; seen 2026-10-05, when one capture held
        /// the window shrunk into a corner of the rectangle. So the frame is pinned first,
        /// and a grab counts only when the window held still across it.
        let pinnedFrame = window.frame
        func capture(_ sv: NSScrollView) async -> Data? {
            guard let grab = unsafe windowImageFunction else { return nil }
            for _ in 0..<10 {
                if window.frame != pinnedFrame {
                    window.setFrame(pinnedFrame, display: true)
                    await settle(300)
                    continue
                }
                let before = window.frame
                let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let rect = CGRect(x: onScreen.minX, y: screenHeight - onScreen.maxY,
                                  width: onScreen.width - 20, height: onScreen.height)
                guard let image = unsafe grab(rect, 1 << 3, CGWindowID(window.windowNumber), 1 << 0)?.takeRetainedValue()
                else { return nil }
                if window.frame == before { return image.dataProvider?.data as Data? }
                await settle(300)
            }
            return nil
        }
        func scroll(_ sv: NSScrollView, to y: CGFloat) {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
        /// Mounts a fresh Imports view on the metadata history and lets its window settle.
        func mountFresh() async -> NSScrollView? {
            appState.navigate(to: .libraryItem(.allFilms))
            await settle(400)
            appState.navigate(to: .libraryItem(.imports))
            await settle(1200)
            return importsScrollView()
        }

        let metadataCount = seedImportSessions(300, context)
        var shots: [Bool: [Data?]] = [:]
        var offsets: [CGFloat] = []
        for windows in [true, false] {
            ImportsListDebug.windows = windows
            guard let sv = await mountFresh() else {
                r.check("mounted windows=\(windows)", false, "Imports scroll view not found")
                continue
            }
            let mounted = ImportsSwitchProbe.mountedCount?() ?? -1
            let revealed = ImportsSwitchProbe.visibleCount?() ?? -1
            r.check("revealed windows=\(windows)", revealed == metadataCount, "\(revealed) of \(metadataCount)")
            if windows {
                r.check("windowed", mounted > 0 && mounted < 60, "\(mounted) of \(revealed) cards mounted")
                let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
                offsets = [0, 777, 2_600, maxY * 0.25, maxY * 0.5 + 123, maxY * 0.75 - 41, maxY - 333, maxY]
                    .map { min(maxY, max(0, $0.rounded())) }
            } else {
                r.check("full-stack", mounted == revealed, "\(mounted) of \(revealed) cards mounted")
            }
            var images: [Data?] = []
            for (i, y) in offsets.enumerated() {
                scroll(sv, to: y)
                await settle(700)
                images.append(await capture(sv))
                // `-FTDebugImportsDumpFrames YES` keeps each capture as a PNG in the container.
                if UserDefaults.standard.bool(forKey: "FTDebugImportsDumpFrames"), let dir = DebugSandbox.rootURL,
                   let grab = unsafe windowImageFunction {
                    let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
                    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                    let rect = CGRect(x: onScreen.minX, y: screenHeight - onScreen.maxY,
                                      width: onScreen.width - 20, height: onScreen.height)
                    if let image = unsafe grab(rect, 1 << 3, CGWindowID(window.windowNumber), 1 << 0)?.takeRetainedValue() {
                        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                        try? png?.write(to: dir.appendingPathComponent("window-\(windows ? "windowed" : "full")-\(i).png"))
                    }
                }
            }
            shots[windows] = images
            r.metric("document-height windows=\(windows)", Double(sv.documentView?.frame.height ?? 0), "pt")
        }
        ImportsListDebug.windows = true
        if let windowed = shots[true], let full = shots[false], windowed.count == full.count {
            for (i, y) in offsets.enumerated() {
                // The same pixels, to within one 8-bit level per channel. Core Animation
                // composites a tree with spacers in it slightly differently: at the top of
                // the list, a few dozen pixels along the viewport's bottom edge come out one
                // level apart (seen 2026-10-05: 29 pixels, 0.157 vs 0.153 gray). Anything
                // laid out differently — a card, a shadow, a line a pixel out of place —
                // differs by far more than that.
                var detail = "offset \(Int(y))"
                var same = false
                if let a = windowed[i], let b = full[i], a.count == b.count {
                    var differing = 0, worst = 0
                    for (p, q) in zip(a, b) where p != q {
                        differing += 1
                        worst = max(worst, abs(Int(p) - Int(q)))
                    }
                    same = worst <= 1
                    if differing > 0 { detail += ": \(differing) of \(a.count) bytes differ, by at most \(worst) level(s)" }
                } else {
                    detail += ": capture missing or sizes differ"
                }
                r.check("window-identical \(i)", same, detail)
            }
        } else {
            r.check("window-identical", false, "captures missing")
        }

        // MARK: Heights at the minimum width

        let heightsBefore = ImportCardMetrics.shared.heights
        r.check("shapes-measured", heightsBefore.count == ImportCardShape.allCases.count,
                heightsBefore.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        let savedFrame = window.frame
        var narrow = savedFrame
        narrow.size.width = window.minSize.width
        window.setFrame(narrow, display: true)
        await settle(500)
        if let sv = await mountFresh() {
            let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
            // Every card mounts at some point on the way down, and reports its height.
            var y: CGFloat = 0
            while y < maxY {
                scroll(sv, to: y)
                await settle(30)
                y += sv.contentView.bounds.height
            }
            scroll(sv, to: maxY)
            await settle(300)
        }
        r.check("heights-width-independent", ImportCardMetrics.shared.heights == heightsBefore,
                "width \(Int(window.frame.width)): " +
                ImportCardMetrics.shared.heights.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        window.setFrame(savedFrame, display: true)

        clearImportSessions(context)
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(200)
        return r
    }
}

// MARK: - Imports QoS

// `imports-qos` (opt-in): saves an import session on the main context — what ImportProgress
// does while an import runs, every 500 ms (updateSessionProgress) — while ImportHistory's
// full load runs, over and over. Every context shares the store's one SQLite connection, so
// a main-thread save waits for the load's fetch; at a lower QoS than the main thread that
// wait is a priority inversion. (Settings once saved here too; they now save on
// DataManager's queue.) The launch itself overlaps the first load with DataManager's
// bootstrap saves. libRPAC does not print outside Xcode: run it under lldb with
// /usr/lib/libRPAC.dylib in DYLD_INSERT_LIBRARIES and a breakpoint on libRPAC's
// `generateCulledBacktrace`, which stops on every priority inversion it detects. While the
// load ran at `.utility`, every run stopped in `NSSQLDefaultConnectionManager
// _checkoutConnectionOfType:` under a save.
//
// Without libRPAC it still measures what an inversion costs: the worst main-thread save
// (`worstSaveMs`), and checks that every save landed and the index followed the last one.
extension DebugHarness {
    private static func importsQoSScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-qos")
        let container = coordinator.persistentContainer
        let context = container.viewContext
        // `-FTDebugImportsQoSSize none` keeps the container's own sessions (a copy of a real
        // library, say); otherwise this many are seeded (default 1000).
        let sizeArgument = UserDefaults.standard.string(forKey: "FTDebugImportsQoSSize")
        let size = sizeArgument == "none" ? 0 : (sizeArgument.flatMap(Int.init) ?? 1000)
        if size > 0 { seedImportSessions(size, context) }

        // The running import's session, as ImportProgress.createSession makes it.
        let session = ImportSession(importType: ImportsCategory.metadata.rawValue, isCompleted: false, isCanceled: false)
        context.insert(session)
        try? context.commit()
        let sessionID = session.id

        var saves = 0
        var worst: Duration = .zero
        for i in 0..<12 {
            ImportHistory.shared.debugReload()
            for k in 0..<6 {
                try? await Task.sleep(for: .milliseconds(5))
                let n = i * 6 + k + 1
                session.totalItems = 72
                session.successCount = n
                session.addedTitles = (1...n).map { "QoS Film \($0)" }
                let start = ContinuousClock.now
                do {
                    try context.commit()
                    saves += 1
                } catch {
                    r.check("save", false, "\(error)")
                }
                worst = max(worst, ContinuousClock.now - start)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        r.check("saves", saves == 72, "\(saves) of 72 main-context session saves during background loads")
        r.metric("worstSaveMs", Double(worst.components.attoseconds) / 1e15 + Double(worst.components.seconds) * 1000, "ms")

        // The loads' results are folded with the saves made while they ran; the last one
        // must win once every load has landed.
        var latest = -1
        for _ in 0..<60 {
            latest = ImportHistory.shared.records(for: .metadata, in: container).first { $0.id == sessionID }?.successCount ?? -1
            if latest == 72 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        r.check("index-follows-last-save", latest == 72, "index shows \(latest) of 72 for the running session")

        if size > 0 { clearImportSessions(context) } else {
            context.delete(session)
            try? context.commit()
        }
        return r
    }
}

// MARK: - Imports Scroll

// `imports-scroll` (opt-in): how scrolling the Imports list LOOKS. A real trackpad scroll
// cannot be synthesized (see `coast-stop`, 99.20), so it drives AppKit's own automated live
// scroll (`_automateLiveScroll`) — the same concurrent, display-link-driven scrolling a
// trackpad gets — six passes down the list, each carrying on from the last
// (`-FTDebugImportsScrollFromTop YES`: each from the top). `-FTDebugImportsScrollLong YES`
// instead scrolls ~3,500 pt per pass from the top on the main thread, between the
// live-scroll notifications, one step per display frame — a long flick, which the
// automation (it always stops ~800 pt down) cannot make — and films the list's rectangle
// through the window server (the `imports-removal` capture, scroller strip excluded) while
// a 4 ms main-thread heartbeat runs. Per pass: distinct frames per second of motion, the
// median and worst gap between them, and the longest main-thread stall. Uses the
// container's own sessions (a copy of a real library).
extension DebugHarness {
    private static func importsScrollScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "imports-scroll")
        guard let appState = AppDelegate.appState,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil })
        else {
            r.check("main-window", false, "no main window")
            return r
        }
        if let reason = await keyWindowUnavailable(window) { r.skip("window-key", reason); return r }
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        // `-FTDebugImportsScrollSeed N` replaces the container's sessions with N seeded ones.
        let seeded = UserDefaults.standard.integer(forKey: "FTDebugImportsScrollSeed")
        if seeded > 0 { seedImportSessions(seeded, coordinator.persistentContainer.viewContext) }
        defer { if seeded > 0 { clearImportSessions(coordinator.persistentContainer.viewContext) } }
        ImportsState.shared.selectCategory(.metadata, persist: false)
        appState.navigate(to: .libraryItem(.imports))
        await settle(1200)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        var found: NSScrollView?
        while let v = stack.popLast(), found == nil {
            if let sv = v as? NSScrollView, let host = sv.documentView?.subviews.first,
               String(describing: type(of: host)).contains("ImportSessionList") { found = sv }
            stack.append(contentsOf: v.subviews)
        }
        guard let sv = found else {
            r.check("scroll-view", false, "Imports list not found")
            return r
        }
        r.metric("document-height", Double(sv.documentView?.frame.height ?? 0), "pt")
        r.metric("listed", Double(ImportsSwitchProbe.visibleCount?() ?? -1), "cards")
        r.metric("mounted-at-rest", Double(ImportsSwitchProbe.mountedCount?() ?? -1), "cards")
        let onScreen = window.convertToScreen(sv.convert(sv.bounds, to: nil))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: onScreen.minX, y: screenHeight - onScreen.maxY, width: onScreen.width - 20, height: onScreen.height)

        var fps: [Double] = [], medianGap: [Double] = [], worstGap: [Double] = [], stalls: [Double] = []
        var travel: [Double] = []
        let automate = NSSelectorFromString("_automateLiveScroll")
        guard sv.responds(to: automate) else {
            r.check("automation", false, "NSScrollView no longer answers _automateLiveScroll")
            return r
        }
        let passes = UserDefaults.standard.integer(forKey: "FTDebugImportsScrollPasses").nonZero ?? 6
        if passes > 6 { print("LOOP-BEGIN scroll"); unsafe fflush(stdout) }
        // Each pass carries on from where the last one stopped, as successive flicks
        // down a long list do, so passes cross the edge of the window mounted at rest.
        // Back to the top (and a pause to settle) only when the next pass would run out.
        let long = UserDefaults.standard.bool(forKey: "FTDebugImportsScrollLong")
        let continues = !long && !UserDefaults.standard.bool(forKey: "FTDebugImportsScrollFromTop")
        for _ in 0..<passes {
            let maxY = (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height
            if !continues || sv.contentView.bounds.origin.y > maxY - 800 {
                sv.contentView.setBoundsOrigin(.zero)
                sv.reflectScrolledClipView(sv.contentView)
            }
            await settle(900)
            let before = sv.contentView.bounds.origin.y
            let origin = ContinuousClock.now + .milliseconds(60)
            let beats = MainHeartbeat()
            beats.start()
            async let filmed = film(windowID: CGWindowID(window.windowNumber), rect: rect, origin: origin,
                                    duration: .milliseconds(long ? 2600 : 1300))
            try? await Task.sleep(until: origin, clock: .continuous)
            let frames: [RemovalFrame]
            if long {
                // A long flick, on the main thread: the live-scroll notifications AppKit
                // posts around a gesture, and between them one scroll per display frame
                // whose step decays from 90 pt, ~3,500 pt in all.
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: sv)
                var y = sv.contentView.bounds.origin.y, speed: CGFloat = 90
                let maxY = (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height
                while speed > 2, y < maxY {
                    y = min(maxY, y + speed)
                    speed *= 0.975
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                    await settle(16)
                }
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: sv)
                frames = await filmed
            } else {
                _ = unsafe sv.perform(automate)
                frames = await filmed
                // AppKit asserts if an automation starts while the last is still registered.
                stopAutomatedCoast(sv)
            }
            await settle(200)
            beats.stop()
            travel.append(Double(sv.contentView.bounds.origin.y - before))
            // Motion: from the first frame that differs to the last.
            let times = frames.map(\.milliseconds).filter { $0 >= 0 }
            guard times.count > 2, let first = times.first, let last = times.last, last > first else { continue }
            let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
            fps.append(Double(times.count - 1) / (last - first) * 1000)
            medianGap.append(gaps[gaps.count / 2])
            worstGap.append(gaps.last ?? 0)
            stalls.append(beats.longestGap)
        }
        r.check("scrolled", travel.allSatisfy { abs($0) > 50 }, "travel per pass " + travel.map { "\(Int($0))" }.joined(separator: ", "))
        r.metric("frames-per-second-median", stats(fps).median, "fps")
        r.metric("frame-gap-median", stats(medianGap).median, "ms")
        r.metric("frame-gap-worst-median", stats(worstGap).median, "ms")
        r.metric("frame-gap-worst-max", stats(worstGap).max, "ms")
        r.metric("main-stall-median", stats(stalls).median, "ms")
        r.metric("main-stall-max", stats(stalls).max, "ms")
        appState.navigate(to: .libraryItem(.allFilms))
        await settle(200)
        return r
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

#endif
