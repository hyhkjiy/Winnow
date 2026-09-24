import AppKit
import ApplicationServices
import Foundation

struct RunningApplicationSnapshot: Equatable, Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String?
  let bundleURL: URL?
  let localizedName: String
  let isRegularApplication: Bool
  let isAccessoryApplication: Bool
  let isTerminated: Bool
}

struct AXWindowSnapshot: Sendable {
  let reference: AXWindowReference
  let windowServerIdentifier: CGWindowID?
  let role: String?
  let subrole: String?
  let title: String?
  let accessibilityIdentifier: String?
  let supportsRaiseAction: Bool
  let hasWindowControls: Bool
  let isMinimized: Bool
  let frame: CGRect?

  init(
    reference: AXWindowReference,
    windowServerIdentifier: CGWindowID? = nil,
    role: String?,
    subrole: String?,
    title: String?,
    accessibilityIdentifier: String?,
    supportsRaiseAction: Bool = true,
    hasWindowControls: Bool = true,
    isMinimized: Bool,
    frame: CGRect? = nil
  ) {
    self.reference = reference
    self.windowServerIdentifier = windowServerIdentifier
    self.role = role
    self.subrole = subrole
    self.title = title
    self.accessibilityIdentifier = accessibilityIdentifier
    self.supportsRaiseAction = supportsRaiseAction
    self.hasWindowControls = hasWindowControls
    self.isMinimized = isMinimized
    self.frame = frame
  }
}

enum AXWindowSystemError: Error, Equatable {
  case accessibility(AXError)
  case invalidAttributeValue(String)
  case deadlineExceeded
}

protocol AXWindowSystemClient: Sendable {
  var isProcessTrusted: Bool { get }

  func runningApplications() -> [RunningApplicationSnapshot]
  func windows(for processIdentifier: pid_t) throws -> [AXWindowSnapshot]
  func selectWindowFromMenu(processIdentifier: pid_t, title: String) throws -> Bool
  func unhideApplication(processIdentifier: pid_t) -> Bool
  func activateApplication(processIdentifier: pid_t) -> Bool
  func setWindowMinimized(_ reference: AXWindowReference, minimized: Bool) throws
  func raiseWindow(_ reference: AXWindowReference) throws
  func setWindowMain(_ reference: AXWindowReference) throws
  func setWindowFocused(_ reference: AXWindowReference) throws
}

final class LiveAXWindowSystemClient: AXWindowSystemClient, @unchecked Sendable {
  typealias AttributeValueCopier = @Sendable (
    AXUIElement,
    CFString,
    UnsafeMutablePointer<CFTypeRef?>
  ) -> AXError

  private let identityBridge: WindowIdentityBridge
  private let messagingTimeout: Float
  private let processScanBudget: TimeInterval
  private let copyAttributeValue: AttributeValueCopier

  init(
    identityBridge: WindowIdentityBridge = WindowIdentityBridge(),
    messagingTimeout: Float = 0.15,
    processScanBudget: TimeInterval = 0.4,
    copyAttributeValue: @escaping AttributeValueCopier = {
      AXUIElementCopyAttributeValue($0, $1, $2)
    }
  ) {
    self.identityBridge = identityBridge
    self.messagingTimeout = messagingTimeout
    self.processScanBudget = processScanBudget
    self.copyAttributeValue = copyAttributeValue
  }

  var isProcessTrusted: Bool {
    AXIsProcessTrusted()
  }

  func runningApplications() -> [RunningApplicationSnapshot] {
    NSWorkspace.shared.runningApplications.map { application in
      RunningApplicationSnapshot(
        processIdentifier: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier,
        bundleURL: application.bundleURL,
        localizedName: application.localizedName ?? "",
        isRegularApplication: application.activationPolicy == .regular,
        isAccessoryApplication: application.activationPolicy == .accessory,
        isTerminated: application.isTerminated
      )
    }
  }

