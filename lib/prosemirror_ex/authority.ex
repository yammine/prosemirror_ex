defmodule ProsemirrorEx.Authority do
  @moduledoc """
  Functional core for a collaborative editing authority server.

  Holds the canonical document, receives steps from clients, validates versions,
  applies steps, and provides step history for client catch-up.

  This is a pure data structure with no process — use `ProsemirrorEx.Authority.Server`
  for a GenServer wrapper.
  """

  alias ProsemirrorEx.Model.NodeType

  defstruct [:schema, :doc, version: 0, steps: [], step_client_ids: []]

  @doc """
  Create a new Authority with the given schema and optional initial document.

  If `doc` is nil, creates a minimal valid document using the schema's top node type.
  """
  def new(schema, doc \\ nil) do
    doc = doc || NodeType.create_and_fill(schema.top_node_type)
    %__MODULE__{schema: schema, doc: doc, version: 0}
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

  def receive_steps(%__MODULE__{} = auth, client_id, _client_version, steps) do
    case apply_steps(auth.doc, steps) do
      {:ok, new_doc} ->
        {:ok,
         %{
           auth
           | doc: new_doc,
             version: auth.version + length(steps),
             steps: auth.steps ++ steps,
             step_client_ids: auth.step_client_ids ++ List.duplicate(client_id, length(steps))
         }}

      {:error, message} ->
        {:error, :step_failed, message}
    end
  end

  @doc """
  Return steps and their client IDs from `since` to the current version.

  Returns:
  - `{:ok, steps, client_ids}` on success
  - `{:error, :invalid_version}` if `since` is negative or beyond current version
  """
  def steps_since(%__MODULE__{version: version}, since) when since < 0 or since > version do
    {:error, :invalid_version}
  end

  def steps_since(%__MODULE__{} = auth, since) do
    steps = Enum.drop(auth.steps, since)
    client_ids = Enum.drop(auth.step_client_ids, since)
    {:ok, steps, client_ids}
  end

  @doc "Return the current document."
  def doc(%__MODULE__{doc: doc}), do: doc

  @doc "Return the current version."
  def version(%__MODULE__{version: version}), do: version

  # ── Private ──────────────────────────────────────────────────────────

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
