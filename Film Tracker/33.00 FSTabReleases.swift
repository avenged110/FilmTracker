// MARK: - FSTabReleases.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// View model and supporting data model for the "Releases" tab of FilmSheet.
// The SwiftUI view layer lives in ReleasesView.swift (33.10).

import SwiftUI

// MARK: - ReleaseCardModel
// @Observable class holding the live UI state for a single release card.
//
// WHY A CLASS, NOT A STRUCT. The array holds object references, so writing a property on an
// element does not mutate the array, and a field edit never marks FSTabReleases.releases dirty.
// Were the elements structs, every keystroke would re-render the whole view and compete with any
// active Core Animation transaction (Picker dismissals, carousel springs). The view is invalidated
// only by structural changes, and each card subscribes only to the properties it reads.
//
// ReleaseCardState is the value-type snapshot used for diffing and serialization; `snapshot()`
// produces it.
@MainActor
@Observable
final class ReleaseCardModel {
    // Stable identity — matches the persisted ReleaseObj.id.
    let id: UUID

    var studio: String

    // MARK: - Studio UI state (ephemeral — not in snapshot/contentHash/serialization)
    // These drive the picker/text-field combo in ReleaseCardView. The canonical persisted value
    // is always `studio`; these are derived from it at load time via initializeStudioUI() and
    // kept in sync by ReleaseCardView's onChange handlers.
    //
    // studioSelection is the selected Picker tag: a known studio name, "" (Select Studio…), or
    // "Other". studioCustomText is the TextField shown when the selection is "Other".
    var studioSelection: String = ""
    var studioCustomText: String = ""

    // Derives studioSelection and studioCustomText from the current `studio`. Called once after
    // `studio` is populated — in init() for new cards, and by loadExistingReleases after
    // assigning the persisted value.
    //
    //   ""                    → selection "" (Select Studio…), customText ""
    //   known studio name     → selection = value, customText ""
    //   anything else         → selection "Other", customText = value
    func initializeStudioUI() {
        if studio.isEmpty {
            studioSelection  = ""
            studioCustomText = ""
        } else if ReleaseStudio.isKnown(studio) {
            studioSelection  = studio
            studioCustomText = ""
        } else {
            // Unknown or pre-existing free-text value — route to "Other" without data loss.
            // studioCustomText MUST be assigned BEFORE studioSelection. @Observable does not
            // distinguish programmatic writes from user interaction, and ReleaseCardView's
            // onChange(of: studioSelection) reads studioCustomText on the first body pass after
            // the card mounts. That value must already be the stored text, not the empty default,
            // or the studio is saved back as "Unknown".
            studioCustomText = studio
            studioSelection  = "Other"
        }
    }

    /// The year of the release date (Release.releaseDate). `hasReleaseYear` says whether the
    /// release has a date at all; while it is false this holds the Stepper's placeholder.
    var releaseYear: Int
    /// Whether the release has a release date. Clearing it also clears `releaseMonthDay`, so
    /// a date the user deletes cannot reappear under a year activated afterward — the field
    /// is cleared whole, as the Delete key promises.
    var hasReleaseYear: Bool {
        didSet { if !hasReleaseYear, releaseMonthDay != nil { releaseMonthDay = nil } }
    }
    /// The month and day of the release date; nil while the date is known only by its year,
    /// which every release stored before full dates is. Carried through load, combo-pack
    /// mirroring and save, so a full date survives an edit to any other field.
    var releaseMonthDay: ReleaseMonthDay?
    var baseReleaseYear: Int
    var hasBaseReleaseYear: Bool
    var purchased: Bool
    var wishlist: Int  // position (0 = not on wishlist, ≥1 = display order)
    var format: String
    var includedVersions: [String]
    var independence: String
    var videoFormat: String
    var releaseAspectRatio: [String]
    var scanningMethod: String
    var audioFormat: String
    var audioChannels: String
    var hasSubtitles: Bool
    var numberOfDiscs: Int
    var discMultiPack: Bool
    var hasArtwork: String
    var remastered: Bool
    var nationalOrigin: String
    var replicationType: String
    var discCapacity: [String]
    var hasHDR: String
    var masterType: String
    var regionLock: String
    var regionLockBypass: Bool
    var marketAvailability: [String]
    var numberOfCopies: Int
    var cost: Double
    var amountSpent: Double
    var purchaseDate: Date
    var hasPurchaseDate: Bool
    var lowestPrice: Double
    var lowestPriceDate: Date
    var hasLowestPriceDate: Bool
    var condition: String
    var notes: String
    var sortOrder: Int
    // Preserved from the persistent store; only used when updating an existing release.
    let dateAdded: Date

    // MARK: - Release Hierarchy (in-session)
    // Mirrors the Core Data relationship on ReleaseObj, propagated into ReleaseSnapshot at save
    // time. NOT in contentHash or ReleaseCardState — structural identity, not editable field
    // content, so it does not participate in field-level change detection.
    //
    // parentReleaseID is set on child Blu-ray cards auto-created from a 4K combo-pack parent.
    // childReleaseIDs holds one entry for "Combo-pack" and two for "Combo-pack (dual BD)"; the
    // count is derivable from the parent's independence, and reconcileComboChildren holds the
    // two in agreement.
    //
    // Array ORDER is not authoritative — it comes from the Core Data relationship, whose
    // element order is unspecified. Anything needing a stable ordering of a parent's children
    // must go through comboChildren(of:).
    //
    // MARK: Why the setters are narrowed
    //
    // A child's `parentReleaseID` and its parent's `childReleaseIDs` are two spellings of one edge,
    // and nothing in the type system holds them together. Only FSTabReleases sees the session's
    // releases, so only it can keep the pair consistent. `fileprivate(set)` makes that structural:
    // this file is ReleaseCardModel plus FSTabReleases, so the compiler refuses any hierarchy write
    // from a view or a helper. A view that needs the live child count calls `liveChildCount(of:)`,
    // which prunes stale IDs inside this type.
    //
    // Reads stay unrestricted: reading one side cannot desynchronize anything.
    fileprivate(set) var parentReleaseID: UUID? = nil
    fileprivate(set) var childReleaseIDs: [UUID] = []

    /// True when this card is an auto-created Combo-pack child (locked fields, no delete).
    var isComboChild: Bool { parentReleaseID != nil }

    // MARK: - Format tests
    // `format` stays a String (it is persisted verbatim and an unrecognized value must
    // round-trip — see ReleaseFormat), so these are the readable form of the string
    // in place of the string comparisons written at every call site. Each registers a read of `format`
    // exactly as the literal did; `format` is never mutated after init, so the subscription can
    // never actually fire.
    var releaseFormat: ReleaseFormat? { ReleaseFormat(rawValue: format) }
    /// True for the 4K UHD format — the parent side of every combo-pack relationship.
    var is4K: Bool { releaseFormat == .uhd4K }
    /// True for the Blu-ray format — the child side of every combo-pack relationship.
    var isBluRay: Bool { releaseFormat == .bluRay }
    /// True for the DVD format.
    var isDVD: Bool { releaseFormat == .dvd }

    // The associated Film's release year, used by purchaseYearRange to clamp the stepper lower
    // bound: a release cannot pre-date the film's own theatrical release year. Stored as 0 when
    // unset, which leaves the format-derived floor in effect.
    //
    // Seeded at card creation/load and maintained by FSTabReleases.updateFilmRelease(year:day:).
    // The Details tab owns that date, and the user can edit it while cards are already built, so
    // this is a `var`. Being @Observable-tracked, it also refreshes _ReleaseYearRow's Stepper ranges.
    //
    // Still NOT in contentHash: it is not persisted and is absent from ReleaseCardState, so it
    // is not a field edit. The corrections a floor change provokes are made through
    // releaseYear/baseReleaseYear, which ARE hashed.
    var filmReleaseYear: Int

    /// The first moment of the film's own release day (pinned calendar), or nil when the film
    /// has no release date. The release-date picker's floor: a disc cannot come out before
    /// the film does. Kept beside `filmReleaseYear` and maintained with it — seeded at
    /// creation and load, updated by FSTabReleases.updateFilmRelease(year:day:) — and, like
    /// it, not persisted or hashed.
    var filmReleaseDay: Date?

    // Convenience helper used by CustomDateStepper instances.
    // Lower bound is the tighter of the format's inherent floor and the film's own
    // release year. For example, a 4K UHD release for a film from 2020 floors at
    // 2020 rather than 2016, since no such release could physically predate the film.
    var purchaseYearRange: ClosedRange<Int> {
        let currentYear = FSTabReleases.currentYear
        // An unrecognized format falls back to the DVD floor. See ReleaseFormat.yearFloor(for:).
        let formatFloor = ReleaseFormat.yearFloor(for: format)
        // Defensive clamp on the lower bound. filmReleaseYear is parsed from the film's stored
        // release-year string, which the Details tab caps at the current year but the
        // metadata-import and restore pipelines do not — a future release year yields
        // lowerBound > currentYear, and `lowerBound...currentYear` traps at construction,
        // crashing the moment the tab opens. Clamping collapses the range to a single year,
        // which enforceReleaseYearOrder handles explicitly.
        let rawLowerBound = filmReleaseYear > formatFloor ? filmReleaseYear : formatFloor
        let lowerBound    = rawLowerBound > currentYear ? currentYear : rawLowerBound
        return lowerBound...currentYear
    }

    // MARK: - Release Date Picker
    //
    // The release date is the one date on the card that may lie ahead: a release can be
    // cataloged up to a year before it comes out (ReleaseDateValue.latestSelectableDay). Its
    // range is purchaseYearRange with the ceiling raised to the year of that latest day. Every
    // other year on the card, the base release year included, keeps the current-year ceiling.

    /// Years the release-date picker steps through on `today`.
    func releaseDateYearRange(today: Date) -> ClosedRange<Int> {
        let range = purchaseYearRange
        let latestYear = StorageDateFormatters.calendar.component(
            .year, from: ReleaseDateValue.latestSelectableDay(today: today))
        return range.lowerBound...max(range.upperBound, latestYear)
    }

    /// The earliest release date the picker offers: the film's own release day when it has
    /// one and it is later than January 1 of the range's floor year, else that January 1.
    /// Given to the picker as its minimum, so no interaction can build a date before the
    /// film came out, or a full date below the format floor (which would save as its year
    /// alone; ReleaseDateValue.init(year:monthDay:format:)).
    var releaseDateFloor: Date {
        let yearFloor = StorageDateFormatters.calendar.date(
            from: DateComponents(year: purchaseYearRange.lowerBound, month: 1, day: 1)) ?? Date()
        guard let filmReleaseDay else { return yearFloor }
        return max(yearFloor, filmReleaseDay)
    }

    /// The release date as the picker's Date. While the card has no month and day — a
    /// year-only value, or no date at all — it carries today's month and day in the stored
    /// year: what the picker shows once it is activated, and so what activating it commits.
    /// February 29 in a year without one becomes the 28th.
    var releaseDatePickerValue: Date {
        let cal = StorageDateFormatters.calendar
        let monthDay = releaseMonthDay ?? Self.todayMonthDay(in: releaseYear)
        let day = min(monthDay.day, gregorianDaysInMonth(monthDay.month, year: releaseYear))
        return cal.date(from: DateComponents(year: releaseYear, month: monthDay.month, day: day))
            ?? Date()
    }

    /// Writes a date the picker produced. Each field is written only when it changed, so an
    /// unchanged year does not re-run the ordering rule observing it.
    func setReleaseDate(_ date: Date) {
        let comps = StorageDateFormatters.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return }
        if releaseYear != year { releaseYear = year }
        let monthDay = ReleaseMonthDay(month: month, day: day)
        if releaseMonthDay != monthDay { releaseMonthDay = monthDay }
        clearAvailabilityIfUpcoming(today: CurrentDay.shared.today)
    }

    /// The picker's `yearOnlyValue` writes false when its first click turns a year-only value
    /// into a full date. The month and day become today's, matching what the picker shows; it
    /// then writes the full date itself whenever that differs (a clamp to its bounds, or a
    /// year it displayed differently).
    func endYearOnlyReleaseDate() {
        guard releaseMonthDay == nil else { return }
        let today = Self.todayMonthDay(in: releaseYear)
        releaseMonthDay = ReleaseMonthDay(
            month: today.month,
            day: min(today.day, gregorianDaysInMonth(today.month, year: releaseYear)))
        // A year-only value in a later year becomes a full date that is still ahead.
        clearAvailabilityIfUpcoming(today: CurrentDay.shared.today)
    }

    private static func todayMonthDay(in year: Int) -> ReleaseMonthDay {
        let comps = StorageDateFormatters.calendar.dateComponents([.month, .day], from: Date())
        return ReleaseMonthDay(month: comps.month ?? 1, day: comps.day ?? 1)
    }

    /// True while the card's release date lies after `today` (see ReleaseDateValue.isUpcoming).
    func isUpcomingRelease(today: Date) -> Bool {
        releaseDateValue?.isUpcoming(today: today) ?? false
    }

    /// Empties the market availability of a release whose date is still ahead: an
    /// unreleased disc has no market, and the card's menu shows "Not-yet-released" (a display
    /// value) while the date is ahead. Run wherever the release date is written — the
    /// picker's writes and load — so the stored field is empty everywhere it is read, and
    /// the menu comes back reading "Select Availability…" once the release is out.
    ///
    /// The combo-pack lock is left alone: "Combo-pack only" on a non-4K disc in a pack
    /// states how the disc is sold, not whether it can be bought yet, and nothing would put
    /// it back. Returns true when it cleared something.
    @discardableResult
    func clearAvailabilityIfUpcoming(today: Date) -> Bool {
        guard !marketAvailability.isEmpty, isUpcomingRelease(today: today) else { return false }
        let comboLocked = ReleaseIndependence.isComboPack(independence) && !is4K
        if comboLocked && marketAvailability == [ReleaseMarketAvailability.comboPackOnly] { return false }
        marketAvailability = []
        return true
    }

    // MARK: - Release Year Ordering Rule

    /// Enforces `baseReleaseYear < releaseYear` whenever both fields hold committed values.
    ///
    /// `baseReleaseYear` identifies the earliest permutation this release is a reissue of, so
    /// equality is as invalid as inversion. A logically impossible combination is corrected the
    /// instant it is produced rather than at save time, as the duration stepper does in
    /// DetailsView.
    ///
    /// The base year is always the field that yields. `releaseYear` names the release the card
    /// is actually about and is the field the user fills in first; `baseReleaseYear` only
    /// qualifies it, so it is the one sacrificed to restore the ordering — moved down beneath
    /// the release year, or cleared outright when no legal year exists there. This method never
    /// writes `releaseYear`, under any path, and callers depend on that:
    ///
    ///   • `syncComboChild` calls it immediately after assigning a child's parent-locked
    ///     release year, and the correction must not undo that assignment;
    ///   • `loadExistingReleases` must not silently rewrite a stored release year; and
    ///   • the user's own release-year edits stand as entered — stepping the release year down
    ///     past a committed base year drags the base year down with it, and stepping it onto
    ///     the range floor clears the base year rather than bouncing the release year back up.
    ///
    /// Both fields always land inside `purchaseYearRange` when they land at all.
    ///
    /// Returns immediately when the ordering already holds, so it is safe to call
    /// unconditionally — including re-entrantly from the `.onChange` handlers its own
    /// corrective writes trigger, which is what bounds the correction to a single extra pass.
    func enforceReleaseYearOrder() {
        // The rule is a relationship between two committed values. A field that has
        // not been given a value carries a placeholder year that is never persisted
        // (buildReleaseDeltas writes "" for it), so constraining against it would
        // move a real user value to satisfy a value that does not exist.
        guard hasReleaseYear, hasBaseReleaseYear else { return }

        let range = purchaseYearRange
        let lower = range.lowerBound
        let upper = range.upperBound

        // MARK: Release year on the range floor
        // No legal pair exists: the release year sits on the lowest year in range, so nothing
        // is left beneath it. The optional field is cleared, the required one kept. This also
        // covers a range collapsed to a single year by the format floor and the film's own
        // release year, where the release year can only sit on that year — unless it is
        // upcoming, in which case the range's one year is a legal base year beneath it.
        //
        // This is the path a user takes by stepping the release year down onto the floor while
        // a base year is committed: the base year is dropped back to its blank, unactivated
        // state, exactly as the Delete key leaves it.
        //
        // Tested BEFORE the ordering fast path below, because the conditions are independent: a
        // record can hold a base year correctly ordered yet below the range floor, which the
        // fast path would wave through.
        guard releaseYear > lower else {
            hasBaseReleaseYear = false
            return
        }

        // Fast path — no violation, nothing to do.
        guard baseReleaseYear >= releaseYear else { return }

        // Lower the base year beneath the release year. The floor guard above has already
        // established releaseYear > lower, so a legal year exists unconditionally.
        //
        // Capped at `upper`, the current year: a base year names an earlier release that has
        // already happened, so it never lies ahead even when the release year does (the
        // release-date picker reaches a year past `upper`; see releaseDateYearRange).
        baseReleaseYear = min(releaseYear - 1, upper)
    }

    // MARK: - Init
    // Used both for new releases (all defaults) and for loading existing records. The
    // dateAdded parameter preserves the original creation timestamp when loading. Callers that
    // load from the store overwrite the other mutable fields directly after init.
    init(id: UUID = UUID(), format: String = ReleaseFormat.bluRay.rawValue, sortOrder: Int = 0, dateAdded: Date = Date(), filmReleaseYear: Int = 0, filmReleaseDay: Date? = nil) {
        self.id                = id
        self.studio            = ""
        self.releaseYear       = FSTabReleases.currentYear
        self.hasReleaseYear    = false
        self.releaseMonthDay   = nil
        self.baseReleaseYear   = FSTabReleases.currentYear
        self.hasBaseReleaseYear = false
        self.purchased         = false
        self.wishlist          = 0
        self.format            = format
        self.includedVersions  = []
        self.independence      = ""
        self.videoFormat       = ""
        self.releaseAspectRatio = []
        self.scanningMethod    = ""
        self.audioFormat       = ""
        self.audioChannels     = ""
        self.hasSubtitles      = false
        self.numberOfDiscs     = 1
        self.discMultiPack     = false
        self.hasArtwork        = ""
        self.remastered        = false
        self.nationalOrigin    = ""
        self.replicationType   = ReleaseReplicationType.pressed
        self.discCapacity      = []
        self.hasHDR            = ""
        self.masterType        = ""
        self.regionLock        = ""
        self.regionLockBypass  = false
        self.marketAvailability = []
        self.numberOfCopies    = 1
        self.cost              = 0.0
        self.amountSpent       = 0.0
        self.purchaseDate      = Date()
        self.hasPurchaseDate   = false
        self.lowestPrice       = 0.0
        self.lowestPriceDate   = Date()
        self.hasLowestPriceDate = false
        self.condition         = ReleaseCondition.new
        self.notes             = ""
        self.sortOrder         = sortOrder
        self.dateAdded         = dateAdded
        self.filmReleaseYear   = filmReleaseYear
        self.filmReleaseDay    = filmReleaseDay
        // Derive initial picker/text-field state from the default studio value ("").
        // For new cards this always resolves to studioSelection = "" (Select Studio…).
        initializeStudioUI()
    }

    // MARK: - Format Defaults
    /// Applies a format's starting technical vocabulary to a newly created card.
    ///
    /// Every field the format's defaults describe is written unconditionally, including the ones
    /// the format leaves empty. That is safe because init() gives each of them the same neutral
    /// value ("" or false), so writing an empty default leaves the field as init built it. A
    /// per-format list of which fields to touch would duplicate the defaults table.
    ///
    /// Used by both creation paths, `addRelease` and `createComboChildren`, so they cannot disagree
    /// about what a fresh Blu-ray looks like. `comboChildHasBeenEdited` depends on that.
    func applyNewReleaseDefaults(for format: String) {
        let defaults = ReleaseFormat.newReleaseDefaults(for: format)
        nationalOrigin = defaults.nationalOrigin
        videoFormat    = defaults.videoFormat
        audioFormat    = defaults.audioFormat
        audioChannels  = defaults.audioChannels
        hasHDR         = defaults.hasHDR
        scanningMethod = defaults.scanningMethod
        regionLock     = defaults.regionLock
        masterType     = defaults.masterType
        hasSubtitles   = defaults.hasSubtitles
        includedVersions = defaults.includedVersions
        // Written like every other default, before the card is ever rendered, so no .onChange
        // cascade observes it: the Type picker's cascade fires on a CHANGE to a mounted card,
        // and a value assigned at construction has no prior value to differ from.
        //
        // Safe on a combo-pack child too: syncComboChild overwrites independence with
        // "Combo-pack" immediately after the child is appended, and independence is a locked
        // field absent from comboChildEditableFields either way.
        independence   = defaults.independence
    }

    // MARK: - Snapshot
    // Produces a value-type ReleaseCardState for diffing and serialization.
    //
    // MARK: Unset optional fields are normalized, not copied
    //
    // The four optional fields — two years, two dates — are each a (value, flag) pair whose
    // value is meaningful ONLY while the flag is true. While it is false the value is a
    // placeholder the store never sees: modelToReleaseSnapshot writes "" for exactly these
    // four, so two cards differing only in an inactive field's leftover placeholder are the
    // same card as far as anything persisted goes.
    //
    // Copying the placeholder into the snapshot would let the change baseline disagree with that.
    // Activating a combo child's base release year moves the value immediately, and clearing the
    // field afterwards lowers the flag but leaves the moved number behind. The card would then be
    // dirty against a field the user had emptied, which cannot be persisted either way.
    //
    // Normalized here rather than by clearing the model's value on delete, because the
    // placeholder is load-bearing in the UI — it is the year the Stepper displays grayed out,
    // and the value re-activation commits.
    //
    // Everything that asks "did this card change?" routes through this one method and
    // `ReleaseCardState`'s synthesized `==`, so the normalization is applied once, here.
    func snapshot() -> ReleaseCardState {
        ReleaseCardState(
            id:                 id,
            studio:             studio,
            releaseYear:        hasReleaseYear ? releaseYear : ReleaseCardState.unsetYear,
            hasReleaseYear:     hasReleaseYear,
            // Normalized as it is saved (releaseDateValue), so a day the year has since
            // lost — February 29 under a non-leap year — compares as the day it saves as.
            releaseMonthDay:    releaseDateValue?.monthDay,
            baseReleaseYear:    hasBaseReleaseYear ? baseReleaseYear : ReleaseCardState.unsetYear,
            hasBaseReleaseYear: hasBaseReleaseYear,
            purchased:          purchased,
            wishlist:           wishlist,
            format:             format,
            includedVersions:   includedVersions,
            independence:       independence,
            videoFormat:        videoFormat,
            releaseAspectRatio: releaseAspectRatio,
            scanningMethod:     scanningMethod,
            audioFormat:        audioFormat,
            audioChannels:      audioChannels,
            hasSubtitles:       hasSubtitles,
            numberOfDiscs:      numberOfDiscs,
            discMultiPack:      discMultiPack,
            hasArtwork:         hasArtwork,
            remastered:         remastered,
            nationalOrigin:     nationalOrigin,
            replicationType:    replicationType,
            discCapacity:       discCapacity,
            hasHDR:             hasHDR,
            masterType:         masterType,
            regionLock:         regionLock,
            regionLockBypass:   regionLockBypass,
            marketAvailability: marketAvailability,
            numberOfCopies:     numberOfCopies,
            cost:               cost,
            amountSpent:        amountSpent,
            purchaseDate:       hasPurchaseDate ? purchaseDate : ReleaseCardState.unsetDate,
            hasPurchaseDate:    hasPurchaseDate,
            lowestPrice:        lowestPrice,
            lowestPriceDate:    hasLowestPriceDate ? lowestPriceDate : ReleaseCardState.unsetDate,
            hasLowestPriceDate: hasLowestPriceDate,
            condition:          condition,
            notes:              notes,
            sortOrder:          sortOrder,
            dateAdded:          dateAdded
        )
    }

    // MARK: - Content Hash
    // One observable value reflecting the combined state of every mutable field, so observers take a
    // single "did anything change" signal instead of one .onChange modifier per field (which also hit
    // the type-checker's complexity limit).
    //
    // Being a computed property on an @Observable class, accessing it registers a read of every field
    // it references, so per-property invalidation still works normally.
    //
    // Derived from `snapshot()` rather than from a separate list of `h.combine` calls. A hand-written
    // list is a second copy of the field set that the compiler cannot check: a field missed there would
    // never schedule a change check. Hashing the snapshot covers every field ReleaseCardState carries.
    //
    // The extra combines below are a closed set. They preserve this property's sensitivity, which is
    // deliberately broader than the snapshot's:
    //
    //   • The two years, the release month/day, and two dates are normalized away by `snapshot()` while
    //     their has-flag is false. Reading them unconditionally here keeps the observer subscribed to the
    //     placeholder values, so the Stepper's grayed-out year still signals. (A ternary would not even
    //     register the read, let alone the value.)
    //   • The three Doubles are hashed by bit pattern, so a 0.0 → -0.0 write still signals even though
    //     `==` considers the two equal.
    /// The release date as it is saved, or nil while the card has none. Built by
    /// ReleaseDateValue.init(year:monthDay:format:), so what is saved always reads back: a
    /// stored day the current year lacks is clamped, and a full date that would fail this
    /// card's format floor keeps only its year.
    ///
    /// A year outside ReleaseDateValue.storableYears cannot be stored in either shape and
    /// saves as its bare number, exactly as the year field always saved — such a year only
    /// reaches a card from a store edited outside the app, and loads as the current year.
    var releaseDateValue: ReleaseDateValue? {
        guard hasReleaseYear else { return nil }
        return ReleaseDateValue(year: releaseYear, monthDay: releaseMonthDay, format: format)
    }

    /// The string the card saves for its release date.
    var releaseDateStorageString: String {
        guard hasReleaseYear else { return "" }
        return releaseDateValue?.storageString ?? String(releaseYear)
    }

    var contentHash: Int {
        var h = Hasher()
        h.combine(snapshot())
        h.combine(releaseYear)
        h.combine(releaseMonthDay)
        h.combine(baseReleaseYear)
        h.combine(purchaseDate)
        h.combine(lowestPriceDate)
        h.combine(cost.bitPattern)
        h.combine(amountSpent.bitPattern)
        h.combine(lowestPrice.bitPattern)
        return h.finalize()
    }
}

