//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation
import JellyfinAPI
import Logging

/// Service for building download queues, especially for hierarchical content (series → seasons → episodes)
class DownloadQueueService {

    private let logger = Logger.swiftfin()

    @Injected(\.currentUserSession)
    private var userSession: UserSession!

    // MARK: - Queue Building

    func buildEpisodeQueue(episode: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let episodeID = episode.id else {
            throw DownloadError.itemNotFound
        }

        guard let seriesID = episode.seriesID, let seasonID = episode.seasonID else {
            throw DownloadError.missingParentInfo
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // Ensure parent metadata exists using helper
        ensureParentMetadata(
            for: episode,
            seriesID: seriesID,
            seasonID: seasonID,
            queue: &queue,
            priority: &priority
        )

        // Add the episode
        let episodeSize = Int64(episode.mediaSources?.first?.size ?? 0)
        let metadataConstantSize: Int64 = 10240 // 10KB
        let totalMetadataSize = Int64(queue.count) * metadataConstantSize
        let groupTotalSize = episodeSize + totalMetadataSize

        let totalItems = queue.count + 1
        queue.append(DownloadQueueItem(
            from: episode,
            priority: priority,
            groupId: episodeID,
            groupCount: totalItems,
            size: episodeSize,
            groupTotalSize: groupTotalSize,
            isMetadataOnly: false
        ))

        // Update previously added metadata items with group info and sizes
        queue = queue.map { item in
            var updated = item
            if updated.groupId == nil {
                updated = DownloadQueueItem(
                    id: item.id,
                    type: item.type,
                    name: item.name,
                    addedAt: item.addedAt,
                    priority: item.priority,
                    seriesID: item.seriesID,
                    seasonID: item.seasonID,
                    groupId: episodeID,
                    groupCount: totalItems,
                    size: metadataConstantSize,
                    groupTotalSize: groupTotalSize,
                    isMetadataOnly: item.isMetadataOnly
                )
            }
            return updated
        }

        logger.info("Built episode queue with \(queue.count) items for: \(episode.displayTitle)")
        return queue
    }

    func buildMovieQueue(movie: BaseItemDto) -> [DownloadQueueItem] {
        guard let movieID = movie.id else {
            return []
        }

        let movieSize = Int64(movie.mediaSources?.first?.size ?? 0)
        return [DownloadQueueItem(
            from: movie,
            priority: 0,
            groupId: movieID,
            groupCount: 1,
            size: movieSize,
            groupTotalSize: movieSize,
            isMetadataOnly: false
        )]
    }

    func buildSeasonQueue(season: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let seasonID = season.id else {
            throw DownloadError.itemNotFound
        }

        guard let seriesID = season.seriesID else {
            throw DownloadError.missingParentInfo
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // Ensure parent metadata exists using helper
        await ensureParentMetadataAsync(
            for: season,
            seriesID: seriesID,
            queue: &queue,
            priority: &priority
        )

        // Ensure season metadata exists
        if !parentMetadataExists(for: season, parentType: .season) {
            queue.append(DownloadQueueItem(
                from: season,
                priority: priority,
                groupId: nil, // Will be set if it's the only item, or if grouped with first episode
                groupCount: nil,
                size: 10240, // 10KB constant for metadata
                groupTotalSize: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }

        // Fetch all episodes in the season
        var parameters = Paths.GetEpisodesParameters()
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.seasonID = seasonID
        parameters.userID = userSession.user.id

        let request = Paths.getEpisodes(seriesID: seriesID, parameters: parameters)
        let response = try await userSession.client.send(request)
        let episodes = response.value.items ?? []

        // Add all episodes (skip already downloaded ones)
        let episodesToDownload = filterDownloadedEpisodes(episodes)
        for episode in episodesToDownload {
            guard let episodeID = episode.id else { continue }

            // Each episode gets its own group. Choose to let parent metadata be its own group or grouped with the series/season ID.

            let episodeSize = Int64(episode.mediaSources?.first?.size ?? 0)
            queue.append(DownloadQueueItem(
                from: episode,
                priority: priority,
                groupId: episodeID,
                groupCount: 1,
                size: episodeSize,
                groupTotalSize: episodeSize,
                isMetadataOnly: false
            ))
            priority += 1
        }

        logger.info("Built season queue with \(queue.count) items for: \(season.displayTitle) (\(episodes.count) episodes)")
        return queue
    }

    /// Helper to ensure series metadata is added to queue if missing (synchronous version).
    private func ensureParentMetadata(
        for item: BaseItemDto,
        seriesID: String,
        seasonID: String,
        queue: inout [DownloadQueueItem],
        priority: inout Int
    ) {
        // Ensure series metadata exists
        if !parentMetadataExists(for: item, parentType: .series) {
            queue.append(DownloadQueueItem(
                id: seriesID,
                type: .series,
                name: item.seriesName ?? seriesID,
                priority: priority,
                seriesID: nil,
                seasonID: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }

        // Ensure season metadata exists
        if !parentMetadataExists(for: item, parentType: .season) {
            queue.append(DownloadQueueItem(
                id: seasonID,
                type: .season,
                name: item.seasonName ?? seasonID,
                priority: priority,
                seriesID: seriesID,
                seasonID: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }
    }

    /// Helper to ensure series metadata is added to queue if missing (async version for when name fetch is needed).
    private func ensureParentMetadataAsync(
        for item: BaseItemDto,
        seriesID: String,
        queue: inout [DownloadQueueItem],
        priority: inout Int
    ) async {
        // Ensure series metadata exists
        if !parentMetadataExists(for: item, parentType: .series) {
            let seriesName: String?
            if let existingName = item.seriesName {
                seriesName = existingName
            } else {
                seriesName = try? await fetchItem(itemID: seriesID).name
            }
            queue.append(DownloadQueueItem(
                id: seriesID,
                type: .series,
                name: seriesName,
                priority: priority,
                seriesID: nil,
                seasonID: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }
    }

    func buildSeriesQueue(series: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let seriesID = series.id else {
            throw DownloadError.itemNotFound
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // Add series metadata first
        if !parentMetadataExists(for: series, parentType: .series) {
            queue.append(DownloadQueueItem(
                from: series,
                priority: priority,
                groupId: seriesID,
                groupCount: 1,
                size: 10240,
                groupTotalSize: 10240,
                isMetadataOnly: true
            ))
            priority += 1
        }

        // Fetch all seasons
        var seasonsParameters = Paths.GetSeasonsParameters()
        seasonsParameters.isMissing = false
        seasonsParameters.userID = userSession.user.id

        let seasonsRequest = Paths.getSeasons(seriesID: seriesID, parameters: seasonsParameters)
        let seasonsResponse = try await userSession.client.send(seasonsRequest)
        let seasons = seasonsResponse.value.items ?? []

        // For each season, add metadata and fetch episodes
        for season in seasons {
            guard let seasonID = season.id else { continue }

            // Add season metadata if it doesn't exist
            if !parentMetadataExists(for: season, parentType: .season) {
                queue.append(DownloadQueueItem(
                    from: season,
                    priority: priority,
                    groupId: seasonID,
                    groupCount: 1,
                    size: 10240,
                    groupTotalSize: 10240,
                    isMetadataOnly: true
                ))
                priority += 1
            }

            // Fetch all episodes in this season
            var episodesParameters = Paths.GetEpisodesParameters()
            episodesParameters.enableUserData = true
            episodesParameters.fields = .MinimumFields
            episodesParameters.seasonID = seasonID
            episodesParameters.userID = userSession.user.id

            let episodesRequest = Paths.getEpisodes(seriesID: seriesID, parameters: episodesParameters)
            let episodesResponse = try await userSession.client.send(episodesRequest)
            let episodes = episodesResponse.value.items ?? []

            // Add all episodes to the queue (skip already downloaded ones)
            let episodesToDownload = filterDownloadedEpisodes(episodes)
            for episode in episodesToDownload {
                guard let episodeID = episode.id else { continue }
                let episodeSize = Int64(episode.mediaSources?.first?.size ?? 0)
                queue.append(DownloadQueueItem(
                    from: episode,
                    priority: priority,
                    groupId: episodeID,
                    groupCount: 1,
                    size: episodeSize,
                    groupTotalSize: episodeSize,
                    isMetadataOnly: false
                ))
                priority += 1
            }
        }

        let totalEpisodes = queue.filter { $0.type == .episode }.count
        logger
            .info(
                "Built series queue with \(queue.count) items for: \(series.displayTitle) (\(seasons.count) seasons, \(totalEpisodes) episodes)"
            )
        return queue
    }

    /// Builds the appropriate queue for any item type.
    /// - Parameter item: The BaseItemDto to download
    /// - Returns: Array of queue items in download order (lower priority = downloaded first)
    func buildQueue(for item: BaseItemDto) async throws -> [DownloadQueueItem] {
        switch item.type {
        case .series:
            // Series: download all seasons and episodes
            return try await buildSeriesQueue(series: item)
        case .season:
            // Season: download all episodes in the season
            return try await buildSeasonQueue(season: item)
        case .episode:
            // Episodes require parent metadata for proper navigation in offline views
            return try await buildEpisodeQueue(episode: item)
        case .movie:
            // Movies are simple single-item downloads
            return buildMovieQueue(movie: item)
        default:
            // For other playable types (music videos, etc.), treat like movies
            guard let itemID = item.id else {
                throw DownloadError.itemNotFound
            }
            let size = Int64(item.mediaSources?.first?.size ?? 0)
            return [DownloadQueueItem(from: item, groupId: itemID, groupCount: 1, size: size, groupTotalSize: size)]
        }
    }

    // MARK: - Parent Metadata Checking

    /// Checks if parent metadata exists for an item.
    /// Checks if parent metadata exists for an item.
    func parentMetadataExists(for item: BaseItemDto, parentType: BaseItemKind) -> Bool {
        let metadataPath: URL?

        // We need to construct a temporary parent item to get its download folder
        // This ensures consistent path logic (whether human-readable or ID-based)

        switch parentType {
        case .series:
            // Check if we have the series name to construct a proper path
            let seriesID = (item.type == .series) ? item.id : item.seriesID
            let seriesName = (item.type == .series) ? item.name : item.seriesName

            guard let seriesID = seriesID else { return false }

            // Try legacy path first
            let legacyPath = URL.seriesDownloadFolder(seriesID: seriesID)
                .appendingPathComponent("Metadata")
                .appendingPathComponent("Item.json")

            if FileManager.default.fileExists(atPath: legacyPath.path) {
                return true
            }

            // Try new path if name is available
            if let seriesName = seriesName {
                let newPath = URL.seriesDownloadFolder(seriesName: seriesName)
                    .appendingPathComponent("Metadata")
                    .appendingPathComponent("Item.json")
                if FileManager.default.fileExists(atPath: newPath.path) {
                    return true
                }
            }
            return false

        case .season:
            let seasonID = (item.type == .season) ? item.id : item.seasonID
            let seriesID = item.seriesID
            let seasonName = (item.type == .season) ? item.name : item.seasonName
            let seriesName = item.seriesName

            guard let seriesID = seriesID, let seasonID = seasonID else { return false }

            // Try legacy path first
            let legacyPath = URL.seasonDownloadFolder(seriesID: seriesID, seasonID: seasonID)
                .appendingPathComponent("Metadata")
                .appendingPathComponent("Item.json")

            if FileManager.default.fileExists(atPath: legacyPath.path) {
                return true
            }

            // Try new path if names are available
            // Note: We need to reconstruct the season name format "Season X" if not provided
            if let seriesName = seriesName {
                let effectiveSeasonName: String
                if let seasonName = seasonName {
                    effectiveSeasonName = seasonName
                } else if let index = item.parentIndexNumber { // Episode's parent index is season number
                    effectiveSeasonName = "Season \(index)"
                } else {
                    return false
                }

                let newPath = URL.seasonDownloadFolder(seriesName: seriesName, seasonName: effectiveSeasonName)
                    .appendingPathComponent("Metadata")
                    .appendingPathComponent("Item.json")

                if FileManager.default.fileExists(atPath: newPath.path) {
                    return true
                }
            }
            return false

        default:
            return false
        }
    }

    /// Checks if an item is already downloaded in CoreStore.
    func isItemDownloaded(itemID: String) -> Bool {
        guard let userSession = Container.shared.currentUserSession() else {
            return false
        }

        // Check CoreStore for the item
        if let _: DownloadItemDto = try? AnyStoredData.fetch(
            itemID,
            ownerID: userSession.user.id,
            domain: "downloads"
        ) {
            return true
        }

        return false
    }

    /// Filters out already-downloaded episodes from a list.
    func filterDownloadedEpisodes(_ episodes: [BaseItemDto]) -> [BaseItemDto] {
        episodes.filter { episode in
            guard let episodeID = episode.id else { return false }
            return !isItemDownloaded(itemID: episodeID)
        }
    }

    /// Counts episodes that need to be downloaded for a season or series.
    func countEpisodesToDownload(seasonID: String, seriesID: String) async throws -> Int {
        var parameters = Paths.GetEpisodesParameters()
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.seasonID = seasonID
        parameters.userID = userSession.user.id

        let request = Paths.getEpisodes(seriesID: seriesID, parameters: parameters)
        let response = try await userSession.client.send(request)
        let allEpisodes = response.value.items ?? []
        let episodesToDownload = filterDownloadedEpisodes(allEpisodes)
        return episodesToDownload.count
    }

    /// Counts episodes that need to be downloaded for a series (all seasons)
    /// - Parameter seriesID: The series ID
    /// - Returns: Count of episodes that need to be downloaded across all seasons
    func countEpisodesToDownload(seriesID: String) async throws -> Int {
        var parameters = Paths.GetSeasonsParameters()
        parameters.isMissing = false
        parameters.userID = userSession.user.id

        let request = Paths.getSeasons(seriesID: seriesID, parameters: parameters)
        let response = try await userSession.client.send(request)
        let seasons = response.value.items ?? []

        var totalCount = 0
        for season in seasons {
            guard let seasonID = season.id else { continue }
            totalCount += try await countEpisodesToDownload(seasonID: seasonID, seriesID: seriesID)
        }

        return totalCount
    }

    // MARK: - API Helpers

    /// Fetches a single item by ID with all fields including people, media sources, and user data.
    func fetchItem(itemID: String) async throws -> BaseItemDto {
        let request = Paths.getItem(itemID: itemID, userID: userSession.user.id)
        let response = try await userSession.client.send(request)
        let item = response.value

        // Safety check to ensure people, media sources, and user data are included
        return try await item.getFullItem(userSession: userSession)
    }
}

// MARK: - Factory Registration

extension Container {

    var downloadQueueService: Factory<DownloadQueueService> {
        self { DownloadQueueService() }
    }
}
