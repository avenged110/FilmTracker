// MARK: - ReleaseNotifications.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Release-day notifications: when `Preferences.notifyAboutNewReleases` is on, Film Tracker
// posts a Notification Center notification on the release date of every release that was
// cataloged while that date was still ahead — or, with `Preferences.onlyNotifyForWishlisted`,
// of every such release that is also wishlisted.
//
// MARK: Scheduled with the system, not fired by the app
//
// Each notification is a pending UNNotificationRequest with a calendar trigger at
// `deliveryHour` on the release day, so macOS delivers it whether or not Film Tracker is
// running then. The app's job is only to keep the pending set equal to what the library and
// the two preferences call for, which `sync()` does on launch, after any change to a film or
// its releases, when either preference changes, and when the day changes.
//
// MARK: "Cataloged with a date still ahead"
//
// A release is scheduled only while its date lies after today. On the release day itself it
// is no longer upcoming, so a sync that day keeps a request only if one is ALREADY pending for
// it — and one can be pending only because it was scheduled while the date was still ahead.
// That is what keeps a release cataloged on the day it comes out from being announced, while
// a sync on the morning of a release day (a relaunch, an unrelated edit) does not cancel the
// notification it is about to deliver.
//
// MARK: What is left out
//
// • Combo-pack children: a bundled Blu-ray shares its 4K parent's date and is one purchase
//   with it, so the pack is announced once, through the parent.
// • Year-only release dates, which name no day to deliver on.
// • Debug sandbox runs, which must never touch the real app's pending notifications, and a
//   session whose library could not be read (DataCoordinator.isLibraryStateUnreliable),
//   where the empty library would otherwise cancel every pending notification.
//
// macOS keeps a limited number of pending requests per app, so at most `maxScheduled` are
// kept — the soonest. Later ones are added as earlier ones are delivered, by the sync that
// runs when the day changes.

import Foundation
import Combine
import UserNotifications

@MainActor
final class ReleaseNotifications: Loggable {
    nonisolated static let logTag = "[ReleaseNotifications]"

    /// Prefix of every request this type owns. Nothing else in the app uses it, so a sync
    /// can remove its own requests without touching anyone else's.
    nonisolated static let identifierPrefix = "release-day."
    /// Below macOS's per-app ceiling on pending requests, leaving room for other requests.
    nonisolated static let maxScheduled = 60
    /// The local hour the notification is delivered on the release day.
    nonisolated static let deliveryHour = 9

    private weak var coordinator: DataCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var started = false
    /// Preference values as of the last `preferencesChanged`, so the event — posted for
    /// every preference — reschedules only when one of these two moved.
    private var lastNotify = Preferences.notifyAboutNewReleases
    private var lastWishlistedOnly = Preferences.onlyNotifyForWishlisted
    /// What the last sync left pending, so a sync that changes nothing makes no calls. nil
    /// until the first sync has read the system's pending list.
    private var applied: [String: Planned]?
    /// Held strongly: the notification center keeps its delegate weakly.
    private let presenter = Presenter()

    /// One request as this type would schedule it.
    struct Planned: Equatable {
        let trigger: DateComponents
        let fireDate: Date
        let title: String
        let body: String
    }

    init(coordinator: DataCoordinator) {
        self.coordinator = coordinator
    }

    /// Installs the listeners and runs the first sync. Called once, after the library has
    /// loaded.
    func start() {
        guard !started else { return }
        started = true
        guard !DebugSandbox.isActive else {
            log("Debug sandbox active — release-day notifications are not scheduled")
            return
        }
        UNUserNotificationCenter.current().delegate = presenter

        // Any change to a film can change what is due: its releases, its wishlist state, or
        // its name, which the notification carries. Debounced, so a burst of edits costs one
        // sync.
        AppEventBus.shared.filmEvents
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)

        AppEventBus.shared.viewEvents
            .filter { $0 == .preferencesChanged }
            .sink { [weak self] _ in self?.handlePreferencesChanged() }
            .store(in: &cancellables)

        // A new day turns yesterday's "upcoming" into today's release and frees places
        // under `maxScheduled` for later dates.
        CurrentDay.shared.dayChanged
            .sink { [weak self] _ in self?.scheduleSync(delay: .zero) }
            .store(in: &cancellables)

