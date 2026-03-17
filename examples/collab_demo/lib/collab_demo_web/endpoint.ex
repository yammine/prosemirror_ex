defmodule CollabDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :collab_demo

  socket "/socket", CollabDemoWeb.UserSocket, websocket: true

  plug Plug.Static,
    at: "/",
    from: :collab_demo,
    gzip: false,
    only: CollabDemoWeb.static_paths()

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session,
    store: :cookie,
    key: "_collab_demo_key",
    signing_salt: "collab_salt"

  plug CollabDemoWeb.Router
end
