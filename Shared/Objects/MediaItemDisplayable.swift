//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// A protocol for media items that share common display properties
protocol MediaItemDisplayable {

    // MARK: - Required Properties

    /// Item type
    var mediaType: BaseItemKind? { get }

    /// Season number (for episodes)
    var parentIndexNumber: Int? { get }

    /// Episode number (for episodes)
    var indexNumber: Int? { get }

    /// Series name (for episodes)
    var seriesName: String? { get }

    /// Runtime in ticks
    var protocolRunTimeTicks: Int64? { get }

    /// Playback position in ticks
    var protocolPlaybackPositionTicks: Int64? { get }

    /// Premiere date
    var premiereDate: Date? { get }
}

// MARK: - Default Implementations

extension MediaItemDisplayable {

    /// Episode locator string (e.g., "E5")
    var episodeLocator: String? {
        guard let episodeNo = indexNumber else { return nil }
        return L10n.episodeNumber(episodeNo)
    }

    /// Season and episode label (e.g., "S1:E5")
    var seasonEpisodeLabel: String? {
        guard let seasonNo = parentIndexNumber, let episodeNo = indexNumber else { return nil }
        return L10n.seasonAndEpisode(String(seasonNo), String(episodeNo))
    }

    /// Human-readable runtime label
    var runTimeLabel: String? {
        let timeHMSFormatter: DateComponentsFormatter = {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.hour, .minute]
            return formatter
        }()

        guard let runTimeTicks = protocolRunTimeTicks,
              let text = timeHMSFormatter.string(from: Double(runTimeTicks / 10_000_000)) else { return nil }

        return text
    }

    /// Play remaining time label (e.g., "45 min remaining")
    var progressLabel: String? {
        guard let playbackPositionTicks = protocolPlaybackPositionTicks,
              let totalTicks = protocolRunTimeTicks,
              playbackPositionTicks != 0,
              totalTicks != 0 else { return nil }

        let remainingSeconds = (totalTicks - playbackPositionTicks) / 10_000_000

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated

        return formatter.string(from: .init(remainingSeconds))
    }

    /// Premiere date year as string
    var premiereDateYear: String? {
        guard let premiereDate = premiereDate else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "YYYY"
        return dateFormatter.string(from: premiereDate)
    }

    /// Parent title (series name for episodes, album for audio)
    var parentTitle: String? {
        switch mediaType {
        case .episode:
            return seriesName
        default:
            return nil
        }
    }
}
