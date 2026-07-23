import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let onToggleOverlay: () -> Void
  private let onOpenSettings: () -> Void
  private let onRequestAccessibility: () -> Void
  private let onDiscoverWindows: () async throws -> [WindowItem]
  private let onActivateWindow: (WindowItem) async -> Void
  private let debugWindowsMenu = NSMenu(title: "Debug Windows")
  private var debugWindows: [UUID: WindowItem] = [:]
  private var discoveryTask: Task<Void, Never>?

  init(
    onToggleOverlay: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onRequestAccessibility: @escaping () -> Void,
    onDiscoverWindows: @escaping () async throws -> [WindowItem],
    onActivateWindow: @escaping (WindowItem) async -> Void
  ) {
    self.onToggleOverlay = onToggleOverlay
    self.onOpenSettings = onOpenSettings
    self.onRequestAccessibility = onRequestAccessibility
    self.onDiscoverWindows = onDiscoverWindows
    self.onActivateWindow = onActivateWindow
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

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
    let debugWindowsItem = NSMenuItem(
      title: "Debug Windows",
      action: nil,
      keyEquivalent: ""
    )
    debugWindowsMenu.delegate = self
    debugWindowsItem.submenu = debugWindowsMenu
    menu.addItem(debugWindowsItem)
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

  nonisolated func menuWillOpen(_: NSMenu) {
    MainActor.assumeIsolated {
      refreshDebugWindows()
    }
  }

  private func refreshDebugWindows() {
    discoveryTask?.cancel()
    debugWindows.removeAll()
    replaceDebugMenu(withPlaceholder: "Loading…")

    discoveryTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        let windows = try await onDiscoverWindows()
        guard !Task.isCancelled else {
          return
        }
        replaceDebugMenu(with: windows)
      } catch {
        guard !Task.isCancelled else {
          return
        }

        if case WindowServiceError.accessibilityPermissionRequired = error {
          replaceDebugMenu(
            withPlaceholder: "Accessibility Permission Required"
          )
        } else {
          replaceDebugMenu(withPlaceholder: "Window Discovery Failed")
        }
      }
    }
  }

  private func replaceDebugMenu(with windows: [WindowItem]) {
    debugWindowsMenu.removeAllItems()
    debugWindows = Dictionary(
      uniqueKeysWithValues: windows.map { ($0.id, $0) }
    )

    guard !windows.isEmpty else {
      replaceDebugMenu(withPlaceholder: "No Windows Found")
      return
    }

    for window in windows {
      let item = NSMenuItem(
        title: "\(window.applicationName) — \(window.title)",
        action: #selector(activateDebugWindow(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = window.id.uuidString
      debugWindowsMenu.addItem(item)
    }
  }

  private func replaceDebugMenu(withPlaceholder title: String) {
    debugWindowsMenu.removeAllItems()
    let item = NSMenuItem(
      title: title,
      action: nil,
      keyEquivalent: ""
    )
    item.isEnabled = false
    debugWindowsMenu.addItem(item)
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
  private func activateDebugWindow(_ sender: NSMenuItem) {
    guard
      let rawIdentifier = sender.representedObject as? String,
      let identifier = UUID(uuidString: rawIdentifier),
      let window = debugWindows[identifier]
    else {
      return
    }

    Task {
      await onActivateWindow(window)
    }
  }

  @objc
  private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
