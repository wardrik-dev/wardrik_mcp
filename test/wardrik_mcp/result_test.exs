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
end
