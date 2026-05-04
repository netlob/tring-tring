import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct WebhookURLBlock: View {
    var url: String

    @State private var didCopy = false
    @State private var showQRSheet = false
    @State private var showCurlSheet = false

    init(url: String) {
        self.url = url
    }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: Theme.spacing.md) {
                HStack(spacing: Theme.spacing.sm) {
                    Image(systemName: "link")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.brass)
                    Text("Your webhook URL")
                        .font(Theme.typography.cardTitle())
                    Spacer()
                }

                MonoText(url)
                    .padding(Theme.spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(
                        .regular.tint(Color.brass.opacity(0.10)),
                        in: .rect(cornerRadius: Theme.radius.small)
                    )

                HStack(spacing: Theme.spacing.sm) {
                    Button {
                        copy()
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.brass)

                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)

                    Button {
                        HapticFeedback.light.fire()
                        showQRSheet = true
                    } label: {
                        Image(systemName: "qrcode")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Show QR code")

                    Button {
                        HapticFeedback.light.fire()
                        showCurlSheet = true
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("View as cURL")
                }
            }
            .padding(Theme.spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.tint(Color.brass.opacity(0.18)),
                in: .rect(cornerRadius: Theme.radius.medium)
            )
        }
        .sheet(isPresented: $showQRSheet) {
            QRSheet(url: url)
                .presentationDetents([.medium, .large])
                .presentationBackground(.thinMaterial)
        }
        .sheet(isPresented: $showCurlSheet) {
            CurlSheet(url: url)
                .presentationDetents([.medium, .large])
                .presentationBackground(.thinMaterial)
        }
    }

    private func copy() {
        UIPasteboard.general.string = url
        HapticFeedback.success.fire()
        withAnimation(.smooth(duration: 0.3)) {
            didCopy = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                withAnimation(.smooth(duration: 0.3)) {
                    didCopy = false
                }
            }
        }
    }
}

private struct QRSheet: View {
    var url: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.spacing.xl) {
                Spacer(minLength: 0)
                if let image = generateQR(for: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 280)
                        .padding(Theme.spacing.lg)
                        .glassEffect(
                            .regular.tint(Color.brass.opacity(0.15)),
                            in: .rect(cornerRadius: Theme.radius.large)
                        )
                } else {
                    Text("Could not generate QR code")
                        .font(Theme.typography.bodySecondary())
                        .foregroundStyle(.secondary)
                }
                MonoText(url)
                    .font(Theme.typography.monoSmall())
                    .padding(.horizontal, Theme.spacing.lg)
                Spacer(minLength: 0)
            }
            .padding(Theme.spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Webhook QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func generateQR(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct CurlSheet: View {
    var url: String
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private var curlCommand: String {
        "curl -X POST '\(url)' \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"title\":\"Hello\",\"text\":\"This is a test\"}'"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing.lg) {
                    Text("Send a notification from any shell:")
                        .font(Theme.typography.bodySecondary())
                        .foregroundStyle(.secondary)

                    MonoText(curlCommand)
                        .padding(Theme.spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(
                            .regular.tint(Color.brass.opacity(0.12)),
                            in: .rect(cornerRadius: Theme.radius.small)
                        )

                    Button {
                        UIPasteboard.general.string = curlCommand
                        HapticFeedback.success.fire()
                        withAnimation(.smooth(duration: 0.3)) {
                            didCopy = true
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            await MainActor.run {
                                withAnimation(.smooth(duration: 0.3)) {
                                    didCopy = false
                                }
                            }
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy command", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.brass)
                }
                .padding(Theme.spacing.lg)
            }
            .navigationTitle("View as cURL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