  func windows(for processIdentifier: pid_t) throws -> [AXWindowSnapshot] {
    let deadline = ProcessInfo.processInfo.systemUptime + processScanBudget
    let application = AXUIElementCreateApplication(processIdentifier)
    let timeoutError = AXUIElementSetMessagingTimeout(application, messagingTimeout)
    if timeoutError == .apiDisabled {
      throw AXWindowSystemError.accessibility(timeoutError)
    }

    try ensureWithinDeadline(deadline)
    let windowElements =
      try copyOptionalAttribute(
        application,
        attribute: kAXWindowsAttribute,
        as: [AXUIElement].self
      ) ?? []
    let childElements =
      try copyBestEffortAttribute(
        application,
        attribute: kAXChildrenAttribute,
        as: [AXUIElement].self,
        deadline: deadline
      ) ?? []
    let focusedWindow = try copyBestEffortAttribute(
      application,
      attribute: kAXFocusedWindowAttribute,
      as: AXUIElement.self,
      deadline: deadline
    )
    let mainWindow = try copyBestEffortAttribute(
      application,
      attribute: kAXMainWindowAttribute,
      as: AXUIElement.self,
      deadline: deadline
    )
    var elements: [AXUIElement] = []
    for element in windowElements + childElements + [focusedWindow, mainWindow].compactMap({ $0 }) {
      guard !elements.contains(where: { CFEqual($0, element) }) else {
        continue
      }
      elements.append(element)
    }

    var snapshots: [AXWindowSnapshot] = []
    for element in elements {
      try ensureWithinDeadline(deadline)
      do {
        let timeoutError = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if timeoutError == .apiDisabled {
          throw AXWindowSystemError.accessibility(timeoutError)
        }

        let actionNames = try copyBestEffortActionNames(
          element,
          deadline: deadline
        )
        let attributeNames = try copyBestEffortAttributeNames(
          element,
          deadline: deadline
        )
        snapshots.append(
          AXWindowSnapshot(
            reference: AXWindowReference(element: element),
            windowServerIdentifier: identityBridge.windowServerIdentifier(
              for: element
            ),
            role: try copyBestEffortAttribute(
              element,
              attribute: kAXRoleAttribute,
              as: String.self,
              deadline: deadline
            ),
            subrole: try copyBestEffortAttribute(
              element,
              attribute: kAXSubroleAttribute,
              as: String.self,
              deadline: deadline
            ),
            title: try copyBestEffortAttribute(
              element,
              attribute: kAXTitleAttribute,
              as: String.self,
              deadline: deadline
            ),
            accessibilityIdentifier: try copyBestEffortAttribute(
              element,
              attribute: kAXIdentifierAttribute,
              as: String.self,
              deadline: deadline
            ),
            supportsRaiseAction: actionNames.contains(
              kAXRaiseAction as String
            ),
            hasWindowControls: Self.hasWindowControls(
              attributeNames: attributeNames
            ),
            isMinimized: try copyBestEffortAttribute(
              element,
              attribute: kAXMinimizedAttribute,
              as: Bool.self,
              deadline: deadline
            ) ?? false,
            frame: try copyBestEffortFrame(element, deadline: deadline)
          )
        )
      } catch AXWindowSystemError.accessibility(.apiDisabled) {
        throw AXWindowSystemError.accessibility(.apiDisabled)
      } catch AXWindowSystemError.deadlineExceeded {
        throw AXWindowSystemError.deadlineExceeded
      } catch {
        if !isProcessTrusted {
          throw AXWindowSystemError.accessibility(.apiDisabled)
        }
        throw error
      }
    }
    return snapshots
  }

  private func copyBestEffortActionNames(
    _ element: AXUIElement,
    deadline: TimeInterval
  ) throws -> [String] {
    try ensureWithinDeadline(deadline)
    var rawNames: CFArray?
    let error = AXUIElementCopyActionNames(element, &rawNames)
    if error == .success {
      return rawNames as? [String] ?? []
    }
    if error == .apiDisabled || !isProcessTrusted {
      throw AXWindowSystemError.accessibility(.apiDisabled)
    }
    if error == .notImplemented {
      return []
    }
    throw AXWindowSystemError.accessibility(error)
  }

  private func copyBestEffortAttributeNames(
    _ element: AXUIElement,
    deadline: TimeInterval
  ) throws -> [String] {
    try ensureWithinDeadline(deadline)
    var rawNames: CFArray?
    let error = AXUIElementCopyAttributeNames(element, &rawNames)
    if error == .success {
      return rawNames as? [String] ?? []
    }
    if error == .apiDisabled || !isProcessTrusted {
      throw AXWindowSystemError.accessibility(.apiDisabled)
    }
    if error == .notImplemented {
      return []
    }
    throw AXWindowSystemError.accessibility(error)
  }

