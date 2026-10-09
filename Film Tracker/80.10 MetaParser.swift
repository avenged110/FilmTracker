// MARK: - MetaParser.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Extracts metadata from MP4/M4V files and creates new Film objects using this data.

import Foundation
import AVFoundation
import AppKit

@MainActor
final class MetaParser: Loggable {
    nonisolated static let logTag = "[MetaParser]"

    // DEBUG flag - set to 'true' to enable detailed metadata logging.
    private nonisolated static let DEBUG_METADATA = false

    private var pendingFilms: [FilmSnapshot] = []
    private var pendingPosterUIDs: [String] = []
    /// The subset of `pendingPosterUIDs` handed to an existing library film during this
    /// import (MetaImporter's poster propagation). That film is already saved referencing
    /// the file, so a rollback must leave it on disk. See `adoptPoster(_:)`.
    private var adoptedPosterUIDs: Set<String> = []

    // MARK: - Public API
    // Parses a single video file and creates an in-memory Film object.
    func parseFile(_ url: URL) async -> Result<Void, any Error> {
        do {
            Self.log("=== BEGIN FULL PARSING FILE: \(url.lastPathComponent) ===")
            let asset = AVURLAsset(url: url)
            let metadata = try await extractMetadata(from: asset)

            // DEBUG logging of parsed metadata.
            if Self.DEBUG_METADATA {
                await MetaParserDebug.logParsedMetadata(
                    metadata, filename: url.lastPathComponent) }

            // Generate a new UUID for this film.
            let filmID = UUID()
            // Extract the poster (if available).
            var posterUID = ""
            if let artworkData = metadata.artworkData {
                Self.log("Extracting poster artwork...")
                posterUID = try await extractPoster(artworkData)
                pendingPosterUIDs.append(posterUID)
                Self.log("Poster extracted successfully: \(posterUID)")
            } else { Self.log("No artwork data found in file") }
            // Create the FilmSnapshot DTO from the parsed metadata.
            let film = createSnapshot(id: filmID, posterUID: posterUID, metadata: metadata)

            // DEBUG logging of created Film object.
            if Self.DEBUG_METADATA { await MetaParserDebug.logCreatedFilm(film) }

            // Store the object in-memory until commit.
            pendingFilms.append(film)
            Self.log("=== END FULL PARSING FILE: \(url.lastPathComponent) ===\n")
            return .success(())
        } catch {
            Self.log("ERROR: Parsing file \(url.lastPathComponent): \(error.localizedDescription)")
            return .failure(error) } }

    // Returns the array of pending film snapshots for duplicate checking.
    func getPendingFilms() -> [FilmSnapshot] { return pendingFilms }

    // Removes the last pending film (used when a duplicate is detected during update mode).
    func removeLastPendingFilm() {
        if !pendingFilms.isEmpty {
            pendingFilms.removeLast()
            Self.log("Removed last pending film from queue (current count: \(pendingFilms.count))") } }

    // Clears all pending films. Called once the batch has been committed to MemoryStore,
    // which is the point at which the posters extracted for it stop needing protection
    // from the pruner (see PosterReservations). A duplicate's poster that was deleted
    // rather than propagated is released here too; releasing a UID with no file behind
    // it is a no-op.
    func clearPendingFilms() {
        pendingFilms.removeAll()
        PosterReservations.release(pendingPosterUIDs)
        pendingPosterUIDs.removeAll()
        adoptedPosterUIDs.removeAll()
        Self.log("Cleared all pending films") }

    // Records that a pending poster now belongs to an existing library film, so a later
    // rollback keeps its file. Its reservation is released with the rest, exactly as
    // before: the adopting film already references it in MemoryStore.
    func adoptPoster(_ posterUID: String) {
        adoptedPosterUIDs.insert(posterUID) }

    // Rolls back all pending imports and cleans up generated files.
    func rollbackPendingImports() async {
        Self.log("Rolling back \(pendingFilms.count) pending imports")
        // Delete any poster images that were generated during the import.
        guard let folderURL = Preferences.posterImagesFolderURL else { return }
        // Adopted posters are skipped: a canceled import used to delete the artwork it had
        // just given an existing film, leaving that film pointing at a missing file.
        for posterUID in pendingPosterUIDs where !adoptedPosterUIDs.contains(posterUID) {
            let posterURL = folderURL.appendingPathComponent("\(posterUID).jpg")
            try? FileManager.default.removeItem(at: posterURL)
            Self.log("Deleted poster: \(posterUID)") }
        pendingFilms.removeAll()
        PosterReservations.release(pendingPosterUIDs)
        pendingPosterUIDs.removeAll()
        adoptedPosterUIDs.removeAll()
        Self.log("Rollback complete") }

