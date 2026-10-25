# mavlink2

MAVLink v2 over a byte stream, for Elixir: the frame codec, a link process
and its transports.

| Module | What |
| --- | --- |
| `MAVLink2.Frame` | v2 encode/decode for a dialect: payload truncation and zero-extension, resynchronisation after a bad frame, `drain/2` over a stream |
| `MAVLink2.CRC` | CRC-16/MCRF4XX with `crc_extra` |
| `MAVLink2.Dialect` | the behaviour a dialect implements: `crc_extra/1`, `payload_length/1` |
| `MAVLink2.Signing` | v2 signing: sign, verify, per-stream replay protection, timestamps that never repeat |
| `MAVLink2.Link` | owns a transport, reassembles frames, numbers what it sends, delivers `{MAVLink2.Link, link, frame}` to subscribers, counts errors and gaps; with `:signing`, signs everything it sends and delivers only frames that verify |
| `MAVLink2.Transport.UART` | a serial port through `Circuits.UART` (an optional dependency) |
| `MAVLink2.Transport.Loopback` | in memory, for tests |

v1 frames are refused.

A signature is checked before a stream's timestamp moves, so a forged frame
changes nothing; pymavlink records the timestamp first.

```sh
mix test
```

The golden frames in `test/mavlink2/frame_test.exs` and
`test/mavlink2/signing_test.exs` are pymavlink's (`common.xml`).