// MARK: - Format Ordering
//
// The unified carousel's primary sort key. The rank itself is `ReleaseFormat.displayRank`
// (63.00 ReleaseObj), shared with the two sidebar lists that order releases the same way; this
// is only the carousel's spelling of it over a card model.
extension ReleaseCardModel {
    /// Sort rank for the unified carousel. Unknown formats sort last rather than crashing
    /// or colliding with a real format's rank — a film restored from a backup written by a
    /// future build can carry a format string this one does not know.
    var carouselRank: Int { ReleaseFormat.displayRank(for: format) }

    /// The one ordering rule for two releases of equal standing: `sortOrder`, then id.
    ///
    /// THIS IS A CORRECTNESS INVARIANT, NOT A CONVENIENCE. Four sites need "the first child"
    /// and "the second child" to mean the same thing — the load-time hierarchy rebuild,
    /// `unifiedReleaseOrder`, the per-entry child sort in `buildCarouselEntries`, and
    /// `comboChildren(of:)` — because a dual→single downgrade discards the LAST child and the
    /// confirmation alert must describe the same disc the reconciliation then removes. Four
    /// copies of a rule cannot be made to agree by comment; one function cannot disagree with
    /// itself.
    ///
    /// The `id` tiebreak is not padding: `sortOrder` is loaded from persisted values and a
    /// backup written by an interrupted save can carry a duplicate, and `sorted(by:)` is not
    /// stable — so without a total order two cards could swap places between one body
    /// evaluation and the next.
    ///
    /// `ReleaseSnapshot.reconcilingHierarchy` applies the identical rule at the model→snapshot
    /// boundary. It cannot share this function (it orders snapshots, not models), so it is the
    /// single deliberate restatement, and its doc comment names this one.
    static func precedes(_ lhs: ReleaseCardModel, _ rhs: ReleaseCardModel) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Carousel Entry
//
// One CARD in the carousel, which is not the same thing as one release: a 4K parent and the
// Blu-ray child (or children) bundled with it in a combo pack occupy a single card carrying a
// segmented picker in its header. Every other release is its own entry with an empty
// `children` array.
//
// MARK: Why identity is the parent's id and not a synthesized one
//
// `id` is what the carousel's `ForEach` uses to decide whether a card is the same card across
// an update, and what the jump menu addresses. A synthesized id would change whenever a combo
// pack gained or lost a child, and SwiftUI would read that as "this card was replaced" —
// tearing down and rebuilding ~50 controls, and dropping first responder if the user happened
// to be typing in one. The parent's UUID is stable across exactly the mutations that should
// NOT rebuild the card.
struct ReleaseCarouselEntry: Identifiable, Equatable {
    let parent: ReleaseCardModel
    /// Combo-pack children merged onto this card, in `comboChildren(of:)` order.
    let children: [ReleaseCardModel]

    var id: UUID { parent.id }

    // MARK: - Variants
    //
    // Every release this card can display, in segment order: parent first, then children. The
    // header's segmented picker indexes directly into this sequence.
    //
    // Addressed through accessors rather than materialized as an array. `[parent] + children`
    // allocated on every read, and the hot reader is `CarouselCard.body`, which runs on every
    // mounted card whenever the variant map changes — possibly while the carousel is still
    // settling. It needs a count and ONE element.

    /// Number of segments this card offers. 1 for an unmerged entry.
    var variantCount: Int { children.count + 1 }

    /// The release shown at segment `index`. Segment 0 is always the parent.
    /// Precondition: `0..<variantCount`, which every caller derives from `variantIndex(for:)`
    /// or from `variantCount` itself.
    func variant(at index: Int) -> ReleaseCardModel {
        index == 0 ? parent : children[index - 1]
    }

    /// The segment showing a release of `format`, or nil if this card holds none. Parent first,
    /// matching segment order, so an unmerged card answers about itself.
    ///
    /// `@MainActor` because this reads a FIELD off the models, unlike the two accessors above
    /// which only move references around; the entry itself carries no isolation of its own.
    @MainActor
    func variantIndex(ofFormat format: String) -> Int? {
        if parent.format == format { return 0 }
        guard let offset = children.firstIndex(where: { $0.format == format }) else {
            return nil
        }
        return offset + 1
    }

    /// Whether this card needs a segmented picker at all.
    var isMerged: Bool { !children.isEmpty }

    // Identity comparison only. The models are reference types whose FIELD changes are
    // delivered to the card by @Observable, not by this struct being rebuilt — comparing
    // field values here would defeat that isolation and re-diff every card on every
    // keystroke. Two entries are "equal" when they name the same releases in the same
    // order, which is the only thing the carousel's structure depends on.
    static func == (lhs: ReleaseCarouselEntry, rhs: ReleaseCarouselEntry) -> Bool {
        lhs.parent === rhs.parent
            && lhs.children.count == rhs.children.count
            && zip(lhs.children, rhs.children).allSatisfy { $0 === $1 }
    }
}

// MARK: - FSTabReleases

@MainActor
@Observable
final class FSTabReleases {
    weak var owner: FilmSheet?

    // Not cached at launch, so release year defaults and purchase year ranges stay accurate if
    // the app is left running across a calendar year boundary. That guarantee comes from the
    // shared CurrentYear cache (90.00), which keeps it while removing the Calendar lookup from
    // the per-access cost — this is read on every _ReleaseYearRow evaluation and again inside
    // every enforceReleaseYearOrder pass.
    static var currentYear: Int { CurrentYear.value }

    // Live card models. Each element is a reference type — field mutations on a
    // model do NOT mutate this array, so @Observable never marks 'releases' dirty
    // from typing or picker changes. Only structural mutations (append, remove,
    // move) change the array and trigger a re-render of FSTabReleasesView.
    var releases: [ReleaseCardModel] = [] {
        didSet {
            updateCarouselCache()
            // Change detection is armed per model here rather than by a view, so it is a
            // property of the model's presence in this array and not of whether a card
            // for it happens to be mounted. See ReleaseChangeObserver.
            reconcileChangeObservers()
        }
    }

    // MARK: - Unified carousel cache
    //
    // One CARD per entry, not one per release: a 4K combo-pack parent and the disc (or two)
    // bundled with it occupy a single entry behind the card's variant picker. Ordered
    // 4K → Blu-ray → DVD, each run in sortOrder.
    //
    // Rebuilt only in `releases.didSet` — only on a structural mutation — so a field edit never
    // re-derives it and never invalidates the carousel.
    private(set) var carouselEntries: [ReleaseCarouselEntry] = []

    /// Per-format display number for every CARD ("Release 3"), keyed by the card's parent
    /// release id. Rebuilt alongside `carouselEntries`. See `buildDisplayNumbers(for:)`.
    private(set) var displayNumbers: [UUID: Int] = [:]

    // MARK: - Merged-card variant selection
    //
    // Cards whose variant picker is showing a bundled Blu-ray rather than the 4K parent. Keyed
    // by the entry's (parent's) id, storing a segment index addressed through
    // `ReleaseCarouselEntry.variant(at:)`; absent means the parent, so the common case stores
    // nothing.
    //
    // Held here rather than as `@State` on the card so a selection survives the card being
    // unmounted by the mount window and re-mounted when it scrolls back in.
    var selectedVariantByCard: [UUID: Int] = [:]

    /// The variant index to display for `cardID`, clamped to the variants that exist.
    ///
    /// Clamped on read rather than reconciled on write: a pack that loses the child
    /// currently being displayed falls back to the parent on the very pass that observes
    /// the shorter array, with no separate reconciliation step that could land late.
    func variantIndex(for cardID: UUID, variantCount: Int) -> Int {
        let raw = selectedVariantByCard[cardID] ?? 0
        return min(max(raw, 0), max(0, variantCount - 1))
    }

    // Carousel state: index of the visible card within `carouselEntries`. There is one stack, so one index.
    var currentIndex: Int = 0

    // ID of a card currently animating off-screen (fly-up delete).
    var dismissingCardID: UUID? = nil

    // ID of a card currently animating in (fade-in on add).
    var addingCardID: UUID? = nil

    // True while any card animation is in flight.
    var isTransitioning: Bool { dismissingCardID != nil || addingCardID != nil }

    // Track original release snapshots for change detection.
    // Maps release ID → ReleaseCardState snapshot taken at load time.
    // Built once in captureOriginalValues(); never mutated thereafter.
    private var originalReleasesByID: [UUID: ReleaseCardState] = [:]
    // Ordered list of original IDs for delta computation.
    private var originalIDs: [UUID] = []

    /// What the dirty diagnostic last reported, so an unchanged report is not re-emitted.
    ///
    /// `@ObservationIgnored` is load-bearing: this is written from `checkForChanges()`, which
    /// runs on the 150 ms debounce tick. A tracked property written there would fire an
    /// @Observable invalidation on every tick that changes the diagnostic, for a value no view
    /// reads — the exact cost the surrounding code is written to avoid.
    ///
    /// Empty means "not currently dirty", so returning to a state re-logs it rather than being
    /// swallowed as a repeat.
    ///
    /// Keyed per release (and "structural"), holding the NAMES of the fields last reported for
    /// it — not the rendered line. See the emit site for why.
    @ObservationIgnored private var lastDirtyDiagnostic: [String: String] = [:]

    // Change tracking.
    var hasChanges: Bool = false

    // MARK: - Load-time repairs
    //
    // IDs of releases that loadExistingReleases' repairs CHANGED: a cleared parent link
    // (Cases A/B), a corrected base release year (Case C and the orphaned-base-year
    // repair), a relabeled combo-pack independence (Case D), or a combo child converged onto
    // its parent (Case E).
    //
    // WHY THIS SET HAS TO EXIST. Those repairs claim to persist on the next save, and without
    // this they cannot, because `captureOriginalValues()` runs AFTER loadExistingReleases:
    // the repaired state IS the baseline, and `buildReleaseDeltas` decides `toUpdate` by
    // snapshot inequality against it, so a repair compares equal to itself and is never
    // written. (For the hierarchy repairs there is a second reason — `ReleaseCardState`
    // omits both hierarchy fields entirely.) Every consumer that reads the store rather than
    // this session — the sidebar, the reports, search — went on seeing the unrepaired
    // values indefinitely, and the sheet re-repaired them on every open.
    //
    // So the repaired IDs are recorded explicitly and force-included in `toUpdate`. For a
    // cleared parent link, DataManager step 6.5's `parentReleaseID == nil` branch clears the
    // stale relationship; for the field repairs, the snapshot carries the values.
    //
    // Cosmetic normalizations (vocabulary canonicalization, `condition` capitalization) are
    // deliberately NOT recorded: they change no meaning, and forcing a write for them would
    // rewrite most legacy releases on the first unrelated save.
    //
    // DELIBERATELY NOT wired into `hasChanges`: folding the repairs into the baseline is what
    // keeps an affected film from opening with "Update" already enabled. The consequence is
    // bounded — the repair rides along with the next real save rather than forcing one, so a
    // film opened and closed untouched keeps the anomaly and is repaired again next time.
    //
    // For hierarchy repairs only the child is recorded; the parent side is derived at save
    // time from the children's own pointers and is never persisted directly.
    @ObservationIgnored private var loadRepairedIDs: Set<UUID> = []

    // MARK: - Field-change observation
    // One observer per live model, keyed by release ID. @ObservationIgnored because this
    // is control bookkeeping — mutating the dictionary must not invalidate any view, and
    // nothing reads it from a body.
    @ObservationIgnored private var changeObservers: [UUID: ReleaseChangeObserver] = [:]

    // Debounce handle for field-level change checks (typing, etc.).
    private var changeCheckTask: TaskHandle?

    // MARK: - Animation quiescence window
    // Deadline before which no change check may execute. Set via markAnimationWindow at every
    // call site that kicks off a card animation — navigation springs, the add slide/fade, the
    // delete fly-up, confirmation presentations — sized to cover that animation's full visual
    // duration.
    //
    // WHY: checkForChanges() is deliberately deferred off the mutation tick, but "one tick later"
    // often lands inside the first frames of the very animation the mutation started. The check
    // compares every release, and when the aggregated result flips, owner.notifyChanges() cascades
    // into hasChanges/canConfirm writes that re-render the FilmSheet footer and start its 0.2 s button
    // fade, all mid-spring. The window keeps those writes out of the animation.
    //
    // CORRECTNESS: the delay is bounded (≤ ~1 s) and affects only WHEN hasChanges/canConfirm
    // update, never their eventual value. No save path depends on their timeliness —
    // FilmSheet.confirm() reads the tab data and buildReleaseDeltas() directly, and cancel()
    // does not consult hasChanges.
    private var animationQuiescenceDeadline: ContinuousClock.Instant? = nil

    /// Opens (or extends) the animation quiescence window. Pending and future
    /// change checks will not execute until `duration` from now has elapsed.
    /// Repeated calls extend the window monotonically — an earlier, longer
    /// deadline is never shortened by a later, nearer one (e.g. a 450 ms
    /// navigation mark landing inside a 900 ms add-sequence window).
    func markAnimationWindow(_ duration: Duration) {
        let candidate = ContinuousClock.now + duration
        if let existing = animationQuiescenceDeadline, existing > candidate { return }
        animationQuiescenceDeadline = candidate
    }

    /// Suspends until the quiescence window (if any) has fully elapsed.
    /// Loops because the deadline may be extended while sleeping (rapid
    /// consecutive navigation). Returns promptly on task cancellation; callers
    /// re-check Task.isCancelled before acting.
    ///
    private func waitForAnimationQuiescence() async {
        while let deadline = animationQuiescenceDeadline, ContinuousClock.now < deadline {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if Task.isCancelled { return }
        }
    }

    // Handle for the in-flight card-deletion animation task.
    // Stored so the async removal body can be canceled if a second deleteRelease
    // call arrives while the 300 ms fly-up animation is still running, preventing
    // two concurrent tasks from mutating releases and dismissingCardID simultaneously.
    private var deleteTask: TaskHandle?

    // MARK: - Deferred work a save must not outrun
    //
    // Three user actions take effect a beat AFTER the user makes them, for animation and
    // menu-dismissal reasons: a delete removes its release only when the 300 ms fly-up ends,
    // a Type change reconciles combo-pack children ~120 ms later (`comboChildTasks`), and a
    // confirmed type-change alert writes its value one turn after the alert dismisses.
    // `FilmSheet.confirm()` builds its deltas synchronously, so a save landing inside one of those
    // windows would persist the state from before the action: a deleted release that came back on the
    // next open, or a 4K release saved as "Combo-pack" with no Blu-ray child, a state no later
    // interaction repairs. `settlePendingWork()` completes all three on demand; these two properties
    // are what it needs to know about the first and third.
    //
    // `@ObservationIgnored`: bookkeeping, read by no view.

    /// The delete whose fly-up is running, with the removal set it will apply.
    @ObservationIgnored private var pendingDeletion: (id: UUID, idsToRemove: [UUID])?

    /// Type changes the user has CONFIRMED in the alert but that have not yet been written
    /// (the write is deferred one turn past the alert's dismissal), keyed by release id.
    @ObservationIgnored private var pendingConfirmedIndependence: [UUID: String] = [:]

    // Handle for the in-flight add sequence (mount → slide → fade → teardown).
    //
    // Held like the other multi-phase tasks, so teardown cancels it. TaskHandle's deinit cancels it
    // with the view model, and the cancellation checks inside the sequence unwind `addingCardID` and
    // the mount window rather than stranding them.
    private var addSequenceTask: TaskHandle?

    // MARK: - Combo-pack child management
    // Debounce handles for deferred child creation/deletion when independence changes. A
    // TaskHandle decouples the side effect from the picker animation transaction.
    //
    // KEYED BY PARENT, not one shared slot. The debounce lets one picker spin through several values
    // and settle on the final selection, which is a per-parent concern. A shared slot would let a second
    // 4K parent retyped within menuDismissalSettleDelay of the first silently cancel the first parent's
    // reconciliation, leaving it with a combo-pack independence and no children. The next load's Case D
    // repair would then "correct" the label to match, discarding the user's actual choice.
    //
    // Entries are not pruned on completion: the dictionary is bounded by the release cap, lives
    // only as long as the sheet, and a finished Task's handle cancels to a no-op.
    @ObservationIgnored private var comboChildTasks: [UUID: TaskHandle] = [:]

