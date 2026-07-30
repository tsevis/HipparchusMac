import CoreGraphics
import Foundation
import HipparchusGeometry
import ImageIO

public enum TerrainTileError: Error, CustomStringConvertible {
    case notAnImage(bytes: Int)
    case unexpectedGeometry(width: Int, height: Int)
    case noTilesReadable
    case tileBudgetExceeded(needed: Int, limit: Int, zoom: Int)
    case coveredNothing

    public var description: String {
        switch self {
        case .notAnImage(let bytes):
            // A 404 from the tile bucket is an XML error document, not a PNG, and
            // saying "not a decodable image" for it is more use than a CG error code.
            return "elevation tile is not a decodable image (\(bytes) bytes)"
        case .unexpectedGeometry(let width, let height):
            return "unexpected elevation tile size \(width)x\(height)"
        case .noTilesReadable:
            return "no elevation tiles could be read for this area"
        case .tileBudgetExceeded(let needed, let limit, let zoom):
            return "area needs \(needed) elevation tiles at zoom \(zoom), over the \(limit) limit"
        case .coveredNothing:
            return "elevation tiles covered no part of the area"
        }
    }
}

/// Unpack terrarium-encoded PNG into metres.
///
/// Kickoff detail 3: `metres = R * 256 + G + B / 256 - 32768`, which covers the
/// whole range from ocean floor to summit at 1/256 m and carries bathymetry as
/// negative values in the same band as land.
///
/// **The decode has to be exact.** Terrarium is not a picture — the bytes *are*
/// the number. A colour transform that shifts a red channel by one produces a
/// 256 m elevation error, and gamma-correcting the blue channel produces noise on
/// every contour. So the bitmap context is built with:
///
/// - `sRGB` as the destination space, matching what an untagged PNG is assumed to
///   be, making the transform the identity;
/// - `.noneSkipLast`, so alpha is ignored rather than premultiplied — premultiply
///   would scale the elevation by the opacity;
/// - no interpolation, drawing 1:1 at the image's own pixel size.
///
/// `TerrariumDecodeTests` round-trips channel values chosen to expose any gamma
/// or matrix applied on the way through.
public func decodeTerrarium(_ data: Data) throws -> Field2D {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary)
    else {
        throw TerrainTileError.notAnImage(bytes: data.count)
    }

    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else {
        throw TerrainTileError.unexpectedGeometry(width: width, height: height)
    }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    let decoded: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard decoded else {
        throw TerrainTileError.unexpectedGeometry(width: width, height: height)
    }

    var values = ContiguousArray<Double>()
    values.reserveCapacity(width * height)
    for row in 0..<height {
        let base = row * bytesPerRow
        for column in 0..<width {
            let offset = base + column * bytesPerPixel
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            values.append(red * 256.0 + green + blue / 256.0 - 32768.0)
        }
    }
    return Field2D(rows: height, columns: width, values: values)
}

/// Encode metres back into terrarium RGB.
///
/// The inverse of the decoder, and only used by tests — the Python's test helper
/// does the same thing so a synthesised tile can stand in for the network. Kept
/// beside the decoder so the two cannot drift apart.
public func encodeTerrariumPNG(_ field: Field2D) -> Data? {
    let width = field.columns
    let height = field.rows
    guard width > 0, height > 0 else { return nil }

    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
    for row in 0..<height {
        let base = row * bytesPerRow
        for column in 0..<width {
            let raw = Swift.min(Swift.max(field[row, column] + 32768.0, 0.0), 65535.0)
            let red = (raw / 256.0).rounded(.down)
            let green = (raw - red * 256.0).rounded(.down)
            let blue = ((raw - red * 256.0 - green) * 256.0).rounded(.down)
            let offset = base + column * 4
            pixels[offset] = UInt8(red)
            pixels[offset + 1] = UInt8(green)
            pixels[offset + 2] = UInt8(blue)
            pixels[offset + 3] = 255
        }
    }

    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else {
        return nil
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
