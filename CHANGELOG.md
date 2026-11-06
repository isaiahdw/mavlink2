# Changelog

## 0.1.0 (2026-11-06)

First release.

- Talk MAVLink 2 with autopilots, ground stations and your own
  microcontrollers, over a serial port or USB.
- Generate a dialect from MAVLink XML: a struct for every message, with
  encoding, decoding and enum lookups.
- Send message structs and receive decoded messages with `MAVLink2.Link`.
- Sign messages, and reject unsigned, forged and replayed ones.
- Forward messages between links with `MAVLink2.Router`.
- Send commands, read and set parameters, and upload, download and clear
  missions, with retries.
- Mistakes in calling the library raise errors that say how to fix them.

Requires Elixir 1.18 or later.
