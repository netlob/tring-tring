//
//  ContentView.swift
//  Tring Tring
//

import SwiftUI

struct ContentView: View {
    @Environment(DeviceState.self) private var deviceState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch deviceState.status {
            case .signedOut:
                SiwaSignInView()
            case .appleRevoked:
                SiwaSignInView(showsRevokedNotice: true)
            case .signedInPendingDevice:
                PendingDeviceView()
            case .registered(let userId, let webhookUrl):
                RegisteredView(userId: userId, webhookUrl: webhookUrl)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await deviceState.checkAppleCredentialState()
                    await deviceState.reRegisterIfAPIChanged()
                }
            }
        }
    }
}

private struct PendingDeviceView: View {
    @Environment(DeviceState.self) private var deviceState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Registering this device…")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let error = deviceState.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
            Button("Retry") {
                Task { await deviceState.retryRegistration() }
            }
            .buttonStyle(.bordered)
            Button("Sign out") {
                deviceState.signOutLocally()
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer().frame(height: 24)
        }
    }
}

private struct RegisteredView: View {
    @Environment(DeviceState.self) private var deviceState
    let userId: String
    let webhookUrl: String

    @State private var showSettings = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusSection
                    webhookSection
                    helpSection
                }
                .padding()
            }
            .navigationTitle("Tring Tring")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Label("Registered", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        if let error = deviceState.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your webhook URL")
                .font(.headline)
            Text(webhookUrl)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button {
                    UIPasteboard.general.string = webhookUrl
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Text("User ID: \(userId)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works")
                .font(.headline)
            Text("POST a JSON body to your webhook URL to receive a push notification on every device you've signed in on. Include a `url` field to make tapping the notification open a link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environment(DeviceState.shared)
}
