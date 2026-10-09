// MARK: - FSTabNotes.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles the "Notes" tab for FilmSheet.

import SwiftUI

@MainActor
@Observable
final class FSTabNotes {
    weak var owner: FilmSheet?

    // Note fields.
    var releaseUsed: String = "" { didSet { checkForChanges() } }
    var tools: [String] = [] { didSet { checkForChanges() } }
    var editedHBRFValue: Int = 0 { didSet { checkForChanges() } }
    var editDate: Date = Date() { didSet { checkForChanges() } }
    var hasEditDate: Bool = false { didSet { checkForChanges() } }
    var warning: [String] = [] { didSet { checkForChanges() } }
    var descriptionNotes: String = "" { didSet { checkForChanges() } }
    var notesOnAudioTiming: [String] = [] { didSet { checkForChanges() } }
    var specialAudioNotes: [String] = [] { didSet { checkForChanges() } }
    var notesArray: [String] = [] { didSet { checkForChanges() } }
    var handbrakeFrames: [String] = [] { didSet { checkForChanges() } }
    var correspondingTimecodes: [String] = [] { didSet { checkForChanges() } }

    // Baseline captured after the initial load in edit mode: the exact same
    // `FilmNotesFields` value that `collectFilmFields()` produces, so
    // "has anything changed?" is a single `==` against what a save would write.
    // There is deliberately no second, parallel snapshot type — one field list
    // to maintain instead of two that could silently drift apart.
    private var original: FilmNotesFields?

    // Change tracking.
    var hasChanges: Bool = false
    
    // Formatter for WRITING the edit date — DTO conversion and the change-detection
    // baseline that is derived from it. Reading goes through parseDate instead; see
    // loadData for why a strict single-format read was silently destructive.
    //
    // The shared "yyyy-MM-dd" storage formatter — the same object the parseDate branch
    // that reads these strings back uses, so writer and reader cannot disagree. Sharing
    // it also keeps the ~0.5ms DateFormatter initialization to one instance app-wide.
    private static let editDateFormatter = StorageDateFormatters.dash

    // Flag to suppress change tracking during initial data load.
    private var isLoadingData: Bool = false

    // MARK: - Initialization
    init(owner: FilmSheet) {
        self.owner = owner
        // Only preload if editing an existing film.
        if owner.isEditMode {
            loadData(for: owner.filmID)
            captureOriginalValues()
        }
    }

    // MARK: - Load Notes from Database
    private func loadData(for id: UUID) {
        guard let owner = owner else { return }

        // Set flag to suppress change tracking during load.
        isLoadingData = true
        defer { isLoadingData = false }

        // Get film from DataCoordinator's memory store (instant)
        guard let film = owner.coordinator.getFilm(id) else {
            owner.log("ERROR: Film \(id) not found in memory store")
            return
        }

        // Load all fields from the FilmSnapshot.
        releaseUsed = film.releaseUsed
        tools = film.tools
        editedHBRFValue = film.editedHBRFValue
        
        // Convert editDate String to Date and track if it has a value.
        //
        // Read through parseDate — the app's canonical parser — rather than through
        // editDateFormatter, which is kept below for WRITING only.
        //
        // The formatter accepts exactly "yyyy-MM-dd". Any other stored shape (including
        // the app's own canonical "yyyy-MM-dd'T'HH:mm:ss'Z'" that FSTabDetails writes for
        // releaseDate, the "yyyy.MM.dd" the releases tab writes, or anything a restore or
        // an import produced) returned nil and fell back to `Date()` — TODAY — while
        // still setting hasEditDate = true. captureOriginalValues() then recorded today's
        // date as the baseline, so the sheet did not look dirty, and the next save
        // silently rewrote the film's edit date to whatever day the sheet happened to be
        // opened. A stored value the user never touched, replaced without a prompt.
        //
        // parseDate handles "yyyy-MM-dd" identically — its dash branch reads through the
        // very same StorageDateFormatters.dash this tab writes with, so "identically" is
        // now identity rather than two configurations that match — and the overwhelmingly
        // common case is byte-for-byte unchanged, with no film's baseline moving. It only adds recovery for the shapes that previously silently lost data.
        //
        // The `?? Date()` remains for a value that no parser can make sense of, matching
        // the precedent in FSTabDetails' releaseDate load path: a non-empty but
        // unparseable value still activates the picker rather than being hidden as unset,
        // so the user can see and correct it.
        if film.editDate.isEmpty {
            editDate = Date()
            hasEditDate = false
        } else {
            if let parsed = parseDate(from: film.editDate) {
                editDate = parsed
            } else {
                editDate = Date()
                owner.log("WARNING: Film \(id) has an unparseable editDate '\(film.editDate)' — the picker opens on today's date and will overwrite it if the sheet is saved.")
            }
            hasEditDate = true
        }
        
        warning = film.warning
        descriptionNotes = film.descriptionNotes
        notesOnAudioTiming = film.notesOnAudioTiming
        specialAudioNotes = film.specialAudioNotes
        notesArray = film.notesArray
        handbrakeFrames = film.handbrakeFrames
        correspondingTimecodes = film.correspondingTimecodes
    }

