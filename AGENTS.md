# ProsemirrorEx — Agent Context

Elixir port of the ProseMirror rich text editor framework (document model + transforms). Used for server-side document manipulation with full wire-format JSON compatibility with the JS ProseMirror ecosystem.

## Architecture

Two core subsystems, mirroring the JS ProseMirror package split, plus convenience schema builders and a collaborative editing authority:

### ProsemirrorEx.Model (prosemirror-model port)

The immutable document model. All types are structs. Documents are trees of `Node` structs containing `Fragment` children and `Mark` inline annotations. A `Schema` defines what node/mark types exist and validates content.

**Key modules:**

| Module | Purpose | When to look here |
|--------|---------|-------------------|
| `Model.Schema` | Schema construction, node/mark/text factory | Creating schemas, understanding content rules |
| `Model.Node` | Document node (block or inline) | Any document operation, traversal, slicing |
| `Model.Fragment` | Ordered child collection | Working with node children, cutting, appending |
| `Model.Mark` | Inline formatting (em, strong, link) | Mark set operations, add/remove/compare |
| `Model.NodeType` | Node type definition from schema | Content validation, node creation, attrs |
| `Model.MarkType` | Mark type definition from schema | Mark creation, exclusion rules |
| `Model.ContentMatch` | DFA-based content expression engine | Content validation, fill_before, find_wrapping |
| `Model.ResolvedPos` | Rich position context in a document | Position resolution, depth, parent, marks at pos |
| `Model.Slice` | Document fragment with open depths | Cut/paste operations, replacements |
| `Model.Replace` | Core replace algorithm | `Node.replace/4` internals |
| `Model.CompareDeep` | Deep equality for plain maps/lists | Attribute comparison |
| `Model.Diff` | Fragment diff detection | Finding where two fragments diverge |
| `Model.NodeRange` | Block range within a parent | Structural operations (lift, wrap) |
| `Model.Utf16` | UTF-16 code-unit length, slicing, byte offset conversion | Text offsets matching JS String semantics |
| `Model.RangeError` | Out-of-bounds position exception | Position resolution & fragment bounds errors |

### ProsemirrorEx.Transform (prosemirror-transform port)

Document transformation via invertible, mappable steps. Each step produces a new document and a position mapping.

**Key modules:**

| Module | Purpose | When to look here |
|--------|---------|-------------------|
| `Transform.Transform` | Main orchestrator, accumulates steps | All document mutations, chaining operations |
| `Transform.Step` | Step behaviour + JSON registry | Defining new step types, step deserialization |
| `Transform.StepRegistry` | Built-in step registry shim | Backwards-compatible `ensure_registered/0` no-op |
| `Transform.StepResult` | Step application result (ok/fail) | Handling step outcomes |
| `Transform.StepMap` | Position change triples from one step | Understanding how positions shift |
| `Transform.Mapping` | Chains StepMaps with mirror recovery | Collaborative editing, rebasing, undo |
| `Transform.Mappable` | Protocol for position mapping | Implementing custom mappers |
| `Transform.ReplaceStep` | Replace range with slice | Content replacement internals |
| `Transform.MarkStep` | Add/Remove marks (4 step types) | Mark operation internals |
| `Transform.AttrStep` | Set node/doc attributes | Attribute changes |
| `Transform.Replace` | Fitter algorithm, replaceRange, deleteRange | WYSIWYG-aware content fitting |
| `Transform.Structure` | lift, wrap, split, join, setBlockType | Structural document operations |
| `Transform.Mark` | addMark, removeMark, clearIncompatible | Mark transform helpers |

### ProsemirrorEx.Schema (convenience)

DX helpers for composing common ProseMirror schemas without hand-writing full spec maps.

| Module | Purpose | When to look here |
|--------|---------|-------------------|
| `Schema.Basic` | `nodes/0`, `marks/0`, `schema/0` for standard prose nodes | Quick schema setup without lists |
| `Schema.List` | `add_list_nodes/2-3` to append list specs to a node list | Adding bullet/ordered lists to Basic |

