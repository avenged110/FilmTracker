// MARK: - DHDocumentation.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only drift check between the search code and the search guide in Documentation/.
//
// Sandboxed, the app cannot read the project folder, so Documentation/Tools/check.sh stages
// copies of the guide's HTML and of 50.00 SearchController.swift in the app's temporary
// directory (`guide-sync/`) and runs this scenario. The scenario fails when the code
// accepts something the guide does not mention: a field alias, a pill label, a smart list
// name, a keyword inside one of the keyword-driven filters, or the set of rotation
// thresholds. It cannot tell whether a description is still accurate, only that nothing
// the code accepts has gone missing, so a change to search still means re-reading the guide.

#if DEBUG

import Foundation

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

        // Every field: its name in the field table, every alias, and any abbreviated pill label.
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

        for list in SmartListType.allCases {
            r.check("guide-sync/smart-list/\(list.rawValue)", guide.contains(list.rawValue),
                    "smart list '\(list.rawValue)' is not named")
        }

        let thresholds = Preferences.rotationThresholdOptions.map(String.init).joined(separator: ", ")
        r.check("guide-sync/rotation-thresholds", guide.contains(thresholds),
                "the guide does not state the thresholds '\(thresholds)'")

        // The keyword-driven filters compare against string literals inside their bodies.
        // Lowercase literals made only of letters, digits, spaces and + - are the keywords.
        // Interpolated literals ("region \(n)") are skipped; the guide covers the numbered
        // regions by hand.
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

#endif
