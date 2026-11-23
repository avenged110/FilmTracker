// MARK: - SearchController.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Uses SwiftUI's native searchable() with token support.
/// The # character triggers token entry mode which pauses filtering until Return.

import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - List Catalog

/// Every list a `#list` token can name, each with a way to resolve it to its films.
/// Built by DataCoordinator.searchListCatalog(). A list's films are resolved only when a
/// token names it, so building the catalog costs no membership work.
struct SearchListCatalog {
    /// Where a list comes from, in the order the suggestion list groups them.
    enum Kind: Int {
        case report, recents, smart, queue, saved, user
    }
    struct Entry {
        let name: String
        let kind: Kind
        /// Other full names the list answers to. Matched like the name, never suggested.
        var aliases: [String] = []
        let filmIDs: () -> Set<UUID>
    }
    let entries: [Entry]
}

// MARK: - Search Controller
@MainActor
@Observable
final class SearchController: Loggable {
    nonisolated static let logTag = "[SearchCon]"
    
    static let shared = SearchController()
    init() {
        /// Recent searches are kept only while both settings allow them. Watching the
        /// defaults catches every way a setting turns off — the checkbox, a restore — so
        /// the list is dropped, not merely hidden, the moment it is no longer allowed.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.recentSearchesEnabled && !self.recentSearches.isEmpty { self.recentSearches = [] }
                if !Preferences.showSearchSuggestions {
                    /// The ranking in flight too, or it would publish its rows after the clear.
                    self.suggestionTask = nil
                    if !self.valueSuggestions.isEmpty { self.valueSuggestions = [] }
                }
            }
        }
        /// The focus guard watches each search window's first responder from when it first
        /// becomes key. See "Search Field Focus Guard".
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.watchFieldFocus(in: window) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.firstResponderObservations[ObjectIdentifier(window)] = nil
            }
        }
        /// A click anywhere in the toolbar may be the user reaching for the field, by way of
        /// its collapsed button too, which focuses the field a beat after the click. Never
        /// consumes the event.
        toolbarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if Self.isInSearchToolbar(event) { SearchController.shared.allowFieldFocus() }
            return event
        }
    }
    
    // MARK: - Published State (Bound to .searchable())
    
    /// The text currently in the search field (bound to .searchable())
    var searchText: String = "" {
        didSet {
            guard !isClearing else { return }
            refreshSuggestions()
            updateTokenEntryState()
            /// Trigger search with minimal delay for text changes
            if !isEnteringToken {
                triggerSearchWithDebounce()
            }
        }
    }
    
    /// The tokens the user has selected/confirmed (bound to .searchable())
    var currentTokens: [SearchToken] = [] {
        didSet {
            guard !isClearing else { return }
            /// `.searchable` writes the tokens back, unchanged, on every keystroke (ahead of
            /// the text). Read as a token change, that write canceled the text debounce and
            /// ran a search at once with the previous keystroke's text — a full reload that
            /// skipped tokenResultCache, re-running every token per keystroke whenever keys
            /// came faster than the debounce. Only a real change searches.
            guard currentTokens != oldValue else { return }
            /// A pill removed while a "#" token is being typed takes effect at once. The
            /// paused results otherwise kept filtering by the removed token, and because the
            /// query string already matched, leaving token entry never reloaded them.
            if isEnteringToken { lastConfirmedTokens = currentTokens }
            /// Immediately trigger search when tokens change
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

    /// The search the results show: the field's own, or during token entry (filtering
    /// paused) the last confirmed one. filterFilms, currentSearchMatches and dependsOnLists
    /// all read it, so they cannot disagree about which search is on screen.
    private var shownSearch: (tokens: [SearchToken], text: String) {
        isActive ? (currentTokens, getCleanSearchText()) : (lastConfirmedTokens, lastConfirmedText)
    }

    /// The first token is being typed into a field that held nothing else: "#" typed with no
    /// pill and no text (or only punctuation, which narrows nothing) before it. The paused
    /// results are then the whole library, so the gallery is covered by the "Enter Search
    /// Token" placeholder. Once a pill or text has narrowed the results, token entry keeps
    /// showing them instead. Read through the paused search, which is what the gallery shows.
    var isEnteringFirstToken: Bool {
        isEnteringToken && lastConfirmedTokens.isEmpty && SearchText.key(lastConfirmedText).isEmpty
    }

    /// Whether the results on screen depend on list membership: the search filtering them
    /// has a #list token. A #list token can name a user list, a smart list, the Film Queue,
    /// a report or a saved search, so a membership change made beside the results can add
    /// films to them or remove films from them.
    var dependsOnLists: Bool {
        hasContent && shownSearch.tokens.contains { $0.field == .list }
    }
    
    // MARK: - Private State

    /// Set to true during clearSearch() to suppress didSet observers on searchText
    /// and currentTokens from triggering redundant search executions while the clear
    /// is in progress. Both properties are reset atomically; the flag is cleared last.
    private var isClearing: Bool = false

    /// Debounce handle for text-change searches. Replaces the previous Timer-based
    /// approach: canceling and re-creating a Task is cleaner than Timer.invalidate()
    /// because it keeps everything within structured concurrency (no run-loop dependency),
    /// and TaskHandle's deinit guarantees cancellation if SearchController is deallocated.
    private var searchDebounceHandle: TaskHandle?
    
    /// When set, getCleanSearchText() returns this value instead of stripping the live
    /// searchText. Used during processSearchSubmission() so that the triggerSearch()
    /// fired by addToken() → currentTokens.didSet uses the post-commit clean text
    /// (beforeHash) rather than the still-present in-progress token string. This
    /// prevents the residual value portion of the token text (e.g. "producer d" from
    /// "#/executive producer d") from being passed into applyFilters as spurious
    /// freeform text, which would briefly zero out films and flash the placeholder.
    private var pendingCleanText: String? = nil
    
    /// Set by the text debounce for the one reload it starts, and consumed by filterFilms:
    /// only the freeform text changed, so the cached token results still hold.
    private var isTextOnlyReload = false
    
    /// The result of the token steps for the last token set, reused across keystrokes.
    private struct TokenResultCache {
        let tokens: [SearchToken]
        let inputCount: Int
        let ids: Set<UUID>
    }
    private var tokenResultCache: TokenResultCache?
    
    // MARK: - Token Entry State
    
    /// Update token entry state based on search text.
    /// When # is present and not yet confirmed, we're in token entry mode.
    private func updateTokenEntryState() {
        let wasEnteringToken = isEnteringToken
        
        /// Check if we have an unconfirmed # pattern
        isEnteringToken = searchText.contains("#")
        /// Kept in step here too: triggerSearch() does not run during token entry, so a
        /// reload in that window otherwise read a stale `isActive` and filtered by the
        /// half-typed token's value instead of holding the last confirmed results.
        updateActivity()

        /// When starting token entry, save current state
        if isEnteringToken && !wasEnteringToken {
            lastConfirmedTokens = currentTokens
            /// Trimmed, as the active path's text is: typing "#" after freeform text leaves
            /// the separating space behind ("matrix #" → "matrix "), which once matched
            /// nothing and collapsed the paused results to zero films.
            lastConfirmedText = Self.freeformText(searchText)
            Self.log("Entering token mode - filtering paused")
        }
    }
    
    /// Derives `hasContent` (any text or pill: the search view shows) and `isActive` (that,
    /// outside token entry: the field's search filters) from the field and isEnteringToken.
    private func updateActivity() {
        hasContent = !searchText.isEmpty || !currentTokens.isEmpty
        isActive = hasContent && !isEnteringToken
    }

    // MARK: - In-Progress "#" Fragment
    
    /// The parsed shape of the in-progress "#…" fragment at the tail of `searchText`.
    ///
    /// Parsing happens once here, so the hash index, the "/" (OR) and "!" (inversion)
    /// prefixes, and the partial field name cannot drift apart, and the fragment's grammar
    /// is readable in a single place.
    private struct HashFragment {
        /// Everything before the "#".
        let beforeHash: String
        /// A "/" prefix was typed after the "#" (OR mode).
        let isOr: Bool
        /// A "!" prefix was typed after the optional "/" (inverted mode).
        let isInverted: Bool
        /// The field-name text typed after the prefixes, whitespace-trimmed.
        let partial: String
        /// A space follows the field name — the user has moved on to entering a value.
        let hasValue: Bool

        /// The fragment rewritten to name `field` by its first alias, with the typed OR and
        /// inversion prefixes kept, then `value` ("" leaves it ready for one).
        func text(naming field: SearchField, value: String = "") -> String {
            beforeHash + "#" + SearchToken.prefix(isOr: isOr, isInverted: isInverted)
                + (field.aliases.first ?? field.rawValue) + " " + value
        }
    }
    
    /// Parses the fragment following the last "#" in `searchText`, or nil if there is none.
    private var hashFragment: HashFragment? {
        guard let hashIndex = searchText.lastIndex(of: "#") else { return nil }
        let beforeHash = String(searchText[..<hashIndex])
        /// Spaces before the field name, or after either prefix, are skipped: only a space
        /// after the name starts the value. Counting the stray one in "# " or "#/ dir" as
        /// that space hid the field suggestions and left Return nothing to commit.
        var rest = searchText[searchText.index(after: hashIndex)...].drop(while: \.isWhitespace)
        let isOr = rest.first == "/"
        if isOr { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        let isInverted = rest.first == "!"
        if isInverted { rest = rest.dropFirst().drop(while: \.isWhitespace) }

        return HashFragment(
            beforeHash: beforeHash,
            isOr: isOr,
            isInverted: isInverted,
            partial: rest.trimmingCharacters(in: .whitespaces),
            hasValue: rest.contains(" ")
        )
    }
    
    // MARK: - Suggested Fields for Current Input
    
    /// Get fields that match current partial input after #.
    /// Returns nothing once a value is being entered — field suggestions no longer apply.
    func getSuggestedFields() -> [SearchField] {
        guard let fragment = hashFragment, !fragment.hasValue else { return [] }
        let partial = fragment.partial
        
        /// Filter fields based on partial match
        if partial.isEmpty {
            return SearchField.allCases
        }
        
        /// Lowercase the partial once instead of re-deriving it for every field — and for
        /// every alias inside the inner closure — on each keystroke. Aliases are already
        /// stored lowercased, so only the partial and the per-field displayName need folding.
        let lowerPartial = partial.lowercased()
        return SearchField.allCases.filter { field in
            field.displayName.lowercased().hasPrefix(lowerPartial) ||
            field.aliases.contains { $0.hasPrefix(lowerPartial) }
        }
    }
    
    /// Commits a token for `field` with `value` exactly, keeping the typed OR and inversion
    /// prefixes. The same path as pressing Return, so it leaves the field in the same state.
    private func insertTokenValue(_ field: SearchField, value: String) {
        guard let fragment = hashFragment else { return }
        searchText = fragment.text(naming: field, value: value)
        processSearchSubmission()
    }
    
    /// Check if inverted mode is active (! after #)
    var isInvertedMode: Bool { hashFragment?.isInverted ?? false }
    
    /// Check if OR mode is active (/ after #)
    var isOrMode: Bool { hashFragment?.isOr ?? false }
    
    /// Insert a field into the search text, replacing partial input
    func insertField(_ field: SearchField) {
        guard let fragment = hashFragment else { return }
        /// Replace with field name and add space for value entry
        searchText = fragment.text(naming: field)
        Self.log("Inserted field: \(field.displayName)")
    }
    
    /// Add a token with a value. Only reached via processSearchSubmission().
    private func addToken(field: SearchField, value: String, isInverted: Bool = false, isOr: Bool = false) {
        let token = SearchToken(field: field, value: value, isInverted: isInverted, isOr: isOr)
        
        if !currentTokens.contains(token) {
            currentTokens.append(token)
            Self.log("Added token: \(token.displayName)")
        }
        /// A committed token is a deliberate choice, so its value is learned at once,
        /// whatever its prefixes.
        recordHeuristic(value, scope: field.rawValue)
    }
    
    /// Process search text on submission to extract tokens.
    /// Called when user presses Return in the search field.
    func processSearchSubmission() {
        /// If no # present, just trigger search if we have content
        guard let fragment = hashFragment else {
            if hasContent {
                triggerSearchImmediate()
            }
            return
        }
        
        /// Need a "field value" pattern; an incomplete one makes no token. The field and
        /// value are resolved as the value suggestions resolve them, so Return commits the
        /// field the suggestions were offered for. The OR ("/") and inversion ("!")
        /// prefixes are hashFragment's, the same parse insertField reads.
        guard let (field, typed) = tokenValueInput(), !typed.isEmpty else { return }
        /// An Is or Release token stays open for a comma and the next term, so it is often
        /// committed with a comma left over ("owned,"). The pill shows the terms as they are
        /// read: empty ones dropped, one comma and a space between the rest.
        let value = field == .flags || field == .releases ? FilmFlag.normalizedTerms(typed) : typed
        let isOr = fragment.isOr
        let isInverted = fragment.isInverted

        /// Compute the clean text that will remain after the # pattern is stripped.
        /// Set pendingCleanText before addToken() so that getCleanSearchText() —
        /// called inside triggerSearch() → getCurrentQuery() → applyFilters() —
        /// uses the post-commit value rather than the live searchText which still
        /// holds the full in-progress token string (e.g. "#/executive producer d").
        /// Without this, the residual value portion after the field name space
        /// ("producer d") leaks into the freeform filter pass, briefly zeroing
        /// films and flashing the placeholder before the correct results arrive.
        let beforeHash = fragment.beforeHash.trimmingCharacters(in: .whitespaces)
        pendingCleanText = beforeHash
        
        /// Exit token entry mode before adding token
        /// This ensures when currentTokens.didSet triggers and calls triggerSearch(),
        /// the isActive check will pass because isEnteringToken is already false
        isEnteringToken = false
        
        /// Now add token - when didSet fires, isActive will become true.
        /// getCleanSearchText() returns pendingCleanText (beforeHash) for this call.
        addToken(field: field, value: value, isInverted: isInverted, isOr: isOr)
        
        /// Commit complete — clear the override before assigning searchText so that
        /// the searchText.didSet path uses normal text stripping going forward.
        pendingCleanText = nil
        
        /// Clear the # pattern from search text
        searchText = beforeHash
        /// The token is chosen; suggestions for the text left beside it wait for an edit.
        suppressSuggestions()
        
        Self.log("Confirmed token: \(field.displayName): \(value) (inverted=\(isInverted), or=\(isOr))")
    }
    
    // MARK: - Search Execution
    
    private func triggerSearchWithDebounce() {
        /// Cancel any in-flight debounce task and start a fresh one.
        /// TaskHandle's deinit cancels the underlying Task when the handle is replaced,
        /// providing the same invalidation guarantee as Timer.invalidate() without
        /// requiring a run-loop or crossing concurrency domains.
        searchDebounceHandle = TaskHandle(Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return /// Canceled — a newer keystroke superseded this one.
            }
            isTextOnlyReload = true
            triggerSearch()
            isTextOnlyReload = false
        })
    }
    
    /// Trigger search immediately without debounce (used for token changes)
    private func triggerSearchImmediate() {
        searchDebounceHandle = nil /// Cancel any pending debounced search.
        triggerSearch()
    }
    
    private func triggerSearch() {
        /// Derived again here: updateTokenEntryState() runs only from searchText.didSet,
        /// so a pill removed with the text unchanged would otherwise leave hasContent and
        /// isActive stale. This is the common tail of the text and token paths.
        updateActivity()
        
        Self.log("triggerSearch: hasContent=\(hasContent), isEnteringToken=\(isEnteringToken), isActive=\(isActive)")
        
        let query = getCurrentQuery()
        
        /// Update ViewStateManager synchronously (both are @MainActor singletons).
        /// This eliminates the one-run-loop async gap that the event bus's
        /// .receive(on: RunLoop.main) subscriber introduced, which was the root
        /// cause of the spinner appearing during OR-token searches: loadFilms()
        /// was deferred one cycle, leaving a window where films=[] and
        /// searchQuery="" simultaneously satisfied the shouldShowLoading condition.
        /// The AppEventBus path for searchQueryChanged has been removed: the direct
        /// synchronous call here is the canonical and only update path.
        ViewStateManager.shared.updateSearchQuery(query)
        
        if isActive {
            scheduleSettle()
        } else if !hasContent {
            /// The field was emptied by hand: the search it held has ended.
            commitSearch()
        }
    }
    
    // MARK: - Suggestions
    
    /// The data the value suggestions draw on. Set by the search field's view.
    weak var suggestionSource: DataCoordinator?
    
    /// The ranked value suggestions for what the field holds, computed off the main actor.
    private(set) var valueSuggestions: [SearchSuggestion] = []
    
    /// The session's recent searches, newest first. Never written to disk.
    private(set) var recentSearches: [RecentSearch] = []
    
    /// A search as the user left it: its pills and its freeform text — the same two things a
    /// saved search keeps, so the same type (whose `label` the drop-down shows).
    typealias RecentSearch = SavedSearchQuery
    
    static var recentSearchesEnabled: Bool {
        Preferences.showSearchSuggestions && Preferences.showRecentSearches
    }
    
    private var suggestionTask: TaskHandle?
    /// The field the last request was for (nil: freeform), so a change of field clears the
    /// old rows at once instead of leaving them up until the new ones arrive. Whenever no
    /// request is made the rows are cleared outright, so nil needs no "none" state of its own.
    private var lastSuggestionField: SearchField?
    /// After a suggestion is picked, the text it left: no suggestions until it is edited.
    private var suppressedSuggestionText: String?
    
    private var vocabulary = SearchVocabulary.empty
    /// The films version `vocabulary` was (or is being) built from. A version rather than the
    /// films map itself: holding the map kept a whole stale copy of the library alive after
    /// the next edit, and made that edit copy the full dictionary.
    private var vocabularyFilmsVersion: UInt64?
    /// The Queue and the day the vocabulary's affinities were computed for: either
    /// changing changes them, though no film does.
    private var vocabularyQueue: Set<UUID> = []
    private var vocabularyDay: Date?
    private var vocabularyTask: TaskHandle?
    /// A build is under way (updateVocabulary), and rankedValues callers waiting on the
    /// first one. Callers wait only while there is no vocabulary at all yet.
    private var isVocabularyBuilding = false
    @ObservationIgnored private var vocabularyWaiters: [CheckedContinuation<Void, Never>] = []
    
    /// The search in progress once it has held still for `settleDelay`: what a recent
    /// search and the freeform heuristics record when the search ends. Waiting for it to
    /// settle keeps every keystroke of a word, and every step of deleting it, out of both.
    private var settledSearch: RecentSearch?
    /// The search in progress the last time it was active, settled or not.
    private var lastActiveSearch: RecentSearch?
    private var settleHandle: TaskHandle?
    private static let settleDelay: Duration = .milliseconds(1500)
    
    /// Recomputes the value suggestions for the field's current text.
    private func refreshSuggestions() {
        suggestionTask = nil
        if let suppressed = suppressedSuggestionText {
            if suppressed == searchText {
                valueSuggestions = []
                return
            }
            suppressedSuggestionText = nil
        }
        guard Preferences.showSearchSuggestions, let source = suggestionSource,
              let (field, typed) = suggestionInput() else {
            valueSuggestions = []
            lastSuggestionField = nil
            return
        }
        if lastSuggestionField != field {
            valueSuggestions = []
            lastSuggestionField = field
        }
        updateVocabulary(from: source)
        
        let request = SearchSuggestionRequest(
            field: field, typed: typed,
            lists: field == .list ? source.searchListCatalog().entries.map { ($0.name, $0.kind) } : [],
            context: suggestionContext(),
            focus: currentFocus())
        let vocabulary = self.vocabulary
        let scope = field?.rawValue ?? SearchHeuristics.titleScope
        suggestionTask = TaskHandle(Task { [weak self] in
            let learned = await SearchHeuristics.shared.learned(scope: scope, typed: typed)
            /// A detached task does not inherit cancellation, so it is forwarded by hand.
            let work = Task.detached(priority: .userInitiated) {
                SearchSuggestionRanker.rank(request, vocabulary: vocabulary, learned: learned,
                                            limit: SearchSuggestionLimits.menuRows)
            }
            let ranked = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.valueSuggestions = ranked
        })
    }
    
    /// The field a value is being typed for (nil for freeform text) and the value so far,
    /// or nil when there is nothing to suggest values for: a "#" fragment still naming its
    /// field, or one whose field is not recognized. Resolves the field as Return does, a
    /// two-word display name ("last watched") first.
    private func suggestionInput() -> (SearchField?, String)? {
        guard hashFragment != nil else {
            let text = searchText.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (nil, text)
        }
        guard let (field, value) = tokenValueInput() else { return nil }
        /// An Is or Release value is suggested for one term at a time: the one after the
        /// last comma.
        if field == .flags || field == .releases { return (field, FilmFlag.splitLast(value).term) }
        return (field, value)
    }

    /// The field and value text of the "#" fragment being typed ("" while no value follows
    /// the field yet), or nil while it still names its field or names none. The one parse
    /// of a fragment's field and value: Return (processSearchSubmission) and the value
    /// suggestions both read it, so they cannot disagree about which field is meant.
    ///
    /// The field name may span more than one word. Every alias is one unspaced word
    /// ("executiveproducer", "userrating"), but the names the user sees include two-word
    /// display names ("Executive Producer", "Last Watched"), so the words are run together
    /// shortest-first until they spell an alias. The first match wins, even with no value
    /// after it.
    ///
    /// A two-word display name is tried first, though. Two of them begin with a word that
    /// is an alias on its own — "date" (Year) and "rotation" — so shortest-first read
    /// "#date added 2020" as a Year token with the value "added 2020", and "#date added"
    /// alone as a Year token with the value "added".
    private func tokenValueInput() -> (SearchField, String)? {
        guard let fragment = hashFragment, fragment.hasValue else { return nil }
        let words = fragment.partial.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        func value(after count: Int) -> String { words.dropFirst(count).joined(separator: " ") }
        if words.count > 1, let field = SearchField.from(twoWordName: words[0] + words[1]) {
            return (field, value(after: 2))
        }
        for count in 1...words.count {
            if let field = SearchField.from(alias: words[..<count].joined()) {
                return (field, value(after: count))
            }
        }
        return nil
    }
    
    /// Starts rebuilding the vocabulary off the main actor when the library has changed
    /// since it was built. Suggestions use the previous vocabulary until it is ready.
    private func updateVocabulary(from source: DataCoordinator) {
        let filmsVersion = source.filmsVersion
        let queued = source.getFilmQueueFilmIDs()
        let today = AppCalendar.current.startOfDay(for: Date())
        guard vocabularyFilmsVersion != filmsVersion || vocabularyQueue != queued || vocabularyDay != today else { return }
        let films = source.getAllFilmsMap()
        vocabularyFilmsVersion = filmsVersion
        vocabularyQueue = queued
        vocabularyDay = today
        isVocabularyBuilding = true
        vocabularyTask = TaskHandle(Task { [weak self] in
            /// Forwarded by hand, as a detached task does not inherit cancellation: a
            /// superseded build stops at SearchVocabulary.init's cancellation check.
            let work = Task.detached(priority: .utility) {
                SearchVocabulary(films: films, queued: queued, today: today)
            }
            let built = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.vocabulary = built
            self.isVocabularyBuilding = false
            let waiters = self.vocabularyWaiters
            self.vocabularyWaiters = []
            for waiter in waiters { waiter.resume() }
            self.refreshSuggestions()
        })
    }

    /// Value suggestions for `field` outside the search field — the saved-search sheet's text
    /// rules (SSSheet's RuleTextField): the search field's own vocabulary and ranking, so the
    /// two offer the same values in the same order, but with no pills or recent searches to
    /// relate to. Empty while search suggestions are turned off.
    func rankedValues(for field: SearchField, typed: String, limit: Int) async -> [String] {
        guard Preferences.showSearchSuggestions, let source = suggestionSource else { return [] }
        updateVocabulary(from: source)
        /// The first request can come before anything has been built: wait for it, rather
        /// than answer the first keystroke with nothing.
        if isVocabularyBuilding, vocabulary.isEmpty {
            await withCheckedContinuation { vocabularyWaiters.append($0) }
        }
        guard !Task.isCancelled else { return [] }
        let request = SearchSuggestionRequest(
            field: field, typed: typed,
            lists: field == .list ? source.searchListCatalog().entries.map { ($0.name, $0.kind) } : [],
            context: SearchContext())
        let vocabulary = self.vocabulary
        let learned = await SearchHeuristics.shared.learned(scope: field.rawValue, typed: typed)
        let work = Task.detached(priority: .userInitiated) {
            SearchSuggestionRanker.rank(request, vocabulary: vocabulary, learned: learned, limit: limit)
        }
        let ranked = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        return ranked.map(\.value)
    }
    
    /// What the suggestions should relate to: the pills in the field at full weight, the
    /// freeform text beside them (when a token's value is being typed) a little less, and
    /// this session's recent searches less again, each older one 0.6 of the one after it.
    /// Recent searches inform this only while they are being kept (recentSearchesEnabled).
    private func suggestionContext() -> SearchContext {
        var context = SearchContext()
        func add(_ tokens: [SearchToken], text: String, weight: Double) {
            /// An inverted pill names what the user does not want; it relates nothing.
            for token in tokens where !token.isInverted {
                context.values.append(.init(field: token.field, key: SearchText.key(token.value), weight: weight))
            }
            let key = SearchText.key(text)
            if !key.isEmpty { context.values.append(.init(field: nil, key: key, weight: weight * 0.8)) }
        }
        add(currentTokens, text: hashFragment?.beforeHash ?? "", weight: 1)
        for token in currentTokens where !token.isInverted {
            context.present[token.field, default: []].insert(SearchText.key(token.value))
        }
        var weight = 0.5
        for recent in recentSearches {
            add(recent.tokens, text: recent.text, weight: weight)
            weight *= 0.6
        }
        return context
    }
    
    /// Applies a picked value suggestion: commits the token, or puts the title in the field.
    /// The pick teaches the heuristics what was typed for it and which rows were passed over.
    func applySuggestion(_ suggestion: SearchSuggestion) {
        defer { suppressSuggestions() }
        learnPick(suggestion)
        guard let field = suggestion.field else {
            typedBeforeTitlePick = getCleanSearchText()
            searchText = suggestion.value
            recordHeuristic(suggestion.value, scope: SearchHeuristics.titleScope)
            return
        }
        /// An Is or Release value holds comma-separated terms, and its suggestions are for
        /// the term being typed (suggestionInput). A pick completes that term, keeping the
        /// finished terms before it and the "!" typed ahead of it — unless the picked value
        /// carries its own (a learned "!4k"), which would otherwise cancel it out.
        var value = suggestion.value
        if field == .flags || field == .releases, let (_, typed) = tokenValueInput() {
            value = FilmFlag.completing(typed, with: value)
        }
        /// An Is term is one test of the film, so the token stays open for a comma and the
        /// next; Return commits it. Anything else, a Release value included (its terms all
        /// describe one release), is committed at once.
        if field == .flags, let fragment = hashFragment {
            searchText = fragment.text(naming: .flags, value: value)
        } else {
            insertTokenValue(field, value: value)
        }
    }
    
    /// Restores a recent search exactly as it was left.
    /// The text goes in first: the token change that follows cancels its debounce and runs
    /// one search with both, where the other order searched the new tokens with the old text.
    /// Pills the field already holds are no change, so that one search is started here.
    func applyRecentSearch(_ recent: RecentSearch) {
        editingSavedSearchID = nil
        let tokensChange = currentTokens != recent.tokens
        searchText = recent.text
        currentTokens = recent.tokens
        if !tokensChange { triggerSearchImmediate() }
        suppressSuggestions()
    }
    
    /// Teaches the heuristics a picked row: the text typed for it, and the rows shown above it
    /// (up to five) as passed over. List rows are left out: their order is by group first.
    private func learnPick(_ suggestion: SearchSuggestion) {
        guard Preferences.showSearchSuggestions, suggestion.field != .list,
              let (_, typed) = suggestionInput() else { return }
        let scope = suggestion.field?.rawValue ?? SearchHeuristics.titleScope
        let index = valueSuggestions.firstIndex(of: suggestion) ?? 0
        let above = valueSuggestions[..<index].suffix(5).map(\.value)
        Task(priority: .background) {
            await SearchHeuristics.shared.recordInput(typed, value: suggestion.value, scope: scope)
            await SearchHeuristics.shared.recordSkips(Array(above), scope: scope)
        }
    }

    // MARK: - Film Use

    /// The freeform text typed by hand before a title suggestion replaced it, for the input
    /// history of a film then opened. Cleared when the search ends.
    private var typedBeforeTitlePick: String?
    private var selectionDwell: TaskHandle?
    /// The single film last selected, so a selection set again unchanged (a reload) is not
    /// counted twice.
    private var lastSelectedFilm: UUID?
    private static let selectionDwellDelay: Duration = .seconds(2)

    /// The view the search was started from: the last view other than search itself.
    private var originView: ViewIdentifier?

    /// A selection changed (SelectionState). One film that stays selected for
    /// `selectionDwellDelay` was looked at, not passed over on the way to another.
    func noteSelection(_ ids: Set<UUID>) {
        let single = ids.count == 1 ? ids.first : nil
        guard single != lastSelectedFilm else { return }
        lastSelectedFilm = single
        guard let id = single, Preferences.showSearchSuggestions else {
            selectionDwell = nil
            return
        }
        selectionDwell = TaskHandle(Task { [weak self] in
            do { try await Task.sleep(for: Self.selectionDwellDelay) } catch { return }
            guard let self, SelectionState.shared.untrackedSelectedFilmIDs == [id] else { return }
            self.creditFilm(id, amount: 0.25)
        })
    }

    /// A film's sheet was opened to edit it.
    func noteFilmSheetOpened(_ id: UUID) {
        creditFilm(id, amount: 0.5)
    }

    /// Teaches the heuristics a use of the film. Found through a search with freeform text, it
    /// counts in full and also as what that text was typed for; otherwise `amount`.
    private func creditFilm(_ id: UUID, amount: Double) {
        guard Preferences.showSearchSuggestions, let title = suggestionSource?.getFilm(id)?.name else { return }
        let typed = isActive && hasContent ? (typedBeforeTitlePick ?? getCleanSearchText()) : ""
        let scope = SearchHeuristics.titleScope
        Task(priority: .background) {
            await SearchHeuristics.shared.record(title, scope: scope, amount: typed.isEmpty ? amount : 1)
            if !typed.isEmpty { await SearchHeuristics.shared.recordInput(typed, value: title, scope: scope) }
        }
    }

    /// What the view the search started from says about the films wanted (SearchFocus).
    private func currentFocus() -> SearchFocus {
        let active = ViewStateManager.shared.activeView
        if !active.isSearch { originView = active }
        switch originView {
        case .filmQueue?:
            return .queue
        case .smartList(let type)?:
            switch type {
            case .upcomingReleases, .purchased, .purchased4K, .purchasedBluray, .purchasedDVD,
                 .unpurchased, .unpurchased4K, .unpurchasedBluray, .unpurchasedDVD:
                return .releases
            default:
                return .none
            }
        case .tag(let tag)?:
            return .tag(tag.key)
        default:
            return .none
        }
    }

    /// Hides the value suggestions until the field's text is next edited.
    private func suppressSuggestions() {
        suggestionTask = nil
        valueSuggestions = []
        suppressedSuggestionText = searchText
    }
    
    /// Notes the search in progress, once it holds still, as the one to record when it ends.
    private func scheduleSettle() {
        let state = currentQuery
        lastActiveSearch = state
        settleHandle = TaskHandle(Task { [weak self] in
            do { try await Task.sleep(for: Self.settleDelay) } catch { return }
            self?.settledSearch = state
        })
    }
    
    /// Records the search that just ended as a recent search. A search being left with content in the field is recorded as it stands.
    /// One the user emptied by hand is recorded as it last stood, unless that was partway
    /// through taking it apart — some of the settled search's pills, and text that the
    /// settled text starts with — in which case it is recorded as it last settled.
    private func commitSearch() {
        settleHandle = nil
        defer { settledSearch = nil; lastActiveSearch = nil; typedBeforeTitlePick = nil; originView = nil }
        let search: RecentSearch
        if isActive && hasContent {
            search = currentQuery
        } else if let last = lastActiveSearch {
            if let settled = settledSearch, last.tokens.allSatisfy(settled.tokens.contains),
               settled.text.hasPrefix(last.text) {
                search = settled
            } else {
                search = last
            }
        } else {
            return
        }
        guard !search.tokens.isEmpty || !search.text.isEmpty else { return }
        
        if Self.recentSearchesEnabled {
            recentSearches.removeAll { $0 == search }
            recentSearches.insert(search, at: 0)
            if recentSearches.count > SearchSuggestionLimits.recentSearches {
                recentSearches.removeLast(recentSearches.count - SearchSuggestionLimits.recentSearches)
            }
        }
        /// The freeform text is not learned as typed: a search left at "man on fir" says
        /// nothing. The film it led to is learned instead, when one is opened (creditFilm).
    }
    
    /// Teaches the heuristics one use of `value`, at background priority. Nothing is
    /// learned (or loaded) while suggestions are off.
    private func recordHeuristic(_ value: String, scope: String) {
        guard Preferences.showSearchSuggestions else { return }
        Task(priority: .background) {
            await SearchHeuristics.shared.record(value, scope: scope)
        }
    }
    
    // MARK: - Clear/Reset
    
    /// Returns every piece of search state to its empty baseline.
    ///
    /// `searchText` and `currentTokens` are reset under `isClearing`, which suppresses
    /// their didSet observers so neither the text debounce path nor the token
    /// immediate-search path fires mid-reset; the derived flags are then derived again
    /// (both false). The search being left is recorded first (commitSearch).
    func clearSearch() {
        commitSearch()
        isClearing = true
        searchText = ""
        currentTokens = []
        isClearing = false
        
        searchDebounceHandle = nil /// Cancel any pending debounced search.
        isEnteringToken = false
        updateActivity()
        lastConfirmedTokens = []
        lastConfirmedText = ""
        pendingCleanText = nil
        tokenResultCache = nil
        settleHandle = nil
        suggestionTask = nil
        suppressedSuggestionText = nil
        valueSuggestions = []
        editingSavedSearchID = nil
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
        /// Clear every piece of prior search state before installing the new token.
        clearSearch()

        /// Assign the token directly. The didSet on currentTokens (isClearing is false
        /// here) calls triggerSearchImmediate() → triggerSearch(), which derives hasContent
        /// and isActive from the new token (both true, since clearSearch left no "#" text)
        /// and dispatches the query to ViewStateManager immediately.
        let token = SearchToken(field: field, value: value, isInverted: false, isOr: false)
        currentTokens = [token]

        Self.log("Programmatic token search: \(field.displayName) = \"\(value)\"")
    }
    
    // MARK: - Empty-Field Menu Hold

    /// True from leaving search with the keyboard elsewhere until the field next gains focus.
    /// Leaving search empties the field, and an empty field's drop-down (saved and recent
    /// searches) opens the moment it has rows — while SwiftUI's focus state, updated a beat
    /// late, still reports the field focused. Holding those rows closes that window.
    private(set) var isEmptyFieldMenuHeld = false

    /// Called as leaving search clears the field. Holds the menu only when the keyboard is
    /// really elsewhere: deleting the last character also leaves search, with the field
    /// still focused, and there the menu should behave as it always has.
    func holdEmptyFieldMenuIfUnfocused() {
        isEmptyFieldMenuHeld = !Self.searchFieldHoldsKeyboard
    }

    func releaseEmptyFieldMenu() {
        if isEmptyFieldMenuHeld { isEmptyFieldMenuHeld = false }
    }

    // MARK: - Search Field Focus Guard

    /// The search field takes focus only when the user asks for it: a click on the field (or
    /// its collapsed toolbar button), Search ▸ Search Film Library, ⌘F, or Tab. Otherwise
    /// AppKit and SwiftUI hand it focus whenever focus has nowhere else to go — after a
    /// popover or sheet closes over a page with no focusable view of its own (Insights, the
    /// summaries), the field is the window's first key view. Each search window's first
    /// responder is watched, and focus the user did not ask for is moved to the window's
    /// focus sink (MainWindowFocusSink) instead. The sink takes it, so the hand-off cannot
    /// bounce straight back the way giving focus to no view at all would.
    ///
    /// The guard only ever turns away focus arriving unasked. Focus the user gave the field
    /// is theirs (isFieldFocusOwned) until it settles somewhere else, so AppKit seating the
    /// field's editor again — as it does while the window resizes and the toolbar lays out —
    /// is never mistaken for focus arriving.
    @ObservationIgnored private var firstResponderObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var fieldFocusAllowedUntil: ContinuousClock.Instant?
    @ObservationIgnored private var toolbarClickMonitor: Any?
    /// The user gave the field focus, and it has not since settled elsewhere.
    @ObservationIgnored private var isFieldFocusOwned = false
    /// Waits to see whether focus that left the field stays gone. See focusLeftField.
    @ObservationIgnored private var focusLossTask: Task<Void, Never>?
    /// The main window's invisible focus holder, registered by MainWindowFocusSink.
    @ObservationIgnored weak var focusSink: NSView?

    /// How long focus must stay off the field, with no resize under way, before the field
    /// counts as left. Long enough to span the editor being seated again.
    private static let focusLossSettleDelay: Duration = .milliseconds(300)

    /// Lets the field take focus during the next second: long enough for a focus change
    /// that SwiftUI or AppKit carries out a beat after the click or command that asked.
    func allowFieldFocus() {
        fieldFocusAllowedUntil = .now + .seconds(1)
    }

    /// Starts watching `window`, once. Called as a window becomes key, and by the sink.
    func watchFieldFocus(in window: NSWindow?) {
        guard let window, Self.searchItem(in: window) != nil else { return }
        let id = ObjectIdentifier(window)
        guard firstResponderObservations[id] == nil else { return }
        firstResponderObservations[id] = window.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                SearchController.shared.firstResponderChanged(windowNumber: window.windowNumber)
            }
        }
    }

    private func firstResponderChanged(windowNumber: Int) {
        guard let window = NSApp.window(withWindowNumber: windowNumber) else { return }
        guard fieldHasFocus(in: window) else {
            focusLeftField(window)
            return
        }
        focusLossTask?.cancel()
        focusLossTask = nil
        if isFieldFocusOwned { return }
        if isFieldFocusAllowed { isFieldFocusOwned = true; return }
        /// Not from inside the change being reported: AppKit is still seating the field's
        /// editor. A run-loop block still runs before this pass draws, so the field never
        /// shows its focus.
        RunLoop.main.perform {
            MainActor.assumeIsolated { SearchController.shared.redirectFieldFocus(windowNumber: windowNumber) }
        }
    }

    /// Focus moved off the field. Another view taking it ends the user's hold on the field at
    /// once. The window itself holding it (no view focused) is also what AppKit passes through
    /// while seating the field's editor again, so that ends the hold only once it has lasted,
    /// outside a live resize.
    private func focusLeftField(_ window: NSWindow) {
        guard isFieldFocusOwned else { return }
        if let responder = window.firstResponder, responder !== window {
            focusLossTask?.cancel()
            focusLossTask = nil
            isFieldFocusOwned = false
            return
        }
        guard focusLossTask == nil else { return }
        focusLossTask = Task { [weak self, weak window] in
            while true {
                try? await Task.sleep(for: Self.focusLossSettleDelay)
                guard !Task.isCancelled, let self else { return }
                guard let window else { self.isFieldFocusOwned = false; break }
                if window.inLiveResize { continue }
                if !self.fieldHasFocus(in: window) { self.isFieldFocusOwned = false }
                break
            }
            self?.focusLossTask = nil
        }
    }

    private func redirectFieldFocus(windowNumber: Int) {
        guard let window = NSApp.window(withWindowNumber: windowNumber), fieldHasFocus(in: window),
              !isFieldFocusOwned, !isFieldFocusAllowed else { return }
        Self.log("Search field took focus unasked; moving it to the focus sink")
        window.makeFirstResponder(focusSink)
    }

    /// The field, or its editor, is the window's first responder.
    private func fieldHasFocus(in window: NSWindow) -> Bool {
        guard let field = Self.searchItem(in: window)?.searchField,
              let responder = window.firstResponder else { return false }
        return responder === field || responder === field.currentEditor()
    }

    /// The user is asking for the field right now: within the allowance after a click in
    /// the toolbar, ⌘F, or the menu command, or during a Tab or a toolbar click.
    private var isFieldFocusAllowed: Bool {
        if let until = fieldFocusAllowedUntil, ContinuousClock.now < until { return true }
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        /// Tab and Shift-Tab, walking the key-view loop.
        case .keyDown: return event.keyCode == 48
        case .leftMouseDown, .leftMouseUp: return Self.isInSearchToolbar(event)
        default: return false
        }
    }

    /// Whether a mouse event landed in the toolbar of a window that has the search field.
    /// The toolbar is the part of the window outside its content layout rect.
    private static func isInSearchToolbar(_ event: NSEvent) -> Bool {
        guard let window = NSApp.window(withWindowNumber: event.windowNumber),
              searchItem(in: window) != nil else { return false }
        return !window.contentLayoutRect.contains(event.locationInWindow)
    }

    private static func searchItem(in window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    /// Whether the toolbar search field's editor is the key window's first responder, read
    /// from AppKit directly rather than from the lagging focus state. Compared by identity
    /// with the field's own `currentEditor()`, not through `NSText.delegate`, an
    /// `unowned(unsafe)` reference strict memory safety flags.
    private static var searchFieldHoldsKeyboard: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder,
              let editor = toolbarSearchItem?.searchField.currentEditor() else { return false }
        return responder === editor
    }

    /// The key window's toolbar search field.
    private static var toolbarSearchItem: NSSearchToolbarItem? {
        NSApp.keyWindow?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    /// Focuses the toolbar search field (Search ▸ Search Film Library, ⌘F).
    static func focusField() {
        shared.allowFieldFocus()
        toolbarSearchItem?.beginSearchInteraction()
    }

    /// Focuses the toolbar search field with the caret after its contents.
    static func focusFieldAtEnd() {
        guard let item = toolbarSearchItem else { return }
        shared.allowFieldFocus()
        item.beginSearchInteraction()
        if let editor = item.searchField.currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
    }

    // MARK: - Saved Searches

    /// The saved search the field was opened from, for as long as the field holds it (edited
    /// or not). Once the field changes, the title bar and the Search menu offer "Update
    /// Saved Search…" for it. Cleared with the field.
    private(set) var editingSavedSearchID: UUID?

    /// The search in the field as a saved search stores it: the confirmed pills and the
    /// freeform text beside them, with any "#" fragment still being typed left out.
    var currentQuery: SavedSearchQuery {
        SavedSearchQuery(tokens: currentTokens, text: getCleanSearchText())
    }

    /// Puts a saved search in the field, exactly as applyRecentSearch restores a recent one,
    /// and remembers where it came from.
    func applySavedSearch(_ search: SavedSearch) {
        applyRecentSearch(search.query)
        editingSavedSearchID = search.id
    }

    /// The films `query` matches among `films`, by the same token and text steps the field's
    /// own search runs. Leaves `tokenResultCache` alone: that belongs to the field's search.
    func filmIDs(matching query: SavedSearchQuery, in films: [FilmSnapshot],
                 lists: SearchListCatalog) -> Set<UUID> {
        guard !query.isEmpty else { return [] }
        return Set(matchingFilms(films, tokens: query.tokens, text: query.text, lists: lists).map(\.id))
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
            parts.append("\(token.prefix)\(token.field.rawValue):\(token.value)")
        }
        
        return parts.joined(separator: " ")
    }
    
    /// Get clean search text (excluding # patterns).
    /// Returns pendingCleanText during token commit if set, allowing processSearchSubmission()
    /// to override the live searchText for the duration of the addToken() call.
    private func getCleanSearchText() -> String {
        pendingCleanText ?? Self.freeformText(searchText)
    }

    /// `text` with the "#…" token fragment, value included, cut off, and trimmed: the
    /// freeform text beside the pills. Everything from the "#" on belongs to the token being
    /// typed; stripping only "#<field> " left its value behind as freeform text ("#dir
    /// nolan" → "nolan"). Shared by getCleanSearchText and updateTokenEntryState.
    private static func freeformText(_ text: String) -> String {
        let head = text.firstIndex(of: "#").map { text[..<$0] } ?? text[...]
        return head.trimmingCharacters(in: .whitespaces)
    }
    
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
            /// Fallback if not in cache (shouldn't happen, but handle gracefully).
            return Self.textContains(film.name, queryKey) ||
                   film.alternateTitle.contains { Self.textContains($0, queryKey) }
        }
        if SearchText.contains(cached.name, queryKey) { return true }
        return SearchText.contains(cached.alternateTitles, queryKey)
    }

    /// Returns true if any value of any of `arrays` contains the query, already in
    /// `SearchText.key` form: through MetadataCache's stored keys, or by normalizing the
    /// snapshot's values on the fly when the film is not yet cached, as matchesTitle does.
    private func matchesText(_ film: FilmSnapshot, _ arrays: [TextArray], query queryKey: String) -> Bool {
        guard let keys = MetadataCache.shared.getTextSearchKeys(for: film.id) else {
            return arrays.contains { array in
                film[keyPath: array.values].contains { Self.textContains($0, queryKey) }
            }
        }
        /// An empty query matches every value, so every array that has one — which the
        /// joined keys cannot tell (see FilmTextSearchKeys).
        if queryKey.isEmpty { return arrays.contains { !film[keyPath: $0.values].isEmpty } }
        return arrays.contains { SearchText.contains(keys[keyPath: $0.keys], queryKey) }
    }

    /// One string-array property a plain text-match token scans: the snapshot's values, and
    /// the same values' stored keys (FilmTextSearchKeys).
    private struct TextArray {
        let values: KeyPath<FilmSnapshot, [String]>
        let keys: KeyPath<FilmTextSearchKeys, String>
    }

    /// The snapshot string-array properties each plain text-match token scans.
    ///
    /// The switch is deliberately exhaustive rather than defaulted: every field that has
    /// its own branch in `applyTokenFilter` (title, genre, notes and the specialized
    /// numeric/date/list/release filters) is listed here returning no key paths, so adding
    /// a SearchField is a compile error in both places instead of silently matching nothing.
    private static func textArrays(for field: SearchField) -> [TextArray] {
        let cast = TextArray(values: \.cast, keys: \.cast)
        let directors = TextArray(values: \.directors, keys: \.directors)
        let producers = TextArray(values: \.producers, keys: \.producers)
        let executiveProducers = TextArray(values: \.executiveProducers, keys: \.executiveProducers)
        let screenwriters = TextArray(values: \.screenwriters, keys: \.screenwriters)
        let composer = TextArray(values: \.composer, keys: \.composer)
        switch field {
        case .crew:
            return [cast, directors, producers, executiveProducers, screenwriters, composer]
        case .cast:              return [cast]
        case .directors:         return [directors]
        case .producer:          return [producers]
        case .executiveProducer: return [executiveProducers]
        case .screenwriter:      return [screenwriters]
        case .composer:          return [composer]
        case .studio:            return [TextArray(values: \.studio, keys: \.studio)]
        case .tags:              return [TextArray(values: \.tags, keys: \.tags)]
        /// Handled by their own branches in applyTokenFilter — never routed here.
        case .title, .genre, .source, .notes, .synopsis, .year, .duration, .rating, .lastWatched,
             .dateAdded, .list, .releases, .rotationThreshold, .flags:
            return []
        }
    }

    /// Apply a single token filter to a set of film snapshots.
    /// 'lists' resolves a `#list` token to its films without accessing model objects.
    private func applyTokenFilter(
        token: SearchToken,
        to films: [FilmSnapshot],
        lists: SearchListCatalog
    ) -> [FilmSnapshot] {
        let results: [FilmSnapshot]
        
        /// Normalize the query once for all field types that need it, rather than inside
        /// the per-film filter closures.
        let lowercasedQuery = SearchText.key(token.value)
        
        switch token.field {
        case .title:
            results = films.filter { matchesTitle($0, query: lowercasedQuery) }
            
        /// Every field backed purely by string-array snapshot properties — the six
        /// credited-person fields, the broad-match .crew union over all six, plus studio
        /// and tags — resolves through one table-driven pass. Each field is a
        /// `films.filter { film.<field>.contains { textContains… } }` over its own arrays, so
        /// the only thing that varies between them is which arrays to scan.
        /// Scan order within .crew is preserved, and `contains` still short-circuits on
        /// the first array that matches.
        case .crew, .cast, .directors, .producer, .executiveProducer,
             .screenwriter, .composer, .studio, .tags:
            let arrays = Self.textArrays(for: token.field)
            results = films.filter { matchesText($0, arrays, query: lowercasedQuery) }

        case .genre:
            results = films.filter { film in
                guard let keys = MetadataCache.shared.getTextSearchKeys(for: film.id) else {
                    return Self.textContains(film.genre, lowercasedQuery)
                }
                return SearchText.contains(keys.genre, lowercasedQuery)
            }

        /// One short string per film (FilmDigitalSource's vocabulary), so it is normalized
        /// here rather than stored in FilmTextSearchKeys. "none" finds the films with no
        /// source set (no source in the vocabulary contains the word); an empty key (a value
        /// of only punctuation) matches every film that has one, as an empty Studio value does.
        case .source:
            results = films.filter { film in
                let hasSource = !film.digitalSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if lowercasedQuery == "none" { return !hasSource }
                if lowercasedQuery.isEmpty { return hasSource }
                return Self.textContains(film.digitalSource, lowercasedQuery)
            }

        case .notes:
            results = films.filter { film in
                guard let keys = MetadataCache.shared.getTextSearchKeys(for: film.id) else {
                    return Self.textContains(film.notes, lowercasedQuery) ||
                        Self.textContains(film.descriptionNotes, lowercasedQuery)
                }
                return SearchText.contains(keys.notes, lowercasedQuery)
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
            results = filterByDateField(films, query: token.value, fieldValue: { $0.lastWatched },
                                        dateType: .lastWatched)
            
        case .dateAdded:
            results = filterByDateField(films, query: token.value, fieldValue: { $0.dateAdded },
                                        dateType: .dateAdded)
            
        case .list:
            results = filterByList(films, query: token.value, lists: lists)
            
        case .releases:
            results = filterByReleases(films, query: token.value)
            
        case .rotationThreshold:
            results = filterByRotationThreshold(films, query: token.value)

        case .flags:
            results = filterByFlags(films, query: token.value)
        }
        
        /// Handle inversion
        if token.isInverted {
            let resultIDs = Set(results.map { $0.id })
            return films.filter { !resultIDs.contains($0.id) }
        }
        
        return results
    }
    
    /// Whether `film` passes the search the gallery shows now — the same tokens and text
    /// `filterFilms` would apply — without filterFilms' side effects (it consumes the
    /// text-only flag and refreshes the token cache). For judging an unsaved edit
    /// (DataCoordinator.filmWouldLeaveCurrentView).
    func currentSearchMatches(_ film: FilmSnapshot, lists: SearchListCatalog) -> Bool {
        let shown = shownSearch
        return !matchingFilms([film], tokens: shown.tokens, text: shown.text, lists: lists).isEmpty
    }

    /// Filter film snapshots based on current search state.
    /// Called by DataCoordinator after view-scoped films are retrieved.
    ///
    /// 'lists' is the catalog of every list a `#list` token can name. Callers supply it to
    /// avoid coupling SearchController to MemoryStore directly; DataCoordinator builds it
    /// with searchListCatalog(). It is required rather than defaulted: an empty default
    /// silently makes every `#list` token match nothing, which is a wrong answer rather
    /// than a degraded one.
    func filterFilms(_ films: [FilmSnapshot], lists: SearchListCatalog) -> [FilmSnapshot] {
        /// Consumed here whatever happens, so the flag never outlives the reload it was set for.
        let textOnly = isTextOnlyReload
        isTextOnlyReload = false
        
        /// During token entry this is the last confirmed search, whose token results are
        /// recomputed: the text-only flag describes the field's own search.
        let shown = shownSearch
        Self.log(isActive
                 ? "filterFilms: Filtering \(films.count) films with \(shown.tokens.count) tokens, text='\(shown.text)'"
                 : "filterFilms: Token entry mode - using last confirmed state")
        return applyFilters(to: films, tokens: shown.tokens, searchText: shown.text,
                            lists: lists, reuseTokenResults: isActive && textOnly)
    }
    
    /// Apply filtering logic with given tokens and search text.
    ///
    /// The token steps (1–4) depend only on the tokens and the films, never on the freeform
    /// text, so their result is cached and reused while only the text changes. Without this,
    /// every keystroke re-ran every token's filter over the whole library, which is why typing
    /// slowed with each token added. `reuseTokenResults` is true only for a reload that the
    /// text debounce started (see isTextOnlyReload); any other reload — a token change, an
    /// edit, a view or sort change — recomputes, so a cached set is never applied to data it
    /// was not computed from.
    private func applyFilters(
        to films: [FilmSnapshot],
        tokens: [SearchToken],
        searchText: String,
        lists: SearchListCatalog,
        reuseTokenResults: Bool
    ) -> [FilmSnapshot] {
        let filtered: [FilmSnapshot]
        if tokens.isEmpty {
            filtered = films
        } else if reuseTokenResults, let cache = tokenResultCache,
                  cache.tokens == tokens, cache.inputCount == films.count {
            filtered = films.filter { cache.ids.contains($0.id) }
        } else {
            filtered = applyTokens(tokens, to: films, lists: lists)
            tokenResultCache = TokenResultCache(tokens: tokens, inputCount: films.count,
                                                ids: Set(filtered.map(\.id)))
        }

        return applyFreeformText(searchText, to: filtered)
    }

    /// The films among `films` that `tokens` and `text` match, in their input order: the
    /// token steps, then the freeform text. The one rule every search answer uses — the
    /// field's results (through applyFilters' cache), saved searches and unsaved edits.
    private func matchingFilms(_ films: [FilmSnapshot], tokens: [SearchToken], text: String,
                               lists: SearchListCatalog) -> [FilmSnapshot] {
        applyFreeformText(text, to: applyTokens(tokens, to: films, lists: lists))
    }

    /// Apply freeform text search (clean text only, # patterns already stripped).
    /// Freeform text matches against title and alternate titles, identical to the
    /// .title token — both share matchesTitle to keep the two paths in lockstep.
    /// A query of nothing but punctuation normalizes to "", which names no text to
    /// match, so it narrows nothing — the same as an empty field.
    private func applyFreeformText(_ text: String, to films: [FilmSnapshot]) -> [FilmSnapshot] {
        let queryKey = SearchText.key(text)
        guard !queryKey.isEmpty else { return films }
        return films.filter { matchesTitle($0, query: queryKey) }
    }
    
    /// Steps 1–4 of applyFilters: the films that satisfy `tokens`, in their input order.
    private func applyTokens(
        _ tokens: [SearchToken],
        to films: [FilmSnapshot],
        lists: SearchListCatalog
    ) -> [FilmSnapshot] {
        /// Separate tokens into three groups:
        ///   AND  — normal positive match, all must be satisfied (intersection)
        ///   OR   — additional positive match, any one is sufficient (union added to AND results)
        ///   NOT  — global exclusion applied after the positive set is built
        /// OR+inverted tokens (isOr && isInverted) are treated as global exclusions,
        /// consistent with the intent of "also exclude these" rather than "OR-union exclusion".
        let andTokens = tokens.filter { !$0.isOr && !$0.isInverted }
        let orTokens  = tokens.filter {  $0.isOr && !$0.isInverted }
        let notTokens = tokens.filter {  $0.isInverted }

        /// Step 1: Apply all AND tokens (intersection — every AND token must match)
        var andResults = films
        for token in andTokens {
            andResults = applyTokenFilter(token: token, to: andResults, lists: lists)
        }

        /// Step 2: Apply OR tokens (union — collect IDs for any OR match against the full set)
        var orResults: Set<UUID> = []
        for token in orTokens {
            let matches = applyTokenFilter(token: token, to: films, lists: lists)
            orResults.formUnion(matches.map { $0.id })
        }

        /// Step 3: Combine AND and OR results. With no OR tokens the AND results stand (the
        /// full set when there are no AND tokens either). With OR tokens, a film qualifies by
        /// matching any OR token, or every AND token when there are some — andResults is the
        /// full set when there are none, so it cannot join the union then.
        var filtered = andResults
        if !orTokens.isEmpty {
            let keep = andTokens.isEmpty ? orResults : orResults.union(andResults.map { $0.id })
            filtered = films.filter { keep.contains($0.id) }
        }

        /// Step 4: Apply NOT tokens (global exclusions from the positive set).
        /// applyTokenFilter already handles inversion internally: when token.isInverted
        /// is true, it returns the complement of the matched set. Passing the token
        /// through once here gives the correct exclusion behavior.
        for token in notTokens {
            filtered = applyTokenFilter(token: token, to: filtered, lists: lists)
        }

        return filtered
    }
    
    // MARK: - Specialized Filters
    
    /// Parses an inclusive "low-high" range such as "2000-2020", "90-120" or "7-9", or nil
    /// when `query` is not that shape. Both ends must be whole numbers, so the open-ended
    /// "8-" (rating at most 8) and a leading-minus value are not ranges. Shared by the
    /// year, duration and rating tokens so the three accept exactly the same form. A
    /// reversed range ("9-7") is read as the same span as "7-9".
    private func parseNumericRange(_ query: String) -> (low: Int, high: Int)? {
        let parts = query.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return nil }
        /// A range typed high-to-low ("2010-2000") means the same span; returned as-is it
        /// matched nothing.
        return (min(low, high), max(low, high))
    }

    /// The number beside a comparison symbol (">", "<", "+", "-"), spaces between the two
    /// allowed: "> 2010" and "8 +" read as ">2010" and "8+", as the date and release tokens'
    /// operators and every range ("90 - 120") already did.
    private static func operand(_ text: Substring) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// Every word typed must appear in the film's synopsis, in any order, each as a
    /// case-insensitive substring ("sins" also matches "business"). Whitespace only
    /// separates words, so extra spaces change nothing. The synopsis is `descriptionText`;
    /// the film's own notes are what `.notes` searches.
    private func filterBySynopsis(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        let words = SearchText.key(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return films.filter { film in
            let synopsis = synopsisKey(for: film)
            return words.allSatisfy { SearchText.contains(synopsis, $0) }
        }
    }

    /// A film's synopsis in `SearchText.key` form: MetadataCache's stored key, or the
    /// synopsis normalized on the fly when the film is not yet cached, as matchesTitle does.
    private func synopsisKey(for film: FilmSnapshot) -> String {
        MetadataCache.shared.getSynopsisSearchKey(for: film.id) ?? SearchText.key(film.descriptionText)
    }

    private func filterByYear(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        /// Range: 2000-2020
        if let range = parseNumericRange(query) {
            return films.filter {
                guard let year = Int($0.releaseYear) else { return false }
                return year >= range.low && year <= range.high
            }
        }
        
        /// Greater than: >2020
        if query.hasPrefix(">"), let year = Self.operand(query.dropFirst()) {
            return films.filter { (Int($0.releaseYear) ?? 0) > year }
        }
        
        /// Less than: <2020. A film with no release year has no year to compare, so it is
        /// excluded here exactly as the range and greater-than forms exclude it — reading it
        /// as year 0 made every undated film match every "<" query.
        if query.hasPrefix("<"), let year = Self.operand(query.dropFirst()) {
            return films.filter {
                guard let filmYear = Int($0.releaseYear) else { return false }
                return filmYear < year
            }
        }
        
        /// Exact match
        return films.filter { $0.releaseYear == query }
    }
    
    /// Runs on `FilmSnapshot.effectiveDuration`: the edited runtime when the film is edited
    /// and has one, otherwise the regular runtime — the same length the gallery sort, its
    /// duration bands and the viewing popover use.
    private func filterByDuration(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        /// Range: 90-120 (minutes, both ends included). A film with no stored duration is
        /// excluded, as it is from the "<" form.
        if let range = parseNumericRange(query) {
            return films.filter {
                guard let minutes = DurationHelpers.storedMinutes($0.effectiveDuration) else { return false }
                return minutes >= range.low && minutes <= range.high
            }
        }
        if query.hasPrefix(">"), let mins = Self.operand(query.dropFirst()) {
            return films.filter { (DurationHelpers.storedMinutes($0.effectiveDuration) ?? 0) > mins }
        }
        /// A film with no stored duration is excluded, not read as 0 minutes long; otherwise
        /// every film missing a duration matched every "<" query.
        if query.hasPrefix("<"), let mins = Self.operand(query.dropFirst()) {
            return films.filter {
                guard let filmMinutes = DurationHelpers.storedMinutes($0.effectiveDuration) else { return false }
                return filmMinutes < mins
            }
        }
        if let mins = Int(query) {
            return films.filter { (DurationHelpers.storedMinutes($0.effectiveDuration) ?? 0) >= mins }
        }
        /// Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    private func filterByRating(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        /// Range: 7-9 (both ends included). Taken literally, so "0-3" reaches down to the
        /// unrated films; the "at most" and "<" forms below are what skip them.
        if let range = parseNumericRange(query) {
            return films.filter { $0.userRating >= range.low && $0.userRating <= range.high }
        }
        /// Exclusive greater-than: >7 → rating > 7
        if query.hasPrefix(">"), let rating = Self.operand(query.dropFirst()) {
            return films.filter { $0.userRating > rating }
        }
        /// Exclusive less-than: <9 → rating < 9. The two upper-bound forms skip unrated
        /// films: 0 means "Not Rated" (the Unwatched tab's own rule), not a rating below 9.
        /// An exact "0" query below still finds them when asked for by name.
        if query.hasPrefix("<"), let rating = Self.operand(query.dropFirst()) {
            return films.filter { $0.userRating > 0 && $0.userRating < rating }
        }
        /// Inclusive "at least": 8+ → rating >= 8
        if query.hasSuffix("+"), let rating = Self.operand(query.dropLast()) {
            return films.filter { $0.userRating >= rating }
        }
        /// Inclusive "at most": 8- → rating <= 8
        if query.hasSuffix("-"), let rating = Self.operand(query.dropLast()) {
            return films.filter { $0.userRating > 0 && $0.userRating <= rating }
        }
        /// Exact match: 8 → rating == 8
        if let rating = Int(query) {
            return films.filter { $0.userRating == rating }
        }
        /// Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    /// Shared implementation for date-field token filters (lastWatched, dateAdded).
    ///
    /// `fieldValue` extracts the raw date string from a FilmSnapshot; `dateType` names the
    /// same field's parsed date in MetadataCache, which the forms below compare against
    /// instead of parsing every film's string again (falling back to that parse for a film
    /// not yet cached). The cache holds `parseDate(from:)` of the same string, so the
    /// answer is the same.
    /// "none" finds films with no date for the field; a bare year ("2025") finds that
    /// calendar year. A query that matches none of the forms below, or names a date that cannot be parsed,
    /// returns no films — the same answer a misspelled title gets. Returning every film with
    /// any value for the field would make a typo look like a successful search.
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
        fieldValue: (FilmSnapshot) -> String,
        dateType: MetadataCache.DateType
    ) -> [FilmSnapshot] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()
        let calendar = AppCalendar.current
        func filmDate(_ film: FilmSnapshot) -> Date? {
            MetadataCache.shared.getParsedDate(for: film.id, type: dateType) ?? parseDate(from: fieldValue(film))
        }

        /// "none": films with no date recorded for the field (for Last Watched, no viewing
        /// date). Tested first so no other form can claim the word.
        if q == "none" || q == "never" {
            return films.filter { fieldValue($0).isEmpty }
        }
        
        /// A bare four-digit year: every date inside that calendar year.
        if q.count == 4, let year = Int(q), year > 1900 && year < 2100 {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= start && date < end
            }
        }
        
        /// Natural-language phrases (“2 months ago”, “last summer”, “since march”, “between
        /// 2019 and 2021”). Tried ahead of the fixed forms below. It accepts nothing they do
        /// except the rolling words, which it reads exactly as they do, the month-year form,
        /// and spelled-out dates, which name the same span either way.
        if let matches = naturalDateMatcher(q, now: now) {
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return matches(date)
            }
        }
        
        /// Relative: today
        if q.contains("today") {
            let startOfToday = calendar.startOfDay(for: now)
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= startOfToday
            }
        }
        
        /// Relative: week / past week (last 7 days)
        if q.contains("week") {
            guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else {
                return []
            }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= weekAgo
            }
        }
        
        /// Relative: month / past month (last calendar month)
        if q.contains("month") {
            guard let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) else {
                return []
            }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= monthAgo
            }
        }
        
        /// Relative: year / past year (last calendar year)
        if q.contains("year") {
            guard let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) else {
                return []
            }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= yearAgo
            }
        }
        
        /// Operator: >date — after the given date (exclusive)
        if q.hasPrefix(">") {
            let dateString = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let year = Int(dateString), year > 1900 && year < 2100 {
                /// ">2019" means after the last moment of 2019, i.e. dateAdded/lastWatched is in 2020+
                let comps = DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59)
                guard let yearEndDate = calendar.date(from: comps) else {
                    return []
                }
                return films.filter {
                    guard let date = filmDate($0) else { return false }
                    return date > yearEndDate
                }
            }
            /// A natural phrase works too: “>last summer” is after the end of last summer.
            guard let compareDate = parseDate(from: dateString)
                    ?? naturalDateAnySpan(naturalDateWords(dateString), now: now)?.end else { return [] }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date > compareDate
            }
        }
        
        /// Operator: <date — before the given date (exclusive)
        if q.hasPrefix("<") {
            let dateString = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let year = Int(dateString), year > 1900 && year < 2100 {
                /// "<2020" means before the first moment of 2020, i.e. dateAdded/lastWatched is ≤ 2019
                let comps = DateComponents(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0)
                guard let yearStartDate = calendar.date(from: comps) else {
                    return []
                }
                return films.filter {
                    guard let date = filmDate($0) else { return false }
                    return date < yearStartDate
                }
            }
            guard let compareDate = parseDate(from: dateString)
                    ?? naturalDateAnySpan(naturalDateWords(dateString), now: now)?.start else { return [] }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date < compareDate
            }
        }
        
        /// Month+year: "December 2020", "Dec 2020", "December, 2020", "Dec, 2020"
        if let monthYearDate = parseMonthYear(q) {
            let startOfMonth = calendar.startOfDay(for: monthYearDate)
            guard let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startOfMonth) else {
                return []
            }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= startOfMonth && date <= endOfMonth
            }
        }
        
        /// Exact day match: any parseable date string
        if let compareDate = parseDate(from: q) {
            let startOfDay = calendar.startOfDay(for: compareDate)
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                return []
            }
            return films.filter {
                guard let date = filmDate($0) else { return false }
                return date >= startOfDay && date < endOfDay
            }
        }
        
        /// Unrecognized query — return no results, consistent with all other filter methods.
        return []
    }
    
    /// Cached formatters for parseMonthYear to avoid repeated allocations.
    /// DateFormatter creation is expensive (~0.5ms per instantiation × 4 = ~2ms saved per call).
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
    
    /// Helper to parse "month year" queries (e.g., "december 2020", "dec 2020")
    private func parseMonthYear(_ query: String) -> Date? {
        for formatter in Self.monthYearFormatters {
            if let date = formatter.date(from: query) {
                return date
            }
        }
        
        return nil
    }
    
    // MARK: - Natural-Language Dates
    ///
    /// The everyday phrasings a date token accepts on top of the fixed forms in
    /// filterByDateField: "2 months ago", "last summer", "since march", "between 2019 and
    /// 2021", "early december 2020", and so on. Both date fields use them.
    ///
    /// Every lowercase keyword literal in these functions is a word the search guide must
    /// mention: the `guide-sync` harness scenario (99.53) scans their bodies for literals.
    /// Keep backslashes and string interpolation out of them — either derails that scan.

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
            /// An ordinal: digits followed by exactly two letters (“1st”, “25th”).
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
        let cal = AppCalendar.current
        /// A typed amount like "1e300 days" is finite but far beyond Int's range; converting
        /// it below would trap. No real date lies that far back, so it names no span.
        guard amount.isFinite, amount < 1_000_000 else { return nil }
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
        let cal = AppCalendar.current
        let phrase = words.joined(separator: " ")

        /// Any recorded date at all.
        if ["ever", "anytime", "any time", "any date"].contains(phrase) {
            return { _ in true }
        }

        /// Today's month and day, in any year.
        if ["this day", "this date"].contains(phrase) {
            let today = cal.dateComponents([.month, .day], from: now)
            return { date in
                let comps = cal.dateComponents([.month, .day], from: date)
                return comps.month == today.month && comps.day == today.day
            }
        }

        /// An amount of time ago, compared: “more than 2 years ago” is older than that
        /// moment; “less than 3 weeks ago” and “within 3 weeks” are more recent.
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
        /// An unfinished phrase ("march to", "prior to", "<") leaves no words on one side.
        guard !words.isEmpty else { return nil }
        let cal = AppCalendar.current
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
        /// Several branches below read words[0]; an empty list names no span.
        guard !words.isEmpty else { return nil }
        let cal = AppCalendar.current
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
        /// A split that does not leave a date on both sides falls through, so "prior to
        /// 2020" still reaches the open-ended forms below.
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
            /// A year stated only on the right applies to both sides: “march to june 2025”.
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
            /// Matches the rolling “today” form: anything from the start of today on.
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
        let weekday = cal.component(.weekday, from: now) /// 1 = Sunday … 7 = Saturday
        if core == ["weekend"] {
            /// The Saturday that begins the most recent weekend (this one, if it is under way).
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
        /// “late last year”, “early this year”: the calendar year itself.
        if core == ["last", "year"] || core == ["this", "year"], explicitYear == nil, part != nil {
            let year = cal.component(.year, from: now) - (core[0] == "last" ? 1 : 0)
            guard let start = day(year, 1, 1), let end = day(year + 1, 1, 1) else { return nil }
            return naturalDatePortion(DateSpan(start: start, end: end), part: part)
        }
        /// A numeric month: “2020-12”, “12/2020”, “2020.12”.
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

        /// The period `core` names in a given year, or nil when `core` names none.
        func period(in year: Int) -> DateSpan? {
            if core.isEmpty, part != nil {
                guard let start = day(year, 1, 1), let end = day(year + 1, 1, 1) else { return nil }
                return DateSpan(start: start, end: end)
            }
            guard !core.isEmpty else { return nil }
            /// A month, or a month and day in either order (“dec 25”, “25 december”).
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
            /// Meteorological seasons. Winter is named for the year its December falls in.
            let seasonStarts: [String: Int] = ["spring": 3, "summer": 6, "fall": 9, "winter": 12]
            if core.count == 1, let month = seasonStarts[core[0]] {
                guard let start = day(year, month, 1),
                      let end = cal.date(byAdding: .month, value: 3, to: start) else { return nil }
                return DateSpan(start: start, end: end)
            }
            /// Quarters.
            let quarters: [String: Int] = ["q1": 1, "q2": 4, "q3": 7, "q4": 10]
            if core.count == 1, let month = quarters[core[0]] {
                guard let start = day(year, month, 1),
                      let end = cal.date(byAdding: .month, value: 3, to: start) else { return nil }
                return DateSpan(start: start, end: end)
            }
            /// Holidays (US). The Fourth of July arrives as two words once the filler is gone.
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
                /// The fourth Thursday of November, through that weekend.
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
                /// The most recent occurrence that is already over.
                span = thisYears.end <= now ? thisYears : period(in: currentYear - 1)
            case "this":
                /// The occurrence under way, or else this calendar year's.
                if thisYears.start > now, let previous = period(in: currentYear - 1), previous.end > now {
                    span = previous
                } else {
                    span = thisYears
                }
            default:
                /// The most recent occurrence that has begun.
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
        let cal = AppCalendar.current
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
        /// A month splits 1–10 / 11–20 / 21–end, or 1–15 / 16–end.
        let size = pieces == 3 ? 10 : 15
        let from = index * size
        let to = index == pieces - 1 ? length : (index + 1) * size
        guard let start = cal.date(byAdding: .day, value: from, to: span.start),
              let end = cal.date(byAdding: .day, value: to, to: span.start) else { return nil }
        return DateSpan(start: start, end: end)
    }

    /// Filters films to those in the list(s) the query names.
    ///
    /// A query that is a list's whole name selects that list alone, even when the name also
    /// appears inside another one: "purchased 4k" is "Purchased 4K", not "Unpurchased 4K"
    /// too, which is what the token's pill promises. Only a query that names no list exactly
    /// falls back to every list whose name contains it, so "#list purch" still works.
    /// A list's aliases are matched exactly as its name is.
    private func filterByList(
        _ films: [FilmSnapshot],
        query: String,
        lists: SearchListCatalog
    ) -> [FilmSnapshot] {
        /// The rule itself is SearchListMatcher's, shared with the saved-search cycle check.
        let keyed = lists.entries.indices.flatMap { index in
            ([lists.entries[index].name] + lists.entries[index].aliases).map { (key: SearchText.key($0), index: index) }
        }
        let matched = Set(SearchListMatcher.matches(query, keys: keyed.map(\.key)).map { keyed[$0].index })
        guard !matched.isEmpty else { return [] }
        let ids = matched.reduce(into: Set<UUID>()) { $0.formUnion(lists.entries[$1].filmIDs()) }
        return films.filter { ids.contains($0.id) }
    }
    
    /// The Is token: films for which every term of the comma-separated value holds (see
    /// FilmFlag). An unrecognized term matches nothing, as other tokens' unread values do.
    private func filterByFlags(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        guard let tests = FilmFlag.parse(query) else { return [] }
        let today = StorageDateFormatters.calendar.startOfDay(for: Date())
        return films.filter { film in
            tests.allSatisfy { Self.film(film, has: $0.flag, today: today) != $0.negated }
        }
    }

    /// One flag's test. Each mirrors the rule of the smart list or report it shares a name
    /// with, minus that list's side conditions (see FilmFlag).
    private static func film(_ film: FilmSnapshot, has flag: FilmFlag, today: Date) -> Bool {
        func ownsFormat(_ format: ReleaseFormat) -> Bool {
            film.releases.contains { $0.purchased && $0.format == format.rawValue }
        }
        switch flag {
        case .edited: return film.edited
        case .watched: return film.watched
        case .rated: return film.userRating > 0
        case .complete: return film.infoComplete
        case .sorted: return !film.specialSorting.isEmpty
        case .waitingForEdit: return film.specialSorting.contains(FilmSpecialSorting.waitingForEdit)
        case .onHold:
            return film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold)
                || film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold)
        case .temporarilyOnHold: return film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold)
        case .indefinitelyOnHold: return film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold)
        case .ignored: return film.specialSorting.contains(FilmSpecialSorting.ignore)
        case .blacklisted: return film.specialSorting.contains(FilmSpecialSorting.blacklisted)
        case .owned: return film.releases.contains { $0.purchased }
        case .owned4K: return ownsFormat(.uhd4K)
        case .ownedBluray: return ownsFormat(.bluRay)
        case .ownedDVD: return ownsFormat(.dvd)
        /// The Unpurchased list's rule: releases, none of them purchased. "!owned" also
        /// takes the films with no releases at all.
        case .unowned: return !film.releases.isEmpty && film.releases.allSatisfy { !$0.purchased }
        case .noReleases: return film.releases.isEmpty
        case .wishlisted: return film.releases.contains { $0.wishlist > 0 && $0.isTopLevel }
        case .upcoming:
            return film.releases.contains {
                ReleaseDateValue($0.releaseDate, format: $0.format)?.isUpcoming(today: today) ?? false
            }
        case .alternateVersions: return SmartLists.hasAlternateVersions(film)
        case .hallOfFame: return film.hofPosition > 0
        }
    }

    /// The Release token: films with at least one release that has the property the value names.
    ///
    /// A value of several comma-separated terms asks for ONE release that meets them all:
    /// "purchased, criterion" is a purchased Criterion disc, where two separate Release tokens
    /// could be met by two different discs. A term prefixed with "!" asks for a release that
    /// does not have the property ("!purchased, criterion, 4k"). A value that is wholly a
    /// release date is one term, so a date that contains a comma is never split.
    private func filterByReleases(_ films: [FilmSnapshot], query: String) -> [FilmSnapshot] {
        let terms = releaseTerms(query)

        /// One plain studio term, the commonest case, uses the precomputed studio keys rather
        /// than normalizing every release's studio. An empty key matches any release (see
        /// FilmTextSearchKeys), so it finds every film that has releases.
        if terms.count == 1, !terms[0].negated, case .studio(let studioKey) = terms[0].kind {
            return films.filter { film in
                guard let keys = MetadataCache.shared.getTextSearchKeys(for: film.id) else {
                    return film.releases.contains { Self.textContains($0.studio, studioKey) }
                }
                if studioKey.isEmpty { return !film.releases.isEmpty }
                return SearchText.contains(keys.releaseStudios, studioKey)
            }
        }

        let tests = terms.map { term in
            let test = releaseTest(term.kind)
            return { (release: ReleaseSnapshot) in test(release) != term.negated }
        }
        return films.filter { film in
            film.releases.contains { release in tests.allSatisfy { $0(release) } }
        }
    }

    /// What one term of a Release value asks about a release.
    private enum ReleaseTermKind {
        /// A release date form or a keyword, as its test (see releaseKeywordTest).
        case test((ReleaseSnapshot) -> Bool)
        /// Anything else: a studio name, in `SearchText.key` form.
        case studio(String)
    }

    /// The terms of a Release value. The whole value is one term when it is a release date;
    /// otherwise it splits at commas, each segment taking any number of leading "!" (an odd
    /// number negates), and two neighboring segments that together make a date ("March,
    /// 2027") stay one term. Empty segments are skipped, so a trailing comma changes nothing. A
    /// value with no terms at all is the empty studio term, which matches any release.
    private func releaseTerms(_ value: String) -> [(kind: ReleaseTermKind, negated: Bool)] {
        /// Read through StorageDateFormatters, as the "upcoming" forms always were.
        let today = StorageDateFormatters.calendar.startOfDay(for: Date())
        let whole = value.lowercased().trimmingCharacters(in: .whitespaces)
        if let test = releaseDateTest(whole) { return [(.test(test), false)] }
        var terms: [(kind: ReleaseTermKind, negated: Bool)] = []
        let segments = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var index = 0
        while index < segments.count {
            var text = segments[index]
            index += 1
            var negated = false
            while text.hasPrefix("!") {
                negated.toggle()
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { continue }
            /// A date whose own spelling has a comma ("March, 2027") arrives as two segments.
            /// They are read as one term when together they make a date.
            if index < segments.count {
                let joined = text + ", " + segments[index]
                if let test = releaseDateTest(joined.lowercased()) {
                    terms.append((.test(test), negated))
                    index += 1
                    continue
                }
            }
            let q = text.lowercased()
            /// Joined keywords before single ones: the format words match by substring, so
            /// "oop+4k" would otherwise read as the 4K format alone.
            if let test = releaseDateTest(q) ?? Self.joinedKeywordTest(q, today: today)
                ?? Self.releaseKeywordTest(q, today: today) {
                terms.append((.test(test), negated))
            } else {
                terms.append((.studio(SearchText.key(text)), negated))
            }
        }
        return terms.isEmpty ? [(.studio(""), false)] : terms
    }

    /// A release date form (see releaseDateMatcher) as a test on one release, or nil when
    /// `q` is not one. Tested before the keyword forms, none of which starts with a digit or
    /// an operator or names a month and year.
    private func releaseDateTest(_ q: String) -> ((ReleaseSnapshot) -> Bool)? {
        guard let matches = Self.releaseDateMatcher(q, parseMonthYear: parseMonthYear) else { return nil }
        return { release in
            guard let date = ReleaseDateValue(release.releaseDate, format: release.format) else { return false }
            return matches(date)
        }
    }

    /// The test one term makes of one release.
    private func releaseTest(_ kind: ReleaseTermKind) -> (ReleaseSnapshot) -> Bool {
        switch kind {
        case .test(let test):
            return test
        case .studio(let studioKey):
            /// An empty key matches any release (see FilmTextSearchKeys).
            return { release in studioKey.isEmpty || Self.textContains(release.studio, studioKey) }
        }
    }

    /// Keywords joined by "+" ("out of print+exorbitant") as one test: a release that has
    /// them all. One term, so a "!" before it negates the pair as a whole — a release that is
    /// not both — which separate negated terms cannot say. Nil unless every piece is a
    /// keyword, so a studio with "+" in its name, and "hdr10+", read as they always have.
    private static func joinedKeywordTest(_ q: String, today: Date) -> ((ReleaseSnapshot) -> Bool)? {
        let pieces = q.split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard pieces.count > 1 else { return nil }
        let tests = pieces.compactMap { releaseKeywordTest($0, today: today) }
        guard tests.count == pieces.count else { return nil }
        return { release in tests.allSatisfy { $0(release) } }
    }

    /// A keyword form (`q` lowercased and trimmed) as a test on one release, or nil when `q`
    /// is not a keyword, in which case the term is a studio name.
    ///
    /// The branches run in a fixed order, and the order matters: master type ("native 4k")
    /// is checked with exact equality BEFORE the format branch, since "native 4k" contains
    /// "4k" and would otherwise be read as the format.
    private static func releaseKeywordTest(_ q: String, today: Date) -> ((ReleaseSnapshot) -> Bool)? {
        /// Upcoming: a release whose date is still ahead (ReleaseDateValue.isUpcoming), the
        /// same rule as the "Upcoming Releases" smart list and the release card's badge.
        if q == "upcoming" || q == "unreleased" || q == "preorder" || q == "pre-order" {
            return { ReleaseDateValue($0.releaseDate, format: $0.format)?.isUpcoming(today: today) ?? false }
        }

        /// Market availability: the status, in any of its spellings (domestic, import,
        /// multi-pack), and the price. Exact words, so "unavailable" is not read inside
        /// "temporarily unavailable".
        let tags: (ReleaseSnapshot) -> [String] = { $0.marketAvailability }
        switch q {
        case "available", "in print":
            return { ReleaseMarketAvailability.isAvailable(tags($0)) }
        case "out of print", "out-of-print", "oop":
            return { ReleaseMarketAvailability.isOutOfPrint(tags($0)) }
        case "temporarily unavailable", "temp unavailable":
            return { ReleaseMarketAvailability.status(tags($0)) == ReleaseMarketAvailability.temporarilyUnavailable }
        case "unavailable":
            return { ReleaseMarketAvailability.status(tags($0)) == ReleaseMarketAvailability.unavailable }
        case "cheap":
            return { ReleaseMarketAvailability.price(tags($0)) == ReleaseMarketAvailability.cheap }
        case "reasonable":
            return { ReleaseMarketAvailability.price(tags($0)) == ReleaseMarketAvailability.reasonable }
        case "exorbitant", "expensive":
            return { ReleaseMarketAvailability.price(tags($0)) == ReleaseMarketAvailability.exorbitant }
        default:
            break
        }

        /// Wishlist: only releases actually on the Release Wishlist. A child of a combo pack
        /// mirrors its parent's position, so `wishlist > 0` on any release is the same test
        /// the Release Wishlist report makes for the pack.
        if q.contains("wishlist") || q == "wanted" {
            return { $0.wishlist > 0 }
        }
        /// Exact words: a substring test read "unowned" and "owned 4k" as "owned".
        if q == "unpurchased" || q == "unowned" || q == "not owned" {
            return { !$0.purchased }
        }
        if q == "purchased" || q == "owned" {
            return { $0.purchased }
        }

        if q == "native 4k" || q == "native" {
            return { $0.masterType == ReleaseMasterType.nativeFourK }
        }
        if q == "upscaled" || q == "upscale" {
            return { $0.masterType == ReleaseMasterType.upscaled }
        }

        if q.contains("4k") || q.contains("uhd") {
            return { $0.format == ReleaseFormat.uhd4K.rawValue }
        }
        if q.contains("2k") || q.contains("bluray") || q.contains("blu-ray") {
            return { $0.format == ReleaseFormat.bluRay.rawValue }
        }
        if q.contains("dvd") {
            return { $0.format == ReleaseFormat.dvd.rawValue }
        }

        /// Imported vs. domestic: any release whose nationalOrigin is set to something
        /// other than the domestic one — `ReleaseOrigin.isImport`, which also holds the
        /// rule that an unset (empty) origin is neither.
        if q == "imported" || q == "foreign" {
            return { ReleaseOrigin.isImport($0.nationalOrigin) }
        }

        /// Region lock. Periods are stripped before matching so "reg. a"/"reg. free"/etc.
        /// collapse onto the same forms as "reg a"/"reg free" without listing every
        /// period-bearing variant separately.
        if let regionTags = regionLockTags(forQuery: q.replacingOccurrences(of: ".", with: "")) {
            let tagSet = Set(regionTags)
            return { tagSet.contains($0.regionLock) }
        }

        if q == "remastered" || q == "remaster" || q == "rem" {
            return { $0.remastered }
        }

        /// HDR. Exact-match on the finite hasHDR vocabulary, so no ordering concerns
        /// arise between e.g. "hdr10" and "hdr10+" the way substring checks would have.
        /// The tags and the "which of these count as HDR" question both come from
        /// ReleaseHDR, so these filters cannot drift from the picker that writes the field.
        if q == "hdr" { return { ReleaseHDR.isCapable($0.hasHDR) } }
        if q == "dolby vision" || q == "dv" { return { $0.hasHDR == ReleaseHDR.dolbyVision } }
        if q == "hdr10" { return { ReleaseHDR.isHDR10Family($0.hasHDR) } }
        if q == "hdr10+" || q == "hdrplus" || q == "hdr+" { return { $0.hasHDR == ReleaseHDR.hdr10Plus } }

        /// Independence (pack type). "combo-pack"/"combopack"/"combo" cover every combo-pack
        /// form via the same ReleaseIndependence.isComboPack(_:) predicate the model itself
        /// uses, so this stays in lockstep with any future combo-pack variant.
        if q == "combo-pack" || q == "combopack" || q == "combo" {
            return { ReleaseIndependence.isComboPack($0.independence) }
        }
        if q == "standalone" { return { $0.independence == ReleaseIndependence.standalone } }
        if q == "multi-pack" || q == "multipack" || q == "multi" {
            return { $0.independence == ReleaseIndependence.multiPack }
        }

        return nil
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
            /// Either order: "2020-2015" names the same span as "2015-2020".
            let (from, to) = (min(low, high), max(low, high))
            return { $0.year >= from && $0.year <= to }
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
            let c = AppCalendar.current.dateComponents([.year, .month], from: monthStart)
            guard let y = c.year, let m = c.month else { return nil }
            return { $0.year == y && $0.monthDay?.month == m }
        }

        /// Only strings that start with a digit: parseDate is lenient enough elsewhere that a
        /// studio name should never be offered to it.
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
            /// DVD region numbers (the only numbered regions this app's region pickers
            /// offer): "region 1"/"reg 1"/"reg1", etc.
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

        /// Patterns for recognized unit suffixes (anchored to end of string, space-separated).
        /// yr\.? matches both "yr" and "yr." without a word-boundary issue on the period.
        let yearUnitPattern  = #"\s+(years?|yr\.?)$"#
        let monthUnitPattern = #"\s+(months?|mo\.?)$"#
        /// Any trailing non-whitespace token that is not a whitelisted unit.
        let anyTrailingWordPattern = #"\s+\S+$"#

        let hasYearUnit  = q.range(of: yearUnitPattern,  options: .regularExpression) != nil
        let hasMonthUnit = q.range(of: monthUnitPattern, options: .regularExpression) != nil

        /// If the input has a trailing word that is neither a year nor a month unit, reject it.
        let hasAnyTrailingWord = q.range(of: anyTrailingWordPattern, options: .regularExpression) != nil
        if hasAnyTrailingWord && !hasYearUnit && !hasMonthUnit {
            return nil
        }

        /// Strip the recognized unit suffix (if present) to isolate the bare numeral.
        let stripped = q
            .replacingOccurrences(of: yearUnitPattern,  with: "", options: .regularExpression)
            .replacingOccurrences(of: monthUnitPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        /// Bounded so a typed "1e300" or "inf" cannot trap in the Int conversions below.
        guard let doubleVal = Double(stripped), doubleVal.isFinite, abs(doubleVal) < 1_000_000 else { return nil }

        if hasYearUnit {
            /// Unit was explicitly years — convert to months and validate.
            let months = Int((doubleVal * 12).rounded())
            return Preferences.rotationThresholdOptions.contains(months) ? months : nil
        }

        if hasMonthUnit {
            /// Unit was explicitly months — the numeral must be an exact integer match.
            let asInt = Int(doubleVal)
            guard Double(asInt) == doubleVal else { return nil }
            return Preferences.rotationThresholdOptions.contains(asInt) ? asInt : nil
        }

        /// No unit supplied — try the numeral as a direct month integer first,
        /// then fall back to treating it as a year fraction.
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
        /// Keywords test whether a per-film override exists, not what the effective value is.
        /// A film explicitly set to the same value as the global default still has an override.
        switch query.trimmingCharacters(in: .whitespaces).lowercased() {
        case "default":
            return films.filter { $0.rotationThresholdOverride == nil }
        case "override", "custom":
            return films.filter { $0.rotationThresholdOverride != nil }
        default:
            break
        }
        guard let targetMonths = parseRotationThresholdQuery(query) else {
            /// Invalid / unrecognized value — no results, just like a misspelled title.
            return []
        }
        return films.filter { film in
            /// film.rotationThreshold resolves override ?? Preferences.defaultRotationThreshold.
            film.rotationThreshold == targetMonths
        }
    }
    
    // MARK: - Text Matching
    
    /// Whether raw `text` contains `queryKey` (already in `SearchText.key` form): the text is
    /// normalized on the fly. For values MetadataCache holds no stored key for; stored keys
    /// go to SearchText.contains directly. An empty key is contained in every text.
    private static func textContains(_ text: String, _ queryKey: String) -> Bool {
        SearchText.contains(SearchText.key(text), queryKey)
    }
}
