//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import JellyfinAPI
import SwiftUI

struct DownloadItemView: View {

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    @Router
    private var router

    let item: StoredDownloadItem

    @StateObject
    private var viewModel: DownloadItemViewModel

    @State
    private var showingDeleteConfirmation = false

    @Default(.Customization.itemViewType)
    private var itemViewType

    init(item: StoredDownloadItem) {
        self.item = item
        self._viewModel = StateObject(wrappedValue: DownloadItemViewModel(storedItem: item))
    }

    var body: some View {
        downloadScrollView(item: item, viewModel: viewModel) {
            scrollContentView
        }
        .navigationTitle(item.item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.isDeleted) { isDeleted in
            if isDeleted {
                router.dismiss()
            }
        }
    }

    @ViewBuilder
    private var scrollContentView: some View {
        switch item.type {
        case .movie:
            ItemView.MovieItemContentView(viewModel: viewModel)
        case .series:
            ItemView.SeriesItemContentView(viewModel: viewModel)
        case .episode, .musicVideo, .video:
            ItemView.SimpleItemContentView(viewModel: viewModel)
        default:
            ItemView.SimpleItemContentView(viewModel: viewModel)
        }
    }

    private func downloadScrollView<Content: View>(
        item: StoredDownloadItem,
        viewModel: DownloadItemViewModel,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if UIDevice.isPad {
            return AnyView(DownloadItemView.DownloadiPadOSCinematicScrollView(viewModel: viewModel, content: content))
        }

        switch item.type {
        case .movie, .series:
            switch itemViewType {
            case .compactPoster:
                return AnyView(DownloadItemView.DownloadCompactPosterScrollView(viewModel: viewModel, content: content))
            case .compactLogo:
                return AnyView(DownloadItemView.DownloadCompactLogoScrollView(viewModel: viewModel, content: content))
            case .cinematic:
                return AnyView(DownloadItemView.DownloadCinematicScrollView(viewModel: viewModel, content: content))
            }
        case .person, .musicArtist:
            return AnyView(DownloadItemView.DownloadCompactPosterScrollView(viewModel: viewModel, content: content))
        default:
            return AnyView(DownloadItemView.DownloadSimpleScrollView(viewModel: viewModel, content: content))
        }
    }
}
