// MARK: - FilmComparison.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized film comparison utility for import deduplication with enhanced
// title matching using Levenshtein distance and intelligent normalization.
// Extended with database-wide duplicate detection for existing films.

import SwiftUI

// MARK: - Film Comparison
@MainActor
final class FilmComparison: Loggable {
    nonisolated static let logTag = "[Comparison]"

    // MARK: - Duplicate Pair Structure
    struct DuplicatePair: Identifiable, Sendable {
        let id = UUID()
        let film1ID: UUID
        let film2ID: UUID
        let confidence: Double
    }

    // MARK: - Public Interface (Import Mode)
    // Returns the existing library film matching the given title and year, or nil
    // if the incoming item is new. Used by MetaImporter for duplicate detection.
    //
    // Takes a pre-fetched film snapshot array rather than a DataCoordinator so that
    // callers comparing many incoming items against the library (e.g. MetaImporter,
    // looping over every file in an import batch) fetch the library list ONCE and
    // reuse it, instead of paying for a fresh `Array(films.values)` copy out of
    // MemoryStore on every single call. The library's title/year fields are immutable
    // across the lifetime of a single import pass, so reusing one snapshot array for
    // the whole batch is safe and produces identical match results.
    //
    // Years are always compared exactly here: the ±1 year tolerance
    // (Preferences.fuzzyImportYearMatching) is a ratings-pairing affordance and has
    // never applied to metadata-import duplicate detection, which is this function's
    // only caller. RatingsImporter does its own dictionary-backed matching (including
    // an alternateTitle pass) and calls yearsMatch(_:_:allowFuzzy:) below directly.
    static func existingFilm(matchingTitle title: String, year: String,
        in allFilms: [FilmSnapshot]) -> FilmSnapshot? {
        // Validate input - empty title should never match
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("WARNING: Empty title provided for comparison")
            return nil
        }

        if allFilms.isEmpty {
            log("WARNING: Film library appears empty during comparison")
        }

        // First, try exact matching.
        if let exactMatch = allFilms.first(where: { film in
            film.name == title && yearsMatch(film.releaseYear, year, allowFuzzy: false)
        }) {
            logMatch(inputTitle: title, inputYear: year, matchedFilm: exactMatch, isFuzzy: false)
            return exactMatch
        }

        // If fuzzy matching is enabled, try fuzzy matching.
        if Preferences.fuzzyImportMatching,
           let fuzzyMatch = findBestFuzzyMatch(title: title, year: year,
               candidates: allFilms, allowFuzzyYear: false) {
            logMatch(inputTitle: title, inputYear: year, matchedFilm: fuzzyMatch, isFuzzy: true)
            return fuzzyMatch
        }

