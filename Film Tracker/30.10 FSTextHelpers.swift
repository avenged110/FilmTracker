// MARK: - FSTextHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Low-level AppKit/SwiftUI text and input field primitives used by FilmSheet tabs.
//
// Contains infrastructure that changes when text-editing or input-validation behavior needs
// updating, independently of the domain-level control widgets in FSControlComponents.swift.

import SwiftUI
import AppKit

// MARK: - External ID Field
/// A digit-only text field (max 9 digits) that also accepts URL paste for IMDb and
/// Blu-ray.com links, extracting the numeric identifier only when the pasted URL
/// matches that field's exact accepted pattern and no other.
///
/// - IMDb accepted pattern:    https://www.imdb.com/title/tt<digits>/reference/
/// - Blu-ray accepted pattern: https://www.blu-ray.com/<dashed-name>/<digits>/
///
/// The trailing `/reference/` on an IMDb URL is OPTIONAL, and any components after it
/// are ignored — `https://www.imdb.com/title/tt0111161/` extracts just as
/// `…/reference/` does. The HOST, by contrast, is matched exactly, so
/// `imdb.com` without `www.` and `m.imdb.com` are both rejected — deliberately, since a
/// permissive host match is how a look-alike domain would get in.
///
/// Any URL that does not satisfy those structural constraints is silently
/// swallowed. Plain digit strings (1–9 chars) are accepted directly.
///
/// Validation is enforced via ExternalIDFormatter, an NSFormatter subclass whose
/// isPartialStringValid fires for every proposed text change — typing, paste
/// (Cmd+V, Edit menu, context menu), drag-drop, autocorrect — before the change
/// reaches text storage. This is the same proven mechanism used by DigitOnlyFormatter
/// in InputUtilities.swift.
///
/// The formatter compares the proposed result against the original string to isolate
/// what was inserted. Multi-character insertions (pastes) are validated against the
/// site-specific URL pattern; single-character insertions enforce digits-only.
struct ExternalIDField: NSViewRepresentable {
    @Binding var text: String
    let site: ExternalIDSite

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.formatter         = ExternalIDFormatter(site: site)
        field.delegate          = context.coordinator
        field.isBordered        = false
        field.isBezeled         = true
        (field.cell as? NSTextFieldCell)?.bezelStyle = .roundedBezel
        field.drawsBackground   = true
        field.focusRingType     = .default
        field.font              = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.placeholderString = site.placeholder
        field.alignment         = .left
        field.cell?.wraps        = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Keep the coordinator's parent current, for the same reason
        // ScrollingTextViewRepresentable does it below: SwiftUI recreates this
        // representable struct on every update but REUSES the coordinator, so without
        // this the delegate goes on writing through the `text` binding captured when the
        // coordinator was made.
        //
        // That is currently harmless here only by luck. This field's sole call site
        // (FSTabDetailsView's External IDs row) hands it a `Binding(get:set:)` whose
        // closures capture the view model — a stable @Observable reference — so a stale
        // binding still reaches the right object. Any call site whose binding closes over
        // per-render state instead would write into a previous generation of it, and
        // nothing about this type would indicate why. Refreshing the reference costs one
        // assignment per update and removes the dependence on what callers happen to
        // capture.
        context.coordinator.parent = self

        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ExternalIDField

        init(_ parent: ExternalIDField) { self.parent = parent }

        /// Syncs the field value back to the SwiftUI binding after every committed change.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - External ID Formatter
/// NSFormatter subclass that enforces digit-only input (max 9 chars) for normal typing
/// and validates pasted content against site-specific URL patterns before allowing it
/// through. isPartialStringValid is AppKit's authoritative pre-storage intercept —
/// it fires for every proposed text change regardless of input method.
///
/// For pastes: the formatter compares the proposed result to the original string to
/// isolate what was inserted, then checks whether it is a valid site-specific URL
/// (extracting the numeric ID) or a pure digit string. Everything else is rejected
/// by reverting to the original string.
///
/// For typing: the formatter checks that the proposed result is all-digits and at
/// most 9 characters.
private final class ExternalIDFormatter: StringFormatter {
    let site: ExternalIDSite

    init(site: ExternalIDSite) {
        self.site = site
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String

        // Allow clearing the field.
        if proposed.isEmpty { return true }

        // Compute the net character change to distinguish paste from typing.
        // origSelRange.length accounts for selected text being replaced.
        let insertedCount = proposed.count - origString.count + origSelRange.length

        if insertedCount > 1 {
            // Multi-character insertion = paste or drag-drop.
            // Extract what was actually inserted by removing the parts of
            // origString that surround the insertion point.
            let prefixEnd = origSelRange.location
            let suffixStart = origSelRange.location + origSelRange.length
            let prefix = String(origString.prefix(prefixEnd))
            let suffix = String(origString.dropFirst(suffixStart))
            // The inserted portion is the proposed string minus the kept prefix/suffix.
            let inserted: String
            if proposed.hasPrefix(prefix) && proposed.hasSuffix(suffix) {
                let afterPrefix = proposed.dropFirst(prefix.count)
                inserted = String(afterPrefix.dropLast(suffix.count))
            } else {
                // Fallback: the entire proposed string is new content.
                inserted = proposed
            }

            let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)

            // Path 1 — valid site-specific URL: extract the ID.
            if let extracted = site.extractID(from: trimmed) {
                unsafe partialStringPtr.pointee = extracted as NSString
                if let ptr = unsafe proposedSelRangePtr {
                    unsafe ptr.pointee = NSRange(location: extracted.count, length: 0)
                }
                return false
            }

            // Path 2 — pure digit string (1–9 chars): accept as-is.
            if !trimmed.isEmpty,
               trimmed.count <= 9,
               trimmed.allSatisfy(\.isASCIIDigit) {
                unsafe partialStringPtr.pointee = trimmed as NSString
                if let ptr = unsafe proposedSelRangePtr {
                    unsafe ptr.pointee = NSRange(location: trimmed.count, length: 0)
                }
                return false
            }

            // Path 3 — anything else: reject by reverting to the original string.
            unsafe partialStringPtr.pointee = origString as NSString
            if let ptr = unsafe proposedSelRangePtr {
                unsafe ptr.pointee = origSelRange
            }
            return false
        }

