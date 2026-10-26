defmodule WardrikMCP.Tool do
  @moduledoc false

  alias WardrikCore.Context
  alias WardrikMCP.Connection
  alias WardrikMCP.Result
  alias WardrikMCP.Server

  @hints [
    {"readOnlyHint", :read_only},
    {"destructiveHint", :destructive},
    {"idempotentHint", :idempotent},
    {"openWorldHint", :open_world}
  ]

  @margin :timer.seconds(1)

  @spec offered(Server.t(), [map()]) :: [WardrikCore.Tool.t()]
  def offered(server, definitions) do
    definitions
    |> Enum.filter(fn definition -> Server.offers?(server, definition["name"]) end)
    |> Enum.map(&new(server, &1))
  end

  @spec new(Server.t(), map()) :: WardrikCore.Tool.t()
  def new(%Server{} = server, %{"name" => name} = definition) do
    WardrikCore.Tool.new!(
      name: "#{Server.prefix(server)}__#{name}",
      description: Map.get(definition, "description", name),
      schema: Map.get(definition, "inputSchema", %{"type" => "object"}),
      run: fn arguments, context -> call(server, name, arguments, context) end,
      annotations: annotations(server, name, hints(definition))
    )
  end

  @doc "The one tool a server offers before anyone has reached it with their credential: connecting."
  @spec connect(Server.t()) :: WardrikCore.Tool.t()
  def connect(%Server{} = server) do
    WardrikCore.Tool.new!(
      name: "#{Server.prefix(server)}__connect",
      description:
        "Connects to #{server.name} as whoever you act for, signing in first if they must. Its tools come with the next turn.",
      schema: %{"type" => "object", "properties" => %{}},
      run: fn _arguments, context -> connected(server, context) end,
      annotations: [read_only: true, idempotent: true]
    )
  end

  defp annotations(server, name, hints) do
    [
      timeout: server.timeout + @margin,
      gated: Server.gated?(server, name, Keyword.get(hints, :read_only, false)),
      labels: Server.labels(server)
    ] ++ hints
  end

  defp hints(%{"annotations" => %{} = given}) do
    @hints
    |> Enum.flat_map(fn {hint, annotation} -> hint(given, hint, annotation) end)
    |> read_only_is_idempotent()
  end

  defp hints(_definition), do: []

  defp hint(given, hint, annotation) do
    case Map.fetch(given, hint) do
      {:ok, value} -> [{annotation, value == true}]
      :error -> []
    end
  end

  defp read_only_is_idempotent(annotations) do
    if annotations[:read_only],
      do: Keyword.put(annotations, :idempotent, true),
      else: annotations
  end

  defp call(server, name, arguments, context),
    do: call(server, name, arguments, context, :first)

  defp call(server, name, arguments, context, attempt) do
    case client(server, context) do
      {:ok, client} ->
        server
        |> called(client, name, arguments)
        |> refused(server, name, arguments, context, attempt)

      {:park, authorization} ->
        {:park, authorization}

      {:error, reason} ->
        {:error, "The MCP server #{server.name} isn't connected: #{inspect(reason)}"}
    end
  end

  defp refused(called, %Server{credential_name: name} = server, tool, arguments, context, :first)
       when is_binary(name) do
    if Connection.refused?(called) do
      Connection.refuse(server, context)
      call(server, tool, arguments, context, :again)
    else
      answered(server, called, context)
    end
  end

  defp refused(called, server, _tool, _arguments, context, _attempt),
    do: answered(server, called, context)

  defp connected(server, context) do
    case Connection.open(server, context) do
      {:ok, _client} -> {:ok, "Connected to #{server.name}. Its tools come with the next turn."}
      {:park, authorization} -> {:park, authorization}
      {:error, reason} -> {:error, "#{server.name} didn't connect: #{inspect(reason)}"}
    end
  end

  defp client(%Server{credential_name: nil} = server, _context),
    do: {:ok, Connection.client(server, nil)}

  defp client(server, context), do: Connection.open(server, context)

  defp answered(server, called, context) do
    {tag, output} = Result.answer(called, server.max_result_bytes)
    {tag, output, Context.measure(context, cost(server.cost, called))}
  end

  defp called(server, client, name, arguments) do
    Anubis.Client.call_tool(client, name, arguments, timeout: server.timeout)
  catch
    :exit, _reason -> {:error, "The MCP server #{server.name} isn't connected."}
  end

  defp cost(nil, _called), do: %{}
  defp cost(fixed, {:ok, _response}) when is_list(fixed), do: Map.new(fixed)
  defp cost(cost, {:ok, response}) when is_function(cost, 1), do: cost.(response.result)
  defp cost(_cost, {:error, _reason}), do: %{}
end
