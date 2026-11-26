defmodule ProsemirrorEx.Transform.MarkStepHelper do
  @moduledoc false

  alias ProsemirrorEx.Model.{Fragment, Mark, Node, NodeType, RangeError, Schema, Slice}
  alias ProsemirrorEx.Transform.{Mappable, MapResult, Step, StepResult}

  @doc """
  Map a fragment, calling `f.(child, parent)` on each inline node.
  Recursively processes content of non-leaf nodes first.
  """
  @spec map_fragment(Fragment.t(), (Node.t(), Node.t() -> Node.t()), Node.t()) :: Fragment.t()
  def map_fragment(%Fragment{} = fragment, f, parent) do
    mapped =
      Enum.map(fragment.content, fn child ->
        child =
          if child.content && child.content.size > 0 do
            Node.copy(child, map_fragment(child.content, f, child))
          else
            child
          end

        if Node.is_inline(child) do
          f.(child, parent)
        else
          child
        end
      end)

    Fragment.from_array(mapped)
  end

  @doc false
  @spec replace_range_marks(
          Node.t(),
          integer(),
          integer(),
          Node.t(),
          (Node.t(), Node.t() -> Node.t())
        ) :: StepResult.t()
  def replace_range_marks(doc, from, to, parent, mapper) do
    doc_size = (doc.content || Fragment.empty()).size

    if from < 0 or to > doc_size or from > to do
      StepResult.fail("Position out of range")
    else
      try do
        old_slice = Node.slice(doc, from, to)

        slice =
          Slice.new(
            map_fragment(old_slice.content, mapper, parent),
            old_slice.open_start,
            old_slice.open_end
          )

        StepResult.from_replace(doc, from, to, slice)
      rescue
        e in [RangeError] ->
          StepResult.fail(e.message)
      end
    end
  end

  @doc false
  @spec map_range_mark(struct(), Mappable.t()) :: struct() | nil
  def map_range_mark(%{__struct__: mod} = step, mapping) do
    from = Mappable.map_result(mapping, step.from, 1)
    to = Mappable.map_result(mapping, step.to, -1)

    if (MapResult.deleted?(from) and MapResult.deleted?(to)) or from.pos >= to.pos do
      nil
    else
      mod.new(from.pos, to.pos, step.mark)
    end
  end

  @doc false
  @spec merge_range_mark(struct(), struct()) :: struct() | nil
  def merge_range_mark(%{__struct__: mod} = step, %{__struct__: mod} = other) do
    if Mark.eq(other.mark, step.mark) and step.from <= other.to and step.to >= other.from do
      mod.new(min(step.from, other.from), max(step.to, other.to), step.mark)
    else
      nil
    end
  end

  def merge_range_mark(_step, _other), do: nil

  @doc false
  @spec range_mark_from_json(Schema.t() | nil, term(), module(), String.t()) :: struct()
  def range_mark_from_json(schema, json, mod, step_name) do
    Step.validate_json_map!(json, step_name)
    from = Step.parse_non_neg_int!(json, "from", step_name)
    to = Step.parse_non_neg_int!(json, "to", step_name)

    if from > to do
      raise ArgumentError, "Invalid input for #{step_name}.fromJSON"
    end

    mark = Step.parse_mark!(schema, Map.get(json, "mark"), step_name)
    mod.new(from, to, mark)
  end

  @doc false
  @spec apply_node_mark(struct(), Node.t(), ([Mark.t()] -> [Mark.t()])) :: StepResult.t()
  def apply_node_mark(step, doc, mark_fn) do
    node = Node.node_at(doc, step.pos)

    cond do
      is_nil(node) ->
        StepResult.fail("No node at mark step's position")

      Node.is_text(node) ->
        StepResult.fail("Cannot apply node mark step to a text node")

      true ->
        updated =
          NodeType.create(
            node.type,
            node.attrs,
            nil,
            mark_fn.(node.marks || [])
          )

        StepResult.from_replace(
          doc,
          step.pos,
          step.pos + 1,
          Slice.new(Fragment.from(updated), 0, if(Node.is_leaf(node), do: 0, else: 1))
        )
    end
  end

  @doc false
  @spec map_node_mark(struct(), Mappable.t()) :: struct() | nil
  def map_node_mark(%{__struct__: mod} = step, mapping) do
    pos = Mappable.map_result(mapping, step.pos, 1)

    if MapResult.deleted_after?(pos) do
      nil
    else
      mod.new(pos.pos, step.mark)
    end
  end

  @doc false
  @spec node_mark_from_json(Schema.t() | nil, term(), module(), String.t()) :: struct()
  def node_mark_from_json(schema, json, mod, step_name) do
    Step.validate_json_map!(json, step_name)
    pos = Step.parse_non_neg_int!(json, "pos", step_name)
    mark = Step.parse_mark!(schema, Map.get(json, "mark"), step_name)
    mod.new(pos, mark)
  end
