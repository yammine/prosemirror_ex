# Authority Server Design Spec

## Overview

A collaborative editing authority server module for ProsemirrorEx. Holds the canonical document, receives steps from clients, validates versions, applies steps, and provides step history for client catch-up. Designed for easy integration with Phoenix channels, LiveView, or any Elixir web framework.

Implements the three responsibilities from the [ProseMirror collab guide](https://prosemirror.net/docs/guides/collab/):

1. Track a current document version
2. Accept changes from editors, and when these can be applied, add them to its list of changes
3. Provide a way for editors to receive changes since a given version

## ProseMirror Suite Coverage (what the authority needs)

| Package | Role | Needed by authority? |
|---------|------|----------------------|
| `prosemirror-model` | Document + schema + JSON | **Yes** — ported as `ProsemirrorEx.Model` |
| `prosemirror-transform` | Steps, maps, apply/invert/map | **Yes** — ported as `ProsemirrorEx.Transform` |
| `prosemirror-collab` | Client plugin (`sendableSteps`, `receiveTransaction`) | **No** — client-only; authority is custom server code |
| `prosemirror-state` | EditorState, Transaction, Selection | **No** — client/editor; transforms are enough server-side |
| `prosemirror-view` | DOM editor UI | **No** |
| `prosemirror-commands` / `keymap` / `history` / `inputrules` | Editing UX | **No** |
| `prosemirror-gapcursor` / `dropcursor` / `menu` / `search` | UI helpers | **No** |
| `prosemirror-schema-basic` / `schema-list` / `markdown` | Convenience schemas | **No** — authority accepts any schema |
| `prosemirror-changeset` / `tables` | Optional extensions | **No** for core authority |

Production features from the official collab demo `Instance` that belong in the authority library:

| Feature | Status |
|---------|--------|
| Versioned step log + client IDs | Done |
| `receiveSteps` / `stepsSince` | Done (`receive_steps` / `steps_since`) |
| Apply steps via `step.apply` | Done |
| JSON step boundary | Done (`Authority.Server`) |
| Bounded history (`MAX_STEP_HISTORY`) | Done (`:max_history`) |
| History-too-old error (HTTP 410 in demo) | Done (`:history_unavailable`) |
| New-step notification (`onNewSteps` / waiting clients) | Done (`Authority.Server.subscribe/1`) |
| Comments / presence / persistence / multi-doc registry | App-layer (see collab demo), not library core |

## Architecture

Two layers:
1. **Functional core** (`ProsemirrorEx.Authority`) — pure functions, no process, easy to test
2. **GenServer wrapper** (`ProsemirrorEx.Authority.Server`) — optional process with JSON boundary handling and subscriber notifications

## Data Structure

```elixir
%ProsemirrorEx.Authority{
  schema: Schema.t(),
  doc: Node.t(),
  version: non_neg_integer(),
  steps: [Step.t()],
  step_client_ids: [term()],
  max_history: pos_integer() | nil
}
```

- `version` starts at 0, increments by the number of steps in each accepted batch
- `steps` and `step_client_ids` are parallel lists, appended on each accepted batch
- `step_client_ids` tracks which client sent each step (for broadcast filtering — clients don't need their own steps echoed back)
- When `max_history` is set and exceeded, older steps are dropped. `steps_since` indexes relative to the retained window: `start = length(steps) - (version - since)`, matching the official demo

## Functional Core API — `ProsemirrorEx.Authority`

```elixir
Authority.new(schema, doc \\ nil, opts \\ [])
# Creates authority with schema and optional initial doc.
# If doc is nil, creates a minimal valid doc using schema.top_node_type.create_and_fill().
# opts: [max_history: pos_integer()]

Authority.receive_steps(authority, client_id, client_version, steps)
# steps: list of Step structs (already deserialized)
# Returns {:ok, updated_authority} if client_version == authority.version
#   - Applies all steps sequentially to the doc
#   - If any step fails to apply, returns {:error, :step_failed, message}
#   - Appends steps to history, increments version, trims if max_history set
# Returns {:error, :version_mismatch} if client_version != authority.version
# Empty step lists are a no-op success

Authority.steps_since(authority, version)
# Returns {:ok, steps, client_ids} — the steps from `version` to current
# Returns {:error, :invalid_version} if version > authority.version or version < 0
# Returns {:error, :history_unavailable} if version was trimmed away

Authority.doc(authority)
# Returns the current document

Authority.version(authority)
# Returns the current version

Authority.first_version(authority)
# Oldest version still present in retained history
```

## GenServer Wrapper API — `ProsemirrorEx.Authority.Server`

```elixir
Authority.Server.start_link(opts)
# opts: [schema: schema, doc: doc, max_history: n, name: name]
# Starts a GenServer holding an Authority struct

Authority.Server.receive_steps(server, client_id, version, steps_json)
# steps_json: list of JSON maps (raw from client)
# Deserializes steps via Step.from_json, delegates to Authority.receive_steps
# Notifies subscribers with {:authority_update, %{version, steps, client_ids}}
# Returns {:ok, new_version} | {:error, reason}

Authority.Server.get_doc(server)
# Returns {doc_json, version} — serialized doc + current version

Authority.Server.get_version(server)
# Returns the current version integer

Authority.Server.steps_since(server, version)
# Returns {:ok, steps_json, client_ids} | {:error, reason}
# steps_json: list of step JSON maps (serialized via step.to_json)

Authority.Server.subscribe(server, subscriber \\ self())
# Register for {:authority_update, payload} messages (onNewSteps equivalent)
# Auto-removed on subscriber exit

Authority.Server.unsubscribe(server, subscriber \\ self())
```

The GenServer handles all JSON conversion at the boundary so callers work with plain maps.

## Error Handling

- `receive_steps` with wrong version: `{:error, :version_mismatch}` — client should fetch steps_since their version, rebase their pending steps, and retry
- `receive_steps` with a batch larger than `max_history`: `{:error, :batch_too_large}` — split the batch or raise the limit so the accepted batch always fits in the retained window
- `receive_steps` with a step that fails to apply: `{:error, :step_failed, message}` — indicates a bug or corrupted step
- `steps_since` with invalid version: `{:error, :invalid_version}`
- `steps_since` with trimmed-away version: `{:error, :history_unavailable}` — client should reload full doc via `get_doc`
- GenServer `receive_steps` with invalid step JSON: `{:error, :invalid_step, message}`

## Testing Strategy

### Unit tests for functional core

- Create authority, verify initial state
- Send steps at correct version — accepted, doc updated, version incremented
- Send steps at stale version — rejected with :version_mismatch
- Send multiple batches sequentially — version accumulates correctly
- steps_since returns correct slice of history
- steps_since with invalid version returns error
- Step that fails to apply returns :step_failed
- max_history trims old steps; steps_since returns :history_unavailable for trimmed versions
- Empty batches are no-ops

### Integration tests for GenServer

- Start server, get initial doc
- Two simulated clients:
  1. Client A sends steps at version 0 — accepted
  2. Client B sends steps at version 0 — rejected (version_mismatch)
  3. Client B fetches steps_since(0), rebases, retries at version N — accepted
  4. Both converge on same document
- Late-joining client fetches full step history
- Multi-step batches (insert + mark in one batch)
- JSON round-trip: steps sent as JSON, doc retrieved as JSON, verified correct
- Subscribers receive authority_update on accepted steps
- max_history surfaces :history_unavailable through the Server API

### Collaboration simulation test

Full scenario with 3+ clients making concurrent edits, verifying:
- All accepted steps produce valid documents
- Version numbers are consistent
- Step history is complete and ordered
- Any client can reconstruct the current doc from initial doc + all steps

## File Structure

```
lib/prosemirror_ex/
├── authority.ex           # Functional core
└── authority/
    └── server.ex          # GenServer wrapper

test/prosemirror_ex/
├── authority_test.exs           # Unit tests for functional core
└── authority/
    └── server_test.exs          # Integration tests for GenServer
```

## Dependencies

Only `ProsemirrorEx.Model` and `ProsemirrorEx.Transform` — no external deps.
