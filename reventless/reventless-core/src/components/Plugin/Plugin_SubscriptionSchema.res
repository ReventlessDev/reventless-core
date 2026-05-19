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

// AppSync subscriptions have a hard limit of 5 input arguments.
// Source C subscriptions only use `id` for server-side filtering (ctx.args.id),
// so all subscription fields are generated with a single optional `id: ID` arg
// regardless of how many args the corresponding mutation carries.
//
// Every aggregate-derived mutation now returns CommandResult (a union of
// CommandAccepted | CommandRejected | CommandPending). AppSync requires the
// subscription return type to be a strict subset of the linked mutation's
// return type, so the subscription field has to declare CommandResult as well.
let sourceCFields = (
  ~mutationEntries: array<mutationSchemaEntry>,
): array<string> => {
  let fields: array<string> = []
  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | Union({anyOf}) =>
      anyOf->Array.forEachWithIndex((_, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          let sub = `  on${fieldName}(id: ID): CommandResult\n    @aws_subscribe(mutations: ["${fieldName}"])`
          fields->Array.push(sub)
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        let sub = `  on${fieldName}(id: ID): CommandResult\n    @aws_subscribe(mutations: ["${fieldName}"])`
        fields->Array.push(sub)
      }
    | _ => ()
    }
  })
  fields
}

// ── Source B: state-change subscriptions ─────────────────────────────────────
// State changes are pushed directly via AppSync Events channels (one channel
// per QueryDb row), not through a GraphQL Subscription field. Clients open a
// WebSocket against the Events API endpoint and subscribe to a channel pattern
// like `/default/{topicRoot}/{entityKey}` (or `/default/{topicRoot}/*` for a
// list view). No SDL is generated here — see `StateTopic_AppSync.res` for the
// publish path.

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
  ~eventLogEntries: array<eventLogSchemaEntry>,
): result => {
  let cFields = sourceCFields(~mutationEntries)
  let (aFields, aTypes) = sourceAFieldsAndTypes(~eventLogEntries)
  {
    subscriptionFields: Array.flat([cFields, aFields]),
    extraTypes: aTypes,
  }
}
