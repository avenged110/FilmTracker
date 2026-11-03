// MARK: - FSControlHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Domain-level SwiftUI control widgets used by FilmSheet tabs.
//
// Contains stateful UI components tied to FilmSheet data model concepts
// (dates, steppers, lists). Changes to tab functionality or data schema are
// localized here, independently of the low-level text/input primitives in
// FSTextHelpers.swift (30.10).
//
// It also hosts the chrome shared across the sheet's list components: the
// `ListCircleButton` family, the `ListImportPopover` bulk-entry sheet, the
// `ListBulkImportButton` that presents it, `PopoverDeleteButton`, the
// `listContainerChrome(height:)` modifier every table's container is drawn
// with, the `ListRowMetrics` geometry they are laid out on, and
// `ListImportCommit`, the cap-and-replace rule they all apply. The three
// reorderable lists themselves live in 30.30 FSStringList.swift,
// 30.40 FSFramesList.swift, and 30.50 FSTextList.swift; none imports another,
// and all three draw their controls from here. `ScrollActivityObserver`, the
// AppKit-level scroll signal they use to dismiss their open popovers, is here
// for the same reason.
//
// The rule for what belongs here: anything the three tables must agree on, so
// that agreement is a property of the code rather than something a reader is
// asked to maintain by eye. Anything genuinely specific to one table — the
// frames list's index column and metadata block, the string list's in-place
// editing field — stays with that table.

import SwiftUI
import AppKit

// MARK: - Shared Color Constants
// Constructed once, on first use, rather than on every render of StandardStepper and
// RatingStepper, which would repeat the NSColor→Color bridging each time.
private let disabledControlTextColor  = Color(NSColor.disabledControlTextColor)
// The placeholder shade shared by every un-activated stepper in the app — the same
// color CustomDateStepper's year and full-date placeholders use.
private let tertiaryLabelColor        = Color(NSColor.tertiaryLabelColor)
// The Steppers' fill and border are `stepperChrome(filled:)` (90.00 GlobalUtilities.swift),
// shared with InputUtilities.swift's so the two files' Steppers cannot drift.
// Backing fill for the circular control family. Bridged once here rather than inside
// ListCircleButtonStyle.makeBody, which runs for every circular control a populated
// Metadata tab carries.
private let listButtonBackingFill     = Color(nsColor: .windowBackgroundColor)

// MARK: - Observation Boundary

/// Builds `content` in its own body, so everything `content` reads is tracked HERE rather
/// than in the body that declares it.
///
/// **Why the tabs need it**
///
/// Creating `$viewModel.name` in a tab's body and handing it to a control there subscribes
/// that whole body to `name`, exactly as reading `viewModel.name` there would. Measured by
/// the `filmsheet-perf` harness scenario: one keystroke in the Details tab's Name field,
/// Metadata's Sort Name or Notes' Release re-ran the entire tab body, and with it every
/// row's construction, for a change one text field displays.
///
/// Wrapping the row moves the binding's creation into this view's body, so a change
/// re-evaluates the row and nothing else. It is the same boundary `FilmSheetListRow`
/// draws by taking a model and key path, and that `DeferredFieldContent` draws as a side
/// effect of calling its closure in its own body, offered for rows that need no type of
/// their own. A row with state or a cascade of its own is better given a named view.
///
/// The closure makes this view incomparable, so it re-runs whenever the enclosing body
/// does — which, once every bound row is wrapped, is only for the few values that body
/// still reads itself.
struct ObservationBoundary<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

// MARK: - Deferred Field Construction

/// One display frame, in the units `Task.sleep(for:)` takes.
///
/// File scope rather than a static on `DeferredFieldContent`: a static stored property on a
/// generic type is duplicated for each `Content` specialization, and this value is the same
/// for all of them.
///
/// 16ms is one frame at 60Hz. The value only has to be long enough that the frame
/// the placeholder was laid out in has actually been presented before the real
/// control replaces it; erring long costs a few imperceptible milliseconds on a
/// control the user is not looking at, whereas erring short puts the deferred work
/// back into the frame it was moved out of.
private let deferredFieldFrameInterval: Duration = .milliseconds(16)

/// Renders a fixed-height, invisible stand-in for `content` on the first frame,
/// then swaps the real thing in `wave` frames later.
///
/// **What this is for**
///
/// The FilmSheet's Metadata tab is built the first time the user activates it, and
/// everything on it is constructed in that one synchronous pass, including several
/// `ReorderableStringList`s and `FixedHeightScrollingTextView`s, each an AppKit scroll
/// view with its own hosted subtree. The sheet is 600pt square, so only the first few
/// of those can be inside the viewport when the tab appears. The rest are built, laid
/// out, and rendered below the fold before a single frame is shown, which is the
/// "click and wait" the tab exhibits.
///
/// Deferring the off-screen ones does not make the total work smaller — it takes it
/// off the critical path between the click and the first frame, and spreads what is
/// left across several frames so the main thread is never blocked for the whole
/// build at once.
///
/// **Why the height is a parameter and not measured**
///
/// The placeholder has to occupy *exactly* the space the real control will, or the
/// tab's content height changes underneath the scroll view when each wave lands and
/// the viewport shifts. Both consumers already know their final height as a pure
/// function of their content — `ListRowMetrics.listHeight(rowCount:)` for a list,
/// `FixedHeightScrollingTextView.fixedHeight(lineCount:)` for a text field — so the
/// figure is handed in rather than measured, and the swap is guaranteed to be a
/// no-op for layout. Measuring would defeat the purpose anyway: it would require
/// building the control to find out how tall it is.
///
/// `wave <= 0` renders `content` immediately with no `@State`, no task, and no
/// branch change, so a caller that wants the current behavior gets it exactly —
/// which is what every call site outside the Metadata tab passes.
struct DeferredFieldContent<Content: View>: View {

    /// How many frames to wait. 0 builds immediately.
    ///
    /// Call sites assign this in document order so that anything that can be on
    /// screen when the tab appears is in wave 0, and each later wave holds a small
    /// group — the point being to yield to the run loop between groups rather than
    /// to trade one long block for one slightly shorter one.
    let wave: Int

    /// Exact height the real control will occupy. See the note above.
    let placeholderHeight: CGFloat

    @ViewBuilder let content: () -> Content

    @State private var isReady = false

    var body: some View {
        if wave <= 0 || isReady {
            content()
        } else {
            // Greedy in width and fixed in height, which is the shape both
            // consumers resolve to — a `List` under `listContainerChrome(height:)`
            // and a text view under an explicit `.frame(height:)`. `Color` is
            // greedy the same way, so the enclosing HStack measures identically
            // before and after the swap.
            Color.clear
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: placeholderHeight)
                .task {
                    // Cancellation is the normal exit when the sheet is dismissed
                    // or the tab torn down inside the wait: the placeholder is
                    // going away, so there is nothing to swap in. Returning
                    // without writing `isReady` also keeps the write off a view
                    // that is no longer in the hierarchy.
                    do {
                        try await Task.sleep(for: deferredFieldFrameInterval * wave)
                    } catch {
                        return
                    }

                    // The swap is a structural change, and a structural change
                    // inside an ambient animation is interpolated. Nothing on this
                    // tab installs one today, but the sheet's own presentation
                    // transaction can still be in flight when a tab is activated
                    // early, and an interpolated swap would read as the field
                    // fading in. Disabling animations for this one write scopes
                    // the suppression to the swap itself, leaving the row
                    // insertion and reorder animations inside `content` untouched.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isReady = true }
                }
        }
    }
}

// MARK: - Shared List Control Family
//
// The circular button family and the bulk-entry popover, used by the three reorderable list
// components (30.30 FSStringList.swift, 30.40 FSFramesList.swift, 30.50 FSTextList.swift) and by
// SavedSearchSheet (50.32) and MultiFilmSheetView (52.10). They live here because they are shared:
// sheet-wide chrome belongs with the sheet's other domain-level controls, not inside one consumer.

// MARK: - Shared Field Label

/// The leading label of a FilmSheet form row.
///
/// The leading label of a form row in the FilmSheet's tabs and list components. Every such
/// label shares one frame, lineLimit, and truncationMode chain, so their width and truncation
/// rule is defined once here.
///
/// Variants that differ apply a modifier after this chain, such as a top offset, padding, or
/// the Hall of Fame row's secondary foreground style when the toggle is locked. They compose
/// from this view rather than restating the chain.
///
/// `width` defaults to `Preferences.filmSheetLabelWidth`, the value the tabs' `labelWidth`
/// constants resolve to. It stays a parameter for `NotesLegendSection`, which receives its width
/// from its parent.
struct FilmSheetFieldLabel: View {
    let text: String
    let width: CGFloat

    init(_ text: String, width: CGFloat = Preferences.filmSheetLabelWidth) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Shared List Row Metrics

/// Row geometry shared by `ReorderableStringList` (30.30 FSStringList.swift) and
/// `ReorderableFramesList` (30.40 FSFramesList.swift), and by the rows and add rows each builds.
/// The two tables are meant to be visually interchangeable within a tab, so a value that both
/// must share lives here, where a change applies to both.
///
/// Only values that genuinely have to agree across both components live here. Anything specific
/// to one table, such as the frames list's index column and metadata block, stays with that table.
enum ListRowMetrics {

    /// Height of a row's content, excluding the list's per-row insets.
    static let rowContentHeight: CGFloat = 20

    /// Inset applied above and below each row's content by `listRowInsets`.
    static let rowVerticalInset: CGFloat = 2

    /// The inset `List` adds inside its own bounds. Added to the summed row
    /// heights to produce a container that exactly encloses its content.
    static let listPadding: CGFloat = 20

    /// Total vertical space one row occupies, insets included. Derived rather
    /// than restated so a change to either term above cannot leave a container
    /// short of or overrunning the rows it encloses.
    static let rowTotalHeight: CGFloat = rowContentHeight + (rowVerticalInset * 2)

    /// Drawn diameter of an in-row circular control. 16pt of circle plus the
    /// button style's 2pt shadow margin on each side is exactly
    /// `rowContentHeight`, so the control fits without forcing the row taller.
    static let circleDiameter: CGFloat = 16

    /// Glyph point size for the family's stroke symbols — `pencil`, `minus`,
    /// `info`.
    static let circleGlyphSize: CGFloat = 10

    /// `plus` is optically heavier than the stroke symbols at the same nominal
    /// size, so it is set fractionally smaller.
    static let plusGlyphSize: CGFloat = 9.5

    /// `xmark` is heavier still. Where `plus` draws two strokes that stop short of its box,
    /// `xmark` draws two diagonals that run corner to corner, so at the same nominal size its
    /// drawn extent is larger. Matching nominal sizes would leave the "✕" reading as the larger
    /// mark, so it is set 1.5pt below `plusGlyphSize`. It is derived from that constant rather
    /// than stated absolutely, so the pair cannot drift apart if the "+" is retuned.
    static let xmarkGlyphSize: CGFloat = plusGlyphSize - 1.5

    /// Glyph size for the bulk-import control.
    ///
    /// Set below the family's 10pt because `list.clipboard.fill` is a filled
    /// body rather than a stroke: at the same nominal size it reads as a
    /// noticeably heavier mark than the "+" beside it. The filled variant is
    /// deliberate — at a 16pt circle the outlined one's ruled lines fall below
    /// the point where they resolve as lines at all, and a solid silhouette
    /// stays legible where interior detail does not.
    static let importGlyphSize: CGFloat = 9

    /// Horizontal space one row control consumes inside a row's `HStack`: the
    /// circle, plus the button style's 2pt shadow margin on each side, plus the
    /// stack's 8pt spacing.
    static let controlSpan: CGFloat = circleDiameter + 4 + 8

    /// Horizontal inset `.squareBezel` applies to its own text. Mirrored by any
    /// display label or placeholder that occupies the same slot as an editing
    /// field, so the glyphs do not shift sideways when a row enters edit mode.
    static let fieldTextInset: CGFloat = 3

    /// The `listRowInsets` every row of every one of the three tables carries.
    ///
    /// Declared once rather than restated as a literal `EdgeInsets(...)` at six call sites —
    /// two per table, one for the entry rows and one for the add row. All six
    /// were built from `rowVerticalInset` already, so the values could not
    /// disagree; what they could disagree about is the *shape*, since a leading
    /// or trailing inset introduced at one site and not the others would move
    /// one table's rows out of column with the rest. Declared once, that is not
    /// expressible.
    static let rowInsets = EdgeInsets(top: rowVerticalInset,
                                      leading: 0,
                                      bottom: rowVerticalInset,
                                      trailing: 0)

    /// Height of a table container that exactly encloses `rowCount` rows.
    ///
    /// `rowCount` is the number of rows actually drawn, which for all three
    /// tables is their entry count plus the unconditional trailing add row.
    ///
    /// Derived here so that the row total, the `List`'s internal padding, and the frame the
    /// container is given stay in agreement. If they drift apart, the alternating background
    /// overruns the border or falls short of it. Tables state only how many rows they draw.
    static func listHeight(rowCount: Int) -> CGFloat {
        CGFloat(rowCount) * rowTotalHeight + listPadding
    }

    /// Distance below the add row's content that must be brought into the
    /// viewport along with it when a commit pushes it down.
    ///
    /// Derived rather than a literal, because it has to track the table's own
    /// bottom chrome. Measured from the add row's content rectangle, the
    /// container's outer edge sits one `rowVerticalInset` below it — the row's
    /// own bottom inset — plus half of `listPadding`, the `List`'s internal
    /// padding, which `listHeight(rowCount:)` distributes evenly between the top
    /// and bottom edges. Revealing only the row itself would therefore leave the
    /// table's border and shadow clipped at the fold, which reads as the row
    /// being cut off even though its text is fully visible.
    ///
    /// The trailing 8pt is the requested breathing room beneath the finished
    /// table. See `ListAddRowRevealer`.
    static let addRowRevealPadding: CGFloat = (listPadding / 2) + rowVerticalInset + 8
}

// MARK: - Enclosing Scroll View Lookup

extension NSView {

