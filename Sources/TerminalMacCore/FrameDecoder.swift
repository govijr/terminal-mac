import Foundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Bounds untrusted guest frames before allocating their decoded representation.
public enum FrameDecoder {
    public static let maximumBytes = 256 * 1024 * 1024
    private static func valid(width: Int, height: Int, stride: Int) -> Bool {
        (1...8192).contains(width) && (1...8192).contains(height) &&
        (width * 4...width * 4 + 1024).contains(stride) && stride <= maximumBytes / height
    }
    public static func pixels(_ compressed: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard valid(width: width, height: height, stride: bytesPerRow) else { throw Failure("Invalid frame size") }
        let expected = bytesPerRow * height
        var output = Data()
        let filter = try OutputFilter(.decompress, using: .lz4, bufferCapacity: 65536) { chunk in
            guard let chunk else { return }
            guard chunk.count <= expected - output.count else { throw Failure("Decoded frame exceeded size limit") }
            output.append(chunk)
        }
        try filter.write(compressed)
        try filter.finalize()
        guard output.count == expected else { throw Failure("Decoded frame has incorrect size") }
        return output
    }
    public static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              valid(width: width, height: height, stride: width * 4),
              width <= maximumBytes / 8 / height else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
