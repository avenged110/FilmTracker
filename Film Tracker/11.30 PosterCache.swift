// MARK: - PosterCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// In-memory NSImage cache for film posters, following a metadata-first / images-progressive
// pattern: loadMetadata() sets isReady (UI may proceed) while images are restored from disk
// and filled in the background via restoreCacheFromMetadata() and completeCache().

import AppKit

/// A poster freshly decoded off the main actor, on its way into the MainActor cache.
///
/// NSImage is explicitly not Sendable, so the one handoff that needs it — a decode task's
/// result — carries it in this box instead of the whole app treating NSImage as Sendable.
/// `@unchecked` is sound because the image is created by `loadDecodedImage(from:)` and
/// never touched again by the thread that made it: ownership moves, nothing is shared.
/// Unwrapped as soon as it reaches the main actor; nothing else should hold one.
private struct DecodedPoster: @unchecked Sendable {
    let image: NSImage
}

@MainActor
@Observable
final class PosterCache: Loggable {
    nonisolated static let logTag = "[PosterCache]"

    static let shared = PosterCache()

    // IMPORTANT: isReady means METADATA is loaded, not that all images are cached.
    // UI can proceed when isReady = true; images load progressively from disk.
    private(set) var isReady: Bool = false

    // @ObservationIgnored on everything below except isReady is deliberate and load-bearing.
    //
    // PosterCache is @Observable, and GalleryItemView.body, PosterThumbnailView.body
    // (GalleryListView), and Header's poster loader all call getImageWithFallback /
    // getImageSync directly from within their SwiftUI bodies. Under @Observable's
    // per-property tracking, reading `cache[uid]` from inside a tracked body registers
    // a dependency on the *entire* `cache` dictionary, not just the one key that was
    // read. Without @ObservationIgnored, every poster insertion anywhere — the
    // background restoreCacheFromMetadata/completeCache pass, a bulk import via
    // addPosters, or a single FSTabPoster edit via addPoster/removePoster — would
    // invalidate and re-run the body of every currently-mounted gallery cell that has
    // ever read the cache, even though only one poster actually changed. That is a
    // needless multiplication of SwiftUI body re-evaluations racing against real
    // scroll/layout work, especially during initial load ramp-up or import.
    //
    // isReady is the sole property genuinely meant to drive reactive UI (GalleryView
    // gates its content on it), so it alone remains tracked. Everything else here is
    // read via explicit method calls for a point-in-time snapshot and must not
    // participate in observation.
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var cachedPosterUIDs: Set<String> = []
    @ObservationIgnored private var isMetadataLoaded = false
    @ObservationIgnored private let cacheMetadataFileName = "poster_cache_metadata.json"
    
    private var cacheMetadataURL: URL? {
        guard let dataFolder = Preferences.dataFolderURL else {
            log("Data folder URL not available")
            return nil }
        return dataFolder.appendingPathComponent(cacheMetadataFileName)
    }

    @ObservationIgnored private var cacheHits: Int = 0
    @ObservationIgnored private var cacheMisses: Int = 0
    @ObservationIgnored private var lastStatsLog: Date = Date()

    @ObservationIgnored private var metadataSaveTask: Task<Void, Never>?

    // MARK: - Population Window Tracking
    //
    // True from launch until the startup population pipeline (restoreCacheFromMetadata →
    // completeCache) has finished making the entire library resident — the FilmTracker
    // analog of the reference design's ThumbnailCache.isRestoringActiveFolder. The gallery
    // grid's Coordinator polls this from its warming-scoped scroll-prefetch tick (see
    // GallerySubview's "Warming-Scoped Scroll Prefetch" section): while true, scrolling
    // ahead of the restore's own progress triggers a look-ahead background load of the
    // approaching band; the moment this goes false the observer self-uninstalls, so the
    // mechanism costs nothing for the remainder of the session (the reference design's
    // history shows an UNSCOPED version of the same mechanism causes its own steady-state
    // micro-stutter, which is exactly why it is gated to this transient window).
    //
    // Set false by markPopulationComplete(), called from FilmTrackerApp's Step 3 launch
    // task immediately after completeCache resolves. Deliberately NOT reset to true by
    // clearMemory(): that memory-pressure path repopulates on demand via the existing
    // synchronous fallback, and re-arming scroll observers mid-session for that rare case
    // is not worth the added lifecycle complexity.
    //
    // @ObservationIgnored: this is polled from AppKit notification handlers, never read
    // inside a SwiftUI body, so it must not participate in observation.
    @ObservationIgnored private(set) var isPopulating = true

    /// Marks the startup population pipeline as finished. See `isPopulating` above.
    func markPopulationComplete() {
        guard isPopulating else { return }
        isPopulating = false

        // Retire the one-shot launch pre-paint warm at the same moment.
        //
        // registerLaunchDisplayOrder() is normally consumed by the first non-empty gallery
        // render, a few hundred milliseconds into launch. But it is gated on !newFilms.isEmpty
        // at both call sites, so a launch that lands on an EMPTY view (a filtered All Films, an
        // empty list, a library with no films yet) never consumes it. Left armed, that has two
        // consequences for the rest of the session: both gallery styles keep rebuilding the
        // O(N) posterUID array on every single update pass just to re-test the gate, and the
        // first later navigation to a populated view pays a synchronous, main-thread, parallel
        // decode of up to launchBlockingWarmCount posters — a blocking wait that is correct at
        // launch, where there is no window content to stall, and simply a hitch anywhere else.
        //
        // By this point the entire library is resident in `cache`, so the warm's own
        // `cache[$0] == nil` filter would already reduce it to a no-op; retiring the flag makes
        // that explicit and also stops the per-pass array construction. The restore's priority
        // hint has likewise already been consumed, so nothing downstream still needs it.
        if !hasPerformedLaunchBlockingWarm {
            hasPerformedLaunchBlockingWarm = true
            log("Launch pre-paint warm retired unconsumed — the launch view held no posters")
        }

        log("Startup population complete — warming-scoped scroll prefetch will disarm")
    }

