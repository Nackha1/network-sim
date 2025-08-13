import Config

Config.import_config("#{Mix.env()}.exs")

# import Config

# # Show debug logs while running tests
# config :logger, level: :debug

config :logger, :console,
  # format: "\n$time $metadata[$level] $message\n",
  metadata: [:node_id]
