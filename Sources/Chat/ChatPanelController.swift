import Cocoa

// MARK: - Custom NSTextView (Input)

private final class ChatInputTextView: NSTextView {
  weak var controller: ChatPanelController?

  private let _undoManager = UndoManager()
  override var undoManager: UndoManager? { _undoManager }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36, flags == .shift {
      insertNewline(nil)
      return
    }
    if flags.contains(.command), !flags.contains(.shift), event.keyCode == 6 {
      undoManager?.undo()
      return
    }
    super.keyDown(with: event)
  }
}

// MARK: - Custom NSPanel

private final class ChatPanel: NSPanel {
  weak var controller: ChatPanelController?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // 编辑修饰键 — 显式派发给第一响应者
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

    switch event.keyCode {
    case 53:
      EventBus.shared.publish(PanelEvent.requestClose, payload: controller)
      return true
    case 36:  // return/enter
      if flags == .command {
        controller?.triggerChat()
        return true
      }
      if !flags.contains(.command), !flags.contains(.shift), !flags.contains(.control),
        controller?.hasOutput == true
      {
        controller?.pasteAndClose()
        return true
      }
      return false
    default: break
    }
    return super.performKeyEquivalent(with: event)
  }
}

// MARK: - Panel Controller

public final class ChatPanelController: NSWindowController {
  private var previousFrontmostApp: NSRunningApplication?

