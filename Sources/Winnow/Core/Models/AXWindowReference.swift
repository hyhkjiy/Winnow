import ApplicationServices
import Foundation

final class AXWindowReference: @unchecked Sendable {
  let element: AXUIElement

  init(element: AXUIElement) {
    self.element = element
  }
}
