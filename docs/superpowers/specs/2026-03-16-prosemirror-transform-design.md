# ProseMirror Transform - Elixir Port Design Spec

## Overview

A complete Elixir port of [prosemirror-transform](https://github.com/ProseMirror/prosemirror-transform) (v1.11.x), the document transformation layer of the ProseMirror framework. Builds on top of `ProsemirrorEx.Model` to provide invertible, mappable document transformation steps.

## Goals

- **Full parity** with prosemirror-transform's public API
- **Wire-format compatibility**: Step JSON must be identical to the JS library for collaborative editing interop
- **Exhaustive tests**: ported from the JS test suite
- **Extensible Transform**: designed so a future `Transaction` (from prosemirror-state) can extend it naturally
- **Idiomatic Elixir internals** with recognizable ProseMirror naming (same approach as prosemirror-model port)

## Dependencies

- `ProsemirrorEx.Model` (Node, Fragment, Slice, Mark, MarkType, NodeType, NodeRange, ResolvedPos, ContentMatch, Schema, ReplaceError)
- No additional external dependencies

## Module Structure

All modules under `ProsemirrorEx.Transform`:

```
lib/prosemirror_ex/transform/
├── map_result.ex          # MapResult struct
├── step_map.ex            # StepMap struct (position change triples)
├── mapping.ex             # Mapping struct (chains StepMaps with mirror support)
├── step.ex                # Step behaviour + StepResult struct + step registry
├── replace_step.ex        # ReplaceStep + ReplaceAroundStep
├── mark_step.ex           # AddMarkStep, RemoveMarkStep, AddNodeMarkStep, RemoveNodeMarkStep
├── attr_step.ex           # AttrStep, DocAttrStep
├── transform.ex           # Transform struct (main orchestrator)
├── transform_error.ex     # TransformError exception
├── replace.ex             # Fitter algorithm + replaceStep/replaceRange/deleteRange
├── structure.ex           # lift, wrap, split, join, setBlockType + utility functions
└── mark.ex                # addMark, removeMark, clearIncompatible helpers
```

## Data Structures

### MapResult

```elixir
defstruct [:pos, :deleted, :deleted_before, :deleted_after, :deleted_across, :recover]
# pos: non_neg_integer()
# deleted: boolean() — position was in a deleted range (considering assoc)
# deleted_before: boolean()
# deleted_after: boolean()
# deleted_across: boolean() — deletion spans across position
# recover: number | nil — recovery value for mirror mapping
```

### StepMap

```elixir
defstruct [:ranges, :inverted]
# ranges: [integer()] — flat list of [start, old_size, new_size, ...] triples
# inverted: boolean() — when true, old_size and new_size are swapped during mapping
```

Represents position changes from a single step as a compact array of triples. Each triple `[start, old_size, new_size]` says: at position `start`, `old_size` characters were replaced by `new_size` characters. The `_map()` method iterates these ranges to compute new positions, tracking cumulative offset.

### Mapping

```elixir
defstruct [:maps, :mirror, :from, :to]
# maps: [StepMap.t()] — ordered list of step maps
# mirror: [{integer(), integer()}] | nil — pairs of mirrored step indices
# from: integer() — start index for iteration
# to: integer() — end index for iteration
```

Chains multiple StepMaps into a pipeline. The mirror system enables position recovery in collaborative editing: when mapping through a step that deletes a position, if a mirror step exists later, the position is recovered instead of lost. Recovery values use float encoding to maintain 48-bit precision.

### StepResult

```elixir
defstruct [:doc, :failed]
# doc: Node.t() | nil
# failed: String.t() | nil
```

### Transform

```elixir
defstruct [:doc, :steps, :docs, :mapping]
# doc: Node.t() — current document after all steps
# steps: [Step.t()] — all steps applied
# docs: [Node.t()] — document snapshot before each step
# mapping: Mapping.t() — accumulated position mapping
```

**Extensibility:** Transform functions accept any struct/map with `doc`, `steps`, `docs`, `mapping` fields (pattern matching on those keys rather than `%Transform{}`). A future `Transaction` module can define its own struct with additional fields and reuse Transform functions directly.

## Step System

### Step Behaviour

```elixir
@callback apply(step :: t(), doc :: Node.t()) :: StepResult.t()
@callback invert(step :: t(), doc :: Node.t()) :: t()
@callback map(step :: t(), mapping :: Mappable.t()) :: t() | nil
@callback to_json(step :: t()) :: map()
@callback get_map(step :: t()) :: StepMap.t()
@callback merge(step :: t(), other :: t()) :: t() | nil
```

Default implementations: `get_map` returns `StepMap.empty()`, `merge` returns `nil`.

### Step Registry

Step modules register with a string JSON ID via `Step.json_id("replace", ReplaceStep)`. Uses a module attribute or persistent_term for the registry. `Step.from_json(schema, json)` dispatches to the registered module's `from_json/2`.

### Step Subclasses (8 total)

| Module | JSON ID | Constructor Args | Purpose |
|--------|---------|-----------------|---------|
| `ReplaceStep` | `"replace"` | `from, to, slice, structure \\ false` | Replace range with slice |
| `ReplaceAroundStep` | `"replaceAround"` | `from, to, gap_from, gap_to, slice, insert, structure \\ false` | Replace range preserving a gap |
| `AddMarkStep` | `"addMark"` | `from, to, mark` | Add mark to inline range |
| `RemoveMarkStep` | `"removeMark"` | `from, to, mark` | Remove mark from inline range |
| `AddNodeMarkStep` | `"addNodeMark"` | `pos, mark` | Add mark to node |
| `RemoveNodeMarkStep` | `"removeNodeMark"` | `pos, mark` | Remove mark from node |
| `AttrStep` | `"attr"` | `pos, attr, value` | Set node attribute |
| `DocAttrStep` | `"docAttr"` | `attr, value` | Set document attribute |

### Step Merging

`ReplaceStep.merge/2` combines adjacent replace steps when boundaries align and neither has `structure` set. `AddMarkStep.merge/2` and `RemoveMarkStep.merge/2` merge overlapping ranges with the same mark.

## API Surface

### StepMap

```elixir
StepMap.new(ranges \\ [])
StepMap.empty()
StepMap.offset(n)
StepMap.map(step_map, pos, assoc \\ 1)
StepMap.map_result(step_map, pos, assoc \\ 1)
StepMap.invert(step_map)
StepMap.for_each(step_map, f)    # iterate ranges as {old_start, old_end, new_start, new_end}
```

### Mapping

```elixir
Mapping.new(maps \\ [], mirror \\ nil, from \\ 0, to \\ nil)
Mapping.map(mapping, pos, assoc \\ 1)
Mapping.map_result(mapping, pos, assoc \\ 1)
Mapping.append_map(mapping, map, mirrors \\ nil)
Mapping.append_mapping(mapping, other)
Mapping.append_mapping_inverted(mapping, other)
Mapping.slice(mapping, from, to)
Mapping.invert(mapping)
```

### Step + StepResult

```elixir
Step.from_json(schema, json)
Step.json_id(id, module)

StepResult.ok(doc)
StepResult.fail(message)
StepResult.from_replace(doc, from, to, slice)
```

### Transform

```elixir
# Construction
Transform.new(doc)

# Core
Transform.step(tr, step)                    # apply step, raises TransformError on failure
Transform.maybe_step(tr, step)              # returns {updated_tr, step_result}
Transform.doc_changed?(tr)
Transform.before(tr)
Transform.changed_range(tr)

# Content replacement
Transform.replace(tr, from, to \\ from, slice \\ Slice.empty())
Transform.replace_with(tr, from, to, content)
Transform.delete(tr, from, to)
Transform.insert(tr, pos, content)
Transform.replace_range(tr, from, to, slice)
Transform.replace_range_with(tr, from, to, node)
Transform.delete_range(tr, from, to)

# Structure
Transform.lift(tr, range, target)
Transform.wrap(tr, range, wrappers)
Transform.set_block_type(tr, from, to \\ from, type, attrs \\ nil)
Transform.set_node_markup(tr, pos, type \\ nil, attrs \\ nil, marks \\ nil)
Transform.split(tr, pos, depth \\ 1, types_after \\ nil)
Transform.join(tr, pos, depth \\ 1)

# Attributes
Transform.set_node_attribute(tr, pos, attr, value)
Transform.set_doc_attribute(tr, attr, value)

# Marks
Transform.add_mark(tr, from, to, mark)
Transform.remove_mark(tr, from, to, mark \\ nil)
Transform.add_node_mark(tr, pos, mark)
Transform.remove_node_mark(tr, pos, mark)
Transform.clear_incompatible(tr, pos, parent_type, match \\ nil)
```

### Exported Utility Functions

```elixir
ProsemirrorEx.Transform.Structure.lift_target(range)
ProsemirrorEx.Transform.Structure.find_wrapping(range, node_type, attrs \\ nil, inner_range \\ nil)
ProsemirrorEx.Transform.Structure.can_join(doc, pos)
ProsemirrorEx.Transform.Structure.can_split(doc, pos, depth \\ 1, types_after \\ nil)
ProsemirrorEx.Transform.Structure.join_point(doc, pos, dir \\ -1)
ProsemirrorEx.Transform.Structure.insert_point(doc, pos, node_type)
ProsemirrorEx.Transform.Structure.drop_point(doc, pos, slice)
ProsemirrorEx.Transform.Replace.replace_step(doc, from, to \\ from, slice \\ Slice.empty())
```

## Wire Format

Steps serialize to JSON identically to the JS library:

```json
{"stepType":"replace","from":1,"to":5,"slice":{"content":[{"type":"text","text":"hello"}]}}
{"stepType":"addMark","from":1,"to":5,"mark":{"type":"em"}}
{"stepType":"removeMark","from":1,"to":5,"mark":{"type":"em"}}
{"stepType":"addNodeMark","pos":0,"mark":{"type":"em"}}
{"stepType":"removeNodeMark","pos":0,"mark":{"type":"em"}}
{"stepType":"attr","pos":0,"attr":"level","value":2}
{"stepType":"docAttr","attr":"title","value":"Hello"}
{"stepType":"replaceAround","from":1,"to":10,"gapFrom":2,"gapTo":9,"insert":1,"slice":{"content":[...]}}
```

The `stepType` field identifies the step class. Slice is serialized using the model's `Slice.to_json/1`. Marks use `Mark.to_json/1`.

## Error Handling

Same conventions as prosemirror-model:
- `Transform.step/2` raises `TransformError` on step failure (matching JS behavior of throwing)
- `Transform.maybe_step/2` returns `StepResult` without raising
- `StepResult.from_replace/4` catches `ReplaceError` and converts to `StepResult.fail`
- Step `map/2` returns `nil` when a step can't be mapped (position deleted)

## Implementation Order

1. **MapResult** — no dependencies
2. **StepMap** — depends on MapResult
3. **Mapping** — depends on StepMap, MapResult
4. **TransformError** — simple exception
5. **Step behaviour + StepResult + registry** — depends on Model
6. **ReplaceStep + ReplaceAroundStep** — depends on Step, StepMap, Model
7. **AddMarkStep + RemoveMarkStep** — depends on Step, StepMap, Model
8. **AddNodeMarkStep + RemoveNodeMarkStep** — depends on Step, StepMap, Model
9. **AttrStep + DocAttrStep** — depends on Step, StepMap, Model
10. **Transform struct + core methods** — depends on Step, Mapping
11. **mark.ex helpers** — depends on Transform, mark steps
12. **structure.ex** — depends on Transform, ReplaceStep, mark helpers
13. **replace.ex (Fitter)** — depends on Transform, ReplaceStep, ReplaceAroundStep, structure
14. **Wire Transform convenience methods** — connect all helpers to Transform
15. **Integration tests + JSON step round-trips**

## Testing Strategy

### Test structure

```
test/prosemirror_ex/transform/
├── step_map_test.exs
├── mapping_test.exs
├── replace_step_test.exs
├── mark_step_test.exs
├── attr_step_test.exs
├── step_test.exs          # fromJSON round-trips, merge
├── transform_test.exs     # full transform operations
├── structure_test.exs     # lift, wrap, split, join
└── integration_test.exs   # end-to-end workflows
```

### Test sources

1. **Ported JS tests** from the 6 test files in prosemirror-transform/test/
2. **Step JSON round-trips**: serialize a step, deserialize, apply both, compare results
3. **Mapping invariants**: position mapping is monotonic, invertible, composable
4. **Reuse existing test helpers**: test_schema, builders (doc, p, em, etc.) from prosemirror-model port
