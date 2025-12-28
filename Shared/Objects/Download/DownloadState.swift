//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

// MARK: - StoredDownloadItem

/// Wrapper that stores the full BaseItemDto with download-specific metadata in CoreStore.
/// This is the single source of truth for downloaded content.
struct StoredDownloadItem: Codable, Hashable, Identifiable {

    /// The full item metadata from the server
    let item: BaseItemDto

    /// When the item was downloaded
    let downloadedAt: Date

    /// Size of the downloaded media file in bytes
    let fileSize: Int64?

    /// Relative path to the media file from the downloads root
    let mediaPath: String?

    /// Relative path to the primary image
    let primaryImagePath: String?

    /// Relative path to the backdrop image
    let backdropImagePath: String?

    /// Relative path to the logo image
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

// MARK: - DownloadResumeInfo

/// Information needed to resume a paused download
struct DownloadResumeInfo: Codable, Hashable {

    /// The item ID being downloaded
    let itemID: String

    /// The original download URL
    let downloadURL: URL

    /// Resume data from URLSession
    let resumeData: Data

    /// Bytes already downloaded
    let bytesDownloaded: Int64

    /// Total expected bytes
    let totalBytes: Int64

    /// When the download was paused
    let pausedAt: Date

    /// Progress as a percentage (0.0 to 1.0)
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}

// MARK: - DownloadQueueItem

/// Represents an item in the download queue
struct DownloadQueueItem: Codable, Hashable, Identifiable {

    /// The item ID
    let id: String

    /// The type of item
    let type: BaseItemKind

    /// Display name for the item (optional, for UI display)
    let name: String?

    /// When the item was added to the queue
    let addedAt: Date

    /// Priority in the queue (lower = higher priority)
    let priority: Int

    /// For hierarchical items - the series ID
    let seriesID: String?

    /// For hierarchical items - the season ID
    let seasonID: String?

    /// ID of the group this item belongs to (usually the playable item ID)
    let groupId: String?

    /// Total number of items in the group
    let groupCount: Int?

    /// Size of this specific item in bytes
    let size: Int64?

    /// Combined size of all items in the group in bytes
    let groupTotalSize: Int64?

    /// Whether this is a metadata-only download (no media file)
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

// MARK: - DownloadItemState

/// The state of a download item
enum DownloadItemState: String, Codable, Hashable, CaseIterable {

    /// Download is pending in the queue
    case pending

    /// Download is currently in progress
    case downloading

    /// Download is paused
    case paused

    /// Download completed successfully
    case complete

    /// Download failed with an error
    case error

    /// Download was cancelled
    case cancelled
}

// MARK: - DownloadError

/// Errors that can occur during download
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

// MARK: - DownloadStage

/// The current stage of a download operation
enum DownloadStage: Hashable {

    /// Preparing to download
    case preparing

    /// Downloading media file
    case downloadingMedia(progress: Double)

    /// Downloading primary image
    case downloadingPrimaryImage

    /// Downloading backdrop image
    case downloadingBackdropImage

    /// Downloading logo image
    case downloadingLogoImage

    /// Saving metadata
    case savingMetadata

    /// Completed
    case completed
}
