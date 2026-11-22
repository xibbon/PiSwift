import Foundation
import PiSwiftAI

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

/// Get the model's image limits. Use the default for each limit the model does not set.
public func imageLimits(_ model: Model?) -> ImageLimits {
    let resize = model?.inputLimits?.images?.resize
    return ImageLimits(
        maxWidth: resize?.maxWidth ?? defaultImageLimits.maxWidth,
        maxHeight: resize?.maxHeight ?? defaultImageLimits.maxHeight,
        maxBytes: resize?.maxBytes ?? defaultImageLimits.maxBytes
    )
}

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

/// Describe changes to the format and how to map coordinates to the original image.
func preparedNotes(_ image: PreparedImage) -> [String] {
    var notes: [String] = []
    if let from = image.convertedFrom {
        notes.append("Converted from \(from) to \(image.mimeType).")
    }
    if let resized = image.resized {
        let (from, to) = (resized.from, resized.to)
        let scale = imageScaleText(Double(from.width) / Double(to.width))
        notes.append("Resized from \(from.width)x\(from.height) to \(to.width)x\(to.height). Multiply coordinates by \(scale) to map them to the original.")
    }
    return notes
}

// Match JavaScript toFixed(2), which rounds exact half ties away from zero.
private func imageScaleText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    // The exact binary half ties at two decimal places are odd multiples of 1/8.
    let eighths = abs(value) * 8
    if eighths.truncatingRemainder(dividingBy: 2) == 1 {
        let wholeEighths = Int64(eighths)
        let cents = (wholeEighths % 8 * 100 + 4) / 8
        return "\(value < 0 ? "-" : "")\(wholeEighths / 8).\(cents)"
    }
    return String(format: "%.2f", value == 0 ? 0 : value)
}

let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

func toBase64(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
}

private enum InvalidBase64: String, Error, CustomStringConvertible {
    case invalidCharacter = "Invalid character"
    case invalidLength = "The string to be decoded is not correctly encoded."

    var description: String { rawValue }
}

/// Decode standard base64 with the same whitespace and padding rules as `atob`.
func fromBase64(_ data: String) throws -> [UInt8] {
    var normalized = Data(capacity: data.utf8.count)
    var padding = 0
    for byte in data.utf8 {
        switch byte {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20: // ASCII whitespace
            continue
        case 0x3D: // =
            padding += 1
            guard padding <= 2 else { throw InvalidBase64.invalidCharacter }
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F: // A-Z, a-z, 0-9, +, /
            guard padding == 0 else { throw InvalidBase64.invalidCharacter }
            normalized.append(byte)
        default:
            throw InvalidBase64.invalidCharacter
        }
    }

    let remainder = normalized.count % 4
    guard remainder != 1 else { throw InvalidBase64.invalidLength }
    let requiredPadding = remainder == 0 ? 0 : 4 - remainder
    guard padding == 0 || padding == requiredPadding else { throw InvalidBase64.invalidCharacter }
    for _ in 0..<requiredPadding { normalized.append(0x3D) }
    guard let decoded = Data(base64Encoded: normalized) else { throw InvalidBase64.invalidCharacter }
    return Array(decoded)
}

/// Use Double for the result so large file lengths do not overflow Int64.
func base64Length(_ byteLength: Int64) -> Double {
    ceil(Double(byteLength) / 3) * 4
}

func base64Length(_ byteLength: Int) -> Double {
    base64Length(Int64(byteLength))
}
