//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

struct DownloadTaskView: View {

    @Router
    private var router

    let item: BaseItemDto

    var body: some View {
        ScrollView(showsIndicators: false) {
            ContentView(item: item)
        }
        .navigationBarCloseButton {
            router.dismiss()
        }
    }
}
