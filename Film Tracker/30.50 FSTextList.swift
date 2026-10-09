// MARK: - FSTextList.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The reorderable long-text list used by the FilmSheet Notes tab's Warnings and
// Notes fields.
//
// **Why this is a third list component rather than a mode on either existing one**
//
// This sits between the sheet's two other reorderable lists:
//
//   • `ReorderableStringList` (30_30_FSStringList.swift) edits in place through a
//     one-line `NSTextField` — right for a cast name or tag, wrong for a warning
//     or note that routinely runs to a paragraph and needs to be seen in full
//     while editing.
//   • `ReorderableFramesList` (30_40_FSFramesList.swift) edits through a popover
//     (the right affordance for a large text block), but its rows are four-field
//     comma-packed records with a three-toggle/three-picker popover, and it
//     numbers rows because a frame list is cited by position.
//
// Folding this into either as a flag would mean that type carrying two disjoint
// row models and editors, gated throughout — the exact arrangement the note atop
// `FSFramesList.swift` explains those two files were split apart to avoid. So the
// shape is borrowed and the specifics aren't: this is `ReorderableFramesList`'s
// structure with the record model, metadata block, and index column removed, and
// a seven-line `FixedHeightScrollingTextView` in place of the popover's field.
//
// Everything the three genuinely share is already factored out and used unchanged
// here: `ListCircleButton`/`ListCircleButtonStyle`, `ListImportPopover`,
// `ListRowMetrics`, `ScrollActivityObserver`, and `FieldEdgeTreatment`
// (30_10_FSTextHelpers.swift). Nothing about the chrome is restated, so these
// tables stay visually indistinguishable from the other two on the same sheet.

import SwiftUI
import Combine

// MARK: - Reorderable Text List Component

/// A drag-to-reorder list whose entries are edited through a popover holding a
/// seven-line scrolling text view.
///
/// **Display versus edit**
///
/// A row shows one line of its entry, truncated with a trailing ellipsis at the
/// table's inner width — the same resting appearance `ReorderableStringList`'s
/// rows have, so the two read alike in a table the user is scanning. The full
/// value, line breaks included, is only ever shown in the editor.
///
/// **No index column**
///
/// Unlike the frames tables, these entries are not an ordered sequence anyone
/// cites by position: a warning is a warning. The row is therefore text and one
/// control, and the text takes the width the index column would have occupied.
///
/// **Editing is drafted**
///
/// The popover works on row-local `@State` and writes the array exactly once, on
/// Update. Canceling — by the button, by Escape, or by scrolling the sheet — is
/// a no-op on the model by construction. That is the same guarantee the string
/// list gets from its draft buffer, reached here without any of the
/// first-responder machinery, because a popover's dismissal is unambiguous in a
/// way that a field losing focus is not.
struct ReorderableTextList: View {

    @Binding var items: [String]

    /// Singular noun used in popover titles, tooltips, and the bulk-import
    /// sheet — "Warning" produces "Add Warning" and "Import Warnings".
    var itemLabel: String = "Item"

    /// Upper bound on row count.
    ///
    /// 30, matching `ReorderableStringList` rather than the frames list's 99.
    /// These are the same two fields that list held before this component
    /// existed, so the limit they were already under is preserved; the frames
    /// list's higher cap is tied to its two-digit index column, which this table
    /// does not draw.
    private static let maxItems = 30

    /// Tells any row holding an open popover to close it.
    ///
    /// Driven by the two events that invalidate a popover's anchor — a scroll of
    /// the enclosing sheet, and a drag-to-reorder. The second matches the
    /// `endEditing()` the string list performs in its own `.onMove`: no editor
    /// may outlive the arrangement of rows it was opened against.
    ///
    /// A publisher rather than a stored scroll offset, for the reason set out at
    /// the matching declaration in `ReorderableFramesList`: a stored value is an
    /// input to every row, so one scroll tick would invalidate all thirty of
    /// them to let at most one close a popover. `.onReceive` is not an input, so
    /// only the row that actually reacts re-renders.
    @State private var dismissRowPopovers = PassthroughSubject<Void, Never>()

    // MARK: Import Popover State
    //
    // The presentation flag, so a scroll can close the popover, and the replace
    // mode, which `commitImport` reads. Mirrors both other list components.

    @State private var showImportPopover = false
    @State private var importReplaces = false

