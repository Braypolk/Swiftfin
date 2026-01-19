//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import Logging
import SwiftUI

extension ItemView {

    struct PlayButton<ViewModel: ItemViewModelProtocol>: View {

        @Default(.accentColor)
        private var accentColor

        @Router
        private var router

        @ObservedObject
        var viewModel: ViewModel

        private let onPlay: (() -> Void)?

        private let logger = Logger.swiftfin()

        init(
            viewModel: ViewModel,
            onPlay: (() -> Void)? = nil
        ) {
            self.viewModel = viewModel
            self.onPlay = onPlay
        }

        // MARK: - Validation

        private var isEnabled: Bool {
            if onPlay != nil { return true }
            return viewModel.selectedMediaSource != nil
        }

        // MARK: - Title

        private var title: String {
            /// Use the Season/Episode label for the Series ItemView
            if viewModel.item.type == .series,
                let seriesViewModel = viewModel as? SeriesViewModelProtocol,
                let seasonEpisodeLabel = seriesViewModel.playButtonItem?
                    .seasonEpisodeLabel
            {
                return seasonEpisodeLabel

                /// Use a Play/Resume label for single Media Source items that are not Series
            } else if let playButtonLabel = viewModel.playButtonItem?
                .playButtonLabel
            {
                return playButtonLabel

                /// Fallback to a generic `Play` label
            } else {
                return L10n.play
            }
        }

        // MARK: - Media Source

        private var source: String? {
            guard let sourceLabel = viewModel.selectedMediaSource?.displayTitle,
                viewModel.item.mediaSources?.count ?? 0 > 1
            else {
                return nil
            }

            return sourceLabel
        }

        // MARK: - Body

        var body: some View {
            Button {
                play()
            } label: {
                HStack {
                    Image(systemName: "play.fill")

                    VStack {
                        Text(title)

                        if let source {
                            Marquee(source, speed: 40, delay: 3, fade: 5)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .font(.callout)
                .fontWeight(.semibold)
            }
            .buttonStyle(
                .tintedMaterial(
                    tint: accentColor,
                    foregroundColor: accentColor.overlayColor
                )
            )
            .contextMenu {
                if viewModel.playButtonItem?.userData?.playbackPositionTicks
                    != 0
                {
                    Button(L10n.playFromBeginning, systemImage: "gobackward") {
                        play(fromBeginning: true)
                    }
                }
            }
            .isSelected(true)
            .enabled(isEnabled)
        }

        // MARK: - Play Content

        private func play(fromBeginning: Bool = false) {
            if let onPlay {
                // TODO: handle fromBeginning for offline if needed?
                // For now the simple closure is what we have.
                // The offline view usually handles its own playback logic including resume/reset.
                onPlay()
                return
            }

            guard let playButtonItem = viewModel.playButtonItem,
                let selectedMediaSource = viewModel.selectedMediaSource
            else {
                logger.error("Play selected with no item or media source")
                return
            }

            let queue: (any MediaPlayerQueue)? = {
                if playButtonItem.type == .episode {
                    return EpisodeMediaPlayerQueue(episode: playButtonItem)
                }
                return nil
            }()

            let provider = MediaPlayerItemProvider(item: playButtonItem) {
                item in
                try await MediaPlayerItem.build(
                    for: item,
                    mediaSource: selectedMediaSource
                ) {
                    if fromBeginning {
                        $0.userData?.playbackPositionTicks = 0
                    }
                }
            }

            router.route(
                to: .videoPlayer(
                    provider: provider,
                    queue: queue
                )
            )
        }
    }
}

extension ItemView.PlayButton where ViewModel == ItemViewModel {
    init(viewModel: ItemViewModel) {
        self.init(viewModel: viewModel, onPlay: nil)
    }
}
