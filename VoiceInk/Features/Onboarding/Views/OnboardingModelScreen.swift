import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let localModel: FluidAudioModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let isSetupReady: Bool
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownload: (FluidAudioModel) -> Void
    let onCancelDownload: (FluidAudioModel) -> Void
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            OnboardingTranscriptionSetupCard(
                localModel: localModel,
                setupKind: setupKind,
                providerOptions: providerOptions,
                selectedProviderKey: $selectedProviderKey,
                isLocalDownloaded: isLocalDownloaded,
                isLocalDownloading: isLocalDownloading,
                localDownloadStatus: localDownloadStatus,
                onSelectSetupKind: onSelectSetupKind,
                onDownloadLocalModel: onDownload,
                onCancelLocalModelDownload: onCancelDownload,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("You can choose a model later in Models.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip for now", action: onSkip).buttonStyle(.borderless)
                        .accessibilityIdentifier(
                            "onboarding.skipModel")
                }
                OnboardingBottomBar(
                    leadingTitle: "Back",
                    primaryTitle: "Continue",
                    isPrimaryEnabled: isSetupReady && !(setupKind == .local && isLocalDownloading),
                    onLeading: onBack,
                    onPrimary: onContinue
                )
            }
        }
    }
}
