import AppKit
import SwiftUI

/// Offers the quick microphone choices from the recorder while its input delivers no sound.
/// A native menu pops from a styled button: SwiftUI's macOS `Menu` drops a label's font and color.
struct RecorderMicrophoneMenu: View {
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(QuickMicrophoneMenu.make(devices: .shared))
        } label: {
            HStack(spacing: 2) {
                Text("Pick another mic?")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(appSymbol: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .accessibilityLabel("Pick another mic?")
        .help("Pick another microphone")
    }
}

/// The toolbar and menu bar's memory-only choices: resume automatic selection, or use an input temporarily.
@MainActor
enum QuickMicrophoneMenu {
    static func make(devices: AudioDeviceManager) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if devices.temporaryMicrophone != nil {
            menu.addItem(ActionMenuItem(title: String(localized: "Resume Automatic Selection")) {
                devices.resumeAutomaticMicrophoneSelection()
            })
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: String(localized: "Use Microphone Temporarily")))
        let currentDeviceID = devices.getCurrentDevice()
        for device in devices.availableDevices {
            let deviceID = device.id
            let item = ActionMenuItem(title: device.name) { devices.selectTemporaryMicrophone(id: deviceID) }
            item.state = deviceID == currentDeviceID ? .on : .off
            item.isEnabled = devices.isDeviceUsableForRecording(deviceID)
            menu.addItem(item)
        }
        return menu
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func invoke() { handler() }
}

@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
