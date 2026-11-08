import Foundation

// Only the recognition data consumed by PlaybackOffsetTracker is needed here.
struct ShazamMatchResult {
  var identity: String
  var predictedOffsetSeconds: Double
  var matchedAt: Date
  var matchedUptime: TimeInterval
}

@main
struct PlaybackTimingTests {
  static func main() {
    let anchor = PlaybackPosition(seconds: 60, observedUptime: 100)
    assert(abs(anchor.seconds(at: 102.3) - 62.3) < 0.0001,
           "Search/device/mute delay must advance the target")
    assert(abs(anchor.seconds(at: 104.8) - 64.8) < 0.0001,
           "Additional token refresh/queue delay must also count")
    assert(anchor.seconds(at: 99) == 60, "Clock anomaly must not rewind playback")

    let tracker = PlaybackOffsetTracker()
    let wall = Date(timeIntervalSince1970: 1000)
    let first = ShazamMatchResult(identity: "one", predictedOffsetSeconds: 60,
                                 matchedAt: wall, matchedUptime: 100)
    guard case .start(let start) = tracker.observe(first, isNewTrack: true) else {
      fatalError("First match must start playback")
    }
    assert(start == 60)
    // A wall-clock adjustment must not create false drift.
    let next = ShazamMatchResult(identity: "one", predictedOffsetSeconds: 70,
                                matchedAt: wall.addingTimeInterval(3610), matchedUptime: 110)
    guard case .none = tracker.observe(next, isNewTrack: false) else {
      fatalError("Wall-clock jump caused a false correction")
    }
    assert(abs(tracker.status().driftSeconds) < 0.0001)
    let drift = ShazamMatchResult(identity: "one", predictedOffsetSeconds: 96,
                                 matchedAt: wall.addingTimeInterval(-1000), matchedUptime: 131)
    guard case .correct(let corrected) = tracker.observe(drift, isNewTrack: false) else {
      fatalError("Correction interval must use elapsed monotonic time")
    }
    let correction = PlaybackPosition(seconds: corrected, observedUptime: drift.matchedUptime)
    assert(abs(correction.seconds(at: 133) - (corrected + 2)) < 0.0001)
    tracker.reset()
    assert(tracker.status().trackIdentity.isEmpty)
    guard case .start = tracker.observe(first, isNewTrack: false) else {
      fatalError("Reset must allow a fresh start")
    }
    let gradual = PlaybackOffsetTracker()
    _ = gradual.observe(first, isNewTrack: true)
    var corrections = 0
    for i in 1...60 {
      let elapsed = Double(i) * 3
      let observation = ShazamMatchResult(identity: "one",
        predictedOffsetSeconds: 60 + elapsed * 1.01,
        matchedAt: wall.addingTimeInterval(elapsed), matchedUptime: 100 + elapsed)
      if case .correct = gradual.observe(observation, isNewTrack: false) {
        corrections += 1
      }
    }
    assert(corrections > 0, "Gradual 1% drift must not disappear into the smoothed estimate")
    let steady = PlaybackOffsetTracker()
    _ = steady.observe(first, isNewTrack: true)
    for i in 1...60 {
      let elapsed = Double(i) * 3
      let observation = ShazamMatchResult(identity: "one",
        predictedOffsetSeconds: 60 + elapsed + (i % 2 == 0 ? 0.2 : -0.2),
        matchedAt: wall.addingTimeInterval(elapsed), matchedUptime: 100 + elapsed)
      guard case .none = steady.observe(observation, isNewTrack: false) else {
        fatalError("Small recognition jitter must not cause corrective playback")
      }
    }
    assert(!PlaybackExpiry.shouldClear(elapsed: 50, duration: 100, silentFor: 30))
    assert(!PlaybackExpiry.shouldClear(elapsed: 110, duration: 100, silentFor: 0))
    assert(!PlaybackExpiry.shouldClear(elapsed: 110, duration: 100, silentFor: 4.9))
    assert(PlaybackExpiry.shouldClear(elapsed: 100, duration: 100, silentFor: 5))
    assert(!PlaybackExpiry.shouldClear(elapsed: 100, duration: 0, silentFor: 30))
    print("Playback timing regression checks passed")
  }
}