    // MARK: - Full Metadata Extraction
    private func extractMetadata(from asset: AVURLAsset) async throws -> ParsedMetadata {
        return try await Task.detached(priority: .userInitiated) { [asset] in
            var parsed = ParsedMetadata()
            // Captured up front (synchronous, thread-safe) so it's available for logging
            // regardless of the order in which metadata atoms are processed below —
            // parsed.title may not be populated yet when the genre atom is encountered.
            let filmName = asset.url.lastPathComponent
            let formats = try await asset.load(.availableMetadataFormats)

            // DEBUG logging of available metadata formats.
            if Self.DEBUG_METADATA { await MetaParserDebug.logAvailableFormats(formats) }

            // Extract duration from asset.
            let durationCMTime = try await asset.load(.duration)
            parsed.duration = Fmt.fixed(durationCMTime.seconds * 1000, 0)

            // Extract frame rate and aspect ratio from video track.
            // Added aspect ratio extraction
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let firstVideoTrack = tracks.first {
                let frameRate = try await firstVideoTrack.load(.nominalFrameRate)
                parsed.frameRate = Fmt.fixed(Double(frameRate), 2)
                
                // Extract aspect ratio from video track
                let naturalSize = try await firstVideoTrack.load(.naturalSize)
                let preferredTransform = try await firstVideoTrack.load(.preferredTransform)
                
                // Apply transform to get actual display size
                let size = naturalSize.applying(preferredTransform)
                let width = abs(size.width)
                let height = abs(size.height)
                
                if width > 0 && height > 0 {
                    let ratio = width / height
                    // Snap to master aspect ratio if within 0.01
                    parsed.aspectRatio = Self.snapToMasterAspectRatio(ratio)
                    // Store dimensions for digitalSource resolution fallback.
                    parsed.videoWidth  = width
                    parsed.videoHeight = height
                    let aspectRatioValue = parsed.aspectRatio
                    let widthInt = Int(width)
                    let heightInt = Int(height)
                    await MainActor.run {
                        Self.log("Extracted aspect ratio: \(aspectRatioValue) (from \(widthInt)x\(heightInt))")
                    }
                }
            }

            // Only process the "com.apple.itunes" format.
            for format in formats where format.rawValue == "com.apple.itunes" {
                let items = try await asset.loadMetadata(for: format)

                let itemCount = items.count
                await MainActor.run {
                    Self.log("Processing format: \(format.rawValue) (\(itemCount) items)") }

                for item in items {
                    // DEBUG logging of all raw data 'read' from the file.
                    if Self.DEBUG_METADATA { await
                        MetaParserDebug.logMetadataItem(item) }

                    // Get the identifier to determine what field this is.
                    guard let identifier = item.identifier?.rawValue else { continue }

                    // Extract based on identifier (handle both URL-encoded and raw formats).
                    switch identifier {
                    // Title - handle both formats.
                    case "itsk/©nam", "itsk/%C2%A9nam", "itsk/%A9nam":
                        if parsed.title.isEmpty {
                            parsed.title = await MetaParser.extractString(from: item) }
                    // Composer - handle both formats.
                    // Split comma-separated values
                    case "itsk/©wrt", "itsk/%C2%A9wrt", "itsk/%A9wrt":
                        if parsed.composer.isEmpty {
                            let composerString = await MetaParser.extractString(from: item)
                            parsed.composer = Self.parseCommaSeparatedValues(composerString)
                            let composerLogString = parsed.composer.joined(separator: ", ")
                            await MainActor.run {
                                Self.log("Parsed composer: \(composerLogString)")
                            }
                        }
                    // Comments - handle both formats.
                    case "itsk/©cmt", "itsk/%C2%A9cmt", "itsk/%A9cmt":
                        if parsed.comments.isEmpty {
                            parsed.comments = await MetaParser.extractString(from: item) }
                    // Genre (can be number or string) - handle both formats.
                    case "itsk/©gen", "itsk/%A9gen":
                        if parsed.genre.isEmpty {
                            // Genre can be stored as a number reference or data
                            if let dataValue = try? await item.load(.dataValue),
                                dataValue.count == 2 {
                                // Extract the 16-bit integer from data. Copied to an
                                // Array first: `Data` is not guaranteed to be zero-based
                                // (a slice keeps its parent's indices), so subscripting
                                // by 0 and 1 directly would trap on such a value.
                                let bytes = Array(dataValue)
                                let genreCode = Int(bytes[0]) << 8 | Int(bytes[1])
                                    parsed.genre = MetaParser.filmGenreFromCode(genreCode)
                            } else if let numberValue = try? await item.load(.numberValue) {
                                parsed.genre = MetaParser.filmGenreFromCode(
                                    numberValue.intValue)
                            } else {
                                parsed.genre = await MetaParser.extractString(from: item) } }
                    // Numeric (legacy) genre atom – maps 2-byte code to name.
                    case "itsk/gnre":
                        if parsed.genre.isEmpty {
                            if let data = try? await item.load(.dataValue) {
                                if data.count >= 2 {
                                    // Read big-endian UInt16, byte by byte: no pointer, and no
                                    // alignment requirement on the Data's storage.
                                    let i = data.startIndex
                                    let code = UInt16(data[i]) << 8 | UInt16(data[i + 1])
                                    let genreName = Self.genreName(for: Int(code))
                                    let fallbackGenre = genreName ?? "Unknown (\(code))"
                                    if Self.DEBUG_METADATA {
                                        await MetaParserDebug.logLegacyGenreMapping(Int(code),
                                            parsedGenre: fallbackGenre) }
                                    // The legacy 2-byte genre atom uses a different vocabulary than
                                    // the app's canonical genre whitelist. Remap any legacy name that
                                    // has no canonical bucket so it isn't silently dropped later by
                                    // Details-tab normalization (see canonicalGenre(forLegacy:)).
                                    if let canonicalGenre = Self.canonicalGenre(forLegacy: fallbackGenre) {
                                        await MetaParserDebug.logFallbackGenreMapped(
                                            filmName: filmName,
                                            fallbackGenre: fallbackGenre,
                                            canonicalGenre: canonicalGenre)
                                        parsed.genre = canonicalGenre
                                    } else {
                                        parsed.genre = fallbackGenre
                                    } } } }
                    // Release Date - handle both formats.
                    case "itsk/©day", "itsk/%C2%A9day", "itsk/%A9day":
                        if parsed.releaseDate.isEmpty {
                            parsed.releaseDate = await MetaParser.extractString(from: item) }
                    // Sort Name.
                    case "itsk/sonm":
                        if parsed.sortName.isEmpty {
                            parsed.sortName = await MetaParser.extractString(from: item) }
                    // Description (short).
                    case "itsk/desc":
                        if parsed.descriptionText.isEmpty {
                            parsed.descriptionText = await MetaParser.extractString(from: item) }
                    // Encoding Tool - handle both formats.
                    // Split comma-separated values
                    case "itsk/©too", "itsk/%C2%A9too", "itsk/%A9too":
                        if parsed.encodingTool.isEmpty {
                            let toolString = await MetaParser.extractString(from: item)
                            parsed.encodingTool = Self.parseCommaSeparatedValues(toolString)
                            let toolLogString = parsed.encodingTool.joined(separator: ", ")
                            await MainActor.run {
                                Self.log("Parsed encodingTool: \(toolLogString)")
                            }
                        }
                    // Executive Producer - handle both formats.
                    // Split comma-separated values
                    case "itsk/©xpd", "itsk/%C2%A9xpd", "itsk/%A9xpd":
                        if parsed.executiveProducers.isEmpty {
                            let xpdString = await MetaParser.extractString(from: item)
                            parsed.executiveProducers = Self.parseCommaSeparatedValues(xpdString)
                            let xpdLogString = parsed.executiveProducers.joined(separator: ", ")
                            await MainActor.run {
                                Self.log("Parsed executiveProducers: \(xpdLogString)")
                            }
                        }
                    // HD Video - stored as string number, needs mapping.
                    case "itsk/hdvd":
                        if parsed.hdVideo.isEmpty {
                            let value = await MetaParser.extractString(from: item)
                            parsed.hdVideo = MetaParser.hdVideoFromCode(value) }
                    // Artwork.
                    case "itsk/covr":
                        if parsed.artworkData == nil {
                            parsed.artworkData = await MetaParser.extractData(from: item) }
                    // Rating.
                    case "itlk/com.apple.iTunes.iTunEXTC":
                        if parsed.rating.isEmpty {
                            let rawRating = await MetaParser.extractString(from: item)
                            parsed.rating = MetaParser.formatRating(rawRating) }
                    // iTunes Movie Info (XML plist with cast, directors, producers, etc.).
                    case "itlk/com.apple.iTunes.iTunMOVI":
                        let xmlString = await MetaParser.extractString(from: item)
                        if !xmlString.isEmpty {
                            await MetaParser.parseITunMOVI(xmlString, into: &parsed) }
                    // Duration (in milliseconds).
                    case "itsk/----:com.apple.iTunes:duration":
                        if parsed.duration.isEmpty {
                            parsed.duration = await MetaParser.extractString(from: item) }
                    default: break } } }
            
            // If hdVideo is still empty after all parsing, map to "SD"
            if parsed.hdVideo.isEmpty {
                parsed.hdVideo = "SD"
                await MainActor.run {
                    Self.log("No hdVideo metadata found - defaulting to 'SD'")
                }
            }

            // Resolve digitalSource and subtitles.
            // Step 1 — comments-based disc detection (Blu-ray disc / DVD).
            // Step 2 — if no disc match, use hdVideo to infer a download tier.
            // Step 3 — if hdVideo maps to SD or is absent, measure actual dimensions.
            // The video dimensions were captured above alongside the aspect ratio so
            // no second AVAsset load is required here.
            let (commentsSource, subtitles) = Self.parseCommentsForSourceAndSubtitles(parsed.comments)
            parsed.subtitles = subtitles

            if !commentsSource.isEmpty {
                // Step 1 matched.
                parsed.digitalSource = commentsSource
                await MainActor.run {
                    Self.log("digitalSource from comments: '\(commentsSource)'")
                }
            } else if let downloadSource = Self.downloadSourceFromHDVideo(parsed.hdVideo) {
                // Step 2 matched — hdVideo indicated a known HD/4K tier.
                parsed.digitalSource = downloadSource
                await MainActor.run {
                    Self.log("digitalSource from hdVideo '\(parsed.hdVideo)': '\(downloadSource)'")
                }
            } else {
                // Step 3 — measure actual video dimensions (already captured above).
                let measuredSource = Self.downloadSourceFromDimensions(
                    width: parsed.videoWidth, height: parsed.videoHeight)
                parsed.digitalSource = measuredSource
                await MainActor.run {
                    let w = Int(parsed.videoWidth)
                    let h = Int(parsed.videoHeight)
                    Self.log("digitalSource from dimensions \(w)x\(h): '\(measuredSource)'")
                }
            }

            return parsed
        }.value }

