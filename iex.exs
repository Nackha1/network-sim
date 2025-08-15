alias NetworkSim.Protocol

nodes = [
      {:a, Protocol.DynamicMST, %{parent: nil, children: [:b]}},
      {:b, Protocol.DynamicMST, %{parent: :a, children: []}}
    ]

    links = [
      {:a, :b, %{weight: 3}}
    ]