    // MARK: - Pending Confirmation
    //
    // Both of this tab's confirmations are NSAlert sheets on the FilmSheet's window, presented
    // by ReleaseConfirmationController. See that type for why NSAlert and not SwiftUI's
    // `.alert`. Under confirm-before-commit nothing is written until the user confirms, so
    // presentation carries no mutation at all.
    /// Owns the alert's presentation flag and payload. Held as an `@ObservationIgnored` `let`
    /// and not itself observable, so presenting a confirmation has no edge to any view.
    @ObservationIgnored let confirmation = ReleaseConfirmationController()

    /// Read-only mirror of the presentation flag for the carousel's event monitors and the
    /// AppEventBus sink, so navigation, add, and delete stay inert while a confirmation is up.
    ///
    /// Those call sites read this from closures rather than from a view body, so the forwarded
    /// read registers no subscription anywhere.
    var isConfirmationPresented: Bool { confirmation.isPresented }

    /// Raises a confirmation. Exactly one of `onConfirm`/`onCancel` runs.
    ///
    /// Re-entrancy is rejected rather than queued: a second confirmation while one is up
    /// would have nowhere to present, and the caller's cancel path is the correct
    /// outcome for a request that never reached the user.
    func requestConfirmation(title: String,
                             message: String,
                             confirmTitle: String,
                             isDestructive: Bool,
                             onConfirm: @escaping @MainActor () -> Void,
                             onCancel: @escaping @MainActor () -> Void = {}) {
        guard !confirmation.isPresented else { onCancel(); return }

        confirmation.present(title: title,
                             message: message,
                             confirmTitle: confirmTitle,
                             isDestructive: isDestructive,
                             onConfirm: onConfirm,
                             onCancel: onCancel)
    }

    /// Sequences the combo-pack confirmation (see requestIndependenceChange), so spinning the
    /// Type picker through several values discards the earlier, not-yet-presented prompts.
    ///
    /// Keyed by release id, as `comboChildTasks` is: superseding a prompt is a per-card concern, so
    /// one card's change cannot cancel another card's pending prompt.
    @ObservationIgnored private var independencePromptTasks: [UUID: TaskHandle] = [:]

    // MARK: - Initialization

    // The shared "yyyy.MM.dd" storage formatter, which is also the one parseDate uses
    // to read these strings back — so writer and reader are the same object rather than
    // two configurations that have to agree.
    private static let releaseDateFormatter = StorageDateFormatters.dot

    init(owner: FilmSheet) {
        self.owner = owner
        if owner.isEditMode {
            loadExistingReleases(with: owner.filmID)
            captureOriginalValues()
            // MUST follow captureOriginalValues, and MUST stay synchronous with it.
            // See rebaselineChangeObservers().
            rebaselineChangeObservers()
        }
    }

    // MARK: - Load Releases from Database
    private func loadExistingReleases(with id: UUID) {
        guard let owner = owner else { return }

        guard let film = owner.coordinator.getFilm(id) else {
            owner.log("ERROR: Film \(id) not found in memory store")
            return
        }

        let sortedReleases = film.releases.sorted { $0.sortOrder < $1.sortOrder }
        let dateFormatter = FSTabReleases.releaseDateFormatter
        // Parse the film's release year once for all release models in this load.
        // ReleaseCardModel treats 0 as "no constraint" in purchaseYearRange.
        let parsedFilmYear = Int(film.releaseYear) ?? 0
        // And its day, for the release-date picker's floor (filmReleaseDay).
        let parsedFilmDay = parseDate(from: film.releaseDate)
            .map { StorageDateFormatters.calendar.startOfDay(for: $0) }

        releases = sortedReleases.map { release in
            let model = ReleaseCardModel(
                id:             release.id,
                format:         release.format,
                sortOrder:      release.sortOrder,
                dateAdded:      release.dateAdded,
                filmReleaseYear: parsedFilmYear,
                filmReleaseDay: parsedFilmDay
            )

            model.studio           = release.studio
            // Resolve the picker/text-field UI state from the loaded studio value.
            // Any value not in the known studio list (including pre-existing free-text)
            // maps cleanly to "Other" + the value in studioCustomText, avoiding data loss.
            model.initializeStudioUI()
            model.independence     = release.independence
            model.videoFormat      = release.videoFormat
            // Canonicalized on load (see also includedVersions below). The menus commit in
            // vocabulary order, but a record written before that rule can hold the same values
            // in a different order, rendering as "Extended, Theatrical" beside another
            // release's "Theatrical, Extended". Normalizing inside loadExistingReleases, which
            // init() calls BEFORE captureOriginalValues(), folds the correction into the
            // change-detection baseline so the film does not open already dirty.
            model.releaseAspectRatio = ReleaseOptionVocabulary.aspectRatios
                .canonicalized(release.releaseAspectRatio)
            model.scanningMethod   = release.scanningMethod
            model.audioFormat      = release.audioFormat
            model.audioChannels    = release.audioChannels
            model.hasSubtitles     = release.hasSubtitles
            model.numberOfDiscs    = release.numberOfDiscs
            model.discMultiPack    = release.discMultiPack
            model.hasArtwork       = release.hasArtwork
            model.remastered       = release.remastered
            model.nationalOrigin   = release.nationalOrigin
            model.replicationType  = release.replicationType
            model.discCapacity     = release.discCapacity
            model.hasHDR           = release.hasHDR
            model.masterType       = release.masterType
            model.regionLock       = release.regionLock
            model.regionLockBypass = release.regionLockBypass
            model.marketAvailability = release.marketAvailability
            model.numberOfCopies   = release.numberOfCopies
            model.cost             = release.cost
            model.amountSpent      = release.amountSpent
            model.lowestPrice      = release.lowestPrice
            model.condition        = release.condition.capitalized
            model.notes            = release.notes
            model.purchased        = release.purchased
            model.wishlist         = release.wishlist
            model.includedVersions = ReleaseOptionVocabulary.includedVersions
                .canonicalized(release.includedVersions)

            // Either stored shape (ReleaseDateValue). An unreadable non-empty value — malformed,
            // or a full date before this format's floor — loads as a dated release in the
            // current year, as an unreadable year always has.
            // releaseMonthDay is assigned AFTER hasReleaseYear, whose didSet clears it.
            let releaseDateValue = ReleaseDateValue(release.releaseDate, format: release.format)
            let hasReleaseYearValue = !release.releaseDate.isEmpty
            model.hasReleaseYear = hasReleaseYearValue
            model.releaseYear = hasReleaseYearValue
                ? (releaseDateValue?.year ?? FSTabReleases.currentYear)
                : FSTabReleases.currentYear
            model.releaseMonthDay = hasReleaseYearValue ? releaseDateValue?.monthDay : nil

            let hasBaseReleaseYearValue = !release.baseReleaseYear.isEmpty
            model.hasBaseReleaseYear = hasBaseReleaseYearValue
            model.baseReleaseYear = hasBaseReleaseYearValue
                ? (Int(release.baseReleaseYear) ?? FSTabReleases.currentYear)
                : FSTabReleases.currentYear

            let hasPurchaseDateValue = !release.purchaseDate.isEmpty
            model.hasPurchaseDate = hasPurchaseDateValue
            model.purchaseDate = hasPurchaseDateValue
                ? (dateFormatter.date(from: release.purchaseDate) ?? Date())
                : Date()

            let hasLowestPriceDateValue = !release.lowestPriceDate.isEmpty
            model.hasLowestPriceDate = hasLowestPriceDateValue
            model.lowestPriceDate = hasLowestPriceDateValue
                ? (dateFormatter.date(from: release.lowestPriceDate) ?? Date())
                : Date()

            // Populate hierarchy IDs so the in-session models reflect the persisted
            // parent/child relationship.
            model.parentReleaseID = release.parentReleaseID
            model.childReleaseIDs = release.childReleaseIDs

            return model
        }
        // MARK: - Post-load hierarchy integrity repair
        // Heals broken parent/child references arising from interrupted saves, migration from
        // pre-combo-pack data, or any other condition where the MemoryStore snapshot's
        // hierarchy IDs do not match the loaded models.
        //
        //   (A) A parent holds a childReleaseID not present in releases — removed, so the
        //       parent cannot get stuck in combo-pack state with no visible or deletable child.
        //   (B) A child holds a parentReleaseID not present in releases — cleared, unlocking
        //       the locked fields and the delete button so the orphan can be edited or removed.
        //
        // Both log a warning. Repairs are in-session; the corrected state persists on the next
        // save.
        let loadedIDSet = Set(releases.map { $0.id })

        // Cases A and B are handled together, and by REBUILDING rather than by pruning.
        //
        // The two sides of the hierarchy are not equally trustworthy. A child's
        // `parentReleaseID` is written everywhere — by createComboChildren in-session, by
        // DataManager's step 6.5 on save, by DBRestorer on restore, and by the export format,
        // which has no field for the parent side at all. `childReleaseIDs` is derived from
        // the inverse relationship and is the side that can come back empty while the
        // child pointers survive.
        //
        // Pruning-only repair could not see that failure: with the parent claiming no children
        // and each child still naming the parent, there is no stale ID to prune and no orphan
        // to unlock. In that state the card shows no children and no deletion confirmation applies,
        // while the sidebar, which groups on `parentReleaseID ?? id`, still reads the surviving side.
        //
        // ReleaseSnapshot.reconcilingHierarchy performs the same derivation at the
        // model→snapshot boundary, so in normal operation this finds nothing to do. It is kept
        // because this is the last point before the models are handed to the confirmation and
        // reconciliation logic, and because MemoryStore snapshots written by the sheet's own
        // save path do not pass through that boundary.
        //
        //   (B) A child naming a parent that is absent, that is itself a child (an illegal
        //       second level), or that is the child itself, has its parentReleaseID cleared.
        //   (A) Every parent's childReleaseIDs is then rebuilt from the surviving pointers.
        //
        // Ordering is deliberate: (B) runs first and in two rounds, so a release that is only
        // "a child" by virtue of a pointer about to be cleared is not mistaken for an illegal
        // middle level. The repairs are in-session and land BEFORE captureOriginalValues(), so
        // a repaired film does not open with the Update button already enabled.
        var modelsByID = [UUID: ReleaseCardModel](minimumCapacity: releases.count)
        for model in releases { modelsByID[model.id] = model }

        // Round 1: pointers into nothing.
        for model in releases {
            guard let pid = model.parentReleaseID else { continue }
            if !loadedIDSet.contains(pid) {
                owner.log(
                    "WARNING: Release \(model.id) has parentReleaseID \(pid) not found in " +
                    "session releases — clearing stale parent reference to restore full editability."
                )
                model.parentReleaseID = nil
                loadRepairedIDs.insert(model.id)
            } else if pid == model.id {
                owner.log(
                    "WARNING: Release \(model.id) names itself as its parent — clearing the " +
                    "self-reference."
                )
                model.parentReleaseID = nil
                loadRepairedIDs.insert(model.id)
            }
        }

        // Round 2: pointers at a release that is itself a child (depth > 1).
        for model in releases {
            guard let pid = model.parentReleaseID,
                  let parent = modelsByID[pid],
                  parent.parentReleaseID != nil else { continue }
            owner.log(
                "WARNING: Release \(model.id) names parent \(pid), which is itself a child " +
                "release — clearing the link (only one level of hierarchy is supported)."
            )
            model.parentReleaseID = nil
            loadRepairedIDs.insert(model.id)
        }

        // Rebuild the parent side from the pointers that survived, in the project's one
        // child ordering — see ReleaseCardModel.precedes.
        var childrenByParent = [UUID: [ReleaseCardModel]](minimumCapacity: releases.count)
        for model in releases {
            guard let pid = model.parentReleaseID else { continue }
            childrenByParent[pid, default: []].append(model)
        }
        for model in releases {
            let derived = (childrenByParent[model.id] ?? [])
                .sorted(by: ReleaseCardModel.precedes)
                .map { $0.id }
            guard derived != model.childReleaseIDs else { continue }

            let added   = derived.filter { !model.childReleaseIDs.contains($0) }
            let removed = model.childReleaseIDs.filter { !derived.contains($0) }
            if !added.isEmpty || !removed.isEmpty {
                owner.log(
                    "WARNING: Release \(model.id) had a child list that disagreed with its " +
                    "children's own parent pointers — rebuilt from the pointers. " +
                    "Restored: \(added.map { $0.uuidString }.joined(separator: ", ")). " +
                    "Dropped: \(removed.map { $0.uuidString }.joined(separator: ", "))."
                )
            }
            model.childReleaseIDs = derived
        }

        for model in releases {
            // An upcoming release holding a market availability — written by a build that
            // kept the field while the card showed "Not-yet-released", or restored. Cleared as the
            // picker's own writes clear it (clearAvailabilityIfUpcoming).
            if model.clearAvailabilityIfUpcoming(today: CurrentDay.shared.today) {
                owner.log("WARNING: Release \(model.id) loaded upcoming with a market availability — cleared.")
                loadRepairedIDs.insert(model.id)
            }

            // Case C: base release year not strictly earlier than the release year. The two
            // Steppers cannot produce this, but a record predating the ordering rule (or one
            // written by the restore pipeline) could. Repairing inside loadExistingReleases,
            // which init() calls BEFORE captureOriginalValues(), folds the correction into the
            // change-detection baseline. The release year is the required field of the pair
            // and is held fixed; the optional base year yields.
            //
            // Orphaned base year — a stored base year with no release year to qualify — is
            // repaired BEFORE the snapshot below, so the ordering repair's log line, which is
            // phrased for a two-value conflict, cannot also fire for this one-value defect and
            // describe it incorrectly.
            if !model.hasReleaseYear && model.hasBaseReleaseYear {
                owner.log(
                    "WARNING: Release \(model.id) loaded with base release year " +
                    "\(model.baseReleaseYear) but no release year — base year cleared."
                )
                model.hasBaseReleaseYear = false
                loadRepairedIDs.insert(model.id)
            }

            let priorReleaseYear     = model.releaseYear
            let priorBaseYear        = model.baseReleaseYear
            let priorHasBaseYear     = model.hasBaseReleaseYear
            model.enforceReleaseYearOrder()
            if model.releaseYear != priorReleaseYear
                || model.baseReleaseYear != priorBaseYear
                || model.hasBaseReleaseYear != priorHasBaseYear {
                let resolution = model.hasBaseReleaseYear
                    ? "base year \(model.baseReleaseYear) / release year \(model.releaseYear)"
                    : "base year cleared (no earlier year available in range)"
                // Two distinct defects reach this branch, and naming the wrong one in the log
                // sends a future reader looking for an ordering bug that isn't there. The
                // inversion is the original case; the second is a base year correctly ordered
                // but outside purchaseYearRange, which arises when a record predates a
                // format-floor change or the film's release year has since been raised.
                let cause = priorBaseYear >= priorReleaseYear
                    ? "base release year \(priorBaseYear) at or after its release year \(priorReleaseYear)"
                    : "base release year \(priorBaseYear) below the selectable range for its " +
                      "release year \(priorReleaseYear)"
                owner.log(
                    "WARNING: Release \(model.id) loaded with \(cause) — corrected to \(resolution)."
                )
                loadRepairedIDs.insert(model.id)
            }

            // Case D: a 4K parent's combo-pack independence disagrees with how many children
            // it actually has.
            //
            // The two combo forms differ only in child count, so a record carrying one while
            // holding the other's count is internally inconsistent. Nothing in the UI can
            // produce that (reconcileComboChildren keeps them in step), but a restored backup,
            // a save interrupted between the two writes, or data predating the dual form can.
            // Left alone, the next independence change would reconcile against the stated value
            // rather than the real one, creating or destroying a card unasked.
            //
            // The CHILDREN are authoritative and the label yields: releases are user data that
            // may carry edits, whereas the independence value describes them. Runs after Case A
            // has pruned stale child IDs, so the count is of children genuinely present.
            //
            // Deliberately narrow — it only moves between the two combo values, so it cannot
            // silently retype a Standalone or Multi-pack release. A parent holding three or
            // more children has no corresponding value and is left alone with the mismatch
            // logged.
            //
            // Like Case C, this runs before captureOriginalValues(), so the correction is
            // folded into the change-detection baseline.
            if model.is4K,
               ReleaseIndependence.isComboPack(model.independence) {
                let actualChildCount = model.childReleaseIDs.count
                let statedChildCount = ReleaseIndependence.childCount(for: model.independence)
                if actualChildCount != statedChildCount {
                    if let corrected = ReleaseIndependence.value(forChildCount: actualChildCount) {
                        owner.log(
                            "WARNING: 4K release \(model.id) has independence " +
                            "\"\(model.independence)\" (implying \(statedChildCount) child " +
                            "release(s)) but \(actualChildCount) child release(s) are present " +
                            "— correcting independence to \"\(corrected)\"."
                        )
                        model.independence = corrected
                        loadRepairedIDs.insert(model.id)
                    } else {
                        owner.log(
                            "WARNING: 4K release \(model.id) has independence " +
                            "\"\(model.independence)\" but \(actualChildCount) child release(s) " +
                            "are present, which matches no combo-pack type — leaving the stored " +
                            "value in place."
                        )
                    }
                }
            }
        }

        // MARK: Case E — converge every combo-pack child's locked fields onto its parent
        //
        // Runs in its own pass because it is the only repair that reads across releases. It depends on
        // Cases A–D having settled the hierarchy and the independence label, since `comboChildren(of:)`
        // resolves through `childReleaseIDs`.
        //
        // WHY IT HAS TO HAPPEN HERE. A child's locked fields are owned by the 4K parent and pushed down by
        // `syncComboChildFields`, which runs after any field edit on a parent with children. Nothing syncs at
        // load, so a stored child that had drifted from its parent would open out of sync. The first parent
        // edit would then converge it, mutating the child after `captureOriginalValues` had recorded its
        // drifted values as the baseline. The child would stay permanently dirty, and the Update button could
        // never be disabled again.
        //
        // Converging before the baseline is taken makes the invariant true from the moment the sheet opens.
        //
        // Folded into the baseline rather than forcing a save, like the Case C/D repairs. A film opened and
        // closed untouched keeps the stored drift and is converged again next time, while any real save carries
        // the correction along. That happens only because each moved child is recorded in `loadRepairedIDs`;
        // the baseline comparison alone would never write it.
        //
        // The parent test is `handleChange`'s verbatim, so the set converged here is exactly the set the first
        // edit would have converged. Anything narrower leaves a parent whose first edit still moves its child
        // off the baseline.
        //
        // Logged per child that actually moved, since a silent rewrite of user data at load is hard to notice.
        // Snapshots are taken only for combo children.
        for parent in releases
        where parent.is4K && !parent.isComboChild && !parent.childReleaseIDs.isEmpty {
            let children = comboChildren(of: parent)
            let before = children.map { $0.snapshot() }
            syncComboChildFields(from: parent)
            for (child, priorState) in zip(children, before) {
                let moved = child.snapshot().differingFields(from: priorState)
                guard !moved.isEmpty else { continue }
                owner.log(
                    "WARNING: Combo-pack child \(child.id) loaded out of sync with its 4K " +
                    "parent \(parent.id) — converged: \(moved.joined(separator: ", "))."
                )
                loadRepairedIDs.insert(child.id)
            }
        }

        // MARK: Cache rebuild after the repairs
        //
        // REQUIRED, not belt-and-braces. `carouselEntries` is built in `releases.didSet`, which
        // ran at the `releases = sortedReleases.map { … }` assignment above — BEFORE every
        // repair in this method. The repairs then rewrite `parentReleaseID` and
        // `childReleaseIDs` IN PLACE, and mutating a model does not touch the array.
        //
        // The repair this most matters for is the one that restores a parent's
        // `childReleaseIDs` when the inverse relationship came back empty: without this
        // call the carousel would keep the pre-repair grouping for the life of the sheet.
        updateCarouselCache()

        owner.log("Loaded \(releases.count) existing releases")
    }

    // Capture original state after loading.
    private func captureOriginalValues() {
        originalIDs = releases.map { $0.id }
        var byID = [UUID: ReleaseCardState](minimumCapacity: releases.count)
        for model in releases { byID[model.id] = model.snapshot() }
        originalReleasesByID = byID
        // The diagnostic is a statement about a specific baseline; a new baseline makes any
        // suppressed repeat stale, so the next dirty check starts from a clean slate.
        lastDirtyDiagnostic = [:]
    }

    // MARK: - Change Tracking

    /// Brings `changeObservers` into agreement with `releases`: arms an observer for every
    /// model that lacks one, cancels and drops those whose models are gone. Called from
    /// `releases.didSet`, the only place a model can enter or leave the session, so an observed
    /// model is exactly a live model by construction.
    private func reconcileChangeObservers() {
        let liveIDs = Set(releases.map(\.id))

        // Stale keys are collected before any removal rather than removed inside the loop.
        // Dictionary is a value type, so mutating during iteration is defined behavior via
        // copy-on-write — but it means the loop silently walks a stale copy, which is the
        // kind of subtlety that survives until someone edits it. Two passes, no subtlety.
        let staleIDs = changeObservers.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            changeObservers.removeValue(forKey: id)?.cancel()
        }

        for model in releases where changeObservers[model.id] == nil {
            changeObservers[model.id] = ReleaseChangeObserver(model: model, viewModel: self)
        }
    }

