import CryptoKit
import Foundation
import Network

struct SpotifyStatus {
  var configured = false
  var authenticated = false
  var user = "--"
  var image = ""
  var targetDevice = "Not selected"
  var lastAction = "waiting"
  var error = ""
}

struct SpotifyTrackResolution {
  var uri: String
  var title: String
  var artist: String
  var durationSeconds: Double
  var albumId: String
  var albumName: String
  var albumArtists: String
  var albumImage: String
}

final class SpotifyClient {
  private struct Token: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
  }

  private var clientId: String { ConfigStore.shared.spotifyClientId }
  private var clientSecret: String { ConfigStore.shared.spotifyClientSecret }
  private var redirectUri: String { ConfigStore.shared.spotifyRedirectUri }
  private var targetDeviceIdValue: String { ConfigStore.shared.spotifyTargetDeviceId }
  private var targetDeviceName: String { ConfigStore.shared.spotifyTargetDeviceName }
  private let tokenURL = ConfigStore.shared.stateFileURL("spotify-token.json")
  private let lock = NSLock()
  private var token: Token?
  private var user = "--"
  private var image = ""
  private var lastAction = "waiting"
  private var lastError = ""

  init() {
    token = Self.loadToken(from: tokenURL)
      ?? Self.loadToken(from: URL(fileURLWithPath: ".state/spotify-token.json"))
    if token != nil {
      _ = refreshIfNeeded()
      loadProfile()
    }
  }

  var isConfigured: Bool {
    !clientId.isEmpty && !clientSecret.isEmpty
  }

  var redirectUriValue: String {
    redirectUri
  }

  func status() -> SpotifyStatus {
    lock.lock()
    let copy = SpotifyStatus(
      configured: isConfigured,
      authenticated: token != nil,
      user: user,
      image: image,
      targetDevice: targetDeviceName.isEmpty ? "Not selected" : targetDeviceName,
      lastAction: lastAction,
      error: lastError
    )
    lock.unlock()
    return copy
  }

  func loginURL() -> URL? {
    guard isConfigured else { return nil }
    var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "scope", value: "user-read-playback-state user-modify-playback-state user-read-currently-playing")
    ]
    return components.url
  }

  func handleCallback(code: String) throws {
    let body = formEncoded([
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectUri
    ])
    let data = try tokenRequest(body: body)
    let accessToken = data["access_token"] as? String ?? ""
    let refreshToken = data["refresh_token"] as? String ?? ""
    let expiresIn = data["expires_in"] as? Double ?? 3600
    guard !accessToken.isEmpty, !refreshToken.isEmpty else {
      throw NSError(domain: "Spotify", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spotify did not return tokens."])
    }
    save(Token(accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(expiresIn - 60)))
    loadProfile()
  }

  func trackURI(isrc: String, title: String, artist: String) throws -> String {
    try trackResolution(isrc: isrc, title: title, artist: artist).uri
  }

  func trackResolution(isrc: String, title: String, artist: String,
                       preferredAlbumID: String = "", ownedAlbums: Set<String> = []) throws -> SpotifyTrackResolution {
    func search(_ query: String) throws -> [[String: Any]] {
      let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      let encoded = query.addingPercentEncoding(withAllowedCharacters: characters) ?? query
      let json = try api("GET", "/search?q=\(encoded)&type=track&limit=5")
      return ((json["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    }
    func normalized(_ value: String) -> String {
      value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    var items = isrc.isEmpty ? [] : try search("isrc:\(isrc)")
    if items.isEmpty {
      items = try search("track:\"\(title)\" artist:\"\(artist)\"").filter { track in
        normalized(track["name"] as? String ?? "") == normalized(title)
          && ((track["artists"] as? [[String: Any]]) ?? []).contains {
            normalized($0["name"] as? String ?? "") == normalized(artist)
          }
      }
    }
    guard let track = SpotifyAlbumPreference.select(items, preferredAlbumID: preferredAlbumID, ownedAlbums: ownedAlbums),
          let uri = track["uri"] as? String, !uri.isEmpty else {
      throw NSError(
        domain: "Spotify",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Spotify track not found for \(artist) — \(title)."]
      )
    }
    let album = track["album"] as? [String: Any] ?? [:]
    let trackArtists = ((track["artists"] as? [[String: Any]]) ?? [])
      .compactMap { $0["name"] as? String }
      .joined(separator: ", ")
    let albumArtists = ((album["artists"] as? [[String: Any]]) ?? [])
      .compactMap { $0["name"] as? String }
      .joined(separator: ", ")
    return SpotifyTrackResolution(
      uri: uri,
      title: track["name"] as? String ?? title,
      artist: trackArtists.isEmpty ? artist : trackArtists,
      durationSeconds: Double(track["duration_ms"] as? Int ?? 0) / 1000,
      albumId: album["id"] as? String ?? "",
      albumName: album["name"] as? String ?? "",
      albumArtists: albumArtists,
      albumImage: (((album["images"] as? [[String: Any]]) ?? []).first?["url"] as? String) ?? ""
    )
  }

  func devices() throws -> [[String: Any]] {
    let json = try api("GET", "/me/player/devices")
    let devices = json["devices"] as? [[String: Any]] ?? []
    return devices.map {
      [
        "id": $0["id"] as? String ?? "",
        "name": $0["name"] as? String ?? "Unknown device",
        "type": $0["type"] as? String ?? "",
        "isActive": $0["is_active"] as? Bool ?? false,
        "isRestricted": $0["is_restricted"] as? Bool ?? false
      ]
    }
  }

  func play(uri: String, albumId: String, position: PlaybackPosition, reason: String,
            isCurrent: @escaping () -> Bool) {
    // User-calibrated lead, separate from measured request preparation time.
    let playbackLeadSeconds = 1.0
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        guard isCurrent() else { return }
        let deviceId = try self.targetDeviceId()
        guard isCurrent() else { return }
        _ = try self.api("PUT", "/me/player/volume?volume_percent=0&device_id=\(deviceId)", emptyOK: true)
        var sentAt: TimeInterval = 0
        var sentPosition: Double = 0
        // Construct the body after token refresh and all preparation requests.
        _ = try self.api("PUT", "/me/player/play?device_id=\(deviceId)", emptyOK: true, makeBody: {
          guard isCurrent() else { throw CancellationError() }
          sentAt = ProcessInfo.processInfo.systemUptime
          sentPosition = position.seconds(at: sentAt) + playbackLeadSeconds
          return try JSONSerialization.data(withJSONObject: [
            "context_uri": "spotify:album:\(albumId)",
            "offset": ["uri": uri], "position_ms": Int(sentPosition * 1000)
          ])
        })
        let responseAt = ProcessInfo.processInfo.systemUptime
        guard isCurrent() else { return }
        let timing = String(format: "advanced %.2fs; lead +%.1fs; play request %.2fs",
                            max(0, sentAt - position.observedUptime), playbackLeadSeconds, responseAt - sentAt)
        self.setAction("play requested \(reason) · \(timing)", error: "")
        print("Spotify timing: \(timing), target \(sentPosition)s")
        // A reported progress value is diagnostic, not proof of audible alignment.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
          guard isCurrent() else { return }
          do {
            let before = ProcessInfo.processInfo.systemUptime
            let playback = try self.api("GET", "/me/player")
            let after = ProcessInfo.processInfo.systemUptime
            guard isCurrent() else { return }
            guard playback["is_playing"] as? Bool == true,
                  (playback["item"] as? [String: Any])?["uri"] as? String == uri,
                  (playback["device"] as? [String: Any])?["id"] as? String == deviceId,
                  let progressMs = playback["progress_ms"] as? Int else {
              self.setAction("playback not confirmed", error: "Spotify accepted the request but did not report the requested track playing on the target device. Try Resync.")
              return
            }
            let progress = Double(progressMs) / 1000
            let lag = position.seconds(at: (before + after) / 2) + playbackLeadSeconds - progress
            let diagnostic = String(format: "target lag %+.2fs (poll ±%.2fs)", lag, (after - before) / 2)
            self.setAction("playing \(reason) · \(timing) · \(diagnostic)", error: "")
            print("Spotify timing: \(diagnostic); positive = Spotify behind lead-adjusted target")
          } catch {
            // Diagnostic failure must not label successful playback as failed.
            if isCurrent() { self.setAction("playback unverified", error: "Could not verify Spotify playback: \(error.localizedDescription)") }
            print("Spotify timing: playback-state check unavailable")
          }
        }
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent() else { return }
        self.setAction("play failed", error: error.localizedDescription)
      }
    }
  }

  private func targetDeviceId() throws -> String {
    let devices = try devices()
    if !targetDeviceIdValue.isEmpty,
       let exact = devices.first(where: { ($0["id"] as? String) == targetDeviceIdValue }),
       let id = exact["id"] as? String {
      return id
    }
    if !targetDeviceName.isEmpty,
       let exact = devices.first(where: { ($0["name"] as? String) == targetDeviceName }),
       let id = exact["id"] as? String {
      return id
    }
    if targetDeviceIdValue.isEmpty, targetDeviceName.isEmpty,
       let active = devices.first(where: { ($0["isActive"] as? Bool) == true }),
       let id = active["id"] as? String {
      return id
    }
    let requested = targetDeviceName.isEmpty ? "selected device" : targetDeviceName
    throw NSError(domain: "Spotify", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spotify \(requested) is unavailable. Open Spotify on the target device or choose another device in Settings."])
  }

  private func loadProfile() {
    do {
      let me = try api("GET", "/me")
      lock.lock()
      user = me["display_name"] as? String ?? me["id"] as? String ?? "--"
      image = ((me["images"] as? [[String: Any]]) ?? []).first?["url"] as? String ?? ""
      lastError = ""
      lock.unlock()
    } catch {
      setAction("profile failed", error: error.localizedDescription)
    }
  }

  private func refreshIfNeeded() -> Bool {
    lock.lock()
    let current = token
    lock.unlock()
    guard let current else { return false }
    guard current.expiresAt <= Date() else { return true }

    do {
      let body = formEncoded([
        "grant_type": "refresh_token",
        "refresh_token": current.refreshToken
      ])
      let data = try tokenRequest(body: body)
      let accessToken = data["access_token"] as? String ?? ""
      let refreshToken = data["refresh_token"] as? String ?? current.refreshToken
      let expiresIn = data["expires_in"] as? Double ?? 3600
      guard !accessToken.isEmpty else { return false }
      save(Token(accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(expiresIn - 60)))
      return true
    } catch {
      setAction("refresh failed", error: error.localizedDescription)
      return false
    }
  }

  private func api(_ method: String, _ path: String, body: Data? = nil, emptyOK: Bool = false, makeBody: (() throws -> Data)? = nil) throws -> [String: Any] {
    guard refreshIfNeeded() else {
      throw NSError(domain: "Spotify", code: 3, userInfo: [NSLocalizedDescriptionKey: "Spotify is not connected."])
    }
    lock.lock()
    let accessToken = token?.accessToken ?? ""
    lock.unlock()

    var request = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)")!)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let body = try makeBody?() ?? body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try send(request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let text = String(data: data, encoding: .utf8) ?? "Spotify HTTP \(status)"
      throw NSError(domain: "Spotify", code: status, userInfo: [NSLocalizedDescriptionKey: text])
    }
    if data.isEmpty || emptyOK { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func tokenRequest(body: Data) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
    request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

    let (data, response) = try send(request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let text = String(data: data, encoding: .utf8) ?? "Spotify token HTTP \(status)"
      throw NSError(domain: "Spotify", code: status, userInfo: [NSLocalizedDescriptionKey: text])
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, URLResponse), Error>!
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        result = .failure(error)
      } else {
        result = .success((data ?? Data(), response ?? URLResponse()))
      }
      semaphore.signal()
    }.resume()
    semaphore.wait()
    return try result.get()
  }

  private func save(_ newToken: Token) {
    lock.lock()
    token = newToken
    lock.unlock()
    try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(newToken) {
      try? data.write(to: tokenURL)
    }
  }

  func reportResolutionFailure(_ error: Error) {
    setAction("track lookup failed", error: error.localizedDescription)
  }

  private func setAction(_ action: String, error: String) {
    lock.lock()
    lastAction = action
    lastError = error
    lock.unlock()
  }

  private static func loadToken(from url: URL) -> Token? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Token.self, from: data)
  }
}

