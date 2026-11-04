defmodule MAVLink2.FrameTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MAVLink2.{Frame, TestDialect}

  @d TestDialect

  # pymavlink 2.4 (common.xml), srcSystem 255, srcComponent 0.
  @heartbeat Base.decode16!("FD09000000FF00000000000000000608000403855C")
  @command_long Base.decode16!(
                  "FD20000000FF004C00000000803F0000000000000000000000000000000000000000000000009001010121EC"
                )

  test "frames as pymavlink encodes them" do
    heartbeat = %Frame{msgid: 0, payload: <<0::32, 6, 8, 0, 4, 3>>, sysid: 255, compid: 0}
    assert Frame.encode(heartbeat, @d) == {:ok, @heartbeat}
    assert Frame.decode(@heartbeat, @d) == {:ok, %{heartbeat | raw: @heartbeat}, <<>>}

    # COMMAND_LONG 400 with param1 = 1.0; its trailing zero byte is truncated.
    payload = <<1.0::float-32-little, 0::size(6 * 32), 400::16-little, 1, 1, 0>>
    command = %Frame{msgid: 76, payload: payload, sysid: 255, compid: 0}
    assert Frame.encode(command, @d) == {:ok, @command_long}
    assert Frame.decode(@command_long, @d) == {:ok, %{command | raw: @command_long}, <<>>}
  end

  test "every message round-trips" do
    for msgid <- TestDialect.msgids() do
      payload = :binary.copy(<<0xAB>>, TestDialect.payload_length(msgid))
      frame = %Frame{msgid: msgid, payload: payload, seq: 7, sysid: 1, compid: 2}
      assert {:ok, wire} = Frame.encode(frame, @d)
      assert Frame.decode(wire, @d) == {:ok, %{frame | raw: wire}, <<>>}
    end
  end

  test "trailing zeros are dropped on the wire and restored on receipt" do
    payload = <<1, 0, 0, 0>>
    assert {:ok, wire} = Frame.encode(%Frame{msgid: 300, payload: payload}, @d)
    assert byte_size(wire) == 1 + 9 + 1 + 2
    assert {:ok, %Frame{payload: ^payload}, <<>>} = Frame.decode(wire, @d)

    assert {:ok, wire} = Frame.encode(%Frame{msgid: 300, payload: <<0, 0, 0, 0>>}, @d)
    assert {:ok, %Frame{payload: <<0, 0, 0, 0>>}, <<>>} = Frame.decode(wire, @d)
  end

  test "an id the dialect lacks is refused" do
    assert Frame.encode(%Frame{msgid: 4242, payload: <<1>>}, @d) ==
             {:error, {:unknown_msgid, 4242}}
  end

  test "a partial frame is incomplete and kept" do
    {:ok, wire} = Frame.encode(%Frame{msgid: 300, payload: <<1, 2, 3, 4>>}, @d)
    partial = binary_part(wire, 0, byte_size(wire) - 1)
    assert Frame.decode(partial, @d) == {:incomplete, partial}
  end

  test "a bad checksum resumes after the rejected STX" do
    {:ok, wire} = Frame.encode(%Frame{msgid: 300, payload: <<1, 2, 3, 4>>}, @d)
    n = byte_size(wire) - 1
    <<head::binary-size(^n), last>> = wire

    assert {:error, :bad_checksum, rest} =
             Frame.decode(<<head::binary, bxor(last, 0xFF)>>, @d)

    assert byte_size(rest) == byte_size(wire) - 1
  end

  test "drain skips junk, collects frames and keeps the trailing partial" do
    {:ok, a} = Frame.encode(%Frame{msgid: 300, payload: <<9, 9, 9, 9>>}, @d)
    {:ok, b} = Frame.encode(%Frame{msgid: 0, payload: :binary.copy(<<2>>, 9)}, @d)
    partial = binary_part(a, 0, 4)

    assert {[%Frame{msgid: 300}, %Frame{msgid: 0}], [:no_stx, :no_stx], ^partial} =
             Frame.drain(<<0x00, 0x11>> <> a <> <<0x22>> <> b <> partial, @d)
  end

  test "an STX with an unknown id resumes after the STX, not after its length" do
    {:ok, a} = Frame.encode(%Frame{msgid: 300, payload: <<9, 9, 9, 9>>}, @d)
    noise = <<0xFD, 0x40, 0, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE>>

    assert {[%Frame{}, %Frame{}, %Frame{}], [{:unknown_msgid, 0xEEEEEE}, :no_stx], <<>>} =
             Frame.drain(noise <> a <> a <> a, @d)
  end

  test "an unknown id is refused as soon as the header arrives" do
    assert {:error, {:unknown_msgid, 0xEEEEEE}, _} =
             Frame.decode(<<0xFD, 0xFF, 0, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE>>, @d)
  end

  test "an unknown incompat flag is refused as soon as it arrives" do
    assert Frame.decode(<<0xFD, 4, 0x08>>, @d) ==
             {:error, {:unsupported_incompat_flags, 0x08}, <<4, 0x08>>}

    assert Frame.encode(%Frame{msgid: 300, payload: <<1>>, incompat_flags: 0x08}, @d) ==
             {:error, {:unsupported_incompat_flags, 0x08}}
  end

  # Built by hand from the C library's layout: the 3 high sysid bytes after
  # the first, the 4-byte target after msgid, all covered by the checksum.
  defp wide(sysid, target, payload, msgid \\ 300) do
    flags = if(sysid > 255, do: 0x02, else: 0) ||| if(target, do: 0x04, else: 0)
    sys = if sysid > 255, do: <<sysid::little-32>>, else: <<sysid>>
    tgt = if target, do: <<target::little-32>>, else: <<>>
    header = <<byte_size(payload), flags, 0, 0>> <> sys <> <<2, msgid::little-24>> <> tgt
    crc = MAVLink2.CRC.checksum(header <> payload, TestDialect.crc_extra(msgid))
    <<0xFD>> <> header <> payload <> <<crc::little-16>>
  end

  test "a 32-bit sysid and a header target, each and both" do
    for {sysid, target} <- [{70_000, nil}, {9, 100_000}, {70_000, 100_000}, {9, 0}] do
      wire = wide(sysid, target, <<1, 2, 3, 4>>)

      frame = %Frame{
        msgid: 300,
        payload: <<1, 2, 3, 4>>,
        sysid: sysid,
        compid: 2,
        target_sysid: target
      }

      assert Frame.encode(frame, @d) == {:ok, wire}
      assert {:ok, decoded, "x"} = Frame.decode(wire <> "x", @d)
      assert %{sysid: ^sysid, compid: 2, target_sysid: ^target, raw: ^wire} = decoded
    end
  end

  test "a SYSID32 frame with a small sysid keeps its 4-byte sysid" do
    frame = %Frame{msgid: 300, payload: <<1>>, sysid: 5, incompat_flags: 0x02}
    {:ok, wire} = Frame.encode(frame, @d)
    assert byte_size(wire) == 1 + 9 + 3 + 1 + 2
    assert {:ok, %{sysid: 5, incompat_flags: 0x02}, <<>>} = Frame.decode(wire, @d)
  end

  test "an extended header waits until all of it has arrived" do
    wire = wide(70_000, 100_000, <<1, 2, 3, 4>>)

    for n <- 1..(byte_size(wire) - 1) do
      part = binary_part(wire, 0, n)
      assert Frame.decode(part, @d) == {:incomplete, part}
    end
  end

  test "with unknown: :keep, an unknown id is returned unchecked, whole" do
    {:ok, a} = Frame.encode(%Frame{msgid: 300, payload: <<9, 9, 9, 9>>}, @d)
    unknown = <<0xFD, 3, 0, 0, 7, 70, 80, 0x39, 0x30, 0, 1, 2, 3, 0xAA, 0xBB>>

    assert {[%Frame{known: false} = u, %Frame{known: true}], [], <<>>} =
             Frame.drain(unknown <> a, @d, unknown: :keep)

    assert %{msgid: 0x3039, sysid: 70, compid: 80, payload: <<1, 2, 3>>, raw: ^unknown} = u
  end

  test "fields that do not fit are refused, not wrapped" do
    frame = %Frame{msgid: 300, payload: <<1>>}
    assert Frame.encode(%{frame | sysid: 1 <<< 32}, @d) == {:error, {:out_of_range, :sysid}}
    assert Frame.encode(%{frame | compid: 256}, @d) == {:error, {:out_of_range, :compid}}

    assert Frame.encode(%{frame | target_sysid: -1}, @d) ==
             {:error, {:out_of_range, :target_sysid}}

    assert Frame.encode(%{frame | seq: -1}, @d) == {:error, {:out_of_range, :seq}}
    assert Frame.encode(%{frame | msgid: 1 <<< 24}, @d) == {:error, {:out_of_range, :msgid}}
    assert Frame.encode(%{frame | payload: <<1, 2, 3, 4, 5>>}, @d) == {:error, :payload_too_long}
    assert {:ok, _} = Frame.encode(%{frame | payload: <<1, 2, 3, 4, 0, 0>>}, @d)
  end

  test "v1 frames are refused" do
    assert {:error, :mavlink_v1_unsupported, _} = Frame.decode(<<0xFE, 4, 0, 0, 0>>, @d)
  end

  test "a signed frame waits for its signature, then decodes with it" do
    {:ok, wire} = Frame.encode(%Frame{msgid: 300, payload: <<1, 2, 3, 4>>, incompat_flags: 1}, @d)
    signed = wire <> <<9, 1::little-48, "abcdef">>
    assert Frame.decode(wire, @d) == {:incomplete, wire}

    assert {:ok, %Frame{signature: {9, 1, "abcdef", covered}}, "x"} =
             Frame.decode(signed <> "x", @d)

    assert covered == binary_part(signed, 0, byte_size(signed) - 6)
  end
end
