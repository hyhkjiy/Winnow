import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
  var onRequestAccessibility: (() -> Void)?

  private let permissionClient: AccessibilityPermissionClient
  private let permissionLabel = NSTextField(labelWithString: "")

  init(permissionClient: AccessibilityPermissionClient) {
    self.permissionClient = permissionClient

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
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
        "Winnow needs Accessibility permission to discover and focus windows. "
        + "It does not request Screen Recording permission."
    )
    explanation.textColor = .secondaryLabelColor

    let permissionButton = NSButton(
      title: "Request Accessibility Permission",
      target: self,
      action: #selector(requestPermission)
    )
    permissionButton.bezelStyle = .rounded

    let stack = NSStackView(
      views: [title, explanation, permissionLabel, permissionButton]
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
    permissionLabel.stringValue =
      permissionClient.isTrusted
      ? "Accessibility: Granted"
      : "Accessibility: Not granted"
    permissionLabel.textColor = permissionClient.isTrusted ? .systemGreen : .systemOrange
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
}
