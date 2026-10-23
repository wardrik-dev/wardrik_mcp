defmodule WardrikMCPTest.Tokens do
  @moduledoc "Credentials the tests give principals: a token each, or a sign-in."
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve("stub", %WardrikCore.Principal{id: id}, tokens) do
    case Map.fetch(tokens, id) do
      {:ok, token} -> {:ok, token}
      :error -> {:authorize, "https://sign.in/" <> id}
    end
  end
end

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

    Enum.each(~w(stub cheap metered hasty growing flaky), &connected/1)
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

    assert_receive {:tools, @mcp, "growing", %{count: 9}}, 5_000
    assert tool(:growing, "grown")
  end

  test "a connection that dies offers nothing, then connects again" do
    listen()
    {:ok, client} = flaky_client()
    Process.exit(client, :kill)

    assert_receive {:tools, @mcp, "flaky", %{count: 0}}, 5_000
    assert_receive {:tools, @mcp, "flaky", %{count: count}}, 5_000
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

    assert_receive {:tools, WardrikMCPTest.Other, "stub", %{count: 1}}, 10_000

    assert ["stub__echo"] =
             Enum.map(
               WardrikMCP.tools(context(), name: WardrikMCPTest.Other, servers: :stub),
               & &1.name
             )

    assert "stub__charge" in Enum.map(tools(:stub), & &1.name)
  end

  describe "servers added as the app runs" do
    test "reaches a server once it's added, and nothing of it once it's removed" do
      listen()

      assert :ok =
               WardrikMCP.add(@mcp, "added", transport: @stub, only: ["echo"], prefix: "extra")

      assert_receive {:tools, @mcp, "added", %{count: 1}}, 10_000

      assert "added" in WardrikMCP.servers(@mcp)
      assert ["extra__echo"] = Enum.map(tools("added"), & &1.name)

      assert :ok = WardrikMCP.remove(@mcp, "added")
      refute "added" in WardrikMCP.servers(@mcp)
      assert tools("added") == []
      assert {:error, :not_found} = WardrikMCP.remove(@mcp, "added")
    end

    test "says why it can't add or remove a server" do
      assert {:error, "stub is a server already"} = WardrikMCP.add(@mcp, "stub", transport: @stub)
      assert {:error, "stub is a server the app starts with"} = WardrikMCP.remove(@mcp, "stub")

      assert {:error, "unknown keys" <> _} =
               WardrikMCP.add(@mcp, "odd", transport: @stub, colour: "blue")

      assert {:error, "a server added as the app runs takes its options as data"} =
               WardrikMCP.add(@mcp, "priced", transport: @stub, cost: &Map.new/1)
    end

    test "reaches what another node added, through the store they share" do
      listen()
      store = WardrikStore.ETS.new(name: WardrikMCPTest.Store)
      start_supervised!({WardrikStore, store}, id: :store)

      for {name, id} <- [{WardrikMCPTest.One, :one}, {WardrikMCPTest.Two, :two}] do
        start_supervised!({WardrikMCP, name: name, store: store, reconcile: :infinity}, id: id)
      end

      assert :ok = WardrikMCP.add(WardrikMCPTest.One, "shared", transport: @stub, only: ["echo"])
      assert :ok = WardrikMCP.reconcile(WardrikMCPTest.Two)

      assert_receive {:tools, WardrikMCPTest.Two, "shared", %{count: 1}}, 10_000
      assert "shared" in WardrikMCP.servers(WardrikMCPTest.Two)

      assert :ok = WardrikMCP.remove(WardrikMCPTest.One, "shared")
      assert :ok = WardrikMCP.reconcile(WardrikMCPTest.Two)
      refute "shared" in WardrikMCP.servers(WardrikMCPTest.Two)
    end
  end

  describe "a server each principal reaches with their own credential" do
    setup do
      server = [
        transport: @stub,
        credential: "stub",
        credential_env: "STUB_TOKEN",
        only: ["whoami"]
      ]

      :ok = WardrikMCP.add(@mcp, "own", server)
      on_exit(fn -> WardrikMCP.remove(@mcp, "own") end)
    end

    defp own(context), do: WardrikMCP.tools(context, name: @mcp, servers: "own")

    defp ask(context, name) do
      call = %ToolCall{id: "1", name: "own__" <> name, arguments: %{}}
      Tool.call(own(context), call, context)
    end

    test "offers connecting until someone has, then each calls it as themselves" do
      ada = context("ada", %{"ada" => "ada-token"})
      grace = context("grace", %{})

      assert ["own__connect"] = Enum.map(own(ada), & &1.name)

      assert {:park, %WardrikCore.Authorization{url: "https://sign.in/grace", credential: "stub"}} =
               ask(grace, "connect")

      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      assert ["own__whoami"] = Enum.map(own(ada), & &1.name)
      assert {:ok, "ada-token", _context} = ask(ada, "whoami")

      linus = context("linus", %{"linus" => "linus-token"})
      assert {:ok, "linus-token", _context} = ask(linus, "whoami")

      renewed = context("ada", %{"ada" => "ada-renewed"})
      assert {:ok, "ada-renewed", _context} = ask(renewed, "whoami")

      assert {:park, %WardrikCore.Authorization{}} = ask(grace, "whoami")
    end

    test "says when it can't be reached, or there's nothing to reach it with" do
      :ok =
        WardrikMCP.add(@mcp, "broken",
          transport: {:stdio, command: "no-such-mcp-server"},
          credential: "stub"
        )

      ada = context("ada", %{"ada" => "ada-token"})
      call = %ToolCall{id: "1", name: "broken__connect", arguments: %{}}

      assert {:error, "broken didn't connect" <> _} =
               Tool.call(WardrikMCP.tools(ada, name: @mcp, servers: "broken"), call, ada)

      bare = Context.new(agent_id: "mcp-test", principal: %WardrikCore.Principal{id: "ada"})
      assert {:error, "own didn't connect" <> _} = ask(bare, "connect")

      :ok = WardrikMCP.remove(@mcp, "broken")
    end

    test "closes every connection to it when it's removed" do
      ada = context("ada", %{"ada" => "ada-token"})
      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      assert :ok = WardrikMCP.remove(@mcp, "own")
      assert own(ada) == []
    end
  end

  defp flaky_client do
    [{connection, _hash}] =
      Registry.lookup(WardrikMCP.Connection.registry(@mcp), {:connection, "flaky", nil})

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

  defp context(principal, tokens),
    do:
      Context.new(
        agent_id: "mcp-test",
        principal: %WardrikCore.Principal{id: principal},
        credentials: {WardrikMCPTest.Tokens, tokens}
      )
end
