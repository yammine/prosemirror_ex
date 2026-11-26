defmodule ProsemirrorEx.Transform.Transform do
  @moduledoc """
  Abstraction to build up and track an array of steps representing a
  document transformation.

  Functions pattern-match on map keys rather than the `%Transform{}` struct
  so that a future Transaction struct can reuse them.

  Ports `Transform` from prosemirror-transform/src/transform.ts.
  """

  alias ProsemirrorEx.Model.{Fragment, Mark, MarkType, Node, NodeRange, NodeType, Slice}

  alias ProsemirrorEx.Transform.{
    AddNodeMarkStep,
    AttrStep,
    DocAttrStep,
    Mapping,
    RemoveNodeMarkStep,
    Step,
    StepMap,
    StepResult,
    TransformError
  }

  defstruct [:doc, steps: [], docs: [], mapping: nil]

  @type transform_like :: %{
          doc: Node.t(),
          steps: [Step.step()],
          docs: [Node.t()],
          mapping: Mapping.t()
        }

  @type t :: %__MODULE__{
          doc: Node.t(),
          steps: [Step.step()],
          docs: [Node.t()],
          mapping: Mapping.t()
        }

  @doc "Create a new Transform starting with the given document."
  @spec new(Node.t()) :: t()
  def new(doc) do
    %__MODULE__{doc: doc, steps: [], docs: [], mapping: Mapping.new()}
  end

  @doc "The starting document (before any steps were applied)."
  @spec before(transform_like()) :: Node.t()
  def before(%{docs: [first_doc | _]}), do: first_doc
  def before(%{doc: doc}), do: doc

  @doc "True when the document has been changed (when there are any steps)."
  @spec doc_changed?(transform_like()) :: boolean()
  def doc_changed?(%{steps: [_ | _]}), do: true
  def doc_changed?(%{steps: []}), do: false

  @doc """
  Apply a new step in this transform, saving the result. Raises a
  `TransformError` when the step fails.
  """
  @spec step(tr, Step.step()) :: tr when tr: transform_like()
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
  @spec maybe_step(tr, Step.step()) :: {tr, StepResult.t()} when tr: transform_like()
  def maybe_step(%{doc: _doc, steps: _steps, docs: _docs, mapping: _mapping} = tr, step_struct) do
    result = Step.apply(step_struct, tr.doc)

    if result.failed do
      {tr, result}
    else
      {add_step(tr, step_struct, result.doc), result}
    end
  end

  @doc """
  Return a single range, in post-transform document positions, that covers
  all content changed by this transform. Returns `nil` if no replacements
  are made. Note that this will ignore changes that add/remove marks without
  replacing the underlying content.
  """
  @spec changed_range(transform_like()) :: %{from: non_neg_integer(), to: non_neg_integer()} | nil
  def changed_range(%{steps: [], mapping: _mapping}), do: nil

  def changed_range(%{mapping: %{maps: maps, from: from_idx, to: to_idx}}) do
    active_maps = maps |> Enum.drop(from_idx) |> Enum.take(max(0, to_idx - from_idx))

    range =
      Enum.reduce(active_maps, nil, fn step_map, acc ->
        mapped_acc =
          case acc do
            nil ->
              nil

            {from_acc, to_acc} ->
              {
                StepMap.map(step_map, from_acc, 1),
                StepMap.map(step_map, to_acc, -1)
              }
          end

        StepMap.fold(step_map, mapped_acc, fn _old_start, _old_end, new_start, new_end, cur ->
          case cur do
            nil -> {new_start, new_end}
            {f, t} -> {min(f, new_start), max(t, new_end)}
          end
        end)
      end)

    case range do
      nil -> nil
      {from, to} -> %{from: from, to: to}
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp add_step(
         %{doc: doc, steps: steps, docs: docs, mapping: mapping} = tr,
         step_struct,
         new_doc
       ) do
    step_map = Step.step_map(step_struct)

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
  @spec add_mark(tr, non_neg_integer(), non_neg_integer(), Mark.t()) :: tr
        when tr: transform_like()
  def add_mark(tr, from, to, mark) do
    ProsemirrorEx.Transform.Mark.add_mark(tr, from, to, mark)
  end

  @doc """
  Remove marks from inline nodes between `from` and `to`. When `mark` is a
  single mark, remove precisely that mark. When it is a mark type, remove all
  marks of that type. When it is `nil`, remove all marks of any type.
  """
  @spec remove_mark(tr, non_neg_integer(), non_neg_integer(), Mark.t() | MarkType.t() | nil) :: tr
        when tr: transform_like()
  def remove_mark(tr, from, to, mark \\ nil) do
    ProsemirrorEx.Transform.Mark.remove_mark(tr, from, to, mark)
  end

  @doc """
  Removes all marks and nodes from the content of the node at `pos` that
  don't match the given new parent node type.
  """
  @spec clear_incompatible(tr, non_neg_integer(), NodeType.t(), term(), boolean()) :: tr
        when tr: transform_like()
  def clear_incompatible(tr, pos, parent_type, match \\ nil, clear_newlines \\ true) do
    ProsemirrorEx.Transform.Mark.clear_incompatible(tr, pos, parent_type, match, clear_newlines)
  end

  # ── Replace helper delegates ──────────────────────────────────────

  @doc "Replace a range of the document with a slice."
  @spec replace(tr, non_neg_integer(), non_neg_integer() | nil, Slice.t() | nil) :: tr
        when tr: transform_like()
  def replace(tr, from, to \\ nil, slice \\ nil) do
    to = to || from
    slice = slice || Slice.empty()
    step_val = ProsemirrorEx.Transform.Replace.replace_step(tr.doc, from, to, slice)
    if step_val, do: step(tr, step_val), else: tr
  end

  @doc "Replace a range of the document with a node or list of nodes."
  @spec replace_with(
          tr,
          non_neg_integer(),
          non_neg_integer(),
          Fragment.t() | Node.t() | [Node.t()]
        ) :: tr
        when tr: transform_like()
  def replace_with(tr, from, to, content) do
    replace(tr, from, to, Slice.new(Fragment.from(content), 0, 0))
  end

  @doc "Delete content between `from` and `to`."
  @spec delete(tr, non_neg_integer(), non_neg_integer()) :: tr when tr: transform_like()
  def delete(tr, from, to), do: replace(tr, from, to)

  @doc "Insert content at `pos`."
  @spec insert(tr, non_neg_integer(), Fragment.t() | Node.t() | [Node.t()]) :: tr
        when tr: transform_like()
  def insert(tr, pos, content) do
    replace(tr, pos, pos, Slice.new(Fragment.from(content), 0, 0))
  end

  @doc "WYSIWYG-aware replace across a range."
  @spec replace_range(tr, non_neg_integer(), non_neg_integer(), Slice.t()) :: tr
        when tr: transform_like()
  def replace_range(tr, from, to, slice) do
    ProsemirrorEx.Transform.Replace.replace_range(tr, from, to, slice)
  end

  @doc "WYSIWYG-aware replace with a single node."
  @spec replace_range_with(tr, non_neg_integer(), non_neg_integer(), Node.t()) :: tr
        when tr: transform_like()
  def replace_range_with(tr, from, to, node) do
    ProsemirrorEx.Transform.Replace.replace_range_with(tr, from, to, node)
  end

  @doc "Smart delete that expands to cover parent nodes when appropriate."
  @spec delete_range(tr, non_neg_integer(), non_neg_integer()) :: tr when tr: transform_like()
  def delete_range(tr, from, to) do
    ProsemirrorEx.Transform.Replace.delete_range(tr, from, to)
  end

  # ── Structure helper delegates ─────────────────────────────────────

  @doc "Lift the content in the given range to the given target depth."
  @spec lift(tr, NodeRange.t(), non_neg_integer()) :: tr when tr: transform_like()
  def lift(tr, range, target) do
    ProsemirrorEx.Transform.Structure.lift(tr, range, target)
  end

  @doc "Wrap the content in the given range in the given wrapper nodes."
  @spec wrap(tr, NodeRange.t(), [map()]) :: tr when tr: transform_like()
  def wrap(tr, range, wrappers) do
    ProsemirrorEx.Transform.Structure.wrap(tr, range, wrappers)
  end

  @doc """
  Set the type of all textblocks (partly) between `from` and `to`.

  Supports 3-, 4-, and 5-argument calls:
  - `set_block_type(tr, from, type)` — converts the block at `from` (`to` defaults to `from`, `attrs` to `nil`)
  - `set_block_type(tr, from, to, type)` — converts blocks in `from..to` (`attrs` defaults to `nil`)
  - `set_block_type(tr, from, to, type, attrs)` — passes explicit `attrs` map or function
  """
  @spec set_block_type(
          tr,
          non_neg_integer(),
          non_neg_integer() | nil,
          NodeType.t(),
          map() | (Node.t() -> map()) | nil
        ) :: tr
        when tr: transform_like()
  def set_block_type(tr, from, to \\ nil, type, attrs \\ nil) do
    ProsemirrorEx.Transform.Structure.set_block_type(tr, from, to || from, type, attrs)
  end

  @doc "Change the type, attributes, and/or marks of the node at `pos`."
  @spec set_node_markup(
          tr,
          non_neg_integer(),
          NodeType.t() | nil,
          map() | nil,
          [Mark.t()] | nil
        ) :: tr
        when tr: transform_like()
  def set_node_markup(tr, pos, type \\ nil, attrs \\ nil, marks \\ nil) do
    ProsemirrorEx.Transform.Structure.set_node_markup(tr, pos, type, attrs, marks)
  end

  @doc "Split the node at the given position."
  @spec split(tr, non_neg_integer(), non_neg_integer(), [map() | nil] | nil) :: tr
        when tr: transform_like()
  def split(tr, pos, depth \\ 1, types_after \\ nil) do
    ProsemirrorEx.Transform.Structure.split(tr, pos, depth, types_after)
  end

  @doc "Join the blocks around the given position."
  @spec join(tr, non_neg_integer(), non_neg_integer()) :: tr when tr: transform_like()
  def join(tr, pos, depth \\ 1) do
    ProsemirrorEx.Transform.Structure.join(tr, pos, depth)
  end

  # ── Node mark & attribute steps ─────────────────────────────────────

  @doc "Add a mark to the node at `pos`."
  @spec add_node_mark(tr, non_neg_integer(), Mark.t()) :: tr when tr: transform_like()
  def add_node_mark(%{doc: _doc, steps: _steps, docs: _docs, mapping: _mapping} = tr, pos, mark) do
    step(tr, AddNodeMarkStep.new(pos, mark))
  end

  @doc """
  Remove a mark from the node at `pos`. `mark` may be a `Mark` struct
  or a `MarkType` (in which case all marks of that type on the node are removed).
  """
  @spec remove_node_mark(tr, non_neg_integer(), Mark.t() | MarkType.t()) :: tr
        when tr: transform_like()
  def remove_node_mark(
        %{doc: doc, steps: _steps, docs: _docs, mapping: _mapping} = tr,
        pos,
        %MarkType{} = mark_type
      ) do
    node = Node.node_at(doc, pos)

    if !node do
      raise TransformError, message: "No node at position #{pos}"
    end

    Enum.reduce(node.marks || [], tr, fn m, acc ->
      if m.type.name == mark_type.name do
        step(acc, RemoveNodeMarkStep.new(pos, m))
      else
        acc
      end
    end)
  end

  def remove_node_mark(
        %{doc: _doc, steps: _steps, docs: _docs, mapping: _mapping} = tr,
        pos,
        %Mark{} = mark
      ) do
    step(tr, RemoveNodeMarkStep.new(pos, mark))
  end

  @doc "Set a single attribute on the node at `pos`."
  @spec set_node_attribute(tr, non_neg_integer(), String.t(), any()) :: tr
        when tr: transform_like()
  def set_node_attribute(tr, pos, attr, value) do
    step(tr, AttrStep.new(pos, attr, value))
  end

  @doc "Set a document-level attribute."
  @spec set_doc_attribute(tr, String.t(), any()) :: tr when tr: transform_like()
  def set_doc_attribute(tr, attr, value) do
    step(tr, DocAttrStep.new(attr, value))
  end
end
