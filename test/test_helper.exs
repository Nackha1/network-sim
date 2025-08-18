ExUnit.start()

defmodule NetworkSim.TestHelper do
  alias NetworkSim.Dot
  alias NetworkSim.Router

  def start(nodes, links, test_name) do
    NetworkSim.start_network(nodes, links)

    show_custom_tree(
      Router.nodes(),
      Router.links(),
      NetworkSim.get_tree(),
      "#{test_name}_start"
    )
  end

  def stop(test_name) do
    show_custom_tree(
      Router.nodes(),
      Router.links(),
      NetworkSim.get_tree(),
      "#{test_name}_end"
    )

    NetworkSim.stop_network()
  end

  def show_custom_mst(nodes, links, test_name) do
    Dot.show_mst(nodes, links, "tmp/dmst/#{test_name}")
  end

  def show_custom_tree(nodes, links, tree, test_name) do
    Dot.show_mst(nodes, links, tree, "tmp/dmst/#{test_name}")
  end
end
