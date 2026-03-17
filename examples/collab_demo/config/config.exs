import Config

config :collab_demo, CollabDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: CollabDemoWeb.ErrorHTML], layout: false],
  pubsub_server: CollabDemo.PubSub

config :esbuild,
  version: "0.25.4",
  collab_demo: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
