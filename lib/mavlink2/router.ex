defmodule MAVLink2.Router do
  @moduledoc """
  Forwards frames between `MAVLink2.Link`s, by MAVLink's routing rules:

  - Each frame received teaches the router that its sender, `{sysid,
    compid}`, is reachable through the link it arrived on.
  - A broadcast goes out on every other link: a frame with no target, or a
    target system of 0. A frame whose id the dialect lacks (a link with
    `unknown: :keep`) is a broadcast.
  - A frame for a system goes out on the other links where that system has
    been seen; with a target component other than 0, where that component
    of it has been seen. A target not seen on any other link goes nowhere.
  - Nothing goes back out on the link it came in on.

  The target is the header's `target_sysid` when present, else the
  payload's `target_system` and `target_component`, found through the
  dialect's `target_offsets/1` (`MAVLink2.Dialect`).

  Frames go out with `MAVLink2.Link.forward/2`, unchanged. The router is a
  subscriber like any other: an application on the same links sees every
  frame too, and decides for itself what is addressed to it.

  Options:

  | | |
  | --- | --- |
  | `:links` | the links to route between, as pids or registered names (required) |
  | `:name` | registered name |

  The router stops when one of its links does, so a supervisor restarting
  both resubscribes it.
  """

  use GenServer

  alias MAVLink2.{Frame, Link}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Where each sender has been seen: `%{{sysid, compid} => [link]}`."
  @spec routes(GenServer.server()) :: %{{non_neg_integer(), 0..255} => [GenServer.server()]}
  def routes(router), do: GenServer.call(router, :routes)

  @doc """
  The target of `frame`: `:broadcast`, or `{system, component}`, where
  component 0 is any component of the system.
  """
  @spec target(Frame.t(), module()) :: :broadcast | {pos_integer(), 0..255}
  def target(%Frame{known: false}, _dialect), do: :broadcast

  def target(%Frame{} = frame, dialect) do
    {sys_at, comp_at} =
      if Code.ensure_loaded?(dialect) and function_exported?(dialect, :target_offsets, 1),
        do: dialect.target_offsets(frame.msgid),
        else: {nil, nil}

    case {frame.target_sysid || byte_at(frame.payload, sys_at), byte_at(frame.payload, comp_at)} do
      {nil, _} -> :broadcast
      {0, _} -> :broadcast
      {system, component} -> {system, component || 0}
    end
  end

  defp byte_at(_payload, nil), do: nil
  defp byte_at(payload, at) when at < byte_size(payload), do: :binary.at(payload, at)
  defp byte_at(_payload, _at), do: 0

  @impl true
  def init(opts) do
    links = Keyword.fetch!(opts, :links)

    # A link's messages name it by its registered name, or its pid when it
    # has none; either way, map back to the term the router was given.
    aliases =
      for link <- links,
          key <- Enum.uniq([link, GenServer.whereis(link)]),
          into: %{},
          do: {key, link}

    for link <- links do
      :ok = Link.subscribe(link)
      Process.monitor(GenServer.whereis(link))
    end

    dialects = Map.new(links, &{&1, Link.info(&1).dialect})
    {:ok, %{links: links, aliases: aliases, dialects: dialects, routes: %{}}}
  end

  @impl true
  def handle_call(:routes, _from, state),
    do: {:reply, Map.new(state.routes, fn {k, v} -> {k, MapSet.to_list(v)} end), state}

  @impl true
  def handle_info({Link, from, %Frame{} = frame}, state) do
    from = Map.get(state.aliases, from, from)
    sender = {frame.sysid, frame.compid}
    routes = Map.update(state.routes, sender, MapSet.new([from]), &MapSet.put(&1, from))
    state = %{state | routes: routes}

    for out <- destinations(target(frame, state.dialects[from]), from, state),
        do: Link.forward(out, frame)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state),
    do: {:stop, {:link_down, reason}, state}

  defp destinations(:broadcast, from, state), do: List.delete(state.links, from)

  defp destinations({system, component}, from, state) do
    for {{sysid, compid}, links} <- state.routes,
        sysid == system and (component == 0 or compid == component),
        link <- links,
        link != from,
        uniq: true,
        do: link
  end
end