    // Capture original state after loading.
    private func captureOriginalValues() {
        original = collectFilmFields()
    }

    // MARK: - Change Tracking
    private func checkForChanges() {
        // Don't track changes during initial data load.
        guard !isLoadingData else { return }
        
        guard let owner = owner, owner.isEditMode, let orig = original else {
            // Only write — and therefore only fire an observation invalidation —
            // when the value actually needs to change (defensive; should always
            // be false here).
            if hasChanges { hasChanges = false }
            return
        }
        
        // One comparison against the baseline. `FilmNotesFields` is what a save
        // actually writes, so any difference here is a real, persistable edit and
        // anything it collapses is a no-op on disk.
        //
        // The edit date is the case that matters: `collectFilmFields()` renders it as
        // the stored "yyyy-MM-dd" string, empty when `hasEditDate` is false, so:
        //   • Setting or clearing the date changes the string to/from "".
        //   • With no date on either side, both strings are "" — the wall-clock
        //     `Date()` default is never compared and can't manufacture a phantom change.
        //   • With a date on both sides, comparison is day-precision, matching storage.
        //     Comparing `Date` values directly would not: a date parsed from storage
        //     has its time zeroed, while the same day chosen in the picker may carry a
        //     time component, differing despite displaying and saving identically.
        let changed = collectFilmFields() != orig

        // Only write hasChanges — and only call owner.notifyChanges() — when the
        // aggregated result actually differs from the last known value. Skipping
        // the no-op path keeps every keystroke in edit mode from waking FilmSheet
        // once hasChanges has already latched to its steady-state value.
        // Mirrors the identical pattern in FSTabReleases.checkForChanges().
        if hasChanges != changed {
            hasChanges = changed
            owner.notifyChanges()
        }
    }

    // MARK: - DTO Support
    /// Collects all notes tab fields as a plain Sendable struct for FilmChangeset assembly.
    /// Called by FilmSheet.confirm() on the DTO-based save path.
    func collectFilmFields() -> FilmNotesFields {
        let editDateString: String
        if hasEditDate {
            editDateString = FSTabNotes.editDateFormatter.string(from: editDate)
        } else {
            editDateString = ""
        }
        return FilmNotesFields(
            releaseUsed: releaseUsed,
            tools: tools,
            editedHBRFValue: editedHBRFValue,
            editDate: editDateString,
            warning: warning,
            descriptionNotes: descriptionNotes,
            notesOnAudioTiming: notesOnAudioTiming,
            specialAudioNotes: specialAudioNotes,
            notesArray: notesArray,
            handbrakeFrames: handbrakeFrames,
            correspondingTimecodes: correspondingTimecodes
        )
    }
}