        // Single-character typing (or deletion that leaves content).
        // Accept only if the full proposed result is all-digits and ≤ 9 chars.
        if proposed.count <= 9, proposed.allSatisfy(\.isASCIIDigit) {
            return true
        }

        // Reject: revert to original.
        unsafe partialStringPtr.pointee = origString as NSString
        if let ptr = unsafe proposedSelRangePtr {
            unsafe ptr.pointee = origSelRange
        }
        return false
    }
}

// MARK: - ExternalIDSite
/// Identifies which external site an ExternalIDField targets.
/// Drives both the placeholder string and the URL extraction pattern.
enum ExternalIDSite {
    case imdb
    case bluray

    var placeholder: String {
        switch self {
        case .imdb:   return "IMDb.com"
        case .bluray: return "Blu-ray.com"
        }
    }

    /// Extracts a numeric identifier from a pasted string only if it is a valid URL
    /// that matches this field's exact accepted pattern. Returns nil for everything else,
    /// including plain digit strings (handled separately by the caller),
    /// URLs for the wrong site, and any URL that doesn't match the required structure.
    ///
    /// Accepted patterns (scheme must be https, host must match exactly):
    ///   IMDb:    https://www.imdb.com/title/tt<digits>/reference/
    ///   Blu-ray: https://www.blu-ray.com/<dashed-name>/<digits>/
    func extractID(from trimmed: String) -> String? {
        // Parse as a URL first. This is the hard gate — anything that is not a
        // well-formed URL with an https scheme is rejected before any other check.
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              let host = url.host else { return nil }

        // pathComponents on a URL always begins with "/". Filter it out so
        // parts[0] is the first real path segment.
        let parts = url.pathComponents.filter { $0 != "/" }

        switch self {
        case .imdb:
            // Host must be exactly www.imdb.com.
            guard host == "www.imdb.com" else { return nil }
            // Path must begin with /title/tt<digits>; the trailing /reference
            // segment is optional. Additional trailing components are ignored.
            guard parts.count >= 2,
                  parts[0] == "title",
                  parts[1].hasPrefix("tt"),
                  parts.count < 3 || parts[2] == "reference" else { return nil }
            let digits = String(parts[1].dropFirst(2))   // drop the "tt" prefix
            guard !digits.isEmpty,
                  digits.allSatisfy(\.isASCIIDigit),
                  digits.count <= 9 else { return nil }
            return digits

        case .bluray:
            // Host must be exactly www.blu-ray.com.
            guard host == "www.blu-ray.com" else { return nil }
            // Path must be /<dashed-name>/<digits>  (at least 2 components;
            // the final component must be an all-digit ID).
            guard parts.count >= 2,
                  let last = parts.last,
                  !last.isEmpty,
                  last.allSatisfy(\.isASCIIDigit),
                  last.count <= 9 else { return nil }
            return last
        }
    }
}

// MARK: - FixedHeightScrollingTextView
//
// Fixed-height multiline text field with native AppKit styling and the system focus
// ring (standard shrink-to-fit animation). Content scrolls vertically when it overflows
// the fixed frame; below that point the scroll view is non-scrollable, so trackpad/
// scroll-wheel events pass through to the parent scroll view.
//
// Architecture:
//   • FixedHeightScrollingTextView (public SwiftUI wrapper) — SwiftUI .background fill
//     and .overlay border, plus fixedHeight(lineCount:).
//   • ScrollingTextViewRepresentable (private NSViewRepresentable) — input/scrolling
//     mechanism, fully transparent so the SwiftUI chrome shows through.
//   • ConditionalScrollView (private NSScrollView subclass) — draws the system focus
//     ring on behalf of its first-responder document view; gates scrolling until
//     content overflows.
//   • InnerTextView (private NSTextView subclass) — placeholder drawing, and opens the
//     focus-ring "gate" (focusRingType = .exterior) so ConditionalScrollView can draw it.
//
// Focus ring: AppKit draws the ring for the actual first responder (InnerTextView), but
// the ring wanted is around the fixed-size scroll view. Standard AppKit behavior: an
// NSScrollView draws the ring on behalf of its document view when that view's
// focusRingType is not .none — InnerTextView's .exterior is the "gate"; the ring shape
// itself comes from ConditionalScrollView's drawFocusRingMask/focusRingMaskBounds.
//
// Visual chrome: drawn entirely in SwiftUI (.background/.overlay), not on the
// layer-backed NSScrollView. Color(NSColor:) re-resolves for light/dark automatically in
// SwiftUI; a layer-backed AppKit view resolves its background color once and washes out
// in dark mode. .background/.overlay also avoids .clipShape, which would mask the
// exterior focus ring drawn ~3 px beyond the field edge.
//
// Scrollability gating: ConditionalScrollView.isScrollingEnabled is toggled by the
// Coordinator after every text change by comparing content height to frame height.
// Scroll-wheel events forward to the next responder while scrolling is disabled.
//
// Return / Option-Return: Return never inserts a paragraph break. Inside a popover that
// installs a FieldSubmitAction (via .fieldSubmitAction(_:)) Return runs that popover's
// confirming button; everywhere else — the FilmSheet's own fields — Return finishes
// editing the field and gives up focus, so the NEXT Return, with no field active, saves
// the sheet. Option-Return enters a line break via AppKit's own standard binding
// (insertNewlineIgnoringFieldEditor(_:)), not custom key interception. All of it runs
// through NSTextViewDelegate's textView(_:doCommandBy:); see FieldSubmitAction.
//
// Usage:
//     FixedHeightScrollingTextView(text: $text, placeholder: "Notes")
//         .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: 3))

