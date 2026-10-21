// MARK: - SearchController.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Uses SwiftUI's native searchable() with token support.
// The # character triggers token entry mode which pauses filtering until Return.

import Foundation
import SwiftUI
import Observation

// MARK: - Search Controller
@MainActor
@Observable
final class SearchController: Loggable {
    nonisolated static let logTag = "[SearchCon]"
    
    static let shared = SearchController()
    init() {}
    
    // MARK: - Published State (Bound to .searchable())
    
    /// The text currently in the search field (bound to .searchable())
    var searchText: String = "" {
        didSet {
            guard !isClearing else { return }
            updateTokenEntryState()
            // Trigger search with minimal delay for text changes
            if !isEnteringToken {
                triggerSearchWithDebounce()
            }
        }
    }
    
    /// The tokens the user has selected/confirmed (bound to .searchable())
    var currentTokens: [SearchToken] = [] {
        didSet {
            guard !isClearing else { return }
            // Immediately trigger search when tokens change
            triggerSearchImmediate()
        }
    }
    
    /// Whether user is currently entering a token (# typed but not confirmed with Return)
    /// When true, filtering is PAUSED - no results change until Return is pressed.
    private(set) var isEnteringToken: Bool = false
    
    /// Whether search is currently active and should filter results.
    /// False when entering a token (filtering paused).
    private(set) var isActive: Bool = false
    
    /// Whether search has any content at all (for view switching purposes).
    /// True even during token entry - we want to show search view.
    private(set) var hasContent: Bool = false
    
    
    /// Last confirmed search state (used during token entry to maintain previous results)
    private var lastConfirmedTokens: [SearchToken] = []
    private var lastConfirmedText: String = ""
    
    // MARK: - Private State

    /// Set to true during clearSearch() to suppress didSet observers on searchText
    /// and currentTokens from triggering redundant search executions while the clear
    /// is in progress. Both properties are reset atomically; the flag is cleared last.
    private var isClearing: Bool = false

    // Debounce handle for text-change searches. Replaces the previous Timer-based
    // approach: canceling and re-creating a Task is cleaner than Timer.invalidate()
    // because it keeps everything within structured concurrency (no run-loop dependency),
    // and TaskHandle's deinit guarantees cancellation if SearchController is deallocated.
    private var searchDebounceHandle: TaskHandle?
    
    /// When set, getCleanSearchText() returns this value instead of stripping the live
    /// searchText. Used during processSearchSubmission() so that the triggerSearch()
    /// fired by addToken() → currentTokens.didSet uses the post-commit clean text
    /// (beforeHash) rather than the still-present in-progress token string. This
    /// prevents the residual value portion of the token text (e.g. "producer d" from
    /// "#/executive producer d") from being passed into applyFilters as spurious
    /// freeform text, which would briefly zero out films and flash the placeholder.
    private var pendingCleanText: String? = nil
    
    // MARK: - Token Entry State
    
