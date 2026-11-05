import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.95, green: 0.34, blue: 0.19)
    static let accentSoft = accent.opacity(0.12)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let field = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.09)
    static let subtleText = Color.secondary
}

struct CardSurface<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    var title: String
    var color: Color = AppTheme.accent
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                prominent ? AppTheme.accent : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
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
