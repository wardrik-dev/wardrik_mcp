defmodule WardrikMCP.HTTPStub do
  @moduledoc false
  # An MCP server over HTTP that answers at `path` alone and tells `test` each request's path, and
  # the authorization it was sent.

  def start(test, path) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    pid = spawn_link(fn -> accept(socket, test, path) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    port
  end

  defp accept(socket, test, path) do
    {:ok, client} = :gen_tcp.accept(socket)
    pid = spawn(fn -> serve(client, test, path) end)
    :ok = :gen_tcp.controlling_process(client, pid)
    accept(socket, test, path)
  end

  defp serve(client, test, path) do
    case request(client) do
      {:ok, method, at, authorization, body} ->
        send(test, {:http, method, at})
        if authorization, do: send(test, {:authorization, authorization})
        :gen_tcp.send(client, respond(method, at == path, body))
        serve(client, test, path)

      :closed ->
        :ok
    end
  end

  defp request(client) do
    :ok = :inet.setopts(client, packet: :http_bin)

    case :gen_tcp.recv(client, 0) do
      {:ok, {:http_request, method, {:abs_path, at}, _version}} ->
        {length, authorization} = headers(client, {0, nil})
        :ok = :inet.setopts(client, packet: :raw)
        {:ok, body} = if length > 0, do: :gen_tcp.recv(client, length), else: {:ok, ""}
        {:ok, method, at, authorization, body}

      _closed ->
        :closed
    end
  end

  defp headers(client, {length, authorization} = read) do
    case :gen_tcp.recv(client, 0) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        headers(client, {String.to_integer(value), authorization})

      {:ok, {:http_header, _, :Authorization, _, value}} ->
        headers(client, {length, value})

      {:ok, {:http_header, _, _, _, _}} ->
        headers(client, read)

      {:ok, :http_eoh} ->
        read
    end
  end

  defp respond(_method, false, _body), do: reply(404, "text/plain", "not found")
  defp respond(:POST, true, body), do: body |> JSON.decode!() |> answer()
  defp respond(_method, true, _body), do: reply(202, "text/plain", "")

  defp answer(%{"id" => id, "method" => "initialize", "params" => params}),
    do:
      result(id, %{
        "protocolVersion" => params["protocolVersion"],
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "http", "version" => "1.0.0"}
      })

  defp answer(%{"id" => id, "method" => "tools/list"}),
    do:
      result(id, %{
        "tools" => [
          %{
            "name" => "ping",
            "description" => "Answers.",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      })

  defp answer(%{"id" => id}), do: result(id, %{})
  defp answer(_notification), do: reply(202, "text/plain", "")

  defp result(id, result),
    do:
      reply(
        200,
        "application/json",
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
      )

  defp reply(status, type, body),
    do:
      "HTTP/1.1 #{status} OK\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
        body
end
