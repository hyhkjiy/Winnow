import Combine
import Foundation

@MainActor
final class SearchSession: ObservableObject {
  @Published var query = ""
  @Published private(set) var allWindows: [WindowItem] = []

  var filteredWindows: [WindowItem] {
    WindowFilter.filter(allWindows, query: query)
  }

  func replaceWindows(with windows: [WindowItem]) {
    allWindows = windows
  }

  func reset() {
    query = ""
  }
}

enum WindowFilter {
  static func filter(_ windows: [WindowItem], query: String) -> [WindowItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
      return windows
    }

    return windows.filter { window in
      window.applicationName.localizedCaseInsensitiveContains(normalizedQuery)
        || window.title.localizedCaseInsensitiveContains(normalizedQuery)
    }
  }
}
