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

    /// A secondary-colored label in a rounded outline, matching the release-year and genre badges.
    ///
    /// - Parameter fixedWidth: When set, the text is centered to this width before its padding and background
    ///   are applied, so the badge has the same total width whatever its characters. `nil` (the default) lets
    ///   the badge hug its content.
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

    // Fixed width for the release-year badge's text, applied before its padding and background. It keeps the
    // badge's total width constant across films, so a varying year does not nudge the MPAA badge beside it.
    // Sized for four characters at size 14.
    private let releaseYearBadgeTextWidth = CGFloat(36)

    // Vertical gap between the poster row and the title. The outer VStack's fixed 8 pt vertical padding is
    // structural and not tuned here.
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

                    // Col 1: poster thumbnail. The shadow bleeds outside the layout frame, which is exactly
                    // posterWidth by posterHeight. The details column aligns to its top and bottom edges with no offsets.
                    posterThumbnail
                        .frame(width: posterWidth, height: posterHeight)
                        .padding(.trailing, posterToDetailsSpacing)

                    // Col 2: details VStack. Pinned to posterHeight, so the two Spacers spread the three items across
                    // the poster's height. The top item aligns with the poster's top edge and the bottom item with its
                    // bottom edge. The genre badge uses .fixedSize(horizontal: true) so it can overflow rightward under
                    // the Edit button without truncating.
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
            // The title wraps to at most two lines. With `Preferences.reserveTwoLineSidebarTitle` on, the header
            // keeps the same height for every film, so content below stays put. With it off, the second line is
            // claimed only when a title wraps.
            //
            // The reserved case uses a hidden two-line sizer with the real title overlaid bottom-leading.
            // `.lineLimit(2, reservesSpace:)` would put a one-line title on the first line and leave a blank line
            // below. The title should sit on the second line, next to the divider. The sizer carries the title's
            // font and weight, so the reserved height always matches two lines of this text.
            if Preferences.reserveTwoLineSidebarTitle {
                // The sizer owns the layout. `.hidden()` keeps it measured but invisible, and `reservesSpace` makes a
                // single space two lines tall. The overlay takes the sizer's frame, so a wrapped title fills it and a
                // one-line title settles at the bottom.
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
    // The rated state (a monochrome "star.fill" with a numeral) is the master footprint. The unrated state (a
    // two-tone "star.slash.fill" with no numeral) matches it exactly in glyph frame, numeral width, and height.
    // Changing a rating to or from zero then shifts nothing in the row.
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

    /// Holds the in-flight cache-miss load outside `@State`. The task must be retained so a newer request can
    /// cancel it. Keeping it in `@State` would invalidate the view on every film change, even when nothing visible
    /// changed. A reference box keeps SwiftUI's identity constant while the task inside is replaced, so the
    /// bookkeeping costs no render pass.
    @MainActor
    private final class PosterLoadBox {
        var task: Task<Void, Never>?
    }

    @State private var loadBox = PosterLoadBox()

    /// A cache-miss load result and the UID it was loaded for. Only these poster values need `@State`, since a
    /// disk load completes after the render that requested it and must be able to trigger a new one. A cache hit
    /// needs no state (see `displayedImage`).
    @State private var asyncLoadedImage: NSImage?
    @State private var asyncLoadedUID: String?

    /// The poster to draw, derived from the film rather than stored. It was once `@State`, written from
    /// `onChange(of: film?.posterUID)`. That drew the new film's text beside the previous film's poster, and the
    /// handler's write then forced a second pass. The sidebar's per-selection cost is dominated by laying out this
    /// stack, so a redundant pass is expensive. The cached work is one dictionary lookup, `PosterCache.getImageSync`,
    /// which is `cache[uid]`.
    ///
    /// Reading the cache in `body` is safe for this cache. The lookup is a non-mutating O(1) read with no LRU
    /// bookkeeping. The unbounded dictionary loses entries only on an explicit poster deletion, where falling back
    /// to the placeholder is correct, or in `clearMemory()` at termination.
    ///
    /// The `asyncLoadedUID == uid` test also guards against stale loads. A load that finishes after navigation has
    /// moved on is not the current UID, so its result is never shown.
    private var displayedImage: NSImage? {
        guard let uid = film?.posterUID, !uid.isEmpty else { return nil }
        if let cached = PosterCache.shared.getImageSync(for: uid) { return cached }
        return asyncLoadedUID == uid ? asyncLoadedImage : nil
    }

    private var posterThumbnail: some View {
        // The shadow is applied to the shape itself, so it bleeds outside the layout frame, which stays exactly
        // posterWidth by posterHeight. The details column aligns to it with no offsets.
        // `.continuous` on both this base shape and the image clip below: every poster site
        // in the app (gallery grid and list, this Header, the FilmSheet Poster tab) uses the
        // continuous ("squircle") corner curve, and the sheen overlay's corner fall-off
        // (PosterEdgeSheen.Profile.header) is rendered for that same curve.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
            .overlay(posterImageView)
            .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 2)
            // Load when the poster UID changes. onChange fires only on an actual change.
            .onChange(of: film?.posterUID) { _, newUID in
                ensurePosterLoaded(newUID)
            }
            .onAppear {
                // A cache hit needs nothing here (the body already read it). A miss is loaded on
                // first appearance, which onChange does not cover.
                ensurePosterLoaded(film?.posterUID)
            }
            .onDisappear {
                // Cancel any in-flight load on dismount. Replacement is handled by the cancel() at the top of
                // ensurePosterLoaded; this covers teardown.
                loadBox.task?.cancel()
                loadBox.task = nil
            }
    }

    /// Starts a disk load only when the poster is not already in the cache. On a hit, `displayedImage` reads the
    /// cache during the render, so nothing is published and nothing is written.
    @MainActor
    private func ensurePosterLoaded(_ posterUID: String?) {

        // Supersede any load in flight. A stale result that still publishes is filtered by the UID test in
        // `displayedImage`, so it is never shown.
        loadBox.task?.cancel()
        loadBox.task = nil

        guard let uid = posterUID, !uid.isEmpty else { return }

        // Already cached: the body reads it directly.
        guard PosterCache.shared.getImageSync(for: uid) == nil else { return }

        // Cache miss. PosterCache.getImageAsync handles disk loading and caching. A nil result means the file is not
        // on disk, so there is no manual fallback.
        loadBox.task = Task { @MainActor in
            let image = await PosterCache.shared.getImageAsync(for: uid)
            guard !Task.isCancelled else { return }
            asyncLoadedImage = image
            asyncLoadedUID = uid
            loadBox.task = nil
        }
    }

    // The overlay is always exactly posterWidth × posterHeight, the frame applied to posterThumbnail in `body`
    // (an .overlay takes its base view's resolved frame). The constants are used directly, with no GeometryReader
    // and its extra layout pass.
    private var posterImageView: some View {
        // Resolved once per render: `displayedImage` is derived, so each access is a fresh cache lookup.
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
                    // overflowing bounds. Soft edge band: see PosterEdgeSheen in 23.50 GalleryItemView.swift.
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay { PosterEdgeSheen.overlay(profile: .header) }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .frame(width: posterWidth, height: posterHeight, alignment: .center)
    }
    
    // Placeholder, split out to reduce body complexity.
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
            
            // Last 10 characters (see UUID.placeholderIDSuffix). Evaluated only here, so a film with artwork never
            // builds the string.
            Text(filmID.placeholderIDSuffix)
                .font(.system(
                    size: min(size.width, size.height) * 0.12))
                .foregroundStyle(.secondary)
                .opacity(0.6)
                // Sized to its own text, not the poster box, so a narrow frame cannot clip it.
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Button Actions
    @MainActor
    private func editFilm() {
        // Routed through SheetHostView, like the menu's Edit command, rather than a sheet
        // presented here: a sheet of its own bypassed the sheet coordinator, so the menu
        // bar stayed enabled beneath it and its shortcuts (Add Film, Settings, and so on)
        // could try to present a second sheet, and alerts did not know a sheet was up.
        // The sidebar shows the single selected film, which is the film .editFilm opens.
        AppEventBus.shared.sendCommand(.editFilm)
    }
}
