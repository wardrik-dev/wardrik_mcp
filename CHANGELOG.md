# Changelog

## Unreleased

- A header's value can name a secret, as `{:secret, name}` or `["Bearer ", {:secret, name}]`,
  read with the new `:secret` option for the server's `owner` each time it connects. A server
  whose secret can't be read is down, like one that can't be reached.
- `reconnect/3` connects again the servers whose headers name a secret, once it changes.
- `start_link/1` validates its options with NimbleOptions, documented from the schema.

## 0.1.0-rc.1 (2026-10-30)

- `WardrikMCP`, which connects to MCP servers over stdio or Streamable HTTP, and gives an agent
  their tools as a WardrikCore capability.
- Each server connects on its own, and is tried again when it's down. A server whose tools change
  is asked for them again, reported as `[:wardrik_mcp, :tools]`.
- Servers added and removed at runtime, kept in a `WardrikStore` for every node, with a `:check`
  for URLs users supply.
- Per-person credentials: with `credential_name`, each principal reaches the server over their
  own connection.
- The server's hints as tool annotations, like `read_only` and `destructive`. Tools are `gated`
  unless read-only, or as a server's `gated` says.
- Answers labelled `"outside"` unless the server is `trusted`.
- `only` and `except`, a call `timeout`, a cap on what a result gives the model, and a `cost` per
  call that a budget counts.
- A call that fails in passing raises `WardrikMCP.Unavailable`, for the tool runner to try again.
