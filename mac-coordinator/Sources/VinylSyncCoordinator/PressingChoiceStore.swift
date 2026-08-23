import Foundation

final class PressingChoiceStore {
  private let lock = NSLock()
  private let url = ConfigStore.shared.stateFileURL("pressing-choices.json")
  private var choices: [String: Int]

  init() {
    if let data = try? Data(contentsOf: url),
       let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
      choices = stored
    } else {
      choices = [:]
    }
  }

  func releaseID(album: String, artist: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return choices[key(album: album, artist: artist)]
  }

  func remember(releaseID: Int, album: String, artist: String) {
    lock.lock()
    choices[key(album: album, artist: artist)] = releaseID
    let snapshot = choices
    lock.unlock()

    if let data = try? JSONEncoder().encode(snapshot) {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func key(album: String, artist: String) -> String {
    "\(normalize(artist))|\(normalize(album))"
  }

  private func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