    // MARK: - iTunes Movie XML Parser
    private nonisolated static func parseITunMOVI(_ xmlString: String,
        into metadata: inout ParsedMetadata) async {
        guard let data = xmlString.data(using: .utf8) else { return }
        do {
            let plist = unsafe try PropertyListSerialization.propertyList(from: data,
                options: [], format: nil) as? [String: Any]
            // Extract cast.
            if let castArray = plist?["cast"] as? [[String: Any]] {
                metadata.cast = castArray.compactMap { $0["name"] as? String } }
            // Extract directors.
            if let directorsArray = plist?["directors"] as? [[String: Any]] {
                metadata.directors = directorsArray.compactMap { $0["name"] as? String } }
            // Extract producers.
            if let producersArray = plist?["producers"] as? [[String: Any]] {
                metadata.producers = producersArray.compactMap { $0["name"] as? String } }
            // Extract screenwriters.
            if let screenwritersArray = plist?["screenwriters"] as? [[String: Any]] {
                metadata.screenwriters = screenwritersArray.compactMap {
                    $0["name"] as? String } }
            // Extract studio - parse comma-separated values into array.
            if let studioString = plist?["studio"] as? String {
                metadata.studio = parseCommaSeparatedValues(studioString) }
            // DEBUG logging for iTunMOVI metadata arrays.
            if DEBUG_METADATA { await MetaParserDebug.logParsedITunMOVI(metadata) }
        } catch { if DEBUG_METADATA { await MetaParserDebug.logITunMOVIError(error) } } }

