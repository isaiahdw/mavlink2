defmodule MAVLink2.TestDialect do
  @moduledoc false
  @behaviour MAVLink2.Dialect

  # HEARTBEAT and COMMAND_LONG from common.xml, and one id with a short payload.
  @messages %{0 => {50, 9}, 76 => {152, 33}, 300 => {7, 4}}

  def msgids, do: Map.keys(@messages)

  @impl true
  def crc_extra(id), do: with({c, _} <- Map.get(@messages, id), do: c)

  @impl true
  def payload_length(id), do: with({_, l} <- Map.get(@messages, id), do: l)
end
