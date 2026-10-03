import Foundation
import PiSwiftAI

public struct ImageResizeOptions: Sendable {
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxBytes: Int
    public var jpegQuality: Int

    public init(
        maxWidth: Int = 2000,
        maxHeight: Int = 2000,
        maxBytes: Int = Int(4.5 * 1024 * 1024),
        jpegQuality: Int = 80
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBytes = maxBytes
        self.jpegQuality = jpegQuality
    }

    public init(modelProfile: ModelImageResizeOptions?) {
        self.init(
            maxWidth: modelProfile?.maxWidth ?? 2000,
            maxHeight: modelProfile?.maxHeight ?? 2000,
            maxBytes: modelProfile?.maxBytes ?? Int(4.5 * 1024 * 1024),
            jpegQuality: modelProfile?.jpegQuality ?? 80
        )
    }
}

public struct ResizedImage: Sendable {
    public var data: String
    public var mimeType: String
    public var originalWidth: Int
    public var originalHeight: Int
    public var width: Int
    public var height: Int
    public var wasResized: Bool

    public init(
        data: String,
        mimeType: String,
        originalWidth: Int,
        originalHeight: Int,
        width: Int,
        height: Int,
        wasResized: Bool
    ) {
        self.data = data
        self.mimeType = mimeType
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.width = width
        self.height = height
        self.wasResized = wasResized
    }
}

private let defaultQualitySteps: [Int] = [85, 70, 55, 40]
private let defaultScaleSteps: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25]

private struct ImageDimensions: Sendable {
    let widthPx: Int
    let heightPx: Int
}

public func formatDimensionNote(_ result: ResizedImage) -> String? {
    guard result.wasResized, result.width > 0, result.originalWidth > 0 else { return nil }
    let scale = Double(result.originalWidth) / Double(result.width)
    let scaleString = String(format: "%.2f", scale)
    return "[Image: original \(result.originalWidth)x\(result.originalHeight), displayed at \(result.width)x\(result.height). Multiply coordinates by \(scaleString) to map to original image.]"
}

/// A failed resize can return the original bytes. Callers that add new images
/// to context must check the encoded payload and dimensions before using them.
public func imageFitsResizeLimits(_ result: ResizedImage, options: ImageResizeOptions) -> Bool {
    result.width > 0 && result.height > 0 &&
        result.width <= options.maxWidth && result.height <= options.maxHeight &&
        result.data.utf8.count < options.maxBytes
}

