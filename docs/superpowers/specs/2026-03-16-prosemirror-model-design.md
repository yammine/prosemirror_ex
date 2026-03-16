# ProseMirror Model - Elixir Port Design Spec

## Overview

A complete Elixir port of [prosemirror-model](https://github.com/ProseMirror/prosemirror-model) (v1.25.x), the document model layer of the ProseMirror rich text editor framework. The port provides the core data structures and algorithms for representing, validating, and manipulating ProseMirror documents on the server side.

## Goals

- **Full parity** with prosemirror-model's core modules (excluding DOM parser/serializer)
- **Wire-format compatibility**: JSON serialized by the JS library must round-trip perfectly through the Elixir version and vice versa
- **Arbitrary schema support**: any valid ProseMirror schema must work
- **Exhaustive tests**: ported from the JS test suite, supplemented with property-based tests and JSON fixtures from the JS library
- **Idiomatic Elixir internals** with recognizable ProseMirror naming conventions (Approach C from brainstorming)

## Out of Scope (for now)

- `DOMParser` (from_dom.ts) - browser DOM parsing
- `DOMSerializer` (to_dom.ts) - browser DOM serialization
- These can be added later as HTML string equivalents using Floki

## Module Structure

All modules live under `ProsemirrorEx.Model`:

```
lib/prosemirror_ex/model/
├── compare_deep.ex       # Deep equality for attrs/plain objects
├── mark.ex               # Mark struct + mark set operations
├── fragment.ex            # Fragment struct + child collection operations
├── diff.ex               # findDiffStart/findDiffEnd between fragments
├── node.ex               # Node struct (TextNode is Node with non-nil :text)
├── content_match.ex      # ContentMatch DFA + expression compiler
├── schema.ex             # Schema struct + construction
├── node_type.ex          # NodeType struct + node creation/validation
├── mark_type.ex          # MarkType struct + mark creation/exclusion
├── resolved_pos.ex       # ResolvedPos struct + position resolution
├── node_range.ex         # NodeRange struct
├── slice.ex              # Slice struct + slicing operations
├── replace.ex            # Core replace algorithm
├── replace_error.ex      # ReplaceError exception
```

## Spec Types

These correspond to the TypeScript interfaces used to define schemas. In Elixir, they are plain maps with string keys.

### SchemaSpec

```elixir
%{
  "nodes" => [{name :: String.t(), NodeSpec.t()}],  # required, ordered
  "marks" => [{name :: String.t(), MarkSpec.t()}],  # optional, ordered
  "topNode" => String.t()                            # optional, default "doc"
}
```

### NodeSpec

```elixir
%{
  "content" => String.t(),            # content expression, e.g. "paragraph+"
  "marks" => String.t(),              # allowed marks, e.g. "em strong" or "_" for all, "" for none
  "group" => String.t(),              # space-separated group names, e.g. "block"
  "inline" => boolean(),              # true = inline node
  "atom" => boolean(),                # true = atom (no directly editable content)
  "attrs" => %{String.t() => AttributeSpec.t()},
  "selectable" => boolean(),          # default true
  "draggable" => boolean(),           # default false
  "code" => boolean(),                # code content (preserves whitespace)
  "whitespace" => "pre" | "normal",   # whitespace handling, default inferred from code
  "defining" => boolean(),            # wrapping node should be recreated on enter
  "definingAsContext" => boolean(),    # like defining, for context matching
  "definingForContent" => boolean(),  # like defining, for content preservation
  "isolating" => boolean(),           # prevents cursor from leaving
  "leafText" => fun,                  # custom text extraction for leaf nodes (fn node -> string)
  "linebreakReplacement" => boolean(),# this node replaces line breaks
  "toDebugString" => fun              # custom debug string (fn node -> string)
}
```

All fields optional. Unknown fields are ignored.

### MarkSpec

```elixir
%{
  "attrs" => %{String.t() => AttributeSpec.t()},
  "inclusive" => boolean(),            # default true; marks extend to cover adjacent content
  "excludes" => String.t(),           # space-separated mark names this excludes, "_" for all
  "group" => String.t(),              # space-separated group names
  "spanning" => boolean(),            # default true; mark wraps across nodes
  "code" => boolean()                 # code mark
}
```

### AttributeSpec

```elixir
%{
  "default" => any(),                 # default value; key ABSENT means attr is required
  "validate" => String.t()            # pipe-separated type names, e.g. "string|number"
}
# Important: distinguish missing "default" key (required attr) from "default" => nil
# (attr has nil/null as default). Use Map.has_key?(spec, "default") to check.
```

Validation: the `validate` field supports type strings like `"string"`, `"number"`, `"boolean"`, `"string|number"`. In Elixir, we also accept `{module, function, extra_args}` MFA tuples for custom validators. String-based validation checks Elixir equivalents (e.g., `"string"` checks `is_binary/1`).

## Error Handling Strategy

Functions follow Elixir conventions:

- **Raising functions** for programmer errors and invalid operations that indicate bugs (e.g., `Node.child/2` with out-of-bounds index, `ResolvedPos.resolve/2` with invalid position, `Node.check/1` with invalid content). These match the JS behavior of throwing RangeError/TypeError.
- **`ReplaceError`** is a dedicated exception (matching JS `ReplaceError`), raised by `Replace.replace/4` and `Node.replace/4` on invalid replacements.
- **`{:ok, result} | {:error, reason}`** tuples only where the caller is expected to handle failure as a normal case (e.g., `ContentMatch.match_type/2` returns `nil` on no match, not an error — matching the JS return of `null`).

In general: if the JS code throws, we raise. If the JS code returns null/undefined for "no match", we return `nil`.

## Data Structures

### Node

```elixir
defstruct [:type, :attrs, :content, :marks, :text]
# type: %NodeType{}
# attrs: %{String.t() => any()}
# content: %Fragment{}
# marks: [%Mark{}]
# text: String.t() | nil  (non-nil for text nodes only)
```

TextNode is not a separate struct. A text node is a `%Node{}` with `text != nil`. Functions pattern match on the `:text` field for text-specific behavior (e.g., `cut/3`, `eq/2`, `node_size/1`).

### Fragment

```elixir
defstruct [:content, :size]
# content: [%Node{}]
# size: non_neg_integer()
```

`Fragment.empty()` returns a singleton `%Fragment{content: [], size: 0}`.

### Mark

```elixir
defstruct [:type, :attrs]
# type: %MarkType{}
# attrs: %{String.t() => any()}
```

Mark sets are sorted lists of `%Mark{}`, ordered by `MarkType.rank`. `Mark.none()` is `[]`.

### Schema

```elixir
defstruct [:spec, :nodes, :marks, :top_node_type, :linebreak_replacement, :cached]
# spec: %{nodes: [{name, node_spec}], marks: [{name, mark_spec}], top_node: String.t()}
# nodes: %{String.t() => %NodeType{}}
# marks: %{String.t() => %MarkType{}}
# top_node_type: %NodeType{}
# linebreak_replacement: %NodeType{} | nil
# cached: %{}
```

Schema spec uses `[{name, spec}]` tuples (keyword-list-like) to preserve insertion order, replacing the JS `OrderedMap` dependency.

### NodeType

```elixir
defstruct [
  :name, :schema, :spec, :groups, :content_match,
  :mark_set, :inline_content, :is_block, :is_text,
  :default_attrs, :attrs
]
```

### MarkType

```elixir
defstruct [:name, :rank, :schema, :spec, :excluded, :instance, :attrs]
```

### ContentMatch

```elixir
defstruct [:valid_end, :next, :wrap_cache]
# valid_end: boolean()
# next: [{%NodeType{}, %ContentMatch{}}]
# wrap_cache: [term()]
```

The expression compiler (`ContentMatch.parse/2`) implements the full grammar:
- Operators: `+`, `*`, `?`, `{min,max}`
- Choice: `|`
- Grouping: `()`
- Group references: names that match `NodeSpec.group`
- Pipeline: tokenize → parse to AST → build NFA → convert to DFA

`next` is a list of `{%NodeType{}, %ContentMatch{}}` edge tuples, analogous to the JS `MatchEdge` objects. `wrap_cache` is a flat list used as an alternating key-value cache: `[target_type, wrapping_types | nil, ...]`.

### ResolvedPos

```elixir
defstruct [:pos, :path, :parent_offset, :depth]
# pos: non_neg_integer()
# path: [term()]  (flat list: [node, index, offset, ...] repeating)
# parent_offset: non_neg_integer()
# depth: non_neg_integer()
```

### NodeRange

```elixir
defstruct [:from, :to, :depth]
# from: %ResolvedPos{}
# to: %ResolvedPos{}
# depth: non_neg_integer()
```

### Slice

```elixir
defstruct [:content, :open_start, :open_end]
# content: %Fragment{}
# open_start: non_neg_integer()
# open_end: non_neg_integer()
```

## API Surface

### Node

```elixir
# Construction
Node.new(type, attrs, content, marks)

# Properties
Node.node_size(node)
Node.child_count(node)
Node.children(node)              # returns fragment's content list
Node.is_block(node), is_textblock/1, is_inline/1, is_text/1, is_leaf/1, is_atom_node/1
Node.inline_content(node)
Node.text_content(node)

# Child access
Node.child(node, index)
Node.maybe_child(node, index)
Node.first_child(node), last_child/1

# Traversal
Node.for_each(node, fun)
Node.nodes_between(node, from, to, fun, start_pos \\ 0)
Node.descendants(node, fun)
Node.text_between(node, from, to, block_separator \\ "", leaf_text \\ nil)

# Comparison
Node.eq(a, b)
Node.same_markup(a, b)
Node.has_markup(node, type, attrs \\ nil, marks \\ nil)

# Transformation
Node.copy(node, content)
Node.mark(node, marks)
Node.cut(node, from, to \\ nil)
Node.slice(node, from, to \\ nil, include_parents \\ false)
Node.replace(node, from, to, slice)

# Position
Node.resolve(node, pos)
Node.node_at(node, pos)
Node.child_after(node, pos)
Node.child_before(node, pos)

# Validation
Node.range_has_mark(node, from, to, type)
Node.can_replace(node, from, to, replacement, start, end_val)
Node.can_replace_with(node, from, to, type, marks)
Node.can_append(node, other)
Node.content_match_at(node, index)
Node.check(node)

# Serialization
Node.to_json(node)
Node.from_json(schema, json)
```

### Fragment

```elixir
Fragment.from(value)
Fragment.from_array(array)
Fragment.empty()
Fragment.size(frag)
Fragment.child_count(frag)
Fragment.child(frag, index), maybe_child/2, first_child/1, last_child/1
Fragment.for_each(frag, fun)
Fragment.nodes_between(frag, from, to, fun, node_start, parent)
Fragment.descendants(frag, fun)
Fragment.text_between(frag, from, to, block_sep, leaf_text)
Fragment.append(frag, other)
Fragment.cut(frag, from, to)
Fragment.cut_by_index(frag, from, to)
Fragment.replace_child(frag, index, node)
Fragment.add_to_start(frag, node), add_to_end/2
Fragment.eq(a, b)
Fragment.find_diff_start(a, b), find_diff_end/2  # delegates to Diff module
Fragment.find_index(frag, pos)
Fragment.to_json(frag)
Fragment.from_json(schema, value)
```

### Mark

```elixir
Mark.new(type, attrs)
Mark.add_to_set(mark, set)
Mark.remove_from_set(mark, set)
Mark.is_in_set(mark, set)         # returns matching %Mark{} or nil (not boolean)
Mark.eq(a, b)
Mark.same_set(set_a, set_b)
Mark.set_from(marks)
Mark.none()
Mark.to_json(mark), from_json/2
```

### Schema / NodeType / MarkType

```elixir
Schema.new(spec)
Schema.node(schema, type, attrs, content, marks)
Schema.text(schema, text, marks)
Schema.mark(schema, type, attrs)
Schema.node_type(schema, name)
Schema.node_from_json(schema, json), mark_from_json/2

NodeType.create(type, attrs, content, marks)
NodeType.create_checked(type, attrs, content, marks)
NodeType.create_and_fill(type, attrs, content, marks)
NodeType.valid_content(type, content)
NodeType.check_content(type, content)  # raises on invalid (counterpart to valid_content which returns boolean)
NodeType.allows_mark_type(type, mark_type)
NodeType.allows_marks(type, marks), allowed_marks/2
NodeType.compatible_content(type, other)
NodeType.has_required_attrs(type)
NodeType.is_in_group(type, group)
NodeType.whitespace(type)
# Derived boolean properties: is_block, is_inline, is_textblock, is_leaf, is_atom_node, is_text

MarkType.create(type, attrs)
MarkType.remove_from_set(type, set)
MarkType.is_in_set(type, set)
MarkType.excludes(type, other)
```

### ContentMatch

```elixir
ContentMatch.parse(expr_string, node_types)
ContentMatch.match_type(match, type)
ContentMatch.match_fragment(match, fragment, start, end_val)
ContentMatch.fill_before(match, after_frag, to_end, start_index)
ContentMatch.find_wrapping(match, target)
ContentMatch.default_type(match)
ContentMatch.inline_content(match)
ContentMatch.edge_count(match), edge/2
ContentMatch.empty()
```

### ResolvedPos / NodeRange / Slice / Replace

```elixir
ResolvedPos.resolve(doc, pos)
ResolvedPos.resolve_cached(doc, pos)
ResolvedPos.doc(rpos)
ResolvedPos.parent(rpos)
ResolvedPos.text_offset(rpos)
ResolvedPos.node_after(rpos)
ResolvedPos.node_before(rpos)
ResolvedPos.node(rpos, depth)
ResolvedPos.resolve_depth(rpos, depth)   # normalizes nil/negative depth
ResolvedPos.index(rpos, depth), index_after/2
ResolvedPos.start(rpos, depth), end_pos/2
ResolvedPos.before(rpos, depth), after_pos/2
ResolvedPos.marks(rpos), marks_across/2
ResolvedPos.shared_depth(rpos, pos)
ResolvedPos.block_range(rpos, other, pred)
ResolvedPos.content_match_at(rpos, depth)
ResolvedPos.same_parent(rpos, other)
ResolvedPos.pos_at_index(rpos, index, depth)
ResolvedPos.max(rpos, other), min/2

NodeRange.new(from, to, depth)
NodeRange.start(range), end_pos/1
NodeRange.parent(range)
NodeRange.start_index(range), end_index/1

Slice.new(content, open_start, open_end)
Slice.max_open(fragment, open_isolating \\ true)
Slice.empty()
Slice.size(slice)
Slice.eq(a, b)
Slice.cut(slice, from, to)
Slice.insert_at(slice, pos, fragment)   # returns %Slice{} | nil
Slice.remove_between(slice, from, to)
Slice.to_json(slice), from_json/2

Replace.replace(from_rpos, to_rpos, slice)  # takes ResolvedPos, not integers
```

## Protocols

Implement the following Elixir protocols for debugging and serialization:

- **`Inspect`** for Node, Fragment, Mark, Slice, ResolvedPos — maps to JS `toString()` methods. Provides readable debug output.
- **`String.Chars`** for Node — `to_string(node)` returns the debug representation.
- **`Jason.Encoder`** for Node, Fragment, Mark, Slice — enables `Jason.encode!(node)` to produce wire-compatible JSON.

## Performance Considerations

- **Fragment.content**: stored as an Elixir list. Index access via `Enum.at/2` is O(n). For the initial implementation this is acceptable — ProseMirror documents are typically shallow (few hundred direct children max). If profiling shows this is a bottleneck, we can switch to a tuple-backed or array-backed structure later without changing the public API.
- **ResolvedPos cache**: the JS library uses a 12-entry WeakMap cache on each node. In Elixir, `resolve_cached/2` will use a process dictionary cache or accept recomputation, since WeakMaps don't exist. For server-side use, recomputation is likely acceptable.
- **Schema.cached**: the JS version mutates this object in place. In Elixir, all cacheable values (DOMParser, DOMSerializer, etc.) will be computed eagerly during `Schema.new/1` where possible. The `cached` field remains a map for extension, but we avoid needing mutation.

## Implementation Order

Build bottom-up in dependency order. Each module is fully tested before the next begins.

1. **Project setup** — `mix new`, dependencies, test config
2. **compare_deep** — no dependencies
3. **Mark struct + basic operations** — depends on compare_deep. MarkType is a forward ref (just needs the struct shape).
4. **Fragment struct + basic operations** — struct definition, `from_array`, `cut`, `append`, `eq`, `size`. Uses minimal stub nodes for testing.
5. **Diff** — `find_diff_start`, `find_diff_end`. Depends on Fragment + Node structs.
6. **Node struct + full API** — depends on Fragment, Mark, compare_deep. Wire up Fragment cross-references. Test with manually constructed nodes (no schema yet).
7. **Fragment full API** — complete remaining functions that depend on Node (e.g., `nodes_between`, `text_between`, `from_json`).
8. **ContentMatch** — expression compiler (tokenize → AST → NFA → DFA). Needs NodeType struct definition but not the full Schema. Create minimal NodeType structs for testing.
9. **NodeType + MarkType + Schema** — full construction pipeline. Depends on Node, Fragment, Mark, ContentMatch. This is where content expressions get compiled, mark sets computed, default attrs resolved, attribute validation wired up.
10. **Mark full wiring** — complete `from_json` and any Schema-dependent operations.
11. **ResolvedPos + NodeRange** — depends on Node, Mark, Schema (for full testing).
12. **Slice + Replace + ReplaceError** — depends on Fragment, Node, ResolvedPos, Schema.
13. **JSON round-trip integration tests** — all modules, fixture-driven, 100% compatibility.
14. **Protocols** — Inspect, String.Chars, Jason.Encoder.

## Testing Strategy

### Test structure

```
test/prosemirror_ex/model/
├── test_helper.exs           # shared test schema + node builder helpers
├── compare_deep_test.exs
├── mark_test.exs
├── fragment_test.exs
├── diff_test.exs
├── node_test.exs
├── content_match_test.exs
├── schema_test.exs
├── node_type_test.exs
├── resolved_pos_test.exs
├── slice_test.exs
├── replace_test.exs
└── json_round_trip_test.exs
```

### Test sources

1. **Ported JS tests**: translate each test from the prosemirror-model test suite, preserving test names for traceability
2. **JSON fixtures**: real JSON output captured from the JS library for round-trip verification
3. **Property-based tests** (StreamData): invariants like:
   - `Node.from_json(schema, Node.to_json(node)) == node`
   - `Fragment.size` always equals sum of child `node_size` values
   - Mark set operations maintain sort order
   - `ContentMatch.match_fragment` is consistent with `valid_content`
4. **Error case tests**: verify that all error paths raise the correct exception type with meaningful messages:
   - Schema construction errors (invalid content expressions, unknown node types, circular group refs)
   - `ReplaceError` from invalid replacements
   - `RangeError` equivalents from `Node.check/1`, `Node.child/2` out of bounds, `ResolvedPos.resolve/2` invalid positions
   - Missing required attributes
   - Invalid attribute values (when `validate` is specified)
5. **Operation fixture tests**: for complex algorithms (`Replace.replace`, `ContentMatch.fill_before`, `ContentMatch.find_wrapping`), generate input/output pairs from the JS library to verify behavioral parity beyond JSON serialization

### Test helpers

A shared test schema matching the JS test suite's schema, plus builder functions:

```elixir
# Quick node construction for tests
doc(content)
p(content)
blockquote(content)
h1(content), h2(content)
em(content)        # mark helper
strong(content)    # mark helper
```

### Fixture-driven testing

JSON fixtures from the JS library are stored in `test/fixtures/` and used for round-trip tests. Tests run against these fixtures until 100% compatibility is achieved.

### Integration tests

Beyond JSON round-trips, integration tests cover end-to-end workflows:
- Create schema → build document → slice → replace → resolve positions in result
- Schema with complex content expressions → create_and_fill → validate
- Mark exclusion and ordering across schema operations

## Wire Format

The JSON format matches prosemirror-model exactly:

```json
// Node
{"type": "paragraph", "content": [...]}
{"type": "heading", "attrs": {"level": 1}, "content": [...]}
{"type": "text", "text": "hello"}
{"type": "text", "marks": [{"type": "strong"}], "text": "bold"}

// Fragment (serialized as array of node JSON)
[{"type": "paragraph", "content": [...]}, ...]

// Mark
{"type": "em"}
{"type": "link", "attrs": {"href": "https://example.com", "title": null}}

// Slice
{"content": [...], "openStart": 1, "openEnd": 1}
```

Field names, null handling, and key presence/absence must match the JS output exactly.

## Dependencies

- **Elixir ~> 1.15** (for Map improvements and pattern matching features)
- **Jason** - JSON encoding/decoding (for wire format compatibility)
- **StreamData** (dev/test only) - property-based testing
- No other runtime dependencies
