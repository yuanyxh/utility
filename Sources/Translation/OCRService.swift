import Cocoa
import Vision

/// OCR 区域截图服务
public enum OCRService {
  fileprivate static var activeSelector: ScreenSelector?

  public static func selectAndRecognize(completion: @escaping (String?) -> Void) {
    DispatchQueue.main.async {
      let selector = ScreenSelector()
      activeSelector = selector
      selector.startCapture { image in
        activeSelector = nil
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

  public static func selectAndRecognize() async -> String? {
    return await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        let selector = ScreenSelector()
        activeSelector = selector
        selector.startCapture { image in
          activeSelector = nil
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

  private static func recognizeText(in cgImage: CGImage, completion: @escaping (String) -> Void) {
    let request = VNRecognizeTextRequest { request, error in
      guard error == nil else {
        completion("")
        return
      }
      let results = request.results as? [VNRecognizedTextObservation] ?? []
      let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
      completion(text)
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch { completion("") }
  }

  private static func recognizeText(in cgImage: CGImage) async -> String {
    return await withCheckedContinuation { continuation in
      let request = VNRecognizeTextRequest { request, error in
        guard error == nil else {
          continuation.resume(returning: "")
          return
        }
        let results = request.results as? [VNRecognizedTextObservation] ?? []
        let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        continuation.resume(returning: text)
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.recognitionLanguages = ["zh-Hans", "en-US"]
      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do { try handler.perform([request]) } catch { continuation.resume(returning: "") }
    }
  }
}

// MARK: - Screen Selector

private final class ScreenSelector: NSObject {
  private var window: NSWindow?
  private var completion: ((CGImage?) -> Void)?
  private var selectionView: SelectionOverlay?
  private var eventTap: CFMachPort?

  func startCapture(completion: @escaping (CGImage?) -> Void) {
    var completed = false
    let safeCompletion: (CGImage?) -> Void = { image in
      guard !completed else { return }
      completed = true
      completion(image)
    }
    self.completion = safeCompletion
    guard let screen = NSScreen.main else {
      completion(nil)
      return
    }

    let panel = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    panel.isOpaque = false
    panel.backgroundColor = NSColor.black.withAlphaComponent(0.2)
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.acceptsMouseMovedEvents = true
    panel.hidesOnDeactivate = false

    let overlay = SelectionOverlay(frame: screen.frame)
    overlay.onSelectionComplete = { [weak self] rect in
      guard let self = self else { return }
      self.captureAndReturn(rect: rect, screen: screen)
    }
    overlay.onCancel = { [weak self] in
      guard let self = self else { return }
      self.cleanup()
      self.completion?(nil)
      OCRService.activeSelector = nil
    }
    panel.contentView = overlay
    selectionView = overlay
    window = panel
    panel.makeKeyAndOrderFront(nil)

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard type == .keyDown,
        event.getIntegerValueField(.keyboardEventKeycode) == 53,
        let refcon = refcon
      else {
        return Unmanaged.passUnretained(event)
      }
      let selector = Unmanaged<ScreenSelector>.fromOpaque(refcon).takeUnretainedValue()
      selector.perform(#selector(ScreenSelector._handleEsc), with: nil, afterDelay: 0)
      return Unmanaged.passUnretained(event)
    }
    let ptr = Unmanaged.passRetained(self).toOpaque()
    if let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
      callback: callback,
      userInfo: ptr
    ) {
      eventTap = tap
      let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
      CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
    }
  }

  @objc private func _handleEsc() {
    releaseTap()
    cleanup()
    completion?(nil)
    OCRService.activeSelector = nil
  }

  /// 清理 eventTap + 释放 retained self
  private func releaseTap() {
    guard let tap = eventTap else { return }
    CFMachPortInvalidate(tap)
    eventTap = nil
    Unmanaged<ScreenSelector>.fromOpaque(Unmanaged.passUnretained(self).toOpaque()).release()
  }

  private func captureAndReturn(rect: CGRect, screen: NSScreen) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? CGDirectDisplayID
      else {
        DispatchQueue.main.async {
          self?.releaseTap()
          self?.cleanup()
          self?.completion?(nil)
          OCRService.activeSelector = nil
        }
        return
      }
      guard let fullImage = CGDisplayCreateImage(displayID) else {
        DispatchQueue.main.async {
          self?.releaseTap()
          self?.cleanup()
          self?.completion?(nil)
          OCRService.activeSelector = nil
        }
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
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.releaseTap()
        self.cleanup()
        self.completion?(cropped)
        OCRService.activeSelector = nil
      }
    }
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

  override var acceptsFirstResponder: Bool {
    true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }

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
    guard let start = startPoint else { return }
    let current = convert(event.locationInWindow, from: nil)
    let rect = NSRect(
      x: min(start.x, current.x), y: min(start.y, current.y),
      width: abs(current.x - start.x), height: abs(current.y - start.y)
    )
    guard rect.width > 5, rect.height > 5 else {
      startPoint = nil
      currentRect = nil
      needsDisplay = true
      return
    }
    currentRect = rect
    onSelectionComplete?(rect)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let rect = currentRect else { return }
    NSColor.selectedControlTextColor.withAlphaComponent(0.25).setFill()
    rect.fill(using: .destinationAtop)
    NSColor.darkGray.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath(rect: rect)
    path.lineWidth = 0.5
    path.stroke()
    let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
    let sizeAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.darkGray,
    ]
    sizeText.draw(at: NSPoint(x: rect.maxX + 8, y: rect.minY), withAttributes: sizeAttrs)
  }
}
