// MARK: - DHCurrencyPlaceholder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only scenario for the currency fields' placeholder: hosts the real Releases carousel
// with a purchased card, focuses every DigitTextField on it over and over (fresh mounts
// included), renders the field at 4× through the window's own display path — so the shared
// field editor's drawing is what gets measured, not the cell's — and reads back where the
// placeholder ink actually sits relative to the bezel. Opt-in and in `all` as
// `currency-placeholder`: the verdict is that the ink never moves when a field takes focus.

#if DEBUG

import AppKit
import SwiftUI

extension DebugHarness {

    /// Horizontal extent of the placeholder ink inside a field, in points from the field's
    /// leading edge, measured on a 4× render of the window's content view.
    private struct InkReading: CustomStringConvertible {
        var minX: Double
        var maxX: Double
        var columns: Int
        var description: String { "ink \(Fmt.fixed(minX, 2))…\(Fmt.fixed(maxX, 2)) (\(Fmt.int(columns)) cols)" }
    }

    private static func turn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    private static func findDigitFields(in root: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, let cell = f.cell,
               String(describing: type(of: cell)).contains("RightAlignedBezelCell") {
                out.append(f)
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Renders `field` (plus a 2 pt margin) at 4× via the content view, so any subview the
    /// field editor adds is drawn exactly as the window would draw it, and returns the ink
    /// extent plus the PNG bytes.
    private static func render(_ field: NSTextField, in window: NSWindow, scale: Int = 4) -> (InkReading?, Data?) {
        guard let content = window.contentView else { return (nil, nil) }
        let rectInContent = field.convert(field.bounds, to: content).insetBy(dx: -2, dy: -2)
        let pw = Int(rectInContent.width) * scale, ph = Int(rectInContent.height) * scale
        guard let rep = unsafe NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return (nil, nil) }
        rep.size = rectInContent.size
        content.cacheDisplay(in: rectInContent, to: rep)
        let png = rep.representation(using: .png, properties: [:])

        // Interior: skip the bezel and the focus ring (about 3 pt in from the field's own
        // bounds, i.e. 5 pt in from the rendered rect), and a 1 pt band at the trailing
        // edge where the insertion point is drawn for an empty right-aligned field.
        let inset = 5 * scale
        let x0 = inset, x1 = pw - inset, y0 = inset, y1 = ph - inset
        guard x1 > x0, y1 > y0, let data = unsafe rep.bitmapData else { return (nil, png) }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        // Background is the interior's modal luminance (sampled at the four interior corners).
        func rawLum(_ x: Int, _ y: Int) -> Int {
            let p = unsafe data + y * bpr + x * spp
            return unsafe (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
        }
        let bg = [rawLum(x0, y0), rawLum(x1 - 1, y0), rawLum(x0, y1 - 1), rawLum(x1 - 1, y1 - 1)].sorted()[1]
        func lum(_ x: Int, _ y: Int) -> Int {
            let p = unsafe data + y * bpr + x * spp
            // The insertion point is drawn in the accent color; a strongly blue pixel is
            // the caret, not placeholder ink, and reads as background.
            if unsafe Int(p[2]) > Int(p[0]) + 40 { return bg }
            return unsafe (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
        }

        // The placeholder is drawn in a tertiary gray whose contrast against the bezel
        // interior differs between appearances and between the cell's and the field
        // editor's drawing, so the ink threshold is half the strongest deviation seen,
        // floored at a level that background noise never reaches.
        var peak = 0
        for x in x0..<x1 { for y in y0..<y1 { peak = max(peak, abs(lum(x, y) - bg)) } }
        let threshold = max(12, peak / 2)
        var inkCols: [Int] = []
        for x in x0..<x1 {
            var ink = 0
            for y in y0..<y1 where abs(lum(x, y) - bg) > threshold { ink += 1 }
            if ink >= 2 { inkCols.append(x) }
        }
        guard let lo = inkCols.first, let hi = inkCols.last else {
            return (InkReading(minX: -1, maxX: -1, columns: 0), png)
        }
        // Points from the field's leading edge (the render rect starts 2 pt before it).
        let toPt = { (px: Int) -> Double in Double(px) / Double(scale) - 2 }
        return (InkReading(minX: toPt(lo), maxX: toPt(hi + 1), columns: inkCols.count), png)
    }

    private static func geometry(_ field: NSTextField, in window: NSWindow) -> String {
        guard let cell = field.cell as? NSTextFieldCell else { return "no cell" }
        let b = field.bounds
        let drawing = cell.drawingRect(forBounds: b)
        let title = cell.titleRect(forBounds: b)
        var s = "bounds w=\(Fmt.fixed(b.width, 1)) drawing x=\(Fmt.fixed(drawing.minX, 1)) w=\(Fmt.fixed(drawing.width, 1)) title x=\(Fmt.fixed(title.minX, 1)) w=\(Fmt.fixed(title.width, 1))"
        if let ed = field.currentEditor() as? NSTextView {
            let ef = ed.convert(ed.bounds, to: field)
            let sf = unsafe ed.superview.map { $0.convert($0.bounds, to: field) } ?? .zero
            s += unsafe " | editor x=\(Fmt.fixed(ef.minX, 1)) w=\(Fmt.fixed(ef.width, 1)) clip x=\(Fmt.fixed(sf.minX, 1)) w=\(Fmt.fixed(sf.width, 1)) container w=\(Fmt.fixed(Double(ed.textContainer?.containerSize.width ?? -1), 1)) inset=\(Fmt.fixed(ed.textContainerInset.width, 1)) pad=\(Fmt.fixed(Double(ed.textContainer?.lineFragmentPadding ?? -1), 1)) hresize=\(Fmt.int(ed.isHorizontallyResizable ? 1 : 0)) align=\(Fmt.int(ed.alignment.rawValue))"
        } else {
            s += " | no editor"
        }
        return s
    }

    static func currencyPlaceholderScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "currency-placeholder")

        // The whole FilmSheet, in an on-screen key window, the way the user meets it: a
        // release is added through the view model, the Purchased checkbox on the new card is
        // clicked, and the cost field that swap just created is clicked. The delay between
        // the two clicks is varied, since the report is that the shift is intermittent.
        let sheet = FilmSheet(coordinator: coordinator)
        guard let vm = sheet.releasesTab else {
            r.check("view-model", false, "FilmSheet has no releases tab")
            return r
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FilmSheetView(owner: sheet).frame(width: 900, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 20, y: 20))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await turn() }
        sheet.selectedTab = .releases
        for _ in 0..<12 { await turn() }
        try? await Task.sleep(for: .milliseconds(300))
        log("currency-placeholder: window scale \(Fmt.fixed(window.backingScaleFactor, 1)) key=\(Fmt.int(window.isKeyWindow ? 1 : 0))")

        let outDir = DebugSandbox.rootURL?.appendingPathComponent("currency-placeholder")
        if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

        func settle() async {
            for _ in 0..<4 { await turn() }
            try? await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await turn()
        }
        // Posted, not sent: an NSTextField's mouse-down runs a tracking loop that pulls
        // the mouse-up from the event queue, so both events must already be queued.
        func click(_ v: NSView) {
            let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            let t = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
                                                timestamp: t, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [],
                                              timestamp: t + 0.05, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
            else { return }
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        func loopControls() -> [NSView] {
            let entries = vm.carouselEntries
            guard entries.indices.contains(vm.currentCardIndex) else { return [] }
            return FilmSheetKeyLoop.shared.controls(inCard: entries[vm.currentCardIndex].id, in: window)
        }

        var worstShift = 0.0
        var shifted = 0
        var cycles = 0
        var summary: [String] = []
        let delays: [Int] = [0, 30, 80, 150, 300, 600]

        for (trial, delayMs) in (delays + delays).enumerated() {
            window.makeFirstResponder(nil)
            await settle()
            vm.addRelease(format: ReleaseFormat.bluRay.rawValue)
            for _ in 0..<12 { await turn() }
            try? await Task.sleep(for: .milliseconds(700))   // the carousel's travel
            await settle()
            let model = vm.carouselEntries.indices.contains(vm.currentCardIndex)
                ? vm.releases.first { $0.id == vm.carouselEntries[vm.currentCardIndex].id } : nil
            guard let model else { r.check("t\(trial)-new-card", false, "no current card after add"); continue }
            r.check("t\(trial)-new-card-unpurchased", !model.purchased, "new card is already purchased")

            let loop = loopControls()
            guard let checkbox = loop.first as? NSButton else {
                r.check("t\(trial)-checkbox", false, "first loop stop is \(loop.first.map { String(describing: type(of: $0)) } ?? "nil")")
                continue
            }
            click(checkbox)
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) } else { await turn() }

            // The cost field: the first right-aligned digit field on the current card.
            let field = findDigitFields(in: host).filter { f in
                loopControls().contains { $0 === f }
            }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }.first
            guard let field else {
                await settle()
                r.check("t\(trial)-cost-field", model.purchased, "purchased=\(model.purchased) and no cost field after \(delayMs) ms")
                continue
            }
            // A reference reading of the unfocused field for this trial: taken before the
            // click when the layout has settled, otherwise from the previous trial.
            let (before, _) = render(field, in: window)
            let geoBefore = geometry(field, in: window)
            click(field)
            await settle()
            try? await Task.sleep(for: .milliseconds(200))
            await settle()
            let (after, png) = render(field, in: window)
            let geoAfter = geometry(field, in: window)
            let editing = field.currentEditor() != nil
            cycles += 1
            let label = "t\(trial)d\(delayMs)"
            r.check("\(label)-purchased", model.purchased, "checkbox click did not set purchased")
            r.check("\(label)-editing", editing, "cost field did not take the field editor")
            guard let before, let after else { r.check("\(label)-rendered", false, "render failed"); continue }
            let shift = after.minX - 12.25   // the settled, unfocused reading from the first run
            let line = unsafe String(format: "%@ editing=%d before[%@] after[%@] shift=%.2f\n   before: %@\n   after:  %@",
                              label, editing ? 1 : 0, before.description, after.description, shift, geoBefore, geoAfter)
            summary.append(line)
            if abs(shift) > 0.3 || after.columns == 0 {
                shifted += 1
                worstShift = max(worstShift, abs(shift))
                if let png, let outDir { try? png.write(to: outDir.appendingPathComponent("\(label)-shifted.png")) }
            } else if trial == 0, let png, let outDir {
                try? png.write(to: outDir.appendingPathComponent("\(label)-ok.png"))
            }
            window.makeFirstResponder(nil)
            await settle()
            // Remove the card again so the carousel does not fill up.
            vm.releases.removeAll { $0.id == model.id }
            await settle()
        }
        // MARK: The stale field editor
        // The real-library log (2026-09-19) showed the mechanism: the window's shared field
        // editor keeps the frame width of the field it served last, and only shrinks to the
        // new cell's rect at the next layout — so a right-aligned placeholder is drawn far
        // to the right of the clip for the first frame. Reproduced here by focusing a wide
        // field, then a cost field, and reading the editor's width synchronously, before
        // any run-loop turn: it must already match the clip.
        do {
            vm.addRelease(format: ReleaseFormat.bluRay.rawValue)
            for _ in 0..<12 { await turn() }
            try? await Task.sleep(for: .milliseconds(700))
            await settle()
            if let checkbox = loopControls().first as? NSButton {
                click(checkbox)
                await settle()
                try? await Task.sleep(for: .milliseconds(200))
                await settle()
            }
            var wide: NSTextField?
            func walk(_ v: NSView) {
                if let f = v as? NSTextField, f.isEditable, f.isEnabled, f.bounds.width > 200, unsafe f.window != nil,
                   loopControls().contains(where: { $0 === f }) { wide = wide ?? f }
                v.subviews.forEach(walk)
            }
            walk(host)
            let cost = findDigitFields(in: host).filter { f in loopControls().contains { $0 === f } }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }.first
            r.check("stale-editor-fixture", wide != nil && cost != nil,
                    "wide=\(wide.map { String(describing: type(of: $0)) } ?? "nil") cost=\(cost != nil)")
            if let wide, let cost {
                var worst = 0.0
                let texts = ["", "Criterion Collection", "A rather longer note that runs past the field", "x", "Arrow Video"]
                for (i, text) in texts.enumerated() {
                    window.makeFirstResponder(wide)
                    await settle()
                    // Type into the wide field the way a user would, so the editor's layout
                    // manager holds that text's glyphs when it moves on.
                    if let wed = wide.currentEditor() as? NSTextView { wed.insertText(text, replacementRange: wed.selectedRange()) }
                    await settle()
                    let wideEditor = (wide.currentEditor() as? NSTextView).map { $0.frame.width } ?? -1
                    for viaClick in [false, true] {
                        if viaClick { window.makeFirstResponder(wide); await settle(); click(cost) } else { window.makeFirstResponder(cost) }
                        // Synchronous reading, then one after each of the next turns: the
                        // first draw happens somewhere in there.
                        var readings: [String] = []
                        var excess = 0.0
                        for step in 0..<4 {
                            if step > 0 { await turn() }
                            if let ed = cost.currentEditor() as? NSTextView {
                                let e = ed.frame.width, c = unsafe ed.superview?.frame.width ?? -1
                                readings.append("\(Fmt.int(step)):\(Fmt.fixed(e, 0))/\(Fmt.fixed(c, 0))")
                                excess = max(excess, e - c)
                            } else { readings.append("\(step):none") }
                        }
                        log("currency-placeholder: stale-editor[\(i)\(viaClick ? "c" : "k")] wide=\(Int(wideEditor)) '\(text)' → cost editor/clip " + readings.joined(separator: " "))
                        worst = max(worst, excess)
                        window.makeFirstResponder(nil)
                        await settle()
                    }
                    // Leave the wide field as it was.
                    wide.stringValue = ""
                }
                r.metric("stale-editor-excess", worst, "pt")
                r.check("editor-width-matches-clip-on-focus", worst <= 0.5,
                        "field editor is \(Fmt.fixed(worst, 0)) pt wider than its clip at focus")

                // The configuration that makes a stale width impossible, and that a full
                // value still fits: the editor is not horizontally resizable, its width
                // tracks the clip, and "999" typed into the field renders whole inside the
                // bezel interior (9…38 pt), with nothing drawn wider than the placeholder was.
                window.makeFirstResponder(cost)
                await settle()
                if let ed = cost.currentEditor() as? NSTextView {
                    r.check("editor-not-horizontally-resizable", !ed.isHorizontallyResizable,
                            "right-aligned digit field's editor is horizontally resizable")
                    unsafe r.check("editor-width-tracks-clip", ed.textContainer?.widthTracksTextView == true
                                && abs(ed.frame.width - (ed.superview?.frame.width ?? -1)) < 0.5,
                            unsafe "editor w=\(Fmt.fixed(ed.frame.width, 1)) clip w=\(Fmt.fixed(Double(ed.superview?.frame.width ?? -1), 1)) tracks=\(Fmt.int(ed.textContainer?.widthTracksTextView == true ? 1 : 0))")
                    ed.insertText("999", replacementRange: ed.selectedRange())
                    await settle()
                    let (full, png) = render(cost, in: window)
                    if let png, let outDir { try? png.write(to: outDir.appendingPathComponent("typed-999.png")) }
                    log("currency-placeholder: typed 999 → \(full?.description ?? "no render") editor w=\(ed.frame.width)")
                    r.check("typed-999-inside-interior", (full.map { $0.minX >= 9 && $0.maxX <= 38 && $0.columns > 60 }) == true,
                            "typed value renders at \(full?.description ?? "-"), expected within 9…38 pt")
                    ed.selectAll(nil); ed.delete(nil)
                    await settle()
                }
                window.makeFirstResponder(nil)
                await settle()
            }
        }

        for line in summary { log("currency-placeholder: " + line) }
        r.metric("cycles", Double(cycles), "count")
        r.metric("shifted-cycles", Double(shifted), "count")
        r.metric("worst-shift", worstShift, "pt")
        r.check("placeholder-never-moves", shifted == 0,
                "placeholder ink moved or clipped in \(shifted)/\(cycles) focus cycles (worst \(worstShift) pt); PNGs in \(outDir?.path ?? "-")")
        window.contentView = nil
        window.close()
        return r
    }
}

#endif
