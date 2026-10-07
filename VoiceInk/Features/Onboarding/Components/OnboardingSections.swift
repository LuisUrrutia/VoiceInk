import SwiftUI

struct OnboardingBackground: View {
    var body: some View {
        AppTheme.Surface.window.ignoresSafeArea()
    }
}

enum OnboardingLayout {
    static let chromeMaxWidth: CGFloat = 560
    static let horizontalPadding: CGFloat = 36
    static let headerTopPadding: CGFloat = 36
    static let bottomPadding: CGFloat = 28
}

struct OnboardingHeroHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingSidebar: View {
    let stage: OnboardingStage
    let skippedModel: Bool
    private let stages: [OnboardingStage] = [.permissions, .microphone, .model, .api, .experience, .trust]
    private let titles: [LocalizedStringKey] = [
        "Permissions", "Microphone", "Model", "Enhancement", "Try it out", "Ready"
    ]

    private var currentIndex: Int { stages.firstIndex(of: stage == .contextAwareness ? .experience : stage) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Label("VoiceInk", systemImage: "waveform").font(.system(size: 20, weight: .semibold)).padding(.top, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("GET STARTED").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(
                        .bottom, 8)
                ForEach(stages.indices, id: \.self) { index in
                    let skipped = skippedModel && (2...4).contains(index)
                    HStack(spacing: 10) {
                        Image(
                            systemName: skipped
                                ? "minus.circle" : index < currentIndex ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(index == currentIndex ? Color.accentColor : Color.secondary).frame(width: 18)
                        Text(titles[index])
                            .font(
                                .system(size: 13, weight: index == currentIndex ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(
                        index == currentIndex ? AppTheme.Selection.fill : .clear, in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(titles[index])
                    .accessibilityValue(
                        skipped
                            ? "Skipped"
                            : index < currentIndex ? "Completed" : index == currentIndex ? "Current step" : "Upcoming")
                }
            }
            Spacer()
            Text("Your voice. Your workflow.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .appNavigationSurface()
        .frame(width: 210)
    }
}

enum OnboardingBottomBarPlacement {
    case split
    case centered
}

struct OnboardingBottomBar: View {
    let leadingTitle: String?
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    var placement: OnboardingBottomBarPlacement = .split
    let onLeading: (() -> Void)?
    let onPrimary: () -> Void

    private enum Metrics {
        static let controlButtonWidth: CGFloat = 132
        static let buttonHeight: CGFloat = 42
        static let primaryButtonHorizontalPadding: CGFloat = 20
    }

    @ViewBuilder
    var body: some View {
        switch placement {
        case .split:
            HStack(spacing: 0) {
                leadingSlot
                    .frame(maxWidth: .infinity, alignment: .leading)
                primaryButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .centered:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                primaryButton
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let leadingTitle, let onLeading {
            Button(action: onLeading) {
                Text(LocalizedStringKey(leadingTitle))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: Metrics.controlButtonWidth, height: Metrics.buttonHeight)
            }
            .appGlassButtonStyle()
        } else {
            AppTheme.Surface.clear
                .frame(width: Metrics.controlButtonWidth, height: Metrics.buttonHeight)
                .accessibilityHidden(true)
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            Text(LocalizedStringKey(primaryTitle))
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, Metrics.primaryButtonHorizontalPadding)
                .frame(minWidth: Metrics.controlButtonWidth, minHeight: Metrics.buttonHeight)
        }
        .appGlassButtonStyle(.primary)
        .disabled(!isPrimaryEnabled).keyboardShortcut(.defaultAction)
    }
}

struct OnboardingStepScreen<Content: View, BottomBar: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let contentMaxWidth: CGFloat
    let showsHeader: Bool
    let contentYOffset: CGFloat
    let content: Content
    let bottomBar: BottomBar

    init(
        stage: OnboardingStage,
        contentMaxWidth: CGFloat,
        showsHeader: Bool = true,
        contentYOffset: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> BottomBar
    ) {
        self.systemImage = stage.systemImage
        self.title = stage.title
        self.subtitle = stage.subtitle
        self.contentMaxWidth = contentMaxWidth
        self.showsHeader = showsHeader
        self.contentYOffset = contentYOffset
        self.content = content()
        self.bottomBar = bottomBar()
    }

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        contentMaxWidth: CGFloat,
        showsHeader: Bool = true,
        contentYOffset: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> BottomBar
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.contentMaxWidth = contentMaxWidth
        self.showsHeader = showsHeader
        self.contentYOffset = contentYOffset
        self.content = content()
        self.bottomBar = bottomBar()
    }

    var body: some View {
        if showsHeader {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        OnboardingHeroHeader(
                            systemImage: systemImage,
                            title: title,
                            subtitle: subtitle
                        )
                        content.frame(maxWidth: contentMaxWidth)
                    }
                    .frame(maxWidth: max(contentMaxWidth, OnboardingLayout.chromeMaxWidth))
                    .padding(
                        .top, OnboardingLayout.headerTopPadding
                    )
                    .padding(.bottom, 24).frame(maxWidth: .infinity)
                }
                AppGlassContainer { bottomBar }.frame(maxWidth: OnboardingLayout.chromeMaxWidth)
                    .padding(.top, 16)
                    .padding(.bottom, OnboardingLayout.bottomPadding)
            }
            .padding(.horizontal, OnboardingLayout.horizontalPadding)
        } else {
            ZStack {
                content
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .offset(y: contentYOffset)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    AppGlassContainer { bottomBar }
                        .frame(maxWidth: OnboardingLayout.chromeMaxWidth)
                }
                .padding(.bottom, OnboardingLayout.bottomPadding)
            }
            .padding(.horizontal, OnboardingLayout.horizontalPadding)
        }
    }
}
