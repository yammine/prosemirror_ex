defmodule ProsemirrorEx.Schema.List do
  @moduledoc """
  DX sugar porting [prosemirror-schema-list](https://github.com/ProseMirror/prosemirror-schema-list)
  node specs and `addListNodes/3`.

  Provides base specs for ordered and bullet lists and list items, plus helpers
  to append them to a schema node list. Does not include list commands
  (`wrapInList`, `splitListItem`, etc.).

  ## Example

      nodes =
        ProsemirrorEx.Schema.Basic.nodes()
        |> add_list_nodes("paragraph block*", "block")

      schema = ProsemirrorEx.Model.Schema.new(%{
        "nodes" => nodes,
        "marks" => ProsemirrorEx.Schema.Basic.marks()
      })
  """

  @doc """
  Base ordered list node spec.

  Has a single `order` attribute defaulting to `1`. Content and group are not
  set — use `add_list_nodes/3` or `nodes/2` to fill those in.
  """
  @spec ordered_list() :: map()
  def ordered_list do
    %{"attrs" => %{"order" => %{"default" => 1}}}
  end

  @doc """
  Base bullet list node spec.

  Content and group are not set — use `add_list_nodes/3` or `nodes/2` to fill
  those in.
  """
  @spec bullet_list() :: map()
  def bullet_list, do: %{}

  @doc """
  Base list item node spec.

  Marked as defining. Content is not set — use `add_list_nodes/3` or `nodes/2`
  to fill it in.
  """
  @spec list_item() :: map()
  def list_item do
    %{"defining" => true}
  end

  @doc """
  Returns the three list node entries as `{name, spec}` tuples.

  `item_content` sets the list item content expression (e.g. `"paragraph block*"`).
  When `list_group` is a string, both list types get `"group" => list_group`;
  when `nil`, no group is set.
  """
  @spec nodes(String.t(), String.t() | nil) :: [{String.t(), map()}]
  def nodes(item_content, list_group \\ nil) do
    [
      {"ordered_list", list_spec(ordered_list(), list_group)},
      {"bullet_list", list_spec(bullet_list(), list_group)},
      {"list_item", Map.put(list_item(), "content", item_content)}
    ]
  end

  @doc """
  Appends `ordered_list`, `bullet_list`, and `list_item` to a node list.

  `nodes` is a list of `{name, spec}` tuples in this project's schema format.
  Returns a new list with the three list nodes appended.
  """
  @spec add_list_nodes([{String.t(), map()}], String.t(), String.t() | nil) :: [
          {String.t(), map()}
        ]
  def add_list_nodes(nodes, item_content, list_group \\ nil) do
    nodes ++ nodes(item_content, list_group)
  end

  defp list_spec(base, nil), do: Map.put(base, "content", "list_item+")
  defp list_spec(base, list_group), do: list_spec(base, nil) |> Map.put("group", list_group)
end