    // MARK: Add Popover State
    //
    // Presentation only. The drafted text lives inside `TextEntryPopover`, in
    // that view's own `@State`, and arrives here as an argument to `onConfirm`.
    //
    // Deliberately not a `@Binding` down into the popover, which is the
    // arrangement `ListImportPopover` documents as unreliable: a popover's
    // content is hosted in its own window with its own update graph, so a write
    // that invalidates the *presenter* is no guarantee that the presented
    // content is re-evaluated in step. Anything computed from the draft — here,
    // the confirm button's enablement — has to be computed where the draft is
    // written, or it goes stale. Keeping the draft inside the popover is what
    // makes that true by construction.

    @State private var showAddPopover = false

    /// Bumped each time an entry is committed, which is what asks the add row to
    /// scroll itself back into the viewport. See `ListAddRowRevealer`.
    @State private var addRevealToken = 0

    /// Rows drawn: every entry, plus the trailing add row.
    ///
    /// Unconditional, as on both other tables: an empty list is one ordinary row
    /// tall rather than a shorter special case, so the paired label needs one
    /// alignment constant instead of two.
    private var displayedRowCount: Int { items.count + 1 }

    private var listHeight: CGFloat {
        ListRowMetrics.listHeight(rowCount: displayedRowCount)
    }

    /// Whether the table has room for another entry. At the cap the add row stays
    /// visible but inert: its "+" is disabled and grays out, which states the
    /// limit rather than silently removing the control.
    private var canAdd: Bool { items.count < Self.maxItems }

    /// The pending "this already exists" confirmation, or `nil` when there is
    /// none. Held on the table rather than on the row or popover that raised it:
    /// both commit paths dismiss their popover on the same interaction, so an
    /// alert anchored there would be torn down before it could be answered.
    @State private var duplicatePrompt: ListDuplicatePrompt?

    var body: some View {
        List {
            // Index identity, deliberately, and for the same reason the string
            // list gives: `id: \.self` on the strings would collapse two
            // identical entries onto one identity, which breaks both reordering
            // and row-level state. Two identical notes are entirely plausible.
            ForEach(items.indices, id: \.self) { index in
                TextListRow(
                    // A value, not `$items[index]`. The row never writes its entry
                    // itself — an Update is handed back through `onUpdate` — so a
                    // positional binding bought nothing but a subscript that traps if
                    // it is read after the array has shrunk past it.
                    item: items[index],
                    itemLabel: itemLabel,
                    dismissRowPopovers: dismissRowPopovers,
                    // The array lives here, so the duplicate comparison, the
                    // position verification, and the write do too — the same
                    // division `ReorderableFramesList` makes with its `onUpdate`.
                    // Handing down a closure rather than the array is deliberate:
                    // `items` as a row input would invalidate every row on any edit.
                    onUpdate: { expected, text in
                        // Verified before the duplicate check as well as at the
                        // write: a row that has moved since its popover opened
                        // would be compared with a stale index excluded, and its
                        // prompt's "Add Anyway" would then be silently dropped.
                        guard items.indices.contains(index), items[index] == expected else { return }
                        confirmingDuplicate(text, excluding: index, prompt: ListDuplicatePrompt {
                            applyUpdate(at: index, expecting: expected, to: text)
                        })
                    },
                    // The row hands back the value it was showing at the moment
                    // Delete was clicked, not just its position. The delete is
                    // deferred past the popover's close animation, and the sheet
                    // stays interactive across that interval, so an index alone
                    // is not enough to identify what the user asked to remove.
                    // See `deleteEntry(at:expecting:)`.
                    onDelete: { expected in
                        deleteEntry(at: index, expecting: expected)
                    }
                )
                .listRowInsets(ListRowMetrics.rowInsets)
            }
            .onMove { source, destination in
                // Editors must close before the move, on the same terms as the
                // string list's `endEditing()`: a popover is anchored to a row
                // at a position, and the move redefines what occupies it. A
                // surviving editor would commit its draft into whichever entry
                // had arrived there — and this popover's draft is seeded once,
                // on appear, so it would still be holding the old row's text.
                //
                // In practice a transient `NSPopover` is dismissed by the drag's
                // own mouseDown before this runs, so this is the belt to that
                // brace — and the `expecting` checks on both the update and the
                // delete are what make a late commit safe rather than merely
                // unlikely.
                closeAllEditors()
                items.move(fromOffsets: source, toOffset: destination)
            }

            // The add row, outside the `ForEach` and therefore outside `.onMove`
            // — it is not an entry, so it must be neither draggable nor a valid
            // drop destination. `.onMove` bounds both the source and the
            // destination to its own `ForEach`'s range, so keeping this a
            // sibling gives that for free.
            //
            // Inlined rather than extracted, as on the frames list: it is a
            // label and two buttons, and it anchors the add popover, whose state
            // is `@State` on this view.
            addRow
                // Brings this row back into the viewport after a commit pushes
                // it down. A background contributes no layout and consumes no
                // events, so the row is unaffected.
                .background(ListAddRowRevealer(token: addRevealToken))
                .listRowInsets(ListRowMetrics.rowInsets)
        }
        // List style, sizing, clip, border, and shadow — one modifier, shared with the
        // string and frames lists so all three tables are drawn identically and
        // in the same order. The order is load-bearing; the full account is on
        // `listContainerChrome(height:)` (30_20_FSControlHelpers.swift).
        .listContainerChrome(height: listHeight)
        // Scroll detection in AppKit rather than SwiftUI. An `NSPopover` is
        // pinned to the screen rectangle its anchor occupied when presented, so
        // scrolling the sheet would leave it floating over unrelated content.
        // `ScrollActivityObserver` watches the enclosing clip view's bounds —
        // the notification AppKit already posts for its own use — rather than a
        // `GeometryReader`, which would put SwiftUI layout on the live-scroll
        // path that `AppKitScrollView`'s live-scroll suppression exists to keep
        // it off.
        //
        // The same close a reorder performs. Shared rather than restated, so a
        // popover added to this table later cannot be handled on one path and
        // forgotten on the other.
        .background(
            ScrollActivityObserver {
                closeAllEditors()
            }
        )
        // Raised by `commitAdd` and by a row's Update when the finished value
        // already exists verbatim.
        .listDuplicateAlert($duplicatePrompt)
    }

