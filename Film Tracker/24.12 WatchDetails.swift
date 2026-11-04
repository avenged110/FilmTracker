// MARK: - WatchDetails.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// RightSidebar's modular "WatchDetails" tab, module 02.

import SwiftUI
import AppKit
import EventKit

struct WatchDetails: View, Loggable {
    nonisolated static let logTag = "[RSB_WatchDetails]"

    @Environment(\.sidebarFilm) private var film: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    
    @State private var showViewingPopover = false
    @State private var calendarAccessStatus: EKAuthorizationStatus = .notDetermined
    @State private var showViewingCheckmark = false
    /// Pending reset of showViewingCheckmark, retained so a second confirmation can
    /// cancel the first one's timer instead of racing it. See showCheckmarkFeedback().
    @State private var checkmarkResetTask: Task<Void, Never>?

    /// Snapshot of the popover's entry, taken when "Add" hits a date that already exists. macOS closes the popover
    /// when the "Event Already Exists" alert appears, which tears down its @State. The reopened popover (fired by
    /// .reopenViewingEventPopover) restores from this. `nil` for a fresh open (see handleViewingButtonClick).
    @State private var pendingViewingEntry: PendingViewingEntry?

    /// The film a click is waiting on calendar permission for, while the request is out.
    /// Cleared by a change of film, so a grant that resolves after the user has moved on
    /// does not open the popover for whatever film is showing by then.
    @State private var permissionPendingFilmID: UUID?

    /// @AppStorage monitors for preference key changes.
    @AppStorage(preference: Preferences.iCalIntegrationKey)
        private var iCalIntegration: Bool
    @AppStorage(preference: Preferences.defaultRotationThresholdKey)
        private var defaultRotationThreshold: Int
    /// Read through @AppStorage, not `Preferences.showWatchDetailsAnnotationGlyphs`, so toggling it in Settings
    /// redraws this module at once. A static read would not schedule that redraw. The glyph maps below are instance
    /// members for the same reason, since a static cannot read a view's @AppStorage.
    @AppStorage(preference: Preferences.showWatchDetailsAnnotationGlyphsKey)
        private var showAnnotationGlyphs: Bool
    @AppStorage(preference: Preferences.manualExtQueryKey)
        private var manualExtQuery: Bool
    
    // MARK: - Derived Display Values
    ///
    /// Values are computed from the film on each render, not cached in @State. A copy written from onChange would
    /// render the module twice per new film, first with the old values. Layout dominates the per-selection cost, so
    /// that extra pass costs more than the string work it saves. A derived value cannot go stale: a film or
    /// `defaultRotationThreshold` change invalidates the view and the values are recomputed with it. Changes that
    /// invalidate nothing by themselves (a midnight rollover, or a queue change that leaves `lastModified` untouched)
    /// are covered by `externalRefreshToken` below.
    ///
    /// `effectiveThreshold` is a local inside calculateRotationData. No view reads it, since the threshold already
    /// appears in `headerTitle`.

    /// Bumped by events that change what these values read without altering the film or any observed preference,
    /// so nothing else would schedule the re-render. Read once in `body` to make the dependency explicit.
    @State private var externalRefreshToken = 0

    private var cachedLastWatched: String {
        guard let film else { return "" }
        guard !film.lastWatched.isEmpty else {
            return film.watched ? "Unknown date" : "Unwatched"
        }
        return formatDateWithTimeAgo(film.lastWatched)
    }

    private var cachedLastWatchedIsPlaceholder: Bool {
        film?.lastWatched.isEmpty ?? true
    }

    private var cachedRotationData: RotationData {
        /// `film.rotationThreshold` falls back to `Preferences.defaultRotationThreshold`, a static, not this @AppStorage
        /// mirror. A Settings change alters neither the film nor its lastModified, so this read is what invalidates the
        /// view for it. Removing it as "unused" would break the Settings-to-sidebar update.
        _ = defaultRotationThreshold
        /// Read through CurrentDay, as the Source field is, so the countdown ticks down and
        /// turns into "Ready for viewing" when the day changes without anything else changing.
        let today = CurrentDay.shared.today
        return film.map { calculateRotationData(for: $0, today: today) } ?? RotationData()
    }

    /// The Source field's display string plus its three branch-derived companions
    /// (disc glyph, "available for purchase" suffix, "Region B locked" suffix). All
    /// four come from a single RSBHelpers.sourceDisplay(for:) call so they cannot
    /// disagree about which release the field is describing.
    private var cachedSourceDisplay: RSBHelpers.SourceDisplay {
        /// Read through CurrentDay so an upcoming release's purchase note turns into
        /// "Available for purchase" on its release day without anything else changing.
        let today = CurrentDay.shared.today
        return film.map { RSBHelpers.sourceDisplay(for: $0, today: today) } ?? RSBHelpers.SourceDisplay()
    }

    private var cachedAverageBetweenViewings: String {
        film.map { calculateAverageBetweenViewings(for: $0) } ?? ""
    }

    private var cachedViewCountData: (formattedValue: String, isPlaceholder: Bool) {
        film.map { calculateViewCountData(for: $0) } ?? ("None recorded", true)
    }

    /// Used solely by averageBetweenViewingsSection to distinguish "None recorded"
    /// (0 entries) from "Insufficient data" (any entries present, but fewer than two
    /// usable dates among them).
    private var cachedCalendarTableCount: Int {
        film?.calendarTable.count ?? 0
    }

    private var cachedDuration: String {
        film.map { RSBHelpers.formattedDuration(from: $0.duration) } ?? ""
    }

    /// Abbreviated form of the original duration, used only in the parenthetical
    /// suffix when an edited duration is also present: "(originally 2 hr. 1 min.)".
    private var cachedDurationAbbreviated: String {
        film.map { RSBHelpers.formattedDurationAbbreviated(from: $0.duration) } ?? ""
    }

