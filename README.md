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
  Tracks an album side from needle drop, elapsed time, and silence gaps
  Searches Spotify albums and controls playback on the Windows Spotify device named CUTE-GAMING
```

## Defaults

```text
Mac host: 192.168.1.3
Mac port: 4739
Spotify target device: CUTE-GAMING
Spotify redirect URI: http://192.168.1.3:4739/callback
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
.build/debug/vinyl-sync-coordinator 4739
```

Open from the PC:

```text
http://192.168.1.3:4739
```

Spotify credentials are read from environment variables or an ignored `.env` file:

```text
SPOTIFY_CLIENT_ID=...
SPOTIFY_CLIENT_SECRET=...
VINYL_SYNC_SPOTIFY_REDIRECT_URI=http://192.168.1.3:4739/callback
```

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
