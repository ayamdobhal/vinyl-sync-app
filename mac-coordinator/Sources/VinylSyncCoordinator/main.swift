import CryptoKit
import Foundation
import Network

struct ServerState {
  var audioConnected = false
  var lastDeviceName = "none"
  var sampleRate = 0
  var frameCount: UInt64 = 0
  var rms: Float = 0
  var lastSeen = Date.distantPast
}

final class StateStore {
  private let lock = NSLock()
  private var state = ServerState()

  func update(_ body: (inout ServerState) -> Void) {
    lock.lock()
    body(&state)
    lock.unlock()
  }

  func snapshot() -> ServerState {
    lock.lock()
    let copy = state
    lock.unlock()
    return copy
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
      let snapshot = state.snapshot()
      respondJSON(connection: connection, status: 200, body: [
        "audioConnected": snapshot.audioConnected,
        "lastDeviceName": snapshot.lastDeviceName,
        "sampleRate": snapshot.sampleRate,
        "frameCount": snapshot.frameCount,
        "rms": snapshot.rms,
        "lastSeen": ISO8601DateFormatter().string(from: snapshot.lastSeen)
      ])
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
        self.state.update {
          $0.audioConnected = true
          $0.lastSeen = Date()
        }
        self.readWebSocketFrames(connection: connection, buffer: Data())
      } else {
        connection.cancel()
      }
    })
  }

  private func readWebSocketFrames(connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
      guard error == nil, let data, !data.isEmpty else {
        self.state.update { $0.audioConnected = false }
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
            self.state.update { $0.audioConnected = false }
            connection.cancel()
            return
          default:
            break
          }
        }
      } catch {
        print("websocket parse error: \(error.localizedDescription)")
        self.state.update { $0.audioConnected = false }
        connection.cancel()
        return
      }

      if isComplete {
        self.state.update { $0.audioConnected = false }
        connection.cancel()
      } else {
        self.readWebSocketFrames(connection: connection, buffer: nextBuffer)
      }
    }
  }

  private func handleHello(_ payload: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
    state.update {
      $0.lastDeviceName = json["deviceName"] as? String ?? "unknown"
      $0.sampleRate = json["sampleRate"] as? Int ?? 0
      $0.lastSeen = Date()
    }
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
    state.update {
      $0.frameCount += 1
      $0.rms = rms
      $0.lastSeen = Date()
    }
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
        body { margin: 0; padding: 28px; }
        main { max-width: 900px; margin: 0 auto; }
        h1 { margin: 0 0 18px; font-size: 32px; }
        .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
        .panel { border: 1px solid #d8cdc0; border-radius: 8px; background: #fffaf3; padding: 16px; }
        .row { display: flex; justify-content: space-between; gap: 16px; padding: 8px 0; border-bottom: 1px solid #eee2d6; }
        .row:last-child { border-bottom: 0; }
        .label { color: #6b6258; }
        .value { font-weight: 700; }
        .meter { height: 12px; border-radius: 999px; background: #e3d7ca; overflow: hidden; margin-top: 10px; }
        .bar { height: 100%; width: 0%; background: #2d6a5f; }
        @media (max-width: 720px) { .grid { grid-template-columns: 1fr; } body { padding: 16px; } }
      </style>
    </head>
    <body>
      <main>
        <h1>Vinyl Sync</h1>
        <section class="grid">
          <div class="panel">
            <div class="row"><span class="label">Audio stream</span><span class="value" id="connected">--</span></div>
            <div class="row"><span class="label">Input device</span><span class="value" id="device">--</span></div>
            <div class="row"><span class="label">Sample rate</span><span class="value" id="sampleRate">--</span></div>
            <div class="row"><span class="label">Frames</span><span class="value" id="frames">--</span></div>
            <div class="meter"><div class="bar" id="rms"></div></div>
          </div>
          <div class="panel">
            <div class="row"><span class="label">Spotify target</span><span class="value">CUTE-GAMING</span></div>
            <div class="row"><span class="label">ShazamKit</span><span class="value">pending</span></div>
            <div class="row"><span class="label">Last seen</span><span class="value" id="lastSeen">--</span></div>
          </div>
        </section>
      </main>
      <script>
        async function tick() {
          const response = await fetch('/status');
          const status = await response.json();
          document.getElementById('connected').textContent = status.audioConnected ? 'connected' : 'waiting';
          document.getElementById('device').textContent = status.lastDeviceName;
          document.getElementById('sampleRate').textContent = status.sampleRate || '--';
          document.getElementById('frames').textContent = status.frameCount;
          document.getElementById('lastSeen').textContent = status.lastSeen;
          document.getElementById('rms').style.width = Math.min(100, status.rms * 400) + '%';
        }
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
