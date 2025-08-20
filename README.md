# NetworkSim & Dynamic MST

A tiny playground for distributed graph algorithms in [Elixir](https://elixir-lang.org/).

Written by **Nazareno Piccin** for the *Advanced Laboratory in Distributed Systems* at the **University of Udine — DMIF** (Department of Mathematics, Computer Science and Physics).

## What’s inside

This repository has two main parts:

### 1) Network Simulator

A lightweight, process-per-node simulator for undirected graphs:

* Each node runs as a `GenServer` (`NetworkSim.Node`) and is registered in a `Registry`.
* A central `Router` (`NetworkSim.Router`) owns the **undirected** adjacency, per-edge attributes (e.g., weights), and the enable/disable state of edges.
* You can:

  * load a graph and start nodes via `NetworkSim.start_network/2`,
  * enable/disable links at runtime,
  * send messages along enabled edges, and
  * inspect node inboxes / protocol state.
* Graph export utilities are available in `NetworkSim.Dot` (Graphviz DOT).

**Quick taste (iex):**

```elixir
iex -S mix
iex> nodes = [{:a, NetworkSim.Protocol.PingPong, []},
...>          {:b, NetworkSim.Protocol.PingPong, []},
...>          {:c, NetworkSim.Protocol.PingPong, []}]
iex> links = [{:a, :b, %{weight: 1}}, {:b, :c, %{weight: 2}}]
iex> :ok = NetworkSim.start_network(nodes, links)
iex> NetworkSim.send(:a, :b, {:hello, 1})
:ok
iex> NetworkSim.inbox(:b)
[{:a, {:hello, 1}}]
```

> DOT helpers require **Graphviz** on your system if you want to render to SVG/PNG:
> `brew install graphviz` (macOS), `apt-get install graphviz` (Debian/Ubuntu), etc.

### 2) Dynamic MST

An experimental implementation of a **resilient Minimum Spanning Tree** protocol (`NetworkSim.Protocol.DynamicMST`) built on top of the simulator:

* Handles **failures** using a *REIDEN + FINDMOE + CHANGE\_ROOT/CONNECT* pipeline (inspired by GHS-style MOE selection).
* Handles **recoveries** by launching a *replace* procedure to drop the heaviest edge on a newly formed cycle.
* Uses the `Router`’s per-edge `:weight` attribute.
* Includes a simple `Kruskal` offline MST (`NetworkSim.Kruskal`) for validation and visualization with `NetworkSim.Dot`.

**Current limitations (by design in this version):**

* Failure and recovery phases are **not serialized**; adversarial interleaving is out of scope here.
* Fragment identifiers are `(weight, node_id)`; per-link **counters** are **not** used yet.

## Project layout (high-level)

```
lib/
  network_sim.ex                 # Public API: start/stop, messaging, helpers
  network_sim/router.ex          # Central topology & delivery authority
  network_sim/node.ex            # Node GenServer with inbox + protocol host
  network_sim/protocol.ex        # Behaviour for protocol implementations
  network_sim/protocol/dynamic_mst.ex  # Resilient MST protocol (this project’s focus)
  network_sim/kruskal.ex         # Offline MST for reference/visualization
  network_sim/dot.ex             # Graphviz DOT export utilities
test/
  ...                            # Unit tests
```

## Getting started

### 1) Install dependencies

```bash
mix deps.get
```

### 2) Run the test suite

```bash
mix test
```

### 3) Generate documentation (ExDoc)

Docs are compiled to the `doc/` folder:

```bash
mix deps.get
mix docs
open doc/index.html   # macOS; use xdg-open on Linux or just open in your browser
```