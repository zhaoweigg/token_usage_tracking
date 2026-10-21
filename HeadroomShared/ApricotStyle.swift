import SwiftUI
import UIKit
import CoreText

enum HeadroomStyle {
    static let background = Color(uiColor: backgroundColor)
    static let surface = Color(uiColor: surfaceColor)
    static let primaryText = Color(uiColor: primaryTextColor)
    static let secondaryText = Color(uiColor: secondaryTextColor)
    static let accent = Color(uiColor: accentColor)
    static let tint = Color(uiColor: tintColor)
    static let track = adaptive(0xF2DFCF, 0x594133)
    static let separator = adaptive(0xECDFD3, 0x59483C)
    static let warning = adaptive(0x925012, 0xF8C17E)
    static let onAccent = adaptive(0xFFFFFF, 0x2A1D15)

    static let backgroundColor = adaptiveUIColor(0xFFF8F0, 0x251E1A)
    static let surfaceColor = adaptiveUIColor(0xFFFFFF, 0x342923)
    static let primaryTextColor = adaptiveUIColor(0x332B25, 0xFFF0E1)
    static let secondaryTextColor = adaptiveUIColor(0x7B695B, 0xC9B5A4)
    static let accentColor = adaptiveUIColor(0xAD482B, 0xF6AD87)
    static let tintColor = adaptiveUIColor(0xFBE5D6, 0x4A3126)

    private static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: adaptiveUIColor(light, dark))
    }

    private static func adaptiveUIColor(_ light: UInt, _ dark: UInt) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

enum HeadroomTypography {
    enum Weight: CaseIterable {
        case regular, medium, semibold, bold
        var name: String {
            switch self {
            case .regular: return "Manrope-Regular"
            case .medium: return "Manrope-Medium"
            case .semibold: return "Manrope-SemiBold"
            case .bold: return "Manrope-Bold"
            }
        }
        var filename: String { self == .semibold ? "Manrope-Semibold" : name }
    }

    // The extension has its own process and bundle, so register the same local
    // files there too rather than relying on registration by the containing app.
    private static let registration: Void = {
        for weight in Weight.allCases {
            if let url = Bundle.main.url(forResource: weight.filename, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func name(for weight: Weight) -> String {
        _ = registration
        return weight.name
    }

    static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 23
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    static func uiFont(size: CGFloat, weight: Weight = .regular, textStyle: UIFont.TextStyle = .body,
                       traits: UITraitCollection? = nil) -> UIFont {
        let font = UIFont(name: name(for: weight), size: size) ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font, compatibleWith: traits)
    }
}

extension Font {
    static func apricot(_ style: Font.TextStyle, weight: HeadroomTypography.Weight = .regular) -> Font {
        .custom(HeadroomTypography.name(for: weight), size: HeadroomTypography.size(for: style), relativeTo: style)
    }

    static func apricot(size: CGFloat, weight: HeadroomTypography.Weight = .regular,
                        relativeTo style: Font.TextStyle = .caption2) -> Font {
        .custom(HeadroomTypography.name(for: weight), size: size, relativeTo: style)
    }
}
