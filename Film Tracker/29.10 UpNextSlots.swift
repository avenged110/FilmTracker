// MARK: - UpNextSlots.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The "Up Next" Queue's empty slots. "Up Next" holds at most FilmQueue.upNextCapacity
// films; on the Film Queue's "All" tab, every vacancy is drawn after the "Up Next" films as
// a dashed placeholder the size of a gallery cell (grid) or row (list). Slots are
// interchangeable: "Up Next" is ordered by the gallery's sort, so a film added from any
// slot simply takes its sorted place and the placeholders fill from the top down. A slot is not a
// film: it lives outside the gallery's film index space, so selection, marquee, drag and
// keyboard navigation never see it. Clicking one opens the slot sheet to search for a film;
// dropping films from the Queue's other sections on one moves them into "Up Next".
//
// Hooks elsewhere:
//   • SmoothResizingGridLayout.slotRun (23.10) lays the grid's slots out; GallerySubview
//     (23.20) feeds it from `UpNextSlots.plan` and registers UpNextSlotDecorationView.
//   • GalleryListView (23.30) emits `.slot` rows from the same plan.
//   • SheetHostView (10.10) presents UpNextSlotSheet for UICommand.openUpNextSlot.
//   • UpNextResultsTable (23.30) is the sheet's result list: the list gallery's own table.

import AppKit
import SwiftUI
import Synchronization

// MARK: - Plan

@MainActor
enum UpNextSlots: Loggable {
    nonisolated static let logTag = "[UpNextSlots]"

    /// Where a gallery draws its empty slots. Shared by both gallery styles so they cannot
    /// disagree.
    struct Plan: Equatable {
        /// The film index the slots follow: the end of the displayed "Up Next" run.
        let afterIndex: Int
        /// The position of the first empty slot (1-based). Layout identity only: slots are
        /// interchangeable and never numbered in the UI.
        let firstNumber: Int
        let count: Int
        /// True when no "Up Next" film is displayed, so no band names the section: the
        /// gallery draws an "Up Next" band of its own above the slots.
        let needsOwnBand: Bool
    }

    /// The slot plan for a gallery showing `filmCount` films with these section breaks, or
    /// nil anywhere but the Film Queue's "All" tab, or when "Up Next" is full.
    ///
    /// Vacancies come from "Up Next"'s real membership, not from what is displayed, so a
    /// filter hiding some of its films never offers more slots than actually exist.
    static func plan(breaks: [(index: Int, section: GallerySection)], filmCount: Int,
                     coordinator: DataCoordinator) -> Plan? {
        guard coordinator.loadedFilmQueueFilter == .all else { return nil }
        let vacancies = FilmQueue.upNextVacancies(coordinator: coordinator)
        guard vacancies > 0 else { return nil }
        let upNext = FilmQueueSection.upNext.gallerySection
        let showsUpNext = breaks.first?.section == upNext
        let end = showsUpNext ? (breaks.count > 1 ? breaks[1].index : filmCount) : 0
        return Plan(afterIndex: end,
                    firstNumber: FilmQueue.upNextCapacity - vacancies + 1,
                    count: vacancies,
                    needsOwnBand: !showsUpNext)
    }

    /// A section divider's trailing count, shared by both gallery styles. "Up Next" states
    /// its capacity ("3 of 8 films"); every other section a plain count.
    static func sectionCountText(section: GallerySection, filmCount: Int) -> String {
        if section == FilmQueueSection.upNext.gallerySection {
            return "\(filmCount) of \(FilmQueue.upNextCapacity) films"
        }
        return "\(filmCount) film\(filmCount == 1 ? "" : "s")"
    }

    /// True while "Up Next" really has a vacancy at slot `number` (1-based) — read from its
    /// live membership, not from whatever a gallery last laid out. A slot view asks this
    /// before it takes a click or a drop, so a placeholder left behind by a layout that
    /// has not caught up yet can never act as one (see UpNextSlotView.isLive).
    static func isOpen(slotNumber number: Int) -> Bool {
        guard number > 0, let coordinator = AppDelegate.dataCoordinator else { return false }
        let vacancies = FilmQueue.upNextVacancies(coordinator: coordinator)
        return vacancies > 0 && number > FilmQueue.upNextCapacity - vacancies
    }

    // MARK: Actions

    static func open() {
        log("Opening the slot sheet")
        AppEventBus.shared.sendCommand(.openUpNextSlot)
    }

