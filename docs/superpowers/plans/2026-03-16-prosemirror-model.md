# ProseMirror Model Elixir Port - Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port prosemirror-model (JS) to idiomatic Elixir with full wire-format compatibility and exhaustive tests.

**Architecture:** Bottom-up module implementation following dependency order. All modules under `ProsemirrorEx.Model`. Structs for data types, functional APIs, pattern matching for TextNode behavior. JSON compatibility via Jason.

**Tech Stack:** Elixir ~> 1.15, Jason (JSON), StreamData (property tests, dev/test only)

**Spec:** `docs/superpowers/specs/2026-03-16-prosemirror-model-design.md`

**JS Source Reference:** Each agent MUST fetch and read the upstream JS source from `https://raw.githubusercontent.com/ProseMirror/prosemirror-model/master/src/<file>.ts` when implementing complex modules (especially content.ts, schema.ts, replace.ts, resolvedpos.ts). Port line-by-line where needed.

**Critical Implementation Notes:**
- All tasks follow TDD: write tests FIRST, verify they fail, then implement, then verify they pass.
- `MarkType.excludes/2` must handle self-exclusion: same-type marks exclude each other by default (when `excluded` is nil/not set).
- `Fragment.nodes_between` should use a recursive function, not `Enum.reduce_while`, since the JS version relies on side-effect callbacks.
- `Diff` module must use `Node.eq/2` for child comparison, NOT Elixir `==` (which would be too expensive on full structs with schema references).
- `Node.to_string` conflicts with `Kernel.to_string/1`. Name the function `debug_string/1` in the Node module, and use it in the `String.Chars` protocol implementation.
- `test/support/` files must be compiled. Add `elixirc_paths` to mix.exs: `defp elixirc_paths(:test), do: ["lib", "test/support"]` and `defp elixirc_paths(_), do: ["lib"]`.

---

## Chunk 1: Project Setup + Utilities

### Task 1: Project Setup

**Files:**
- Create: `mix.exs`
- Create: `lib/prosemirror_ex.ex`
- Create: `lib/prosemirror_ex/model.ex`
- Create: `test/test_helper.exs`
- Create: `.formatter.exs`

- [ ] **Step 1: Create project with mix**

```bash
cd /home/yammine/Work/prosemirror_ex
# Remove any existing files except docs/ and .git/
mix new prosemirror_ex --app prosemirror_ex
```

Note: Since the directory already exists with docs/ and .git/, we'll need to initialize the mix project carefully. Run `mix new` in a temp location and move files, or create files manually.

- [ ] **Step 2: Create mix.exs with dependencies**

```elixir
defmodule ProsemirrorEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :prosemirror_ex,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end
end
```

- [ ] **Step 3: Create lib/prosemirror_ex.ex**

```elixir
defmodule ProsemirrorEx do
  @moduledoc "ProseMirror document model for Elixir."
end
```

- [ ] **Step 4: Create lib/prosemirror_ex/model.ex**

```elixir
defmodule ProsemirrorEx.Model do
  @moduledoc "Core document model types and operations."
end
```

- [ ] **Step 5: Create test/test_helper.exs**

```elixir
ExUnit.start()
```

- [ ] **Step 6: Install dependencies and verify**

```bash
cd /home/yammine/Work/prosemirror_ex && mix deps.get && mix test
```

Expected: 0 tests, 0 failures

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Initialize Elixir project with mix, add Jason and StreamData deps"
```

---

### Task 2: CompareDeep

**Files:**
- Create: `lib/prosemirror_ex/model/compare_deep.ex`
- Create: `test/prosemirror_ex/model/compare_deep_test.exs`

This is a utility for deep equality of plain maps and lists, used for attribute comparison.

Reference JS (`src/comparedeep.ts`):
```javascript
export function compareDeep(a, b) {
  if (a === b) return true
  if (!(a && typeof a == "object") || !(b && typeof b == "object")) return false
  let array = Array.isArray(a)
  if (Array.isArray(b) != array) return false
  if (array) {
    if (a.length != b.length) return false
    for (let i = 0; i < a.length; i++) if (!compareDeep(a[i], b[i])) return false
  } else {
    for (let p in a) if (!(p in b) || !compareDeep(a[p], b[p])) return false
    for (let p in b) if (!(p in a)) return false
  }
  return true
}
```

- [ ] **Step 1: Write failing tests**

```elixir
# test/prosemirror_ex/model/compare_deep_test.exs
defmodule ProsemirrorEx.Model.CompareDeepTest do
  use ExUnit.Case, async: true
  alias ProsemirrorEx.Model.CompareDeep

  describe "compare/2" do
    test "identical values are equal" do
      assert CompareDeep.compare(1, 1)
      assert CompareDeep.compare("foo", "foo")
      assert CompareDeep.compare(nil, nil)
      assert CompareDeep.compare(true, true)
    end

    test "different primitives are not equal" do
      refute CompareDeep.compare(1, 2)
      refute CompareDeep.compare("foo", "bar")
      refute CompareDeep.compare(true, false)
      refute CompareDeep.compare(nil, 0)
    end

    test "compares flat maps" do
      assert CompareDeep.compare(%{"a" => 1, "b" => 2}, %{"a" => 1, "b" => 2})
      refute CompareDeep.compare(%{"a" => 1}, %{"a" => 2})
      refute CompareDeep.compare(%{"a" => 1}, %{"a" => 1, "b" => 2})
      refute CompareDeep.compare(%{"a" => 1, "b" => 2}, %{"a" => 1})
    end

    test "compares nested maps" do
      assert CompareDeep.compare(
        %{"a" => %{"b" => 1}},
        %{"a" => %{"b" => 1}}
      )
      refute CompareDeep.compare(
        %{"a" => %{"b" => 1}},
        %{"a" => %{"b" => 2}}
      )
    end

    test "compares lists" do
      assert CompareDeep.compare([1, 2, 3], [1, 2, 3])
      refute CompareDeep.compare([1, 2], [1, 2, 3])
      refute CompareDeep.compare([1, 2, 3], [1, 2])
      refute CompareDeep.compare([1, 2], [1, 3])
    end

    test "compares nested lists" do
      assert CompareDeep.compare([[1, 2], [3]], [[1, 2], [3]])
      refute CompareDeep.compare([[1, 2], [3]], [[1, 2], [4]])
    end

    test "map vs list are not equal" do
      refute CompareDeep.compare(%{}, [])
      refute CompareDeep.compare([], %{})
    end

    test "nil vs map/list are not equal" do
      refute CompareDeep.compare(nil, %{})
      refute CompareDeep.compare(%{}, nil)
      refute CompareDeep.compare(nil, [])
    end

    test "handles maps with nil values" do
      assert CompareDeep.compare(%{"a" => nil}, %{"a" => nil})
      refute CompareDeep.compare(%{"a" => nil}, %{})
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/prosemirror_ex/model/compare_deep_test.exs
```

Expected: compilation error, module not found

- [ ] **Step 3: Implement CompareDeep**

```elixir
# lib/prosemirror_ex/model/compare_deep.ex
defmodule ProsemirrorEx.Model.CompareDeep do
  @moduledoc false

  @spec compare(any(), any()) :: boolean()
  def compare(a, a), do: true

  def compare(a, b) when is_map(a) and is_map(b) do
    # Exclude structs - only compare plain maps
    not Map.has_key?(a, :__struct__) and
      not Map.has_key?(b, :__struct__) and
      map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} ->
        Map.has_key?(b, k) and compare(v, Map.get(b, k))
      end)
  end

  def compare(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> compare(x, y) end)
  end

  def compare(_a, _b), do: false
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/prosemirror_ex/model/compare_deep_test.exs
```

Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/compare_deep.ex test/prosemirror_ex/model/compare_deep_test.exs
git commit -m "Add CompareDeep utility for deep equality of attrs"
```

---

### Task 3: ReplaceError Exception

**Files:**
- Create: `lib/prosemirror_ex/model/replace_error.ex`

A simple exception module, no tests needed.

- [ ] **Step 1: Create ReplaceError**

```elixir
# lib/prosemirror_ex/model/replace_error.ex
defmodule ProsemirrorEx.Model.ReplaceError do
  defexception [:message]
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/prosemirror_ex/model/replace_error.ex
git commit -m "Add ReplaceError exception"
```

---

## Chunk 2: Mark

### Task 4: Mark Struct and Operations

**Files:**
- Create: `lib/prosemirror_ex/model/mark.ex`
- Create: `lib/prosemirror_ex/model/mark_type.ex` (stub struct only)
- Create: `test/prosemirror_ex/model/mark_test.exs`

Mark depends on MarkType for `type.rank` (ordering) and `type.excludes()` (exclusion). We create a minimal MarkType struct first, then implement Mark operations. Full MarkType implementation comes in Task 9.

Reference JS (`src/mark.ts`): Mark has `type`, `attrs`, and methods: `addToSet`, `removeFromSet`, `isInSet`, `eq`, `toJSON`, plus statics `sameSet`, `setFrom`, `fromJSON`, `none`.

