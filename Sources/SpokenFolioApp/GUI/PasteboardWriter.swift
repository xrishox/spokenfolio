import AppKit

/// Clipboard writes can fail (pasteboard server unavailable, sandbox denial);
/// "Copied" feedback must reflect what actually happened.
enum PasteboardWriter {
  @MainActor
  @discardableResult
  static func copy(_ string: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(string, forType: .string)
  }
}
