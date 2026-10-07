import Foundation
import SwiftUI

struct AppIconButton: View {
    let systemName: String
    let help: LocalizedStringResource
    var size: CGFloat = 30
    var iconSize: CGFloat = 14
    var isDisabled = false
    let action: () -> Void

    init(
        systemName: String,
        help: LocalizedStringResource,
        size: CGFloat = 30,
        iconSize: CGFloat = 14,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.iconSize = iconSize
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(isDisabled ? .secondary.opacity(0.45) : .primary.opacity(0.7))
                .frame(width: max(16, size - 12), height: max(16, size - 12))
        }
        .appGlassButtonStyle(shape: .circle)
        .controlSize(.large)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum AppActionButtonKind: Equatable {
    case secondary
    case primary
    case destructive
}

struct AppActionButton: View {
    let title: LocalizedStringKey
    var kind: AppActionButtonKind = .secondary
    var minWidth: CGFloat?
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        kind: AppActionButtonKind = .secondary,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.minWidth = minWidth
        self.action = action
    }

    var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            Text(title)
                .frame(minWidth: minWidth)
        }
        .font(.system(size: 12, weight: .semibold))
        .controlSize(.large)
        .appGlassButtonStyle(kind)
    }
}

extension View {
    @ViewBuilder
    func appGlassButtonStyle(_ kind: AppActionButtonKind = .secondary, shape: ButtonBorderShape = .capsule) -> some View {
        if #available(macOS 26.0, *) {
            if kind == .secondary {
                buttonStyle(.glass).buttonBorderShape(shape)
            } else {
                buttonStyle(.glassProminent).buttonBorderShape(shape)
                    .tint(kind == .destructive ? AppTheme.Status.error : .accentColor)
                    .foregroundStyle(.white)
            }
        } else if kind == .secondary {
            buttonStyle(.bordered).buttonBorderShape(shape)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(shape)
                .tint(kind == .destructive ? AppTheme.Status.error : .accentColor)
        }
    }
}

struct AppPanelHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                action: onClose
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .zIndex(1)
    }
}

struct AppScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var infoMessage: LocalizedStringKey?
    var infoURL: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }

                if let infoMessage {
                    if let infoURL {
                        InfoTip(infoMessage, learnMoreURL: infoURL)
                    } else {
                        InfoTip(infoMessage)
                    }
                }
            }

            Spacer()

            trailing()
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }
}

extension AppScreenHeader where Trailing == EmptyView {
    init(
        title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, infoMessage: LocalizedStringKey? = nil,
        infoURL: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.infoMessage = infoMessage
        self.infoURL = infoURL
        self.trailing = { EmptyView() }
    }
}