end

defmodule ProsemirrorEx.Transform.AddMarkStep do
  @moduledoc """
  Add a mark to all inline content between two positions.

  Ports `AddMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Fragment, Mark, Node, NodeType, ResolvedPos, Schema}
  alias ProsemirrorEx.Transform.{Mappable, MarkStepHelper, Step, StepMap, StepResult}

  defstruct [:from, :to, :mark]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new AddMarkStep."
  @spec new(non_neg_integer(), non_neg_integer(), Mark.t()) :: t()
  def new(from, to, mark) do
    %__MODULE__{from: from, to: to, mark: mark}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    doc_size = (doc.content || Fragment.empty()).size

    if step.from < 0 or step.to > doc_size or step.from > step.to do
      StepResult.fail("Position out of range")
    else
      from_pos = Node.resolve(doc, step.from)
      parent = ResolvedPos.node(from_pos, ResolvedPos.shared_depth(from_pos, step.to))

      MarkStepHelper.replace_range_marks(doc, step.from, step.to, parent, fn node, par ->
        if !Node.is_atom_node(node) or !NodeType.allows_mark_type(par.type, step.mark.type) do
          node
        else
          Node.mark(node, Mark.add_to_set(step.mark, node.marks || []))
        end
      end)
    end
  end

  @impl true
  @spec invert(t(), Node.t() | nil) :: ProsemirrorEx.Transform.RemoveMarkStep.t()
  def invert(%__MODULE__{} = step, _doc) do
    ProsemirrorEx.Transform.RemoveMarkStep.new(step.from, step.to, step.mark)
  end

  @impl true
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t() | nil
  def map(%__MODULE__{} = step, mapping), do: MarkStepHelper.map_range_mark(step, mapping)

  @impl true
  @spec merge(t(), Step.step()) :: t() | nil
  def merge(%__MODULE__{} = step, other), do: MarkStepHelper.merge_range_mark(step, other)

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "addMark",
      "mark" => Mark.to_json(step.mark),
      "from" => step.from,
      "to" => step.to
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(schema, json) do
    MarkStepHelper.range_mark_from_json(schema, json, __MODULE__, "AddMarkStep")
  end
end

defmodule ProsemirrorEx.Transform.RemoveMarkStep do
  @moduledoc """
  Remove a mark from all inline content between two positions.

  Ports `RemoveMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Mark, Node, Schema}
  alias ProsemirrorEx.Transform.{Mappable, MarkStepHelper, Step, StepMap, StepResult}

  defstruct [:from, :to, :mark]

  @type t :: %__MODULE__{
          from: non_neg_integer(),
          to: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new RemoveMarkStep."
  @spec new(non_neg_integer(), non_neg_integer(), Mark.t()) :: t()
  def new(from, to, mark) do
    %__MODULE__{from: from, to: to, mark: mark}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    MarkStepHelper.replace_range_marks(doc, step.from, step.to, doc, fn node, _parent ->
      Node.mark(node, Mark.remove_from_set(step.mark, node.marks || []))
    end)
  end

  @impl true
  @spec invert(t(), Node.t() | nil) :: ProsemirrorEx.Transform.AddMarkStep.t()
  def invert(%__MODULE__{} = step, _doc) do
    ProsemirrorEx.Transform.AddMarkStep.new(step.from, step.to, step.mark)
  end

  @impl true
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t() | nil
  def map(%__MODULE__{} = step, mapping), do: MarkStepHelper.map_range_mark(step, mapping)

  @impl true
  @spec merge(t(), Step.step()) :: t() | nil
  def merge(%__MODULE__{} = step, other), do: MarkStepHelper.merge_range_mark(step, other)

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "removeMark",
      "mark" => Mark.to_json(step.mark),
      "from" => step.from,
      "to" => step.to
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(schema, json) do
    MarkStepHelper.range_mark_from_json(schema, json, __MODULE__, "RemoveMarkStep")
  end
end

defmodule ProsemirrorEx.Transform.AddNodeMarkStep do
  @moduledoc """
  Add a mark to a specific node.

  Ports `AddNodeMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Mark, Node, Schema}
  alias ProsemirrorEx.Transform.{Mappable, MarkStepHelper, Step, StepMap, StepResult}

  defstruct [:pos, :mark]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new AddNodeMarkStep."
  @spec new(non_neg_integer(), Mark.t()) :: t()
  def new(pos, mark) do
    %__MODULE__{pos: pos, mark: mark}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    MarkStepHelper.apply_node_mark(step, doc, &Mark.add_to_set(step.mark, &1))
  end

  @impl true
  @spec invert(t(), Node.t()) :: t() | ProsemirrorEx.Transform.RemoveNodeMarkStep.t()
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if node do
      new_set = Mark.add_to_set(step.mark, node.marks || [])

      if length(new_set) == length(node.marks || []) do
        replaced = Enum.find(node.marks || [], fn m -> !Mark.is_in_set(m, new_set) end)

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
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t() | nil
  def map(%__MODULE__{} = step, mapping), do: MarkStepHelper.map_node_mark(step, mapping)

  @impl true
  @spec merge(t(), Step.step()) :: nil
  def merge(_step, _other), do: nil

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "addNodeMark",
      "pos" => step.pos,
      "mark" => Mark.to_json(step.mark)
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(schema, json) do
    MarkStepHelper.node_mark_from_json(schema, json, __MODULE__, "AddNodeMarkStep")
  end
