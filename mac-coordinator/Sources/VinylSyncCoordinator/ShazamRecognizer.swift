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
}

struct ShazamRecognitionStatus {
  var available = true
  var enabled = true
  var state = "waiting for audio"
  var sampleRate = 0
  var submittedFrames: UInt64 = 0
  var matches: UInt64 = 0
  var lastMatch: ShazamMatchResult?
  var error = ""
}

final class ShazamRecognizer: NSObject, SHSessionDelegate {
  private let queue = DispatchQueue(label: "dev.iamdobhal.vinyl-sync.shazam", qos: .userInitiated)
  private let lock = NSLock()
  private let onMatch: (ShazamMatchResult) -> Void

  private var session = SHSession()
  private var audioFormat: AVAudioFormat?
  private var sampleTime: AVAudioFramePosition = 0
  private var statusValue = ShazamRecognitionStatus()

  init(onMatch: @escaping (ShazamMatchResult) -> Void) {
    self.onMatch = onMatch
    super.init()
    session.delegate = self
  }

  func configure(sampleRate: Int) {
    queue.async {
      guard [16_000, 32_000, 44_100, 48_000].contains(sampleRate) else {
        self.updateStatus {
          $0.sampleRate = sampleRate
          $0.state = "unsupported audio format"
          $0.error = "ShazamKit requires mono PCM at 16, 32, 44.1, or 48 kHz."
        }
        self.audioFormat = nil
        return
      }

      guard self.audioFormat?.sampleRate != Double(sampleRate) else { return }
      self.session = SHSession()
      self.session.delegate = self
      self.audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
      )
      self.sampleTime = 0
      self.updateStatus {
        $0.sampleRate = sampleRate
        $0.state = "listening"
        $0.error = ""
      }
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
        $0.state = "listening"
      }
    }
  }

  func disconnect() {
    queue.async {
      self.audioFormat = nil
      self.sampleTime = 0
      self.session = SHSession()
      self.session.delegate = self
      self.updateStatus { $0.state = "waiting for audio" }
    }
  }

  func status() -> ShazamRecognitionStatus {
    lock.lock()
    defer { lock.unlock() }
    return statusValue
  }

  func session(_ session: SHSession, didFind match: SHMatch) {
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

    updateStatus {
      $0.matches += 1
      $0.lastMatch = result
      $0.state = "matched"
      $0.error = ""
    }
    onMatch(result)
  }

  func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    guard let error else {
      updateStatus { $0.state = "listening" }
      return
    }
    updateStatus {
      $0.state = "recognition error"
      $0.error = error.localizedDescription
    }
  }

  private func updateStatus(_ mutate: (inout ShazamRecognitionStatus) -> Void) {
    lock.lock()
    mutate(&statusValue)
    lock.unlock()
  }
}
