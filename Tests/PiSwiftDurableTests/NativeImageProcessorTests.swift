import Foundation
import Testing
@testable import PiSwiftDurable
#if canImport(CryptoKit)
import CryptoKit
#endif

@Suite("Image processor values and EXIF")
struct ImageProcessorValueTests {
    @Test func defaultsAndBase64() {
        #expect(defaultImageLimits == ImageLimits(maxWidth: 2000, maxHeight: 2000, maxBytes: 4_718_592))
        // Expected SHA256 values come from Node Buffer.toString("base64") and node:crypto.
        let expected = [
            (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (1, "5ae215233ffde97b377345174ea52b64f6c4130369b714fc44aea521c84347a3"),
            (2, "5c27c6563150d11fa41759c2064759ee136a886ddd63ad88b5cfe1504278825b"),
            (3, "7193ed3c5cb459f1d87b732f8658b1eae5108267528f8f1445ce5d5de93b6516"),
            (4, "fd94703ecee1c02a1cf864091fbea09c0b960fed4fbb6c4a6554686dda2f9a26"),
            (5, "454e7c5ee25dfb37dd20c1233b45f332d3d67f4b1cb89a51726d8556dfb719fa"),
            (8191, "9e0075629726692ae23483d45d701c6b61b6c03c1351a085d4fcd1d7a277f728"),
            (8192, "da36256377f0ae69c5e7e8a11f8ebb0f39b3934b4c8c67ca02b57de2f047fd8c"),
            (8193, "dc0fdd9f2bfb4ac62182ca449bc9a536e2ab0108cfb2595f90c26722f11c94c6"),
            (10000, "4c038a7973f8e49de3a80685589efd026d7dfe9224dba4a03a9dabaea937f450"),
            (16385, "e0a13555c36b806132e0016f690dfa047a452d8a4b6e518ddb35c26b4ad334d0"),
            (3147295, "156aeef61926a517909692eb40c76411be8c38f4ce0aa286ccc372fea7d26c5f"),
        ]
        for (length, digest) in expected {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 * 37) }
            let encoded = toBase64(bytes)
            #if canImport(CryptoKit)
            let actual = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest)
            #endif
            #expect(encoded == Data(bytes).base64EncodedString())
            #expect(Data(base64Encoded: encoded) == Data(bytes))
            #expect(base64Length(length) == Double(encoded.utf8.count))
        }
        #expect(base64Length(Int64.max).isFinite)
        #expect(base64Length(Int64.max) > Double(Int64.max))
        #expect([0, 1, 2, 3, 4, 5].map { toBase64((0..<$0).map { UInt8($0 * 37) }) }
                == ["", "AA==", "ACU=", "ACVK", "ACVKbw==", "ACVKb5Q="])
    }

    @Test func jpegEXIFByteOrdersAndSegments() {
        for little in [false, true] {
            for orientation in 1...8 {
                let jpeg = withImageOrientation([0xff, 0xd8, 0xff, 0xd9], orientation, little: little, app0: true)
                #expect(exifOrientation(jpeg) == orientation)
            }
        }
        #expect(exifOrientation(withImageOrientation([0xff, 0xd8], 9)) == 1)
        #expect(exifOrientation([0xff, 0xd8, 0xff, 0xd9]) == 1)
        #expect(exifOrientation([]) == 1)
    }

    @Test func webpEXIFPrefixAndChunkPadding() {
        for prefixed in [false, true] {
            for little in [false, true] {
                #expect(exifOrientation(webpImageOrientation(6, prefixed: prefixed, little: little)) == 6)
            }
        }
    }

    @Test func truncatedAndInvalidEXIF() {
        let jpeg = withImageOrientation([0xff, 0xd8], 6)
        for count in 0..<(jpeg.count - 4) { #expect(exifOrientation(Array(jpeg.prefix(count))) == 1) }
        let webp = webpImageOrientation(8, prefixed: true, little: true)
        for count in 0..<(webp.count - 8) { #expect(exifOrientation(Array(webp.prefix(count))) == 1) }
        var badDirectory = jpeg
        badDirectory.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0xff])
        #expect(exifOrientation(badDirectory) == 1)
        #expect(exifOrientation([0xff, 0xd8, 0xff, 0xff, 0xff, 0xe0, 0, 0]) == 1)
    }
}

