defmodule ProsemirrorEx.Transform.AttrStep do
  @moduledoc """
  Update an attribute in a specific node.

  Ports `AttrStep` from prosemirror-transform/src/attr_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Model.{Slice, Fragment, Node}
  alias ProsemirrorEx.Transform.{StepMap, StepResult, Mappable, MapResult}

  defstruct [:pos, :attr, :value]

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          attr: String.t(),
          value: any()
        }

  @doc "Create a new AttrStep."
  def new(pos, attr, value) do
    %__MODULE__{pos: pos, attr: attr, value: value}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)

    if !node do
      StepResult.fail("No node at attribute step's position")
    else
      attrs =
        node.attrs
        |> Kernel.||(%{})
        |> Map.put(step.attr, step.value)

      updated =
        ProsemirrorEx.Model.NodeType.create(
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
  def invert(%__MODULE__{} = step, doc) do
    node = Node.node_at(doc, step.pos)
    old_value = (node.attrs || %{})[step.attr]
    new(step.pos, step.attr, old_value)
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
      new(pos.pos, step.attr, step.value)
    end
  end

  @impl true
  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "attr",
      "pos" => step.pos,
      "attr" => step.attr,
      "value" => step.value
    }
  end

  @impl true
  def from_json(_schema, json) do
    unless is_number(json["pos"]) and is_binary(json["attr"]) do
      raise ArgumentError, "Invalid input for AttrStep.fromJSON"
    end

    new(json["pos"], json["attr"], json["value"])
  end
end

defmodule ProsemirrorEx.Transform.DocAttrStep do
  @moduledoc """
  Update an attribute in the doc node.

  Ports `DocAttrStep` from prosemirror-transform/src/attr_step.ts.
  """

  @behaviour ProsemirrorEx.Transform.Step

  alias ProsemirrorEx.Transform.{StepMap, StepResult}

  defstruct [:attr, :value]

  @type t :: %__MODULE__{
          attr: String.t(),
          value: any()
        }

  @doc "Create a new DocAttrStep."
  def new(attr, value) do
    %__MODULE__{attr: attr, value: value}
  end

  @impl true
  def apply(%__MODULE__{} = step, doc) do
    attrs =
      doc.attrs
      |> Kernel.||(%{})
      |> Map.put(step.attr, step.value)

    updated =
      ProsemirrorEx.Model.NodeType.create(
        doc.type,
        attrs,
        doc.content,
        doc.marks
      )

    StepResult.ok(updated)
  end

  @impl true
  def invert(%__MODULE__{} = step, doc) do
    old_value = (doc.attrs || %{})[step.attr]
    new(step.attr, old_value)
  end

  @impl true
  def step_map(_step) do
    StepMap.empty()
  end

  @impl true
  def map(%__MODULE__{} = step, _mapping) do
    step
  end

  @impl true
  def merge(_step, _other), do: nil

  @impl true
  def to_json(%__MODULE__{} = step) do
    %{
      "stepType" => "docAttr",
      "attr" => step.attr,
      "value" => step.value
    }
  end

  @impl true
  def from_json(_schema, json) do
    unless is_binary(json["attr"]) do
      raise ArgumentError, "Invalid input for DocAttrStep.fromJSON"
    end

    new(json["attr"], json["value"])
  end
end
