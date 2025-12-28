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
import OrderedCollections
import SwiftUI

// MARK: - DownloadPagingLibraryViewModel

/// ViewModel for browsing downloaded content with filtering and sorting support
@MainActor
@Stateful
final class DownloadPagingLibraryViewModel: ViewModel {

    // MARK: - Action

    @CasePathable
    enum Action {
        case refresh
        case filter
        case delete(String)

        var transition: Transition {
            switch self {
            case .refresh:
                .to(.content) // Will be updated to .empty in applyFiltersAndSort if needed
            case .filter:
                .none // No state change, just update elements
            case .delete:
                .none // No state change, just remove item
            }
        }
    }

    // MARK: - State

    enum State: Hashable {
        case initial
        case content
        case empty
        case error
    }

    // MARK: - Properties

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    /// All downloaded items
    @Published
    var elements: IdentifiedArray<Int, DownloadItemDto> = IdentifiedArray([], id: \.unwrappedIDHashOrZero, uniquingIDsWith: { x, _ in x })

    /// Filter view model for local filtering
    @Published
    var filterViewModel: DownloadFilterViewModel = DownloadFilterViewModel()

    /// Current download task (if any)
    @Published
    var currentDownload: DownloadTask?

    /// Download queue
    @Published
    var queue: [DownloadQueueItem] = []

    /// Item states
    @Published
    var itemStates: [String: DownloadItemState] = [:]

    // MARK: - Initialization

