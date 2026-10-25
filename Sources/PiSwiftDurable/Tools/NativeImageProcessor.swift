import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Prepare images with the system codecs, off the caller's actor.
///
/// This adapter uses ImageIO and CoreGraphics instead of Photon. The output bytes,
/// color conversion, resize filter, and JPEG quality scale can differ. A native
/// codec call finishes before it checks cancellation. Only the first frame is
/// re-encoded; an image that needs no change keeps all its original bytes.
public struct NativeImageProcessor: ImageProcessor, Sendable {
    /// Test seam: reports whether the codec work ran on the main thread.
    private let onWork: (@Sendable (_ onMainThread: Bool) -> Void)?

    public init() { onWork = nil }

    internal init(onWork: @escaping @Sendable (_ onMainThread: Bool) -> Void) { self.onWork = onWork }

    /// Use the installed ImageIO codecs to decode the input and produce PNG or JPEG
    /// when a change is required. Invalid limits or damaged image data return nil.
    public func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        try Task.checkCancellation()
        let onWork = onWork
        let work = Task.detached(priority: Task.currentPriority) {
            try Self.observedPrepare(bytes: bytes, mimeType: mimeType, limits: limits, onWork: onWork)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }

    private static func observedPrepare(
        bytes: [UInt8], mimeType: String, limits: ImageLimits, onWork: (@Sendable (Bool) -> Void)?
    ) throws -> PreparedImage? {
        onWork?(Thread.isMainThread)
        return try prepareImage(bytes: bytes, mimeType: mimeType, limits: limits)
    }

