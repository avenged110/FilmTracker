// MARK: - ATVQIntegration.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Dispatches the "Up Next" Queue to ATVQ, the companion tvOS app, and to the ATVQ Deployer's
// relay. Everything ATVQ-related in Film Tracker lives here; the rest of the app only
// mounts ATVQDispatchButton (GalleryTitleBar), ATVQTestRelayButton (STabAdvanced), and
// stores the `Preferences.atvq` switch that gates all of it.
//
// Wire protocol (shared with ATVQ's QueuePayload.swift and the Deployer's Relay.swift):
//   Bonjour `_atvq._tcp` (ATVQ itself) and `_atvqrelay._tcp` (the Deployer's relay, which
//   holds the newest queue and hands it to ATVQ when the Apple TV wakes). Both are servers;
//   Film Tracker is only ever a client, so it needs no incoming-connection entitlement.
//   request:  4-byte big-endian length, then JSON {version, dispatchedAt, films[…]}
//   response: 4-byte big-endian length, then JSON {ok, error?}
// A dispatch goes to the relay and to ATVQ itself at the same time, and succeeds as soon as
// either accepts it. The relay always gets a copy: ATVQ polls it for as long as it's on
// screen, so whatever the relay holds reaches the Apple TV within seconds of ATVQ being
// open, and an ATVQ that answers directly just shows it sooner. ATVQ keeps whichever copy
// is newest by `dispatchedAt`, so a queue arriving twice is harmless.
//
// Local Network privacy (TCC): macOS asks the first time the app browses the local
// network. Nothing here browses until the preference is on AND the user has dispatched
// once, so turning the preference on never prompts by itself. After that first request,
// a pair of Bonjour browsers stays up while the preference is on: they keep the endpoints
// current and are how the permission is observed, since macOS offers no API to read it.
// A browser can report `.ready` while macOS still refuses every connection, and a Bonjour
// connection that is refused never says so (it just stays in `.preparing`), so access is
// settled by localNetworkDenied(), which asks for a path to the router directly. That check
// and the relay test only ever run because the user acted: a dispatch, or Settings' "Test
// Relay Connection" (including the relay browser becoming ready while one of those runs).
// Nothing probes at launch or in the background. The browsers
// are rebuilt whenever Film Tracker becomes active (the user returning from System
// Settings), so a change made there is picked up at once.

import AppKit
import Network
import Synchronization
import SwiftUI
import UserNotifications

// MARK: - Wire Format

/// Mirrors ATVQ's QueuePayload. Text arrives display-ready: ATVQ formats nothing itself.
private struct ATVQPayload: Encodable {
    static let currentVersion = 1
    let version = currentVersion
    let dispatchedAt: Date
    let films: [ATVQFilm]
}

private struct ATVQFilm: Encodable {
    let id: UUID
    let title: String
    let year: String
    let genre: String
    let rating: String
    let duration: String          // "2 hr 16 min"
    let runtimeMinutes: Int?      // drives ATVQ's "will end around …"
    let source: String            // the sidebar's "Source for Viewing" value
    let lastWatched: String       // the sidebar's "Last Watched" value; empty if never
    let synopsis: String
    let directors: [String]
    let screenwriters: [String]
    let cast: [String]
    let producers: [String]
    let composers: [String]
    var poster: Data?             // JPEG, base64 in JSON
}

private struct ATVQReply: Decodable {
    let ok: Bool
    let error: String?
}

// MARK: - Client

@MainActor
@Observable
final class ATVQClient: Loggable {
    nonisolated static let logTag = "[ATVQ]"

    static let shared = ATVQClient()

    enum Access: Equatable {
        /// Never requested: the first dispatch will prompt.
        case notDetermined
        /// Requested; waiting for the user to answer the prompt.
        case pending
        case granted
        case denied
    }

    enum Failure: Equatable {
        case denied
        case notFound
        case rejected([String])
        /// Every recipient was tried and none answered; one line per recipient saying why.
        case unreachable([String])
        /// The preference was turned off (or a dispatch was already running): nothing to say.
        case cancelled

        var message: String {
            switch self {
            case .denied:
                return "macOS is blocking Film Tracker from your local network, so it can't reach ATVQ or the ATVQ Deployer. Open System Settings › Privacy & Security › Local Network and turn on Film Tracker — if it's already on, turn it off and back on — then try again."
            case .notFound:
                return "Film Tracker couldn't find ATVQ on your Apple TV, or the ATVQ Deployer on another Mac. Make sure ATVQ is open on your Apple TV (or the ATVQ Deployer is running), and that it's on the same network as this Mac, then try again."
            case .rejected(let reasons):
                return "ATVQ couldn't accept your \"Up Next\" Queue: \(reasons.joined(separator: "; "))."
            case .cancelled:
                return ""
            case .unreachable(let details):
                return "Film Tracker couldn't deliver your \"Up Next\" Queue to ATVQ or to the ATVQ Deployer's relay. Make sure the ATVQ Deployer is running on its Mac (or ATVQ is open on your Apple TV), then try again.\n\n" + details.joined(separator: "\n")
            }
        }
    }

    private(set) var access: Access = .notDetermined
    private(set) var isDispatching = false