// MARK: - FieldSubmitAction

/// The "Return confirms" action for `FixedHeightScrollingTextView`, carried in the
/// SwiftUI environment. Installed by the FilmSheet's popovers (bulk import, text entry),
/// whose own confirming button Return should press. The sheet itself installs none: its
/// fields follow the rule that Return finishes the field first (see the Coordinator's
/// `doCommandBy`), and only a Return with no field active saves the sheet.
///
/// Why this exists: an `NSTextView` is the first responder while typing and consumes
/// Return by inserting a paragraph break, so a `.keyboardShortcut(.defaultAction)`
/// button on the enclosing sheet never sees the key. AppKit's
/// `NSTextViewDelegate.textView(_:doCommandBy:)` is the correct hook for handing the
/// text view an action to run instead — nothing here overrides `keyDown`, installs an
/// `NSEvent` monitor, or reaches for the window's default button cell.
///
/// Option-Return needs no extra work: AppKit's standard key bindings already map it to
/// `insertNewlineIgnoringFieldEditor(_:)` — the selector that exists precisely so a
/// "Return commits" field can still take a literal line break. Letting that selector
/// through to `NSTextView`'s own implementation reuses the platform's own mechanism
/// (the same one system single-line-with-line-breaks fields use).
///
/// **Why a reference type, not a bare closure, in the environment.** SwiftUI
/// re-evaluates every descendant reading a changed environment value, and closures
/// aren't equatable — a closure installed inline in `body` would be a new value on
/// every evaluation, invalidating the whole tab tree beneath it (exactly the cascade
/// `FilmSheetView` is structured to avoid — see `FilmSheetButtonBar` and
/// `FilmSheetTabContent`). A class held in `@State` has stable identity for the
/// presentation's lifetime, so readers are never invalidated by it. Mirrors
/// `HorizontalScrollZoneRegistrar` in 24_00_RightSidebar.swift for the same reason.
///
/// **Why the handler returns `Bool`.** The confirming button is often disabled (no
/// changes yet, an invalid draft). The handler reports whether it acted, so it can
/// decline in those cases without performing an action the button beside it would have
/// refused. Declining does not restore the line break — Return is consumed regardless,
/// matching what pressing Return against a disabled default button does everywhere else
/// on the platform. Option-Return remains the way to enter a line break either way.
@MainActor
final class FieldSubmitAction {

    /// Runs the confirming action. Returns `true` if it was performed, `false` if the
    /// action is currently unavailable (nothing to confirm, validation unmet, a save
    /// already in flight) — in which case Return simply does nothing; it is consumed
    /// either way, and never falls back to inserting a newline.
    private var handler: (() -> Bool)?

    init() {}

    /// Installs (or clears) the action.
    ///
    /// Called from `onAppear`, never from a `body` — assigning here during view
    /// evaluation would be a mutation of shared state mid-render. Because the closure
    /// captures the installing `View` value, and `@State` storage is read through the
    /// SwiftUI graph rather than copied, reading a `@State` property inside the closure
    /// yields the value current at the moment Return is pressed rather than the value
    /// that was current when the closure was made.
    func setHandler(_ handler: (() -> Bool)?) {
        self.handler = handler
    }

    /// Invoked by the text view's delegate on Return. Returns whether the action ran;
    /// the delegate consumes the key either way, so the result is informational.
    @discardableResult
    func perform() -> Bool {
        guard let handler else { return false }
        return handler()
    }
}

private struct FieldSubmitActionKey: EnvironmentKey {
    static let defaultValue: FieldSubmitAction? = nil
}

extension EnvironmentValues {
    /// The action `FixedHeightScrollingTextView` runs when Return is pressed.
    ///
    /// Return is taken away from the text view whether or not this is set — the default
    /// of `nil` means Return finishes editing the field rather than inserting a line
    /// break.
    /// Any subtree that presents its own confirming control over a subtree that already
    /// installed one — a popover opened from the FilmSheet, for instance — MUST state its
    /// own value, because SwiftUI popovers inherit the presenter's environment and would
    /// otherwise commit the sheet behind them.
    var fieldSubmitAction: FieldSubmitAction? {
        get { self[FieldSubmitActionKey.self] }
        set { self[FieldSubmitActionKey.self] = newValue }
    }
}

extension View {
    /// Installs the Return-confirms action for every `FixedHeightScrollingTextView` in
    /// this subtree. Pass `nil` to opt a subtree back out.
    func fieldSubmitAction(_ action: FieldSubmitAction?) -> some View {
        environment(\.fieldSubmitAction, action)
    }
}

