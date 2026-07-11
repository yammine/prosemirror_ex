# Run with: mix run examples/schema_demo.exs
#
# Demonstrates ProsemirrorEx.Schema.Basic + Schema.List convenience APIs
# versus hand-written Schema.new/1 maps.

alias ProsemirrorEx.Schema.{Basic, List}
alias ProsemirrorEx.Model.{Schema, Node}

banner = fn title ->
  line = String.duplicate("─", 62)
  IO.puts("\n#{line}\n  #{title}\n#{line}")
end

banner.("ProsemirrorEx — Schema.Basic + Schema.List Demo")

item_content = "paragraph block*"
list_group = "block"

verbose_spec = %{
  "nodes" => Basic.nodes() |> List.add_list_nodes(item_content, list_group),
  "marks" => Basic.marks()
}

banner.("BEFORE — verbose Schema.new/1 map")

IO.puts("""
Schema.new(%{
  "nodes" => [
    {"doc", %{"content" => "block+"}},
    {"paragraph", %{"content" => "inline*", "group" => "block"}},
    {"blockquote", %{"content" => "block+", "group" => "block", "defining" => true}},
    {"horizontal_rule", %{"group" => "block"}},
    {"heading", %{"content" => "inline*", "group" => "block", ...}},
    {"code_block", %{"content" => "text*", "group" => "block", ...}},
    {"text", %{"group" => "inline"}},
    {"image", %{"group" => "inline", "inline" => true, ...}},
    {"hard_break", %{"group" => "inline", "inline" => true}},
    {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
    {"ordered_list", %{"content" => "list_item+", "group" => "block", ...}},
    {"list_item", %{"content" => "#{item_content}", "defining" => true}}
  ],
  "marks" => [
    {"link", %{...}},
    {"em", %{}},
    {"strong", %{}},
    {"code", %{}}
  ]
})
""")

IO.puts("Full spec (#{length(verbose_spec["nodes"])} nodes, #{length(verbose_spec["marks"])} marks):")
IO.puts(inspect(verbose_spec, pretty: true, limit: :infinity, printable_limit: :infinity))

banner.("AFTER — one-liner Basic + List composition")

IO.puts("""
alias ProsemirrorEx.Schema.{Basic, List}
alias ProsemirrorEx.Model.Schema

schema =
  Schema.new(%{
    "nodes" => Basic.nodes() |> List.add_list_nodes("#{item_content}", "#{list_group}"),
    "marks" => Basic.marks()
  })

# Without lists: Basic.schema()
""")

schema = Schema.new(verbose_spec)

banner.("Sample document built with the composed schema")

em = Schema.mark(schema, "em")
strong = Schema.mark(schema, "strong")

doc =
  Schema.node(schema, "doc", nil, [
    Schema.node(schema, "heading", %{"level" => 1}, [
      Schema.text(schema, "Schema.Basic + Schema.List Demo")
    ]),
    Schema.node(schema, "paragraph", nil, [
      Schema.text(schema, "Plain text, "),
      Schema.text(schema, "emphasized", [em]),
      Schema.text(schema, ", and "),
      Schema.text(schema, "bold", [strong]),
      Schema.text(schema, ".")
    ]),
    Schema.node(schema, "blockquote", nil, [
      Schema.node(schema, "paragraph", nil, [
        Schema.text(schema, "A blockquote with a nested paragraph.")
      ])
    ]),
    Schema.node(schema, "bullet_list", nil, [
      Schema.node(schema, "list_item", nil, [
        Schema.node(schema, "paragraph", nil, [Schema.text(schema, "First bullet")])
      ]),
      Schema.node(schema, "list_item", nil, [
        Schema.node(schema, "paragraph", nil, [Schema.text(schema, "Second bullet")])
      ])
    ]),
    Schema.node(schema, "ordered_list", %{"order" => 1}, [
      Schema.node(schema, "list_item", nil, [
        Schema.node(schema, "paragraph", nil, [Schema.text(schema, "Step one")])
      ]),
      Schema.node(schema, "list_item", nil, [
        Schema.node(schema, "paragraph", nil, [Schema.text(schema, "Step two")])
      ])
    ]),
    Schema.node(schema, "code_block", nil, [
      Schema.text(schema, "def hello, do: :world")
    ]),
    Schema.node(schema, "horizontal_rule", nil, [])
  ])

json =
  doc
  |> Node.to_json()
  |> Jason.encode!(pretty: true)

IO.puts(json)

banner.("Composed schema — node types")

node_names = schema.nodes |> Map.keys() |> Enum.sort()
IO.puts(Enum.join(node_names, ", "))
IO.puts("(#{length(node_names)} total)")

banner.("Composed schema — mark types")

mark_names = schema.marks |> Map.keys() |> Enum.sort()
IO.puts(Enum.join(mark_names, ", "))
IO.puts("(#{length(mark_names)} total)")

banner.("Done — exit 0")