        // No match found.
        return nil
    }

    // MARK: - Public Interface (Database Scan Mode)
    // Scans the entire database for duplicate films and returns pairs with confidence scores.
    // Uses a two-phase approach: fast title+year coarse filter, then deep metadata validation.
    // This eliminates false positives (e.g. "The Ring" vs "The Lord of the Rings") while
    // keeping expensive per-field comparisons only for genuine candidate pairs.
    static func findAllDuplicates(
        coordinator: DataCoordinator,
        cancelFlag: @escaping @Sendable () async -> Bool,
        progressHandler: @escaping @Sendable (Double, Int, Int) async -> Void
    ) async -> [DuplicatePair] {
        log("Starting database-wide duplicate scan using in-memory store...")
        
        // Get all films from DataCoordinator's memory store
        let allFilms = coordinator.getAllFilms()
        log("Loaded \(allFilms.count) films from memory for duplicate detection")
        
        guard allFilms.count > 1 else {
            log("Insufficient films for duplicate detection (need at least 2)")
            return []
        }
        
        // Extract data for background processing (includes rich metadata for phase 2)
        let filmData = allFilms.compactMap { film -> FilmComparisonData? in
            let trimmedName = film.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                log("WARNING: Skipping film with empty name (ID: \(film.id))")
                return nil
            }
            return FilmComparisonData(
                id: film.id,
                name: film.name,
                releaseYear: film.releaseYear,
                directors: film.directors,
                cast: film.cast,
                genre: film.genre,
                studio: film.studio,
                duration: film.duration,
                rating: film.rating
            )
        }
        
        guard filmData.count > 1 else {
            log("Insufficient valid films for duplicate detection after filtering")
            return []
        }
        
        log("Processing \(filmData.count) valid films for duplicate detection")
        
        // Perform the heavy computation on a background task
        let duplicatePairs = await Task.detached(priority: .userInitiated) {
            await performDuplicateScan(
                filmData: filmData,
                cancelFlag: cancelFlag,
                progressHandler: progressHandler
            )
        }.value
        
        // Get list of ignored pairs from preferences
        let ignoredPairs = await MainActor.run { Preferences.ignoredDuplicatePairs }
        let ignoredPairsSet = Set(ignoredPairs)
        
        // Map back to FilmSnapshots on main actor with validation
        return await MainActor.run {
            duplicatePairs.compactMap { pairData in
                // Verify both films still exist in the coordinator
                guard allFilms.contains(where: { $0.id == pairData.film1ID }),
                      allFilms.contains(where: { $0.id == pairData.film2ID }) else {
                    log("WARNING: Skipping duplicate pair with missing film(s)")
                    return nil
                }
                
                // Filter out ignored pairs
                let pairKey = Preferences.makeDuplicatePairKey(film1ID: pairData.film1ID, film2ID: pairData.film2ID)
                if ignoredPairsSet.contains(pairKey) {
                    log("Filtering out previously ignored pair: \(pairKey)")
                    return nil
                }
                
                return DuplicatePair(film1ID: pairData.film1ID, film2ID: pairData.film2ID, confidence: pairData.confidence)
            }
        }
    }
    
    // MARK: - Background Duplicate Scanning
    
    // Lightweight data structure for background processing.
    // Includes rich metadata fields for the phase 2 deep validation pass.
    private struct FilmComparisonData: Sendable {
        let id: UUID
        let name: String
        let releaseYear: String
        // Phase 2 metadata fields
        let directors: [String]
        let cast: [String]
        let genre: String
        let studio: [String]
        let duration: String
        let rating: String
    }
    
    private struct DuplicatePairData: Sendable {
        let film1ID: UUID
        let film2ID: UUID
        let confidence: Double
    }
    
    // MARK: - Two-Phase Duplicate Scan
    //
    // Phase 1 (coarse): Fast O(n²) title+year comparison with a permissive threshold.
    //   Catches all genuine duplicates while keeping phase 2 candidate sets small.
    //
    // Phase 2 (deep): Multi-field metadata scoring for each phase 1 candidate.
    //   Directors, cast, genre, studio, duration, and content rating are compared.
    //   A pair must pass BOTH phases to be reported as a duplicate.
    //   This eliminates coincidental title overlap (e.g. "The Ring" vs
    //   "The Lord of the Rings: The Two Towers") without expensive per-field work
    //   on every possible pair in the database.
    nonisolated private static func performDuplicateScan(
        filmData: [FilmComparisonData],
        cancelFlag: @escaping @Sendable () async -> Bool,
        progressHandler: @escaping @Sendable (Double, Int, Int) async -> Void
    ) async -> [DuplicatePairData] {
        var duplicatePairs: [DuplicatePairData] = []
        
        guard filmData.count <= 10000 else {
            await MainActor.run {
                log("ERROR: Film count exceeds safe limit for duplicate scanning (\(filmData.count) > 10000)")
            }
            return []
        }
        
        let totalComparisons = (filmData.count * (filmData.count - 1)) / 2
        var currentComparison = 0
        
        let useFuzzyYearMatching = await MainActor.run { Preferences.fuzzyImportYearMatching }
        
        await MainActor.run {
            log("Fuzzy year matching: \(useFuzzyYearMatching ? "enabled" : "disabled")")
            log("Using two-phase duplicate detection (coarse title filter → deep metadata validation)")
        }
        
        // Phase 1 threshold: permissive enough to catch all real duplicates (including
        // alternate titles / minor spelling differences), tight enough to exclude clearly
        // unrelated films. The deep pass will eliminate remaining false positives.
        let coarseThreshold = 0.65
        
        // Final confidence threshold after deep scoring.
        let deepThreshold = 0.70
        
        // Pre-normalize all titles — avoids re-running 22+ regex ops per comparison.
        let normalizedTitles = filmData.map { FilmTitleComparison.normalizeTitle($0.name) }
        
        // Time-based progress throttling at ~30fps.
        var lastUpdateTime = ContinuousClock.now
        let updateInterval: ContinuousClock.Duration = .milliseconds(33)
        
        // Shared progress + cancellation check, time-gated to ~30fps. Returns true
        // if the scan should stop. Consolidates what was previously three identical
        // inline blocks (one per early-exit point in the pairwise loop below).
        func checkProgressAndCancellation() async -> Bool {
            let now = ContinuousClock.now
            guard now - lastUpdateTime >= updateInterval || currentComparison == totalComparisons else {
                return false
            }
            lastUpdateTime = now
            if await cancelFlag() { return true }
            let progress = Double(currentComparison) / Double(totalComparisons)
            await progressHandler(progress, currentComparison, totalComparisons)
            await Task.yield()
            return false
        }
        
        for i in 0..<filmData.count {
            guard i + 1 < filmData.count else { continue }
            
            for j in (i + 1)..<filmData.count {
                currentComparison += 1
                
                let film1 = filmData[i]
                let film2 = filmData[j]
                
                // ── Phase 1: Title + year coarse filter ──────────────────────────────
                let titleSimilarity = FilmTitleComparison.calculateSimilarityPreNormalized(
                    normalizedTitles[i], normalizedTitles[j],
                    original1: film1.name, original2: film2.name)
                
                let yearMatch = yearsMatch(
                    film1.releaseYear, film2.releaseYear, allowFuzzy: useFuzzyYearMatching)
                
                // Require at minimum a year match and a passing coarse title score.
                // Years that don't match at all are a near-certain non-duplicate
                // (sequels with same title get different years in the library).
                guard yearMatch && titleSimilarity >= coarseThreshold else {
                    if await checkProgressAndCancellation() { return duplicatePairs }
                    continue
                }
                
                // ── Sequential numeral guard ─────────────────────────────────────────
                // If both titles contain an ordinal numeral (Arabic, Roman, or spelled-out
                // word) and those numerals are consecutive integers, the films are distinct
                // entries in a series — not duplicates — and can be skipped immediately.
                //
                // Equivalent numerals in different forms (e.g. "Part 2" vs "Part II")
                // are NOT skipped: they map to the same integer, so n1 != n2 is false
                // and the pair correctly proceeds to Phase 2 as a likely duplicate.
                //
                // Examples that are skipped (different sequential integers):
                //   "Back to the Future, Part II"  vs "Back to the Future, Part III"  → 2 vs 3
                //   "The Hunger Games: Mockingjay, Part 1" vs "…Part 2"               → 1 vs 2
                //
                // Examples that proceed (same integer, different notation — likely duplicate):
                //   "Back to the Future, Part 2" vs "Back to the Future, Part II"     → 2 vs 2
                if let n1 = FilmTitleComparison.extractOrdinalNumber(from: film1.name),
                   let n2 = FilmTitleComparison.extractOrdinalNumber(from: film2.name),
                   n1 != n2, abs(n1 - n2) == 1 {
                    if await checkProgressAndCancellation() { return duplicatePairs }
                    continue
                }
                
                // ── Phase 2: Deep metadata validation ────────────────────────────────
                // Score across rich metadata fields to disambiguate title overlap.
                // Each field is weighted by its discriminative power:
                //   Directors  — very high weight: same director = very strong signal
                //   Genre      — minimal weight: genre tags can legitimately differ
                //   Studio     — medium weight: same studio supports match
                //   Cast       — medium weight: shared cast members support match
                //   Rating     — medium weight: same content rating supports match
                //   Duration   — lower weight: runtime varies by cut; approximate match
                //   Title      — retained as part of the blended score
                
                let metadataScore = deepMetadataScore(film1, film2)
                
                // Blend title similarity with metadata score for the final confidence.
                // Title carries more weight because it's the primary identity signal;
                // metadata acts as a disqualifier / confirmer, not the sole arbiter.
                let blendedConfidence = (titleSimilarity * 0.55) + (metadataScore * 0.45)
                
                if blendedConfidence >= deepThreshold {
                    duplicatePairs.append(DuplicatePairData(
                        film1ID: film1.id,
                        film2ID: film2.id,
                        confidence: min(1.0, blendedConfidence)
                    ))
                }
                
                // Progress + cancellation check (time-gated).
                let now = ContinuousClock.now
                if now - lastUpdateTime >= updateInterval || currentComparison == totalComparisons {
                    lastUpdateTime = now
                    if await cancelFlag() {
                        let cc = currentComparison
                        await MainActor.run {
                            log("Scan canceled by user at comparison \(cc) of \(totalComparisons)")
                        }
                        return duplicatePairs
                    }
                    let progress = Double(currentComparison) / Double(totalComparisons)
                    await progressHandler(progress, currentComparison, totalComparisons)
                    await Task.yield()
                }
                // Note: this final check point in the loop retains its own inline
                // logic (rather than calling checkProgressAndCancellation()) so it
                // can log the exact comparison index at cancellation time — useful
                // diagnostic context that the two earlier, more frequent early-exit
                // points don't need.
            }
        }
        
        // Final progress update
        await progressHandler(1.0, totalComparisons, totalComparisons)
        
        let pairCount = duplicatePairs.count
        await MainActor.run {
            log("Scan complete: Found \(pairCount) confirmed duplicate pair(s) after two-phase detection")
        }
        
        return duplicatePairs
    }
    
    // MARK: - Deep Metadata Scoring
    //
    // Returns a 0.0–1.0 score representing how similar two films' metadata fields are.
    // A high score means multiple independent signals agree the films are the same title.
    // A low score means the films are likely different despite title similarity.
    //
    // When a field is empty on BOTH films, it contributes a neutral score so missing
    // metadata doesn't unfairly penalize genuine duplicates in sparse libraries.
    // When a field is populated on both films but they disagree, it contributes 0.
    nonisolated private static func deepMetadataScore(
        _ a: FilmComparisonData, _ b: FilmComparisonData
    ) -> Double {
        var totalWeight: Double = 0
        var weightedScore: Double = 0
        
        // Helper: accumulate a field comparison result
        func accumulate(weight: Double, score: Double) {
            totalWeight += weight
            weightedScore += weight * score
        }
        
        // ── Directors (weight: 2.5) ──────────────────────────────────────────────
        // Overlap coefficient: |A∩B| / |smaller set|. Handles partial cast lists.
        let dirScore = setOverlapScore(a.directors, b.directors)
        if dirScore >= 0 { accumulate(weight: 2.5, score: dirScore) }
        
        // ── Genre (weight: 0.25) ─────────────────────────────────────────────────
        // Genre is intentionally given minimal weight. The same film can carry
        // different genre tags across library entries (e.g. "Thriller" vs
        // "Horror/Thriller"), so a mismatch is often expected rather than
        // diagnostic. It contributes only a faint supporting signal.
        if !a.genre.isEmpty || !b.genre.isEmpty {
            let genreScore: Double
            if a.genre.isEmpty || b.genre.isEmpty {
                // One film lacks genre metadata — neutral
                genreScore = 0.5
            } else {
                genreScore = a.genre.lowercased() == b.genre.lowercased() ? 1.0 : 0.0
            }
            accumulate(weight: 0.25, score: genreScore)
        }
        
        // ── Studio (weight: 1.5) ─────────────────────────────────────────────────
        let studioScore = setOverlapScore(a.studio, b.studio)
        if studioScore >= 0 { accumulate(weight: 1.5, score: studioScore) }
        
        // ── Cast (weight: 1.5) ───────────────────────────────────────────────────
        // Use overlap coefficient on up to the first 10 cast members to avoid
        // very long cast lists dominating the score.
        let castA = Array(a.cast.prefix(10))
        let castB = Array(b.cast.prefix(10))
        let castScore = setOverlapScore(castA, castB)
        if castScore >= 0 { accumulate(weight: 1.5, score: castScore) }
        
        // ── Content Rating (weight: 1.0) ─────────────────────────────────────────
        // A G-rated film and an R-rated film are almost certainly not duplicates.
        if !a.rating.isEmpty || !b.rating.isEmpty {
            let ratingScore: Double
            if a.rating.isEmpty || b.rating.isEmpty {
                ratingScore = 0.5 // Neutral when one is absent
            } else {
                ratingScore = a.rating.lowercased() == b.rating.lowercased() ? 1.0 : 0.0
            }
            accumulate(weight: 1.0, score: ratingScore)
        }
        
        // ── Duration (weight: 0.75) ──────────────────────────────────────────────
        // Runtimes often differ by a few minutes between editions; allow ±5 min tolerance.
        if !a.duration.isEmpty || !b.duration.isEmpty {
            let durationScore: Double
            if a.duration.isEmpty || b.duration.isEmpty {
                durationScore = 0.5
            } else {
                durationScore = durationSimilarity(a.duration, b.duration)
            }
            accumulate(weight: 0.75, score: durationScore)
        }
        
        guard totalWeight > 0 else {
            // No metadata available on either film — give a moderate score so that
            // the title similarity (phase 1 coarse filter) effectively decides.
            return 0.5
        }
        
        return weightedScore / totalWeight
    }
    
    // Returns the overlap coefficient (|A∩B| / |smaller set|) for two string arrays,
    // normalizing to lowercase for a case-insensitive comparison.
    // Returns -1 if both arrays are empty (caller should skip the field entirely
    // to avoid dividing by zero or contributing noise from absent data).
    nonisolated private static func setOverlapScore(_ a: [String], _ b: [String]) -> Double {
        let setA = Set(a.map { $0.lowercased() }.filter { !$0.isEmpty })
        let setB = Set(b.map { $0.lowercased() }.filter { !$0.isEmpty })
        
        if setA.isEmpty && setB.isEmpty { return -1 } // Both absent — skip
        if setA.isEmpty || setB.isEmpty { return 0.4 } // One absent — slight penalty
        
        let intersection = setA.intersection(setB).count
        let smaller = min(setA.count, setB.count)
        return Double(intersection) / Double(smaller)
    }
    
    // Compares duration strings (e.g. "1:52:30", "112", "112 min") and returns a
    // similarity score with a ±5 minute tolerance window. Returns 1.0 for a close
    // match, 0.5 for a moderate difference, 0.0 for a large difference.
    nonisolated private static func durationSimilarity(_ d1: String, _ d2: String) -> Double {
        func toMinutes(_ s: String) -> Int? {
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " min", with: "")
                .replacingOccurrences(of: " mins", with: "")
            // Handle H:MM:SS or HH:MM
            let parts = cleaned.components(separatedBy: ":")
            if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) {
                return h * 60 + m
            } else if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                return h * 60 + m
            } else if let mins = Int(cleaned) {
                return mins
            }
            return nil
        }
        
        guard let m1 = toMinutes(d1), let m2 = toMinutes(d2), m1 > 0, m2 > 0 else {
            return 0.5 // Unparseable — neutral
        }
        
        let diff = abs(m1 - m2)
        if diff <= 5  { return 1.0 }
        if diff <= 15 { return 0.5 }
        return 0.0
    }

    // MARK: - Fuzzy Matching (Import Mode)
    // Finds the best fuzzy match for a title among candidate films.
    private static func findBestFuzzyMatch(title: String, year: String, candidates: [FilmSnapshot],
        allowFuzzyYear: Bool) -> FilmSnapshot? {

        // Safety check for empty title
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        
        var bestMatch: FilmSnapshot?
        var bestScore = 0.0
        let threshold = 0.80

        for candidate in candidates {
            // Skip candidates with empty names
            guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            
            // Check if years match (with fuzzy tolerance if enabled).
            guard yearsMatch(candidate.releaseYear, year, allowFuzzy: allowFuzzyYear) else {
                continue
            }

            // Calculate similarity score.
            let score = FilmTitleComparison.calculateSimilarity(title, candidate.name)

            if score >= threshold && score > bestScore {
                bestScore = score
                bestMatch = candidate
            }
        }

        return bestMatch
    }

    // MARK: - Year Matching
    // Checks if two year strings match, with optional fuzzy tolerance.
    // Marked nonisolated (rather than actor-isolated) since it touches no actor
    // state, which lets both the MainActor-isolated import-mode callers below
    // and the nonisolated background duplicate scan share this single
    // implementation instead of maintaining two copies that could drift apart.
    nonisolated static func yearsMatch(_ year1: String, _ year2: String, allowFuzzy: Bool) -> Bool {
        // Handle empty years - consider them as matching if both empty
        if year1.isEmpty && year2.isEmpty { return true }
        if year1.isEmpty || year2.isEmpty { return false }

        // Exact match
        if year1 == year2 { return true }

        // If fuzzy matching is allowed, check +/- 1 year.
        if allowFuzzy {
            if let y1 = Int(year1), let y2 = Int(year2) {
                return abs(y1 - y2) <= 1
            }
        }
        return false
    }

    // MARK: - Match Logging
    private static func logMatch(inputTitle: String, inputYear: String,
        matchedFilm: FilmSnapshot, isFuzzy: Bool) {
        // Duplicate detection during metadata import — the only caller.
        log("DUPLICATE DETECTED - \(isFuzzy ? "FUZZY MATCH" : "EXACT MATCH")")
        log("Source: metadata import")
        log("Input: '\(inputTitle)' (\(inputYear))")
        log("Matched: '\(matchedFilm.name)' (\(matchedFilm.releaseYear))")
        log("DISCARDED - Data will not be written to database")
        log("---")
    }
}

