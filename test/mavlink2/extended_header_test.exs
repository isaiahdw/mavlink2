defmodule MAVLink2.ExtendedHeaderTest do
  use ExUnit.Case, async: true

  alias MAVLink2.{Common, Frame, Signing}

  # mavlink/c_library_v2 a2d0ecf (mavlink bb97687): mavlink_msg_*_pack and
  # mavlink_msg_to_send_buffer on channel 0, so seq counts up from 0.
  @sysid32_heartbeat "FD09020000701101000100000000000000060800040318A8"
  @target32_command_long "FD20040001FFBE4C0000A08601000000803F0000000000000000000000000000000000000000000000009001FF019996"
  @both_command_long "FD2006000270110100BE4C0000A08601000000803F0000000000000000000000000000000000000000000000009001FF013B27"
  # Signed with key bytes 0..31, link id 5, timestamp 0x123456789A.
  @signed_both_command_long "FD2007000370110100BE4C0000A08601000000803F0000000000000000000000000000000000000000000000009001FF0127E5059A78563412006CACFDD2805A"

  @key :binary.list_to_bin(Enum.to_list(0..31))

  defp frame(message, opts) do
    {msgid, payload} = Common.encode(message)
    struct!(%Frame{msgid: msgid, payload: payload}, opts)
  end

  defp heartbeat, do: %Common.Heartbeat{type: 6, autopilot: 8, system_status: 4}

  # A target over 255 is 255 in the payload, the full id in the header.
  defp command,
    do: %Common.CommandLong{target_system: 255, target_component: 1, command: 400, param1: 1.0}

  test "frames as the C library encodes them, both ways" do
    for {hex, message, opts} <- [
          {@sysid32_heartbeat, heartbeat(), seq: 0, sysid: 70_000, compid: 1},
          {@target32_command_long, command(),
           seq: 1, sysid: 255, compid: 190, target_sysid: 100_000},
          {@both_command_long, command(),
           seq: 2, sysid: 70_000, compid: 190, target_sysid: 100_000}
        ] do
      wire = Base.decode16!(hex)
      f = frame(message, opts)
      assert Frame.encode(f, Common) == {:ok, wire}

      assert {:ok, decoded, <<>>} = Frame.decode(wire, Common)

      expected = opts |> Map.new() |> Map.put_new(:target_sysid, nil)
      assert Map.take(decoded, Map.keys(expected)) == expected

      assert Common.decode(decoded.msgid, decoded.payload) == {:ok, message}
    end
  end

  test "a signed frame with both extensions, as the C library signs it" do
    wire = Base.decode16!(@signed_both_command_long)
    f = frame(command(), seq: 3, sysid: 70_000, compid: 190, target_sysid: 100_000)

    assert {:ok, ^wire, _} =
             Signing.encode(Signing.new(@key, link_id: 5), f, Common, 0x123456789A)

    assert {:ok, decoded, <<>>} = Frame.decode(wire, Common)
    assert {:ok, _} = Signing.verify(Signing.new(@key), decoded, 0x123456789A)
  end
end
