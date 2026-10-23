defmodule WardrikMCP.Servers do
  @moduledoc """
  Holds the servers a `WardrikMCP` reaches, those it started with and those added as it runs, and
  the tools each reached with a credential last listed. Servers added as it runs are kept in the
  store, and every node reads them again every so often.
  """

  use GenServer

  alias WardrikMCP.Connection
  alias WardrikMCP.Server
  alias WardrikMCP.Tool

  @doc "Starts the servers `settings` describe."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(settings),
    do: GenServer.start_link(__MODULE__, settings, name: name(settings.mcp))

  @doc "Adds the server `name`, on every node where it's given a store."
  @spec add(atom(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def add(mcp, name, opts), do: GenServer.call(name(mcp), {:add, name, opts})

  @doc "Removes the server `name`, added as the app ran."
  @spec remove(atom(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def remove(mcp, name), do: GenServer.call(name(mcp), {:remove, name})

  @doc "Returns every server, by name."
  @spec all(atom()) :: %{String.t() => Server.t()}
  def all(mcp) do
    mcp
    |> table()
    |> :ets.match({{:server, :"$1"}, :"$2"})
    |> Map.new(fn [name, server] -> {name, server} end)
  end

  @doc "Returns the tools of the server `name`, as the agent the turn acts for may call them."
  @spec tools(atom(), String.t()) :: [WardrikCore.Tool.t()]
  def tools(mcp, name), do: offered(mcp, read(mcp, {:server, name}))

  @doc "Keeps the tools a server reached with a credential listed, before it returns."
  @spec listed(atom(), String.t(), [map()]) :: :ok
  def listed(mcp, name, definitions), do: GenServer.call(name(mcp), {:listed, name, definitions})

  @doc "Reads the servers added on other nodes, now."
  @spec reconcile(atom()) :: :ok
  def reconcile(mcp), do: GenServer.call(name(mcp), :reconcile)

  @impl GenServer
  def init(settings) do
    :ets.new(name(settings.mcp), [:named_table, :protected, read_concurrency: true])
    true = :ets.insert(name(settings.mcp), {:store, settings.store})
    static = MapSet.new(settings.servers, fn {name, _opts} -> to_string(name) end)
    {:ok, %{settings: settings, static: static, servers: %{}}, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %{settings: settings} = state) do
    state =
      Enum.reduce(settings.servers, state, fn {name, opts}, state ->
        started(state, Server.new!(name, opts))
      end)

    tick(settings)
    {:noreply, reconciled(state)}
  end

  @impl GenServer
  def handle_call({:add, name, opts}, _from, state) do
    with {:ok, server} <- built(name, opts),
         :ok <- new(state, name),
         :ok <- kept(state.settings, name, opts) do
      {:reply, :ok, started(state, server)}
    else
      {:error, why} -> {:reply, {:error, why}, state}
    end
  end

  def handle_call({:remove, name}, _from, state) do
    cond do
      MapSet.member?(state.static, name) ->
        {:reply, {:error, "#{name} is a server the app starts with"}, state}

      Map.has_key?(state.servers, name) ->
        forget(state.settings, name)
        {:reply, :ok, stopped(state, name)}

      true ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:reconcile, _from, state), do: {:reply, :ok, reconciled(state)}

  def handle_call({:listed, name, definitions}, _from, %{settings: settings} = state) do
    if settings.store,
      do: {:ok, _vsn} = WardrikStore.put(settings.store, "tools/" <> name, definitions)

    true = :ets.insert(name(settings.mcp), {{:listed, name}, definitions})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    tick(state.settings)
    {:noreply, reconciled(state)}
  end

  defp offered(_mcp, nil), do: []

  defp offered(mcp, %Server{credential_name: nil} = server),
    do: Connection.tools(mcp, server.name)

  defp offered(mcp, server) do
    case listed(mcp, server.name) do
      nil -> [Tool.connect(server)]
      definitions -> Tool.offered(server, definitions)
    end
  end

  defp listed(mcp, name) do
    case {read(mcp, {:listed, name}), read(mcp, :store)} do
      {nil, nil} -> nil
      {nil, store} -> WardrikStore.get(store, "tools/" <> name)
      {definitions, _store} -> definitions
    end
  end

  defp read(mcp, key) do
    case :ets.lookup(table(mcp), key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp table(mcp) do
    name = name(mcp)
    if :ets.whereis(name) == :undefined, do: raise(ArgumentError, not_started(mcp))
    name
  end

  defp not_started(mcp) do
    "#{inspect(mcp)} isn't started. Add {WardrikMCP, name: #{inspect(mcp)}, servers: servers} to your supervision tree, ahead of what uses it."
  end

  defp built(name, opts) do
    if Enum.any?(Keyword.values(opts), &is_function/1),
      do: {:error, "a server added as the app runs takes its options as data"},
      else: {:ok, Server.new!(name, opts)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp new(state, name) do
    if Map.has_key?(state.servers, name),
      do: {:error, "#{name} is a server already"},
      else: :ok
  end

  defp kept(%{store: nil}, _name, _opts), do: :ok

  defp kept(%{store: store}, name, opts) do
    with {:ok, _vsn} <- WardrikStore.put(store, "servers/" <> name, opts), do: :ok
  end

  defp forget(%{store: nil}, _name), do: :ok

  defp forget(%{store: store}, name) do
    with :ok <- WardrikStore.delete(store, "servers/" <> name),
         do: WardrikStore.delete(store, "tools/" <> name)
  end

  defp started(%{settings: settings} = state, server) do
    server = %{server | mcp: settings.mcp}

    if server.credential_name == nil, do: connect(settings.mcp, server)
    true = :ets.insert(name(settings.mcp), {{:server, server.name}, server})
    %{state | servers: Map.put(state.servers, server.name, server)}
  end

  defp connect(mcp, server) do
    case DynamicSupervisor.start_child(
           Connection.supervisor(mcp),
           {Connection, {server, nil, nil}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stopped(state, name) do
    :ok = Connection.close(state.settings.mcp, name)
    true = :ets.delete(name(state.settings.mcp), {:server, name})
    true = :ets.delete(name(state.settings.mcp), {:listed, name})
    %{state | servers: Map.delete(state.servers, name)}
  end

  defp reconciled(%{settings: %{store: nil}} = state), do: state

  defp reconciled(%{settings: settings} = state) do
    kept =
      Map.new(
        WardrikStore.keys(settings.store, "servers/"),
        &{String.replace_prefix(&1, "servers/", ""), &1}
      )

    state =
      Enum.reduce(kept, state, fn {name, key}, state ->
        if Map.has_key?(state.servers, name),
          do: state,
          else: started(state, Server.new!(name, WardrikStore.get(settings.store, key)))
      end)

    gone =
      for {name, _server} <- state.servers,
          not MapSet.member?(state.static, name),
          not Map.has_key?(kept, name),
          do: name

    Enum.reduce(gone, state, &stopped(&2, &1))
  end

  defp tick(%{reconcile: :infinity}), do: :ok
  defp tick(%{reconcile: ms}), do: Process.send_after(self(), :reconcile, ms)

  defp name(mcp), do: Module.concat(mcp, "Servers")
end
