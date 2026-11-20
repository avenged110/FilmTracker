// MARK: - TagSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The TagSheet: one sheet with two views, only one of which it ever shows. The rename view is
/// the small name sheet lists use (ListManagerSheet); the View All Tags view lists every tag in
/// the library, pins, renames and deletes them, and shows each tag's films. Opened from a tag row's menu
/// in the left sidebar or the menu bar (TagActions).

import SwiftUI

// MARK: - Tag Sheet
struct TagSheet: View {
    enum Mode: Equatable, Sendable {
        /// Renaming the tag of this name.
        case rename(String)
        /// Every tag in the library.
        case viewAll
    }

    let mode: Mode

    var body: some View {
        switch mode {
        case .rename(let name):
            TagRenameView(tag: SidebarTag(name))
        case .viewAll:
            AllTagsView()
        }
    }
}

// MARK: - Rename View
/// Laid out as ListManagerSheet's edit view: a large glyph, the title, the field, a note on the
/// names it refuses, Cancel and Rename. The new name reaches every film carrying the tag and
/// the saved searches whose rules name it, which a second note discloses
/// (TagActions.performRename).
private struct TagRenameView: View, Loggable {
    nonisolated static let logTag = "[TagSheet]"

    let tag: SidebarTag

    @Environment(\.dismiss) private var dismiss
    @Environment(DataCoordinator.self) private var coordinator

    @State private var name = ""
    @State private var isSaving = false
    /// The debounced form of `collides`, as ListManagerSheet's showsCollision: it turns the
    /// note red and disables Rename once the entry has rested on a taken name.
    @State private var showsCollision = false

    /// As ListManagerSheet's collisionOnsetDelay: typing through a taken name ("Noir" on the
    /// way to "Noirish") doesn't flash the note red.
    private static let collisionOnsetDelay: Duration = .milliseconds(150)

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Films carrying the tag now.
    private var filmCount: Int {
        SidebarTags.census(in: coordinator).first { $0.key == tag.key }?.filmCount ?? 0
    }

    /// True when the entry is another tag's name, in any spelling: a film's tags or a pin.
    /// A change of case or spacing alone keeps the tag's own key and is always allowed.
    private var collides: Bool {
        let key = SearchText.key(trimmed)
        guard !key.isEmpty, key != tag.key else { return false }
        return PinnedTagStore.shared.keys.contains(key)
            || SidebarTags.census(in: coordinator).contains { $0.key == key }
    }

    /// A name with no letters or digits ("!!!") has no key, so it could name no tag.
    private var canSave: Bool {
        !SearchText.key(trimmed).isEmpty && trimmed != tag.name && !showsCollision && !isSaving
    }

    /// The saved searches with a rule naming the tag, read once as the sheet opens.
    @State private var namingSearches: [SavedSearch] = []

    /// Whether renaming to the entry would update them: a name still containing the old one
    /// leaves their rules as they are (SavedSearchQuery.renamingTag).
    private var updatesSavedSearches: Bool {
        canSave && namingSearches.contains { $0.query.renamingTag(tag.key, to: trimmed) != nil }
    }

    /// Whether renaming to the entry leaves them as written because the name holds a comma,
    /// which a rule reads as separating alternatives (SavedSearchQuery.renamingTag): they would
    /// stop finding the tag's films, so the sheet says so.
    private var skipsSavedSearches: Bool {
        canSave && trimmed.contains(",") && !namingSearches.isEmpty
    }

    private var savedSearchDisclosure: String {
        if namingSearches.count == 1, let name = namingSearches.first?.name {
            return "The saved search \u{201C}\(name)\u{201D} will also be updated to use the new name."
        }
        return "\(Fmt.count(namingSearches.count)) saved searches will also be updated to use the new name."
    }

