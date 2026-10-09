// MARK: - EventKitManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized EventKit management with proper authorization and caching.
// Enhanced with robust permission change detection and UI notification.

import Foundation
import os
import EventKit

/// Singleton manager for EventKit operations.
/// Reduces XPC overhead by maintaining a single EventStore instance and caching calendars.
/// Notifies UI components when authorization status changes for immediate reactive updates.
@MainActor
final class EventKitManager: Loggable {
    nonisolated static let logTag = "[EventKitManager]"
    
    // MARK: - Singleton
    
    static let shared = EventKitManager()

    /// A store and status built off the main actor by `prewarm()`, taken by `init`.
    private struct Prepared: @unchecked Sendable {
        let store: EKEventStore
        let status: EKAuthorizationStatus
    }
    /// Lives inside its lock, so there is no way to touch it unlocked.
    nonisolated private static let prepared = OSAllocatedUnfairLock<Prepared?>(initialState: nil)

    /// Builds the event store and reads the authorization status on a background thread,
    /// then creates `shared` with them. Both are slow the first time in a process —
    /// EKEventStore soft-links ReminderKit, and the status is a synchronous XPC round trip
    /// to the calendar daemon — and `shared` was otherwise first touched by WatchDetails'
    /// onAppear, so the session's first film selection paid for them on the main thread.
    /// Called once at launch; if a selection wins the race, init just builds its own.
    nonisolated static func prewarm() {
        Task.detached(priority: .utility) {
            let ready = Prepared(store: EKEventStore(), status: EKEventStore.authorizationStatus(for: .event))
            prepared.withLock { $0 = ready }
            await MainActor.run { _ = EventKitManager.shared }
        }
    }

    private init() {
        let ready = Self.prepared.withLock { slot -> Prepared? in
            defer { slot = nil }
            return slot
        }
        eventStore = ready?.store ?? EKEventStore()
        log("Initialized\(ready != nil ? " (prewarmed)" : "")")
        // Start observing authorization changes from system
        startObservingAuthorizationChanges(knownStatus: ready?.status)
        // Start observing calendar-set changes from the system
        startObservingStoreChanges()
    }
    
    // MARK: - Properties
    
    /// Single shared event store instance (reduces XPC connections).
    private let eventStore: EKEventStore
    
    /// Cached authorization status (reduces repeated authorization checks).
    private var cachedAuthStatus: EKAuthorizationStatus?
    
    /// Cached writable calendars (reduces repeated calendar queries).
    private var cachedCalendars: [EKCalendar]?
    
    /// Last time calendars were loaded (for cache invalidation).
    private var lastCalendarLoadTime: Date?
    
    /// Cache duration (5 minutes) - balances freshness with performance.
    private let cacheValidityDuration: TimeInterval = 300
    
    /// Task for polling authorization status changes
    private var authPollingTask: Task<Void, Never>?

    /// Token for the EKEventStoreChanged observation (see startObservingStoreChanges).
    private var storeChangeObserver: (any NSObjectProtocol)?
    
    // MARK: - Authorization Observation
    