    /// Whether the edited duration is worth showing at all: it is the runtime that
    /// applies (`FilmSnapshot.effectiveDuration` — edited, and a positive value) and it
    /// differs from the regular duration, since identical values would make the
    /// parenthetical suffix say nothing.
    private var hasDistinctEditedDuration: Bool {
        guard let film else { return false }
        return film.effectiveDuration != film.duration
    }

    /// The formatted edited duration, non-empty only when it applies and differs from the regular duration. It is
    /// shown as the primary value, with the regular duration in an "(originally X)" parenthetical.
    private var cachedEditedDuration: String {
        guard hasDistinctEditedDuration, let film else { return "" }
        return RSBHelpers.formattedDuration(from: film.editedDuration)
    }

    /// The abbreviated spelling of `cachedEditedDuration`, offered to `fittingValueRow`
    /// as the shorter candidate.
    private var cachedEditedDurationAbbreviated: String {
        guard hasDistinctEditedDuration, let film else { return "" }
        return RSBHelpers.formattedDurationAbbreviated(from: film.editedDuration)
    }

    /// Local appearance parameters.
    private let buttonFontSize = CGFloat(12)
    
    /// The shared "yyyy.MM.dd" formatter. calendarTable entries are stored in this format and compared as strings
    /// against what CalendarPopover and ViewingDatesTable produce. All three use this one object, so the formats match.
    private static let viewingDateFormatter = StorageDateFormatters.dot
    
