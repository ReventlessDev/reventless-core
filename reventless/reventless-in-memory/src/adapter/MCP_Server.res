// Shared in-memory MCP server.
// Collects tool and resource definitions from Plugin_Builder during Platform.Make().
// start() is called once after all components are built (shared lifecycle with GraphQL server).
//
// Uses the low-level MCP Server class to register tools and resources with
// JSON Schema input schemas derived from sury schemas (no Zod dependency).

// ─── Registry ──────────────────────────────────────────────────────────────

type toolHandler = (JSON.t, Reventless.Identity.t) => promise<McpSdk.callToolResult>
type resourceHandler = string => promise<McpSdk.readResourceResult>

type registeredTool = {
  definition: ReventlessCore.MCP_SchemaGenerator.mcpToolDefinition,
  handler: toolHandler,
}

type registeredResource = {
  definition: ReventlessCore.MCP_SchemaGenerator.mcpResourceDefinition,
  handler: resourceHandler,
}

let tools: ref<dict<registeredTool>> = ref(Dict.make())
let resources: ref<dict<registeredResource>> = ref(Dict.make())
let resourceTemplates: ref<dict<registeredResource>> = ref(Dict.make())

let registerTool = (~name: string, ~definition, ~handler: toolHandler) => {
  tools.contents->Dict.set(name, {definition, handler})
}

let registerResource = (~name: string, ~definition, ~handler: resourceHandler) => {
  resources.contents->Dict.set(name, {definition, handler})
}

let registerResourceTemplate = (~name: string, ~definition, ~handler: resourceHandler) => {
  resourceTemplates.contents->Dict.set(name, {definition, handler})
}

// ─── Batch registration from schema entries ────────────────────────────────

/** Register MCP tools from mutation entries (aggregate commands + DCB slices). */
let registerToolsFromEntries = (
  ~pluginName: string,
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~commandHandler: (string, JSON.t, Reventless.Identity.t) => promise<string>,
) => {
  let toolDefs = ReventlessCore.MCP_SchemaGenerator.generateTools(~pluginName, ~mutationEntries)
  toolDefs->Array.forEach(def => {
    let handler: toolHandler = async (args, identity) => {
      try {
        let result = await commandHandler(def.name, args, identity)
        McpSdk_Helpers.toolResult(result)
      } catch {
      | exn =>
        let msg =
          exn
          ->JsExn.fromException
          ->Option.flatMap(JsExn.message)
          ->Option.getOr("Command failed")
        McpSdk_Helpers.toolError(msg)
      }
    }
    registerTool(~name=def.name, ~definition=def, ~handler)
  })
}

/** Register MCP resources from query entries (ReadModels + StateViewSlices). */
let registerResourcesFromEntries = (
  ~pluginName: string,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  ~queryHandler: (string, string) => promise<JSON.t>,
) => {
  let resourceDefs = ReventlessCore.MCP_SchemaGenerator.generateResources(
    ~pluginName,
    ~queryEntries,
  )
  resourceDefs->Array.forEach(def => {
    let handler: resourceHandler = async uri => {
      let result = await queryHandler(def.name, uri)
      {
        McpSdk.contents: [
          {
            McpSdk.uri,
            text: result->JSON.stringify,
          },
        ],
      }
    }
    // URIs with template parameters ({id}) go into resource templates;
    // fixed URIs (list endpoints) go into regular resources.
    if def.uriTemplate->String.includes("{") {
      registerResourceTemplate(~name=def.name, ~definition=def, ~handler)
    } else {
      registerResource(~name=def.name, ~definition=def, ~handler)
    }
  })
}

/** Register MCP resources for event history (aggregate EventLog + DCB EventLog). */
let registerEventHistoryResourcesFromEntries = (
  ~pluginName: string,
  ~eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  ~eventLogHandler: (string, string) => promise<JSON.t>,
) => {
  let resourceDefs = ReventlessCore.MCP_SchemaGenerator.generateEventHistoryResources(
    ~pluginName,
    ~eventLogEntries,
  )
  resourceDefs->Array.forEach(def => {
    let handler: resourceHandler = async uri => {
      let result = await eventLogHandler(def.name, uri)
      {
        McpSdk.contents: [
          {
            McpSdk.uri,
            text: result->JSON.stringify,
          },
        ],
      }
    }
    // Event history resources always have template parameters ({entityId})
    registerResourceTemplate(~name=def.name, ~definition=def, ~handler)
  })
}

