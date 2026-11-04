defmodule MAVLink2.CommandTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Command, Common, Vehicle}

  @fast [timeout: 50, progress_timeout: 100]
  @arm 400
  @accepted 0
  @in_progress 5

  defp ack(command, result, extra \\ []),
    do: struct!(Common.CommandAck, [command: command, result: result] ++ extra)

  test "a command is acked" do
    {gcs, vehicle} = Vehicle.pair()

    Vehicle.script(vehicle, nil, fn
      %Common.CommandLong{command: @arm, param1: 1.0, target_system: 1, target_component: 1},
      _,
      s ->
        {ack(@arm, @accepted), s}
    end)

    assert {:ok, :mav_result_accepted, %Common.CommandAck{command: @arm}} =
             Command.long(gcs, {1, 1}, :mav_cmd_component_arm_disarm, [1.0], @fast)
  end

  test "an unanswered command is sent again, its confirmation counted up" do
    {gcs, vehicle} = Vehicle.pair()
    test = self()

    Vehicle.script(vehicle, 0, fn %Common.CommandLong{confirmation: c}, _, n ->
      send(test, {:confirmation, c})
      if n < 2, do: {[], n + 1}, else: {ack(@arm, @accepted), n + 1}
    end)

    assert {:ok, :mav_result_accepted, _} = Command.long(gcs, {1, 1}, @arm, [1.0], @fast)
    assert_received {:confirmation, 0}
    assert_received {:confirmation, 1}
    assert_received {:confirmation, 2}
  end

  test "no ack at all is a timeout after the retries" do
    {gcs, vehicle} = Vehicle.pair()
    test = self()
    Vehicle.script(vehicle, nil, fn _, _, s -> send(test, :sent) && {[], s} end)

    assert Command.long(gcs, {1, 1}, @arm, [], @fast ++ [retries: 1]) == {:error, :timeout}
    assert_received :sent
    assert_received :sent
    refute_received :sent
  end

  test "in progress stops the resending and waits for the final ack" do
    {gcs, vehicle} = Vehicle.pair()
    test = self()

    Vehicle.script(vehicle, nil, fn %Common.CommandLong{}, _, s ->
      {[
         ack(@arm, @in_progress, progress: 10),
         ack(@arm, @in_progress, progress: 90),
         ack(@arm, 4)
       ], s}
    end)

    assert {:ok, :mav_result_failed, _} =
             Command.long(
               gcs,
               {1, 1},
               @arm,
               [],
               @fast ++ [on_progress: &send(test, {:p, &1.progress})]
             )

    assert_received {:p, 10}
    assert_received {:p, 90}
  end

  test "acks for another command, another system or another station are ignored" do
    {gcs, vehicle} = Vehicle.pair()

    Vehicle.script(vehicle, nil, fn %Common.CommandLong{}, _, s ->
      {[
         ack(@arm + 1, @accepted),
         ack(@arm, @accepted, target_system: 7),
         ack(@arm, 2, target_system: 255, target_component: 190)
       ], s}
    end)

    assert {:ok, :mav_result_denied, _} = Command.long(gcs, {1, 1}, @arm, [], @fast)
  end

  test "COMMAND_INT carries its frame and integer position" do
    {gcs, vehicle} = Vehicle.pair()
    test = self()

    Vehicle.script(vehicle, nil, fn %Common.CommandInt{} = c, _, s ->
      send(test, {:got, c})
      {ack(c.command, @accepted), s}
    end)

    assert {:ok, :mav_result_accepted, _} =
             Command.int(
               gcs,
               {1, 0},
               :mav_cmd_do_reposition,
               [frame: :mav_frame_global_int, x: 473_977_420, y: 85_455_940, z: 50.0],
               @fast
             )

    assert_received {:got, %{command: 192, frame: 5, x: 473_977_420, y: 85_455_940, z: 50.0}}
  end

  test "an unknown command entry is refused before anything is sent" do
    {gcs, _vehicle} = Vehicle.pair()

    assert Command.long(gcs, {1, 1}, :mav_cmd_no_such_thing) ==
             {:error, {:unknown_entry, :mav_cmd, :mav_cmd_no_such_thing}}
  end
end
