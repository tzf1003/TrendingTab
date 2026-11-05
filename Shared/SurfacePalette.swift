import AppKit
import SwiftUI

enum SurfacePalette {
    static let canvas = adaptive(light: 0xF5F4F0, dark: 0x1C2026)
    static let reading = adaptive(light: 0xFCFBF8, dark: 0x23272E)
    static let sidebar = adaptive(light: 0xEEEFEA, dark: 0x20252C)
    static let inspector = adaptive(light: 0xF1F2EF, dark: 0x20252C)
    static let card = adaptive(light: 0xFFFEFC, dark: 0x2A3038)
    static let hairline = adaptive(light: 0x28323E, dark: 0xDFE6EE).opacity(0.10)
    static let accent = adaptive(light: 0xA3482F, dark: 0xEDB394)
    static let action = adaptive(light: 0xA3482F, dark: 0xAC573B)

    static let widgetTop = adaptive(light: 0xF3EDE3, dark: 0x29323D)
    static let widgetBottom = adaptive(light: 0xDEE7EE, dark: 0x171D25)
    static let widgetWarmGlow = adaptive(light: 0xEDD2B8, dark: 0x78543D)
    static let widgetCoolGlow = adaptive(light: 0xBACDDE, dark: 0x3A566D)
    static let edgeLight = adaptive(light: 0xFFFFFF, dark: 0xBCC9D8)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
