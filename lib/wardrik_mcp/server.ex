defmodule WardrikMCP.Server do
  @moduledoc """
  A server is an MCP server an agent's tools come from, and how to reach it.

  | Key | Takes | Unless set |
  | --- | --- | --- |
  | `transport` | `{:stdio, command: "…", args: […], env: %{…}}` or `{:streamable_http, base_url: "…", headers: %{…}}` | required |
  | `only` | the server's own tool names to offer, as `["search_issues"]` | every tool |
  | `except` | the server's own tool names to leave out | none |
  | `prefix` | what its tools are named under, as `linear` for `linear__search_issues` | its name |
  | `credential` | the credential each principal reaches it with, as their own | none |
  | `credential_header`, `credential_scheme` | where the credential goes over HTTP | `authorization`, `Bearer` |
  | `credential_env` | the variable the credential goes in, for a command | none |
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
    :prefix,
    :credential,
    :credential_env,
    :cost,
    :mcp,
    credential_header: "authorization",
    credential_scheme: "Bearer",
    timeout: :timer.seconds(60),
    max_result_bytes: 128 * 1024
  ]

  @type cost() :: keyword(number()) | (map() -> %{optional(atom()) => number()})

  @type t() :: %__MODULE__{
          name: String.t(),
          transport: {:stdio | :streamable_http, keyword()},
          only: [String.t()] | nil,
          except: [String.t()] | nil,
          prefix: String.t() | nil,
          credential: String.t() | nil,
          credential_env: String.t() | nil,
          credential_header: String.t(),
          credential_scheme: String.t(),
          cost: cost() | nil,
          mcp: atom() | nil,
          timeout: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @options [
    :transport,
    :only,
    :except,
    :prefix,
    :credential,
    :credential_env,
    :cost,
    credential_header: "authorization",
    credential_scheme: "Bearer",
    timeout: :timer.seconds(60),
    max_result_bytes: 128 * 1024
  ]

  @doc "Builds a server named `name` from its options. Raises on an option it doesn't know."
  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(name, opts) do
    opts = Keyword.validate!(opts, @options)

    struct!(
      __MODULE__,
      [name: to_string(name), transport: Keyword.fetch!(opts, :transport)] ++ opts
    )
  end

  @doc "Says whether the server offers its tool `name` to agents."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{only: only, except: except}, name),
    do: listed?(only, name, true) and not listed?(except, name, false)

  @doc "Returns what the server's tools are named under."
  @spec prefix(t()) :: String.t()
  def prefix(%__MODULE__{prefix: nil, name: name}), do: name
  def prefix(%__MODULE__{prefix: prefix}), do: prefix

  @doc "Returns the transport that reaches the server with `token`, the credential of whoever calls it."
  @spec transport(t(), String.t() | nil) :: {:stdio | :streamable_http, keyword()}
  def transport(%__MODULE__{transport: transport}, nil), do: transport

  def transport(%__MODULE__{transport: {:streamable_http, opts}} = server, token) do
    value = String.trim("#{server.credential_scheme} #{token}")

    {:streamable_http,
     Keyword.update(
       opts,
       :headers,
       %{server.credential_header => value},
       &Map.put(&1, server.credential_header, value)
     )}
  end

  def transport(%__MODULE__{transport: {:stdio, opts}, credential_env: env}, token)
      when is_binary(env),
      do: {:stdio, Keyword.update(opts, :env, %{env => token}, &Map.put(&1, env, token))}

  def transport(%__MODULE__{transport: transport}, _token), do: transport

  defp listed?(nil, _name, unset), do: unset
  defp listed?(names, name, _unset), do: name in names
end
