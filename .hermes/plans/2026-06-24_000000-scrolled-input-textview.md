# 基础输入框组件封装 — 实现计划

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 封装一个自包含的可滚动多行输入框组件（ScrolledInputTextView），内置 NSScrollView + 内部 NSTextView，对外暴露统一的 clear/scroll/setCursor API。配套定义 InputViewStyle 样式结构体及 BorderStyle 类。

**Architecture:** 组件继承 NSView，内部持有 NSScrollView + 自定义 InnerTextView。样式通过 InputViewStyle struct 配置，在 apply 时一次性应用到所有子视图。scroll、setCursor 方法直接委托到内部 NSTextView。

**Tech Stack:** Swift 5.9+ / AppKit / macOS 14+

---

## Task 1: 创建 BorderStyle 类

**Objective:** 在 `Sources/Styles/BorderStyle.swift` 中定义 BorderStyle 类，封装边框的颜色、宽度、圆角属性。

**Files:**
- Create: `Sources/Styles/BorderStyle.swift`

**Step 1: 编写完整实现**

```swift
import Cocoa

/// 边框样式
public final class BorderStyle {
  public var color: NSColor
  public var width: CGFloat
  public var cornerRadius: CGFloat

  public init(color: NSColor = .separatorColor, width: CGFloat = 1, cornerRadius: CGFloat = 0) {
    self.color = color
    self.width = width
    self.cornerRadius = cornerRadius
  }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && rm -rf .build && swift build
```

预期：BUILD SUCCESS

**Step 3: 确认代码入二进制**

```bash
strings .build/debug/utility | grep "BorderStyle"
```

预期：能找到相关符号

---

## Task 2: 创建 InputViewStyle 结构体

**Objective:** 在 `Sources/Styles/InputViewStyle.swift` 中定义 InputViewStyle，收束所有可配置样式（含 border 属性）。

**Files:**
- Create: `Sources/Styles/InputViewStyle.swift`

**Step 1: 编写完整实现**

```swift
import Cocoa

// MARK: - ScrollPosition

/// 滚动目标位置
public enum ScrollPosition {
  case top
  case bottom
}

// MARK: - CursorPosition

/// 光标目标位置
public enum CursorPosition {
  case start
  case end
  /// 数字位置（0-based），创建时自动校验有效性
  case index(Int)
}

// MARK: - InputViewStyle

/// 输入框样式配置 — 收束所有可配置属性，一个 apply 方法全量应用
public struct InputViewStyle {
  /// 背景色，nil 表示透明（drawsBackground = false）
  public var backgroundColor: NSColor?

  /// 字体
  public var font: NSFont

  /// 文字颜色
  public var textColor: NSColor

  /// 文字内边距
  public var textContainerInset: NSSize

  /// 是否可编辑
  public var isEditable: Bool

  /// 是否显示垂直滚动条
  public var showsVerticalScroller: Bool

  /// 边框样式，nil 表示无边框
  public var border: BorderStyle?

  public init(
    backgroundColor: NSColor? = nil,
    font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
    textColor: NSColor = .labelColor,
    textContainerInset: NSSize = NSSize(width: 8, height: 8),
    isEditable: Bool = true,
    showsVerticalScroller: Bool = false,
    border: BorderStyle? = nil
  ) {
    self.backgroundColor = backgroundColor
    self.font = font
    self.textColor = textColor
    self.textContainerInset = textContainerInset
    self.isEditable = isEditable
    self.showsVerticalScroller = showsVerticalScroller
    self.border = border
  }

  /// 将样式应用到 NSTextView
  func apply(to textView: NSTextView) {
    textView.font = font
    textView.textColor = textColor
    textView.textContainerInset = textContainerInset
    textView.isEditable = isEditable
    textView.typingAttributes = [
      .font: font,
      .foregroundColor: textColor,
    ]

    if let bg = backgroundColor {
      textView.backgroundColor = bg
      textView.drawsBackground = true
    } else {
      textView.drawsBackground = false
    }
  }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build
```

预期：BUILD SUCCESS

---

## Task 3: 创建 InnerTextView（NSTextView 子类）

**Objective:** 在 `Sources/Components/ScrolledInputTextView.swift` 中定义内部使用的 private InnerTextView，重写 undoManager 为独立实例，避免污染全局撤销栈。

**Files:**
- Create: `Sources/Components/ScrolledInputTextView.swift`

**Step 1: 编写 InnerTextView**

```swift
import Cocoa

// MARK: - InnerTextView

/// 内部 NSTextView — 独立 undoManager，避免污染全局撤销栈
private final class InnerTextView: NSTextView {
  private let _undoManager = UndoManager()
  override var undoManager: UndoManager? { _undoManager }

  override init(frame: NSRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isRichText = false
    isFieldEditor = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build
```

预期：InnerTextView 编译通过

---

## Task 4: 创建 ScrolledInputTextView 组件主体

**Objective:** 在同一文件中追加 ScrolledInputTextView（NSView 子类），内部持有 NSScrollView + InnerTextView，实现 style 配置、clear、scroll、setCursor API。

**Files:**
- Modify: `Sources/Components/ScrolledInputTextView.swift`（追加在 InnerTextView 之后）