- [ ] **Step 1: Create MarkType stub struct**

```elixir
# lib/prosemirror_ex/model/mark_type.ex
defmodule ProsemirrorEx.Model.MarkType do
  @moduledoc "A mark type is a specification for a type of mark in a schema."

  defstruct [:name, :rank, :schema, :spec, :excluded, :instance, :attrs]

  @doc "Check whether this mark type excludes another."
  # Default: same-type marks exclude each other
  def excludes(%__MODULE__{excluded: nil, name: name}, %__MODULE__{name: other_name}) do
    name == other_name
  end
  # :all means globally excluding (excludes everything)
  def excludes(%__MODULE__{excluded: :all}, _other), do: true
  # Explicit exclusion list
  def excludes(%__MODULE__{excluded: excluded}, %__MODULE__{} = other) when is_list(excluded) do
    Enum.any?(excluded, fn ex -> ex.name == other.name end)
  end
end
```

- [ ] **Step 2: Create Mark struct and operations**

```elixir
# lib/prosemirror_ex/model/mark.ex
defmodule ProsemirrorEx.Model.Mark do
  @moduledoc "A mark is a piece of information attached to a node, such as emphasis or a link."

  alias ProsemirrorEx.Model.{CompareDeep, MarkType}

  defstruct [:type, :attrs]

  @type t :: %__MODULE__{
    type: MarkType.t(),
    attrs: map()
  }

  @doc "The empty set of marks."
  def none, do: []

  @doc "Test whether two marks are equal (same type and attributes)."
  def eq(%__MODULE__{type: type, attrs: attrs}, %__MODULE__{type: type2, attrs: attrs2}) do
    type.name == type2.name and CompareDeep.compare(attrs, attrs2)
  end

  @doc "Test whether two sets of marks are identical."
  def same_set(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> eq(x, y) end)
  end

  @doc """
  Add this mark to a set, returning a new set. Respects rank ordering
  and exclusion rules.
  """
  def add_to_set(%__MODULE__{} = mark, set) when is_list(set) do
    {copy, placed} = do_add_to_set(mark, set, [], false)
    if placed, do: copy, else: copy ++ [mark]
  end

  defp do_add_to_set(_mark, [], acc, placed), do: {Enum.reverse(acc), placed}

  defp do_add_to_set(mark, [other | rest], acc, placed) do
    cond do
      eq(mark, other) ->
        # Already in set, return original
        {Enum.reverse(acc) ++ [other | rest], true}

      MarkType.excludes(mark.type, other.type) ->
        # Mark excludes this one, skip it
        do_add_to_set(mark, rest, acc, placed)

      MarkType.excludes(other.type, mark.type) ->
        # Other excludes mark, return set unchanged
        {Enum.reverse(acc) ++ [other | rest], true}

      not placed and other.type.rank > mark.type.rank ->
        # Insert mark here (before higher-ranked), continue
        do_add_to_set(mark, rest, [other, mark | acc], true)

      true ->
        do_add_to_set(mark, rest, [other | acc], placed)
    end
  end

  @doc "Remove this mark from a set, returning a new set."
  def remove_from_set(%__MODULE__{} = mark, set) when is_list(set) do
    case Enum.find_index(set, &eq(mark, &1)) do
      nil -> set
      idx -> List.delete_at(set, idx)
    end
  end

  @doc "Test whether this mark is in the given set. Returns the matching mark or nil."
  def is_in_set(%__MODULE__{} = mark, set) when is_list(set) do
    Enum.find(set, &eq(mark, &1))
  end

  @doc "Create a properly sorted mark set from nil, a single mark, or an unsorted list."
  def set_from(nil), do: none()
  def set_from([]), do: none()
  def set_from(%__MODULE__{} = mark), do: [mark]

  def set_from(marks) when is_list(marks) do
    Enum.sort_by(marks, & &1.type.rank)
  end

  @doc "Convert this mark to a JSON-serializable representation."
  def to_json(%__MODULE__{type: type, attrs: attrs}) do
    obj = %{"type" => type.name}
    if attrs == %{} or attrs == nil, do: obj, else: Map.put(obj, "attrs", attrs)
  end
end
```

- [ ] **Step 3: Write Mark tests**

```elixir
# test/prosemirror_ex/model/mark_test.exs
defmodule ProsemirrorEx.Model.MarkTest do
  use ExUnit.Case, async: true
  alias ProsemirrorEx.Model.{Mark, MarkType}

  # Create minimal mark types for testing
  defp em_type, do: %MarkType{name: "em", rank: 1, excluded: []}
  defp strong_type, do: %MarkType{name: "strong", rank: 2, excluded: []}
  defp code_type, do: %MarkType{name: "code", rank: 4, excluded: []}

  defp link_type, do: %MarkType{name: "link", rank: 3, excluded: []}

  defp em, do: %Mark{type: em_type(), attrs: %{}}
  defp strong_mark, do: %Mark{type: strong_type(), attrs: %{}}
  defp code_mark, do: %Mark{type: code_type(), attrs: %{}}
  defp link(href, title \\ nil), do: %Mark{type: link_type(), attrs: %{"href" => href, "title" => title}}

  describe "same_set/2" do
    test "returns true for two empty sets" do
      assert Mark.same_set([], [])
    end

    test "returns true for simple identical sets" do
      assert Mark.same_set([em(), strong_mark()], [em(), strong_mark()])
    end

    test "returns false for different sets" do
      refute Mark.same_set([em(), strong_mark()], [em(), code_mark()])
    end

    test "returns false when set size differs" do
      refute Mark.same_set([em(), strong_mark()], [em(), strong_mark(), code_mark()])
    end

    test "recognizes identical links in set" do
      assert Mark.same_set([link("http://foo"), code_mark()], [link("http://foo"), code_mark()])
    end

    test "recognizes different links in set" do
      refute Mark.same_set([link("http://foo"), code_mark()], [link("http://bar"), code_mark()])
    end
  end

  describe "eq/2" do
    test "considers identical links to be the same" do
      assert Mark.eq(link("http://foo"), link("http://foo"))
    end

    test "considers different links to differ" do
      refute Mark.eq(link("http://foo"), link("http://bar"))
    end

    test "considers links with different titles to differ" do
      refute Mark.eq(link("http://foo", "A"), link("http://foo", "B"))
    end
  end

  describe "add_to_set/2" do
    test "can add to the empty set" do
      assert Mark.same_set(Mark.add_to_set(em(), []), [em()])
    end

    test "is a no-op when the added thing is in set" do
      assert Mark.same_set(Mark.add_to_set(em(), [em()]), [em()])
    end

    test "adds marks with lower rank before others" do
      assert Mark.same_set(Mark.add_to_set(em(), [strong_mark()]), [em(), strong_mark()])
    end

    test "adds marks with higher rank after others" do
      assert Mark.same_set(Mark.add_to_set(strong_mark(), [em()]), [em(), strong_mark()])
    end

    test "replaces different marks with new attributes" do
      result = Mark.add_to_set(link("http://bar"), [link("http://foo"), em()])
      assert Mark.same_set(result, [link("http://bar"), em()])
    end

    test "does nothing when adding an existing link" do
      result = Mark.add_to_set(link("http://foo"), [em(), link("http://foo")])
      assert Mark.same_set(result, [em(), link("http://foo")])
    end

    test "puts code marks at the end" do
      result = Mark.add_to_set(code_mark(), [em(), strong_mark(), link("http://foo")])
      assert Mark.same_set(result, [em(), strong_mark(), link("http://foo"), code_mark()])
    end

    test "puts marks with middle rank in the middle" do
      result = Mark.add_to_set(strong_mark(), [em(), code_mark()])
      assert Mark.same_set(result, [em(), strong_mark(), code_mark()])
    end
  end

  describe "add_to_set/2 with exclusion" do
    # Create mark types with exclusion rules
    defp remark_type, do: %MarkType{name: "remark", rank: 1, excluded: []}
    defp user_type do
      # Excludes everything (represented by having all types in excluded)
      # For testing, we'll use a special marker
      %MarkType{name: "user", rank: 2, excluded: :all}
    end
    defp em_group_excluding_type do
      %MarkType{name: "strong_custom", rank: 3, excluded: [%MarkType{name: "em_custom", rank: 4, excluded: []}]}
    end
    defp em_custom_type, do: %MarkType{name: "em_custom", rank: 4, excluded: []}

    test "allows nonexclusive instances of marks with the same type" do
      remark1 = %Mark{type: %MarkType{name: "remark", rank: 1, excluded: []}, attrs: %{"id" => 1}}
      remark2 = %Mark{type: %MarkType{name: "remark", rank: 1, excluded: []}, attrs: %{"id" => 2}}
      result = Mark.add_to_set(remark2, [remark1])
      assert length(result) == 2
    end

    test "doesn't duplicate identical instances of nonexclusive marks" do
      remark1 = %Mark{type: %MarkType{name: "remark", rank: 1, excluded: []}, attrs: %{"id" => 1}}
      result = Mark.add_to_set(remark1, [remark1])
      assert length(result) == 1
    end
  end

  describe "remove_from_set/2" do
    test "is a no-op for the empty set" do
      assert Mark.same_set(Mark.remove_from_set(em(), []), [])
    end

    test "can remove the last mark from a set" do
      assert Mark.same_set(Mark.remove_from_set(em(), [em()]), [])
    end

    test "is a no-op when the mark isn't in the set" do
      assert Mark.same_set(Mark.remove_from_set(strong_mark(), [em()]), [em()])
    end

    test "can remove a mark with attributes" do
      assert Mark.same_set(Mark.remove_from_set(link("http://foo"), [link("http://foo")]), [])
    end

    test "doesn't remove a mark when its attrs differ" do
      result = Mark.remove_from_set(link("http://foo", "title"), [link("http://foo")])
      assert Mark.same_set(result, [link("http://foo")])
    end
  end

  describe "is_in_set/2" do
    test "finds a mark in a set" do
      result = Mark.is_in_set(em(), [em(), strong_mark()])
      assert result != nil
    end

    test "returns nil when mark is not in set" do
      assert Mark.is_in_set(code_mark(), [em(), strong_mark()]) == nil
    end
  end

  describe "set_from/1" do
    test "returns empty list for nil" do
      assert Mark.set_from(nil) == []
    end

    test "returns empty list for empty list" do
      assert Mark.set_from([]) == []
    end

    test "wraps a single mark" do
      assert Mark.set_from(em()) == [em()]
    end

    test "sorts by rank" do
      result = Mark.set_from([strong_mark(), em()])
      assert hd(result).type.rank < List.last(result).type.rank
    end
  end

  describe "to_json/1" do
    test "serializes a simple mark" do
      assert Mark.to_json(em()) == %{"type" => "em"}
    end

    test "serializes a mark with attrs" do
      result = Mark.to_json(link("http://foo"))
      assert result == %{"type" => "link", "attrs" => %{"href" => "http://foo", "title" => nil}}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
mix test test/prosemirror_ex/model/mark_test.exs
```

