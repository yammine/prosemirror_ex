defmodule CollabDemoWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {CollabDemoWeb.Layouts, :root}
  end

  scope "/", CollabDemoWeb do
    pipe_through :browser
    get "/", PageController, :index
  end
end