    /// The outermost `NSScrollView` this view sits inside, or `nil` if it sits
    /// in none.
    ///
    /// `enclosingScrollView` returns the *nearest* ancestor, which inside any of
    /// the sheet's tables is the scroll view backing the `List` itself — a view
    /// that is `scrollDisabled`, sized exactly to its content, and has nothing
    /// to scroll or to gate. Walking to the outermost one instead reaches
    /// `FilmSheetScrollView`, which is both the scroll view that actually moves
    /// and the one whose `hitTest` gate distinguishes an active tab from a
    /// hidden-but-mounted one.
    ///
    /// Both consumers need exactly that view: `ListAddRowRevealer` below to scroll to a row, and
    /// `RowClickReporter` (30.30 FSStringList.swift) to decide whether a click reached its tab.
    ///
    /// The identity check guards against an implementation of
    /// `enclosingScrollView` that returns the receiver, which would otherwise
    /// spin here.
    var outermostEnclosingScrollView: NSScrollView? {
        var result: NSScrollView?
        var current: NSView = self
        while let next = current.enclosingScrollView, next !== current {
            result = next
            current = next
        }
        return result
    }
}

// MARK: - Add Row Reveal

/// Scrolls the enclosing sheet just far enough to bring the add row it is
/// attached to fully into the viewport, with `ListRowMetrics.addRowRevealPadding`
/// of clearance beneath it.
///
/// **The problem:** all three tables grow downward. Committing an entry turns the
/// "Add new…" row into a real row and appends a fresh one beneath it, so the control
/// the user is about to reach for moves down — and, near the fold, can leave the
/// viewport entirely, forcing a manual scroll after every addition.
///
/// **Why this rather than the scroll proxy:** `FilmSheetScrollProxy` scrolls to a named
/// anchor, which would require every table to publish one, its tab to route it, and the
/// proxy to be threaded down. This needs no anchor, proxy, or tab cooperation: the view
/// measures itself against whatever scroll view it is inside, so all three tables get
/// identical behavior from one attachment, in any tab.
///
/// **Minimal scrolling, only when needed:** done via `NSView.scrollToVisible(_:)`,
/// AppKit's own "scroll the least amount that reveals this rectangle" — a no-op when
/// the row is already visible with its clearance, and a shortfall-only correction
/// otherwise. Using the first-party call also hands flipped/unflipped document cases
/// and the scroll view's own elasticity/clipping rules to AppKit rather than
/// restating them here.
struct ListAddRowRevealer: NSViewRepresentable {

    /// Incremented by the owning list each time an entry is committed. A change
    /// is the request; an unchanged value is a no-op, so ordinary update passes
    /// — a reorder, a keystroke elsewhere on the tab, a window resize — do not
    /// move the viewport.
    let token: Int

    // No `bottomPadding` parameter. Every table uses the default, which is
    // `ListRowMetrics.addRowRevealPadding`, derived from the shared geometry so that all
    // tables agree. A per-instance override would break that agreement.

    @MainActor
    final class Coordinator {
        /// The token most recently acted on. Seeded in `makeNSView` so the
        /// table's first appearance never scrolls: a sheet opening on a film
        /// with a populated list should present at the top, not jumped to the
        /// bottom of whichever table happens to be longest.
        var lastToken: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.lastToken = token
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastToken != token else { return }
        context.coordinator.lastToken = token

        // Deferred by one main-queue turn. This update runs while SwiftUI is
        // still applying the change that grew the table by a row, so the add
        // row's frame has not yet moved; measuring now would reveal the position
        // it is leaving rather than the one it is arriving at.
        //
        // `DispatchQueue.main.async` rather than `Task { @MainActor }`, per the
        // rule the rest of this file follows: the hop has to order against
        // AppKit's own layout work, and the main queue does, whereas a Task is
        // scheduled against the actor's queue with no such guarantee.
        DispatchQueue.main.async { [weak nsView] in
            MainActor.assumeIsolated {
                guard let nsView else { return }
                Self.reveal(nsView, remainingPasses: Self.settlePasses)
            }
        }
    }

    /// How many further turns the reveal will re-measure on before giving up.
    ///
    /// **Why more than one.** A single-entry commit grows the table by one row, and one hop is
    /// enough for that: the document view's height is either already correct or short by less
    /// than the scroll needs, so the clamped scroll lands within the clearance. A bulk import
    /// commits *many* rows at once, and there the enclosing sheet's document view, a SwiftUI
    /// hosting view sized from the table's row count through `listContainerChrome(height:)`,
    /// has not yet grown when the first hop runs. `scrollToVisible` clamps to the document
    /// bounds it is given, so that pass scrolls to the old bottom and stops, leaving the add
    /// row below the fold. The reveal fires, but it measures a document that has not finished
    /// growing.
    ///
    /// `layoutSubtreeIfNeeded` cannot close that on its own — it forces AppKit's
    /// pending layout, not SwiftUI's next render pass, so a height that arrives
    /// with that pass is invisible to it.
    ///
    /// Re-measuring instead: each pass scrolls with what it can see, and stops as soon as a
    /// pass finds the geometry unchanged from the one before. The normal single-row case ends
    /// after its second pass, whose scroll is a no-op. The cap bounds the rare case where
    /// something else is animating the document's height, so this can never spin.
    private static let settlePasses = 6

    @MainActor
    private static func reveal(_ view: NSView, remainingPasses: Int, lastGeometry: CGRect? = nil) {
        // A view that has left the window — the sheet was dismissed inside the
        // deferral, or the tab was torn down — has nothing to scroll.
        guard unsafe view.window != nil,
              let scrollView = view.outermostEnclosingScrollView,
              let document = scrollView.documentView else { return }

        // Forces any layout still pending from the update that scheduled this,
        // so the rectangle measured below is the row's final position rather
        // than an intermediate one.
        scrollView.layoutSubtreeIfNeeded()

        var rect = view.convert(view.bounds, to: document)
        guard rect.width > 0, rect.height > 0 else { return }

        // The two quantities a clamped `scrollToVisible` depends on: where the
        // row sits in the document, and how tall the document has grown. Packed
        // into one rect so the pass-to-pass comparison below is a single
        // equality — the origin carries the row's position, the size carries the
        // document's. A pass that finds both unchanged has nothing further to
        // wait for.
        let geometry = CGRect(origin: rect.origin, size: document.bounds.size)

        // Extend the rectangle by the clearance, on whichever side is "below" in
        // the document's own coordinate space. The clearance is the tables'
        // shared constant, read here rather than passed in. SwiftUI's hosting views are
        // flipped and AppKit's are not, and this sits inside both depending on
        // the host, so the orientation is asked rather than assumed.
        let bottomPadding = ListRowMetrics.addRowRevealPadding
        if document.isFlipped {
            rect.size.height += bottomPadding
        } else {
            rect.origin.y -= bottomPadding
            rect.size.height += bottomPadding
        }

        document.scrollToVisible(rect)

        // Settled: the row and the document both measured the same as on the
        // previous pass, so a further pass would scroll to the same place.
        guard geometry != lastGeometry, remainingPasses > 0 else { return }

        // Same one-turn main-queue hop as the initial deferral, and for the same
        // reason — the growth this is chasing arrives with SwiftUI's next render
        // pass, which is ordered against the main queue.
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                guard let view else { return }
                Self.reveal(view, remainingPasses: remainingPasses - 1, lastGeometry: geometry)
            }
        }
    }

}

// MARK: - Shared List Container Chrome

extension View {

    /// The list style, outline, clip, and shadow of the sheet's three reorderable tables,
    /// applied to the `List` itself.
    ///
    /// The edge is the shared `.standard` field edge, so the tables cannot disagree about a
    /// radius or shadow opacity. What remains load-bearing here is the order:
    ///
    ///   - Sizing before the chrome, so the rounded rect and stroke resolve against the
    ///     container's final bounds. Clipping first resolves the shape against the
    ///     `List`'s own laid-out bounds, leaving the last alternating background
    ///     band's overhang outside the clip as a sliver of fill below the border.
    ///   - The content clip is inset by exactly the border width (`insetsInterior`), with
    ///     the border stroked into the ring that inset leaves free. Without the inset, the
    ///     alternating fill paints to the bounds and composites with the translucent
    ///     separator color, darkening the bottom edge into an apparent extra band.
    ///   - The list paints its own rows, so there is no fill, and the shadow is cast by
    ///     the finished shape (`.content`). Shadows don't participate in layout, so the
    ///     table's bounds are unchanged.
    func listContainerChrome(height: CGFloat) -> some View {
        self
            // The list style the three tables share: inset, alternating row bands, and
            // no scrolling of their own (each is sized to its full content by `height`).
            // Applied first, before the frame and clip.
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollDisabled(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .fieldEdgeChrome(fill: nil, clipsContent: true, insetsInterior: true, shadow: .content)
    }
}

// MARK: - Shared Bulk-Import Control

/// The bulk-import control in the add row of the three reorderable tables, immediately left of
/// the "+", together with the popover it anchors. Only the tooltip and the reset before the popover
/// opens differ per table. Sharing the rest keeps the look and behavior, including the `isActive`
/// binding that holds the accent fill while the popover is open, from drifting apart.
///
/// Rationale:
///
///   - Permanently gray, NOT gated on the table's entry cap. It is an alternative route in, not
///     the primary action (the green "+" is). Gating it would also be invisible: `ListCircleButton`
///     signals "disabled" via `disabledFill`, the same `Color.gray.opacity(0.5)` this already
///     carries, so a disabled instance would look live and do nothing. The cap is enforced in the
///     popover's own Import button and in each table's commit, which bounds the array regardless.
///   - The filled `list.clipboard.fill` at a reduced glyph size is deliberate;
///     see `ListRowMetrics.importGlyphSize`.
///
/// Generic over the popover's content rather than `AnyView`: each table owns its
/// own `ListImportPopover` configuration (item label, cap, sample text, commit) and
/// hands it in as an opaque builder, keeping that ownership where it belongs
/// without an existential box.
struct ListBulkImportButton<PopoverContent: View>: View {

    /// Presentation flag, owned by the table so a scroll can close it.
    @Binding var isPresented: Bool

    /// Tooltip. The one thing that legitimately differs between the three
    /// tables, because it names what is being imported.
    let help: String

    /// Resets the owning table's import mode before the popover appears — each
    /// table opens it in Replace mode at its cap. Runs before the flag is set, so
    /// the popover's first frame already reads the reset value.
    let onOpen: () -> Void

    @ViewBuilder let popoverContent: () -> PopoverContent

    var body: some View {
        ListCircleButton(
            systemImage: "list.clipboard.fill",
            fill: Color.gray.opacity(0.5),
            diameter: ListRowMetrics.circleDiameter,
            glyphSize: ListRowMetrics.importGlyphSize,
            isActive: isPresented,
            help: help,
            glyphOffset: ListCircleButtonStyle.clipboardGlyphOffset,
            action: {
                onOpen()
                isPresented = true
            }
        )
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            popoverContent()
        }
    }
}

// MARK: - Shared Popover Delete Button

/// The Delete button in the editing popovers of the frames list, the text list (30.40, 30.50), and `ViewingDatesTable`.
///
/// Red label text, with NO destructive role, and drawn with an explicit blend mode.
///
/// The role is omitted because SwiftUI's macOS push-button style renders a `.destructive` label
/// through its own tint treatment, which composites over whatever `.foregroundStyle` supplied.
/// Dropping the role does not fix the washout by itself. The rest of it comes from the popover,
/// which the blend mode below addresses.
///
/// An `NSPopover` hosts its content over a vibrant material, and SwiftUI
/// content in a vibrant context is composited through a blend that pulls
/// saturated colors toward the material behind them. Red is the most saturated
/// thing in these views, so it is the one that visibly desaturates — the "faded
/// salmon" reading. `FSTabPoster`'s "Delete Poster" (35.00) uses the identical color and
/// looks correct because it is NOT in a popover; it draws onto the sheet's opaque surface.
///
/// Stating a blend mode opts this leaf out of the inherited vibrant blend and
/// draws the literal color. `.normal` is the default everywhere else, so on any
/// surface that was never vibrant this modifier changes nothing — it cannot
/// regress the appearance, it can only stop the blend where one is applied. It
/// is scoped to the label rather than the row so each popover's Cancel and
/// confirm buttons keep the standard vibrant treatment every other control
/// there has.
///
/// The action is supplied whole rather than being decomposed into "dismiss" and
/// "delete", because the order of those two is not the same everywhere and is
/// deliberate at each site: the two lists dismiss BEFORE mutating, since the
/// delete tears down the row the popover is anchored to.
struct PopoverDeleteButton: View {

    let action: () -> Void

    /// Binds Opt+Delete to this button while its popover is up.
    ///
    /// Opt-in rather than unconditional, because only the reorderable lists want it: their popover
    /// IS the row's editor, so "delete" while it is open unambiguously means this row. `ViewingDatesTable`
    /// edits a value that persists after dismissal, so the same key would be a less obvious gesture there,
    /// and it does not opt in.
    ///
    /// A `keyboardShortcut` rather than an event monitor is what makes this
    /// correctly scoped for free. Key equivalents are dispatched to the key
    /// window, which while a popover is up is the popover's own window, so the
    /// binding is live exactly while this row's editor is open and inert at
    /// every other moment — including for the other rows of the same table,
    /// whose Delete buttons do not exist.
    ///
    /// It also takes precedence over the text field the popover opens with
    /// focused: `performKeyEquivalent(with:)` runs before the responder chain's
    /// `keyDown`, so the field editor never sees the event as "delete word
    /// backward".
    var bindsOptionDelete: Bool = false

    var body: some View {
        Button(action: action) {
            Text("Delete")
                .foregroundStyle(Color.red)
                .blendMode(.normal)
        }
        // Applied unconditionally with a `nil` equivalent when not opted in,
        // rather than behind an `if`, so the button keeps one view identity in
        // both cases.
        .keyboardShortcut(bindsOptionDelete ? KeyboardShortcut(.delete, modifiers: .option) : nil)
    }
}

// MARK: - Shared Bulk-Import Commit

/// The cap-and-replace rule the three tables apply to a bulk import: reject an empty or over-cap
/// batch, replace outright in Replace mode, and otherwise append and bound the result. The append
/// bound is the one that matters, since appending is the only route by which a permitted import
/// could push a list past its cap.
///
/// **The append bound rejects; it does not truncate**
///
/// Truncating with `prefix(cap)` would silently discard the overflow. With 25 of 30 slots used, a
/// ten-entry paste would import five and drop five while the popover still reported ten entries
/// detected, which loses data the user supplied with nothing to indicate it.
///
/// The rule is all-or-nothing on both paths: a batch that does not fit is refused, and the array
/// is left exactly as it was. That is safe because the popover does not offer to submit such a
/// batch. `ListImportPopover.effectiveLimit` measures the *headroom* in append mode rather than the
/// raw cap, so an over-headroom paste disables Import, colors its readout red, and states the room
/// remaining, all before it is committed. This guard is the model-level form of that UI rule.
///
/// Returns the array to write rather than mutating one `inout`. Deliberate: the
/// tables' arrays are reached through a `Binding` onto an `@Observable` model,
/// and an `inout` argument bound to a computed property writes back
/// unconditionally on return — including on the rejection paths, which would
/// fire an observation invalidation and a change-tracking pass for a value that
/// did not change. Returning `nil` for "nothing to do" means the caller writes
/// exactly once, and only when there is something to write.
enum ListImportCommit {

    /// The array `current` should become, or `nil` if the batch is rejected.
    ///
    /// - Parameters:
    ///   - incoming: Entries to import, already parsed and, where the table
    ///     stores records rather than bare strings, already converted.
    ///   - current: The table's existing entries.
    ///   - replacing: Replace mode, from the popover's toggle.
    ///   - cap: The table's `maxItems`.
    static func resolved(_ incoming: [String],
                         into current: [String],
                         replacing: Bool,
                         cap: Int) -> [String]? {
        guard !incoming.isEmpty else { return nil }
        if replacing {
            // The whole array is being written, so the batch is measured against the cap itself.
            guard incoming.count <= cap else { return nil }
            return incoming
        }
        // Appending, so the batch is measured against what is left — the same
        // quantity `ListImportPopover` gates its Import button on, so an enabled
        // button can never land here and be refused.
        guard current.count + incoming.count <= cap else { return nil }
        return current + incoming
    }
}