    /// Re-reads every observer's baseline hash from its model, so the state the models are in
    /// right now counts as "unchanged".
    ///
    /// MARK: Why this exists rather than an isLoadingData check
    /// loadExistingReleases assigns `releases` first — arming an observer per model — then
    /// normalizes and repairs those models in place, and each of those writes signals its
    /// observer. The reaction is deferred by one main-actor turn while loadExistingReleases is
    /// synchronous, so by the time any reaction runs the load has returned and isLoadingData is
    /// false again: a flag check inside the observer is dead code.
    ///
    /// Left unhandled, those queued reactions would run syncComboChildFields over every freshly
    /// loaded 4K parent right after the sheet opens. captureOriginalValues has already run by
    /// then, so any field that moved is a genuine difference from the baseline — the sheet
    /// would open with "Update" enabled and no user edit behind it.
    ///
    /// Advancing the baselines neutralizes all of them at once without knowing how many are
    /// queued: each reaction compares the model's CURRENT hash against lastHash when it runs,
    /// so once the baselines match the models every pending reaction no-ops, and each still
    /// re-arms on its way out.
    ///
    /// This depends on running synchronously before those reactions get a turn. If loading ever
    /// becomes asynchronous, this call has to move to where the load's last write lands.
    private func rebaselineChangeObservers() {
        for observer in changeObservers.values { observer.rebaseline() }
    }

    /// Debounced check for field edits — 150 ms coalesces rapid keystrokes into one
    /// comparison. Called by ReleaseChangeObserver.
    func scheduleChangeCheckDebounced() { scheduleChangeCheck(debounce: .milliseconds(150)) }

    /// Change check for structural mutations (add, delete, reorder).
    ///
    /// The Task hop is intentional, mirroring FilmSheet.notifyChanges: callers are @MainActor
    /// but mid-body-evaluation, so deferring the hasChanges / owner.notifyChanges writes to the
    /// next run-loop turn avoids cascading @Observable invalidations mid-render. Held in a
    /// TaskHandle so a rapid second mutation cancels a pending check.
    ///
    /// Both paths wait out the animation window: a structural mutation starts an animation on
    /// the same tick it schedules this, and a debounce armed by a field edit can otherwise fire
    /// inside a navigation spring started in the meantime.
    func scheduleChangeCheck(debounce: Duration? = nil) {
        changeCheckTask = TaskHandle(Task { @MainActor [weak self] in
            if let debounce { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled, let self else { return }
            await self.waitForAnimationQuiescence()
            guard !Task.isCancelled else { return }
            self.checkForChanges()
        })
    }

    private func checkForChanges() {
        // No isLoadingData guard: checkForChanges() is only ever reached through
        // scheduleChangeCheck's Task hop, which runs at least one run-loop turn after
        // loadExistingReleases (synchronous) has already reset the flag to false — see
        // rebaselineChangeObservers' "Why this exists rather than an isLoadingData check".
        guard let owner = owner, owner.isEditMode else {
            // Only write — and therefore only emit an @Observable invalidation —
            // when the value actually needs to change. All tab checkForChanges()
            // methods share this pattern.
            if hasChanges { hasChanges = false }
            return
        }

        // Structural change: different count or different IDs.
        let currentIDs = releases.map { $0.id }
        let changed: Bool
        if currentIDs != originalIDs {
            changed = true
        } else {
            // Field-level change: one snapshot compared against the baseline, through ReleaseCardState's
            // synthesized `==`. `buildReleaseDeltas` uses the same comparison, so the Update button and the
            // save path cannot disagree about the same card.
            changed = releases.contains { model in
                guard let original = originalReleasesByID[model.id] else { return true }
                return model.snapshot() != original
            }
        }

        // MARK: Diagnostic — why the tab is dirty
        //
        // Evaluated on every check that resolves dirty, not just on the transition, and then emitted only
        // when the resulting text differs from the last one emitted. The state that needs explaining is the
        // one a transition log cannot see: a check that finds the tab still dirty after the user believes they
        // have reverted everything. Exact repeats are suppressed; see the note at the emit site.
        //
        // The isLoggingEnabled guard is on the BLOCK, not left to log(): `Loggable.log` returns
        // early when logging is off, but its parameter is an ordinary String rather than an
        // @autoclosure, so everything needed to build it is evaluated at the call site
        // regardless. That is not trivial here — the loop pays a SECOND `snapshot()` per
        // release on top of the one `contains` already took, then runs `differingFields`, which
        // performs 39 generic comparisons and allocates a [String]. This path runs on the
        // 150 ms debounce tick for as long as the tab is dirty and the user keeps typing.
        if !changed {
            // Clean again — the next dirty state is news even if it repeats an earlier one.
            lastDirtyDiagnostic = [:]
        } else if Logger.isLoggingEnabled {
            // (key, signature, line): the signature is what repeat-suppression compares.
            var entries: [(key: String, signature: String, line: String)] = []
            if currentIDs != originalIDs {
                let line = "structural: current \(currentIDs.count) id(s) vs original \(originalIDs.count)"
                entries.append(("structural", line, line))
            } else {
                for model in releases {
                    let key = model.id.uuidString
                    guard let original = originalReleasesByID[model.id] else {
                        let line = "release \(model.id) has no baseline entry"
                        entries.append((key, line, line))
                        continue
                    }
                    let diffs = model.snapshot().differingFields(from: original)
                    if !diffs.isEmpty {
                        // Field names carry no spaces; the value suffix starts at the first one.
                        let names = diffs.map { String($0.prefix { $0 != " " }) }
                        entries.append((key, names.joined(separator: ","),
                                        "release \(model.id): \(diffs.joined(separator: ", "))"))
                    }
                }
            }

            // Emit only when the diagnostic actually says something new.
            //
            // The block above runs on every dirty tick, deliberately: what is suppressed is a repeated line,
            // not a repeated check, and the only way to know a line repeats is to build it. The worst case
            // is a structurally dirty tab, where the message is two counts that cannot change until the user
            // adds or removes a release.
            //
            // The field-level branch is why the whole diagnostic is not gated on the dirty transition. It names
            // which fields differ, and that changes from tick to tick as the user edits. Comparing the assembled
            // text keeps those lines distinct and collapses only exact repeats. A tab still dirty after the user
            // believes they reverted everything is recorded the first time it is seen, and again if it recurs
            // after a clean tick.
            //
            // Suppression is per release and on field names, not on the whole assembled text. Comparing the whole
            // text re-emitted every dirty release whenever any one changed, and comparing values made each edit
            // its own line. A release is reported when it first becomes dirty, and again only when the set of
            // differing fields changes. The line still shows the values as of that moment.
            var next: [String: String] = [:]
            for entry in entries {
                next[entry.key] = entry.signature
                if lastDirtyDiagnostic[entry.key] != entry.signature {
                    owner.log("Releases dirty — \(entry.line)")
                }
            }
            lastDirtyDiagnostic = next
        }

        // Only write hasChanges — and only call owner.notifyChanges() — when the
        // aggregated result actually differs from the last known value. Skipping
        // the no-op path keeps the 150ms debounce tick from waking FilmSheet on
        // every keystroke once hasChanges has already latched to true.
        if hasChanges != changed {
            hasChanges = changed
            owner.notifyChanges()
        }
    }

    // MARK: - Cache Maintenance

    private func updateCarouselCache() {
        // Sorted ONCE. The display numbers are derived from the entries themselves, so the
        // numbering and the card order cannot disagree.
        let entries = buildCarouselEntries(from: unifiedReleaseOrder)
        carouselEntries = entries
        displayNumbers  = buildDisplayNumbers(for: entries)
    }

    // MARK: - Unified Ordering

    /// Every release in the film, ordered as the carousel presents them: all 4K releases, then
    /// all Blu-rays, then all DVDs, each group in `sortOrder`.
    ///
    /// The insertion rule the design calls for — a new 4K lands at the end of the 4K run and
    /// ahead of the first Blu-ray — is not implemented anywhere; it FALLS OUT of this
    /// comparator. `nextSortOrder` is a film-wide monotonic maximum, so a new release always
    /// sorts last within its own format while the format rank keeps it ahead of every format
    /// below. There is no renumbering step and no insertion index, which is why adding a
    /// release cannot disturb the position of any existing one.
    ///
    /// Within a format the order is `ReleaseCardModel.precedes` — the same total order every
    /// other consumer uses; see there for why the id tiebreak is load-bearing.
    ///
    /// `carouselRank` is computed once per release rather than inside the comparator. It is a string match
    /// plus a rank lookup, and a comparator would repeat it O(n log n) times to answer a question with only
    /// n distinct answers.
    private var unifiedReleaseOrder: [ReleaseCardModel] {
        releases
            .map { (rank: $0.carouselRank, model: $0) }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return ReleaseCardModel.precedes(lhs.model, rhs.model)
            }
            .map(\.model)
    }

    /// The carousel's CARDS: a combo-pack child is removed from the top level and folded into
    /// its parent's entry, so a 4K release bundled with a Blu-ray produces one card, not two.
    ///
    /// MARK: Every release appears on exactly one card
    ///
    /// This is the invariant the whole tab rests on, and it is why absorption is decided ONCE
    /// here and the absorbed models are carried straight into the entry rather than re-derived
    /// per parent by `comboChildren(of:)`. Two derivations of "who are this parent's children"
    /// that could disagree would show a release twice — once as a variant, once as a card of
    /// its own — or lose it entirely.
    ///
    /// A pairing is honored only when all three hold, and each rules out a specific way
    /// malformed data could break the invariant:
    ///
    ///   • the child is present in this session — a `childReleaseID` naming an absent release
    ///     has nothing to absorb;
    ///   • the child names this parent back — a one-sided claim would hide a release inside a
    ///     card that will not render it, since the variant list and the absorbed set would be
    ///     built from different sides of the relationship;
    ///   • the parent is itself top-level — without this, a two-release cycle (each naming the
    ///     other as both parent and child) would absorb BOTH and leave the carousel empty while
    ///     `releases` was not.
    ///
    /// Together they make `carouselEntries.isEmpty` equivalent to `releases.isEmpty`.
    ///
    /// An orphaned child — one whose `parentReleaseID` names a release not in this session — is
    /// therefore promoted back to a top-level card rather than dropped. `loadExistingReleases`
    /// repairs this at load time, so this covers only the window before the next reload;
    /// dropping such a child would make a real, persisted release invisible and un-deletable.
    private func buildCarouselEntries(from ordered: [ReleaseCardModel]) -> [ReleaseCarouselEntry] {
        var byID = [UUID: ReleaseCardModel](minimumCapacity: ordered.count)
        for model in ordered { byID[model.id] = model }

        var absorbed = Set<UUID>()
        var childrenByParent = [UUID: [ReleaseCardModel]]()
        for parent in ordered
        where parent.parentReleaseID == nil && !parent.childReleaseIDs.isEmpty {
            for childID in parent.childReleaseIDs {
                guard let child = byID[childID],
                      child.parentReleaseID == parent.id,
                      absorbed.insert(childID).inserted else { continue }
                childrenByParent[parent.id, default: []].append(child)
            }
        }

        return ordered.compactMap { model in
            if absorbed.contains(model.id) { return nil }
            // The segment order on the card must agree with the order the delete and
            // type-change alerts name the same discs in, and `childReleaseIDs`' own element
            // order is not authoritative (it comes from a Core Data to-many relationship,
            // whose element order is unspecified). See ReleaseCardModel.precedes.
            let children = (childrenByParent[model.id] ?? []).sorted(by: ReleaseCardModel.precedes)
            return ReleaseCarouselEntry(parent: model, children: children)
        }
    }

    // MARK: - Per-format Display Numbering
    //
    // The number a card shows in its header ("Release 3"). Per-FORMAT, not per-carousel:
    // numbering straight through the unified stack would label the first DVD on a well-stocked
    // film "Release 14", which is meaningless and inconsistent with every other surface.
    //
    // Numbers CARDS, in carousel order. Bundled combo-pack discs are segments of their 4K
    // card and carry no number of their own — nothing reads one (both readers look up
    // `entry.parent.id`) — so they are not numbered, which keeps the visible run gap-free.
    //
    // Returns a map rather than a per-call search, so the carousel computes it once per
    // structural change instead of once per card.
    private func buildDisplayNumbers(for entries: [ReleaseCarouselEntry]) -> [UUID: Int] {
        var nextByFormat: [String: Int] = [:]
        var result = [UUID: Int](minimumCapacity: entries.count)
        for entry in entries {
            let number = nextByFormat[entry.parent.format, default: 0] + 1
            nextByFormat[entry.parent.format] = number
            result[entry.parent.id] = number
        }
        return result
    }

    // MARK: - Carousel Navigation

    /// Index of the visible card, clamped to the cards that exist.
    ///
    /// Reads through a clamp rather than trusting the stored value so a structural change
    /// that shortens the stack can never leave the carousel addressing a card that is gone
    /// — the fallback lands on the same pass that observes the shorter array.
    var currentCardIndex: Int {
        min(max(currentIndex, 0), max(0, carouselEntries.count - 1))
    }

    // MARK: - Release Cap
    //
    // Ten CARDS across every format together, not ten per format. A combo pack is one card
    // however many discs it bundles.
    //
    // Combo-pack children are created automatically when a 4K parent's independence is
    // configured, and that path is deliberately NOT gated on this cap: refusing there would
    // leave a parent with missing children, which is worse than exceeding the cap. A child adds no card
    // of its own, so creating one cannot exceed the cap.
    /// `nonisolated` because its readers are not all on the main actor:
    /// ReleasesFormatting.releaseCapHelpText spells this number into the cap help text from a
    /// nonisolated static initializer.
    nonisolated static let maxReleases = 10

    // MARK: - Swipe navigation
    //
    // A two-finger swipe is a DISCRETE navigation event, identical to an arrow button or key.
    // Once the gesture locks in as horizontal and passes
    // `FSTabReleasesView.discreteSwipeThreshold`, one nextCard()/previousCard() runs and the
    // rest of the gesture is ignored.
    //
    // A discrete step rather than a live drag. A drag that tracked the fingers 1:1 could not be kept
    // consistently responsive, and an inconsistent direct-manipulation gesture reads as unresponsive
    // rather than deliberate.

    /// Whether another release may be added.
    ///
    /// The single source of truth for the cap. Every gate — the Add menu, the Cmd+N path, the
    /// uiCommands route, and addRelease() itself — asks this rather than comparing counts
    /// against a literal, so the cap cannot be enforced inconsistently across the four.
    ///
    func canAddRelease() -> Bool {
        carouselEntries.count < Self.maxReleases
    }

    // MARK: - Navigation Serialization
    //
    // Carousel navigation is a SERIAL pipeline: one step at a time, each owning the full
    // duration of its spring. Input arriving mid-step does not move the index; it is remembered
    // in a one-deep slot and taken up once the step completes. See requestNavigation.
    //
    // WHY. Input that writes `currentIndex` the instant it arrives retargets a spring that is still
    // running. SwiftUI re-aims a running spring rather than queueing, so the visible travel per step
    // shrinks as input rate rises. Held arrow-key repeat (~30/s against the navigation spring) collapses
    // the animation: cards change with no travel, and once the index outruns the mounted window the carousel
    // shows a blank followed by a card arriving late.
    //
    // Serializing removes the ability to accelerate — a card always animates in, settles, and
    // animates out exactly as under slow navigation, because the input no longer reaches the
    // index.
    //
    // On the view model rather than in the view because all three input paths already funnel
    // through nextCard() / previousCard(), so this covers them by construction.
    //
    // It also makes the mount window's guarantee cheap: the index can move at most one step per
    // completed animation, so the next visible window is always inside the current prefetch
    // ring.

    /// The carousel's navigation spring. Declared here rather than inline at the
    /// `.animation` call site so that the animation and the lock that protects it are
    /// derived from ONE value and cannot drift apart. ReleasesView applies it via
    /// `.animation(.spring(FSTabReleases.navigationSpring), value: idx)`.
    ///
    /// MARK: Why `response` is the responsiveness knob, and `dampingRatio` is not
    ///
    /// Perceived input latency in this carousel comes from the spring's soft start, not from scheduling.
    /// A spring leaves rest with zero velocity, so its opening frames cover little ground. Lowering
    /// `response` moves more of each step into those early frames, which reads as immediate rather than
    /// delayed.
    ///
    /// `dampingRatio` is held at 0.85 on purpose. Peak overshoot is set by damping alone and does not
    /// change with `response`, so the response can be lowered without changing the bounce. Lowering
    /// damping to buy the same early travel would substantially increase the overshoot, which is the
    /// visual character this carousel was tuned away from.
    ///
    /// `navigationStepDuration` (the back-to-back lock) and `addFadeDelay` both derive from the spring, so
    /// they follow any change to `response` and `dampingRatio`.
    static let navigationSpring = Spring(response: 0.28, dampingRatio: 0.85)

    /// Safety margin added to the spring's own settling estimate.
    ///
    /// `settlingDuration` is the time to converge within an epsilon, not a guarantee that the
    /// animation has been torn down. A step beginning at exactly that instant can still meet an
    /// attached, barely-moving spring, and SwiftUI retargets it rather than starting fresh —
    /// carrying the old velocity into the new step and collapsing it.
    ///
    /// 70 ms is several frames past the settling estimate, and is only ever paid between steps,
    /// never inside one. It is the one part of a step's duration that is pure insurance rather
    /// than visible motion, so it is where back-to-back navigation can be made more responsive
    /// without shortening the spring.
    ///
    /// The margin can be shortened, but that changes the invariant rather than tuning a knob. The motion
    /// is finished well before the lock releases at `navigationStepDuration`, so the margin is where the
    /// lock could be made more responsive. Releasing before `settlingDuration` would let a queued step
    /// retarget an animation SwiftUI has not yet torn down, which is what this margin exists to prevent.
    /// Any change here should be made deliberately and watched for travel collapse.
    private static let navigationSettleMargin: Duration = .milliseconds(70)

    /// How long one navigation step owns the pipeline, end to end.
    static let navigationStepDuration: Duration =
        .seconds(navigationSpring.settlingDuration) + navigationSettleMargin

    /// How long `addRelease`'s travel waits before the new card starts fading into the slot it
    /// just slid open.
    ///
    /// Keyed to the spring's RESPONSE, not to `navigationStepDuration`. `settlingDuration` is
    /// where the spring converges within an epsilon — well past the last frame in which
    /// anything is visibly moving — and the margin on top is insurance against a FOLLOWING step
    /// retargeting a live spring. Neither says anything about when the motion LOOKS finished,
    /// and waiting for both put a dead beat between the slide and the fade.
    ///
    /// `response` is the spring's perceptual duration. Taken at 0.9 of it so the fade's first
    /// frames overlap the slide's last, barely-moving ones and the sequence reads as one
    /// gesture. The overrides' teardown still waits out the FULL `navigationStepDuration` —
    /// unmounting is structural work and has no business in the spring's tail.
    static let addFadeDelay: Duration = .seconds(navigationSpring.response * 0.9)

    /// True while a step owns the pipeline. `@ObservationIgnored` deliberately: no view
    /// reads it, and making it observable would invalidate every observer of this view
    /// model twice per step for state that is purely internal bookkeeping.
    @ObservationIgnored private var isNavigationLocked = false

    /// Handle for the in-flight step, so teardown cancels it.
    @ObservationIgnored private var navigationStepTask: TaskHandle?

    /// The ONE step remembered from input that arrived while the pipeline was busy, as its
    /// direction (-1 / +1), or nil.
    ///
    /// Depth of exactly one, by design: four presses during one animation remember one further
    /// step, and the last direction pressed wins. See requestNavigation.
    @ObservationIgnored private var queuedNavigationStep: Int?

    /// The index the mount window must center on, when it has to lead the current index.
    ///
    /// Exists so that mounting and animating never share an update pass. See
    /// beginNavigationStep for the sequence; FSTabReleasesView centers its window on this
    /// when set, and on the current index otherwise.
    private(set) var mountWindowTarget: Int? = nil

    /// A SECOND index the mount window must also cover, alongside `mountWindowTarget`.
    ///
    /// Set on every move, short or long.
    ///
    /// The long case is the obvious one: traveling to card 9 from card 0 would point the window
    /// at {8,9} and unmount card 0 — the card the user is still looking at, and the one the
    /// sweep is supposed to depart FROM — for the turn between the mount pass and the index
    /// change.
    ///
    /// The short case has the same problem one card over. Windows around origin and
    /// destination do overlap for a ±1 step, but a window is a RANGE: centering it on the
    /// destination drops its trailing end, which is the card at distance 1 behind the user —
    /// visible, dimmed, and a sliver of it on screen. See the note at the assignment in
    /// `beginNavigationMove`.
    ///
    /// The cost is one additional mounted card for the duration of a move only. Phase C drops
    /// it while the carousel is at rest and the card in question has reached distance 2, where
    /// `cardOpacity` is 0.
    private(set) var mountWindowSecondary: Int? = nil

