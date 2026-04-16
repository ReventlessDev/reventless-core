// Plugin_SubscriptionSchema.res
// Generates subscription SDL fields and supporting types for a plugin.
// Called by Plugin_Builder after generateFragment to inject subscriptions into
// the fragment before it is pushed to the API and stored in the plugin definition.

open ReventlessInfra.Api

// ── Source C: mutation-triggered subscriptions ────────────────────────────────
// One field per command variant. Fires when the mutation is ACCEPTED by AppSync.
// Uses @aws_subscribe — no additional infrastructure is needed.
//
// Generated from the same mutation entries as the query/mutation SDL so that
// field names and argument types are always in sync.

let sourceCFields = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~collectedTypes: array<string>,
  ~seenTypes: Set.t<string>,
): array<string> => {
  let fields: array<string> = []
  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | Union({anyOf}) =>
      anyOf->Array.forEachWithIndex((variantSchema, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
            ~fieldName,
            ~collectedTypes,
            ~seenTypes,
            variantSchema,
          )
          ->Option.forEach(field => {
            // Mirror what generate does: prepend id: ID! to the arg list.
            let withId = if field->String.includes("(") {
              field->String.replace(`${fieldName}(`, `${fieldName}(id: ID!, `)
            } else {
              field->String.replace(`${fieldName}:`, `${fieldName}(id: ID!):`)
            }
            // Rename "  fieldName..." → "  onfieldName..." by slicing past "  fieldName".
            let sub =
              "  on" ++
              fieldName ++
              withId->String.slice(
                ~start=2 + fieldName->String.length,
                ~end=withId->String.length,
              )
            // Replace ": String!" return type with the subscription variant.
            let subWithDirective =
              sub->String.replace(
                ": String!",
                `: String\n    @aws_subscribe(mutations: ["${fieldName}"])`,
              )
            fields->Array.push(subWithDirective)
          })
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        GraphQL_FragmentGenerator.deriveMutationFieldFromObject(
          ~fieldName,
          ~collectedTypes,
          ~seenTypes,
          schema,
        )
        ->Option.forEach(field => {
          let sub =
            "  on" ++
            fieldName ++
            field->String.slice(
              ~start=2 + fieldName->String.length,
              ~end=field->String.length,
            )
          let subWithDirective =
            sub->String.replace(
              ": String!",
              `: String\n    @aws_subscribe(mutations: ["${fieldName}"])`,
            )
          fields->Array.push(subWithDirective)
        })
      }
    | _ => ()
    }
  })
  fields
}

// ── Source B: state-change subscriptions ─────────────────────────────────────
// One field per ReadModel / StateViewSlice. Fires after an event is fully
// projected into the QueryDb (pushed via AppSync Events API — no @aws_subscribe).
//
// The optional `id` arg enables server-side AppSync subscription filters so
// clients only receive updates for the specific entity they are watching.

let sourceBFields = (~queryEntries: array<querySchemaEntry>): array<string> => {
  let seen: Set.t<string> = Set.make()
  queryEntries->Array.filterMap(entry => {
    let typeName = entry.returnTypeName
    if seen->Set.has(typeName) {
      None
    } else {
      seen->Set.add(typeName)
      Some(`  on${typeName}_stateChanged(id: ID): ${typeName}`)
    }
  })
}

// ── Source A: raw event stream subscriptions ──────────────────────────────────
// One field per EventLog (aggregate or DCB). Fires when an event is appended.
// Pushed via AppSync Events API. Admin / observability only.
//
// Returns (subscriptionFields, supportingTypes) — the supporting type is the
// {DisplayName}EventLogEvent type that carries position, eventType, payload, and
// the optional originatorSlice tag injected by StateChangeSlice_Callback.

let sourceAFieldsAndTypes = (
  ~eventLogEntries: array<eventLogSchemaEntry>,
): (array<string>, array<string>) => {
  let seen: Set.t<string> = Set.make()
  let fields: array<string> = []
  let types: array<string> = []
  eventLogEntries->Array.forEach(entry => {
    let n = entry.displayName
    if !(seen->Set.has(n)) {
      seen->Set.add(n)
      fields->Array.push(`  on${n}EventLog_eventAppended: ${n}EventLogEvent`)
      types->Array.push(
        `type ${n}EventLogEvent {\n  position: String!\n  eventType: String!\n  payload: AWSJSON!\n  originatorSlice: String\n}`,
      )
    }
  })
  (fields, types)
}

// ── Public API ────────────────────────────────────────────────────────────────

type result = {
  subscriptionFields: array<string>,
  extraTypes: array<string>,
}

let generate = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
  ~eventLogEntries: array<eventLogSchemaEntry>,
): result => {
  let mutationTypes: array<string> = []
  let mutationSeen: Set.t<string> = Set.make()
  let cFields = sourceCFields(
    ~mutationEntries,
    ~collectedTypes=mutationTypes,
    ~seenTypes=mutationSeen,
  )
  let bFields = sourceBFields(~queryEntries)
  let (aFields, aTypes) = sourceAFieldsAndTypes(~eventLogEntries)
  {
    subscriptionFields: Array.flat([cFields, bFields, aFields]),
    extraTypes: Array.flat([aTypes, mutationTypes]),
  }
}
