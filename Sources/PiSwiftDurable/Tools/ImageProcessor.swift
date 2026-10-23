import Foundation

/// Limits for an image sent to a model. The byte limit applies to base64 data.
public struct ImageLimits: Sendable, Equatable {
    /// Maximum width in pixels.
    public var maxWidth: Int
    /// Maximum height in pixels.
    public var maxHeight: Int
    /// Maximum number of bytes in the base64 string.
    public var maxBytes: Int

    public init(maxWidth: Int = 2000, maxHeight: Int = 2000, maxBytes: Int = 4_718_592) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBytes = maxBytes
    }
}

/// The coding agent's default image limits: 2000 pixels per side and 4.5 MiB of base64.
public let defaultImageLimits = ImageLimits()

/// Image width and height in pixels.
public struct ImageDimensions: Sendable, Equatable {
    /// Width in pixels.
    public var width: Int
    /// Height in pixels.
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Dimensions before and after a resize. The source dimensions are upright.
public struct ImageResize: Sendable, Equatable {
    /// Upright dimensions before the resize.
    public var from: ImageDimensions
    /// Dimensions after the resize.
    public var to: ImageDimensions

    public init(from: ImageDimensions, to: ImageDimensions) {
        self.from = from
        self.to = to
    }
}

/// An image in a supported format, within the limits, as base64 data.
public struct PreparedImage: Sendable, Equatable {
    /// Standard base64 image data.
    public var data: String
    /// MIME type of the prepared data.
    public var mimeType: String
    /// Set only when the upright dimensions changed.
    public var resized: ImageResize?
    /// Original MIME type, set only when the output MIME type changed.
    public var convertedFrom: String?

    public init(data: String, mimeType: String, resized: ImageResize? = nil, convertedFrom: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.resized = resized
        self.convertedFrom = convertedFrom
    }
}

/// Decode, orient, resize, and encode images for model input.
public protocol ImageProcessor: Sendable {
    /// Return nil if the image cannot be decoded or made to fit. Cancellation throws.
    func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage?
}

let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

func toBase64(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
}

/// Use Double for the result so large file lengths do not overflow Int64.
func base64Length(_ byteLength: Int64) -> Double {
    ceil(Double(byteLength) / 3) * 4
}

func base64Length(_ byteLength: Int) -> Double {
    base64Length(Int64(byteLength))
}
