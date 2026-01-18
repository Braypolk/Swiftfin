//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Foundation
import IdentifiedCollections
import JellyfinAPI
import SwiftUI

/// Unified SeasonItemViewModel that works for both online and downloaded content.
final class SeasonItemViewModel: PagingLibraryViewModel<BaseItemDto>, Identifiable {
    private let _season: BaseItemDto
    private let _id: String?
    private let _get: (Int) async throws -> [BaseItemDto]
    private weak var _wrappedViewModel: (any PagingLibraryViewModel<BaseItemDto> & Identifiable)?

    var season: BaseItemDto { _season }

    var id: String? { _id }

    init(_ viewModel: ServerSeasonItemViewModel) {
        self._season = viewModel.season
        self._id = viewModel.id
        self._wrappedViewModel = viewModel
        self._get = { [weak viewModel] page in
            guard let viewModel = viewModel else { return [] }
            return try await viewModel.get(page: page)
        }
        super.init(parent: self._season)
    }

    init(_ viewModel: DownloadSeasonItemViewModel) {
        self._season = viewModel.season
        self._id = viewModel.id
        self._wrappedViewModel = viewModel
        self._get = { [weak viewModel] page in
            guard let viewModel = viewModel else { return [] }
            return try await viewModel.get(page: page)
        }
        super.init(parent: self._season)
    }

    override func get(page: Int) async throws -> [BaseItemDto] {
        try await _get(page)
    }
}

/// A lightweight view model for downloaded items that provides the same interface
/// as ItemViewModel for use with existing components.
class DownloadItemViewModel: ObservableObject, ItemViewModelProtocol, SeriesViewModelProtocol {

    @Published
    private(set) var item: BaseItemDto

    @Published
    var playButtonItem: BaseItemDto? {
        didSet {
            if let playButtonItem {
                selectedMediaSource = playButtonItem.mediaSources?.first
            }
        }
    }

    @Published
    private(set) var selectedMediaSource: MediaSourceInfo?

    @Published
    var seasons: IdentifiedArrayOf<SeasonItemViewModel> = []

    /// The stored download item containing the full BaseItemDto and download metadata
    let storedItem: StoredDownloadItem

    /// The DownloadItemDto for display purposes
    let downloadItem: DownloadItemDto

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    private var loadSeasonsTask: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    @Published
    var isDeleted = false

    init(storedItem: StoredDownloadItem) {
        self.storedItem = storedItem
        self.downloadItem = DownloadItemDto(from: storedItem)

        // Use the full BaseItemDto from StoredDownloadItem
        let baseItem = storedItem.item
        self.item = baseItem
        self.playButtonItem = baseItem.isPlayable ? baseItem : nil
        self.selectedMediaSource = baseItem.mediaSources?.first

        if storedItem.type == .series {
            loadSeasons()
        }

        setupObservers()
    }

