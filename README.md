# Vinyl Sync

Vinyl Sync recognizes a record playing through a Windows audio input and silently mirrors the same track and position to Spotify. A Mac coordinator runs ShazamKit recognition and can optionally show a matching owned pressing from the listener's Discogs collection.

```text
turntable / interface
  -> Windows WASAPI tray agent
  -> float32 mono PCM over a LAN WebSocket
  -> signed macOS ShazamKit coordinator
  -> confirmed track + safe local offset clock
  -> muted Spotify Connect playback
  -> optional owned-pressing context from Discogs
```

No album, side, or track selection is required during playback. New tracks require two agreeing Shazam matches; silence is not submitted to ShazamKit; duplicate callbacks and implausible offset jumps do not replay or seek Spotify.

## Requirements

- a Windows 10/11 x64 PC with a working audio capture input connected to the turntable or audio interface
- an Apple Silicon Mac running macOS 14 or newer (the shell build targets ARM64)
- full Xcode with its command-line tools selected for the signed Mac build
- Spotify Premium and a Spotify developer application
- paid Apple Developer team with ShazamKit enabled for the macOS App ID
- optional Discogs account and personal access token
- both computers reachable on the same LAN

## First-time setup

All terminal commands below start from the repository root unless stated otherwise. Use your own identifiers and account credentials; the examples are placeholders.

### 1. Build and start the Mac coordinator

For recognition against Shazam's public catalogue, build with your Apple Developer team and an explicit App ID with the **ShazamKit App Service** enabled. A successful code signature alone does not establish recognition access.

1. Open `mac-coordinator/VinylSyncCoordinator.xcodeproj` in Xcode and sign in to your Apple Developer account.
2. Choose a unique reverse-domain bundle identifier, such as `com.example.vinylsync`. Register that identifier under your team in the Apple Developer portal and enable **App Services → ShazamKit**.
3. Set the target's signing team and bundle identifier to your own values. The checked-in project has maintainer defaults; override both when building independently.
4. Build the `VinylSyncCoordinator` scheme using the `Direct` configuration. This is the non-sandboxed local-use configuration.

Alternatively, run this command after replacing both placeholder values:

```bash
xcodebuild -project mac-coordinator/VinylSyncCoordinator.xcodeproj \
  -scheme VinylSyncCoordinator -configuration Direct \
  -derivedDataPath mac-coordinator/.build/local \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.vinylsync \
  -allowProvisioningUpdates build

open "mac-coordinator/.build/local/Build/Products/Direct/Vinyl Sync Coordinator.app"
```

An Apple Development signature is intended for development, not a notarized public download. The project also provides `Debug` and sandboxed `Release` configurations; distributing builds to other people requires the appropriate signing and distribution setup. Changing the signing team may prompt for Keychain access or require Spotify sign-in again.

### 2. Connect Spotify and optional Discogs

Register `http://127.0.0.1:4739/callback` as a redirect URI in your Spotify developer application. It must exactly match the coordinator setting. Complete authorization in a browser on the **coordinator Mac**; the loopback address refers to the computer running that browser.

Open `http://127.0.0.1:4739` on the Mac, then use **Settings** to configure:

- Spotify client ID and secret
- redirect URI, normally `http://127.0.0.1:4739/callback`
- Spotify Connect target device
- optional Discogs username and token

Secrets are stored in Keychain. Non-secret settings, Spotify tokens, and remembered pressing choices are stored under `~/Library/Application Support/VinylSyncCoordinator/`.

Save the settings, complete Spotify sign-in, then open Spotify on the intended playback computer and select it as the target device. The app intentionally mutes that device so you hear the record while Spotify follows its position. Discogs setup is optional and uses your own collection.

If you change the coordinator port, update its redirect URI and the Spotify developer application to match. Plain HTTP LAN addresses are not suitable OAuth callbacks.

### 3. Connect the Windows tray agent

Download and extract the `vinyl-sync-windows-agent` artifact from a successful **Windows Agent** GitHub Actions run, or build it using the command below. This repository retains CI artifacts for seven days and downloading them may require sign-in. The published x64 artifact includes the .NET runtime. Run `VinylSync.Agent.exe`, then right-click its system-tray icon to configure:

- **Select Input Device**: choose the WASAPI capture input carrying the record
- **Coordinator**: enter the Mac hostname or LAN address and port
- **Reconnect**: reconnect after changing either setting

Configuration is stored at `%APPDATA%\VinylSync\config.json`. The agent reconnects automatically after transient coordinator or network failures.

The coordinator URL is `http://<mac-host>:4739`; its audio WebSocket is `ws://<mac-host>:4739/audio`. Allow inbound TCP port `4739` through the Mac firewall. No address, Windows input, Spotify device, or Discogs user is hardcoded.

### 4. Verify the complete path

