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

- Windows 10/11 machine connected to the turntable or audio interface
- macOS 14 or newer on the coordinator Mac
- Spotify Premium and a Spotify developer application
- paid Apple Developer team with ShazamKit enabled for the macOS App ID
- optional Discogs account and personal access token
- both computers reachable on the same LAN

## First-time setup

### 1. Mac coordinator

From the repository root, build an **ad-hoc signed development bundle** (this alone does not establish public-catalog ShazamKit access):

```bash
cd mac-coordinator
./build.sh
```

Public-catalog Shazam recognition requires a signed build whose explicit App ID has the ShazamKit App Service enabled. The Xcode project contains `Debug`, `Release` (App Store/TestFlight), and `Direct` configurations. Select the Apple Developer team and use the Bundle ID registered for ShazamKit; this repository currently uses `dev.iamdobhal.vinylsync`.

For a development-signed command-line build:

```bash
./sign.sh "Apple Development: Developer Name (TEAMID)" /path/to/profile.provisionprofile
open ".build/debug/Vinyl Sync Coordinator.app"
```

For the current owner-signed Mac build (version 0.3.0, build 12), run **from the repository root**:

```sh
xcodebuild -project mac-coordinator/VinylSyncCoordinator.xcodeproj \
  -scheme VinylSyncCoordinator -configuration Direct \
  -derivedDataPath mac-coordinator/.build/owner-signed \
  DEVELOPMENT_TEAM=4FFCQ5BLJT -allowProvisioningUpdates build
```

The built app is at `mac-coordinator/.build/owner-signed/Build/Products/Direct/Vinyl Sync Coordinator.app`.

Register the explicit App ID `dev.iamdobhal.vinylsync` under Ayam's team (`4FFCQ5BLJT`) and enable **App Services → ShazamKit** in the Apple Developer portal. The previous Sumit-signed identifier is separate; signing successfully does not enable this service automatically. Direct is the non-sandboxed local testing configuration and retains the existing Application Support data location. A team change may require approving Keychain access or signing in to Spotify again.

Do not add the iOS-only `com.apple.developer.shazamkit` entitlement manually. ShazamKit access on macOS is enabled on the App ID. The App Store target uses its sandbox/network entitlements; the Direct target is available for local testing and diagnostics. An Apple Development signature is not a notarized public-distribution build; broader distribution needs appropriate signing and notarization.

Open `http://127.0.0.1:4739` on the Mac, then use **Settings** to configure:

- Spotify client ID and secret
- redirect URI, normally `http://127.0.0.1:4739/callback`
- Spotify Connect target device
- optional Discogs username and token

Secrets are stored in Keychain. Non-secret settings, Spotify tokens, and remembered pressing choices are stored under `~/Library/Application Support/VinylSyncCoordinator/`.

The Spotify redirect URI must exactly match one registered in the Spotify developer dashboard. Complete OAuth from the Mac through the loopback URL; plain HTTP LAN callback addresses are not accepted by Spotify.

### 2. Windows tray agent

Windows artifacts are built by GitHub Actions. Run the agent and use its tray menu to configure:

- **Select Input Device**: choose the WASAPI capture input carrying the record
- **Coordinator**: enter the Mac hostname or LAN address and port
- **Reconnect**: reconnect after changing either setting

Configuration is stored at `%APPDATA%\VinylSync\config.json`. The agent reconnects automatically after transient coordinator or network failures.

The coordinator URL is `http://<mac-host>:4739`; its audio WebSocket is `ws://<mac-host>:4739/audio`. Allow inbound TCP port `4739` through the Mac firewall. No address, Windows input, Spotify device, or Discogs user is hardcoded.

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

Build the macOS app:

```bash
cd mac-coordinator
./build.sh
```

Run it on a non-default port without replacing an installed build:

```bash
".build/debug/Vinyl Sync Coordinator.app/Contents/MacOS/vinyl-sync-coordinator" 4740
```

The Windows CI workflow restores and publishes a self-contained .NET 8 `win-x64` tray artifact. Local Windows build:

```powershell
dotnet publish windows-tray-agent/VinylSync.Agent/VinylSync.Agent.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

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


Never commit Apple certificates, `.p12` files, private keys, provisioning profiles, Spotify secrets/tokens, or Discogs tokens. Signed `.app` bundles belong in private release artifacts, not Git history.
