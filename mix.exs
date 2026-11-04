defmodule MAVLink2.MixProject do
  use Mix.Project

  def project do
    [
      app: :mavlink2,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:crypto, :xmerl, :ex_unit],
        plt_local_path: "priv/plts",
        flags: [:error_handling, :extra_return, :missing_return]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :xmerl]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # MAVLink2.Transport.UART only; a project that uses it depends on it.
      {:circuits_uart, "~> 1.5", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
