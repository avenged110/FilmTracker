// MARK: - DetailsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI view layer for the "Details" tab of FilmSheet — layout, controls,
// and private helper views.

import SwiftUI

// MARK: - Developer Override Flag
// `Preferences.overrideAutoExpandingTablePref` controls whether the
// `Preferences.autoExpandRightSidebarTables` preference is enforced for the Past Viewing
// Dates table in `FSTabDetailsView` (its `ViewingDatesRow`). The switch lives in
// Preferences.swift with the app's other testing switches; this is the file that reads it.
//
// - `false` (default): Behavior is unchanged — the preference governs whether the table
//   auto-expands when the view loads. `ViewingDatesTable` reads the preference directly
//   and expands automatically when it is enabled.
//
// - `true`: The preference is ignored by this file. `ViewingDatesRow` always passes a
//   collapsed binding to `ViewingDatesTable`, so the table loads collapsed regardless of
//   the preference value. The user can still expand the table manually after load.


// MARK: - FSTabDetailsView
//
// MARK: Observation boundaries
//
// This body reads almost nothing of the view model itself. Every bound row is built inside
// an `ObservationBoundary` (30_20) or a named row view below, because a `$viewModel.field`
// binding created HERE subscribes this body to `field`, and @Observable would then re-run
// it — every row's construction — on each change to any bound field. Measured by the
// `filmsheet-perf` harness scenario: a Name keystroke, a Release Date step and an Edited
// toggle each re-ran it, and opening the sheet ran it three times rather than once (the
// deferred `availableLists` write and the viewing-dates anchor's first measurement were the
// other two). Now each of those re-evaluates the one row that shows it.
//
// What the body still reads: `upNextWasFullAtOpen` (fixed for the sheet's life), the
// `manualExtQuery` preference, and `Preferences.showInfoComplete` — the three conditions that
// decide which rows exist at all.
struct FSTabDetailsView: View {
    @Bindable var viewModel: FSTabDetails
    @AppStorage(preference: Preferences.manualExtQueryKey) private var manualExtQuery: Bool

    /// Proxy that drives programmatic scrolling through the AppKit NSScrollView.
    /// FilmSheetTabContent creates one FilmSheetScrollProxy for the Details tab and
    /// passes it to both FSTabDetailsView (here) and FilmSheetScrollView (which wires
    /// the implementation). Handed on to the Viewing Events row, the only consumer.
    var scrollProxy: FilmSheetScrollProxy?

    // Layout constants are static: they are process-wide constants drawn from
    // Preferences and never differ between instances. Keeping them static removes
    // them from per-instance allocation and eliminates implicit self captures in
    // every closure inside body that previously referenced them. Internal to the file so
    // the named rows below share them.
    fileprivate static let pickerWidth          = Preferences.standardPickerWidth
    fileprivate static let labelWidth           = Preferences.filmSheetLabelWidth
    fileprivate static let colSpacing: CGFloat  = 16
    fileprivate static let rowSpacing: CGFloat  = 10
    // Vertical offset that lines a top-leading label up with the first line of
    // the content beside it.
    fileprivate static let topAlignmentOffset: CGFloat = 2

    // The menu pickers' rows, built once from the option tables in FSTabDetails. The empty
    // option is each menu's placeholder row.
    private static let genreItems: [SheetPopUpButton<String>.Item] =
        FSTabDetails.genreOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select Genre…" : $0) }
    private static let ratingItems: [SheetPopUpButton<String>.Item] =
        FSTabDetails.ratingOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select MPAA Rating…" : $0) }
    private static let autoAddToQueueSectionItems: [SheetPopUpButton<Int>.Item] = [
        .option(tag: 0, title: "\"Up Next\""),
        .option(tag: 1, title: "\"Soon\""),
        .option(tag: 2, title: "\"Later\""),
    ]

