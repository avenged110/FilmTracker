// MARK: - FSStringList.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The reorderable plain-string list used by the FilmSheet Metadata and Notes tabs.
//
// Renamed from FSListUtilities.swift when ReorderableFramesList was split out to
// 30_40_FSFramesList.swift. The two components are deliberately NOT unified: a
// frames entry is a four-field comma-packed record edited through a popover,
// whereas a string-list entry is a bare value edited in place, so a single type
// would carry two disjoint row models and two disjoint edit paths.
//
// What the two DO share now lives in FSControlHelpers.swift — `ListCircleButton`
// and `ListCircleButtonStyle` (the circular control family), `ListImportPopover`
// (the comma/line-separated bulk-entry sheet), and `ListRowMetrics` (the row and
// control geometry both tables are drawn on). Everything remaining in this file
// is specific to the string list: its in-place editing field and the focus
// machinery behind it, and the click tracking that ends an edit.

import SwiftUI
import AppKit

// MARK: - Row Metrics
//
// The private `StringListMetrics` that used to sit here is gone. Its three values
// were shared with `ReorderableFramesList` in all but name — that file carried
// its own byte-identical copies under different constant names, with comments at
// both sites instructing the reader to keep them in step by hand — so they now
// live on `ListRowMetrics` (30_20_FSControlHelpers.swift) alongside the circular
// control family they are measured against. The same consolidation retired
// `AddRowMetrics`, which held this file's second copy of the control geometry.
//
// This is the arrangement `FieldEdgeTreatment` already established for the
// container chrome: values that must agree across both tables are defined once
// on a primitives file both depend on, rather than restated sideways between two
// peers that are free to drift.

// MARK: - Row Control Region Tracking

/// Holds a reference to a live `NSView` so unrelated views can hit-test against
/// its bounds.
///
/// An earlier version of this type existed to forgive clicks on the "+" button
/// that used to sit OUTSIDE the table, which would otherwise have registered as
/// clicks away from the row being edited. That control is now a row, so the
/// problem it solved is gone — but its inverse appeared in its place.
///
/// A row's own trailing buttons lie INSIDE the row's bounds, so a double-click
/// on one of them was being read as a double-click on the row. That is only ever
/// wrong: those buttons already act on their own clicks, and a click that
/// happens to be the second half of a double-click is not a different intent
/// from the first. The concrete failure is described at `RowClickReporter`.
@MainActor
private final class ClickExclusionRegion {
    weak var view: NSView?

    /// Whether `point` (in window coordinates) falls inside the tracked view.
    func contains(windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let view, unsafe view.window === window else { return false }
        return view.bounds.contains(view.convert(windowPoint, from: nil))
    }
}

/// Zero-size representable that publishes its own backing view into a
/// `ClickExclusionRegion`. Attached as a background, it measures whatever it is
/// placed behind without contributing layout or consuming events.
///
/// No teardown hook is needed: the region holds its view weakly, so the
/// reference simply lapses when SwiftUI releases the backing view.
private struct ClickExclusionCapture: NSViewRepresentable {
    let region: ClickExclusionRegion

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        region.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        region.view = nsView
    }
}

// MARK: - Row Double-Click Detection

/// Reports left clicks relative to the view it is attached to — double-clicks
/// landing inside it, and any click landing outside it — without consuming the
/// events that produce them.
///
/// **Why not a SwiftUI gesture**
///
/// Both `.onTapGesture(count: 2)` and `.simultaneousGesture(TapGesture(count: 2))`
/// were tried, and both broke drag-to-reorder. SwiftUI's tap recognizer has to
/// claim the initial mouseDown to determine whether a second click follows, and
/// the hosting `NSTableView` needs that same event to begin a drag session.
/// Adding `.contentShape` to widen the gesture's hit region only widened the
/// area in which dragging was suppressed. The two cannot share the event
/// through SwiftUI's gesture system.
///
/// A local `NSEvent` monitor sidesteps the conflict: it observes the event
/// stream and returns every event unmodified, so AppKit's drag machinery sees an
/// untouched sequence. This is the pattern the project already uses elsewhere
/// for AppKit-level input that must not disturb the responder chain.
///
/// **One monitor, not one per row**
///
/// The monitor itself lives on `RowClickBroadcaster`, which every reporter
/// registers with. `NSEvent` local monitors are process-wide, so installing one
/// per row meant a single click ran one closure for every visible row of every
/// list on the tab — around forty of them on a populated Metadata tab, all
/// asking the same question. One monitor answers it once and fans the result
/// out. See `RowClickBroadcaster` for the second, more important reason:
/// dispatch order.
private struct RowClickReporter: NSViewRepresentable {

    /// Whether the attached row is currently being edited. Both of the reporter's
    /// jobs are conditional on this, which lets the monitor discard the great
    /// majority of clicks before doing any geometry work — see `handle`.
    let isEditing: Bool

    let onDoubleClickInside: () -> Void

    /// Fired for any left click landing outside this row while it is being
    /// edited. Used to end the edit when the user clicks elsewhere in the sheet.
    ///
    /// This cannot be left to `@FocusState` resigning on its own: clicking
    /// non-focusable chrome — a static label, empty padding, the sheet's
    /// background — does not move first responder on macOS, so focus is never
    /// lost and the edit stays open. The monitor sees those clicks regardless of
    /// whether anything accepts first responder.
    let onClickOutside: () -> Void

    /// The row's own trailing controls. A double-click landing here is not a
    /// double-click on the row.
    ///
    /// **The failure this fixes**
    ///
    /// The pencil button's action is state-dependent: it begins an edit when its
    /// row is at rest and commits one when its row is being edited. Click it to
    /// finish an edit, then click it again within the system double-click
    /// interval — up to about a second, and easily done — and AppKit reports the
    /// second click with `clickCount == 2`. Without this region the monitor read
    /// that as a double-click on the row and began an edit on `mouseDown`;
    /// SwiftUI then re-evaluated the row, so by `mouseUp` the button was the
    /// *editing* variant, and its action committed the edit it had just opened.
    /// The row visibly flickered into edit mode and straight back out, and the
    /// user had to click a third time.
    ///
    /// Ignoring double-clicks over the controls removes the second interpretation
    /// entirely: the button acts on its own click, once, exactly as it does at
    /// every other moment.
    let controlsRegion: ClickExclusionRegion

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        apply(to: context.coordinator)
        RowClickBroadcaster.shared.register(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Rows are index-identified and reused, so the inputs are refreshed on
        // every update; otherwise a row could fire its predecessor's action
        // after a reorder.
        context.coordinator.hostView = nsView
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.isEditing = isEditing
        coordinator.onDoubleClickInside = onDoubleClickInside
        coordinator.onClickOutside = onClickOutside
        coordinator.controlsRegion = controlsRegion
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        RowClickBroadcaster.shared.unregister(coordinator)
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var isEditing = false
        var onDoubleClickInside: () -> Void = {}
        var onClickOutside: () -> Void = {}
        var controlsRegion: ClickExclusionRegion?

        /// What this row makes of `event`. Deliberately a pure classification
        /// with no side effects: the broadcaster asks every registered row what
        /// a click means to it, and only then decides in which order to act on
        /// the answers. See `RowClickBroadcaster.dispatch`.
        enum Outcome {
            case ignore
            case doubleClickInside
            case clickOutside
        }

        func classify(_ event: NSEvent) -> Outcome {
            // Neither of the reporter's jobs applies to a plain click on a row
            // that is not being edited — only a double-click begins an edit, and
            // only an open edit can be ended by clicking away — so that case is
            // discarded up front, before any window lookup or coordinate
            // conversion.
            //
            // The monitor delivers left clicks only, so no button check is
            // needed here; see `RowClickBroadcaster.installIfNeeded`.
            guard isEditing || event.clickCount == 2 else { return .ignore }

            guard let view = hostView, let window = unsafe view.window else { return .ignore }

            // A click in a different window is outside this row by definition.
            guard event.window === window else {
                return isEditing ? .clickOutside : .ignore
            }

            // Hit-test against this row's own bounds. The row also contains
            // buttons and, while editing, a text field; a click on those is
            // inside the row and must not be treated as a click away from it.
            //
            // Bounds containment alone is NOT proof the click reached this row.
            // FilmSheet keeps every visited tab mounted at full size, hidden
            // behind `.opacity(0)`, so a hidden Metadata row occupies real
            // window coordinates while the user is looking at Details or Notes.
            // AppKit already knows those coordinates are unreachable —
            // `TabEventShield` claims them and the tab's scroll view gates its
            // own `hitTest` to nil — but a local event monitor observes the
            // stream before and outside that routing, so it has to consult it
            // explicitly. The check is short-circuited behind the bounds test,
            // so it costs one hit-test only for a click that actually landed on
            // some row's rect.
            let local = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(local), clickReachesThisTab(event, from: view, in: window) {
                guard event.clickCount == 2 else { return .ignore }
                // The row's own buttons handle their clicks themselves; a second
                // click on one of them is another button click, not a gesture on
                // the row. See `controlsRegion` for what happened when it was.
                if let controlsRegion,
                   controlsRegion.contains(windowPoint: event.locationInWindow, in: window) {
                    return .ignore
                }
                return .doubleClickInside
            }

            // Everything below ends an edit, so a row that is not editing has
            // nothing further to do with a click that landed outside it.
            guard isEditing else { return .ignore }

            return .clickOutside
        }

        /// Whether AppKit's own hit-testing routes `event` into the same tab
        /// this row belongs to.
        ///
        /// Answers "is my tab the one receiving clicks", not "did the click hit
        /// my exact row" — the caller's bounds test already settled the latter.
        /// Asking at tab granularity keeps the result independent of whether
        /// SwiftUI's hosting view chooses to claim a given point, which for
        /// non-interactive content such as a plain `Text` it may decline to do.
        ///
        /// Permissive when the view is not inside a scroll view at all, so a
        /// future host that does not use the FilmSheet's tab architecture keeps
        /// the unconditional behavior.
        private func clickReachesThisTab(_ event: NSEvent, from view: NSView, in window: NSWindow) -> Bool {
            // `outermostEnclosingScrollView` (30_20_FSControlHelpers.swift)
            // rather than `enclosingScrollView`: the nearest ancestor is the
            // scroll view backing this row's own `List`, whereas the outermost
            // is `FilmSheetScrollView`, whose `hitTest` gate is what
            // distinguishes an active tab from a hidden one. `ListAddRowRevealer`
            // needs the same view for its own reasons, which is why the walk is
            // shared rather than restated here.
            guard let tabScrollView = view.outermostEnclosingScrollView else { return true }
            guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
            return hit.isDescendant(of: tabScrollView)
        }

    }
}

