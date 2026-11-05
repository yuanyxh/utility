import Cocoa
import ImageIO

enum ImagePreviewError: Error {
    case tooLarge
    case unreadable
}

/// Read-only image preview. Decoding happens off the main thread and the longest
/// edge is capped, so large photos do not stall the window.
@MainActor
final class ImagePreviewView: NSView {
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "heic", "webp",
    ]
    private static let maxPixelSize = 4096

    private var maxBytes = 20 * 1024 * 1024

    private let imageView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.editorBackground.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder _: NSCoder) { nil }

    static func load(url: URL, maxBytes: Int) async -> Result<NSImage, ImagePreviewError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: decode(url: url, maxBytes: maxBytes))
            }
        }
    }

    func show(_ result: Result<NSImage, ImagePreviewError>, maxBytes: Int) {
        self.maxBytes = maxBytes
        switch result {
        case .success(let image):
            imageView.image = image
            imageView.isHidden = false
            messageLabel.isHidden = true
        case .failure(let error):
            imageView.image = nil
            imageView.isHidden = true
            messageLabel.stringValue = message(for: error)
            messageLabel.isHidden = false
        }
    }

    func clear() {
        imageView.image = nil
        imageView.isHidden = true
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
    }

    private func message(for error: ImagePreviewError) -> String {
        switch error {
        case .tooLarge:
            return L10n.Workspace.imageTooLarge(limit: maxBytes / 1024 / 1024)
        case .unreadable:
            return L10n.Workspace.imageUnreadable
        }
    }

    private func setup() {
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = VSTheme.secondaryText
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    private static func decode(url: URL, maxBytes: Int) -> Result<NSImage, ImagePreviewError> {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxBytes {
            return .failure(.tooLarge)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else {
            return .failure(.unreadable)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return .failure(.unreadable)
        }
        return .success(
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
        )
    }
}
