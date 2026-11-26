defmodule ProsemirrorEx.Authority.Server do
  @moduledoc """
  GenServer wrapper around `ProsemirrorEx.Authority`.

  Handles JSON serialization/deserialization at the boundary so callers
  work with plain maps. Suitable for integration with Phoenix channels,
  LiveView, or any Elixir web framework.

  Supports process subscriptions for new-step notifications (the Elixir
  equivalent of the guide's `onNewSteps` callbacks / the collab demo's
  waiting clients).

  ## Supervision

  `child_spec/1` derives the child `:id` from `:id`, then `:name`, falling back
  to `ProsemirrorEx.Authority.Server`, so multiple named document servers can
  be supervised under the same supervisor without manual `Supervisor.child_spec/2`.

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
  Build a child specification for supervising an `Authority.Server`.

  Uses `:id`, then `:name`, then `__MODULE__` as the child `:id`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id) || Keyword.get(opts, :name) || __MODULE__

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Start a linked Authority.Server process.

  ## Options

  - `:schema` (required) - the ProseMirror schema
  - `:doc` (optional) - initial document `%Node{}` or JSON map
  - `:doc_json` (optional) - initial document as a JSON map (mutually exclusive with `:doc`)
  - `:version` (optional) - initial non-negative integer version (default `0`)
  - `:max_history` (optional) - max retained steps (see `Authority.new/3`)
  - `:name` (optional) - process name for registration
  - `:id` (optional) - child spec ID when supervised
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Submit steps from a client.

  `steps_json` is a list of step JSON maps (as would arrive from a client).
  Version and batch size are validated before deserializing steps; valid steps
  are then deserialized and applied.

  On success, subscribed processes are notified with
  `{:authority_update, %{version, steps, client_ids}}`.

  Returns `{:ok, new_version}` on success, or `{:error, reason}` /
  `{:error, reason, message}`.
  """
  @spec receive_steps(GenServer.server(), term(), integer(), [map()]) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_version | :version_mismatch | :batch_too_large}
          | {:error, :invalid_step | :step_failed, String.t()}
  def receive_steps(server, client_id, version, steps_json) do
    GenServer.call(server, {:receive_steps, client_id, version, steps_json})
  end

  @doc """
  Get the current document as JSON and the current version.

  Returns `{doc_json, version}`.
  """
  @spec get_doc(GenServer.server()) :: {map(), non_neg_integer()}
  def get_doc(server) do
    GenServer.call(server, :get_doc)
  end

  @doc """
  Get the current authority version.
  """
  @spec get_version(GenServer.server()) :: non_neg_integer()
  def get_version(server) do
    GenServer.call(server, :get_version)
  end

  @doc """
  Get the oldest version still available in step history.
  """
  @spec first_version(GenServer.server()) :: non_neg_integer()
  def first_version(server) do
    GenServer.call(server, :first_version)
  end

  @doc """
  Get all steps since the given version as JSON maps.

  Returns `{:ok, steps_json, client_ids}` or `{:error, reason}`
  (`:invalid_version` or `:history_unavailable`).
  """
  @spec steps_since(GenServer.server(), integer()) ::
          {:ok, [map()], [term()]} | {:error, :invalid_version | :history_unavailable}
  def steps_since(server, version) do
    GenServer.call(server, {:steps_since, version})
  end

  @doc """
  Subscribe the calling (or given) process to authority updates.

  The subscriber receives `{:authority_update, payload}` messages whenever
  new steps are accepted. The subscription is removed automatically when the
  subscriber exits. Returns `{:error, :invalid_subscriber}` if `subscriber`
  is not a PID.
  """
  @spec subscribe(GenServer.server(), pid() | term()) :: :ok | {:error, :invalid_subscriber}
  def subscribe(server, subscriber \\ self()) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @doc """
  Unsubscribe a process from authority updates.
  """
  @spec unsubscribe(GenServer.server(), pid() | term()) :: :ok
  def unsubscribe(server, subscriber \\ self()) do
    GenServer.call(server, {:unsubscribe, subscriber})
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    schema = Keyword.fetch!(opts, :schema)
    doc = resolve_initial_doc(schema, opts)
    auth_opts = Keyword.take(opts, [:max_history, :version])

    {:ok,
     %{
       auth: Authority.new(schema, doc, auth_opts),
       subscribers: %{}
     }}
  end

  @impl true
  def handle_call({:receive_steps, client_id, version, steps_json}, _from, state) do
    with :ok <- validate_receive_args(state.auth, version, steps_json),
         {:ok, steps} <- deserialize_steps(state.auth.schema, steps_json),
         {:ok, new_auth} <- Authority.receive_steps(state.auth, client_id, version, steps) do
      if steps != [] and map_size(state.subscribers) > 0 do
        steps_json_out = Enum.map(steps, fn s -> s.__struct__.to_json(s) end)
        client_ids = List.duplicate(client_id, length(steps))

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

  def handle_call(:first_version, _from, state) do
    {:reply, Authority.first_version(state.auth), state}
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

  def handle_call({:subscribe, _non_pid}, _from, state) do
    {:reply, {:error, :invalid_subscriber}, state}
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

  defp resolve_initial_doc(schema, opts) do
    doc_opt = Keyword.get(opts, :doc)
    doc_json_opt = Keyword.get(opts, :doc_json)

    cond do
      doc_opt != nil and doc_json_opt != nil ->
        raise ArgumentError, "Pass either :doc or :doc_json, not both"

      doc_json_opt != nil ->
        Node.from_json(schema, doc_json_opt)

      is_map(doc_opt) and not is_struct(doc_opt) ->
        Node.from_json(schema, doc_opt)

      true ->
        doc_opt
    end
  end

  defp validate_receive_args(auth, version, steps_json) do
    cond do
      not is_integer(version) ->
        {:error, :invalid_version}

      version != auth.version ->
        {:error, :version_mismatch}

      not is_list(steps_json) ->
        {:error, :invalid_step, "steps must be a list"}

      is_integer(auth.max_history) and length(steps_json) > auth.max_history ->
        {:error, :batch_too_large}

      true ->
        :ok
    end
  end

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
