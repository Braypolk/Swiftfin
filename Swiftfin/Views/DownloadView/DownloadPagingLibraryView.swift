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

struct DownloadPagingLibraryView: View {

    @Default(.Customization.Library.displayType)
    private var libraryDisplayType

    @Default(.Customization.Library.posterType)
    private var libraryPosterType

    @Default(.Customization.Library.listColumnCount)
    private var defaultListColumnCount

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

        let initialPosterType = Defaults[.Customization.Library.posterType]
        let initialDisplayType = Defaults[.Customization.Library.displayType]
        let initialListColumnCount = Defaults[.Customization.Library.listColumnCount]

        if UIDevice.isPhone {
            _columns = State(initialValue: Self.phoneLayout(
                posterType: initialPosterType,
                viewType: initialDisplayType
            ))
        } else {
            _columns = State(initialValue: Self.padLayout(
                posterType: initialPosterType,
                viewType: initialDisplayType,
                listColumnCount: initialListColumnCount
            ))
        }
    }

    @State
    private var columns: [GridItem]

    var body: some View {
        contentView
            .navigationTitle(L10n.downloads)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
            .onChange(of: libraryDisplayType) { newValue in
                updateLayout(displayType: newValue, posterType: libraryPosterType)
            }
            .onChange(of: libraryPosterType) { newValue in
                updateLayout(displayType: libraryDisplayType, posterType: newValue)
            }
            .onChange(of: defaultListColumnCount) { newValue in
                updateLayout(displayType: libraryDisplayType, posterType: libraryPosterType, listColumnCount: newValue)
            }
    }

    private func updateLayout(
        displayType: LibraryDisplayType,
        posterType: PosterDisplayType,
        listColumnCount: Int? = nil
    ) {
        let columnsCount = listColumnCount ?? defaultListColumnCount
        if UIDevice.isPhone {
            columns = Self.phoneLayout(
                posterType: posterType,
                viewType: displayType
            )
        } else {
            columns = Self.padLayout(
                posterType: posterType,
                viewType: displayType,
                listColumnCount: columnsCount
            )
        }
    }

    private static func padLayout(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType,
        listColumnCount: Int
    ) -> [GridItem] {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            return [GridItem(.adaptive(minimum: 200), spacing: 8)]
        case (.portrait, .grid), (.square, .grid):
            return [GridItem(.adaptive(minimum: 150), spacing: 8)]
        case (_, .list):
            return Array(repeating: GridItem(.flexible(), spacing: 0), count: listColumnCount)
        }
    }

    private static func phoneLayout(
        posterType: PosterDisplayType,
        viewType: LibraryDisplayType
    ) -> [GridItem] {
        switch (posterType, viewType) {
        case (.landscape, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        case (.portrait, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        case (.square, .grid):
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        case (_, .list):
            return [GridItem(.flexible(), spacing: 0)]
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
        .padding(.horizontal, EdgeInsets.edgePadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: 8) {
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
        .padding(.horizontal, EdgeInsets.edgePadding)
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

struct DownloadItemPosterView: View {

    let item: DownloadItemDto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
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

            if item.showTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1, reservesSpace: true)

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

struct DownloadItemRowView: View {

    let item: DownloadItemDto

    var body: some View {
        HStack(spacing: 12) {
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
