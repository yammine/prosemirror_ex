defmodule CollabDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :collab_demo,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {CollabDemo.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:prosemirror_ex, path: "../.."}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing", "cmd --cd assets npm install"],
      "assets.build": ["esbuild collab_demo"]
    ]
  end
end
