defmodule WardrikMCPTest.Tokens do
  @moduledoc "Credentials the tests give principals: a token each, or a sign-in."
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(%{name: "stub", principal: %WardrikCore.Principal{id: id}}, tokens) do
    case Map.fetch(tokens, id) do
      {:ok, token} -> {:ok, token}
      :error -> {:authorize, "https://sign.in/" <> id}
    end
  end
end

defmodule WardrikMCPTest.Rotating do
  @moduledoc "Credentials that hand out the token an agent holds, and a new one once the old is refused."
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(%{name: "stub"}, tokens), do: {:ok, Agent.get(tokens, & &1.token)}

  @impl true
  def refused(%{name: "stub"}, tokens) do
    Agent.update(tokens, fn state ->
      send(state.test, {:refused, state.token})
      %{state | token: state.token <> "-renewed"}
    end)
  end
end

defmodule WardrikMCPTest do
  use ExUnit.Case, async: true
  use Mimic

  alias WardrikCore.Context
  alias WardrikCore.Tool
  alias WardrikCore.ToolCall
  alias WardrikMCP.Server

  @mcp WardrikMCPTest.MCP
  @stub {:stdio, command: "elixir", args: [Path.expand("support/stub_server.exs", __DIR__)]}

  setup_all do
    listen()

    start_supervised!(
      {WardrikMCP,
       name: @mcp,
       servers: [
         stub: [transport: @stub],
         cheap: [
           transport: @stub,
           only: ["echo", "charge"],
           cost: [usd: 0.01],
           gated: ["ec*"],
           trusted: true
         ],
         metered: [transport: @stub, except: ["slow"], cost: &%{usd: &1["_meta"]["usd"]}],
         hasty: [transport: @stub, timeout: 200, max_result_bytes: 101],
         growing: [transport: @stub],
         flaky: [transport: @stub],
         down: [transport: {:stdio, command: "no-such-mcp-server"}]
       ]}
    )

    Enum.each(~w(stub cheap metered hasty growing flaky), &connected/1)
  end

  test "says which MCP isn't started" do
    assert_raise ArgumentError, ~r/^MyApp.Missing isn't started/, fn ->
      WardrikMCP.servers(MyApp.Missing)
    end
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

  test "gates a tool unless it's read-only, and labels answers outside unless trusted" do
    assert false == Tool.annotation(tool(:stub, "echo"), :gated)
    assert true == Tool.annotation(tool(:stub, "charge"), :gated)
    assert true == Tool.annotation(tool(:stub, "boom"), :gated)
    assert ["outside"] == Tool.annotation(tool(:stub, "echo"), :labels)

    assert true == Tool.annotation(tool(:cheap, "echo"), :gated)
    assert false == Tool.annotation(tool(:cheap, "charge"), :gated)
    assert [] == Tool.annotation(tool(:cheap, "echo"), :labels)
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

  test "a call that fails in passing raises, for the tool runner to try again" do
    assert_raise WardrikMCP.Unavailable, ~r/hasty failed/, fn -> call(:hasty, "slow") end
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

    assert_receive {:tools, @mcp, "growing", %{count: 10}}, 5_000
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

      assert {:error, "unknown options [:colour]" <> _} =
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

  test "reaches a server over HTTP at exactly the URL it's given" do
    listen()

    for {name, path} <- [{"ending", "/mcp"}, {"nested", "/v1/tools/"}, {"root", "/"}] do
      port = WardrikMCP.HTTPStub.start(self(), path)
      url = "http://127.0.0.1:#{port}" <> if(path == "/", do: "", else: path)

      :ok = WardrikMCP.add(@mcp, name, transport: {:streamable_http, url: url})
      on_exit(fn -> WardrikMCP.remove(@mcp, name) end)
      connected(name)

      assert ["#{name}__ping"] == name |> tools() |> Enum.map(& &1.name)
      assert [^path | _rest] = paths = requested()
      assert Enum.uniq(paths) == [path]
    end
  end

  test "refuses a server over HTTP without an http or https URL" do
    transport = {:streamable_http, url: "mcp.example.com/mcp"}
    assert {:error, _reason} = WardrikMCP.add(@mcp, "bad", transport: transport)
  end

  describe "a server whose headers name secrets" do
    setup do
      test = self()
      {:ok, secrets} = Agent.start_link(fn -> %{{"acme", "KEY"} => "one"} end)

      secret = fn owner, name ->
        send(test, {:read, owner, name})

        case Agent.get(secrets, &Map.fetch(&1, {owner, name})) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end

      start_supervised!({WardrikMCP, name: WardrikMCPTest.Secrets, secret: secret}, id: :secrets)
      port = WardrikMCP.HTTPStub.start(test, "/mcp")
      %{secrets: secrets, url: "http://127.0.0.1:#{port}/mcp"}
    end

    defp secured(url, owner, value),
      do: [
        transport: {:streamable_http, url: url, headers: %{"authorization" => value}},
        owner: owner
      ]

    test "reads them for its owner as it connects, and again once reconnected", %{
      secrets: secrets,
      url: url
    } do
      server = secured(url, "acme", ["Bearer ", {:secret, "KEY"}])
      assert :ok = WardrikMCP.add(WardrikMCPTest.Secrets, "crm", server)

      assert_receive {:read, "acme", "KEY"}
      assert_receive {:authorization, "Bearer one"}, 5_000

      Agent.update(secrets, &Map.put(&1, {"acme", "KEY"}, "two"))
      assert :ok = WardrikMCP.reconnect(WardrikMCPTest.Secrets, owner: "globex", secret: "KEY")
      refute_receive {:read, _owner, _name}, 200

      assert :ok = WardrikMCP.reconnect(WardrikMCPTest.Secrets, owner: "acme", secret: "KEY")
      assert_receive {:authorization, "Bearer two"}, 5_000
    end

    test "is down while one can't be read, and says why", %{url: url} do
      theirs = secured(url, "globex", {:secret, "KEY"})
      server = Server.new!("theirs", theirs)

      assert Server.resolved(server) ==
               {:error, "the secret KEY can't be read: WardrikMCP was given no :secret"}

      assert Server.resolved(%{server | secret: fn _owner, _name -> {:error, :not_found} end}) ==
               {:error, "the secret KEY can't be read: :not_found"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = WardrikMCP.add(WardrikMCPTest.Secrets, "theirs", theirs)
          assert_receive {:read, "globex", "KEY"}
          :ok = WardrikMCP.remove(WardrikMCPTest.Secrets, "theirs")
        end)

      assert log =~ "The MCP server theirs is down: \"the secret KEY can't be read: :not_found\""
      assert WardrikMCP.tools(context(), name: WardrikMCPTest.Secrets, servers: "theirs") == []
    end
  end

  describe "servers added under a check" do
    setup do
      test = self()
      {:ok, answers} = Agent.start_link(fn -> [:ok, {:error, "it's private"}] end)

      check = fn url ->
        send(test, {:checked, url})
        Agent.get_and_update(answers, &answered/1)
      end

      start_supervised!({WardrikMCP, name: WardrikMCPTest.Checked, check: check}, id: :checked)
      :ok
    end

    test "holds each URL to the check as it's added, and as each connection starts" do
      url = "https://mcp.example.com/mcp"

      assert :ok =
               WardrikMCP.add(WardrikMCPTest.Checked, "remote",
                 transport: {:streamable_http, url: url}
               )

      assert_receive {:checked, ^url}
      assert_receive {:checked, ^url}

      assert {:error, "https://mcp.example.com/mcp can't be reached: it's private"} =
               WardrikMCP.add(WardrikMCPTest.Checked, "again",
                 transport: {:streamable_http, url: url}
               )
    end

    test "reaches a server added as the app runs over HTTP alone" do
      assert {:error, "a server added as the app runs is reached over HTTP"} =
               WardrikMCP.add(WardrikMCPTest.Checked, "local", transport: @stub)
    end
  end

  test "starts a command with the variables it's given, and only a few of its own" do
    System.put_env("WARDRIK_MCP_SENTINEL", "secret")
    on_exit(fn -> System.delete_env("WARDRIK_MCP_SENTINEL") end)
    listen()

    {:stdio, opts} = @stub

    :ok =
      WardrikMCP.add(@mcp, "isolated",
        transport: {:stdio, [env: %{"STUB_SETTING" => "set"}] ++ opts}
      )

    on_exit(fn -> WardrikMCP.remove(@mcp, "isolated") end)
    connected("isolated")

    assert {:ok, env, _context} = call("isolated", "env")
    env = JSON.decode!(env)

    assert env["STUB_SETTING"] == "set"
    assert env["PATH"] == System.get_env("PATH")
    assert env["WARDRIK_MCP_SENTINEL"] == nil
  end

  describe "a server each principal reaches with their own credential" do
    setup do
      server = [
        transport: @stub,
        credential_name: "stub",
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
          credential_name: "stub"
        )

      ada = context("ada", %{"ada" => "ada-token"})
      call = %ToolCall{id: "1", name: "broken__connect", arguments: %{}}

      assert {:error, "broken didn't connect" <> _} =
               Tool.call(WardrikMCP.tools(ada, name: @mcp, servers: "broken"), call, ada)

      bare = Context.new(agent_id: "mcp-test", principal: %WardrikCore.Principal{id: "ada"})
      assert {:error, "own didn't connect" <> _} = ask(bare, "connect")

      :ok = WardrikMCP.remove(@mcp, "broken")
    end

    test "reports a credential the server refuses, and calls again with it renewed" do
      test = self()
      {:ok, tokens} = Agent.start_link(fn -> %{token: "ada-token", test: test} end)

      ada =
        Context.new(
          agent_id: "mcp-test",
          principal: %WardrikCore.Principal{id: "ada"},
          credentials: {WardrikMCPTest.Rotating, tokens}
        )

      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      refusal = %Anubis.MCP.Error{data: %{original_reason: {:authorization_required, %{}}}}
      stub(Anubis.Client, :call_tool, &call_original(Anubis.Client, :call_tool, [&1, &2, &3, &4]))

      expect(Anubis.Client, :call_tool, fn _client, _name, _arguments, _opts ->
        {:error, refusal}
      end)

      assert {:ok, "ada-token-renewed", _context} = ask(ada, "whoami")
      assert_received {:refused, "ada-token"}

      expect(Anubis.Client, :call_tool, 2, fn _client, _name, _arguments, _opts ->
        {:error, refusal}
      end)

      assert {:error, _refused, _context} = ask(ada, "whoami")
    end

    test "closes every connection to it when it's removed" do
      ada = context("ada", %{"ada" => "ada-token"})
      assert {:ok, "Connected to own." <> _} = ask(ada, "connect")

      assert :ok = WardrikMCP.remove(@mcp, "own")
      assert own(ada) == []
    end
  end

  defp requested do
    receive do
      {:http, _method, path} -> [path | requested()]
    after
      0 -> []
    end
  end

  defp answered([answer]), do: {answer, [answer]}
  defp answered([answer | rest]), do: {answer, rest}

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
