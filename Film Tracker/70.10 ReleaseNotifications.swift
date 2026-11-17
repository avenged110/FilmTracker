// MARK: - ReleaseNotifications.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Release-day notifications: when `Preferences.notifyAboutNewReleases` is on, Film Tracker
/// posts a Notification Center notification on the release date of every release that was
/// cataloged while that date was still ahead — or, with `Preferences.onlyNotifyForWishlisted`,
/// of every such release that is also wishlisted.
///
// MARK: At most one notification a day
///
/// A day's releases share one notification: a single release is named outright ("Heat", "The
/// 4K UHD release from Criterion is out today."), two or more become a digest ("3 New Releases
/// Today", "Out today: Alien (4K UHD), Heat (Blu-ray), and 1 more."). So the requests are per
/// day, not per release, and a day's request is replaced whenever its set of releases changes.
///
// MARK: Scheduled with the system, not fired by the app
///
/// Each notification is a pending UNNotificationRequest with a calendar trigger at
/// `deliveryHour` on the release day, so macOS delivers it whether or not Film Tracker is
/// running then. The app's job is only to keep the pending set equal to what the library and
/// the two preferences call for, which `sync()` does on launch, after any change to a film or
/// its releases, when either preference changes, and when the day changes.
///
// MARK: "Cataloged with a date still ahead"
///
/// A release is scheduled only while its date lies after today. On the release day itself it
/// is no longer upcoming, so a sync that day keeps a request only if an earlier sync planned it
/// — and one did only while the date was still ahead. That is what keeps a release cataloged on
/// the day it comes out from being announced, while a sync on the morning of a release day (a
/// relaunch, an unrelated edit, the midnight sync) does not cancel the notification it is about
/// to deliver.
///
/// What earlier syncs planned is recorded here (`plannedIDsKey`), not read back from the
/// system's pending list. macOS can hold fewer requests than were added — it has kept a single
/// one for this app, dropping each earlier request as the next arrived ("Too many requests" in
/// usernoted's log) — and a rule that trusted the pending list then dropped every release on its
/// own day at the midnight sync. The record is this Mac's, like the pending requests themselves,
/// so it lives in UserDefaults and not in Preferences, which a backup carries to other Macs.
///
// MARK: What is left out
///
/// • Combo-pack children: a bundled Blu-ray shares its 4K parent's date and is one purchase
///   with it, so the pack is announced once, through the parent.
/// • Year-only release dates, which name no day to deliver on.
/// • Debug sandbox runs, which must never touch the real app's pending notifications, and a
///   session whose library could not be read (DataCoordinator.isLibraryStateUnreliable),
///   where the empty library would otherwise cancel every pending notification.
///
/// macOS keeps a limited number of pending requests per app, so at most `maxScheduled` are
/// kept — the soonest. Later ones are added as earlier ones are delivered, by the sync that
/// runs when the day changes. Requests are added latest first, so if macOS keeps fewer than
/// that, what it keeps are the soonest; a sync that finds fewer pending than it added says so
/// in the log.

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
    /// UserDefaults key: the releases (`releaseKey`s) the last sync planned, across every day's
    /// request (see "Cataloged with a date still ahead").
    private static let plannedIDsKey = "releaseNotifications.plannedIDs"

    private static var storedPlannedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: plannedIDsKey) ?? []) }
        set {
            guard newValue != storedPlannedIDs else { return }
            UserDefaults.standard.set(newValue.sorted(), forKey: plannedIDsKey)
        }
    }

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

    /// One request as this type would schedule it: one day's notification.
    struct Planned: Equatable {
        let trigger: DateComponents
        let fireDate: Date
        /// The day's releases, as `releaseKey`s, sorted: what the record of planned releases
        /// keeps (see "Cataloged with a date still ahead").
        let releaseKeys: [String]
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

        /// Any change to a film can change what is due: its releases, its wishlist state, or
        /// its name, which the notification carries. Debounced, so a burst of edits costs one
        /// sync.
        AppEventBus.shared.filmEvents
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)

        AppEventBus.shared.viewEvents
            .filter { $0 == .preferencesChanged }
            .sink { [weak self] _ in self?.handlePreferencesChanged() }
            .store(in: &cancellables)

        /// A new day turns yesterday's "upcoming" into today's release and frees places
        /// under `maxScheduled` for later dates.
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
            /// Turning the setting on is the moment to ask macOS for permission, and to say so
            /// if it is refused, since nothing will be delivered until it is granted.
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

        let pendingIDs = await Self.pendingIDs(center)
        guard !Task.isCancelled else { return }

        let wanted: [String: Planned]
        if Preferences.notifyAboutNewReleases {
            var status = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled else { return }
            if status == .notDetermined {
                /// Enabled in a restored backup or before permission was ever asked.
                await requestAuthorization(announceRefusal: false)
                status = await center.notificationSettings().authorizationStatus
            }
            /// Refused: nothing can be scheduled, and trying on every sync would only log a
            /// failure per release each time. The pending set is left as it is.
            guard status != .denied else { return }
            /// The inputs are read here; the plan itself — a walk over every release of every
            /// film — runs off the main actor. It is pure and takes only Sendable values.
            let films = coordinator.getAllFilms()
            let today = CurrentDay.shared.today
            let wishlistedOnly = Preferences.onlyNotifyForWishlisted
            /// The pending requests count too, for per-release requests scheduled before the
            /// record was kept (their identifiers are release keys).
            let eligibleIDs = Self.storedPlannedIDs.union(pendingIDs)
            wanted = await Task.detached(priority: .utility) {
                Self.plan(films: films, eligibleIDs: eligibleIDs, today: today, now: Date(),
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
        /// Recorded whether or not each add succeeds: a release planned while its date was ahead
        /// stays eligible on its day even if macOS did not keep, or refused, its request.
        Self.storedPlannedIDs = Set(wanted.values.flatMap(\.releaseKeys))
        var added = 0
        var nowApplied = wanted
        /// Latest first: if macOS keeps fewer requests than are added, each add dropping an
        /// earlier one, the ones it keeps are the soonest.
        let toAdd = wanted
            .filter { id, planned in !pendingIDs.contains(id) || applied?[id] != planned }
            .sorted { $0.value.fireDate > $1.value.fireDate }
        for (id, planned) in toAdd {
            /// A newer sync is waiting with newer data; it will finish the job.
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
                /// Left out of `applied`, so the next sync tries it again.
                nowApplied[id] = nil
                log("WARNING: Could not schedule \(id): \(error.localizedDescription)")
            }
        }
        applied = nowApplied
        if added > 0 || !stale.isEmpty {
            log("Scheduled \(added), removed \(stale.count); \(wanted.count) pending")
        }
        guard added > 0, !Task.isCancelled else { return }
        /// Read back once, so a system that keeps fewer than were added is caught in the log
        /// rather than discovered on a release day with no notification. Anything it dropped
        /// is no longer pending, so the next sync adds it again (soonest last, as above).
        let kept = await Self.pendingIDs(center).intersection(wanted.keys).count
        if kept < wanted.count {
            log("WARNING: macOS kept \(kept) of \(wanted.count) release-day notifications; "
                + "the rest were dropped (see usernoted's \"Too many requests\" in the system log)")
        }
    }

    /// The identifiers of this type's requests the system holds.
    private static func pendingIDs(_ center: UNUserNotificationCenter) async -> Set<String> {
        Set(await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) })
    }

    /// A release's key in the record of planned releases ("release-day.<release UUID>") — the
    /// identifier its request had when there was one request per release.
    nonisolated static func releaseKey(_ release: ReleaseSnapshot) -> String {
        identifierPrefix + release.id.uuidString
    }

    /// The identifier of a day's request ("release-day.day.2026-11-20"). It shares the prefix,
    /// so a sync removes this type's requests of either form, and never parses as a release key.
    nonisolated static func dayRequestID(year: Int, month: Int, day: Int) -> String {
        func padded(_ n: Int, _ width: Int) -> String {
            let digits = String(n)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return identifierPrefix + "day." + "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
    }

    /// The requests due for `films` on `today` (its start) at the moment `now`, one per
    /// release day, soonest first, at most `maxScheduled` days. `eligibleIDs` are the release
    /// keys an earlier sync planned, which a release on `today` needs to be kept. Pure, so the
    /// harness can drive it (99.12 `release-date-rules`).
    nonisolated static func plan(films: [FilmSnapshot], eligibleIDs: Set<String>, today: Date,
                                 now: Date, wishlistedOnly: Bool) -> [String: Planned] {
        let todayComps = StorageDateFormatters.calendar.dateComponents([.year, .month, .day], from: today)
        let todayKey = (todayComps.year ?? 0) * 10_000 + (todayComps.month ?? 0) * 100 + (todayComps.day ?? 0)
        /// Delivered in the Mac's own time zone, at the hour on the release day.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current

        struct Item { let key: String; let filmName: String; let release: ReleaseSnapshot }
        var days: [String: (trigger: DateComponents, fireDate: Date, items: [Item])] = [:]
        for film in films {
            for release in film.releases where !release.isChild {
                if wishlistedOnly && release.wishlist < 1 { continue }
                guard let date = ReleaseDateValue(release.releaseDate, format: release.format),
                      let monthDay = date.monthDay else { continue }
                let key = releaseKey(release)
                /// Ahead of today, or today and planned while it was ahead (see the header).
                guard date.isUpcoming(today: today)
                        || (date.sortKey == todayKey && eligibleIDs.contains(key)) else { continue }
                let id = dayRequestID(year: date.year, month: monthDay.month, day: monthDay.day)
                let item = Item(key: key, filmName: film.name, release: release)
                if days[id] != nil { days[id]!.items.append(item); continue }
                var trigger = DateComponents(year: date.year, month: monthDay.month,
                                             day: monthDay.day, hour: deliveryHour)
                trigger.calendar = local
                trigger.timeZone = local.timeZone
                guard let fireDate = local.date(from: trigger), fireDate > now else { continue }
                days[id] = (trigger, fireDate, [item])
            }
        }

        let soonest = days.sorted { $0.value.fireDate < $1.value.fireDate }.prefix(maxScheduled)
        var result: [String: Planned] = [:]
        for (id, day) in soonest {
            /// Film name, then format, then ID: the same text whatever order the films came in,
            /// so an unchanged day compares equal and is not re-added.
            let items = day.items.sorted {
                ($0.filmName, $0.release.format, $0.key) < ($1.filmName, $1.release.format, $1.key)
            }
            let (title, body) = content(for: items.map { ($0.filmName, $0.release) })
            result[id] = Planned(trigger: day.trigger, fireDate: day.fireDate,
                                 releaseKeys: items.map(\.key), title: title, body: body)
        }
        return result
    }

    /// Releases a digest names before "and N more": a banner shows about two lines.
    nonisolated static let digestNamedLimit = 3

    /// One release: its film, and "The 4K UHD release from Criterion is out today." Two or
    /// more: "3 New Releases Today", and "Out today: Alien (4K UHD), Heat (Blu-ray), and 1
    /// more." Either way the wishlisted ones are counted last.
    nonisolated static func content(for releases: [(filmName: String, release: ReleaseSnapshot)])
        -> (title: String, body: String) {
        let wished = releases.filter { $0.release.wishlist >= 1 }.count
        if releases.count == 1, let only = releases.first {
            let studio = only.release.studio.trimmingCharacters(in: .whitespacesAndNewlines)
            let from = studio.isEmpty ? "" : " from \(studio)"
            let wishlisted = wished > 0 ? " It's on your wishlist." : ""
            return (only.filmName, "The \(only.release.format) release\(from) is out today.\(wishlisted)")
        }
        let names = releases.map { "\($0.filmName) (\($0.release.format))" }
        let listed: String
        if names.count <= digestNamedLimit {
            listed = names.dropLast().joined(separator: ", ")
                + (names.count > 2 ? "," : "") + " and " + names[names.count - 1]
        } else {
            let shown = digestNamedLimit - 1
            listed = names.prefix(shown).joined(separator: ", ") + ", and \(names.count - shown) more"
        }
        let wishlisted: String
        switch wished {
        case 0: wishlisted = ""
        case releases.count: wishlisted = releases.count == 2 ? " Both are on your wishlist." : " All are on your wishlist."
        case 1: wishlisted = " 1 is on your wishlist."
        default: wishlisted = " \(wished) are on your wishlist."
        }
        return ("\(releases.count) New Releases Today", "Out today: \(listed).\(wishlisted)")
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