// MARK: - InnerTextView

/// Minimal NSTextView subclass — draws its own placeholder (NSTextView has no native
/// placeholder API) and opens the focus-ring "gate" so its enclosing scroll view can
/// draw the system ring.
/// Background and border chrome belong to the SwiftUI wrapper.
private final class InnerTextView: NSTextView {

    var placeholder: String = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        commonInit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Appearance.
        drawsBackground     = false   // transparent — the SwiftUI wrapper draws the fill
        textColor           = .textColor
        insertionPointColor = .controlAccentColor
        font                = .systemFont(ofSize: NSFont.systemFontSize)

        // Behavior.
        isEditable          = true
        isSelectable        = true
        isRichText          = false
        allowsUndo          = true
        usesFontPanel       = false
        usesRuler           = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled  = false

        // Layout — vertically resizable so content grows inside the scroll view.
        isVerticallyResizable   = true
        isHorizontallyResizable = false
        autoresizingMask        = [.width]

        // Text container.
        unsafe textContainer?.containerSize       = NSSize(width: 0,
                                                    height: CGFloat.greatestFiniteMagnitude)
        unsafe textContainer?.widthTracksTextView = true
        unsafe textContainer?.lineFragmentPadding = 5
        textContainerInset                 = NSSize(width: 6, height: 4)

        // Focus ring — OPEN THE GATE.
        // AppKit only draws/animates a focus ring for the first responder. This text
        // view is the first responder, but the ring we want sits around the FIXED-size
        // scroll view, not this (vertically resizable) document view. The standard
        // AppKit behavior — used by the system scrollable text view — is that the
        // enclosing NSScrollView draws the ring on behalf of its document view, but
        // ONLY when the document view's focusRingType is not .none. Setting .exterior
        // here is what permits ConditionalScrollView to draw the ring at all; the ring's
        // SHAPE is defined by the scroll view, so this view installs no mask of its own.
        focusRingType = .exterior
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        insertionPointColor = .controlAccentColor
        if string.isEmpty { needsDisplay = true }
    }

    // MARK: Placeholder drawing.

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !placeholder.isEmpty, string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let x = unsafe textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let y = textContainerInset.height
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: x, y: y))
    }

    // MARK: Paste — line-break flattening.
    //
    // Pasted content is flattened to a single paragraph: every line break in the incoming
    // string is removed and the lines joined with a single space, so "This is\na test of
    // a string with\ntwo new line breaks in it" lands as "This is a test of a string with
    // two new line breaks in it".
    //
    // Hooked in three places, not one: `paste(_:)` and `pasteAsPlainText(_:)` are the
    // action methods the Paste menu item and Command-V actually send to the first
    // responder, so those are overridden directly. Relying on `readSelection(from:type:)`
    // alone — an earlier version's approach, on the premise that `paste(_:)` funnels
    // through it — does not hold in this view; line breaks survived. `readSelection` is
    // still overridden because it IS the path for dragged-in text and Services, and now
    // routes to the same helper as the other two.
    //
    // All three delegate to `insertFlattenedPasteboardString(from:)`, which reports
    // whether it handled the insertion. When it declines (no plain text, or text with no
    // line breaks), the override falls through to `super` unchanged. The pasteboard
    // itself is never mutated, and no key events are intercepted.
    //
    // Option-Return is untouched — this affects only pasted content; line breaks the
    // user enters themselves are left alone.
    override func paste(_ sender: Any?) {
        if !insertFlattenedPasteboardString(from: .general) {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !insertFlattenedPasteboardString(from: .general) {
            super.pasteAsPlainText(sender)
        }
    }

    /// Text dragged into the field, and any other route that reads a selection off a
    /// pasteboard, gets the same treatment. No type filter here: the only question that
    /// matters is whether a plain-text representation is available and whether flattening
    /// it would change anything. When either answer is no, `super` handles it exactly as
    /// before.
    override func readSelection(from pasteboard: NSPasteboard,
                                type: NSPasteboard.PasteboardType) -> Bool {
        guard insertFlattenedPasteboardString(from: pasteboard) else {
            return super.readSelection(from: pasteboard, type: type)
        }
        return true
    }

    /// Reads `pasteboard`'s plain-text content, flattens its line breaks, and inserts the
    /// result at the current selection.
    ///
    /// Returns `true` when it has fully handled the insertion, and `false` when the caller
    /// should fall back to AppKit's own behavior — either because the pasteboard carries no
    /// plain text at all (a file promise, an image) or because the text contains no line
    /// breaks, in which case there is nothing to do that `super` would not do identically.
    ///
    /// The insertion runs through the standard
    /// `shouldChangeText(in:replacementString:)` / `replaceCharacters(in:with:)` /
    /// `didChangeText()` sequence, which registers the undo action (a paste stays a single
    /// Command-Z) and posts `NSText.didChangeNotification` — so the Coordinator's
    /// `textDidChange` writes through to the SwiftUI binding and re-evaluates scroll gating
    /// exactly as it does for typing.
    private func insertFlattenedPasteboardString(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let raw = pasteboard.string(forType: .string) else { return false }

        let flattened = Self.flatteningLineBreaks(in: raw)

        // Nothing to change — let AppKit do its own (identical) work.
        guard flattened != raw else { return false }

        // Content that was nothing but line breaks and spaces flattens away to nothing.
        // Consume the paste and leave the field as it was; replacing the selection with an
        // empty string would silently delete the user's text in exchange for content that
        // carried none.
        guard !flattened.isEmpty else { return true }

        let target = selectedRange()
        guard shouldChangeText(in: target, replacementString: flattened) else { return true }
        replaceCharacters(in: target, with: flattened)
        didChangeText()

        // Leave the insertion point after the inserted run, as a normal paste does.
        // UTF-16 length, because NSRange is measured in UTF-16 units.
        let insertedLength = (flattened as NSString).length
        let caret = NSRange(location: target.location + insertedLength, length: 0)
        setSelectedRange(caret)
        scrollRangeToVisible(caret)

        return true
    }

    /// Removes every line break from `raw`, joining the resulting lines with a single
    /// space so the content reads as one paragraph.
    ///
    /// Details that matter in practice:
    ///   • `CharacterSet.newlines` covers LF, CR, U+2028 and U+2029, so text copied from a
    ///     Windows file (CRLF), a classic Mac file (CR), or a PDF/word processor is handled
    ///     by the same pass. CRLF splits into an empty middle component, which is dropped.
    ///   • Whitespace stranded at a break — the trailing spaces of one line, the indent of
    ///     the next — is trimmed rather than left to collapse into a double space.
    ///   • Whitespace at the very START of the first line and the very END of the last is
    ///     preserved, because it was not created by a line break and removing it would be
    ///     an edit the user did not ask for.
    ///   • Blank lines contribute nothing rather than becoming runs of spaces.
    private static func flatteningLineBreaks(in raw: String) -> String {
        guard raw.rangeOfCharacter(from: .newlines) != nil else { return raw }

        let pieces = raw.components(separatedBy: .newlines)
        let lastIndex = pieces.count - 1
        var kept: [String] = []
        kept.reserveCapacity(pieces.count)

        for (index, piece) in pieces.enumerated() {
            var trimmed = Substring(piece)
            if index > 0 {
                while let first = trimmed.first, first.isWhitespace { trimmed = trimmed.dropFirst() }
            }
            if index < lastIndex {
                while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
            }
            guard !trimmed.isEmpty else { continue }
            kept.append(String(trimmed))
        }

        return kept.joined(separator: " ")
    }

    // MARK: First-responder transitions.
    // Nudge the enclosing scroll view to refresh its focus ring as focus enters and
    // leaves. AppKit drives the ring's appearance/animation off first-responder changes,
    // but noteFocusRingMaskChanged() guarantees the scroll view re-evaluates and redraws
    // its ring at the moment of transition (and after any field resize while focused).

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { enclosingScrollView?.noteFocusRingMaskChanged() }
        return result
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            enclosingScrollView?.noteFocusRingMaskChanged()
            if string.isEmpty { needsDisplay = true }   // restore placeholder
        }
        return result
    }
}

