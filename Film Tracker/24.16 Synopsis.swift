// MARK: - Synopsis.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Synopsis module (module 05) in RightSidebar's Details tab, showing the film's description.

import SwiftUI

struct Synopsis: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
            // Title.
            RSBHelpers.moduleHeader("Synopsis")
            // Content.
            if let film = film {
                // Single column with no title, since the module header is enough.
                RSBHelpers.textSection(
                    title: "", value: film.descriptionText,
                    rowFontSize: RSBHelpers.rowFontSize + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
