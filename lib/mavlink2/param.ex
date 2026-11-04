defmodule MAVLink2.Param do
  @moduledoc """
  MAVLink's parameter protocol: read, set and list a component's
  parameters.

      MAVLink2.Param.read(link, {1, 1}, "SYSID_THISMAV")
      #=> {:ok, %{name: "SYSID_THISMAV", value: 1, type: :mav_param_type_int32, index: 802, count: 1203}}

  The link's dialect must have the messages (`common.xml` does). `target`
  is `{sysid, compid}`.

  `PARAM_VALUE` carries every value in a float. Autopilots put integers in
  it one of two ways, chosen with `:encoding`:

  | | |
  | --- | --- |
  | `:cast` (default) | the integer converted to a float, as ArduPilot does |
  | `:bytewise` | the integer's bytes in the float's, as PX4 does (`MAV_PROTOCOL_CAPABILITY_PARAM_ENCODE_BYTEWISE`) |

  A `REAL32` value is a float either way. 64-bit types do not fit and
  are returned as the float on the wire.

  Options:

  | | |
  | --- | --- |
  | `:encoding` | as above |
  | `:timeout` | ms to wait for a reply before asking again (default 1000); for `list/3`, the quiet time that ends the stream |
  | `:retries` | times to ask again (default 3) |

  A parameter is `%{name, value, type, index, count}`, `type` a
  `MAV_PARAM_TYPE` entry atom.
  """

  import Bitwise

  alias MAVLink2.Service

  @request_read 20
  @request_list 21
  @value 22
  @set 23

  @type encoding :: :cast | :bytewise

  @type param :: %{
          name: String.t(),
          value: number() | :nan | :infinity | :neg_infinity,
          type: atom() | integer(),
          index: non_neg_integer(),
          count: non_neg_integer()
        }

  @doc "Reads one parameter, by name or by index."
  @spec read(GenServer.server(), MAVLink2.target(), String.t() | non_neg_integer(), keyword()) ::
          {:ok, param()} | {:error, term()}
  def read(link, target, name_or_index, opts \\ []) do
    Service.run(link, target, fn ctx ->
      {id, index} = key!(name_or_index)
      send_fun = fn _ -> request_read(ctx, id, index) end
      matches = fn p -> if is_binary(name_or_index), do: p.name == id, else: p.index == index end
      Service.request(retries(opts), send_fun, fn -> await_value(ctx, opts, matches) end)
    end)
  end

  @doc """
  Sets a parameter and returns the value the target reports back, which
  is what it now holds: compare it with `value` to see whether the target
  took it. `type` is a `MAV_PARAM_TYPE` atom or value.
  """
  @spec set(
          GenServer.server(),
          MAVLink2.target(),
          String.t(),
          number(),
          atom() | integer(),
          keyword()
        ) ::
          {:ok, param()} | {:error, term()}
  def set(link, target, name, value, type, opts \\ []) when is_number(value) do
    Service.run(link, target, fn ctx ->
      {id, -1} = key!(name)
      type = Service.value!(ctx, :mav_param_type, type)
      {float, raw} = to_wire(value, type, encoding(opts))

      send_fun = fn _ ->
        Service.send_to(
          ctx,
          @set,
          :param_set,
          [param_id: id, param_value: float, param_type: type],
          raw
        )
      end

      Service.request(retries(opts), send_fun, fn ->
        await_value(ctx, opts, &(&1.name == id))
      end)
    end)
  end

  @doc """
  Every parameter, in index order. After the stream goes quiet, each
  missing index is asked for on its own. `{:error, {:missing, indices}}`
  when some never arrive.
  """
  @spec list(GenServer.server(), MAVLink2.target(), keyword()) ::
          {:ok, [param()]} | {:error, term()}
  def list(link, target, opts \\ []) do
    Service.run(link, target, fn ctx ->
      send_fun = fn _ -> Service.send_to(ctx, @request_list, :param_request_list, []) end

      with {:ok, first} <-
             Service.request(retries(opts), send_fun, fn -> await_value(ctx, opts, &listed?/1) end) do
        got = collect(ctx, opts, %{first.index => first})
        fill(ctx, opts, got, first.count)
      end
    end)
  end

  defp listed?(p), do: p.index < p.count

  defp collect(ctx, opts, got) do
    case await_value(ctx, opts, &listed?/1) do
      {:ok, p} -> collect(ctx, opts, Map.put(got, p.index, p))
      :timeout -> got
    end
  end

  defp fill(ctx, opts, got, count) do
    got =
      Enum.reduce(0..(count - 1)//1, got, fn index, got ->
        if Map.has_key?(got, index) do
          got
        else
          send_fun = fn _ -> request_read(ctx, "", index) end
          await = fn -> await_value(ctx, opts, &(&1.index == index)) end

          case Service.request(retries(opts), send_fun, await) do
            {:ok, p} -> Map.put(got, index, p)
            {:error, :timeout} -> got
          end
        end
      end)

    case Enum.reject(0..(count - 1)//1, &Map.has_key?(got, &1)) do
      [] -> {:ok, got |> Map.values() |> Enum.sort_by(& &1.index)}
      missing -> {:error, {:missing, missing}}
    end
  end

  defp request_read(ctx, id, index) do
    Service.send_to(ctx, @request_read, :param_request_read, param_id: id, param_index: index)
  end

  defp await_value(ctx, opts, matches) do
    mod = Service.message!(ctx, @value, :param_value)

    Service.await(ctx, Keyword.get(opts, :timeout, 1000), fn frame, message ->
      with @value <- frame.msgid,
           raw = Service.raw(mod, frame.payload, :param_value),
           p = param(ctx, message, raw, encoding(opts)),
           true <- matches.(p) do
        {:ok, p}
      else
        _ -> :skip
      end
    end)
  end

  defp param(ctx, message, raw, encoding) do
    %{
      name: message.param_id,
      value: from_wire(message.param_value, raw, message.param_type, encoding),
      type: Service.entry(ctx, :mav_param_type, message.param_type),
      index: message.param_index,
      count: message.param_count
    }
  end

  defp key!(name) when is_binary(name) and byte_size(name) <= 16, do: {name, -1}
  defp key!(name) when is_binary(name), do: throw({:error, :name_too_long})
  defp key!(index) when is_integer(index) and index in 0..32_767, do: {"", index}

  defp retries(opts), do: Keyword.get(opts, :retries, 3)

  defp encoding(opts) do
    case Keyword.get(opts, :encoding, :cast) do
      e when e in [:cast, :bytewise] -> e
      other -> throw({:error, {:unknown_encoding, other}})
    end
  end

  # MAV_PARAM_TYPE: 1 UINT8, 2 INT8, 3 UINT16, 4 INT16, 5 UINT32, 6 INT32,
  # 7 UINT64, 8 INT64, 9 REAL32, 10 REAL64.
  @integers %{
    1 => {8, :unsigned},
    2 => {8, :signed},
    3 => {16, :unsigned},
    4 => {16, :signed},
    5 => {32, :unsigned},
    6 => {32, :signed}
  }

  @doc """
  A wire float (and its raw 4 bytes) as the parameter's value, for a
  `MAV_PARAM_TYPE` value and an encoding.
  """
  @spec from_wire(float() | :nan | :infinity | :neg_infinity, binary(), integer(), encoding()) ::
          number() | :nan | :infinity | :neg_infinity
  def from_wire(float, raw, type, encoding)

  def from_wire(float, _raw, type, :cast) when is_float(float) and is_map_key(@integers, type),
    do: trunc(float)

  def from_wire(_float, raw, type, :bytewise) when is_map_key(@integers, type) do
    {bits, sign} = @integers[type]

    case {sign, raw} do
      {:signed, <<v::signed-little-size(^bits), _::binary>>} -> v
      {:unsigned, <<v::unsigned-little-size(^bits), _::binary>>} -> v
    end
  end

  def from_wire(float, _raw, _type, _encoding), do: float

  @doc """
  A value as the wire float and, for a bytewise integer, the raw bytes to
  put in its place.
  """
  @spec to_wire(number(), integer(), encoding()) :: {float(), [{:param_value, binary()}]}
  def to_wire(value, type, :bytewise) when is_map_key(@integers, type) and is_integer(value) do
    {bits, sign} = @integers[type]
    pad = 32 - bits
    half = 1 <<< (bits - 1)
    {min, max} = if sign == :signed, do: {-half, half - 1}, else: {0, 2 * half - 1}
    unless value >= min and value <= max, do: throw({:error, {:out_of_range, value}})

    {0.0, [param_value: <<value::little-size(bits), 0::size(pad)>>]}
  end

  def to_wire(value, _type, _encoding), do: {value / 1, []}
end
