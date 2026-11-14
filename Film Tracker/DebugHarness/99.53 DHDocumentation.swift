// MARK: - DHDocumentation.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only drift check between the search code and the search guide in Documentation/.
///
/// Sandboxed, the app cannot read the project folder, so Documentation/Tools/check.sh stages
/// copies of the guide's HTML and of 50.00 SearchController.swift in the app's temporary
/// directory (`guide-sync/`) and runs this scenario. The scenario fails when the code
/// accepts something the guide does not mention: a field alias, a pill label, an Is term, a smart
/// list name, a keyword inside one of the keyword-driven filters, or the set of rotation
/// thresholds. It cannot tell whether a description is still accurate, only that nothing
/// the code accepts has gone missing, so a change to search still means re-reading the guide.

#if DEBUG

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension DebugHarness {

    static func documentationDriftScenario() -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "guide-sync")

        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("guide-sync")
        let guideURL = staged.appendingPathComponent("SearchGuide.html")
        let controllerURL = staged.appendingPathComponent("SearchController.swift")
        guard let guide = try? String(contentsOf: guideURL, encoding: .utf8),
              let controller = try? String(contentsOf: controllerURL, encoding: .utf8) else {
            r.check("guide-sync/sources-found", false,
                    "nothing staged in \(staged.path); run Documentation/Tools/check.sh, which stages the files and runs this scenario")
            return r
        }
        r.check("guide-sync/sources-found", true)

        /// True when `term` appears in the guide as a whole token: not glued to letters or
        /// digits on either side, so "rem" is not satisfied by "remastered".
        func guideMentions(_ term: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return guide.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                               options: [.regularExpression, .caseInsensitive]) != nil
        }

        /// Every field: its name in the field table, every alias, and any abbreviated pill label.
        for field in SearchField.allCases {
            r.check("guide-sync/field-name/\(field.rawValue)", guide.contains("<strong>\(field.displayName)</strong>"),
                    "the field table has no row named '\(field.displayName)'")
            for alias in field.aliases {
                r.check("guide-sync/alias/\(alias)", guide.contains("<code>\(alias)</code>"),
                        "alias '\(alias)' of \(field.displayName) is not listed as <code>\(alias)</code>")
            }
            if field.tokenPillLabel != field.displayName {
                r.check("guide-sync/pill-label/\(field.rawValue)",
                        guide.contains("class=\"pill\">\(field.tokenPillLabel)</span>"),
                        "pill label '\(field.tokenPillLabel)' of \(field.displayName) is not shown")
            }
        }

        /// Every Is term, under each spelling it accepts.
        for term in FilmFlag.terms {
            for spelling in [term.display] + term.aliases {
                r.check("guide-sync/is-term/\(spelling)", guide.contains("<code>\(spelling)</code>"),
                        "Is term '\(spelling)' is not listed as <code>\(spelling)</code>")
            }
        }

        for list in SmartListType.allCases {
            r.check("guide-sync/smart-list/\(list.rawValue)", guide.contains(list.rawValue),
                    "smart list '\(list.rawValue)' is not named")
        }

        let thresholds = Preferences.rotationThresholdOptions.map(String.init).joined(separator: ", ")
        r.check("guide-sync/rotation-thresholds", guide.contains(thresholds),
                "the guide does not state the thresholds '\(thresholds)'")

        /// The keyword-driven filters compare against string literals inside their bodies.
        /// Lowercase literals made only of letters, digits, spaces and + - are the keywords.
        /// Interpolated literals ("region \(n)") are skipped; the guide covers the numbered
        /// regions by hand.
        for function in ["filterByReleases", "regionLockTags", "filterByRotationThreshold", "filterByDateField",
                         "naturalDateWords", "naturalDateUnit", "naturalDateQuantity", "naturalDateOffset",
                         "naturalDateMatcher", "naturalDateSpan", "naturalDatePortion"] {
            guard let start = controller.range(of: "func \(function)("),
                  let end = controller.range(of: "\n    }\n", range: start.upperBound..<controller.endIndex) else {
                r.check("guide-sync/keywords/\(function)", false, "could not find \(function) in the controller source")
                continue
            }
            let body = String(controller[start.upperBound..<end.lowerBound])
            var keywords: [String] = []
            var seen = Set<String>()
            var searchRange = body.startIndex..<body.endIndex
            while let match = body.range(of: #""([^"\\\n]+)""#, options: .regularExpression, range: searchRange) {
                let literal = String(body[match]).dropFirst().dropLast()
                searchRange = match.upperBound..<body.endIndex
                let keyword = String(literal)
                guard keyword.range(of: #"^[a-z0-9][a-z0-9+\- ]*$"#, options: .regularExpression) != nil,
                      seen.insert(keyword).inserted else { continue }
                keywords.append(keyword)
            }
            r.check("guide-sync/keywords/\(function)/found-some", !keywords.isEmpty, "no keyword literals found")
            for keyword in keywords {
                r.check("guide-sync/keyword/\(function)/\(keyword)", guideMentions(keyword),
                        "keyword '\(keyword)' accepted by \(function) is not in the guide")
            }
        }
        return r
    }
}


