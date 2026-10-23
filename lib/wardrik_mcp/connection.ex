defmodule WardrikMCP.Connection do
  @moduledoc false
  use GenServer

  require Logger

  alias Anubis.MCP.Response
  alias WardrikMCP.Server
  alias WardrikMCP.Servers
  alias WardrikMCP.Tool

  @first_retry :timer.seconds(1)
  @last_retry :timer.minutes(1)
  @ready :timer.seconds(30)
  @idle :timer.minutes(5)

  @spec child_spec({Server.t(), String.t() | nil, String.t() | nil}) :: Supervisor.child_spec()
  def child_spec({server, who, _token} = args),
    do: %{
      id: {__MODULE__, server.name, who},
      start: {__MODULE__, :start_link, [args]},
      restart: if(who, do: :temporary, else: :permanent)
    }

  @spec start_link({Server.t(), String.t() | nil, String.t() | nil}) :: GenServer.on_start()
  def start_link({server, who, token}) do
    name = {:via, Registry, {registry(server.mcp), {:connection, server.name, who}, hash(token)}}
    GenServer.start_link(__MODULE__, {server, who, token}, name: name)
  end

  @spec registry(atom()) :: atom()
  def registry(mcp), do: Module.concat(mcp, "Registry")

  @spec finch(atom()) :: atom()
  def finch(mcp), do: Module.concat(mcp, "Finch")

  @spec supervisor(atom()) :: atom()
  def supervisor(mcp), do: Module.concat(mcp, "Connections")

  @spec tools(atom(), String.t()) :: [WardrikCore.Tool.t()]
  def tools(mcp, name) do
    case Registry.lookup(registry(mcp), {:tools, name}) do
      [{_pid, tools}] -> tools
      [] -> []
    end
  end

  @spec client(Server.t(), String.t() | nil) :: GenServer.name()
  def client(server, who),
    do: {:via, Registry, {registry(server.mcp), {:client, server.name, who}}}

  @doc """
  Returns the client the principal the turn acts for reaches `server` with, connecting with their
  credential, and again when it changed. A credential the server refuses is reported refused, and
  fetched once more, renewed or signed in to again.
  """
  @spec open(Server.t(), WardrikCore.Context.t()) ::
          {:ok, GenServer.name()} | {:park, WardrikCore.Authorization.t()} | {:error, term()}
  def open(server, context), do: open(server, context, :first)

  @doc "Reports the principal's credential refused, and closes their connection, so the next open fetches it again."
  @spec refuse(Server.t(), WardrikCore.Context.t()) :: :ok
  def refuse(server, context) do
    :ok = WardrikCore.Credentials.refused(context, server.credential_name)

    for {pid, _hash} <-
          Registry.lookup(registry(server.mcp), {:connection, server.name, who(context)}) do
      DynamicSupervisor.terminate_child(supervisor(server.mcp), pid)
    end

    :ok
  end

  @doc "Returns whether `answer` is the server refusing the credential it was reached with."
  @spec refused?(term()) :: boolean()
  def refused?({:error, %Anubis.MCP.Error{data: %{original_reason: reason}}}),
    do: authorization_required?(reason)

  def refused?({:error, reason}), do: authorization_required?(reason)
  def refused?(_answer), do: false

  defp authorization_required?({:authorization_required, _challenge}), do: true
  defp authorization_required?(_reason), do: false

  defp open(server, context, attempt) do
    case WardrikCore.Credentials.fetch(context, server.credential_name) do
      {:ok, token} -> server |> opened(who(context), token) |> retried(server, context, attempt)
      {:park, authorization} -> {:park, authorization}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retried({:error, reason} = refusal, server, context, :first) do
    if refused?(refusal) do
      refuse(server, context)
      open(server, context, :again)
    else
      {:error, reason}
    end
  end

  defp retried(opened, _server, _context, _attempt), do: opened

  @doc "Stops every connection to the server `name`."
  @spec close(atom(), String.t()) :: :ok
  def close(mcp, name) do
    for pid <-
          Registry.select(registry(mcp), [{{{:connection, name, :_}, :"$1", :_}, [], [:"$1"]}]) do
      DynamicSupervisor.terminate_child(supervisor(mcp), pid)
    end

    :ok
  end

  @spec handle_event([atom()], map(), map(), pid()) :: :ok
  def handle_event(_event, _measurements, %{method: "tools/list_changed"}, connection) do
    send(connection, :list_changed)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _connection), do: :ok

  @impl GenServer
  def init({server, who, token}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       server: server,
       who: who,
       token: token,
       client: nil,
       slot: nil,
       retry: @first_retry,
       failure: nil,
       used: 0
     }, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    listen_for_changes(state)
    {:noreply, state |> claimed() |> connect()}
  end

  @impl GenServer
  def handle_call(:ready, _from, %{failure: nil} = state), do: {:reply, :ok, used(state)}

  def handle_call(:ready, _from, %{failure: reason} = state),
    do: {:stop, :normal, {:error, reason}, state}

  @impl GenServer
  def handle_cast(:used, state), do: {:noreply, used(state)}

  @impl GenServer
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info(:list_changed, %{client: nil} = state), do: {:noreply, state}
  def handle_info(:list_changed, state), do: {:noreply, refresh(state)}

  def handle_info({:idle, used}, %{used: used} = state), do: {:stop, :normal, state}
  def handle_info({:idle, _used}, state), do: {:noreply, state}

  def handle_info({:EXIT, client, _reason}, %{client: client, who: who} = state)
      when is_binary(who),
      do: {:stop, :normal, state}

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:noreply, %{state | client: nil} |> offer([]) |> retry_later(reason)}

  def handle_info({:EXIT, _gone, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: :telemetry.detach(handler(state))

  defp opened(server, who, token) do
    registry = registry(server.mcp)

    case Registry.lookup(registry, {:connection, server.name, who}) do
      [{pid, hashed}] -> reopened(server, who, token, pid, hashed == hash(token))
      [] -> started(server, who, token)
    end
  end

  defp reopened(server, who, _token, pid, true) do
    GenServer.cast(pid, :used)
    {:ok, client(server, who)}
  end

  defp reopened(server, who, token, pid, false) do
    DynamicSupervisor.terminate_child(supervisor(server.mcp), pid)
    started(server, who, token)
  end

  defp started(server, who, token) do
    case DynamicSupervisor.start_child(supervisor(server.mcp), {__MODULE__, {server, who, token}}) do
      {:ok, pid} -> ready(server, who, pid)
      {:error, {:already_started, pid}} -> ready(server, who, pid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ready(server, who, pid) do
    case GenServer.call(pid, :ready, @ready + :timer.seconds(5)) do
      :ok -> {:ok, client(server, who)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp claimed(%{server: server} = state) do
    if state.who == nil,
      do: {:ok, _owner} = Registry.register(registry(server.mcp), {:tools, server.name}, [])

    %{state | slot: slot(registry(server.mcp), 0)}
  end

  defp slot(registry, n) do
    case Registry.register(registry, {:slot, n}, nil) do
      {:ok, _owner} -> n
      {:error, {:already_registered, _pid}} -> slot(registry, n + 1)
    end
  end

  defp connect(state) do
    case start_client(state) do
      {:ok, client} -> refresh(%{state | client: client})
      {:error, reason} -> failed(state, reason)
    end
  end

  defp refresh(state) do
    case listed(state) do
      {:ok, definitions} -> %{offer(state, definitions) | retry: @first_retry, failure: nil}
      {:error, reason} -> state |> disconnect() |> failed(reason)
    end
  end

  defp failed(%{who: nil} = state, reason), do: retry_later(state, reason)
  defp failed(state, reason), do: %{state | failure: reason}

  defp start_client(%{server: server, who: who, token: token, slot: slot}) do
    Anubis.Client.start_link(
      name: client(server, who),
      transport_name: {:via, Registry, {registry(server.mcp), {:transport, server.name, who}}},
      transport: Server.transport(server, token),
      client_info: %{
        "name" => "wardrik_mcp #{inspect(server.mcp)} #{slot}",
        "version" => version()
      },
      capabilities: %{}
    )
  end

  defp listed(%{server: server, who: who}) do
    with :ok <- Anubis.Client.await_ready(client(server, who), timeout: @ready) do
      page(client(server, who), [], [])
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp page(client, opts, listed) do
    with {:ok, %Response{result: result}} <- Anubis.Client.list_tools(client, opts) do
      next_page(client, result, listed ++ Map.get(result, "tools", []))
    end
  end

  defp next_page(client, %{"nextCursor" => cursor}, listed) when is_binary(cursor),
    do: page(client, [cursor: cursor], listed)

  defp next_page(_client, _result, listed), do: {:ok, listed}

  defp offer(%{server: server, who: nil} = state, definitions) do
    tools = Tool.offered(server, definitions)
    Registry.update_value(registry(server.mcp), {:tools, server.name}, fn _offered -> tools end)
    told(server, length(tools))
    state
  end

  defp offer(%{server: server} = state, definitions) do
    Servers.listed(server.mcp, server.name, definitions)
    told(server, length(Tool.offered(server, definitions)))
    state
  end

  defp told(server, count),
    do:
      :telemetry.execute([:wardrik_mcp, :tools], %{count: count}, %{
        mcp: server.mcp,
        server: server.name
      })

  defp used(%{who: nil} = state), do: state

  defp used(state) do
    used = state.used + 1
    Process.send_after(self(), {:idle, used}, @idle)
    %{state | used: used}
  end

  defp disconnect(%{client: nil} = state), do: state

  defp disconnect(%{client: client} = state) do
    Supervisor.stop(client)
    %{state | client: nil}
  catch
    :exit, _reason -> %{state | client: nil}
  end

  defp retry_later(%{server: server, retry: retry} = state, reason) do
    Logger.warning(
      "The MCP server #{server.name} is down: #{inspect(reason)}. " <>
        "Trying again in #{div(retry, 1000)}s."
    )

    Process.send_after(self(), :connect, retry)
    %{state | retry: min(retry * 2, @last_retry)}
  end

  defp listen_for_changes(state) do
    :telemetry.attach(
      handler(state),
      [:anubis_mcp, :client, :notification],
      &__MODULE__.handle_event/4,
      self()
    )
  end

  defp handler(%{server: server, who: who}), do: {__MODULE__, server.mcp, server.name, who}

  defp who(context) do
    case WardrikCore.Context.acting_for(context) do
      %WardrikCore.Principal{id: id} -> id
      nil -> ""
    end
  end

  defp hash(nil), do: nil
  defp hash(token), do: :erlang.phash2(token)

  defp version, do: :wardrik_mcp |> Application.spec(:vsn) |> to_string()
end