    private static let serviceTypes = [directType, relayType]
    /// Internal state, not a preference: whether the Local Network prompt has been asked
    /// for. Lives beside the preferences (Preferences.store) but is not backed up — a
    /// restored backup must not suppress the prompt on a Mac that never showed it.
    private static let requestedKey = "atvq.localNetworkRequested"
    /// kDNSServiceErr_PolicyDenied: the Local Network permission is off.
    private nonisolated static let policyDenied: Int32 = -65570

    @ObservationIgnored private var browsers: [String: NWBrowser] = [:]
    @ObservationIgnored private var endpoints: [String: [NWEndpoint]] = [:]
    @ObservationIgnored private var requestedAt: Date?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var preferenceObserver: (any NSObjectProtocol)?

    /// When a dispatch from this Mac last reached a recipient, for the title-bar button's
    /// tooltip. Internal state like `requestedKey`, and likewise not backed up: it describes
    /// this Mac's dispatches, not the library.
    private static let lastDeliveredKey = "atvq.lastDelivered"
    private(set) var lastDelivered: Date? = Preferences.store.object(forKey: lastDeliveredKey) as? Date

    func noteDelivered() {
        let now = Date()
        lastDelivered = now
        Preferences.store.set(now, forKey: Self.lastDeliveredKey)
    }

    private var hasRequested: Bool {
        get { Preferences.store.bool(forKey: Self.requestedKey) }
        set { Preferences.store.set(newValue, forKey: Self.requestedKey) }
    }

