//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// A display-oriented struct derived from StoredDownloadItem for UI purposes.
struct DownloadItemDto: Codable, Hashable, Identifiable {

    // MARK: - Identity

    let id: String
    let type: BaseItemKind

    // MARK: - Display

    let name: String
    let sortName: String?
    let overview: String?
    let taglines: [String]?

    // MARK: - Hierarchy

    let seriesID: String?
    let seriesName: String?
    let seasonID: String?
    let seasonName: String?
    let parentIndexNumber: Int? // Season number
    let indexNumber: Int? // Episode number

    // MARK: - Metadata for filtering

    let genres: [String]?
    let tags: [String]?
    let productionYear: Int?
    let premiereDate: Date?
    let officialRating: String?
    let communityRating: Double?
    let criticRating: Double?

    // MARK: - Runtime

    let runTimeTicks: Int64?

    // MARK: - User data

    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool
    let played: Bool

    let people: [DownloadPersonDto]?

    let studios: [DownloadStudioDto]?

    // MARK: - Local file paths (relative to download root)

    // Note: Use DownloadItemDto+Images extension methods (imageURL, imageSource) to work with these paths

    let mediaPath: String?
    let primaryImagePath: String?
    let backdropImagePath: String?
    let logoImagePath: String?

    // MARK: - Download metadata

    let downloadedAt: Date
    let fileSize: Int64?

    // MARK: - Computed Properties

    /// Episode locator string (e.g., "S1:E5")
    var episodeLocator: String? {
        guard let episodeNo = indexNumber else { return nil }
        return L10n.episodeNumber(episodeNo)
    }

    /// Season and episode label (e.g., "S1:E5")
    var seasonEpisodeLabel: String? {
        guard let seasonNo = parentIndexNumber, let episodeNo = indexNumber else { return nil }
        return L10n.seasonAndEpisode(String(seasonNo), String(episodeNo))
    }

    /// Parent title (series name for episodes, album for audio)
    var parentTitle: String? {
        switch type {
        case .episode:
            return seriesName
        default:
            return nil
        }
    }

    /// Premiere date year as string
    var premiereDateYear: String? {
        guard let premiereDate = premiereDate else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "YYYY"
        return dateFormatter.string(from: premiereDate)
    }

    /// Runtime as Duration
    var runtime: Duration? {
        guard let ticks = runTimeTicks else { return nil }
        return Duration.ticks(Int(ticks))
    }

    /// Human-readable runtime label
    var runTimeLabel: String? {
        let timeHMSFormatter: DateComponentsFormatter = {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.hour, .minute]
            return formatter
        }()

        guard let runTimeTicks = runTimeTicks,
              let text = timeHMSFormatter.string(from: Double(runTimeTicks / 10_000_000)) else { return nil }

        return text
    }

    /// Play remaining time label (e.g., "45 min remaining")
    var progressLabel: String? {
        guard let playbackPositionTicks = playbackPositionTicks,
              let totalTicks = runTimeTicks,
              playbackPositionTicks != 0,
              totalTicks != 0 else { return nil }

        let remainingSeconds = (totalTicks - playbackPositionTicks) / 10_000_000

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated

        return formatter.string(from: .init(remainingSeconds))
    }
}

/// Simplified person DTO for offline storage.
struct DownloadPersonDto: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let role: String?
    let type: String?
    let primaryImagePath: String?
}

/// Simplified studio DTO for offline storage.
struct DownloadStudioDto: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

// MARK: - DownloadItemDto + Initialization

extension DownloadItemDto {

    /// Creates a DownloadItemDto from a StoredDownloadItem.
    init(from stored: StoredDownloadItem) {
        let item = stored.item

        self.id = item.id ?? UUID().uuidString
        self.type = item.type ?? .video
        self.name = item.name ?? L10n.unknown
        self.sortName = item.sortName
        self.overview = item.overview
        self.taglines = item.taglines

        self.seriesID = item.seriesID
        self.seriesName = item.seriesName
        self.seasonID = item.seasonID
        self.seasonName = item.seasonName
        self.parentIndexNumber = item.parentIndexNumber
        self.indexNumber = item.indexNumber

        self.genres = item.genres
        self.tags = item.tags
        self.productionYear = item.productionYear
        self.premiereDate = item.premiereDate
        self.officialRating = item.officialRating
        self.communityRating = item.communityRating.map { Double($0) }
        self.criticRating = item.criticRating.map { Double($0) }

        self.runTimeTicks = item.runTimeTicks.map { Int64($0) }

        self.playbackPositionTicks = item.userData?.playbackPositionTicks.map { Int64($0) }
        self.playCount = item.userData?.playCount
        self.isFavorite = item.userData?.isFavorite ?? false
        self.played = item.userData?.isPlayed ?? false

        self.people = item.people?.map { DownloadPersonDto(from: $0) }
        self.studios = item.studios?.map { DownloadStudioDto(from: $0) }

        self.mediaPath = stored.mediaPath
        self.primaryImagePath = stored.primaryImagePath
        self.backdropImagePath = stored.backdropImagePath
        self.logoImagePath = stored.logoImagePath

        self.downloadedAt = stored.downloadedAt
        self.fileSize = stored.fileSize
    }
}

// MARK: - DownloadPersonDto + Initialization

extension DownloadPersonDto {

    init(from person: BaseItemPerson) {
        self.id = person.id ?? UUID().uuidString
        self.name = person.name ?? L10n.unknown
        self.role = person.role
        self.type = person.type?.rawValue
        self.primaryImagePath = nil // Will be set when downloading person images
    }
}

extension DownloadStudioDto {
    init(from studio: NameGuidPair) {
        self.id = studio.id ?? UUID().uuidString
        self.name = studio.name ?? L10n.unknown
    }
}

extension DownloadItemDto {

    /// Converts DownloadPersonDto array to BaseItemPerson array for display components
    var baseItemPeople: [BaseItemPerson] {
        people?.compactMap { person in
            var basePerson = BaseItemPerson()
            basePerson.id = person.id
            basePerson.name = person.name
            basePerson.role = person.role
            if let typeString = person.type {
                basePerson.type = PersonKind(rawValue: typeString)
            }
            return basePerson
        } ?? []
    }

    /// Converts DownloadStudioDto array to NameGuidPair array for display components
    var nameGuidPairStudios: [NameGuidPair] {
        studios?.compactMap { studio in
            var pair = NameGuidPair()
            pair.id = studio.id
            pair.name = studio.name
            return pair
        } ?? []
    }

    /// Converts genres array to ItemGenre array for display components
    var itemGenres: [ItemGenre] {
        genres?.map { ItemGenre(stringLiteral: $0) } ?? []
    }
}