// MARK: - Add Row Copy

/// Text the three tables' add rows share.
///
/// One declaration rather than three literals, for the same reason the metrics
/// and the controls are shared: the rows are read as a set, and a wording change
/// in one of them that did not reach the others would be visible.
enum ListAddRowCopy {

    /// Replaces the usual "Add new…" invitation once the table is full.
    ///
    /// States both the condition and the remedy, because the row it replaces is
    /// the only place the cap is ever mentioned — the "+" beside it can only
    /// gray out and darken, which says "not now" without saying why.
    static let atCapacity = "Maximum entries reached. Remove some to add more."
}

// MARK: - Duplicate Entry Confirmation

/// Whether a value the user is about to commit already exists verbatim in the
/// table.
///
/// Deliberately an exact comparison of the finished value, not a normalized or
/// case-insensitive one. Two crew members can share a name and two frame marks
/// can legitimately repeat, so this is a nudge against an accidental
/// double-entry rather than a rule the model enforces — which is also why the
/// prompt it drives offers to proceed rather than refusing.
///
/// The candidate is compared *after* the caller has trimmed it and, where the
/// table stores records rather than bare strings, built the record: the array
/// holds finished values, so the comparison has to be made against one.
enum ListDuplicateCheck {

    /// - Parameters:
    ///   - candidate: The finished value about to be written.
    ///   - items: The table's current entries.
    ///   - excluding: The row being edited, whose own value must not be read as
    ///     a duplicate of itself. `nil` for an append, where there is no such
    ///     row.
    static func isDuplicate(_ candidate: String,
                            in items: [String],
                            excluding index: Int? = nil) -> Bool {
        for (position, existing) in items.enumerated() {
            if position == index { continue }
            if existing == candidate { return true }
        }
        return false
    }
}

/// A confirmation the user has yet to answer, carrying the write it would
/// perform.
///
/// The write is captured as a closure rather than as data because the three
/// tables commit differently — one appends, one writes through a row's binding,
/// one does either — and the prompt has no business knowing which. Deferring the
/// closure rather than the value is also what keeps every existing guard intact:
/// the closure re-runs the same bounds and position checks the immediate path
/// would have, so a table that changed underneath the alert is still safe.
///
/// It doubles as the currency the tables' rows hand their pending write back in.
/// A stored function type cannot mark its own closure parameter `@escaping`, so
/// a bare closure arriving through one is non-escaping and could not be parked
/// in `@State`; a closure held as a property of a struct is escaping by
/// construction, which is what makes this type the right thing to pass.
struct ListDuplicatePrompt: Identifiable {
    let id = UUID()
    /// Performs the commit the user was in the middle of.
    let confirm: () -> Void
}

extension View {

    /// The "you are about to add an exact duplicate" alert, shared by all three
    /// reorderable tables.
    ///
    /// Attached to each table's outermost view rather than to the row or popover
    /// the commit came from: the frames and text tables commit from inside a
    /// popover that dismisses on the same interaction, so an alert anchored
    /// there would be torn down with its host before it could be answered. The
    /// table itself is the nearest view guaranteed to outlive the commit.
    ///
    /// Canceling clears the prompt and does nothing else, which leaves the
    /// array exactly as it was — the same outcome as clicking away from the
    /// entry — because nothing has been written at the point the alert appears.
    func listDuplicateAlert(_ prompt: Binding<ListDuplicatePrompt?>) -> some View {
        alert(
            "Add Duplicate",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { presented in if !presented { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { pending in
            Button("Cancel", role: .cancel) { prompt.wrappedValue = nil }
            Button("Add Anyway") {
                // Cleared first, so the write cannot re-enter a still-presented
                // alert by any route, and so a confirm that throws the table
                // back into a state the user then repeats starts from a clean
                // prompt.
                prompt.wrappedValue = nil
                pending.confirm()
            }
        } message: { _ in
            Text("This exact item already exists in the table. Are you sure you want to add it again?")
        }
    }
}

// MARK: - Scroll Activity Observer

/// Zero-size representable that reports scrolling of whatever `NSScrollView` it
/// happens to sit inside, without SwiftUI participating in the scroll at all.
///
/// Used by every control on the sheet that anchors a popover: an `NSPopover`
/// stays pinned to the screen rectangle its anchor occupied at presentation
/// time, so scrolling the sheet leaves it stranded over unrelated content. Each
/// consumer closes its own popovers from the callback.
///
/// The alternative — a `GeometryReader` watching `frame(in: .global)` — makes
/// every scroll tick a SwiftUI layout query on the hosted tree. That is the one
/// thing `AppKitScrollView`'s live-scroll suppression exists to avoid, and it
/// happens whether or not anything is actually listening for the result.
///
/// An `NSClipView` already posts `boundsDidChangeNotification` as it scrolls, so
/// this observes the signal AppKit is publishing anyway. Nothing is allocated
/// per tick and no SwiftUI invalidation occurs unless the callback itself
/// changes state — which, with each consumer's `if showPopover` guard, means
/// only when a popover is actually open.
///
/// Silent when the view is not inside a scroll view, so it is safe to attach
/// anywhere.
///
/// Declared here rather than inside one consumer's file, because the reorderable lists and
/// `ViewingDatesTable` need the same behavior. Sharing it keeps them from maintaining separate
/// copies of one notification observer.
struct ScrollActivityObserver: NSViewRepresentable {

    let onScroll: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView(frame: .zero)
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        // Refreshed on every update: the closure captures the consumer's current
        // state, so a stale one would post into a previous generation of it.
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: ObservingView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObservingView: NSView {

        var onScroll: () -> Void = {}

        private weak var observedClipView: NSClipView?

        /// Entering a window is the first moment an enclosing scroll view can be
        /// found; leaving one is when the observation has to be dropped.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard unsafe window != nil else {
                stopObserving()
                return
            }
            startObserving()
        }

        /// Also re-resolved on re-parenting, which is how a row that is moved
        /// between containers picks up its new clip view.
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard unsafe window != nil else { return }
            startObserving()
        }

        private func startObserving() {
            let clipView = enclosingScrollView?.contentView
            guard clipView !== observedClipView else { return }
            stopObserving()
            guard let clipView else { return }
            // Default for NSClipView, set explicitly so the observation does not
            // depend on a default staying what it is.
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            observedClipView = clipView
        }

        /// Target/action rather than a block observer, so the teardown is a
        /// single `removeObserver(self)` that a nonisolated `deinit` is also
        /// allowed to perform — no token has to be read off a main-actor
        /// property at deallocation time.
        func stopObserving() {
            guard observedClipView != nil else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
            observedClipView = nil
        }

        @objc private func clipViewBoundsDidChange(_ notification: Notification) {
            onScroll()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Color Darkening

private extension Color {
    /// Returns the color blended toward black by `amount` (0...1).
    ///
    /// Goes through `NSColor` in the sRGB space rather than compositing a black
    /// overlay, so the result is a real color that can be handed to `.fill`
    /// without adding a layer. Falls back to the receiver unchanged if the color
    /// cannot be converted — dynamic system colors resolve fine, but a pattern
    /// or catalog color may not.
    func darkened(by amount: CGFloat) -> Color {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let factor = max(0, 1 - amount)
        return Color(nsColor: NSColor(srgbRed: srgb.redComponent * factor,
                                      green: srgb.greenComponent * factor,
                                      blue: srgb.blueComponent * factor,
                                      alpha: srgb.alphaComponent))
    }
}

// MARK: - List Button Style

/// Draws the circular chrome for `ListCircleButton` and supplies its press
/// response.
///
/// Not used directly by callers — construct a `ListCircleButton` instead, which
/// resolves the enabled/active fill vocabulary before handing this style the
/// single fill it draws.
///
/// A `ButtonStyle` is the framework's own hook for pressed-state rendering. It is used here
/// instead of a `.onLongPressGesture(minimumDuration: 0, pressing:)` layered over the button,
/// which would put a gesture recognizer on every control in every row, competing for the mouseDown
/// the row's drag session needs. A style observes the press without recognizing anything, so
/// nothing contends for the event, and activation semantics are untouched: a `ButtonStyle`
/// governs presentation only.
///
/// **Shadow clipping**
///
/// The drop shadow is cast by a `Circle` drawn inside a frame deliberately
/// larger than the circle itself. Applying `.shadow` to a view whose frame is
/// exactly its own bounds leaves the shadow clipped by any ancestor that clips —
/// which, inside a `List` row, it will be. Reserving margin means the shadow
/// renders into space the layout has already accounted for.
struct ListCircleButtonStyle: ButtonStyle {

    /// Fill for the idle state. The caller resolves active/disabled variants
    /// before constructing the style, so the style itself has one fill to draw.
    let fill: Color
    /// Drawn diameter of the circle, excluding the reserved shadow margin.
    let diameter: CGFloat

    /// Whether the owning control is disabled.
    ///
    /// The gray fill alone isn't enough signal: the bulk-import control beside
    /// the "+" is *permanently* that same gray while fully live, so a grayed-out
    /// "+" read as just another active button. A disabled control therefore also
    /// carries the darkening the press state uses — a treatment nothing enabled
    /// shows at rest — so the two together say "inert" in a way neither does alone.
    ///
    /// Passed in rather than read from `@Environment(\.isEnabled)` inside
    /// `makeBody`: a `ButtonStyle`'s body isn't a `View` that can hold an
    /// environment read, and `ListCircleButton` already resolves the
    /// enabled/disabled vocabulary to produce `fill`, so the flag is free there
    /// and the two can never disagree.
    var isDisabled: Bool = false

    // MARK: Uniform Style Constants
    // Deliberately not parameters — these define the family and should move
    // together for every control that adopts it.

    /// Space reserved on each side for the drop shadow to render into.
    private static let shadowMargin: CGFloat = 2
    private static let dropShadowRadius: CGFloat = 1.5
    private static let dropShadowY: CGFloat = 1
    private static let dropShadowOpacity: CGFloat = 0.35
    /// How far the fill AND the glyph are darkened while held. The press is
    /// communicated by this alone — no bevel, no movement, no shadow change —
    /// which keeps the control flat enough to sit alongside the rest of the
    /// sheet's chrome. One constant for both, so the two can never fall out of
    /// step and invert the contrast between them.
    private static let pressedDarkening: CGFloat = 0.18

    /// How far the fill AND the glyph are darkened while the control is
    /// disabled, and how far the finished control is faded.
    ///
    /// Deliberately far heavier than the press response. The press treatment, felt only while
    /// held, leaves a disabled "+" reading as live, because it falls back to the same gray as the
    /// fully live bulk-import button beside it.
    ///
    /// Darkening and fading together, not either alone: darkening alone only
    /// deepens a color the eye reads as "import," while fading alone leaves a
    /// green button that merely looks washed out. Sunk toward the sheet's own
    /// surface and drained of contrast at once, the control stops reading as
    /// clickable.
    private static let disabledDarkening: CGFloat = 0.4
    private static let disabledOpacity: CGFloat = 0.6

    // MARK: Glyph Optical Centering
    //
    // SF Symbols are laid out on a typographic box, not a tight bounding box: the
    // drawn strokes of `plus` and `minus` sit slightly right of and below the
    // center of the box the symbol reports. `.overlay` centers the reported box,
    // so the strokes land off-center. The discrepancy is a property of the box, so
    // scaling the glyph scales the error with it.
    //
    // The remedy is a translation, not a size change: shift the glyph back by the
    // amount the box is biased. Half a point is one physical pixel on a Retina
    // display — the observed error — landing the strokes on the pixel grid rather
    // than straddling it.
    //
    // Sign convention: negative moves LEFT and UP.
    //
    // This is the FAMILY default, correct for `pencil` and the larger diameters
    // the family draws at. A symbol whose strokes aren't centered in its own box
    // — or whose bias only shows at the small in-row diameter — needs a different
    // correction via `ListCircleButton.glyphOffset`. These overrides are
    // per-symbol corrections, not style choices, collected immediately below
    // rather than written as literals at the call sites.
    static let defaultGlyphOffset = CGSize(width: 0, height: -0.5)

    // MARK: Per-Symbol Corrections
    //
    // Held here beside the family default rather than as literals at each call
    // site. They are properties of the symbols' artwork, not of the controls
    // that happen to draw them, so two buttons drawing the same glyph must not
    // be able to disagree about where it sits.
    //
    // Same sign convention as above: negative moves LEFT and UP. A quarter point
    // is half a physical pixel on a Retina display, which is the granularity
    // needed to split a one-pixel imbalance.

    /// `plus`, as drawn at the small in-row diameter.
    ///
    /// The family's upward half point overcorrects this symbol at that size —
    /// the bar crossing reads high in the circle — so the correction is backed
    /// out and the glyph is centered on its reported box. Adjust this one value
    /// to move every in-table "+" together; more negative moves it up.
    static let plusGlyphOffset = CGSize(width: 0, height: 0)

    /// `minus`, as drawn at the small in-row diameter.
    ///
    /// At 10pt in a 16pt circle the bar rendered with one more physical pixel of
    /// clearance below it than above, and one more to its left than its right —
    /// the symbol's box is biased up and right of its stroke by half a pixel in
    /// each axis. Both are corrected by a quarter point, which is exactly that
    /// half pixel, rather than by resizing the glyph: the bias is a property of
    /// the box, so scaling the symbol scales the error with it.
    static let minusGlyphOffset = CGSize(width: -0.25, height: -0.25)

    /// `info`, whose dot-and-stem sits left of the center of its own box — the
    /// one glyph in the family that is not symmetric within it.
    static let infoGlyphOffset = CGSize(width: 0.5, height: defaultGlyphOffset.height)

    /// `xmark`, as drawn at the small in-row diameter.
    ///
    /// Deliberately zero in BOTH axes: the two strokes cross at the center of
    /// the symbol's own box, so it needs no horizontal correction, and — as with
    /// `plus` — the family's upward half point overcorrects it at this size,
    /// reading the cross high in the circle. Backing that out lands the glyph on
    /// its reported box, which is where it belongs.
    ///
    /// Kept as a named constant, as `plusGlyphOffset` is: zero here is a measured per-symbol
    /// result, not an absence of one. Omitting it would silently inherit `defaultGlyphOffset`'s
    /// half point, which this symbol was measured NOT to want. Naming it lets every in-table "✕"
    /// move together. More
    /// negative moves it left and up.
    static let xmarkGlyphOffset = CGSize(width: 0, height: 0)

    /// `list.clipboard.fill`, as drawn at the small in-row diameter.
    ///
    /// A full point up, where the family default is half a point. The filled
    /// clipboard carries a tab across its top edge that is part of the drawn
    /// artwork but reads as clearance rather than as body, so the symbol's
    /// visual mass sits below the center of the box it reports — the opposite of
    /// `plus`, which needed the family's correction backed out. One point is two
    /// physical pixels on a Retina display, which keeps the glyph on the pixel
    /// grid, and it is measured against the "+" beside it rather than against
    /// the circle in isolation: the two sit side by side in the add row, so they
    /// are judged as a pair.
    static let clipboardGlyphOffset = CGSize(width: 0, height: -1.0)

    /// Translation applied to the glyph. Defaults to `defaultGlyphOffset`.
    var glyphOffset: CGSize = ListCircleButtonStyle.defaultGlyphOffset

    func makeBody(configuration: Configuration) -> some View {
        // One term for both states, so the fill and the glyph can never darken
        // on different conditions. A disabled control is dimmed permanently; a
        // pressed one only while it is held. A control cannot be both, since a
        // disabled button never reports a press.
        let isDimmed = configuration.isPressed || isDisabled
        // Disabled wins where both could apply — a disabled button never reports
        // a press, so this only ever resolves one way in practice, but stating
        // it keeps the fill and the glyph reading the same amount.
        let darkening = isDisabled ? Self.disabledDarkening : Self.pressedDarkening

        // UtilityKit's GlyphBadge draws the circle and centers the glyph on it. Its own
        // shadows are off: the family's shadow is cast once, below, by the finished control,
        // and the glyph's comes with the label `ListCircleButton` supplies.
        //
        // The fill darkens rather than swapping to a separate pressed color, so any
        // fill passed in gets a consistent press response without needing a paired
        // constant declared alongside it. The conversion only runs while the control
        // is actually held.
        return GlyphBadge(color: isDimmed ? fill.darkened(by: darkening) : fill,
                          diameter: diameter, inkShadow: nil) {
                configuration.label
                    .offset(x: glyphOffset.width, y: glyphOffset.height)
                    // Darkened in step with the fill.
                    //
                    // The glyph darkens with the fill. If only the fill darkened, the white
                    // glyph would hold full brightness over a dimmer fill, so the contrast
                    // would rise while the control is held, which reads as the glyph lighting
                    // rather than the button dimming.
                    //
                    // `colorMultiply` rather than a second darkened color: the
                    // label is supplied by the caller and is not necessarily a
                    // single flat color, and multiplying scales whatever it
                    // contains by the same factor the fill is darkened by. At
                    // rest the multiplier is white, which is the identity, so
                    // the modifier is inert until the button is actually down.
                    .colorMultiply(
                        isDimmed
                            ? Color(white: 1 - darkening)
                            : .white
                    )
            }
            // Opaque backing beneath the fill.
            //
            // Not every fill in this family is opaque — the import and edit
            // controls are gray at 50% — and a shadow cast by a translucent
            // shape is visible *through* it, which stacked the shadow on top of
            // the fill and made those buttons read as markedly darker than the
            // solid green "+" beside them. Compositing the fill over an opaque
            // circle first leaves the drawn color unchanged (the sheet behind is
            // this same background) while giving the shadow something it cannot
            // show through, so every control in the family now casts the same
            // shadow.
            .background(Circle().fill(listButtonBackingFill))
            // Flattened so the shadow is cast once by the finished control
            // rather than separately by each layer of it.
            .compositingGroup()
            // Constant across press states: the shadow separates the button
            // from the background and should not flicker when clicked.
            .shadow(color: .black.opacity(Self.dropShadowOpacity),
                    radius: Self.dropShadowRadius,
                    x: 0,
                    y: Self.dropShadowY)
            // Applied to the finished, flattened control so the shadow fades
            // with it. A disabled button that still cast a full-strength shadow
            // would keep the raised, clickable silhouette the fade is trying to
            // take away.
            .opacity(isDisabled ? Self.disabledOpacity : 1)
            .frame(width: diameter, height: diameter)
            // Reserved margin so the shadow has somewhere to render rather
            // than being clipped by an ancestor, which inside a List row it
            // otherwise would be.
            .padding(Self.shadowMargin)
            .contentShape(Circle())
    }
}

// MARK: - List Button Factory

/// Shared visual treatment for every circular control on the FilmSheet: the trailing "+" and
/// import buttons, and the per-row edit and delete buttons of `ReorderableStringList`
/// (30.30 FSStringList.swift), the "+" and per-row info buttons of `ReorderableFramesList`
/// (30.40 FSFramesList.swift), and the controls in the other sheets that use the family.
///
/// It lives here rather than in any one consumer's file, so no consumer depends on another's file
/// for its chrome.
///
/// The point is a single place to tune the family's appearance. Anything that
/// legitimately varies between instances is a parameter; anything that should
/// stay uniform (shadow radii, press response) lives in `ListCircleButtonStyle`.
struct ListCircleButton: View {

    // MARK: Parameters

    /// SF Symbol drawn inside the circle.
    let systemImage: String
    /// Fill applied when the control is idle and enabled.
    let fill: Color
    /// Drawn diameter of the circle, excluding the reserved shadow margin.
    var diameter: CGFloat = 22
    /// Point size of the glyph. Kept independent of `diameter` because symbols
    /// differ widely in optical weight at the same nominal size.
    var glyphSize: CGFloat = 12
    /// When `true` the control holds `Self.activeFill` for as long as the flag
    /// is set, rather than only while the mouse is down. Used by the row edit
    /// button to show which row is currently being edited.
    var isActive: Bool = false
    var isEnabled: Bool = true
    var help: String? = nil
    var role: ButtonRole? = nil

    // MARK: Family Fills
    //
    // `activeFill` and `disabledFill` were parameters with defaults and no
    // overriders: every one of the family's call sites across the three tables
    // and `ViewingDatesTable` took the default. That is the same arrangement
    // `ListAddRowRevealer`'s `bottomPadding` was retired for, and the argument
    // is the same — these two describe states the family as a whole is supposed
    // to signal identically, so a per-instance override was never something a
    // caller should reach for. Reading one declaration is what keeps every
    // control's "this one is active" and "this one is inert" reading alike.

    /// Fill held while `isActive`.
    private static let activeFill: Color = .accentColor

    /// Fill substituted when the control is disabled.
    ///
    /// Note that this is the same gray the bulk-import control wears while fully
    /// live, which is precisely why the style also darkens and fades a disabled
    /// control rather than relying on the fill alone; see
    /// `ListCircleButtonStyle.isDisabled`.
    private static let disabledFill: Color = Color.gray.opacity(0.5)

    /// Per-symbol optical correction, forwarded to the style.
    ///
    /// Left at the family default for `pencil`. Every other in-table glyph —
    /// `plus`, `minus`, `info`, `xmark`, `list.clipboard.fill` — passes its own
    /// measured correction from `ListCircleButtonStyle`'s per-symbol constants.
    var glyphOffset: CGSize = ListCircleButtonStyle.defaultGlyphOffset

    /// Optional key equivalent, applied to the `Button` itself.
    ///
    /// A parameter rather than something the caller layers on with an outer
    /// `.keyboardShortcut` modifier, so the shortcut lands on the control
    /// directly rather than relying on SwiftUI to find the one button inside
    /// this wrapper. The only current use is the reorderable lists' Opt+Delete
    /// binding on the "-" that a row exposes while it is being edited; see
    /// `StringListRow`.
    ///
    /// Scoping comes for free from the control's own lifetime: a shortcut on a
    /// button that is not on screen is not bound, and `.disabled` suppresses it
    /// as well, so a control grayed out at the entry cap does not answer its key
    /// either.
    var shortcut: KeyboardShortcut? = nil

    let action: () -> Void

    /// Glyph treatment belongs to the label rather than the style, since the
    /// label is what the caller supplies.
    private static let glyphShadowRadius: CGFloat = 0.8
    private static let glyphShadowOpacity: CGFloat = 0.7

    /// Resolved here rather than in the style so the style has a single fill to
    /// draw and needs no knowledge of the enabled/active vocabulary.
    private var resolvedFill: Color {
        if !isEnabled { return Self.disabledFill }
        if isActive { return Self.activeFill }
        return fill
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(Self.glyphShadowOpacity),
                        radius: Self.glyphShadowRadius, x: 0, y: 0.5)
        }
        .buttonStyle(ListCircleButtonStyle(fill: resolvedFill,
                                           diameter: diameter,
                                           // Darkens the disabled state on top
                                           // of the gray fill; see the flag's
                                           // declaration for why gray alone was
                                           // not a sufficient signal.
                                           isDisabled: !isEnabled,
                                           glyphOffset: glyphOffset))
        .disabled(!isEnabled)
        .keyboardShortcut(shortcut)
        .help(help ?? "")
    }
}

// MARK: - List Popover Dismissal

/// Sequencing for a popover that commits a change to the table it is anchored to.
///
/// The problem is purely visual, appearing only when a commit changes the table's row
/// COUNT — an add, bulk import, or delete. An `NSPopover` stays positioned against its
/// anchor for as long as it's on screen, including through its own close animation. A
/// commit in the same turn as dismissal makes the table grow or shrink underneath a
/// popover still visible and tracking — the attachment point shifts, new rows shove it
/// further, then it snaps back and only then fades. Three visible jumps for one commit.
///
/// Dismissing first was already the convention at every call site, for an unrelated and
/// equally good reason: a commit can raise the table's duplicate confirmation, and an
/// alert must not compete with a live popover for the window's presentation. But "first
/// in the same run-loop turn" isn't soon enough for the animation, since SwiftUI applies
/// the array mutation before AppKit draws a single frame of the close. Holding the
/// mutation until the popover is actually gone removes the chase: it closes against a
/// table that hasn't moved, and the rows appear into empty space.
///
/// The delay is a fixed interval rather than a completion handler because SwiftUI's
/// `.popover` exposes no dismissal callback, and `onDisappear` fires when content is
/// removed, not when the window finishes animating out. A deliberate over-estimate of
/// `NSPopover`'s close animation: erring long costs imperceptible milliseconds; erring
/// short reintroduces the artifact this exists to remove.
@MainActor
enum ListPopoverDismissal {

