// MARK: - LibraryPDFReport.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Builds the complete-library table — one row per film — as a PDFTableSection.
//
// Layer three of the PDF stack described at the top of PDFCore.swift (88.00). This file
// owns the table's MEANING: which columns exist, what each cell says about a film, and
// which fill each state earns. It draws nothing itself; `LibraryPDFExporter` (43.10) hands
// the section it produces to `PDFTableRenderer` (88.10).
//
// Every measurement the table depends on lives in `LibraryTableLayout` below, in one block,
// so the layout can be retuned without reading the derivation rules — and every color comes
// from `PDFPalette`, so a shade named once is the same shade in every column that asks for
// it.

import AppKit
import Foundation

// MARK: - Layout

/// Every tunable measurement for the complete-library table, in one place.
///
/// # Column widths are WEIGHTS
///
/// `PDFTableRenderer` normalizes the column set to the page's content width before drawing
/// (see `PDFTableColumn.width`), so these numbers only have to be right RELATIVE to one
/// another. They are written as points against the landscape content width — 792pt page
/// less two 36pt margins, so 720pt — and currently sum to exactly that, which means each
/// value below is also its real on-page width today. Change one and the rest absorb the
/// difference proportionally; nothing falls off the page.
///
/// # Tuning guidance
///
/// `title` and `notes` are the two elastic columns — they wrap, and every other column is
/// sized to hold its widest expected value on one line. Take width from those two first.
/// The badge columns (`source`, the four purchase columns, `subs`, `chroma`) are sized for
/// their longest literal: "rem. DVD", "upscaled", "1080p", "disc", "B&W".
struct LibraryTableLayout {
    // MARK: Column widths

    /// The numerical index, in the fixed-width face. Measured against four fixed-width
    /// digits (18.4pt) so a four-figure library cannot wrap this column — and a wrapped
    /// index would grow the height of every row it landed on.
    ///
    /// Shared with the document's other two per-film sections, which number the same films
    /// and must present them in the same column at the same width — see `PDFColumnWidth`.
    var index: CGFloat = PDFColumnWidth.index
    /// The film title. The one column that TRUNCATES rather than wraps, so this width is a
    /// legibility budget rather than a fit: at 139pt it holds roughly fifty characters,
    /// past which no reasonable title is still ambiguous. Every point freed by tightening a
    /// measured column ends up here or in Notes.
    var title: CGFloat = 139
    /// The release year. Measured against four PROPORTIONAL digits — "2000" is 19.1pt in
    /// SF Pro against 18.4pt in SF Mono, so dropping the fixed-width face made this column
    /// wider, not narrower. The index column keeps the fixed-width face and its own width.
    var year: CGFloat = 20
    /// The digital source badge. Measured against "remaster" (28.1pt with padding).
    var source: CGFloat = 29
    /// The purchased Blu-ray/DVD badge. Its widest value, "remaster", needs only 28.1pt —
    /// the extra exists so this column plus `audio2K` can seat the "Purchased Blu-ray"
    /// banner spanning them both (47.9pt), with a point of margin rather than to the
    /// nearest tenth.
    var disc2K: CGFloat = 35
    /// That disc's audio channel configuration. Every value is now a bare "#.#", so this
    /// is measured against "2.0" (13.8pt). The "Audio" header is wider than that and takes
    /// the difference from the Disc header beside it rather than from this column — see
    /// the groups' `headerWeights` in `section(films:)`.
    var audio2K: CGFloat = 14
    /// The purchased 4K badge. Its widest value, "available", needs 27.6pt; the extra
    /// seats the "Purchased 4K UHD" banner spanning this column and `audio4K` (49.0pt),
    /// with a point of margin — sized to the exact tenth, it failed the fit check on
    /// floating-point equality alone.
    var disc4K: CGFloat = 36
    /// That disc's audio channel configuration. As `audio2K`.
    var audio4K: CGFloat = 14
    /// The subtitles badge. Sized by its "Subs." header (18.9pt), not by "disc".
    var subs: CGFloat = 19
    /// Notes — the film's own, plus everything derived into it (see `notesCell`). Elastic,
    /// and the column every point freed elsewhere is given to: it is the only column whose
    /// content has no upper bound, so width spent here is width spent on legibility.
    var notes: CGFloat = 258
    /// Total disc count across purchased releases. Sized by its "Discs" header (18.4pt).
    var discs: CGFloat = 19
    /// The HandBrake RF value. Two digits.
    var rf: CGFloat = 15
    /// The aspect ratio, at the narrowest width that holds a full-width value on one line.
    /// Measured against the three that compete for it: "Hybrid" (22.5pt), the "Aspect"
    /// header (21.9pt), and "2.39:1" (21.3pt). The open-matte tags are longer and wrap,
    /// which is the deliberate trade for the points this returns to Notes.
    var aspect: CGFloat = 23
    /// The chroma badge. Sized by its "Color" header (12.2pt of text) rather than by the
    /// "B&W" (11.8pt) it holds, which is the narrower of the two by a hair.
    ///
    /// One point wider than the "Chr." abbreviation it replaced needed, and that point came
    /// from Notes. "Chr." was shortened to save six points against the full word "Chroma";
    /// "Color" says the same thing, costs one, and does not have to be decoded.
    var chroma: CGFloat = 19
    /// The custom-edit badge. Sized by "Cust." (18.1pt), the first line of its two-row
    /// header — wider than the "yes" it holds.
    var customEdit: CGFloat = 19
    /// The most recent viewing date. Measured against "Sep 21, 2025" (38.1pt) — trimmed
    /// back to just clear of that once the table had been seen, with the points handed to
    /// the title.
    var lastWatched: CGFloat = 42

    // MARK: Page

    /// The page the table is drawn on. Landscape because sixteen columns do not read on a
    /// portrait page at any font size that is also readable.
    var geometry: PDFPageGeometry = .landscapeLetter

    /// The heading printed at the top of every page of the table.
    var sectionTitle: String = "Complete Library"

    // MARK: Derived

    /// Every column weight, summed. `PDFTableRenderer` normalizes the set to the page's
    /// content width before drawing (see `PDFTableColumn.width`), so this is what converts
    /// one weight into the width it will actually occupy.
    var totalWidth: CGFloat {
        index + title + year + source + disc2K + audio2K + disc4K + audio4K + subs
            + notes + discs + rf + aspect + chroma + customEdit + lastWatched
    }

