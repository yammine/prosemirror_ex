# ProseMirror Transform Elixir Port - Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port prosemirror-transform (JS) to Elixir, providing invertible/mappable document transformation steps with full wire-format compatibility.

**Architecture:** Builds on ProsemirrorEx.Model. Step behaviour with 8 concrete implementations. Mappable protocol for position mapping. Transform struct accumulates steps. All under ProsemirrorEx.Transform.

**Tech Stack:** Elixir, ProsemirrorEx.Model (already implemented), persistent_term (step registry)

**Spec:** `docs/superpowers/specs/2026-03-16-prosemirror-transform-design.md`

**JS Reference:** All upstream source files are at `reference/prosemirror-transform/src/` and tests at `reference/prosemirror-transform/test/`. Agents MUST read these files and port line-by-line for complex modules.

**Critical Notes:**
- All tasks follow TDD: write tests FIRST, verify fail, implement, verify pass.
- Reuse existing test helpers from `test/support/test_helpers.ex` (test_schema, builders: doc, p, em, strong, etc.)
- The Mappable protocol must be defined before StepMap and Mapping.
- Step registry uses `:persistent_term`.
- Transform functions accept any struct with `doc`, `steps`, `docs`, `mapping` fields for extensibility.

---

## Chunk 1: Position Mapping System

### Task 1: MapResult + Mappable Protocol

**Files:**
- Create: `lib/prosemirror_ex/transform/map_result.ex`
- Create: `lib/prosemirror_ex/transform/mappable.ex`
- Test: `test/prosemirror_ex/transform/map_result_test.exs`

- [ ] **Step 1: Create MapResult struct**

Read `reference/prosemirror-transform/src/map.ts` lines 1-50 for MapResult.

```elixir
# lib/prosemirror_ex/transform/map_result.ex
defmodule ProsemirrorEx.Transform.MapResult do
  @moduledoc "Result of mapping a position through a set of changes."

  defstruct [:pos, :del_info, :recover]

  @del_before 1
  @del_after 2
  @del_both 3

  def new(pos, del_info \\ 0, recover \\ nil) do
    %__MODULE__{pos: pos, del_info: del_info, recover: recover}
  end

  def deleted?(%__MODULE__{del_info: del_info}, assoc) do
    if assoc < 0 do
      Bitwise.band(del_info, @del_before) > 0
    else
      Bitwise.band(del_info, @del_after) > 0
    end
  end

  def deleted_before?(%__MODULE__{del_info: d}), do: Bitwise.band(d, @del_before) > 0
  def deleted_after?(%__MODULE__{del_info: d}), do: Bitwise.band(d, @del_after) > 0
  def deleted_across?(%__MODULE__{del_info: d}), do: d == @del_both
end
```

- [ ] **Step 2: Create Mappable protocol**

```elixir
# lib/prosemirror_ex/transform/mappable.ex
defprotocol ProsemirrorEx.Transform.Mappable do
  @doc "Map a position through this mapping."
  def map(mappable, pos, assoc)

  @doc "Map a position, returning a MapResult with deletion info."
  def map_result(mappable, pos, assoc)
end
```

- [ ] **Step 3: Write tests and verify**

```bash
mix test test/prosemirror_ex/transform/map_result_test.exs
```

- [ ] **Step 4: Commit**

```bash
git add lib/prosemirror_ex/transform/ test/prosemirror_ex/transform/
git commit -m "Add MapResult struct and Mappable protocol"
```

---

### Task 2: StepMap

**Files:**
- Create: `lib/prosemirror_ex/transform/step_map.ex`
- Test: `test/prosemirror_ex/transform/step_map_test.exs`

Read `reference/prosemirror-transform/src/map.ts` lines 52-160 for StepMap.

Port the `_map` method faithfully — this is the core position mapping algorithm. Key: iterate ranges as triples, track cumulative `diff`, handle `assoc` for insertions at same position, compute `del_info` bitmask, generate `recover` values.

