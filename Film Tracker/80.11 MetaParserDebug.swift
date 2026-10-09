// MARK: - MetaParserDebug.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Debug utilities for MetaParser.swift.

import AVFoundation

@MainActor
enum MetaParserDebug {
    static func logAvailableFormats(_ formats: [AVMetadataFormat]) async {
        MetaParser.log("Available metadata formats: \(formats.map { $0.rawValue }.joined(separator: ", "))") }

    nonisolated static func logMetadataItem(_ item: AVMetadataItem) async {
        // Extract info before crossing any isolation boundary
        var parts: [String] = []
        if let id = item.identifier?.rawValue { parts.append("identifier:\(id)") }
        if let common = item.commonKey?.rawValue { parts.append("commonKey:\(common)") }
        if let ks = item.keySpace?.rawValue { parts.append("keySpace:\(ks)") }
        let message = "  Item: \(parts.joined(separator: " "))"
        await MainActor.run { MetaParser.log(message) }
    }

    static func logParsedMetadata(_ metadata: Any, filename: String) async {
        MetaParser.log("Parsed metadata for \(filename): \(metadata)") }

    static func logCreatedFilm(_ snapshot: FilmSnapshot) async {
        MetaParser.log("Created FilmSnapshot DTO: id=\(snapshot.id) name='\(snapshot.name)' year='\(snapshot.releaseYear)'") }

    static func logParsedITunMOVI(_ metadata: ParsedMetadata) async {
        let castCount = metadata.cast.count
        let directorsCount = metadata.directors.count
        let producersCount = metadata.producers.count
        let screenwritersCount = metadata.screenwriters.count
        let studioInfo = metadata.studio.isEmpty ? "none" : "\(metadata.studio.count) studio(s)"
        MetaParser.log("Parsed iTunMOVI XML: cast=\(castCount), directors=\(directorsCount), producers=\(producersCount), screenwriters=\(screenwritersCount), studio=\(studioInfo)") }

    static func logITunMOVIError(_ error: any Error) async {
        MetaParser.log("ERROR parsing iTunMOVI XML: \(error.localizedDescription)") }

    static func extractString(_ error: any Error) async {
        MetaParser.log("ERROR extracting string from item: \(error.localizedDescription)") }

    static func logLegacyGenreMapping(_ code: Int, parsedGenre: String) async {
        MetaParser.log("Parsed numeric genre \(code) → \"\(parsedGenre)\"") }

    // Always logged (not gated behind DEBUG_METADATA) so the user is clearly informed
    // whenever a legacy fallback genre with no canonical bucket is remapped onto the
    // app's whitelisted genre vocabulary during import.
    static func logFallbackGenreMapped(filmName: String, fallbackGenre: String, canonicalGenre: String) async {
        MetaParser.log("'\(filmName)' was parsed with fallback genre \"\(fallbackGenre)\" during import; mapping to canonical genre \"\(canonicalGenre)\"") }
}