- [ ] **Step 5: Fix any issues until all tests pass**

```bash
mix test test/prosemirror_ex/model/mark_test.exs
```

Note: The `add_to_set` with exclusion tests may need the `MarkType.excludes/2` function to handle the `:all` case. Update MarkType.excludes:

```elixir
def excludes(%__MODULE__{excluded: :all}, _other), do: true
def excludes(%__MODULE__{excluded: excluded}, %__MODULE__{} = other) when is_list(excluded) do
  Enum.any?(excluded, fn ex -> ex.name == other.name end)
end
```

- [ ] **Step 6: Run full test suite**

```bash
mix test
```

- [ ] **Step 7: Commit**

```bash
git add lib/prosemirror_ex/model/mark.ex lib/prosemirror_ex/model/mark_type.ex test/prosemirror_ex/model/mark_test.exs
git commit -m "Add Mark struct with set operations (addToSet, removeFromSet, eq, sameSet)"
```

---

## Chunk 3: Fragment + Diff + Node

### Task 5: Fragment Struct and Basic Operations

**Files:**
- Create: `lib/prosemirror_ex/model/fragment.ex`
- Create: `lib/prosemirror_ex/model/node.ex` (stub struct only initially)
- Create: `test/prosemirror_ex/model/fragment_test.exs`

Fragment holds child nodes. We need a minimal Node struct to test Fragment operations.

Reference JS (`src/fragment.ts`): Fragment has `content` (node array), `size`, and methods: `nodesBetween`, `descendants`, `textBetween`, `append`, `cut`, `cutByIndex`, `replaceChild`, `addToStart`, `addToEnd`, `eq`, `firstChild`, `lastChild`, `childCount`, `child`, `maybeChild`, `forEach`, `findDiffStart`, `findDiffEnd`, `findIndex`, `toString`, `toJSON`, `fromJSON`, `fromArray`, `from`.

- [ ] **Step 1: Create Node stub struct**

```elixir
# lib/prosemirror_ex/model/node.ex
defmodule ProsemirrorEx.Model.Node do
  @moduledoc "A node in the ProseMirror document tree."

  alias ProsemirrorEx.Model.{Fragment, Mark}

  defstruct [:type, :attrs, :content, :marks, :text]

  @doc "The size of this node in the indexing scheme."
  def node_size(%__MODULE__{text: text}) when is_binary(text), do: String.length(text)
  def node_size(%__MODULE__{type: type, content: content}) do
    if type != nil and type.is_leaf do
      1
    else
      2 + (content && content.size || 0)
    end
  end

  @doc "Whether this is a text node."
  def is_text(%__MODULE__{text: text}), do: text != nil

  @doc "Whether this node is a leaf node."
  def is_leaf(%__MODULE__{type: nil}), do: false
  def is_leaf(%__MODULE__{type: type}), do: type.is_leaf

  @doc "Compare the markup of this node to another."
  def same_markup(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.type == b.type and
      ProsemirrorEx.Model.CompareDeep.compare(a.attrs, b.attrs) and
      Mark.same_set(a.marks || [], b.marks || [])
  end

  @doc "Test whether two nodes represent the same document."
  def eq(%__MODULE__{text: text_a} = a, %__MODULE__{text: text_b} = b) when is_binary(text_a) do
    same_markup(a, b) and text_a == text_b
  end
  def eq(%__MODULE__{} = a, %__MODULE__{} = b) do
    same_markup(a, b) and Fragment.eq(a.content, b.content)
  end
end
```

- [ ] **Step 2: Create Fragment module**

