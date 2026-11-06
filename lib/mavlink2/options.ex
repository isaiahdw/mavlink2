defmodule MAVLink2.Options do
  @moduledoc false
  # Option and argument checks for the public API. A mistake in how the API
  # is called raises ArgumentError naming the function, what was wrong and
  # what would be right, with the closest valid names for a misspelling.
  # Errors from the other end of a link are returned, not raised.

  @type type ::
          :boolean
          | :pos_integer
          | :non_neg_integer
          | :timeout
          | :byte
          | :id
          | :compid
          | :string
          | :pid
          | :atom
          | :module
          | :server
          | {:in, [term()]}
          | {:list, type()}
          | {:fun, arity()}
          | {:struct, module()}
          | {:or, [type()]}
          | :any

  @doc """
  Checks `opts` against `schema`, `[{name, type}]`, raising ArgumentError
  for anything that is not a keyword list, an unknown name, or a value of
  the wrong type. `required` names must be present.
  """
  @spec validate!(term(), keyword(type()), String.t(), [atom()]) :: keyword()
  def validate!(opts, schema, where, required \\ []) do
    keyword!(opts, where)

    for {name, value} <- opts do
      case Keyword.fetch(schema, name) do
        {:ok, type} -> check!(value, type, "#{where}: option #{inspect(name)}")
        :error -> unknown!(where, "option", name, Keyword.keys(schema))
      end
    end

    for name <- required, not Keyword.has_key?(opts, name) do
      raise ArgumentError, "#{where}: option #{inspect(name)} is required"
    end

    opts
  end

  @doc "Raises ArgumentError unless `opts` is a keyword list."
  @spec keyword!(term(), String.t()) :: :ok
  def keyword!(opts, where) do
    if Keyword.keyword?(opts),
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{where}: options must be a keyword list, such as [timeout: 1000], got: #{inspect(opts)}"
        )
  end

  @doc "Raises ArgumentError unless `value` is of `type`."
  @spec check!(term(), type(), String.t()) :: :ok
  def check!(value, type, what) do
    if valid?(value, type),
      do: :ok,
      else: raise(ArgumentError, "#{what} must be #{describe(type)}, got: #{inspect(value)}")
  end

  # Names other libraries and protocols use for these options.
  @synonyms %{
    baud: :speed,
    baudrate: :speed,
    baud_rate: :speed,
    rate: :speed,
    port: :device,
    path: :device,
    tty: :device,
    serial: :device,
    system_id: :sysid,
    sys_id: :sysid,
    source_system: :sysid,
    component_id: :compid,
    comp_id: :compid,
    source_component: :compid,
    key: :signing,
    secret_key: :signing,
    retry: :retries,
    max_retries: :retries,
    attempts: :retries,
    timeout_ms: :timeout,
    links_list: :links,
    type: :mission_type,
    cmd: :command
  }

  @doc """
  Raises ArgumentError for an unknown `name`, listing the closest of
  `known` first.
  """
  @spec unknown!(String.t(), String.t(), term(), [term()], String.t()) :: no_return()
  def unknown!(where, kind, name, known, prefix \\ "") do
    synonym = Map.get(@synonyms, name)
    suggestions = if synonym in known, do: [synonym], else: closest(name, known, prefix)

    hint =
      case suggestions do
        [] -> ""
        names -> " Did you mean #{Enum.map_join(names, " or ", &inspect/1)}?"
      end

    listing =
      if length(known) <= 30,
        do: " Known: #{Enum.map_join(Enum.sort(known), ", ", &inspect/1)}.",
        else: ""

    raise ArgumentError, "#{where}: unknown #{kind} #{inspect(name)}.#{hint}#{listing}"
  end

  @doc """
  Up to three of `known` closest to `name`, closest first, comparing what
  follows a shared `prefix` (an enum's name, for its entries).

  Besides spelling, a name counts as close when its words are all words of
  a known one (`arm` for `component_arm_disarm`), when one contains the
  other, or when its letters appear in order in a known one (`cmd` for
  `command`). Ties go to the shorter, then the first in order.
  """
  @spec closest(term(), [term()], String.t()) :: [term()]
  def closest(name, known, prefix \\ "") do
    strip = &String.replace_prefix(to_string(&1), prefix, "")
    target = strip.(name)

    known
    |> Enum.map(fn k -> {similarity(target, strip.(k)), k} end)
    |> Enum.filter(fn {score, _} -> score >= 0.8 end)
    |> Enum.sort_by(fn {score, k} -> {-score, String.length(to_string(k)), to_string(k)} end)
    |> Enum.take(3)
    |> Enum.map(fn {_, k} -> k end)
  end

  defp similarity("", _other), do: 0.0

  defp similarity(target, other) do
    words = &String.split(&1, "_", trim: true)

    cond do
      words.(target) -- words.(other) == [] -> 0.95
      String.contains?(other, target) or String.contains?(target, other) -> 0.9
      String.length(target) >= 2 and subsequence?(target, other) -> 0.85
      true -> String.jaro_distance(target, other)
    end
  end

  defp subsequence?(<<>>, _), do: true
  defp subsequence?(_, <<>>), do: false
  defp subsequence?(<<c::utf8, a::binary>>, <<c::utf8, b::binary>>), do: subsequence?(a, b)
  defp subsequence?(a, <<_::utf8, b::binary>>), do: subsequence?(a, b)

  @doc """
  Raises ArgumentError unless `target` is `{sysid, compid}`, sysid 1 to 32
  bits and compid 0 to 255.
  """
  @spec target!(term(), String.t()) :: MAVLink2.target()
  def target!({sysid, compid} = target, _where)
      when is_integer(sysid) and sysid in 1..0xFFFFFFFF and is_integer(compid) and
             compid in 0..255,
      do: target

  def target!(target, where) do
    raise ArgumentError,
          "#{where}: the target must be {sysid, compid}, sysid from 1 to 2^32-1 and compid " <>
            "from 0 to 255 (0 is any component), such as {1, 1} for an autopilot; got: " <>
            inspect(target)
  end

  @doc """
  Raises ArgumentError unless `module` is a loaded `MAVLink2.Dialect`.
  """
  @spec dialect!(term(), String.t()) :: module()
  def dialect!(module, where) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :crc_extra, 1) and
         function_exported?(module, :payload_length, 1) do
      module
    else
      raise ArgumentError,
            "#{where}: #{inspect(module)} is not a MAVLink2.Dialect. Define one with " <>
              "`defmodule MyDialect do use MAVLink2.Dialect.XML, file: \"priv/common.xml\" end` " <>
              "and pass the module"
    end
  end

  defp valid?(v, :boolean), do: is_boolean(v)
  defp valid?(v, :pos_integer), do: is_integer(v) and v > 0
  defp valid?(v, :non_neg_integer), do: is_integer(v) and v >= 0
  defp valid?(v, :timeout), do: is_integer(v) and v >= 0
  defp valid?(v, :byte), do: is_integer(v) and v in 0..255
  defp valid?(v, :id), do: is_integer(v) and v in 1..0xFFFFFFFF
  defp valid?(v, :compid), do: is_integer(v) and v in 1..255
  defp valid?(v, :string), do: is_binary(v)
  defp valid?(v, :pid), do: is_pid(v)
  defp valid?(v, :atom), do: is_atom(v)
  defp valid?(v, :module), do: is_atom(v) and Code.ensure_loaded?(v)

  defp valid?(v, :server),
    do: is_pid(v) or is_atom(v) or match?({:via, _, _}, v) or match?({:global, _}, v)

  defp valid?(v, {:in, values}), do: v in values
  defp valid?(v, {:list, type}), do: is_list(v) and Enum.all?(v, &valid?(&1, type))
  defp valid?(v, {:fun, arity}), do: is_function(v, arity)
  defp valid?(v, {:struct, mod}), do: is_struct(v, mod)
  defp valid?(v, {:or, types}), do: Enum.any?(types, &valid?(v, &1))
  defp valid?(_v, :any), do: true

  defp describe(:boolean), do: "true or false"
  defp describe(:pos_integer), do: "a positive integer"
  defp describe(:non_neg_integer), do: "a non-negative integer"
  defp describe(:timeout), do: "a non-negative integer of milliseconds"
  defp describe(:byte), do: "an integer from 0 to 255"
  defp describe(:id), do: "an integer from 1 to 2^32-1 (0 is the broadcast id)"
  defp describe(:compid), do: "an integer from 1 to 255 (0 is the broadcast id)"
  defp describe(:string), do: "a string"
  defp describe(:pid), do: "a pid"
  defp describe(:atom), do: "an atom"
  defp describe(:module), do: "a module"
  defp describe(:server), do: "a pid or registered name"
  defp describe({:in, values}), do: "one of #{Enum.map_join(values, ", ", &inspect/1)}"
  defp describe({:list, type}), do: "a list, each #{describe(type)}"
  defp describe({:fun, arity}), do: "a function of arity #{arity}"
  defp describe({:struct, mod}), do: "a %#{inspect(mod)}{}"
  defp describe({:or, types}), do: Enum.map_join(types, ", or ", &describe/1)
  defp describe(:any), do: "anything"
end
