defmodule MAVLink2.MisuseTest do
  # Each mistake in calling the API raises ArgumentError saying what is
  # wrong and what would be right.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MAVLink2.{Command, Common, Link, Mission, Param, Router, Signing, TestDialect, Vehicle}
  alias MAVLink2.Transport.Loopback

  defp raises(pattern, fun), do: assert_raise(ArgumentError, pattern, fun)

  # Hides a deliberately wrong value from the compiler's type checks.
  defp wrong(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  test "a misspelled or foreign option names the right one" do
    raises(~r/unknown option :baud\. Did you mean :speed\?/, fn ->
      Link.start_link(dialect: Common, device: "/dev/null", baud: 57_600)
    end)

    raises(~r/unknown option :system_id\. Did you mean :sysid\?/, fn ->
      Link.start_link(dialect: Common, transport: Loopback, system_id: 1)
    end)

    raises(~r/unknown option :dialekt\. Did you mean :dialect\?/, fn ->
      Link.start_link(dialekt: Common, transport: Loopback)
    end)
  end

  test "options must be a keyword list" do
    raises(~r/options must be a keyword list/, fn ->
      Link.start_link(wrong(%{dialect: Common}))
    end)
  end

  test "a link needs a dialect, and a serial link a device" do
    raises(~r/option :dialect is required/, fn -> Link.start_link(transport: Loopback) end)

    raises(~r/:device is required for MAVLink2.Transport.UART/, fn ->
      Link.start_link(dialect: Common)
    end)

    raises(~r/String is not a MAVLink2.Dialect\. Define one with `defmodule/, fn ->
      Link.start_link(dialect: String, transport: Loopback)
    end)
  end

  test "a signing key is 32 bytes" do
    raises(~r/32-byte binary.*got: 5 bytes/, fn -> Signing.new(wrong("short")) end)

    raises(~r/option :link_id must be an integer from 0 to 255/, fn ->
      Signing.new(:binary.copy(<<1>>, 32), link_id: 300)
    end)
  end

  test "send_message takes an id and payload, not a struct" do
    link = start_supervised!({Link, dialect: Common, transport: Loopback})

    raises(~r/use MAVLink2.Link.send\/2/, fn ->
      Link.send_message(link, wrong(%Common.Heartbeat{}), <<>>)
    end)

    raises(~r/message id must be an integer/, fn -> Link.send_message(link, wrong("0"), <<>>) end)
  end

  test "send takes a struct of the link's own dialect" do
    link = start_supervised!({Link, dialect: TestDialect, transport: Loopback})

    raises(
      ~r/MAVLink2.Common.Heartbeat is not a message of the link's dialect MAVLink2.TestDialect/,
      fn ->
        Link.send(link, %Common.Heartbeat{})
      end
    )

    common =
      start_supervised!(
        Supervisor.child_spec({Link, dialect: Common, transport: Loopback}, id: :c)
      )

    raises(~r/takes a message struct/, fn -> Link.send(common, wrong({0, <<>>})) end)

    raises(~r/field :type is 300, outside uint8/, fn ->
      Link.send(common, %Common.Heartbeat{type: 300})
    end)
  end

  test "subscribe's options are checked" do
    link = start_supervised!({Link, dialect: TestDialect, transport: Loopback})

    raises(~r/decode: true needs a dialect with decode\/2/, fn ->
      Link.subscribe(link, self(), decode: true)
    end)

    raises(~r/:only takes message ids or message modules/, fn ->
      Link.subscribe(link, self(), only: [:heartbeat])
    end)

    raises(~r/unknown option :filter\. Known: :decode, :only, :rejected/, fn ->
      Link.subscribe(link, self(), filter: [0])
    end)
  end

  test "a router needs its links" do
    raises(~r/option :links is required/, fn -> Router.start_link([]) end)
  end

  test "a target is {sysid, compid}" do
    {gcs, _vehicle} = Vehicle.pair()

    raises(~r/the target must be \{sysid, compid\}.*got: 1/, fn ->
      Command.long(gcs, wrong(1), 400)
    end)

    raises(~r/the target must be.*got: \{0, 1\}/, fn -> Param.read(gcs, {0, 1}, "A") end)
  end

  test "service options and arguments are checked before anything is sent" do
    {gcs, _vehicle} = Vehicle.pair()

    raises(~r/option :encoding must be one of :cast, :bytewise/, fn ->
      Param.read(gcs, {1, 1}, "A", encoding: :bytes)
    end)

    raises(~r/unknown option :type\. Did you mean :mission_type\?/, fn ->
      Mission.download(gcs, {1, 1}, type: :fence)
    end)

    raises(~r/params must be a list of up to 7 numbers/, fn ->
      Command.long(gcs, {1, 1}, 400, [1, 2, 3, 4, 5, 6, 7, 8])
    end)

    raises(~r/unknown MAV_FRAME entry :mav_frame_globl\. Did you mean :mav_frame_global/, fn ->
      Command.int(gcs, {1, 1}, 192, frame: :mav_frame_globl)
    end)

    raises(~r/a parameter is a name .* or an index/, fn ->
      Param.read(gcs, {1, 1}, wrong(:sysid))
    end)
  end

  test "a dialect's XML that is not there says where it looked" do
    raises(~r/cannot read "nope\.xml".*relative to the project root/, fn ->
      Code.compile_string("""
      defmodule MAVLink2.MisuseTest.Missing do
        use MAVLink2.Dialect.XML, file: "nope.xml"
      end
      """)
    end)
  end

  test "the test dialect is still accepted as a dialect" do
    assert start_supervised!({Link, dialect: TestDialect, transport: Loopback})
  end
end
