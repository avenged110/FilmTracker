// MARK: - ViewGlyphs.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Single source of truth for the SF Symbols that identify a *view* — the sidebar rows,
// the GalleryTitleBar, and the gallery's empty-state placeholders.

import Foundation

// MARK: - View Glyphs
/// The one place a view's identifying SF Symbol is named.
///
/// The same logical item (a smart list, the Film Queue, Recents) is drawn in three
/// different places — the LeftSidebar row, the GalleryTitleBar, and the gallery's
/// empty-state placeholder — and each of those has historically been free to pick the
/// outline or the filled variant independently. That freedom is deliberate and is kept:
/// what is *not* kept is having the symbol's actual name typed out at every one of those
/// sites, which turned "change the smart-list glyph" into a project-wide grep.
///
/// Each entry below is a `Glyph`: one logical symbol carrying both of its variants. Call
/// sites keep choosing `.outline` or `.filled` as they always did, so swapping a symbol
/// here changes it everywhere at once while leaving each site's fill choice intact.
///
/// This type holds *names only*. Sizing, coloring, and rendering mode stay with the
/// views — `StandardPlaceholder` (GlobalUtilities.swift) and `RightSidebar`'s
/// `placeholderGlyph` own the placeholder presentation, `Label` owns the sidebar's.
enum ViewGlyphs {

    // MARK: - Glyph
    /// One logical symbol plus its filled counterpart.
    ///
    /// Most SF Symbols come as a matched `name` / `name.fill` pair, so `filled` is
    /// derived by default. Symbols that have no filled counterpart (or whose filled form
    /// is the only form that exists) are declared with `uniform(_:)`, which points both
    /// variants at the same name — a call site asking for `.filled` on one of those gets
    /// a symbol that renders rather than a blank frame.
    struct Glyph: Sendable, Hashable {
        /// The outline (unfilled) symbol name.
        let outline: String
        /// The filled symbol name.
        let filled: String

        /// Declares a symbol whose filled variant is the conventional `name.fill`.
        init(_ outline: String) {
            self.outline = outline
            self.filled = outline + ".fill"
        }

        /// Declares a symbol with an irregularly-named filled variant.
        init(outline: String, filled: String) {
            self.outline = outline
            self.filled = filled
        }

        /// Declares a symbol that has no separate filled variant. Both accessors return
        /// the same name, so a call site is free to ask for either.
        static func uniform(_ name: String) -> Glyph {
            Glyph(outline: name, filled: name)
        }
    }

    // MARK: - Library
    /// All Films. Sidebar uses `.outline`; title bar and placeholder use `.filled`.
    static let allFilms = Glyph("film.stack")
    /// Unwatched (and its Not Rated sub-category, which shares the glyph).
    static let unwatched = Glyph("eye.slash")
    /// Reports. Sidebar uses `.outline`; title bar uses `.filled`.
    static let reports = Glyph("chart.pie")
    /// Film Queue. No filled counterpart exists for this symbol.
    static let filmQueue = Glyph.uniform("text.line.first.and.arrowtriangle.forward")

    // MARK: - Lists
    /// A user-created list.
    static let userList = Glyph.uniform("list.and.film")
    /// Every smart list. `SmartListType.icon` and the smart-list placeholders both
    /// resolve here, so all eighteen types stay in lockstep by construction.
    static let smartList = Glyph("sparkles.rectangle.stack")

    // MARK: - Search
    /// The search view and its "No Results" placeholder.
    static let search = Glyph.uniform("magnifyingglass")
    /// A saved search: its sidebar row and its view's title bar.
    static let savedSearch = Glyph.uniform("text.magnifyingglass")
    /// The "No Results" placeholder shown when filters — rather than a query — are what
    /// emptied the gallery.
    static let activeFilters = Glyph("line.3.horizontal.decrease.circle")

    // MARK: - Recents
    /// The Recents sidebar row, which shares its glyph with the Recently Viewed
    /// category (the default sub-category the row opens on).
    static let recents = Glyph.uniform("calendar.badge.clock")
    static let recentlyViewed = recents
    static let recentlyRotated = Glyph.uniform("clock.arrow.2.circlepath")
    static let recentlyAdded = Glyph.uniform("goforward.plus")
    static let recentlyUpdated = Glyph.uniform("arrow.2.squarepath")
    static let recentlyPurchased = Glyph("opticaldisc")

    // MARK: - Imports
    /// The Imports sidebar row, which shares its glyph with the Metadata import
    /// category. Sidebar uses `.outline`; the category tile uses `.filled`.
    static let imports = Glyph("arrow.down.document")
    static let metadataImport = imports
    static let ratingsImport = Glyph("star.square.on.square")
    /// `ViewIdentifier.imports`' title-bar glyph. Imports has its own dedicated view and
    /// never actually reaches GalleryTitleBar, so this exists only to keep that switch
    /// exhaustive — it is intentionally distinct from `imports` above rather than folded
    /// into it, because it names a different symbol and nothing renders it today.
    static let importsTitleBarFallback = Glyph.uniform("rectangle.stack.fill.badge.plus")

    // MARK: - Momentary Row Glyphs
    /// Shown briefly in place of a sidebar row's own glyph to confirm a drop or an
    /// "Add to…" action landed. Used by both `ListRow` and the Film Queue row.
    static let rowCompletion = Glyph.uniform("checkmark.circle.fill")
    /// The Imports row's own completion glyph, distinct from `rowCompletion` because it
    /// confirms a finished import rather than an addition to a list.
    static let importsCompletion = Glyph.uniform("checkmark.rectangle.stack")
    /// Replaces `importsCompletion` when the finished import had failures. Deliberately
    /// the same symbol the session card uses for its own failure line, so the sidebar
    /// badge and the card the user lands on read as one signal.
    static let importsFailure = Glyph.uniform("exclamationmark.triangle.fill")
}