// MARK: - Row Click Broadcaster

/// Owns the single `NSEvent` local monitor behind every `RowClickReporter`, and
/// decides the order in which rows act on a click.
///
/// **Why one monitor**
///
/// Local monitors are process-wide. A monitor per row meant one click ran one
/// closure per visible row across every list on the tab, each repeating the same
/// window lookup and hit test. This installs exactly one while any row is on
/// screen and removes it when the last one leaves.
///
/// **Why the order matters**
///
/// A single click can mean different things to two different rows: it can be the
/// double-click that begins an edit on one row and, at the same moment, the
/// click-away that ends an open edit on another. Those two are not independent —
/// ending an edit whose draft is blank *removes that row*, which shifts every
/// index after it, and `editingIndex` is an index.
///
/// With a monitor per row the order was whatever order AppKit happened to call
/// the monitors in. If the abandoned blank row was serviced first, its removal
/// shifted the list out from under the index the double-click was about to
/// target, and the double-click resolved against a position that no longer held
/// the row that was clicked — so the edit silently failed to open.
///
/// Dispatching in two phases fixes it by construction. Every begin-edit runs
/// first, so `editingIndex` is set while the array still matches the indices the
/// rows were built with; the click-away commits then run, and
/// `shiftEditingIndex(afterRemovalAt:)` corrects `editingIndex` for any removal
/// they cause. The result no longer depends on monitor ordering at all.
@MainActor
private final class RowClickBroadcaster {

    static let shared = RowClickBroadcaster()

    private init() {}

    /// Registered rows, held weakly.
    ///
    /// Weak rather than strong so a coordinator whose `dismantleNSView` never
    /// ran — SwiftUI guarantees it does, but the broadcaster outlives every row
    /// and a strong entry would be permanent — cannot pin a torn-down row's
    /// views and closures in memory. Cleared entries are pruned on the next
    /// dispatch.
    private var listeners: [ObjectIdentifier: WeakCoordinator] = [:]

    private struct WeakCoordinator {
        weak var value: RowClickReporter.Coordinator?
    }

    private var monitor: Any?

    func register(_ coordinator: RowClickReporter.Coordinator) {
        listeners[ObjectIdentifier(coordinator)] = WeakCoordinator(value: coordinator)
        installIfNeeded()
    }

    func unregister(_ coordinator: RowClickReporter.Coordinator) {
        listeners.removeValue(forKey: ObjectIdentifier(coordinator))
        removeIfIdle()
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        // Left clicks only, deliberately. A right click elsewhere in the sheet
        // does NOT resolve an open edit: it raises a context menu without moving
        // first responder, and the edit is expected to still be there when that
        // menu is dismissed. Widening the mask would make dismissing a stray
        // context menu destroy an in-progress edit.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            // Returning the event unchanged is what preserves dragging: this
            // monitor observes, it never consumes.
            MainActor.assumeIsolated { RowClickBroadcaster.shared.dispatch(event) }
            return event
        }
    }

    /// Tears the monitor down once nothing is listening. Monitors are
    /// process-global, so one left installed keeps firing for the remaining
    /// lifetime of the app.
    private func removeIfIdle() {
        guard listeners.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func dispatch(_ event: NSEvent) {
        var beginEdits: [() -> Void] = []
        var endEdits: [() -> Void] = []
        var stale: [ObjectIdentifier] = []

        for (key, box) in listeners {
            guard let coordinator = box.value else {
                stale.append(key)
                continue
            }
            switch coordinator.classify(event) {
            case .ignore:
                continue
            case .doubleClickInside:
                beginEdits.append(coordinator.onDoubleClickInside)
            case .clickOutside:
                endEdits.append(coordinator.onClickOutside)
            }
        }

        for key in stale { listeners.removeValue(forKey: key) }
        removeIfIdle()

        // Phase order is the point — see the note on the type.
        for action in beginEdits { action() }
        for action in endEdits { action() }
    }
}

// MARK: - Reorderable String List Component

/// The sheet's string-list field: native drag-to-reorder alongside in-place row
/// editing.
///
/// It replaced `EditableStringList`, a plain `VStack` of permanently-bound
/// `TextField`s with a trailing "Add new..." row, which has now been removed
/// entirely. Several notes below contrast the two; that type no longer exists.

///
/// **Why rows are `Text` rather than `TextField`**
///
/// A `List` with `.onMove` makes the entire row the drag source; SwiftUI offers
/// no way to scope the drag to a sub-region. Any control that consumes mouseDown
/// — a `TextField` above all — is therefore not draggable, and a permanently
/// editable field spanning the row width would leave only an incidental gutter
/// from which to initiate a reorder. Rendering rows as inert `Text` keeps the
/// full row width draggable, and editing is entered explicitly.
///
/// **Two ways into edit mode**
///
/// Double-clicking a row and clicking its pencil button both set the same
/// `editingIndex`. The button is contention-free by construction, since it
/// consumes only its own bounds. The double-click is detected by a local
/// `NSEvent` monitor rather than a SwiftUI gesture — every gesture-based
/// approach suppressed drag-to-reorder. See `RowClickReporter`.
///
/// **Adding is a row, not a button**
///
/// The table's last row is always `StringListAddRow` — a placeholder that turns
/// into a focused field when its "+" is clicked, and back into a placeholder
/// once the add resolves. Nothing is written to the array until a non-empty
/// draft is committed, so a canceled add is a no-op by construction rather than
/// by remembering to remove a blank entry on each of the routes out. See that
/// type for what the change removed: the empty-state layout, the scroll bridge,
/// and the click-exclusion machinery all existed to serve an add control that
/// lived outside the table.
///
/// **Edits are drafted, not live-bound**
///
/// While a row is being edited its text lives in row-local `@State`, and the
/// backing array is written exactly once on commit. The former list bound each
/// field directly to `$items[index]`, so every keystroke performed a full
/// array write and fired observation invalidation for the whole collection,
/// which in turn re-ran the owning tab's change tracking. Drafting removes that
/// per-keystroke cost entirely.
///
/// **Commits are position-verified**
///
/// Because a commit is drafted, it necessarily arrives after the interaction
/// that ended the edit, and rows are identified by index rather than by value.
/// A row therefore hands back both its draft and the value it was seeded with,
/// and the write is applied only if that slot still holds the seeded value. See
/// `commitEdit(at:expecting:to:)`.
struct ReorderableStringList: View {

    @Binding var items: [String]

    /// Singular noun used in popover titles and placeholders — "Cast Member"
    /// produces "Import Cast Members". Defaults to a neutral term.
    var itemLabel: String = "Item"

    // No scroll bridge. The list used to take a `FilmSheetScrollProxy` and an
    // anchor name so that adding a row could pull the table into the viewport,
    // because the "+" button sat beside the table's TOP edge and could therefore
    // be clicked while the row it created was below the fold. The add control is
    // now the table's last row: it cannot be clicked unless it is already on
    // screen, and the row it turns into is that same row. There is nothing left
    // to scroll to.

    /// Upper bound on row count. The list does not scroll internally, so every
    /// row adds to the sheet's overall content height; 30 is well clear of the
    /// 1–10 these fields carry in practice while still bounding the worst case.
    private static let maxItems = 30

    // MARK: - Editing State
    //
    // Both live on the parent rather than in the row so that a move or delete
    // can clear them atomically with the mutation that invalidates them. Rows
    // are identified by index (see the ForEach note below), so a stale
    // editingIndex surviving a reorder would silently retarget the edit at
    // whichever item now occupies that position.

    @State private var editingIndex: Int?

