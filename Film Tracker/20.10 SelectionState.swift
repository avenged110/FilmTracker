// MARK: - SelectionState.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The observable selection tracker shared by all views. It also records what kind of input produced each change.

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
    /// AppKit delegate callbacks run inside the event that caused them, so `NSApp.currentEvent` is that event.
    /// A discrete mouse press is never an auto-repeat, so it is classified `.discrete`. That lets
    /// `RightSidebar.handleSelectionChange` resolve rapid clicks at once. Without this, the timing fallback
    /// (changes less than 0.15 s apart) would debounce them. The fallback exists for held-key streams.
    ///
    /// `.leftMouseDragged` is NOT classified `.discrete`. A drag can produce many changes per second, so it keeps
    /// the timing fallback's protection. Non-mouse origins (keyboard, programmatic, nil current event) are `.unspecified`.
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

    /// The single process-wide selection instance. FilmTrackerApp injects it into the SwiftUI environment, so
    /// environment consumers and `SelectionState.shared` consumers observe the same state. The private init enforces this.
    static let shared = SelectionState()

    private init() {}

    /// The set of currently selected film UUIDs (updates immediately on selection change).
    var selectedFilmIDs: Set<UUID> = [] {
        didSet { untrackedSelectedFilmIDs = selectedFilmIDs } }

    /// The same value as `selectedFilmIDs`, read without registering an observation. The galleries' selection
    /// sync runs inside `updateNSView`. Reading `selectedFilmIDs` there would re-run the whole update on every click.
    /// It is written synchronously with `selectedFilmIDs`, so it is never stale.
    @ObservationIgnored private(set) var untrackedSelectedFilmIDs: Set<UUID> = []

    /// Convenience property for single-selection scenarios (returns first selected UUID).
    var selectedFilmID: UUID? { selectedFilmIDs.first }

    /// Classifies the input that produced the selection change currently reflected in
    /// `selectedFilmIDs` (see `SelectionInputKind`).
    ///
    /// The `keyRepeat` and `discrete` cases come from `NSEvent.isARepeat` at key dispatch (see
    /// `GalleryCollectionView.keyDown`), not from timing. A deliberate tap is always `discrete`, however quickly it
    /// follows the last change. Sources that cannot supply a signal leave this `unspecified`.
    ///
    /// Set together with `selectedFilmIDs` by every selection-mutating call, so it cannot go stale. Consumers such as
    /// RightSidebar's adaptive debounce read it in the same observation cycle.
    private(set) var lastSelectionInputKind: SelectionInputKind = .unspecified

    /// The selection a deferred `select` has queued but not yet written, and a counter
    /// that lets a later call cancel it. Without these, a deferred write could land after
    /// a newer immediate change (or a newer deferred change back to the current value,
    /// which the redundancy guard skipped) and overwrite it with a stale selection.
    @ObservationIgnored private var pendingFilmIDs: Set<UUID>?
    @ObservationIgnored private var selectionGeneration = 0

    /// Whether a deferred `select` is still waiting to land. The galleries skip syncing
    /// their highlight from `selectedFilmIDs` meanwhile: it is about to change, and the
    /// landing write triggers a fresh sync. Syncing early would briefly undo the click,
    /// or prune the outgoing selection and cancel the click's write along with it.
    var hasPendingSelection: Bool { pendingFilmIDs != nil }

    // MARK: - Selection Methods
    
    /// PRIMARY METHOD: use for all UI-driven selection changes. It defers the write by one run-loop turn, so a
    /// change from an AppKit delegate callback does not publish during a view update.
    ///
    /// Use it for NSCollectionView delegate callbacks, marquee selection, and any user-driven selection.
    ///
    /// - Parameter inputKind: Classifies the input that produced this change (see
    ///   `SelectionInputKind`). Defaults to `.unspecified`, which is correct for callers
    ///   that cannot supply an authoritative signal (marquee selection, drag, programmatic
    ///   selection, etc.).
    func select(_ filmIDs: Set<UUID>, inputKind: SelectionInputKind = .unspecified) {
        /// Avoid redundant publishes and downstream work when the selection is unchanged.
        guard filmIDs != (pendingFilmIDs ?? selectedFilmIDs) else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        pendingFilmIDs = filmIDs

        /// DispatchQueue.main.async defers the write while keeping the caller's QoS. AppKit events run at
        /// User-Interactive QoS, and a bare Task { @MainActor } runs at default QoS, which the runtime flags as a
        /// priority inversion. Task(priority: .userInteractive) avoids this but is deprecated in Swift 6.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.selectionGeneration else { return }
            self.pendingFilmIDs = nil
            self.lastSelectionInputKind = inputKind
            self.selectedFilmIDs = filmIDs
        }
    }

    /// IMMEDIATE METHOD: use ONLY where you know the call is not inside a view update. It applies the change
    /// at once, for menu commands, keyboard shortcuts, and programmatic event handlers. Calling it from a view
    /// update logs "Publishing changes from within view updates". When in doubt, use select().
    ///
    /// - Parameter inputKind: Classifies the input that produced this change (see
    ///   `SelectionInputKind`). Defaults to `.unspecified`.
    func selectImmediate(_ filmIDs: Set<UUID>, inputKind: SelectionInputKind = .unspecified) {
        cancelPendingSelection()
        /// Avoid redundant publishes and downstream work when the selection is unchanged.
        guard filmIDs != selectedFilmIDs else { return }
        
        /// Direct update - zero latency for menu/keyboard actions.
        /// Only safe when called from event handlers, not from view callbacks.
        lastSelectionInputKind = inputKind
        selectedFilmIDs = filmIDs
    }

    /// Convenience for single selection (UI-driven). A nil selection clears immediately. A deferred clear would
    /// land after the coordinator's isUpdatingSelection flag resets, and it would cause a spurious deselect one frame later.
    /// A non-nil selection is deferred, as select(_:) is, to avoid view-update publishing.
    func select(_ filmID: UUID?, inputKind: SelectionInputKind = .unspecified) {
        if let filmID = filmID {
            select([filmID], inputKind: inputKind)
        } else {
            clearImmediate()
        }
    }

    /// Convenience function for single immediate selection (programmatic).
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
        cancelPendingSelection()
        guard !selectedFilmIDs.isEmpty else { return }
        selectedFilmIDs = []
    }

    /// Drops any deferred selection write still waiting to land.
    private func cancelPendingSelection() {
        guard pendingFilmIDs != nil else { return }
        selectionGeneration &+= 1
        pendingFilmIDs = nil
    }
    
}
