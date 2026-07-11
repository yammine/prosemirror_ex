defmodule ProsemirrorEx.Authority do
  @moduledoc """
  Functional core for a collaborative editing authority server.

  Holds the canonical document, receives steps from clients, validates versions,
  applies steps, and provides step history for client catch-up.

  Implements the three responsibilities from the ProseMirror collaborative
  editing guide:

  1. Track a current document version
  2. Accept changes from editors when they apply, adding them to the change list
  3. Provide a way for editors to receive changes since a given version

  Optionally bounds retained step history (as in the official collab demo's
  `MAX_STEP_HISTORY`) so memory does not grow without bound. When a requested
  version has been trimmed away, `steps_since/2` returns
  `{:error, :history_unavailable}` and the client should fetch a full document
  snapshot via `doc/1` instead.

  This is a pure data structure with no process — use `ProsemirrorEx.Authority.Server`
  for a GenServer wrapper.
  """

  alias ProsemirrorEx.Model.NodeType

  defstruct [:schema, :doc, version: 0, steps: [], step_client_ids: [], max_history: nil]

  @type t :: %__MODULE__{
          schema: term(),
          doc: term(),
          version: non_neg_integer(),
          steps: [term()],
          step_client_ids: [term()],
          max_history: pos_integer() | nil
        }

  @doc """
  Create a new Authority with the given schema and optional initial document.

  If `doc` is nil, creates a minimal valid document using the schema's top node type.

  ## Options

  - `:max_history` — maximum number of steps to retain (default `nil`, unlimited).
    Matches the official ProseMirror collab demo's history window. When exceeded,
    older steps are discarded; clients that are too far behind must reload the
    full document.
  """
  def new(schema, doc \\ nil, opts \\ [])

  def new(schema, doc, opts) when is_list(opts) do
    doc = doc || NodeType.create_and_fill(schema.top_node_type)
    max_history = Keyword.get(opts, :max_history)

    if max_history != nil and (not is_integer(max_history) or max_history < 1) do
      raise ArgumentError, "max_history must be a positive integer or nil"
    end

    %__MODULE__{schema: schema, doc: doc, version: 0, max_history: max_history}
  end

  @doc """
  Receive steps from a client.

  Steps must be pre-deserialized Step structs. The client's version must match
  the authority's current version, otherwise `{:error, :version_mismatch}` is returned.

  Returns:
  - `{:ok, updated_authority}` on success
  - `{:error, :version_mismatch}` if `client_version != authority.version`
  - `{:error, :step_failed, message}` if a step fails to apply
  """
  def receive_steps(%__MODULE__{version: version}, _client_id, client_version, _steps)
      when client_version != version do
    {:error, :version_mismatch}
  end

  def receive_steps(%__MODULE__{} = auth, _client_id, _client_version, []) do
    {:ok, auth}
  end

  def receive_steps(%__MODULE__{} = auth, client_id, _client_version, steps)
      when is_list(steps) do
    case apply_steps(auth.doc, steps) do
      {:ok, new_doc} ->
        new_steps = auth.steps ++ steps
        new_client_ids = auth.step_client_ids ++ List.duplicate(client_id, length(steps))
        {trimmed_steps, trimmed_ids} = trim_history(new_steps, new_client_ids, auth.max_history)

        {:ok,
         %{
           auth
           | doc: new_doc,
             version: auth.version + length(steps),
             steps: trimmed_steps,
             step_client_ids: trimmed_ids
         }}

      {:error, message} ->
        {:error, :step_failed, message}
    end
  end

  @doc """
  Return steps and their client IDs from `since` to the current version.

  Uses the same indexing as the official ProseMirror collab demo: retained steps
  may not start at version 0 when `max_history` has trimmed older entries.

  Returns:
  - `{:ok, steps, client_ids}` on success
  - `{:error, :invalid_version}` if `since` is negative or beyond current version
  - `{:error, :history_unavailable}` if `since` is older than the retained window
  """
  def steps_since(%__MODULE__{version: version}, since) when since < 0 or since > version do
    {:error, :invalid_version}
  end

  def steps_since(%__MODULE__{} = auth, since) do
    first_available = auth.version - length(auth.steps)

    if since < first_available do
      {:error, :history_unavailable}
    else
      drop = since - first_available
      steps = Enum.drop(auth.steps, drop)
      client_ids = Enum.drop(auth.step_client_ids, drop)
      {:ok, steps, client_ids}
    end
  end

  @doc "Return the current document."
  def doc(%__MODULE__{doc: doc}), do: doc

  @doc "Return the current version."
  def version(%__MODULE__{version: version}), do: version

  @doc """
  Return the oldest version still available in step history.

  Equals `version - length(steps)`. When history is empty this equals the
  current version (a fresh authority or one whose history was fully trimmed
  after catch-up is still at a consistent version with a current doc snapshot).
  """
  def first_version(%__MODULE__{version: version, steps: steps}) do
    version - length(steps)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp trim_history(steps, client_ids, nil), do: {steps, client_ids}

  defp trim_history(steps, client_ids, max_history) when length(steps) <= max_history do
    {steps, client_ids}
  end

  defp trim_history(steps, client_ids, max_history) do
    drop = length(steps) - max_history
    {Enum.drop(steps, drop), Enum.drop(client_ids, drop)}
  end

  defp apply_steps(doc, []), do: {:ok, doc}

  defp apply_steps(doc, [step | rest]) do
    try do
      result = step.__struct__.apply(step, doc)

      if result.doc do
        apply_steps(result.doc, rest)
      else
        {:error, result.failed}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
