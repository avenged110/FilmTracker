// MARK: - RatingsParser.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Parses Blu-ray.com ratings HTML files and extracts film ratings.

import Foundation

// MARK: - Parsed Rating Data Model
struct ParsedRating: Sendable { let title: String; let year: String; let rating: Int }

// Deliberately not @MainActor. The parser is stateless and touches no MainActor state,
// and parseFile reads, lowercases, splits and regex-scans an entire collection export —
// a multi-megabyte file for a large collection. As a nonisolated async method on a
// Sendable type, parseFile runs on the global executor, so RatingsImporter's `await`
// suspends the main actor instead of blocking it for the whole parse.
final class RatingsParser: Sendable, Loggable {
    nonisolated static let logTag = "[RatingsParser]"

    // MARK: - Public Interface
    func parseFile(_ url: URL) async -> [ParsedRating]? {
        Self.log("Parsing ratings file: \(url.lastPathComponent)")

        // Read the HTML file with multiple encoding attempts
        guard let htmlContent = readHTMLFile(url) else {
            Self.log("ERROR: Failed to read HTML file")
            return nil }
        Self.log("Successfully read the HTML file (\(htmlContent.count) characters)")

        // Verify the file is from Blu-ray.com
        guard isFromBluRay(htmlContent) else {
            Self.log("ERROR: File does not appear to be from Blu-ray.com")
            return nil }
        Self.log("Successfully verified the file is from Blu-ray.com")

        // Parse ratings from the HTML
        let ratings = extractRatings(from: htmlContent)
        Self.log("Extracted \(ratings.count) ratings from file")
        // Return an empty array (not nil) so the caller can distinguish
        // a valid-but-empty file from a file that failed to parse.
        return ratings }

