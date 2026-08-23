# Audio stream protocol

The Windows agent connects to the coordinator endpoint configured in its tray settings:

```text
ws://<coordinator-host>:<port>/audio
```

The default port is `4739`; the host has no baked-in default.

The first WebSocket message is UTF-8 JSON:

```json
{
  "type": "hello",
  "sampleRate": 48000,
  "channels": 1,
  "format": "f32le",
  "frameMs": 100,
  "deviceName": "Selected WASAPI input"
}
```

Subsequent binary messages contain little-endian, non-interleaved `float32` mono PCM. The agent normally sends one 100 ms buffer per message.

The coordinator calculates RMS for every buffer. Buffers below the silence threshold remain visible in diagnostics but are not submitted to ShazamKit. Supported recognition sample rates are 16, 32, 44.1, and 48 kHz. A new hello or changed sample rate resets the recognition and local offset sessions.

A new recording requires two agreeing Shazam matches before it can affect Spotify. The coordinator resolves the track by ISRC, falling back to normalized title and artist, then anchors Shazam's predicted position to a local monotonic clock. Later observations refine drift gradually; duplicate callbacks and implausible backward or forward jumps do not issue playback commands.

The WebSocket is intended for a trusted LAN. It currently has no transport encryption or client authentication; do not expose port `4739` directly to the public internet.