    /// Incremented every time an edit begins.
    ///
    /// Identifies one edit session, and is handed to the row's field as its
    /// focus token. The field seeds its buffer and claims first responder once
    /// per token, which makes both operations correct whether SwiftUI builds a
    /// fresh view for the session or reuses the one already at that index —
    /// rows are index-identified, so reuse is possible and must not be relied on
    /// either way.
    ///
    /// Note that the token is a *disambiguator*, not the mechanism: the field's
    /// focus claim is made against the live `NSWindow` and verified, so it does
    /// not depend on any SwiftUI lifecycle hook firing. See `EditingTextField`.
    @State private var editSession: Int = 0

    /// Whether the trailing add row is currently showing its text field.
    ///
    /// Deliberately a separate flag rather than an `editingIndex` of
    /// `items.count`. The add row is not backed by an array element: its draft
    /// has nothing to be position-verified against, its commit appends rather
    /// than writes, and canceling it must leave the array untouched. Folding it
    /// into `editingIndex` would mean every guard on that index having to ask
    /// whether it referred to a real row.
    ///
    /// The two are mutually exclusive by construction — `beginEdit` clears this,
    /// `beginAdd` clears `editingIndex` — so at most one field is ever open.
    @State private var isAdding = false

    /// Bumped each time an entry is committed, which is what asks the add row to
    /// scroll itself back into the viewport. See `ListAddRowRevealer`.
    ///
    /// Deliberately separate from `editSession`: that token identifies an edit
    /// and changes when one *begins*, whereas this changes when the table
    /// *grows*, which is the only moment the add row moves.
    @State private var addRevealToken = 0

    // MARK: - Import Popover State

    @State private var showImportPopover = false
    @State private var importReplaces = false

    // MARK: - Duplicate Confirmation State

    /// The pending "this already exists" confirmation, or `nil` when there is
    /// none. Held here rather than on the row that raised it because both the
    /// add row and the entry rows can raise one, and because a row being edited
    /// may resolve its edit — and be rebuilt — on the same interaction that
    /// produces the prompt.
    @State private var duplicatePrompt: ListDuplicatePrompt?

    // MARK: - Row Geometry
    //
    // Every value now comes from `ListRowMetrics` (30_20_FSControlHelpers.swift).
    // The private `listPadding` that used to sit here was the last of the row
    // constants this type owned, and `ReorderableFramesList` carried its own copy
    // of the identical value; the two are the same measurement, so they are now
    // one declaration rather than two the reader is asked to keep in step.

    // MARK: Container Chrome
    //
    // The outline and shadow now come from `FieldEdgeTreatment`
    // (30_10_FSTextHelpers.swift), shared with `ReorderableFramesList` and with
    // `FixedHeightScrollingTextView`. This list's treatment was the reference
    // for it, so the drawn result is unchanged — the private copy that used to
    // sit here is simply gone, along with the byte-identical copy that sat on
    // the frames list and the mismatched hairline the text view drew.
    //
    // The corner radius and border width still have to agree with each other:
    // the clip below is inset by exactly the width the border occupies, so a
    // change to one without the other reopens the composited edge described at
    // the clip site. Both now come from the same place, which is what keeps
    // them agreeing.

    // The bulk-import control's geometry constants that used to sit here are
    // gone with the control's old position. It is no longer a separate button
    // trailing the table at 22pt — it is a row control inside the add row, at
    // the row-control diameter, and its constants live with the other add-row
    // controls on `StringListAddRow`.

    /// Rows drawn: every entry, plus the trailing add row.
    ///
    /// The add row is unconditional, which is what retired the old "extra short"
    /// empty state. A list with no entries is not a special layout any more —
    /// it is a list of one row that happens to be the add row, so the first
    /// entry a user types changes that row's contents and nothing else about the
    /// table's structure.
    private var displayedRowCount: Int { items.count + 1 }

    private var listHeight: CGFloat {
        ListRowMetrics.listHeight(rowCount: displayedRowCount)
    }

    /// Whether another entry may be added. At the cap the add row stays visible
    /// but inert: its "+" is disabled and grays out, which states the limit
    /// rather than silently removing the control.
    private var canAdd: Bool { items.count < Self.maxItems }

    // MARK: - Body

    // MARK: - Vertical Alignment Tuning
    //
    // The field label and the bulk-import button need different offsets: they
    // have different intrinsic heights and different baselines, so a single
    // shared value cannot put both in line with the list's first row. Each is
    // therefore its own constant, and the two can be adjusted independently.
    //
    // Sign convention: positive moves DOWN, negative moves UP.
    //
    // These were previously pairs — one value for the empty state, one for the
    // populated one — because the inset List applied its internal top padding
    // only when it held rows, so a single constant lined up in one state and not
    // the other. The table now always holds at least the add row, so the padding
    // is always present and the empty-state variants have no state left to
    // describe.

    /// Vertical offset that aligns an adjacent field label with the list's first
    /// row. Exposed statically so the owning tab applies the same rule the
    /// component uses internally, rather than duplicating a constant that could
    /// drift out of step.
    static let labelTopOffset: CGFloat = 14

    // `buttonTopOffset` is gone. It aligned a control sitting BESIDE the table
    // with the table's first row, and no control sits beside either table any
    // more — the frames list read this same constant for its own trailing
    // button and has been moved in step.

    var body: some View {
        // No wrapping HStack any more. Every control this component offers now
        // lives inside the table — the bulk-import button was the last one
        // outside it, and it has moved into the add row alongside the "+" — so
        // the table is the whole component and takes the full column width, the
        // same width every other field on the sheet occupies. The `buttonTopOffset`
        // that aligned the old trailing control with the first row went with it.
        listContainer
        // The `.animation(nil, value: items.isEmpty)` that used to sit here is
        // gone with the state it guarded. It suppressed the interpolation of the
        // simultaneous height change and offset flip that emptying the table
        // produced, which read as the whole field sliding down and snapping
        // back. There is no offset flip any more — emptying the table is now an
        // ordinary row removal, animated exactly like every other one.
        //
        // Scroll detection, done in AppKit rather than in SwiftUI.
        //
        // An `NSPopover` is pinned to the screen rectangle its anchor occupied
        // when it was presented, so scrolling the sheet leaves the bulk-import
        // popover floating over unrelated content. `ScrollActivityObserver`
        // (30_20_FSControlHelpers.swift) watches the enclosing clip view's
        // bounds — a notification AppKit posts for its own purposes — instead of
        // the `GeometryReader` that would otherwise put SwiftUI layout on the
        // live-scroll path, which is precisely what `AppKitScrollView`'s
        // live-scroll suppression exists to prevent.
        //
        // This list has exactly one popover, and the guard means a scroll tick
        // with that popover shut reads a `Bool` and writes nothing — so SwiftUI
        // is not invalidated and no work reaches the view tree.
        .background(
            ScrollActivityObserver {
                if showImportPopover { showImportPopover = false }
            }
        )
        // Raised by `commitAdd` and `commitEdit` when the finished value already
        // exists verbatim. Attached to the component rather than to the row, so
        // it survives the row being rebuilt as the edit resolves.
        .listDuplicateAlert($duplicatePrompt)
    }

    // MARK: - List

    private var listContainer: some View {
        List {
            // Index identity is deliberate. `id: \.self` on the strings would
            // collapse duplicate entries onto a single identity — two identical
            // tags or a repeated crew name are entirely plausible here — which
            // breaks both reordering and row-level state. The cost of index
            // identity is that editing state must be cleared across mutations,
            // which is handled centrally in the mutation helpers below, and that
            // a drafted commit has to be verified against the position it
            // targets before it is applied.
            ForEach(items.indices, id: \.self) { index in
                StringListRow(
                    text: items[index],
                    isEditing: editingIndex == index,
                    editSession: editSession,
                    onBeginEdit: { beginEdit(at: index) },
                    onCommit: { original, newValue in
                        commitEdit(at: index, expecting: original, to: newValue)
                    },
                    onCancel: { original in
                        cancelEdit(at: index, expecting: original)
                    },
                    onDelete: { deleteItem(at: index) }
                )
                .listRowInsets(ListRowMetrics.rowInsets)
            }
            .onMove { source, destination in
                // Editing must end before the move: editingIndex refers to a
                // position, and the move redefines what occupies it. The drag's
                // own mouseDown has normally already ended the edit through the
                // row's click-away monitor, so this is the belt to that braces;
                // any commit that does still arrive afterward is caught by the
                // position check in commitEdit.
                endEditing()
                items.move(fromOffsets: source, toOffset: destination)
            }

            // The add row, outside the `ForEach` and therefore outside `.onMove`
            // — it is not an entry, so it must be neither draggable nor a valid
            // drop destination. Keeping it a sibling rather than an extra
            // iteration of the same `ForEach` is what gives that for free:
            // `.onMove` bounds both the source and the destination to the range
            // its `ForEach` covers.
            StringListAddRow(
                editSession: editSession,
                isAdding: isAdding,
                canAdd: canAdd,
                placeholder: "Add new…",
                itemLabel: itemLabel,
                onBeginAdd: { beginAdd() },
                onCommit: { newValue in commitAdd(newValue) },
                onCancel: { endAdding() },
                showImportPopover: $showImportPopover,
                // Reset here rather than inside the row: these are this type's
                // state, and the row is not given them to write.
                onBeginImport: {
                    // Replace mode is the only mode that can do anything at the
                    // cap, so the popover opens in it and locks it; see
                    // `ListImportPopover.isAtCapacity`.
                    importReplaces = !canAdd
                },
                importPopover: { importPopoverContent }
            )
            // Brings this row back into the viewport after a commit pushes it
            // down. Attached here rather than inside `StringListAddRow` because
            // the token belongs to the list, which is what knows an entry was
            // appended. A background contributes no layout and consumes no
            // events, so the row is unaffected.
            .background(ListAddRowRevealer(token: addRevealToken))
            .listRowInsets(ListRowMetrics.rowInsets)
        }
        // List style, sizing, clip, border, and shadow — one modifier, shared with the
        // frames and text lists so all three tables are drawn identically and,
        // just as importantly, in the same order. The sequence is load-bearing:
        // sizing before the clip is what stops the last alternating background
        // band's overhang from escaping it, and the clip's inset is what keeps
        // the translucent border from compositing over that fill into a
        // distinctly darker bottom edge. The full account is on
        // `listContainerChrome(height:)` (30_20_FSControlHelpers.swift).
        .listContainerChrome(height: listHeight)
        // The empty-state placeholder overlay that used to sit here is gone: the
        // placeholder is now the add row's own label, so it is a real row with
        // the list's own leading inset rather than an overlay that had to
        // reproduce that inset by hand.
    }

