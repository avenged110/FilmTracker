// MARK: - PosterCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// In-memory cache of decoded poster images. Metadata loads first so the UI can proceed, and images are
/// restored from disk in the background.


import AppKit
import Synchronization

/// A decoded poster passed from a background task to the main actor.
///
/// NSImage is not Sendable, so this box carries it across the handoff. `@unchecked` is sound because the
/// image is never touched again by the thread that created it.
private struct DecodedPoster: @unchecked Sendable {
    let image: NSImage
}

@MainActor
@Observable
final class PosterCache: Loggable {
    nonisolated static let logTag = "[PosterCache]"

    static let shared = PosterCache()

    /// IMPORTANT: isReady means METADATA is loaded, not that all images are cached.
    /// UI can proceed when isReady = true; images load progressively from disk.
    private(set) var isReady: Bool = false

    /// Everything except isReady is @ObservationIgnored. Under @Observable, reading `cache[uid]` in a SwiftUI
    /// body would subscribe that body to the whole dictionary, so every insertion would re-run every mounted cell.
    /// isReady drives the UI (GalleryView gates content on it), so it alone stays observed.
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
    ///
    /// True from launch until the startup population pipeline (restoreCacheFromMetadata, then completeCache) has
    /// made the whole library resident. While true, GallerySubview's scroll prefetch loads the band ahead of the
    /// user. Once false, that observer uninstalls.
    ///
    /// Set false by markPopulationComplete(). clearMemory() does not re-arm it, because memory-pressure reloads
    /// happen on demand.
    ///
    /// @ObservationIgnored: this is polled from AppKit notification handlers, never read in a SwiftUI body.
    @ObservationIgnored private(set) var isPopulating = true

    /// Marks the startup population pipeline as finished. See `isPopulating` above.
    func markPopulationComplete() {
        guard isPopulating else { return }
        isPopulating = false

        /// Retire the one-shot launch warm. It is consumed only by a non-empty launch view, so an empty launch
        /// view would leave it armed. Armed, it keeps the display-order array rebuilding on every update pass, and a
        /// later navigation to a populated view would pay a blocking decode on the main thread. The library is
        /// already resident by now, so the warm would be a no-op anyway.
        earlyLaunchWarm = nil
        if !hasPerformedLaunchBlockingWarm {
            hasPerformedLaunchBlockingWarm = true
            log("Launch pre-paint warm retired unconsumed — the launch view held no posters")
        }

        log("Startup population complete — warming-scoped scroll prefetch will disarm")
    }

    // MARK: - Launch Pre-Paint Warm
    ///
    /// One-shot, launch-only, synchronous pre-paint warm. It loads the first `launchBlockingWarmCount` posters of
    /// the launch view's display order, fully decoded, before returning. Cells configured later in the same
    /// main-actor turn then find their images already resident. The loads run in parallel across cores.
    ///
    /// The registered display order also becomes the restore's priority ordering (see restoreCacheFromMetadata).
    @ObservationIgnored private var hasPerformedLaunchBlockingWarm = false

    /// Cheap gate the gallery views check before building the (O(N)) display-order
    /// array on each update pass — true only until the one-shot warm has run.
    var needsLaunchWarm: Bool { !hasPerformedLaunchBlockingWarm }

    /// Number of leading grid items the launch-only warm loads before first paint, roughly two worst-case viewports.
    private static let launchBlockingWarmCount = 128

    /// Registers the launch view's display-ordered poster UIDs, performs the one-shot warm of the leading
    /// `launchBlockingWarmCount` posters, and stores the full ordering as the restore's priority hint. Callers
    /// check `needsLaunchWarm` first, so the array is not built on later passes.
    ///
    /// UIDs must be in grid (display) order, and this must run before the launch view's first reload.
    func registerLaunchDisplayOrder(_ posterUIDs: [String]) {
        guard !hasPerformedLaunchBlockingWarm else { return }
        let ordered = posterUIDs.filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return }
        hasPerformedLaunchBlockingWarm = true
        LaunchTimeline.markFirstGalleryFrame()
        defer { LaunchTimeline.mark("launchWarmDone") }

