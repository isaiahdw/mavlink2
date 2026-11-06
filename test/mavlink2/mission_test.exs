defmodule MAVLink2.MissionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Common, Mission, Vehicle}

  @fast [timeout: 100, retries: 3]
  @accepted 0
  @no_space 4
  @fence 1

  @items [
    [command: :mav_cmd_nav_takeoff, frame: :mav_frame_global_relative_alt, z: 20.0],
    [
      command: :mav_cmd_nav_waypoint,
      frame: :mav_frame_global_relative_alt,
      x: 473_977_420,
      y: 85_455_940,
      z: 30.0,
      autocontinue: 1
    ]
  ]

  defp ack(type, mission_type \\ 0),
    do: %Common.MissionAck{
      target_system: 255,
      target_component: 190,
      type: type,
      mission_type: mission_type
    }

  defp request(seq, legacy?) do
    mod = if legacy?, do: Common.MissionRequest, else: Common.MissionRequestInt
    struct!(mod, target_system: 255, target_component: 190, seq: seq)
  end

  # A vehicle that takes uploads into, and serves downloads from, its
  # state: %{items, expected, opts}. opts: :drop_first_count, :legacy,
  # :refuse.
  defp vehicle(v, test, items \\ [], opts \\ []) do
    Vehicle.script(v, %{items: items, expected: 0, opts: opts, dropped: false}, fn
      %Common.MissionCount{} = c, _, s ->
        if s.opts[:drop_first_count] && not s.dropped,
          do: {[], %{s | dropped: true}},
          else: count(%{s | expected: c.count, items: []})

      %Common.MissionItemInt{seq: seq} = item, _, s ->
        s = %{s | items: s.items ++ [item]}

        if seq + 1 < s.expected,
          do: {request(seq + 1, s.opts[:legacy]), s},
          else: send(test, {:stored, s.items}) && {ack(@accepted), s}

      %Common.MissionRequestList{}, _, s ->
        {%Common.MissionCount{target_system: 255, target_component: 190, count: length(s.items)},
         s}

      %Common.MissionRequestInt{seq: seq}, _, s ->
        {struct!(Enum.at(s.items, seq), target_system: 255, target_component: 190), s}

      %Common.MissionAck{type: type}, _, s ->
        send(test, {:acked, type})
        {[], s}

      %Common.MissionClearAll{mission_type: t}, _, s ->
        {[ack(@accepted, @fence), ack(@accepted, t)], %{s | items: []}}
    end)
  end

  defp count(%{opts: o} = s) do
    cond do
      o[:refuse] -> {ack(@no_space), s}
      s.expected == 0 -> {ack(@accepted), s}
      true -> {request(0, o[:legacy]), s}
    end
  end

  test "upload sends each item the vehicle asks for" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == {:ok, nil}
    assert_receive {:stored, [takeoff, waypoint]}
    assert %{seq: 0, command: 22, frame: 3, z: 20.0} = takeoff
    assert %{seq: 1, command: 16, x: 473_977_420, y: 85_455_940, autocontinue: 1} = waypoint
  end

  test "upload answers the older MISSION_REQUEST too" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], legacy: true)
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == {:ok, nil}
    assert_receive {:stored, [_, _]}
  end

  test "upload sends the count again when the vehicle stays quiet" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], drop_first_count: true)
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == {:ok, nil}
    assert_receive {:stored, [_, _]}
  end

  test "an empty upload is acked at once" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    assert Mission.upload(gcs, {1, 1}, [], @fast) == {:ok, nil}
  end

  test "a refusal is the vehicle's mission result" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], refuse: true)

    assert Mission.upload(gcs, {1, 1}, @items, @fast) ==
             {:error, {:mission_result, :mav_mission_no_space}}
  end

  test "a silent vehicle is a timeout, and the operation is cancelled" do
    {gcs, v} = Vehicle.pair()
    test = self()

    Vehicle.script(v, nil, fn
      %Common.MissionAck{type: type}, _, s -> send(test, {:acked, type}) && {[], s}
      _, _, s -> {[], s}
    end)

    assert Mission.upload(gcs, {1, 1}, @items, @fast) == {:error, :timeout}
    assert_receive {:acked, 15}
    assert Mission.download(gcs, {1, 1}, @fast) == {:error, :timeout}
    assert_receive {:acked, 15}
  end

  test "download takes the deprecated MISSION_ITEM, scaling its positions" do
    {gcs, v} = Vehicle.pair()

    Vehicle.script(v, nil, fn
      %Common.MissionRequestList{}, _, s ->
        {%Common.MissionCount{target_system: 255, target_component: 190, count: 2}, s}

      %Common.MissionRequestInt{seq: 0}, _, s ->
        {%Common.MissionItem{
           target_system: 255,
           target_component: 190,
           seq: 0,
           frame: 3,
           command: 16,
           x: 47.397742,
           y: 8.545594,
           z: 30.0
         }, s}

      %Common.MissionRequestInt{seq: 1}, _, s ->
        {%Common.MissionItem{
           target_system: 255,
           target_component: 190,
           seq: 1,
           frame: 1,
           command: 16,
           x: 5.0,
           y: -2.5
         }, s}

      %Common.MissionAck{}, _, s ->
        {[], s}
    end)

    assert {:ok, [global, local], nil} = Mission.download(gcs, {1, 1}, @fast)
    # A float32 holds about 7 significant digits: degrees to within a few
    # 10^-7.
    assert global.frame == :mav_frame_global_relative_alt
    assert_in_delta global.x, 473_977_420, 20
    assert_in_delta global.y, 85_455_940, 20
    assert %{frame: :mav_frame_local_ned, x: 50_000, y: -25_000} = local
  end

  test "download returns what upload stored, and acks it" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    {:ok, nil} = Mission.upload(gcs, {1, 1}, @items, @fast)
    assert_receive {:stored, stored}

    {gcs2, v2} = Vehicle.pair()
    vehicle(v2, self(), stored)
    assert {:ok, [takeoff, waypoint], nil} = Mission.download(gcs2, {1, 1}, @fast)

    assert %{command: :mav_cmd_nav_takeoff, frame: :mav_frame_global_relative_alt, z: 20.0} =
             takeoff

    assert %{command: :mav_cmd_nav_waypoint, x: 473_977_420, autocontinue: 1} = waypoint
    assert_receive {:acked, @accepted}

    assert Mission.upload(gcs2, {1, 1}, [takeoff, waypoint], @fast) == {:ok, nil}
  end

  test "clear waits for the ack of its own mission type" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    assert Mission.clear(gcs, {1, 1}, @fast) == :ok
  end

  test "an unknown item field is refused before anything is sent" do
    {gcs, _v} = Vehicle.pair()

    assert_raise ArgumentError, ~r/unknown item field :cmd. Did you mean :command/, fn ->
      Mission.upload(gcs, {1, 1}, [[cmd: 16]])
    end
  end
end
