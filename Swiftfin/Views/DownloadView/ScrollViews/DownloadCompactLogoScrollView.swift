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

    struct DownloadCompactLogoScrollView<Content: View>: View {

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

        @ViewBuilder
        private var headerView: some View {
            let bottomColor = viewModel.item.blurHash(for: .backdrop)?.averageLinearColor ?? Color.secondarySystemFill

            GeometryReader { proxy in
                ImageView(viewModel.downloadItem.imageSource(.backdrop, maxWidth: 1320))
                    .aspectRatio(1.77, contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height * 0.70, alignment: .top)
                    .bottomEdgeGradient(bottomColor: bottomColor)
            }
        }

        var body: some View {
            ItemView.OffsetScrollView(heightRatio: 0.5) {
                headerView
            } overlay: {
                OverlayView(viewModel: viewModel)
                    .edgePadding(.horizontal)
                    .edgePadding(.bottom)
                    .frame(maxWidth: .infinity)
                    .background {
                        BlurView(style: .systemThinMaterialDark)
                            .maskLinearGradient {
                                (location: 0, opacity: 0)
                                (location: 0.3, opacity: 1)
                            }
                    }
            } content: {
                SeparatorVStack(alignment: .leading) {
                    RowDivider()
                        .padding(.vertical, 10)
                } content: {
                    ItemView.OverviewView(item: viewModel.item)
                        .overviewLineLimit(4)
                        .taglineLineLimit(2)
                        .edgePadding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    content
                }
                .edgePadding(.vertical)
            }
        }
    }
}

extension DownloadItemView.DownloadCompactLogoScrollView {

    struct OverlayView: View {

        @StoredValue(.User.itemViewAttributes)
        private var attributes

        @Router
        private var router
        @ObservedObject
        var viewModel: DownloadItemViewModel

        var body: some View {
            VStack(alignment: .center, spacing: 10) {
                let logoImageSource = viewModel.downloadItem.imageSource(.logo)
                if logoImageSource.url != nil {
                    ImageView(logoImageSource)
                        .placeholder { _ in
                            EmptyView()
                        }
                        .failure {
                            MaxHeightText(text: viewModel.item.displayTitle, maxHeight: 70)
                                .font(.largeTitle.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                        }
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 70, alignment: .bottom)
                } else {
                    MaxHeightText(text: viewModel.item.displayTitle, maxHeight: 70)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                }

                DotHStack {
                    if let firstGenre = viewModel.item.genres?.first {
                        Text(firstGenre)
                    }

                    if let premiereYear = viewModel.item.premiereDateYear {
                        Text(premiereYear)
                    }

                    if let playButtonitem = viewModel.playButtonItem, let runtime = playButtonitem.runTimeLabel {
                        Text(runtime)
                    }
                }
                .font(.caption)
                .foregroundColor(Color(UIColor.lightGray))
                .padding(.horizontal)

                Group {
                    ItemView.AttributesHStack(
                        attributes: attributes,
                        viewModel: viewModel
                    )

                    if viewModel.downloadItem.mediaURL != nil {
                        DownloadItemView.DownloadPlayButton(item: viewModel.downloadItem)
                            .frame(height: 50)
                    }

                    DownloadItemView.DownloadActionButtonHStack(item: viewModel.downloadItem)
                        .foregroundStyle(.white)
                        .frame(height: 50)
                }
                .frame(maxWidth: 300)
            }
        }
    }
}