    /// Adds dropped films to "Up Next". Runs inside performDragOperation, so it is
    /// synchronous and defers any alert to the end of the drag session — the same contract
    /// as the sidebar's Queue row (LeftSidebar.RowDragProxyView).
    static func performDrop(_ info: any NSDraggingInfo) -> Bool {
        guard let filmIDs = FilmDragDecoder.decode(from: info), !filmIDs.isEmpty,
              let coordinator = AppDelegate.dataCoordinator else { return false }
        let listID = FilmQueueSection.upNext.listID
        let newcomers = filmIDs.subtracting(FilmQueue.upNextFilmIDs(coordinator: coordinator))
        guard !newcomers.isEmpty else { return false }   // already in "Up Next"
        if FilmQueue.refuseUpNextAddIfFull(newcomers, coordinator: coordinator,
                                           afterDragSession: true) {
            log("Refused drop of \(newcomers.count) film(s) on a slot — not enough room")
            return false
        }
        if FilmQueue.addNeedsConfirmation(newcomers, coordinator: coordinator) {
            AppEventBus.shared.sendAlert(.confirmFilmQueueAddOnDrop(filmIDs: newcomers, listID: listID))
            return true
        }
        log("Adding \(newcomers.count) dropped film(s) to 'Up Next'")
        FilmManager.addFilmsToList(newcomers, listID: listID, coordinator: coordinator)
        return true
    }
}

// MARK: - Slot View

