defmodule MAVLink2.Dialect.XMLTest do
  use ExUnit.Case, async: true

  alias MAVLink2.{Common, Frame}

  # pymavlink 2.4.50's view of the same common.xml (test/fixtures).
  @golden "test/fixtures/pymavlink_common.json" |> File.read!() |> JSON.decode!()

  test "every message: id, crc_extra, length, wire order and field types as pymavlink has them" do
    golden = @golden["messages"]

    assert Common.msgids() ==
             golden |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.sort()

    for {id, g} <- golden do
      id = String.to_integer(id)
      mod = Common.message(id) || flunk("no module for #{g["name"]}")
      assert Common.crc_extra(id) == g["crc_extra"], g["name"]
      assert Common.payload_length(id) == g["length"], g["name"]

      layout = mod.layout()

      assert Enum.map(layout, fn {name, _, _} -> Atom.to_string(name) end) == g["wire_order"],
             g["name"]

      for {name, type, n} <- layout do
        field = Atom.to_string(name)
        assert c_type(type) == g["types"][field], "#{g["name"]}.#{field}"
        assert (n || 0) == g["array_lengths"][field], "#{g["name"]}.#{field}"
      end
    end
  end

  test "payloads as pymavlink packs them, both ways" do
    for g <- @golden["payloads"] do
      mod = Code.ensure_loaded!(Common.message(g["msgid"]) || flunk("no module for #{g["name"]}"))
      message = struct!(mod, for({k, v} <- g["fields"], do: {String.to_existing_atom(k), v}))
      wire = Base.decode16!(g["wire_payload"], case: :lower)

      assert {msgid, payload} = Common.encode(message)
      assert msgid == g["msgid"]
      assert trim(payload) == wire, g["name"]
      assert Common.decode(msgid, wire) == {:ok, message}, g["name"]
    end
  end

  test "a generated message goes through a frame and back" do
    message = %Common.CommandLong{
      command: 400,
      param1: 1.0,
      target_system: 1,
      target_component: 1
    }

    {msgid, payload} = Common.encode(message)

    {:ok, wire} =
      Frame.encode(%Frame{msgid: msgid, payload: payload, sysid: 255, compid: 0}, Common)

    # The same frame pymavlink packs (frame_test.exs).
    assert Base.encode16(wire) ==
             "FD20000000FF004C00000000803F0000000000000000000000000000000000000000000000009001010121EC"

    {:ok, frame, <<>>} = Frame.decode(wire, Common)
    assert Common.decode(frame.msgid, frame.payload) == {:ok, message}
  end

  test "NaN and infinities survive, as atoms" do
    message = %Common.CommandLong{
      param1: :nan,
      param2: :infinity,
      param3: :neg_infinity,
      param4: 2.5
    }

    {msgid, payload} = Common.encode(message)
    assert Common.decode(msgid, payload) == {:ok, message}
  end

  test "defaults, strings and short arrays" do
    assert %Common.Heartbeat{}.mavlink_version == 3
    assert %Common.ParamValue{}.param_id == ""

    message = %Common.ParamValue{param_id: "A_NAME_LONGER_THAN_16"}
    {msgid, payload} = Common.encode(message)
    assert {:ok, %{param_id: "A_NAME_LONGER_TH"}} = Common.decode(msgid, payload)

    {msgid, payload} = Common.encode(%Common.SetupSigning{secret_key: [1, 2]})
    assert {:ok, %{secret_key: [1, 2 | zeros]}} = Common.decode(msgid, payload)
    assert zeros == List.duplicate(0, 30)
  end

  test "enums by name and value; unknown ids" do
    assert Common.enum_value(:mav_cmd, :mav_cmd_component_arm_disarm) == 400
    assert Common.enum_entry(:mav_cmd, 400) == :mav_cmd_component_arm_disarm
    assert Common.enum(:mav_state)[:mav_state_active] == 4
    assert Common.decode(99_999, <<>>) == {:error, {:unknown_msgid, 99_999}}
    assert Common.crc_extra(99_999) == nil
  end

  defp c_type(:char), do: "char"
  defp c_type(:float), do: "float"
  defp c_type(:double), do: "double"
  defp c_type(t), do: Atom.to_string(t) <> "_t"

  defp trim(payload) do
    case String.trim_trailing(payload, <<0>>) do
      "" -> <<0>>
      t -> t
    end
  end
end