    // MARK: - Mount-window ownership
    //
    // The two overrides above have more than one writer: a navigation move and `addRelease`'s auto-scroll
    // both set and clear them. An unconditional clear lets one writer tear down a window it no longer owns,
    // unmounting a card that is still on screen. Two cases this prevents:
    //
    //   1. An add's teardown landing inside a later navigation. `isTransitioning` gates navigation input and
    //      falls with `addingCardID` at `addFadeDelay`, while the add holds the overrides until
    //      `navigationStepDuration`. In that gap a step or jump can be accepted, and the add's teardown then
    //      clears the window it set up.
    //
    //   2. A canceled navigation's release path landing inside a later add. `addRelease` calls
    //      `cancelNavigation()` and then claims the window, and the abandoned step's cancellation branch must
    //      not clear the add's overrides.
    //
    // A claim token supplies an owner. A writer takes a token before setting the overrides and presents it to
    // release them, and a release whose token has been superseded is a no-op. Every claim is total (there is
    // exactly one window), so this is a hand-off, not a lock: a later claimant always wins, so the newest
    // intent governs the carousel.
    //
    // `@ObservationIgnored` for the same reason as `isNavigationLocked`: internal bookkeeping
    // that no body reads, and making it observable would invalidate every observer of this view
    // model on each claim.
    @ObservationIgnored private var mountWindowClaim: Int = 0

    /// Takes ownership of the mount-window overrides, returning the token required to release
    /// them. Supersedes any outstanding claim.
    private func claimMountWindow() -> Int {
        mountWindowClaim &+= 1
        return mountWindowClaim
    }

    /// Clears the overrides, but only if `token` is still the live claim. A superseded token
    /// means another path has since taken the window and is responsible for tearing it down.
    private func releaseMountWindow(token: Int) {
        guard mountWindowClaim == token else { return }
        mountWindowTarget = nil
        mountWindowSecondary = nil
    }

    /// Clears the overrides unconditionally AND retires the outstanding claim, so the writer
    /// that set them cannot re-clear a window some later path has taken in the meantime.
    ///
    /// For abandonment paths only — a contents change, or teardown — where the window must go
    /// now and no successor has claimed it yet.
    private func abandonMountWindow() {
        mountWindowClaim &+= 1
        mountWindowTarget = nil
        mountWindowSecondary = nil
    }

    // MARK: Animation key
    //
    // The card stack's spring is keyed to this token rather than to `idx`, so that moving the
    // index and ANIMATING the move are separable. Keyed to idx, every index change fired the
    // spring — including the ones that must not: `addRelease` corrects the displayed index
    // across the array's growth before traveling anywhere, and `openOnFirstCard` seeds the
    // deep-link position before the first render. Both write `currentIndex` without bumping
    // this, and so are silent by construction.
    //
    // Jumps travel like any other move, so they bump this token. Only index writes that are not moves stay silent.
    private(set) var keyboardNavigationToken: Int = 0

    func previousCard() { requestNavigation(step: -1) }

    func nextCard() { requestNavigation(step: +1) }

    /// Travels to `target`, the entry point for the header's card-selection menu.
    ///
    /// The carousel SWEEPS to the destination rather than cutting to it — the same spring, over
    /// the same strip, that an arrow step and `addRelease`'s auto-scroll use. The distance is
    /// the only difference, and it is the point: the sweep shows how far away the card is, which an
    /// instant swap cannot show.
    ///
    /// Deliberately NOT routed through the remembered-step slot: that slot stores a DIRECTION,
    /// which is all a keypress means, while a menu selection names an absolute position — and
    /// remembering a jump across a running animation would be wrong anyway, since by the time
    /// the pipeline frees up the user has moved on. A jump requested while busy is declined,
    /// exactly as the menu's own `disabled` state already says.
    func jumpToCard(_ target: Int) {
        guard !isTransitioning, !isNavigationLocked else { return }
        beginNavigationMove(to: target)
    }

    /// Positions the carousel on the first card of `format`, for the deep-link path.
    ///
    /// Writes `currentIndex` directly — no lock, no mount phase, no animation — because the
    /// destination is where the tab is OPENING rather than somewhere it travels to. That is
    /// only true if it runs before the first render, which is why SheetHostView calls it on the
    /// freshly constructed FilmSheet rather than the carousel consuming a stored format in
    /// `onAppear`: `onAppear` fires AFTER the first body pass, so the tab would render card 0
    /// and then jump.
    ///
    /// A no-op when no card carries the format.
    func openOnFirstCard(ofFormat format: String) {
        guard let index = resolveFirstCard(ofFormat: format) else { return }
        currentIndex = index
    }

    /// The live-carousel counterpart to `openOnFirstCard(ofFormat:)`, for a tab already on
    /// screen.
    ///
    /// Same destination, different means of arriving. A direct `currentIndex` write is only
    /// correct before the first render; once mounted it would cut to the destination without
    /// the mount discipline and could land against a running spring. So this routes through
    /// `jumpToCard`, which declines while the carousel is busy and otherwise runs the full
    /// mount-then-move sequence.
    ///
    /// The variant selection is applied either way, not gated on the jump being accepted: it is
    /// state the card reads when it next renders.
    func revealFirstCard(ofFormat format: String) {
        guard let index = resolveFirstCard(ofFormat: format) else { return }
        jumpToCard(index)
    }

    /// Resolves the card index for `format`, applying the variant selection when the format is
    /// only present as a bundled disc. Shared by the two entry points above so "the first card
    /// of this format" means one thing either way. The variant write belongs here because it is
    /// part of resolving WHICH release is being addressed, not of how the carousel gets there.
    private func resolveFirstCard(ofFormat format: String) -> Int? {
        // A card whose own release is of this format is the better answer, so it is tried
        // first: on a film holding a 4K combo pack and a standalone Blu-ray, asking for
        // Blu-ray should land on the standalone card rather than on the 4K pack that merely
        // bundles one.
        if let index = carouselEntries.firstIndex(where: { $0.parent.format == format }) {
            return index
        }
        // Otherwise the format may still be present as a bundled disc — a film whose only
        // Blu-ray came inside a combo pack. Land on that card and open it on the disc the
        // user asked for, since showing the 4K master would answer a question they did not
        // ask.
        guard let index = carouselEntries.firstIndex(where: {
            $0.variantIndex(ofFormat: format) != nil
        }) else { return nil }
        let entry = carouselEntries[index]
        if let variant = entry.variantIndex(ofFormat: format) {
            selectedVariantByCard[entry.id] = variant
        }
        return index
    }

    /// Entry point for all navigation input.
    ///
    /// Input arriving while a step is running does not move the index, but is not thrown away
    /// either: it sets a single one-deep slot that the pipeline consumes once the running step
    /// has fully completed. Four presses during one animation therefore advance twice — the
    /// step already running, plus one more.
    ///
    /// WHY REMEMBER AT ALL. Discarding input is correct for the animation but wrong for the user: the first
    /// press often lands during the step it just started, so the input would vanish with no acknowledgment
    /// and the carousel would read as unresponsive.
    ///
    /// WHY THE REMEMBERED STEP IS NOT FIRED AT RELEASE. Firing from the release path, the instant the lock
    /// drops, would retarget a spring that is still attached and inherit its velocity. Instead:
    ///
    ///   * Depth one, permanently. The slot is overwritten, never appended to, so N inputs buy one extra
    ///     step. Input rate can decide whether the next step happens, never how fast any step runs.
    ///   * The flush happens after the lock is released and the settle margin has elapsed, and the new step
    ///     runs the full mount/animate/settle sequence from the top. A flushed step is structurally
    ///     indistinguishable from fresh input against an idle carousel.
    private func requestNavigation(step: Int) {
        // Add and delete own the carousel for the duration of their own animations, and
        // they change what the carousel CONTAINS. A step remembered across one would be
        // aimed at a card layout that no longer exists, so this path still discards.
        guard !isTransitioning else { return }

        // The remember. This single line is the whole input policy.
        guard !isNavigationLocked else { queuedNavigationStep = step; return }

        beginNavigationStep(step)
    }

    /// Consumes the remembered step, if there is one. Called only from a released, idle
    /// pipeline. Clearing the slot BEFORE beginning the step is what bounds this to one extra
    /// step rather than a self-sustaining loop: anything the user presses during the new step
    /// writes a fresh slot, so each flush is paid for by new input.
    private func flushQueuedNavigation() {
        guard let step = queuedNavigationStep else { return }
        queuedNavigationStep = nil
        // Re-check the gates rather than trusting the caller: the carousel may have been
        // claimed by an add, a delete, or a new gesture between the release and here.
        requestNavigation(step: step)
    }

    /// Runs one step: mount, then animate, then settle. The lock is held across all three.
    ///
    /// MOUNTING AND ANIMATING ARE SEPARATE PASSES. A step both shifts the mount window and moves the index.
    /// Doing both in one pass would start each spring on a turn that is also building and tearing down card
    /// subtrees, so the spring's first frames would compete with that structural work and its timing would
    /// vary with whatever that work cost.
    ///
    ///   Phase A — point the window at the target. Cards mount and unmount, all at distance >= 2
    ///             and therefore off-screen and clipped. The index does not move.
    ///   Phase B — one run-loop turn later, move the index. Offsets and opacities only; nothing
    ///             structural. The spring runs alone.
    ///   Phase C — hold the lock until the spring has fully settled, then release.
    ///
    /// Input is discarded throughout all three, so no phase can be re-entered.
    private func beginNavigationStep(_ step: Int) {
        beginNavigationMove(to: currentCardIndex + step)
    }

    /// Runs one navigation move, under the three-phase discipline documented above.
    ///
    /// MARK: Every move the user asks for is traveled
    ///
    /// Arrows, swipes, the jump menu, and `addRelease`'s auto-scroll all run this same spring
    /// over the same strip. A jump is a longer move, not a different kind of move.
    ///
    /// A jump is traveled rather than cut to. An instant swap leaves no evidence of where the user went,
    /// while a sweep shows how far the destination is.
    ///
    /// There is no `animated` parameter: every move is traveled, so a branch for an instant move would be
    /// dead code. Silent index writes are not moves and never come through here. `addRelease` corrects the
    /// index across an insertion by assigning `currentIndex` directly, and `openOnFirstCard` seeds it before
    /// the first render.
    ///
    /// The mount discipline is unchanged and is what makes the long travel safe: Phase A covers
    /// both origin and destination (see `mountWindowSecondary`), so the card being left does
    /// not blank out as the window jumps ahead of it.
    private func beginNavigationMove(to target: Int) {
        let idx = currentCardIndex

        // Nothing to do at a boundary, or when the target is already on screen, so the
        // lock is never taken.
        guard target >= 0, target < carouselEntries.count, target != idx else { return }

        isNavigationLocked = true

        // Taken before the task is armed, so the claim is established on this tick rather than
        // one turn later — an add sequence starting in between must supersede this move, not
        // find an unowned window. See the mount-window ownership note.
        let windowToken = claimMountWindow()

        navigationStepTask = TaskHandle(Task { @MainActor [weak self] in
            guard let self else { return }

            // Phase A — mount ahead. Structural, silent, un-animated.
            self.mountWindowTarget = target
            // The origin is held for EVERY move, including a ±1 step. The window is a range, so pointing it
            // at the destination alone drops the far end. Stepping idx -> idx+1 at radius 1 would unmount card
            // idx-1 while it is still visible at distance 1 (opacity 0.5) and the strip is at rest. Holding the
            // origin makes the union idx-1...idx+2 during the move. The card at idx-1 is then unmounted when
            // Phase C releases the window, by which point it is at distance 2, where cardOpacity is exactly 0.
            //
            // Phase A is also the last turn before the spring starts. Keeping the teardown of ~50 controls out of
            // it keeps variable-cost work out of the animation's first frames.
            //
            // The secondary is set unconditionally rather than re-derived from the radius. A redundant secondary is
            // a window that already overlaps, which costs nothing, whereas a conditional form has to restate the
            // mount window's geometry.
            self.mountWindowSecondary = idx
            await Self.nextRunLoopTurn()
            guard !Task.isCancelled else {
                self.releaseNavigationLock(mountWindowToken: windowToken); return
            }

            // Phase B — the index change, over a structurally static tree.
            //
            // Deferred change checks are held across it: a pending debounced check snapshots
            // every release and can cascade into a FilmSheet footer re-render, which inside the
            // spring's low-amplitude tail reads as a jerk.
            self.markAnimationWindow(Self.navigationStepDuration)
            // Bumped in the same pass as the index change: this is what opts this path
            // into the spring. See the Animation keys note above.
            self.keyboardNavigationToken &+= 1
            self.currentIndex = target

            // Phase C — settle.
            try? await Task.sleep(for: Self.navigationStepDuration)
            guard !Task.isCancelled else {
                self.releaseNavigationLock(mountWindowToken: windowToken); return
            }

            // The primary override is centered on the target, which is now the current
            // index, so dropping it changes nothing about which cards are mounted; the
            // secondary is what actually unmounts the card a long move left behind, and it
            // does so here, at rest.
            //
            // Token-scoped: an add sequence that claimed the window while this step's spring
            // was settling owns it now, and tearing it down here would unmount the card the
            // add is sliding away from.
            self.releaseMountWindow(token: windowToken)
            self.isNavigationLocked = false

            // Last, and only once genuinely idle: lock down, window cleared, settle margin
            // already spent. A step taken from here starts against a torn-down spring and a
            // static tree, exactly as a freshly typed one would.
            self.flushQueuedNavigation()
        })
    }

    /// Yields exactly one run-loop turn.
    ///
    /// `Task.yield()` will not do: it is a cooperative yield within the actor and does not
    /// give SwiftUI a chance to complete a render pass, which is the entire purpose here.
    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Unlocks WITHOUT flushing, and drops anything remembered. Every caller is an abandonment
    /// path (cancellation, teardown, a contents change), and on all of them the remembered step
    /// is aimed at a layout the pipeline is no longer running against.
    ///
    /// `mountWindowToken` names the claim the CALLER holds, when it holds one: an in-flight
    /// step's own cancellation branches pass theirs, so a step abandoned in favor of an add
    /// releases the lock without touching a window the add has since claimed. Omitting it
    /// abandons the window outright, which is right for a caller that is not a claimant —
    /// `cancelNavigation`, reacting to a contents change that invalidates every window.
    private func releaseNavigationLock(mountWindowToken token: Int? = nil) {
        if let token {
            releaseMountWindow(token: token)
        } else {
            abandonMountWindow()
        }
        isNavigationLocked = false
        queuedNavigationStep = nil
    }

    /// Abandons any in-flight step and unlocks. Called when the carousel's contents change
    /// out from under the pipeline (format switch, add, delete), where the step's target
    /// index refers to a card layout that no longer exists.
    func cancelNavigation() {
        navigationStepTask = nil
        releaseNavigationLock()
    }

    // MARK: - Neighbor dimming
    //
    // A card's opacity as a linear ramp on its DISTANCE from the center in card steps, passing
    // through 1.0 at 0, 0.5 at 1, and 0 at 2. A function of distance rather than of index so
    // the navigation spring interpolates opacity along with position instead of stepping it at
    // the moment the index commits.

    /// Opacity lost per card step of distance from the center. 0.5 puts an immediate
    /// neighbor at half opacity and the card beyond it at zero.
    static let dimmingPerCardStep: Double = 0.5

    /// Opacity for a card sitting `distance` card steps from the carousel's center.
    static func cardOpacity(distanceInSteps distance: CGFloat) -> Double {
        max(0, 1 - dimmingPerCardStep * Double(abs(distance)))
    }

    // MARK: - Release Management
    /// Adds a release in `format`, which the caller always supplies — there is no "current"
    /// format to infer when every format shares one stack.
    ///
    /// No insertion index is computed: `nextSortOrder` is a film-wide monotonic maximum and the
    /// unified comparator sorts by format rank first, so a new 4K lands at the end of the 4K
    /// run and ahead of the first Blu-ray purely as a consequence of the ordering.
    func addRelease(format: String) {
        // Enforced here as well as at every gate, so the cap is an invariant of the
        // operation rather than a property of the callers that happen to check it.
        guard canAddRelease() else {
            owner?.log("Add release rejected: the carousel is at the "
                       + "\(Self.maxReleases)-release cap")
            return
        }

        // Carry the film's release year forward so the new card's year steppers are constrained
        // from the outset. releaseYear is already 0 when detailsTab has no release date set,
        // which is the "unconstrained" value the stepper expects, so no separate check is needed.
        let filmYear = owner?.detailsTab.releaseYear ?? 0
        let newModel = ReleaseCardModel(format: format, sortOrder: nextSortOrder,
                                        filmReleaseYear: filmYear,
                                        filmReleaseDay: owner?.detailsTab.releaseDay)

        newModel.applyNewReleaseDefaults(for: format)

        let newID = newModel.id

        // The card the user is looking at, captured BEFORE the array grows.
        //
        // Identified by id rather than index because the insertion can move it: a new 4K lands
        // ahead of every Blu-ray and pushes the displayed card's index up by one. Holding the
        // index would leave the carousel showing a different card the instant the array
        // changed — a jump, when the whole point of what follows is that the move is traveled.
        let originID: UUID? = {
            let before = carouselEntries
            let idx = currentCardIndex
            return before.indices.contains(idx) ? before[idx].id : nil
        }()

        releases.append(newModel)
        owner?.log("Added new release form with format: \(format)")
        scheduleChangeCheck()

        // The new card's position in the unified stack, which the format-rank ordering may
        // have placed anywhere — a new Blu-ray on a film that already has DVDs lands in the
        // middle, not at the end — so it is looked up rather than assumed to be last.
        let entries = carouselEntries
        let targetIndex = entries.firstIndex { $0.parent.id == newID } ?? max(0, entries.count - 1)

        // Where the card the user was looking at ended up after the insertion.
        let originIndex = originID.flatMap { id in entries.firstIndex { $0.id == id } }
            ?? currentCardIndex

        if entries.count == 1 {
            // Quiescence window covering the two-yield mount plus the 0.2 s
            // fade-in, so the scheduleChangeCheck above cannot execute (nor
            // cascade into a FilmSheet footer re-render via notifyChanges)
            // during the new card's appearance animation.
            markAnimationWindow(.milliseconds(400))
            currentIndex = 0
            addingCardID = newID
            addSequenceTask = TaskHandle(Task { @MainActor [weak self] in
                await Task.yield()
                await Task.yield()
                guard let self else { return }
                // Canceled: clear the flag without the fade rather than returning early.
                // `addingCardID` holds the new card at zero opacity AND keeps
                // `isTransitioning` true, so leaving it set would strand the card invisible
                // and the carousel permanently locked against navigation, add, and delete.
                guard !Task.isCancelled else { self.addingCardID = nil; return }
                withAnimation(.easeIn(duration: 0.2)) { self.addingCardID = nil }
            })
        } else {
            // MARK: The auto-scroll
            //
            // The carousel TRAVELS to the new card — the intervening cards sweep past and the
            // stack settles on the empty slot, which the new card then fades into.
            //
            // The slide uses the same token-bumped spring as the arrow keys. Writing the index without bumping
            // the token would make the slide a cut, so this path bumps the same token and runs the same
            // mount-then-animate discipline as `beginNavigationMove`.
            //
            // The destination is the new card's position in the unified stack (`targetIndex`). The format rank
            // can place a new release anywhere, not only at the end.
            //
            // Any navigation still in flight is abandoned first: its target refers to the
            // pre-insertion layout, and it would clear the mount overrides set below.
            cancelNavigation()

            // Hold the displayed card in place across the array's growth. An insertion
            // ahead of it shifts its index, and without this correction the stack would cut
            // to a neighboring card the moment `releases` changed — a jump before the
            // slide, which is exactly what the slide exists to avoid.
            currentIndex = originIndex

            // Quiescence window covering the full add sequence: mount turn + the spring's
            // own settling duration + margin (navigationStepDuration) + the 0.3 s fade-in,
            // with headroom. The scheduleChangeCheck above waits this out, so the change
            // check — and the footer's hasChanges/canConfirm fade it can trigger — never
            // competes with the slide's or the fade's early frames.
            markAnimationWindow(.milliseconds(1300))
            addingCardID = newID

            // Claimed on this tick, immediately after `cancelNavigation()` retired whatever
            // claim the abandoned step held — so an in-flight step's own cancellation branch,
            // which runs a turn or more from now, cannot tear down the window claimed below.
            // See the mount-window ownership note.
            let windowToken = claimMountWindow()

            addSequenceTask = TaskHandle(Task { @MainActor [weak self] in
                guard let self else { return }

                if targetIndex != originIndex {
                    // Phase A — mount ahead. Structural, silent, un-animated. The origin is
                    // held alongside the destination (as the jump path does) because the
                    // travel can be long: without it, pointing the window at a distant
                    // target would unmount the card the user is still looking at for the
                    // turn before the slide begins.
                    self.mountWindowTarget = targetIndex
                    self.mountWindowSecondary = originIndex
                    await Self.nextRunLoopTurn()
                    guard !Task.isCancelled else {
                        self.addingCardID = nil
                        self.releaseMountWindow(token: windowToken)
                        return
                    }

                    // Phase B — the index change, over a static tree. The token bump is
                    // what opts this path into the spring; the slot it slides to is empty,
                    // because `addingCardID` holds the new card at zero opacity.
                    self.keyboardNavigationToken &+= 1
                    self.currentIndex = targetIndex

                    // Phase C — let the slide play out, then fade the new card in. Sourced
                    // from the spring itself rather than from a hand-tuned sleep, so
                    // retuning the spring retunes this too — but from its RESPONSE, the
                    // duration of the visible motion, rather than from its settling
                    // estimate plus a between-steps safety margin. See addFadeDelay.
                    try? await Task.sleep(for: Self.addFadeDelay)
                    guard !Task.isCancelled else {
                        self.addingCardID = nil
                        self.releaseMountWindow(token: windowToken)
                        return
                    }
                    withAnimation(.easeIn(duration: 0.3)) { self.addingCardID = nil }

                    // Phase D — hold the mount overrides until the spring is genuinely torn down. Dropping them
                    // mounts and unmounts cards, and that structural work must not land in the spring's tail. The
                    // fade starting earlier does not change this.
                    //
                    // MARK: Why this teardown is token-scoped
                    //
                    // `addingCardID` was cleared one sleep ago. It is the only thing `isTransitioning` is made of, and
                    // `isTransitioning` is the sole gate on navigation input. So the carousel accepts arrow keys, swipes
                    // and jumps for the whole `navigationStepDuration - addFadeDelay` interval this sleep spans, while
                    // this sequence still holds the window. An unconditional clear here would unmount whatever a step or
                    // jump started in that interval had mounted, so the release is scoped to this sequence's token.
                    //
                    // Not tied to `addingCardID` instead: that flag drives the new card's opacity and the fade that
                    // reveals it, so holding it to Phase D would keep the card invisible for another ~340 ms. What is
                    // at stake is the window's owner, so ownership is what is tracked.
                    try? await Task.sleep(for: Self.navigationStepDuration - Self.addFadeDelay)
                    self.releaseMountWindow(token: windowToken)
                    return
                } else {
                    // The new card landed on the slot already displayed — nothing to travel
                    // across. One turn for the mount, then the fade, with no spring at all.
                    //
                    // This branch sets no overrides — nothing travels, so nothing needs mounting
                    // ahead — which makes the token-scoped release below a no-op on it. Kept so
                    // both branches exit through the same call: the overrides are cleared by
                    // whoever owns them, on every path, without the reader having to work out
                    // which branch set what.
                    await Self.nextRunLoopTurn()
                }

                guard !Task.isCancelled else { self.addingCardID = nil; return }
                withAnimation(.easeIn(duration: 0.3)) { self.addingCardID = nil }
                self.releaseMountWindow(token: windowToken)
            })
        }
    }