    /// Held slightly beyond `NSPopover`'s close animation. Not a public AppKit constant,
    /// so it is measured against the observed animation rather than read from the system.
    private static let closeDuration: Duration = .milliseconds(220)

    /// Runs `commit` once the dismissing popover has finished animating away.
    ///
    /// The caller sets its presentation flag to false and hands the mutation here, in
    /// that order. `commit` must not depend on the popover's own view still existing —
    /// every call site writes through a `Binding` or calls a method on the enclosing
    /// table, both of which outlive the popover, which is the same requirement the
    /// existing dismiss-before-commit ordering already imposed.
    ///
    /// `Task { @MainActor }` rather than `DispatchQueue.main.asyncAfter`, matching
    /// `CustomTable`'s "expand after the fade settles" delay: this is dispatched from a
    /// SwiftUI button action, not from a synchronous AppKit event callback, so there is no
    /// QoS inheritance to preserve and the concurrency-native form is the correct one.
    ///
    /// The commit is also registered as pending until it runs, so `settlePending()` can
    /// run it early — see there.
    static func afterClose(_ commit: @escaping @MainActor () -> Void) {
        schedule(commit, after: closeDuration)
    }

    /// Runs `commit` on the next main-actor turn, registered as pending in the same way.
    /// For a mutation that only has to wait out the current transaction — the frames
    /// table's Clear, behind its alert — rather than a popover's close animation.
    static func nextTurn(_ commit: @escaping @MainActor () -> Void) {
        schedule(commit, after: nil)
    }

    // MARK: Settling

    /// Commits scheduled but not yet run, in scheduling order. Each removes itself when it
    /// runs, so a commit already run by `settlePending()` is not run again by its timer.
    private static var pending: [(id: UInt64, commit: @MainActor () -> Void)] = []
    private static var nextID: UInt64 = 0

    /// Set by a table that parks a commit behind its duplicate confirmation; read by
    /// `settlePending()` to report it. See `noteDeferredPrompt()`.
    private static var promptRaised = false

    private static func schedule(_ commit: @escaping @MainActor () -> Void, after delay: Duration?) {
        nextID &+= 1
        let id = nextID
        pending.append((id, commit))
        Task { @MainActor in
            if let delay { try? await Task.sleep(for: delay) }
            guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
            pending.remove(at: index).commit()
        }
    }

    /// Called by a table whose commit stopped at its duplicate confirmation instead of
    /// writing. Only meaningful during `settlePending()`.
    static func noteDeferredPrompt() {
        promptRaised = true
    }

    /// Runs every pending commit now, in the order it was scheduled.
    ///
    /// **Why.** A commit held for the close animation lands about a fifth of a second
    /// after the click. A FilmSheet save starting inside that window read the view model
    /// before the commit wrote it, so the add, edit, delete, or import was missing from
    /// the saved film. `FilmSheet.confirm()` calls this first, the way it calls the
    /// Releases tab's `settlePendingWork()`, so the save always sees the finished tables.
    /// Running early is safe: every commit re-verifies its position and cap against the
    /// live arrays, which is what it does after the delay too.
    ///
    /// Returns `true` when a commit raised its table's duplicate confirmation rather than
    /// writing. The value is not in the model until the user answers, so the caller
    /// should not save yet: the prompt is left up for the user, and the save is theirs
    /// to repeat.
    @discardableResult
    static func settlePending() -> Bool {
        promptRaised = false
        // Drained in a loop: a commit may itself schedule another.
        while !pending.isEmpty {
            pending.removeFirst().commit()
        }
        defer { promptRaised = false }
        return promptRaised
    }

    #if DEBUG
    /// Number of commits still waiting. Harness use only.
    static var pendingCount: Int { pending.count }
    #endif
}

// MARK: - Entry Popover Metrics
/// The one size every popover the FilmSheet presents from a table is drawn at — the
/// viewing-dates add and edit popovers, the bulk-import popovers, the text list's entry
/// editor, the frames table's — and the sidebar's calendar popover with them.
/// `ViewingDatesTable`'s popovers set it; the others were narrowed to match.
enum EntryPopoverMetrics {
    /// Content width, exclusive of `padding`.
    static let width: CGFloat = 290
    /// Inset on every side of the content.
    static let padding: CGFloat = 16
}

// MARK: - Bulk Import Popover

/// The comma/line-separated bulk-entry sheet shared by the reorderable list
/// components.
///
/// Held here, rather than inside either list component's own file, so neither
/// depends on the other for it. Nothing in it is specialized to a particular
/// list: the noun and the cap both arrive as parameters, so a component with a
/// limit of 99 gets the identical control with 99 in its messaging and its
/// enablement rule.
///
/// `ReorderableStringList` and `ReorderableTextList` present it. `ReorderableFramesList` presents
/// its own two-list popover, `PairedFramesImportPopover`, which borrows only `parseItems` from here
/// so that every table accepts the same separators.
struct ListImportPopover: View {

    /// Singular noun for the thing being imported — "Cast Member" gives
    /// "Import Cast Members".
    let itemLabel: String

    /// Upper bound on the resulting entry count. Supplied by the caller so the
    /// popover carries no assumption about whose list it is serving.
    let maxItems: Int

    /// How many entries the destination table is holding right now.
    ///
    /// Supplied so the popover can state and enforce the limit that applies to the mode the user
    /// is in. Appending is bounded by the *headroom*, `maxItems - currentCount`, not by `maxItems`.
    /// Replacing is bounded by `maxItems`, because it discards what is there first.
    ///
    /// It is also the single quantity the two locked states of the Replace toggle derive from; see
    /// `isAtCapacity` and `hasEntries`.
    ///
    /// Required rather than defaulted: a caller that omitted it would be told its table was empty,
    /// with full headroom and an unlocked toggle, whatever it actually held.
    let currentCount: Int

