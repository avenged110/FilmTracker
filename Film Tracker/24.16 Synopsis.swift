// MARK: - Synopsis.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's modular "Details" tab, module 05.

import SwiftUI

struct Synopsis: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
            // Title.
            RSBHelpers.moduleHeader("Synopsis")
            // Content.
            if let film = film {
                // Single column section: "Synopsis" (no title — module header is sufficient).
                RSBHelpers.textSection(
                    title: "", value: film.descriptionText,
                    rowFontSize: RSBHelpers.rowFontSize + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
