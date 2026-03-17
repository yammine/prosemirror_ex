defmodule CollabDemo.DocServer do
  use GenServer

  alias ProsemirrorEx.Model.{Schema, Node}
  alias ProsemirrorEx.Authority

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get_doc, do: GenServer.call(__MODULE__, :get_doc)

  def receive_steps(client_id, version, steps_json),
    do: GenServer.call(__MODULE__, {:receive_steps, client_id, version, steps_json})

  def steps_since(version), do: GenServer.call(__MODULE__, {:steps_since, version})

  @impl true
  def init(:ok) do
    ProsemirrorEx.Transform.StepRegistry.ensure_registered()
    schema = build_schema()

    doc =
      Schema.node(schema, "doc", nil, [
        Schema.node(schema, "heading", %{"level" => 1}, [
          Schema.text(schema, "Collaborative Editing Demo")
        ]),
        Schema.node(schema, "paragraph", nil, [
          Schema.text(schema, "Type in either editor — changes sync in real time.")
        ])
      ])

    {:ok, %{auth: Authority.new(schema, doc), schema: schema}}
  end

  @impl true
  def handle_call(:get_doc, _from, state) do
    {:reply, {Node.to_json(state.auth.doc), state.auth.version}, state}
  end

  def handle_call({:receive_steps, client_id, version, steps_json}, _from, state) do
    steps =
      Enum.map(steps_json, &ProsemirrorEx.Transform.Step.from_json(state.schema, &1))

    case Authority.receive_steps(state.auth, client_id, version, steps) do
      {:ok, new_auth} ->
        {:ok, new_steps, client_ids} = Authority.steps_since(new_auth, version)
        steps_out = Enum.map(new_steps, &(&1.__struct__.to_json(&1)))

        Phoenix.PubSub.broadcast(
          CollabDemo.PubSub,
          "collab:doc",
          {:new_steps,
           %{version: new_auth.version, steps: steps_out, client_ids: client_ids}}
        )

        {:reply, {:ok, new_auth.version}, %{state | auth: new_auth}}

      {:error, :version_mismatch} ->
        {:reply, {:error, :version_mismatch}, state}
    end
  end

  def handle_call({:steps_since, version}, _from, state) do
    case Authority.steps_since(state.auth, version) do
      {:ok, steps, client_ids} ->
        {:reply,
         {:ok, Enum.map(steps, &(&1.__struct__.to_json(&1))), client_ids, state.auth.version},
         state}

      error ->
        {:reply, error, state}
    end
  end

  defp build_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"heading",
         %{
           "content" => "inline*",
           "group" => "block",
           "attrs" => %{"level" => %{"default" => 1}}
         }},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"ordered_list",
         %{
           "content" => "list_item+",
           "group" => "block",
           "attrs" => %{"start" => %{"default" => 1}}
         }},
        {"list_item", %{"content" => "paragraph block*"}},
        {"horizontal_rule", %{"group" => "block"}},
        {"code_block", %{"content" => "text*", "group" => "block", "code" => true}},
        {"hard_break", %{"group" => "inline", "inline" => true}},
        {"text", %{"group" => "inline"}}
      ],
      "marks" => [
        {"bold", %{}},
        {"italic", %{}},
        {"code", %{}},
        {"strike", %{}}
      ]
    })
  end
end