// MARK: - Doc Shots

/// `doc-shots` (opt-in, not in any suite): screenshots for the guides in Documentation/.
/// Drives the REAL main window through a script, `<sandbox>/doc-shots.txt`, one step per
/// line, fields separated by `|`, and writes each capture as a PNG at the display's full
/// resolution to `<sandbox>/doc-shots/`. Captures come from the window server
/// (CGWindowListCreateImage on the app's own windows), so they show exactly what is on
/// screen. Launch with `open -n` so the window can become key; run it against a copy of a
/// library (with posters) in its own sandbox.
///
/// Steps: `wait|ms` · `appearance|dark|light` · `size|w|h` · `nav|all|unwatched|recents|
/// reports|imports|queue` · `nav|smart|<Smart List>` · `nav|list|<name>` · `nav|saved|<name>` ·
/// `tab|n` (the view's own tabs, 1-based) · `style|list|grid` · `select|<title>|<title>…` ·
/// `selectfirst|n` · `scroll` · `rsb|details|releases|notes` · `cmd|editFilm|editMetadata|
/// editReleases|duplicates|newSavedSearch|saveSearch|upNextSlot|addFilm|newList` ·
/// `cmd|settings|<n>` · `cmd|editSaved|<name>` · `sheettab|n` · `settingstab|n` · `dismiss` ·
/// `token|#field value` · `text|<plain text>` · `focussearch` · `type|<keystrokes>` (into the
/// focused field) · `clearsearch` ·
/// `shot|window|<name>` (main window) · `shot|sheet|<name>` (its sheet) ·
/// `shot|screen|<name>` (everything of ours over the main window's frame: popovers, menus
/// of suggestions, a sheet in place).
extension DebugHarness {
    static func docShotsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "doc-shots")
        guard let root = DebugSandbox.rootURL else {
            r.check("sandbox", false, "no sandbox root")
            return r
        }
        guard let script = try? String(contentsOf: root.appendingPathComponent("doc-shots.txt"), encoding: .utf8) else {
            r.check("script", false, "no doc-shots.txt in \(root.path)")
            return r
        }
        guard let appState = AppDelegate.appState else {
            r.check("app-state", false, "no AppDelegate.appState")
            return r
        }
        let output = root.appendingPathComponent("doc-shots")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

        /// The first gallery frame, then a moment for posters.
        let deadline = ContinuousClock.now + .seconds(15)
        while LaunchTimeline.milliseconds(for: "galleryFirstCommit") == nil, ContinuousClock.now < deadline {
            await settle(50)
        }
        await settle(1500)
        func mainWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) && !$0.isSheet }
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow()?.makeKeyAndOrderFront(nil)

        func films(named names: [String]) -> Set<UUID> {
            let all = coordinator.getAllFilms()
            var ids: Set<UUID> = []
            for name in names {
                if let film = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    ids.insert(film.id)
                } else {
                    r.check("film \(name)", false, "not found")
                }
            }
            return ids
        }

        func save(_ image: CGImage, _ name: String) {
            let url = output.appendingPathComponent("\(name).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                r.check("shot \(name)", false, "no destination"); return
            }
            CGImageDestinationAddImage(dest, image, nil)
            r.check("shot \(name)", CGImageDestinationFinalize(dest), "\(image.width)×\(image.height)")
        }

        func shoot(_ target: String, _ name: String) {
            guard let capture = unsafe windowImageFunction, let window = mainWindow() else {
                r.check("shot \(name)", false, "no capture function or window"); return
            }
            /// Window list options: on screen only (1 << 0), including window (1 << 3). Image
            /// options: bounds ignore framing (1 << 0), best resolution (1 << 3).
            let image: CGImage?
            switch target {
            case "sheet":
                guard let sheet = window.attachedSheet else { r.check("shot \(name)", false, "no sheet"); return }
                image = unsafe capture(.null, 1 << 3, UInt32(sheet.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
            case "screen":
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let f = window.frame
                let rect = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
                image = unsafe capture(rect, 1 << 0, 0, 1 << 3)?.takeRetainedValue()
            default:
                image = unsafe capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
            }
            guard let image else { r.check("shot \(name)", false, "capture returned nil"); return }
            save(image, name)
        }

        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let arg = f.count > 1 ? f[1] : ""
            log("doc-shots: \(line)")
            switch f[0] {
            case "wait":
                await settle(Int(arg) ?? 500)
            case "appearance":
                NSApp.appearance = NSAppearance(named: arg == "light" ? .aqua : .darkAqua)
                await settle(600)
            case "size":
                if let window = mainWindow(), let w = Double(arg), f.count > 2, let h = Double(f[2]),
                   let screen = window.screen ?? NSScreen.main {
                    let visible = screen.visibleFrame
                    let frame = NSRect(x: visible.minX + 20, y: visible.maxY - 20 - h, width: w, height: h)
                    window.setFrame(frame, display: true, animate: false)
                }
                await settle(800)
            case "nav":
                let item: SidebarItem?
                switch arg {
                case "all": item = .libraryItem(.allFilms)
                case "unwatched": item = .libraryItem(.unwatched)
                case "recents": item = .libraryItem(.recents)
                case "reports": item = .libraryItem(.reports)
                case "imports": item = .libraryItem(.imports)
                case "queue": item = .libraryItem(.filmQueue)
                case "smart": item = SmartListType.allCases.first { $0.rawValue == f[2] }.map { .smartList($0) }
                case "list": item = coordinator.getAllLists().first { $0.listName == f[2] }.map { .list($0.listID) }
                case "saved": item = SavedSearchStore.shared.searches.first { $0.name == f[2] }.map { .savedSearch($0.id) }
                default: item = nil
                }
                guard let item else { r.check("nav \(line)", false, "unknown"); continue }
                appState.navigate(to: item)
                await settle(1200)
            case "tab":
                let i = (Int(arg) ?? 1) - 1
                switch appState.selectedSidebarItem {
                case .libraryItem(.unwatched): UnwatchedState.shared.selectCategory(UnwatchedCategory.allCases[i])
                case .libraryItem(.recents): RecentsState.shared.selectCategory(RecentsCategory.allCases[i])
                case .libraryItem(.reports): ReportsState.shared.selectCategory(ReportsCategory.allCases[i])
                case .libraryItem(.imports): ImportsState.shared.selectCategory(ImportsCategory.allCases[i], persist: false)
                case .libraryItem(.filmQueue): FilmQueueFilterState.shared.selectFilter(FilmQueueFilter.allCases[i])
                default: r.check("tab \(line)", false, "no tabs here")
                }
                await settle(1200)
            case "style":
                ViewStateManager.shared.updateListViewStyle(arg == "list")
                await settle(1000)
            case "select":
                SelectionState.shared.selectImmediate(films(named: Array(f.dropFirst())))
                await settle(1200)
            case "selectfirst":
                SelectionState.shared.selectImmediate(Set(coordinator.films.prefix(Int(arg) ?? 1).map(\.id)))
                await settle(1200)
            case "scroll":
                AppEventBus.shared.sendCommand(.scrollToSelection)
                await settle(800)
            case "rsb":
                if let tab = RightSidebarTab(rawValue: arg) { ViewStateManager.shared.setRightSidebarTab(tab) }
                await settle(1000)
            case "cmd":
                switch arg {
                case "editFilm": AppEventBus.shared.sendCommand(.editFilm)
                case "editMetadata": AppEventBus.shared.sendCommand(.editFilmMetadata)
                case "editReleases": AppEventBus.shared.sendCommand(.editFilmReleases())
                case "duplicates": AppEventBus.shared.sendCommand(.findDuplicates)
                case "addFilm": AppEventBus.shared.sendCommand(.addFilm)
                case "newList": AppEventBus.shared.sendCommand(.showListCreation)
                case "upNextSlot": AppEventBus.shared.sendCommand(.openUpNextSlot)
                case "newSavedSearch": SavedSearchActions.newSearch()
                case "saveSearch": SavedSearchActions.saveCurrentSearch()
                case "settings":
                    let i = (f.count > 2 ? Int(f[2]) ?? 1 : 1) - 1
                    AppEventBus.shared.sendCommand(.openSettingsToTab(tab: SettingsTab.allCases[i]))
                case "editSaved":
                    if let search = SavedSearchStore.shared.searches.first(where: { $0.name == f[2] }) {
                        SavedSearchActions.edit(search.id)
                    }
                default: r.check("cmd \(line)", false, "unknown")
                }
                await settle(1800)
            case "sheettab":
                AppEventBus.shared.sendCommand(.changeFilmSheetTab(tab: Int(arg) ?? 1))
                await settle(1200)
            case "settingstab":
                AppEventBus.shared.sendCommand(.changeSettingsSheetTab(tab: Int(arg) ?? 1))
                await settle(1200)
            case "dismiss":
                appState.sheetCoordinator.dismissSheet()
                await settle(1200)
            case "token":
                SearchController.shared.searchText = SearchController.shared.searchText + arg
                SearchController.shared.processSearchSubmission()
                await settle(1200)
            case "text":
                SearchController.shared.searchText = arg
                await settle(1500)
            case "focussearch":
                if let toolbar = mainWindow()?.toolbar,
                   let search = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.search" }) as? NSSearchToolbarItem {
                    search.beginSearchInteraction()
                }
                await settle(800)
            case "type":
                /// Through the field editor, as keystrokes arrive, so the field's own
                /// change handling (suggestions included) runs.
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    for character in arg {
                        editor.insertText(String(character), replacementRange: editor.selectedRange())
                        await settle(60)
                    }
                } else {
                    r.check("type \(line)", false, "no field editor")
                }
                await settle(1500)
            case "clearsearch":
                SearchController.shared.clearSearch()
                await settle(1200)
            case "shot":
                shoot(arg, f.count > 2 ? f[2] : "shot")
            default:
                r.check("step \(line)", false, "unknown step")
            }
        }
        return r
    }
}

#endif
