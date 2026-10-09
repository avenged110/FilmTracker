// MARK: - CalendarPopover.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Calendar popover components for WatchDetails module with reactive
// authorization handling for immediate TCC permission updates.

import SwiftUI
import EventKit

// MARK: - Viewing Form Row

/// A labeled row in the two viewing-event editors — this file's popover and the FilmSheet
/// Details tab's add/edit date popovers (ViewingDatesTable, 30.20 FSControlHelpers.swift).
/// Both put their labels in the same 72 pt column; this is where that column is defined,
/// rather than in nine copies of the same three modifiers.
struct ViewingFormRow<Content: View>: View {
    /// The label column's width; also what the calendar checkbox row indents by.
    static var labelWidth: CGFloat { 72 }

    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: Self.labelWidth, alignment: .leading)
            content
        }
    }
}

// MARK: - Pending Viewing Entry Snapshot

/// A snapshot of everything the user had entered in UnifiedViewingPopover, captured
/// the instant a duplicate-date collision is detected — just before the "Event
/// Already Exists" alert is fired. macOS automatically closes an open NSPopover as
/// soon as an NSAlert sheet is presented over it, tearing down the popover's own
/// @State along with it; WatchDetails holds onto this snapshot and feeds it back in
/// as `initialEntry` when it reopens the popover once the alert clears, so the
/// reopened popover shows exactly what the user had typed rather than resetting to
/// blank defaults.
struct PendingViewingEntry {
    var date: Date
    var version: ViewingVersion?
    var hour: Int
    var minute: Int
    var isAM: Bool
    var addToSystemCalendar: Bool
    var selectedCalendar: EKCalendar?
}

// MARK: - Unified Viewing Popover

struct UnifiedViewingPopover: View, Loggable {
    nonisolated static let logTag = "[CalendarPopover]"
    
    let film: FilmSnapshot
    @Binding var isPresented: Bool
    /// Called for every committed viewing on both commit paths — the local-only path
    /// and the system-calendar path (which invokes it after the event is created, and
    /// also when creation fails, so the viewing is still recorded in Film Tracker).
    /// This is the single "a viewing was committed" signal; a second `onEventAdded`
    /// callback used to fire alongside it on the calendar path only, which meant the
    /// parent's completion handling ran twice for one viewing.
    let onDateSelected: (Date, ViewingVersion) -> Void
    /// Called the instant a duplicate-date collision is detected, with a full
    /// snapshot of the current entry — immediately before the alert is fired (and,
    /// as a consequence, the instant before macOS auto-closes this popover). The
    /// parent (WatchDetails) stores this snapshot and passes it back in as
    /// `initialEntry` on the next open, restoring the user's in-progress entry.
    let onDuplicateDateDetected: (PendingViewingEntry) -> Void
    
    // Authorization state - reactive to permission changes
    @State private var hasCalendarAccess = false
    @State private var isRequestingPermission = false
    
    // Calendar settings — availableCalendars is always recomputed fresh in
    // onAppear (see loadCalendars()); selectedCalendar is seeded from
    // initialEntry below so a restored entry keeps whatever calendar the user
    // had manually chosen, rather than falling back to the remembered default.
    @State private var availableCalendars: [EKCalendar] = []
    @State private var selectedCalendar: EKCalendar?

    // Date/time settings — all seeded from `initialEntry` at init time (see the
    // custom init below) so a popover reopened after a duplicate-date rejection
    // restores the user's prior entry instead of resetting to blank defaults.
    @State private var selectedDate: Date
    @State private var selectedVersion: ViewingVersion?
    @State private var hour: Int
    @State private var minute: Int
    @State private var isAM: Bool
    @State private var addToSystemCalendar: Bool

