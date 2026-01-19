//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import SwiftUI

struct DownloadQueueView: View {

    @Environment(\.dismiss)
    private var dismiss

    @ObservedObject
    var viewModel: DownloadPagingLibraryViewModel

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    var body: some View {
        List {
            let groups = viewModel.groupedQueue

            if let currentGroup = groups.first(where: { $0.isMainDownload }) {
                Section {
                    CurrentDownloadRow(
                        group: currentGroup,
                        onDelete: {
                            downloadManager.deleteGroup(id: currentGroup.id)
                        }
                    )
                } header: {
                    Text("Downloading")
                }
            }

            let pendingGroups = groups.filter { !$0.isMainDownload }
            if !pendingGroups.isEmpty {
                Section {
                    ForEach(pendingGroups) { group in
                        DownloadQueueRow(
                            group: group,
                            onDelete: {
                                downloadManager.deleteGroup(id: group.id)
                            }
                        )
                    }
                } header: {
                    Text("Queue (\(pendingGroups.count))")
                }
            }

            if viewModel.currentDownload == nil && viewModel.queue.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)

                        Text("No Active Downloads")
                            .font(.headline)

                        Text("Your download queue is empty")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }
        }
        .navigationTitle("Download Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.close) {
                    dismiss()
                }
            }
        }
    }
}

struct CurrentDownloadRow: View {

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    let group: DownloadPagingLibraryViewModel.DownloadQueueGroup
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(stageDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let currentTask = downloadManager.currentTask, group.items.contains(where: { $0.id == currentTask.id }) {
                    Button {
                        if currentTask.state == .paused {
                            downloadManager.resume(itemID: currentTask.id)
                        } else {
                            currentTask.pause()
                        }
                    } label: {
                        Image(systemName: currentTask.state == .paused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: group.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(formattedSizes)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(formattedPercentage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var stageDescription: String {
        guard let currentTask = downloadManager.currentTask, group.items.contains(where: { $0.id == currentTask.id }) else {
            return "Waiting..."
        }

        switch currentTask.stage {
        case .preparing:
            return "Preparing..."
        case let .downloadingMedia(progress):
            return "Downloading media (\(Int(progress * 100))%)"
        case .downloadingPrimaryImage:
            return "Downloading poster..."
        case .downloadingBackdropImage:
            return "Downloading backdrop..."
        case .downloadingLogoImage:
            return "Downloading logo..."
        case .savingMetadata:
            return "Saving metadata..."
        case .completed:
            return "Complete"
        }
    }

    private var formattedSizes: String {
        let downloaded = group.bytesDownloaded.formattedBytes
        let total = group.totalSize.formattedBytes
        return "\(downloaded) / \(total)"
    }

    private var formattedPercentage: String {
        "\(Int(group.progress * 100))%"
    }
}

struct DownloadQueueRow: View {

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    let group: DownloadPagingLibraryViewModel.DownloadQueueGroup
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {}
            }

            Spacer()

            if group.items.contains(where: { downloadManager.itemStates[$0.id] == .paused }) {
                Button {
                    if let pausedItem = group.items.first(where: { downloadManager.itemStates[$0.id] == .paused }) {
                        downloadManager.resume(itemID: pausedItem.id)
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                stateIndicator
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        let states = group.items.compactMap { downloadManager.itemStates[$0.id] }

        if states.contains(.downloading) {
            ProgressView()
        } else if states.contains(.paused) {
            Image(systemName: "pause.circle")
                .foregroundColor(.orange)
        } else if states.allSatisfy({ $0 == .complete }) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else if states.contains(.error) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        } else {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        }
    }
}
