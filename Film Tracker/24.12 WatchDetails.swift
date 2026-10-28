// MARK: - WatchDetails.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "WatchDetails" tab, module 02.

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
    // Pending reset of showViewingCheckmark, retained so a second confirmation can
    // cancel the first one's timer instead of racing it. See showCheckmarkFeedback().
    @State private var checkmarkResetTask: Task<Void, Never>?

    // Holds a snapshot of the viewing-event popover's in-progress entry, captured only
    // when the user hits "Add" with a date that collides with an existing entry.
    // macOS automatically closes an open NSPopover the instant the resulting "Event
    // Already Exists" NSAlert is presented, so the popover's own @State is torn down
    // along with it — this snapshot is what lets the reopened popover (fired by
    // .reopenViewingEventPopover once the alert clears) seed itself with exactly
    // what the user had entered, rather than resetting to blank defaults. `nil` for
    // a genuine fresh open (see handleViewingButtonClick, which clears it).
    @State private var pendingViewingEntry: PendingViewingEntry?

    // The film a click is waiting on calendar permission for, while the request is out.
    // Cleared by a change of film, so a grant that resolves after the user has moved on
    // does not open the popover for whatever film is showing by then.
    @State private var permissionPendingFilmID: UUID?

    // @AppStorage monitors for preference key changes.
    @AppStorage(preference: Preferences.iCalIntegrationKey)
        private var iCalIntegration: Bool
    @AppStorage(preference: Preferences.defaultRotationThresholdKey)
        private var defaultRotationThreshold: Int
    /// Read through @AppStorage rather than `Preferences.showWatchDetailsAnnotationGlyphs`
    /// so that toggling it in Settings redraws this module immediately: a plain static read
    /// would give the right answer on the next body pass but nothing would schedule one, and
    /// the sidebar behind the sheet would keep its old glyphs until the film changed.
    ///
    /// This is also why the glyph maps below are instance members. They were `static` while
    /// the switch was a compile-time constant; a static cannot read a view's @AppStorage.
    @AppStorage(preference: Preferences.showWatchDetailsAnnotationGlyphsKey)
        private var showAnnotationGlyphs: Bool
    @AppStorage(preference: Preferences.manualExtQueryKey)
        private var manualExtQuery: Bool
    
    // MARK: - Derived Display Values
    //
    // These were `@State` caches, refreshed from an `onChange(of: film)` handler. They
    // are now computed directly from the film, which is both cheaper and more robust.
    //
    // Cheaper, because the caching was a net loss once measured. Writing `@State` from
    // an `onChange` means a new film renders this module twice — once with the previous
    // film's values still in place, then again after the handler overwrites them — and
    // profiling showed the sidebar's per-selection cost is dominated by laying out this
    // stack, at roughly 50 ms a pass. The work being avoided was the whole set of
    // calculations below, which together measured under 2 ms. Paying an extra layout
    // pass to skip 2 ms of string formatting is a bad trade, and this module was the
    // last one still making it.
    //
    // More robust, because a derived value cannot go stale. Every trigger that used to
    // need an explicit refresh call now works by construction: a film change and a
    // `defaultRotationThreshold` change both already invalidate this view, and the
    // values are simply recomputed with it. The one class of change that does NOT
    // invalidate anything on its own — a midnight rollover shifting date-relative
    // wording, or a queue membership change that leaves `lastModified` untouched — is
    // handled by `externalRefreshToken` below.
    //
    // `effectiveThreshold` used to be carried as a fifth field of the rotation data; it
    // was never read by any view (the threshold is already baked into `headerTitle`),
    // so it remains a purely local value inside calculateRotationData.

    /// Bumped by the events that change what these values should read but that alter
    /// neither the film value nor any preference this view observes — so nothing else
    /// would schedule the re-render they require. Read once in `body` to make the
    /// dependency explicit rather than relying on the invalidation side effect alone.
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
        // `film.rotationThreshold` falls back to Preferences.defaultRotationThreshold
        // for films carrying no per-film override, and that fallback reads the static
        // rather than the @AppStorage mirror below. Changing the preference in Settings
        // alters neither the film value nor its lastModified stamp, so the @AppStorage
        // declaration is the only thing that invalidates this view for it. Touching it
        // here makes that dependency textual instead of incidental — the value is
        // genuinely required to compute a correct result, and a future reader removing
        // an "unused" property wrapper would silently break the Settings→sidebar
        // update path.
        _ = defaultRotationThreshold
        // Read through CurrentDay, as the Source field is, so the countdown ticks down and
        // turns into "Ready for viewing" when the day changes without anything else changing.
        let today = CurrentDay.shared.today
        return film.map { calculateRotationData(for: $0, today: today) } ?? RotationData()
    }

    /// The Source field's display string plus its three branch-derived companions
    /// (disc glyph, "available for purchase" suffix, "Region B locked" suffix). All
    /// four come from a single RSBHelpers.sourceDisplay(for:) call so they cannot
    /// disagree about which release the field is describing.
    private var cachedSourceDisplay: RSBHelpers.SourceDisplay {
        // Read through CurrentDay so an upcoming release's purchase note turns into
        // "Available for purchase" on its release day without anything else changing.
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

    // Abbreviated form of the original duration, used only in the parenthetical
    // suffix when an edited duration is also present: "(originally 2 hr. 1 min.)".
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

    // The formatted edited duration string; non-empty only when film.edited is true
    // and film.editedDuration contains a meaningful (non-zero) millisecond value.
    // When non-empty it is appended to the duration field as "(originally X)".
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

    // Local appearance parameters.
    private let buttonFontSize = CGFloat(12)
    
    // The shared "yyyy.MM.dd" storage formatter. These values are stored in
    // calendarTable and compared as strings against what CalendarPopover and
    // ViewingDatesTable produce; those now resolve to this same object, so the
    // comparisons hold by construction rather than by three copies being pinned alike.
    private static let viewingDateFormatter = StorageDateFormatters.dot
    
    var body: some View {
        // Establishes the dependency described on `externalRefreshToken`.
        let _ = externalRefreshToken
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                // Action buttons row: "Add Viewing Event" (expands/contracts) + optional
                // Web query button.
                HStack(spacing: 8) {
                    // "Add Viewing Event" — expands to fill available width when the
                    // Web query button is hidden, contracting smoothly when it appears.
                    Button(action: {
                        handleViewingButtonClick()
                    }) {
                        HStack(spacing: 6) {
                            // Fixed-width container for icon to prevent text shifting
                            ZStack {
                                Image(systemName: showViewingCheckmark ? "checkmark.circle.fill" : "calendar.badge.plus")
                                    .contentTransition(.symbolEffect(.replace))
                                    // The symbol swap is animated HERE, scoped to this one
                                    // value, rather than with `withAnimation` around the
                                    // state change. showCheckmarkFeedback() runs in the
                                    // same turn as addViewing(), whose MemoryStore write
                                    // re-renders the whole tab (Last Watched, Queue
                                    // inclusion) in the same update pass; a transaction-
                                    // wide animation there animated that relayout too,
                                    // and the sidebar's modules visibly slid into place.
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
                    
                    // External Web query menu button — shown only when
                    // Preferences.manualExtQuery is true.
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
                
                // "Last Watched" section (combined date and time ago).
                lastWatchedSection
                
                // Full-width section: "Next Up for Rotation"
                nextUpForRotationSection
                
                // Two-column section: "Recorded View Count" and "Average Between Viewings".
                HStack(spacing: 12) {
                    recordedViewCountSection
                    averageBetweenViewingsSection
                }
                
                // Full-width "Duration" section.
                durationSection
                
                // "Source" section.
                sourceSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 0)
            .onAppear {
                checkCalendarAccess()
            }
            .onDisappear {
                // Cancel the pending checkmark reset on dismount, matching the
                // cancel-on-teardown treatment every other retained task in the sidebar
                // gets (RightSidebar's resolutionTask/swipeResetTask). The re-entry case is
                // already covered by the cancel() at the top of showCheckmarkFeedback().
                checkmarkResetTask?.cancel()
                checkmarkResetTask = nil
            }
            // This handler no longer refreshes any display values — those are derived
            // from the film as it renders (see "Derived Display Values" above), which is
            // both why a new film can never show the previous one's figures and why
            // there is no first-frame flash to guard against. What remains here is the
            // transient-state reset, which is genuinely stateful and has no other
            // trigger, plus the diagnostic line.
            //
            // `initial: true` is kept so a fresh mount still emits exactly one log line.
            // It intentionally does NOT run the reset below: SwiftUI passes equal old and
            // new values on the initial call, so the id guard is false — correct, since
            // there is no prior film whose popover could still be open.
            //
            // Logging note: onAppear and this onChange both fire exactly once per fresh
            // WatchDetails mount (one here, one for the live calendar authorization read,
            // since the latter is not a function of `film` and cannot be folded into the
            // same trigger). Both used to log independently, producing two lines per
            // mount. The single log call below reads the authorization status directly
            // (rather than relying on `calendarAccessStatus`, which would be stale if
            // this onChange happens to run before onAppear's assignment — the relative
            // firing order of two independent initial-appearance modifiers is not
            // guaranteed) so a mount still produces exactly one accurate diagnostic line,
            // and a genuine double-mount (if one ever occurs) still surfaces as two
            // lines, preserving that signal for future debugging.
            .onChange(of: film, initial: true) { oldFilm, newFilm in
                // A different film is a different subject: nothing transient that was
                // on screen for the previous one still applies. This used to happen
                // implicitly, because the sidebar gave each film's tab content a fresh
                // SwiftUI identity and every `@State` here was destroyed with it; the
                // tab content is now reused across films (it is far too expensive to
                // rebuild per selection), so the reset has to be stated. Guarded on a
                // genuine id change so an in-place edit of the *current* film — a
                // rating change, a new viewing — cannot dismiss a popover the user is
                // actively working in.
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
                    // Dismiss the popover synchronously when the sidebar's scroll
                    // view begins a live-scroll phase. SidebarScrollView's
                    // onScrollWillStart callback fires this event before the content
                    // has re-laid-out, so the popover tears down before it can chase
                    // the moving anchor. Guard on the existing presented-state flag
                    // to avoid redundant state mutations.
                    if showViewingPopover { showViewingPopover = false }
                case .smartListsRecalculated:
                    // SmartLists fires this event at midnight after recalculating
                    // rotation-based list membership. The date-relative display
                    // strings ("Today" → "Yesterday", "X months away") are derived
                    // from the current date, which nothing else observes, so this is
                    // one of the two cases that must force a re-render explicitly.
                    externalRefreshToken &+= 1
                    Self.log("Midnight rollover: refreshed date-relative cached values for \(film.name)")
                default:
                    break
                }
            }
            .onReceive(AppEventBus.shared.uiCommands) { command in
                guard case .reopenViewingEventPopover = command else { return }
                // The system already auto-closed the popover the instant the
                // duplicate-date alert appeared; pendingViewingEntry (captured at
                // that moment) is what lets it come back with the same entry.
                showViewingPopover = true
            }
            .onReceive(AppEventBus.shared.listEvents) { event in
                // Film Queue membership changes (e.g. drag-and-drop between Up Next /
                // Soon / Later, or removal from the queue entirely) do not update the
                // film's own lastModified timestamp, so the onChange(of: film) trigger
                // above won't fire for them on its own. Refresh here whenever one of
                // the three internal queue lists changes, so the "in the '<Section>'
                // Queue" clause never goes stale while this film is on screen.
                guard case .membershipChanged(let listID) = event, FilmQueue.isInternalList(listID) else { return }
                externalRefreshToken &+= 1
            }
        }
    }
    
    // MARK: - Custom Section Builders (for placeholder styling)

    // Every builder below renders exclusively from the derived `cached…` values above
    // — none of them read the live snapshot directly — so they are parameterless
    // computed properties rather than functions taking a `film` argument they never
    // used. `sourceSection` was already written this way.
    /// The "Last Watched" field: the viewing date followed by its relative-time clause.
    ///
    /// Built from `sectionHeader` + `fittingValueRow` rather than from `textSection`
    /// (which is exactly those two with a plain `valueRow`) so the value can shorten its
    /// time units when the full spelling would wrap — "November 04, 2021 (4 years 4 months
    /// ago)" is the shape that overruns a 300pt sidebar, and "(4 yr. 4 mo. ago)" is not.
    /// The abbreviation is offered, never imposed: `fittingValueRow` uses it only when the
    /// full text does not fit on one line, and falls back to the full text wrapping when
    /// even the short form needs two. Placeholder values ("Unwatched", "Unknown date")
    /// carry no parenthetical, so `abbreviatingTimeUnits` returns nil for them and the row
    /// behaves exactly as it always did.
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

    /// The value row's foreground for the rotation field, matching `RSBHelpers.valueRow`'s
    /// own placeholder rule. Needed explicitly here because `fittingValueRow` takes a
    /// pre-styled `Text` (so a composed row such as the source field's glyph-plus-value can
    /// use the same path), which moves the color decision to the call site.
    ///
    /// Takes the placeholder flag rather than reading `cachedRotationData` itself. That
    /// mattered once the rotation data stopped being stored: this is read once for the
    /// full value and again for *every* entry of the abbreviation ladder, so reading the
    /// derived property here would re-run `calculateRotationData` per ladder entry. As a
    /// stored `@State` read that was free; as a derived value it is not, and passing the
    /// one flag it actually needs keeps the computation at one per render.
    private func rotationValueColor(isPlaceholder: Bool) -> Color {
        isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary
    }

    /// The "Next Up for Rotation" field: the countdown value, then each of its
    /// subordinate notes on its own row beneath it, in the fixed order value →
    /// special-sorting tags → Film Queue membership.
    ///
    /// The notes were previously joined into one comma-separated italic clause appended
    /// to the value itself ("June 2028 (1 year away), in the "Up Next" Queue,
    /// indefinitely on hold"), which routinely wrapped the row to two or three lines and
    /// needed a hand-composed mixed-style Text to keep the value and the clause in
    /// different colors. Giving each note its own row removes both problems and matches
    /// the one-header-many-rows shape `searchableItemSection` uses for cast and crew.
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
            // Same overflow-driven abbreviation as "Last Watched" above, and for the same
            // string shape: "September 2029 (3 years 7 months away)" is a month label plus
            // a relative-time clause. The other formattedValue shapes this field produces
            // ("Ready for viewing", "Blacklisted", "Ignored", "Unknown") have no
            // parenthetical at all, so no alternative is offered for them.
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
    
    /// Everything the "Next Up for Rotation" section renders. The notes are kept as
    /// separate, individually complete strings rather than one pre-joined clause
    /// because each is now its own row; this function stays style-free, exactly as it
    /// did when the view was responsible for composing them into mixed Text runs.
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

    // Helper to calculate rotation data.
    private func calculateRotationData(for film: FilmSnapshot, today: Date) -> RotationData {
        // Check if film is blacklisted or ignored. These two remain mutually exclusive
        // with "Indefinitely on hold" (enforced by the FilmSheet UI), and both still take
        // display priority over the rotation countdown even though "Waiting for edit" and/or
        // "Temporarily on hold" may also be present on the same film.
        if film.specialSorting.contains(FilmSpecialSorting.blacklisted) {
            return RotationData(headerTitle: "Next Up for Rotation", formattedValue: "Blacklisted", isPlaceholder: true)
        }
        if film.specialSorting.contains(FilmSpecialSorting.ignore) {
            return RotationData(headerTitle: "Next Up for Rotation", formattedValue: "Ignored", isPlaceholder: true)
        }

        let effectiveThreshold = film.rotationThreshold
        let thresholdInYears = Double(effectiveThreshold) / 12.0
        
        // Format years with one decimal place if not a whole number
        let yearsText: String
        if thresholdInYears.truncatingRemainder(dividingBy: 1) == 0 {
            yearsText = String(Int(thresholdInYears))
        } else {
            yearsText = Fmt.fixed(thresholdInYears, 1)
        }
        
        // Determine if we're using default or override
        let isDefault = film.rotationThresholdOverride == nil
        let headerTitle = isDefault ? "Next Up for Rotation (\(yearsText), Default)" : "Next Up for Rotation (\(yearsText))"
        
        // Calculate the rotation date and check if it's ready
        let formattedValue: String
        let isPlaceholder: Bool
        
        if let lastWatchedDate = parseDate(from: film.lastWatched) {
            // The eligibility date is the anniversary rounded up to the 1st of the
            // following month. Every part of this line is derived from this one
            // value — the readiness switch, the month named, and the countdown — so
            // the line is structurally incapable of contradicting itself the way
            // "September 2026 (0 days away)" did, and equally incapable of
            // contradicting the smart list, which compares against the same helper.
            if let rotationDate = rotationEligibilityDate(
                from: lastWatchedDate,
                months: effectiveThreshold
            ) {
                // Check if rotation date has passed. `rotationDate` is midnight on
                // the 1st and `today` the start of the current day, so this turns true
                // on the first day of the month the label names — never partway through it.
                if today >= rotationDate {
                    formattedValue = "Ready for viewing"
                    isPlaceholder = false
                } else {
                    // `timeDistanceFromNow` is guaranteed at least "1 day away" here:
                    // the branch above has already absorbed every instant at or past
                    // the target, so the two can never both describe today.
                    formattedValue = "\(monthYearLabel(for: rotationDate)) (\(timeDistanceFromNow(to: rotationDate)))"
                    isPlaceholder = false
                }
            } else {
                formattedValue = "Unknown"
                isPlaceholder = true
            }
        } else {
            // If lastWatched is empty, check if film has never been watched
            if !film.watched {
                // Never watched - ready for viewing
                formattedValue = "Ready for viewing"
                isPlaceholder = false
            } else {
                // Watched but date unknown
                formattedValue = "Unknown"
                isPlaceholder = true
            }
        }
        
        // Resolve the special sorting notes, if any. "Blacklisted" and "Ignore"
        // returned early above, already naming their parameter in the value row. Each
        // remaining tag is its own entry, one row apiece — the FilmSpecialSorting
        // constants are already written in the sentence case a standalone row wants, so
        // they are used verbatim rather than lowercased for splicing mid-sentence as the
        // joined clause required.
        //
        // These rows are NOT gated on `!isPlaceholder`. A film whose countdown resolves
        // to "Unknown" (watched, but with an unparseable or missing date) can still carry
        // a special sorting parameter, and that parameter is exactly the kind of fact the
        // user needs to see at a glance — suppressing it made the only surface that
        // reports it disappear for that class of film, since Metadata deliberately no
        // longer duplicates the field. The Film Queue note below remains suppressed for
        // placeholders: queue membership is a statement about an active rotation, which
        // an unknown countdown does not describe.
        var specialSortingNotes: [String] = []
        if film.specialSorting.contains(FilmSpecialSorting.waitingForEdit)     { specialSortingNotes.append(FilmSpecialSorting.waitingForEdit) }
        if film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold)  { specialSortingNotes.append(FilmSpecialSorting.temporarilyOnHold) }
        if film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold) { specialSortingNotes.append(FilmSpecialSorting.indefinitelyOnHold) }

        // Resolve the Film Queue note, if the film currently belongs to one of the
        // three internal Film Queue sections (Up Next, Soon, Later). Suppressed
        // alongside the special sorting notes whenever the row is a placeholder
        // value ("Unknown").
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

    /// The "Recorded View Count" plate's trailing inset, tightened from the standard 8pt.
    ///
    /// This field is the narrowest in the module — it shares a row with "Average Between
    /// Viewings", so it gets half of the sidebar's 268pt of content, 128pt — and the glyph
    /// gutter takes 22 of that. At the standard inset the widest values it can produce
    /// ("44 (since 2004)" is 91.3pt against 90pt of room; `4` is the widest digit in the
    /// system font at this size) overflow by a point or two and wrap to a second line, which
    /// also drags the neighboring column's row taller. 4pt clears every two-digit count with
    /// room to spare, and is a point past the 5pt where the worst case first fits.
    ///
    /// Applied unconditionally rather than only to values that need it: the fill spans the
    /// full column either way, so a value that does not reach the trailing edge renders
    /// identically at 4 or 8 — the condition would buy nothing but a branch that could
    /// mis-fire near the boundary.
    ///
    /// A triple-digit count would still wrap. That is accepted, not overlooked.
    ///
    /// "Average Between Viewings", the other half of the row, uses it too: its
    /// "Insufficient data" placeholder is 91.6pt against the same 90pt. Its numeric values
    /// never come close (a five-digit day count is about 68pt).
    private static let viewCountTrailingInset: CGFloat = 4
    
    // Helper to calculate view count data
    private func calculateViewCountData(for film: FilmSnapshot) -> (formattedValue: String, isPlaceholder: Bool) {
        let count = film.calendarTable.count
        
        if count == 0 {
            return ("None recorded", true)
        }
        
        // Find the oldest year in calendarTable.
        // Note: entries may be "YYYY.MM.DD" or "YYYY.MM.DD.XX" - we only need the year.
        // `first` rather than an index plus a count check: splitting a non-empty string
        // on "." yields at least one component in every case except an entry made up
        // entirely of dots, which `first` reports as nil and the index form guarded for
        // separately. One optional chain covers both.
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
        // Derive display state from the derived values only — no live snapshot reads.
        // cachedCalendarTableCount and cachedAverageBetweenViewings are computed from
        // the same film value in the same render, so they cannot disagree.
        let displayValueAndPlaceholder: (String, Bool) = {
            switch cachedCalendarTableCount {
            case 0:  return ("None recorded", true)
            case 1:  return ("Insufficient data", true)
            default:
                let value = cachedAverageBetweenViewings
                // An empty value with 2+ entries means the entries exist but fewer
                // than two of them parsed into usable dates (calculateAverageBetween-
                // Viewings drops unparseable ones before pairing). That is the same
                // "there are viewings, just not enough to measure an interval" state
                // as the single-entry case, so it reads identically. "None recorded"
                // was wrong here and directly contradicted the adjacent Recorded View
                // Count field, which reports the raw entry count and would be showing
                // a non-zero number beside it.
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
    
    // Helper to calculate average between viewings.
    //
    // The parsed `Date`s are carried through to the interval arithmetic rather than being
    // discarded in favor of the raw strings. This previously sorted on the parsed dates,
    // mapped back to the originals, and then handed each consecutive pair to
    // `daysBetween(from:to:)`, which parsed both again — three parses per entry instead of
    // one, on a path that reruns for every film selection. The arithmetic below is
    // `daysBetween`'s own, applied to the very Dates that function would have recovered
    // from those strings, so the result is unchanged.
    //
    // Dropping the re-parse also retires the "some intervals failed to parse" bookkeeping
    // it required. Every entry still in `sortedDates` parsed successfully to get there, so
    // the interval count is exactly `count - 1`, which the guard below already establishes
    // as at least 1 — the old `validIntervals > 0` guard could never fail.
    // `averageBetweenViewingsSection`'s "Insufficient data" state (entries present, fewer
    // than two of them usable) is still reached by the empty string that guard returns,
    // which remains the only way this reports nothing.
    private func calculateAverageBetweenViewings(for film: FilmSnapshot) -> String {
        // Sort dates from most to least recent.
        let sortedDates = film.calendarTable
            .compactMap { parseDate(from: $0) }
            .sorted(by: >)

        // Need at least 2 viewings to calculate an average.
        guard sortedDates.count >= 2 else {
            return ""
        }

        let calendar = AppCalendar.current
        var totalDays = 0

        // Days between each consecutive pair, matching daysBetween(from:to:) exactly —
        // same calendar, same single `.day` component, same absolute value.
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
        // When the film is edited and a non-empty editedDuration value is available,
        // the primary value (edited runtime) is rendered at full prominence and the
        // "(originally X hr. Y min.)" suffix is rendered in secondary color to reduce
        // its visual weight. Text concatenation (+) is used to mix foreground styles
        // within a single layout run.
        // When editedDuration is absent, falls back to the standard duration string.
        // When neither value is present, shows the standard placeholder.
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

    /// The Duration row's composed value: the primary runtime at full prominence, and — when
    /// the film is edited — the original runtime as a tertiary parenthetical.
    ///
    /// `abbreviatingPrimary` selects the spelling of the PRIMARY value only. The parenthetical
    /// is always abbreviated, as it has been: it is the lesser of the two figures and was
    /// never given the long spelling to lose.
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

    /// The shorter candidate `fittingValueRow` falls back to when the full spelling would wrap
    /// — "1 hr. 47 min." for "1 hour 47 minutes".
    ///
    /// `nil` when there is nothing to shorten, which skips the measurement entirely: the
    /// placeholder has no abbreviation, and neither does a primary value whose short form is
    /// missing or already identical to the long one ("0 min." is spelled the same either way).
    /// That matches how every other row in the module offers its abbreviation — as a candidate,
    /// never as an imposition.
    private var durationAbbreviatedRowText: Text? {
        let full = cachedEditedDuration.isEmpty ? cachedDuration : cachedEditedDuration
        let short = cachedEditedDuration.isEmpty ? cachedDurationAbbreviated : cachedEditedDurationAbbreviated
        guard !full.isEmpty, !short.isEmpty, short != full else { return nil }
        return durationRowText(abbreviatingPrimary: true)
    }

    // MARK: - Field Glyphs
    //
    // The symbols that precede this module's value and annotation rows, all behind the user
    // preference `showWatchDetailsAnnotationGlyphs` — read here as `showAnnotationGlyphs`,
    // the @AppStorage member declared at the top of this view. They are decoration for values
    // that already read unambiguously on their own, so the preference turns every one of them
    // off together rather than leaving a partial set.
    //
    // The single exception is the "Source for Viewing" disc, which
    // `Preferences.purchasedDiscGlyphVisibilityOverride` can exempt from the preference; see
    // `sourceValueGlyph`.
    //
    // Naming a glyph is a per-ROW decision, not a per-row-kind one: the special-sorting rows
    // share a builder, but not a symbol.
    //
    // None of them is drawn inline. Every one goes in the fixed-width gutter that
    // `RSBHelpers.sidebarRowContainer(glyph:)` reserves, so no row's text starts at a
    // different offset than another's and no symbol can make a row taller.

    /// The Film Queue membership note's glyph, shared by all three sections (Up Next, Soon,
    /// Later) — the note names which queue, and the symbol only marks it as a queue row.
    ///
    /// Read from `RSBHelpers` rather than spelled out here: ListTable draws the same mark
    /// for the same fact in the List Membership table, and the two were previously three
    /// separate literals kept matched by comment. See `RSBHelpers.queueMembershipGlyph`.
    private static let queueNoteGlyph = RSBHelpers.queueMembershipGlyph

    /// The "Available for purchase on <format>" note's glyph.
    private static let purchaseNoteGlyph = "cart.fill.badge.questionmark"
    private static let preorderNoteGlyph = "calendar.badge.clock"

    /// The tint a value row's glyph is drawn in.
    ///
    /// The original rule was simply "whatever the text beside it uses", which put a glyph
    /// beside a normal value at full `.primary` — the same weight as the value itself, for a
    /// mark that only labels it. `Preferences.capWatchDetailsGlyphColorAtSecondary` caps that
    /// at `.secondary` so the glyph reads as an annotation on the value rather than as part
    /// of it. A placeholder row's tertiary gray is already below the cap and passes through
    /// either way, so an empty field's glyph stays as faint as its text.
    ///
    /// `opticaldisc.fill` is exempt: it denotes a purchased release, which is a fact about
    /// the film rather than decoration on the row, and it is the one glyph in the module a
    /// user may be reading FOR rather than reading past.
    ///
    /// Annotation rows do not come through here — `annotationRow` already defaults to
    /// `.secondary`, which is what this cap would give them anyway.
    private func glyphTint(isPlaceholder: Bool, symbol: String? = nil) -> Color {
        if isPlaceholder { return Color(nsColor: .tertiaryLabelColor) }
        if symbol == "opticaldisc.fill" { return .primary }
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
    /// gets the right symbol, while a renamed fixed string would fall through to the clock —
    /// so the fixed spellings are written here exactly as that function writes them.
    private func rotationValueGlyph(_ formattedValue: String) -> String? {
        switch formattedValue {
        case "Blacklisted", "Ignored": return gatedGlyph("xmark")
        case "Ready for viewing":      return gatedGlyph("checkmark")
        case "Unknown":                return gatedGlyph("questionmark")
        default:                       return gatedGlyph("deskclock")
        }
    }

    /// The "Source for Viewing" value row's glyph: the disc for a purchased disc-based
    /// source, a document for everything else, and the document's outline form for the
    /// "None provided" placeholder — an unfilled symbol for an unfilled field.
    ///
    /// The disc is the one glyph that can outrank the user's preference. With
    /// `Preferences.purchasedDiscGlyphVisibilityOverride` on it bypasses the gate entirely
    /// and is always drawn; with it off it is gated like everything else. Either way it is
    /// drawn in the gutter — the inline composition it used to fall back to when glyphs were
    /// off is gone, so the disc's position and size no longer depend on the preference.
    private func sourceValueGlyph(isPurchasedDisc: Bool, isPlaceholder: Bool) -> String? {
        if isPurchasedDisc {
            return Preferences.purchasedDiscGlyphVisibilityOverride
                ? "opticaldisc.fill"
                : gatedGlyph("opticaldisc.fill")
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

    /// Composes the "Source for Viewing" value row: the optional disc glyph followed by
    /// the value. Extracted from the @ViewBuilder context because Text + Text
    /// concatenation is not a valid @ViewBuilder expression — the result type is Text,
    /// not a View the builder can emit directly.
    ///
    /// The glyph is inlined as a Text attachment so it participates in the text's own
    /// layout flow. When the value wraps, subsequent lines return to the text's left
    /// edge — directly beneath the glyph — rather than indenting past it as they would
    /// in an HStack column arrangement. A kerned space separates the glyph from the
    /// text, approximating the original 5pt HStack gap at 12pt.
    /// This row's value text, plain. The disc glyph it used to compose inline is now drawn
    /// in the leading gutter by `sourceValueGlyph`, in every state of every preference, so
    /// the value and its abbreviation are just text.
    ///
    /// Kept as a function rather than folded into its two call sites because both candidates
    /// handed to `fittingValueRow` must be built the same way for the measurement to mean
    /// anything.
    private func sourceRowText(displayValue: String, valueColor: Color) -> Text {
        Text(displayValue).foregroundStyle(valueColor)
    }

    @ViewBuilder
    private var sourceSection: some View {
        let source = cachedSourceDisplay
        let isPlaceholder = source.value.isEmpty
        let displayValue = isPlaceholder ? "None provided" : source.value
        // Both notes stay suppressed for the "None provided" placeholder, as they were
        // when they hung off the end of the value: with no source recorded there is no
        // statement for them to qualify. The purchase-availability note can now sit
        // beside a purchased Blu-ray disc (e.g. an owned Blu-ray with an unpurchased 4K
        // reads "Available for purchase on 4K UHD"), so it and the Region B note are no
        // longer mutually exclusive; each is emitted independently by sourceDisplay.
        let purchaseNote = isPlaceholder ? "" : source.availableForPurchaseNote
        let regionBNote = isPlaceholder ? "" : source.regionBLockNote
        let preorderNote = isPlaceholder ? "" : source.preorderReleaseNote
        let valueColor: Color = isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary
        // Resolved once and used for both the glyph itself and the tint decision that
        // depends on which glyph it is. Called separately at the two sites, the symbol
        // was derived twice per render and — more to the point — the two calls had to be
        // kept identical by hand for `glyphTint`'s `opticaldisc.fill` exemption to be
        // asking about the symbol actually drawn.
        let valueGlyph = sourceValueGlyph(isPurchasedDisc: source.isPurchasedDiscSource,
                                          isPlaceholder: isPlaceholder)

        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Source for Viewing")
            // Three words in a source value are long enough to be worth shortening and
            // safe to shorten: "remastered" ("rem."), the origin demonym ("Australian" →
            // "AU") and the studio shorthand ("Universal" → "Uni"). Every other component
            // ("Blu-ray disc", "4K disc", "rip", the year) is already short. As everywhere
            // else, a short form is used only when the longer one would wrap; a value with
            // none of the three words offers no alternative at all. The origin's and the
            // studio's compact forms come from sourceDisplay rather than from text
            // substitution — see SourceDisplay.originAbbreviatedValue for why.
            //
            // Composed through sourceRowText for every candidate so all of them are
            // measured the same way as the full value.
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
            // Region B first: it describes the very disc named on the value row, and
            // stays .primary because a hard playback restriction warrants the same
            // attention as the value it qualifies. Purchase availability is the lesser
            // aside and takes annotationRow's default .secondary.
            if !regionBNote.isEmpty {
                RSBHelpers.annotationRow(regionBNote, color: .primary)
            }
            // Built as a fitting row rather than a plain annotationRow so an upcoming
            // release's date can drop to its abbreviated month ("Oct. 2, 2026") instead
            // of wrapping, exactly as the module's other date rows do. Styled to match
            // annotationRow: .secondary text and glyph, always selectable.
            // A pre-ordered disc's release date, styled as the purchase note below it.
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
        // Built on the store's current snapshot, not the sidebar's copy: the table computed
        // below REPLACES the stored calendarTable, so a copy that lagged a save would erase
        // whatever viewings that save added.
        let film = dataCoordinator.getFilm(displayedFilm.id) ?? displayedFilm
        let dateFormatter = Self.viewingDateFormatter
        let baseDateString = dateFormatter.string(from: date)

        // Build full date string with version code (e.g. "2025.06.14.tc")
        // CRITICAL: lastWatched must store the base date only, never the version code
        let fullDateString: String
        if version.rawValue.isEmpty {
            fullDateString = baseDateString
        } else {
            fullDateString = "\(baseDateString).\(version.rawValue)"
        }

        // Build new calendarTable as a local copy - do NOT mutate the live Film object
        var newCalendarTable = film.calendarTable
        let existingBaseDates = newCalendarTable.compactMap { extractDatePortion(from: $0) }
        // Defense-in-depth: UnifiedViewingPopover already rejects a duplicate date up
        // front (with a visible "Event Already Exists" alert) before this closure is
        // ever invoked, so this guard should be unreachable in the normal UI flow.
        // It is retained so this method can never silently create a second viewing
        // entry for the same calendar day even if called from an unexpected path.
        if !existingBaseDates.contains(baseDateString) {
            newCalendarTable.append(fullDateString)
        }

        // Compute new lastWatched - only advance it if this date is more recent.
        //
        // Parsed with the app-wide canonical `parseDate(from:)` rather than the strict
        // "yyyy.MM.dd" formatter above. The two are NOT interchangeable here: the
        // formatter accepts only the dot format, while `lastWatched` is merely
        // guaranteed to have had version codes and trailing dots stripped (see
        // DBRestorer's `cleanedLastWatched` and FilmSheet's derivation) — a dash-format
        // or ISO value surviving an import parses fine everywhere else in this file
        // (calculateRotationData, formatDateWithTimeAgo) but failed here, dropping into
        // the unconditional-overwrite branch below. Recording an OLDER viewing for such
        // a film then silently rewound lastWatched to that older date.
        var newLastWatched = film.lastWatched
        if let existingDate = parseDate(from: film.lastWatched) {
            if date > existingDate { newLastWatched = baseDateString }
        } else {
            // No parseable lastWatched date yet - set it unconditionally.
            newLastWatched = baseDateString
        }

        // Delegate to coordinator: MemoryStore-first, background persistence, rollback on failure
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
        // Intentionally not logged here — onAppear and onChange(of: film, initial: true)
        // both fire once per fresh WatchDetails mount, and the resulting calendar status
        // is folded into that single consolidated log line instead of being logged twice.
    }
    
    private func handleViewingButtonClick() {
        // Fresh open: clear any leftover pending entry so the popover seeds itself
        // with blank defaults rather than a stale snapshot from an earlier session.
        // (The reopen path after a duplicate-date alert does NOT go through this
        // function — see the .reopenViewingEventPopover handler below — so a
        // rejected entry is never wiped out by this reset before it can be restored.)
        pendingViewingEntry = nil

        // If Preferences.iCalIntegration is enabled and permission has not yet been
        // granted, route the request through EventKitManager so its cache, polling
        // loop, and event bus notifications all stay coherent.
        if iCalIntegration {
            let currentStatus = EventKitManager.shared.authorizationStatus
            
            if currentStatus == .notDetermined {
                log("iCal integration enabled, requesting calendar access...")
                let requestingFilmID = film?.id
                permissionPendingFilmID = requestingFilmID
                Task {
                    let granted = await EventKitManager.shared.requestAccessIfNeeded()
                    log("Access granted: \(granted)")
                    // calendarAccessStatus is kept in sync via the calendarAuthorizationChanged
                    // event bus notification that EventKitManager fires on status change.
                    //
                    // Open only for the film that was clicked, and only while the Details tab
                    // is the one on screen: the permission prompt can sit for as long as the
                    // user likes, and in the meantime the film may have changed (which clears
                    // the pending id) or the tab may have slid away, leaving the popover's
                    // anchor off-screen.
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
        
        // Otherwise, just show the popover
        showViewingPopover = true
    }
    
    /// Flashes the confirmation checkmark on the "Add Viewing Event" button for three
    /// seconds. The reset is held in `checkmarkResetTask` and canceled on re-entry so
    /// that consecutive viewings restart the full three-second window rather than
    /// leaving an earlier timer running to clear the checkmark early — with a detached
    /// task per call, adding two viewings in quick succession had the first call's
    /// timer expire partway through the second call's display.
    ///
    /// Deliberately NOT wrapped in `withAnimation`: the symbol swap carries its own
    /// value-scoped `.animation` on the Image. A transaction-wide animation here also
    /// animated the tab relayout that addViewing() triggers in the same update pass.
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
