// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SkipFuse
import SwiftUI
import SkipFirebaseCore
import SkipFirebaseMessaging

/// A logger for the ECashWalletMobile module.
let logger: Logger = Logger(subsystem: "com.layertwolabs.mobile.ecashwallet", category: "ECashWalletMobile")

/// The platform bridge entry, loaded from the platform-specific App delegates below.
/// It stays thin — it just hosts the app's logical root, `RootView`.
/* SKIP @bridge */public struct ECashWalletMobileRootView : View {
    /* SKIP @bridge */public init() {
    }

    public var body: some View {
        RootView()
    }
}

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
/* SKIP @bridge */public final class ECashWalletMobileAppDelegate : Sendable {
    /* SKIP @bridge */public static let shared = ECashWalletMobileAppDelegate()

    // Push-notification delegates (Firebase Cloud Messaging via SkipFirebaseMessaging). Both platforms
    // route through the iOS-style UNUserNotificationCenterDelegate; MessageDelegate is the FCM
    // registration-token callback (bridged to the Kotlin Firebase API on Android).
    private let notificationDelegate = NotificationDelegate()
    private let messageDelegate = MessageDelegate()

    private init() {
    }

    /* SKIP @bridge */public func onInit() {
        logger.debug("onInit")
        FontRegistration.registerBundledFonts()   // iOS: register bundled .ttf with CoreText

        // Firebase. On Android, FirebaseApp.configure() reads the google-services.json the Gradle
        // plugin compiled in. On iOS/macOS, GoogleService-Info.plist lives in the SwiftPM module
        // bundle (not the main bundle), so configure with explicit options loaded from Bundle.module.
        #if !os(Android)
        if let path = Bundle.module.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        } else {
            logger.error("GoogleService-Info.plist missing from module bundle")
            FirebaseApp.configure()
        }
        #else
        FirebaseApp.configure()
        #endif
        Messaging.messaging().delegate = messageDelegate
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    /* SKIP @bridge */public func onLaunch() {
        logger.debug("onLaunch")
        // Ask for notification permission (cross-platform via UNUserNotificationCenter).
        notificationDelegate.requestPermission()
    }

    /* SKIP @bridge */public func onResume() {
        logger.debug("onResume")
    }

    /* SKIP @bridge */public func onPause() {
        logger.debug("onPause")
    }

    /* SKIP @bridge */public func onStop() {
        logger.debug("onStop")
    }

    /* SKIP @bridge */public func onDestroy() {
        logger.debug("onDestroy")
    }

    /* SKIP @bridge */public func onLowMemory() {
        logger.debug("onLowMemory")
    }
}

/// Cross-platform notification delegate (FCM). Requests permission, presents incoming notifications
/// while foregrounded, and on tap routes any recognized payload into an in-app alert sheet via
/// `PushRouter` (which `RootView` observes). Unrecognized pushes just show the system banner.
final class NotificationDelegate : NSObject, @preconcurrency UNUserNotificationCenterDelegate, @unchecked Sendable {
    func requestPermission() {
        Task { @MainActor in
            do {
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                logger.error("notification permission error: \(error)")
            }
        }
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]   // show even when the app is foregrounded
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        logger.info("notification tapped: \(content.title)")
        // Route the payload into a root-level in-app alert sheet. `userInfo` is the FCM data block
        // (custom key/value pairs); the notification block's title/body are the fallbacks.
        PushRouter.shared.handle(userInfo: content.userInfo,
                                 fallbackTitle: content.title,
                                 fallbackBody: content.body)
    }
}

/// FCM registration-token callback. Bridged because it uses the Firebase Kotlin API on Android.
/* SKIP @bridge */final class MessageDelegate : NSObject, MessagingDelegate, @unchecked Sendable {
    /* SKIP @bridge */public func messaging(_ messaging: Messaging, didReceiveRegistrationToken token: String?) {
        logger.info("didReceiveRegistrationToken: \(token ?? "nil")")
    }
}