// MARK: - ConditionalScrollView

/// NSScrollView subclass that (a) draws the system focus ring on behalf of its
/// first-responder document view and (b) gates scrolling until content overflows.
/// It is otherwise fully transparent — the fill and border are SwiftUI chrome.
///
/// Scroll gating: when isScrollingEnabled is false, scroll-wheel events (including
/// trackpad momentum) are passed to the next responder rather than handled, so the
/// view feels non-scrollable until content actually overflows the fixed frame.
private final class ConditionalScrollView: NSScrollView {

    private let cornerRadius: CGFloat = 6

    var isScrollingEnabled: Bool = false {
        didSet {
            hasVerticalScroller = isScrollingEnabled
        }
    }

    // One-shot guard for the initial scroll-to-top. An NSTextView embedded in a scroll
    // view can land scrolled to the BOTTOM of overflowing content on first appearance,
    // which would show the user the END of the text with the beginning hidden above the
    // viewport. We bring the beginning of the content into view exactly once per instance
    // so the field first reads from the top, with the overflow tucked below the viewport.
    // Consumed on the first layout pass that has a real (non-zero) frame — i.e. before the
    // user can interact — so that a later layout pass triggered by the user typing a
    // short field past its fixed height can never yank the view back to the top mid-edit.
    private var didPerformInitialScroll = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // wantsLayer = true is required for AppKit to draw the focus ring on this view
        // inside SwiftUI's layer-backed hosting hierarchy. Without it, AppKit silently
        // suppresses the ring on non-layer-backed views that sit inside a layer-backed
        // ancestor.
        wantsLayer    = true
        focusRingType = .exterior