    /// Starts observing authorization changes.
    /// macOS doesn't provide a notification when TCC grants permission in System Settings,
    /// so polling is required to detect that transition. However, polling is only meaningful
    /// when the status is in a transient state (.notDetermined or immediately after a request
    /// is made). For stable states (.authorized / .fullAccess / .denied / .restricted) the
    /// status cannot change without a new explicit request, so starting a polling loop on
    /// every launch for those users is pure overhead — this guard eliminates that waste.
    private func startObservingAuthorizationChanges(knownStatus: EKAuthorizationStatus? = nil) {
        // Cancel any existing polling task before potentially starting a new one.
        authPollingTask?.cancel()

        // Read the current status once. If it is already stable (anything other than
        // .notDetermined), there is nothing to poll for: the user has either granted or
        // denied access, and only a new requestAccessIfNeeded() call can change that.
        // restartAuthorizationPolling() is called from requestAccessIfNeeded() to cover
        // the post-request window, so those users are never left unmonitored.
        let currentStatus = knownStatus ?? EKEventStore.authorizationStatus(for: .event)
        cachedAuthStatus = currentStatus
        log("Initial authorization status: \(currentStatus.rawValue)")

        guard currentStatus == .notDetermined else {
            log("Authorization status is stable (\(currentStatus.rawValue)) — polling skipped")
            return
        }

        // Status is .notDetermined: the user has never been asked. Start polling so that
        // if another part of the system (or a concurrent app launch) triggers a grant,
        // we detect it promptly.
        authPollingTask = Task { @MainActor in
            var consecutiveUnchangedChecks = 0
            let maxBackoffChecks = 10 // After 10 unchanged checks, stop polling

            while !Task.isCancelled {
                // Check current status
                let polledStatus = EKEventStore.authorizationStatus(for: .event)

                // If status changed, notify and reset backoff
                if let cached = cachedAuthStatus, cached != polledStatus {
                    log("Authorization status changed: \(cached.rawValue) → \(polledStatus.rawValue)")
                    handleAuthorizationStatusChange(from: cached, to: polledStatus)
                    consecutiveUnchangedChecks = 0
                }

                // Determine next check interval based on backoff
                let checkInterval: TimeInterval
                if consecutiveUnchangedChecks < 5 {
                    // First 5 checks: every 0.5 seconds (catches TCC approval quickly)
                    checkInterval = 0.5
                } else if consecutiveUnchangedChecks < maxBackoffChecks {
                    // Next 5 checks: every 2 seconds
                    checkInterval = 2.0
                } else {
                    // After 10 unchanged checks, stop polling until next request
                    break
                }

                consecutiveUnchangedChecks += 1

                try? await Task.sleep(for: .seconds(checkInterval))
            }

            log("Authorization polling stopped")
        }
    }
    
    // MARK: - Store Change Observation

