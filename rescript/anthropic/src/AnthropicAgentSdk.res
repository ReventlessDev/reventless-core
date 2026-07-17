/**
Bindings for `@anthropic-ai/claude-agent-sdk` — the Claude Agent SDK (the
surface that powers Claude Code). Subscription-billed via
CLAUDE_CODE_OAUTH_TOKEN instead of per-token API billing.

This module lives in its own file deliberately: the compiled import of
`@anthropic-ai/claude-agent-sdk` (an optional peer dependency) is only pulled
in by consumers that import THIS module — keeping the default (API-key) code
path loadable without the Agent SDK installed.
*/

// ---------------------------------------------------------------------------
// In-process MCP tools
// ---------------------------------------------------------------------------

type sdkTool

type toolResultContent = {@as("type") type_: string, text: string}

/** The MCP CallToolResult shape a tool handler returns. */
type callToolResult = {content: array<toolResultContent>, isError?: bool}

let textResult = (~isError: option<bool>=?, text: string): callToolResult => {
  content: [{type_: "text", text: text}],
  isError: ?isError,
}

/** `tool(name, description, zodRawShape, handler)` — handler receives the
    parsed input. */
@module("@anthropic-ai/claude-agent-sdk")
external tool: (string, string, Dict.t<AnthropicZod.t>, JSON.t => promise<callToolResult>) => sdkTool =
  "tool"

type mcpServer

type serverConfig = {
  name: string,
  version: string,
  tools: array<sdkTool>,
}

@module("@anthropic-ai/claude-agent-sdk")
external createSdkMcpServer: serverConfig => mcpServer = "createSdkMcpServer"

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

/** Union: `{behavior: "allow", updatedInput}` | `{behavior: "deny", message}`. */
type permissionResult

type permissionAllow = {behavior: string, updatedInput: JSON.t}
type permissionDeny = {behavior: string, message: string}

external allow_: permissionAllow => permissionResult = "%identity"
external deny_: permissionDeny => permissionResult = "%identity"

let allow = (updatedInput: JSON.t): permissionResult =>
  allow_({behavior: "allow", updatedInput: updatedInput})

let deny = (message: string): permissionResult => deny_({behavior: "deny", message: message})

// ---------------------------------------------------------------------------
// query()
// ---------------------------------------------------------------------------

type options = {
  model?: string,
  systemPrompt?: string,
  env?: Dict.t<string>,
  mcpServers?: Dict.t<mcpServer>,
  allowedTools?: array<string>,
  maxTurns?: int,
  permissionMode?: string,
  canUseTool?: (string, JSON.t) => promise<permissionResult>,
}

type queryParams = {prompt: string, options: options}

/** Messages on the query stream, discriminated by `type_`; `"result"` is the
    terminal message and carries usage / error state. */
type sdkMessage = {
  @as("type") type_: string,
  subtype?: string,
  is_error?: bool,
  usage?: JSON.t,
  result?: string,
}

/** The AsyncGenerator returned by `query()`. */
type queryStream

@module("@anthropic-ai/claude-agent-sdk")
external query: queryParams => queryStream = "query"

type iterationResult = {
  done: bool,
  value: Nullable.t<sdkMessage>,
}

@send external next: queryStream => promise<iterationResult> = "next"

/** Stop consuming early (closes the underlying generator). */
@send external return: (queryStream, unit) => promise<unit> = "return"
