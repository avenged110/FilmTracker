// MARK: - PosterUtilities.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reusable utilities for normalizing poster images and pruning orphaned posters.

import CoreData
import Foundation
import os
import AppKit
import UniformTypeIdentifiers

// MARK: - PosterConverter
// Utility responsible for normalizing poster images before saving.
// Converts arbitrary input images to JPEG with fixed dimensions and saves them in the
// folder referenced by Preferences.posterImagesFolderURL.
@MainActor
enum PosterConverter {
    // Error types for poster conversion.
    enum PosterError: LocalizedError, Sendable {
        case failedToLoadSource
        case failedToResize
        case failedToWrite
        case missingPosterFolder

        var errorDescription: String? {
            switch self {
            case .failedToLoadSource: return "Unable to load the source image."
            case .failedToResize: return "Failed to resize the image."
            case .failedToWrite: return "Failed to write the converted image."
            case .missingPosterFolder: return "The PosterImages folder could not be located." } } }

    // MARK: - Public Interface
    // Normalizes an image and saves it as a JPEG to the poster folder, returning the
    // generated posterUID through `completion`.
    //
    // PURE FILE-SYSTEM OPERATION — no database work. The caller's FilmChangeset (or, for
    // an import, the committed film) is the single writer of the posterUID; conversion's
    // job ends at the file on disk.
    // - Parameters:
    //   - sourceURL: The URL of the image to convert, loaded off the main actor.
    //   - completion: Called on completion with success/failure carrying the new posterUID.
    static func normalizePosterImage(from sourceURL: URL,
        completion: @Sendable @escaping (Result<String, PosterError>) -> Void) {
        guard let settings = OutputSettings.current else {
            completion(.failure(.missingPosterFolder)); return }
        Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: sourceURL) else {
                completion(.failure(.failedToLoadSource)); return }
            completion(writeNormalizedPoster(image, settings))
        }
    }

    // Overload for an already-decoded image (embedded artwork during a metadata import).
    static func normalizePosterImage(from image: sending NSImage,
        completion: @Sendable @escaping (Result<String, PosterError>) -> Void) {
        guard let settings = OutputSettings.current else {
            completion(.failure(.missingPosterFolder)); return }
        Task.detached(priority: .utility) {
            completion(writeNormalizedPoster(image, settings))
        }
    }

    /// The @MainActor-isolated Preferences values a conversion needs, captured before
    /// leaving the main actor. Stable for the duration of any single conversion.
    private struct OutputSettings: Sendable {
        let folder: URL
        let size: NSSize
        let quality: CGFloat

        static var current: OutputSettings? {
            guard let folderURL = Preferences.posterImagesFolderURL else { return nil }
            return OutputSettings(folder: folderURL.standardizedFileURL,
                                  size: NSSize(width: Preferences.normalizedPosterWidth,
                                               height: Preferences.normalizedPosterHeight),
                                  quality: Preferences.normalizedPosterQuality)
        }
    }

    /// The conversion both overloads share: resize, encode, reserve a UID, write.
    /// Nonisolated — it runs inside their detached tasks.
    private nonisolated static func writeNormalizedPoster(
        _ image: NSImage, _ settings: OutputSettings
    ) -> Result<String, PosterError> {
        do {
            // Ensure the PosterImages folder exists.
            try FileManager.default.createDirectory(at: settings.folder,
                withIntermediateDirectories: true)
        } catch { return .failure(.failedToWrite) }

        // Resize and convert to JPEG. Both helpers force the sRGB color space explicitly,
        // regardless of the source image's embedded profile (or lack thereof) — see the
        // doc comment on `resize(image:to:)` for why this matters for CALayer compositing.
        guard let resizedCGImage = resize(image: image, to: settings.size),
              let jpegData = jpegData(from: resizedCGImage, quality: settings.quality)
        else { return .failure(.failedToResize) }

        // Generate a unique posterUID, and reserve it BEFORE the write so the pruner can
        // never see the file without the reservation (see PosterReservations). The caller
        // releases it once the owning film is in MemoryStore.
        let posterUID = UUID().uuidString
        PosterReservations.reserve(posterUID)
        let destinationURL = settings.folder.appendingPathComponent("\(posterUID).jpg")

        // Write the JPEG data. `.atomic` and synchronous: the file is fully on disk before
        // this returns, and therefore before the caller's success completion fires.
        // Callers need no existence poll — see FSTabPoster.processPendingPoster.
        do { try jpegData.write(to: destinationURL, options: .atomic)
        } catch { return .failure(.failedToWrite) }
        return .success(posterUID)
    }

    // MARK: - Helpers
    //
    // COLOR SPACE NORMALIZATION: Poster art sourced from iTunes/TMDB metadata (or
    // embedded artwork) arrives with inconsistent, sometimes absent, ICC profiles —
    // sRGB, Display P3, Adobe RGB, or untagged. GalleryItem/GalleryItemView composite
    // thumbnails via plain CALayers (no CoreImage filter chain) specifically to keep
    // scrolling cheap; mismatched or missing profiles on disk would force CoreAnimation
    // to color-match each texture at composite time, reintroducing the scroll hitch
    // this architecture avoids.
    //
    // The fix: force every generated thumbnail through an explicit, fixed sRGB
    // CGColorSpace at resize time, then let NSBitmapImageRep embed that same profile
    // into the JPEG. Every poster this app writes thereafter carries the identical
    // sRGB tag CALayer/NSScreen already assume by default — no per-texture color
    // matching required at composite time.
    //
    // sRGB standard shared color space, resolved once. PosterConverter is @MainActor,
    // so a plain `static let` would be MainActor-isolated and unreachable from the
    // nonisolated `resize`/`jpegData` helpers below, even though CGColorSpace is
    // Sendable. Plain `nonisolated` (not `nonisolated(unsafe)`) is the correct,
    // warning-free way to opt out: `unsafe` is only for types not provably Sendable.
    nonisolated fileprivate static let normalizedColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // PIXEL-DENSITY FIX: Preferences.normalizedPosterWidth/Height (120x180) are LOGICAL
    // POINT dimensions, not pixel dimensions. GalleryItemView/GalleryItem set the
    // displaying CALayer's `contentsScale` to the window's backingScaleFactor (falling
    // back to 2.0 — see 23_40_GalleryItem.swift and 23_50_GalleryItemView.swift)
    // precisely because they expect the poster bitmap to already be rendered at Retina
    // pixel density, not the raw point size. The original lockFocus-based pipeline
    // satisfied this implicitly: `NSImage(size: targetSize).lockFocus()` rasterizes at
    // the main screen's backingScaleFactor (2.0 on every modern Mac), silently
    // producing a 240x360-pixel bitmap for a "120x180" poster. The CGContext-based
    // rewrite used `targetSize` as literal pixel dimensions instead, halving the
    // actual stored resolution — the dramatic quality loss reported. Restoring
    // `posterPixelScale` here reproduces the same 2x pixel density the rest of the
    // gallery pipeline has always assumed, independent of screen generation.
    nonisolated fileprivate static let posterPixelScale: CGFloat = 2.0

    // Resizes an NSImage to a target (point) size, compositing through an explicit
    // sRGB CGContext so the output pixel buffer always has a known, fixed color space —
    // regardless of what profile (if any) the source image was tagged with. The actual
    // pixel buffer is rendered at `posterPixelScale`x the requested point size so
    // on-disk posters retain full Retina resolution (see the doc comment on
    // `posterPixelScale` above).
    // Marked nonisolated so it can run off the MainActor inside Task.detached.
    nonisolated fileprivate static func resize(image: NSImage, to targetSize: NSSize) -> CGImage? {
        // Resolve the best available CGImage representation of the source at its
        // native resolution; the CGContext draw below performs the actual resample.
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let sourceCGImage = unsafe image.cgImage(forProposedRect: &proposedRect,
            context: nil, hints: nil) else { return nil }

        // Pixel dimensions of the output bitmap: point size x posterPixelScale.
        let pixelWidth = max(1, Int((targetSize.width * posterPixelScale).rounded()))
        let pixelHeight = max(1, Int((targetSize.height * posterPixelScale).rounded()))
        let pixelRect = CGRect(x: 0, y: 0,
            width: targetSize.width * posterPixelScale,
            height: targetSize.height * posterPixelScale)

        // Opaque RGB, 8-bit, explicit sRGB — no alpha channel.
        //
        // QUALITY FIX: the previous version used `.premultipliedLast` (RGBA). Poster
        // art is always effectively opaque, so that alpha channel carried no real
        // information, but its presence meant NSBitmapImageRep/the JPEG encoder had to
        // flatten it before writing — an implicit conversion that appeared to apply
        // its own lossy compression ahead of our explicit `compressionFactor`,
        // compounding into visibly blockier output than the original lockFocus-based
        // pipeline produced. Requesting `.noneSkipLast` up front means the CGImage has
        // no alpha to flatten, so the JPEG encoder writes directly from RGB pixels
        // honoring only the quality we specify — matching the original pipeline's
        // fidelity while still gaining the deterministic sRGB tagging.
        guard let context = unsafe CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: normalizedColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        // Defensive opaque white fill: `.noneSkipLast` ignores the source's alpha
        // during compositing math (the destination is always treated as fully
        // opaque), so any genuinely transparent edge pixels in an unusual source
        // (e.g. a PNG/HEIC poster with true transparency) would otherwise blend
        // against whatever garbage/zeroed bytes are in the freshly allocated buffer.
        // Filling with white first ensures that rare case degrades gracefully rather
        // than picking up stray black fringing.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pixelRect)

        context.interpolationQuality = .high
        context.draw(sourceCGImage, in: pixelRect)
        return context.makeImage() }

    // Converts a CGImage (already normalized to sRGB by `resize`) into JPEG data.
    // NSBitmapImageRep(cgImage:) preserves the CGImage's own color space, so the sRGB
    // profile applied in `resize` is embedded into the JPEG unchanged; no separate
    // tagging step is needed here.
    // Marked nonisolated so it can run off the MainActor inside Task.detached.
    nonisolated fileprivate static func jpegData(from cgImage: CGImage, quality: CGFloat = 0.9) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) }
}

