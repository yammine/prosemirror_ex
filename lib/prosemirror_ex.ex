defmodule ProsemirrorEx do
  @moduledoc """
  Elixir port of the ProseMirror rich-text document model and transform engine,
  plus a collaborative editing authority.

  ## Subsystems

  - `ProsemirrorEx.Model` — immutable document tree (`Node`, `Fragment`, `Mark`,
    `Schema`, `NodeType`, `MarkType`, `ContentMatch`, `ResolvedPos`, `Slice`,
    and JSON wire-format serialization compatible with `prosemirror-model`).
  - `ProsemirrorEx.Transform` — invertible, mappable transformation `Step`s
    and high-level `Transform` operations (`Replace`, `Structure`, `Mark`)
    compatible with `prosemirror-transform`.
  - `ProsemirrorEx.Schema` — convenience schema builders (`Schema.Basic` and
    `Schema.List`).
  - `ProsemirrorEx.Authority` & `ProsemirrorEx.Authority.Server` — central
    collaborative editing authority (functional core + GenServer JSON wrapper
    with subscriber notifications).
  """
end