## File Layout

```
lib/
├── prosemirror_ex.ex             # Top-level library @moduledoc
└── prosemirror_ex/
    ├── authority.ex              # Pure functional collaborative authority
    ├── authority/
    │   └── server.ex             # GenServer + JSON boundary + subscriptions
    ├── model.ex                  # Model namespace @moduledoc
    ├── model/                    # Document model (prosemirror-model port)
    │   ├── compare_deep.ex       # Deep equality util
    │   ├── content_match.ex      # DFA content expression engine
    │   ├── diff.ex               # Fragment diffing
    │   ├── fragment.ex           # Fragment (child collection)
    │   ├── mark.ex               # Mark struct + set operations
    │   ├── mark_type.ex          # MarkType + create/exclude
    │   ├── node.ex               # Node struct + operations
    │   ├── node_range.ex         # Block range
    │   ├── node_type.ex          # NodeType + create/validate
    │   ├── protocols.ex          # Inspect, String.Chars, Jason.Encoder
    │   ├── range_error.ex        # RangeError exception
    │   ├── replace.ex            # Replace algorithm
    │   ├── replace_error.ex      # ReplaceError exception
    │   ├── resolved_pos.ex       # Position resolution
    │   ├── schema.ex             # Schema construction + factories
    │   ├── slice.ex              # Document slices
    │   └── utf16.ex              # UTF-16 code-unit helpers
    ├── schema.ex                 # Schema namespace @moduledoc
    ├── schema/                   # Convenience schema builders
    │   ├── basic.ex              # Basic prose node/mark specs + schema/0
    │   └── list.ex               # add_list_nodes/2-3
    └── transform/                # Document transforms (prosemirror-transform port)
        ├── attr_step.ex          # AttrStep, DocAttrStep
        ├── map_result.ex         # MapResult struct
        ├── mappable.ex           # Mappable protocol
        ├── mapping.ex            # Mapping (chained maps + mirror)
        ├── mark.ex               # addMark, removeMark, clearIncompatible
        ├── mark_step.ex          # AddMarkStep, RemoveMarkStep, AddNodeMarkStep, RemoveNodeMarkStep
        ├── replace.ex            # Fitter algorithm + replaceRange/deleteRange
        ├── replace_step.ex       # ReplaceStep + ReplaceAroundStep
        ├── step.ex               # Step behaviour, dispatch helpers & custom JSON registry
        ├── step_map.ex           # StepMap (position triples)
        ├── step_registry.ex      # Backwards-compatible no-op shim
        ├── step_result.ex        # StepResult struct
        ├── structure.ex          # lift, wrap, split, join, setBlockType, etc.
        ├── transform.ex          # Transform struct + all convenience methods
        └── transform_error.ex    # TransformError exception
```

## Key Concepts

### Position Model
ProseMirror uses a flat integer position scheme. Non-leaf nodes contribute an opening and closing token (each = 1 position). Text nodes are counted in UTF-16 code units (via `ProsemirrorEx.Model.Utf16`) to match JavaScript string indexing. Position 0 is before the first child of the root.

### Content Expressions
Schema node specs use content expressions like `"paragraph+"`, `"inline*"`, `"heading block*"`. These compile to a DFA via `ContentMatch.parse/2`. The DFA validates whether a sequence of child node types is valid.

### Steps and Transforms
All document mutations happen through `Step` structs. Each step is invertible (for undo), mappable (for collaborative editing), and serializable (for persistence/networking). The `Transform` struct accumulates steps and maintains a `Mapping` for position tracking.

### Wire Format
JSON serialization is byte-for-byte compatible with the JS ProseMirror libraries. Documents serialize via `Node.to_json/1` / `Node.from_json/2`. Steps serialize via `Step.to_json/1` / `Step.from_json/2` with a `"stepType"` discriminator field.

## Testing