// MARK: - Poster Reservations
/// Poster files that exist on disk for films that do not yet exist in MemoryStore.
///
/// `PosterPruner` deletes every JPEG in the poster folder whose name is not the
/// `posterUID` of a film in MemoryStore — and both writers of poster files put the file
/// on disk BEFORE the film that will own it is there:
///
///   • The metadata importer parses a whole batch first, writing each file's artwork as
///     it goes, and commits the films to MemoryStore only in `finishImport`. A large
///     import keeps those posters "orphaned" for minutes.
///   • The FilmSheet converts a chosen image in `confirm()` Step 1, and the film (or the
///     film's new UID) reaches MemoryStore only when Step 8 dispatches the changeset.
///
/// The pruner runs from the deferred maintenance pass after launch and from every backup
/// that has poster pruning enabled — including the automatic one thirty seconds after
/// launch. An import begun in that window lost every poster it had extracted so far:
/// the files were deleted, the films then committed with `posterUID`s that pointed at
/// nothing, and nothing ever re-extracted them.
///
/// A UID is reserved by `PosterConverter` at the moment it is generated, before the
/// write, so the pruner can never observe the file without the reservation. It is
/// released by whoever committed (or abandoned) the owning film. A UID that is never
/// released only delays pruning of one file until the next launch, so a missed release
/// fails harmless.
///
/// Lock-protected rather than actor-isolated: the converter reserves from a detached
/// task, the pruner reads from whichever background thread it happens to run on, and the
/// importer releases from the main actor.
enum PosterReservations {
    /// The set lives inside its lock, so there is no way to touch it unlocked.
    private static let reserved = OSAllocatedUnfairLock(initialState: Set<String>())