    init(film: FilmSnapshot,
         isPresented: Binding<Bool>,
         initialEntry: PendingViewingEntry? = nil,
         onDateSelected: @escaping (Date, ViewingVersion) -> Void,
         onDuplicateDateDetected: @escaping (PendingViewingEntry) -> Void) {
        self.film = film
        self._isPresented = isPresented
        self.onDateSelected = onDateSelected
        self.onDuplicateDateDetected = onDuplicateDateDetected
        // `initialEntry` is nil for a genuine fresh open (WatchDetails clears its
        // pendingViewingEntry before showing the popover from the "Add Viewing
        // Event" button), in which case every field falls back to the same blank
        // defaults this view has always opened with.
        self._selectedDate = State(initialValue: initialEntry?.date ?? Date())
        // No `?? nil` on the two optional-valued fields below: `initialEntry?.version` is
        // already `ViewingVersion?`, so coalescing it with nil could never change it.
        self._selectedVersion = State(initialValue: initialEntry?.version)
        self._hour = State(initialValue: initialEntry?.hour ?? 7)
        self._minute = State(initialValue: initialEntry?.minute ?? 0)
        self._isAM = State(initialValue: initialEntry?.isAM ?? false) // Default to PM
        self._addToSystemCalendar = State(initialValue: initialEntry?.addToSystemCalendar ?? true)
        self._selectedCalendar = State(initialValue: initialEntry?.selectedCalendar)
    }
    
    // Cached DateFormatter for end time display (avoids per-evaluation allocation).
    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    // Base-date (no version code) comparison against film.calendarTable entries, which
    // must match the "yyyy.MM.dd" convention used throughout the app so string
    // comparisons against extractDatePortion(from:) results are exact. That is now the
    // shared StorageDateFormatters.dot — the same object WatchDetails and
    // ViewingDatesTable write through — so "must match" is satisfied by identity.
    private static let baseDateFormatter = StorageDateFormatters.dot
    
    // Preference for calendar integration
    @AppStorage(preference: Preferences.iCalIntegrationKey)
    private var iCalIntegrationEnabled: Bool
    
