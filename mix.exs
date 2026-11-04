defmodule MAVLink2.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/isaiahdw/mavlink2"

  def project do
    [
      app: :mavlink2,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "MAVLink v2 for Elixir: frames, signing, dialects generated from XML, " <>
          "links, routing, and the command, parameter and mission protocols.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:crypto, :xmerl, :ex_unit],
        plt_local_path: "_build/plts",
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Overview: [MAVLink2],
        Frames: [MAVLink2.Frame, MAVLink2.CRC, MAVLink2.Signing],
        Dialects: [MAVLink2.Dialect, MAVLink2.Dialect.XML, MAVLink2.XML, MAVLink2.Codec],
        Links: [MAVLink2.Link, MAVLink2.Router],
        Services: [MAVLink2.Command, MAVLink2.Param, MAVLink2.Mission],
        Transports: [MAVLink2.Transport, MAVLink2.Transport.UART, MAVLink2.Transport.Loopback]
      ]
    ]
  end
end
