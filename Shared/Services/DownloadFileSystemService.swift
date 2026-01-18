//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Files
import Foundation
import JellyfinAPI
import Logging

/// Service responsible for all file system operations related to downloads.
class DownloadFileSystemService {

    private let logger = Logger.swiftfin()

    // MARK: - Directory Management

    /// Creates the required download directory structure.
    func createDownloadDirectories() {
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

    /// Clears the temporary download directory.
    func clearTmp() {
        do {
            try Folder(path: URL.tmp.path).files.delete()
            logger.trace("Cleared tmp directory")
        } catch {
            logger.error("Unable to clear tmp directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Path Resolution

    /// Determines the folder path for an item.
    func folderPath(for item: BaseItemDto) -> URL? {
        item.downloadFolder
    }

    /// Determines the folder path for an item based on its type and hierarchy (Legacy/Fallback).
    func folderPath(
        for id: String,
        type: BaseItemKind,
        seriesID: String?,
        seasonID: String?
    ) -> URL? {
        switch type {
        case .movie:
            return URL.movieDownloadFolder(itemID: id)
        case .series:
            return URL.seriesDownloadFolder(seriesID: id)
        case .season:
            guard let seriesID = seriesID else { return nil }
            return URL.seasonDownloadFolder(seriesID: seriesID, seasonID: id)
        case .episode:
            guard let seriesID = seriesID, let seasonID = seasonID else { return nil }
            return URL.episodeDownloadFolder(seriesID: seriesID, seasonID: seasonID, episodeID: id)
        default:
            return URL.movieDownloadFolder(itemID: id)
        }
    }

    // MARK: - File Deletion

    /// Deletes the folder for a given item.
    /// - Parameter path: The URL of the folder to delete.
    /// - Returns: True if deletion was successful or folder didn't exist.
    @discardableResult
    func deleteFolder(at path: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
                logger.info("Successfully deleted download folder: \(path.path)")
            }
            return true
        } catch {
            logger.error("Failed to delete download folder \(path.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes an item's files based on stored or queue information.
    func deleteItemFiles(
        itemID: String,
        type: BaseItemKind,
        seriesID: String?,
        seasonID: String?
    ) {
        // Try to construct path using IDs (legacy)
        // Note: For new items using metadata names, we can't reconstruct the path from just IDs
        // However, deletions usually happen via DownloadManager which loads the StoredDownloadItem first
        // If this is called properly, we should rely on the item's stored path or the caller passing the item

        // Use legacy path construction as best effort fallback
        if let path = folderPath(for: itemID, type: type, seriesID: seriesID, seasonID: seasonID) {
            deleteFolder(at: path)
        }
    }

    /// Deletes files for a specific item
    func deleteItemFiles(for item: BaseItemDto) {
        if let path = item.downloadFolder {
            deleteFolder(at: path)
        }
    }
}

// MARK: - Factory Registration

extension Container {
    var downloadFileSystemService: Factory<DownloadFileSystemService> {
        self { DownloadFileSystemService() }.shared
    }
}
