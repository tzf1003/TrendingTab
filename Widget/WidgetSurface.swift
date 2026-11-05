import SwiftUI

struct WidgetSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let radius = max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(
                    colors: [SurfacePalette.widgetTop, SurfacePalette.widgetBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if contrast != .increased {
                    RadialGradient(
                        colors: [SurfacePalette.widgetWarmGlow.opacity(glowOpacity), .clear],
                        center: .topLeading, startRadius: 0, endRadius: radius * 0.85
                    )
                    RadialGradient(
                        colors: [SurfacePalette.widgetCoolGlow.opacity(glowOpacity), .clear],
                        center: .bottomTrailing, startRadius: 0, endRadius: radius * 0.8
                    )
                }
                ContainerRelativeShape()
                    .strokeBorder(
                        LinearGradient(
                            colors: [SurfacePalette.edgeLight.opacity(colorScheme == .dark ? 0.24 : 0.8),
                                     SurfacePalette.edgeLight.opacity(0.05),
                                     SurfacePalette.edgeLight.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var glowOpacity: Double { colorScheme == .dark ? 0.22 : 0.55 }
}