    /// The Notes column's real on-page width, in points.
    ///
    /// Derived rather than read straight off `notes` because the weights only happen to sum
    /// to the content width today — and the one caller that needs this is deciding whether a
    /// string will fit, which a weight cannot answer.
    var notesWidth: CGFloat {
        totalWidth > 0 ? geometry.contentWidth * notes / totalWidth : notes
    }

    static let standard = LibraryTableLayout()
}

// MARK: - Report Builder

@MainActor
enum LibraryPDFReport {
    // MARK: Column indices
    // Named so the header groups below cannot drift out of step with the column array.

    private enum Column {
        static let index = 0
        static let title = 1
        static let year = 2
        static let source = 3
        static let disc2K = 4
        static let audio2K = 5
        static let disc4K = 6
        static let audio4K = 7
        static let subs = 8
        static let notes = 9
        static let discs = 10
        static let rf = 11
        static let aspect = 12
        static let chroma = 13
        static let customEdit = 14
        static let lastWatched = 15
    }

    // MARK: Film ordering

    /// The order EVERY per-film section of the library PDF lists films in: the way the
    /// gallery orders them by name — sort name when the film carries one, otherwise its
    /// title.
    ///
    /// Shared rather than restated because the document now has three per-film sections
    /// (this table, Viewing History, and Disc-based Releases) and their whole point is that
    /// a reader can carry a film's position from one to the next. A second copy of these
    /// four lines is all it would take for two of them to disagree.
    static func ordered(_ films: [FilmSnapshot]) -> [FilmSnapshot] {
        films.sorted { lhs, rhs in
            let left = lhs.sortName.isEmpty ? lhs.name : lhs.sortName
            let right = rhs.sortName.isEmpty ? rhs.name : rhs.sortName
            let comparison = left.localizedCaseInsensitiveCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            // Total order: two films sharing a sort name would otherwise be free to swap
            // between exports, which makes two PDFs of an unchanged library differ.
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: Section

    /// Builds the complete-library section: one row per film, ordered the way the gallery
    /// orders films by name (sort name when the film carries one, otherwise its title).
    static func section(films: [FilmSnapshot],
                        layout: LibraryTableLayout = .standard) -> PDFTableSection {
        let ordered = Self.ordered(films)

        let columns: [PDFTableColumn] = [
            // Values right-aligned so the digits line up; the label centered, because a
            // lone "#" pinned to the right edge reads as though it belongs to the title.
            PDFTableColumn("#",     width: layout.index,       alignment: .right,
                           headerAlignment: .center),
            PDFTableColumn("Title", width: layout.title,       alignment: .left),
            PDFTableColumn("Year",  width: layout.year,        alignment: .center),
            PDFTableColumn("Source", width: layout.source,     alignment: .center),
            PDFTableColumn("Disc",  width: layout.disc2K,      alignment: .center),
            PDFTableColumn("Audio", width: layout.audio2K,     alignment: .center),
            PDFTableColumn("Disc",  width: layout.disc4K,      alignment: .center),
            PDFTableColumn("Audio", width: layout.audio4K,     alignment: .center),
            PDFTableColumn("Subs.", width: layout.subs,        alignment: .center),
            PDFTableColumn("Notes", width: layout.notes,       alignment: .left),
            PDFTableColumn("Discs", width: layout.discs,       alignment: .center),
            // Wraps to "HB" over "rf" in the column's own merged header cell, the way
            // "Aspect Ratio" and "Cust. Edit" wrap in theirs. "rf" alone does not say
            // whose — the value is a HandBrake constant-quality figure, and the tool's
            // name is what makes the number interpretable.
            PDFTableColumn("HB rf", width: layout.rf,          alignment: .center),
            PDFTableColumn("Aspect Ratio", width: layout.aspect, alignment: .center),
            PDFTableColumn("Color", width: layout.chroma,      alignment: .center),
            PDFTableColumn("Cust. Edit", width: layout.customEdit, alignment: .center),
            PDFTableColumn("Last Watched", width: layout.lastWatched, alignment: .right,
                           headerAlignment: .center),
        ]

        // The left group covers DVDs too, but Blu-ray is what the column is FOR — a DVD is
        // the fallback state it reports, not the thing it is named after.
        // `headerWeights` lets the Disc/Audio labels split the span differently from the
        // data below them: "Audio" (19.0pt) is wider than the "5.1" it names, and "Disc"
        // (15.8pt) has width to spare, so the header row borrows across the divider rather
        // than the table paying for it on every row.
        let groups = [
            PDFHeaderGroup("Purchased Blu-ray",
                           columns: Column.disc2K..<(Column.audio2K + 1),
                           headerWeights: [subHeaderDisc, subHeaderAudio]),
            PDFHeaderGroup("Purchased 4K UHD",
                           columns: Column.disc4K..<(Column.audio4K + 1),
                           headerWeights: [subHeaderDisc, subHeaderAudio]),
        ]

        let rows = ordered.enumerated().map { position, film in
            row(for: film, index: position + 1, layout: layout)
        }

        return PDFTableSection(title: layout.sectionTitle,
                               columns: columns,
                               headerGroups: groups,
                               rows: rows)
    }

    /// The sub-header row's split of a purchased-disc group's span. Weights, normalized to
    /// the span the group actually covers — "Audio" needs 19.0pt and "Disc" 15.8pt, and the
    /// remainder goes to Disc because it is the wider label's neighbor.
    private static let subHeaderDisc: CGFloat = 29
    private static let subHeaderAudio: CGFloat = 19

    // MARK: Row

    private static func row(for film: FilmSnapshot, index: Int,
                            layout: LibraryTableLayout) -> [PDFCell] {
        let best2K = preferredNonFourK(film)
        let best4K = preferredFourK(film)
        let ownership = purchaseTint(film, best2K: best2K, best4K: best4K)

        // Whether the film has ANY release in each column's format — which is what
        // separates "you have not bought this" (red) from "there is nothing here to buy"
        // (no fill), across BOTH sub-columns of each purchased-disc group.
        let hasNonFourK = film.releases.contains {
            $0.format == ReleaseFormat.bluRay.rawValue || $0.format == ReleaseFormat.dvd.rawValue
        }
        let hasFourK = film.releases.contains { $0.format == ReleaseFormat.uhd4K.rawValue }

        return [
            PDFCell("\(index)", monospaced: true),
            PDFCell(film.name, fill: ownership, truncates: true),
            PDFCell(film.releaseYear, fill: ownership),
            digitalSourceCell(film),
            nonFourKDiscCell(film, purchased: best2K, formatExists: hasNonFourK),
            audioCell(best2K, formatExists: hasNonFourK),
            fourKDiscCell(film, purchased: best4K),
            audioCell(best4K, formatExists: hasFourK),
            subtitlesCell(film),
            notesCell(film, best2K: best2K, best4K: best4K, fill: ownership, layout: layout),
            discCountCell(film, fill: ownership),
            rfCell(film, ownership: ownership, hasPurchase: best2K != nil || best4K != nil),
            aspectRatioCell(film),
            chromaCell(film),
            customEditCell(film),
            lastWatchedCell(film),
        ]
    }

    // MARK: Ownership tint

    /// The fill carried across the columns that describe the film rather than a disc —
    /// Title, Year, Notes, Discs, and rf.
    ///
    /// Those five say nothing about ownership on their own, which made a purchased film and
    /// an unpurchased one read identically across more than half the row. Tinting them from
    /// the purchase state turns the whole row into one band the eye can follow: green when
    /// the film is owned on Blu-ray or 4K, light gray when the only copy owned is a DVD, and
    /// no fill at all when nothing has been bought — an unowned film is the table's neutral
    /// state, not a negative one, so it takes no color rather than red.
    private static func purchaseTint(_ film: FilmSnapshot,
                                     best2K: ReleaseSnapshot?,
                                     best4K: ReleaseSnapshot?) -> NSColor? {
        if best4K != nil { return PDFPalette.green }
        guard let best2K else { return nil }
        return best2K.format == ReleaseFormat.bluRay.rawValue
            ? PDFPalette.green
            : PDFPalette.lightGray
    }

    // MARK: Digital source

    /// The `digitalSource` field, narrowed to what fits the `source` column.
    ///
    /// A download source is reduced to its resolution alone ("1080p download" → "1080p");
    /// the disc sources become their badges. The remastered flag folded into the stored
    /// value (see `FilmDigitalSource.decompose`) becomes a "rem. " prefix.
    ///
    /// Fills rank the source by how good the user's viewing copy is: a Blu-ray rip is the
    /// benchmark (green), a remastered one qualifies that ranking rather than beating it
    /// (pale green), a high-definition download is a clear step down but still HD (dark
    /// green), and everything else — DVD, sub-720p downloads, an unset field — is the
    /// column's negative state (red).
    private static func digitalSourceCell(_ film: FilmSnapshot) -> PDFCell {
        let (source, remastered) = FilmDigitalSource.decompose(film.digitalSource)
        guard !source.isEmpty else { return PDFCell("", fill: PDFPalette.red) }

        let prefix = remastered ? "rem. " : ""

        switch source {
        case FilmDigitalSource.blurayDisc:
            // A remastered Blu-ray reads "remaster", not "rem. BD": the pale green already
            // says Blu-ray, so repeating the format costs width and tells the reader
            // nothing the fill has not.
            return remastered
                ? PDFCell(remasterLabel, fill: PDFPalette.paleGreen)
                : PDFCell("BD", fill: PDFPalette.green)
        case FilmDigitalSource.dvd:
            return PDFCell(prefix + "DVD", fill: PDFPalette.red)
        default:
            // "<resolution> download" → "<resolution>". An unrecognized value passes
            // through verbatim rather than being reduced to something it may not mean.
            let resolution = source.hasSuffix(downloadSuffix)
                ? String(source.dropLast(downloadSuffix.count))
                : source
            let isHD = resolution == "720p" || resolution == "1080p"
            return PDFCell(prefix + resolution,
                           fill: isHD ? PDFPalette.darkGreen : PDFPalette.red)
        }
    }

    /// The trailing text every download tier in `FilmDigitalSource` shares.
    private static let downloadSuffix = " download"

    /// The badge a remastered disc earns, whatever its format and wherever it appears.
    /// The cell's fill is what discloses the format; this word only says "remastered".
    private static let remasterLabel = "remaster"

    // MARK: Purchased non-4K disc

    /// The purchased Blu-ray or DVD that best represents what the user owns.
    ///
    /// Ranked by tier first — a remastered Blu-ray outranks a plain one, which outranks a
    /// remastered DVD, which outranks a plain DVD — and by `qualityScore` within a tier,
    /// which is the same "which of these discs is the better one" rule the rest of the app
    /// uses. Child releases of a combo pack are eligible: a disc inside a pack is still a
    /// disc the user owns.
    private static func preferredNonFourK(_ film: FilmSnapshot) -> ReleaseSnapshot? {
        let candidates = film.releases.filter {
            $0.purchased && ($0.format == ReleaseFormat.bluRay.rawValue
                             || $0.format == ReleaseFormat.dvd.rawValue)
        }
        return candidates.max { lhs, rhs in
            let leftTier = nonFourKTier(lhs)
            let rightTier = nonFourKTier(rhs)
            if leftTier != rightTier { return leftTier < rightTier }
            return lhs.qualityScore < rhs.qualityScore
        }
    }

    private static func nonFourKTier(_ release: ReleaseSnapshot) -> Int {
        let isBluRay = release.format == ReleaseFormat.bluRay.rawValue
        switch (isBluRay, release.remastered) {
        case (true, true):   return 3
        case (true, false):  return 2
        case (false, true):  return 1
        case (false, false): return 0
        }
    }

    /// Whether a non-4K disc was ever bought, and which kind.
    ///
    /// Blu-ray is the column's affirmative state (green); a remastered Blu-ray qualifies
    /// it (pale green); a DVD of either kind is neutral rather than good (light gray); and
    /// owning nothing on disc is the negative state — blank text over red, since the fill
    /// alone says it.
    ///
    /// The unpurchased state is split the same three ways the 4K column's is, for the same
    /// reason: a film with no Blu-ray at all is simply blank, while one that has a Blu-ray
    /// nobody bought reads "available" — qualified to "OOP" when every such release is out
    /// of print (the option exists only on the used market), or to "import" when the single
    /// release on offer is a foreign one. All three take red; the distinction is in the text.
    private static func nonFourKDiscCell(_ film: FilmSnapshot,
                                         purchased release: ReleaseSnapshot?,
                                         formatExists: Bool) -> PDFCell {
        guard let release else {
            // No disc on record at all is a non-event, not a gap: red there would flag a
            // purchase the user could not have made. Same rule as the 4K column's.
            guard formatExists else { return PDFCell("") }
            return PDFCell(unpurchasedBluRayNote(film), fill: PDFPalette.red)
        }

        // "remaster" in either format. The FILL is what names the format — pale green for
        // Blu-ray, light gray for DVD — so spelling it out again in the text would cost
        // width to repeat something already on the page.
        if release.format == ReleaseFormat.bluRay.rawValue {
            return release.remastered
                ? PDFCell(remasterLabel, fill: PDFPalette.paleGreen)
                : PDFCell("BD", fill: PDFPalette.green)
        }
        return PDFCell(release.remastered ? remasterLabel : "DVD", fill: PDFPalette.lightGray)
    }

    /// What the Blu-ray column says for a film with no purchased disc.
    ///
    /// Empty when there is no Blu-ray release on record at all. Otherwise "available", with
    /// two qualifications, in this order:
    ///
    /// - "OOP" when EVERY unpurchased Blu-ray on record is out of print. This is checked
    ///   first because it is the stronger fact: a release that is both an import and out of
    ///   print is one the user cannot simply go and buy, which is what the column is
    ///   reporting — "import" would understate it.
    /// - "import" when there is exactly ONE unpurchased Blu-ray and it is foreign. With
    ///   two or more on record the reader cannot tell which one the word describes, so the
    ///   cell falls back to the plain "available" and leaves the origins to the Notes
    ///   column.
    private static func unpurchasedBluRayNote(_ film: FilmSnapshot) -> String {
        let available = film.releases.filter {
            !$0.purchased && $0.format == ReleaseFormat.bluRay.rawValue
        }
        guard !available.isEmpty else { return "" }

        if available.allSatisfy({ isOutOfPrint($0) }) { return "OOP" }
        if available.count == 1, isImport(available[0]) { return "import" }
        return "available"
    }

    /// True when a release carries any tag meaning it is no longer pressed — the three
    /// price tiers plus the import-and-out-of-print tag, which `outOfPrintTags` itself
    /// deliberately excludes because the picker files it under imports.
    private static func isOutOfPrint(_ release: ReleaseSnapshot) -> Bool {
        release.marketAvailability.contains {
            ReleaseMarketAvailability.outOfPrintTags.contains($0)
                || $0 == ReleaseMarketAvailability.importOnlyOOP
        }
    }

    /// True for a release from anywhere but the domestic market — `ReleaseOrigin`'s rule.
    private static func isImport(_ release: ReleaseSnapshot) -> Bool {
        ReleaseOrigin.isImport(release.nationalOrigin)
    }

    // MARK: Purchased 4K disc

    /// The purchased 4K release that best represents what the user owns — native masters
    /// ahead of upscales, then `qualityScore` within that.
    private static func preferredFourK(_ film: FilmSnapshot) -> ReleaseSnapshot? {
        let candidates = film.releases.filter {
            $0.purchased && $0.format == ReleaseFormat.uhd4K.rawValue
        }
        return candidates.max { lhs, rhs in
            let leftNative = lhs.masterType == ReleaseMasterType.nativeFourK
            let rightNative = rhs.masterType == ReleaseMasterType.nativeFourK
            if leftNative != rightNative { return rightNative }
            return lhs.qualityScore < rhs.qualityScore
        }
    }

    /// Whether a 4K disc was ever bought, and what kind of master it carries.
    ///
    /// The unpurchased state is split in two because the two mean different things to the
    /// user: a film that HAS a 4K release nobody bought reads "available" over red — the
    /// red is what says "there is something here you have not bought". A film with no 4K
    /// release at all is a non-event, not a gap, so it takes no fill: red there would flag
    /// a purchase the user could not have made.
    private static func fourKDiscCell(_ film: FilmSnapshot,
                                      purchased: ReleaseSnapshot?) -> PDFCell {
        guard let purchased else {
            let existsUnpurchased = film.releases.contains {
                $0.format == ReleaseFormat.uhd4K.rawValue
            }
            return existsUnpurchased ? PDFCell("available", fill: PDFPalette.red) : PDFCell("")
        }

        switch purchased.masterType {
        case ReleaseMasterType.nativeFourK:
            return PDFCell("native", fill: PDFPalette.lightBlue)
        case ReleaseMasterType.upscaled:
            return PDFCell("upscaled", fill: PDFPalette.purple)
        default:
            // Purchased, but the master type is unset or from a build this one does not
            // know. The purchase is the fact worth printing; the master type is not
            // something this cell can vouch for, so it says neither "native" nor "upscaled".
            return PDFCell("4K", fill: PDFPalette.lightBlue)
        }
    }

    // MARK: Audio sub-column

    /// The audio channel configuration on whichever release the disc column to its left
    /// settled on, so the two cells always describe the same physical disc.
    ///
    /// An object-based track (Dolby Atmos, DTS:X) has no fixed channel count of its own —
    /// the stored value is the bed it falls back to — so it takes the qualifying pale green
    /// rather than the flat green a discrete configuration earns.
    ///
    /// Four states. No disc bought, but one on record, is the negative state (red, blank);
    /// no release in this format at all takes no fill, matching the Disc cell beside it.
    /// A disc whose channel field was never filled in is a THIRD thing — the disc is owned,
    /// the fact is simply unrecorded — and takes no fill: an affirmative green over an
    /// empty cell would read exactly like a good discrete track, which is the one reading
    /// the data does not support.
    private static func audioCell(_ release: ReleaseSnapshot?, formatExists: Bool) -> PDFCell {
        // The fourth state, shared with the Disc cell beside it: a film with no release in
        // this column's format has no audio to report and nothing to buy, so it takes no
        // fill. Red here would say "unbought" about a disc that does not exist.
        guard let release else {
            return formatExists ? PDFCell("", fill: PDFPalette.red) : PDFCell("")
        }
        let label = audioChannelsLabel(release.audioChannels)
        guard !label.isEmpty else { return PDFCell("") }
        return PDFCell(label, fill: audioFill(release))
    }

    /// The channel layout as a bare "#.#".
    ///
    /// "2.0 Mono" prints as "2.0" like any other 2.0 track: mono is a property of the MIX,
    /// not of the channel count, and the cell's fill is what reports it (see `audioFill`).
    /// Dropping the suffix is what lets the column be sized to three characters.
    private static func audioChannelsLabel(_ stored: String) -> String {
        stored == ReleaseAudioChannels.mono20 ? ReleaseAudioChannels.stereo20 : stored
    }

    /// The three states this column distinguishes, all through fill.
    ///
    /// A discrete multichannel track is the affirmative case (green). An object-based mix
    /// has no fixed channel count of its own — the stored value is only its fallback bed —
    /// so it qualifies rather than affirms (pale green). A mono track is a real step down
    /// from the stereo it is printed as, and takes the same dark green the column's
    /// neighbors use for "good, but not the benchmark".
    private static func audioFill(_ release: ReleaseSnapshot) -> NSColor {
        if ReleaseAudioFormat.isObjectBased(release.audioFormat) { return PDFPalette.paleGreen }
        if release.audioChannels == ReleaseAudioChannels.mono20 { return PDFPalette.darkGreen }
        return PDFPalette.green
    }

    // MARK: Subtitles

    /// The `subtitles` field as a badge.
    ///
    /// "On-disc only" is its own state — subtitles exist but not on the copy the user
    /// actually watches — so it gets its own dark gold rather than being folded into
    /// either yes or no. "Digital rip only" is an affirmative tag (see
    /// `FilmSubtitles.affirmativeTags`) and reads as "yes": the rip is the viewing copy.
    private static func subtitlesCell(_ film: FilmSnapshot) -> PDFCell {
        if FilmSubtitles.matches(film.subtitles, FilmSubtitles.onDiscOnly) {
            return PDFCell("disc", fill: PDFPalette.darkGold)
        }
        if FilmSubtitles.isAffirmative(film.subtitles) {
            return PDFCell("yes", fill: PDFPalette.green)
        }
        return PDFCell("", fill: PDFPalette.red)
    }

    // MARK: Notes

    /// The Notes column: every fact about this film that has no column of its own, joined
    /// through `PDFNoteList` — the shared list convention the Hall of Fame's Notes column
    /// also prints in.
    ///
    /// `preservesCase` marks the exceptions to that convention's casing rule — items that
    /// are proper names rather than descriptions. "Atmos" and "DTS:X" are two of them:
    /// lowercasing them the way an ordinary trailing item is lowercased would produce
    /// "atmos" and "dTS:X", which are not what either format is called.
    private static func notesCell(_ film: FilmSnapshot,
                                  best2K: ReleaseSnapshot?,
                                  best4K: ReleaseSnapshot?,
                                  fill: NSColor?,
                                  layout: LibraryTableLayout) -> PDFCell {
        // Built at full length first, then rebuilt with the studio names shortened only if
        // the full form would not fit. Abbreviating unconditionally would cost every reader
        // the studio's real name to save a cell that had room for it; abbreviating never
        // would let one long note truncate away the derived facts behind it.
        //
        // This REDUCES truncation rather than guaranteeing against it: an authored note has
        // no upper bound and no abbreviation can save a cell from one. What it does buy is
        // that the table's own derived items — which appear nowhere else in the document —
        // survive a note that would otherwise have pushed them off the end.
        let full = notesContent(film, best2K: best2K, best4K: best4K, abbreviated: false)
        let font = PDFFonts.font(size: layout.geometry.fontSize, weight: .semibold)
        let available = layout.notesWidth - (layout.geometry.cellPaddingX * 2)

        // Measured in the upright face. The italic runs are the same family at the same
        // size and differ by a fraction of a point across a studio name, which is within
        // the slack this decision already carries.
        let content = PDFDrawing.singleLineWidth(full.text, font: font) <= available
            ? full
            : notesContent(film, best2K: best2K, best4K: best4K, abbreviated: true)

        // Truncated, not wrapped: this column is the table's catch-all and a single long
        // authored note would otherwise grow its whole row to three or four lines, taking
        // the fifteen columns beside it along with it.
        return PDFCell(content.text, fill: fill, alignment: .left, truncates: true,
                       highlights: regionLockHighlight(for: content.regionLock)
                           + content.studios.map { PDFTextHighlight($0, italic: true) })
    }

    /// One rendering of the Notes column's content, plus what the cell needs to decorate it.
    private struct NotesContent {
        let text: String
        /// The region note as it was phrased, so the red highlight can be attached to the
        /// blocking form alone. See `regionLockHighlight(for:)`.
        let regionLock: String?
        /// The studio names that ended up in the text, at whatever length they ended up.
        /// Italicized in place — a studio is a proper noun inside a sentence, not part of
        /// the sentence.
        let studios: [String]
    }

    private static func notesContent(_ film: FilmSnapshot,
                                     best2K: ReleaseSnapshot?,
                                     best4K: ReleaseSnapshot?,
                                     abbreviated: Bool) -> NotesContent {
        var items: [PDFNoteList.Item] = []
        var studios: [String] = []

        // Leads the cell: a disc that will not play on the user's hardware is the one fact
        // here that changes what they can do with the shelf copy. The column now truncates
        // rather than wrapping, so lead position is also what guarantees it survives.
        let lock = regionLockNote(film)
        if let lock { items.append(PDFNoteList.Item(lock, preservesCase: true)) }

        // A steelbook is a property of the case, not of the disc, so it has no technical
        // column to live in — but it is the first thing the user wants to know about a
        // shelf copy. Reported once however many purchased releases carry the tag.
        if film.releases.contains(where: { $0.purchased && $0.hasArtwork == ReleaseArtwork.steelbook }) {
            // A brand name, so it is capitalized wherever it lands in the list.
            items.append(PDFNoteList.Item("Steelbook", preservesCase: true))
        }

        // The open-matte qualifier, displaced from the aspect column so that column can be
        // sized to a bare ratio. See `aspectRatioCell`.
        if isOpenMatte(film.aspectRatio) { items.append(PDFNoteList.Item("open matte")) }

        // Which cut the user's own copy is, and which OTHER cuts the discs on the shelf
        // would give them. Nothing else in the table reports either.
        items.append(contentsOf: versionNotes(film))

        // Two or more purchased discs of the SAME format — a double dip. Neither disc
        // column can report it: each shows the one release it settled on, so a second copy
        // of that format is invisible outside this note.
        for note in duplicateFormatNotes(film, abbreviated: abbreviated) {
            items.append(PDFNoteList.Item(note.text, preservesCase: true))
            studios.append(contentsOf: note.studios)
        }

        // Where a purchased disc was pressed, when that is anywhere but the United States.
        for note in importNotes(film) { items.append(PDFNoteList.Item(note, preservesCase: true)) }

        // Artwork is a property of the package, so like the steelbook tag it has no
        // technical column of its own.
        if film.releases.contains(where: {
            $0.purchased && ReleaseArtwork.negativeTags.contains($0.hasArtwork)
        }) {
            items.append(PDFNoteList.Item("missing artwork"))
        }

        // Which object-based format a pale-green Audio cell is reporting. The fill says
        // "object-based"; only this says which one, and the Audio column has no room for it.
        for format in objectBasedFormats(best2K: best2K, best4K: best4K) {
            items.append(PDFNoteList.Item(format, preservesCase: true))
        }

        // The film's own note goes LAST, after every derived item. Those items are facts
        // this table alone reports; the authored note is also on the film's own card, so
        // it is the part a truncated cell can afford to lose.
        let authored = film.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authored.isEmpty { items.append(PDFNoteList.Item(authored, preservesCase: true)) }

        return NotesContent(text: PDFNoteList.joined(items),
                            regionLock: lock,
                            studios: studios)
    }

    /// Colors a hard region lock red wherever it appears in the Notes column.
    ///
    /// This cell is a comma-joined list of a dozen unrelated facts, and one of them is not
    /// like the others: every other item describes a copy the user can watch, while this one
    /// says a disc on their shelf will not play. Set in the same gray-on-white as the rest
    /// of the sentence it is buried in, it reads as trivia. The color is what makes it
    /// findable at this type size without a column of its own.
    ///
    /// Deliberately NOT applied to "Loosely Region B locked", even though that string
    /// contains this one. The loose form means a bypass exists and the disc DOES play — it
    /// is the reassuring case, and flagging it in the same red as the blocking one would
    /// train the reader to ignore both. The same reasoning keeps the orange fill off
    /// `Region B (LL)` in the Disc-based Releases section, so the two sections agree about
    /// which region state is a problem.
    ///
    /// Matching is by phrase rather than by range because `PDFNoteList` may lowercase an
    /// item's initial depending on where it lands in the list — see `PDFTextHighlight`.
    /// Attached only when the note is the BLOCKING form. A substring match cannot make
    /// this distinction on its own — "Loosely Region B locked" contains "Region B locked"
    /// — so the decision is made here, where the two forms are still told apart, rather
    /// than left to the drawing code to infer from the text.
    private static func regionLockHighlight(for note: String?) -> [PDFTextHighlight] {
        guard note == hardRegionLockNote else { return [] }
        return [PDFTextHighlight(hardRegionLockNote, color: PDFPalette.red)]
    }

    // MARK: Notes — derived items

    /// "Region B locked" or "Loosely Region B locked", for a film with ANY purchased disc
    /// locked away from this library's Region A hardware.
    ///
    /// Any, not all: one unplayable disc on the shelf is a thing the user needs to know
    /// about, whether or not a second, playable copy sits beside it. The loose form is
    /// only claimed when no purchased disc is hard-locked — a hard lock anywhere in the set
    /// is the more restrictive fact and is what the note reports.
    ///
    /// Combo-pack children included, like every other note in this column: a bundled
    /// Blu-ray is a real disc with a real region code, and the box it came in does not
    /// make it play.
    private static func regionLockNote(_ film: FilmSnapshot) -> String? {
        let locked = film.releases.filter {
            $0.purchased && ReleaseRegionRules.regionBTags.contains($0.regionLock)
        }
        guard !locked.isEmpty else { return nil }

        return locked.contains { $0.regionLock == ReleaseRegionRules.regionB }
            ? hardRegionLockNote
            : "Loosely \(hardRegionLockNote)"
    }

    /// The blocking form of the region note. Named because `regionLockHighlight` colors
    /// exactly this phrase, and a note and a highlight that spelled it separately would
    /// stop agreeing the moment either was reworded.
    private static let hardRegionLockNote = "Region B locked"


    // MARK: Notes — versions

    /// Which cut the user's digital copy is, and which other cuts their purchased discs
    /// would give them.
    ///
    /// # Why this is in Notes
    ///
    /// Nothing else in the table reports either fact. `digitalVersion` has no column, and
    /// the disc columns report a release's format and audio, never what is on it — so a
    /// film the user holds as an extended cut while owning a disc that also carries the
    /// theatrical is, everywhere else in this document, indistinguishable from one that
    /// does not.
    ///
    /// # What is reported, and what is not
    ///
    /// The theatrical cut is the default every film is assumed to be until something says
    /// otherwise, so a theatrical (or unset) `digitalVersion` prints nothing AND suppresses
    /// the disc clause with it — see `ViewingVersion.reportableName(forStoredCode:)`, whose
    /// rule this follows rather than restates. The clause only earns its width when the
    /// copy is unusual to begin with; on a theatrical copy "also includes theatrical in 2K"
    /// would be noise on most of the library.
    ///
    /// Versions already named are not repeated, and the extras are grouped by the formats
    /// that carry them, so a cut on both a Blu-ray and a 4K reads as one clause rather than
    /// as two contradictory ones.
    private static func versionNotes(_ film: FilmSnapshot) -> [PDFNoteList.Item] {
        let version = ViewingVersion.reportableName(forStoredCode: film.digitalVersion)
        guard !version.isEmpty else { return [] }

        // Quoted and named as a version, so the item reads as a claim about the cut rather
        // than as a loose adjective sitting in a list of unrelated facts — "Extended" beside
        // "Steelbook" and "open matte" does not obviously describe the same kind of thing.
        // `preservesCase` because the quote, not a letter, now leads the item: the list
        // convention would lowercase whatever came first, and there is nothing to lowercase.
        var items = [PDFNoteList.Item("\(quoted(version)) version", preservesCase: true)]

        // Formats carrying each version the digital copy is NOT. Combo-pack children
        // included, as everywhere else in this column: a bundled Blu-ray is a real disc,
        // and what is on it is really on the shelf.
        var formatsByVersion: [String: Set<ReleaseFormat>] = [:]
        for release in film.releases where release.purchased {
            guard let format = ReleaseFormat(rawValue: release.format) else { continue }
            for included in release.includedVersions where included != version {
                formatsByVersion[included, default: []].insert(format)
            }
        }
        guard !formatsByVersion.isEmpty else { return items }

        // Grouped the other way round — versions per format set — so two cuts that live on
        // the same discs share one clause. Both the version list and the format list are
        // ordered from a fixed vocabulary rather than from a Set's iteration, or two exports
        // of an unchanged library would phrase the same fact differently.
        var versionsByFormats: [Set<ReleaseFormat>: [String]] = [:]
        for (included, formats) in formatsByVersion {
            versionsByFormats[formats, default: []].append(included)
        }

        var clauses: [(order: Int, text: String)] = []
        for (formats, versions) in versionsByFormats {
            let named = orderedVersions(versions)
            let ordered = versionFormatOrder.filter { formats.contains($0) }
            let labels: [String] = ordered.map { noteFormatName($0) }
            let order: Int = ordered.first?.displayRank ?? ReleaseFormat.unknownRank
            let quotedNames = list(named.map(quoted))
            let noun = named.count == 1 ? "version" : "versions"
            clauses.append((order, "also includes \(quotedNames) \(noun) in \(list(labels))"))
        }
        // Ordered by the first format named, so 2K clauses precede 4K ones.
        clauses.sort { $0.order == $1.order ? $0.text < $1.text : $0.order < $1.order }

        // The clause names proper version titles and format labels, both of which keep
        // their casing wherever the joined list places them.
        items.append(contentsOf: clauses.map { PDFNoteList.Item($0.text, preservesCase: true) })
        return items
    }

    /// A version name in typographic quotes, so a multi-word cut — "The Final Cut" — reads
    /// as one title inside a sentence that also lists formats and other cuts.
    ///
    /// Curly quotes rather than straight ones: this is prose on a printed page, and the
    /// straight pair is a typewriter artifact that reads as code beside the em dashes and
    /// en dashes the rest of the column uses.
    private static func quoted(_ name: String) -> String {
        // One version already arrives quoted — `ViewingVersion.finalCut` is stored as
        // "\"The Final Cut\"" — so its straight pair is stripped rather than nested inside
        // a second one.
        let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return "\u{201C}\(bare)\u{201D}"
    }

    /// The formats a version clause may name, in the order it names them: the 2K tiers
    /// before the 4K one, matching how every other note in this column contrasts the two.
    private static let versionFormatOrder: [ReleaseFormat] = [.bluRay, .dvd, .uhd4K]

    /// A set of stored version names in the app's own menu order, with anything outside
    /// that vocabulary sorted alphabetically after it. Ordering from a fixed list rather
    /// than from the set's own iteration is what keeps two exports of an unchanged library
    /// from phrasing the same clause differently.
    private static func orderedVersions(_ versions: [String]) -> [String] {
        let known = ViewingVersion.selectableNames.filter { versions.contains($0) }
        let unknown = versions.filter { !ViewingVersion.selectableNames.contains($0) }.sorted()
        return known + unknown
    }

    /// "A", "A and B", "A, B and C" — the conjunction the version and format lists both
    /// read in. `PDFNoteList` joins the column's ITEMS with commas, so a list inside one
    /// item needs a form that does not look like the end of it.
    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0:  return ""
        case 1:  return values[0]
        case 2:  return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + " and \(values[values.count - 1])"
        }
    }