    // Computed: Show full calendar features if preference enabled AND we have access
    private var showFullCalendarFeatures: Bool {
        iCalIntegrationEnabled && hasCalendarAccess
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header (centered)
            Text("Add Viewing Event")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            
            // Film details
            VStack(alignment: .leading, spacing: 4) {
                Text("\(film.name) (\(film.releaseYear))")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !film.effectiveDuration.isEmpty {
                    if showFullCalendarFeatures && addToSystemCalendar {
                        Text("\(formattedDuration), Ends: \(calculatedEndTime)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .id("endTime-\(hour)-\(minute)-\(isAM)")
                    } else {
                        Text(formattedDuration)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Divider()
            
            // Date picker
            ViewingFormRow("Select date:") {
                CustomDatePicker(date: $selectedDate, minDate: releaseDateMin)
            }
            
            // Version picker
            ViewingFormRow("Version:") {
                Picker("", selection: $selectedVersion) {
                    Text("Select…").tag(nil as ViewingVersion?)
                    ForEach(ViewingVersion.allCases.filter { $0 != .none }, id: \.self) { version in
                        Text(version.displayName).tag(version as ViewingVersion?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 183)
            }
            
            // System calendar checkbox (only if integration enabled)
            if iCalIntegrationEnabled {
                HStack(spacing: 7) {
                    Spacer()
                        .frame(width: ViewingFormRow<EmptyView>.labelWidth)
                    HStack(spacing: 6) {
                        Toggle("", isOn: $addToSystemCalendar)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(!hasCalendarAccess)
                            .onChange(of: addToSystemCalendar) { _, newValue in
                                if newValue && !hasCalendarAccess {
                                    // User wants to add to calendar but we don't have permission
                                    Task {
                                        await requestCalendarPermission()
                                    }
                                }
                            }
                        
                        Text("Add Event to System Calendar")
                            .font(.system(size: 12))
                            .foregroundStyle(hasCalendarAccess ? .primary : .secondary)
                        
                        // Show requesting indicator
                        if isRequestingPermission {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
            
            // Time picker (only if integration enabled, calendar checkbox true, and has access)
            if iCalIntegrationEnabled {
                ViewingFormRow("Time:") {
                    
                    TimePicker(hour: $hour, minute: $minute, isAM: $isAM)
                }
                .disabled(!addToSystemCalendar || !hasCalendarAccess)
                .opacity((addToSystemCalendar && hasCalendarAccess) ? 1.0 : 0.5)
            }
            
            // Calendar picker (only if integration enabled, checkbox true, and has access)
            if iCalIntegrationEnabled {
                ViewingFormRow("Calendar:") {
                    Picker("", selection: $selectedCalendar) {
                        // `selectedCalendar` is Optional and legitimately nil in two
                        // states: before loadCalendars() has run (access not yet
                        // granted, or the popover has only just appeared), and
                        // permanently when the account exposes no writable calendar for
                        // it to pick. Without a tagged entry for nil, the Picker's
                        // selection matches no option in either state — SwiftUI reports
                        // that as an invalid selection and draws the control blank, with
                        // nothing to explain why. Tagging it names the state instead.
                        // The version picker above does the same with its "Select…" row.
                        Text(availableCalendars.isEmpty ? "No calendars available" : "Select…")
                            .tag(nil as EKCalendar?)
                        ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                            HStack {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 8, height: 8)
                                Text(calendar.title)
                            }
                            .tag(calendar as EKCalendar?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 183)
                }
                .disabled(!addToSystemCalendar || !hasCalendarAccess)
                .opacity((addToSystemCalendar && hasCalendarAccess) ? 1.0 : 0.5)
            }
            
            Divider()
            
            // Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .controlSize(.regular)
                
                Spacer()
                
                Button("Add") {
                    guard !isDuplicateViewingDate(selectedDate) else {
                        // Capture the in-progress entry before this popover is torn
                        // down — macOS closes an open NSPopover the instant the
                        // alert's NSAlert sheet is presented, so this snapshot (not
                        // the popover's own soon-to-be-destroyed @State) is what
                        // restores the user's entry when WatchDetails reopens it.
                        onDuplicateDateDetected(PendingViewingEntry(
                            date: selectedDate,
                            version: selectedVersion,
                            hour: hour,
                            minute: minute,
                            isAM: isAM,
                            addToSystemCalendar: addToSystemCalendar,
                            selectedCalendar: selectedCalendar
                        ))
                        AppEventBus.shared.sendAlert(.duplicateViewingDate)
                        return
                    }
                    if showFullCalendarFeatures && addToSystemCalendar {
                        addEventAndViewing()
                    } else {
                        onDateSelected(selectedDate, selectedVersion ?? .none)
                        isPresented = false
                    }
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 290)
        .padding(16)
        .onAppear {
            // `updateCalendarAccess()` loads the calendars itself on the one path where
            // it flips access on with the checkbox already ticked, so it reports whether
            // it did. Without that, this handler's own load below ran a second time for
            // the same open — `getWritableCalendars()` is cached but XPC-backed, and the
            // duplicate also re-ran the remembered-calendar resolution underneath it.
            let didLoad = updateCalendarAccess()
            // If calendar integration is enabled but access is still not recognized,
            // do a live (non-cached) recheck and restart polling on every open.
            // This self-heals the race where the TCC grant arrived after the
            // polling loop had already timed out and stopped.
            if iCalIntegrationEnabled && !hasCalendarAccess {
                EventKitManager.shared.recheckAuthorizationStatus()
            }
            if hasCalendarAccess && !didLoad {
                loadCalendars()
            }
        }
        // React to calendar authorization changes
        .onReceive(AppEventBus.shared.viewEvents) { event in
            if case .calendarAuthorizationChanged = event {
                log("Received calendar authorization change notification")
                // Same one-load-per-event contract as onAppear above: skip this
                // handler's load when updateCalendarAccess already performed it.
                let didLoad = updateCalendarAccess()
                if hasCalendarAccess && !didLoad {
                    loadCalendars()
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var formattedDuration: String {
        RSBHelpers.formattedDuration(from: film.effectiveDuration)
    }

    /// The runtime the calendar event spans, in whole minutes — read the same way as
    /// `formattedDuration`, so the duration shown, the "Ends:" readout and the event
    /// created can never disagree. 0 when there is no usable runtime.
    private var durationMinutes: Int {
        DurationHelpers.storedMinutes(film.effectiveDuration) ?? 0
    }

    /// The film's release date, parsed for use as the CustomDatePicker's lower bound.
    /// `nil` when the film's releaseDate field is empty or unparseable, in which case
    /// CustomDatePicker applies no clamp (per its documented no-op contract). Also `nil`
    /// when Preferences.overrideDateClamp is true, allowing the user to temporarily add
    /// viewing events dated prior to the film's release date.
    private var releaseDateMin: Date? {
        guard !Preferences.overrideDateClamp else { return nil }
        return parseDate(from: film.releaseDate)
    }

    /// True when `date` falls on the same calendar day (ignoring any version code) as
    /// an entry already present in film.calendarTable. Mirrors the base-date comparison
    /// WatchDetails.addViewing() performs before committing, so the popover can reject
    /// the collision up front — with a visible alert — instead of silently no-oping.
    private func isDuplicateViewingDate(_ date: Date) -> Bool {
        let candidateBaseDate = Self.baseDateFormatter.string(from: date)
        return film.calendarTable.contains { extractDatePortion(from: $0) == candidateBaseDate }
    }
    
    /// Converts the current 12-hour picker state (hour, isAM) to 24-hour format.
    private var hour24: Int {
        if isAM && hour == 12 { return 0 }
        if !isAM && hour != 12 { return hour + 12 }
        return hour
    }
    
    private var calculatedEndTime: String {
        // Create start date using selected date and time
        var components = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        components.hour = hour24
        components.minute = minute
        
        guard let startDate = Calendar.current.date(from: components) else {
            return "--:-- --"
        }
        
        // Calculate end date (start + duration in minutes).
        
        guard let endDate = Calendar.current.date(byAdding: .minute, value: durationMinutes, to: startDate) else {
            return "--:-- --"
        }
        
        // Format end time without seconds
        return Self.endTimeFormatter.string(from: endDate)
    }
    
    // MARK: - Authorization Management
    
    /// Updates the calendar access state from EventKitManager.
    ///
    /// Returns whether it loaded the calendar list as part of that update, so the two
    /// callers — `onAppear` and the `.calendarAuthorizationChanged` handler — can skip
    /// their own load rather than repeating it. Both previously called this and then
    /// loaded unconditionally, so the one path that gains access with the checkbox
    /// already ticked did the work twice for a single open.
    @MainActor
    @discardableResult
    private func updateCalendarAccess() -> Bool {
        let newAccessState = EventKitManager.shared.hasWriteAccess

        guard newAccessState != hasCalendarAccess else { return false }

        log("Calendar access changed: \(hasCalendarAccess) → \(newAccessState)")
        hasCalendarAccess = newAccessState

        // If we gained access and the checkbox is on, load calendars
        guard newAccessState && addToSystemCalendar else { return false }
        loadCalendars()
        return true
    }
    
    /// Requests calendar permission from the system
    @MainActor
    private func requestCalendarPermission() async {
        guard !isRequestingPermission else { return }
        
        log("Requesting calendar permission")
        isRequestingPermission = true
        
        let granted = await EventKitManager.shared.requestAccessIfNeeded()
        
        isRequestingPermission = false
        
        if granted {
            log("Calendar permission granted")
            hasCalendarAccess = true
            loadCalendars()
        } else {
            log("Calendar permission denied")
            hasCalendarAccess = false
            // Turn off the checkbox since we don't have access
            addToSystemCalendar = false
        }
    }
    
    // MARK: - Calendar Operations
    
    @MainActor
    private func loadCalendars() {
        guard hasCalendarAccess else {
            log("Cannot load calendars - no access")
            return
        }
        
        // Get calendars from manager (uses cache when valid, reduces XPC calls).
        availableCalendars = EventKitManager.shared.getWritableCalendars()
        log("Loaded \(availableCalendars.count) calendars")
        
        // Only auto-select a calendar if nothing is already selected. A non-nil
        // value here means either the user actively chose one this session, or it
        // was restored via initialEntry after a duplicate-date rejection — either
        // way, it must not be silently overridden by the remembered/default pick.
        guard selectedCalendar == nil else { return }

        // Try to load remembered calendar.
        if let rememberedID = Preferences.store.string(forKey: "LastSelectedCalendarID"),
           let remembered = availableCalendars.first(where: { $0.calendarIdentifier == rememberedID }) {
            selectedCalendar = remembered
            log("Restored remembered calendar: \(remembered.title)")
        } else if let first = availableCalendars.first {
            selectedCalendar = first
            log("Selected default calendar: \(first.title)")
        }
    }
    
    @MainActor
    private func addEventAndViewing() {
        guard let calendar = selectedCalendar else {
            // No calendar to write to — either the account exposes none that is
            // writable, or the user left the picker on its untagged "Select…" entry.
            // This is the same situation as a failed EventKit write, and is handled
            // identically for the same reason: recording the viewing is the user's
            // primary intent and the calendar event is the optional half, so the
            // viewing is committed and the failure is surfaced. Returning here without
            // committing (as this did) left the popover open and the "Add" click with
            // no visible result whatsoever — the exact dead end the creation-failure
            // path below was already corrected for.
            log("Cannot add event - no calendar selected; recording viewing locally only")
            onDateSelected(selectedDate, selectedVersion ?? .none)
            isPresented = false
            AppEventBus.shared.sendAlert(.calendarEventCreationFailed)
            return
        }
        
        // Remember calendar selection.
        Preferences.store.set(calendar.calendarIdentifier, forKey: "LastSelectedCalendarID")
        
        // Create start date using selected date and time.
        var components = Calendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        components.hour = hour24
        components.minute = minute
        
        // A start date that cannot be composed is handled exactly as a missing calendar
        // and a failed EventKit write are, and for the same reason: the viewing is the
        // user's primary intent and the calendar event is the optional half, so the
        // viewing is committed, the popover closes, and the failure is surfaced.
        // Returning bare (as this did) left the popover open with the "Add" click having
        // produced no visible result at all — the one remaining instance of the dead end
        // the other two paths were already corrected for. Unreachable in practice, since
        // the components come from a real date plus a validated 24-hour time; kept
        // consistent rather than left as the odd path out.
        guard let startDate = Calendar.current.date(from: components) else {
            log("Failed to create start date; recording viewing locally only")
            onDateSelected(selectedDate, selectedVersion ?? .none)
            isPresented = false
            AppEventBus.shared.sendAlert(.calendarEventCreationFailed)
            return
        }

        // Calculate end date (start + duration in minutes).

        let endDate = Calendar.current.date(byAdding: .minute, value: durationMinutes, to: startDate) ?? startDate
        
        log("Creating event: Start=\(startDate), Duration=\(durationMinutes)min, End=\(endDate)")
        
        // Create event with title including year.
        // No empty "()" for a film without a release year.
        let eventTitle = film.releaseYear.isEmpty ? film.name : "\(film.name) (\(film.releaseYear))"
        
        // Use EventKitManager to create event (reduces XPC overhead).
        let success = EventKitManager.shared.createEvent(
            title: eventTitle,
            startDate: startDate,
            endDate: endDate,
            calendar: calendar
        )
        
        // The viewing is recorded in Film Tracker either way. Event creation is the
        // optional half of this action — the user's primary intent is to log that they
        // watched the film — so a failed EventKit write must not also discard the
        // viewing. Previously the failure branch did nothing at all: the popover stayed
        // open, no viewing was recorded, and the only trace was this log line, so the
        // user saw their "Add" click produce no visible result whatsoever.
        log(success ? "Event created successfully" : "Failed to create event — recording viewing locally only")

        // Add viewing date to FilmTracker (just the date, not time) with version.
        onDateSelected(selectedDate, selectedVersion ?? .none)
        isPresented = false

        if !success {
            // Fired after the commit above so the viewing is already saved by the time
            // the alert is presented (presenting an NSAlert tears this popover down).
            AppEventBus.shared.sendAlert(.calendarEventCreationFailed)
        }
    }
}
