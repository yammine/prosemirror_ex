# Authority Server Design Spec

## Overview

A collaborative editing authority server module for ProsemirrorEx. Holds the canonical document, receives steps from clients, validates versions, applies steps, and provides step history for client catch-up. Designed for easy integration with Phoenix channels, LiveView, or any Elixir web framework.

## Architecture

Two layers:
1. **Functional core** (`ProsemirrorEx.Authority`) — pure functions, no process, easy to test
2. **GenServer wrapper** (`ProsemirrorEx.Authority.Server`) — optional process with JSON boundary handling

## Data Structure

```elixir
%ProsemirrorEx.Authority{
  schema: Schema.t(),
  doc: Node.t(),
  version: non_neg_integer(),
  steps: [Step.t()],
  step_client_ids: [term()]
}
```

- `version` starts at 0, increments by the number of steps in each accepted batch
- `steps` and `step_client_ids` are parallel lists, appended on each accepted batch
- `step_client_ids` tracks which client sent each step (for broadcast filtering — clients don't need their own steps echoed back)

## Functional Core API — `ProsemirrorEx.Authority`

```elixir
Authority.new(schema, doc \\ nil)
# Creates authority with schema and optional initial doc.
# If doc is nil, creates a minimal valid doc using schema.top_node_type.create_and_fill().

Authority.receive_steps(authority, client_id, client_version, steps)
# steps: list of Step structs (already deserialized)
# Returns {:ok, updated_authority} if client_version == authority.version
#   - Applies all steps sequentially to the doc
#   - If any step fails to apply, returns {:error, :step_failed, message}
#   - Appends steps to history, increments version
# Returns {:error, :version_mismatch} if client_version != authority.version

Authority.steps_since(authority, version)
# Returns {:ok, steps, client_ids} — the steps from `version` to current
# Returns {:error, :invalid_version} if version > authority.version or version < 0

Authority.doc(authority)
# Returns the current document

Authority.version(authority)
# Returns the current version
```

## GenServer Wrapper API — `ProsemirrorEx.Authority.Server`

```elixir
Authority.Server.start_link(opts)
# opts: [schema: schema, doc: doc, name: name]
# Starts a GenServer holding an Authority struct

Authority.Server.receive_steps(server, client_id, version, steps_json)
# steps_json: list of JSON maps (raw from client)
# Deserializes steps via Step.from_json, delegates to Authority.receive_steps
# Returns {:ok, new_version} | {:error, reason}

Authority.Server.get_doc(server)
# Returns {doc_json, version} — serialized doc + current version
# doc_json is the result of Node.to_json(doc)

Authority.Server.steps_since(server, version)
# Returns {:ok, steps_json, client_ids} | {:error, reason}
# steps_json: list of step JSON maps (serialized via step.to_json)
```

The GenServer handles all JSON conversion at the boundary so callers work with plain maps.

## Error Handling

- `receive_steps` with wrong version: `{:error, :version_mismatch}` — client should fetch steps_since their version, rebase their pending steps, and retry
- `receive_steps` with a step that fails to apply: `{:error, :step_failed, message}` — indicates a bug or corrupted step
- `steps_since` with invalid version: `{:error, :invalid_version}`
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