struct DiscogsStatus {
  var configured = false
  var user = ""
  var error = ""
}

final class DiscogsClient {
  private var token: String { ConfigStore.shared.discogsToken }
  private var username: String { ConfigStore.shared.discogsUsername }
  private let lock = NSLock()
  private var lastError = ""
  private var cachedCollection: [[String: Any]] = []
  private var cachedCollectionAt = Date.distantPast
  private var cachedCollectionUsername = ""

  func status() -> DiscogsStatus {
    lock.lock()
    let error = lastError
    lock.unlock()
    return DiscogsStatus(configured: !token.isEmpty && !username.isEmpty, user: username, error: error)
  }

  func collection() throws -> [[String: Any]] {
    guard !token.isEmpty, !username.isEmpty else {
      throw NSError(domain: "Discogs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configure a Discogs username and token."])
    }

    lock.lock()
    let cached = cachedCollection
    let cacheAge = Date().timeIntervalSince(cachedCollectionAt)
    lock.unlock()
    let cacheMatchesUser = cachedCollectionUsername == username
    if !cached.isEmpty, cacheAge < 600, cacheMatchesUser { return cached }

    var page = 1
    var releases: [[String: Any]] = []

    while page <= 10 {
      let json = try api("/users/\(username)/collection/folders/0/releases?per_page=100&page=\(page)&sort=artist&sort_order=asc")
      let items = json["releases"] as? [[String: Any]] ?? []
      releases.append(contentsOf: items.compactMap(collectionItem))

      let pagination = json["pagination"] as? [String: Any]
      let pages = pagination?["pages"] as? Int ?? page
      if page >= pages { break }
      page += 1
    }