    /// One note per format the user has bought TWICE or more, naming the copies:
    /// "Lionsgate/Shout Factory 2K releases", or "2011/2018 2K releases" when the copies
    /// come from one studio and the year is the only thing that tells them apart.
    ///
    /// Suppressed entirely when neither label tells the copies apart — two purchases of one
    /// studio's single release in one year is a duplicate copy, and "2017/2017 2K releases"
    /// describes it no better than saying nothing does.
    ///
    /// Combo-pack children are counted like any other release of their format, matching the
    /// rest of this column: a bundled Blu-ray is a second Blu-ray on the shelf.
    private static func duplicateFormatNotes(_ film: FilmSnapshot,
                                             abbreviated: Bool) -> [DuplicateFormatNote] {
        let purchased = film.releases.filter(\.purchased)

        // Format order fixed rather than dictionary order, so two exports of an unchanged
        // library cannot list the same notes in a different sequence.
        return [ReleaseFormat.uhd4K, ReleaseFormat.bluRay, ReleaseFormat.dvd]
            .compactMap { format -> DuplicateFormatNote? in
                let copies = purchased.filter { $0.format == format.rawValue }
                guard copies.count > 1 else { return nil }

                let studios = copies.map(\.studio)
                // The studio names, unless they would all read the same — in which case
                // the year is the only label that actually distinguishes the copies. An
                // unknown studio anywhere falls back to years for the same reason.
                let useStudios = !studios.contains(where: \.isEmpty) && Set(studios).count > 1
                // Shortened only when the cell is over budget — see `notesCell`. The abbreviated
                // forms come from the same table the RightSidebar's "Source for Viewing"
                // field abbreviates with, so a studio reads the same in both places.
                let displayed = useStudios
                    ? studios.map { abbreviated ? ReleaseStudio.abbreviated($0) : $0 }
                    : []
                let labels = (useStudios ? displayed : copies.map(\.releaseYear))
                    .map { $0.isEmpty ? placeholderDash : $0 }

                // Nothing distinguishes the copies — same studio, same year, or no year at
                // all on any of them. The note would only repeat one label twice.
                guard Set(labels).count > 1 else { return nil }

                return DuplicateFormatNote(
                    text: labels.joined(separator: "/") + " " + noteFormatName(format) + " releases",
                    // Only the studio labels are names; a year is not italicized. Duplicates
                    // are dropped because the highlight colors every occurrence anyway.
                    studios: useStudios ? Array(Set(displayed)).sorted() : [])
            }
    }

