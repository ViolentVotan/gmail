import SwiftUI
import AppKit

// MARK: - NSColor WCAG Contrast

extension NSColor {
    /// Relative luminance per WCAG 2.1 (requires sRGB color space).
    func relativeLuminance() -> CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func linearize(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(c.redComponent)
             + 0.7152 * linearize(c.greenComponent)
             + 0.0722 * linearize(c.blueComponent)
    }

    /// Contrast ratio between two colors (1.0–21.0).
    func contrastRatio(against other: NSColor) -> CGFloat {
        let l1 = relativeLuminance()
        let l2 = other.relativeLuminance()
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Adjusts this color to meet the target contrast ratio against the given background.
    /// Darkens if text is lighter than background, lightens if darker.
    /// Returns self if already sufficient.
    func adjustedForContrast(against background: NSColor, targetRatio: CGFloat = 4.5) -> NSColor {
        guard let fg = usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else { return self }

        let bgLum = bg.relativeLuminance()
        let fgLum = fg.relativeLuminance()

        if fg.contrastRatio(against: bg) >= targetRatio { return self }

        // Extract HSB
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        fg.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let shouldDarken = fgLum > bgLum // text lighter than bg → darken

        for _ in 0..<20 {
            b += shouldDarken ? -0.05 : 0.05
            b = max(0, min(1, b))
            let candidate = NSColor(hue: h, saturation: s, brightness: b, alpha: a)
            if candidate.contrastRatio(against: bg) >= targetRatio {
                return candidate
            }
            if (shouldDarken && b <= 0) || (!shouldDarken && b >= 1) { break }
        }
        // Fallback: return fully dark or light
        return shouldDarken ? NSColor(red: 0, green: 0, blue: 0, alpha: a)
                            : NSColor(red: 1, green: 1, blue: 1, alpha: a)
    }
}

// MARK: - SwiftUI Color Convenience

extension Color {
    /// Only valid for sRGB-concrete colors created via Color(hex:), Color(red:green:blue:),
    /// or Color(nsColor:). Do NOT pass semantic colors (.primary, .secondary, .accentColor)
    /// or asset catalog colors — NSColor resolution will silently return nil for those.
    func adjustedForContrast(against background: Color, targetRatio: CGFloat = 4.5) -> Color {
        guard let fg = NSColor(self).usingColorSpace(.sRGB),
              let bg = NSColor(background).usingColorSpace(.sRGB)
        else { return self }
        return Color(nsColor: fg.adjustedForContrast(against: bg, targetRatio: targetRatio))
    }

    /// Returns the WCAG contrast target for the current accessibility context.
    static func contrastTarget(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 7.0 : 4.5
    }
}
