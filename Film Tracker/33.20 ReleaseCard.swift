// MARK: - ReleaseCard.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines ReleaseCardView — the individual release card rendered inside the
// FSTabReleasesView carousel — along with its private helper menu components.

import SwiftUI

// MARK: - Card Layout

enum ReleaseCardMetrics {
    static let labelWidth:            CGFloat = Preferences.filmSheetReleasesLabelWidth
    static let pickerWidth:           CGFloat = Preferences.standardPickerWidth
    static let colSpacing:            CGFloat = 12
    static let rowSpacing:            CGFloat = 8
    /// Gap between two controls sharing a row.
    static let controlSpacing:        CGFloat = 8
    /// Height reserved for the header's control area on EVERY card, whether or not that card
    /// carries a variant picker.
    ///
    /// Not cosmetic. Cards are centered vertically in the carousel, so a card a few points
    /// shorter than its neighbors sits at a different y — and every navigation slides one past
    /// the other, which is exactly where a small misalignment is most visible. Only merged combo
    /// packs carry the picker.
    ///
    /// 22 pt is that control's natural height at the regular control size, which is also the
    /// height the header had before the merge, so reserving it keeps card height unchanged from
    /// the previous build as well as uniform within this one.
    static let headerControlHeight:   CGFloat = 22
    /// Layout height of a pop-up menu (ReleasePopUpButton) at the regular control size: 20,
    /// see `SheetPopUpButton.layoutHeight` (30_20). The card's 28 pt row pitch
    /// (20 + `rowSpacing`) depends on it.
    static let popUpLayoutHeight:     CGFloat = ReleasePopUpButton.layoutHeight
}

/// One labeled row of the card: a fixed-width leading label, then whatever the caller puts
/// beside it.
///
/// Content is placed directly in the row's HStack rather than in a container, because several
/// rows are sensitive to added layout height (see _StudioRow) and the ones that do want a
/// container disagree on its spacing. `RowControls` supplies the common case.
private struct CardRow<Content: View>: View {
    private let label: Text
    private let content: Content

    /// `dimmed` marks a field locked by combo-pack inheritance.
    init(_ title: String, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = Text(title).foregroundStyle(dimmed ? Color.secondary : Color.primary)
        self.content = content()
    }

    /// For rows whose label has two independently-dimmed halves ("Type / Versions:").
    init(_ label: Text, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: ReleaseCardMetrics.colSpacing) {
            label
                .padding(.leading, 2)
                .frame(width: ReleaseCardMetrics.labelWidth, alignment: .leading)
            content
        }
    }
}

/// The usual pair-of-controls container beside a row label.
private struct RowControls<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: ReleaseCardMetrics.controlSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Text {
    /// Half of a two-part row label.
    func rowLabelSegment(dimmed: Bool) -> Text {
        foregroundStyle(dimmed ? Color.secondary : Color.primary)
    }
}

// MARK: - Fixed Value Text

/// A value the format fixes, standing in for the picker that would otherwise sit here.
///
/// Text rather than a disabled Picker on purpose: it conveys the same locked value without
/// adding another NSPopUpButton to a card that already carries ~50 controls.
///
/// The insets match a menu picker's own text position so the column still lines up, and they
/// live here rather than at each call site because the two sites had drifted 2 pt apart —
/// which made DVD cards taller than every other card, and card height has to be uniform (see
/// ReleaseCardMetrics.headerControlHeight).
struct FixedValueText: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.primary)
            .padding(.leading, 8)
            .padding(.top, 1)
            .padding(.bottom, 3)
            .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
    }
}

// MARK: - Tagged Picker

/// One entry of a `TaggedPicker`. `title` defaults to the stored tag; the two differ only
/// where the stored vocabulary is abbreviated ("OOP (cheap)" → "Out-of-print (cheap)").
struct ReleaseOption: Hashable, ExpressibleByStringLiteral {
    let tag: String
    let title: String

    init(_ tag: String, title: String? = nil) {
        self.tag = tag
        self.title = title ?? tag
    }

    init(stringLiteral value: String) { self.init(value) }
}

/// A pop-up menu that guarantees its bound value always has a matching item.
///
/// A menu whose selection matches no item would render blank over a real stored value. That
/// happens whenever a picker's option set depends on another control: the items rebuild on the
/// render pass that changed the other control, but the cascade clearing the now-invalid value
/// only runs after it, leaving one frame with no match.
///
/// Every site previously restated its own option list a second time as a "is the stored value
/// known?" check. Here the fallback item is derived from the same `options` array the menu is
/// built from, so the two cannot disagree. Values outside the vocabulary entirely keep their own
/// item rather than being masked, so they stay visible and selectable-away-from.
///
/// Backed by `ReleasePopUpButton` rather than a SwiftUI `Picker(.menu)`. See that type for the
/// measurements; the short version is that SwiftUI's picker costs ~0.6 ms per menu item to
/// build and ~0.2 ms per item on every update, and a card carries eight or nine of them.
struct TaggedPicker: View {
    @Binding var selection: String
    let options: [ReleaseOption]
    /// The empty-tag row. `nil` omits it, for a picker with no unset state.
    var placeholder: String? = nil
    var width: CGFloat = ReleaseCardMetrics.pickerWidth

    var body: some View {
        ReleasePopUpButton(selection: $selection,
                           items: ReleasePopUpButton.items(placeholder: placeholder,
                                                           options: options))
            .frame(width: width, height: ReleaseCardMetrics.popUpLayoutHeight,
                   alignment: .leading)
    }
}

// MARK: - Pop-up Button
//
// The card's single-select control is `SheetPopUpButton` (30_20), an `NSPopUpButton` driven
// directly in place of SwiftUI's `Picker(.menu)`; the rationale and measurements live with
// the type. This card was where the cost was measured — eight or nine menus with ~70 items
// between them were about half of the ~110 ms it took to mount a card.
typealias ReleasePopUpButton = SheetPopUpButton<String>

extension SheetPopUpButton where Value == String {
    /// The rows a `TaggedPicker` shows: the placeholder (as the empty tag) and the options.
    /// A bound value that matches none of them still gets its own row — appended by
    /// `SheetPopUpButton.effectiveItems`, not here; see that property's doc comment.
    static func items(placeholder: String?, options: [ReleaseOption]) -> [Item] {
        var items: [Item] = []
        if let placeholder { items.append(.option(tag: "", title: placeholder)) }
        for option in options { items.append(.option(tag: option.tag, title: option.title)) }
        return items
    }
}

// MARK: - Variant-swap-safe change observation
//
// THE HAZARD. A merged combo pack is ONE card whose `model` is swapped between the 4K parent
// and its bundled Blu-ray(s) by the header's segmented picker. The swap re-points the same view
// at a different object at the same position in the view tree — the card carries no `.id()`,
// deliberately, so switching segments reuses the layout tree rather than rebuilding fifty
// controls.
//
// `.onChange(of: model.someField)` cannot see that. All it compares is the value it read on the
// previous body evaluation against the value now, so a swap between two releases that simply
// hold DIFFERENT values for that field is indistinguishable from the user editing it — and the
// handler fires, running a cascade against a card the user never touched. It needs the parent
// and child to disagree about that particular field, which is ordinary for every field the
// combo-pack sync does not lock, which is why it surfaced on one release and not others.
//
// THE FIX. Pair the value with the identity of the model it was read from. A swap changes the
// id and the handler declines; a real edit keeps the id and it runs as before. Preferred over
// giving the card an `.id(model.id)` — which would also close the hole, by rebuilding the
// subtree instead of re-pointing it — because that would undo the layout-tree reuse the merged
// card is built around and put a structural rebuild inside the carousel's ambient spring.
private struct ModelField<Value: Equatable>: Equatable {
    let modelID: UUID
    let value: Value
}

private extension View {
    /// `.onChange(of:)` for a field on the card's current model, scoped so that it fires
    /// only for a genuine change of that field ON THE SAME RELEASE.
    ///
    /// Use this — never bare `.onChange(of: model.someField)` — for any handler that
    /// MUTATES state. A read-only handler is unaffected by a swap and does not need it.
    func onFieldChange<Value: Equatable>(
        of value: Value,
        on model: ReleaseCardModel,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        onChange(of: ModelField(modelID: model.id, value: value)) { old, new in
            // Different release: this is the variant picker swapping the card's content,
            // not an edit. The value did change, but not because anything happened to it.
            guard old.modelID == new.modelID else { return }
            action(old.value, new.value)
        }
    }
}

// MARK: - Release Card View
// Uses @Bindable on ReleaseCardModel (an @Observable class) rather than @Binding
// on a ReleaseFormData struct. Field writes go directly to model properties;
// @Observable invalidates only this card, never FSTabReleasesView.
// See FSTabReleases.swift for the full architectural rationale.
struct ReleaseCardView: View {
    @Bindable var model: ReleaseCardModel

    // MARK: - Header identity
    //
    // The badge and the "Release N" label name the CARD, not the release currently shown in it.
    // On a merged combo pack those differ: switching to a bundled Blu-ray changes `model`, but
    // the card is still the 4K release the user navigated to, and relabeling it "Blu-ray
    // Release 4" mid-inspection asserts the opposite of what the merge is for. Bundled discs
    // have no user-facing release number at all — see `variantLabels`.
    //
    // Supplied by the caller, which knows the entry; every card passes its PARENT's format and
    // display number, so an unmerged card is unaffected.
    let badgeFormat: String
    let displayIndex: Int

    // MARK: - Merged combo-pack variants
    //
    // A 4K combo-pack parent and the Blu-ray disc (or two) bundled with it are separate
    // releases in the data model but ONE card in the carousel, with the selector in the card's
    // own header.
    //
    // Passed in rather than derived here because the selection has to outlive the card: the
    // carousel's mount window unmounts off-screen cards and view-local @State would go with
    // them, so a user who switched a pack to its Blu-ray, navigated away, and came back would
    // find the parent showing again. The store lives on FSTabReleases.

    /// One label per variant, in segment order. EMPTY when this card is not a merged combo
    /// pack, which is what makes the picker conditional — the header adds nothing at all
    /// rather than reserving space for a control that will never appear.
    var variantLabels: [String] = []
    /// Index of the displayed variant within `variantLabels`. Meaningless (and ignored)
    /// while `variantLabels` is empty.
    var variantSelection: Int = 0
    var onSelectVariant: ((Int) -> Void)? = nil

    let onDelete: () -> Void
    // Reference to the owning view model — used only to schedule change checks and
    // to forward wishlist toggle actions; never read for rendering, so it never
    // subscribes this view to FSTabReleases.
    let viewModel: FSTabReleases

    // MARK: - Variant labels
    //
    // Derived from the entry rather than from each model in isolation: whether a bundled disc
    // needs a number is a property of the whole pack, not of any one release on it. A
    // single-disc pack reading "Blu-ray 1" would imply a second disc that does not exist, so a
    // lone child is named by its format alone and a dual-BD pack's two take "1" and "2".
    //
    // Not prefixed with "Included": that a bundled disc is part of this release is already said
    // by the segments sitting inside one card and by the "Included in Combo-pack" text on the
    // Purchased row, and saying it a third time inside a segmented control is what pushed the
    // picker wide. The numbers are per-pack ordinals, deliberately unrelated to the carousel's
    // release numbering.
    //
    // Returns [] for an unmerged entry, which is what suppresses the picker entirely.
    @MainActor
    static func variantLabels(for entry: ReleaseCarouselEntry) -> [String] {
        guard entry.isMerged else { return [] }
        let children = entry.children
        let numbered = children.count > 1
        return [entry.parent.format] + children.enumerated().map { offset, child in
            numbered ? "\(child.format) \(offset + 1)" : child.format
        }
    }

    // MARK: - Static sets (shared, allocation-free)
    // Non-private so the isolated sub-view struct _MarketAvailabilityPicker can reference it
    // without duplicating the data.
    //
    // `regionAOnlyOrigins` used to sit beside this and is gone: the Blu-ray region rule now
    // lives in ReleaseRegionRules (63_00), because syncComboChildFields has to apply the
    // identical rule when it pushes a country onto a combo-pack child and cannot reach a
    // private static on a view in this file.
    static let importOnlyTags: Set<String> = ReleaseMarketAvailability.importOnlyTags