    @Binding var replaces: Bool

    /// The entry text, and the single source the readout and the Import button are computed from.
    /// Opens empty on every presentation (see `onAppear`).
    ///
    /// Local `@State` rather than a binding to the presenter's storage. A popover's content is hosted
    /// in its own window with its own update graph, so an invalidation of the presenter does not
    /// reliably re-evaluate the presented content. Writing local state invalidates this view directly,
    /// so every keystroke recomputes the parse, the count, its color, and the button's enablement
    /// together. Nothing is mirrored back to the presenter.
    @State private var draft: String = ""

    /// Working copy of the Replace toggle, mirrored back to `replaces`.
    ///
    /// Local for the same reason as `draft`: the mode feeds computations this view performs (the limit
    /// sentence, the readout color, and the Import button's enablement), so a change must invalidate
    /// this view directly. `replaces` stays mirrored so the caller's storage remains the single value
    /// the commit reads.
    ///
    /// Optional, `nil` until the first `onAppear`, so the first body evaluation reads the caller's mode.
    /// A `Bool` defaulting to `false` would briefly show "appending" for a table already forced to
    /// Replace at its cap. See `mode`.
    @State private var replaceLocal: Bool? = nil

    /// The mode in force: the local mirror once seeded, the caller's value
    /// before that. Every computation and the toggle itself read this rather
    /// than either underlying property, so there is one answer at every moment
    /// of the popover's life.
    private var mode: Bool { replaceLocal ?? replaces }

    /// What the checkbox writes. Writing the mirror rather than `replaces`
    /// directly is the whole point — see `replaceLocal` — and the mirror is
    /// carried back to the caller by the `onChange` below.
    private var modeBinding: Binding<Bool> {
        Binding(get: { mode }, set: { replaceLocal = $0 })
    }

    /// Return runs Import; Option-Return enters a line break. Owned here rather than
    /// inherited from the FilmSheet behind this popover — see the note at the
    /// `.fieldSubmitAction(_:)` call site.
    @State private var submitAction = FieldSubmitAction()

    /// Sample text shown in the empty entry area. Defaults to a name-shaped
    /// example, which suits the cast/crew lists; the text lists pass their own
    /// so the sample looks like the values they actually hold.
    var placeholder: String = "Name 1, Name 2, Name 3"

    /// Whether the destination table is already holding its maximum number of
    /// entries.
    ///
    /// At the cap, appending cannot produce anything the user asked for — the
    /// headroom is zero, so `ListImportCommit` would refuse the batch outright —
    /// so replacing is the only mode that can do any work. Rather than let the
    /// user compose a batch that cannot be submitted, the toggle is forced on,
    /// locked, and colored red, which states the constraint at the moment it
    /// applies instead of after the fact.
    ///
    /// Derived from `currentCount` rather than passed in separately. Two arguments that must agree
    /// about the same array could drift apart.
    private var isAtCapacity: Bool { currentCount >= maxItems }

    /// Whether the destination table currently holds anything at all.
    ///
    /// With an empty table, replacing and appending produce the identical
    /// result, so the toggle is locked off rather than left live to imply a
    /// choice that does not exist. The two locked states are opposites and
    /// mutually exclusive by definition — a table cannot be both empty and at
    /// its cap, given a positive cap — so there is no ordering between them to
    /// get wrong. Derived from the same single count, for the reason above.
    private var hasEntries: Bool { currentCount > 0 }

    /// Receives the parsed entries. The popover has already checked them against
    /// the limit its current mode allows — see `effectiveLimit` — but the caller
    /// is expected to re-check before mutating, which `ListImportCommit` does.
    ///
    /// The entries handed over are plain trimmed strings. A caller whose model
    /// stores something richer — `ReorderableFramesList`, whose rows are
    /// four-field comma-packed records — is expected to map them on the way in;
    /// the popover deliberately knows nothing about the destination's format.
    let onImport: ([String]) -> Void
    let onCancel: () -> Void

    /// Content width and padding: `EntryPopoverMetrics`, narrowed from the 320 this
    /// control used to carry. Nothing here needed the extra 30pt: the widest element
    /// is the entry area, which fills whatever width it is given.
    private static let width = EntryPopoverMetrics.width
    private static let padding = EntryPopoverMetrics.padding
    private static let footnoteSize: CGFloat = 11
    /// Visible lines in the entry area before it begins scrolling. Pasted lists routinely run past
    /// one line, and four lines show a useful amount of text for a modest popover height. Every
    /// table that presents this control gets the same entry area.
    private static let visibleLines: Int = 4

    // MARK: Parsing

    /// Splits on commas and line breaks, trims surrounding whitespace, and drops
    /// empties. Line breaks are accepted alongside commas because pasted crew
    /// and cast lists routinely arrive one entry per line.
    ///
    /// Duplicates are intentionally NOT filtered: two crew members can share a
    /// name, and silently dropping the second would be a data loss the user
    /// never asked for and would struggle to notice.
    static func parseItems(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The largest number of entries that may be submitted in the current mode.
    ///
    /// Replacing discards the table first, so the whole cap is available.
    /// Appending keeps what is there, so only the headroom is — clamped at zero,
    /// since a table at or (defensively) beyond its cap has none.
    ///
    /// **Why the existing entries move into the limit, not the count**
    ///
    /// Comparing `current.count + parsed.count` against `maxItems` would make the warning stick
    /// after a trim: the readout counts entries *typed*, while that condition would count the
    /// projected *result*. Trimming a paste to 30 would leave the warning up beside a readout that
    /// says "30 entries detected". So both the readout and its color count entries typed, and only
    /// the number they are compared against changes with the mode. The readout clears the moment the
    /// paste is short enough to import whole, which is exactly when Import becomes enabled.
    private var effectiveLimit: Int {
        mode ? maxItems : max(0, maxItems - currentCount)
    }

    /// Whether the number of entries typed exceeds what this mode can accept.
    private func overflows(_ parsed: [String]) -> Bool {
        parsed.count > effectiveLimit
    }

    /// The instruction line, phrased for the limit that applies.
    ///
    /// Three cases rather than one interpolated sentence, because "Separate up
    /// to 1 entries" is both ungrammatical and describes a separation there is
    /// nothing to perform. The zero case is unreachable through the UI — a full
    /// table forces and locks Replace mode, which restores the full cap — and is
    /// stated only so the control is well-defined if it is ever presented that
    /// way.
    private static func limitDescription(_ limit: Int) -> String {
        switch limit {
        case ...0: return "No room for further entries."
        case 1:    return "Room for 1 more entry."
        default:   return "Separate up to \(limit) entries with commas or line breaks."
        }
    }

    // MARK: Body

    var body: some View {
        // Parsed once per body evaluation from `draft`, and reused by the
        // readout, the enablement rule, and the commit — so the popover never
        // parses the same text twice, and all three necessarily agree. Nothing
        // here is cached, and `draft` is local state, so a keystroke recomputes
        // the count, its color, and the Import button's enabled state in the
        // same pass.
        let parsed = Self.parseItems(from: draft)
        let limit = effectiveLimit
        let isOverflowing = overflows(parsed)

        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk Import \(itemLabel)s")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // States the limit that actually applies, which changes with the
            // mode: the full cap while replacing, the remaining room while
            // appending. Stating `maxItems` unconditionally was accurate only
            // for an empty table, and for every other one it invited a paste
            // that could not fit — which the commit then silently truncated.
            //
            // Recomputed from `mode`, so toggling the checkbox updates the
            // sentence, the readout's color, and the Import button together.
            Text(Self.limitDescription(limit))
                .font(.system(size: Self.footnoteSize))
                .foregroundStyle(.secondary)

            // A scrolling text view rather than a text field: pasted lists are
            // routinely long, and four visible lines with scrolling beyond that
            // lets the whole entry be reviewed before importing. The binding is
            // updated on every keystroke, into this view's own state, so the
            // readout and the Import button stay live.
            //
            // Return runs Import and Option-Return enters a line break, via the
            // `FieldSubmitAction` installed below. Line breaks remain one of the
            // two supported entry separators — they just take Option-Return here,
            // as they do in every other instance of this control.
            FixedHeightScrollingTextView(text: $draft,
                                         placeholder: placeholder)
                .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: Self.visibleLines))

            // Label supplied as a view rather than as a string, so the red at
            // the cap applies to the text and not to the checkbox glyph beside
            // it — the constraint is being explained, not flagged as an error in
            // the control itself.
            // An AppKit checkbox beside its label rather than a Toggle wrapping it, so
            // the box is a stop in the popover's Tab walk (SheetCheckbox, above). The
            // label still toggles it on click, as a Toggle's label would.
            HStack(spacing: Preferences.spacingAfterCheckbox) {
                SheetCheckbox(isOn: modeBinding)
                Text("Replace existing entries")
                    // Three states, in priority order.
                    //
                    // Red at the cap, where the lock is a constraint being
                    // explained and the color is the explanation. An empty table
                    // locks the same control for the opposite and entirely
                    // unremarkable reason — there is nothing to replace — so it
                    // takes the system's disabled text color instead, which is
                    // exactly the treatment the frames popover's own toggled-off
                    // labels wear. Coloring that case red would read as an error
                    // the user had made.
                    //
                    // The color is stated rather than left to `.disabled`'s own
                    // dimming: that dims the checkbox and the label together as
                    // one control, which is not the same as the label reading as
                    // inactive text beside a locked box.
                    .foregroundStyle(isAtCapacity
                                     ? Color(nsColor: .systemRed)
                                     : (hasEntries
                                        ? Color(nsColor: .labelColor)
                                        : disabledControlTextColor))
                    .onTapGesture { modeBinding.wrappedValue.toggle() }
            }
            .font(.system(size: 12))
            .disabled(isAtCapacity || !hasEntries)

            Divider()

            // Cancel leads, per the platform convention for a dismissive action;
            // the readout sits directly to the left of Import, which is what it
            // describes.
            HStack(alignment: .center, spacing: 8) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Spacer(minLength: 8)

                // Shown only once something has been entered. An empty field has nothing to report.
                if !parsed.isEmpty {
                    // Colored off `isOverflowing` — the exact term the Import
                    // button is disabled on — rather than off a separately
                    // written comparison. One rule, so the red and the disabled
                    // button can only ever appear and clear together.
                    //
                    // The readout counts entries *typed*, which keeps it in step with its own
                    // color. The mode's headroom is expressed in the limit it is compared against,
                    // not by adding the table's existing entries into the number shown.
                    Text(parsed.count == 1
                         ? "1 entry detected"
                         : "\(parsed.count) entries detected")
                        .font(.system(size: Self.footnoteSize))
                        .foregroundStyle(isOverflowing
                                         ? Color(nsColor: .systemRed)
                                         : Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button("Import") { onImport(parsed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.isEmpty || isOverflowing)
            }
        }
        .frame(width: Self.width)
        .padding(Self.padding)
        // Return runs Import; Option-Return enters a line break.
        //
        // Stated here rather than inherited. This popover is presented from inside the
        // FilmSheet, and SwiftUI popovers inherit the presenting view's environment — so
        // without its own value, Return would run the *sheet's* action and save and
        // dismiss the whole sheet behind a paste the user had not imported yet.
        //
        // Line breaks remain a supported entry separator here, which is the reason this
        // field is a text view rather than a text field. They are entered with
        // Option-Return, exactly as they are in every other instance of this control.
        .fieldSubmitAction(submitAction)
        .onAppear {
            // Every presentation opens empty — reset here rather than relied upon
            // from the property initializer, since SwiftUI may reuse this node for a
            // later presentation.
            if !draft.isEmpty { draft = "" }
            // The mode this presentation opens in, resolved once and then
            // written to both copies, so the local mirror and the caller's
            // storage can never begin a session disagreeing.
            //
            // The presenting table also sets `replaces` before presenting. Resolving it here as
            // well makes the two locked rules properties of the control itself, rather than of
            // each call site. At the cap, replacing is the only mode that can do
            // any work, so it is forced ON; with nothing to replace, the two
            // modes are identical, so it is locked OFF. The two conditions are
            // mutually exclusive given a positive cap, so their order is
            // immaterial. Every write is guarded, so a popover that already
            // agrees writes nothing.
            var resolved = replaces
            if isAtCapacity { resolved = true }
            if !hasEntries { resolved = false }
            if replaces != resolved { replaces = resolved }
            if replaceLocal != resolved { replaceLocal = resolved }
            // Installed in `onAppear`, not in `body` — assigning the handler is a
            // mutation of a shared object and must not happen during view
            // evaluation. The closure captures this view value, and `@State`
            // reads route through SwiftUI's storage rather than a captured copy,
            // so `draft` is the text current at the moment Return is pressed.
            //
            // The entries are re-parsed here rather than read from the body's
            // `parsed` local, which is a per-evaluation value this closure has no
            // access to. Same function, same input, so the two necessarily agree —
            // and the two conditions below are precisely the Import button's own
            // `.disabled(parsed.isEmpty || isOverflowing)`. Returning false when
            // either holds is what makes Return inert exactly when the button is,
            // rather than importing something the button would have refused.
            submitAction.setHandler {
                let items = Self.parseItems(from: draft)
                guard !items.isEmpty, !overflows(items) else { return false }
                onImport(items)
                return true
            }
        }
        // Cleared on dismissal so a handler capturing a finished presentation cannot
        // survive into the next one if SwiftUI reuses this node.
        .onDisappear {
            submitAction.setHandler(nil)
        }
        // Mirrored back on every change, so the caller's storage stays the one value the commit
        // reads. The mirror-back runs in the same update as the toggle's write, and Import is
        // necessarily a later interaction, so the commit never reads a stale mode.
        .onChange(of: replaceLocal) { _, newValue in
            guard let newValue else { return }
            if replaces != newValue { replaces = newValue }
        }
    }
}

// MARK: - Standard Stepper Component
// The plain clamped Stepper, for callers with no Delete (ReleaseCard's discs count and
// DHCardProfile's preview). RatingStepper below is the ClearableStepperView counterpart.
struct StandardStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(value: Binding<Int>, in range: ClosedRange<Int>) {
        self._value = value
        self.range = range
    }

    var body: some View {
        Stepper(value: $value, in: range) {
            Text("\(value)")
                .frame(width: 41, alignment: .trailing)
                .foregroundStyle(.primary)
                // Prevent the ambient spring transaction from the release card carousel
                // from animating the label text's position during card navigation.
                // SwiftUI can interpolate a Text view's geometry when an ambient
                // transaction is in flight — .contentTransition(.identity) opts this
                // text out of content-driven animation, keeping it visually static.
                .contentTransition(.identity)
        }
        // 1 pt tighter than padding(4), as every Stepper widget in the family is.
        .padding(3)
        // A windowBackgroundColor fill (slightly darker than the controlBackgroundColor of
        // the surrounding ReleaseCard) so the Stepper reads as an interactive control.
        .stepperChrome(filled: true)
    }
}

