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
import Logging

// TODO: build report of determined values for playback information
//       - transcode, video stream, path

extension MediaPlayerItem {

    /// Builds a `MediaPlayerItem` for offline/downloaded content from StoredDownloadItem.
    static func buildOffline(for storedItem: StoredDownloadItem) throws -> MediaPlayerItem {
        guard let mediaPath = storedItem.mediaPath else {
            throw ErrorMessage("No media file available for offline playback")
        }

        let mediaURL = URL.downloads.appendingPathComponent(mediaPath)

        // Use the full BaseItemDto from StoredDownloadItem
        let baseItem = storedItem.item
        let mediaSource: MediaSourceInfo

        if let savedMediaSource = baseItem.mediaSources?.first {
            // Use the saved MediaSourceInfo with audio streams
            mediaSource = savedMediaSource
        } else {
            // Fallback: Create a minimal MediaSourceInfo for offline playback
            mediaSource = MediaSourceInfo(
                id: storedItem.id,
                isRemote: false,
                name: baseItem.name,
                path: mediaURL.absoluteString,
                runTimeTicks: baseItem.runTimeTicks
            )
        }

        return MediaPlayerItem(
            baseItem: baseItem,
            mediaSource: mediaSource,
            playSessionID: "offline-\(storedItem.id)",
            url: mediaURL
        )
    }

    /// Builds a `MediaPlayerItem` for offline/downloaded content from DownloadItemDto.
    /// This loads the StoredDownloadItem from CoreStore.
    static func buildOffline(for downloadedItem: DownloadItemDto) throws -> MediaPlayerItem {
        // Try to load the StoredDownloadItem from CoreStore
        guard let userSession = Container.shared.currentUserSession(),
              let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                  downloadedItem.id,
                  ownerID: userSession.user.id,
                  domain: "downloads"
              )
        else {
            throw ErrorMessage("Unable to load downloaded item from storage")
        }

