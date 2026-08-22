# Vinyl Sync Automation Plan

## Goal

Turn Vinyl Sync into a near-zero-interaction appliance:

> Put on a record. Vinyl Sync recognizes the recording, mirrors the correct track and position to a configured Spotify device, and shows the exact owned Discogs pressing when it can identify it.

The album/side timing workflow becomes legacy code. ShazamKit drives playback; Discogs enriches the display but never gates recognition or Spotify sync.

## Baseline

This plan starts after merged PR #1 at `7ae956c`, which provides:

- the native Xcode project;
- App Store and Direct build configurations;
- ShazamKit-enabled recognition;
- sandboxed App Store packaging and a non-sandboxed Developer ID build;
- Keychain-backed Spotify and Discogs secrets;
- Application Support persistence;
- inbound MOTU PCM streaming over WebSocket;
- Spotify control and Discogs collection access.

The signed Direct build has been verified on two Macs. After resetting the local Shazam daemon with a reboot, the live MOTU stream recognized C418 tracks and followed a real track transition.

## Product principles

1. Playback must not require choosing an album, disc, side, or track.
2. A false positive is worse than a slightly delayed transition.
3. Shazam offsets are evidence, not absolute truth.
4. Transient Shazam errors must not replace a healthy confirmed state.
5. Discogs is passive pressing context and must never block Spotify sync.
6. The normal UI should be calm; raw stream and recognition details belong in Diagnostics.
7. A manual escape hatch should exist without becoming part of the usual flow.
8. No user, machine, IP address, audio device, Spotify device, or Discogs account may be hardcoded.
9. Each installation is single-user and local-first, but the software must be portable to anyone's Mac/Windows/audio setup.

## Target flow

```text
MOTU audio arrives
  -> Shazam candidate appears
  -> second agreeing match confirms the recording
  -> Spotify track resolves by ISRC, then title/artist fallback
  -> safe playback offset is calculated
  -> muted Spotify starts or transitions on the configured target device
  -> album identity resolves against the owned Discogs collection
  -> now-playing UI shows track, progress, and pressing details
```

## Milestone 1: Recognition state machine

Replace the current callback-by-callback UI state with explicit recognition state.

### States

- `waiting`: no active audio stream;
- `listening`: audio is arriving but no credible candidate exists;
- `candidate`: one match has been observed;
- `confirmed`: at least two agreeing matches have been observed within the confirmation window;
- `stale`: audio continues but the confirmed recording has not matched recently;
- `unavailable`: ShazamKit is unavailable or has failed continuously beyond the error threshold.

### Confirmation policy

- Identify a recording by Shazam ID, falling back to normalized artist and title.
- Require two agreeing matches within 15 seconds before confirming a new recording.
- Reset a candidate after 15 seconds or when a conflicting candidate gains stronger evidence.
- Do not demote a confirmed recording because of a single no-match or error callback.
- Preserve the last confirmed match through transient `com.apple.ShazamKit error 202` callbacks.
- Mark recognition unavailable only when there has been no successful match for 30 seconds and errors continue.

### Callback and logging policy

- Count successful matches, no-matches, and errors separately.
- Keep the latest error timestamp and message without replacing the confirmed track.
- Log state transitions and meaningful errors, not every repeated callback.
- Keep raw counters and the latest callback in `/status` for Diagnostics.

### Acceptance criteria

- A one-off false match does not trigger Spotify.
- Two consecutive correct matches confirm within roughly 5–15 seconds.
- Intermittent error 202 callbacks do not flash an error or clear now-playing.
- Repeated matches for one track do not trigger repeated Spotify play calls.

## Milestone 2: Safe offset tracking

Build a local playback clock around Shazam rather than seeking to every reported offset.

### Initial anchor

- On confirmation, collect the agreeing matches and use the most recent credible predicted offset.
- Record the local monotonic stream time at the anchor.
- Derive the expected current offset from the anchor plus elapsed local time.

### Sanity checks