// MARK: - FilmNotesFields
/// Plain Sendable struct carrying the notes tab's contribution to a FilmChangeset.
struct FilmNotesFields: Sendable, Equatable {
    let releaseUsed: String
    let tools: [String]
    let editedHBRFValue: Int
    let editDate: String
    let warning: [String]
    let descriptionNotes: String
    let notesOnAudioTiming: [String]
    let specialAudioNotes: [String]
    let notesArray: [String]
    let handbrakeFrames: [String]
    let correspondingTimecodes: [String]
}

// MARK: - SwiftUI View
struct FSTabNotesView: View {
    @Bindable var viewModel: FSTabNotes

    // No scroll proxy. This tab carried one only so its call site looked uniform
    // with the Details tab's; it was never read here or handed to any child, and
    // the two commands that once scrolled this tab are gone. Nothing on the tab
    // publishes a scroll anchor either, so a proxy would have had no target even
    // if something called it. The list tables reveal a freshly committed row
    // through `ListAddRowRevealer`, which locates its own enclosing scroll view
    // and needs neither an anchor nor a proxy.

    // Layout constants are static: they are process-wide constants drawn from
    // Preferences and never differ between instances. Keeping them static removes
    // them from per-instance allocation and eliminates implicit self captures in
    // every closure inside body that previously referenced them.
    private static let labelWidth: CGFloat = Preferences.filmSheetLabelWidth
    // Vertical offset that lines a topLeading label up with the first line of
    // the content beside it. Only the Legend row still uses it — every list row
    // on this tab is now drawn by a child view that applies
    // `ReorderableStringList.labelTopOffset` itself.
    private static let topAlignmentOffset: CGFloat = 2
    
    // The two lifted popover triggers and two scroll anchors that used to sit here
    // are gone with the Opt+A/Opt+S shortcuts that drove them — back when a frames
    // table's add control was a "+" fixed beside its top edge, reachable while the
    // row it created was below the fold. Every table's add control is now its own
    // last row, unclickable unless already visible, and scrolls itself into view
    // after each commit (`ListAddRowRevealer`), so there's nothing left for an
    // external trigger or scroll anchor to do. The `UICommand` cases and
    // KeyboardManager branches went with them, as did the Software Tools list's
    // own anchor, "notes.tools".

