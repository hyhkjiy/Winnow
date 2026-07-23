import AppKit

@MainActor
final class OverlayCoordinator {
  private struct PanelEntry {
    let panel: SearchPanel
    let controller: SearchPanelViewController
  }

  private let session: SearchSession
  private var panels: [CGDirectDisplayID: PanelEntry] = [:]
  private var screenObserver: NSObjectProtocol?
  private(set) var isVisible = false

  init(session: SearchSession) {
    self.session = session
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.isVisible == true else {
          return
        }
        self?.show()
      }
    }
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    hidePanels(resetSession: false)
    isVisible = true

    let screens = NSScreen.screens
    guard !screens.isEmpty else {
      return
    }

    let primaryScreen = screenContainingMouse(in: screens) ?? screens[0]
    for screen in screens {
      let entry = makePanel(for: screen)
      panels[screen.displayID] = entry
      entry.panel.orderFrontRegardless()
    }

    promotePrimary(displayID: primaryScreen.displayID)
  }

  func hide() {
    hidePanels(resetSession: true)
  }

  private func hidePanels(resetSession: Bool) {
    for entry in panels.values {
      entry.panel.orderOut(nil)
      entry.panel.close()
    }
    panels.removeAll()
    isVisible = false

    if resetSession {
      session.reset()
    }
  }

  private func makePanel(for screen: NSScreen) -> PanelEntry {
    let size = NSSize(width: min(680, screen.visibleFrame.width - 80), height: 150)
    let origin = NSPoint(
      x: screen.visibleFrame.midX - size.width / 2,
      y: screen.visibleFrame.midY - size.height / 2
    )
    let frame = NSRect(origin: origin, size: size)

    let panel = SearchPanel(
      contentRect: frame,
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false

    let controller = SearchPanelViewController(session: session)
    controller.onRequestPrimary = { [weak self] in
      self?.promotePrimary(displayID: screen.displayID)
    }
    panel.contentViewController = controller

    return PanelEntry(panel: panel, controller: controller)
  }

  private func promotePrimary(displayID: CGDirectDisplayID) {
    for (candidateDisplayID, entry) in panels {
      let isPrimary = candidateDisplayID == displayID
      entry.controller.setPrimary(isPrimary)

      if isPrimary {
        entry.panel.makeKeyAndOrderFront(nil)
        entry.controller.focusSearchField()
      }
    }
  }

  private func screenContainingMouse(in screens: [NSScreen]) -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return screens.first { $0.frame.contains(mouseLocation) }
  }
}

extension NSScreen {
  fileprivate var displayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }
}