```elixir
# lib/prosemirror_ex/model/fragment.ex
defmodule ProsemirrorEx.Model.Fragment do
  @moduledoc "A fragment represents a node's collection of child nodes."

  alias ProsemirrorEx.Model.Node, as: PMNode

  defstruct [:content, :size]

  @type t :: %__MODULE__{
    content: [PMNode.t()],
    size: non_neg_integer()
  }

  @doc "An empty fragment."
  def empty, do: %__MODULE__{content: [], size: 0}

  @doc "The number of child nodes."
  def child_count(%__MODULE__{content: content}), do: length(content)

  @doc "Get the child at the given index. Raises on out of range."
  def child(%__MODULE__{content: content}, index) do
    case Enum.at(content, index) do
      nil -> raise "Index #{index} out of range for fragment"
      node -> node
    end
  end

  @doc "Get the child at the given index, or nil."
  def maybe_child(%__MODULE__{content: content}, index) do
    Enum.at(content, index)
  end

  @doc "The first child, or nil."
  def first_child(%__MODULE__{content: []}), do: nil
  def first_child(%__MODULE__{content: [first | _]}), do: first

  @doc "The last child, or nil."
  def last_child(%__MODULE__{content: []}), do: nil
  def last_child(%__MODULE__{content: content}), do: List.last(content)

  @doc "Call f for every child node."
  def for_each(%__MODULE__{content: content}, f) do
    Enum.reduce(content, {0, 0}, fn child, {offset, index} ->
      f.(child, offset, index)
      {offset + PMNode.node_size(child), index + 1}
    end)
    :ok
  end

  @doc "Compare two fragments."
  def eq(%__MODULE__{content: a}, %__MODULE__{content: b}) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> PMNode.eq(x, y) end)
  end

  @doc "Build a fragment from an array, joining adjacent text nodes with same marks."
  def from_array([]), do: empty()
  def from_array(array) when is_list(array) do
    {joined, size} = join_adjacent_text(array, [], 0)
    %__MODULE__{content: joined, size: size}
  end

  defp join_adjacent_text([], acc, size), do: {Enum.reverse(acc), size}
  defp join_adjacent_text([node | rest], [], size) do
    join_adjacent_text(rest, [node], size + PMNode.node_size(node))
  end
  defp join_adjacent_text([node | rest], [prev | acc_rest] = acc, size) do
    if PMNode.is_text(node) and PMNode.is_text(prev) and PMNode.same_markup(node, prev) do
      merged = %{prev | text: prev.text <> node.text}
      new_size = size - PMNode.node_size(prev) + PMNode.node_size(merged)
      join_adjacent_text(rest, [merged | acc_rest], new_size)
    else
      join_adjacent_text(rest, [node | acc], size + PMNode.node_size(node))
    end
  end

  @doc "Create a fragment from various input types."
  def from(nil), do: empty()
  def from(%__MODULE__{} = frag), do: frag
  def from(%PMNode{} = node), do: %__MODULE__{content: [node], size: PMNode.node_size(node)}
  def from(nodes) when is_list(nodes), do: from_array(nodes)

  @doc "Cut out the sub-fragment between two positions."
  def cut(%__MODULE__{} = frag, from, to \\ nil) do
    to = if to == nil, do: frag.size, else: to
    if from == 0 and to == frag.size, do: frag, else: do_cut(frag, from, to)
  end

  defp do_cut(%__MODULE__{content: content}, from, to) do
    {result, _size} =
      Enum.reduce_while(content, {[], 0, 0}, fn child, {acc, size, pos} ->
        child_size = PMNode.node_size(child)
        end_pos = pos + child_size

        if end_pos <= from do
          {:cont, {acc, size, end_pos}}
        else if pos >= to do
          {:halt, {acc, size, end_pos}}
        else
          child =
            cond do
              pos < from or end_pos > to ->
                if PMNode.is_text(child) do
                  cut_from = max(0, from - pos)
                  cut_to = min(String.length(child.text), to - pos)
                  %{child | text: String.slice(child.text, cut_from, cut_to - cut_from)}
                else
                  cut_from = max(0, from - pos - 1)
                  cut_to = min(child.content.size, to - pos - 1)
                  %{child | content: cut(child.content, cut_from, cut_to)}
                end
              true ->
                child
            end

          new_size = size + PMNode.node_size(child)
          {:cont, {[child | acc], new_size, end_pos}}
        end end
      end)

    %__MODULE__{content: Enum.reverse(result), size: _size}
  end

  @doc "Create a new fragment containing the combined content of this and other."
  def append(%__MODULE__{size: 0} = _frag, other), do: other
  def append(frag, %__MODULE__{size: 0}), do: frag
  def append(%__MODULE__{content: content, size: size} = _frag,
             %__MODULE__{content: other_content, size: other_size}) do
    last = List.last(content)
    [first_other | rest_other] = other_content

    if PMNode.is_text(last) and PMNode.is_text(first_other) and PMNode.same_markup(last, first_other) do
      merged = %{last | text: last.text <> first_other.text}
      new_content = List.replace_at(content, length(content) - 1, merged) ++ rest_other
      %__MODULE__{content: new_content, size: size + other_size}
    else
      %__MODULE__{content: content ++ other_content, size: size + other_size}
    end
  end

  @doc "Cut by child index."
  def cut_by_index(%__MODULE__{}, from, to) when from == to, do: empty()
  def cut_by_index(%__MODULE__{content: content} = frag, 0, to)
    when to == length(content), do: frag
  def cut_by_index(%__MODULE__{content: content}, from, to) do
    sliced = Enum.slice(content, from, to - from)
    size = Enum.reduce(sliced, 0, fn node, acc -> acc + PMNode.node_size(node) end)
    %__MODULE__{content: sliced, size: size}
  end

  @doc "Replace the child at index with a new node."
  def replace_child(%__MODULE__{content: content, size: size}, index, node) do
    current = Enum.at(content, index)
    if current == node do
      %__MODULE__{content: content, size: size}
    else
      new_content = List.replace_at(content, index, node)
      new_size = size + PMNode.node_size(node) - PMNode.node_size(current)
      %__MODULE__{content: new_content, size: new_size}
    end
  end

  @doc "Prepend a node."
  def add_to_start(%__MODULE__{content: content, size: size}, node) do
    %__MODULE__{content: [node | content], size: size + PMNode.node_size(node)}
  end

  @doc "Append a node."
  def add_to_end(%__MODULE__{content: content, size: size}, node) do
    %__MODULE__{content: content ++ [node], size: size + PMNode.node_size(node)}
  end

  @doc "Find the index and offset for a position."
  def find_index(%__MODULE__{content: content, size: size}, pos) do
    cond do
      pos == 0 -> {0, 0}
      pos == size -> {length(content), pos}
      pos < 0 or pos > size -> raise "Position #{pos} outside of fragment (size #{size})"
      true -> do_find_index(content, pos, 0, 0)
    end
  end

  defp do_find_index([child | rest], pos, index, cur_pos) do
    end_pos = cur_pos + PMNode.node_size(child)
    if end_pos >= pos do
      if end_pos == pos do
        {index + 1, end_pos}
      else
        {index, cur_pos}
      end
    else
      do_find_index(rest, pos, index + 1, end_pos)
    end
  end

  @doc "Serialize to JSON (array of node JSON, or null if empty)."
  def to_json(%__MODULE__{content: []}), do: nil
  def to_json(%__MODULE__{content: content}) do
    Enum.map(content, &PMNode.to_json/1)
  end

  @doc "Return a string representation."
  def to_string_inner(%__MODULE__{content: content}) do
    content |> Enum.map(&Kernel.to_string/1) |> Enum.join(", ")
  end
end
```

- [ ] **Step 3: Write Fragment tests**

Write tests for: `empty`, `from_array`, `from`, `child_count`, `child`, `maybe_child`, `first_child`, `last_child`, `eq`, `cut`, `append`, `find_index`, `add_to_start`, `add_to_end`, `replace_child`, `cut_by_index`.

Use manually constructed nodes (no schema needed) with a minimal NodeType stub.

```elixir
# test/prosemirror_ex/model/fragment_test.exs
defmodule ProsemirrorEx.Model.FragmentTest do
  use ExUnit.Case, async: true
  alias ProsemirrorEx.Model.{Fragment, Node, Mark}

  # Minimal node type stubs for testing
  defp text_type, do: %{name: "text", is_leaf: true, is_text: true, is_block: false, is_inline: true, spec: %{}}
  defp para_type, do: %{name: "paragraph", is_leaf: false, is_text: false, is_block: true, is_inline: false, spec: %{}}

  defp text_node(text, marks \\ []) do
    %Node{type: text_type(), attrs: %{}, content: Fragment.empty(), marks: marks, text: text}
  end

  defp para_node(children) do
    content = Fragment.from_array(children)
    %Node{type: para_type(), attrs: %{}, content: content, marks: []}
  end

  describe "empty/0" do
    test "returns a fragment with no children" do
      frag = Fragment.empty()
      assert frag.content == []
      assert frag.size == 0
      assert Fragment.child_count(frag) == 0
    end
  end

  describe "from_array/1" do
    test "creates from empty list" do
      assert Fragment.from_array([]) == Fragment.empty()
    end

    test "creates from single text node" do
      node = text_node("hello")
      frag = Fragment.from_array([node])
      assert Fragment.child_count(frag) == 1
      assert frag.size == 5
    end

    test "joins adjacent text nodes with same markup" do
      a = text_node("hello")
      b = text_node(" world")
      frag = Fragment.from_array([a, b])
      assert Fragment.child_count(frag) == 1
      assert Fragment.child(frag, 0).text == "hello world"
    end

    test "does not join text nodes with different marks" do
      em_type = %{name: "em", rank: 1, excluded: []}
      a = text_node("hello")
      b = text_node("world", [%Mark{type: em_type, attrs: %{}}])
      frag = Fragment.from_array([a, b])
      assert Fragment.child_count(frag) == 2
    end
  end

  describe "from/1" do
    test "returns empty for nil" do
      assert Fragment.from(nil) == Fragment.empty()
    end

    test "returns the fragment itself" do
      frag = Fragment.from_array([text_node("x")])
      assert Fragment.from(frag) == frag
    end

    test "wraps a single node" do
      node = text_node("x")
      frag = Fragment.from(node)
      assert Fragment.child_count(frag) == 1
    end

    test "wraps a list" do
      frag = Fragment.from([text_node("a"), text_node("b")])
      assert Fragment.child_count(frag) == 1  # joined
    end
  end

  describe "child access" do
    setup do
      a = text_node("hello")
      b = para_node([text_node("world")])
      frag = Fragment.from_array([a, b])
      %{frag: frag, a: a, b: b}
    end

    test "child/2 returns child at index", %{frag: frag, a: a} do
      assert Node.eq(Fragment.child(frag, 0), a)
    end

    test "child/2 raises on out of range", %{frag: frag} do
      assert_raise RuntimeError, fn -> Fragment.child(frag, 5) end
    end

    test "maybe_child/2 returns nil on out of range", %{frag: frag} do
      assert Fragment.maybe_child(frag, 5) == nil
    end

    test "first_child/1", %{frag: frag, a: a} do
      assert Node.eq(Fragment.first_child(frag), a)
    end

    test "last_child/1", %{frag: frag, b: b} do
      assert Node.eq(Fragment.last_child(frag), b)
    end

    test "first/last child of empty" do
      assert Fragment.first_child(Fragment.empty()) == nil
      assert Fragment.last_child(Fragment.empty()) == nil
    end
  end

  describe "eq/2" do
    test "empty fragments are equal" do
      assert Fragment.eq(Fragment.empty(), Fragment.empty())
    end

    test "same content is equal" do
      a = Fragment.from_array([text_node("hi")])
      b = Fragment.from_array([text_node("hi")])
      assert Fragment.eq(a, b)
    end

    test "different content is not equal" do
      a = Fragment.from_array([text_node("hi")])
      b = Fragment.from_array([text_node("bye")])
      refute Fragment.eq(a, b)
    end
  end

  describe "cut/3" do
    test "returns self when cutting full range" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.cut(frag, 0) == frag
    end

    test "cuts text" do
      frag = Fragment.from_array([text_node("hello")])
      result = Fragment.cut(frag, 1, 4)
      assert Fragment.child(result, 0).text == "ell"
    end

    test "cuts across nodes" do
      frag = Fragment.from_array([para_node([text_node("ab")]), para_node([text_node("cd")])])
      # size of first para: 2 + 2 = 4, second: 4, total: 8
      # Cut from position 0 to 4 should give just the first paragraph
      result = Fragment.cut(frag, 0, 4)
      assert Fragment.child_count(result) == 1
    end
  end

  describe "append/2" do
    test "appending empty returns self" do
      frag = Fragment.from_array([text_node("a")])
      assert Fragment.append(frag, Fragment.empty()) == frag
    end

    test "prepending empty returns other" do
      frag = Fragment.from_array([text_node("a")])
      assert Fragment.append(Fragment.empty(), frag) == frag
    end

    test "joins adjacent text with same marks" do
      a = Fragment.from_array([text_node("hello")])
      b = Fragment.from_array([text_node(" world")])
      result = Fragment.append(a, b)
      assert Fragment.child_count(result) == 1
      assert Fragment.child(result, 0).text == "hello world"
    end

    test "does not join different node types" do
      a = Fragment.from_array([text_node("a")])
      b = Fragment.from_array([para_node([text_node("b")])])
      result = Fragment.append(a, b)
      assert Fragment.child_count(result) == 2
    end
  end

  describe "find_index/2" do
    test "returns {0, 0} for position 0" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 0) == {0, 0}
    end

    test "returns {count, size} for position == size" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 5) == {1, 5}
    end

    test "finds position within text" do
      frag = Fragment.from_array([text_node("hello")])
      assert Fragment.find_index(frag, 3) == {0, 0}
    end

    test "raises for position out of range" do
      frag = Fragment.from_array([text_node("hello")])
      assert_raise RuntimeError, fn -> Fragment.find_index(frag, 10) end
    end
  end
end
```

