// MCP server instance factory.
// Creates independent server instances with isolated registries.
// Used by Platform to create separate core and plugin servers in split mode.

let log = ReventlessCore.Logger.fromEnv()

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

type diagnostics = {
  registeredTools: array<string>,
  registeredResources: array<string>,
  toolCount: int,
  resourceCount: int,
  serverRunning: bool,
}

type t = {
  registerTool: (~name: string, ~definition: ReventlessCore.MCP_SchemaGenerator.mcpToolDefinition, ~handler: toolHandler) => unit,
  registerResource: (~name: string, ~definition: ReventlessCore.MCP_SchemaGenerator.mcpResourceDefinition, ~handler: resourceHandler) => unit,
  registerResourceTemplate: (~name: string, ~definition: ReventlessCore.MCP_SchemaGenerator.mcpResourceDefinition, ~handler: resourceHandler) => unit,
  registerToolsFromEntries: (
    ~pluginName: string,
    ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
    ~commandHandler: (string, JSON.t, Reventless.Identity.t) => promise<string>,
  ) => unit,
  registerResourcesFromEntries: (
    ~pluginName: string,
    ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
    ~queryHandler: (string, string) => promise<JSON.t>,
  ) => unit,
  registerEventHistoryResourcesFromEntries: (
    ~pluginName: string,
    ~eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
    ~eventLogHandler: (string, string) => promise<JSON.t>,
  ) => unit,
  start: (~port: int=?, unit) => unit,
  stop: unit => unit,
  reset: unit => unit,
  diagnostics: unit => diagnostics,
  printDiagnostics: unit => unit,
}

@val external processEnv: dict<string> = "process.env"
let debug = processEnv->Dict.get("MCP_DEBUG")->Option.isSome

let make = (~label: string="MCP"): t => {
  let tools: ref<dict<registeredTool>> = ref(Dict.make())
  let resources: ref<dict<registeredResource>> = ref(Dict.make())
  let resourceTemplates: ref<dict<registeredResource>> = ref(Dict.make())
  let activeServer: ref<option<McpSdk.httpServer>> = ref(None)

  let registerTool = (~name: string, ~definition, ~handler: toolHandler) => {
    tools.contents->Dict.set(name, {definition, handler})
  }

  let registerResource = (~name: string, ~definition, ~handler: resourceHandler) => {
    resources.contents->Dict.set(name, {definition, handler})
  }

  let registerResourceTemplate = (~name: string, ~definition, ~handler: resourceHandler) => {
    resourceTemplates.contents->Dict.set(name, {definition, handler})
  }

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
      if def.uriTemplate->String.includes("{") {
        registerResourceTemplate(~name=def.name, ~definition=def, ~handler)
      } else {
        registerResource(~name=def.name, ~definition=def, ~handler)
      }
    })
  }

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
      registerResourceTemplate(~name=def.name, ~definition=def, ~handler)
    })
  }

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

  let createServerInstance = (identity: Reventless.Identity.t) => {
    let server = McpSdk.newServer(
      {name: `reventless-${label->String.toLowerCase}`, version: "1.0.0"},
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
        log.info(~comp=label, `tools/call: ${toolName}`)
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
        log.info(~comp=label, `resources/read: ${uri}`)
      }
      let matchedResource =
        resources.contents
        ->Dict.valuesToArray
        ->Array.find(({definition}) => uri->String.includes(definition.name))
      switch matchedResource {
      | Some({definition, handler}) =>
        if debug {
          log.debug(~comp=label, `matched resource: ${definition.name}`)
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
            log.debug(~comp=label, `matched template: ${definition.name}`)
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
            let server = createServerInstance(identity)
            let transport = McpSdk.newStreamableHTTPTransport({
              enableJsonResponse: true,
            })
            let _ = await server->McpSdk.connect(transport)
            let _ = await transport->McpSdk.handleRequest(req, res, body)
          | "GET" =>
            res->McpSdk.setHeader("Content-Type", "text/plain")
            res->McpSdk.endResponse(`${label} server running`)
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
      log.info(~comp=label, `listening on http://localhost:${port->Int.toString}/mcp`)
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
    log.info(~comp=label, "diagnostics")
    log.info(~comp=label, `  tools (${d.toolCount->Int.toString}):`)
    d.registeredTools->Array.forEach(t => log.info(~comp=label, `    - ${t}`))
    log.info(~comp=label, `  resources (${d.resourceCount->Int.toString}):`)
    d.registeredResources->Array.forEach(r => log.info(~comp=label, `    - ${r}`))
    log.info(~comp=label, `  server running: ${d.serverRunning ? "yes" : "no"}`)
  }

  {
    registerTool,
    registerResource,
    registerResourceTemplate,
    registerToolsFromEntries,
    registerResourcesFromEntries,
    registerEventHistoryResourcesFromEntries,
    start,
    stop,
    reset,
    diagnostics,
    printDiagnostics,
  }
}
