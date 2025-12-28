//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Files
import Foundation
import JellyfinAPI
import Logging

extension Container {
    var downloadManager: Factory<DownloadManager> { self { DownloadManager() }.shared }
}

// MARK: - DownloadManager

class DownloadManager: ObservableObject {

    // MARK: - State

    enum State: Hashable {
        case idle
        case downloading(itemID: String)
        case error(String)
    }

    // MARK: - Properties

    private let logger = Logger.swiftfin()

    @Injected(\.downloadQueueService)
    private var queueService: DownloadQueueService

    /// Current manager state
    @Published
    private(set) var state: State = .idle

    /// The download queue (persisted)
    @Published
    private(set) var queue: [DownloadQueueItem] = []

    /// Currently active download task
    @Published
    private(set) var currentTask: DownloadTask?

    /// Completed downloaded items (from CoreStore/disk)
    @Published
    private(set) var completedItems: [DownloadItemDto] = []

    /// Download states for each item
    @Published
    private(set) var itemStates: [String: DownloadItemState] = [:]

    /// Progress tracking for each item (0.0 to 1.0)
    @Published
    private(set) var itemProgress: [String: Double] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var currentTaskCancellable: AnyCancellable?

    /// Cached stored items from CoreStore (invalidated on add/remove)
    private var cachedStoredItems: [StoredDownloadItem]?

    // MARK: - Initialization

    fileprivate init() {
        createDownloadDirectories()
        loadPersistedQueue()
        loadCompletedItems()
        restoreDownloadProgress()

        // Initialize background download session early
        _ = BackgroundDownloadSession.shared

        // Auto-resume processing if there are items in queue
        if !queue.isEmpty {
            processNextInQueue()
        }
    }

    /// Restore download progress from persisted storage for paused items
    private func restoreDownloadProgress() {
        for item in queue {
            if itemStates[item.id] == .paused {
                // Load persisted progress
                let bytesDownloaded = StoredValues[.User.downloadBytesDownloaded(itemID: item.id)]
                let totalBytes = StoredValues[.User.downloadTotalBytes(itemID: item.id)]
                if totalBytes > 0 {
                    itemProgress[item.id] = Double(bytesDownloaded) / Double(totalBytes)
                }
            }
        }
    }

    // MARK: - Directory Management

