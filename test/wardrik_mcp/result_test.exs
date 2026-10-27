defmodule WardrikMCP.ResultTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.MCP.Response
  alias WardrikMCP.Result

  test "joins the text of each part, and says what it can't show" do
    content = [
      %{"type" => "text", "text" => "one"},
      %{"type" => "resource", "resource" => %{"text" => "two"}},
      %{"type" => "image", "data" => "…"}
    ]

    assert {:ok, "one\ntwo\n[A part of type image isn't shown here.]"} =
             Result.answer({:ok, %Response{result: %{"content" => content}}}, 1024)
  end

  test "answers a protocol error with its message" do
    assert {:error, "Method not found"} =
             Result.answer({:error, %Error{code: -32_601, message: "Method not found"}}, 1024)

    assert {:error, ":closed"} = Result.answer({:error, :closed}, 1024)
  end

  test "answers a refused request with what the server said, and doesn't call it passing" do
    body =
      ~s({"jsonrpc":"2.0","id":"1","error":{"code":-32020,"message":"missing Mcp-Param-owner header"}})

    error = Error.transport(:send_failure, %{original_reason: {:http_error, 400, body}})

    assert {:error, "Send Failure: HTTP 400: missing Mcp-Param-owner header"} =
             Result.answer({:error, error}, 1024)

    refute Result.passing?(error)

    assert Result.passing?(
             Error.transport(:send_failure, %{original_reason: {:http_error, 503, ""}})
           )
  end
end
