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

/// Protocol that both ItemViewModel and DownloadItemViewModel conform to
/// for use with components like AttributesHStack
protocol ItemViewModelProtocol: ObservableObject {
    var item: BaseItemDto { get }
    var selectedMediaSource: MediaSourceInfo? { get }
}

/// Type-erased wrapper for season view models
/// Allows both ServerSeasonItemViewModel and DownloadSeasonItemViewModel to be stored together
/// This is the unified SeasonItemViewModel that works for both online and downloaded content
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

/// Protocol for view models that support series with seasons
/// Used by SeriesEpisodeSelector to work with both online and downloaded series
protocol SeriesViewModelProtocol: ItemViewModelProtocol {
    var seasons: IdentifiedArrayOf<SeasonItemViewModel> { get }
    var playButtonItem: BaseItemDto? { get }
}

/// A lightweight view model for downloaded items that provides the same interface
/// as ItemViewModel for use with existing components like AttributesHStack
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

    init(storedItem: StoredDownloadItem) {
        self.storedItem = storedItem
        self.downloadItem = DownloadItemDto(from: storedItem)

        // Use the full BaseItemDto from StoredDownloadItem
        let baseItem = storedItem.item
        self.item = baseItem
        self.playButtonItem = baseItem.isPlayable ? baseItem : nil
        self.selectedMediaSource = baseItem.mediaSources?.first

        // Load seasons if this is a series
        if storedItem.type == .series {
            loadSeasons()
        }
    }

    /// Convenience initializer for backward compatibility with DownloadItemDto
    /// Note: This will load the StoredDownloadItem from CoreStore
    convenience init(downloadItem: DownloadItemDto) {
        // Try to load the StoredDownloadItem from CoreStore
        if let userSession = Container.shared.currentUserSession(),
           let stored: StoredDownloadItem = try? AnyStoredData.fetch(
               downloadItem.id,
               ownerID: userSession.user.id,
               domain: "downloads"
           )
        {
            self.init(storedItem: stored)
        } else {
            // Fallback: Create a minimal StoredDownloadItem from DownloadItemDto
            // This shouldn't happen in normal usage, but provides a safety net
            var baseItem = BaseItemDto()
            baseItem.id = downloadItem.id
            baseItem.name = downloadItem.name
            baseItem.type = downloadItem.type
            baseItem.overview = downloadItem.overview
            baseItem.genres = downloadItem.genres
            baseItem.productionYear = downloadItem.productionYear
            baseItem.premiereDate = downloadItem.premiereDate
            baseItem.officialRating = downloadItem.officialRating
            baseItem.communityRating = downloadItem.communityRating.map { Float($0) }
            baseItem.criticRating = downloadItem.criticRating.map { Float($0) }
            baseItem.runTimeTicks = downloadItem.runTimeTicks.map { Int($0) }
            baseItem.seriesID = downloadItem.seriesID
            baseItem.seriesName = downloadItem.seriesName
            baseItem.seasonID = downloadItem.seasonID
            baseItem.seasonName = downloadItem.seasonName
            baseItem.parentIndexNumber = downloadItem.parentIndexNumber
            baseItem.indexNumber = downloadItem.indexNumber

            let stored = StoredDownloadItem(
                item: baseItem,
                downloadedAt: downloadItem.downloadedAt,
                fileSize: downloadItem.fileSize,
                mediaPath: downloadItem.mediaPath,
                primaryImagePath: downloadItem.primaryImagePath,
                backdropImagePath: downloadItem.backdropImagePath,
                logoImagePath: downloadItem.logoImagePath
            )
            self.init(storedItem: stored)
        }
    }

    // MARK: - Load Seasons

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
            }
        }
        .asAnyCancellable()
    }

    private func loadDownloadedSeasons(seriesID: String) async -> [BaseItemDto] {
        let seriesPath = URL.seriesDownloadFolder(seriesID: seriesID)
        let seasonsPath = seriesPath.appendingPathComponent("seasons")

        guard let seasonContents = try? FileManager.default.contentsOfDirectory(atPath: seasonsPath.path) else {
            return []
        }

        var seasons: [BaseItemDto] = []

        for seasonID in seasonContents {
            let seasonPath = URL.seasonDownloadFolder(seriesID: seriesID, seasonID: seasonID)
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

    // MARK: - Download Progress

    /// Get download progress for seasons and series
    /// Returns a tuple of (downloaded: Int, total: Int) or nil if not applicable
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
