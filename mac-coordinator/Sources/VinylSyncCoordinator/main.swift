import CryptoKit
import Foundation
import Network

struct SideTrack: Codable {
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
      SideTrack(title: "The Requiem", durationSeconds: 121, uri: nil),
      SideTrack(title: "The Radiance", durationSeconds: 57, uri: nil),
      SideTrack(title: "Burning in the Skies", durationSeconds: 253, uri: nil),
      SideTrack(title: "Empty Spaces", durationSeconds: 18, uri: nil),
      SideTrack(title: "When They Come for Me", durationSeconds: 293, uri: nil),
      SideTrack(title: "Robot Boy", durationSeconds: 269, uri: nil)
    ]
  )
}

struct PlaybackRequest {
  var uri: String
  var positionMs: Int
  var reason: String
}

struct SpotifyStatus {
  var configured = false
  var authenticated = false
  var user = "--"
  var targetDevice = "CUTE-GAMING"
  var lastAction = "waiting"
  var error = ""
}

final class SpotifyClient {
  private struct Token: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
  }

  private let clientId: String
  private let clientSecret: String
  private let redirectUri: String
  private let targetDeviceName = "CUTE-GAMING"
  private let tokenURL = URL(fileURLWithPath: ".state/spotify-token.json")
  private let lock = NSLock()
  private var token: Token?
  private var user = "--"
  private var lastAction = "waiting"
  private var lastError = ""

  init() {
    let env = loadEnvironment()
    clientId = env["SPOTIFY_CLIENT_ID"] ?? ""
    clientSecret = env["SPOTIFY_CLIENT_SECRET"] ?? ""
    redirectUri = env["VINYL_SYNC_SPOTIFY_REDIRECT_URI"] ?? "http://127.0.0.1:4739/callback"
    token = Self.loadToken(from: tokenURL)
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
      targetDevice: targetDeviceName,
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
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
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

  func sidePlanForAlbum(id: String) throws -> SidePlan {
    let album = try api("GET", "/albums/\(id)")
    let name = album["name"] as? String ?? "Spotify album"
    let artists = ((album["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
    let items = ((album["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    let tracks = items.map { item in
      SideTrack(
        title: item["name"] as? String ?? "Untitled",
        durationSeconds: Double(item["duration_ms"] as? Int ?? 0) / 1000,
        uri: item["uri"] as? String
      )
    }
    return SidePlan(name: artists.isEmpty ? name : "\(artists) - \(name)", tracks: tracks)
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
    let json = try api("GET", "/me/player/devices")
    let devices = json["devices"] as? [[String: Any]] ?? []
    if let exact = devices.first(where: { ($0["name"] as? String) == targetDeviceName }),
       let id = exact["id"] as? String {
      return id
    }
    if let active = devices.first(where: { ($0["is_active"] as? Bool) == true }),
       let id = active["id"] as? String {
      return id
    }
    throw NSError(domain: "Spotify", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spotify device \(targetDeviceName) not found. Keep Spotify Desktop open on the PC."])
  }

  private func loadProfile() {
    do {
      let me = try api("GET", "/me")
      lock.lock()
      user = me["display_name"] as? String ?? me["id"] as? String ?? "--"
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

func loadEnvironment() -> [String: String] {
  var values = ProcessInfo.processInfo.environment
  for path in [".env", "../.env", "../../vinyl-shadow_archive_20260707_0232/.env"] {
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
}

final class StateStore {
  private let lock = NSLock()
  private var snapshot = SyncSnapshot()

  private let activityThreshold: Float = 0.0010
  private let silenceThreshold: Float = 0.00045
  private let transitionSilenceSeconds = 1.6
  private let transitionWindowSeconds = 35.0

  init() {
    resetLocked(event: "ready")
  }

  func configureSide(_ plan: SidePlan) {
    lock.lock()
    snapshot.sidePlan = plan
    resetLocked(event: "side loaded")
    lock.unlock()
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
    snapshot.mode = "running"
    snapshot.event = "manual next"
    let request = playbackRequestLocked(reason: "manual next")
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

    let activeNow = rms >= activityThreshold
    if activeNow {
      snapshot.silenceSeconds = 0
    } else if rms <= silenceThreshold {
      snapshot.silenceSeconds += delta
    }

    switch snapshot.mode {
    case "armed":
      if activeNow {
        snapshot.mode = "running"
        snapshot.audioActive = true
        snapshot.needleDropAt = Date()
        snapshot.event = "needle drop"
        request = playbackRequestLocked(reason: "needle drop")
      }
    case "running":
      snapshot.sideElapsedSeconds += delta

      let wasActive = snapshot.audioActive
      snapshot.audioActive = activeNow || (snapshot.silenceSeconds < transitionSilenceSeconds)

      let previousIndex = snapshot.currentTrackIndex
      updateTrackFromTimelineLocked()
      if snapshot.currentTrackIndex != previousIndex {
        request = playbackRequestLocked(reason: "timeline")
      }

      if wasActive,
         snapshot.silenceSeconds >= transitionSilenceSeconds,
         shouldSnapToNextTrackLocked() {
        snapToNextTrackLocked(event: "silence gap")
        request = playbackRequestLocked(reason: "silence gap")
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

  private func shouldSnapToNextTrackLocked() -> Bool {
    guard snapshot.currentTrackIndex + 1 < snapshot.sidePlan.tracks.count else { return false }
    return snapshot.currentTrackRemainingSeconds <= transitionWindowSeconds
      || snapshot.currentTrackElapsedSeconds >= 30
  }

  private func snapToNextTrackLocked(event: String) {
    let nextIndex = snapshot.currentTrackIndex + 1
    guard snapshot.sidePlan.tracks.indices.contains(nextIndex) else { return }
    snapshot.sideElapsedSeconds = elapsedAtTrackStartLocked(nextIndex)
    updateTrackFromTimelineLocked()
    snapshot.silenceSeconds = 0
    snapshot.event = event
  }

  private func playbackRequestLocked(reason: String) -> PlaybackRequest? {
    guard snapshot.sidePlan.tracks.indices.contains(snapshot.currentTrackIndex),
          snapshot.playedTrackIndex != snapshot.currentTrackIndex,
          let uri = snapshot.sidePlan.tracks[snapshot.currentTrackIndex].uri,
          !uri.isEmpty else {
      return nil
    }
    snapshot.playedTrackIndex = snapshot.currentTrackIndex
    return PlaybackRequest(
      uri: uri,
      positionMs: Int(max(0, snapshot.currentTrackElapsedSeconds) * 1000),
      reason: reason
    )
  }
}

final class CoordinatorServer {
  private let port: NWEndpoint.Port
  private let listener: NWListener
  private let state = StateStore()
  private let spotify = SpotifyClient()

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

    if request.method == "GET", request.path == "/status" {
      let snapshot = state.currentSnapshot()
      respondJSON(connection: connection, status: 200, body: statusPayload(snapshot))
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

    if request.method == "GET", request.path == "/callback" {
      guard let code = request.query["code"] else {
        respondHTML(connection: connection, body: "<p>Missing Spotify callback code.</p>")
        return
      }
      do {
        try spotify.handleCallback(code: code)
        respondHTML(connection: connection, body: "<p>Spotify connected. You can close this tab or go back to <a href=\"/\">Vinyl Sync</a>.</p>")
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

    if request.method == "POST", request.path == "/spotify/load-album" {
      do {
        guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? String else {
          respondJSON(connection: connection, status: 400, body: ["error": "Missing album id."])
          return
        }
        let plan = try spotify.sidePlanForAlbum(id: id)
        state.configureSide(plan)
        respondJSON(connection: connection, status: 200, body: ["ok": true, "side": sidePayload(plan)])
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

    if request.method == "POST", request.path == "/sync/next" {
      if let request = state.nextTrack() {
        spotify.play(uri: request.uri, positionMs: request.positionMs, reason: request.reason)
      }
      respondJSON(connection: connection, status: 200, body: ["ok": true])
      return
    }

    if request.method == "POST", request.path == "/spotify/play-current" {
      let snapshot = state.currentSnapshot()
      if snapshot.sidePlan.tracks.indices.contains(snapshot.currentTrackIndex),
         let uri = snapshot.sidePlan.tracks[snapshot.currentTrackIndex].uri {
        spotify.play(uri: uri, positionMs: Int(max(0, snapshot.currentTrackElapsedSeconds) * 1000), reason: "manual")
        respondJSON(connection: connection, status: 200, body: ["ok": true])
      } else {
        respondJSON(connection: connection, status: 400, body: ["error": "Current track has no Spotify URI. Load the side from Spotify search first."])
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
            connection.cancel()
            return
          default:
            break
          }
        }
      } catch {
        print("websocket parse error: \(error.localizedDescription)")
        self.state.disconnectAudio()
        connection.cancel()
        return
      }

      if isComplete {
        self.state.disconnectAudio()
        connection.cancel()
      } else {
        self.readWebSocketFrames(connection: connection, buffer: nextBuffer)
      }
    }
  }

  private func handleHello(_ payload: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
    state.receiveHello(
      deviceName: json["deviceName"] as? String ?? "unknown",
      sampleRate: json["sampleRate"] as? Int ?? 0
    )
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
      spotify.play(uri: request.uri, positionMs: request.positionMs, reason: request.reason)
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
      "spotify": spotifyPayload()
    ]
  }

  private func sidePayload(_ side: SidePlan) -> [String: Any] {
    [
      "name": side.name,
      "tracks": side.tracks.map {
        ["title": $0.title, "durationSeconds": $0.durationSeconds, "uri": $0.uri ?? ""] as [String: Any]
      }
    ]
  }

  private func spotifyPayload() -> [String: Any] {
    let status = spotify.status()
    return [
      "configured": status.configured,
      "authenticated": status.authenticated,
      "user": status.user,
      "targetDevice": status.targetDevice,
      "redirectUri": spotify.redirectUriValue,
      "lastAction": status.lastAction,
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

func pageHTML() -> String {
  """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Vinyl Sync</title>
      <style>
        :root { font-family: system-ui, sans-serif; color: #1f2328; background: #f6f2eb; }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 24px; }
        main { max-width: 1120px; margin: 0 auto; }
        h1 { margin: 0 0 18px; font-size: 32px; }
        h2 { margin: 0 0 12px; font-size: 18px; }
        .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
        .panel { border: 1px solid #d8cdc0; border-radius: 8px; background: #fffaf3; padding: 16px; }
        .row { display: flex; justify-content: space-between; gap: 16px; padding: 7px 0; border-bottom: 1px solid #eee2d6; }
        .row:last-child { border-bottom: 0; }
        .label { color: #6b6258; }
        .value { font-weight: 700; text-align: right; overflow-wrap: anywhere; }
        .meter { height: 12px; border-radius: 999px; background: #e3d7ca; overflow: hidden; margin-top: 10px; }
        .bar { height: 100%; width: 0%; background: #2d6a5f; transition: width 120ms linear; }
        .controls { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
        button { border: 1px solid #1f2328; background: #1f2328; color: white; border-radius: 6px; padding: 9px 12px; font: inherit; cursor: pointer; }
        button.secondary { background: transparent; color: #1f2328; }
        input { width: 100%; border: 1px solid #d8cdc0; border-radius: 6px; padding: 10px; font: inherit; background: #fff; color: #1f2328; }
        textarea { width: 100%; min-height: 220px; resize: vertical; border: 1px solid #d8cdc0; border-radius: 6px; padding: 10px; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: #fff; color: #1f2328; }
        .timeline { margin-top: 12px; height: 16px; border-radius: 999px; overflow: hidden; background: #e3d7ca; }
        .progress { height: 100%; width: 0%; background: #8d3f2f; transition: width 160ms linear; }
        .hint { color: #6b6258; font-size: 13px; margin-top: 8px; }
        .results { display: grid; gap: 8px; margin-top: 12px; }
        .result { display: grid; grid-template-columns: 44px minmax(0, 1fr) auto; gap: 10px; align-items: center; border: 1px solid #eee2d6; border-radius: 8px; padding: 8px; background: #fff; }
        .result img { width: 44px; height: 44px; object-fit: cover; border-radius: 4px; background: #e3d7ca; }
        .result-title { font-weight: 700; overflow-wrap: anywhere; }
        .result-meta { color: #6b6258; font-size: 12px; }
        @media (max-width: 820px) { .grid { grid-template-columns: 1fr; } body { padding: 14px; } }
      </style>
    </head>
    <body>
      <main>
        <h1>Vinyl Sync</h1>
        <section class="grid">
          <div class="panel">
            <h2>Audio</h2>
            <div class="row"><span class="label">Stream</span><span class="value" id="connected">--</span></div>
            <div class="row"><span class="label">Input</span><span class="value" id="device">--</span></div>
            <div class="row"><span class="label">Sample rate</span><span class="value" id="sampleRate">--</span></div>
            <div class="row"><span class="label">Frames</span><span class="value" id="frames">--</span></div>
            <div class="row"><span class="label">RMS</span><span class="value" id="rmsValue">--</span></div>
            <div class="meter"><div class="bar" id="rms"></div></div>
          </div>

          <div class="panel">
            <h2>Sync</h2>
            <div class="row"><span class="label">Mode</span><span class="value" id="mode">--</span></div>
            <div class="row"><span class="label">Event</span><span class="value" id="event">--</span></div>
            <div class="row"><span class="label">Audio active</span><span class="value" id="active">--</span></div>
            <div class="row"><span class="label">Silence</span><span class="value" id="silence">--</span></div>
            <div class="row"><span class="label">Side elapsed</span><span class="value" id="sideElapsed">--</span></div>
            <div class="row"><span class="label">Needle drop</span><span class="value" id="needleDrop">--</span></div>
            <div class="controls">
              <button onclick="post('/sync/arm')">Arm</button>
              <button class="secondary" onclick="post('/sync/next')">Next track</button>
              <button class="secondary" onclick="post('/spotify/play-current')">Play current muted</button>
              <button class="secondary" onclick="post('/sync/reset')">Reset</button>
            </div>
          </div>

          <div class="panel">
            <h2>Spotify</h2>
            <div class="row"><span class="label">Auth</span><span class="value" id="spotifyAuth">--</span></div>
            <div class="row"><span class="label">User</span><span class="value" id="spotifyUser">--</span></div>
            <div class="row"><span class="label">Target</span><span class="value" id="spotifyTarget">--</span></div>
            <div class="row"><span class="label">Redirect</span><span class="value" id="spotifyRedirect">--</span></div>
            <div class="row"><span class="label">Action</span><span class="value" id="spotifyAction">--</span></div>
            <div class="row"><span class="label">Error</span><span class="value" id="spotifyError">--</span></div>
            <div class="controls">
              <button onclick="window.location.href='/spotify/login'">Connect Spotify on Mac</button>
            </div>
            <div class="hint">Open this page from the Mac at 127.0.0.1 for Spotify OAuth. PC control works after auth.</div>
          </div>

          <div class="panel">
            <h2>Album Search</h2>
            <input id="albumQuery" placeholder="Search Spotify album">
            <div class="controls">
              <button onclick="searchAlbums()">Search</button>
            </div>
            <div class="results" id="albumResults"></div>
          </div>

          <div class="panel">
            <h2>Now</h2>
            <div class="row"><span class="label">Side</span><span class="value" id="sideName">--</span></div>
            <div class="row"><span class="label">Track</span><span class="value" id="track">--</span></div>
            <div class="row"><span class="label">Track elapsed</span><span class="value" id="trackElapsed">--</span></div>
            <div class="row"><span class="label">Remaining</span><span class="value" id="trackRemaining">--</span></div>
            <div class="row"><span class="label">Next</span><span class="value" id="nextTrack">--</span></div>
            <div class="timeline"><div class="progress" id="progress"></div></div>
          </div>

          <div class="panel">
            <h2>Side Plan</h2>
            <textarea id="sideJson" spellcheck="false"></textarea>
            <div class="controls">
              <button onclick="saveSide()">Save side</button>
              <button class="secondary" onclick="loadTemplate()">Load A Thousand Suns A</button>
            </div>
            <div class="hint">Durations are seconds. Arm after saving, then drop the needle.</div>
          </div>
        </section>
      </main>
      <script>
        const template = {
          name: 'A Thousand Suns - Side A',
          tracks: [
            { title: 'The Requiem', durationSeconds: 121, uri: '' },
            { title: 'The Radiance', durationSeconds: 57, uri: '' },
            { title: 'Burning in the Skies', durationSeconds: 253, uri: '' },
            { title: 'Empty Spaces', durationSeconds: 18, uri: '' },
            { title: 'When They Come for Me', durationSeconds: 293, uri: '' },
            { title: 'Robot Boy', durationSeconds: 269, uri: '' }
          ]
        };

        function fmt(seconds) {
          const value = Math.max(0, Number(seconds || 0));
          const mins = Math.floor(value / 60);
          const secs = Math.floor(value % 60).toString().padStart(2, '0');
          return `${mins}:${secs}`;
        }

        function sideDuration(side) {
          return (side.tracks || []).reduce((sum, track) => sum + Number(track.durationSeconds || 0), 0);
        }

        async function post(path) {
          const response = await fetch(path, { method: 'POST' });
          if (!response.ok) {
            const data = await response.json().catch(() => ({ error: 'Request failed.' }));
            alert(data.error || 'Request failed.');
          }
          await tick();
        }

        async function saveSide() {
          const body = document.getElementById('sideJson').value;
          const response = await fetch('/side', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body
          });
          if (!response.ok) {
            const data = await response.json().catch(() => ({ error: 'Could not save side.' }));
            alert(data.error || 'Could not save side.');
          }
          await tick();
        }

        function loadTemplate() {
          document.getElementById('sideJson').value = JSON.stringify(template, null, 2);
        }

        async function searchAlbums() {
          const query = document.getElementById('albumQuery').value.trim();
          if (!query) return;
          const results = document.getElementById('albumResults');
          results.textContent = 'Searching...';
          const response = await fetch('/spotify/search?q=' + encodeURIComponent(query));
          const data = await response.json();
          if (!response.ok) {
            results.textContent = data.error || 'Search failed.';
            return;
          }
          results.innerHTML = '';
          for (const album of data.albums || []) {
            const row = document.createElement('div');
            row.className = 'result';
            const image = document.createElement('img');
            image.src = album.image || '';
            const text = document.createElement('div');
            const title = document.createElement('div');
            title.className = 'result-title';
            title.textContent = album.name;
            const meta = document.createElement('div');
            meta.className = 'result-meta';
            meta.textContent = [album.artists, album.releaseDate].filter(Boolean).join(' / ');
            text.append(title, meta);
            const button = document.createElement('button');
            button.className = 'secondary';
            button.textContent = 'Load';
            button.onclick = () => loadAlbum(album.id);
            row.append(image, text, button);
            results.append(row);
          }
        }

        async function loadAlbum(id) {
          const response = await fetch('/spotify/load-album', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id })
          });
          const data = await response.json();
          if (!response.ok) {
            alert(data.error || 'Could not load album.');
            return;
          }
          document.getElementById('sideJson').value = JSON.stringify(data.side, null, 2);
          await tick();
        }

        async function tick() {
          const response = await fetch('/status');
          const status = await response.json();
          const side = status.side || { name: '--', tracks: [] };
          document.getElementById('connected').textContent = status.audioConnected ? 'connected' : 'waiting';
          document.getElementById('device').textContent = status.lastDeviceName;
          document.getElementById('sampleRate').textContent = status.sampleRate || '--';
          document.getElementById('frames').textContent = status.frameCount;
          document.getElementById('rmsValue').textContent = Number(status.rms || 0).toFixed(5);
          document.getElementById('rms').style.width = Math.min(100, status.rms * 4500) + '%';
          document.getElementById('mode').textContent = status.mode;
          document.getElementById('event').textContent = status.event;
          document.getElementById('active').textContent = status.audioActive ? 'yes' : 'no';
          document.getElementById('silence').textContent = Number(status.silenceSeconds || 0).toFixed(1) + 's';
          document.getElementById('sideElapsed').textContent = fmt(status.sideElapsedSeconds);
          document.getElementById('needleDrop').textContent = status.needleDropAt || '--';
          document.getElementById('sideName').textContent = side.name || '--';
          document.getElementById('track').textContent = `${Number(status.currentTrackIndex || 0) + 1}. ${status.currentTrackTitle}`;
          document.getElementById('trackElapsed').textContent = fmt(status.currentTrackElapsedSeconds);
          document.getElementById('trackRemaining').textContent = fmt(status.currentTrackRemainingSeconds);
          document.getElementById('nextTrack').textContent = status.nextTrackTitle || '--';
          document.getElementById('progress').style.width = Math.min(100, (status.sideElapsedSeconds / Math.max(1, sideDuration(side))) * 100) + '%';
          const spotify = status.spotify || {};
          document.getElementById('spotifyAuth').textContent = spotify.configured ? (spotify.authenticated ? 'connected' : 'not connected') : 'missing config';
          document.getElementById('spotifyUser').textContent = spotify.user || '--';
          document.getElementById('spotifyTarget').textContent = spotify.targetDevice || '--';
          document.getElementById('spotifyRedirect').textContent = spotify.redirectUri || '--';
          document.getElementById('spotifyAction').textContent = spotify.lastAction || '--';
          document.getElementById('spotifyError').textContent = spotify.error || '--';

          const sideBox = document.getElementById('sideJson');
          if (!sideBox.value && side.tracks && side.tracks.length) {
            sideBox.value = JSON.stringify(side, null, 2);
          }
        }

        loadTemplate();
        tick();
        setInterval(tick, 1000);
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
