import OSLog

enum PrivacyLogger {
  static let app = Logger(
    subsystem: "app.winnow.Winnow",
    category: "application"
  )
  static let accessibility = Logger(
    subsystem: "app.winnow.Winnow",
    category: "accessibility"
  )

  static func windowFailure(processIdentifier: pid_t, code: Int) {
    accessibility.error(
      "Window operation failed pid=\(processIdentifier, privacy: .public) code=\(code, privacy: .public)"
    )
  }
}