- [ ] **Step 4: Run tests, fix issues until all pass**

```bash
mix test test/prosemirror_ex/model/fragment_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/fragment.ex lib/prosemirror_ex/model/node.ex test/prosemirror_ex/model/fragment_test.exs
git commit -m "Add Fragment struct with basic operations (cut, append, eq, from_array)"
```

---

### Task 6: Diff Module

**Files:**
- Create: `lib/prosemirror_ex/model/diff.ex`
- Create: `test/prosemirror_ex/model/diff_test.exs`

Reference JS (`src/diff.ts`): Two functions — `findDiffStart(a, b, pos)` and `findDiffEnd(a, b, posA, posB)`.

- [ ] **Step 1: Implement Diff module**

Port directly from the JS source. Key logic:
- Walk children in parallel
- Return nil if identical
- Return position of first difference
- For text nodes, find character-level diff position

```elixir
# lib/prosemirror_ex/model/diff.ex
defmodule ProsemirrorEx.Model.Diff do
  @moduledoc false

  alias ProsemirrorEx.Model.{Fragment, Node}

  @doc "Find the first position where two fragments differ."
  def find_diff_start(%Fragment{} = a, %Fragment{} = b, pos \\ 0) do
    do_find_diff_start(a, b, pos, 0)
  end

  defp do_find_diff_start(a, b, pos, i) do
    a_count = Fragment.child_count(a)
    b_count = Fragment.child_count(b)

    cond do
      i == a_count or i == b_count ->
        if a_count == b_count, do: nil, else: pos

      true ->
        child_a = Fragment.child(a, i)
        child_b = Fragment.child(b, i)

        cond do
          child_a == child_b ->
            do_find_diff_start(a, b, pos + Node.node_size(child_a), i + 1)

          not Node.same_markup(child_a, child_b) ->
            pos

          Node.is_text(child_a) and child_a.text != child_b.text ->
            j = find_text_diff_start(child_a.text, child_b.text, 0)
            pos + j

          true ->
            if child_a.content.size > 0 or child_b.content.size > 0 do
              inner = find_diff_start(child_a.content, child_b.content, pos + 1)
              if inner != nil, do: inner, else: do_find_diff_start(a, b, pos + Node.node_size(child_a), i + 1)
            else
              do_find_diff_start(a, b, pos + Node.node_size(child_a), i + 1)
            end
        end
    end
  end

  defp find_text_diff_start(a, b, j) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    if j < length(a_chars) and j < length(b_chars) and
       Enum.at(a_chars, j) == Enum.at(b_chars, j) do
      find_text_diff_start(a, b, j + 1)
    else
      j
    end
  end

  @doc "Find the first position from the end where two fragments differ."
  def find_diff_end(%Fragment{} = a, %Fragment{} = b, pos_a \\ nil, pos_b \\ nil) do
    pos_a = if pos_a == nil, do: a.size, else: pos_a
    pos_b = if pos_b == nil, do: b.size, else: pos_b
    do_find_diff_end(a, b, pos_a, pos_b, Fragment.child_count(a), Fragment.child_count(b))
  end

  defp do_find_diff_end(a, b, pos_a, pos_b, i_a, i_b) do
    cond do
      i_a == 0 or i_b == 0 ->
        if i_a == i_b, do: nil, else: %{a: pos_a, b: pos_b}

      true ->
        child_a = Fragment.child(a, i_a - 1)
        child_b = Fragment.child(b, i_b - 1)
        size = Node.node_size(child_a)

        cond do
          child_a == child_b ->
            do_find_diff_end(a, b, pos_a - size, pos_b - Node.node_size(child_b), i_a - 1, i_b - 1)

          not Node.same_markup(child_a, child_b) ->
            %{a: pos_a, b: pos_b}

          Node.is_text(child_a) and child_a.text != child_b.text ->
            {new_pos_a, new_pos_b} = find_text_diff_end(child_a.text, child_b.text, pos_a, pos_b)
            %{a: new_pos_a, b: new_pos_b}

          true ->
            if child_a.content.size > 0 or child_b.content.size > 0 do
              inner = find_diff_end(child_a.content, child_b.content, pos_a - 1, pos_b - 1)
              if inner != nil, do: inner, else: do_find_diff_end(a, b, pos_a - size, pos_b - Node.node_size(child_b), i_a - 1, i_b - 1)
            else
              do_find_diff_end(a, b, pos_a - size, pos_b - Node.node_size(child_b), i_a - 1, i_b - 1)
            end
        end
    end
  end

  defp find_text_diff_end(a, b, pos_a, pos_b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    min_size = min(length(a_chars), length(b_chars))
    do_text_diff_end(a_chars, b_chars, pos_a, pos_b, 0, min_size)
  end

  defp do_text_diff_end(a_chars, b_chars, pos_a, pos_b, same, min_size) do
    if same < min_size and
       Enum.at(a_chars, length(a_chars) - same - 1) == Enum.at(b_chars, length(b_chars) - same - 1) do
      do_text_diff_end(a_chars, b_chars, pos_a - 1, pos_b - 1, same + 1, min_size)
    else
      {pos_a, pos_b}
    end
  end
end
```

- [ ] **Step 2: Write Diff tests (ported from JS test-diff.ts)**

Tests use the tag system from the test builder. Since we don't have the test schema yet, we'll create test docs manually. These tests will be expanded when the schema is available.

```elixir
# test/prosemirror_ex/model/diff_test.exs
defmodule ProsemirrorEx.Model.DiffTest do
  use ExUnit.Case, async: true
  alias ProsemirrorEx.Model.{Diff, Fragment, Node}

  # Minimal helpers
  defp text_type, do: %{name: "text", is_leaf: true, is_text: true, is_block: false, is_inline: true, spec: %{}}
  defp text(t), do: %Node{type: text_type(), attrs: %{}, content: Fragment.empty(), marks: [], text: t}

  describe "find_diff_start/3" do
    test "returns nil for identical fragments" do
      a = Fragment.from_array([text("hello")])
      assert Diff.find_diff_start(a, a) == nil
    end

    test "finds diff when one fragment is longer" do
      a = Fragment.from_array([text("hello")])
      b = Fragment.from_array([text("hello"), text("x")])
      assert Diff.find_diff_start(a, b) == 5
    end

    test "finds character-level diff in text" do
      a = Fragment.from_array([text("foobar")])
      b = Fragment.from_array([text("foocar")])
      assert Diff.find_diff_start(a, b) == 3
    end
  end

  describe "find_diff_end/4" do
    test "returns nil for identical fragments" do
      a = Fragment.from_array([text("hello")])
      assert Diff.find_diff_end(a, a) == nil
    end

    test "finds diff from end in text" do
      a = Fragment.from_array([text("foobar")])
      b = Fragment.from_array([text("foocar")])
      result = Diff.find_diff_end(a, b)
      assert result.a == 4
      assert result.b == 4
    end
  end
end
```

- [ ] **Step 3: Run tests, fix until pass**

```bash
mix test test/prosemirror_ex/model/diff_test.exs
```

- [ ] **Step 4: Wire up Fragment.find_diff_start/find_diff_end**

Add to Fragment module:

