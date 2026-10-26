defmodule WardrikMCP.Server do
  @moduledoc """
  A server is an MCP server an agent's tools come from, and how to reach it.

  | Key | Takes | Unless set |
  | --- | --- | --- |
  | `transport` | `{:stdio, command: "…", args: […], env: %{…}}` or `{:streamable_http, base_url: "…", headers: %{…}}` | required |
  | `only` | the server's own tool names to offer, as `["search_issues"]` | every tool |
  | `except` | the server's own tool names to leave out | none |
  | `prefix` | what its tools are named under, as `linear` for `linear__search_issues` | its name |
  | `credential_name` | the name each principal's own credential for it is held under | none |
  | `credential_header`, `credential_scheme` | where the credential goes over HTTP | `authorization`, `Bearer` |
  | `credential_env` | the variable the credential goes in, for a command | none |
  | `timeout` | how long a call may take, in milliseconds | 60 seconds |
  | `max_result_bytes` | how much of a result the model gets | 128 KB |
  | `cost` | what each call costs, as `[usd: 0.001]`, or a function of the server's result | nothing |
  | `gated` | which tools can change something, so a person must allow their calls: `true`, `false`, or the server's own tool names, as `["create_*"]` | those it doesn't mark read-only |
  | `trusted` | `true` where its answers are the deployment's own, so they aren't labelled `"outside"` | `false` |
  """

  @enforce_keys [:name, :transport]
  defstruct [
    :name,
    :transport,
    :only,
    :except,
    :prefix,
    :credential_name,
    :credential_env,
    :cost,
    :mcp,
    :gated,
    trusted: false,
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
          credential_name: String.t() | nil,
          credential_env: String.t() | nil,
          credential_header: String.t(),
          credential_scheme: String.t(),
          cost: cost() | nil,
          mcp: atom() | nil,
          gated: boolean() | [String.t()] | nil,
          trusted: boolean(),
          timeout: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @options [
    :transport,
    :only,
    :except,
    :prefix,
    :credential_name,
    :credential_env,
    :cost,
    :gated,
    trusted: false,
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

  @doc "Says whether the server's tool `name`, `read_only` or not, can change something a person must allow."
  @spec gated?(t(), String.t(), boolean()) :: boolean()
  def gated?(%__MODULE__{gated: nil}, _name, read_only), do: not read_only
  def gated?(%__MODULE__{gated: gated}, _name, _read_only) when is_boolean(gated), do: gated
  def gated?(%__MODULE__{gated: names}, name, _read_only), do: Enum.any?(names, &glob?(&1, name))

  @doc "Returns the labels every answer of the server holds: `[\"outside\"]` unless it's trusted."
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{trusted: true}), do: []
  def labels(%__MODULE__{trusted: false}), do: ["outside"]

  @doc "Returns what the server's tools are named under."
  @spec prefix(t()) :: String.t()
  def prefix(%__MODULE__{prefix: nil, name: name}), do: name
  def prefix(%__MODULE__{prefix: prefix}), do: prefix

  @doc "Returns the transport that reaches the server with `token`, the credential of whoever calls it."
  @spec transport(t(), String.t() | nil) :: {:stdio | :streamable_http, keyword()}
  def transport(%__MODULE__{transport: {:streamable_http, opts}} = server, token),
    do: {:streamable_http, opts |> pooled(server.mcp) |> credentialed(server, token)}

  def transport(%__MODULE__{transport: transport}, nil), do: transport

  def transport(%__MODULE__{transport: {:stdio, opts}, credential_env: env}, token)
      when is_binary(env),
      do: {:stdio, Keyword.update(opts, :env, %{env => token}, &Map.put(&1, env, token))}

  def transport(%__MODULE__{transport: transport}, _token), do: transport

  defp pooled(opts, nil), do: opts
  defp pooled(opts, mcp), do: Keyword.put_new(opts, :finch_name, WardrikMCP.Connection.finch(mcp))

  defp credentialed(opts, _server, nil), do: opts

  defp credentialed(opts, server, token) do
    value = String.trim("#{server.credential_scheme} #{token}")

    Keyword.update(
      opts,
      :headers,
      %{server.credential_header => value},
      &Map.put(&1, server.credential_header, value)
    )
  end

  defp glob?(glob, name) do
    pattern = glob |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.match?(~r/\A#{pattern}\z/, name)
  end

  defp listed?(nil, _name, unset), do: unset
  defp listed?(names, name, _unset), do: name in names
end