    /// Called by ReleaseCardView when the user toggles the Wishlist checkbox. All mutations
    /// stay in-session until the sheet is saved, like every other field.
    ///
    /// MARK: Position assignment is APPEND-ONLY, and deliberately so
    ///
    /// A new position is one past the highest in use anywhere in the library —
    /// `coordinator.maxWishlistPosition(excludingFilm:)` together with this film's in-session
    /// maximum.
    ///
    /// A count-based base is wrong. It assumes this film's positions are the last N of the global sequence,
    /// but a film acquires positions whenever the user wishlists from it, so its slots are interleaved with
    /// every other film's. When they are, the arithmetic issues a slot another film already holds:
    ///
    ///     Film A wishlists R1  → 1        Film B wishlists R2  → 2
    ///     Film A wishlists R3  → 3        library: {1, 2, 3}
    ///     Film A un-wishlists R1: base = 3 − 2 = 1, so R3 compacts to 2 — Film B's.
    ///
    /// The Wishlist report sorts on this value, so a collision makes the order arbitrary. A
    /// value above every position in use cannot collide however gapped the sequence is.
    ///
    /// Removal does not compact. Compaction would renumber only this film's releases, which would move them
    /// across positions other films own. Gaps are harmless: every consumer treats `wishlist` as an ordering key, not an index.
    func handleWishlistToggle(releaseID: UUID, isOn: Bool) {
        guard let owner = owner else { return }
        guard let model = model(releaseID) else { return }

        if isOn {
            // The highest position in use, from the two sources that between them cover the
            // whole library: the store for every other film, and the live models for this
            // one (whose unsaved edits the store does not yet reflect). Combo-pack children
            // are excluded on both sides — a child's position is mirrored from its parent
            // by syncComboChildFields and never occupies a slot of its own.
            let otherFilmsMax = owner.coordinator.maxWishlistPosition(excludingFilm: owner.filmID)
            let thisFilmMax   = releases
                .filter { !$0.isComboChild }
                .map(\.wishlist)
                .max() ?? 0
            model.wishlist = max(otherFilmsMax, thisFilmMax) + 1
        } else {
            // Vacating the slot is the whole operation. See the note above on why the
            // survivors are deliberately left where they are.
            model.wishlist = 0
        }
    }