        // The scroll view is fully transparent. The visible chrome — the rounded
        // textBackgroundColor fill and the border — is drawn in SwiftUI behind/over the
        // representable (see FixedHeightScrollingTextView), where Color(NSColor:) values
        // re-resolve for light/dark automatically. This deliberately avoids hosting the
        // fill on this layer-backed NSScrollView: an AppKit/layer background color is
        // resolved only once, against the appearance current at set time (typically
        // light, before the view is in a window), so it washes out in dark mode, and a
        // layer background set with drawsBackground = false is liable to be cleared by
        // the scroll view's own background management. Keeping the fill in SwiftUI
        // sidesteps both issues; doing it with .background/.overlay there — rather than
        // .clipShape — keeps the exterior focus ring from being masked away.
        drawsBackground = false
    }

    // MARK: Scrollability gating
    //
    // Canonical overflow evaluation. Compares the document view's laid-out content
    // height against the visible content height and toggles isScrollingEnabled
    // accordingly. Idempotent — it mutates isScrollingEnabled only when the computed
    // value differs from the current one, so it is safe to call repeatedly: from
    // layout() (initial appearance and every resize), after user edits (textDidChange),
    // and after programmatic text changes (updateNSView). Centralizing the computation
    // here keeps a single source of truth shared by all three call sites.
    func updateScrollability() {
        guard let textView = documentView as? InnerTextView,
              let lm = unsafe textView.layoutManager,
              let tc = unsafe textView.textContainer else { return }
        // layoutManager.usedRect gives the true content height including all laid-out
        // text, using the same container as the text view itself.
        lm.ensureLayout(for: tc)
        let contentHeight = lm.usedRect(for: tc).height
            + textView.textContainerInset.height * 2
        let shouldScroll  = contentHeight > contentSize.height
        if isScrollingEnabled != shouldScroll {
            isScrollingEnabled = shouldScroll
        }
    }

    // MARK: Initial scroll position
    //
    // Brings the very top of the document into view. We scroll the clip view to the
    // document's true top-left origin (0, 0) rather than using scrollRangeToVisible to
    // the first glyph: scrollRangeToVisible parks the first GLYPH at the top edge of the
    // viewport, which scrolls past the textContainerInset — the small gap that should sit
    // above the first line — leaving the text a few pixels too high. Scrolling to the
    // document origin preserves that top inset, so the resting position matches a
    // freshly-shown field whose content fits exactly. For a flipped document view
    // (NSTextView is flipped) bounds origin (0, 0) is the top, regardless of content
    // height. reflectScrolledClipView syncs the scrollers/visual state to the new origin.
    private func scrollToTop() {
        contentView.scroll(to: NSPoint(x: 0, y: 0))
        reflectScrolledClipView(contentView)
    }

    // MARK: Layout
    //
    // AppKit calls layout() after this scroll view is assigned its real frame — in
    // particular on first appearance, the moment at which contentSize first becomes
    // non-zero. Evaluating overflow here is what makes a field whose content already
    // exceeds the fixed height scrollable WITHOUT any user interaction, and makes that
    // hold on every fresh sheet session (isScrollingEnabled starts false on each newly
    // created instance). Earlier attempts to measure at makeNSView time failed because
    // contentSize is still zero there; layout() is the correct, frame-valid hook.
    override func layout() {
        super.layout()
        updateScrollability()

        // One-time initial scroll-to-top, performed on the FIRST layout pass that has a
        // real (non-zero) frame — the same frame-valid moment updateScrollability relies
        // on. Consuming the one-shot here, before the user can interact, guarantees we
        // never scroll to the top in response to a LATER event: in particular, if a field
        // that fit on load is subsequently typed past its fixed height, the resulting
        // layout pass must leave the insertion point where the user is typing rather than
        // snapping the view back to the top. We actually scroll only when the content
        // overflows (isScrollingEnabled); when it fits, the top is already shown and a
        // scroll would be a no-op. The scroll itself is deferred one run-loop turn so it
        // runs after AppKit finishes the entire layout/sizing cascade for this pass —
        // including any re-tile triggered by toggling the vertical scroller in the
        // isScrollingEnabled didSet — guaranteeing our position is the final word rather
        // than being overridden mid-cascade. DispatchQueue.main.async (not Task) matches
        // the codebase convention for deferring from AppKit layout callbacks where
        // run-loop ordering matters.
        if !didPerformInitialScroll, bounds.width > 0, bounds.height > 0 {
            didPerformInitialScroll = true
            if isScrollingEnabled {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollToTop()
                }
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if isScrollingEnabled {
            super.scrollWheel(with: event)
        } else {
            unsafe nextResponder?.scrollWheel(with: event)
        }
    }

    // MARK: Focus ring.
    // System-standard ring shaped to match the SwiftUI rounded border (radius 6). That border
    // is a `RoundedRectangle`, whose default corner style is `.continuous`, so the ring mask
    // uses the same continuous curve rather than NSBezierPath's circular `roundedRect`. AppKit invokes these on this scroll view because
    // focusRingType is .exterior here and the document view (InnerTextView) has a non-.none
    // focusRingType — i.e., the scroll view is the ring drawer for its first-responder
    // document view.

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(cgPath: CGPath.continuousRoundedRect(bounds, cornerRadius: cornerRadius)).fill()
    }
}

// MARK: - ScrollingTextViewRepresentable

