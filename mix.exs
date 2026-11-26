defmodule ProsemirrorEx.MixProject do
  use Mix.Project

  @version "0.4.0"
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
      source_url: @source_url,
      docs: docs()
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

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Document Model": [
          ProsemirrorEx.Model,
          ProsemirrorEx.Model.Schema,
          ProsemirrorEx.Model.Node,
          ProsemirrorEx.Model.Fragment,
          ProsemirrorEx.Model.Mark,
          ProsemirrorEx.Model.NodeType,
          ProsemirrorEx.Model.MarkType,
          ProsemirrorEx.Model.ContentMatch,
          ProsemirrorEx.Model.ResolvedPos,
          ProsemirrorEx.Model.Slice,
          ProsemirrorEx.Model.NodeRange,
          ProsemirrorEx.Model.Replace,
          ProsemirrorEx.Model.Diff,
          ProsemirrorEx.Model.CompareDeep,
          ProsemirrorEx.Model.Utf16,
          ProsemirrorEx.Model.RangeError,
          ProsemirrorEx.Model.ReplaceError
        ],
        "Document Transforms": [
          ProsemirrorEx.Transform.Transform,
          ProsemirrorEx.Transform.Step,
          ProsemirrorEx.Transform.StepResult,
          ProsemirrorEx.Transform.StepMap,
          ProsemirrorEx.Transform.Mapping,
          ProsemirrorEx.Transform.Mappable,
          ProsemirrorEx.Transform.MapResult,
          ProsemirrorEx.Transform.ReplaceStep,
          ProsemirrorEx.Transform.ReplaceAroundStep,
          ProsemirrorEx.Transform.AddMarkStep,
          ProsemirrorEx.Transform.RemoveMarkStep,
          ProsemirrorEx.Transform.AddNodeMarkStep,
          ProsemirrorEx.Transform.RemoveNodeMarkStep,
          ProsemirrorEx.Transform.AttrStep,
          ProsemirrorEx.Transform.DocAttrStep,
          ProsemirrorEx.Transform.Replace,
          ProsemirrorEx.Transform.Structure,
          ProsemirrorEx.Transform.Mark,
          ProsemirrorEx.Transform.StepRegistry,
          ProsemirrorEx.Transform.TransformError
        ],
        "Convenience Schemas": [
          ProsemirrorEx.Schema,
          ProsemirrorEx.Schema.Basic,
          ProsemirrorEx.Schema.List
        ],
        "Collaborative Authority": [
          ProsemirrorEx.Authority,
          ProsemirrorEx.Authority.Server
        ]
      ]
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
