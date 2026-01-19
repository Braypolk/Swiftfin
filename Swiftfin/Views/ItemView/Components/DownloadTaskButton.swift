//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import SwiftUI

struct DownloadTaskButton: View {

    @ObservedObject
    private var downloadManager: DownloadManager

    private let item: BaseItemDto
    private var onSelect: (BaseItemDto) -> Void

    private var downloadStatus: DownloadManager.DownloadItemStatus? {
        guard let itemID = item.id else { return nil }
        return downloadManager.status(for: itemID)
    }

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            if let status = downloadStatus {
                switch status.state {
                case .cancelled:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .downloading:
                    EmptyView()
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                case .pending:
                    Image(systemName: "arrow.down.circle")
                case .paused:
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)
                }
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
    }
}

extension DownloadTaskButton {

    init(item: BaseItemDto) {
        self.item = item
        self.downloadManager = Container.shared.downloadManager()
        self.onSelect = { _ in }
    }

    func onSelect(_ action: @escaping (BaseItemDto) -> Void) -> Self {
        copy(modifying: \.onSelect, with: action)
    }
}