    lock.lock()
    cachedCollection = releases
    cachedCollectionAt = Date()
    cachedCollectionUsername = username
    lastError = ""
    lock.unlock()
    return releases
  }

  func ownedAlbumKeys() throws -> Set<String> {
    Set(try collection().map {
      SpotifyAlbumPreference.key(title: $0["title"] as? String ?? "", artist: $0["artists"] as? String ?? "")
    })
  }

  func matchOwnedRelease(album: String, artist: String, preferredReleaseID: Int? = nil) throws -> [String: Any]? {
    guard !album.isEmpty else { return nil }
    let releases = try collection()
    let wantedAlbum = normalized(album)
    let wantedArtist = normalized(artist)
    let titleMatches = releases.filter { normalized($0["title"] as? String ?? "") == wantedAlbum }
    let exact = titleMatches.filter {
      let releaseArtist = normalized($0["artists"] as? String ?? "")
      return wantedArtist.isEmpty || releaseArtist == wantedArtist
        || releaseArtist.contains(wantedArtist) || wantedArtist.contains(releaseArtist)
    }
    let candidates = exact.isEmpty ? titleMatches : exact
    if let preferredReleaseID,
       var preferred = candidates.first(where: { $0["id"] as? Int == preferredReleaseID }) {
      preferred["ambiguous"] = false
      preferred["candidateCount"] = candidates.count
      preferred["confidence"] = "remembered"
      return preferred
    }
    guard candidates.count == 1, var result = candidates.first else {
      return candidates.isEmpty ? nil : [
        "ambiguous": true,
        "candidateCount": candidates.count,
        "album": album,
        "artist": artist,
        "candidates": candidates
      ]
    }
    result["ambiguous"] = false
    result["candidateCount"] = 1
    result["confidence"] = exact.isEmpty ? "title" : "exact"
    return result
  }

  func release(id: Int) throws -> [String: Any] {
    guard !token.isEmpty else {
      throw NSError(domain: "Discogs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing DISCOGS_TOKEN."])
    }

    let json = try api("/releases/\(id)")
    let title = json["title"] as? String ?? "Discogs release"
    let artists = json["artists_sort"] as? String
      ?? ((json["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
    let image = ((json["images"] as? [[String: Any]]) ?? []).first?["uri"] as? String
      ?? json["thumb"] as? String
      ?? ""
    let tracklist = json["tracklist"] as? [[String: Any]] ?? []
    var sides: [String: [[String: Any]]] = [:]
    var sideOrder: [String] = []

    for item in tracklist {
      guard (item["type_"] as? String ?? "track") == "track" else { continue }
      let position = item["position"] as? String ?? ""
      let side = sideKey(position)
      guard !side.isEmpty else { continue }
      if sides[side] == nil {
        sides[side] = []
        sideOrder.append(side)
      }
      sides[side]?.append([
        "position": position,
        "title": item["title"] as? String ?? "Untitled",
        "durationSeconds": parseDuration(item["duration"] as? String ?? ""),
        "uri": ""
      ])
    }

    setError("")
    return [
      "id": id,
      "name": title,
      "artists": artists,
      "image": image,
      "sides": sides,
      "sideOrder": sideOrder
    ]
  }

  private func collectionItem(_ item: [String: Any]) -> [String: Any]? {
    guard let basic = item["basic_information"] as? [String: Any] else { return nil }
    let id = basic["id"] as? Int ?? item["id"] as? Int ?? 0
    guard id > 0 else { return nil }
    let artists = ((basic["artists"] as? [[String: Any]]) ?? []).compactMap { artist in
      (artist["name"] as? String)?.replacingOccurrences(of: " \\(\\d+\\)$", with: "", options: .regularExpression)
    }.joined(separator: ", ")
    return [
      "id": id,
      "title": basic["title"] as? String ?? "Untitled",
      "artists": artists,
      "year": basic["year"] as? Int ?? 0,
      "thumb": basic["thumb"] as? String ?? basic["cover_image"] as? String ?? "",
      "country": basic["country"] as? String ?? "",
      "labels": ((basic["labels"] as? [[String: Any]]) ?? []).map {
        ["name": $0["name"] as? String ?? "", "catalogNumber": $0["catno"] as? String ?? ""]
      },
      "formats": ((basic["formats"] as? [[String: Any]]) ?? []).map {
        [
          "name": $0["name"] as? String ?? "",
          "quantity": $0["qty"] as? String ?? "",
          "text": $0["text"] as? String ?? "",
          "descriptions": $0["descriptions"] as? [String] ?? []
        ] as [String: Any]
      },
      "resourceURL": basic["resource_url"] as? String ?? ""
    ]
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: "\\s*\\(\\d+\\)$", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func api(_ path: String) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.discogs.com\(path)")!)
    request.httpMethod = "GET"
    request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
    request.setValue("VinylSync/0.1 +https://iamdobhal.dev", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, URLResponse), Error>!
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        result = .failure(error)
      } else {
        result = .success((data ?? Data(), response ?? URLResponse()))
      }
      semaphore.signal()
    }.resume()
    semaphore.wait()

    let (data, response) = try result.get()
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let text = String(data: data, encoding: .utf8) ?? "Discogs HTTP \(status)"
      setError(text)
      throw NSError(domain: "Discogs", code: status, userInfo: [NSLocalizedDescriptionKey: text])
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func sideKey(_ position: String) -> String {
    let trimmed = position.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, first.isLetter else { return "" }
    return String(first).uppercased()
  }

  private func parseDuration(_ duration: String) -> Double {
    let parts = duration.split(separator: ":").compactMap { Double($0) }
    if parts.count == 2 {
      return parts[0] * 60 + parts[1]
    }
    if parts.count == 3 {
      return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
    return 0
  }

  private func setError(_ value: String) {
    lock.lock()
    lastError = value
    lock.unlock()
  }
}

func loadEnvironment() -> [String: String] {
  var values = ProcessInfo.processInfo.environment
  for path in [
    ".env",
    "../.env"
  ] {
    guard let text = try? String(contentsOfFile: path) else { continue }
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
            let equals = trimmed.firstIndex(of: "=") else { continue }
      let key = String(trimmed[..<equals])
      let value = String(trimmed[trimmed.index(after: equals)...])
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      values[key] = values[key] ?? value
    }
  }
  return values
}

func formEncoded(_ values: [String: String]) -> Data {
  let body = values.map { key, value in
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    return "\(encodedKey)=\(encodedValue)"
  }.joined(separator: "&")
  return Data(body.utf8)
}

struct AudioSnapshot {
  var audioConnected = false
  var lastDeviceName = "none"
  var sampleRate = 0
  var frameCount: UInt64 = 0
  var streamSeconds: Double = 0
  var rms: Float = 0
  var lastSeen = Date.distantPast
  var lastBufferUptime: TimeInterval = 0
  var lastSoundUptime: TimeInterval = 0
}

final class AudioStateStore {
  let silenceThreshold: Double = 0.00045

  private let lock = NSLock()
  private var snapshot = AudioSnapshot()

  func receiveHello(deviceName: String, sampleRate: Int) {
    lock.lock()
    snapshot.audioConnected = true
    snapshot.lastDeviceName = deviceName
    snapshot.sampleRate = sampleRate
    snapshot.frameCount = 0
    snapshot.streamSeconds = 0
    snapshot.rms = 0
    snapshot.lastSeen = Date()
    snapshot.lastBufferUptime = ProcessInfo.processInfo.systemUptime
    snapshot.lastSoundUptime = snapshot.lastBufferUptime
    lock.unlock()
  }

  func receiveAudio(sampleCount: Int, rms: Float) {
    lock.lock()
    snapshot.audioConnected = true
    snapshot.frameCount += UInt64(sampleCount)
    if snapshot.sampleRate > 0 {
      snapshot.streamSeconds = Double(snapshot.frameCount) / Double(snapshot.sampleRate)
    }
    snapshot.rms = rms
    snapshot.lastBufferUptime = ProcessInfo.processInfo.systemUptime
    if rms > Float(silenceThreshold) { snapshot.lastSoundUptime = snapshot.lastBufferUptime }
    snapshot.lastSeen = Date()
    lock.unlock()
  }

  func disconnectAudio() {
    lock.lock()
    snapshot.audioConnected = false
    snapshot.rms = 0
    snapshot.lastSeen = Date()
    lock.unlock()
  }

  func currentSnapshot() -> AudioSnapshot {
    lock.lock()
    let value = snapshot
    lock.unlock()
    return value
  }
}

final class CoordinatorServer {
  private let port: NWEndpoint.Port
  private let listener: NWListener
  private let state = AudioStateStore()
  private let spotify = SpotifyClient()
  private let discogs = DiscogsClient()
  private let pressingChoices = PressingChoiceStore()
  private lazy var shazam = ShazamRecognizer { [weak self] match, isNewTrack in
    self?.handleShazamMatch(match, isNewTrack: isNewTrack)
  }
  private let offsetTracker = PlaybackOffsetTracker()
  private let shazamPlaybackLock = NSLock()
  private var currentShazamPlaybackID = ""
  private var currentShazamPlaybackURI = ""
  private var currentShazamPlaybackAlbumID = ""
  private let metadataLock = NSLock()
  private var resolvedTrackPayload: [String: Any]?
  private var pressingState = "waiting"
  private var pressingMatch: [String: Any]?
  private var pressingError = ""

  init(port: UInt16) throws {
    self.port = NWEndpoint.Port(rawValue: port)!
    self.listener = try NWListener(using: .tcp, on: self.port)
  }

