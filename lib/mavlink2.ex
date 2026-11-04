defmodule MAVLink2 do
  @moduledoc """
  MAVLink v2 for Elixir. See the README for an overview, and the modules
  for each part:

  | | |
  | --- | --- |
  | Frames | `MAVLink2.Frame`, `MAVLink2.Signing` |
  | Dialects | `MAVLink2.Dialect.XML` |
  | Links | `MAVLink2.Link`, `MAVLink2.Router` |
  | Services | `MAVLink2.Command`, `MAVLink2.Param`, `MAVLink2.Mission` |
  | Transports | `MAVLink2.Transport.UART`, `MAVLink2.Transport.Loopback` |
  """

  @typedoc """
  A system and component to talk to: a sysid of up to 32 bits and a compid,
  where compid 0 is any component of the system.
  """
  @type target :: {sysid :: pos_integer(), compid :: 0..255}
end