Recovery value encoding:
```elixir
defp make_recover(index, offset), do: index + offset * 0x10000
defp recover_index(value), do: Bitwise.band(value, 0xFFFF)
defp recover_offset(value), do: div(value - Bitwise.band(value, 0xFFFF), 0x10000)
```

Implement: `new/1`, `empty/0`, `offset/1`, `map/3`, `map_result/3`, `invert/1`, `for_each/2`, `to_string/1`.

Also implement `Mappable` protocol for StepMap.

Tests: port from `reference/prosemirror-transform/test/test-mapping.ts` — the `testMapping` helper tests.

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement StepMap**
- [ ] **Step 3: Implement Mappable for StepMap**
- [ ] **Step 4: Run tests, fix until pass**
- [ ] **Step 5: Commit**

---

### Task 3: Mapping

**Files:**
- Create: `lib/prosemirror_ex/transform/mapping.ex`
- Test: `test/prosemirror_ex/transform/mapping_test.exs`

Read `reference/prosemirror-transform/src/map.ts` lines 162-end for Mapping.

Key: the mirror system for position recovery. `maps` is a list, `mirror` is a flat list of integer pairs. `_map` iterates maps from→to (or to→from when inverted), using `getMirror` to find recovery partners.

Implement: `new/4`, `map/3`, `map_result/3`, `append_map/3`, `append_mapping/2`, `append_mapping_inverted/2`, `get_mirror/2`, `set_mirror/3`, `slice/3`, `invert/1`.

Also implement `Mappable` protocol for Mapping.

Tests: port remaining tests from `test-mapping.ts` — especially the mirror/recovery tests.

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement Mapping**
- [ ] **Step 3: Implement Mappable for Mapping**
- [ ] **Step 4: Run all tests (including StepMap)**
- [ ] **Step 5: Commit**

---

## Chunk 2: Step System

### Task 4: TransformError + Step Behaviour + StepResult

**Files:**
- Create: `lib/prosemirror_ex/transform/transform_error.ex`
- Create: `lib/prosemirror_ex/transform/step.ex`
- Test: `test/prosemirror_ex/transform/step_test.exs`

- [ ] **Step 1: Create TransformError**

```elixir
defmodule ProsemirrorEx.Transform.TransformError do
  defexception [:message]
end
```

- [ ] **Step 2: Create Step behaviour + StepResult + registry**

Read `reference/prosemirror-transform/src/step.ts`.

```elixir
defmodule ProsemirrorEx.Transform.Step do
  @callback apply(step :: struct(), doc :: Node.t()) :: StepResult.t()
  @callback invert(step :: struct(), doc :: Node.t()) :: struct()
  @callback step_map(step :: struct()) :: StepMap.t()
  @callback to_json(step :: struct()) :: map()
  @callback merge(step :: struct(), other :: struct()) :: struct() | nil
  # map/2 is handled via each module's own map function

  @optional_callbacks [merge: 2]

  def json_id(id, module) do
    registry = :persistent_term.get(:prosemirror_step_registry, %{})
    :persistent_term.put(:prosemirror_step_registry, Map.put(registry, id, module))
  end

  def from_json(schema, json) do
    step_type = json["stepType"]
    registry = :persistent_term.get(:prosemirror_step_registry, %{})
    module = Map.get(registry, step_type) || raise "No step type #{step_type} registered"
    module.from_json(schema, json)
  end
end

defmodule ProsemirrorEx.Transform.StepResult do
  defstruct [:doc, :failed]

  def ok(doc), do: %__MODULE__{doc: doc, failed: nil}
  def fail(message), do: %__MODULE__{doc: nil, failed: message}

  def from_replace(doc, from, to, slice) do
    try do
      ok(ProsemirrorEx.Model.Node.replace(doc, from, to, slice))
    rescue
      e in ProsemirrorEx.Model.ReplaceError -> fail(e.message)
    end
  end
end
```

