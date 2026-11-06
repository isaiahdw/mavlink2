defmodule MAVLink2.Frame do
  @moduledoc """
  MAVLink v2 frame encoding and decoding, for a `MAVLink2.Dialect`.

  Wire layout:

      STX             0xFD  (v2); 0xFE (v1) is refused on receive
      len             payload length after truncation
      incompat_flags
      compat_flags
      seq
      sysid           1 byte, or 4 (little endian) with SYSID32
      compid
      msgid           24-bit, little endian
      target_sysid    4 bytes, little endian, with TARGET32 only
      payload
      checksum        16-bit LE, over everything after STX plus crc_extra
      signature       13 bytes, with SIGNED only

  ## Incompat flags

  | Bit | | |
  | --- | --- | --- |
  | `0x01` | SIGNED | a signature follows the checksum; see `MAVLink2.Signing` |
  | `0x02` | SYSID32 | `sysid` is 4 bytes. `encode/2` sets it when `sysid` is over 255 |
  | `0x04` | TARGET32 | the header carries `target_sysid`, which takes precedence over a payload `target_system`. `encode/2` sets it when `target_sysid` is not `nil` |

  A frame with any other bit is refused.

  A message to a system id over 255 carries `target_sysid` and 255 in its
  payload `target_system`.

  ## Payload truncation

  v2 drops trailing zero bytes from the payload on the wire, keeping at
  least one, and the receiver zero-extends it back to the message's length.
  A receiver that does not zero-extend misreads every short frame.

  ## Decoded frames

  `raw` is the frame's wire bytes, for forwarding it unchanged (a
  re-encoded frame would lose its signature). `known` is `false` only for a
  frame decoded with `unknown: :keep` whose id the dialect lacks: its
  checksum was not checked and its payload is as received.
  """

  import Bitwise

  alias MAVLink2.CRC

  @stx_v2 0xFD
  @stx_v1 0xFE
  # len, the two flags, seq, sysid, compid, msgid: the header after STX
  # without extensions. The checksum also starts after STX.
  @base_header 9
  @iflag_signed 0x01
  @iflag_sysid32 0x02
  @iflag_target32 0x04
  # The known flags are the low bits, so a byte over this has an unknown one.
  @iflags_known 0x07
  @signature_bytes 13
  @u32 0xFFFFFFFF

  defstruct [
    :msgid,
    :payload,
    seq: 0,
    sysid: 1,
    compid: 1,
    incompat_flags: 0,
    compat_flags: 0,
    target_sysid: nil,
    signature: nil,
    raw: nil,
    known: true
  ]

  @type t :: %__MODULE__{
          msgid: non_neg_integer(),
          payload: binary(),
          seq: 0..255,
          sysid: 0..0xFFFFFFFF,
          compid: 0..255,
          incompat_flags: 0..255,
          compat_flags: 0..255,
          target_sysid: nil | 0..0xFFFFFFFF,
          signature:
            nil | {link_id :: 0..255, timestamp :: non_neg_integer(), <<_::48>>, binary()},
          raw: nil | binary(),
          known: boolean()
        }

  @spec stx_v2() :: 0xFD
  def stx_v2, do: @stx_v2
  @spec stx_v1() :: 0xFE
  def stx_v1, do: @stx_v1
  @spec iflag_signed() :: 0x01
  def iflag_signed, do: @iflag_signed

  @doc """
  Encode a frame to wire bytes. `raw` and `known` are ignored.

  Errors:

  | | |
  | --- | --- |
  | `{:unknown_msgid, id}` | the dialect does not have `id`: a guessed `crc_extra` makes a frame the peer drops without a word |
  | `{:out_of_range, field}` | `seq`, `compid` or a flags byte outside 0..255, `sysid` or `target_sysid` outside 32 bits, or `msgid` outside 24 bits |
  | `{:unsupported_incompat_flags, flags}` | a bit in `incompat_flags` other than the three above |
  | `:payload_too_long` | the payload, after truncation, is longer than the message |
  """
  @spec encode(t(), module()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = f, dialect) do
    with :ok <- check_header(f),
         {:ok, crc_extra} <- fetch_crc_extra(dialect, f.msgid),
         payload = truncate(f.payload),
         :ok <- check_length(payload, dialect.payload_length(f.msgid)) do
      header = header(f, byte_size(payload))
      crc = CRC.checksum(header <> payload, crc_extra)
      {:ok, <<@stx_v2, header::binary, payload::binary, crc::little-16>>}
    end
  end

  defp header(f, len) do
    sysid32? = f.sysid > 255 or (f.incompat_flags &&& @iflag_sysid32) != 0
    target32? = f.target_sysid != nil

    incompat =
      (f.incompat_flags &&& bnot(@iflag_sysid32 ||| @iflag_target32)) |||
        if(sysid32?, do: @iflag_sysid32, else: 0) |||
        if(target32?, do: @iflag_target32, else: 0)

    sysid = if sysid32?, do: <<f.sysid::little-32>>, else: <<f.sysid>>
    target = if target32?, do: <<f.target_sysid::little-32>>, else: <<>>

    <<len, incompat, f.compat_flags, f.seq, sysid::binary, f.compid, f.msgid::little-24,
      target::binary>>
  end

  @limits [
    seq: 255,
    compid: 255,
    incompat_flags: 255,
    compat_flags: 255,
    sysid: @u32,
    msgid: 0xFFFFFF
  ]

  defp check_header(f) do
    bad =
      Enum.find_value(@limits, fn {field, max} ->
        v = Map.fetch!(f, field)
        if not (is_integer(v) and v >= 0 and v <= max), do: field
      end)

    cond do
      bad ->
        {:error, {:out_of_range, bad}}

      f.target_sysid != nil and not (is_integer(f.target_sysid) and f.target_sysid in 0..@u32) ->
        {:error, {:out_of_range, :target_sysid}}

      f.incompat_flags > @iflags_known ->
        {:error, {:unsupported_incompat_flags, f.incompat_flags}}

      true ->
        :ok
    end
  end

  defp fetch_crc_extra(dialect, msgid) do
    case dialect.crc_extra(msgid) do
      nil -> {:error, {:unknown_msgid, msgid}}
      crc_extra -> {:ok, crc_extra}
    end
  end

  defp check_length(payload, max) when byte_size(payload) <= max, do: :ok
  defp check_length(_payload, _max), do: {:error, :payload_too_long}

  @doc """
  Decode the first complete frame in `bin`.

    * `{:ok, frame, rest}`
    * `{:incomplete, bin}`: more bytes needed; keep `bin`
    * `{:error, reason, rest}`: resynchronise from `rest`

  Option `unknown:` is `:skip` (the default) or `:keep`, for an id the
  dialect lacks.

  Errors:

  | | Resumes |
  | --- | --- |
  | `:no_stx` | at the next STX, so a run of junk is one error |
  | `:mavlink_v1_unsupported` | after the v1 STX |
  | `{:unsupported_incompat_flags, flags}` | after the STX, as soon as the flags byte has arrived: an unknown flag may change the layout |
  | `{:unknown_msgid, id}` | with `unknown: :skip`, after the STX as soon as the header has arrived: without the message's `crc_extra` the frame cannot be checked, so its length byte cannot be trusted |
  | `:bad_checksum` | after the STX, since the length byte itself may be the corruption |

  With `unknown: :keep`, a frame with an unknown id is returned with
  `known: false` once all of it has arrived, and decoding resumes after it.
  Noise that starts with an STX then costs up to a frame's length of the
  bytes after it, as in the C library and pymavlink.
  """
  @spec decode(binary(), module(), keyword()) ::
          {:ok, t(), binary()} | {:incomplete, binary()} | {:error, term(), binary()}
  def decode(bin, dialect, opts \\ [])
  def decode(<<>>, _dialect, _opts), do: {:incomplete, <<>>}

  def decode(<<@stx_v2, rest::binary>> = bin, dialect, opts),
    do: decode_v2(bin, rest, dialect, unknown!(opts))

  def decode(<<@stx_v1, rest::binary>>, _dialect, _opts),
    do: {:error, :mavlink_v1_unsupported, rest}

  def decode(bin, _dialect, _opts) do
    case :binary.match(bin, [<<@stx_v2>>, <<@stx_v1>>]) do
      {at, 1} -> {:error, :no_stx, binary_part(bin, at, byte_size(bin) - at)}
      :nomatch -> {:error, :no_stx, <<>>}
    end
  end

  defp decode_v2(_bin, <<_len, incompat, _::binary>> = rest, _dialect, _unknown)
       when incompat > @iflags_known,
       do: {:error, {:unsupported_incompat_flags, incompat}, rest}

  defp decode_v2(bin, rest, dialect, unknown) do
    case parse_header(rest) do
      :incomplete ->
        {:incomplete, bin}

      {h, size} ->
        case {dialect.crc_extra(h.msgid), unknown} do
          {nil, :skip} -> {:error, {:unknown_msgid, h.msgid}, rest}
          {crc_extra, _} -> decode_body(bin, rest, h, size, crc_extra, dialect)
        end
    end
  end

  defp parse_header(<<len, incompat, compat, seq, sysid0, rest::binary>>) do
    sys_bits = if (incompat &&& @iflag_sysid32) != 0, do: 24, else: 0
    target_bits = if (incompat &&& @iflag_target32) != 0, do: 32, else: 0

    case rest do
      <<sysid_hi::little-size(^sys_bits), compid, msgid::little-24,
        target::little-size(^target_bits), _::binary>> ->
        header = %{
          len: len,
          incompat: incompat,
          compat: compat,
          seq: seq,
          sysid: sysid0 + (sysid_hi <<< 8),
          compid: compid,
          msgid: msgid,
          target_sysid: if(target_bits > 0, do: target)
        }

        {header, @base_header + div(sys_bits + target_bits, 8)}

      _ ->
        :incomplete
    end
  end

  defp parse_header(_rest), do: :incomplete

  defp decode_body(bin, rest, h, size, crc_extra, dialect) do
    len = h.len
    sig_len = if (h.incompat &&& @iflag_signed) != 0, do: @signature_bytes, else: 0

    case rest do
      <<header::binary-size(^size), payload::binary-size(^len), crc::little-16,
        sig_block::binary-size(^sig_len), tail::binary>> ->
        cond do
          crc_extra != nil and CRC.checksum(header <> payload, crc_extra) != crc ->
            {:error, :bad_checksum, rest}

          true ->
            frame_len = 1 + size + len + 2 + sig_len

            frame = %__MODULE__{
              msgid: h.msgid,
              payload: zero_extend(payload, crc_extra && dialect.payload_length(h.msgid)),
              seq: h.seq,
              sysid: h.sysid,
              compid: h.compid,
              incompat_flags: h.incompat,
              compat_flags: h.compat,
              target_sysid: h.target_sysid,
              signature: signature(sig_block, bin, frame_len),
              raw: binary_part(bin, 0, frame_len),
              known: crc_extra != nil
            }

            {:ok, frame, tail}
        end

      _ ->
        {:incomplete, bin}
    end
  end

  defp signature(<<>>, _bin, _frame_len), do: nil

  # The signed bytes run from STX through the signature's link id and
  # timestamp: all but its last 6 bytes.
  defp signature(<<link_id, ts::little-48, sig::binary-size(6)>>, bin, frame_len),
    do: {link_id, ts, sig, binary_part(bin, 0, frame_len - 6)}

  @doc """
  Every complete frame in `bin`, as `{frames, errors, rest}`. Errors are
  collected, so a noisy line degrades instead of failing. Takes `decode/3`'s
  options.
  """
  @spec drain(binary(), module(), keyword()) :: {[t()], [term()], binary()}
  def drain(bin, dialect, opts \\ []) do
    unknown!(opts)
    drain(bin, dialect, opts, [], [])
  end

  defp unknown!([]), do: :skip
  defp unknown!(unknown: mode) when mode in [:skip, :keep], do: mode

  defp unknown!(opts),
    do:
      MAVLink2.Options.validate!(
        opts,
        [unknown: {:in, [:skip, :keep]}],
        "MAVLink2.Frame.decode/3"
      )
      |> Keyword.get(:unknown, :skip)

  defp drain(bin, dialect, opts, frames, errors) do
    case decode(bin, dialect, opts) do
      {:ok, frame, rest} -> drain(rest, dialect, opts, [frame | frames], errors)
      {:incomplete, rest} -> {Enum.reverse(frames), Enum.reverse(errors), rest}
      {:error, reason, rest} -> drain(rest, dialect, opts, frames, [reason | errors])
    end
  end

  defp truncate(payload) do
    case trim_trailing_zeros(payload) do
      <<>> -> <<0>>
      trimmed -> trimmed
    end
  end

  defp trim_trailing_zeros(<<>>), do: <<>>

  defp trim_trailing_zeros(bin) do
    head_size = byte_size(bin) - 1

    case bin do
      <<head::binary-size(^head_size), 0>> -> trim_trailing_zeros(head)
      _ -> bin
    end
  end

  defp zero_extend(payload, nil), do: payload
  defp zero_extend(payload, len) when byte_size(payload) >= len, do: binary_part(payload, 0, len)
  defp zero_extend(payload, len), do: payload <> :binary.copy(<<0>>, len - byte_size(payload))
end
