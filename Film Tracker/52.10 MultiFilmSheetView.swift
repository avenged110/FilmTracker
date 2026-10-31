// MARK: - MultiFilmSheetView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The MultiFilmSheet's view: a 600×600 sheet laid out as the FilmSheet is — title strip,
// tab bar (CustomTabs, 94_00), a fixed band saying what the sheet does, the active tab
// (Details: the fields, scrolling beneath the band; Selected Films: the films, in the list
// gallery's table), and the Cancel / Update gutter. The fields are the FilmSheet's own
// controls (FSSharedFields, 30_25), each opening to what the films share.

import SwiftUI
import AppKit

// MARK: - Tabs

/// Declaration order is the tab strip's order, and the Option-number shortcuts'
/// (KeyboardManager.handleSheetTabNavigation).
enum MultiFilmTab: String, CaseIterable, Identifiable, CustomTab {
    case details = "Details"
    case films = "Selected Films"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var iconName: String {
        switch self {
        case .details: return "square.text.square"
        case .films: return "film.stack"
        }
    }
}

// MARK: - MultiFilmSheetView

struct MultiFilmSheetView: View {
    @Bindable var owner: MultiFilmSheet

    /// The sheet's own window, for scoping the Tab monitor to it.
    @State private var window: NSWindow?
    @State private var tabMonitor: Any?

    static let labelWidth = Preferences.filmSheetLabelWidth
    static let pickerWidth = Preferences.standardPickerWidth
    static let colSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    /// The fields' side margin — the FilmSheet tabs'.
    static let sideMargin: CGFloat = 26
    /// The change marker's slot at the end of every row, kept whether or not the marker
    /// shows so nothing moves when it appears: the Details tab's Name row's help button
    /// slot (22 pt, 6 pt from the field).
    static let markerSlot: CGFloat = 22
    static let markerSpacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            Text(owner.windowTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            // As the FilmSheet's tab header is placed (FilmSheetView).
            CustomTabHeader(
                selectedTab: owner.selectedTab,
                enabled: true,
                showIcons: true,
                onTabSelect: { owner.selectedTab = $0 }
            )
            .padding(.horizontal, 4)
            .padding(.top, -1)
            .padding(.bottom, 1)
            .background(Color(nsColor: .windowBackgroundColor))
            .focusEffectDisabled()
            .overlay(Divider(), alignment: .bottom)
            .zIndex(1)

            MultiFilmHeader()
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
                .zIndex(1)

            MultiFilmTabContent(owner: owner,
                                selectedTab: owner.selectedTab,
                                appearedTabs: owner.appearedTabs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            MultiFilmButtonBar(owner: owner)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor(window: $window))
        .frame(width: Preferences.sheetSize, height: Preferences.sheetSize)
        .onAppear(perform: installTabMonitor)
        .onDisappear(perform: removeTabMonitor)
    }

    // MARK: Tab
    //
    // The FilmSheet's Tab rule (FilmSheetView.installTabMonitor): Tab and Shift-Tab walk the
    // sheet's controls in reading order through FilmSheetKeyLoop, since SwiftUI's own key
    // view chain skips the AppKit controls the fields are made of. The walk skips the hidden
    // tab (it is drawn at zero alpha, FilmSheetKeyLoop's hidden-tab test). Scoped to this
    // sheet's window, and left alone while a menu tracks or a popover (the Tags editor's)
    // is up.
    private func installTabMonitor() {
        let tracking = FilmSheetKeyLoop.MenuTrackingState.shared
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [window] event in
            guard event.keyCode == 48, event.normalizedModifiers.isSubset(of: [.shift]),
                  !tracking.isActive,
                  let sheetWindow = window, let key = NSApp.keyWindow,
                  key === sheetWindow, event.window === key,
                  !(key.childWindows ?? []).contains(where: \.isVisible) else { return event }
            let forward = !event.normalizedModifiers.contains(.shift)
            return FilmSheetKeyLoop.shared.advance(inWindow: key, forward: forward) ? nil : event
        }
    }

    private func removeTabMonitor() {
        if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
        tabMonitor = nil
    }
}

#if DEBUG
extension MultiFilmSheetView {
    /// The Details tab's fields at their full height, for the `bulk-edit-shots` harness
    /// scenario (DHBulkEdit), which renders what the sheet's scroll view would clip.
    static func fieldsForHarness(_ owner: MultiFilmSheet) -> some View {
        MultiFilmFields(owner: owner)
            .padding(.horizontal, sideMargin)
            .padding(.vertical, 20)
    }
}
#endif