    /// Update token entry state based on search text.
    /// When # is present and not yet confirmed, we're in token entry mode.
    private func updateTokenEntryState() {
        let wasEnteringToken = isEnteringToken
        
        // Check if we have an unconfirmed # pattern
        isEnteringToken = searchText.contains("#")
        
        // Update hasContent (for view switching - any input counts)
        hasContent = !searchText.isEmpty || !currentTokens.isEmpty
        
        // When starting token entry, save current state
        if isEnteringToken && !wasEnteringToken {
            lastConfirmedTokens = currentTokens
            // Trim after stripping the # fragment. Typing "#" after freeform text always
            // leaves the separating space behind (e.g. "matrix #" → "matrix "), and that
            // trailing space was carried straight into applyFilters' substring comparison
            // during token entry — so "matrix " matched nothing and the paused results
            // collapsed to zero films instead of holding the pre-token result set.
            // getCleanSearchText() already trims for the active path; this matches it.
            lastConfirmedText = searchText
                .replacingOccurrences(of: "#.*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            Self.log("Entering token mode - filtering paused")
        }
    }
    
    // MARK: - In-Progress "#" Fragment
    
    /// The parsed shape of the in-progress "#…" fragment at the tail of `searchText`.
    ///
    /// Four members used to re-derive these same pieces independently — the hash index,
    /// the "/" (OR) and "!" (inversion) prefixes, and the partial field name — each with
    /// its own copy of the prefix-stripping order. Parsing once here keeps them from
    /// drifting and makes the fragment's grammar readable in a single place.
    private struct HashFragment {
        /// Everything before the "#".
        let beforeHash: String
        /// A "/" prefix was typed after the "#" (OR mode).
        let isOr: Bool
        /// A "!" prefix was typed after the optional "/" (inverted mode).
        let isInverted: Bool
        /// The field-name text typed after the prefixes, whitespace-trimmed.
        let partial: String
        /// A space follows the "#" fragment — the user has moved on to entering a value.
        let hasValue: Bool
    }
    
    /// Parses the fragment following the last "#" in `searchText`, or nil if there is none.
    private var hashFragment: HashFragment? {
        guard let hashIndex = searchText.lastIndex(of: "#") else { return nil }
        let beforeHash = String(searchText[..<hashIndex])
        let afterHash = String(searchText[searchText.index(after: hashIndex)...])
        
        var partial = afterHash.trimmingCharacters(in: .whitespaces)
        let isOr = partial.hasPrefix("/")
        if isOr { partial = String(partial.dropFirst()) }
        let isInverted = partial.hasPrefix("!")
        if isInverted { partial = String(partial.dropFirst()) }
        
        return HashFragment(
            beforeHash: beforeHash,
            isOr: isOr,
            isInverted: isInverted,
            partial: partial,
            hasValue: afterHash.contains(" ")
        )
    }
    
    // MARK: - Suggested Fields for Current Input
    
    /// Get fields that match current partial input after #.
    /// Returns nothing once a value is being entered — field suggestions no longer apply.
    func getSuggestedFields() -> [SearchField] {
        guard let fragment = hashFragment, !fragment.hasValue else { return [] }
        let partial = fragment.partial
        
        // Filter fields based on partial match
        if partial.isEmpty {
            return SearchField.allCases
        }
        
        // Lowercase the partial once instead of re-deriving it for every field — and for
        // every alias inside the inner closure — on each keystroke. Aliases are already
        // stored lowercased, so only the partial and the per-field displayName need folding.
        let lowerPartial = partial.lowercased()
        return SearchField.allCases.filter { field in
            field.displayName.lowercased().hasPrefix(lowerPartial) ||
            field.aliases.contains { $0.hasPrefix(lowerPartial) }
        }
    }
    
    /// Check if inverted mode is active (! after #)
    var isInvertedMode: Bool { hashFragment?.isInverted ?? false }
    
    /// Check if OR mode is active (/ after #)
    var isOrMode: Bool { hashFragment?.isOr ?? false }
    
    /// Insert a field into the search text, replacing partial input
    func insertField(_ field: SearchField) {
        guard let fragment = hashFragment else { return }
        
        var prefix = ""
        if fragment.isOr { prefix += "/" }
        if fragment.isInverted { prefix += "!" }
        
        // Replace with field name and add space for value entry
        searchText = fragment.beforeHash + "#" + prefix + (field.aliases.first ?? field.rawValue) + " "
        
        Self.log("Inserted field: \(field.displayName) with prefix: \(prefix)")
    }
    
    /// Add a token with a value. Only reached via processSearchSubmission().
    private func addToken(field: SearchField, value: String, isInverted: Bool = false, isOr: Bool = false) {
        let token = SearchToken(field: field, value: value, isInverted: isInverted, isOr: isOr)
        
        if !currentTokens.contains(token) {
            currentTokens.append(token)
            Self.log("Added token: \(token.displayName)")
        }
    }
    
    /// Process search text on submission to extract tokens.
    /// Called when user presses Return in the search field.
    func processSearchSubmission() {
        let text = searchText
        
        // If no # present, just trigger search if we have content
        guard let hashIndex = text.lastIndex(of: "#") else {
            if hasContent {
                triggerSearchImmediate()
            }
            return
        }
        
        let afterHash = String(text[text.index(after: hashIndex)...])
        
        // Need "field value" pattern (must have space with value after it)
        guard afterHash.contains(" ") else {
            // Incomplete token - don't process
            return
        }
        
        var parts = afterHash.components(separatedBy: " ")
        guard parts.count >= 2 else { return }

        // Check for OR mode (/) and inversion (!) — both prefix the field name.
        var firstWord = parts[0]
        let isOr = firstWord.hasPrefix("/")
        if isOr {
            firstWord = String(firstWord.dropFirst())
        }
        let isInverted = firstWord.hasPrefix("!")
        if isInverted {
            firstWord = String(firstWord.dropFirst())
        }
        parts[0] = firstWord

        // Resolve the field name, allowing it to span more than one word.
        //
        // Every alias is a single unspaced token ("executiveproducer", "lastwatched"), but
        // the field names the user actually sees — and that the suggestion list inserts —
        // include multi-word display names such as "Executive Producer" and "Last Watched".
        // Matching only parts[0] meant that typing a space-separated field name resolved to
        // no field at all: Return did nothing, no token was created, and the half-typed
        // string stayed in the field with filtering paused.
        //
        // Word counts are tried shortest-first, so any input that resolves today resolves
        // identically (the single-word match is found on the first iteration) and only
        // previously-unresolvable input gains a match. At least one word is always reserved
        // for the value, and the value must be non-empty, so a bare field name still
        // correctly produces no token.
        var matchedField: SearchField?
        var matchedValue = ""
        for wordCount in 1..<parts.count {
            let candidateName = parts[0..<wordCount].joined()
            guard let field = SearchField.from(alias: candidateName) else { continue }
            let candidateValue = parts[wordCount...]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !candidateValue.isEmpty else { break }
            matchedField = field
            matchedValue = candidateValue
            break
        }

        guard let field = matchedField else { return }
        let value = matchedValue
        
        // Compute the clean text that will remain after the # pattern is stripped.
        // Set pendingCleanText before addToken() so that getCleanSearchText() —
        // called inside triggerSearch() → getCurrentQuery() → applyFilters() —
        // uses the post-commit value rather than the live searchText which still
        // holds the full in-progress token string (e.g. "#/executive producer d").
        // Without this, the residual value portion after the field name space
        // ("producer d") leaks into the freeform filter pass, briefly zeroing
        // films and flashing the placeholder before the correct results arrive.
        let beforeHash = String(text[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        pendingCleanText = beforeHash
        
        // Exit token entry mode before adding token
        // This ensures when currentTokens.didSet triggers and calls triggerSearch(),
        // the isActive check will pass because isEnteringToken is already false
        isEnteringToken = false
        
        // Now add token - when didSet fires, isActive will become true.
        // getCleanSearchText() returns pendingCleanText (beforeHash) for this call.
        addToken(field: field, value: value, isInverted: isInverted, isOr: isOr)
        
        // Commit complete — clear the override before assigning searchText so that
        // the searchText.didSet path uses normal text stripping going forward.
        pendingCleanText = nil
        
        // Clear the # pattern from search text
        searchText = beforeHash
        
        Self.log("Confirmed token: \(field.displayName): \(value) (inverted=\(isInverted), or=\(isOr))")
    }
    
    // MARK: - Search Execution
    
    private func triggerSearchWithDebounce() {
        // Cancel any in-flight debounce task and start a fresh one.
        // TaskHandle's deinit cancels the underlying Task when the handle is replaced,
        // providing the same invalidation guarantee as Timer.invalidate() without
        // requiring a run-loop or crossing concurrency domains.
        searchDebounceHandle = TaskHandle(Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return // Canceled — a newer keystroke superseded this one.
            }
            triggerSearch()
        })
    }
    
    /// Trigger search immediately without debounce (used for token changes)
    private func triggerSearchImmediate() {
        searchDebounceHandle = nil // Cancel any pending debounced search.
        triggerSearch()
    }
    
    private func triggerSearch() {
        // Recompute hasContent here as the authoritative source of truth.
        // updateTokenEntryState() is only called from searchText.didSet, so when
        // currentTokens changes without searchText changing — e.g. the user removes
        // a token pill via the SwiftUI .searchable() UI — hasContent would otherwise
        // retain its previous value. Recomputing at the entry point of triggerSearch()
        // (which is the common tail of both the text-change debounce path and the
        // immediate token-change path) guarantees hasContent always reflects the true
        // current state before isActive and the outgoing query are derived from it.
        hasContent = !searchText.isEmpty || !currentTokens.isEmpty

        // Update active state:
        // - Must have content (text or tokens)
        // - Must NOT be entering a token (filtering paused during token entry)
        isActive = hasContent && !isEnteringToken
        
        Self.log("triggerSearch: hasContent=\(hasContent), isEnteringToken=\(isEnteringToken), isActive=\(isActive)")
        
        let query = getCurrentQuery()
        
        // Update ViewStateManager synchronously (both are @MainActor singletons).
        // This eliminates the one-run-loop async gap that the event bus's
        // .receive(on: RunLoop.main) subscriber introduced, which was the root
        // cause of the spinner appearing during OR-token searches: loadFilms()
        // was deferred one cycle, leaving a window where films=[] and
        // searchQuery="" simultaneously satisfied the shouldShowLoading condition.
        // The AppEventBus path for searchQueryChanged has been removed: the direct
        // synchronous call here is the canonical and only update path.
        ViewStateManager.shared.updateSearchQuery(query)
    }
    
    // MARK: - Clear/Reset
    
    /// Returns every piece of search state to its empty baseline.
    ///
    /// `searchText` and `currentTokens` are reset under `isClearing`, which suppresses
    /// their didSet observers so neither the text debounce path nor the token
    /// immediate-search path fires mid-reset; the derived flags are then set explicitly.
    /// `isActive`/`hasContent` are left false here — `programmaticTokenSearch` raises them
    /// itself before assigning its token, which is the only case where they end up true.
    private func resetState() {
        isClearing = true
        searchText = ""
        currentTokens = []
        isClearing = false
        
        searchDebounceHandle = nil // Cancel any pending debounced search.
        isActive = false
        hasContent = false
        isEnteringToken = false
        lastConfirmedTokens = []
        lastConfirmedText = ""
        pendingCleanText = nil
    }
    
    func clearSearch() {
        resetState()
        Self.log("Search cleared")
    }
    
    // MARK: - Programmatic Token Search
    
    /// Immediately activates a token-based search for the specified field and value,
    /// bypassing the interactive # entry flow. Designed for use by sidebar "Search"
    /// buttons that should produce instant results with no visible intermediate state.
    ///
    /// All state is set up atomically before triggering the search so ViewStateManager
    /// receives a complete, consistent query string on its first call — preventing any
    /// flash of empty results or a spinner.
    ///
    /// Callers must only invoke this on the @MainActor (enforced by class isolation).
    func programmaticTokenSearch(field: SearchField, value: String) {
        // Clear every piece of prior search state before installing the new token.
        resetState()

        // Set content/active flags to their final values BEFORE assigning currentTokens.
        // This ensures that when currentTokens.didSet fires triggerSearchImmediate(),
        // both hasContent and isActive are already true — so triggerSearch() writes the
        // correct query string to ViewStateManager on the very first call.
        hasContent = true
        isActive = true

        // Assign the token directly. The didSet on currentTokens (isClearing is false
        // here) calls triggerSearchImmediate() → triggerSearch(), which reads the final
        // flag state set above and dispatches the query to ViewStateManager immediately.
        let token = SearchToken(field: field, value: value, isInverted: false, isOr: false)
        currentTokens = [token]

        Self.log("Programmatic token search: \(field.displayName) = \"\(value)\"")
    }
    
    // MARK: - Query Generation
    
    /// Get current query string for ViewStateManager.
    /// Uses clean search text (# patterns stripped) so that the in-progress token
    /// entry string never contaminates activeState.searchQuery — which would cause
    /// a spurious searchQuery="" window on the next GalleryView initialization cycle,
    /// satisfying the shouldShowLoading spinner condition incorrectly.
    func getCurrentQuery() -> String {
        var parts: [String] = []
        
        let cleanText = getCleanSearchText()
        if !cleanText.isEmpty {
            parts.append(cleanText)
        }
        
        for token in currentTokens {
            var prefix = ""
            if token.isOr { prefix += "/" }
            if token.isInverted { prefix += "!" }
            parts.append("\(prefix)\(token.field.rawValue):\(token.value)")
        }
        
        return parts.joined(separator: " ")
    }
    
    /// Get clean search text (excluding # patterns).
    /// Returns pendingCleanText during token commit if set, allowing processSearchSubmission()
    /// to override the live searchText for the duration of the addToken() call.
    private func getCleanSearchText() -> String {
        if let pending = pendingCleanText { return pending }
        // Fast path: once a token is committed the # is stripped from searchText, so the
        // common case has no # at all. Skipping the regex engine entirely here is
        // behavior-identical — the pattern would match nothing and only the trim would
        // apply — while avoiding per-call NSRegularExpression setup on the hot path.
        if !searchText.contains("#") {
            return searchText.trimmingCharacters(in: .whitespaces)
        }
        // Remove any # patterns from the search text.
        // The pattern is compiled once as a static constant rather than on every call.
        let cleaned = searchText.replacingOccurrences(
            of: Self.hashPatternRegex,
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
    
    /// Regex pattern that strips any "#<field><optional-value>" token fragment from
    /// freeform search text. Compiled once; reused on every getCleanSearchText() call.
    private static let hashPatternRegex = "#[^\\s]*\\s*"
    
    // MARK: - Film Filtering
    
    // MARK: - Token Filtering
    
    /// Returns true if `film`'s title, or any of its alternate titles, contains the query,
    /// already in `SearchText.key` form.
    ///
    /// Prefers MetadataCache's precomputed keys (no per-keystroke normalization) and falls
    /// back to normalizing the snapshot fields on the fly when the film is not yet cached.
    /// This is the single source of truth for title matching, shared by the `.title` token
    /// case and the freeform text pass.
    private func matchesTitle(_ film: FilmSnapshot, query queryKey: String) -> Bool {
        guard let cached = MetadataCache.shared.getSearchKeys(for: film.id) else {
            // Fallback if not in cache (shouldn't happen, but handle gracefully).
            return fuzzyMatchOptimized(film.name, query: queryKey) ||
                   film.alternateTitle.contains { fuzzyMatchOptimized($0, query: queryKey) }
        }
        if fuzzyMatchCore(cached.name, query: queryKey) { return true }
        return fuzzyMatchCore(cached.alternateTitles, query: queryKey)
    }

    /// The snapshot string-array properties each plain text-match token scans.
    ///
    /// The switch is deliberately exhaustive rather than defaulted: every field that has
    /// its own branch in `applyTokenFilter` (title, genre, notes and the specialized
    /// numeric/date/list/release filters) is listed here returning no key paths, so adding
    /// a SearchField is a compile error in both places instead of silently matching nothing.
    private static func textArrayKeyPaths(for field: SearchField) -> [KeyPath<FilmSnapshot, [String]>] {
        switch field {
        case .crew:
            return [\.cast, \.directors, \.producers, \.executiveProducers, \.screenwriters, \.composer]
        case .cast:              return [\.cast]
        case .directors:         return [\.directors]
        case .producer:          return [\.producers]
        case .executiveProducer: return [\.executiveProducers]
        case .screenwriter:      return [\.screenwriters]
        case .composer:          return [\.composer]
        case .studio:            return [\.studio]
        case .tags:              return [\.tags]
        // Handled by their own branches in applyTokenFilter — never routed here.
        case .title, .genre, .notes, .synopsis, .year, .duration, .rating, .lastWatched,
             .dateAdded, .list, .releases, .rotationThreshold:
            return []
        }
    }

    /// Apply a single token filter to a set of film snapshots.
    /// 'listNames' maps a film's UUID to the names of any lists it belongs to,
    /// enabling list-field filtering without accessing SwiftData objects.
    private func applyTokenFilter(
        token: SearchToken,
        to films: [FilmSnapshot],
        listNames: (UUID) -> [String]
    ) -> [FilmSnapshot] {
        let results: [FilmSnapshot]
        
        // Normalize the query once for all field types that need it, rather than inside
        // the per-film filter closures.
        let lowercasedQuery = SearchText.key(token.value)
        
        switch token.field {
        case .title:
            results = films.filter { matchesTitle($0, query: lowercasedQuery) }
            
        // Every field backed purely by string-array snapshot properties — the six
        // credited-person fields, the broad-match .crew union over all six, plus studio
        // and tags — resolves through one table-driven pass. Each of these used to be
        // its own near-identical `films.filter { film.<field>.contains { fuzzyMatch… } }`
        // case; the only thing that ever varied between them was which arrays to scan.
        // Scan order within .crew is preserved, and `contains` still short-circuits on
        // the first array that matches.
        case .crew, .cast, .directors, .producer, .executiveProducer,
             .screenwriter, .composer, .studio, .tags:
            let keyPaths = Self.textArrayKeyPaths(for: token.field)
            results = films.filter { film in
                keyPaths.contains { keyPath in
                    film[keyPath: keyPath].contains { fuzzyMatchOptimized($0, query: lowercasedQuery) }
                }
            }
            
        case .genre:
            results = films.filter { fuzzyMatchOptimized($0.genre, query: lowercasedQuery) }
            
        case .notes:
            results = films.filter { film in
                fuzzyMatchOptimized(film.notes, query: lowercasedQuery) ||
                fuzzyMatchOptimized(film.descriptionNotes, query: lowercasedQuery)
            }
            
        case .synopsis:
            results = filterBySynopsis(films, query: token.value)
            
        case .year:
            results = filterByYear(films, query: token.value)
            
        case .duration:
            results = filterByDuration(films, query: token.value)
            
        case .rating:
            results = filterByRating(films, query: token.value)
            
        case .lastWatched:
            results = filterByDateField(films, query: token.value, fieldValue: { $0.lastWatched })
            
        case .dateAdded:
            results = filterByDateField(films, query: token.value, fieldValue: { $0.dateAdded })
            
        case .list:
            results = filterByList(films, query: token.value, listNames: listNames)
            
        case .releases:
            results = filterByReleases(films, query: token.value)
            
        case .rotationThreshold:
            results = filterByRotationThreshold(films, query: token.value)
        }
        
        // Handle inversion
        if token.isInverted {
            let resultIDs = Set(results.map { $0.id })
            return films.filter { !resultIDs.contains($0.id) }
        }
        
        return results
    }
    
    /// Filter film snapshots based on current search state.
    /// Called by DataCoordinator after view-scoped films are retrieved.
    ///
    /// 'listNames' is a closure that returns the names of all lists a given film
    /// belongs to. Callers supply this to avoid coupling SearchController to
    /// MemoryStore directly. DataCoordinator provides this via its own helper.
    /// The `listNames` closure is required rather than defaulted: the only sensible default
    /// (`{ _ in [] }`) silently makes every `#list` token match nothing, which is a wrong
    /// answer rather than a degraded one. Requiring it means a future caller cannot omit it
    /// by accident.
    func filterFilms(_ films: [FilmSnapshot], listNames: (UUID) -> [String]) -> [FilmSnapshot] {
        
        // During token entry, maintain last confirmed search state
        if !isActive {
            Self.log("filterFilms: Token entry mode - using last confirmed state")
            return applyFilters(to: films, tokens: lastConfirmedTokens, searchText: lastConfirmedText, listNames: listNames)
        }
        
        Self.log("filterFilms: Filtering \(films.count) films with \(currentTokens.count) tokens, searchText='\(searchText)'")
        
        return applyFilters(to: films, tokens: currentTokens, searchText: getCleanSearchText(), listNames: listNames)
    }
    
    /// Apply filtering logic with given tokens and search text
    private func applyFilters(
        to films: [FilmSnapshot],
        tokens: [SearchToken],
        searchText: String,
        listNames: (UUID) -> [String]
    ) -> [FilmSnapshot] {
        // Separate tokens into three groups:
        //   AND  — normal positive match, all must be satisfied (intersection)
        //   OR   — additional positive match, any one is sufficient (union added to AND results)
        //   NOT  — global exclusion applied after the positive set is built
        // OR+inverted tokens (isOr && isInverted) are treated as global exclusions,
        // consistent with the intent of "also exclude these" rather than "OR-union exclusion".
        let andTokens = tokens.filter { !$0.isOr && !$0.isInverted }
        let orTokens  = tokens.filter {  $0.isOr && !$0.isInverted }
        let notTokens = tokens.filter {  $0.isInverted }

        var filtered: [FilmSnapshot]

        // Step 1: Apply all AND tokens (intersection — every AND token must match)
        var andResults = films
        for token in andTokens {
            andResults = applyTokenFilter(token: token, to: andResults, listNames: listNames)
        }

        // Step 2: Apply OR tokens (union — collect IDs for any OR match against the full set)
        var orResults: Set<UUID> = []
        if !orTokens.isEmpty {
            for token in orTokens {
                let matches = applyTokenFilter(token: token, to: films, listNames: listNames)
                orResults.formUnion(matches.map { $0.id })
            }
        }

        // Step 3: Combine AND and OR results
        if andTokens.isEmpty && !orTokens.isEmpty {
            // Only OR tokens — use OR results
            filtered = films.filter { orResults.contains($0.id) }
        } else if !andTokens.isEmpty && orTokens.isEmpty {
            // Only AND tokens — use AND results
            filtered = andResults
        } else if !andTokens.isEmpty && !orTokens.isEmpty {
            // Both AND and OR — union: any film satisfying AND or OR qualifies
            let andIDs = Set(andResults.map { $0.id })
            let combinedIDs = andIDs.union(orResults)
            filtered = films.filter { combinedIDs.contains($0.id) }
        } else {
            // No positive tokens — start from full set
            filtered = films
        }

        // Step 4: Apply NOT tokens (global exclusions from the positive set).
        // applyTokenFilter already handles inversion internally: when token.isInverted
        // is true, it returns the complement of the matched set. Passing the token
        // through once here gives the correct exclusion behavior.
        for token in notTokens {
            filtered = applyTokenFilter(token: token, to: filtered, listNames: listNames)
        }

        // Step 5: Apply freeform text search (clean text only, # patterns already stripped).
        // Freeform text matches against title and alternate titles, identical to the
        // .title token — both share matchesTitle to keep the two paths in lockstep.
        // A query of nothing but punctuation normalizes to "", which names no text to
        // match, so it narrows nothing — the same as an empty field.
        let queryKey = SearchText.key(searchText)
        if !queryKey.isEmpty {
            filtered = filtered.filter { matchesTitle($0, query: queryKey) }
        }

        return filtered
    }
    
    // MARK: - Specialized Filters
    
    /// Parses an inclusive "low-high" range such as "2000-2020", "90-120" or "7-9", or nil
    /// when `query` is not that shape. Both ends must be whole numbers, so the open-ended
    /// "8-" (rating at most 8) and a leading-minus value are not ranges. Shared by the
    /// year, duration and rating tokens so the three accept exactly the same form. A
    /// reversed range ("9-7") parses and simply matches nothing.
    private func parseNumericRange(_ query: String) -> (low: Int, high: Int)? {
        let parts = query.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return nil }
        return (low, high)
    }

    /// Every word typed must appear in the film's synopsis, in any order, each as a
    /// case-insensitive substring ("sins" also matches "business"). Whitespace only
    /// separates words, so extra spaces change nothing. The synopsis is `descriptionText`;
    /// the film's own notes are what `.notes` searches.
    private func filterBySynopsis(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        let words = SearchText.key(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return films.filter { film in
            let synopsis = SearchText.key(film.descriptionText)
            return words.allSatisfy { synopsis.contains($0) }
        }
    }

    private func filterByYear(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        // Range: 2000-2020
        if let range = parseNumericRange(query) {
            return films.filter {
                guard let year = Int($0.releaseYear) else { return false }
                return year >= range.low && year <= range.high
            }
        }
        
        // Greater than: >2020
        if query.hasPrefix(">"), let year = Int(query.dropFirst()) {
            return films.filter { (Int($0.releaseYear) ?? 0) > year }
        }
        
        // Less than: <2020. A film with no release year has no year to compare, so it is
        // excluded here exactly as the range and greater-than forms exclude it — reading it
        // as year 0 made every undated film match every "<" query.
        if query.hasPrefix("<"), let year = Int(query.dropFirst()) {
            return films.filter {
                guard let filmYear = Int($0.releaseYear) else { return false }
                return filmYear < year
            }
        }
        
        // Exact match
        return films.filter { $0.releaseYear == query }
    }
    
    /// Runs on `FilmSnapshot.effectiveDuration`: the edited runtime when the film is edited
    /// and has one, otherwise the regular runtime — the same length the gallery sort, its
    /// duration bands and the viewing popover use.
    private func filterByDuration(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        // Range: 90-120 (minutes, both ends included). A film with no stored duration is
        // excluded, as it is from the "<" form.
        if let range = parseNumericRange(query) {
            return films.filter {
                guard let minutes = DurationHelpers.storedMinutes($0.effectiveDuration) else { return false }
                return minutes >= range.low && minutes <= range.high
            }
        }
        if query.hasPrefix(">"), let mins = Int(query.dropFirst()) {
            return films.filter { parseDurationToMinutes($0.effectiveDuration) > mins }
        }
        // A film with no stored duration is excluded, not read as 0 minutes long; otherwise
        // every film missing a duration matched every "<" query.
        if query.hasPrefix("<"), let mins = Int(query.dropFirst()) {
            return films.filter {
                guard let filmMinutes = DurationHelpers.storedMinutes($0.effectiveDuration) else { return false }
                return filmMinutes < mins
            }
        }
        if let mins = Int(query) {
            return films.filter { parseDurationToMinutes($0.effectiveDuration) >= mins }
        }
        // Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    private func filterByRating(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        // Range: 7-9 (both ends included). Taken literally, so "0-3" reaches down to the
        // unrated films; the "at most" and "<" forms below are what skip them.
        if let range = parseNumericRange(query) {
            return films.filter { $0.userRating >= range.low && $0.userRating <= range.high }
        }
        // Exclusive greater-than: >7 → rating > 7
        if query.hasPrefix(">"), let rating = Int(query.dropFirst()) {
            return films.filter { $0.userRating > rating }
        }
        // Exclusive less-than: <9 → rating < 9. The two upper-bound forms skip unrated
        // films: 0 means "Not Rated" (the Unwatched tab's own rule), not a rating below 9.
        // An exact "0" query below still finds them when asked for by name.
        if query.hasPrefix("<"), let rating = Int(query.dropFirst()) {
            return films.filter { $0.userRating > 0 && $0.userRating < rating }
        }
        // Inclusive "at least": 8+ → rating >= 8
        if query.hasSuffix("+"), let rating = Int(query.dropLast()) {
            return films.filter { $0.userRating >= rating }
        }
        // Inclusive "at most": 8- → rating <= 8
        if query.hasSuffix("-"), let rating = Int(query.dropLast()) {
            return films.filter { $0.userRating > 0 && $0.userRating <= rating }
        }
        // Exact match: 8 → rating == 8
        if let rating = Int(query) {
            return films.filter { $0.userRating == rating }
        }
        // Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    /// Shared implementation for date-field token filters (lastWatched, dateAdded).
    ///
    /// `fieldValue` extracts the raw date string from a FilmSnapshot.
    /// "none" finds films with no date for the field; a bare year ("2025") finds that
    /// calendar year. A query that matches none of the forms below, or names a date that cannot be parsed,
    /// returns no films — the same answer a misspelled title gets. It used to return every
    /// film with any value for the field, which made a typo look like a successful search.
    ///
    /// Supported query forms (case-insensitive):
    ///   Keyword:   "none" (no date recorded)
    ///   Year:      "2025" (that calendar year)
    ///   Relative:  "today", "week" / "past week", "month" / "past month", "year" / "past year"
    ///   Operators: ">YYYY", "<YYYY", ">YYYY-MM-DD", "<YYYY-MM-DD"
    ///   Month/year: "December 2020", "Dec 2020", "December, 2020", "Dec, 2020"
    ///   Exact day:  any string parseable by the global parseDate(from:)
    ///   Natural:    "2 months ago", "last summer", "since march", … (naturalDateMatcher)
    private func filterByDateField(
        _ films: [FilmSnapshot],
        query: String,
        fieldValue: (FilmSnapshot) -> String
    ) -> [FilmSnapshot] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()
        let calendar = Calendar.current
        
        // "none": films with no date recorded for the field (for Last Watched, no viewing
        // date). Tested first so no other form can claim the word.
        if q == "none" || q == "never" {
            return films.filter { fieldValue($0).isEmpty }
        }
        
        // A bare four-digit year: every date inside that calendar year.
        if q.count == 4, let year = Int(q), year > 1900 && year < 2100 {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= start && date < end
            }
        }
        
        // Natural-language phrases (“2 months ago”, “last summer”, “since march”, “between
        // 2019 and 2021”). Tried ahead of the fixed forms below. It accepts nothing they do
        // except the rolling words, which it reads exactly as they do, the month-year form,
        // and spelled-out dates, which name the same span either way.
        if let matches = naturalDateMatcher(q, now: now) {
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return matches(date)
            }
        }
        
        // Relative: today
        if q.contains("today") {
            let startOfToday = calendar.startOfDay(for: now)
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= startOfToday
            }
        }
        
        // Relative: week / past week (last 7 days)
        if q.contains("week") {
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else {
                return []
            }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= weekAgo
            }
        }
        
