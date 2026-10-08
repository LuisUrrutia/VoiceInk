import SwiftUI

struct OnboardingTrustScreen: View {
    let contentMaxWidth: CGFloat
    let hasSkippedModelSetup: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            systemImage: "checkmark.circle",
            title: hasSkippedModelSetup ? "Make yourself at home" : "You're ready to go",
            subtitle: "VoiceInk works without an account. Your settings and history stay on this Mac.",
            contentMaxWidth: contentMaxWidth
        ) {
            VStack(
                alignment: .leading, spacing: 0
            ) {
                setupRow(
                    "Local or cloud", icon: "desktopcomputer",
                    detail:
                        "Local models process audio on your Mac. Cloud models send audio to the provider you choose.")
                Divider().padding(.leading, 56)
                setupRow(
                    "Your own workflow", icon: "slider.horizontal.3",
                    detail: "Use Modes for different writing tasks and Dictionary for the words that matter to you.")
                if hasSkippedModelSetup {
                    Divider().padding(.leading, 56)
                    setupRow(
                        "Choose a model when you're ready", icon: "books.vertical",
                        detail:
                            "Open Models to download a local model or connect a provider, then create a mode to start dictating."
                    )
                }
            }
            .padding(6).background(AppCardBackground())
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Open VoiceInk",
                isPrimaryEnabled: true,
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }

    private func setupRow(_ title: LocalizedStringKey, icon: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(appSymbol: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