```elixir
def find_diff_start(%__MODULE__{} = a, %__MODULE__{} = b, pos \\ 0) do
  ProsemirrorEx.Model.Diff.find_diff_start(a, b, pos)
end

def find_diff_end(%__MODULE__{} = a, %__MODULE__{} = b, pos \\ nil, other_pos \\ nil) do
  ProsemirrorEx.Model.Diff.find_diff_end(a, b, pos, other_pos)
end
```

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/diff.ex test/prosemirror_ex/model/diff_test.exs lib/prosemirror_ex/model/fragment.ex
git commit -m "Add Diff module (findDiffStart, findDiffEnd) and wire to Fragment"
```

---

### Task 7: Node Full Implementation

**Files:**
- Modify: `lib/prosemirror_ex/model/node.ex` (expand from stub)
- Create: `test/prosemirror_ex/model/node_test.exs`

Complete the Node module with all operations from the spec. Key methods: `copy`, `mark`, `cut`, `for_each`, `nodes_between`, `descendants`, `text_between`, `text_content`, `node_at`, `child_after`, `child_before`, `to_json`, `children`, `child_count`, `first_child`, `last_child`, property accessors.

The `slice`, `replace`, `resolve`, `check`, `can_replace*`, `content_match_at`, `from_json` functions depend on later modules (Schema, ResolvedPos, Slice, Replace) and will be added as stubs that raise "not yet implemented", then completed in later tasks.

Reference: see the full `node.ts` source code captured above.

- [ ] **Step 1: Implement full Node module**

Key implementation points:
- `node_size`: text length for TextNode, 1 for leaf, 2 + content.size for others
- `copy(node, content)`: new node with same type/attrs/marks but different content
- `mark(node, marks)`: new node with different marks
- `cut(node, from, to)`: delegates to content.cut for non-text, string slice for text
- `nodes_between`: recursive traversal delegating to Fragment.nodes_between
- `text_between`: delegates to content.text_between
- `text_content`: for text nodes returns text, for leaf nodes with leafText calls it, otherwise text_between(0, content.size)
- `node_at(pos)`: iterative descent through findIndex
- `child_after(pos)`, `child_before(pos)`: use findIndex
- `to_json`: serialize type name, attrs (if non-empty), content (if non-empty), marks (if any), text (for text nodes)
- `eq`: for text nodes, same_markup + same text; for others, same_markup + content.eq
- `range_has_mark`: iterate with nodes_between, check type.isInSet
- Boolean properties (`is_block`, `is_textblock`, etc.): delegate to type

- [ ] **Step 2: Write Node tests (ported from JS test-node.ts)**

Port the following test groups:
- `toString` — test string representation
- `cut` — extract sub-documents
- `between/nodesBetween` — iteration over ranges
- `textBetween` — text extraction with separators and leafText
- `textContent` — plain text content
- `from` — Fragment.from with various inputs
- `toJSON` — JSON serialization round trips

Tests that need Schema (check, fromJSON) are deferred to Task 9.

- [ ] **Step 3: Run tests, fix until pass**

```bash
mix test test/prosemirror_ex/model/node_test.exs
```

- [ ] **Step 4: Commit**

```bash
git add lib/prosemirror_ex/model/node.ex test/prosemirror_ex/model/node_test.exs
git commit -m "Implement full Node module with traversal, cut, text extraction, toJSON"
```

---

### Task 8: Fragment Full API (nodes_between, text_between, fromJSON stub)

**Files:**
- Modify: `lib/prosemirror_ex/model/fragment.ex`
- Modify: `test/prosemirror_ex/model/fragment_test.exs`

Complete Fragment with the remaining methods that depend on Node:
- `nodes_between(frag, from, to, f, node_start, parent)` — recursive traversal
- `descendants(frag, f)` — wrapper around nodes_between
- `text_between(frag, from, to, block_sep, leaf_text)` — text extraction
- `to_string` / `to_string_inner` — debug representation

Reference: see `fragment.ts` source captured above. The `nodesBetween` and `textBetween` implementations are straightforward ports.

- [ ] **Step 1: Implement nodesBetween**

```elixir
def nodes_between(%__MODULE__{content: content}, from, to, f, node_start \\ 0, parent \\ nil) do
  Enum.reduce_while(content |> Enum.with_index(), 0, fn {child, i}, pos ->
    end_pos = pos + PMNode.node_size(child)
    if end_pos > from do
      result = f.(child, node_start + pos, parent, i)
      if result != false and child.content != nil and child.content.size > 0 do
        start = pos + 1
        nodes_between(child.content,
          max(0, from - start),
          min(child.content.size, to - start),
          f, node_start + start, child)
      end
    end
    if end_pos < to, do: {:cont, end_pos}, else: {:halt, end_pos}
  end)
  :ok
end
```

- [ ] **Step 2: Implement textBetween**

Port from JS `textBetween` in fragment.ts.

- [ ] **Step 3: Add tests for nodesBetween, descendants, textBetween**

- [ ] **Step 4: Run tests, fix until pass**

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/fragment.ex test/prosemirror_ex/model/fragment_test.exs
git commit -m "Complete Fragment API: nodesBetween, descendants, textBetween"
```

---

## Chunk 4: ContentMatch Expression Engine

### Task 9: ContentMatch

**Files:**
- Create: `lib/prosemirror_ex/model/content_match.ex`
- Create: `lib/prosemirror_ex/model/node_type.ex` (stub struct for testing)
- Create: `test/prosemirror_ex/model/content_match_test.exs`

This is the most complex algorithmic piece. It implements a content expression language compiled to a DFA.

Reference JS (`src/content.ts`): ~500 lines implementing:
1. **Tokenizer**: splits expression string into tokens (name, `*`, `+`, `?`, `{`, `}`, `(`, `)`, `|`, `,`, numbers)
2. **Parser**: builds an AST from tokens. Grammar:
   - expr = seq (`|` seq)*
   - seq = (atom modifier?)+
   - atom = name | `(` expr `)`
   - modifier = `*` | `+` | `?` | `{` min `,` max? `}`
3. **NFA builder**: converts AST to NFA states with `null` (epsilon) and typed edges
4. **DFA converter**: subset construction from NFA to DFA
5. **ContentMatch**: the DFA state with `next` edges, `validEnd`, and matching/filling methods

Key methods on ContentMatch:
- `matchType(type)` — follow edge for type, return next state or null
- `matchFragment(frag, start?, end?)` — match a sequence of nodes
- `fillBefore(after, toEnd?, startIndex?)` — generate required nodes to satisfy expression
- `findWrapping(target)` — find node types that wrap target to make it valid
- `defaultType` — first type reachable from this state
- `edgeCount`, `edge(n)` — introspect DFA
- `validEnd` — whether this is an accepting state

- [ ] **Step 1: Create NodeType stub for testing**

```elixir
# Update lib/prosemirror_ex/model/node_type.ex
defmodule ProsemirrorEx.Model.NodeType do
  @moduledoc "A node type in a ProseMirror schema."

  defstruct [
    :name, :schema, :spec, :groups, :content_match,
    :mark_set, :inline_content, :is_block, :is_text,
    :is_inline, :is_textblock, :is_leaf, :is_atom,
    :default_attrs, :attrs, :has_required_attrs
  ]
end
```

- [ ] **Step 2: Implement ContentMatch module**

This is a large implementation. Key structure:

```elixir
defmodule ProsemirrorEx.Model.ContentMatch do
  defstruct [:valid_end, :next, :wrap_cache]

  # next: [{%NodeType{}, %ContentMatch{}}]
  # wrap_cache: flat list [type, result | nil, ...]

  def empty do
    %__MODULE__{valid_end: true, next: [], wrap_cache: []}
  end

  def match_type(%__MODULE__{next: next}, type) do
    Enum.find_value(next, fn {t, match} ->
      if t == type, do: match
    end)
  end

  def match_fragment(%__MODULE__{} = match, frag, start \\ 0, end_val \\ nil) do
    # Match each child type in sequence
    ...
  end

  def fill_before(%__MODULE__{} = match, after_frag, to_end \\ false, start_index \\ 0) do
    # Find nodes needed to reach a state that accepts after_frag
    ...
  end

  def find_wrapping(%__MODULE__{} = match, target) do
    # BFS to find wrapping node types
    ...
  end

  def parse(string, node_types) do
    # Full pipeline: tokenize -> parse -> NFA -> DFA
    ...
  end
end
```

The full implementation should be a faithful port of `content.ts`. Key internal structures:
- Token list from tokenizer
- AST nodes: `{:choice, exprs}`, `{:seq, exprs}`, `{:plus, expr}`, `{:star, expr}`, `{:opt, expr}`, `{:range, expr, min, max}`, `{:name, name, list_of_types}`
- NFA state: `%{id: int, edges: [{type | nil, state}]}`
- DFA construction via subset construction

- [ ] **Step 3: Write ContentMatch tests (ported from JS test-content.ts)**

Port all `matchType` tests:
- Empty expression, asterisks, groups, choices, sequences, optional elements, nested repeats, counted groups, open ranges

Port all `fillBefore` tests:
- Returns empty when things match, adds nodes, handles asterisks/plus, counted groups, three-way fills

These tests require a schema to resolve node type names in expressions. Since we don't have Schema yet, create a minimal `node_types` map for testing:

