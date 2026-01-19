//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Files
import Foundation
import JellyfinAPI
import Logging

extension Container {
    var downloadManager: Factory<DownloadManager> {
        self { DownloadManager() }.shared
    }
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

    @Injected(\.downloadFileSystemService)
    private var fileSystemService: DownloadFileSystemService

    @Published
    private(set) var state: State = .idle

    @Published
    private(set) var queue: [DownloadQueueItem] = []

    @Published
    private(set) var currentTask: DownloadTask?

    @Published
    private(set) var completedItems: [StoredDownloadItem] = []

    @Published
    private(set) var itemStates: [String: DownloadItemState] = [:]

    @Published
    private(set) var itemProgress: [String: Double] = [:]

    /// Notifies observers when any download-related state changes (additions, deletions, completions)
    @Published
    private(set) var downloadsUpdated: Void = ()

    private var cancellables = Set<AnyCancellable>()
    private var currentTaskCancellable: AnyCancellable?

    private var cachedStoredItems: [StoredDownloadItem]?
    private var cachedUserID: String?
    private var currentUserID: String? {
        if let user = Container.shared.currentUserSession()?.user {
            return user.id
        }

        switch Defaults[.lastSignedInUserID] {
        case let .signedIn(userID):
            return userID
        case .signedOut:
            return nil
        }
    }

    // MARK: - Initialization

    fileprivate init() {
        observeUserSessionChanges()
        createDownloadDirectories()
        loadPersistedQueue()
        loadCompletedItems()
        restoreDownloadProgress()

        // Initialize background download session early
        _ = BackgroundDownloadSession.shared

        if !queue.isEmpty {
            processNextInQueue()
        }
    }

    /// Restore download progress from persisted storage for paused items
    private func restoreDownloadProgress() {
        for item in queue {
            if itemStates[item.id] == .paused {
                // Load persisted progress
                let bytesDownloaded = StoredValues[
                    .User.downloadBytesDownloaded(itemID: item.id)
                ]
                let totalBytes = StoredValues[
                    .User.downloadTotalBytes(itemID: item.id)
                ]
                if totalBytes > 0 {
                    itemProgress[item.id] =
                        Double(bytesDownloaded) / Double(totalBytes)
                }
            }
        }
    }

    // MARK: - Directory Management

    private func createDownloadDirectories() {
        fileSystemService.createDownloadDirectories()
    }

