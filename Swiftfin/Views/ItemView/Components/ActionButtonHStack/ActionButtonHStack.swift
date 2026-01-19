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

extension ItemView {

    struct ActionButtonHStack<ViewModel: ItemViewModelProtocol>: View {

        @Default(.accentColor)
        private var accentColor
        @Default(.Experimental.downloads)
        private var experimentalDownloads

        @StoredValue(.User.enabledTrailers)
        private var enabledTrailers: TrailerSelection

        @ObservedObject
        private var viewModel: ViewModel
        @ObservedObject
        private var downloadManager: DownloadManager

        @Injected(\.downloadQueueService)
        private var queueService: DownloadQueueService

        private let equalSpacing: Bool
        private let onTogglePlayed: () -> Void
        private let onToggleFavorite: () -> Void

        @State
        private var showingDownloadConfirmation = false

        @State
        private var episodeCount: Int?

        // MARK: - Has Trailers

        private var hasTrailers: Bool {
            if enabledTrailers.contains(.local),
                let itemViewModel = viewModel as? ItemViewModel,
                itemViewModel.localTrailers.isNotEmpty
            {
                return true
            }

            if enabledTrailers.contains(.external),
                viewModel.item.remoteTrailers?.isNotEmpty == true
            {
                return true
            }

            return false
        }

        // MARK: - Download Status

        private var downloadStatus: DownloadManager.DownloadItemStatus? {
            guard let itemID = viewModel.item.id else { return nil }
            return downloadManager.status(for: itemID)
        }

        private var downloadIcon: String {
            guard let status = downloadStatus else { return "arrow.down" }

            switch status.state {
            case .downloading: return "arrow.down.circle.fill"
            case .pending: return "clock"
            case .paused: return "pause.circle.fill"
            case .error: return "exclamationmark"
            case .complete: return "trash"
            case .cancelled: return "arrow.down"
            }
        }

        // MARK: - Download Button Actions

        private func handleDownloadButtonTap() {
            guard let status = downloadStatus else {
                // Check if this is a season or series that needs confirmation
                if viewModel.item.type == .season
                    || viewModel.item.type == .series
                {
                    // Fetch episode count for confirmation
                    Task {
                        await fetchEpisodeCount()
                        await MainActor.run {
                            showingDownloadConfirmation = true
                        }
                    }
                } else {
                    // Start download immediately for movies/episodes
                    downloadManager.queueItem(viewModel.item)
                }
                return
            }

            switch status.state {
            case .downloading, .pending:
                downloadManager.pause(itemID: viewModel.item.id ?? "")
            case .paused:
                downloadManager.resume(itemID: viewModel.item.id ?? "")
            case .error, .cancelled:
                downloadManager.retry(itemID: viewModel.item.id ?? "")
            case .complete:
                downloadManager.delete(itemID: viewModel.item.id ?? "")
            }
        }

        private func fetchEpisodeCount() async {
            guard let itemID = viewModel.item.id,
                let itemType = viewModel.item.type
            else { return }

            do {
                let count: Int
                if itemType == .season {
                    guard let seriesID = viewModel.item.seriesID else { return }
                    count = try await queueService.countEpisodesToDownload(
                        seasonID: itemID,
                        seriesID: seriesID
                    )
                } else if itemType == .series {
                    count = try await queueService.countEpisodesToDownload(
                        seriesID: itemID
                    )
                } else {
                    return
                }

                await MainActor.run {
                    episodeCount = count
                }
            } catch {
                // If fetching fails, proceed without count
                await MainActor.run {
                    episodeCount = nil
                }
            }
        }

        private func confirmDownload() {
            downloadManager.queueItem(viewModel.item)
            showingDownloadConfirmation = false
            episodeCount = nil
        }

        // MARK: - View Modifiers

        private func buttonFrame<Content: View>(
            @ViewBuilder content: () -> Content
        ) -> some View {
            content()
                .frame(maxWidth: .infinity)
                .if(!equalSpacing) { view in
                    view.aspectRatio(1, contentMode: .fit)
                }
        }

        // MARK: - Download Button View

