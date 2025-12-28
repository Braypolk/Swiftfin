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

/// ViewModel for browsing downloaded content with filtering and sorting support
@MainActor
@Stateful
final class DownloadPagingLibraryViewModel: ViewModel {

    @CasePathable
    enum Action {
        case refresh
        case filter
        case delete(String)

        var transition: Transition {
            switch self {
            case .refresh:
                .to(.content)
            case .filter:
                .none
            case .delete:
                .none
            }
        }
    }

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

    @Published
    var filterViewModel: DownloadFilterViewModel = DownloadFilterViewModel()

    @Published
    var currentDownload: DownloadTask?

    @Published
    var queue: [DownloadQueueItem] = []

    @Published
    var itemStates: [String: DownloadItemState] = [:]

    override nonisolated init() {
        super.init()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setupObservers()
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

    @Function(\Action.Cases.refresh)
    private func _refresh() {
        let items = downloadManager.completedItems
        filterViewModel.updateAvailableFilters(from: items)
        applyFiltersAndSort(to: items)
    }

    @Function(\Action.Cases.filter)
    private func _filter() {
        applyFiltersAndSort(to: downloadManager.completedItems)
    }

    @Function(\Action.Cases.delete)
    private func _delete(_ _itemID: String) {
        downloadManager.delete(itemID: _itemID)
    }

    // MARK: - Public Methods (for view access)

    // BRAY-TODO: is this needed?
    func performRefresh() {
        _refresh()
    }

    // MARK: - Filtering and Sorting

    private func applyFiltersAndSort(to items: [DownloadItemDto]) {
        var filteredItems = items
        let filters = filterViewModel.currentFilters

        if !filters.itemTypes.isEmpty {
            filteredItems = filteredItems.filter { filters.itemTypes.contains($0.type) }
        }

        if !filters.genres.isEmpty {
            let genreValues = Set(filters.genres.map(\.value))
            filteredItems = filteredItems.filter { item in
                guard let genres = item.genres else { return false }
                return !Set(genres).isDisjoint(with: genreValues)
            }
        }

        if !filters.years.isEmpty {
            let yearValues = Set(filters.years.compactMap { Int($0.value) })
            filteredItems = filteredItems.filter { item in
                guard let year = item.productionYear else { return false }
                return yearValues.contains(year)
            }
        }

        if !filters.tags.isEmpty {
            let tagValues = Set(filters.tags.map(\.value))
            filteredItems = filteredItems.filter { item in
                guard let tags = item.tags else { return false }
                return !Set(tags).isDisjoint(with: tagValues)
            }
        }

        filteredItems = applySorting(to: filteredItems, sortBy: filters.sortBy, sortOrder: filters.sortOrder)
        elements = IdentifiedArray(filteredItems, id: \.unwrappedIDHashOrZero, uniquingIDsWith: { x, _ in x })

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
        let isMainDownload: Bool
    }

    var groupedQueue: [DownloadQueueGroup] {
        var allItems: [DownloadQueueItem] = []

        let currentID = currentDownload?.id
        if let current = currentDownload {
            allItems.append(current.queueItem)
        }

        allItems.append(contentsOf: queue.filter { $0.id != currentID })

        let grouped = Dictionary(grouping: allItems) { $0.groupId ?? $0.id }

        return grouped.compactMap { groupId, items in
            let mainItem = items.first(where: { !$0.isMetadataOnly }) ?? items.first
            guard let mainItem = mainItem else { return nil }

            let currentItemsTotalSize = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let totalGroupSize = max(Int64(0), mainItem.groupTotalSize ?? currentItemsTotalSize)

            let completedSizeInBatch = max(Int64(0), totalGroupSize - currentItemsTotalSize)

            var totalBytesDownloaded: Int64 = completedSizeInBatch

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
            if g1.isMainDownload != g2.isMainDownload {
                return g1.isMainDownload
            }
            let d1 = g1.items.first?.addedAt ?? Date.distantPast
            let d2 = g2.items.first?.addedAt ?? Date.distantPast
            return d1 < d2
        }
    }
}

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
        var genreSet = Set<String>()
        for item in items {
            if let genres = item.genres {
                genreSet.formUnion(genres)
            }
        }
        availableGenres = genreSet.sorted().map { ItemGenre(stringLiteral: $0) }

        var yearSet = Set<Int>()
        for item in items {
            if let year = item.productionYear {
                yearSet.insert(year)
            }
        }
        availableYears = yearSet.sorted(by: >).map { ItemYear(integerLiteral: $0) }

        var tagSet = Set<String>()
        for item in items {
            if let tags = item.tags {
                tagSet.formUnion(tags)
            }
        }
        availableTags = tagSet.sorted().map { ItemTag(stringLiteral: $0) }

        availableItemTypes = Array(Set(items.map(\.type))).sorted { $0.rawValue < $1.rawValue }
    }

    func reset() {
        currentFilters = DownloadFilterCollection.default
    }
}

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