Play a record and check the coordinator page in this order:

1. **Audio:** connected, with a moving input level. If disconnected, check the selected Windows input, Mac address, port, and firewall.
2. **Shazam:** a confirmed track after enough recognizable audio. If recognition is unavailable, check the signed build and the App ID's ShazamKit service.
3. **Spotify:** the selected device is playing the recognized track. Inspect Diagnostics if it only reports a request or an error.
4. **Discogs (optional):** a matching owned release, or a pressing chooser. Missing pressing metadata does not mean audio recognition failed.

Then test a track transition. Automatic reconnection and a successful build do not replace testing your actual audio hardware.

## Normal use

1. Start the signed Mac coordinator and Windows tray agent.
2. Make sure the chosen Spotify target is online.
3. Play a record.

The main page shows audio, Shazam, and Spotify health; recognized artwork and track progress; and pressing details when Discogs can resolve them confidently. If multiple owned pressings match, choose once and Vinyl Sync remembers the release for that artist and album.

Recovery controls are intentionally small:

- **Resync** resolves and seeks the current confirmed track again.
- **Wrong match** discards the current confirmation and waits for fresh evidence.
- **Diagnostics** exposes stream, recognition, offset, and error counters.

## Resolution, timing, and limits

- Spotify searches by ISRC first. An empty result falls back to normalized exact track title and artist. Among the returned recording candidates, the resolver prefers the previously confirmed owned album, then an album in the Discogs collection, then the first playable candidate. It currently examines up to five search results, not the entire catalogue.
- Spotify playback uses an **album context** with the recognized track and position. The remaining album may play beyond a physical side; there is no side-only queue, playlist creation, or automatic pause when the needle lifts.
- Discogs is optional. Owned-pressing matching compares album/artist metadata and remembers a choice when multiple owned releases match. It does not identify a physical pressing from audio or prove which of several copies is on the turntable. A missing pressing does not prevent playback. A collection refresh can add startup latency.
- Positions advance using monotonic time, including time spent preparing Spotify requests. The current build adds a fixed 1-second playback lead. Smoothed cumulative drift of at least 1 second can trigger correction, at most once per 30 seconds. These values are source constants, not Settings controls.
- The Spotify status distinguishes a request being accepted from playback confirmed by a subsequent device/track check. That one-time check is not continuous playback monitoring. Its timing estimate is diagnostic, not a guarantee of sub-second lyric or speaker alignment.
- Ten seconds without audio buffers clears the stream state. A completed track plus at least five seconds of silence clears recognition metadata. Neither operation pauses Spotify.

If recognition works but Spotify does not, open **Diagnostics** and check its last action/error, ensure the selected Spotify device is available, then use **Resync**. A single or compilation can still be chosen when an owned-album candidate is absent. Unknown or unavailable pressing metadata is separate from Spotify playback health.

## Development and validation

From the repository root, run the regression checks:

```bash
./mac-coordinator/test.sh
```

These cover monotonic timing, gradual drift, silence expiry, and album-candidate selection without Spotify credentials or Shazam service access. macOS CI also builds the ad-hoc app; signed recognition and full vinyl playback still require live testing.

Build an ad-hoc signed macOS bundle for development (not a substitute for the team-signed recognition setup above):

```bash
./mac-coordinator/build.sh
```

Run it on a non-default port without replacing an installed build:

```bash
"mac-coordinator/.build/debug/Vinyl Sync Coordinator.app/Contents/MacOS/vinyl-sync-coordinator" 4740
```

The Windows CI workflow restores and publishes a self-contained .NET 8 `win-x64` tray artifact. To build locally, install the .NET 8 SDK and run from the repository root on Windows:

```powershell
dotnet publish windows-tray-agent/VinylSync.Agent/VinylSync.Agent.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o publish/windows-agent
```

The executable will be at `publish/windows-agent/VinylSync.Agent.exe`.

Useful coordinator endpoints:

- `GET /status`
- `GET/POST /api/config`
- `GET /spotify/login`
- `GET /spotify/devices`
- `POST /sync/resync`
- `POST /sync/wrong-match`
- `POST /discogs/select-pressing`
- `GET /audio` with a WebSocket upgrade

Before distributing a build, verify the app signature and embedded entitlements, exercise Spotify OAuth and device discovery, connect a real PCM stream, and test at least one full record side including a track transition.

## Security

The coordinator binds to all interfaces. Its HTTP settings/control endpoints and audio WebSocket have **no client authentication or transport encryption**. Run it only on a trusted LAN and do not forward port `4739` to the internet. Anyone with network access can reach these controls.

Never commit Apple certificates, `.p12` files, private keys, provisioning profiles, Spotify secrets/tokens, or Discogs tokens. Distribute built `.app` bundles as reviewed release artifacts, not in Git history.
