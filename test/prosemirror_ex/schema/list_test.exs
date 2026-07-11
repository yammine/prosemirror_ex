defmodule ProsemirrorEx.Schema.ListTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.{Fragment, Node, NodeType, Schema}
  alias ProsemirrorEx.Schema.{Basic, List}

  defp basic_with_lists_schema do
    Schema.new(%{
      "nodes" => Basic.nodes() |> List.add_list_nodes("paragraph block*", "block"),
      "marks" => Basic.marks()
    })
  end

  describe "base specs" do
    test "ordered_list/0 has order attribute default 1" do
      assert List.ordered_list() == %{"attrs" => %{"order" => %{"default" => 1}}}
    end

    test "bullet_list/0 is an empty base spec" do
      assert List.bullet_list() == %{}
    end

    test "list_item/0 is defining without content" do
      assert List.list_item() == %{"defining" => true}
    end
  end

  describe "nodes/2" do
    test "returns ordered_list, bullet_list, and list_item tuples" do
      names = List.nodes("paragraph block*") |> Enum.map(&elem(&1, 0))
      assert names == ~w(ordered_list bullet_list list_item)
    end
  end

  describe "add_list_nodes/2" do
    test "appends ordered_list, bullet_list, and list_item specs" do
      nodes = Basic.nodes() |> List.add_list_nodes("paragraph block*")
      names = nodes |> Enum.map(&elem(&1, 0))

      assert Enum.take(names, -3) == ~w(ordered_list bullet_list list_item)
    end

    test "list nodes omit group when list_group is not given" do
      nodes = Basic.nodes() |> List.add_list_nodes("paragraph")
      bullet = nodes |> Enum.find(fn {name, _} -> name == "bullet_list" end) |> elem(1)

      refute Map.has_key?(bullet, "group")
    end
  end

  describe "add_list_nodes/3" do
    test "appends list nodes with block group" do
      nodes = Basic.nodes() |> List.add_list_nodes("paragraph block*", "block")

      for name <- ~w(ordered_list bullet_list) do
        {_name, spec} = Enum.find(nodes, fn {n, _} -> n == name end)
        assert spec["group"] == "block"
        assert spec["content"] == "list_item+"
      end
    end

    test "list_item uses given content expression and is defining" do
      nodes = Basic.nodes() |> List.add_list_nodes("paragraph block*", "block")
      {_name, spec} = Enum.find(nodes, fn {name, _} -> name == "list_item" end)

      assert spec["content"] == "paragraph block*"
      assert spec["defining"] == true
    end

    test "ordered_list spec includes order attribute default" do
      nodes = Basic.nodes() |> List.add_list_nodes("paragraph block*", "block")
      {_name, spec} = Enum.find(nodes, fn {name, _} -> name == "ordered_list" end)

      assert spec["attrs"] == %{"order" => %{"default" => 1}}
    end
  end

  describe "composed schema" do
    test "Basic.nodes |> add_list_nodes + Basic.marks builds a valid schema" do
      schema = basic_with_lists_schema()

      for name <- ~w(bullet_list ordered_list list_item) do
        assert Map.has_key?(schema.nodes, name)
      end

      for name <- ~w(link em strong code) do
        assert Map.has_key?(schema.marks, name)
      end
    end

    test "ordered_list node defaults order attribute to 1" do
      schema = basic_with_lists_schema()
      assert schema.nodes["ordered_list"].default_attrs == %{"order" => 1}

      ol =
        Schema.node(schema, "ordered_list", nil, [
          Schema.node(schema, "list_item", nil, [
            Schema.node(schema, "paragraph", nil, [Schema.text(schema, "item")])
          ])
        ])

      assert ol.attrs == %{"order" => 1}
    end
  end

  describe "list document construction" do
    setup do
      %{schema: basic_with_lists_schema()}
    end

    test "builds bullet_list content that validates", %{schema: schema} do
      item = list_item(schema, "one")
      list = Schema.node(schema, "bullet_list", nil, [item])

      assert list.type.name == "bullet_list"
      assert NodeType.valid_content(schema.nodes["bullet_list"], list.content)
      assert NodeType.valid_content(schema.nodes["doc"], Fragment.from([list]))
    end

    test "builds ordered_list content that validates", %{schema: schema} do
      items = [
        list_item(schema, "first"),
        list_item(schema, "second")
      ]

      list = Schema.node(schema, "ordered_list", %{"order" => 3}, items)

      assert list.type.name == "ordered_list"
      assert list.attrs == %{"order" => 3}
      assert Node.child_count(list) == 2
      assert NodeType.valid_content(schema.nodes["ordered_list"], list.content)
    end

    test "list_item accepts paragraph followed by blockquote", %{schema: schema} do
      paragraph = Schema.node(schema, "paragraph", nil, [Schema.text(schema, "lead")])
      blockquote = Schema.node(schema, "blockquote", nil, [paragraph])
      item = Schema.node(schema, "list_item", nil, [paragraph, blockquote])

      assert NodeType.valid_content(schema.nodes["list_item"], item.content)
    end

    test "list_item rejects blockquote without leading paragraph", %{schema: schema} do
      paragraph = Schema.node(schema, "paragraph", nil, [])
      blockquote = Schema.node(schema, "blockquote", nil, [paragraph])
      content = Fragment.from([blockquote])

      refute NodeType.valid_content(schema.nodes["list_item"], content)
    end
  end

  defp list_item(schema, text) do
    Schema.node(schema, "list_item", nil, [
      Schema.node(schema, "paragraph", nil, [Schema.text(schema, text)])
    ])
  end
end
