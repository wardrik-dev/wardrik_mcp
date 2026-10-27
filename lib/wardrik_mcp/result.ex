defmodule WardrikMCP.Result do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.MCP.Response

  @spec answer({:ok, Response.t()} | {:error, term()}, pos_integer()) ::
          {:ok, term()} | {:error, String.t()}
  def answer({:ok, %Response{is_error: true, result: result}}, limit),
    do: {:error, text(result, limit)}

  def answer({:ok, %Response{result: %{"structuredContent" => structured}}}, _limit)
      when is_map(structured),
      do: {:ok, structured}

  def answer({:ok, %Response{result: result}}, limit), do: {:ok, text(result, limit)}

  def answer({:error, %Error{} = error}, _limit), do: {:error, message(error)}

  def answer({:error, reason}, _limit) when is_binary(reason), do: {:error, reason}
  def answer({:error, reason}, _limit), do: {:error, inspect(reason)}

  @doc "Returns what went wrong, with what the server answered when it refused the request."
  @spec message(Error.t()) :: String.t()
  def message(%Error{message: message, data: %{original_reason: {:http_error, status, body}}}),
    do: "#{message}: HTTP #{status}: #{said(body)}"

  def message(%Error{message: message}), do: message

  @doc "Returns whether `error` may pass if the call is tried again, unlike a request the server refused."
  @spec passing?(Error.t()) :: boolean()
  def passing?(%Error{data: %{original_reason: {:http_error, status, _body}}}),
    do: status not in 400..499

  def passing?(%Error{}), do: true

  defp said(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _other -> body
    end
  end

  defp said(body), do: inspect(body)

  defp text(result, limit) do
    result
    |> Map.get("content", [])
    |> Enum.map_join("\n", &part/1)
    |> cut(limit)
  end

  defp part(%{"type" => "text", "text" => text}), do: text
  defp part(%{"type" => "resource", "resource" => %{"text" => text}}), do: text
  defp part(%{"type" => type}), do: "[A part of type #{type} isn't shown here.]"

  defp cut(text, limit) when byte_size(text) <= limit, do: text

  defp cut(text, limit) do
    kept = text |> binary_part(0, limit) |> String.replace_invalid("")
    kept <> "\n[Cut to #{limit} of #{byte_size(text)} bytes.]"
  end
end
