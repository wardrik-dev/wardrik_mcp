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

- A command gets its `env` plus `HOME`, `PATH` and a few other basics, not your app's whole environment.
- A server that's down offers no tools. It's retried, up to a minute between tries.
- Every server option is in `WardrikMCP.Server`.

## Give an agent the tools

```elixir
WardrikCore.start_agent(
  agent_id: "triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikMCP, name: MyApp.MCP, servers: [:github, :linear]}]
)
```

- The model sees `github__search_issues`, with the server's description and JSON Schema.
- When a server's tools change, the agent gets the new ones on its next turn.
- A result over `max_result_bytes` is cut, and the model is told.

## Secrets in headers

```elixir
{WardrikMCP,
 name: MyApp.MCP,
 secret: &MyApp.Vault.fetch/2,
 servers: [
   crm: [
     transport:
       {:streamable_http,
        url: "https://mcp.crm.example/mcp",
        headers: %{"authorization" => ["Bearer ", {:secret, "CRM_KEY"}]}},
     owner: "acme"
   ]
 ]}

# After the secret changes:
WardrikMCP.reconnect(MyApp.MCP, owner: "acme", secret: "CRM_KEY")
```

`MyApp.Vault.fetch(owner, name)` returns `{:ok, value}` or `{:error, reason}`. It runs each time the
server connects.

## Add servers at runtime

```elixir
{WardrikMCP, name: MyApp.MCP, store: store, check: &MyApp.Egress.public/1}

WardrikMCP.add(MyApp.MCP, "linear", transport: {:streamable_http, url: "https://mcp.linear.app/mcp"})
#=> :ok

WardrikMCP.servers(MyApp.MCP)
#=> ["linear"]

WardrikMCP.remove(MyApp.MCP, "linear")
#=> :ok
```

- With a `:store`, every node sees the server. Options must be data, not functions.
- `:check` vets each URL. Give one when users supply URLs. Commands are then refused.

## Per-person credentials

```elixir
WardrikMCP.add(MyApp.MCP, "linear",
  transport: {:streamable_http, url: "https://mcp.linear.app/mcp"},
  credential_name: "linear"
)
```

- Each person connects with their own credential, from `WardrikCore.Credentials`.
- It's sent as `authorization: Bearer <token>`, or in `credential_env` for a command.
- Someone with no credential is asked to sign in, and the call waits.
- Until someone connects, the server offers only `linear__connect`.

## Approvals

Tools carry the server's hints as annotations: `read_only`, `destructive`, `idempotent`, `open_world`.

- A tool needs a person's approval (`gated`) unless it's read-only. Set `gated:` to change that.
- Answers are labelled `"outside"` unless the server is `trusted: true`.

```elixir
WardrikPolicy.new!(default: [destructive: :deny, read_only: :allow, else: :ask])
```

## Costs

```elixir
search: [
  transport: {:streamable_http, url: "https://search.example.com/mcp"},
  cost: fn result -> %{usd: result["_meta"]["usd"]} end
]
```

Budgets count each call's cost.

## License

Apache-2.0
