defmodule MAVLink2.Transport.Loopback do
  @moduledoc """
  An in-memory transport for tests. With `echo: true` everything written
  comes back to the owner; `inject/2` delivers bytes as though the peer had
  sent them, and `written/1` returns what was written.
  """

  @behaviour MAVLink2.Transport

  use Agent

  @impl true
  def open(opts) do
    owner = Keyword.get(opts, :owner, self())
    echo? = Keyword.get(opts, :echo, false)
    Agent.start_link(fn -> %{owner: owner, echo: echo?, written: []} end)
  end

  @impl true
  def write(pid, data) do
    bin = IO.iodata_to_binary(data)

    Agent.update(pid, fn s ->
      if s.echo, do: send(s.owner, {:mavlink_data, bin})
      %{s | written: [bin | s.written]}
    end)
  end

  @impl true
  def close(pid), do: Agent.stop(pid)

  @doc "Everything written so far, oldest first."
  def written(pid), do: Agent.get(pid, &Enum.reverse(&1.written)) |> IO.iodata_to_binary()

  @doc "Deliver `bytes` to the owner as though the peer had sent them."
  def inject(pid, bytes) do
    Agent.get(pid, & &1.owner) |> send({:mavlink_data, bytes})
    :ok
  end
end
