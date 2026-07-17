/** Register a handler for tools/list requests. */
let onListTools = (server: McpSdk.server, handler: unit => promise<McpSdk.listToolsResult>) =>
  server->McpSdk.setRequestHandler(McpSdk.listToolsRequestSchema, _ => handler())

/** Register a handler for tools/call requests. */
let onCallTool = (server: McpSdk.server, handler: McpSdk.callToolRequest => promise<McpSdk.callToolResult>) =>
  server->McpSdk.setRequestHandler(McpSdk.callToolRequestSchema, handler)

/** Register a handler for resources/list requests. */
let onListResources = (server: McpSdk.server, handler: unit => promise<McpSdk.listResourcesResult>) =>
  server->McpSdk.setRequestHandler(McpSdk.listResourcesRequestSchema, _ => handler())

/** Register a handler for resources/read requests. */
let onReadResource = (server: McpSdk.server, handler: McpSdk.readResourceRequest => promise<McpSdk.readResourceResult>) =>
  server->McpSdk.setRequestHandler(McpSdk.readResourceRequestSchema, handler)

/** Register a handler for resources/templates/list requests. */
let onListResourceTemplates = (
  server: McpSdk.server,
  handler: unit => promise<McpSdk.listResourceTemplatesResult>,
) => server->McpSdk.setRequestHandler(McpSdk.listResourceTemplatesRequestSchema, _ => handler())

/** Create a text content item for tool results. */
let textContent = (text: string): McpSdk.contentItem => {type_: "text", text}

/** Create a successful tool result. */
let toolResult = (text: string): McpSdk.callToolResult => {
  content: [textContent(text)],
}

/** Create an error tool result. */
let toolError = (message: string): McpSdk.callToolResult => {
  content: [textContent(message)],
  isError: true,
}

/** Read and parse the JSON body from an IncomingMessage. Returns a promise. */
let parseJsonBody: McpSdk.incomingMessage => promise<JSON.t> = req => {
  Promise.make((resolve, _reject) => {
    let chunks: array<string> = []
    let _ = req->McpSdk.onData(chunk => chunks->Array.push(chunk))
    let _ = req->McpSdk.onEnd(() => {
      let body = chunks->Array.join("")
      let json = try JSON.parseOrThrow(body) catch {
      | _ => JSON.Encode.null
      }
      resolve(json)
    })
  })
}