    // MARK: - Studio Parsing Helper
    // Parses a comma-separated string into an array of trimmed values.
    private nonisolated static func parseCommaSeparatedValues(_ input: String) -> [String] {
        return input
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    // MARK: - Comments Parsing Helper
    // Extracts disc-based digitalSource and subtitles flag from the iTunes comments field.
    // Returns an empty digitalSource string when no disc-type language is recognized;
    // the caller then proceeds to the hdVideo / dimension fallback steps.
    private nonisolated static func parseCommentsForSourceAndSubtitles(_ comments: String) -> (digitalSource: String, subtitles: String) {
        var digitalSource = ""
        var subtitles = ""

        let lowercased = comments.lowercased()

        // Check for digital source phrases
        if lowercased.contains("purchased bd") ||
           lowercased.contains("purchased 4k+bd") ||
           lowercased.contains("bd rip") {
            digitalSource = FilmDigitalSource.blurayDisc
        } else if lowercased.contains("purchased dvd") ||
                  lowercased.contains("dvd rip") {
            digitalSource = FilmDigitalSource.dvd
        }

        // Check for subtitles phrase
        if lowercased.contains("includes subtitles") {
            subtitles = FilmSubtitles.yes
        }

        return (digitalSource, subtitles)
    }

    // MARK: - HD Video → Download Source Helper
    // Maps the iTunes hdVideo field value to the corresponding download tier string.
    // Returns nil for SD (or any unrecognized value) so the caller falls through to
    // dimension-based measurement.
    private nonisolated static func downloadSourceFromHDVideo(_ hdVideo: String) -> String? {
        switch hdVideo {
        case "720p HD":  return FilmDigitalSource.download720p
        case "1080p HD": return FilmDigitalSource.download1080p
        case "4K":       return FilmDigitalSource.download4K
        default:         return nil   // "SD" and any unrecognized value → fall through
        }
    }

    // MARK: - Dimension-Based Download Source Helper
    // Classifies a video's actual pixel height into a download tier, with fuzzy
    // tolerances to account for natural encoding variation within each class.
    // Each class boundary sits at the midpoint between adjacent canonical heights:
    //
    //   Class    Canonical height   Lower bound   Upper bound
    //   360p     360                 1             419
    //   480p     480                420             509   (midpoint 360↔480 = 420, midpoint 480↔540 = 510)
    //   540p     540                510             629   (midpoint 480↔540 = 510, midpoint 540↔720 = 630)
    //   720p     720                630             899   (midpoint 540↔720 = 630, midpoint 720↔1080 = 900)
    //   1080p    1080               900            1439   (midpoint 720↔1080 = 900, midpoint 1080↔2160 = 1440)
    //   4K       2160              1440             ∞
    //
    private nonisolated static func downloadSourceFromDimensions(width: CGFloat, height: CGFloat) -> String {
        // Use the smaller axis as the height reference to handle both landscape
        // and portrait encodings correctly (transform-applied dimensions may swap axes).
        let h = min(width, height)

        switch h {
        case ..<1:       return ""            // no usable dimensions
        case 1..<420:    return FilmDigitalSource.download360p
        case 420..<510:  return FilmDigitalSource.download480p
        case 510..<630:  return FilmDigitalSource.download540p
        case 630..<900:  return FilmDigitalSource.download720p
        case 900..<1440: return FilmDigitalSource.download1080p
        default:         return FilmDigitalSource.download4K
        }
    }
    
    // MARK: - Aspect Ratio Helper
    // Snaps calculated aspect ratio to master list if within 0.01
    private nonisolated static func snapToMasterAspectRatio(_ calculatedRatio: Double) -> String {
        let masterRatios: [Double] = [1.33, 1.37, 1.60, 1.67, 1.78, 1.85, 2.00, 2.21, 2.25, 2.29, 2.35, 2.39, 2.55, 2.76, 2.89]
        
        // Check if within 0.01 of any master ratio
        for masterRatio in masterRatios {
            if abs(calculatedRatio - masterRatio) <= 0.01 {
                return "\(Fmt.fixed(masterRatio, 2)):1"
            }
        }
        
        // Not close to any master ratio, return the calculated value
        return "\(Fmt.fixed(calculatedRatio, 2)):1"
    }

    // MARK: - Code Mapping Functions
    private nonisolated static func genreName(for code: Int) -> String? {
        // Only include non-music/movie genres relevant to use-case.
        switch code {
        case 58: return "Comedy"
        case 27: return "Adventure"
        case 28: return "Animation"
        case 29: return "Action"
        case 30: return "Documentary"
        case 31: return "Drama"
        case 32: return "Horror"
        case 33: return "Science Fiction"
        case 34: return "Thriller"
        case 35: return "Crime"
        case 36: return "Western"
        case 37: return "Romance"
        case 38: return "Mystery"
        case 39: return "Fantasy"
        case 40: return "War"
        case 41: return "History"
        case 42: return "Biography"
        default: return nil } }

    // Maps legacy fallback genre names (produced by genreName(for:) above, when the modern
    // iTunes genre atom is absent) that have no clean 1:1 match in the app's canonical genre
    // whitelist (FSTabDetails.genreOptions) onto the closest whitelisted genre. Returns nil
    // for legacy names that either already are canonical (e.g. "Comedy", "Drama", "Horror",
    // "Thriller") or aren't covered by this table, in which case the fallback name is used
    // as-is.
    private nonisolated static let legacyGenreCanonicalMap: [String: String] = [
        "Science Fiction": "Sci-Fi and Fantasy",
        "Adventure": "Action and Adventure",
        "Action": "Action and Adventure",
        "Fantasy": "Sci-Fi and Fantasy",
        "Mystery": "Thriller",
        "Animation": "Kids and Family",
        "Crime": "Drama",
        "Western": "Drama",
        "Romance": "Drama",
        "War": "Drama",
        "History": "Drama",
        "Biography": "Drama",
        "Documentary": "Drama"
    ]

    private nonisolated static func canonicalGenre(forLegacy fallbackGenre: String) -> String? {
        return legacyGenreCanonicalMap[fallbackGenre] }

    // Film Genre Code Mapping (iTunes/MPAA genres for movies).
    private nonisolated static func filmGenreFromCode(_ code: Int) -> String {
        let genreMap: [Int: String] = [
            4000: "Action and Adventure",
            4001: "Comedy",
            4002: "Documentary",
            4003: "Drama",
            4004: "Kids and Family",
            4005: "Horror",
            4006: "Romance",
            4007: "Sci-Fi and Fantasy",
            4008: "Thriller",
            4009: "Western",
            4010: "Animation",
            4011: "Classics",
            4012: "Concert Films",
            4013: "Foreign",
            4014: "Independent",
            4015: "Music Documentaries",
            4016: "Music Feature Films",
            4017: "Musicals",
            4018: "Short Films",
            4019: "Special Interest",
            4020: "Sports" ]
        return genreMap[code] ?? String(code) }

    // 'HD Video' code mapping.
    private nonisolated static func hdVideoFromCode(_ code: String) -> String {
        // Default to "SD" if the code is empty or unrecognized.
        if code.isEmpty { return "SD" }
        switch code {
        case "0": return "SD"
        case "1": return "720p HD"
        case "2": return "1080p HD"
        case "3": return "4K"
        default: return "SD" } }

    // Format 'Rating' String (extract MPAA rating from iTunes format).
    private nonisolated static func formatRating(_ rawRating: String) -> String {
        // Format is typically "mpaa|RATING|code|".
        let components = rawRating.components(separatedBy: "|")
        // Return just "R", "PG-13", etc.
        if components.count >= 2 && components[0] == "mpaa" { return components[1] }
        return rawRating }

    // MARK: - Value Extractors
    private nonisolated static func extractString(from item: AVMetadataItem) async -> String {
        do { if let value = try await item.load(.stringValue) { return value }
        } catch { if DEBUG_METADATA { await MetaParserDebug.extractString(error) } }
        return "" }

    private nonisolated static func extractData(from item: AVMetadataItem) async -> Data? {
        do { return try await item.load(.dataValue)
        } catch { return nil } } // Silently handle extraction errors.

    // MARK: - Poster Extraction
    private func extractPoster(_ data: Data) async throws -> String {
        guard let image = NSImage(data: data) else { throw ParserError.invalidArtwork }
        return try await withCheckedThrowingContinuation { continuation in
            PosterConverter.normalizePosterImage(from: image) { result in
                switch result {
                case .success(let posterUID): continuation.resume(returning: posterUID)
                case .failure(let error): continuation.resume(throwing: error) } } } }

    // MARK: - Snapshot Creation
    /// Builds a Sendable FilmSnapshot DTO from parsed metadata. No SwiftData context required.
    private func createSnapshot(id: UUID, posterUID: String, metadata: ParsedMetadata) -> FilmSnapshot {
        // Normalize the raw tag value into the app's canonical
        // "yyyy-MM-dd'T'12:00:00'Z'" releaseDate storage format up front, so both
        // the year extraction below and the snapshot's own releaseDate field are
        // built from the same well-formed string. See normalizeReleaseDate's doc
        // comment for the tolerated input formats and fallback behavior.
        let normalizedReleaseDate = Self.normalizeReleaseDate(metadata.releaseDate, filmTitle: metadata.title)
        // Extract year from release date.
        let releaseYear = extractYear(from: normalizedReleaseDate)
        // Get the current date and time as a string (ISO8601 format with fractional seconds).
        let dateAdded = StorageDateFormatters.timestamp.format(Date())
        // Strip year in parentheses from title for the name field.
        let cleanedName = stripYearFromTitle(metadata.title)
        // Determine final sortName based on preference.
        let finalSortName: String
        let overrideSortName = Preferences.overrideSortNameField
        if !metadata.sortName.isEmpty && !overrideSortName {
            // Preference is OFF: Use parsed sortName if available.
            finalSortName = metadata.sortName
            Self.log("sortName PRESERVED: Using parsed value '\(finalSortName)'")
        } else {
            // Preference is ON or no parsed sortName: Calculate custom sortName.
            let strippedName = stripArticles(cleanedName)
            if !releaseYear.isEmpty { finalSortName = "\(strippedName) (\(releaseYear))"
            } else { finalSortName = strippedName }
            if !metadata.sortName.isEmpty && overrideSortName {
                Self.log("sortName OVERRIDE: Discarding parsed '\(metadata.sortName)' → Using calculated '\(finalSortName)' (Preference: overrideSortNameField = true)")
            } else if metadata.sortName.isEmpty {
                Self.log("sortName CALCULATED: No parsed value found → Generated '\(finalSortName)'") } }
        // Check if comments contain "B&W" to set color boolean.
        let isColor = !metadata.comments.contains("B&W")
        // Check if comments contain "edited" to set edited boolean.
        let isEdited = metadata.comments.lowercased().contains("edited")
        // Extract and convert quality value from comments (format: "quality ##").
        let qualityValueString = extractQualityValue(from: metadata.comments)
        let qualityValue = convertQualityValue(qualityValueString)
        let frameRateValue = convertFrameRate(metadata.frameRate)

        return FilmSnapshot(
            id: id,
            posterUID: posterUID,
            name: cleanedName,
            releaseYear: releaseYear,
            userRating: 0,
            lastWatched: "",
            rotationThresholdOverride: nil,
            duration: metadata.duration,
            viewCount: 0,
            calendarTable: [],
            autoAddToQueueOnRotation: nil,
            digitalSource: metadata.digitalSource,
            digitalVersion: "",
            subtitles: metadata.subtitles,
            notes: "",
            numberOfDiscs: "",
            aspectRatio: metadata.aspectRatio,
            color: isColor,
            edited: isEdited,
            editedDuration: "",
            frameRate: frameRateValue,
            tags: [],
            externalIdentifiers: [],
            dateAdded: dateAdded,
            // Intentionally empty — NOT an oversight, and not a value to "fix" by writing
            // Date() here. "" is the sentinel for "never modified since import"; see the
            // lastModified declaration in 61_00_FilmObj.swift for the display semantics that
            // depend on it and for why the snapshot cache's validity check depends on it too.
            lastModified: "",
            // Imported films are NOT presumed watched. A file arriving through the
            // metadata import is overwhelmingly likely to be new to the user, and the
            // rest of this snapshot already says so — `lastWatched` is empty, `viewCount`
            // is 0, and `calendarTable` is empty. Writing `true` here contradicted all
            // three, put every import into the watched-only smart lists (filteredLibrary,
            // and rotation once a lastWatched date was eventually entered), and kept them
            // out of the Unwatched view where a newly added film belongs. The user marks
            // a film watched from the sheet or the Watch Details panel, which is the only
            // path that sets `watched` alongside a real viewing date.
            watched: false,
            specialSorting: [],
            alternateTitle: [],
            hofPosition: 0,
            infoComplete: false,
            comments: metadata.comments,
            genre: metadata.genre,
            releaseDate: normalizedReleaseDate,
            descriptionText: metadata.descriptionText,
            rating: metadata.rating,
            studio: metadata.studio,
            cast: metadata.cast,
            directors: metadata.directors,
            producers: metadata.producers,
            executiveProducers: metadata.executiveProducers,
            screenwriters: metadata.screenwriters,
            encodingTool: metadata.encodingTool,
            libraryHBRFValue: qualityValue,
            composer: metadata.composer,
            sortName: finalSortName,
            releaseUsed: "",
            tools: [],
            editedHBRFValue: 0,
            editDate: "",
            warning: [],
            descriptionNotes: "",
            notesOnAudioTiming: [],
            specialAudioNotes: [],
            notesArray: [],
            handbrakeFrames: [],
            correspondingTimecodes: []) }

    // MARK: - Type Conversion Helpers
    private func convertFrameRate(_ frameRateString: String) -> Double {
        // Attempt to parse the string as a Double (e.g., "23.98" -> 23.98).
        if let value = Double(frameRateString) { return value }
        // Attempt to extract numeric portion if the string contains non-numeric characters.
        let numericString = frameRateString.trimmingCharacters(
            in: CharacterSet(charactersIn: "0123456789.").inverted)
        return Double(numericString) ?? 0.0 }

    private func convertQualityValue(_ qualityString: String) -> Int {
        // Attempt to parse the string as an Int (e.g., "85" -> 85).
        if let value = Int(qualityString) { return value }
        // Attempt to extract digits if embedded in text.
        let digits = qualityString.filter(\.isNumber)
        return Int(digits) ?? 0 }

    /// Normalizes a raw release-date metadata tag value into the app's canonical
    /// "yyyy-MM-dd'T'12:00:00'Z'" storage format (the same format FSTabMetadata's
    /// Release Date picker writes and parseDate(from:) expects to read back).
    ///
    /// Tag writers vary widely in how they encode this field — some already emit
    /// a full ISO8601 timestamp (with any time-of-day and any zone suffix), some
    /// emit a bare "YYYY-MM-DD", and older or manually-tagged files sometimes use
    /// locale-style text such as "March 4, 2011", "03/04/2011", or "03.04.11".
    /// This function tolerates all of the above and always produces the fixed
    /// noon-UTC-anchored format on success.
    ///
    /// The leading "YYYY-MM-DD"/"YYYY.MM.DD" case is matched by extracting the
    /// digits directly via regex rather than parsing through Date/Calendar — this
    /// is deliberate: a Date carries an absolute instant, and re-deriving calendar
    /// components from it requires choosing a time zone, which would make the
    /// result depend on the importing machine's local time zone (or the source
    /// timestamp's own zone) for no benefit, since the calendar date the string
    /// names is already unambiguous as plain digits.
    ///
    /// The locale-style fallback formats carry no time zone information at all,
    /// so they are parsed with a fixed UTC reference frame purely for consistency
    /// (the same input always normalizes to the same output, regardless of which
    /// machine performs the import).
    ///
    /// A value that cannot be confidently parsed by any of the above is DISCARDED
    /// (returns "") rather than preserved as-is — an unrecognized raw string would
    /// otherwise flow untouched into the releaseDate field, silently defeating the
    /// format guarantee this function exists to provide (and, downstream, would
    /// surface as an unparseable value wherever releaseDate is later consumed,
    /// e.g. ViewingDatesTable/CalendarPopover's minDate clamp). The drop is logged
    /// with the film's title and the discarded raw value so it can be identified
    /// and corrected manually in FSTabMetadata's Release Date field.
    private nonisolated static func normalizeReleaseDate(_ rawValue: String, filmTitle: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Fast path: a leading "YYYY-MM-DD" or "YYYY.MM.DD" — already the app's
        // own convention and the convention most third-party taggers use.
        if let (year, month, day) = isoDatePrefixComponents(from: trimmed) {
            return "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(day, 2))T12:00:00Z"
        }

        // Fallback: locale-style formats some taggers use instead of ISO8601.
        // Parsed and re-extracted using a fixed UTC calendar so the result is
        // reproducible across machines regardless of local time zone.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        for format in additionalReleaseDateFormats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            guard let date = formatter.date(from: trimmed) else { continue }
            let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
            if let year = comps.year, let month = comps.month, let day = comps.day {
                return "\(Fmt.padded(year, 4))-\(Fmt.padded(month, 2))-\(Fmt.padded(day, 2))T12:00:00Z"
            }
        }

        // Nothing recognizable by any parser above — discard rather than pass
        // through an unformatted value that would poison every downstream
        // consumer of releaseDate. Logged with enough context (film title, the
        // exact discarded value) to locate and manually correct the field.
        let displayTitle = filmTitle.isEmpty ? "(untitled)" : filmTitle
        Self.log("releaseDate DISCARDED for '\(displayTitle)': raw value '\(rawValue)' could not be parsed by any supported date format. Field left empty — enter the release date manually in the Metadata tab.")
        return ""
    }