        return try buildOffline(for: storedItem)
    }

    /// The main `MediaPlayerItem` builder for normal online usage.
    static func build(
        for initialItem: BaseItemDto,
        mediaSource _initialMediaSource: MediaSourceInfo? = nil,
        videoPlayerType: VideoPlayerType = Defaults[.VideoPlayer.videoPlayerType],
        requestedBitrate: PlaybackBitrate = Defaults[.VideoPlayer.Playback.appMaximumBitrate],
        compatibilityMode: PlaybackCompatibility = Defaults[.VideoPlayer.Playback.compatibilityMode],
        modifyItem: ((inout BaseItemDto) -> Void)? = nil
    ) async throws -> MediaPlayerItem {

        let logger = Logger.swiftfin()

        guard let itemID = initialItem.id else {
            logger.critical("No item ID!")
            throw ErrorMessage(L10n.unknownError)
        }

        guard let userSession = Container.shared.currentUserSession() else {
            logger.critical("No user session!")
            throw ErrorMessage(L10n.unknownError)
        }

        var item = try await initialItem.getFullItem(userSession: userSession)

        if let modifyItem {
            modifyItem(&item)
        }

        guard let initialMediaSource = {
            if let _initialMediaSource {
                return _initialMediaSource
            }

            if let first = item.mediaSources?.first {
                logger.trace("Using first media source for item \(itemID)")
                return first
            }

            return nil
        }() else {
            logger.error("No media sources for item \(itemID)!")
            throw ErrorMessage(L10n.unknownError)
        }

        let maxBitrate = try await requestedBitrate.getMaxBitrate()

        let deviceProfile = DeviceProfile.build(
            for: videoPlayerType,
            compatibilityMode: compatibilityMode,
            maxBitrate: maxBitrate
        )

        var playbackInfo = PlaybackInfoDto()
        playbackInfo.isAutoOpenLiveStream = true
        playbackInfo.deviceProfile = deviceProfile
        playbackInfo.liveStreamID = initialMediaSource.liveStreamID
        playbackInfo.maxStreamingBitrate = maxBitrate
        playbackInfo.userID = userSession.user.id

        if !item.isLiveStream {
            playbackInfo.mediaSourceID = initialMediaSource.id
        }

        let request = Paths.getPostedPlaybackInfo(
            itemID: itemID,
            playbackInfo
        )

        let response = try await userSession.client.send(request)

        let mediaSource: MediaSourceInfo? = {

            guard let mediaSources = response.value.mediaSources else { return nil }

            if let matchingTag = mediaSources.first(where: { $0.eTag == initialMediaSource.eTag }) {
                return matchingTag
            }

            for source in mediaSources {
                if let openToken = source.openToken,
                   let id = source.id,
                   openToken.contains(id)
                {
                    return source
                }
            }

            logger.warning("Unable to find matching media source, defaulting to first media source")

            return mediaSources.first
        }()

        guard let mediaSource else {
            throw ErrorMessage("Unable to find media source for item")
        }

        guard let playSessionID = response.value.playSessionID else {
            throw ErrorMessage("No associated play session ID")
        }

        let playbackURL = try Self.streamURL(
            item: item,
            mediaSource: mediaSource,
            playSessionID: playSessionID,
            userSession: userSession,
            logger: logger
        )

        let previewImageProvider: (any PreviewImageProvider)? = {
            let previewImageScrubbingSetting = StoredValues[.User.previewImageScrubbing]
            lazy var chapterPreviewImageProvider: ChapterPreviewImageProvider? = {
                if let chapters = item.fullChapterInfo, chapters.isNotEmpty {
                    return ChapterPreviewImageProvider(chapters: chapters)
                }
                return nil
            }()

            if case let PreviewImageScrubbingOption.trickplay(fallbackToChapters: fallbackToChapters) = previewImageScrubbingSetting {
                if let mediaSourceID = mediaSource.id,
                   let trickplayInfo = item.trickplay?[mediaSourceID]?.first
                {
                    return TrickplayPreviewImageProvider(
                        info: trickplayInfo.value,
                        itemID: itemID,
                        mediaSourceID: mediaSourceID,
                        runtime: item.runtime ?? .zero
                    )
                }

                if fallbackToChapters {
                    return chapterPreviewImageProvider
                }
            } else if previewImageScrubbingSetting == .chapters {
                return chapterPreviewImageProvider
            }

            return nil
        }()

        return .init(
            baseItem: item,
            mediaSource: mediaSource,
            playSessionID: playSessionID,
            url: playbackURL,
            requestedBitrate: requestedBitrate,
            previewImageProvider: previewImageProvider,
            thumbnailProvider: item.getNowPlayingImage
        )
    }

    // TODO: audio type stream
    // TODO: build live tv stream from Paths.getLiveHlsStream?
    private static func streamURL(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        playSessionID: String,
        userSession: UserSession,
        logger: Logger
    ) throws -> URL {

        guard let itemID = item.id else {
            throw ErrorMessage("No item ID while building online media player item!")
        }

        if let transcodingURL = mediaSource.transcodingURL {
            logger.trace("Using transcoding URL for item \(itemID)")

            guard let fullTranscodeURL = userSession.client.fullURL(with: transcodingURL)
            else { throw ErrorMessage("Unable to make transcode URL") }
            return fullTranscodeURL
        }

        if item.mediaType == .video, !item.isLiveStream {

            logger.trace("Making video stream URL for item \(itemID)")

            let videoStreamParameters = Paths.GetVideoStreamParameters(
                isStatic: true,
                tag: item.etag,
                playSessionID: playSessionID,
                mediaSourceID: itemID
            )

            let videoStreamRequest = Paths.getVideoStream(
                itemID: itemID,
                parameters: videoStreamParameters
            )

            guard let videoStreamURL = userSession.client.fullURL(with: videoStreamRequest)
            else { throw ErrorMessage("Unable to make video stream URL") }

            return videoStreamURL
        }

        logger.trace("Using media source path for item \(itemID)")

        guard let path = mediaSource.path, let streamURL = URL(
            string: path
        ) else { throw ErrorMessage("Unable to make stream URL") }

        return streamURL
    }
}