    // Single-string Bindings for the two single-element array fields.
    // Defined here on the View struct (a value type) rather than as computed
    // properties on the @Observable view model, so no Binding heap allocation
    // occurs on every view-model property mutation — SwiftUI evaluates these
    // only when body is re-evaluated, which is already gated by the view's
    // observation tracking scope.
    private var notesOnAudioTimingText: Binding<String> {
        Binding(
            get: { viewModel.notesOnAudioTiming.first ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    viewModel.notesOnAudioTiming = []
                } else if viewModel.notesOnAudioTiming.isEmpty {
                    viewModel.notesOnAudioTiming = [newValue]
                } else {
                    viewModel.notesOnAudioTiming[0] = newValue
                }
            }
        )
    }

    private var specialAudioNotesText: Binding<String> {
        Binding(
            get: { viewModel.specialAudioNotes.first ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    viewModel.specialAudioNotes = []
                } else if viewModel.specialAudioNotes.isEmpty {
                    viewModel.specialAudioNotes = [newValue]
                } else {
                    viewModel.specialAudioNotes[0] = newValue
                }
            }
        )
    }
    
    // The `pluralMap` lookup table and the `pluralizedLabel` helper that read it
    // are gone. Both existed only to build the Warnings and Notes labels in this
    // body, which is what put those two arrays in this view's observation set.
    // The labels are now supplied to `FilmSheetListRow` fully formed, so
    // there is no table to consult and nothing to derive.

    // MARK: - Label helpers
    // Encapsulates the fixed-width, left-aligned, single-line label pattern used by
    // every HStack row. Returning `some View` from a @ViewBuilder avoids constructing
    // the full modifier chain at every call site in body. Mirrors FSTabDetailsView.
    @ViewBuilder
    private func label(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: Self.labelWidth)
    }

    // The `topLabel` helper that used to sit here has no callers left. Every row
    // that needed it — Warnings, Notes, and the Legend — is now built through a
    // child view that draws its own label. Warnings and Notes take the rule from
    // `ReorderableStringList.labelTopOffset`, the same as every other list row on
    // the sheet; the Legend still receives `Self.topAlignmentOffset` as
    // `labelTopPadding`, because it pairs with a plain `VStack` rather than a
    // `List` and so keeps the older offset.

    // Variant for rows that pair with ReorderableStringList or
    // ReorderableFramesList. Both sit lower than a plain field, because the
    // inset List they are built on adds its own top padding.
    //
    // This used to take the paired list's item count, because that padding was
    // applied only when the list held content and a fixed offset therefore lined
    // up in one state and not the other. Both lists now always draw at least
    // their trailing add row, so the padding is unconditional and one constant
    // covers both states. The rule is still ReorderableStringList's own, so the
    // label, the list's first row, and the list's bulk-import button stay
    // aligned by construction rather than by constants kept in step by hand.
    //
    // .offset rather than .padding: the alignment constants are signed, so
    // either element can be nudged upward, which padding cannot express.
    @ViewBuilder
    private func topListLabel(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: Self.labelWidth)
            .offset(y: ReorderableStringList.labelTopOffset)
    }

    // `scrollAnchor(_:)` moved into `FilmSheetListRow`, the only thing
    // that used it. The two frames rows below used to publish their own anchors
    // inline as well; both are gone with the shortcuts that targeted them.

    var body: some View {
        // Local shadows of the static layout constants — gives every downstream
        // call site in this property unqualified access without explicit Self.
        // qualification, at zero runtime cost (no allocation, no capture).
        let colSpacing: CGFloat = 16
        let rowSpacing: CGFloat = 10

        // Heights of the three multiline fields, resolved once here rather than
        // at their call sites. The measurement behind them is memoized per line
        // count — see FixedHeightScrollingTextView.fixedHeight(lineCount:) — and
        // hoisting them also guarantees a deferred field and its stand-in cannot
        // be given different numbers.
        let descriptionHeight   = FixedHeightScrollingTextView.fixedHeight(lineCount: 7)
        let audioTimingHeight   = FixedHeightScrollingTextView.fixedHeight(lineCount: 10)
        let specialAudioHeight  = FixedHeightScrollingTextView.fixedHeight(lineCount: 5)

        // MARK: Build waves
        //
        // Same scheme as the Metadata tab, and for the same reason: this tab is
        // built the first time the user activates it, and it carries seven
        // AppKit scroll-view stacks — four `List`-backed tables and three
        // `NSTextView`s — every one of which was previously constructed before
        // the tab's first frame was shown. Fields that cannot be on screen at
        // that moment are given a non-zero wave so their construction lands a
        // few frames later. See `DeferredFieldContent`
        // (30_20_FSControlHelpers.swift).
        //
        // Where the line is drawn, computed against the minimum height every
        // field above can collapse to, since that is the arrangement that pulls
        // the most content into view. The sheet's tab viewport is roughly 460pt.
        // Release, Software Tools (one add row at minimum), the RF stepper, the
        // date picker, Warnings (likewise one row), Description (7 lines) and
        // Audio Timing Notes (10 lines) take it to about y=530 at the earliest —
        // so Audio Timing Notes is the last field whose top edge can enter the
        // viewport, and everything through it stays in wave 0.
        //
        // Special Audio Notes therefore begins no higher than about y=530, with
        // the Notes table and the HandBrake Frames table below it again. Those
        // three are deferred, split across two waves so the run loop gets a turn
        // between them. The frames table is last because it is the most
        // expensive component on the sheet — a paired two-column table whose
        // every row carries its own popover-anchored controls.
        //
        // The Legend below it is deliberately NOT deferred: it is a conditional
        // row of plain `Text` and `Image`, so it is cheap to build and, being
        // conditional, has no height that could be reserved without evaluating
        // the condition the section exists to keep out of this body.

        // The `showLegend` precomputation that used to sit here is gone with the
        // inline conditional it fed. It read two of the view model's arrays, which
        // is precisely what kept this body being invalidated by frames-list edits;
        // the condition now lives in `NotesLegendSection`, which is the only thing
        // that has to re-evaluate when it changes.

        // VStack of HStack rows replaces Grid/GridRow. Both column widths are fixed
        // constants (labelWidth and .infinity), so Grid's two-pass column-resolution
        // sweep was doing zero useful negotiation work — confirming values it was
        // already given on every sheet open. VStack/HStack produces pixel-identical
        // output with one fewer layout container per row (~13 rows) and no column pass.
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Release — single-line text field
            HStack(alignment: .center, spacing: colSpacing) {
                // `label`, not a top-aligned variant. This row pairs with a plain
                // single-line TextField in a center-aligned stack, so the 2pt top
                // padding the top-aligned label carries — which exists to line a
                // label up with the first line of multi-line content — grew the
                // label's box and pushed its glyphs below the field's centerline.
                // Every other single-line field row on this sheet uses `label`.
                label("Release:")
                TextField("Release Used", text: $viewModel.releaseUsed)
                    .textFieldStyle(.roundedBorder)
            }
            // Software Tools — top-aligned. Uses the reorderable list, as every
            // string-list row on this tab now does.
            //
            // Built through the shared row rather than inline so this body never
            // reads `tools` — see FilmSheetListRow. Inline, the label's
            // count read put the array in this view's observation set, so every
            // entry committed in the list re-rendered the whole tab.
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.tools,
                                   singularLabel: "Software Tool:",
                                   pluralLabel: "Software Tools:",
                                   itemLabel: "Software Tool",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing)
            // HandBrake RF Value
            HStack(alignment: .center, spacing: colSpacing) {
                label("HandBrake RF Value:")
                HBRFValueStepper(value: $viewModel.editedHBRFValue)
            }
            // Edit Date
            HStack(alignment: .center, spacing: colSpacing) {
                label("Edit Date:")
                CustomDatePicker(date: $viewModel.editDate, hasValue: $viewModel.hasEditDate) {
                    viewModel.hasEditDate = false
                }
            }
            // Warnings — top-aligned. Built through the shared row for the same
            // reason the Software Tools list is: inline, the label's count read
            // put `warning` in THIS view's observation set, so every entry added
            // or removed in the list re-rendered the whole tab.
            //
            // `editor: .popover` (`ReorderableTextList`, 30_50_FSTextList.swift)
            // rather than the inline string list. Warnings and Notes routinely hold a
            // paragraph, and the string list edits an entry in place through a
            // one-line field — a sliding window onto text there is no way to see
            // whole while editing. The text list is the same table with the same
            // chrome, edited through a popover holding a seven-line scrolling
            // text view. Every other list on the sheet, this tab's Software Tools
            // included, holds short values and stays on the string list.
            FilmSheetListRow(model: viewModel,
                             keyPath: \.warning,
                             singularLabel: "Warning:",
                             pluralLabel: "Warnings:",
                             itemLabel: "Warning",
                             labelWidth: Self.labelWidth,
                             columnSpacing: colSpacing,
                             editor: .popover)
            // Description — top-aligned; label offset matches FixedHeightScrollingTextView inset
            HStack(alignment: .top, spacing: colSpacing) {
                label("Description:")
                    .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                FixedHeightScrollingTextView(text: $viewModel.descriptionNotes, placeholder: "Description of Process Used")
                    .frame(height: descriptionHeight)
            }
            // Audio Timing Notes — top-aligned; label offset matches FixedHeightScrollingTextView inset
            HStack(alignment: .top, spacing: colSpacing) {
                label("Audio Timing Notes:")
                    .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                FixedHeightScrollingTextView(text: notesOnAudioTimingText, placeholder: "Notes On Audio Timing")
                    .frame(height: audioTimingHeight)
            }
            // Special Audio Notes — top-aligned; label offset matches FixedHeightScrollingTextView inset.
            //
            // The first field below the fold, and an NSTextView inside an
            // NSScrollView, so it is the first one deferred. `specialAudioHeight`
            // is the exact height the real control takes, so the stand-in
            // reserves the same space and the swap moves nothing.
            HStack(alignment: .top, spacing: colSpacing) {
                label("Special Audio Notes:")
                    .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                DeferredFieldContent(wave: 1, placeholderHeight: specialAudioHeight) {
                    FixedHeightScrollingTextView(text: specialAudioNotesText, placeholder: "Special Audio Notes")
                        .frame(height: specialAudioHeight)
                }
            }
            // Notes — top-aligned. Same observation boundary as Warnings above,
            // and the same popover-based editor, for the same reason.
            FilmSheetListRow(model: viewModel,
                             keyPath: \.notesArray,
                             singularLabel: "Note:",
                             pluralLabel: "Notes:",
                             itemLabel: "Note",
                             labelWidth: Self.labelWidth,
                             columnSpacing: colSpacing,
                             renderWave: 1,
                             editor: .popover)
            // HandBrake frames and their time codes — one table, top-aligned.
            //
            // These were two `ReorderableFramesList` instances, one per array,
            // and keeping them in step was left entirely to the user: entry n of
            // one described the same moment as entry n of the other, and the
            // mark and the two fade flags had to be set identically on both by
            // hand. A delete, a reorder, or a flag set on one and not the other
            // desynchronized the pair silently.
            //
            // The two arrays are unchanged and are still stored, loaded, and
            // saved separately — the right sidebar's Notes tab still draws them
            // as two tables, where the horizontal space does not allow anything
            // else. What is combined is the editing surface: one row now carries
            // a frame, its time code, and ONE set of flags, and every write path
            // writes both arrays together. See the header of
            // 30_40_FSFramesList.swift.
            HStack(alignment: .top, spacing: colSpacing) {
                topListLabel("HandBrake Frames:")
                ReorderableFramesList(
                    frames: $viewModel.handbrakeFrames,
                    timecodes: $viewModel.correspondingTimecodes,
                    renderWave: 2
                )
            }
            // Legend — conditional; shown only when an entry in one of the two
            // tables actually carries a glyph the legend explains. The condition
            // lives inside the child rather than here so
            // that reading the two arrays does not put them in THIS view's
            // observation set: adding a single frame entry previously invalidated
            // the whole tab body, rebuilding both frames lists, every text view,
            // and both editable lists.
            NotesLegendSection(model: viewModel,
                               framesKeyPath: \.handbrakeFrames,
                               timecodesKeyPath: \.correspondingTimecodes,
                               labelWidth: Self.labelWidth,
                               columnSpacing: colSpacing,
                               labelTopPadding: Self.topAlignmentOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The `.onReceive(AppEventBus.shared.uiCommands)` sink that used to sit
        // here is gone with the two commands it handled. It scrolled to one of
        // the frames anchors and then set that table's external add trigger, a
        // two-step dance that existed only because the add control could be
        // invoked while the row it produced was off screen. That control is now
        // the table's own last row and reveals itself after every commit, so
        // both steps have nothing left to do.
    }
}

