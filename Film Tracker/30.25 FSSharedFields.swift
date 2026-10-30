// MARK: - FSSharedFields.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Field controls the FilmSheet's Details tab and the MultiFilmSheet both show: the Queue
// Membership picker, the automatic-queueing row, the List Membership and Special Sorting
// menus, and the Rotation Threshold picker. Moved here from DetailsView (31.10) unchanged,
// except that each can also show a blank "nothing chosen" state, which only the
// MultiFilmSheet asks for. Also the mixed-state checkbox the MultiFilmSheet's flags use.

import SwiftUI

// MARK: - Film Queue Picker
/// Segmented picker with four equal-width segments — "None", "Up Next", "Soon", "Later" —
/// bound to a film's Film Queue section. An AppKit segmented control, as the sheet's other
/// segmented pickers are — see SheetSegmentedControl (30_20).
///
/// `tag` maps each segment to the binding's value: the FilmSheet binds the section itself
/// ("None" is nil); the MultiFilmSheet binds a BulkField, whose `.unchanged` is no segment's
/// tag and so shows no segment selected.
struct FilmQueuePicker<Tag: Hashable>: View {
    @Binding var selection: Tag
    let tag: (FilmQueueSection?) -> Tag
    /// Dims the "Up Next" segment: the Queue has no room for the film(s).
    var upNextDisabled = false

    private var segments: [SheetSegmentedControl<Tag>.Segment] {
        [.init(tag(nil), "None")]
            + FilmQueueSection.allCases.map {
                .init(tag($0), $0.displayName, isEnabled: !(upNextDisabled && $0 == .upNext))
            }
    }

    var body: some View {
        SheetSegmentedControl(selection: $selection, segments: segments)
    }
}

extension FilmQueuePicker where Tag == FilmQueueSection? {
    init(selection: Binding<FilmQueueSection?>, upNextDisabled: Bool = false) {
        self.init(selection: selection, tag: { $0 }, upNextDisabled: upNextDisabled)
    }
}

// MARK: - Auto-Add to Queue Row
/// The "Add to [section] Queue when up for rotation" checkbox row and its description.
///
/// Mirrors the Toggle + inline Picker composition used for the equivalent "Add dragged
/// films to the … section of the Queue" and "Making changes to …" rows in
/// GeneralSettingsView (STabGeneral.swift). Row title is intentionally empty; the checkbox
/// itself carries the row's meaning.
struct AutoAddToQueueRow: View {
    @Binding var isEnabled: Bool
    @Binding var section: Int
    /// No section chosen: the menu shows "Select…" (MultiFilmSheet, before a change).
    var isUnset = false
    let description: String
    var labelWidth: CGFloat = Preferences.filmSheetLabelWidth
    var columnSpacing: CGFloat = 16
    /// The checkbox shows the mixed state (MultiFilmSheet: some films queue automatically,
    /// some do not). Only read when `onCheckboxClick` is set.
    var checkboxIsMixed = false
    /// Set, the checkbox is a MixedStateCheckbox and clicks on it (and on its two text runs)
    /// come here instead of toggling `isEnabled`.
    var onCheckboxClick: (() -> Void)? = nil

    private func toggle() {
        if let onCheckboxClick { onCheckboxClick() } else { isEnabled.toggle() }
    }

    private static let sectionItems: [SheetPopUpButton<Int>.Item] = [
        .option(tag: 0, title: "\"Up Next\""),
        .option(tag: 1, title: "\"Soon\""),
        .option(tag: 2, title: "\"Later\""),
    ]
    /// The hidden "Select…" row's tag; never a section.
    private static let unsetTag = -1
    private static let unsetItems: [SheetPopUpButton<Int>.Item] =
        [.placeholder(tag: unsetTag, title: "Select…")] + sectionItems

