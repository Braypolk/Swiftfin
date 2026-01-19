//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension ItemView {

    struct CompactLogoScrollView<
        Content: View,
        ViewModel: ItemViewModelProtocol
    >: ScrollContainerView {

        @Router
        private var router

        @ObservedObject
        private var viewModel: ViewModel

        private let content: Content
        private let onPlay: (() -> Void)?
        private let onTogglePlayed: () -> Void
        private let onToggleFavorite: () -> Void

        init(
            viewModel: ViewModel,
            onPlay: (() -> Void)? = nil,
            onTogglePlayed: @escaping () -> Void = {},
            onToggleFavorite: @escaping () -> Void = {},
            content: @escaping () -> Content
        ) {
            self.content = content()
            self.viewModel = viewModel
            self.onPlay = onPlay
            self.onTogglePlayed = onTogglePlayed
            self.onToggleFavorite = onToggleFavorite
        }

        @ViewBuilder
        private var headerView: some View {

            let bottomColor =
                viewModel.item.blurHash(for: .backdrop)?.averageLinearColor
                ?? Color.secondarySystemFill

            GeometryReader { proxy in
                ImageView(viewModel.item.imageSource(.backdrop, maxWidth: 1320))
                    .aspectRatio(1.77, contentMode: .fill)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height * 0.70,
                        alignment: .top
                    )
                    .bottomEdgeGradient(bottomColor: bottomColor)
            }
        }

        var body: some View {
            OffsetScrollView(heightRatio: 0.5) {
                headerView
            } overlay: {
                OverlayView(
                    viewModel: viewModel,
                    onPlay: onPlay,
                    onTogglePlayed: onTogglePlayed,
                    onToggleFavorite: onToggleFavorite
                )
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

extension ItemView.CompactLogoScrollView where ViewModel == ItemViewModel {
    init(
        viewModel: ItemViewModel,
        content: @escaping () -> Content
    ) {
        self.init(
            viewModel: viewModel,
            onPlay: nil,
            onTogglePlayed: { viewModel.send(.toggleIsPlayed) },
            onToggleFavorite: { viewModel.send(.toggleIsFavorite) },
            content: content
        )
    }
}

extension ItemView.CompactLogoScrollView {

    struct OverlayView: View {

        @StoredValue(.User.itemViewAttributes)
        private var attributes

        @Router
        private var router

        @ObservedObject
        var viewModel: ViewModel
        var onPlay: (() -> Void)?
        var onTogglePlayed: () -> Void
        var onToggleFavorite: () -> Void

        var body: some View {
            VStack(alignment: .center, spacing: 10) {
                ImageView(viewModel.item.imageURL(.logo, maxHeight: 70))
                    .placeholder { _ in
                        EmptyView()
                    }
                    .failure {
                        MaxHeightText(
                            text: viewModel.item.displayTitle,
                            maxHeight: 70
                        )
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                    }
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 70, alignment: .bottom)

                DotHStack {
                    if let firstGenre = viewModel.item.genres?.first {
                        Text(firstGenre)
                    }

                    if let premiereYear = viewModel.item.premiereDateYear {
                        Text(premiereYear)
                    }

                    if let playButtonitem = viewModel.playButtonItem,
                        let runtime = playButtonitem.runTimeLabel
                    {
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

                    if viewModel.item.presentPlayButton {
                        ItemView.PlayButton(
                            viewModel: viewModel,
                            onPlay: onPlay
                        )
                        .frame(height: 50)
                    }

                    ItemView.ActionButtonHStack(
                        viewModel: viewModel,
                        onTogglePlayed: onTogglePlayed,
                        onToggleFavorite: onToggleFavorite
                    )
                    .foregroundStyle(.white)
                    .frame(height: 50)
                }
                .frame(maxWidth: 300)
            }
        }
    }
}
