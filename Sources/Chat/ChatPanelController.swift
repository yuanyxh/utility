import Cocoa

// MARK: - Custom NSPanel

private final class ChatPanel: NSPanel {
  weak var controller: ChatPanelController?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if flags == .command {
      switch event.keyCode {
      case 8:  // c
        if let tv = firstResponder as? NSTextView {
          tv.copy(nil)
          return true
        }
      case 7:  // x
        if let tv = firstResponder as? NSTextView, tv.isEditable {
          tv.cut(nil)
          return true
        }
      case 9:  // v
        if let tv = firstResponder as? NSTextView, tv.isEditable {
          tv.paste(nil)
          return true
        }
      case 0:  // a
        if let tv = firstResponder as? NSTextView {
          tv.selectAll(nil)
          return true
        }
      default: break
      }
    }

    return super.performKeyEquivalent(with: event)
  }
}

// MARK: - Panel Controller

public final class ChatPanelController: NSWindowController {
  private let inputView = ScrolledInputTextView(style: InputViewStyle(
    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
    textContainerInset: NSSize(width: 6, height: 8),
    showsVerticalScroller: false
  ))

  private let output = ScrolledInputTextView(style: InputViewStyle(
    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
    textColor: .textColor,
    textContainerInset: NSSize(width: 8, height: 8),
    isEditable: false,
    showsVerticalScroller: true
  ))

  private let divider: NSBox = {
    let b = NSBox()
    b.boxType = .separator
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isHidden = true
    return b
  }()

  private let loadingIndicator: LoadingSpinner = {
    let p = LoadingSpinner()
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
  }()

  private var accumulatedOutput = ""
  private var isStreaming = false
  private var chatSeq: UInt = 0
  private var currentRuleProcess: Process?
  private let inputHeight: CGFloat = 3 * 16 + 16 + 2
  private let panelBaseHeight: CGFloat = 12 + (3 * 16 + 16 + 2) + 12
  private let extraSpacing: CGFloat = 20  // divider + spacing

  private static let chatBgColor = NSColor(
    calibratedRed: 0xC5 / 0xFF, green: 0xC2 / 0xFF, blue: 0xC1 / 0xFF, alpha: 1.0
  )

  // MARK: - Init

