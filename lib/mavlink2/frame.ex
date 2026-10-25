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
  `MAVLink2.Signing.verify/2`. `MAVLink2.Signing.encode/4` sends one.
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

  An id the dialect does not have is `{:error, {:unknown_msgid, id}}`: a
  guessed `crc_extra` makes a frame the peer drops without a word.
  """
  @spec encode(t(), module()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = f, dialect) do
    case dialect.crc_extra(f.msgid) do
      nil ->
        {:error, {:unknown_msgid, f.msgid}}

      crc_extra ->
        payload = truncate(f.payload)
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

  @doc """
  Decode the first complete frame in `bin`.

    * `{:ok, frame, rest}`
    * `{:incomplete, bin}`: more bytes needed; keep `bin`
    * `{:error, reason, rest}`: resynchronise from `rest`

  A bad checksum resumes after the rejected STX, since the length byte
  itself may be the corruption.
  """
  @spec decode(binary(), module()) ::
          {:ok, t(), binary()} | {:incomplete, binary()} | {:error, term(), binary()}
  def decode(<<>>, _dialect), do: {:incomplete, <<>>}
  def decode(<<@stx_v2, rest::binary>> = bin, dialect), do: decode_v2(bin, rest, dialect)
  def decode(<<@stx_v1, rest::binary>>, _dialect), do: {:error, :mavlink_v1_unsupported, rest}
  def decode(<<_junk, rest::binary>>, _dialect), do: {:error, :no_stx, rest}

  defp decode_v2(bin, <<len, incompat, _::binary>> = rest, dialect) do
    sig_len = if (incompat &&& @iflag_signed) != 0, do: @signature_bytes, else: 0
    need = @header_after_stx + len + 2 + sig_len

    case rest do
      <<header::binary-size(@header_after_stx), payload::binary-size(^len), crc::little-16,
        sig_block::binary-size(^sig_len), tail::binary>> ->
        <<_len, incompat, compat, seq, sysid, compid, msgid::little-size(24)>> = header

        case dialect.crc_extra(msgid) do
          nil ->
            {:error, {:unknown_msgid, msgid}, tail}

          crc_extra ->
            if CRC.checksum(header <> payload, crc_extra) == crc do
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
            else
              <<_stx, after_stx::binary>> = bin
              {:error, :bad_checksum, after_stx}
            end
        end

      _ when byte_size(rest) < need ->
        {:incomplete, bin}
    end
  end

  defp decode_v2(bin, _rest, _dialect), do: {:incomplete, bin}

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