private func imageTIFF(_ orientation: Int, little: Bool) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 26)
    bytes[0] = little ? 0x49 : 0x4d
    bytes[1] = bytes[0]
    func put(_ value: Int, _ offset: Int, _ count: Int) {
        for index in 0..<count {
            let shift = (little ? index : count - 1 - index) * 8
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
    put(42, 2, 2)
    put(8, 4, 4)
    put(1, 8, 2)
    put(0x0112, 10, 2)
    put(3, 12, 2)
    put(1, 14, 4)
    put(orientation, 18, 2)
    return bytes
}

private func withImageOrientation(
    _ jpeg: [UInt8], _ orientation: Int, little: Bool = false, app0: Bool = false
) -> [UInt8] {
    let exif: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + imageTIFF(orientation, little: little)
    let app1: [UInt8] = [0xff, 0xe1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 0xff)] + exif
    let header: [UInt8] = app0 ? [0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0] : []
    return Array(jpeg.prefix(2)) + header + app1 + jpeg.dropFirst(2)
}

private func webpImageOrientation(_ orientation: Int, prefixed: Bool, little: Bool) -> [UInt8] {
    func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        Array(type.utf8) + [UInt8(data.count), 0, 0, 0] + data + (data.count % 2 == 1 ? [0] : [])
    }
    let prefix: [UInt8] = prefixed ? [0x45, 0x78, 0x69, 0x66, 0, 0] : []
    let body = Array("WEBP".utf8) + chunk("VP8 ", [1, 2, 3])
        + chunk("EXIF", prefix + imageTIFF(orientation, little: little))
    return Array("RIFF".utf8) + [UInt8(body.count), 0, 0, 0] + body
}

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

