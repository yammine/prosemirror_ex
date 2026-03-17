defmodule ProsemirrorEx.Transform.Transform do
  @moduledoc """
  Abstraction to build up and track an array of steps representing a
  document transformation.

  Functions pattern-match on map keys rather than the %Transform{} struct
  so that a future Transaction struct can reuse them.

  Ports `Transform` from prosemirror-transform/src/transform.ts.
  """

  alias ProsemirrorEx.Transform.{Mapping, StepMap, TransformError}

  defstruct [:doc, steps: [], docs: [], mapping: nil]

  @type t :: %__MODULE__{
          doc: ProsemirrorEx.Model.Node.t(),
          steps: [term()],
          docs: [ProsemirrorEx.Model.Node.t()],
          mapping: Mapping.t()
        }

  @doc "Create a new Transform starting with the given document."
  def new(doc) do
    %__MODULE__{doc: doc, steps: [], docs: [], mapping: Mapping.new()}
  end

  @doc "The starting document (before any steps were applied)."
  def before(%{docs: [first_doc | _]}), do: first_doc
  def before(%{doc: doc}), do: doc

  @doc "True when the document has been changed (when there are any steps)."
  def doc_changed?(%{steps: steps}), do: length(steps) > 0

  @doc """
  Apply a new step in this transform, saving the result. Raises a
  TransformError when the step fails.
  """
  def step(%{doc: _doc, steps: _steps, docs: _docs, mapping: _mapping} = tr, step_struct) do
    {tr, result} = maybe_step(tr, step_struct)

    if result.failed do
      raise TransformError, message: result.failed
    end

    tr
  end

  @doc """
  Try to apply a step in this transformation, ignoring it if it fails.
  Returns `{updated_tr, step_result}`.
  """
  def maybe_step(%{doc: _doc, steps: _steps, docs: _docs, mapping: _mapping} = tr, step_struct) do
    step_module = step_struct.__struct__
    result = step_module.apply(step_struct, tr.doc)

    if result.failed do
      {tr, result}
    else
      {add_step(tr, step_struct, result.doc), result}
    end
  end

  @doc """
  Return a single range, in post-transform document positions, that covers
  all content changed by this transform. Returns nil if no replacements
  are made. Note that this will ignore changes that add/remove marks without
  replacing the underlying content.
  """
  def changed_range(%{steps: [], mapping: _mapping}), do: nil

  def changed_range(%{mapping: %{maps: maps}}) do
    {from, to} =
      maps
      |> Enum.with_index()
      |> Enum.reduce({1_000_000_000, -1_000_000_000}, fn {map, i}, {from_acc, to_acc} ->
        # For maps after the first, map existing from/to through this map
        {from_acc, to_acc} =
          if i > 0 do
            {
              ProsemirrorEx.Transform.Mappable.map(map, from_acc, 1),
              ProsemirrorEx.Transform.Mappable.map(map, to_acc, -1)
            }
          else
            {from_acc, to_acc}
          end

        # Expand range to cover all changes in this map
        StepMap.for_each(map, fn _old_start, _old_end, new_start, new_end ->
          {new_start, new_end}
        end)
        |> Enum.reduce({from_acc, to_acc}, fn {ns, ne}, {f, t} ->
          {min(f, ns), max(t, ne)}
        end)
      end)

    if from == 1_000_000_000 do
      nil
    else
      %{from: from, to: to}
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp add_step(
         %{doc: doc, steps: steps, docs: docs, mapping: mapping} = tr,
         step_struct,
         new_doc
       ) do
    step_module = step_struct.__struct__
    step_map = step_module.step_map(step_struct)

    %{
      tr
      | doc: new_doc,
        steps: steps ++ [step_struct],
        docs: docs ++ [doc],
        mapping: Mapping.append_map(mapping, step_map)
    }
  end

  # ── Mark helper delegates ────────────────────────────────────────────

  @doc "Add a mark to inline content between `from` and `to`."
  def add_mark(tr, from, to, mark) do
    ProsemirrorEx.Transform.Mark.add_mark(tr, from, to, mark)
  end

  @doc """
  Remove marks from inline nodes between `from` and `to`. When `mark` is a
  single mark, remove precisely that mark. When it is a mark type, remove all
  marks of that type. When it is nil, remove all marks of any type.
  """
  def remove_mark(tr, from, to, mark \\ nil) do
    ProsemirrorEx.Transform.Mark.remove_mark(tr, from, to, mark)
  end

  @doc """
  Removes all marks and nodes from the content of the node at `pos` that
  don't match the given new parent node type.
  """
  def clear_incompatible(tr, pos, parent_type, match \\ nil, clear_newlines \\ true) do
    ProsemirrorEx.Transform.Mark.clear_incompatible(tr, pos, parent_type, match, clear_newlines)
  end

  # ── Replace helper delegates ──────────────────────────────────────

  @doc "Replace a range of the document with a slice."
  def replace(tr, from, to \\ nil, slice \\ nil) do
    to = to || from
    slice = slice || ProsemirrorEx.Model.Slice.empty()
    step_val = ProsemirrorEx.Transform.Replace.replace_step(tr.doc, from, to, slice)
    if step_val, do: step(tr, step_val), else: tr
  end

  @doc "Replace a range of the document with a node or list of nodes."
  def replace_with(tr, from, to, content) do
    replace(
      tr,
      from,
      to,
      ProsemirrorEx.Model.Slice.new(
        ProsemirrorEx.Model.Fragment.from(content),
        0,
        0
      )
    )
  end

  @doc "Delete content between `from` and `to`."
  def delete(tr, from, to), do: replace(tr, from, to)

  @doc "Insert content at `pos`."
  def insert(tr, pos, content) do
    replace(
      tr,
      pos,
      pos,
      ProsemirrorEx.Model.Slice.new(
        ProsemirrorEx.Model.Fragment.from(content),
        0,
        0
      )
    )
  end

  @doc "WYSIWYG-aware replace across a range."
  def replace_range(tr, from, to, slice) do
    ProsemirrorEx.Transform.Replace.replace_range(tr, from, to, slice)
  end

  @doc "WYSIWYG-aware replace with a single node."
  def replace_range_with(tr, from, to, node) do
    ProsemirrorEx.Transform.Replace.replace_range_with(tr, from, to, node)
  end

  @doc "Smart delete that expands to cover parent nodes when appropriate."
  def delete_range(tr, from, to) do
    ProsemirrorEx.Transform.Replace.delete_range(tr, from, to)
  end
end
