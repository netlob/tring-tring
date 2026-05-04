//
//  AppDelegate.swift
//  Tring Tring
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        Task {
            await NotificationCategories.registerAll()
        }

        Task { @MainActor in
            await DeviceState.shared.checkAppleCredentialState()
            // If we already have a stored APNs token + Apple session, the system
            // re-issues the token via didRegisterForRemoteNotifications. Trigger
            // it explicitly to refresh the token after each cold launch.
            if case .registered = DeviceState.shared.status {
                UIApplication.shared.registerForRemoteNotifications()
            } else if case .signedInPendingDevice = DeviceState.shared.status {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await DeviceState.shared.handleAPNsToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            let options = await PushActionRouter.shared.handleForegroundPresentation(notification: notification)
            completionHandler(options)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await PushActionRouter.shared.handle(response: response, deviceState: DeviceState.shared)
            completionHandler()
        }
    }
}