    /// Additional DateFormatter patterns tried after the ISO-prefix fast path
    /// fails. Ordered from most to least common; the two-digit-year "MM.dd.yy"
    /// format is tried last since it is the most format-ambiguous.
    private nonisolated static let additionalReleaseDateFormats: [String] = [
        "MMMM d, yyyy",   // "March 4, 2011"
        "MMMM d yyyy",    // "March 4 2011" (no comma)
        "MMM d, yyyy",    // "Mar 4, 2011"
        "MMM d yyyy",     // "Mar 4 2011"
        "MM/dd/yyyy",     // "03/04/2011"
        "M/d/yyyy",       // "3/4/2011"
        "MM.dd.yyyy",     // "03.04.2011"
        "MM.dd.yy",       // "03.04.11"
    ]

    /// Extracts a leading "YYYY-MM-DD" or "YYYY.MM.DD" date directly from the
    /// string's text (not via Date/Calendar), validating that the digits form an
    /// actual calendar date (rejecting e.g. "2011-02-30"). Returns nil if no such
    /// prefix is present or the digits don't form a valid date.
    private nonisolated static func isoDatePrefixComponents(
        from string: String
    ) -> (year: Int, month: Int, day: Int)? {
        let pattern = #"^(\d{4})[-.](\d{2})[-.](\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges == 4,
              let yearRange = Range(match.range(at: 1), in: string),
              let monthRange = Range(match.range(at: 2), in: string),
              let dayRange = Range(match.range(at: 3), in: string),
              let year = Int(string[yearRange]),
              let month = Int(string[monthRange]),
              let day = Int(string[dayRange])
        else { return nil }

        // Validate as an actual calendar date using a fixed UTC calendar (avoids
        // any host-time-zone dependency in the validity check itself).
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let date = utcCalendar.date(from: comps) else { return nil }
        let reExtracted = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard reExtracted.year == year, reExtracted.month == month, reExtracted.day == day else {
            return nil // e.g. Feb 30 silently rolled over to Mar 2 — reject it.
        }
        return (year, month, day)
    }