  func start() {
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global(qos: .userInitiated))
      self.readHTTP(connection: connection)
    }
    listener.start(queue: .global(qos: .userInitiated))
    print("vinyl-sync coordinator listening on http://0.0.0.0:\(port.rawValue)")
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.expireInactivePlayback()
    }
    RunLoop.main.run()
  }

  private func readHTTP(connection: NWConnection) {
    var buffer = Data()

    func receiveMore() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if let error {
          self.respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
          return
        }

        if let data {
          buffer.append(data)
        }

        if let request = HTTPRequest(data: buffer) {
          self.handle(request: request, connection: connection)
          return
        }

        if isComplete {
          self.respondJSON(connection: connection, status: 400, body: ["error": "Malformed HTTP request."])
          return
        }

        receiveMore()
      }
    }

    receiveMore()
  }

  private func handle(request: HTTPRequest, connection: NWConnection) {
    if request.method == "GET", request.path == "/" {
      respondHTML(connection: connection, body: pageHTML())
      return
    }

    if request.method == "GET", request.path == "/favicon.svg" {
      respond(connection: connection, status: 200, contentType: "image/svg+xml", body: Data(faviconSVG().utf8))
      return
    }

    if request.method == "GET", request.path == "/status" {
      let snapshot = state.currentSnapshot()
      respondJSON(connection: connection, status: 200, body: statusPayload(snapshot))
      return
    }

    if request.method == "GET", request.path == "/api/config" {
      respondJSON(connection: connection, status: 200, body: configPayload())
      return
    }

    if request.method == "POST", request.path == "/api/config" {
      guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
        respondJSON(connection: connection, status: 400, body: ["error": "Missing config payload."])
        return
      }
      let field = { (key: String) -> String? in
        (json[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      }
      // Empty secrets mean "keep the stored value" so the form can be saved without retyping them.
      ConfigStore.shared.update(
        spotifyClientId: field("spotifyClientId"),
        spotifyClientSecret: field("spotifyClientSecret").flatMap { $0.isEmpty ? nil : $0 },
        spotifyRedirectUri: field("spotifyRedirectUri"),
        spotifyTargetDeviceId: field("spotifyTargetDeviceId"),
        spotifyTargetDeviceName: field("spotifyTargetDeviceName"),
        discogsToken: field("discogsToken").flatMap { $0.isEmpty ? nil : $0 },
        discogsUsername: field("discogsUsername")
      )
      respondJSON(connection: connection, status: 200, body: configPayload())
      return
    }

    if request.method == "GET", request.path == "/spotify/login" {
      guard let url = spotify.loginURL() else {
        respondJSON(connection: connection, status: 400, body: ["error": "Missing Spotify config."])
        return
      }
      respondRedirect(connection: connection, url: url.absoluteString)
      return
    }

    if request.method == "GET", request.path == "/spotify/devices" {
      do {
        respondJSON(connection: connection, status: 200, body: ["devices": try spotify.devices()])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "GET", request.path == "/callback" {
      guard let code = request.query["code"] else {
        respondHTML(connection: connection, body: "<p>Missing Spotify callback code.</p>")
        return
      }
      do {
        try spotify.handleCallback(code: code)
        respondRedirect(connection: connection, url: "/")
      } catch {
        respondHTML(connection: connection, body: "<p>Spotify connection failed: \(escapeHTML(error.localizedDescription))</p>")
      }
      return
    }

    if request.method == "POST", request.path == "/sync/resync" {
      guard let match = shazam.status().lastMatch else {
        respondJSON(connection: connection, status: 409, body: ["error": "No confirmed Shazam match to resync."])
        return
      }
      resetOffsetTracking()
      handleShazamMatch(match, isNewTrack: true)
      respondJSON(connection: connection, status: 200, body: ["ok": true])
      return
    }

    if request.method == "POST", request.path == "/sync/wrong-match" {
      shazam.rejectCurrentMatch()
      resetOffsetTracking()
      respondJSON(connection: connection, status: 200, body: ["ok": true])
      return
    }

    if request.method == "POST", request.path == "/discogs/select-pressing" {
      do {
        guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let releaseID = json["releaseId"] as? Int else {
          respondJSON(connection: connection, status: 400, body: ["error": "Missing Discogs release ID."])
          return
        }
        try selectPressing(releaseID: releaseID)
        respondJSON(connection: connection, status: 200, body: ["ok": true])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "GET",
       request.path == "/audio",
       request.headers["upgrade"]?.lowercased() == "websocket",
       let key = request.headers["sec-websocket-key"] {
      upgradeToWebSocket(connection: connection, key: key)
      return
    }

    respondJSON(connection: connection, status: 404, body: ["error": "Not found."])
  }

  private func upgradeToWebSocket(connection: NWConnection, key: String) {
    let accept = webSocketAccept(key)
    var response = "HTTP/1.1 101 Switching Protocols\r\n"
    response += "Upgrade: websocket\r\n"
    response += "Connection: Upgrade\r\n"
    response += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

    connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
      if error == nil {
        self.state.receiveHello(deviceName: "connecting", sampleRate: 0)
        self.readWebSocketFrames(connection: connection, buffer: Data())
      } else {
        connection.cancel()
      }
    })
  }

  private func readWebSocketFrames(connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
      guard error == nil, let data, !data.isEmpty else {
        self.state.disconnectAudio()
        self.resetShazamPlayback()
        connection.cancel()
        return
      }

      var nextBuffer = buffer
      nextBuffer.append(data)

      do {
        while let parsed = try WebSocketFrame.parseNext(nextBuffer) {
          nextBuffer.removeFirst(parsed.consumedBytes)
          switch parsed.frame.opcode {
          case 1:
            self.handleHello(parsed.frame.payload)
          case 2:
            self.handleAudio(parsed.frame.payload)
          case 8:
            self.state.disconnectAudio()
            self.resetShazamPlayback()
            connection.cancel()
            return
          default:
            break
          }
        }
      } catch {
        print("websocket parse error: \(error.localizedDescription)")
        self.state.disconnectAudio()
        self.resetShazamPlayback()
        connection.cancel()
        return
      }

      if isComplete {
        self.state.disconnectAudio()
        self.resetShazamPlayback()
        connection.cancel()
      } else {
        self.readWebSocketFrames(connection: connection, buffer: nextBuffer)
      }
    }
  }

  private func handleHello(_ payload: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
    let sampleRate = json["sampleRate"] as? Int ?? 0
    resetOffsetTracking()
    state.receiveHello(
      deviceName: json["deviceName"] as? String ?? "unknown",
      sampleRate: sampleRate
    )
    shazam.configure(sampleRate: sampleRate)
  }

  private func handleAudio(_ payload: Data) {
    let previous = state.currentSnapshot()
    if !previous.audioConnected, previous.sampleRate > 0 {
      shazam.configure(sampleRate: previous.sampleRate)
    }
    let sampleCount = payload.count / MemoryLayout<Float>.size
    var sum: Float = 0

    payload.withUnsafeBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: Float.self)
      for sample in samples {
        sum += sample * sample
      }
    }

    let rms = sampleCount == 0 ? 0 : sqrt(sum / Float(sampleCount))
    state.receiveAudio(sampleCount: sampleCount, rms: rms)
    let silenceThreshold = Float(state.silenceThreshold)
    if rms > silenceThreshold {
      shazam.receive(float32MonoPCM: payload)
    } else {
      shazam.skipSilent(frameCount: sampleCount)
    }
  }

  private func handleShazamMatch(_ match: ShazamMatchResult, isNewTrack: Bool) {
    let action = offsetTracker.observe(match, isNewTrack: isNewTrack)
    switch action {
    case .none:
      return
    case let .start(positionSeconds):
      let identity = match.identity
      DispatchQueue.global(qos: .userInitiated).async { [weak self, spotify] in
        guard let self else { return }
        do {
          self.metadataLock.lock()
          let preferredAlbumID = self.pressingState == "matched"
            ? self.resolvedTrackPayload?["albumId"] as? String ?? "" : ""
          self.metadataLock.unlock()
          // Collection lookup failure must not prevent Spotify playback.
          let ownedAlbums = (try? self.discogs.ownedAlbumKeys()) ?? []
          let resolution = try spotify.trackResolution(
            isrc: match.isrc,
            title: match.title,
            artist: match.artist,
            preferredAlbumID: preferredAlbumID,
            ownedAlbums: ownedAlbums
          )
          guard self.offsetTracker.status().trackIdentity == identity else { return }
          self.shazamPlaybackLock.lock()
          self.currentShazamPlaybackID = identity
          self.currentShazamPlaybackURI = resolution.uri
          self.currentShazamPlaybackAlbumID = resolution.albumId
          self.shazamPlaybackLock.unlock()
          self.updateResolvedTrack(resolution)
          spotify.play(
            uri: resolution.uri,
            albumId: resolution.albumId,
            position: PlaybackPosition(seconds: positionSeconds, observedUptime: match.matchedUptime),
            reason: "Shazam confirmed \(match.artist) — \(match.title)",
            isCurrent: { self.offsetTracker.status().trackIdentity == identity }
          )
          self.resolvePressing(for: resolution)
        } catch {
          spotify.reportResolutionFailure(error)
          print("Shazam match could not be mapped to Spotify: \(error.localizedDescription)")
        }
      }
    case let .correct(positionSeconds):
      shazamPlaybackLock.lock()
      let uri = currentShazamPlaybackID == match.identity ? currentShazamPlaybackURI : ""
      let albumId = currentShazamPlaybackAlbumID
      shazamPlaybackLock.unlock()
      guard !uri.isEmpty else { return }
      DispatchQueue.global(qos: .userInitiated).async { [weak self, spotify] in
        spotify.play(
          uri: uri,
          albumId: albumId,
          position: PlaybackPosition(seconds: positionSeconds, observedUptime: match.matchedUptime),
          reason: "Shazam drift correction for \(match.artist) — \(match.title)",
          isCurrent: { self?.offsetTracker.status().trackIdentity == match.identity }
        )
      }
    }
  }

  private func expireInactivePlayback() {
    let audio = state.currentSnapshot()
    let now = ProcessInfo.processInfo.systemUptime
    if audio.audioConnected && now - audio.lastBufferUptime >= 10 {
      state.disconnectAudio()
      resetShazamPlayback()
      return
    }
    metadataLock.lock()
    let duration = resolvedTrackPayload?["durationSeconds"] as? Double ?? 0
    metadataLock.unlock()
    let tracking = offsetTracker.status()
    guard !tracking.trackIdentity.isEmpty,
          PlaybackExpiry.shouldClear(elapsed: tracking.estimatedOffsetSeconds,
            duration: duration, silentFor: now - audio.lastSoundUptime) else { return }
    shazam.clearPlayback { [weak self] in self?.resetOffsetTracking() }
  }

  private func resetShazamPlayback() {
    shazam.disconnect()
    resetOffsetTracking()
  }

  private func resetOffsetTracking() {
    offsetTracker.reset()
    shazamPlaybackLock.lock()
    currentShazamPlaybackID = ""
    currentShazamPlaybackURI = ""
    currentShazamPlaybackAlbumID = ""
    shazamPlaybackLock.unlock()
    metadataLock.lock()
    resolvedTrackPayload = nil
    pressingState = "waiting"
    pressingMatch = nil
    pressingError = ""
    metadataLock.unlock()
  }

  private func updateResolvedTrack(_ track: SpotifyTrackResolution) {
    metadataLock.lock()
    resolvedTrackPayload = [
      "uri": track.uri,
      "title": track.title,
      "artist": track.artist,
      "durationSeconds": track.durationSeconds,
      "albumId": track.albumId,
      "albumName": track.albumName,
      "albumArtists": track.albumArtists,
      "albumImage": track.albumImage
    ]
    pressingState = discogs.status().configured ? "searching" : "not configured"
    pressingMatch = nil
    pressingError = ""
    metadataLock.unlock()
  }

  private func resolvePressing(for track: SpotifyTrackResolution) {
    guard discogs.status().configured else { return }
    do {
      let preferredReleaseID = pressingChoices.releaseID(album: track.albumName, artist: track.albumArtists)
      let match = try discogs.matchOwnedRelease(
        album: track.albumName,
        artist: track.albumArtists,
        preferredReleaseID: preferredReleaseID
      )
      metadataLock.lock()
      guard resolvedTrackPayload?["uri"] as? String == track.uri else {
        metadataLock.unlock()
        return
      }
      pressingMatch = match
      if match?["ambiguous"] as? Bool == true {
        pressingState = "ambiguous"
      } else {
        pressingState = match == nil ? "not found" : "matched"
      }
      pressingError = ""
      metadataLock.unlock()
    } catch {
      metadataLock.lock()
      guard resolvedTrackPayload?["uri"] as? String == track.uri else {
        metadataLock.unlock()
        return
      }
      pressingState = "unavailable"
      pressingMatch = nil
      pressingError = error.localizedDescription
      metadataLock.unlock()
    }
  }

  private func selectPressing(releaseID: Int) throws {
    metadataLock.lock()
    let album = resolvedTrackPayload?["albumName"] as? String ?? ""
    let artist = resolvedTrackPayload?["albumArtists"] as? String ?? ""
    metadataLock.unlock()
    guard !album.isEmpty else {
      throw NSError(domain: "Discogs", code: 2, userInfo: [NSLocalizedDescriptionKey: "No recognized album is awaiting a pressing choice."])
    }

    guard let match = try discogs.matchOwnedRelease(
      album: album,
      artist: artist,
      preferredReleaseID: releaseID
    ), match["ambiguous"] as? Bool == false,
       match["id"] as? Int == releaseID else {
      throw NSError(domain: "Discogs", code: 3, userInfo: [NSLocalizedDescriptionKey: "That release is not a candidate for the recognized album."])
    }

    pressingChoices.remember(releaseID: releaseID, album: album, artist: artist)
    metadataLock.lock()
    pressingState = "matched"
    pressingMatch = match
    pressingError = ""
    metadataLock.unlock()
  }

  private func statusPayload(_ snapshot: AudioSnapshot) -> [String: Any] {
    [
      "audioConnected": snapshot.audioConnected,
      "lastDeviceName": snapshot.lastDeviceName,
      "sampleRate": snapshot.sampleRate,
      "frameCount": snapshot.frameCount,
      "streamSeconds": snapshot.streamSeconds,
      "rms": snapshot.rms,
      "lastSeen": ISO8601DateFormatter().string(from: snapshot.lastSeen),
      "shazam": shazamPayload(),
      "offsetTracking": offsetTrackingPayload(),
      "nowPlaying": nowPlayingPayload(),
      "pressing": pressingPayload(),
      "spotify": spotifyPayload(),
      "discogs": discogsPayload()
    ]
  }

  private func shazamPayload() -> [String: Any] {
    let status = shazam.status()
    var payload: [String: Any] = [
      "available": status.available,
      "enabled": status.enabled,
      "state": status.state,
      "sampleRate": status.sampleRate,
      "submittedFrames": status.submittedFrames,
      "lastQueueDelaySeconds": status.lastQueueDelaySeconds,
      "maxQueueDelaySeconds": status.maxQueueDelaySeconds,
      "lastBufferDurationSeconds": status.lastBufferDurationSeconds,
      "silentFramesSkipped": status.silentFramesSkipped,
      "silentBuffersSkipped": status.silentBuffersSkipped,
      "matches": status.matches,
      "noMatches": status.noMatches,
      "transientErrors": status.transientErrors,
      "candidateTitle": status.candidateTitle,
      "candidateArtist": status.candidateArtist,
      "candidateMatches": status.candidateMatches,
      "confirmedAt": status.confirmedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
      "lastSuccessfulMatchAt": status.lastSuccessfulMatchAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
      "lastError": status.lastError,
      "lastErrorAt": status.lastErrorAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
      "error": status.error
    ]
    if let match = status.lastMatch {
      payload["lastMatch"] = [
        "shazamID": match.shazamID,
        "title": match.title,
        "artist": match.artist,
        "isrc": match.isrc,
        "artworkURL": match.artworkURL,
        "webURL": match.webURL,
        "appleMusicURL": match.appleMusicURL,
        "matchOffsetSeconds": match.matchOffsetSeconds,
        "queryDurationSeconds": match.queryDurationSeconds,
        "predictedOffsetSeconds": match.predictedOffsetSeconds,
        "frequencySkew": match.frequencySkew,
        "matchedAt": ISO8601DateFormatter().string(from: match.matchedAt)
      ] as [String: Any]
    } else {
      payload["lastMatch"] = NSNull()
    }
    return payload
  }

  private func offsetTrackingPayload() -> [String: Any] {
    let status = offsetTracker.status()
    return [
      "trackIdentity": status.trackIdentity,
      "estimatedOffsetSeconds": status.estimatedOffsetSeconds,
      "observedOffsetSeconds": status.observedOffsetSeconds,
      "driftSeconds": status.driftSeconds,
      "acceptedObservations": status.acceptedObservations,
      "rejectedObservations": status.rejectedObservations,
      "lastCorrectionAt": status.lastCorrectionAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
    ]
  }

  private func nowPlayingPayload() -> Any {
    metadataLock.lock()
    let payload = resolvedTrackPayload
    metadataLock.unlock()
    return payload ?? NSNull()
  }

  private func pressingPayload() -> [String: Any] {
    metadataLock.lock()
    let state = pressingState
    let match = pressingMatch
    let error = pressingError
    metadataLock.unlock()
    return [
      "state": state,
      "match": match ?? NSNull(),
      "error": error
    ]
  }

  private func spotifyPayload() -> [String: Any] {
    let status = spotify.status()
    return [
      "configured": status.configured,
      "authenticated": status.authenticated,
      "user": status.user,
      "image": status.image,
      "targetDevice": status.targetDevice,
      "redirectUri": spotify.redirectUriValue,
      "lastAction": status.lastAction,
      "error": status.error
    ]
  }

  private func configPayload() -> [String: Any] {
    let config = ConfigStore.shared
    return [
      "spotifyClientId": config.spotifyClientId,
      "spotifyRedirectUri": config.spotifyRedirectUri,
      "spotifyTargetDeviceId": config.spotifyTargetDeviceId,
      "spotifyTargetDeviceName": config.spotifyTargetDeviceName,
      "discogsUsername": config.discogsUsername,
      "spotifyClientSecretSet": !config.spotifyClientSecret.isEmpty,
      "discogsTokenSet": !config.discogsToken.isEmpty
    ]
  }

  private func discogsPayload() -> [String: Any] {
    let status = discogs.status()
    return [
      "configured": status.configured,
      "user": status.user,
      "error": status.error
    ]
  }

  private func respondHTML(connection: NWConnection, body: String) {
    respond(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
  }

  private func respondJSON(connection: NWConnection, status: Int, body: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: body)
    respond(connection: connection, status: status, contentType: "application/json", body: data)
  }

  private func respondRedirect(connection: NWConnection, url: String) {
    var headers = "HTTP/1.1 302 Found\r\n"
    headers += "Location: \(url)\r\n"
    headers += "Content-Length: 0\r\n"
    headers += "Connection: close\r\n\r\n"
    connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() })
  }

  private func respond(connection: NWConnection, status: Int, contentType: String, body: Data) {
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict"][status] ?? "OK"
    var headers = "HTTP/1.1 \(status) \(reason)\r\n"
    headers += "Content-Type: \(contentType)\r\n"
    headers += "Content-Length: \(body.count)\r\n"
    headers += "Connection: close\r\n\r\n"
    var response = Data(headers.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }
}