// The `FilmSheetEditableListRow` that used to sit here is gone with the last two
// callers of `EditableStringList`. Warnings and Notes are now drawn by
// `FilmSheetListRow` (30_30_FSStringList.swift) with `editor: .popover`, and the
// Software Tools list above by the same row with its default inline editor — the
// same labeled row every list on the Metadata tab uses. Moving a field between
// the two lists is a change to that one argument.
//
// The two types differed only in which list they paired with and, consequently,
// in how their label was nudged into line with it: this one took a
// `labelTopPadding` because it cleared the first text field of a plain `VStack`,
// where the surviving row applies `ReorderableStringList.labelTopOffset` itself
// to clear the internal top padding of an inset `List`. With one list left there
// is one rule, and it lives with the list that defines it rather than being
// passed in from each tab. The observation boundary both types existed to draw —
// reaching the array by key path so the tab's body never reads it — is unchanged
// and is documented on the surviving type.

// MARK: - Legend Section

/// The Notes tab's legend row, shown only once at least one entry in one of the two
/// frames tables carries a glyph the legend explains (a mark, a fade-in, or a
/// fade-out). Merely holding entries is not enough — see
/// `FramesEntryParser.containsLegendGlyphs`.
///
/// **Why the condition lives here rather than in the tab's body**
///
/// Same observation boundary as `FilmSheetListRow`. Evaluating the arrays in
/// the tab's
/// body was the only thing putting either array in the tab's observation set —
/// `ReorderableFramesList` receives them as `Binding`s, and constructing a
/// `Binding` from `@Bindable` does not read the value it projects. So adding one
/// frame entry invalidated the entire tab. Moving the read into the one view
/// whose appearance actually depends on it confines the invalidation to this row.
///
/// Read-only, so a plain stored reference rather than `@Bindable`: `@Observable`
/// tracking applies to any property read inside a `View` body, and nothing here
/// needs to write.
private struct NotesLegendSection<Model: AnyObject & Observable>: View {

