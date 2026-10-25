# mavlink2

[MAVLink v2](https://mavlink.io/en/guide/serialization.html) for Elixir: a
frame codec, message signing, dialects generated from MAVLink XML, and a link
process over a serial port or any other byte transport.

- Frames: payload truncation and zero-extension, resynchronisation after a
  bad frame, partial frames buffered until complete.
- Dialects: `use MAVLink2.Dialect.XML` turns a MAVLink XML file and its
  includes into a struct per message, `encode/1`, `decode/2` and enum lookups.
- Signing: sign and verify, per-stream replay protection, timestamps that
  never repeat when the clock steps back.
- Link: a GenServer that owns a transport, numbers outgoing frames, delivers
  decoded frames to subscribers and counts errors, sequence gaps and rejected
  signatures.
- Checked against pymavlink: `crc_extra`, payload length, wire order and field
  types for every message in `common.xml`, packed payloads, and signed frames
  byte for byte.

MAVLink v1 frames are refused.

## Installation

```elixir
def deps do
  [
    {:mavlink2, github: "isaiahdw/mavlink2"},
    # only for MAVLink2.Transport.UART
    {:circuits_uart, "~> 1.5"}
  ]
end
```

Requires Elixir 1.17 or later.

## Usage

### A dialect

Put a MAVLink XML file and the files it includes in your project, for example
`common.xml`, `standard.xml` and `minimal.xml` from
[mavlink/mavlink](https://github.com/mavlink/mavlink/tree/master/message_definitions/v1.0):

```elixir
defmodule MyApp.MAVLink do
  use MAVLink2.Dialect.XML, file: "priv/mavlink/common.xml"
end
```

The path is relative to the project root. The module recompiles when any of
the XML files changes. Each message becomes a struct (`HEARTBEAT` is
`MyApp.MAVLink.Heartbeat`) with the XML's field names; enums and entries are
lowercase atoms.

### A link

```elixir
alias MyApp.MAVLink, as: D

{:ok, link} =
  MAVLink2.Link.start_link(
    dialect: D,
    device: "/dev/ttyUSB0",
    speed: 57_600,
    sysid: 255,
    compid: 190
  )

:ok = MAVLink2.Link.subscribe(link)

heartbeat = %D.Heartbeat{
  type: D.enum_value(:mav_type, :mav_type_gcs),
  autopilot: D.enum_value(:mav_autopilot, :mav_autopilot_invalid)
}

{msgid, payload} = D.encode(heartbeat)
:ok = MAVLink2.Link.send_message(link, msgid, payload)

receive do
  {MAVLink2.Link, ^link, %MAVLink2.Frame{msgid: id, payload: payload}} ->
    {:ok, message} = D.decode(id, payload)
end

MAVLink2.Link.stats(link)
#=> %{rx: 1, tx: 1, errors: 0, dropped: 0, unknown: 0, unsigned: 0, bad_signature: 0, replay: 0}
```

Link options:

| Option | |
| --- | --- |
| `:dialect` | the dialect module (required) |
| `:transport` | a `MAVLink2.Transport`; default `MAVLink2.Transport.UART`. Remaining options go to its `open/1` |
| `:device`, `:speed`, `:flow_control` | `MAVLink2.Transport.UART` options; `:speed` defaults to 115200 |
| `:sysid`, `:compid` | this end's ids; default 1, 1 |
| `:sendable` | message ids the peer accepts; others return `{:error, {:not_sendable, id}}` |
| `:signing` | a `MAVLink2.Signing`; see below |
| `:name` | registered name |

If the transport does not open, the link logs a warning and `start_link/1`
returns `:ignore`.

### Signing

```elixir
key = :crypto.strong_rand_bytes(32)  # shared with the peer
signing = MAVLink2.Signing.new(key, link_id: 1)

MAVLink2.Link.start_link(dialect: D, device: "/dev/ttyUSB0", signing: signing)
```

With `:signing`, every frame sent is signed and a frame received is delivered
only if it verifies. Rejected frames are counted as `:unsigned`,
`:bad_signature` or `:replay`. `accept_unsigned: [msgid]` lets the listed
message ids through unsigned.

### Without a link

`MAVLink2.Frame` encodes and decodes frames directly:

```elixir
{msgid, payload} = D.encode(heartbeat)
{:ok, bytes} = MAVLink2.Frame.encode(%MAVLink2.Frame{msgid: msgid, payload: payload}, D)

{frames, errors, rest} = MAVLink2.Frame.drain(bytes, D)
```

`drain/2` returns every complete frame in a buffer, the errors it skipped
over, and the bytes left for the next read.

## Modules

| Module | |
| --- | --- |
| `MAVLink2.Frame` | v2 encode and decode for a dialect; `drain/2` over a byte stream |
| `MAVLink2.Dialect` | the behaviour a dialect implements: `crc_extra/1`, `payload_length/1` |
| `MAVLink2.Dialect.XML` | generates a dialect from MAVLink XML at compile time |
| `MAVLink2.XML` | reads MAVLink XML with its includes: wire order, lengths, `crc_extra` |
| `MAVLink2.Codec` | payloads from a wire layout; NaN and the infinities as atoms |
| `MAVLink2.Signing` | sign, verify, per-stream replay protection |
| `MAVLink2.CRC` | CRC-16/MCRF4XX with `crc_extra` |
| `MAVLink2.Link` | a link process over one transport |
| `MAVLink2.Transport` | the transport behaviour: `open/1`, `write/2`, `close/1` |
| `MAVLink2.Transport.UART` | a serial port through `Circuits.UART` |
| `MAVLink2.Transport.Loopback` | in memory, for tests; `echo: true` sends writes back |

A custom transport implements `MAVLink2.Transport` and sends received bytes to
the link as `{:mavlink_data, binary}`.

## Tests

```sh
mix test
```

The fixtures are pymavlink 2.4.50's XML definitions and its output on them;
see `test/fixtures/README.md`.
