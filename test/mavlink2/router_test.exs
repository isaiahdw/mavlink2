defmodule MAVLink2.RouterTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Common, Frame, Link, Router}
  alias MAVLink2.Transport.Loopback

  setup do
    links =
      for id <- [:a, :b, :c], into: %{} do
        spec = {Link, dialect: Common, transport: Loopback, unknown: :keep}
        {id, start_supervised!(Supervisor.child_spec(spec, id: id))}
      end

    router = start_supervised!({Router, links: Map.values(links)})
    %{links: links, router: router}
  end

  defp wire(message, opts) do
    {msgid, payload} = Common.encode(message)
    {:ok, bytes} = Frame.encode(struct(%Frame{msgid: msgid, payload: payload}, opts), Common)
    bytes
  end

  defp heartbeat(sysid, compid \\ 1), do: wire(%Common.Heartbeat{}, sysid: sysid, compid: compid)

  defp command(to_system, to_component, opts \\ []) do
    wire(
      %Common.CommandLong{target_system: to_system, target_component: to_component, command: 400},
      Keyword.merge([sysid: 255, compid: 190], opts)
    )
  end

  # Injects bytes as though the link's peer sent them, and waits until the
  # router has handled them.
  defp receive_on(link, router, bytes) do
    send(link, {:mavlink_data, bytes})
    _ = Link.stats(link)
    _ = Router.routes(router)
  end

  defp written(link), do: Loopback.written(:sys.get_state(link).handle)

  test "a broadcast goes out on every other link", %{links: l, router: r} do
    hb = heartbeat(2)
    receive_on(l.a, r, hb)
    assert written(l.a) == ""
    assert written(l.b) == hb
    assert written(l.c) == hb
  end

  test "a targeted frame goes only where its target has been seen", %{links: l, router: r} do
    receive_on(l.b, r, heartbeat(2, 1))
    receive_on(l.c, r, heartbeat(3, 1))
    assert %{{2, 1} => [_], {3, 1} => [_]} = Router.routes(r)
    before_b = written(l.b)
    before_c = written(l.c)

    to_2 = command(2, 1)
    receive_on(l.a, r, to_2)
    assert written(l.b) == before_b <> to_2
    assert written(l.c) == before_c

    any_of_3 = command(3, 0)
    receive_on(l.a, r, any_of_3)
    assert written(l.c) == before_c <> any_of_3

    # Another system's components are its own business: any component of
    # system 2 goes where system 2 has been seen.
    other_component = command(2, 5)
    unseen_system = command(9, 1)
    receive_on(l.a, r, other_component <> unseen_system)
    assert written(l.b) == before_b <> to_2 <> other_component
    assert written(l.c) == before_c <> any_of_3
  end

  test "within the router's own system, a component goes only where it has been seen", %{links: l} do
    :ok = stop_supervised(Router)

    r =
      start_supervised!(Supervisor.child_spec({Router, links: Map.values(l), sysid: 1}, id: :own))

    receive_on(l.b, r, heartbeat(1, 1))
    receive_on(l.c, r, heartbeat(1, 154))
    before_b = written(l.b)

    to_gimbal = command(1, 154)
    receive_on(l.a, r, to_gimbal)
    assert written(l.b) == before_b
    assert written(l.c) =~ to_gimbal

    to_all_of_1 = command(1, 0)
    receive_on(l.a, r, to_all_of_1)
    assert written(l.b) =~ to_all_of_1
  end

  test "SETUP_SIGNING is never forwarded", %{links: l, router: r} do
    setup = wire(%Common.SetupSigning{target_system: 0, secret_key: [1, 2, 3]}, sysid: 255)
    receive_on(l.a, r, setup)
    assert written(l.b) == ""
    assert written(l.c) == ""
  end

  test "a SYSTEM_TIME that goes back forgets the system's routes", %{links: l, router: r} do
    time = fn ms -> wire(%Common.SystemTime{time_boot_ms: ms}, sysid: 2, compid: 1) end
    receive_on(l.b, r, time.(50_000) <> heartbeat(2, 5))
    assert %{{2, 1} => _, {2, 5} => _} = Router.routes(r)

    receive_on(l.b, r, time.(100))
    assert Map.keys(Router.routes(r)) == [{2, 1}]
  end

  test "nothing goes back out on the link it came in on", %{links: l, router: r} do
    receive_on(l.a, r, heartbeat(2))
    receive_on(l.a, r, command(2, 1))
    assert written(l.a) == ""
  end

  test "a header target takes precedence over the payload's", %{links: l, router: r} do
    receive_on(l.b, r, heartbeat(70_000))
    receive_on(l.c, r, heartbeat(255))
    before_b = written(l.b)
    before_c = written(l.c)

    wide = command(255, 1, target_sysid: 70_000)
    receive_on(l.a, r, wide)
    assert written(l.b) == before_b <> wide
    assert written(l.c) == before_c
  end

  test "a frame outside the dialect is a broadcast, forwarded unchanged", %{links: l, router: r} do
    unknown = <<0xFD, 3, 0, 0, 7, 70, 80, 0x39, 0x30, 0, 1, 2, 3, 0xAA, 0xBB>>
    receive_on(l.a, r, unknown)
    assert written(l.b) == unknown
    assert written(l.c) == unknown
  end

  test "frames a link's signing refuses are forwarded, but teach nothing" do
    key = :binary.copy(<<1>>, 32)
    signing = MAVLink2.Signing.new(key)

    a =
      start_supervised!(
        Supervisor.child_spec({Link, dialect: Common, transport: Loopback, signing: signing},
          id: :signed_a
        )
      )

    b =
      start_supervised!(
        Supervisor.child_spec({Link, dialect: Common, transport: Loopback}, id: :plain_b)
      )

    r = start_supervised!(Supervisor.child_spec({Router, links: [a, b]}, id: :signed_router))

    unsigned = heartbeat(7)
    receive_on(a, r, unsigned)
    assert written(b) == unsigned
    assert Router.routes(r) == %{}
  end

  test "the router stops with a link", %{links: l, router: r} do
    ref = Process.monitor(r)
    GenServer.stop(l.b)
    assert_receive {:DOWN, ^ref, :process, ^r, {:link_down, _}}
  end
end
