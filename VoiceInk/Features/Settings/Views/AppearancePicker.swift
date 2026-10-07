import SwiftUI

struct AppearancePicker: View {
    @Binding var selection: AppAppearancePreference

    var body: some View {
        LabeledContent("Theme") {
            HStack(spacing: 12) {
                ForEach(AppAppearancePreference.allCases) { preference in
                    Button {
                        selection = preference
                    } label: {
                        VStack(spacing: 7) {
                            preview(preference).frame(width: 88, height: 56)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 7)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(
                                            selection == preference ? Color.accentColor : AppTheme.Border.control,
                                            lineWidth: selection == preference ? 2 : 1)
                                }
                            Text(preference.displayName)
                                .font(
                                    .system(size: 12, weight: selection == preference ? .semibold : .regular))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(preference.displayName)
                    .accessibilityAddTraits(
                        selection == preference ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func preview(_ preference: AppAppearancePreference) -> some View {
        HStack(spacing: 0) {
            miniature(isDark: preference == .dark)
            if preference == .system { miniature(isDark: true) }
        }
        .accessibilityHidden(true)
    }

    private func miniature(isDark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 1).fill(Color.blue).frame(height: 4)
                RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.4)).frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(6).frame(width: 24).background(isDark ? Color(white: 0.18) : Color(white: 0.87))
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.8)).frame(height: 10)
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.18)).frame(height: 14)
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .background(isDark ? Color(white: 0.12) : .white)
    }
}
