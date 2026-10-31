import SwiftUI

struct OnboardingPermissionsScreen: View {
    let contentMaxWidth: CGFloat
    let isComplete: Bool
    let activePermission: OnboardingPermissionKind
    let hasRequestedScreenRecording: Bool
    let stepNumber: (OnboardingPermissionKind) -> Int
    let status: (OnboardingPermissionKind) -> OnboardingPermissionStatus
    let isLocked: (OnboardingPermissionKind) -> Bool
    let actionTitle: (OnboardingPermissionKind) -> String
    let onSelect: (OnboardingPermissionKind) -> Void
    let onAction: (OnboardingPermissionKind) -> Void
    let onRecheck: () -> Void
    let onContinue: () -> Void
    let engine: VoiceInkEngine
    let shortcuts: RecordingShortcutManager

    var body: some View {
        OnboardingStepScreen(
            stage: .permissions,
            contentMaxWidth: contentMaxWidth
        ) {
            permissionList
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Recheck",
                primaryTitle: "Continue",
                isPrimaryEnabled: isComplete,
                onLeading: onRecheck,
                onPrimary: onContinue
            )
        }
    }

    private var permissionList: some View {
        VStack(spacing: 10) {
            ForEach(OnboardingPermissionKind.allCases) { permission in
                PermissionStepRow(
                    stepNumber: stepNumber(permission),
                    descriptor: permission.descriptor,
                    status: status(permission),
                    isActive: !isComplete && activePermission == permission,
                    isLocked: isLocked(permission),
                    actionTitle: actionTitle(permission),
                    onSelect: {
                        guard !isLocked(permission) else { return }
                        onSelect(permission)
                    },
                    onAction: {
                        onAction(permission)
                    }
                ) {
                    restartHint(for: permission)
                }
            }
        }
    }

    @ViewBuilder
    private func restartHint(for permission: OnboardingPermissionKind) -> some View {
        switch permission {
        case .microphone:
            EmptyView()
        case .accessibility:
            if status(.accessibility).isGranted {
                AccessibilityRestartHint(engine: engine, shortcuts: shortcuts)
            }
        case .screenRecording:
            // A running process gets Screen Recording only after relaunch, and preflight cannot tell a pending grant from none.
            if hasRequestedScreenRecording && !isLocked(.screenRecording) && !status(.screenRecording).isGranted {
                PermissionRestartHint(message: "Restart VoiceInk after enabling Screen Recording.", engine: engine)
            }
        }
    }
}

private struct AccessibilityRestartHint: View {
    let engine: VoiceInkEngine
    @ObservedObject var shortcuts: RecordingShortcutManager

    var body: some View {
        if shortcuts.hotkeyAvailability == .needsRestart {
            PermissionRestartHint(message: LocalizedStringKey(shortcuts.hotkeyAvailability.message), engine: engine)
        }
    }
}

private struct PermissionRestartHint: View {
    let message: LocalizedStringKey
    let engine: VoiceInkEngine

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.Text.muted)
                .fixedSize(horizontal: false, vertical: true)

            RestartVoiceInkButton(engine: engine)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.Action.secondaryForeground)
        }
        .padding(.leading, 44)
    }
}