    var body: some View {
        /// Establishes the dependency described on `externalRefreshToken`.
        let _ = externalRefreshToken
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                /// Action buttons row: "Add Viewing Event" (expands/contracts) + optional
                /// Web query button.
                HStack(spacing: 8) {
                    /// "Add Viewing Event" — expands to fill available width when the
                    /// Web query button is hidden, contracting smoothly when it appears.
                    Button(action: {
                        handleViewingButtonClick()
                    }) {
                        HStack(spacing: 6) {
                            /// Fixed-width container for icon to prevent text shifting
                            ZStack {
                                Image(systemName: showViewingCheckmark ? "checkmark.circle.fill" : "calendar.badge.plus")
                                    .contentTransition(.symbolEffect(.replace))
                                    /// The symbol swap animates here, scoped to this value. A transaction-wide animation would also
                                    /// animate the tab relayout that the same turn triggers, so the modules would visibly slide.
                                    .animation(.smooth, value: showViewingCheckmark)
                                    .font(.system(size: buttonFontSize))
                                    .frame(width: 16, alignment: .center)
                            }
                            
                            Text("Add Viewing Event")
                                .font(.system(size: buttonFontSize))
                        }
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(viewingButtonHelpText)
                    .popover(isPresented: $showViewingPopover, arrowEdge: .leading) {
                        UnifiedViewingPopover(
                            film: film,
                            isPresented: $showViewingPopover,
                            initialEntry: pendingViewingEntry,
                            onDateSelected: { selectedDate, selectedVersion in
                                addViewing(film: film, date: selectedDate, version: selectedVersion)
                                showCheckmarkFeedback()
                            },
                            onDuplicateDateDetected: { snapshot in
                                pendingViewingEntry = snapshot
                            }
                        )
                    }
                    
                    /// External Web query menu button — shown only when
                    /// Preferences.manualExtQuery is true.
                    if manualExtQuery {
                        let hasIMDbID = film.externalIdentifiers.indices.contains(0) &&
                            !film.externalIdentifiers[0].trimmingCharacters(in: .whitespaces).isEmpty
                        let hasBlurayID = film.externalIdentifiers.indices.contains(1) &&
                            !film.externalIdentifiers[1].trimmingCharacters(in: .whitespaces).isEmpty
                        Menu {
                            Button(hasIMDbID ? "Open on IMDb.com" : "Search IMDb.com") {
                                QueryHandoff.open(filmName: film.name,
                                                  externalIdentifiers: film.externalIdentifiers,
                                                  target: .imdb,
                                                  logHandler: { Self.log($0) })
                            }
                            Button(hasBlurayID ? "Open on Blu-ray.com" : "Search Blu-ray.com") {
                                QueryHandoff.open(filmName: film.name,
                                                  externalIdentifiers: film.externalIdentifiers,
                                                  target: .bluray,
                                                  logHandler: { Self.log($0) })
                            }
                        } label: {
                            PrivateSymbol.image(named: "globe.badge.magnifyingglass")
                                .frame(alignment: .center)
                        }
                        .fixedSize()
                        .menuIndicator(.hidden)
                        .controlSize(.large)
                        .help("Search for this film on the Web in the default browser")
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.25), value: manualExtQuery)
                
                /// "Last Watched" section (combined date and time ago).
                lastWatchedSection
                
                /// Full-width section: "Next Up for Rotation"
                nextUpForRotationSection
                
                /// Two-column section: "Recorded View Count" and "Average Between Viewings".
                HStack(spacing: 12) {
                    recordedViewCountSection
                    averageBetweenViewingsSection
                }
                
                /// Full-width "Duration" section.
                durationSection
                
                /// "Source" section.
                sourceSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 0)
            .onAppear {
                checkCalendarAccess()
            }
            .onDisappear {
                /// Cancel the pending checkmark reset on dismount, as RightSidebar does for its resolutionTask and
                /// swipeResetTask. Re-entry is covered by the cancel() at the top of showCheckmarkFeedback().
                checkmarkResetTask?.cancel()
                checkmarkResetTask = nil
            }
            /// Display values are derived from the film as it renders, so a new film never shows the previous one's
            /// figures. This handler only resets transient state and logs.
            ///
            /// `initial: true` logs once per fresh mount and skips the reset on that call: equal old and new values
            /// fail the id guard, and no earlier film's popover can be open. onAppear and this handler both fire per
            /// mount. The log reads the authorization status directly, since `calendarAccessStatus` may not be set yet.
            /// A genuine double mount still shows as two lines.
            .onChange(of: film, initial: true) { oldFilm, newFilm in
                /// The sidebar reuses tab content across films, so reset transient state explicitly on a real id change.
                /// An in-place edit of the same film (a rating, a new viewing) must not dismiss the popover being used.
                if oldFilm.id != newFilm.id {
                    showViewingPopover = false
                    pendingViewingEntry = nil
                    permissionPendingFilmID = nil
                    checkmarkResetTask?.cancel()
                    checkmarkResetTask = nil
                    showViewingCheckmark = false
                }

                let liveCalendarStatus = EventKitManager.shared.authorizationStatus.rawValue
                Self.log("Film changed/appeared: \(newFilm.name) (calendar access status: \(liveCalendarStatus))")
            }
            .onReceive(AppEventBus.shared.viewEvents) { event in
                switch event {
                case .calendarAuthorizationChanged:
                    calendarAccessStatus = EventKitManager.shared.authorizationStatus
                    Self.log("Calendar authorization updated: \(calendarAccessStatus.rawValue)")
                case .rightSidebarDidStartLiveScroll:
                    /// Dismiss the popover synchronously when a sidebar live scroll starts, before the content re-lays
                    /// out and the popover can chase the moving anchor (SidebarScrollView's onScrollWillStart fires this).
                    /// Guarded on showViewingPopover to avoid redundant mutations.
                    if showViewingPopover { showViewingPopover = false }
                case .smartListsRecalculated:
                    /// SmartLists fires this at midnight. Date-relative strings ("Today" → "Yesterday", "X months away")
                    /// depend on the date, which nothing else observes, so this must force a re-render.
                    externalRefreshToken &+= 1
                    Self.log("Midnight rollover: refreshed date-relative cached values for \(film.name)")
                default:
                    break
                }
            }
            .onReceive(AppEventBus.shared.uiCommands) { command in
                guard case .reopenViewingEventPopover = command else { return }
                /// The system closed the popover when the duplicate-date alert appeared. pendingViewingEntry lets it
                /// reopen with the same entry.
                showViewingPopover = true
            }
            .onReceive(AppEventBus.shared.listEvents) { event in
                /// Queue membership changes (drag between Up Next, Soon, and Later, or removal) leave the film's
                /// lastModified alone, so onChange(of: film) does not fire. Refresh here so the "in the '<Section>'
                /// Queue" clause never goes stale.
                guard case .membershipChanged(let listID) = event, FilmQueue.isInternalList(listID) else { return }
                externalRefreshToken &+= 1
            }
        }
    }
    
    // MARK: - Custom Section Builders (for placeholder styling)

    /// Builders below render only from the derived `cached…` values, never the live snapshot. That is why they
    /// are parameterless computed properties.
    /// The "Last Watched" field: the viewing date and its relative-time clause. It is built from `sectionHeader`
    /// and `fittingValueRow`, so the time units can shorten when the full text would wrap. "November 04, 2021
    /// (4 years 4 months ago)" overruns a 300 pt sidebar, while "(4 yr. 4 mo. ago)" fits. The abbreviation is only
    /// offered. `fittingValueRow` uses it when the full text does not fit on one line, and wraps the full text if
    /// even the short form needs two. Placeholder values ("Unwatched", "Unknown date") have no parenthetical, so
    /// they are unchanged.
    @ViewBuilder
    private var lastWatchedSection: some View {
        let value = cachedLastWatched
        let isPlaceholder = cachedLastWatchedIsPlaceholder
        let color: Color = isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary

        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Last Watched")
            RSBHelpers.fittingValueRow(
                full: Text(value).foregroundStyle(color),
                abbreviations: SidebarTextAbbreviation.dateValueLadder(for: value)
                    .map { Text($0).foregroundStyle(color) },
                isPlaceholder: isPlaceholder,
                glyph: lastWatchedGlyph(value: value, isPlaceholder: isPlaceholder),
                glyphColor: glyphTint(isPlaceholder: isPlaceholder)
            )
        }
    }

    /// The foreground for the rotation field, matching `RSBHelpers.valueRow`'s placeholder rule. It is needed here
    /// because `fittingValueRow` takes a pre-styled `Text`, which moves the color decision to the caller.
    ///
    /// It takes the placeholder flag rather than reading `cachedRotationData`. That data is derived, so reading it
    /// here would re-run `calculateRotationData` for every entry of the abbreviation ladder. Passing the one flag it
    /// needs keeps the computation to one per render.
    private func rotationValueColor(isPlaceholder: Bool) -> Color {
        isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary
    }

    /// The "Next Up for Rotation" field: the countdown value, then each subordinate note on its own row, in the
    /// order value, special-sorting tags, Film Queue membership.
    ///
    /// Each note is its own row. A combined clause would wrap across lines and need mixed-style Text to keep
    /// the colors apart. Separate rows avoid both, and match the one-header-many-rows shape of
    /// `RSBHelpers.searchableItemSection`.
    ///
    /// This builder needs no placeholder guard of its own: `calculateRotationData`
    /// decides which notes apply. "Blacklisted"/"Ignored" return with no notes at all,
    /// the queue note is gated on `!isPlaceholder`, and the special-sorting rows are
    /// deliberately not — an "Unknown" countdown still shows its parameter.
    @ViewBuilder
    private var nextUpForRotationSection: some View {
        let rotationData = cachedRotationData
        let valueColor = rotationValueColor(isPlaceholder: rotationData.isPlaceholder)

        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader(rotationData.headerTitle)
            /// Same overflow-driven abbreviation as "Last Watched" above, and for the same
            /// string shape: "September 2029 (3 years 7 months away)" is a month label plus
            /// a relative-time clause. The other formattedValue shapes this field produces
            /// ("Ready for viewing", "Blacklisted", "Ignored", "Unknown") have no
            /// parenthetical at all, so no alternative is offered for them.
            RSBHelpers.fittingValueRow(
                full: Text(rotationData.formattedValue).foregroundStyle(valueColor),
                abbreviations: SidebarTextAbbreviation
                    .dateValueLadder(for: rotationData.formattedValue)
                    .map { Text($0).foregroundStyle(valueColor) },
                isPlaceholder: rotationData.isPlaceholder,
                glyph: rotationValueGlyph(rotationData.formattedValue),
                glyphColor: glyphTint(isPlaceholder: rotationData.isPlaceholder)
            )
            ForEach(rotationData.specialSortingNotes, id: \.self) { note in
                RSBHelpers.annotationRow(note, glyph: glyph(forSpecialSorting: note))
            }
            if let queueNote = rotationData.queueNote {
                RSBHelpers.annotationRow(queueNote, glyph: gatedGlyph(Self.queueNoteGlyph))
            }
        }
    }
    
    /// Everything the "Next Up for Rotation" section renders. The notes are separate, complete strings, one row
    /// each, and the struct is style-free: the view applies all styling.
    struct RotationData {
        var headerTitle: String = ""
        var formattedValue: String = ""
        var isPlaceholder: Bool = true
        /// One entry per active special-sorting tag, in declaration order. Rendered as
        /// one annotation row each, directly beneath the value row.
        var specialSortingNotes: [String] = []
        /// "In the "<Section>" Queue" when the film sits in an internal Film Queue
        /// section; `nil` otherwise. Rendered last, beneath any special-sorting rows.
        var queueNote: String?
    }

    /// The fixed "Next Up for Rotation" values `calculateRotationData` writes and
    /// `rotationValueGlyph` matches on — one spelling each, so the two cannot drift.
    private enum RotationValue {
        static let blacklisted = "Blacklisted"
        static let ignored = "Ignored"
        static let ready = "Ready for viewing"
        static let unknown = "Unknown"
    }

    /// Helper to calculate rotation data.
    private func calculateRotationData(for film: FilmSnapshot, today: Date) -> RotationData {
        /// Blacklisted and Ignored take display priority over the countdown, even when "Waiting for edit" or
        /// "Temporarily on hold" also applies. They are mutually exclusive with "Indefinitely on hold"
        /// (FilmSpecialSorting.exclusiveOptions).
        if film.specialSorting.contains(FilmSpecialSorting.blacklisted) {
            return RotationData(headerTitle: "Next Up for Rotation", formattedValue: RotationValue.blacklisted, isPlaceholder: true)
        }
        if film.specialSorting.contains(FilmSpecialSorting.ignore) {
            return RotationData(headerTitle: "Next Up for Rotation", formattedValue: RotationValue.ignored, isPlaceholder: true)
        }

        let effectiveThreshold = film.rotationThreshold
        let thresholdInYears = Double(effectiveThreshold) / 12.0
        
        /// Format years with one decimal place if not a whole number
        let yearsText: String
        if thresholdInYears.truncatingRemainder(dividingBy: 1) == 0 {
            yearsText = String(Int(thresholdInYears))
        } else {
            yearsText = Fmt.fixed(thresholdInYears, 1)
        }
        
        /// Determine if we're using default or override
        let isDefault = film.rotationThresholdOverride == nil
        let headerTitle = isDefault ? "Next Up for Rotation (\(yearsText), Default)" : "Next Up for Rotation (\(yearsText))"
        
        /// Calculate the rotation date and check if it's ready
        let formattedValue: String
        let isPlaceholder: Bool
        
        if let lastWatchedDate = parseDate(from: film.lastWatched) {
            /// The eligibility date is the anniversary rounded up to the 1st of the following month. Every part of this
            /// line derives from that one value (the readiness switch, the month named, and the countdown), and the
            /// smart list compares against the same helper.
            if let rotationDate = rotationEligibilityDate(
                from: lastWatchedDate,
                months: effectiveThreshold
            ) {
                /// Check if rotation date has passed. `rotationDate` is midnight on
                /// the 1st and `today` the start of the current day, so this turns true
                /// on the first day of the month the label names — never partway through it.
                if today >= rotationDate {
                    formattedValue = RotationValue.ready
                    isPlaceholder = false
                } else {
                    /// `timeDistanceFromNow` is guaranteed at least "1 day away" here:
                    /// the branch above has already absorbed every instant at or past
                    /// the target, so the two can never both describe today.
                    formattedValue = "\(monthYearLabel(for: rotationDate)) (\(timeDistanceFromNow(to: rotationDate)))"
                    isPlaceholder = false
                }
            } else {
                formattedValue = RotationValue.unknown
                isPlaceholder = true
            }
        } else {
            /// If lastWatched is empty, check if film has never been watched
            if !film.watched {
                /// Never watched - ready for viewing
                formattedValue = RotationValue.ready
                isPlaceholder = false
            } else {
                /// Watched but date unknown
                formattedValue = RotationValue.unknown
                isPlaceholder = true
            }
        }
        
        /// Special sorting notes. "Blacklisted" and "Ignored" returned early above, as the value row. Each remaining
        /// tag gets its own row, using the FilmSpecialSorting constants as-is (already sentence case).
        ///
        /// These rows are not gated on `!isPlaceholder`: an "Unknown" countdown (watched, but with a missing or
        /// unparseable date) can still carry a special sorting parameter. The Film Queue note is suppressed for
        /// placeholders, since queue membership describes an active rotation.
        var specialSortingNotes: [String] = []
        if film.specialSorting.contains(FilmSpecialSorting.waitingForEdit)     { specialSortingNotes.append(FilmSpecialSorting.waitingForEdit) }
        if film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold)  { specialSortingNotes.append(FilmSpecialSorting.temporarilyOnHold) }
        if film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold) { specialSortingNotes.append(FilmSpecialSorting.indefinitelyOnHold) }

        /// Film Queue note: the film is in one of the three internal sections (Up Next, Soon, Later). Suppressed
        /// for a placeholder value ("Unknown").
        let queueNote: String?
        if !isPlaceholder, let section = dataCoordinator.filmQueueSection(forFilm: film.id) {
            queueNote = "In the \"\(section.displayName)\" Queue"
        } else {
            queueNote = nil
        }

        return RotationData(
            headerTitle: headerTitle,
            formattedValue: formattedValue,
            isPlaceholder: isPlaceholder,
            specialSortingNotes: specialSortingNotes,
            queueNote: queueNote
        )
    }
    
    @ViewBuilder
    private var recordedViewCountSection: some View {
        let viewCountData = cachedViewCountData

        RSBHelpers.textSection(
            title: "Recorded View Count",
            displayValue: viewCountData.formattedValue,
            isPlaceholder: viewCountData.isPlaceholder,
            glyph: gatedGlyph("eye"),
            glyphColor: glyphTint(isPlaceholder: viewCountData.isPlaceholder),
            trailingInset: Self.viewCountTrailingInset
        )
    }

    /// Trailing inset for the "Recorded View Count" plate. The field shares its row with "Average Between Viewings"
    /// and gets half of the sidebar's content width, of which the glyph gutter takes 22 pt. At the standard inset,
    /// a value such as "44 (since 2004)" overflows its column and wraps, which makes the neighboring column's row
    /// taller. This inset fits every two-digit count.
    ///
    /// Applied unconditionally: the fill spans the full column either way, so a short value renders the same at
    /// any inset. A triple-digit count would still wrap, and that is accepted.
    ///
    /// "Average Between Viewings" uses it too, for its "Insufficient data" placeholder, which needs the same room.
    /// Its numeric values are narrower than that.
    private static let viewCountTrailingInset: CGFloat = 4
    
    /// Helper to calculate view count data
    private func calculateViewCountData(for film: FilmSnapshot) -> (formattedValue: String, isPlaceholder: Bool) {
        let count = film.calendarTable.count
        
        if count == 0 {
            return ("None recorded", true)
        }
        
        /// Oldest year. Entries are "YYYY.MM.DD" or "YYYY.MM.DD.XX"; only the first component is needed. `first` is nil
        /// only for an entry with no components (empty or all dots), which compactMap skips.
        let years = film.calendarTable.compactMap { entry -> Int? in
            guard let firstComponent = entry.split(separator: ".").first else { return nil }
            return Int(firstComponent)
        }
        
        if let oldestYear = years.min() {
            return ("\(count) (since \(oldestYear))", false)
        } else {
            return ("\(count)", false)
        }
    }
    
    @ViewBuilder
    private var averageBetweenViewingsSection: some View {
        /// Derive display state from the derived values only — no live snapshot reads.
        /// cachedCalendarTableCount and cachedAverageBetweenViewings are computed from
        /// the same film value in the same render, so they cannot disagree.
        let displayValueAndPlaceholder: (String, Bool) = {
            switch cachedCalendarTableCount {
            case 0:  return ("None recorded", true)
            case 1:  return ("Insufficient data", true)
            default:
                let value = cachedAverageBetweenViewings
                /// An empty value with 2+ entries means fewer than two parsed into usable dates
                /// (calculateAverageBetweenViewings drops unparseable ones). That reads as "Insufficient data", not
                /// "None recorded", because the adjacent Recorded View Count shows the raw non-zero count.
                return value.isEmpty ? ("Insufficient data", true) : (value, false)
            }
        }()

        RSBHelpers.textSection(
            title: "Avg. Between Viewings",
            displayValue: displayValueAndPlaceholder.0,
            isPlaceholder: displayValueAndPlaceholder.1,
            glyph: gatedGlyph("rectangle.split.3x1"),
            glyphColor: glyphTint(isPlaceholder: displayValueAndPlaceholder.1),
            trailingInset: Self.viewCountTrailingInset
        )
    }
    
    /// Helper to calculate the average between viewings.
    ///
    /// The parsed Dates are carried through the interval arithmetic rather than re-parsed from the strings, which
    /// would cost three parses per entry on a path that runs for every film selection.
    ///
    /// Every entry in `sortedDates` parsed, so the interval count is exactly `count - 1`. The guard below needs at
    /// least two dates, and the empty string it returns is the only way this reports nothing ("Insufficient data").
    private func calculateAverageBetweenViewings(for film: FilmSnapshot) -> String {
        /// Sort dates from most to least recent.
        let sortedDates = film.calendarTable
            .compactMap { parseDate(from: $0) }
            .sorted(by: >)

        /// Need at least 2 viewings to calculate an average.
        guard sortedDates.count >= 2 else {
            return ""
        }

        let calendar = AppCalendar.current
        var totalDays = 0

        /// Days between each consecutive pair: the current calendar, one `.day` component, and the absolute value.
        for index in 0..<(sortedDates.count - 1) {
            let laterDate = sortedDates[index]
            let earlierDate = sortedDates[index + 1]
            let days = calendar.dateComponents([.day], from: earlierDate, to: laterDate).day ?? 0
            totalDays += abs(days)
        }

        let average = totalDays / (sortedDates.count - 1)
        return "\(average) day" + (average == 1 ? "" : "s")
    }
    
    /// Renders the Duration field from the cached display strings.
    @ViewBuilder
    private var durationSection: some View {
        /// Edited runtime: primary value at full prominence, with the "(originally X)" parenthetical in tertiary
        /// (text concatenation mixes styles in one layout run). Without an edited duration, the standard duration.
        /// With neither, the placeholder.
        let isPlaceholder = cachedEditedDuration.isEmpty && cachedDuration.isEmpty

        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Duration")
            RSBHelpers.fittingValueRow(
                full: durationRowText(abbreviatingPrimary: false),
                abbreviations: durationAbbreviatedRowText.map { [$0] } ?? [],
                isPlaceholder: isPlaceholder,
                glyph: gatedGlyph("timer"),
                glyphColor: glyphTint(isPlaceholder: isPlaceholder)
            )
        }
    }

    /// The Duration row's composed value: the primary runtime at full prominence, and, when the film is edited,
    /// the original runtime as a tertiary parenthetical.
    ///
    /// `abbreviatingPrimary` selects the spelling of the PRIMARY value only. The parenthetical is always
    /// abbreviated, since it is the lesser of the two figures.
    private func durationRowText(abbreviatingPrimary: Bool) -> Text {
        if !cachedEditedDuration.isEmpty {
            let primary = abbreviatingPrimary ? cachedEditedDurationAbbreviated : cachedEditedDuration
            let value = Text(primary).foregroundStyle(.primary)
            guard !cachedDurationAbbreviated.isEmpty else { return value }
            return value + Text(" (originally \(cachedDurationAbbreviated))").foregroundStyle(.tertiary)
        }
        if !cachedDuration.isEmpty {
            return Text(abbreviatingPrimary ? cachedDurationAbbreviated : cachedDuration)
                .foregroundStyle(.primary)
        }
        return Text("None provided").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }

    /// The shorter candidate `fittingValueRow` falls back to when the full spelling would wrap, such as
    /// "1 hr. 47 min." for "1 hour 47 minutes".
    ///
    /// `nil` when there is nothing to shorten, which skips the measurement: the placeholder has no abbreviation,
    /// and neither does a value whose short form is missing or identical to the long one ("0 min." is the same
    /// either way). As in every other row, the abbreviation is only a candidate.
    private var durationAbbreviatedRowText: Text? {
        let full = cachedEditedDuration.isEmpty ? cachedDuration : cachedEditedDuration
        let short = cachedEditedDuration.isEmpty ? cachedDurationAbbreviated : cachedEditedDurationAbbreviated
        guard !full.isEmpty, !short.isEmpty, short != full else { return nil }
        return durationRowText(abbreviatingPrimary: true)
    }

    // MARK: - Field Glyphs
    ///
    /// The symbols that precede this module's value and annotation rows, all behind the user
    /// preference `showWatchDetailsAnnotationGlyphs` — read here as `showAnnotationGlyphs`,
    /// the @AppStorage member declared at the top of this view. They are decoration for values
    /// that already read unambiguously on their own, so the preference turns every one of them
    /// off together rather than leaving a partial set.
    ///
    /// The single exception is the "Source for Viewing" disc, which
    /// `Preferences.purchasedDiscGlyphVisibilityOverride` can exempt from the preference; see
    /// `sourceValueGlyph`.
    ///
    /// Naming a glyph is a per-ROW decision, not a per-row-kind one: the special-sorting rows
    /// share a builder, but not a symbol.
    ///
    /// None of them is drawn inline. Every one goes in the fixed-width gutter that
    /// `RSBHelpers.sidebarRowContainer(glyph:)` reserves, so no row's text starts at a
    /// different offset than another's and no symbol can make a row taller.

    /// The Film Queue membership note's glyph, shared by all three sections (Up Next, Soon, Later). The note
    /// names the queue, and the symbol only marks it as a queue row. It is defined once in `RSBHelpers`
    /// (`queueMembershipGlyph`), which ListTable also uses for the same mark.
    private static let queueNoteGlyph = RSBHelpers.queueMembershipGlyph

    /// The "Available for purchase on <format>" note's glyph.
    private static let purchaseNoteGlyph = "cart.fill.badge.questionmark"
    private static let preorderNoteGlyph = "calendar.badge.clock"

    /// The tint for a value row's glyph. Glyphs take `.secondary` instead of the text's `.primary` (capped by
    /// `Preferences.capWatchDetailsGlyphColorAtSecondary`), so a glyph reads as an annotation rather than part of
    /// the value. Placeholder glyphs stay tertiary, which is already below the cap.
    ///
    /// `opticaldisc.fill` is exempt. It marks a purchased release, a fact about the film rather than decoration,
    /// so it stays `.primary`.
    ///
    /// Annotation rows do not come through here. `annotationRow` already defaults to `.secondary`.
    private func glyphTint(isPlaceholder: Bool, symbol: String? = nil) -> Color {
        if isPlaceholder { return Color(nsColor: .tertiaryLabelColor) }
        if symbol == ContentGlyphs.disc { return .primary }
        return Preferences.capWatchDetailsGlyphColorAtSecondary ? .secondary : .primary
    }

    /// Passes a glyph name through when the switch is on, and `nil` when it is off — the
    /// row builders' own "no glyph" case, so the off state costs nothing at the row. Every
    /// map below returns through this, so the switch has exactly one enforcement point.
    private func gatedGlyph(_ systemName: String?) -> String? {
        showAnnotationGlyphs ? systemName : nil
    }

    /// The "Last Watched" value row's glyph. The two placeholders say different things —
    /// never watched at all, versus watched on a date we no longer hold — and get different
    /// symbols rather than sharing one "no data" mark.
    private func lastWatchedGlyph(value: String, isPlaceholder: Bool) -> String? {
        guard isPlaceholder else { return gatedGlyph("calendar") }
        return gatedGlyph(value == "Unknown date" ? "questionmark" : "eye.slash.fill")
    }

    /// The "Next Up for Rotation" value row's glyph, keyed off the resolved display string.
    ///
    /// Matched against the four fixed spellings `calculateRotationData` can produce; anything
    /// else is a formatted future date ("September 2029 (3 years 7 months away)"), the case
    /// the clock names. Defaulting that way round means a date whose formatting changes still
    /// gets the right symbol; both sides read the fixed spellings from `RotationValue`.
    private func rotationValueGlyph(_ formattedValue: String) -> String? {
        switch formattedValue {
        case RotationValue.blacklisted, RotationValue.ignored: return gatedGlyph("xmark")
        case RotationValue.ready:   return gatedGlyph("checkmark")
        case RotationValue.unknown: return gatedGlyph("questionmark")
        default:                       return gatedGlyph("deskclock")
        }
    }

    /// The "Source for Viewing" value row's glyph: the disc for a purchased disc-based source, a document for
    /// everything else, and the outline document for the "None provided" placeholder.
    ///
    /// The disc can outrank the user's preference. With `Preferences.purchasedDiscGlyphVisibilityOverride` on, it
    /// is always drawn; with it off, it is gated like the rest. Either way it sits in the leading gutter, so its
    /// position does not depend on the preference.
    private func sourceValueGlyph(isPurchasedDisc: Bool, isPlaceholder: Bool) -> String? {
        if isPurchasedDisc {
            return Preferences.purchasedDiscGlyphVisibilityOverride
                ? ContentGlyphs.disc
                : gatedGlyph(ContentGlyphs.disc)
        }
        return gatedGlyph(isPlaceholder ? "document" : "document.fill")
    }

    /// The glyph for one special-sorting parameter row, or `nil` for a parameter that takes
    /// none. Keyed off the `FilmSpecialSorting` constants themselves rather than the
    /// rendered string, so a reworded tag cannot silently lose its symbol.
    ///
    /// The two hold states take related but distinct hourglasses — the lock marks the
    /// indefinite one as having no expected end, which is the difference between them that
    /// matters at a glance. "Blacklisted" and "Ignored" never reach here: they return early
    /// from `calculateRotationData` and are rendered as the value row, not as annotations.
    private func glyph(forSpecialSorting note: String) -> String? {
        switch note {
        case FilmSpecialSorting.waitingForEdit:     return gatedGlyph("scissors")
        case FilmSpecialSorting.temporarilyOnHold:  return gatedGlyph("hourglass")
        case FilmSpecialSorting.indefinitelyOnHold: return gatedGlyph("hourglass.and.lock")
        default:                                    return nil
        }
    }

    /// The Source row's value text, plain. The disc glyph is drawn in the leading gutter by `sourceValueGlyph`,
    /// so the value and its abbreviation are just text.
    ///
    /// Kept as a function because every candidate handed to `fittingValueRow` must be built the same way for the
    /// measurement to mean anything.
    private func sourceRowText(displayValue: String, valueColor: Color) -> Text {
        Text(displayValue).foregroundStyle(valueColor)
    }

    @ViewBuilder
    private var sourceSection: some View {
        let source = cachedSourceDisplay
        let isPlaceholder = source.value.isEmpty
        let displayValue = isPlaceholder ? "None provided" : source.value
        /// Both notes are suppressed for the "None provided" placeholder, since there is no source to qualify. The
        /// purchase note can sit beside a purchased Blu-ray disc (an owned Blu-ray with an unpurchased 4K reads
        /// "Available for purchase on 4K UHD"), so it and the Region B note are emitted independently by sourceDisplay.
        let purchaseNote = isPlaceholder ? "" : source.availableForPurchaseNote
        let regionBNote = isPlaceholder ? "" : source.regionBLockNote
        let preorderNote = isPlaceholder ? "" : source.preorderReleaseNote
        let valueColor: Color = isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary
        /// The glyph and the tint decision use the same resolved symbol, so `glyphTint`'s `opticaldisc.fill`
        /// exemption tests the symbol actually drawn.
        let valueGlyph = sourceValueGlyph(isPurchasedDisc: source.isPurchasedDiscSource,
                                          isPlaceholder: isPlaceholder)

        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Source for Viewing")
            /// Three words in a source value are worth shortening and safe to shorten: "remastered" ("rem."), the origin
            /// demonym ("Australian" → "AU"), and the studio shorthand ("Universal" → "Uni"). Other components ("Blu-ray
            /// disc", "4K disc", "rip", the year) are already short. A short form is used only when the longer one would
            /// wrap, and a value with none of the three offers no alternative. The origin and studio forms come from
            /// sourceDisplay, not text substitution (see SourceDisplay.originAbbreviatedValue). Every candidate is built
            /// through sourceRowText, so all are measured alike.
            RSBHelpers.fittingValueRow(
                full: sourceRowText(displayValue: displayValue, valueColor: valueColor),
                abbreviations: SidebarTextAbbreviation
                    .sourceValueLadder(full: displayValue,
                                       originAbbreviated: isPlaceholder ? nil : source.originAbbreviatedValue,
                                       studioAbbreviated: isPlaceholder ? nil : source.studioAbbreviatedValue,
                                       originAndStudioAbbreviated: isPlaceholder ? nil : source.originAndStudioAbbreviatedValue)
                    .map { sourceRowText(displayValue: $0, valueColor: valueColor) },
                isPlaceholder: isPlaceholder,
                glyph: valueGlyph,
                glyphColor: glyphTint(isPlaceholder: isPlaceholder, symbol: valueGlyph)
            )
            /// Region B first: it describes the disc named on the value row, and stays .primary because a playback
            /// restriction warrants the same attention as the value it qualifies. Purchase availability is the lesser
            /// aside and takes annotationRow's default .secondary.
            if !regionBNote.isEmpty {
                RSBHelpers.annotationRow(regionBNote, color: .primary)
            }
            /// Pre-order date: a fitting row, so it can drop to an abbreviated month ("Oct. 2, 2026") instead of
            /// wrapping, as the module's other date rows do. Styled like annotationRow (.secondary text and glyph,
            /// always selectable).
            if !preorderNote.isEmpty {
                RSBHelpers.fittingValueRow(
                    full: Text(preorderNote).foregroundStyle(.secondary),
                    abbreviations: source.preorderReleaseNoteAbbreviated
                        .map { [Text($0).foregroundStyle(.secondary)] } ?? [],
                    isPlaceholder: false,
                    glyph: gatedGlyph(Self.preorderNoteGlyph),
                    glyphColor: .secondary
                )
            }
            if !purchaseNote.isEmpty {
                RSBHelpers.fittingValueRow(
                    full: Text(purchaseNote).foregroundStyle(.secondary),
                    abbreviations: source.availableForPurchaseNoteAbbreviated
                        .map { [Text($0).foregroundStyle(.secondary)] } ?? [],
                    isPlaceholder: false,
                    glyph: gatedGlyph(Self.purchaseNoteGlyph),
                    glyphColor: .secondary
                )
            }
        }
    }
    
    // MARK: - "Add Viewing" Logic
    
    private func addViewing(film displayedFilm: FilmSnapshot, date: Date, version: ViewingVersion) {
        /// Built on the store's current snapshot, not the sidebar's copy: the table computed
        /// below REPLACES the stored calendarTable, so a copy that lagged a save would erase
        /// whatever viewings that save added.
        let film = dataCoordinator.getFilm(displayedFilm.id) ?? displayedFilm
        let dateFormatter = Self.viewingDateFormatter
        let baseDateString = dateFormatter.string(from: date)

        /// Full date string with version code (e.g. "2025.06.14.tc").
        /// lastWatched must store the base date only, never the version code.
        let fullDateString: String
        if version.rawValue.isEmpty {
            fullDateString = baseDateString
        } else {
            fullDateString = "\(baseDateString).\(version.rawValue)"
        }

        /// Build new calendarTable as a local copy - do NOT mutate the live Film object
        var newCalendarTable = film.calendarTable
        let existingBaseDates = newCalendarTable.compactMap { extractDatePortion(from: $0) }
        /// Defense in depth: UnifiedViewingPopover rejects a duplicate date first (with the "Event Already Exists"
        /// alert), so this guard is normally unreachable. It keeps this method from ever adding a second entry for the same day.
        if !existingBaseDates.contains(baseDateString) {
            newCalendarTable.append(fullDateString)
        }

        /// Advance lastWatched only when this date is more recent. Parse it with the app-wide `parseDate(from:)`, not
        /// the dot-only formatter above: after an import, lastWatched can still be dash or ISO format (DBRestorer's
        /// cleanedLastWatched strips version codes and trailing dots only). The dot-only formatter fails on those and
        /// would fall through to the unconditional overwrite, so an older viewing would rewind lastWatched.
        var newLastWatched = film.lastWatched
        if let existingDate = parseDate(from: film.lastWatched) {
            if date > existingDate { newLastWatched = baseDateString }
        } else {
            /// No parseable lastWatched date yet - set it unconditionally.
            newLastWatched = baseDateString
        }

        /// Delegate to coordinator: MemoryStore-first, background persistence, rollback on failure
        dataCoordinator.updateViewingDates(
            filmID: film.id,
            calendarTable: newCalendarTable,
            lastWatched: newLastWatched,
            watched: true
        )

        Self.log("Added viewing for film '\(film.name)' on date \(fullDateString)")
    }
    
    // MARK: - Calendar Access Logic
    
    /// Reads the current authorization status from EventKitManager.
    /// Never creates a throwaway EKEventStore — all EK traffic flows through the manager.
    private func checkCalendarAccess() {
        calendarAccessStatus = EventKitManager.shared.authorizationStatus
        /// Intentionally not logged here — onAppear and onChange(of: film, initial: true)
        /// both fire once per fresh WatchDetails mount, and the resulting calendar status
        /// is folded into that single consolidated log line instead of being logged twice.
    }
    
    private func handleViewingButtonClick() {
        /// Fresh open: clear any leftover pending entry so the popover starts blank. The reopen path after a
        /// duplicate-date alert does not come through here (see .reopenViewingEventPopover), so a rejected entry
        /// survives until it is restored.
        pendingViewingEntry = nil

        /// If Preferences.iCalIntegration is enabled and permission has not yet been
        /// granted, route the request through EventKitManager so its cache, polling
        /// loop, and event bus notifications all stay coherent.
        if iCalIntegration {
            let currentStatus = EventKitManager.shared.authorizationStatus
            
            if currentStatus == .notDetermined {
                log("iCal integration enabled, requesting calendar access...")
                let requestingFilmID = film?.id
                permissionPendingFilmID = requestingFilmID
                Task {
                    let granted = await EventKitManager.shared.requestAccessIfNeeded()
                    log("Access granted: \(granted)")
                    /// calendarAccessStatus is kept in sync via the calendarAuthorizationChanged
                    /// event bus notification that EventKitManager fires on status change.
                    ///
                    /// Open only for the film that was clicked, and only while the Details tab
                    /// is the one on screen: the permission prompt can sit for as long as the
                    /// user likes, and in the meantime the film may have changed (which clears
                    /// the pending id) or the tab may have slid away, leaving the popover's
                    /// anchor off-screen.
                    guard permissionPendingFilmID == requestingFilmID,
                          ViewStateManager.shared.selectedRightSidebarTab == .details else {
                        permissionPendingFilmID = nil
                        return
                    }
                    permissionPendingFilmID = nil
                    showViewingPopover = true
                }
                return
            }
        }
        
        /// Otherwise, just show the popover
        showViewingPopover = true
    }
    
    /// Flashes the "Add Viewing Event" confirmation checkmark for three seconds. The pending reset lives in
    /// `checkmarkResetTask` and is canceled on re-entry, so consecutive viewings each get the full three seconds.
    ///
    /// Not wrapped in `withAnimation`: the symbol swap has its own value-scoped `.animation`, and a transaction-wide
    /// animation would also animate the tab relayout that addViewing() triggers.
    private func showCheckmarkFeedback() {
        checkmarkResetTask?.cancel()
        showViewingCheckmark = true
        checkmarkResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showViewingCheckmark = false
        }
    }
    
    private var viewingButtonHelpText: String {
        if !iCalIntegration {
            return "Add a viewing to Film Tracker"
        }
        
        switch calendarAccessStatus {
        case .notDetermined:
            return "Add viewing to Film Tracker and system calendar (requires calendar access)"
        case .denied, .restricted:
            return "Calendar access denied. Will only add to Film Tracker. Enable in System Settings > Privacy & Security > Calendar for full features"
        case .fullAccess, .writeOnly:
            return "Add viewing to Film Tracker and system calendar"
        @unknown default:
            return "Add a viewing to Film Tracker"
        }
    }
}