    let model: Model
    let framesKeyPath: KeyPath<Model, [String]>
    let timecodesKeyPath: KeyPath<Model, [String]>

    let labelWidth: CGFloat
    let columnSpacing: CGFloat
    let labelTopPadding: CGFloat

    var body: some View {
        // Yields no subview at all when neither table holds an annotated entry, so the enclosing
        // VStack neither draws the row nor reserves spacing for it — the same
        // result the inline `if` produced.
        if FramesEntryParser.containsLegendGlyphs(model[keyPath: framesKeyPath])
            || FramesEntryParser.containsLegendGlyphs(model[keyPath: timecodesKeyPath]) {
            HStack(alignment: .top, spacing: columnSpacing) {
                FilmSheetFieldLabel("Legend:", width: labelWidth)
                    .padding(.top, labelTopPadding)

                LegendContent()
            }
        }
    }
}

// MARK: - Legend Views

// LegendContent and LegendRow are extracted as standalone structs rather than
// @ViewBuilder properties / functions on FSTabNotesView for two reasons:
//
//  1. Stable identity — SwiftUI assigns each struct a stable node in the view
//     tree, so it can diff and skip re-evaluation when nothing has changed.
//     A @ViewBuilder var or func is inlined directly into the parent's body and
//     re-runs unconditionally on every FSTabNotesView body evaluation.
//
//  2. No captured state — both structs are entirely static (no bindings, no
//     observed objects). Expressing that at the type level lets the compiler
//     and the SwiftUI runtime confirm there is nothing to diff at the call site,
//     eliminating even the lightweight equality check that @ViewBuilder closures
//     require.

private struct LegendContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LegendRow(glyph: "asterisk", label: "See notes")
            LegendRow(glyph: "chevron.up", label: "See notes")
            LegendRow(glyph: "number", label: "See notes")
            LegendRow(glyph: "arrow.up.right.circle.fill", label: "Audio fade-in for this section")
            LegendRow(glyph: "arrow.down.right.circle.fill", label: "Audio fade-out for this section")

            Text("Final Cut Pro audio fade effects:")
                .font(.system(size: 13))
                .padding(.top, 8)

            LegendRow(glyph: "line.diagonal", label: "Linear")
            LegendRow(glyph: "point.bottomleft.forward.to.point.topright.scurvepath", label: "S-curve")
            LegendRow(glyph: "wave.3.up", label: "+3dB")
            LegendRow(glyph: "wave.3.down", label: "-3dB")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LegendRow: View {
    let glyph: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .leading)
            Text(label)
                .font(.system(size: 13))
        }
    }
}
