//
//  Tring_TringApp.swift
//  Tring Tring
//
//  Created by Sjoerd Bolten on 04/05/2026.
//

import SwiftUI

@main
struct Tring_TringApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var deviceState = DeviceState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(deviceState)
        }
    }
}