/// Pure input/scrolling mechanism. Fully transparent — the focus ring is drawn by
/// ConditionalScrollView; the fill and border are SwiftUI chrome on the public wrapper.
private struct ScrollingTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    /// The Return-confirms action, read from the environment by the public wrapper and
    /// handed down here. `nil` makes Return finish editing the field — still consumed,
    /// never turned into a paragraph break (see the Coordinator's `doCommandBy`).
    var submitAction: FieldSubmitAction?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ConditionalScrollView {
        let scrollView                         = ConditionalScrollView()
        scrollView.borderType                  = .noBorder
        scrollView.hasVerticalScroller         = false  // starts disabled; enabled when content overflows
        scrollView.hasHorizontalScroller       = false
        scrollView.autohidesScrollers          = true
        // Both the scroll view (set in commonInit) and its clip view are transparent so
        // the SwiftUI rounded fill behind the representable shows through.
        scrollView.contentView.drawsBackground = false

        let textView         = InnerTextView()
        textView.delegate    = context.coordinator
        textView.string      = text
        textView.placeholder = placeholder
        textView.minSize     = NSSize(width: 0, height: 0)
        textView.maxSize     = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: ConditionalScrollView, context: Context) {
        // Keep the coordinator's parent current: SwiftUI recreates this representable
        // struct on every update but reuses the coordinator, so refreshing the reference
        // ensures textDidChange always writes through the latest binding.
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? InnerTextView else { return }

        var textChanged = false
        if textView.string != text {
            textView.string = text
            textChanged = true
        }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }

        // When the text changes programmatically (e.g. a different record is loaded into
        // the sheet), re-evaluate overflow so scrolling engages immediately rather than
        // only after the first keystroke. Initial appearance is handled by the scroll
        // view's layout() override; user edits are handled in textDidChange.
        if textChanged {
            scrollView.updateScrollability()
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollingTextViewRepresentable

        init(_ parent: ScrollingTextViewRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? InnerTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            (tv.enclosingScrollView as? ConditionalScrollView)?.updateScrollability()
        }

        // MARK: Return / Option-Return
        //
        // AppKit's own routing, not an override of it: `interpretKeyEvents` translates a
        // key press into a selector via the standard key bindings and offers it to the
        // delegate here first; returning true means "handled, do not act." Two selectors
        // matter: insertNewline(_:) (Return) and insertNewlineIgnoringFieldEditor(_:)
        // (Option-Return).
        //
        // Return never inserts a paragraph break. With a submit action installed (a
        // popover's), it runs that action; a decline (confirming button disabled) leaves
        // the key consumed and inert, as Return against any disabled default button is.
        //
        // With NO action installed — every field on the FilmSheet itself — Return
        // finishes editing: the field gives up first responder, its text stays exactly as
        // typed (it is live-bound, so there is nothing further to commit), and the next
        // Return, now with no field active, reaches the sheet and saves it. That is the
        // sheet's Return rule: an active field takes Return first. The single-line fields
        // follow the same rule through FilmSheetView's key monitor.
        //
        // Option-Return is deliberately NOT consumed — it's the sole way to enter a line
        // break. `NSTextView`'s own insertNewlineIgnoringFieldEditor(_:) inserts one
        // without ending editing; returning false hands it straight through, so undo,
        // marked text, and the usual textDidChange-driven layout update all run
        // unmodified. This is AppKit's standard binding for the selector — the same one
        // system commit-on-Return fields use.
        //
        // Marked text guard: while an input method has an uncommitted composition on
        // screen, Return commits that composition, so intercepting it would discard the
        // user's in-progress input — the composition wins and the key goes to the text
        // view in that one case.
        func textView(_ textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            guard !textView.hasMarkedText() else { return false }
            if let submitAction = parent.submitAction {
                submitAction.perform()
            } else {
                unsafe textView.window?.makeFirstResponder(nil)
            }
            return true
        }
    }
}

// MARK: - Field Edge Treatment

/// The outline and drop shadow shared by every boxed field on the FilmSheet:
/// `ReorderableStringList`, `ReorderableFramesList`, and
/// `FixedHeightScrollingTextView`.
///
/// One definition rather than three copies: the two reorderable lists each carried a
/// byte-identical private set of these constants, and the text view carried a
/// mismatched flat outline of its own — so a field meant to look like its neighbors
/// could silently drift. The lists' treatment is the reference, lifted out here.
///
/// Declared in this low-level primitives file, not beside the lists, because the text
/// view lives here too and reaching up into a domain-level file for its own chrome
/// would invert the intended layering.
///
/// Shape is deliberately NOT here: the lists round with `.continuous`, while
/// `FixedHeightScrollingTextView` uses the default circular style because its corner
/// must match the AppKit `drawFocusRingMask` the focus ring strokes against — different
/// requirements that happen to share a radius, so each call site states its own style
/// and reads only the radius from here.
enum FieldEdgeTreatment {

    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1

    /// Strength of the outline.
    ///
    /// The border reads stronger than a nominal `separatorColor` would suggest,
    /// because it sits on the window background rather than over a fill that
    /// would dilute it. This scales the system color back down; lower is
    /// fainter, 1 is the system color at full strength.
    static let borderOpacity: Double = 0.2

    /// Fraction of the drop at which the outline begins fading out. Above this
    /// it is at `borderOpacity`; at the bottom edge it is gone.
    static let borderFadeStart: Double = 0.1

    /// Border color, fading to nothing over the last stretch of the drop.
    /// Vertical rather than uniform so the lower edge is carried by the shadow.
    static let borderGradient = LinearGradient(
        stops: [
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity), location: 0.0),
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity), location: borderFadeStart),
            .init(color: Color(NSColor.separatorColor).opacity(0), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // Deliberately understated — enough to seat the field on the sheet without
    // reading as a raised control.
    static let shadowOpacity: Double = 0.16
    static let shadowRadius: CGFloat = 1.5
    static let shadowOffsetY: CGFloat = 1
}

// MARK: - FixedHeightScrollingTextView

/// Fixed-height multiline text field with native AppKit styling and the system focus
/// ring (with the standard shrink-to-fit animation).
///
/// Usage:
///     FixedHeightScrollingTextView(text: $text, placeholder: "Notes")
///         .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: 3))
///
struct FixedHeightScrollingTextView: View {
    @Binding var text: String
    var placeholder: String = ""

    /// Return-confirms action for this field, supplied by the enclosing presentation.
    ///
    /// Read from the environment rather than taken as an initializer argument, so a
    /// popover states its action once for every field inside it, and the sheet's own
    /// fields — which install none — all share the one "Return finishes the field" rule.
    ///
    /// Because the installed value is a reference type with stable identity (see
    /// `FieldSubmitAction`), reading it here costs nothing: the environment value never
    /// changes for the life of the presentation, so this never becomes a source of
    /// re-evaluation.
    @Environment(\.fieldSubmitAction) private var submitAction

