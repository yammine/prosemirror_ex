defmodule CollabDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: CollabDemo.PubSub},
      CollabDemo.DocServer,
      CollabDemoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CollabDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
