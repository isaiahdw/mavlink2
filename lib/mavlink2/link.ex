defmodule MAVLink2.Link do
  @moduledoc """
  A MAVLink link over one transport: it owns the transport, reassembles
  frames from the byte stream, numbers what it sends and delivers each
  decoded frame to its subscribers as `{MAVLink2.Link, link, frame}`, where
  `link` is the link's name or pid.

  It knows framing and sequence numbers, not what a message means.

  - A partial frame stays buffered until the rest arrives.
  - Decode errors are counted in `stats/1`, not raised: a noisy line
    degrades.
  - Outgoing frames are numbered per link; a gap in the peer's numbers is
    counted as `:dropped`.

  Options:

  | | |
  | --- | --- |
  | `:dialect` | a `MAVLink2.Dialect` (required) |
  | `:transport` | a `MAVLink2.Transport` (default `MAVLink2.Transport.UART`); the rest of the options go to its `open/1` |
  | `:sendable` | the message ids the peer accepts; others are refused with `{:error, {:not_sendable, id}}`. Default: any id the dialect has |
  | `:sysid`, `:compid` | this end's ids (default 1, 1) |
  | `:name` | registered name |

  A transport that does not open logs a warning and the link returns
  `:ignore`, so a board without the peer still starts.
  """

  use GenServer

  require Logger

  alias MAVLink2.Frame

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :dialect,
      :transport,
      :handle,
      :sendable,
      sysid: 1,
      compid: 1,
      buffer: <<>>,
      tx_seq: 0,
      peer_seq: nil,
      subscribers: MapSet.new(),
      stats: %{rx: 0, tx: 0, errors: 0, dropped: 0, unknown: 0}
    ]
  end

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Delivers every decoded frame to `pid`."
  def subscribe(link, pid \\ self()), do: GenServer.call(link, {:subscribe, pid})

  def unsubscribe(link, pid \\ self()), do: GenServer.call(link, {:unsubscribe, pid})

  @doc """
  Sends message `msgid` with `payload`. `sysid:` and `compid:` override the
  link's; `force: true` sends an id outside `:sendable`, for probing.
  """
  @spec send_message(GenServer.server(), non_neg_integer(), binary(), keyword()) ::
          :ok | {:error, term()}
  def send_message(link, msgid, payload, opts \\ [])
      when is_integer(msgid) and is_binary(payload),
      do: GenServer.call(link, {:send, msgid, payload, opts})

  @doc "Counts: `:rx`, `:tx`, `:errors`, `:dropped`, `:unknown`."
  def stats(link), do: GenServer.call(link, :stats)

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, MAVLink2.Transport.UART)

    # The link always owns its transport's bytes.
    case transport.open(Keyword.put(opts, :owner, self())) do
      {:ok, handle} ->
        {:ok,
         %State{
           name: Keyword.get(opts, :name) || self(),
           dialect: Keyword.fetch!(opts, :dialect),
           transport: transport,
           handle: handle,
           sendable: Keyword.get(opts, :sendable),
           sysid: Keyword.get(opts, :sysid, 1),
           compid: Keyword.get(opts, :compid, 1)
         }}

      {:error, reason} ->
        Logger.warning("MAVLink2.Link: transport did not open: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  def handle_call({:send, msgid, payload, opts}, _from, state) do
    if state.sendable != nil and msgid not in state.sendable and
         not Keyword.get(opts, :force, false) do
      {:reply, {:error, {:not_sendable, msgid}}, state}
    else
      frame = %Frame{
        msgid: msgid,
        payload: payload,
        seq: state.tx_seq,
        sysid: Keyword.get(opts, :sysid, state.sysid),
        compid: Keyword.get(opts, :compid, state.compid)
      }

      with {:ok, bytes} <- Frame.encode(frame, state.dialect),
           :ok <- state.transport.write(state.handle, bytes) do
        {:reply, :ok, state |> Map.update!(:tx_seq, &rem(&1 + 1, 256)) |> bump(:tx)}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info({:mavlink_data, bytes}, state) do
    {frames, errors, rest} = Frame.drain(state.buffer <> bytes, state.dialect)
    state = state |> Map.put(:buffer, rest) |> count_errors(errors)
    {:noreply, Enum.reduce(frames, state, &deliver/2)}
  end

  # Circuits.UART's active-mode messages.
  def handle_info({:circuits_uart, _port, bytes}, state) when is_binary(bytes),
    do: handle_info({:mavlink_data, bytes}, state)

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.error("MAVLink2.Link: serial error: #{inspect(reason)}")
    {:noreply, bump(state, :errors)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{transport: t, handle: h}) when h != nil, do: t.close(h)
  def terminate(_reason, _state), do: :ok

  defp deliver(%Frame{} = frame, state) do
    state = track_peer_seq(state, frame.seq)
    for pid <- state.subscribers, do: send(pid, {__MODULE__, state.name, frame})
    bump(state, :rx)
  end

  defp track_peer_seq(%{peer_seq: nil} = state, seq), do: %{state | peer_seq: seq}

  defp track_peer_seq(state, seq) do
    lost = rem(seq - rem(state.peer_seq + 1, 256) + 256, 256)
    state = %{state | peer_seq: seq}
    if lost > 0, do: bump(state, :dropped, lost), else: state
  end

  defp count_errors(state, errors) do
    Enum.reduce(errors, state, fn
      {:unknown_msgid, _}, s -> bump(s, :unknown)
      _, s -> bump(s, :errors)
    end)
  end

  defp bump(state, key, n \\ 1), do: %{state | stats: Map.update!(state.stats, key, &(&1 + n))}
end
