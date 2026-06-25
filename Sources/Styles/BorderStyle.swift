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