    // MARK: - Bulk Import

    /// Content for the bulk-entry popover, handed to the add row, which owns the
    /// control it is anchored to.
    ///
    /// The control moved into the row; the state and the commit did not. The
    /// presentation flag, the replace toggle, and `commitImport` all stay on this
    /// type, because the array is here and the
    /// cap is here. The row supplies an anchor and a click — it is not given the
    /// list to mutate.
    private var importPopoverContent: some View {
        ListImportPopover(
            itemLabel: itemLabel,
            maxItems: Self.maxItems,
            // One count, from which the popover derives both the append-mode
            // headroom and the two locked states of its Replace toggle. It used
            // to receive `isAtCapacity` and `hasEntries` as separate booleans,
            // which was three descriptions of one array that had to agree.
            currentCount: items.count,
            replaces: $importReplaces,
            onImport: { parsed in
                // Dismiss, then commit once the popover has finished closing.
                // An import changes the row count, which moves this popover's own
                // anchor — see `ListPopoverDismissal`.
                showImportPopover = false
                ListPopoverDismissal.afterClose { commitImport(parsed) }
            },
            onCancel: { showImportPopover = false }
        )
    }

    // MARK: - Import Popover

    // Parsing lives entirely on `ListImportPopover.parseItems(from:)`, which is
    // what the popover itself calls and what hands the result back through
    // `onImport`. The forwarding wrapper that used to sit here had no callers.

    // MARK: - Mutation Helpers
    //
    // Every mutation that can invalidate `editingIndex` routes through one of
    // these, so the clearing rule is stated once rather than at each call site.

    /// Opens the add row's text field.
    ///
    /// No placeholder element is appended to the array. The old "+" button
    /// appended an empty string and then edited it, which meant every route out
    /// of a canceled add had to remember to remove that blank entry again — and
    /// meant a blank row could survive into the model if any of them did not.
    /// The add row exists in the view only, so a canceled add is a no-op on the
    /// array by construction.
    private func beginAdd() {
        guard canAdd, !isAdding else { return }
        // Clearing `editingIndex` ends any open row edit through the row's own
        // `onChange(of: isEditing)`, which DISCARDS its draft — the rule every
        // unconfirmed exit follows, since only Return and the pencil save. That
        // is the same path used when the edit is retargeted from one row to
        // another.
        editingIndex = nil
        isAdding = true
        editSession &+= 1
        // Focus is deliberately NOT assigned here: the add row's field claims
        // first responder itself, against the window, and verifies that the
        // claim took. See `EditingTextField`.
    }

    /// Appends the drafted entry and returns the add row to its placeholder
    /// state, so the next add starts from a fresh, unfocused row.
    ///
    /// A draft that trims to nothing is discarded rather than stored, matching
    /// `commitEdit`: an empty string would render as a blank row and round-trip
    /// into the model as noise.
    private func commitAdd(_ newValue: String) {
        isAdding = false
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-checked rather than trusted from the button's enablement: the cap
        // is a limit on the model, not merely a UI rule.
        guard !trimmed.isEmpty, items.count < Self.maxItems else { return }
        // An exact duplicate is confirmed rather than refused — see
        // `ListDuplicateCheck`. The append is deferred whole, so the confirmed
        // path and the immediate one are the same code and the cap is re-checked
        // either way.
        confirmingDuplicate(trimmed, prompt: ListDuplicatePrompt { appendCommitted(trimmed) })
    }

    /// The append itself, shared by the immediate and confirmed paths.
    ///
    /// The cap is checked again here rather than only in `commitAdd`: on the
    /// confirmed path an alert stood between the two, and while a modal alert
    /// leaves no route to add an entry elsewhere, the guard costs nothing and
    /// keeps this method safe to call from either.
    private func appendCommitted(_ trimmed: String) {
        guard items.count < Self.maxItems else { return }
        items.append(trimmed)
        // Only on a write that actually grew the table. A draft that trimmed to
        // nothing, or one rejected at the cap, leaves the add row where it was,
        // and scrolling for it would move the viewport for no visible reason.
        addRevealToken &+= 1
    }

    /// Runs `write` immediately, or parks it behind a confirmation when the
    /// finished value already exists verbatim.
    ///
    /// Bulk import deliberately does NOT route through here: a pasted list is
    /// reviewed as a whole before it is imported, and interrupting it once per
    /// repeated entry would make the control unusable.
    /// The pending write is handed over already wrapped in a
    /// `ListDuplicatePrompt` rather than as a bare closure. That is not
    /// decoration: a function type's own closure parameter cannot be marked
    /// `@escaping` when the function type is stored — which the frames and text
    /// tables must do, since their rows call this through a stored callback —
    /// so a bare closure arriving that way is non-escaping and cannot be parked
    /// in `@State`. A closure held as a property of a struct is escaping by
    /// construction, so passing the prompt itself sidesteps the restriction
    /// entirely, and all three tables use the one signature.
    private func confirmingDuplicate(_ candidate: String,
                                     excluding index: Int? = nil,
                                     prompt: ListDuplicatePrompt) {
        if ListDuplicateCheck.isDuplicate(candidate, in: items, excluding: index) {
            duplicatePrompt = prompt
            ListPopoverDismissal.noteDeferredPrompt()
        } else {
            prompt.confirm()
        }
    }

    private func endAdding() {
        isAdding = false
    }

    private func beginEdit(at index: Int) {
        guard items.indices.contains(index) else { return }
        // Mutually exclusive with the add row; see `isAdding`. The add row's own
        // `onChange` discards its draft when this clears the flag.
        isAdding = false
        editingIndex = index
        editSession &+= 1
    }

