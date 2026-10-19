import UIKit
import XCTest
@testable import Syncstr

final class AppearanceTests: XCTestCase {
    @MainActor
    func testPaletteAdaptsToAppearanceAndPreservesReadableText() throws {
        func resolve(_ name: String, _ style: UIUserInterfaceStyle) throws -> UIColor {
            try XCTUnwrap(UIColor(named: name)).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        }
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (foreground, background) in [("PrimaryText", "SurfaceContent"), ("SecondaryText", "SurfaceContent"),
                                             ("PrimaryText", "SurfaceControl"), ("AccentColor", "SurfaceContent")] {
                let values = try [foreground, background].map { luminance(try resolve($0, style)) }
                XCTAssertGreaterThanOrEqual((values.max()! + 0.05) / (values.min()! + 0.05), 4.5, "\(style): \(foreground) on \(background)")
            }
            let action = luminance(try resolve("ActionAccent", style))
            XCTAssertGreaterThanOrEqual(1.05 / (action + 0.05), 4.5)
        }
        XCTAssertNotEqual(try resolve("SurfaceContent", .light), try resolve("SurfaceContent", .dark))
        XCTAssertNotEqual(try resolve("AccentColor", .light), try resolve("AccentColor", .dark))
        XCTAssertEqual(try resolve("ActionAccent", .light), try resolve("ActionAccent", .dark))
    }
}
