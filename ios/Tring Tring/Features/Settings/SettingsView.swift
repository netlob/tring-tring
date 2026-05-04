//
//  SettingsView.swift
//  Tring Tring
//

import OSLog
import SwiftUI

struct SettingsView: View {
    @Environment(DeviceState.self) private var deviceState

    @State private var devices: [DeviceSummary] = []
    @State private var devicesLoading = false
    @State private var devicesError: String?

    @State private var apiBaseURLDraft: String = ""
    @State private var showAPIChangeConfirm = false
    @State private var showSignOutConfirm = false
    @State private var showAbout = false
    @State private var apiSaveFeedback: String?

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "settings")

    init() {}

    private var registered: (userId: String, webhookUrl: String)? {
        if case .registered(let userId, let webhookUrl) = deviceState.status {
            return (userId, webhookUrl)
        }
        return nil
    }

    private var webhookUrl: String { registered?.webhookUrl ?? "" }
    private var userId: String? { registered?.userId }

    private var trimmedDraft: String {
        apiBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDraft: String {
        let t = trimmedDraft
        return t.hasSuffix("/") ? String(t.dropLast()) : t
    }

    private var draftIsValid: Bool {
        guard !trimmedDraft.isEmpty, let url = URL(string: trimmedDraft) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private var draftDiffersFromCurrent: Bool {
        normalizedDraft != APIBaseURL.currentBaseURL
    }

    var body: some View {
        NavigationStack {
            Form {
                webhookSection
                devicesSection
                soundsSection
                configurationSection
                accountSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .task { await loadDevices() }
            .onAppear {
                apiBaseURLDraft = APIBaseURL.currentBaseURL
            }
            .refreshable { await loadDevices() }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
            .alert("Change API base URL?",
                   isPresented: $showAPIChangeConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) { applyAPIChange() }
            } message: {
                Text("This will sign you out so you can re-register on the new server. Proceed?")
            }
            .alert("Sign out?",
                   isPresented: $showSignOutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    HapticFeedback.warning.fire()
                    deviceState.signOutLocally()
                }
            } message: {
                Text("You'll need to sign in with Apple again to receive notifications.")
            }
        }
    }

    @ViewBuilder
    private var webhookSection: some View {
        Section {
            BrandedCard {
                WebhookURLBlock(url: webhookUrl)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Theme.spacing.sm,
                                      leading: Theme.spacing.xs,
                                      bottom: Theme.spacing.lg,
                                      trailing: Theme.spacing.xs))
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        DevicesSection(
            devices: devices,
            isLoading: devicesLoading,
            loadError: devicesError
        )
    }

    @ViewBuilder
    private var soundsSection: some View {
        SoundsPreviewSection(
            webhookUrl: registered?.webhookUrl,
            userId: registered?.userId
        )
    }

    @ViewBuilder
    private var configurationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.spacing.sm) {
                TextField("https://your-host.example", text: $apiBaseURLDraft)
                    .font(Theme.typography.mono())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)

                HStack(spacing: Theme.spacing.sm) {
                    Button("Reset to default") {
                        apiBaseURLDraft = APIBaseURL.defaultBaseURL
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button("Save") {
                        attemptSaveAPI()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.brass)
                    .disabled(!draftIsValid || !draftDiffersFromCurrent)
                }

                if let apiSaveFeedback {
                    Text(apiSaveFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Theme.spacing.xs)
        } header: {
            Text("Configuration")
        } footer: {
            Text("Default: \(APIBaseURL.defaultBaseURL). Changing this signs you out and re-registers your device.")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            Button {
                showAbout = true
            } label: {
                HStack {
                    Label("About", systemImage: "info.circle")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func attemptSaveAPI() {
        guard draftIsValid else { return }
        if !draftDiffersFromCurrent {
            apiSaveFeedback = "No change."
            return
        }
        showAPIChangeConfirm = true
    }

    private func applyAPIChange() {
        let normalized = normalizedDraft
        APIBaseURL.set(normalized)
        log.info("api base url changed; signing out for re-register")
        HapticFeedback.warning.fire()
        deviceState.signOutLocally()
    }

    private func loadDevices() async {
        guard let bearer = deviceState.bearerToken else {
            devices = []
            return
        }
        devicesLoading = true
        devicesError = nil
        defer { devicesLoading = false }

        do {
            let response = try await BackendClient.shared.userDetails(bearer: bearer)
            devices = response.devices
        } catch let error as APIError {
            devicesError = error.errorDescription
            log.error("user details fetch failed: \(String(describing: error), privacy: .public)")
        } catch {
            devicesError = error.localizedDescription
            log.error("user details fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    SettingsView()
        .environment(DeviceState.shared)
}