    /// Per-lineCount memoization for fixedHeight(lineCount:). The measurement below
    /// depends only on lineCount and the system font at its standard size — neither
    /// of which changes across the four call sites (Details, Metadata ×2, Notes ×3)
    /// during a single app session — so the NSTextStorage/NSLayoutManager/
    /// NSTextContainer measurement sweep only needs to run once per distinct
    /// lineCount value rather than on every SwiftUI body evaluation. Without this
    /// cache, the measurement re-ran on every render of the Details/Metadata/Notes
    /// tabs (every keystroke, every canConfirm toggle, etc.), including the first
    /// render that lands inside the sheet's presentation transaction — competing
    /// with CoreAnimation for main-thread time at exactly the moment the sheet-open
    /// animation is handed its first frame budget. Mirrors the rationale already
    /// documented on ViewingDatesTable's cached DateFormatters ("~0.5ms init cost").
    /// @MainActor-isolated: every call site is a SwiftUI body evaluation, which is
    /// already confined to the main actor, so no additional synchronization or
    /// actor hop is needed.
    @MainActor
    private static var heightCache: [Int: CGFloat] = [:]

    /// Computes the frame height for a given number of visible lines.
    /// Uses NSLayoutManager to measure the true rendered line height for the system
    /// font, rather than assuming a fixed per-line constant.
    @MainActor
    static func fixedHeight(lineCount: Int) -> CGFloat {
        if let cached = heightCache[lineCount] { return cached }

        let font      = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let storage   = NSTextStorage(string: "Ay")
        let manager   = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 5
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        storage.addAttribute(.font, value: font,
                             range: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)
        let lineHeight = manager.usedRect(for: container).height
        let result = ceil(lineHeight * CGFloat(lineCount) + 8)
        heightCache[lineCount] = result
        return result
    }

    /// Vertical offset that aligns an adjacent field label with this control's
    /// first line of text.
    ///
    /// Exposed statically, the way `ReorderableStringList.labelTopOffset` is, so the
    /// six call sites that pair a label with this control apply one rule instead of six copies of a literal.
    ///
    /// Sign convention: positive moves DOWN.
    static let labelTopOffset: CGFloat = 4

    var body: some View {
        // The focus ring is drawn by ConditionalScrollView at the AppKit level. The fill
        // and border are SwiftUI here, using Color(NSColor:) values that re-resolve for
        // light/dark automatically. These are applied as a rounded .background and
        // .overlay — NOT a .clipShape: a clip would mask away the exterior focus ring
        // (drawn ~3px beyond the field edge), whereas a background/overlay only draws
        // behind/over the field without masking it. The corner radius and shape match
        // the AppKit drawFocusRingMask (circular, radius 6) so the ring hugs the border.
        //
        // The outline and shadow are `FieldEdgeTreatment`'s, shared with the two
        // reorderable lists, which is what makes a text field and a list sitting
        // in the same column read as the same kind of object. The flat
        // `tertiaryLabelColor` hairline that used to be here was neither the same
        // color nor the same weight as theirs.
        //
        // Note the shape style: the lists round with `.continuous`, this rounds
        // circular. That is not an oversight — see the note on
        // `FieldEdgeTreatment`. Only the radius is shared.
        ScrollingTextViewRepresentable(
            text: $text,
            placeholder: placeholder,
            submitAction: submitAction
        )
        .background(
            // The shadow is cast by the fill shape alone rather than by the
            // finished control.
            //
            // Applying `.shadow` to the outer view would ask SwiftUI to derive a
            // silhouette from content that includes a hosted `NSView`, and the
            // usual remedy for that — `.compositingGroup()` — would try to
            // flatten a layer tree containing that same hosted view. Casting the
            // shadow off the background shape sidesteps both: the shape is a
            // plain opaque rounded rect of exactly the field's bounds, so the
            // silhouette is exact, and the only visible part of the shadow is
            // the part outside the field, which is all that was ever wanted.
            // It also cannot clip the exterior focus ring, since nothing here
            // masks.
            // Inset by the border width, so the fill stops where the border
            // begins instead of painting underneath it.
            //
            // This is the same defect the reorderable lists' alternating row
            // background had, and the same remedy: `separatorColor` is
            // translucent, so anything drawn beneath the border composites
            // through it. A fill running to the full bounds therefore tinted the
            // outline from below, muddying the gradient and reading as a field
            // one pixel oversized on every side — the border was there, but it
            // was sitting on top of the field's own color rather than on the
            // sheet.
            //
            // `strokeBorder` insets its stroke by half the line width and draws
            // inward, so a 1pt border occupies exactly the outer 1pt ring. A fill
            // inset by that same 1pt abuts it precisely: no gap, no overlap.
            RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius)
                .inset(by: FieldEdgeTreatment.borderWidth)
                .fill(Color(NSColor.textBackgroundColor))
                .shadow(color: .black.opacity(FieldEdgeTreatment.shadowOpacity),
                        radius: FieldEdgeTreatment.shadowRadius,
                        x: 0,
                        y: FieldEdgeTreatment.shadowOffsetY)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius)
                .strokeBorder(FieldEdgeTreatment.borderGradient,
                              lineWidth: FieldEdgeTreatment.borderWidth)
        )
    }
}