    private static func prepareImage(
        bytes: [UInt8], mimeType: String, limits: ImageLimits
    ) throws -> PreparedImage? {
        try Task.checkCancellation()
        guard limits.maxWidth > 0, limits.maxHeight > 0, limits.maxBytes > 0 else { return nil }
        let data = Data(bytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let decoded = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        try Task.checkCancellation()
        let orientation = exifOrientation(bytes)
        if inlineImageTypes.contains(mimeType), orientation == 1,
           decoded.width <= limits.maxWidth, decoded.height <= limits.maxHeight,
           base64Length(bytes.count) <= Double(limits.maxBytes) {
            return PreparedImage(data: toBase64(bytes), mimeType: mimeType)
        }
        guard let image = try uprightImage(decoded, orientation: orientation) else { return nil }
        let original = ImageDimensions(width: image.width, height: image.height)
        let scale = min(1, Double(limits.maxWidth) / Double(image.width),
                        Double(limits.maxHeight) / Double(image.height))
        var target = ImageDimensions(
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
        while true {
            try Task.checkCancellation()
            if let encoded = try encodeWithin(
                image, size: target, maxBytes: limits.maxBytes, jpegFirst: mimeType == "image/jpeg"
            ) {
                return PreparedImage(
                    data: encoded.data, mimeType: encoded.mimeType,
                    resized: target == original ? nil : ImageResize(from: original, to: target),
                    convertedFrom: encoded.mimeType == mimeType ? nil : mimeType
                )
            }
            if target.width == 1, target.height == 1 { return nil }
            target = ImageDimensions(
                width: max(1, Int(floor(Double(target.width) * 0.75))),
                height: max(1, Int(floor(Double(target.height) * 0.75)))
            )
        }
    }

    private static func encodeWithin(
        _ image: CGImage, size: ImageDimensions, maxBytes: Int, jpegFirst: Bool
    ) throws -> PreparedImage? {
        try Task.checkCancellation()
        let scaled: CGImage
        if image.width == size.width, image.height == size.height {
            scaled = image
        } else {
            guard let context = makeContext(width: size.width, height: size.height) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let result = context.makeImage() else { return nil }
            scaled = result
        }
        let png: (String, Double?) = ("image/png", nil)
        let jpegs: [(String, Double?)] = [0.80, 0.70, 0.55, 0.40].map { ("image/jpeg", $0) }
        let candidates = jpegFirst ? jpegs + [png] : [png] + jpegs
        for (mimeType, quality) in candidates {
            try Task.checkCancellation()
            let data = NSMutableData()
            let identifier = mimeType == "image/png" ? "public.png" : "public.jpeg"
            guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil) else {
                continue
            }
            let properties: CFDictionary? = quality.map {
                [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
            }
            CGImageDestinationAddImage(destination, scaled, properties)
            let complete = CGImageDestinationFinalize(destination)
            try Task.checkCancellation()
            if complete, base64Length(data.length) <= Double(maxBytes) {
                return PreparedImage(data: (data as Data).base64EncodedString(), mimeType: mimeType)
            }
        }
        return nil
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Move pixels exactly for EXIF orientations; do not interpolate a right-angle turn.
    private static func uprightImage(_ image: CGImage, orientation: Int) throws -> CGImage? {
        if orientation == 1 { return image }
        guard let source = makeContext(width: image.width, height: image.height) else { return nil }
        source.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let swapsDimensions = orientation >= 5
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard let output = makeContext(width: width, height: height),
              let sourceData = source.data, let outputData = output.data else { return nil }
        let input = sourceData.assumingMemoryBound(to: UInt8.self)
        let pixels = outputData.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            try Task.checkCancellation()
            for x in 0..<image.width {
                let outX: Int
                let outY: Int
                switch orientation {
                case 2: (outX, outY) = (image.width - 1 - x, y)
                case 3: (outX, outY) = (image.width - 1 - x, image.height - 1 - y)
                case 4: (outX, outY) = (x, image.height - 1 - y)
                case 5: (outX, outY) = (y, x)
                case 6: (outX, outY) = (image.height - 1 - y, x)
                case 7: (outX, outY) = (image.height - 1 - y, image.width - 1 - x)
                default: (outX, outY) = (y, image.width - 1 - x)
                }
                let from = y * source.bytesPerRow + x * 4
                let to = outY * output.bytesPerRow + outX * 4
                for channel in 0..<4 { pixels[to + channel] = input[from + channel] }
            }
        }
        return output.makeImage()
    }
}
#endif

/// Read JPEG or WebP EXIF orientation without an image decode.
func exifOrientation(_ bytes: [UInt8]) -> Int {
    guard let tiff = imageTIFFStart(bytes), tiff <= bytes.count - 8 else { return 1 }
    let little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49
    func u16(_ offset: Int) -> Int {
        little ? Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            : (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }
    func u32(_ offset: Int) -> Int {
        let first = UInt32(bytes[offset])
        let second = UInt32(bytes[offset + 1])
        let third = UInt32(bytes[offset + 2])
        let fourth = UInt32(bytes[offset + 3])
        return Int(little ? first | (second << 8) | (third << 16) | (fourth << 24)
                   : (first << 24) | (second << 16) | (third << 8) | fourth)
    }
    let directory = tiff + u32(tiff + 4)
    guard directory <= bytes.count - 2 else { return 1 }
    for index in 0..<u16(directory) {
        let entry = directory + 2 + index * 12
        guard entry <= bytes.count - 12 else { return 1 }
        if u16(entry) == 0x0112 {
            let value = u16(entry + 8)
            return (1...8).contains(value) ? value : 1
        }
    }
    return 1
}

private func imageTIFFStart(_ bytes: [UInt8]) -> Int? {
    func ascii(_ offset: Int, _ text: String) -> Bool {
        let expected = Array(text.utf8)
        guard offset <= bytes.count - expected.count else { return false }
        return bytes[offset..<(offset + expected.count)].elementsEqual(expected)
    }
    func exif(_ offset: Int) -> Bool {
        ascii(offset, "Exif") && offset <= bytes.count - 6 && bytes[offset + 4] == 0 && bytes[offset + 5] == 0
    }
    if bytes.starts(with: [0xff, 0xd8]) {
        var offset = 2
        while offset <= bytes.count - 4 {
            guard bytes[offset] == 0xff else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0xff { offset += 1; continue }
            if marker == 0xe1, exif(offset + 4) { return offset + 10 }
            offset += 2 + (Int(bytes[offset + 2]) << 8) + Int(bytes[offset + 3])
        }
    } else if ascii(0, "RIFF"), ascii(8, "WEBP") {
        var offset = 12
        while offset <= bytes.count - 8 {
            let size = Int(bytes[offset + 4]) | (Int(bytes[offset + 5]) << 8)
                | (Int(bytes[offset + 6]) << 16) | (Int(bytes[offset + 7]) << 24)
            if ascii(offset, "EXIF") { return exif(offset + 8) ? offset + 14 : offset + 8 }
            offset += 8 + size + size % 2
        }
    }
    return nil
}
