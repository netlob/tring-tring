//
//  DevicesSection.swift
//  Tring Tring
//

import SwiftUI
import UIKit

struct DevicesSection: View {
    var devices: [DeviceSummary]
    var isLoading: Bool
    var loadError: String?

    private var thisDeviceName: String {
        UIDevice.current.name
    }

    var body: some View {
        Section {
            if isLoading && devices.isEmpty {
                HStack(spacing: Theme.spacing.md) {
                    ProgressView()
                    Text("Loading devices…")
                        .font(Theme.typography.bodySecondary())
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            } else if let loadError, devices.isEmpty {
                Text(loadError)
                    .font(Theme.typography.bodySecondary())
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            } else if devices.isEmpty {
                Text("No devices registered yet.")
                    .font(Theme.typography.bodySecondary())
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(devices) { device in
                    DeviceRow(device: device, isThis: isThisDevice(device))
                }
            }

            Text("Renaming and revoking are coming soon.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        } header: {
            Text("Devices")
        }
    }

    private func isThisDevice(_ device: DeviceSummary) -> Bool {
        guard let name = device.deviceName else { return false }
        return name == thisDeviceName
    }
}

private struct DeviceRow: View {
    var device: DeviceSummary
    var isThis: Bool

    var body: some View {
        HStack(spacing: Theme.spacing.md) {
            Image(systemName: "iphone")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.brass)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName ?? "Untitled")
                    .font(Theme.typography.body())
                Text(envLabel(device.apnsEnv))
                    .font(Theme.typography.bodySecondary())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isThis {
                Chip("This device", tint: .brass)
            }
        }
        .padding(.vertical, Theme.spacing.xs)
    }

    private func envLabel(_ env: String) -> String {
        switch env.lowercased() {
        case "production": return "Production"
        case "sandbox": return "Sandbox"
        default: return env
        }
    }
}
