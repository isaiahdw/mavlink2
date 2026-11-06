defmodule MAVLink2.Transport.Loopback do
  @moduledoc """
  An in-memory transport for tests. With `echo: true` everything written
  comes back to the owner; with `peer:` a pid or registered name (another
  link), everything written goes to it, or nowhere while it is not running.
  `inject/2` delivers bytes as though the peer had sent them, and
  `written/1` returns what was written.
  """

  @behaviour MAVLink2.Transport

  @impl true
  @spec options() :: keyword()
  def options, do: [echo: :boolean, peer: {:or, [{:in, [nil]}, :server]}]

  use Agent

  @impl true
  @spec open(keyword()) :: {:ok, pid()} | {:error, term()}
  def open(opts) do
    owner = Keyword.get(opts, :owner, self())
    echo? = Keyword.get(opts, :echo, false)
    peer = Keyword.get(opts, :peer)
    Agent.start_link(fn -> %{owner: owner, echo: echo?, peer: peer, written: []} end)
  end

  @impl true
  @spec write(pid(), iodata()) :: :ok
  def write(pid, data) do
    bin = IO.iodata_to_binary(data)

    Agent.update(pid, fn s ->
      if s.echo, do: send(s.owner, {:mavlink_data, bin})
      if pid = s.peer && GenServer.whereis(s.peer), do: send(pid, {:mavlink_data, bin})
      %{s | written: [bin | s.written]}
    end)
  end

  @impl true
  @spec close(pid()) :: :ok
  def close(pid), do: Agent.stop(pid)

  @doc "Everything written so far, oldest first."
  @spec written(pid()) :: binary()
  def written(pid), do: Agent.get(pid, &Enum.reverse(&1.written)) |> IO.iodata_to_binary()

  @doc "Deliver `bytes` to the owner as though the peer had sent them."
  @spec inject(pid(), binary()) :: :ok
  def inject(pid, bytes) do
    Agent.get(pid, & &1.owner) |> send({:mavlink_data, bytes})
    :ok
  end
end
