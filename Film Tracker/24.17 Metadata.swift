// MARK: - Metadata.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Metadata module (module 06) in RightSidebar's Details tab. It sits at the bottom of
// RTabDetails' stack. RTabDetails supplies the scroll view
// and outer padding. This module draws two headers: "Cast and Crewmen" over the crew block,
// and "Metadata" over everything below it.

import SwiftUI

struct Metadata: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    /// The switch that gates WatchDetails' glyphs. Read through @AppStorage so that toggling it
    /// in Settings redraws this module immediately.
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

    // Timestamps and release date are derived from the film, not cached in `@State`. A cache
    // written from `onChange(of: film)` would render the module twice per selection, first with
    // stale strings. The extra pass re-lays out the whole module stack, which costs more than
    // the parsing it saves. Deriving keeps one selection to one pass.
    private var cachedLastModified: String {
        film.map { RSBHelpers.formatFullTimestamp($0.lastModified) } ?? ""
    }

    private var cachedDateAdded: String {
        film.map { RSBHelpers.formatFullTimestamp($0.dateAdded) } ?? ""
    }

    // releaseDate is stored as "yyyy-MM-dd'T'12:00:00'Z'" (see FSTabDetails). formatDateString
    // renders it as "Month Day, Year", such as "November 4, 2025". A non-empty but unparseable
    // value shows "Unknown date".
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

    // MARK: - Metadata Content
    // Block order: crew and studio, then naming and sorting, video characteristics, and dates
    // and text. The crew block leads because readers scan it first.
    @ViewBuilder
    private var metadataContent: some View {
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                // MARK: Crew / studio block
                // Each section is hidden when empty. The trailing divider appears only if a section
                // drew, so a film with no credits does not open with a bare rule.
                let hasAnyCrewField = !film.cast.isEmpty
                    || !film.directors.isEmpty
                    || !film.producers.isEmpty
                    || !film.executiveProducers.isEmpty
                    || !film.screenwriters.isEmpty
                    || !film.composer.isEmpty
                    || !film.studio.isEmpty
                if hasAnyCrewField && !RSBProfileFlags.noCrewBlock {
                    // The header is inside the gate, so a film with no credits shows no stray title or divider.
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
                // Headed by "Metadata", which titles this block and every block below it. The header
                // is unconditional because the later blocks always render.
                //
                // The Special Sorting row was dropped as duplicative: WatchDetails already reports the
                // same values as the suffix on its "Next Up for Rotation" row. FilmSnapshot.specialSorting
                // is unchanged and still drives that row, MetadataCache's rotation exclusions, and the
                // Film Queue add guard in LeftSidebar.
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
                // The divider appears only if this block drew a field, so an empty block does not stack rules.
                if hasSortName || hasHofPosition {
                    Divider()
                }

                // MARK: Video characteristics block
                // Never empty: "Color" and "Encoding Tool(s)" always render, so the trailing divider is unconditional.
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
                // Subtitles and Aspect Ratio share a row. Hidden when both are empty.
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
                // Frame Rate, HB RF Value, and Color. Color is always present. The numeric fields hide
                // when empty, and the row shrinks from three columns to two or one.
                let frameRateStr = RSBHelpers.formatNumericalValue(film.frameRate)
                let hbRFStr      = RSBHelpers.formatNumericalValue(film.libraryHBRFValue)
                let hasFrameRate = !frameRateStr.isEmpty
                let hasHBRF      = !hbRFStr.isEmpty
                // Color always shows, since it is a Yes/No value.
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
                    // Both numeric fields absent: Color alone.
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
                // lastModified and dateAdded are system-managed and always shown. releaseDate is
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