    private var savedSearchSkipNote: String {
        if namingSearches.count == 1, let name = namingSearches.first?.name {
            return "The saved search \u{201C}\(name)\u{201D} won\u{2019}t be updated: A comma would change what it finds."
        }
        return "\(Fmt.count(namingSearches.count)) saved searches won\u{2019}t be updated: A comma would change what they find."
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: ViewGlyphs.tag.filled)
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            Text("Rename Tag")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 8)
                .padding(.bottom, 4)

            let count = filmCount
            Text("Used by \(Fmt.count(count)) \(Fmt.noun(count, "Film"))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            TextField("Tag Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .onSubmit {
                    if canSave { save() }
                }

            Text("Note: Name must not match that of another tag.")
                .font(.system(size: 11))
                .foregroundStyle(showsCollision ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 280, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, namingSearches.isEmpty ? 20 : 6)

            /// Discloses the saved searches the rename will also update, or, for a name with a
            /// comma, that it leaves them as written. Its space, the taller of the two notes, is
            /// kept whenever a saved search names the tag, so the sheet doesn't resize as the
            /// entry changes; a note shows while it applies.
            if !namingSearches.isEmpty {
                let updates = updatesSavedSearches
                let skips = skipsSavedSearches
                ZStack(alignment: .topLeading) {
                    savedSearchNote(savedSearchDisclosure, isShown: updates)
                    savedSearchNote(savedSearchSkipNote, isShown: skips)
                }
                .frame(width: 280, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").sheetButtonLabel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Spacer()

                Button {
                    save()
                } label: {
                    Text("Rename").sheetButtonLabel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .sheetBottomBar()
        }
        .frame(width: 320)
        .fixedSize()
        .onAppear {
            name = tag.name
            namingSearches = TagActions.savedSearchesNaming(tag)
        }
        /// The debounce, as ListManagerSheet's: each keystroke cancels the last run, so only an
        /// entry resting on a taken name raises the flag; any other entry clears it at once.
        .task(id: name) {
            guard collides else {
                if showsCollision { showsCollision = false }
                return
            }
            guard !showsCollision else { return }
            try? await Task.sleep(for: Self.collisionOnsetDelay)
            guard !Task.isCancelled else { return }
            showsCollision = true
        }
    }

    private func savedSearchNote(_ text: String, isShown: Bool) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280, alignment: .leading)
            .opacity(isShown ? 1 : 0)
            .accessibilityHidden(!isShown)
    }

    private func save() {
        /// The live check, for a Return pressed inside the debounce window.
        guard !isSaving, !collides else {
            if collides { showsCollision = true }
            return
        }
        isSaving = true
        let newName = trimmed
        Self.log("Renaming tag '\(tag.name)' to '\(newName)'")
        Task {
            await TagActions.performRename(tag, to: newName, coordinator: coordinator)
            dismiss()
        }
    }
}

