//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
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
}
#endif