public func resizeImage(_ img: ImageContent, options: ImageResizeOptions = ImageResizeOptions()) -> ResizedImage {
    let mimeType = img.mimeType
    let base64Data = img.data
    guard let rawData = Data(base64Encoded: base64Data) else {
        return ResizedImage(
            data: base64Data,
            mimeType: mimeType,
            originalWidth: 0,
            originalHeight: 0,
            width: 0,
            height: 0,
            wasResized: false
        )
    }

    let parsedDims = getImageDimensions(base64Data, mimeType: mimeType)
    var originalWidth = parsedDims?.widthPx ?? 0
    var originalHeight = parsedDims?.heightPx ?? 0

    if originalWidth > 0, originalHeight > 0,
       originalWidth <= options.maxWidth,
       originalHeight <= options.maxHeight,
       base64Data.utf8.count < options.maxBytes {
        return ResizedImage(
            data: base64Data,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    #if canImport(AppKit)
    return resizeImageWithAppKit(
        rawData: rawData,
        originalBase64: base64Data,
        mimeType: mimeType,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        options: options
    )
    #else
    return ResizedImage(
        data: base64Data,
        mimeType: mimeType,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        width: originalWidth,
        height: originalHeight,
        wasResized: false
    )
    #endif
}

public func convertToPng(_ base64Data: String, _ mimeType: String) -> ImageContent? {
    if mimeType == "image/png" {
        return ImageContent(data: base64Data, mimeType: mimeType)
    }
    guard let rawData = Data(base64Encoded: base64Data) else { return nil }
    #if canImport(AppKit)
    if let converted = convertImageToPng(rawData) {
        return ImageContent(data: converted.base64EncodedString(), mimeType: "image/png")
    }
    #endif
    return nil
}

/// Convert image data to base64 PNG data and apply EXIF orientation.
/// Returns nil for invalid image data or on platforms without AppKit.
public func transcodeToPng(_ base64Data: String, _ mimeType: String) -> String? {
    #if canImport(AppKit)
    guard let rawData = Data(base64Encoded: base64Data),
          let converted = convertImageToPng(rawData) else { return nil }
    return converted.base64EncodedString()
    #else
    return nil
    #endif
}

private func getPngDimensions(_ base64Data: String) -> ImageDimensions? {
    guard let data = Data(base64Encoded: base64Data), data.count >= 24 else {
        return nil
    }
    if data.prefix(8) != Data([137, 80, 78, 71, 13, 10, 26, 10]) {
        return nil
    }
    let width = data.readUInt32BE(at: 16)
    let height = data.readUInt32BE(at: 20)
    return ImageDimensions(widthPx: Int(width), heightPx: Int(height))
}

private func getGifDimensions(_ base64Data: String) -> ImageDimensions? {
    guard let data = Data(base64Encoded: base64Data), data.count >= 10 else {
        return nil
    }
    let header = String(decoding: data.prefix(6), as: UTF8.self)
    if header != "GIF87a" && header != "GIF89a" {
        return nil
    }
    let width = data.readUInt16LE(at: 6)
    let height = data.readUInt16LE(at: 8)
    return ImageDimensions(widthPx: Int(width), heightPx: Int(height))
}

private func getJpegDimensions(_ base64Data: String) -> ImageDimensions? {
    guard let data = Data(base64Encoded: base64Data), data.count >= 4 else {
        return nil
    }
    if data[0] != 0xFF || data[1] != 0xD8 {
        return nil
    }
    var offset = 2
    while offset + 9 < data.count {
        if data[offset] != 0xFF {
            offset += 1
            continue
        }
        let marker = data[offset + 1]
        if marker == 0xC0 || marker == 0xC2 {
            let height = data.readUInt16BE(at: offset + 5)
            let width = data.readUInt16BE(at: offset + 7)
            return ImageDimensions(widthPx: Int(width), heightPx: Int(height))
        } else if marker == 0xDA {
            break
        } else {
            let segmentLength = data.readUInt16BE(at: offset + 2)
            if segmentLength < 2 {
                break
            }
            offset += Int(segmentLength) + 2
        }
    }
    return nil
}

private func getWebpDimensions(_ base64Data: String) -> ImageDimensions? {
    guard let data = Data(base64Encoded: base64Data), data.count >= 30 else {
        return nil
    }
    let riff = String(decoding: data.prefix(4), as: UTF8.self)
    let webp = String(decoding: data.subdata(in: 8..<12), as: UTF8.self)
    if riff != "RIFF" || webp != "WEBP" {
        return nil
    }
    let chunk = String(decoding: data.subdata(in: 12..<16), as: UTF8.self)
    if chunk == "VP8 " {
        guard data.count >= 30 else { return nil }
        let width = data.readUInt16LE(at: 26) & 0x3FFF
        let height = data.readUInt16LE(at: 28) & 0x3FFF
        return ImageDimensions(widthPx: Int(width), heightPx: Int(height))
    } else if chunk == "VP8L" {
        guard data.count >= 25 else { return nil }
        let bits = data.readUInt32LE(at: 21)
        let width = Int(bits & 0x3FFF) + 1
        let height = Int((bits >> 14) & 0x3FFF) + 1
        return ImageDimensions(widthPx: width, heightPx: height)
    } else if chunk == "VP8X" {
        guard data.count >= 30 else { return nil }
        let width = Int(data[24] | (data[25] << 8) | (data[26] << 16)) + 1
        let height = Int(data[27] | (data[28] << 8) | (data[29] << 16)) + 1
        return ImageDimensions(widthPx: width, heightPx: height)
    }
    return nil
}

private func getImageDimensions(_ base64Data: String, mimeType: String) -> ImageDimensions? {
    switch mimeType {
    case "image/png":
        return getPngDimensions(base64Data)
    case "image/jpeg":
        return getJpegDimensions(base64Data)
    case "image/gif":
        return getGifDimensions(base64Data)
    case "image/webp":
        return getWebpDimensions(base64Data)
    default:
        return nil
    }
}

#if canImport(AppKit)
import AppKit

private func resizeImageWithAppKit(
    rawData: Data,
    originalBase64: String,
    mimeType: String,
    originalWidth: Int,
    originalHeight: Int,
    options: ImageResizeOptions
) -> ResizedImage {
    guard let image = NSImage(data: rawData) else {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    var width = originalWidth
    var height = originalHeight
    if width == 0 || height == 0 {
        if let rep = NSBitmapImageRep(data: rawData) {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        } else {
            width = Int(image.size.width)
            height = Int(image.size.height)
        }
    }

    if width <= 0 || height <= 0 {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    let originalSize = originalBase64.utf8.count
    if width <= options.maxWidth, height <= options.maxHeight, originalSize < options.maxBytes {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: width,
            originalHeight: height,
            width: width,
            height: height,
            wasResized: false
        )
    }

    let target = scaleToFit(width: width, height: height, maxWidth: options.maxWidth, maxHeight: options.maxHeight)

    let qualitySteps = defaultQualitySteps
    let scaleSteps = defaultScaleSteps

    var bestData: Data?
    var bestMimeType = mimeType
    var finalWidth = target.width
    var finalHeight = target.height

    func tryEncode(width: Int, height: Int, jpegQuality: Int) -> (Data, String)? {
        guard let rep = makeBitmapRep(image: image, width: width, height: height) else { return nil }
        return encodeBestFormat(rep: rep, jpegQuality: jpegQuality)
    }

    if let encoded = tryEncode(width: target.width, height: target.height, jpegQuality: options.jpegQuality) {
        bestData = encoded.0
        bestMimeType = encoded.1
        if encoded.0.base64EncodedString().utf8.count < options.maxBytes {
            return ResizedImage(
                data: encoded.0.base64EncodedString(),
                mimeType: encoded.1,
                originalWidth: width,
                originalHeight: height,
                width: target.width,
                height: target.height,
                wasResized: true
            )
        }
    }

    for quality in qualitySteps {
        if let encoded = tryEncode(width: target.width, height: target.height, jpegQuality: quality) {
            bestData = encoded.0
            bestMimeType = encoded.1
            if encoded.0.base64EncodedString().utf8.count < options.maxBytes {
                return ResizedImage(
                    data: encoded.0.base64EncodedString(),
                    mimeType: encoded.1,
                    originalWidth: width,
                    originalHeight: height,
                    width: target.width,
                    height: target.height,
                    wasResized: true
                )
            }
        }
    }

    for scale in scaleSteps {
        finalWidth = max(1, Int(Double(target.width) * scale))
        finalHeight = max(1, Int(Double(target.height) * scale))
        if finalWidth < 100 || finalHeight < 100 {
            break
        }
        for quality in qualitySteps {
            if let encoded = tryEncode(width: finalWidth, height: finalHeight, jpegQuality: quality) {
                bestData = encoded.0
                bestMimeType = encoded.1
                if encoded.0.base64EncodedString().utf8.count < options.maxBytes {
                    return ResizedImage(
                        data: encoded.0.base64EncodedString(),
                        mimeType: encoded.1,
                        originalWidth: width,
                        originalHeight: height,
                        width: finalWidth,
                        height: finalHeight,
                        wasResized: true
                    )
                }
            }
        }
    }

    if let bestData {
        return ResizedImage(
            data: bestData.base64EncodedString(),
            mimeType: bestMimeType,
            originalWidth: width,
            originalHeight: height,
            width: finalWidth,
            height: finalHeight,
            wasResized: true
        )
    }

    return ResizedImage(
        data: originalBase64,
        mimeType: mimeType,
        originalWidth: width,
        originalHeight: height,
        width: width,
        height: height,
        wasResized: false
    )
}

private func scaleToFit(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
    var targetWidth = width
    var targetHeight = height
    if targetWidth > maxWidth {
        targetHeight = Int(Double(targetHeight) * Double(maxWidth) / Double(targetWidth))
        targetWidth = maxWidth
    }
    if targetHeight > maxHeight {
        targetWidth = Int(Double(targetWidth) * Double(maxHeight) / Double(targetHeight))
        targetHeight = maxHeight
    }
    return (max(1, targetWidth), max(1, targetHeight))
}

private func makeBitmapRep(image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
    let size = NSSize(width: width, height: height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep else { return nil }
    image.size = size
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func encodeBestFormat(rep: NSBitmapImageRep, jpegQuality: Int) -> (Data, String)? {
    let pngData = rep.representation(using: .png, properties: [:])
    let quality = max(0.0, min(1.0, Double(jpegQuality) / 100.0))
    let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])

    switch (pngData, jpegData) {
    case let (png?, jpeg?):
        if png.count <= jpeg.count {
            return (png, "image/png")
        }
        return (jpeg, "image/jpeg")
    case let (png?, nil):
        return (png, "image/png")
    case let (nil, jpeg?):
        return (jpeg, "image/jpeg")
    default:
        return nil
    }
}

private func convertImageToPng(_ rawData: Data) -> Data? {
    let orientedData = applyExifOrientation(rawData)
    if let rep = NSBitmapImageRep(data: orientedData) {
        return rep.representation(using: .png, properties: [:])
    }
    guard let image = NSImage(data: orientedData),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
}
#endif

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        let high = UInt16(self[offset]) << 8
        let low = UInt16(self[offset + 1])
        return high | low
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        let low = UInt16(self[offset])
        let high = UInt16(self[offset + 1]) << 8
        return high | low
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset]) << 24
        let b1 = UInt32(self[offset + 1]) << 16
        let b2 = UInt32(self[offset + 2]) << 8
        let b3 = UInt32(self[offset + 3])
        return b0 | b1 | b2 | b3
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
