//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import JellyfinAPI
import SwiftUI

extension DownloadTaskView {

    struct ContentView: View {

        @Default(.accentColor)
        private var accentColor

        @ObservedObject
        private var downloadManager: DownloadManager

        @Router
        private var router

        let item: BaseItemDto

        @State
        private var isPresentingVideoPlayerTypeError: Bool = false

        private var downloadStatus: DownloadManager.DownloadItemStatus? {
            guard let itemID = item.id else { return nil }
            return downloadManager.status(for: itemID)
        }

        init(item: BaseItemDto) {
            self.item = item
            self.downloadManager = Container.shared.downloadManager()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {

                VStack(alignment: .center) {
                    ImageView(item.landscapeImageSources(maxWidth: 600))
                        .frame(maxHeight: 300)
                        .aspectRatio(1.77, contentMode: .fill)
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .posterShadow()

                    ShelfView(item: item)

                    if let status = downloadStatus {
                        switch status.state {
                        case .pending, .cancelled:
                            Button("Download") {
                                downloadManager.queueItem(item)
                            }
                            .frame(maxWidth: 300)
                            .frame(height: 50)
                        case .paused:
                            Button("Resume") {
                                downloadManager.resume(itemID: item.id ?? "")
                            }
                            .frame(maxWidth: 300)
                            .frame(height: 50)
                        case .downloading:
                            HStack {
                                Text("\(Int((status.progress ?? 0) * 100))%")
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button {
                                    downloadManager.pause(itemID: item.id ?? "")
                                } label: {
                                    Image(systemName: "stop.circle")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal)
                        case .error:
                            VStack {
                                Button(L10n.retry) {
                                    downloadManager.manualRetry(itemID: item.id ?? "")
                                }
                                .frame(maxWidth: 300)
                                .frame(height: 50)

                                if let error = status.error {
                                    Text("Error: \(error)")
                                        .padding(.horizontal)
                                }
                            }
                        case .complete:
                            Button(L10n.play) {
                                playDownloadedItem()
                            }
                            .frame(maxWidth: 300)
                            .frame(height: 50)
                        }
                    } else {
                        Button("Download") {
                            downloadManager.queueItem(item)
                        }
                        .frame(maxWidth: 300)
                        .frame(height: 50)
                    }
                }
            }
            .alert(
                L10n.error,
                isPresented: $isPresentingVideoPlayerTypeError
            ) {
                Button {
                    isPresentingVideoPlayerTypeError = false
                } label: {
                    Text(L10n.dismiss)
                }
            } message: {
                Text("Downloaded items are only playable through the Swiftfin video player.")
            }
        }

        private func playDownloadedItem() {
            Task { @MainActor in
                do {
                    // Try to load StoredDownloadItem from CoreStore
                    guard let userSession = Container.shared.currentUserSession(),
                          let itemID = item.id,
                          let storedItem: StoredDownloadItem = try? AnyStoredData.fetch(
                              itemID,
                              ownerID: userSession.user.id,
                              domain: "downloads"
                          )
                    else {
                        isPresentingVideoPlayerTypeError = true
                        return
                    }

                    let playbackItem = try MediaPlayerItem.buildOffline(for: storedItem)
                    let manager = MediaPlayerManager(playbackItem: playbackItem)
                    router.route(to: .videoPlayer(manager: manager))
                } catch {
                    isPresentingVideoPlayerTypeError = true
                }
            }
        }
    }
}

extension DownloadTaskView.ContentView {

    struct ShelfView: View {

        let item: BaseItemDto

        var body: some View {
            VStack(alignment: .center, spacing: 10) {

                if let seriesName = item.seriesName {
                    Text(seriesName)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal)
                        .foregroundColor(.secondary)
                }

                Text(item.displayTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal)

                DotHStack {
                    if item.type == .episode {
                        if let episodeLocation = item.episodeLocator {
                            Text(episodeLocation)
                        }
                    } else {
                        if let firstGenre = item.genres?.first {
                            Text(firstGenre)
                        }
                    }

                    if let productionYear = item.premiereDateYear {
                        Text(productionYear)
                    }

                    if let runtime = item.runTimeLabel {
                        Text(runtime)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            }
        }
    }
}
