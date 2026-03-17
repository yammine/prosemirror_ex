defmodule ProsemirrorEx.Transform.MarkStepHelper do
  @moduledoc false

  alias ProsemirrorEx.Model.{Fragment, Node}

  @doc """
  Map a fragment, calling f(child, parent, index) on each inline node.
  Recursively processes content of non-leaf nodes first.
  """
  def map_fragment(%Fragment{} = fragment, f, parent) do
    mapped =
      Enum.with_index(fragment.content)
      |> Enum.map(fn {child, i} ->
        child =
          if child.content && child.content.size > 0 do
            Node.copy(child, map_fragment(child.content, f, child))
          else
            child
          end

        if Node.is_inline(child) do
          f.(child, parent, i)
        else
          child
        end
      end)

    Fragment.from_array(mapped)
  end
end

defmodule ProsemirrorEx.Transform.AddMarkStep do
  @moduledoc """
  Add a mark to all inline content between two positions.

  Ports `AddMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Fragment, Node, Mark, NodeType}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult, MarkStepHelper}


  defstruct [:from, :to, :mark]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new AddMarkStep."
  def new(from, to, mark) do
    %__MODULE__{from: from, to: to, mark: mark}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    old_slice = Node.slice(doc, step.from, step.to)
    from_pos = Node.resolve(doc, step.from)

    parent =
      ProsemirrorEx.Model.ResolvedPos.node(
        from_pos,
        ProsemirrorEx.Model.ResolvedPos.shared_depth(from_pos, step.to)
      )

    slice =
      Slice.new(
        MarkStepHelper.map_fragment(
          old_slice.content,
          fn node, par, _i ->
            if !Node.is_atom_node(node) or !NodeType.allows_mark_type(par.type, step.mark.type) do
              node
            else
              Node.mark(node, Mark.add_to_set(step.mark, node.marks || []))
            end
          end,
          parent
        ),
        old_slice.open_start,
        old_slice.open_end
      )

    StepResult.from_replace(doc, step.from, step.to, slice)
  end

  @impl true
  def invert(%__MODULE__{} = step, _doc) do
    ProsemirrorEx.Transform.RemoveMarkStep.new(step.from, step.to, step.mark)
  end

  @impl true
  def step_map(_step) do
    StepMap.empty()
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    from = Mappable.map_result(mapping, step.from, 1)
    to = Mappable.map_result(mapping, step.to, -1)

    if (MapResult.deleted?(from) and MapResult.deleted?(to)) or from.pos >= to.pos do
      nil
    else
      new(from.pos, to.pos, step.mark)
    end
  end

  @impl true
  def merge(%__MODULE__{} = step, %__MODULE__{} = other) do
    if Mark.eq(other.mark, step.mark) and step.from <= other.to and step.to >= other.from do
      new(min(step.from, other.from), max(step.to, other.to), step.mark)
    else
      nil
    end
  end

  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "addMark",
      "mark" => Mark.to_json(step.mark),
      "from" => step.from,
      "to" => step.to
    }
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["from"]) and is_number(json["to"]) do
      raise ArgumentError, "Invalid input for AddMarkStep.fromJSON"
    end

    new(json["from"], json["to"], ProsemirrorEx.Model.Schema.mark_from_json(schema, json["mark"]))
  end
end

defmodule ProsemirrorEx.Transform.RemoveMarkStep do
  @moduledoc """
  Remove a mark from all inline content between two positions.

  Ports `RemoveMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Node, Mark}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult, MarkStepHelper}


  defstruct [:from, :to, :mark]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new RemoveMarkStep."
  def new(from, to, mark) do
    %__MODULE__{from: from, to: to, mark: mark}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    old_slice = Node.slice(doc, step.from, step.to)

    slice =
      Slice.new(
        MarkStepHelper.map_fragment(
          old_slice.content,
          fn node, _parent, _i ->
            Node.mark(node, Mark.remove_from_set(step.mark, node.marks || []))
          end,
          doc
        ),
        old_slice.open_start,
        old_slice.open_end
      )

    StepResult.from_replace(doc, step.from, step.to, slice)
  end

  @impl true
  def invert(%__MODULE__{} = step, _doc) do
    ProsemirrorEx.Transform.AddMarkStep.new(step.from, step.to, step.mark)
  end

  @impl true
  def step_map(_step) do
    StepMap.empty()
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    from = Mappable.map_result(mapping, step.from, 1)
    to = Mappable.map_result(mapping, step.to, -1)

    if (MapResult.deleted?(from) and MapResult.deleted?(to)) or from.pos >= to.pos do
      nil
    else
      new(from.pos, to.pos, step.mark)
    end
  end

  @impl true
  def merge(%__MODULE__{} = step, %__MODULE__{} = other) do
    if Mark.eq(other.mark, step.mark) and step.from <= other.to and step.to >= other.from do
      new(min(step.from, other.from), max(step.to, other.to), step.mark)
    else
      nil
    end
  end

  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "removeMark",
      "mark" => Mark.to_json(step.mark),
      "from" => step.from,
      "to" => step.to
    }
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["from"]) and is_number(json["to"]) do
      raise ArgumentError, "Invalid input for RemoveMarkStep.fromJSON"
    end

    new(json["from"], json["to"], ProsemirrorEx.Model.Schema.mark_from_json(schema, json["mark"]))
  end
end

defmodule ProsemirrorEx.Transform.AddNodeMarkStep do
  @moduledoc """
  Add a mark to a specific node.

  Ports `AddNodeMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Fragment, Node, Mark}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult}


  defstruct [:pos, :mark]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new AddNodeMarkStep."
  def new(pos, mark) do
    %__MODULE__{pos: pos, mark: mark}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if !node do
      StepResult.fail("No node at mark step's position")
    else
      updated =
        ProsemirrorEx.Model.NodeType.create(
          node.type,
          node.attrs,
          nil,
          Mark.add_to_set(step.mark, node.marks || [])
        )

      StepResult.from_replace(
        doc,
        step.pos,
        step.pos + 1,
        Slice.new(Fragment.from(updated), 0, if(Node.is_leaf(node), do: 0, else: 1))
      )
    end
  end

  @impl true
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if node do
      new_set = Mark.add_to_set(step.mark, node.marks || [])

      if length(new_set) == length(node.marks || []) do
        # The mark replaced an existing one; find which mark was replaced
        replaced =
          Enum.find(node.marks || [], fn m ->
            !Mark.is_in_set(m, new_set)
          end)

        if replaced do
          new(step.pos, replaced)
        else
          new(step.pos, step.mark)
        end
      else
        ProsemirrorEx.Transform.RemoveNodeMarkStep.new(step.pos, step.mark)
      end
    else
      ProsemirrorEx.Transform.RemoveNodeMarkStep.new(step.pos, step.mark)
    end
  end

  @impl true
  def step_map(_step) do
    StepMap.empty()
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    pos = Mappable.map_result(mapping, step.pos, 1)

    if MapResult.deleted_after?(pos) do
      nil
    else
      new(pos.pos, step.mark)
    end
  end

  @impl true
  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "addNodeMark",
      "pos" => step.pos,
      "mark" => Mark.to_json(step.mark)
    }
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["pos"]) do
      raise ArgumentError, "Invalid input for AddNodeMarkStep.fromJSON"
    end

    new(json["pos"], ProsemirrorEx.Model.Schema.mark_from_json(schema, json["mark"]))
  end
