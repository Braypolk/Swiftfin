//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import CollectionVGrid
import SwiftUI

// MARK: - CollectionVGrid Layout Helpers

extension LibraryDisplayType {

    /// Returns the appropriate CollectionVGrid layout for phone devices
    static func phoneCollectionLayout(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType
    ) -> CollectionVGridLayout {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            .columns(2)
        case (.portrait, .grid):
            .columns(3)
        case (.square, .grid):
            .columns(3)
        case (_, .list):
            .columns(1, insets: .zero, itemSpacing: 0, lineSpacing: 0)
        }
    }

    /// Returns the appropriate CollectionVGrid layout for pad devices
    static func padCollectionLayout(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType,
        listColumnCount: Int
    ) -> CollectionVGridLayout {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            .minWidth(200)
        case (.portrait, .grid), (.square, .grid):
            .minWidth(150)
        case (_, .list):
            .columns(listColumnCount, insets: .zero, itemSpacing: 0, lineSpacing: 0)
        }
    }
}

// MARK: - LazyVGrid Layout Helpers

extension LibraryDisplayType {

    /// Returns the appropriate LazyVGrid columns for phone devices
    static func phoneGridItems(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType
    ) -> [GridItem] {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        case (.portrait, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        case (.square, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        case (_, .list):
            return [GridItem(.flexible(), spacing: 0)]
        }
    }

    /// Returns the appropriate LazyVGrid columns for pad devices
    static func padGridItems(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType,
        listColumnCount: Int
    ) -> [GridItem] {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            return [GridItem(.adaptive(minimum: 200), spacing: 8)]
        case (.portrait, .grid), (.square, .grid):
            return [GridItem(.adaptive(minimum: 150), spacing: 8)]
        case (_, .list):
            return Array(repeating: GridItem(.flexible(), spacing: 0), count: listColumnCount)
        }
    }
}