// MARK: - Header

/// The fixed band under the tab bar, on both tabs: what the sheet does. Inset as the
/// fields are, with an "info" badge beside the text (IndicatorBadge, the reorderable lists' info
/// glyph).
private struct MultiFilmHeader: View {
    static let description = "You are editing data for all of the selected films. Anything changed here will overwrite their existing values, which may differ from one another, with the exception of the \u{201C}Tags\u{201D} field, whose changes are simply appended."

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // A badge, not a control: the app's IndicatorBadge, with the circle family's
            // drop shadow so it matches the sheet's circular buttons.
            IndicatorBadge(color: Color.gray.opacity(0.5), diameter: 18,
                           circleShadow: (opacity: 0.35, radius: 1.5, offsetY: 1)) {
                Image(systemName: "info")
                    .font(.system(size: 10, weight: .bold))
                    .offset(ListCircleButtonStyle.infoGlyphOffset)
            }
            .accessibilityHidden(true)
            Text(Self.description)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MultiFilmSheetView.sideMargin)
        .padding(.vertical, 12)
    }
}

// MARK: - Tab Content

/// The two tabs, each built on its first visit and then kept, hidden, as the FilmSheet's
/// are (FilmSheetTabContent.tabLayer, whose notes explain each layer of the hiding). Reads
/// nothing from `owner` itself, so editing a field never re-evaluates this view.
private struct MultiFilmTabContent: View {
    let owner: MultiFilmSheet
    let selectedTab: MultiFilmTab
    let appearedTabs: Set<MultiFilmTab>

