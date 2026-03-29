defmodule ProsemirrorEx.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/yammine/prosemirror_ex"

  def project do
    [
      app: :prosemirror_ex,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp description do
    "ProseMirror document model and transforms for Elixir. " <>
      "Full port of prosemirror-model and prosemirror-transform with " <>
      "wire-format JSON compatibility for collaborative editing."
  end

  defp package do
    [
      name: "prosemirror_ex",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
