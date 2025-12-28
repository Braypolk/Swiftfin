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

extension DownloadItemView {

    struct DownloadPlayButton: View {

        @Default(.accentColor)
        private var accentColor

        @Router
        private var router

        let item: DownloadItemDto

        private var title: String {
            if let progressLabel = item.progressLabel {
                return progressLabel
            } else {
                return L10n.play
            }
        }

        var body: some View {
            Button {
                playOfflineItem()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text(title)
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
                if item.playbackPositionTicks != nil, item.playbackPositionTicks != 0 {
                    Button(L10n.playFromBeginning, systemImage: "gobackward") {
                        playOfflineItem(fromBeginning: true)
                    }
                }
            }
            .isSelected(true)
        }

        private func playOfflineItem(fromBeginning: Bool = false) {
            Task { @MainActor in
                do {
                    let playbackItem = try MediaPlayerItem.buildOffline(for: item)
                    let manager = MediaPlayerManager(playbackItem: playbackItem)
                    router.route(to: .videoPlayer(manager: manager))
                } catch {
                    print("Failed to play offline item: \(error)")
                }
            }
        }
    }

    struct DownloadActionButtonHStack: View {

        @Injected(\.downloadManager)
        private var downloadManager: DownloadManager

        @Router
        private var router

        let item: DownloadItemDto
        private let equalSpacing: Bool

        @State
        private var showingDeleteConfirmation = false

        init(item: DownloadItemDto, equalSpacing: Bool = true) {
            self.item = item
            self.equalSpacing = equalSpacing
        }

        var body: some View {
            HStack(alignment: .center, spacing: 10) {

                if item.type == .movie || item.type == .episode || item.type == .video {
                    let isCheckmarkSelected = item.played

                    Button {
                        // TODO: Implement toggle played for downloaded items
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.tintedMaterial(tint: .jellyfinPurple, foregroundColor: .white))
                    .isSelected(isCheckmarkSelected)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                let isHeartSelected = item.isFavorite

                Button {
                    // TODO: Implement toggle favorite for downloaded items
                    // This would need to update the local metadata
                } label: {
                    Image(systemName: isHeartSelected ? "heart.fill" : "heart")
                }
                .buttonStyle(.tintedMaterial(tint: .red, foregroundColor: .white))
                .isSelected(isHeartSelected)
                .frame(maxWidth: .infinity)
                .if(!equalSpacing) { view in
                    view.aspectRatio(1, contentMode: .fit)
                }

                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.tintedMaterial(tint: .red, foregroundColor: .white))
                .frame(maxWidth: .infinity)
                .if(!equalSpacing) { view in
                    view.aspectRatio(1, contentMode: .fit)
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .labelStyle(.iconOnly)
            .confirmationDialog(
                "Delete Download",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    downloadManager.delete(itemID: item.id)
                    router.dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this download?")
            }
        }
    }

    struct DownloadAboutView: View {

        @ObservedObject
        var viewModel: DownloadItemViewModel

        var body: some View {
            ItemView.AboutView(viewModel: createDummyViewModel())
        }

        private func createDummyViewModel() -> ItemViewModel {
            // Create a minimal ItemViewModel for AboutView
            // AboutView only needs the item property
            let viewModel = ItemViewModel(item: viewModel.item)
            return viewModel
        }
    }

    /// Episode card for downloaded content that plays from local storage.
    struct DownloadEpisodeCard: View {

        @Injected(\.downloadManager)
        private var downloadManager: DownloadManager

        @Router
        private var router

        let episode: BaseItemDto

        @ViewBuilder
        private var overlayView: some View {
            if let progressLabel = episode.progressLabel {
                LandscapePosterProgressBar(
                    title: progressLabel,
                    progress: (episode.userData?.playedPercentage ?? 0) / 100
                )
            } else if episode.userData?.isPlayed ?? false {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear

                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: 30, height: 30, alignment: .bottomTrailing)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black)
                        .padding()
                }
            }
        }

        private var episodeContent: String {
            if episode.isUnaired {
                episode.airDateLabel ?? L10n.noOverviewAvailable
            } else {
                episode.overview ?? L10n.noOverviewAvailable
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Button {
                    playOffline()
                } label: {
                    ImageView(episode.imageSource(.primary, maxWidth: 250))
                        .failure {
                            SystemImageContentView(systemName: episode.systemImage)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            overlayView
                        }
                        .posterStyle(.landscape)
                        .posterShadow()
                }

                SeriesEpisodeSelector<DownloadItemViewModel>.EpisodeContent(
                    header: episode.displayTitle,
                    subHeader: episode.episodeLocator ?? .emptyDash,
                    content: episodeContent
                ) {
                    if let downloadedItem = downloadManager.downloadedEpisode(for: episode) {
                        router.route(to: .downloadItem(item: downloadedItem))
                    }
                }
            }
        }

        private func playOffline() {
            guard let downloadedItem = downloadManager.downloadedEpisode(for: episode) else {
                print("Failed to get downloaded episode")
                return
            }

            Task { @MainActor in
                do {
                    let playbackItem = try MediaPlayerItem.buildOffline(for: downloadedItem)
                    let manager = MediaPlayerManager(playbackItem: playbackItem)
                    router.route(to: .videoPlayer(manager: manager))
                } catch {
                    print("Failed to play offline episode: \(error)")
                }
            }
        }
    }
}