    override nonisolated init() {
        super.init()

        // Setup observers and initial load on main actor
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setupObservers()
            // Call refresh action directly
            self._refresh()
        }
    }

    private func setupObservers() {
        downloadManager.$completedItems
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                self?.applyFiltersAndSort(to: items)
            }
            .store(in: &cancellables)

        downloadManager.$currentTask
            .receive(on: RunLoop.main)
            .sink { [weak self] task in
                self?.currentDownload = task
            }
            .store(in: &cancellables)

        downloadManager.$queue
            .receive(on: RunLoop.main)
            .sink { [weak self] queue in
                self?.queue = queue
            }
            .store(in: &cancellables)

        downloadManager.$itemStates
            .receive(on: RunLoop.main)
            .sink { [weak self] states in
                self?.itemStates = states
            }
            .store(in: &cancellables)

        // Observe filter changes
        filterViewModel.$currentFilters
            .dropFirst()
            .debounce(for: 0.3, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?._filter()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Stateful Actions

    @Function(\Action.Cases.refresh)
    private func _refresh() {
        let items = downloadManager.completedItems
        filterViewModel.updateAvailableFilters(from: items)
        applyFiltersAndSort(to: items)
        // State will be updated by applyFiltersAndSort
    }

    @Function(\Action.Cases.filter)
    private func _filter() {
        applyFiltersAndSort(to: downloadManager.completedItems)
        // State will be updated by applyFiltersAndSort
    }

    @Function(\Action.Cases.delete)
    private func _delete(_ _itemID: String) {
        downloadManager.delete(itemID: _itemID)
    }

    // MARK: - Public Methods (for view access)

    func performRefresh() {
        _refresh()
    }

    // MARK: - Filtering and Sorting

    private func applyFiltersAndSort(to items: [DownloadItemDto]) {
        var filteredItems = items
        let filters = filterViewModel.currentFilters

        // Filter by item type
        if !filters.itemTypes.isEmpty {
            filteredItems = filteredItems.filter { filters.itemTypes.contains($0.type) }
        }

        // Filter by genre
        if !filters.genres.isEmpty {
            let genreValues = Set(filters.genres.map(\.value))
            filteredItems = filteredItems.filter { item in
                guard let genres = item.genres else { return false }
                return !Set(genres).isDisjoint(with: genreValues)
            }
        }

        // Filter by year
        if !filters.years.isEmpty {
            let yearValues = Set(filters.years.compactMap { Int($0.value) })
            filteredItems = filteredItems.filter { item in
                guard let year = item.productionYear else { return false }
                return yearValues.contains(year)
            }
        }

        // Filter by tag
        if !filters.tags.isEmpty {
            let tagValues = Set(filters.tags.map(\.value))
            filteredItems = filteredItems.filter { item in
                guard let tags = item.tags else { return false }
                return !Set(tags).isDisjoint(with: tagValues)
            }
        }

        // Apply sorting
        filteredItems = applySorting(to: filteredItems, sortBy: filters.sortBy, sortOrder: filters.sortOrder)

        // Update elements
        elements = IdentifiedArray(filteredItems, id: \.unwrappedIDHashOrZero, uniquingIDsWith: { x, _ in x })

        // Update state based on elements
        if elements.isEmpty {
            state = .empty
        } else {
            state = .content
        }
    }

    private func applySorting(
        to items: [DownloadItemDto],
        sortBy: [ItemSortBy],
        sortOrder: [ItemSortOrder]
    ) -> [DownloadItemDto] {
        let ascending = sortOrder.first == .ascending

        guard let primarySort = sortBy.first else {
            // Default: sort by download date
            return items.sorted { ascending ? $0.downloadedAt < $1.downloadedAt : $0.downloadedAt > $1.downloadedAt }
        }

        switch primarySort {
        case .name:
            return items.sorted {
                ascending
                    ? ($0.sortName ?? $0.name) < ($1.sortName ?? $1.name)
                    : ($0.sortName ?? $0.name) > ($1.sortName ?? $1.name)
            }
        case .dateLastContentAdded, .dateCreated:
            return items.sorted {
                ascending ? $0.downloadedAt < $1.downloadedAt : $0.downloadedAt > $1.downloadedAt
            }
        case .premiereDate, .productionYear:
            return items.sorted {
                let year0 = $0.productionYear ?? 0
                let year1 = $1.productionYear ?? 0
                return ascending ? year0 < year1 : year0 > year1
            }
        case .communityRating:
            return items.sorted {
                let rating0 = $0.communityRating ?? 0
                let rating1 = $1.communityRating ?? 0
                return ascending ? rating0 < rating1 : rating0 > rating1
            }
        case .criticRating:
            return items.sorted {
                let rating0 = $0.criticRating ?? 0
                let rating1 = $1.criticRating ?? 0
                return ascending ? rating0 < rating1 : rating0 > rating1
            }
        case .runtime:
            return items.sorted {
                let runtime0 = $0.runTimeTicks ?? 0
                let runtime1 = $1.runTimeTicks ?? 0
                return ascending ? runtime0 < runtime1 : runtime0 > runtime1
            }
        case .random:
            return items.shuffled()
        default:
            return items.sorted {
                ascending ? $0.downloadedAt < $1.downloadedAt : $0.downloadedAt > $1.downloadedAt
            }
        }
    }

    // MARK: - Computed Properties

    /// Total size of all downloads (calculated from disk, not from elements)
    var totalDownloadSize: Int64 {
        FileManager.default.downloadsDirectorySize() ?? 0
    }

    /// Formatted total size
    var formattedTotalSize: String {
        FileManager.default.formattedDownloadsSize()
    }

    /// Available storage
    var formattedAvailableStorage: String {
        guard let available = FileManager.default.availableStorage else {
            return "Unknown"
        }
        return FileManager.default.formatBytes(available)
    }

    /// Storage summary
    var storageSummary: String {
        FileManager.default.storageSummary()
    }

    // MARK: - Grouped Queue

    struct DownloadQueueGroup: Identifiable {
        let id: String
        let title: String
        let items: [DownloadQueueItem]
        let totalSize: Int64
        let bytesDownloaded: Int64
        let progress: Double
        let isMainDownload: Bool // True if this group contains the currentDownload
    }

    var groupedQueue: [DownloadQueueGroup] {
        var allItems: [DownloadQueueItem] = []

        // Add current download if it exists
        let currentID = currentDownload?.id
        if let current = currentDownload {
            allItems.append(current.queueItem)
        }

        // Add all items from the queue, ensuring no duplication with current download
        allItems.append(contentsOf: queue.filter { $0.id != currentID })

        // Group items by groupId (falling back to id)
        let grouped = Dictionary(grouping: allItems) { $0.groupId ?? $0.id }

        return grouped.compactMap { groupId, items in
            // Find the "main" item in the group (the playable one)
            let mainItem = items.first(where: { !$0.isMetadataOnly }) ?? items.first
            guard let mainItem = mainItem else { return nil }

            // Calculate group total size
            // Use the stored groupTotalSize if available, otherwise sum what we have
            let currentItemsTotalSize = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let totalGroupSize = max(Int64(0), mainItem.groupTotalSize ?? currentItemsTotalSize)

            // Size of items in this group that have already been fully downloaded
            let completedSizeInBatch = max(Int64(0), totalGroupSize - currentItemsTotalSize)

            // Calculate downloaded bytes: completed items + current active item progress
            var totalBytesDownloaded: Int64 = completedSizeInBatch

            // Add bytes from the active download if it belongs to this group
            if let current = currentDownload, items.contains(where: { $0.id == current.id }) {
                totalBytesDownloaded += current.bytesDownloaded
            }

            let overallProgress = totalGroupSize > 0 ? min(1.0, Double(totalBytesDownloaded) / Double(totalGroupSize)) : 0

            return DownloadQueueGroup(
                id: groupId,
                title: mainItem.name ?? groupId,
                items: items,
                totalSize: totalGroupSize,
                bytesDownloaded: totalBytesDownloaded,
                progress: overallProgress,
                isMainDownload: currentID != nil && items.contains(where: { $0.id == currentID })
            )
        }.sorted { g1, g2 in
            // Keep current download at the top
            if g1.isMainDownload != g2.isMainDownload {
                return g1.isMainDownload
            }
            // Otherwise sort by added date of the first item
            let d1 = g1.items.first?.addedAt ?? Date.distantPast
            let d2 = g2.items.first?.addedAt ?? Date.distantPast
            return d1 < d2
        }
    }
}