    // MARK: - Auto-Add to Queue on Rotation
    // Binding for the row's checkbox. Checking it enables the feature and defaults the
    // Picker to "Up Next" (0) if no section was previously selected; unchecking it clears
    // the value back to nil, matching the RotationThresholdPicker's "tag 0 represents nil"
    // pattern used elsewhere in this file for the same nil-means-unset convention.
    // Read only from inside the auto-add row's ObservationBoundary.
    private var autoAddToQueueEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoAddToQueueOnRotation != nil },
            set: { isEnabled in
                viewModel.autoAddToQueueOnRotation = isEnabled ? (viewModel.autoAddToQueueOnRotation ?? 0) : nil
            }
        )
    }

    // Binding for the row's Picker. Only meaningful while the checkbox above is checked;
    // defaults to 0 ("Up Next") when the backing value is nil so the Picker always has a
    // valid selection even while its control is disabled.
    private var autoAddToQueueSectionBinding: Binding<Int> {
        Binding(
            get: { viewModel.autoAddToQueueOnRotation ?? 0 },
            set: { viewModel.autoAddToQueueOnRotation = $0 }
        )
    }

    // MARK: - Label helpers
    // Encapsulates the four-modifier label-column pattern used by every HStack row.
    // Returning `some View` from a @ViewBuilder avoids constructing the
    // full modifier chain at every call site in body. Mirrors FSTabMetadataView.
    @ViewBuilder
    fileprivate static func label(_ text: String) -> some View {
        FilmSheetFieldLabel(text, width: labelWidth)
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        Self.label(text)
    }

    var body: some View {
        let _ = FilmSheetBodyProbe.hit("details")
        // Local shadows of the static layout constants — gives every downstream
        // call site in this property unqualified access without explicit Self.
        // qualification, at zero runtime cost (no allocation, no capture).
        let pickerWidth           = Self.pickerWidth
        let colSpacing            = Self.colSpacing
        let rowSpacing            = Self.rowSpacing

        // Height of the Synopsis field, resolved once so the control and its
        // deferred stand-in below cannot be given different numbers. The
        // measurement behind it is memoized per line count — see
        // FixedHeightScrollingTextView.fixedHeight(lineCount:).
        let synopsisHeight = FixedHeightScrollingTextView.fixedHeight(lineCount: 5)

        // MARK: Build waves
        //
        // Same scheme as the Metadata and Notes tabs, but with far less to apply
        // it to: this tab's only AppKit scroll-view stacks are `ViewingDatesTable`
        // and the Synopsis text view, and everything else is an ordinary control.
        // See `DeferredFieldContent` (30_20_FSControlHelpers.swift).
        //
        // `ViewingDatesTable` is NOT deferred, for two independent reasons. It
        // begins around y=334 against a viewport of roughly 460pt, so it is
        // always partly on screen; and it is the row that publishes the
        // `viewingDatesAnchorID` offset that `.openViewingDatesAddPopover`
        // scrolls to, which a stand-in could not measure.
        //
        // The Synopsis is deferred. Counting the fixed rows above it — Name,
        // Release Date, User Rating, Genre/Rating, a divider, Queue Membership,
        // the auto-add block, a divider, Duration — puts the viewing-dates table
        // at about y=334, and that table's own collapsed floor is 167pt (a header
        // plus 6.5 rows; expanding it only makes this larger). With the List
        // Membership row after it, the Synopsis cannot begin higher than about
        // y=547, comfortably clear of the fold in every configuration.
        //
        // Nothing below the Synopsis is deferred: the remaining rows are toggles,
        // menus, and short fields, none of which carries a scroll view, and
        // several of which are sized by wrapped description text rather than by a
        // constant this could reserve without risking a layout shift.

        // VStack of HStack rows replaces Grid/GridRow. Both column widths are fixed
        // constants (labelWidth and .infinity), so Grid's two-pass column-resolution
        // sweep was doing zero useful negotiation work — confirming values it was
        // already given on every sheet open. VStack/HStack produces pixel-identical
        // output with one fewer layout container per row and no column pass.
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Name
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Name:")
                    HStack(spacing: 6) {
                        TextField("Film Title", text: $viewModel.name)
                            .textFieldStyle(.roundedBorder)
                        HelpPopoverButton(helpText: "When the gallery is sorted by title, any value in the Metadata tab's \"Sort Name\" field takes precedence over this field's value.")
                    }
                }
            }
            // Release Date
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Release Date:")
                    CustomDateStepper(date: $viewModel.releaseDate, hasValue: $viewModel.hasReleaseDate) {
                        viewModel.hasReleaseDate = false
                    }
                }
            }
            // User Rating
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("User Rating:")
                    RatingStepper(value: $viewModel.userRating, in: 0...10)
                }
            }
            // Genre / Rating
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Genre / Rating:")
                    HStack(spacing: 8) {
                        // AppKit pop-ups, as every menu picker in the sheet is — see
                        // SheetPopUpButton (30_20).
                        SheetMenuPicker(selection: $viewModel.genre,
                                        items: Self.genreItems, width: pickerWidth)
                        SheetMenuPicker(selection: $viewModel.rating,
                                        items: Self.ratingItems, width: pickerWidth)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
                .padding(.vertical, 6)

            // Film Queue — a segmented picker placing the film in one of the three
            // internal queue sections, or "None" (not queued). Committed on save, mirroring
            // how List Membership below is reconciled when the sheet is saved.
            FilmQueueRow(viewModel: viewModel)
            if viewModel.upNextWasFullAtOpen {
                HStack(alignment: .top, spacing: colSpacing) {
                    label("")
                    Text("Your \"Up Next\" Queue contains the maximum of eight films. You must remove one or more films from it before you can add another.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 4 pt under the picker, as the tab's other descriptions sit under their
                // controls, rather than a full row gap.
                .padding(.top, -(rowSpacing - 4))
            }
            // Auto-Add to Queue on Rotation — mirrors the Toggle + inline Picker composition
            // used for the equivalent "Add dragged films to the … section of the Queue" and
            // "Making changes to …" rows in GeneralSettingsView (STabGeneral.swift). Row title
            // is intentionally empty; the checkbox itself carries the row's meaning. A
            // description is shown underneath, matching the styling used for the Special
            // Sorting and External IDs description text elsewhere in this tab.
            ObservationBoundary {
                HStack(alignment: .top, spacing: colSpacing) {
                    label("")
                        .padding(.top, 2)
                    // A checkbox beside its label rather than a Toggle wrapping it, so the box
                    // is a stop in the sheet's Tab traversal (SheetCheckbox, 30_20). The two
                    // text runs still toggle it on click, as a Toggle's label would.
                    // The checkbox is centered on the "Add to … Queue" line through the
                    // rotationLine guide, rather than placed by a top padding that drifted out of
                    // line with the menu beside it.
                    HStack(alignment: .rotationLine, spacing: 4) {
                        SheetCheckbox(isOn: autoAddToQueueEnabledBinding)
                            .alignmentGuide(.rotationLine) { $0[VerticalAlignment.center] }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Add to")
                                    .onTapGesture { autoAddToQueueEnabledBinding.wrappedValue.toggle() }
                                SheetMenuPicker(selection: autoAddToQueueSectionBinding,
                                                items: Self.autoAddToQueueSectionItems, width: 110)
                                    .disabled(!autoAddToQueueEnabledBinding.wrappedValue)
                                Text("Queue when up for rotation")
                                    .onTapGesture { autoAddToQueueEnabledBinding.wrappedValue.toggle() }
                            }
                            .alignmentGuide(.rotationLine) { $0[VerticalAlignment.center] }
                            .padding(.top, 4)
                            // Intentionally ommitted the 2 point vertical padding reduction seen
                            // with other checkbox + Picker rows elsewhere in the codebase as this
                            // unexpectedly causes unnaturally thin margins here.
                            Text("Automatically add this film to the selected Queue section when its rotation threshold is met and it becomes ready for viewing. If you select \"Up Next\" and this section is full at the time adding is triggered, the film will be added to the \"Soon\" Queue instead.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, -2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
                .padding(.vertical, 6)

            // Duration — label and content change based on the "Edited" checkbox state.
            // When edited == false: single DurationStepper for the canonical duration.
            // When edited == true: both pickers are shown separated by "/" and the row
            // title widens to "Duration / Edited:" to describe both columns.
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label(viewModel.edited ? "Duration / Edited:" : "Duration:")
                    HStack(spacing: 6) {
                        DurationStepper(
                            hours: $viewModel.durationHours,
                            minutes: $viewModel.durationMinutes,
                            hasValue: $viewModel.hasDuration
                        ) {
                            viewModel.durationHours   = 0
                            viewModel.durationMinutes = 0
                            viewModel.hasDuration     = false
                        }
                        if viewModel.edited {
                            Text("/")
                                .foregroundStyle(.primary)
                            DurationStepper(
                                hours: $viewModel.editedDurationHours,
                                minutes: $viewModel.editedDurationMinutes,
                                hasValue: $viewModel.hasEditedDuration
                            ) {
                                viewModel.editedDurationHours   = 0
                                viewModel.editedDurationMinutes = 0
                                viewModel.hasEditedDuration     = false
                            }
                        }
                    }
                }
            }
            // Viewing Events — top-aligned; reports its y-offset for programmatic scrolling.
            ViewingDatesRow(viewModel: viewModel, scrollProxy: scrollProxy)
            // List Membership
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("List Membership:")
                    ListMembershipMenu(
                        selectedListIDs: $viewModel.selectedListIDs,
                        availableLists: viewModel.availableLists
                    )
                    .frame(width: pickerWidth)
                }
            }
            // Synopsis — top-aligned; label offset matches FixedHeightScrollingTextView inset.
            // Fixed 5-line height, scrolls on overflow: .frame(height:) drives the
            // NSTextView height from the SwiftUI side rather than the view reporting an
            // intrinsic size of its own. The binding is created inside DeferredFieldContent's
            // body, which is already an observation boundary.
            HStack(alignment: .top, spacing: colSpacing) {
                label("Synopsis:")
                    .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
                DeferredFieldContent(wave: 1, placeholderHeight: synopsisHeight) {
                    FixedHeightScrollingTextView(
                        text: $viewModel.descriptionText,
                        placeholder: "Synopsis"
                    )
                    .frame(height: synopsisHeight)
                }
            }

            Divider()
                .padding(.vertical, 6)

            // Watched
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Watched:")
                    // AppKit checkboxes rather than SwiftUI Toggles, here and below, so they are
                    // stops in the sheet's Tab traversal — see SheetCheckbox (30_20).
                    SheetCheckbox(isOn: $viewModel.watched)
                }
            }
            // Edited
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Edited:")
                    SheetCheckbox(isOn: $viewModel.edited)
                }
            }
            // Hall of Fame
            ObservationBoundary {
                HStack(alignment: .center, spacing: colSpacing) {
                    // The lockout applies only to films that were NOT Hall of Fame members when
                    // the sheet opened. A film that was already a member can always be freely
                    // toggled: unchecking it would reduce the list to 199 on commit, and
                    // re-checking it just restores the original state — neither action adds a
                    // new slot. Locking the checkbox the moment the user unchecks an existing
                    // member (before any commit) was wrong because hallOfFameIsFull still
                    // reflects the live count, which hasn't changed yet.
                    let hofDisabled = viewModel.hallOfFameIsFull
                        && !viewModel.inHallOfFame
                        && !viewModel.wasOriginallyInHallOfFame
                    label("Hall of Fame:")
                        .foregroundStyle(hofDisabled ? .secondary : .primary)
                    SheetCheckbox(isOn: $viewModel.inHallOfFame)
                        .disabled(hofDisabled)
                        .overlay(alignment: .trailing) {
                            if hofDisabled {
                                HelpPopoverButton(helpText: "The Hall of Fame may only contain at most 200 films. You must first remove an existing entry before you can add more.")
                                    .fixedSize()
                                    .offset(x: 30)
                            }
                        }
                }
            }
            // Complete Data (conditional)
            if Preferences.showInfoComplete {
                ObservationBoundary {
                    HStack(alignment: .center, spacing: colSpacing) {
                        label("Complete Data:")
                        SheetCheckbox(isOn: $viewModel.infoComplete)
                    }
                }
            }
            // Special Sorting — top-aligned (content includes a multi-line description Text)
            SpecialSortingRow(viewModel: viewModel)
            // Rotation Threshold
            ObservationBoundary {
                let isBlacklisted = viewModel.specialSorting.contains(FilmSpecialSorting.blacklisted)
                HStack(alignment: .center, spacing: colSpacing) {
                    label("Rotation Threshold:")
                        .foregroundStyle(isBlacklisted ? .secondary : .primary)
                    RotationThresholdPicker(override: $viewModel.rotationThresholdOverride)
                        .disabled(isBlacklisted)
                }
            }
            // External IDs (conditional)
            if manualExtQuery {
                ObservationBoundary {
                    HStack(alignment: .top, spacing: colSpacing) {
                        label("External IDs:")
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                // The view model guarantees exactly two slots (IMDb at [0], Blu-ray
                                // at [1]) — see loadExistingDetails — so no count guard is needed.
                                ExternalIDField(
                                    text: $viewModel.externalIdentifiers[0],
                                    site: .imdb
                                )
                                .frame(width: 120, height: 22)
                                ExternalIDField(
                                    text: $viewModel.externalIdentifiers[1],
                                    site: .bluray
                                )
                                .frame(width: 120, height: 22)
                            }
                            Text("Add the unique numerical identifiers for IMDb.com and Blu-ray.com to link directly to this film using the Web Query button in the contextual sidebar.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The `.task` that used to activate the scroll anchor is gone with the
        // deferral it performed — see ViewingDatesRow.anchorOffset. Nothing else on this
        // view needed it.
        .onReceive(AppEventBus.shared.listEvents) { event in
            switch event {
            case .deleted(let deletedListID):
                viewModel.selectedListIDs.remove(deletedListID)
                viewModel.refreshAvailableLists()
            case .created, .updated:
                viewModel.refreshAvailableLists()
            default: break
            }
        }
    }

}

// MARK: - Film Queue Row
/// The Queue Membership row, with the confirmation and "Up Next" full alerts it raises.
/// Its own view so the selection, and the special-sorting set the confirmation consults,
/// are observed here rather than by the whole tab.
private struct FilmQueueRow: View {
    @Bindable var viewModel: FSTabDetails
    @AppStorage(preference: Preferences.confirmFilmQueueAddKey) private var confirmFilmQueueAdd: Bool

    // Backing state for the Film Queue confirmation alert. When the user selects a
    // non-"None" segment while the film carries a special sorting parameter (and the
    // confirmFilmQueueAdd preference is enabled), the selection is held here pending
    // confirmation rather than being applied to viewModel.selectedFilmQueueSection
    // immediately — see filmQueueSectionBinding below.
    @State private var showFilmQueueConfirmAlert = false
    @State private var pendingFilmQueueSection: FilmQueueSection?
    @State private var showUpNextFullAlert = false

    // MARK: - Film Queue Confirmation
    // Intercepts assignment to viewModel.selectedFilmQueueSection so that moving a film
    // INTO the queue (selecting "Up Next", "Soon", or "Later") while it carries a
    // special sorting parameter can be gated behind a confirmation alert. Moving OUT
    // of the queue (selecting "None") is never gated — only additions are confirmed.
    // The get always reflects the view model's committed value, so the segmented
    // Picker's highlighted segment does not visually change until the user confirms
    // (or is left unchanged entirely if they cancel).
    private var filmQueueSectionBinding: Binding<FilmQueueSection?> {
        Binding(
            get: { viewModel.selectedFilmQueueSection },
            set: { newValue in
                // "Up Next" holds at most eight films. Fallback only: a full "Up Next"
                // disables its segment before the sheet renders (upNextWasFullAtOpen), so
                // this alert should never be seen. Kept as a safety net. Deferred for the
                // same reason as the confirmation below.
                if newValue == .upNext, viewModel.upNextIsFull {
                    DispatchQueue.main.async { showUpNextFullAlert = true }
                    return
                }
                if newValue != nil,
                   !viewModel.specialSorting.isEmpty,
                   confirmFilmQueueAdd {
                    // Deferred via DispatchQueue.main.async: this setter executes inside
                    // the segmented control's action dispatch (AppKit's mouse-tracking
                    // context for the click on the segment). Flipping the presentation
                    // boolean synchronously here opens SwiftUI's alert transaction while
                    // that event handling is still on the stack, and Core Animation is
                    // denied the appear animation — the alert pops on screen fully
                    // formed. Main-queue blocks are drained only in common run-loop
                    // modes, so this block structurally cannot run until the control's
                    // event handling has fully unwound; the alert then presents on a
                    // clean main-thread turn. (Same mechanism as the LeftSidebar drop
                    // target's deferred confirmFilmQueueAddOnDrop event, and the same
                    // main.async-over-Task rationale documented in SelectionState:
                    // run-loop ordering plus QoS inheritance from the AppKit event.)
                    // Both state writes are grouped in the block so the pending value
                    // and the presentation flip land in the same SwiftUI update.
                    DispatchQueue.main.async {
                        pendingFilmQueueSection = newValue
                        showFilmQueueConfirmAlert = true
                    }
                } else {
                    viewModel.selectedFilmQueueSection = newValue
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: FSTabDetailsView.colSpacing) {
            FSTabDetailsView.label("Queue Membership:")
            FilmQueuePicker(selection: filmQueueSectionBinding,
                            upNextDisabled: viewModel.upNextWasFullAtOpen)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Add to Queue", isPresented: $showFilmQueueConfirmAlert) {
            Button("Cancel", role: .cancel) {
                pendingFilmQueueSection = nil
            }
            Button("Add Anyway") {
                viewModel.selectedFilmQueueSection = pendingFilmQueueSection
                pendingFilmQueueSection = nil
            }
        } message: {
            Text(FilmQueue.addConfirmationMessage(flaggedWith: viewModel.specialSorting))
        }
        .alert(FilmQueue.upNextFullTitle, isPresented: $showUpNextFullAlert) {
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(FilmQueue.upNextFullMessage(adding: 1, vacancies: 0))
        }
    }
}

// MARK: - Viewing Dates Row
/// The Viewing Events row: the table, the scroll anchor it publishes, and the shortcut that
/// scrolls to it and opens its add popover. Its own view so the table's binding, the release
/// date it floors entries at, and the anchor's measured offset are observed here — the
/// offset's first measurement used to re-run the whole tab body during the sheet's open.
private struct ViewingDatesRow: View {
    @Bindable var viewModel: FSTabDetails
    var scrollProxy: FilmSheetScrollProxy?

    @State private var isViewingDatesExpanded = false

    // Lifted popover trigger for the ViewingDatesTable "+" button.
    // Bumped by the onReceive handler for .openViewingDatesAddPopover; never reset — see
    // ViewingDatesTable.externalAddTrigger for why this is a monotonic token rather than a
    // flag the table had to lower from inside its own .onChange.
    @State private var triggerViewingDatesAddPopover: Int = 0

    // Anchor ID used for programmatic scroll targeting via FilmSheetScrollProxy.
    // Reported upward through ScrollAnchorPreferenceKey and resolved to a y-offset
    // by the Coordinator in FilmSheetScrollView.
    private static let viewingDatesAnchorID = "viewingDatesSection"

    // Measured y-offset of the Viewing Events row within the "filmSheetScrollContent"
    // coordinate space, published upward through ScrollAnchorPreferenceKey.
    //
    // Used to be a deferral flag gating a background `GeometryReader`, held out of
    // the first layout pass because the extra layout node competed with
    // CoreAnimation's sheet-presentation animation. Both are gone:
    // `onGeometryChange(for:of:action:)` (macOS 15) computes only the reduced value
    // and writes here solely when it changes, contributing no layout node ever —
    // the same first-party substitution made for `HelpPopoverButton`
    // (90_00_GlobalUtilities.swift) and the imports session card, and the
    // counterpart to `ScrollActivityObserver` in `ViewingDatesTable` and the
    // reorderable lists (those only need to know *that* a scroll happened; this
    // needs the position itself).
    //
    // `nil` until the first measurement lands — the row publishes no entry at all
    // rather than a placeholder zero, since a wrong anchor would scroll the clip
    // view to the top. In practice the action fires with the initial geometry as
    // the view first appears, well before the only consumer (the
    // .openViewingDatesAddPopover shortcut, reachable only once the sheet is
    // visible) can reach it.
    @State private var anchorOffset: CGFloat?

    /// The payload published through `ScrollAnchorPreferenceKey`. Written out as an
    /// explicitly typed computed property rather than inline in `body`: a closure body
    /// that opens with `[` is ambiguous with a capture list, and spelling the
    /// dictionary type here removes any inference work from the `body` type-check.
    private var anchorPreference: [String: CGFloat] {
        guard let anchorOffset else { return [:] }
        return [Self.viewingDatesAnchorID: anchorOffset]
    }

    var body: some View {
        HStack(alignment: .top, spacing: FSTabDetailsView.colSpacing) {
            // Variant with the top-alignment padding for rows that pair with
            // ViewingDatesTable. Uses .padding(.top:) rather than .offset(y:) — .offset
            // bypasses layout entirely and is semantically incorrect here; .padding participates
            // in layout and produces the same visual result without the misuse.
            FSTabDetailsView.label("Viewing Events:")
                .padding(.top, FSTabDetailsView.topAlignmentOffset)
            ViewingDatesTable(
                isTableExpanded: $isViewingDatesExpanded,
                calendarTableBinding: $viewModel.calendarTable,
                releaseDate: viewModel.hasReleaseDate ? viewModel.releaseDate : nil,
                externalAddTrigger: $triggerViewingDatesAddPopover,
                disableAutoExpand: Preferences.overrideAutoExpandingTablePref
            )
        }
        // Report this row's y-offset to FilmSheetScrollProxy via ScrollAnchorPreferenceKey.
        // Reads the row's frame relative to the "filmSheetScrollContent" coordinate space,
        // which is established by FilmSheetTabContent on the outermost content wrapper —
        // outside the .padding(26) — so the measured y-offset is a true document-relative
        // value aligned with what NSScrollView.contentView.scroll(to:) expects.
        //
        // The transform closure captures nothing — the coordinate-space name is a
        // literal — so it satisfies strict concurrency regardless of how the SDK
        // annotates it. The action runs on the main actor with the rest of the view.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named("filmSheetScrollContent")).minY
        } action: { newOffset in
            anchorOffset = newOffset
        }
        // Published separately from the measurement so the preference value is a
        // plain function of state: `.preference` performs no measurement of its own
        // and adds no layout node, and an unmeasured row contributes an empty
        // dictionary, which ScrollAnchorPreferenceKey's merge reduces away.
        .preference(
            key: ScrollAnchorPreferenceKey.self,
            value: anchorPreference
        )
        .padding(.bottom, 4)
        .onReceive(AppEventBus.shared.uiCommands) { command in
            guard case .openViewingDatesAddPopover = command else { return }
            // Scroll the NSScrollView to the viewing-dates anchor so the "+" button
            // is visible, then open the add popover. The Task hop defers the trigger
            // so the scroll settles first — matching the pattern used throughout the
            // codebase for deferred @MainActor state mutations.
            scrollProxy?.scroll(to: Self.viewingDatesAnchorID)
            Task { @MainActor in
                triggerViewingDatesAddPopover &+= 1
            }
        }
    }
}

// MARK: - Special Sorting Row
/// The Special Sorting menu and its description, with the blacklist cascade onto the
/// rotation threshold. Its own view so the tag set — and the stash the cascade keeps — are
/// observed and held here rather than by the whole tab.
private struct SpecialSortingRow: View {
    @Bindable var viewModel: FSTabDetails

    // The rotation threshold override as it stood immediately before the user
    // blacklisted the film, so un-blacklisting can hand it back rather than resetting the
    // field to "Use Default". See the onChange below for the full rationale. Two
    // properties rather than an `Int??`: the stashed value is itself legitimately nil
    // (meaning "Use Default"), so "nothing stashed" needs its own flag and cannot be
    // expressed by the value alone.
    //
    // @State survives for the life of the sheet: FilmSheetTabContent builds each tab once
    // and keeps it mounted (hidden) rather than destroying it, so switching tabs and
    // coming back does not drop the stash.
    @State private var thresholdBeforeBlacklist: Int?
    @State private var hasStashedThreshold = false

    var body: some View {
        HStack(alignment: .top, spacing: FSTabDetailsView.colSpacing) {
            FSTabDetailsView.label("Special Sorting:")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                SpecialSortingMenu(selectedTags: $viewModel.specialSorting)
                    .frame(width: FSTabDetailsView.pickerWidth, alignment: .leading)
                    // Blacklisting forces the rotation threshold to 60 and disables
                    // the picker; un-blacklisting hands the field back.
                    //
                    // What it hands back used to be unconditionally `nil` — "Use
                    // Default" — which discarded whatever override the user had
                    // deliberately set BEFORE blacklisting. Toggling Blacklisted on
                    // and straight back off was therefore not a round trip: it
                    // quietly reset a field the user never touched, on a control they
                    // could not even reach while it was disabled.
                    //
                    // The pre-blacklist value is stashed instead and restored on the
                    // way out. The picker is `.disabled` for the whole blacklisted
                    // interval (see the Rotation Threshold row), so the stashed
                    // value cannot go stale — there is no way to edit the field while
                    // it is held.
                    //
                    // A film that arrives ALREADY blacklisted has nothing stashed,
                    // since no transition occurred in this session; un-blacklisting it
                    // falls back to nil exactly as before. Only in-session transitions
                    // are reversible, which is the scope the stash can honestly cover.
                    .onChange(of: viewModel.specialSorting) { oldValue, newValue in
                        let isBlacklisted = newValue.contains(FilmSpecialSorting.blacklisted)
                        let wasBlacklisted = oldValue.contains(FilmSpecialSorting.blacklisted)
                        if isBlacklisted && !wasBlacklisted {
                            thresholdBeforeBlacklist = viewModel.rotationThresholdOverride
                            hasStashedThreshold = true
                            viewModel.rotationThresholdOverride = 60
                        } else if wasBlacklisted && !isBlacklisted {
                            viewModel.rotationThresholdOverride =
                                hasStashedThreshold ? thresholdBeforeBlacklist : nil
                            thresholdBeforeBlacklist = nil
                            hasStashedThreshold = false
                        }
                    }
                Text("Specially-sorted items will not appear in any automatically-generated\n\"Up for Rotation\" view, even if otherwise eligible to do so.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Film Queue Picker
/// Segmented picker with four equal-width segments — "None", "Up Next", "Soon", "Later" —
/// bound to the film's selected Film Queue section. "None" corresponds to a nil section
/// (the film is not queued). An AppKit segmented control, as the sheet's other segmented
/// pickers are — see SheetSegmentedControl (30_20).
private struct FilmQueuePicker: View {
    @Binding var selection: FilmQueueSection?
    /// Dims the "Up Next" segment: the Queue is full and this film isn't in it.
    var upNextDisabled = false

    private var segments: [SheetSegmentedControl<FilmQueueSection?>.Segment] {
        [.init(nil, "None")]
            + FilmQueueSection.allCases.map {
                .init(.some($0), $0.displayName, isEnabled: !(upNextDisabled && $0 == .upNext))
            }
    }

    var body: some View {
        SheetSegmentedControl(selection: $selection, segments: segments)
    }
}

// MARK: - Menu Field Chrome
/// The bordered, control-colored field the two mixed-selection menus below use as their
/// `Menu` label, so both read as the same kind of form field as the sheet's text inputs
/// rather than as a system pop-up button.
///
/// Factored out because `ListMembershipMenu` and `SpecialSortingMenu` are the same control
/// wearing different contents: they differ only in what their `displayText` says and in
/// which set they consult for the empty/secondary styling, both of which stay at the call
/// site. Keeping the chrome in one place is what stops the two from drifting apart
/// visually — they are two rows of the same form column on the Details tab, left-aligned
/// to the same label width, where a divergence in corner radius or padding would read as
/// one of them being a different kind of control.
private extension View {
    func menuFieldChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - List Membership Menu
private struct ListMembershipMenu: View {
    @Binding var selectedListIDs: Set<UUID>
    let availableLists: [MemoryList]

    private var displayText: String {
        let selectedCount = selectedListIDs.count
        if selectedCount == 0 {
            return "None"
        } else if selectedCount == 1 {
            if let listID = selectedListIDs.first,
               let list = availableLists.first(where: { $0.listID == listID }) {
                return truncateListName(list.listName)
            }
            // The selected list was deleted while the sheet was open. Show a count
            // instead of "None" so the user knows a membership is still pending
            // (it will be removed from selectedListIDs by the .deleted event handler,
            // but there is a brief window between the deletion and the UI refresh).
            return "1 selected"
        } else {
            return "Multiple"
        }
    }

    var body: some View {
        Menu {
            if availableLists.isEmpty {
                Text("No Lists Available")
                    .disabled(true)
            } else {
                ForEach(availableLists, id: \.listID) { list in
                    Toggle(isOn: Binding(
                        get: { selectedListIDs.contains(list.listID) },
                        set: { isSelected in
                            if isSelected {
                                selectedListIDs.insert(list.listID)
                            } else {
                                selectedListIDs.remove(list.listID)
                            }
                        }
                    )) {
                        Text(truncateListName(list.listName))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        } label: {
            Text(displayText)
                .foregroundStyle(selectedListIDs.isEmpty ? .secondary : .primary)
                .menuFieldChrome()
        }
    }
}

// MARK: - Special Sorting Menu
/// Menu-based mixed-selection control for the specialSorting tag set. "Waiting for
/// edit" and "Temporarily on hold" are independent Toggle rows — either, both, or
/// neither may be active. "Indefinitely on hold", "Ignore", and "Blacklisted" form a
/// mutually-exclusive group directly below a divider — selecting one clears the other
/// two in that group, exactly as GalleryFilterMenu's watched/color/purchase pairs do,
/// but the group coexists in the same menu with the independent pair above rather than
/// replacing it. A film can therefore carry at most three tags at once: both
/// independent options plus one member of the exclusive group.
private struct SpecialSortingMenu: View {
    @Binding var selectedTags: Set<String>

    private var displayText: String {
        let activeTags = FilmSpecialSorting.canonicalOrder.filter { selectedTags.contains($0) }
        if activeTags.isEmpty {
            return "None"
        } else if activeTags.count == 1 {
            return activeTags[0]
        } else {
            return "Multiple"
        }
    }

    private func toggleIndependent(_ option: String, isOn: Bool) {
        if isOn {
            selectedTags.insert(option)
        } else {
            selectedTags.remove(option)
        }
    }

    private func toggleExclusive(_ option: String, isOn: Bool) {
        // Mutate a local copy and commit it in a single write. Calling .remove()/.insert()
        // directly on `selectedTags` (a @Binding) would round-trip through its get-mutate-set
        // cycle on every call — up to three separate writes to viewModel.specialSorting for
        // one tap — firing checkForChanges() and onChange(of:) multiple times with transient
        // intermediate states. Batching avoids that, matching GalleryFilterMenu's pattern of
        // building a local Set and committing once.
        var updated = selectedTags
        if isOn {
            for sibling in FilmSpecialSorting.exclusiveOptions where sibling != option {
                updated.remove(sibling)
            }
            updated.insert(option)
        } else {
            updated.remove(option)
        }
        selectedTags = updated
    }

    var body: some View {
        Menu {
            ForEach(FilmSpecialSorting.independentOptions, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedTags.contains(option) },
                    set: { isOn in toggleIndependent(option, isOn: isOn) }
                )) {
                    Text(option)
                }
            }
            Divider()
            ForEach(FilmSpecialSorting.exclusiveOptions, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedTags.contains(option) },
                    set: { isOn in toggleExclusive(option, isOn: isOn) }
                )) {
                    Text(option)
                }
            }
        } label: {
            Text(displayText)
                .foregroundStyle(selectedTags.isEmpty ? .secondary : .primary)
                .menuFieldChrome()
        }
    }
}

// MARK: - Rotation Threshold Picker
private struct RotationThresholdPicker: View {
    @Binding var override: Int?

    private static let pickerWidth = Preferences.standardPickerWidth

    /// Converts a month count to a years display string.
    /// Static: pure function with no instance state — eliminates the implicit
    /// `self` capture that an instance method would incur at every call site.
    private static func formatAsYears(_ months: Int) -> String {
        let years = Double(months) / 12.0
        if years == 1.0 {
            return "1 year"
        } else if years.truncatingRemainder(dividingBy: 1.0) == 0 {
            return "\(Int(years)) years"
        } else {
            return "\(years) years"
        }
    }

    /// Every threshold option displayed as years. Built once: the options are a fixed table.
    private static let optionItems: [SheetPopUpButton<Int>.Item] =
        Preferences.rotationThresholdOptions.map { .option(tag: $0, title: formatAsYears($0)) }

    /// "Use Default" (tag 0 represents nil), a separator, then `optionItems`.
    ///
    /// Built per body rather than once, because the first row names the default threshold,
    /// which is a user setting (General settings). As a `static let` the title was fixed at
    /// whatever the default was the first time any FilmSheet opened, so changing the setting
    /// later left every subsequent sheet advertising the old value. Nine rows, and
    /// SheetPopUpButton rebuilds its NSMenu only when the rows actually differ.
    private static func items(defaultThreshold: Int) -> [SheetPopUpButton<Int>.Item] {
        [.option(tag: 0, title: "Use Default (\(formatAsYears(defaultThreshold)))"), .separator]
            + optionItems
    }

    var body: some View {
        let pickerWidth = Self.pickerWidth
        SheetMenuPicker(selection: Binding(
            get: { override ?? 0 },
            set: { newValue in
                override = newValue == 0 ? nil : newValue
            }
        ), items: Self.items(defaultThreshold: Preferences.defaultRotationThreshold),
           width: pickerWidth)
    }
}

// MARK: - Rotation Row Alignment
/// Centers the auto-add row's checkbox on its "Add to … Queue" line.
private extension VerticalAlignment {
    enum RotationLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let rotationLine = VerticalAlignment(RotationLine.self)
}
