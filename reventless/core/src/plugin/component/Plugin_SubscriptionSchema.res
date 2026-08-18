// Plugin_SubscriptionSchema.res
// Generates subscription SDL fields and supporting types for a plugin.
// Called by Plugin_Builder after generateFragment to inject subscriptions into
// the fragment before it is pushed to the API and stored in the plugin definition.

open ReventlessInfra.Api

// ── Source C: mutation-triggered subscriptions ────────────────────────────────
// One field per command variant. Fires when the mutation is accepted.
// The SDL emitted here is provider-neutral; the subscription→mutation link is
// carried as structured `subscriptionSource` metadata on the fragment. Each
// provider adds its own wiring (AppSync appends `@aws_subscribe` at push time;
// the local platform routes its PubSub bridge from the same metadata).
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
): (array<string>, array<GraphQL_Stitcher.subscriptionSource>) => {
  let fields: array<string> = []
  let sources: array<GraphQL_Stitcher.subscriptionSource> = []
  let pushField = (fieldName: string) => {
    // AppSync caps subscription field names at 50 chars. A mutation whose `on<field>`
    // Source-C subscription would exceed that (e.g. the admin-aggregate-convention
    // `Platform_ApiFragmentRegistry_DeregisterApiFragment` → 52) simply gets NO
    // mutation-triggered subscription — the field is dropped here so the pushed SDL stays
    // valid, and the resolver side (CommandSubscriptionResolvers) applies the same gate so
    // no orphan resolver is created. Plugin mutations are far under the cap and unaffected.
    if `on${fieldName}`->String.length <= Api_Naming.appSyncSubscriptionMaxLen {
      fields->Array.push(`  on${fieldName}(id: ID): CommandResult`)
      sources->Array.push({GraphQL_Stitcher.field: `on${fieldName}`, mutations: [fieldName]})
    }
  }
  mutationEntries->Array.forEach(entry => {
    let schema = entry.commandSchema
    switch schema {
    | AnyOf({anyOf}) =>
      anyOf->Array.forEachWithIndex((_, i) => {
        let fieldName = entry.fieldNames->Array.get(i)->Option.getOr("")
        if fieldName->String.length > 0 {
          pushField(fieldName)
        }
      })
    | Object(_) =>
      let fieldName = entry.fieldNames->Array.get(0)->Option.getOr("")
      if fieldName->String.length > 0 {
        pushField(fieldName)
      }
    | _ => ()
    }
  })
  (fields, sources)
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
// {DisplayName}EventLogEvent type that carries position, eventType, and payload.

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
        `type ${n}EventLogEvent {\n  position: String!\n  eventType: String!\n  payload: AWSJSON!\n}`,
      )
    }
  })
  (fields, types)
}

// ── Public API ────────────────────────────────────────────────────────────────

type result = {
  subscriptionFields: array<string>,
  extraTypes: array<string>,
  subscriptionSources: array<GraphQL_Stitcher.subscriptionSource>,
}

let generate = (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~eventLogEntries: array<eventLogSchemaEntry>,
): result => {
  let (cFields, cSources) = sourceCFields(~mutationEntries)
  let (aFields, aTypes) = sourceAFieldsAndTypes(~eventLogEntries)
  // Source A fields carry no source mapping — they are pushed via the
  // provider's events channel, not triggered by a mutation.
  {
    subscriptionFields: Array.flat([cFields, aFields]),
    extraTypes: aTypes,
    subscriptionSources: cSources,
  }
}
