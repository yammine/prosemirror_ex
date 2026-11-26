defmodule ProsemirrorEx.Transform.AttrStep do
  @moduledoc """
  Update an attribute in a specific node.

  Ports `AttrStep` from prosemirror-transform/src/attr_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Fragment, Node, NodeType, Schema, Slice}
  alias ProsemirrorEx.Transform.{Mappable, MapResult, Step, StepMap, StepResult}

  defstruct [:pos, :attr, :value]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          attr: String.t(),
          value: any()
        }

  @doc "Create a new AttrStep."
  @spec new(non_neg_integer(), String.t(), any()) :: t()
  def new(pos, attr, value) do
    %__MODULE__{pos: pos, attr: attr, value: value}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    cond do
      is_nil(node) ->
        StepResult.fail("No node at attribute step's position")

      Node.is_text(node) ->
        StepResult.fail("Cannot apply attribute step to a text node")

      true ->
        attrs =
          node.attrs
          |> Kernel.||(%{})
          |> Map.put(step.attr, step.value)

        updated =
          NodeType.create(
            node.type,
            attrs,
            nil,
            node.marks
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
  @spec invert(t(), Node.t()) :: t()
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)
    old_value = if node, do: (node.attrs || %{})[step.attr], else: nil
    new(step.pos, step.attr, old_value)
  end

  @impl true
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t() | nil
  def map(%__MODULE__{} = step, mapping) do
    pos = Mappable.map_result(mapping, step.pos, 1)

    if MapResult.deleted_after?(pos) do
      nil
    else
      new(pos.pos, step.attr, step.value)
    end
  end

  @impl true
  @spec merge(t(), Step.step()) :: nil
  def merge(_step, _other), do: nil

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "attr",
      "pos" => step.pos,
      "attr" => step.attr,
      "value" => step.value
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(_schema, json) do
    Step.validate_json_map!(json, "AttrStep")
    pos = Step.parse_non_neg_int!(json, "pos", "AttrStep")
    attr = json["attr"]

    unless is_binary(attr) do
      raise ArgumentError, "Invalid input for AttrStep.fromJSON"
    end

    new(pos, attr, json["value"])
  end
end

defmodule ProsemirrorEx.Transform.DocAttrStep do
  @moduledoc """
  Update an attribute in the doc node.

  Ports `DocAttrStep` from prosemirror-transform/src/attr_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Node, NodeType, Schema}
  alias ProsemirrorEx.Transform.{Mappable, Step, StepMap, StepResult}

  defstruct [:attr, :value]

  @type t :: %__MODULE__{
          attr: String.t(),
          value: any()
        }

  @doc "Create a new DocAttrStep."
  @spec new(String.t(), any()) :: t()
  def new(attr, value) do
    %__MODULE__{attr: attr, value: value}
  end

  @impl true
  @spec apply(t(), Node.t()) :: StepResult.t()
  def apply(%__MODULE__{} = step, doc) do
    attrs =
      doc.attrs
      |> Kernel.||(%{})
      |> Map.put(step.attr, step.value)

    updated =
      NodeType.create(
        doc.type,
        attrs,
        doc.content,
        doc.marks
      )

    StepResult.ok(updated)
  end

  @impl true
  @spec invert(t(), Node.t()) :: t()
  def invert(%__MODULE__{} = step, doc) do
    old_value = (doc.attrs || %{})[step.attr]
    new(step.attr, old_value)
  end

  @impl true
  @spec step_map(t()) :: StepMap.t()
  def step_map(_step), do: StepMap.empty()

  @impl true
  @spec map(t(), Mappable.t()) :: t()
  def map(%__MODULE__{} = step, _mapping), do: step

  @impl true
  @spec merge(t(), Step.step()) :: nil
  def merge(_step, _other), do: nil

  @impl true
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "docAttr",
      "attr" => step.attr,
      "value" => step.value
    }
  end

  @impl true
  @spec from_json(Schema.t() | nil, map()) :: t()
  def from_json(_schema, json) do
    Step.validate_json_map!(json, "DocAttrStep")
    attr = json["attr"]

    unless is_binary(attr) do
      raise ArgumentError, "Invalid input for DocAttrStep.fromJSON"
    end

    new(attr, json["value"])
  end
end