    /// Writes the drafted text back to the array. An entry trimmed to nothing is
    /// removed rather than stored: an empty string would render as a blank,
    /// undraggable-looking row and would round-trip into the model as noise.
    ///
    /// Deliberately NOT guarded on `editingIndex == index`. A commit is drafted,
    /// so it necessarily arrives after the interaction that ended the edit, and
    /// that interaction may already have retargeted `editingIndex` — the click
    /// monitor's two-phase dispatch runs every begin-edit before any of the
    /// resolutions those begins displaced. A guard on the current editing row
    /// would therefore discard a legitimately confirmed edit. The row itself
    /// enforces at-most-once commit per edit session, so idempotency is handled
    /// there rather than here, and the `expecting` check below is what makes the
    /// unguarded write safe.
    ///
    /// `expecting` is the value the row was seeded with when the edit began, and
    /// it is what makes an index-identified commit safe. A commit is always
    /// delivered after the interaction that ended the edit, so the array may
    /// have shifted underneath it in the meantime — a reorder, a delete
    /// elsewhere in the list, or a Replace-mode import. Without the check the
    /// draft would be written over whatever now occupies that position, which is
    /// silent data loss. If the slot no longer holds the seeded value the commit
    /// is stale by definition and is dropped.
    private func commitEdit(at index: Int, expecting original: String, to newValue: String) {
        // Only surrender editing state if this row is still the one holding it.
        if editingIndex == index { endEditing() }

        guard items.indices.contains(index), items[index] == original else { return }

        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items.remove(at: index)
            shiftEditingIndex(afterRemovalAt: index)
        } else if items[index] != trimmed {
            // The row's own value is excluded from the comparison — an edit that
            // did not change the text never reaches here, but an edit that
            // changed it to match a DIFFERENT row is exactly the case worth
            // catching. Canceling leaves the array untouched, so the row simply
            // redraws the value it held.
            confirmingDuplicate(trimmed,
                                excluding: index,
                                prompt: ListDuplicatePrompt {
                                    applyEdit(at: index, expecting: original, to: trimmed)
                                })
        }
    }

    /// The single-slot write, shared by the immediate and confirmed paths.
    ///
    /// Position-verified again rather than relying on the check `commitEdit`
    /// already made: on the confirmed path an alert stood between the two, so
    /// the guard is what keeps a deferred write from landing on a slot that no
    /// longer holds what the edit began on.
    private func applyEdit(at index: Int, expecting original: String, to trimmed: String) {
        guard items.indices.contains(index), items[index] == original else { return }
        items[index] = trimmed
    }

    /// Discards the edit, dropping the row if it was blank to begin with.
    ///
    /// The removal no longer has anything to do with canceling an add — the add
    /// row is not backed by an array element, so an abandoned add leaves nothing
    /// behind to clean up. What remains is the defensive case: a blank entry
    /// that reached the array by some other route (older data, a restore) should
    /// not survive being opened and dismissed, because an empty string renders as
    /// a blank, undraggable-looking row.
    ///
    /// Position-verified on the same terms as `commitEdit`, and blankness is
    /// judged on the seeded value rather than the live one, so that a draft the
    /// user typed and then abandoned with Escape cannot be mistaken for one.
    private func cancelEdit(at index: Int, expecting original: String) {
        if editingIndex == index { endEditing() }

        guard items.indices.contains(index),
              items[index] == original,
              original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        items.remove(at: index)
        shiftEditingIndex(afterRemovalAt: index)
    }

    private func deleteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        // Clear editing only when deleting the row being edited. Blanket
        // clearing would drop an unrelated in-flight edit on the floor.
        if editingIndex == index { endEditing() }
        items.remove(at: index)
        shiftEditingIndex(afterRemovalAt: index)
    }

    /// Keeps `editingIndex` pointing at the same logical item after a removal
    /// earlier in the array. Without this, deleting row 2 while row 5 is being
    /// edited would leave the edit targeting what is now row 6.
    private func shiftEditingIndex(afterRemovalAt removed: Int) {
        guard let current = editingIndex, current > removed else { return }
        editingIndex = current - 1
    }

    /// The cap-and-replace rule is `ListImportCommit`'s, shared with the frames
    /// and text lists. Resolving before writing is what keeps this a single
    /// array write — one observation invalidation, one change-tracking pass —
    /// and what leaves a rejected batch writing nothing at all.
    ///
    /// `endEditing` is ordered after the resolve so a rejected import does not
    /// close an open field the user is still working in.
    private func commitImport(_ parsed: [String]) {
        guard let updated = ListImportCommit.resolved(parsed,
                                                      into: items,
                                                      replacing: importReplaces,
                                                      cap: Self.maxItems)
        else { return }
        endEditing()
        // Measured before the write, so the comparison is against the array the
        // import is replacing rather than the one it produced.
        let grew = updated.count > items.count
        items = updated
        // The add row moves down by one row per entry gained, so a bulk import
        // can push it well below the fold — further than a single commit ever
        // does, which is the case this reveal was built for. Only on growth: a
        // Replace-mode import that shrinks the table moves the add row UP, and
        // scrolling to it then would drag the viewport for no reason.
        if grew { addRevealToken &+= 1 }
    }

    /// Closes whichever field is open — a row's or the add row's.
    ///
    /// Both are cleared rather than only `editingIndex` because every caller
    /// means "no field should be open after this": a move, a delete, a stale
    /// commit landing, or a bulk import replacing the contents. They are
    /// mutually exclusive, so clearing the one that was already closed costs
    /// nothing.
    private func endEditing() {
        editingIndex = nil
        isAdding = false
    }
}

// MARK: - Labeled List Row

/// A field label paired with a `ReorderableStringList` and its scroll anchor —
/// the unit both the Metadata and Notes tabs are built out of.
///
/// **Why this is a type and not three lines inlined in the tab's body**
///
/// It is an observation boundary. Inlined, each list's `items:` argument was a
/// `Binding` constructed in the tab's body, and the label beside it read
/// `viewModel.someArray.count` there too. Both consequences were bad: the tab's
/// body was tracking every array on the tab, so committing an entry in one list
/// invalidated the tab; and `Binding` carries closures, which never compare
/// equal, so once the tab's body re-ran every list was rebuilt along with it —
/// eleven `List`s and all of their rows, for a keystroke in an unrelated text
/// field.
///
/// Here the array is reached through a key path instead. The tab's body no
/// longer touches it, and this view's stored properties are all values or plain
/// references, so SwiftUI can compare one against its predecessor and skip the
/// body outright when nothing this row depends on has moved. What remains is
/// `@Observable`'s own property-level tracking: a change to `cast` invalidates
/// the row showing `cast`, and nothing else.
///
/// Generic over the view model so the Metadata and Notes tabs share it rather
/// than each carrying a copy specialized to its own type.
///
/// It also serves both list editors. The Notes tab's Warnings and Notes use
/// `ReorderableTextList` (30_50_FSTextList.swift) — long, multi-line values edited
/// in a popover — while every other list uses the inline `ReorderableStringList`.
/// Those two rows were once two copies of this type, identical but for the list
/// they built. `editor` is a plain enum rather than a view-builder closure so the
/// row still compares by value (see above).
struct FilmSheetListRow<Model: AnyObject & Observable>: View {

    @Bindable var model: Model

    /// The array this row edits. A key path rather than a `Binding` so the
    /// enclosing tab's body never reads the array — see the note above.
    let keyPath: ReferenceWritableKeyPath<Model, [String]>

    /// Label shown while the list holds no more than one entry, colon included.
    let singularLabel: String
    /// Label shown from the second entry onward. Pass the same string as
    /// `singularLabel` for fields that do not pluralize.
    ///
    /// Both are supplied fully formed rather than derived from a noun and a
    /// lookup table, so this view stores two plain `String`s and stays cheap to
    /// compare.
    let pluralLabel: String

    /// Singular noun the list uses in its own popovers and placeholder.
    let itemLabel: String

    // The `anchorID` and `scrollProxy` this row used to carry are gone. They
    // existed only so that adding an entry could scroll the list into view when
    // the "+" button beside its top edge had been clicked while the newly
    // appended row was below the fold. The add control is now the list's last
    // row, which cannot be clicked from outside the viewport, so neither the
    // anchor nor the proxy has anything left to do.

    let labelWidth: CGFloat
    let columnSpacing: CGFloat

    /// Which build wave this row's *list* belongs to; the label is always drawn
    /// immediately. `0` — the default, and what every call site outside the
    /// Metadata tab uses — builds the list synchronously, exactly as before.
    ///
    /// A tab that stacks many of these carries far more list than fits in the
    /// sheet's 600pt viewport, and every one of them is an AppKit scroll view
    /// built before the tab's first frame is shown. Rows that cannot be on screen
    /// at that moment are given a non-zero wave so their construction lands a few
    /// frames later instead; see `DeferredFieldContent`
    /// (30_20_FSControlHelpers.swift) for the full account, including why the
    /// stand-in's height is stated rather than measured.
    ///
    /// Declared last so the existing memberwise call sites are unaffected.
    var renderWave: Int = 0

    /// Which list edits the entries. Fixed per call site, so the branch in `body`
    /// never flips and the list's identity is stable.
    var editor: FilmSheetListEditor = .inline

    var body: some View {
        let count = model[keyPath: keyPath].count

        HStack(alignment: .top, spacing: columnSpacing) {
            FilmSheetFieldLabel(count <= 1 ? singularLabel : pluralLabel,
                                width: labelWidth)
                // .offset rather than .padding: the alignment constants are
                // signed, so either element can be nudged upward, which padding
                // cannot express.
                .offset(y: ReorderableStringList.labelTopOffset)

            // The stand-in's height is the same expression both lists hand to
            // `listContainerChrome(height:)` — entry count plus the unconditional
            // trailing add row — so the swap cannot move anything.
            // Read from the same `count` the label above already reads, so this
            // adds no observation and no second array access.
            DeferredFieldContent(
                wave: renderWave,
                placeholderHeight: ListRowMetrics.listHeight(rowCount: count + 1)
            ) {
                switch editor {
                case .inline:
                    ReorderableStringList(items: $model[dynamicMember: keyPath],
                                          itemLabel: itemLabel)
                case .popover:
                    ReorderableTextList(items: $model[dynamicMember: keyPath],
                                        itemLabel: itemLabel)
                }
            }
        }
    }
}

/// The list a `FilmSheetListRow` builds.
enum FilmSheetListEditor {
    /// `ReorderableStringList`: short values edited in place.
    case inline
    /// `ReorderableTextList`: long, multi-line values edited in a popover.
    case popover
}

// MARK: - Row Edit Buffer

/// Scratch storage for one row's in-progress edit.
///
/// A reference type rather than a set of `@State` properties, for two reasons.
///
/// First, seeding. The values have to be in place the moment the editor appears,
/// and a `@State` write cannot be made from within the same update that creates
/// the view — which is why the previous implementation seeded from `.task` and
/// therefore always seeded one turn late. A class can be written directly from
/// `makeNSView`, so the draft, the baseline, and the resolution flag are all
/// correct before the field draws a single frame.
///
/// Second, cost. The draft is written on every keystroke but read only when the
/// edit resolves; storing it in `@State` invalidated the row on each character
/// for a value nothing was displaying. Mutating a class does not invalidate
/// anything, so typing now performs no SwiftUI work at all.
///
/// Not `Sendable`, and deliberately so: it is main-actor-only by construction,
/// reached solely from view bodies and AppKit callbacks on the main thread.
private final class RowEditBuffer {
    /// The array value this edit session started from. Handed back on resolve so
    /// the parent can confirm the targeted position still holds it.
    var original: String = ""
    /// Live text, kept current by the field's delegate.
    var current: String = ""
    /// At-most-once guard for a single edit session. Several paths can
    /// legitimately end an edit — Return, focus leaving, the parent retargeting
    /// `editingIndex`, a click elsewhere in the sheet — and each must be able to
    /// fire without the others double-writing. Starts `true` so a row that has
    /// never entered edit mode can never resolve, which would delete it.
    var isResolved: Bool = true
}

