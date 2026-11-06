defmodule MAVLink2.Transport do
  @moduledoc """
  The byte transport under a `MAVLink2.Link`: `MAVLink2.Transport.UART` for
  a serial port, `MAVLink2.Transport.Loopback` for tests.

  `open/1` gets the link's options with `:owner`, the link process. Bytes
  arrive at the owner as `{:mavlink_data, binary}`.
  """

  @type t :: term()

  @callback open(keyword()) :: {:ok, t()} | {:error, term()}
  @callback write(t(), iodata()) :: :ok | {:error, term()}
  @callback close(t()) :: :ok

  @doc """
  The options `open/1` takes, as `[{name, type}]` for `MAVLink2.Link` to
  check before opening, so a misspelled option is an error rather than
  ignored. Optional: without it, the link passes any option through.
  """
  @callback options() :: keyword()

  @optional_callbacks options: 0
end
