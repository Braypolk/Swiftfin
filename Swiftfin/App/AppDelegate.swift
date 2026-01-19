//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import PreferencesView
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Initialize background download session early to reconnect to any existing downloads
        _ = BackgroundDownloadSession.shared
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let topViewController = scene.keyWindow?.rootViewController,
           let presentedViewController = topViewController.presentedViewController,
           let preferencesHostingController = presentedViewController as? UIPreferencesHostingController
        {
            return preferencesHostingController.supportedInterfaceOrientations
        }

        return UIDevice.isPad ? .allButUpsideDown : .portrait
    }

    // MARK: - Background URL Session Handling

    /// Called when iOS wakes the app to handle background URL session events
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadSession.identifier {
            BackgroundDownloadSession.shared.storeCompletionHandler(completionHandler)
        } else {
            completionHandler()
        }
    }
}
