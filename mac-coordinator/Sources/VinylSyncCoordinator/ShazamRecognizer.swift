import AVFoundation
import Foundation
import ShazamKit

struct ShazamMatchResult {
  var shazamID: String
  var title: String
  var artist: String
  var isrc: String
  var artworkURL: String
  var webURL: String
  var appleMusicURL: String
  var matchOffsetSeconds: Double
  var predictedOffsetSeconds: Double
  var frequencySkew: Float
  var matchedAt: Date

  var identity: String {
    if !shazamID.isEmpty { return shazamID }
    return "\(artist)|\(title)"
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }
}

struct ShazamRecognitionStatus {
  var available = true
  var enabled = true
  var state = "waiting"
  var sampleRate = 0
  var submittedFrames: UInt64 = 0
  var matches: UInt64 = 0
  var noMatches: UInt64 = 0
  var transientErrors: UInt64 = 0
  var lastMatch: ShazamMatchResult?
  var latestObservation: ShazamMatchResult?
  var candidateTitle = ""
  var candidateArtist = ""
  var candidateMatches = 0
  var confirmedAt: Date?
  var lastSuccessfulMatchAt: Date?
  var lastError = ""
  var lastErrorAt: Date?
  var consecutiveErrorBeganAt: Date?
  var error = ""
}

final class ShazamRecognizer: NSObject, SHSessionDelegate {
  private let confirmationWindow: TimeInterval = 15
  private let staleAfter: TimeInterval = 30
  private let queue = DispatchQueue(label: "dev.iamdobhal.vinyl-sync.shazam", qos: .userInitiated)
  private let lock = NSLock()
  private let onConfirmedMatch: (ShazamMatchResult, Bool) -> Void

  private var session = SHSession()
  private var audioFormat: AVAudioFormat?
  private var sampleTime: AVAudioFramePosition = 0
  private var statusValue = ShazamRecognitionStatus()
  private var candidateIdentity = ""
  private var candidateFirstSeen = Date.distantPast
  private var confirmedIdentity = ""

  init(onConfirmedMatch: @escaping (ShazamMatchResult, Bool) -> Void) {
    self.onConfirmedMatch = onConfirmedMatch
    super.init()
    session.delegate = self
  }

  func configure(sampleRate: Int) {
    queue.async {
      guard [16_000, 32_000, 44_100, 48_000].contains(sampleRate) else {
        self.updateStatus {
          $0.sampleRate = sampleRate
          $0.state = "unavailable"
          $0.error = "ShazamKit requires mono PCM at 16, 32, 44.1, or 48 kHz."
        }
        self.audioFormat = nil
        return
      }

      guard self.audioFormat?.sampleRate != Double(sampleRate) else { return }
      self.resetSession(sampleRate: sampleRate)
    }
  }