    /// A double-dip note and the studio names inside it, which the cell italicizes in place.
    private struct DuplicateFormatNote {
        let text: String
        let studios: [String]
    }

    /// The short name a format goes by in the Notes column. "2K" rather than the disc
    /// columns' "BD": the note sits beside a "4K" it is being contrasted with, and the two
    /// only read as a pair when they are named on the same axis.
    private static func noteFormatName(_ format: ReleaseFormat) -> String {
        switch format {
        case .uhd4K:  return "4K"
        case .bluRay: return "2K"
        case .dvd:    return "DVD"
        }
    }

    /// "German import" for each distinct foreign origin among the purchased discs, in the
    /// order the releases are stored so the list is stable between exports.
    private static func importNotes(_ film: FilmSnapshot) -> [String] {
        var seen = Set<String>()
        return film.releases
            .filter { $0.purchased && isImport($0) }
            .map(\.nationalOrigin)
            .filter { seen.insert($0).inserted }
            .map { ReleaseOrigin.demonym(for: $0) + " import" }
    }

    /// The object-based formats in play on the discs the two purchased columns settled on,
    /// in column order and without repetition — a film whose Blu-ray and 4K both carry
    /// Atmos says "Atmos" once.
    ///
    /// The names are SHORTENED from the stored vocabulary: `ReleaseAudioFormat.dolbyAtmos`
    /// is "Dolby Atmos", and the vendor prefix is dead weight in a note whose whole job is
    /// to say which of the two object-based formats this is. "DTS:X" is already short and
    /// passes through.
    private static func objectBasedFormats(best2K: ReleaseSnapshot?,
                                           best4K: ReleaseSnapshot?) -> [String] {
        var seen = Set<String>()
        return [best2K, best4K].compactMap { $0 }
            .map(\.audioFormat)
            .filter { ReleaseAudioFormat.isObjectBased($0) && seen.insert($0).inserted }
            .map(objectBasedNoteName)
    }

