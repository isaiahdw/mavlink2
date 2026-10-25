defmodule MAVLink2.Transport.UART do
  @moduledoc """
  A serial port through `Circuits.UART`, 8N1 and no flow control.

  Options: `:device` (required), `:speed` (default 115200),
  `:flow_control` (default `:none`). Circuits.UART's active-mode messages
  are what `MAVLink2.Link` receives.
  """

  @behaviour MAVLink2.Transport

  @impl true
  def open(opts) do
    device = Keyword.fetch!(opts, :device)

    with {:ok, pid} <- uart().start_link([]),
         :ok <-
           uart().open(pid, device,
             speed: Keyword.get(opts, :speed, 115_200),
             data_bits: 8,
             stop_bits: 1,
             parity: :none,
             flow_control: Keyword.get(opts, :flow_control, :none),
             active: true
           ) do
      {:ok, pid}
    end
  end

  @impl true
  def write(pid, data), do: uart().write(pid, IO.iodata_to_binary(data))

  @impl true
  def close(pid), do: uart().close(pid)

  # Resolved at run time: Circuits.UART is an optional dependency.
  defp uart, do: Module.concat([:Circuits, :UART])
end
