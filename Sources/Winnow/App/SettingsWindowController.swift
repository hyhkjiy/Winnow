import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
  var onRequestAccessibility: (() -> Void)?
  var onRequestScreenCapture: (() -> Void)?

  private let permissionClient: AccessibilityPermissionClient
  private let screenCapturePermissionClient: ScreenCapturePermissionClient
  private let accessibilityPermissionLabel = NSTextField(labelWithString: "")
  private let screenCapturePermissionLabel = NSTextField(labelWithString: "")

  init(
    permissionClient: AccessibilityPermissionClient,
    screenCapturePermissionClient: ScreenCapturePermissionClient
  ) {
    self.permissionClient = permissionClient
    self.screenCapturePermissionClient = screenCapturePermissionClient

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 310),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Winnow Settings"
    window.isReleasedWhenClosed = false

    super.init(window: window)
    configureContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show() {
    refreshPermissionStatus()
    window?.center()
    showWindow(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  private func configureContent() {
    let title = NSTextField(labelWithString: "Winnow")
    title.font = .systemFont(ofSize: 24, weight: .semibold)

    let explanation = NSTextField(
      wrappingLabelWithString:
        "Accessibility lets Winnow inspect and focus windows. Screen Recording "
        + "lets it discover more windows on other Spaces. Window data remains in memory."
    )
    explanation.textColor = .secondaryLabelColor

    let permissionButton = NSButton(
      title: "Request Accessibility Permission",
      target: self,
      action: #selector(requestPermission)
    )
    permissionButton.bezelStyle = .rounded

    let screenCaptureButton = NSButton(
      title: "Request Screen Recording Permission",
      target: self,
      action: #selector(requestScreenCapturePermission)
    )
    screenCaptureButton.bezelStyle = .rounded

    let stack = NSStackView(
      views: [
        title,
        explanation,
        accessibilityPermissionLabel,
        permissionButton,
        screenCapturePermissionLabel,
        screenCaptureButton,
      ]
    )
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false

    guard let contentView = window?.contentView else {
      return
    }

    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
    ])

    refreshPermissionStatus()
  }

  private func refreshPermissionStatus() {
    accessibilityPermissionLabel.stringValue =
      permissionClient.isTrusted
      ? "Accessibility: Granted"
      : "Accessibility: Not granted"
    accessibilityPermissionLabel.textColor =
      permissionClient.isTrusted ? .systemGreen : .systemOrange
    screenCapturePermissionLabel.stringValue =
      screenCapturePermissionClient.isGranted
      ? "Screen Recording: Granted"
      : "Screen Recording: Not granted"
    screenCapturePermissionLabel.textColor =
      screenCapturePermissionClient.isGranted ? .systemGreen : .systemOrange
  }

  @objc
  private func requestPermission() {
    if let onRequestAccessibility {
      onRequestAccessibility()
    } else {
      permissionClient.requestAccess()
    }
    refreshPermissionStatus()
  }

  @objc
  private func requestScreenCapturePermission() {
    if let onRequestScreenCapture {
      onRequestScreenCapture()
    } else {
      screenCapturePermissionClient.requestAccess()
    }
    refreshPermissionStatus()
  }
}
