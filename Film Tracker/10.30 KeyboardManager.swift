// MARK: - KeyboardManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Consolidated keyboard event handling for FilmTracker.
// Intercepts keyboard events at the NSEvent level to ensure reliable shortcut handling.

import AppKit
import SwiftUI

@MainActor
@Observable
final class KeyboardManager {
    static let shared = KeyboardManager()
    
    private var localMonitor: Any?
    private weak var appState: AppState?
    private weak var selectionState: SelectionState?
    private weak var dataCoordinator: DataCoordinator?
    
    init() {}
    
    // MARK: - Setup
    
    func setup(appState: AppState, selectionState: SelectionState, dataCoordinator: DataCoordinator) {
        self.appState = appState
        self.selectionState = selectionState
        self.dataCoordinator = dataCoordinator
        
        // Remove existing monitor if any
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        
        // Set up local monitor to intercept events before responder chain
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Handle event synchronously
            if self.handleKeyEvent(event) {
                return nil // Consume event
            }
            return event // Pass through
        }
    }
    
    // MARK: - Event Handling
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Whether any sheet is active. Two sources are OR'd, so a mismatch between them during
        // a sheet's presentation or dismissal animation cannot leave a gap where a blocked
        // shortcut fires:
        //   • AppKit window state: the key window is a sheet, or the main window has an attached sheet.
        //   • SheetCoordinator: its activeSheet is non-nil.
        let isInSheet: Bool = {
            // AppKit window-level check
            if let keyWindow = NSApp.keyWindow, keyWindow.isSheet || keyWindow.sheetParent != nil {
                return true
            }
            if let mainWindow = NSApp.mainWindow, mainWindow.attachedSheet != nil {
                return true
            }
            // App-level coordinator check (guards the transition window during animation)
            if appState?.sheetCoordinator.activeSheet != nil {
                return true
            }
            return false
        }()
        
        // Whether text input is active in the key window or any sheet.
        let textInputActive = isTextInputActiveAnywhere()
        
        // Every shortcut below compares against these modifiers. `normalizedModifiers`
        // (InputUtilities.swift) strips device-specific bits and CapsLock. CapsLock is part of
        // .deviceIndependentFlagsMask, so with raw flags every exact `modifiers == …` test
        // failed while CapsLock was on.
        let modifiers = event.normalizedModifiers
        
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let char = characters.first else {
            return false
        }
        
        // MARK: Return Key — FilmSheet Confirm Fallback
        //
        // AppKit's text fields consume Return during "end editing" and never pass it up the
        // responder chain, so the sheet's default button (Add/Update) never sees it. SwiftUI
        // updates (canConfirm flips) can also reassign first responder away from
        // FilmSheetSinkButton to a text field in the keep-alive ZStack.
        //
        // So plain Return is intercepted here when a FilmSheet is the key window, no text field
        // is being edited (an active field takes Return first; see below), canConfirm is true,
        // and no confirm is already running. This runs before the textInputActive check, as Cmd+N
        // and Cmd+Delete on the Releases tab do, so stale first-responder state cannot block it.
        //
        // Three things must be guarded against firing confirm() by mistake:
        // A) A key-stealing popover: SwiftUI can present a popover as its own key window
        //    (isSheet == false). The keyWindow.isSheet check below excludes this — the
        //    popover's own default button handles Return.
        // B) A non-activating popover panel: keyWindow is still the sheet (isSheet ==
        //    true), but SwiftUI popovers always attach as a child window of the
        //    presenting window. hasVisibleChildWindow(on:) catches this and passes
        //    Return through to the popover instead.
        // C) A nested alert (e.g. an FSTabReleases confirmation .alert()): SwiftUI's
        //    .alert() is backed by the same native sheet mechanism as FilmSheet itself,
        //    so the alert becomes keyWindow with isSheet == true and no child windows of
        //    its own — neither A nor B catches it. Without a separate check this would
        //    fire filmSheet.confirm() while the alert's own presentation/dismissal
        //    animation is in flight, contending for the main thread (the same class of
        //    Core Animation contention documented in ReleasesView's requestDelete).
        //    sheetParent?.isSheet != true distinguishes the base case (FilmSheet's
        //    sheetParent is the main window, not itself a sheet) from the nested case
        //    (a nested alert's sheetParent is FilmSheet's window, which is a sheet).
        if modifiers == [] && event.keyCode == 36 {
            if let keyWindow = NSApp.keyWindow, keyWindow.isSheet,
               keyWindow.sheetParent?.isSheet != true,
               !hasVisibleChildWindow(on: keyWindow),
               let activeSheet = appState?.sheetCoordinator.activeSheet,
               let confirm = Self.returnConfirmAction(for: activeSheet) {
                // Pass through whenever ANY text is being edited — the first responder is
                // an NSTextView in both cases below. The sheet's rule is that an active
                // field takes Return first; the field finishes editing (or, for a table
                // row's editor, commits the row) and gives up focus, and it is the NEXT
                // Return, with no field active, that reaches this intercept and saves.
                //
                //   • A multi-line FixedHeightScrollingTextView ends its own editing on
                //     Return (FSTextHelpers.swift, doCommandBy).
                //   • A single-line NSTextField edits through the window's shared field
                //     editor, whose delegate is the owning NSTextField itself — never an
                //     NSCell. FilmSheetView's key monitor ends its editing, except for a
                //     string-list row's editor, which commits its row on Return.
                if keyWindow.firstResponder is NSTextView {
                    return false
                }
                confirm()
                return true // Consume — confirm() was fired directly.
            }
        }

        // MARK: Tab Key — Direct Gallery Focus
        // With a gallery view active and no sheet or text input, plain Tab moves first responder
        // straight to the gallery collection view. AppKit's default traversal would cross every
        // intermediate control first (toolbar search field, "+" menu, right sidebar). One Tab
        // from the LeftSidebar lands on the grid and selects item 0 (via seedInitialCursor).
        if modifiers == [] && char == "\t" {
            // Only apply in gallery views; pass through in all other views so that
            // Tab retains its default traversal behavior in Reports, Imports, etc.
            guard let appState = appState,
                  appState.selectedSidebarItem.capabilities.routesTabFocusToGallery else {
                return false
            }
            // Never intercept when a sheet is active or text input is focused.
            guard !isInSheet, !textInputActive else {
                return false
            }
            // Move first responder directly to the gallery collection view.
            // If the collection view cannot be located (e.g., empty gallery showing
            // a placeholder), pass through so the event is not silently swallowed.
            if focusGalleryGrid() {
                return true
            }
            return false
        }
        
        // MARK: Text Editing Shortcuts - Pass Through When Text Active
        // Cmd+X, Cmd+C, Cmd+V - Cut/Copy/Paste
        // Always pass through to responder chain when text input is active
        if modifiers == .command && (char == "x" || char == "c" || char == "v") {
            if textInputActive {
                return false // Pass through to responder chain for native text editing
            }
            // If sheet is active but no text field focused, consume to prevent unintended actions
            if isInSheet {
                return true // Consume event
            }
            // Otherwise pass through
            return false
        }
        
        // Cmd+A - Select All (special handling for text fields vs gallery)
        if modifiers == .command && char == "a" {
            // If text field is focused anywhere (including in sheets), let native handling work
            if textInputActive {
                return false // Pass through to responder chain for native text selection
            }
            
            // If sheet is active but no text field focused, block the action
            guard !isInSheet else {
                return true // Consume event to prevent action behind sheet
            }
            
            // Not in sheet, no text field - trigger custom film selection if in a valid view.
            guard let appState = appState else { return false }
            
            if appState.selectedSidebarItem.capabilities.supportsMultiSelection {
                AppEventBus.shared.selectAllFilms()
                return true // Consume event
            }
            
            // View doesn't support selection — pass through.
            return false
        }
        
        // Cmd+I - Edit Film (alternative to Cmd+E, which is handled via MenuBar)
        if modifiers == .command && char == "i" {
            // If text field is focused, let native handling work (for italic formatting in rich text)
            if textInputActive {
                return false // Pass through to responder chain
            }
            
            guard !isInSheet else { return false }
            return handleEditFilm(isInSheet: isInSheet)
        }
        
        // Cmd+L - Scroll gallery to the topmost selected film (single or multi-selection)
        if modifiers == .command && char == "l" {
            if textInputActive {
                return false // Pass through to responder chain
            }
            guard !isInSheet else { return true }
            // No-op unless at least one film is selected
            guard let selectionState = selectionState,
                  !selectionState.selectedFilmIDs.isEmpty else { return true }
            AppEventBus.shared.sendCommand(.scrollToSelection)
            return true
        }
        
        // MARK: Application Shortcuts
        // Opt+A - Add Film (no sheet). With a sheet open, it opens the Viewing Dates add popover
        // on the Details tab (ViewingDatesTable owns that trigger) and does nothing elsewhere.
        if modifiers == .option && char == "a" {
            if isInSheet {
                if activeFilmSheet(showing: .details) != nil {
                    AppEventBus.shared.sendCommand(.openViewingDatesAddPopover)
                    return true
                }
                return true // Sheet active but not a routed tab — block background action
            }
            return handleAddFilm(isInSheet: isInSheet)
        }
        
        // Opt+1-5 - Sheet tab navigation (when sheet is active) OR RightSidebar tabs (when no sheet)
        // When a sheet is open, all five digits route to sheet tab navigation.
        // When no sheet is open, digits 1-3 route to RightSidebar tab switching
        // (digits 4-5 have no out-of-sheet binding and fall through).
        if modifiers == .option && (char == "1" || char == "2" || char == "3" || char == "4" || char == "5") {
            if isInSheet {
                return handleSheetTabNavigation(char)
            }
            // No sheet — route 1-3 to RightSidebar tabs; 4-5 fall through to end of handler.
            if char == "1" || char == "2" || char == "3" {
                return handleRightSidebarTab(char)
            }
        }
        
        // Cmd+Up / Cmd+Down - Step backward / forward through a tab stack, wrapping at either end:
        // the FilmSheet or SettingsSheet tabs while a sheet is open, otherwise the current view's
        // own tabs (Opt+Cmd+1-9). Passes through in other views and while text is being edited,
        // where Cmd+Up/Down is AppKit's move to the beginning or end of the document.
        //
        // Arrow keys carry .numericPad and .function, so those are stripped before comparing.
        if modifiers.subtracting([.numericPad, .function]) == .command,
           event.specialKey == .upArrow || event.specialKey == .downArrow {
            guard !textInputActive else { return false }
            let forward = event.specialKey == .downArrow
            if isInSheet {
                return handleSheetTabCycle(forward: forward)
            }
            return handleInViewTabCycle(forward: forward)
        }

        // Opt+Cmd+S - Toggle Left Sidebar
        if modifiers == [.option, .command] && char == "s" {
            guard !isInSheet else { return false }
            AppEventBus.shared.sendCommand(.toggleLeftSidebar)
            return true
        }
        
        // Opt+Cmd+1-9 - In-view tab switching for the Unwatched view, Recents, Reports, Imports,
        // the Film Queue, or a smart-list family. Nine digits cover the largest tab group.
        // Outside those views the event passes through.
        if modifiers == [.option, .command],
           let tabNum = Int(String(char)), tabNum >= 1 && tabNum <= 9 {
            guard !isInSheet else {
                return true // Consume to prevent background actions
            }
            if handleInViewTabNavigation(tabNum) {
                return true
            }
            // Not in a tabbed view — pass through, so the event still reaches the menu
            // system and anything else that may claim it. The sibling Opt+Cmd+N branch
            // below relies on the same pass-through behavior.
            return false
        }
        
        // Opt+Cmd+N - Add a 4K UHD release, when a FilmSheet is open on the Releases tab.
        //
        // Deliberately scoped to that one context and NOT consumed otherwise: Opt+Cmd+N is
        // "Duplicate List" in the File menu, which is only offered when a list is selected
        // and is disabled while any sheet is active. Falling through when the condition
        // does not hold leaves that binding exactly as it was.
        //
        // ORDERING: like Cmd+N below, the Releases intercept is evaluated BEFORE
        // textInputActive — see the long note there for why a stale first responder would
        // otherwise break the shortcut for the rest of the session.
        if modifiers == [.option, .command] && char == "n" {
            if let filmSheet = activeFilmSheet(showing: .releases) {
                guard filmSheet.releasesTab?.canAddRelease() == true else { return true }
                AppEventBus.shared.sendCommand(
                    .addReleaseToActiveSheet(format: ReleaseFormat.uhd4K.rawValue))
                return true // Consumed
            }
        }

        // Opt+Cmd+E - Edit Film, opening the FilmSheet directly on its Metadata tab.
        // Same gating as Cmd+I: exactly one film selected and no sheet already open.
        if modifiers == [.option, .command] && char == "e" {
            if textInputActive {
                return false
            }
            
            guard !isInSheet else { return false }
            return handleEditFilmMetadata()
        }
        
        // Cmd+N - Create New List (with fallback handling)
        // Special case: when a FilmSheet is active and showing the Releases tab,
        // forward as addReleaseToActiveSheet(format: Blu-ray) instead of blocking the event.
        //
        // ORDERING: the Releases-tab intercept runs BEFORE the textInputActive check. After
        // interacting with pickers, checkboxes or text fields on another tab, the first responder
        // can stay a view that isTextInputActiveAnywhere() matches. Checking text input first
        // would then pass Cmd+N through until focus moves. Cmd+N has no text-editing meaning in
        // any AppKit control, so intercepting it never disrupts text entry.
        if modifiers == .command && char == "n" {
            // If a FilmSheet is open on the Releases tab, route Cmd+N to add a release
            // regardless of what currently holds first responder.
            if let filmSheet = activeFilmSheet(showing: .releases) {
                // Only add if the carousel is under its ten-card cap.
                //
                // Asks the view model rather than counting here, so this gate and the menu's own
                // cannot disagree about what the cap counts (cards, not releases: a combo pack is
                // one card). A nil releasesTab has no room, so the event is consumed.
                guard filmSheet.releasesTab?.canAddRelease() == true else { return true }
                // Cmd+N is the Blu-ray shortcut; Opt+Cmd+N above is the 4K one.
                AppEventBus.shared.sendCommand(
                    .addReleaseToActiveSheet(format: ReleaseFormat.bluRay.rawValue))
                return true // Consumed
            }
            
            // If text field is focused (and not on the Releases tab), let native
            // handling work — pass through to the responder chain.
            if textInputActive {
                return false
            }
            
            // Sheet is active but not a Releases-tab FilmSheet — block the shortcut
            // to prevent triggering a background action.
            if isInSheet {
                return true
            }
            
            // Try to handle the shortcut directly as a fallback.
            if handleCreateNewList() {
                return true // Consumed - we handled it
            }
            
            // If we couldn't handle it, pass through to MenuBar.
            return false
        }
        
        // Cmd+Delete - Delete the visible release card on the Releases tab. "Delete" produces
        // U+0008 via charactersIgnoringModifiers; U+007F is forward-delete (Fn+Delete).
        //
        // ORDERING: as for Cmd+N, the Releases-tab intercept runs BEFORE the textInputActive check.
        // Cmd+Delete deletes to line start in text fields, so on every other tab text input keeps
        // its pass-through. On the Releases tab a precise field-editor test takes its place (below).
        if modifiers == .command && (char == "\u{8}" || char == "\u{7F}") {
            // If a FilmSheet is open on the Releases tab, route Cmd+Delete to delete
            // the current release regardless of what currently holds first responder.
            if let filmSheet = activeFilmSheet(showing: .releases) {
                // A field being edited keeps Cmd+Delete as line deletion. Tested precisely (the key
                // window's first responder is a field editor or text view) rather than with
                // isTextInputActiveAnywhere(), whose heuristics can latch. Without this check,
                // clearing a line in a release's Notes or cost field deleted the whole release.
                if NSApp.keyWindow?.firstResponder is NSText { return false }
                let releasesTab = filmSheet.releasesTab
                // Guard: card animations must have settled, and a card must be visible.
                guard releasesTab?.isTransitioning == false else { return true }
                // The carousel is a single stack, so a card is visible exactly when it has any.
                guard releasesTab?.carouselEntries.isEmpty == false else { return true }
                AppEventBus.shared.sendCommand(.deleteReleaseFromActiveSheet)
                return true // Consumed
            }
            
            // Not on the Releases tab — pass through when text input is focused so
            // Cmd+Delete continues to perform word/line deletion in text fields.
            if textInputActive {
                return false
            }
            
            // Sheet is active but not a Releases-tab FilmSheet — block the shortcut
            // to prevent triggering a background action.
            if isInSheet {
                return true
            }
            
            // No sheet — pass through so the system/responder chain can handle it.
            return false
        }
        
        // Opt+Delete - Remove selected film(s) from the current user-generated list.
        //
        // WHY THIS IS NOT A MENU ITEM: Opt+Delete is AppKit's "delete word backward" binding.
        // GalleryCollectionView's super.keyDown(with:) consumes it before key-equivalent matching
        // runs, so it is intercepted here, at the local event monitor.
        if modifiers == .option && (char == "\u{8}" || char == "\u{7F}") {
            // Opt+Delete has no text-editing meaning beyond "delete word backward", which is
            // irrelevant in a gallery context. Pass through when a text field is focused so
            // native word-deletion still works in text entry areas.
            if textInputActive {
                return false
            }
            
            // Inside a sheet, pass the event through. Consuming it would starve the sheet's own
            // Opt+Delete bindings (the reorderable lists' delete controls for the row being edited),
            // because a local monitor runs before key-equivalent matching. Where no such binding
            // exists, the event reaches the responder chain as usual.
            if isInSheet {
                return false
            }
            
            // Attempt the remove-from-list action; consume the event regardless of outcome
            // (a no-op is preferable to accidentally feeding "delete word backward" to
            // whatever AppKit view happens to be first responder).
            handleRemoveFromCurrentList()
            return true
        }
        
        // Shift+Cmd+N - Create New List from Selection (with fallback handling)
        if modifiers == [.command, .shift] && char == "n" {
            // If text field is focused, let native handling work
            if textInputActive {
                return false // Pass through to responder chain
            }
            
            // Block if sheet is active
            if isInSheet {
                return true // Consume event to prevent action behind sheet
            }
            
            // Try to handle the shortcut directly as a fallback
            if handleCreateNewListFromSelection() {
                return true // Consumed - we handled it
            }
            
            // If we couldn't handle it, pass through to MenuBar
            return false
        }
        
        // Cmd+0-9 - LeftSidebar navigation (with fallback handling)
        // Block when sheet active OR text input active, otherwise handle directly as fallback
        if modifiers == .command {
            switch char {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9", "0":
                // Block if sheet is active or text input is active
                if isInSheet || textInputActive {
                    return true // Consume the event to prevent action
                }
                
                // Try to handle the shortcut directly as a fallback
                // This bypasses the menu system which can fail validation in certain views (like search)
                if handleLeftSidebarNavigation(char) {
                    return true // Consumed - we handled it
                }
                
                // If we couldn't handle it, pass through to MenuBar
                // This allows the menu system to work when it's valid
                return false
                
            default:
                break
            }
        }
        
        // Shift+Cmd+D - Find Duplicates, matching MenuBar's
        // .keyboardShortcut("d", modifiers: [.command, .shift]).
        //
        // An exact match, like the other branches, since `modifiers` is already normalized.
        if modifiers == [.command, .shift] && char == "d" {
            return handleFindDuplicates(isInSheet: isInSheet)
        }
        
        // Cmd+/ - Toggle Status Bar
        // Mirrors clicking the "Show Status Bar" checkbox in General Settings in real-time.
        // Allowed from any app context (including when a sheet is open) since this toggles
        // main-window chrome, not film data. Blocked only when text input is focused, as
        // Cmd+/ is a common comment shortcut in text editors and should not be hijacked.
        if modifiers == .command && char == "/" {
            if textInputActive {
                return false // Pass through — let the responder chain handle it
            }
            Preferences.showStatusBar.toggle()
            return true
        }
        
        return false
    }
    
    // MARK: - Handler Methods
    
    private func handleAddFilm(isInSheet: Bool) -> Bool {
        guard !isInSheet else { return false }
        
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        AppEventBus.shared.sendCommand(.addFilm)
        return true
    }
    
    private func handleEditFilm(isInSheet: Bool) -> Bool {
        guard !isInSheet else { return false }
        
        // One film opens its FilmSheet; more than one, the MultiFilmSheet.
        guard let selectionState = selectionState,
              !selectionState.selectedFilmIDs.isEmpty else {
            return false
        }
        
        // Check no sheet is already active
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        AppEventBus.shared.sendCommand(.editFilm)
        return true
    }
    
    private func handleRightSidebarTab(_ char: Character) -> Bool {
        // Only work when exactly one film is selected
        guard let selectionState = selectionState,
              selectionState.selectedFilmIDs.count == 1 else {
            return false
        }
        
        // Update ViewStateManager directly based on the key pressed
        switch char {
        case "1":
            ViewStateManager.shared.setRightSidebarTab(RightSidebarTab.details)
            return true
        case "2":
            ViewStateManager.shared.setRightSidebarTab(RightSidebarTab.releases)
            return true
        case "3":
            // Mirror the MenuBar's notesTabEnabled guard: only switch to the Notes
            // tab when the selected film actually has notes content.
            guard let filmID = selectionState.selectedFilmIDs.first,
                  let film = dataCoordinator?.getFilm(filmID),
                  film.hasNotesContent else {
                return true // Consume the event without switching tabs
            }
            ViewStateManager.shared.setRightSidebarTab(RightSidebarTab.notes)
            return true
        default:
            return false
        }
    }
    
    /// Handle Shift+Cmd+D — Scan Library for Duplicates.
    ///
    /// The empty-library guard mirrors MenuBar's `.disabled(filmCount == 0 || isSheetActive)`
    /// on the item this shortcut duplicates. It is needed here: the local event monitor runs
    /// before AppKit's key-equivalent matching, so this handler receives the shortcut, not the
    /// disabled menu item.
    private func handleFindDuplicates(isInSheet: Bool) -> Bool {
        guard !isInSheet else { return false }
        
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        // Nothing to scan — pass the event through, exactly as the two guards above do,
        // so it reaches the (disabled) menu item and does nothing.
        guard let dataCoordinator = dataCoordinator, dataCoordinator.totalFilmCount > 0 else {
            return false
        }
        
        AppEventBus.shared.sendCommand(.findDuplicates)
        return true
    }
    
    private func handleSheetTabNavigation(_ char: Character) -> Bool {
        guard let appState = appState,
              let activeSheet = appState.sheetCoordinator.activeSheet else {
            return false
        }
        
        // Convert character to tab index (1-5)
        guard let tabNumber = Int(String(char)),
              tabNumber >= 1 && tabNumber <= 5 else {
            return false
        }
        
        // Send appropriate command based on which sheet is active
        switch activeSheet.content {
        case .film:
            AppEventBus.shared.sendCommand(.changeFilmSheetTab(tab: tabNumber))
            return true
        case .settings(_, _, _):
            AppEventBus.shared.sendCommand(.changeSettingsSheetTab(tab: tabNumber))
            return true
        case .multiFilm(let sheet):
            // Set directly: the sheet object is at hand, and it has only two tabs, so a
            // number past them passes through as it does with no tab to go to.
            let tabs = MultiFilmTab.allCases
            guard tabNumber <= tabs.count else { return false }
            sheet.selectedTab = tabs[tabNumber - 1]
            return true
        default:
            // Other sheets don't support tab navigation
            return false
        }
    }
    
    /// Cmd+Up/Down in a sheet: the stepping counterpart of handleSheetTabNavigation.
    /// Each sheet resolves the neighbor itself, since only it knows its current tab.
    private func handleSheetTabCycle(forward: Bool) -> Bool {
        guard let activeSheet = appState?.sheetCoordinator.activeSheet else { return false }
        switch activeSheet.content {
        case .film:
            AppEventBus.shared.sendCommand(.cycleFilmSheetTab(forward: forward))
            return true
        case .settings(_, _, _):
            AppEventBus.shared.sendCommand(.cycleSettingsSheetTab(forward: forward))
            return true
        case .multiFilm(let sheet):
            let tabs = MultiFilmTab.allCases
            let index = tabs.firstIndex(of: sheet.selectedTab) ?? 0
            sheet.selectedTab = tabs[(index + (forward ? 1 : -1) + tabs.count) % tabs.count]
            return true
        default:
            return false
        }
    }

    /// Cmd+Up/Down with no sheet: the stepping counterpart of handleInViewTabNavigation,
    /// in the same tab order.
    private func handleInViewTabCycle(forward: Bool) -> Bool {
        guard let appState else { return false }
        func step<T: Equatable>(_ tabs: [T], _ current: T, _ select: (T) -> Void) -> Bool {
            let index = tabs.firstIndex(of: current) ?? 0
            select(tabs[(index + (forward ? 1 : -1) + tabs.count) % tabs.count])
            return true
        }
        switch appState.selectedSidebarItem {
        case .libraryItem(.unwatched):
            let state = UnwatchedState.shared
            return step([.unwatched, .notRated], state.selectedCategory) { state.selectCategory($0) }
        case .libraryItem(.recents):
            let state = RecentsState.shared
            return step([.recentlyViewed, .recentlyRotated, .recentlyAdded, .recentlyUpdated, .recentlyPurchased],
                        state.selectedCategory) { state.selectCategory($0) }
        case .libraryItem(.reports):
            let state = ReportsState.shared
            return step(ReportsCategory.allCases, state.selectedCategory) { state.selectCategory($0) }
        case .libraryItem(.imports):
            let state = ImportsState.shared
            return step([.metadata, .ratings], state.selectedCategory) { state.selectCategory($0) }
        case .libraryItem(.filmQueue):
            let state = FilmQueueFilterState.shared
            return step([.all, .upNext, .soon, .later], state.selectedFilter) { state.selectFilter($0) }
        case .smartList(let type):
            // A family of one has no tabs to cycle; the key passes through.
            guard type.familyVariants.count > 1 else { return false }
            let state = SmartListVariantState.shared(for: type)
            return step(type.familyVariants, state.selected) { state.select($0) }
        default:
            return false
        }
    }

    /// Handle Cmd+N - Create New List
    private func handleCreateNewList() -> Bool {
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        AppEventBus.shared.sendCommand(.showListCreation)
        return true
    }
    
    /// Handle Opt+Delete — Remove selected film(s) from the current list context.
    ///
    /// Hands off to FilmRemoval (LibraryManager.swift), which resolves the context (user list,
    /// Film Queue or Hall of Fame), pre-filters to actual members, applies the confirmation
    /// preference, and builds the alert for every surface offering this command.
    ///
    /// `clearingSelection: false` keeps the selection, matching the MenuBar item this shortcut duplicates.
    private func handleRemoveFromCurrentList() {
        guard let appState = appState,
              let selectionState = selectionState,
              let dataCoordinator = dataCoordinator else { return }

        FilmRemoval.removeFromCurrentList(filmIDs: selectionState.selectedFilmIDs,
                                          appState: appState,
                                          coordinator: dataCoordinator,
                                          clearingSelection: false)
    }
    
    /// Handle Shift+Cmd+N - Create New List from Selection. Matches AddToListMenuItems;
    /// Opt+Cmd+N is a different shortcut (Duplicate List, in MenuBar's File menu).
    private func handleCreateNewListFromSelection() -> Bool {
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        // Requires at least one film to be selected (matches MenuBar restriction)
        guard let selectionState = selectionState,
              !selectionState.selectedFilmIDs.isEmpty else {
            return false
        }
        
        let filmIDs = selectionState.selectedFilmIDs
        AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs))
        return true
    }
    
    /// Handle Opt+Cmd+1-9 - Switch tabs within the currently active multi-tab view.
    /// Scoped to the Unwatched view, Recents, Reports, Imports, the Film Queue, and the
    /// rotation, purchased, unpurchased, alternate-versions and filtered-library smart-list families.
    /// Returns false if not in one of those views, allowing the caller to decide
    /// whether to consume or pass through the event.
    private func handleInViewTabNavigation(_ tabNumber: Int) -> Bool {
        guard let appState = appState else { return false }
        
        switch appState.selectedSidebarItem {
        case .libraryItem(.unwatched):
            // Tab order: 1=Unwatched, 2=Not Rated
            switch tabNumber {
            case 1: UnwatchedState.shared.selectCategory(.unwatched)
            case 2: UnwatchedState.shared.selectCategory(.notRated)
            default: return false
            }
            return true

        case .libraryItem(.recents):
            // Tab order: 1=Most Recently Viewed, 2=Recently Come Up for Rotation,
            //            3=Recently Added, 4=Recently Updated, 5=Recently Purchased
            switch tabNumber {
            case 1: RecentsState.shared.selectCategory(.recentlyViewed)
            case 2: RecentsState.shared.selectCategory(.recentlyRotated)
            case 3: RecentsState.shared.selectCategory(.recentlyAdded)
            case 4: RecentsState.shared.selectCategory(.recentlyUpdated)
            case 5: RecentsState.shared.selectCategory(.recentlyPurchased)
            default: return false
            }
            return true
            
        case .libraryItem(.reports):
            // Tab order: 1=Purchase and Expense Tracker, 2=Price Tracker,
            //            3=Hall of Fame, 4=Release Wishlist, 5=Data Visualizations
            switch tabNumber {
            case 1: ReportsState.shared.selectCategory(.costTracker)
            case 2: ReportsState.shared.selectCategory(.priceTracker)
            case 3: ReportsState.shared.selectCategory(.hallOfFame)
            case 4: ReportsState.shared.selectCategory(.releaseWishlist)
            case 5: ReportsState.shared.selectCategory(.dataVisualizations)
            default: return false
            }
            return true
            
        case .libraryItem(.imports):
            // Tab order: 1=Import Metadata, 2=Import Ratings
            switch tabNumber {
            case 1: ImportsState.shared.selectCategory(.metadata)
            case 2: ImportsState.shared.selectCategory(.ratings)
            default: return false
            }
            return true

        case .libraryItem(.filmQueue):
            // Tab order: 1=All, 2=Up Next, 3=Soon, 4=Later
            // Uses FilmQueueFilterState.selectFilter() — the same path as the segmented
            // picker in GalleryTitleBar — so the picker and ViewStateManager stay in sync.
            switch tabNumber {
            case 1: FilmQueueFilterState.shared.selectFilter(.all)
            case 2: FilmQueueFilterState.shared.selectFilter(.upNext)
            case 3: FilmQueueFilterState.shared.selectFilter(.soon)
            case 4: FilmQueueFilterState.shared.selectFilter(.later)
            default: return false
            }
            return true
            
        case .smartList(let type):
            // Tab order is the family's own variant order (SmartListType.familyVariants):
            // the parent first, then its sub-variants — e.g. 1=Up for Rotation,
            // 2=Viewed Over One Year Ago, or 1=Purchased, 2=4K, 3=Blu-ray, 4=DVD.
            // Selecting goes through the same SmartListVariantState.select() the gallery
            // picker uses, so sidebar highlighting and ViewStateManager stay in sync.
            let variants = type.familyVariants
            guard tabNumber >= 1, tabNumber <= variants.count else { return false }
            SmartListVariantState.shared(for: type).select(variants[tabNumber - 1])
            return true

        default:
            // Not in a view that supports in-view tab navigation
            return false
        }
    }
    
    /// Handle Opt+Cmd+E - Edit Film, opened on the Metadata tab
    private func handleEditFilmMetadata() -> Bool {
        guard let appState = appState,
              appState.sheetCoordinator.activeSheet == nil else {
            return false
        }
        
        // Requires a selection (matches the Edit Metadata menu item). More than one film opens
        // the MultiFilmSheet, which ignores the requested tab.
        guard let selectionState = selectionState,
              !selectionState.selectedFilmIDs.isEmpty else {
            return false
        }
        
        AppEventBus.shared.sendCommand(.editFilmMetadata)
        return true
    }
    
    /// Handle Cmd+1-9 shortcuts for Left Sidebar navigation as a fallback.
    /// Provides a robust alternative when the menu system fails validation.
    private func handleLeftSidebarNavigation(_ char: Character) -> Bool {
        guard let appState = appState else { return false }

        // Delegates entirely to TopLevelSidebarShortcut (MenuBar.swift), the single
        // source of truth for what each Cmd+<digit> shortcut does — shared with
        // LeftSidebarMenu's Toggle rows so the two paths can never silently drift
        // apart on what a given digit navigates to.
        guard let digit = Int(String(char)), let shortcut = TopLevelSidebarShortcut(rawValue: digit) else {
            return false
        }
        // With Smart Lists off, the menu omits these items and the sidebar has no row for
        // them; navigating anyway opened an empty, un-highlighted list. Consumed silently,
        // as the menu would have nothing to match.
        if shortcut.smartListType != nil && !Preferences.smartLists { return true }
        shortcut.activate(appState: appState)
        return true
    }
    
    // MARK: - Helper Methods

    /// What a bare Return saves in `sheet`, when it may save now: the FilmSheet's or the
    /// MultiFilmSheet's confirm, nil for any other sheet or while saving is not allowed.
    private static func returnConfirmAction(for sheet: AppSheet) -> (() -> Void)? {
        switch sheet.content {
        case .film(_, let filmSheet):
            guard filmSheet.canConfirm, !filmSheet.isConfirming else { return nil }
            return { filmSheet.confirm() }
        case .multiFilm(let multiFilmSheet):
            guard multiFilmSheet.canConfirm else { return nil }
            return { multiFilmSheet.confirm() }
        default:
            return nil
        }
    }

    /// The open FilmSheet, when one is on screen showing `tab`.
    private func activeFilmSheet(showing tab: FilmTab) -> FilmSheet? {
        guard let activeSheet = appState?.sheetCoordinator.activeSheet,
              case .film(_, let filmSheet) = activeSheet.content,
              filmSheet.selectedTab == tab else { return nil }
        return filmSheet
    }

    /// Whether `window` has a visible child window, which is how a SwiftUI popover attaches.
    ///
    /// A non-activating popover leaves its presenting window key, so `isSheet` cannot tell
    /// "sheet" from "sheet with a popover open". A visible child window means a popover (or
    /// similar floating panel) is up, and Return must pass through to it. Any visible child is
    /// treated as a popover, since a FilmSheet has no other kind of child window.
    private func hasVisibleChildWindow(on window: NSWindow) -> Bool {
        window.childWindows?.contains { $0.isVisible } ?? false
    }

    /// Check if text input is active in any relevant window (key window or attached sheets)
    private func isTextInputActiveAnywhere() -> Bool {
        // Deduplicated windows to inspect. With a sheet open, NSApp.keyWindow is the same
        // object as mainWindow.attachedSheet, so each window is added at most once.
        var windowsToCheck: [NSWindow] = []
        
        if let keyWindow = NSApp.keyWindow {
            windowsToCheck.append(keyWindow)
        }
        
        // Include the main window when it differs from the key window (e.g. when
        // no sheet is open and a floating panel holds key status), and include any
        // attached sheet when it isn't already the key window.
        if let mainWindow = NSApp.mainWindow, !windowsToCheck.contains(mainWindow) {
            windowsToCheck.append(mainWindow)
        }
        if let sheet = NSApp.mainWindow?.attachedSheet, !windowsToCheck.contains(sheet) {
            windowsToCheck.append(sheet)
        }
        
        return windowsToCheck.contains { isTextInputActive(in: $0) }
    }
    
    /// Delegates to `TextInputFocus` (InputUtilities.swift), the single definition this
    /// check shares with MenuBar's Cut/Copy/Paste enablement and SettingsSheet's
    /// Return-key monitor. Kept as a named method because the rationale for every
    /// `textInputActive` branch above is written in terms of it.
    private func isTextInputActive(in window: NSWindow) -> Bool {
        TextInputFocus.isActive(in: window)
    }
    
    // MARK: - Gallery Focus

    /// Locates the active gallery view in the key window's NSView hierarchy and
    /// makes it the first responder, routing keyboard focus directly to the grid or
    /// list and bypassing all intermediate NSView controls.
    ///
    /// Checks for `GalleryCollectionView` first (grid mode), then falls back to
    /// `DraggableListTableView` (list mode). Returns `true` on success, `false`
    /// when neither is found (e.g. the gallery is showing a loading spinner or
    /// placeholder instead of live content).
    @discardableResult
    private func focusGalleryGrid() -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return false
        }
        if let cv = findGalleryCollectionView(in: contentView) {
            return window.makeFirstResponder(cv)
        }
        if let tv = findDraggableListTableView(in: contentView) {
            return window.makeFirstResponder(tv)
        }
        return false
    }

    /// Depth-first search for the first `GalleryCollectionView` in the NSView tree
    /// rooted at `view`. Returns `nil` when none is found.
    private func findGalleryCollectionView(in view: NSView) -> GalleryCollectionView? {
        if let cv = view as? GalleryCollectionView { return cv }
        for sub in view.subviews {
            if let found = findGalleryCollectionView(in: sub) { return found }
        }
        return nil
    }

    /// Depth-first search for the first `DraggableListTableView` in the NSView tree
    /// rooted at `view`. Returns `nil` when none is found.
    /// Used as the Tab-focus fallback when the gallery is in list-view mode.
    private func findDraggableListTableView(in view: NSView) -> DraggableListTableView? {
        if let tv = view as? DraggableListTableView { return tv }
        for sub in view.subviews {
            if let found = findDraggableListTableView(in: sub) { return found }
        }
        return nil
    }
}
