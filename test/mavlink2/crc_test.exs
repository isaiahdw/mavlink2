defmodule MAVLink2.CRCTest do
  use ExUnit.Case, async: true

  alias MAVLink2.CRC

  test "the CRC-16/MCRF4XX check value" do
    assert CRC.accumulate_bytes(CRC.seed(), "123456789") == 0x6F91
  end

  test "order matters and crc_extra changes the result" do
    refute CRC.accumulate_bytes(CRC.seed(), <<1, 2, 3>>) ==
             CRC.accumulate_bytes(CRC.seed(), <<3, 2, 1>>)

    refute CRC.checksum(<<1, 2, 3>>, 0) == CRC.checksum(<<1, 2, 3>>, 1)
  end

  test "stays inside 16 bits for every byte value" do
    for b <- 0..255, seed <- [0x0000, 0xFFFF], do: assert(CRC.accumulate(seed, b) in 0..0xFFFF)
  end
end