        // Relative: month / past month (last calendar month)
        if q.contains("month") {
            guard let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) else {
                return []
            }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= monthAgo
            }
        }
        
        // Relative: year / past year (last calendar year)
        if q.contains("year") {
            guard let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) else {
                return []
            }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= yearAgo
            }
        }
        
        // Operator: >date — after the given date (exclusive)
        if q.hasPrefix(">") {
            let dateString = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let year = Int(dateString), year > 1900 && year < 2100 {
                // ">2019" means after the last moment of 2019, i.e. dateAdded/lastWatched is in 2020+
                let comps = DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59)
                guard let yearEndDate = calendar.date(from: comps) else {
                    return []
                }
                return films.filter {
                    guard let date = parseDate(from: fieldValue($0)) else { return false }
                    return date > yearEndDate
                }
            }
            // A natural phrase works too: “>last summer” is after the end of last summer.
            guard let compareDate = parseDate(from: dateString)
                    ?? naturalDateAnySpan(naturalDateWords(dateString), now: now)?.end else { return [] }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date > compareDate
            }
        }
        
        // Operator: <date — before the given date (exclusive)
        if q.hasPrefix("<") {
            let dateString = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let year = Int(dateString), year > 1900 && year < 2100 {
                // "<2020" means before the first moment of 2020, i.e. dateAdded/lastWatched is ≤ 2019
                let comps = DateComponents(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0)
                guard let yearStartDate = calendar.date(from: comps) else {
                    return []
                }
                return films.filter {
                    guard let date = parseDate(from: fieldValue($0)) else { return false }
                    return date < yearStartDate
                }
            }
            guard let compareDate = parseDate(from: dateString)
                    ?? naturalDateAnySpan(naturalDateWords(dateString), now: now)?.start else { return [] }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date < compareDate
            }
        }
        
        // Month+year: "December 2020", "Dec 2020", "December, 2020", "Dec, 2020"
        if let monthYearDate = parseMonthYear(q) {
            let startOfMonth = calendar.startOfDay(for: monthYearDate)
            guard let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth) else {
                return []
            }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= startOfMonth && date <= endOfMonth
            }
        }
        
        // Exact day match: any parseable date string
        if let compareDate = parseDate(from: q) {
            let startOfDay = calendar.startOfDay(for: compareDate)
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                return []
            }
            return films.filter {
                guard let date = parseDate(from: fieldValue($0)) else { return false }
                return date >= startOfDay && date < endOfDay
            }
        }
        
        // Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    // Cached formatters for parseMonthYear to avoid repeated allocations.
    // DateFormatter creation is expensive (~0.5ms per instantiation × 4 = ~2ms saved per call).
    private static let monthYearFormatters: [DateFormatter] = {
        let formats = [
            "MMMM yyyy",
            "MMM yyyy",
            "MMMM, yyyy",
            "MMM, yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            return formatter
        }
    }()
    
    // Helper to parse "month year" queries (e.g., "december 2020", "dec 2020")
    private func parseMonthYear(_ query: String) -> Date? {
        for formatter in Self.monthYearFormatters {
            if let date = formatter.date(from: query) {
                return date
            }
        }
        
        return nil
    }
    
    // MARK: - Natural-Language Dates
    //
    // The everyday phrasings a date token accepts on top of the fixed forms in
    // filterByDateField: "2 months ago", "last summer", "since march", "between 2019 and
    // 2021", "early december 2020", and so on. Both date fields use them.
    //
    // Every lowercase keyword literal in these functions is a word the search guide must
    // mention: the `guide-sync` harness scenario (99.53) scans their bodies for literals.
    // Keep backslashes and string interpolation out of them — either derails that scan.

    /// A half-open span of time, `start ..< end`.
    private struct DateSpan {
        let start: Date
        let end: Date
    }

    /// The units an amount of time can be counted in.
    private enum DateUnit {
        case day, week, fortnight, month, year, decade
    }

    /// Splits a date query into words: lowercased, apostrophes dropped ("new year's",
    /// "'90s"), commas treated as spaces, ordinal suffixes removed ("25th" → "25"), and
    /// filler words that never change the meaning left out.
    private func naturalDateWords(_ query: String) -> [String] {
        let fillers: Set<String> = ["about", "around", "roughly", "approximately", "circa",
                                    "the", "on", "in", "of", "during", "sometime"]
        let cleaned = query.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: ",", with: " ")
        return cleaned.split(whereSeparator: { $0.isWhitespace }).compactMap { piece in
            var word = String(piece)
            // An ordinal: digits followed by exactly two letters (“1st”, “25th”).
            let digits = word.prefix(while: { $0.isNumber })
            let suffix = word.dropFirst(digits.count)
            if !digits.isEmpty, suffix.count == 2, suffix.allSatisfy({ $0.isLetter }) {
                word = String(digits)
            }
            return fillers.contains(word) ? nil : word
        }
    }

    /// A unit word, singular, plural, or abbreviated.
    private func naturalDateUnit(_ word: String) -> DateUnit? {
        switch word {
        case "day", "days": return .day
        case "week", "weeks", "wk", "wks": return .week
        case "fortnight", "fortnights": return .fortnight
        case "month", "months", "mo", "mos": return .month
        case "year", "years", "yr", "yrs": return .year
        case "decade", "decades": return .decade
        default: return nil
        }
    }

    /// A count written as digits ("3", "1.5") or words ("a", "two", "a couple", "a few").
    private func naturalDateQuantity(_ words: [String]) -> Double? {
        guard !words.isEmpty else { return 1 }
        let phrase = words.joined(separator: " ")
        switch phrase {
        case "a", "an", "one", "a single", "single": return 1
        case "half", "half a", "half an", "a half": return 0.5
        case "two", "a couple", "couple", "a pair", "pair": return 2
        case "three", "a few", "few": return 3
        case "four", "several": return 4
        case "five": return 5
        case "six", "half a dozen", "half dozen": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        case "ten": return 10
        case "eleven": return 11
        case "twelve", "a dozen", "dozen": return 12
        case "fifteen": return 15
        case "eighteen": return 18
        case "twenty": return 20
        case "thirty": return 30
        default:
            guard let value = Double(phrase), value > 0, value.isFinite else { return nil }
            return value
        }
    }

    /// An amount of time: "[count] unit [and a half]" — "3 weeks", "a year and a half",
    /// "half a year", "month" (a bare unit counts one).
    private func naturalDateOffset(_ words: [String]) -> (amount: Double, unit: DateUnit)? {
        var words = words
        var extra = 0.0
        if words.count >= 3, Array(words.suffix(3)) == ["and", "a", "half"] {
            extra = 0.5
            words.removeLast(3)
        }
        guard let unitWord = words.last, let unit = naturalDateUnit(unitWord),
              let count = naturalDateQuantity(Array(words.dropLast())) else { return nil }
        return (count + extra, unit)
    }

    /// `date` moved back by an amount of time. Whole months and years use calendar
    /// arithmetic; fractions of them are converted to days.
    private func naturalDate(_ date: Date, back amount: Double, _ unit: DateUnit) -> Date? {
        let cal = Calendar.current
        let days: Double
        let months: Double
        switch unit {
        case .day: days = amount; months = 0
        case .week: days = amount * 7; months = 0
        case .fortnight: days = amount * 14; months = 0
        case .month: days = 0; months = amount
        case .year: days = 0; months = amount * 12
        case .decade: days = 0; months = amount * 120
        }
        if months > 0 {
            if months == months.rounded() {
                return cal.date(byAdding: .month, value: -Int(months), to: date)
            }
            return cal.date(byAdding: .day, value: -Int((months * 30.44).rounded()), to: date)
        }
        return cal.date(byAdding: .day, value: -Int(days.rounded()), to: date)
    }

    /// Days either side of the target an "… ago" search also accepts: none for a day or
    /// two, a week either side of a number of months, a month either side of years.
    private func naturalDateTolerance(_ amount: Double, _ unit: DateUnit) -> Int {
        switch unit {
        case .day: return amount <= 2 ? 0 : 1
        case .week: return amount <= 1 ? 2 : 3
        case .fortnight: return 3
        case .month: return 7
        case .year: return 30
        case .decade: return 182
        }
    }

    /// The natural-language date phrases, as a test against a film's date, or nil when
    /// the query is not one of them.
    private func naturalDateMatcher(_ query: String, now: Date) -> ((Date) -> Bool)? {
        let words = naturalDateWords(query)
        guard !words.isEmpty else { return nil }
        let cal = Calendar.current
        let phrase = words.joined(separator: " ")

        // Any recorded date at all.
        if ["ever", "anytime", "any time", "any date"].contains(phrase) {
            return { _ in true }
        }

        // Today's month and day, in any year.
        if ["this day", "this date"].contains(phrase) {
            let today = cal.dateComponents([.month, .day], from: now)
            return { date in
                let comps = cal.dateComponents([.month, .day], from: date)
                return comps.month == today.month && comps.day == today.day
            }
        }

        // An amount of time ago, compared: “more than 2 years ago” is older than that
        // moment; “less than 3 weeks ago” and “within 3 weeks” are more recent.
        let comparators: [(words: [String], older: Bool)] = [
            (["no", "more", "than"], false), (["more", "than"], true), (["over"], true),
            (["at", "least"], true), (["older", "than"], true), (["longer", "than"], true),
            (["less", "than"], false), (["under"], false), (["fewer", "than"], false),
            (["newer", "than"], false), (["within"], false), (["at", "most"], false)
        ]
        for comparator in comparators where words.starts(with: comparator.words) {
            var rest = Array(words.dropFirst(comparator.words.count))
            if rest.last == "ago" { rest.removeLast() }
            guard let offset = naturalDateOffset(rest),
                  let moment = naturalDate(now, back: offset.amount, offset.unit) else { return nil }
            return comparator.older ? { $0 < moment } : { $0 >= moment }
        }

        guard let span = naturalDateSpan(words, now: now) else { return nil }
        return { $0 >= span.start && $0 < span.end }
    }

    /// The fixed single-period forms (a year, "dec 2020", a full date) or a natural phrase,
    /// as a span. Used for each side of a range and for "since"/"before"/"after".
    private func naturalDateAnySpan(_ words: [String], now: Date) -> DateSpan? {
        let cal = Calendar.current
        let text = words.joined(separator: " ")
        if words.count == 1, text.count == 4, let year = Int(text), year > 1900 && year < 2100,
           let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = cal.date(byAdding: .year, value: 1, to: start) {
            return DateSpan(start: start, end: end)
        }
        if let date = parseDate(from: text) {
            let start = cal.startOfDay(for: date)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateSpan(start: start, end: end)
        }
        return naturalDateSpan(words, now: now)
    }

    /// The natural phrases that name one stretch of time.
    private func naturalDateSpan(_ words: [String], now: Date) -> DateSpan? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let phrase = words.joined(separator: " ")
        let forever = Date.distantFuture
        let dawn = Date.distantPast

        func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date? {
            cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
        }
        func days(from start: Date, count: Int) -> DateSpan? {
            guard let end = cal.date(byAdding: .day, value: count, to: start) else { return nil }
            return DateSpan(start: start, end: end)
        }

        // MARK: Ranges — “between X and Y”, “from X to Y”, “X through Y”
        // A split that does not leave a date on both sides falls through, so "prior to
        // 2020" still reaches the open-ended forms below.
        if words.first == "between", let split = words.firstIndex(of: "and"), split > 1,
           let from = naturalDateAnySpan(Array(words[1..<split]), now: now),
           let to = naturalDateAnySpan(Array(words[(split + 1)...]), now: now) {
            return from.start < to.end ? DateSpan(start: from.start, end: to.end) : nil
        }
        let rangeWords: Set<String> = ["to", "through", "thru", "until", "till"]
        if let split = words.firstIndex(where: { rangeWords.contains($0) }), split > 0 {
            let leftStart = words.first == "from" ? 1 : 0
            var left = Array(words[leftStart..<split])
            let right = Array(words[(split + 1)...])
            // A year stated only on the right applies to both sides: “march to june 2025”.
            if let year = right.last, year.count == 4, Int(year) != nil,
               let leftLast = left.last, !(leftLast.count == 4 && Int(leftLast) != nil) {
                left.append(year)
            }
            if split > leftStart,
               let from = naturalDateAnySpan(left, now: now),
               let to = naturalDateAnySpan(right, now: now) {
                return from.start < to.end ? DateSpan(start: from.start, end: to.end) : nil
            }
        }

        // MARK: Open-ended — “since X”, “after X”, “before X”, “until X”
        if let first = words.first, words.count > 1 {
            let rest = Array(words.dropFirst())
            switch first {
            case "since", "from":
                guard let span = naturalDateAnySpan(rest, now: now) else { return nil }
                return DateSpan(start: span.start, end: forever)
            case "after":
                guard let span = naturalDateAnySpan(rest, now: now) else { return nil }
                return DateSpan(start: span.end, end: forever)
            case "before", "prior":
                let target = rest.first == "to" ? Array(rest.dropFirst()) : rest
                guard let span = naturalDateAnySpan(target, now: now) else { return nil }
                return DateSpan(start: dawn, end: span.start)
            case "until", "till", "through", "thru":
                guard let span = naturalDateAnySpan(rest, now: now) else { return nil }
                return DateSpan(start: dawn, end: span.end)
            default:
                break
            }
        }

        // MARK: Named days
        switch phrase {
        case "today", "tonight":
            // Matches the rolling “today” form: anything from the start of today on.
            return DateSpan(start: today, end: forever)
        case "yesterday", "last night":
            guard let start = cal.date(byAdding: .day, value: -1, to: today) else { return nil }
            return days(from: start, count: 1)
        case "day before yesterday":
            guard let start = cal.date(byAdding: .day, value: -2, to: today) else { return nil }
            return days(from: start, count: 1)
        case "recently", "lately", "recent":
            guard let start = cal.date(byAdding: .day, value: -30, to: now) else { return nil }
            return DateSpan(start: start, end: forever)
        default:
            break
        }

        // MARK: “… ago” — “2 months ago”, “a year and a half ago”, “a week ago today”
        if let agoIndex = words.lastIndex(of: "ago"),
           agoIndex == words.count - 1 || (agoIndex == words.count - 2 && words.last == "today") {
            guard let offset = naturalDateOffset(Array(words[..<agoIndex])),
                  let target = naturalDate(today, back: offset.amount, offset.unit) else { return nil }
            let tolerance = words.last == "today" ? 0 : naturalDateTolerance(offset.amount, offset.unit)
            guard let start = cal.date(byAdding: .day, value: -tolerance, to: target) else { return nil }
            return days(from: start, count: tolerance * 2 + 1)
        }

        // MARK: “Earlier this …” — the calendar period so far
        if words.count == 3, words[0] == "earlier", words[1] == "this" {
            let component: Calendar.Component
            switch words[2] {
            case "week": component = .weekOfYear
            case "month": component = .month
            case "year": component = .year
            default: return nil
            }
            guard let start = cal.dateInterval(of: component, for: now)?.start else { return nil }
            return DateSpan(start: start, end: forever)
        }

        // MARK: Rolling windows — “last 3 months”, “past 10 days”, “this week”, “6 weeks”
        let rollingWords: Set<String> = ["last", "past", "previous", "this"]
        let rollingRest = rollingWords.contains(words[0]) ? Array(words.dropFirst()) : words
        if let offset = naturalDateOffset(rollingRest),
           let start = naturalDate(now, back: offset.amount, offset.unit) {
            return DateSpan(start: start, end: forever)
        }

        // MARK: Weekends and weekdays — “last weekend”, “saturday”, “last friday”
        var relation: String?
        var core = words
        if let first = core.first, ["last", "this", "previous"].contains(first), core.count > 1 {
            relation = first == "previous" ? "last" : first
            core.removeFirst()
        }
        let weekday = cal.component(.weekday, from: now) // 1 = Sunday … 7 = Saturday
        if core == ["weekend"] {
            // The Saturday that begins the most recent weekend (this one, if it is under way).
            var back = weekday % 7
            if relation == "last", weekday == 7 || weekday == 1 { back += 7 }
            guard let saturday = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return days(from: saturday, count: 2)
        }
        let weekdayNames: [String: Int] = [
            "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
            "friday": 6, "fri": 6, "saturday": 7, "sat": 7
        ]
        if core.count == 1, let target = weekdayNames[core[0]] {
            var back = (weekday - target + 7) % 7
            if relation == "last", back == 0 { back = 7 }
            guard let start = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return days(from: start, count: 1)
        }

        // MARK: Decades — “2010s”, “90s”, “early 2000s”
        var part: String?
        let partWords: [String: String] = [
            "early": "early", "beginning": "early", "start": "early",
            "mid": "mid", "middle": "mid",
            "late": "late", "end": "late"
        ]
        if let first = core.first, let mapped = partWords[first], core.count > 1 {
            part = mapped
            core.removeFirst()
        } else if core.count > 2, core[1] == "half", core[0] == "first" || core[0] == "second" {
            part = core[0] == "first" ? "first half" : "second half"
            core.removeFirst(2)
        }
        if core.count == 1, core[0].last?.isLetter == true, let number = Int(core[0].dropLast()) {
            var decade: Int?
            if number >= 1900, number < 2100, number % 10 == 0 { decade = number }
            if core[0].count == 3, number % 10 == 0 {
                let current = cal.component(.year, from: now) % 100
                decade = number <= current ? 2000 + number : 1900 + number
            }
            guard let decade, let start = day(decade, 1, 1),
                  let end = day(decade + 10, 1, 1) else { return nil }
            return naturalDatePortion(DateSpan(start: start, end: end), part: part)
        }

        // MARK: Calendar periods — months, days, seasons, quarters, holidays
        var explicitYear: Int?
        if let last = core.last, last.count == 4, let year = Int(last), year > 1900 && year < 2100 {
            explicitYear = year
            core.removeLast()
        }
        // “late last year”, “early this year”: the calendar year itself.
        if core == ["last", "year"] || core == ["this", "year"], explicitYear == nil, part != nil {
            let year = cal.component(.year, from: now) - (core[0] == "last" ? 1 : 0)
            guard let start = day(year, 1, 1), let end = day(year + 1, 1, 1) else { return nil }
            return naturalDatePortion(DateSpan(start: start, end: end), part: part)
        }
        // A numeric month: “2020-12”, “12/2020”, “2020.12”.
        if core.count == 1, explicitYear == nil, relation == nil {
            let pieces = core[0].split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." })
            if pieces.count == 2 {
                let first = String(pieces[0])
                let second = String(pieces[1])
                let (yearText, monthText) = first.count == 4 ? (first, second) : (second, first)
                guard yearText.count == 4, let year = Int(yearText), let month = Int(monthText),
                      (1...12).contains(month), let start = day(year, month, 1),
                      let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
                return naturalDatePortion(DateSpan(start: start, end: end), part: part)
            }
        }

        let monthNames: [String: Int] = [
            "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
            "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
            "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "october": 10,
            "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12
        ]

        // The period `core` names in a given year, or nil when `core` names none.
        func period(in year: Int) -> DateSpan? {
            if core.isEmpty, part != nil {
                guard let start = day(year, 1, 1), let end = day(year + 1, 1, 1) else { return nil }
                return DateSpan(start: start, end: end)
            }
            guard !core.isEmpty else { return nil }
            // A month, or a month and day in either order (“dec 25”, “25 december”).
            if let month = monthNames[core[0]] {
                if core.count == 1 {
                    guard let start = day(year, month, 1),
                          let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
                    return DateSpan(start: start, end: end)
                }
                if core.count == 2, let dayOfMonth = Int(core[1]), (1...31).contains(dayOfMonth),
                   let start = day(year, month, dayOfMonth),
                   cal.component(.day, from: start) == dayOfMonth {
                    return days(from: start, count: 1)
                }
                return nil
            }
            if core.count == 2, let dayOfMonth = Int(core[0]), let month = monthNames[core[1]],
               (1...31).contains(dayOfMonth), let start = day(year, month, dayOfMonth),
               cal.component(.day, from: start) == dayOfMonth {
                return days(from: start, count: 1)
            }
            // Meteorological seasons. Winter is named for the year its December falls in.
            let seasonStarts: [String: Int] = ["spring": 3, "summer": 6, "fall": 9, "winter": 12]
            if core.count == 1, let month = seasonStarts[core[0]] {
                guard let start = day(year, month, 1),
                      let end = cal.date(byAdding: .month, value: 3, to: start) else { return nil }
                return DateSpan(start: start, end: end)
            }
            // Quarters.
            let quarters: [String: Int] = ["q1": 1, "q2": 4, "q3": 7, "q4": 10]
            if core.count == 1, let month = quarters[core[0]] {
                guard let start = day(year, month, 1),
                      let end = cal.date(byAdding: .month, value: 3, to: start) else { return nil }
                return DateSpan(start: start, end: end)
            }
            // Holidays (US). The Fourth of July arrives as two words once the filler is gone.
            if core == ["fourth", "july"] {
                return day(year, 7, 4).flatMap { days(from: $0, count: 1) }
            }
            switch core.joined(separator: " ") {
            case "christmas", "xmas":
                return day(year, 12, 24).flatMap { days(from: $0, count: 3) }
            case "christmas eve":
                return day(year, 12, 24).flatMap { days(from: $0, count: 1) }
            case "christmas day":
                return day(year, 12, 25).flatMap { days(from: $0, count: 1) }
            case "new years eve", "nye":
                return day(year, 12, 31).flatMap { days(from: $0, count: 1) }
            case "new years", "new years day", "new year":
                return day(year - 1, 12, 31).flatMap { days(from: $0, count: 2) }
            case "halloween":
                return day(year, 10, 31).flatMap { days(from: $0, count: 1) }
            case "valentines", "valentines day":
                return day(year, 2, 14).flatMap { days(from: $0, count: 1) }
            case "independence day":
                return day(year, 7, 4).flatMap { days(from: $0, count: 1) }
            case "thanksgiving":
                // The fourth Thursday of November, through that weekend.
                guard let first = day(year, 11, 1) else { return nil }
                let firstWeekday = cal.component(.weekday, from: first)
                let firstThursday = 1 + (5 - firstWeekday + 7) % 7
                return day(year, 11, firstThursday + 21).flatMap { days(from: $0, count: 4) }
            case "holidays", "holiday season":
                guard let start = day(year, 12, 20), let end = day(year + 1, 1, 3) else { return nil }
                return DateSpan(start: start, end: end)
            default:
                return nil
            }
        }

        let currentYear = cal.component(.year, from: now)
        let span: DateSpan?
        if let explicitYear {
            guard relation == nil else { return nil }
            span = period(in: explicitYear)
        } else {
            guard let thisYears = period(in: currentYear) else { return nil }
            switch relation {
            case "last":
                // The most recent occurrence that is already over.
                span = thisYears.end <= now ? thisYears : period(in: currentYear - 1)
            case "this":
                // The occurrence under way, or else this calendar year's.
                if thisYears.start > now, let previous = period(in: currentYear - 1), previous.end > now {
                    span = previous
                } else {
                    span = thisYears
                }
            default:
                // The most recent occurrence that has begun.
                span = thisYears.start <= now ? thisYears : period(in: currentYear - 1)
            }
        }
        guard let span else { return nil }
        return naturalDatePortion(span, part: part)
    }

    /// The early, middle, or late third — or the first or second half — of a span. Spans
    /// of three months or more divide by whole months; shorter ones by days.
    private func naturalDatePortion(_ span: DateSpan, part: String?) -> DateSpan? {
        guard let part else { return span }
        let cal = Calendar.current
        let pieces = part.hasSuffix("half") ? 2 : 3
        let index: Int
        switch part {
        case "early", "first half": index = 0
        case "mid": index = 1
        case "late": index = pieces - 1
        default: index = pieces - 1
        }
        let months = cal.dateComponents([.month], from: span.start, to: span.end).month ?? 0
        if months >= 3 {
            let size = Double(months) / Double(pieces)
            let from = Int((Double(index) * size).rounded())
            let to = Int((Double(index + 1) * size).rounded())
            guard let start = cal.date(byAdding: .month, value: from, to: span.start),
                  let end = cal.date(byAdding: .month, value: to, to: span.start) else { return nil }
            return DateSpan(start: start, end: end)
        }
        let length = cal.dateComponents([.day], from: span.start, to: span.end).day ?? 0
        guard length >= pieces else { return span }
        // A month splits 1–10 / 11–20 / 21–end, or 1–15 / 16–end.
        let size = pieces == 3 ? 10 : 15
        let from = index * size
        let to = index == pieces - 1 ? length : (index + 1) * size
        guard let start = cal.date(byAdding: .day, value: from, to: span.start),
              let end = cal.date(byAdding: .day, value: to, to: span.start) else { return nil }
        return DateSpan(start: start, end: end)
    }

    /// Filters films by list name using the caller-supplied list name lookup closure.
    /// 'listNames' returns the names of all lists a given film ID belongs to.
    private func filterByList(
        _ films: [FilmSnapshot],
        query: String,
        listNames: (UUID) -> [String]
    ) -> [FilmSnapshot] {
        let q = SearchText.key(query)
        return films.filter { film in
            listNames(film.id).contains { fuzzyMatchOptimized($0, query: q) }
        }
    }
    
    private func filterByReleases(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Upcoming: a release whose date is still ahead (ReleaseDateValue.isUpcoming), the
        // same rule as the "Upcoming Releases" smart list and the release card's badge.
        if q == "upcoming" || q == "unreleased" || q == "preorder" || q == "pre-order" {
            let today = StorageDateFormatters.calendar.startOfDay(for: Date())
            return films.filter { film in
                film.releases.contains {
                    ReleaseDateValue($0.releaseDate, format: $0.format)?.isUpcoming(today: today) ?? false
                }
            }
        }

        // A release date: "2027", "2020-2027", ">2026", "<2020.06.01", "March 2027",
        // "2027.03.14" — see releaseDateMatcher. Tested before the keyword forms below, none
        // of which starts with a digit or an operator or names a month and year.
        if let matches = Self.releaseDateMatcher(q, parseMonthYear: parseMonthYear) {
            return films.filter { film in
                film.releases.contains {
                    guard let date = ReleaseDateValue($0.releaseDate, format: $0.format) else { return false }
                    return matches(date)
                }
            }
        }

        // Each branch only needs to know whether a release of a given kind EXISTS, so it
        // uses releases.contains { … } directly. The FilmSnapshot convenience properties
        // this once went through (purchasedReleases / releases4K / releases2K / releasesSD,
        // since deleted) built a filtered, sorted copy of the array on every access; testing
        // their .isEmpty paid for an allocation and an O(R log R) sort whose result is
        // immediately discarded. contains is O(R), allocation-free, and behavior-identical.
        if q == "unpurchased" || q.contains("wishlist") || q.contains("wanted") {
            // Unpurchased/wishlist releases are those not marked as purchased.
            return films.filter { film in film.releases.contains { !$0.purchased } }
        }
        if q == "purchased" || q.contains("owned") {
            return films.filter { film in film.releases.contains { $0.purchased } }
        }

        // Master type ("native 4k"/"native"/"upscaled"/"upscale") is checked with exact
        // equality BEFORE the general 4K/UHD format branch below, since "native 4k"
        // contains "4k" as a substring and would otherwise be swallowed by that branch's
        // .contains("4k") check and answer the wrong question (format vs. master type).
        if q == "native 4k" || q == "native" {
            return films.filter { film in film.releases.contains { $0.masterType == ReleaseMasterType.nativeFourK } }
        }
        if q == "upscaled" || q == "upscale" {
            return films.filter { film in film.releases.contains { $0.masterType == ReleaseMasterType.upscaled } }
        }

        if q.contains("4k") || q.contains("uhd") {
            return films.filter { film in film.releases.contains { $0.format == ReleaseFormat.uhd4K.rawValue } }
        }
        if q.contains("2k") || q.contains("bluray") || q.contains("blu-ray") {
            return films.filter { film in film.releases.contains { $0.format == ReleaseFormat.bluRay.rawValue } }
        }
        if q.contains("dvd") {
            return films.filter { film in film.releases.contains { $0.format == ReleaseFormat.dvd.rawValue } }
        }

        // Imported vs. domestic: any release whose nationalOrigin is set to something
        // other than the domestic one — `ReleaseOrigin.isImport`, which also holds the
        // rule that an unset (empty) origin is neither.
        if q == "imported" || q == "foreign" {
            return films.filter { film in
                film.releases.contains { ReleaseOrigin.isImport($0.nationalOrigin) }
            }
        }

        // Region lock. Periods are stripped before matching so "reg. a"/"reg. free"/etc.
        // collapse onto the same forms as "reg a"/"reg free" without listing every
        // period-bearing variant separately.
        let regionQuery = q.replacingOccurrences(of: ".", with: "")
        if let regionTags = Self.regionLockTags(forQuery: regionQuery) {
            let tagSet = Set(regionTags)
            return films.filter { film in film.releases.contains { tagSet.contains($0.regionLock) } }
        }

        // Remastered
        if q == "remastered" || q == "remaster" || q == "rem" {
            return films.filter { film in film.releases.contains { $0.remastered } }
        }

        // HDR. Exact-match on the finite hasHDR vocabulary, so no ordering concerns
        // arise between e.g. "hdr10" and "hdr10+" the way substring checks would have.
        // The tags and the "which of these count as HDR" question both come from
        // ReleaseHDR, so these filters cannot drift from the picker that writes the field.
        if q == "hdr" {
            return films.filter { film in film.releases.contains { ReleaseHDR.isCapable($0.hasHDR) } }
        }
        if q == "dolby vision" || q == "dv" {
            return films.filter { film in film.releases.contains { $0.hasHDR == ReleaseHDR.dolbyVision } }
        }
        if q == "hdr10" {
            return films.filter { film in film.releases.contains { ReleaseHDR.isHDR10Family($0.hasHDR) } }
        }
        if q == "hdr10+" || q == "hdrplus" || q == "hdr+" {
            return films.filter { film in film.releases.contains { $0.hasHDR == ReleaseHDR.hdr10Plus } }
        }

        // Independence (pack type). "combo-pack"/"combopack"/"combo" cover both combo-pack
        // forms via the same ReleaseIndependence.isComboPack(_:) predicate the model itself
        // uses, so this stays in lockstep with any future combo-pack variant. The other two
        // independence values are exposed by the same logical extension.
        if q == "combo-pack" || q == "combopack" || q == "combo" {
            return films.filter { film in film.releases.contains { ReleaseIndependence.isComboPack($0.independence) } }
        }
        if q == "standalone" {
            return films.filter { film in film.releases.contains { $0.independence == ReleaseIndependence.standalone } }
        }
        if q == "multi-pack" || q == "multipack" || q == "multi" {
            return films.filter { film in film.releases.contains { $0.independence == ReleaseIndependence.multiPack } }
        }

        return films.filter { film in
            film.releases.contains { fuzzyMatchOptimized($0.studio, query: q) }
        }
    }

    /// The release-date forms of the releases token, as a test on one release's date, or nil
    /// when `q` is not one of them.
    ///
    ///   Year:       "2027" — any date in that year, or a year-only value of it
    ///   Range:      "2020-2027" — years, both ends included
    ///   Operators:  ">2026", "<2020" (years), ">2026.10.01", "<2020-06-01" (days, exclusive)
    ///   Month/year: "March 2027", "Mar 2027"
    ///   Exact day:  anything parseDate(from:) reads, e.g. "2027.03.14"
    ///
    /// Deliberately narrower than the lastWatched / dateAdded forms: the relative words
    /// ("week", "month", "today") and natural phrases look BACKWARD from now, which suits a
    /// viewing date and not a release date that may lie ahead — and, unlike a date token,
    /// this one also matches studio names, so only forms no studio name can take are read
    /// as dates.
    ///
    /// A release known only by its year matches the year forms, and a day comparison only
    /// when the whole year falls on one side of the day: "2026" is neither before nor after
    /// 2026.06.01.
    static func releaseDateMatcher(
        _ q: String,
        parseMonthYear: (String) -> Date?
    ) -> ((ReleaseDateValue) -> Bool)? {
        let cal = StorageDateFormatters.calendar
        func year(_ text: Substring) -> Int? {
            guard text.count == 4, let y = Int(text), ReleaseDateValue.storableYears.contains(y) else { return nil }
            return y
        }
        func dayKey(_ date: Date) -> (key: Int, year: Int) {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return ((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0), c.year ?? 0)
        }

        if let y = year(Substring(q)) { return { $0.year == y } }

        let parts = q.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let low = year(Substring(parts[0])), let high = year(Substring(parts[1])) {
            return { $0.year >= low && $0.year <= high }
        }

        if let op = q.first, op == ">" || op == "<" {
            let rest = q.dropFirst().trimmingCharacters(in: .whitespaces)
            let after = op == ">"
            if let y = year(Substring(rest)) {
                return after ? { $0.year > y } : { $0.year < y }
            }
            guard let date = parseDate(from: rest) else { return nil }
            let (key, dayYear) = dayKey(date)
            return { value in
                if value.isYearOnly { return after ? value.year > dayYear : value.year < dayYear }
                return after ? value.sortKey > key : value.sortKey < key
            }
        }

        if let monthStart = parseMonthYear(q) {
            let c = Calendar.current.dateComponents([.year, .month], from: monthStart)
            guard let y = c.year, let m = c.month else { return nil }
            return { $0.year == y && $0.monthDay?.month == m }
        }

        // Only strings that start with a digit: parseDate is lenient enough elsewhere that a
        // studio name should never be offered to it.
        if q.first?.isNumber == true, let date = parseDate(from: q) {
            let key = dayKey(date).key
            return { !$0.isYearOnly && $0.sortKey == key }
        }
        return nil
    }

    /// Maps a period-stripped, lowercased, trimmed release-token query fragment to the
    /// `regionLock` tag(s) it should match, or nil if the fragment does not describe a
    /// recognized region form.
    ///
    /// "Region A" and "Region 1"–"Region 5" each map to a single tag. "Region B" maps to
    /// two tags — the plain and loosely-locked variants — since both are region-B releases
    /// from the user's point of view. "Region Free" additionally accepts the negative
    /// phrasings ("no region", "no lock", "unlocked") a user might reach for instead.
    private static func regionLockTags(forQuery query: String) -> [String]? {
        switch query {
        case "region a", "reg a", "rega":
            return [ReleaseRegionRules.regionA]
        case "region b", "reg b", "regb":
            return Array(ReleaseRegionRules.regionBTags)
        case "region free", "reg free", "no region", "no reg", "no lock", "unlocked":
            return [ReleaseRegionRules.regionFree]
        default:
            // DVD region numbers (the only numbered regions this app's region pickers
            // offer): "region 1"/"reg 1"/"reg1", etc.
            for n in ReleaseRegionRules.dvdRegionNumbers {
                if query == "region \(n)" || query == "reg \(n)" || query == "reg\(n)" {
                    return [ReleaseRegionRules.dvdRegionTag(n)]
                }
            }
            return nil
        }
    }
    
    // MARK: - Rotation Threshold Filtering
    
    /// Parses a user-supplied rotation threshold query into a canonical month value.
    ///
    /// Accepted forms (case-insensitive, whitespace-tolerant):
    ///
    ///   No unit — bare numeral tried as months first, then as years:
    ///     "12", "24", "36"  →  treated as months (valid options win)
    ///     "1", "1.5", "2"   →  treated as years  (× 12 → months)
    ///
    ///   Year unit (year | years | yr | yr.) — numeral treated exclusively as years:
    ///     "3 years", "3 year", "3 yr.", "3 yr"  →  3 × 12 = 36 months (valid)
    ///     "36 years"                             →  36 × 12 = 432 months (nil — invalid)
    ///
    ///   Month unit (month | months | mo | mo.) — numeral treated exclusively as months:
    ///     "36 months", "36 month", "36 mo.", "36 mo"  →  36 months (valid)
    ///     "3 months"                                   →  3 months  (nil — invalid)
    ///
    ///   Any other trailing word (e.g. "36 dingus") → nil (no results).
    ///
    ///   The keywords "default", "override" and "custom" are not numeric: they test whether a
    ///   per-film override is set, and are answered by filterByRotationThreshold before this
    ///   parser is consulted.
    ///
    /// Returns nil for any input that does not map to a valid threshold value.
    private func parseRotationThresholdQuery(_ query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }

        // Patterns for recognized unit suffixes (anchored to end of string, space-separated).
        // yr\.? matches both "yr" and "yr." without a word-boundary issue on the period.
        let yearUnitPattern  = #"\s+(years?|yr\.?)$"#
        let monthUnitPattern = #"\s+(months?|mo\.?)$"#
        // Any trailing non-whitespace token that is not a whitelisted unit.
        let anyTrailingWordPattern = #"\s+\S+$"#

        let hasYearUnit  = q.range(of: yearUnitPattern,  options: .regularExpression) != nil
        let hasMonthUnit = q.range(of: monthUnitPattern, options: .regularExpression) != nil

        // If the input has a trailing word that is neither a year nor a month unit, reject it.
        let hasAnyTrailingWord = q.range(of: anyTrailingWordPattern, options: .regularExpression) != nil
        if hasAnyTrailingWord && !hasYearUnit && !hasMonthUnit {
            return nil
        }

        // Strip the recognized unit suffix (if present) to isolate the bare numeral.
        let stripped = q
            .replacingOccurrences(of: yearUnitPattern,  with: "", options: .regularExpression)
            .replacingOccurrences(of: monthUnitPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard let doubleVal = Double(stripped) else { return nil }

        if hasYearUnit {
            // Unit was explicitly years — convert to months and validate.
            let months = Int((doubleVal * 12).rounded())
            return Preferences.rotationThresholdOptions.contains(months) ? months : nil
        }

        if hasMonthUnit {
            // Unit was explicitly months — the numeral must be an exact integer match.
            let asInt = Int(doubleVal)
            guard Double(asInt) == doubleVal else { return nil }
            return Preferences.rotationThresholdOptions.contains(asInt) ? asInt : nil
        }

        // No unit supplied — try the numeral as a direct month integer first,
        // then fall back to treating it as a year fraction.
        let asInt = Int(doubleVal)
        if Double(asInt) == doubleVal && Preferences.rotationThresholdOptions.contains(asInt) {
            return asInt
        }
        let asMonthsFromYears = Int((doubleVal * 12).rounded())
        if Preferences.rotationThresholdOptions.contains(asMonthsFromYears) {
            return asMonthsFromYears
        }

        return nil
    }
    
    /// Filters films to only those whose effective rotation threshold (override or default)
    /// matches the canonical month value derived from the query string, or, for the
    /// keywords "default" / "override" / "custom", by whether a per-film override is set.
    /// An unrecognized query yields no results, consistent with the behavior of other token fields
    /// when the supplied value matches nothing.
    private func filterByRotationThreshold(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        // Keywords test whether a per-film override exists, not what the effective value is.
        // A film explicitly set to the same value as the global default still has an override.
        switch query.trimmingCharacters(in: .whitespaces).lowercased() {
        case "default":
            return films.filter { $0.rotationThresholdOverride == nil }
        case "override", "custom":
            return films.filter { $0.rotationThresholdOverride != nil }
        default:
            break
        }
        guard let targetMonths = parseRotationThresholdQuery(query) else {
            // Invalid / unrecognized value — no results, just like a misspelled title.
            return []
        }
        return films.filter { film in
            // film.rotationThreshold resolves override ?? Preferences.defaultRotationThreshold.
            film.rotationThreshold == targetMonths
        }
    }
    
    // MARK: - Fuzzy Matching
    
    /// Core fuzzy match implementation. Both text and query must be pre-lowercased.
    ///
    /// Priority order (each successful check short-circuits):
    ///   1. Exact match  — cheapest, most common for token equality
    ///   2. Prefix match — common for autocomplete-style queries
    ///   3. Substring match — the general case
    ///
    /// A separate word-start pass used to follow the substring check, but it was
    /// unreachable: `word.hasPrefix(query)` implies `text.contains(query)`, so once
    /// the substring check returns false no word can begin with the query either.
    /// The exact and prefix checks are retained purely as fast exits ahead of the
    /// (potentially O(n·m)) substring scan; each is subsumed by the substring check
    /// but avoids that scan in the common cases.
    @inline(__always)
    private func fuzzyMatchCore(_ lowercasedText: String, query lowercasedQuery: String) -> Bool {
        guard !lowercasedQuery.isEmpty, !lowercasedText.isEmpty else { return lowercasedQuery.isEmpty }
        if lowercasedText == lowercasedQuery         { return true }
        if lowercasedText.hasPrefix(lowercasedQuery) { return true }
        return lowercasedText.contains(lowercasedQuery)
    }
    
    /// Match where the query is already in `SearchText.key` form but the text is not.
    /// Normalizes the text once before delegating to the shared core.
    @inline(__always)
    private func fuzzyMatchOptimized(_ text: String, query queryKey: String) -> Bool {
        fuzzyMatchCore(SearchText.key(text), query: queryKey)
    }
    
    /// The whole minutes a film's stored `duration` represents, or 0 when it is empty,
    /// unparseable, or non-positive.
    ///
    /// `Film.duration` is a MILLISECOND count stored as a string — MetaParser writes
    /// `asset.duration.seconds * 1000`, and every reader (the sidebar's formatters, the
    /// list view's duration column, the FilmSheet's hours/minutes fields) decodes it as
    /// such through `RSBHelpers.hoursAndMinutes`. This used to read the string as a minute
    /// count instead (with a dead branch for an "H:MM:SS" form nothing ever stored), so
    /// `duration:>90` compared 5,400,000 against 90 and matched every film that had a
    /// duration at all, while `duration:<200` matched none. Going through the shared
    /// decoder keeps the search's idea of a film's length the same as the display's.
    private func parseDurationToMinutes(_ duration: String) -> Int {
        DurationHelpers.storedMinutes(duration) ?? 0
    }
}
