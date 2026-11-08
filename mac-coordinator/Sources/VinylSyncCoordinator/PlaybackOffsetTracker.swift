import Foundation

// Position at an observation instant, advanced only with a monotonic clock.
struct PlaybackPosition {
  let seconds: Double
  let observedUptime: TimeInterval

  func seconds(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
    max(0, seconds + max(0, uptime - observedUptime))
  }
}

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
  private let correctionThreshold: Double = 1
  private let correctionInterval: TimeInterval = 30
  private let smoothingFactor: Double = 0.2
  private let lock = NSLock()

  private var statusValue = PlaybackOffsetStatus()
  private var anchorOffsetSeconds: Double = 0
  private var anchorUptime: TimeInterval = 0
  // Separate commanded timeline: smoothing the estimate must not hide accumulated drift.
  private var commandedPosition: PlaybackPosition?
  private var lastCorrectionUptime: TimeInterval?

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
      anchorUptime = match.matchedUptime
      commandedPosition = PlaybackPosition(seconds: observed, observedUptime: match.matchedUptime)
      lastCorrectionUptime = match.matchedUptime
      return .start(positionSeconds: observed)
    }

    let expected = max(0, anchorOffsetSeconds + max(0, match.matchedUptime - anchorUptime))
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
    anchorUptime = match.matchedUptime
    statusValue.estimatedOffsetSeconds = smoothed

    let accumulatedDrift = smoothed - (commandedPosition?.seconds(at: match.matchedUptime) ?? expected)
    statusValue.driftSeconds = accumulatedDrift
    let mayCorrect = abs(accumulatedDrift) >= correctionThreshold
      && lastCorrectionUptime.map {
        match.matchedUptime - $0 >= correctionInterval
      } ?? true
    guard mayCorrect else { return .none }
    statusValue.lastCorrectionAt = match.matchedAt
    lastCorrectionUptime = match.matchedUptime
    commandedPosition = PlaybackPosition(seconds: smoothed, observedUptime: match.matchedUptime)
    return .correct(positionSeconds: smoothed)
  }

  func status() -> PlaybackOffsetStatus {
    lock.lock()
    defer { lock.unlock() }
    var snapshot = statusValue
    if !snapshot.trackIdentity.isEmpty {
      snapshot.estimatedOffsetSeconds = max(0, anchorOffsetSeconds + max(0, ProcessInfo.processInfo.systemUptime - anchorUptime))
    }
    return snapshot
  }

  func reset() {
    lock.lock()
    statusValue = PlaybackOffsetStatus()
    anchorOffsetSeconds = 0
    anchorUptime = 0
    lastCorrectionUptime = nil
    commandedPosition = nil
    lock.unlock()
  }
}

// Require sustained silence as well as track completion; quiet passages alone stay active.
enum PlaybackExpiry {
  static func shouldClear(elapsed: Double, duration: Double, silentFor: TimeInterval) -> Bool {
    duration > 0 && elapsed >= duration && silentFor >= 5
  }
}
