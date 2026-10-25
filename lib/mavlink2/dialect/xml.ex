defmodule MAVLink2.Dialect.XML do
  @moduledoc """
  A `MAVLink2.Dialect` generated at compile time from a MAVLink XML file
  and its includes:

      defmodule MyDialect do
        use MAVLink2.Dialect.XML, file: "priv/my_dialect.xml"
      end

  `:file` is relative to the project root, or absolute. The module
  recompiles when any of the XML files changes.

  Generated in the dialect module:

  | Function | |
  | --- | --- |
  | `crc_extra/1`, `payload_length/1` | the `MAVLink2.Dialect` callbacks |
  | `msgids/0`, `message/1` | every message id; the struct module for an id, or `nil` |
  | `encode/1` | a message struct to `{msgid, payload}` (untruncated; `MAVLink2.Frame` truncates) |
  | `decode/2` | `{msgid, payload}` to `{:ok, struct}`, or `{:error, {:unknown_msgid, id}}` |
  | `enum/1`, `enum_value/2`, `enum_entry/2` | an enum as `%{entry => value}`, an entry's value, a value's entry |

  And a module per message, named from the message (`COMMAND_LONG` is
  `MyDialect.CommandLong`): a struct with the XML's field names as written, each
  starting at its zero value (`MAVLink2.Codec`), and `msgid/0`,
  `crc_extra/0`, `layout/0`. A `uint8_t_mavlink_version` field starts at
  the XML's `<version>`. Enum and entry names are lowercase atoms
  (`:mav_cmd`, `:mav_cmd_component_arm_disarm`).
  """

  defmacro __using__(opts) do
    file = Keyword.fetch!(opts, :file)
    path = Path.expand(file, File.cwd!())
    defs = MAVLink2.XML.read!(path)
    dialect = __CALLER__.module

    resources = for f <- defs.files, do: quote(do: @external_resource(unquote(f)))
    message_modules = for m <- defs.messages, do: message_module(dialect, m, defs.version)
    by_id = for m <- defs.messages, do: {m.id, Module.concat(dialect, module_name(m.name))}

    enums =
      for {name, entries} <- defs.enums, into: %{} do
        {key(name), for({e, v} <- entries, into: %{}, do: {key(e), v})}
      end

    quote do
      @behaviour MAVLink2.Dialect
      unquote_splicing(resources)
      unquote_splicing(message_modules)

      @mavlink2_messages Map.new(unquote(by_id))
      @mavlink2_enums unquote(Macro.escape(enums))

      @impl MAVLink2.Dialect
      def crc_extra(msgid) do
        case @mavlink2_messages do
          %{^msgid => mod} -> mod.crc_extra()
          _ -> nil
        end
      end

      @impl MAVLink2.Dialect
      def payload_length(msgid) do
        case @mavlink2_messages do
          %{^msgid => mod} -> mod.payload_length()
          _ -> nil
        end
      end

      def msgids, do: @mavlink2_messages |> Map.keys() |> Enum.sort()
      def message(msgid), do: Map.get(@mavlink2_messages, msgid)

      def encode(%mod{} = message),
        do: {mod.msgid(), MAVLink2.Codec.encode(mod.layout(), message)}

      def decode(msgid, payload) do
        case @mavlink2_messages do
          %{^msgid => mod} -> {:ok, struct!(mod, MAVLink2.Codec.decode(mod.layout(), payload))}
          _ -> {:error, {:unknown_msgid, msgid}}
        end
      end

      def enum(name), do: Map.get(@mavlink2_enums, name)

      def enum_value(name, entry), do: @mavlink2_enums |> Map.get(name, %{}) |> Map.get(entry)

      def enum_entry(name, value) do
        @mavlink2_enums
        |> Map.get(name, %{})
        |> Enum.find_value(fn {e, v} -> if v == value, do: e end)
      end
    end
  end

  defp message_module(dialect, m, version) do
    module = Module.concat(dialect, module_name(m.name))
    layout = for f <- m.wire, do: {String.to_atom(f.name), f.type, f.array}

    defaults =
      for f <- m.fields do
        value =
          if f.mavlink_version and version,
            do: version,
            else: MAVLink2.Codec.zero(f.type, f.array)

        {String.to_atom(f.name), value}
      end

    quote do
      defmodule unquote(module) do
        @moduledoc unquote("MAVLink message #{m.name} (#{m.id}).")
        defstruct unquote(Macro.escape(defaults))

        def msgid, do: unquote(m.id)
        def crc_extra, do: unquote(m.crc_extra)
        def payload_length, do: unquote(m.length)
        def layout, do: unquote(Macro.escape(layout))
      end
    end
  end

  defp module_name(name), do: name |> String.downcase() |> Macro.camelize()

  defp key(name), do: name |> String.downcase() |> String.to_atom()
end