    func deleteRelease(id: UUID) {
        // Guard against re-entrant calls while a fly-up is in flight. The keyboard path checks
        // isTransitioning, but the card's delete button and the alert's "Delete" action do not,
        // so a rapid second tap could launch a concurrent Task that overwrites dismissingCardID
        // while the first is still sleeping.
        guard !isTransitioning else { return }

        guard let target = model(id) else {
            owner?.log("ERROR: Attempted to delete release with unknown id \(id)")
            return
        }

        // Collect IDs to remove: the target release plus any combo-pack children.
        // IDs are re-validated inside the async body before the actual removal, in
        // case an intervening structural mutation (e.g. a rapid combo-pack change)
        // alters releases during the 300 ms animation window.
        var idsToRemove: [UUID] = [id]
        let childIDs = target.childReleaseIDs
        for childID in childIDs {
            if releases.contains(where: { $0.id == childID }) {
                idsToRemove.append(childID)
            } else {
                // childReleaseIDs references a UUID not present in session releases.
                // Log the anomaly; the stale ID will be absent from idsToRemove so
                // the removal loop silently skips it (correct — nothing to remove).
                // The parent release is being deleted anyway, so no further cleanup
                // of its childReleaseIDs is necessary.
                owner?.log(
                    "WARNING: Deleting release \(id) which references child \(childID) " +
                    "not found in session releases — stale child ID skipped."
                )
            }
        }

        // MARK: Abandon this card's deferred picker work before the fly-up starts
        //
        // Both dictionaries hold tasks armed by the Type picker, keyed by the release they act on.
        // Removing a handle releases it, and TaskHandle cancels on deinit. Delete does this for every
        // release it removes, so no armed work outlives its card.
        //
        //   * comboChildTasks — the reconciliation, which CREATES child releases. Its own
        //     post-sleep liveness check (see handleComboPackChange) is the guarantee; this is
        //     what makes the common case not need it, and it closes the window 120 ms earlier
        //     than that check can. Deferred work that appends to `releases` behind a card the
        //     user has just deleted has no correct outcome, so it should not be in flight at
        //     all.
        //   * independencePromptTasks — the confirmation alert. Already re-validated before it
        //     presents, so this changes no outcome; it stops a destructive prompt about a card
        //     that is mid-fly-up from being queued in the first place.
        //
        // Keyed over `idsToRemove`, not just `id`: a combo-pack child can carry its own armed
        // task, and the children go with the parent.
        for doomedID in idsToRemove {
            comboChildTasks.removeValue(forKey: doomedID)
            independencePromptTasks.removeValue(forKey: doomedID)
            // A confirmed-but-unwritten type change for a release that is about to go has
            // nothing left to act on.
            pendingConfirmedIndependence.removeValue(forKey: doomedID)
        }

        // Animate the primary target flying off; children are removed silently after the same
        // delay, since they are off-screen when the parent is displayed. Stored in a
        // TaskHandle for its cancel-on-deinit/reassignment behavior, though a re-entrant call
        // reaching that reassignment is not actually possible: the isTransitioning guard at
        // the top of this function already refuses any call while this task is in flight.
        //
        // The quiescence window covers the 300 ms fly-up plus the 0.3 s post-removal settle,
        // so the scheduleChangeCheck at the end of the task waits it out.
        //
        // Recorded in `pendingDeletion` for the duration, so a save landing mid-fly-up can
        // complete the removal instead of persisting the release. See settlePendingWork().
        markAnimationWindow(.milliseconds(700))
        dismissingCardID = id
        pendingDeletion = (id: id, idsToRemove: idsToRemove)
        deleteTask = TaskHandle(Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else {
                // Task was canceled before the sleep completed — clear dismissingCardID
                // so the card is not left frozen in its fly-up position indefinitely.
                self?.abandonDeletion(id: id)
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                self.abandonDeletion(id: id)
                return
            }
            self.completeDeletion(id: id, idsToRemove: idsToRemove)
        })
    }

    /// Unwinds a delete whose fly-up task was canceled without completing it.
    ///
    /// Scoped to `id` on both writes. The one path that cancels this task on purpose,
    /// `settlePendingWork`, has already completed the delete by the time the canceled task
    /// wakes here — and a later delete may have started in between — so an unconditional
    /// clear could strand a newer fly-up or forget a newer pending removal.
    private func abandonDeletion(id: UUID) {
        if dismissingCardID == id { dismissingCardID = nil }
        if pendingDeletion?.id == id { pendingDeletion = nil }
    }

    /// Applies a delete's removal: the end of the fly-up, or `settlePendingWork` finishing it
    /// early.
    private func completeDeletion(id: UUID, idsToRemove: [UUID]) {
        pendingDeletion = nil

        // Re-validate that the IDs collected before the sleep are still present: an
        // intervening structural mutation (removeComboChildren firing because the user
        // changed the parent's independence back) could have removed one during the 300 ms
        // window, which would produce log output claiming a release was removed when it
        // was not.
        let currentIDSet = Set(releases.map { $0.id })
        let validatedIDs = idsToRemove.filter { currentIDSet.contains($0) }

        if !validatedIDs.isEmpty {
            // Remove all targeted releases in a single mutation so releases.didSet
            // (and the updateCarouselCache() it triggers) fires exactly once, rather
            // than once per removed element, so a parent and its children cost one filter and sort pass.
            let removalSet = Set(validatedIDs)
            releases.removeAll { removalSet.contains($0.id) }
            owner?.log("Removed release(s) with ids: \(validatedIDs.map { $0.uuidString }.joined(separator: ", "))")
        } else {
            owner?.log(
                "INFO: deleteRelease(\(id)) — all targeted IDs were already absent " +
                "from releases by animation completion; no removal performed."
            )
        }

        if dismissingCardID == id { dismissingCardID = nil }

        // One stack, one index — the removal may have shortened it past the current
        // position, so the index is brought back inside the array.
        clampIndex()
        // A merged card's variant selection is keyed by parent id; a pack that is gone
        // leaves an entry behind that would be re-applied if the same id ever returned
        // (an undo, a restore). Dropping it keeps the map to live cards only.
        for removedID in validatedIDs { selectedVariantByCard.removeValue(forKey: removedID) }

        scheduleChangeCheck()
    }

    /// Completes every user action still waiting on an animation or a menu-settle delay, so
    /// the session's state is the state the user has asked for. Called by
    /// `buildReleaseDeltas()`, which is what a save reads; see "Deferred work a save must not
    /// outrun" above.
    ///
    /// Order matters: a delete first (it also drops the deleted releases' pending work), then
    /// confirmed type changes (whose commit arms a reconciliation), then every armed
    /// reconciliation — including those just armed.
    ///
    /// A still-unanswered type-change PROMPT is deliberately left alone: the user has not
    /// agreed to it, so the value was never written and saving without it is correct.
    func settlePendingWork() {
        if let pending = pendingDeletion {
            // Releasing the handle cancels the fly-up; its cancellation branch is id-scoped
            // (abandonDeletion), so it cannot undo the completion below when it wakes.
            deleteTask = nil
            completeDeletion(id: pending.id, idsToRemove: pending.idsToRemove)
        }

        let confirmed = pendingConfirmedIndependence
        pendingConfirmedIndependence.removeAll()
        for (releaseID, value) in confirmed {
            guard let model = model(releaseID) else { continue }
            commitIndependence(value, on: model)
        }

        // Reconciliation is idempotent — it drives the child set to what the parent's
        // CURRENT independence calls for — so running it for a parent whose task already
        // finished (entries are never pruned) changes nothing.
        let parentIDs = Array(comboChildTasks.keys)
        comboChildTasks.removeAll()
        for parentID in parentIDs {
            guard let parent = model(parentID), parent.is4K else { continue }
            reconcileComboChildren(for: parent, targetIndependence: parent.independence)
        }
    }

    // MARK: - Combo-pack Child Management

    /// Pushes a new film release year onto every card and re-asserts the year-ordering rule
    /// against the floor it moves.
    ///
    /// Called by FSTabDetails whenever the film's release date changes, so `purchaseYearRange`
    /// — whose lower bound is the tighter of the format floor and the film's own year — cannot
    /// go stale on cards built before the edit.
    ///
    /// Raising the floor above a stored base release year is a real conflict, so
    /// `enforceReleaseYearOrder` runs for each affected card: the release year is the required
    /// field of the pair and is parent-locked on a combo child, so the method never rewrites it
    /// and the optional base year yields instead. Corrections reach change detection through
    /// ReleaseChangeObserver.
    ///
    /// The equality guard keeps this free on the common path — a date change that does not
    /// cross a year boundary writes nothing.
    ///
    /// The film's DAY rides along for the release-date picker's floor; it moves no stored
    /// value, so it needs no enforcement pass.
    func updateFilmRelease(year: Int, day: Date?) {
        for model in releases {
            if model.filmReleaseDay != day { model.filmReleaseDay = day }
            guard model.filmReleaseYear != year else { continue }
            model.filmReleaseYear = year
            model.enforceReleaseYearOrder()
        }
    }

    /// The live model for `id`, or nil if it is not in the session (a stale reference).
    func model(_ id: UUID) -> ReleaseCardModel? {
        releases.first { $0.id == id }
    }

    /// The sortOrder a newly appended release should take. Read it once before appending, so every new
    /// card in a batch is numbered from the same base.
    var nextSortOrder: Int {
        (releases.map { $0.sortOrder }.max() ?? -1) + 1
    }

    /// Re-clamps the carousel index after a removal. `currentCardIndex` already clamps on
    /// read, so this is not what keeps the carousel correct — it stops the stored value
    /// drifting arbitrarily far past the end across a run of deletions, which would make the
    /// next `+1` step compute nonsense.
    private func clampIndex() {
        currentIndex = min(currentIndex, max(0, carouselEntries.count - 1))
    }

    /// The fields a user can actually touch on a combo-pack child card — the ones not locked
    /// to and mirrored from the 4K parent.
    ///
    /// A list of COMPARISONS, not of literal defaults. Restating each default inline put the
    /// "untouched" baseline in two places — here and in whatever `createComboChildren`
    /// assigned — and getting it wrong is silent and asymmetric: too strict prompts on every
    /// revert, too loose discards an edited child without asking. Comparing against a pristine
    /// child built by the SAME factory removes the second copy, so changing a default is one
    /// edit in `ReleaseFormat.newReleaseDefaults`.
    ///
    /// Deliberately absent: every locked field, since a difference there is not user work.
    /// `baseReleaseYear` IS present (a bundled Blu-ray may be a reprint of an earlier release),
    /// as is `remastered`, a per-disc attribute with no `.disabled(isComboChild)` gate.
    private static let comboChildEditableFields: [ReleaseFieldComparison] = [
        .field(\.videoFormat),
        .field(\.scanningMethod),
        .field(\.audioFormat),
        .field(\.audioChannels),
        .field(\.hasSubtitles),
        .field(\.replicationType),
        .field(\.discCapacity),
        .field(\.regionLock),
        .field(\.regionLockBypass),
        .field(\.numberOfDiscs),
        .field(\.releaseAspectRatio),
        .field(\.hasBaseReleaseYear),
        .field(\.remastered),
        .field(\.includedVersions),
        // Notes are compared with surrounding whitespace stripped, so a stray space typed
        // into an otherwise-untouched child is not treated as user work. This is the one
        // field whose comparison is not plain equality, which is why the type admits a
        // custom predicate rather than being a bare list of key paths.
        .custom { $0.notes.trimmingCharacters(in: .whitespaces)
               != $1.notes.trimmingCharacters(in: .whitespaces) }
    ]

    /// Returns true if the child Blu-ray card at `childID` carries user work — i.e. if any
    /// field the user can edit on a combo-child card differs from a freshly created one.
    ///
    /// Drives only the decision of WHETHER to confirm a combo-pack reduction; the surplus
    /// children are deleted either way once confirmed. See `requestIndependenceChange`.
    func comboChildHasBeenEdited(_ childID: UUID) -> Bool {
        guard let child = model(childID) else { return false }
        // The baseline is a real child built by the same factory createComboChildren uses,
        // so it carries exactly the defaults a just-created child is handed. Constructed
        // per call rather than cached: this runs only on a Type-picker interaction, and a
        // shared instance would be a mutable baseline that any future code could corrupt.
        let pristine = Self.makeComboChild()
        return Self.comboChildEditableFields.contains { $0.differs(child, pristine) }
    }

    /// Builds a combo-pack child Blu-ray with its starting field values.
    ///
    /// The single definition of what an untouched child IS, used both to create one
    /// (`createComboChildren`) and to recognize one (`comboChildHasBeenEdited`). The
    /// caller wires `parentReleaseID`; identity and hierarchy are not part of "untouched".
    private static func makeComboChild(sortOrder: Int = 0,
                                       filmReleaseYear: Int = 0) -> ReleaseCardModel {
        let bluRay = ReleaseFormat.bluRay.rawValue
        let child = ReleaseCardModel(format: bluRay,
                                     sortOrder: sortOrder,
                                     filmReleaseYear: filmReleaseYear)
        child.applyNewReleaseDefaults(for: bluRay)
        return child
    }

    /// The children of `parent` actually present in this session, in a stable order.
    ///
    /// Ordered by `ReleaseCardModel.precedes` rather than by `childReleaseIDs`' element order,
    /// which is unspecified because it is populated from a Core Data to-many relationship.
    /// Every decision that distinguishes "the first child" from "the second" reads through
    /// here, so those decisions survive a save/reload cycle.
    func comboChildren(of parent: ReleaseCardModel) -> [ReleaseCardModel] {
        let idSet = Set(parent.childReleaseIDs)
        guard !idSet.isEmpty else { return [] }
        return releases
            .filter { idSet.contains($0.id) }
            .sorted(by: ReleaseCardModel.precedes)
    }

    /// Drops any entry from `parent.childReleaseIDs` naming a release not present in this
    /// session, logging each one. Same anomaly `loadExistingReleases` Case A repairs at load
    /// time; this covers the window before the next reload. A phantom ID makes the parent's
    /// child count read high, so reconciliation would delete a real child to "reach" a count
    /// it already had.
    private func pruneStaleChildIDs(on parent: ReleaseCardModel) {
        let presentIDs = Set(releases.map { $0.id })
        let stale = parent.childReleaseIDs.filter { !presentIDs.contains($0) }
        guard !stale.isEmpty else { return }
        owner?.log(
            "WARNING: Parent release \(parent.id) references \(stale.count) child ID(s) " +
            "not present in session releases — clearing stale entries. " +
            "Stale IDs: \(stale.map { $0.uuidString }.joined(separator: ", "))"
        )
        parent.childReleaseIDs.removeAll { !presentIDs.contains($0) }
    }

    /// How many bundled discs would go with `parent` if it were deleted right now, after any
    /// stale child ID has been dropped from it.
    ///
    /// The one entry point for "how many children does this card really have?" from outside
    /// this type, and the reason `childReleaseIDs` can be `fileprivate(set)` at all.
    ///
    /// A view calls this rather than deriving the count itself, for three reasons:
    ///
    ///   * A view would become a writer of hierarchy state, which has to be reasoned about across two
    ///     models at once.
    ///   * A view-side derivation would be a fifth copy of a rule that already exists four times (see
    ///     `ReleaseCardModel.precedes`), so a change to the rule would have to find it there too.
    ///   * Pruning must log. `pruneStaleChildIDs` logs each stale ID because a phantom child means something
    ///     upstream is wrong. A silent prune would drop that warning exactly where it matters most: immediately
    ///     before a destructive confirmation whose wording depends on this number.
    ///
    /// A parent with no stale IDs prunes nothing, and a parent with no children resolves none.
    func liveChildCount(of parent: ReleaseCardModel) -> Int {
        pruneStaleChildIDs(on: parent)
        return comboChildren(of: parent).count
    }

    /// Delay before any combo-pack reconciliation runs, measured from the Type picker's
    /// selection change.
    ///
    /// A Core Animation animation is only vulnerable while its transaction is being built and
    /// committed on the main thread; once committed, the window server interpolates it out of
    /// process. So this does not need to cover the menu's fade-out PLAYING — only the run-loop
    /// turn in which AppKit ends the tracking loop and commits that fade.
    ///
    /// 120 ms is comfortably past the commit while still overlapping the fade on screen, which
    /// is what makes the interaction read as one gesture. The margin is not zero because
    /// `beginSheetModal` does substantial synchronous layout work and reconciliation performs
    /// SwiftUI writes; neither should land in the same turn as the menu teardown.
    private static let menuDismissalSettleDelay: Duration = .milliseconds(120)

    /// Called from `commitIndependence`, once the value is written. The work itself is kept
    /// off the menu's dismissal turn by the settle delay inside the task. By this point the
    /// change is already settled (see `requestIndependenceChange`).
    ///
    /// Delegates to `reconcileComboChildren`, which drives the parent's child set to whatever the new
    /// independence calls for. Expressing it as reconciliation rather than as old→new transitions is what
    /// makes "Combo-pack" ⇄ "Combo-pack (dual BD)" tractable: a change between two combo values has no
    /// create-or-delete form.
    ///
    /// Non-4K releases are no-ops, as are changes where neither value is a combo type —
    /// UNLESS the parent already holds children.
    ///
    /// That exception keeps the type-change alert honest. A 4K release can hold children under a non-combo
    /// type (a restored backup, or a save interrupted mid-reconciliation), and `requestIndependenceChange`
    /// counts those children and
    /// warns they will be removed. Skipping reconciliation here because neither type NAMES a
    /// combo pack then broke that promise: the user confirmed, and the discs stayed.
    /// Reconciling drives the child count to what the new type calls for, which for every
    /// non-combo type is zero.
    private func handleComboPackChange(for parentID: UUID,
                                       oldIndependence: String,
                                       newIndependence: String) {
        guard let parent = model(parentID) else { return }
        guard parent.is4K else { return }
        guard ReleaseIndependence.isComboPack(oldIndependence)
                || ReleaseIndependence.isComboPack(newIndependence)
                || !parent.childReleaseIDs.isEmpty else { return }

        // Cancel any previously queued task FOR THIS PARENT (rapid picker spinning) by
        // replacing its dictionary entry — the displaced TaskHandle cancels on release. Keying
        // by parent keeps a second parent's change from discarding this one's reconciliation.
        //
        // The sleep sits inside the cancellable task on purpose: spinning the picker through
        // several values discards every intermediate reconciliation.
        comboChildTasks[parentID] = TaskHandle(Task { @MainActor [weak self] in
            try? await Task.sleep(for: FSTabReleases.menuDismissalSettleDelay)
            guard let self, !Task.isCancelled else { return }

            // MARK: The parent must still be in the session
            //
            // `parent` is captured strongly, so it stays alive and fully usable after the
            // release it describes has left `releases` — and `reconcileComboChildren` does not
            // ask. `createComboChildren` would then APPEND children beneath a release that no
            // longer exists, and those children are not stale references that later repairs
            // prune: they are new, top-level-on-arrival Blu-ray cards the user never asked for,
            // which `buildReleaseDeltas` files under `create` and the next save persists.
            //
            // The window is real and does not require unusual speed. `deleteRelease` snapshots
            // its removal set BEFORE its 300 ms fly-up, so children created at this point (120 ms
            // in) are not in it and outlive the parent's removal by construction. Deleting the
            // card while the Type picker's menu is still settling is enough.
            //
            // `===` rather than an id lookup: the question is whether THIS object is still the
            // session's model for that release, which an id match would answer yes to even
            // after a reload replaced it. Matches the identical re-validation in
            // `requestIndependenceChange`.
            guard self.releases.contains(where: { $0 === parent }) else {
                self.owner?.log(
                    "Combo-pack reconciliation for parent \(parentID) abandoned: the release "
                    + "left the session while the picker was settling."
                )
                return
            }

            self.reconcileComboChildren(for: parent, targetIndependence: newIndependence)
        })
    }

    /// Writes a user's Type change and applies everything that follows from it: the
    /// dependent-field cascade, and (for a 4K release) the combo-pack reconciliation.
    ///
    /// MARK: Why this lives on the view model
    ///
    /// The cascade runs here rather than in the card's `.onChange(of: model.independence)`. That handler
    /// runs only if a view observing this model is mounted when the value lands, so the side effects could
    /// silently not happen. A merged card showing its Blu-ray segment, for example, observes the child, not
    /// the parent. Applied at the one write site, the cascade is a property of the change, not of what is on
    /// screen.
    ///
    /// Writes nothing and triggers nothing when the value is unchanged. Combo-pack children never come through
    /// here, because their independence is locked and written only by `syncComboChild`. They are guarded out
    /// anyway, so the cascade can never clobber synced values.
    private func commitIndependence(_ newValue: String, on model: ReleaseCardModel) {
        let oldValue = model.independence
        guard oldValue != newValue else { return }
        model.independence = newValue
        guard !model.isComboChild else { return }

        model.discMultiPack = (newValue == ReleaseIndependence.multiPack)

        // hasArtwork is reset because each type offers a different artwork tag set. Two
        // exceptions, both rules of the artwork vocabulary rather than of this cascade:
        //   • the combo-pack forms share their tags, so moving between them keeps any tag
        //     the new form still offers — "Combo-pack (multi-pack)" adds "Yes (Multi-pack)",
        //     which is retracted on the way back to a form that lacks it;
        //   • "Steelbook" is offered under every type and purchased state (see
        //     _ArtworkPicker), so no type change can make it invalid. A cascade may retract a
        //     value the NEW vocabulary cannot express, never one it still can.
        let stayedWithinComboForms = ReleaseIndependence.isComboPack(oldValue)
            && ReleaseIndependence.isComboPack(newValue)
            && (model.hasArtwork.isEmpty
                || ReleaseArtwork.options(forIndependence: newValue).contains(model.hasArtwork))
        if !stayedWithinComboForms && model.hasArtwork != ReleaseArtwork.steelbook {
            model.hasArtwork = ""
        }

        // A non-4K combo-pack disc carries no price of its own. Reachable only through a
        // value the Type menu keeps for display (see _TypeVersionsRow.typeItems).
        if model.purchased && ReleaseIndependence.isComboPack(newValue) && !model.is4K {
            model.cost        = 0.0
            model.amountSpent = 0.0
        }

        // Market availability, which only exists while the release is unpurchased (the
        // purchased branch of _PurchaseRows does not show it). A non-4K combo disc is locked to
        // "Combo-pack only"; leaving the combo forms retracts that lock.
        if !model.purchased {
            if (model.isBluRay || model.isDVD) && ReleaseIndependence.isComboPack(newValue) {
                model.marketAvailability = [ReleaseMarketAvailability.comboPackOnly]
            } else if !ReleaseIndependence.isComboPack(newValue)
                        && model.marketAvailability == [ReleaseMarketAvailability.comboPackOnly] {
                model.marketAvailability = []
            } else {
                // Entering or leaving "Multi-pack" respells the status ("Available" ⇄
                // "Multi-pack available"); see ReleaseMarketAvailability.Kind.
                let kind = ReleaseMarketAvailability.Kind(nationalOrigin: model.nationalOrigin,
                                                          independence: newValue)
                let respelled = ReleaseMarketAvailability.retargeted(model.marketAvailability,
                                                                     for: kind)
                if respelled != model.marketAvailability { model.marketAvailability = respelled }
            }
        }

        // Children follow the new type after the menu-settle delay; see handleComboPackChange.
        if model.is4K {
            handleComboPackChange(for: model.id, oldIndependence: oldValue,
                                  newIndependence: newValue)
        }
    }

    /// The single entry point for every user-initiated change to a release's `independence`.
    /// Called from the Type picker's binding setter, BEFORE the value is written.
    ///
    /// MARK: Why the confirmation happens here and not after the write
    /// A change that discards edited combo-pack children has to be confirmed, and applying it
    /// first and undoing on cancel cannot be made correct: the write fans out immediately —
    /// commitIndependence's cascade clears `hasArtwork`, ReleaseChangeObserver converges every child's
    /// locked fields onto the parent — and each of those is a real difference from the
    /// change-detection baseline. The restore's own writes then re-trigger the same mechanisms
    /// a render pass later, so the undo gets undone, leaving the sheet dirty for a change the
    /// user explicitly abandoned.
    ///
    /// Gating the write removes the problem: nothing was written, no cascade ran, no child was
    /// touched, so a canceled change cannot enable the Update button by construction.
    func requestIndependenceChange(on model: ReleaseCardModel, to newValue: String) {
        guard model.independence != newValue else { return }

        // Only a 4K parent can own children, so every other card commits directly.
        guard model.is4K else {
            commitIndependence(newValue, on: model)
            return
        }

        pruneStaleChildIDs(on: model)
        let desired = ReleaseIndependence.childCount(for: newValue)
        let current = comboChildren(of: model)

        // Not a reduction — creating children or leaving the count alone discards
        // nothing, so there is nothing to ask about.
        guard desired < current.count else {
            commitIndependence(newValue, on: model)
            return
        }

        // Same suffix rule reconciliation will apply, so the children named here are
        // exactly the ones that will be removed.
        let surplus = Array(current.suffix(current.count - desired))
        guard surplus.contains(where: { comboChildHasBeenEdited($0.id) }) else {
            // Nothing in the surplus carries user work — drop it without asking. A child
            // still holding exactly the defaults createComboChildren gave it represents
            // no user effort, so discarding it silently is correct.
            owner?.log("Combo child deletion needs no confirmation: \(surplus.count) surplus "
                     + "child(ren), none edited — deleting silently")
            commitIndependence(newValue, on: model)
            return
        }

        // Edited-ness decides only WHETHER to prompt; the message covers the ENTIRE surplus,
        // because confirming deletes every surplus child regardless of which ones were edited.
        //
        // The surplus is counted, not named: bundled discs are segments of one merged card and
        // carry no release number the user can see. See ReleasesFormatting.
        // The title names the ACTION the user took, not its consequence. Titling the alert after the deleted
        // discs made it read as a delete prompt the user had not asked for, while the picker they had just
        // changed sat behind it. The title is one fixed string, so the same action always announces itself
        // the same way.
        let title = "Change Release Type"
        // Only a combo pack can reach here — a reduction in child count presupposes children —
        // so the noun is fixed rather than derived, and the bundled discs are always Blu-rays.
        //
        // Pluralized on the SURPLUS, which is what will actually be removed, not on the pack
        // type: dual BD → Standalone drops both discs and reads "releases", while dual BD →
        // Combo-pack drops exactly one and reads "release". Keying it to the type would have
        // made that second case say "releases" for a single disc.
        let clause = surplus.count == 1
            ? "the associated Blu-ray release"
            : "the associated Blu-ray releases"
        let message = "Are you sure you want to change this combo-pack release's type? Doing so will also remove \(clause). This action cannot be undone unless all changes to the sheet are discarded."

        // MARK: Sequencing
        //
        // The alert is raised a menu-settle interval after the selection, not on the same
        // turn: AppKit is still unwinding the picker's menu tracking loop and committing its
        // fade-out. Held in a TaskHandle so spinning the picker through several values
        // discards the superseded prompts and only the final selection asks anything.
        //
        // The picker needs no correction: the value was never written, so the control never showed the
        // pending selection.
        independencePromptTasks[model.id] = TaskHandle(Task { @MainActor [weak self] in
            try? await Task.sleep(for: FSTabReleases.menuDismissalSettleDelay)
            guard let self, !Task.isCancelled else { return }

            // Re-validated after the sleep: the card could have been deleted, or the
            // model's value changed, while it ran.
            guard self.releases.contains(where: { $0 === model }),
                  model.independence != newValue else { return }

            // Quiescence window covering the alert's presentation, so a debounced change
            // check armed by an earlier field edit cannot execute inside it.
            self.markAnimationWindow(.milliseconds(500))

            self.requestConfirmation(
                title: title,
                message: message,
                confirmTitle: "Change and Remove",
                // Destructive: confirming discards the bundled Blu-ray release(s) named in the
                // message, which is the half of this action the user needs warning about.
                isDestructive: true,
                onConfirm: { [weak self] in
                    guard let self else { return }
                    // Recorded BEFORE the deferral, so a save landing in the turn between
                    // the alert's dismissal and the write still carries the change the user
                    // just agreed to. See settlePendingWork().
                    self.pendingConfirmedIndependence[model.id] = newValue
                    // Deferred one turn so the model write — and the carousel re-render
                    // that removing the children sets off — do not share the turn in
                    // which the alert begins dismissing.
                    DispatchQueue.main.async {
                        // Already applied by settlePendingWork (or dropped by a delete):
                        // nothing left to do.
                        guard self.pendingConfirmedIndependence
                                .removeValue(forKey: model.id) != nil else { return }
                        // Re-validated at execution time rather than trusted from
                        // capture: this write is the ONLY mutation of the whole flow, so
                        // it must still be the right one to make.
                        guard self.releases.contains(where: { $0 === model }),
                              model.independence != newValue else { return }
                        self.markAnimationWindow(.milliseconds(500))
                        // Commits the change with its cascade and reconciliation, exactly
                        // as for a change that never needed asking about. The picker needs
                        // no attention: a real write pushes the new value down normally.
                        self.commitIndependence(newValue, on: model)
                    }
                },
                // Nothing to undo on cancel — the value was never written, and the Type
                // control re-selected the binding's value on the turn the write was declined
                // (see ReleasePopUpButton), so its menu marks nothing stale either.
                onCancel: {}
            )
        })
    }

    /// Brings `parent`'s child Blu-rays into agreement with `targetIndependence` — creating
    /// the shortfall (see `createComboChildren`) or removing the surplus.
    ///
    /// This asks nothing. Confirmation moved upstream to `requestIndependenceChange`, which
    /// raises the alert BEFORE the value is written, so by the time this runs the change is
    /// settled. That is what makes canceling free: nothing committed, no cascade fired.
    ///
    /// The surplus is taken from the END of `comboChildren(of:)` — a dual→single downgrade
    /// keeps the first Blu-ray, which leaves the surviving card where the user has been looking
    /// and matches the children the alert named.
    private func reconcileComboChildren(for parent: ReleaseCardModel,
                                        targetIndependence: String) {
        pruneStaleChildIDs(on: parent)

        let desired  = ReleaseIndependence.childCount(for: targetIndependence)
        let current  = comboChildren(of: parent)

        if desired > current.count {
            createComboChildren(for: parent, count: desired - current.count)
            return
        }

        guard desired < current.count else { return }

        let surplus = Array(current.suffix(current.count - desired))
        removeComboChildren(surplus.map { $0.id }, from: parent)
    }

    /// Syncs all locked fields from a parent 4K model onto its child Blu-ray models.
    ///
    /// Iterates every child rather than only the first: a "Combo-pack (dual BD)" parent has
    /// two, equally locked to it, so a studio or purchase-date edit has to reach both or the
    /// second card silently retains a stale value that then persists on save.
    func syncComboChildFields(from parent: ReleaseCardModel) {
        let children = comboChildren(of: parent)
        guard !children.isEmpty else { return }
        for child in children { syncComboChild(child, from: parent) }
    }

    /// The per-child half of `syncComboChildFields`.
    private func syncComboChild(_ child: ReleaseCardModel, from parent: ReleaseCardModel) {
        // Locked fields: purchased, wishlist, studio, releaseYear/hasReleaseYear/releaseMonthDay,
        // independence, nationalOrigin, cost, amountSpent, lowestPrice,
        // lowestPriceDate/hasLowestPriceDate, marketAvailability,
        // purchaseDate/hasPurchaseDate, condition, hasArtwork.
        // baseReleaseYear is NOT locked — the child may be a reprint of an earlier release.
        //
        // MARK: Condition-gated writes
        // Every assignment is guarded by an inequality check. That is a performance measure, not a behavioral
        // one: @Observable notifies on every write, including equal-value ones, and this runs on every keystroke
        // on a 4K parent card. Unconditional writes would notify observers on each keystroke even when no locked
        // field changed. The end state is identical, and the card's cascades key off .onChange(of:), which never
        // fired on equal-value writes anyway.
        if child.purchased          != parent.purchased          { child.purchased          = parent.purchased }
        if child.wishlist           != parent.wishlist           { child.wishlist           = parent.wishlist }
        if child.studio             != parent.studio             { child.studio             = parent.studio }
        if child.studioSelection    != parent.studioSelection    { child.studioSelection    = parent.studioSelection }
        if child.studioCustomText   != parent.studioCustomText   { child.studioCustomText   = parent.studioCustomText }
        if child.releaseYear        != parent.releaseYear        { child.releaseYear        = parent.releaseYear }
        if child.hasReleaseYear     != parent.hasReleaseYear     { child.hasReleaseYear     = parent.hasReleaseYear }
        // After hasReleaseYear, whose didSet clears the month and day when it goes false.
        if child.releaseMonthDay    != parent.releaseMonthDay    { child.releaseMonthDay    = parent.releaseMonthDay }
        // releaseYear is locked to the parent but baseReleaseYear is not, so a change to the
        // parent's release year can push the child into a state its own Steppers never
        // produced. Both are re-asserted here against the just-synced release year, so the
        // child's base year is the field that yields.
        //
        // enforceReleaseYearOrder never writes releaseYear, which is what makes this safe to
        // call here: the correction cannot undo the assignment two lines above. Returns
        // immediately when nothing is wrong.
        //
        // Asserted at the data layer rather than left to _ReleaseYearRow's clear handler,
        // which only runs for a card currently mounted in the carousel.
        if !child.hasReleaseYear && child.hasBaseReleaseYear {
            child.hasBaseReleaseYear = false
        }
        child.enforceReleaseYearOrder()
        // A child's independence is always the singular "Combo-pack", never the parent's
        // "Combo-pack (dual BD)" — the dual form describes the 4K master's packaging, while
        // each individual Blu-ray is simply a combo-pack disc. It is also what lets every
        // child-side check elsewhere stay written as `isComboPack(independence) && format !=
        // "4K UHD"`.
        if child.independence       != ReleaseIndependence.comboPack {
            child.independence = ReleaseIndependence.comboPack
        }
        if child.nationalOrigin     != parent.nationalOrigin     { child.nationalOrigin     = parent.nationalOrigin }
        // MARK: Region compatibility follows the synced origin
        //
        // `regionLock` is the CHILD's own field — a bundled Blu-ray may be locked differently
        // from how the pack was sold — but the origin it must be compatible with IS locked and
        // is pushed down one line above, so a parent country change can leave the child holding
        // a region its own picker would never have allowed.
        //
        // `_CountryRow`'s cascade cannot cover this: it suppresses itself for combo children,
        // and it only runs while the child's segment is mounted. The card's read-side clamp would hide the stale
        // value, while the sidebar and table, which read `regionLock` raw, would show it. Handled here because this
        // is the path the change arrives on, and it runs whether or not a card is mounted. Cleared rather than
        // substituted: there
        // is no correct region to guess at.
        if child.isBluRay,
           ReleaseRegionRules.isIncompatible(regionLock: child.regionLock,
                                             origin: child.nationalOrigin) {
            child.regionLock = ""
            // Kept in step with regionLock exactly as the card's cascade keeps it: the
            // bypass only ever describes the loosely-locked tag, so clearing one without
            // the other would strand a flag with nothing to qualify.
            if child.regionLockBypass { child.regionLockBypass = false }
        }
        if child.cost               != parent.cost               { child.cost               = parent.cost }
        if child.amountSpent        != parent.amountSpent        { child.amountSpent        = parent.amountSpent }
        if child.lowestPrice        != parent.lowestPrice        { child.lowestPrice        = parent.lowestPrice }
        if child.lowestPriceDate    != parent.lowestPriceDate    { child.lowestPriceDate    = parent.lowestPriceDate }
        if child.hasLowestPriceDate != parent.hasLowestPriceDate { child.hasLowestPriceDate = parent.hasLowestPriceDate }
        if child.marketAvailability != [ReleaseMarketAvailability.comboPackOnly] {
            child.marketAvailability = [ReleaseMarketAvailability.comboPackOnly]
        }
        if child.purchaseDate       != parent.purchaseDate       { child.purchaseDate       = parent.purchaseDate }
        if child.hasPurchaseDate    != parent.hasPurchaseDate    { child.hasPurchaseDate    = parent.hasPurchaseDate }
        if child.condition          != parent.condition          { child.condition          = parent.condition }
        if child.hasArtwork         != parent.hasArtwork         { child.hasArtwork         = parent.hasArtwork }
    }

    // MARK: - Private combo-pack helpers

    /// Creates `count` child Blu-ray releases beneath `parent` and appends them in a single
    /// mutation.
    ///
    /// Batched, not staggered. `releases` has a `didSet` that runs `updateCarouselCache()` (a
    /// sort plus a group over the whole array) and invalidates every carousel observer; two
    /// appends pay that twice and leave a frame in which the parent claims two children while
    /// only one exists — which the sidebar's group builder, the table's stacking, and
    /// reconciliation itself would all observe mid-flight.
    ///
    /// There is also nothing to stagger away from: the user is looking at the 4K card, and the
    /// caller already arrived a full run-loop turn after the picker's onChange.
    private func createComboChildren(for parent: ReleaseCardModel, count: Int) {
        guard count > 0 else { return }

        let baseSortOrder = nextSortOrder
        let filmYear      = parent.filmReleaseYear
        let filmDay       = parent.filmReleaseDay

        var newChildren: [ReleaseCardModel] = []
        newChildren.reserveCapacity(count)

        for offset in 0..<count {
            // Built by the same factory comboChildHasBeenEdited measures "untouched"
            // against, so the two cannot disagree about what a fresh child looks like.
            let child = Self.makeComboChild(sortOrder: baseSortOrder + offset,
                                            filmReleaseYear: filmYear)
            child.filmReleaseDay = filmDay
            // Wire the hierarchy.
            child.parentReleaseID = parent.id
            newChildren.append(child)
        }

        // Append BEFORE syncing. syncComboChildFields resolves children by searching
        // `releases` for the recorded IDs — before they are appended the lookup returns nothing
        // and the sync is a silent no-op, leaving every locked field at its init-time default.
        //
        // childReleaseIDs is APPENDED to, not overwritten: this is also the path that tops a
        // single-child pack up to a dual-BD pack's two, and overwriting would orphan the
        // existing child — leaving it permanently locked and undeletable.
        parent.childReleaseIDs.append(contentsOf: newChildren.map { $0.id })
        releases.append(contentsOf: newChildren)

        // Sync all locked fields onto every child, including any that already existed — the
        // condition-gated writes make that free when they already agree.
        //
        // marketAvailability needs no separate handling: syncComboChild writes
        // ["Combo-pack only"] onto every child unconditionally, with no special case for an unpurchased parent.
        syncComboChildFields(from: parent)

        owner?.log(
            "Created \(newChildren.count) combo-pack child Blu-ray release(s) for 4K parent " +
            "\(parent.id): \(newChildren.map { $0.id.uuidString }.joined(separator: ", "))"
        )
        scheduleChangeCheck()
    }

    /// Removes the given child releases from `parent` and from `releases` in a single
    /// mutation, for the same reason `createComboChildren` appends in one: `releases` has a
    /// `didSet` that re-filters and re-sorts.
    ///
    /// IDs not present in `releases` are stale and are filtered out rather than treated as an
    /// error; the parent's `childReleaseIDs` is cleaned of them either way.
    private func removeComboChildren(_ childIDs: [UUID], from parent: ReleaseCardModel) {
        guard !childIDs.isEmpty else { return }

        let presentIDs = Set(releases.map { $0.id })
        let removalSet = Set(childIDs.filter { presentIDs.contains($0) })

        // Always drop the requested IDs from the parent, present or not: a stale entry
        // left behind would inflate the parent's apparent child count and cause the next
        // reconciliation to delete a real child in its place.
        parent.childReleaseIDs.removeAll { childIDs.contains($0) }

        guard !removalSet.isEmpty else { return }
        releases.removeAll { removalSet.contains($0.id) }
        owner?.log(
            "Removed \(removalSet.count) combo-pack child Blu-ray release(s) from 4K parent " +
            "\(parent.id): \(removalSet.map { $0.uuidString }.sorted().joined(separator: ", "))"
        )

        clampIndex()

        // Bring the merged card's displayed variant back inside the variants that remain.
        //
        // `variantIndex(for:variantCount:)` already clamps on READ, so this is not what keeps
        // the card correct — it stops the stored value outliving the discs it referred to, so a
        // dual→single→dual round trip does not silently reopen on the second Blu-ray.
        if let stored = selectedVariantByCard[parent.id] {
            let variantCount = 1 + parent.childReleaseIDs.count
            if stored >= variantCount {
                selectedVariantByCard[parent.id] = max(0, variantCount - 1)
            }
        }

        scheduleChangeCheck()
    }

    // MARK: - DTO Support
    /// The changes a save writes.
    ///
    /// Settles deferred work FIRST, so the deltas describe what the user has asked for rather
    /// than where the animations have got to. This is what a save reads, and a save can land
    /// mid-fly-up or mid-reconciliation. See settlePendingWork().
    func buildReleaseDeltas() -> (create: [ReleaseSnapshot], update: [ReleaseSnapshot], delete: [UUID]) {
        settlePendingWork()
        let dateFormatter = FSTabReleases.releaseDateFormatter

        let originalIDSet = Set(originalReleasesByID.keys)
        let currentIDSet  = Set(releases.map { $0.id })

        let addedIDs     = currentIDSet.subtracting(originalIDSet)
        let survivingIDs = originalIDSet.intersection(currentIDSet)
        let deletedIDs   = Array(originalIDSet.subtracting(currentIDSet))

        let toCreate = releases
            .filter { addedIDs.contains($0.id) }
            .map { modelToReleaseSnapshot($0, dateFormatter: dateFormatter) }

        let toUpdate = releases
            .filter { model in
                guard survivingIDs.contains(model.id) else { return false }
                // A load-time repair is already part of the baseline, so the snapshot
                // comparison below can never see it. See loadRepairedIDs.
                if loadRepairedIDs.contains(model.id) { return true }
                return model.snapshot() != originalReleasesByID[model.id]
            }
            .map { modelToReleaseSnapshot($0, dateFormatter: dateFormatter) }

        return (create: toCreate, update: toUpdate, delete: deletedIDs)
    }

    /// Converts a live ReleaseCardModel to the ReleaseSnapshot the persistence layer takes.
    ///
    /// Reads the model directly. ReleaseCardState is not a stage in this conversion, so a save does not
    /// allocate a throwaway ReleaseCardState per release.
    ///
    /// ReleaseCardState stays: it is the change-detection baseline, a genuinely different job.
    /// The three optional fields are each gated on their has-value flag, so an inactive field
    /// persists as "", never as the placeholder the model carries.
    private func modelToReleaseSnapshot(_ model: ReleaseCardModel,
                                        dateFormatter: DateFormatter) -> ReleaseSnapshot {
        ReleaseSnapshot(
            id: model.id,
            studio: model.studio,
            releaseDate: model.releaseDateStorageString,
            baseReleaseYear: model.hasBaseReleaseYear ? "\(model.baseReleaseYear)" : "",
            purchased: model.purchased,
            wishlist: model.wishlist,
            format: model.format,
            includedVersions: model.includedVersions,
            independence: model.independence,
            videoFormat: model.videoFormat,
            releaseAspectRatio: model.releaseAspectRatio,
            scanningMethod: model.scanningMethod,
            audioFormat: model.audioFormat,
            audioChannels: model.audioChannels,
            hasSubtitles: model.hasSubtitles,
            numberOfDiscs: model.numberOfDiscs,
            discMultiPack: model.discMultiPack,
            hasArtwork: model.hasArtwork,
            remastered: model.remastered,
            nationalOrigin: model.nationalOrigin,
            replicationType: model.replicationType,
            discCapacity: model.discCapacity,
            hasHDR: model.hasHDR,
            masterType: model.masterType,
            regionLock: model.regionLock,
            regionLockBypass: model.regionLockBypass,
            marketAvailability: model.marketAvailability,
            numberOfCopies: model.numberOfCopies,
            cost: model.cost,
            amountSpent: model.amountSpent,
            purchaseDate: model.hasPurchaseDate ? dateFormatter.string(from: model.purchaseDate) : "",
            lowestPrice: model.lowestPrice,
            lowestPriceDate: model.hasLowestPriceDate ? dateFormatter.string(from: model.lowestPriceDate) : "",
            condition: model.condition,
            notes: model.notes,
            dateAdded: model.dateAdded,
            sortOrder: model.sortOrder,
            parentReleaseID: model.parentReleaseID,
            childReleaseIDs: model.childReleaseIDs
        )
    }
}

