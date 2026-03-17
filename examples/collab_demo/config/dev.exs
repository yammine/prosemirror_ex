import Config

config :collab_demo, CollabDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  debug_errors: true,
  secret_key_base: String.duplicate("a", 64),
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:collab_demo, ~w(--sourcemap=inline --watch)]}
  ]

config :phoenix, :plug_init_mode, :runtime