    private init() {
        access = hasRequested ? .pending : .notDetermined
        // The preference is the master switch: follow it wherever it is changed (Settings,
        // a restore).
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Preferences.store, queue: .main) { _ in
            MainActor.assumeIsolated { ATVQClient.shared.syncWithPreference() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ATVQClient.shared.recheck() }
        }
        syncWithPreference()
    }

    /// Starts or stops browsing to match the preference. Browsing waits for the first
    /// dispatch, which is what asks for Local Network access.
    func syncWithPreference() {
        if Preferences.atvq && hasRequested {
            if browsers.isEmpty { startBrowsing() }
        } else if !browsers.isEmpty || !Preferences.atvq {
            stopBrowsing()
            if !hasRequested { access = .notDetermined }
        }
    }

    /// Rebuilds the browsers so a permission change made in System Settings is seen now.
    /// The Local Network prompt is a system dialog, so coming back active after asking also
    /// means it was answered: a refusal from then on is final rather than "still asking".
    private func recheck() {
        guard Preferences.atvq, hasRequested else { return }
        if let requestedAt, Date().timeIntervalSince(requestedAt) > 1 { self.requestedAt = nil }
        stopBrowsing()
        startBrowsing()
    }

    private func startBrowsing() {
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.browser(type, changedTo: state) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.found(results, of: type) }
            }
            browsers[type] = browser
            browser.start(queue: .main)
        }
        log("Browsing for ATVQ")
    }

    private func stopBrowsing() {
        for browser in browsers.values {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers.removeAll()
        endpoints.removeAll()
    }

    private func browser(_ type: String, changedTo state: NWBrowser.State) {
        guard browsers[type] != nil else { return }
        switch state {
        case .ready:
            // Browsing works even while connections are refused, so a ready browser only
            // prompts the real check — and only while a dispatch or relay test is running,
            // since the first of either waits here for the Local Network prompt's answer.
            // With neither running, the check is left to the next one.
            if type == Self.relayType, isDispatching || isTestingRelay { refreshAccess() }
        case .waiting(let error) where Self.isPolicyDenied(error):
            // While the prompt is still up the browser reports a refusal too; the answer is
            // only final once the prompt has had time to be answered.
            if let requestedAt, Date().timeIntervalSince(requestedAt) < 60 {
                setAccess(.pending)
            } else {
                setAccess(.denied)
            }
            endpoints[type] = []
        case .failed(let error):
            log("Browser for \(type) failed: \(error); restarting")
            if Self.isPolicyDenied(error) { setAccess(.denied) }
            browsers[type]?.cancel()
            browsers[type] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.browsers[type] == nil, Preferences.atvq, self.hasRequested else { return }
                self.stopBrowsing()
                self.startBrowsing()
            }
        default:
            break
        }
    }

    @ObservationIgnored private var isRefreshingAccess = false

    /// Settles `access` from localNetworkDenied(). A refusal while the prompt may still be
    /// up (see browser(_:changedTo:)) counts as still asking.
    private func refreshAccess() {
        guard !isRefreshingAccess else { return }
        isRefreshingAccess = true
        Task {
            let denied = await Self.localNetworkDenied()
            isRefreshingAccess = false
            if denied, let requestedAt, Date().timeIntervalSince(requestedAt) < 60 {
                setAccess(.pending)
            } else {
                setAccess(denied ? .denied : .granted)
            }
        }
    }

    private func setAccess(_ newValue: Access) {
        guard access != newValue else { return }
        log("Local Network access: \(newValue)")
        access = newValue
        if newValue != .pending { requestedAt = nil }
    }

    private nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDenied }
        return false
    }

    // MARK: Dispatch

    /// Sends the "Up Next" Queue to the Deployer's relay and to every ATVQ found, all at
    /// once. Asks for Local Network access first if it never has been. Returns nil as soon as
    /// any recipient accepts the queue; the others finish by themselves.
    ///
    /// The relay always gets it, even when ATVQ answers too: ATVQ polls the relay while it's
    /// on screen, so the relay holding the newest queue is what makes delivery dependable.
    func dispatch(coordinator: DataCoordinator) async -> Failure? {
        guard Preferences.atvq, !isDispatching else { return .cancelled }
        isDispatching = true
        defer { isDispatching = false }

        if !hasRequested {
            hasRequested = true
            requestedAt = Date()
            access = .pending
            log("Requesting Local Network access")
        }
        if browsers.isEmpty { startBrowsing() }

        // Only a dispatch that just asked for access waits — for the prompt to be answered
        // (60 s, the window in browser(_:changedTo:)). Otherwise the connections themselves
        // are the test: a browser's report is only a hint, and a momentary refusal from one
        // must not stop a dispatch before anything is even tried.
        if requestedAt != nil {
            let deadline = Date().addingTimeInterval(60)
            while access == .pending, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard Preferences.atvq else { return .cancelled }
            }
            if access == .pending { setAccess(.denied) }
            if access == .denied { return .denied }
        }

        // Discovery usually answers within a second of the browsers (re)starting — they're
        // rebuilt whenever Film Tracker becomes active. A relay seen before is tried by name
        // regardless, so a slow browser never decides the outcome.
        let started = Date()
        while Date().timeIntervalSince(started) < 3 {
            let relayFound = !endpoints(for: Self.relayType).isEmpty
            let directFound = !endpoints(for: Self.directType).isEmpty
            if relayFound, directFound || Date().timeIntervalSince(started) > 1 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let targets = targets()
        guard !targets.isEmpty else {
            log("Dispatch: neither ATVQ (_atvq._tcp) nor a relay (_atvqrelay._tcp) is advertised")
            return await settledNothingFound() ? .denied : .notFound
        }

        let films = Self.upNextFilms(coordinator: coordinator)
        guard let folder = Preferences.posterImagesFolderURL else {
            return .unreachable(["Film Tracker couldn't locate its poster images folder."])
        }
        let body: Data
        do {
            body = try await Self.encode(films, posterFolder: folder)
        } catch {
            log("ERROR: Couldn't encode the payload: \(error)")
            return .unreachable(["Film Tracker couldn't prepare the queue: \(error.localizedDescription)"])
        }
        log("Dispatching \(films.count) film(s), \(body.count / 1024) KB, to \(targets.map(\.label).joined(separator: ", "))")

        let result = await Self.deliver(body, to: targets)
        if let accepted = result.accepted {
            log("Dispatch accepted by \(accepted)")
            // A delivery proves access, whatever a browser last reported.
            setAccess(.granted)
            return nil
        }

        for attempt in result.attempts { log("Dispatch to \(attempt.label) failed: \(attempt.summary)") }
        if result.attempts.contains(where: \.denied) {
            setAccess(.denied)
            return .denied
        }
        // Nobody answered at all: check whether macOS is refusing local network access,
        // which it never reports on a Bonjour connection (see localNetworkDenied()).
        if result.attempts.allSatisfy({ $0.reply == nil }), await Self.localNetworkDenied() {
            log("Dispatch: macOS reports Local Network access denied")
            setAccess(.denied)
            return .denied
        }
        let rejections = result.attempts.compactMap { attempt -> String? in
            guard let reply = attempt.reply, !reply.ok else { return nil }
            return reply.error ?? "unknown error"
        }
        if !rejections.isEmpty { return .rejected(rejections) }
        return .unreachable(result.attempts.map { "\($0.label.prefix(1).uppercased())\($0.label.dropFirst()): \($0.summary)" })
    }

    /// Who to send to: every relay and ATVQ being advertised, plus relays seen before (by
    /// name — resolved afresh when connecting). ATVQs are only ever tried while advertised:
    /// connecting to a sleeping Apple TV by name can wake it, and the TV with it.
    private func targets() -> [Target] {
        Self.serviceTypes.flatMap { type -> [Target] in
            let isRelay = type == Self.relayType
            var byName: [String: NWEndpoint] = [:]
            if isRelay {
                for name in knownRelays { byName[name] = .service(name: name, type: type, domain: "local.", interface: nil) }
            }
            for endpoint in endpoints(for: type) {
                guard case .service(let name, _, _, _) = endpoint else { continue }
                byName[name] = endpoint
            }
            return byName.sorted { $0.key < $1.key }.map { name, endpoint in
                Target(endpoint: endpoint, label: isRelay ? "the relay on \(name)" : "ATVQ on \(name)", isRelay: isRelay)
            }
        }
    }

    /// Relays seen on the network, newest first; internal state like `requestedKey`.
    private static let knownRelaysKey = "atvq.knownRelays"

    private var knownRelays: [String] {
        get { Preferences.store.stringArray(forKey: Self.knownRelaysKey) ?? [] }
        set { Preferences.store.set(Array(newValue.prefix(3)), forKey: Self.knownRelaysKey) }
    }

    private func found(_ results: Set<NWBrowser.Result>, of type: String) {
        endpoints[type] = results.map(\.endpoint)
        guard type == Self.relayType else { return }
        let names = results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint { return name }
            return nil
        }
        let known = knownRelays
        guard !names.isEmpty, names != Array(known.prefix(names.count)) else { return }
        knownRelays = names + known.filter { !names.contains($0) }
    }

    private func waitForRelays(seconds: TimeInterval) async -> [NWEndpoint] {
        let deadline = Date().addingTimeInterval(seconds)
        while endpoints(for: Self.relayType).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return endpoints(for: Self.relayType)
    }

    // MARK: Relay Self-Test

    enum RelayTestResult: Equatable {
        case received
        /// No `_atvqrelay._tcp` advertisement: the Deployer isn't running, or macOS refused
        /// to publish its service.
        case notAdvertised
        /// Advertised, but no reply came back.
        case noReply
        case denied
        case cancelled

        var message: String {
            switch self {
            case .received: "The ATVQ Deployer's relay received Film Tracker's test dispatch."
            case .notAdvertised: "Film Tracker couldn't find the ATVQ Deployer's relay on your network. Make sure the Deployer is running and has Local Network access on its Mac."
            case .noReply: "Film Tracker found the ATVQ Deployer's relay, but it didn't acknowledge a test dispatch."
            case .denied: Failure.denied.message
            case .cancelled: ""
            }
        }
    }

    private(set) var isTestingRelay = false

    /// Whether finding nothing on the network is down to macOS refusing access. A recorded
    /// refusal is confirmed rather than trusted: nothing re-checks access in the background,
    /// so one recorded before the user turned access back on would otherwise stay, and a
    /// dispatch or test that simply found nothing would be blamed on it. Only ever runs
    /// inside a dispatch or relay test the user started.
    private func settledNothingFound() async -> Bool {
        guard access == .denied else { return false }
        let denied = await Self.localNetworkDenied()
        if !denied { setAccess(.granted) }
        return denied
    }

    /// Sends a `{"ping":true}` frame to every relay found and waits for any framed reply,
    /// which proves the relay received it; nothing is stored. A Deployer predating ping
    /// answers "Not a queue payload", which still counts as received.
    func testRelay() async -> RelayTestResult {
        guard Preferences.atvq, !isTestingRelay else { return .cancelled }
        isTestingRelay = true
        defer { isTestingRelay = false }
        if !hasRequested {
            hasRequested = true
            requestedAt = Date()
            access = .pending
        }
        if browsers.isEmpty { startBrowsing() }
        // As in dispatch(): only a test that just asked for access waits on the prompt.
        if requestedAt != nil {
            let deadline = Date().addingTimeInterval(60)
            while access == .pending, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard Preferences.atvq else { return .cancelled }
            }
            if access == .pending { setAccess(.denied) }
            if access == .denied { return .denied }
        }

        let relays = await waitForRelays(seconds: 5)
        guard !relays.isEmpty else {
            log("Relay test: no _atvqrelay._tcp service advertised")
            return await settledNothingFound() ? .denied : .notAdvertised
        }
        let ping = Data(#"{"ping":true}"#.utf8)
        let received = await withTaskGroup(of: Bool.self) { group in
            for endpoint in relays {
                group.addTask {
                    // Any framed reply proves receipt (see above).
                    let attempt = await Self.send(ping, to: endpoint, label: "the relay", timeout: 6)
                    return attempt.reply != nil
                }
            }
            for await ok in group where ok { group.cancelAll(); return true }
            return false
        }
        log("Relay test: \(received ? "received" : "no reply") from \(relays.count) relay(s)")
        if !received, await Self.localNetworkDenied() {
            setAccess(.denied)
            return .denied
        }
        return received ? .received : .noReply
    }

    /// Runs the self-test on request (Settings) and posts a non-blocking system notification
    /// with the result.
    func runRelayTest() {
        Task {
            let result = await testRelay()
            guard result != .cancelled else { return }
            Self.notify(title: result == .received ? "ATVQ Relay Test Passed" : "ATVQ Relay Test Failed",
                        body: result.message)
        }
    }

    /// Async throughout, on the main actor: the completion-handler API would capture the
    /// non-Sendable notification center in a @Sendable closure.
    private static func notify(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: relayTestNotificationID, content: content, trigger: nil))
        }
    }

    /// The relay test's notification. ReleaseNotifications' presenter lets it show as a
    /// banner while Film Tracker is frontmost, which it always is when the test is run.
    nonisolated static let relayTestNotificationID = "atvq.relayTest"

    private static let directType = "_atvq._tcp"
    private static let relayType = "_atvqrelay._tcp"

    private func endpoints(for type: String) -> [NWEndpoint] { endpoints[type] ?? [] }

    // MARK: Payload

    /// "Up Next", in the order the Queue's "All" tab shows it, capped at ATVQ's eight slots.
    private static func upNextFilms(coordinator: DataCoordinator) -> [FilmSnapshot] {
        let ids = Array(FilmQueue.upNextFilmIDs(coordinator: coordinator))
        let state = ViewStateManager.shared.filmQueueAllTabState()
        let ordered = MetadataCache.shared.sort(ids, by: state.effectiveSortOption(in: .filmQueue),
                                                direction: state.sortDirection)
        return ordered.prefix(FilmQueue.upNextCapacity).compactMap { coordinator.getFilm($0) }
    }

    /// Builds the JSON body. Text is formatted here, on the main actor, with the same
    /// helpers the sidebar uses; poster files are read and the JSON encoded off it.
    private static func encode(_ films: [FilmSnapshot], posterFolder: URL) async throws -> Data {
        let entries: [(ATVQFilm, URL?)] = films.map { film in
            let minutes = (Double(film.effectiveDuration) ?? 0) / 60_000
            let runtime = minutes > 0 && minutes < 1e9 ? Int(minutes.rounded()) : nil
            let entry = ATVQFilm(
                id: film.id, title: film.name, year: film.releaseYear, genre: film.genre,
                rating: film.rating, duration: runtime.map(durationText) ?? "",
                runtimeMinutes: runtime,
                source: RSBHelpers.sourceDisplay(for: film).value,
                lastWatched: film.lastWatched.isEmpty ? "" : formatDateWithTimeAgo(film.lastWatched),
                synopsis: film.descriptionText, directors: film.directors,
                screenwriters: film.screenwriters, cast: film.cast,
                producers: film.producers, composers: film.composer, poster: nil)
            let poster = film.posterUID.isEmpty ? nil
                : posterFolder.appendingPathComponent("\(film.posterUID).jpg")
            return (entry, poster)
        }
        let dispatchedAt = Date()
        return try await Task.detached(priority: .userInitiated) {
            let films = entries.map { entry, url -> ATVQFilm in
                var film = entry
                film.poster = url.flatMap { try? Data(contentsOf: $0) }
                return film
            }
            let encoder = JSONEncoder()
            // Fractional seconds: ATVQ orders dispatches by this, and two can share a second.
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            }
            return try encoder.encode(ATVQPayload(dispatchedAt: dispatchedAt, films: films))
        }.value
    }

    private static func durationText(_ minutes: Int) -> String {
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    // MARK: Transport

    private struct Target: Sendable {
        let endpoint: NWEndpoint
        let label: String
        let isRelay: Bool
    }

    /// One recipient's result: its reply, or why there wasn't one.
    private struct Attempt: Sendable {
        let label: String
        var reply: ATVQReply?
        var problem: String?
        var denied = false

        var summary: String {
            if let reply { return reply.ok ? "accepted" : "rejected: \(reply.error ?? "unknown error")" }
            return problem ?? "no reply"
        }
    }

    private enum SendOutcome: Sendable {
        case reply(ATVQReply)
        case failed(NWError)
        /// Connected but got no reply in time — or, with `connected` false, never connected:
        /// a Bonjour endpoint that can't be reached can sit in `.preparing` indefinitely
        /// without reporting a failure.
        case timedOut(TimeInterval, connected: Bool)
        case closed
        case unreadable
    }

    /// Sends to every target at once and returns as soon as one accepts, or once all have
    /// answered otherwise. Nothing is cancelled early: a stale advertisement (a sleeping
    /// Apple TV still listed by the network's sleep proxy) can't hold up the result, and an
    /// ATVQ that is awake still gets its copy straight away after the relay has accepted.
    private nonisolated static func deliver(_ body: Data, to targets: [Target]) async -> (accepted: String?, attempts: [Attempt]) {
        let collector = Collector(expected: targets.count)
        return await withCheckedContinuation { continuation in
            collector.arm(continuation)
            for target in targets {
                Task.detached(priority: .userInitiated) {
                    // The relay is on a wired, always-on Mac and answers on receipt; ATVQ may be
                    // waking or busy decoding, so it gets a little longer.
                    let attempt = await send(body, to: target.endpoint, label: target.label,
                                             timeout: target.isRelay ? 20 : 10)
                    collector.add(attempt)
                }
            }
        }
    }

    /// Gathers deliver()'s attempts and resumes it exactly once. Lock-guarded: attempts
    /// finish on their connections' queues.
    private final class Collector: Sendable {
        typealias Result = (accepted: String?, attempts: [Attempt])
        private struct State: Sendable {
            let expected: Int
            var attempts: [Attempt] = []
            var continuation: CheckedContinuation<Result, Never>?
            var resumed = false

            /// The result, the first time there is one to give.
            mutating func settled() -> Result? {
                guard !resumed else { return nil }
                if let accepted = attempts.first(where: { $0.reply?.ok == true }) {
                    resumed = true
                    return (accepted.label, attempts)
                }
                guard attempts.count >= expected else { return nil }
                resumed = true
                return (nil, attempts)
            }
        }
        private let state: Mutex<State>

        init(expected: Int) { state = Mutex(State(expected: expected)) }

        func arm(_ continuation: CheckedContinuation<Result, Never>) {
            let ready = state.withLock { state in
                state.continuation = continuation
                return state.settled()
            }
            ready.map { continuation.resume(returning: $0) }
        }

        func add(_ attempt: Attempt) {
            let (late, ready, continuation) = state.withLock { state in
                state.attempts.append(attempt)
                let late = state.resumed
                let ready = state.continuation == nil ? nil : state.settled()
                return (late, ready, ready == nil ? nil : state.continuation)
            }
            if late { ATVQClient.log("\(attempt.label) (after the dispatch was settled): \(attempt.summary)") }
            if let ready, let continuation { continuation.resume(returning: ready) }
        }
    }

    /// One framed request and its framed reply.
    private nonisolated static func send(_ body: Data, to endpoint: NWEndpoint, label: String,
                                         timeout: TimeInterval) async -> Attempt {
        // IPv4 only: a Bonjour peer also resolves to an IPv6 link-local address, which firewalls
        // (e.g. Little Snitch's "Local Network") commonly drop silently; a stalled IPv6 attempt
        // then decides whether a dispatch goes through. Everything here is on one LAN, so IPv4 always works.
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "FilmTracker.ATVQ.send")
        let length = UInt32(body.count)
        let frame = Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }) + body

        let finisher = Finisher()
        let (outcome, lastWaiting) = await withTaskCancellationHandler { await withCheckedContinuation { continuation in
            // Every path below finishes through here exactly once.
            finisher.arm { outcome, lastWaiting in
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: (outcome, lastWaiting))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed(let error): finisher.finish(.failed(error))
                case .waiting(let error) where isPolicyDenied(error): finisher.finish(.failed(error))
                // Not fatal by itself (Network.framework keeps retrying), but it's the best
                // explanation if the attempt then times out.
                case .waiting(let error): finisher.note(error)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finisher.finish(.timedOut(timeout, connected: connection.state == .ready)) }
            connection.start(queue: queue)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { finisher.finish(.failed(error)) }
            })
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
                guard let header, header.count == 4 else { finisher.finish(.closed); return }
                let count = header.reduce(0) { $0 << 8 | Int($1) }
                guard count > 0, count <= 64 * 1024 else { finisher.finish(.unreadable); return }
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                    guard let data, let reply = try? JSONDecoder().decode(ATVQReply.self, from: data) else {
                        finisher.finish(.unreadable); return
                    }
                    finisher.finish(.reply(reply))
                }
            }
        } } onCancel: {
            finisher.finish(.timedOut(0, connected: false))
        }

        var attempt = Attempt(label: label)
        switch outcome {
        case .reply(let reply):
            attempt.reply = reply
        case .failed(let error):
            attempt.problem = "\(error)"
            attempt.denied = isPolicyDenied(error)
        case .timedOut(let seconds, let connected):
            attempt.problem = (connected ? "connected, but no reply within \(Int(seconds)) s"
                                         : "couldn't connect within \(Int(seconds)) s")
                + (lastWaiting.map { " (\($0))" } ?? "")
        case .closed:
            attempt.problem = "the connection closed without a reply"
        case .unreadable:
            attempt.problem = "the reply couldn't be read"
        }
        return attempt
    }

    /// Runs its completion once, whichever of a send's callbacks — or a cancellation, which
    /// may arrive before the completion is even armed — gets there first. Lock-guarded:
    /// the callbacks run on the connection's queue, cancellation on any thread.
    private final class Finisher: Sendable {
        typealias Completion = @Sendable (SendOutcome, NWError?) -> Void
        private struct State: Sendable {
            var completion: Completion?
            var outcome: SendOutcome?
            var lastWaiting: NWError?
            var done = false
        }
        private let state = Mutex(State())

        func arm(_ completion: @escaping Completion) {
            // The completion runs after the lock is released, never inside it.
            let ready: (SendOutcome, NWError?)? = state.withLock { state in
                if let outcome = state.outcome, !state.done {
                    state.done = true
                    return (outcome, state.lastWaiting)
                }
                state.completion = completion
                return nil
            }
            if let (outcome, waiting) = ready { completion(outcome, waiting) }
        }

        func note(_ error: NWError) {
            state.withLock { $0.lastWaiting = error }
        }

        func finish(_ result: SendOutcome) {
            let ready: (Completion, NWError?)? = state.withLock { state in
                guard !state.done, state.outcome == nil else { return nil }
                guard let completion = state.completion else { state.outcome = result; return nil }
                state.done = true
                state.completion = nil
                return (completion, state.lastWaiting)
            }
            if let (completion, waiting) = ready { completion(result, waiting) }
        }
    }
}

