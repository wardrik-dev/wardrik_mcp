defmodule StubServer do
  @tools [
    %{
      "name" => "echo",
      "description" => "Hands the value back.",
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    },
    %{
      "name" => "boom",
      "description" => "Answers with a tool error.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "charge",
      "description" => "Charges a card, and says what it cost.",
      "annotations" => %{"readOnlyHint" => false, "destructiveHint" => true},
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "report",
      "description" => "Answers with structured content.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "big",
      "description" => "Answers with a lot of text.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "slow",
      "description" => "Never answers.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "grow",
      "description" => "Gains a tool, and says its list changed.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @whoami %{
    "name" => "whoami",
    "description" => "Says the token it was started with.",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  }

  @env %{
    "name" => "env",
    "description" => "Says the environment it was started with.",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  }

  @grown %{
    "name" => "grown",
    "description" => "The tool grow added.",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  }

  def run(grown \\ false) do
    case IO.read(:stdio, :line) do
      :eof -> System.halt(0)
      {:error, _reason} -> System.halt(0)
      line -> line |> String.trim() |> handle(grown) |> run()
    end
  end

  defp handle("", grown), do: grown
  defp handle(line, grown), do: line |> JSON.decode!() |> respond(grown)

  defp respond(%{"method" => "initialize", "id" => id, "params" => params}, grown) do
    reply(id, %{
      "protocolVersion" => params["protocolVersion"],
      "capabilities" => %{"tools" => %{"listChanged" => true}},
      "serverInfo" => %{"name" => "stub", "version" => "1.0.0"}
    })

    grown
  end

  defp respond(%{"method" => "tools/list", "id" => id}, grown) do
    reply(id, %{
      "tools" => if(grown, do: @tools ++ [@whoami, @env, @grown], else: @tools ++ [@whoami, @env])
    })

    grown
  end

  defp respond(%{"method" => "tools/call", "id" => id, "params" => params}, grown),
    do: called(params["name"], params["arguments"] || %{}, id, grown)

  defp respond(%{"method" => "ping", "id" => id}, grown) do
    reply(id, %{})
    grown
  end

  defp respond(%{"id" => id, "method" => method}, grown) do
    send_message(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => method}
    })

    grown
  end

  defp respond(_notification, grown), do: grown

  defp called("echo", arguments, id, grown), do: text(id, arguments["value"], grown)

  defp called("whoami", _arguments, id, grown),
    do: text(id, System.get_env("STUB_TOKEN", "nobody"), grown)

  defp called("env", _arguments, id, grown),
    do: text(id, JSON.encode!(System.get_env()), grown)

  defp called("big", _arguments, id, grown), do: text(id, String.duplicate("é", 1000), grown)
  defp called("slow", _arguments, _id, grown), do: grown

  defp called("boom", _arguments, id, grown) do
    reply(id, %{
      "content" => [%{"type" => "text", "text" => "the tool refused"}],
      "isError" => true
    })

    grown
  end

  defp called("charge", _arguments, id, grown) do
    reply(id, %{
      "content" => [%{"type" => "text", "text" => "charged"}],
      "_meta" => %{"usd" => 0.25}
    })

    grown
  end

  defp called("report", _arguments, id, grown) do
    reply(id, %{
      "content" => [%{"type" => "text", "text" => "{\"open\":3}"}],
      "structuredContent" => %{"open" => 3}
    })

    grown
  end

  defp called("grow", _arguments, id, _grown) do
    text(id, "grown", true)
    send_message(%{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"})
    true
  end

  defp text(id, text, grown) do
    reply(id, %{"content" => [%{"type" => "text", "text" => text}]})
    grown
  end

  defp reply(id, result), do: send_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp send_message(message) do
    IO.puts(JSON.encode!(message))
  rescue
    ErlangError -> System.halt(0)
  end
end

StubServer.run()
