//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import Foundation
import JellyfinAPI

/// SeasonItemViewModel for downloaded content that loads episodes from CoreStore.
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

        let seriesID = self.seriesID

        // CoreStore must be accessed from the main thread
        return await MainActor.run {
            guard let userSession = Container.shared.currentUserSession() else {
                return []
            }

            guard let clause = try? AnyStoredData.fetchClause(ownerID: userSession.user.id, domain: "downloads"),
                  let storedData = try? SwiftfinStore.dataStack.fetchAll(clause)
            else {
                return []
            }

            let episodes = storedData.compactMap { data -> BaseItemDto? in
                guard let itemData = data.data,
                      let storedItem = try? JSONDecoder().decode(StoredDownloadItem.self, from: itemData)
                else {
                    return nil
                }

                // Filter for episodes belonging to this season and series
                guard storedItem.type == .episode,
                      storedItem.seasonID == seasonID,
                      storedItem.seriesID == seriesID
                else {
                    return nil
                }

                return storedItem.item
            }

            // Sort by index number
            return episodes.sorted { ($0.indexNumber ?? -1) < ($1.indexNumber ?? -1) }
        }
    }
}
