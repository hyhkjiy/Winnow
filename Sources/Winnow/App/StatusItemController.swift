import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let statusMenu = NSMenu()
  private let onToggleOverlay: () -> Void
  private let onOpenSettings: () -> Void
  private let onRequestAccessibility: () -> Void
  private let onRequestScreenCapture: () -> Void
  private let onDiscoverWindows: () async throws -> [WindowItem]
  private let onActivateWindow: (WindowItem) async -> Void
  private let debugWindowsMenu = NSMenu(title: "Debug Windows")
  private var debugWindows: [UUID: WindowItem] = [:]
  private var discoveryTask: Task<Void, Never>?

  init(
    onToggleOverlay: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onRequestAccessibility: @escaping () -> Void,
    onRequestScreenCapture: @escaping () -> Void,
    onDiscoverWindows: @escaping () async throws -> [WindowItem],
    onActivateWindow: @escaping (WindowItem) async -> Void
  ) {
    self.onToggleOverlay = onToggleOverlay
    self.onOpenSettings = onOpenSettings
    self.onRequestAccessibility = onRequestAccessibility
    self.onRequestScreenCapture = onRequestScreenCapture
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

    let image =
      NSImage(
        systemSymbolName: "rectangle.stack",
        accessibilityDescription: "Winnow"
      )
      ?? NSImage(
        systemSymbolName: "magnifyingglass",
        accessibilityDescription: "Winnow"
      )
    image?.isTemplate = true

    button.image = image
    button.toolTip = "Winnow"
    if image == nil {
      button.title = "W"
    }
    button.target = self
    button.action = #selector(showStatusMenu(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func configureMenu() {
    statusMenu.delegate = self
    statusMenu.addItem(
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
    debugWindowsItem.submenu = debugWindowsMenu
    statusMenu.addItem(debugWindowsItem)
    statusMenu.addItem(
      NSMenuItem(
        title: "Accessibility Permission…",
        action: #selector(requestAccessibility),
        keyEquivalent: ""
      )
    )
    statusMenu.addItem(
      NSMenuItem(
        title: "Screen Recording Permission…",
        action: #selector(requestScreenCapture),
        keyEquivalent: ""
      )
    )
    statusMenu.addItem(
      NSMenuItem(
        title: "Settings…",
        action: #selector(openSettings),
        keyEquivalent: ","
      )
    )
    statusMenu.addItem(.separator())
    statusMenu.addItem(
      NSMenuItem(
        title: "Quit Winnow",
        action: #selector(quit),
        keyEquivalent: "q"
      )
    )

    for item in statusMenu.items {
      item.target = self
    }
  }

  nonisolated func menuWillOpen(_ menu: NSMenu) {
    MainActor.assumeIsolated {
      guard menu === statusMenu else {
        return
      }
      refreshDebugWindows()
    }
  }

  private func refreshDebugWindows() {
    discoveryTask?.cancel()
    if debugWindowsMenu.items.isEmpty {
      replaceDebugMenu(withPlaceholder: "Loading…")
    }

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

  @objc
  private func showStatusMenu(_ button: NSStatusBarButton) {
    statusItem.menu = statusMenu
    button.performClick(nil)
    statusItem.menu = nil
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

    for entry in WindowMenuGrouping.entries(for: windows) {
      switch entry {
      case .window(let displayTitle, let window):
        debugWindowsMenu.addItem(
          debugWindowMenuItem(
            for: window,
            displayTitle: displayTitle
          )
        )
      case .application(let group):
        let applicationItem = NSMenuItem(
          title: "\(group.applicationName) (\(group.windows.count))",
          action: nil,
          keyEquivalent: ""
        )
        let windowsMenu = NSMenu(title: group.applicationName)

        for window in group.windows {
          let item = debugWindowMenuItem(for: window)
          windowsMenu.addItem(item)
        }

        applicationItem.submenu = windowsMenu
        debugWindowsMenu.addItem(applicationItem)
      }
    }
  }

  private func debugWindowMenuItem(
    for window: WindowItem,
    displayTitle: String? = nil
  ) -> NSMenuItem {
    let confidencePrefix: String
    switch window.discoveryConfidence {
    case .exact:
      confidencePrefix = ""
    case .probable:
      confidencePrefix = "≈ "
    case .inventoryOnly:
      confidencePrefix = "◇ "
    }
    let item = NSMenuItem(
      title: "\(confidencePrefix)\(displayTitle ?? window.title)",
      action: #selector(activateDebugWindow(_:)),
      keyEquivalent: ""
    )
    item.toolTip =
      window.accessibilityReference == nil
      ? "Discovered from the window inventory; exact focus will be recovered on selection."
      : "An Accessibility window reference is available."
    item.target = self
    item.representedObject = window.id.uuidString
    return item
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
  private func requestScreenCapture() {
    onRequestScreenCapture()
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
