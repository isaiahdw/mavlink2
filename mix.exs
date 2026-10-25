defmodule MAVLink2.MixProject do
  use Mix.Project

  def project do
    [
      app: :mavlink2,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      # MAVLink2.Transport.UART only; a project that uses it depends on it.
      {:circuits_uart, "~> 1.5", optional: true}
    ]
  end
end
