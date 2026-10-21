import XCTest
import UIKit
@testable import Headroom

@MainActor
final class ApricotStyleTests: XCTestCase {
    func testFontWeightsAreBundledInBothAppAndWidgetAndResolveWithoutFallback() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("HeadroomWidgets.appex")))
        for weight in HeadroomTypography.Weight.allCases {
            for bundle in [Bundle.main, widget] {
                XCTAssertNotNil(bundle.url(forResource: weight.filename, withExtension: "ttf"))
                XCTAssertTrue((bundle.object(forInfoDictionaryKey: "UIAppFonts") as? [String])?.contains(weight.filename + ".ttf") == true)
            }
            let font = try XCTUnwrap(UIFont(name: HeadroomTypography.name(for: weight), size: 17))
            XCTAssertEqual(font.familyName, "Manrope")
            XCTAssertEqual(font.fontName, weight.name)
        }
    }

    func testManropeScalesForAccessibilitySizes() {
        let normal = HeadroomTypography.uiFont(size: 17, textStyle: .body, traits: .init(preferredContentSizeCategory: .large))
        let accessible = HeadroomTypography.uiFont(size: 17, textStyle: .body, traits: .init(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThan(accessible.pointSize, normal.pointSize * 1.5)
        XCTAssertEqual(accessible.familyName, "Manrope")
    }

    func testTextContrastOnApricotSurfacesInBothAppearances() {
        func luminance(_ color: UIColor, _ traits: UITraitCollection) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
        }
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for background in [HeadroomStyle.backgroundColor, HeadroomStyle.surfaceColor] {
                for text in [HeadroomStyle.primaryTextColor, HeadroomStyle.secondaryTextColor] {
                    let values = [luminance(background, traits), luminance(text, traits)].sorted()
                    XCTAssertGreaterThanOrEqual((values[1] + 0.05) / (values[0] + 0.05), 4.5)
                }
            }
        }
    }
}
