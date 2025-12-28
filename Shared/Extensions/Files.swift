//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import Logging

#if os(iOS)
extension FileManager {

    private static let logger = Logger.swiftfin()

    // MARK: - Space Checking

    /// Get the available storage space on the device
    /// - Returns: Available bytes, or nil if unable to determine
    var availableStorage: Int64? {
        let documentDirectory = URL.documents

        do {
            let values = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }

            // Fallback to regular available capacity
            let fallbackValues = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = fallbackValues.volumeAvailableCapacity {
                return Int64(capacity)
            }
        } catch {
            Self.logger.error("Failed to get available storage space: \(error.localizedDescription)")
        }

        return nil
    }

    /// Legacy property for backward compatibility (returns Int, -1 on error)
    var availableStorageLegacy: Int {
        guard let available = availableStorage else {
            return -1
        }
        return Int(available)
    }

    /// Get the total storage space on the device
    /// - Returns: Total bytes, or nil if unable to determine
    var totalStorage: Int64? {
        let documentDirectory = URL.documents

        do {
            let values = try documentDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey])
            if let capacity = values.volumeTotalCapacity {
                return Int64(capacity)
            }
        } catch {
            Self.logger.error("Failed to get total storage space: \(error.localizedDescription)")
        }

        return nil
    }

    /// Get the used storage space on the device
    /// - Returns: Used bytes, or nil if unable to determine
    var usedStorage: Int64? {
        guard let total = totalStorage, let available = availableStorage else {
            return nil
        }
        return total - available
    }

    /// Check if there's enough space for a download
    /// - Parameter requiredBytes: The number of bytes required
    /// - Throws: `DownloadError.insufficientSpace` if there's not enough space
    func checkSpace(requiredBytes: Int64) throws {
        guard let available = availableStorage else {
            Self.logger.warning("Unable to determine available storage space")
            return // Proceed with download if we can't check
        }

        // Add a 10% buffer for safety
        let requiredWithBuffer = Int64(Double(requiredBytes) * 1.1)

        if available < requiredWithBuffer {
            throw DownloadError.insufficientSpace(required: requiredBytes, available: available)
        }
    }

    // MARK: - Size Estimation

    /// Estimate the download size for an item based on its media sources
    /// - Parameter item: The item to estimate size for
    /// - Returns: Estimated size in bytes, or nil if unable to estimate
    func estimateDownloadSize(for item: BaseItemDto) -> Int64? {
        // Try to get size from media sources
        if let mediaSources = item.mediaSources {
            for source in mediaSources {
                if let size = source.size {
                    return Int64(size)
                }
            }
        }

        // Fallback: estimate based on runtime and typical bitrate
        // Average bitrate assumption: 5 Mbps for movies/episodes
        if let runTimeTicks = item.runTimeTicks {
            let seconds = Double(runTimeTicks) / 10_000_000
            let estimatedBitrate: Double = 5_000_000 // 5 Mbps
            let estimatedBytes = (seconds * estimatedBitrate) / 8
            return Int64(estimatedBytes)
        }

        return nil
    }

    // MARK: - Formatting

    /// Format bytes as a human-readable string
    /// - Parameter bytes: The number of bytes
    /// - Returns: Formatted string (e.g., "1.5 GB")
    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Get a summary of storage status
    /// - Returns: A formatted string describing storage status
    func storageSummary() -> String {
        var summary = ""

        if let available = availableStorage {
            summary += "Available: \(formatBytes(available))"
        }

        if let total = totalStorage {
            summary += " / Total: \(formatBytes(total))"
        }

        return summary.isEmpty ? "Unable to determine storage" : summary
    }

    // MARK: - Downloads Directory Size

    /// Get the total size of all downloaded content
    /// - Returns: Size in bytes, or nil if unable to determine
    func downloadsDirectorySize() -> Int64? {
        let downloadsURL = URL.downloads

        guard fileExists(atPath: downloadsURL.path) else {
            return 0
        }

        do {
            if let size = try downloadsURL.directoryTotalAllocatedSize(includingSubfolders: true) {
                return Int64(size)
            }
        } catch {
            Self.logger.error("Failed to calculate downloads directory size: \(error.localizedDescription)")
        }

        return nil
    }

    /// Get a formatted string of the downloads directory size
    /// - Returns: Formatted size string
    func formattedDownloadsSize() -> String {
        guard let size = downloadsDirectorySize() else {
            return "Unknown"
        }
        return formatBytes(size)
    }
}
#endif
