import CryptoKit
import Foundation
import Network

struct SideTrack: Codable {
  var position: String?
  var title: String
  var durationSeconds: Double
  var uri: String?
}

struct SidePlan: Codable {
  var name: String
  var tracks: [SideTrack]

  static let empty = SidePlan(name: "Untitled side", tracks: [])
  static let aThousandSunsSideA = SidePlan(
    name: "A Thousand Suns - Side A",
    tracks: [
      SideTrack(position: "A1", title: "The Requiem", durationSeconds: 121, uri: nil),
      SideTrack(position: "A2", title: "The Radiance", durationSeconds: 57, uri: nil),
      SideTrack(position: "A3", title: "Burning in the Skies", durationSeconds: 253, uri: nil),
      SideTrack(position: "A4", title: "Empty Spaces", durationSeconds: 18, uri: nil),
      SideTrack(position: "A5", title: "When They Come for Me", durationSeconds: 293, uri: nil),
      SideTrack(position: "A6", title: "Robot Boy", durationSeconds: 269, uri: nil)
    ]
  )
}

struct PlaybackRequest {
  var uri: String
  var positionMs: Int
  var reason: String
  var startDelaySeconds: Double
}

struct SyncSettings: Codable {
  var spotifyOffsetSeconds: Double
  var spotifyStartDelaySeconds: Double
  var activityThreshold: Double
  var silenceThreshold: Double
  var leadInSilenceSeconds: Double
  var transitionSilenceSeconds: Double
  var transitionWindowSeconds: Double

  static let `default` = SyncSettings(
    spotifyOffsetSeconds: 0,
    spotifyStartDelaySeconds: 0,
    activityThreshold: 0.0010,
    silenceThreshold: 0.00045,
    leadInSilenceSeconds: 0.45,
    transitionSilenceSeconds: 1.6,
    transitionWindowSeconds: 35
  )

