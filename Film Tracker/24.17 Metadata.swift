// MARK: - Metadata.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "Details" tab, module 06.
//
// Formerly the standalone "Metadata" tab (RTabMetadata, file 24_20). It is now a module
// rendered at the bottom of RTabDetails' stack, so it supplies no SidebarScrollView or
// outer padding of its own — RTabDetails owns both — and it is named and numbered like
// every other Details module. It draws two headers rather than one: "Cast and Crewmen"
// over the crew block, and "Metadata" over everything below it.

import SwiftUI

struct Metadata: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    /// The same switch that gates WatchDetails' glyphs, read through @AppStorage for the
    /// same reason: so toggling it in Settings redraws this module immediately.
    @AppStorage(preference: Preferences.showWatchDetailsAnnotationGlyphsKey)
        private var showAnnotationGlyphs: Bool

    /// Passes a glyph name through when the switch is on, `nil` when it is off.
    private func gatedGlyph(_ systemName: String) -> String? {
        showAnnotationGlyphs ? systemName : nil
    }

    /// WatchDetails' value-row tint: capped at `.secondary` so the glyph reads as an
    /// annotation on the value. Placeholder rows resolve their own tertiary gray.
    private var glyphTint: Color {
        Preferences.capWatchDetailsGlyphColorAtSecondary ? .secondary : .primary
    }

    // Formatted timestamps and release date, derived directly from the film rather
    // than cached in `@State` and refreshed from an `onChange`.
    //
    // The caching this replaces was a pessimization, and the profiling that showed it
    // is worth recording. Writing these into `@State` from an `onChange(of: film)`
    // means a new film renders the module twice: once with the previous film's strings
    // still in place, then again once the handler has written the new ones. The parse
    // and format work being avoided measured 0.4-2.8 ms per selection; the extra render
    // pass it bought costs vastly more than that, because it re-lays out the whole
    // module stack. Deriving the values makes the module a pure function of the film,
    // so one selection is one pass.
    private var cachedLastModified: String {
        film.map { RSBHelpers.formatFullTimestamp($0.lastModified) } ?? ""
    }

    private var cachedDateAdded: String {
        film.map { RSBHelpers.formatFullTimestamp($0.dateAdded) } ?? ""
    }

    // releaseDate is stored as "yyyy-MM-dd'T'12:00:00'Z'" (see FSTabDetails);
    // formatDateString is the application's canonical parser/formatter and renders it
    // as "Month Day, Year" (e.g. "November 4, 2025"). Falls back to "Unknown date" only
    // if the stored value is non-empty, but unparseable.
    private var cachedReleaseDate: String {
        guard let film else { return "" }
        return film.releaseDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : formatDateString(film.releaseDate)
    }

    var body: some View {
        metadataContent
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // This module carries two module titles, drawn with the shared
    // RSBHelpers.moduleHeader: "Cast and Crewmen" over the crew block, and "Metadata"
    // over everything from Sort Name down.

    // MARK: - Metadata Content
    // Block order: crew/studio → naming/sorting → video characteristics → dates/text.
    // The crew block leads because it is the block a reader scans first; the naming and
    // video-characteristics blocks that used to sit above it are now below the Studio
    // section, each behind its own divider.
    @ViewBuilder
    private var metadataContent: some View {
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                // MARK: Crew / studio block
                // Each section is hidden when the film has no members. The trailing
                // divider is gated on the block having drawn at least one section, so a
                // film with no crew credits does not open the module with a bare rule.
                let hasAnyCrewField = !film.cast.isEmpty
                    || !film.directors.isEmpty
                    || !film.producers.isEmpty
                    || !film.executiveProducers.isEmpty
                    || !film.screenwriters.isEmpty
                    || !film.composer.isEmpty
                    || !film.studio.isEmpty
                if hasAnyCrewField {
                    // Header is inside the gate so a film with no credits shows neither
                    // a stray title nor the trailing divider below.
                    RSBHelpers.moduleHeader("Cast and Crewmen")
                    if !film.cast.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: "Cast",
                            items: film.cast,
                            field: .cast,
                            glyph: gatedGlyph("person"), glyphColor: glyphTint)
                    }
                    if !film.directors.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Director", "Directors",
                                count: film.directors.count),
                            items: film.directors,
                            field: .directors,
                            glyph: gatedGlyph("movieclapper"), glyphColor: glyphTint)
                    }
                    if !film.producers.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Producer", "Producers",
                                count: film.producers.count),
                            items: film.producers,
                            field: .producer,
                            glyph: gatedGlyph("megaphone"), glyphColor: glyphTint)
                    }
                    if !film.executiveProducers.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Executive Producer", "Executive Producers",
                                count: film.executiveProducers.count),
                            items: film.executiveProducers,
                            field: .executiveProducer,
                            glyph: gatedGlyph("chair"), glyphColor: glyphTint)
                    }
                    if !film.screenwriters.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Screenwriter", "Screenwriters",
                                count: film.screenwriters.count),
                            items: film.screenwriters,
                            field: .screenwriter,
                            glyph: gatedGlyph("book.pages"), glyphColor: glyphTint)
                    }
                    if !film.composer.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Composer", "Composers",
                                count: film.composer.count),
                            items: film.composer,
                            field: .composer,
                            glyph: gatedGlyph("music.quarternote.3"), glyphColor: glyphTint)
                    }
                    if !film.studio.isEmpty {
                        RSBHelpers.searchableItemSection(
                            title: RSBHelpers.pluralizedTitle("Studio", "Studios",
                                count: film.studio.count),
                            items: film.studio,
                            field: .studio,
                            glyph: gatedGlyph("building.columns"), glyphColor: glyphTint)
                    }
                    Divider()
                }

                // MARK: Naming / sorting block
                // Headed by "Metadata", which titles this block and every block below it.
                // The header is unconditional because the video-characteristics and date
                // blocks that follow always render, even when both fields here are absent.
                //
                // "Special Sorting Parameter" used to appear here. It was removed as
                // duplicative: WatchDetails already reports the same values unconditionally
                // as the suffix on its "Next Up for Rotation" row. FilmSnapshot.specialSorting
                // is untouched and still drives that row, MetadataCache's rotation
                // exclusions, and the Film Queue add guard in LeftSidebar.
                RSBHelpers.moduleHeader("Metadata")
                let hasSortName    = !film.sortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasHofPosition = film.hofPosition > 0
                if hasSortName {
                    RSBHelpers.textSection(
                        title: "Sort Name", value: film.sortName,
                        glyph: gatedGlyph("text.line.magnify"), glyphColor: glyphTint)
                }
                if hasHofPosition {
                    RSBHelpers.textSection(
                        title: "Hall of Fame Membership", value: "Position \(film.hofPosition)")
                }
                // Divider is shown whenever this block drew at least one field, so an
                // empty block does not put two rules back to back.
                if hasSortName || hasHofPosition {
                    Divider()
                }

                // MARK: Video characteristics block
                // Never empty — "Color" (Bool) and "Encoding Tool(s)" always render — so
                // its trailing divider is unconditional.
                let hasDigitalSource = !film.digitalSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasDigitalSource {
                    RSBHelpers.textSection(
                        title: "Source of Rip", value: film.digitalSource,
                        glyph: gatedGlyph("scanner"), glyphColor: glyphTint)
                }
                // Single column section: "Library Version" (conditional).
                if !film.digitalVersion.isEmpty {
                    let versionDisplay = ViewingVersion(
                        rawValue: film.digitalVersion)?.displayName ?? film.digitalVersion
                    let libraryVersionText =
                        film.edited ? "\(versionDisplay) (edited)" : versionDisplay
                    RSBHelpers.textSection(
                        title: "Library Version", value: libraryVersionText,
                        glyph: gatedGlyph("film.stack"), glyphColor: glyphTint)
                }
                // Two-column section: "Subtitles" and "Aspect Ratio" — hidden when both are empty.
                let hasSubtitles   = !film.subtitles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasAspectRatio = !film.aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasSubtitles || hasAspectRatio {
                    if hasSubtitles && hasAspectRatio {
                        HStack(spacing: 12) {
                            RSBHelpers.textSection(
                                title: "Subtitles", value: film.subtitles,
                                glyph: gatedGlyph("captions.bubble"), glyphColor: glyphTint)
                            RSBHelpers.textSection(
                                title: "Aspect Ratio", value: film.aspectRatio,
                                glyph: gatedGlyph("aspectratio"), glyphColor: glyphTint)
                        }
                    } else if hasSubtitles {
                        RSBHelpers.textSection(
                            title: "Subtitles", value: film.subtitles,
                                glyph: gatedGlyph("captions.bubble"), glyphColor: glyphTint)
                    } else {
                        RSBHelpers.textSection(
                            title: "Aspect Ratio", value: film.aspectRatio,
                                glyph: gatedGlyph("aspectratio"), glyphColor: glyphTint)
                    }
                }
                // Dynamic row: "Frame Rate", "HB RF Value", "Color".
                // Color (Bool) is always present. The two numeric fields hide when zero.
                // Row adapts from three columns down to two or one as fields are absent.
                let frameRateStr = RSBHelpers.formatNumericalValue(film.frameRate)
                let hbRFStr      = RSBHelpers.formatNumericalValue(film.libraryHBRFValue)
                let hasFrameRate = !frameRateStr.isEmpty
                let hasHBRF      = !hbRFStr.isEmpty
                // Color is always displayed (Bool — always has a meaningful Yes/No value).
                if hasFrameRate && hasHBRF {
                    // All three visible — three-column layout.
                    HStack(spacing: 12) {
                        RSBHelpers.textSection(
                            title: "Frame Rate",
                            displayValue: frameRateStr,
                            isPlaceholder: false,
                            glyph: gatedGlyph("forward.frame"),
                            glyphColor: glyphTint)
                        RSBHelpers.textSection(
                            title: "HB RF Value",
                            displayValue: hbRFStr,
                            isPlaceholder: false,
                            glyph: gatedGlyph("rectangle.compress.vertical"),
                            glyphColor: glyphTint)
                        RSBHelpers.textSection(
                            title: "Color",
                            displayValue: film.color ? "Yes" : "No",
                            isPlaceholder: false,
                            glyph: gatedGlyph("camera.filters"),
                            glyphColor: glyphTint)
                    }
                } else if hasFrameRate {
                    // HB RF Value absent — two-column layout.
                    HStack(spacing: 12) {
                        RSBHelpers.textSection(
                            title: "Frame Rate",
                            displayValue: frameRateStr,
                            isPlaceholder: false,
                            glyph: gatedGlyph("forward.frame"),
                            glyphColor: glyphTint)
                        RSBHelpers.textSection(
                            title: "Color",
                            displayValue: film.color ? "Yes" : "No",
                            isPlaceholder: false,
                            glyph: gatedGlyph("camera.filters"),
                            glyphColor: glyphTint)
                    }
                } else if hasHBRF {
                    // Frame Rate absent — two-column layout.
                    HStack(spacing: 12) {
                        RSBHelpers.textSection(
                            title: "HB RF Value",
                            displayValue: hbRFStr,
                            isPlaceholder: false,
                            glyph: gatedGlyph("rectangle.compress.vertical"),
                            glyphColor: glyphTint)
                        RSBHelpers.textSection(
                            title: "Color",
                            displayValue: film.color ? "Yes" : "No",
                            isPlaceholder: false,
                            glyph: gatedGlyph("camera.filters"),
                            glyphColor: glyphTint)
                    }
                } else {
                    // Both numeric fields absent — single-column Color only.
                    RSBHelpers.textSection(
                        title: "Color",
                        displayValue: film.color ? "Yes" : "No",
                        isPlaceholder: false,
                        glyph: gatedGlyph("camera.filters"),
                        glyphColor: glyphTint)
                }
                // Single column section: "Encoding Tool(s)".
                RSBHelpers.textSectionList(
                    title: RSBHelpers.pluralizedTitle("Encoding Tool", "Encoding Tools",
                        count: film.encodingTool.count),
                    values: film.encodingTool,
                    glyph: gatedGlyph("hammer"),
                    glyphColor: film.encodingTool.isEmpty
                        ? Color(nsColor: .tertiaryLabelColor) : glyphTint)
                Divider()

                // MARK: Date / text / taxonomy block
                // lastModified and dateAdded are system-managed and always present for
                // any persisted film, so they are shown unconditionally. releaseDate is
                // user-entered and hidden when empty.
                let hasReleaseDate = !cachedReleaseDate.isEmpty
                if hasReleaseDate {
                    RSBHelpers.textSection(
                        title: "Release Date", value: cachedReleaseDate,
                    glyph: gatedGlyph("calendar"), glyphColor: glyphTint)
                }
                RSBHelpers.textSection(
                    title: "Last Modified",
                    value: cachedLastModified,
                    glyph: gatedGlyph("calendar.badge.checkmark"), glyphColor: glyphTint)
                RSBHelpers.textSection(
                    title: "Date Added to Library",
                    value: cachedDateAdded,
                    glyph: gatedGlyph("calendar.badge.plus"), glyphColor: glyphTint)
                // Single column section: "Alternate Title(s)" (conditional).
                if !film.alternateTitle.isEmpty {
                    RSBHelpers.textSectionList(
                        title: RSBHelpers.pluralizedTitle("Alternate Title", "Alternate Titles",
                            count: film.alternateTitle.count),
                        values: film.alternateTitle,
                        glyph: gatedGlyph("text.page.badge.magnifyingglass"), glyphColor: glyphTint)
                }
                // Single column section: user-authored "Notes" (hidden when empty).
                let hasNotes = !film.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasNotes {
                    RSBHelpers.textSection(
                        title: "Notes", value: film.notes)
                }
                // Single column section: "iTunes Comments" (sourced from imported iTunes
                // metadata; hidden when empty).
                let hasComments = !film.comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasComments {
                    RSBHelpers.textSection(
                        title: "iTunes Comments", value: film.comments,
                    glyph: gatedGlyph(RSBHelpers.privateGlyph("music.circle", fallback: "music.note.house")), glyphColor: glyphTint)
                }
                // Single column section: "Tags" (conditional).
                if !film.tags.isEmpty {
                    RSBHelpers.textSectionList(
                        title: "Tags", values: film.tags,
                        glyph: gatedGlyph("tag"), glyphColor: glyphTint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
