// MARK: - SelectionState.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Global observable selection tracker, shared across all views.

import SwiftUI
import AppKit
import Observation

/// Classifies the input that produced a selection change, so downstream consumers
/// (notably `RightSidebar`'s adaptive debounce) can react correctly without guessing
/// from timing.
///
/// - `keyRepeat`:   The change came from an OS-reported keyboard auto-repeat event
///                  (`NSEvent.isARepeat == true`) — i.e. the user is holding an arrow
///                  key and scrolling. Consumers should debounce expensive work.
/// - `discrete`:    The change came from a single, deliberate user action whose
///                  authoritative non-repeat status is known at the call site (e.g. a
///                  discrete arrow-key tap). Consumers should resolve **instantly**, with
///                  no debounce, no matter how quickly successive `discrete` changes arrive.
/// - `unspecified`: The source did not (or cannot) supply an authoritative signal
///                  (programmatic selection, native NSTableView list-view arrow navigation,
///                  marquee/drag, report-driven selection, etc.). Consumers fall back to a
///                  timing heuristic so debounce protection degrades gracefully.
enum SelectionInputKind {
    case keyRepeat
    case discrete
    case unspecified
}

extension SelectionInputKind {
    /// Classifies the input behind a selection change delivered by an AppKit selection
    /// delegate callback (`didSelectItemsAt` / `didDeselectItemsAt` /
    /// `tableViewSelectionDidChange`), using `NSApp.currentEvent` as the authoritative
    /// signal.
    ///
    /// AppKit delegate callbacks fire synchronously inside the event dispatch (or the
    /// mouse-tracking loop) of the event that produced them, so `NSApp.currentEvent` at
    /// callback time IS the triggering event. A discrete mouse press/release can never be
    /// an auto-repeat, so classifying it `.discrete` is exactly as authoritative as the
    /// `NSEvent.isARepeat` signal the grid's arrow-key path already uses — and it is what
    /// lets `RightSidebar.handleSelectionChange` resolve deliberate rapid clicking
    /// instantly instead of tripping the `.unspecified` inter-event timing fallback
    /// (< 0.15 s → 75 ms debounce), which was designed to protect against held-key
    /// streams, not deliberate clicks.
    ///
    /// `.leftMouseDragged` is deliberately NOT classified `.discrete`: any drag-driven
    /// selection churn (e.g. AppKit's own band-selection updates, should they ever reach
    /// a delegate callback) must keep the timing fallback's debounce protection, since a
    /// drag can produce many selection changes per second. Every non-mouse origin
    /// (keyboard, programmatic, nil current event) also falls through to `.unspecified`,
    /// preserving the exact pre-existing behavior for those sources.
    @MainActor
    static func fromCurrentAppKitEvent() -> SelectionInputKind {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return .discrete
        default:
            return .unspecified
        }
    }
}

@MainActor
@Observable
final class SelectionState: Loggable {
    nonisolated static let logTag = "[SelectionState]"

    /// The single process-wide selection instance. FilmTrackerApp injects this same
    /// instance into the SwiftUI environment at the root, so `@Environment(SelectionState.self)`
    /// consumers and direct `SelectionState.shared` consumers (e.g. SubcategoryNavigation)
    /// always observe identical state. The private init enforces the singleton.
    static let shared = SelectionState()

    private init() {}

    // The set of currently selected film UUIDs (updates immediately on selection change).
    var selectedFilmIDs: Set<UUID> = [] {
        didSet { untrackedSelectedFilmIDs = selectedFilmIDs } }

    /// The same value as `selectedFilmIDs`, read without registering an observation.
    ///
    /// For the two galleries' selection sync, which runs inside their `updateNSView`.
    /// SwiftUI observation-tracks a representable's update, so reading `selectedFilmIDs`
    /// there re-ran the whole update — the grid's change detection included — on every
    /// click, although each gallery already follows selection through its own observation
    /// loop. Written synchronously with `selectedFilmIDs`, so it is never stale.
    @ObservationIgnored private(set) var untrackedSelectedFilmIDs: Set<UUID> = []

    // Convenience property for single-selection scenarios (returns first selected UUID).
    var selectedFilmID: UUID? { selectedFilmIDs.first }

    /// Classifies the input that produced the selection change currently reflected in
    /// `selectedFilmIDs` (see `SelectionInputKind`).
    ///
    /// The `keyRepeat` / `discrete` cases are sourced directly from `NSEvent.isARepeat` at
    /// the point of key dispatch (see `GalleryCollectionView.keyDown`) rather than being
    /// inferred from timing, so they are authoritative: `keyRepeat` is true on the very first
    /// repeat event of a held key, and a deliberate single tap is always `discrete` no matter
    /// how quickly it follows a previous change. Sources that cannot supply an authoritative
    /// signal leave this `unspecified`.
    ///
    /// Set atomically alongside `selectedFilmIDs` by every selection-mutating call below, so
    /// it can never go stale — there is no separate "reset" call site to forget. Consumers
    /// (e.g. RightSidebar's adaptive debounce) should read this in the same observation cycle
    /// that observes `selectedFilmIDs` changing.
    private(set) var lastSelectionInputKind: SelectionInputKind = .unspecified