```elixir
defp make_node_types do
  types = %{
    "paragraph" => %NodeType{name: "paragraph", groups: ["block"], is_block: true, is_leaf: false, ...},
    "heading" => %NodeType{name: "heading", groups: ["block"], ...},
    "text" => %NodeType{name: "text", groups: ["inline"], is_text: true, ...},
    "image" => %NodeType{name: "image", groups: ["inline"], is_inline: true, ...},
    "hard_break" => %NodeType{name: "hard_break", groups: ["inline"], ...},
    "horizontal_rule" => %NodeType{name: "horizontal_rule", groups: ["block"], ...},
    "code_block" => %NodeType{name: "code_block", groups: ["block"], ...},
    ...
  }
end
```

- [ ] **Step 4: Run tests, fix until pass**

```bash
mix test test/prosemirror_ex/model/content_match_test.exs
```

This will likely require multiple iterations. The expression parser and NFA→DFA conversion are the trickiest parts.

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/content_match.ex lib/prosemirror_ex/model/node_type.ex test/prosemirror_ex/model/content_match_test.exs
git commit -m "Implement ContentMatch expression engine (tokenizer, parser, NFA->DFA compiler)"
```

---

## Chunk 5: Schema System

### Task 10: Schema, NodeType, MarkType Full Implementation

**Files:**
- Modify: `lib/prosemirror_ex/model/node_type.ex`
- Modify: `lib/prosemirror_ex/model/mark_type.ex`
- Create: `lib/prosemirror_ex/model/schema.ex`
- Create: `test/prosemirror_ex/model/schema_test.exs`

Reference JS (`src/schema.ts`): Schema construction is a multi-step process:
1. Create NodeType and MarkType instances from spec
2. Resolve groups
3. Compile content expressions
4. Resolve mark sets
5. Compute attribute defaults and validators
6. Find linebreak replacement

Key functions to port from schema.ts:
- `initAttrs`, `defaultAttrs`, `computeAttrs`, `checkAttrs`
- `NodeType.create`, `createChecked`, `createAndFill`
- `NodeType.validContent`, `checkContent`
- `NodeType.allowsMarkType`, `allowsMarks`, `allowedMarks`
- `MarkType.create`, `removeFromSet`, `isInSet`, `excludes`
- `Schema` constructor (the big wiring function)

- [ ] **Step 1: Implement Schema module**

```elixir
defmodule ProsemirrorEx.Model.Schema do
  defstruct [:spec, :nodes, :marks, :top_node_type, :linebreak_replacement, :cached]

  def new(spec) do
    # 1. Create NodeType instances
    # 2. Create MarkType instances
    # 3. Compile content expressions
    # 4. Resolve mark sets
    # 5. Set up attribute handling
    # 6. Find linebreak replacement
    ...
  end

  def node(schema, type, attrs \\ nil, content \\ nil, marks \\ nil) do ...end
  def text(schema, text, marks \\ nil) do ...end
  def mark(schema, type, attrs \\ nil) do ...end
  def node_type(schema, name) do ...end
  def node_from_json(schema, json) do ...end
  def mark_from_json(schema, json) do ...end
end
```

- [ ] **Step 2: Complete NodeType with all methods**

Port from schema.ts: `create`, `createChecked`, `createAndFill`, `validContent`, `checkContent`, `allowsMarkType`, `allowsMarks`, `allowedMarks`, `hasRequiredAttrs`, `compatibleContent`, `whitespace`.

- [ ] **Step 3: Complete MarkType with all methods**

Port: `create`, `removeFromSet`, `isInSet`, `excludes`, `checkAttrs`.

- [ ] **Step 4: Create test schema helper**

Create a test helper module that defines the standard test schema matching the JS test suite:

```elixir
# test/support/test_schema.exs  (or test/prosemirror_ex/model/test_helpers.ex)
defmodule ProsemirrorEx.TestHelpers do
  alias ProsemirrorEx.Model.Schema

  def test_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"horizontal_rule", %{"group" => "block"}},
        {"heading", %{"content" => "inline*", "group" => "block",
                       "attrs" => %{"level" => %{"default" => 1,
                                                  "validate" => "number"}}}},
        {"code_block", %{"content" => "text*", "group" => "block", "code" => true}},
        {"text", %{"group" => "inline"}},
        {"image", %{"group" => "inline", "inline" => true,
                    "attrs" => %{"src" => %{},
                                 "alt" => %{"default" => nil},
                                 "title" => %{"default" => nil}}}},
        {"hard_break", %{"group" => "inline", "inline" => true}},
        {"ordered_list", %{"content" => "list_item+", "group" => "block",
                           "attrs" => %{"order" => %{"default" => 1}}}},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"list_item", %{"content" => "paragraph block*"}}
      ],
      "marks" => [
        {"link", %{"attrs" => %{"href" => %{}, "title" => %{"default" => nil}},
                   "inclusive" => false}},
        {"em", %{}},
        {"strong", %{}},
        {"code", %{}}
      ]
    })
  end

  # Builder functions
  def doc(schema \\ test_schema(), children) do
    Schema.node(schema, "doc", nil, children)
  end

  def p(schema \\ test_schema(), children) do
    Schema.node(schema, "paragraph", nil, children)
  end

  # ... more builders (blockquote, h1, h2, hr, br, img, ul, ol, li, pre)
  # ... mark builders (em, strong, code, a)
end
```

- [ ] **Step 5: Write Schema tests**

Test schema construction, node creation, mark creation, content validation. Port relevant tests from test-node.ts that require Schema (check, fromJSON).

- [ ] **Step 6: Run full test suite**

```bash
mix test
```

- [ ] **Step 7: Commit**

```bash
git add lib/prosemirror_ex/model/schema.ex lib/prosemirror_ex/model/node_type.ex lib/prosemirror_ex/model/mark_type.ex test/
git commit -m "Implement Schema, NodeType, MarkType with content expression compilation"
```

---

### Task 11: Test Helpers and Builder System

**Files:**
- Create: `test/support/test_helpers.ex`
- Create: `test/support/builders.ex`

Port the prosemirror-test-builder system to Elixir. This provides `doc()`, `p()`, `em()`, etc. builder functions with tag support (`<a>`, `<b>` position markers).

- [ ] **Step 1: Implement builder system**

The builder needs to:
1. Accept children as strings (with `<tag>` markers), nodes, or mark-wrapped content
2. Track tag positions through nesting
3. Create nodes with correct types and attrs

- [ ] **Step 2: Wire up mark builders**

Mark builders wrap children with marks, returning `{flat: nodes, tag: tags}`.

- [ ] **Step 3: Implement the `eq` helper**

```elixir
def eq(a, b), do: ProsemirrorEx.Model.Node.eq(a, b)
```

- [ ] **Step 4: Run existing tests using new builders, verify they still pass**

- [ ] **Step 5: Commit**

```bash
git add test/support/
git commit -m "Add test builder system with tag support (doc, p, em, etc.)"
```

---

### Task 12: Complete Mark and Node with Schema-dependent operations

**Files:**
- Modify: `lib/prosemirror_ex/model/mark.ex` (add from_json)
- Modify: `lib/prosemirror_ex/model/node.ex` (add from_json, check, can_replace*, content_match_at)
- Modify: `lib/prosemirror_ex/model/fragment.ex` (add from_json)
- Add tests for all these operations

- [ ] **Step 1: Implement Mark.from_json**

```elixir
def from_json(schema, json) do
  if !json, do: raise("Invalid input for Mark.fromJSON")
  type = schema.marks[json["type"]]
  if !type, do: raise("There is no mark type #{json["type"]} in this schema")
  mark = MarkType.create(type, json["attrs"])
  # validate attrs
  mark
end
```

- [ ] **Step 2: Implement Node.from_json**

```elixir
def from_json(schema, json) do
  if !json, do: raise("Invalid input for Node.fromJSON")
  marks = if json["marks"] do
    Enum.map(json["marks"], &Mark.from_json(schema, &1))
  end
  if json["type"] == "text" do
    Schema.text(schema, json["text"], marks)
  else
    content = Fragment.from_json(schema, json["content"])
    Schema.node_type(schema, json["type"]) |> NodeType.create(json["attrs"], content, marks)
  end
end
```

- [ ] **Step 3: Implement Fragment.from_json**

```elixir
def from_json(_schema, nil), do: empty()
def from_json(schema, value) when is_list(value) do
  from_array(Enum.map(value, &PMNode.from_json(schema, &1)))
