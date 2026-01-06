//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import IdentifiedCollections
import JellyfinAPI

/// Protocol for use with components like AttributesHStack.
protocol ItemViewModelProtocol: ObservableObject {
    var item: BaseItemDto { get }
    var selectedMediaSource: MediaSourceInfo? { get }

    // MARK: - Optional Content

    // These defaults allow conforming types to opt-in or return empty by default.
    var similarItems: [BaseItemDto] { get }
    var specialFeatures: [BaseItemDto] { get }
    var additionalParts: [BaseItemDto] { get }

    var seriesItem: BaseItemDto? { get }
}

extension ItemViewModelProtocol {
    var similarItems: [BaseItemDto] { [] }
    var specialFeatures: [BaseItemDto] { [] }
    var additionalParts: [BaseItemDto] { [] }
    var seriesItem: BaseItemDto? { nil }
}

/// Protocol for view models that support series with seasons.
protocol SeriesViewModelProtocol: ItemViewModelProtocol {
    var seasons: IdentifiedArrayOf<SeasonItemViewModel> { get }
    var playButtonItem: BaseItemDto? { get }
}