// MARK: - Editing Field

/// The `NSTextField` used while a row is being edited, with an explicit,
/// self-verifying first-responder claim.
///
/// **Why this is not a SwiftUI `TextField` with `@FocusState`**
///
/// The component previously used `TextField(...).focused($isFocused)`, owned by the
/// row. That had a durable failure mode: when a row was destroyed *while its field
/// held focus*, its `@FocusState` storage went away with it, so SwiftUI never
/// observed the focused → unfocused transition and the focus scope was left
/// resolved against a field that no longer existed. Every later `isFocused = true`
/// in that scope was then treated as a request the scope believed it had already
/// granted, and was silently — and permanently — dropped for the life of the sheet.
///
/// That matches the reported bug exactly. Committing a *non-empty* edit leaves the
/// row in place, so its focus state survives and the scope unwinds cleanly — which
/// is why committing never broke anything. Every route that *cancels* an add
/// (Escape, the delete button, clicking away with a blank draft) ends by removing
/// the row while the field is still focused, so the first cancel poisons the scope.
///
/// Rather than keeping SwiftUI's focus bookkeeping balanced across a teardown it
/// can't observe, this type removes the bookkeeping entirely: the field asks the
/// window to make it first responder, confirms it actually became first responder,
/// and retries on the next run-loop turn if not. The claim is made against the live
/// `NSWindow`, unaffected by any previous edit session, and idempotent per session
/// token so it can be driven from both `makeNSView` and `viewDidMoveToWindow`
/// without double-firing.
///
/// Behavior otherwise maps one-for-one onto the first-party `NSTextFieldDelegate`
/// hooks: Return → `insertNewline:`, Escape → `cancelOperation:`, focus leaving →
/// `controlTextDidEndEditing`.
private struct EditingTextField: NSViewRepresentable {

    /// Value the edit starts from. Written into the buffer and the field
    /// synchronously, so there is no frame in which the editor shows stale or
    /// empty text.
    let seed: String
    let buffer: RowEditBuffer
    /// Identifies the edit session. A change re-seeds and re-claims focus; an
    /// unchanged value is a no-op. See `ReorderableStringList.editSession`.
    let focusToken: Int

    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Editing ended by some route other than Return or Escape — tabbing away,
    /// a popover taking focus, the field being torn down.
    let onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusClaimingTextField {
        let field = FocusClaimingTextField(frame: .zero)
        field.delegate = context.coordinator

        // Matches SwiftUI's `.squareBorder` style, which is itself a bezeled
        // NSTextField with the square bezel — so the row's metrics and text
        // position are unchanged by the switch to explicit AppKit.
        // isBordered and isBezeled are mutually exclusive on NSTextField —
        // setting either clears the other — so the plain border is cleared
        // first and the bezel established second.
        field.isBordered = false
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.focusRingType = .default
        field.font = .systemFont(ofSize: 12)
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        // The row supplies the width and height; the field must not fight it.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        context.coordinator.seedIfNeeded(token: focusToken, seed: seed)
        field.stringValue = seed
        field.focusToken = focusToken
        return field
    }

    func updateNSView(_ nsView: FocusClaimingTextField, context: Context) {
        // Rows are index-identified, so a row's view can in principle be reused
        // across a change of session. Refreshing the callbacks and re-seeding on
        // a token change keeps a reused field correct rather than relying on it
        // never being reused.
        context.coordinator.parent = self
        if context.coordinator.seedIfNeeded(token: focusToken, seed: seed) {
            nsView.stringValue = seed
        }
        nsView.focusToken = focusToken
    }

    /// Fills the width it is offered and keeps its natural height.
    ///
    /// The height is deliberately the control's own: a bezeled field has a fixed
    /// natural height, and forcing it to the row's nominal content height would
    /// shave a point off the bezel and clip the text's descenders. The row's
    /// `HStack` already fixes the row height, so the field sits within it
    /// exactly as the SwiftUI `.squareBorder` field did.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: FocusClaimingTextField,
                      context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = intrinsic.width
        }
        return CGSize(width: width, height: intrinsic.height)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {

        var parent: EditingTextField
        /// Session the buffer currently holds, so seeding runs once per session
        /// regardless of how many update passes the field receives.
        private var seededToken: Int?

        init(_ parent: EditingTextField) { self.parent = parent }

        /// Establishes the buffer for `token`. Returns `true` when it actually
        /// seeded, which is the caller's cue to push the seed into the field.
        @discardableResult
        func seedIfNeeded(token: Int, seed: String) -> Bool {
            guard seededToken != token else { return false }
            seededToken = token
            parent.buffer.original = seed
            parent.buffer.current = seed
            parent.buffer.isResolved = false
            return true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Straight into the buffer — no SwiftUI state is touched, so typing
            // costs nothing beyond the keystroke itself.
            parent.buffer.current = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Deferred by one main-queue turn. This notification is posted
            // synchronously when AppKit tears the field down, which happens
            // *inside* a SwiftUI update — and the handler mutates the bound
            // array. Hopping past the update keeps the mutation out of it.
            //
            // Safe to defer because resolution is idempotent: whichever path
            // actually ended the edit has normally already resolved it, in which
            // case this is a no-op, and if none has, the parent's own
            // position check guards the late write.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.parent.onEndEditing()
                }
            }
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // The field editor holds the authoritative text until editing
                // ends, so read it rather than the cell.
                parent.buffer.current = textView.string
                parent.onSubmit()
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true

            default:
                // Tab and everything else stay with AppKit; leaving the field by
                // Tab ends editing and is picked up by controlTextDidEndEditing.
                return false
            }
        }
    }
}

/// `NSTextField` that claims first responder for a given session and verifies
/// that the claim took.
///
/// The verification is the point. A first-responder request placed before the
/// view is in a window is simply dropped, and one placed during a window state
/// transition can fail outright — both cases return quietly, leaving the field
/// unfocused with nothing to indicate it. Confirming against
/// `window.firstResponder` and retrying turns a request that may or may not have
/// landed into one that either succeeds or exhausts a bounded budget.
private final class FocusClaimingTextField: NSTextField, FilmSheetReturnHandlingField {

    /// Attempts are cheap (one run-loop turn each) and the budget only needs to
    /// outlast view insertion and window attachment, which take one or two.
    /// Entering a window resets it, so this bounds a single stretch of retries
    /// rather than the field's lifetime.
    private static let maxAttempts = 12

    /// Session to claim focus for. Assigning a new value starts a claim;
    /// re-assigning the same value does nothing.
    var focusToken: Int = .min {
        didSet {
            guard focusToken != oldValue else { return }
            beginFocusClaim()
        }
    }

    /// Session for which focus has been confirmed. Guards every path, so the
    /// claim is idempotent no matter how many times it is driven.
    private var satisfiedToken: Int?
    private var attemptsRemaining = 0
    private var retryScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The authoritative moment: a field that could not take focus because it
        // had no window now has one.
        guard unsafe window != nil else { return }
        beginFocusClaim()
    }

    private func beginFocusClaim() {
        guard satisfiedToken != focusToken else { return }
        attemptsRemaining = Self.maxAttempts
        attemptFocus()
    }

    private func attemptFocus() {
        guard satisfiedToken != focusToken else { return }
        guard attemptsRemaining > 0 else { return }
        attemptsRemaining -= 1

        guard let window = unsafe window else {
            // Not in a window yet. viewDidMoveToWindow will restart the claim
            // with a fresh budget; the retry below covers the case where the
            // insertion happens within the same run-loop turn.
            scheduleRetry()
            return
        }

        if isFirstResponderOrEditing(in: window) {
            satisfiedToken = focusToken
            return
        }

        if window.makeFirstResponder(self), isFirstResponderOrEditing(in: window) {
            satisfiedToken = focusToken
            // Matches the selection behavior of a SwiftUI TextField receiving
            // focus: the existing value is selected, so typing replaces it.
            currentEditor()?.selectAll(nil)
            return
        }

        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !retryScheduled, attemptsRemaining > 0 else { return }
        retryScheduled = true
        // A run-loop hop rather than a Task: this has to land after AppKit
        // finishes the view-insertion or window-attachment work that caused the
        // first attempt to fail, and the main queue orders against that work.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryScheduled = false
                self.attemptFocus()
            }
        }
    }

    /// True when this field owns the keyboard — either directly or, once editing
    /// has begun, through the window's shared field editor.
    private func isFirstResponderOrEditing(in window: NSWindow) -> Bool {
        if window.firstResponder === self { return true }
        if let editor = currentEditor(), window.firstResponder === editor { return true }
        return false
    }
}

