defmodule NetworkSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :network_sim,
      version: "1.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "Network Simulator",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {NetworkSim.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # For documentation generation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
      # {:stream_data, "~> 1.0", only: :test}
    ]
  end

  # Run "mix help docs" to learn about ExDoc.
  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      authors: ["Nazareno Piccin"],
      nest_modules_by_prefix: [
        "NetworkSim",
        "NetworkSim.Protocol"
      ],
      source_url: "https://github.com/Nackha1/network-sim/"
    ]
  end
end