// MARK: - View All Tags
/// Every tag in the library, alphabetically, with pinned tags no film carries among them. A
/// row's menu pins, renames or deletes its tag, as the sidebar's does; its film-count button
/// opens a popover listing the films (the Insights tab's DVAttentionPopover) whose button makes
/// a list of them.
private struct AllTagsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataCoordinator.self) private var coordinator

    /// The list the popover's "Create New List With These Items" asks for. Another sheet can't
    /// open while this one is up, so the list sheet opens over this one and returns here.
    @State private var listCreation: ListCreation?
    /// The tag the rename view is open on, over this sheet.
    @State private var renaming: TagUsage?
    /// The tag the delete confirmation asks about. Shown here, over this sheet: AlertHostView
    /// never presents over a sheet.
    @State private var deleting: TagUsage?

    struct ListCreation: Identifiable {
        let id = UUID()
        let filmIDs: Set<UUID>
        let name: String
    }

    /// The census, plus each pinned tag no film carries, by name.
    private var rows: [TagUsage] {
        var rows = SidebarTags.census(in: coordinator)
        let present = Set(rows.map(\.key))
        for pinned in PinnedTagStore.shared.tags where !present.contains(pinned.key) {
            rows.append(TagUsage(key: pinned.key, name: pinned.name, filmCount: 0))
        }
        return rows.sorted {
            let order = $0.name.englishStandardCompare($1.name)
            return order != .orderedSame ? order == .orderedAscending : $0.key < $1.key
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            /// First in the sheet, as the FilmSheet's: AppKit's automatic first responder lands
            /// here rather than on the first control, so the sheet opens with no focus ring and
            /// one Tab press reaches the first row's menu.
            FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: true)
                .frame(height: 0)
                .clipped()

            SheetTitleBar("All Tags")

            Group {
                if rows.isEmpty {
                    SheetPlaceholder("No films in your library carry tags.")
                } else {
                    DataCoordinatorScrollView {
                        TagUsageList(rows: rows) { action in
                            switch action {
                            case .createList(let filmIDs, let name):
                                listCreation = ListCreation(filmIDs: filmIDs, name: name)
                            case .rename(let usage):
                                renaming = usage
                            case .delete(let usage):
                                deleting = usage
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            /// The rename view, over this sheet rather than in place of it, as an alert opens
            /// over a sheet.
            .sheet(item: $renaming) { usage in
                TagSheet(mode: .rename(usage.name))
                    .environment(coordinator)
            }

            Divider()

            /// The count leading and Close trailing, where the Settings sheet keeps its one button.
            HStack {
                Text("\(Fmt.count(rows.count)) \(Fmt.noun(rows.count, "Tag"))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Close").sheetButtonLabel()
                }
                .keyboardShortcut(.cancelAction)
                .focusable(false)
            }
            .sheetBottomBar()
        }
        .sheetFrame()
        .sheet(item: $listCreation) { request in
            ListManagerSheet(mode: .create, filmIDs: request.filmIDs, prefillName: request.name)
                .environment(coordinator)
        }
        /// The sidebar's "Delete Tag?", word for word (TagActions.deleteAlertMessage).
        .alert(TagActions.deleteAlertTitle,
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { usage in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await TagActions.performDelete(usage.sidebarTag, coordinator: coordinator) }
            }
        } message: { usage in
            Text(TagActions.deleteAlertMessage(name: usage.name, filmCount: usage.filmCount))
        }
    }
}

// MARK: - Tag Usage List
/// The rows inside View All Tags' scroll view.
///
/// **Inside the scroll view, on purpose.** The scroll view hosts its content in a hosting view
/// of its own and holds back every update from outside it while the list scrolls
/// (AppKitScrollView's live-scroll buffering). State that the rows need to change while
/// scrolling, the open films popover, therefore lives here: held by AllTagsView, closing it
/// would wait for the scroll to end and settle.
///
/// **What the sheet builds as it opens.** AppKit animates a sheet from a run-loop mode that
/// nothing else runs in, so whatever the sheet's first layout costs is paid before the
/// animation starts, and nothing deferred can run until the animation ends. The rows the
/// sheet shows at once are built before it appears. The rest are built after the animation,
/// one per frame, each standing in as an empty row of the same height until then: under a
/// frame's work each, top-down, so thirty tags are all built about a quarter of a second
/// after the sheet settles (measured). A plain VStack, as DVAttentionPopover's list: a lazy
/// stack builds everything here anyway (the scroll view's hosting view shows it whole), and
/// its estimated heights make the scroller jump.
private struct TagUsageList: View {
    let rows: [TagUsage]
    let onAction: (TagRowAction) -> Void

    /// The key of the row whose films popover is open; opening one closes any other.
    @State private var popoverKey: String?

    /// Each row's wave, by key: 0 for the rows the opening sheet shows, then one wave per
    /// row in order. Fixed as the sheet opens, so a tag that turns up while it's open (an
    /// import finishing) is built at once rather than queued behind the others.
    @State private var openingWaves: [String: Int]

    init(rows: [TagUsage], onAction: @escaping (TagRowAction) -> Void) {
        self.rows = rows
        self.onAction = onAction
        _openingWaves = State(initialValue: Self.waves(for: rows))
    }

    /// The rows whose tops fall inside the list's viewport: the sheet's height less its title
    /// and bottom bars (about 86 points; 80 here, so a change of chrome errs toward one row
    /// more) and the space above the first row, over a row's height.
    private static let openingRowCount =
        Int(((Preferences.sheetSize - 80 - stripeInset) / TagUsageRow.rowHeight).rounded(.up))

    private static func waves(for rows: [TagUsage]) -> [String: Int] {
        var waves: [String: Int] = [:]
        for (index, usage) in rows.enumerated() where index >= openingRowCount {
            waves[usage.key] = index - openingRowCount + 1
        }
        return waves
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, usage in
                DeferredTagRow(wave: openingWaves[usage.key] ?? 0) {
                    TagUsageRow(usage: usage,
                                isShowingFilms: popoverBinding(for: usage.key), onAction: onAction)
                }
                /// Outside the deferral, so a row not yet built is striped already.
                .background {
                    if !index.isMultiple(of: 2) { Self.stripe }
                }
            }
        }
        .padding(.vertical, Self.stripeInset)
        /// Closes the films popover when the list scrolls, as every popover in a scrolling
        /// list does (ScrollActivityObserver, 30.20).
        .background(
            ScrollActivityObserver {
                if popoverKey != nil { popoverKey = nil }
            }
        )
    }

    /// Alternate rows striped as the Insights tables (Hall of Fame) stripe theirs: an inset
    /// NSTableView fills every second row with the system's second alternating color, in a band
    /// inset 10 points from each side with 4-point corners, with no dividers and 10 points above
    /// the first row (measured from an inset table). One fill per striped row: nothing
    /// measurable beside the row itself.
    private static let stripeInset: CGFloat = 10

    private static var stripe: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
            .padding(.horizontal, stripeInset)
    }

    private func popoverBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { popoverKey == key },
            set: { isShown in
                if isShown {
                    popoverKey = key
                } else if popoverKey == key {
                    popoverKey = nil
                }
            })
    }
}

