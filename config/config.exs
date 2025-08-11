import Config

Config.import_config("#{Mix.env()}.exs")

# import Config

# # Show debug logs while running tests
# config :logger, level: :debug

# config :logger, :console,
#   format: "$time $metadata[$level] $message\n",
#   metadata: [:module, :node_id],
#   compile_time_purge_matching: [
#     [level_lower_than: :debug]
#   ]
