defmodule MAVLink2.Signing do
  @moduledoc """
  MAVLink v2 message signing: a 32-byte secret shared by both ends, a link
  id, and a timestamp that only moves forward.

  A signed frame has `incompat_flags` bit 0 set and 13 bytes after its
  checksum: the link id, a 48-bit timestamp (little endian, 10 µs units
  since 2015-01-01 00:00:00 UTC) and the first 6 bytes of

      SHA-256(secret ++ frame from STX through checksum ++ link id ++ timestamp)

  Receiving, a frame is accepted only if its signature matches and its
  timestamp is later than the last one accepted from the same stream
  (link id, system, component). A stream not seen before is accepted if its
  timestamp is no more than one minute behind this end's timestamp, which
  is at least the clock. The signature is checked before any stream state
  changes, so a forged frame moves nothing.

  Sending, each frame takes a timestamp later than the previous one and no
  earlier than the clock, so a clock that steps back cannot repeat one.
  This end's timestamp also follows the latest accepted from a peer.

  Each frame this end signs also records its own stream, so its frames
  reflected back to it are refused as replays.

  The replay window is only as good as the clock: a board that boots with
  no real time accepts stale frames until its timestamp catches up. Such a
  board can persist `timestamp` and pass it back to `new/2`.
  """

  import Bitwise

  @enforce_keys [:key]
  defstruct [:key, link_id: 0, timestamp: 0, streams: %{}, accept_unsigned: []]

  @type t :: %__MODULE__{
          key: <<_::256>>,
          link_id: 0..255,
          timestamp: non_neg_integer(),
          streams: %{{0..255, 0..0xFFFFFFFF, 0..255} => non_neg_integer()},
          accept_unsigned: [non_neg_integer()] | :all
        }

  @iflag_signed 0x01
  @iflag_sysid32 0x02
  # 2015-01-01T00:00:00Z in Unix microseconds.
  @epoch_us 1_420_070_400_000_000
  # One minute in timestamp units (10 µs).
  @new_stream_window 6_000_000
  @max_timestamp (1 <<< 48) - 1

  @doc """
  Signing state for `key`. Options:

  | | |
  | --- | --- |
  | `:link_id` | default 0 |
  | `:accept_unsigned` | message ids delivered even when unsigned, or `:all` (for a link that is secure by itself, such as USB); default none |
  | `:timestamp` | the earliest timestamp, for a board that persists it; default 0 |
  """
  @spec new(<<_::256>>, keyword()) :: t()
  def new(<<_::binary-size(32)>> = key, opts \\ []) do
    %__MODULE__{
      key: key,
      link_id: Keyword.get(opts, :link_id, 0),
      accept_unsigned: Keyword.get(opts, :accept_unsigned, []),
      timestamp: Keyword.get(opts, :timestamp, 0)
    }
  end

  @spec iflag_signed() :: 0x01
  def iflag_signed, do: @iflag_signed

  @doc "A timestamp for `unix_us`, Unix time in microseconds."
  @spec timestamp(integer()) :: non_neg_integer()
  def timestamp(unix_us), do: max(div(unix_us - @epoch_us, 10), 0)

  @doc """
  Signs `wire`, an encoded frame whose `incompat_flags` already carry the
  signed bit, with the next timestamp at or after `now` (a `timestamp/1`).
  """
  @spec sign(t(), binary(), non_neg_integer()) :: {binary(), t()}
  def sign(%__MODULE__{} = s, wire, now) do
    {sysid, compid} = source(wire)
    ts = min(max(now, s.timestamp + 1), @max_timestamp)
    tail = <<s.link_id, ts::little-48>>
    streams = Map.put(s.streams, {s.link_id, sysid, compid}, ts)
    {wire <> tail <> digest(s.key, wire <> tail), %{s | timestamp: ts, streams: streams}}
  end

  @doc """
  Encodes `frame` signed: the signed bit set before the checksum, then the
  signature with the next timestamp at or after `now`.
  """
  @spec encode(t(), MAVLink2.Frame.t(), module(), non_neg_integer()) ::
          {:ok, binary(), t()} | {:error, term()}
  def encode(%__MODULE__{} = s, %MAVLink2.Frame{} = frame, dialect, now) do
    frame = %{frame | incompat_flags: frame.incompat_flags ||| @iflag_signed, signature: nil}

    with {:ok, wire} <- MAVLink2.Frame.encode(frame, dialect) do
      {signed, s} = sign(s, wire, now)
      {:ok, signed, s}
    end
  end

  @doc """
  Checks a decoded frame at `now`, this end's clock as a `timestamp/1`.
  `{:ok, state}` for a signed frame that verifies and is not a replay, or
  an unsigned one of an `accept_unsigned` id; otherwise
  `{:error, :unsigned | :bad_signature | :replay}`.
  """
  @spec verify(t(), MAVLink2.Frame.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :unsigned | :bad_signature | :replay}
  def verify(%__MODULE__{} = s, %MAVLink2.Frame{signature: nil} = frame, _now) do
    if s.accept_unsigned == :all or frame.msgid in s.accept_unsigned,
      do: {:ok, s},
      else: {:error, :unsigned}
  end

  def verify(
        %__MODULE__{} = s,
        %MAVLink2.Frame{signature: {link_id, ts, sig, signed}} = frame,
        now
      ) do
    s = %{s | timestamp: max(s.timestamp, now)}
    stream = {link_id, frame.sysid, frame.compid}

    cond do
      not :crypto.hash_equals(digest(s.key, signed), sig) ->
        {:error, :bad_signature}

      replay?(s, stream, ts) ->
        {:error, :replay}

      true ->
        {:ok, %{s | streams: Map.put(s.streams, stream, ts), timestamp: max(s.timestamp, ts)}}
    end
  end

  defp replay?(s, stream, ts) do
    case s.streams do
      %{^stream => last} -> ts <= last
      _ -> ts + @new_stream_window < s.timestamp
    end
  end

  defp source(<<_stx, _len, iflags, _cflags, _seq, sysid0, rest::binary>>)
       when (iflags &&& @iflag_sysid32) != 0 do
    <<sysid_hi::little-24, compid, _::binary>> = rest
    {sysid0 + (sysid_hi <<< 8), compid}
  end

  defp source(<<_stx, _len, _iflags, _cflags, _seq, sysid, compid, _::binary>>),
    do: {sysid, compid}

  defp digest(key, data), do: :crypto.hash(:sha256, [key, data]) |> binary_part(0, 6)
end
