defmodule MAVLink2.Mission do
  @moduledoc """
  MAVLink's mission protocol: upload, download and clear a mission, geofence
  or rally point list.

      items = [
        [command: :mav_cmd_nav_takeoff, frame: :mav_frame_global_relative_alt, z: 20.0],
        [command: :mav_cmd_nav_waypoint, frame: :mav_frame_global_relative_alt,
         x: 473_977_420, y: 85_455_940, z: 30.0, autocontinue: 1]
      ]

      MAVLink2.Mission.upload(link, {1, 1}, items)
      #=> {:ok, opaque_id}

  The link's dialect must have the messages (`common.xml` does). `target`
  is `{sysid, compid}`.

  An item has `MISSION_ITEM_INT`'s fields other than the target, `seq` and
  `mission_type`: `:frame` (a `MAV_FRAME` atom or value), `:command` (a
  `MAV_CMD` atom or value), `:current`, `:autocontinue`, `:param1`..`:param4`,
  `:x`, `:y` (integers: degrees × 10^7 for a global frame, metres × 10^4
  for a local one) and `:z`; each defaults to 0. The `_INT` global frames
  are superseded by their plain counterparts (`:mav_frame_global_relative_alt`
  for `:mav_frame_global_relative_alt_int`), which mean the same here.

  Uploading sends `MISSION_COUNT` and then each item the target asks for,
  by `MISSION_REQUEST_INT` or the deprecated `MISSION_REQUEST` (answered
  with `MISSION_ITEM_INT` either way), until its `MISSION_ACK`. Downloading
  asks for the count and then each item by `MISSION_REQUEST_INT`, accepts
  the deprecated `MISSION_ITEM` in reply (its float positions scaled to
  integers), and acks the whole. When the target goes quiet, the last
  message is sent again, up to `:retries` times in a row; after that the
  operation is cancelled with a `MISSION_ACK` of
  `MAV_MISSION_OPERATION_CANCELLED` and returns `{:error, :timeout}`.

  `upload/4` returns `{:ok, opaque_id}` and `download/3` `{:ok, items,
  opaque_id}`: the plan's id from the target's `MISSION_ACK` or
  `MISSION_COUNT`, to compare with `MISSION_CURRENT` later, or `nil` for a
  dialect or target without it.

  Options:

  | | |
  | --- | --- |
  | `:mission_type` | a `MAV_MISSION_TYPE` atom or value (default `:mav_mission_type_mission`) |
  | `:timeout` | ms to wait for the target before sending again (default 1500) |
  | `:item_timeout` | the same, for a plan item (default 250) |
  | `:retries` | times in a row to send again (default 5) |

  A refusal is `{:error, {:mission_result, result}}`, with `result` the
  `MAV_MISSION_RESULT` entry atom (`:mav_mission_no_space`, ...).
  """

  alias MAVLink2.Service

  @item 39
  @request 40
  @request_list 43
  @count 44
  @clear_all 45
  @ack 47
  @request_int 51
  @item_int 73

  @item_fields [
    :frame,
    :command,
    :current,
    :autocontinue,
    :param1,
    :param2,
    :param3,
    :param4,
    :x,
    :y,
    :z
  ]

  @type item :: keyword() | map()

  @doc "Uploads `items`, replacing the target's list of that mission type."
  @spec upload(GenServer.server(), MAVLink2.target(), [item()], keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def upload(link, target, items, opts \\ []) do
    Service.run(link, target, fn ctx ->
      type = mission_type(ctx, opts)
      items = items |> Enum.map(&item_fields(ctx, &1)) |> List.to_tuple()

      send_count = fn ->
        send_to(ctx, @count, :mission_count, count: tuple_size(items), mission_type: type)
      end

      send_count.()
      upload_loop(ctx, opts, type, items, {send_count, timeout(opts)}, 0)
    end)
  end

  defp upload_loop(ctx, opts, type, items, {resend, wait} = last, quiet) do
    reply =
      Service.await(ctx, wait, fn frame, message ->
        cond do
          not mine?(ctx, frame, message, type) ->
            :skip

          frame.msgid in [@request_int, @request] and message.seq < tuple_size(items) ->
            {:ok, {:request, message.seq}}

          frame.msgid == @ack ->
            {:ok, {:ack, message.type, Map.get(message, :opaque_id)}}

          true ->
            :skip
        end
      end)

    retries = retries(opts)

    case reply do
      {:ok, {:request, seq}} ->
        send_item = fn ->
          fields = [seq: seq, mission_type: type] ++ elem(items, seq)
          send_to(ctx, @item_int, :mission_item_int, fields)
        end

        send_item.()
        upload_loop(ctx, opts, type, items, {send_item, item_timeout(opts)}, 0)

      {:ok, {:ack, result, opaque_id}} ->
        with :ok <- result(ctx, result), do: {:ok, opaque_id}

      :timeout when quiet < retries ->
        resend.()
        upload_loop(ctx, opts, type, items, last, quiet + 1)

      :timeout ->
        cancel(ctx, type)
        {:error, :timeout}
    end
  end

  @doc "Downloads the target's list of that mission type."
  @spec download(GenServer.server(), MAVLink2.target(), keyword()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, term()}
  def download(link, target, opts \\ []) do
    Service.run(link, target, fn ctx ->
      type = mission_type(ctx, opts)
      Service.message!(ctx, @item_int, :mission_item_int)

      %{count: count} =
        count_message =
        reply!(
          ctx,
          ask(
            ctx,
            timeout(opts),
            opts,
            type,
            fn -> send_to(ctx, @request_list, :mission_request_list, mission_type: type) end,
            fn frame, message -> if frame.msgid == @count, do: {:ok, message}, else: :skip end
          )
        )

      items =
        for seq <- 0..(count - 1)//1 do
          reply!(
            ctx,
            ask(
              ctx,
              item_timeout(opts),
              opts,
              type,
              fn ->
                send_to(ctx, @request_int, :mission_request_int, seq: seq, mission_type: type)
              end,
              fn frame, message ->
                if frame.msgid in [@item_int, @item] and message.seq == seq,
                  do: {:ok, item(ctx, frame.msgid, message)},
                  else: :skip
              end
            )
          )
        end

      send_to(ctx, @ack, :mission_ack, type: accepted(ctx), mission_type: type)
      {:ok, items, Map.get(count_message, :opaque_id)}
    end)
  end

  @doc "Clears the target's list of that mission type."
  @spec clear(GenServer.server(), MAVLink2.target(), keyword()) :: :ok | {:error, term()}
  def clear(link, target, opts \\ []) do
    Service.run(link, target, fn ctx ->
      type = mission_type(ctx, opts)
      send_fun = fn -> send_to(ctx, @clear_all, :mission_clear_all, mission_type: type) end

      {:ack, ack} =
        ask(ctx, timeout(opts), opts, type, send_fun, fn _frame, _message -> :skip end)

      result(ctx, ack)
    end)
  end

  # Sends with send_fun until `accept` takes a reply or the target acks:
  # {:reply, value} or {:ack, result}. Out of retries, cancels the
  # operation.
  defp ask(ctx, wait, opts, type, send_fun, accept) do
    await = fn ->
      Service.await(ctx, wait, fn frame, message ->
        cond do
          not mine?(ctx, frame, message, type) -> :skip
          frame.msgid == @ack -> {:ok, {:ack, message.type}}
          true -> with({:ok, v} <- accept.(frame, message), do: {:ok, {:reply, v}})
        end
      end)
    end

    case Service.request(retries(opts), fn _ -> send_fun.() end, await) do
      {:ok, reply} ->
        reply

      {:error, :timeout} ->
        cancel(ctx, type)
        throw({:error, :timeout})
    end
  end

  defp cancel(ctx, type) do
    cancelled = ctx.dialect.enum_value(:mav_mission_result, :mav_mission_operation_cancelled)
    send_to(ctx, @ack, :mission_ack, type: cancelled, mission_type: type)
  end

  # A reply, or the target's ack ending the exchange early as an error.
  defp reply!(_ctx, {:reply, value}), do: value
  defp reply!(ctx, {:ack, result}), do: throw({:error, {:mission_result, entry(ctx, result)}})

  defp result(ctx, result) do
    if result == accepted(ctx), do: :ok, else: {:error, {:mission_result, entry(ctx, result)}}
  end

  defp accepted(ctx), do: ctx.dialect.enum_value(:mav_mission_result, :mav_mission_accepted)
  defp entry(ctx, result), do: Service.entry(ctx, :mav_mission_result, result)

  defp mine?(ctx, frame, message, type),
    do: Service.for_me?(ctx, frame, message) and Map.get(message, :mission_type, type) == type

  defp send_to(ctx, msgid, name, fields), do: Service.send_to(ctx, msgid, name, fields)

  defp item_fields(ctx, item) do
    item = Map.new(item)

    case Map.keys(item) -- @item_fields do
      [] -> :ok
      unknown -> throw({:error, {:unknown_fields, unknown}})
    end

    item
    |> Map.update(:frame, 0, &Service.value!(ctx, :mav_frame, &1))
    |> Map.update(:command, 0, &Service.value!(ctx, :mav_cmd, &1))
    |> Enum.to_list()
  end

  defp item(ctx, msgid, message) do
    frame = Service.entry(ctx, :mav_frame, message.frame)

    message
    |> Map.take(@item_fields)
    |> scale(msgid, frame)
    |> Map.put(:frame, frame)
    |> Map.update!(:command, &Service.entry(ctx, :mav_cmd, &1))
  end

  # MISSION_ITEM carries x and y as floats: degrees for a global frame,
  # metres for a local one. MISSION_ITEM_INT scales them to integers by 10^7
  # and 10^4.
  defp scale(item, @item_int, _frame), do: item

  defp scale(item, @item, frame) do
    factor =
      cond do
        is_atom(frame) and String.starts_with?(Atom.to_string(frame), "mav_frame_global") -> 1.0e7
        frame in [:mav_frame_mission, 2] -> 1
        true -> 1.0e4
      end

    item
    |> Map.update!(:x, &scaled(&1, factor))
    |> Map.update!(:y, &scaled(&1, factor))
  end

  defp scaled(v, factor) when is_number(v), do: round(v * factor)
  defp scaled(_not_a_number, _factor), do: 0

  defp mission_type(ctx, opts),
    do: Service.value!(ctx, :mav_mission_type, Keyword.get(opts, :mission_type, 0))

  defp timeout(opts), do: Keyword.get(opts, :timeout, 1500)
  defp item_timeout(opts), do: Keyword.get(opts, :item_timeout, 250)
  defp retries(opts), do: Keyword.get(opts, :retries, 5)
end
