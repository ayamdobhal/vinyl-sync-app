import Foundation

enum ShazamPlaybackAction {
  case none
  case start(positionSeconds: Double)
  case correct(positionSeconds: Double)
}

struct PlaybackOffsetStatus {
  var trackIdentity = ""
  var estimatedOffsetSeconds: Double = 0
  var observedOffsetSeconds: Double = 0
  var driftSeconds: Double = 0
  var acceptedObservations: UInt64 = 0
  var rejectedObservations: UInt64 = 0
  var lastCorrectionAt: Date?
}

final class PlaybackOffsetTracker {
  private let backwardTolerance: Double = 5
  private let forwardTolerance: Double = 10
  private let correctionThreshold: Double = 3
  private let correctionInterval: TimeInterval = 30
  private let smoothingFactor: Double = 0.2
  private let lock = NSLock()

  private var statusValue = PlaybackOffsetStatus()
  private var anchorOffsetSeconds: Double = 0
  private var anchorDate = Date.distantPast

  func observe(_ match: ShazamMatchResult, isNewTrack: Bool) -> ShazamPlaybackAction {
    lock.lock()
    defer { lock.unlock() }

    let observed = max(0, match.predictedOffsetSeconds)
    let identity = match.identity
    if isNewTrack || identity != statusValue.trackIdentity {
      statusValue = PlaybackOffsetStatus(
        trackIdentity: identity,
        estimatedOffsetSeconds: observed,
        observedOffsetSeconds: observed,
        driftSeconds: 0,
        acceptedObservations: 1,
        rejectedObservations: 0,
        lastCorrectionAt: match.matchedAt
      )
      anchorOffsetSeconds = observed
      anchorDate = match.matchedAt
      return .start(positionSeconds: observed)
    }

    let expected = max(0, anchorOffsetSeconds + match.matchedAt.timeIntervalSince(anchorDate))
    let drift = observed - expected
    statusValue.observedOffsetSeconds = observed
    statusValue.estimatedOffsetSeconds = expected
    statusValue.driftSeconds = drift

    guard drift >= -backwardTolerance, drift <= forwardTolerance else {
      statusValue.rejectedObservations += 1
      return .none
    }

    statusValue.acceptedObservations += 1
    let smoothed = max(0, expected + drift * smoothingFactor)
    anchorOffsetSeconds = smoothed
    anchorDate = match.matchedAt
    statusValue.estimatedOffsetSeconds = smoothed

    let mayCorrect = abs(drift) >= correctionThreshold
      && statusValue.lastCorrectionAt.map {
        match.matchedAt.timeIntervalSince($0) >= correctionInterval
      } ?? true
    guard mayCorrect else { return .none }
    statusValue.lastCorrectionAt = match.matchedAt
    return .correct(positionSeconds: smoothed)
  }

  func status() -> PlaybackOffsetStatus {
    lock.lock()
    defer { lock.unlock() }
    var snapshot = statusValue
    if !snapshot.trackIdentity.isEmpty {
      snapshot.estimatedOffsetSeconds = max(0, anchorOffsetSeconds + Date().timeIntervalSince(anchorDate))
    }
    return snapshot
  }

  func reset() {
    lock.lock()
    statusValue = PlaybackOffsetStatus()
    anchorOffsetSeconds = 0
    anchorDate = .distantPast
    lock.unlock()
  }
}
