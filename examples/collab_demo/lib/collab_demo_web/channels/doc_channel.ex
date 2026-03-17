defmodule CollabDemoWeb.DocChannel do
  use Phoenix.Channel

  @impl true
  def join("doc:main", _params, socket) do
    {doc_json, version} = CollabDemo.DocServer.get_doc()
    Phoenix.PubSub.subscribe(CollabDemo.PubSub, "collab:doc")
    {:ok, %{"doc" => doc_json, "version" => version}, socket}
  end

  @impl true
  def handle_in("steps", %{"version" => version, "steps" => steps, "clientID" => client_id}, socket) do
    case CollabDemo.DocServer.receive_steps(client_id, version, steps) do
      {:ok, new_version} ->
        {:reply, {:ok, %{"version" => new_version}}, socket}

      {:error, :version_mismatch} ->
        case CollabDemo.DocServer.steps_since(version) do
          {:ok, steps_json, client_ids, current_version} ->
            {:reply,
             {:error,
              %{
                "reason" => "version_mismatch",
                "version" => current_version,
                "steps" => steps_json,
                "clientIDs" => client_ids
              }}, socket}

          _ ->
            {:reply, {:error, %{"reason" => "version_mismatch"}}, socket}
        end
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