    /// The short name an object-based format goes by in the Notes column.
    private static func objectBasedNoteName(_ stored: String) -> String {
        stored == ReleaseAudioFormat.dolbyAtmos ? "Atmos" : stored
    }

    // MARK: Disc count

    /// Total discs across every purchased release.
    ///
    /// Only TOP-LEVEL releases are summed. A combo pack's `numberOfDiscs` already counts
    /// the discs in the box, and its child releases are those same discs described
    /// individually — adding both would double-count every pack the user owns.
    private static func discCountCell(_ film: FilmSnapshot, fill: NSColor?) -> PDFCell {
        let total = film.releases
            .filter { $0.purchased && $0.isTopLevel }
            .reduce(0) { $0 + $1.numberOfDiscs }
        return PDFCell(total > 0 ? "\(total)" : "", fill: fill)
    }

    // MARK: HandBrake RF

    /// `libraryHBRFValue`, blank when unset — 0 is the field's "never encoded" sentinel,
    /// not an RF of zero.
    ///
    /// An unset RF on a film the user OWNS is the one place this column turns negative: the
    /// disc is on the shelf and nothing has been encoded from it, which is a gap worth
    /// flagging. That red deliberately overrides the ownership tint the rest of the row
    /// carries — the tint says "owned", and the whole point here is that being owned is
    /// what makes the blank field a loose end rather than a non-event. An unset RF on a
    /// film that was never bought is simply nothing to report, and stays blank.
    private static func rfCell(_ film: FilmSnapshot,
                               ownership: NSColor?,
                               hasPurchase: Bool) -> PDFCell {
        guard film.libraryHBRFValue > 0 else {
            // Owned but unencoded is a loose end (red). Unowned and unencoded is a
            // non-event — but an empty cell reads as an oversight, so it gets the dash
            // that says "asked and answered: nothing here".
            return hasPurchase
                ? PDFCell("", fill: PDFPalette.red)
                : PDFCell(placeholderDash)
        }
        return PDFCell("\(film.libraryHBRFValue)", fill: ownership)
    }

