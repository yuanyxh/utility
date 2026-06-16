import Cocoa
import Vision

/// OCR 区域截图服务
/// 用户拖拽框选屏幕区域，esc 取消，识别后返回文本
public final class OCRService {
    /// 启动区域选择 + OCR 识别（回调方式，兼容 Carbon 上下文）
    public static func selectAndRecognize(completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let selector = ScreenSelector()
            selector.startCapture { image in
                guard let image = image else {
                    completion(nil)
                    return
                }
                recognizeText(in: image) { text in
                    completion(text)
                }
            }
        }
    }

    /// async/await 版本
    public static func selectAndRecognize() async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let selector = ScreenSelector()
                selector.startCapture { image in
                    guard let image = image else {
                        continuation.resume(returning: nil)
                        return
                    }
                    Task {
                        let text = await recognizeText(in: image)
                        continuation.resume(returning: text)
                    }
                }
            }
        }
    }

    /// 对 CGImage 进行 OCR 文字识别
    private static func recognizeText(in cgImage: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil else {
                completion("")
                return
            }
            let results = request.results as? [VNRecognizedTextObservation] ?? []
            let text = results
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            completion(text)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            completion("")
        }
    }

    private static func recognizeText(in cgImage: CGImage) async -> String {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else {
                    continuation.resume(returning: "")
                    return
                }
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                let text = results
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}

// MARK: - Screen Selector (透明覆盖层，拖拽框选)

private final class ScreenSelector: NSObject {
    private var window: NSWindow?
    private var completion: ((CGImage?) -> Void)?
    private var selectionView: SelectionOverlay?

    func startCapture(completion: @escaping (CGImage?) -> Void) {
        self.completion = completion
        guard let screen = NSScreen.main else {
            completion(nil)
            return
        }

        let panel = NSPanel(contentRect: screen.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true

        let overlay = SelectionOverlay(frame: screen.frame)
        overlay.onSelectionComplete = { [weak self] rect in
            self?.captureAndReturn(rect: rect, screen: screen)
        }
        overlay.onCancel = { [weak self] in
            self?.cleanup()
            self?.completion?(nil)
        }
        panel.contentView = overlay
        self.selectionView = overlay
        self.window = panel

        panel.makeKeyAndOrderFront(nil)
    }

    private func captureAndReturn(rect: CGRect, screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            completion?(nil)
            cleanup()
            return
        }

        guard let fullImage = CGDisplayCreateImage(displayID) else {
            completion?(nil)
            cleanup()
            return
        }

        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        let cropRect = CGRect(
            x: rect.minX * scale,
            y: (screenFrame.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        let cropped = fullImage.cropping(to: cropRect)
        cleanup()
        completion?(cropped)
    }

    private func cleanup() {
        window?.orderOut(nil)
        window = nil
        selectionView = nil
    }
}

// MARK: - Selection Overlay View

private final class SelectionOverlay: NSView {
    var onSelectionComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    private var trackingRect: NSRect?

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 5, rect.height > 5 else {
            currentRect = nil
            needsDisplay = true
            return
        }
        onSelectionComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            onCancel?()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let rect = currentRect else {
            // 提示文字
            let text = "拖拽选择区域 · Esc 取消"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.white
            ]
            text.draw(at: NSPoint(x: bounds.midX - 80, y: bounds.midY + 100),
                      withAttributes: attrs)
            return
        }

        // 绘制选择框
        NSColor.selectedControlTextColor.withAlphaComponent(0.25).setFill()
        rect.fill(using: .destinationAtop)

        NSColor.white.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        // 尺寸标注
        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        sizeText.draw(at: NSPoint(x: rect.maxX + 8, y: rect.minY), withAttributes: sizeAttrs)
    }
}