    // MARK: - Shared static resources
    private static let controlBackground = Color(NSColor.controlBackgroundColor)
    private static let shadowColor       = Color.black.opacity(0.5)
    private static let cardShadowColor   = Color.black.opacity(0.2)

    // MARK: - Card chrome
    // The header sits on a full-bleed band tinted by the card's format, in the manner of the
    // right sidebar's purchase-tinted release cards (RSBCardChrome in 24_20). The color
    // change is itself the separation from the rows below, taking the place of the divider
    // that used to close the header; the divider's height and padding are kept as blank
    // inset so no row moves.
    //
    // Every value here is a `static let` chosen from `badgeFormat` — a plain stored property
    // set by the caller — so the band registers no model subscription and costs the body
    // nothing beyond one flat color fill.

    /// The card is inset by SwiftUI's default padding on all sides; stated so the header
    /// band and the rows below can carry the inset separately without either drifting.
    private static let cardInset: CGFloat = 16
    /// The band carries the card inset above and below the header, matching the card's
    /// other three edges. The header used to sit `rowSpacing` above its divider, so the
    /// band's lower edge now falls `cardInset - rowSpacing` further down than the divider
    /// did; that surplus is taken back out of the blank inset above the Purchased row, so
    /// the rows below the band are exactly where they always were.
    private static let bandGrowth: CGFloat = cardInset - ReleaseCardMetrics.rowSpacing
    /// What the header's closing `Divider()` and its `.padding(.bottom, 8)` measured.
    private static let formerDividerHeight: CGFloat = 1
    private static let formerDividerBottomPadding: CGFloat = 8

    /// Format tints. All three are opaque and dark enough for white lettering, so the same
    /// palette reads at home in both appearances the way `Preferences.darkGreen` and
    /// `.darkRed` do on the sidebar. The 4K band is deliberately darker than the card's own
    /// fill in dark mode (`controlBackgroundColor` sits near 0.12 there); the DVD band is the
    /// light end of the set, but still well below the gray that would wash out white text.
    private static let tint4K     = Color(red: 0.05, green: 0.05, blue: 0.06)
    private static let tintBluRay = Color(red: 0.10, green: 0.22, blue: 0.42)
    private static let tintDVD    = Color(white: 0.30)
    /// A format string this build does not recognize: the sidebar's neutral badge gray.
    private static let tintUnknown = Preferences.darkGray

    /// Format-badge plate and lettering, fixed rather than appearance-adaptive for the same
    /// reason as RSBCardChrome's: the badge has to read identically on every band and the
    /// band must never show through the glyphs. `Color.primary` on `windowBackgroundColor`
    /// would vanish in light mode, black on the 4K band's black.
    private static let badgePlate = Color(white: 0.93)
    private static let badgeInk   = Color(red: 0.11, green: 0.11, blue: 0.12)

