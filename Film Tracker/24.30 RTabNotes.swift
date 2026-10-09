// MARK: - RTabNotes.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays film notes in the right sidebar's "Notes" tab.

import SwiftUI
import AppKit

struct RTabNotes: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var body: some View {
        SidebarScrollView {
            VStack(alignment: .leading, spacing: 0) {
                notesContent
            }
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Notes Content
    
    @ViewBuilder
    private var notesContent: some View {
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                RSBHelpers.textSection(
                    title: "Release", value: film.releaseUsed)
                RSBHelpers.textSectionList(
                    title: RSBHelpers.pluralizedTitle("Software Tool", "Software Tools", count: film.tools.count),
                    values: film.tools)
                // Two-column section: "HandBrake RF Value" and "Edit Date".
                HStack(spacing: 12) {
                    RSBHelpers.textSection(
                        title: "HandBrake RF Value",
                        value: RSBHelpers.formatNumericalValue(film.editedHBRFValue))
                    editDateSection(editDateString: film.editDate)
                }
                
                // Warnings (with pluralization)
                if film.warning.isEmpty {
                    RSBHelpers.textSection(
                        title: "Warning",
                        value: "")
                } else {
                    ForEach(film.warning.indices, id: \.self) { index in
                        RSBHelpers.textSection(
                            title: index == 0 ? RSBHelpers.pluralizedTitle("Warning", "Warnings", count: film.warning.count) : "",
                            value: film.warning[index])
                    }
                }
                
                RSBHelpers.textSection(
                    title: "Description", value: film.descriptionNotes)

                // Notes On Audio Timing
                if film.notesOnAudioTiming.isEmpty {
                    RSBHelpers.textSection(
                        title: "Notes On Audio Timing",
                        value: "")
                } else {
                    ForEach(film.notesOnAudioTiming.indices, id: \.self) { index in
                        RSBHelpers.textSection(
                            title: index == 0 ? "Notes On Audio Timing" : "",
                            value: film.notesOnAudioTiming[index])
                    }
                }

                // Special Audio Notes (with pluralization)
                if !film.specialAudioNotes.isEmpty {
                    ForEach(film.specialAudioNotes.indices, id: \.self) { index in
                        RSBHelpers.textSection(
                            title: index == 0 ? RSBHelpers.pluralizedTitle("Special Audio Note", "Special Audio Notes", count: film.specialAudioNotes.count) : "",
                            value: film.specialAudioNotes[index])
                    }
                }

                // Notes (with pluralization)
                if film.notesArray.isEmpty {
                    RSBHelpers.textSection(
                        title: "Note",
                        value: "")
                } else {
                    ForEach(film.notesArray.indices, id: \.self) { index in
                        RSBHelpers.textSection(
                            title: index == 0 ? RSBHelpers.pluralizedTitle("Note", "Notes", count: film.notesArray.count) : "",
                            value: film.notesArray[index])
                    }
                }
                
                framesSection(title: "HandBrake Frames", values: film.handbrakeFrames)
                // Only this table gets the aligned range layout. Its values are
                // time codes, which are uniform in character count and therefore
                // ragged only because the face is proportional — exactly what
                // the sub-columns correct. Frame numbers vary in length for real
                // reasons, so pinning them to fixed sub-columns would impose a
                // regularity the data does not have.
                framesSection(title: "Associated Time Codes",
                              values: film.correspondingTimecodes,
                              alignsRanges: true)
                
                // Legend — shown only when at least one entry in either table actually
                // carries one of the glyphs it explains, not merely when a table is
                // non-empty. A list of plain frame numbers displays no marks and no fade
                // indicators, so a key to those symbols has nothing to key.
                if FramesEntryParser.containsLegendGlyphs(film.handbrakeFrames)
                    || FramesEntryParser.containsLegendGlyphs(film.correspondingTimecodes) {
                    legendSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Custom Sections
    
    /// Renders the Edit Date section from the stored String value in FilmSnapshot.
    /// FilmSnapshot.editDate is a "yyyy-MM-dd" string (empty string = no date set),
    /// matching the format used by FSTabNotes when saving.
    @ViewBuilder
    private func editDateSection(editDateString: String) -> some View {
        let formattedDate = formatDateString(editDateString)
        let isPlaceholder = (formattedDate == "Unknown date") || editDateString.isEmpty
        let displayValue = isPlaceholder ? "None provided" : formattedDate

        RSBHelpers.textSection(
            title: "Edit Date",
            displayValue: displayValue,
            isPlaceholder: isPlaceholder
        )
    }
    
    // MARK: - Frames Section Display
    
    @ViewBuilder
    private func framesSection(title: String,
                               values: [String],
                               alignsRanges: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader(title)
            
            // Content
            if values.isEmpty {
                Text("None provided")
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .font(.system(size: RSBHelpers.rowFontSize))
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .sidebarRowContainer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(values.indices, id: \.self) { index in
                        frameEntryRow(index: index + 1,
                                      entry: values[index],
                                      alignsRanges: alignsRanges)
                    }
                }
                .sidebarRowContainer()
            }
        }
    }
    
    @ViewBuilder
    private func frameEntryRow(index: Int, entry: String, alignsRanges: Bool = false) -> some View {
        let parsed = FramesEntryParser.parse(entry)
        
        HStack(spacing: 8) {
            // Index number
            // Index number.
            //
            // Zero-padded and tinted to match the sheet's `ReorderableFramesList`
            // exactly: the two surfaces show the same rows of the same arrays, so
            // an index that reads one way while editing and another way in the
            // sidebar is a difference with nothing behind it. Padding also fills
            // the tens place on rows 1 through 9, which is what keeps the
            // trailing-aligned column reading as a column of numerals rather than
            // as one that starts ragged and squares up at row 10.
            //
            // `%02d` is a minimum width, not a cap, so an index that somehow ran
            // to three digits would widen rather than truncate.
            Text("\(Fmt.padded(index, 2)).")
                .font(.system(size: RSBHelpers.rowFontSize, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            
            // Frame value.
            //
            // The aligned variant draws the same string; it only distributes it
            // across three fixed sub-columns, and falls back to the plain run
            // for any value it cannot measure as a time-code range — so the two
            // branches agree on what a non-range entry looks like. Font, line
            // limit, and truncation are set inside that view, which needs the
            // point size to derive its widths; `.textSelection` is an
            // environment modifier and reaches its `Text`s either way.
            Group {
                if alignsRanges {
                    TimeCodeRangeText(text: parsed.text, fontSize: RSBHelpers.rowFontSize)
                } else {
                    Text(parsed.text)
                        .font(.system(size: RSBHelpers.rowFontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Indicators
            HStack(spacing: 5) {
                // Mark indicator (11pt wide)
                Group {
                    if parsed.mark != .none {
                        Image(systemName: parsed.mark.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 11, height: 11)
                
                // Fade-in indicator (27pt wide total: 11pt arrow + 2pt spacing + 14pt glyph)
                HStack(spacing: 2) {
                    Group {
                        if parsed.fadeIn != .none {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 11, height: 11)
                    
                    Group {
                        if parsed.fadeIn != .none {
                            fadeGlyphForStyle(parsed.fadeIn)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 11)
                }
                .frame(width: 27)
                
                // Fade-out indicator (27pt wide total: 11pt arrow + 2pt spacing + 14pt glyph)
                HStack(spacing: 2) {
                    Group {
                        if parsed.fadeOut != .none {
                            Image(systemName: "arrow.down.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 11, height: 11)
                    
                    Group {
                        if parsed.fadeOut != .none {
                            fadeGlyphForStyle(parsed.fadeOut)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 11)
                }
                .frame(width: 27)
            }
            .frame(width: 75) // Total: 11 + 5 + 27 + 5 + 27
        }
    }
    
    @ViewBuilder
    private func fadeGlyphForStyle(_ style: AudioFadeStyle) -> some View {
        Image(systemName: style.glyph)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Legend Section Display
    
    @ViewBuilder
    private var legendSection: some View {
        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Legend")
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                legendRow(glyph: "asterisk", text: "See notes")
                legendRow(glyph: "chevron.up", text: "See notes")
                legendRow(glyph: "number", text: "See notes")
                legendRow(glyph: "arrow.up.right.circle.fill", text: "Audio fade-in for this section")
                legendRow(glyph: "arrow.down.right.circle.fill", text: "Audio fade-out for this section")
                
                Text("Final Cut Pro audio fade effects:")
                    .font(.system(size: RSBHelpers.rowFontSize))
                    .padding(.top, 8)
                
                legendRow(glyph: "line.diagonal", text: "Linear")
                legendRow(glyph: "point.bottomleft.forward.to.point.topright.scurvepath", text: "S-curve")
                legendRow(glyph: "wave.3.up", text: "+3dB")
                legendRow(glyph: "wave.3.down", text: "-3dB")
            }
            .sidebarRowContainer()
        }
    }
    
    @ViewBuilder
    private func legendRow(glyph: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .leading)
            Text(text)
                .font(.system(size: RSBHelpers.rowFontSize))
        }
    }
}
