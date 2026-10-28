// MARK: - FSTabMetadata.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles the "Metadata" tab for FilmSheet.

import SwiftUI

@MainActor
@Observable
final class FSTabMetadata {
    weak var owner: FilmSheet?

    // Metadata Fields
    var sortName: String = "" { didSet { checkForChanges() } }
    var digitalSource: String = "" { didSet { checkForChanges() } }
    var digitalVersion: String = "" {
        didSet {
            // A colorized copy is by definition a color copy, and a black-and-white one
            // is by definition not — see the picker's own doc comment. Locking Color to
            // the matching value the instant either is selected (rather than only at
            // save) keeps the two fields from ever showing a contradictory pair on
            // screen, and it reacts to every selection in real time, including one made
            // programmatically (e.g. by an import).
            if digitalVersion == ViewingVersion.colorized.rawValue, !color {
                color = true
            } else if digitalVersion == ViewingVersion.blackAndWhite.rawValue, color {
                color = false
            }
            checkForChanges()
        }
    }
    var isRemastered: Bool = false { didSet { checkForChanges() } }
    var subtitles: String = "" { didSet { checkForChanges() } }
    var aspectRatio: String = "" { didSet { checkForChanges() } }
    var frameRate: Double = 0.0 { didSet { checkForChanges() } }
    var color: Bool = false { didSet { checkForChanges() } }

    /// True while "Colorized" or "Black-and-White" is the selected version, in which
    /// case the Color checkbox is locked to the matching value (see digitalVersion's
    /// didSet) and must not be user-editable — toggling it would leave the
    /// contradictory pair the digital-version menu's own qualification exists to
    /// prevent.
    var isColorLocked: Bool {
        digitalVersion == ViewingVersion.colorized.rawValue
            || digitalVersion == ViewingVersion.blackAndWhite.rawValue
    }
    var libraryHBRFValue: Int = 0 { didSet { checkForChanges() } }
    var encodingTool: [String] = [] { didSet { checkForChanges() } }
    var cast: [String] = [] { didSet { checkForChanges() } }
    var directors: [String] = [] { didSet { checkForChanges() } }
    var producers: [String] = [] { didSet { checkForChanges() } }
    var executiveProducers: [String] = [] { didSet { checkForChanges() } }
    var screenwriters: [String] = [] { didSet { checkForChanges() } }
    var composer: [String] = [] { didSet { checkForChanges() } }
    var studio: [String] = [] { didSet { checkForChanges() } }
    var alternateTitle: [String] = [] { didSet { checkForChanges() } }
    var notes: String = "" { didSet { checkForChanges() } }
    var comments: String = "" { didSet { checkForChanges() } }
    var tags: [String] = [] { didSet { checkForChanges() } }

    // Baseline captured after the initial load in edit mode: the exact same
    // `FilmMetadataFields` value that `collectFilmFields()` produces, so
    // "has anything changed?" is a single `==` against what a save would write.
    // There is deliberately no second, parallel snapshot type — one field list
    // to maintain instead of two that could silently drift apart.
    private var original: FilmMetadataFields?
    
    // Change tracking.
    var hasChanges: Bool = false
    
    // Flag to suppress change tracking during initial data load.
    private var isLoadingData: Bool = false

    /// Whether the iTunes Comments field is shown on this sheet.
    ///
    /// The field is a read-back of imported iTunes metadata. Its contents are
    /// parsed during ingestion to seed other fields, after which it serves only
    /// as a reference display — nothing in the app reads it again — so a film
    /// that carries none has no reason to show an empty box for it.
    ///
    /// **Why this is a snapshot and not a live `!comments.isEmpty`**
    ///
    /// Two reasons, and either alone would be sufficient.
    ///
    /// First, correctness of the interaction. A live read would tear the field
    /// out from under the user the instant they selected all and deleted — the
    /// editor would vanish mid-edit, taking first responder with it, and there
    /// would be no way to type anything back. Deciding once, at load, means the
    /// field stays put for the whole session however it is edited; a film whose
    /// comments are cleared and saved simply opens without the field next time,
    /// which is the behavior asked for.
    ///
    /// Second, observation. `FSTabMetadataView`'s body does not read `comments`
    /// today — the field reaches it through a `Binding`, and constructing one
    /// from `@Bindable` does not read the value it projects. A live condition in
    /// the body would read it, putting the string into the whole tab's
    /// observation set, so every keystroke in the comments field would
    /// re-evaluate the entire tab. This flag is written once during
    /// `loadMetadata` and never again, so reading it in the body opens a
    /// subscription that can never fire.
    ///
    /// `false` in add mode, where there is nothing imported to display.
    private(set) var displaysComments: Bool = false

