//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension DownloadItemView {

    struct DownloadSimpleScrollView<Content: View>: View {

        @StoredValue(.User.itemViewAttributes)
        private var attributes

        @Router
        private var router

        @ObservedObject
        private var viewModel: DownloadItemViewModel
        private let content: Content

        init(
            viewModel: DownloadItemViewModel,
            @ViewBuilder content: () -> Content
        ) {
            self.viewModel = viewModel
            self.content = content()
        }

        // TODO: remove and just use `PosterImage` with landscape
        //       after poster environment implemented
        private var imageType: ImageType {
            switch viewModel.item.type {
            case .episode, .musicVideo, .video:
                .primary
            default:
                .backdrop
            }
        }

        @ViewBuilder
        private var shelfView: some View {
            VStack(alignment: .center, spacing: 10) {
                if let parentTitle = viewModel.item.parentTitle {
                    Text(parentTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal)
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text(viewModel.item.displayTitle)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    // Show progress badge for seasons/series
                    if let progress = viewModel.downloadProgress {
                        Text("\(progress.downloaded)/\(progress.total)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal)

                DotHStack {
                    if let seasonEpisodeLabel = viewModel.item.seasonEpisodeLabel {
                        Text(seasonEpisodeLabel)
                    }

                    if let productionYear = viewModel.item.premiereDateYear {
                        Text(productionYear)
                    }

                    if let runtime = viewModel.item.runTimeLabel {
                        Text(runtime)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

                Group {
                    ItemView.AttributesHStack(
                        attributes: attributes,
                        viewModel: viewModel,
                        alignment: .center
                    )

                    if viewModel.downloadItem.mediaURL != nil {
                        DownloadItemView.DownloadPlayButton(item: viewModel.downloadItem)
                            .frame(height: 50)
                    }

                    DownloadItemView.DownloadActionButtonHStack(item: viewModel.downloadItem)
                        .frame(height: 50)
                }
                .frame(maxWidth: 300)
            }
        }

        @ViewBuilder
        private var header: some View {
            VStack(alignment: .center) {
                ZStack {
                    Rectangle()
                        .fill(.complexSecondary)

                    ImageView(viewModel.downloadItem.imageSource(imageType, maxWidth: 600))
                        .failure {
                            SystemImageContentView(systemName: viewModel.item.systemImage)
                        }
                }
                .frame(maxHeight: 300)
                .posterStyle(.landscape)
                .posterShadow()
                .padding(.horizontal)

                shelfView
            }
        }

        var body: some View {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {

                    header

                    ItemView.OverviewView(item: viewModel.item)
                        .overviewLineLimit(4)
                        .padding(.horizontal)

                    RowDivider()

                    content
                        .edgePadding(.bottom)
                }
            }
        }
    }
}
