defmodule MAVLink2.SigningTest do
  use ExUnit.Case, async: true

  alias MAVLink2.{Frame, Signing, TestDialect}

  @d TestDialect
  @key :binary.list_to_bin(Enum.to_list(0..31))
  @t0 0x123456789A

  # pymavlink 2.4 (common.xml), srcSystem 255, srcComponent 0, secret_key
  # bytes 0..31, link_id 5, signing.timestamp 0x123456789A.
  @heartbeat Base.decode16!(
               "FD09010000FF0000000000000000060800040362A4059A7856341200D69285B04F59"
             )
  @command_long Base.decode16!(
                  "FD20010000FF004C00000000803F00000000000000000000000000000000000000000000000090010101F672059B78563412008E3ECA2F33A7"
                )

  defp heartbeat, do: %Frame{msgid: 0, payload: <<0::32, 6, 8, 0, 4, 3>>, sysid: 255, compid: 0}

  defp command_long do
    payload = <<1.0::float-32-little, 0::size(6 * 32), 400::16-little, 1, 1, 0>>
    %Frame{msgid: 76, payload: payload, sysid: 255, compid: 0}
  end

  test "signs as pymavlink does, the timestamp moving on per frame" do
    s = Signing.new(@key, link_id: 5)
    assert {:ok, @heartbeat, s} = Signing.encode(s, heartbeat(), @d, @t0)
    assert {:ok, @command_long, s} = Signing.encode(s, command_long(), @d, @t0)
    assert s.timestamp == @t0 + 1
  end

  test "pymavlink's signed frames decode and verify; a second time is a replay" do
    assert {:ok, %Frame{signature: {5, @t0, _, _}} = hb, <<>>} = Frame.decode(@heartbeat, @d)
    assert {:ok, %Frame{signature: {5, t1, _, _}} = cl, <<>>} = Frame.decode(@command_long, @d)
    assert t1 == @t0 + 1

    s = Signing.new(@key)
    assert {:ok, s} = Signing.verify(s, hb, 0)
    assert {:ok, s} = Signing.verify(s, cl, 0)
    assert s.timestamp == t1
    assert Signing.verify(s, hb, 0) == {:error, :replay}
    assert Signing.verify(s, cl, 0) == {:error, :replay}
  end

  test "a wrong key or a changed signature fails, and moves nothing" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    other = Signing.new(:binary.copy(<<7>>, 32))
    assert Signing.verify(other, frame, 0) == {:error, :bad_signature}

    n = byte_size(@heartbeat) - 1
    <<head::binary-size(^n), last>> = @heartbeat
    {:ok, forged, <<>>} = Frame.decode(<<head::binary, Bitwise.bxor(last, 1)>>, @d)
    s = Signing.new(@key)
    assert Signing.verify(s, forged, 0) == {:error, :bad_signature}
    assert {:ok, _} = Signing.verify(s, frame, 0)
  end

  test "a signed frame's checksum still covers it" do
    <<a::binary-size(14), b, rest::binary>> = @heartbeat

    assert {:error, :bad_checksum, _} =
             Frame.decode(<<a::binary, Bitwise.bxor(b, 1), rest::binary>>, @d)
  end

  test "unsigned frames are refused unless their id is accepted unsigned" do
    {:ok, wire} = Frame.encode(heartbeat(), @d)
    {:ok, frame, <<>>} = Frame.decode(wire, @d)
    assert frame.signature == nil
    assert Signing.verify(Signing.new(@key), frame, 0) == {:error, :unsigned}
    assert {:ok, _} = Signing.verify(Signing.new(@key, accept_unsigned: [0]), frame, 0)
  end

  test "a new stream more than a minute behind is refused" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    ahead = %{Signing.new(@key) | timestamp: @t0 + 6_000_001}
    assert Signing.verify(ahead, frame, 0) == {:error, :replay}
    assert {:ok, _} = Signing.verify(%{ahead | timestamp: @t0 + 6_000_000}, frame, 0)
  end

  test "a new stream more than a minute behind the clock is refused" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    assert Signing.verify(Signing.new(@key), frame, @t0 + 6_000_001) == {:error, :replay}
    assert {:ok, s} = Signing.verify(Signing.new(@key), frame, @t0 + 6_000_000)
    assert s.timestamp == @t0 + 6_000_000
  end

  test "a frame this end signed, reflected back, is a replay" do
    s = Signing.new(@key, link_id: 5)
    {:ok, wire, s} = Signing.encode(s, heartbeat(), @d, @t0)
    {:ok, frame, <<>>} = Frame.decode(wire, @d)
    assert Signing.verify(s, frame, @t0) == {:error, :replay}
    assert {:ok, _} = Signing.verify(Signing.new(@key), frame, @t0)
  end

  test "a signature covers the extended header" do
    frame = %Frame{msgid: 300, payload: <<1, 2, 3, 4>>, sysid: 70_000, target_sysid: 100_000}
    {:ok, wire, s} = Signing.encode(Signing.new(@key), frame, @d, @t0)
    assert {:ok, decoded, <<>>} = Frame.decode(wire, @d)
    assert {:ok, _} = Signing.verify(Signing.new(@key), decoded, @t0)
    assert Signing.verify(s, decoded, @t0) == {:error, :replay}

    # The target's high byte, changed with the checksum fixed up, fails the
    # signature.
    <<head::binary-size(16), hi, rest::binary>> = wire
    tampered = <<head::binary, Bitwise.bxor(hi, 1), rest::binary>>
    n = byte_size(tampered) - 13 - 2
    <<covered::binary-size(^n), _crc::16, sig::binary>> = tampered
    <<_stx, crc_input::binary>> = covered
    crc = MAVLink2.CRC.checksum(crc_input, @d.crc_extra(300))
    {:ok, forged, <<>>} = Frame.decode(<<covered::binary, crc::little-16, sig::binary>>, @d)
    assert forged.target_sysid != 100_000
    assert Signing.verify(Signing.new(@key), forged, @t0) == {:error, :bad_signature}
  end

  test "a persisted timestamp is where a new state starts" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    s = Signing.new(@key, timestamp: @t0 + 6_000_001)
    assert Signing.verify(s, frame, 0) == {:error, :replay}
  end

  test "timestamps never repeat when the clock steps back" do
    s = Signing.new(@key)
    {:ok, _, s} = Signing.encode(s, heartbeat(), @d, 1_000)
    {:ok, _, s} = Signing.encode(s, heartbeat(), @d, 10)
    {:ok, wire, s} = Signing.encode(s, heartbeat(), @d, 10)
    assert s.timestamp == 1_002
    assert {:ok, %Frame{signature: {0, 1_002, _, _}}, <<>>} = Frame.decode(wire, @d)
  end

  test "timestamps count 10 µs from 2015-01-01" do
    assert Signing.timestamp(1_420_070_400_000_000) == 0
    assert Signing.timestamp(1_420_070_401_000_000) == 100_000
  end
end
