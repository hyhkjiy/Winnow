import AppKit

@main
enum WinnowApp {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    if let option = CommandLine.arguments.firstIndex(of: "--diagnose-windows"),
      CommandLine.arguments.indices.contains(option + 1)
    {
      application.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          let succeeded = try await WindowDiagnostics.writeReport(
            to: URL(fileURLWithPath: CommandLine.arguments[option + 1])
          )
          exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
        } catch {
          PrivacyLogger.app.error("Could not write window diagnostic report")
          exit(EXIT_FAILURE)
        }
      }
      application.run()
      return
    }
    let delegate = AppDelegate()

    application.setActivationPolicy(.accessory)
    application.mainMenu = makeMainMenu(application: application)
    application.delegate = delegate
    application.run()

    withExtendedLifetime(delegate) {}
  }

  private static func makeMainMenu(application: NSApplication) -> NSMenu {
    let mainMenu = NSMenu()
    let applicationMenuItem = NSMenuItem()
    let applicationMenu = NSMenu()
    let quitItem = NSMenuItem(
      title: "Quit Winnow",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = application
    applicationMenu.addItem(quitItem)
    applicationMenuItem.submenu = applicationMenu
    mainMenu.addItem(applicationMenuItem)
    return mainMenu
  }
}