    /// Observes `EKEventStoreChanged` and drops the calendar cache when it fires.
    ///
    /// `getWritableCalendars` caches for five minutes, and nothing previously invalidated
    /// that on an external edit — so a calendar renamed, added, or deleted in Calendar.app
    /// stayed in the picker for up to five minutes, and selecting a deleted one made
    /// `createEvent` throw and silently return false. EventKit posts this notification for
    /// exactly that case; one line of invalidation closes the window.
    private func startObservingStoreChanges() {
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("EKEventStoreChanged received — invalidating calendar cache")
                self.invalidateCalendarCache()
            }
        }
    }

    /// Handles authorization status change.
    private func handleAuthorizationStatusChange(from oldStatus: EKAuthorizationStatus, to newStatus: EKAuthorizationStatus) {
        cachedAuthStatus = newStatus
        
        // If we gained write access, refresh calendars immediately
        let hadWriteAccess = (oldStatus == .fullAccess || oldStatus == .writeOnly)
        let hasWriteAccess = (newStatus == .fullAccess || newStatus == .writeOnly)
        
        if !hadWriteAccess && hasWriteAccess {
            log("Gained write access - refreshing calendars")
            // forceReload bypasses and overwrites the cache outright, so no separate
            // invalidation is needed ahead of it.
            _ = getWritableCalendars(forceReload: true)
        }
        
        // Notify UI components that authorization changed
        AppEventBus.shared.calendarAuthorizationChanged()
        log("Notified UI of authorization change")
    }
    
    /// Restarts authorization polling (call after requesting permissions)
    private func restartAuthorizationPolling() {
        log("Restarting authorization polling")
        startObservingAuthorizationChanges()
    }
    
    // MARK: - Authorization
    
    /// Returns current authorization status, using cached value if available.
    /// This is checked synchronously and uses the cache to avoid repeated queries.
    var authorizationStatus: EKAuthorizationStatus {
        if let cached = cachedAuthStatus {
            return cached
        }
        
        let status = EKEventStore.authorizationStatus(for: .event)
        cachedAuthStatus = status
        return status
    }
    
    /// Checks if the app has write access to calendars.
    /// This is the primary method UI components should use to determine feature availability.
    var hasWriteAccess: Bool {
        let status = authorizationStatus
        return status == .fullAccess || status == .writeOnly
    }
    
    /// Requests calendar access if not already authorized.
    /// Restarts polling to detect when TCC grants permission.
    /// - Returns: Whether write access was granted.
    func requestAccessIfNeeded() async -> Bool {
        // Calendar access is the one capability in this app that reaches outside its own
        // container entirely — a granted authorization writes to the user's real calendar
        // database, which no sandbox path redirect can contain. A debug instance therefore
        // never asks for it. This is belt-and-braces: sandbox preferences come from a
        // fresh suite where `iCalIntegration` is false by default, so nothing should call
        // this in the first place; the guard makes that a property of the code rather than
        // of the default value.
        #if DEBUG
        if DebugSandbox.isActive {
            log("Calendar authorization request suppressed: debug sandbox active")
            return false
        }
        #endif

        let currentStatus = authorizationStatus
        
        // Already have write access.
        if currentStatus == .fullAccess || currentStatus == .writeOnly {
            log("Already authorized (status: \(currentStatus.rawValue))")
            return true
        }
        
        // Need to request authorization.
        log("Requesting calendar authorization...")
        
        // Restart polling BEFORE request to catch quick grants
        restartAuthorizationPolling()
        
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            
            // Force refresh status immediately after request completes
            let newStatus = EKEventStore.authorizationStatus(for: .event)
            
            // If cached status differs, handle the change
            if let cached = cachedAuthStatus, cached != newStatus {
                handleAuthorizationStatusChange(from: cached, to: newStatus)
            } else {
                cachedAuthStatus = newStatus
            }
            
            log("Authorization result: \(granted), status: \(newStatus.rawValue)")
            
            // If granted, invalidate calendar cache to load fresh data.
            if granted {
                // See handleAuthorizationStatusChange: forceReload already replaces the
                // cache, so a preceding invalidateCalendarCache() would be a no-op.
                _ = getWritableCalendars(forceReload: true)
            }
            
            return granted
        } catch {
            log("Authorization request failed: \(error)")
            // Still restart polling in case of async grant
            return false
        }
    }
    
    /// Performs a live (non-cached) authorization check on every popover open
    /// when access has not yet been recognized by the UI.
    ///
    /// Two cases are handled:
    /// - Status is already granted (fullAccess / writeOnly): the cache was stale;
    ///   fire the change handler to update the UI immediately.
    /// - Status is still .notDetermined: TCC may not have committed the grant yet
    ///   (the classic timing gap between requestFullAccessToEvents() returning and
    ///   EKEventStore.authorizationStatus(for:) reflecting it). In this case we
    ///   call requestAccessIfNeeded() on the singleton store, which awaits the real
    ///   TCC result, then updates the cache and fires the event bus.
    func recheckAuthorizationStatus() {
        let liveStatus = EKEventStore.authorizationStatus(for: .event)
        log("Live recheck: status=\(liveStatus.rawValue), cached=\(cachedAuthStatus?.rawValue ?? -1)")
        
        let hasAccess = (liveStatus == .fullAccess || liveStatus == .writeOnly)
        
        if hasAccess {
            // Access is already visible — update the cache and notify the UI
            // if the cached value was stale.
            if let cached = cachedAuthStatus, cached != liveStatus {
                handleAuthorizationStatusChange(from: cached, to: liveStatus)
            } else {
                cachedAuthStatus = liveStatus
                // Even if cached already matched, broadcast so any UI that missed
                // the original notification can re-evaluate.
                AppEventBus.shared.calendarAuthorizationChanged()
            }
        } else if liveStatus == .notDetermined {
            // TCC may not have committed the grant yet. Fire a real async request
            // on the singleton store so we properly await the TCC result.
            // requestAccessIfNeeded() is a no-op if already authorized, so this
            // is safe to call speculatively.
            Task { @MainActor in
                log("Status still notDetermined on recheck — awaiting TCC via requestAccessIfNeeded")
                _ = await requestAccessIfNeeded()
            }
        }
        // For .denied / .restricted there is nothing to poll for; leave as-is.
    }
    
    // MARK: - Calendar Operations
    
    /// Retrieves writable calendars, using cache when valid.
    /// - Parameter forceReload: If true, bypasses cache and loads fresh data.
    /// - Returns: Array of writable calendars, or empty array if unauthorized.
    func getWritableCalendars(forceReload: Bool = false) -> [EKCalendar] {
        // Check authorization first.
        guard hasWriteAccess else {
            log("No write access, returning empty calendar list")
            return []
        }
        
        // Use cache if valid and not forcing reload.
        if !forceReload,
           let cached = cachedCalendars,
           let lastLoad = lastCalendarLoadTime,
           Date().timeIntervalSince(lastLoad) < cacheValidityDuration {
            log("Returning \(cached.count) cached calendars")
            return cached
        }
        
        // Load fresh calendars.
        log("Loading calendars from EventKit...")
        let calendars = eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        
        // Update cache.
        cachedCalendars = calendars
        lastCalendarLoadTime = Date()
        
        log("Loaded \(calendars.count) writable calendars")
        return calendars
    }
    
    /// Invalidates the calendar cache, forcing a reload on next access.
    /// Private: the two former internal call sites both invalidated and then immediately
    /// called getWritableCalendars(forceReload: true), which bypasses and overwrites the
    /// cache anyway, so those invalidations were no-ops and have been removed. The only
    /// caller left is the EKEventStoreChanged observer below, which genuinely needs it.
    /// (A `calendar(withIdentifier:)` lookup also lived here with no callers anywhere in
    /// the project; it has been removed.)
    private func invalidateCalendarCache() {
        log("Invalidating calendar cache")
        cachedCalendars = nil
        lastCalendarLoadTime = nil
    }
    
    // MARK: - Event Operations
    
    /// Creates and saves a calendar event.
    /// - Parameters:
    ///   - title: Event title.
    ///   - startDate: Event start time.
    ///   - endDate: Event end time.
    ///   - calendar: Target calendar.
    /// - Returns: True if event was saved successfully.
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        calendar: EKCalendar
    ) -> Bool {
        // See requestAccessIfNeeded(): the user's calendar is outside every container
        // boundary this app can redirect, so a sandbox instance never writes to it.
        // Guarded independently of the authorization request because authorization may
        // already have been granted to the production instance under the same bundle
        // identifier — in which case `hasWriteAccess` below would be true here too.
        #if DEBUG
        if DebugSandbox.isActive {
            log("Event creation suppressed: debug sandbox active")
            return false
        }
        #endif

        guard hasWriteAccess else {
            log("Cannot create event: no write access")
            return false
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        // Explicitly clear any alarms before saving. EventKit may inherit a default
        // URL-based alarm from the calendar configuration; sandboxed apps are not
        // entitled to set alarm URLs and the attempt produces:
        // "Attempted to set URL on an alarm in a process that is not allowed. Ignoring."
        event.alarms = nil
        
        do {
            try eventStore.save(event, span: .thisEvent)
            log("Successfully created event: \(title)")
            return true
        } catch {
            log("Failed to create event: \(error)")
            return false
        }
    }
    
    // MARK: - Cleanup
    //
    // No deinit. This type is only ever reachable through `static let shared`, so it is
    // never deallocated while the process runs — a deinit canceling authPollingTask or
    // removing storeChangeObserver could not execute, and implying otherwise invites the
    // assumption that instances are disposable. Both the polling task and the notification
    // observation are torn down by process exit.
}