// MARK: - ReleaseFieldComparison
// A single field's "are these two cards different here?" test, type-erased so fields of
// differing types can sit in one list.
//
// `.field(_:)` is the ordinary case: a key path plus `!=`. The generic initializer erases the
// value type — the key path's `Value` is captured inside the closure and never appears in the
// stored property's type. `.custom(_:)` exists for the one field whose comparison is not plain
// equality (notes are compared whitespace-trimmed).
@MainActor
struct ReleaseFieldComparison {
    let differs: (ReleaseCardModel, ReleaseCardModel) -> Bool

    static func field<Value: Equatable>(
        _ keyPath: KeyPath<ReleaseCardModel, Value>
    ) -> ReleaseFieldComparison {
        ReleaseFieldComparison { $0[keyPath: keyPath] != $1[keyPath: keyPath] }
    }

    static func custom(
        _ differs: @escaping (ReleaseCardModel, ReleaseCardModel) -> Bool
    ) -> ReleaseFieldComparison {
        ReleaseFieldComparison(differs: differs)
    }
}

// MARK: - Release Card State (DTO / Snapshot)
// Minimal value type used exclusively for snapshotting, diffing, and serialization.
// ReleaseCardModel.snapshot() produces instances of this type. It carries no
// convenience properties or init overloads — those belong on ReleaseCardModel itself.
struct ReleaseCardState: Equatable, Hashable {
    // MARK: - Sentinels for unset optional fields
    //
    // What `snapshot()` records for an optional field whose has-value flag is false, in place
    // of the placeholder the model carries. Constants are the point: two states with the field
    // unset must compare equal no matter what each placeholder had drifted to. The values are
    // ones no real field can hold, so a sentinel can never be mistaken for data.
    static let unsetYear = 0
    static let unsetDate = Date.distantPast

    let id: UUID
    var studio: String
    var releaseYear: Int
    var hasReleaseYear: Bool
    var releaseMonthDay: ReleaseMonthDay?
    var baseReleaseYear: Int
    var hasBaseReleaseYear: Bool
    var purchased: Bool
    var wishlist: Int  // position (0 = not on wishlist, ≥1 = display order)
    var format: String
    var includedVersions: [String]
    var independence: String
    var videoFormat: String
    var releaseAspectRatio: [String]
    var scanningMethod: String
    var audioFormat: String
    var audioChannels: String
    var hasSubtitles: Bool
    var numberOfDiscs: Int
    var discMultiPack: Bool
    var hasArtwork: String
    var remastered: Bool
    var nationalOrigin: String
    var replicationType: String
    var discCapacity: [String]
    var hasHDR: String
    var masterType: String
    var regionLock: String
    var regionLockBypass: Bool
    var marketAvailability: [String]
    var numberOfCopies: Int
    var cost: Double
    var amountSpent: Double
    var purchaseDate: Date
    var hasPurchaseDate: Bool
    var lowestPrice: Double
    var lowestPriceDate: Date
    var hasLowestPriceDate: Bool
    var condition: String
    var notes: String
    var sortOrder: Int
    let dateAdded: Date

    // MARK: - Diagnostics
    /// Names every field in which this state differs from `other`.
    ///
    /// Exists to make `checkForChanges()` explainable: it answers "is this card dirty?" with a
    /// Bool, which is useless when the Update button disagrees with what the user believes they
    /// did.
    ///
    /// Walks the stored properties reflectively, so the field set is defined in one place and a new field is
    /// compared automatically. `Mirror` yields them in declaration order, and `id` and `dateAdded` are immutable
    /// and skipped.
    ///
    /// Reflection is slow, and this is the one place in the file where that is acceptable: it
    /// runs only inside the `Logger.isLoggingEnabled` guard in `checkForChanges`, on a path
    /// that already pays a second `snapshot()` per release.
    ///
    /// Values are compared as `AnyHashable`, which covers every type the state carries today.
    /// The `String(describing:)` fallback is what keeps a future non-Hashable field from
    /// silently comparing equal to itself and vanishing from the log.
    func differingFields(from other: ReleaseCardState) -> [String] {
        var fields: [String] = []
        for (mine, theirs) in zip(Mirror(reflecting: self).children,
                                  Mirror(reflecting: other).children) {
            guard let name = mine.label, name != "id", name != "dateAdded" else { continue }
            let differs: Bool
            if let lhs = mine.value as? AnyHashable, let rhs = theirs.value as? AnyHashable {
                differs = lhs != rhs
            } else {
                differs = String(describing: mine.value) != String(describing: theirs.value)
            }
            if differs {
                fields.append(Self.valueOmittedFields.contains(name)
                              ? name
                              : "\(name) (\(mine.value) ≠ \(theirs.value))")
            }
        }
        return fields
    }

    /// Fields named without their values.
    ///
    /// `notes` is free prose the user is typing: printing both sides put a copy of the whole
    /// field in the log, and — because the text differs on every keystroke — made the line
    /// itself different every tick, so `checkForChanges`'s repeat-suppression never matched
    /// and each edit would emit its own "Releases dirty" entry.
    ///
    /// The diagnostic's job is to name WHICH field is dirty when the user believes they
    /// reverted everything; for a text field the name alone answers that, and the constant
    /// line collapses the repeats into one.
    private static let valueOmittedFields: Set<String> = ["notes"]
}

// MARK: - ReleaseConfirmationController
//
// Sole owner of the Releases tab's confirmation-alert state — the presentation flag and the
// pending payload — and its presenter: an NSAlert sheet on the key window (the FilmSheet's).
// Not @Observable: nothing renders from this state, and the navigation guards read
// `isPresented` from event monitors and closures, never from a view body. The callback API
// means a caller hands over two closures and gets no shared state back.
//
// WHY NSAlert, NOT SwiftUI's `.alert`. In a timed comparison on the real library, NSAlert reached the screen
// sooner with less main-thread work, and animation and dismissal were identical.
// It also needs no zero-size host view and no binding to keep the two from both presenting.
//
// Return does not confirm: the confirm button is destructive, and macOS gives a destructive
// button no Return key equivalent (SwiftUI's `.alert` behaved the same). Escape cancels.
@MainActor
final class ReleaseConfirmationController: Loggable {
    nonisolated static let logTag = "[ReleaseConfirmationController]"

    /// One raised confirmation. Exactly one of `onConfirm` / `onCancel` runs, and the
    /// payload is discarded immediately afterward.
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmTitle: String
        /// Whether the confirm button destroys something, which is a property of the ACTION
        /// and so travels with the payload rather than being decided by the presenter, which
        /// maps it to the confirm button's `hasDestructiveAction`.
        ///
        /// Defaults nowhere — every call site states it, so a confirmation added later cannot
        /// inherit destructive styling by accident.
        let isDestructive: Bool
        let onConfirm: @MainActor () -> Void
        let onCancel: @MainActor () -> Void
    }

    /// Payload for the alert, taken and cleared by `resolve`.
    var pending: Pending?

    /// Whether a confirmation is up. Every navigation route consults it through
    /// `isConfirmationPresented`, so the carousel stays inert under the alert.
    var isPresented = false

    /// Raises a confirmation. Callers are responsible for rejecting re-entrant requests;
    /// this method assumes it has been called only when nothing is currently presented.
    func present(title: String,
                 message: String,
                 confirmTitle: String,
                 isDestructive: Bool,
                 onConfirm: @escaping @MainActor () -> Void,
                 onCancel: @escaping @MainActor () -> Void) {
        pending = Pending(title: title,
                          message: message,
                          confirmTitle: confirmTitle,
                          isDestructive: isDestructive,
                          onConfirm: onConfirm,
                          onCancel: onCancel)
        isPresented = true

        // The NSAlert needs a key window to attach to. Leaving `isPresented` true with no
        // window to show it on would strand the tab — every later request is refused as
        // re-entrant (see the callers' "nothing currently presented" guards), and every
        // control gated on isConfirmationPresented (arrow keys, swipes, add, delete) goes
        // inert for the rest of the sheet. Declining is the safe outcome for any of these
        // actions (see onCancel above), so resolve as canceled.
        guard let window = NSApp.keyWindow else {
            Self.log("WARNING: No key window to present release confirmation on — declining the action")
            let onCancel = pending?.onCancel
            pending = nil
            isPresented = false
            onCancel?()
            return
        }
        presentNSAlert(on: window)
    }

    // MARK: - AppKit presentation
    //
    // Matches the app's other alerts (SwiftUI's `.alert` is an NSAlert underneath) — same
    // style, same icon, same button order:
    //
    //   • `messageText` / `informativeText` are the title and message.
    //   • `.warning` is NSAlert's default style, and is what puts the app icon in the corner.
    //   • BUTTON ORDER IS BY POSITION, NOT BY DECLARATION. NSAlert lays buttons out
    //     right-to-left in the order added, so the confirm button is added FIRST to land
    //     rightmost, and Cancel second to sit to its left. (Being destructive, the confirm
    //     button gets no Return key equivalent — see the type's header.)
    //   • Escape is bound explicitly rather than relying on NSAlert's convention of granting it
    //     to a button titled "Cancel", so a future retitling cannot silently drop it.
    private func presentNSAlert(on window: NSWindow) {
        guard let pending else { return }

        let alert = NSAlert()
        alert.messageText = pending.title
        alert.informativeText = pending.message
        alert.alertStyle = .warning
        let confirmButton = alert.addButton(withTitle: pending.confirmTitle)
        // The AppKit equivalent of SwiftUI's `role: .destructive` — red title on the confirm
        // button. Set on the button rather than the alert: NSAlert has no destructive style of
        // its own, the styling belongs to the one button that does the destroying.
        confirmButton.hasDestructiveAction = pending.isDestructive
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Cleared BEFORE resolving: `resolve` can run a callback that raises a second
                // confirmation, and it must find the presenter idle.
                self.isPresented = false
                self.resolve(confirmed: response == .alertFirstButtonReturn)
            }
        }
    }

    /// Runs the chosen callback and clears the payload. `pending` is taken and nilled BEFORE
    /// the callback runs, so a callback that raises a second confirmation (the delete flow
    /// can) finds the presenter genuinely idle.
    func resolve(confirmed: Bool) {
        guard let resolved = pending else { return }
        pending = nil
        if confirmed { resolved.onConfirm() } else { resolved.onCancel() }
    }
}

// MARK: - ReleaseChangeObserver
//
// Watches one ReleaseCardModel's `contentHash` and drives the two consequences of a field
// edit — scheduling a change check, and pushing locked fields onto combo-pack children — from
// outside the SwiftUI render path entirely.
//
// Keeping this out of the view tree means change detection does not depend on a card being mounted, and
// nothing here can invalidate a view.
//
// Two properties of `withObservationTracking` shape the code below:
//
//   * Tracking is one-shot, so the observer must re-arm to keep watching. `handleChange`
//     re-arms before doing any work, so mutations made by that work are observed too.
//   * `onChange` fires on willSet, before the new value is stored, so the observer hops to the
//     next main-actor turn to read it. That hop also coalesces a multi-field cascade into a
//     single notification.
//
// It also signals on equal-value writes, which `.onChange(of:)` filtered out; `lastHash`
// restores that filter. `lastHash` has a second duty: writes made while loading a film's
// releases would otherwise read as user edits — see rebaselineChangeObservers().
@MainActor
final class ReleaseChangeObserver {
    private let model: ReleaseCardModel
    // Weak: FSTabReleases owns this object, so a strong reference would be a cycle.
    private weak var viewModel: FSTabReleases?

    /// Last hash acted upon. Guards against the equal-value writes that Observation
    /// reports and `.onChange(of:)` did not.
    private var lastHash: Int

    /// Set when the model leaves the session. A pending hop may already be queued at that
    /// point, so this is checked on the way in as well as before re-arming.
    private var isCanceled = false

    init(model: ReleaseCardModel, viewModel: FSTabReleases) {
        self.model = model
        self.viewModel = viewModel
        // Placeholder, so `self` is fully initialized before armAndRead() — which needs a
        // live `self` for its onChange capture — may be called. Overwritten on the very
        // next line with the real baseline; nothing can observe the intermediate value.
        self.lastHash = 0
        self.lastHash = armAndRead()
    }

    /// Stops observing. Idempotent, and safe to call at teardown.
    func cancel() { isCanceled = true }

    /// Adopts the model's current state as the "unchanged" reference point, so writes made
    /// while populating models do not read as user edits. Deliberately does NOT re-arm: the
    /// existing registration is still live, or a queued reaction will re-arm on its way out.
    func rebaseline() { lastHash = model.contentHash }

    /// Registers the subscription AND returns the hash the registering read produced.
    ///
    /// `contentHash` reads every mutable field through Observation's registrar. Reading it once, inside the
    /// tracking closure, both registers the subscription and yields the value. That keeps this, the hottest
    /// repeated path in the tab, from paying for a second traversal.
    ///
    /// Read INSIDE the closure deliberately: that is the same read that registers, so the hash
    /// and the registration describe the same state.
    private func armAndRead() -> Int {
        // Canceled: no registration, but still report the model's current hash so callers
        // need no second path. `handleChange` guards on isCanceled before it gets here, so
        // in practice this arm is reachable only from init, which is never canceled.
        guard !isCanceled else { return model.contentHash }
        var hash = 0
        withObservationTracking {
            // The read that registers the subscription. `contentHash` touches every
            // mutable field, so this registers all of them — which is the intent here,
            // unlike in a view body where it would defeat per-property invalidation.
            hash = model.contentHash
        } onChange: { [weak self] in
            // Fires on willSet, so the new value is not stored yet — the hop to the next
            // main-actor turn is what makes handleChange's read valid, and it keeps this
            // Sendable-clean since only a weak reference to a @MainActor class crosses.
            // The capture list is on the outer closure only; `self` is already Optional here.
            Task { @MainActor in
                self?.handleChange()
            }
        }
        return hash
    }

    private func handleChange() {
        guard !isCanceled, let viewModel else { return }

        // Re-arms BEFORE any of the work below, so a write performed by that work lands
        // inside a live registration rather than in a gap and no change can be missed —
        // and yields the post-write hash in the same traversal. See armAndRead.
        let newHash = armAndRead()

        // Observation signals equal-value writes too, so this comparison is the filter. It is also what makes
        // rebaseline() work: once
        // FSTabReleases has advanced the baselines past the load, every reaction already
        // queued from the load lands here and returns.
        guard newHash != lastHash else { return }
        lastHash = newHash

        viewModel.scheduleChangeCheckDebounced()

        // Real-time push of the locked fields onto this parent's children. Guarded on
        // `isComboChild` as well as format so a child can never re-enter the sync and
        // start a cycle; `syncComboChildFields` is condition-gated per field, so a sync
        // that changes nothing produces no writes and therefore no further notifications.
        if model.is4K && !model.isComboChild && !model.childReleaseIDs.isEmpty {
            viewModel.syncComboChildFields(from: model)
        }
    }
}