    // Digital source options — the vocabulary itself lives in FilmDigitalSource, since
    // the Reports tab charts the same tags in a different order and the metadata importer
    // writes two of them.
    static let digitalSourceOptions = FilmDigitalSource.pickerOptions

    // Subtitle options.
    static let subtitleOptions = FilmSubtitles.pickerOptions

    // Aspect ratio options — shared with the release card's own aspect-ratio control,
    // which offers the identical tag set for Release.releaseAspectRatio.
    static let aspectRatioOptions = AspectRatioVocabulary.pickerOptions

    // Frame rate options (fps).
    // Stored as a typed pair so the Double tag and its display label are always
    // in lockstep — no format-string derivation that could silently round values.
    // 0.0 / "Select…" is the sentinel for "no value selected".
    struct FrameRateOption: Identifiable {
        let value: Double
        let label: String
        var id: Double { value }
    }
    static let frameRateOptions: [FrameRateOption] = [
        .init(value:  0.0,   label: "Select Frame Rate…"),
        .init(value: 23.98,  label: "23.98"),
        .init(value: 24.0,   label: "24.00"),
        .init(value: 25.0,   label: "25.00"),
        .init(value: 29.97,  label: "29.97"),
        .init(value: 30.0,   label: "30.00"),
        .init(value: 47.95,  label: "47.95"),
        .init(value: 48.0,   label: "48.00"),
        .init(value: 50.0,   label: "50.00"),
        .init(value: 59.94,  label: "59.94"),
        .init(value: 60.0,   label: "60.00"),
    ]

    /// Snaps an incoming frameRate to the known option within ±0.01 of it, so a stored
    /// 23.976 selects the "23.98" row. A value with no such option is returned UNCHANGED.
    ///
    /// It used to fall back to 0.0. The metadata importer stores a file's nominal rate to
    /// two decimals — 119.88, 15.00, 12.00 are all real results — and zeroing those at load
    /// made the zero the change-detection baseline, so the next save of any unrelated edit
    /// silently erased the rate. Kept as-is, it reaches SheetPopUpButton, whose
    /// effectiveItems gives an out-of-vocabulary tag its own row — the policy the Genre,
    /// Rating, Aspect Ratio and Subtitles pickers already follow.
    static func normalizeFrameRate(_ value: Double) -> Double {
        guard value != 0.0 else { return 0.0 }
        return frameRateOptions.first { abs($0.value - value) < 0.01 }?.value ?? value
    }

    // Computed property for digital source (combines base source with remastered flag).
    var computedDigitalSource: String {
        FilmDigitalSource.compose(source: digitalSource, remastered: isRemastered)
    }

    // MARK: - Initialization
    init(owner: FilmSheet) {
        self.owner = owner
        // Only preload if editing an existing film.
        // In add mode, all fields use their declaration defaults
        // and no load or captureOriginalValues call is needed.
        if owner.isEditMode {
            loadMetadata(for: owner.filmID)
            captureOriginalValues()
        }
    }