    static func reserve(_ uid: String) {
        reserved.withLock { _ = $0.insert(uid) }
    }

    static func release(_ uid: String) {
        reserved.withLock { _ = $0.remove(uid) }
    }

    static func release<S: Sequence>(_ uids: S) where S.Element == String {
        let uids = Array(uids)
        reserved.withLock { $0.subtract(uids) }
    }

    static func isReserved(_ uid: String) -> Bool {
        reserved.withLock { $0.contains(uid) }
    }
}

// MARK: - PosterPruner
// Prunes orphaned poster images from Preferences.posterImagesFolderURL.
// ARCHITECTURE: PosterPruner is a pure file-system utility. It accepts a Set of valid
// posterUIDs (sourced from MemoryStore via DataCoordinator) and compares them against
// files on disk. It never touches the database or NSManagedObjectContext directly, which means:
//   1. No @MainActor requirement - it can run freely on any thread.
//   2. No thread-safety concerns - it operates on value types (Set<String>) and file I/O.
//   3. No isolation boundary crossings - the data it needs is already Sendable.

// Result summary from a prune operation.
public struct PosterPruneReport: Sendable {
    public let keptCount: Int
    public let deletedCount: Int
    public let skippedCount: Int
    public let errorCount: Int

    public var description: String {
        "Posters kept: \(keptCount), deleted: \(deletedCount), skipped: \(skippedCount), errors: \(errorCount)" }
}

// Utility for pruning poster images.
enum PosterPruner: Loggable {
    nonisolated static let logTag = "[PosterPruner]"