struct HTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data

  init?(data: Data) {
    guard let delimiter = "\r\n\r\n".data(using: .utf8),
          let headerRange = data.range(of: delimiter),
          let text = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
      return nil
    }

    let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    method = String(requestParts[0])
    let rawPath = String(requestParts[1])
    if let question = rawPath.firstIndex(of: "?") {
      path = String(rawPath[..<question])
      query = parseQuery(String(rawPath[rawPath.index(after: question)...]))
    } else {
      path = rawPath
      query = [:]
    }
    headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line in
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      return (parts[0].lowercased(), parts[1].trimmingCharacters(in: .whitespaces))
    })

    let bodyStart = headerRange.upperBound
    let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
    guard data.count >= bodyStart + contentLength else { return nil }
    body = data[bodyStart..<bodyStart + contentLength]
  }
}

struct WebSocketFrame {
  let opcode: UInt8
  let payload: Data

  static func parseNext(_ data: Data) throws -> (frame: WebSocketFrame, consumedBytes: Int)? {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { return nil }

    let opcode = bytes[0] & 0x0f
    let masked = (bytes[1] & 0x80) != 0
    var length = Int(bytes[1] & 0x7f)
    var index = 2

    if length == 126 {
      guard bytes.count >= index + 2 else { return nil }
      length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      index += 2
    } else if length == 127 {
      guard bytes.count >= index + 8 else { return nil }
      let wideLength = bytes[index..<index + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      guard wideLength <= UInt64(Int.max) else { throw ParseError.unsupportedLength }
      length = Int(wideLength)
      index += 8
    }

    var mask: [UInt8] = []
    if masked {
      guard bytes.count >= index + 4 else { return nil }
      mask = Array(bytes[index..<index + 4])
      index += 4
    }

    guard bytes.count >= index + length else { return nil }
    var payload = Array(bytes[index..<index + length])

    if masked {
      for payloadIndex in payload.indices {
        payload[payloadIndex] ^= mask[payloadIndex % 4]
      }
    }

    return (WebSocketFrame(opcode: opcode, payload: Data(payload)), index + length)
  }

  enum ParseError: Error {
    case unsupportedLength
  }
}

func webSocketAccept(_ key: String) -> String {
  let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
  return Data(digest).base64EncodedString()
}

func parseQuery(_ query: String) -> [String: String] {
  var values: [String: String] = [:]
  for part in query.split(separator: "&") {
    let pieces = part.split(separator: "=", maxSplits: 1)
    guard let key = pieces.first else { continue }
    let value = pieces.count > 1 ? String(pieces[1]) : ""
    values[String(key).removingPercentEncoding ?? String(key)] = value
      .replacingOccurrences(of: "+", with: " ")
      .removingPercentEncoding ?? value
  }
  return values
}

func escapeHTML(_ value: String) -> String {
  value
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}

func faviconSVG() -> String {
  """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <rect width="64" height="64" rx="14" fill="#101215"/>
    <circle cx="32" cy="32" r="23" fill="#17191d" stroke="#d6437f" stroke-width="3"/>
    <circle cx="32" cy="32" r="8" fill="#d6437f"/>
    <circle cx="32" cy="32" r="3" fill="#edeef0"/>
    <path d="M32 9v10M55 32H45M32 55V45M9 32h10" stroke="#5c636d" stroke-width="3" stroke-linecap="round"/>
  </svg>
  """
}

func pageHTML() -> String {
  """
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Vinyl Sync</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg">
    <style>
      :root { color-scheme: light; --bg:#f4f1ec; --panel:#fffefa; --ink:#171513; --muted:#716b65; --line:#ded8d0; --accent:#d5447d; --ok:#218552; --warn:#b56a20; --bad:#b93636; }
      :root[data-theme="dark"] { color-scheme:dark; --bg:#11100f; --panel:#1a1817; --ink:#f3eee8; --muted:#a49d96; --line:#312e2b; --accent:#ed679b; --ok:#54c685; --warn:#e5a054; --bad:#ef7070; }
      * { box-sizing:border-box; }
      body { margin:0; min-height:100vh; background:var(--bg); color:var(--ink); font:15px/1.45 system-ui,-apple-system,sans-serif; }
      button,input,select { font:inherit; color:inherit; }
      button { cursor:pointer; }
      header { height:64px; padding:0 24px; display:flex; align-items:center; border-bottom:1px solid var(--line); background:color-mix(in srgb,var(--panel) 92%,transparent); position:sticky; top:0; z-index:5; backdrop-filter:blur(14px); }
      .brand { font-size:17px; font-weight:700; letter-spacing:-.02em; }
      .brand i { color:var(--accent); font-style:normal; }
      .header-actions { margin-left:auto; display:flex; gap:8px; }
      .icon-button,.button { border:1px solid var(--line); background:var(--panel); border-radius:9px; padding:9px 13px; }
      .button.primary { background:var(--ink); color:var(--panel); border-color:var(--ink); }
      .button.danger { color:var(--bad); }
      main { max-width:980px; margin:0 auto; padding:34px 24px 72px; }
      .health { display:flex; flex-wrap:wrap; gap:9px; margin-bottom:22px; }
      .pill { display:inline-flex; gap:7px; align-items:center; border:1px solid var(--line); background:var(--panel); border-radius:999px; padding:7px 11px; font-size:12px; color:var(--muted); }
      .dot { width:7px; height:7px; border-radius:50%; background:var(--warn); }
      .dot.ok { background:var(--ok); } .dot.bad { background:var(--bad); }
      .hero { display:grid; grid-template-columns:minmax(240px,360px) 1fr; gap:42px; align-items:center; }
      .art { width:100%; aspect-ratio:1; border-radius:16px; overflow:hidden; background:radial-gradient(circle at center,var(--accent) 0 7%,#29252d 7.3% 17%,#151318 17.3% 100%); box-shadow:0 18px 50px rgba(0,0,0,.16); }
      .art img { width:100%; height:100%; object-fit:cover; display:block; }
      .eyebrow { color:var(--accent); font-size:12px; font-weight:700; letter-spacing:.1em; text-transform:uppercase; }
      h1 { margin:10px 0 5px; font-size:clamp(32px,5vw,56px); line-height:1.02; letter-spacing:-.045em; }
      .artist { font-size:20px; color:var(--muted); }
      .album { margin-top:5px; color:var(--muted); }
      .progress { margin:28px 0 8px; height:5px; border-radius:9px; background:var(--line); overflow:hidden; }
      .progress span { display:block; height:100%; width:0; background:var(--accent); transition:width .5s linear; }
      .times { display:flex; justify-content:space-between; color:var(--muted); font:12px ui-monospace,SFMono-Regular,monospace; }
      .actions { display:flex; gap:9px; margin-top:25px; flex-wrap:wrap; }
      .pressing { margin-top:34px; border-top:1px solid var(--line); padding-top:22px; }
      .pressing-title { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; margin-bottom:7px; }
      .pressing-main { font-weight:650; }
      .pressing-meta { color:var(--muted); font-size:13px; margin-top:3px; }
      .pressing-options { display:flex; flex-direction:column; gap:7px; margin-top:12px; }
      .pressing-option { display:flex; align-items:center; gap:10px; text-align:left; border:1px solid var(--line); background:var(--panel); border-radius:9px; padding:8px; }
      .pressing-option:hover { border-color:var(--accent); }
      .pressing-option img { width:42px; height:42px; border-radius:5px; object-fit:cover; background:var(--bg); }
      .pressing-option span { display:block; }
      .pressing-option small { display:block; color:var(--muted); margin-top:2px; }
      details { margin-top:28px; border:1px solid var(--line); border-radius:12px; background:var(--panel); }
      summary { cursor:pointer; padding:15px 17px; font-weight:650; }
      .diagnostics { border-top:1px solid var(--line); padding:15px 17px; display:grid; grid-template-columns:repeat(3,1fr); gap:14px; }
      .metric label { display:block; color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.06em; }
      .metric span { display:block; margin-top:4px; font:13px ui-monospace,SFMono-Regular,monospace; overflow-wrap:anywhere; }
      dialog { width:min(620px,calc(100vw - 32px)); border:1px solid var(--line); border-radius:14px; background:var(--panel); color:var(--ink); padding:0; box-shadow:0 24px 80px rgba(0,0,0,.3); }
      dialog::backdrop { background:rgba(0,0,0,.45); backdrop-filter:blur(3px); }
      .dialog-head { display:flex; align-items:center; padding:18px 20px; border-bottom:1px solid var(--line); }
      .dialog-head h2 { margin:0; font-size:18px; }
      .dialog-head button { margin-left:auto; }
      .form { padding:20px; display:grid; grid-template-columns:1fr 1fr; gap:14px; }
      .field { display:flex; flex-direction:column; gap:6px; }
      .field.wide { grid-column:1/-1; }
      .field label { font-size:12px; color:var(--muted); }
      .field input,.field select { width:100%; padding:10px 11px; border:1px solid var(--line); border-radius:8px; background:var(--bg); }
      .dialog-actions { grid-column:1/-1; display:flex; justify-content:flex-end; gap:9px; padding-top:5px; }
      .empty h1 { color:var(--muted); }
      .toast { position:fixed; left:50%; bottom:24px; transform:translate(-50%,20px); opacity:0; transition:.2s; background:var(--ink); color:var(--panel); border-radius:8px; padding:9px 13px; z-index:10; pointer-events:none; }
      .toast.show { opacity:1; transform:translate(-50%,0); }
      @media(max-width:720px) { header{padding:0 16px} main{padding:24px 16px 56px}.hero{grid-template-columns:1fr;gap:26px}.art{max-width:360px;margin:auto}.diagnostics{grid-template-columns:1fr 1fr}.form{grid-template-columns:1fr}.field.wide{grid-column:auto}.dialog-actions{grid-column:auto} }
    </style>
  </head>
  <body>
    <header><div class="brand">vinyl<i>sync</i></div><div class="header-actions"><button class="icon-button" onclick="toggleTheme()" aria-label="Toggle theme">◐</button><button class="icon-button" onclick="openSettings()">Settings</button></div></header>
    <main>
      <div class="health">
        <div class="pill"><span class="dot" id="audioDot"></span><span id="audioHealth">Audio waiting</span></div>
        <div class="pill"><span class="dot" id="shazamDot"></span><span id="shazamHealth">Shazam waiting</span></div>
        <div class="pill"><span class="dot" id="spotifyDot"></span><span id="spotifyHealth">Spotify waiting</span></div>
      </div>
      <section class="hero empty" id="hero">
        <div class="art" id="art"></div>
        <div>
          <div class="eyebrow" id="stateLabel">Waiting for a record</div>
          <h1 id="title">Drop the needle</h1>
          <div class="artist" id="artist">Recognition starts automatically when sound arrives.</div>
          <div class="album" id="album"></div>
          <div class="progress"><span id="progressFill"></span></div>
          <div class="times"><span id="elapsed">0:00</span><span id="duration">--:--</span></div>
          <div class="actions"><button class="button primary" onclick="action('/sync/resync','Resync requested')">Resync</button><button class="button danger" onclick="action('/sync/wrong-match','Match rejected')">Wrong match</button></div>
          <div class="pressing"><div class="pressing-title">Physical pressing</div><div class="pressing-main" id="pressingMain">Waiting for an album</div><div class="pressing-meta" id="pressingMeta">Discogs is optional and never blocks playback.</div><div class="pressing-options" id="pressingOptions"></div></div>
        </div>
      </section>
      <details><summary>Diagnostics</summary><div class="diagnostics">
        <div class="metric"><label>Input</label><span id="diagInput">—</span></div><div class="metric"><label>Signal RMS</label><span id="diagRms">0</span></div><div class="metric"><label>Sample rate</label><span id="diagRate">—</span></div>
        <div class="metric"><label>Shazam state</label><span id="diagState">waiting</span></div><div class="metric"><label>Submitted / skipped</label><span id="diagFrames">0 / 0</span></div><div class="metric"><label>Matches / errors</label><span id="diagMatches">0 / 0</span></div>
        <div class="metric"><label>Offset</label><span id="diagOffset">—</span></div><div class="metric"><label>Spotify action</label><span id="diagSpotify">—</span></div><div class="metric"><label>Last error</label><span id="diagError">—</span></div>
      </div></details>
    </main>
    <dialog id="settings"><div class="dialog-head"><h2>Connections</h2><button class="icon-button" onclick="settings.close()">Close</button></div><div class="form">
      <div class="field"><label>Spotify client ID</label><input id="spotifyClientId"></div><div class="field"><label>Spotify client secret</label><input id="spotifySecret" type="password"></div>
      <div class="field wide"><label>Spotify redirect URI</label><input id="redirectUri"></div><div class="field wide"><label>Spotify playback device</label><select id="spotifyDevice"></select></div>
      <div class="field"><label>Discogs username</label><input id="discogsUsername"></div><div class="field"><label>Discogs token</label><input id="discogsToken" type="password"></div>
      <div class="dialog-actions"><button class="button" onclick="location.href='/spotify/login'">Connect Spotify</button><button class="button primary" onclick="saveSettings()">Save</button></div>
    </div></dialog>
    <div class="toast" id="toast"></div>
    <script>
      const $ = id => document.getElementById(id);
      const fmt = value => { const seconds=Math.max(0,Number(value||0)); return `${Math.floor(seconds/60)}:${String(Math.floor(seconds%60)).padStart(2,'0')}`; };
      const safe = value => String(value ?? '').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
      function toast(message){ $('toast').textContent=message; $('toast').classList.add('show'); setTimeout(()=>$('toast').classList.remove('show'),2200); }
      function dot(id,state){ $(id).className=`dot ${state}`; }
      function toggleTheme(){ const root=document.documentElement; const dark=root.dataset.theme==='dark'; root.dataset.theme=dark?'light':'dark'; localStorage.setItem('vinyl-theme',root.dataset.theme); }
      document.documentElement.dataset.theme=localStorage.getItem('vinyl-theme') || (matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');
      async function action(path,message){ const response=await fetch(path,{method:'POST'}); const data=await response.json().catch(()=>({})); if(!response.ok){toast(data.error||'Action failed');return;} toast(message); await tick(); }
      function renderPressing(pressing){ const match=pressing?.match, options=$('pressingOptions'); options.innerHTML=''; if(pressing?.state==='matched'&&match){ $('pressingMain').textContent=match.title||'Owned pressing'; const label=(match.labels||[])[0]||{}; const formats=(match.formats||[]).map(f=>[f.name,f.text,...(f.descriptions||[])].filter(Boolean).join(' ')).filter(Boolean).join(', '); $('pressingMeta').textContent=[match.year,match.country,label.name,label.catalogNumber,formats].filter(Boolean).join(' · ')||'Matched in your Discogs collection'; return; } if(pressing?.state==='ambiguous'){ const candidates=match?.candidates||[]; $('pressingMain').textContent=`Choose one of ${candidates.length||match?.candidateCount||'the'} owned pressings`; $('pressingMeta').textContent='Your choice is remembered for this artist and album.'; for(const candidate of candidates){ const label=(candidate.labels||[])[0]||{}, format=(candidate.formats||[])[0]||{}; const button=document.createElement('button'); button.className='pressing-option'; button.onclick=()=>selectPressing(candidate.id); button.innerHTML=`${candidate.thumb?`<img src="${safe(candidate.thumb)}" alt="">`:''}<span><strong>${safe(candidate.title||'Owned pressing')}</strong><small>${safe([candidate.year,candidate.country,label.name,label.catalogNumber,format.text,...(format.descriptions||[])].filter(Boolean).join(' · '))}</small></span>`; options.append(button); } return; } const copy={searching:'Checking your Discogs collection…','not found':'Album recognized; owned pressing not found','not configured':'Connect Discogs to show pressing details',unavailable:'Discogs is temporarily unavailable',waiting:'Waiting for an album'}; $('pressingMain').textContent=copy[pressing?.state]||'Waiting for an album'; $('pressingMeta').textContent=pressing?.error||'Discogs is optional and never blocks playback.'; }
      async function selectPressing(releaseId){ const response=await fetch('/discogs/select-pressing',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({releaseId})}); const data=await response.json().catch(()=>({})); if(!response.ok){toast(data.error||'Could not save pressing');return;} toast('Pressing remembered'); await tick(); }
      function render(status){ const shazam=status.shazam||{}, spotify=status.spotify||{}, now=status.nowPlaying||null, match=shazam.lastMatch||null, track=now||match; dot('audioDot',status.audioConnected?'ok':'bad'); $('audioHealth').textContent=status.audioConnected?`Audio · ${status.lastDeviceName||'connected'}`:'Audio disconnected'; const shazamOK=shazam.state==='confirmed'; dot('shazamDot',shazam.error?'bad':shazamOK?'ok':''); $('shazamHealth').textContent=shazamOK?`Shazam · ${match?.title||'confirmed'}`:`Shazam · ${shazam.state||'waiting'}`; const spotifyReady=spotify.authenticated&&spotify.targetDevice&&spotify.targetDevice!=='Not selected'; dot('spotifyDot',spotifyReady?'ok':spotify.authenticated?'':'bad'); $('spotifyHealth').textContent=spotifyReady?`Spotify · ${spotify.targetDevice}`:spotify.authenticated?'Spotify · choose a device':'Spotify not connected'; if(track){ $('hero').classList.remove('empty'); $('stateLabel').textContent=now?'Now following':'Match confirmed'; $('title').textContent=track.title||'Unknown track'; $('artist').textContent=track.artist||''; $('album').textContent=now?.albumName||''; const art=now?.albumImage||match?.artworkURL||''; $('art').innerHTML=art?`<img src="${safe(art)}" alt="">`:''; const offset=Number(status.offsetTracking?.estimatedOffsetSeconds ?? match?.predictedOffsetSeconds ?? 0); const duration=Number(now?.durationSeconds||0); $('elapsed').textContent=fmt(offset); $('duration').textContent=duration?fmt(duration):'--:--'; $('progressFill').style.width=duration?`${Math.min(100,offset/duration*100)}%`:'0'; } else { $('hero').classList.add('empty'); $('stateLabel').textContent=status.audioConnected?(shazam.state||'Listening'):'Waiting for audio'; $('title').textContent='Drop the needle'; $('artist').textContent='Recognition starts automatically when sound arrives.'; $('album').textContent=''; $('art').innerHTML=''; $('elapsed').textContent='0:00'; $('duration').textContent='--:--'; $('progressFill').style.width='0'; } renderPressing(status.pressing); $('diagInput').textContent=status.lastDeviceName||'—'; $('diagRms').textContent=Number(status.rms||0).toFixed(5); $('diagRate').textContent=status.sampleRate?`${(status.sampleRate/1000).toFixed(1)} kHz`:'—'; $('diagState').textContent=shazam.state||'waiting'; $('diagFrames').textContent=`${shazam.submittedFrames||0} / ${shazam.silentFramesSkipped||0}`; $('diagMatches').textContent=`${shazam.matches||0} / ${shazam.transientErrors||0}`; $('diagOffset').textContent=status.offsetTracking?.trackIdentity?`${Number(status.offsetTracking.estimatedOffsetSeconds||0).toFixed(2)} s · drift ${Number(status.offsetTracking.driftSeconds||0).toFixed(2)} s`:'—'; $('diagSpotify').textContent=spotify.lastAction||'—'; $('diagError').textContent=shazam.error||shazam.lastError||spotify.error||status.pressing?.error||'—'; }
      async function tick(){ try{ const response=await fetch('/status'); render(await response.json()); }catch{ dot('audioDot','bad'); $('audioHealth').textContent='Coordinator unavailable'; } }
      async function openSettings(){ $('settings').showModal(); const config=await (await fetch('/api/config')).json(); $('spotifyClientId').value=config.spotifyClientId||''; $('redirectUri').value=config.spotifyRedirectUri||''; $('discogsUsername').value=config.discogsUsername||''; $('spotifySecret').placeholder=config.spotifyClientSecretSet?'saved':'not set'; $('discogsToken').placeholder=config.discogsTokenSet?'saved':'not set'; const select=$('spotifyDevice'); select.innerHTML=''; if(config.spotifyTargetDeviceId){ const option=new Option(`${config.spotifyTargetDeviceName||'Saved device'} (saved)`,config.spotifyTargetDeviceId,true,true); option.dataset.name=config.spotifyTargetDeviceName||''; select.add(option); } const response=await fetch('/spotify/devices'); if(response.ok){ for(const device of (await response.json()).devices||[]){ let option=[...select.options].find(o=>o.value===device.id); if(!option){ option=new Option(); select.add(option); } option.value=device.id; option.dataset.name=device.name||''; option.textContent=`${device.name||'Unknown'}${device.isActive?' · active':''}`; option.selected=device.id===config.spotifyTargetDeviceId; } } if(!select.options.length)select.add(new Option('No devices available','')); }
      async function saveSettings(){ const select=$('spotifyDevice'), chosen=select.options[select.selectedIndex]; const body={spotifyClientId:$('spotifyClientId').value.trim(),spotifyRedirectUri:$('redirectUri').value.trim(),spotifyTargetDeviceId:select.value,spotifyTargetDeviceName:chosen?.dataset.name||'',discogsUsername:$('discogsUsername').value.trim()}; if($('spotifySecret').value)body.spotifyClientSecret=$('spotifySecret').value; if($('discogsToken').value)body.discogsToken=$('discogsToken').value; const response=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}); if(!response.ok){toast('Could not save settings');return;} $('spotifySecret').value=''; $('discogsToken').value=''; $('settings').close(); toast('Connections saved'); await tick(); }
      tick(); setInterval(tick,1000);
    </script>
  </body>
  </html>
  """
}

let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 4739

do {
  try CoordinatorServer(port: port).start()
} catch {
  fputs("Failed to start coordinator: \(error.localizedDescription)\n", stderr)
  exit(1)
}
