//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Wrapper that stores the full BaseItemDto with download-specific metadata in CoreStore.
struct StoredDownloadItem: Codable, Hashable, Identifiable {

    let item: BaseItemDto
    let downloadedAt: Date
    let fileSize: Int64?
    let mediaPath: String?
    let primaryImagePath: String?
    let backdropImagePath: String?
    let logoImagePath: String?

    // MARK: - Identifiable

    var id: String {
        item.id ?? UUID().uuidString
    }

    // MARK: - Convenience Properties

    var type: BaseItemKind {
        item.type ?? .video
    }

    var seriesID: String? {
        item.seriesID
    }

    var seasonID: String? {
        item.seasonID
    }
}

/// Information needed to resume a paused download.
struct DownloadResumeInfo: Codable, Hashable {

    let itemID: String
    let downloadURL: URL
    let resumeData: Data
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let pausedAt: Date

    /// Progress as a percentage (0.0 to 1.0)
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}

/// Represents an item in the download queue.
struct DownloadQueueItem: Codable, Hashable, Identifiable {

    let id: String
    let type: BaseItemKind
    let name: String?
    let addedAt: Date
    let priority: Int // Lower = higher priority

    let seriesID: String?
    let seasonID: String?
    let groupId: String?
    let groupCount: Int?
    let size: Int64?
    let groupTotalSize: Int64?
    let isMetadataOnly: Bool

    // MARK: - Initializers

    init(
        id: String,
        type: BaseItemKind,
        name: String? = nil,
        addedAt: Date = Date(),
        priority: Int = 0,
        seriesID: String? = nil,
        seasonID: String? = nil,
        groupId: String? = nil,
        groupCount: Int? = nil,
        size: Int64? = nil,
        groupTotalSize: Int64? = nil,
        isMetadataOnly: Bool = false
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.addedAt = addedAt
        self.priority = priority
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.groupId = groupId
        self.groupCount = groupCount
        self.size = size
        self.groupTotalSize = groupTotalSize
        self.isMetadataOnly = isMetadataOnly
    }

    /// Creates a queue item from a BaseItemDto
    init(
        from item: BaseItemDto,
        priority: Int = 0,
        groupId: String? = nil,
        groupCount: Int? = nil,
        size: Int64? = nil,
        groupTotalSize: Int64? = nil,
        isMetadataOnly: Bool = false
    ) {
        self.id = item.id ?? UUID().uuidString
        self.type = item.type ?? .video
        self.name = item.name ?? item.displayTitle
        self.addedAt = Date()
        self.priority = priority
        self.seriesID = item.seriesID
        self.seasonID = item.seasonID
        self.groupId = groupId
        self.groupCount = groupCount
        self.size = size
        self.groupTotalSize = groupTotalSize
        self.isMetadataOnly = isMetadataOnly
    }
}

/// The state of a download item
enum DownloadItemState: String, Codable, Hashable, CaseIterable {
    case pending
    case downloading
    case paused
    case complete
    case error
    case cancelled
}

/// Errors that can occur during download.
enum DownloadError: LocalizedError, Hashable {

    case insufficientSpace(required: Int64, available: Int64)
    case networkError(String)
    case fileSystemError(String)
    case itemNotFound
    case missingParentInfo
    case cancelled
    case unknownContainer
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(required, available):
            let requiredFormatted = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availableFormatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Insufficient storage space. Required: \(requiredFormatted), Available: \(availableFormatted)"
        case let .networkError(message):
            return "Network error: \(message)"
        case let .fileSystemError(message):
            return "File system error: \(message)"
        case .itemNotFound:
            return "Item not found"
        case .missingParentInfo:
            return "Missing parent information for hierarchical item"
        case .cancelled:
            return "Download was cancelled"
        case .unknownContainer:
            return "Unknown file format"
        case let .unknown(message):
            return "Unknown error: \(message)"
        }
    }
}

/// The current stage of a download operation.
enum DownloadStage: Hashable {
    case preparing
    case downloadingMedia(progress: Double)
    case downloadingPrimaryImage
    case downloadingBackdropImage
    case downloadingLogoImage
    case savingMetadata
    case completed
}