/// A dashed, empty placeholder with a "plus.circle.fill" glyph: one empty "Up Next" slot.
/// Clicking it opens the slot sheet; films dropped on it join "Up Next". Subclasses say
/// where the outline and the glyph go.
@MainActor
class UpNextSlotView: NSView {
    private(set) var slotNumber = 0
    private let outline = CAShapeLayer()
    private let glyph = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { if isHovered != oldValue { refreshColors() } } }
    private var isDropTarget = false { didSet { if isDropTarget != oldValue { refreshColors() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { refreshColors() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        registerForDraggedTypes([.filmIDs])
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setSlotNumber(_ number: Int) {
        guard number != slotNumber else { return }
        slotNumber = number
        setAccessibilityLabel("Empty \"Up Next\" slot")
    }

    // Geometry, supplied by subclasses.
    func outlineRect() -> CGRect { bounds.insetBy(dx: 1, dy: 1) }
    func outlineCornerRadius() -> CGFloat { 6 }
    func glyphRect(in outline: CGRect) -> CGRect {
        let side = min(36, outline.width * 0.3)
        return CGRect(x: outline.midX - side / 2, y: outline.midY - side / 2, width: side, height: side)
    }

    override func layout() {
        super.layout()
        let rect = outlineRect()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = rect.width > 0 && rect.height > 0
            ? CGPath.continuousRoundedRect(rect, cornerRadius: outlineCornerRadius()) : nil
        CATransaction.commit()
        let glyphFrame = glyphRect(in: rect)
        if glyph.frame != glyphFrame {
            glyph.frame = glyphFrame
            refreshGlyph()
        }
    }

    private func refreshGlyph() {
        let config = NSImage.SymbolConfiguration(pointSize: max(8, glyph.frame.height), weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: glyphColor))
        glyph.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Hover changes only the glyph's color. Pressing (and a drop) changes the fill, which
    /// is what hover used to do.
    private var glyphColor: NSColor {
        isDropTarget ? .controlAccentColor : (isHovered ? .secondaryLabelColor : .tertiaryLabelColor)
    }

    private func refreshColors() {
        // effectiveAppearance resolves the dynamic colors for the CGColor snapshots below.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accent = NSColor.controlAccentColor
            outline.strokeColor = (isDropTarget ? accent : NSColor.tertiaryLabelColor).cgColor
            outline.fillColor = isDropTarget ? accent.withAlphaComponent(0.12).cgColor
                : (isPressed ? NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor : nil)
            outline.lineWidth = isDropTarget ? 2 : 1.5
            CATransaction.commit()
        }
        refreshGlyph()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    // MARK: Liveness

    /// True when this view is an "Up Next" slot the user can actually see and that actually
    /// exists: on screen, not hidden or faded out, and naming a slot "Up Next" really has
    /// free (UpNextSlots.isOpen). Subclasses add their own container's check.
    ///
    /// Every interaction goes through this, because the view's existence alone proves
    /// nothing. A collection view keeps a decoration it has stopped laying out — hidden in
    /// its reuse queue, or fading out under a film that has taken its cell — and the
    /// override of `hitTest` below bypasses NSView's own refusal to hit a hidden view. With
    /// seven films in "Up Next" and one slot after them, adding an eighth left that slot's
    /// view over the new film's cell: the film drew, but a click on it reached the stale
    /// slot and opened the slot sheet.
    ///
    /// Not gated on `window`: AppKit reads that property unsafely (an unowned reference), and
    /// a view outside any window is never hit-tested or offered a drop in the first place.
    var isLive: Bool {
        !isHiddenOrHasHiddenAncestor && alphaValue > 0
            && UpNextSlots.isOpen(slotNumber: slotNumber)
    }

    // MARK: Click

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview = unsafe superview, isLive else { return nil }
        return outlineRect().contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { isPressed = isLive }

    override func mouseDragged(with event: NSEvent) {
        isPressed = isLive && outlineRect().contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = outlineRect().contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        // Re-checked: the slot can be filled between the press and the release.
        guard inside, isLive else { return }
        UpNextSlots.open()
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isLive, sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTarget = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { isDropTarget = false }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isLive && sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return UpNextSlots.performDrop(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        // As the sidebar's drop targets do: the preview leaves with the highlight.
        NotificationCenter.default.post(name: .dismissDragPreviewImmediately, object: nil)
    }
}

// MARK: - Grid Slot

let upNextSlotDecorationKind = "UpNextSlotDecoration"

/// Decoration attributes carrying the slot's number, so a renumbered slot is re-applied
/// even when its frame did not move (the reason SectionDividerLayoutAttributes exists).
final class UpNextSlotLayoutAttributes: NSCollectionViewLayoutAttributes {
    // Held behind a Mutex rather than as nonisolated(unsafe) vars; see
    // SectionDividerLayoutAttributes for why the overrides below need nonisolated access.
    private struct Fields { var slotNumber = 0; var hasSubtitles = false }
    private nonisolated let fields = Mutex(Fields())

    nonisolated var slotNumber: Int {
        get { fields.withLock { $0.slotNumber } }
        set { fields.withLock { $0.slotNumber = newValue } }
    }
    nonisolated var hasSubtitles: Bool {
        get { fields.withLock { $0.hasSubtitles } }
        set { fields.withLock { $0.hasSubtitles = newValue } }
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let copy = copy as? UpNextSlotLayoutAttributes {
            let current = fields.withLock { $0 }
            copy.fields.withLock { $0 = current }
        }
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UpNextSlotLayoutAttributes else { return false }
        return super.isEqual(object) && other.slotNumber == slotNumber
            && other.hasSubtitles == hasSubtitles
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(super.hash)
        hasher.combine(slotNumber)
        return hasher.finalize()
    }
}

/// The grid's slot: a cell-sized decoration whose outline is exactly the poster box a film
/// in that cell would occupy.
final class UpNextSlotDecorationView: UpNextSlotView, NSCollectionViewElement {
    override func outlineRect() -> CGRect {
        GalleryTileGeometry.posterRect(inCellBounds: bounds)?.insetBy(dx: 0.75, dy: 0.75) ?? .zero
    }

    override func outlineCornerRadius() -> CGFloat { Preferences.cornerRadius }

    /// Also requires the grid's CURRENT layout to place this slot exactly where this view
    /// sits. A view the layout no longer accounts for — the slot was filled, or renumbered
    /// to another cell — is stale even while a vacancy of its number exists.
    override var isLive: Bool {
        guard super.isLive,
              let collectionView = enclosingCollectionView,
              let attrs = collectionView.collectionViewLayout?.layoutAttributesForDecorationView(
                  ofKind: upNextSlotDecorationKind, at: IndexPath(item: slotNumber, section: 0))
        else { return false }
        // The center rather than an exact frame, so a slot mid-way through an animated
        // relayout still counts while it is heading for its own cell.
        return attrs.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
    }

    /// The grid this slot belongs to: a decoration is a direct subview of the collection view,
    /// which is in turn the scroll view's document view. Reached through `enclosingScrollView`
    /// rather than by walking `superview`, which AppKit exposes as an unowned (unsafe) reference.
    private var enclosingCollectionView: NSCollectionView? {
        enclosingScrollView?.documentView as? NSCollectionView
    }

    func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        guard let attrs = layoutAttributes as? UpNextSlotLayoutAttributes else { return }
        setSlotNumber(attrs.slotNumber)
        needsLayout = true
    }
}

// MARK: - List Slot

/// The list's slot: a dashed row with the glyph where a film row's poster sits.
final class UpNextSlotListCell: UpNextSlotView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func update(slotNumber: Int) {
        setSlotNumber(slotNumber)
        if label.stringValue != Self.text { label.stringValue = Self.text }
    }

    private static let text = "Empty slot"

    // As wide as a film row's alternating stripe. In the `.inset` table the stripe runs from
    // 10 pt in at each edge of the row, while the cell sits 16 pt in (measured on a stock
    // NSTableView), so the stripe extends 6 pt beyond the cell on each side.
    override func outlineRect() -> CGRect { bounds.insetBy(dx: -Self.stripeOverhang, dy: 3) }
    private static let stripeOverhang: CGFloat = 6

    // Centered where GalleryListRow's 24 × 36 poster sits (8 pt leading inset).
    override func glyphRect(in outline: CGRect) -> CGRect {
        let side: CGFloat = 20
        return CGRect(x: GalleryListRow.contentInset + 12 - side / 2,
                      y: outline.midY - side / 2, width: side, height: side)
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        // 10 pt after the poster column, as GalleryListRow's HStack spacing puts the title.
        let x = GalleryListRow.contentInset + 24 + 10
        label.frame = CGRect(x: x, y: (bounds.height - height) / 2,
                             width: max(0, bounds.width - x - 8), height: height)
    }
}

// MARK: - Slot Sheet

/// Searches the library for a film to add to "Up Next", where it takes its sorted place. A standard
/// sheet: title bar, a fixed search field, the list gallery's own table (UpNextResultsTable,
/// 23.30) for the results, and a button gutter.
///
/// The search is plain title search only. The toolbar field's "#field" tokens are a
/// `.searchable` feature that needs a toolbar to host the field and its suggestion menu; a
/// sheet has none, so they are deliberately not offered here. Matching is the main search's
/// free-text rule (a film's title or alternate titles contain the text). Films already in
/// "Up Next" are not offered.
struct UpNextSlotSheet: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SheetCoordinator.self) private var sheetCoordinator
    @State private var model = UpNextSlotSearchModel()
    @State private var pendingConfirmation: UUID?
    /// Composed when the alert opens and never cleared, so the message does not go blank
    /// while the alert animates away after pendingConfirmation is reset.
    @State private var confirmationMessage = ""
    @State private var showUpNextFullAlert = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Add Film to \"Up Next\" Queue")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            UpNextSlotSearchField(onChange: { model.setQuery($0) },
                                  onMove: { model.moveSelection(by: $0) },
                                  onReturn: addSelected)
                .frame(height: 22)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button {
                    sheetCoordinator.dismissSheet()
                } label: {
                    Text("Close")
                        .padding(4)
                        .font(.system(size: 12))
                }
                .keyboardShortcut(.cancelAction)
                .focusable(false)

                Spacer()

                Button {
                    addSelected()
                } label: {
                    Text("Add to \"Up Next\"")
                        .padding(4)
                        .font(.system(size: 12))
                }
                // The default action, as the FilmSheet's: highlighted and bound to Return,
                // but only while a result is selected.
                .keyboardShortcut(.defaultAction)
                .focusable(false)
                .disabled(model.selectedFilmID == nil)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: Preferences.sheetSize, height: Preferences.sheetSize)
        .onAppear { model.load(coordinator: dataCoordinator) }
        .alert("Add to Queue", isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } })) {
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            Button("Add Anyway") {
                if let filmID = pendingConfirmation { commit(filmID) }
                pendingConfirmation = nil
            }
        } message: {
            Text(confirmationMessage)
        }
        .alert(FilmQueue.upNextFullTitle, isPresented: $showUpNextFullAlert) {
            Button("OK") { sheetCoordinator.dismissSheet() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(FilmQueue.upNextFullMessage(adding: 1, vacancies: 0))
        }
    }

    @ViewBuilder
    private var results: some View {
        if !model.hasQuery {
            placeholder("Search for films to add to your \"Up Next\" Queue.")
        } else if model.results.isEmpty {
            placeholder("No results.")
        } else {
            UpNextResultsTable(films: model.results,
                               selectedID: model.selectedFilmID,
                               onSelect: { model.selectedFilmID = $0 },
                               onActivate: { add($0) })
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .padding(10)
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

    private func addSelected() {
        guard let filmID = model.selectedFilmID else { return }
        add(filmID)
    }

    /// The sheet's add: the same capacity and special-sorting gates as every other path
    /// into "Up Next", with their alerts shown on the sheet itself.
    private func add(_ filmID: UUID) {
        // Deferred off the click or key event, as DetailsView defers its Queue alerts.
        DispatchQueue.main.async {
            if FilmQueue.upNextOverflow(adding: [filmID], coordinator: dataCoordinator) > 0 {
                showUpNextFullAlert = true
            } else if FilmQueue.addNeedsConfirmation([filmID], coordinator: dataCoordinator) {
                confirmationMessage = FilmQueue.addConfirmationMessage(
                    flaggedWith: dataCoordinator.getFilm(filmID)?.specialSorting ?? [])
                pendingConfirmation = filmID
            } else {
                commit(filmID)
            }
        }
    }

    private func commit(_ filmID: UUID) {
        guard FilmQueue.upNextOverflow(adding: [filmID], coordinator: dataCoordinator) == 0 else {
            showUpNextFullAlert = true
            return
        }
        FilmManager.addFilmsToList([filmID], listID: FilmQueueSection.upNext.listID,
                                   coordinator: dataCoordinator)
        FilmQueueAssignment.armPostMoveScroll([filmID], coordinator: dataCoordinator)
        sheetCoordinator.dismissSheet()
    }
}

// MARK: Model

/// The sheet's search state. The candidate pool (every film not already in "Up Next") is
/// captured once, in title order, with its lowercased titles from MetadataCache, so a
/// keystroke is one substring pass over the pool: no sorting, no snapshot copying, and no
/// debounce needed.
@MainActor
@Observable
final class UpNextSlotSearchModel {
    private struct Entry {
        let film: FilmSnapshot
        let name: String
        let alternate: String
    }

    @ObservationIgnored private var pool: [Entry] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var query = ""

    private(set) var results: [FilmSnapshot] = []
    /// True once the field holds text.
    private(set) var hasQuery = false
    var selectedFilmID: UUID?

    func load(coordinator: DataCoordinator) {
        guard !loaded else { return }
        loaded = true
        let upNext = FilmQueue.upNextFilmIDs(coordinator: coordinator)
        let films = coordinator.getAllFilms().filter { !upNext.contains($0.id) }
        let byID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ordered = MetadataCache.shared.sort(films.map(\.id), by: .title, direction: .ascending)
        pool = ordered.compactMap { id in
            guard let film = byID[id] else { return nil }
            let lowercased = MetadataCache.shared.getLowercasedStrings(for: id)
            return Entry(film: film,
                         name: lowercased?.name ?? film.name.lowercased(),
                         alternate: lowercased?.alternateTitle
                            ?? film.alternateTitle.joined(separator: " ").lowercased())
        }
    }

    func setQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed != query else { return }
        query = trimmed
        hasQuery = !trimmed.isEmpty
        results = trimmed.isEmpty ? []
            : pool.filter { $0.name.contains(trimmed) || $0.alternate.contains(trimmed) }.map(\.film)
        if let id = selectedFilmID, !results.contains(where: { $0.id == id }) {
            selectedFilmID = nil
        }
    }

    /// Up/Down in the search field: moves the selection through the results.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = selectedFilmID.flatMap { id in results.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), results.count - 1) }
            ?? (delta > 0 ? 0 : results.count - 1)
        selectedFilmID = results[next].id
    }
}

// MARK: Search Field

/// A plain NSSearchField: text out on every keystroke, Return to add the selected film, and
/// Up/Down to move the selection without leaving the field.
private struct UpNextSlotSearchField: NSViewRepresentable {
    let onChange: (String) -> Void
    let onMove: (Int) -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search all films"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.focusRingType = .default
        // First responder once the sheet is up, so typing starts searching at once.
        DispatchQueue.main.async { unsafe field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: UpNextSlotSearchField?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent?.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent?.onReturn()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent?.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent?.onMove(-1)
                return true
            default:
                return false
            }
        }
    }
}