    var body: some View {
        ZStack {
            tabLayer(.details) {
                // The focus sink comes first, so AppKit's automatic first responder lands on
                // it rather than on the first field (FilmSheetFocusSink). Return is passed on
                // here, as on the FilmSheet's Details tab.
                VStack(spacing: 0) {
                    FilmSheetFocusSink(swallowReturn: false, reclaimWhenActive: selectedTab == .details)
                        .frame(height: 0)
                        .clipped()
                    ScrollView(.vertical) {
                        MultiFilmFields(owner: owner)
                            .padding(.horizontal, MultiFilmSheetView.sideMargin)
                            .padding(.vertical, 20)
                    }
                }
            }
            tabLayer(.films) {
                VStack(spacing: 0) {
                    FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: selectedTab == .films)
                        .frame(height: 0)
                        .clipped()
                    // Read-only, as the Saved Search builder's results are.
                    UpNextResultsTable(films: owner.films)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .sheetBoxChrome(fill: Color(nsColor: NSColor.alternatingContentBackgroundColors[0]))
                        .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabLayer<C: View>(_ tab: MultiFilmTab, @ViewBuilder content: () -> C) -> some View {
        let active = selectedTab == tab
        if appearedTabs.contains(tab) || active {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .compositingGroup()
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .overlay(TabEventShield(isShielded: !active))
                .zIndex(active ? 1 : 0)
        } else {
            Color.clear
        }
    }
}

// MARK: - Change Marker

/// Marks a field the edit will write, at the end of its row; clicking it leaves the field
/// unchanged again. One of the sheet's circular buttons (ListCircleButton), in the accent
/// color the family uses for "active".
private struct ChangeMarker: View {
    let isSet: Bool
    let revert: () -> Void

    var body: some View {
        ZStack {
            if isSet {
                ListCircleButton(
                    systemImage: "arrow.uturn.backward",
                    fill: .accentColor,
                    diameter: 18,
                    glyphSize: 9,
                    help: "This field will be changed for every film. Click to leave it unchanged.",
                    glyphOffset: ListCircleButtonStyle.plusGlyphOffset,
                    action: revert)
                    .focusable(false)
                    .transition(.opacity)
            }
        }
        .frame(width: MultiFilmSheetView.markerSlot, height: MultiFilmSheetView.markerSlot)
    }
}

private extension View {
    /// Gives a row its change-marker slot at the trailing end. `top` places the marker for
    /// a top-aligned row (on its first line); nil centers it on a one-line row.
    ///
    /// The marker is an overlay in the reserved margin, not a sibling of the row: as a
    /// sibling its 22 pt slot set the height of every shorter row (the checkboxes'), which
    /// spread them further apart than the FilmSheet's.
    func changeMarker(_ isSet: Bool, top: CGFloat? = nil, revert: @escaping () -> Void) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, MultiFilmSheetView.markerSlot + MultiFilmSheetView.markerSpacing)
            .overlay(alignment: top == nil ? .trailing : .topTrailing) {
                ChangeMarker(isSet: isSet, revert: revert)
                    .offset(y: top ?? 0)
            }
            .animation(.easeInOut(duration: 0.15), value: isSet)
    }
}

@MainActor
private func fieldLabel(_ text: String) -> FilmSheetFieldLabel {
    FilmSheetFieldLabel(text, width: MultiFilmSheetView.labelWidth)
}

/// The marker's top for a row whose first line is a control `height` tall.
@MainActor
private func markerTop(centeredOn height: CGFloat, at y: CGFloat = 0) -> CGFloat {
    y + (height - MultiFilmSheetView.markerSlot) / 2
}

// MARK: - Fields

/// The rows, in the FilmSheet's order: Genre / Rating, the Queue block, List Membership,
/// the flags and sorting, Notes and Tags. Each row reads only its own field (see
/// MultiFilmSheet).
private struct MultiFilmFields: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let colSpacing = MultiFilmSheetView.colSpacing
        let rowSpacing = MultiFilmSheetView.rowSpacing
        VStack(alignment: .leading, spacing: rowSpacing) {
            GenreRatingRow(owner: owner)

            Divider().padding(.vertical, 6)

            QueueRow(owner: owner)
            if owner.upNextBlocked {
                HStack(alignment: .top, spacing: colSpacing) {
                    fieldLabel("")
                    note(MultiFilmSheet.upNextBlockedMessage(incoming: owner.upNextIncoming,
                                                             vacancies: owner.upNextVacancies))
                }
                .changeMarker(false) { }
                // 4 pt under the picker, as the FilmSheet's note sits.
                .padding(.top, -(rowSpacing - 4))
            }
            AutoAddRow(owner: owner)

            Divider().padding(.vertical, 6)

            ObservationBoundary {
                let shown = owner.shared.userListIDs.shown(owner.userListIDs)
                HStack(alignment: .center, spacing: colSpacing) {
                    fieldLabel("List Membership:")
                    ListMembershipMenu(
                        selectedListIDs: Binding(
                            get: { shown ?? [] },
                            set: { owner.assign(\.userListIDs, $0, shared: owner.shared.userListIDs) }),
                        availableLists: owner.availableLists,
                        isUnset: shown == nil)
                    .frame(width: MultiFilmSheetView.pickerWidth)
                }
                .changeMarker(owner.userListIDs.isSet) { owner.userListIDs = .unchanged }
            }

            Divider().padding(.vertical, 6)

            CheckboxRow(owner: owner, title: "Watched:", field: \.watched, shared: owner.shared.watched)
            CheckboxRow(owner: owner, title: "Edited:", field: \.edited, shared: owner.shared.edited)
            HallOfFameRow(owner: owner)
            if Preferences.showInfoComplete {
                CheckboxRow(owner: owner, title: "Complete Data:", field: \.infoComplete,
                            shared: owner.shared.infoComplete)
            }
            SpecialSortingRow(owner: owner)
            RotationRow(owner: owner)

            Divider().padding(.vertical, 6)

            NotesRow(owner: owner)
            FilmSheetListRow(model: owner,
                             keyPath: \.tags,
                             singularLabel: "Tags:",
                             pluralLabel: "Tags:",
                             itemLabel: "Tag",
                             labelWidth: MultiFilmSheetView.labelWidth,
                             columnSpacing: colSpacing)
                .changeMarker(!owner.edit.appendedTags.isEmpty,
                              top: markerTop(centeredOn: 15, at: ReorderableStringList.labelTopOffset)) {
                    owner.tags = []
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(AppEventBus.shared.listEvents) { event in
            switch event {
            case .deleted(let listID):
                // Through assign, so a choice left equal to the films' own lists reads
                // unchanged again.
                if case .set(var chosen) = owner.userListIDs, chosen.remove(listID) != nil {
                    owner.assign(\.userListIDs, chosen, shared: owner.shared.userListIDs)
                }
                owner.refreshAvailableLists()
            case .created, .updated:
                owner.refreshAvailableLists()
            default: break
            }
        }
    }
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Rows

/// Genre and MPAA rating: the FilmSheet's two pop-ups, whose own "Select Genre…" /
/// "Select MPAA Rating…" rows clear the value. Over a mix they show those rows, unchanged.
private struct GenreRatingRow: View {
    @Bindable var owner: MultiFilmSheet

    private static let genreItems: [SheetPopUpButton<String>.Item] =
        FSTabDetails.genreOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select Genre…" : $0) }
    private static let ratingItems: [SheetPopUpButton<String>.Item] =
        FSTabDetails.ratingOptions.map { .option(tag: $0, title: $0.isEmpty ? "Select MPAA Rating…" : $0) }

    var body: some View {
        HStack(alignment: .center, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Genre / Rating:")
            HStack(spacing: 8) {
                SheetMenuPicker(selection: Binding(
                                    get: { owner.shared.genre.shown(owner.genre) ?? "" },
                                    set: { owner.assign(\.genre, $0, shared: owner.shared.genre) }),
                                items: Self.genreItems, width: MultiFilmSheetView.pickerWidth)
                SheetMenuPicker(selection: Binding(
                                    get: { owner.shared.rating.shown(owner.rating) ?? "" },
                                    set: { owner.assign(\.rating, $0, shared: owner.shared.rating) }),
                                items: Self.ratingItems, width: MultiFilmSheetView.pickerWidth)
            }
        }
        .changeMarker(owner.genre.isSet || owner.rating.isSet) {
            owner.genre = .unchanged
            owner.rating = .unchanged
        }
    }
}

/// One flag: a checkbox showing what the films share, or mixed ("–") when they differ.
private struct CheckboxRow: View {
    let owner: MultiFilmSheet
    let title: String
    let field: ReferenceWritableKeyPath<MultiFilmSheet, BulkField<Bool>>
    let shared: BulkSharedValue<Bool>

    var body: some View {
        let value = owner[keyPath: field]
        HStack(alignment: .center, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel(title)
            MixedStateCheckbox(state: shared.shown(value)) {
                owner.clickCheckbox(field, shared: shared)
            }
        }
        .changeMarker(value.isSet) { owner[keyPath: field] = .unchanged }
    }
}

/// Queue Membership, with the FilmSheet's special-sorting confirmation and its "Up Next"
/// full fallback alert.
private struct QueueRow: View {
    @Bindable var owner: MultiFilmSheet
    @AppStorage(preference: Preferences.confirmFilmQueueAddKey) private var confirmFilmQueueAdd: Bool

    @State private var pendingSection: FilmQueueSection?
    @State private var confirmMessage = ""
    @State private var showConfirm = false
    @State private var showUpNextFull = false

    /// The picker's value: the edit's section, else the films' shared one, else no segment.
    private var selection: Binding<BulkField<FilmQueueSection?>> {
        Binding(
            get: {
                if owner.queueSection.isSet { return owner.queueSection }
                if case .same(let section) = owner.shared.queueSection { return .set(section) }
                return .unchanged
            },
            set: { newValue in
                guard case .set(let section) = newValue,
                      owner.shared.queueSection.field(for: section).isSet else {
                    // Back to where every film already is.
                    owner.queueSection = .unchanged
                    return
                }
                // Fallback only: a full "Up Next" disables its segment from the first frame.
                // Deferred, as every alert raised from a control's action is (FilmQueueRow).
                if section == .upNext,
                   FilmQueue.upNextOverflow(adding: Set(owner.filmIDs), coordinator: owner.coordinator) > 0 {
                    DispatchQueue.main.async { showUpNextFull = true }
                    return
                }
                if let section, confirmFilmQueueAdd {
                    let (adding, flagged) = owner.flaggedFilmsNewlyQueued(in: section)
                    if !flagged.isEmpty {
                        let message = flagged.count == 1 && adding == 1
                            ? FilmQueue.addConfirmationMessage(flaggedWith: flagged[0])
                            : FilmQueue.addConfirmationMessage(adding: adding, flagged: flagged.count)
                        DispatchQueue.main.async {
                            pendingSection = section
                            confirmMessage = message
                            showConfirm = true
                        }
                        return
                    }
                }
                owner.queueSection = newValue
            })
    }

    var body: some View {
        HStack(alignment: .center, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Queue Membership:")
            FilmQueuePicker(selection: selection, tag: { .set($0) },
                            upNextDisabled: owner.upNextBlocked)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .changeMarker(owner.queueSection.isSet) { owner.queueSection = .unchanged }
        .alert("Add to Queue", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) { pendingSection = nil }
            Button("Add Anyway") {
                if let pendingSection { owner.queueSection = .set(pendingSection) }
                pendingSection = nil
            }
        } message: {
            Text(confirmMessage)
        }
        .alert(FilmQueue.upNextFullTitle, isPresented: $showUpNextFull) {
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(FilmQueue.upNextFullDropMessage(Set(owner.filmIDs), coordinator: owner.coordinator))
        }
    }
}

/// "Add to [section] Queue when up for rotation": a mixed checkbox when some films queue
/// automatically and others do not; "Select…" when they queue to different sections.
private struct AutoAddRow: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let enabled = owner.autoAddShownEnabled
        let section = owner.autoAddShownSection
        AutoAddToQueueRow(
            isEnabled: .constant(enabled ?? false),
            section: Binding(
                get: { section ?? 0 },
                set: { owner.assign(\.autoAddToQueueOnRotation, $0, shared: owner.shared.autoAddToQueueOnRotation) }),
            isUnset: section == nil,
            description: "Automatically add each film to the selected Queue section when its rotation threshold is met and it becomes ready for viewing. If you select \"Up Next\" and this section is full at the time adding is triggered, the film will be added to the \"Soon\" Queue instead.",
            labelWidth: MultiFilmSheetView.labelWidth,
            columnSpacing: MultiFilmSheetView.colSpacing,
            checkboxIsMixed: enabled == nil,
            onCheckboxClick: { owner.clickAutoAddCheckbox() })
        // On the "Add to … Queue" line: 4 pt down, a pop-up tall.
        .changeMarker(owner.autoAddToQueueOnRotation.isSet,
                      top: markerTop(centeredOn: SheetPopUpButton<Int>.layoutHeight, at: 4)) {
            owner.autoAddToQueueOnRotation = .unchanged
        }
    }
}

