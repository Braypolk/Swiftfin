//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

// BRAY-TODO: Understand why this file is needed vs just using baseitemdto+poster

import Defaults
import Foundation
import JellyfinAPI
import SwiftUI

// MARK: - Displayable

extension DownloadItemDto: Displayable {

    var displayTitle: String {
        name
    }
}

// MARK: - LibraryIdentifiable

extension DownloadItemDto: LibraryIdentifiable {

    var unwrappedIDHashOrZero: Int {
        id.hashValue
    }
}

// MARK: - SystemImageable

extension DownloadItemDto: SystemImageable {

    var systemImage: String {
        switch type {
        case .movie:
            "film"
        case .series:
            "tv"
        case .season:
            "tv"
        case .episode:
            "play.rectangle"
        case .audio, .musicAlbum:
            "music.note"
        case .boxSet:
            "film.stack"
        default:
            "circle"
        }
    }

    var secondarySystemImage: String {
        systemImage
    }
}

// MARK: - Poster

extension DownloadItemDto: Poster {

    var preferredPosterDisplayType: PosterDisplayType {
        switch type {
        case .episode:
            .landscape
        case .movie, .series, .season:
            .portrait
        default:
            .portrait
        }
    }

    var subtitle: String? {
        switch type {
        case .episode:
            seasonEpisodeLabel
        default:
            nil
        }
    }

    var showTitle: Bool {
        switch type {
        case .episode, .series, .movie, .boxSet:
            Defaults[.Customization.showPosterLabels]
        default:
            true
        }
    }

    func portraitImageSources(maxWidth: CGFloat? = nil, quality: Int? = nil) -> [ImageSource] {
        switch type {
        case .episode:
            [seriesImageSource(.primary, maxWidth: maxWidth, quality: quality)]
        default:
            [imageSource(.primary, maxWidth: maxWidth, quality: quality)]
        }
    }

    func landscapeImageSources(maxWidth: CGFloat? = nil, quality: Int? = nil) -> [ImageSource] {
        switch type {
        case .episode:
            // For episodes, try backdrop first, then fallback to primary
            let backdropSource = imageSource(.backdrop, maxWidth: maxWidth, quality: quality)
            if backdropSource.url != nil {
                return [backdropSource]
            }
            return [imageSource(.primary, maxWidth: maxWidth, quality: quality)]
        default:
            // For others, try backdrop
            return [imageSource(.backdrop, maxWidth: maxWidth, quality: quality)]
        }
    }

    func cinematicImageSources(maxWidth: CGFloat? = nil, quality: Int? = nil) -> [ImageSource] {
        switch type {
        case .episode:
            [seriesImageSource(.backdrop, maxWidth: maxWidth, quality: quality)]
        default:
            [imageSource(.backdrop, maxWidth: maxWidth, quality: quality)]
        }
    }

    func squareImageSources(maxWidth: CGFloat? = nil, quality: Int? = nil) -> [ImageSource] {
        switch type {
        case .audio, .musicAlbum:
            [imageSource(.primary, maxWidth: maxWidth, quality: quality)]
        default:
            []
        }
    }

    func thumbImageSources() -> [ImageSource] {
        switch preferredPosterDisplayType {
        case .portrait:
            portraitImageSources()
        case .landscape:
            landscapeImageSources()
        case .square:
            squareImageSources()
        }
    }

    @MainActor
    @ViewBuilder
    func transform(image: Image) -> some View {
        image
            .aspectRatio(contentMode: .fill)
    }
}

// MARK: - Convenience Image URL Properties

extension DownloadItemDto {

    /// Returns the local URL for the logo image if available
    var logoImageURL: URL? {
        imageURL(.logo)
    }

    /// Returns the local URL for the primary image if available
    var primaryImageURL: URL? {
        imageURL(.primary)
    }

    /// Returns the local URL for the backdrop image if available
    var backdropImageURL: URL? {
        imageURL(.backdrop)
    }

    /// Returns the local URL for the media file if available
    var mediaURL: URL? {
        guard let mediaPath = mediaPath else { return nil }
        return URL.downloads.appendingPathComponent(mediaPath)
    }
}
