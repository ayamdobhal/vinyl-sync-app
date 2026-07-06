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

The Mac coordinator treats frames as a continuous stream and maintains a monotonic stream clock when passing buffers into ShazamKit.