    // MARK: - Load Metadata from Database
    private func loadMetadata(for id: UUID) {
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
        sortName = film.sortName

        // Split the composite digitalSource field back into its source and remastered
        // halves. Deliberately NOT trimmed — the stored value is shown in a picker whose
        // tags are the stored strings, so trimming here would make an odd stored value
        // silently unselectable rather than visible.
        (digitalSource, isRemastered) = FilmDigitalSource.decompose(film.digitalSource)
        // color must be assigned before digitalVersion: if the stored data has
        // "Colorized" without color, or "Black-and-White" with it (a contradictory
        // pair from an older build or a hand-edited database), digitalVersion's
        // didSet forces color to the matching value, and that must be the value
        // which wins — assigning color afterward would silently restore the
        // contradiction as the load-time baseline.
        color = film.color
        digitalVersion = film.digitalVersion
        subtitles = film.subtitles
        aspectRatio = film.aspectRatio
        frameRate = Self.normalizeFrameRate(film.frameRate)
        libraryHBRFValue = film.libraryHBRFValue
        encodingTool = film.encodingTool
        cast = film.cast
        directors = film.directors
        producers = film.producers
        executiveProducers = film.executiveProducers
        screenwriters = film.screenwriters
        composer = film.composer
        studio = film.studio
        alternateTitle = film.alternateTitle
        notes = film.notes
        comments = film.comments
        tags = film.tags

        // Decided here, once, from the value as it exists in the store — see the
        // property's own note for why this is not re-derived later. Whitespace
        // alone does not count as content: a field holding a stray newline is
        // indistinguishable from an empty one on screen, so showing the box for
        // it would present the user with the empty field this gate exists to
        // remove.
        displaysComments = !film.comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // Capture original state after loading.
    private func captureOriginalValues() {
        original = collectFilmFields()
    }

    // MARK: - Change Tracking
    private func checkForChanges() {
        // Don't track changes during initial data load.
        guard !isLoadingData else { return }

        // In add mode there is no original snapshot and hasChanges is always false.
        // Skip the assignment entirely when it would be a no-op to avoid firing
        // an observation invalidation on every keystroke for no reason.
        guard let owner = owner, owner.isEditMode, let orig = original else {
            // Only write — and therefore only fire an observation invalidation —
            // when the value actually needs to change (defensive; should always
            // be false here).
            if hasChanges { hasChanges = false }
            return
        }
        
        // One comparison against the baseline. `FilmMetadataFields` is what a save
        // actually writes, so any difference here is a real, persistable edit and
        // anything it collapses is, by construction, a no-op on disk.
        //
        // `isRemastered` is the case that matters: it is not a stored field on its
        // own — `collectFilmFields()` persists `computedDigitalSource`, of which the
        // flag is one input. Comparing the flag separately (as an earlier field-by-
        // field version did) reported an unsaved change for a toggle made while no
        // source is selected, a state in which `computedDigitalSource` is unchanged
        // and saving would write nothing, leaving the sheet claiming edits it had none
        // of. Comparing the collected value keeps that correct without a special case.
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
    /// Collects all metadata tab fields as a plain Sendable struct for FilmChangeset assembly.
    /// Called by FilmSheet.confirm() on the DTO-based save path.
    func collectFilmFields() -> FilmMetadataFields {
        return FilmMetadataFields(
            sortName:           sortName,
            digitalSource:      computedDigitalSource,
            digitalVersion:     digitalVersion,
            subtitles:          subtitles,
            aspectRatio:        aspectRatio,
            frameRate:          frameRate,
            color:              color,
            libraryHBRFValue:   libraryHBRFValue,
            encodingTool:       encodingTool,
            cast:               cast,
            directors:          directors,
            producers:          producers,
            executiveProducers: executiveProducers,
            screenwriters:      screenwriters,
            composer:           composer,
            studio:             studio,
            alternateTitle:     alternateTitle,
            notes:              notes,
            comments:           comments,
            tags:               tags
        )
    }
}

// MARK: - FilmMetadataFields
/// Plain Sendable struct carrying the metadata tab's contribution to a FilmChangeset.
struct FilmMetadataFields: Sendable, Equatable {
    let sortName: String
    let digitalSource: String
    let digitalVersion: String
    let subtitles: String
    let aspectRatio: String
    let frameRate: Double
    let color: Bool
    let libraryHBRFValue: Int
    let encodingTool: [String]
    let cast: [String]
    let directors: [String]
    let producers: [String]
    let executiveProducers: [String]
    let screenwriters: [String]
    let composer: [String]
    let studio: [String]
    let alternateTitle: [String]
    let notes: String
    let comments: String
    let tags: [String]
}

// MARK: - SwiftUI View
struct FSTabMetadataView: View {

    @Bindable var viewModel: FSTabMetadata

    // No scroll proxy. It used to be handed to each `FilmSheetListRow` so
    // that adding an entry could pull an off-screen list into view; that became
    // obsolete once the "+" control moved to the list's own last row, which
    // cannot be clicked from outside the viewport, and `ListAddRowRevealer` now
    // covers the remaining case without an anchor or a proxy. It survived a while
    // longer as an unread property purely to keep this view's memberwise
    // initializer shaped like the Details tab's; that is not a reason to carry
    // plumbing, so it is gone along with the argument at the call site.

    // Static: resolved once at type load time; never re-evaluated per-instance
    // or per-render. Pulling from Preferences statics is already free, but
    // keeping them here as `static let` makes the zero-cost contract explicit and
    // avoids repeated static property dispatch during layout passes.
    private static let labelWidth        = Preferences.filmSheetLabelWidth
    private static let pickerWidth       = Preferences.standardPickerWidth

    // The menu pickers' rows, built once from the option tables in FSTabMetadata. The empty
    // option is each menu's placeholder row.
    private static let digitalSourceItems: [SheetPopUpButton<String>.Item] =
        FSTabMetadata.digitalSourceOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select..." : $0) }
    private static let subtitleItems: [SheetPopUpButton<String>.Item] =
        FSTabMetadata.subtitleOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select Subtitles…" : $0) }
    private static let aspectRatioItems: [SheetPopUpButton<String>.Item] =
        FSTabMetadata.aspectRatioOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select Aspect Ratio…" : $0) }
    private static let frameRateItems: [SheetPopUpButton<Double>.Item] =
        FSTabMetadata.frameRateOptions.map { .option(tag: $0.value, title: $0.label) }
    /// Two fixed tables rather than a rebuild per body evaluation: the only thing that varies
    /// is whether the "Colorized"/"Black-and-White" rows are enabled, and the pop-up rebuilds
    /// its NSMenu only when the items it is handed differ from the last.
    private static let digitalVersionItemsColor = makeDigitalVersionItems(colorAllowed: true)
    private static let digitalVersionItemsNoColor = makeDigitalVersionItems(colorAllowed: false)
    private static func digitalVersionItems(colorAllowed: Bool) -> [SheetPopUpButton<String>.Item] {
        colorAllowed ? digitalVersionItemsColor : digitalVersionItemsNoColor
    }
    private static func makeDigitalVersionItems(colorAllowed: Bool) -> [SheetPopUpButton<String>.Item] {
        ViewingVersion.allCases.map { version in
            .option(tag: version.rawValue,
                    title: version.displayName.isEmpty ? "Select Version…" : version.displayName,
                    isEnabled: !(version == .colorized && !colorAllowed)
                        && !(version == .blackAndWhite && colorAllowed))
        }
    }

    // The per-field pluralization table and the top-aligned label helper that
    // used it are gone: both moved into `FilmSheetListRow`, which now owns
    // the label as well as the list. Keeping them here meant this body read every
    // array's `count` to build the labels, which put all eleven of them in this
    // view's observation set — so committing one entry invalidated the whole tab.
    //
    // The bound rows above the lists sit inside `ObservationBoundary` (30_20) for the same
    // reason: a `$viewModel.field` binding created in this body subscribes it to `field`, so a
    // Sort Name keystroke, or a Color toggle, re-ran the whole tab — eleven list rows and
    // all — measured by the `filmsheet-perf` harness scenario.

    // MARK: - Label helpers
    // Encapsulates the fixed-width, left-aligned, single-line label pattern used by
    // every HStack row. Returning `some View` from a @ViewBuilder avoids constructing
    // the full modifier chain at every call site in body. Mirrors FSTabDetailsView.
    @ViewBuilder
    private func label(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: Self.labelWidth)
    }

    // `scrollAnchor(_:)` likewise moved into `FilmSheetListRow`, which is
    // the only thing that ever published one.

    var body: some View {
        let _ = FilmSheetBodyProbe.hit("metadata")
        // Local shadows of the static layout constants — gives every downstream
        // call site in this property unqualified access without explicit Self.
        // qualification, at zero runtime cost (no allocation, no capture).
        let pickerWidth = Self.pickerWidth
        let colSpacing: CGFloat = 16
        let rowSpacing: CGFloat = 10

        // Both multiline fields are three lines tall. Resolved once here rather
        // than at four separate call sites (two frames, two stand-in heights),
        // which also guarantees a field and its deferred stand-in cannot be given
        // different numbers. The measurement behind it is memoized per line count
        // — see FixedHeightScrollingTextView.fixedHeight(lineCount:) — so this is
        // a dictionary read after the first evaluation of any tab that uses it.
        let textFieldHeight = FixedHeightScrollingTextView.fixedHeight(lineCount: 3)

        // MARK: Build waves
        //
        // Every scroll-view-backed field on this tab carries a `renderWave` /
        // `wave`, and they are assigned in document order. Wave 0 is built with
        // the tab's first frame; each subsequent wave lands one display frame
        // later. See `DeferredFieldContent` (30_20_FSControlHelpers.swift) for why.
        //
        // Where the line is drawn, and why it is drawn conservatively: the sheet
        // is 600pt square, leaving this tab a viewport on the order of 460pt. The
        // fixed rows above the first list — Sort Name, a divider, and the four
        // picker/stepper rows — take roughly 210pt of it, so the first list
        // begins near y=210.
        //
        // The fold then MOVES WITH THE CONTENT, which is what decides the wave 0
        // count. In the common case only Encoding Tools and Cast are on screen.
        // But a list's height is `ListRowMetrics.listHeight(rowCount:)` over its
        // entries plus the add row, so an empty list still collapses to a single
        // row — and with every list above it empty, Executive Producers rises to
        // roughly y=450 and its top edge enters the viewport. Wave 0 therefore
        // covers the first FIVE lists: the count that is still correct in that
        // worst case, so nothing the user can see is ever deferred, in any
        // combination of contents.
        //
        // Screenwriters and everything below it cannot reach the viewport under
        // any combination, since each of the five lists above contributes at
        // least one row plus the list's own padding. Those seven fields are split
        // across three later waves rather than deferred as one block, so the run
        // loop gets a turn between groups and the main thread is never held for
        // the whole remainder at once.
        //
        // The iTunes Comments row is conditional (see its own note below), so
        // wave 3 holds either two fields or one. That does not disturb the
        // reasoning above: a row can only ever be REMOVED from the tab, which
        // moves the fields after it UP, and the only field after it is Tags —
        // already the last row on the tab and hundreds of points below the fold
        // with every list above it collapsed. Nothing can be promoted into view
        // by its absence.

        // VStack of HStack rows replaces Grid/GridRow. Both column widths are fixed
        // constants (labelWidth and .infinity), so Grid's two-pass column-resolution
        // sweep was doing zero useful negotiation work — confirming values it was
        // already given on every sheet open. VStack/HStack produces pixel-identical
        // output with one fewer layout container per row and no column pass.
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Sort Name
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Sort Name:")
                    TextField("Sort Name", text: $viewModel.sortName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()
                .padding(.vertical, 6)

            // Digital Source
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Digital Source:")
                    HStack(spacing: 0) {
                        // AppKit pop-ups, as every menu picker in the sheet is — see
                        // SheetPopUpButton (30_20).
                        SheetMenuPicker(selection: $viewModel.digitalSource,
                                        items: Self.digitalSourceItems, width: pickerWidth)
                        Spacer().frame(width: 27)
                        // AppKit checkboxes, so they are stops in the sheet's Tab traversal —
                        // see SheetCheckbox (30_20).
                        SheetCheckbox(isOn: $viewModel.isRemastered)
                        Spacer().frame(width: Preferences.spacingAfterCheckbox)
                        Text("Remastered Version")
                    }
                }
            }
            // Version / Subtitles
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Version / Subtitles:")
                    HStack(spacing: 8) {
                        // Options come from ViewingVersion so this menu and the release card's
                        // "Included Versions" menu cannot drift apart. See ViewingVersion.selectable.
                        //
                        // "Colorized" and "Black-and-White" are the two options this menu qualifies
                        // against the Color checkbox below: a colorized copy is by definition a
                        // color copy, and a black-and-white one is by definition not, so each is
                        // disabled while the checkbox already contradicts it. Disabled rather than
                        // hidden so the option stays visible and its precondition discoverable, and
                        // an already-stored contradictory value keeps displaying rather than
                        // vanishing from the menu. The release card has no Color flag to qualify
                        // against, so the rule is local to this menu. Selecting either option itself
                        // locks the Color checkbox to the matching value (see digitalVersion's
                        // didSet) rather than leaving the pair inconsistent until the row above
                        // re-evaluates on the next render.
                        SheetMenuPicker(selection: $viewModel.digitalVersion,
                                        items: Self.digitalVersionItems(colorAllowed: viewModel.color),
                                        width: pickerWidth)
                        SheetMenuPicker(selection: $viewModel.subtitles,
                                        items: Self.subtitleItems, width: pickerWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Asp. Ratio / Frames
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Asp. Ratio / Frames:")
                    HStack(spacing: 8) {
                        SheetMenuPicker(selection: $viewModel.aspectRatio,
                                        items: Self.aspectRatioItems, width: pickerWidth)
                        SheetMenuPicker(selection: $viewModel.frameRate,
                                        items: Self.frameRateItems, width: pickerWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // HandBrake RF Value / Color
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("HandBrake RF Value:")
                    HStack(spacing: 0) {
                        HBRFValueStepper(value: $viewModel.libraryHBRFValue)
                        Spacer().frame(width: Preferences.spacingBeforeCheckbox)
                        // Locked (and disabled) to the matching value while "Colorized" or
                        // "Black-and-White" is the selected version — see digitalVersion's
                        // didSet and isColorLocked's doc comment.
                        SheetCheckbox(isOn: $viewModel.color)
                            .disabled(viewModel.isColorLocked)
                        Spacer().frame(width: Preferences.spacingAfterCheckbox)
                        Text("Color")
                    }
                }
            }
            // Encoding Tools — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.encodingTool,
                                   singularLabel: "Encoding Tool:",
                                   pluralLabel: "Encoding Tools:",
                                   itemLabel: "Encoding Tool",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 0)

            Divider()
                .padding(.vertical, 6)

            // Cast — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.cast,
                                   singularLabel: "Cast:",
                                   pluralLabel: "Cast:",
                                   itemLabel: "Cast Member",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 0)
            // Directors — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.directors,
                                   singularLabel: "Director:",
                                   pluralLabel: "Directors:",
                                   itemLabel: "Director",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 0)
            // Producers — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.producers,
                                   singularLabel: "Producer:",
                                   pluralLabel: "Producers:",
                                   itemLabel: "Producer",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 0)
            // Executive Producers — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.executiveProducers,
                                   singularLabel: "Executive Producer:",
                                   pluralLabel: "Executive Producers:",
                                   itemLabel: "Executive Producer",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 0)
            // Screenwriters — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.screenwriters,
                                   singularLabel: "Screenwriter:",
                                   pluralLabel: "Screenwriters:",
                                   itemLabel: "Screenwriter",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 1)
            // Composers — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.composer,
                                   singularLabel: "Composer:",
                                   pluralLabel: "Composers:",
                                   itemLabel: "Composer",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 1)
            // Studio — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.studio,
                                   singularLabel: "Studio:",
                                   pluralLabel: "Studios:",
                                   itemLabel: "Studio",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 1)

            Divider()
                .padding(.vertical, 6)

            // Alternate Titles — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.alternateTitle,
                                   singularLabel: "Alternate Title:",
                                   pluralLabel: "Alternate Titles:",
                                   itemLabel: "Alternate Title",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 2)
            // Notes — top-aligned; label offset matches FixedHeightScrollingTextView inset.
            //
            // Deferred on the same terms as the lists above: this field is an
            // NSTextView inside an NSScrollView, it sits far below the fold on a
            // 600pt sheet, and it was previously built before the tab's first
            // frame was shown. `textFieldHeight` is the exact height the real
            // control takes, so the stand-in reserves the same space and the swap
            // moves nothing.
            HStack(alignment: .top, spacing: colSpacing) {
                label("Notes:")
                    .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                DeferredFieldContent(wave: 2, placeholderHeight: textFieldHeight) {
                    FixedHeightScrollingTextView(text: $viewModel.notes, placeholder: "Notes")
                        .frame(height: textFieldHeight)
                }
            }
            // iTunes Comments — top-aligned; label offset matches
            // FixedHeightScrollingTextView inset.
            //
            // Shown only for a film that actually carries imported comments. The
            // condition is `FSTabMetadata.displaysComments`, a flag fixed at load
            // time rather than a live read of the string; see that property for
            // why, including what a live condition would do to this body's
            // observation set.
            //
            // Yielding no subview at all — rather than a hidden or zero-height
            // one — is what makes the enclosing VStack skip the row's `rowSpacing`
            // along with the row, so the Tags list closes up against Notes with no
            // gap left where the field used to be.
            if viewModel.displaysComments {
                HStack(alignment: .top, spacing: colSpacing) {
                    label("iTunes Comments:")
                        .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                    DeferredFieldContent(wave: 3, placeholderHeight: textFieldHeight) {
                        FixedHeightScrollingTextView(text: $viewModel.comments, placeholder: "iTunes Comments")
                            .frame(height: textFieldHeight)
                    }
                }
            }
            // Tags — top-aligned
            FilmSheetListRow(model: viewModel,
                                   keyPath: \.tags,
                                   singularLabel: "Tags:",
                                   pluralLabel: "Tags:",
                                   itemLabel: "Tag",
                                   labelWidth: Self.labelWidth,
                                   columnSpacing: colSpacing,
                                   renderWave: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