// MARK: - HandBrake RF Value Stepper Component
/// The FilmSheet's "HandBrake RF Value" stepper.
///
/// Carries the same not-activated placeholder behavior the year-based steppers in
/// CustomDateStepper have: a field the user has never set shows a placeholder in the
/// tertiary label color rather than a number, the first click activates the field
/// instead of stepping it, and Delete while the AppKit focus ring is on the control
/// returns it to the un-activated state.
///
/// Activation state is derived from the value itself rather than tracked in a
/// separate flag, because the model field already carries it: 0 is the "no value"
/// sentinel persisted for a film whose RF value has never been set, and the
/// activated range starts at 1. There is therefore no state the view could hold that
/// the binding does not already express, and no way for the two to disagree — which
/// is what `shouldActivateInsteadOfIncrement`'s long note in CustomDateStepper is
/// about, where the committed flag and the view-local one are genuinely separate.
///
/// The first click commits `activationValue` (22, HandBrake's own default RF) rather
/// than 1 or 51, so the user starts from a usable value and moves up or down from
/// there. Stepping below 1 is refused: 0 is the sentinel, and reaching it by stepping
/// would clear the field out from under a user who was only walking the value down.
/// Delete is the way back out.
struct HBRFValueStepper: View {
    @Binding var value: Int

    /// The value the first click commits — HandBrake's own default RF.
    static let activationValue = 22
    /// The lowest value reachable by stepping. 0 is the un-activated sentinel and is
    /// only ever reached through Delete.
    static let minimumValue = 1
    static let maximumValue = 51

    /// Shown while the field is un-activated. Matches RatingStepper's zero label.
    private static let placeholder = "None"

    private var isActivated: Bool { value != 0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(isActivated ? "\(value)" : Self.placeholder)
                .frame(width: 41, alignment: .trailing)
                // Tertiary for the placeholder, the shade CustomDateStepper's un-activated fields use.
                .foregroundStyle(isActivated ? Color.primary : tertiaryLabelColor)
                // Same rationale as StandardStepper above — prevent an ambient spring
                // transaction from animating this label's geometry.
                .contentTransition(.identity)
            ClearableStepperView(
                value: $value,
                range: Self.minimumValue...Self.maximumValue,
                onIncrement: { step(by: 1) },
                onDecrement: { step(by: -1) },
                onDelete: { value = 0 }
            )
        }
        // 1 pt tighter than padding(4), matching StandardStepper.
        .padding(3)
        .stepperChrome(filled: true)
    }

    /// One step in `direction`, or the activating click when the field is empty.
    ///
    /// The activating click is thrown away as a step — it only commits
    /// `activationValue` — so the user sees the default appear and decides from there
    /// which way to move, exactly as the year steppers' first click does.
    ///
    /// Neither bound wraps. The value stops at 1 and at 51 the way StandardStepper's
    /// clamped range does; wrapping is a year-stepper behavior, where the range is
    /// cyclical in the user's mind and both ends are ordinary values.
    private func step(by direction: Int) {
        guard isActivated else {
            value = Self.activationValue
            return
        }
        let stepped = value + direction
        guard stepped >= Self.minimumValue, stepped <= Self.maximumValue else { return }
        value = stepped
    }
}

// MARK: - Rating Stepper Component
// Maps a value of zero to "None", and Delete (while the stepper holds the AppKit focus
// ring, intercepted via ClearableStepperView) clears it back to zero — the same
// value-as-sentinel arrangement HBRFValueStepper uses. The sole caller is DetailsView's
// User Rating row. StandardStepper above is the counterpart for callers with no Delete.
struct RatingStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(value: Binding<Int>, in range: ClosedRange<Int>) {
        self._value = value
        self.range = range
    }

    var body: some View {
        // spacing: 8 matches SwiftUI's default HStack spacing — the same
        // gap Stepper { label } places between its label and NSStepper buttons.
        HStack(spacing: 8) {
            Text(value == 0 ? "None" : "\(value)")
                .frame(width: 41, alignment: .trailing)
                .contentTransition(.identity)
            ClearableStepperView(
                value: $value,
                range: range,
                onIncrement: { if value < range.upperBound { value += 1 } },
                onDecrement: { if value > range.lowerBound { value -= 1 } },
                onDelete: { value = 0 }
            )
        }
        // 1 pt tighter than padding(4), matching StandardStepper.
        .padding(3)
        .stepperChrome(filled: true)
    }
}

/// A table-based UI for managing past viewing dates with add/edit/delete functionality.
/// Operates exclusively in FilmSheet mode: all mutations are applied to the bound
/// calendarTable array and the parent FilmSheet handles persistence on confirmation.
@MainActor
struct ViewingDatesTable: View, Loggable {
    nonisolated static let logTag = "[ViewingDatesTable]"

    // Shared formatters, reused across calls rather than rebuilt each time.
    //
    // displayFormatter is local: "MMMM d, yyyy" is this table's own presentation and
    // is written nowhere. databaseFormatter is the one that matters — it writes the
    // persisted "yyyy.MM.dd" values in calendarTable, which WatchDetails and
    // CalendarPopover read back and compare as plain strings — so it is the shared
    // StorageDateFormatters.dot rather than a fourth copy of that configuration kept in
    // step with the other three by hand.
    nonisolated static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
    nonisolated static let databaseFormatter = StorageDateFormatters.dot

    @Binding var isTableExpanded: Bool
    
    // Binding to the FilmSheet view model's calendarTable array
    var calendarTableBinding: Binding<[String]>

    /// The film's release date, passed through from FSTabDetails (which already holds it
    /// as a `Date`) so the add/edit date pickers can clamp their lower bound to it. `nil`
    /// means no release date is set — see releaseDateMin, which also applies the
    /// overrideDateClamp preference on top of this value.
    var releaseDate: Date?

    /// Optional external trigger: a monotonic token the parent bumps to programmatically
    /// open the add popover (e.g., via keyboard shortcut). Zero means "never fired".
    ///
    /// A TOKEN, NOT A FLAG, and the difference is load-bearing on two counts.
    ///
    /// A `Binding<Bool>` cannot represent "fire again while already true", so the flag had to
    /// be reset the instant it was consumed — and the only place to do that was inside the
    /// `.onChange` that observed it. Writing an observed value from its own handler makes the
    /// value change twice inside one update pass, which SwiftUI reports as
    /// "onChange(of: Bool) action tried to update multiple times per frame" and then coalesces
    /// on its own terms. A token needs no reset at all: every invocation is a distinct value,
    /// so a rapid second request is a genuinely new one rather than a flag that has to be
    /// lowered before it can be raised again.
    var externalAddTrigger: Binding<Int>?

    /// When `true`, the `autoExpandRightSidebarTables` preference is ignored and the table
    /// always loads collapsed, regardless of the preference value. Defaults to `false` so
    /// all call sites that do not pass this parameter retain existing behavior.
    var disableAutoExpand: Bool = false
    
    // Preference to control automatic table expansion
    @AppStorage(preference: Preferences.autoExpandRightSidebarTablesKey)
    private var autoExpandRightSidebarTables: Bool
    
    // Computed binding that respects the preference unless disableAutoExpand overrides it.
    // When disableAutoExpand is true, the preference is bypassed and the live binding is
    // always returned, keeping the table collapsed on load regardless of the preference.
    private var effectiveIsTableExpanded: Binding<Bool> {
        (!disableAutoExpand && autoExpandRightSidebarTables) ? .constant(true) : $isTableExpanded
    }
    
    @State private var selectedDateID: String?
    @State private var showAddPopover = false
    @State private var showEditPopover = false
    @State private var addPopoverDate = Date()
    @State private var addPopoverHasValue = true
    @State private var addPopoverVersion: ViewingVersion = .none
    /// The version menu's rows, shared by the add and edit popovers. `.none` (empty
    /// display name) is the placeholder row.
    private static let versionItems: [SheetPopUpButton<ViewingVersion>.Item] =
        ViewingVersion.allCases.map {
            .option(tag: $0, title: $0.displayName.isEmpty ? "Select…" : $0.displayName)
        }
    @State private var editPopoverDate = Date()
    @State private var editPopoverHasValue = true
    @State private var editPopoverVersion: ViewingVersion = .none
    @State private var hasChanges = false

    // Local alert shown when the user attempts to commit a date that collides with an
    // existing entry's calendar day. Scoped to this table's own popovers rather than
    // routed through AlertHostView — see AlertCommand.duplicateViewingDate's doc comment.
    @State private var showingDuplicateDateAlert = false

    /// Which popover to reopen once showingDuplicateDateAlert is dismissed. macOS
    /// automatically closes an open NSPopover the instant this alert's NSAlert sheet
    /// is presented, so both showAddPopover/showEditPopover get force-flipped to
    /// false as a side effect — this records which one to bring back. Unlike
    /// UnifiedViewingPopover, the entry fields themselves (addPopoverDate,
    /// editPopoverDate, etc.) already live on this table, not on the popover content
    /// itself, so they survive that forced close untouched; only the "should this
    /// popover be showing" flag needs to be restored.
    private enum PendingPopoverReopen: Equatable { case add, edit }
    @State private var pendingPopoverReopen: PendingPopoverReopen?

    // Read calendar table from the binding
    private var calendarTable: [String] {
        calendarTableBinding.wrappedValue
    }