  func receive(float32MonoPCM data: Data) {
    guard !data.isEmpty else { return }
    queue.async {
      guard let format = self.audioFormat else { return }
      let frameCount = data.count / MemoryLayout<Float>.size
      guard frameCount > 0,
            frameCount <= Int(UInt32.max),
            let buffer = AVAudioPCMBuffer(
              pcmFormat: format,
              frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let destination = buffer.floatChannelData?[0] else { return }

      buffer.frameLength = AVAudioFrameCount(frameCount)
      data.withUnsafeBytes { source in
        guard let baseAddress = source.baseAddress else { return }
        destination.update(from: baseAddress.assumingMemoryBound(to: Float.self), count: frameCount)
      }

      let time = AVAudioTime(sampleTime: self.sampleTime, atRate: format.sampleRate)
      self.sampleTime += AVAudioFramePosition(frameCount)
      self.session.matchStreamingBuffer(buffer, at: time)
      self.updateStatus {
        $0.submittedFrames += UInt64(frameCount)
        if $0.state == "waiting" { $0.state = "listening" }
      }
    }
  }

  func disconnect() {
    queue.async {
      self.session = SHSession()
      self.session.delegate = self
      self.audioFormat = nil
      self.sampleTime = 0
      self.candidateIdentity = ""
      self.candidateFirstSeen = .distantPast
      self.confirmedIdentity = ""
      self.updateStatus { $0 = ShazamRecognitionStatus() }
    }
  }

  func status() -> ShazamRecognitionStatus {
    lock.lock()
    var snapshot = statusValue
    let now = Date()
    if let errorBeganAt = snapshot.consecutiveErrorBeganAt,
       now.timeIntervalSince(errorBeganAt) >= staleAfter,
       snapshot.lastSuccessfulMatchAt.map({ now.timeIntervalSince($0) >= staleAfter }) ?? true {
      snapshot.state = "unavailable"
      snapshot.error = snapshot.lastError
    } else if snapshot.lastMatch != nil,
              let lastSuccess = snapshot.lastSuccessfulMatchAt,
              now.timeIntervalSince(lastSuccess) >= staleAfter {
      snapshot.state = "stale"
    }
    lock.unlock()
    return snapshot
  }

  func session(_ callbackSession: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first else { return }
    let result = ShazamMatchResult(
      shazamID: item.shazamID ?? "",
      title: item.title ?? "Unknown track",
      artist: item.artist ?? "Unknown artist",
      isrc: item.isrc ?? "",
      artworkURL: item.artworkURL?.absoluteString ?? "",
      webURL: item.webURL?.absoluteString ?? "",
      appleMusicURL: item.appleMusicURL?.absoluteString ?? "",
      matchOffsetSeconds: item.matchOffset,
      predictedOffsetSeconds: item.predictedCurrentMatchOffset,
      frequencySkew: item.frequencySkew,
      matchedAt: Date()
    )

    queue.async {
      guard callbackSession === self.session else { return }
      self.process(result)
    }
  }

  func session(_ callbackSession: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    queue.async {
      guard callbackSession === self.session else { return }
      let now = Date()
      self.updateStatus {
        $0.noMatches += 1
        guard let error else {
          if $0.lastMatch == nil && $0.candidateMatches == 0 { $0.state = "listening" }
          return
        }
        $0.transientErrors += 1
        $0.lastError = error.localizedDescription
        $0.lastErrorAt = now
        if $0.consecutiveErrorBeganAt == nil { $0.consecutiveErrorBeganAt = now }
      }
    }
  }

  private func resetSession(sampleRate: Int) {
    session = SHSession()
    session.delegate = self
    audioFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(sampleRate),
      channels: 1,
      interleaved: false
    )
    sampleTime = 0
    candidateIdentity = ""
    candidateFirstSeen = .distantPast
    confirmedIdentity = ""
    updateStatus {
      $0 = ShazamRecognitionStatus()
      $0.sampleRate = sampleRate
      $0.state = "listening"
    }
  }

  private func process(_ result: ShazamMatchResult) {
    let now = result.matchedAt
    let identity = result.identity
    if identity == confirmedIdentity {
      updateStatus {
        $0.matches += 1
        $0.latestObservation = result
        $0.lastMatch = result
        $0.lastSuccessfulMatchAt = now
        $0.state = "confirmed"
        $0.error = ""
        $0.consecutiveErrorBeganAt = nil
        $0.candidateMatches = 0
        $0.candidateTitle = ""
        $0.candidateArtist = ""
      }
      onConfirmedMatch(result, false)
      return
    }

    let agreesWithCandidate = identity == candidateIdentity
      && now.timeIntervalSince(candidateFirstSeen) <= confirmationWindow
    if agreesWithCandidate {
      updateStatus { $0.candidateMatches += 1 }
    } else {
      candidateIdentity = identity
      candidateFirstSeen = now
      updateStatus { $0.candidateMatches = 1 }
    }

    var shouldConfirm = false
    updateStatus {
      $0.matches += 1
      $0.latestObservation = result
      $0.lastSuccessfulMatchAt = now
      $0.candidateTitle = result.title
      $0.candidateArtist = result.artist
      $0.state = "candidate"
      $0.error = ""
      $0.consecutiveErrorBeganAt = nil
      shouldConfirm = $0.candidateMatches >= 2
    }

    guard shouldConfirm else { return }
    confirmedIdentity = identity
    candidateIdentity = ""
    candidateFirstSeen = .distantPast
    updateStatus {
      $0.lastMatch = result
      $0.confirmedAt = now
      $0.state = "confirmed"
      $0.candidateMatches = 0
      $0.candidateTitle = ""
      $0.candidateArtist = ""
    }
    onConfirmedMatch(result, true)
  }

  private func updateStatus(_ mutate: (inout ShazamRecognitionStatus) -> Void) {
    lock.lock()
    mutate(&statusValue)
    lock.unlock()
  }
}
