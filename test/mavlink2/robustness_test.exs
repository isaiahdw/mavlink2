defmodule MAVLink2.RobustnessTest do
  # Randomised checks, seeded by ExUnit's seed (mix test --seed N repeats a
  # run).
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import Bitwise

  alias MAVLink2.{Common, Frame, Link, Signing}
  alias MAVLink2.Transport.Loopback

  @rounds 300

  setup do
    :rand.seed(:exsss, {ExUnit.configuration()[:seed] || 0, 1, 2})
    :ok
  end

  defp bytes(n), do: for(_ <- 1..n//1, into: <<>>, do: <<random_byte()>>)

  # One byte in eight is a start byte, so noise keeps looking like frames.
  defp random_byte, do: if(:rand.uniform(8) == 1, do: 0xFD, else: :rand.uniform(256) - 1)

  defp noise_without_stx(n),
    do: for(_ <- 1..n//1, into: <<>>, do: <<Enum.random(Enum.to_list(0..0xFC) ++ [0xFF])>>)

  defp random_frame do
    msgid = Enum.random(Common.msgids())
    payload = bytes(Common.payload_length(msgid))

    %Frame{
      msgid: msgid,
      payload: payload,
      seq: :rand.uniform(256) - 1,
      sysid: Enum.random([1, 255, :rand.uniform(255), 70_000]),
      compid: :rand.uniform(255),
      target_sysid: Enum.random([nil, nil, nil, 100_000])
    }
  end

  defp wire(frame) do
    {:ok, bytes} = Frame.encode(frame, Common)
    bytes
  end

  test "random bytes never raise, and leave at most one partial frame" do
    for _ <- 1..@rounds do
      input = bytes(:rand.uniform(600))
      {frames, errors, rest} = Frame.drain(input, Common)
      assert is_list(frames) and is_list(errors)
      assert byte_size(rest) <= 1 + 16 + 255 + 2 + 13
    end
  end

  test "frames hidden in noise, start bytes included, all come out in order" do
    for _ <- 1..@rounds do
      frames = for _ <- 1..:rand.uniform(5), do: random_frame()
      noise = fn -> bytes(:rand.uniform(40) - 1) end
      stream = Enum.map_join(frames, &(noise.() <> wire(&1))) <> noise_without_stx(300)

      {decoded, _errors, _rest} = Frame.drain(stream, Common)
      raws = Enum.map(decoded, & &1.raw)
      assert subsequence?(Enum.map(frames, &wire/1), raws)
    end
  end

  test "a stream split anywhere decodes as the whole does" do
    for _ <- 1..@rounds do
      stream =
        Enum.map_join(1..:rand.uniform(6), fn _ ->
          bytes(:rand.uniform(8) - 1) <> wire(random_frame())
        end)

      {whole, _, _} = Frame.drain(stream, Common)

      {pieces, _rest} =
        stream
        |> chunks()
        |> Enum.reduce({[], <<>>}, fn chunk, {acc, rest} ->
          {frames, _errors, rest} = Frame.drain(rest <> chunk, Common)
          {acc ++ frames, rest}
        end)

      assert Enum.map(pieces, & &1.raw) == Enum.map(whole, & &1.raw)
    end
  end

  test "a link fed random bytes keeps running and counts what it saw" do
    link = start_supervised!({Link, dialect: Common, transport: Loopback})
    :ok = Link.subscribe(link)

    for _ <- 1..@rounds, do: send(link, {:mavlink_data, bytes(:rand.uniform(300))})

    send(
      link,
      {:mavlink_data, noise_without_stx(300) <> wire(%Frame{msgid: 0, payload: <<0::72>>})}
    )

    assert %{rx: rx} = Link.stats(link)
    assert rx >= 1
    assert Process.alive?(link)
  end

  test "every message of common.xml round-trips with random values" do
    for msgid <- Common.msgids(), _ <- 1..3 do
      mod = Common.message(msgid) || flunk("no module for #{msgid}")
      message = struct!(mod, for({name, type, n} <- mod.layout(), do: {name, value(type, n)}))
      {^msgid, payload} = Common.encode(message)
      assert byte_size(payload) == Common.payload_length(msgid)
      assert Common.decode(msgid, payload) == {:ok, message}, inspect(mod)
    end
  end

  test "a signed frame with any one bit flipped never verifies" do
    key = :crypto.strong_rand_bytes(32)

    for _ <- 1..@rounds do
      frame = %{random_frame() | target_sysid: nil}
      {:ok, signed, _} = Signing.encode(Signing.new(key), frame, Common, 1_000_000)
      bit = :rand.uniform(bit_size(signed)) - 1
      <<head::bitstring-size(^bit), b::1, tail::bitstring>> = signed
      tampered = <<head::bitstring, bxor(b, 1)::1, tail::bitstring>>

      case Frame.decode(tampered, Common) do
        {:ok, %Frame{signature: {_, _, _, _}} = f, _} ->
          assert {:error, _} = Signing.verify(Signing.new(key), f, 1_000_000)

        _ ->
          :ok
      end
    end
  end

  defp chunks(<<>>), do: []

  defp chunks(bin) do
    n = min(:rand.uniform(40), byte_size(bin))
    <<chunk::binary-size(^n), rest::binary>> = bin
    [chunk | chunks(rest)]
  end

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([x | xs], [x | ys]), do: subsequence?(xs, ys)
  defp subsequence?(xs, [_ | ys]), do: subsequence?(xs, ys)

  defp value(:char, n) when is_integer(n),
    do: for(_ <- 1..:rand.uniform(n), into: "", do: <<Enum.random(?A..?Z)>>)

  defp value(type, n) when is_integer(n), do: for(_ <- 1..n, do: value(type, nil))
  defp value(:float, nil), do: float(32)
  defp value(:double, nil), do: float(64)
  defp value(:char, nil), do: :rand.uniform(256) - 1

  defp value(type, nil) do
    bits = MAVLink2.XML.size(type) * 8

    if type in [:int8, :int16, :int32, :int64],
      do: :rand.uniform(1 <<< bits) - 1 - (1 <<< (bits - 1)),
      else: :rand.uniform(1 <<< bits) - 1
  end

  # A random float the type holds exactly: random bits, NaN and the
  # infinities aside.
  defp float(size) do
    raw = :rand.uniform(1 <<< size) - 1
    <<f::float-size(^size)>> = <<raw::size(size)>>
    f
  rescue
    MatchError -> float(size)
  end
end
