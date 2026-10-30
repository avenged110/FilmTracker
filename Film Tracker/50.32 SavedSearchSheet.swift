// MARK: - SavedSearchSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The saved-search builder: a 600×600 sheet (the FilmSheet / Settings size) where a search
// is named and built from rules — field, operator, value — under "Match all / any", with
// the films it finds listed live below, in the list gallery's own table. Laid out as the
// "Up Next" slot sheet is: title strip, content bands, Cancel / primary gutter.

import SwiftUI
import AppKit

struct SavedSearchSheet: View, Loggable {
    nonisolated static let logTag = "[SavedSearchSheet]"

    enum Mode: Equatable, Sendable {
        /// A new saved search, starting from `query` — the search field's, or empty.
        case create(SavedSearchQuery)
        case edit(UUID)
        /// Update a saved search with the rules now in the search field (it was opened
        /// there with "Open in Search Field" and changed): the title bar's "Update Saved
        /// Search…". Saving also leaves search for the saved search's own view.
        case editFromField(UUID, SavedSearchQuery)
        case duplicate(UUID)
    }

    let mode: Mode
    let coordinator: DataCoordinator

    @Environment(SheetCoordinator.self) private var sheetCoordinator
    private var store: SavedSearchStore { .shared }

    @State private var name = ""
    /// Until the user types a name of their own, a new search's name follows its rules.
    @State private var nameEdited = false
    @State private var rules = RuleSet()
    @State private var originalName: String?
    @State private var originalQuery: SavedSearchQuery?
    /// The ID the search is checked as: an edited search's own, else a stand-in.
    @State private var candidateID = UUID()
    @State private var listChoices: [ListChoiceGroup] = []
    @State private var results: [FilmSnapshot] = []
    @State private var resultsReady = false
    /// The search needs review — it was stored with rules this version cannot read, which
    /// it shows without (SavedSearchStore.needsReview): the warning button beside Save,
    /// until its alert has been read in this sheet.
    @State private var showsDroppedRulesNotice = false
    @State private var showingDroppedRulesAlert = false
    /// The sheet's window while the alert closes, so the button leaves only once AppKit
    /// reports the alert gone from it (didEndSheetNotification).
    @State private var droppedRulesAlertWindow: ObjectIdentifier?

    private static let previewDelay: Duration = .milliseconds(150)

    /// What the live results depend on: the query the rules make, and whether every rule
    /// is complete. Keyed on this rather than the rules, so an edit that changes neither
    /// (a menu on an unfinished row, the and/or of a row under "Match all") does not run
    /// the library again.
    private struct PreviewKey: Hashable {
        let query: SavedSearchQuery
        let isComplete: Bool
    }

