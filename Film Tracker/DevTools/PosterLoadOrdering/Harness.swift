// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Standalone models for the poster-load ordering harness. No SwiftUI, no AppKit,
// no Xcode target — see README.md.
//
// WHAT IS Modeled
// ────────────────
// `Header.loadImageFromCache(_:)` (24_11_Header.swift), in both its OLD and NEW
// forms, against a poster cache whose completions can be resumed in any order the
// test chooses. Everything irrelevant to ordering is stripped: an "image" is just
// the UID it was loaded for, so a wrong image is directly observable.
//
// THE ONE Modeling DECISION THAT MATTERS
// ───────────────────────────────────────
// The OLD code's staleness guard re-read an `@Environment` value from inside an
// escaping closure:
//
//     Task {
//         let image = await PosterCache.shared.getImageAsync(for: uid)
//         guard film?.posterUID == uid else { return }   // ← this read
//         ...
//     }
//
// A closure captures a COPY of the `View` struct, so what that read returns is not
// specified by SwiftUI. The two readings are:
//
//   • .capturedSnapshot — the copy carries the environment as it stood when the
//     closure was formed, so the guard compares `uid` against the value it was
//     already equal to and can never fail. (This is the behavior the property
//     wrapper's storage implies, and the reading the audit assumed.)
//   • .liveRead        — the read somehow observes the current environment, so the
//     guard does reject a superseded load.
//
// Rather than assert which one SwiftUI implements, the harness runs the OLD model
// under BOTH and reports what each yields. The point it proves is that the NEW
// model is correct under both — it depends only on `@State`, whose semantics in an
// escaping closure are defined — while the OLD model's correctness is contingent on
// a reading nobody guaranteed.
enum EnvironmentSemantics: String, CaseIterable {
    case capturedSnapshot = "captured-snapshot"
    case liveRead = "live-read"
}

// MARK: - Stub Poster Cache

/// Stands in for `PosterCache`. `getImageSync` answers only from the in-memory
/// dictionary (as the real one does); `getImageAsync` suspends until the test
/// explicitly releases that UID, which is what makes completion order controllable
/// without sleeping on a wall clock.
@MainActor
final class StubPosterCache {
    /// UIDs whose "image" is already resident, answered synchronously.
    var resident: Set<String> = []

    /// UIDs present on "disk" — an async load for one of these eventually yields an
    /// image; anything else yields nil, mirroring "file genuinely not present".
    var onDisk: Set<String> = []

    /// Suspended loads, keyed by UID, awaiting `release(_:)`.
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    /// Every async load started, in order — lets a test assert that an obsolete
    /// load was never begun, or was begun and then abandoned.
    private(set) var asyncLoadsStarted: [String] = []

    func getImageSync(for uid: String) -> String? {
        resident.contains(uid) ? uid : nil
    }

    func getImageAsync(for uid: String) async -> String? {
        asyncLoadsStarted.append(uid)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pending[uid] = c
        }
        guard onDisk.contains(uid) else { return nil }
        resident.insert(uid)
        return uid
    }

    /// True once a load for `uid` has suspended and is waiting to be released.
    func isSuspended(_ uid: String) -> Bool { pending[uid] != nil }

    /// Lets the suspended load for `uid` finish. Completion order across several
    /// suspended loads is exactly the order these calls are made in.
    func release(_ uid: String) {
        guard let c = pending.removeValue(forKey: uid) else { return }
        c.resume()
    }

    func reset() {
        resident = []
        onDisk = []
        pending = [:]
        asyncLoadsStarted = []
    }
}

// MARK: - Header Model

/// The two implementations of `Header`'s poster loading, sharing one set of stored
/// properties so a test can drive either against identical inputs.
///
/// `environmentPosterUID` stands in for `film?.posterUID`. The caller sets it before
/// each request, exactly as a new film selection would.
@MainActor
final class HeaderModel {

    enum Implementation { case old, new }

    let implementation: Implementation
    let environmentSemantics: EnvironmentSemantics
    let cache: StubPosterCache

    /// Stand-in for the environment film's poster UID.
    var environmentPosterUID: String?

    // Shared state, present in both implementations.
    var displayedImage: String?
    var lastLoadedPosterUID: String?

    // NEW-only state.
    var requestedPosterUID: String?
    var posterLoadTask: Task<Void, Never>?

    /// Every value `displayedImage` has ever been set to, in order. The ordering bug
    /// is visible here as a trailing write of a superseded UID.
    private(set) var displayHistory: [String?] = []

    init(implementation: Implementation,
         environmentSemantics: EnvironmentSemantics = .capturedSnapshot,
         cache: StubPosterCache) {
        self.implementation = implementation
        self.environmentSemantics = environmentSemantics
        self.cache = cache
    }

    private func publish(_ image: String?, for uid: String) {
        displayedImage = image
        displayHistory.append(image)
        lastLoadedPosterUID = uid
    }

    // MARK: OLD

    /// Verbatim structure of the shipped implementation before the fix: no request
    /// record, no cancellation, and a guard that re-reads the environment.
    private func loadOld(_ posterUID: String?) {
        guard let uid = posterUID, !uid.isEmpty else {
            displayedImage = nil
            displayHistory.append(nil)
            lastLoadedPosterUID = nil
            return
        }
        if lastLoadedPosterUID == uid && displayedImage != nil { return }
        if let cached = cache.getImageSync(for: uid) {
            publish(cached, for: uid)
            return
        }
        // The closure captures a copy of the view struct; `capturedEnvironmentUID`
        // is that copy's view of the environment, frozen here.
        let capturedEnvironmentUID = environmentPosterUID
        Task { @MainActor in
            let image = await self.cache.getImageAsync(for: uid)
            let observed: String? = switch self.environmentSemantics {
            case .capturedSnapshot: capturedEnvironmentUID
            case .liveRead: self.environmentPosterUID
            }
            guard observed == uid else { return }
            self.publish(image, for: uid)
        }
    }

    // MARK: NEW

    /// The fixed implementation: the request is recorded in state before any
    /// suspension, the previous load is canceled unconditionally, and the
    /// completion checks that recorded request rather than the environment.
    private func loadNew(_ posterUID: String?) {
        posterLoadTask?.cancel()
        posterLoadTask = nil

        guard let uid = posterUID, !uid.isEmpty else {
            requestedPosterUID = nil
            displayedImage = nil
            displayHistory.append(nil)
            lastLoadedPosterUID = nil
            return
        }

        requestedPosterUID = uid

        if lastLoadedPosterUID == uid && displayedImage != nil { return }
        if let cached = cache.getImageSync(for: uid) {
            publish(cached, for: uid)
            return
        }
        posterLoadTask = Task { @MainActor in
            let image = await self.cache.getImageAsync(for: uid)
            guard !Task.isCancelled, self.requestedPosterUID == uid else { return }
            self.publish(image, for: uid)
            self.posterLoadTask = nil
        }
    }

    /// Issues one request, mirroring a film change: the environment moves first,
    /// then the loader is invoked with the new UID.
    func request(_ posterUID: String?) {
        environmentPosterUID = posterUID
        switch implementation {
        case .old: loadOld(posterUID)
        case .new: loadNew(posterUID)
        }
    }
}

// MARK: - Scheduling Helper

/// Yields enough times for every continuation resumed so far to have run its
/// remaining body on the main actor. The harness never sleeps on a wall clock —
/// ordering here comes from `StubPosterCache.release(_:)` alone.
@MainActor
func settle(_ turns: Int = 24) async {
    for _ in 0..<turns { await Task.yield() }
}
