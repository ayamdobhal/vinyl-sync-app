# Vinyl Sync

Local vinyl-to-Spotify sync system.

## Architecture

```text
Windows tray agent
  Captures MOTU input via WASAPI
  Streams little-endian float32 mono PCM to the Mac over WebSocket

Mac coordinator
  Serves the control/status UI at http://192.168.1.3:4739
  Receives audio at ws://192.168.1.3:4739/audio
  Feeds incoming PCM to ShazamKit for public-catalog recognition
  Maps Shazam matches to Spotify by ISRC and starts at the recognized offset
  Tracks an album side from needle drop, elapsed time, and silence gaps
  Searches Spotify albums and controls playback on the Windows Spotify device named CUTE-GAMING
```

## Defaults

```text
Mac host: 192.168.1.3
Mac port: 4739
Spotify target device: CUTE-GAMING
Spotify redirect URI: http://127.0.0.1:4739/callback
Windows config: %APPDATA%\VinylSync\config.json
```

## Development Slices

1. Mac coordinator status page and WebSocket audio receiver.
2. Windows tray agent with input selection and PCM streaming.
3. Mac RMS/status display for incoming audio.
4. Album/side timing engine with needle-drop and silence-gap detection.
5. Spotify OAuth, album search, and playback control.
6. Sync policy and drift correction.

## Mac Coordinator

```bash
cd mac-coordinator
./build.sh
".build/debug/Vinyl Sync Coordinator.app/Contents/MacOS/vinyl-sync-coordinator" 4739
```

Open from the PC:

```text
http://192.168.1.3:4739
```

Spotify credentials are read from environment variables or an ignored `.env` file:

```text
SPOTIFY_CLIENT_ID=...
SPOTIFY_CLIENT_SECRET=...
VINYL_SYNC_SPOTIFY_REDIRECT_URI=http://127.0.0.1:4739/callback
```

Spotify rejects plain LAN HTTP callback URLs. Complete OAuth from a browser on the Mac at:

```text
http://127.0.0.1:4739
```

After that, the PC can use the coordinator UI at `http://192.168.1.3:4739`.

### ShazamKit signing

Public Shazam-catalog recognition requires a paid Apple Developer team and a provisioned macOS App ID with the ShazamKit App Service enabled. The build produces a proper app bundle but leaves it unsigned for local development.

Ask the Apple Developer team owner/admin to:

1. Register an explicit macOS App ID. The default bundle ID is `dev.iamdobhal.vinyl-sync`.
2. Enable ShazamKit for that App ID.
3. Create a macOS development provisioning profile for the App ID and Mac.
4. Install a matching Apple Development certificate in the signing Mac's keychain.

If the team uses a different App ID, build with that exact identifier:

```bash
VINYL_SYNC_BUNDLE_ID=com.example.vinylsync ./build.sh
```

Sign and verify the bundle:

```bash
./sign.sh "Apple Development: Developer Name (TEAMID)" /path/to/VinylSync.provisionprofile
```

Run the signed executable from inside the bundle:

```bash
".build/debug/Vinyl Sync Coordinator.app/Contents/MacOS/vinyl-sync-coordinator" 4739
```

Recognition health and the most recent match are exposed under `shazam` at `GET /status`. Until the app is signed for the ShazamKit-enabled App ID, audio ingestion works but public-catalog requests are expected to return a ShazamKit authorization/service error.

On macOS, ShazamKit access is associated with the App ID on Apple's service; do not manually add the iOS-style `com.apple.developer.shazamkit` entitlement. This app also intentionally does not enable App Sandbox, because sandboxing can block access to the local Shazam matching service and surface error 202.

## Windows Agent

Windows builds are produced by GitHub Actions. The app is a system tray agent with:

```text
Select Input Device
Exit
```

The agent starts streaming as soon as it launches. Selecting a different input device restarts the stream with that device. To stop streaming, exit the tray app.

The agent stores configuration at:

```text
%APPDATA%\VinylSync\config.json
```
