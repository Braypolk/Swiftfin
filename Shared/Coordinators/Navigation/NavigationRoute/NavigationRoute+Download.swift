//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension NavigationRoute {

    // MARK: - Download Library

    static let downloadLibrary = NavigationRoute(
        id: "downloadLibrary"
    ) {
        #if os(iOS)
        DownloadPagingLibraryView()
        #else
        EmptyView()
        #endif
    }

    // MARK: - Download Item

    #if os(iOS)
    static func downloadItem(item: DownloadItemDto) -> NavigationRoute {
        NavigationRoute(
            id: "downloadItem-\(item.id)"
        ) {
            DownloadItemView(item: item)
        }
    }
    #endif

    // MARK: - Download Queue

    static let downloadQueue = NavigationRoute(
        id: "downloadQueue",
        style: .sheet
    ) {
        #if os(iOS)
        NavigationView {
            DownloadQueueView(viewModel: DownloadPagingLibraryViewModel())
        }
        #else
        EmptyView()
        #endif
    }
}
