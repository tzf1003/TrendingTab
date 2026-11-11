import AppKit
import SwiftUI

enum AppTheme {
    static let accent = SurfacePalette.accent
    static let accentSoft = accent.opacity(0.12)
    static let actionTint = SurfacePalette.action
    static let canvas = SurfacePalette.canvas
    static let card = SurfacePalette.card
    static let rule = SurfacePalette.hairline
}

struct AppBrandIcon: View {
    var body: some View {
        Image("BrandIcon")
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

struct PaneSurface: View {
    enum Role {
        case sidebar, reader, inspector
    }

    let role: Role

    var body: some View {
        LinearGradient(
            colors: [color, color, AppTheme.canvas],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var color: Color {
        switch role {
        case .sidebar: SurfacePalette.sidebar
        case .reader: SurfacePalette.reading
        case .inspector: SurfacePalette.inspector
        }
    }
}

struct CardSurface<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.card, in: shape)
            .shadow(color: .black.opacity(0.025), radius: 10, y: 3)
            .overlay {
                shape.strokeBorder(AppTheme.rule, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct SectionHeading: View {
    var title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    var title: String
    var color: Color = AppTheme.accent

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct SelectableButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Surface(content: configuration.label, selected: selected,
                pressed: configuration.isPressed, cornerRadius: cornerRadius)
    }

    private struct Surface<Content: View>: View {
        let content: Content
        let selected: Bool
        let pressed: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(fill, in: shape)
                .overlay {
                    if selected {
                        shape.strokeBorder(AppTheme.accent.opacity(contrast == .increased ? 1 : 0.16), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(shape)
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.42)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }

        private var fill: Color {
            if selected {
                return pressed ? AppTheme.accent.opacity(0.2) : AppTheme.accentSoft
            }
            if isEnabled && (hovering || pressed) {
                return Color.primary.opacity(pressed ? 0.12 : 0.065)
            }
            return .clear
        }
    }
}

extension Date {
    var trendingRelativeText: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "更新于 \(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "更新于 \(Int(seconds / 3600)) 小时前" }
        return "更新于 \(formatted(.dateTime.month().day().hour().minute()))"
    }
}