    /// The film's release date, used as both date pickers' lower bound. `nil` when no
    /// release date is set, in which case CustomDateStepper applies no clamp (per its
    /// documented no-op contract). Also `nil` when Preferences.overrideDateClamp is
    /// true, allowing the user to temporarily add viewing events dated prior to the
    /// film's release date.
    private var releaseDateMin: Date? {
        guard !Preferences.overrideDateClamp else { return nil }
        return releaseDate
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Table with edit popover attached to individual rows
            ViewingDatesTableContent(
                isTableExpanded: effectiveIsTableExpanded,
                selectedDateID: $selectedDateID,
                dates: calendarTable,
                showEditPopover: $showEditPopover,
                editPopoverContent: editDatePopover,
                onRowTap: { dateID in
                    handleRowTap(dateID: dateID)
                }
            )
            .frame(width: 268)

            // Add New Date green "+" button, from the shared factory above so
            // its press response, shadow, and optical glyph centering match
            // every other circular control on the sheet.
            //
            // Drawn at 22/12 — the factory's own defaults, and the same diameter
            // the reorderable lists' trailing control uses, so every control
            // sitting beside a table on this sheet is one size.
            //
            // The concern with enlarging it was alignment, not size: this
            // control sits beside a `CustomTable`, and it is centered on that
            // table's 24pt header band rather than on a list row. The offset is
            // what states that, and it has to move with the diameter.
            //
            // The offset is 0. Centering the padded control in the 24pt header band gives
            // (24 - 22) / 2 - 2 = -1, but the band begins 1pt lower than that arithmetic
            // assumes, so the rendered result is correct at 0.
            //
            // Nothing downstream absorbs the extra size. The padded control is
            // 26pt tall against a table at least 167pt tall (24pt header plus
            // 6.5 rows of 22pt), and this `HStack` is top-aligned, so the row's
            // height is still the table's. Horizontally the control is the
            // trailing element with free space beyond it.
            ListCircleButton(
                systemImage: "plus",
                fill: Preferences.green,
                diameter: 22,
                glyphSize: 12,
                help: "Add a viewing date",
                action: {
                    addPopoverDate = Date()
                    addPopoverHasValue = true
                    addPopoverVersion = .none
                    showAddPopover = true
                }
            )
            .offset(y: 0)
            .popover(isPresented: $showAddPopover, arrowEdge: .trailing) {
                addDatePopover
                    .frame(width: EntryPopoverMetrics.width)
                    .padding(EntryPopoverMetrics.padding)
            }
        }
        // Scroll-position monitor, done in AppKit rather than in SwiftUI. A `GeometryReader`
        // reading `frame(in: .global)` would force an extra layout pass. `ScrollActivityObserver`
        // watches the enclosing clip view's `boundsDidChangeNotification`, which AppKit posts
        // anyway, so it adds no layout on any pass.
        //
        // The guards matter as much as the observer: a clip view's bounds also change on resize,
        // and with no popover open both branches only read a `Bool`. No state is written.
        .background(
            ScrollActivityObserver {
                if showAddPopover { showAddPopover = false }
                if showEditPopover {
                    showEditPopover = false
                    selectedDateID = nil
                }
            }
        )
        .onChange(of: showEditPopover) { _, newValue in
            if !newValue {
                // Skip the clear if this closure was caused by the system force-closing
                // the popover to present the duplicate-date alert — selectedDateID must
                // survive so the correct row's popover reopens once the alert clears.
                guard pendingPopoverReopen != .edit else { return }
                // Clear selection when edit popover closes
                selectedDateID = nil
            }
        }
        .onChange(of: selectedDateID) { _, newValue in
            // Open edit popover when a date is selected
            if newValue != nil {
                hasChanges = false  // Reset changes flag for new edit session
                showEditPopover = true
            }
        }
        .onChange(of: externalAddTrigger?.wrappedValue ?? 0) { _, token in
            // Zero is the resting value and also what the expression collapses to if the
            // binding itself goes away, so it is never a request. Every other change is one:
            // the token only ever advances, and nothing here writes it back. See
            // `externalAddTrigger` for why this is a token rather than a flag.
            guard token != 0 else { return }
            addPopoverDate = Date()
            addPopoverHasValue = true
            addPopoverVersion = .none
            showAddPopover = true
        }
        .alert("Event Already Exists", isPresented: $showingDuplicateDateAlert) {
            Button("OK") {
                // The system already force-closed the relevant popover the instant
                // this alert appeared; every entry field (addPopoverDate/Version or
                // editPopoverDate/Version + selectedDateID) already lives on this
                // table rather than on the popover's own content, so simply flipping
                // the presentation flag back on restores exactly what was entered.
                switch pendingPopoverReopen {
                case .add: showAddPopover = true
                case .edit: showEditPopover = true
                case nil: break
                }
                pendingPopoverReopen = nil
            }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("There is already a viewing event for the selected date. Please choose a different date.")
        }
    }
    
    // MARK: - Add Date Popover
    
    @ViewBuilder
    private var addDatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add New Date")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // Date picker
            ViewingFormRow("Select date:") {
                CustomDateStepper(date: $addPopoverDate, hasValue: $addPopoverHasValue, minDate: releaseDateMin, maxDate: Date())
            }
            
            // Version picker
            ViewingFormRow("Version:") {
                SheetMenuPicker(selection: $addPopoverVersion,
                                items: Self.versionItems, width: 183)
            }
            
            Divider()
            
            HStack(spacing: 8) {
                Button("Cancel") {
                    showAddPopover = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Add") {
                    guard !isDuplicateBaseDate(addPopoverDate) else {
                        // The system is about to force-close this popover the instant
                        // the alert appears; record which one to bring back.
                        pendingPopoverReopen = .add
                        showingDuplicateDateAlert = true
                        return
                    }
                    addNewDate()
                    showAddPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
    
    // MARK: - Edit Date Popover
    
    @ViewBuilder
    private var editDatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Existing Date")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            
            // Date picker
            ViewingFormRow("Select date:") {
                CustomDateStepper(date: $editPopoverDate, hasValue: $editPopoverHasValue, minDate: releaseDateMin, maxDate: Date())
                    .onChange(of: editPopoverDate) { _, _ in
                        hasChanges = true
                    }
            }
            
            // Version picker
            ViewingFormRow("Version:") {
                SheetMenuPicker(selection: $editPopoverVersion,
                                items: Self.versionItems, width: 183)
                    .onChange(of: editPopoverVersion) { _, _ in
                        hasChanges = true
                    }
            }
            
            Divider()
            
            HStack(spacing: 8) {
                Button("Cancel") {
                    showEditPopover = false
                }
                .keyboardShortcut(.cancelAction)
                
                // Shared with the frames and text lists' editing popovers, so
                // the three cannot disagree about the treatment a red label
                // needs over a vibrant material. The full account of why the
                // destructive role is dropped and a blend mode stated is on
                // `PopoverDeleteButton`.
                //
                // Deletion runs before the dismissal here, unlike the two
                // lists': this table's popover is anchored to a control that
                // survives the delete, so there is no teardown to order around.
                PopoverDeleteButton {
                    deleteSelectedDate()
                    showEditPopover = false
                }
                
                Spacer()
                
                Button("Update") {
                    guard !isDuplicateBaseDate(editPopoverDate, excludingEntry: selectedDateID) else {
                        // The system is about to force-close this popover the instant
                        // the alert appears; record which one to bring back.
                        pendingPopoverReopen = .edit
                        showingDuplicateDateAlert = true
                        return
                    }
                    updateSelectedDate()
                    showEditPopover = false
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
    
    // MARK: - Actions
    
    private func handleRowTap(dateID: String) {
        // dateID is now the full dateString including version code (stable ID)
        // Extract just the date portion for the date picker
        guard let date = parseDate(from: dateID) else { return }
        
        selectedDateID = dateID
        editPopoverDate = date
        editPopoverHasValue = true
        // Extract the version code from the existing entry
        editPopoverVersion = extractVersionCode(from: dateID)
        // hasChanges reset and showEditPopover are handled by onChange(of: selectedDateID)
    }
    
    private func addNewDate() {
        let dateString = formatDateForDatabase(addPopoverDate, version: addPopoverVersion)
        calendarTableBinding.wrappedValue.append(dateString)
    }
    
    private func updateSelectedDate() {
        guard let selectedDateString = selectedDateID else { return }
        let dates = calendarTable
        guard let index = dates.firstIndex(of: selectedDateString) else { return }
        let newDateString = formatDateForDatabase(editPopoverDate, version: editPopoverVersion)
        calendarTableBinding.wrappedValue[index] = newDateString
    }
    
    private func deleteSelectedDate() {
        guard let selectedDateString = selectedDateID else { return }
        let dates = calendarTable
        guard let index = dates.firstIndex(of: selectedDateString) else { return }
        calendarTableBinding.wrappedValue.remove(at: index)
    }

    /// True when `date` falls on the same calendar day (ignoring any version code) as
    /// an entry already present in the calendar table. A film may only have one viewing
    /// event per calendar day. `addViewing()` in WatchDetails (24.12) enforces the same
    /// base-date invariant for the CalendarPopover flow.
    /// - Parameter excludingEntry: When editing an existing entry, pass its current full
    ///   dateString (selectedDateID) so the entry being edited never collides with itself
    ///   — e.g. when only its version code changed and its date did not.
    private func isDuplicateBaseDate(_ date: Date, excludingEntry: String? = nil) -> Bool {
        let candidateBaseDate = ViewingDatesTable.databaseFormatter.string(from: date)
        return calendarTable.contains { entry in
            guard entry != excludingEntry else { return false }
            return extractDatePortion(from: entry) == candidateBaseDate
        }
    }
    
    // MARK: - Helper Functions
    private func formatDateForDatabase(_ date: Date, version: ViewingVersion) -> String {
        let dateString = ViewingDatesTable.databaseFormatter.string(from: date)
        // Only append version code if it's not empty (i.e., not .none)
        if version.rawValue.isEmpty {
            return dateString
        } else {
            return "\(dateString).\(version.rawValue)"
        }
    }
}

// MARK: - Supporting Types
private struct ViewingDateRow: Identifiable {
    var id: String { dateString }  // Use dateString as stable ID (includes version code)
    let dateString: String  // Original format including version code
    let formattedDate: String  // Display format "Month Day, Year"
    let version: String  // Display version (empty string for .none)
}

private struct ViewingDatesTableContent: View {
    @Binding var isTableExpanded: Bool
    @Binding var selectedDateID: String?
    let dates: [String]
    @Binding var showEditPopover: Bool
    let editPopoverContent: AnyView
    let onRowTap: (String) -> Void

    // Cached table rows — rebuilt only when `dates` changes, not on every render.
    // parseDate + DateFormatter.string() + extractVersionCode per entry are non-trivial;
    // caching prevents them from firing on every SwiftUI layout pass.
    @State private var cachedRows: [ViewingDateRow] = []
    
    init(isTableExpanded: Binding<Bool>,
         selectedDateID: Binding<String?>,
         dates: [String],
         showEditPopover: Binding<Bool>,
         editPopoverContent: some View,
         onRowTap: @escaping (String) -> Void) {
        self._isTableExpanded = isTableExpanded
        self._selectedDateID = selectedDateID
        self.dates = dates
        self._showEditPopover = showEditPopover
        self.editPopoverContent = AnyView(editPopoverContent)
        self.onRowTap = onRowTap
        // Seed the cache on first creation so the table is populated immediately.
        self._cachedRows = State(initialValue: ViewingDatesTableContent.buildRows(from: dates))
    }
    
    // MARK: - Row Building

    private static func buildRows(from dates: [String]) -> [ViewingDateRow] {
        dates
            .compactMap { dateString -> (original: String, date: Date)? in
                guard let date = parseDate(from: dateString) else { return nil }
                return (dateString, date)
            }
            .sorted { $0.date > $1.date }
            .map { item in
                ViewingDateRow(
                    dateString: item.original,
                    formattedDate: ViewingDatesTable.displayFormatter.string(from: item.date),
                    version: extractVersionCode(from: item.original).displayName
                )
            }
    }
    
    var body: some View {
        CustomTable(
            cachedRows,
            columns: [
                CustomTableColumn("Date", minWidth: 122, maxWidth: 122),
                CustomTableColumn("Version", minWidth: 96, maxWidth: 96)
            ],
            isExpanded: $isTableExpanded,
            selectedID: $selectedDateID,
            allowSelection: true,
            onRowTap: onRowTap
        ) { row in
            CustomTableCell(row.formattedDate, minWidth: 122, maxWidth: 122)
            CustomTableCell(row.version, minWidth: 96, maxWidth: 96)
                .popover(isPresented: Binding(
                    get: { showEditPopover && selectedDateID == row.id },
                    set: { if !$0 { showEditPopover = false } }
                ), arrowEdge: .trailing) {
                    editPopoverContent
                        .frame(width: EntryPopoverMetrics.width)
                        .padding(EntryPopoverMetrics.padding)
                }
        }
        // The outer chrome of the reorderable lists (see `listContainerChrome`): content clipped
        // inside the border's 1pt ring and the fading outline stroked into that ring. The
        // shadow rides on an opaque backing plate rather than the table itself, so the
        // collapsed table's "Show All" button and fade don't cast shadows of their own.
        .fieldEdgeChrome(clipsContent: true, insetsInterior: true)
        // Refresh cached rows only when the underlying dates array changes.
        .onChange(of: dates) { _, newDates in
            cachedRows = ViewingDatesTableContent.buildRows(from: newDates)
        }
    }
}

// MARK: - Duration Helpers
struct DurationHelpers {
    /// A stored runtime — the Film model's millisecond string, `duration` or
    /// `editedDuration` — in whole minutes, or nil when it is missing, unparseable, or not
    /// positive. The one reading of that field for display: the right sidebar and gallery
    /// list (through `RSBHelpers.hoursAndMinutes`), search, and the Reports tab's
    /// statistics all go through here. (The gallery's duration sort and its divider bands
    /// read the field their own way, together, because the bands must match the sort; see
    /// MetadataCache's `.duration` case.)
    nonisolated static func storedMinutes(_ milliseconds: String?) -> Int? {
        // `isFinite` and the upper bound keep a corrupt stored value ("inf", "1e300") from
        // trapping in the Int conversion below.
        guard let milliseconds, let value = Double(milliseconds), value > 0, value.isFinite,
              value < 1e15 else { return nil }
        return Int(value / 1000 / 60)
    }

    /// Converts milliseconds to hours and minutes
    /// - Parameter milliseconds: Duration in milliseconds
    /// - Returns: Tuple of (hours, minutes)
    static func millisecondsToHoursAndMinutes(_ milliseconds: Int) -> (hours: Int, minutes: Int) {
        let totalSeconds = milliseconds / 1000
        let totalMinutes = totalSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return (hours, minutes)
    }
    
    /// Converts hours and minutes to milliseconds
    /// - Parameters:
    ///   - hours: Number of hours
    ///   - minutes: Number of minutes
    /// - Returns: Total duration in milliseconds
    static func hoursAndMinutesToMilliseconds(hours: Int, minutes: Int) -> Int {
        let totalMinutes = (hours * 60) + minutes
        let totalSeconds = totalMinutes * 60
        return totalSeconds * 1000
    }
}

// MARK: - Control Size

extension NSControl.ControlSize {
    /// The AppKit size for a SwiftUI `.controlSize`, for the sheet's AppKit-backed controls
    /// to follow the environment the way SwiftUI's own controls do.
    init(_ size: ControlSize) {
        switch size {
        case .mini:       self = .mini
        case .small:      self = .small
        case .large:      self = .large
        case .extraLarge: self = .large
        default:          self = .regular
        }
    }
}

// MARK: - Checkbox
//
// The sheet's checkbox: an `NSButton` checkbox driven directly, in place of SwiftUI's
// `Toggle`. Used by the ReleaseCard's Purchased control (33.20) and by the checkboxes on the
// Details, Metadata, and frames-list controls.
//
// MARK: Why not the SwiftUI Toggle
//
// Keyboard focus, not cost. SwiftUI's checkbox is an NSButton too (a private subclass), but
// one that REFUSES first responder. SwiftUI keeps the checkbox out of AppKit's responder chain
// and moves keyboard focus to it through its own focus engine, with the hosting view standing in
// as the first responder. The sheet's Tab traversal bypasses that engine: FilmSheetKeyLoop
// (30.01 FilmSheetView.swift) walks AppKit first responders by geometry. A SwiftUI Toggle could
// therefore never be a stop in it. An NSButton of our own accepts first responder like every
// other control, draws AppKit's focus ring when it has it, and toggles on Space.
//
// MARK: What is kept identical
//
// The same control SwiftUI builds — `NSButton(checkboxWithTitle:)`, i.e. a `.switch`-type
// button with an empty title, regular control size — so the glyph, the check animation and
// accessibility are AppKit's either way. The enabled state is mirrored from the SwiftUI
// environment exactly as `ReleasePopUpButton` and `ClearableStepperView` do it, including
// `refusesFirstResponder`, so a disabled checkbox (a combo-pack child's) drops out of the Tab
// loop rather than sitting in it as a dead stop.
struct SheetCheckbox: NSViewRepresentable {
    @Binding var isOn: Bool
    /// A title drawn beside the box, as `Toggle(isOn:) { Text(title) }` would; empty for a
    /// bare box with the row's own label elsewhere.
    var title: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.toggled(_:)))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        // Re-pointed on every update, as ReleasePopUpButton's coordinator is: a merged combo
        // pack re-points the card at another release without rebuilding it.
        context.coordinator.isOn = $isOn
        if button.title != title { button.title = title }
        // The environment's control size, as SheetPopUpButton mirrors it. Every sheet call
        // site is regular, the button's own default, so nothing changes there. A small
        // size is followed as well, and the title's font follows the size, as AppKit's own
        // small checkbox's does.
        // Keyed off the font, not the control size, for the reason SheetPopUpButton gives:
        // a zero-frame button already reports `.small`, so a size guard alone would never
        // install the small font.
        let nsSize = NSControl.ControlSize(context.environment.controlSize)
        if button.controlSize != nsSize { button.controlSize = nsSize }
        let fontSize = NSFont.systemFontSize(for: nsSize)
        if button.font?.pointSize != fontSize { button.font = NSFont.systemFont(ofSize: fontSize) }
        let enabled = context.environment.isEnabled
        button.isEnabled = enabled
        button.refusesFirstResponder = !enabled
        let state: NSControl.StateValue = isOn ? .on : .off
        if button.state != state { button.state = state }
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool> = .constant(false)

        @objc func toggled(_ sender: NSButton) {
            let value = sender.state == .on
            if value != isOn.wrappedValue { isOn.wrappedValue = value }
        }
    }
}


// MARK: - Pop-up Button
//
// The sheet's single-select control: an `NSPopUpButton` driven directly, in place of SwiftUI's
// `Picker(.menu)`. Every menu-style picker in the FilmSheet is one of these — the release
// card's (through `TaggedPicker` / `ReleasePopUpButton`, 33.20), the Details and Metadata
// tabs' (through `SheetMenuPicker` below), the frames-list fade rows' and the viewing-date
// popovers'.
//
// MARK: Why not the SwiftUI Picker
//
// The `card-perf` harness scenario (99.50) shows that a SwiftUI menu Picker's cost to mount
// and to re-evaluate grows with its item count. A release card carries eight or nine pickers
// with about 70 items between them, which is a large share of the time it takes to mount a
// card, and therefore of the turn between an arrow press and the first frame of the navigation
// spring. Other tabs carry fewer pickers, but the per-item cost is the same wherever a picker
// sits. What SwiftUI builds is an ordinary `NSPopUpButton` (a private subclass) holding plain
// `NSMenuItem`s with plain titles; the cost is its per-item view adaptor, not AppKit. Building
// the same menu directly in AppKit costs about the same regardless of item count.
//
// MARK: What is kept identical
//
// The control is the same AppKit class SwiftUI uses, configured the way SwiftUI configures it
// (rounded bezel, bordered, regular control size, 13 pt system font, `pullsDown: false`,
// `autoenablesItems` off), so the bezel, the pop-up-over-the-selected-item behavior, keyboard
// type-select, and accessibility are AppKit's own either way. SwiftUI lays a representable out
// through the button's alignment rect exactly as it does its own Picker, so with the call
// site's frame at `layoutHeight` the 25 pt bezel overhangs the row exactly as before —
// verified against the pre-change control frames by the same harness scenario.
//
// MARK: Selection is re-asserted after every write
//
// The coordinator writes the chosen tag through the binding and then selects whatever the
// binding REPORTS afterward. For an ordinary field those agree. For the release card's Type
// picker they may not: its binding declines a write that needs confirming (see
// `_TypeVersionsRow`, 33.20), and the menu would otherwise go on marking the abandoned choice
// as selected until something else pushed a value down. Re-selecting from the binding on the
// same turn means the menu never needs a view rebuild to show the binding's value.
struct SheetPopUpButton<Value: Hashable>: NSViewRepresentable {
    /// One menu row. A separator carries no tag and can never be selected; a disabled option
    /// keeps its row (and stays selected if it is the stored value) but cannot be chosen.
    enum Item: Equatable {
        case option(tag: Value, title: String, isEnabled: Bool = true)
        case separator
        /// A label for the rows below it, in the style of the app's other menu headers
        /// ("Sort By:" in SortFilterMenu): secondary color, and never selectable.
        case header(String)
        /// The collapsed title shown while `tag` (a value meaning "nothing chosen yet") is
        /// the selection — "Select…". A hidden row: it is never in the open menu, so once
        /// the menu opens, a real option has to be chosen.
        case placeholder(tag: Value, title: String)
    }