// ─── Server lifecycle ──────────────────────────────────────────────────────

let activeServer: ref<option<McpSdk.httpServer>> = ref(None)

@val external processEnv: dict<string> = "process.env"
let debug = processEnv->Dict.get("MCP_DEBUG")->Option.isSome

// Extract identity from an HTTP IncomingMessage via the X-Identity header.
// Falls back to Identity.anonymous when the header is absent or malformed.
let extractIdentity = (req: McpSdk.incomingMessage): Reventless.Identity.t => {
  try {
    let headers: dict<string> = (req->Obj.magic)["headers"]
    switch headers->Dict.get("x-identity") {
    | Some(json) =>
      json
      ->JSON.parseOrThrow
      ->S.parseOrThrow(Reventless.Identity.schema)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }
}

// Create a fresh MCP server instance with all registered handlers.
// Called per-request for stateless Streamable HTTP (each request gets its own server+transport).
let createServerInstance = (identity: Reventless.Identity.t) => {
  let server = McpSdk.newServer(
    {name: "reventless-mcp", version: "1.0.0"},
    {capabilities: {tools: {_placeholder: false}, resources: {_placeholder: false}}},
  )

  server->McpSdk_Helpers.onListTools(async () => {
    let toolDefs =
      tools.contents
      ->Dict.valuesToArray
      ->Array.map(({definition}) => {
        McpSdk.name: definition.name,
        description: definition.description,
        inputSchema: definition.inputSchema,
      })
    {McpSdk.tools: toolDefs}
  })

  server->McpSdk_Helpers.onCallTool(async req => {
    let toolName = req.params.name
    let args = req.params.arguments->Option.getOr(JSON.Encode.null)
    if debug {
      Console.log(`[MCP] tools/call: ${toolName}`)
    }
    switch tools.contents->Dict.get(toolName) {
    | Some({handler}) => await handler(args, identity)
    | None => McpSdk_Helpers.toolError(`Unknown tool: ${toolName}`)
    }
  })

  server->McpSdk_Helpers.onListResources(async () => {
    let resourceDefs =
      resources.contents
      ->Dict.valuesToArray
      ->Array.map(({definition}) => {
        McpSdk.uri: definition.uriTemplate,
        name: definition.name,
        description: definition.description,
        mimeType: definition.mimeType,
      })
    {McpSdk.resources: resourceDefs}
  })

  server->McpSdk_Helpers.onListResourceTemplates(async () => {
    let templateDefs =
      resourceTemplates.contents
      ->Dict.valuesToArray
      ->Array.map(({definition}) => {
        McpSdk.uriTemplate: definition.uriTemplate,
        name: definition.name,
        description: definition.description,
        mimeType: definition.mimeType,
      })
    {McpSdk.resourceTemplates: templateDefs}
  })

  server->McpSdk_Helpers.onReadResource(async req => {
    let uri = req.params.uri
    if debug {
      Console.log(`[MCP] resources/read: ${uri}`)
    }
    // Search both regular resources and resource templates
    let matchedResource =
      resources.contents
      ->Dict.valuesToArray
      ->Array.find(({definition}) => uri->String.includes(definition.name))
    switch matchedResource {
    | Some({definition, handler}) =>
      if debug {
        Console.log(`[MCP]   matched resource: ${definition.name}`)
      }
      await handler(uri)
    | None =>
      let matchedTemplate =
        resourceTemplates.contents
        ->Dict.valuesToArray
        ->Array.find(({definition}) => uri->String.includes(definition.name))
      switch matchedTemplate {
      | Some({definition, handler}) =>
        if debug {
          Console.log(`[MCP]   matched template: ${definition.name}`)
        }
        await handler(uri)
      | None => {
          McpSdk.contents: [
            {McpSdk.uri, text: `{"error": "Resource not found: ${uri}"}`},
          ],
        }
      }
    }
  })

  server
}

let start = (~port: int=3001, ()) => {
  let httpServer = McpSdk.createHttpServer((req, res) => {
    let _ = (async () => {
      let reqMethod = req->McpSdk.method
      let reqUrl = req->McpSdk.url

      // CORS headers for browser-based clients (e.g. MCP Inspector)
      res->McpSdk.setHeader("Access-Control-Allow-Origin", "*")
      res->McpSdk.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
      res->McpSdk.setHeader("Access-Control-Allow-Headers", "Content-Type")

      if reqUrl == "/mcp" || reqUrl->String.startsWith("/mcp?") {
        switch reqMethod {
        | "OPTIONS" =>
          res->McpSdk.setStatusCode(204)
          res->McpSdk.endResponseNoBody
        | "POST" =>
          let body = await McpSdk_Helpers.parseJsonBody(req)
          let identity = extractIdentity(req)
          // Stateless mode: fresh server + transport per request
          let server = createServerInstance(identity)
          let transport = McpSdk.newStreamableHTTPTransport({
            enableJsonResponse: true,
          })
          let _ = await server->McpSdk.connect(transport)
          let _ = await transport->McpSdk.handleRequest(req, res, body)
        | "GET" =>
          res->McpSdk.setHeader("Content-Type", "text/plain")
          res->McpSdk.endResponse("MCP server running")
        | "DELETE" =>
          res->McpSdk.setStatusCode(200)
          res->McpSdk.endResponseNoBody
        | _ =>
          res->McpSdk.setStatusCode(405)
          res->McpSdk.endResponse("Method not allowed")
        }
      } else {
        res->McpSdk.setStatusCode(404)
        res->McpSdk.endResponse("Not found")
      }
    })()
  })

  httpServer->McpSdk.listen(port, () => {
    Console.log(`[MCP] Listening on http://localhost:${port->Int.toString}/mcp`)
    if debug {
      let toolNames = tools.contents->Dict.keysToArray
      let resourceNames = resources.contents->Dict.keysToArray
      let templateNames = resourceTemplates.contents->Dict.keysToArray
      Console.log(`[MCP]   Tools (${toolNames->Array.length->Int.toString}):`)
      toolNames->Array.forEach(t => Console.log(`[MCP]     - ${t}`))
      Console.log(`[MCP]   Resources (${resourceNames->Array.length->Int.toString}):`)
      resourceNames->Array.forEach(r => Console.log(`[MCP]     - ${r}`))
      Console.log(`[MCP]   Resource Templates (${templateNames->Array.length->Int.toString}):`)
      templateNames->Array.forEach(r => Console.log(`[MCP]     - ${r}`))
    }
  })
  activeServer.contents = Some(httpServer)
}

let stop = () =>
  switch activeServer.contents {
  | Some(server) =>
    server->McpSdk.close(() => ())
    activeServer.contents = None
  | None => ()
  }

let reset = () => {
  tools.contents = Dict.make()
  resources.contents = Dict.make()
  resourceTemplates.contents = Dict.make()
}

// ─── Diagnostics ───────────────────────────────────────────────────────────

type diagnostics = {
  registeredTools: array<string>,
  registeredResources: array<string>,
  toolCount: int,
  resourceCount: int,
  serverRunning: bool,
}

let diagnostics = (): diagnostics => {
  let toolNames = tools.contents->Dict.keysToArray
  let resourceNames =
    resources.contents
    ->Dict.keysToArray
    ->Array.concat(resourceTemplates.contents->Dict.keysToArray)
  {
    registeredTools: toolNames,
    registeredResources: resourceNames,
    toolCount: toolNames->Array.length,
    resourceCount: resourceNames->Array.length,
    serverRunning: activeServer.contents->Option.isSome,
  }
}

let printDiagnostics = () => {
  let d = diagnostics()
  Console.log("[MCP Diagnostics]")
  Console.log(`  Tools (${d.toolCount->Int.toString}):`)
  d.registeredTools->Array.forEach(t => Console.log(`    - ${t}`))
  Console.log(`  Resources (${d.resourceCount->Int.toString}):`)
  d.registeredResources->Array.forEach(r => Console.log(`    - ${r}`))
  Console.log(`  Server running: ${d.serverRunning ? "yes" : "no"}`)
}