// MARK: - DownloadFilterViewModel

/// Filter ViewModel specifically for downloaded content
class DownloadFilterViewModel: ObservableObject {

    @Published
    var currentFilters: DownloadFilterCollection

    @Published
    var availableGenres: [ItemGenre] = []

    @Published
    var availableYears: [ItemYear] = []

    @Published
    var availableTags: [ItemTag] = []

    @Published
    var availableItemTypes: [BaseItemKind] = []

    init() {
        self.currentFilters = DownloadFilterCollection.default
    }

    func updateAvailableFilters(from items: [DownloadItemDto]) {
        // Extract unique genres
        var genreSet = Set<String>()
        for item in items {
            if let genres = item.genres {
                genreSet.formUnion(genres)
            }
        }
        availableGenres = genreSet.sorted().map { ItemGenre(stringLiteral: $0) }

        // Extract unique years
        var yearSet = Set<Int>()
        for item in items {
            if let year = item.productionYear {
                yearSet.insert(year)
            }
        }
        availableYears = yearSet.sorted(by: >).map { ItemYear(integerLiteral: $0) }

        // Extract unique tags
        var tagSet = Set<String>()
        for item in items {
            if let tags = item.tags {
                tagSet.formUnion(tags)
            }
        }
        availableTags = tagSet.sorted().map { ItemTag(stringLiteral: $0) }

        // Extract unique item types
        availableItemTypes = Array(Set(items.map(\.type))).sorted { $0.rawValue < $1.rawValue }
    }

    func reset() {
        currentFilters = DownloadFilterCollection.default
    }
}

// MARK: - DownloadFilterCollection

/// Filter collection for downloaded content
struct DownloadFilterCollection: Hashable {

    var genres: [ItemGenre]
    var years: [ItemYear]
    var tags: [ItemTag]
    var itemTypes: [BaseItemKind]
    var sortBy: [ItemSortBy]
    var sortOrder: [ItemSortOrder]

    static var `default`: DownloadFilterCollection {
        DownloadFilterCollection(
            genres: [],
            years: [],
            tags: [],
            itemTypes: [],
            sortBy: [.dateLastContentAdded],
            sortOrder: [.descending]
        )
    }
}
