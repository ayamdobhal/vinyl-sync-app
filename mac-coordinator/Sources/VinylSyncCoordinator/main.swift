import CryptoKit
import Foundation
import Network

struct SideTrack: Codable {
  var title: String
  var durationSeconds: Double
}

struct SidePlan: Codable {
  var name: String
  var tracks: [SideTrack]

  static let empty = SidePlan(name: "Untitled side", tracks: [])
  static let aThousandSunsSideA = SidePlan(
    name: "A Thousand Suns - Side A",
    tracks: [
      SideTrack(title: "The Requiem", durationSeconds: 121),
      SideTrack(title: "The Radiance", durationSeconds: 57),
      SideTrack(title: "Burning in the Skies", durationSeconds: 253),
      SideTrack(title: "Empty Spaces", durationSeconds: 18),
      SideTrack(title: "When They Come for Me", durationSeconds: 293),
      SideTrack(title: "Robot Boy", durationSeconds: 269)
    ]
  )
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

  func nextTrack() {
    lock.lock()
    guard !snapshot.sidePlan.tracks.isEmpty else {
      snapshot.event = "no side loaded"
      lock.unlock()
      return
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
    lock.unlock()
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

  func receiveAudio(sampleCount: Int, rms: Float) {
    lock.lock()
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
      }
    case "running":
      snapshot.sideElapsedSeconds += delta

      let wasActive = snapshot.audioActive
      snapshot.audioActive = activeNow || (snapshot.silenceSeconds < transitionSilenceSeconds)

      updateTrackFromTimelineLocked()

      if wasActive,
         snapshot.silenceSeconds >= transitionSilenceSeconds,
         shouldSnapToNextTrackLocked() {
        snapToNextTrackLocked(event: "silence gap")
      }
    default:
      snapshot.audioActive = activeNow
    }

    lock.unlock()
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
}

final class CoordinatorServer {
  private let port: NWEndpoint.Port
  private let listener: NWListener
  private let state = StateStore()

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
      state.nextTrack()
      respondJSON(connection: connection, status: 200, body: ["ok": true])
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
    state.receiveAudio(sampleCount: sampleCount, rms: rms)
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
      "event": snapshot.event
    ]
  }

  private func sidePayload(_ side: SidePlan) -> [String: Any] {
    [
      "name": side.name,
      "tracks": side.tracks.map {
        ["title": $0.title, "durationSeconds": $0.durationSeconds] as [String: Any]
      }
    ]
  }

  private func respondHTML(connection: NWConnection, body: String) {
    respond(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
  }

  private func respondJSON(connection: NWConnection, status: Int, body: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: body)
    respond(connection: connection, status: status, contentType: "application/json", body: data)
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
    path = String(requestParts[1])
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
        textarea { width: 100%; min-height: 220px; resize: vertical; border: 1px solid #d8cdc0; border-radius: 6px; padding: 10px; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: #fff; color: #1f2328; }
        .timeline { margin-top: 12px; height: 16px; border-radius: 999px; overflow: hidden; background: #e3d7ca; }
        .progress { height: 100%; width: 0%; background: #8d3f2f; transition: width 160ms linear; }
        .hint { color: #6b6258; font-size: 13px; margin-top: 8px; }
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
              <button class="secondary" onclick="post('/sync/reset')">Reset</button>
            </div>
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
            { title: 'The Requiem', durationSeconds: 121 },
            { title: 'The Radiance', durationSeconds: 57 },
            { title: 'Burning in the Skies', durationSeconds: 253 },
            { title: 'Empty Spaces', durationSeconds: 18 },
            { title: 'When They Come for Me', durationSeconds: 293 },
            { title: 'Robot Boy', durationSeconds: 269 }
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
          await fetch(path, { method: 'POST' });
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
