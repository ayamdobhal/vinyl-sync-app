import Foundation
import Security

final class ConfigStore {
  static let shared = ConfigStore()

  private struct StoredConfig: Codable {
    var spotifyClientId: String?
    var spotifyRedirectUri: String?
    var discogsUsername: String?
  }

  private let service = "dev.iamdobhal.vinyl-sync"
  private let lock = NSLock()
  private let configURL: URL
  private let environment: [String: String]
  private var stored: StoredConfig

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: ".state")
    let dir = base.appendingPathComponent("VinylSyncCoordinator", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    configURL = dir.appendingPathComponent("config.json")
    environment = loadEnvironment()
    if let data = try? Data(contentsOf: configURL),
       let config = try? JSONDecoder().decode(StoredConfig.self, from: data) {
      stored = config
    } else {
      stored = StoredConfig()
    }
  }

  func stateFileURL(_ name: String) -> URL {
    configURL.deletingLastPathComponent().appendingPathComponent(name)
  }

  var spotifyClientId: String {
    value(\.spotifyClientId, env: "SPOTIFY_CLIENT_ID") ?? ""
  }

  var spotifyClientSecret: String {
    keychainRead(account: "spotify-client-secret") ?? nonEmpty(environment["SPOTIFY_CLIENT_SECRET"]) ?? ""
  }

  var spotifyRedirectUri: String {
    value(\.spotifyRedirectUri, env: "VINYL_SYNC_SPOTIFY_REDIRECT_URI") ?? "http://127.0.0.1:4739/callback"
  }

  var discogsToken: String {
    keychainRead(account: "discogs-token") ?? nonEmpty(environment["DISCOGS_TOKEN"]) ?? ""
  }

  var discogsUsername: String {
    value(\.discogsUsername, env: "DISCOGS_USERNAME") ?? ""
  }

  func update(
    spotifyClientId: String?,
    spotifyClientSecret: String?,
    spotifyRedirectUri: String?,
    discogsToken: String?,
    discogsUsername: String?
  ) {
    lock.lock()
    if let spotifyClientId { stored.spotifyClientId = spotifyClientId }
    if let spotifyRedirectUri { stored.spotifyRedirectUri = spotifyRedirectUri }
    if let discogsUsername { stored.discogsUsername = discogsUsername }
    let snapshot = stored
    lock.unlock()
    if let data = try? JSONEncoder().encode(snapshot) {
      try? data.write(to: configURL)
    }
    if let spotifyClientSecret { keychainWrite(account: "spotify-client-secret", value: spotifyClientSecret) }
    if let discogsToken { keychainWrite(account: "discogs-token", value: discogsToken) }
  }

  private func value(_ keyPath: KeyPath<StoredConfig, String?>, env key: String) -> String? {
    lock.lock()
    let storedValue = stored[keyPath: keyPath]
    lock.unlock()
    return nonEmpty(storedValue) ?? nonEmpty(environment[key])
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private func keychainRead(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return nonEmpty(String(data: data, encoding: .utf8))
  }

  private func keychainWrite(account: String, value: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
    guard !value.isEmpty else { return }
    var attributes = query
    attributes[kSecValueData as String] = Data(value.utf8)
    SecItemAdd(attributes as CFDictionary, nil)
  }
}
