defmodule ProsemirrorEx.Model.ProtocolsTest do
  use ExUnit.Case, async: true

  alias ProsemirrorEx.Model.{Node, Fragment, MarkType, Slice, Schema}
  import ProsemirrorEx.TestHelpers

  describe "Inspect protocol" do
    test "Node inspect produces debug string" do
      {doc_node, _} = doc([p(["hello"])])
      result = inspect(doc_node)
      assert result =~ "doc"
      assert result =~ "paragraph"
      assert result =~ "hello"
    end

    test "text node inspect shows quoted text" do
      schema = test_schema()
      text_node = Schema.text(schema, "hello")
      result = inspect(text_node)
      assert result == "\"hello\""
    end

    test "marked text node inspect wraps with mark names" do
      {_, _} = doc([p([])])
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      text_node = Schema.text(schema, "hello", [em_mark])
      result = inspect(text_node)
      assert result == "em(\"hello\")"
    end

    test "Fragment inspect shows children" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      result = inspect(doc_node.content)
      assert result =~ "paragraph"
    end

    test "empty Fragment inspect" do
      result = inspect(Fragment.empty())
      assert result == "<fragment>"
    end

    test "Mark inspect shows type name" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      result = inspect(em_mark)
      assert result == "em"
    end

    test "Mark with attrs inspect shows attrs" do
      schema = test_schema()

      link_mark =
        MarkType.create(schema.marks["link"], %{"href" => "https://example.com", "title" => nil})

      result = inspect(link_mark)
      assert result =~ "link"
      assert result =~ "href"
      assert result =~ "https://example.com"
    end

    test "Slice inspect shows open depths" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      slice = Node.slice(doc_node, 0, 7)
      result = inspect(slice)
      assert result =~ "("
      assert result =~ ","
    end
  end

  describe "String.Chars protocol" do
    test "Node to_string produces debug string" do
      {doc_node, _} = doc([p(["hello"])])
      result = Kernel.to_string(doc_node)
      assert result =~ "doc"
      assert result =~ "paragraph"
    end

    test "Fragment to_string" do
      result = Kernel.to_string(Fragment.empty())
      assert result == "<fragment>"
    end

    test "Slice to_string" do
      {doc_node, _} = doc([p(["hello"])])
      slice = Node.slice(doc_node, 1, 6)
      result = Kernel.to_string(slice)
      assert is_binary(result)
    end
  end

  describe "Jason.Encoder protocol" do
    test "Node Jason.encode! produces valid JSON" do
      {doc_node, _} = doc([p(["hello"])])
      json_str = Jason.encode!(doc_node)
      decoded = Jason.decode!(json_str)
      assert decoded["type"] == "doc"
      assert is_list(decoded["content"])
    end

    test "Node JSON round-trip preserves structure" do
      {doc_node, _} = doc([p(["hello", em(["world"])])])
      json_str = Jason.encode!(doc_node)
      decoded = Jason.decode!(json_str)
      round_tripped = Node.from_json(test_schema(), decoded)
      assert Node.eq(doc_node, round_tripped)
    end

    test "Fragment Jason.encode! produces valid JSON" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      json_str = Jason.encode!(doc_node.content)
      decoded = Jason.decode!(json_str)
      assert is_list(decoded)
      assert length(decoded) == 2
    end

    test "empty Fragment Jason.encode! produces empty array" do
      json_str = Jason.encode!(Fragment.empty())
      assert json_str == "[]"
    end

    test "Mark Jason.encode! produces valid JSON" do
      schema = test_schema()
      em_mark = MarkType.create(schema.marks["em"])
      json_str = Jason.encode!(em_mark)
      decoded = Jason.decode!(json_str)
      assert decoded == %{"type" => "em"}
    end

    test "Mark with attrs Jason.encode!" do
      schema = test_schema()

      link_mark =
        MarkType.create(schema.marks["link"], %{"href" => "https://example.com", "title" => nil})

      json_str = Jason.encode!(link_mark)
      decoded = Jason.decode!(json_str)
      assert decoded["type"] == "link"
      assert decoded["attrs"]["href"] == "https://example.com"
    end

    test "Slice Jason.encode! produces valid JSON" do
      {doc_node, _} = doc([p(["hello"]), p(["world"])])
      slice = Node.slice(doc_node, 0, 7)
      json_str = Jason.encode!(slice)
      decoded = Jason.decode!(json_str)
      assert is_map(decoded)
    end

    test "empty Slice Jason.encode! produces empty object" do
      json_str = Jason.encode!(Slice.empty())
      assert json_str == "{}"
    end

    test "complex document JSON round-trip via Jason.encode!" do
      {doc_node, _} =
        doc([
          p(["Hello "]),
          blockquote([p(["quoted"])]),
          p([em(["italic"]), strong(["bold"])])
        ])

      json_str = Jason.encode!(doc_node)
      decoded = Jason.decode!(json_str)
      round_tripped = Node.from_json(test_schema(), decoded)
      assert Node.eq(doc_node, round_tripped)
    end
  end
end
