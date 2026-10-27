defmodule WardrikMCP.ConnectionTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias WardrikMCP.Connection

  test "a refused credential is told apart, however the client names it" do
    for reason <- [{:authorization_required, %{}}, {:http_error, 401, ""}, {:http_error, 403, ""}] do
      assert Connection.refused?(
               {:error, Error.transport(:send_failure, %{original_reason: reason})}
             )

      assert Connection.refused?({:error, reason})
    end

    refute Connection.refused?({:error, {:http_error, 400, ""}})
    refute Connection.refused?({:error, :closed})
    refute Connection.refused?({:ok, %{}})
  end
end
