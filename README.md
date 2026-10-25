# mavlink2

MAVLink v2 over a byte stream, for Elixir: the frame codec, a link process
and its transports.

| Module | What |
| --- | --- |
| `MAVLink2.Frame` | v2 encode/decode for a dialect: payload truncation and zero-extension, resynchronisation after a bad frame, `drain/2` over a stream |
| `MAVLink2.CRC` | CRC-16/MCRF4XX with `crc_extra` |
| `MAVLink2.Dialect` | the behaviour a dialect implements: `crc_extra/1`, `payload_length/1` |
| `MAVLink2.Link` | owns a transport, reassembles frames, numbers what it sends, delivers `{MAVLink2.Link, link, frame}` to subscribers, counts errors and gaps |
| `MAVLink2.Transport.UART` | a serial port through `Circuits.UART` (an optional dependency) |
| `MAVLink2.Transport.Loopback` | in memory, for tests |

Signed frames are refused (`:signed_frame_unsupported`); v1 frames too.

```sh
mix test
```

The golden frames in `test/mavlink2/frame_test.exs` are pymavlink's
(`common.xml`).
