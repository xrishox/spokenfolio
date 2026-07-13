import AppKit

enum MainWindowGeometry {
  static let preferredContentSize = NSSize(width: 1_080, height: 780)
  static let nominalMinimumContentSize = NSSize(width: 760, height: 520)
  static let margin: CGFloat = 20

  static func fittedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
    let available = visibleFrame.insetBy(dx: margin, dy: margin)
    guard available.width > 0, available.height > 0 else { return visibleFrame }
    var result = frame
    result.size.width = min(result.width, available.width)
    result.size.height = min(result.height, available.height)
    result.size.width = max(min(nominalMinimumContentSize.width, available.width), result.width)
    result.size.height = max(min(nominalMinimumContentSize.height, available.height), result.height)
    result.origin.x = min(max(result.minX, available.minX), available.maxX - result.width)
    result.origin.y = min(max(result.minY, available.minY), available.maxY - result.height)
    return result
  }

  static func minimumContentSize(visibleFrame: NSRect) -> NSSize {
    let available = visibleFrame.insetBy(dx: margin, dy: margin)
    return NSSize(
      width: min(nominalMinimumContentSize.width, available.width),
      height: min(nominalMinimumContentSize.height, available.height))
  }
}