- Reject negative offsets after allowing for a small lead-in tolerance.
- Reject a new offset that moves substantially backward while the same track is playing.
- Reject a forward correction that exceeds the locally predicted position by more than 10 seconds.
- Treat highly divergent offsets from repeating or ambient passages as ambiguous.
- Use later agreeing observations to refine drift gradually instead of issuing a hard seek.

### Spotify correction policy

- Start Spotify once when a track is confirmed.
- Do not replay or seek for duplicate callbacks.
- Correct drift only when the estimate is stable and exceeds a configurable threshold, initially 3 seconds.
- Rate-limit corrective seeks, initially to one per 30 seconds.
- On a confirmed new track, reset the anchor and transition immediately.

### Acceptance criteria

- Spotify never jumps backward due to a stale callback.
- Ambiguous Shazam offsets do not cause large forward seeks.
- Track position remains acceptably close over a complete side.

## Milestone 3: Automatic Spotify control

### Configuration

- Store the Spotify client ID, secret, redirect URI, refresh token, and chosen target device in the signed app's Application Support and Keychain storage.
- Discover the user's available Spotify Connect devices and require an explicit target-device choice during setup.
- Remember the chosen device by stable Spotify device ID, with its display name as presentation and fallback context.
- Expose connection and authentication state in Settings.

### Resolution

1. Resolve by ISRC.
2. Fall back to normalized title and artist search.
3. Prefer the album/recording whose duration is closest to Shazam metadata when multiple results exist.
4. Cache successful Shazam-ID-to-Spotify-URI mappings.

### Playback

- Start the resolved Spotify track at the safe offset.
- Set playback volume to zero before or immediately after starting.
- Avoid changing the user's active playback when no configured target device is available.
- Surface a recoverable action when authentication or device selection fails.

### Manual controls

- `Resync`: re-resolve the confirmed track and seek using the current safe estimate.
- `Wrong match`: discard the current candidate/confirmation and require fresh evidence.

### Acceptance criteria

- A confirmed vinyl track starts muted on the configured Spotify device without per-play user selection.
- A real track boundary triggers one Spotify transition.
- False candidates and duplicate callbacks trigger no playback changes.

## Milestone 4: Portable setup and device configuration

Provide a first-run flow that makes a new installation usable without editing source files or environment files.

### Windows audio agent

- Enumerate available WASAPI capture devices.
- Let the user choose the turntable/interface input.
- Show the current sample rate, channel mode, and live input level before saving.
- Configure the Mac coordinator using a discovered host when available, with manual hostname/IP and port fallback.
- Persist settings under the current user's application-data directory.
- Reconnect automatically after the coordinator, network, or Windows session restarts.
- Keep a tray-menu shortcut for changing input or coordinator without reinstalling.

### Mac coordinator

- Show a first-run setup screen until required configuration is complete.
- Display the Mac hostname, LAN addresses, port, and WebSocket endpoint for pairing the Windows agent.
- Allow the listening port to be changed without rebuilding.
- Configure Spotify OAuth and target-device selection in-app.
- Configure Discogs username/token as an optional step.
- Store non-secret preferences in Application Support and secrets in Keychain.

### Defaults and portability

- Defaults may be convenient, but never assume `192.168.1.3`, `CUTE-GAMING`, a MOTU device, or a specific Discogs username.
- Use stable device identifiers internally; handle renamed or temporarily missing devices gracefully.
- Keep all machine-specific files and credentials out of Git and release artifacts.
- Document firewall/LAN requirements and provide a visible connection test from both apps.

### Acceptance criteria

- A new user can configure both apps without opening a terminal or editing a file.
- Changing the Windows input device or Spotify target requires only Settings/tray interaction.
- Restarting either machine reconnects the stream without manual intervention.
- Missing devices produce actionable setup state rather than silent failure.

## Milestone 5: Passive Discogs pressing enrichment

Discogs must describe the physical record without participating in playback decisions.

### Resolution

- Infer album identity from the resolved Spotify track and its album metadata.
- Search only the currently configured user's owned Discogs collection.
- Rank candidates using normalized artist, album title, track title, and track position/duration where available.
- Prefer an exact release already associated with the recognized album in the local cache.
- Cache album-to-release choices in Application Support.

### Ambiguity

