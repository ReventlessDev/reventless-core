// MCP schema generator.
// Derives MCP tool and resource definitions from sury schemas
// using the shared SuryToJsonSchema utility.

open ReventlessInfra.Api

let extractVariantNames = Reventless.DcbTag.extractVariantNames

// ─── MCP definition types ─────────────────────────────────────────────────

type mcpToolDefinition = {
  name: string,
  description: string,
  inputSchema: JSON.t,
}

type mcpResourceDefinition = {
  uriTemplate: string,
  name: string,
  description: string,
  mimeType: string,
}

// ─── Tool generation ──────────────────────────────────────────────────────

/** Generate MCP tool definitions from mutation entries.
    Each command variant becomes a separate tool. */
let generateTools = (
  ~pluginName: string,
  ~mutationEntries: array<mutationSchemaEntry>,
): array<mcpToolDefinition> => {
  let tools: array<mcpToolDefinition> = []

  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    let entryDescription = entry.description->Option.getOr("")

    switch schema {
    | Union({anyOf}) =>
      // Aggregate commands: each variant is a separate tool.
      // Inject an "id" property (aggregate instance ID) since aggregate
      // commands target a specific instance.
      anyOf->Array.forEachWithIndex((variantSchema, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          let inputSchema = SuryToJsonSchema.deriveObjectSchema(variantSchema)
          // Add "id" to the JSON Schema properties and required list
          let withId = switch inputSchema->JSON.Decode.object {
          | Some(obj) =>
            let props = switch obj->Dict.get("properties") {
            | Some(p) =>
              switch p->JSON.Decode.object {
              | Some(propsDict) =>
                // Build new dict with "id" first so it appears first in the schema
                let ordered = Dict.fromArray([
                  ("id", SuryToJsonSchema.jsonObject([("type", SuryToJsonSchema.str("string"))])),
                ])
                propsDict->Dict.toArray->Array.forEach(((k, v)) => ordered->Dict.set(k, v))
                JSON.Encode.object(ordered)
              | None => p
              }
            | None => JSON.Encode.null
            }
            obj->Dict.set("properties", props)
            // Add "id" to required array
            switch obj->Dict.get("required") {
            | Some(req) =>
              switch req->JSON.Decode.array {
              | Some(arr) =>
                arr->Array.unshift(JSON.Encode.string("id"))
                obj->Dict.set("required", JSON.Encode.array(arr))
              | None => ()
              }
            | None =>
              obj->Dict.set("required", JSON.Encode.array([JSON.Encode.string("id")]))
            }
            JSON.Encode.object(obj)
          | None => inputSchema
          }
          let desc =
            entryDescription->String.length > 0
              ? entryDescription
              : `Execute ${fieldName} on ${pluginName}`
          tools->Array.push({name: fieldName, description: desc, inputSchema: withId})
        }
      })
    | Object(_) =>
      // Single command (e.g. DCB StateChangeSlice)
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        let inputSchema = SuryToJsonSchema.deriveObjectSchema(schema)
        let desc =
          entryDescription->String.length > 0
            ? entryDescription
            : `Execute ${fieldName} on ${pluginName}`
        tools->Array.push({name: fieldName, description: desc, inputSchema})
      }
    | _ => ()
    }
  })

  tools
}

// ─── Resource generation ──────────────────────────────────────────────────

/** Generate MCP resource definitions from query entries.
    Each query entry becomes one or two resources (single + list). */
let generateResources = (
  ~pluginName: string,
  ~queryEntries: array<querySchemaEntry>,
): array<mcpResourceDefinition> => {
  let resources: array<mcpResourceDefinition> = []

  queryEntries->Array.forEach(entry => {
    let entryDescription = entry.description->Option.getOr("")

    // Single-item resource with ID parameter
    let singleDesc =
      entryDescription->String.length > 0
        ? entryDescription
        : `Read a single ${entry.returnTypeName} by ID`
    resources->Array.push({
      uriTemplate: `${pluginName}/${entry.singleFieldName}/{id}`,
      name: entry.returnTypeName,
      description: singleDesc,
      mimeType: "application/json",
    })

    // List resource
    let listFieldName = entry.listFieldName
    let listDesc = `List all ${listFieldName}`
    resources->Array.push({
      uriTemplate: `${pluginName}/${listFieldName}`,
      name: listFieldName,
      description: listDesc,
      mimeType: "application/json",
    })
  })

  resources
}

// ─── Event history resource generation ───────────────────────────────────

/** Generate MCP resource definitions from event log entries.
    Each entry becomes a single-entity event history resource. */
let generateEventHistoryResources = (
  ~pluginName: string,
  ~eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
): array<mcpResourceDefinition> => {
  let resources: array<mcpResourceDefinition> = []

  eventLogEntries->Array.forEach(entry => {
    let eventTypes = extractVariantNames(entry.eventSchema)
    let typeList = eventTypes->Array.join(", ")

    resources->Array.push({
      uriTemplate: `${pluginName}/${entry.displayName}_events/{entityId}`,
      name: `${entry.displayName}_events`,
      description: `Event history for ${entry.displayName}. Event types: ${typeList}`,
      mimeType: "application/json",
    })
  })

  resources
}