/// Hall of Fame: when the films would not fit, the FilmSheet's help button, and the box can
/// only remove (MultiFilmSheet.clickHallOfFameCheckbox) — disabled outright when none of the
/// films is a member, leaving nothing to remove.
private struct HallOfFameRow: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let blocked = owner.hallOfFameBlocked
        let disabled = blocked && owner.shared.inHallOfFame == .same(false)
        HStack(alignment: .center, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Hall of Fame:")
                .foregroundStyle(disabled ? .secondary : .primary)
            MixedStateCheckbox(state: owner.shared.inHallOfFame.shown(owner.inHallOfFame)) {
                owner.clickHallOfFameCheckbox()
            }
            .disabled(disabled)
            .overlay(alignment: .trailing) {
                if blocked {
                    HelpPopoverButton(helpText: MultiFilmSheet.hallOfFameFullMessage(
                        incoming: owner.hallOfFameIncoming, vacancies: owner.hallOfFameVacancies))
                        .fixedSize()
                        .offset(x: 30)
                }
            }
        }
        .changeMarker(owner.inHallOfFame.isSet) { owner.inHallOfFame = .unchanged }
    }
}

private struct SpecialSortingRow: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let shown = owner.shared.specialSorting.shown(owner.specialSorting)
        HStack(alignment: .top, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Special Sorting:")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                SpecialSortingMenu(
                    selectedTags: Binding(get: { shown ?? [] },
                                          set: { owner.assign(\.specialSorting, $0, shared: owner.shared.specialSorting) }),
                    isUnset: shown == nil)
                    .frame(width: MultiFilmSheetView.pickerWidth, alignment: .leading)
                Text("Specially-sorted items will not appear in any automatically-generated\n\"Up for Rotation\" view, even if otherwise eligible to do so.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // On the menu, whose chrome is a 13 pt line with 4 pt above and below.
        .changeMarker(owner.specialSorting.isSet, top: markerTop(centeredOn: 24)) {
            owner.specialSorting = .unchanged
        }
    }
}

