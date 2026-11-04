defmodule MAVLink2.ParamTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import Bitwise

  alias MAVLink2.{Common, Param, Vehicle}

  @fast [timeout: 50]
  @int32 6
  @real32 9

  # A vehicle holding `params`, [{name, float, type}], in index order,
  # answering as the protocol says. `drop` is a set of indices it leaves out
  # of the list stream.
  defp vehicle(vehicle, params, drop \\ MapSet.new()) do
    count = length(params)

    value = fn {name, v, type}, index ->
      %Common.ParamValue{
        param_id: name,
        param_value: v,
        param_type: type,
        param_count: count,
        param_index: index
      }
    end

    indexed = Enum.with_index(params)
    by_name = fn name -> Enum.find(indexed, fn {{n, _, _}, _} -> n == name end) end

    Vehicle.script(vehicle, params, fn
      %Common.ParamRequestList{}, _, s ->
        {for({p, i} <- indexed, i not in drop, do: value.(p, i)), s}

      %Common.ParamRequestRead{param_index: -1, param_id: name}, _, s ->
        case by_name.(name) do
          {p, i} -> {value.(p, i), s}
          nil -> {[], s}
        end

      %Common.ParamRequestRead{param_index: i}, _, s ->
        {value.(Enum.at(params, i), i), s}

      %Common.ParamSet{param_id: name, param_value: v, param_type: t}, _, s ->
        {{_, _, _}, i} = by_name.(name)
        {value.({name, v, t}, i), s}
    end)
  end

  test "read by name and by index" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, [{"A", 1.5, @real32}, {"SYSID_THISMAV", 7.0, @int32}])

    assert {:ok,
            %{name: "SYSID_THISMAV", value: 7, type: :mav_param_type_int32, index: 1, count: 2}} =
             Param.read(gcs, {1, 1}, "SYSID_THISMAV", @fast)

    assert {:ok, %{name: "A", value: 1.5, type: :mav_param_type_real32}} =
             Param.read(gcs, {1, 1}, 0, @fast)
  end

  test "an unknown name times out after the retries" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, [{"A", 1.5, @real32}])
    assert Param.read(gcs, {1, 1}, "NOPE", @fast ++ [retries: 1]) == {:error, :timeout}
  end

  test "set returns what the vehicle reports back" do
    {gcs, v} = Vehicle.pair()
    vehicle(v, [{"A", 1.5, @real32}])

    assert {:ok, %{name: "A", value: 2.25}} =
             Param.set(gcs, {1, 1}, "A", 2.25, :mav_param_type_real32, @fast)
  end

  test "bytewise integers go out and come back in the float's bytes" do
    {gcs, v} = Vehicle.pair()
    <<as_float::float-little-32>> = <<12_345::little-signed-32>>
    vehicle(v, [{"N", as_float, @int32}])

    assert {:ok, %{value: 12_345}} = Param.read(gcs, {1, 1}, "N", @fast ++ [encoding: :bytewise])

    assert {:ok, %{value: 4242}} =
             Param.set(gcs, {1, 1}, "N", 4242, @int32, @fast ++ [encoding: :bytewise])

    assert Param.set(gcs, {1, 1}, "N", 1 <<< 31, @int32, encoding: :bytewise) ==
             {:error, {:out_of_range, 1 <<< 31}}
  end

  test "bytewise values whose bits are a NaN float are read from the raw bytes" do
    assert Param.from_wire(:nan, <<-12_345::little-signed-32>>, @int32, :bytewise) == -12_345
    assert Param.from_wire(:nan, <<200, 0, 0, 0>>, 1, :bytewise) == 200
  end

  test "a list fills the gaps in the stream index by index" do
    {gcs, v} = Vehicle.pair()
    params = for i <- 0..9, do: {"P#{i}", i * 1.0, @real32}
    vehicle(v, params, MapSet.new([0, 4, 9]))

    assert {:ok, list} = Param.list(gcs, {1, 1}, @fast)
    assert Enum.map(list, & &1.name) == Enum.map(0..9, &"P#{&1}")
    assert Enum.map(list, & &1.value) == Enum.map(0..9, &(&1 * 1.0))
  end

  test "PARAM_ERROR ends the wait" do
    {gcs, v} = Vehicle.pair()
    test = self()

    Vehicle.script(v, nil, fn %Common.ParamRequestRead{param_id: name}, _, s ->
      send(test, :asked)

      {%Common.ParamError{
         target_system: 255,
         target_component: 190,
         param_id: name,
         param_index: -1,
         error: 1
       }, s}
    end)

    assert Param.read(gcs, {1, 1}, "NOPE", @fast) ==
             {:error, {:param_error, :mav_param_error_does_not_exist}}

    assert_received :asked
    refute_received :asked
  end

  test "set reads the value back from a target that does not answer PARAM_SET" do
    {gcs, v} = Vehicle.pair()

    Vehicle.script(v, 0.0, fn
      %Common.ParamSet{param_value: value}, _, _ ->
        {[], value}

      %Common.ParamRequestRead{param_id: "A"}, _, value ->
        {%Common.ParamValue{
           param_id: "A",
           param_value: value,
           param_type: @real32,
           param_count: 1
         }, value}
    end)

    assert {:ok, %{name: "A", value: 2.5}} =
             Param.set(gcs, {1, 1}, "A", 2.5, @real32, @fast ++ [retries: 1])
  end

  test "a list for every component keeps each component's parameters apart" do
    {gcs, v} = Vehicle.pair()

    value = fn compid, index ->
      {%Common.ParamValue{
         param_id: "C#{compid}_#{index}",
         param_value: index * 1.0,
         param_type: @real32,
         param_count: 2,
         param_index: index
       }, compid: compid}
    end

    Vehicle.script(v, nil, fn
      # Component 100 leaves its index 1 out of the stream.
      %Common.ParamRequestList{target_component: 0}, _, s ->
        {[value.(1, 0), value.(100, 0), value.(1, 1)], s}

      %Common.ParamRequestRead{param_index: i, target_component: c}, _, s ->
        {value.(c, i), s}
    end)

    assert {:ok, list} = Param.list(gcs, {1, 0}, @fast)

    assert Enum.map(list, &{&1.component, &1.name}) ==
             [{1, "C1_0"}, {1, "C1_1"}, {100, "C100_0"}, {100, "C100_1"}]
  end

  test "names are 7-bit ASCII" do
    {gcs, _v} = Vehicle.pair()
    assert Param.read(gcs, {1, 1}, "CAFÉ") == {:error, :name_not_ascii}
  end

  test "a name longer than 16 bytes is refused" do
    {gcs, _v} = Vehicle.pair()
    assert Param.read(gcs, {1, 1}, String.duplicate("X", 17)) == {:error, :name_too_long}
  end
end