  private let inputTextView: ChatInputTextView = {
    let tv = ChatInputTextView()
    tv.isEditable = true
    tv.isRichText = false
    tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 6, height: 8)
    tv.typingAttributes = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor.labelColor,
    ]
    return tv
  }()

  private let outputTextView: NSTextView = {
    let tv = NSTextView()
    tv.isEditable = false
    tv.isRichText = false
    tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    tv.textColor = NSColor.textColor
    tv.textContainerInset = NSSize(width: 8, height: 8)
    tv.drawsBackground = false
    return tv
  }()

  private let inputScrollView: NSScrollView = {
    let s = NSScrollView()
    s.hasVerticalScroller = false
    s.borderType = .noBorder
    s.scrollerStyle = .overlay
    s.autohidesScrollers = true
    s.verticalScroller?.controlSize = .small
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
  }()

  private let outputScrollView: NSScrollView = {
    let s = NSScrollView()
    s.hasVerticalScroller = true
    s.borderType = .noBorder
    s.scrollerStyle = .overlay
    s.autohidesScrollers = true
    s.verticalScroller?.controlSize = .small
    s.translatesAutoresizingMaskIntoConstraints = false
    s.drawsBackground = false
    s.isHidden = true
    return s
  }()

  private let divider: NSBox = {
    let b = NSBox()
    b.boxType = .separator
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isHidden = true
    return b
  }()

  private let loadingIndicator: NSProgressIndicator = {
    let p = NSProgressIndicator()
    p.style = .spinning
    p.controlSize = .regular
    p.isDisplayedWhenStopped = false
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
  }()

  private var outputHeightConstraint: NSLayoutConstraint?

  private var accumulatedOutput = ""
  private var isStreaming = false
  private var chatSeq: UInt = 0
  private let inputHeight: CGFloat = 3 * 16 + 16 + 2
  private let panelBaseHeight: CGFloat = 12 + (3 * 16 + 16 + 2) + 12

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
    inputTextView.controller = self

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

    inputScrollView.documentView = inputTextView
    outputScrollView.documentView = outputTextView

    content.addSubview(inputScrollView)
    content.addSubview(loadingIndicator)
    content.addSubview(divider)
    content.addSubview(outputScrollView)

    let panelW: CGFloat = 560
    let panelH: CGFloat = panelBaseHeight

    inputScrollView.drawsBackground = false

    NSLayoutConstraint.activate([
      inputScrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      inputScrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      inputScrollView.trailingAnchor.constraint(
        equalTo: loadingIndicator.leadingAnchor, constant: -4),
      inputScrollView.heightAnchor.constraint(equalToConstant: inputHeight),

      loadingIndicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
      loadingIndicator.centerYAnchor.constraint(equalTo: inputScrollView.centerYAnchor),

      divider.topAnchor.constraint(equalTo: inputScrollView.bottomAnchor, constant: 8),
      divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

      outputScrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
      outputScrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      outputScrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
    ])

    outputHeightConstraint = outputScrollView.heightAnchor.constraint(equalToConstant: 0)
    outputHeightConstraint?.isActive = true

    // 面板初始最小高度
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
    previousFrontmostApp = NSWorkspace.shared.frontmostApplication
    positionPanel()

    // 先显示面板但不抢焦点（确保 cmd+c 兜底能命中源 app）
    window?.orderFront(nil)

    // 异步获取选中文本
    guard let app = previousFrontmostApp else {
      window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      return
    }
    Task { @MainActor in
      if let text = await SelectedTextService.getSelectedText(from: app), !text.isEmpty {
        self.inputTextView.string = text
      }
      // 获取完成后再激活
      self.window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  public override func close() {
    AIChatService.shared.cancel()
    isStreaming = false
    chatSeq += 1  // 废弃所有待处理回调
    loadingIndicator.stopAnimation(nil)

    // 关闭时重置状态（避免打开时闪烁）
    inputTextView.string = ""
    inputTextView.undoManager?.removeAllActions()
    outputTextView.string = ""
    accumulatedOutput = ""
    hideOutput()

    EventBus.shared.publish(PanelEvent.requestClose, payload: self)
  }

  private func positionPanel() {
    guard let screen = window?.screen ?? NSScreen.main else { return }
    let panelSize = window?.frame.size ?? NSSize(width: 560, height: panelBaseHeight)
    let origin = WindowPositioning.screenCenter(
      windowSize: panelSize,
      offsetFraction: 0.2,
      screen: screen
    )
    window?.setFrameOrigin(origin)
  }

  // MARK: - Chat

  fileprivate func triggerChat() {
    if isStreaming {
      AIChatService.shared.cancel()
    }
    outputTextView.string = ""
    accumulatedOutput = ""
    hideOutput()
    startChat()
  }

  private func startChat() {
    let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // 检查 @ 规则匹配
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
          if self.accumulatedOutput.isEmpty {
            self.showOutput()
          }
          self.accumulatedOutput += token
          self.outputTextView.string = self.accumulatedOutput
          self.updateOutputHeight()
          self.outputTextView.scrollToEndOfDocument(nil)
        }
      },
      onComplete: { [weak self] result in
        DispatchQueue.main.async {
          guard let self = self, seq == self.chatSeq else { return }
          self.isStreaming = false
          self.loadingIndicator.stopAnimation(nil)
          if case .failure(let error) = result {
            // 保留已输出内容，追加错误
            let errorMsg = "\n\n⚠️ \(error.localizedDescription)"
            let attrs: [NSAttributedString.Key: Any] = [
              .foregroundColor: NSColor.systemRed,
              .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            ]
            self.outputTextView.textStorage?.append(
              NSAttributedString(string: errorMsg, attributes: attrs)
            )
            self.outputTextView.scrollToEndOfDocument(nil)
            if self.accumulatedOutput.isEmpty {
              self.showOutput()
              self.accumulatedOutput = errorMsg
            }
          }
        }
      }
    )
  }

  // MARK: - @ Rule

  /// 解析 @name content 格式，返回匹配的规则和内容，未匹配返回 nil
  private func matchAtRule(text: String) -> (rule: ChatAtRuleConfig, content: String)? {
    guard text.hasPrefix("@") else { return nil }

    // 找到 name 结束位置（第一个空白字符）
    let afterAt = text.index(after: text.startIndex)
    guard let spaceIdx = text[afterAt...].firstIndex(of: " ") else {
      // 只有 @name 没有 content，content 为空
      let name = String(text[afterAt...])
      guard let rule = ConfigManager.shared.config.chat.atRules.first(where: { $0.name == name })
      else { return nil }
      return (rule, "")
    }

    let name = String(text[afterAt..<spaceIdx])
    let content = String(text[text.index(after: spaceIdx)...])
      .trimmingCharacters(in: .whitespaces)

    guard let rule = ConfigManager.shared.config.chat.atRules.first(where: { $0.name == name })
    else { return nil }
    return (rule, content)
  }

  /// 执行 @ 规则命令并展示输出
  private func executeAtRule(rule: ChatAtRuleConfig, content: String) {
    let command = rule.command.replacingOccurrences(of: "{content}", with: content)

    chatSeq += 1
    let seq = chatSeq
    isStreaming = true
    outputTextView.string = ""
    accumulatedOutput = ""
    loadingIndicator.startAnimation(nil)
    showOutput()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = TaskExecutor.execute(.sh(command))

      DispatchQueue.main.async {
        guard let self = self, seq == self.chatSeq else { return }
        self.isStreaming = false
        self.loadingIndicator.stopAnimation(nil)

        // 拼接 stdout + stderr
        var displayText = result.output
        if !result.error.isEmpty {
          if !displayText.isEmpty {
            displayText += "\n"
          }
          displayText += result.error
        }

        self.accumulatedOutput = displayText
        self.outputTextView.string = displayText
        self.outputTextView.scrollToEndOfDocument(nil)
      }
    }
  }

  // MARK: - Output visibility

  private func showOutput() {
    divider.isHidden = false
    outputScrollView.isHidden = false
    outputHeightConstraint?.isActive = false

    let outputH = clampOutputHeight()
    outputHeightConstraint = outputScrollView.heightAnchor.constraint(equalToConstant: outputH)
    outputHeightConstraint?.isActive = true

    applyPanelHeight(outputH: outputH)
  }

  /// 流式输出时随内容动态增长，上限到 dock 栏
  private func updateOutputHeight() {
    let outputH = clampOutputHeight()
    if let old = outputHeightConstraint, abs(old.constant - outputH) > 2 {
      old.constant = outputH
      applyPanelHeight(outputH: outputH)
    }
  }

  // MARK: - Panel sizing helpers

  /// 可用空间：面板顶部 → dock 栏上方 100pt
  private func availableHeight() -> CGFloat {
    guard let window = window, let screen = window.screen ?? NSScreen.main else { return 0 }
    let panelTop = window.frame.maxY
    let dockTop = screen.visibleFrame.minY
    return panelTop - dockTop - 100
  }

  /// 计算输出区高度 — 基于文本内容，至少 120pt，最多到 dock 栏
  private func clampOutputHeight() -> CGFloat {
    let extraSpacing: CGFloat = 20  // divider + spacing
    let textContentH = textContentHeight()
    let desiredH = max(120, textContentH)
    let maxOutputH = max(120, availableHeight() - panelBaseHeight - extraSpacing)
    return min(desiredH, maxOutputH)
  }

  /// 输出文本的实际内容高度
  private func textContentHeight() -> CGFloat {
    guard let lm = outputTextView.layoutManager,
      let tc = outputTextView.textContainer
    else { return 120 }
    lm.ensureLayout(for: tc)
    let used = lm.usedRect(for: tc)
    return used.height + outputTextView.textContainerInset.height * 2 + 8
  }

  /// 应用面板高度，向下展开（面板顶部位置不变）
  private func applyPanelHeight(outputH: CGFloat) {
    guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
    let extraSpacing: CGFloat = 20
    let maxPanelH = availableHeight()
    let newH = min(panelBaseHeight + outputH + extraSpacing, maxPanelH)
    let currentH = window.frame.size.height
    if abs(newH - currentH) < 1 { return }
    var frame = window.frame
    frame.size.height = newH
    frame.origin.y -= (newH - currentH)
    window.setFrame(frame, display: true, animate: false)
  }

  private func hideOutput() {
    divider.isHidden = true
    outputScrollView.isHidden = true
    outputHeightConstraint?.isActive = false
    outputHeightConstraint = outputScrollView.heightAnchor.constraint(equalToConstant: 0)
    outputHeightConstraint?.isActive = true

    guard let window = window else { return }
    let currentSize = window.frame.size
    var frame = window.frame
    frame.size.height = panelBaseHeight
    frame.origin.y += (currentSize.height - panelBaseHeight)
    window.setFrame(frame, display: true, animate: true)
  }

  // MARK: - Paste

  fileprivate func pasteAndClose() {
    let text = outputTextView.string
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
    AIChatService.shared.cancel()
    isStreaming = false
    chatSeq += 1
    loadingIndicator.stopAnimation(nil)
    inputTextView.string = ""
    inputTextView.undoManager?.removeAllActions()
    outputTextView.string = ""
    accumulatedOutput = ""
    hideOutput()
    window?.orderOut(nil)
  }

  func handleKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      EventBus.shared.publish(PanelEvent.requestClose, payload: self)
      return true
    }
    if event.keyCode == 36 {
      if event.modifierFlags.contains(.command) {
        triggerChat()
        return true
      }
      if hasOutput {
        pasteAndClose()
        return true
      }
      inputTextView.insertNewline(nil)
      return true
    }
    return false
  }
}