        @ViewBuilder
        private var downloadButton: some View {
            if let status = downloadStatus {
                switch status.state {
                case .downloading:
                    buttonFrame {
                        Button {
                            handleDownloadButtonTap()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(
                                        Color.white.opacity(0.3),
                                        lineWidth: 3
                                    )

                                Circle()
                                    .trim(from: 0, to: status.progress ?? 0)
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(
                                            lineWidth: 3,
                                            lineCap: .round
                                        )
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .animation(
                                        .linear(duration: 0.1),
                                        value: status.progress ?? 0
                                    )
                            }
                            .frame(width: 24, height: 24)
                        }
                    }

                case .paused:
                    buttonFrame {
                        Menu {
                            Button {
                                downloadManager.resume(
                                    itemID: viewModel.item.id ?? ""
                                )
                            } label: {
                                Label("Resume", systemImage: "play.circle")
                            }

                            Button(role: .destructive) {
                                downloadManager.delete(
                                    itemID: viewModel.item.id ?? ""
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: downloadIcon)
                        }
                    }

                case .error, .cancelled:
                    buttonFrame {
                        Menu {
                            Button {
                                downloadManager.retry(
                                    itemID: viewModel.item.id ?? ""
                                )
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }

                            Button(role: .destructive) {
                                downloadManager.delete(
                                    itemID: viewModel.item.id ?? ""
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: downloadIcon)
                        }
                    }

                default:
                    buttonFrame {
                        Button {
                            handleDownloadButtonTap()
                        } label: {
                            Image(systemName: downloadIcon)
                        }
                    }
                }
            } else {
                buttonFrame {
                    Button {
                        handleDownloadButtonTap()
                    } label: {
                        Image(systemName: downloadIcon)
                    }
                }
            }
        }

        // MARK: - Initializer

        // MARK: - Initializer

        init(
            viewModel: ViewModel,
            equalSpacing: Bool = true,
            onTogglePlayed: @escaping () -> Void = {},
            onToggleFavorite: @escaping () -> Void = {}
        ) {
            self.viewModel = viewModel
            self.downloadManager = Container.shared.downloadManager()
            self.equalSpacing = equalSpacing
            self.onTogglePlayed = onTogglePlayed
            self.onToggleFavorite = onToggleFavorite
        }

        // MARK: - Body

        var body: some View {
            HStack(alignment: .center, spacing: 10) {

                if viewModel.item.canBePlayed {

                    // MARK: - Toggle Played

                    let isCheckmarkSelected =
                        viewModel.item.userData?.isPlayed == true

                    Button(L10n.played, systemImage: "checkmark") {
                        onTogglePlayed()
                    }
                    .buttonStyle(
                        .tintedMaterial(
                            tint: .jellyfinPurple,
                            foregroundColor: .white
                        )
                    )
                    .isSelected(isCheckmarkSelected)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Toggle Favorite

                let isHeartSelected =
                    viewModel.item.userData?.isFavorite == true

                Button(
                    L10n.favorite,
                    systemImage: isHeartSelected ? "heart.fill" : "heart"
                ) {
                    onToggleFavorite()
                }
                .buttonStyle(
                    .tintedMaterial(tint: .red, foregroundColor: .white)
                )
                .isSelected(isHeartSelected)
                .frame(maxWidth: .infinity)
                .if(!equalSpacing) { view in
                    view.aspectRatio(1, contentMode: .fit)
                }

                // MARK: - Select a Version

                if let mediaSources = viewModel.playButtonItem?.mediaSources,
                    mediaSources.count > 1,
                    let itemViewModel = viewModel as? ItemViewModel
                {
                    VersionMenu(
                        viewModel: itemViewModel,
                        mediaSources: mediaSources
                    )
                    .menuStyle(.button)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Watch a Trailer

                if hasTrailers {
                    TrailerMenu(
                        localTrailers: (viewModel as? ItemViewModel)?
                            .localTrailers ?? [],
                        externalTrailers: viewModel.item.remoteTrailers ?? []
                    )
                    .menuStyle(.button)
                    .frame(maxWidth: .infinity)
                    .if(!equalSpacing) { view in
                        view.aspectRatio(1, contentMode: .fit)
                    }
                }

                // MARK: - Download Button

                if experimentalDownloads {
                    downloadButton
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .buttonStyle(.material)
            .labelStyle(.iconOnly)
            .confirmationDialog(
                "Download \(viewModel.item.type == .season ? "Season" : "Series")",
                isPresented: $showingDownloadConfirmation,
                titleVisibility: .visible
            ) {
                if let count = episodeCount {
                    Button("Download \(count) Episode\(count == 1 ? "" : "s")")
                    {
                        confirmDownload()
                    }
                } else {
                    Button("Download") {
                        confirmDownload()
                    }
                }
                Button("Cancel", role: .cancel) {
                    episodeCount = nil
                }
            } message: {
                if let count = episodeCount {
                    Text(
                        "This will download \(count) episode\(count == 1 ? "" : "s")."
                    )
                } else {
                    Text(
                        "This will download all episodes in this \(viewModel.item.type == .season ? "season" : "series")."
                    )
                }
            }
        }
    }
}

extension ItemView.ActionButtonHStack where ViewModel == ItemViewModel {
    init(viewModel: ItemViewModel, equalSpacing: Bool = true) {
        self.init(
            viewModel: viewModel,
            equalSpacing: equalSpacing,
            onTogglePlayed: { viewModel.send(.toggleIsPlayed) },
            onToggleFavorite: { viewModel.send(.toggleIsFavorite) }
        )
    }
}
