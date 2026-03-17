defmodule CollabDemoWeb do
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CollabDemoWeb.Endpoint,
        router: CollabDemoWeb.Router
    end
  end
end