- If exactly one owned release is a confident match, select it automatically.
- If multiple owned pressings remain plausible, show a small chooser once.
- Remember the choice for later plays.
- If no confident release exists, show album metadata without claiming a pressing.

### Display fields

- release cover;
- release year and country;
- label and catalogue number;
- format, edition, and colour text;
- Discogs release link.

### Acceptance criteria

- Recognition and Spotify sync work when Discogs is unavailable.
- The UI never displays an uncertain release as an exact pressing.
- A remembered pressing loads automatically on later plays.

## Milestone 6: UI simplification

### Remove from the main workflow

- album, disc, and side picker;
- side-plan editor and track rail;
- arm and needle-drop controls;
- manual playback delay;
- transition-silence and timing controls;
- side elapsed-time machinery;
- manual album search as a prerequisite.

Remove the corresponding backend state and endpoints after the automated path passes live tests; do not leave dead timing code behind indefinitely.

### Main screen

- centered artwork;
- track title and artist;
- locally smoothed progress and duration;
- compact pressing description;
- audio-input, Shazam, and Spotify health indicators;
- `Resync` and `Wrong match` actions.

### Settings

- Spotify credentials, OAuth state, and target device;
- Discogs username and token;
- Windows audio input and coordinator pairing status;
- coordinator hostname/port and connection guidance;
- recognition enabled toggle;
- minimal advanced thresholds only if they prove useful in real testing.

### Diagnostics

Keep collapsed by default:

- sample rate, RMS, frame count, and stream duration;
- recognition state and candidate evidence;
- raw Shazam offset and locally predicted offset;
- success/no-match/error counters;
- last transient error;
- Spotify resolution and playback actions.

### Acceptance criteria

- The default page communicates what is playing and whether the system is healthy at a glance.
- Normal playback requires no interaction.
- Troubleshooting data remains available without polluting the primary UI.

## Milestone 7: Validation and release

### Live scenarios

- recognizable track from the beginning;
- quiet or ambiguous intro;
- isolated false positive;
- ordinary track transition;
- repeating ambient passage with ambiguous offsets;
- lifting and re-dropping the needle;
- manually skipping forward or backward;
- changing record sides;
- Windows agent disconnect and reconnect;
- changing the Windows capture device;
- pairing from a fresh Windows/Mac installation;
- coordinator hostname/IP change;
- Spotify device unavailable and later returning;
- Discogs unavailable or ambiguous;
- a complete album side without manual intervention.

### Regression checks

- Swift package build;
- Xcode Debug, App Store, and Direct configurations;
- app bundle and plist validation;
- code-signature and entitlement inspection;
- dashboard JavaScript parsing;
- `/status`, OAuth callback, WebSocket, and settings endpoints;
- no secrets, certificates, profiles, or tokens in Git.

### Release

- Produce incremental Conventional Commits for recognition, automation/enrichment, and UI cleanup.
- Have the Apple Developer team produce a signed Direct build for personal use.
- Produce a TestFlight build as a secondary distribution/compatibility path.
- Run a final live side test on the signed artifact before tagging the release.

## Proposed implementation commits

1. `feat: harden Shazam recognition and offset tracking`
2. `feat: add portable device setup and coordinator pairing`
3. `feat: automate Spotify sync and Discogs pressing resolution`
4. `refactor: simplify coordinator around automatic recognition`
5. Follow-up fixes from live validation as focused Conventional Commits.

## Out of scope for this iteration

- public App Store launch;
- multi-tenant/server-hosted accounts (each installation remains a configurable single-user system);
- identifying an exact pressing from audio alone when multiple owned releases share the same master;
- replacing Spotify with another playback provider;
- cloud-hosted recognition or server-side audio storage;
- preserving the manual album/side workflow as a second full operating mode.

## Definition of done

Vinyl Sync is done for this iteration when a new user can configure their Windows audio input, Mac coordinator, Spotify target device, and optional Discogs account without editing code; then play any recognizable owned record without selecting an album or side; have Spotify silently follow confirmed track changes at a sane position; see trustworthy now-playing state and an exact Discogs pressing only when confidently resolved; and recover from transient Shazam or network failures without intervention.
