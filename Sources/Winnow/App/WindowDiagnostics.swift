import AppKit
import ApplicationServices

/// Runs inside the signed bundle via LaunchServices, under the app's actual TCC identity.
/// The report contains counts and timing only, never window titles or application names.
@MainActor
enum WindowDiagnostics {
  static func writeReport(
    to url: URL,
    discovery suppliedDiscovery: (any WindowDiscovering)? = nil,
    scanTimeout: TimeInterval = 3
  ) async throws -> Bool {
    let discovery = suppliedDiscovery ?? AXWindowDiscovery(
      inventoryClient: LiveWindowInventoryClient(
        permissionClient: ScreenCapturePermissionClient()
      )
    )
    var samples: [[String: Any]] = []
    var previousIDs: Set<UUID> = []
    var lastTick = ProcessInfo.processInfo.systemUptime
    var maximumTickGap = 0.0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
      let now = ProcessInfo.processInfo.systemUptime
      maximumTickGap = max(maximumTickGap, now - lastTick)
      lastTick = now
    }
    for index in 0..<3 {
      let start = ProcessInfo.processInfo.systemUptime
      do {
        let scanReport = try await withDeadline(seconds: scanTimeout) {
          try await discovery.discoverReportForPresentation()
        }
        let windows = scanReport.windows
        let ids = Set(windows.map(\.id))
        let serverKeys = windows.compactMap { window in
          window.windowServerIdentifier.map { "\(window.processIdentifier):\($0)" }
        }
        samples.append([
          "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
          "count": windows.count,
          "unavailableApplicationCount": scanReport.unavailableApplicationCount,
          "exactIdentityCount": windows.filter { $0.discoveryConfidence == .exact }.count,
          "staleWindowCount": windows.filter { $0.discoveryFreshness != .fresh }.count,
          "duplicateIdentityCount": serverKeys.count - Set(serverKeys).count,
          "retainedIDsFromPreviousSample": index == 0 ? 0 : ids.intersection(previousIDs).count,
        ])
        previousIDs = ids
      } catch {
        samples.append([
          "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
          "error": String(describing: error),
        ])
      }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    timer.invalidate()
    let hasErrors = samples.contains { $0["error"] != nil }
    let hasPartialResults = samples.contains { ($0["unavailableApplicationCount"] as? Int ?? 0) > 0 }
    let succeeded = !hasErrors && !hasPartialResults
    let report: [String: Any] = [
      "status": hasErrors ? "failed" : (hasPartialResults ? "partial" : "passed"),
      "accessibilityTrusted": AXIsProcessTrusted(),
      "executable": Bundle.main.executablePath ?? "unknown",
      "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
      "maximumMainRunLoopTickGapMilliseconds": maximumTickGap * 1000,
      "samples": samples,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    return succeeded
  }

  private static func withDeadline(
    seconds: TimeInterval,
    operation: @escaping @MainActor () async throws -> WindowDiscoveryReport
  ) async throws -> WindowDiscoveryReport {
    try await withCheckedThrowingContinuation { continuation in
      let completion = DiagnosticCompletion(continuation)
      Task {
        do { completion.resolve(.success(try await operation())) }
        catch { completion.resolve(.failure(error)) }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        completion.resolve(.failure(DiagnosticError.scanTimedOut))
      }
    }
  }
}

private enum DiagnosticError: Error { case scanTimedOut }

@MainActor
private final class DiagnosticCompletion {
  private var continuation: CheckedContinuation<WindowDiscoveryReport, Error>?

  init(_ continuation: CheckedContinuation<WindowDiscoveryReport, Error>) {
    self.continuation = continuation
  }

  func resolve(_ result: Result<WindowDiscoveryReport, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}
