defmodule WardrikMCP do
  @moduledoc """
  The tools of any MCP server, for a WardrikCore agent to call.

      children = [
        {WardrikMCP,
         name: MyApp.MCP,
         servers: [
           github: [
             transport: {:stdio, command: "github-mcp-server", args: ["stdio"]},
             only: ["search_issues", "create_issue"]
           ],
           linear: [
             transport:
               {:streamable_http,
                base_url: "https://mcp.linear.app/mcp",
                headers: %{"authorization" => "Bearer " <> System.fetch_env!("LINEAR_TOKEN")}}
           ]
         ]}
      ]

  Give an agent a server's tools as a `WardrikCore.Capability`, by the server's name:

      WardrikCore.start_agent(
        agent_id: "triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
      )

  The model sees each tool as `github__search_issues`, with the server's own description and JSON
  Schema. `WardrikMCP.Server` lists every option a server takes.

  Each tool carries the server's hints as `WardrikCore.Tool` annotations: `read_only`,
  `destructive`, `idempotent` and `open_world`. A read-only tool is idempotent too. A hint the
  server doesn't give isn't set.

  Each server connects on its own. One that's down offers no tools, and holds up nothing else. It's
  tried again, waiting longer each time, up to a minute. A server that says its tools changed is
  asked for them again.

  Each time the tools a server offers change, it emits `[:wardrik_mcp, :tools]`. The event carries
  the `mcp` it runs under and the `server`, and measures the `count` of tools it now offers, which
  is 0 while it's down.

  Reach for this when the tools an agent needs already exist as an MCP server.
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  @doc """
  Starts a connection to each of the `:servers`, a keyword list of name and options, under the
  `:name` agents reach them by.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, :servers])
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, {name, Keyword.fetch!(opts, :servers)}, name: name)
  end

  @impl Supervisor
  def init({name, servers}) do
    connections =
      Enum.map(servers, fn {server, opts} ->
        {Connection, %{Server.new!(server, opts) | mcp: name}}
      end)

    Supervisor.init([{Registry, keys: :unique, name: Connection.registry(name)} | connections],
      strategy: :rest_for_one
    )
  end

  @doc """
  Gives the tools of the `:servers` named, as `:github` or `[:github, :linear]`, that the
  `WardrikMCP` started as `:name` connects to.
  """
  @impl WardrikCore.Capability
  def tools(_context, opts) do
    mcp = Keyword.fetch!(opts, :name)

    opts
    |> Keyword.fetch!(:servers)
    |> List.wrap()
    |> Enum.flat_map(&Connection.tools(mcp, &1))
  end
end