// MARK: - Title Bar Button

/// GalleryTitleBar's "Dispatch to ATVQ" button, shown only while the preference is on.
/// `appletv.fill` at rest; `checkmark.circle.fill` for three seconds after a delivery;
/// `exclamationmark.triangle.fill` after a failure, held until clicked, which explains it.
struct ATVQDispatchButton: View {
    @AppStorage(preference: Preferences.atvqKey) private var atvq: Bool

    var body: some View {
        if atvq {
            ATVQDispatchButtonContent()
        }
    }
}

private struct ATVQDispatchButtonContent: View {
    @Environment(DataCoordinator.self) private var coordinator

    private enum Phase { case idle, delivered, failed(ATVQClient.Failure) }
    @State private var phase: Phase = .idle
    @State private var resetTask: Task<Void, Never>?
    /// False only for the silent failed → idle reset in click().
    @State private var glyphAnimates = true

    private var client: ATVQClient { ATVQClient.shared }

    var body: some View {
        Button(action: click) {
            Image(systemName: glyph)
                .contentTransition(.symbolEffect(.replace))
                // GalleryView strips every animation from the title bar's transactions
                // (withAnimation included), which left the replace with nothing to run on.
                // Put one back for glyph changes only, beneath that strip.
                .transaction(value: glyph) { transaction in
                    guard glyphAnimates else { return }
                    transaction.disablesAnimations = false
                    transaction.animation = .default
                }
                .font(.system(size: 14))
                .frame(width: 18)
                // appletv.fill's visual center sits above its layout center.
                .offset(y: 1)
        }
        // Sized like the view-style toggle beside it; see the sizing note at the top of
        // GalleryTitleBar.buttonSection.
        .frame(maxWidth: Preferences.buttonWidth)
        .fixedSize()
        .frame(width: Preferences.buttonSpacing)
        // Off only while a dispatch runs. Never off for a reported refusal: the browsers'
        // report is only a hint, and the dispatch itself is what finds out (and explains it).
        .disabled(client.isDispatching)
        .help(help)
        .onAppear { client.syncWithPreference() }
        .onDisappear { resetTask?.cancel() }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var glyph: String {
        switch phase {
        case .idle: "appletv.fill"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var help: String {
        if isFailed { return "Dispatch failed. Click for details." }
        if client.access == .denied {
            return "Dispatching to ATVQ needs Local Network access. Turn on Film Tracker in System Settings › Privacy & Security › Local Network."
        }
        let base = "Dispatch your \"Up Next\" Queue to ATVQ"
        guard let last = client.lastDelivered else { return base }
        return base + "\nLast sent " + Self.relativeTimestamp(last)
    }

    /// "today at 2:46 PM", "yesterday at 5:10 PM", "Tuesday at 1:11 AM" within the past
    /// week, then "October 5 at 4:04 PM" (with the year when it isn't this one).
    private static func relativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = AppCalendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) {
            day = "today"
        } else if calendar.isDateInYesterday(date) {
            day = "yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day,
                  days < 7 {
            day = date.formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = date.formatted(Date.FormatStyle(calendar: calendar).month(.wide).day())
        } else {
            day = date.formatted(Date.FormatStyle(calendar: calendar).month(.wide).day().year())
        }
        return "\(day) at \(time)"
    }

    private func click() {
        if case .failed(let failure) = phase {
            // Back to rest without an animation, so it can't contend with the alert's.
            glyphAnimates = false
            phase = .idle
            AppEventBus.shared.sendAlert(.showNotice(title: "Couldn't Dispatch to ATVQ",
                                                     message: failure.message))
            return
        }
        resetTask?.cancel()
        Task {
            let failure = await client.dispatch(coordinator: coordinator)
            if failure == .cancelled { return }
            glyphAnimates = true
            phase = failure.map { .failed($0) } ?? .delivered
            guard failure == nil else { return }
            client.noteDelivered()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                phase = .idle
            }
        }
    }
}

// MARK: - Settings

/// The ATVQ row's accessory in Settings › Advanced. Off while the integration is off, so
/// the client (and its browsing) is never created for a disabled preference.
struct ATVQTestRelayButton: View {
    @AppStorage(preference: Preferences.atvqKey) private var atvq: Bool

