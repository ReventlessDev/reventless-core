// MCP schema generator.
// Derives MCP tool and resource definitions from sury schemas
// using the shared SuryToJsonSchema utility.

open ReventlessInfra.Api

let extractEventTypes = Reventless.DcbTag.extractEventTypes

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
      // Aggregate commands: each variant is a separate tool
      anyOf->Array.forEachWithIndex((variantSchema, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          let inputSchema = SuryToJsonSchema.deriveVariantSchema(variantSchema)
          let desc =
            entryDescription->String.length > 0
              ? entryDescription
              : `Execute ${fieldName} on ${pluginName}`
          tools->Array.push({name: fieldName, description: desc, inputSchema})
        }
      })
    | Object(_) =>
      // Single command (e.g. DCB StateChangeSlice)
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        let inputSchema = SuryToJsonSchema.deriveVariantSchema(schema)
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
  let pluginLower = pluginName->String.toLowerCase

  queryEntries->Array.forEach(entry => {
    let entryDescription = entry.description->Option.getOr("")

    // Single-item resource with ID parameter
    let singleDesc =
      entryDescription->String.length > 0
        ? entryDescription
        : `Read a single ${entry.returnTypeName} by ID`
    resources->Array.push({
      uriTemplate: `${pluginLower}/${entry.singleFieldName}/{id}`,
      name: entry.returnTypeName,
      description: singleDesc,
      mimeType: "application/json",
    })

    // List resource (if listFieldName is provided)
    entry.listFieldName->Option.forEach(listFieldName => {
      let listDesc = `List all ${listFieldName}`
      resources->Array.push({
        uriTemplate: `${pluginLower}/${listFieldName}`,
        name: listFieldName,
        description: listDesc,
        mimeType: "application/json",
      })
    })
  })

  resources
}
