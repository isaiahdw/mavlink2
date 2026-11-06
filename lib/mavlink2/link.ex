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
  - Outgoing frames are numbered per link; a gap in a sender's numbers
    (per system and component id) is counted as `:dropped`.

  Options:

  | | |
  | --- | --- |
  | `:dialect` | a `MAVLink2.Dialect` (required) |
  | `:transport` | a `MAVLink2.Transport` (default `MAVLink2.Transport.UART`); the rest of the options go to its `open/1` |
  | `:sendable` | the message ids the peer accepts; others are refused with `{:error, {:not_sendable, id}}`. Default: any id the dialect has |
  | `:sysid`, `:compid` | this end's ids (default 1, 1): `sysid` from 1 to 32 bits, `compid` 1 to 255. 0 is the broadcast id and never a sender's, so the link refuses it, here and in `send_message/4` |
  | `:unknown` | `:skip` (default) or `:keep`: deliver frames whose id the dialect lacks, unchecked, with `known: false` (see `MAVLink2.Frame.decode/3`). Each is counted in `:unknown` as well as `:rx` |
  | `:signing` | a `MAVLink2.Signing`: every frame sent is signed, and a frame received is delivered only if it verifies (counted as `:unsigned`, `:bad_signature` or `:replay` otherwise, and delivered tagged to subscribers that ask; see `subscribe/3`). Without it, frames are sent unsigned and every frame received is delivered, signed or not |
  | `:clock` | Unix time in microseconds for signing timestamps (default `System.os_time(:microsecond)`) |
  | `:name` | registered name |

  A transport that does not open logs a warning and the link returns
  `:ignore`, so a board without the peer still starts.
  """

  use GenServer

  # Link.send/3 sends a message; Kernel.send/2 is called by its full name.
  import Kernel, except: [send: 2]

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
      :signing,
      :clock,
      unknown: :skip,
      sysid: 1,
      compid: 1,
      buffer: <<>>,
      tx_seq: 0,
      peer_seq: %{},
      subscribers: %{},
      stats: %{
        rx: 0,
        tx: 0,
        errors: 0,
        dropped: 0,
        unknown: 0,
        unsigned: 0,
        bad_signature: 0,
        replay: 0
      }
    ]
  end

  @options [
    dialect: :module,
    transport: :module,
    sendable: {:or, [{:in, [nil]}, {:list, :non_neg_integer}]},
    sysid: :id,
    compid: :compid,
    signing: {:or, [{:in, [nil]}, {:struct, MAVLink2.Signing}]},
    clock: {:fun, 0},
    unknown: {:in, [:skip, :keep]},
    name: :server
  ]

  @doc """
  Starts a link. Raises ArgumentError for an unknown option or a bad value;
  see the module doc for the options.

      MAVLink2.Link.start_link(dialect: MyDialect, device: "/dev/ttyACM0", speed: 115_200)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    where = "MAVLink2.Link.start_link/1"
    MAVLink2.Options.keyword!(opts, where)
    transport = Keyword.get(opts, :transport, MAVLink2.Transport.UART)
    MAVLink2.Options.check!(transport, :module, "#{where}: option :transport")

    transport_options =
      if function_exported?(transport, :options, 0), do: transport.options(), else: nil

    schema = @options ++ (transport_options || [])
    known = Keyword.keys(schema)

    opts
    |> then(&if(transport_options, do: &1, else: Keyword.take(&1, known)))
    |> MAVLink2.Options.validate!(schema, where, [:dialect])

    MAVLink2.Options.dialect!(Keyword.fetch!(opts, :dialect), "#{where}: option :dialect")

    if transport == MAVLink2.Transport.UART and not Keyword.has_key?(opts, :device) do
      raise ArgumentError,
            "#{where}: option :device is required for MAVLink2.Transport.UART, " <>
              "such as device: \"/dev/ttyACM0\" (USB) or \"/dev/ttyAMA0\" (a board UART)"
    end

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Delivers every frame the link receives to `pid` as
  `{MAVLink2.Link, link, frame}`, `frame` a `MAVLink2.Frame`. Subscribing
  again replaces the options. The subscription ends when `pid` exits.

  Options:

  | | |
  | --- | --- |
  | `decode: true` | deliver `{MAVLink2.Link, link, frame, message}` instead, `message` the decoded struct (a dialect from `MAVLink2.Dialect.XML`). Frames the dialect cannot decode are not delivered |
  | `only: [...]` | deliver only these messages: message structs' modules (`MyDialect.Heartbeat`) or ids |
  | `rejected: true` | also deliver frames the link's `:signing` refuses, as `{MAVLink2.Link, link, {:rejected, reason, frame}}`, `reason` one of `:unsigned`, `:bad_signature`, `:replay`, so that one cannot be mistaken for a verified frame. Its timestamp moves nothing. A router forwards these; an application can show them as untrusted |

      :ok = MAVLink2.Link.subscribe(link, self(), decode: true, only: [MyDialect.Heartbeat])

      receive do
        {MAVLink2.Link, ^link, frame, %MyDialect.Heartbeat{} = heartbeat} -> {frame.sysid, heartbeat}
      end
  """
  @spec subscribe(GenServer.server(), pid(), keyword()) :: :ok
  def subscribe(link, pid \\ self(), opts \\ []) do
    where = "MAVLink2.Link.subscribe/3"
    MAVLink2.Options.check!(pid, :pid, "#{where}: the subscriber")

    MAVLink2.Options.validate!(
      opts,
      [rejected: :boolean, decode: :boolean, only: {:list, {:or, [:non_neg_integer, :atom]}}],
      where
    )

    decode? = Keyword.get(opts, :decode, false)

    if decode? do
      dialect = info(link).dialect

      unless function_exported?(dialect, :decode, 2) do
        raise ArgumentError,
              "#{where}: decode: true needs a dialect with decode/2, such as one from " <>
                "MAVLink2.Dialect.XML; #{inspect(dialect)} has none"
      end
    end

    only =
      case Keyword.fetch(opts, :only) do
        {:ok, ids} -> MapSet.new(ids, &msgid!(&1, where))
        :error -> nil
      end

    GenServer.call(
      link,
      {:subscribe, pid,
       %{rejected: Keyword.get(opts, :rejected, false), decode: decode?, only: only}}
    )
  end

  defp msgid!(id, _where) when is_integer(id), do: id

  defp msgid!(mod, where) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :msgid, 0),
      do: mod.msgid(),
      else:
        raise(
          ArgumentError,
          "#{where}: :only takes message ids or message modules such as MyDialect.Heartbeat; " <>
            "#{inspect(mod)} is neither"
        )
  end

  @doc """
  Encodes `message`, a struct of the link's dialect, and sends it.
  `target_system` over 255 goes in the header (`TARGET32`) with 255 in the
  payload, as MAVLink requires. Options are `send_message/4`'s other than
  `:target_sysid`. Raises ArgumentError for a struct that is not of the
  link's dialect, or a field value that does not fit its type.

      MAVLink2.Link.send(link, %MyDialect.Heartbeat{type: 6, autopilot: 8})
  """
  @spec send(GenServer.server(), struct(), keyword()) :: :ok | {:error, term()}
  def send(link, message, opts \\ [])

  def send(link, %mod{} = message, opts) do
    where = "MAVLink2.Link.send/3"

    MAVLink2.Options.validate!(
      opts,
      [sysid: :id, compid: :compid, force: :boolean],
      where
    )

    dialect = info(link).dialect

    unless function_exported?(dialect, :message, 1) and function_exported?(mod, :msgid, 0) and
             dialect.message(mod.msgid()) == mod do
      raise ArgumentError,
            "#{where}: #{inspect(mod)} is not a message of the link's dialect " <>
              "#{inspect(dialect)}; build it as %#{inspect(dialect)}.MessageName{...}"
    end

    {message, header} =
      case message do
        %{target_system: t} when is_integer(t) and t > 255 ->
          {%{message | target_system: 255}, [target_sysid: t]}

        _ ->
          {message, []}
      end

    {msgid, payload} = dialect.encode(message)
    send_message(link, msgid, payload, opts ++ header)
  end

  def send(_link, message, _opts) do
    raise ArgumentError,
          "MAVLink2.Link.send/3 takes a message struct of the link's dialect, such as " <>
            "%MyDialect.Heartbeat{}; got: #{inspect(message)}"
  end

  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(link, pid \\ self()), do: GenServer.call(link, {:unsubscribe, pid})

  @doc """
  Sends message `msgid` with `payload`. `sysid:` and `compid:` override the
  link's; `target_sysid:` puts a target system in the header, for a target
  over 255 (with 255 in the payload's `target_system`); `force: true` sends
  an id outside `:sendable`, for probing.
  """
  @spec send_message(GenServer.server(), non_neg_integer(), binary(), keyword()) ::
          :ok | {:error, term()}
  def send_message(link, msgid, payload, opts \\ [])

  def send_message(link, msgid, payload, opts)
      when is_integer(msgid) and msgid in 0..0xFFFFFF and is_binary(payload) do
    MAVLink2.Options.validate!(
      opts,
      [sysid: :id, compid: :compid, target_sysid: {:or, [{:in, [nil]}, :id]}, force: :boolean],
      "MAVLink2.Link.send_message/4"
    )

    GenServer.call(link, {:send, msgid, payload, opts})
  end

  def send_message(_link, %_{} = message, _payload, _opts) do
    raise ArgumentError,
          "MAVLink2.Link.send_message/4 takes a message id and an encoded payload; " <>
            "for a message struct (#{inspect(message.__struct__)}) use MAVLink2.Link.send/2"
  end

  def send_message(_link, msgid, payload, _opts) do
    raise ArgumentError,
          "MAVLink2.Link.send_message/4: the message id must be an integer up to 24 bits and " <>
            "the payload a binary, as a dialect's encode/1 returns them; got: " <>
            "#{inspect(msgid)}, #{inspect(payload, limit: 8)}"
  end

  @doc """
  Writes a decoded frame's `raw` bytes unchanged: its sequence number,
  source and signature are the original sender's. For routing; `:sendable`
  does not apply. A link with `:signing` does not sign what it forwards.
  """
  @spec forward(GenServer.server(), Frame.t()) :: :ok | {:error, term()}
  def forward(link, %Frame{raw: raw}) when is_binary(raw),
    do: GenServer.call(link, {:forward, raw})

  def forward(_link, %Frame{raw: nil}), do: {:error, :no_raw_bytes}

  @doc "This end's `:sysid`, `:compid` and `:dialect`."
  @spec info(GenServer.server()) :: %{sysid: non_neg_integer(), compid: 0..255, dialect: module()}
  def info(link), do: GenServer.call(link, :info)

  @doc "Counts: `:rx`, `:tx`, `:errors`, `:dropped`, `:unknown`, `:unsigned`, `:bad_signature`, `:replay`."
  @spec stats(GenServer.server()) :: %{atom() => non_neg_integer()}
  def stats(link), do: GenServer.call(link, :stats)

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, MAVLink2.Transport.UART)

    with :ok <- check_source(Keyword.get(opts, :sysid, 1), Keyword.get(opts, :compid, 1)) do
      open(transport, opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # 0 is the broadcast id: never a sender's.
  defp check_source(sysid, _compid) when not (is_integer(sysid) and sysid in 1..0xFFFFFFFF),
    do: {:error, {:out_of_range, :sysid}}

  defp check_source(_sysid, compid) when not (is_integer(compid) and compid in 1..255),
    do: {:error, {:out_of_range, :compid}}

  defp check_source(_sysid, _compid), do: :ok

  defp open(transport, opts) do
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
           signing: Keyword.get(opts, :signing),
           clock: Keyword.get(opts, :clock, fn -> System.os_time(:microsecond) end),
           unknown: Keyword.get(opts, :unknown, :skip),
           sysid: Keyword.get(opts, :sysid, 1),
           compid: Keyword.get(opts, :compid, 1)
         }}

      {:error, reason} ->
        Logger.warning("MAVLink2.Link: transport did not open: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_call({:subscribe, pid, sub}, _from, state) do
    ref =
      case state.subscribers do
        %{^pid => {ref, _}} -> ref
        _ -> Process.monitor(pid)
      end

    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, {ref, sub})}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {{ref, _}, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  def handle_call(:info, _from, state),
    do: {:reply, %{sysid: state.sysid, compid: state.compid, dialect: state.dialect}, state}

  def handle_call({:forward, raw}, _from, state) do
    case state.transport.write(state.handle, raw) do
      :ok -> {:reply, :ok, bump(state, :tx)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, msgid, payload, opts}, _from, state) do
    source =
      check_source(
        Keyword.get(opts, :sysid, state.sysid),
        Keyword.get(opts, :compid, state.compid)
      )

    cond do
      source != :ok ->
        {:reply, source, state}

      state.sendable != nil and msgid not in state.sendable and
          not Keyword.get(opts, :force, false) ->
        {:reply, {:error, {:not_sendable, msgid}}, state}

      true ->
        send_frame(msgid, payload, opts, state)
    end
  end

  defp send_frame(msgid, payload, opts, state) do
    frame = %Frame{
      msgid: msgid,
      payload: payload,
      seq: state.tx_seq,
      sysid: Keyword.get(opts, :sysid, state.sysid),
      compid: Keyword.get(opts, :compid, state.compid),
      target_sysid: Keyword.get(opts, :target_sysid)
    }

    with {:ok, bytes, state} <- encode(frame, state),
         :ok <- state.transport.write(state.handle, bytes) do
      {:reply, :ok, state |> Map.update!(:tx_seq, &rem(&1 + 1, 256)) |> bump(:tx)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:mavlink_data, bytes}, state) do
    {frames, errors, rest} =
      Frame.drain(state.buffer <> bytes, state.dialect, unknown: state.unknown)

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
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{transport: t, handle: h}) when h != nil, do: t.close(h)
  def terminate(_reason, _state), do: :ok

  defp encode(frame, %{signing: nil} = state) do
    with {:ok, bytes} <- Frame.encode(frame, state.dialect), do: {:ok, bytes, state}
  end

  defp encode(frame, state) do
    now = MAVLink2.Signing.timestamp(state.clock.())

    with {:ok, bytes, signing} <-
           MAVLink2.Signing.encode(state.signing, frame, state.dialect, now),
         do: {:ok, bytes, %{state | signing: signing}}
  end

  defp deliver(%Frame{} = frame, %{signing: nil} = state), do: fan_out(frame, state)

  defp deliver(%Frame{} = frame, state) do
    now = MAVLink2.Signing.timestamp(state.clock.())

    case MAVLink2.Signing.verify(state.signing, frame, now) do
      {:ok, signing} ->
        fan_out(frame, %{state | signing: signing})

      {:error, reason} ->
        for {pid, {_ref, %{rejected: true} = sub}} <- state.subscribers,
            wants?(sub, frame),
            do: Kernel.send(pid, {__MODULE__, state.name, {:rejected, reason, frame}})

        bump(state, reason)
    end
  end

  defp fan_out(frame, state) do
    state = track_peer_seq(state, frame)
    decoded = decode_once(state, frame)

    for {pid, {_ref, sub}} <- state.subscribers, wants?(sub, frame) do
      case {sub.decode, decoded} do
        {false, _} -> Kernel.send(pid, {__MODULE__, state.name, frame})
        {true, {:ok, message}} -> Kernel.send(pid, {__MODULE__, state.name, frame, message})
        {true, _} -> :ok
      end
    end

    state = bump(state, :rx)
    if frame.known, do: state, else: bump(state, :unknown)
  end

  defp wants?(%{only: nil}, _frame), do: true
  defp wants?(%{only: ids}, frame), do: MapSet.member?(ids, frame.msgid)

  # Decoded once for all the subscribers that asked, and only if one did.
  defp decode_once(state, %Frame{known: true} = frame) do
    if Enum.any?(state.subscribers, fn {_, {_, sub}} -> sub.decode and wants?(sub, frame) end),
      do: state.dialect.decode(frame.msgid, frame.payload),
      else: :none
  end

  defp decode_once(_state, _frame), do: :none

  defp track_peer_seq(state, %Frame{sysid: sysid, compid: compid, seq: seq}) do
    sender = {sysid, compid}

    lost =
      case state.peer_seq do
        %{^sender => last} -> Integer.mod(seq - last - 1, 256)
        _ -> 0
      end

    state = %{state | peer_seq: Map.put(state.peer_seq, sender, seq)}
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
