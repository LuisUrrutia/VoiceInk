import SwiftUI

/// Names the input in use with its live level, and the one reason it differs from the saved setting.
struct MicrophoneInputStatusView: View {
    @ObservedObject var devices: AudioDeviceManager
    let recorder: Recorder

    var body: some View {
        let status = devices.microphoneInputStatus
        LabeledContent("Input in Use") {
            HStack(spacing: 8) {
                Text(status.inputName ?? String(localized: "No microphone"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                MicrophoneLevelIndicator(recorder: recorder)
            }
        }

        if let message = status.message {
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}

/// Owns the level polling, so level changes redraw only the bars and never re-resolve the input.
private struct MicrophoneLevelIndicator: View {
    @StateObject private var monitor: MicrophoneLevelMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(recorder: Recorder) {
        _monitor = StateObject(wrappedValue: MicrophoneLevelMonitor(recorder: recorder))
    }

    var body: some View {
        MicrophoneLevelBars(display: monitor.display, animates: !reduceMotion)
            .onAppear {
                monitor.reducesMotion = reduceMotion
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: reduceMotion) { _, reduces in monitor.reducesMotion = reduces }
    }
}

/// Three uneven bars, after Hex's settings meter, so they never read as an ellipsis at rest.
private struct MicrophoneLevelBars: View {
    private static let weights: [CGFloat] = [0.6, 1, 0.75]

    let display: MicrophoneLevelMeter.Display
    let animates: Bool

    var body: some View {
        let level = CGFloat(display.step) / CGFloat(MicrophoneLevelMeter.steps)
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                let weight = Self.weights[index]
                Capsule()
                    .fill(barStyle(level: level))
                    .frame(width: 3, height: (3 + weight * 5 + level * weight * 10).rounded())
            }
        }
        .frame(width: 13, height: 18)
        .animation(animates ? .easeOut(duration: 0.08) : nil, value: display.step)
        .help(
            "Shows the input level while VoiceInk records, tests the microphone or keeps it ready. Opening this page never turns the microphone on."
        )
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(accessibilityValue)
    }

    private func barStyle(level: CGFloat) -> HierarchicalShapeStyle {
        guard display.isReceiving else { return .quaternary }
        return level > 0 ? .primary : .secondary
    }

    private var accessibilityValue: String {
        guard display.isReceiving else { return String(localized: "Not listening") }
        return String(localized: "\(display.step) of \(MicrophoneLevelMeter.steps)")
    }
}
