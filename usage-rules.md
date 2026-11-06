# mavlink2 usage rules

Rules for writing code that uses `mavlink2`, for people and for coding
agents. The API checks its arguments: a mistake raises `ArgumentError`
saying what is wrong and what would be right, so read the message. Errors
from the other end of a link are returned as `{:error, reason}`.

## Set up

- Define one dialect module per set of messages, from MAVLink XML, and pass
  that module everywhere a `:dialect` is asked for:

  ```elixir
  defmodule MyApp.MAVLink do
    use MAVLink2.Dialect.XML, file: "priv/mavlink/common.xml"
  end
  ```

  Put the XML and every file it includes (`standard.xml`, `minimal.xml`)
  side by side. Never write `crc_extra` values or payload layouts by hand.
- A serial or USB link needs `{:circuits_uart, "~> 1.5"}` in your deps and a
  `:device` such as `"/dev/ttyACM0"` (USB CDC) or `"/dev/ttyAMA0"` (a board
  UART). Its rate option is `:speed`, not `:baud`.
- Give this end real ids: `:sysid` 1 to 2^32-1 and `:compid` 1 to 255. 0 is
  the broadcast id and is refused. A ground station is conventionally
  `sysid: 255, compid: 190`; an autopilot is `sysid: 1, compid: 1`.
- Start links (and a router) under your supervision tree, with `:name`, and
  refer to them by name.

## Send

- Send message structs with `MAVLink2.Link.send/2`:

  ```elixir
  MAVLink2.Link.send(:fc, %MyApp.MAVLink.Heartbeat{type: 6, autopilot: 8})
  ```

  Use `send_message/4` only for a payload you already have as bytes.
- Field names are the XML's, as written (`target_system`, `param1`).
  Integer fields must fit their type; strings fit their `char[n]` length.
- Enum values in structs are integers. Get them by name:
  `MyApp.MAVLink.enum_value(:mav_type, :mav_type_gcs)`. Names are the XML's,
  lowercased. List an enum with `MyApp.MAVLink.enum(:mav_cmd)`.
- A message to a system id over 255: set `target_system` to the id and use
  `Link.send/2`, which puts it in the header. Do not do this by hand.

## Receive

- Subscribe the process that will handle frames, and say what it wants:

  ```elixir
  :ok = MAVLink2.Link.subscribe(:fc, self(), decode: true, only: [MyApp.MAVLink.Heartbeat])

  receive do
    {MAVLink2.Link, :fc, frame, %MyApp.MAVLink.Heartbeat{} = hb} -> {frame.sysid, hb}
  end
  ```

  Without `decode: true` the message is `{MAVLink2.Link, link, %MAVLink2.Frame{}}`
  (three elements) and the payload is bytes: decode it with
  `MyApp.MAVLink.decode(frame.msgid, frame.payload)`.
- The sender is `frame.sysid` and `frame.compid`, not a payload field.
- A subscriber with no `only:` gets every frame on the link: handle or drop
  every message in a `GenServer`'s `handle_info/2`, or its mailbox grows.

## Commands, parameters, missions

- `target` is `{sysid, compid}`. compid 0 means any component of the
  system.
- Commands take `MAV_CMD` entry atoms or integers:

  ```elixir
  {:ok, :mav_result_accepted, _ack} =
    MAVLink2.Command.long(:fc, {1, 1}, :mav_cmd_component_arm_disarm, [1.0])
  ```

  Any result but `:mav_result_accepted` means the target did not do it; it
  is not an error tuple. Positions go in `Command.int/5`, latitude and
  longitude as integers in degrees × 10^7 in `:x` and `:y`.
- These calls block the calling process until the target answers or the
  retries run out (`{:error, :timeout}`): seconds, with the default
  retries. A `GenServer` that calls one handles nothing else meanwhile;
  start a `Task` for it when that matters. The call does its own
  subscribing, so the caller need not be subscribed.
- Parameters: pass `encoding: :bytewise` for PX4 and leave the default
  (`:cast`) for ArduPilot. Names are at most 16 ASCII bytes.
  `Param.set/6` returns what the target now holds; compare it with what you
  set.
- Missions: items are keyword lists of `MISSION_ITEM_INT` fields. Use the
  plain global frames (`:mav_frame_global_relative_alt`), not the
  superseded `_int` ones. `upload/4` returns `{:ok, opaque_id}` and
  `download/3` `{:ok, items, opaque_id}`.

## Signing

- The key is 32 bytes shared with the peer:
  `MAVLink2.Signing.new(:crypto.hash(:sha256, passphrase), link_id: 1)`.
  Give each link its own `link_id`.
- With `:signing`, unsigned frames are refused unless their ids are in
  `accept_unsigned:` (or it is `:all`, for a link that is secure by itself).
- A board without a real-time clock should save `signing.timestamp` and
  start from it with `timestamp:`; otherwise old captured frames are
  accepted after a reboot until its clock is set.
- Never forward or log `SETUP_SIGNING`; the router does not forward it.

## Routing

- `MAVLink2.Router.start_link(links: [:radio, :usb], sysid: 1)` forwards
  frames unchanged between links. Your application still subscribes to the
  links itself.

## Tests

- Use `MAVLink2.Transport.Loopback`: `echo: true` sends what a link writes
  back to it, and `peer: name` joins two links, so one can play the vehicle:
  `start_link(name: :gcs, transport: MAVLink2.Transport.Loopback, peer: :vehicle, ...)`
  and the same for `:vehicle` with `peer: :gcs`.
