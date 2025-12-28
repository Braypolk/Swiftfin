//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation
import JellyfinAPI
import Logging

// MARK: - DownloadQueueService

/// Service for building download queues, especially for hierarchical content (series → seasons → episodes)
class DownloadQueueService {

    private let logger = Logger.swiftfin()

    @Injected(\.currentUserSession)
    private var userSession: UserSession!

    // MARK: - Public Methods

    /// Builds the queue for an episode (episode + parent metadata if needed)
    /// - Parameter episode: The episode BaseItemDto
    /// - Returns: Array of queue items in download order
    func buildEpisodeQueue(episode: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let episodeID = episode.id else {
            throw DownloadError.itemNotFound
        }

        guard let seriesID = episode.seriesID, let seasonID = episode.seasonID else {
            throw DownloadError.missingParentInfo
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // 1. Check if series metadata exists, if not, add it
        if !parentMetadataExists(for: episode, parentType: .series) {
            queue.append(DownloadQueueItem(
                id: seriesID,
                type: .series,
                name: episode.seriesName ?? seriesID,
                priority: priority,
                seriesID: nil,
                seasonID: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }

        // 2. Check if season metadata exists, if not, add it
        if !parentMetadataExists(for: episode, parentType: .season) {
            queue.append(DownloadQueueItem(
                id: seasonID,
                type: .season,
                name: episode.seasonName ?? seasonID,
                priority: priority,
                seriesID: seriesID,
                seasonID: nil,
                isMetadataOnly: true
            ))
            priority += 1
        }

        // 3. Add the episode
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

    /// Builds a queue for a movie
    /// - Parameter movie: The movie BaseItemDto
    /// - Returns: Array with single queue item
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

    /// Builds the queue for a season (all episodes + parent metadata if needed)
    /// - Parameter season: The season BaseItemDto
    /// - Returns: Array of queue items in download order
    func buildSeasonQueue(season: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let seasonID = season.id else {
            throw DownloadError.itemNotFound
        }

        guard let seriesID = season.seriesID else {
            throw DownloadError.missingParentInfo
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // 1. Check if series metadata exists, if not, add it
        if !parentMetadataExists(for: season, parentType: .series) {
            // Use series name from season if available, otherwise fetch it
            let seriesName: String?
            if let existingName = season.seriesName {
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

        // 2. Check if season metadata exists, if not, add it
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

        // 3. Fetch all episodes in the season
        var parameters = Paths.GetEpisodesParameters()
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.seasonID = seasonID
        parameters.userID = userSession.user.id

        let request = Paths.getEpisodes(seriesID: seriesID, parameters: parameters)
        let response = try await userSession.client.send(request)
        let episodes = response.value.items ?? []

        // 4. Add all episodes to the queue (skip already downloaded ones)
        let episodesToDownload = filterDownloadedEpisodes(episodes)
        for episode in episodesToDownload {
            guard let episodeID = episode.id else { continue }

            // Each episode gets its own group.
            // If this is the first episode and we have parent metadata,
            // we'll group the parent metadata with this episode for simplicity,
            // or we can just let parent metadata be its own "group" that completes quickly.
            // Choosing to let parent metadata be its own group or grouped with the series/season ID.

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

    /// Builds the queue for a series (all seasons + all episodes + metadata)
    /// - Parameter series: The series BaseItemDto
    /// - Returns: Array of queue items in download order
    func buildSeriesQueue(series: BaseItemDto) async throws -> [DownloadQueueItem] {
        guard let seriesID = series.id else {
            throw DownloadError.itemNotFound
        }

        var queue: [DownloadQueueItem] = []
        var priority = 0

        // 1. Add series metadata first
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

        // 2. Fetch all seasons
        var seasonsParameters = Paths.GetSeasonsParameters()
        seasonsParameters.isMissing = false
        seasonsParameters.userID = userSession.user.id

        let seasonsRequest = Paths.getSeasons(seriesID: seriesID, parameters: seasonsParameters)
        let seasonsResponse = try await userSession.client.send(seasonsRequest)
        let seasons = seasonsResponse.value.items ?? []

        // 3. For each season, add metadata and fetch episodes
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

    /// Builds the appropriate queue for any item type
    ///
    /// Design decisions:
    /// - Episodes: Require parent metadata (series, season) to be downloaded first for proper navigation
    /// - Movies: Simple single-item queue
    /// - Seasons: Downloads all episodes in the season + parent metadata
    /// - Series: Downloads all seasons and episodes + metadata
    /// - Other types: Treated as simple single-item downloads like movies
    ///
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

    /// Checks if parent metadata exists for an item
    /// - Parameters:
    ///   - item: The child item (or item itself if checking its own metadata)
    ///   - parentType: The type of parent to check for
    /// - Returns: true if parent metadata exists on disk
    func parentMetadataExists(for item: BaseItemDto, parentType: BaseItemKind) -> Bool {
        let metadataPath: URL?

        switch parentType {
        case .series:
            // For series, use the item's own ID if it's a series, otherwise use seriesID
            let seriesID = (item.type == .series) ? item.id : item.seriesID
            guard let seriesID = seriesID else { return false }
            metadataPath = URL.seriesDownloadFolder(seriesID: seriesID)
                .appendingPathComponent("Metadata")
                .appendingPathComponent("Item.json")

        case .season:
            // For season, use the item's own ID if it's a season, otherwise use seasonID
            let seasonID = (item.type == .season) ? item.id : item.seasonID
            guard let seriesID = item.seriesID, let seasonID = seasonID else { return false }
            metadataPath = URL.seasonDownloadFolder(seriesID: seriesID, seasonID: seasonID)
                .appendingPathComponent("Metadata")
                .appendingPathComponent("Item.json")

        default:
            return false
        }

        guard let path = metadataPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Checks if an item is already downloaded
    /// - Parameter itemID: The item ID to check
    /// - Returns: true if the item exists in CoreStore
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

    /// Filters out already-downloaded episodes from a list
    /// - Parameter episodes: Array of episodes to filter
    /// - Returns: Array of episodes that need to be downloaded
    func filterDownloadedEpisodes(_ episodes: [BaseItemDto]) -> [BaseItemDto] {
        episodes.filter { episode in
            guard let episodeID = episode.id else { return false }
            return !isItemDownloaded(itemID: episodeID)
        }
    }

    /// Counts episodes that need to be downloaded for a season
    /// - Parameters:
    ///   - seasonID: The season ID
    ///   - seriesID: The series ID
    /// - Returns: Count of episodes that need to be downloaded
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

    // MARK: - Private API Methods

    /// Fetches a single item by ID with all fields including people, media sources, and user data
    func fetchItem(itemID: String) async throws -> BaseItemDto {
        // Use getItem with userID to get the full item with all fields
        // When userID is provided, the API returns all fields including:
        // - People (cast and crew)
        // - Media sources (media info)
        // - User data (playback position, play count, favorites, etc.)
        // - All other metadata
        let request = Paths.getItem(itemID: itemID, userID: userSession.user.id)
        let response = try await userSession.client.send(request)
        let item = response.value

        // The getItem endpoint should return all fields by default when userID is provided.
        // However, to ensure we have absolutely everything, we call getFullItem as well.
        // This is a safeguard to ensure people, media sources, and user data are included.
        return try await item.getFullItem(userSession: userSession)
    }
}

// MARK: - Factory Registration

extension Container {

    var downloadQueueService: Factory<DownloadQueueService> {
        self { DownloadQueueService() }
    }
}