    var body: some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            FilmSheetFieldLabel("", width: labelWidth)
                .padding(.top, 2)
            // A checkbox beside its label rather than a Toggle wrapping it, so the box
            // is a stop in the sheet's Tab traversal (SheetCheckbox, 30_20). The two
            // text runs still toggle it on click, as a Toggle's label would.
            // The checkbox is centered on the "Add to … Queue" line through the
            // rotationLine guide, rather than placed by a top padding that drifted out of
            // line with the menu beside it.
            HStack(alignment: .rotationLine, spacing: 4) {
                Group {
                    if let onCheckboxClick {
                        MixedStateCheckbox(state: checkboxIsMixed ? nil : isEnabled, onClick: onCheckboxClick)
                    } else {
                        SheetCheckbox(isOn: $isEnabled)
                    }
                }
                .alignmentGuide(.rotationLine) { $0[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Add to")
                            .onTapGesture { toggle() }
                        // While unset the menu shows the hidden "Select…" row, and choosing a
                        // section still writes it (a constant binding would drop the choice).
                        SheetMenuPicker(selection: Binding(
                                            get: { isUnset ? Self.unsetTag : section },
                                            set: { if $0 != Self.unsetTag { section = $0 } }),
                                        items: isUnset ? Self.unsetItems : Self.sectionItems,
                                        width: 110)
                            .disabled(!isEnabled)
                        Text("Queue when up for rotation")
                            .onTapGesture { toggle() }
                    }
                    .alignmentGuide(.rotationLine) { $0[VerticalAlignment.center] }
                    .padding(.top, 4)
                    // Intentionally ommitted the 2 point vertical padding reduction seen
                    // with other checkbox + Picker rows elsewhere in the codebase as this
                    // unexpectedly causes unnaturally thin margins here.
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, -2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Mixed-State Checkbox
/// A checkbox that can also show the mixed state (a dash), for a flag the selected films
/// do not share: `state` nil is mixed. SheetCheckbox's AppKit button, as every checkbox in
/// the sheets is, with `allowsMixedState` on.
///
/// A click is reported rather than applied, because what follows mixed is the caller's
/// rule (BulkFilmEdit.checkboxClick), not AppKit's own on → off → mixed cycle. The state
/// AppKit's click leaves is put back to `state` straight after, in case the caller's rule
/// lands on the same value and so causes no update.
struct MixedStateCheckbox: NSViewRepresentable {
    let state: Bool?
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
                              action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClick = onClick
        coordinator.state = Self.stateValue(state)
        let enabled = context.environment.isEnabled
        button.isEnabled = enabled
        button.refusesFirstResponder = !enabled
        if button.state != coordinator.state { button.state = coordinator.state }
    }

    static func stateValue(_ state: Bool?) -> NSControl.StateValue {
        switch state {
        case true?: return .on
        case false?: return .off
        case nil: return .mixed
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onClick: () -> Void = {}
        var state: NSControl.StateValue = .mixed

        @objc func clicked(_ sender: NSButton) {
            onClick()
            DispatchQueue.main.async { [weak self, weak sender] in
                guard let self, let sender, sender.state != self.state else { return }
                sender.state = self.state
            }
        }
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

/// The two menus' label while nothing has been chosen (MultiFilmSheet, before a change).
private let unsetMenuTitle = "Select…"

// MARK: - List Membership Menu
struct ListMembershipMenu: View {
    @Binding var selectedListIDs: Set<UUID>
    let availableLists: [MemoryList]
    /// Nothing chosen yet: the label reads "Select…" rather than "None".
    var isUnset = false

    private var displayText: String {
        if isUnset { return unsetMenuTitle }
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
                .foregroundStyle(isUnset || selectedListIDs.isEmpty ? .secondary : .primary)
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
struct SpecialSortingMenu: View {
    @Binding var selectedTags: Set<String>
    /// Nothing chosen yet: the label reads "Select…" rather than "None".
    var isUnset = false

    private var displayText: String {
        if isUnset { return unsetMenuTitle }
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
                .foregroundStyle(isUnset || selectedTags.isEmpty ? .secondary : .primary)
                .menuFieldChrome()
        }
    }
}

// MARK: - Rotation Threshold Picker
struct RotationThresholdPicker: View {
    @Binding var override: Int?
    /// Nothing chosen yet: the button shows a hidden "Select…" row, as the Saved Search
    /// builder's menus do, since the menu itself has no such option.
    var isUnset = false

    private static let pickerWidth = Preferences.standardPickerWidth
    /// The hidden "Select…" row's tag; never a threshold (0 is "Use Default").
    private static let unsetTag = -1

    /// Converts a month count to a years display string.
    /// Static: pure function with no instance state — eliminates the implicit
    /// `self` capture that an instance method would incur at every call site.
    static func formatAsYears(_ months: Int) -> String {
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
    private static func items(defaultThreshold: Int, isUnset: Bool) -> [SheetPopUpButton<Int>.Item] {
        (isUnset ? [.placeholder(tag: unsetTag, title: unsetMenuTitle)] : [])
            + [.option(tag: 0, title: "Use Default (\(formatAsYears(defaultThreshold)))"), .separator]
            + optionItems
    }

    var body: some View {
        let pickerWidth = Self.pickerWidth
        let isUnset = isUnset
        SheetMenuPicker(selection: Binding(
            get: { isUnset ? Self.unsetTag : (override ?? 0) },
            set: { newValue in
                guard newValue != Self.unsetTag else { return }
                override = newValue == 0 ? nil : newValue
            }
        ), items: Self.items(defaultThreshold: Preferences.defaultRotationThreshold, isUnset: isUnset),
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
