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

  @spec new(Server.t(), map()) :: WardrikCore.Tool.t()
  def new(%Server{} = server, %{"name" => name} = definition) do
    WardrikCore.Tool.new!(
      name: "#{server.name}__#{name}",
      description: Map.get(definition, "description", name),
      schema: Map.get(definition, "inputSchema", %{"type" => "object"}),
      run: fn arguments, context -> call(server, name, arguments, context) end,
      annotations: [timeout: server.timeout + @margin] ++ hints(definition)
    )
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

  defp call(server, name, arguments, context) do
    called = called(server, name, arguments)
    {tag, output} = Result.answer(called, server.max_result_bytes)
    {tag, output, Context.measure(context, cost(server.cost, called))}
  end

  defp called(server, name, arguments) do
    server.name
    |> Connection.client()
    |> Anubis.Client.call_tool(name, arguments, timeout: server.timeout)
  catch
    :exit, _reason -> {:error, "The MCP server #{server.name} isn't connected."}
  end

  defp cost(nil, _called), do: %{}
  defp cost(fixed, {:ok, _response}) when is_list(fixed), do: Map.new(fixed)
  defp cost(cost, {:ok, response}) when is_function(cost, 1), do: cost.(response.result)
  defp cost(_cost, {:error, _reason}), do: %{}
end
