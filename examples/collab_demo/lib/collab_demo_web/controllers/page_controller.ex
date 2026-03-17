defmodule CollabDemoWeb.PageController do
  use CollabDemoWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
