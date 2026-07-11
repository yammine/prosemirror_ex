defmodule ProsemirrorEx.Authority.Server do
  @moduledoc """
  GenServer wrapper around `ProsemirrorEx.Authority`.

  Handles JSON serialization/deserialization at the boundary so callers
  work with plain maps. Suitable for integration with Phoenix channels,
  LiveView, or any Elixir web framework.

  Supports process subscriptions for new-step notifications (the Elixir
  equivalent of the guide's `onNewSteps` callbacks / the collab demo's
  waiting clients).

  ## Usage

      {:ok, pid} = Authority.Server.start_link(schema: schema, doc: doc_node)

      # Optionally subscribe this process to updates
      :ok = Authority.Server.subscribe(pid)

      # Receive steps from a client (steps as JSON maps)
      {:ok, new_version} = Authority.Server.receive_steps(pid, "client1", 0, [step_json])

      # Subscribers receive:
      # {:authority_update, %{version: v, steps: steps_json, client_ids: ids}}

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
  - `:max_history` (optional) - max retained steps (see `Authority.new/3`)
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

  On success, subscribed processes are notified with
  `{:authority_update, %{version, steps, client_ids}}`.

  Returns `{:ok, new_version}` on success, or `{:error, reason}` /
  `{:error, reason, message}`.
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
  Get the current authority version.
  """
  def get_version(server) do
    GenServer.call(server, :get_version)
  end

  @doc """
  Get all steps since the given version as JSON maps.

  Returns `{:ok, steps_json, client_ids}` or `{:error, reason}`
  (`:invalid_version` or `:history_unavailable`).
  """
  def steps_since(server, version) do
    GenServer.call(server, {:steps_since, version})
  end

  @doc """
  Subscribe the calling process to authority updates.

  The subscriber receives `{:authority_update, payload}` messages whenever
  new steps are accepted. The subscription is removed automatically when the
  subscriber exits.
  """
  def subscribe(server, subscriber \\ self()) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @doc """
  Unsubscribe a process from authority updates.
  """
  def unsubscribe(server, subscriber \\ self()) do
    GenServer.call(server, {:unsubscribe, subscriber})
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    schema = Keyword.fetch!(opts, :schema)
    doc = Keyword.get(opts, :doc)
    auth_opts = Keyword.take(opts, [:max_history])

    {:ok,
     %{
       auth: Authority.new(schema, doc, auth_opts),
       subscribers: %{}
     }}
  end

  @impl true
  def handle_call({:receive_steps, client_id, version, steps_json}, _from, state) do
    with {:ok, steps} <- deserialize_steps(state.auth.schema, steps_json),
         {:ok, new_auth} <- Authority.receive_steps(state.auth, client_id, version, steps) do
      steps_json_out = Enum.map(steps, fn s -> s.__struct__.to_json(s) end)
      client_ids = List.duplicate(client_id, length(steps))

      if steps != [] do
        notify_subscribers(state.subscribers, %{
          version: new_auth.version,
          steps: steps_json_out,
          client_ids: client_ids
        })
      end

      {:reply, {:ok, new_auth.version}, %{state | auth: new_auth}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, msg} -> {:reply, {:error, reason, msg}, state}
    end
  end

  def handle_call(:get_doc, _from, state) do
    {:reply, {Node.to_json(state.auth.doc), state.auth.version}, state}
  end

  def handle_call(:get_version, _from, state) do
    {:reply, state.auth.version, state}
  end

  def handle_call({:steps_since, version}, _from, state) do
    case Authority.steps_since(state.auth, version) do
      {:ok, steps, client_ids} ->
        steps_json = Enum.map(steps, fn s -> s.__struct__.to_json(s) end)
        {:reply, {:ok, steps_json, client_ids}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, _ref} ->
        # Idempotent: already subscribed — do not create another monitor.
        {:reply, :ok, state}

      :error ->
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp notify_subscribers(subscribers, payload) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:authority_update, payload})
    end)
  end

  defp deserialize_steps(schema, steps_json) do
    try do
      steps = Enum.map(steps_json, &Step.from_json(schema, &1))
      {:ok, steps}
    rescue
      e -> {:error, :invalid_step, Exception.message(e)}
    end
  end
end