    private func setupObservers() {
        downloadManager.$downloadsUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDownloadsUpdated()
            }
            .store(in: &cancellables)
    }

    private func handleDownloadsUpdated() {
        // Check if item still exists
        if downloadManager.status(for: storedItem.id) == nil {
            isDeleted = true
            return
        }

        // If series, reload seasons to reflect changes (e.g. deleted episodes)
        if storedItem.type == .series {
            loadSeasons()
        }
    }

    private func loadSeasons() {
        loadSeasonsTask?.cancel()

        loadSeasonsTask = Task { [weak self] in
            guard let self else { return }
            let seriesID = self.downloadItem.id

            await MainActor.run {
                self.seasons.removeAll()
            }

            let seasons = await self.loadDownloadedSeasons(seriesID: seriesID)

            await MainActor.run {
                let seasonViewModels = seasons
                    .sorted { ($0.indexNumber ?? -1) < ($1.indexNumber ?? -1) }
                    .map { SeasonItemViewModel(DownloadSeasonItemViewModel(season: $0, seriesID: seriesID)) }

                self.seasons.append(contentsOf: seasonViewModels)

                // For series, set the playButtonItem to the first episode of the first season
                // to provide a starting point for season selection in the UI.
                if let firstSeasonVM = seasonViewModels.first {
                    Task {
                        let episodes = try? await firstSeasonVM.get(page: 0)
                        if let firstEpisode = episodes?.first {
                            await MainActor.run {
                                self.playButtonItem = firstEpisode
                            }
                        }
                    }
                } else {
                    // If no seasons found, check if we should consider this item deleted
                    // We only delete if there are no active downloads for this series
                    let status = self.downloadManager.aggregatedStatus(for: seriesID, type: .series)
                    let isDownloading = (status?.downloadingEpisodes ?? 0) > 0 || (status?.pendingEpisodes ?? 0) > 0

                    if !isDownloading {
                        self.downloadManager.delete(itemID: seriesID)
                    }
                }
            }
        }
        .asAnyCancellable()
    }

    private func loadDownloadedSeasons(seriesID: String) async -> [BaseItemDto] {
        // Try to find series folder using ID (legacy) or Name (new)
        // Since we only have ID here, we first check legacy path
        var seriesPath = URL.seriesDownloadFolder(seriesID: seriesID)

        // If legacy path doesn't exist, we need to find the human-readable path
        // We can scan the "series" directory and check metadata files to find the matching series ID
        if !FileManager.default.fileExists(atPath: seriesPath.path) {
            if let path = findSeriesFolder(by: seriesID) {
                seriesPath = path
            } else {
                return []
            }
        }

        let seasonsPath = seriesPath.appendingPathComponent("seasons")

        guard let seasonContents = try? FileManager.default.contentsOfDirectory(atPath: seasonsPath.path) else {
            return []
        }

        var seasons: [BaseItemDto] = []

        for seasonFolder in seasonContents {
            // Skip hidden files
            if seasonFolder.hasPrefix(".") { continue }

            let seasonPath = seasonsPath.appendingPathComponent(seasonFolder)
            let episodesPath = seasonPath.appendingPathComponent("episodes")

            // Filter out empty seasons: check if episodes directory exists and has contents
            guard let episodeContents = try? FileManager.default.contentsOfDirectory(atPath: episodesPath.path),
                  episodeContents.contains(where: { !$0.hasPrefix(".") })
            else {
                continue
            }

            let metadataPath = seasonPath.appendingPathComponent("Metadata").appendingPathComponent("Item.json")

            guard let data = FileManager.default.contents(atPath: metadataPath.path),
                  let season = try? JSONDecoder().decode(BaseItemDto.self, from: data)
            else {
                continue
            }

            seasons.append(season)
        }

        return seasons
    }

    /// Helper to find a series folder by ID when the folder name might be human-readable
    private func findSeriesFolder(by seriesID: String) -> URL? {
        let seriesRoot = URL.downloadsSeries
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: seriesRoot.path) else { return nil }

        for folderName in contents {
            if folderName.hasPrefix(".") { continue }

            let folderURL = seriesRoot.appendingPathComponent(folderName)
            let metadataPath = folderURL.appendingPathComponent("Metadata").appendingPathComponent("Item.json")

            if let data = FileManager.default.contents(atPath: metadataPath.path),
               let item = try? JSONDecoder().decode(BaseItemDto.self, from: data),
               item.id == seriesID
            {
                return folderURL
            }
        }

        return nil
    }

    /// Get download progress for seasons and series (downloaded, total).
    var downloadProgress: (downloaded: Int, total: Int)? {
        guard downloadItem.type == .season || downloadItem.type == .series else {
            return nil
        }

        guard let aggregatedStatus = downloadManager.aggregatedStatus(for: downloadItem.id, type: downloadItem.type) else {
            return nil
        }

        return (downloaded: aggregatedStatus.downloadedEpisodes, total: aggregatedStatus.totalEpisodes)
    }
}
