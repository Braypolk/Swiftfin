//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

extension DownloadItemView {

    struct DownloadCinematicScrollView<Content: View>: View {

        @Default(.Customization.CinematicItemViewType.usePrimaryImage)
        private var usePrimaryImage

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

        private var imageType: ImageType {
            usePrimaryImage ? .primary : .backdrop
        }

        @ViewBuilder
        private var headerView: some View {
            let bottomColor = viewModel.item.blurHash(for: imageType)?.averageLinearColor ?? Color.secondarySystemFill

            GeometryReader { proxy in
                if proxy.size.height.isZero { EmptyView() }
                else {
                    ImageView(viewModel.downloadItem.imageSource(
                        imageType,
                        maxWidth: usePrimaryImage ? proxy.size.width : 0,
                        maxHeight: usePrimaryImage ? 0 : proxy.size.height * 0.6
                    ))
                    .aspectRatio(usePrimaryImage ? (2 / 3) : 1.77, contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height * 0.6)
                    .bottomEdgeGradient(bottomColor: bottomColor)
                }
            }
        }

        var body: some View {
            ItemView.OffsetScrollView(heightRatio: 0.75) {
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
                                (location: 1, opacity: 1)
                            }
                    }
            } content: {
                content
                    .padding(.top, 10)
                    .edgePadding(.bottom)
            }
        }
    }
}

extension DownloadItemView.DownloadCinematicScrollView {

    struct OverlayView: View {

        @Default(.Customization.CinematicItemViewType.usePrimaryImage)
        private var usePrimaryImage

        @StoredValue(.User.itemViewAttributes)
        private var attributes

        @Router
        private var router
        @ObservedObject
        var viewModel: DownloadItemViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .center, spacing: 10) {
                    if !usePrimaryImage {
                        let logoImageSource = viewModel.downloadItem.imageSource(.logo)
                        if logoImageSource.url != nil {
                            ImageView(logoImageSource)
                                .placeholder { _ in
                                    EmptyView()
                                }
                                .failure {
                                    MaxHeightText(text: viewModel.item.displayTitle, maxHeight: 100)
                                        .font(.largeTitle.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.white)
                                }
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 100, alignment: .bottom)
                        } else {
                            MaxHeightText(text: viewModel.item.displayTitle, maxHeight: 100)
                                .font(.largeTitle.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                        }
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
                .frame(maxWidth: .infinity)

                ItemView.OverviewView(item: viewModel.item)
                    .overviewLineLimit(3)
                    .taglineLineLimit(2)
                    .foregroundColor(.white)

                ItemView.AttributesHStack(
                    attributes: attributes,
                    viewModel: viewModel,
                    alignment: .center
                )
            }
        }
    }
}
