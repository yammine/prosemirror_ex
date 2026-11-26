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

  alias ProsemirrorEx.Model.{Node, NodeType, Schema}

  defstruct [
    :schema,
    :doc,
    version: 0,
    steps: [],
    step_client_ids: [],
    steps_count: 0,
    max_history: nil
  ]

  @type t :: %__MODULE__{
          schema: Schema.t(),
          doc: Node.t(),
          version: non_neg_integer(),
          steps: [struct()],
          step_client_ids: [term()],
          steps_count: non_neg_integer(),
          max_history: pos_integer() | nil
        }

  @type receive_error ::
          {:error, :invalid_version}
          | {:error, :version_mismatch}
          | {:error, :batch_too_large}
          | {:error, :step_failed, String.t()}

  @doc """
  Create a new Authority with the given schema and optional initial document.

  If `doc` is nil, creates a minimal valid document using the schema's top node type.

  ## Options

  - `:version` — initial non-negative integer version (default `0`), useful when
    restoring an authority from a persisted document snapshot.
  - `:max_history` — maximum number of steps to retain (default `nil`, unlimited).
    Matches the official ProseMirror collab demo's history window. When exceeded,
    older steps are discarded; clients that are too far behind must reload the
    full document. A single `receive_steps` batch may not exceed this limit
    (`{:error, :batch_too_large}`); accepted batches are always retained in full
    so `steps_since/2` from the pre-batch version remains valid.
  """
  @spec new(Schema.t(), Node.t() | nil, keyword()) :: t()
  def new(schema, doc \\ nil, opts \\ [])

  def new(%Schema{} = schema, doc, opts) when is_list(opts) do
    doc =
      case doc do
        nil ->
          created = NodeType.create_and_fill(schema.top_node_type)

          if created == nil do
            raise ArgumentError,
                  "Could not create a valid empty document from schema top node type"
          end

          created

        %Node{} = node ->
          node

        other ->
          raise ArgumentError,
                "doc must be a ProsemirrorEx.Model.Node struct or nil, got: #{inspect(other)}"
      end

    version = Keyword.get(opts, :version, 0)

    if not is_integer(version) or version < 0 do
      raise ArgumentError, "version must be a non-negative integer"
    end

    max_history = Keyword.get(opts, :max_history)

    if max_history != nil and (not is_integer(max_history) or max_history < 1) do
      raise ArgumentError, "max_history must be a positive integer or nil"
    end

    %__MODULE__{
      schema: schema,
      doc: doc,
      version: version,
      steps_count: 0,
      max_history: max_history
    }
  end

  @doc """
  Receive steps from a client.

  Steps must be pre-deserialized Step structs. The client's version must match
  the authority's current version, otherwise `{:error, :version_mismatch}` is returned.

  Returns:
  - `{:ok, updated_authority}` on success
  - `{:error, :invalid_version}` if `client_version` is not an integer
  - `{:error, :version_mismatch}` if `client_version != authority.version`
  - `{:error, :batch_too_large}` if `max_history` is set and the batch is larger
    (a batch must fit in the history window so `steps_since(client_version)`
    still works after accept — needed for broadcast/catch-up)
  - `{:error, :step_failed, message}` if `steps` is not a list or a step fails to apply
  """
  @spec receive_steps(t(), term(), integer(), [struct()]) :: {:ok, t()} | receive_error()
  def receive_steps(%__MODULE__{}, _client_id, client_version, _steps)
      when not is_integer(client_version) do
    {:error, :invalid_version}
  end

  def receive_steps(%__MODULE__{version: version}, _client_id, client_version, _steps)
      when client_version != version do
    {:error, :version_mismatch}
  end

  def receive_steps(%__MODULE__{}, _client_id, _client_version, steps) when not is_list(steps) do
    {:error, :step_failed, "steps must be a list"}
  end

  def receive_steps(%__MODULE__{} = auth, _client_id, _client_version, []) do
    {:ok, auth}
  end

  def receive_steps(
        %__MODULE__{max_history: max_history} = auth,
        client_id,
        _client_version,
        steps
      ) do
    batch_len = length(steps)

    if is_integer(max_history) and batch_len > max_history do
      {:error, :batch_too_large}
    else
      apply_and_append(auth, client_id, steps, batch_len)
    end
  end

  defp apply_and_append(auth, client_id, steps, batch_len) do
    case apply_steps(auth.doc, steps) do
      {:ok, new_doc} ->
        {trimmed_steps, trimmed_ids, final_count} =
          trim_and_append(
            auth.steps,
            auth.step_client_ids,
            auth.steps_count,
            steps,
            client_id,
            batch_len,
            auth.max_history
          )

        {:ok,
         %{
           auth
           | doc: new_doc,
             version: auth.version + batch_len,
             steps: trimmed_steps,
             step_client_ids: trimmed_ids,
             steps_count: final_count
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
  - `{:error, :invalid_version}` if `since` is not an integer, is negative, or is beyond current version
  - `{:error, :history_unavailable}` if `since` is older than the retained window
  """
  @spec steps_since(t(), integer()) ::
          {:ok, [struct()], [term()]} | {:error, :invalid_version | :history_unavailable}
  def steps_since(%__MODULE__{version: version}, since)
      when not is_integer(since) or since < 0 or since > version do
    {:error, :invalid_version}
  end

  def steps_since(%__MODULE__{version: version}, version) do
    {:ok, [], []}
  end

  def steps_since(%__MODULE__{} = auth, since) do
    first_available = auth.version - auth.steps_count

    if since < first_available do
      {:error, :history_unavailable}
    else
      drop = since - first_available
      {:ok, Enum.drop(auth.steps, drop), Enum.drop(auth.step_client_ids, drop)}
    end
  end

  @doc "Return the current document."
  @spec doc(t()) :: Node.t()
  def doc(%__MODULE__{doc: doc}), do: doc

  @doc "Return the current version."
  @spec version(t()) :: non_neg_integer()
  def version(%__MODULE__{version: version}), do: version

  @doc """
  Return the oldest version still available in step history.

  Equals `version - steps_count`. When history is empty this equals the
  current version (a fresh authority, one loaded from a snapshot at `version > 0`,
  or one whose history was trimmed).
  """
  @spec first_version(t()) :: non_neg_integer()
  def first_version(%__MODULE__{version: version, steps_count: steps_count}) do
    version - steps_count
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp trim_and_append(old_steps, old_ids, old_count, new_steps, client_id, batch_len, nil) do
    {
      old_steps ++ new_steps,
      old_ids ++ List.duplicate(client_id, batch_len),
      old_count + batch_len
    }
  end

  defp trim_and_append(
         old_steps,
         old_ids,
         old_count,
         new_steps,
         client_id,
         batch_len,
         max_history
       ) do
    total_count = old_count + batch_len
    keep = max(max_history, batch_len)
    new_ids = List.duplicate(client_id, batch_len)

    if total_count <= keep do
      {old_steps ++ new_steps, old_ids ++ new_ids, total_count}
    else
      drop = total_count - keep

      if drop == old_count do
        {new_steps, new_ids, keep}
      else
        {Enum.drop(old_steps, drop) ++ new_steps, Enum.drop(old_ids, drop) ++ new_ids, keep}
      end
    end
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
