import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TerminalMacCore

final class FrameDecoderTests: XCTestCase {
    func testPNGDimensionsAreCheckedBeforeDecode() throws {
        func png(width: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        XCTAssertNotNil(FrameDecoder.image(try png(width: 16)))
        XCTAssertNil(FrameDecoder.image(try png(width: 8193)))
    }
    func testValidPixelsRoundTrip() throws {
        let data = Data(repeating: 42, count: 16 * 8 * 4)
        let compressed = try (data as NSData).compressed(using: .lz4) as Data
        XCTAssertEqual(try FrameDecoder.pixels(compressed, width: 16, height: 8, bytesPerRow: 64), data)
    }
    func testExpansionBeyondDeclaredSizeIsRejected() throws {
        let compressed = try (Data(repeating: 0, count: 1024 * 1024) as NSData).compressed(using: .lz4) as Data
        XCTAssertThrowsError(try FrameDecoder.pixels(compressed, width: 1, height: 1, bytesPerRow: 4))
    }
    func testInvalidDimensionsAndTruncatedFrameAreRejected() throws {
        let compressed = try (Data(repeating: 0, count: 4) as NSData).compressed(using: .lz4) as Data
        for width in [0, -1, 8193, Int.max] {
            XCTAssertThrowsError(try FrameDecoder.pixels(compressed, width: width, height: 1, bytesPerRow: 4))
        }
        XCTAssertThrowsError(try FrameDecoder.pixels(compressed, width: 2, height: 1, bytesPerRow: 8))
        XCTAssertThrowsError(try FrameDecoder.pixels(compressed, width: 8192, height: 8192, bytesPerRow: 33792))
        XCTAssertNil(FrameDecoder.image(Data("invalid image".utf8)))
    }
}
