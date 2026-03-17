defmodule ProsemirrorEx.Transform.ReplaceStep do
  @moduledoc """
  Replace a part of the document with a slice of new content.

  Ports `ReplaceStep` from prosemirror-transform/src/replace_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Fragment, Node}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult}

  defstruct [:from, :to, :slice, structure: false]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          slice: Slice.t(),
          structure: boolean()
        }

  @doc "Create a new ReplaceStep."
  def new(from, to, slice, structure \\ false) do
    %__MODULE__{from: from, to: to, slice: slice, structure: structure}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    if step.structure and content_between(doc, step.from, step.to) do
      StepResult.fail("Structure replace would overwrite content")
    else
      StepResult.from_replace(doc, step.from, step.to, step.slice)
    end
  end

  @impl true
  def step_map(%__MODULE__{} = step) do
    %StepMap{ranges: [step.from, step.to - step.from, Slice.size(step.slice)], inverted: false}
  end

  @impl true
  def invert(%__MODULE__{} = step, doc) do
    new(step.from, step.from + Slice.size(step.slice), Node.slice(doc, step.from, step.to))
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    from = Mappable.map_result(mapping, step.from, 1)
    to = Mappable.map_result(mapping, step.to, -1)

    if MapResult.deleted_across?(from) and MapResult.deleted_across?(to) do
      nil
    else
      new(from.pos, max(from.pos, to.pos), step.slice, step.structure)
    end
  end

  @impl true
  def merge(%__MODULE__{} = step, %__MODULE__{} = other) do
    if other.structure or step.structure do
      nil
    else
      step_slice_size = Slice.size(step.slice)
      other_slice_size = Slice.size(other.slice)

      cond do
        step.from + step_slice_size == other.from and
          step.slice.open_end == 0 and other.slice.open_start == 0 ->
          slice =
            if step_slice_size + other_slice_size == 0 do
              Slice.empty()
            else
              Slice.new(
                Fragment.append(step.slice.content, other.slice.content),
                step.slice.open_start,
                other.slice.open_end
              )
            end

          new(step.from, step.to + (other.to - other.from), slice, step.structure)

        other.to == step.from and
          step.slice.open_start == 0 and other.slice.open_end == 0 ->
          slice =
            if step_slice_size + other_slice_size == 0 do
              Slice.empty()
            else
              Slice.new(
                Fragment.append(other.slice.content, step.slice.content),
                other.slice.open_start,
                step.slice.open_end
              )
            end

          new(other.from, step.to, slice, step.structure)

        true ->
          nil
      end
    end
  end

  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    json = %{"stepType" => "replace", "from" => step.from, "to" => step.to}

    json =
      if Slice.size(step.slice) > 0 do
        Map.put(json, "slice", Slice.to_json(step.slice))
      else
        json
      end

    json =
      if step.structure do
        Map.put(json, "structure", true)
      else
        json
      end

    json
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["from"]) and is_number(json["to"]) do
      raise ArgumentError, "Invalid input for ReplaceStep.fromJSON"
    end

    new(
      json["from"],
      json["to"],
      Slice.from_json(schema, json["slice"]),
      !!json["structure"]
    )
  end

  # ── contentBetween helper ──────────────────────────────────────────

  defp content_between(doc, from, to) do
    resolved_from = Node.resolve(doc, from)
    dist = to - from
    depth = resolved_from.depth

    {dist, depth} = close_right(resolved_from, dist, depth)

    if dist > 0 do
      next = node_at_index_after(resolved_from, depth)
      check_content_left(next, dist)
    else
      false
    end
  end

  defp close_right(_resolved, dist, depth) when dist <= 0 or depth <= 0, do: {dist, depth}

  defp close_right(resolved, dist, depth) do
    node = ProsemirrorEx.Model.ResolvedPos.node(resolved, depth)
    index_after = ProsemirrorEx.Model.ResolvedPos.index_after(resolved, depth)

    if index_after == Node.child_count(node) do
      close_right(resolved, dist - 1, depth - 1)
    else
      {dist, depth}
    end
  end

  defp node_at_index_after(resolved, depth) do
    node = ProsemirrorEx.Model.ResolvedPos.node(resolved, depth)
    index_after = ProsemirrorEx.Model.ResolvedPos.index_after(resolved, depth)
    Node.maybe_child(node, index_after)
  end

  defp check_content_left(_next, dist) when dist <= 0, do: false
  defp check_content_left(nil, _dist), do: true

  defp check_content_left(next, _dist) when next.type.is_leaf == true do
    true
  end

  defp check_content_left(next, dist) do
    check_content_left(Node.first_child(next), dist - 1)
  end
end

defmodule ProsemirrorEx.Transform.ReplaceAroundStep do
  @moduledoc """
  Replace a part of the document with a slice of content, but
  preserve a range of the replaced content by moving it into the slice.

  Ports `ReplaceAroundStep` from prosemirror-transform/src/replace_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Node}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult}

  defstruct [:from, :to, :gap_from, :gap_to, :slice, :insert, structure: false]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          gap_from: non_neg_integer(),
          gap_to: non_neg_integer(),
          slice: Slice.t(),
          insert: non_neg_integer(),
          structure: boolean()
        }

  @doc "Create a new ReplaceAroundStep."
  def new(from, to, gap_from, gap_to, slice, insert, structure \\ false) do
    %__MODULE__{
      from: from,
      to: to,
      gap_from: gap_from,
      gap_to: gap_to,
      slice: slice,
      insert: insert,
      structure: structure
    }
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    if step.structure and
         (content_between(doc, step.from, step.gap_from) or
            content_between(doc, step.gap_to, step.to)) do
      StepResult.fail("Structure gap-replace would overwrite content")
    else
      gap = Node.slice(doc, step.gap_from, step.gap_to)

      if gap.open_start != 0 or gap.open_end != 0 do
        StepResult.fail("Gap is not a flat range")
      else
        inserted = Slice.insert_at(step.slice, step.insert, gap.content)

        if !inserted do
          StepResult.fail("Content does not fit in gap")
        else
          StepResult.from_replace(doc, step.from, step.to, inserted)
        end
      end
    end
  end

  @impl true
  def step_map(%__MODULE__{} = step) do
    %StepMap{
      ranges: [
        step.from,
        step.gap_from - step.from,
        step.insert,
        step.gap_to,
        step.to - step.gap_to,
        Slice.size(step.slice) - step.insert
      ],
      inverted: false
    }
  end

  @impl true
  def invert(%__MODULE__{} = step, doc) do
    gap = step.gap_to - step.gap_from
    slice_size = Slice.size(step.slice)

    new(
      step.from,
      step.from + slice_size + gap,
      step.from + step.insert,
      step.from + step.insert + gap,
      Node.slice(doc, step.from, step.to)
      |> Slice.remove_between(step.gap_from - step.from, step.gap_to - step.from),
      step.gap_from - step.from,
      step.structure
    )
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    from = Mappable.map_result(mapping, step.from, 1)
    to = Mappable.map_result(mapping, step.to, -1)

    gap_from =
      if step.from == step.gap_from do
        from.pos
      else
        Mappable.map(mapping, step.gap_from, -1)
      end

    gap_to =
      if step.to == step.gap_to do
        to.pos
      else
        Mappable.map(mapping, step.gap_to, 1)
      end

    if (MapResult.deleted_across?(from) and MapResult.deleted_across?(to)) or
         gap_from < from.pos or gap_to > to.pos do
      nil
    else
      new(from.pos, to.pos, gap_from, gap_to, step.slice, step.insert, step.structure)
    end
  end

  @impl true
  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    json = %{
      "stepType" => "replaceAround",
      "from" => step.from,
      "to" => step.to,
      "gapFrom" => step.gap_from,
      "gapTo" => step.gap_to,
      "insert" => step.insert
    }

    json =
      if Slice.size(step.slice) > 0 do
        Map.put(json, "slice", Slice.to_json(step.slice))
      else
        json
      end

    json =
      if step.structure do
        Map.put(json, "structure", true)
      else
        json
      end

    json
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["from"]) and is_number(json["to"]) and
             is_number(json["gapFrom"]) and is_number(json["gapTo"]) and
             is_number(json["insert"]) do
      raise ArgumentError, "Invalid input for ReplaceAroundStep.fromJSON"
    end

    new(
      json["from"],
      json["to"],
      json["gapFrom"],
      json["gapTo"],
      Slice.from_json(schema, json["slice"]),
      json["insert"],
      !!json["structure"]
    )
  end

  # Reuse contentBetween from ReplaceStep
  defp content_between(doc, from, to) do
    resolved_from = Node.resolve(doc, from)
    dist = to - from
    depth = resolved_from.depth

    {dist, depth} = close_right(resolved_from, dist, depth)

    if dist > 0 do
      next = node_at_index_after(resolved_from, depth)
      check_content_left(next, dist)
    else
      false
    end
  end

  defp close_right(_resolved, dist, depth) when dist <= 0 or depth <= 0, do: {dist, depth}

  defp close_right(resolved, dist, depth) do
    node = ProsemirrorEx.Model.ResolvedPos.node(resolved, depth)
    index_after = ProsemirrorEx.Model.ResolvedPos.index_after(resolved, depth)

    if index_after == Node.child_count(node) do
      close_right(resolved, dist - 1, depth - 1)
    else
      {dist, depth}
    end
  end

  defp node_at_index_after(resolved, depth) do
    node = ProsemirrorEx.Model.ResolvedPos.node(resolved, depth)
    index_after = ProsemirrorEx.Model.ResolvedPos.index_after(resolved, depth)
    Node.maybe_child(node, index_after)
  end

  defp check_content_left(_next, dist) when dist <= 0, do: false
  defp check_content_left(nil, _dist), do: true

  defp check_content_left(next, _dist) when next.type.is_leaf == true do
    true
  end

  defp check_content_left(next, dist) do
    check_content_left(Node.first_child(next), dist - 1)
  end
end
