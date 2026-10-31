defmodule WardrikMCP.Server do
  @inherited ~w(HOME LANG LC_ALL LOGNAME PATH SHELL TERM TMPDIR USER)

  @secret {:tuple, [{:in, [:secret]}, :string]}

  @http NimbleOptions.new!(
          url: [type: :string, required: true],
          headers: [
            type: {:map, :string, {:or, [:string, @secret, {:list, {:or, [:string, @secret]}}]}},
            default: %{}
          ]
        )

  @stdio NimbleOptions.new!(
           command: [type: :string, required: true],
           args: [type: {:list, :string}, default: []],
           env: [type: {:map, :string, :string}, default: %{}]
         )

  @schema NimbleOptions.new!(
            transport: [
              type: {:custom, __MODULE__, :transport, []},
              required: true,
              doc: """
              `{:stdio, command: ..., args: ..., env: ...}` or
              `{:streamable_http, url: ..., headers: ...}`. The `url` is the server's endpoint, as
              it publishes it, as `"https://mcp.linear.app/mcp"`. A command gets its `env` and only
              these of the app's own variables: #{Enum.map_join(@inherited, ", ", &"`#{&1}`")}.
              It's started through `env`, which unsets the rest.

              A header's value is a string, `{:secret, name}`, or a list of both, as
              `["Bearer ", {:secret, "LINEAR_TOKEN"}]`. A secret is read with `WardrikMCP`'s
              `:secret` each time the server connects.
              """
            ],
            owner: [
              type: :string,
              doc: "Whose secrets its headers name. `WardrikMCP`'s `:secret` is given it."
            ],
            only: [
              type: {:list, :string},
              doc:
                "The server's tool names to offer, as `[\"search_issues\"]`. Every tool unless set."
            ],
            except: [type: {:list, :string}, doc: "The server's tool names to leave out."],
            prefix: [
              type: :string,
              doc: """
              The prefix for tool names, as `"linear"` for `linear__search_issues`. The server's
              name unless set.
              """
            ],
            credential_name: [
              type: :string,
              doc: """
              The credential each principal reaches the server with. See
              `WardrikCore.Credentials`.
              """
            ],
            credential_header: [
              type: :string,
              default: "authorization",
              doc: "The HTTP header the credential goes in."
            ],
            credential_scheme: [
              type: :string,
              default: "Bearer",
              doc: "The scheme before the credential."
            ],
            credential_env: [
              type: :string,
              doc: "The environment variable the credential goes in, for a command."
            ],
            timeout: [
              type: :pos_integer,
              default: :timer.seconds(60),
              doc: "Milliseconds a call may take."
            ],
            max_result_bytes: [
              type: :pos_integer,
              default: 128 * 1024,
              doc: "Bytes of a result the model gets."
            ],
            cost: [
              type: {:or, [:keyword_list, {:fun, 1}]},
              doc: "Each call's cost, as `[usd: 0.001]`, or a function of the server's result."
            ],
            gated: [
              type: {:or, [:boolean, {:list, :string}]},
              doc: """
              Which tools need a person's approval: `true`, `false`, or tool name globs, as
              `["create_*"]`. Tools not marked read-only unless set.
              """
            ],
            trusted: [
              type: :boolean,
              default: false,
              doc: "`true` treats answers as the deployment's own, not labelled `\"outside\"`."
            ]
          )

  @moduledoc """
  An MCP server and how to reach it.

      github: [
        transport: {:stdio, command: "github-mcp-server", args: ["stdio"], env: %{}},
        only: ["search_issues", "create_issue"],
        gated: ["create_*"]
      ]

      linear: [
        transport: {:streamable_http, url: "https://mcp.linear.app/mcp", headers: %{}},
        credential_name: "linear"
      ]

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @enforce_keys [:name, :transport]
  defstruct [
    :name,
    :transport,
    :only,
    :except,
    :prefix,
    :owner,
    :credential_name,
    :credential_env,
    :cost,
    :mcp,
    :gated,
    :check,
    :secret,
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
          owner: String.t() | nil,
          credential_name: String.t() | nil,
          credential_env: String.t() | nil,
          credential_header: String.t(),
          credential_scheme: String.t(),
          cost: cost() | nil,
          mcp: atom() | nil,
          gated: boolean() | [String.t()] | nil,
          check: (String.t() -> :ok | {:error, String.t()}) | nil,
          secret: (String.t() | nil, String.t() -> {:ok, String.t()} | {:error, term()}) | nil,
          trusted: boolean(),
          timeout: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @doc "Builds a server named `name`. Raises `NimbleOptions.ValidationError` on invalid options."
  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(name, opts),
    do: struct!(__MODULE__, [name: to_string(name)] ++ NimbleOptions.validate!(opts, @schema))

  @doc false
  def transport({:streamable_http, opts}) do
    with {:ok, opts} <- options(opts, @http) do
      case URI.new(opts[:url]) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ~w(http https) and host not in [nil, ""] ->
          {:ok, {:streamable_http, opts}}

        _invalid ->
          {:error, "a server over HTTP needs an http or https :url, got: #{inspect(opts[:url])}"}
      end
    end
  end

  def transport({:stdio, opts}) do
    with {:ok, opts} <- options(opts, @stdio), do: {:ok, {:stdio, opts}}
  end

  def transport(other),
    do: {:error, "expected {:stdio, opts} or {:streamable_http, opts}, got: #{inspect(other)}"}

  defp options(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, %NimbleOptions.ValidationError{message: message}} -> {:error, message}
    end
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
    url = Keyword.fetch!(opts, :url)

    case check.(url) do
      :ok -> :ok
      {:error, why} -> {:error, "#{url} can't be reached: #{why}"}
    end
  end

  @doc """
  Returns the server with each secret its headers name read, or `{:error, reason}` for the first
  that can't be.
  """
  @spec resolved(t()) :: {:ok, t()} | {:error, String.t()}
  def resolved(%__MODULE__{transport: {:streamable_http, opts}} = server) do
    headers = opts[:headers]

    named =
      for {_header, value} <- headers, {:secret, name} <- List.wrap(value), uniq: true, do: name

    with {:ok, secrets} <- read(server, named) do
      headers =
        Map.new(headers, fn {header, value} ->
          {header, Enum.map_join(List.wrap(value), &Map.get(secrets, &1, &1))}
        end)

      {:ok, %{server | transport: {:streamable_http, Keyword.put(opts, :headers, headers)}}}
    end
  end

  def resolved(server), do: {:ok, server}

  @doc "Returns whether the server's headers name the secret `name`."
  @spec names?(t(), String.t()) :: boolean()
  def names?(%__MODULE__{transport: {:streamable_http, opts}}, name),
    do: Enum.any?(opts[:headers], fn {_header, value} -> {:secret, name} in List.wrap(value) end)

  def names?(_server, _name), do: false

  defp read(server, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, read} ->
      case secret(server, name) do
        {:ok, value} -> {:cont, {:ok, Map.put(read, {:secret, name}, value)}}
        {:error, reason} -> {:halt, {:error, "the secret #{name} can't be read: #{reason}"}}
      end
    end)
  end

  defp secret(%__MODULE__{secret: nil}, _name), do: {:error, "WardrikMCP was given no :secret"}

  defp secret(%__MODULE__{secret: secret, owner: owner}, name) do
    case secret.(owner, name) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:error, reason} -> {:error, inspect(reason)}
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
    do:
      {:streamable_http, opts |> endpoint() |> pooled(server.mcp) |> credentialed(server, token)}

  def transport(%__MODULE__{transport: {:stdio, opts}, credential_env: env}, token)
      when is_binary(env) and is_binary(token),
      do:
        {:stdio,
         opts |> Keyword.update(:env, %{env => token}, &Map.put(&1, env, token)) |> isolated()}

  def transport(%__MODULE__{transport: {:stdio, opts}}, _token), do: {:stdio, isolated(opts)}

  # Anubis joins base_url and mcp_path, so the URL splits into them to be reached as given.
  defp endpoint(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    uri = URI.new!(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    Keyword.merge(opts,
      base_url: URI.to_string(%{uri | path: nil, fragment: nil}),
      mcp_path: path
    )
  end

  defp pooled(opts, nil), do: opts
  defp pooled(opts, mcp), do: Keyword.put_new(opts, :finch_name, WardrikMCP.Connection.finch(mcp))

  defp isolated(opts) do
    kept = @inherited ++ Map.keys(opts[:env] || %{})
    unset = for {name, _value} <- System.get_env(), name not in kept, do: ["-u", name]
    command = System.find_executable(opts[:command]) || opts[:command]

    Keyword.merge(opts,
      command: "env",
      args: List.flatten(unset) ++ ["--", command | opts[:args] || []]
    )
  end

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
