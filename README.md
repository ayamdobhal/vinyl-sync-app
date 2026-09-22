# Vinyl Sync

Vinyl Sync recognizes a record playing through a Windows audio input and silently mirrors the same track and position to Spotify. A Mac coordinator runs ShazamKit recognition and can optionally show the exact pressing from the listener's Discogs collection.

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

Build the app locally:

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

For the current owner-signed Mac build (version 0.3.0, build 6):

```sh
xcodebuild -project mac-coordinator/VinylSyncCoordinator.xcodeproj \
  -scheme VinylSyncCoordinator -configuration Direct \
  -derivedDataPath mac-coordinator/.build/owner-signed \
  DEVELOPMENT_TEAM=4FFCQ5BLJT -allowProvisioningUpdates build
```

Register the explicit App ID `dev.iamdobhal.vinylsync` under Ayam's team (`4FFCQ5BLJT`) and enable **App Services → ShazamKit** in the Apple Developer portal. The previous Sumit-signed identifier is separate; signing successfully does not enable this service automatically. Direct is the non-sandboxed local testing configuration and retains the existing Application Support data location. A team change may require approving Keychain access or signing in to Spotify again.

Do not add the iOS-only `com.apple.developer.shazamkit` entitlement manually. ShazamKit access on macOS is enabled on the App ID. The App Store target uses its sandbox/network entitlements; the Direct target is available for direct distribution and diagnostics.

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

## Development and validation

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

Never commit Apple certificates, `.p12` files, private keys, provisioning profiles, Spotify secrets/tokens, or Discogs tokens. Signed `.app` bundles belong in private release artifacts, not Git history.