// MARK: - Enhanced Fuzzy Title Matching with Levenshtein Distance
enum FilmTitleComparison {
    // MARK: - Main Similarity Calculation
    // Returns a score from 0.0 (no match) to 1.0 (perfect match).
    static func calculateSimilarity(_ title1: String, _ title2: String) -> Double {
        // Early return for empty strings
        let trimmed1 = title1.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed2 = title2.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed1.isEmpty && trimmed2.isEmpty { return 1.0 }
        if trimmed1.isEmpty || trimmed2.isEmpty { return 0.0 }
        
        let normalized1 = normalizeTitle(title1)
        let normalized2 = normalizeTitle(title2)

        return calculateSimilarityCore(normalized1, normalized2, original1: title1, original2: title2)
    }
    
    // Pre-normalized variant for batch scanning.
    // When comparing N films pairwise, each title would otherwise be re-normalized
    // ~N times. This entry point accepts already-normalized titles and skips that work.
    static func calculateSimilarityPreNormalized(
        _ normalized1: String, _ normalized2: String,
        original1: String, original2: String
    ) -> Double {
        // Early return for empty strings
        if normalized1.isEmpty && normalized2.isEmpty { return 1.0 }
        if normalized1.isEmpty || normalized2.isEmpty { return 0.0 }
        
        return calculateSimilarityCore(normalized1, normalized2, original1: original1, original2: original2)
    }
    
