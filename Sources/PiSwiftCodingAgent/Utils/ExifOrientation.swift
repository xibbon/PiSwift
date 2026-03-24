import Foundation
import ImageIO
import CoreGraphics

/// Read EXIF orientation from image data and return a corrected CGImage.
/// Returns the original data if no rotation needed or if reading fails.
public func applyExifOrientation(_ imageData: Data) -> Data {
    // 1. Create image source
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return imageData }

    // 2. Read orientation from properties
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let orientationValue = properties[kCGImagePropertyOrientation] as? UInt32,
          orientationValue > 1 else {
        return imageData // No rotation needed (orientation 1 = normal)
    }

    // 3. Create CGImage
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return imageData }

    // 4. Apply orientation transform
    let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
    guard let corrected = createOrientedImage(cgImage, orientation: orientation) else { return imageData }

    // 5. Re-encode to original format
    // Detect format from first bytes
    let isJPEG = imageData.count >= 2 && imageData[0] == 0xFF && imageData[1] == 0xD8
    let uti = isJPEG ? "public.jpeg" as CFString : "public.png" as CFString

    let mutableData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return imageData }
    // Write without the orientation tag (image is now correctly oriented)
    CGImageDestinationAddImage(dest, corrected, nil)
    guard CGImageDestinationFinalize(dest) else { return imageData }

    return mutableData as Data
}

private func createOrientedImage(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
    let width = image.width
    let height = image.height

    // Determine output size and transform
    let swapDimensions: Bool
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
        swapDimensions = true
    default:
        swapDimensions = false
    }

    let outputWidth = swapDimensions ? height : width
    let outputHeight = swapDimensions ? width : height

    guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: outputWidth,
              height: outputHeight,
              bitsPerComponent: image.bitsPerComponent,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: image.bitmapInfo.rawValue
          ) else { return nil }

    // Apply transform based on orientation
    switch orientation {
    case .up:
        // No transform needed
        break
    case .upMirrored:
        context.translateBy(x: CGFloat(outputWidth), y: 0)
        context.scaleBy(x: -1, y: 1)
    case .down:
        context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight))
        context.rotate(by: .pi)
    case .downMirrored:
        context.translateBy(x: 0, y: CGFloat(outputHeight))
        context.scaleBy(x: 1, y: -1)
    case .left:
        context.translateBy(x: 0, y: CGFloat(outputHeight))
        context.rotate(by: -.pi / 2)
    case .leftMirrored:
        context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight))
        context.scaleBy(x: -1, y: 1)
        context.rotate(by: -.pi / 2)
    case .right:
        context.translateBy(x: CGFloat(outputWidth), y: 0)
        context.rotate(by: .pi / 2)
    case .rightMirrored:
        context.scaleBy(x: -1, y: 1)
        context.rotate(by: .pi / 2)
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}
