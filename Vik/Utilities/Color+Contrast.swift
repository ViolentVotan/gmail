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
}
