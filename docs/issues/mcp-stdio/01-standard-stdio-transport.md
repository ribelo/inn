---
status: completed
---

# MCP stdio transport that real clients can use

## Problem Statement

`inn mcp` frames stdio messages with LSP-style `Content-Length` headers. The
MCP stdio transport uses newline-delimited JSON-RPC: one JSON message per line,
with no embedded newlines and no headers. Because of this, Claude Code, Codex,
OpenCode, and every other MCP client cannot talk to Inn's MCP server at all.
The server also always answers `initialize` with protocol version
`2024-11-05`, whatever the client asks for. A single malformed message, or a
message with no `Content-Length`, silently ends the whole session.

## Solution

`inn mcp` speaks the standard MCP stdio transport: it reads newline-delimited
JSON-RPC messages from stdin and writes one compact JSON message per line to
stdout. It negotiates the protocol version with the client. It answers
malformed input with JSON-RPC errors instead of exiting. It exits cleanly only
at end of input. Logs go to stderr, never stdout.

## User Stories

1. As an agent user, I want to register `inn mcp` in Claude Code, Codex, or OpenCode and have its tools listed, so that my coding agent can query local telemetry ^mcp-gurs
2. As an agent user, I want each MCP response written as one line of compact JSON on stdout, so that standard clients parse it ^mcp-dgq3
3. As an agent user, I want Inn to answer `initialize` with the protocol version I requested when Inn supports it, and otherwise with Inn's latest supported version, so that version negotiation follows the MCP lifecycle rules ^mcp-592g
4. As an agent user, I want invalid JSON to get a JSON-RPC parse error (-32700) and the session to keep going, so that one bad message does not kill my agent's tool access ^mcp-seqk
5. As an agent user, I want notifications (messages without an id) never answered, and unknown methods answered with -32601, so that the server follows JSON-RPC 2.0 ^mcp-i9qo
6. As an agent user, I want a tool call made while the Inn server is not running to return a tool result with `isError: true` and a message that says how to start the service, so that the agent can explain the problem ^mcp-j7lb
7. As an agent user, I want the MCP server to exit with status 0 when stdin closes, so that clients can shut it down cleanly ^mcp-jovg
8. As an Inn contributor, I want the MCP request handling to be a pure function from a request message to an optional response message, separate from stdio I/O, so that the protocol can be tested without a subprocess ^mcp-v9fl
9. As an agent user, I want `serverInfo.version` to report the real Inn version instead of `dev`, so that I can tell which build is answering ^mcp-zxs5

## Implementation Decisions

- Transport: read stdin line by line. Skip blank lines. Parse each line as one
  JSON-RPC message. Write each response as compact JSON followed by `\n`, and
  flush after each message. Remove the `Content-Length` framing entirely. Do
  not keep it as a fallback.
- Supported protocol versions: `2025-11-25`, `2025-06-18`, `2025-03-26`, and
  `2024-11-05`. Echo the requested version if it is in this set; otherwise
  answer with `2025-11-25`.
- JSON-RPC batches (arrays) are not supported. Answer them with an
  invalid-request error.
- Move the MCP code out of the CLI entry point into its own library module
  with a pure handler and a thin stdio loop. The tool catalogue is maintained
  in that module. The MCP tool parity spec extends it.
- The version string comes from one place shared by the CLI and MCP. A
  build-time value from the dune-project version is preferred.

## Testing Decisions

- Unit tests drive the pure handler: initialize with each supported version
  and with an unknown version, tools/list, tools/call with a server that is
  down, an unknown method, a notification, and an invalid request
  (mcp-592g, mcp-i9qo, mcp-j7lb, mcp-v9fl, mcp-zxs5).
- One end-to-end test runs the built `inn mcp` binary as a subprocess, for
  example with a cram test. It pipes newline-delimited initialize, tools/list,
  and a malformed line, then checks one JSON response per line, and exit 0 on
  EOF (mcp-gurs, mcp-dgq3, mcp-seqk, mcp-jovg).

## Out of Scope

- Streamable HTTP MCP transport.
- New tools. See the motel parity specs.

## Further Notes

- Depends on the Eta migration spec.
