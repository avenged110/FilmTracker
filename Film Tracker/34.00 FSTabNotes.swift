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
    
    // Formatter for WRITING the edit date and the change-detection baseline derived from it. Reading goes
    // through parseDate; see loadData for why a strict single-format read is unsafe.
    //
    // This is the shared "yyyy-MM-dd" storage formatter, the object the parseDate dash branch reads with, so
    // writer and reader cannot disagree. Sharing it also keeps DateFormatter setup to one instance app-wide.
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
        
        // Read through parseDate, the app's canonical parser, not editDateFormatter, which is for writing only.
        //
        // parseDate reads "yyyy-MM-dd" identically to the formatter and also recovers the other shapes the app
        // can store. A value no parser can read still activates the picker, showing today's date, so the user can
        // see and correct it. That fallback logs a warning, because saving then overwrites the stored value.
        //
        // The `?? Date()` fallback matches FSTabDetails' releaseDate load path.
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

    // This tab has no scroll proxy. The list tables reveal a freshly committed row through
    // `ListAddRowRevealer`, which locates its own enclosing scroll view and needs neither an anchor nor a proxy.

    // Layout constants are static: they are process-wide constants drawn from
    // Preferences and never differ between instances. Keeping them static removes
    // them from per-instance allocation and eliminates implicit self captures in
    // every closure inside body that would otherwise reference them.
    private static let labelWidth: CGFloat = Preferences.filmSheetLabelWidth
    // Vertical offset that lines a topLeading label up with the first line of
    // the content beside it. Only the Legend row still uses it — every list row
    // on this tab is now drawn by a child view that applies
    // `ReorderableStringList.labelTopOffset` itself.
    private static let topAlignmentOffset: CGFloat = 2
    

    // Single-string Bindings for the two single-element array fields.
    // Defined here on the View struct (a value type) rather than as computed
    // properties on the @Observable view model, so no Binding heap allocation
    // occurs on every view-model property mutation — SwiftUI evaluates these
    // only when body is re-evaluated, which is already gated by the view's
    // observation tracking scope.
    private var notesOnAudioTimingText: Binding<String> {
        firstElementBinding(\.notesOnAudioTiming)
    }

    private var specialAudioNotesText: Binding<String> {
        firstElementBinding(\.specialAudioNotes)
    }

    /// The field edits the array's FIRST entry only. A restored backup or an older build can
    /// hold more than one (the right sidebar lists them all), so clearing the field removes
    /// just that first entry and keeps the rest, rather than emptying the whole array behind
    /// entries the field never showed.
    private func firstElementBinding(_ keyPath: ReferenceWritableKeyPath<FSTabNotes, [String]>) -> Binding<String> {
        let model = viewModel
        return Binding(
            get: { model[keyPath: keyPath].first ?? "" },
            set: { newValue in
                let current = model[keyPath: keyPath]
                if newValue.isEmpty {
                    model[keyPath: keyPath] = Array(current.dropFirst())
                } else if current.isEmpty {
                    model[keyPath: keyPath] = [newValue]
                } else {
                    model[keyPath: keyPath][0] = newValue
                }
            }
        )
    }
    

    // MARK: - Label helpers
    // Encapsulates the fixed-width, left-aligned, single-line label pattern used by
    // every HStack row. Returning `some View` from a @ViewBuilder avoids constructing
    // the full modifier chain at every call site in body. Mirrors FSTabDetailsView.
    @ViewBuilder
    private func label(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: Self.labelWidth)
    }


    // Variant for rows that pair with ReorderableStringList or
    // ReorderableFramesList. Both sit lower than a plain field, because the
    // inset List they are built on adds its own top padding.
    //
    // Both lists always draw at least their trailing add row, so the padding is unconditional. The rule is
    // ReorderableStringList's own, so the label, the list's first row, and its bulk-import button stay aligned by
    // construction rather than by constants kept in step by hand.
    //
    // .offset rather than .padding: the alignment constants are signed, so
    // either element can be nudged upward, which padding cannot express.
    @ViewBuilder
    private func topListLabel(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: Self.labelWidth)
            .offset(y: ReorderableStringList.labelTopOffset)
    }


    var body: some View {
        let _ = FilmSheetBodyProbe.hit("notes")
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
        // Same scheme as the Metadata tab, and for the same reason: this tab is built on first activation, and it
        // carries seven AppKit scroll-view stacks (four `List`-backed tables and three `NSTextView`s).
        // Fields that cannot be on screen at that moment are given a non-zero wave so their construction lands a
        // few frames later. See `DeferredFieldContent`
        // (30.20 FSControlHelpers.swift).
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


        // Both column widths are fixed (labelWidth and .infinity), so a VStack of HStack rows lays out the same as
        // a Grid, with less work and no column pass.
        //
        // Rows that bind a field are built inside `ObservationBoundary` (30.20) or reach their field by key path
        // (`FilmSheetListRow`, `NotesLegendSection`). A `$viewModel.field` binding created in this body subscribes
        // the body to `field`, so each binding must stay out of this body. The `filmsheet-perf` harness scenario
        // checks this.
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Release — single-line text field
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    // `label`, not a top-aligned variant. This row sits in a center-aligned stack beside a plain
                    // single-line field, and a top padding would push the label's glyphs below the field's centerline.
                    // Every other single-line field row on this sheet uses `label`.
                    label("Release:")
                    TextField("Release Used", text: $viewModel.releaseUsed)
                        .textFieldStyle(.roundedBorder)
                }
            }
            // Software Tools, top-aligned. Built through the shared row so this body never reads `tools`; see
            // FilmSheetListRow.
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.tools,
                                   singularLabel: "Software Tool:",
                                   pluralLabel: "Software Tools:",
                                   itemLabel: "Software Tool",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing)
            // HandBrake RF Value
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("HandBrake RF Value:")
                    HBRFValueStepper(value: $viewModel.editedHBRFValue)
                }
            }
            // Edit Date
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Edit Date:")
                    CustomDateStepper(date: $viewModel.editDate, hasValue: $viewModel.hasEditDate) {
                        viewModel.hasEditDate = false
                    }
                }
            }
            // Warnings, top-aligned. Built through the shared row so this body never reads `warning`.
            //
            // `editor: .popover` (`ReorderableTextList`, 30.50 FSTextList.swift)
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
            ObservationBoundary {
                HStack(alignment: .top, spacing: colSpacing) {
                    label("Description:")
                        .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                    FixedHeightScrollingTextView(text: $viewModel.descriptionNotes, placeholder: "Description of Process Used")
                        .frame(height: descriptionHeight)
                }
            }
            // Audio Timing Notes — top-aligned; label offset matches FixedHeightScrollingTextView inset
            ObservationBoundary {
                HStack(alignment: .top, spacing: colSpacing) {
                    label("Audio Timing Notes:")
                        .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                    FixedHeightScrollingTextView(text: notesOnAudioTimingText, placeholder: "Notes On Audio Timing")
                        .frame(height: audioTimingHeight)
                }
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
            // HandBrake frames and their time codes: one table, top-aligned. Each row carries a frame, its time code,
            // and one set of flags. The two arrays are still stored, loaded, and saved separately, and the right
            // sidebar's Notes tab still draws them as two tables. Every write path writes both arrays together. See
            // the header of 30.40 FSFramesList.swift.
            ObservationBoundary {
                HStack(alignment: .top, spacing: colSpacing) {
                    topListLabel("HandBrake Frames:")
                    ReorderableFramesList(
                        frames: $viewModel.handbrakeFrames,
                        timecodes: $viewModel.correspondingTimecodes,
                        renderWave: 2
                    )
                }
            }
            // Legend: conditional, shown only when an entry in one of the two tables carries a glyph the legend
            // explains. The condition lives inside the child, so reading the two arrays does not put them in this
            // view's observation set.
            NotesLegendSection(model: viewModel,
                               framesKeyPath: \.handbrakeFrames,
                               timecodesKeyPath: \.correspondingTimecodes,
                               labelWidth: Self.labelWidth,
                               columnSpacing: colSpacing,
                               labelTopPadding: Self.topAlignmentOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - Legend Section

/// The Notes tab's legend row, shown only once at least one entry in one of the two
/// frames tables carries a glyph the legend explains (a mark, a fade-in, or a
/// fade-out). Merely holding entries is not enough — see
/// `FramesEntryParser.containsLegendGlyphs`.
///
/// **Why the condition lives here rather than in the tab's body**
///
/// Same observation boundary as `FilmSheetListRow`. Reading the arrays in the tab's body would put both of them
/// in the tab's observation set, so adding one frame entry would invalidate the entire tab. Reading them here
/// confines the invalidation to this row. The frames table is built inside an `ObservationBoundary` (30.20)
/// for the same reason, and its bindings are created there too. The `filmsheet-perf` harness scenario
/// measures this.
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
            LegendRow(glyph: ContentGlyphs.audioFadeIn, label: "Audio fade-in for this section")
            LegendRow(glyph: ContentGlyphs.audioFadeOut, label: "Audio fade-out for this section")

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
