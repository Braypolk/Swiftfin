//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension DownloadItemDto {

    /// Returns the local file URL for the specified image type.
    func imageURL(
        _ type: ImageType,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> URL? {
        _imageURL(type)
    }

    /// Returns an ImageSource for the specified image type.
    func imageSource(
        _ type: ImageType,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> ImageSource {
        let url = _imageURL(type)
        return ImageSource(url: url)
    }

    /// Returns the local file URL for the series image of the specified type.
    func seriesImageURL(
        _ type: ImageType,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> URL? {
        guard let seriesID = seriesID else { return nil }
        return _seriesImageURL(type, seriesID: seriesID)
    }

    /// Returns an ImageSource for the series image of the specified type.
    func seriesImageSource(
        _ type: ImageType,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> ImageSource {
        let url = seriesImageURL(type, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality)
        return ImageSource(url: url)
    }

    private func _imageURL(_ type: ImageType) -> URL? {
        let relativePath: String?

        switch type {
        case .primary:
            relativePath = primaryImagePath
        case .backdrop:
            relativePath = backdropImagePath
        case .logo:
            relativePath = logoImagePath
        default:
            // For other types, fallback to primary image
            relativePath = primaryImagePath
        }

        guard let relativePath = relativePath else { return nil }
        return URL.downloads.appendingPathComponent(relativePath)
    }

    private func _seriesImageURL(_ type: ImageType, seriesID: String) -> URL? {
        let seriesFolder = URL.seriesDownloadFolder(seriesID: seriesID)
        let imagesFolder = seriesFolder.appendingPathComponent("Images")

        // Try to find the image file based on type
        let imageFileName: String
        switch type {
        case .primary:
            imageFileName = "Primary"
        case .backdrop:
            imageFileName = "Backdrop"
        case .logo:
            imageFileName = "Logo"
        case .thumb:
            imageFileName = "Thumb"
        default:
            imageFileName = "Primary"
        }

        // Check if the images folder exists and find matching file
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path) else {
            return nil
        }

        if let imageFile = contents.first(where: { $0.hasPrefix(imageFileName) }) {
            return imagesFolder.appendingPathComponent(imageFile)
        }

        return nil
    }
}
