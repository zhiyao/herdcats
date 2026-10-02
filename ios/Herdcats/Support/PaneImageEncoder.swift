import UIKit

/// Prepares a photo-library image for SFTP upload: normalize orientation,
/// strip location metadata (via UIImage re-encode), prefer PNG for screenshots
/// / transparency and JPEG for photos, and downscale large images.
enum PaneImageEncoder {
    private static let maxDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.82

    struct EncodedImage: Sendable {
        let data: Data
        let fileExtension: String
        let preview: UIImage
    }

    static func encode(_ image: UIImage, prefersPNG: Bool) -> EncodedImage? {
        let prepared = image.preparedForUpload(maxDimension: maxDimension)
        if prefersPNG || prepared.hasAlphaChannel,
           let png = prepared.pngData() {
            return EncodedImage(data: png, fileExtension: "png", preview: prepared)
        }
        if let jpeg = prepared.jpegData(compressionQuality: jpegQuality) {
            return EncodedImage(data: jpeg, fileExtension: "jpg", preview: prepared)
        }
        if let png = prepared.pngData() {
            return EncodedImage(data: png, fileExtension: "png", preview: prepared)
        }
        return nil
    }
}

private extension UIImage {
    func preparedForUpload(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        let targetSize: CGSize
        if longest > maxDimension, longest > 0 {
            let scaleRatio = maxDimension / longest
            targetSize = CGSize(
                width: max(1, (size.width * scaleRatio).rounded()),
                height: max(1, (size.height * scaleRatio).rounded())
            )
        } else if imageOrientation != .up {
            targetSize = size
        } else {
            return self
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = !hasAlphaChannel
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    var hasAlphaChannel: Bool {
        guard let cgImage else { return false }
        switch cgImage.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        default:
            return true
        }
    }
}