// MARK: - StringListRow

/// A single row of `ReorderableStringList`.
///
/// Extracted as its own struct so SwiftUI can assign each row a stable node and
/// skip re-evaluating rows whose inputs have not changed — inlining the row into
/// the parent's `ForEach` would re-run every row's content on any parent state
/// change, including each keystroke in an unrelated row.
private struct StringListRow: View {

    let text: String
    let isEditing: Bool
    /// Changes on every edit begin; see `ReorderableStringList.editSession`.
    let editSession: Int

    let onBeginEdit: () -> Void
    /// Receives the value the row was seeded with and the drafted replacement.
    /// The parent uses the former to confirm the row still occupies the position
    /// the commit is addressed to.
    let onCommit: (_ original: String, _ newValue: String) -> Void
    /// Receives the seeded value, for the same position check.
    let onCancel: (_ original: String) -> Void
    let onDelete: () -> Void

    // Row control geometry comes from `ListRowMetrics`. Diameter and glyph size
    // are separate values there so the symbol's optical weight and the row's
    // layout stay independent, and both are shared with `PairedFramesListRow`,
    // whose controls sit in the same column on the same sheet.

    /// Draft, baseline, and resolution flag for this row's edit.
    ///
    /// Deliberately not `@FocusState` + `@State`. Focus is claimed by the field
    /// itself against the window, and the draft lives in a reference the field
    /// can seed synchronously — see `EditingTextField` for why the previous
    /// SwiftUI-focus arrangement failed permanently after the first canceled
    /// add.
    ///
    /// The buffer belongs to the row rather than the field so that it outlives
    /// the field: an edit is resolved by whichever path ends it, and several of
    /// those paths (the pencil button, a click elsewhere in the sheet, the
    /// parent retargeting the edit) run at moments when the field is already
    /// being torn down.
    @State private var buffer = RowEditBuffer()

    /// Bounds of this row's trailing controls, so a double-click on one of them
    /// is not also read as a double-click on the row. See
    /// `RowClickReporter.controlsRegion`.
    @State private var controlsRegion = ClickExclusionRegion()

    /// Writes the draft back through the parent, at most once per edit session.
    private func commitIfNeeded() {
        guard !buffer.isResolved else { return }
        buffer.isResolved = true
        onCommit(buffer.original, buffer.current)
    }

