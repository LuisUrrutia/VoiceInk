import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(ViewType.sidebarGroups, id: \.self) { group in
                        VStack(spacing: 4) { ForEach(group) { destination in sidebarButton(destination) } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 9) {
                Image(appSymbol: "waveform").font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("VoiceInk").font(.system(size: 13, weight: .semibold))
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(20)
        }
        .appNavigationSurface()
        .frame(width: 216)
    }

    private func sidebarButton(_ destination: ViewType) -> some View {
        let isSelected = selectedView == destination
        return Button {
            selectedView = destination
        } label: {
            HStack(spacing: 10) {
                Image(appSymbol: destination.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.secondary)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)

                Text(destination.title).font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 42).contentShape(RoundedRectangle(cornerRadius: 9))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AppTheme.Accent.fillSubtle)
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(AppTheme.Accent.border, lineWidth: 0.5)
                        }
                }
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier("navigation.\(destination.id)")
        .accessibilityAddTraits(
            isSelected ? .isSelected : [])
    }
}

extension ViewType {
    fileprivate var icon: String {
        switch self {
        case .dashboard: "house.fill"
        case .modes: "sparkles"
        case .dictionary: "character.book.closed.fill"
        case .settings: "gearshape"
        case .audio: "speaker.wave.2.fill"
        case .models: "books.vertical.fill"
        case .history: "clock.arrow.circlepath"
        case .transcribeAudio: "waveform.badge.plus"
        }
    }

}
