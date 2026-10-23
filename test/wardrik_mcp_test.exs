defmodule WardrikMCPTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Context
  alias WardrikCore.Tool
  alias WardrikCore.ToolCall

  @mcp WardrikMCPTest.MCP
  @stub {:stdio, command: "elixir", args: [Path.expand("support/stub_server.exs", __DIR__)]}

  setup_all do
    listen()

    start_supervised!(
      {WardrikMCP,
       name: @mcp,
       servers: [
         stub: [transport: @stub],
         cheap: [transport: @stub, only: ["echo", "charge"], cost: [usd: 0.01]],
         metered: [transport: @stub, except: ["slow"], cost: &%{usd: &1["_meta"]["usd"]}],
         hasty: [transport: @stub, timeout: 200, max_result_bytes: 101],
         growing: [transport: @stub],
         flaky: [transport: @stub],
         down: [transport: {:stdio, command: "no-such-mcp-server"}]
       ]}
    )

    Enum.each([:stub, :cheap, :metered, :hasty, :growing, :flaky], &connected/1)
  end

  test "offers a server's tools under its name" do
    names = :stub |> tools() |> Enum.map(& &1.name)

    assert "stub__echo" in names
    assert "stub__charge" in names
  end

  test "offers only the tools a server is given" do
    assert ["cheap__charge", "cheap__echo"] =
             :cheap |> tools() |> Enum.map(& &1.name) |> Enum.sort()

    refute "metered__slow" in (:metered |> tools() |> Enum.map(& &1.name))
  end

  test "gives several servers' tools together" do
    assert length(WardrikMCP.tools(context(), name: @mcp, servers: [:stub, :cheap])) ==
             length(tools(:stub)) + length(tools(:cheap))
  end

  test "carries the server's hints as annotations" do
    echo = tool(:stub, "echo")
    charge = tool(:stub, "charge")

    assert true == Tool.annotation(echo, :read_only)
    assert true == Tool.annotation(echo, :idempotent)
    assert false == Tool.annotation(charge, :read_only)
    assert true == Tool.annotation(charge, :destructive)
    assert nil == Tool.annotation(charge, :idempotent)
    assert nil == Tool.annotation(tool(:stub, "boom"), :read_only)
  end

  test "a call answers with the server's text" do
    assert {:ok, "hello", %Context{}} = call(:stub, "echo", %{"value" => "hello"})
  end

  test "a call the tool refuses answers with its error" do
    assert {:error, "the tool refused", %Context{}} = call(:stub, "boom")
  end

  test "structured content is given as it is" do
    assert {:ok, %{"open" => 3}, _context} = call(:stub, "report")
  end

  test "a long result is cut, and the model is told" do
    assert {:ok, text, _context} = call(:hasty, "big")
    assert String.valid?(text)
    assert text =~ "[Cut to 101 of 2000 bytes.]"
  end

  test "a call that takes too long answers with an error" do
    assert {:error, _message, _context} = call(:hasty, "slow")
  end

  test "a server's cost is measured on the call's step" do
    assert {:ok, "charged", %Context{measurements: %{usd: 0.01}}} = call(:cheap, "charge")
    assert {:ok, "charged", %Context{measurements: %{usd: 0.25}}} = call(:metered, "charge")
    assert {:ok, "charged", %Context{measurements: measured}} = call(:stub, "charge")
    assert measured == %{}
  end

  test "a server that's down offers no tools" do
    assert [] = tools(:down)
  end

  test "the arguments are checked against the server's schema" do
    calls = [%ToolCall{id: "1", name: "stub__echo", arguments: %{}}]
    assert {:error, _reason} = Tool.call(tools(:stub), hd(calls), context())
  end

  test "a server that says its tools changed is asked for them again" do
    listen()
    refute tool(:growing, "grown")
    assert {:ok, "grown", _context} = call(:growing, "grow")

    assert_receive {:tools, @mcp, :growing, %{count: 8}}, 5_000
    assert tool(:growing, "grown")
  end

  test "a connection that dies offers nothing, then connects again" do
    listen()
    {:ok, client} = flaky_client()
    Process.exit(client, :kill)

    assert_receive {:tools, @mcp, :flaky, %{count: 0}}, 5_000
    assert_receive {:tools, @mcp, :flaky, %{count: count}}, 5_000
    assert count > 0
    assert {:ok, "back", _context} = call(:flaky, "echo", %{"value" => "back"})
  end

  test "keeps the servers of each WardrikMCP apart" do
    listen()

    start_supervised!(
      {WardrikMCP,
       name: WardrikMCPTest.Other, servers: [stub: [transport: @stub, only: ["echo"]]]},
      id: :other
    )

    assert_receive {:tools, WardrikMCPTest.Other, :stub, %{count: 1}}, 10_000

    assert ["stub__echo"] =
             Enum.map(
               WardrikMCP.tools(context(), name: WardrikMCPTest.Other, servers: :stub),
               & &1.name
             )

    assert "stub__charge" in Enum.map(tools(:stub), & &1.name)
  end

  defp flaky_client do
    [{connection, _tools}] = Registry.lookup(WardrikMCP.Connection.registry(@mcp), :flaky)
    {:ok, :sys.get_state(connection).client}
  end

  defp listen do
    test = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:wardrik_mcp, :tools],
      fn _event, measured, %{mcp: mcp, server: server}, _config ->
        send(test, {:tools, mcp, server, measured})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp tools(server), do: WardrikMCP.tools(context(), name: @mcp, servers: server)

  defp tool(server, name), do: Enum.find(tools(server), &(&1.name == "#{server}__#{name}"))

  defp call(server, name, arguments \\ %{}) do
    call = %ToolCall{id: "1", name: "#{server}__#{name}", arguments: arguments}
    Tool.call(tools(server), call, context())
  end

  defp context, do: Context.new(agent_id: "mcp-test")

  defp connected(server) do
    if tools(server) == [], do: assert_receive({:tools, @mcp, ^server, %{count: _count}}, 10_000)
  end
end
