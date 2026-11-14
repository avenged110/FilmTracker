// MARK: - DHImportsSwitch.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only scenario for the Imports view (28_00).
///
/// `imports-window` (in the `imports` suite) checks what keeps entering and leaving the view cheap
/// whatever the history size:
///   • ImportHistory (28_20) matches the store after main-context inserts and updates —
///     synchronously, before `save()` returns — and after DataManager's deletes;
///   • ImportSessionList mounts only a window of a long list, and what the window
///     shows is pixel-identical to the full stack at offsets throughout it, to within one
///     8-bit level of compositing rounding (`window-identical`), scroller strip left out;
///   • every card shape keeps its height at the window's minimum width, which the windowed
///     layout's spacers rely on.

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
        case "imports-window": return await importsWindowScenario(coordinator: coordinator)
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

        /// Inserts and an update saved on the main context are in the index before save() returns.
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
        /// Deletes saved by DataManager's own context, as "Clear This Item" and "Clear All" make them.
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
        /// working out the rectangle and grabbing it, and a capture can then hold the window
        /// shrunk into a corner of the rectangle. So the frame is pinned first,
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
                /// `-FTDebugImportsDumpFrames YES` keeps each capture as a PNG in the container.
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
                /// The same pixels, to within one 8-bit level per channel. Core Animation
                /// composites a tree with spacers in it slightly differently: at the top of
                /// the list, a few dozen pixels along the viewport's bottom edge come out one
                /// level apart. Anything
                /// laid out differently — a card, a shadow, a line a pixel out of place —
                /// differs by far more than that.
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
            /// Every card mounts at some point on the way down, and reports its height.
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

#endif
