import Foundation
import XCTest

@testable import Winnow

final class WindowDiagnosticsTests: XCTestCase {
  func testSlowDiscoveryWritesFailedReportBeforeScanReturns() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try await WindowDiagnostics.writeReport(
      to: url, discovery: DiagnosticDiscovery(delay: 2_000_000_000), scanTimeout: 0.01
    )
    XCTAssertFalse(result)
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    XCTAssertEqual(report["status"] as? String, "failed")
    let samples = try XCTUnwrap(report["samples"] as? [[String: Any]])
    XCTAssertEqual(samples.count, 3)
    XCTAssertTrue(samples.allSatisfy { $0["error"] as? String == "scanTimedOut" })
  }

  func testUnwritableReportDestinationThrows() async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("missing/report.json")
    do {
      _ = try await WindowDiagnostics.writeReport(to: url, discovery: DiagnosticDiscovery(delay: 0))
      XCTFail("Missing destination directory must not be reported as successful")
    } catch {
      // The caller can fail the diagnostic process instead of silently succeeding.
    }
  }
}

private struct DiagnosticDiscovery: WindowDiscovering {
  let delay: UInt64

  func discoverWindows() async throws -> [WindowItem] {
    try await Task.sleep(nanoseconds: delay)
    return []
  }
}
