defmodule MAVLink2.CRC do
  @moduledoc """
  MAVLink's checksum: CRC-16/MCRF4XX, also called the X.25 CRC, as
  MAVLink's `crc_accumulate` computes it (seed `0xFFFF`).
  """

  import Bitwise

  @seed 0xFFFF

  @doc "The initial accumulator value, `0xFFFF`."
  @spec seed() :: 0..0xFFFF
  def seed, do: @seed

  @doc """
  Fold one byte into `crc`.

  Separate from `accumulate_bytes/2` because a frame's checksum runs over
  the header and payload and then over the message's `crc_extra`, which is
  not contiguous with either.
  """
  @spec accumulate(0..0xFFFF, 0..255) :: 0..0xFFFF
  def accumulate(crc, byte) when is_integer(crc) and is_integer(byte) do
    tmp = bxor(byte, crc &&& 0xFF)
    tmp = bxor(tmp, tmp <<< 4) &&& 0xFF

    bxor(
      bxor(crc >>> 8, tmp <<< 8),
      bxor(tmp <<< 3, tmp >>> 4)
    ) &&& 0xFFFF
  end

  @doc "Fold every byte of `bin` into `crc`."
  @spec accumulate_bytes(0..0xFFFF, binary()) :: 0..0xFFFF
  def accumulate_bytes(crc, bin) when is_binary(bin) do
    for <<byte <- bin>>, reduce: crc, do: (acc -> accumulate(acc, byte))
  end

  @doc """
  The frame checksum over `bin`, finished with `crc_extra`.

  `crc_extra` is the per-message byte from the dialect: two peers with
  different definitions of a message fail the checksum instead of misreading
  its fields.
  """
  @spec checksum(binary(), 0..255) :: 0..0xFFFF
  def checksum(bin, crc_extra) when is_binary(bin) and is_integer(crc_extra) do
    @seed
    |> accumulate_bytes(bin)
    |> accumulate(crc_extra)
  end
end
