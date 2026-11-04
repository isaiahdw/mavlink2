defmodule MAVLink2.Frame do
  @moduledoc """
  MAVLink v2 frame encoding and decoding, for a `MAVLink2.Dialect`.

  Wire layout:

      0     STX            0xFD  (v2); 0xFE (v1) is refused on receive
      1     len            payload length after truncation
      2     incompat_flags
      3     compat_flags
      4     seq
      5     sysid
      6     compid
      7..9  msgid          24-bit, little endian
      10..  payload
      last  checksum       16-bit LE, over bytes 1..end-of-payload plus crc_extra

  ## Payload truncation

  v2 drops trailing zero bytes from the payload on the wire, keeping at
  least one, and the receiver zero-extends it back to the message's length.
  A receiver that does not zero-extend misreads every short frame.

  ## Signing

  `incompat_flags` bit 0 (`MAVLINK_IFLAG_SIGNED`) adds a 13-byte signature
  after the checksum. A signed frame decodes with `signature` set to
  `{link_id, timestamp, signature, signed_bytes}`; checking it is
  `MAVLink2.Signing.verify/3`. `MAVLink2.Signing.encode/4` sends one.
  """

  import Bitwise

  alias MAVLink2.CRC

  @stx_v2 0xFD
  @stx_v1 0xFE
  # The header after STX: len, the two flags, seq, sysid, compid, msgid.
  # The checksum also starts after STX.
  @header_after_stx 9
  @iflag_signed 0x01
  @signature_bytes 13

  defstruct [
    :msgid,
    :payload,
    seq: 0,
    sysid: 1,
    compid: 1,
    incompat_flags: 0,
    compat_flags: 0,
    signature: nil
  ]

  @type t :: %__MODULE__{
          msgid: non_neg_integer(),
          payload: binary(),
          seq: 0..255,
          sysid: 0..255,
          compid: 0..255,
          incompat_flags: 0..255,
          compat_flags: 0..255,
          signature:
            nil | {link_id :: 0..255, timestamp :: non_neg_integer(), <<_::48>>, binary()}
        }

  def stx_v2, do: @stx_v2
  def stx_v1, do: @stx_v1

  @doc """
  Encode a frame to wire bytes.

  Errors:

  | | |
  | --- | --- |
  | `{:unknown_msgid, id}` | the dialect does not have `id`: a guessed `crc_extra` makes a frame the peer drops without a word |
  | `{:out_of_range, field}` | `seq`, `sysid`, `compid` or a flags byte outside 0..255, or `msgid` outside 24 bits |
  | `:payload_too_long` | the payload, after truncation, is longer than the message |
  """
  @spec encode(t(), module()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = f, dialect) do
    with :ok <- check_header(f),
         {:ok, crc_extra} <- fetch_crc_extra(dialect, f.msgid),
         payload = truncate(f.payload),
         :ok <- check_length(payload, dialect.payload_length(f.msgid)) do
      len = byte_size(payload)

      header = <<
        len,
        f.incompat_flags,
        f.compat_flags,
        f.seq,
        f.sysid,
        f.compid,
        f.msgid::little-size(24)
      >>

      crc = CRC.checksum(header <> payload, crc_extra)
      {:ok, <<@stx_v2, header::binary, payload::binary, crc::little-16>>}
    end
  end

  @bytes [:seq, :sysid, :compid, :incompat_flags, :compat_flags]

  defp check_header(f) do
    bad =
      Enum.find(@bytes, &(not (is_integer(Map.fetch!(f, &1)) and Map.fetch!(f, &1) in 0..255)))

    cond do
      bad -> {:error, {:out_of_range, bad}}
      not (is_integer(f.msgid) and f.msgid in 0..0xFFFFFF) -> {:error, {:out_of_range, :msgid}}
      true -> :ok
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

  Errors:

  | | Resumes |
  | --- | --- |
  | `:no_stx` | at the next STX, so a run of junk is one error |
  | `:mavlink_v1_unsupported` | after the v1 STX |
  | `{:unknown_msgid, id}` | after the STX, as soon as the header has arrived: without the message's `crc_extra` the frame cannot be checked, so its length byte cannot be trusted |
  | `:bad_checksum` | after the STX, since the length byte itself may be the corruption |
  | `{:unsupported_incompat_flags, flags}` | after the frame: a flag other than signing may change the layout |
  """
  @spec decode(binary(), module()) ::
          {:ok, t(), binary()} | {:incomplete, binary()} | {:error, term(), binary()}
  def decode(<<>>, _dialect), do: {:incomplete, <<>>}
  def decode(<<@stx_v2, rest::binary>> = bin, dialect), do: decode_v2(bin, rest, dialect)
  def decode(<<@stx_v1, rest::binary>>, _dialect), do: {:error, :mavlink_v1_unsupported, rest}

  def decode(bin, _dialect) do
    case :binary.match(bin, [<<@stx_v2>>, <<@stx_v1>>]) do
      {at, 1} -> {:error, :no_stx, binary_part(bin, at, byte_size(bin) - at)}
      :nomatch -> {:error, :no_stx, <<>>}
    end
  end

  defp decode_v2(
         bin,
         <<_len, _flags::16, _seq, _sysid, _compid, msgid::little-24, _::binary>> = rest,
         dialect
       ) do
    case dialect.crc_extra(msgid) do
      nil -> {:error, {:unknown_msgid, msgid}, rest}
      crc_extra -> decode_v2(bin, rest, crc_extra, dialect)
    end
  end

  defp decode_v2(bin, _rest, _dialect), do: {:incomplete, bin}

  defp decode_v2(bin, <<len, incompat, _::binary>> = rest, crc_extra, dialect) do
    sig_len = if (incompat &&& @iflag_signed) != 0, do: @signature_bytes, else: 0

    case rest do
      <<header::binary-size(@header_after_stx), payload::binary-size(^len), crc::little-16,
        sig_block::binary-size(^sig_len), tail::binary>> ->
        <<_len, incompat, compat, seq, sysid, compid, msgid::little-size(24)>> = header

        cond do
          CRC.checksum(header <> payload, crc_extra) != crc ->
            {:error, :bad_checksum, rest}

          (incompat &&& bnot(@iflag_signed)) != 0 ->
            {:error, {:unsupported_incompat_flags, incompat}, tail}

          true ->
            frame = %__MODULE__{
              msgid: msgid,
              payload: zero_extend(payload, dialect.payload_length(msgid)),
              seq: seq,
              sysid: sysid,
              compid: compid,
              incompat_flags: incompat,
              compat_flags: compat,
              signature: signature(sig_block, bin, len)
            }

            {:ok, frame, tail}
        end

      _ ->
        {:incomplete, bin}
    end
  end

  defp signature(<<>>, _bin, _len), do: nil

  defp signature(<<link_id, ts::little-48, sig::binary-size(6)>>, bin, len),
    do: {link_id, ts, sig, binary_part(bin, 0, 1 + @header_after_stx + len + 2 + 7)}

  @doc """
  Every complete frame in `bin`, as `{frames, errors, rest}`. Errors are
  collected, so a noisy line degrades instead of failing.
  """
  @spec drain(binary(), module()) :: {[t()], [term()], binary()}
  def drain(bin, dialect), do: drain(bin, dialect, [], [])

  defp drain(bin, dialect, frames, errors) do
    case decode(bin, dialect) do
      {:ok, frame, rest} -> drain(rest, dialect, [frame | frames], errors)
      {:incomplete, rest} -> {Enum.reverse(frames), Enum.reverse(errors), rest}
      {:error, reason, rest} -> drain(rest, dialect, frames, [reason | errors])
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
