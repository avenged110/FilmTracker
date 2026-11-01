// MARK: - CalendarPopover.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Add Viewing Event popover for WatchDetails, with its shared form row and the pending-entry
// snapshot that survives a duplicate-date alert. It reacts to calendar permission changes so a
// TCC grant takes effect immediately.

import SwiftUI
import EventKit

// MARK: - Viewing Form Row

/// A labeled row in the viewing-event editors: this popover and the FilmSheet Details tab's
/// date popovers (ViewingDatesTable, 30.20 FSControlHelpers.swift). Both share the 72 pt label
/// column defined here.
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

/// The user's in-progress entry in UnifiedViewingPopover, captured when a duplicate-date
/// collision is detected. macOS closes an open NSPopover when an NSAlert sheet appears over
/// it, destroying the popover's @State. WatchDetails stores this snapshot and passes it back
/// as `initialEntry` when it reopens the popover, so the entry is not lost.
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
    /// Called for every committed viewing, on both the local-only and system-calendar paths.
    /// The calendar path also calls it when event creation fails, so the viewing is still
    /// recorded. This is the only "viewing committed" signal.
    let onDateSelected: (Date, ViewingVersion) -> Void
    /// Called when a duplicate date is detected, before the alert fires and macOS closes this
    /// popover. The parent stores the snapshot and passes it back as `initialEntry` on the next open.
    let onDuplicateDateDetected: (PendingViewingEntry) -> Void
    
    // Authorization state - reactive to permission changes
    @State private var hasCalendarAccess = false
    @State private var isRequestingPermission = false
    
    // Calendar settings. availableCalendars is reloaded in onAppear (see loadCalendars()).
    // selectedCalendar is seeded from initialEntry, so a restored entry keeps its calendar.
    @State private var availableCalendars: [EKCalendar] = []
    @State private var selectedCalendar: EKCalendar?

    // Date and time settings, all seeded from `initialEntry` in the init below.
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
        // `initialEntry` is nil on a fresh open (WatchDetails clears pendingViewingEntry before
        // showing the popover), so each field falls back to its blank default.
        self._selectedDate = State(initialValue: initialEntry?.date ?? Date())
        // No `?? nil` on `initialEntry?.version`: it is already `ViewingVersion?`.
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

    // Base-date (no version code) format for comparing against film.calendarTable entries and
    // extractDatePortion(from:) results. It is StorageDateFormatters.dot, shared with the other
    // viewing-date code, so the "yyyy.MM.dd" strings match exactly.
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
                CustomDateStepper(date: $selectedDate, minDate: releaseDateMin, maxDate: Date())
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
                    
                    TimeStepper(hour: $hour, minute: $minute, isAM: $isAM)
                }
                .disabled(!addToSystemCalendar || !hasCalendarAccess)
                .opacity((addToSystemCalendar && hasCalendarAccess) ? 1.0 : 0.5)
            }
            
            // Calendar picker (only if integration enabled, checkbox true, and has access)
            if iCalIntegrationEnabled {
                ViewingFormRow("Calendar:") {
                    Picker("", selection: $selectedCalendar) {
                        // selectedCalendar is nil before loadCalendars() runs, and also when the
                        // account has no writable calendar. Without a tag for nil, the Picker
                        // matches no option and draws blank. The tag names that state instead.
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
                        // Snapshot the entry first: presenting the alert closes this popover (see PendingViewingEntry).
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
        .frame(width: EntryPopoverMetrics.width)
        .padding(EntryPopoverMetrics.padding)
        .onAppear {
            // updateCalendarAccess() reports whether it already loaded calendars, so this
            // handler does not load them a second time.
            let didLoad = updateCalendarAccess()
            // If integration is on but access is not recognized, recheck live (uncached).
            // This covers a TCC grant that arrived after polling had timed out.
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
                // Same as onAppear: skip the load if updateCalendarAccess already did it.
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

    /// The film's release date, parsed for use as the CustomDateStepper's lower bound.
    /// `nil` when the film's releaseDate field is empty or unparseable, in which case
    /// CustomDateStepper applies no clamp (per its documented no-op contract). Also `nil`
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
        var components = AppCalendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        components.hour = hour24
        components.minute = minute
        
        guard let startDate = AppCalendar.current.date(from: components) else {
            return "--:-- --"
        }
        
        // Calculate end date (start + duration in minutes).
        
        guard let endDate = AppCalendar.current.date(byAdding: .minute, value: durationMinutes, to: startDate) else {
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
    /// their own load rather than repeating it. The access-gained path must not
    /// also load unconditionally, or a single open does the work twice.
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
        if let rememberedID = Preferences.store.string(forKey: Preferences.lastSelectedCalendarIDKey),
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
            // No writable calendar, or the picker is on its untagged "Select…" entry. This is
            // handled like a failed EventKit write: the viewing is recorded, since that is the
            // primary intent, and the failure is surfaced. Returning early left the popover open
            // with no visible result.
            log("Cannot add event - no calendar selected; recording viewing locally only")
            onDateSelected(selectedDate, selectedVersion ?? .none)
            isPresented = false
            AppEventBus.shared.sendAlert(.calendarEventCreationFailed)
            return
        }
        
        // Remember calendar selection.
        Preferences.store.set(calendar.calendarIdentifier, forKey: Preferences.lastSelectedCalendarIDKey)
        
        // Create start date using selected date and time.
        var components = AppCalendar.current.dateComponents([.year, .month, .day], from: selectedDate)
        components.hour = hour24
        components.minute = minute
        
        // A start date that cannot be composed is handled like a missing calendar, for the same
        // reason. It is unreachable in practice, since the components come from a real date and
        // a valid time.
        guard let startDate = AppCalendar.current.date(from: components) else {
            log("Failed to create start date; recording viewing locally only")
            onDateSelected(selectedDate, selectedVersion ?? .none)
            isPresented = false
            AppEventBus.shared.sendAlert(.calendarEventCreationFailed)
            return
        }

        // Calculate end date (start + duration in minutes).

        let endDate = AppCalendar.current.date(byAdding: .minute, value: durationMinutes, to: startDate) ?? startDate
        
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
        
        // The viewing is recorded either way. The calendar event is optional, so a failed
        // EventKit write must not discard the viewing.
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
