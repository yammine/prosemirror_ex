defmodule ProsemirrorEx.Model.JsonRoundTripTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.{Node, Schema}

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defp test_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"horizontal_rule", %{"group" => "block"}},
        {"heading",
         %{
           "content" => "inline*",
           "group" => "block",
           "attrs" => %{"level" => %{"default" => 1}}
         }},
        {"code_block", %{"content" => "text*", "group" => "block", "code" => true}},
        {"text", %{"group" => "inline"}},
        {"image",
         %{
           "group" => "inline",
           "inline" => true,
           "attrs" => %{
             "src" => %{"default" => "img.png"},
             "alt" => %{"default" => nil},
             "title" => %{"default" => nil}
           }
         }},
        {"hard_break", %{"group" => "inline", "inline" => true}},
        {"ordered_list",
         %{
           "content" => "list_item+",
           "group" => "block",
           "attrs" => %{"order" => %{"default" => 1}}
         }},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"list_item", %{"content" => "paragraph block*"}}
      ],
      "marks" => [
        {"link",
         %{
           "attrs" => %{"href" => %{"default" => "foo"}, "title" => %{"default" => nil}},
           "inclusive" => false
         }},
        {"em", %{}},
        {"strong", %{}},
        {"code", %{}}
      ]
    })
  end

  # Dynamic tests for each fixture file
  for file <- Path.wildcard(Path.join(@fixtures_dir, "*.json")) do
    fixture_name = Path.basename(file, ".json")

    test "round-trips #{fixture_name}" do
      json_str = File.read!(unquote(file))
      json = Jason.decode!(json_str)
      schema = test_schema()
      node = Node.from_json(schema, json)
      result = Node.to_json(node)
      assert result == json
    end
  end

  describe "additional round-trip scenarios" do
    test "round-trip preserves mark ordering" do
      schema = test_schema()

      json = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "marks" => [%{"type" => "em"}, %{"type" => "strong"}],
                "text" => "bold italic"
              }
            ]
          }
        ]
      }

      node = Node.from_json(schema, json)
      result = Node.to_json(node)
      marks = hd(result["content"])["content"] |> hd() |> Map.get("marks")
      assert Enum.map(marks, & &1["type"]) == ["em", "strong"]
    end

    test "round-trip with multiple paragraphs" do
      schema = test_schema()

      json = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "first"}]
          },
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "second"}]
          }
        ]
      }

      node = Node.from_json(schema, json)
      assert Node.to_json(node) == json
    end

    test "round-trip deeply nested blockquotes" do
      schema = test_schema()

      json = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "blockquote",
            "content" => [
              %{
                "type" => "blockquote",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "deep"}]
                  }
                ]
              }
            ]
          }
        ]
      }

      node = Node.from_json(schema, json)
      assert Node.to_json(node) == json
    end

    test "from_json then to_json produces structurally equal nodes" do
      schema = test_schema()

      json = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "hello"},
              %{"type" => "text", "marks" => [%{"type" => "em"}], "text" => "world"}
            ]
          }
        ]
      }

      node1 = Node.from_json(schema, json)
      node2 = Node.from_json(schema, Node.to_json(node1))
      assert Node.eq(node1, node2)
    end
  end
end
