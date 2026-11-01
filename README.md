# WardrikMCP

Gives [WardrikCore](https://hexdocs.pm/wardrik_core) agents the tools of any MCP server.

## Install

```elixir
def deps do
  [
    {:wardrik_mcp, "~> 0.1.0-rc.2"}
  ]
end
```

## Connect to servers

Add `WardrikMCP` to your supervision tree with a name and its servers. A server runs as a local
command (`:stdio`) or is reached over HTTP (`:streamable_http`):

```elixir
children = [
  {WardrikMCP,
   name: MyApp.MCP,
   servers: [
     github: [
       transport:
         {:stdio,
          command: "github-mcp-server",
          args: ["stdio"],
          env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}},
       only: ["search_issues", "create_issue"]
     ],
     linear: [
       transport:
         {:streamable_http,
          url: "https://mcp.linear.app/mcp",
          headers: %{"authorization" => "Bearer " <> System.fetch_env!("LINEAR_TOKEN")}}
     ]
   ]}
]
```

A command doesn't inherit the app's environment. It gets its `env` and only `HOME`, `LANG`,
`LC_ALL`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, `TMPDIR` and `USER`; it's started through `env`,
which unsets the rest. Give it anything else it needs in `env`.

Each server connects on its own. A server that's down offers no tools and doesn't block the
others. It's retried with backoff, up to a minute between tries.

## Give an agent the tools

Pass `WardrikMCP` as a capability, with the servers to take tools from:

```elixir
WardrikCore.start_agent(
  agent_id: "triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
)
```

The model sees each tool as `<server>__<tool>`, as `github__search_issues`, with the server's own
description and JSON Schema. When a server says its tools changed, the agent gets the new ones on
its next turn.

## Server options

| Option | Value | Default |
| --- | --- | --- |
| `transport` | `{:stdio, command: …, args: …, env: …}` or `{:streamable_http, url: …, headers: …}`, where `url` is the endpoint the server publishes | required |
| `only` | the server's tool names to offer | every tool |
| `except` | the server's tool names to leave out | none |
| `timeout` | milliseconds a call may take | `60_000` |
| `max_result_bytes` | bytes of a result the model gets | `131_072` |
| `prefix` | the prefix for tool names | the server's name |
| `credential_name` | the credential each principal reaches the server with | none |
| `credential_header`, `credential_scheme` | where the credential goes over HTTP | `"authorization"`, `"Bearer"` |
| `credential_env` | the environment variable the credential goes in, for a command | none |
| `cost` | each call's cost, as `[usd: 0.001]`, or a function of the result | none |
| `gated` | which tools need a person's approval: `true`, `false`, or tool names, as `["create_*"]` | tools not marked read-only |
| `trusted` | `true` to not label answers `"outside"` | `false` |

See `WardrikMCP.Server`.

## Results

The model gets a result's structured content if the server sends it, and its text otherwise. A
result over `max_result_bytes` is cut, and the model is told. An error the tool returns reaches
the model as the call's error.

## Add servers at runtime

Give `WardrikMCP` a `:store` to add and remove servers while the app runs. Every node sharing the
store sees them.

```elixir
{WardrikMCP, name: MyApp.MCP, store: store, servers: []}

WardrikMCP.add(MyApp.MCP, "linear", transport: {:streamable_http, url: "https://mcp.linear.app/mcp"})
#=> :ok

WardrikMCP.servers(MyApp.MCP)
#=> ["linear"]

WardrikMCP.remove(MyApp.MCP, "linear")
#=> :ok
```

Options for a server added at runtime must be data, not functions. Each node re-reads the store
every minute, or when you call `WardrikMCP.reconcile/1`.

### Checking URLs

When users supply the URLs, give a `:check`. It's called on each URL when the server is added and
each time a connection starts. With a check, runtime servers must use HTTP; commands are refused.

```elixir
{WardrikMCP, name: MyApp.MCP, store: store, check: &MyApp.Egress.public/1}

WardrikMCP.add(MyApp.MCP, "internal", transport: {:streamable_http, url: "https://10.0.0.5/mcp"})
#=> {:error, "https://10.0.0.5/mcp can't be reached: 10.0.0.5 is a private address"}
```

## Per-person credentials

Set `credential_name` so each principal reaches the server with their own credential, over their
own connection. The credential comes from the agent's `WardrikCore.Credentials`.

```elixir
WardrikMCP.add(MyApp.MCP, "linear",
  transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
  credential_name: "linear"
)
```

* Over HTTP, it's sent as `authorization: Bearer <token>`. Change this with `credential_header`
  and `credential_scheme`.
* A command gets it in the environment variable named by `credential_env`.
* A principal with no credential yet is asked to sign in, and the call waits.
* A changed credential reconnects.
* If the server refuses the credential (401 or 403), it's reported with
  `WardrikCore.Credentials.refused/2` and the call is tried once more. An OAuth grant is renewed,
  or the person is asked to sign in again.

Until someone has connected, the server offers one tool, `linear__connect`, so an agent can start.
After that, its tools are kept in the store and offered to everyone. A person's connection closes
after five minutes without a call.

## Tool annotations

MCP servers mark their tools with hints. Each tool carries them as
[annotations](https://hexdocs.pm/wardrik_core/WardrikCore.Tool.html):

| Server hint | Annotation |
| --- | --- |
| `readOnlyHint` | `read_only`, and `idempotent` |
| `destructiveHint` | `destructive` |
| `idempotentHint` | `idempotent` |
| `openWorldHint` | `open_world` |

A hint the server doesn't give isn't set. With [WardrikPolicy](https://hexdocs.pm/wardrik_policy),
you can make tools that aren't read-only wait for a person:

```elixir
WardrikPolicy.new!(default: [destructive: :deny, read_only: :allow, else: :ask])
```

## Call costs

Give a server a fixed `cost`, or a function that reads it from the result:

```elixir
search: [
  transport: {:streamable_http, url: "https://search.example.com/mcp"},
  cost: fn result -> %{usd: result["_meta"]["usd"]} end
]
```

Each call's cost is measured on its step, so budgets count it.

## Telemetry

`[:wardrik_mcp, :tools]` is emitted each time a server's tools change.

* Measurements: `:count`, the number of tools the server offers. `0` while it's down.
* Metadata: `:mcp`, the `WardrikMCP` name, and `:server`, the server's name.

## License

Apache-2.0