/// Rotation Threshold: disabled at 60 while every film will be blacklisted, as the
/// FilmSheet's picker is for a blacklisted film; a note says when some films keep theirs.
private struct RotationRow: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let locked = owner.rotationLocked
        let keeping = owner.filmsKeepingBlacklistThreshold
        HStack(alignment: keeping > 0 ? .top : .center, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Rotation Threshold:")
                .foregroundStyle(locked ? .secondary : .primary)
                .padding(.top, keeping > 0 ? 2 : 0)
            VStack(alignment: .leading, spacing: 4) {
                if locked {
                    RotationThresholdPicker(override: .constant(BulkFilmEdit.blacklistedThreshold))
                        .disabled(true)
                } else {
                    let baseline = owner.rotationBaseline
                    let shown: Int?? = {
                        if case .set(let value) = owner.rotationThresholdOverride { return .some(value) }
                        if case .same(let value) = baseline { return .some(value) }
                        return nil
                    }()
                    RotationThresholdPicker(
                        override: Binding(
                            get: { shown ?? nil },
                            set: { owner.assign(\.rotationThresholdOverride, $0, shared: baseline) }),
                        isUnset: shown == nil)
                }
                if keeping > 0 {
                    let films = keeping == 1 ? "1 of the selected films is" : "\(keeping) of the selected films are"
                    note("\(films) blacklisted and will keep a threshold of \(RotationThresholdPicker.formatAsYears(BulkFilmEdit.blacklistedThreshold)).")
                }
            }
        }
        .changeMarker(owner.rotationThresholdOverride.isSet,
                      top: keeping > 0 ? markerTop(centeredOn: SheetPopUpButton<Int>.layoutHeight) : nil) {
            owner.rotationThresholdOverride = .unchanged
        }
    }
}

