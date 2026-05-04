//
//  HomeView.swift
//  Tring Tring
//

import SwiftUI

struct HomeView: View {
    @Environment(DeviceState.self) private var deviceState

    var body: some View {
        TabView {
            Tab("Activity", systemImage: "bell.fill") {
                ActivityView()
            }
            Tab("Templates", systemImage: "tray.fill") {
                TemplatesView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
        .tint(.brass)
    }
}

#Preview {
    HomeView()
        .environment(DeviceState.shared)
}
