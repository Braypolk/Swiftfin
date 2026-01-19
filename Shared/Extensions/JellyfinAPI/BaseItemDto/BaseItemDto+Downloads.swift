//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension BaseItemDto {

    /// Estimate the download size for an item based on its media sources
    /// - Returns: Estimated size in bytes, or nil if unable to estimate
    var estimatedDownloadSize: Int64? {
        // Try to get size from media sources
        if let mediaSources = mediaSources {
            for source in mediaSources {
                if let size = source.size {
                    return Int64(size)
                }
            }
        }

        // Fallback: estimate based on runtime and typical bitrate
        // Average bitrate assumption: 5 Mbps for movies/episodes
        if let runTimeTicks = runTimeTicks {
            let seconds = Double(runTimeTicks) / 10_000_000
            let estimatedBitrate: Double = 5_000_000 // 5 Mbps
            let estimatedBytes = (seconds * estimatedBitrate) / 8
            return Int64(estimatedBytes)
        }

        return nil
    }
}
