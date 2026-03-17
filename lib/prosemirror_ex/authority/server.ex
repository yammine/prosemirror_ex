defmodule ProsemirrorEx.Authority.Server do
  @moduledoc """
  GenServer wrapper around `ProsemirrorEx.Authority`.

  Handles JSON serialization/deserialization at the boundary so callers
  work with plain maps. Suitable for integration with Phoenix channels,
  LiveView, or any Elixir web framework.

  ## Usage

      {:ok, pid} = Authority.Server.start_link(schema: schema, doc: doc_node)

      # Receive steps from a client (steps as JSON maps)
      {:ok, new_version} = Authority.Server.receive_steps(pid, "client1", 0, [step_json])

      # Get the current document as JSON
      {doc_json, version} = Authority.Server.get_doc(pid)

      # Get step history since a version
      {:ok, steps_json, client_ids} = Authority.Server.steps_since(pid, 0)
  """

  use GenServer

  alias ProsemirrorEx.Authority
  alias ProsemirrorEx.Model.Node
  alias ProsemirrorEx.Transform.Step

  @doc """
  Start a linked Authority.Server process.

  ## Options

  - `:schema` (required) - the ProseMirror schema
  - `:doc` (optional) - initial document node
  - `:name` (optional) - process name for registration
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit steps from a client.

  `steps_json` is a list of step JSON maps (as would arrive from a client).
  Steps are deserialized, validated, and applied.

  Returns `{:ok, new_version}` on success, or `{:error, reason}` / `{:error, reason, message}`.
  """
  def receive_steps(server, client_id, version, steps_json) do
    GenServer.call(server, {:receive_steps, client_id, version, steps_json})
  end

  @doc """
  Get the current document as JSON and the current version.

  Returns `{doc_json, version}`.
  """
  def get_doc(server) do
    GenServer.call(server, :get_doc)
  end

  @doc """
  Get all steps since the given version as JSON maps.

  Returns `{:ok, steps_json, client_ids}` or `{:error, reason}`.
  """
  def steps_since(server, version) do
    GenServer.call(server, {:steps_since, version})
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    schema = Keyword.fetch!(opts, :schema)
    doc = Keyword.get(opts, :doc)
    {:ok, Authority.new(schema, doc)}
  end

  @impl true
  def handle_call({:receive_steps, client_id, version, steps_json}, _from, auth) do
    with {:ok, steps} <- deserialize_steps(auth.schema, steps_json),
         {:ok, new_auth} <- Authority.receive_steps(auth, client_id, version, steps) do
      {:reply, {:ok, new_auth.version}, new_auth}
    else
      {:error, reason} -> {:reply, {:error, reason}, auth}
      {:error, reason, msg} -> {:reply, {:error, reason, msg}, auth}
    end
  end

  def handle_call(:get_doc, _from, auth) do
    {:reply, {Node.to_json(auth.doc), auth.version}, auth}
  end

  def handle_call({:steps_since, version}, _from, auth) do
    case Authority.steps_since(auth, version) do
      {:ok, steps, client_ids} ->
        steps_json = Enum.map(steps, fn s -> s.__struct__.to_json(s) end)
        {:reply, {:ok, steps_json, client_ids}, auth}

      error ->
        {:reply, error, auth}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp deserialize_steps(schema, steps_json) do
    try do
      steps = Enum.map(steps_json, &Step.from_json(schema, &1))
      {:ok, steps}
    rescue
      e -> {:error, :invalid_step, Exception.message(e)}
    end
  end
end