  private static func hasWindowControls(
    attributeNames: [String]
  ) -> Bool {
    let controlAttributes = [
      kAXCloseButtonAttribute,
      kAXMinimizeButtonAttribute,
      kAXZoomButtonAttribute,
      kAXFullScreenButtonAttribute,
    ]
    return controlAttributes.contains { attribute in
      attributeNames.contains(attribute as String)
    }
  }

  func selectWindowFromMenu(
    processIdentifier: pid_t,
    title: String
  ) throws -> Bool {
    let application = AXUIElementCreateApplication(processIdentifier)
    guard
      let menuBar = try copyBestEffortAttribute(
        application,
        attribute: kAXMenuBarAttribute,
        as: AXUIElement.self
      )
    else {
      return false
    }

    var remainingElements = 400
    var visitedElements: Set<CFHashCode> = []
    let matches = try matchingMenuItems(
      in: menuBar,
      title: title,
      depth: 0,
      remainingElements: &remainingElements,
      visitedElements: &visitedElements
    )
    guard matches.count == 1, let item = matches.first else {
      return false
    }

    let error = AXUIElementPerformAction(
      item,
      kAXPressAction as CFString
    )
    return error == .success
  }

  private func copyBestEffortFrame(
    _ element: AXUIElement,
    deadline: TimeInterval
  ) throws -> CGRect? {
    guard
      let positionValue = try copyBestEffortAttribute(
        element,
        attribute: kAXPositionAttribute,
        as: AXValue.self,
        deadline: deadline
      ),
      let sizeValue = try copyBestEffortAttribute(
        element,
        attribute: kAXSizeAttribute,
        as: AXValue.self,
        deadline: deadline
      )
    else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue, .cgPoint, &position),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private func matchingMenuItems(
    in element: AXUIElement,
    title: String,
    depth: Int,
    remainingElements: inout Int,
    visitedElements: inout Set<CFHashCode>
  ) throws -> [AXUIElement] {
    guard depth <= 5, remainingElements > 0 else {
      return []
    }
    remainingElements -= 1

    let elementHash = CFHash(element)
    guard visitedElements.insert(elementHash).inserted else {
      return []
    }

    let role = try copyBestEffortAttribute(
      element,
      attribute: kAXRoleAttribute,
      as: String.self
    )
    let elementTitle = try copyBestEffortAttribute(
      element,
      attribute: kAXTitleAttribute,
      as: String.self
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    var matches: [AXUIElement] = []
    if role == kAXMenuItemRole as String, elementTitle == title {
      matches.append(element)
    }

    let children =
      try copyBestEffortAttribute(
        element,
        attribute: kAXChildrenAttribute,
        as: [AXUIElement].self
      ) ?? []
    for child in children {
      matches.append(
        contentsOf: try matchingMenuItems(
          in: child,
          title: title,
          depth: depth + 1,
          remainingElements: &remainingElements,
          visitedElements: &visitedElements
        )
      )
      if matches.count > 1 {
        return matches
      }
    }
    return matches
  }

  private func copyBestEffortAttribute<T>(
    _ element: AXUIElement,
    attribute: String,
    as type: T.Type,
    deadline: TimeInterval? = nil
  ) throws -> T? {
    if let deadline {
      try ensureWithinDeadline(deadline)
    }
    do {
      return try copyOptionalAttribute(
        element,
        attribute: attribute,
        as: type
      )
    } catch AXWindowSystemError.accessibility(.apiDisabled) {
      throw AXWindowSystemError.accessibility(.apiDisabled)
    } catch AXWindowSystemError.accessibility(.notImplemented) {
      return nil
    } catch {
      guard isProcessTrusted else {
        throw AXWindowSystemError.accessibility(.apiDisabled)
      }
      throw error
    }
  }

  private func ensureWithinDeadline(_ deadline: TimeInterval) throws {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      throw AXWindowSystemError.deadlineExceeded
    }
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
    let error = copyAttributeValue(
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
