// MARK: - Header.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "Details" tab, module 01 (fixed position).
// Displays the selected film's thumbnail, rating, year of release, genre, and title.

import SwiftUI

struct Header: View {
    let filmID: UUID

    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    @State private var presentedFilmSheet: FilmSheet?

    // Convenience accessors for UI.
    private var filmName: String { return film?.name ?? "Untitled Film" }
    private var filmRating: Int { return film?.userRating ?? 0 }
    private var filmYear: String {
        let value = film?.releaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : "YEAR" }
    private var filmGenre: String {
        let value = film?.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : "No Genre Provided" }

    // Trimmed MPAA rating — empty string when absent or whitespace-only.
    private var mpaaRating: String {
        let value = film?.rating.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : ""
    }

    // MARK: - Badge Helpers

    /// Produces a secondary-colored text label inside a rounded outline,
    /// matching the existing releaseYear / genre badge style.
    ///
    /// - Parameter fixedWidth: When provided, the label's text is constrained
    ///   (centered) to this width *before* the badge's padding/background
    ///   are applied, so the resulting badge always occupies the same total
    ///   width regardless of how wide its specific characters happen to be.
    ///   Pass `nil` (the default) to let the badge hug its content, as before.
    @ViewBuilder
    private func outlineBadge(_ label: String, fixedWidth: CGFloat? = nil) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .modifier(OptionalFixedWidth(width: fixedWidth))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.quaternaryLabelColor), lineWidth: 1)
            )
    }

    /// Applies a fixed, centered width to a view only when a width is
    /// supplied; otherwise passes the view through unchanged. Used so
    /// `outlineBadge` can optionally stabilize a badge's width without
    /// affecting badges that should keep hugging their content (e.g. genre).
    private struct OptionalFixedWidth: ViewModifier {
        let width: CGFloat?
        func body(content: Content) -> some View {
            if let width {
                content.frame(width: width, alignment: .center)
            } else {
                content
            }
        }
    }

    // ── Layout tuning constants ─────────────────────────────────────────────
    // Poster image height. Width is derived automatically at the 2:3 aspect
    // ratio, so adjusting this single value scales the image proportionally.
    // The details column (rating, year/MPAA, genre) is pinned to the same
    // height and compresses or expands with it.
    private let posterHeight = CGFloat(82)
    private var posterWidth: CGFloat { (posterHeight * 2.0) / 3.0 }

    // Horizontal gap between the poster's trailing edge and the details column.
    private let posterToDetailsSpacing = CGFloat(16)

    // Vertical inset applied to the top and bottom of the details column.
    // Compresses the three detail rows (rating, year/MPAA, genre) symmetrically
    // toward the center without affecting any outer layout dimensions.
    private let detailsVerticalInset = CGFloat(2)

    // Fixed centered width reserved for the releaseYear badge's text,
    // applied before the badge's padding/background. Keeps the badge's total
    // width constant across films even though four-digit years (and the
    // "YEAR" placeholder) vary slightly in intrinsic rendered width, which
    // would otherwise nudge the MPAA rating badge that sits beside it.
    // Sized generously for four rounded-design characters at size 14.
    private let releaseYearBadgeTextWidth = CGFloat(36)

    // Vertical gap between the bottom of the poster row and the top of the title.
    // Note: the module also has a fixed .padding(.vertical, 8) applied to the
    // outer VStack, contributing 8 pt of space above the poster and 8 pt below
    // the title — those are structural and not tuned here.
    private let posterToTitleSpacing = CGFloat(12)
    // ────────────────────────────────────────────────────────────────────────

    // Fixed appearance constants (not layout-tuning knobs).
    private let buttonWidth  = CGFloat(38)
    private let cornerRadius = CGFloat(6) // Looks better being less than Preferences.cornerRadius

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: posterToTitleSpacing) {

            // ── Poster + details row, with Edit button overlaid ──────────
            // The HStack contains the poster (col 1) and an equidistant
            // details VStack (col 2). The ZStack wrapper floats the Edit
            // button in the top-trailing corner, fully outside the HStack's
            // layout negotiation so it can never compress col 2.
            ZStack(alignment: .topTrailing) {

                // ── Poster + details ─────────────────────────────────────
                // .frame(maxWidth:.infinity) ensures the HStack fills the full
                // available width rather than sizing to content within the ZStack.
                HStack(alignment: .top, spacing: 0) {

                    // Col 1 — poster thumbnail.
                    // The shadow bleeds outside the layout frame as pure visual
                    // decoration; the layout frame is exactly posterWidth × posterHeight,
                    // giving clean top/bottom alignment references for the details
                    // column with no offsets required.
                    posterThumbnail
                        .frame(width: posterWidth, height: posterHeight)
                        .padding(.trailing, posterToDetailsSpacing)

                    // Col 2 — details VStack.
                    // Pinned to posterHeight so the two Spacer()s distribute the
                    // three items evenly across exactly the poster's height —
                    // top item aligns with the poster's top edge, bottom item
                    // with its bottom edge. The genre badge uses
                    // .fixedSize(horizontal:true) so it can overflow rightward
                    // under the Edit button without truncating.
                    VStack(alignment: .leading, spacing: 0) {
                        ratingDisplayLabel
                        Spacer()
                        HStack(spacing: 6) {
                            outlineBadge(filmYear, fixedWidth: releaseYearBadgeTextWidth)
                            if !mpaaRating.isEmpty {
                                outlineBadge(mpaaRating)
                            }
                        }
                        Spacer()
                        outlineBadge(filmGenre)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, detailsVerticalInset)
                    .frame(height: posterHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // ── Edit button — top-trailing of the ZStack ─────────────
                // Lives outside the HStack so it participates in no width
                // negotiation with col 2. The inner Text frame drives the
                // button chrome to buttonWidth via .controlSize(.large).
                Button(action: editFilm) {
                    Text("Edit")
                        .frame(width: buttonWidth)
                }
                .controlSize(.large)
            }
            .padding(.top, 1) // End ZStack

            // ── Film title ───────────────────────────────────────────────
            // The title wraps to at most two lines. The switch decides whether a one-line
            // title still occupies both: with it on, the header's height — and so the
            // position of everything below it in the sidebar — is the same for every film
            // regardless of title length. Off, the second line's height is claimed only when
            // a title actually wraps into it, and short titles pull the tabs up.
            // Switch: Preferences.reserveTwoLineSidebarTitle.
            //
            // The reserved case is a hidden two-line sizer with the real title overlaid
            // bottom-leading, rather than `.lineLimit(2, reservesSpace:)` on the title
            // itself. Both reserve the same height, but `reservesSpace` puts a one-line
            // title on the FIRST line and leaves the blank one beneath it; the title should
            // instead sit on the second line, hugging the divider below, so a short title
            // and the last line of a wrapped one land in the same place. The sizer carries
            // the title's own font and weight so the height it reserves is the height two
            // lines of THIS text need — no measured constant to drift when the font changes.
            if Preferences.reserveTwoLineSidebarTitle {
                // The sizer owns the layout; `.hidden()` keeps it invisible but measured,
                // and `reservesSpace` is what makes a single space two lines tall. The
                // overlay is proposed exactly the sizer's frame, so a wrapped two-line title
                // fills it and a one-line title settles on its bottom edge.
                Text(verbatim: " ")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2, reservesSpace: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomLeading) {
                        titleText
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
            } else {
                titleText
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        } // End outer VStack
        .padding(.vertical, 8)
        .sheet(item: $presentedFilmSheet) { sheet in
            FilmSheetView(owner: sheet)
                .onDisappear { presentedFilmSheet = nil }
        }
    }

    // MARK: - Film Title
    /// The title itself, unstyled beyond its type ramp. Shared by the two layouts below so
    /// neither can drift from the other in font, weight, or content.
    private var titleText: some View {
        Text(filmName)
            .font(.title2)
            .fontWeight(.semibold)
    }

    // MARK: - Rating Display Label
    // The rated state (a monochrome "star.fill" plus a numeral) is the
    // definitive master for this label's footprint. The unrated state
    // (a two-tone "star.slash.fill" with no numeral) is constrained to
    // match that master exactly — same glyph frame, same numeral column
    // width, same overall height — so nothing in the row above/below it
    // shifts position when a film's rating changes to or from zero.
    private let ratingGlyphSize = CGFloat(16)
    private let ratingNumeralWidth = CGFloat(22)
    private let ratingLabelHeight = CGFloat(20)

    private var ratingDisplayLabel: some View {
        HStack(alignment: .center, spacing: 3) {
            Group {
                if filmRating == 0 {
                    Image(systemName: "star.slash.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.primary, .yellow)
                } else {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(width: ratingGlyphSize, height: ratingGlyphSize, alignment: .center)

            Text(filmRating == 0 ? "" : "\(filmRating)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .frame(width: ratingNumeralWidth, alignment: .leading)
        }
        .frame(height: ratingLabelHeight, alignment: .center)
    }
    
    // MARK: - Poster Thumbnail

    /// Holds the in-flight cache-miss load outside of `@State`.
    ///
    /// The task has to be retained so a newer request can cancel it, but retaining it
    /// in `@State` meant every film change wrote view state purely for bookkeeping —
    /// and a `@State` write invalidates the view whether or not anything visible
    /// changed. A reference box keeps the identity SwiftUI observes constant while the
    /// task inside it is replaced freely, so the bookkeeping costs no render pass.
    @MainActor
    private final class PosterLoadBox {
        var task: Task<Void, Never>?
    }

    @State private var loadBox = PosterLoadBox()

    /// Result of a cache-miss load, together with the UID it was loaded for.
    ///
    /// These are the only poster values that must live in `@State`: a disk load
    /// genuinely completes after the render that requested it, so its arrival has to be
    /// able to trigger a new one. A cache *hit* needs no state at all — see
    /// `displayedImage`.
    @State private var asyncLoadedImage: NSImage?
    @State private var asyncLoadedUID: String?

    /// The poster to draw, derived from the film rather than stored.
    ///
    /// Previously this was `@State`, written from the `onChange(of: film?.posterUID)`
    /// handler. That produced two renders for every selection: the first drew the new
    /// film's text beside the *previous* film's poster, and the handler's write then
    /// forced a second pass to correct it. Profiling showed the sidebar's per-selection
    /// cost is dominated by laying out this stack, so a wholly redundant second pass is
    /// expensive — and the work being cached is a single dictionary lookup
    /// (`PosterCache.getImageSync` is exactly `cache[uid]`).
    ///
    /// Reading the cache during body evaluation is safe here for reasons specific to
    /// this cache: the lookup is a non-mutating O(1) read with no LRU bookkeeping, the
    /// store is an unbounded dictionary, and the only paths that remove from it are an
    /// explicit poster deletion (where falling back to the placeholder is the correct
    /// result, and strictly better than the previous behavior of showing a deleted
    /// poster until the UID happened to change) and `clearMemory()`, which runs only
    /// during termination.
    ///
    /// The `asyncLoadedUID == uid` test also replaces the old completion-time identity
    /// guard structurally: a load that resolves after its film has been navigated away
    /// from simply is not the current UID, so its result can never be displayed.
    private var displayedImage: NSImage? {
        guard let uid = film?.posterUID, !uid.isEmpty else { return nil }
        if let cached = PosterCache.shared.getImageSync(for: uid) { return cached }
        return asyncLoadedUID == uid ? asyncLoadedImage : nil
    }

    private var posterThumbnail: some View {
        // The shadow is applied directly to the shape so it bleeds outside
        // the layout frame as pure visual decoration — the layout frame itself
        // is exactly posterWidth × posterHeight, giving clean top/bottom alignment references
        // for the adjacent details column with no offsets required.
        // `.continuous` on both this base shape and the image clip below: every poster site
        // in the app (gallery grid and list, this Header, the FilmSheet Poster tab) uses the
        // continuous ("squircle") corner curve, and the sheen overlay's corner fall-off
        // (PosterEdgeSheen.Profile.header) is rendered for that same curve.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
            .overlay(posterImageView)
            .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 2)
            // Load image when the poster UID changes. `onChange` only fires when the
            // observed value actually differs from the previous one, so no additional
            // old-vs-new comparison is performed here.
            .onChange(of: film?.posterUID) { _, newUID in
                ensurePosterLoaded(newUID)
            }
            .onAppear {
                // A cache hit needs nothing on first appearance either — the body
                // already read it. This covers the miss case, which onChange does not
                // fire for on the initial render.
                ensurePosterLoaded(film?.posterUID)
            }
            .onDisappear {
                // Cancel any in-flight cache-miss load on dismount. The
                // replace-on-new-request case is already handled by the cancel() at the
                // top of ensurePosterLoaded; this covers the dismount case so the task
                // does not run on against a view hierarchy that is going away.
                loadBox.task?.cancel()
                loadBox.task = nil
            }
    }

    /// Starts a disk load when, and only when, the poster is not already in the cache.
    ///
    /// This no longer has a cache-hit branch: on a hit `displayedImage` reads the cache
    /// directly during the render that needs it, so there is nothing to publish and no
    /// state to write. The function therefore does nothing at all for the common case,
    /// which is what removes the second render pass per selection.
    @MainActor
    private func ensurePosterLoaded(_ posterUID: String?) {

        // Supersede any load still in flight. Cancellation is now belt-and-braces
        // rather than load-bearing: a stale result that publishes anyway is filtered by
        // the UID test in `displayedImage` and can never be shown.
        loadBox.task?.cancel()
        loadBox.task = nil

        guard let uid = posterUID, !uid.isEmpty else { return }

        // Already cached — the body reads it directly; nothing to do.
        guard PosterCache.shared.getImageSync(for: uid) == nil else { return }

        // Cache miss. PosterCache.getImageAsync handles disk loading and cache
        // population internally, so no manual disk-fallback path is required when it
        // returns nil (nil = file genuinely not present on disk).
        loadBox.task = Task { @MainActor in
            let image = await PosterCache.shared.getImageAsync(for: uid)
            guard !Task.isCancelled else { return }
            asyncLoadedImage = image
            asyncLoadedUID = uid
            loadBox.task = nil
        }
    }

    // The overlay's content area is always exactly posterWidth × posterHeight —
    // that size is fixed by the `.frame(width: posterWidth, height: posterHeight)`
    // applied to posterThumbnail in `body`, and SwiftUI sizes an `.overlay` to
    // match its base view's resolved frame. A GeometryReader here would only
    // rediscover a size that's already known at compile time, at the cost of an
    // extra layout pass; using the constants directly removes that pass.
    private var posterImageView: some View {
        // Resolved once per render rather than read twice: `displayedImage` is now a
        // derived value, so each access is a fresh cache lookup.
        let image = displayedImage

        return ZStack {
            // Placeholder matching the main gallery version.
            if image == nil {
                placeholderContent(size: CGSize(width: posterWidth, height: posterHeight))
            }

            // Current image - displayed immediately when available.
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    // Pins the layout size to the poster box so the sheen overlay (and the
                    // clip) trace the visible rect rather than the fill-scaled image's
                    // overflowing bounds. Soft edge band: see 23.55 PosterEdgeSheen.swift.
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay { PosterEdgeSheen.overlay(profile: .header) }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .frame(width: posterWidth, height: posterHeight, alignment: .center)
    }
    
    // Extract placeholder into separate view to reduce complexity.
    @ViewBuilder
    private func placeholderContent(size: CGSize) -> some View {
        ZStack {
            Image(systemName: "film")
                .resizable()
                .scaledToFit()
                .frame(
                    width: size.width * 0.6,
                    height: size.height * 0.6
                )
                .foregroundStyle(.secondary)
                .opacity(0.4)
            
            // Last 10 characters only — see UUID.placeholderIDSuffix. Evaluated only on
            // the no-poster branch, so a film with artwork never builds the string at all.
            Text(filmID.placeholderIDSuffix)
                .font(.system(
                    size: min(size.width, size.height) * 0.12))
                .foregroundStyle(.secondary)
                .opacity(0.6)
                // The label is sized to its own text rather than to the poster box, so a
                // narrow poster frame cannot clip or truncate it back down.
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Button Actions
    @MainActor
    private func editFilm() {
        withAnimation {
            // Create the FilmSheet owner for the film.
            let fs = FilmSheet(coordinator: dataCoordinator, filmID: filmID)
            // Set the dismissal handler so the "Cancel" button works.
            fs.dismissHandler = { presentedFilmSheet = nil }
            // Present the sheet.
            self.presentedFilmSheet = fs
        }
    }
}