end
```

- [ ] **Step 4: Implement Node.check, can_replace, can_replace_with, can_append, content_match_at**

Port from node.ts. These all depend on Schema/NodeType/ContentMatch being available.

- [ ] **Step 5: Port remaining tests from test-node.ts (check, fromJSON, toJSON round-trip)**

- [ ] **Step 6: Run full test suite**

- [ ] **Step 7: Commit**

```bash
git add lib/ test/
git commit -m "Complete Mark, Node, Fragment with JSON serialization and schema validation"
```

---

## Chunk 6: ResolvedPos + Slice + Replace

### Task 13: ResolvedPos and NodeRange

**Files:**
- Create: `lib/prosemirror_ex/model/resolved_pos.ex`
- Create: `lib/prosemirror_ex/model/node_range.ex`
- Create: `test/prosemirror_ex/model/resolved_pos_test.exs`

Reference JS (`src/resolvedpos.ts`): ResolvedPos stores a flat `path` array of `[node, index, offset, ...]` triples, representing the path from root to the resolved position. Methods derive context from this path.

Key implementation:
- `resolve(doc, pos)` — walk the document tree to build path
- `node(depth)`, `index(depth)`, `start(depth)`, `end(depth)` — read from path
- `parent`, `doc`, `text_offset`, `node_after`, `node_before` — derived properties
- `marks()` — compute marks at position respecting inclusive/exclusive
- `marks_across($end)` — marks preserved across a deletion
- `shared_depth(pos)` — common ancestor depth
- `block_range(other, pred)` — find NodeRange

- [ ] **Step 1: Implement ResolvedPos**

Port the `resolve` static method and all instance methods from resolvedpos.ts.

- [ ] **Step 2: Implement NodeRange**

Simple struct with computed properties (`start`, `end_pos`, `parent`, `start_index`, `end_index`).

- [ ] **Step 3: Wire Node.resolve to ResolvedPos**

```elixir
# In Node module
def resolve(%__MODULE__{} = doc, pos) do
  ResolvedPos.resolve(doc, pos)
end
```

- [ ] **Step 4: Port tests from test-resolve.ts**

Port all tests including the position table test and posAtIndex test.

- [ ] **Step 5: Port mark position tests from test-mark.ts (ResolvedPos.marks section)**

- [ ] **Step 6: Run tests, fix until pass**

- [ ] **Step 7: Commit**

```bash
git add lib/prosemirror_ex/model/resolved_pos.ex lib/prosemirror_ex/model/node_range.ex test/
git commit -m "Implement ResolvedPos and NodeRange with position resolution"
```

---

### Task 14: Slice

**Files:**
- Create: `lib/prosemirror_ex/model/slice.ex`
- Create: `test/prosemirror_ex/model/slice_test.exs`

Reference JS (`src/replace.ts` Slice class): Slice has `content`, `openStart`, `openEnd`. Methods: `size`, `eq`, `toJSON`, `fromJSON`, `maxOpen`, `insertAt`, `removeBetween`.

- [ ] **Step 1: Implement Slice**

```elixir
defmodule ProsemirrorEx.Model.Slice do
  defstruct [:content, :open_start, :open_end]

  def empty, do: %__MODULE__{content: Fragment.empty(), open_start: 0, open_end: 0}

  def size(%__MODULE__{content: content, open_start: os, open_end: oe}) do
    content.size - os - oe
  end

  def eq(a, b) do
    Fragment.eq(a.content, b.content) and a.open_start == b.open_start and a.open_end == b.open_end
  end

  def max_open(%Fragment{} = fragment, open_isolating \\ true) do
    open_start = compute_open(fragment, :start, open_isolating)
    open_end = compute_open(fragment, :end, open_isolating)
    %__MODULE__{content: fragment, open_start: open_start, open_end: open_end}
  end

  def to_json(%__MODULE__{content: content, open_start: os, open_end: oe}) do
    ...
  end

  def from_json(schema, json) do
    ...
  end
end
```

- [ ] **Step 2: Wire Node.slice**

```elixir
# In Node module
def slice(%__MODULE__{} = node, from, to \\ nil, include_parents \\ false) do
  ...
end
```

- [ ] **Step 3: Port tests from test-slice.ts**

Port all slice tests including openStart/openEnd verification and includeParents.

- [ ] **Step 4: Run tests, fix until pass**

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/slice.ex test/prosemirror_ex/model/slice_test.exs
git commit -m "Implement Slice with maxOpen, toJSON, fromJSON"
```

---

### Task 15: Replace Algorithm

**Files:**
- Create: `lib/prosemirror_ex/model/replace.ex`
- Create: `test/prosemirror_ex/model/replace_test.exs`

Reference JS (`src/replace.ts` replace function): The replace algorithm handles replacing a range in a document with a slice. It's ~150 lines of complex tree manipulation.

Key logic:
1. Find the deepest common ancestor
2. Replace content at the appropriate depth
3. Handle open sides of the slice (joining nodes)
4. Validate the result

- [ ] **Step 1: Implement Replace module**

Port the `replace()` function and helper functions (`replaceOuter`, `replaceThreeWay`, `close`, `addNode`, `addRange`) from replace.ts.

- [ ] **Step 2: Wire Node.replace**

```elixir
def replace(%__MODULE__{} = doc, from, to, slice) do
  from_pos = resolve(doc, from)
  to_pos = resolve(doc, to)
  ProsemirrorEx.Model.Replace.replace(from_pos, to_pos, slice)
end
```

- [ ] **Step 3: Port tests from test-replace.ts**

Port all replace tests including join, merge, split, lopsided, multi-level, and error cases.

- [ ] **Step 4: Run tests, fix until pass**

This will be the most challenging test suite to get passing.

- [ ] **Step 5: Commit**

```bash
git add lib/prosemirror_ex/model/replace.ex test/prosemirror_ex/model/replace_test.exs
git commit -m "Implement Replace algorithm for document tree manipulation"
```

---

## Chunk 7: Integration, Protocols, and Final Tests

### Task 16: JSON Fixtures and Round-Trip Tests

**Files:**
- Create: `test/fixtures/` directory with JSON fixtures
- Create: `test/prosemirror_ex/model/json_round_trip_test.exs`
- Create: `test/prosemirror_ex/model/integration_test.exs`

- [ ] **Step 1: Generate JSON fixtures from JS library**

Create a small Node.js script that generates test fixtures:

```javascript
// test/fixtures/generate.mjs
import {Schema} from "prosemirror-model"
// Create various documents and serialize them
// Save to JSON files
```

Or manually create fixture files based on the test schema.

- [ ] **Step 2: Write round-trip tests**

```elixir
defmodule ProsemirrorEx.Model.JsonRoundTripTest do
  use ExUnit.Case, async: true

  @fixtures_dir Path.join(__DIR__, "../../../test/fixtures")

  for file <- Path.wildcard(Path.join(@fixtures_dir, "*.json")) do
    fixture_name = Path.basename(file, ".json")

    test "round-trips #{fixture_name}" do
      json = File.read!(unquote(file)) |> Jason.decode!()
      schema = ProsemirrorEx.TestHelpers.test_schema()
      node = ProsemirrorEx.Model.Node.from_json(schema, json)
      assert ProsemirrorEx.Model.Node.to_json(node) == json
    end
  end
end
```

- [ ] **Step 3: Write integration tests**

Test end-to-end workflows: schema → build → slice → replace → resolve.

- [ ] **Step 4: Run ALL tests**

```bash
mix test
```

Fix any remaining failures until 100% pass rate.

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "Add JSON round-trip fixtures and integration tests"
```

---

### Task 17: Protocols (Inspect, String.Chars, Jason.Encoder)

**Files:**
- Modify: `lib/prosemirror_ex/model/node.ex`
- Modify: `lib/prosemirror_ex/model/fragment.ex`
- Modify: `lib/prosemirror_ex/model/mark.ex`
- Modify: `lib/prosemirror_ex/model/slice.ex`
- Modify: `lib/prosemirror_ex/model/resolved_pos.ex`

- [ ] **Step 1: Implement Inspect protocol for all types**

```elixir
defimpl Inspect, for: ProsemirrorEx.Model.Node do
  def inspect(node, _opts) do
    ProsemirrorEx.Model.Node.to_string(node)
  end
end
```

- [ ] **Step 2: Implement String.Chars for Node**

```elixir
defimpl String.Chars, for: ProsemirrorEx.Model.Node do
  def to_string(node) do
    ProsemirrorEx.Model.Node.to_string(node)
  end
end
```

- [ ] **Step 3: Implement Jason.Encoder for Node, Fragment, Mark, Slice**

```elixir
defimpl Jason.Encoder, for: ProsemirrorEx.Model.Node do
  def encode(node, opts) do
    node |> ProsemirrorEx.Model.Node.to_json() |> Jason.Encoder.Map.encode(opts)
  end
end
```

- [ ] **Step 4: Run full test suite**

```bash
mix test
```

- [ ] **Step 5: Commit**

```bash
git add lib/
git commit -m "Implement Inspect, String.Chars, and Jason.Encoder protocols"
```

---

### Task 18: Final Verification and Cleanup

- [ ] **Step 1: Run full test suite with verbose output**

```bash
mix test --trace
```

- [ ] **Step 2: Check for any TODO/stub functions**

```bash
grep -r "not yet implemented\|TODO\|FIXME" lib/
```

- [ ] **Step 3: Run formatter**

```bash
mix format
```

- [ ] **Step 4: Run dialyzer (if configured)**

```bash
mix dialyzer
```

- [ ] **Step 5: Final commit**

```bash
git add -A && git commit -m "Final cleanup: formatting, remove TODOs, all tests passing"
```