    // Shared implementation for both entry points.
    private static func calculateSimilarityCore(
        _ normalized1: String, _ normalized2: String,
        original1: String, original2: String
    ) -> Double {
        // Exact match after normalization.
        if normalized1 == normalized2 { return 1.0 }

        let words1 = normalized1.components(separatedBy: " ").filter { !$0.isEmpty }
        let words2 = normalized2.components(separatedBy: " ").filter { !$0.isEmpty }

        // Strategy 1: Substring containment — only score high when the shorter title
        // is a substantial portion of the longer one. This prevents "The Ring" from
        // matching "The Lord of the Rings: The Two Towers" via naive containment.
        // Require: shorter is at least 75% the character count of the longer, AND
        // both titles are multi-word (prevents single-word false positives).
        if words1.count >= 2 && words2.count >= 2 {
            let len1 = normalized1.count
            let len2 = normalized2.count
            let shorter = min(len1, len2)
            let longer  = max(len1, len2)
            let lengthRatio = Double(shorter) / Double(longer)
            
            if lengthRatio >= 0.75 &&
               (normalized1.contains(normalized2) || normalized2.contains(normalized1)) {
                return 0.95
            }
        }

        // Strategy 2: Levenshtein distance-based similarity.
        let maxLength = max(normalized1.count, normalized2.count)
        guard maxLength > 0 else { return 0.0 }

        let distance = levenshteinDistance(normalized1, normalized2)
        let levenshteinScore = 1.0 - (Double(distance) / Double(maxLength))

        // Strategy 3: Word overlap (Jaccard index).
        let commonWords = Set(words1).intersection(Set(words2))
        let totalUniqueWords = Set(words1).union(Set(words2))
        let wordOverlapScore = totalUniqueWords.isEmpty ? 0.0 :
            Double(commonWords.count) / Double(totalUniqueWords.count)

        // Strategy 4: Known title variations.
        let variationScore = checkCommonVariations(original1, original2)

        // Combine scores with weights.
        // Levenshtein gets highest weight, word overlap second, variations as bonus.
        let combinedScore = (levenshteinScore * 0.6) + (
            wordOverlapScore * 0.3) + (variationScore * 0.1)

        return combinedScore
    }