    // MARK: - Add Row

    /// The table's trailing row: a permanent invitation to add the next entry.
    ///
    /// Its "+" opens the add popover rather than an inline field, which is the
    /// whole point of this component — the editor has to be large enough to hold
    /// a paragraph, and a row is not.
    private var addRow: some View {
        HStack(spacing: 8) {
            // At the cap the invitation is replaced by the reason there is
            // none: the "+" beside it can only gray out and darken, which says
            // "not now" without saying why. Scaled rather than truncated,
            // because a sentence cut off mid-word explains nothing.
            Text(canAdd ? "Add new…" : ListAddRowCopy.atCapacity)
                .font(.system(size: 12))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.tertiary)
                // Matches the inset applied to a real row's text, so the
                // placeholder's first glyph sits in the same column as every
                // entry above it.
                .padding(.leading, ListRowMetrics.fieldTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Bulk import, in the slot immediately left of the "+" — the same
            // slot it occupies on both other tables, and the same shared control
            // they present it with. The account of why it is permanently gray
            // and deliberately NOT gated on `canAdd` lives on
            // `ListBulkImportButton` (30_20_FSControlHelpers.swift).
            ListBulkImportButton(
                isPresented: $showImportPopover,
                help: "Add multiple \(itemLabel.lowercased())s from a comma- or line-separated list",
                onOpen: {
                    // Replace mode is the only mode that can do anything at the
                    // cap, so the popover opens in it and locks it; see
                    // `ListImportPopover.isAtCapacity`.
                    importReplaces = !canAdd
                },
                popoverContent: { importPopoverContent }
            )

            ListCircleButton(
                systemImage: "plus",
                fill: Preferences.green,
                diameter: ListRowMetrics.circleDiameter,
                // "plus" is optically heavier than "info" at the same nominal
                // size, so it is set fractionally smaller. Matches both other
                // add rows.
                glyphSize: ListRowMetrics.plusGlyphSize,
                isActive: showAddPopover,
                // Disabled at the entry cap; the factory substitutes its own gray
                // fill in that state, which is why no fill is chosen for it here.
                isEnabled: canAdd,
                help: "Add \(itemLabel.lowercased())",
                glyphOffset: ListCircleButtonStyle.plusGlyphOffset,
                action: { showAddPopover = true }
            )
            .popover(isPresented: $showAddPopover, arrowEdge: .trailing) {
                addPopoverContent
            }
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
    }

    // MARK: - Add Popover Content

    private var addPopoverContent: some View {
        TextEntryPopover(
            title: "Add \(itemLabel)",
            initialText: "",
            confirmTitle: "Add",
            onConfirm: { text in
                // Dismiss BEFORE committing. The commit may raise the duplicate
                // confirmation, and an alert presented while this popover is
                // still up would be competing with it for the window's
                // presentation. The write is performed by the table, not by the
                // popover, so it is unaffected by the dismissal.
                //
                // Held until the close animation has finished, additionally,
                // because the appended row grows the table under a popover that
                // is still tracking its anchor — see `ListPopoverDismissal`.
                showAddPopover = false
                ListPopoverDismissal.afterClose { commitAdd(text) }
            },
            onCancel: { showAddPopover = false },
            onDelete: nil
        )
    }

    // MARK: - Bulk Import

    /// Content for the bulk-entry popover, presented from the add row's control.
    ///
    /// The control lives in the row; the state and the commit stay here, because
    /// the array is here and the cap is here.
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
            placeholder: "Entry 1, Entry 2, Entry 3",
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

    // MARK: - Mutation Helpers

    /// Appends the drafted entry.
    ///
    /// Trimmed on `.whitespacesAndNewlines` rather than `.whitespaces`, because
    /// this editor accepts line breaks and a draft that is nothing but a
    /// trailing return would otherwise be stored as a blank row.
    ///
    /// The cap is re-checked rather than trusted from the button's enablement:
    /// it is a limit on the model, not merely a UI rule.
    private func commitAdd(_ draft: String) {
        guard items.count < Self.maxItems else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // An exact duplicate is confirmed rather than refused — see
        // `ListDuplicateCheck`. The append is deferred whole, so the confirmed
        // path and the immediate one are the same code.
        confirmingDuplicate(text, prompt: ListDuplicatePrompt { appendCommitted(text) })
    }

    /// The append itself, shared by the immediate and confirmed paths.
    ///
    /// The cap is checked again here rather than only in `commitAdd`: on the
    /// confirmed path an alert stood between the two, so the guard is what keeps
    /// this method safe to call from either.
    private func appendCommitted(_ text: String) {
        guard items.count < Self.maxItems else { return }
        items.append(text)
        // Only on a write that actually grew the table, so a rejected draft
        // leaves the viewport alone.
        addRevealToken &+= 1
    }

    /// Runs `write` immediately, or parks it behind a confirmation when the
    /// finished value already exists verbatim.
    ///
    /// Bulk import deliberately does NOT route through here: a pasted list is
    /// reviewed as a whole before it is imported, and interrupting it once per
    /// repeated entry would make the control unusable.
    /// The pending write arrives already wrapped in a `ListDuplicatePrompt`
    /// rather than as a bare closure: a closure held as a property of a struct is
    /// escaping by construction, which is what lets it be parked in `@State` until
    /// the alert is answered, and lets all three tables share the one signature.
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

    /// The cap-and-replace rule is `ListImportCommit`'s, shared with the string
    /// and frames lists. Resolving before writing keeps this a single array
    /// write — one observation invalidation, one change-tracking pass — and
    /// leaves a rejected batch writing nothing at all.
    private func commitImport(_ parsed: [String]) {
        guard let updated = ListImportCommit.resolved(parsed,
                                                      into: items,
                                                      replacing: importReplaces,
                                                      cap: Self.maxItems)
        else { return }
        // Close any open editor, matching the `endEditing()`
        // `ReorderableStringList.commitImport` performs at this same point, and
        // ordered after the resolve for the reason stated there: a rejected batch
        // must not close a field the user is still working in.
        //
        // The gap this closes is real but narrow. The commit is dispatched
        // through `ListPopoverDismissal.afterClose`, and the sheet stays fully
        // interactive across that interval — so a row's edit popover can be
        // opened between the Import click and this running. A Replace-mode import
        // then redefines or removes the row that popover is anchored to, leaving
        // an editor floating over a row that no longer holds what it was opened
        // on. The `expecting` check in `applyUpdate` already makes a late write
        // from such an editor a no-op rather than data loss; this closes the
        // visual half the check cannot reach. The editor is drafted, so closing
        // it discards nothing that was committed.
        closeAllEditors()
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

    /// Closes every editor this table can have open — each row's edit popover,
    /// the add popover, and the bulk-import popover.
    ///
    /// One method rather than the same three lines at each caller, because the
    /// callers are exactly the two events that invalidate a popover's anchor: a
    /// scroll and a reorder. Both flags are guarded rather than assigned
    /// unconditionally, so a scroll tick with nothing open reads two `Bool`s and
    /// writes nothing — no SwiftUI invalidation reaches the view tree.
    ///
    /// The row popovers are reached through the subject rather than a flag,
    /// because each row owns its own presentation state; see
    /// `dismissRowPopovers` for why that is a publisher and not a value.
    private func closeAllEditors() {
        dismissRowPopovers.send()
        if showAddPopover { showAddPopover = false }
        if showImportPopover { showImportPopover = false }
    }

    /// The single-slot write behind a row's Update, shared by the immediate and
    /// confirmed paths.
    ///
    /// Position-verified, on the terms `ReorderableStringList.applyEdit` states: the
    /// write arrives after the popover's close animation and possibly after a modal
    /// alert, and an index addresses a POSITION. If the slot no longer holds the value
    /// the edit opened on, the edit is stale and is dropped rather than written over
    /// whatever has arrived there.
    private func applyUpdate(at index: Int, expecting original: String, to text: String) {
        guard items.indices.contains(index), items[index] == original else { return }
        items[index] = text
    }

    /// Removes the entry the row was showing when Delete was clicked.
    ///
    /// **Why the value and not just the index**
    ///
    /// The delete is dispatched through `ListPopoverDismissal.afterClose`, which
    /// holds it for the length of the popover's close animation. The sheet is
    /// fully interactive across that interval, so the index captured when the
    /// row was built is not by itself a reliable identifier of what the user
    /// asked to remove: a reorder landing inside the window would leave it
    /// pointing at a different entry, and `indices.contains` would happily let
    /// that through — it prevents a trap, not a wrong deletion.
    ///
    /// Verifying the value first is the same rule `ReorderableStringList` states
    /// as `expecting` on its own drafted commits. The fallback search covers the
    /// case where the entry is still present but has moved, so a reorder inside
    /// the window delays the deletion rather than misdirecting it; an entry that
    /// is gone altogether leaves nothing to do.
    /// A table holding two identical entries makes the fallback ambiguous, and
    /// harmlessly so: removing either occurrence yields the same array, because
    /// the two are the same value.
    private func deleteEntry(at index: Int, expecting value: String) {
        if items.indices.contains(index), items[index] == value {
            items.remove(at: index)
            return
        }
        guard let moved = items.firstIndex(of: value) else { return }
        items.remove(at: moved)
    }
}

// MARK: - Text Entry Popover

/// The shared editor body for both of this component's entry popovers.
///
/// Add and edit differ in three things — the title, the confirm button's label,
/// and whether a Delete button is offered — and in nothing else. Expressed as one
/// type with those three as parameters, so the seven-line text view, the gutter's
/// spacing, the button order, and the keyboard shortcuts are defined once rather
/// than in two copies free to drift. This is the same consolidation
/// `FramesMarkRow` and `FramesFadeRow` perform for the frames popovers.
///
/// `fileprivate` because both call sites are in this file.
fileprivate struct TextEntryPopover: View {

    let title: String

    /// The value the editor opens on. Also the baseline the confirm button's
    /// enablement is measured against — the empty string for an add, the current
    /// entry for an edit — so "has anything changed?" is one rule rather than two.
    let initialText: String

    /// "Add" or "Update".
    let confirmTitle: String

    /// Receives the drafted text. Trimming and the empty-draft rule belong to the
    /// list, which owns the array.
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    /// Supplied only by the edit popover. `nil` suppresses the button entirely
    /// rather than disabling it: there is nothing to delete before an entry
    /// exists, and a permanently dead destructive control invites a click that
    /// can never do anything.
    let onDelete: (() -> Void)?

    /// The draft, and the single source the confirm button's enablement is
    /// computed from.
    ///
    /// Local `@State` rather than a `Binding` back to the presenter, for the
    /// reason `ListImportPopover` sets out at its own `draft`: a popover's
    /// content is hosted in its own window with its own update graph, so writing
    /// the presenter's state is not a guarantee that this view is re-evaluated
    /// in step — the symptom there was a readout and a button that would change
    /// on the way up but not on the way down. Writing local state invalidates
    /// *this* view by definition, so every keystroke recomputes the enablement
    /// in the same pass. The value reaches the list through `onConfirm`, which
    /// is the only moment anything outside this view needs it.
    @State private var draft: String

    /// Return commits this popover's edit; Option-Return takes a line break.
    ///
    /// Stated here rather than inherited. This popover is presented from inside the
    /// FilmSheet, and SwiftUI popovers inherit the presenter's environment — so without
    /// its own value, Return in this editor would run the *sheet's* action and save and
    /// dismiss the whole sheet out from under an entry the user had not yet committed.
    /// The rule for any subtree that presents a confirming control of its own over one
    /// that already has one: state your own action, or explicitly state `nil`.
    @State private var submitAction = FieldSubmitAction()

    init(title: String,
         initialText: String,
         confirmTitle: String,
         onConfirm: @escaping (String) -> Void,
         onCancel: @escaping () -> Void,
         onDelete: (() -> Void)?) {
        self.title = title
        self.initialText = initialText
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onDelete = onDelete
        self._draft = State(initialValue: initialText)
    }

    /// Visible lines in the entry area before it begins scrolling.
    private static let visibleLines: Int = 7

    /// Wide enough that a sentence of a warning or a note is a line rather than
    /// three. Matches `ListImportPopover`, which sits over the same tables — and
    /// with it, `ViewingDatesTable`'s add and edit popovers, which are the width
    /// every FilmSheet-presented popover is now stated in. The entry area fills
    /// whatever width it is given, so the 30pt this used to carry beyond that
    /// reference bought nothing but an inconsistent edge.
    private static let width: CGFloat = 290
    private static let padding: CGFloat = 16

    /// Non-empty once trimmed, and different from what the editor opened on.
    ///
    /// **Measured on the trimmed value, deliberately**
    ///
    /// The change test previously compared the RAW draft against `initialText`,
    /// while the commit trims and then compares. The two disagreed on exactly
    /// one input: an edit that changed only leading or trailing whitespace. That
    /// enabled Update, and the commit then found nothing to write — so the
    /// popover closed, the entry was unchanged, and nothing said why. Both sides
    /// now measure the finished value.
    ///
    /// The cheap `allSatisfy` emptiness check is kept as the leading term, so a
    /// draft that is plainly blank short-circuits without allocating; only a
    /// draft that could actually be committed pays for the trim.
    /// `isWhitespace` covers line breaks, so a draft of nothing but returns is
    /// correctly treated as empty.
    private var isConfirmEnabled: Bool {
        guard !draft.isEmpty, !draft.allSatisfy(\.isWhitespace) else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) != initialText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // The reason this component exists. A seven-line scrolling text view
            // shows a paragraph-length entry whole, and accepts line breaks
            // within it, neither of which the one-line field it replaces could do.
            //
            // Return confirms and Option-Return enters a line break, via the
            // `FieldSubmitAction` installed below — so the keyboard reaches the
            // Update button here the same way it does on a one-line field, while
            // multi-line entry stays available. When the confirm button is
            // disabled (an empty or unchanged draft) Return is still consumed and
            // simply does nothing, matching the button beside it.
            //
            // No placeholder: the title already states what the editor is for,
            // and sample text inside a free-form prose field reads as content.
            FixedHeightScrollingTextView(text: $draft, placeholder: "")
                .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: Self.visibleLines))

