defmodule MAVLink2.Service do
  @moduledoc false
  # What MAVLink2.Command, MAVLink2.Param and MAVLink2.Mission share: a
  # transaction in its own process, so the frames it subscribes to never
  # reach the caller's mailbox; sending a message to a target; and waiting
  # for a reply from it.

  alias MAVLink2.{Frame, Link}

  defstruct [:link, :dialect, :me, :target]

  @type target :: {sysid :: non_neg_integer(), compid :: 0..255}

  @doc """
  Runs `fun` with a context for `link` and `target` in a process subscribed
  to the link, and returns its result. A thrown `{:error, reason}` is
  returned.
  """
  def run(link, {sysid, compid} = target, fun)
      when is_integer(sysid) and sysid > 0 and is_integer(compid) and compid in 0..255 do
    task =
      Task.async(fn ->
        info = Link.info(link)
        :ok = Link.subscribe(link)

        ctx = %__MODULE__{
          link: link,
          dialect: info.dialect,
          me: {info.sysid, info.compid},
          target: target
        }

        try do
          fun.(ctx)
        catch
          {:error, _} = error -> error
        end
      end)

    Task.await(task, :infinity)
  end

  @doc "The message module for `msgid`, or a throw the caller turns into an error."
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
  def request(retries, send_fun, await_fun, attempt \\ 0) do
    :ok = send_fun.(attempt)

    case await_fun.() do
      {:ok, value} -> {:ok, value}
      :timeout when attempt < retries -> request(retries, send_fun, await_fun, attempt + 1)
      :timeout -> {:error, :timeout}
    end
  end

  @doc "An enum entry as an atom when the dialect has it, else the integer."
  def entry(%__MODULE__{dialect: d}, enum, value), do: d.enum_entry(enum, value) || value

  @doc "An enum value from an atom entry or an integer."
  def value!(_ctx, _enum, value) when is_integer(value), do: value

  def value!(%__MODULE__{dialect: d}, enum, entry) when is_atom(entry) do
    d.enum_value(enum, entry) || throw({:error, {:unknown_entry, enum, entry}})
  end
end