    // MARK: - Levenshtein Distance Algorithm
    // Two-row rolling buffer: O(min(n,m)) memory, identical results to full matrix.
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        var s1Count = s1Array.count
        var s2Count = s2Array.count
        
        // Handle empty string edge cases
        if s1Count == 0 { return s2Count }
        if s2Count == 0 { return s1Count }
        
        // Ensure s2 is the shorter string to minimize row width
        let (rowSource, colSource): ([Character], [Character])
        if s1Count < s2Count {
            rowSource = s2Array; colSource = s1Array
            swap(&s1Count, &s2Count)
        } else {
            rowSource = s1Array; colSource = s2Array
        }

        // Two-row buffer: previousRow and currentRow
        var previousRow = Array(0...s2Count)
        var currentRow = Array(repeating: 0, count: s2Count + 1)
        
        for i in 1...s1Count {
            currentRow[0] = i
            for j in 1...s2Count {
                let cost = rowSource[i - 1] == colSource[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,       // Deletion
                    currentRow[j - 1] + 1,    // Insertion
                    previousRow[j - 1] + cost // Substitution
                )
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[s2Count]
    }

    // MARK: - Common Variation Checking
    // Checks for known title variations that should match.
    private static func checkCommonVariations(_ title1: String, _ title2: String) -> Double {
        // Safety check for empty titles
        guard !title1.isEmpty, !title2.isEmpty else { return 0.0 }
        
        let variations: [(String, String)] = [
            ("vs", "v"),                   // "Ford vs Ferrari" / "Ford v Ferrari"
            ("and", "&"),                  // "Me and You" / "Me & You"
            ("part", "pt"),                // "Part 2" / "Pt 2"
            ("at worlds", "at world's"),   // Handle apostrophe variations
            ("dantes", "dante's"),
            ("dont", "don't")
        ]

        let lower1 = title1.lowercased()
        let lower2 = title2.lowercased()

        for (variant1, variant2) in variations {
            // Check if one title has variant1 and other has variant2 in the same position.
            if (lower1.contains(variant1) && lower2.contains(variant2)) ||
                (lower1.contains(variant2) && lower2.contains(variant1)) {
                // Full bonus for known variations
                return 1.0
            }
        }
        return 0.0
    }

    // MARK: - Title Normalization
    // Normalizes titles for comparison, removing all punctuation to maximize matching.
    // Internal access allows pre-normalization in batch scanning (FilmComparison.performDuplicateScan).
    static func normalizeTitle(_ title: String) -> String {
        // Safety check
        guard !title.isEmpty else { return "" }
        
        var normalized = title.lowercased()

        // Replace numeric words with digits.
        let numericReplacements = [
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
            "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
            "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
            "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
            "eighteen": "18", "nineteen": "19", "twenty": "20"
        ]
        for (word, digit) in numericReplacements {
            normalized = normalized.replacingOccurrences(of: "\\b\(word)\\b",
                with: digit, options: .regularExpression)
        }

        // Normalize common abbreviations.
        normalized = normalized.replacingOccurrences(
            of: "\\bvs\\b", with: "v", options: .regularExpression)
        normalized = normalized.replacingOccurrences(
            of: "\\band\\b", with: "&", options: .regularExpression)

        // Remove all punctuation including apostrophes, periods, dashes, colons, etc.
        // This maximizes matching for ratings import where URL paths may strip punctuation.
        // Trade-off: "world's" and "worlds" will now match, but this is acceptable
        // since we prioritize catching legitimate matches over maintaining fine distinctions.
        // Uses character filtering instead of components/joined to avoid introducing
        // extra spaces where punctuation existed (e.g., "don't" and "dont" must both → "dont")
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
        normalized = String(normalized.unicodeScalars.filter {
            allowedCharacters.contains($0)
        })

        // Collapse multiple spaces and trim.
        let words = normalized.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        return words.joined(separator: " ")
    }

    // MARK: - Ordinal Number Extraction
    // Scans a film title for an ordinal numeral and returns its integer value, or nil
    // if none is found. Handles three forms: Arabic digits (1, 2…), Roman numerals
    // (I, II, III, IV…), and English ordinal words (one, two, three…).
    //
    // Only the LAST numeral token in the title is returned, since franchise entries
    // like "Part II" or "Chapter 3" place their ordinal at the end.
    //
    // Used by the sequential numeral guard in performDuplicateScan to skip pairs
    // that are clearly consecutive series entries rather than accidental duplicates.
    static func extractOrdinalNumber(from title: String) -> Int? {
        // Map of Roman numeral strings → integer values.
        // Ordered longest-first so multi-character tokens (e.g. "VIII") are
        // matched before their shorter substrings ("V", "I"). Each value appears
        // exactly once. Covers I–XX (1–20), sufficient for any realistic franchise.
        let romanMap: [(String, Int)] = [
            ("XVIII", 18), ("XVII",  17), ("XIX", 19), ("XVI", 16),
            ("XIII",  13), ("VIII",   8), ("XIV", 14), ("XII", 12),
            ("VII",    7), ("XI",    11), ("XX",  20), ("VI",   6),
            ("IX",     9), ("IV",     4), ("III",  3), ("XV",  15),
            ("II",     2), ("X",     10), ("V",    5), ("I",    1)
        ]
        
        // Map of English ordinal/cardinal words → integer values.
        let wordMap: [String: Int] = [
            "one": 1, "first": 1,
            "two": 2, "second": 2,
            "three": 3, "third": 3,
            "four": 4, "fourth": 4,
            "five": 5, "fifth": 5,
            "six": 6, "sixth": 6,
            "seven": 7, "seventh": 7,
            "eight": 8, "eighth": 8,
            "nine": 9, "ninth": 9,
            "ten": 10, "tenth": 10
        ]
        
        // Tokenize on whitespace and common separators.
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",:;-–—."))
        let tokens = title.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()[]")) }
            .filter { !$0.isEmpty }
        
        var lastFound: Int? = nil
        
        for token in tokens {
            // 1. Arabic digit (e.g. "2", "10")
            if let n = Int(token), n > 0, n <= 50 {
                lastFound = n
                continue
            }
            
            // 2. Roman numeral — exact whole-token match (uppercased) to avoid
            //    matching "I" inside "In" or "II" as part of another word.
            let upper = token.uppercased()
            var matchedRoman = false
            for (roman, value) in romanMap where upper == roman {
                lastFound = value
                matchedRoman = true
                break
            }
            if matchedRoman { continue }
            
            // 3. English ordinal/cardinal word (case-insensitive)
            let lower = token.lowercased()
            if let n = wordMap[lower] {
                lastFound = n
            }
        }
        
        return lastFound
    }

    // MARK: - Similarity Threshold
    // The ratings importer's fuzzy-title rule: similar at a score of 0.80 or above.
    static func titlesAreSimilar(_ title1: String, _ title2: String) -> Bool {
        return calculateSimilarity(title1, title2) >= 0.80
    }
}
