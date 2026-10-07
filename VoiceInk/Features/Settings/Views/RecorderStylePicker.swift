import SwiftUI

struct RecorderStylePicker: View {
    @Binding var selection: RecorderPanelStyle

    var body: some View {
        LabeledContent("Recorder Style") {
            HStack(spacing: 14) {
                ForEach(RecorderPanelStyle.allCases) { style in
                    Button {
                        selection = style
                    } label: {
                        VStack(spacing: 8) {
                            preview(style)
                                .frame(width: 112, height: 64)
                                .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(selection == style ? Color.accentColor : AppTheme.Border.control,
                                                      lineWidth: selection == style ? 2.5 : 1)
                                }
                                .appHoverHighlight(cornerRadius: 14)
                            Text(style.displayName).font(.system(size: 12))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.displayName)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func preview(_ style: RecorderPanelStyle) -> some View {
        ZStack(alignment: style == .notch ? .top : .center) {
            if style == .notch {
                VStack(spacing: 4) {
                    Capsule().fill(.white.opacity(0.18)).frame(width: 25, height: 3)
                    waveform(isMini: false)
                }
                .padding(.top, 6).padding(.bottom, 10).frame(width: 80)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
            } else {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    waveform(isMini: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.black, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style == .notch ? .top : .center)
        .accessibilityHidden(true)
    }

    private func waveform(isMini: Bool) -> some View {
        let heights: [CGFloat] = isMini ? [5, 12, 18, 9, 14, 6] : [5, 9, 14, 8, 18, 11, 15, 7, 12, 5]
        return HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule().fill(.white).frame(width: isMini ? 3 : 2, height: heights[index])
            }
        }
        .frame(height: 18)
    }
}
