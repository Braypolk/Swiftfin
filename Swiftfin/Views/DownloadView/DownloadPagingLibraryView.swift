//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import JellyfinAPI
import SwiftUI

// MARK: - DownloadPagingLibraryView

struct DownloadPagingLibraryView: View {

    @Default(.Customization.Library.displayType)
    private var libraryDisplayType

    @Default(.Customization.Library.posterType)
    private var libraryPosterType

    @Default(.offlineMode)
    private var offlineMode

    @Default(.Experimental.downloads)
    private var experimentalDownloads

    @Router
    private var router

    #if os(iOS)
    @EnvironmentObject
    private var rootCoordinator: RootCoordinator
    #endif

    @StateObject
    var viewModel: DownloadPagingLibraryViewModel

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    @State
    private var showingQueueSheet = false

    init(viewModel: DownloadPagingLibraryViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? DownloadPagingLibraryViewModel())
    }

    var body: some View {
        contentView
            .navigationTitle(L10n.downloads)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Show offline mode toggle if experimental downloads is enabled
                    if experimentalDownloads {
                        Button {
                            let wasOffline = offlineMode
                            offlineMode.toggle()
                            // When offline mode is disabled, navigate to server check
                            if wasOffline && !offlineMode {
                                rootCoordinator.root(.serverCheck)
                            }
                        } label: {
                            Image(systemName: offlineMode ? "wifi.slash" : "wifi")
                        }
                    }

                    if !viewModel.queue.isEmpty || viewModel.currentDownload != nil {
                        Button {
                            showingQueueSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingQueueSheet) {
                NavigationView {
                    DownloadQueueView(viewModel: viewModel)
                }
            }
            .onFirstAppear {
                viewModel.performRefresh()
            }
            .refreshable {
                await MainActor.run {
                    viewModel.performRefresh()
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .initial:
            ProgressView()
        case .empty:
            emptyView
        case .content:
            libraryContentView
        case .error:
            ErrorView(error: ErrorMessage("An error occurred"))
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Downloads")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Download movies and shows to watch offline")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private var libraryContentView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Storage info header
                storageInfoHeader

                // Grid of downloaded items
                switch libraryDisplayType {
                case .grid:
                    gridContent
                case .list:
                    listContent
                }
            }
        }
    }

    @ViewBuilder
    private var storageInfoHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(viewModel.elements.count) \(viewModel.elements.count == 1 ? "item" : "items")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Using \(viewModel.formattedTotalSize)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(viewModel.formattedAvailableStorage) available")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var gridContent: some View {
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(viewModel.elements) { item in
                Button {
                    router.route(to: .downloadItem(item: item))
                } label: {
                    DownloadItemPosterView(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        downloadManager.delete(itemID: item.id)
                    } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.elements) { item in
                Button {
                    router.route(to: .downloadItem(item: item))
                } label: {
                    DownloadItemRowView(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        downloadManager.delete(itemID: item.id)
                    } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                }

                Divider()
                    .padding(.leading, 88)
            }
        }
    }
}

// MARK: - DownloadItemPosterView

struct DownloadItemPosterView: View {

    let item: DownloadItemDto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // Poster image
                posterImage
                    .posterStyle(item.preferredPosterDisplayType)
                    .posterShadow()

                // Downloaded indicator
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color.accentColor)
                            .padding(-2)
                    )
                    .padding(8)
            }

            // Title
            if item.showTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        ImageView(item.portraitImageSources())
            .failure {
                SystemImageContentView(systemName: item.systemImage)
            }
    }
}

// MARK: - DownloadItemRowView

struct DownloadItemRowView: View {

    let item: DownloadItemDto

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ImageView(item.portraitImageSources())
                .failure {
                    SystemImageContentView(systemName: item.systemImage)
                }
                .frame(width: 60, height: 90)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack {
                    if let runtime = item.runTimeLabel {
                        Text(runtime)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let fileSize = item.fileSize {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(FileManager.default.formatBytes(fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
