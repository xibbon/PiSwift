import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import PiSwiftCodingAgent

@Test func imageOrientationSurvivesANonExifAPP1Segment() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let original = data as Data
    let payload = Data("http://ns.adobe.com/xap/1.0/\0<metadata/>".utf8)
    let length = payload.count + 2
    var withXMP = Data(original.prefix(2))
    withXMP.append(contentsOf: [0xff, 0xe1, UInt8(length >> 8), UInt8(length & 0xff)])
    withXMP.append(payload)
    withXMP.append(original.dropFirst(2))
    let corrected = applyExifOrientation(withXMP)
    let source = try #require(CGImageSourceCreateWithData(corrected as CFData, nil))
    let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(result.width == 3)
    #expect(result.height == 2)
}
