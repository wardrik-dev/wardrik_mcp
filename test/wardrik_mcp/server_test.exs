defmodule WardrikMCP.ServerTest do
  use ExUnit.Case, async: true

  alias WardrikMCP.Server

  test "sends a credential in a header over HTTP, as its scheme says" do
    http = {:streamable_http, base_url: "https://mcp.test/mcp", headers: %{"x-app" => "1"}}

    assert {:streamable_http, opts} =
             Server.transport(Server.new!("a", transport: http, credential: "a"), "tok")

    assert opts[:headers] == %{"x-app" => "1", "authorization" => "Bearer tok"}

    server =
      Server.new!("a",
        transport: {:streamable_http, base_url: "https://mcp.test/mcp"},
        credential: "a",
        credential_header: "x-key",
        credential_scheme: ""
      )

    assert {:streamable_http, opts} = Server.transport(server, "tok")
    assert opts[:headers] == %{"x-key" => "tok"}
  end

  test "sends a credential in a variable to a command, where it names one" do
    stdio = {:stdio, command: "server"}

    assert {:stdio, opts} =
             Server.transport(Server.new!("a", transport: stdio, credential_env: "TOKEN"), "tok")

    assert opts[:env] == %{"TOKEN" => "tok"}

    assert Server.transport(Server.new!("a", transport: stdio), "tok") == stdio
    assert Server.transport(Server.new!("a", transport: stdio), nil) == stdio
  end

  test "names its tools under its prefix, or its name" do
    assert Server.prefix(Server.new!(:github, transport: {:stdio, command: "x"})) == "github"

    assert Server.prefix(Server.new!("gh", transport: {:stdio, command: "x"}, prefix: "github")) ==
             "github"
  end
end
