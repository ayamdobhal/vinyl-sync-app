# Audio Stream Protocol

The Windows agent connects to:

```text
ws://192.168.1.3:4739/audio
```

The first WebSocket message is UTF-8 JSON:

```json
{
  "type": "hello",
  "sampleRate": 48000,
  "channels": 1,
  "format": "f32le",
  "frameMs": 100,
  "deviceName": "MOTU M Series"
}
```

Subsequent binary messages are little-endian `float32` mono PCM frames.

The Mac coordinator treats frames as a continuous stream and maintains a monotonic stream clock for album/side sync. The side timer starts when RMS crosses the activity threshold while the coordinator is armed.

The same frames are passed to a ShazamKit streaming session using the sample rate from the hello message. ShazamKit supports the protocol's mono float32 PCM at 16, 32, 44.1, or 48 kHz. A new hello with a different sample rate resets the recognition session and stream clock.

On a public-catalog match, the coordinator uses the Shazam ISRC to find the Spotify recording, falling back to title and artist. Spotify playback starts at ShazamKit's predicted current match offset. Duplicate callbacks for the same recording are suppressed for 30 seconds.
