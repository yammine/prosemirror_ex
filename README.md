# ProsemirrorEx

[![CI](https://github.com/yammine/prosemirror_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/yammine/prosemirror_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/prosemirror_ex.svg)](https://hex.pm/packages/prosemirror_ex)

Elixir port of the [ProseMirror](https://prosemirror.net/) document model and transform libraries. Enables server-side ProseMirror document manipulation with full wire-format JSON compatibility.

## Features

- **Document Model** (`ProsemirrorEx.Model`) — complete port of [prosemirror-model](https://github.com/ProseMirror/prosemirror-model)
- **Transforms** (`ProsemirrorEx.Transform`) — complete port of [prosemirror-transform](https://github.com/ProseMirror/prosemirror-transform)
- **Authority Server** (`ProsemirrorEx.Authority`) — collaborative editing server with version tracking and step history
- **Wire-format compatible** — JSON serialization is identical to the JS libraries
- **Arbitrary schemas** — define any ProseMirror schema, not just the basic one

## Installation

Add `prosemirror_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:prosemirror_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
alias ProsemirrorEx.Model.{Schema, Node}
alias ProsemirrorEx.Transform.Transform

# Define a schema
schema = Schema.new(%{
  "nodes" => [
    {"doc", %{"content" => "block+"}},
    {"paragraph", %{"content" => "inline*", "group" => "block"}},
    {"text", %{"group" => "inline"}}
  ],
  "marks" => [
    {"em", %{}},
    {"strong", %{}}
  ]
})

# Create a document
doc = Schema.node(schema, "doc", nil, [
  Schema.node(schema, "paragraph", nil, [
    Schema.text(schema, "Hello world")
  ])
])

# Transform it
tr = Transform.new(doc)
     |> Transform.add_mark(1, 6, Schema.mark(schema, "strong"))

new_doc = tr.doc
# doc(paragraph(strong("Hello"), " world"))

# Serialize to JSON (compatible with JS ProseMirror)
json = Node.to_json(new_doc)

# Deserialize from JSON
restored = Node.from_json(schema, json)
```

## Authority Server (Collaborative Editing)

Implements the central authority from the [ProseMirror collab guide](https://prosemirror.net/docs/guides/collab/): version tracking, step acceptance, and catch-up history. Built on `Model` + `Transform` only — client packages (`prosemirror-collab`, `prosemirror-state`, `prosemirror-view`, etc.) stay in the browser.

```elixir
alias ProsemirrorEx.Authority

# Start an authority with a schema and initial document
# Optionally bound step history (official demo uses MAX_STEP_HISTORY)
auth = Authority.new(schema, doc, max_history: 10_000)

# Receive steps from clients
{:ok, auth} = Authority.receive_steps(auth, "client-1", 0, steps)

# Reject stale versions
{:error, :version_mismatch} = Authority.receive_steps(auth, "client-2", 0, other_steps)

# Get steps for catch-up
{:ok, missed_steps, client_ids} = Authority.steps_since(auth, 0)

# If history was trimmed past the client's version:
# {:error, :history_unavailable} — reload via Authority.doc/1
```

`ProsemirrorEx.Authority.Server` wraps this in a GenServer with JSON boundaries and `subscribe/1` notifications (`{:authority_update, payload}`), the Elixir equivalent of the guide's `onNewSteps` callbacks.

## License

MIT