            Divider()

            // Cancel leads, per the platform convention for a dismissive action;
            // the confirming action holds the trailing edge.
            HStack(spacing: 8) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                if let onDelete {
                    // Shared with the frames list's and `ViewingDatesTable`'s
                    // Delete buttons; the full account of the treatment is on
                    // `PopoverDeleteButton` (30_20_FSControlHelpers.swift).
                    PopoverDeleteButton(action: onDelete, bindsOptionDelete: true)
                }

                Spacer()

                Button(confirmTitle) { onConfirm(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfirmEnabled)
            }
        }
        .frame(width: Self.width)
        .padding(Self.padding)
        .fieldSubmitAction(submitAction)
        // Re-seeds the draft each time the popover appears.
        //
        // The `State(initialValue:)` in `init` covers the first presentation;
        // this covers every subsequent one, because SwiftUI may reuse the node
        // it built for the previous presentation rather than constructing a
        // fresh view — in which case the initializer's value is ignored and a
        // stale draft would survive into the next edit. Guarded so a re-appear
        // that already agrees writes nothing.
        .onAppear {
            if draft != initialText { draft = initialText }
            // Installed in `onAppear`, not in `body` — see `FieldSubmitAction.setHandler`.
            // The closure captures this view value, and `@State` reads route through
            // SwiftUI's storage rather than a captured copy, so `draft` and
            // `isConfirmEnabled` are evaluated at the moment Return is pressed. That is
            // what keeps this handler in exact agreement with the Update button beside it,
            // which reads the same two properties.
            submitAction.setHandler {
                guard isConfirmEnabled else { return false }
                onConfirm(draft)
                return true
            }
        }
        .onDisappear {
            // A dismissed popover's handler must not survive into the next presentation:
            // SwiftUI may reuse this node, and a stale closure could confirm against a
            // previous row's callback.
            submitAction.setHandler(nil)
        }
    }
}

