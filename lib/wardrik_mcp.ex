defmodule WardrikMCP do
  @moduledoc """
  Gives WardrikCore agents the tools of any MCP server.

  Start it with the servers it connects to:

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
                url: "https://mcp.linear.app/mcp",
                headers: %{"authorization" => "Bearer " <> System.fetch_env!("LINEAR_TOKEN")}}
           ]
         ]}
      ]

  Then give an agent their tools as a `WardrikCore.Capability`:

      WardrikCore.start_agent(
        agent_id: "triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
      )

  The model sees each tool as `github__search_issues`, with the server's own description and JSON
  Schema. See `WardrikMCP.Server` for every server option.

  Use it when the tools an agent needs already exist as an MCP server.

  ## Connections

  Each server connects on its own. A server that's down offers no tools and doesn't block the
  others. It's retried with backoff, up to a minute between tries. When a server says its tools
  changed, they're listed again.

  ## Annotations

  Each tool carries the server's hints as `WardrikCore.Tool` annotations: `read_only`,
  `destructive`, `idempotent` and `open_world`. A hint the server doesn't give isn't set.

    * A read-only tool is also `idempotent`.
    * A tool is `gated` unless it's read-only. The server's `gated` option overrides this.
    * Answers are labelled `"outside"` unless the server is `trusted`.

  ## Errors

  A call that fails transiently raises `WardrikMCP.Unavailable`. This covers a dropped connection,
  a timeout or a server error. The tool runner then retries read-only and idempotent tools. See
  `WardrikCore.Retry`.

  An error the tool itself returns is passed to the model as the call's error.

  ## Telemetry

  `[:wardrik_mcp, :tools]` is emitted each time a server's tools change.

    * Measurements: `:count`, the number of tools the server offers. `0` while it's down.
    * Metadata: `:mcp`, the `WardrikMCP` name, and `:server`, the server's name.
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  alias WardrikMCP.Connection
  alias WardrikMCP.Servers

  @doc """
  Starts `WardrikMCP` and connects to each of its servers.

      WardrikMCP.start_link(
        name: MyApp.MCP,
        servers: [github: [transport: {:stdio, command: "github-mcp-server", args: ["stdio"]}]],
        store: store,
        check: &MyApp.Egress.public/1
      )

  ## Options

    * `:name` - required. The name agents and functions reach it by.
    * `:servers` - servers to start with, as a keyword list of name and options. See
      `WardrikMCP.Server`. `[]` unless set.
    * `:store` - a `WardrikStore` for servers added at runtime. Without it, `add/3` only adds a
      server on this node.
    * `:reconcile` - milliseconds between re-reads of the store, or `:infinity`. `60_000` unless
      set.
    * `:check` - a function called on each URL of a server added at runtime. It returns `:ok` or
      `{:error, reason}`. It's called when the server is added and each time a connection starts.
      With a check, runtime servers must use HTTP; commands are refused. Use one when users supply
      the URLs.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        servers: [],
        store: nil,
        reconcile: :timer.minutes(1),
        check: nil
      ])

    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Adds the server `name` at runtime.

  Takes the same options as a server in `:servers`, but only as data, not functions. With a
  `:store`, every node reaches it.

      :ok =
        WardrikMCP.add(MyApp.MCP, "linear",
          transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
          credential_name: "linear"
        )
  """
  @spec add(atom(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def add(mcp, name, opts) when is_binary(name), do: Servers.add(mcp, name, opts)

  @doc """
  Removes the server `name` and closes every connection to it.

  Returns `{:error, :not_found}` if there's no such server, and `{:error, reason}` for a server
  given in `:servers`.
  """
  @spec remove(atom(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def remove(mcp, name), do: Servers.remove(mcp, name)

  @doc "Returns the names of all servers, sorted."
  @spec servers(atom()) :: [String.t()]
  def servers(mcp), do: mcp |> Servers.all() |> Map.keys() |> Enum.sort()

  @doc "Re-reads the servers in the store now, picking up those added or removed on other nodes."
  @spec reconcile(atom()) :: :ok
  def reconcile(mcp), do: Servers.reconcile(mcp)

  @impl Supervisor
  def init(opts) do
    settings = %{
      mcp: opts.name,
      servers: opts.servers,
      store: scoped(opts.store),
      reconcile: opts.reconcile,
      check: opts.check
    }

    children = [
      {Finch, name: Connection.finch(opts.name)},
      {Registry, keys: :unique, name: Connection.registry(opts.name)},
      {DynamicSupervisor, name: Connection.supervisor(opts.name)},
      {Servers, settings}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp scoped(nil), do: nil
  defp scoped(store), do: WardrikStore.scope(store, "wardrik_mcp")

  @doc """
  Returns the tools of the named servers.

  ## Options

    * `:name` - required. The `WardrikMCP` name.
    * `:servers` - required. A server name or a list of them, as `:github` or
      `["github", "linear"]`.
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

defmodule WardrikMCP.Unavailable do
  @moduledoc "Raised when an MCP server fails transiently. Retrying the call may succeed."
  defexception [:message]
end
