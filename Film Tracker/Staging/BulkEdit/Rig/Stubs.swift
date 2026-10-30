// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Stand-ins for the two app types BulkFilmEdit names, copied from the app. run.sh checks
// that their literals still match 29.00 FilmQueue.swift and 61.00 FilmObj.swift, so a
// change there fails the rig instead of passing it against stale copies.

import Foundation

enum FilmQueueSection: String, CaseIterable, Hashable, Sendable {
    case upNext = "Up Next"
    case soon   = "Soon"
    case later  = "Later"

    var listID: UUID {
        switch self {
        case .upNext: return UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000001")!
        case .soon:   return UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000002")!
        case .later:  return UUID(uuidString: "F1E2D3C4-B5A6-4788-9900-000000000003")!
        }
    }
}

enum FilmSpecialSorting {
    static let waitingForEdit      = "Waiting for edit"
    static let temporarilyOnHold   = "Temporarily on hold"
    static let indefinitelyOnHold  = "Indefinitely on hold"
    static let ignore              = "Ignore"
    static let blacklisted         = "Blacklisted"
    static let independentOptions = [waitingForEdit, temporarilyOnHold]
    static let exclusiveOptions = [indefinitelyOnHold, ignore, blacklisted]
    static let canonicalOrder = independentOptions + exclusiveOptions
}