        /// Full ordering becomes the restore's priority hint (best-effort — see
        /// restoreCacheFromMetadata for the timing rationale).
        restorePriorityOrder = ordered

        guard let folderURL = Preferences.posterImagesFolderURL else { return }
        let leading = Array(ordered.prefix(Self.launchBlockingWarmCount))
        saveLaunchWarmOrder(leading)

        let startTime = Date()
        /// Install what the early warm already decoded for this order (see beginEarlyLaunchWarm).
        /// The wait is normally zero: the early decode finished while the window was built.
        var earlyHits = 0
        if let early = earlyLaunchWarm {
            earlyLaunchWarm = nil
            early.group.wait()
            let decoded = early.take()
            for posterUID in leading where cache[posterUID] == nil {
                guard let poster = decoded[posterUID] else { continue }
                cache[posterUID] = poster.image
                cachedPosterUIDs.insert(posterUID)
                earlyHits += 1
            }
        }

        let warmUIDs = leading.filter { cache[$0] == nil }
        let warmed = Self.loadImagesBlocking(warmUIDs, in: folderURL)
        for (posterUID, image) in warmed {
            cache[posterUID] = image
            cachedPosterUIDs.insert(posterUID)
        }
        let ms = Date().timeIntervalSince(startTime) * 1000
        log("Launch pre-paint warm: \(earlyHits) from the early warm + \(warmed.count)/\(warmUIDs.count) decoded now, resident before first paint (\(Fmt.fixed(ms, 0)) ms)")
    }

    // MARK: - Early Launch Warm
    ///
    /// The early warm decodes the posters the previous launch warmed. The launch view and its sort rarely change
    /// between sessions, so each launch records its warmed UIDs. The next launch decodes them in the background from
    /// FilmTrackerApp.init. registerLaunchDisplayOrder installs the ones still wanted and decodes the rest. A wrong
    /// guess costs only the background decode.
    @ObservationIgnored private var earlyLaunchWarm: EarlyLaunchWarm?
    @ObservationIgnored private let launchWarmOrderFileName = "poster_launch_order.json"

    private var launchWarmOrderURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent(launchWarmOrderFileName)
    }

    /// Starts decoding the previous launch's warmed posters in the background. Called once,
    /// from DataCoordinator.beginEarlyCacheLoads.
    func beginEarlyLaunchWarm() {
        guard earlyLaunchWarm == nil, !hasPerformedLaunchBlockingWarm,
              let folderURL = Preferences.posterImagesFolderURL,
              let orderURL = launchWarmOrderURL else { return }
        let warm = EarlyLaunchWarm()
        earlyLaunchWarm = warm
        let count = Self.launchBlockingWarmCount
        DispatchQueue.global(qos: .userInitiated).async(group: warm.group) {
            guard let data = try? Data(contentsOf: orderURL),
                  let posterUIDs = try? JSONDecoder().decode([String].self, from: data) else { return }
            warm.store(Self.loadImagesBlocking(Array(posterUIDs.prefix(count)), in: folderURL))
        }
    }

    /// Records this launch's warmed UIDs for the next launch's early warm.
    private func saveLaunchWarmOrder(_ posterUIDs: [String]) {
        guard let url = launchWarmOrderURL,
              let data = try? JSONEncoder().encode(posterUIDs) else { return }
        DispatchQueue.global(qos: .utility).async {
            do { try data.write(to: url, options: .atomic) }
            catch { Self.log("Could not save the launch warm order: \(error)") }
        }
    }

    /// Synchronous, parallel disk load and decode of `posterUIDs`, using `DispatchQueue.concurrentPerform`. Used
    /// only by the launch warm, where blocking the caller is intended. Each image goes through `loadDecodedImage(from:)`,
    /// as every other load does. Missing files yield nothing.
    private nonisolated static func loadImagesBlocking(
        _ posterUIDs: [String], in folderURL: URL
    ) -> [(String, NSImage)] {
        guard !posterUIDs.isEmpty else { return [] }
        /// The Mutex lets the compiler verify that each image is handed off rather than shared.
        let results = Mutex<[(String, NSImage)]>([])
        DispatchQueue.concurrentPerform(iterations: posterUIDs.count) { index in
            let posterUID = posterUIDs[index]
            let url = folderURL.appendingPathComponent("\(posterUID).jpg")
            guard let image = Self.loadDecodedImage(from: url) else { return }
            results.withLock { $0.append((posterUID, image)) }
        }
        return results.withLock { $0 }
    }

    /// Display-order hint set by registerLaunchDisplayOrder and read once by restoreCacheFromMetadata.
    @ObservationIgnored private var restorePriorityOrder: [String] = []

    init() { log("PosterCache initialized (metadata-first, images-progressive)") }

    // MARK: - Synchronous Access (Primary Path)
    /// Synchronous cache lookup - returns nil on cache miss.
    /// Called during scroll for immediate display; misses trigger background population.
    func getImageSync(for posterUID: String) -> NSImage? {
        return cache[posterUID]
    }

    /// Returns the cached image, or loads and decodes it from disk on a miss. Returns nil only if the file does not exist.
    ///
    /// Used by GalleryItem (via refreshTileContent) and GalleryListView. Disk I/O on the main thread is acceptable
    /// here, because the background pipeline makes misses rare during normal scrolling.
    ///
    /// Loads through `loadDecodedImage(from:)`, not `NSImage(contentsOf:)`. The latter defers JPEG decoding to the
    /// first draw, which would happen on the main thread mid-scroll.
    func getImageWithFallback(for posterUID: String) -> NSImage? {
        guard !posterUID.isEmpty else { return nil }
        
        /// Try cache first (fastest path)
        if let image = cache[posterUID] { return image }
        
        /// Cache miss — load and decode from disk
        guard let folderURL = Preferences.posterImagesFolderURL else { return nil }
        let imageURL = folderURL.appendingPathComponent("\(posterUID).jpg")
        guard let image = Self.loadDecodedImage(from: imageURL) else { return nil }
        
        /// Store the already-loaded image directly — no second disk read needed
        cache[posterUID] = image
        cachedPosterUIDs.insert(posterUID)
        
        return image
    }

    /// Cache-only lookup for drag-preview thumbnails. Returns nil for an empty UID or a miss, and never reads from disk.
    ///
    /// It is called inside a mouseDown drag-tracking loop, which runs at elevated QoS. A synchronous disk read there
    /// risks a priority inversion. The preview is cosmetic, so a missing poster is acceptable.
    func dragPreviewImage(for posterUID: String) -> NSImage? {
        guard !posterUID.isEmpty else { return nil }
        return getImageSync(for: posterUID)
    }

    // MARK: - Asynchronous Access
    /// Asynchronous image retrieval with cache population on miss.
    /// Primarily used for prefetching and background population.
    func getImageAsync(for posterUID: String) async -> NSImage? {
        if let cached = cache[posterUID] {
            /// Counters are updated only when logging is on.
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
    /// STARTUP: disk I/O and JSON decoding run on a background task, in parallel with other startup work.
    func loadMetadata() async {
        /// Load once. A repeat call would overwrite UIDs added since the first load.
        guard !isMetadataLoaded else {
            log("Poster cache metadata already loaded — skipping")
            return
        }

        /// Timed for the startup breakdown log.
        let loadStart = ContinuousClock.now

        guard let url = cacheMetadataURL else {
            log("Cache metadata URL not available")
            isMetadataLoaded = true
            /// UI can proceed even with no metadata
            isReady = true
            return
        }

        /// Check existence through the URL resource API.
        let exists = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard exists else {
            log("No cache metadata found at \(url.lastPathComponent) - starting with empty cache")
            isMetadataLoaded = true
            /// UI can proceed with empty cache
            isReady = true
            return
        }

        /// Read and decode off the main actor.
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
        /// Images then load progressively.
        isReady = true
    }

    // MARK: - Background Image Restoration
    /// Restores images from disk into memory cache.
    /// Called after UI is responsive - this is background work.
    /// Images that aren't restored here will load on-demand when viewed.
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

        /// Yield once, so the first SwiftUI render can register the display order before the snapshot is taken.
        await Task.yield()

        let startTime = Date()

        /// Display-ordered restore. Launch-view posters load first, in grid order. The first `restoreHeadCount`
        /// load at `.userInitiated`, and the rest at `.utility`.
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

        /// Adaptive batch size based on total count
        let batchSize = min(30, max(10, totalCount / 20))
        var loadedCount = 0

        /// Each UID ends in one of three outcomes: already resident, loaded, or failed. The three sum to `totalCount`,
        /// which the completion log checks.
        var alreadyResidentCount = 0
        var failedCount = 0

        /// Progress is logged when the count crosses a milestone. An exact-equality check would miss most batches.
        let progressInterval = 200
        var nextProgressMilestone = progressInterval
        var loggedResidentCoverage = false

        /// Offset of the current batch's first UID, used to choose its load priority.
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

            /// Resident UIDs are filtered out here, on MainActor, so no task is spawned for them. This runs per batch.
            let pending = batch.filter { cache[$0] == nil }
            alreadyResidentCount += batch.count - pending.count

            if !pending.isEmpty {
                let batchResults = await withTaskGroup(of: (String, DecodedPoster)?.self) { group in
                    for posterUID in pending {
                        /// PosterCache.shared is a singleton — no [weak self] needed.
                        /// loadImage is nonisolated and does not access MainActor state.
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

                /// A pending UID with no image is a read failure.
                failedCount += pending.count - batchResults.count
            }

            /// Advance the milestone past the current count.
            if loadedCount >= nextProgressMilestone {
                log("Restored \(loadedCount)/\(totalCount) posters")
                nextProgressMilestone =
                    ((loadedCount / progressInterval) + 1) * progressInterval
            }

            /// Logged once: the number of already-resident posters before the first disk load. The cause is not
            /// attributed, because the pre-paint warm is the usual explanation, not the only one.
            if !loggedResidentCoverage, loadedCount > 0 {
                loggedResidentCoverage = true
                if alreadyResidentCount > 0 {
                    log("Restore skipped \(alreadyResidentCount) already-resident poster(s) "
                        + "before its first disk load (typically the launch pre-paint warm)")
                }
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        /// The three outcomes are reported together. They must sum to totalCount.
        log("Cache restoration complete: \(loadedCount) loaded, "
            + "\(alreadyResidentCount) already resident, \(failedCount) failed "
            + "— \(loadedCount + alreadyResidentCount)/\(totalCount) resident "
            + "in \(Fmt.fixed(duration, 2))s")

        /// Remove UIDs whose files failed to load, for example because they were deleted externally. Otherwise
        /// completeCache() would skip them, and they would never reload.
        let loadedKeys = Set(cache.keys)
        let staleUIDs = cachedPosterUIDs.subtracting(loadedKeys)
        if !staleUIDs.isEmpty {
            cachedPosterUIDs.subtract(staleUIDs)
            log("Removed \(staleUIDs.count) stale UID(s) from poster cache metadata (files missing on disk)")
            saveMetadataThrottled()
        }
    }

    /// Number of leading display-order UIDs the restore loads at `.userInitiated`. Sized to cover the initial
    /// viewport and the first stretch of scrolling.
    private static let restoreHeadCount = 600

    // MARK: - Warming-Window Prefetch Ingestion
    ///
    /// Background load and commit for a scroll-driven look-ahead band. Called by GallerySubview's warming-scoped
    /// prefetch while `isPopulating` is true. Loads at `.userInitiated`, above the restore's tail phase. No metadata
    /// save is needed, because every UID here is already on disk.
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
        /// Safety check - don't start if metadata isn't ready
        guard isReady else {
            log("Cannot complete cache: Metadata not ready")
            return
        }
        
        /// Deduplicate. Films can share a poster UID, and addPosters snapshots the cache once, so duplicates would
        /// load twice.
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
    /// Encoding and writing run on a background task, so the main thread does not block on the write.
    func saveMetadata() async {
        /// Before loadMetadata() the set says nothing about the posters on disk; writing it
        /// (a quit during launch) replaced the file with an empty list.
        guard isMetadataLoaded else {
            log("Cache metadata save skipped: not loaded yet")
            return
        }
        guard let url = cacheMetadataURL else {
            log("Cannot save cache metadata: URL not available")
            return
        }

        /// Capture a value-type copy before leaving MainActor so the detached task has no
        /// access to shared mutable state.
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

        /// Snapshot cache state once on MainActor — avoids ~N MainActor hops inside TaskGroup
        let alreadyCached = cachedPosterUIDs

        for batch in validUIDs.chunked(into: batchSize) {
            guard !Task.isCancelled else {
                log("Batch poster addition canceled after \(addedCount) images")
                return
            }

            let batchResults = await withTaskGroup(of: (String, DecodedPoster)?.self) { group in
                for posterUID in batch {
                    /// PosterCache.shared is a singleton — no [weak self] needed.
                    /// loadImage is nonisolated and does not access MainActor state.
                    group.addTask {
                        /// Check local snapshot — no MainActor hop needed
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
    /// Clears in-memory images while preserving metadata on disk.
    /// Use for memory pressure situations - images will reload on demand.
    func clearMemory() {
        let count = cache.count
        cache.removeAll()
        cacheHits = 0
        cacheMisses = 0
        /// NOTE: Don't reset isReady - metadata is still valid on disk
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

    /// - Parameter priority: priority of the detached disk read and decode. Restore tail batches pass `.utility`.
    private nonisolated func loadImage(posterUID: String,
                                       priority: TaskPriority = .userInitiated) async -> DecodedPoster? {
        guard let folderURL = Preferences.posterImagesFolderURL else { return nil }

        /// Decoding happens off the main thread, so every image entering the cache is already decoded.
        let imageURL = folderURL.appendingPathComponent("\(posterUID).jpg")
        return await Task.detached(priority: priority) {
            Self.loadDecodedImage(from: imageURL).map(DecodedPoster.init)
        }.value
    }

    // MARK: - Decoded Loading
    ///
    /// The shared load-and-decode primitive for every disk read in this cache. It decodes the full bitmap on the
    /// calling thread, so drawing is a plain composite.

    /// Loads a single poster, fully decoded. Returns nil if the file is missing or cannot be decoded. Safe from any
    /// concurrency context. Internal, so FSTabPoster's preview decodes the same way.
    nonisolated static func loadDecodedImage(from url: URL) -> NSImage? {
        /// Check existence first. CGImageSource logs an error for a missing file, and missing posters are expected.
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

    /// Queue for all poster decodes. ImageIO takes a process-wide lock, so a low-priority decode could stall a
    /// high-priority one. Routing every decode through one `.userInitiated` queue avoids that inversion. The queue is
    /// concurrent, so the population batches keep their own parallelism.
    ///
    /// `nonisolated` is required because PosterCache is `@MainActor`. The queue is an immutable, thread-safe `let`.
    private nonisolated static let posterDecodeQueue = DispatchQueue(
        label: "com.filmtracker.poster-decode",
        qos: .userInitiated,
        attributes: .concurrent)
}

// MARK: - Cache Metadata
private struct CacheMetadata: Codable { let posterUIDs: [String] }

/// The early launch warm's background results, handed to the main actor once.
private final class EarlyLaunchWarm: Sendable {
    let group = DispatchGroup()
    private let decoded = Mutex<[String: DecodedPoster]>([:])

    func store(_ images: [(String, NSImage)]) {
        let posters = images.map { ($0.0, DecodedPoster(image: $0.1)) }
        decoded.withLock { $0 = Dictionary(posters, uniquingKeysWith: { first, _ in first }) }
    }

    func take() -> [String: DecodedPoster] {
        decoded.withLock { taken in defer { taken = [:] }; return taken }
    }
}