@Suite("Native image processor")
struct NativeImageProcessorTests {
    @Test func readsHeaderDimensionsForAllInlineFormats() throws {
        let expected = ImageDimensions(width: 7, height: 5)
        let png = try imageFixture(width: 7, height: 5)
        let jpeg = try imageFixture(width: 7, height: 5, jpeg: true)
        #expect(imageDimensions(png, mimeType: "image/png") == expected)
        #expect(imageDimensions(jpeg, mimeType: "image/jpeg") == expected)
        #expect(imageDimensions(withImageOrientation(jpeg, 6, app0: true), mimeType: "image/jpeg") == expected)
        var gif = Array(try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")))
        gif.replaceSubrange(6..<10, with: [0x2c, 0x01, 0xc8, 0x00])
        let large = ImageDimensions(width: 300, height: 200)
        #expect(imageDimensions(gif, mimeType: "image/gif") == large)
        func webp(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
                + Array(type.utf8) + [0, 0, 0, 0] + payload + [UInt8](repeating: 0, count: 16)
        }
        #expect(imageDimensions(webp("VP8 ", [0, 0, 0, 0x9d, 0x01, 0x2a, 0x2c, 0x01, 0xc8, 0]), mimeType: "image/webp") == large)
        let bits = 299 | (199 << 14)
        let lossless = [UInt8(0x2f)] + (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        #expect(imageDimensions(webp("VP8L", lossless), mimeType: "image/webp") == large)
        #expect(imageDimensions(webp("VP8X", [0, 0, 0, 0, 0x2b, 0x01, 0, 0xc7, 0, 0]), mimeType: "image/webp") == large)
        #expect(imageDimensions([0xff, 0xd8, 0xff], mimeType: "image/jpeg") == nil)
    }

    @Test func passesInlineFormatsThrough() async throws {
        let processor = NativeImageProcessor()
        let png = try imageFixture(width: 8, height: 6)
        let jpeg = try imageFixture(width: 8, height: 6, jpeg: true)
        let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let webp = try #require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        for (bytes, mime) in [(png, "image/png"), (jpeg, "image/jpeg"), (Array(gif), "image/gif"), (Array(webp), "image/webp")] {
            let result = try await processor.prepare(bytes: bytes, mimeType: mime, limits: defaultImageLimits)
            #expect(result == PreparedImage(data: toBase64(bytes), mimeType: mime))
            let prepared = try #require(result)
            let decoded = try #require(Data(base64Encoded: prepared.data))
            #expect(bytes == Array(decoded))
        }
    }

    @Test func acceptsExactByteAndDimensionLimits() async throws {
        let bytes = try imageFixture(width: 8, height: 6)
        let result = try await NativeImageProcessor().prepare(
            bytes: bytes, mimeType: "image/png",
            limits: ImageLimits(maxWidth: 8, maxHeight: 6, maxBytes: Int(base64Length(bytes.count)))
        )
        #expect(result?.data == toBase64(bytes))
        #expect(result?.resized == nil)
    }

    @Test func resizesAndKeepsOnePixel() async throws {
        let processor = NativeImageProcessor()
        for (width, height, targetWidth, targetHeight) in [(4000, 1000, 2000, 500), (6000, 2, 2000, 1), (2, 6000, 1, 2000)] {
            let result = try #require(await processor.prepare(
                bytes: imageFixture(width: width, height: height), mimeType: "image/png", limits: defaultImageLimits
            ))
            #expect(result.resized == ImageResize(
                from: ImageDimensions(width: width, height: height),
                to: ImageDimensions(width: targetWidth, height: targetHeight)
            ))
            let decoded = try decodePreparedImage(result)
            #expect(decoded.width == targetWidth)
            #expect(decoded.height == targetHeight)
            #expect(result.data.utf8.count <= defaultImageLimits.maxBytes)
        }
    }

    @Test func usesCustomLimitsAndRoundsDimensions() async throws {
        let result = try #require(await NativeImageProcessor().prepare(
            bytes: imageFixture(width: 13, height: 7), mimeType: "image/png",
            limits: ImageLimits(maxWidth: 6, maxHeight: 100)
        ))
        #expect(result.resized?.to == ImageDimensions(width: 6, height: 3))
    }

    @Test func convertsBMPToPNG() async throws {
        let result = try #require(await NativeImageProcessor().prepare(
            bytes: bmpImageFixture(width: 4, height: 4), mimeType: "image/bmp", limits: defaultImageLimits
        ))
        #expect(result.mimeType == "image/png")
        #expect(result.convertedFrom == "image/bmp")
        #expect(result.resized == nil)
        #expect(try decodePreparedImage(result).width == 4)
    }

    @Test func convertsLargePNGAndShrinksForBytes() async throws {
        let processor = NativeImageProcessor()
        let noisy = try imageFixture(width: 600, height: 600, noise: true)
        let converted = try #require(await processor.prepare(
            bytes: noisy, mimeType: "image/png", limits: ImageLimits(maxBytes: 600_000)
        ))
        #expect(converted.mimeType == "image/jpeg")
        #expect(converted.convertedFrom == "image/png")
        #expect(converted.resized == nil)
        let shrunk = try #require(await processor.prepare(
            bytes: noisy, mimeType: "image/png", limits: ImageLimits(maxBytes: 20_000)
        ))
        #expect(shrunk.data.utf8.count <= 20_000)
        #expect(shrunk.resized?.from == ImageDimensions(width: 600, height: 600))
        let resize = try #require(shrunk.resized)
        #expect(resize.to.width < 600)
        #expect(try decodePreparedImage(shrunk).width == shrunk.resized?.to.width)
    }

    @Test func returnsNilForInvalidImagesAndLimits() async throws {
        let processor = NativeImageProcessor()
        let valid = try imageFixture(width: 4, height: 4)
        for bytes in [[], [1, 2, 3], Array(valid.prefix(40))] as [[UInt8]] {
            #expect(try await processor.prepare(bytes: bytes, mimeType: "image/png", limits: defaultImageLimits) == nil)
        }
        for limits in [ImageLimits(maxBytes: 8), ImageLimits(maxWidth: 0), ImageLimits(maxHeight: -1), ImageLimits(maxBytes: 0)] {
            #expect(try await processor.prepare(bytes: valid, mimeType: "image/png", limits: limits) == nil)
        }
    }

    @Test(arguments: 1...8) func appliesEveryEXIFOrientation(_ orientation: Int) async throws {
        let blocks: [[UInt8]] = [
            [255, 0, 0], [0, 255, 0], [0, 0, 255],
            [255, 255, 255], [0, 0, 0], [255, 255, 0],
        ]
        let jpeg = try imageFixture(width: 48, height: 32, jpeg: true, blocks: blocks)
        let expected: [[Int]] = [
            [0, 1, 2, 3, 4, 5], [2, 1, 0, 5, 4, 3], [5, 4, 3, 2, 1, 0], [3, 4, 5, 0, 1, 2],
            [0, 3, 1, 4, 2, 5], [3, 0, 4, 1, 5, 2], [5, 2, 4, 1, 3, 0], [2, 5, 1, 4, 0, 3],
        ]
        for little in [false, true] {
            let result = try #require(await NativeImageProcessor().prepare(
                bytes: withImageOrientation(jpeg, orientation, little: little, app0: true),
                mimeType: "image/jpeg", limits: defaultImageLimits
            ))
            let image = try decodePreparedImage(result)
            #expect(image.width == (orientation < 5 ? 48 : 32))
            #expect(image.height == (orientation < 5 ? 32 : 48))
            #expect(result.mimeType == "image/jpeg")
            #expect(result.resized == nil)
            #expect(result.convertedFrom == nil)
            for index in 0..<6 {
                let x = (index % (image.width / 16)) * 16 + 8
                let y = (index / (image.width / 16)) * 16 + 8
                let at = (y * image.width + x) * 4
                let seen = image.pixels[at..<(at + 3)].map { $0 > 127 ? UInt8(255) : UInt8(0) }
                #expect(seen == blocks[expected[orientation - 1][index]])
            }
        }
    }

    @Test func resizeDimensionsUseUprightSource() async throws {
        let jpeg = try imageFixture(width: 60, height: 40, jpeg: true)
        let result = try #require(await NativeImageProcessor().prepare(
            bytes: withImageOrientation(jpeg, 6), mimeType: "image/jpeg",
            limits: ImageLimits(maxWidth: 20, maxHeight: 20)
        ))
        #expect(result.resized == ImageResize(
            from: ImageDimensions(width: 40, height: 60), to: ImageDimensions(width: 13, height: 20)
        ))
    }

    @Test func concurrentCallsKeepInputBytes() async throws {
        let processor = NativeImageProcessor()
        let bytes = try imageFixture(width: 40, height: 30)
        let copy = bytes
        let results = try await withThrowingTaskGroup(of: PreparedImage?.self) { group in
            for _ in 0..<12 {
                group.addTask { try await processor.prepare(bytes: bytes, mimeType: "image/png", limits: defaultImageLimits) }
            }
            var results: [PreparedImage?] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0?.data == toBase64(bytes) })
        #expect(bytes == copy)

        let bmp = bmpImageFixture(width: 4, height: 4)
        let wide = try imageFixture(width: 4000, height: 1000)
        let originalWide = wide
        async let converted = processor.prepare(bytes: bmp, mimeType: "image/bmp", limits: defaultImageLimits)
        async let resized = processor.prepare(bytes: wide, mimeType: "image/png", limits: defaultImageLimits)
        async let invalid = processor.prepare(bytes: [1, 2, 3], mimeType: "image/png", limits: defaultImageLimits)
        let (conversion, resize, failure) = try await (converted, resized, invalid)
        #expect(conversion?.mimeType == "image/png")
        #expect(resize?.resized?.to == ImageDimensions(width: 2000, height: 500))
        #expect(failure == nil)
        let repeated = try await processor.prepare(bytes: wide, mimeType: "image/png", limits: defaultImageLimits)
        #expect(resize == repeated)
        #expect(wide == originalWide)
    }

    @MainActor @Test func leavesMainActorFree() async throws {
        let bytes = try imageFixture(width: 1800, height: 1200, noise: true)
        let clock = ContinuousClock()
        let start = clock.now
        let work = Task { @MainActor in
            try await NativeImageProcessor().prepare(
                bytes: bytes, mimeType: "image/png", limits: ImageLimits(maxWidth: 500, maxBytes: 50_000)
            )
        }
        var ticks = 0
        var longest = Duration.zero
        while clock.now - start < .milliseconds(100) {
            let tick = clock.now
            try await Task.sleep(for: .milliseconds(5))
            longest = max(longest, clock.now - tick)
            ticks += 1
        }
        #expect(try await work.value != nil)
        #expect(ticks >= 3)
        #expect(longest < .milliseconds(100))
    }

    @Test func cancellationThrowsAndDoesNotAffectLaterCalls() async throws {
        let processor = NativeImageProcessor()
        let bytes = try imageFixture(width: 1800, height: 1200, noise: true)
        let work = Task {
            try await processor.prepare(bytes: bytes, mimeType: "image/png", limits: ImageLimits(maxBytes: 200))
        }
        try await Task.sleep(for: .milliseconds(10))
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("Image preparation did not throw on cancellation")
        } catch is CancellationError {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.prepare(bytes: [], mimeType: "image/png", limits: defaultImageLimits)
        }
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled caller did not throw")
        } catch is CancellationError {}
        #expect(try await processor.prepare(
            bytes: imageFixture(width: 2, height: 2), mimeType: "image/png", limits: defaultImageLimits
        ) != nil)
    }
}

