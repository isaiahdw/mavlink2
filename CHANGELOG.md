# Changelog

## 0.1.0 (2026-11-04)

First release.

- `MAVLink2.Frame`: MAVLink v2 frames for any dialect, with payload truncation
  and zero-extension, resynchronisation after noise, 32-bit system ids and
  header targets (`SYSID32`, `TARGET32`), and frames outside the dialect kept
  on request.
- `MAVLink2.Signing`: signing and verification, with per-stream replay
  protection, a clock-seeded window for new streams, and reflected frames
  refused.
- `MAVLink2.Dialect.XML`: a dialect generated at compile time from MAVLink XML
  and its includes, with a typed struct per message, `encode/1`, `decode/2`
  and enum lookups.
- `MAVLink2.Link`: a link process over a transport that numbers outgoing
  frames, delivers decoded frames to subscribers, forwards frames unchanged,
  and counts errors, sequence gaps per sender and rejected signatures.
- `MAVLink2.Router`: forwarding between links by MAVLink's routing rules.
- `MAVLink2.Command`, `MAVLink2.Param`, `MAVLink2.Mission`: the command,
  parameter and mission protocols, with retries.
- `MAVLink2.Transport.UART` for serial and USB CDC ports through
  `Circuits.UART`, and `MAVLink2.Transport.Loopback` for tests.