    private func createDownloadDirectories() {
        let directories = [
            URL.downloads,
            URL.downloadsMovies,
            URL.downloadsSeries,
        ]

        for directory in directories {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func clearTmp() {
        do {
            try Folder(path: URL.tmp.path).files.delete()
            logger.trace("Cleared tmp directory")
        } catch {
            logger.error("Unable to clear tmp directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue Management

    /// Queue an item for download
    func queueItem(_ item: BaseItemDto) {
        Task {
            do {
                let queueItems = try await queueService.buildQueue(for: item)
                await MainActor.run {
                    addToQueue(queueItems)
                }
            } catch {
                logger.error("Failed to build queue for item: \(error.localizedDescription)")
            }
        }
    }

    private func addToQueue(_ items: [DownloadQueueItem]) {
        guard let userSession = Container.shared.currentUserSession() else { return }

        // Filter out items already in queue, completed items array, or CoreStore
        let newItems = items.filter { newItem in
            // Skip if already in queue
            if queue.contains(where: { $0.id == newItem.id }) {
                return false
            }

            // Skip if in completed items array (movies/series only)
            if completedItems.contains(where: { $0.id == newItem.id }) {
                return false
            }

            // Skip if already downloaded (check CoreStore for all item types including episodes)
            if let _: StoredDownloadItem = try? AnyStoredData.fetch(
                newItem.id,
                ownerID: userSession.user.id,
                domain: "downloads"
            ) {
                return false
            }

            return true
        }

        guard !newItems.isEmpty else { return }

        queue.append(contentsOf: newItems)

        // Set initial states
        for item in newItems {
            itemStates[item.id] = .pending
        }

        persistQueue()
        processNextInQueue()
    }

    // MARK: - Download Control

    /// Pause a specific download
    func pause(itemID: String) {
        if currentTask?.id == itemID {
            currentTask?.pause()
            itemStates[itemID] = .paused
            processNextInQueue()
        } else {
            itemStates[itemID] = .paused
        }
        persistQueue()
    }

    /// Resume a paused download
    func resume(itemID: String) {
        // Check if there's resume data available
        let hasResumeData = StoredValues[.User.downloadResumeInfo(itemID: itemID)] != nil

        itemStates[itemID] = .pending
        persistQueue()

        // If the current task is the one we're resuming (e.g. it was paused in this session),
        // we need to clear it so processNextInQueue can start a new task
        if currentTask?.id == itemID {
            currentTask = nil
            currentTaskCancellable?.cancel()
            currentTaskCancellable = nil
        }

        if currentTask == nil {
            // If resuming and there's resume data, the task will use it automatically
            processNextInQueue()
        } else if hasResumeData {
            // If another task is running, just mark as pending - it will resume when its turn comes
            logger.info("Queued resume for item \(itemID) with resume data")
        }
    }

    /// Retry a failed download
    func retry(itemID: String) {
        itemStates[itemID] = .pending
        persistQueue()

        if currentTask == nil {
            processNextInQueue()
        }
    }

    /// Delete a download (from queue or completed)
    /// For seasons and series, this will recursively delete all child episodes
    func delete(itemID: String) {
        deleteGroup(id: itemID)
    }

    /// Delete a group of downloads (from queue or completed)
    /// This handles both individual items and groups identified by groupId
    func deleteGroup(id: String) {
        guard let userSession = Container.shared.currentUserSession() else { return }

        // Find all items in this group from the queue
        let queuedItemsInGroup = queue.filter { $0.id == id || $0.groupId == id }

        // Find children if this is a series or season (for completeness)
        var childrenIDs: Set<String> = []
        if let firstItem = queuedItemsInGroup.first {
            if firstItem.type == .series {
                childrenIDs = Set(queue.filter { $0.seriesID == id }.map(\.id))
            } else if firstItem.type == .season {
                childrenIDs = Set(queue.filter { $0.seasonID == id }.map(\.id))
            }
        }

        let allIDsToDelete = Set(queuedItemsInGroup.map(\.id)).union(childrenIDs).union([id])

        for itemID in allIDsToDelete {
            // Determine the item type by checking CoreStore or queue
            var itemType: BaseItemKind?
            var seriesID: String?
            var seasonID: String?

            // Try to get from CoreStore first
            if let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(itemID, ownerID: userSession.user.id, domain: "downloads") {
                itemType = storedItem.type
                seriesID = storedItem.seriesID
                seasonID = storedItem.seasonID
            } else if let queueItem = queue.first(where: { $0.id == itemID }) {
                itemType = queueItem.type
                seriesID = queueItem.seriesID
                seasonID = queueItem.seasonID
            }

            // Handle bulk deletion for seasons and series (if not already covered)
            if let type = itemType {
                switch type {
                case .season:
                    if let seriesID = seriesID {
                        deleteSeasonEpisodes(seasonID: itemID, seriesID: seriesID)
                    }
                case .series:
                    deleteSeriesContent(seriesID: itemID)
                default:
                    break
                }
            }

            // Remove from queue
            queue.removeAll(where: { $0.id == itemID })
            itemStates.removeValue(forKey: itemID)
            itemProgress.removeValue(forKey: itemID)

            // Cancel any active background download
            BackgroundDownloadSession.shared.cancelDownload(itemID: itemID)

            // Clean up stored resume data and progress
            if let resumeInfo = StoredValues[.User.downloadResumeInfo(itemID: itemID)] {
                BackgroundDownloadSession.shared.deleteResumeData(resumeInfo.resumeData)
            }
            StoredValues[.User.downloadResumeInfo(itemID: itemID)] = nil
            StoredValues[.User.downloadBytesDownloaded(itemID: itemID)] = 0
            StoredValues[.User.downloadTotalBytes(itemID: itemID)] = 0

            // Cancel if currently downloading
            if currentTask?.id == itemID {
                currentTask?.cancel()
                currentTask = nil
                currentTaskCancellable?.cancel()
                currentTaskCancellable = nil
            }

            // Remove from completed items
            if completedItems.contains(where: { $0.id == itemID }) {
                completedItems.removeAll(where: { $0.id == itemID })
            }

            // Delete files and CoreStore entry
            deleteItem(itemID: itemID)
        }

        persistQueue()
        processNextInQueue()
    }

    /// Delete all episodes in a season
    private func deleteSeasonEpisodes(seasonID: String, seriesID: String) {
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seasonEpisodes = allStoredItems.filter { $0.seasonID == seasonID && $0.seriesID == seriesID && $0.type == .episode }

        // Delete each episode
        for episode in seasonEpisodes {
            // Remove from queue
            queue.removeAll(where: { $0.id == episode.id })
            itemStates.removeValue(forKey: episode.id)

            // Cancel if currently downloading
            if currentTask?.id == episode.id {
                currentTask?.cancel()
                currentTask = nil
            }

            // Delete files and CoreStore entry
            deleteItem(itemID: episode.id)
        }

        // Also remove any queued episodes for this season
        let queuedEpisodes = queue.filter { $0.seasonID == seasonID && $0.seriesID == seriesID && $0.type == .episode }
        for queuedEpisode in queuedEpisodes {
            queue.removeAll(where: { $0.id == queuedEpisode.id })
            itemStates.removeValue(forKey: queuedEpisode.id)
            if currentTask?.id == queuedEpisode.id {
                currentTask?.cancel()
                currentTask = nil
            }
        }
    }

    /// Delete all seasons and episodes in a series
    private func deleteSeriesContent(seriesID: String) {
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seriesEpisodes = allStoredItems.filter { $0.seriesID == seriesID && $0.type == .episode }
        let seriesSeasons = allStoredItems.filter { $0.seriesID == seriesID && $0.type == .season }

        // Delete all episodes
        for episode in seriesEpisodes {
            queue.removeAll(where: { $0.id == episode.id })
            itemStates.removeValue(forKey: episode.id)
            if currentTask?.id == episode.id {
                currentTask?.cancel()
                currentTask = nil
            }
            deleteItem(itemID: episode.id)
        }

        // Delete all seasons
        for season in seriesSeasons {
            deleteSeasonEpisodes(seasonID: season.id, seriesID: seriesID)
            queue.removeAll(where: { $0.id == season.id })
            itemStates.removeValue(forKey: season.id)
            deleteItem(itemID: season.id)
        }

        // Also remove any queued items for this series
        let queuedItems = queue.filter { $0.seriesID == seriesID }
        for queuedItem in queuedItems {
            queue.removeAll(where: { $0.id == queuedItem.id })
            itemStates.removeValue(forKey: queuedItem.id)
            if currentTask?.id == queuedItem.id {
                currentTask?.cancel()
                currentTask = nil
            }
        }
    }

    // MARK: - Queue Processing

    private func processNextInQueue() {
        // Don't start new download if one is active
        guard currentTask == nil || currentTask?.state.isActive == false else { return }

        // Find next pending item
        guard let nextItem = queue.first(where: { itemStates[$0.id] == .pending }) else {
            state = .idle
            return
        }

        startDownload(for: nextItem)
    }

    private func startDownload(for queueItem: DownloadQueueItem) {
        Task {
            do {
                // Fetch the full item from the API
                let item = try await queueService.fetchItem(itemID: queueItem.id)

                await MainActor.run {
                    let task = DownloadTask(item: item, queueItem: queueItem)

                    // Set up completion handler
                    task.onComplete = { [weak self] result in
                        Task { @MainActor in
                            self?.handleDownloadCompletion(queueItem: queueItem, result: result)
                        }
                    }

                    // Observe task state changes
                    currentTaskCancellable = task.$state
                        .receive(on: RunLoop.main)
                        .sink { [weak self] taskState in
                            // Map DownloadTask.State to DownloadItemState
                            let itemState: DownloadItemState = switch taskState {
                            case .pending: .pending
                            case .downloading: .downloading
                            case .paused: .paused
                            case .complete: .complete
                            case .error: .error
                            case .cancelled: .cancelled
                            }
                            self?.itemStates[queueItem.id] = itemState
                            // Track progress separately
                            if let progress = taskState.progress {
                                self?.itemProgress[queueItem.id] = progress
                            }
                        }

                    currentTask = task
                    state = .downloading(itemID: queueItem.id)
                    itemStates[queueItem.id] = .downloading

                    // Check if there's resume data for this item
                    let hasResumeData = StoredValues[.User.downloadResumeInfo(itemID: queueItem.id)] != nil
                    if hasResumeData {
                        task.resumeFromPaused()
                    } else {
                        task.download()
                    }
                }
            } catch {
                await MainActor.run {
                    itemStates[queueItem.id] = .error
                    logger.error("Failed to fetch item for download: \(error.localizedDescription)")
                    processNextInQueue()
                }
            }
        }
    }

    @MainActor
    private func handleDownloadCompletion(queueItem: DownloadQueueItem, result: Result<StoredDownloadItem, Error>) {
        // Guard against deleted items (check if still in queue)
        guard queue.contains(where: { $0.id == queueItem.id }) else {
            logger.info("Ignoring completion for deleted item: \(queueItem.name)")
            return
        }

        switch result {
        case let .success(storedItem):
            // Save to CoreStore immediately (all item types)
            if let userSession = Container.shared.currentUserSession() {
                do {
                    try AnyStoredData.store(
                        value: storedItem,
                        key: storedItem.id,
                        ownerID: userSession.user.id,
                        domain: "downloads"
                    )
                    invalidateCache()
                } catch {
                    logger.error("Failed to save downloaded item to CoreStore: \(error.localizedDescription)")
                }
            }

            // Add to completed items array (only movies and series for main downloads view)
            // Episodes and seasons are accessible via navigation from series
            // This array is used for reactive UI updates, CoreStore is the source of truth
            let downloadedItem = DownloadItemDto(from: storedItem)
            if storedItem.type == .movie || storedItem.type == .series {
                // Check if already exists (shouldn't happen, but be safe)
                if !completedItems.contains(where: { $0.id == downloadedItem.id }) {
                    completedItems.append(downloadedItem)
                }
            }

            // Remove from queue
            queue.removeAll(where: { $0.id == queueItem.id })
            itemStates[queueItem.id] = .complete
            itemProgress[queueItem.id] = 1.0

            logger.info("Completed download: \(downloadedItem.name)")

        case let .failure(error):
            itemStates[queueItem.id] = .error
            itemProgress.removeValue(forKey: queueItem.id)
            logger.error("Download failed: \(error.localizedDescription)")
        }

        // Clean up
        currentTask = nil
        currentTaskCancellable?.cancel()
        currentTaskCancellable = nil

        persistQueue()

        // Process next item
        processNextInQueue()
    }

    // MARK: - Persistence

    private func persistQueue() {
        StoredValues[.User.downloadQueue] = queue

        // Also persist individual states
        for (itemID, state) in itemStates {
            StoredValues[.User.downloadState(itemID: itemID)] = state
        }
    }

    private func loadPersistedQueue() {
        queue = StoredValues[.User.downloadQueue]

        // Load states for each queued item
        for item in queue {
            itemStates[item.id] = StoredValues[.User.downloadState(itemID: item.id)]
        }
    }

    /// Load all downloaded items from CoreStore as StoredDownloadItem (cached)
    private func loadStoredItemsFromCoreStore() -> [StoredDownloadItem] {
        // Return cached items if available
        if let cached = cachedStoredItems {
            return cached
        }

        guard let userSession = Container.shared.currentUserSession() else { return [] }

        do {
            let clause = try AnyStoredData.fetchClause(ownerID: userSession.user.id, domain: "downloads")
            let storedData = try SwiftfinStore.dataStack.fetchAll(clause)

            let items = storedData.compactMap { data -> StoredDownloadItem? in
                guard let itemData = data.data,
                      let item = try? JSONDecoder().decode(StoredDownloadItem.self, from: itemData)
                else {
                    return nil
                }
                return item
            }

            // Cache the results
            cachedStoredItems = items
            return items
        } catch {
            logger.error("Failed to load completed items from CoreStore: \(error.localizedDescription)")
            return []
        }
    }

    /// Invalidate the cached stored items (call after adding or removing items)
    private func invalidateCache() {
        cachedStoredItems = nil
    }

    private func loadCompletedItems() {
        // Load from CoreStore (primary source of truth)
        let allStoredItems = loadStoredItemsFromCoreStore()

        // Convert to DownloadItemDto and filter to only movies/series for completedItems array
        // Episodes and seasons are accessible via navigation from series
        completedItems = allStoredItems
            .filter { $0.type == .movie || $0.type == .series }
            .map { DownloadItemDto(from: $0) }
    }

    // MARK: - Legacy Compatibility

    /// Lightweight status information for a download item
    struct DownloadItemStatus {
        let state: DownloadItemState
        let progress: Double?
        let error: String?
    }

    /// Status information for aggregated downloads (seasons/series)
    struct AggregatedDownloadStatus {
        let totalEpisodes: Int
        let downloadedEpisodes: Int
        let pendingEpisodes: Int
        let downloadingEpisodes: Int
        let isComplete: Bool
        let isPartiallyDownloaded: Bool
        let progress: Double // 0.0 to 1.0
    }

    /// Get download status for a season by aggregating child episodes
    func getSeasonDownloadStatus(seasonID: String, seriesID: String) -> AggregatedDownloadStatus {
        // Get all episodes for this season from CoreStore
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seasonEpisodes = allStoredItems.filter { $0.seasonID == seasonID && $0.seriesID == seriesID && $0.type == .episode }

        let downloadedCount = seasonEpisodes.count

        // Count episodes in queue for this season
        let queuedEpisodes = queue.filter { $0.seasonID == seasonID && $0.seriesID == seriesID && $0.type == .episode }
        let pendingCount = queuedEpisodes.filter { itemStates[$0.id] == .pending || itemStates[$0.id] == nil }.count
        let downloadingCount = queuedEpisodes.filter { itemStates[$0.id] == .downloading }.count

        // We need to know the total expected episodes - try to get from API or use downloaded + queued as estimate
        // For now, use downloaded + queued as total (will be accurate once all are queued)
        let totalCount = max(downloadedCount + queuedEpisodes.count, downloadedCount)

        let isComplete = totalCount > 0 && downloadedCount == totalCount && queuedEpisodes.isEmpty
        let isPartiallyDownloaded = downloadedCount > 0 && downloadedCount < totalCount
        let progress = totalCount > 0 ? Double(downloadedCount) / Double(totalCount) : 0.0

        return AggregatedDownloadStatus(
            totalEpisodes: totalCount,
            downloadedEpisodes: downloadedCount,
            pendingEpisodes: pendingCount,
            downloadingEpisodes: downloadingCount,
            isComplete: isComplete,
            isPartiallyDownloaded: isPartiallyDownloaded,
            progress: progress
        )
    }

    /// Get download status for a series by aggregating all child episodes
    func getSeriesDownloadStatus(seriesID: String) -> AggregatedDownloadStatus {
        // Get all episodes for this series from CoreStore
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seriesEpisodes = allStoredItems.filter { $0.seriesID == seriesID && $0.type == .episode }

        let downloadedCount = seriesEpisodes.count

        // Count episodes in queue for this series
        let queuedEpisodes = queue.filter { $0.seriesID == seriesID && $0.type == .episode }
        let pendingCount = queuedEpisodes.filter { itemStates[$0.id] == .pending || itemStates[$0.id] == nil }.count
        let downloadingCount = queuedEpisodes.filter { itemStates[$0.id] == .downloading }.count

        // Use downloaded + queued as total estimate
        let totalCount = max(downloadedCount + queuedEpisodes.count, downloadedCount)

        let isComplete = totalCount > 0 && downloadedCount == totalCount && queuedEpisodes.isEmpty
        let isPartiallyDownloaded = downloadedCount > 0 && downloadedCount < totalCount
        let progress = totalCount > 0 ? Double(downloadedCount) / Double(totalCount) : 0.0

        return AggregatedDownloadStatus(
            totalEpisodes: totalCount,
            downloadedEpisodes: downloadedCount,
            pendingEpisodes: pendingCount,
            downloadingEpisodes: downloadingCount,
            isComplete: isComplete,
            isPartiallyDownloaded: isPartiallyDownloaded,
            progress: progress
        )
    }

    /// Get status for an item (preferred method)
    func status(for itemID: String) -> DownloadItemStatus? {
        // Check current task
        if let currentTask, currentTask.id == itemID {
            let progress = currentTask.state.progress
            let errorMessage: String?
            if case let .error(message) = currentTask.state {
                errorMessage = message
            } else {
                errorMessage = nil
            }
            // Map DownloadTask.State to DownloadItemState
            let itemState: DownloadItemState = switch currentTask.state {
            case .pending: .pending
            case .downloading: .downloading
            case .paused: .paused
            case .complete: .complete
            case .error: .error
            case .cancelled: .cancelled
            }
            return DownloadItemStatus(
                state: itemState,
                progress: progress,
                error: errorMessage
            )
        }

        // Check queue
        if let state = itemStates[itemID] {
            let progress = itemProgress[itemID]
            return DownloadItemStatus(state: state, progress: progress, error: nil)
        }

        // Check completed
        if completedItems.contains(where: { $0.id == itemID }) {
            return DownloadItemStatus(state: .complete, progress: 1.0, error: nil)
        }

        // Check CoreStore
        if let userSession = Container.shared.currentUserSession() {
            if let _: StoredDownloadItem = try? AnyStoredData.fetch(itemID, ownerID: userSession.user.id, domain: "downloads") {
                return DownloadItemStatus(state: .complete, progress: 1.0, error: nil)
            }
        }

        return nil
    }

    /// Get aggregated status for a season or series item
    func aggregatedStatus(for itemID: String, type: BaseItemKind) -> AggregatedDownloadStatus? {
        guard let userSession = Container.shared.currentUserSession() else { return nil }

        // Try to get the item from CoreStore to get seriesID/seasonID
        guard let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(itemID, ownerID: userSession.user.id, domain: "downloads")
        else {
            // Item not in CoreStore, check if it's in queue
            if let queueItem = queue.first(where: { $0.id == itemID }) {
                if queueItem.type == .season, let seriesID = queueItem.seriesID {
                    return getSeasonDownloadStatus(seasonID: itemID, seriesID: seriesID)
                } else if queueItem.type == .series {
                    return getSeriesDownloadStatus(seriesID: itemID)
                }
            }
            return nil
        }

        switch type {
        case .season:
            guard let seriesID = storedItem.seriesID else { return nil }
            return getSeasonDownloadStatus(seasonID: itemID, seriesID: seriesID)
        case .series:
            return getSeriesDownloadStatus(seriesID: itemID)
        default:
            return nil
        }
    }

    /// Get a downloaded episode as DownloadItemDto for offline playback
    func downloadedEpisode(for episode: BaseItemDto) -> DownloadItemDto? {
        guard let episodeID = episode.id,
              let userSession = Container.shared.currentUserSession(),
              let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                  episodeID,
                  ownerID: userSession.user.id,
                  domain: "downloads"
              )
        else {
            return nil
        }

        return DownloadItemDto(from: storedItem)
    }

    // MARK: - File Deletion

    /// Determine the folder path for an item from its properties
    private func folderPathForItem(id: String, type: BaseItemKind, seriesID: String?, seasonID: String?) -> URL? {
        switch type {
        case .movie:
            return URL.movieDownloadFolder(itemID: id)
        case .series:
            return URL.seriesDownloadFolder(seriesID: id)
        case .season:
            guard let seriesID = seriesID else {
                return nil
            }
            return URL.seasonDownloadFolder(seriesID: seriesID, seasonID: id)
        case .episode:
            guard let seriesID = seriesID, let seasonID = seasonID else {
                return nil
            }
            return URL.episodeDownloadFolder(seriesID: seriesID, seasonID: seasonID, episodeID: id)
        default:
            // For other types, try movies folder
            return URL.movieDownloadFolder(itemID: id)
        }
    }

    /// Unified method to delete an item's files and CoreStore entry
    private func deleteItem(itemID: String) {
        // 1. Try to get item from CoreStore to determine folder path
        var folderPath: URL?
        var hasCoreStoreEntry = false

        if let userSession = Container.shared.currentUserSession() {
            if let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                itemID,
                ownerID: userSession.user.id,
                domain: "downloads"
            ) {
                hasCoreStoreEntry = true
                folderPath = folderPathForItem(
                    id: storedItem.id,
                    type: storedItem.type,
                    seriesID: storedItem.seriesID,
                    seasonID: storedItem.seasonID
                )
            } else if let queueItem = queue.first(where: { $0.id == itemID }) {
                // If not in CoreStore, check the queue for metadata
                folderPath = folderPathForItem(
                    id: queueItem.id,
                    type: queueItem.type,
                    seriesID: queueItem.seriesID,
                    seasonID: queueItem.seasonID
                )
            }
        }

        // 2. Use type-based path lookup since we know the structure
        if folderPath == nil {
            folderPath = folderPathForItem(id: itemID, type: .movie, seriesID: nil, seasonID: nil)
        }

        // 3. Delete files
        if let path = folderPath {
            do {
                try FileManager.default.removeItem(at: path)
                logger.info("Successfully deleted download folder: \(path.path)")
            } catch {
                logger.error("Failed to delete download folder \(path.path): \(error.localizedDescription)")
            }
        }

        // 4. Delete from CoreStore
        if hasCoreStoreEntry || folderPath != nil {
            deleteFromCoreStore(itemID: itemID)
        }
    }

    private func deleteFromCoreStore(itemID: String) {
        guard let userSession = Container.shared.currentUserSession() else { return }
        do {
            try AnyStoredData.delete(key: itemID, ownerID: userSession.user.id, domain: "downloads")
            invalidateCache()
        } catch {
            logger.error("Failed to delete item from CoreStore: \(error.localizedDescription)")
        }
    }
}
