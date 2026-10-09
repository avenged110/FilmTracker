// MARK: - DuplicateSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// User interface for finding and resolving duplicate films in the library.

import SwiftUI

@MainActor
struct DuplicateSheet: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SheetCoordinator.self) private var sheetCoordinator
    
    @State private var viewModel = DuplicateSheetViewModel()
    @State private var showingCancelConfirmation = false
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    
    // Reference-type box so the scroll monitor closure can reliably read and write
    // the flag across the continuous stream of scrollWheel events in a single gesture.
    private final class SwipeState { var consumed: Bool = false }
    @State private var swipeState = SwipeState()
    
    var body: some View {
        VStack(spacing: 0) {
            // Titlebar.
            titleBar
            
            // Main content area.
            ZStack {
                if viewModel.duplicates.isEmpty {
                    // Placeholder (initial, scanning, and post-scan states).
                    placeholderView
                } else {
                    // Results state: Show carousel of duplicates.
                    carouselView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped() // Clip at exact titlebar boundary
            
            Divider()
            
            // Bottom buttons.
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: Preferences.sheetSize, height: Preferences.sheetSize)
        .onAppear {
            viewModel.configure(dataCoordinator: dataCoordinator)
            
            // MARK: Trackpad horizontal swipe → card navigation
            let swipe = swipeState
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak viewModel] event in
                guard let viewModel = viewModel else { return event }
                guard event.hasPreciseScrollingDeltas else { return event }
                guard !viewModel.duplicates.isEmpty && !viewModel.isScanning else { return event }
                
                let threshold: CGFloat = 20
                
                if event.phase == .ended || event.momentumPhase == .ended {
                    swipe.consumed = false
                    return event
                }
                guard event.phase.contains(.changed) || event.phase.contains(.began) else { return event }
                
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                guard abs(dx) > abs(dy) else { return event }
                guard !swipe.consumed else { return event }
                
                if dx < -threshold {
                    swipe.consumed = true
                    Task { @MainActor in viewModel.nextCard() }
                } else if dx > threshold {
                    swipe.consumed = true
                    Task { @MainActor in viewModel.previousCard() }
                }
                return event
            }
            
            // Set up keyboard event monitoring for this sheet
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
                guard let viewModel = viewModel else { return event }
                
                // Handle Escape key
                if event.keyCode == 53 { // Escape key
                    if viewModel.isScanning {
                        // Trigger Cancel Scan confirmation
                        Task { @MainActor in
                            self.showingCancelConfirmation = true
                        }
                        return nil // Event handled
                    }
                    return event // Let default Close button handle it
                }
                
                // Handle Left/Right arrow keys for carousel navigation
                if !viewModel.duplicates.isEmpty && !viewModel.isScanning {
                    if event.keyCode == 123 { // Left arrow
                        Task { @MainActor in
                            viewModel.previousCard()
                        }
                        return nil // Event handled
                    } else if event.keyCode == 124 { // Right arrow
                        Task { @MainActor in
                            viewModel.nextCard()
                        }
                        return nil // Event handled
                    }
                }
                
                return event // Pass through other keys
            }
        }
        .onDisappear {
            // Remove keyboard event monitor
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            // Remove scroll event monitor
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            
            // SAFETY NET: Cancel any ongoing scan if sheet is dismissed
            if viewModel.isScanning {
                viewModel.emergencyCancelScan()
            }
        }
        .interactiveDismissDisabled(viewModel.isScanning)
        .alert("Stop Duplicate Scan", isPresented: $showingCancelConfirmation) {
            Button("Continue Scan", role: .cancel) {
                // User canceled the cancellation — scan continues unaffected.
            }
            Button("Stop Scan", role: .destructive) {
                viewModel.confirmCancelScan()
            }
        } message: {
            Text("Are you sure you want to stop the duplicate scan? Progress will be lost.")
        }
    }
    
    // MARK: - Titlebar
    private var titleBar: some View {
        ZStack {
            Text("Find Duplicates")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
    
    // MARK: - Placeholder / Scanning View
    // The glyph + label are vertically centered in the available space at all times.
    // During a scan the progress bar and counter grow downward from below the label
    // without disturbing the centered position of the glyph + label pair.
    private var placeholderView: some View {
        ZStack(alignment: .center) {
            // Centered anchor: glyph + label always sit at the vertical midpoint.
            VStack(spacing: 16) {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(.secondary)
                
                // Fixed 2-line height reservation (13pt × 2 lines + leading ≈ 36pt).
                // Top-aligned so single-line strings don't shift the glyph above them.
                Text(viewModel.placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 320, height: 36, alignment: .top)
            }
            
            // Progress components: offset downward from the ZStack center so they
            // appear directly below the centered glyph + label without participating
            // in the centering calculation themselves.
            if viewModel.isScanning {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.scanProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 320)
                        .animation(nil, value: viewModel.scanProgress)
                    
                    Text("\(viewModel.currentComparison) of \(viewModel.totalComparisons) comparisons")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.identity)
                }
                // Offset pushes this block below the centered glyph + label stack:
                // 120pt glyph + 16pt gap + 36pt label (fixed) + 16pt gap + ~24pt half-progress ≈ 106pt
                .offset(y: 106)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .transition(.opacity)
    }
    
    // MARK: - Carousel View
    private var carouselView: some View {
        ZStack {
            // Full-width card container (viewport).
            GeometryReader { geometry in
                ZStack {
                    ForEach(Array(viewModel.duplicates.enumerated()), id: \.element.id) { index, duplicate in
                        DuplicateCardView(
                            duplicate: duplicate,
                            dataCoordinator: dataCoordinator,
                            selectedFilmID: $viewModel.selectedFilmForReconciliation,
                            onIgnore: { viewModel.ignoreCurrentCard() },
                            onReconcile: { viewModel.reconcileCurrentCard() })
                        .frame(width: 462)
                        .offset(x: cardOffset(for: index, in: geometry), y: cardVerticalOffset(for: index))
                        .opacity(cardOpacity(for: index))
                        .zIndex(index == viewModel.currentIndex ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.currentIndex)
            .animation(.easeOut(duration: 0.3), value: viewModel.dismissingCardIndex)
            
            // Arrow buttons overlaid on top.
            HStack {
                Button(action: { viewModel.previousCard() }) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.currentIndex <= 0)
                .opacity(viewModel.currentIndex <= 0 ? 0.3 : 1.0)
                .focusable(false)
                
                Spacer()
                
                Button(action: { viewModel.nextCard() }) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.currentIndex >= viewModel.duplicates.count - 1)
                .opacity(viewModel.currentIndex >= viewModel.duplicates.count - 1 ? 0.3 : 1.0)
                .focusable(false)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 20)
    }
    
    // Calculate horizontal offset for each card based on current index.
    private func cardOffset(for index: Int, in geometry: GeometryProxy) -> CGFloat {
        let cardWidth: CGFloat = 462
        let cardSpacing: CGFloat = 40
        let cardPlusSpacing = cardWidth + cardSpacing
        
        // Calculate relative position from current card.
        // Cards in ZStack are already centered, so current card needs offset of 0.
        let relativePosition = CGFloat(index - viewModel.currentIndex)
        
        return relativePosition * cardPlusSpacing
    }
    
    // Calculate vertical offset for dismissing animation.
    private func cardVerticalOffset(for index: Int) -> CGFloat {
        if let dismissingIndex = viewModel.dismissingCardIndex, index == dismissingIndex {
            return -600 // Slide upward off screen
        }
        return 0
    }
    
    // Calculate opacity for cards (fade out cards that are far from viewport).
    private func cardOpacity(for index: Int) -> Double {
        // If this card is being dismissed, fade it out.
        if let dismissingIndex = viewModel.dismissingCardIndex, index == dismissingIndex {
            return 0.0
        }
        
        let distance = abs(index - viewModel.currentIndex)
        if distance == 0 {
            return 1.0 // Current card: fully visible
        } else if distance == 1 {
            return 0.5 // Adjacent cards: partially visible
        } else {
            return 0.0 // Distant cards: invisible
        }
    }
    
    // MARK: - Bottom Bar
    private var bottomBar: some View {
        ZStack {
            // Buttons in HStack
            HStack {
                // Close button - disabled during scan
                Button {
                    sheetCoordinator.dismissSheet()
                } label: {
                    Text("Close")
                        .padding(4)
                        .font(.system(size: 12))
                }
                .keyboardShortcut(.cancelAction)
                .focusable(false)
                .disabled(viewModel.isScanning)
                
                Spacer()
                
                if viewModel.isScanning {
                    Button {
                        showingCancelConfirmation = true
                    } label: {
                        Text("Cancel Scan")
                            .padding(4)
                            .font(.system(size: 12))
                    }
                } else {
                    Button {
                        viewModel.startScan()
                    } label: {
                        Text(viewModel.scanButtonText)
                            .padding(4)
                            .font(.system(size: 12))
                    }
                    .disabled(viewModel.isScanning)
                }
            }
            
            // Duplicate counter centered in the entire sheet
            if !viewModel.duplicates.isEmpty && !viewModel.isScanning {
                Text("\(viewModel.currentIndex + 1) of \(viewModel.duplicates.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }
}

// MARK: - Duplicate Card View
struct DuplicateCardView: View {
    let duplicate: FilmComparison.DuplicatePair
    let dataCoordinator: DataCoordinator
    @Binding var selectedFilmID: UUID?
    let onIgnore: () -> Void
    let onReconcile: () -> Void
    
    /// Retrieve film snapshots using IDs from the coordinator's memory store.
    /// Returns value types — no live SwiftData object references.
    @MainActor
    private var films: [FilmSnapshot] {
        [duplicate.film1ID, duplicate.film2ID].compactMap { id in
            dataCoordinator.getFilm(id)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // Confidence badge.
                HStack {
                    Spacer()
                    Text("\(Int(duplicate.confidence * 100))% Match")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(confidenceColor(duplicate.confidence))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                
                // Film posters - centered in their halves with unique IDs.
                HStack(spacing: 0) {
                    ForEach(Array(films.enumerated()), id: \.element.id) { index, film in
                        posterButton(for: film, position: index)
                            .frame(maxWidth: .infinity)
                            .id("poster-\(duplicate.id)-\(film.id)-\(index)")
                    }
                }
                .padding(.horizontal, 12)
                
                Text("Select a film to retain or ignore this finding.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                // Action buttons (equal width for balanced proportions).
                HStack(spacing: 12) {
                    Button(action: onIgnore) {
                        ZStack{ Text("Ignore") }
                        .frame(width: 90)
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 90)
                    
                    Button(action: onReconcile) {
                        ZStack{ Text("Reconcile") }
                        .frame(width: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFilmID == nil)
                }
            }
            .padding(.bottom, 12)
            
            // Differences list with unique ID to prevent sliding animation.
            differencesView
                .id("differences-\(duplicate.id)")
        }
        .frame(height: 460, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
    }
    
    // MARK: - Poster Button
    @MainActor
    @ViewBuilder
    private func posterButton(for film: FilmSnapshot, position: Int) -> some View {
        let isSelected = selectedFilmID == film.id
        
        Button(action: {
            selectedFilmID = film.id
        }) {
            VStack(spacing: 8) {
                // Poster image (reduced by 20%).
                if let posterImage = PosterCache.shared.getImageSync(for: film.posterUID) {
                    Image(nsImage: posterImage)
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.clear,
                                    lineWidth: isSelected ? 3 : 0))
                }
                else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 80, height: 120)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.clear,
                                    lineWidth: isSelected ? 3 : 0))
                }
                
                // Film title (reserved space for up to two lines to prevent layout shifts).
                Text(film.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(height: 32, alignment: .top)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .focusable(false)
    }
    
    // MARK: - Differences View
    @MainActor
    @ViewBuilder
    private var differencesView: some View {
        let differences = calculateDifferences()
        
        if !differences.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Differences:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                
                Divider()
                
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(differences, id: \.field) { diff in
                            HStack(spacing: 0) {
                                // Left side (film1).
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(diff.field)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(diff.value1)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // Vertical divider.
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: 1)
                                    .padding(.horizontal, 8)
                                
                                // Right side (film2).
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(diff.field)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(diff.value2)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .id("diff-\(duplicate.id)-\(diff.field)")
                        }
                        
                        // Bottom padding inside ScrollView
                        Color.clear
                            .frame(height: 8)
                    }
                }
                .frame(height: 180)
                
                // Small spacer to ensure scrollbar indicator doesn't get clipped
                Spacer()
                    .frame(height: 8)
            }
        }
        else {
            Text("No differences detected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 180)
        }
    }
    
    // MARK: - Helpers
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.95 {
            return .red
        } else if confidence >= 0.85 {
            return .orange
        } else {
            return .yellow
        }
    }
    
    /// Calculates field-level differences between the two film snapshots.
    @MainActor
    private func calculateDifferences() -> [FieldDifference] {
        var differences: [FieldDifference] = []
        
        // Retrieve film snapshots from the coordinator's memory store.
        // getFilm() returns a FilmSnapshot value type — no SwiftData objects involved.
        guard let film1 = dataCoordinator.getFilm(duplicate.film1ID),
              let film2 = dataCoordinator.getFilm(duplicate.film2ID) else {
            return differences
        }
        
        // Compare relevant fields.
        if film1.releaseYear != film2.releaseYear {
            differences.append(FieldDifference(
                field: "Year", value1: film1.releaseYear, value2: film2.releaseYear))
        }
        if film1.rating != film2.rating {
            differences.append(FieldDifference(
                field: "Rating", value1: film1.rating, value2: film2.rating))
        }
        if film1.genre != film2.genre {
            differences.append(FieldDifference(
                field: "Genre", value1: film1.genre, value2: film2.genre))
        }
        if film1.studio != film2.studio {
            differences.append(FieldDifference(
                field: "Studio",
                value1: film1.studio.joined(separator: ", "),
                value2: film2.studio.joined(separator: ", ")))
        }
        if film1.dateAdded != film2.dateAdded {
            differences.append(FieldDifference(
                field: "Date Added",
                value1: film1.dateAdded,
                value2: film2.dateAdded))
        }
        
        return differences
    }
    
    struct FieldDifference {
        let field: String
        let value1: String
        let value2: String
    }
}

// MARK: - View Model
@MainActor
@Observable
final class DuplicateSheetViewModel: Loggable {
    nonisolated static let logTag = "[DuplicateSheet]"
    
    var isScanning = false
    var scanProgress: Double = 0.0
    var currentComparison: Int = 0
    var totalComparisons: Int = 0
    var duplicates: [FilmComparison.DuplicatePair] = []
    var currentIndex: Int = 0
    var selectedFilmForReconciliation: UUID? = nil
    var hasCompletedScan = false
    var scanFoundDuplicates = false
    var dismissingCardIndex: Int? = nil
    
    private var dataCoordinator: DataCoordinator?
    private var scanTask: Task<Void, Never>?
    
    // Generation counter: each scan increments this value. Progress callbacks
    // capture the generation at scan-start and are silently dropped if a newer
    // scan (or cancellation) has since advanced the counter. This eliminates the
    // race where callbacks from a canceled scan corrupt a freshly-started one,
    // which previously caused progress bar flickering and illegible counter values.
    private var scanGeneration: Int = 0
    
    var placeholderText: String {
        if isScanning {
            return "Duplicate scan in-progress\u{2026}"
        }
        if hasCompletedScan {
            return scanFoundDuplicates
                ? "All duplicates reconciled or ignored."
                : "No duplicates found."
        }
        return "Scan your library for duplicate items and resolve any which are found."
    }
    
    var scanButtonText: String {
        hasCompletedScan ? "Scan Again" : "Start Scan"
    }
    
    /// Configure the view model. No modelContext is needed — duplicate scanning
    /// and deletion both route through DataCoordinator's memory-first architecture.
    func configure(dataCoordinator: DataCoordinator) {
        self.dataCoordinator = dataCoordinator
    }
    
    // MARK: - Scanning
    func startScan() {
        guard let coordinator = dataCoordinator else { return }
        
        // Cancel any in-flight scan before starting a new one.
        // Advancing the generation immediately invalidates all pending callbacks
        // from the previous scan — they will see a mismatched generation and no-op.
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1               // Wrapping increment; overflow-safe
        let myGeneration = scanGeneration
        
        Self.log("Starting duplicate scan (generation \(myGeneration))...")
        clearScanState(completed: false)
        isScanning = true
        scanFoundDuplicates = false
        
        scanTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let foundDuplicates = await FilmComparison.findAllDuplicates(
                coordinator: coordinator,
                cancelFlag: {
                    await MainActor.run { Task.isCancelled || self.scanGeneration != myGeneration }
                }
            ) { progress, current, total in
                await MainActor.run {
                    // Drop stale callbacks from a canceled or superseded scan.
                    guard !Task.isCancelled, self.scanGeneration == myGeneration else { return }
                    self.scanProgress = progress
                    self.currentComparison = current
                    self.totalComparisons = total
                }
            }
            
            // Verify this scan is still the active one before touching any state.
            guard !Task.isCancelled, self.scanGeneration == myGeneration else {
                Self.log("Scan generation \(myGeneration) superseded — discarding results")
                return
            }
            
            Self.log("Scan complete: Found \(foundDuplicates.count) duplicate pair(s)")
            
            self.duplicates = foundDuplicates
            self.isScanning = false
            self.hasCompletedScan = true
            if !foundDuplicates.isEmpty {
                self.scanFoundDuplicates = true
            }
            
            // If no duplicates found, give user a moment to see progress complete.
            if foundDuplicates.isEmpty {
                Self.log("No duplicates found - returning to placeholder")
                try? await Task.sleep(for: .milliseconds(500))
                // Re-check generation after the sleep — the sheet could have been
                // dismissed or a new scan started during those 500ms.
                guard self.scanGeneration == myGeneration else { return }
                self.clearScanState(completed: true)
            }
        }
    }
    
    func confirmCancelScan() {
        Self.log("User confirmed scan cancellation")
        abandonScan()
    }

    // SAFETY NET: Emergency cancellation if sheet is dismissed unexpectedly
    func emergencyCancelScan() {
        Self.log("WARNING: Sheet dismissed while scanning - forcing scan cancelation")
        abandonScan()
    }

    /// Stops any scan in flight and clears its state, synchronously — no spawned Task, so
    /// there is no window in which a new scan could start against half-cleared state.
    /// Advancing the generation is the primary cancellation mechanism: every in-flight
    /// callback sees the mismatch and no-ops.
    private func abandonScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        clearScanState(completed: false)
    }

    /// Clears every piece of scan state. `completed` is what `hasCompletedScan` becomes:
    /// true returns the sheet to its "Scan Again" placeholder.
    private func clearScanState(completed: Bool) {
        isScanning = false
        scanProgress = 0.0
        currentComparison = 0
        totalComparisons = 0
        duplicates.removeAll()
        currentIndex = 0
        selectedFilmForReconciliation = nil
        hasCompletedScan = completed
        dismissingCardIndex = nil
    }

    /// The bookkeeping after a card's dismiss animation, shared by ignore and reconcile:
    /// removes the card, drops any other pair naming `deletedFilmID`, keeps the index in
    /// range, and returns to the placeholder once no pairs remain.
    ///
    /// Skipped entirely when a scan started or was canceled meanwhile — that replaced
    /// `duplicates`, so the captured index names a card from a different result set.
    private func finishDismissingCard(at indexToRemove: Int, generation: Int,
                                      deletedFilmID: UUID? = nil) async {
        guard scanGeneration == generation else { return }

        // Safety: ensure the captured index is still valid.
        guard indexToRemove < duplicates.count else {
            dismissingCardIndex = nil
            return
        }

        // Remove the card and clear dismissing state.
        duplicates.remove(at: indexToRemove)
        dismissingCardIndex = nil

        // Purge any other remaining pairs that reference a film just deleted. If three or
        // more films were mutual duplicates (e.g. pairs A–B and A–C both appeared in the
        // scan), reconciling A–B would otherwise leave pair A–C in the carousel pointing at
        // a film that no longer exists — that card would silently render with only one
        // poster and its "Reconcile" button would be a dead end.
        if let deletedFilmID {
            let staleCount = duplicates.count
            duplicates.removeAll { pair in
                pair.film1ID == deletedFilmID || pair.film2ID == deletedFilmID
            }
            if staleCount != duplicates.count {
                Self.log("Removed \(staleCount - duplicates.count) stale pair(s) referencing deleted film")
            }
        }

        // Adjust index if any removal left it at or beyond the new end.
        if currentIndex >= duplicates.count {
            currentIndex = max(0, duplicates.count - 1)
        }

        // Clear selection.
        selectedFilmForReconciliation = nil

        // If no more duplicates, return to placeholder.
        if duplicates.isEmpty {
            Self.log("All duplicates resolved - returning to placeholder")
            try? await Task.sleep(for: .milliseconds(300))
            guard scanGeneration == generation else { return }
            clearScanState(completed: true)
        }
    }
    
    // MARK: - Navigation
    func previousCard() {
        // Block navigation while a card dismiss animation is in flight to prevent
        // currentIndex from drifting before the async removal Task completes.
        guard dismissingCardIndex == nil else { return }
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex -= 1
            selectedFilmForReconciliation = nil
        }
    }
    
    func nextCard() {
        // Block navigation while a card dismiss animation is in flight.
        guard dismissingCardIndex == nil else { return }
        guard currentIndex < duplicates.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex += 1
            selectedFilmForReconciliation = nil
        }
    }
    
    // MARK: - Actions
    func ignoreCurrentCard() {
        Self.log("Ignoring duplicate pair at index \(currentIndex)")
        
        guard currentIndex < duplicates.count else { return }
        
        // Save the pair to ignored list before removing it
        let pair = duplicates[currentIndex]
        let pairKey = Preferences.makeDuplicatePairKey(film1ID: pair.film1ID, film2ID: pair.film2ID)
        var ignoredPairs = Preferences.ignoredDuplicatePairs
        if !ignoredPairs.contains(pairKey) {
            ignoredPairs.append(pairKey)
            Preferences.ignoredDuplicatePairs = ignoredPairs
            Self.log("Added pair to ignored list: \(pairKey)")
        }
        
        // Capture the index now — navigation is blocked while dismissingCardIndex is set,
        // but we capture defensively so the async Task never reads a stale value.
        let indexToRemove = currentIndex
        dismissingCardIndex = indexToRemove
        let generation = scanGeneration
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Wait for upward slide animation to complete.
            try? await Task.sleep(for: .milliseconds(300))
            await self.finishDismissingCard(at: indexToRemove, generation: generation)
        }
    }
    
    func reconcileCurrentCard() {
        guard let selectedID = selectedFilmForReconciliation,
              currentIndex < duplicates.count else { return }
        
        let pair = duplicates[currentIndex]
        
        // Retrieve film snapshots from the memory store using IDs.
        // DataCoordinator.getFilm returns a FilmSnapshot value type — no SwiftData involved.
        guard let coordinator = dataCoordinator,
              let film1 = coordinator.getFilm(pair.film1ID),
              let film2 = coordinator.getFilm(pair.film2ID) else {
            Self.log("ERROR: Could not retrieve film snapshots for reconciliation")
            return
        }
        
        // Determine which film to delete (the one NOT selected).
        let filmToDeleteID: UUID
        let keepName: String
        let deleteName: String
        if film1.id == selectedID {
            filmToDeleteID = film2.id
            keepName = film1.name
            deleteName = film2.name
        } else {
            filmToDeleteID = film1.id
            keepName = film2.name
            deleteName = film1.name
        }
        
        Self.log("Reconciling duplicate: Keeping '\(keepName)', deleting '\(deleteName)'")
        
        // Capture the index now — navigation is blocked while dismissingCardIndex is set,
        // but we capture defensively so the async Task never reads a stale value.
        let indexToRemove = currentIndex
        dismissingCardIndex = indexToRemove
        let generation = scanGeneration
        
        // Perform deletion.
        Task { @MainActor [weak self] in
            guard let self = self, let coordinator = self.dataCoordinator else { return }
            
            // Wait for upward slide animation to complete.
            try? await Task.sleep(for: .milliseconds(300))
            
            await FilmManager.deleteFilms(
                Set([filmToDeleteID]),
                coordinator: coordinator,
                selectionState: nil)
            
            Self.log("Film deleted successfully")

            // The deletion above was the user's decision and stands; the card bookkeeping
            // does not if a scan replaced `duplicates` meanwhile.
            await self.finishDismissingCard(at: indexToRemove, generation: generation,
                                            deletedFilmID: filmToDeleteID)
        }
    }
}
