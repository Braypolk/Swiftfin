//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import Factory
import JellyfinAPI
import SwiftUI

// TODO: The content/loading/error states are implemented as different CollectionHStacks because it was just easy.
//       A theoretically better implementation would be a single CollectionHStack with cards that represent the state instead.
extension SeriesEpisodeSelector {

    struct EpisodeHStack<ParentViewModel: SeriesViewModelProtocol>: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        @Injected(\.downloadManager)
        private var downloadManager: DownloadManager

        @Router
        private var router

        @State
        private var didScrollToPlayButtonItem = false

        @StateObject
        private var proxy = CollectionHStackProxy()

        let playButtonItem: BaseItemDto?
        let parentViewModel: ParentViewModel

        private func contentView(viewModel: SeasonItemViewModel) -> some View {
            CollectionHStack(
                uniqueElements: viewModel.elements,
                id: \.unwrappedIDHashOrZero,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { episode in
                if parentViewModel is DownloadItemViewModel {
                    SeriesEpisodeSelector.EpisodeCard(
                        episode: episode,
                        onPlay: {
                            playOffline(episode: episode)
                        },
                        onDetail: { namespace in
                            goToOfflineDetail(episode: episode, in: namespace)
                        }
                    )
                } else {
                    SeriesEpisodeSelector.EpisodeCard(
                        episode: episode,
                        onPlay: {
                            router.route(
                                to: .videoPlayer(
                                    item: episode,
                                    queue: EpisodeMediaPlayerQueue(
                                        episode: episode
                                    )
                                )
                            )
                        },
                        onDetail: { namespace in
                            router.route(
                                to: .item(item: episode),
                                in: namespace
                            )
                        }
                    )
                }
            }
            .clipsToBounds(false)
            .scrollBehavior(.continuousLeadingEdge)
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .proxy(proxy)
            .onFirstAppear {
                guard !didScrollToPlayButtonItem else { return }
                didScrollToPlayButtonItem = true

                // good enough?
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let playButtonItem else { return }

                    // Only scroll if it's not the first element to avoid alignment bugs
                    if viewModel.elements.first?.id != playButtonItem.id {
                        proxy.scrollTo(
                            id: playButtonItem.unwrappedIDHashOrZero,
                            animated: false
                        )
                    }
                }
            }
        }

        private func playOffline(episode: BaseItemDto) {
            guard
                let downloadedItem = downloadManager.downloadedEpisode(
                    for: episode
                )
            else {
                print("Failed to get downloaded episode")
                return
            }

            Task { @MainActor in
                do {
                    let playbackItem = try MediaPlayerItem.buildOffline(
                        for: downloadedItem
                    )
                    let manager = MediaPlayerManager(playbackItem: playbackItem)
                    router.route(to: .videoPlayer(manager: manager))
                } catch {
                    print("Failed to play offline episode: \(error)")
                }
            }
        }

        private func goToOfflineDetail(
            episode: BaseItemDto,
            in namespace: Namespace.ID
        ) {
            if let downloadedItem = downloadManager.downloadedEpisode(
                for: episode
            ) {
                router.route(
                    to: .downloadItem(item: downloadedItem),
                    in: namespace
                )
            }
        }

        var body: some View {
            switch viewModel.state {
            case .content:
                if viewModel.elements.isEmpty {
                    EmptyHStack()
                } else {
                    contentView(viewModel: viewModel)
                }
            case .error(let error):
                ErrorHStack(viewModel: viewModel, error: error)
            case .initial, .refreshing:
                LoadingHStack()
                    .task {
                        if viewModel.state == .initial {
                            viewModel.send(.refresh)
                        }
                    }
            }
        }
    }

    struct EmptyHStack: View {

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.EmptyCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    // TODO: better refresh design
    struct ErrorHStack: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        let error: ErrorMessage

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.ErrorCard(error: error) {
                    viewModel.send(.refresh)
                }
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    struct LoadingHStack: View {

        var body: some View {
            CollectionHStack(
                count: Int.random(in: 2..<5),
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.LoadingCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }
}
