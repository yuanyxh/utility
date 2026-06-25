import Cocoa

/// 通用加载指示器 — 预配置的 NSProgressIndicator 子类
///
/// 自动设置 `.spinning` 样式 + `isDisplayedWhenStopped = false`。
/// 图标色、大小、布局由外部控制：
///
/// ```swift
/// let spinner = LoadingSpinner()
/// spinner.contentTintColor = .systemBlue
/// spinner.controlSize = .small
/// spinner.translatesAutoresizingMaskIntoConstraints = false
/// spinner.startAnimation(nil)
/// ```
public final class LoadingSpinner: NSProgressIndicator {

  override public init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    style = .spinning
    controlSize = .regular
    isDisplayedWhenStopped = false
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    style = .spinning
    controlSize = .regular
    isDisplayedWhenStopped = false
  }
}
