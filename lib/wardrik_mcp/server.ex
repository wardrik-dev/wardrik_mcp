defmodule WardrikMCP.Server do
  @moduledoc """
  A server is an MCP server an agent's tools come from, and how to reach it.

  | Key | Takes | Unless set |
  | --- | --- | --- |
  | `transport` | `{:stdio, command: "…", args: […], env: %{…}}` or `{:streamable_http, base_url: "…", headers: %{…}}` | required |
  | `only` | the server's own tool names to offer, as `["search_issues"]` | every tool |
  | `except` | the server's own tool names to leave out | none |
  | `timeout` | how long a call may take, in milliseconds | 60 seconds |
  | `max_result_bytes` | how much of a result the model gets | 128 KB |
  | `cost` | what each call costs, as `[usd: 0.001]`, or a function of the server's result | nothing |
  """

  @enforce_keys [:name, :transport]
  defstruct [
    :name,
    :transport,
    :only,
    :except,
    :cost,
    :mcp,
    timeout: :timer.seconds(60),
    max_result_bytes: 128 * 1024
  ]

  @type cost() :: keyword(number()) | (map() -> %{optional(atom()) => number()})

  @type t() :: %__MODULE__{
          name: atom(),
          transport: {:stdio | :streamable_http, keyword()},
          only: [String.t()] | nil,
          except: [String.t()] | nil,
          cost: cost() | nil,
          mcp: atom() | nil,
          timeout: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @doc "Builds a server named `name` from its options. Raises on an option it doesn't know."
  @spec new!(atom(), keyword()) :: t()
  def new!(name, opts) when is_atom(name) do
    opts =
      Keyword.validate!(opts, [
        :transport,
        :only,
        :except,
        :cost,
        timeout: :timer.seconds(60),
        max_result_bytes: 128 * 1024
      ])

    struct!(__MODULE__, [name: name, transport: Keyword.fetch!(opts, :transport)] ++ opts)
  end

  @doc "Says whether the server offers its tool `name` to agents."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{only: only, except: except}, name),
    do: listed?(only, name, true) and not listed?(except, name, false)

  defp listed?(nil, _name, unset), do: unset
  defp listed?(names, name, _unset), do: name in names
end
