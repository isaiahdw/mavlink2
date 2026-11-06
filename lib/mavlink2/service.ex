defmodule MAVLink2.Service do
  @moduledoc false
  # What MAVLink2.Command, MAVLink2.Param and MAVLink2.Mission share: a
  # transaction in its own process, so the frames it subscribes to never
  # reach the caller's mailbox; sending a message to a target; and waiting
  # for a reply from it.

  alias MAVLink2.{Frame, Link}

  defstruct [:link, :dialect, :me, :target, :where]

  @type t :: %__MODULE__{
          link: GenServer.server(),
          dialect: module(),
          me: target(),
          target: target(),
          where: String.t()
        }

  @type target :: MAVLink2.target()

  @doc """
  Runs `fun` with a context for `link` and `target` in a process subscribed
  to the link, and returns its result. A thrown `{:error, reason}` is
  returned; an exception is raised again in the caller, so a mistake in
  how the service was called reads as one. `where` names the public
  function, for messages.
  """
  @spec run(GenServer.server(), term(), String.t(), (t() -> result)) :: result | {:error, term()}
        when result: term()
  def run(link, target, where, fun) do
    target = MAVLink2.Options.target!(target, where)
    info = Link.info(link)

    ctx = %__MODULE__{
      link: link,
      dialect: info.dialect,
      me: {info.sysid, info.compid},
      target: target,
      where: where
    }

    task =
      Task.async(fn ->
        :ok = Link.subscribe(link)

        try do
          {:ok, fun.(ctx)}
        rescue
          e -> {:raise, e, __STACKTRACE__}
        catch
          {:error, _} = error -> {:ok, error}
        end
      end)

    case Task.await(task, :infinity) do
      {:ok, result} -> result
      {:raise, e, stacktrace} -> reraise e, stacktrace
    end
  end

  @doc "The message module for `msgid`, or a throw the caller turns into an error."
  @spec message!(t(), non_neg_integer(), atom()) :: module()
  def message!(%__MODULE__{dialect: dialect}, msgid, name) do
    if Code.ensure_loaded?(dialect) and function_exported?(dialect, :message, 1) and
         dialect.message(msgid),
       do: dialect.message(msgid),
       else: throw({:error, {:unsupported_message, name}})
  end

  @doc """
  Sends `fields` as message `msgid` to the target. A target system over 255
  goes in the header, with 255 in the payload. `raw` is `[{field, bytes}]`
  written over fields' encoded bytes.
  """
  @spec send_to(t(), non_neg_integer(), atom(), keyword(), [{atom(), binary()}]) :: :ok
  def send_to(%__MODULE__{target: {sysid, compid}} = ctx, msgid, name, fields, raw \\ []) do
    mod = message!(ctx, msgid, name)
    narrow = if sysid > 255, do: 255, else: sysid
    message = struct!(mod, [target_system: narrow, target_component: compid] ++ fields)
    {^msgid, payload} = ctx.dialect.encode(message)
    payload = Enum.reduce(raw, payload, fn {field, bytes}, p -> put_raw(mod, p, field, bytes) end)
    opts = if sysid > 255, do: [target_sysid: sysid], else: []

    case Link.send_message(ctx.link, msgid, payload, opts) do
      :ok -> :ok
      {:error, reason} -> throw({:error, reason})
    end
  end

  @doc "The encoded bytes of `field` in `payload`, a message of `mod`."
  @spec raw(module(), binary(), atom()) :: binary()
  def raw(mod, payload, field) do
    {at, size} = place(mod, field)
    binary_part(payload, at, size)
  end

  defp put_raw(mod, payload, field, bytes) do
    {at, size} = place(mod, field)
    ^size = byte_size(bytes)
    <<head::binary-size(^at), _::binary-size(^size), tail::binary>> = payload
    head <> bytes <> tail
  end

  defp place(mod, field) do
    Enum.reduce_while(mod.layout(), 0, fn {name, type, n}, at ->
      size = MAVLink2.XML.size(type) * (n || 1)
      if name == field, do: {:halt, {at, size}}, else: {:cont, at + size}
    end)
  end

  @doc """
  Waits up to `ms` for a frame from the target whose decoded message `fun`
  accepts, returning `{:ok, value}` or `:timeout`. `fun` returns `{:ok,
  value}` or `:skip`.
  """
  @spec await(t(), non_neg_integer(), (MAVLink2.Frame.t(), struct() -> {:ok, v} | :skip)) ::
          {:ok, v} | :timeout
        when v: term()
  def await(%__MODULE__{} = ctx, ms, fun) do
    deadline = System.monotonic_time(:millisecond) + ms
    await_until(ctx, deadline, fun)
  end

  defp await_until(ctx, deadline, fun) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {Link, _link, %Frame{known: true} = frame} ->
        with true <- from_target?(ctx, frame),
             {:ok, message} <- ctx.dialect.decode(frame.msgid, frame.payload),
             {:ok, value} <- fun.(frame, message) do
          {:ok, value}
        else
          _ -> await_until(ctx, deadline, fun)
        end

      {Link, _link, %Frame{}} ->
        await_until(ctx, deadline, fun)
    after
      left -> :timeout
    end
  end

  defp from_target?(%{target: {sysid, compid}}, frame),
    do: frame.sysid == sysid and (compid == 0 or frame.compid == compid)

  @doc """
  True when a reply's own `target_system` and `target_component`, where it
  has them and they are not 0, name this end.
  """
  @spec for_me?(t(), MAVLink2.Frame.t(), map()) :: boolean()
  def for_me?(%__MODULE__{me: {sysid, compid}}, frame, message) do
    system = frame.target_sysid || Map.get(message, :target_system, 0)
    component = Map.get(message, :target_component, 0)
    system in [0, sysid] and component in [0, compid]
  end

  @doc """
  Sends with `send_fun` and waits with `await_fun`, sending again after each
  timeout, up to `retries` more times. `send_fun` gets the attempt number,
  from 0.
  """
  @spec request(
          non_neg_integer(),
          (non_neg_integer() -> :ok),
          (-> {:ok, v} | :timeout),
          non_neg_integer()
        ) :: {:ok, v} | {:error, :timeout}
        when v: term()
  def request(retries, send_fun, await_fun, attempt \\ 0) do
    :ok = send_fun.(attempt)

    case await_fun.() do
      {:ok, value} -> {:ok, value}
      :timeout when attempt < retries -> request(retries, send_fun, await_fun, attempt + 1)
      :timeout -> {:error, :timeout}
    end
  end

  @doc "An enum entry as an atom when the dialect has it, else the integer."
  @spec entry(t(), atom(), integer()) :: atom() | integer()
  def entry(%__MODULE__{dialect: d}, enum, value), do: d.enum_entry(enum, value) || value

  @doc "An enum value from an atom entry or an integer."
  @spec value!(t(), atom(), atom() | integer()) :: integer()
  def value!(_ctx, _enum, value) when is_integer(value), do: value

  def value!(%__MODULE__{dialect: d, where: where}, enum, entry) when is_atom(entry) do
    d.enum_value(enum, entry) ||
      MAVLink2.Options.unknown!(
        where,
        "#{String.upcase(to_string(enum))} entry",
        entry,
        Map.keys(d.enum(enum) || %{}),
        "#{enum}_"
      )
  end

  def value!(%__MODULE__{where: where}, enum, other) do
    raise ArgumentError,
          "#{where}: a #{String.upcase(to_string(enum))} value must be an entry atom, such as " <>
            ":#{enum}_..., or its integer; got: #{inspect(other)}"
  end
end
