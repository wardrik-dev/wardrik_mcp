defmodule WardrikMCP do
  @moduledoc """
  Gives WardrikCore agents the tools of any MCP server.

      children = [
        {WardrikMCP,
         name: MyApp.MCP,
         servers: [
           github: [transport: {:stdio, command: "github-mcp-server", args: ["stdio"]}],
           linear: [transport: {:streamable_http, url: "https://mcp.linear.app/mcp"}]
         ]}
      ]

      WardrikCore.start_agent(
        agent_id: "triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
      )

    * The model sees each tool as `github__search_issues`.
    * Server options are in `WardrikMCP.Server`.
    * A server that's down offers no tools and is retried, up to a minute between tries.
    * Tools carry the server's hints as `WardrikCore.Tool` annotations. A tool is `gated` unless
      it's read-only.
    * A transient failure raises `WardrikMCP.Unavailable`, so the tool runner can retry.
    * An error the tool returns reaches the model as the call's error.

  ## Telemetry

    * `[:wardrik_mcp, :tools]` when a server's tools change. Measurements: `:count` (`0` while
      down). Metadata: `:mcp`, `:server`.
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  @options NimbleOptions.new!(
             name: [
               type: :atom,
               required: true,
               doc: "The name agents and functions reach it by."
             ],
             servers: [
               type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
               default: [],
               doc:
                 "Servers to start with, as a list of name and options. See `WardrikMCP.Server`."
             ],
             store: [
               type: :any,
               doc:
                 "A `WardrikStore` for servers added at runtime. Without it, `add/3` only adds a server on this node."
             ],
             reconcile: [
               type: {:or, [:pos_integer, {:in, [:infinity]}]},
               default: :timer.minutes(1),
               doc: "Milliseconds between re-reads of the store, or `:infinity`."
             ],
             check: [
               type: {:or, [{:fun, 1}, nil]},
               doc: """
               Vets each URL of a server added at runtime, returning `:ok` or `{:error, reason}`.
               With a check, runtime servers must use HTTP.
               """
             ],
             secret: [
               type: {:or, [{:fun, 2}, nil]},
               doc: """
               Reads a secret a header names: `fun.(owner, name)` returns `{:ok, value}` or
               `{:error, reason}`.
               """
             ]
           )

  alias WardrikMCP.Connection
  alias WardrikMCP.Servers

  @doc """
  Starts `WardrikMCP` and connects to its servers.

  ## Options

  #{NimbleOptions.docs(@options)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options)
    Supervisor.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @doc """
  Adds the server `name`. Options are as in `WardrikMCP.Server`, as data, not functions.

      :ok =
        WardrikMCP.add(MyApp.MCP, "linear",
          transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
          credential_name: "linear"
        )
  """
  @spec add(atom(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def add(mcp, name, opts) when is_binary(name), do: Servers.add(mcp, name, opts)

  @doc """
  Removes the server `name` and closes its connections.

  Returns `{:error, :not_found}`, or `{:error, reason}` for a server given in `:servers`.
  """
  @spec remove(atom(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def remove(mcp, name), do: Servers.remove(mcp, name)

  @doc """
  Reconnects the servers whose headers name a secret. Call it after the secret changes.

      :ok = WardrikMCP.reconnect(MyApp.MCP, owner: "acme", secret: "CRM_KEY")

  `owner: nil` matches servers with no `owner`.
  """
  @spec reconnect(atom(), owner: String.t() | nil, secret: String.t()) :: :ok
  def reconnect(mcp, args), do: Servers.reconnect(mcp, args)

  @doc "Returns the names of all servers, sorted."
  @spec servers(atom()) :: [String.t()]
  def servers(mcp), do: mcp |> Servers.all() |> Map.keys() |> Enum.sort()

  @doc "Re-reads the store now, for servers added or removed on other nodes."
  @spec reconcile(atom()) :: :ok
  def reconcile(mcp), do: Servers.reconcile(mcp)

  @impl Supervisor
  def init(opts) do
    settings = %{
      mcp: opts.name,
      servers: opts.servers,
      store: scoped(opts[:store]),
      reconcile: opts.reconcile,
      check: opts[:check],
      secret: opts[:secret]
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
  @moduledoc "Raised when an MCP server fails transiently. A retry may succeed."
  defexception [:message]
end