private func imageFixture(
    width: Int, height: Int, jpeg: Bool = false, noise: Bool = false, blocks: [[UInt8]]? = nil
) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var seed: UInt32 = 1
    for y in 0..<height {
        for x in 0..<width {
            let at = (y * width + x) * 4
            for channel in 0..<3 {
                if noise {
                    seed = seed &* 1_103_515_245 &+ 12345
                    pixels[at + channel] = UInt8(truncatingIfNeeded: seed >> 24)
                } else if let blocks {
                    pixels[at + channel] = blocks[(y / 16) * 3 + x / 16][channel]
                } else {
                    pixels[at + channel] = channel == 0 ? 255 : 0
                }
            }
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return Array(data as Data)
}

private func decodePreparedImage(_ prepared: PreparedImage) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let data = try #require(Data(base64Encoded: prepared.data))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let context = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (image.width, image.height, Array(UnsafeBufferPointer(start: pixels, count: image.width * image.height * 4)))
}

private func bmpImageFixture(width: Int, height: Int) -> [UInt8] {
    let row = ((width * 3 + 3) / 4) * 4
    var bytes = [UInt8](repeating: 0, count: 54 + row * height)
    func put(_ value: Int, _ offset: Int, _ count: Int) {
        for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    bytes[0] = 0x42
    bytes[1] = 0x4d
    put(bytes.count, 2, 4)
    put(54, 10, 4)
    put(40, 14, 4)
    put(width, 18, 4)
    put(height, 22, 4)
    put(1, 26, 2)
    put(24, 28, 2)
    put(row * height, 34, 4)
    for y in 0..<height {
        for x in 0..<width { bytes[54 + y * row + x * 3 + 2] = 255 }
    }
    return bytes
}
#endif
