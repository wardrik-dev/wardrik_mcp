defmodule WardrikMCP.ServerTest do
  use ExUnit.Case, async: true

  alias WardrikMCP.Server

  test "sends a credential in a header over HTTP, as its scheme says" do
    http = {:streamable_http, url: "https://mcp.test/mcp", headers: %{"x-app" => "1"}}

    assert {:streamable_http, opts} =
             Server.transport(Server.new!("a", transport: http, credential_name: "a"), "tok")

    assert opts[:headers] == %{"x-app" => "1", "authorization" => "Bearer tok"}

    server =
      Server.new!("a",
        transport: {:streamable_http, url: "https://mcp.test/mcp"},
        credential_name: "a",
        credential_header: "x-key",
        credential_scheme: ""
      )

    assert {:streamable_http, opts} = Server.transport(server, "tok")
    assert opts[:headers] == %{"x-key" => "tok"}
  end

  test "reaches a server over HTTP through its WardrikMCP's own pool" do
    server = %{
      Server.new!("a", transport: {:streamable_http, url: "https://mcp.test/mcp"})
      | mcp: MyApp.MCP
    }

    assert {:streamable_http, opts} = Server.transport(server, nil)
    assert opts[:finch_name] == WardrikMCP.Connection.finch(MyApp.MCP)
  end

  test "sends a credential in a variable to a command, where it names one" do
    stdio = {:stdio, command: "server"}

    assert {:stdio, opts} =
             Server.transport(Server.new!("a", transport: stdio, credential_env: "TOKEN"), "tok")

    assert opts[:env] == %{"TOKEN" => "tok"}

    assert {:stdio, opts} = Server.transport(Server.new!("a", transport: stdio), "tok")
    assert opts[:env] == %{}
  end

  test "starts a command through env, unsetting what it isn't given" do
    System.put_env("SERVER_TEST_SENTINEL", "secret")
    on_exit(fn -> System.delete_env("SERVER_TEST_SENTINEL") end)

    stdio = {:stdio, command: "server", args: ["stdio"], env: %{"SERVER_TEST_SENTINEL" => "mine"}}
    assert {:stdio, opts} = Server.transport(Server.new!("a", transport: stdio), nil)

    assert opts[:command] == "env"
    assert ["--", "server", "stdio"] = Enum.take(opts[:args], -3)
    refute "SERVER_TEST_SENTINEL" in opts[:args]
    refute "PATH" in opts[:args]

    assert {:stdio, opts} =
             Server.transport(Server.new!("a", transport: {:stdio, command: "server"}), nil)

    assert "SERVER_TEST_SENTINEL" in opts[:args]
  end

  test "names its tools under its prefix, or its name" do
    assert Server.prefix(Server.new!(:github, transport: {:stdio, command: "x"})) == "github"

    assert Server.prefix(Server.new!("gh", transport: {:stdio, command: "x"}, prefix: "github")) ==
             "github"
  end

  test "refuses a transport it can't start" do
    for transport <- [{:stdio, args: ["stdio"]}, {:stdio, command: "x", cwd: "/"}, {:ssh, []}] do
      assert_raise NimbleOptions.ValidationError, ~r/:transport/, fn ->
        Server.new!("a", transport: transport)
      end
    end
  end

  test "reads the secrets its headers name, and knows which they are" do
    headers = %{"authorization" => ["Bearer ", {:secret, "KEY"}], "x-team" => {:secret, "TEAM"}}

    server = %{
      Server.new!("a",
        transport: {:streamable_http, url: "https://mcp.test/mcp", headers: headers}
      )
      | secret: fn "acme", name -> {:ok, String.downcase(name)} end,
        owner: "acme"
    }

    assert {:ok, %Server{transport: {:streamable_http, opts}}} = Server.resolved(server)
    assert opts[:headers] == %{"authorization" => "Bearer key", "x-team" => "team"}

    assert Server.names?(server, "KEY")
    assert Server.names?(server, "TEAM")
    refute Server.names?(server, "OTHER")
    refute Server.names?(Server.new!("b", transport: {:stdio, command: "x"}), "KEY")

    assert_raise NimbleOptions.ValidationError, ~r/:headers/, fn ->
      Server.new!("c",
        transport: {:streamable_http, url: "https://mcp.test/mcp", headers: %{"x" => {:env, "X"}}}
      )
    end
  end
end