private struct NotesRow: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        let height = FixedHeightScrollingTextView.fixedHeight(lineCount: 3)
        HStack(alignment: .top, spacing: MultiFilmSheetView.colSpacing) {
            fieldLabel("Notes:")
                .padding(.top, FixedHeightScrollingTextView.labelTopOffset)
            FixedHeightScrollingTextView(text: $owner.notes, placeholder: "Notes")
                .frame(height: height)
        }
        // On the label's line: a 15 pt line at the label's offset.
        .changeMarker(owner.notesEdit.isSet,
                      top: markerTop(centeredOn: 15, at: FixedHeightScrollingTextView.labelTopOffset)) {
            owner.revertNotes()
        }
    }
}

// MARK: - Button Bar

private struct MultiFilmButtonBar: View {
    @Bindable var owner: MultiFilmSheet

    var body: some View {
        HStack(spacing: 12) {
            Button { owner.cancel() } label: {
                Text("Cancel").padding(4).font(.system(size: 12))
            }
            .keyboardShortcut(.cancelAction)
            .disabled(owner.isConfirming)
            .focusable(false)

            Spacer()

            Text(owner.gutterNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(owner.gutterNote)

            Button { owner.confirm() } label: {
                Text(owner.confirmButtonTitle).padding(4).font(.system(size: 12))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!owner.canConfirm)
            .focusable(false)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .alert(Self.title(of: owner.pendingAlert),
               isPresented: Binding(get: { owner.pendingAlert != nil },
                                    set: { if !$0 { owner.pendingAlert = nil } }),
               presenting: owner.pendingAlert) { alert in
            switch alert {
            case .replaceNotes:
                Button("Cancel", role: .cancel) { }
                Button("Replace Notes", role: .destructive) { owner.confirmNotesReplacement() }
            case .clearNotes:
                Button("Cancel", role: .cancel) { }
                Button("Clear Notes", role: .destructive) { owner.confirmNotesReplacement() }
            case .upNextFull, .hallOfFameFull:
                Button("OK") { }
                    .keyboardShortcut(.defaultAction)
            }
        } message: { alert in
            Text(Self.message(of: alert))
        }
    }

    private static func title(of alert: MultiFilmSheet.ConfirmAlert?) -> String {
        switch alert {
        case .upNextFull: return FilmQueue.upNextFullTitle
        case .hallOfFameFull: return "Hall of Fame Full"
        case .replaceNotes: return "Replace Notes?"
        case .clearNotes: return "Clear Notes?"
        case nil: return ""
        }
    }

    private static func message(of alert: MultiFilmSheet.ConfirmAlert) -> String {
        switch alert {
        case .upNextFull(let message), .hallOfFameFull(let message):
            return message
        case .replaceNotes(let count):
            let films = count == 1
                ? "1 of the selected films has notes of its own"
                : "\(count) of the selected films have notes of their own"
            return "\(films), which will be replaced. This can\u{2019}t be undone."
        case .clearNotes(let count):
            let films = count == 1 ? "1 selected film" : "all \(count) selected films"
            return "The notes of \(films) will be cleared. This can\u{2019}t be undone."
        }
    }
}
