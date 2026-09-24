import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class WindowIdentityBridge: @unchecked Sendable {
  typealias Lookup = @Sendable (AXUIElement) -> CGWindowID?

  private typealias AXUIElementGetWindowFunction = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
  ) -> AXError

  private let lookup: Lookup

  init(lookup: @escaping Lookup = WindowIdentityBridge.liveLookup()) {
    self.lookup = lookup
  }

  func windowServerIdentifier(for element: AXUIElement) -> CGWindowID? {
    guard let identifier = lookup(element), Self.isValid(identifier) else {
      return nil
    }
    return identifier
  }

  private static func liveLookup() -> Lookup {
    if ProcessInfo.processInfo.environment["WINNOW_DISABLE_PRIVATE_WINDOW_ID"] == "1" {
      return { _ in nil }
    }
    guard
      let handle = dlopen(nil, RTLD_LAZY),
      let symbol = dlsym(handle, "_AXUIElementGetWindow")
    else {
      return { _ in nil }
    }

    let function = unsafeBitCast(
      symbol,
      to: AXUIElementGetWindowFunction.self
    )
    return { element in
      var identifier = CGWindowID(0)
      guard function(element, &identifier) == .success else {
        return nil
      }
      return identifier
    }
  }

  private static func isValid(_ identifier: CGWindowID) -> Bool {
    identifier != 0 && identifier != CGWindowID.max
  }
}
