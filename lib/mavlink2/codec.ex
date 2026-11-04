defmodule MAVLink2.Codec do
  @moduledoc """
  Message payloads from a wire layout (`MAVLink2.XML`): fields little
  endian, in wire order.

  | Field | Elixir value |
  | --- | --- |
  | integer, scalar `char` | integer |
  | `float`, `double` | float, or `:nan`, `:infinity`, `:neg_infinity` |
  | `char[n]` | binary, up to the first NUL; zero-padded or cut to `n` when encoded |
  | other arrays | list of `n` values, zero-filled when shorter |

  `decode/2` zero-extends a short payload first, as a v2 receiver must.
  `encode/2` raises `ArgumentError` for an integer outside its type's range.
  """

  import Bitwise

  @type layout :: [{atom(), MAVLink2.XML.base_type(), pos_integer() | nil}]

  @doc "The payload for `values`, a map or struct holding every field in `layout`."
  @spec encode(layout(), map()) :: binary()
  def encode(layout, values) do
    for {name, type, n} <- layout, into: <<>> do
      field(type, n, Map.fetch!(values, name), name)
    end
  end

  @doc "The field values in `payload`, as a keyword list in wire order."
  @spec decode(layout(), binary()) :: keyword()
  def decode(layout, payload) do
    length =
      Enum.reduce(layout, 0, fn {_, t, n}, acc -> acc + MAVLink2.XML.size(t) * (n || 1) end)

    payload = pad(payload, length)

    {values, _rest} =
      Enum.map_reduce(layout, payload, fn {name, type, n}, rest ->
        {value, rest} = take(type, n, rest)
        {{name, value}, rest}
      end)

    values
  end

  @doc "A field's zero value."
  @spec zero(MAVLink2.XML.base_type(), pos_integer() | nil) :: term()
  def zero(:char, n) when is_integer(n), do: ""
  def zero(type, n) when is_integer(n), do: List.duplicate(zero(type, nil), n)
  def zero(type, nil) when type in [:float, :double], do: 0.0
  def zero(_type, nil), do: 0

  defp field(:char, n, s, _name) when is_integer(n) and is_binary(s),
    do: s |> binary_part(0, min(byte_size(s), n)) |> pad(n)

  defp field(type, n, list, name) when is_integer(n) and is_list(list) do
    list = Enum.take(list, n)
    values = list ++ List.duplicate(zero(type, nil), n - length(list))
    for v <- values, into: <<>>, do: field(type, nil, v, name)
  end

  defp field(:float, nil, v, _name), do: float(32, v)
  defp field(:double, nil, v, _name), do: float(64, v)

  defp field(type, nil, v, name) do
    {min, max} = range(type)

    unless is_integer(v) and v >= min and v <= max do
      raise ArgumentError,
            "field #{inspect(name)} is #{inspect(v)}, outside #{type} (#{min}..#{max})"
    end

    <<v::little-size(bits(type))>>
  end

  @signed [:int8, :int16, :int32, :int64]

  defp range(type) when type in @signed,
    do: {-(1 <<< (bits(type) - 1)), (1 <<< (bits(type) - 1)) - 1}

  defp range(type), do: {0, (1 <<< bits(type)) - 1}

  defp float(32, :nan), do: <<0x7FC00000::little-32>>
  defp float(32, :infinity), do: <<0x7F800000::little-32>>
  defp float(32, :neg_infinity), do: <<0xFF800000::little-32>>
  defp float(64, :nan), do: <<0x7FF8000000000000::little-64>>
  defp float(64, :infinity), do: <<0x7FF0000000000000::little-64>>
  defp float(64, :neg_infinity), do: <<0xFFF0000000000000::little-64>>
  defp float(size, v) when is_number(v), do: <<v::float-little-size(size)>>

  defp take(:char, n, bin) when is_integer(n) do
    <<s::binary-size(^n), rest::binary>> = bin
    {s |> :binary.split(<<0>>) |> hd(), rest}
  end

  defp take(type, n, bin) when is_integer(n) do
    Enum.map_reduce(1..n, bin, fn _, rest -> take(type, nil, rest) end)
  end

  defp take(:float, nil, <<raw::little-32, rest::binary>>), do: {unfloat(32, raw), rest}
  defp take(:double, nil, <<raw::little-64, rest::binary>>), do: {unfloat(64, raw), rest}

  defp take(type, nil, bin) when type in @signed do
    size = bits(type)
    <<v::signed-little-size(^size), rest::binary>> = bin
    {v, rest}
  end

  defp take(type, nil, bin) do
    size = bits(type)
    <<v::unsigned-little-size(^size), rest::binary>> = bin
    {v, rest}
  end

  # Exponent all ones: NaN or an infinity, which Elixir floats cannot hold.
  defp unfloat(32, raw) when (raw &&& 0x7F800000) == 0x7F800000,
    do: special(raw &&& 0x7FFFFF, raw >>> 31)

  defp unfloat(64, raw) when (raw &&& 0x7FF0000000000000) == 0x7FF0000000000000,
    do: special(raw &&& 0xFFFFFFFFFFFFF, raw >>> 63)

  defp unfloat(size, raw) do
    <<v::float-size(^size)>> = <<raw::size(size)>>
    v
  end

  defp special(0, 0), do: :infinity
  defp special(0, 1), do: :neg_infinity
  defp special(_mantissa, _sign), do: :nan

  defp bits(type), do: MAVLink2.XML.size(type) * 8

  defp pad(bin, n) when byte_size(bin) >= n, do: binary_part(bin, 0, n)
  defp pad(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))
end
