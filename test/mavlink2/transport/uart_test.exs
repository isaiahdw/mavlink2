defmodule MAVLink2.Transport.UARTTest do
  use ExUnit.Case, async: true

  alias MAVLink2.Transport.UART

  test "a port that does not open leaves no process behind" do
    {:links, before} = Process.info(self(), :links)
    assert {:error, _} = UART.open(device: "/dev/mavlink2-test-no-such-port", owner: self())
    assert Process.info(self(), :links) == {:links, before}
  end
end