- [ ] **Step 3: Write basic tests**
- [ ] **Step 4: Commit**

---

### Task 5: ReplaceStep + ReplaceAroundStep

**Files:**
- Create: `lib/prosemirror_ex/transform/replace_step.ex`
- Test: `test/prosemirror_ex/transform/replace_step_test.exs`

Read `reference/prosemirror-transform/src/replace_step.ts` and port both classes.

**ReplaceStep**: `apply` calls `doc.replace(from, to, slice)`. `invert` creates the inverse by slicing the original. `map` remaps from/to through the mapping. `getMap` returns `StepMap.new([from, to - from, slice.size])`. `merge` can combine adjacent replaces. `toJSON`/`fromJSON` serialize with `stepType: "replace"`.

**ReplaceAroundStep**: More complex — replaces content around a gap. `apply` uses `doc.replace` with a constructed slice that includes the gap content.

Tests: port from `reference/prosemirror-transform/test/test-replace_step.ts` + step JSON round-trip tests from `test-step.ts`.

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement ReplaceStep**
- [ ] **Step 3: Implement ReplaceAroundStep**
- [ ] **Step 4: Register both with Step.json_id**
- [ ] **Step 5: Run tests, fix until pass**
- [ ] **Step 6: Commit**

---

### Task 6: Mark Steps (AddMarkStep, RemoveMarkStep, AddNodeMarkStep, RemoveNodeMarkStep)

**Files:**
- Create: `lib/prosemirror_ex/transform/mark_step.ex`
- Test: `test/prosemirror_ex/transform/mark_step_test.exs`

Read `reference/prosemirror-transform/src/mark_step.ts` and port all 4 classes.

**AddMarkStep**: walks inline nodes in range, adds mark where missing, reconstructs the slice.
**RemoveMarkStep**: walks inline nodes, removes mark where present.
**AddNodeMarkStep**: adds a mark to a specific node at pos.
**RemoveNodeMarkStep**: removes a mark from a specific node at pos.

All implement `apply`, `invert`, `map`, `getMap`, `toJSON`, `fromJSON`. AddMarkStep and RemoveMarkStep implement `merge`.

- [ ] **Step 1: Write tests (port mark step tests from test-step.ts)**
- [ ] **Step 2: Implement all 4 step types**
- [ ] **Step 3: Register with Step.json_id**
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Commit**

---

### Task 7: AttrStep + DocAttrStep

**Files:**
- Create: `lib/prosemirror_ex/transform/attr_step.ex`
- Test: `test/prosemirror_ex/transform/attr_step_test.exs`

Read `reference/prosemirror-transform/src/attr_step.ts`.

**AttrStep**: sets a single attribute on the node at `pos`. `getMap` returns `StepMap.empty` (no position changes).
**DocAttrStep**: sets a single attribute on the document node itself.

Simple implementations — `apply` modifies the node attrs, `invert` restores the old value.

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement AttrStep and DocAttrStep**
- [ ] **Step 3: Register with Step.json_id**
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Commit**

---

## Chunk 3: Transform + Helpers

### Task 8: Transform Struct + Core Methods

**Files:**
- Create: `lib/prosemirror_ex/transform/transform.ex`
- Test: `test/prosemirror_ex/transform/transform_test.exs`

Read `reference/prosemirror-transform/src/transform.ts` lines 1-80.

The Transform struct holds `doc`, `steps`, `docs`, `mapping`. Core methods:

```elixir
defmodule ProsemirrorEx.Transform.Transform do
  defstruct [:doc, steps: [], docs: [], mapping: %Mapping{}]

  def new(doc), do: %__MODULE__{doc: doc, mapping: Mapping.new()}

  def step(tr, step_struct) do
    result = apply_step(tr, step_struct)
    if result.failed, do: raise TransformError, message: result.failed
    add_step(tr, step_struct, result.doc)
  end

  def maybe_step(tr, step_struct) do
    result = apply_step(tr, step_struct)
    if result.failed do
      {tr, result}
    else
      {add_step(tr, step_struct, result.doc), result}
    end
  end

  defp apply_step(tr, step_struct) do
    step_module = step_struct.__struct__
    step_module.apply(step_struct, tr.doc)
  end

  defp add_step(tr, step_struct, doc) do
    step_module = step_struct.__struct__
    %{tr |
      doc: doc,
      steps: tr.steps ++ [step_struct],
      docs: tr.docs ++ [tr.doc],
      mapping: Mapping.append_map(tr.mapping, step_module.step_map(step_struct))
    }
  end

  def before(tr), do: List.first(tr.docs) || tr.doc
  def doc_changed?(tr), do: length(tr.steps) > 0
end
```

**IMPORTANT**: Functions pattern-match on map keys, not `%Transform{}`, for extensibility.

Tests: basic step application, doc_changed?, before, maybe_step with failing step.

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement Transform**
- [ ] **Step 3: Run all tests**
- [ ] **Step 4: Commit**

---

### Task 9: Mark Helpers (addMark, removeMark, clearIncompatible)

**Files:**
- Create: `lib/prosemirror_ex/transform/mark.ex`
- Test: `test/prosemirror_ex/transform/mark_test.exs`

Read `reference/prosemirror-transform/src/mark.ts`.

These are functions that create and apply mark steps to a Transform:

- `add_mark(tr, from, to, mark)` — walks inline content, creates AddMarkStep for ranges that don't have the mark
- `remove_mark(tr, from, to, mark_or_mark_type_or_nil)` — removes matching marks, creates RemoveMarkStep
- `clear_incompatible(tr, pos, parent_type, match \\ nil, clear_newlines \\ true)` — removes invalid children/marks

Wire these as Transform functions:
```elixir
def add_mark(tr, from, to, mark), do: ProsemirrorEx.Transform.Mark.add_mark(tr, from, to, mark)
```

Tests: port mark-related tests from `test-trans.ts`.

- [ ] **Step 1: Write tests (port addMark/removeMark tests from test-trans.ts)**
- [ ] **Step 2: Implement mark helpers**
- [ ] **Step 3: Wire to Transform module**
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Commit**

---

### Task 10: Replace Helpers (Fitter, replaceStep, replaceRange, deleteRange)

**Files:**
- Create: `lib/prosemirror_ex/transform/replace.ex`
- Modify: `lib/prosemirror_ex/transform/transform.ex`
- Test: `test/prosemirror_ex/transform/replace_test.exs`

Read `reference/prosemirror-transform/src/replace.ts` — this is the largest and most complex file (~500 lines).

**MUST port line-by-line from the JS source.** Key components:

1. `replace_step(doc, from, to, slice)` — creates a ReplaceStep using the Fitter
2. The `Fitter` struct/module with frontier, unplaced, placed tracking
3. `replace_range(tr, from, to, slice)` — WYSIWYG-aware replace
4. `replace_range_with(tr, from, to, node)` — WYSIWYG-aware node replace
5. `delete_range(tr, from, to)` — smart delete

Wire as Transform convenience methods: `replace`, `replace_with`, `delete`, `insert`, `replace_range`, `replace_range_with`, `delete_range`.

Tests: port replace-related tests from `test-trans.ts` (the replace/insert/delete/replaceRange sections).

- [ ] **Step 1: Write tests**
- [ ] **Step 2: Implement Fitter + replace_step**
- [ ] **Step 3: Implement replaceRange, replaceRangeWith, deleteRange**
- [ ] **Step 4: Wire all to Transform**
- [ ] **Step 5: Run tests, fix iteratively**
- [ ] **Step 6: Commit**

---

