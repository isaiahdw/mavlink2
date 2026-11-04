defmodule MAVLink2.MissionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Common, Mission, Vehicle}

  @fast [timeout: 50, retries: 2]
  @accepted 0
  @no_space 4
  @fence 1

  @items [
    [command: :mav_cmd_nav_takeoff, frame: :mav_frame_global_relative_alt_int, z: 20.0],
    [
      command: :mav_cmd_nav_waypoint,
      frame: :mav_frame_global_relative_alt_int,
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
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == :ok
    assert_received {:stored, [takeoff, waypoint]}
    assert %{seq: 0, command: 22, frame: 6, z: 20.0} = takeoff
    assert %{seq: 1, command: 16, x: 473_977_420, y: 85_455_940, autocontinue: 1} = waypoint
  end

  test "upload answers the older MISSION_REQUEST too" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], legacy: true)
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == :ok
    assert_received {:stored, [_, _]}
  end

  test "upload sends the count again when the vehicle stays quiet" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], drop_first_count: true)
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == :ok
    assert_received {:stored, [_, _]}
  end

  test "an empty upload is acked at once" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    assert Mission.upload(gcs, {1, 1}, [], @fast) == :ok
  end

  test "a refusal is the vehicle's mission result" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self(), [], refuse: true)

    assert Mission.upload(gcs, {1, 1}, @items, @fast) ==
             {:error, {:mission_result, :mav_mission_no_space}}
  end

  test "a silent vehicle is a timeout" do
    {gcs, _v} = Vehicle.pair()
    assert Mission.upload(gcs, {1, 1}, @items, @fast) == {:error, :timeout}
    assert Mission.download(gcs, {1, 1}, @fast) == {:error, :timeout}
  end

  test "download returns what upload stored, and acks it" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    :ok = Mission.upload(gcs, {1, 1}, @items, @fast)
    assert_received {:stored, stored}

    {gcs2, v2} = Vehicle.pair()
    vehicle(v2, self(), stored)
    assert {:ok, [takeoff, waypoint]} = Mission.download(gcs2, {1, 1}, @fast)

    assert %{command: :mav_cmd_nav_takeoff, frame: :mav_frame_global_relative_alt_int, z: 20.0} =
             takeoff

    assert %{command: :mav_cmd_nav_waypoint, x: 473_977_420, autocontinue: 1} = waypoint
    assert_receive {:acked, @accepted}

    assert Mission.upload(gcs2, {1, 1}, [takeoff, waypoint], @fast) == :ok
  end

  test "clear waits for the ack of its own mission type" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, self())
    assert Mission.clear(gcs, {1, 1}, @fast) == :ok
  end

  test "an unknown item field is refused before anything is sent" do
    {gcs, _v} = Vehicle.pair()
    assert Mission.upload(gcs, {1, 1}, [[cmd: 16]]) == {:error, {:unknown_fields, [:cmd]}}
  end
end