    // MARK: Aspect ratio

    /// The stored aspect ratio, banded by shape.
    ///
    /// The four fills are this column's own family (see `PDFPalette`'s aspect-ratio
    /// heading) — they are darker than the shared shades on purpose, so the eye reads this
    /// column as a separate axis from the purchase and quality columns to its left rather
    /// than as more of the same signaling.
    ///
    /// Bands: narrower than 1.60:1, 1.60:1 up to 2.00:1, 2.00:1 and wider, and "Hybrid" —
    /// which names a film whose ratio changes and therefore has no band to fall into.
    /// A value with no parseable ratio takes no fill rather than guessing at one.
    private static func aspectRatioCell(_ film: FilmSnapshot) -> PDFCell {
        let stored = film.aspectRatio
        guard !stored.isEmpty else { return PDFCell("") }

        if stored.localizedCaseInsensitiveContains("Hybrid") {
            return PDFCell(stored, fill: PDFPalette.veryDarkPurple)
        }

        // The bare ratio. The open-matte qualifier moves to Notes (see `notesCell`), which
        // is what allows this column to be sized to six characters instead of nineteen —
        // and stops one film in twenty from wrapping its whole row to three lines.
        let display = strippingOpenMatte(stored)
        guard let ratio = leadingRatio(display) else { return PDFCell(display) }

        if ratio < 1.60 { return PDFCell(display, fill: PDFPalette.veryDarkGold) }
        if ratio < 2.00 { return PDFCell(display, fill: PDFPalette.veryDarkGreen) }
        return PDFCell(display, fill: PDFPalette.veryDarkBlue)
    }