    /// Discards the draft, at most once per edit session. Resolving first is
    /// what stops the teardown that follows from writing the value back.
    private func cancelIfNeeded() {
        guard !buffer.isResolved else { return }
        buffer.isResolved = true
        onCancel(buffer.original)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                // A bezeled NSTextField with the square bezel — the same control
                // `.squareBorder` wraps, so the row's geometry and text position
                // are unchanged, but with an explicit, verified first-responder
                // claim in place of `@FocusState`. See `EditingTextField`.
                EditingTextField(
                    seed: text,
                    buffer: buffer,
                    focusToken: editSession,
                    // Return.
                    onSubmit: { commitIfNeeded() },
                    // Escape.
                    onCancel: { cancelIfNeeded() },
                    // Focus left the field by a route that has not already
                    // resolved the edit — tabbing away, most commonly.
                    //
                    // Discarding rather than saving is deliberate, and it is the
                    // rule for every unconfirmed exit: an edit is committed only
                    // by Return or by the pencil. Escape, the delete button, and
                    // a click anywhere outside the field all cancel, so the two
                    // confirming gestures are the whole of the save vocabulary
                    // and there is nothing to remember about which exit means
                    // what. `StringListAddRow` follows the identical rule.
                    // Resolved paths make this a no-op.
                    onEndEditing: { cancelIfNeeded() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Matches the inset that .squareBorder applies to its own
                    // text, so the glyphs stay put when the row flips into edit
                    // mode instead of nudging sideways as the field appears.
                    .padding(.leading, ListRowMetrics.fieldTextInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Delete, then edit — the delete control leads, and it is present
            // ONLY while the row is being edited.
            //
            // Gating it on the edit state is what makes a resting table read as
            // a list rather than as a bank of destructive controls: at rest each
            // row offers one affordance, the pencil, and destruction is
            // something the user has to open the row to reach. The pencil is
            // last, so it holds the trailing edge in both states and does not
            // shift when its neighbor appears; the text simply yields the width.
            // Grouped so their combined bounds can be published in one region.
            // Individually captured, the gap between them would not be covered,
            // and a double-click landing in it would still reach the row.
            HStack(spacing: 8) {
                if isEditing {
                    ListCircleButton(
                        systemImage: "minus",
                        fill: Preferences.red,
                        diameter: ListRowMetrics.circleDiameter,
                        glyphSize: ListRowMetrics.circleGlyphSize,
                        help: "Delete this entry",
                        role: .destructive,
                        glyphOffset: ListCircleButtonStyle.minusGlyphOffset,
                        // Opt+Delete, bound to the control rather than layered
                        // over it, so the key equivalent lands on the button
                        // directly. See `ListCircleButton.shortcut`.
                        shortcut: KeyboardShortcut(.delete, modifiers: .option),
                        action: {
                            // Resolve the edit before deleting, so the teardown
                            // that follows cannot also act on it. Tearing the
                            // field down drops focus, which fires the
                            // end-editing path; marking the edit resolved here
                            // is what keeps that a no-op.
                            //
                            // On this row the control deletes the entry rather
                            // than merely abandoning the edit — it is the
                            // table's only route to removing a row, and there is
                            // nowhere else to put it. It still satisfies the
                            // rule that only Return and the pencil save: what
                            // was typed is discarded either way.
                            buffer.isResolved = true
                            onDelete()
                        }
                    )
                    // The Opt+Delete binding above is scoped entirely by this
                    // control's own lifetime: the "-" exists only while its row
                    // is being edited, so at rest nothing claims the key, and at
                    // most one row across the sheet is in edit mode at a time
                    // (any route into editing another row is a click, which the
                    // click monitor reads as a click-away and resolves the open
                    // edit first).
                    //
                    // A key equivalent rather than an event monitor is also what
                    // makes it beat the field editor:
                    // `performKeyEquivalent(with:)` runs before the responder
                    // chain sees `keyDown`, so the focused `NSTextField` never
                    // interprets the event as its default "delete word
                    // backward". `KeyboardManager` is what lets it reach the
                    // window at all — it now passes Opt+Delete through inside a
                    // sheet rather than consuming it.
                }

                // From the shared factory so the row controls and the table's
                // other circular controls stay in visual lockstep. `isActive`
                // while its row is being edited, which holds the accent fill for
                // the duration rather than only while the mouse is down.
                ListCircleButton(
                    systemImage: "pencil",
                    fill: Color.gray.opacity(0.5),
                    diameter: ListRowMetrics.circleDiameter,
                    glyphSize: ListRowMetrics.circleGlyphSize,
                    isActive: isEditing,
                    help: isEditing ? "Save this entry" : "Edit this entry",
                    action: {
                        if isEditing {
                            commitIfNeeded()
                        } else {
                            onBeginEdit()
                        }
                    }
                )
            }
            .background(ClickExclusionCapture(region: controlsRegion))
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
        // Double-click to edit, detected via a local NSEvent monitor rather
        // than a SwiftUI gesture. See `RowClickReporter` for why every
        // gesture-based approach broke drag-to-reorder. The reporter is a
        // background view: it contributes no layout and consumes no events, so
        // the row remains draggable across its entire width.
        .background(
            RowClickReporter(
                isEditing: isEditing,
                onDoubleClickInside: {
                    if !isEditing { onBeginEdit() }
                },
                onClickOutside: {
                    // Discards the edit for a click anywhere else in the sheet,
                    // including on chrome that never takes first responder and
                    // so would not otherwise resign focus.
                    cancelIfNeeded()
                },
                controlsRegion: controlsRegion
            )
        )
        // Resolves the edit if the row leaves editing state by any route that
        // has not already done so — for example the parent retargeting the edit
        // to a different row, or opening the add row.
        .onChange(of: isEditing) { _, editing in
            if !editing { cancelIfNeeded() }
        }
    }
}

// The private `AddRowMetrics` namespace that used to sit here is gone. It held
// this file's second copy of the row-control geometry — a copy that existed only
// because `StringListAddRow` is generic and Swift does not permit static stored
// properties in a generic type. `ListRowMetrics` (30_20_FSControlHelpers.swift)
// is a non-generic namespace, so it satisfies that language rule as well, and it
// does so with one declaration instead of the three this file and the frames
// list carried between them.

// MARK: - StringListAddRow

/// The table's trailing row: a placeholder until the user chooses to add, and an
/// entry field once they do.
///
/// **Why the add control is a row**
///
/// It used to be a "+" button beside the table, with an empty table collapsing to
/// a shorter "Add item…" well. Both are gone — the control that creates a row now
/// IS a row, drawn with the same metrics and circular button family as every other
/// row, so the table has exactly one resting appearance: n entries followed by an
/// invitation to add the next one.
///
/// Knock-on effects worth stating, since each deleted code rather than adding it:
///
///   - No empty state: a table with no entries is one row tall, so the paired
///     label and bulk-import button no longer need two alignment constants each.
///   - No scroll-into-view: the old button sat level with the table's TOP edge and
///     could be clicked while the row it appended was below the fold — what the
///     `FilmSheetScrollProxy` bridge existed to correct. This row can't be clicked
///     unless already visible, and it's the row that changes.
///   - No placeholder entry in the model: the old flow appended `""` and edited
///     it, so every cancel path had to remember to remove it. Nothing is written
///     to the array until a non-empty draft is committed.
///
/// **Why it is a separate type from `StringListRow`**
///
/// The two share metrics and chrome but nothing else. This row has no backing
/// array element, so no seeded value to position-verify a commit against, no
/// delete, and no drag identity; its commit appends and its cancel is a true
/// no-op. Folding the two together would mean one type whose every branch asked
/// which of the two it currently was.
///
/// **Generic over its popover's content**
///
/// Generic rather than taking an `AnyView` or the seven parameters
/// `ListImportPopover` needs — the row's job is to place a control and anchor a
/// popover to it, and what goes inside is the list's business. This is also why
/// the type declares no constants of its own: Swift disallows static stored
/// properties in a generic type, so its geometry comes from `ListRowMetrics`,
/// which is where the frames list's identical values live too.
private struct StringListAddRow<ImportPopover: View>: View {

    /// Changes on every add begin; see `ReorderableStringList.editSession`. Also
    /// the field's focus token.
    let editSession: Int

    /// Whether the field is showing. Owned by the list, for the same reason
    /// `editingIndex` is: it has to be cleared atomically with anything that
    /// opens an edit elsewhere in the table.
    let isAdding: Bool

    /// Whether the table has room for another entry. At the cap the row stays
    /// put and its "+" grays out.
    let canAdd: Bool

    let placeholder: String

    /// Singular noun, used only for the "+" tooltip.
    let itemLabel: String

    let onBeginAdd: () -> Void
    /// Receives the drafted text. Trimming and the empty-draft rule belong to
    /// the list, which owns the array.
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    /// Presentation flag for the bulk-entry popover. Owned by the list — the row
    /// only sets it, and the popover it anchors reads it.
    @Binding var showImportPopover: Bool
    /// Clears the list's draft state before the popover opens.
    let onBeginImport: () -> Void
    @ViewBuilder let importPopover: () -> ImportPopover

    // Geometry lives on `ListRowMetrics` (30_20_FSControlHelpers.swift) rather
    // than on the type itself.
    //
    // Not purely a style preference — it is also a language rule. Swift does not
    // allow static stored properties in a generic type, and this type became
    // generic when the bulk-import control moved into it and brought its popover
    // content along as a type parameter. A non-generic namespace is the standard
    // remedy and costs nothing: these are process-wide constants that never
    // varied by instance, let alone by type argument. Reaching for the shared
    // namespace rather than a private one is what additionally guarantees the
    // "+" here is the same size as the frames list's.

    /// Draft and resolution flag for the add in progress. Its `original` is
    /// unused here — there is no array slot to verify against — but the type is
    /// shared with `StringListRow` because `EditingTextField` writes into it.
    @State private var buffer = RowEditBuffer()

    /// Bounds of this row's trailing controls, so a double-click on one of them
    /// is not also read as a double-click on the row. See
    /// `RowClickReporter.controlsRegion`.
    @State private var controlsRegion = ClickExclusionRegion()

    /// Hands the draft to the list, at most once per add session.
    private func commitIfNeeded() {
        guard !buffer.isResolved else { return }
        buffer.isResolved = true
        onCommit(buffer.current)
    }

    /// Discards the draft, at most once per add session.
    private func cancelIfNeeded() {
        guard !buffer.isResolved else { return }
        buffer.isResolved = true
        onCancel()
    }

    var body: some View {
        HStack(spacing: 8) {
            if isAdding {
                EditingTextField(
                    seed: "",
                    buffer: buffer,
                    focusToken: editSession,
                    onSubmit: { commitIfNeeded() },
                    // Escape.
                    onCancel: { cancelIfNeeded() },
                    // Focus left the field by a route that has not already
                    // resolved the add — tabbing away, most commonly. Canceling
                    // rather than committing is deliberate: an add is confirmed
                    // explicitly, by Return or by the pencil, and every other
                    // exit means the user did not confirm it. Resolved paths
                    // make this a no-op.
                    onEndEditing: { cancelIfNeeded() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // At the cap the invitation is replaced by the reason there is
                // none: the "+" beside it can only gray out and darken, which
                // says "not now" without saying why. Scaled rather than
                // truncated, because a sentence cut off mid-word explains
                // nothing.
                Text(canAdd ? placeholder : ListAddRowCopy.atCapacity)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.tertiary)
                    // Matches the inset `.squareBezel` applies to its own text,
                    // so the caret lands where the placeholder's first glyph was
                    // rather than a few points to its side.
                    .padding(.leading, ListRowMetrics.fieldTextInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Grouped so their combined bounds can be published in one region,
            // covering the gap between them as well as the controls themselves.
            HStack(spacing: 8) {
                // One slot, two occupants, decided by whether an add is open.
                //
                // At rest it holds bulk import; while adding it holds cancel.
                // The two can share a position because they can never both be
                // wanted: opening the field is a commitment to typing one entry,
                // and reaching for a pasted list is a decision not to. The slot
                // is therefore always "the thing you do instead of confirming",
                // which is also what makes it read correctly beside the "+" that
                // becomes a pencil in exactly the same way.
                if isAdding {
                    // Cancel, mirroring the delete control on a real row.
                    ListCircleButton(
                        systemImage: "minus",
                        fill: Preferences.red,
                        diameter: ListRowMetrics.circleDiameter,
                        glyphSize: ListRowMetrics.circleGlyphSize,
                        help: "Cancel this entry",
                        role: .cancel,
                        glyphOffset: ListCircleButtonStyle.minusGlyphOffset,
                        // Opt+Delete, on the same terms as an entry row's: the
                        // key does whatever this row's "-" does. Here that is
                        // discarding the unconfirmed draft rather than removing
                        // an entry, because this row has no backing array
                        // element — which is the correct reading of "delete this
                        // row" for a row that does not exist in the model yet.
                        //
                        // Mutually exclusive with the entry rows' binding by
                        // construction: `beginAdd` clears `editingIndex` and
                        // `beginEdit` clears `isAdding`, so exactly one "-" is
                        // ever on screen within a table.
                        shortcut: KeyboardShortcut(.delete, modifiers: .option),
                        action: { cancelIfNeeded() }
                    )
                } else {
                    // Bulk import, from the shared control all three tables
                    // present it with — same fill, same glyph size, same
                    // per-symbol offset, same accent-while-open behavior. The
                    // account of why it is permanently gray and deliberately
                    // NOT gated on `canAdd` lives on `ListBulkImportButton`
                    // (30_20_FSControlHelpers.swift).
                    ListBulkImportButton(
                        isPresented: $showImportPopover,
                        help: "Add multiple \(itemLabel.lowercased())s from a comma-separated list",
                        onOpen: onBeginImport,
                        popoverContent: { importPopover() }
                    )
                }

                // "+" at rest, "pencil" while adding — the same slot, so
                // confirming an add is the same gesture in the same place as
                // confirming an edit. Accent-filled while adding, matching a row
                // under edit.
                ListCircleButton(
                    systemImage: isAdding ? "pencil" : "plus",
                    fill: isAdding ? Color.gray.opacity(0.5) : Preferences.green,
                    diameter: ListRowMetrics.circleDiameter,
                    glyphSize: isAdding ? ListRowMetrics.circleGlyphSize : ListRowMetrics.plusGlyphSize,
                    isActive: isAdding,
                    // Enabled while adding regardless of the cap: the field is
                    // already open, and the user must be able to resolve it. The
                    // list re-checks the cap before appending.
                    isEnabled: isAdding || canAdd,
                    help: isAdding ? "Save this entry" : "Add \(itemLabel.lowercased())",
                    // Per-symbol, so the correction follows the glyph rather
                    // than the control it is drawn in.
                    glyphOffset: isAdding
                        ? ListCircleButtonStyle.defaultGlyphOffset
                        : ListCircleButtonStyle.plusGlyphOffset,
                    action: {
                        if isAdding {
                            commitIfNeeded()
                        } else {
                            onBeginAdd()
                        }
                    }
                )
            }
            .background(ClickExclusionCapture(region: controlsRegion))
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
        // Same click reporting as a real row: double-click to open, and a click
        // anywhere else in the sheet to resolve. See `RowClickReporter`.
        .background(
            RowClickReporter(
                isEditing: isAdding,
                onDoubleClickInside: {
                    if !isAdding, canAdd { onBeginAdd() }
                },
                // Clicking away from an unconfirmed add discards it, which is
                // the same rule Escape and the cancel button follow.
                onClickOutside: {
                    cancelIfNeeded()
                },
                controlsRegion: controlsRegion
            )
        )
        // Resolves the add if the list closes it by some other route — beginning
        // an edit on a real row, a bulk import, a reorder.
        .onChange(of: isAdding) { _, adding in
            if !adding { cancelIfNeeded() }
        }
    }
}
