//
//  AboutSheet.swift
//  Tring Tring
//

import SwiftUI

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (build \(build))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.spacing.xl) {
                Spacer(minLength: 0)

                VStack(spacing: Theme.spacing.md) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.brass)
                        .padding(Theme.spacing.lg)
                        .glassEffect(
                            .regular.tint(Color.brass.opacity(0.18)),
                            in: .circle
                        )

                    Text("tring-tring")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))

                    Text(versionString)
                        .font(Theme.typography.monoSmall())
                        .foregroundStyle(.secondary)
                }

                Text("A self-hosted personal pager. Send a webhook, get a push. Calm, direct, and yours.")
                    .font(Theme.typography.bodySecondary())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacing.lg)

                Link(destination: URL(string: "https://github.com/netlob/tring-tring")!) {
                    Label("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.brass)
                .padding(.horizontal, Theme.spacing.lg)

                Spacer(minLength: 0)
            }
            .padding(Theme.spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
    }
}
