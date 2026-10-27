# WardrikMCP

The tools of any MCP server, for [WardrikCore](https://hexdocs.pm/wardrik_core) agents to call.

## Install

```elixir
def deps do
  [
    {:wardrik_mcp, "~> 0.1"}
  ]
end
```

## Connect to servers

Add `WardrikMCP` to your supervision tree, with a name and the servers it reaches. A server runs as a command,
or is reached over HTTP:

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
          base_url: "https://mcp.linear.app/mcp",
          headers: %{"authorization" => "Bearer " <> System.fetch_env!("LINEAR_TOKEN")}}
     ]
   ]}
]
```

Every function takes the name you gave it, and raises saying so where it isn't started.

Each server connects on its own. One that's down offers no tools, and holds up nothing else. It's
tried again, waiting longer each time, up to a minute.

## Give an agent the tools

A server's tools are a `WardrikCore.Capability`, named by the server:

```elixir
WardrikCore.start_agent(
  agent_id: "triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
)
```

The model sees each tool as `github__search_issues`, with the server's own description and JSON
Schema. When the server says its tools changed, the agent gets the new ones from its next turn.

| Key | Takes | Unless set |
| --- | --- | --- |
| `transport` | `{:stdio, command: …, args: …, env: …}` or `{:streamable_http, base_url: …, headers: …}` | required |
| `only` | the server's own tool names to offer | every tool |
| `except` | the server's own tool names to leave out | none |
| `timeout` | how long a call may take, in milliseconds | 60 seconds |
| `max_result_bytes` | how much of a result the model gets | 128 KB |
| `prefix` | what its tools are named under | its name |
| `credential_name` | the name each principal's own credential for it is held under | none |
| `cost` | what each call costs, as `[usd: 0.001]`, or a function of the server's result | nothing |
| `gated` | which tools can change something, so a person must allow their calls: `true`, `false`, or the server's own tool names, as `["create_*"]` | those it doesn't mark read-only |
| `trusted` | `true` where its answers are the deployment's own, so they aren't labelled `"outside"` | `false` |

The model gets a result's structured content where the server sends some, and its text otherwise.
A longer result is cut, and the model is told. A tool's error reaches the model as the call's error.

## Add servers as the app runs

Add and remove servers while the app runs. Give `WardrikMCP` a `store:`, and every node reaches
what any adds:

```elixir
{WardrikMCP, name: MyApp.MCP, store: store, servers: []}

WardrikMCP.add(MyApp.MCP, "linear", transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"})
#=> :ok

WardrikMCP.servers(MyApp.MCP)
#=> ["github", "linear"]

WardrikMCP.remove(MyApp.MCP, "linear")
#=> :ok
```

A server added as the app runs takes its options as data. Each node reads the servers in the store
again every minute, or when you call `reconcile/1`.

Where others name the URLs, as the users of a hosted app do, give a `check:`. Each URL of a server
added as the app runs is held to it as it's added and as each connection to it starts, and a
command is never run:

```elixir
{WardrikMCP, name: MyApp.MCP, store: store, check: &MyApp.Egress.public/1}

WardrikMCP.add(MyApp.MCP, "internal", transport: {:streamable_http, base_url: "https://10.0.0.5/mcp"})
#=> {:error, "https://10.0.0.5/mcp can't be reached: 10.0.0.5 is a private address"}
```

## Reach a server as each person

Give a `credential_name`, and each principal reaches the server with their own credential of that
name, from the agent's `WardrikCore.Credentials`, over a connection of their own:

```elixir
WardrikMCP.add(MyApp.MCP, "linear",
  transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"},
  credential_name: "linear"
)
```

Over HTTP, it's sent as `authorization: Bearer <token>`; `credential_header` and
`credential_scheme` change that. A command gets it in the variable `credential_env` names. A
principal who holds none yet is asked to sign in, and the call waits on it. A credential that
changes reconnects. One the server refuses, with a 401, is reported through
`WardrikCore.Credentials.refused/2`, and the call is tried once more: an OAuth grant is renewed,
or the person is asked to sign in again.

Until anyone has reached it, the server offers one tool, `linear__connect`, so an agent can begin.
Once someone has, its tools are kept in the store and offered to everyone. A person's connection
closes after five minutes without a call.

## What a server says about its tools

An MCP server marks its tools with hints. Each tool carries them as
[annotations](https://hexdocs.pm/wardrik_core/WardrikCore.Tool.html):

| The server's hint | The tool's annotation |
| --- | --- |
| `readOnlyHint` | `read_only`, and `idempotent` too |
| `destructiveHint` | `destructive` |
| `idempotentHint` | `idempotent` |
| `openWorldHint` | `open_world` |

A hint the server doesn't give isn't set. Anything that reads annotations can decide by them. With
[WardrikPolicy](https://hexdocs.pm/wardrik_policy), a tool the server doesn't mark read-only can
wait for a person:

```elixir
WardrikPolicy.new!(default: [destructive: :deny, read_only: :allow, else: :ask])
```

## What a call cost

A server that charges for its calls can say so. Give it a fixed `cost`, or read it from the
server's result:

```elixir
search: [
  transport: {:streamable_http, base_url: "https://search.example.com/mcp"},
  cost: fn result -> %{usd: result["_meta"]["usd"]} end
]
```

Each call's cost is measured on its step, so a budget counts it.

## Events

Each time the tools a server offers change, `WardrikMCP` emits `[:wardrik_mcp, :tools]`. It carries
the `mcp` it runs under and the `server`, and measures the `count` of tools the server now offers, which is 0 while it's down.

## License

Apache-2.0
