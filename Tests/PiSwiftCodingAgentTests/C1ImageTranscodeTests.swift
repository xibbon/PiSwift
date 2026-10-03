import Foundation
import Testing
@testable import PiSwiftCodingAgent

@Suite struct C1ImageTranscodeTests {
    // The 2x1 JPEG fixture is from upstream image-processing.test.ts.
    private let jpeg2x1 = "/9j/4AAQSkZJRgABAgAAAQABAAD/wAARCAABAAIDAREAAhEBAxEB/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/9sAQwEDBAQFBAUJBQUJFA0LDRQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD4H8Q/8h/Uv+vmX/0M1/o1wJ/ySWU/9g1D/wBNRMOM/wDkp8z/AOv9b/05I//Z"

    private func app1(_ payload: Data) -> Data {
        let length = payload.count + 2
        var segment = Data([0xff, 0xe1, UInt8(length >> 8), UInt8(length & 0xff)])
        segment.append(payload)
        return segment
    }

    private func jpegWithXmpBeforeOrientation() throws -> String {
        let jpeg = try #require(Data(base64Encoded: jpeg2x1))
        let xmp = app1(Data("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8))
        var exif = Data("Exif\0\0".utf8)
        exif.append(contentsOf: [
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00
        ])
        var result = Data(jpeg.prefix(2))
        result.append(xmp)
        result.append(app1(exif))
        result.append(jpeg.dropFirst(2))
        return result.base64EncodedString()
    }

    private func expectOrientedPng(_ base64: String) throws {
        let png = try #require(Data(base64Encoded: base64))
        #expect(png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        try #require(png.count >= 24)
        let width = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(width == 1)
        #expect(height == 2)
    }

    #if canImport(AppKit)
    @Test func conversionAppliesExifAfterAnXmpAPP1Segment() throws {
        let result = try #require(convertToPng(try jpegWithXmpBeforeOrientation(), "image/jpeg"))
        #expect(result.mimeType == "image/png")
        try expectOrientedPng(result.data)
    }

    @Test func transcoderReturnsOrientedPngSynchronously() throws {
        let jpeg = try jpegWithXmpBeforeOrientation()
        let result = try #require(transcodeToPng(jpeg, "image/jpeg"))
        try expectOrientedPng(result)
        let detected = try #require(transcodeToPng(jpeg, "application/octet-stream"))
        try expectOrientedPng(detected)
    }
    #else
    @Test func transcoderReturnsNilWithoutAppKit() throws {
        #expect(transcodeToPng(try jpegWithXmpBeforeOrientation(), "image/jpeg") == nil)
    }
    #endif

    @Test func transcoderRejectsInvalidImageData() {
        let invalid = Data("not an image".utf8).base64EncodedString()
        #expect(transcodeToPng(invalid, "image/jpeg") == nil)
        #expect(transcodeToPng(invalid, "image/png") == nil)
        #expect(transcodeToPng("not base64", "image/jpeg") == nil)
    }
}
