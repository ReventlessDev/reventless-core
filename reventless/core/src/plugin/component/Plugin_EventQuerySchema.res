// Plugin_EventQuerySchema.res
// Generates the query counterpart of the Source A raw-event subscription:
// one paginated `…EventHistory` connection per event log, so a client can ask
// "what happened to this entity, in order, with who and when".
//
// Called by Plugin_Builder alongside Plugin_SubscriptionSchema, from the same
// `eventLogEntries` array — so the query and the subscription can never drift
// about which logs exist.
//
// The subscription (Plugin_SubscriptionSchema.sourceAFieldsAndTypes) answers
// "something was just appended" and deliberately carries no envelope metadata.
// This answers a historical question, so it carries the audit-relevant subset
// of `Message.meta`: who (`user`), when (`time`), and the correlation /
// causation chain. Transport and tracing fields (`ip`, `traceparent`,
// `schemaVersion`) and the `headers` context bag are NOT exposed — `headers`
// in particular carries cross-cutting context (tenant ids, feature flags) that
// should not leave the server.

open ReventlessInfra.Api

// Shared supporting types, emitted once per fragment. The stitcher dedupes by
// type name across fragments, so concatenating plugin + admin fragments stays
// safe — the same contract `commandResultSdlTypes` relies on.
let sharedSdlTypes: array<string> = [
  `type EventMeta {
  service: String!
  time: String!
  user: String
  msgId: String!
  correlationId: String!
  causationId: String
}`,
  `type EventTag {
  key: String!
  value: String!
}`,
]

let recordTypeName = (~plugin: string, ~displayName: string) =>
  `${plugin}_${displayName}EventRecord`

let historyFieldName = (~plugin: string, ~displayName: string) =>
  `${plugin}_${displayName}EventHistory`

let filterTypeName = (~plugin: string, ~displayName: string) =>
  `${plugin}_${displayName}EventHistoryFilter`

let recordSdl = (~typeName: string): string =>
  `type ${typeName} {
  position: String!
  eventType: String!
  payload: AWSJSON!
  tags: [EventTag!]!
  meta: EventMeta!
  recordedAt: String!
}`

let connectionSdlTypes = (~typeName: string): array<string> => [
  `type ${typeName}Edge {\n  node: ${typeName}!\n  cursor: String!\n}`,
  `type ${typeName}Connection {\n  edges: [${typeName}Edge!]!\n  pageInfo: PageInfo!\n}`,
]

// `entityId` is the ergonomic filter and the audit-trail case: for an
// aggregate log it matches the aggregate id, for a DCB log it matches ANY tag
// value (the same semantics the MCP event-history handler uses).
// `tagKey` + `tagValue` is the precise form, for a DCB event carrying several
// ids where you mean one specific one.
let filterSdl = (~typeName: string): string =>
  `input ${typeName} {
  entityId: ID
  tagKey: String
  tagValue: String
  eventTypes: [String!]
  user: String
  timeFrom: String
  timeTo: String
}`

type result = {
  queryFields: array<string>,
  extraTypes: array<string>,
}

/**
Emit the event-history query field + supporting types for every distinct event
log in `eventLogEntries`.

Deduped by `displayName` exactly as the Source A subscription is: an aggregate
and a DCB log that project the same display name describe one logical stream.
*/
let generate = (~plugin: string, ~eventLogEntries: array<eventLogSchemaEntry>): result => {
  let seen: Set.t<string> = Set.make()
  let queryFields: array<string> = []
  let extraTypes: array<string> = []

  eventLogEntries->Array.forEach(entry => {
    let displayName = entry.displayName
    if !(seen->Set.has(displayName)) {
      seen->Set.add(displayName)
      let typeName = recordTypeName(~plugin, ~displayName)
      let filterName = filterTypeName(~plugin, ~displayName)
      let fieldName = historyFieldName(~plugin, ~displayName)

      extraTypes->Array.push(recordSdl(~typeName))
      connectionSdlTypes(~typeName)->Array.forEach(t => extraTypes->Array.push(t))
      extraTypes->Array.push(filterSdl(~typeName=filterName))

      queryFields->Array.push(
        `  ${fieldName}(filter: ${filterName}, first: Int, after: String, last: Int, before: String): ${typeName}Connection!`,
      )
    }
  })

  // Only pull in the shared types when this fragment actually emits a record
  // type that references them — a plugin with no event logs stays untouched.
  if queryFields->Array.length > 0 {
    sharedSdlTypes->Array.forEach(t => extraTypes->Array.push(t))
  }

  {queryFields, extraTypes}
}