        scheduleSync(delay: .zero)
    }

    private func handlePreferencesChanged() {
        let notify = Preferences.notifyAboutNewReleases
        let wishlistedOnly = Preferences.onlyNotifyForWishlisted
        guard notify != lastNotify || wishlistedOnly != lastWishlistedOnly else { return }
        let turnedOn = notify && !lastNotify
        lastNotify = notify
        lastWishlistedOnly = wishlistedOnly
        log("Preferences changed — notify \(notify), wishlisted only \(wishlistedOnly)")
        if turnedOn {
            // Turning the setting on is the moment to ask macOS for permission, and to say so
            // if it is refused, since nothing will be delivered until it is granted.
            Task { [weak self] in
                await self?.requestAuthorization(announceRefusal: true)
                self?.scheduleSync(delay: .zero)
            }
        } else {
            scheduleSync(delay: .zero)
        }
    }

    private func requestAuthorization(announceRefusal: Bool) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard !granted else { return }
        log("Notification permission not granted")
        if announceRefusal {
            AppEventBus.shared.sendAlert(.showNotice(
                title: "Notifications Are Turned Off",
                message: "Film Tracker isn't allowed to send notifications, so new releases can't be announced. You can allow them in System Settings > Notifications > Film Tracker."))
        }
    }

    // MARK: - Sync

    /// Runs one sync after `delay`, replacing any that has not started. Syncs never overlap:
    /// a new one waits for the one before it to finish, so an older sync working from older
    /// data cannot add back a request a newer one has just removed.
    private func scheduleSync(delay: Duration = .seconds(2)) {
        let previous = syncTask
        previous?.cancel()
        syncTask = Task { [weak self] in
            await previous?.value
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.sync()
        }
    }

    /// Brings the system's pending requests into line with what is due.
    private func sync() async {
        guard let coordinator, !coordinator.isLibraryStateUnreliable else { return }
        let center = UNUserNotificationCenter.current()

        // The pending list is read from the system on the first sync, and again whenever
        // what is due depends on it (see "Cataloged with a date still ahead").
        let pendingIDs = Set(await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) })
        guard !Task.isCancelled else { return }

        let wanted: [String: Planned]
        if Preferences.notifyAboutNewReleases {
            var status = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled else { return }
            if status == .notDetermined {
                // Enabled in a restored backup or before permission was ever asked.
                await requestAuthorization(announceRefusal: false)
                status = await center.notificationSettings().authorizationStatus
            }
            // Refused: nothing can be scheduled, and trying on every sync would only log a
            // failure per release each time. The pending set is left as it is.
            guard status != .denied else { return }
            // The inputs are read here; the plan itself — a walk over every release of every
            // film — runs off the main actor. It is pure and takes only Sendable values.
            let films = coordinator.getAllFilms()
            let today = CurrentDay.shared.today
            let wishlistedOnly = Preferences.onlyNotifyForWishlisted
            wanted = await Task.detached(priority: .utility) {
                Self.plan(films: films, pendingIDs: pendingIDs, today: today, now: Date(),
                          wishlistedOnly: wishlistedOnly)
            }.value
            guard !Task.isCancelled else { return }
        } else {
            wanted = [:]
        }

        let stale = pendingIDs.subtracting(wanted.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        var added = 0
        var nowApplied = wanted
        for (id, planned) in wanted where !pendingIDs.contains(id) || applied?[id] != planned {
            // A newer sync is waiting with newer data; it will finish the job.
            if Task.isCancelled { nowApplied[id] = nil; continue }
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.body = planned.body
            content.sound = .default
            content.threadIdentifier = "release-day"
            let trigger = UNCalendarNotificationTrigger(dateMatching: planned.trigger, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                added += 1
            } catch {
                // Left out of `applied`, so the next sync tries it again.
                nowApplied[id] = nil
                log("WARNING: Could not schedule \(id): \(error.localizedDescription)")
            }
        }
        applied = nowApplied
        if added > 0 || !stale.isEmpty {
            log("Scheduled \(added), removed \(stale.count); \(wanted.count) pending")
        }
    }

    /// The requests due for `films` on `today` (its start) at the moment `now`, soonest
    /// first, at most `maxScheduled`. `pendingIDs` are this type's requests the system holds.
    /// Pure, so the harness can drive it (99.12 `release-day-notifications`).
    nonisolated static func plan(films: [FilmSnapshot], pendingIDs: Set<String>, today: Date,
                                 now: Date, wishlistedOnly: Bool) -> [String: Planned] {
        let todayComps = StorageDateFormatters.calendar.dateComponents([.year, .month, .day], from: today)
        let todayKey = (todayComps.year ?? 0) * 10_000 + (todayComps.month ?? 0) * 100 + (todayComps.day ?? 0)
        // Delivered in the Mac's own time zone, at the hour on the release day.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current

        var due: [(id: String, planned: Planned)] = []
        for film in films {
            for release in film.releases where !release.isChild {
                if wishlistedOnly && release.wishlist < 1 { continue }
                guard let date = ReleaseDateValue(release.releaseDate, format: release.format),
                      let monthDay = date.monthDay else { continue }
                let id = Self.identifierPrefix + release.id.uuidString
                // Ahead of today, or today with a request already waiting (see the header).
                guard date.isUpcoming(today: today)
                        || (date.sortKey == todayKey && pendingIDs.contains(id)) else { continue }
                var trigger = DateComponents(year: date.year, month: monthDay.month,
                                             day: monthDay.day, hour: Self.deliveryHour)
                trigger.calendar = local
                trigger.timeZone = local.timeZone
                guard let fireDate = local.date(from: trigger), fireDate > now else { continue }
                due.append((id, Planned(trigger: trigger, fireDate: fireDate,
                                        title: film.name,
                                        body: Self.body(for: release))))
            }
        }
        due.sort { $0.planned.fireDate < $1.planned.fireDate }
        return Dictionary(due.prefix(Self.maxScheduled).map { ($0.id, $0.planned) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// "The 4K UHD release from Criterion is out today."
    nonisolated private static func body(for release: ReleaseSnapshot) -> String {
        let studio = release.studio.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = studio.isEmpty ? "" : " from \(studio)"
        let wishlisted = release.wishlist >= 1 ? " It's on your wishlist." : ""
        return "The \(release.format) release\(from) is out today.\(wishlisted)"
    }

    // MARK: - Presentation

    /// Lets a release-day notification, and the ATVQ relay test's result, show as a banner
    /// while Film Tracker is the active app, which macOS otherwise suppresses (the request
    /// goes straight to Notification Center). The relay test is always run from Settings, so
    /// without this its result never appeared on screen at all.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            let id = notification.request.identifier
            return id.hasPrefix(ReleaseNotifications.identifierPrefix) || id == ATVQClient.relayTestNotificationID
                ? [.banner, .list, .sound] : []
        }
    }
}
