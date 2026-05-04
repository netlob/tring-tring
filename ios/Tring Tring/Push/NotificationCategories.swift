//
//  NotificationCategories.swift
//  Tring Tring
//

import UserNotifications

enum NotificationCategories {
    static func registerAll() async {
        let center = UNUserNotificationCenter.current()
        let categories: Set<UNNotificationCategory> = [
            makeCategory(slots: 1, id: "tt-1"),
            makeCategory(slots: 2, id: "tt-2"),
            makeCategory(slots: 3, id: "tt-3")
        ]
        center.setNotificationCategories(categories)
    }

    // Registered titles are fixed; iOS shows these on the action buttons.
    private static func makeCategory(slots: Int, id: String) -> UNNotificationCategory {
        let actions: [UNNotificationAction] = (0..<slots).map { i in
            UNNotificationAction(
                identifier: "act-\(i)",
                title: "Action \(i + 1)",
                options: [.foreground]
            )
        }
        return UNNotificationCategory(
            identifier: id,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }
}