// MARK: - TextListRow

/// A single row of `ReorderableTextList`.
///
/// Extracted as its own struct so SwiftUI can assign each row a stable node and
/// skip re-evaluating rows whose inputs have not changed — inlined into the
/// parent's `ForEach`, every row's content would re-run on any parent state
/// change, including each keystroke in an unrelated row's open popover.
///
/// Each row owns its own popover state, which is also what stops the
/// shared-state race the frames list documents: a single presentation flag on
/// the parent leaves a reopened popover unable to present, because the flag is
/// still being torn down from the previous row.
private struct TextListRow: View {

    /// The stored entry this row shows. A value: the row reads it and hands edits back
    /// through `onUpdate`, and never writes it.
    let item: String
    let itemLabel: String

    /// Fires when the enclosing content scrolls. Received rather than observed as
    /// a value, so a scroll re-renders only the row that has a popover open.
    let dismissRowPopovers: PassthroughSubject<Void, Never>

    /// Hands an Update back to the table: the entry as it stood when the edit opened,
    /// then the finished text. The table owns the array, so it owns the duplicate
    /// comparison, the position check, and the write, and either performs it at once
    /// or parks it behind its confirmation alert.
    let onUpdate: (_ expected: String, _ text: String) -> Void

    /// Removes this row. Carries the value the row was showing at the moment
    /// Delete was clicked, so the table can confirm it is removing that entry
    /// rather than whatever has since arrived at this position — the deletion is
    /// deferred past the popover's close animation. See
    /// `ReorderableTextList.deleteEntry(at:expecting:)`.
    let onDelete: (String) -> Void