    var body: some View {
        // Once per pass: it builds the #list catalog and walks the references, and both
        // the note and Save read it.
        let problem = saveProblem
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            builder
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            resultsSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Button { sheetCoordinator.dismissSheet() } label: {
                    Text("Cancel").padding(4).font(.system(size: 12))
                }
                .keyboardShortcut(.cancelAction)
                .focusable(false)

                Spacer()

                if let (text, color) = gutterNote(problem) {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(text)
                }

                if showsDroppedRulesNotice {
                    // Styled as Save beside it; the glyph is ImportsView's failed-import
                    // notice: a white mark in a red triangle.
                    Button {
                        droppedRulesAlertWindow = NSApp.keyWindow.map(ObjectIdentifier.init)
                        showingDroppedRulesAlert = true
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .padding(4)
                            .font(.system(size: 12))
                    }
                    .focusable(false)
                    .help("Rules this version does not recognize were removed. Click for details.")
                    .transition(OpacityTransition().combined(with: ScaleTransition(0.5)))
                }

                Button { save() } label: {
                    Text(actionTitle).padding(4).font(.system(size: 12))
                }
                .keyboardShortcut(.defaultAction)
                .focusable(false)
                .disabled(problem != nil || isUnchanged)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: Preferences.sheetSize, height: Preferences.sheetSize)
        .onAppear(perform: prepare)
        .alert("Unrecognized Rules Removed", isPresented: $showingDroppedRulesAlert) {
            Button("OK") {
                // A backstop only: should AppKit not report the alert's end (below), the
                // button still leaves, a little after the alert has.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    hideDroppedRulesNotice()
                }
            }
        } message: {
            Text("This saved search contains rules, most likely from a backup made by a newer version of Film Tracker, that this version doesn\u{2019}t recognize, so they have been removed. Review its rules and save it to use it again.")
        }
        // The alert is a sheet on this sheet's window; its end, posted once the closing
        // animation is over, is the button's cue to leave.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
            guard let window = note.object as? NSWindow,
                  droppedRulesAlertWindow == ObjectIdentifier(window), !showingDroppedRulesAlert else { return }
            hideDroppedRulesNotice()
        }
        .task(id: PreviewKey(query: rules.query, isComplete: rules.problem == nil)) { await refreshResults() }
        .onChange(of: rules) { _, _ in
            if !nameEdited, case .create = mode { name = suggestedName }
        }
    }

    // MARK: Builder

    private var builder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Name:")
                    .font(.system(size: 12))
                TextField("Saved Search Name", text: Binding(
                    get: { name },
                    set: { newName in
                        // Only a real change counts: a write-back of the same text when
                        // the field ends editing must not stop the name following the
                        // rules. A name cleared to nothing follows them again from the
                        // next rule change.
                        guard newName != name else { return }
                        name = newName
                        nameEdited = !newName.trimmingCharacters(in: .whitespaces).isEmpty
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .centeredWithPopUps()
            }

            HStack(spacing: 6) {
                Text("Match films that meet")
                    .font(.system(size: 12))
                SheetMenuPicker(selection: $rules.mode,
                                items: RuleMatchMode.allCases.map { .option(tag: $0, title: $0.label) },
                                width: 220)
                Spacer()
                // The one add control, above the table's trailing edge, in the list
                // utilities' style (ReorderableStringList's "+"): rows carry only "−".
                ListCircleButton(
                    systemImage: "plus",
                    fill: Preferences.green,
                    diameter: ListRowMetrics.circleDiameter,
                    glyphSize: ListRowMetrics.plusGlyphSize,
                    // Not until the last rule is complete: a new row is no use beside an
                    // unfinished one.
                    isEnabled: rules.rules.last.map { $0.problem == nil } ?? true,
                    help: "Add a rule",
                    glyphOffset: ListCircleButtonStyle.plusGlyphOffset,
                    action: addRule)
                    .padding(.trailing, RuleRow.trailingInset)
            }

            rulesList
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The rows, scrolling once there are more than fit: about five show at once.
    private var rulesList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach($rules.rules) { $rule in
                    RuleRow(rule: $rule,
                            showsConjunction: rules.mode == .custom,
                            listChoices: listChoices,
                            canRemove: rules.rules.count > 1,
                            onRemove: { removeRule(rule.id) })
                }
            }
            .padding(8)
        }
        .frame(height: 172)
        .sheetBoxChrome(fill: Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query Results:")
                    .font(.system(size: 12))
                Spacer()
                if resultsReady, rules.problem == nil, !rules.query.isEmpty {
                    Text(results.count == 1 ? "1 film" : "\(results.count) films")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // One box whatever it holds, so the table and its placeholders occupy the same
            // filled shape.
            Group {
                if rules.query.isEmpty || rules.problem != nil {
                    placeholder("Configure rules above to see the live results here.")
                } else if resultsReady && results.isEmpty {
                    placeholder("No results.")
                } else {
                    // Read-only: nothing acts on a result here.
                    UpNextResultsTable(films: results)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheetBoxChrome(fill: Color(nsColor: NSColor.alternatingContentBackgroundColors[0]))
            // The rules table's inset, so the two boxes line up.
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Runs the rules once they hold still, in title order — the same engine the saved
    /// search's own view uses, so the preview is exactly what saving will show.
    private func refreshResults() async {
        let query = rules.query
        guard !query.isEmpty, rules.problem == nil else {
            results = []
            // Not ready: the placeholder covers this state, and leaving it (deleting the
            // incomplete rule, say) must wait for real results rather than flash
            // "No results." for the preview delay.
            resultsReady = false
            return
        }
        try? await Task.sleep(for: Self.previewDelay)
        guard !Task.isCancelled else { return }
        let ids = coordinator.filmIDs(matching: query)
        let ordered = MetadataCache.shared.sort(Array(ids), by: .title, direction: .ascending)
        results = ordered.compactMap { coordinator.getFilm($0) }
        resultsReady = true
    }

    // MARK: Validation

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Said beside Save, which it disables; nothing under the name field, so the sheet's
    /// contents never shift while typing.
    private var nameProblem: String? {
        switch SavedSearchName.problem(with: name, claims: coordinator.savedSearchNameClaims(excluding: candidateID)) {
        case nil: return nil
        case .empty: return "Enter a name."
        case .taken(let claim): return "This name is already taken by \(claim.kind.noun). Choose another."
        }
    }

    private var cycleProblem: String? {
        let query = rules.query
        // A cycle through this search leaves it by one of its own #list tokens.
        guard query.tokens.contains(where: { $0.field == .list }) else { return nil }
        let candidate = SavedSearch(id: candidateID, name: trimmedName, query: query, displayOrder: 0)
        guard let cycle = SavedSearchReferences.cycle(saving: candidate, among: store.searches,
                                                      otherNames: coordinator.savedSearchOtherListNames()) else { return nil }
        var names = Dictionary(uniqueKeysWithValues: store.searches.map { ($0.id, $0.name) })
        names[candidateID] = trimmedName
        return SavedSearchReferences.message(for: cycle, names: names)
    }

    /// Why Save is disabled, shown beside it; nil when it is enabled.
    private var saveProblem: String? {
        if let problem = rules.problem { return problem }
        if rules.query.isEmpty { return "Add a rule." }
        if let nameProblem { return nameProblem }
        if let cycleProblem { return cycleProblem }
        return nil
    }

    /// An edit that changes nothing leaves Save disabled, without a note saying so — an
    /// update from the field too, once its rules are back to what is saved. Not for a
    /// search that needs review: saving it as it stands is the review.
    private var isUnchanged: Bool {
        switch mode {
        case .edit(let id), .editFromField(let id, _):
            return trimmedName == originalName && rules.query == originalQuery && !store.needsReview(id)
        case .create, .duplicate: return false
        }
    }

    /// The one line beside Save: why it is disabled, or else what the rules do that is
    /// easy to miss. Here rather than under the rules, so the builder never changes height.
    private func gutterNote(_ saveProblem: String?) -> (String, Color)? {
        if let saveProblem { return saveProblem.isEmpty ? nil : (saveProblem, .secondary) }
        if rules.mode != .all, rules.rules.contains(where: { $0.op.isInverted }) {
            return ("Rules that exclude films (\u{201C}does not contain\u{201D}, \u{201C}is not\u{201D}\u{2026}) always apply.", .secondary)
        }
        return nil
    }

    // MARK: Actions

    private var title: String {
        switch mode {
        case .create: return "Create New Saved Search"
        case .edit: return "Edit Saved Search"
        case .editFromField: return "Update Saved Search"
        case .duplicate: return "Duplicate Saved Search"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .edit, .editFromField: return "Update"
        case .create, .duplicate: return "Save"
        }
    }

    /// Empty until the rules are complete: a half-built rule names nothing yet.
    private var suggestedName: String {
        rules.query.isEmpty || rules.problem != nil ? ""
            : SavedSearchName.suggestion(for: rules.query, claims: coordinator.savedSearchNameClaims(excluding: nil))
    }

    private func prepare() {
        switch mode {
        case .create(let query):
            rules = RuleSet(query: query)
            if rules.rules.isEmpty { rules.rules = [.blank()] }
            name = suggestedName
        case .edit(let id), .editFromField(let id, _):
            guard let search = store.search(id) else { return sheetCoordinator.dismissSheet() }
            candidateID = id
            // From the field, its rules; either way compared with what is saved.
            if case .editFromField(_, let query) = mode {
                rules = RuleSet(query: query)
            } else {
                rules = RuleSet(query: search.query)
            }
            name = search.name
            nameEdited = true
            originalName = search.name
            originalQuery = RuleSet(query: search.query).query
            showsDroppedRulesNotice = store.needsReview(id)
        case .duplicate(let id):
            guard let search = store.search(id) else { return sheetCoordinator.dismissSheet() }
            rules = RuleSet(query: search.query)
            name = SavedSearchName.duplicate(of: search.name, claims: coordinator.savedSearchNameClaims(excluding: nil))
            nameEdited = true
            // A copy of a search missing rules would be missing them too, unflagged.
            showsDroppedRulesNotice = store.needsReview(id)
        }
        // A search left with no rules (every stored one unreadable) starts as a new one does.
        if rules.rules.isEmpty { rules.rules = [.blank()] }
        listChoices = ListChoiceGroup.groups(coordinator.searchListCatalog(),
                                             excluding: store.search(candidateID)?.name)
    }

    /// The dropped-rules button leaves, once its alert has been read and has closed.
    private func hideDroppedRulesNotice() {
        guard showsDroppedRulesNotice, !showingDroppedRulesAlert else { return }
        droppedRulesAlertWindow = nil
        withAnimation(.easeOut(duration: 0.25)) { showsDroppedRulesNotice = false }
    }

    /// Appends a row with nothing chosen, keeping the last row's and/or.
    private func addRule() {
        rules.rules.append(.blank(conjunction: rules.rules.last?.conjunction ?? .and))
    }

    private func removeRule(_ id: UUID) {
        guard rules.rules.count > 1 else { return }
        // First, so a field still being edited in the row commits while its row exists:
        // after the removal its binding would address the next row, or none.
        RuleRow.endEditing()
        rules.rules.removeAll { $0.id == id }
    }

    private func save() {
        // Commits a field still being edited (and clamps a typed year) before the rules
        // are read: the button's click, or Return, would otherwise come first.
        RuleRow.endEditing()
        guard saveProblem == nil, !isUnchanged else { return }
        let query = rules.query
        switch mode {
        case .create:
            let search = store.create(name: trimmedName, query: query)
            if showOwnViewFromSearch(search.id) { return }
        case .duplicate:
            store.create(name: trimmedName, query: query)
        case .edit(let id):
            store.update(id, name: trimmedName, query: query)
        case .editFromField(let id, _):
            store.update(id, name: trimmedName, query: query)
            // To the saved search's view, now showing the change — not back to wherever
            // "Open in Search Field" was chosen from.
            if showOwnViewFromSearch(id) { return }
            SearchController.shared.clearSearch()
        }
        sheetCoordinator.dismissSheet()
    }

    /// Saved from the search results: goes to saved search `id`'s own view, as a click on
    /// its sidebar row would (leaving search clears the field, as any exit does). False,
    /// doing nothing, anywhere but the search view.
    private func showOwnViewFromSearch(_ id: UUID) -> Bool {
        guard let appState = AppDelegate.appState, appState.selectedSidebarItem == .libraryItem(.search) else { return false }
        sheetCoordinator.dismissSheet()
        appState.navigate(to: .savedSearch(id))
        return true
    }
}

// MARK: - List Choices

/// The #list targets a List rule's menu offers, grouped as the search suggestions group
/// them, the search being edited left out (a search cannot include itself).
struct ListChoiceGroup: Identifiable, Hashable {
    let title: String
    let names: [String]
    var id: String { title }

    static func groups(_ catalog: SearchListCatalog, excluding excluded: String?) -> [ListChoiceGroup] {
        let order: [(SearchListCatalog.Kind, String)] = [
            (.user, "Lists"), (.saved, "Saved Searches"), (.smart, "Smart Lists"),
            (.recents, "Recents"), (.report, "Reports")]
        return order.compactMap { kind, title in
            let names = catalog.entries.filter { $0.kind == kind && $0.name != excluded }.map(\.name)
            return names.isEmpty ? nil : ListChoiceGroup(title: title, names: names)
        }
    }
}

// MARK: - Rule Row

/// One rule: [and/or] [field] [operator] [value…] (−). Its menus are the FilmSheet's
/// SheetPopUpButton, as every menu picker in the sheets is.
private struct RuleRow: View {
    @Binding var rule: QueryRule
    let showsConjunction: Bool
    let listChoices: [ListChoiceGroup]
    let canRemove: Bool
    let onRemove: () -> Void

    /// The rules table's inner inset, which the "+" above the table repeats so it sits
    /// directly over the rows' "−" buttons.
    static let trailingInset: CGFloat = 8

    /// The field menu's groups, in the order the Search Guide presents them.
    private static let fieldGroups: [(String, [SearchField])] = [
        ("Title and Text:", [.title, .genre, .studio, .tags, .notes, .synopsis]),
        ("People:", [.crew, .cast, .directors, .producer, .executiveProducer, .screenwriter, .composer]),
        ("Numbers:", [.year, .duration, .rating]),
        ("Dates:", [.lastWatched, .dateAdded]),
        ("Library:", [.flags, .list, .releases, .rotationThreshold]),
    ]

    private static let fieldItems: [SheetPopUpButton<SearchField?>.Item] =
        [.placeholder(tag: nil, title: selectTitle)]
        + grouped(fieldGroups.map { ($0.0, $0.1.map { (tag: Optional($0), title: fieldLabel($0)) }) })

    /// The collapsed title of a menu with nothing chosen yet.
    private static let selectTitle = "Select\u{2026}"

    private static let otherTag = "\u{1}other"

    var body: some View {
        HStack(spacing: 6) {
            if showsConjunction {
                SheetMenuPicker(selection: $rule.conjunction,
                                items: [.option(tag: .and, title: "and"), .option(tag: .or, title: "or")],
                                width: 58)
                    // A rule that excludes films excludes them whatever it is joined by
                    // (SearchController.applyTokens), so its and/or would change nothing.
                    .disabled(rule.isOperatorChosen && rule.op.isInverted)
                    .help(rule.isOperatorChosen && rule.op.isInverted
                          ? "A rule that excludes films always applies."
                          : "And: must also match. Or: matching this rule is enough.")
            }

            SheetMenuPicker(selection: Binding(
                get: { rule.isFieldChosen ? rule.field : nil },
                set: { field in
                    guard let field, !rule.isFieldChosen || field != rule.field else { return }
                    Self.endEditing()
                    rule = rule.changingField(to: field)
                    rule.isFieldChosen = true
                }), items: Self.fieldItems, width: 140)

            // Waits for a field; its choices depend on it.
            SheetMenuPicker(selection: Binding(
                get: { rule.isFieldChosen && rule.isOperatorChosen ? rule.op : nil },
                set: { if let op = $0 { Self.endEditing(); switchOperator(to: op) } }),
                            items: operatorItems, width: 150)
                .disabled(!rule.isFieldChosen)

            // Nothing to edit until the condition is chosen.
            Group {
                if rule.isFieldChosen && rule.isOperatorChosen { valueEditor } else { Color.clear }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ListCircleButton(
                systemImage: "minus",
                fill: Preferences.red,
                diameter: ListRowMetrics.circleDiameter,
                glyphSize: ListRowMetrics.circleGlyphSize,
                isEnabled: canRemove,
                help: "Remove this rule",
                role: .destructive,
                glyphOffset: ListCircleButtonStyle.minusGlyphOffset,
                action: onRemove)
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    /// Header, then options, for each group; a separator between groups.
    private static func grouped<T: Hashable>(_ groups: [(String, [(tag: T, title: String)])]) -> [SheetPopUpButton<T>.Item] {
        var items: [SheetPopUpButton<T>.Item] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { items.append(.separator) }
            if !group.0.isEmpty { items.append(.header(group.0)) }
            items += group.1.map { .option(tag: $0.tag, title: $0.title) }
        }
        return items
    }

    private static func fieldLabel(_ field: SearchField) -> String {
        switch field {
        case .crew: return "Anyone in the Credits"
        case .flags: return "Status (Is)"
        case .releases: return "Releases"
        default: return field.displayName
        }
    }

    private var operatorItems: [SheetPopUpButton<RuleOperator?>.Item] {
        let options = RuleOperator.options(for: rule.field)
        return [.placeholder(tag: nil, title: Self.selectTitle)]
            + options.filter { $0.editor != .raw }.map { .option(tag: $0, title: $0.label) }
            + [.separator]
            + options.filter { $0.editor == .raw }.map { .option(tag: $0, title: $0.label) }
    }

    /// Switching to "matches" carries the current value over as typed, so a structured rule
    /// can be refined in search syntax without starting again.
    private func switchOperator(to op: RuleOperator) {
        let previous = rule
        rule.isOperatorChosen = true
        guard op != previous.op || !previous.isOperatorChosen else { return }
        rule.op = op
        // A year and an amount share the numbers but not their meaning: "in the last 1
        // month" must not become the year 1, nor this year an amount of 2026 months.
        if (op.editor == .year) != (previous.op.editor == .year) {
            (rule.a, rule.b) = QueryRule.defaultNumbers(for: rule.field, op: op)
        }
        guard previous.isOperatorChosen else { return }
        if op.editor == .raw, previous.op.editor != .raw { rule.text = previous.value }
        // A menu value chosen for one kind of menu means nothing in another.
        if op.editor != previous.op.editor, op.editor.isMenu {
            rule.isValueChosen = false
            rule.otherChosen = nil
            rule.text = ""
        }
    }

    /// Ends any text editing in the sheet, committing the field being edited. Before
    /// anything replaces or removes the row a field writes to, and before saving.
    static func endEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: Value Editors

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.op.editor {
        case .text:
            TextField(rule.field == .title ? "Title" : "Text", text: $rule.text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .centeredWithPopUps()
        case .raw:
            TextField("As typed after #\(rule.field.aliases.first ?? rule.field.rawValue)", text: $rule.text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .centeredWithPopUps()
                .help("Any value the search field accepts for this field. See the Search Guide.")
        case .number:
            HStack(spacing: 4) {
                NumberEntry(value: $rule.a)
                unitLabel
            }
        case .numberRange:
            HStack(spacing: 4) {
                NumberEntry(value: $rule.a)
                Text("and").foregroundStyle(.secondary)
                NumberEntry(value: $rule.b)
                unitLabel
            }
        case .year:
            NumberEntry(value: $rule.a, range: CustomDateStepper.defaultYearRange)
        case .amountUnit:
            HStack(spacing: 4) {
                NumberEntry(value: $rule.a)
                SheetMenuPicker(selection: $rule.unit,
                                items: RuleTimeUnit.allCases.map { .option(tag: $0, title: $0.label(rule.a)) },
                                width: 76)
                if rule.op == .moreThanAgo || rule.op == .aboutAgo {
                    Text("ago").foregroundStyle(.secondary)
                }
            }
        case .day:
            DatePicker("Date", selection: Binding(
                get: { rule.day.date() },
                set: { rule.day = RuleDay($0) }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
        case .none:
            EmptyView()
        case .flagTerm:
            menuValue(selection: $rule.text,
                      items: FilmFlag.terms.map { .option(tag: $0.display, title: $0.display) })
        case .listName:
            choiceWithOther(selection: $rule.text,
                            groups: listChoices.map { ($0.title + ":", $0.names) },
                            placeholder: "Part of a list name")
        case .releaseKeyword:
            choiceWithOther(selection: $rule.text,
                            groups: Self.releaseGroups,
                            placeholder: "e.g. criterion, 2027, >2026")
        case .rotationValue:
            choiceWithOther(selection: $rule.text,
                            groups: [("", RuleValues.rotationValues)],
                            placeholder: "e.g. 2 years")
        }
    }

    /// Release keywords grouped in their declared order, headed as the Search Guide heads them.
    private static let releaseGroups: [(String, [String])] = {
        var groups: [(String, [String])] = []
        for item in RuleValues.releaseKeywords {
            if groups.last?.0 == item.group + ":" { groups[groups.count - 1].1.append(item.keyword) }
            else { groups.append((item.group + ":", [item.keyword])) }
        }
        return groups
    }()

    @ViewBuilder
    private var unitLabel: some View {
        switch rule.field {
        case .duration: Text("minutes").foregroundStyle(.secondary)
        case .rating: Text("out of 10").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    /// A value menu spanning the row up to "−", showing "Select…" until a value is chosen.
    private func menuValue(selection: Binding<String>, items: [SheetPopUpButton<String>.Item],
                           maxWidth: CGFloat = .infinity) -> some View {
        let unchosen = "\u{1}unchosen"
        return SheetPopUpButton(selection: Binding(
            get: { rule.isValueChosen ? selection.wrappedValue : unchosen },
            set: { value in
                guard value != unchosen else { return }
                rule.isValueChosen = true
                selection.wrappedValue = value
            }), items: [.placeholder(tag: unchosen, title: Self.selectTitle)] + items)
            .frame(maxWidth: maxWidth, maxHeight: SheetPopUpButton<String>.layoutHeight, alignment: .leading)
    }

    /// A menu of fixed choices with a last item, "Other…", that reveals a text field for
    /// anything else. The text is the value either way. The menu shows "Other…" once it is
    /// chosen (QueryRule.otherChosen), and for a rule read from a token whose text is not
    /// one of the choices.
    private func choiceWithOther(selection: Binding<String>, groups: [(String, [String])],
                                 placeholder: String) -> some View {
        let all = Set(groups.flatMap(\.1))
        let isOther = rule.isValueChosen && (rule.otherChosen ?? !all.contains(selection.wrappedValue))
        let items = Self.grouped(groups.map { group in (group.0, group.1.map { (tag: $0, title: $0) }) })
            + [.separator, .option(tag: Self.otherTag, title: "Other…")]
        return HStack(spacing: 4) {
            menuValue(selection: Binding(
                get: { isOther ? Self.otherTag : selection.wrappedValue },
                set: { value in
                    rule.otherChosen = value == Self.otherTag
                    selection.wrappedValue = value == Self.otherTag ? "" : value
                }),
                      items: items, maxWidth: isOther ? 90 : .infinity)
            if isOther {
                TextField(placeholder, text: selection)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .centeredWithPopUps()
            }
        }
    }
}

// MARK: - Number Entry

/// A rule's number, typed in the app's digit-only field (DigitTextField): only digits go
/// in, and every keystroke reaches the rule, so the live results and Save follow the
/// typing — a formatted TextField held the number back until Return or Tab, and a click
/// on Save came first. Ending the edit settles the text: an empty field returns to the
/// number it held, and a `range` (a year) clamps the number into it, the range the year
/// Steppers step through.
private struct NumberEntry: View {
    @Binding var value: Int
    let range: ClosedRange<Int>?
    @State private var text: String

    init(value: Binding<Int>, range: ClosedRange<Int>? = nil) {
        _value = value
        self.range = range
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        DigitTextField(text: $text, maxLength: 4, placeholder: "",
                       onEndEditing: { committed, _ in settle(committed) }, fontSize: 12)
            // Spans the row, as every other value editor does; a range's two share it.
            .frame(maxWidth: .infinity)
            .centeredWithPopUps()
            .onChange(of: text) { _, typed in
                // A year passes through numbers outside its range on the way ("2", "20"…);
                // only one inside it is taken while typing, and the end of the edit
                // clamps whatever is left.
                guard let typedValue = Int(typed), range?.contains(typedValue) ?? true,
                      typedValue != value else { return }
                value = typedValue
            }
            .onChange(of: value) { _, newValue in
                // Set from outside: another operator's starting numbers.
                if Int(text) != newValue { text = String(newValue) }
            }
    }

    private func settle(_ committed: String) {
        var settled = Int(committed) ?? value
        if let range { settled = min(max(settled, range.lowerBound), range.upperBound) }
        if settled != value { value = settled }
        if text != String(settled) { text = String(settled) }
    }
}

// MARK: - Row Alignment

private extension View {
    /// Centers a text field on the row's pop-up buttons. SwiftUI centers a pop-up by its
    /// alignment rect, which AppKit insets unevenly from the 25 pt frame (1 pt top, 4 pt
    /// bottom), so the bezel sits half a point above that center; a text field has no
    /// inset and is centered as drawn. Moving its center guide down by the same half
    /// point lifts it level with the bezels.
    func centeredWithPopUps() -> some View {
        alignmentGuide(VerticalAlignment.center) { $0[VerticalAlignment.center] + 0.5 }
    }
}
