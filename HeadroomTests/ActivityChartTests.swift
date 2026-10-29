import XCTest
import SwiftUI
import UIKit
@testable import Headroom

@MainActor
final class ActivityChartTests: XCTestCase {
    func testRepeatedCaptureTimesDoNotSumIndependentPercentages() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repeated = (0..<20).map { _ in
            QuotaObservation(date: now.addingTimeInterval(-86400), period: .session, usedPercent: 20, source: .provider)
        }
        let observations = repeated + [
            QuotaObservation(date: now.addingTimeInterval(-3600), period: .session, usedPercent: 12, source: .provider),
            QuotaObservation(date: now, period: .session, usedPercent: 0, source: .provider)
        ]
        let renderer = ImageRenderer(content:
            QuotaHistoryChart(observations: observations)
                .padding(16).frame(width: 360, height: 260)
                .background(HeadroomStyle.surface)
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, .large)
        )
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Repeated timestamp quota chart"
        attachment.lifetime = .keepAlways
        add(attachment)

        let cgImage = try XCTUnwrap(rendered.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        HeadroomStyle.accentColor.resolvedColor(with: .init(userInterfaceStyle: .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let accent = [red, green, blue].map { Int(($0 * 255).rounded()) }
        var rows = Set<Int>()
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if (0..<3).allSatisfy({ abs(Int(pixels[offset + $0]) - accent[$0]) < 16 }) {
                    rows.insert(y)
                }
            }
        }
        XCTAssertGreaterThan(rows.count, 5, "The chart must actually render its usage bars.")
        let extent = try XCTUnwrap(rows.max()) - XCTUnwrap(rows.min()) + 1
        XCTAssertLessThanOrEqual(extent, height / 4,
                                 "Repeated 20% readings must stay at 20%, rather than stacking above 100%.")
    }
}