    func clearTmp() {
        fileSystemService.clearTmp()
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
                logger.error(
                    "Failed to build queue for item: \(error.localizedDescription)"
                )
            }
        }
    }

    private func addToQueue(_ items: [DownloadQueueItem]) {
        guard let userID = currentUserID else { return }

        // Filter out items already in queue, completed items array, or CoreStore
        let newItems = items.filter { newItem in
            // Skip if already in queue
            if queue.contains(where: { $0.id == newItem.id }) {
                return false
            }

            // Skip if in completed items array (check ID only)
            if completedItems.contains(where: { $0.id == newItem.id }) {
                return false
            }

            // Skip if already downloaded (check CoreStore for all item types including episodes)
            if (try? AnyStoredData.fetch(
                newItem.id,
                ownerID: userID,
                domain: "downloads"
            ) as StoredDownloadItem?) != nil {
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

    func resume(itemID: String) {
        // Check if there's resume data available
        let hasResumeData =
            StoredValues[.User.downloadResumeInfo(itemID: itemID)] != nil

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

    func retry(itemID: String) {
        itemStates[itemID] = .pending
        persistQueue()

        if currentTask == nil {
            processNextInQueue()
        }
    }

    func delete(itemID: String) {
        deleteGroup(id: itemID)
    }

    func deleteGroup(id: String) {
        guard let userID = currentUserID else { return }

        // Find all items in this group from the queue
        let queuedItemsInGroup = queue.filter {
            $0.id == id || $0.groupId == id
        }

        // Handle cases where deletion affects series or seasons
        var childrenIDs: Set<String> = []
        if let firstItem = queuedItemsInGroup.first {
            if firstItem.type == .series {
                childrenIDs = Set(queue.filter { $0.seriesID == id }.map(\.id))
            } else if firstItem.type == .season {
                childrenIDs = Set(queue.filter { $0.seasonID == id }.map(\.id))
            }
        }

        let allIDsToDelete = Set(queuedItemsInGroup.map(\.id)).union(
            childrenIDs
        ).union([id])

        for itemID in allIDsToDelete {
            var itemType: BaseItemKind?
            var seriesID: String?
            if let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                itemID,
                ownerID: userID,
                domain: "downloads"
            ) {
                itemType = storedItem.type
                seriesID = storedItem.seriesID
            } else if let queueItem = queue.first(where: { $0.id == itemID }) {
                itemType = queueItem.type
                seriesID = queueItem.seriesID
            }

            if let type = itemType {
                switch type {
                case .season:
                    if let seriesID = seriesID {
                        deleteSeasonEpisodes(
                            seasonID: itemID,
                            seriesID: seriesID
                        )
                    }
                case .series:
                    deleteSeriesContent(seriesID: itemID)
                default:
                    break
                }
            }

            queue.removeAll(where: { $0.id == itemID })
            itemStates.removeValue(forKey: itemID)
            itemProgress.removeValue(forKey: itemID)

            BackgroundDownloadSession.shared.cancelDownload(itemID: itemID)

            if let resumeInfo = StoredValues[
                .User.downloadResumeInfo(itemID: itemID)
            ] {
                BackgroundDownloadSession.shared.deleteResumeData(
                    resumeInfo.resumeData
                )
            }
            StoredValues[.User.downloadResumeInfo(itemID: itemID)] = nil
            StoredValues[.User.downloadBytesDownloaded(itemID: itemID)] = 0
            StoredValues[.User.downloadTotalBytes(itemID: itemID)] = 0

            if currentTask?.id == itemID {
                currentTask?.cancel()
                currentTask = nil
                currentTaskCancellable?.cancel()
                currentTaskCancellable = nil
            }

            if completedItems.contains(where: { $0.id == itemID }) {
                completedItems.removeAll(where: { $0.id == itemID })
            }

            deleteItem(itemID: itemID)
        }

        persistQueue()
        downloadsUpdated = ()
        processNextInQueue()
    }

    private func deleteSeasonEpisodes(seasonID: String, seriesID: String) {
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seasonEpisodes = allStoredItems.filter {
            $0.seasonID == seasonID && $0.seriesID == seriesID
                && $0.type == .episode
        }

        // Delete each episode
        for episode in seasonEpisodes {
            queue.removeAll(where: { $0.id == episode.id })
            itemStates.removeValue(forKey: episode.id)

            if currentTask?.id == episode.id {
                currentTask?.cancel()
                currentTask = nil
            }

            deleteItem(itemID: episode.id)
        }

        // Also remove any queued episodes for this season
        let queuedEpisodes = queue.filter {
            $0.seasonID == seasonID && $0.seriesID == seriesID
                && $0.type == .episode
        }
        for queuedEpisode in queuedEpisodes {
            queue.removeAll(where: { $0.id == queuedEpisode.id })
            itemStates.removeValue(forKey: queuedEpisode.id)
            if currentTask?.id == queuedEpisode.id {
                currentTask?.cancel()
                currentTask = nil
            }
        }
    }

    private func deleteSeriesContent(seriesID: String) {
        let allStoredItems = loadStoredItemsFromCoreStore()
        let seriesEpisodes = allStoredItems.filter {
            $0.seriesID == seriesID && $0.type == .episode
        }
        let seriesSeasons = allStoredItems.filter {
            $0.seriesID == seriesID && $0.type == .season
        }

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
        guard currentTask == nil || currentTask?.state.isActive == false else {
            return
        }

        guard let nextItem = queue.first(where: { itemStates[$0.id] == .pending })
        else {
            state = .idle
            return
        }

        startDownload(for: nextItem)
    }

    private func startDownload(for queueItem: DownloadQueueItem) {
        Task {
            do {
                // Fetch the full item from the API
                let item = try await queueService.fetchItem(
                    itemID: queueItem.id
                )

                await MainActor.run {
                    let task = DownloadTask(item: item, queueItem: queueItem)

                    // Set up completion handler
                    task.onComplete = { [weak self] result in
                        Task { @MainActor in
                            self?.handleDownloadCompletion(
                                queueItem: queueItem,
                                result: result
                            )
                        }
                    }

                    currentTaskCancellable = task.$state
                        .receive(on: RunLoop.main)
                        .sink { [weak self] taskState in
                            let itemState: DownloadItemState =
                                switch taskState {
                                case .pending: .pending
                                case .downloading: .downloading
                                case .paused: .paused
                                case .complete: .complete
                                case .error: .error
                                case .cancelled: .cancelled
                                }
                            self?.itemStates[queueItem.id] = itemState
                            if let progress = taskState.progress {
                                self?.itemProgress[queueItem.id] = progress
                            }
                        }

                    currentTask = task
                    state = .downloading(itemID: queueItem.id)
                    itemStates[queueItem.id] = .downloading

                    // Check if there's resume data for this item
                    let hasResumeData =
                        StoredValues[
                            .User.downloadResumeInfo(itemID: queueItem.id)
                        ] != nil
                    if hasResumeData {
                        task.resumeFromPaused()
                    } else {
                        task.download()
                    }
                }
            } catch {
                await MainActor.run {
                    itemStates[queueItem.id] = .error
                    logger.error(
                        "Failed to fetch item for download: \(error.localizedDescription)"
                    )
                    processNextInQueue()
                }
            }
        }
    }

    @MainActor
    private func handleDownloadCompletion(
        queueItem: DownloadQueueItem,
        result: Result<StoredDownloadItem, Error>
    ) {
        // Guard against deleted items (check if still in queue)
        guard queue.contains(where: { $0.id == queueItem.id }) else {
            logger.info(
                "Ignoring completion for deleted item: \(queueItem.name ?? "Unknown")"
            )
            return
        }

        switch result {
        case let .success(storedItem):
            // Save to CoreStore immediately (all item types)
            if let userID = currentUserID {
                do {
                    try AnyStoredData.store(
                        value: storedItem,
                        key: storedItem.id,
                        ownerID: userID,
                        domain: "downloads"
                    )
                    invalidateCache()
                } catch {
                    logger.error(
                        "Failed to save downloaded item to CoreStore: \(error.localizedDescription)"
                    )
                }
            }

            // Add to completed items array (only movies and series for main downloads view)
            // Episodes and seasons are accessible via navigation from series
            // This array is used for reactive UI updates, CoreStore is the source of truth
            if storedItem.type == .movie || storedItem.type == .series {
                // Check if already exists (shouldn't happen, but be safe)
                if !completedItems.contains(where: { $0.id == storedItem.id }) {
                    completedItems.append(storedItem)
                }
            }

            // Remove from queue
            queue.removeAll(where: { $0.id == queueItem.id })
            itemStates[queueItem.id] = .complete
            itemProgress[queueItem.id] = 1.0

            logger.info(
                "Completed download: \(storedItem.item.name ?? "Unknown")"
            )

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
        downloadsUpdated = ()
        processNextInQueue()
    }

    // MARK: - Persistence

    private func persistQueue() {
        StoredValues[.User.downloadQueue] = queue

        for (itemID, state) in itemStates {
            StoredValues[.User.downloadState(itemID: itemID)] = state
        }
    }

    private func loadPersistedQueue() {
        queue = StoredValues[.User.downloadQueue]

        for item in queue {
            itemStates[item.id] =
                StoredValues[.User.downloadState(itemID: item.id)]
        }
    }

    /// Load all downloaded items from CoreStore as StoredDownloadItem (cached)
    private func loadStoredItemsFromCoreStore() -> [StoredDownloadItem] {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                loadStoredItemsFromCoreStore()
            }
        }

        // Return cached items if available
        if let cached = cachedStoredItems, cachedUserID == currentUserID {
            return cached
        }

        guard let userID = currentUserID else { return [] }

        do {
            let clause = try AnyStoredData.fetchClause(
                ownerID: userID,
                domain: "downloads"
            )
            let storedData = try SwiftfinStore.dataStack.fetchAll(clause)

            let items = storedData.compactMap { data -> StoredDownloadItem? in
                guard let itemData = data.data,
                      let item = try? JSONDecoder().decode(
                          StoredDownloadItem.self,
                          from: itemData
                      )
                else {
                    return nil
                }
                return item
            }

            cachedStoredItems = items
            cachedUserID = userID
            return items
        } catch {
            logger.error(
                "Failed to load completed items from CoreStore: \(error.localizedDescription)"
            )
            return []
        }
    }

    private func invalidateCache() {
        cachedStoredItems = nil
        cachedUserID = nil
    }

    private func observeUserSessionChanges() {
        Notifications[.didSignIn]
            .publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateCache()
                self?.loadCompletedItems()
                self?.downloadsUpdated = ()
            }
            .store(in: &cancellables)

        Notifications[.didSignOut]
            .publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.invalidateCache()
                self?.completedItems.removeAll()
                self?.downloadsUpdated = ()
            }
            .store(in: &cancellables)
    }

    private func loadCompletedItems() {
        let allStoredItems = loadStoredItemsFromCoreStore()

        // Episodes and seasons are accessible via navigation from series, so only include movies/series here
        completedItems =
            allStoredItems
                .filter { $0.type == .movie || $0.type == .series }
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
    func getSeasonDownloadStatus(seasonID: String, seriesID: String)
        -> AggregatedDownloadStatus
    {
        aggregateEpisodeStatus { item in
            item.seasonID == seasonID && item.seriesID == seriesID
        } queueFilter: { item in
            item.seasonID == seasonID && item.seriesID == seriesID
        }
    }

    /// Get download status for a series by aggregating all child episodes
    func getSeriesDownloadStatus(seriesID: String) -> AggregatedDownloadStatus {
        aggregateEpisodeStatus { item in
            item.seriesID == seriesID
        } queueFilter: { item in
            item.seriesID == seriesID
        }
    }

    /// Unified helper to aggregate episode download status based on filter predicates.
    private func aggregateEpisodeStatus(
        storedFilter: (StoredDownloadItem) -> Bool,
        queueFilter: (DownloadQueueItem) -> Bool
    ) -> AggregatedDownloadStatus {
        let allStoredItems = loadStoredItemsFromCoreStore()
        let matchingEpisodes = allStoredItems.filter {
            storedFilter($0) && $0.type == .episode
        }
        let downloadedCount = matchingEpisodes.count

        let queuedEpisodes = queue.filter {
            queueFilter($0) && $0.type == .episode
        }
        let pendingCount = queuedEpisodes.filter {
            itemStates[$0.id] == .pending || itemStates[$0.id] == nil
        }.count
        let downloadingCount = queuedEpisodes.filter {
            itemStates[$0.id] == .downloading
        }.count

        let totalCount = max(
            downloadedCount + queuedEpisodes.count,
            downloadedCount
        )
        let isComplete =
            totalCount > 0 && downloadedCount == totalCount
                && queuedEpisodes.isEmpty
        let isPartiallyDownloaded =
            downloadedCount > 0 && downloadedCount < totalCount
        let progress =
            totalCount > 0 ? Double(downloadedCount) / Double(totalCount) : 0.0

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
            let itemState: DownloadItemState =
                switch currentTask.state {
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
            return DownloadItemStatus(
                state: state,
                progress: progress,
                error: nil
            )
        }

        // Check completed
        if completedItems.contains(where: { $0.id == itemID }) {
            return DownloadItemStatus(
                state: .complete,
                progress: 1.0,
                error: nil
            )
        }

        // Check CoreStore
        if let userID = currentUserID {
            if (try? AnyStoredData.fetch(
                itemID,
                ownerID: userID,
                domain: "downloads"
            ) as StoredDownloadItem?) != nil {
                return DownloadItemStatus(
                    state: .complete,
                    progress: 1.0,
                    error: nil
                )
            }
        }

        return nil
    }

    /// Get aggregated status for a season or series item
    func aggregatedStatus(for itemID: String, type: BaseItemKind)
        -> AggregatedDownloadStatus?
    {
        guard let userID = currentUserID else { return nil }

        // Try to get the item from CoreStore, then check the queue if not found
        guard let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
            itemID,
            ownerID: userID,
            domain: "downloads"
        )
        else {
            // Item not in CoreStore, check if it's in queue
            if let queueItem = queue.first(where: { $0.id == itemID }) {
                if queueItem.type == .season, let seriesID = queueItem.seriesID {
                    return getSeasonDownloadStatus(
                        seasonID: itemID,
                        seriesID: seriesID
                    )
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
    func downloadedEpisode(for episode: BaseItemDto) -> StoredDownloadItem? {
        guard let episodeID = episode.id,
              let userID = currentUserID,
              let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                  episodeID,
                  ownerID: userID,
                  domain: "downloads"
              )
        else {
            return nil
        }

        return storedItem
    }

    // MARK: - File Deletion

    /// Determine the folder path for an item from its properties
    private func folderPathForItem(
        id: String,
        type: BaseItemKind,
        seriesID: String?,
        seasonID: String?
    ) -> URL? {
        switch type {
        case .movie:
            return fileSystemService.folderPath(
                for: id,
                type: .movie,
                seriesID: nil,
                seasonID: nil
            )
        case .series:
            return fileSystemService.folderPath(
                for: id,
                type: .series,
                seriesID: nil,
                seasonID: nil
            )
        case .season:
            return fileSystemService.folderPath(
                for: id,
                type: .season,
                seriesID: seriesID,
                seasonID: nil
            )
        case .episode:
            return fileSystemService.folderPath(
                for: id,
                type: .episode,
                seriesID: seriesID,
                seasonID: seasonID
            )
        default:
            return fileSystemService.folderPath(
                for: id,
                type: .movie,
                seriesID: nil,
                seasonID: nil
            )
        }
    }

    /// Unified method to delete an item's files and CoreStore entry
    private func deleteItem(itemID: String) {
        // 1. Try to get item from CoreStore to determine folder path(s)
        var pathsToDelete: [URL] = []
        var hasCoreStoreEntry = false

        if let userID = currentUserID {
            if let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                itemID,
                ownerID: userID,
                domain: "downloads"
            ) {
                hasCoreStoreEntry = true
                if let path = fileSystemService.folderPath(for: storedItem.item) {
                    pathsToDelete.append(path)
                }

                if let legacyPath = fileSystemService.folderPath(
                    for: storedItem.id,
                    type: storedItem.type,
                    seriesID: storedItem.seriesID,
                    seasonID: storedItem.seasonID
                ) {
                    pathsToDelete.append(legacyPath)
                }
            } else if let queueItem = queue.first(where: { $0.id == itemID }) {
                // If not in CoreStore, check the queue for metadata
                if let path = fileSystemService.folderPath(
                    for: queueItem.id,
                    type: queueItem.type,
                    seriesID: queueItem.seriesID,
                    seasonID: queueItem.seasonID
                ) {
                    pathsToDelete.append(path)
                }
            }
        }

        // 2. Delete files
        if !pathsToDelete.isEmpty {
            for path in Set(pathsToDelete) {
                fileSystemService.deleteFolder(at: path)
            }
        }

        // 3. Delete from CoreStore
        if hasCoreStoreEntry || !pathsToDelete.isEmpty {
            deleteFromCoreStore(itemID: itemID)
        }
    }

    private func deleteFromCoreStore(itemID: String) {
        guard let userID = currentUserID else { return }
        do {
            try AnyStoredData.delete(
                key: itemID,
                ownerID: userID,
                domain: "downloads"
            )
            invalidateCache()
        } catch {
            logger.error(
                "Failed to delete item from CoreStore: \(error.localizedDescription)"
            )
        }
    }
}
