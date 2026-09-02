import SwiftUI

/// A calendar colour as components rather than an opaque `Color`, so the swatch and the decision
/// about what is legible on top of it come from one source (spec 3B.7).
struct CalendarSwatch: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// WCAG relative luminance. Used only to choose a foreground, so the sRGB transfer function
    /// matters more than perceptual nicety.
    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Spec 3B.7: a provider's colour is arbitrary, and some are illegible against one appearance
    /// or the other. Calendar colour is a fill behind text in the Day/Week/Month chips, so the
    /// foreground is chosen per swatch rather than fixed.
    ///
    /// The 0.45 threshold sits above the 0.179 point where white and black contrast equally,
    /// biasing towards white text — which reads better on the mid-saturation blues, greens and
    /// reds that account colours overwhelmingly are.
    var prefersLightForeground: Bool {
        relativeLuminance < 0.45
    }

    /// Parses `#RRGGBB` or `RRGGBB`, and the eight-digit `#RRGGBBAA` an account occasionally
    /// supplies — trailing alpha is dropped rather than honoured, because a translucent calendar
    /// colour renders as a different colour on every background it lands on.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else {
            return nil
        }

        // Eight digits are read as #RRGGBBAA, so the colour is the high six.
        let rgb = digits.count == 8 ? (value >> 8) : value
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension CalendarColorName {
    /// The design tokens from UI/UX §6.2.
    var swatch: CalendarSwatch {
        switch self {
        case .betterBlue: CalendarSwatch(red: 0.31, green: 0.49, blue: 1.0)
        case .success: CalendarSwatch(red: 0.18, green: 0.66, blue: 0.42)
        case .warning: CalendarSwatch(red: 0.90, green: 0.54, blue: 0.18)
        case .destructive: CalendarSwatch(red: 0.85, green: 0.30, blue: 0.30)
        case .navy: CalendarSwatch(red: 0.09, green: 0.14, blue: 0.24)
        case .gray: CalendarSwatch(red: 0.36, green: 0.40, blue: 0.47)
        }
    }

    var color: Color {
        swatch.color
    }
}

extension BetterCalendar {
    /// Spec 3B.7: a device calendar carries an arbitrary provider colour in `colorHex`; a local
    /// one carries a design token and no hex, and renders exactly as it did before this existed.
    ///
    /// An unparseable hex falls back to the token rather than to a default colour, so a provider
    /// sending something unexpected produces a wrong-but-legible calendar rather than an
    /// invisible one.
    var displaySwatch: CalendarSwatch {
        colorHex.flatMap(CalendarSwatch.init(hex:)) ?? colorName.swatch
    }

    var displayColor: Color {
        displaySwatch.color
    }

    /// What to draw *on* `displayColor`.
    var displayForegroundColor: Color {
        displaySwatch.prefersLightForeground ? .white : Color(red: 0.09, green: 0.11, blue: 0.15)
    }
}