    // MARK: - Selection Methods
    
    /// PRIMARY METHOD: Call this for all UI-driven selection changes.
    ///
    /// This method wraps the update in a Task to break the synchronous chain,
    /// preventing "Publishing changes from within view updates" errors that occur
    /// when NSCollectionView delegate methods (didSelectItemsAt, etc.) trigger
    /// @Published property changes during the AppKit view update cycle.
    ///
    /// Use this for:
    /// - NSCollectionView delegate callbacks
    /// - Marquee selection updates
    /// - Any selection triggered by user interaction with UI elements
    ///
    /// This is the safe default that works in all contexts.
    ///
    /// - Parameter inputKind: Classifies the input that produced this change (see
    ///   `SelectionInputKind`). Defaults to `.unspecified`, which is correct for callers
    ///   that cannot supply an authoritative signal (marquee selection, drag, programmatic
    ///   selection, etc.).
    func select(_ filmIDs: Set<UUID>, inputKind: SelectionInputKind = .unspecified) {
        // Avoid redundant publishes and downstream work when the selection is unchanged.
        guard filmIDs != selectedFilmIDs else { return }
        
        // Defer the write by one run-loop turn to break the synchronous chain from
        // AppKit view updates, preventing "Publishing changes from within view updates"
        // errors when NSCollectionView delegate callbacks (didSelectItemsAt, etc.) trigger
        // @Observable property mutations during the AppKit event cycle.
        //
        // DispatchQueue.main.async is used here instead of Task { @MainActor } because
        // it inherits the caller's QoS automatically. AppKit delivers mouse/keyboard
        // events at User-Interactive QoS, so a bare Task { @MainActor } — which defaults
        // to .default — creates a priority inversion the runtime flags as:
        // "[Internal] Thread running at User-interactive quality-of-service class waiting
        // on a lower QoS thread running at Default quality-of-service class."
        // Task(priority: .userInteractive) resolves this but is deprecated in Swift 6.
        // DispatchQueue.main.async propagates the caller's QoS without any explicit hint,
        // which is both correct and forward-compatible.
        DispatchQueue.main.async { [weak self] in
            self?.lastSelectionInputKind = inputKind
            self?.selectedFilmIDs = filmIDs
        }
    }

    /// IMMEDIATE METHOD: Call this ONLY for programmatic selection changes
    /// where you explicitly know you are NOT in a view update context.
    ///
    /// This provides zero-latency updates for:
    /// - Menu bar commands (Select All, etc.)
    /// - Keyboard shortcuts handled outside view updates
    /// - Event bus handlers that are triggered programmatically
    ///
    /// WARNING: Calling this from a view update context will cause the
    /// "Publishing changes from within view updates" error. When in doubt,
    /// use select() instead.
    ///
    /// - Parameter inputKind: Classifies the input that produced this change (see
    ///   `SelectionInputKind`). Defaults to `.unspecified`.
    func selectImmediate(_ filmIDs: Set<UUID>, inputKind: SelectionInputKind = .unspecified) {
        // Avoid redundant publishes and downstream work when the selection is unchanged.
        guard filmIDs != selectedFilmIDs else { return }
        
        // Direct update - zero latency for menu/keyboard actions.
        // Only safe when called from event handlers, not from view callbacks.
        lastSelectionInputKind = inputKind
        selectedFilmIDs = filmIDs
    }

    // Convenience function for single selection (UI-driven).
    //
    // nil-branch uses clearImmediate() rather than the deferred select(Set<UUID>())
    // because a deferred nil-clear would schedule a DispatchQueue.main.async that
    // lands after any isUpdatingSelection flag resets in the calling coordinator.
    // That delayed clear triggers syncSelectionToView() unnecessarily, which then
    // writes [] to collectionView.selectionIndexPaths / deselectAll — producing a
    // spurious deselect one frame after the user's intended clear. The immediate
    // synchronous clear avoids this and is safe because clearImmediate() only ever
    // writes a nil→empty transition, which is idempotent and cannot cause re-entrancy.
    //
    // The non-nil branch routes through the deferred select([filmID]) to avoid
    // "Publishing changes from within view updates" errors when called from AppKit
    // delegate callbacks that fire during the AppKit event cycle.
    func select(_ filmID: UUID?, inputKind: SelectionInputKind = .unspecified) {
        if let filmID = filmID {
            select([filmID], inputKind: inputKind)
        } else {
            clearImmediate()
        }
    }

    // Convenience function for single immediate selection (programmatic).
    func selectImmediate(_ filmID: UUID?, inputKind: SelectionInputKind = .unspecified) {
        if let filmID = filmID {
            selectImmediate([filmID], inputKind: inputKind)
        } else {
            clearImmediate()
        }
    }

    /// Synchronous clear for view changes.
    /// This must complete before view switches to prevent selection artifacts.
    func clearImmediate() {
        guard !selectedFilmIDs.isEmpty else { return }
        selectedFilmIDs = []
    }
    
}