    private func extractYear(from dateString: String) -> String {
        // Try to extract a 4-digit year.
        let pattern = "\\b(19|20)\\d{2}\\b"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: dateString,
                range: NSRange(dateString.startIndex..., in: dateString)) {
            if let range = Range(match.range, in: dateString) {
                return String(dateString[range]) } }
        return "" }

    private func stripYearFromTitle(_ title: String) -> String {
        // Remove year in parentheses (e.g. "Movie Title (2023)" -> "Movie Title").
        let pattern = "\\s*\\(\\d{4}\\)\\s*$"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(title.startIndex..., in: title)
            let result = regex.stringByReplacingMatches(in: title, range: range,
                withTemplate: "")
            return result.trimmingCharacters(in: .whitespaces) }
        return title }

    private func stripArticles(_ title: String) -> String {
        // Strips leading articles (a, an, the) from a title.
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("the ") { return String(trimmed.dropFirst(4))
        } else if lowercased.hasPrefix("an ") { return String(trimmed.dropFirst(3))
        } else if lowercased.hasPrefix("a ") { return String(trimmed.dropFirst(2)) }
        return trimmed }

    private func extractQualityValue(from comments: String) -> String {
        // Extract two-digit number from "quality ##" pattern (case-insensitive).
        let pattern = "quality\\s+(\\d{2})"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: comments,
                range: NSRange(comments.startIndex..., in: comments)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: comments) {
            return String(comments[range]) }
        return "" }

    // MARK: - Error Types
    enum ParserError: LocalizedError {
        case invalidArtwork

        var errorDescription: String? {
            switch self {
            case .invalidArtwork: return "Could not process artwork image" } } }
}

// MARK: - Parsed Metadata Structure
struct ParsedMetadata: Sendable {
    var title: String = ""
    var hdVideo: String = ""
    var comments: String = ""
    var genre: String = ""
    var releaseDate: String = ""
    var descriptionText: String = ""
    var rating: String = ""
    var studio: [String] = []
    var cast: [String] = []
    var directors: [String] = []
    var producers: [String] = []
    var executiveProducers: [String] = []
    var screenwriters: [String] = []
    var encodingTool: [String] = []
    var composer: [String] = []
    var sortName: String = ""
    var duration: String = ""
    var frameRate: String = ""
    var aspectRatio: String = ""
    var digitalSource: String = ""
    var subtitles: String = ""
    var artworkData: Data?
    // Pixel dimensions measured from the video track; used as a fallback for
    // digitalSource resolution when hdVideo maps to SD or is absent.
    var videoWidth: CGFloat = 0
    var videoHeight: CGFloat = 0
}