**Step 1: 追加 ScrolledInputTextView 类**

```swift
// MARK: - ScrolledInputTextView

/// 自包含可滚动多行输入框组件
/// 内部管理 NSScrollView + InnerTextView，对外暴露统一的 style / clear / scroll / setCursor API
public final class ScrolledInputTextView: NSView {

  // MARK: - Subviews

  private let scrollView: NSScrollView = {
    let s = NSScrollView()
    s.hasVerticalScroller = false
    s.borderType = .noBorder
    s.scrollerStyle = .overlay
    s.autohidesScrollers = true
    s.verticalScroller?.controlSize = .small
    s.drawsBackground = false
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
  }()

  public let textView: InnerTextView = {
    let tv = InnerTextView()
    tv.isRichText = false
    tv.drawsBackground = false
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.textContainer?.widthTracksTextView = true
    tv.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    return tv
  }()

  // MARK: - Style

  private var _style: InputViewStyle = InputViewStyle()

  /// 获取/设置样式 — 设置时全量应用
  public var style: InputViewStyle {
    get { _style }
    set { applyStyle(newValue) }
  }

  // MARK: - Content proxy

  /// 文本内容（直接代理到内部 NSTextView）
  public var string: String {
    get { textView.string }
    set { textView.string = newValue }
  }

  /// 是否可编辑（直接代理）
  public var isEditable: Bool {
    get { textView.isEditable }
    set { textView.isEditable = newValue }
  }

  // MARK: - Init

  public init(style: InputViewStyle = InputViewStyle()) {
    self._style = style
    super.init(frame: .zero)
    wantsLayer = true
    setupScrollView()
    applyStyle(style)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Setup

  private func setupScrollView() {
    scrollView.documentView = textView
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Style application

  private func applyStyle(_ style: InputViewStyle) {
    // 背景
    if let bg = style.backgroundColor {
      scrollView.drawsBackground = true
      scrollView.backgroundColor = bg
      style.apply(to: textView) // 会设 drawsBackground = true
    } else {
      scrollView.drawsBackground = false
      style.apply(to: textView) // drawsBackground = false
    }

    // 滚动条
    scrollView.hasVerticalScroller = style.showsVerticalScroller

    // 边框
    if let border = style.border {
      layer?.borderColor = border.color.cgColor
      layer?.borderWidth = border.width
      layer?.cornerRadius = border.cornerRadius
    } else {
      layer?.borderWidth = 0
      layer?.cornerRadius = 0
    }
  }

  // MARK: - API: Clear

  /// 清空输入内容
  public func clear() {
    textView.string = ""
    textView.undoManager?.removeAllActions()
  }

  // MARK: - API: Scroll

  /// 滚动到顶部或底部
  public func scroll(to position: ScrollPosition) {
    switch position {
    case .top:
      textView.scrollToBeginningOfDocument(nil)
    case .bottom:
      textView.scrollToEndOfDocument(nil)
    }
  }

  // MARK: - API: SetCursor

  /// 设置光标位置
  /// - Parameter position: .start / .end / .index(n)，n 会被校验到 [0, text.count] 范围内
  public func setCursor(to position: CursorPosition) {
    let count = textView.string.count
    let target: Int

    switch position {
    case .start:
      target = 0
    case .end:
      target = count
    case .index(let n):
      target = max(0, min(n, count))
    }

    textView.setSelectedRange(NSRange(location: target, length: 0))
  }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build
```

预期：BUILD SUCCESS

**Step 3: 验证关键符号进二进制**

```bash
strings .build/arm64-apple-macosx/debug/utility | grep -E "ScrolledInputTextView|InnerTextView|InputViewStyle|BorderStyle|ScrollPosition|CursorPosition"
```

预期：全部找到

---

## 最终文件结构

```
Sources/
  Components/
    ScrolledInputTextView.swift    ← 新建
  Styles/
    BorderStyle.swift              ← 新建
    InputViewStyle.swift           ← 新建
```

---

## 不改的模块（显式列出）

| 模块 | 理由 |
|------|------|
| `ChatPanelController` | 不涉及本次变更 — 后续如有需求可迁移到新组件 |
| `TranslationPanelController` | 不涉及本次变更 |
| `ClipboardPanelController` | 不涉及本次变更 |
| `EventBus` / `PanelManager` | 架构基础设施，不动 |
| `ConfigManager` / `ConfigTypes` | 不涉及配置层变更 |

---

## 设计决策说明

1. **InnerTextView 内嵌而非独立暴露**：组件自我管理 scroll view 和 text view 的关系，调用方只需一行 `ScrolledInputTextView(style:)` 即可使用，避免每次手写 scroll view 配置。
2. **InputViewStyle 为 struct**：符合项目 Config struct 收束模式，未来加属性不碰函数签名。
3. **BorderStyle 为 class**：用户明确指定为类（"BorderSytle 类"），用 class 方便共享引用和后续扩展动画属性。
4. **ScrollPosition / CursorPosition 为 enum**：类型安全，`.index(n)` 自动校验范围，避免无效光标位置。
5. **滚动条默认 overlay + small + autohide**：与项目现有 ChatPanelController 的 scroll view 配置一致。
