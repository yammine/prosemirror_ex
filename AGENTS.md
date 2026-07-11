# ProsemirrorEx — Agent Context

Elixir port of the ProseMirror rich text editor framework (document model + transforms). Used for server-side document manipulation with full wire-format JSON compatibility with the JS ProseMirror ecosystem.

## Architecture

Two subsystems, mirroring the JS ProseMirror package split:

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

### ProsemirrorEx.Transform (prosemirror-transform port)

Document transformation via invertible, mappable steps. Each step produces a new document and a position mapping.

**Key modules:**

| Module | Purpose | When to look here |
|--------|---------|-------------------|
| `Transform.Transform` | Main orchestrator, accumulates steps | All document mutations, chaining operations |
| `Transform.Step` | Step behaviour + JSON registry | Defining new step types, step deserialization |
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

## File Layout

```
lib/prosemirror_ex/
├── model/                    # Document model (prosemirror-model port)
│   ├── schema.ex             # Schema construction + factories
│   ├── node.ex               # Node struct + operations
│   ├── fragment.ex           # Fragment (child collection)
│   ├── mark.ex               # Mark struct + set operations
│   ├── node_type.ex          # NodeType + create/validate
│   ├── mark_type.ex          # MarkType + create/exclude
│   ├── content_match.ex      # DFA content expression engine
│   ├── resolved_pos.ex       # Position resolution
│   ├── slice.ex              # Document slices
│   ├── replace.ex            # Replace algorithm
│   ├── diff.ex               # Fragment diffing
│   ├── node_range.ex         # Block range
│   ├── compare_deep.ex       # Deep equality util
│   ├── replace_error.ex      # ReplaceError exception
│   └── protocols.ex          # Inspect, String.Chars, Jason.Encoder
└── transform/                # Document transforms (prosemirror-transform port)
    ├── transform.ex          # Transform struct + all convenience methods
    ├── step.ex               # Step behaviour + registry (persistent_term)
    ├── step_result.ex        # StepResult struct
    ├── step_map.ex           # StepMap (position triples)
    ├── mapping.ex            # Mapping (chained maps + mirror)
    ├── mappable.ex           # Mappable protocol
    ├── map_result.ex         # MapResult struct
    ├── replace_step.ex       # ReplaceStep + ReplaceAroundStep
    ├── mark_step.ex          # AddMarkStep, RemoveMarkStep, AddNodeMarkStep, RemoveNodeMarkStep
    ├── attr_step.ex          # AttrStep, DocAttrStep
    ├── replace.ex            # Fitter algorithm + replaceRange/deleteRange
    ├── structure.ex          # lift, wrap, split, join, setBlockType, etc.
    ├── mark.ex               # addMark, removeMark, clearIncompatible
    └── transform_error.ex    # TransformError exception
```

## Key Concepts

### Position Model
ProseMirror uses a flat integer position scheme. Non-leaf nodes contribute an opening and closing token (each = 1 position). Text nodes are counted by character length. Position 0 is before the first child of the root.

### Content Expressions
Schema node specs use content expressions like `"paragraph+"`, `"inline*"`, `"heading block*"`. These compile to a DFA via `ContentMatch.parse/2`. The DFA validates whether a sequence of child node types is valid.

### Steps and Transforms
All document mutations happen through `Step` structs. Each step is invertible (for undo), mappable (for collaborative editing), and serializable (for persistence/networking). The `Transform` struct accumulates steps and maintains a `Mapping` for position tracking.

### Wire Format
JSON serialization is byte-for-byte compatible with the JS ProseMirror libraries. Documents serialize via `Node.to_json/1` / `Node.from_json/2`. Steps serialize via `step.to_json()` / `Step.from_json/2` with a `"stepType"` discriminator field.

## Testing

```bash
mix test                    # Run all 1112 tests
mix test test/prosemirror_ex/model/     # Model tests only (518)
mix test test/prosemirror_ex/transform/ # Transform tests only (594)
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

## Reference Material

`reference/prosemirror-transform/` contains the original TypeScript source from prosemirror-transform for cross-referencing.

Design specs and implementation plans are in `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Common Tasks

### Create a document and apply transforms
```elixir
alias ProsemirrorEx.Model.Schema
alias ProsemirrorEx.Transform.Transform

schema = Schema.new(%{"nodes" => [...], "marks" => [...]})
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
result = step.__struct__.apply(step, doc)
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
| `Authority` | Pure functional core: version, receive_steps, steps_since, optional `max_history` |
| `Authority.Server` | GenServer + JSON boundary + `subscribe` (`onNewSteps` equivalent) |

**Suite note:** An authority only needs `prosemirror-model` + `prosemirror-transform` (ported). Packages like `prosemirror-state`, `prosemirror-view`, `prosemirror-collab`, commands/keymap/history are client-side and intentionally not ported.

## Design Decisions

- **TextNode as Node with non-nil `:text`** — no separate struct, pattern match on `:text` field
- **ContentMatch uses ETS** — DFA states reference each other cyclically; ETS handles this naturally
- **Step registry via `:persistent_term`** — global, cross-process, registered on module load via `@on_load`
- **Transform extensibility** — functions pattern match on map keys (`%{doc: _, steps: _, ...}`) not `%Transform{}`, so `Transaction` can extend it
- **Mappable as protocol** — both StepMap and Mapping implement it; third-party types can too
- **Authority history trim** — `max_history` mirrors the official collab demo; trimmed versions return `:history_unavailable`
