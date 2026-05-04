//
//  ContentView.swift
//  Tring Tring
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        AppRouter()
    }
}

#Preview {
    ContentView()
        .environment(DeviceState.shared)
}
