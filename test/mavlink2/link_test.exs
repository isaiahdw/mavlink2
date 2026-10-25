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
    assert %{rx: 2, dropped: 2, errors: 2} = Link.stats(link)
  end

  test "a transport that does not open leaves the link out" do
    defmodule Closed do
      def open(_), do: {:error, :enoent}
    end

    assert :ignore = Link.init(dialect: TestDialect, transport: Closed)
  end
end
