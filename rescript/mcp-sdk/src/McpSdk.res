// ReScript bindings for @modelcontextprotocol/sdk v1.x
//
// Uses the low-level Server class (not McpServer) to avoid Zod dependency
// for domain schemas. Tool inputSchema and resource definitions use raw
// JSON Schema objects, which map naturally to sury-derived schemas.

// ─── Opaque types ──────────────────────────────────────────────────────────

/** Low-level MCP Server instance. Handles JSON-RPC protocol framing. */
type server

/** Streamable HTTP transport for remote MCP connections. */
type transport

/** Node.js IncomingMessage (from http module). */
type incomingMessage

/** Node.js ServerResponse (from http module). */
type serverResponse

/** Node.js http.Server instance. */
type httpServer

// ─── Server creation ───────────────────────────────────────────────────────

type serverInfo = {
  name: string,
  version: string,
}

type emptyObj = {_placeholder?: bool}

type serverCapabilities = {
  tools?: emptyObj,
  resources?: emptyObj,
}

type serverOptions = {capabilities: serverCapabilities}

@module("@modelcontextprotocol/sdk/server/index.js")
external createServer: (serverInfo, serverOptions) => server = "Server"

@new @module("@modelcontextprotocol/sdk/server/index.js")
external newServer: (serverInfo, serverOptions) => server = "Server"

// ─── Transport ─────────────────────────────────────────────────────────────

type transportOptions = {
  sessionIdGenerator?: unit => string,
  enableJsonResponse?: bool,
}

@new @module("@modelcontextprotocol/sdk/server/streamableHttp.js")
external newStreamableHTTPTransport: transportOptions => transport = "StreamableHTTPServerTransport"

/** Connect a server to a transport. */
@send
external connect: (server, transport) => promise<unit> = "connect"

/** Handle an incoming HTTP request through the transport. */
@send
external handleRequest: (transport, incomingMessage, serverResponse, JSON.t) => promise<unit> =
  "handleRequest"

@send
external handleRequestNoParsedBody: (transport, incomingMessage, serverResponse) => promise<unit> =
  "handleRequest"

// ─── Request schema constants (for setRequestHandler) ──────────────────────
//
// These are Zod schemas that define the shape of each MCP protocol request.
// We import them as opaque values and pass them to setRequestHandler.

type zodSchema

@module("@modelcontextprotocol/sdk/types.js")
external listToolsRequestSchema: zodSchema = "ListToolsRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external callToolRequestSchema: zodSchema = "CallToolRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external listResourcesRequestSchema: zodSchema = "ListResourcesRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external readResourceRequestSchema: zodSchema = "ReadResourceRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external listResourceTemplatesRequestSchema: zodSchema = "ListResourceTemplatesRequestSchema"

@module("@modelcontextprotocol/sdk/types.js")
external initializeRequestSchema: zodSchema = "InitializeRequestSchema"

// ─── Request/response types ────────────────────────────────────────────────

/** Tool definition for tools/list response. */
type toolDefinition = {
  name: string,
  description: string,
  inputSchema: JSON.t,
}

/** Result content item for tool call responses. */
type contentItem = {
  @as("type") type_: string,
  text: string,
}

/** Tool call result. */
type callToolResult = {
  content: array<contentItem>,
  isError?: bool,
}

/** tools/list response. */
type listToolsResult = {tools: array<toolDefinition>}

/** tools/call request params. */
type callToolParams = {
  name: string,
  arguments: option<JSON.t>,
}

/** tools/call request. */
type callToolRequest = {params: callToolParams}

/** Resource definition for resources/list response. */
type resourceDefinition = {
  uri: string,
  name: string,
  description?: string,
  mimeType?: string,
}

/** Resource template definition. */
type resourceTemplateDefinition = {
  uriTemplate: string,
  name: string,
  description?: string,
  mimeType?: string,
}

/** resources/list response. */
type listResourcesResult = {resources: array<resourceDefinition>}

/** resources/templates/list response. */
type listResourceTemplatesResult = {resourceTemplates: array<resourceTemplateDefinition>}

/** resources/read request params. */
type readResourceParams = {uri: string}

/** resources/read request. */
type readResourceRequest = {params: readResourceParams}

/** Resource content for read response. */
type resourceContent = {
  uri: string,
  text: string,
  mimeType?: string,
}

/** resources/read response. */
type readResourceResult = {contents: array<resourceContent>}

// ─── setRequestHandler ─────────────────────────────────────────────────────
//
// Generic binding — the zodSchema constant determines what request type the
// handler receives. We provide typed wrappers below.

@send
external setRequestHandler: (server, zodSchema, 'request => promise<'response>) => unit =
  "setRequestHandler"

// ─── Utility ───────────────────────────────────────────────────────────────

/** Check if a request body is an MCP initialize request. */
@module("@modelcontextprotocol/sdk/server/streamableHttp.js")
external isInitializeRequest: JSON.t => bool = "isInitializeRequest"

// ─── Node.js HTTP server ───────────────────────────────────────────────────

@module("http")
external createHttpServer: (
  (incomingMessage, serverResponse) => unit,
) => httpServer = "createServer"

@send
external listen: (httpServer, int, unit => unit) => unit = "listen"

@send
external close: (httpServer, unit => unit) => unit = "close"

/** Get the HTTP method from an IncomingMessage. */
@get
external method: incomingMessage => string = "method"

/** Get the URL from an IncomingMessage. */
@get
external url: incomingMessage => string = "url"

/** Set a response header. */
@send
external setHeader: (serverResponse, string, string) => unit = "setHeader"

/** Write a response status code. */
@get
external statusCode: serverResponse => int = "statusCode"

@set
external setStatusCode: (serverResponse, int) => unit = "statusCode"

/** End the response with a body. */
@send
external endResponse: (serverResponse, string) => unit = "end"

@send
external endResponseNoBody: serverResponse => unit = "end"

// ─── IncomingMessage event bindings ──────────────────────────────────────────

@send
external onData: (incomingMessage, @as("data") _, string => unit) => incomingMessage = "on"

@send
external onEnd: (incomingMessage, @as("end") _, unit => unit) => incomingMessage = "on"
