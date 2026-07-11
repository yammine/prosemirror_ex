defmodule ProsemirrorEx.Schema.Basic do
  @moduledoc """
  Node and mark specifications from
  [`prosemirror-schema-basic`](https://github.com/ProseMirror/prosemirror-schema-basic).

  This is the CommonMark-oriented schema minus list nodes (see
  `ProsemirrorEx.Schema.List`). DOM `parseDOM` / `toDOM` rules are omitted.

  ## Usage

      schema = ProsemirrorEx.Schema.Basic.schema()

      doc =
        ProsemirrorEx.Model.Schema.node(schema, "doc", nil, [
          ProsemirrorEx.Model.Schema.node(schema, "paragraph", nil, [
            ProsemirrorEx.Model.Schema.text(schema, "hello")
          ])
        ])
  """

  alias ProsemirrorEx.Model.Schema

  @doc_spec %{"content" => "block+"}

  @paragraph_spec %{
    "content" => "inline*",
    "group" => "block"
  }

  @blockquote_spec %{
    "content" => "block+",
    "group" => "block",
    "defining" => true
  }

  @horizontal_rule_spec %{"group" => "block"}

  @heading_spec %{
    "attrs" => %{"level" => %{"default" => 1}},
    "content" => "inline*",
    "group" => "block",
    "defining" => true
  }

  @code_block_spec %{
    "content" => "text*",
    "marks" => "",
    "group" => "block",
    "code" => true,
    "defining" => true
  }

  @text_spec %{"group" => "inline"}

  @image_spec %{
    "inline" => true,
    "attrs" => %{
      "src" => %{},
      "alt" => %{"default" => nil},
      "title" => %{"default" => nil}
    },
    "group" => "inline",
    "draggable" => true
  }

  @hard_break_spec %{
    "inline" => true,
    "group" => "inline",
    "selectable" => false
  }

  @link_spec %{
    "attrs" => %{
      "href" => %{},
      "title" => %{"default" => nil}
    },
    "inclusive" => false
  }

  @em_spec %{}
  @strong_spec %{}
  @code_mark_spec %{"code" => true}

  @doc """
  Node specifications as `{name, spec}` tuples for `Schema.new/1`.
  """
  def nodes do
    [
      {"doc", @doc_spec},
      {"paragraph", @paragraph_spec},
      {"blockquote", @blockquote_spec},
      {"horizontal_rule", @horizontal_rule_spec},
      {"heading", @heading_spec},
      {"code_block", @code_block_spec},
      {"text", @text_spec},
      {"image", @image_spec},
      {"hard_break", @hard_break_spec}
    ]
  end

  @doc """
  Mark specifications as `{name, spec}` tuples for `Schema.new/1`.
  """
  def marks do
    [
      {"link", @link_spec},
      {"em", @em_spec},
      {"strong", @strong_spec},
      {"code", @code_mark_spec}
    ]
  end

  @doc """
  A compiled schema with the basic node and mark types.
  """
  def schema do
    Schema.new(%{"nodes" => nodes(), "marks" => marks()})
  end

  @doc """
  Individual node spec maps keyed by name, for extending or composing schemas.
  """
  def node_specs do
    %{
      "doc" => @doc_spec,
      "paragraph" => @paragraph_spec,
      "blockquote" => @blockquote_spec,
      "horizontal_rule" => @horizontal_rule_spec,
      "heading" => @heading_spec,
      "code_block" => @code_block_spec,
      "text" => @text_spec,
      "image" => @image_spec,
      "hard_break" => @hard_break_spec
    }
  end

  @doc """
  Individual mark spec maps keyed by name, for extending or composing schemas.
  """
  def mark_specs do
    %{
      "link" => @link_spec,
      "em" => @em_spec,
      "strong" => @strong_spec,
      "code" => @code_mark_spec
    }
  end
end
