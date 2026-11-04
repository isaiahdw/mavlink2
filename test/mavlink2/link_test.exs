defmodule MAVLink2.LinkTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Frame, Link, TestDialect}
  alias MAVLink2.Transport.Loopback

  defp link(opts) do
    start_supervised!({Link, [dialect: TestDialect, transport: Loopback] ++ opts})
  end

  test "frames written come back decoded to subscribers, numbered" do
    link = link(echo: true, sysid: 9)
    :ok = Link.subscribe(link)

    assert :ok = Link.send_message(link, 300, <<1, 2, 3, 4>>)
    assert :ok = Link.send_message(link, 300, <<5, 6, 7, 8>>)

    assert_receive {Link, ^link, %Frame{msgid: 300, payload: <<1, 2, 3, 4>>, seq: 0, sysid: 9}}
    assert_receive {Link, ^link, %Frame{seq: 1}}
    assert %{tx: 2, rx: 2, errors: 0, dropped: 0} = Link.stats(link)
  end

  test "ids outside :sendable are refused" do
    link = link(sendable: [0])
    assert Link.send_message(link, 300, <<1>>) == {:error, {:not_sendable, 300}}
    assert Link.send_message(link, 4242, <<1>>, []) == {:error, {:not_sendable, 4242}}
    assert Link.send_message(link, 300, <<1>>, force: true) == :ok
  end

  test "an id the dialect lacks is an error, not a frame" do
    link = link([])
    assert Link.send_message(link, 4242, <<1>>) == {:error, {:unknown_msgid, 4242}}
  end

  test "a frame split across reads is reassembled; gaps and garbage are counted" do
    link = link([])
    :ok = Link.subscribe(link)
    {:ok, a} = Frame.encode(%Frame{msgid: 300, payload: <<1, 1, 1, 1>>, seq: 10}, TestDialect)
    {:ok, b} = Frame.encode(%Frame{msgid: 300, payload: <<2, 2, 2, 2>>, seq: 13}, TestDialect)

    send(link, {:mavlink_data, binary_part(a, 0, 5)})
    send(link, {:mavlink_data, binary_part(a, 5, byte_size(a) - 5) <> <<0xDE, 0xAD>> <> b})

    assert_receive {Link, ^link, %Frame{seq: 10}}
    assert_receive {Link, ^link, %Frame{seq: 13}}
    assert %{rx: 2, dropped: 2, errors: 1} = Link.stats(link)
  end

  test "a transport that does not open leaves the link out" do
    defmodule Closed do
      def open(_), do: {:error, :enoent}
    end

    assert :ignore = Link.init(dialect: TestDialect, transport: Closed)
  end

  describe "signed" do
    @key :binary.copy(<<1>>, 32)

    test "frames go out signed; reflected back, they are refused" do
      link = link(echo: true, signing: MAVLink2.Signing.new(@key, link_id: 3))
      :ok = Link.subscribe(link)

      assert :ok = Link.send_message(link, 300, <<1, 2, 3, 4>>)
      assert :ok = Link.send_message(link, 300, <<5, 6, 7, 8>>)
      refute_receive {Link, ^link, _}, 50
      assert %{tx: 2, rx: 0, replay: 2} = Link.stats(link)

      written = Loopback.written(:sys.get_state(link).handle)
      assert {[a, b], [], <<>>} = Frame.drain(written, TestDialect)
      assert {3, t1, _, _} = a.signature
      assert {3, t2, _, _} = b.signature
      assert t2 > t1

      peer = MAVLink2.Signing.new(@key)
      assert {:ok, peer} = MAVLink2.Signing.verify(peer, a, t1)
      assert {:ok, _} = MAVLink2.Signing.verify(peer, b, t1)
    end

    test "a frame signed long ago is refused by a link that has not sent" do
      link = link(signing: MAVLink2.Signing.new(@key))
      :ok = Link.subscribe(link)
      frame = %Frame{msgid: 300, payload: <<1, 1, 1, 1>>, sysid: 7}

      {:ok, stale, _} =
        MAVLink2.Signing.encode(MAVLink2.Signing.new(@key), frame, TestDialect, 1_000)

      send(link, {:mavlink_data, stale})
      refute_receive {Link, ^link, _}, 50
      assert %{rx: 0, replay: 1} = Link.stats(link)
    end

    test "unsigned, wrongly signed and replayed frames are dropped and counted" do
      link = link(signing: MAVLink2.Signing.new(@key))
      :ok = Link.subscribe(link)
      frame = %Frame{msgid: 300, payload: <<1, 1, 1, 1>>}
      now = MAVLink2.Signing.timestamp(System.os_time(:microsecond))

      {:ok, unsigned} = Frame.encode(frame, TestDialect)

      {:ok, other, _} =
        MAVLink2.Signing.encode(
          MAVLink2.Signing.new(:binary.copy(<<2>>, 32)),
          frame,
          TestDialect,
          now
        )

      {:ok, good, _} =
        MAVLink2.Signing.encode(MAVLink2.Signing.new(@key), frame, TestDialect, now)

      send(link, {:mavlink_data, unsigned <> other <> good <> good})
      assert_receive {Link, ^link, %Frame{signature: {0, ^now, _, _}}}
      refute_receive {Link, ^link, _}, 50
      assert %{rx: 1, unsigned: 1, bad_signature: 1, replay: 1} = Link.stats(link)
    end
  end
end