```bash
mix test                                # Run all 1354 tests (24 properties, 1330 unit tests)
mix test test/prosemirror_ex/model/     # Model tests
mix test test/prosemirror_ex/transform/ # Transform tests
mix test test/prosemirror_ex/authority* # Authority & Authority.Server tests
mix test test/prosemirror_ex/schema/    # Schema convenience builder tests
```

### Test Helpers
`test/support/test_helpers.ex` provides:
- `test_schema/0` — standard schema matching JS prosemirror-test-builder
- Builders: `doc/1`, `p/1`, `blockquote/1`, `h1/1`, `h2/1`, `h3/1`, `pre/1`, `ul/1`, `ol/1`, `li/1`, `hr/0`, `br/0`, `img/0`
- Mark builders: `em/1`, `strong/1`, `code_mark/1`, `a/1`
- Tag system: `"<a>"` / `"<b>"` markers in strings track positions. Builders return `{node, tags}` tuples.
- `eq/2` — structural node equality

### JSON Fixtures
`test/fixtures/*.json` — real ProseMirror document JSON for round-trip testing.

## Design Specs & Plans

Design specs and implementation plans are in `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Common Tasks

### Create a document and apply transforms
```elixir
alias ProsemirrorEx.Schema.{Basic, List}
alias ProsemirrorEx.Model.Schema
alias ProsemirrorEx.Transform.Transform

schema = Schema.new(%{
  "nodes" => Basic.nodes() |> List.add_list_nodes("paragraph block*", "block"),
  "marks" => Basic.marks()
})
doc = Schema.node(schema, "doc", nil, [Schema.node(schema, "paragraph", nil, [Schema.text(schema, "hello")])])

tr = Transform.new(doc)
     |> Transform.insert(1, Schema.text(schema, "world"))
     |> Transform.add_mark(1, 6, Schema.mark(schema, "em"))

new_doc = tr.doc
```

### Deserialize a document from JSON
```elixir
json = Jason.decode!(json_string)
doc = ProsemirrorEx.Model.Node.from_json(schema, json)
```

### Apply steps from JSON (collaborative editing)
```elixir
step = ProsemirrorEx.Transform.Step.from_json(schema, step_json)
result = ProsemirrorEx.Transform.Step.apply(step, doc)
if result.doc, do: result.doc, else: raise result.failed
```

### Map positions through changes
```elixir
mapping = tr.mapping
new_pos = ProsemirrorEx.Transform.Mapping.map(mapping, old_pos)
```

## Authority (`ProsemirrorEx.Authority`)

Collaborative editing central authority (server-side counterpart to `prosemirror-collab` clients).

| Module | Purpose |
|--------|---------|
| `Authority` | Pure functional core: version, receive_steps, steps_since, first_version, optional `max_history` and initial `:version` |
| `Authority.Server` | GenServer + JSON boundary (JSON `:doc`/`:doc_json` init, pre-deserialization validation) + `subscribe` (`onNewSteps` equivalent) |

**Suite note:** An authority only needs `prosemirror-model` + `prosemirror-transform` (ported). Packages like `prosemirror-state`, `prosemirror-view`, `prosemirror-collab`, commands/keymap/history are client-side and intentionally not ported.

## Design Decisions

- **TextNode as Node with non-nil `:text`** — no separate struct, pattern match on `:text` field
- **ContentMatch uses pure immutable maps** — DFA states are stored in an immutable `:states` map by state ID (no ETS tables)
- **Step dispatch & custom registry** — `Step.from_json/2` pattern-matches all 8 built-in `stepType` strings directly; custom step types register via `Step.json_id/2` (serialized via `:global.trans` into `:persistent_term`)
- **Transform extensibility** — functions pattern match on map keys (`%{doc: _, steps: _, ...}`) not `%Transform{}`, so `Transaction` can extend it
- **Mappable as protocol** — both StepMap and Mapping implement it; third-party types can too
- **Authority history trim** — `max_history` mirrors the official collab demo; trimmed versions return `:history_unavailable`