    var body: some View {
        // `atvq &&` short-circuits: no client while off.
        let testing = atvq && ATVQClient.shared.isTestingRelay
        HStack(spacing: 8) {
            Button("Test Relay Connection") { ATVQClient.shared.runRelayTest() }
                .disabled(!atvq || testing)
                .help("Sends a test dispatch to the ATVQ Deployer's relay and reports whether it was received")
            // Always laid out, so the button never shifts as the spinner comes and goes.
            ProgressView()
                .controlSize(.small)
                .opacity(testing ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: testing)
                .accessibilityHidden(!testing)
        }
    }
}

// MARK: - Local Network Check

extension ATVQClient {
    /// Whether macOS is refusing Film Tracker local network access right now.
    ///
    /// The refusal is only ever reported plainly for a connection to a literal LAN address:
    /// a Bonjour connection just stays in `.preparing` forever (the attempt to each resolved
    /// address fails inside Network.framework, which keeps retrying), and one by host name
    /// waits with "Network is down". The browsers aren't affected at all. So this asks
    /// directly: can a connection to this network's router get a path? When access is
    /// denied, nothing is sent; when it's allowed, the probe is cancelled before it connects.
    nonisolated static func localNetworkDenied() async -> Bool {
        let queue = DispatchQueue(label: "FilmTracker.ATVQ.localNetworkCheck")
        let monitor = NWPathMonitor()
        let gateway: NWEndpoint? = await withCheckedContinuation { continuation in
            let once = Once<NWEndpoint?> { continuation.resume(returning: $0) }
            monitor.pathUpdateHandler = { path in once.fire(path.gateways.first) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { once.fire(nil) }
        }
        monitor.cancel()
        guard case .hostPort(let host, _)? = gateway else { return false }

        let connection = NWConnection(to: .hostPort(host: host, port: 9), using: .tcp)
        let denied: Bool = await withCheckedContinuation { continuation in
            let once = Once<Bool> { continuation.resume(returning: $0) }
            connection.stateUpdateHandler = { state in
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { once.fire(true); return }
                switch state {
                case .preparing, .ready, .waiting, .failed: once.fire(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { once.fire(false) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        log("Local Network check via \(host): \(denied ? "denied" : "allowed")")
        return denied
    }

    /// Delivers one value, from whichever callback gets there first.
    private final class Once<Value>: Sendable {
        private let action: Mutex<((Value) -> Void)?>
        init(_ action: sending @escaping (Value) -> Void) { self.action = Mutex(action) }
        func fire(_ value: Value) {
            let action = self.action.withLock { action -> sending ((Value) -> Void)? in
                let taken = action; action = nil; return taken
            }
            action?(value)
        }
    }
}

// MARK: - Debug Harness Probe

#if DEBUG
extension ATVQClient {
    /// DebugHarness `atvq-relay`: from inside the real (sandboxed) app, browses for relays
    /// and pings each one several ways, recording every connection state with its timing,
    /// so a failure to connect can be pinned to one variable. Stores nothing on the relay.
    static func harnessRelayProbe() async -> [(variant: String, ok: Bool, trace: String)] {
        let browser = NWBrowser(for: .bonjour(type: relayType, domain: nil), using: .tcp)
        let box = ProbeBox()
        browser.browseResultsChangedHandler = { results, _ in box.set(results.map(\.endpoint)) }
        browser.stateUpdateHandler = { state in box.note("browser \(state)") }
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(3))
        browser.cancel()
        let found = box.endpoints
        var results: [(String, Bool, String)] = [("browse", !found.isEmpty, "\(box.notes) found=\(found)")]
        let denied = await localNetworkDenied()
        results.append(("local network allowed", !denied, denied ? "macOS reports localNetworkDenied" : "allowed"))
        // The production path, end to end, with a ping body (the relay acknowledges it and
        // stores nothing).
        let targets = found.map { Target(endpoint: $0, label: "relay \($0)", isRelay: true) }
        if !targets.isEmpty {
            let started = Date()
            let outcome = await deliver(Data(#"{"ping":true}"#.utf8), to: targets)
            results.append(("deliver() ping", outcome.accepted != nil,
                            "\(seconds(since: started)) "
                                + outcome.attempts.map { "\($0.label): \($0.summary)" }.joined(separator: " | ")))
            let single = await send(Data(#"{"ping":true}"#.utf8), to: found[0], label: "relay", timeout: 8)
            results.append(("send() ping", single.reply != nil, single.summary))
            // Full-size, but without `dispatchedAt`: the relay reads all of it, then answers
            // "Not a queue payload" and stores nothing.
            for kilobytes in [64, 512, 2048] {
                let padding = String(repeating: "A", count: kilobytes * 1024)
                let big = Data(#"{"films":[],"padding":"\#(padding)"}"#.utf8)
                let bigStart = Date()
                let attempt = await send(big, to: found[0], label: "relay", timeout: 20)
                results.append(("send() \(kilobytes) KB", attempt.reply != nil,
                                "\(seconds(since: bigStart)) " + attempt.summary))
            }
        }
        for endpoint in found {
            guard case .service(let name, let type, let domain, _) = endpoint else { continue }
            let variants: [(String, NWEndpoint, Bool)] = [
                ("browsed, IPv4 only", endpoint, true),
                ("browsed, any IP", endpoint, false),
                ("by name, IPv4 only", .service(name: name, type: type, domain: domain, interface: nil), true),
                ("by name, any IP", .service(name: name, type: type, domain: domain, interface: nil), false),
            ]
            for (label, target, v4) in variants {
                let (ok, trace) = await probe(target, ipv4Only: v4)
                results.append(("\(name): \(label)", ok, trace))
            }
        }
        return results
    }

    private nonisolated static func probe(_ endpoint: NWEndpoint, ipv4Only: Bool) async -> (Bool, String) {
        let parameters = NWParameters.tcp
        if ipv4Only { (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let box = ProbeBox()
        let start = Date()
        let ping = Data(#"{"ping":true}"#.utf8)
        let frame = Data([0, 0, 0, UInt8(ping.count)]) + ping
        let ok: Bool = await withCheckedContinuation { continuation in
            let once = ProbeOnce { continuation.resume(returning: $0) }
            connection.stateUpdateHandler = { state in
                let path = connection.currentPath
                box.note("\(seconds(since: start)) \(state) path=\(path?.status as Any)/\(path?.unsatisfiedReason as Any) remote=\(path?.remoteEndpoint as Any)")
                if case .failed = state { once.fire(false) }
            }
            connection.start(queue: DispatchQueue(label: "FilmTracker.ATVQ.probe"))
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { box.note("send error \(error)") }
            })
            connection.receive(minimumIncompleteLength: 4, maximumLength: 1024) { data, _, _, error in
                box.note("\(seconds(since: start)) reply \(data.map { String(decoding: $0.dropFirst(4), as: UTF8.self) } ?? "nil") error=\(error as Any)")
                once.fire(data != nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { box.note("timeout 8s"); once.fire(false) }
        }
        connection.cancel()
        return (ok, box.notes)
    }

    private nonisolated static func seconds(since start: Date) -> String {
        Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(2))) + "s"
    }

    private final class ProbeBox: Sendable {
        private let lines = Mutex<[String]>([])
        private let found = Mutex<[NWEndpoint]>([])
        func note(_ line: String) { lines.withLock { $0.append(line) } }
        func set(_ endpoints: [NWEndpoint]) { found.withLock { $0 = endpoints } }
        var notes: String { lines.withLock { $0.joined(separator: " | ") } }
        var endpoints: [NWEndpoint] { found.withLock { $0 } }
    }

    private final class ProbeOnce: Sendable {
        private let action: Mutex<((Bool) -> Void)?>
        init(_ action: sending @escaping (Bool) -> Void) { self.action = Mutex(action) }
        func fire(_ value: Bool) {
            let action = self.action.withLock { action -> sending ((Bool) -> Void)? in
                let taken = action; action = nil; return taken
            }
            action?(value)
        }
    }
}
#endif
