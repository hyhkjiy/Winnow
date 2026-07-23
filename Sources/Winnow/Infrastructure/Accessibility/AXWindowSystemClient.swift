import AppKit
import ApplicationServices
import Foundation

struct RunningApplicationSnapshot: Equatable, Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String?
  let localizedName: String
  let isRegularApplication: Bool
  let isTerminated: Bool
}

struct AXWindowSnapshot: Sendable {
  let reference: AXWindowReference
  let role: String?
  let subrole: String?
  let title: String?
  let accessibilityIdentifier: String?
  let isMinimized: Bool
}

enum AXWindowSystemError: Error, Equatable {
  case accessibility(AXError)
  case invalidAttributeValue(String)
}

protocol AXWindowSystemClient: Sendable {
  var isProcessTrusted: Bool { get }

  func runningApplications() -> [RunningApplicationSnapshot]
  func windows(for processIdentifier: pid_t) throws -> [AXWindowSnapshot]
  func unhideApplication(processIdentifier: pid_t) -> Bool
  func activateApplication(processIdentifier: pid_t) -> Bool
  func setWindowMinimized(_ reference: AXWindowReference, minimized: Bool) throws
  func raiseWindow(_ reference: AXWindowReference) throws
  func setWindowMain(_ reference: AXWindowReference) throws
  func setWindowFocused(_ reference: AXWindowReference) throws
}

final class LiveAXWindowSystemClient: AXWindowSystemClient, @unchecked Sendable {
  var isProcessTrusted: Bool {
    AXIsProcessTrusted()
  }

  func runningApplications() -> [RunningApplicationSnapshot] {
    NSWorkspace.shared.runningApplications.map { application in
      RunningApplicationSnapshot(
        processIdentifier: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier,
        localizedName: application.localizedName ?? "",
        isRegularApplication: application.activationPolicy == .regular,
        isTerminated: application.isTerminated
      )
    }
  }

  func windows(for processIdentifier: pid_t) throws -> [AXWindowSnapshot] {
    let application = AXUIElementCreateApplication(processIdentifier)
    let timeoutError = AXUIElementSetMessagingTimeout(application, 1)
    if timeoutError == .apiDisabled {
      throw AXWindowSystemError.accessibility(timeoutError)
    }

    guard
      let elements = try copyOptionalAttribute(
        application,
        attribute: kAXWindowsAttribute,
        as: [AXUIElement].self
      )
    else {
      return []
    }

    var snapshots: [AXWindowSnapshot] = []
    for element in elements {
      do {
        let timeoutError = AXUIElementSetMessagingTimeout(element, 1)
        if timeoutError == .apiDisabled {
          throw AXWindowSystemError.accessibility(timeoutError)
        }

        snapshots.append(
          AXWindowSnapshot(
            reference: AXWindowReference(element: element),
            role: try copyOptionalAttribute(
              element,
              attribute: kAXRoleAttribute,
              as: String.self
            ),
            subrole: try copyOptionalAttribute(
              element,
              attribute: kAXSubroleAttribute,
              as: String.self
            ),
            title: try copyOptionalAttribute(
              element,
              attribute: kAXTitleAttribute,
              as: String.self
            ),
            accessibilityIdentifier: try copyOptionalAttribute(
              element,
              attribute: kAXIdentifierAttribute,
              as: String.self
            ),
            isMinimized: try copyOptionalAttribute(
              element,
              attribute: kAXMinimizedAttribute,
              as: Bool.self
            ) ?? false
          )
        )
      } catch AXWindowSystemError.accessibility(.apiDisabled) {
        throw AXWindowSystemError.accessibility(.apiDisabled)
      } catch {
        if !isProcessTrusted {
          throw AXWindowSystemError.accessibility(.apiDisabled)
        }
        continue
      }
    }
    return snapshots
  }

  func unhideApplication(processIdentifier: pid_t) -> Bool {
    guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
      return false
    }

    if application.isHidden {
      return application.unhide()
    }

    return true
  }

  func activateApplication(processIdentifier: pid_t) -> Bool {
    guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
      return false
    }

    return application.activate(options: [])
  }

  func setWindowMinimized(_ reference: AXWindowReference, minimized: Bool) throws {
    try setAttribute(
      reference.element,
      attribute: kAXMinimizedAttribute,
      value: minimized ? kCFBooleanTrue : kCFBooleanFalse
    )
  }

  func raiseWindow(_ reference: AXWindowReference) throws {
    let error = AXUIElementPerformAction(
      reference.element,
      kAXRaiseAction as CFString
    )
    try throwIfNeeded(error)
  }

  func setWindowMain(_ reference: AXWindowReference) throws {
    try setAttribute(
      reference.element,
      attribute: kAXMainAttribute,
      value: kCFBooleanTrue
    )
  }

  func setWindowFocused(_ reference: AXWindowReference) throws {
    try setAttribute(
      reference.element,
      attribute: kAXFocusedAttribute,
      value: kCFBooleanTrue
    )
  }

  private func copyOptionalAttribute<T>(
    _ element: AXUIElement,
    attribute: String,
    as type: T.Type
  ) throws -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      element,
      attribute as CFString,
      &value
    )

    switch error {
    case .success:
      guard let value else {
        return nil
      }
      guard let typedValue = value as? T else {
        throw AXWindowSystemError.invalidAttributeValue(attribute)
      }
      return typedValue
    case .noValue, .attributeUnsupported:
      return nil
    default:
      throw AXWindowSystemError.accessibility(error)
    }
  }

  private func setAttribute(
    _ element: AXUIElement,
    attribute: String,
    value: CFTypeRef
  ) throws {
    let error = AXUIElementSetAttributeValue(
      element,
      attribute as CFString,
      value
    )
    try throwIfNeeded(error)
  }

  private func throwIfNeeded(_ error: AXError) throws {
    guard error == .success else {
      throw AXWindowSystemError.accessibility(error)
    }
  }
}
