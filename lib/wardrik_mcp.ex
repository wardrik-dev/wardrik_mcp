defmodule WardrikMCP do
  @moduledoc """
  The tools of any MCP server, for a WardrikCore agent to call.

      children = [
        {WardrikMCP,
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
        capabilities: [{WardrikMCP, [:github, :linear]}]
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
  the `server`, and measures the `count` of tools it now offers, which is 0 while it's down.

  Reach for this when the tools an agent needs already exist as an MCP server.
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  @doc "Starts a connection to each of the `:servers`, a keyword list of name and options."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    connections =
      opts
      |> Keyword.validate!([:servers])
      |> Keyword.fetch!(:servers)
      |> Enum.map(fn {name, server} -> {Connection, Server.new!(name, server)} end)

    Supervisor.init([{Registry, keys: :unique, name: WardrikMCP.Registry} | connections],
      strategy: :rest_for_one
    )
  end

  @doc "Gives the tools of the servers named, as `:github` or `[:github, :linear]`."
  @impl WardrikCore.Capability
  def tools(_context, servers), do: servers |> List.wrap() |> Enum.flat_map(&Connection.tools/1)
end
