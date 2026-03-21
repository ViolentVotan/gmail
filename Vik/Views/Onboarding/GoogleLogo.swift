import SwiftUI

/// Multicolor Google "G" logo drawn purely in SwiftUI.
struct GoogleLogo: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = s / 2
            let inner = s * 0.28
            let barHeight = s * 0.16

            func arcPath(startAngle: Double, endAngle: Double) -> Path {
                var path = Path()
                path.addArc(center: center, radius: outer, startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                path.addArc(center: center, radius: inner, startAngle: .degrees(endAngle), endAngle: .degrees(startAngle), clockwise: true)
                path.closeSubpath()
                return path
            }

            // Blue arc (right / bottom-right) — 315° to 50°
            context.fill(arcPath(startAngle: -14, endAngle: 50), with: .color(Color(hex: "#4285F4")))
            // Green arc (bottom) — 50° to 150°
            context.fill(arcPath(startAngle: 50, endAngle: 150), with: .color(Color(hex: "#34A853")))
            // Yellow arc (left / bottom-left) — 150° to 230°
            context.fill(arcPath(startAngle: 150, endAngle: 230), with: .color(Color(hex: "#FBBC05")))
            // Red arc (top) — 230° to 315°
            context.fill(arcPath(startAngle: 230, endAngle: 315), with: .color(Color(hex: "#EA4335")))

            // Horizontal bar (the crossbar of the "G") — blue
            let barRect = CGRect(
                x: center.x + s * 0.04 - s * 0.52 / 2,
                y: center.y - barHeight / 2,
                width: s * 0.52,
                height: barHeight
            )
            context.fill(Path(barRect), with: .color(Color(hex: "#4285F4")))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