    // Prunes poster images that do not correspond to a known posterUID.
    //
    // IMPORTANT: This method accepts pre-collected posterUIDs from MemoryStore (via
    // DataCoordinator.getAllPosterUIDs()). It does NOT access NSManagedObjectContext or the database.
    // All data it needs is passed in as Sendable value types, so it can safely run on
    // any thread without isolation concerns.
    //
    // - Parameters:
    //   - validPosterUIDs: The set of posterUIDs that correspond to existing films.
    //     Any poster image on disk whose basename is NOT in this set will be deleted.
    //   - snapshotTakenAt: When `validPosterUIDs` was read from MemoryStore. Every file
    //     modified at or after that moment is kept, whatever its name. A poster saved
    //     after the snapshot is missing from it, and by the time this loop reaches the
    //     file its reservation may already be released (the FilmSheet and importer
    //     release right after commit) — so neither the set nor PosterReservations would
    //     protect it. The same rule covers a save's in-flight temporary file, which the
    //     non-JPEG branch below would otherwise delete. A file spared this way is only
    //     deferred: the next prune, with a newer snapshot, judges it normally.
    static func pruneOrphanedPosters(validPosterUIDs: Set<String>, snapshotTakenAt: Date) {
        // Only run if enabled.
        guard Preferences.prunePosterImages else {
            log("Skipping: Preferences.prunePosterImages is false."); return }

        // SAFETY: refuse to run against an empty valid-UID set.
        //
        // Both call sites derive this set from MemoryStore — AppState.performDeferredMaintenance
        // and DBExporter, each via DataCoordinator.getAllPosterUIDs(). An empty set therefore
        // means one of two things, and they are indistinguishable from inside this function:
        //
        //   1. The library genuinely contains no films (or no films with posters). Every file
        //      in the folder is an orphan, so aborting leaves some dead files behind until the
        //      next prune that runs with at least one valid UID — cosmetic and fully recoverable.
        //   2. The library could not be read (a store fetch failure leaves MemoryStore
        //      empty, and an model-layer failure is exactly the kind of transient problem that
        //      resolves on the next launch). Proceeding here would delete EVERY poster image
        //      the user owns, irreversibly, with the source films still intact in the database.
        //
        // The asymmetry between those two outcomes makes aborting the only defensible choice,
        // so this guard is deliberately unconditional rather than gated on a caller-supplied
        // "the library really is empty" assertion, which would just move the same ambiguity
        // one level up. Callers that have positive evidence of a failed load skip the call
        // outright; this is the backstop for every path that does not.
        guard !validPosterUIDs.isEmpty else {
            log("Skipping: no valid poster UIDs supplied — refusing to prune, because an empty set cannot be distinguished from a failed library read.")
            return }

        guard let folderURL = Preferences.posterImagesFolderURL else {
            log("Skipping: Preferences.posterImagesFolderURL is nil."); return }
        log("Starting poster prune in folder: \(folderURL.path(percentEncoded: false))")

        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .nameKey,
                                                 .contentModificationDateKey]
        // Two seconds of slack for timestamp granularity on non-APFS volumes (HFS+ and
        // FAT hold whole or even seconds); keeping one extra file costs nothing.
        let protectedSince = snapshotTakenAt.addingTimeInterval(-2)

        guard let enumerator = fm.enumerator(at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: nil
        ) else { log("Enumerator could not be created for \(folderURL.path(percentEncoded: false))."); return }

        var kept = 0
        var deleted = 0
        var skipped = 0
        var errorCount = 0

        for case let fileURL as URL in enumerator {
            do {
                let rv = try fileURL.resourceValues(forKeys: resourceKeys)
                // Skip directories and non-regular files.
                guard rv.isRegularFile == true else { skipped += 1; continue }

                // Ignore Apple's hidden file.
                if rv.name?.lowercased() == ".ds_store" { skipped += 1; continue }

                // Written since the snapshot — see `snapshotTakenAt`. A missing date is
                // treated as recent: when in doubt, keep.
                if (rv.contentModificationDate ?? .distantFuture) >= protectedSince {
                    kept += 1; continue }

                // Check JPEG via UTType (falling back to extension).
                let isJPEG: Bool = {
                    if let type = rv.contentType {
                        return type.conforms(to: .jpeg)
                    }
                    let ext = fileURL.pathExtension.lowercased()
                    return ext == "jpg" || ext == "jpeg" }()

                // Delete non-JPEGs outright.
                guard isJPEG else {
                    try fm.removeItem(at: fileURL)
                    deleted += 1
                    continue }

                // For JPEGs: basename (without extension) must match a posterUID — either
                // one MemoryStore knows, or one reserved for a film that is on its way
                // there (see PosterReservations). Checked live, per file, rather than
                // from a snapshot taken at the start, so a reservation made while this
                // loop is running is honored too.
                let basename = fileURL.deletingPathExtension().lastPathComponent
                if validPosterUIDs.contains(basename) || PosterReservations.isReserved(basename) {
                    kept += 1
                } else {
                    try fm.removeItem(at: fileURL)
                    deleted += 1 }
            } catch {
                errorCount += 1
                if errorCount <= 5 {
                    log("ERROR deleting \(fileURL.lastPathComponent): \(error)")
                }
            }
        }

        let report = PosterPruneReport(keptCount: kept, deletedCount: deleted,
            skippedCount: skipped, errorCount: errorCount)
        if errorCount == 0 {
            log("Finished. \(report.description)")
        } else {
            log("Finished with \(errorCount) error(s). \(report.description)")
        }
    }
}
