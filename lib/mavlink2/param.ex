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
  @error 345

  @type encoding :: :cast | :bytewise

  @type param :: %{
          name: String.t(),
          value: number() | :nan | :infinity | :neg_infinity,
          type: atom() | integer(),
          index: non_neg_integer(),
          count: non_neg_integer(),
          component: 0..255
        }

  @doc """
  Reads one parameter, by name or by index. A target that answers with
  `PARAM_ERROR` (a dialect with it, such as current `common.xml`) ends the
  wait with `{:error, {:param_error, error}}`, `error` a `MAV_PARAM_ERROR`
  atom such as `:mav_param_error_does_not_exist`.
  """
  @spec read(GenServer.server(), MAVLink2.target(), String.t() | non_neg_integer(), keyword()) ::
          {:ok, param()} | {:error, term()}
  def read(link, target, name_or_index, opts \\ []) do
    where = "MAVLink2.Param.read/4"
    validate_opts!(opts, where)
    {id, index} = key!(name_or_index, where)

    Service.run(link, target, where, fn ctx ->
      read_one(ctx, opts, id, index)
    end)
  end

  defp read_one(ctx, opts, id, index) do
    matches = if id == "", do: &(&1.index == index), else: &(&1.name == id)
    ask(ctx, opts, fn _ -> request_read(ctx, id, index) end, matches, {id, index})
  end

  @doc """
  Sets a parameter and returns the value the target reports back, which
  is what it now holds: compare it with `value` to see whether the target
  took it. `type` is a `MAV_PARAM_TYPE` atom or value. `PARAM_ERROR` ends
  the wait as for `read/4`.

  The protocol has the target answer with `PARAM_VALUE`. For one that does
  not, as the MAVLink guide notes of ArduPilot, the value is read back by
  name once the retries run out.
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
  def set(link, target, name, value, type, opts \\ []) do
    where = "MAVLink2.Param.set/6"
    validate_opts!(opts, where)
    {id, -1} = key!(name, where)

    unless is_number(value) do
      raise ArgumentError, "#{where}: the value must be a number, got: #{inspect(value)}"
    end

    Service.run(link, target, where, fn ctx ->
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

      case ask(ctx, opts, send_fun, &(&1.name == id), {id, -1}) do
        {:error, :timeout} -> read_one(ctx, opts, id, -1)
        result -> result
      end
    end)
  end

  @doc """
  Every parameter, in component and index order. With target compid 0
  (`MAV_COMP_ID_ALL`), every component of the system that answers is
  included, each parameter with its `component`.

  After the stream goes quiet, each missing index is asked for on its own.
  `{:error, {:missing, [{component, index}]}}` when some never arrive. A
  `PARAM_VALUE` whose index is not below its count is not part of the list
  (PX4 sends its parameter-set hash at index 32767).
  """
  @spec list(GenServer.server(), MAVLink2.target(), keyword()) ::
          {:ok, [param()]} | {:error, term()}
  def list(link, target, opts \\ []) do
    where = "MAVLink2.Param.list/3"
    validate_opts!(opts, where)

    Service.run(link, target, where, fn ctx ->
      send_fun = fn _ -> Service.send_to(ctx, @request_list, :param_request_list, []) end

      with {:ok, first} <-
             Service.request(retries(opts), send_fun, fn ->
               await_value(ctx, opts, &listed?/1, nil)
             end) do
        got = collect(ctx, opts, %{{first.component, first.index} => first})
        fill(ctx, opts, got)
      end
    end)
  end

  defp listed?(p), do: p.index < p.count

  defp collect(ctx, opts, got) do
    case await_value(ctx, opts, &listed?/1, nil) do
      {:ok, p} -> collect(ctx, opts, Map.put(got, {p.component, p.index}, p))
      :timeout -> got
    end
  end

  defp fill(ctx, opts, got) do
    counts = for {{component, _}, p} <- got, into: %{}, do: {component, p.count}
    wanted = for {component, count} <- counts, index <- 0..(count - 1)//1, do: {component, index}

    got =
      Enum.reduce(wanted, got, fn {component, index} = key, got ->
        if Map.has_key?(got, key) do
          got
        else
          {sysid, _} = ctx.target
          ctx = %{ctx | target: {sysid, component}}

          case read_one(ctx, opts, "", index) do
            {:ok, p} -> Map.put(got, key, p)
            {:error, _} -> got
          end
        end
      end)

    case Enum.reject(wanted, &Map.has_key?(got, &1)) do
      [] -> {:ok, got |> Map.values() |> Enum.sort_by(&{&1.component, &1.index})}
      missing -> {:error, {:missing, missing}}
    end
  end

  defp request_read(ctx, id, index) do
    Service.send_to(ctx, @request_read, :param_request_read, param_id: id, param_index: index)
  end

  # Sends until a PARAM_VALUE `matches`, or the target refuses `key`
  # ({id, index}) with PARAM_ERROR.
  defp ask(ctx, opts, send_fun, matches, key) do
    case Service.request(retries(opts), send_fun, fn -> await_value(ctx, opts, matches, key) end) do
      {:ok, {:param_error, _} = error} -> {:error, error}
      result -> result
    end
  end

  defp await_value(ctx, opts, matches, key) do
    mod = Service.message!(ctx, @value, :param_value)

    Service.await(ctx, Keyword.get(opts, :timeout, 1000), fn
      %{msgid: @value} = frame, message ->
        p =
          param(
            ctx,
            frame,
            message,
            Service.raw(mod, frame.payload, :param_value),
            encoding(opts)
          )

        if matches.(p), do: {:ok, p}, else: :skip

      %{msgid: @error} = frame, message ->
        if key != nil and refuses?(key, message) and Service.for_me?(ctx, frame, message),
          do: {:ok, {:param_error, Service.entry(ctx, :mav_param_error, message.error)}},
          else: :skip

      _frame, _message ->
        :skip
    end)
  end

  defp refuses?({"", index}, message), do: message.param_index == index
  defp refuses?({id, _}, message), do: message.param_id == id

  defp param(ctx, frame, message, raw, encoding) do
    %{
      name: message.param_id,
      value: from_wire(message.param_value, raw, message.param_type, encoding),
      type: Service.entry(ctx, :mav_param_type, message.param_type),
      index: message.param_index,
      count: message.param_count,
      component: frame.compid
    }
  end

  defp validate_opts!(opts, where) do
    MAVLink2.Options.validate!(
      opts,
      [encoding: {:in, [:cast, :bytewise]}, timeout: :timeout, retries: :non_neg_integer],
      where
    )
  end

  # Names are up to 16 bytes of 7-bit ASCII; indices fit an int16.
  defp key!(name, where) when is_binary(name) do
    cond do
      name == "" ->
        raise ArgumentError, "#{where}: the parameter name is empty"

      byte_size(name) > 16 ->
        raise ArgumentError,
              "#{where}: parameter names are at most 16 bytes, got #{byte_size(name)}: #{inspect(name)}"

      not for(<<c <- name>>, reduce: true, do: (ok -> ok and c < 128)) ->
        raise ArgumentError, "#{where}: parameter names are 7-bit ASCII, got: #{inspect(name)}"

      true ->
        {name, -1}
    end
  end

  defp key!(index, _where) when is_integer(index) and index in 0..32_767, do: {"", index}

  defp key!(other, where) do
    raise ArgumentError,
          "#{where}: a parameter is a name (a string of up to 16 ASCII bytes, such as " <>
            "\"SYSID_THISMAV\") or an index from 0 to 32767; got: #{inspect(other)}"
  end

  defp retries(opts), do: Keyword.get(opts, :retries, 3)

  defp encoding(opts), do: Keyword.get(opts, :encoding, :cast)

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