    /// Layout height of the button at the regular control size.
    ///
    /// 20, not the 25 pt the NSPopUpButton's frame measures: SwiftUI lays the control out by
    /// its alignment rect and lets the bezel overhang it, as it does for its own
    /// `Picker(.menu)`, whose layout height is 20 with a 25 pt frame. Measured by the
    /// `card-perf` harness scenario's frame dump.
    nonisolated static var layoutHeight: CGFloat { 20 }

    @Binding var selection: Value
    let items: [Item]
    /// Whether the button re-selects what the binding reports right after a write (see "Selection
    /// is re-asserted after every write" above). `SubcategoryPicker` turns it off: its binding's
    /// getter returns the value its body captured, which is still the OLD choice until SwiftUI
    /// re-renders, so re-asserting flashed the stale title for a frame. Its writes are never
    /// declined, so there is nothing to re-assert.
    var reassertsSelectionAfterWrite = true

    /// `items` plus the tag-set guarantee: a selection no row carries gets a row of its own,
    /// titled with the raw stored value, so a value outside the vocabulary stays visible rather
    /// than rendering as a blank menu.
    private var effectiveItems: [Item] {
        let hasTag = items.contains { item in
            switch item {
            case .option(let tag, _, _), .placeholder(let tag, _): return tag == selection
            default: return false
            }
        }
        return hasTag ? items : items + [.option(tag: selection, title: String(describing: selection))]
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.imagePosition = .noImage
        button.alignment = .natural
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        // Hugs its content like SwiftUI's own popup, so the `.frame` at the call site is the
        // whole of the sizing and the button never stretches a row.
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        // Re-pointed on every update for the same reason ClearableStepperView does it: the
        // binding captured at makeCoordinator time addresses whatever model the view showed
        // then, and a merged combo pack re-points the release card without rebuilding it.
        coordinator.selection = $selection
        coordinator.reassertsSelectionAfterWrite = reassertsSelectionAfterWrite

        let size = context.environment.controlSize
        let nsSize = NSControl.ControlSize(size)
        if button.controlSize != nsSize { button.controlSize = nsSize }
        // Keyed off the font, not the control size: a zero-frame NSPopUpButton already
        // reports `.small` on macOS 15, so a size-change guard alone never installs the
        // 11 pt font for a `.controlSize(.small)` site and the button (and its menu, which
        // draws in the cell's font) stays at 13 pt — and misaligned with the collapsed title.
        let fontSize = NSFont.systemFontSize(for: nsSize)
        if button.font?.pointSize != fontSize { button.font = NSFont.systemFont(ofSize: fontSize) }
        button.isEnabled = context.environment.isEnabled

        // Rebuilt only when a row's CONTENT changed; a selection change alone moves a check
        // mark. Rebuilding on every update would discard and re-create every NSMenuItem for
        // a value that already has one.
        let items = effectiveItems
        coordinator.rebuildMenu(on: button, items: items)
        coordinator.select(tag: selection, on: button)
    }


    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var reassertsSelectionAfterWrite = true
        /// The tag of each menu row, index-aligned with the menu's items; nil for a separator.
        private var tags: [Value?] = []
        /// What the current menu was built from, so an unchanged update is free.
        private var builtItems: [Item]?

        init(selection: Binding<Value>) { self.selection = selection }

        func rebuildMenu(on button: NSPopUpButton, items: [Item]) {
            guard builtItems != items, let menu = button.menu else { return }
            builtItems = items
            menu.removeAllItems()
            tags.removeAll(keepingCapacity: true)
            for item in items {
                switch item {
                case .option(let tag, let title, let isEnabled):
                    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    menuItem.isEnabled = isEnabled
                    menu.addItem(menuItem)
                    tags.append(tag)
                case .separator:
                    menu.addItem(.separator())
                    tags.append(nil)
                case .header(let title):
                    // Disabled so it cannot be chosen; the attributed title keeps the
                    // secondary color rather than the disabled gray, as SortFilterMenu's
                    // SwiftUI headers do.
                    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    menuItem.attributedTitle = NSAttributedString(string: title, attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: button.font ?? NSFont.menuFont(ofSize: 0),
                    ])
                    menuItem.isEnabled = false
                    menu.addItem(menuItem)
                    tags.append(nil)
                case .placeholder(let tag, let title):
                    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    menuItem.isHidden = true
                    menu.addItem(menuItem)
                    tags.append(tag)
                }
            }
        }

        func select(tag: Value, on button: NSPopUpButton) {
            guard let index = tags.firstIndex(where: { $0 == tag }) else { return }
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard tags.indices.contains(index), let tag = tags[index] else { return }
            if tag != selection.wrappedValue {
                selection.wrappedValue = tag
            }
            // Whatever the binding says now is what the button shows — the written value
            // for an ordinary field, the old one for a write that was declined.
            if reassertsSelectionAfterWrite {
                select(tag: selection.wrappedValue, on: sender)
            }
        }
    }
}

/// The drop-in replacement for a `Picker("", selection:) { … }.labelsHidden().frame(width:)`
/// on the sheet's form tabs: a `SheetPopUpButton` sized the way the SwiftUI picker was laid
/// out, so rows keep their pitch. `items` are in menu order.
struct SheetMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [SheetPopUpButton<Value>.Item]
    var width: CGFloat = Preferences.standardPickerWidth

    init(selection: Binding<Value>, items: [SheetPopUpButton<Value>.Item],
         width: CGFloat = Preferences.standardPickerWidth) {
        _selection = selection
        self.items = items
        self.width = width
    }

    var body: some View {
        SheetPopUpButton(selection: $selection, items: items)
            .frame(width: width, height: SheetPopUpButton<Value>.layoutHeight,
                   alignment: .leading)
    }
}

// MARK: - Segmented Control
//
// The sheet's segmented picker: an `NSSegmentedControl` driven directly, in place of SwiftUI's
// `Picker(.segmented)`. Used by the release card's variant switcher and Condition row (33.20),
// the Details tab's Queue Membership row (31.10), the frames popover's "Mark with" row
// (30.40), and the import Details popover's category header (28.00), which disables the
// segments with nothing to show through `Segment.isEnabled`.
//
// MARK: Why not the SwiftUI Picker
//
// The same reason as `SheetPopUpButton`, at a smaller scale. The `card-perf` probe table puts
// a two-segment SwiftUI segmented Picker at ~6 ms to mount and eight NSViews, against ~1 ms
// and one view for the `NSSegmentedControl` it wraps: SwiftUI's adaptor hosts a private
// `SwiftUISegmentedControl` inside a `PlatformViewHost` and builds a view per segment label
// on the way. The sheet carries at most four, so this is a few milliseconds per card mount —
// taken because it is free, and because it finishes the pattern: every stop in the sheet's
// Tab loop is now a control the sheet builds itself.
//
// MARK: What is kept identical
//
// Configured exactly as SwiftUI's adaptor configures its control, read off that control by
// the `segmented-equivalence` harness scenario (99.50): `.automatic` style, `.selectOne`
// tracking, `.fillEqually` distribution, regular control size, 13 pt system font, centered
// labels, no per-segment width, vertical hugging at `.defaultHigh`.
//
// Sizing is where the adaptor is not just "the intrinsic size", and where SwiftUI's default
// representable sizing would differ. Measured: the layout height is always the control's
// 22 pt (a 40 pt proposal still yields 22, with the 24 pt bezel overhanging by one point top
// and bottom); the width is the PROPOSED width clamped to a minimum — 88 / 174 / 201 pt for
// the two-, three- and four-segment controls the sheet has — and the ideal (under
// `.fixedSize()`) is AppKit's `.fillEqually` intrinsic width (89 / 185 / 251). The minimum is
// the `.fit` distribution's intrinsic width plus the control's horizontal alignment-rect
// insets (84 + 4, and so on); the control is switched to `.fit` for one measurement whenever
// its segments change, and back. `sizeThatFits` reproduces the rule,
// and the harness asserts the two controls' alignment rects agree for every proposal shape
// the sheet uses.
/// What a segmented control's measured size depends on — its labels, size and font, and the
/// appearance it resolves CoreUI metrics in — so equal keys measure equally.
private struct SegmentedMetricsKey: Hashable {
    let titles: [String]
    let controlSize: UInt
    let fontSize: CGFloat
    let appearance: NSAppearance.Name
}

/// Measured (minimum, ideal) width and height per segment set, shared by every
/// `SheetSegmentedControl` in the process.
///
/// File scope rather than a static on this generic type, so every specialization shares one cache.
/// Measuring is a CoreUI metrics query per segment, about a millisecond for the Queue Membership
/// row's four. Every FilmSheet builds a fresh control showing the same four labels, so the cache
/// spares each open from measuring them again. The `filmsheet-perf` harness scenario's open loop
/// sampled `intrinsicContentSize` under `sizeThatFits` as the largest single item in the Details
/// tab's first layout. The cache is bounded by the handful of distinct segment sets the app has.
@MainActor private var segmentedMetricsCache: [SegmentedMetricsKey: (min: CGFloat, ideal: CGFloat, height: CGFloat)] = [:]

struct SheetSegmentedControl<Value: Hashable>: NSViewRepresentable {
    /// One segment, in order. A disabled segment is drawn dimmed and ignores clicks
    /// (`NSSegmentedControl.setEnabled(_:forSegment:)`); it can still be selected through
    /// the binding.
    struct Segment: Equatable {
        let tag: Value
        let title: String
        var isEnabled: Bool = true
        init(tag: Value, title: String, isEnabled: Bool = true) {
            self.tag = tag; self.title = title; self.isEnabled = isEnabled
        }
        init(_ tag: Value, _ title: String, isEnabled: Bool = true) {
            self.init(tag: tag, title: title, isEnabled: isEnabled)
        }
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// Keeps the control out of the key view loop, so it never takes focus or draws a
    /// focus ring. For a header that is clicked, never tabbed to (the import Details
    /// popover's); the sheet's own controls leave it off, as they are stops in its Tab loop.
    var refusesFirstResponder = false

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: segments.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator,
                                         action: #selector(Coordinator.selectionChanged(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultHigh, for: .vertical)
        control.refusesFirstResponder = refusesFirstResponder
        context.coordinator.remember(segments: segments, on: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let coordinator = context.coordinator
        // Re-pointed on every update, as SheetPopUpButton's coordinator is: a merged combo
        // pack re-points the card at another release without rebuilding it.
        coordinator.selection = $selection

        let size = context.environment.controlSize
        let nsSize = NSControl.ControlSize(size)
        if control.controlSize != nsSize {
            control.controlSize = nsSize
            coordinator.invalidateWidths()
        }
        // Keyed off the font, not the control size, for the reason SheetPopUpButton gives: a
        // zero-frame control already reports `.small` on macOS 15, so the size guard above
        // alone never installed the 11 pt font for a `.controlSize(.small)` site.
        let fontSize = NSFont.systemFontSize(for: nsSize)
        if control.font?.pointSize != fontSize {
            control.font = NSFont.systemFont(ofSize: fontSize)
            coordinator.invalidateWidths()
        }
        control.isEnabled = context.environment.isEnabled

        coordinator.rebuildSegments(on: control, segments: segments)
        coordinator.select(tag: selection, on: control)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl,
                      context: Context) -> CGSize? {
        // The height is cached with the widths. `intrinsicContentSize` is a CoreUI metrics query
        // per segment, and SwiftUI asks several times per layout pass.
        let (minWidth, idealWidth, height) = context.coordinator.metrics(of: control)
        if let width = proposal.width, width.isFinite {
            return CGSize(width: max(width, minWidth), height: height)
        }
        return CGSize(width: idealWidth, height: height)
    }


    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        /// The tag of each segment, index-aligned with the control's segments.
        private var tags: [Value] = []
        /// What the current segments were built from, so an unchanged update is free.
        private var builtSegments: [Segment]?
        /// (minimum, ideal) width and height, measured once per segment set; see the type
        /// comment and `segmentedMetricsCache`.
        private var cachedWidths: (min: CGFloat, ideal: CGFloat, height: CGFloat)?

        init(selection: Binding<Value>) { self.selection = selection }

        func remember(segments: [Segment], on control: NSSegmentedControl) {
            builtSegments = segments
            tags = segments.map(\.tag)
            for (index, segment) in segments.enumerated() where !segment.isEnabled {
                control.setEnabled(false, forSegment: index)
            }
        }

        func invalidateWidths() { cachedWidths = nil }

        func rebuildSegments(on control: NSSegmentedControl, segments: [Segment]) {
            guard builtSegments != segments else { return }
            builtSegments = segments
            tags = segments.map(\.tag)
            control.segmentCount = segments.count
            for (index, segment) in segments.enumerated() {
                control.setLabel(segment.title, forSegment: index)
                control.setWidth(0, forSegment: index)
                control.setEnabled(segment.isEnabled, forSegment: index)
            }
            cachedWidths = nil
            control.invalidateIntrinsicContentSize()
        }

        func metrics(of control: NSSegmentedControl) -> (min: CGFloat, ideal: CGFloat, height: CGFloat) {
            if let cachedWidths { return cachedWidths }
            let key = SegmentedMetricsKey(titles: builtSegments?.map(\.title) ?? [],
                                          controlSize: control.controlSize.rawValue,
                                          fontSize: control.font?.pointSize ?? 0,
                                          appearance: control.effectiveAppearance.name)
            if let shared = segmentedMetricsCache[key] {
                cachedWidths = shared
                return shared
            }
            control.segmentDistribution = .fit
            control.invalidateIntrinsicContentSize()
            let insets = control.alignmentRectInsets
            let minWidth = control.intrinsicContentSize.width + insets.left + insets.right
            control.segmentDistribution = .fillEqually
            control.invalidateIntrinsicContentSize()
            let fitted = control.intrinsicContentSize
            let metrics = (min: minWidth, ideal: fitted.width, height: fitted.height)
            cachedWidths = metrics
            segmentedMetricsCache[key] = metrics
            return metrics
        }

        func select(tag: Value, on control: NSSegmentedControl) {
            guard let index = tags.firstIndex(of: tag) else {
                if control.selectedSegment != -1 { control.selectedSegment = -1 }
                return
            }
            if control.selectedSegment != index { control.selectedSegment = index }
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard tags.indices.contains(index) else { return }
            let tag = tags[index]
            if tag != selection.wrappedValue {
                selection.wrappedValue = tag
            }
            // Unlike SheetPopUpButton, the binding is NOT re-read here. The release card's
            // variant switcher writes through a binding whose getter answers from the card's
            // own state, which the swap updates a turn later. Re-selecting from it on the click
            // would put the old segment back for that turn, so the clicked segment would flash
            // unselected before the swap lands. AppKit has already moved the selection, and the
            // next updateNSView reconciles it with the binding, which is where a declined write
            // is put back.
        }
    }
}
