import AppKit

@MainActor
final class StatusItemController {
  private let statusItem: NSStatusItem
  private let onToggleOverlay: () -> Void
  private let onOpenSettings: () -> Void
  private let onRequestAccessibility: () -> Void

  init(
    onToggleOverlay: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onRequestAccessibility: @escaping () -> Void
  ) {
    self.onToggleOverlay = onToggleOverlay
    self.onOpenSettings = onOpenSettings
    self.onRequestAccessibility = onRequestAccessibility
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    configureButton()
    configureMenu()
  }

  private func configureButton() {
    guard let button = statusItem.button else {
      return
    }

    button.image = NSImage(
      systemSymbolName: "rectangle.stack.badge.magnifyingglass",
      accessibilityDescription: "Winnow"
    )
  }

  private func configureMenu() {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "Show Winnow",
        action: #selector(toggleOverlay),
        keyEquivalent: ""
      )
    )
    menu.addItem(
      NSMenuItem(
        title: "Accessibility Permission…",
        action: #selector(requestAccessibility),
        keyEquivalent: ""
      )
    )
    menu.addItem(
      NSMenuItem(
        title: "Settings…",
        action: #selector(openSettings),
        keyEquivalent: ","
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit Winnow",
        action: #selector(quit),
        keyEquivalent: "q"
      )
    )

    for item in menu.items {
      item.target = self
    }

    statusItem.menu = menu
  }

  @objc
  private func toggleOverlay() {
    onToggleOverlay()
  }

  @objc
  private func openSettings() {
    onOpenSettings()
  }

  @objc
  private func requestAccessibility() {
    onRequestAccessibility()
  }

  @objc
  private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