    /// Outline shared with the sidebar cards: the reorderable lists' edge treatment with
    /// the strengths RSBCardChrome states, restated here rather than reaching into that
    /// file's private chrome.
    private static let borderWidth: CGFloat = FieldEdgeTreatment.borderWidth
    private static let borderOpacity: Double = 0.32
    private static let borderGradient = LinearGradient(
        stops: [
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity), location: 0.0),
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity),
                  location: FieldEdgeTreatment.borderFadeStart),
            .init(color: Color(NSColor.separatorColor).opacity(0), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private var bandTint: Color {
        switch ReleaseFormat(rawValue: badgeFormat) {
        case .uhd4K:  return Self.tint4K
        case .bluRay: return Self.tintBluRay
        case .dvd:    return Self.tintDVD
        case nil:     return Self.tintUnknown
        }
    }

    // MARK: - Body
    // Thin shell — each row is a named computed property or an isolated struct. This body
    // deliberately never reads model.contentHash: that read touches all 30+ fields and would
    // register every one as a dependency of the entire card, defeating per-property
    // invalidation. Change detection lives outside the view tree in ReleaseChangeObserver
    // (33_00). Cascade .onChange calls that mutate other fields remain inline on their specific
    // sub-views.
    //
    // The only model fields this body reads directly are `isComboChild` and the format tests,
    // neither of which changes for the life of a model. Every field that CAN change is read
    // inside the struct that owns the row — so a click on any control re-evaluates its own row
    // and no other, and in particular never re-diffs the eight or nine pop-up menus on the
    // rows around it.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, Self.cardInset)
                .padding(.vertical, Self.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bandTint)
            VStack(alignment: .leading, spacing: ReleaseCardMetrics.rowSpacing) {
            purchasedRow
            // Isolated struct (see _StudioRow below). It owns the studio picker, the
            // "Other" free-text field, and the two write-through handlers between them —
            // so its subscriptions to studioSelection and studioCustomText, both of which
            // those handlers must observe, stay off ReleaseCardView.body.
            _StudioRow(model: model)
            // Isolated struct (see _ReleaseYearRow below). It owns the mutual
            // release-year / base-release-year range validation, so its subscriptions
            // to releaseYear, baseReleaseYear, and their two hasValue flags — all of
            // which the validation must observe — stay off ReleaseCardView.body.
            _ReleaseYearRow(model: model, viewModel: viewModel)
            // Isolated struct (see _TypeVersionsRow below). Its Type picker's option set and
            // binding both read `independence`, so the subscription stays
            // off ReleaseCardView.body.
            _TypeVersionsRow(model: model, viewModel: viewModel)
            // MARK: Isolated sub-view structs
            // Each of the private structs below reads only the model fields it needs, so
            // @Observable registers those subscriptions against the STRUCT's body rather than
            // ReleaseCardView's. Changing model.audioFormat re-evaluates only _AudioRow. The
            // same pattern covers _CountryRow, _StudioRow, _ReleaseYearRow, _TraitsMenu,
            // _ArtworkPicker, _MarketAvailabilityPicker, and CardHelpButton.
            _CountryRow(model: model)
            videoRowView
            _AudioRow(model: model)
            traitsArtRow
            // Separates the rows describing the DISC from the rows describing this copy of
            // it as a purchase — price, availability, dates. Present on every card, so it
            // does not disturb the uniform card height the carousel depends on.
            Divider()
            // Isolated struct (see _PurchaseRows below). The two rows that branch on
            // `purchased`, and the purchased cascade, live there — so ticking the checkbox
            // re-evaluates those two rows rather than all twelve.
            _PurchaseRows(model: model, viewModel: viewModel)
            _NotesRow(model: model)
            }
            .padding(.horizontal, Self.cardInset)
            .padding(.bottom, Self.cardInset)
            // The divider, its bottom padding, and the row spacing that followed it, kept as
            // blank inset — less what the band grew by — so the Purchased row sits where it
            // always has.
            .padding(.top, Self.formerDividerHeight + Self.formerDividerBottomPadding
                     + ReleaseCardMetrics.rowSpacing - Self.bandGrowth)
        }
        .frame(maxWidth: .infinity)
        .background(Self.controlBackground)
        // Clipped before the outline is stroked so the band's fill and the outline meet
        // cleanly at the top corners, as on the sidebar cards.
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Self.borderGradient, lineWidth: Self.borderWidth))
        .shadow(color: Self.cardShadowColor, radius: 10, x: 0, y: 4)
    }

    // MARK: - Row sub-views

    private var headerRow: some View {
        HStack(spacing: ReleaseCardMetrics.colSpacing) {
            HStack(spacing: 6) {
                Text(badgeFormat)
                    .font(.system(size: 11, weight: .heavy))
                    .frame(width: 52, alignment: .center)
                    .padding(.vertical, 2)
                    .background(Self.badgePlate)
                    .foregroundStyle(Self.badgeInk)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(ReleaseLabel.short(number: displayIndex))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    // White on the dark tinted band, whichever appearance is active.
                    .foregroundStyle(.white)
                    // Suppress SwiftUI's default cross-fade when displayIndex changes
                    // (e.g. after a deletion renumbers cards). Without this, the old
                    // label fades out at the new position independently of the card,
                    // making it appear to float. .identity swaps the content instantly.
                    .contentTransition(.identity)
            }
            .frame(width: ReleaseCardMetrics.labelWidth, alignment: .leading)
            HStack(spacing: ReleaseCardMetrics.controlSpacing) {
                // MARK: Variant picker
                //
                // Occupies the space the Purchased/Wishlist controls used to. Present ONLY on
                // a merged combo pack; `variantLabels` is empty for every other card, which is
                // why the enclosing HStack carries a fixed height — see below.
                if !variantLabels.isEmpty {
                    // An AppKit segmented control, as the sheet's other segmented pickers
                    // are — see SheetSegmentedControl (30_20).
                    SheetSegmentedControl(selection: Binding(
                        get: { variantSelection },
                        set: { onSelectVariant?($0) }
                    ), segments: variantLabels.enumerated().map { .init($0.offset, $0.element) })
                    .frame(maxWidth: 320)
                    .focusable(false)
                    // MARK: Why the swap is not animated
                    //
                    // Changing segments replaces roughly fifty controls' worth of layout tree,
                    // and the card sits under the carousel's ambient spring transaction, which
                    // would animate that swap for free at the worst possible moment — a segment
                    // clicked while the carousel is still settling. `.animation(nil, value:)`
                    // refuses the inherited transaction rather than merely not adding one.
                    //
                    // An instant swap is the honest affordance besides: the segments are not
                    // two states of one thing, they are a selector over two different discs.
                    .animation(nil, value: variantSelection)
                }
                Spacer()
                // MARK: Delete
                //
                // One button, always live. It deletes the CARD — which for a merged combo pack
                // is the whole pack, parent and bundled discs together, whichever variant
                // happens to be on screen; deleteRelease cascades to the children.
                //
                // There used to be a second, disabled treatment for a card that IS a combo-pack
                // child, explaining that the 4K master had to go first. Merging ended it: a
                // child is a SEGMENT inside its parent's card and is never rendered as a card
                // of its own, so the branch became unreachable — and buildCarouselEntries
                // promotes an ORPHANED child to a top-level card, where the lock would be
                // exactly wrong. Both the branch and the debug override that defeated it are
                // gone rather than left as a safety net that no longer catches anything.
                Button(role: .destructive, action: onDelete) {
                    Circle()
                        .fill(Preferences.red)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "minus")
                                .foregroundStyle(.white)
                                .font(.system(size: 12, weight: .bold))
                                .shadow(color: Self.shadowColor, radius: 0.5, x: 0, y: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            // MARK: Fixed height — keeps every card the same height
            //
            // Only merged combo packs carry the variant picker, so without this the header
            // would be an NSSegmentedControl taller on those cards than on standalone ones,
            // and cards are centered vertically in a carousel that slides one past another.
            //
            // A fixed height rather than a minimum, set to the segmented control's own natural
            // height (ReleaseCardMetrics.headerControlHeight): if that estimate is ever low,
            // SwiftUI overflows the frame rather than clipping, so the picker still draws in
            // full and the ROW height stays identical across cards either way.
            .frame(height: ReleaseCardMetrics.headerControlHeight)
        }
    }

    /// The Purchased checkbox, in the row the header's segmented picker vacated.
    ///
    /// A checkbox rather than the former "Purchased / Unpurchased" segmented pair: the field is
    /// a plain Bool, and a two-segment picker over a Bool spends a full picker's width
    /// restating what a checkbox says in a glyph. The purchased cascade is unchanged — it hangs
    /// off `model.purchased` on the card body, not off the control that writes it.
    private var purchasedRow: some View {
        CardRow("Purchased:", dimmed: model.isComboChild) {
            // A plain HStack rather than RowControls: the label sits directly beside the
            // checkbox at the card's usual control spacing, which RowControls would add to
            // rather than supply, since it spaces its children itself.
            HStack(spacing: 0) {
                SheetCheckbox(isOn: $model.purchased)
                    // Combo-pack children mirror the parent's purchased state. The
                    // representable mirrors this onto the NSButton as `isEnabled` plus
                    // `refusesFirstResponder`, so a disabled checkbox is neither clickable
                    // nor a Tab stop and never draws a focus ring — see SheetCheckbox (30_20).
                    .disabled(model.isComboChild)
                if model.isComboChild {
                    Spacer().frame(width: ReleaseCardMetrics.controlSpacing)
                    // Deliberately .primary even though the checkbox beside it is disabled and
                    // the row label is dimmed. Those two are dimmed because they are inert
                    // CONTROLS; this is a statement of fact about the release, and it is also
                    // the only thing on the card explaining why the checkbox cannot be clicked,
                    // so graying it out would mute the one element carrying the explanation.
                    //
                    // Applied to the Text rather than inherited: a disabled ancestor would
                    // override it.
                    Text("Included in Combo-pack")
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The traits menu and the artwork picker.
    ///
    /// This row is what the "Aspect Ratio / Art:" row became once the aspect-ratio menu
    /// moved up beside the video controls, freeing the first column for the collected
    /// traits. See `_TraitsMenu` for what the traits are and why they are one control.
    private var traitsArtRow: some View {
        CardRow(Text("Misc. Traits / ").rowLabelSegment(dimmed: false)
                + Text("Art:").rowLabelSegment(dimmed: model.isComboChild)) {
            RowControls {
                // Isolated struct — its subscriptions (remastered, wishlist, hasSubtitles,
                // scanningMethod, masterType, replicationType, format, isComboChild) are
                // registered against its own body, not ReleaseCardView.body.
                _TraitsMenu(model: model, viewModel: viewModel)
                // _ArtworkPicker is an isolated struct — its @Observable subscriptions
                // (independence, purchased, hasArtwork, isComboChild) are registered
                // against its own body, not ReleaseCardView.body.
                _ArtworkPicker(model: model)
            }
        }
    }

    // The Video row carries the aspect-ratio menu in its second column, which the
    // scanning-method / master-type pickers vacated when they became traits. It is therefore
    // rendered for EVERY card, including a format this build does not recognize — that case
    // used to render no row at all, which is still right for the format-specific first column
    // but would now also hide the aspect ratio, a field unrelated to the format.
    private var videoRowView: some View {
        CardRow("Video:") {
            RowControls {
                videoControls
                MultiSelectMenu(selection: $model.releaseAspectRatio,
                                vocabulary: .aspectRatios,
                                placeholder: "Select Aspect Ratio…")
                    .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
            }
        }
    }

    /// The two video vocabularies as menu options. The tags come from ReleaseHDR and
    /// ReleaseVideoFormat, mapped to options here rather than declared there: ReleaseOption is
    /// a control type, and the model layer that owns the vocabulary must not depend on it.
    /// Every tag doubles as its own title, so the map carries no second string to keep in
    /// step. Static, as _AudioRow's lists are: both are fixed, so mapping them per render
    /// buys nothing.
    private static let hdrOptions: [ReleaseOption] =
        ReleaseHDR.pickerOptions.map { ReleaseOption($0) }
    private static let bluRayCodecOptions: [ReleaseOption] =
        ReleaseVideoFormat.bluRayPickerOptions.map { ReleaseOption($0) }

    @ViewBuilder
    private var videoControls: some View {
        // Both branches use TaggedPicker rather than a bare menu over hard-coded tags:
        // `hasHDR` and `videoFormat` are persisted verbatim and read back with no
        // membership check, so a restored or hand-edited record can carry a value this
        // build does not offer — which a plain menu renders as a blank control over a
        // real stored value. See TaggedPicker.
        switch model.releaseFormat {
        case .uhd4K:
            // masterType moved to the traits menu as "Upscaled 4K Master".
            TaggedPicker(selection: $model.hasHDR,
                         options: Self.hdrOptions,
                         placeholder: "Select HDR…")

        case .bluRay:
            // scanningMethod moved to the traits menu as "Interlaced".
            TaggedPicker(selection: $model.videoFormat,
                         options: Self.bluRayCodecOptions,
                         placeholder: "Select Codec…")

        // Its former second value ("Interlaced") is now the locked trait of the same name.
        case .dvd:
            FixedValueText(ReleaseVideoFormat.mpeg2)

        // Unknown format: hold the column so the aspect-ratio menu still lands in the
        // second one rather than sliding under the row label.
        case nil:
            Color.clear
                .frame(width: ReleaseCardMetrics.pickerWidth, height: 1)
        }
    }

}

// MARK: - Equatable (parent-render skip)
// The carousel's cardStack ForEach re-evaluates on every navigation step (it reads the current
// index for each slot's opacity and zIndex) and reconstructs every ReleaseCardView with
// a freshly allocated onDelete closure. Without an Equatable conformance SwiftUI cannot prove
// the reconstructed struct is unchanged, so it re-evaluates EVERY mounted card's body on every
// navigation — rebuilding ~12 rows of NSView-backed controls per card at the exact moment the
// container spring needs the main thread. That churn is pure waste: the slide/fade is driven
// entirely by the .offset/.opacity/.zIndex modifiers applied OUTSIDE this view.
//
// A card's visible content is fully determined by three inputs:
//   • model         — compared by object identity (===). The releases array holds stable
//                     references for the carousel's lifetime, so identity is the strictest
//                     correct test: a genuinely new instance for the same id forces a rebuild,
//                     whereas an id-only comparison could wrongly skip it.
//   • displayIndex  — so renumbering after a deletion re-renders the affected cards.
//   • variantLabels — the one that is easy to miss. A combo pack promoted from one bundled
//                     Blu-ray to two changes the SEGMENTS without changing which variant is
//                     displayed, so model and displayIndex both stay put and the comparison
//                     would wrongly report equality. `variantSelection` needs no term: selecting
//                     a different segment swaps the model reference, which identity catches.
//
// onDelete and viewModel are intentionally excluded: viewModel is a stable reference never read
// during body, and onDelete's behavior is fully determined by the three inputs above.
//
// This does NOT suppress content updates. @Observable invalidation is a separate path: when a
// field the card reads changes, SwiftUI re-runs the body regardless of Equatable — == only
// gates redundant parent-push re-renders.
//
// Isolation note: in Swift 6 a SwiftUI View is @MainActor-isolated, so its stored properties
// cannot be read from the nonisolated == that Equatable requires. SwiftUI always performs
// view-equality comparisons on the main actor, so MainActor.assumeIsolated safely asserts that.
extension ReleaseCardView: Equatable {
    nonisolated static func == (lhs: ReleaseCardView, rhs: ReleaseCardView) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model
                && lhs.badgeFormat == rhs.badgeFormat
                && lhs.displayIndex == rhs.displayIndex
                && lhs.variantLabels == rhs.variantLabels
        }
    }
}

// MARK: - Card Help Button (Navigation-Dismissing)
// Wraps HelpPopoverButton and sources its dismissToken from the carousel's current card index.
// Reading that inside THIS dedicated view's body isolates the @Observable subscription to
// viewModel.currentIndex to a small wrapper.
//
// Without the isolation (the read was previously inline in headerRow and releaseYearRow), it
// registers currentIndex as a dependency of the ENTIRE card body — so every carousel navigation
// would re-evaluate every visible card's full body, rebuilding both CustomDatePickers and all
// pickers exactly when the container's spring needs the main thread. Dismiss-on-navigation
// behavior is unchanged: the token still changes every navigation.
//
// The former `format` parameter is gone. It selected a per-format carousel index back when each
// format had its own stack; there is one stack now, and the parameter had been unread since.
//
// The RAW `currentIndex` is read, deliberately, not the clamped `currentCardIndex`. The clamped
// accessor also reads `carouselEntries`, which would subscribe this wrapper to every structural
// change in the tab — an add, a delete, a combo pack gaining a disc — none of which is
// navigation. The token only has to CHANGE when the position does; it is never interpreted as
// an index.
private struct CardHelpButton: View {
    let helpText: String
    // Double to match HelpPopoverButton, which this forwards to unchanged.
    var autoDismissDuration: Double = 10
    let viewModel: FSTabReleases

    var body: some View {
        HelpPopoverButton(
            helpText: helpText,
            autoDismissDuration: autoDismissDuration,
            dismissToken: AnyHashable(viewModel.currentIndex)
        )
    }
}

// MARK: - Studio Row (Observation Isolation)
//
// The studio picker, the "Other" free-text field, and the two write-through handlers that keep
// `model.studio` in agreement with them. Subscriptions to studioSelection, studioCustomText,
// and isComboChild are registered against _StudioRow.body rather than ReleaseCardView.body.
//
// MARK: Why this row in particular
//
// The two handlers below use `onFieldChange`, which builds its `ModelField` comparand FROM THE
// BODY — so `of: model.studioCustomText` is a genuine value read in whatever body the modifier
// is attached to. While this row was a computed property on ReleaseCardView, that read belonged
// to the card: every keystroke in the "Other" field invalidated all twelve rows, both
// MultiSelectMenus (thirty Toggles, each with a freshly allocated Binding), both
// CustomDatePickers, and every Picker — for a change that alters one text field and one
// opacity.
//
// That made it the only remaining per-KEYSTROKE field read on the card body. The other
// body-level reads each gate a branch in another row and change on a click rather than a
// character. `model.notes` looks similar but is only ever reached through a Binding, which
// registers its read inside the TextField.
//
// MARK: Variant-swap safety is unchanged
//
// The card carries no `.id()`, so a variant swap on a merged combo pack re-points this struct
// at a different model at the same position rather than rebuilding it. `onFieldChange`'s
// modelID term is what declines in that case, and it is carried in here verbatim.
private struct _StudioRow: View {
    @Bindable var model: ReleaseCardModel

    /// The studio menu's rows: the placeholder, then `ReleaseStudio`'s three tiers — each
    /// already alphabetized — with a divider ahead of every tier after the first, and a
    /// final divider before "Other". `ReleaseStudio.sections` is the source of the tier
    /// boundaries; nothing here decides where they fall.
    private static let studioItems: [ReleasePopUpButton.Item] =
        [.option(tag: "", title: "Select Studio…")]
        + ReleaseStudio.sections.enumerated().flatMap { index, section in
            (index == 0 ? [] : [.separator])
                + section.map { ReleasePopUpButton.Item.option(tag: $0.name, title: $0.name) }
        }
        + [.separator, .option(tag: "Other", title: "Other")]

    var body: some View {
        // Flat siblings, no RowControls: even a sized, non-flexible inner container adds
        // implicit height that inflates this row. The −4 trailing padding on the menu
        // brings the 12 pt row spacing down to the 8 pt other two-control rows use.
        CardRow("Studio:", dimmed: model.isComboChild) {
            ReleasePopUpButton(selection: $model.studioSelection, items: Self.studioItems)
            .frame(width: ReleaseCardMetrics.pickerWidth,
                   height: ReleaseCardMetrics.popUpLayoutHeight, alignment: .leading)
            .padding(.trailing, -4)
            // Locked on combo-pack children (studio mirrors the parent 4K release).
            .disabled(model.isComboChild)
            .onFieldChange(of: model.studioSelection, on: model) { _, newSelection in
                if newSelection == "Other" {
                    // Entering "Other": fires both on genuine user selection and programmatically
                    // during load via initializeStudioUI(). In both cases studioCustomText is
                    // already set correctly before this handler runs (initializeStudioUI assigns
                    // studioCustomText before studioSelection for exactly this reason), so
                    // model.studio is always written with the correct pre-existing value.
                    model.studio = model.studioCustomText
                } else {
                    // Leaving "Other" (or selecting any concrete option): write the concrete
                    // value and clear the custom text field. The studioCustomText onChange handler
                    // guards on studioSelection == "Other" and is therefore a no-op here, so the
                    // order of these two assignments does not affect the final model.studio value.
                    model.studio = newSelection
                    model.studioCustomText = ""
                }
            }
            // In the tree only while "Other" is selected. It used to be always present and
            // opacity-toggled, on the theory that the row height had to be held — but the
            // menu beside it is already the row's 22 pt, so the row is the same height with
            // or without the field, and an NSTextField that is invisible on nineteen cards
            // in twenty is a real view AppKit still creates, lays out, and walks. Height
            // pinned to the same 22 pt so the roundedBorder TextField's internal vertical
            // padding cannot inflate the row when it is present.
            if model.studioSelection == "Other" {
                TextField("Studio name", text: $model.studioCustomText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: ReleaseCardMetrics.pickerWidth,
                           height: ReleaseCardMetrics.headerControlHeight)
                    // The field is 22 pt and the row is the menu's 20; the same −1 pt
                    // vertical padding the whole row used to carry, applied to the one
                    // control that needs it, so the field overhangs the row by a point at
                    // each edge exactly as it always has and the card's height never moves
                    // when it appears.
                    .padding(.vertical, -1)
                    .disabled(model.isComboChild)
                    .onFieldChange(of: model.studioCustomText, on: model) { _, newText in
                        // Write through to the canonical studio field only when "Other" is
                        // the active selection. Switching away from "Other" clears
                        // studioCustomText as cleanup; this field has left the tree by the
                        // pass that runs the clear, and the guard covers the case where it
                        // has not, so the clear can never overwrite model.studio with ""
                        // after the concrete selection has already been committed.
                        guard model.studioSelection == "Other" else { return }
                        model.studio = newText
                    }
            }
        }
    }
}

// MARK: - Release Year Row (Observation Isolation + Mutual Range Validation)
// Subscriptions to the four year fields plus numberOfDiscs, format, and isComboChild are
// registered against _ReleaseYearRow.body rather than ReleaseCardView.body. Isolation matters
// more here than for a presentational row: the ordering rule has to OBSERVE all four year
// fields to react to them, and registering those on the full card body would re-evaluate every
// picker on the card on each stepper click.
//
// MARK: The ordering rule
// baseReleaseYear names the earliest permutation this release reissues, so it must fall
// strictly before releaseYear. Enforcement is split deliberately across two layers:
//
//   1. Reachability (here) — the base year's Stepper range is capped at releaseYear - 1, so no
//      illegal base year is reachable by stepping. The base year cycles the years between the
//      range floor and that cap, wrapping back to the floor at the top instead of pushing the
//      release year up.
//   2. Value correction (ReleaseCardModel.enforceReleaseYearOrder) — the authoritative
//      invariant, driven by the .onChange handlers below. It also covers the paths a range
//      cannot: field activation, a release year stepped down onto a committed base year,
//      parent→child sync, and load.
//
// Both layers move the SAME field. The release year is entered first and names the release the
// card is about, so it is never rewritten to make room; the base year is capped on the way up
// and dragged down (or cleared, at the floor) on the way down. Layer 1 makes the interaction
// feel right, layer 2 makes it correct; neither is redundant. The model is the single source of
// truth, so a correction applied by any path is reflected in both Steppers.
private struct _ReleaseYearRow: View {
    @Bindable var model: ReleaseCardModel
    // Forwarded to CardHelpButton only; never read here, so this row never
    // subscribes to FSTabReleases.
    let viewModel: FSTabReleases

    var body: some View {
        // purchaseYearRange is evaluated once and narrowed per-stepper below, avoiding
        // repeated property reads that would each open an @Observable subscription.
        let fullRange = model.purchaseYearRange

        // MARK: Explicit observation of baseReleaseYear
        //
        // Every other field this row displays is read somewhere in the logic below, which is
        // what registers it with @Observable. `baseReleaseYear` was the exception: the row only
        // passed `$model.baseReleaseYear` to CustomDatePicker, and forming a Binding does NOT
        // read the property — so nothing in the view tree observed the value itself.
        //
        // That left the base-year Stepper's displayed number dependent on some OTHER field
        // changing in the same pass. It holds for the common corrections, but not for a write
        // touching the base year alone — syncComboChild's post-sync enforcement pass, or a
        // load-time repair — after which the Stepper kept showing the year it was last
        // rendered with while the model held another.
        //
        // The read is deliberate and its result deliberately unused.
        _ = model.baseReleaseYear

        // MARK: Base-year availability
        // The base year is offerable only when a year strictly earlier than the release year
        // exists inside the range. Two conditions, and the second is the one the original
        // gating (`!model.hasReleaseYear` alone) missed:
        //
        //   • the release year must be committed — the base year qualifies it; and
        //   • the release year must sit above the range floor — if it is ON the floor, every
        //     year the base Stepper could reach is at or after it.
        //
        // Leaving the Stepper live in that second case offers a field that cannot hold a legal
        // value: every year it could reach is at or after the release year, so the rule would
        // clear it again immediately. It is the same condition enforceReleaseYearOrder tests
        // before clearing a committed base year, applied one step earlier — as a disabled
        // Stepper rather than a value that vanishes the moment it is committed.
        //
        // The condition subsumes the degenerate one-year range. It cannot strand a committed
        // base year either: when the release year is stepped onto the floor, the value layer
        // clears the base year in the same pass that disables this Stepper.
        let baseYearAvailable = model.hasReleaseYear && model.releaseYear > fullRange.lowerBound

        // MARK: Reachability cap on the base year
        //
        // The base year names a permutation that PRECEDES this release, so releaseYear - 1 is
        // its hard ceiling — and that ceiling is given to the Stepper as its range, not applied
        // afterwards as a correction. Wrapping is a property of the RANGE the Stepper is handed
        // (steppedYear wraps to the floor when it steps past `upperBound`), so a capped range
        // is what makes the up button at the ceiling wrap back down to the floor rather than
        // step past it. A 2010 release year on a Blu-ray thus cycles the base year 2006...2009
        // and wraps 2009 → 2006.
        //
        // This is the whole reason the release year is never carried upward by the base year
        // any more: an explicitly entered release year is not something a click on the OTHER
        // Stepper should overwrite. The relationship is kept by capping the subservient field
        // instead. (It also subsumes the combo-child case, where the release year is inherited
        // and its Stepper disabled — that card used to be the only one capped this way.)
        //
        // max() with the floor keeps the range constructible in the degenerate case where the
        // release year sits on the floor: the Stepper is disabled there anyway (see
        // baseYearAvailable), but a ClosedRange with upper < lower traps at construction,
        // disabled or not. The uncapped ceiling applies only while no release year is committed,
        // where the base-year Stepper is disabled as well.
        let baseCeiling: Int = {
            guard model.hasReleaseYear else { return fullRange.upperBound }
            return max(fullRange.lowerBound, min(fullRange.upperBound, model.releaseYear - 1))
        }()
        let baseRange = fullRange.lowerBound...baseCeiling

        // MARK: Row composition
        //
        // "Released / Discs:" — the two year steppers plus their help button in the first
        // column, and the disc-count stepper in the second.
        //
        // The first column is pinned to the standard picker width and its three controls are
        // distributed inside it with flexible spacers. Pinning rather than letting the controls
        // size themselves is what puts the disc stepper on the same vertical line as every
        // other second-column control on the card. The "/" separator between the year steppers
        // is gone with it: the gap does that work and the label carries the naming.
        //
        // A plain HStack rather than RowControls, whose only addition is a `maxWidth: .infinity`
        // frame this row does not need — and CardRow's own note warns that even a sized inner
        // container adds implicit height to rows sensitive to it.
        //
        // The two halves dim independently: a combo-pack child inherits its release year from
        // the parent, so "Released" grays out with the Stepper it names, while the disc count
        // remains the child's own field and "/ Discs:" stays primary.
        return CardRow(Text("Released").rowLabelSegment(dimmed: model.isComboChild)
                       + Text(" / Discs:").rowLabelSegment(dimmed: false)) {
            HStack(spacing: ReleaseCardMetrics.controlSpacing) {
            HStack(spacing: 0) {
                CustomDatePicker(
                    year: $model.releaseYear,
                    hasValue: $model.hasReleaseYear,
                    // The FULL range: the release year is the anchored field and is free to
                    // reach both bounds. Stepping it down onto the floor is legal and simply
                    // clears the base year (enforceReleaseYearOrder), which is what the former
                    // one-year narrowing of this range existed to prevent.
                    yearRange: fullRange
                ) {
                    model.hasReleaseYear = false
                }
                // Locked for combo-pack children (releaseYear mirrors the parent 4K release).
                .disabled(model.isComboChild)
                Spacer(minLength: 0)
                CustomDatePicker(
                    year: $model.baseReleaseYear,
                    hasValue: $model.hasBaseReleaseYear,
                    yearRange: baseRange,
                    // The un-activated placeholder shows the range's own ceiling rather than
                    // the current calendar year, and the activating click commits it.
                    //
                    // A year Stepper's placeholder is a statement about what the first click
                    // will produce, and for this one field that is not the current year: the
                    // base year can only be activated while a release year exists (see
                    // baseYearAvailable) and can only hold a year beneath it, so it activates
                    // at the cap. baseCeiling IS that cap, so passing it here keeps the
                    // placeholder tracking the release-year Stepper click for click.
                    //
                    // nil while no release year is committed — the Stepper is disabled and
                    // renders dashes there, and there is no cap to name.
                    placeholderYear: model.hasReleaseYear ? baseCeiling : nil
                ) {
                    model.hasBaseReleaseYear = false
                }
                // Gated on the release year existing. The base year names the earliest
                // permutation OF THIS RELEASE, so it is meaningless without the release it
                // qualifies, and the ordering rule has no anchor to order against. The
                // dependency is one-way: clearing the release year clears and disables this
                // field, while clearing the base year leaves the release year untouched.
                //
                // Not locked for combo-pack children — the included Blu-ray may be a reprint of
                // an earlier release — but still gated on a legal year existing beneath the
                // release year; see baseYearAvailable.
                .disabled(!baseYearAvailable)
                Spacer(minLength: 0)
                // 30-second auto-dismiss: the help text needs more reading time than the
                // default 10-second window.
                //
                // CardHelpButton sources its dismissToken from the carousel's current index, so
                // the popover closes whenever the user navigates to a different card.
                // HelpPopoverButton handles vertical-scroll dismissal separately via its own
                // minY observer; this token covers the horizontal case that minY cannot detect,
                // since a carousel slide moves the card in x only. The currentCardIndex read is
                // deliberately inside CardHelpButton's own body so navigation does not
                // invalidate this row — see CardHelpButton.
                CardHelpButton(
                    helpText: "Some releases are reissues of prior ones with slight variations, yet retain the same on-disc film version/mastering. The first field refers to this specific release, while the optional second field pertains to the earliest permutation of this release.",
                    autoDismissDuration: 30,
                    viewModel: viewModel
                )
                // No trailing Spacer. The three controls span the column's FULL width, so
                // the help button's right edge lines up with the right edge of every picker
                // above and below it; the two interior gaps absorb the slack instead. A
                // trailing spacer took an equal share of that slack and pulled the button
                // inward, which read as the row being narrower than the rest of the card.
            }
            .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
            // Second column: the disc count, which used to live on its own row alongside the
            // Subtitles checkbox and the Pressed/Recordable picker — both now traits.
            //
            // Centered as ONE unit: the Stepper and its unit label read as a single value, so
            // centering them individually would leave the value hanging off one side of an
            // otherwise empty column.
            HStack(spacing: ReleaseCardMetrics.controlSpacing) {
                StandardStepper(value: $model.numberOfDiscs, in: 1...10)
                // Unit label for the bare number the Stepper shows. Secondary because it
                // annotates the value rather than being one, and pluralized from the live
                // binding so it tracks each click.
                //
                // Sized to the LONGER of the two forms in both states, via a hidden "discs"
                // that reserves width with the live text overlaid on its leading edge.
                // Pluralization otherwise changed the width of the pair, and because the pair
                // is centered in the column, half that change moved the Stepper — the whole
                // unit visibly jumped as the user stepped between 1 and 2.
                //
                // A hidden sizer rather than a hard-coded width: the string widths are the
                // font's business and change with the user's text size. `.hidden()` keeps it
                // out of the accessibility tree too, so the label is announced once.
                Text("discs")
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(model.numberOfDiscs == 1 ? "disc" : "discs")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
            }
            .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .center)
            }
        }
        // MARK: Value-layer enforcement
        // Each handler names the field the user just moved as the anchor; the model holds that
        // value fixed and walks the other field to the nearest year that restores the ordering.
        // Re-entry is self-limiting: the corrective write fires these handlers once more, at
        // which point the ordering holds and enforceReleaseYearOrder returns on its fast path.
        //
        // All four are scoped to this release — see onFieldChange. `baseReleaseYear` and its
        // flag are explicitly NOT locked to the parent (a bundled disc may be a reprint of an
        // earlier release), so a merged card's two variants routinely disagree about them and
        // every variant swap used to run an enforcement pass against the release being switched
        // to.
        // The release year moved: the base year follows it down, or is cleared when the
        // release year lands on the range floor and leaves nothing beneath it.
        .onFieldChange(of: model.releaseYear, on: model) { _, _ in
            model.enforceReleaseYearOrder()
        }
        // The base year moved. Its Stepper range already forbids an illegal value, so this is a
        // backstop for the paths a range cannot cover — a stored value arriving from load or
        // restore, or a floor that rose under it.
        .onFieldChange(of: model.baseReleaseYear, on: model) { _, _ in
            model.enforceReleaseYearOrder()
        }
        // Activation transitions. The first click on an unset field commits its displayed
        // value without changing it (CustomDatePicker.shouldActivateInsteadOfIncrement), so no
        // value onChange fires and a conflict introduced purely by a field coming into
        // existence would go uncorrected until the next step. Either way the base year is the
        // field that gives way:
        //   • base activated — it commits at whatever year it was displaying, which may sit at
        //     or above the release year; the rule pulls it to releaseYear - 1. This is the path
        //     that lands an activation on 2009 under a 2010 release year. Its Stepper is only
        //     enabled when a legal year exists beneath the release year (see
        //     baseYearAvailable), so the correction always has somewhere to put it.
        //   • release activated — it commits at the current year, the range ceiling, so any
        //     base year already committed is already beneath it.
        .onFieldChange(of: model.hasReleaseYear, on: model) { _, isActive in
            guard isActive else {
                // Release year cleared: the base year has nothing left to qualify, so it is
                // cleared with it and its Stepper disabled. Writing the flag unconditionally
                // would be a redundant no-op write on every deactivation of an already-unset
                // base year, which .onChange(of: model.hasBaseReleaseYear) would then have to
                // absorb; the guard keeps this to the one case that needs it.
                if model.hasBaseReleaseYear { model.hasBaseReleaseYear = false }
                return
            }
            model.enforceReleaseYearOrder()
        }
        .onFieldChange(of: model.hasBaseReleaseYear, on: model) { _, isActive in
            guard isActive else { return }
            model.enforceReleaseYearOrder()
        }
    }
}

// MARK: - Type / Versions Row (Observation Isolation)
//
// The Type picker, whose option set depends on `independence` and `is4K`, its
// confirm-before-commit binding, and the Included Versions menu. (The independence cascade is
// FSTabReleases.commitIndependence.)
// Subscriptions to independence and isComboChild are registered against this struct's body
// rather than ReleaseCardView's, so a type change re-evaluates this row and no other.
private struct _TypeVersionsRow: View {
    @Bindable var model: ReleaseCardModel
    let viewModel: FSTabReleases

    /// The Type menu's rows. Built per body because two of them depend on the model — the
    /// arrays are four or five elements, and ReleasePopUpButton rebuilds its NSMenu only when
    /// the rows actually differ from the ones it built last.
    private var typeItems: [ReleasePopUpButton.Item] {
        var items: [ReleasePopUpButton.Item] = [
            .option(tag: "", title: "Select Type…"),
            .option(tag: ReleaseIndependence.standalone, title: "Standalone"),
        ]
        // "Combo-pack" is offered on 4K UHD cards only. A combo pack here is a 4K master
        // bundled with its Blu-ray copies — the parent/child pairing the value drives only ever
        // runs from a 4K parent and only ever produces Blu-ray children — so the value describes
        // the 4K disc's packaging. It is withheld from a standalone Blu-ray as well: a Blu-ray
        // inside a pack acquires the value by being made a child of its 4K parent, not by being
        // typed.
        //
        // The second disjunct is the tag-set guarantee, covering two live cases: every
        // combo-pack CHILD is a Blu-ray carrying exactly this value (its picker is disabled,
        // but it must still render), and any record typed "Combo-pack" by hand before this
        // build keeps its row so the user can pick their way out of it.
        if model.is4K || model.independence == ReleaseIndependence.comboPack {
            items.append(.option(tag: ReleaseIndependence.comboPack, title: "Combo-pack"))
        }
        // Dual-Blu-ray combo packs are a property of the 4K master, so the option is offered
        // on 4K UHD cards only. The second disjunct is the tag-set guarantee, not a feature: a
        // Blu-ray or DVD can only hold this value by way of a hand-edited or corrupt backup,
        // but if one does, keeping the row lets the card display it and the user pick out of it.
        if model.is4K || model.independence == ReleaseIndependence.comboPackDualBD {
            items.append(.option(tag: ReleaseIndependence.comboPackDualBD,
                                 title: "Combo-pack (dual BD)"))
        }
        items.append(.option(tag: ReleaseIndependence.multiPack, title: "Multi-pack"))
        return items
    }

    var body: some View {
        CardRow(Text("Type").rowLabelSegment(dimmed: model.isComboChild)
                + Text(" / Versions:").rowLabelSegment(dimmed: false)) {
            RowControls {
                // MARK: Confirm-before-commit binding
                //
                // The selection does NOT write straight through to the model. A change that
                // would discard edited combo-pack children has to be confirmed first, and the
                // only way for a canceled change to leave nothing behind is for nothing to have
                // happened yet. requestIndependenceChange applies the value itself when no
                // confirmation is needed, and otherwise defers the write until the user
                // confirms — so cancel has nothing to undo.
                //
                // Writing through a Binding rather than acting in .onChange is what makes that
                // possible: .onChange runs after the value is already committed, and every
                // cascade keyed to it has already fired by then.
                //
                // When a change needs confirming the binding's getter still reports the old
                // value after the setter returns, and ReleasePopUpButton re-selects whatever the
                // getter reports on that same turn — so the closed control never displays the
                // pending selection at all: no interim value, and so no change-then-change-back
                // flash to collide with the alert.
                //
                // This is why nothing here mirrors, shadows, or forces the displayed value.
                // Every previous attempt to correct the display after the fact was correcting a
                // divergence that only existed because something had been written.
                ReleasePopUpButton(selection: Binding(
                    get: { model.independence },
                    set: { newValue in
                        guard newValue != model.independence else { return }
                        // Commit any in-progress field edit BEFORE asking, because the
                        // decision depends on it: requestIndependenceChange reads the child
                        // models to judge whether a surplus child carries user work worth
                        // confirming, and a value still sitting in the field editor would read
                        // as untouched and be discarded without asking. Conditional, so it
                        // costs nothing when nothing is being edited.
                        commitPendingFieldEdit()
                        viewModel.requestIndependenceChange(on: model, to: newValue)
                    }
                ), items: typeItems)
                .frame(width: ReleaseCardMetrics.pickerWidth,
                       height: ReleaseCardMetrics.popUpLayoutHeight, alignment: .leading)
                // Combo-pack children have their independence locked to "Combo-pack".
                .disabled(model.isComboChild)
                // There is no `.id()` rebuild here any more. It cleared the NSPopUpButton
                // MENU's stale selected-item marking after a declined confirmation;
                // ReleasePopUpButton re-selects from the binding on the same turn as the
                // declined write, so the marking is never stale to begin with.
                //
                // No cascade here. Everything that follows from a Type change — the artwork
                // reset, the multi-pack flag, market availability, and the combo-pack
                // reconciliation — is applied by FSTabReleases.commitIndependence at the write
                // itself. It used to be an .onChange on this row, which only ran if the row
                // was mounted AND showing this release when the value landed.
                MultiSelectMenu(selection: $model.includedVersions,
                                vocabulary: .includedVersions,
                                placeholder: "Select Versions…")
                    .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
                    // Combo-pack children cannot change their included versions independently;
                    // this field is not in the locked set but is meaningless for a child card.
                    // We leave it editable (it has no locked-field constraint per spec).
            }
        }
    }
}

// MARK: - Purchase Rows (Observation Isolation)
//
// The two rows that branch on `purchased` — Cost / Lowest Price and Purchase Date / Date Last
// Seen — plus the purchased cascade. Both rows' subscriptions to purchased and independence,
// and the cascade's read of purchased, are registered against this struct's body rather than
// ReleaseCardView's: ticking the Purchased checkbox swaps two rows' subtrees and leaves the
// other ten untouched, where it used to re-evaluate the whole card.
//
// A VStack at the card's row spacing rather than a Group, so the cascade below attaches to ONE
// view — a modifier on a Group is applied to each of its elements, and the cascade would fire
// twice per toggle.
private struct _PurchaseRows: View {
    @Bindable var model: ReleaseCardModel
    let viewModel: FSTabReleases

    var body: some View {
        VStack(alignment: .leading, spacing: ReleaseCardMetrics.rowSpacing) {
            pricingRow
            datesRow
        }
        // Purchased cascade — clears or resets several fields when the toggle
        // switches. Kept as a separate .onChange because it performs mutations,
        // not just detection. Suppressed for combo-pack children: their purchased
        // state is locked to the parent and must not trigger independent field cascades,
        // which would clobber the parent-synced values (wishlist, marketAvailability, etc.).
        .onFieldChange(of: model.purchased, on: model) { _, newValue in
            guard !model.isComboChild else { return }
            if !newValue {
                // MARK: Artwork is cleared EXCEPT where it stays valid
                //
                // "Steelbook" is the one artwork tag _ArtworkPicker offers regardless of
                // purchased state — every other option is gated behind the Purchased control
                // and the Type picker, which is why the field is cleared here at all. Clearing
                // it unconditionally discarded a still-selectable value: un-ticking Purchased
                // on a steelbook silently deleted the fact that it is one, and re-ticking did
                // not bring it back.
                //
                // Same distinction the independence cascade (FSTabReleases.commitIndependence) draws with
                // `stayedWithinComboForms`: a cascade may retract a value the NEW vocabulary
                // cannot express, and must not retract one it still can.
                if model.hasArtwork != ReleaseArtwork.steelbook {
                    model.hasArtwork    = ""
                }
                model.cost              = 0.0
                model.amountSpent       = 0.0
                model.condition         = ReleaseCondition.new
                model.purchaseDate      = Date()
                model.hasPurchaseDate   = false
                // MARK: Both directions, not just the locking one
                //
                // The `if` arm applies the lock a non-4K combo-pack disc carries. The `else if`
                // retracts it, and is not symmetry for its own sake: this is the moment
                // _MarketAvailabilityPicker comes back into the tree, and the last point at
                // which a stranded "Combo-pack only" can still be caught.
                //
                // The picker's read-side clamp maps that tag to the placeholder when the
                // release is not combo-locked, but the clamp does not WRITE — it covers the
                // single frame between a tag set changing and the picker's own independence
                // cascade updating the value, and that cascade fires on a CHANGE to
                // independence. A value already wrong when the picker mounted never produces
                // one. So the tag survived behind a control showing "Select Availability…",
                // persisted on every save, and went on being displayed raw by the releases
                // table, the sidebar, and the wishlist report.
                //
                // Not reachable by ordinary editing, which is why it went unnoticed: the
                // purchase arm below clears the field on the way in. A restored or hand-edited
                // record can arrive holding it, and un-ticking Purchased is where the user
                // meets it. Cleared rather than substituted — there is no correct availability
                // to guess at.
                if (model.isBluRay || model.isDVD)
                    && ReleaseIndependence.isComboPack(model.independence) {
                    model.marketAvailability = [ReleaseMarketAvailability.comboPackOnly]
                } else if model.marketAvailability.first
                            == ReleaseMarketAvailability.comboPackOnly {
                    model.marketAvailability = []
                }
            } else {
                // Clearing the wishlist position goes through the same helper the Wishlisted
                // trait uses, so "leaving the wishlist" means one thing however it is reached.
                //
                // The helper vacates the slot and nothing more: positions are issued above
                // every position in use across the library, so a hole cannot cause the next
                // assignment to collide. (It used to compact this film's survivors to keep the
                // sequence gap-free, and that compaction was itself the collision, since it
                // renumbered across slots other films owned. See handleWishlistToggle.)
                //
                // Guarded on `> 0` so the common case stays a no-op and writes nothing.
                if model.wishlist > 0 {
                    viewModel.handleWishlistToggle(releaseID: model.id, isOn: false)
                }
                model.lowestPrice         = 0.0
                model.lowestPriceDate     = Date()
                model.hasLowestPriceDate  = false
                model.marketAvailability  = []
            }
        }
    }

    @ViewBuilder
    private var pricingRow: some View {
        // isComboDisabled: true for either combo-pack form on a non-4K release. The read
        // subscribes _PurchaseRows to model.independence, which is correct: changing
        // independence on a Blu-ray combo-pack card should re-render the cost labels.
        let isComboDisabled = ReleaseIndependence.isComboPack(model.independence) && !model.is4K
        if model.purchased {
            CardRow("Cost / Spent:", dimmed: isComboDisabled) {
                HStack(spacing: ReleaseCardMetrics.controlSpacing) {
                    // Locked for combo-pack children (cost mirrors the parent 4K release).
                    CurrencyInputField(value: $model.cost, isDisabled: isComboDisabled || model.isComboChild)
                    Text("/").foregroundStyle(!isComboDisabled ? .primary : .secondary)
                    CurrencyInputField(value: $model.amountSpent, isDisabled: isComboDisabled || model.isComboChild)
                }
            }
        } else {
            CardRow("Lowest Price:", dimmed: model.isComboChild) {
                HStack(spacing: ReleaseCardMetrics.controlSpacing) {
                    // Locked for combo-pack children (lowestPrice mirrors the parent 4K
                    // release). `isDisabled` is the whole of the lock, exactly as for the two
                    // fields in the purchased branch above: CurrencyInputField applies
                    // `.disabled(isDisabled)` to its own body on top of dimming the "$" and "."
                    // A second `.disabled(model.isComboChild)` used to sit here as well; it
                    // changed nothing and made the parameter read as styling-only.
                    CurrencyInputField(value: $model.lowestPrice, isDisabled: model.isComboChild)
                        .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
                    // _MarketAvailabilityPicker is an isolated struct — its @Observable
                    // subscriptions (independence, format, nationalOrigin, purchased,
                    // marketAvailability) are registered against its own body, not
                    // ReleaseCardView.body. Its nationalOrigin cascade lives inside the struct;
                    // the independence one is FSTabReleases.commitIndependence.
                    _MarketAvailabilityPicker(model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var datesRow: some View {
        // Evaluated once here and passed to both CustomDatePicker instances below,
        // avoiding two separate model.purchaseYearRange reads (each of which opens an
        // @Observable subscription and triggers a Calendar.current.component call).
        let yearRange = model.purchaseYearRange
        if model.purchased {
            CardRow("Purchase Date:", dimmed: model.isComboChild) {
                HStack(spacing: 12) {
                    CustomDatePicker(
                        date: $model.purchaseDate,
                        hasValue: $model.hasPurchaseDate,
                        yearRange: yearRange
                    ) {
                        model.hasPurchaseDate = false
                    }
                    // Locked for combo-pack children (disabled — not merely dimmed).
                    .disabled(model.isComboChild)
                    // Isolated struct (see _ConditionPicker below). It owns the read of
                    // model.condition that the out-of-vocabulary segment needs, so a New/Used
                    // click re-evaluates the segmented control alone rather than both of
                    // these rows.
                    _ConditionPicker(model: model)
                }
            }
        } else {
            CardRow("Date Last Seen:", dimmed: model.isComboChild) {
                CustomDatePicker(
                    date: $model.lowestPriceDate,
                    hasValue: $model.hasLowestPriceDate,
                    yearRange: yearRange
                ) {
                    model.hasLowestPriceDate = false
                }
                // Locked for combo-pack children (lowestPriceDate mirrors the parent 4K release).
                .disabled(model.isComboChild)
            }
        }
    }
}

// MARK: - Notes Row (Observation Isolation)
//
// The placeholder reads `independence`, which is exactly the field the Type picker writes;
// held here so that write re-evaluates this row and the Type row, not the card.
private struct _NotesRow: View {
    @Bindable var model: ReleaseCardModel

    var body: some View {
        let notesPlaceholder: String = (model.isBluRay
                                        && ReleaseIndependence.isComboPack(model.independence))
            ? "Notes, if different from 4K master release"
            : "Notes"
        return CardRow("Notes:") {
            TextField(notesPlaceholder, text: $model.notes)
                .textFieldStyle(.roundedBorder)
                .padding(.trailing, 2)
        }
    }
}

// MARK: - Country Row (Observation Isolation)
// Subscriptions to model.nationalOrigin, model.format, model.regionLock,
// model.regionLockBypass, and model.isComboChild are registered against _CountryRow.body, not
// ReleaseCardView.body, so changes to them re-evaluate only this struct. Absorbs the former
// countryRow and regionPickerView computed properties, cascades intact.
private struct _CountryRow: View {
    @Bindable var model: ReleaseCardModel

    /// Which Blu-ray region locks a country of origin permits.
    ///
    /// Delegates to `ReleaseRegionRules`, the single statement of the rule. It was written out
    /// three times inside this struct, and consolidating those was only half the job:
    /// `syncComboChildFields` has to apply the same rule when it pushes an origin onto a
    /// combo-pack child, and it is not a view and cannot reach into this file.
    private static func regionScope(for origin: String) -> (aOnly: Bool, bOnly: Bool) {
        ReleaseRegionRules.scope(for: origin)
    }

    /// The stored countries of origin, in menu order.
    ///
    /// Hoisted out of the picker's ViewBuilder so `TaggedPicker` can derive its
    /// unknown-value fallback from the same array the menu is built from — which is the
    /// whole of that type's guarantee. See the picker below.
    ///
    /// The names come from `ReleaseOrigin`, the one list of countries the app knows.
    private static let originOptions: [ReleaseOption] = ReleaseOrigin.names.map { ReleaseOption($0) }

    /// The DVD region list is fixed; the Blu-ray list depends on the origin and is built by
    /// `bluRayRegionOptions` per render.
    private static let dvdRegionOptions: [ReleaseOption] =
        ReleaseRegionRules.dvdTags.map { ReleaseOption($0) }

    var body: some View {
        CardRow("Country:", dimmed: model.isComboChild) {
            RowControls {
                // TaggedPicker rather than a bare Picker over hard-coded tags: the stored
                // vocabulary is not closed. `nationalOrigin` is persisted verbatim and read
                // back with no membership check, so a restored or hand-edited record can carry
                // a country this list does not offer — and a Picker whose selection matches no
                // tag logs an "invalid selection" fault and renders BLANK over a real stored
                // value, which then persists unseen on the next save.
                TaggedPicker(selection: $model.nationalOrigin,
                             options: Self.originOptions,
                             placeholder: "Select Country…")
                // Locked on combo-pack children (nationalOrigin mirrors the parent 4K release).
                .disabled(model.isComboChild)
                regionPickerBody
            }
        }
    }

    private static func bluRayRegionOptions(regionAOnly: Bool,
                                            regionBOnly: Bool) -> [ReleaseOption] {
        ReleaseRegionRules.bluRayTags(regionAOnly: regionAOnly, regionBOnly: regionBOnly)
            .map { ReleaseOption($0) }
    }

    @ViewBuilder
    private var regionPickerBody: some View {
        switch model.releaseFormat {
        // 4K is always region free.
        case .uhd4K:
            FixedValueText(ReleaseRegionRules.regionFree)

        case .bluRay:
            // Read-side clamp. The available tags depend on nationalOrigin, but the cascade
            // that clears a now-incompatible regionLock runs only AFTER the pass that rebuilt
            // the tag set — so the clamp shows the placeholder for that one frame. The stored
            // value is untouched; the cascade below still performs the canonical clear.
            //
            // A value outside the Blu-ray vocabulary entirely (a DVD region string from a
            // legacy backup) falls through unchanged and TaggedPicker gives it its own tag —
            // nothing will ever clear it, so masking it would hide a value that still persists.
            let (regionAOnly, regionBOnly) = Self.regionScope(for: model.nationalOrigin)
            let regionBinding = Binding<String>(
                get: {
                    switch model.regionLock {
                    case ReleaseRegionRules.regionA:
                        return regionBOnly ? "" : model.regionLock
                    case _ where ReleaseRegionRules.regionBTags.contains(model.regionLock):
                        return regionAOnly ? "" : model.regionLock
                    default:
                        return model.regionLock
                    }
                },
                set: { model.regionLock = $0 }
            )

            TaggedPicker(selection: regionBinding,
                         options: Self.bluRayRegionOptions(regionAOnly: regionAOnly,
                                                           regionBOnly: regionBOnly),
                         placeholder: "Select Region…")
            // Scoped to this release. This row is reached only on the Blu-ray branch, so
            // today a 4K↔Blu-ray swap rebuilds it rather than re-pointing it and these could
            // not misfire — but that immunity is an accident of which branch each variant
            // lands in, and `regionLock` is a child-owned field the variants may legitimately
            // disagree about. Scoping makes the safety intrinsic.
            .onFieldChange(of: model.regionLock, on: model) { _, newValue in
                model.regionLockBypass = (newValue == ReleaseRegionRules.looselyLockedTag)
            }
            .onFieldChange(of: model.nationalOrigin, on: model) { _, newOrigin in
                // Suppressed for combo-pack children: nationalOrigin is synced from the parent,
                // but regionLock is the child's own field — without this guard a parent country
                // change would clear it from a view that only happens to be mounted, which is
                // the wrong layer for a change arriving through the data path. syncComboChild
                // applies the identical predicate the moment it pushes the origin down.
                guard !model.isComboChild else { return }
                // The same predicate syncComboChild uses, and the same one the picker's
                // option list derives from — see ReleaseRegionRules.
                guard ReleaseRegionRules.isIncompatible(regionLock: model.regionLock,
                                                        origin: newOrigin) else { return }
                model.regionLock = ""
                // Only ever true for the loosely-locked tag, which the clear above has just
                // discarded, so the flag has nothing left to qualify.
                if model.regionLockBypass { model.regionLockBypass = false }
            }

        case .dvd:
            TaggedPicker(selection: $model.regionLock,
                         options: Self.dvdRegionOptions,
                         placeholder: "Select Region…")

        case nil:
            EmptyView()
        }
    }
}

// MARK: - Audio Row (Observation Isolation)
// Subscriptions to model.audioFormat, model.audioChannels, and model.format are registered
// against _AudioRow.body, not ReleaseCardView.body — and channelsLocked (derived from
// audioFormat) is computed in this struct's tracking scope — so changing the audio format
// re-evaluates only this row rather than the 12-row card body.
//
// The channel-lock cascade for Dolby Atmos / DTS:X observes via onFieldChange rather than a
// bare .onChange, so a variant swap on a merged combo card cannot present itself as a format
// edit.
private struct _AudioRow: View {
    @Bindable var model: ReleaseCardModel

    /// The formats that carry their channel layout in the bitstream rather than as a fixed bed,
    /// and for which the Channels picker is therefore locked to 7.1.
    ///
    /// The single definition of "object-based", so the control that LOCKS the field and the
    /// cascade that CLEARS it cannot drift apart — they were two copies of the same pair of
    /// string comparisons, which is how the cascade came to clear the field in a case the lock
    /// never applied to.
    private static func isObjectBased(_ audioFormat: String) -> Bool {
        ReleaseAudioFormat.isObjectBased(audioFormat)
    }

    // Derived inline — in scope here, isolated from ReleaseCardView.body.
    private var channelsLocked: Bool { Self.isObjectBased(model.audioFormat) }

    /// The two audio-format vocabularies. DVD carries the narrower one — the HD formats did not
    /// exist on the disc — which is what makes the tag-set guarantee load-bearing here rather
    /// than merely defensive: this is the one picker whose option list is a strict SUBSET of
    /// another branch's, so a value perfectly ordinary on one format is out-of-vocabulary on
    /// another. A DVD restored holding "DTS-HD MA" renders blank on a bare Picker.
    private static let dvdAudioFormats: [ReleaseOption] =
        ReleaseAudioFormat.dvdOptions.map { ReleaseOption($0) }
    private static let hdAudioFormats: [ReleaseOption] =
        ReleaseAudioFormat.hdOptions.map { ReleaseOption($0) }

    /// Channel layouts, in menu order. 7.1 is a non-DVD layout, so it is withheld there — and
    /// withholding a tag is exactly the condition TaggedPicker's fallback covers, both for a DVD
    /// restored holding "7.1" and for the bare integers DBRestorer's numeric coercion can
    /// produce ("7", "5"). Those match no branch's vocabulary at all; surfacing them keeps them
    /// visible and selectable-away-from instead of persisting behind a blank menu.
    ///
    /// Two `static let`s rather than a function, matching the two audio-format lists
    /// directly above: both branches are fixed, so building either one per render — which
    /// mapping the vocabulary to `ReleaseOption` on each call would do — buys nothing.
    private static let dvdChannelOptions: [ReleaseOption] =
        ReleaseAudioChannels.options(isDVD: true).map { ReleaseOption($0) }
    private static let hdChannelOptions: [ReleaseOption] =
        ReleaseAudioChannels.options(isDVD: false).map { ReleaseOption($0) }

    private static func channelOptions(isDVD: Bool) -> [ReleaseOption] {
        isDVD ? dvdChannelOptions : hdChannelOptions
    }

    var body: some View {
        CardRow("Audio:") {
            RowControls {
                if model.isDVD {
                    TaggedPicker(selection: $model.audioFormat,
                                 options: Self.dvdAudioFormats,
                                 placeholder: "Select Format…")
                } else {
                    TaggedPicker(selection: $model.audioFormat,
                                 options: Self.hdAudioFormats,
                                 placeholder: "Select Format…")
                    // Scoped to this release — see onFieldChange. Switching the card to a
                    // bundled Blu-ray and back is not an edit of the audio format, and
                    // used to run this cascade against whichever release was switched TO:
                    // returning to a 7.1 parent whose format is not object-based landed in
                    // the clear arm below and blanked its channels.
                    .onFieldChange(of: model.audioFormat, on: model) { oldValue, newValue in
                        // Cascade: lock channels to 7.1 for object-based formats.
                        if Self.isObjectBased(newValue) {
                            model.audioChannels = ReleaseAudioChannels.surround71
                        } else if Self.isObjectBased(oldValue),
                                  model.audioChannels == ReleaseAudioChannels.surround71 {
                            // Clear ONLY on the way out of an object-based format, where the
                            // 7.1 in the field was placed by the arm above and the picker was
                            // disabled — so it is this cascade's own value to retract.
                            //
                            // Testing the OLD value is the whole of the fix. Without it any
                            // move between two non-object formats that both legitimately carry
                            // 7.1 — DTS-HD MA to Dolby TrueHD, TrueHD to LPCM — silently
                            // discarded a layout the user had selected on an enabled picker.
                            model.audioChannels = ""
                        }
                    }
                }
                TaggedPicker(selection: $model.audioChannels,
                             options: Self.channelOptions(isDVD: model.isDVD),
                             placeholder: "Select Channels…")
                .disabled(channelsLocked)
            }
        }
    }
}

// MARK: - Traits Menu (Observation Isolation)
//
// The one control behind six previously-scattered fields: Remastered, Wishlist, the
// Progressive/Interlaced picker, the Native 4K/Upscaled picker, Subtitles, and the
// Pressed/Recordable picker.
//
// MARK: Why these six and not others
//
// Every one is a BOOLEAN dressed differently. Three were literal checkboxes; the other three
// were two-segment pickers over a field whose vocabulary has exactly two values, one of which
// is the default a new release is created with. So each field's whole information content is
// "is this release the non-default one?", and a two-segment picker spends a full picker's
// width saying that. Because a new release holds every one of those defaults, "Select Traits…"
// accurately describes a fresh card — with one deliberate exception: a DVD is born interlaced,
// so its menu opens reading "Interlaced".
//
// MARK: Why the selection is not a [String] like the other two multi-select menus
//
// `MultiSelectMenu` binds to a stored array because Included Versions and Aspect Ratio
// genuinely ARE arrays of vocabulary strings. These traits are not: they are six fields of
// three different shapes (`Bool`, a two-value `String`, an `Int` wishlist position), each with
// its own write path — the wishlist one is not even a plain assignment. So the trait list is
// built from bindings that write through in whatever form the field takes. Nothing is stored
// differently as a result; only the control over it is shared.
//
// MARK: Format-specificity
//
// Traits describing a capability a format does not have are simply not offered. A recordable
// disc is a BD-R or a DVD-R depending on which it is, so the trait carries the format's own
// name while both spellings write the same "Recordable" tag the rest of the app reads.
//
// "Interlaced" is additionally LOCKED ON for DVD: every DVD is interlaced, which the card
// previously stated as static text in the Video row. A locked-on trait is checked and disabled
// rather than hidden, because hiding it would silently drop the one fact that text conveyed.
private struct _TraitsMenu: View {
    @Bindable var model: ReleaseCardModel
    let viewModel: FSTabReleases

    /// One row of the menu.
    private struct Trait: Identifiable {
        let id: String
        /// Menu row title, and — when it is the only trait on — the closed menu's text.
        let title: String
        let isOn: Binding<Bool>
        /// True for a trait the format fixes and the user cannot change (DVD interlacing).
        var isLocked: Bool = false
    }

    /// A binding over a two-value String field: on ⇒ `onValue`, off ⇒ `offValue`.
    ///
    /// The off value is written explicitly rather than cleared to "" because these fields have
    /// no unset state — a Blu-ray is progressive or interlaced — and clearing one would make it
    /// read as unconfigured to every consumer that switches on it.
    private func stringTrait(_ keyPath: ReferenceWritableKeyPath<ReleaseCardModel, String>,
                             on onValue: String,
                             off offValue: String) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] == onValue },
            set: { model[keyPath: keyPath] = $0 ? onValue : offValue }
        )
    }

    private var traits: [Trait] {
        var traits: [Trait] = [
            Trait(id: "remastered", title: "Remastered", isOn: $model.remastered),
        ]

        switch model.releaseFormat {
        case .uhd4K:
            traits.append(Trait(id: "master", title: "Upscaled 4K Master",
                                isOn: stringTrait(\.masterType,
                                                  on:  ReleaseMasterType.upscaled,
                                                  off: ReleaseMasterType.nativeFourK)))
        case .bluRay:
            traits.append(Trait(id: "scan", title: "Interlaced",
                                isOn: stringTrait(\.scanningMethod,
                                                  on:  ReleaseScanningMethod.interlaced,
                                                  off: ReleaseScanningMethod.progressive)))
        case .dvd:
            // Fixed by the format. Shown checked and disabled rather than omitted — see
            // the note above.
            traits.append(Trait(id: "scan", title: "Interlaced",
                                isOn: .constant(true), isLocked: true))
        case nil:
            break
        }

        traits.append(Trait(id: "subtitles", title: "Includes Subtitles",
                            isOn: $model.hasSubtitles))

        // Same stored tag ("Recordable") either way; only the user-facing spelling of the
        // disc type differs.
        switch model.releaseFormat {
        case .bluRay:
            traits.append(Trait(id: "recordable", title: "Recordable (BD-R)",
                                isOn: stringTrait(\.replicationType,
                                                  on:  ReleaseReplicationType.recordable,
                                                  off: ReleaseReplicationType.pressed)))
        case .dvd:
            traits.append(Trait(id: "recordable", title: "Recordable (DVD-R)",
                                isOn: stringTrait(\.replicationType,
                                                  on:  ReleaseReplicationType.recordable,
                                                  off: ReleaseReplicationType.pressed)))
        case .uhd4K, nil:
            break
        }

        // MARK: Wishlisted — last, and only where it can mean something
        //
        // At the bottom rather than beside "Remastered" because it is the odd one out: every
        // other trait describes the DISC, while this one describes the user's intention toward
        // it.
        //
        // TWO conditions withhold it, and neither is cosmetic:
        //
        //   • Purchased. "Purchased and also on the wishlist" is contradictory, and the
        //     invariant is maintained by ONE mechanism — the purchased cascade, which clears
        //     the position on purchase and only runs in that direction. An always-offered trait
        //     would let the user re-enter the contradictory state afterwards, and it would
        //     persist: appearing in the Wishlist report and consuming a position for a disc
        //     already owned.
        //
        //   • Combo-pack child. A bundled disc's wishlist state mirrors its parent's and is
        //     written by syncComboChildFields. This used to be offered and disabled; hidden is
        //     more accurate, because a disabled row still asserts the trait is a property of
        //     THIS release, and it is not. (Contrast the DVD "Interlaced" row, which stays
        //     visible-and-locked: that one IS a fact about the disc in front of the user.)
        //
        // Withholding keeps both states unreachable rather than adding a second mechanism to
        // clean up after them.
        if !model.purchased && !model.isComboChild {
            // Not a plain assignment: a wishlist POSITION has to be issued when turning
            // this on and the surviving positions compacted when turning it off, so the
            // write goes through the same helper the old checkbox used.
            traits.append(Trait(id: "wishlist", title: "Wishlisted", isOn: Binding(
                get: { model.wishlist > 0 },
                set: { isOn in viewModel.handleWishlistToggle(releaseID: model.id, isOn: isOn) }
            )))
        }

        return traits
    }

    var body: some View {
        let traits = self.traits
        // Locked traits count toward the summary: a DVD's fixed interlacing is a real
        // property of the release, and leaving it out would make a DVD with subtitles read
        // "Includes Subtitles" while listing two ticks when opened.
        let selected = traits.filter { $0.isOn.wrappedValue }
        let displayText: String
        switch selected.count {
        case 0:  displayText = "Select Traits…"
        case 1:  displayText = selected[0].title
        default: displayText = "Multiple"
        }

        return Menu {
            ForEach(traits) { trait in
                Toggle(isOn: trait.isOn) { Text(trait.title) }
                    .disabled(trait.isLocked)
            }
        } label: {
            Text(displayText)
                .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .frame(width: ReleaseCardMetrics.pickerWidth, alignment: .leading)
    }
}

// MARK: - Condition Picker (Observation Isolation + Tag-Set Guarantee)
//
// The purchase condition, as the two-segment control it has always been — plus a third segment
// that appears ONLY when the stored value is neither "New" nor "Used".
//
// MARK: Why the third segment is not optional politeness
//
// This is the one picker on the card whose stored field has no unset representation in its own
// vocabulary, and also the field most likely to arrive empty: `Release.condition` defaults to
// "" throughout the persistence layer, and DBRestorer's `parseString` yields "" for a backup
// predating the field. Every other consumer already treats empty as legal, so the card was the
// only surface asserting the field must hold one of two values.
//
// A Picker whose selection matches no tag logs an "invalid selection" fault and renders with
// NO segment selected, which on a segmented control is indistinguishable from a rendering
// glitch — and the value is untouched by the non-interaction, so "" round-trips to disk unseen.
//
// Showing it is the same rule TaggedPicker applies to every menu picker here: a value outside
// the vocabulary keeps its own tag so it stays visible and selectable-away-from. TaggedPicker
// itself is not reused because it is a `.menu` picker by construction, and a two-value field is
// exactly what a segmented control is right for — the guarantee transfers, not the control.
//
// The 144 pt frame is unchanged, so the ordinary two-segment case is bit-for-bit what it was. A
// third segment squeezes three into that same width rather than widening the row, which keeps
// the card's uniform height intact on the anomalous path — a card of a different height is
// visible against its neighbors on every carousel navigation.
private struct _ConditionPicker: View {
    @Bindable var model: ReleaseCardModel

    /// What to call a value the vocabulary does not contain. An empty value is the common
    /// anomaly and has no name of its own, so it gets an em dash; anything else is shown
    /// verbatim, because the stored string is the only truthful thing the segment can say
    /// about it.
    private var anomalousTitle: String {
        model.condition.isEmpty ? "—" : model.condition
    }

    private static let vocabularySegments: [SheetSegmentedControl<String>.Segment] =
        ReleaseCondition.pickerOptions.map { .init($0, $0) }

    var body: some View {
        // The vocabulary and the "is this outside it?" question both come from
        // ReleaseCondition — not offered as a placeholder-style empty tag, because unlike
        // the menu pickers this field has no "unset" state the user is meant to select;
        // the extra segment exists to SHOW an anomalous value, not to let one be chosen.
        let isAnomalous = ReleaseCondition.isAnomalous(model.condition)
        let segments = Self.vocabularySegments
            + (isAnomalous ? [.init(model.condition, anomalousTitle)] : [])
        SheetSegmentedControl(selection: $model.condition, segments: segments)
        .frame(minWidth: 144, maxWidth: 144)
        // Locked for combo-pack children (condition mirrors the parent 4K release).
        .disabled(model.isComboChild)
    }
}

// MARK: - Artwork Picker (Observation Isolation)
// Isolated so hasArtwork/independence/purchased subscriptions register here rather than
// on ReleaseCardView.body.
private struct _ArtworkPicker: View {
    @Bindable var model: ReleaseCardModel

    /// Tags beyond the universal placeholder and "Steelbook", which depend on BOTH the
    /// Purchased control and the Type picker. Both combo-pack forms share one vocabulary — how
    /// many Blu-rays a pack bundles has no bearing on whether its artwork is correct — so
    /// moving between them preserves the selection.
    ///
    /// The unconditional seed below is load-bearing beyond this control: it is what makes
    /// "Steelbook" valid under every type and purchased state, and therefore what the purchased
    /// and independence cascades' Steelbook exemptions assert. Named through
    /// `ReleaseArtwork.steelbook` so all three read one definition — they were three separate
    /// literals, and two disagreed about the rule.
    ///
    /// Four fixed lists, chosen between per render rather than assembled per render.
    private static let steelbookOnly: [ReleaseOption] = [ReleaseOption(ReleaseArtwork.steelbook)]
    private static let comboPackArtwork: [ReleaseOption] =
        steelbookOnly + ReleaseArtwork.comboPackOptions.map { ReleaseOption($0) }
    private static let multiPackArtwork: [ReleaseOption] =
        steelbookOnly + ReleaseArtwork.multiPackOptions.map { ReleaseOption($0) }
    private static let standaloneArtwork: [ReleaseOption] =
        steelbookOnly + ReleaseArtwork.standaloneOptions.map { ReleaseOption($0) }

    private var options: [ReleaseOption] {
        guard model.purchased, !model.independence.isEmpty else { return Self.steelbookOnly }
        switch model.independence {
        case ReleaseIndependence.comboPack, ReleaseIndependence.comboPackDualBD:
            return Self.comboPackArtwork
        case ReleaseIndependence.multiPack:
            return Self.multiPackArtwork
        default: // Standalone
            return Self.standaloneArtwork
        }
    }

    var body: some View {
        // Bound straight to model.hasArtwork. A clamp was tried here and reverted: its closures
        // captured a tag snapshot from the render pass that created them and could detach from
        // the content's own re-evaluation, leaving a new release permanently showing only the
        // placeholder. TaggedPicker derives its fallback from the same `options` this body
        // computes, so there is no second source to fall out of step.
        //
        // Artwork reset on a type change is handled by FSTabReleases.commitIndependence;
        // combo-pack children take the parent's value via syncComboChildFields.
        TaggedPicker(selection: $model.hasArtwork,
                     options: options,
                     placeholder: "Select Artwork…")
        .disabled(model.isComboChild)
    }
}

// MARK: - Market Availability Picker (Observation Isolation)
// Isolated so marketAvailability/independence/nationalOrigin/purchased subscriptions
// register here rather than on ReleaseCardView.body. Its nationalOrigin cascade is in the tree
// only while the release is unpurchased, which is the condition it already assumed; the
// independence half lives in FSTabReleases.commitIndependence, which applies the same guard.
private struct _MarketAvailabilityPicker: View {
    @Bindable var model: ReleaseCardModel

    /// Titles come from ReleaseMarketAvailability rather than being written out here, so
    /// the menu and the right sidebar's release cards cannot disagree about how a stored tag
    /// is spelled out. A tag needing no expansion maps to itself.
    ///
    /// `nonisolated` so the static lists below, whose initializers run outside the main
    /// actor, can call it.
    private nonisolated static func option(_ tag: String) -> ReleaseOption {
        ReleaseOption(tag, title: ReleaseMarketAvailability.displayTitle(tag))
    }

    /// The tag list and its order come from ReleaseMarketAvailability; the US list drops
    /// the import tags rather than restating the remainder. Three fixed lists, chosen
    /// between per render.
    private static let allOptions: [ReleaseOption] =
        ReleaseMarketAvailability.allTags.map(option)
    private static let domesticOptions: [ReleaseOption] =
        ReleaseMarketAvailability.allTags
            .filter { !ReleaseMarketAvailability.importOnlyTags.contains($0) }
            .map(option)
    private static let comboLockedOptions: [ReleaseOption] =
        [ReleaseOption(ReleaseMarketAvailability.comboPackOnly)]

    var body: some View {
        // A non-4K release in either combo-pack form is locked to a single value.
        let comboLocked = ReleaseIndependence.isComboPack(model.independence) && !model.is4K
        let usOrigin    = model.nationalOrigin == ReleaseOrigin.domestic

        // Read-side clamp, for the frame between a tag set changing and the cascade below
        // updating the stored value. Both arms map to a tag that exists in the branch
        // being rendered; an unrecognized value falls through and TaggedPicker tags it.
        let normalizedBinding = Binding<String>(
            get: {
                let current = model.marketAvailability.first ?? ""
                if comboLocked { return ReleaseMarketAvailability.comboPackOnly }
                if current == ReleaseMarketAvailability.comboPackOnly { return "" }
                if usOrigin, ReleaseCardView.importOnlyTags.contains(current) { return "" }
                return current
            },
            set: { newValue in
                model.marketAvailability = newValue.isEmpty ? [] : [newValue]
            }
        )

        return TaggedPicker(selection: normalizedBinding,
                            options: comboLocked ? Self.comboLockedOptions
                                   : usOrigin    ? Self.domesticOptions
                                                 : Self.allOptions,
                            placeholder: comboLocked ? nil : "Select Availability…")
        .disabled(comboLocked)
        // The independence half of this cascade is applied by
        // FSTabReleases.commitIndependence, at the write — see _TypeVersionsRow.
        .onFieldChange(of: model.nationalOrigin, on: model) { _, newValue in
            guard !model.purchased else { return }
            if newValue == ReleaseOrigin.domestic,
               let current = model.marketAvailability.first,
               ReleaseCardView.importOnlyTags.contains(current) {
                model.marketAvailability = []
            }
        }
    }
}

// MARK: - Multi-Select Option Vocabulary (Canonical Ordering)
// Single source of truth for the two multi-select menus in this file: the same instance
// supplies the menu's display order (the `options` array drives the ForEach) and the stored
// array's order (`canonicalized` ranks by position in that same array), so the two cannot
// drift apart.
//
// Canonicalization rather than sort-on-insert: sorting only the array being appended to
// normalizes it relative to its existing contents, so an array that arrived already out of
// order — from a pre-normalization build, a restored backup, a hand-edited record — stayed out
// of order, and two releases holding the same set rendered as "Theatrical, Extended" and
// "Extended, Theatrical". Rebuilding from the vocabulary on every commit makes the stored
// order a pure function of the selected SET.
//
// Unrecognized values (kept rather than dropped, per the same data-preservation rule as the
// pickers' tag-set guarantees) are placed after all known values and sorted
// lexicographically — not left in input order — so no residual input-order carryover survives.
// Ranks of known values are unique, so `sort`'s lack of a stability guarantee cannot matter.
struct ReleaseOptionVocabulary: Sendable {
    /// Menu display order. Also the canonical storage order.
    let options: [String]
    private let rank: [String: Int]
    /// Former spellings of an option, mapped to the current one. A record written under the
    /// old name (or restored from a backup that carries it) is folded into the current
    /// option on canonicalization instead of surviving as an unrecognized value.
    private let aliases: [String: String]

    private init(_ options: [String], aliases: [String: String] = [:]) {
        self.options = options
        var dict = [String: Int](minimumCapacity: options.count)
        for (i, option) in options.enumerated() { dict[option] = i }
        self.rank = dict
        self.aliases = aliases
    }

    /// Whether `value` is one of this vocabulary's options. False for an unrecognized value
    /// the stored array carries through (see `canonicalized`). Stored arrays are canonicalized
    /// on load and on every commit, so a former spelling has already become its current
    /// option by the time anything asks.
    func isKnown(_ value: String) -> Bool { rank[value] != nil }

    /// Rebuilds `values` in canonical order, removing duplicates. Accepts any
    /// sequence so callers can pass either the stored array or a mutated Set.
    func canonicalized<S: Sequence<String>>(_ values: S) -> [String] {
        var seen = Set<String>()
        var known: [(rank: Int, value: String)] = []
        var unknown: [String] = []
        for raw in values {
            let value = aliases[raw] ?? raw
            guard seen.insert(value).inserted else { continue }
            if let r = rank[value] { known.append((r, value)) } else { unknown.append(value) }
        }
        known.sort { $0.rank < $1.rank }
        unknown.sort()
        return known.map { $0.value } + unknown
    }

    /// Shared with the FilmSheet's Metadata tab, which offers the identical version set for
    /// `Film.digitalVersion`. Both enumerate ViewingVersion, so neither menu can list an
    /// option the other lacks; the canonical ORDER is that enum's case order.
    ///
    /// This was a hand-written literal, and it had already drifted from the enum: it offered
    /// "Television Edit" and "Colorized" and the enum did not.
    static let includedVersions = ReleaseOptionVocabulary(
        ViewingVersion.selectableNames,
        // Renamed 2026-09-11; records written under the old names fold into the new ones.
        aliases: ["Television Edit": ViewingVersion.televisionEdit.displayName,
                  "International": ViewingVersion.international.displayName])

    /// Shared with the FilmSheet's Metadata tab, which offers the identical tag set for
    /// `Film.aspectRatio`. The canonical ORDER comes from there too — this vocabulary's
    /// rank map is built from it. See AspectRatioVocabulary.
    static let aspectRatios = ReleaseOptionVocabulary(AspectRatioVocabulary.all)
}

// MARK: - Multi-Select Menu
// The single Menu implementation behind both multi-select controls on a release card
// (Included Versions and Aspect Ratio). These were two structs with identical bodies,
// differing only in which array they bound to and which vocabulary they listed — exactly what
// ReleaseOptionVocabulary parameterizes.
//
// Both Toggle arms rebuild the whole array from the resulting Set rather than inserting or
// removing in place, so the committed order is a pure function of the selected SET. See
// ReleaseOptionVocabulary.
private struct MultiSelectMenu: View {
    @Binding var selection: [String]
    let vocabulary: ReleaseOptionVocabulary
    let placeholder: String

    private var displayText: String {
        switch selection.count {
        case 0:  return placeholder
        case 1:  return selection[0]
        default: return "Multiple"
        }
    }

    var body: some View {
        let selected = Set(selection)
        // Values the vocabulary does not offer, kept by `canonicalized` rather than dropped.
        // Listed after the vocabulary (already in canonical order, since `selection` is) so
        // they stay visible AND removable — the same guarantee TaggedPicker gives the
        // single-select menus. Without a row, an imported or restored unknown value could
        // never be unchecked, since every toggle rebuilds from the set that still held it.
        let unrecognized = selection.filter { !vocabulary.isKnown($0) }
        Menu {
            ForEach(vocabulary.options + unrecognized, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selected.contains(option) },
                    set: { isSelected in
                        var next = Set(selection)
                        if isSelected { next.insert(option) } else { next.remove(option) }
                        selection = vocabulary.canonicalized(next)
                    }
                )) {
                    Text(option)
                }
            }
        } label: {
            Text(displayText)
                .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }
}