    // MARK: - File Reading
    private func readHTMLFile(_ url: URL) -> String? {
        // Try UTF-8 first.
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content }
        // Try ISO Latin 1.
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            log("Read file using ISO Latin 1 encoding")
            return content }
        // Try Windows CP1252.
        if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
            log("Read file using Windows CP1252 encoding")
            return content }
        // Try ASCII.
        if let content = try? String(contentsOf: url, encoding: .ascii) {
            log("Read file using ASCII encoding")
            return content }
        return nil }

    // MARK: - Validation
    private func isFromBluRay(_ html: String) -> Bool {
        // Check for Blu-ray.com-specific href links in the header (case-insensitive).
        let lowercaseHTML = html.lowercased()
        let bluRayIndicators = [
            "blu-ray.com",
            "www.blu-ray.com",
            "https://www.blu-ray.com" ]
        return bluRayIndicators.contains { lowercaseHTML.contains($0) } }

    // MARK: - Rating Extraction
    private func extractRatings(from html: String) -> [ParsedRating] {
        var ratings: [ParsedRating] = []
        // Split HTML into lines for processing.
        let lines = html.components(separatedBy: .newlines)
        log("Processing \(lines.count) lines from HTML file")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            // Look for table rows that contain movie links.
            // Pattern variations:
            // - <td class="middle"><a href="https://www.blu-ray.com/...">Title</a></td>
            // - <td class='middle'><a href='https://www.blu-ray.com/...'>Title</a></td>
            // - With or without www.
            if containsMovieLink(line) {
                // Extract title and URL from the line.
                if let (title, urlPath) = extractTitleAndURL(from: line) {
                    log("Found movie link: '\(title)' at path '\(urlPath)'")
                    // Look ahead for year and rating in subsequent lines.
                    if let (year, rating) = extractYearAndRating(
                        from: lines, startingAt: i + 1) {
                        let parsedRating = ParsedRating(title: title, year: year, rating: rating)
                        ratings.append(parsedRating)
                        log("Successfully parsed: '\(title)' (\(year)) - Rating: \(rating)")
                    } else { log("WARNING: Could not find year/rating for '\(title)'") } } }
            i += 1 }
        log("Total ratings extracted: \(ratings.count)")
        return ratings }

    // Check if line contains a Blu-ray.com movie link
    private func containsMovieLink(_ line: String) -> Bool {
        let lowercaseLine = line.lowercased()
        return (lowercaseLine.contains("<td class=\"middle\">") ||
            lowercaseLine.contains("<td class='middle'>")) &&
            (lowercaseLine.contains("blu-ray.com/") ||
            lowercaseLine.contains("www.blu-ray.com/")) }

    // Extract title and URL path from the link line.
    // Returns: (title, urlPath) or nil.
    private func extractTitleAndURL(from line: String) -> (String, String)? {
        // Find the href URL.
        guard let hrefStart = line.range(of: "href=\"", options: .caseInsensitive) ??
            line.range(of: "href='", options: .caseInsensitive) else { return nil }

        // Find the closing quote.
        let searchStart = hrefStart.upperBound
        guard let hrefEnd = line.range(of: "\"", range: searchStart..<line.endIndex) ??
            line.range(of: "'", range: searchStart..<line.endIndex) else { return nil }

        let fullURL = String(line[searchStart..<hrefEnd.lowerBound])
        // Extract the path component from the URL.
        // Example URL: https://www.blu-ray.com/Baby-Driver/413161/
        // Seeking: Baby-Driver

        // Find the last two path components before the trailing slash.
        let urlComponents = fullURL.components(separatedBy: "/").filter { !$0.isEmpty }
        // Look for the movie title component (typically second to last component).
        guard urlComponents.count >= 2 else {
            log("WARNING: URL has unexpected structure: \(fullURL)")
            return nil }
        // The movie title is typically the second-to-last component.
        let titleComponent = urlComponents[urlComponents.count - 2]
        // Convert dashes and underscores to spaces.
        var title = titleComponent.replacingOccurrences(of: "-", with: " ")
        title = title.replacingOccurrences(of: "_", with: " ")
        // Decode URL encoding (e.g., %20 -> space).
        if let decodedTitle = title.removingPercentEncoding { title = decodedTitle }
        // Clean up multiple spaces.
        title = title.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (title, titleComponent) }

    // Extract year and rating from subsequent lines.
    // NOTE: Skips items containing year ranges.
    // Looks for patterns like:
    // <td><font class="gray">2017</font></td><td><center>9</center></td>
    // <td class="gray">2017</td><td><center>9</center></td>
    // <td>2017</td><td>9</td>
    private func extractYearAndRating(from lines: [String], startingAt index: Int) -> (String, Int)? {
        // Look in the next several lines for the year and rating pattern.
        let searchRange = min(index + 10, lines.count)
        for i in index..<searchRange {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            // Try multiple patterns for year and rating.
            if let result = tryExtractYearAndRating(from: line) { return result } }
        return nil }

    // Try to extract year and rating from a single line.
    // Returns 'nil' immediately if year validation fails.
    private func tryExtractYearAndRating(from line: String) -> (String, Int)? {
        // Pattern 1: <font class="gray">YYYY</font></td><td><center>R</center>.
        if let year = extractYearPattern1(from: line) {
            // Year validation already happened in extractYearPattern1.
            if let rating = extractCenteredRating(from: line, after: "</font></td>") { return (year, rating) } }

        // Pattern 2: <td class="gray">YYYY</td><td><center>R</center>.
        if let year = extractYearPattern2(from: line) {
            // Year validation already happened in extractYearPattern2.
            if let rating = extractCenteredRating(from: line, after: "</td>") { return (year, rating) } }

        // Pattern 3: Simple <td>YYYY</td><td>R</td>.
        if let year = extractYearPattern3(from: line) {
            // Year validation already happened in extractYearPattern3.
            if let rating = extractRatingPattern3(from: line) { return (year, rating) } }

        return nil }

    // Pattern 1: <font class="gray">YYYY</font>.
    private func extractYearPattern1(from line: String) -> String? {
        guard let grayStart = line.range(of: "<font class=\"gray\">",
        options: .caseInsensitive) ?? line.range(of: "<font class='gray'>",
        options: .caseInsensitive) else { return nil }

        guard let grayEnd = line.range(of: "</font>", options: .caseInsensitive,
            range: grayStart.upperBound..<line.endIndex) else { return nil }

        let yearString = String(line[grayStart.upperBound..<grayEnd.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return validateYear(yearString) }

    // Pattern 2: <td class="gray">YYYY</td>.
    private func extractYearPattern2(from line: String) -> String? {
        guard let tdStart = line.range(of: "<td class=\"gray\">",
        options: .caseInsensitive) ?? line.range(of: "<td class='gray'>",
        options: .caseInsensitive) else { return nil }

        guard let tdEnd = line.range(of: "</td>", options: .caseInsensitive,
            range: tdStart.upperBound..<line.endIndex) else { return nil }

        let yearString = String(line[tdStart.upperBound..<tdEnd.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return validateYear(yearString) }

    // Pattern 3: <td>YYYY</td> (when followed by rating).
    private func extractYearPattern3(from line: String) -> String? {
        // Look for <td>YYYY</td><td>R</td> pattern.
        let tdMatches = matches(for: "<td>([^<]+)</td>", in: line)
        // At least 2 <td> tags (year and rating) are required.
        guard tdMatches.count >= 2 else { return nil }
        // First match should be the year.
        let potentialYear = tdMatches[0].trimmingCharacters(in: .whitespaces)
        return validateYear(potentialYear) }

    // Validate that the string is a 4-digit year (not a range).
    private func validateYear(_ yearString: String) -> String? {
        // Check if the string contains a dash (indicating a year range).
        if yearString.contains("-") {
            log("DISCARDED: Year range detected '\(yearString)' - not a film")
            return nil }

        // Validate it's a 4-digit year.
        guard yearString.count == 4, let yearInt = Int(yearString),
            yearInt >= 1800 && yearInt <= 2100 else { return nil }
        return yearString }

    // Patterns 1 and 2: `<yearClose><td><center>R</center>` — or the same cell opened as
    // `<td align="center">` / `<td align='center'>` and closed by `</td>` — where
    // `yearClose` is the year cell's own closing markup (`</font></td>` for pattern 1,
    // `</td>` for pattern 2).
    private func extractCenteredRating(from line: String, after yearClose: String) -> Int? {
        let openers = ["<td><center>", "<td align=\"center\">", "<td align='center'>"]
        guard let centerStart = openers.lazy.compactMap({
            line.range(of: yearClose + $0, options: .caseInsensitive)
        }).first else { return nil }

        guard let centerEnd = line.range(of: "</center>", options: .caseInsensitive,
            range: centerStart.upperBound..<line.endIndex) ?? line.range(of: "</td>",
            options: .caseInsensitive, range: centerStart.upperBound..<line.endIndex) else {
            return nil }

        let ratingString = String(line[centerStart.upperBound..<centerEnd.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return validateRating(ratingString) }

    // Pattern 3: <td>R</td> (second td after year).
    private func extractRatingPattern3(from line: String) -> Int? {
        let tdMatches = matches(for: "<td>([^<]+)</td>", in: line)
        // At least 2 <td> tags (year and rating) are required.
        guard tdMatches.count >= 2 else { return nil }
        // Second match should be the rating.
        let potentialRating = tdMatches[1].trimmingCharacters(in: .whitespaces)
        return validateRating(potentialRating) }

    // Validate that the string is a valid rating (1-10).
    private func validateRating(_ ratingString: String) -> Int? {
        guard let rating = Int(ratingString), rating >= 1 && rating <= 10 else {
            return nil }
        return rating }

    // Helper function to extract regex matches.
    private func matches(for regex: String, in text: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: regex, options: .caseInsensitive)
            let results = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return results.compactMap {
                if let range = Range($0.range(at: 1), in: text) {
                    return String(text[range]) }
                return nil }
        } catch { log("ERROR: Invalid regex pattern: \(regex)"); return [] } }
}
