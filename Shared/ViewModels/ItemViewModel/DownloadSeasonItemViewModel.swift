//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import JellyfinAPI

/// SeasonItemViewModel for downloaded content that loads episodes from local files.
final class DownloadSeasonItemViewModel: PagingLibraryViewModel<BaseItemDto>, Identifiable {

    let season: BaseItemDto

    var id: String? {
        season.id
    }

    private let seriesID: String

    init(season: BaseItemDto, seriesID: String) {
        self.season = season
        self.seriesID = seriesID
        super.init(parent: season)
    }

    override func get(page: Int) async throws -> [BaseItemDto] {
        guard let seasonID = season.id else {
            return []
        }

        let seasonPath = URL.seasonDownloadFolder(seriesID: seriesID, seasonID: seasonID)
        let episodesPath = seasonPath.appendingPathComponent("episodes")

        guard let episodeContents = try? FileManager.default.contentsOfDirectory(atPath: episodesPath.path) else {
            return []
        }

        var episodes: [BaseItemDto] = []

        for episodeID in episodeContents {
            let episodePath = URL.episodeDownloadFolder(
                seriesID: seriesID,
                seasonID: seasonID,
                episodeID: episodeID
            )
            let metadataPath = episodePath.appendingPathComponent("Metadata").appendingPathComponent("Item.json")

            guard let data = FileManager.default.contents(atPath: metadataPath.path),
                  let episode = try? JSONDecoder().decode(BaseItemDto.self, from: data)
            else {
                continue
            }

            episodes.append(episode)
        }

        // Sort by index number
        return episodes.sorted { ($0.indexNumber ?? -1) < ($1.indexNumber ?? -1) }
    }
}