### Task 11: Structure Helpers (lift, wrap, split, join, setBlockType, setNodeMarkup)

**Files:**
- Create: `lib/prosemirror_ex/transform/structure.ex`
- Modify: `lib/prosemirror_ex/transform/transform.ex`
- Test: `test/prosemirror_ex/transform/structure_test.exs`

Read `reference/prosemirror-transform/src/structure.ts` — ~400 lines.

Implement all structural operations:
- `lift_target(range)` — find valid depth for lifting
- `lift(tr, range, target)` — lift content out of wrapping
- `find_wrapping(range, node_type, attrs, inner_range)` — compute wrappers
- `wrap(tr, range, wrappers)` — wrap range
- `set_block_type(tr, from, to, type, attrs)` — change textblock type (attrs can be function)
- `set_node_markup(tr, pos, type, attrs, marks)` — change node type/attrs/marks
- `can_split(doc, pos, depth, types_after)` — test if split valid
- `split(tr, pos, depth, types_after)` — split node
- `can_join(doc, pos)` — test if join valid
- `join_point(doc, pos, dir)` — find joinable position
- `join(tr, pos, depth)` — join adjacent blocks
- `insert_point(doc, pos, node_type)` — find insertion point
- `drop_point(doc, pos, slice)` — find drop point

Wire all as Transform methods: `lift`, `wrap`, `set_block_type`, `set_node_markup`, `split`, `join`, `set_node_attribute`, `set_doc_attribute`.

Tests: port ALL tests from `test-structure.ts` + structure-related tests from `test-trans.ts`.

- [ ] **Step 1: Write tests (port test-structure.ts)**
- [ ] **Step 2: Implement utility functions (lift_target, find_wrapping, can_split, can_join, etc.)**
- [ ] **Step 3: Implement transform methods (lift, wrap, split, join, set_block_type, set_node_markup)**
- [ ] **Step 4: Wire to Transform**
- [ ] **Step 5: Run tests, fix iteratively**
- [ ] **Step 6: Commit**

---

## Chunk 4: Integration + Final

### Task 12: Step JSON Round-Trip Tests

**Files:**
- Create: `test/prosemirror_ex/transform/step_json_test.exs`

Port ALL tests from `reference/prosemirror-transform/test/test-step.ts`.

The `testStepJSON` pattern:
1. Create a step
2. Apply to doc → get result
3. Serialize step to JSON
4. Deserialize from JSON
5. Apply deserialized to same doc
6. Assert results are equal

Cover all 8 step types.

- [ ] **Step 1: Write all round-trip tests**
- [ ] **Step 2: Run tests (should pass if steps are correct)**
- [ ] **Step 3: Fix any failures**
- [ ] **Step 4: Commit**

---

### Task 13: Full Transform Integration Tests

**Files:**
- Create: `test/prosemirror_ex/transform/integration_test.exs`

Port remaining tests from `test-trans.ts` that weren't covered in earlier tasks. This includes:
- Transform chaining (multiple steps)
- Position mapping through transforms
- Edge cases in replace/delete/insert
- Complex mark operations across block boundaries
- Structural operations with content validation

Also test Transform extensibility: create a mock Transaction struct that adds fields and verify Transform functions work with it.

- [ ] **Step 1: Write integration tests**
- [ ] **Step 2: Run full test suite**
- [ ] **Step 3: Fix any failures**
- [ ] **Step 4: Commit**

---

### Task 14: Final Verification

- [ ] **Step 1: Run full test suite (model + transform)**

```bash
mix test
```

Must be 518+ (model) + new transform tests, all passing.

- [ ] **Step 2: Check for stubs**

```bash
grep -r "not yet implemented\|TODO\|FIXME" lib/prosemirror_ex/transform/
```

- [ ] **Step 3: Format**

```bash
mix format
```

- [ ] **Step 4: Final commit**

```bash
git add -A && git commit -m "Complete prosemirror-transform Elixir port"
```