  init(
    spotifyOffsetSeconds: Double = 0,
    spotifyStartDelaySeconds: Double = 0,
    activityThreshold: Double = 0.0010,
    silenceThreshold: Double = 0.00045,
    leadInSilenceSeconds: Double = 0.45,
    transitionSilenceSeconds: Double = 1.6,
    transitionWindowSeconds: Double = 35
  ) {
    self.spotifyOffsetSeconds = spotifyOffsetSeconds
    self.spotifyStartDelaySeconds = spotifyStartDelaySeconds
    self.activityThreshold = activityThreshold
    self.silenceThreshold = silenceThreshold
    self.leadInSilenceSeconds = leadInSilenceSeconds
    self.transitionSilenceSeconds = transitionSilenceSeconds
    self.transitionWindowSeconds = transitionWindowSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    spotifyOffsetSeconds = try container.decodeIfPresent(Double.self, forKey: .spotifyOffsetSeconds) ?? Self.default.spotifyOffsetSeconds
    spotifyStartDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .spotifyStartDelaySeconds) ?? Self.default.spotifyStartDelaySeconds
    activityThreshold = try container.decodeIfPresent(Double.self, forKey: .activityThreshold) ?? Self.default.activityThreshold
    silenceThreshold = try container.decodeIfPresent(Double.self, forKey: .silenceThreshold) ?? Self.default.silenceThreshold
    leadInSilenceSeconds = try container.decodeIfPresent(Double.self, forKey: .leadInSilenceSeconds) ?? Self.default.leadInSilenceSeconds
    transitionSilenceSeconds = try container.decodeIfPresent(Double.self, forKey: .transitionSilenceSeconds) ?? Self.default.transitionSilenceSeconds
    transitionWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .transitionWindowSeconds) ?? Self.default.transitionWindowSeconds
  }
}

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

  func searchAlbums(query: String) throws -> [[String: Any]] {
    let queryCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = query.addingPercentEncoding(withAllowedCharacters: queryCharacters) ?? query
    let json = try api("GET", "/search?q=\(encoded)&type=album&limit=8")
    let albums = ((json["albums"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    return albums.map { album in
      [
        "id": album["id"] as? String ?? "",
        "name": album["name"] as? String ?? "",
        "artists": ((album["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", "),
        "image": (((album["images"] as? [[String: Any]]) ?? []).first?["url"] as? String) ?? "",
        "releaseDate": album["release_date"] as? String ?? ""
      ]
    }
  }

  func albumForAlbum(id: String) throws -> (sidePlan: SidePlan, album: [String: Any]) {
    let album = try api("GET", "/albums/\(id)")
    let name = album["name"] as? String ?? "Spotify album"
    let artists = ((album["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
    let image = (((album["images"] as? [[String: Any]]) ?? []).first?["url"] as? String) ?? ""
    let items = ((album["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    let tracks = items.map { item in
      SideTrack(
        position: item["track_number"].map { "\($0)" },
        title: item["name"] as? String ?? "Untitled",
        durationSeconds: Double(item["duration_ms"] as? Int ?? 0) / 1000,
        uri: item["uri"] as? String
      )
    }
    let sidePlan = SidePlan(name: artists.isEmpty ? name : "\(artists) - \(name)", tracks: tracks)
    let albumPayload: [String: Any] = [
      "id": id,
      "name": name,
      "artists": artists,
      "image": image,
      "tracks": tracks.map {
        ["position": $0.position ?? "", "title": $0.title, "durationSeconds": $0.durationSeconds, "uri": $0.uri ?? ""] as [String: Any]
      }
    ]
    return (sidePlan, albumPayload)
  }

  func trackURI(isrc: String, title: String, artist: String) throws -> String {
    try trackResolution(isrc: isrc, title: title, artist: artist).uri
  }

  func trackResolution(isrc: String, title: String, artist: String) throws -> SpotifyTrackResolution {
    let query: String
    if !isrc.isEmpty {
      query = "isrc:\(isrc)"
    } else {
      query = "track:\"\(title)\" artist:\"\(artist)\""
    }
    let queryCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = query.addingPercentEncoding(withAllowedCharacters: queryCharacters) ?? query
    let json = try api("GET", "/search?q=\(encoded)&type=track&limit=5")
    let items = ((json["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    guard let track = items.first,
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

  func play(uri: String, positionMs: Int, reason: String) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let deviceId = try self.targetDeviceId()
        _ = try self.api("PUT", "/me/player/volume?volume_percent=0&device_id=\(deviceId)", emptyOK: true)
        let body = try JSONSerialization.data(withJSONObject: [
          "uris": [uri],
          "position_ms": max(0, positionMs)
        ])
        _ = try self.api("PUT", "/me/player/play?device_id=\(deviceId)", body: body, emptyOK: true)
        self.setAction("playing \(reason)", error: "")
      } catch {
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

  private func api(_ method: String, _ path: String, body: Data? = nil, emptyOK: Bool = false) throws -> [String: Any] {
    guard refreshIfNeeded() else {
      throw NSError(domain: "Spotify", code: 3, userInfo: [NSLocalizedDescriptionKey: "Spotify is not connected."])
    }
    lock.lock()
    let accessToken = token?.accessToken ?? ""
    lock.unlock()

    var request = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)")!)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let body {
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

  func matchOwnedRelease(album: String, artist: String) throws -> [String: Any]? {
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
    guard candidates.count == 1, var result = candidates.first else {
      return candidates.isEmpty ? nil : [
        "ambiguous": true,
        "candidateCount": candidates.count,
        "album": album,
        "artist": artist
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

struct SyncSnapshot {
  var audioConnected = false
  var lastDeviceName = "none"
  var sampleRate = 0
  var frameCount: UInt64 = 0
  var streamSeconds: Double = 0
  var rms: Float = 0
  var lastSeen = Date.distantPast

  var sidePlan = SidePlan.aThousandSunsSideA
  var mode = "idle"
  var audioActive = false
  var silenceSeconds: Double = 0
  var sideElapsedSeconds: Double = 0
  var currentTrackIndex = 0
  var currentTrackElapsedSeconds: Double = 0
  var currentTrackRemainingSeconds: Double = 0
  var currentTrackTitle = "--"
  var nextTrackTitle = "--"
  var needleDropAt: Date?
  var event = "waiting"
  var playedTrackIndex: Int?
  var pendingTrackIndex: Int?
  var settings = SyncSettings.default
}

final class StateStore {
  private let lock = NSLock()
  private var snapshot = SyncSnapshot()
  private let settingsURL = ConfigStore.shared.stateFileURL("sync-settings.json")
  private let sideURL = ConfigStore.shared.stateFileURL("side-plan.json")

  init() {
    snapshot.settings = Self.loadSettings(from: settingsURL, legacy: URL(fileURLWithPath: ".state/sync-settings.json"))
    snapshot.sidePlan = Self.loadSidePlan(from: sideURL, legacy: URL(fileURLWithPath: ".state/side-plan.json"))
    resetLocked(event: "ready")
  }

  func configureSide(_ plan: SidePlan) {
    lock.lock()
    snapshot.sidePlan = plan
    resetLocked(event: "side loaded")
    lock.unlock()
    saveSidePlan(plan)
  }

  func arm() {
    lock.lock()
    snapshot.mode = "armed"
    snapshot.sideElapsedSeconds = 0
    snapshot.currentTrackIndex = 0
    snapshot.currentTrackElapsedSeconds = 0
    snapshot.currentTrackRemainingSeconds = firstTrackDurationLocked()
    snapshot.currentTrackTitle = firstTrackTitleLocked()
    snapshot.nextTrackTitle = nextTrackTitleLocked(after: 0)
    snapshot.needleDropAt = nil
    snapshot.playedTrackIndex = nil
    snapshot.pendingTrackIndex = nil
    snapshot.silenceSeconds = 0
    snapshot.audioActive = false
    snapshot.event = "armed"
    lock.unlock()
  }

  func reset() {
    lock.lock()
    resetLocked(event: "reset")
    lock.unlock()
  }

  func updateSettings(_ settings: SyncSettings) {
    lock.lock()
    snapshot.settings = settings
    snapshot.event = "settings updated"
    lock.unlock()
    try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(settings) {
      try? data.write(to: settingsURL)
    }
  }

  func nextTrack() -> PlaybackRequest? {
    lock.lock()
    guard !snapshot.sidePlan.tracks.isEmpty else {
      snapshot.event = "no side loaded"
      lock.unlock()
      return nil
    }

    let nextIndex = min(snapshot.currentTrackIndex + 1, snapshot.sidePlan.tracks.count - 1)
    snapshot.sideElapsedSeconds = elapsedAtTrackStartLocked(nextIndex)
    snapshot.currentTrackIndex = nextIndex
    snapshot.currentTrackElapsedSeconds = 0
    snapshot.currentTrackRemainingSeconds = snapshot.sidePlan.tracks[nextIndex].durationSeconds
    snapshot.currentTrackTitle = snapshot.sidePlan.tracks[nextIndex].title
    snapshot.nextTrackTitle = nextTrackTitleLocked(after: nextIndex)
    snapshot.silenceSeconds = 0
    snapshot.pendingTrackIndex = nil
    snapshot.mode = "running"
    snapshot.event = "manual next"
    let request = playbackRequestLocked(reason: "manual next", useStartDelay: false)
    lock.unlock()
    return request
  }

  func disconnectAudio() {
    lock.lock()
    snapshot.audioConnected = false
    snapshot.event = "audio disconnected"
    lock.unlock()
  }

  func receiveHello(deviceName: String, sampleRate: Int) {
    lock.lock()
    snapshot.audioConnected = true
    snapshot.lastDeviceName = deviceName
    snapshot.sampleRate = sampleRate
    snapshot.lastSeen = Date()
    snapshot.event = "audio connected"
    lock.unlock()
  }

  func receiveAudio(sampleCount: Int, rms: Float) -> PlaybackRequest? {
    lock.lock()
    var request: PlaybackRequest?
    let delta = snapshot.sampleRate > 0 ? Double(sampleCount) / Double(snapshot.sampleRate) : 0
    snapshot.frameCount += 1
    snapshot.streamSeconds += delta
    snapshot.rms = rms
    snapshot.lastSeen = Date()

    let settings = snapshot.settings
    let activeNow = rms >= Float(settings.activityThreshold)
    if activeNow {
      snapshot.silenceSeconds = 0
    } else if rms <= Float(settings.silenceThreshold) {
      snapshot.silenceSeconds += delta
    }

    switch snapshot.mode {
    case "armed":
      if activeNow {
        snapshot.mode = "lead-in"
        snapshot.audioActive = true
        snapshot.needleDropAt = Date()
        snapshot.event = "needle drop ignored"
      }
    case "lead-in":
      snapshot.audioActive = activeNow
      if !activeNow, snapshot.silenceSeconds >= settings.leadInSilenceSeconds {
        snapshot.mode = "waiting-start"
        snapshot.audioActive = false
        snapshot.event = "waiting for first track start"
      }
    case "waiting-start":
      snapshot.audioActive = activeNow
      if activeNow {
        snapshot.mode = "running"
        snapshot.sideElapsedSeconds = 0
        snapshot.currentTrackIndex = 0
        snapshot.currentTrackElapsedSeconds = 0
        snapshot.currentTrackRemainingSeconds = firstTrackDurationLocked()
        snapshot.currentTrackTitle = firstTrackTitleLocked()
        snapshot.nextTrackTitle = nextTrackTitleLocked(after: 0)
        snapshot.silenceSeconds = 0
        snapshot.event = "first track start"
        request = playbackRequestLocked(reason: "first track start")
      }
    case "running":
      snapshot.sideElapsedSeconds += delta

      let wasActive = snapshot.audioActive
      snapshot.audioActive = activeNow || (snapshot.silenceSeconds < settings.transitionSilenceSeconds)

      if activeNow {
        if let pendingTrackIndex = snapshot.pendingTrackIndex {
          snapToTrackStartLocked(pendingTrackIndex, event: "track start")
          request = playbackRequestLocked(reason: "track start")
        } else {
          let previousIndex = snapshot.currentTrackIndex
          updateTrackFromTimelineLocked()
          if snapshot.currentTrackIndex != previousIndex {
            request = playbackRequestLocked(reason: "timeline")
          }
        }
      } else if wasActive,
                snapshot.silenceSeconds >= settings.transitionSilenceSeconds,
                shouldPrepareNextTrackLocked() {
        snapshot.pendingTrackIndex = snapshot.currentTrackIndex + 1
        snapshot.event = "waiting for next track start"
      }
    default:
      snapshot.audioActive = activeNow
    }

    lock.unlock()
    return request
  }

  func currentSnapshot() -> SyncSnapshot {
    lock.lock()
    let copy = snapshot
    lock.unlock()
    return copy
  }

  func currentSettings() -> SyncSettings {
    lock.lock()
    let settings = snapshot.settings
    lock.unlock()
    return settings
  }

  private func resetLocked(event: String) {
    snapshot.mode = "idle"
    snapshot.audioActive = false
    snapshot.silenceSeconds = 0
    snapshot.sideElapsedSeconds = 0
    snapshot.currentTrackIndex = 0
    snapshot.currentTrackElapsedSeconds = 0
    snapshot.currentTrackRemainingSeconds = firstTrackDurationLocked()
    snapshot.currentTrackTitle = firstTrackTitleLocked()
    snapshot.nextTrackTitle = nextTrackTitleLocked(after: 0)
    snapshot.needleDropAt = nil
    snapshot.playedTrackIndex = nil
    snapshot.pendingTrackIndex = nil
    snapshot.event = event
  }

  private func firstTrackTitleLocked() -> String {
    snapshot.sidePlan.tracks.first?.title ?? "--"
  }

  private func firstTrackDurationLocked() -> Double {
    snapshot.sidePlan.tracks.first?.durationSeconds ?? 0
  }

  private func nextTrackTitleLocked(after index: Int) -> String {
    let nextIndex = index + 1
    guard snapshot.sidePlan.tracks.indices.contains(nextIndex) else { return "--" }
    return snapshot.sidePlan.tracks[nextIndex].title
  }

  private func elapsedAtTrackStartLocked(_ index: Int) -> Double {
    guard index > 0 else { return 0 }
    return snapshot.sidePlan.tracks.prefix(index).reduce(0) { $0 + $1.durationSeconds }
  }

  private func updateTrackFromTimelineLocked() {
    guard !snapshot.sidePlan.tracks.isEmpty else {
      snapshot.currentTrackTitle = "--"
      snapshot.nextTrackTitle = "--"
      snapshot.currentTrackIndex = 0
      snapshot.currentTrackElapsedSeconds = 0
      snapshot.currentTrackRemainingSeconds = 0
      return
    }

    var elapsed = max(0, snapshot.sideElapsedSeconds)
    var selectedIndex = snapshot.sidePlan.tracks.count - 1

    for (index, track) in snapshot.sidePlan.tracks.enumerated() {
      if elapsed < track.durationSeconds {
        selectedIndex = index
        break
      }
      elapsed -= track.durationSeconds
    }

    let track = snapshot.sidePlan.tracks[selectedIndex]
    snapshot.currentTrackIndex = selectedIndex
    snapshot.currentTrackTitle = track.title
    snapshot.currentTrackElapsedSeconds = min(elapsed, track.durationSeconds)
    snapshot.currentTrackRemainingSeconds = max(0, track.durationSeconds - snapshot.currentTrackElapsedSeconds)
    snapshot.nextTrackTitle = nextTrackTitleLocked(after: selectedIndex)
  }

  private func shouldPrepareNextTrackLocked() -> Bool {
    guard snapshot.currentTrackIndex + 1 < snapshot.sidePlan.tracks.count else { return false }
    return snapshot.currentTrackRemainingSeconds <= snapshot.settings.transitionWindowSeconds
  }

  private func snapToTrackStartLocked(_ index: Int, event: String) {
    guard snapshot.sidePlan.tracks.indices.contains(index) else { return }
    snapshot.sideElapsedSeconds = elapsedAtTrackStartLocked(index)
    updateTrackFromTimelineLocked()
    snapshot.silenceSeconds = 0
    snapshot.pendingTrackIndex = nil
    snapshot.event = event
  }

  private func playbackRequestLocked(reason: String, useStartDelay: Bool = true) -> PlaybackRequest? {
    guard snapshot.sidePlan.tracks.indices.contains(snapshot.currentTrackIndex),
          snapshot.playedTrackIndex != snapshot.currentTrackIndex else {
      return nil
    }
    guard let uri = snapshot.sidePlan.tracks[snapshot.currentTrackIndex].uri,
          !uri.isEmpty else {
      snapshot.event = "current track has no Spotify URI"
      return nil
    }
    snapshot.playedTrackIndex = snapshot.currentTrackIndex
    return PlaybackRequest(
      uri: uri,
      positionMs: adjustedPositionMsLocked(snapshot.currentTrackElapsedSeconds),
      reason: reason,
      startDelaySeconds: useStartDelay ? snapshot.settings.spotifyStartDelaySeconds : 0
    )
  }

  private func adjustedPositionMsLocked(_ seconds: Double) -> Int {
    Int(max(0, seconds + snapshot.settings.spotifyOffsetSeconds) * 1000)
  }

  private static func loadSettings(from url: URL, legacy: URL) -> SyncSettings {
    guard let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: legacy)),
          let settings = try? JSONDecoder().decode(SyncSettings.self, from: data) else {
      return .default
    }
    return settings
  }

  private func saveSidePlan(_ plan: SidePlan) {
    try? FileManager.default.createDirectory(at: sideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(plan) {
      try? data.write(to: sideURL)
    }
  }

  private static func loadSidePlan(from url: URL, legacy: URL) -> SidePlan {
    guard let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: legacy)),
          let plan = try? JSONDecoder().decode(SidePlan.self, from: data),
          !plan.tracks.isEmpty else {
      return .aThousandSunsSideA
    }
    return plan
  }
}

final class CoordinatorServer {
  private let port: NWEndpoint.Port
  private let listener: NWListener
  private let state = StateStore()
  private let spotify = SpotifyClient()
  private let discogs = DiscogsClient()
  private lazy var shazam = ShazamRecognizer { [weak self] match, isNewTrack in
    self?.handleShazamMatch(match, isNewTrack: isNewTrack)
  }
  private let offsetTracker = PlaybackOffsetTracker()
  private let shazamPlaybackLock = NSLock()
  private var currentShazamPlaybackID = ""
  private var currentShazamPlaybackURI = ""
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

    if request.method == "GET", request.path == "/sync/settings" {
      respondJSON(connection: connection, status: 200, body: settingsPayload(state.currentSettings()))
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

    if request.method == "GET", request.path == "/spotify/search" {
      do {
        let query = request.query["q"] ?? ""
        respondJSON(connection: connection, status: 200, body: ["albums": try spotify.searchAlbums(query: query)])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "GET", request.path == "/discogs/collection" {
      do {
        respondJSON(connection: connection, status: 200, body: ["releases": try discogs.collection()])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "POST", request.path == "/discogs/load-release" {
      do {
        guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? Int else {
          respondJSON(connection: connection, status: 400, body: ["error": "Missing Discogs release id."])
          return
        }
        let release = mergeReleaseWithSpotify(try discogs.release(id: id))
        if let plan = sidePlan(from: release) {
          state.configureSide(plan)
        }
        respondJSON(connection: connection, status: 200, body: ["ok": true, "release": release])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "POST", request.path == "/spotify/load-album" {
      do {
        guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? String else {
          respondJSON(connection: connection, status: 400, body: ["error": "Missing album id."])
          return
        }
        let album = try spotify.albumForAlbum(id: id)
        state.configureSide(album.sidePlan)
        respondJSON(connection: connection, status: 200, body: [
          "ok": true,
          "side": sidePayload(album.sidePlan),
          "album": album.album
        ])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "GET", request.path == "/side" {
      let snapshot = state.currentSnapshot()
      respondJSON(connection: connection, status: 200, body: sidePayload(snapshot.sidePlan))
      return
    }

    if request.method == "POST", request.path == "/side" {
      handleSidePost(request: request, connection: connection)
      return
    }

    if request.method == "POST", request.path == "/sync/arm" {
      state.arm()
      respondJSON(connection: connection, status: 200, body: ["ok": true])
      return
    }

    if request.method == "POST", request.path == "/sync/reset" {
      state.reset()
      respondJSON(connection: connection, status: 200, body: ["ok": true])
      return
    }

    if request.method == "POST", request.path == "/sync/settings" {
      do {
        guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
          respondJSON(connection: connection, status: 400, body: ["error": "Missing settings payload."])
          return
        }
        let offset = json["spotifyOffsetSeconds"] as? Double
          ?? (json["spotifyOffsetSeconds"] as? Int).map(Double.init)
          ?? 0
        let startDelay = json["spotifyStartDelaySeconds"] as? Double
          ?? (json["spotifyStartDelaySeconds"] as? Int).map(Double.init)
          ?? SyncSettings.default.spotifyStartDelaySeconds
        let activityThreshold = json["activityThreshold"] as? Double
          ?? (json["activityThreshold"] as? Int).map(Double.init)
          ?? SyncSettings.default.activityThreshold
        let silenceThreshold = json["silenceThreshold"] as? Double
          ?? (json["silenceThreshold"] as? Int).map(Double.init)
          ?? SyncSettings.default.silenceThreshold
        let leadInSilenceSeconds = json["leadInSilenceSeconds"] as? Double
          ?? (json["leadInSilenceSeconds"] as? Int).map(Double.init)
          ?? SyncSettings.default.leadInSilenceSeconds
        let transitionSilenceSeconds = json["transitionSilenceSeconds"] as? Double
          ?? (json["transitionSilenceSeconds"] as? Int).map(Double.init)
          ?? SyncSettings.default.transitionSilenceSeconds
        let transitionWindowSeconds = json["transitionWindowSeconds"] as? Double
          ?? (json["transitionWindowSeconds"] as? Int).map(Double.init)
          ?? SyncSettings.default.transitionWindowSeconds
        state.updateSettings(SyncSettings(
          spotifyOffsetSeconds: max(-30, min(30, offset)),
          spotifyStartDelaySeconds: max(0, min(10, startDelay)),
          activityThreshold: max(0.00001, min(0.1, activityThreshold)),
          silenceThreshold: max(0.00001, min(0.1, silenceThreshold)),
          leadInSilenceSeconds: max(0.05, min(5, leadInSilenceSeconds)),
          transitionSilenceSeconds: max(0.2, min(10, transitionSilenceSeconds)),
          transitionWindowSeconds: max(1, min(120, transitionWindowSeconds))
        ))
        respondJSON(connection: connection, status: 200, body: ["ok": true])
      } catch {
        respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
      }
      return
    }

    if request.method == "POST", request.path == "/sync/next" {
      if let request = state.nextTrack() {
        schedulePlayback(request)
      }
      respondJSON(connection: connection, status: 200, body: ["ok": true])
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

    if request.method == "POST", request.path == "/spotify/play-current" {
      let snapshot = state.currentSnapshot()
      if snapshot.sidePlan.tracks.indices.contains(snapshot.currentTrackIndex),
         let uri = snapshot.sidePlan.tracks[snapshot.currentTrackIndex].uri {
        let positionMs = Int(max(0, snapshot.currentTrackElapsedSeconds + snapshot.settings.spotifyOffsetSeconds) * 1000)
        spotify.play(uri: uri, positionMs: positionMs, reason: "manual")
        respondJSON(connection: connection, status: 200, body: ["ok": true])
      } else {
        respondJSON(connection: connection, status: 400, body: ["error": "Current track has no Spotify URI. Load the side from Discogs first."])
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

  private func handleSidePost(request: HTTPRequest, connection: NWConnection) {
    do {
      let plan = try JSONDecoder().decode(SidePlan.self, from: request.body)
      guard !plan.tracks.isEmpty else {
        respondJSON(connection: connection, status: 400, body: ["error": "Side must contain at least one track."])
        return
      }
      state.configureSide(plan)
      respondJSON(connection: connection, status: 200, body: ["ok": true])
    } catch {
      respondJSON(connection: connection, status: 400, body: ["error": error.localizedDescription])
    }
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
    let sampleCount = payload.count / MemoryLayout<Float>.size
    var sum: Float = 0

    payload.withUnsafeBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: Float.self)
      for sample in samples {
        sum += sample * sample
      }
    }

    let rms = sampleCount == 0 ? 0 : sqrt(sum / Float(sampleCount))
    if let request = state.receiveAudio(sampleCount: sampleCount, rms: rms) {
      schedulePlayback(request)
    }
    let silenceThreshold = Float(state.currentSettings().silenceThreshold)
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
          let resolution = try spotify.trackResolution(
            isrc: match.isrc,
            title: match.title,
            artist: match.artist
          )
          guard self.offsetTracker.status().trackIdentity == identity else { return }
          self.shazamPlaybackLock.lock()
          self.currentShazamPlaybackID = identity
          self.currentShazamPlaybackURI = resolution.uri
          self.shazamPlaybackLock.unlock()
          self.updateResolvedTrack(resolution)
          spotify.play(
            uri: resolution.uri,
            positionMs: Int(positionSeconds * 1000),
            reason: "Shazam confirmed \(match.artist) — \(match.title)"
          )
          self.resolvePressing(for: resolution)
        } catch {
          print("Shazam match could not be mapped to Spotify: \(error.localizedDescription)")
        }
      }
    case let .correct(positionSeconds):
      shazamPlaybackLock.lock()
      let uri = currentShazamPlaybackID == match.identity ? currentShazamPlaybackURI : ""
      shazamPlaybackLock.unlock()
      guard !uri.isEmpty else { return }
      DispatchQueue.global(qos: .userInitiated).async { [spotify] in
        spotify.play(
          uri: uri,
          positionMs: Int(positionSeconds * 1000),
          reason: "Shazam drift correction for \(match.artist) — \(match.title)"
        )
      }
    }
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
      let match = try discogs.matchOwnedRelease(album: track.albumName, artist: track.albumArtists)
      metadataLock.lock()
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
      pressingState = "unavailable"
      pressingMatch = nil
      pressingError = error.localizedDescription
      metadataLock.unlock()
    }
  }

  private func schedulePlayback(_ request: PlaybackRequest) {
    guard request.startDelaySeconds > 0 else {
      spotify.play(uri: request.uri, positionMs: request.positionMs, reason: request.reason)
      return
    }

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + request.startDelaySeconds) { [spotify] in
      spotify.play(uri: request.uri, positionMs: request.positionMs, reason: "\(request.reason) delayed")
    }
  }

  private func statusPayload(_ snapshot: SyncSnapshot) -> [String: Any] {
    [
      "audioConnected": snapshot.audioConnected,
      "lastDeviceName": snapshot.lastDeviceName,
      "sampleRate": snapshot.sampleRate,
      "frameCount": snapshot.frameCount,
      "streamSeconds": snapshot.streamSeconds,
      "rms": snapshot.rms,
      "lastSeen": ISO8601DateFormatter().string(from: snapshot.lastSeen),
      "side": sidePayload(snapshot.sidePlan),
      "mode": snapshot.mode,
      "audioActive": snapshot.audioActive,
      "silenceSeconds": snapshot.silenceSeconds,
      "sideElapsedSeconds": snapshot.sideElapsedSeconds,
      "currentTrackIndex": snapshot.currentTrackIndex,
      "currentTrackElapsedSeconds": snapshot.currentTrackElapsedSeconds,
      "currentTrackRemainingSeconds": snapshot.currentTrackRemainingSeconds,
      "currentTrackTitle": snapshot.currentTrackTitle,
      "nextTrackTitle": snapshot.nextTrackTitle,
      "needleDropAt": snapshot.needleDropAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
      "event": snapshot.event,
      "pendingTrackIndex": snapshot.pendingTrackIndex.map { $0 as Any } ?? NSNull(),
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

  private func settingsPayload(_ settings: SyncSettings) -> [String: Any] {
    [
      "spotifyOffsetSeconds": settings.spotifyOffsetSeconds,
      "spotifyStartDelaySeconds": settings.spotifyStartDelaySeconds,
      "activityThreshold": settings.activityThreshold,
      "silenceThreshold": settings.silenceThreshold,
      "leadInSilenceSeconds": settings.leadInSilenceSeconds,
      "transitionSilenceSeconds": settings.transitionSilenceSeconds,
      "transitionWindowSeconds": settings.transitionWindowSeconds
    ]
  }

  private func sidePayload(_ side: SidePlan) -> [String: Any] {
    [
      "name": side.name,
      "tracks": side.tracks.map {
        ["position": $0.position ?? "", "title": $0.title, "durationSeconds": $0.durationSeconds, "uri": $0.uri ?? ""] as [String: Any]
      }
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

  private func sidePlan(from release: [String: Any], sideKey: String? = nil) -> SidePlan? {
    guard let sides = release["sides"] as? [String: [[String: Any]]] else { return nil }
    let sideOrder = release["sideOrder"] as? [String] ?? sides.keys.sorted()
    let selected = sideKey ?? sideOrder.first
    guard let selected, let tracks = sides[selected], !tracks.isEmpty else { return nil }
    let name = "\(release["artists"] as? String ?? "") - \(release["name"] as? String ?? "Discogs release") - Side \(selected)"
    return SidePlan(name: name.trimmingCharacters(in: CharacterSet(charactersIn: " -")), tracks: tracks.map {
      SideTrack(
        position: $0["position"] as? String,
        title: $0["title"] as? String ?? "Untitled",
        durationSeconds: $0["durationSeconds"] as? Double ?? 0,
        uri: $0["uri"] as? String
      )
    })
  }

  private func mergeReleaseWithSpotify(_ original: [String: Any]) -> [String: Any] {
    var release = original
    guard var sides = release["sides"] as? [String: [[String: Any]]] else { return release }
    let query = [release["artists"] as? String, release["name"] as? String].compactMap { $0 }.joined(separator: " ")
    let discogsTracks = flattenedTracks(from: release)
    guard let spotifyMatch = bestSpotifyMatch(for: release, query: query, discogsTracks: discogsTracks),
          let spotifyTracks = spotifyMatch.album["tracks"] as? [[String: Any]] else {
      return release
    }

    var used = Set<Int>()
    var flatIndex = 0
    let sideOrder = release["sideOrder"] as? [String] ?? sides.keys.sorted()
    for side in sideOrder {
      var sideTracks = sides[side] ?? []
      for index in sideTracks.indices {
        let title = normalizeTitle(sideTracks[index]["title"] as? String ?? "")
        let exactIndex = spotifyTracks.indices.first { candidate in
          !used.contains(candidate) && normalizeTitle(spotifyTracks[candidate]["title"] as? String ?? "") == title
        }
        let matchedIndex = exactIndex ?? (spotifyTracks.indices.contains(flatIndex) ? flatIndex : nil)
        if let matchedIndex {
          used.insert(matchedIndex)
          flatIndex = max(flatIndex, matchedIndex + 1)
          sideTracks[index]["durationSeconds"] = spotifyTracks[matchedIndex]["durationSeconds"] as? Double ?? sideTracks[index]["durationSeconds"] ?? 0
          sideTracks[index]["uri"] = spotifyTracks[matchedIndex]["uri"] as? String ?? ""
        }
      }
      sides[side] = sideTracks
    }

    release["sides"] = sides
    release["spotifyMatch"] = [
      "id": spotifyMatch.id,
      "name": spotifyMatch.album["name"] as? String ?? "",
      "artists": spotifyMatch.album["artists"] as? String ?? "",
      "image": spotifyMatch.album["image"] as? String ?? "",
      "score": spotifyMatch.score,
      "trackMatches": spotifyMatch.trackMatches,
      "trackCount": spotifyTracks.count,
      "discogsTrackCount": discogsTracks.count,
      "confidence": spotifyMatch.score >= 70 ? "high" : spotifyMatch.score >= 45 ? "medium" : "low"
    ]
    if (release["image"] as? String ?? "").isEmpty {
      release["image"] = spotifyMatch.album["image"] as? String ?? ""
    }
    return release
  }

  private struct SpotifyAlbumMatch {
    var id: String
    var album: [String: Any]
    var score: Int
    var trackMatches: Int
  }

  private func bestSpotifyMatch(for release: [String: Any], query: String, discogsTracks: [[String: Any]]) -> SpotifyAlbumMatch? {
    guard let candidates = try? spotify.searchAlbums(query: query), !candidates.isEmpty else { return nil }
    let releaseTitle = normalizeTitle(release["name"] as? String ?? "")
    let releaseArtists = normalizeTitle(release["artists"] as? String ?? "")
    var best: SpotifyAlbumMatch?

    for candidate in candidates.prefix(8) {
      guard let id = candidate["id"] as? String,
            let spotifyAlbum = try? spotify.albumForAlbum(id: id).album,
            let spotifyTracks = spotifyAlbum["tracks"] as? [[String: Any]] else {
        continue
      }

      let albumTitle = normalizeTitle(spotifyAlbum["name"] as? String ?? "")
      let albumArtists = normalizeTitle(spotifyAlbum["artists"] as? String ?? "")
      let titleMatch = albumTitle == releaseTitle || albumTitle.contains(releaseTitle) || releaseTitle.contains(albumTitle)
      let artistMatch = !albumArtists.isEmpty && !releaseArtists.isEmpty && (albumArtists.contains(releaseArtists) || releaseArtists.contains(albumArtists))
      let trackMatches = orderedTitleMatches(discogsTracks: discogsTracks, spotifyTracks: spotifyTracks)
      let trackCountDelta = abs(spotifyTracks.count - discogsTracks.count)

      var score = 0
      if titleMatch { score += 35 }
      if artistMatch { score += 25 }
      if trackCountDelta == 0 {
        score += 20
      } else if trackCountDelta <= 2 {
        score += 8
      } else {
        score -= min(20, trackCountDelta * 2)
      }
      if !discogsTracks.isEmpty {
        score += Int((Double(trackMatches) / Double(discogsTracks.count)) * 40)
      }

      let match = SpotifyAlbumMatch(id: id, album: spotifyAlbum, score: score, trackMatches: trackMatches)
      if best == nil || match.score > best!.score {
        best = match
      }
    }

    return best
  }

  private func flattenedTracks(from release: [String: Any]) -> [[String: Any]] {
    guard let sides = release["sides"] as? [String: [[String: Any]]] else { return [] }
    let sideOrder = release["sideOrder"] as? [String] ?? sides.keys.sorted()
    return sideOrder.flatMap { sides[$0] ?? [] }
  }

  private func orderedTitleMatches(discogsTracks: [[String: Any]], spotifyTracks: [[String: Any]]) -> Int {
    var matches = 0
    for index in 0..<min(discogsTracks.count, spotifyTracks.count) {
      let discogsTitle = normalizeTitle(discogsTracks[index]["title"] as? String ?? "")
      let spotifyTitle = normalizeTitle(spotifyTracks[index]["title"] as? String ?? "")
      if !discogsTitle.isEmpty, !spotifyTitle.isEmpty,
         (discogsTitle == spotifyTitle || discogsTitle.contains(spotifyTitle) || spotifyTitle.contains(discogsTitle)) {
        matches += 1
      }
    }
    return matches
  }

  private func normalizeTitle(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\[[^]]*\\]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
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
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
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

func legacyPageHTML() -> String {
  """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Vinyl Sync</title>
      <link rel="icon" type="image/svg+xml" href="/favicon.svg">
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
      <style>
        :root {
          --bg: #f7f8f9; --card: #ffffff; --bd: #e5e8ec; --tx: #16181d; --sub: #6b7280; --ft: #a5adb8;
          --p2: #fafbfc; --tk: #eceff2; --gn: #16a34a; --gnt: #15803d; --gnb: #e8f5ee;
          --rd: #dc2626; --pu: #7c6fd0; --gy: #8a929c; --hbd: #c3cad3; --btn: #16181d; --btnTx: #fff;
          --acc: #d6437f; --accSoft: rgba(214, 67, 127, 0.11);
          color-scheme: light;
        }
        :root[data-theme="dark"] {
          --bg: #101215; --card: #17191d; --bd: #262a30; --tx: #edeef0; --sub: #9aa1ab; --ft: #5c636d;
          --p2: #101215; --tk: #262a30; --gn: #34c374; --gnt: #34c374; --gnb: rgba(52,195,116,0.13);
          --rd: #ef6b5e; --pu: #9a8fd0; --gy: #7d848e; --hbd: #3a4048; --btn: #edeef0; --btnTx: #101215;
          --accSoft: rgba(214, 67, 127, 0.16);
          color-scheme: dark;
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--tx); font-family: 'Space Grotesk', system-ui, sans-serif; }
        button, input, select { font: inherit; color: inherit; }
        button { cursor: pointer; }
        .mono { font-family: 'IBM Plex Mono', ui-monospace, monospace; }
        .header { position: sticky; top: 0; z-index: 5; display: flex; align-items: center; gap: 18px; padding: 12px 24px; background: var(--card); border-bottom: 1px solid var(--bd); }
        .logo { font-size: 17px; font-weight: 600; letter-spacing: -0.01em; white-space: nowrap; }
        .logo span, .accent { color: var(--acc); }
        .release-wrap { position: relative; }
        .release-wrap.rail-picker { margin-bottom: 14px; }
        .chip { display: flex; align-items: center; gap: 9px; padding: 5px 12px 5px 6px; background: var(--bg); border: 1px solid var(--bd); border-radius: 8px; cursor: pointer; min-height: 40px; width: 100%; }
        .chip:hover, .outline:hover { border-color: var(--hbd); }
        .art-sm, .art-md, .art-xl { flex: none; border-radius: 4px; background: repeating-linear-gradient(45deg,var(--tk),var(--tk) 3px,var(--p2) 3px,var(--p2) 6px); object-fit: cover; display: grid; place-items: center; font: 500 7px 'IBM Plex Mono', monospace; color: var(--gy); overflow: hidden; }
        .art-sm { width: 28px; height: 28px; } .art-md { width: 40px; height: 40px; border-radius: 6px; } .art-xl { width: 100%; aspect-ratio: 1; border-radius: 8px; font-size: 10px; }
        .art-sm img, .art-md img, .art-xl img { width: 100%; height: 100%; object-fit: cover; display: block; }
        .release-title { flex: 1; min-width: 0; font-size: 13px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .release-title span { color: var(--sub); font-weight: 400; }
        .caret { font-size: 9px; color: var(--sub); }
        .dropdown { position: absolute; top: calc(100% + 6px); left: 0; width: 100%; max-width: 100%; max-height: 520px; overflow-y: auto; overflow-x: hidden; background: var(--card); border: 1px solid var(--bd); border-radius: 10px; box-shadow: 0 10px 30px rgba(0,0,0,0.14); padding: 6px; z-index: 20; display: none; }
        .dropdown.open { display: block; }
        .disc-search { position: sticky; top: 0; z-index: 2; background: var(--card); padding: 4px 4px 8px; }
        .disc-search input { width: 100%; background: var(--p2); border: 1px solid var(--bd); border-radius: 8px; padding: 8px 10px; font-size: 12.5px; outline: none; }
        .disc-search input:focus { border-color: var(--hbd); }
        .release-row { display: flex; align-items: center; gap: 10px; padding: 7px; border-radius: 7px; cursor: pointer; min-width: 0; }
        .release-row:hover { background: var(--p2); }
        .release-row.selected { background: var(--accSoft); }
        .row-title { font-size: 13px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .row-meta { font-size: 11px; color: var(--sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .row-copy { flex: 1; min-width: 0; overflow: hidden; }
        .selected-mark { flex: none; width: 10px; text-align: center; }
        .drop-footer { padding: 8px 10px 6px; border-top: 1px solid var(--bd); margin-top: 4px; display: flex; justify-content: space-between; align-items: center; }
        .linkish { border: 0; background: transparent; color: var(--sub); padding: 0; font-size: 11.5px; }
        .linkish:hover { color: var(--acc); }
        .bottom-player { position: fixed; left: 0; right: 0; bottom: 0; z-index: 6; display: flex; justify-content: center; align-items: center; padding: 12px 24px; background: color-mix(in srgb, var(--card) 94%, transparent); border-top: 1px solid var(--bd); backdrop-filter: blur(18px); }
        .now-main { display: flex; align-items: center; gap: 12px; width: min(560px, calc(100vw - 48px)); min-width: 0; }
        .now-copy { display: flex; flex: 1; flex-direction: column; gap: 7px; min-width: 0; }
        .now-line { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
        .now-title { font-size: 14px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .now-sub { font-size: 11.5px; color: var(--sub); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .progress-row { display: flex; align-items: center; gap: 8px; }
        .time { font: 500 10px 'IBM Plex Mono', monospace; color: var(--sub); }
        .mini-progress, .progress { position: relative; overflow: hidden; background: var(--tk); border-radius: 3px; }
        .mini-progress { flex: 1; height: 3px; } .progress { height: 5px; }
        .fill { height: 100%; width: 0%; background: var(--acc); border-radius: inherit; }
        .spotify-chip { display: flex; align-items: center; gap: 8px; padding: 5px 12px 5px 6px; background: var(--bg); border: 1px solid var(--bd); border-radius: 99px; cursor: pointer; margin-left: auto; }
        .avatar { width: 24px; height: 24px; border-radius: 50%; background: var(--tx); color: var(--card); display: grid; place-items: center; font-size: 9px; font-weight: 600; overflow: hidden; }
        .avatar img { width: 100%; height: 100%; object-fit: cover; }
        .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--gn); }
        .dot.bad { background: var(--rd); }
        .spotify-name { font-size: 12px; font-weight: 500; }
        .theme-toggle { width: 26px; height: 26px; flex: none; border-radius: 50%; border: 1.5px solid var(--tx); background: linear-gradient(90deg,var(--tx) 50%,transparent 50%); cursor: pointer; }
        .outline { padding: 6px 13px; border: 1px solid var(--bd); border-radius: 8px; background: var(--card); font-size: 12.5px; font-weight: 500; }
        .layout { padding: 18px 368px 112px 348px; max-width: 1680px; margin: 0 auto; }
        .stack { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
        .split { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        .card { background: var(--card); border: 1px solid var(--bd); border-radius: 12px; padding: 16px 18px; }
        .card-title { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; font-size: 15px; font-weight: 600; }
        .badge { display: inline-flex; align-items: center; gap: 6px; padding: 3px 9px; border-radius: 99px; background: var(--gnb); color: var(--gnt); font-size: 11px; font-weight: 600; }
        .badge.run { color: var(--acc); background: var(--accSoft); }
        .badge.bad { color: var(--rd); background: rgba(220,38,38,0.12); }
        .device { margin-left: auto; display: flex; gap: 8px; align-items: center; min-width: 0; }
        .device-name { font-size: 12px; color: var(--sub); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .khz { padding: 3px 8px; border-radius: 6px; background: var(--bg); border: 1px solid var(--bd); font: 500 10.5px 'IBM Plex Mono', monospace; }
        .chart-panel { border: 1px solid var(--bd); border-radius: 10px; background: var(--p2); padding: 10px 12px 6px; }
        .chart-head { display: flex; align-items: baseline; gap: 14px; margin-bottom: 4px; }
        .chart-label { font: 600 10px 'IBM Plex Mono', monospace; letter-spacing: 0.08em; color: var(--sub); }
        .chart-value { font: 500 12px 'IBM Plex Mono', monospace; color: var(--acc); }
        .chart-frames { margin-left: auto; font: 500 10px 'IBM Plex Mono', monospace; color: var(--sub); }
        .rms-canvas { width: 100%; height: 180px; display: block; }
        .axis { display: flex; justify-content: space-between; font: 400 9px 'IBM Plex Mono', monospace; color: var(--ft); margin-top: 2px; }
        .stat-list { display: flex; flex-direction: column; gap: 10px; }
        .stat { display: flex; justify-content: space-between; gap: 12px; font-size: 12.5px; }
        .stat span:first-child { color: var(--sub); }
        .stat strong { font: 500 12px 'IBM Plex Mono', monospace; text-align: right; }
        .good { color: var(--gnt); }
        .track-ref { font-size: 11.5px; color: var(--sub); }
        .actions { display: flex; gap: 8px; margin-top: 4px; flex-wrap: wrap; }
        .primary { border: 0; border-radius: 8px; padding: 7px 14px; background: var(--acc); color: #fff; font-size: 12.5px; font-weight: 600; }
        .secondary { border: 1px solid var(--bd); border-radius: 8px; padding: 7px 14px; background: var(--card); font-size: 12.5px; font-weight: 500; }
        .secondary:hover { border-color: var(--hbd); }
        .events { border-left: 2px solid var(--tk); margin-left: 5px; min-height: 260px; }
        .event { position: relative; padding: 0 0 14px 18px; display: flex; align-items: baseline; gap: 10px; }
        .event:before { content: ''; position: absolute; left: -5px; top: 3px; width: 8px; height: 8px; border-radius: 50%; background: var(--gy); box-shadow: 0 0 0 3px var(--card); }
        .event.spotify:before, .event.track:before { background: var(--gn); } .event.needle:before { background: var(--acc); } .event.settings:before { background: var(--pu); } .event.error:before { background: var(--rd); }
        .event-time { font: 500 10.5px 'IBM Plex Mono', monospace; color: var(--sub); }
        .event-type { font-size: 10px; font-weight: 700; letter-spacing: 0.06em; color: var(--gy); text-transform: uppercase; }
        .event.spotify .event-type, .event.track .event-type { color: var(--gn); } .event.needle .event-type { color: var(--acc); } .event.settings .event-type { color: var(--pu); } .event.error .event-type { color: var(--rd); }
        .event-msg { font-size: 12.5px; }
        .rail { position: fixed; top: 76px; bottom: 92px; overflow-y: auto; overflow-x: hidden; padding: 16px; z-index: 4; }
        .left-rail { display: flex; flex-direction: column; gap: 12px; }
        .right-rail { display: flex; flex-direction: column; gap: 14px; }
        .left-rail { left: 24px; width: 300px; }
        .right-rail { right: 24px; width: 320px; }
        .rail-title { font-size: 15px; font-weight: 600; margin-bottom: 10px; }
        .sidebar { padding: 16px; }
        .disc-title { margin-top: 12px; font-size: 17px; font-weight: 600; }
        .disc-meta { margin-top: 4px; font-size: 12px; color: var(--sub); }
        .side-pills { display: flex; gap: 8px; margin: 14px 0; flex-wrap: wrap; }
        .side-pill { width: 32px; height: 32px; border-radius: 7px; border: 1px solid var(--bd); background: var(--card); font-weight: 500; }
        .side-pill.active { background: var(--acc); border-color: var(--acc); color: #fff; font-weight: 600; }
        .track-list { display: grid; gap: 2px; margin: 8px 0 14px; }
        .track-row { display: grid; grid-template-columns: 36px minmax(0,1fr) auto; gap: 10px; align-items: baseline; padding: 9px 10px; border-radius: 7px; }
        .track-row.active { background: var(--accSoft); }
        .trk-num { font: 500 10.5px 'IBM Plex Mono', monospace; color: var(--ft); } .track-row.active .trk-num { color: var(--acc); }
        .trk-title { font-size: 13px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; } .track-row.active .trk-title { font-weight: 600; }
        .trk-time { font: 500 11px 'IBM Plex Mono', monospace; color: var(--sub); } .track-row.active .trk-time { color: var(--acc); }
        .use-side { width: 100%; border: 0; border-radius: 8px; padding: 9px 0; background: var(--btn); color: var(--btnTx); font-size: 13px; font-weight: 600; }
        .caption { margin-top: 10px; font-size: 10.5px; color: var(--ft); line-height: 1.4; }
        .settings-grid { display: grid; grid-template-columns: 1fr; gap: 12px; }
        .field { display: grid; gap: 6px; }
        .field label { font-size: 11px; font-weight: 600; color: var(--sub); text-transform: uppercase; letter-spacing: 0.04em; }
        .field input, .field select { width: 100%; background: var(--p2); border: 1px solid var(--bd); border-radius: 7px; padding: 8px 10px; font: 500 12.5px 'IBM Plex Mono', monospace; }
        .settings-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 4px; }
        @media (max-width: 1200px) { .layout { padding: 18px 24px 112px; } .rail { position: static; max-height: none; } }
      </style>
    </head>
    <body>
      <header class="header">
        <div class="logo">Vinyl Sync<span>.</span></div>
        <div class="spotify-chip" id="spotifyChip" onclick="connectSpotifyIfNeeded()" title="Spotify">
          <div class="avatar" id="spotifyAvatar"></div><div class="dot" id="spotifyDot"></div><div class="spotify-name" id="spotifyName">Spotify</div>
        </div>
        <button class="theme-toggle" onclick="toggleTheme()" title="Toggle theme"></button>
      </header>
      <main class="layout">
        <aside class="card rail left-rail">
          <div>
            <div class="rail-title">Disc selection</div>
            <div class="release-wrap rail-picker">
              <div class="chip" id="releaseChip" onclick="toggleDropdown()">
                <div class="art-sm" id="chipArt"></div>
                <div class="release-title"><span id="chipTitle"></span> <span id="chipArtist"></span></div>
                <div class="caret">▾</div>
              </div>
              <div class="dropdown" id="releaseDropdown">
                <div class="disc-search"><input id="discSearch" type="search" placeholder="Search discs" autocomplete="off" oninput="setDiscSearch(this.value)"></div>
                <div id="releaseRows"></div>
                <div class="drop-footer"><button class="linkish" onclick="loadDiscogsCollection(event)">Refresh collection</button><div class="mono" id="collectionCount">0 releases</div></div>
              </div>
            </div>
          </div>
          <div class="art-xl" id="discArt"></div>
          <div class="disc-title" id="discTitle"></div>
          <div class="disc-meta" id="discMeta"></div>
          <div class="side-pills" id="sidePills"></div>
          <div class="track-list" id="trackList"></div>
          <button class="use-side" onclick="saveSelectedSide()">Use this side</button>
          <div class="caption" id="discCaption"></div>
        </aside>
        <section class="stack">
          <div class="card">
            <div class="card-title"><span>Audio stream</span><span class="badge" id="streamBadge"><span class="dot"></span>Waiting</span><span class="badge" id="shazamBadge">Shazam waiting</span><div class="device"><div class="device-name" id="deviceName">none</div><div class="khz" id="khz">-- kHz</div></div></div>
            <div class="chart-panel">
              <div class="chart-head"><div class="chart-label">RMS</div><div class="chart-value" id="rmsValue">0.00000</div><div class="chart-frames" id="framesLabel">frames 0</div></div>
              <canvas class="rms-canvas" id="rmsGraph"></canvas>
              <div class="axis"><span>-120 s</span><span id="silenceAxis">silence threshold 0.00045</span><span>now</span></div>
            </div>
          </div>
          <div class="split">
            <div class="card">
              <div class="card-title"><span>Album sync</span><span class="badge run" id="modeBadge">Idle</span></div>
              <div class="stat-list">
                <div class="stat"><span>Side elapsed</span><strong><span id="sideElapsed"></span> <span id="sideDivider"></span> <span id="sideTotal"></span></strong></div>
                <div class="progress"><div class="fill" id="sideFill"></div></div>
                <div class="stat"><span>Needle drop</span><strong id="needleDrop"></strong></div>
                <div class="stat"><span>Silence</span><strong id="silence">0.0 s</strong></div>
                <div class="stat"><span>Audio active</span><strong id="active">no</strong></div>
              </div>
            </div>
            <div class="card">
              <div class="card-title"><span>Track sync</span><span class="track-ref" id="trackRef"></span></div>
              <div class="stat-list">
                <div class="stat"><span>Track elapsed</span><strong id="trackElapsed"></strong></div>
                <div class="stat"><span>Est. remaining</span><strong id="trackRemaining"></strong></div>
                <div class="stat"><span>Position offset</span><strong class="accent" id="offsetLabel">+0.00 s</strong></div>
                <div class="stat"><span>Next</span><strong id="nextTrack"></strong></div>
                <div class="actions"><button class="primary" onclick="post('/sync/arm')">Arm</button><button class="secondary" onclick="post('/sync/next')">Next track</button><button class="secondary" onclick="post('/spotify/play-current')">Play muted</button></div>
              </div>
            </div>
          </div>
          <div class="card">
            <div class="card-title">Events</div>
            <div class="events" id="events"></div>
          </div>
        </section>
        <aside class="card rail right-rail">
          <div class="rail-title">Sync settings</div>
          <div class="settings-grid">
            <div class="field"><label>Start delay (s)</label><input id="spotifyStartDelay" type="number" min="0" max="10" step="0.05"></div>
            <div class="field"><label>Position offset (s)</label><input id="spotifyOffset" type="number" min="-30" max="30" step="0.25"></div>
            <div class="field"><label>Active RMS</label><input id="activityThreshold" type="number" min="0.00001" max="0.1" step="0.0001"></div>
            <div class="field"><label>Silence RMS</label><input id="silenceThreshold" type="number" min="0.00001" max="0.1" step="0.0001"></div>
            <div class="field"><label>Lead-in silence (s)</label><input id="leadInSilenceSeconds" type="number" min="0.05" max="5" step="0.05"></div>
            <div class="field"><label>Gap seconds</label><input id="transitionSilenceSeconds" type="number" min="0.2" max="10" step="0.1"></div>
            <div class="field"><label>Boundary window (s)</label><input id="transitionWindowSeconds" type="number" min="1" max="120" step="1"></div>
          </div>
          <div class="caption">Start delay waits before firing Spotify. Position offset seeks into the Spotify track. Needle drop is ignored until lead-in silence is seen.</div>
          <div class="settings-actions"><button class="secondary" onclick="resetSettings()">Reset</button><button class="primary" onclick="saveSyncSettings()">Save settings</button></div>
          <div class="rail-title">Credentials</div>
          <div class="settings-grid">
            <div class="field"><label>Spotify client ID</label><input id="cfgSpotifyClientId" type="text" autocomplete="off" spellcheck="false"></div>
            <div class="field"><label>Spotify client secret</label><input id="cfgSpotifySecret" type="password" autocomplete="new-password"></div>
            <div class="field"><label>Spotify redirect URI</label><input id="cfgRedirectUri" type="text" autocomplete="off" spellcheck="false"></div>
            <div class="field"><label>Spotify playback device</label><select id="cfgSpotifyDevice"><option value="">Connect Spotify to load devices</option></select></div>
            <div class="field"><label>Discogs token</label><input id="cfgDiscogsToken" type="password" autocomplete="new-password"></div>
            <div class="field"><label>Discogs username</label><input id="cfgDiscogsUsername" type="text" autocomplete="off" spellcheck="false"></div>
          </div>
          <div class="caption">Secrets are stored in the macOS Keychain, never in the app bundle. Saved secrets stay hidden; leave a secret blank to keep the stored value.</div>
          <div class="settings-actions"><button class="primary" onclick="saveCredentials()">Save credentials</button></div>
        </aside>
      </main>
      <footer class="bottom-player">
        <div class="now-main">
          <div class="art-md" id="nowArt"></div>
          <div class="now-copy">
            <div class="now-line"><div class="now-title" id="nowTitle"></div><div class="now-sub" id="nowSub"></div></div>
            <div class="progress-row"><div class="time" id="nowElapsed"></div><div class="mini-progress"><div class="fill" id="nowFill"></div></div><div class="time" id="nowDur"></div></div>
          </div>
        </div>
      </footer>
      <script>
        let releases = [];
        let activeAlbum = null;
        let selectedSide = 'A';
        let selectedReleaseId = null;
        let discSearchTerm = '';
        let lastStatus = null;
        let lastBackendEvent = '';
        let lastShazamIdentity = '';
        let lastShazamError = '';
        let syncSettings = { spotifyOffsetSeconds: 0, spotifyStartDelaySeconds: 0, activityThreshold: 0.001, silenceThreshold: 0.00045, leadInSilenceSeconds: 0.45, transitionSilenceSeconds: 1.6, transitionWindowSeconds: 35 };
        const rmsHistory = [];
        const eventLog = [];
        let lastEvent = '';
        const accents = ['#d6437f', '#0f766e', '#4655d4', '#c2503a', '#7048c8'];

        function initTheme() {
          const stored = localStorage.getItem('vinylsync-theme');
          const theme = stored || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
          document.documentElement.dataset.theme = theme;
          document.documentElement.style.setProperty('--acc', localStorage.getItem('vinylsync-accent') || accents[0]);
        }
        function toggleTheme() {
          const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
          document.documentElement.dataset.theme = next;
          localStorage.setItem('vinylsync-theme', next);
          drawRmsGraph(Number(lastStatus?.rms || 0), syncSettings);
        }
        function fmt(seconds) {
          const value = Math.max(0, Number(seconds || 0));
          const mins = Math.floor(value / 60);
          const secs = Math.floor(value % 60).toString().padStart(2, '0');
          return `${mins}:${secs}`;
        }
        function sideDuration(side) { return (side.tracks || []).reduce((sum, track) => sum + Number(track.durationSeconds || 0), 0); }
        function getAlbumSides(album) { return album?.sides || { A: album?.tracks || [] }; }
        function getSideKeys(album) { const sides = getAlbumSides(album); return (album?.sideOrder || Object.keys(sides).sort()).filter((key) => (sides[key] || []).length); }
        function selectedTracks() { return (getAlbumSides(activeAlbum)[selectedSide] || []); }
        function sidePlanFromAlbum(album, sideKey) { return { name: `${album?.artists ? album.artists + ' - ' : ''}${album?.name || ''}${album?.name ? ' - ' : ''}Side ${sideKey}`, tracks: getAlbumSides(album)[sideKey] || [] }; }
        function artHTML(src, label = '') { return src ? `<img src="${src}" alt="">` : label; }
        function firstName(name) { return String(name || 'Spotify').split(' ')[0] || 'Spotify'; }
        function initials(name) { return String(name || '--').split(' ').map((p) => p[0]).join('').slice(0, 2).toUpperCase() || '--'; }
        function normalizeSearch(value) { return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim(); }
        function classifyEvent(event) {
          const value = String(event || '').toLowerCase();
          if (value.includes('spotify') || value.includes('play')) return 'spotify';
          if (value.includes('needle') || value.includes('first track')) return 'needle';
          if (value.includes('track') || value.includes('timeline')) return 'track';
          if (value.includes('silence') || value.includes('waiting')) return 'silence';
          if (value.includes('setting')) return 'settings';
          if (value.includes('error') || value.includes('no spotify')) return 'error';
          return 'silence';
        }
        function pushEvent(event) {
          if (!event || event === lastEvent) return;
          lastEvent = event;
          eventLog.unshift({ event, type: classifyEvent(event), at: new Date() });
          eventLog.splice(14);
          renderEvents();
        }
        function renderEvents() {
          const target = document.getElementById('events');
          target.innerHTML = eventLog.length ? '' : '<div class="event"><span class="event-time mono">--</span><span class="event-type">idle</span><span class="event-msg">Waiting for sync events</span></div>';
          for (const item of eventLog) {
            const row = document.createElement('div');
            row.className = `event ${item.type}`;
            row.innerHTML = `<span class="event-time mono">${item.at.toLocaleTimeString()}</span><span class="event-type">${item.type}</span><span class="event-msg">${item.event}</span>`;
            target.append(row);
          }
        }
        function clearDiscDisplay() {
          document.getElementById('discTitle').textContent = '';
          document.getElementById('discMeta').textContent = '';
          document.getElementById('discArt').innerHTML = '';
          document.getElementById('chipArt').innerHTML = '';
          document.getElementById('chipTitle').textContent = '';
          document.getElementById('chipArtist').textContent = '';
          document.getElementById('discCaption').textContent = '';
          document.getElementById('sidePills').innerHTML = '';
          document.getElementById('trackList').innerHTML = '';
        }
        function clearTrackDisplay() {
          document.getElementById('trackRef').textContent = '';
          document.getElementById('trackElapsed').textContent = '';
          document.getElementById('trackRemaining').textContent = '';
          document.getElementById('nextTrack').textContent = '';
          document.getElementById('nowTitle').textContent = '';
          document.getElementById('nowSub').textContent = '';
          document.getElementById('nowElapsed').textContent = '';
          document.getElementById('nowDur').textContent = '';
          document.getElementById('nowFill').style.width = '0%';
          document.getElementById('nowArt').innerHTML = '';
          document.getElementById('sideElapsed').textContent = '';
          document.getElementById('sideDivider').textContent = '';
          document.getElementById('sideTotal').textContent = '';
          document.getElementById('sideFill').style.width = '0%';
          document.getElementById('needleDrop').textContent = '';
        }
        function toggleDropdown(force) {
          const dropdown = document.getElementById('releaseDropdown');
          dropdown.classList.toggle('open', force);
          if (dropdown.classList.contains('open')) setTimeout(() => document.getElementById('discSearch')?.focus(), 0);
        }
        document.addEventListener('click', (event) => { if (!event.target.closest('.release-wrap')) toggleDropdown(false); });
        function setDiscSearch(value) { discSearchTerm = value; renderReleaseRows(); }
        function connectSpotifyIfNeeded() { if (!lastStatus?.spotify?.authenticated) window.location.href = '/spotify/login'; }
        async function post(path) {
          const response = await fetch(path, { method: 'POST' });
          if (!response.ok) alert((await response.json().catch(() => ({ error: 'Request failed.' }))).error || 'Request failed.');
          await tick();
        }
        async function saveSyncSettings() {
          const value = (id) => Number(document.getElementById(id).value || 0);
          const response = await fetch('/sync/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ spotifyOffsetSeconds: value('spotifyOffset'), spotifyStartDelaySeconds: value('spotifyStartDelay'), activityThreshold: value('activityThreshold'), silenceThreshold: value('silenceThreshold'), leadInSilenceSeconds: value('leadInSilenceSeconds'), transitionSilenceSeconds: value('transitionSilenceSeconds'), transitionWindowSeconds: value('transitionWindowSeconds') }) });
          if (!response.ok) alert((await response.json().catch(() => ({ error: 'Could not save settings.' }))).error || 'Could not save settings.');
          await loadSyncSettings();
          await tick();
        }
        async function loadCredentials() {
          const response = await fetch('/api/config');
          if (!response.ok) return;
          const config = await response.json();
          document.getElementById('cfgSpotifyClientId').value = config.spotifyClientId || '';
          document.getElementById('cfgRedirectUri').value = config.spotifyRedirectUri || '';
          document.getElementById('cfgDiscogsUsername').value = config.discogsUsername || '';
          document.getElementById('cfgSpotifySecret').placeholder = config.spotifyClientSecretSet ? 'saved' : 'not set';
          document.getElementById('cfgDiscogsToken').placeholder = config.discogsTokenSet ? 'saved' : 'not set';
          await loadSpotifyDevices(config);
        }
        async function loadSpotifyDevices(config) {
          const select = document.getElementById('cfgSpotifyDevice');
          select.innerHTML = '';
          if (config.spotifyTargetDeviceId) {
            const saved = document.createElement('option');
            saved.value = config.spotifyTargetDeviceId;
            saved.dataset.name = config.spotifyTargetDeviceName || 'Saved device';
            saved.textContent = `${saved.dataset.name} (saved)`;
            saved.selected = true;
            select.appendChild(saved);
          }
          const response = await fetch('/spotify/devices');
          if (response.ok) {
            const data = await response.json();
            for (const device of data.devices || []) {
              let option = Array.from(select.options).find((item) => item.value === device.id);
              if (!option) { option = document.createElement('option'); select.appendChild(option); }
              option.value = device.id;
              option.dataset.name = device.name || 'Unknown device';
              option.textContent = `${option.dataset.name}${device.isActive ? ' · active' : ''}${device.isRestricted ? ' · restricted' : ''}`;
              option.selected = device.id === config.spotifyTargetDeviceId;
            }
          }
          if (!select.options.length) {
            const option = document.createElement('option');
            option.value = '';
            option.textContent = 'No Spotify devices available';
            select.appendChild(option);
          }
        }
        async function saveCredentials() {
          const value = (id) => document.getElementById(id).value.trim();
          const device = document.getElementById('cfgSpotifyDevice');
          const selectedDevice = device.options[device.selectedIndex];
          const body = { spotifyClientId: value('cfgSpotifyClientId'), spotifyRedirectUri: value('cfgRedirectUri'), spotifyTargetDeviceId: device.value, spotifyTargetDeviceName: selectedDevice?.dataset.name || '', discogsUsername: value('cfgDiscogsUsername') };
          if (value('cfgSpotifySecret')) body.spotifyClientSecret = value('cfgSpotifySecret');
          if (value('cfgDiscogsToken')) body.discogsToken = value('cfgDiscogsToken');
          const response = await fetch('/api/config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
          if (!response.ok) { alert((await response.json().catch(() => ({ error: 'Could not save credentials.' }))).error || 'Could not save credentials.'); return; }
          document.getElementById('cfgSpotifySecret').value = '';
          document.getElementById('cfgDiscogsToken').value = '';
          pushEvent('Credentials saved');
          await loadCredentials();
          await tick();
        }
        async function resetSettings() {
          const defaults = { spotifyOffset: 0, spotifyStartDelay: 0, activityThreshold: 0.001, silenceThreshold: 0.00045, leadInSilenceSeconds: 0.45, transitionSilenceSeconds: 1.6, transitionWindowSeconds: 35 };
          for (const [id, value] of Object.entries(defaults)) document.getElementById(id).value = value;
          await saveSyncSettings();
        }
        function renderReleaseRows() {
          const rows = document.getElementById('releaseRows');
          rows.innerHTML = '';
          const query = normalizeSearch(discSearchTerm);
          const filtered = query ? releases.filter((release) => normalizeSearch(`${release.title} ${release.artists || ''} ${release.year || ''}`).includes(query)) : releases;
          if (!filtered.length) {
            const empty = document.createElement('div');
            empty.className = 'drop-footer';
            empty.textContent = query ? 'No matching discs' : 'No discs loaded';
            rows.append(empty);
          }
          for (const release of filtered) {
            const row = document.createElement('div');
            row.className = `release-row ${Number(release.id) === Number(selectedReleaseId) ? 'selected' : ''}`;
            row.onclick = () => loadDiscogsRelease(release.id);
            row.innerHTML = `<div class="art-sm">${artHTML(release.thumb)}</div><div class="row-copy"><div class="row-title">${release.title}</div><div class="row-meta">${release.artists || ''} · ${release.year || ''}</div></div><div class="accent selected-mark">${Number(release.id) === Number(selectedReleaseId) ? '●' : ''}</div>`;
            rows.append(row);
          }
          document.getElementById('collectionCount').textContent = query ? `${filtered.length} / ${releases.length} releases` : `${releases.length} releases`;
        }
        async function loadDiscogsCollection(event) {
          if (event) event.stopPropagation();
          const response = await fetch('/discogs/collection');
          const data = await response.json();
          if (!response.ok) { pushEvent(data.error || 'Could not load Discogs collection'); return; }
          releases = data.releases || [];
          renderReleaseRows();
        }
        async function loadDiscogsRelease(id) {
          selectedReleaseId = Number(id);
          toggleDropdown(false);
          const response = await fetch('/discogs/load-release', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: selectedReleaseId }) });
          const data = await response.json();
          if (!response.ok) { pushEvent(data.error || 'Could not load Discogs release'); return; }
          activeAlbum = data.release;
          selectedSide = (activeAlbum.sideOrder || Object.keys(activeAlbum.sides || {}))[0] || 'A';
          pushEvent(activeAlbum.spotifyMatch?.name ? `Spotify match: ${activeAlbum.spotifyMatch.name} (${activeAlbum.spotifyMatch.confidence}, ${activeAlbum.spotifyMatch.trackMatches}/${activeAlbum.spotifyMatch.discogsTrackCount} tracks)` : 'Loaded Discogs release without Spotify match');
          renderReleaseRows();
          renderDisc();
          await saveSelectedSide();
        }
        async function saveSelectedSide() {
          if (!activeAlbum) return;
          const response = await fetch('/side', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(sidePlanFromAlbum(activeAlbum, selectedSide)) });
          if (!response.ok) alert((await response.json().catch(() => ({ error: 'Could not save side.' }))).error || 'Could not save side.');
          await tick();
        }
        function selectSide(side) { selectedSide = side; renderDisc(); saveSelectedSide(); }
        function drawRmsGraph(rms, settings) {
          rmsHistory.push(rms); if (rmsHistory.length > 240) rmsHistory.shift();
          const canvas = document.getElementById('rmsGraph'); const rect = canvas.getBoundingClientRect(); const scale = window.devicePixelRatio || 1;
          const width = Math.max(1, Math.floor(rect.width * scale)); const height = Math.max(1, Math.floor(rect.height * scale));
          if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
          const styles = getComputedStyle(document.documentElement); const ctx = canvas.getContext('2d'); ctx.clearRect(0, 0, width, height);
          const maxRms = Math.max(0.004, Number(settings.activityThreshold || 0.001) * 12, ...rmsHistory) * 1.15;
          const yFor = (value) => height - Math.sqrt(Math.min(1, Math.max(0, value / maxRms))) * height;
          const drawThreshold = (value) => { const y = yFor(Number(value || 0)); ctx.strokeStyle = styles.getPropertyValue('--hbd').trim(); ctx.lineWidth = scale; ctx.setLineDash([3 * scale, 4 * scale]); ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke(); ctx.setLineDash([]); };
          drawThreshold(settings.silenceThreshold); drawThreshold(settings.activityThreshold);
          ctx.strokeStyle = styles.getPropertyValue('--acc').trim(); ctx.lineWidth = 1.4 * scale; ctx.beginPath();
          rmsHistory.forEach((value, index) => { const x = rmsHistory.length <= 1 ? width : (index / (rmsHistory.length - 1)) * width; const y = yFor(value); if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y); }); ctx.stroke();
        }
        function renderDisc(status) {
          if (!activeAlbum) { clearDiscDisplay(); return; }
          const side = status?.side || sidePlanFromAlbum(activeAlbum, selectedSide);
          const tracks = selectedTracks();
          const titleParts = String(activeAlbum?.name || side.name || '').split(' - Side ');
          document.getElementById('discTitle').textContent = activeAlbum?.name || titleParts[0] || '';
          document.getElementById('discMeta').textContent = activeAlbum ? `${activeAlbum.artists || ''} · Side ${selectedSide} · ${tracks.length} tracks · ${fmt(sideDuration({ tracks }))}` : `${tracks.length} tracks · ${fmt(sideDuration(side))}`;
          document.getElementById('discArt').innerHTML = artHTML(activeAlbum?.image);
          document.getElementById('chipArt').innerHTML = artHTML(activeAlbum?.image);
          document.getElementById('chipTitle').textContent = activeAlbum?.name || '';
          document.getElementById('chipArtist').textContent = activeAlbum?.artists ? `— ${activeAlbum.artists}` : '';
          document.getElementById('discCaption').textContent = activeAlbum?.spotifyMatch?.name ? `Spotify match: ${activeAlbum.spotifyMatch.artists ? activeAlbum.spotifyMatch.artists + ' - ' : ''}${activeAlbum.spotifyMatch.name} (${activeAlbum.spotifyMatch.confidence}, ${activeAlbum.spotifyMatch.trackMatches}/${activeAlbum.spotifyMatch.discogsTrackCount} tracks).` : 'Sides come from Discogs positions. Spotify matching runs behind the scenes for playback URIs.';
          const pills = document.getElementById('sidePills'); pills.innerHTML = '';
          for (const key of getSideKeys(activeAlbum || { tracks })) { const btn = document.createElement('button'); btn.className = `side-pill ${key === selectedSide ? 'active' : ''}`; btn.textContent = key; btn.onclick = () => selectSide(key); pills.append(btn); }
          const list = document.getElementById('trackList'); list.innerHTML = '';
          const activeIndex = Number(status?.currentTrackIndex || 0);
          tracks.forEach((track, index) => { const row = document.createElement('div'); row.className = `track-row ${index === activeIndex ? 'active' : ''}`; row.innerHTML = `<div class="trk-num">${track.position || String(index + 1).padStart(2, '0')}</div><div class="trk-title">${track.title}</div><div class="trk-time">${fmt(track.durationSeconds)}</div>`; list.append(row); });
        }
        function applySettings(settings) {
          const values = { spotifyOffset: settings.spotifyOffsetSeconds ?? 0, spotifyStartDelay: settings.spotifyStartDelaySeconds ?? 0, activityThreshold: settings.activityThreshold ?? 0.001, silenceThreshold: settings.silenceThreshold ?? 0.00045, leadInSilenceSeconds: settings.leadInSilenceSeconds ?? 0.45, transitionSilenceSeconds: settings.transitionSilenceSeconds ?? 1.6, transitionWindowSeconds: settings.transitionWindowSeconds ?? 35 };
          for (const [id, value] of Object.entries(values)) { const input = document.getElementById(id); if (document.activeElement !== input) input.value = id.includes('Threshold') ? Number(value).toFixed(5) : Number(value).toFixed(2); }
        }
        async function loadSyncSettings() {
          const response = await fetch('/sync/settings');
          const settings = await response.json();
          if (!response.ok) { pushEvent(settings.error || 'Could not load settings'); return; }
          Object.assign(syncSettings, settings);
          applySettings(syncSettings);
        }
        async function tick() {
          const response = await fetch('/status'); const status = await response.json(); lastStatus = status; const side = status.side || { name: '--', tracks: [] };
          if (status.event && status.event !== lastBackendEvent) { lastBackendEvent = status.event; pushEvent(status.event); }
          drawRmsGraph(Number(status.rms || 0), syncSettings);
          document.getElementById('streamBadge').className = `badge ${status.audioConnected ? '' : 'bad'}`; document.getElementById('streamBadge').innerHTML = `<span class="dot ${status.audioConnected ? '' : 'bad'}"></span>${status.audioConnected ? 'Connected' : 'Waiting'}`;
          const shazam = status.shazam || {}; const shazamMatch = shazam.lastMatch || null;
          const shazamError = Boolean(shazam.error); document.getElementById('shazamBadge').className = `badge ${shazamError ? 'bad' : (shazamMatch ? 'run' : '')}`; document.getElementById('shazamBadge').textContent = shazamError ? 'Shazam error' : (shazamMatch ? `Shazam · ${shazamMatch.title}` : `Shazam ${shazam.state || 'waiting'}`);
          if (shazam.error !== lastShazamError) { lastShazamError = shazam.error || ''; if (shazam.error) pushEvent(`Shazam error: ${shazam.error}`); }
          const shazamIdentity = shazamMatch?.shazamID || (shazamMatch ? `${shazamMatch.artist}|${shazamMatch.title}` : '');
          if (shazamIdentity && shazamIdentity !== lastShazamIdentity) { lastShazamIdentity = shazamIdentity; pushEvent(`Shazam confirmed ${shazamMatch.artist} — ${shazamMatch.title} at ${fmt(shazamMatch.predictedOffsetSeconds)}`); }
          document.getElementById('deviceName').textContent = status.lastDeviceName || 'none'; document.getElementById('khz').textContent = status.sampleRate ? `${(Number(status.sampleRate) / 1000).toFixed(1)} kHz` : '-- kHz'; document.getElementById('rmsValue').textContent = Number(status.rms || 0).toFixed(5); document.getElementById('framesLabel').textContent = `frames ${status.frameCount || 0}`; document.getElementById('silenceAxis').textContent = `silence threshold ${Number(syncSettings.silenceThreshold || 0).toFixed(5)}`;
          document.getElementById('modeBadge').textContent = status.mode || 'idle'; document.getElementById('silence').textContent = `${Number(status.silenceSeconds || 0).toFixed(1)} s`; document.getElementById('active').textContent = status.audioActive ? 'yes' : 'no'; document.getElementById('active').className = status.audioActive ? 'good' : '';
          const showSelectedDisc = Boolean(activeAlbum);
          const currentTrack = showSelectedDisc ? (selectedTracks()[status.currentTrackIndex || 0] || {}) : {};
          if (showSelectedDisc) {
            document.getElementById('sideElapsed').textContent = fmt(status.sideElapsedSeconds);
            document.getElementById('sideDivider').textContent = '/';
            document.getElementById('sideTotal').textContent = fmt(sideDuration(side));
            document.getElementById('sideFill').style.width = `${Math.min(100, (Number(status.sideElapsedSeconds || 0) / Math.max(1, sideDuration(side))) * 100)}%`;
            document.getElementById('needleDrop').textContent = status.needleDropAt || '';
            document.getElementById('trackRef').textContent = `${currentTrack.position || ''}${currentTrack.position ? ' · ' : ''}${status.currentTrackTitle || ''}`;
            document.getElementById('trackElapsed').textContent = fmt(status.currentTrackElapsedSeconds);
            document.getElementById('trackRemaining').textContent = fmt(status.currentTrackRemainingSeconds);
            document.getElementById('nextTrack').textContent = status.nextTrackTitle || '';
            document.getElementById('nowTitle').textContent = status.currentTrackTitle || '';
            document.getElementById('nowSub').textContent = [activeAlbum?.artists, currentTrack.position].filter(Boolean).join(' · ');
            document.getElementById('nowElapsed').textContent = fmt(status.currentTrackElapsedSeconds);
            document.getElementById('nowDur').textContent = fmt(currentTrack.durationSeconds);
            document.getElementById('nowFill').style.width = `${Math.min(100, (Number(status.currentTrackElapsedSeconds || 0) / Math.max(1, Number(currentTrack.durationSeconds || 1))) * 100)}%`;
            document.getElementById('nowArt').innerHTML = artHTML(activeAlbum?.image);
          } else {
            clearTrackDisplay();
            if (shazamMatch) {
              document.getElementById('nowTitle').textContent = shazamMatch.title || '';
              document.getElementById('nowSub').textContent = shazamMatch.artist || '';
              document.getElementById('nowElapsed').textContent = fmt(shazamMatch.predictedOffsetSeconds);
              document.getElementById('nowArt').innerHTML = artHTML(shazamMatch.artworkURL);
            }
          }
          const offset = Number(syncSettings.spotifyOffsetSeconds || 0); document.getElementById('offsetLabel').textContent = `${offset >= 0 ? '+' : ''}${offset.toFixed(2)} s`;
          const spotify = status.spotify || {}; document.getElementById('spotifyDot').className = `dot ${spotify.authenticated ? '' : 'bad'}`; document.getElementById('spotifyName').textContent = spotify.authenticated ? firstName(spotify.user) : 'Connect'; document.getElementById('spotifyChip').title = spotify.authenticated ? `Spotify connected as ${spotify.user} (${spotify.targetDevice || ''})` : 'Connect Spotify'; document.getElementById('spotifyAvatar').innerHTML = spotify.image ? `<img src="${spotify.image}" alt="">` : initials(spotify.user);
          renderDisc(status);
        }
        initTheme(); renderEvents(); loadDiscogsCollection(); loadSyncSettings(); loadCredentials(); tick(); setInterval(tick, 1000);
      </script>
    </body>
  </html>
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
          <div class="pressing"><div class="pressing-title">Physical pressing</div><div class="pressing-main" id="pressingMain">Waiting for an album</div><div class="pressing-meta" id="pressingMeta">Discogs is optional and never blocks playback.</div></div>
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
      function renderPressing(pressing){ const match=pressing?.match; if(pressing?.state==='matched'&&match){ $('pressingMain').textContent=match.title||'Owned pressing'; const label=(match.labels||[])[0]||{}; const formats=(match.formats||[]).map(f=>[f.name,f.text,...(f.descriptions||[])].filter(Boolean).join(' ')).filter(Boolean).join(', '); $('pressingMeta').textContent=[match.year,match.country,label.name,label.catalogNumber,formats].filter(Boolean).join(' · ')||'Matched in your Discogs collection'; return; } if(pressing?.state==='ambiguous'){ $('pressingMain').textContent=`${match?.candidateCount||'Multiple'} owned pressings match`; $('pressingMeta').textContent='A small pressing chooser will be used only when needed.'; return; } const copy={searching:'Checking your Discogs collection…','not found':'Album recognized; owned pressing not found','not configured':'Connect Discogs to show pressing details',unavailable:'Discogs is temporarily unavailable',waiting:'Waiting for an album'}; $('pressingMain').textContent=copy[pressing?.state]||'Waiting for an album'; $('pressingMeta').textContent=pressing?.error||'Discogs is optional and never blocks playback.'; }
      function render(status){ const shazam=status.shazam||{}, spotify=status.spotify||{}, now=status.nowPlaying||null, match=shazam.lastMatch||null, track=now||match; dot('audioDot',status.audioConnected?'ok':'bad'); $('audioHealth').textContent=status.audioConnected?`Audio · ${status.lastDeviceName||'connected'}`:'Audio disconnected'; const shazamOK=shazam.state==='confirmed'; dot('shazamDot',shazam.error?'bad':shazamOK?'ok':''); $('shazamHealth').textContent=shazamOK?`Shazam · ${match?.title||'confirmed'}`:`Shazam · ${shazam.state||'waiting'}`; dot('spotifyDot',spotify.authenticated?'ok':'bad'); $('spotifyHealth').textContent=spotify.authenticated?`Spotify · ${spotify.targetDevice||spotify.user||'connected'}`:'Spotify not connected'; if(track){ $('hero').classList.remove('empty'); $('stateLabel').textContent=now?'Now following':'Match confirmed'; $('title').textContent=track.title||'Unknown track'; $('artist').textContent=track.artist||''; $('album').textContent=now?.albumName||''; const art=now?.albumImage||match?.artworkURL||''; $('art').innerHTML=art?`<img src="${safe(art)}" alt="">`:''; const offset=Number(status.offsetTracking?.estimatedOffsetSeconds ?? match?.predictedOffsetSeconds ?? 0); const duration=Number(now?.durationSeconds||0); $('elapsed').textContent=fmt(offset); $('duration').textContent=duration?fmt(duration):'--:--'; $('progressFill').style.width=duration?`${Math.min(100,offset/duration*100)}%`:'0'; } else { $('hero').classList.add('empty'); $('stateLabel').textContent=status.audioConnected?(shazam.state||'Listening'):'Waiting for audio'; $('title').textContent='Drop the needle'; $('artist').textContent='Recognition starts automatically when sound arrives.'; $('album').textContent=''; $('art').innerHTML=''; $('elapsed').textContent='0:00'; $('duration').textContent='--:--'; $('progressFill').style.width='0'; } renderPressing(status.pressing); $('diagInput').textContent=status.lastDeviceName||'—'; $('diagRms').textContent=Number(status.rms||0).toFixed(5); $('diagRate').textContent=status.sampleRate?`${(status.sampleRate/1000).toFixed(1)} kHz`:'—'; $('diagState').textContent=shazam.state||'waiting'; $('diagFrames').textContent=`${shazam.submittedFrames||0} / ${shazam.silentFramesSkipped||0}`; $('diagMatches').textContent=`${shazam.matches||0} / ${shazam.transientErrors||0}`; $('diagOffset').textContent=status.offsetTracking?.trackIdentity?`${Number(status.offsetTracking.estimatedOffsetSeconds||0).toFixed(2)} s · drift ${Number(status.offsetTracking.driftSeconds||0).toFixed(2)} s`:'—'; $('diagSpotify').textContent=spotify.lastAction||'—'; $('diagError').textContent=shazam.error||shazam.lastError||spotify.error||status.pressing?.error||'—'; }
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
