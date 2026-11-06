defmodule MAVLink2.XML do
  @moduledoc """
  Reads a MAVLink message definition file, following its `<include>`s, into
  messages and enums with their wire layout.

  A message's wire layout is its base fields stable-sorted by type size,
  largest first, then its extension fields in the order written. Its
  `crc_extra` is the MAVLink CRC over `"NAME "` and, for each base field in
  wire order, `"type name "` and an array's length as one byte, folded to
  a byte as `low ^^^ high`.
  """

  import Bitwise
  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @type base_type ::
          :int8
          | :uint8
          | :char
          | :int16
          | :uint16
          | :int32
          | :uint32
          | :int64
          | :uint64
          | :float
          | :double

  @type field :: %{
          name: String.t(),
          type: base_type(),
          array: pos_integer() | nil,
          enum: String.t() | nil,
          extension: boolean(),
          mavlink_version: boolean()
        }

  @type message :: %{
          id: non_neg_integer(),
          name: String.t(),
          fields: [field()],
          wire: [field()],
          length: pos_integer(),
          min_length: pos_integer(),
          crc_extra: 0..255
        }

  @type t :: %{
          version: non_neg_integer() | nil,
          files: [Path.t()],
          messages: [message()],
          enums: %{String.t() => %{String.t() => integer()}}
        }

  @sizes %{
    int8: 1,
    uint8: 1,
    char: 1,
    int16: 2,
    uint16: 2,
    int32: 4,
    uint32: 4,
    int64: 8,
    uint64: 8,
    float: 4,
    double: 8
  }

  @doc "Reads `path` and every file it includes."
  @spec read!(Path.t()) :: t()
  def read!(path) do
    {defs, files} = collect(Path.expand(path), [])
    top = List.last(defs)
    messages = defs |> Enum.flat_map(& &1.messages) |> Enum.map(&layout/1)

    case messages |> Enum.group_by(& &1.id) |> Enum.find(fn {_, ms} -> length(ms) > 1 end) do
      nil ->
        :ok

      {id, ms} ->
        raise ArgumentError,
              "message id #{id} defined twice: #{Enum.map_join(ms, ", ", & &1.name)}"
    end

    enums =
      Enum.reduce(defs, %{}, fn d, acc ->
        Map.merge(acc, d.enums, fn _name, a, b -> Map.merge(a, b) end)
      end)

    %{
      version: top.version,
      files: Enum.reverse(files),
      messages: Enum.sort_by(messages, & &1.id),
      enums: enums
    }
  end

  @spec size(base_type()) :: pos_integer()
  def size(type), do: Map.fetch!(@sizes, type)

  # Includes first, each file once; the including file last.
  defp collect(path, seen) do
    if path in seen do
      {[], seen}
    else
      doc =
        case File.regular?(path) && :xmerl_scan.file(String.to_charlist(path), quiet: true) do
          {doc, _rest} ->
            doc

          _ ->
            raise ArgumentError,
                  "MAVLink2.XML: cannot read #{path}, included from a dialect's XML. Includes " <>
                    "are relative to the including file; copy the included file next to it"
        end

      dir = Path.dirname(path)

      {included, seen} =
        doc
        |> children(:include)
        |> Enum.reduce({[], [path | seen]}, fn inc, {defs, seen} ->
          {more, seen} = collect(Path.expand(text(inc), dir), seen)
          {defs ++ more, seen}
        end)

      {included ++ [parse(doc)], seen}
    end
  end

  defp parse(doc) do
    version =
      case children(doc, :version) do
        [v | _] -> String.to_integer(text(v))
        [] -> nil
      end

    messages = for ms <- children(doc, :messages), m <- children(ms, :message), do: message(m)

    enums =
      for es <- children(doc, :enums), e <- children(es, :enum), into: %{} do
        {entries, _} =
          e
          |> children(:entry)
          |> Enum.map_reduce(0, fn entry, next ->
            value = if v = attr(entry, :value), do: parse_int(v), else: next
            {{attr(entry, :name), value}, value + 1}
          end)

        {attr(e, :name), Map.new(entries)}
      end

    %{version: version, messages: messages, enums: enums}
  end

  defp message(m) do
    {fields, _} =
      m
      |> elements()
      |> Enum.reduce({[], false}, fn
        xml_element(name: :extensions), {fs, _} -> {fs, true}
        xml_element(name: :field) = f, {fs, ext?} -> {[field(f, ext?) | fs], ext?}
        _other, acc -> acc
      end)

    %{id: String.to_integer(attr(m, :id)), name: attr(m, :name), fields: Enum.reverse(fields)}
  end

  defp field(f, extension?) do
    type = attr(f, :type)

    {base, array} =
      case Regex.run(~r/^(\w+)\[(\d+)\]$/, type) do
        [_, base, n] -> {base, String.to_integer(n)}
        nil -> {type, nil}
      end

    %{
      name: attr(f, :name),
      type: base_type(base),
      array: array,
      enum: attr(f, :enum),
      extension: extension?,
      mavlink_version: base == "uint8_t_mavlink_version"
    }
  end

  defp base_type("uint8_t_mavlink_version"), do: :uint8
  defp base_type("char"), do: :char
  defp base_type("float"), do: :float
  defp base_type("double"), do: :double

  defp base_type(t) do
    case Regex.run(~r/^(u?int)(8|16|32|64)_t$/, t) do
      [_, kind, bits] -> String.to_atom(kind <> bits)
      nil -> raise ArgumentError, "unknown MAVLink field type #{inspect(t)}"
    end
  end

  defp layout(m) do
    {ext, base} = Enum.split_with(m.fields, & &1.extension)
    wire = Enum.sort_by(base, &size(&1.type), :desc) ++ ext
    bytes = fn fs -> fs |> Enum.map(&(size(&1.type) * (&1.array || 1))) |> Enum.sum() end
    length = bytes.(wire)
    if length > 255, do: raise(ArgumentError, "#{m.name} is #{length} bytes, over 255")

    crc =
      Enum.reduce(
        Enum.reject(wire, & &1.extension),
        MAVLink2.CRC.accumulate_bytes(MAVLink2.CRC.seed(), m.name <> " "),
        fn f, crc ->
          crc = MAVLink2.CRC.accumulate_bytes(crc, c_type(f.type) <> " " <> f.name <> " ")
          if f.array, do: MAVLink2.CRC.accumulate(crc, f.array), else: crc
        end
      )

    Map.merge(m, %{
      wire: wire,
      length: length,
      min_length: bytes.(base),
      crc_extra: bxor(crc &&& 0xFF, crc >>> 8)
    })
  end

  defp c_type(:char), do: "char"
  defp c_type(:float), do: "float"
  defp c_type(:double), do: "double"
  defp c_type(t), do: Atom.to_string(t) <> "_t"

  defp parse_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_int("0X" <> hex), do: String.to_integer(hex, 16)

  defp parse_int(v) do
    case Regex.run(~r/^(\d+)\*\*(\d+)$/, v) do
      [_, b, e] -> Integer.pow(String.to_integer(b), String.to_integer(e))
      nil -> String.to_integer(v)
    end
  end

  defp elements(xml_element(content: content)),
    do: Enum.filter(content, &Record.is_record(&1, :xmlElement))

  defp children(el, name),
    do: el |> elements() |> Enum.filter(&match?(xml_element(name: ^name), &1))

  defp attr(xml_element(attributes: attrs), name) do
    Enum.find_value(attrs, fn
      xml_attribute(name: ^name, value: v) -> to_string(v)
      _ -> nil
    end)
  end

  defp text(xml_element(content: content)) do
    content
    |> Enum.filter(&Record.is_record(&1, :xmlText))
    |> Enum.map_join(fn xml_text(value: v) -> to_string(v) end)
    |> String.trim()
  end
end
