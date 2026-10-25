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
    assert {:ok, s} = Signing.verify(s, hb)
    assert {:ok, s} = Signing.verify(s, cl)
    assert s.timestamp == t1
    assert Signing.verify(s, hb) == {:error, :replay}
    assert Signing.verify(s, cl) == {:error, :replay}
  end

  test "a wrong key or a changed signature fails, and moves nothing" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    other = Signing.new(:binary.copy(<<7>>, 32))
    assert Signing.verify(other, frame) == {:error, :bad_signature}

    n = byte_size(@heartbeat) - 1
    <<head::binary-size(^n), last>> = @heartbeat
    {:ok, forged, <<>>} = Frame.decode(<<head::binary, Bitwise.bxor(last, 1)>>, @d)
    s = Signing.new(@key)
    assert Signing.verify(s, forged) == {:error, :bad_signature}
    assert {:ok, _} = Signing.verify(s, frame)
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
    assert Signing.verify(Signing.new(@key), frame) == {:error, :unsigned}
    assert {:ok, _} = Signing.verify(Signing.new(@key, accept_unsigned: [0]), frame)
  end

  test "a new stream more than a minute behind is refused" do
    {:ok, frame, <<>>} = Frame.decode(@heartbeat, @d)
    ahead = %{Signing.new(@key) | timestamp: @t0 + 6_000_001}
    assert Signing.verify(ahead, frame) == {:error, :replay}
    assert {:ok, _} = Signing.verify(%{ahead | timestamp: @t0 + 6_000_000}, frame)
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
