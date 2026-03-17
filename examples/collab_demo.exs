# Collaborative Editing Demo with ProsemirrorEx
#
# Run with: elixir examples/collab_demo.exs
#
# Opens a browser with two side-by-side Tiptap editors sharing a single
# document via Phoenix Channels + ProsemirrorEx.Authority.
#
# Type in one editor and watch changes appear in the other in real-time.

Mix.install([
  {:phoenix_playground, "~> 0.1.4"},
  {:prosemirror_ex, path: "."}
])

# ── Authority GenServer ──────────────────────────────────────────────────

defmodule CollabDemo.DocServer do
  use GenServer

  alias ProsemirrorEx.Model.{Schema, Node}
  alias ProsemirrorEx.Authority

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_doc, do: GenServer.call(__MODULE__, :get_doc)
  def receive_steps(client_id, version, steps_json), do: GenServer.call(__MODULE__, {:receive_steps, client_id, version, steps_json})
  def steps_since(version), do: GenServer.call(__MODULE__, {:steps_since, version})

  @impl true
  def init(:ok) do
    schema = build_schema()

    doc =
      Schema.node(schema, "doc", nil, [
        Schema.node(schema, "heading", %{"level" => 1}, [
          Schema.text(schema, "ProsemirrorEx Collab Demo")
        ]),
        Schema.node(schema, "paragraph", nil, [
          Schema.text(schema, "Start typing in either editor. Changes sync in real-time via Phoenix Channels + ProsemirrorEx.Authority.")
        ]),
        Schema.node(schema, "paragraph", nil, [
          Schema.text(schema, "Try adding "),
          Schema.text(schema, "bold", [Schema.mark(schema, "bold")]),
          Schema.text(schema, " or "),
          Schema.text(schema, "italic", [Schema.mark(schema, "italic")]),
          Schema.text(schema, " text!")
        ])
      ])

    auth = Authority.new(schema, doc)
    {:ok, %{auth: auth, schema: schema, subscribers: []}}
  end

  @impl true
  def handle_call(:get_doc, _from, state) do
    {:reply, {Node.to_json(state.auth.doc), state.auth.version}, state}
  end

  def handle_call({:receive_steps, client_id, version, steps_json}, _from, state) do
    ProsemirrorEx.Transform.StepRegistry.ensure_registered()

    steps =
      Enum.map(steps_json, fn step_json ->
        ProsemirrorEx.Transform.Step.from_json(state.schema, step_json)
      end)

    case Authority.receive_steps(state.auth, client_id, version, steps) do
      {:ok, new_auth} ->
        # Notify subscribers
        new_version = new_auth.version
        {:ok, new_steps, client_ids} = Authority.steps_since(new_auth, version)
        steps_json_out = Enum.map(new_steps, &(&1.__struct__.to_json(&1)))

        Phoenix.PubSub.broadcast(
          PhoenixPlayground.PubSub,
          "collab:doc",
          {:new_steps, %{version: new_version, steps: steps_json_out, client_ids: client_ids}}
        )

        {:reply, {:ok, new_version}, %{state | auth: new_auth}}

      {:error, :version_mismatch} ->
        {:reply, {:error, :version_mismatch}, state}

      {:error, :step_failed, msg} ->
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:steps_since, version}, _from, state) do
    case Authority.steps_since(state.auth, version) do
      {:ok, steps, client_ids} ->
        steps_json = Enum.map(steps, &(&1.__struct__.to_json(&1)))
        {:reply, {:ok, steps_json, client_ids, state.auth.version}, state}

      error ->
        {:reply, error, state}
    end
  end

  defp build_schema do
    Schema.new(%{
      "nodes" => [
        {"doc", %{"content" => "block+"}},
        {"paragraph", %{"content" => "inline*", "group" => "block"}},
        {"heading", %{
          "content" => "inline*",
          "group" => "block",
          "attrs" => %{"level" => %{"default" => 1}}
        }},
        {"blockquote", %{"content" => "block+", "group" => "block"}},
        {"bullet_list", %{"content" => "list_item+", "group" => "block"}},
        {"ordered_list", %{
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
        {"link", %{
          "attrs" => %{
            "href" => %{},
            "target" => %{"default" => nil},
            "rel" => %{"default" => nil},
            "class" => %{"default" => nil}
          }
        }},
        {"strike", %{}}
      ]
    })
  end
end

# ── Phoenix Channel ──────────────────────────────────────────────────────

defmodule CollabDemo.DocChannel do
  use Phoenix.Channel

  @impl true
  def join("doc:main", _params, socket) do
    {doc_json, version} = CollabDemo.DocServer.get_doc()
    Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, "collab:doc")
    {:ok, %{"doc" => doc_json, "version" => version}, socket}
  end

  @impl true
  def handle_in("steps", %{"version" => version, "steps" => steps, "clientID" => client_id}, socket) do
    case CollabDemo.DocServer.receive_steps(client_id, version, steps) do
      {:ok, new_version} ->
        {:reply, {:ok, %{"version" => new_version}}, socket}

      {:error, :version_mismatch} ->
        # Send missed steps so client can rebase
        case CollabDemo.DocServer.steps_since(version) do
          {:ok, steps_json, client_ids, current_version} ->
            {:reply, {:error, %{"reason" => "version_mismatch", "version" => current_version,
                                "steps" => steps_json, "clientIDs" => client_ids}}, socket}
          _ ->
            {:reply, {:error, %{"reason" => "version_mismatch"}}, socket}
        end

      {:error, msg} ->
        {:reply, {:error, %{"reason" => msg}}, socket}
    end
  end

  @impl true
  def handle_info({:new_steps, payload}, socket) do
    push(socket, "steps", %{
      "version" => payload.version,
      "steps" => payload.steps,
      "clientIDs" => payload.client_ids
    })
    {:noreply, socket}
  end
end

defmodule CollabDemo.CollabSocket do
  use Phoenix.Socket

  channel "doc:*", CollabDemo.DocChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end

# ── Phoenix Endpoint ─────────────────────────────────────────────────────

defmodule CollabDemo.ErrorHTML do
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

defmodule CollabDemo.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_playground

  @session_options [
    store: :cookie,
    key: "_collab_key",
    signing_salt: "collab_demo_salt"
  ]

  socket "/collab-ws", CollabDemo.CollabSocket,
    websocket: true,
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: {:phoenix_playground, "priv/static"}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session, @session_options

  plug PhoenixPlayground.Router
end

# ── LiveView ─────────────────────────────────────────────────────────────

defmodule CollabDemo.EditorLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; }

      .container { max-width: 1400px; margin: 0 auto; padding: 24px; }

      .header {
        text-align: center; margin-bottom: 24px;
      }
      .header h1 { font-size: 1.5rem; color: #333; margin-bottom: 4px; }
      .header p { color: #888; font-size: 0.85rem; }

      .editors {
        display: grid; grid-template-columns: 1fr 1fr; gap: 20px;
      }

      .editor-pane {
        background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.12);
        display: flex; flex-direction: column; overflow: hidden;
      }

      .editor-label {
        padding: 10px 16px; background: #fafafa; border-bottom: 1px solid #eee;
        font-size: 0.8rem; font-weight: 600; color: #666;
        display: flex; justify-content: space-between; align-items: center;
      }

      .status { font-weight: 400; font-size: 0.75rem; }
      .status.connected { color: #22c55e; }
      .status.disconnected { color: #ef4444; }

      .toolbar {
        padding: 6px 8px; border-bottom: 1px solid #eee; display: flex;
        gap: 2px; flex-wrap: wrap; background: #fafafa;
      }

      .toolbar button {
        padding: 4px 8px; border: 1px solid #ddd; border-radius: 4px;
        background: white; cursor: pointer; font-size: 0.8rem; color: #555;
        transition: all 0.15s;
      }
      .toolbar button:hover { background: #f0f0f0; border-color: #ccc; }
      .toolbar button.is-active { background: #333; color: white; border-color: #333; }

      .editor-content {
        padding: 16px 20px; min-height: 300px; flex: 1;
      }

      .ProseMirror { outline: none; min-height: 260px; }
      .ProseMirror p { margin-bottom: 0.5em; line-height: 1.6; }
      .ProseMirror h1, .ProseMirror h2, .ProseMirror h3 { margin: 0.5em 0 0.3em; line-height: 1.3; }
      .ProseMirror h1 { font-size: 1.6em; }
      .ProseMirror h2 { font-size: 1.3em; }
      .ProseMirror h3 { font-size: 1.1em; }
      .ProseMirror blockquote { border-left: 3px solid #ddd; padding-left: 12px; margin: 0.5em 0; color: #666; }
      .ProseMirror ul, .ProseMirror ol { padding-left: 24px; margin: 0.5em 0; }
      .ProseMirror code { background: #f0f0f0; padding: 2px 4px; border-radius: 3px; font-size: 0.9em; }
      .ProseMirror pre { background: #282c34; color: #abb2bf; padding: 12px; border-radius: 6px; overflow-x: auto; margin: 0.5em 0; }
      .ProseMirror pre code { background: none; padding: 0; }
      .ProseMirror hr { border: none; border-top: 2px solid #eee; margin: 1em 0; }
      .ProseMirror s { text-decoration: line-through; }

      @media (max-width: 768px) {
        .editors { grid-template-columns: 1fr; }
      }
    </style>

    <div class="container">
      <div class="header">
        <h1>ProsemirrorEx Collab Demo</h1>
        <p>Two independent Tiptap editors sharing a document via Phoenix Channels + ProsemirrorEx.Authority</p>
      </div>
      <div class="editors">
        <div class="editor-pane">
          <div class="editor-label">
            <span>Client A</span>
            <span class="status" id="status-a">connecting...</span>
          </div>
          <div class="toolbar" id="toolbar-a"></div>
          <div class="editor-content" id="editor-a"></div>
        </div>
        <div class="editor-pane">
          <div class="editor-label">
            <span>Client B</span>
            <span class="status" id="status-b">connecting...</span>
          </div>
          <div class="toolbar" id="toolbar-b"></div>
          <div class="editor-content" id="editor-b"></div>
        </div>
      </div>
    </div>

    <!-- Suppress LiveView's default JS (we don't need it) -->
    <script>window.liveSocket = {disconnect(){}, getSocket(){return {conn(){}}}};</script>

    <script type="module">
      // Pin all prosemirror packages to same versions to avoid duplicate instances
      const PM_DEPS = 'prosemirror-state@1.4.3,prosemirror-model@1.25.1,prosemirror-transform@1.10.4,prosemirror-view@1.38.1'
      const { Editor } = await import(`https://esm.sh/@tiptap/core@2.11.5?deps=${PM_DEPS}`)
      const { default: StarterKit } = await import(`https://esm.sh/@tiptap/starter-kit@2.11.5?deps=${PM_DEPS}`)
      const { collab, sendableSteps, receiveTransaction, getVersion } = await import(`https://esm.sh/prosemirror-collab@1.3.1?deps=${PM_DEPS}`)
      const { Step } = await import(`https://esm.sh/prosemirror-transform@1.10.4`)
      const { Socket } = await import('https://esm.sh/phoenix@1.7.18?bundle')

      function createEditor(elementId, toolbarId, statusId, clientID) {
        const statusEl = document.getElementById(statusId)

        // Each editor gets its own socket so both can join the same topic independently
        const socket = new Socket("/collab-ws", {})
        socket.connect()

        const channel = socket.channel("doc:main", {})

        let editor = null
        let serverVersion = 0
        let sending = false

        channel.join()
          .receive("ok", (data) => {
            serverVersion = data.version
            statusEl.textContent = "connected"
            statusEl.className = "status connected"

            editor = new Editor({
              element: document.getElementById(elementId),
              extensions: [
                StarterKit.configure({ history: false }),
                collab({ version: serverVersion, clientID }),
              ],
              content: data.doc,
            })

            // Build toolbar
            buildToolbar(document.getElementById(toolbarId), editor)

            // Watch for local changes
            editor.on('transaction', ({ transaction }) => {
              if (!transaction.docChanged) return
              trySend()
            })
          })
          .receive("error", (err) => {
            statusEl.textContent = "error"
            statusEl.className = "status disconnected"
            console.error("Join error:", err)
          })

        // Receive steps from server
        channel.on("steps", (data) => {
          if (!editor) return
          const state = editor.state
          const currentVersion = getVersion(state)

          // Filter out steps we already have
          if (data.version <= currentVersion) return

          const stepsToApply = data.steps.slice(currentVersion - (data.version - data.steps.length))
          const clientIDs = data.clientIDs.slice(currentVersion - (data.version - data.clientIDs.length))

          if (stepsToApply.length === 0) return

          const steps = stepsToApply.map(j => Step.fromJSON(editor.schema, j))
          const tr = receiveTransaction(state, steps, clientIDs)
          editor.view.dispatch(tr)
        })

        function trySend() {
          if (sending || !editor) return
          const sendable = sendableSteps(editor.state)
          if (!sendable) return

          sending = true
          const stepsJSON = sendable.steps.map(s => s.toJSON())

          channel.push("steps", {
            version: sendable.version,
            steps: stepsJSON,
            clientID: clientID.toString(),
          })
            .receive("ok", (data) => {
              sending = false
              // Try sending more if queued
              setTimeout(trySend, 0)
            })
            .receive("error", (data) => {
              sending = false
              if (data.reason === "version_mismatch" && data.steps) {
                // Apply missed steps and retry
                const state = editor.state
                const steps = data.steps.map(j => Step.fromJSON(editor.schema, j))
                const tr = receiveTransaction(state, steps, data.clientIDs)
                editor.view.dispatch(tr)
                setTimeout(trySend, 100)
              }
            })
        }
      }

      function buildToolbar(container, editor) {
        const buttons = [
          { label: 'B', cmd: () => editor.chain().focus().toggleBold().run(), active: () => editor.isActive('bold') },
          { label: 'I', cmd: () => editor.chain().focus().toggleItalic().run(), active: () => editor.isActive('italic') },
          { label: 'S', cmd: () => editor.chain().focus().toggleStrike().run(), active: () => editor.isActive('strike') },
          { label: '<>', cmd: () => editor.chain().focus().toggleCode().run(), active: () => editor.isActive('code') },
          { label: 'H1', cmd: () => editor.chain().focus().toggleHeading({ level: 1 }).run(), active: () => editor.isActive('heading', { level: 1 }) },
          { label: 'H2', cmd: () => editor.chain().focus().toggleHeading({ level: 2 }).run(), active: () => editor.isActive('heading', { level: 2 }) },
          { label: 'UL', cmd: () => editor.chain().focus().toggleBulletList().run(), active: () => editor.isActive('bulletList') },
          { label: 'OL', cmd: () => editor.chain().focus().toggleOrderedList().run(), active: () => editor.isActive('orderedList') },
          { label: 'BQ', cmd: () => editor.chain().focus().toggleBlockquote().run(), active: () => editor.isActive('blockquote') },
          { label: '---', cmd: () => editor.chain().focus().setHorizontalRule().run(), active: () => false },
        ]

        buttons.forEach(({ label, cmd, active }) => {
          const btn = document.createElement('button')
          btn.textContent = label
          btn.addEventListener('click', cmd)
          container.appendChild(btn)

          editor.on('selectionUpdate', () => {
            btn.classList.toggle('is-active', active())
          })
          editor.on('transaction', () => {
            btn.classList.toggle('is-active', active())
          })
        })
      }

      // Create two independent editors with unique client IDs
      createEditor('editor-a', 'toolbar-a', 'status-a', 'client-' + Math.random().toString(36).slice(2, 8))
      createEditor('editor-b', 'toolbar-b', 'status-b', 'client-' + Math.random().toString(36).slice(2, 8))
    </script>
    """
  end
end

# ── Start ────────────────────────────────────────────────────────────────

Application.put_env(:phoenix_playground, CollabDemo.Endpoint,
  render_errors: [formats: [html: CollabDemo.ErrorHTML], layout: false]
)

PhoenixPlayground.start(
  live: CollabDemo.EditorLive,
  endpoint: CollabDemo.Endpoint,
  child_specs: [CollabDemo.DocServer],
  open_browser: true
)