    /// Presentation state, owned per row. The draft itself lives inside
    /// `TextEntryPopover` — see the note on its `draft`. The array is therefore
    /// written exactly once, on Update, so a canceled edit is a no-op on the
    /// model by construction rather than by remembering to restore the previous
    /// value on each of the routes out.
    @State private var showPopover = false

    /// One-line form of the entry, computed once per construction.
    ///
    /// Line breaks are folded to spaces rather than left in place. `Text` with
    /// `lineLimit(1)` renders only up to the first hard break, so an entry whose
    /// first line is short would draw as a short line with no ellipsis — reading
    /// as a complete value when it is not. Folding first means the row always
    /// shows as much as fits and truncates with the trailing ellipsis whenever
    /// there is more, which is the resting appearance the string-list rows this
    /// replaces already had.
    ///
    /// A plain value rather than a `@State` cache. The table constructs a row only
    /// when its own body re-runs — the only moment `item` can have changed — so
    /// this costs what the cache did (its initial-value expression ran on every
    /// construction anyway), and it cannot lag `item`: the cache needed an
    /// `onChange` to catch up, which ran a second body pass after every reorder,
    /// import, or edit. The row's own re-renders (its popover opening and
    /// closing) do not reconstruct it, so they do not recompute this either.
    private let displayText: String