  public init() {
    let panel = ChatPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 90),
      styleMask: [.nonactivatingPanel, .borderless, .resizable],
      backing: .buffered, defer: false
    )
    panel.level = NSWindow.Level.floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    super.init(window: panel)
    panel.controller = self

    setupUI()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  // MARK: - UI

  private func setupUI() {
    guard let window = window else { return }
    let content = window.contentView!
    content.wantsLayer = true
    content.layer?.cornerRadius = 12
    content.layer?.masksToBounds = true
    content.layer?.backgroundColor = Self.chatBgColor.withAlphaComponent(0.85).cgColor

    output.minHeight = 120
    output.translatesAutoresizingMaskIntoConstraints = false
    output.isHidden = true

    inputView.translatesAutoresizingMaskIntoConstraints = false

    content.addSubview(inputView)
    content.addSubview(loadingIndicator)
    content.addSubview(divider)
    content.addSubview(output)

    let panelW: CGFloat = 560
    let panelH: CGFloat = panelBaseHeight

    NSLayoutConstraint.activate([
      inputView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      inputView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      inputView.trailingAnchor.constraint(
        equalTo: loadingIndicator.leadingAnchor, constant: -4),
      inputView.heightAnchor.constraint(equalToConstant: inputHeight),

      loadingIndicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
      loadingIndicator.centerYAnchor.constraint(equalTo: inputView.centerYAnchor),

      divider.topAnchor.constraint(equalTo: inputView.bottomAnchor, constant: 8),
      divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

      output.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
      output.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      output.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
    ])

    var frame = window.frame
    frame.size.height = max(frame.size.height, panelH)
    window.setFrame(frame, display: false)

    window.setContentSize(NSSize(width: panelW, height: panelH))
  }

  // MARK: - Property

  public var isPanelVisible: Bool {
    window?.isVisible ?? false
  }

  var hasOutput: Bool {
    !accumulatedOutput.isEmpty
  }

  // MARK: - Show / Close

  public func show() {
    
    if hasOutput {
      output.maxHeight = availableOutputHeight()
      growPanelIfNeeded()
    } else {
      positionPanel()
    }
    window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    // 聚焦输入框
    window?.makeFirstResponder(inputView.textView)
  }

  public override func close() {
    EventBus.shared.publish(PanelEvent.requestClose, payload: self)
  }

  private func positionPanel() {
    guard let screen = window?.screen ?? NSScreen.main else { return }
    let panelSize = window?.frame.size ?? NSSize(width: 560, height: panelBaseHeight)
    let origin = WindowPositioning.screenCenter(
      windowSize: panelSize, offsetFraction: 0.2, screen: screen
    )
    window?.setFrameOrigin(origin)
  }

  // MARK: - Chat

  fileprivate func triggerChat() {
    if isStreaming {
      AIChatService.shared.cancel()
      currentRuleProcess?.terminate()
      currentRuleProcess = nil
    }
    output.clear()
    accumulatedOutput = ""
    hideOutput()
    startChat()
  }

  private func startChat() {
    let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    if let (rule, content) = matchAtRule(text: text) {
      executeAtRule(rule: rule, content: content)
      return
    }

    chatSeq += 1
    let seq = chatSeq
    isStreaming = true
    loadingIndicator.startAnimation(nil)
    AIChatService.shared.chat(
      messages: [.init(role: "user", content: text)],
      onToken: { [weak self] token in
        DispatchQueue.main.async {
          guard let self = self, seq == self.chatSeq else { return }
          if self.accumulatedOutput.isEmpty { self.showOutput() }
          self.accumulatedOutput += token
          self.output.string = self.accumulatedOutput
          self.output.scroll(to: .bottom)
          self.growPanelIfNeeded()
        }
      },
      onComplete: { [weak self] result in
        DispatchQueue.main.async {
          guard let self = self, seq == self.chatSeq else { return }
          self.isStreaming = false
          self.loadingIndicator.stopAnimation(nil)
          if case .failure(let error) = result {
            let errorMsg = "\n\n⚠️ \(error.localizedDescription)"
            let attrs: [NSAttributedString.Key: Any] = [
              .foregroundColor: NSColor.systemRed,
              .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            ]
            self.output.append(errorMsg, attributes: attrs)
            self.output.scroll(to: .bottom)
            self.growPanelIfNeeded()
            if self.accumulatedOutput.isEmpty {
              self.showOutput()
              self.accumulatedOutput = errorMsg
            }
          } else if !self.isPanelVisible {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
              title: L10n.Menu.chatCompleted, body: ""))
          }
        }
      }
    )
  }

  // MARK: - @ Rule

  private func matchAtRule(text: String) -> (rule: ChatAtRuleConfig, content: String)? {
    guard text.hasPrefix("@") else { return nil }
    let afterAt = text.index(after: text.startIndex)
    guard let spaceIdx = text[afterAt...].firstIndex(of: " ") else {
      let name = String(text[afterAt...])
      guard let rule = ConfigManager.shared.config.chat.atRules.first(where: { $0.name == name })
      else { return nil }
      return (rule, "")
    }
    let name = String(text[afterAt..<spaceIdx])
    let content = String(text[text.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
    guard let rule = ConfigManager.shared.config.chat.atRules.first(where: { $0.name == name })
    else { return nil }
    return (rule, content)
  }

  private func executeAtRule(rule: ChatAtRuleConfig, content: String) {
    let command = rule.command.replacingOccurrences(of: "{content}", with: content)
    chatSeq += 1
    let seq = chatSeq
    isStreaming = true
    output.clear()
    accumulatedOutput = ""
    loadingIndicator.startAnimation(nil)

    currentRuleProcess = TaskExecutor.execute(.sh(command),
      onOutput: { [weak self] chunk in
        guard let self = self, seq == self.chatSeq else { return }
        if self.accumulatedOutput.isEmpty { self.showOutput() }
        self.accumulatedOutput += chunk
        self.output.string = self.accumulatedOutput
        self.output.scroll(to: .bottom)
        self.growPanelIfNeeded()
      },
      onComplete: { [weak self] result in
        guard let self = self, seq == self.chatSeq else { return }
        self.currentRuleProcess = nil
        self.isStreaming = false
        self.loadingIndicator.stopAnimation(nil)
        if self.accumulatedOutput.isEmpty { self.showOutput() }
        if !result.success {
          let errorMsg: String
          if !result.error.isEmpty {
            errorMsg = result.output.isEmpty
              ? result.error
              : "\n\n⚠️ \(result.error)"
          } else {
            errorMsg = "\n\n⚠️ exit code != 0"
          }
          let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
          ]
          self.output.append(errorMsg, attributes: attrs)
          self.output.scroll(to: .bottom)
          self.growPanelIfNeeded()
        } else if !self.isPanelVisible {
          EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
              title: L10n.Menu.chatCompleted, body: ""))
        }
      }
    )
  }

  // MARK: - Output & Panel sizing

  private func showOutput() {
    divider.isHidden = false
    output.isHidden = false
    output.maxHeight = availableOutputHeight()
    growPanelIfNeeded()
  }

  private func availableOutputHeight() -> CGFloat {
    let maxPanelH = availableHeight()
    return max(120, maxPanelH - panelBaseHeight - extraSpacing)
  }

  private func growPanelIfNeeded() {
    guard let window = window, output.maxHeight != nil else { return }
    output.layoutSubtreeIfNeeded()
    let outputH = output.frame.height
    let newH = min(panelBaseHeight + outputH + extraSpacing, availableHeight())
    let currentH = window.frame.size.height
    if abs(newH - currentH) < 2 { return }
    var frame = window.frame
    frame.size.height = newH
    frame.origin.y -= (newH - currentH)
    window.setFrame(frame, display: true, animate: false)
  }

  private func availableHeight() -> CGFloat {
    guard let window = window, let screen = window.screen ?? NSScreen.main else { return 0 }
    let panelTop = window.frame.maxY
    let dockTop = screen.visibleFrame.minY
    return panelTop - dockTop - 100
  }

  private func hideOutput() {
    output.maxHeight = nil
    divider.isHidden = true
    output.isHidden = true
    output.clear()
    guard let window = window else { return }
    let currentSize = window.frame.size
    var frame = window.frame
    frame.size.height = panelBaseHeight
    frame.origin.y += (currentSize.height - panelBaseHeight)
    window.setFrame(frame, display: true, animate: true)
  }

  // MARK: - Paste

  fileprivate func pasteAndClose() {
    let text = output.string
    guard !text.isEmpty else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    EventBus.shared.publish(PanelEvent.requestPaste, payload: self)
  }
}

// MARK: - PanelProtocol

extension ChatPanelController: PanelProtocol {
  var panelID: String { "chat" }
  var panelWindow: NSWindow? { window }

  func showPanel(context: [String: Any]?) {
    if isPanelVisible {
      EventBus.shared.publish(PanelEvent.requestClose, payload: self)
    } else {
      show()
    }
  }

  func closePanel() {
    window?.orderOut(nil)
  }

  func handleKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      EventBus.shared.publish(PanelEvent.requestClose, payload: self)
      return true
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36 {
      if event.modifierFlags.contains(.command) {
        triggerChat()
        return true
      }
      if flags == .shift {
        inputView.insertNewline()
        return true
      }
      if hasOutput {
        pasteAndClose()
        return true
      }
      return true
    }
    if event.keyCode == 6 {  // z
      if flags.contains(.command), !flags.contains(.shift) {
        inputView.undo()
        return true
      }
      return false
    }
    return false
  }
}