end

defmodule ProsemirrorEx.Transform.RemoveNodeMarkStep do
  @moduledoc """
  Remove a mark from a specific node.

  Ports `RemoveNodeMarkStep` from prosemirror-transform/src/mark_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Mark, Node, Schema}
  alias ProsemirrorEx.Transform.{Mappable, MarkStepHelper, Step, StepMap, StepResult}

  defstruct [:pos, :mark]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          mark: Mark.t()
        }

  @doc "Create a new RemoveNodeMarkStep."
  @spec new(non_neg_integer(), Mark.t()) :: t()
  def new(pos, mark) do
    %__MODULE__{pos: pos, mark: mark}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    MarkStepHelper.apply_node_mark(step, doc, &Mark.remove_from_set(step.mark, &1))
  end

  @impl true
  @spec invert(t(), Node.t()) :: t() | ProsemirrorEx.Transform.AddNodeMarkStep.t()
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if node && Mark.is_in_set(step.mark, node.marks || []) do
      ProsemirrorEx.Transform.AddNodeMarkStep.new(step.pos, step.mark)
    else
      step
    end
  end

  @impl true
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t() | nil
  def map(%__MODULE__{} = step, mapping), do: MarkStepHelper.map_node_mark(step, mapping)

  @impl true
  @spec merge(t(), Step.step()) :: nil
  def merge(_step, _other), do: nil

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "removeNodeMark",
      "pos" => step.pos,
      "mark" => Mark.to_json(step.mark)
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(schema, json) do
    MarkStepHelper.node_mark_from_json(schema, json, __MODULE__, "RemoveNodeMarkStep")
  end
end