    init(item: String,
         itemLabel: String,
         dismissRowPopovers: PassthroughSubject<Void, Never>,
         onUpdate: @escaping (_ expected: String, _ text: String) -> Void,
         onDelete: @escaping (String) -> Void) {
        self.item = item
        self.itemLabel = itemLabel
        self.dismissRowPopovers = dismissRowPopovers
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.displayText = Self.singleLine(item)
    }

    /// Collapses every run of line breaks and whitespace into single spaces.
    ///
    /// `split(whereSeparator:)` on `isNewline` then joining with a space would
    /// leave internal runs of spaces intact and is one allocation per fragment;
    /// this walks the string once.
    private static func singleLine(_ raw: String) -> String {
        guard raw.contains(where: { $0.isNewline || $0 == "\t" }) else { return raw }
        var out = ""
        out.reserveCapacity(raw.count)
        var lastWasSpace = false
        for character in raw {
            if character.isNewline || character == "\t" {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = (character == " ")
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(displayText)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                // Matches the inset the add row's placeholder carries, and the
                // one `.squareBorder` applies to its own text on the string
                // list's rows, so all three tables' entries start in the same
                // column.
                .padding(.leading, ListRowMetrics.fieldTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Edit. Built from the shared factory rather than drawn inline, so it
            // is the same control as the frames list's per-row "info" and the
            // string list's pencil: same diameter, same glyph weight, same
            // shadow, same press response. `info` rather than `info.circle`
            // because the factory already supplies the circle.
            //
            // `isActive` holds the accent fill for as long as the popover is
            // open. `showPopover` is this row's own state, so no other row's
            // button lights up.
            ListCircleButton(
                systemImage: "info",
                fill: Color.gray.opacity(0.5),
                diameter: ListRowMetrics.circleDiameter,
                glyphSize: ListRowMetrics.circleGlyphSize,
                isActive: showPopover,
                help: showPopover ? "Finish editing" : "Edit this entry",
                // `info` is the one glyph in the family that is not symmetric in
                // its own box; the correction lives with the family's other
                // per-symbol corrections rather than as a literal here.
                glyphOffset: ListCircleButtonStyle.infoGlyphOffset,
                action: { showPopover.toggle() }
            )
            .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                TextEntryPopover(
                    title: "Edit \(itemLabel)",
                    // The editor opens on the stored value, not on the folded
                    // one-line form the row draws: `displayText` is a rendering,
                    // and editing it would silently discard the entry's line
                    // breaks the first time anyone opened this popover.
                    initialText: item,
                    confirmTitle: "Update",
                    onConfirm: { text in
                        // Dismiss BEFORE committing, on the same terms as Delete
                        // below: the commit may raise the table's duplicate
                        // confirmation, and an alert presented while this popover
                        // is still up would compete with it. The write is the
                        // table's, which outlives the popover.
                        // `commitUpdate` reads the draft and current entry
                        // synchronously and defers only the table hand-off until
                        // the popover finishes closing; see its own note.
                        showPopover = false
                        commitUpdate(text)
                    },
                    onCancel: { showPopover = false },
                    // Dismiss BEFORE mutating. The delete removes this row, which
                    // tears down the view the popover is anchored to; ordering it
                    // this way leaves AppKit nothing to dismiss a popover from.
                    // The frames list's Delete does the same. Held until the
                    // close animation has finished for the same reason an add is:
                    // removing a row moves every anchor below it, including this
                    // one — see `ListPopoverDismissal`.
                    onDelete: {
                        // Captured here, at the click, and handed to the table,
                        // which verifies it against the position before removing:
                        // the delete runs after the close animation, and "what is
                        // at this position now" is precisely the question the
                        // verification exists to stop it depending on.
                        let removing = item
                        showPopover = false
                        ListPopoverDismissal.afterClose { onDelete(removing) }
                    }
                )
            }
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
        .onReceive(dismissRowPopovers) { _ in
            if showPopover { showPopover = false }
        }
    }

    // MARK: - Helpers

    /// Writes the draft back, once the popover it came from has finished closing.
    ///
    /// Trimmed on `.whitespacesAndNewlines`, matching `commitAdd`: this editor
    /// accepts line breaks, so a trailing return is whitespace here in a way it
    /// is not in a one-line field. An entry trimmed to nothing is discarded
    /// rather than stored — the Update button is disabled in that state, so this
    /// is the model-level restatement of a rule the UI already enforces.
    ///
    /// **Why the hand-off is deferred.** Everything below is computed
    /// synchronously, at the click; only the hand-off to the table is held. The
    /// table's commit can raise its window-modal duplicate confirmation, and
    /// presenting one while the popover it was raised from is still on screen
    /// and tracking its anchor is exactly the competition `ListPopoverDismissal`
    /// exists to remove. The deferral can't change what's written, since nothing
    /// it depends on is read after it: the finished text and the value the edit
    /// opened against are both captured here, and the table verifies the second
    /// against the row's position before writing (`applyUpdate`).
    private func commitUpdate(_ draft: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Guarded so an Update that changed only surrounding whitespace writes
        // nothing: the array is observed, and a no-op write would still fire an
        // invalidation and a change-tracking pass on the owning tab.
        guard text != item else { return }
        // The value this edit began against, captured now, for the table's
        // position check.
        let expected = item
        // Captured out of `self` so the deferred call carries only the callback
        // it needs rather than the whole row view.
        let update = onUpdate
        ListPopoverDismissal.afterClose { update(expected, text) }
    }
}
