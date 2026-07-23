import ApplicationServices
import Foundation

final class AccessibilityPermissionClient {
  var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  func requestAccess() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}
