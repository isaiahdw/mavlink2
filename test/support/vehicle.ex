defmodule MAVLink2.Vehicle do
  @moduledoc false
  # Two links joined through Loopback, a ground station (255, 190) and a
  # vehicle (1, 1), with the vehicle's side scripted by the test.

  alias MAVLink2.{Common, Link}
  alias MAVLink2.Transport.Loopback

  @doc "Starts both links under the test's supervisor; returns `{gcs, vehicle}`."
  def pair(vehicle_opts \\ []) do
    {dialect, vehicle_opts} = Keyword.pop(vehicle_opts, :dialect, Common)
    n = System.unique_integer([:positive])
    gcs = :"gcs_#{n}"
    vehicle = :"vehicle_#{n}"

    for {name, peer, opts} <- [
          {vehicle, gcs, Keyword.merge([sysid: 1, compid: 1], vehicle_opts)},
          {gcs, vehicle, [sysid: 255, compid: 190]}
        ] do
      opts = [name: name, dialect: dialect, transport: Loopback, peer: peer] ++ opts
      ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Link, opts}, id: name))
    end

    {gcs, vehicle}
  end

  @doc """
  Runs the vehicle's side: for each message the vehicle receives,
  `fun.(message, frame, state)` returns `{replies, state}`, each reply a
  message struct sent back from the vehicle. Returns once subscribed.
  """
  def script(vehicle, state, fun) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Link.subscribe(vehicle)
        send(test, :ready)
        loop(vehicle, Link.info(vehicle).dialect, state, fun)
      end)

    receive do
      :ready -> pid
    end
  end

  defp loop(vehicle, dialect, state, fun) do
    receive do
      {Link, _, frame} ->
        {:ok, message} = dialect.decode(frame.msgid, frame.payload)
        {replies, state} = fun.(message, frame, state)

        for reply <- List.wrap(replies) do
          {msgid, payload} = dialect.encode(reply)
          :ok = Link.send_message(vehicle, msgid, payload)
        end

        loop(vehicle, dialect, state, fun)
    end
  end
end
