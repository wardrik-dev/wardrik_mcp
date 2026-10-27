# Changelog

## 0.1.0 (unreleased)

- Tools are `gated` unless read-only, or as a server's `gated` says, and their answers are labelled
  `"outside"` unless the server is `trusted`.
- A call that fails in passing raises `WardrikMCP.Unavailable`, for the tool runner to try again.
- `WardrikMCP`, which connects to MCP servers over stdio or Streamable HTTP, and gives an agent
  their tools as a WardrikCore capability.
- Each server connects on its own, and is tried again when it's down. A server whose tools change
  is asked for them again.
- The server's hints become tool annotations, like `read_only` and `destructive`.
- `only` and `except`, a call `timeout`, a cap on what a result gives the model, and a `cost` per
  call that a budget counts.
- `[:wardrik_mcp, :tools]` events when the tools a server offers change.