// MARK: - Deferred Tag Row
/// A row built `wave` frames after it first appears, an empty row of its height until then;
/// wave 0 builds it at once.
///
/// Unlike DeferredFieldContent (30.20), whose waves count from the moment the fields appear,
/// each wave here waits a frame after the one before it. The waiting can't start until the
/// sheet's animation has ended (see TagUsageList), so waves counted from the opening would all
/// come due at that moment and land together, as one long frame. Built once, a row stays
/// built: its wave is read only when it is created.
private struct DeferredTagRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isBuilt: Bool
    private let wave: Int

    init(wave: Int, @ViewBuilder content: @escaping () -> Content) {
        self.wave = wave
        self.content = content
        _isBuilt = State(initialValue: wave <= 0)
    }

    var body: some View {
        if isBuilt {
            content()
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: TagUsageRow.rowHeight)
                .task {
                    /// Cancellation (the sheet closing) leaves the row unbuilt, as it is going.
                    for _ in 0..<wave {
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    }
                    /// As DeferredFieldContent: the swap is never animated.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isBuilt = true }
                }
        }
    }
}

// MARK: - Tag Usage Row
/// One tag: its glyph (pin.fill for a pinned tag, tag.fill otherwise), its name, its film
/// count, the film.stack button whose popover lists its films, and the menu of the sidebar
/// row's actions.
private struct TagUsageRow: View {
    let usage: TagUsage
    /// The films popover's presentation, owned by TagUsageList (see its popoverKey).
    @Binding var isShowingFilms: Bool
    let onAction: (TagRowAction) -> Void

    @Environment(DataCoordinator.self) private var coordinator

    /// The films behind the popover, read when it opens.
    @State private var films: [DVNamedFilm] = []

    static let rowHeight: CGFloat = 32

    private var isPinned: Bool { PinnedTagStore.shared.keys.contains(usage.key) }

