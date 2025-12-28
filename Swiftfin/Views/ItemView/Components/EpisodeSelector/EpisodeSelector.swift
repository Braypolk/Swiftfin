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

struct SeriesEpisodeSelector<ViewModel: SeriesViewModelProtocol>: View {

    @ObservedObject
    var viewModel: ViewModel

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    @Injected(\.downloadQueueService)
    private var queueService: DownloadQueueService

    @Default(.Experimental.downloads)
    private var experimentalDownloads

    @State
    private var didSelectPlayButtonSeason = false
    @State
    private var selection: SeasonItemViewModel.ID?
    @State
    private var showingDownloadConfirmation = false
    @State
    private var selectedSeasonForDownload: BaseItemDto?
    @State
    private var episodeCount: Int?

    private var selectionViewModel: SeasonItemViewModel? {
        viewModel.seasons.first(where: { $0.id == selection })
    }

    @ViewBuilder
    private var seasonSelectorMenu: some View {
        if let seasonDisplayName = selectionViewModel?.season.displayTitle,
           viewModel.seasons.count <= 1
        {
            HStack {
                Text(seasonDisplayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                if experimentalDownloads, let season = selectionViewModel?.season {
                    Spacer()
                    downloadButton(for: season)
                }
            }
        } else {
            HStack {
                Menu {
                    ForEach(viewModel.seasons, id: \.season.id) { seasonViewModel in
                        Button {
                            selection = seasonViewModel.id
                        } label: {
                            if seasonViewModel.id == selection {
                                Label(seasonViewModel.season.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(seasonViewModel.season.displayTitle)
                            }
                        }
                    }
                } label: {
                    Label(
                        selectionViewModel?.season.displayTitle ?? .emptyDash,
                        systemImage: "chevron.down"
                    )
                    .labelStyle(.episodeSelector)
                }

                if experimentalDownloads, let season = selectionViewModel?.season {
                    Spacer()
                    downloadButton(for: season)
                }
            }
        }
    }

    @ViewBuilder
    private func downloadButton(for season: BaseItemDto) -> some View {
        Button {
            selectedSeasonForDownload = season
            Task {
                await fetchEpisodeCount(for: season)
                await MainActor.run {
                    showingDownloadConfirmation = true
                }
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.title3)
        }
        .buttonStyle(.plain)
    }

    private func fetchEpisodeCount(for season: BaseItemDto) async {
        guard let seasonID = season.id,
              let seriesID = season.seriesID else { return }

        do {
            let count = try await queueService.countEpisodesToDownload(seasonID: seasonID, seriesID: seriesID)
            await MainActor.run {
                episodeCount = count
            }
        } catch {
            await MainActor.run {
                episodeCount = nil
            }
        }
    }

    private func confirmDownload() {
        guard let season = selectedSeasonForDownload else { return }
        downloadManager.queueItem(season)
        showingDownloadConfirmation = false
        selectedSeasonForDownload = nil
        episodeCount = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            seasonSelectorMenu
                .edgePadding(.horizontal)

            Group {
                if let selectionViewModel {
                    EpisodeHStack(viewModel: selectionViewModel, playButtonItem: viewModel.playButtonItem, parentViewModel: viewModel)
                } else {
                    LoadingHStack()
                }
            }
            .transition(.opacity.animation(.linear(duration: 0.1)))
        }
        .onReceive(viewModel.playButtonItem.publisher) { newValue in

            guard !didSelectPlayButtonSeason else { return }
            didSelectPlayButtonSeason = true

            if let playButtonSeason = viewModel.seasons.first(where: { $0.id == newValue.seasonID }) {
                selection = playButtonSeason.id
            } else {
                selection = viewModel.seasons.first?.id
            }
        }
        .onChange(of: selection) { _ in
            guard let selectionViewModel else { return }

            if selectionViewModel.state == .initial {
                selectionViewModel.send(.refresh)
            }
        }
        .confirmationDialog(
            "Download Season",
            isPresented: $showingDownloadConfirmation,
            titleVisibility: .visible
        ) {
            if let count = episodeCount {
                Button("Download \(count) Episode\(count == 1 ? "" : "s")") {
                    confirmDownload()
                }
            } else {
                Button("Download") {
                    confirmDownload()
                }
            }
            Button("Cancel", role: .cancel) {
                selectedSeasonForDownload = nil
                episodeCount = nil
            }
        } message: {
            if let count = episodeCount {
                Text("This will download \(count) episode\(count == 1 ? "" : "s").")
            } else {
                Text("This will download all episodes in this season.")
            }
        }
    }
}
