defmodule WardrikMCP.Server do
  @moduledoc """
  An MCP server and how to reach it.

      github: [
        transport: {:stdio, command: "github-mcp-server", args: ["stdio"], env: %{}},
        only: ["search_issues", "create_issue"],
        gated: ["create_*"]
      ]

      linear: [
        transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp", headers: %{}},
        credential_name: "linear"
      ]

  ## Options

    * `:transport` - required. `{:stdio, command: ..., args: ..., env: ...}` or
      `{:streamable_http, base_url: ..., headers: ...}`.
    * `:only` - the server's tool names to offer, as `["search_issues"]`. Every tool unless set.
    * `:except` - the server's tool names to leave out.
    * `:prefix` - the prefix for tool names, as `"linear"` for `linear__search_issues`. The
      server's name unless set.
    * `:credential_name` - the credential each principal reaches the server with. See
      `WardrikCore.Credentials`.
    * `:credential_header` - the HTTP header the credential goes in. `"authorization"` unless set.
    * `:credential_scheme` - the scheme before the credential. `"Bearer"` unless set.
    * `:credential_env` - the environment variable the credential goes in, for a command.
    * `:timeout` - milliseconds a call may take. `60_000` unless set.
    * `:max_result_bytes` - bytes of a result the model gets. `131_072` unless set.
    * `:cost` - each call's cost, as `[usd: 0.001]`, or a function of the server's result.
    * `:gated` - which tools need a person's approval: `true`, `false`, or tool name globs, as
      `["create_*"]`. Tools not marked read-only unless set.
    * `:trusted` - `true` to treat answers as the deployment's own, not labelled `"outside"`.
      `false` unless set.
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
    :check,
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
          check: (String.t() -> :ok | {:error, String.t()}) | nil,
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

  @doc "Builds a server named `name`. Raises `ArgumentError` on an unknown option."
  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(name, opts) do
    opts = Keyword.validate!(opts, @options)

    struct!(
      __MODULE__,
      [name: to_string(name), transport: Keyword.fetch!(opts, :transport)] ++ opts
    )
  end

  @doc """
  Returns `:ok` if the server may be reached now, or `{:error, reason}`.

  Always `:ok` without a `check`. With one, a command is refused and the URL must pass it.
  """
  @spec reachable(t()) :: :ok | {:error, String.t()}
  def reachable(%__MODULE__{check: nil}), do: :ok

  def reachable(%__MODULE__{transport: {:stdio, _opts}}),
    do: {:error, "a server added as the app runs is reached over HTTP"}

  def reachable(%__MODULE__{transport: {:streamable_http, opts}, check: check}) do
    url = Keyword.fetch!(opts, :base_url)

    case check.(url) do
      :ok -> :ok
      {:error, why} -> {:error, "#{url} can't be reached: #{why}"}
    end
  end

  @doc "Returns whether the server offers its tool `name`, given `only` and `except`."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{only: only, except: except}, name),
    do: listed?(only, name, true) and not listed?(except, name, false)

  @doc "Returns whether calls to the tool `name` need a person's approval."
  @spec gated?(t(), String.t(), boolean()) :: boolean()
  def gated?(%__MODULE__{gated: nil}, _name, read_only), do: not read_only
  def gated?(%__MODULE__{gated: gated}, _name, _read_only) when is_boolean(gated), do: gated
  def gated?(%__MODULE__{gated: names}, name, _read_only), do: Enum.any?(names, &glob?(&1, name))

  @doc "Returns the labels on the server's answers: `[\"outside\"]`, or `[]` if it's trusted."
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{trusted: true}), do: []
  def labels(%__MODULE__{trusted: false}), do: ["outside"]

  @doc "Returns the prefix for the server's tool names."
  @spec prefix(t()) :: String.t()
  def prefix(%__MODULE__{prefix: nil, name: name}), do: name
  def prefix(%__MODULE__{prefix: prefix}), do: prefix

  @doc "Returns the transport options for reaching the server with the caller's `token`."
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
