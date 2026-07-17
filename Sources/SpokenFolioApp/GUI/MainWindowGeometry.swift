import AppKit

enum MainWindowGeometry {
  static let preferredContentSize = NSSize(width: 1_180, height: 760)
  static let nominalMinimumContentSize = NSSize(width: 900, height: 620)
  static let margin: CGFloat = 16

  static func fittedFrame(
    _ frame: NSRect, visibleFrame: NSRect, minimumFrameSize: NSSize? = nil
  ) -> NSRect {
    let available = visibleFrame.insetBy(dx: margin, dy: margin)
    guard available.width > 0, available.height > 0 else { return frame }
    var result = frame
    if !result.width.isFinite || result.width <= 0 { result.size.width = preferredContentSize.width }
    if !result.height.isFinite || result.height <= 0 { result.size.height = preferredContentSize.height }
    let minimum = minimumFrameSize ?? nominalMinimumContentSize
    result.size.width = min(
      available.width, max(min(minimum.width, available.width), result.width))
    result.size.height = min(
      available.height, max(min(minimum.height, available.height), result.height))
    result.origin.x = min(max(result.minX, available.minX), available.maxX - result.width)
    result.origin.y = min(max(result.minY, available.minY), available.maxY - result.height)
    return result
  }

  /// The visible frame of the display that should host a restored window: the
  /// screen sharing the largest area with the saved frame. A frame from a
  /// disconnected display intersects nothing and falls back to the main screen.
  static func restorationVisibleFrame(
    windowFrame: NSRect, screenVisibleFrames: [NSRect], mainVisibleFrame: NSRect?
  ) -> NSRect? {
    let best = screenVisibleFrames
      .map { (frame: $0, overlap: $0.intersection(windowFrame)) }
      .filter { !$0.overlap.isEmpty }
      .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }
    return best?.frame ?? mainVisibleFrame
  }

  static func minimumContentSize(visibleFrame: NSRect) -> NSSize {
    let available = visibleFrame.insetBy(dx: margin, dy: margin)
    return minimumContentSize(maximumContentSize: available.size)
  }

  static func minimumContentSize(maximumContentSize: NSSize) -> NSSize {
    return NSSize(
      width: max(0, min(nominalMinimumContentSize.width, maximumContentSize.width)),
      height: max(0, min(nominalMinimumContentSize.height, maximumContentSize.height)))
  }
}
