//
//  OnboardingFlow.swift
//  Tring Tring
//

import SwiftUI

struct OnboardingFlow: View {
    let onComplete: () -> Void

    @State private var step: Int = 0

    var body: some View {
        TabView(selection: $step) {
            OnboardingWelcomeStep(onContinue: { advance(to: 1) })
                .tag(0)
            OnboardingPermissionStep(onContinue: { advance(to: 2) })
                .tag(1)
            OnboardingTestStep(onContinue: onComplete)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(
            LinearGradient(
                colors: [Color.brass.opacity(0.15), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }

    private func advance(to next: Int) {
        withAnimation(.smooth(duration: 0.4)) {
            step = next
        }
    }
}

#Preview {
    OnboardingFlow(onComplete: {})
        .environment(DeviceState.shared)
}