end

defmodule ProsemirrorEx.Transform.RemoveNodeMarkStep do
  @moduledoc """
  Remove a mark from a specific node.

  Ports `RemoveNodeMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Fragment, Node, Mark}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult}


  defstruct [:pos, :mark]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new RemoveNodeMarkStep."
  def new(pos, mark) do
    %__MODULE__{pos: pos, mark: mark}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if !node do
      StepResult.fail("No node at mark step's position")
    else
      updated =
        ProsemirrorEx.Model.NodeType.create(
          node.type,
          node.attrs,
          nil,
          Mark.remove_from_set(step.mark, node.marks || [])
        )

      StepResult.from_replace(
        doc,
        step.pos,
        step.pos + 1,
        Slice.new(Fragment.from(updated), 0, if(Node.is_leaf(node), do: 0, else: 1))
      )
    end
  end

  @impl true
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if node && Mark.is_in_set(step.mark, node.marks || []) do
      ProsemirrorEx.Transform.AddNodeMarkStep.new(step.pos, step.mark)
    else
      step
    end
  end

  @impl true
  def step_map(_step) do
    StepMap.empty()
  end

  @impl true
  def map(%__MODULE__{} = step, mapping) do
    pos = Mappable.map_result(mapping, step.pos, 1)

    if MapResult.deleted_after?(pos) do
      nil
    else
      new(pos.pos, step.mark)
    end
  end

  @impl true
  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "removeNodeMark",
      "pos" => step.pos,
      "mark" => Mark.to_json(step.mark)
    }
  end

  @impl true
  def from_json(schema, json) do
    unless is_number(json["pos"]) do
      raise ArgumentError, "Invalid input for RemoveNodeMarkStep.fromJSON"
    end

    new(json["pos"], ProsemirrorEx.Model.Schema.mark_from_json(schema, json["mark"]))
  end
end