    // MARK: - Launch Pre-Paint Warm
    //
    // One-shot, launch-only, SYNCHRONOUS pre-paint warm — ported from the reference
    // design's ThumbnailCache.warmLaunchViewport(for:). Loads the first
    // `launchBlockingWarmCount` posters of the launch view's DISPLAY ORDER into memory,
    // fully decoded, before returning — so every gallery cell configured later in the
    // same main-actor turn (the first reloadData) finds its image already resident on
    // its very first configure. This is what makes launch paint real posters instead of
    // placeholders: any asynchronous scheme, however fast, races window appearance.
    //
    // This REPLACES the previous implicit mechanism (each visible cell paying its own
    // synchronous, SERIAL getImageWithFallback disk-decode on the main thread at first
    // configure) with a single PARALLEL load fanned across all cores via
    // concurrentPerform — the same total work finished in a fraction of the wall time,
    // and sized to roughly two-plus worst-case viewports so an immediate fling from the
    // very first frame stays inside pre-warmed rows long enough for the restore's
    // display-ordered head phase to take over seamlessly.
    //
    // The registered display order also becomes the restore's priority ordering (see
    // restoreCacheFromMetadata), so background population proceeds top-of-grid first.
    @ObservationIgnored private var hasPerformedLaunchBlockingWarm = false

    /// Cheap gate the gallery views check before building the (O(N)) display-order
    /// array on each update pass — true only until the one-shot warm has run.
    var needsLaunchWarm: Bool { !hasPerformedLaunchBlockingWarm }

    /// Number of leading grid items the launch-only blocking warm loads before first
    /// paint. Sized to roughly two-plus worst-case viewports (largest realistic
    /// viewport ≈ 56 tiles at 7 columns), matching the reference design's sizing
    /// rationale. The wait is tightly bounded: the loads fan across all cores and are
    /// paid once per session, before any window content exists to block.
    private static let launchBlockingWarmCount = 128

    /// Registers the launch view's display-ordered posterUIDs (first non-empty gallery
    /// data to render, grid or list), performs the one-shot blocking pre-paint warm of
    /// the leading `launchBlockingWarmCount` posters, and stores the full ordering as
    /// the background restore's priority hint. Idempotent after the first effective
    /// call; callers gate on `needsLaunchWarm` to avoid building the array at all on
    /// subsequent passes.
    ///
    /// MUST be called with UIDs in GRID (display) order, BEFORE the first reloadData
    /// of the launch view — the warm covers `prefix(count)` on the premise that
    /// "first in the array" == "top of the grid."
    func registerLaunchDisplayOrder(_ posterUIDs: [String]) {
        guard !hasPerformedLaunchBlockingWarm else { return }
        let ordered = posterUIDs.filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return }
        hasPerformedLaunchBlockingWarm = true
        LaunchTimeline.markFirstGalleryFrame()
        defer { LaunchTimeline.mark("launchWarmDone") }

        // Full ordering becomes the restore's priority hint (best-effort — see
        // restoreCacheFromMetadata for the timing rationale).
        restorePriorityOrder = ordered

        guard let folderURL = Preferences.posterImagesFolderURL else { return }
        let warmUIDs = ordered.prefix(Self.launchBlockingWarmCount).filter { cache[$0] == nil }
        guard !warmUIDs.isEmpty else { return }