    /// The qualifier `AspectRatioVocabulary` appends to its open-matte tags.
    private static let openMatteQualifier = AspectRatioVocabulary.openMatteQualifier

    /// True for a stored ratio carrying the open-matte qualifier.
    private static func isOpenMatte(_ stored: String) -> Bool {
        stored.localizedCaseInsensitiveContains(openMatteQualifier)
    }

    /// `stored` with the open-matte qualifier and its separating space removed.
    /// Matched case-insensitively, since the qualifier arrives from stored data.
    private static func strippingOpenMatte(_ stored: String) -> String {
        guard let range = stored.range(of: openMatteQualifier,
                                       options: .caseInsensitive) else { return stored }
        return stored.replacingCharacters(in: range, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The numeric width of a "W:H" tag, tolerating a trailing qualifier.
    ///
    /// `AspectRatioVocabulary` carries values like "1.33:1 (Open matte)", so the height
    /// side cannot simply be parsed as a `Double` — the leading numeric run of each side is
    /// taken instead. A tag whose sides do not both start with a number has no ratio.
    private static func leadingRatio(_ stored: String) -> Double? {
        let parts = stored.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = leadingNumber(parts[0]),
              let height = leadingNumber(parts[1]),
              height > 0 else { return nil }
        return width / height
    }

    private static func leadingNumber(_ text: Substring) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let numeric = trimmed.prefix { $0.isNumber || $0 == "." }
        return numeric.isEmpty ? nil : Double(numeric)
    }

    // MARK: Chroma

    /// Blank for a color film, "B&W" for a black-and-white one.
    ///
    /// The blank cell is still FILLED — seafoam — because "this film is in color" is a
    /// positive fact the column reports, and the overwhelmingly common one. Printing the
    /// word for every color film would drown out the handful that are not.
    private static func chromaCell(_ film: FilmSnapshot) -> PDFCell {
        film.color
            ? PDFCell("", fill: PDFPalette.seafoam)
            : PDFCell("B&W", fill: PDFPalette.lightGray)
    }

    // MARK: Custom edit

    /// "yes" for a film the user has cut their own version of, blank otherwise.
    ///
    /// Brown is this column's alone. An edit is neither a quality judgment nor a purchase
    /// state, so borrowing a shade from either family would fold it into a scale it does
    /// not belong on.
    private static func customEditCell(_ film: FilmSnapshot) -> PDFCell {
        film.edited ? PDFCell("yes", fill: PDFPalette.brown) : PDFCell("")
    }

    // MARK: Last watched

    /// `lastWatched` as "Jul 21, 2025", or a dash when never watched or unparseable.
    ///
    /// Parsing goes through `parseDate(from:)` in GlobalUtilities — the app's one date
    /// reader — so a stored value carrying a viewing-version code ("2026.01.24.TH") is
    /// handled here exactly as it is everywhere else.
    private static func lastWatchedCell(_ film: FilmSnapshot) -> PDFCell {
        PDFCell(PDFCellText.abbreviatedDate(film.lastWatched))
    }

    /// The stand-in for a field with nothing in it — see `PDFCellText.placeholder`.
    private static let placeholderDash = PDFCellText.placeholder
}
