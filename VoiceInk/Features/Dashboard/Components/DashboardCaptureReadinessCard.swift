import SwiftUI

struct DashboardCaptureReadinessCard: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject private var readiness: CaptureReadinessController
    let hasCompletedDictation: Bool
    let onRecord: () -> Void

    init(
        engine: VoiceInkEngine, shortcuts: RecordingShortcutManager, hasCompletedDictation: Bool,
        onRecord: @escaping () -> Void
    ) {
        self.engine = engine
        self.shortcuts = shortcuts
        self.readiness = engine.captureReadiness
        self.hasCompletedDictation = hasCompletedDictation
        self.onRecord = onRecord
    }

    var body: some View {
        if DashboardSetupGuide.showsCaptureReadiness(
            hasCompletedDictation: hasCompletedDictation, readiness: readiness.snapshot,
            hotkey: shortcuts.hotkeyAvailability, hasRecordingError: engine.recordingError != nil)
        {
            CaptureReadinessView(engine: engine, shortcuts: shortcuts, onRecord: onRecord)
                .padding(20)
                .appGlassCard()
        }
    }
}
