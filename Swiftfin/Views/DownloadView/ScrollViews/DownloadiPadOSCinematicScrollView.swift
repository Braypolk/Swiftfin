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

    struct DownloadiPadOSCinematicScrollView<Content: View>: View {

        let item: DownloadItemDto
        @ObservedObject
        var viewModel: DownloadItemViewModel

        @State
        private var globalSize: CGSize = .zero

        private let content: Content

        init(
            item: DownloadItemDto,
            viewModel: DownloadItemViewModel,
            @ViewBuilder content: () -> Content
        ) {
            self.item = item
            self.viewModel = viewModel
            self.content = content()
        }

        private var imageType: ImageType {
            switch item.type {
            case .episode, .musicVideo, .video:
                .primary
            default:
                .backdrop
            }
        }

        @ViewBuilder
        private var headerView: some View {
            let bottomColor = Color.secondarySystemFill
            let imageSource = item.imageSource(imageType, maxWidth: 1920)

            ImageView(imageSource)
                .aspectRatio(1.77, contentMode: .fill)
                .bottomEdgeGradient(bottomColor: bottomColor)
        }

        var body: some View {
            ItemView.OffsetScrollView(
                heightRatio: globalSize.isLandscape ? 0.75 : 0.5
            ) {
                headerView
            } overlay: {
                OverlayView(item: item, viewModel: viewModel)
                    .edgePadding()
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
            .trackingSize($globalSize)
        }
    }
}

extension DownloadItemView.DownloadiPadOSCinematicScrollView {

    struct OverlayView: View {

        @StoredValue(.User.itemViewAttributes)
        private var attributes

        @Router
        private var router

        let item: DownloadItemDto
        @ObservedObject
        var viewModel: DownloadItemViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .center, spacing: 10) {
                    let logoImageSource = item.imageSource(.logo)
                    if logoImageSource.url != nil {
                        ImageView(logoImageSource)
                            .placeholder { _ in
                                EmptyView()
                            }
                            .failure {
                                MaxHeightText(text: item.displayTitle, maxHeight: 100)
                                    .font(.largeTitle.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                            }
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 100, alignment: .bottom)
                    } else {
                        MaxHeightText(text: item.displayTitle, maxHeight: 100)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                    }

                    DotHStack {
                        if let firstGenre = item.genres?.first {
                            Text(firstGenre)
                        }

                        if let premiereYear = item.premiereDateYear {
                            Text(premiereYear)
                        }

                        if let runtime = item.runTimeLabel {
                            Text(runtime)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(Color(UIColor.lightGray))
                    .padding(.horizontal)

                    Group {
                        if item.mediaURL != nil {
                            DownloadItemView.DownloadPlayButton(item: item)
                                .frame(height: 50)
                        }

                        DownloadItemView.DownloadActionButtonHStack(item: item)
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
                    alignment: .leading
                )
            }
        }
    }
}
