defmodule MAVLink2.Command do
  @moduledoc """
  MAVLink's command protocol: a `COMMAND_LONG` or `COMMAND_INT` to a
  target, answered by `COMMAND_ACK`.

      MAVLink2.Command.long(link, {1, 1}, :mav_cmd_component_arm_disarm, [1.0])
      #=> {:ok, :mav_result_accepted, %MyDialect.CommandAck{...}}

  The link's dialect must have the messages (`common.xml` does). `target`
  is `{sysid, compid}`; compid 0 accepts the reply from any component of the
  system. `command` is a `MAV_CMD` entry atom or its value.

  With no ack in `:timeout`, the command is sent again, up to `:retries`
  more times; a `COMMAND_LONG` sent again has its `confirmation` counted up.
  An ack of `MAV_RESULT_IN_PROGRESS` stops the resending: each one goes to
  `:on_progress`, and the wait for the final ack restarts at
  `:progress_timeout`. `cancel/3` asks the target to stop a long-running
  command.

  Options:

  | | |
  | --- | --- |
  | `:timeout` | ms to wait for an ack before sending again (default 1000) |
  | `:retries` | times to send again (default 3) |
  | `:progress_timeout` | ms to wait after an in-progress ack (default 5000) |
  | `:on_progress` | called with each in-progress ack |

  Returns `{:ok, result, ack}`, with `result` the `MAV_RESULT` entry atom
  (`:mav_result_accepted`, `:mav_result_denied`, ...) and `ack` the decoded
  `COMMAND_ACK`, or `{:error, :timeout}`.
  """

  alias MAVLink2.Service

  @command_int 75
  @command_long 76
  @command_ack 77
  @command_cancel 80

  @doc "Sends `COMMAND_LONG` with up to seven `params` (the rest 0.0)."
  @spec long(GenServer.server(), MAVLink2.target(), atom() | integer(), [number()], keyword()) ::
          {:ok, atom() | integer(), struct()} | {:error, term()}
  def long(link, target, command, params \\ [], opts \\ []) when length(params) <= 7 do
    params = params ++ List.duplicate(0.0, 7 - length(params))
    fields = for {p, i} <- Enum.with_index(params, 1), do: {:"param#{i}", p}

    Service.run(link, target, fn ctx ->
      command = Service.value!(ctx, :mav_cmd, command)

      send_fun = fn attempt ->
        Service.send_to(
          ctx,
          @command_long,
          :command_long,
          [command: command, confirmation: min(attempt, 255)] ++ fields
        )
      end

      exchange(ctx, command, send_fun, opts)
    end)
  end

  @doc """
  Sends `COMMAND_INT`. `fields` are its fields other than the target and
  command: `:frame` (a `MAV_FRAME` atom or value), `:param1`..`:param4`,
  `:x`, `:y` (integers, degrees × 10^7 for a global frame), `:z`,
  `:current`, `:autocontinue`; each defaults to 0.
  """
  @spec int(GenServer.server(), MAVLink2.target(), atom() | integer(), keyword(), keyword()) ::
          {:ok, atom() | integer(), struct()} | {:error, term()}
  def int(link, target, command, fields \\ [], opts \\ []) do
    Service.run(link, target, fn ctx ->
      command = Service.value!(ctx, :mav_cmd, command)
      fields = Keyword.update(fields, :frame, 0, &Service.value!(ctx, :mav_frame, &1))
      fields = [command: command] ++ fields

      send_fun = fn _attempt -> Service.send_to(ctx, @command_int, :command_int, fields) end
      exchange(ctx, command, send_fun, opts)
    end)
  end

  @doc """
  Sends `COMMAND_CANCEL` for a long-running `command` the target is
  executing. It is not acked: the `long/5` or `int/5` call waiting on the
  command returns with the target's final ack, `:mav_result_cancelled` if
  it cancelled. A target that cannot cancel carries on, and one with
  nothing running ignores it. The dialect must have `COMMAND_CANCEL`
  (current `common.xml` does).
  """
  @spec cancel(GenServer.server(), MAVLink2.target(), atom() | integer()) ::
          :ok | {:error, term()}
  def cancel(link, target, command) do
    Service.run(link, target, fn ctx ->
      Service.send_to(ctx, @command_cancel, :command_cancel,
        command: Service.value!(ctx, :mav_cmd, command)
      )
    end)
  end

  defp exchange(ctx, command, send_fun, opts) do
    Service.message!(ctx, @command_ack, :command_ack)
    in_progress = ctx.dialect.enum_value(:mav_result, :mav_result_in_progress)
    await_ack = fn ms -> Service.await(ctx, ms, &ack(ctx, command, &1, &2)) end

    with {:ok, ack} <-
           Service.request(
             Keyword.get(opts, :retries, 3),
             send_fun,
             fn -> await_ack.(Keyword.get(opts, :timeout, 1000)) end
           ) do
      final(ctx, ack, in_progress, await_ack, opts)
    end
  end

  defp final(ctx, %{result: result} = ack, result, await_ack, opts) do
    if fun = opts[:on_progress], do: fun.(ack)

    case await_ack.(Keyword.get(opts, :progress_timeout, 5000)) do
      {:ok, next} -> final(ctx, next, result, await_ack, opts)
      :timeout -> {:error, :timeout}
    end
  end

  defp final(ctx, ack, _in_progress, _await_ack, _opts),
    do: {:ok, Service.entry(ctx, :mav_result, ack.result), ack}

  defp ack(ctx, command, frame, %{command: command} = message) do
    if frame.msgid == @command_ack and Service.for_me?(ctx, frame, message),
      do: {:ok, message},
      else: :skip
  end

  defp ack(_ctx, _command, _frame, _message), do: :skip
end
