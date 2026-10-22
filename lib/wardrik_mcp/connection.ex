defmodule WardrikMCP.Connection do
  @moduledoc false
  use GenServer

  require Logger

  alias Anubis.MCP.Response
  alias WardrikMCP.Server
  alias WardrikMCP.Tool

  @registry WardrikMCP.Registry
  @first_retry :timer.seconds(1)
  @last_retry :timer.minutes(1)
  @ready :timer.seconds(30)

  @spec child_spec(Server.t()) :: Supervisor.child_spec()
  def child_spec(%Server{name: name} = server),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [server]}}

  @spec start_link(Server.t()) :: GenServer.on_start()
  def start_link(%Server{name: name} = server),
    do: GenServer.start_link(__MODULE__, server, name: {:via, Registry, {@registry, name, []}})

  @spec tools(atom()) :: [WardrikCore.Tool.t()]
  def tools(name) do
    case Registry.lookup(@registry, name) do
      [{_pid, tools}] -> tools
      [] -> []
    end
  end

  @spec client(atom()) :: GenServer.name()
  def client(name), do: via({name, :client})

  @spec handle_event([atom()], map(), map(), pid()) :: :ok
  def handle_event(_event, _measurements, %{method: "tools/list_changed"}, connection) do
    send(connection, :list_changed)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _connection), do: :ok

  @impl GenServer
  def init(%Server{} = server) do
    Process.flag(:trap_exit, true)
    listen_for_changes(server)
    {:ok, %{server: server, client: nil, retry: @first_retry}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info(:list_changed, %{client: nil} = state), do: {:noreply, state}
  def handle_info(:list_changed, state), do: {:noreply, refresh(state)}

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:noreply, %{state | client: nil} |> offer([]) |> retry_later(reason)}

  def handle_info({:EXIT, _gone, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{server: server}), do: :telemetry.detach(handler(server))

  defp connect(%{server: server} = state) do
    case start_client(server) do
      {:ok, client} -> refresh(%{state | client: client})
      {:error, reason} -> retry_later(state, reason)
    end
  end

  defp refresh(%{server: server} = state) do
    case listed(server) do
      {:ok, definitions} -> %{offer(state, definitions) | retry: @first_retry}
      {:error, reason} -> state |> disconnect() |> retry_later(reason)
    end
  end

  defp start_client(%Server{name: name, transport: transport}) do
    Anubis.Client.start_link(
      name: client(name),
      transport_name: via({name, :transport}),
      transport: transport,
      client_info: %{"name" => "wardrik_mcp_#{name}", "version" => version()},
      capabilities: %{}
    )
  end

  defp listed(%Server{name: name}) do
    with :ok <- Anubis.Client.await_ready(client(name), timeout: @ready) do
      page(client(name), [], [])
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

  defp offer(%{server: server} = state, definitions) do
    tools =
      definitions
      |> Enum.filter(fn definition -> Server.offers?(server, definition["name"]) end)
      |> Enum.map(&Tool.new(server, &1))

    Registry.update_value(@registry, server.name, fn _offered -> tools end)
    :telemetry.execute([:wardrik_mcp, :tools], %{count: length(tools)}, %{server: server.name})
    state
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

  defp listen_for_changes(server) do
    :telemetry.attach(
      handler(server),
      [:anubis_mcp, :client, :notification],
      &__MODULE__.handle_event/4,
      self()
    )
  end

  defp handler(server), do: {__MODULE__, server.name}

  defp via(key), do: {:via, Registry, {@registry, key}}

  defp version, do: :wardrik_mcp |> Application.spec(:vsn) |> to_string()
end
