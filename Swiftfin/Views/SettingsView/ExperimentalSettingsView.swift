//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

// Note: Used for experimental settings that may be removed or implemented
//       officially. Keep for future settings.

struct ExperimentalSettingsView: View {

    @Default(.Experimental.downloads)
    private var experimentalDownloads

    @Default(.offlineMode)
    private var offlineMode

    var body: some View {
        Form {
            Section {
                Toggle(L10n.downloads, isOn: $experimentalDownloads)
            } footer: {
                Text("Experimental features may be unstable or removed in future versions.")
            }
        }
        .navigationTitle(L10n.experimental)
        .onChange(of: experimentalDownloads) { newValue in
            // If experimental downloads is disabled, also disable offline mode
            if !newValue && offlineMode {
                offlineMode = false
            }
        }
    }
}
