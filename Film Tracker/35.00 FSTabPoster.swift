// MARK: - FSTabPoster.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles the "Poster" tab for FilmSheet (gets, sets, and displays the image).
// Defers poster conversion until save/update is clicked.

import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class FSTabPoster {
    weak var owner: FilmSheet?

    var posterUID: String = "" { didSet { checkForChanges() } }
    var posterImage: NSImage?

    // Original value (for change tracking).
    private var originalPosterUID: String = ""

    // Pending poster change - holds the selected image URL until save.
    private var pendingPosterURL: URL?

    // Delete-poster transient state.
    // Set when the user clicks "Delete Poster"; cleared on undo or save.
    private(set) var posterDeletedByUser: Bool = false
    private var posterImageBeforeDelete: NSImage?
    private var posterUIDBeforeDelete: String = ""
    private var pendingPosterURLBeforeDelete: URL?

    // Change tracking.
    var hasChanges: Bool = false

    // Flag to suppress change tracking during initial data load.
    private var isLoadingData: Bool = false

    // True when there is no poster to delete — no original poster, no pending
    // replacement, and no current UID. Drives the disabled state of the Delete
    // Poster button. In add mode, originalPosterUID is "", so we also check
    // pendingPosterURL and the live posterUID to allow deletion of a just-selected image.
    var cannotDeletePoster: Bool {
        originalPosterUID.isEmpty && posterUID.isEmpty && pendingPosterURL == nil
    }

    // The title label for the view. Computed once at init rather than on every render pass.
    let titleText: String

    init(owner: FilmSheet) {
        self.owner = owner
        self.titleText = owner.isEditMode ? "Update the poster:" : "Add a poster:"

        // Only load the poster if editing an existing film.
        if owner.isEditMode {
            loadPoster(for: owner.filmID)
        }
    }

    // Load poster from database.
    private func loadPoster(for id: UUID) {
        guard let owner = owner else { return }

        // Set flag to suppress change tracking during load.
        isLoadingData = true
        defer { isLoadingData = false }

        // Get film from DataCoordinator's memory store (instant)
        guard let film = owner.coordinator.getFilm(id) else {
            owner.log("ERROR: Film \(id) not found in memory store")
            return
        }

        posterUID = film.posterUID

        // Capture the original UID after the load so it reflects the value
        // that was actually read from the store (not the pre-load nil).
        originalPosterUID = posterUID

        loadPosterIfNeeded()
    }

    // MARK: - Change Tracking
    private func checkForChanges() {
        // Don't track changes during initial data load.
        guard !isLoadingData else { return }

        // In add mode, hasChanges is intentionally always false and notifyChanges()
        // is intentionally not called. FilmSheet.performCanConfirmUpdate() does not
        // consult posterTab.hasChanges when computing canConfirm in add mode — it
        // only requires detailsTab.isValid. Posters selected in add mode are handled
        // by processPendingPoster() at confirm time regardless of this flag.
        // If future logic needs posterTab.hasChanges in add mode, this guard must
        // be revisited.
        guard let owner = owner, owner.isEditMode else {
            // In add mode, hasChanges is intentionally always false. Guard the write
            // so no observation invalidation fires when it is already false.
            if hasChanges { hasChanges = false }
            return
        }

        // Compute the new value first so we can gate the write and the notifyChanges()
        // call on an actual delta — mirrors FSTabReleases.checkForChanges().
        let newHasChanges = posterUID != originalPosterUID || pendingPosterURL != nil || posterDeletedByUser
        if hasChanges != newHasChanges {
            hasChanges = newHasChanges
            // Notify the owner of changes.
            // FilmSheet.notifyChanges() defers its writes to the next run loop so
            // they do not cascade into views that are still mid-render from this
            // tracked-property mutation.
            owner.notifyChanges()
        }
    }

    func loadPosterIfNeeded() {
        guard let folderURL = Preferences.posterImagesFolderURL else { return }
        guard !posterUID.isEmpty else { return }
        let uid = posterUID
        let url = folderURL.appendingPathComponent("\(uid).jpg")
        // The outer detached Task captures no self — only the URL value — so a
        // dismissed FSTabPoster (and its FilmSheet) is never kept alive for the
        // duration of the disk read. The inner MainActor.run uses [weak self]
        // so the final write is a no-op if the sheet was closed while the file
        // was being read.
        //
        // The poster is decoded here too, through PosterCache's decoder, rather than
        // wrapped with NSImage(data:) — which defers JPEG rasterization to the first
        // draw, on the main thread.
        Task.detached(priority: .background) {
            guard let image = PosterCache.loadDecodedImage(from: url) else { return }
            await MainActor.run { [weak self] in
                // Only while the tab still shows the poster this read was for. The read
                // runs at background priority, and a selection or a Delete made before it
                // lands has already replaced the preview; writing the stored image over
                // either would show a poster the save is not going to keep.
                guard let self, self.posterUID == uid else { return }
                self.posterImage = image
            }
        }
    }

    func selectImage() {
        // selectImage is already @MainActor — no outer Task wrapper needed.
        let config = OpenPanelConfiguration(
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            allowedContentTypes: [.image],
            title: nil,
            message: "Select Poster Image",
            prompt: "Select"
        )

        Task { @MainActor [weak self] in
            guard let self = self, self.owner != nil else { return }

            let selection = await OpenPanelPresenter.present(configuration: config)
            guard case let .urls(urls) = selection,
                  let selectedURL = urls.first else { return }

            // Store the pending URL and load a preview immediately. The pending-delete
            // state is NOT cleared here — only once the decode below actually succeeds.
            // Clearing it eagerly would mean a failed read/decode leaves the tab with
            // posterUID == "" (from the earlier deletePoster() call) and no Undo button,
            // since the snapshot needed to restore it would already be gone.
            // [weak self] in the MainActor.run block prevents the detached Task from
            // keeping a dismissed FSTabPoster (and its owner FilmSheet) alive for the
            // duration of the background I/O.
            //
            // The selection being replaced is remembered so a failed read or decode can put
            // it back. Clearing to nil instead stranded an earlier successful pick: its
            // preview and temporary posterUID stayed on screen, but with no pending URL the
            // save took processPendingPoster's no-change branch and wrote that temporary UID
            // — one with no file behind it — as the film's poster.
            let previousPendingURL = self.pendingPosterURL
            self.pendingPosterURL = selectedURL

            Task.detached(priority: .background) {
                // Read the file on a background thread.
                let imageData: Data
                do {
                    imageData = try Data(contentsOf: selectedURL)
                } catch {
                    // Convert the error to a Sendable String before crossing the
                    // actor boundary — Swift.Error is not Sendable by default and
                    // cannot be captured directly by a MainActor.run closure.
                    let errorDescription = error.localizedDescription
                    let selectedPath = selectedURL.path(percentEncoded: false)
                    await MainActor.run { [weak self] in
                        guard let self = self, self.pendingPosterURL == selectedURL else { return }
                        // The user's selection did not produce a valid preview. Revert to
                        // the selection it was replacing (nil when there was none), so the
                        // pending URL again matches the preview and posterUID on screen.
                        self.pendingPosterURL = previousPendingURL
                        self.owner?.log("ERROR: Failed to read selected poster image at \(selectedPath): \(errorDescription)")
                    }
                    return
                }
                // Decode the image. NSImage(data:) returns nil for unsupported or
                // corrupted image content — log the failure so the user can see why
                // the preview didn't update rather than having it appear to do nothing,
                // and clear pendingPosterURL so change tracking doesn't latch to true
                // for a selection that produced no preview.
                guard let previewImage = NSImage(data: imageData) else {
                    let selectedPath = selectedURL.path(percentEncoded: false)
                    await MainActor.run { [weak self] in
                        guard let self = self, self.pendingPosterURL == selectedURL else { return }
                        self.pendingPosterURL = previousPendingURL
                        self.owner?.log("ERROR: Selected poster image could not be decoded (unsupported or corrupted file): \(selectedPath)")
                    }
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self = self, self.pendingPosterURL == selectedURL else { return }

                    // Only now — a decoded preview is actually going to replace the
                    // current state — clear any pending delete the user had staged.
                    if self.posterDeletedByUser {
                        self.posterDeletedByUser = false
                        self.posterImageBeforeDelete = nil
                        self.posterUIDBeforeDelete = ""
                        self.pendingPosterURLBeforeDelete = nil
                    }

                    self.posterImage = previewImage

                    // Generate a temporary UID for tracking the change.
                    // This won't be written to disk until processPendingPoster() is called.
                    self.posterUID = UUID().uuidString

                    self.owner?.log("Poster image selected (pending save)")
                }
            }
        }
    }

    // MARK: - Delete / Undo Delete
    func deletePoster() {
        guard !posterDeletedByUser else { return }

        // Snapshot current UI state so we can restore it on undo.
        posterImageBeforeDelete = posterImage
        posterUIDBeforeDelete = posterUID

        // If there's a pending image selection, snapshot it before clearing so
        // undo can restore it. Without the clear, processPendingPoster() would
        // convert the image even though the user deleted it.
        pendingPosterURLBeforeDelete = pendingPosterURL
        pendingPosterURL = nil

        // Clear the preview — transient UI change only; nothing written yet.
        posterImage = nil
        posterDeletedByUser = true

        // Clear the displayed UID so change tracking sees a delta.
        // The empty string signals "no poster" to processPendingPoster().
        // posterUID's didSet fires checkForChanges(); no redundant call needed.
        posterUID = ""

        owner?.log("Poster marked for deletion (pending save)")
    }

    func undoDeletePoster() {
        guard posterDeletedByUser else { return }

        // Restore the UI state captured at delete time.
        posterImage = posterImageBeforeDelete
        posterUID = posterUIDBeforeDelete
        pendingPosterURL = pendingPosterURLBeforeDelete

        posterDeletedByUser = false
        posterImageBeforeDelete = nil
        posterUIDBeforeDelete = ""
        pendingPosterURLBeforeDelete = nil

        owner?.log("Poster deletion undone")

        checkForChanges()
    }

    // MARK: - DTO Support
    /// Processes any pending poster selection and returns the final posterUID for use in
    /// FilmChangeset assembly. Does NOT require a live Film @Model object.
    ///
    /// - If a new image was selected (pendingPosterURL set): converts the image, writes it to
    ///   disk, updates PosterCache, clears pending state, and returns the new UID.
    /// - If the user deleted the poster (posterDeletedByUser): evicts the old poster from the
    ///   cache, clears state, and returns "".
    /// - If neither is pending: posterUID still equals the original (see the branch below for
    ///   why), so it is returned as-is with no cache work.
    /// - Cache cleanup for the replaced old poster is performed when originalUID differs from
    ///   the returned UID.
    ///
    /// - Parameters:
    ///   - filmID: The UUID of the film (used for the poster filename).
    ///   - originalUID: The poster UID as it existed before the sheet opened (for cache eviction).
    /// - Returns: The posterUID to write into FilmSnapshot/FilmChangeset.
    func processPendingPoster(filmID: UUID, originalUID: String) async throws -> String {
        guard let owner = owner else { return posterUID }

        if let pendingURL = pendingPosterURL {
            owner.log("Processing pending poster for film \(filmID)...")

            let result = await withCheckedContinuation { continuation in
                PosterConverter.normalizePosterImage(from: pendingURL) { result in
                    continuation.resume(returning: result)
                }
            }

            switch result {
            case .success(let newUID):
                owner.log("Poster converted successfully: \(newUID)")

                // Confirm the file is on disk before caching. Caching a UID whose write
                // silently failed would leave a stale entry that can never be displayed.
                //
                // A single check, not a poll. This used to loop on `fileExists` for up to
                // five wall-clock seconds, sleeping 50 ms between attempts — but
                // PosterConverter writes with a synchronous `Data.write(to:options:.atomic)`
                // and only calls the success completion AFTER that write returns, so the
                // file is always present on the first look. The loop, its timeout branch,
                // and the cancellation plumbing threaded through it were unreachable; worse,
                // the imagined five-second window was cited as justification elsewhere (see
                // FilmSheet.cancel(), whose comment has been corrected). A negative result
                // here now means the write genuinely did not produce a file, which is worth
                // logging rather than waiting on.
                if !newUID.isEmpty, let folderURL = Preferences.posterImagesFolderURL {
                    let fileURL = folderURL.appendingPathComponent("\(newUID).jpg")
                    if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                        await PosterCache.shared.addPoster(newUID)
                        owner.log("Added poster \(newUID) to cache")
                    } else {
                        owner.log("WARNING: Poster file \(newUID) reported written but not found on disk — cache update skipped")
                    }
                }

                // Evict the old poster if it changed.
                if !originalUID.isEmpty && originalUID != newUID {
                    PosterCache.shared.removePoster(originalUID)
                    owner.log("Evicted old poster \(originalUID) from cache")
                }

                pendingPosterURL = nil
                self.posterUID = newUID
                return newUID

            case .failure(let error):
                owner.log("ERROR: Poster conversion failed: \(error)")
                throw error
            }

        } else if posterDeletedByUser {
            // User confirmed deletion — evict the original from the cache and clear state.
            owner.log("Applying poster deletion for film \(filmID)")
            if !originalUID.isEmpty {
                PosterCache.shared.removePoster(originalUID)
                owner.log("Evicted deleted poster \(originalUID) from cache")
            }
            posterDeletedByUser = false
            posterImageBeforeDelete = nil
            posterUIDBeforeDelete = ""
            pendingPosterURLBeforeDelete = nil
            self.posterUID = ""
            return ""

        } else {
            // No pending selection and no pending delete: posterUID is only ever
            // mutated alongside one of those two states (selectImage's success path
            // sets pendingPosterURL before it sets posterUID; deletePoster/undo set
            // posterDeletedByUser alongside posterUID), so reaching here means
            // posterUID still equals originalUID — nothing to reconcile with the cache.
            return posterUID
        }
    }
}