    var body: some View {
        let isPinned = isPinned
        HStack(spacing: 8) {
            Image(systemName: isPinned ? "pin.fill" : ViewGlyphs.tag.filled)
                .font(.system(size: 13))
                .foregroundStyle(isPinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 18)
                .help(isPinned ? "Pinned to the sidebar" : "")
                .accessibilityLabel(isPinned ? "Pinned" : "Tag")

            /// The list titles' ceiling (truncateListName); narrower, the row truncates sooner.
            Text(truncateListName(usage.name))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text("\(Fmt.count(usage.filmCount)) \(Fmt.noun(usage.filmCount, "Film"))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            FilmsButton(filmCount: usage.filmCount) {
                if isShowingFilms {
                    isShowingFilms = false
                } else {
                    films = filmsCarrying()
                    isShowingFilms = true
                }
            }
            .popover(isPresented: $isShowingFilms, arrowEdge: .trailing) {
                DVAttentionPopover(label: usage.name, items: films, dismiss: { isShowingFilms = false },
                                   onCreateList: { filmIDs in
                                       isShowingFilms = false
                                       onAction(.createList(filmIDs: filmIDs, name: usage.name))
                                   })
            }

            /// The sidebar row's menu, less View All Tags (this is it): the same items, acting
            /// the same way, except that Rename and Delete open over this sheet.
            TagMenuButton(isPinned: isPinned) { item in
                switch item {
                case .togglePin: TagActions.togglePin(usage.sidebarTag)
                case .rename: onAction(.rename(usage))
                case .delete: onAction(.delete(usage))
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
    }

    private func filmsCarrying() -> [DVNamedFilm] {
        SidebarTags.filmIDs(taggedWith: usage.sidebarTag, in: coordinator.getAllFilms())
            .compactMap { coordinator.getFilm($0).map { DVNamedFilm($0) } }
    }
}

/// What a row asks of the sheet: the actions that open something over it.
private enum TagRowAction {
    case createList(filmIDs: Set<UUID>, name: String)
    case rename(TagUsage)
    case delete(TagUsage)
}

// MARK: - Tag Menu Button
/// The row's ellipsis menu: a pull-down NSPopUpButton with push-button chrome and no arrow,
/// the control a SwiftUI Menu with its indicator hidden is built on, hosted directly. Measured
/// with the earlier segmented Picker: a SwiftUI control per row costs about three times its
/// AppKit control to build and updates whenever the sheet's window gains or loses key status,
/// as it does when each animation starts, which stalled both animations. The
/// Pin item's title is set as the menu opens, so it always reads the store.
private struct TagMenuButton: NSViewRepresentable {
    /// From 1: an item's tag is 0 by default, the hidden first item's included.
    enum Item: Int { case togglePin = 1, rename, delete }

    let isPinned: Bool
    let onChoose: (Item) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .push
        /// Configured as SwiftUI configures a Menu's: the face is the cell's own item rather
        /// than the menu's first, no arrow.
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .noArrow
            cell.usesItemFromMenu = false
            let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            face.image = Glyph.ellipsis
            cell.menuItem = face
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        /// A pull-down's first item is never shown in its menu.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for (item, title) in [(Item.togglePin, "Pin Tag"), (.rename, "Edit Tag Name\u{2026}"), (.delete, "Delete Tag")] {
            let menuItem = NSMenuItem(title: title, action: #selector(Coordinator.chosen(_:)), keyEquivalent: "")
            menuItem.target = context.coordinator
            menuItem.tag = item.rawValue
            menu.addItem(menuItem)
        }
        menu.delegate = context.coordinator
        button.menu = menu
        return button
    }

    /// The face's width, a SwiftUI Menu's with an ellipsis label (its alignment rectangle).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: Self.faceWidth, height: nsView.intrinsicContentSize.height)
    }

    static let faceWidth: CGFloat = 30

    @MainActor
    enum Glyph {
        static let ellipsis = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Tag Actions")
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onChoose = onChoose
        context.coordinator.isPinned = isPinned
        let help = "Pin, rename, or delete this tag"
        if button.toolTip != help { button.toolTip = help }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var onChoose: ((Item) -> Void)?
        var isPinned = false

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.item(withTag: Item.togglePin.rawValue)?.title = isPinned ? "Unpin Tag" : "Pin Tag"
        }

        @objc func chosen(_ sender: NSMenuItem) {
            guard let item = Item(rawValue: sender.tag) else { return }
            onChoose?(item)
        }
    }
}

// MARK: - Films Button
/// The row's film.stack push button, which opens the films popover: an NSButton hosted
/// directly (see TagMenuButton), the ellipsis menu's size.
private struct FilmsButton: NSViewRepresentable {
    let filmCount: Int
    let action: () -> Void

    @MainActor
    enum Glyph {
        static let films = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Show Films")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .push
        button.image = Glyph.films
        button.imagePosition = .imageOnly
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let enabled = filmCount > 0
        if button.isEnabled != enabled { button.isEnabled = enabled }
        let help = "Show the films using this tag"
        if button.toolTip != help { button.toolTip = help }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: TagMenuButton.faceWidth, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func clicked() { action?() }
    }
}
