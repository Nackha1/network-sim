# NetworkSim

A minimal OTP-based network simulator: one process per graph node, a router that owns
topology and link state, plus a `Registry` for name-to-pid lookup and a `DynamicSupervisor`
for node lifecycles.

## Quickstart

```bash
cd network_sim
iex -S mix
```

In `iex`:

```elixir
# Define undirected graph with nodes and links
nodes = [:a, :b,:c]
links = [{:a, :b}, {:a, :c}, {:b,:c}]

# Load a graph and start nodes automatically
NetworkSim.start_network(nodes, links)

# Send when the link is enabled
NetworkSim.send(:a, :b, "hello")  # => :ok
NetworkSim.inbox(:b)              # => [a: "hello"]

# Disable / enable links at runtime
NetworkSim.disable_link(:a, :b)   # => :ok
NetworkSim.send(:a, :b, "msg")    # => {:error, :link_disabled}
NetworkSim.enable_link(:a, :b)    # => :ok

# Inspect state
NetworkSim.neighbors(:a)          # => MapSet.new([:b, :c])
NetworkSim.inbox(:b)              # => [a: "hello"]
NetworkSim.clear_inbox(:b)        # => :ok
```

## Design

- **Node per vertex**: `NetworkSim.Node` is a `GenServer` that registers in a local `Registry`
  under `{:node, id}`.
- **Dynamic supervision**: nodes are started on demand by `DynamicSupervisor` (`NetworkSim.NodeSupervisor`).
- **Centralized policy**: `NetworkSim.Router` is a `GenServer` that owns the adjacency map and a `MapSet`
  of disabled directed edges. All application sends go through `Router.send/3`, which enforces the policy.
