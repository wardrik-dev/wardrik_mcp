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
  alias WardrikMCP.Servers

  @doc """
  Starts a connection to each of the `:servers`, a keyword list of name and options, under the
  `:name` agents reach them by. Takes `:store`, a `WardrikStore` to keep servers added as the app
  runs in, and `:reconcile`, how often each node reads them again, a minute unless set.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, servers: [], store: nil, reconcile: :timer.minutes(1)])
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Adds the server `name` as the app runs, taking what a server in `:servers` takes, as data. With
  a store, every node reaches it.

      :ok =
        WardrikMCP.add(MyApp.MCP, "linear",
          transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"},
          credential_name: "linear"
        )
  """
  @spec add(atom(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def add(mcp, name, opts) when is_binary(name), do: Servers.add(mcp, name, opts)

  @doc "Removes the server `name`, added as the app ran, and closes every connection to it."
  @spec remove(atom(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def remove(mcp, name), do: Servers.remove(mcp, name)

  @doc "Returns the names of the servers it reaches."
  @spec servers(atom()) :: [String.t()]
  def servers(mcp), do: mcp |> Servers.all() |> Map.keys() |> Enum.sort()

  @doc "Reads the servers added on other nodes now, as each node does every so often."
  @spec reconcile(atom()) :: :ok
  def reconcile(mcp), do: Servers.reconcile(mcp)

  @impl Supervisor
  def init(opts) do
    settings = %{
      mcp: opts.name,
      servers: opts.servers,
      store: scoped(opts.store),
      reconcile: opts.reconcile
    }

    children = [
      {Registry, keys: :unique, name: Connection.registry(opts.name)},
      {DynamicSupervisor, name: Connection.supervisor(opts.name)},
      {Servers, settings}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp scoped(nil), do: nil
  defp scoped(store), do: WardrikStore.scope(store, "wardrik_mcp")

  @doc """
  Gives the tools of the `:servers` named, as `:github` or `["github", "linear"]`, that the
  `WardrikMCP` started as `:name` reaches.
  """
  @impl WardrikCore.Capability
  def tools(_context, opts) do
    mcp = Keyword.fetch!(opts, :name)

    opts
    |> Keyword.fetch!(:servers)
    |> List.wrap()
    |> Enum.flat_map(&Servers.tools(mcp, to_string(&1)))
  end
end