// MARK: - SwiftUI View
struct FSTabPosterView: View {
    @Bindable var viewModel: FSTabPoster

    var body: some View {
        VStack(spacing: 16) {
            Text(viewModel.titleText)
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Single layout path for both states — the frame, clip, shadow, and
            // padding are applied once to the Group rather than duplicated across
            // the if/else branches.
            Group {
                if let image = viewModel.posterImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        // Soft edge band (23.55 PosterEdgeSheen.swift) applied to the
                        // fitted image itself, so on a non-2:3 poster it hugs the picture
                        // rather than the letterboxed 200x300 frame; the matching clip is
                        // applied here too so the band's rounded corners and the visible
                        // corners agree (for a 2:3 poster this is identical to the frame
                        // clip below).
                        .overlay { PosterEdgeSheen.overlay(profile: .grid) }
                        .clipShape(RoundedRectangle(cornerRadius: Preferences.cornerRadius,
                                                    style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: Preferences.cornerRadius, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(Text("No Poster").foregroundStyle(.secondary))
                }
            }
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Preferences.cornerRadius, style: .continuous))
            // Mirrors GalleryItem's tile drop-shadow (black, radius 4, offset 2pt downward)
            // so the poster preview here reads with the same shadow weight as every
            // gallery cell elsewhere in the app, rather than SwiftUI's plain default
            // `.shadow(radius:)` shadow (centered, no directional offset).
            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
            .padding(.top, 20)

            // Button row — both buttons share the same chrome width.
            // A fixed-width Text label expands the button chrome to fill its
            // half of the 240-unit container (116pt each, 8pt gap).
            HStack(spacing: 8) {
                Button {
                    viewModel.selectImage()
                } label: {
                    Text("Select An Image…")
                        .frame(width: 116)
                }

                if viewModel.posterDeletedByUser {
                    Button {
                        viewModel.undoDeletePoster()
                    } label: {
                        Text("Undo Delete")
                            .frame(width: 116)
                    }
                } else {
                    Button {
                        viewModel.deletePoster()
                    } label: {
                        // Red mimics the system's .destructive role while enabled. When
                        // disabled (nothing to delete), the label falls back to .secondary
                        // at reduced opacity — plain .secondary alone still read as too
                        // prominent for a disabled control, and hierarchical .tertiary
                        // didn't match a normal disabled button label either.
                        Text("Delete Poster")
                            .foregroundStyle(viewModel.cannotDeletePoster
                                ? Color.secondary.opacity(0.5) : Color.red)
                            .frame(width: 116)
                    }
                    .disabled(viewModel.cannotDeletePoster)
                }
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
