//
//  ContentView.swift
//  Tring Tring
//

import SwiftUI

struct ContentView: View {
    @Environment(DeviceState.self) private var deviceState
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await deviceState.reRegisterIfAPIChanged() }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch deviceState.status {
        case .idle, .requestingPermission, .awaitingToken:
            Label("Waiting for push registration…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .registering:
            Label("Registering with backend…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .registered:
            Label("Registered", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Registration failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await deviceState.registerIfNeeded(force: true) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your webhook URL")
                .font(.headline)
            if let url = deviceState.webhookUrl {
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button {
                        UIPasteboard.general.string = url
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
            } else {
                Text("Your URL will appear here once your device is registered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works")
                .font(.headline)
            Text("POST a JSON body to your webhook URL to receive a push notification on this device. Include a `url` field to make tapping the notification open a link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsView: View {
    @Environment(DeviceState.self) private var deviceState
    @Environment(\.dismiss) private var dismiss
    @State private var apiBaseURL: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-host.example", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("API base URL")
                } footer: {
                    Text("Default: \(APIConfig.defaultBaseURL). Changing this re-registers your device with the new backend.")
                }

                Section {
                    Button("Reset to default") {
                        apiBaseURL = APIConfig.defaultBaseURL
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                apiBaseURL = UserDefaults.standard.string(forKey: APIConfig.baseURLKey) ?? APIConfig.defaultBaseURL
            }
        }
    }

    private var isValid: Bool {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func save() {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        UserDefaults.standard.set(normalized, forKey: APIConfig.baseURLKey)
        Task { await deviceState.reRegisterIfAPIChanged() }
    }
}

#Preview {
    ContentView()
        .environment(DeviceState.shared)
}
