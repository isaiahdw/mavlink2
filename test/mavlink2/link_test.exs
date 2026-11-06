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

  test "sequence gaps are counted per sender" do
    link = link([])

    bytes =
      for seq <- 0..4, compid <- [1, 2], into: <<>> do
        {:ok, wire} =
          Frame.encode(%Frame{msgid: 300, payload: <<1>>, seq: seq, compid: compid}, TestDialect)

        wire
      end

    {:ok, gap} = Frame.encode(%Frame{msgid: 300, payload: <<1>>, seq: 8, compid: 2}, TestDialect)
    send(link, {:mavlink_data, bytes <> gap})
    assert %{rx: 11, dropped: 3} = Link.stats(link)
  end

  test "subscribing twice delivers once; unsubscribing stops delivery" do
    link = link(echo: true)
    :ok = Link.subscribe(link)
    :ok = Link.subscribe(link)
    :ok = Link.send_message(link, 300, <<1>>)
    assert_receive {Link, ^link, %Frame{}}
    refute_receive {Link, ^link, _}, 50

    :ok = Link.unsubscribe(link)
    assert {:monitors, []} = Process.info(link, :monitors)
    :ok = Link.send_message(link, 300, <<1>>)
    refute_receive {Link, ^link, _}, 50
  end

  test "a 32-bit sysid and a header target go out and come back" do
    link = link(echo: true, sysid: 70_000)
    :ok = Link.subscribe(link)
    :ok = Link.send_message(link, 300, <<1, 2, 3, 4>>, target_sysid: 100_000)
    assert_receive {Link, ^link, %Frame{sysid: 70_000, target_sysid: 100_000}}
  end

  test "unknown ids are delivered with unknown: :keep, and forwarded unchanged" do
    link = link(unknown: :keep)
    :ok = Link.subscribe(link)
    unknown = <<0xFD, 3, 0, 0, 7, 70, 80, 0x39, 0x30, 0, 1, 2, 3, 0xAA, 0xBB>>
    send(link, {:mavlink_data, unknown})
    assert_receive {Link, ^link, %Frame{known: false, msgid: 0x3039} = frame}
    assert %{rx: 1, unknown: 1, errors: 0} = Link.stats(link)

    out =
      start_supervised!(
        Supervisor.child_spec({Link, dialect: TestDialect, transport: Loopback}, id: :out)
      )

    assert :ok = Link.forward(out, frame)
    assert Loopback.written(:sys.get_state(out).handle) == unknown
    assert Link.forward(out, %Frame{msgid: 300, payload: <<1>>}) == {:error, :no_raw_bytes}
  end

  test "0 is refused as this end's sysid or compid" do
    assert_raise ArgumentError, ~r/:sysid must be an integer from 1.*broadcast/, fn ->
      Link.start_link(dialect: TestDialect, transport: Loopback, sysid: 0)
    end

    assert_raise ArgumentError, ~r/:compid must be an integer from 1 to 255/, fn ->
      Link.start_link(dialect: TestDialect, transport: Loopback, compid: 0)
    end

    link = link([])

    assert_raise ArgumentError, ~r/:compid must be an integer from 1 to 255/, fn ->
      Link.send_message(link, 300, <<1>>, compid: 0)
    end
  end

  describe "with a generated dialect" do
    alias MAVLink2.Common

    defp common_link(opts) do
      spec = {Link, [dialect: Common, transport: Loopback, echo: true] ++ opts}
      start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
    end

    test "send/3 encodes a struct; subscribers can take it decoded, filtered" do
      link = common_link(sysid: 7)
      :ok = Link.subscribe(link, self(), decode: true, only: [Common.Heartbeat])

      :ok = Link.send(link, %Common.SystemTime{time_boot_ms: 5})
      :ok = Link.send(link, %Common.Heartbeat{type: 6, autopilot: 8})

      assert_receive {Link, ^link, %Frame{sysid: 7}, %Common.Heartbeat{type: 6, autopilot: 8}}
      refute_receive {Link, ^link, _, %Common.SystemTime{}}, 50
    end

    test "send/3 puts a target over 255 in the header" do
      link = common_link([])
      :ok = Link.subscribe(link, self(), decode: true)

      :ok =
        Link.send(link, %Common.CommandLong{
          target_system: 100_000,
          target_component: 1,
          command: 400
        })

      assert_receive {Link, ^link, %Frame{target_sysid: 100_000},
                      %Common.CommandLong{target_system: 255, command: 400}}
    end

    test "only: takes ids as well as modules" do
      link = common_link([])
      :ok = Link.subscribe(link, self(), only: [2])
      :ok = Link.send(link, %Common.Heartbeat{})
      :ok = Link.send(link, %Common.SystemTime{})
      assert_receive {Link, ^link, %Frame{msgid: 2}}
      refute_receive {Link, ^link, %Frame{msgid: 0}}, 50
    end
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

    test "subscribers that ask get refused frames, tagged with the reason" do
      link = link(signing: MAVLink2.Signing.new(@key))
      :ok = Link.subscribe(link, self(), rejected: true)
      {:ok, unsigned} = Frame.encode(%Frame{msgid: 300, payload: <<1, 1, 1, 1>>}, TestDialect)
      send(link, {:mavlink_data, unsigned})
      assert_receive {Link, ^link, {:rejected, :unsigned, %Frame{msgid: 300}}}
      assert %{rx: 0, unsigned: 1} = Link.stats(link)

      :ok = Link.subscribe(link)
      send(link, {:mavlink_data, unsigned})
      refute_receive {Link, ^link, _}, 50
    end

    test "accept_unsigned: :all lets every unsigned frame through" do
      link = link(signing: MAVLink2.Signing.new(@key, accept_unsigned: :all))
      :ok = Link.subscribe(link)
      {:ok, unsigned} = Frame.encode(%Frame{msgid: 300, payload: <<1, 1, 1, 1>>}, TestDialect)
      send(link, {:mavlink_data, unsigned})
      assert_receive {Link, ^link, %Frame{signature: nil}}
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