        let startTime = Date()
        let warmed = Self.loadImagesBlocking(warmUIDs, in: folderURL)
        for (posterUID, image) in warmed {
            cache[posterUID] = image
            cachedPosterUIDs.insert(posterUID)
        }
        let ms = Date().timeIntervalSince(startTime) * 1000
        log("Launch pre-paint warm: \(warmed.count)/\(warmUIDs.count) poster(s) resident before first paint (\(Fmt.fixed(ms, 0)) ms)")
    }

    /// Synchronous, parallel disk-load + decode of `posterUIDs`, fanned across all
    /// cores with `DispatchQueue.concurrentPerform` — used ONLY by
    /// registerLaunchDisplayOrder's launch-time pre-paint warm, where blocking the
    /// caller is the entire point (the images must be resident before the current
    /// main-actor turn yields to the first paint). Each iteration runs the same
    /// loadDecodedImage(from:) primitive every other populating path uses, so a
    /// pre-warmed image is indistinguishable from a restored one. Missing files
    /// (films without posters) simply yield nothing; results order is irrelevant.
    private nonisolated static func loadImagesBlocking(
        _ posterUIDs: [String], in folderURL: URL
    ) -> [(String, NSImage)] {
        guard !posterUIDs.isEmpty else { return [] }
        let results = BlockingWarmResults()
        DispatchQueue.concurrentPerform(iterations: posterUIDs.count) { index in
            let posterUID = posterUIDs[index]
            let url = folderURL.appendingPathComponent("\(posterUID).jpg")
            guard let image = Self.loadDecodedImage(from: url) else { return }
            results.lock.lock()
            results.pairs.append((posterUID, image))
            results.lock.unlock()
        }
        return results.pairs
    }

    /// NSLock-guarded accumulator for loadImagesBlocking's concurrentPerform workers.
    /// @unchecked Sendable: all mutation of `pairs` occurs strictly under `lock`, and
    /// the instance never escapes the function that creates it.
    private final class BlockingWarmResults: @unchecked Sendable {
        let lock = NSLock()
        var pairs: [(String, NSImage)] = []
    }

    /// Display-ordered restore priority hint, set by registerLaunchDisplayOrder.
    /// Consumed (read once) by restoreCacheFromMetadata to load top-of-grid posters
    /// first. @ObservationIgnored for the same reason as every other bookkeeping field.
    @ObservationIgnored private var restorePriorityOrder: [String] = []

    init() { log("PosterCache initialized (metadata-first, images-progressive)") }

    // MARK: - Synchronous Access (Primary Path)
    // Synchronous cache lookup - returns nil on cache miss.
    // Called during scroll for immediate display; misses trigger background population.
    func getImageSync(for posterUID: String) -> NSImage? {
        return cache[posterUID]
    }

    /// Synchronous image retrieval with disk fallback on cache miss.
    /// Returns the cached image if available; otherwise loads from disk, stores in cache,
    /// and returns the image. Returns nil only if the file doesn't exist.
    ///
    /// This is the canonical single-path method for all synchronous image access that
    /// needs a disk fallback. Used by GalleryItem (scroll display, via
    /// refreshTileContent) and GalleryListView (row display). Centralizes the
    /// cache-miss → disk-load → cache-store pattern that would otherwise be duplicated
    /// across call sites.
    ///
    /// NOTE: Disk I/O on the main thread is acceptable here because PosterCache's
    /// background loading pipeline (restoreCacheFromMetadata + completeCache) ensures
    /// cache misses are extremely rare during normal scrolling.
    ///
    /// This path uses `Self.loadDecodedImage(from:)` — NOT `NSImage(contentsOf:)` — so
    /// the JPEG bitmap is fully decoded before the image is stored and returned.
    /// `NSImage(contentsOf:)` only reads file bytes; AppKit would defer the actual
    /// decode until first draw, paying that cost on the main thread mid-scroll the
    /// instant the tile becomes visible. Decoding here makes the per-miss cost
    /// slightly higher (read + decode instead of read only) but eliminates the
    /// deferred draw-time decode of the same image, so net main-thread cost is
    /// equal or lower — and the image is permanently hitch-free thereafter.
    func getImageWithFallback(for posterUID: String) -> NSImage? {
        guard !posterUID.isEmpty else { return nil }
        
        // Try cache first (fastest path)
        if let image = cache[posterUID] { return image }
        
        // Cache miss — load and decode from disk
        guard let folderURL = Preferences.posterImagesFolderURL else { return nil }
        let imageURL = folderURL.appendingPathComponent("\(posterUID).jpg")
        guard let image = Self.loadDecodedImage(from: imageURL) else { return nil }
        
        // Store the already-loaded image directly — no second disk read needed
        cache[posterUID] = image
        cachedPosterUIDs.insert(posterUID)
        
        return image
    }

    /// Cache-only poster lookup for drag-preview thumbnails. Returns nil for an
    /// empty posterUID or a cache miss — it deliberately never falls back to disk.
    ///
    /// Both gallery view styles resolve their flyback drag-preview image while
    /// still inside their respective NSView's mouseDown drag-detection tracking
    /// loop (GalleryCollectionView's manual drag path, GalleryListView's native
    /// NSTableView path). That loop runs on the main thread elevated to
    /// User-Interactive QoS. getImageWithFallback's synchronous disk read can
    /// hand off to lower-QoS kernel/IO threads, and the main thread blocking on
    /// that handoff while still elevated is a priority inversion (confirmed via
    /// Thread Performance Checker on the list-view path). A cache miss here is
    /// rare — PosterCache's background restore keeps the cache warm — and the
    /// drag-preview thumbnail is purely cosmetic, so showing no poster on a miss
    /// is preferable to risking a main-thread stall during drag initiation.
    func dragPreviewImage(for posterUID: String) -> NSImage? {
        guard !posterUID.isEmpty else { return nil }
        return getImageSync(for: posterUID)
    }

    // MARK: - Asynchronous Access
    // Asynchronous image retrieval with cache population on miss.
    // Primarily used for prefetching and background population.
    func getImageAsync(for posterUID: String) async -> NSImage? {
        if let cached = cache[posterUID] {
            // Counter increments and stat logging are only useful when logging is on;
            // skip them entirely during normal (logging-off) operation to avoid the
            // Date() allocation and timeIntervalSince arithmetic on every async access.
            if Logger.isLoggingEnabled {
                cacheHits += 1
                logStatsIfNeeded()
            }
            return cached
        }
        if Logger.isLoggingEnabled {
            cacheMisses += 1
            logStatsIfNeeded()
        }

        guard let image = await loadImage(posterUID: posterUID)?.image else { return nil }
        cache[posterUID] = image
        cachedPosterUIDs.insert(posterUID)

        if Logger.isLoggingEnabled && cache.count % 100 == 0 {
            log("Cached \(cache.count) images")
            saveMetadataThrottled()
        }
        return image
    }

    // MARK: - Metadata Loading
    // STARTUP: Disk I/O and JSON decoding now run on a background
    // thread via Task.detached, enabling true parallelism with other startup work.
    // Previously this ran entirely on MainActor, blocking the main thread and
    // preventing the async let in initializeApp() from actually parallelizing.
    func loadMetadata() async {
        // Load-once. A repeat call would re-read the on-disk set and overwrite
        // cachedPosterUIDs wholesale, silently discarding every UID added since the first
        // load by prefetchPosters(), addPosters(), or addPoster() — and, if the file is
        // gone or unreadable by then, replacing a populated set with an empty one. The
        // isMetadataLoaded flag already existed for restoreCacheFromMetadata's benefit;
        // this makes it govern entry as well.
        guard !isMetadataLoaded else {
            log("Poster cache metadata already loaded — skipping")
            return
        }

        // Timed so the three concurrent Phase 1 jobs can be compared against each other.
        // The claim this measurement exists to confirm or refute is that this load always
        // finishes well ahead of the snapshot cache decode, and therefore never gates the
        // launch progress indicator.
        let loadStart = ContinuousClock.now

        guard let url = cacheMetadataURL else {
            log("Cache metadata URL not available")
            isMetadataLoaded = true
            // UI can proceed even with no metadata
            isReady = true
            return
        }

        // Use URL.resourceValues to check file existence — avoids the deprecated .path
        // String conversion and bridges directly into the modern URL resource API.
        let exists = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard exists else {
            log("No cache metadata found at \(url.lastPathComponent) - starting with empty cache")
            isMetadataLoaded = true
            // UI can proceed with empty cache
            isReady = true
            return
        }

        // Perform disk read and JSON decoding on a background thread.
        // This frees MainActor to begin other startup work concurrently.
        let loaded: Set<String>? = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                let metadata = try JSONDecoder().decode(CacheMetadata.self, from: data)
                return Set(metadata.posterUIDs)
            } catch {
                return nil
            }
        }.value

        if let loaded = loaded {
            cachedPosterUIDs = loaded
            log("Loaded poster cache metadata: \(loaded.count) entries")
        } else {
            log("Failed to load cache metadata - starting with empty cache")
        }

        log("STARTUP BREAKDOWN (poster metadata) — total: \((ContinuousClock.now - loadStart).formattedMilliseconds) | entries: \(cachedPosterUIDs.count)")
        
        isMetadataLoaded = true
        // Set isReady after metadata loads.
        // UI can now proceed - images will load progressively.
        isReady = true
    }

    // MARK: - Background Image Restoration
    // Restores images from disk into memory cache.
    // Called after UI is responsive - this is background work.
    // Images that aren't restored here will load on-demand when viewed.
    func restoreCacheFromMetadata() async {
        guard isMetadataLoaded else {
            log("Cannot restore cache: Metadata not loaded")
            return
        }
        guard !cachedPosterUIDs.isEmpty else {
            log("No cached posters to restore - cache will be built as-needed")
            return
        }
        
        log("Restoring cache from \(cachedPosterUIDs.count) poster UIDs (background)")

        // Best-effort ordering handoff: yield the main actor once before snapshotting
        // the UID list, giving SwiftUI's first render pass — and with it the gallery's
        // first updateNSView, which calls registerLaunchDisplayOrder — a chance to run
        // first so restorePriorityOrder is populated. If the render hasn't happened yet
        // (or the app launched into a posterless view), the restore proceeds exactly as
        // before with an unordered snapshot: correctness is unaffected either way, and
        // the launch blocking warm independently guarantees the visible viewport.
        await Task.yield()

        let startTime = Date()

        // TWO-PHASE, DISPLAY-ORDERED RESTORE (reconciled from the reference design's
        // ThumbnailCache.restore head/tail split):
        //
        // Ordering — when a display-order hint was registered, load those UIDs first,
        // in grid order, followed by any remaining metadata UIDs (posters not in the
        // launch view, e.g. filtered out). Without a hint, the unordered metadata set
        // is used exactly as before.
        //
        // Priority — the first `restoreHeadCount` UIDs (the grid's topmost region, the
        // band the user sees and scrolls first) load at `.userInitiated`; everything
        // after loads at `.utility`, so the long remainder of a large library populates
        // without competing with the main thread's own user-interactive work.
        let uidsToLoad: [String]
        if restorePriorityOrder.isEmpty {
            uidsToLoad = Array(cachedPosterUIDs)
        } else {
            var seen = Set<String>()
            seen.reserveCapacity(cachedPosterUIDs.count)
            var ordered: [String] = []
            ordered.reserveCapacity(cachedPosterUIDs.count)
            for uid in restorePriorityOrder
            where cachedPosterUIDs.contains(uid) && seen.insert(uid).inserted {
                ordered.append(uid)
            }
            for uid in cachedPosterUIDs where !seen.contains(uid) {
                ordered.append(uid)
            }
            uidsToLoad = ordered
        }
        let totalCount = uidsToLoad.count
        let headCount = min(Self.restoreHeadCount, totalCount)

        // Adaptive batch size based on total count
        let batchSize = min(30, max(10, totalCount / 20))
        var loadedCount = 0

        // Restore accounting. `loadedCount` alone cannot explain the outcome, because a
        // UID in the metadata reaches the end of a batch by three different routes and
        // only one of them is a load:
        //
        //   - Already resident: populated by the launch pre-paint warm (or by an earlier
        //     batch). Skipped deliberately; not a failure.
        //   - Loaded: read and decoded from disk here.
        //   - Failed: the file is gone or unreadable. These are exactly the UIDs the stale
        //     cleanup at the end of this method prunes from the metadata, so counting them
        //     gives that cleanup a cross-check rather than leaving it to be inferred.
        //
        // Tracking all three makes the completion line self-verifying: the three must sum
        // to `totalCount`, so a discrepancy is visible in the log rather than silent.
        var alreadyResidentCount = 0
        var failedCount = 0

        // Progress milestones by CROSSING, not by exact equality.
        //
        // This previously read `if loadedCount % 200 == 0`, which was wrong in both
        // directions and is worth spelling out so it is not reintroduced:
        //
        //   - It fired spuriously. `0 % 200 == 0` is true, so every batch that loaded
        //     nothing logged "Restored 0/N". On a warm launch the pre-paint warm has
        //     already populated the head of the display order — which is exactly where
        //     `restorePriorityOrder` places the first batches — so the leading batches
        //     load nothing and the same zero line was emitted several times in a row.
        //   - It fired almost never when it mattered. Batches yield an irregular number
        //     of images (0…batchSize, depending on cache overlap and read failures), so
        //     `loadedCount` has to LAND on a multiple of 200 rather than pass one. A
        //     1,241-image restore produced zero genuine progress lines.
        //
        // Comparing against a milestone that advances past whatever value was actually
        // reached fixes both: one line per 200 images loaded, no line when nothing was,
        // and no dependence on batches dividing evenly into the interval.
        let progressInterval = 200
        var nextProgressMilestone = progressInterval
        var loggedResidentCoverage = false

        // Running offset of the first UID in the current batch, used to decide the
        // batch's load priority (head vs. tail). Batches are contiguous slices of
        // uidsToLoad, so this exactly partitions the head/tail boundary (a batch
        // straddling the boundary loads at the head's priority — harmless).
        var batchOffset = 0

        for batch in uidsToLoad.chunked(into: batchSize) {
            let batchPriority: TaskPriority = batchOffset < headCount ? .userInitiated : .utility
            batchOffset += batch.count
            guard !Task.isCancelled else {
                log("Cache restore canceled after \(loadedCount) loaded, "
                    + "\(alreadyResidentCount) already resident, \(failedCount) failed "
                    + "(of \(totalCount))")
                return
            }

            // Resident UIDs are filtered out HERE, on MainActor, rather than inside each
            // child task. This is where `cache` lives, so the check is a direct read with
            // no snapshot to capture and no hop, and — unlike the previous arrangement —
            // no task is spawned at all for a UID that is already in hand. The filter is
            // re-run per batch (not once before the loop) so images loaded by batch N are
            // correctly excluded from batch N+1, which is the same reason the snapshot it
            // replaces was taken per batch.
            //
            // It also separates the two reasons a UID can produce no image: skipped
            // because resident (counted here) versus attempted and failed (counted below).
            // The child tasks previously returned nil for both, which is what made the
            // outcome unaccountable.
            let pending = batch.filter { cache[$0] == nil }
            alreadyResidentCount += batch.count - pending.count

            if !pending.isEmpty {
                let batchResults = await withTaskGroup(of: (String, DecodedPoster)?.self) { group in
                    for posterUID in pending {
                        // PosterCache.shared is a singleton — no [weak self] needed.
                        // loadImage is nonisolated and does not access MainActor state.
                        group.addTask {
                            if let image = await self.loadImage(posterUID: posterUID,
                                                                priority: batchPriority) {
                                return (posterUID, image)
                            }
                            return nil
                        }
                    }

                    var results: [(String, NSImage)] = []
                    for await result in group {
                        if let (posterUID, decoded) = result { results.append((posterUID, decoded.image)) }
                    }
                    return results
                }

                for (posterUID, image) in batchResults {
                    cache[posterUID] = image
                    loadedCount += 1
                }

                // Every pending UID that produced no image was a genuine read failure —
                // resident UIDs never entered `pending`.
                failedCount += pending.count - batchResults.count
            }

            // One line each time the load count passes a milestone, with the milestone
            // then advanced past the value actually reached so an oversized jump cannot
            // emit two lines or skip the next threshold.
            if loadedCount >= nextProgressMilestone {
                log("Restored \(loadedCount)/\(totalCount) posters")
                nextProgressMilestone =
                    ((loadedCount / progressInterval) + 1) * progressInterval
            }

            // Emitted at most once, at the boundary where the already-resident run ends
            // and real loading begins. This is the information the repeated "Restored 0/N"
            // lines were accidentally conveying — that the restore opened on posters it
            // already had — stated once and quantified, instead of as a run of identical
            // zeroes whose length happened to encode it.
            //
            // Deliberately worded without attributing the residents to the launch
            // pre-paint warm and without claiming they form a contiguous head of the
            // display order, because neither is guaranteed. When `restorePriorityOrder` is
            // empty (the app launched into a posterless view, so no display-order hint was
            // ever registered) `uidsToLoad` is an unordered set and the residents are
            // scattered through it. A scroll-driven prefetch or a poster edit landing while
            // this loop runs can also populate the cache concurrently. The pre-paint warm
            // is the usual explanation, not the only one, so the line reports the count it
            // actually measured and leaves the cause to the reader.
            if !loggedResidentCoverage, loadedCount > 0 {
                loggedResidentCoverage = true
                if alreadyResidentCount > 0 {
                    log("Restore skipped \(alreadyResidentCount) already-resident poster(s) "
                        + "before its first disk load (typically the launch pre-paint warm)")
                }
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        // The three outcomes are reported together because they must sum to totalCount;
        // stating them side by side makes that identity checkable at a glance, and makes
        // `failedCount` agree with the stale-UID count logged just below.
        log("Cache restoration complete: \(loadedCount) loaded, "
            + "\(alreadyResidentCount) already resident, \(failedCount) failed "
            + "— \(loadedCount + alreadyResidentCount)/\(totalCount) resident "
            + "in \(Fmt.fixed(duration, 2))s")

        // Clean up stale UIDs: any posterUID in the metadata that failed to load from disk
        // (file deleted externally, disk error, etc.) must be removed from cachedPosterUIDs.
        // Without this, completeCache() skips these UIDs because it thinks they're already
        // cached, and the poster is never reloaded from the source images folder.
        let loadedKeys = Set(cache.keys)
        let staleUIDs = cachedPosterUIDs.subtracting(loadedKeys)
        if !staleUIDs.isEmpty {
            cachedPosterUIDs.subtract(staleUIDs)
            log("Removed \(staleUIDs.count) stale UID(s) from poster cache metadata (files missing on disk)")
            saveMetadataThrottled()
        }
    }

    /// Number of leading display-order UIDs the restore loads at `.userInitiated`
    /// (the "head" phase) before dropping to `.utility` for the remainder — sized, per
    /// the reference design, to comfortably cover the initial viewport plus the first
    /// stretch of scrolling on any window size (roughly the first 85 rows at 7
    /// columns), while remaining small enough that the phase finishes within a few
    /// hundred milliseconds of launch.
    private static let restoreHeadCount = 600

    // MARK: - Warming-Window Prefetch Ingestion
    //
    // Background load-and-commit for a scroll-driven look-ahead band, called by
    // GallerySubview's warming-scoped prefetch (see that file's "Warming-Scoped Scroll
    // Prefetch" section) while `isPopulating` is true. Loads at `.userInitiated` — the
    // user is actively scrolling toward these posters, making them the most urgent
    // pending work — one tier above the restore's own tail phase, so a prefetch burst
    // naturally jumps the queue. Committed images are indistinguishable from restored
    // ones. No metadata save: every UID here already exists on disk and is covered by
    // the restore/completeCache pipeline's own throttled saves.
    func prefetchPosters(_ posterUIDs: [String]) async {
        let pending = posterUIDs.filter { !$0.isEmpty && cache[$0] == nil }
        guard !pending.isEmpty else { return }

        for batch in pending.chunked(into: 10) {
            guard !Task.isCancelled else { return }

            let batchResults = await withTaskGroup(of: (String, DecodedPoster)?.self) { group in
                for posterUID in batch {
                    group.addTask {
                        if let image = await self.loadImage(posterUID: posterUID,
                                                            priority: .userInitiated) {
                            return (posterUID, image)
                        }
                        return nil
                    }
                }
                var results: [(String, NSImage)] = []
                for await result in group {
                    if let (posterUID, decoded) = result { results.append((posterUID, decoded.image)) }
                }
                return results
            }

            for (posterUID, image) in batchResults where cache[posterUID] == nil {
                cache[posterUID] = image
                cachedPosterUIDs.insert(posterUID)
            }
        }
    }
    
    // MARK: - Complete Cache Building
    /// Completes cache by adding all uncached posters in the background.
    /// Should be called after restoreCacheFromMetadata() completes and the initial viewport
    /// items are cached. This allows the entire cache to be populated without requiring
    /// the user to scroll through the entire library.
    ///
    /// The method filters out already-cached UIDs and delegates to addPosters() which
    /// handles efficient batching and progress logging.
    ///
    /// - Parameter allPosterUIDs: Complete list of all poster UIDs from the database
    func completeCache(withAllPosterUIDs allPosterUIDs: [String]) async {
        // Safety check - don't start if metadata isn't ready
        guard isReady else {
            log("Cannot complete cache: Metadata not ready")
            return
        }
        
        // Filter out already-cached UIDs, and deduplicate.
        //
        // getAllPosterUIDs() returns one entry per FILM, so two films sharing a posterUID
        // (combo packs, re-releases, deliberate duplicates) yield the same UID twice.
        // addPosters() snapshots cachedPosterUIDs ONCE before its batch loop rather than
        // per-batch, so a duplicate landing in a later batch is not filtered by that
        // snapshot and gets loaded and decoded a second time. Collapsing here is both the
        // cheaper and the more honest fix — it also makes the count in the log below
        // reflect the actual work about to be performed.
        var seen = Set<String>()
        let uncachedUIDs = allPosterUIDs.filter {
            !$0.isEmpty && !cachedPosterUIDs.contains($0) && seen.insert($0).inserted
        }
        
        guard !uncachedUIDs.isEmpty else {
            log("Cache is already complete - no new posters to add")
            return
        }
        
        log("Completing cache: \(uncachedUIDs.count) uncached posters out of \(allPosterUIDs.count) total")
        await addPosters(uncachedUIDs)
    }

    // MARK: - Metadata Persistence
    // Disk I/O and JSON encoding run on a background thread via Task.detached, matching
    // MetadataCache.save() and MemoryStoreCache.save(). Previously the encode, the
    // directory creation, and the atomic write all executed inline on MainActor: this
    // method is async but had no suspension point around its I/O, so the main thread
    // blocked for the whole write. That mattered most exactly when it was least
    // affordable — saveMetadataThrottled() fires from addPosters() as the startup
    // population pipeline completes each batch, and again from the shutdown flush.
    func saveMetadata() async {
        // Before loadMetadata() the set says nothing about the posters on disk; writing it
        // (a quit during launch) replaced the file with an empty list.
        guard isMetadataLoaded else {
            log("Cache metadata save skipped: not loaded yet")
            return
        }
        guard let url = cacheMetadataURL else {
            log("Cannot save cache metadata: URL not available")
            return
        }

        // Capture a value-type copy before leaving MainActor so the detached task has no
        // access to shared mutable state.
        let uids = Array(cachedPosterUIDs)
        let count = uids.count

        let saveError: String? = await Task.detached(priority: .utility) {
            let directory = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return "could not create cache directory — \(error.localizedDescription)"
            }

            do {
                let metadata = CacheMetadata(posterUIDs: uids)
                let encoded = try JSONEncoder().encode(metadata)
                try encoded.write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let saveError {
            log("Failed to save cache metadata: \(saveError)")
        } else {
            log("Saved poster cache metadata: \(count) entries to \(url.lastPathComponent)")
        }
    }

    private func saveMetadataThrottled() {
        metadataSaveTask?.cancel()
        metadataSaveTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.saveMetadata()
        }
    }

    // MARK: - Cache Mutations
    func addPoster(_ posterUID: String) async {
        guard !posterUID.isEmpty else { return }

        if cache[posterUID] != nil && cachedPosterUIDs.contains(posterUID) {
            log("Poster already cached: \(posterUID)")
            return
        }

        if let image = await loadImage(posterUID: posterUID)?.image {
            cache[posterUID] = image
            cachedPosterUIDs.insert(posterUID)
            saveMetadataThrottled()
            log("Added poster to cache: \(posterUID)")
        } else {
            log("Failed to load poster for caching: \(posterUID)")
        }
    }

    func addPosters(_ posterUIDs: [String]) async {
        let validUIDs = posterUIDs.filter { !$0.isEmpty }
        guard !validUIDs.isEmpty else { return }

        log("Adding \(validUIDs.count) posters to cache")
        let startTime = Date()
        var addedCount = 0

        let batchSize = 10

        // Snapshot cache state once on MainActor — avoids ~N MainActor hops inside TaskGroup
        let alreadyCached = cachedPosterUIDs

        for batch in validUIDs.chunked(into: batchSize) {
            guard !Task.isCancelled else {
                log("Batch poster addition canceled after \(addedCount) images")
                return
            }

            let batchResults = await withTaskGroup(of: (String, DecodedPoster)?.self) { group in
                for posterUID in batch {
                    // PosterCache.shared is a singleton — no [weak self] needed.
                    // loadImage is nonisolated and does not access MainActor state.
                    group.addTask {
                        // Check local snapshot — no MainActor hop needed
                        if alreadyCached.contains(posterUID) { return nil }

                        if let image = await self.loadImage(posterUID: posterUID) {
                            return (posterUID, image)
                        }
                        return nil
                    }
                }

                var results: [(String, NSImage)] = []
                for await result in group {
                    if let (posterUID, decoded) = result { results.append((posterUID, decoded.image)) }
                }
                return results
            }

            for (posterUID, image) in batchResults {
                cache[posterUID] = image
                cachedPosterUIDs.insert(posterUID)
                addedCount += 1
            }

            if addedCount % 50 == 0 {
                log("Added \(addedCount)/\(validUIDs.count) posters")
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        log("Added \(addedCount) posters to cache in \(Fmt.fixed(duration, 2))s")
        saveMetadataThrottled()
    }

    func removePoster(_ posterUID: String) {
        guard !posterUID.isEmpty else { return }

        cache.removeValue(forKey: posterUID)
        cachedPosterUIDs.remove(posterUID)
        saveMetadataThrottled()
        log("Removed poster from cache: \(posterUID)")
    }

    func removePosters(_ posterUIDs: [String]) {
        let validUIDs = posterUIDs.filter { !$0.isEmpty }
        guard !validUIDs.isEmpty else { return }

        for posterUID in validUIDs {
            cache.removeValue(forKey: posterUID)
            cachedPosterUIDs.remove(posterUID)
        }

        saveMetadataThrottled()
        log("Removed \(validUIDs.count) posters from cache")
    }

    // MARK: - Cache Management
    // Clears in-memory images while preserving metadata on disk.
    // Use for memory pressure situations - images will reload on demand.
    func clearMemory() {
        let count = cache.count
        cache.removeAll()
        cacheHits = 0
        cacheMisses = 0
        // NOTE: Don't reset isReady - metadata is still valid on disk
        log("Cleared poster cache memory (\(count) images freed, metadata preserved on disk)")
    }

    // MARK: - Private Helpers
    private func logStatsIfNeeded() {
        guard Logger.isLoggingEnabled else { return }
        let now = Date()
        if now.timeIntervalSince(lastStatsLog) >= 5.0 {
            let total = cacheHits + cacheMisses
            let hitRate = total > 0 ? (Double(cacheHits) / Double(total) * 100.0) : 0.0
            log("Cache stats: \(cacheHits) hits, \(cacheMisses) misses (hit rate: \(Fmt.fixed(hitRate, 1))%)")
            lastStatsLog = now
        }
    }

    /// - Parameter priority: detached-task priority for the disk read + decode.
    ///   Defaults to `.userInitiated` (all pre-existing call sites are unchanged);
    ///   the restore's tail phase passes `.utility` so bulk background population
    ///   never competes with the main thread at equal footing.
    private nonisolated func loadImage(posterUID: String,
                                       priority: TaskPriority = .userInitiated) async -> DecodedPoster? {
        guard let folderURL = Preferences.posterImagesFolderURL else { return nil }

        // Task.detached replaces the previous DispatchQueue.global(qos:).async +
        // withCheckedContinuation pattern: it is the idiomatic Swift Concurrency way
        // to push work off the current executor without inheriting actor isolation,
        // and is consistent with the Task.detached usage throughout the rest of the app.
        //
        // The load itself goes through loadDecodedImage(from:) — CGImageSource with
        // kCGImageSourceShouldCacheImmediately — rather than NSImage(contentsOf:), so
        // every image entering the cache via this path (restoreCacheFromMetadata,
        // completeCache/addPosters, addPoster, getImageAsync) is already fully decoded
        // on this background thread. No deferred main-thread decode cost remains for
        // any of them, at any point in the session — including posters added by
        // imports or FSTabPoster edits long after launch.
        let imageURL = folderURL.appendingPathComponent("\(posterUID).jpg")
        return await Task.detached(priority: priority) {
            Self.loadDecodedImage(from: imageURL).map(DecodedPoster.init)
        }.value
    }

    // MARK: - Decoded Loading
    //
    // The single load-and-decode primitive behind every disk read in this cache
    // (loadImage(posterUID:) for all background population paths, and
    // getImageWithFallback for the rare synchronous main-thread miss). Unlike
    // NSImage(contentsOf:) — which reads file bytes but defers JPEG rasterization
    // until first draw, silently pushing that cost onto the main thread mid-scroll —
    // this decodes the full bitmap on the calling thread via CGImageSource with
    // kCGImageSourceShouldCacheImmediately, so by the time the image reaches a
    // gallery cell the bitmap is already resident and drawing is a straight
    // composite. This makes the cache-population passes the decode passes: no
    // separate library-wide warming sweep is required afterward.

    /// Loads a single poster from disk, fully decoded. Returns nil when the file does
    /// not exist or cannot be decoded — preserving getImageWithFallback's
    /// "nil only if the file doesn't exist" contract. Safe to call from any
    /// concurrency context (nonisolated static, pure I/O + decode). Internal rather
    /// than private so FSTabPoster's stored-poster preview decodes the same way.
    nonisolated static func loadDecodedImage(from url: URL) -> NSImage? {
        // Cheap existence check first: CGImageSourceCreateWithURL logs a noisy
        // "*** ERROR: can't open ..." console message for a missing file rather than
        // failing silently. Films without posters routinely reach this path (an
        // entirely normal condition, not an error), so checking first avoids invoking
        // CGImageSource at all — and skips the queue hop — for that expected case,
        // with no change in behavior: the function still returns nil exactly as
        // before whenever the file is absent.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return posterDecodeQueue.sync { decodeImage(from: url) }
    }

    /// The actual ImageIO decode, run only on `posterDecodeQueue` — see that
    /// property's doc comment for why. Pure, synchronous, and side-effect-free.
    private nonisolated static func decodeImage(from url: URL) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(size: size)
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return image
    }

    /// Dedicated queue for all poster decode work. ImageIO's decode machinery uses its
    /// own internal, process-wide synchronization that a lower-priority thread can hold
    /// regardless of which queue dispatched it: with decodes now issued from both
    /// `.userInitiated` background population tasks and the main thread (the
    /// getImageWithFallback miss path), a lower-QoS decode holding that lock could
    /// stall a higher-QoS one waiting on it — a real priority inversion. Routing every
    /// decode through one `.userInitiated` concurrent queue closes that gap. Concurrent
    /// (not serial): the population paths already bound how many decodes are in flight
    /// via their own TaskGroup batch sizes, so this queue simply needs to allow that
    /// same parallelism, not add its own serialization.
    ///
    /// `nonisolated` is required (not just on the functions that use it): PosterCache
    /// is `@MainActor`, so its static members are actor-isolated by default, and the
    /// decode functions above are themselves `nonisolated`. Safe to mark: DispatchQueue
    /// is an immutable, thread-safe reference type, and this is a `let` never mutated
    /// after init.
    private nonisolated static let posterDecodeQueue = DispatchQueue(
        label: "com.filmtracker.poster-decode",
        qos: .userInitiated,
        attributes: .concurrent)
}

// MARK: - Cache Metadata
private struct CacheMetadata: Codable { let posterUIDs: [String] }
