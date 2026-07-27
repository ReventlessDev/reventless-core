open JestGlobals

// The event-history query is the read counterpart of the Source A raw-event
// subscription. These tests pin the two properties that make it safe to expose:
// it is deduped per event log exactly as the subscription is, and it leaks none
// of the transport / tenant-context fields of `Message.meta`.

module SomeEvent = {
  @schema
  type event = Happened({thingId: string})
}

let entry = (~displayName): ReventlessInfra.Api.eventLogSchemaEntry => {
  busKey: displayName ++ "AggrEventLog",
  displayName,
  eventSchema: SomeEvent.eventSchema->S.castToUnknown,
}

let allTypes = (r: Plugin_EventQuerySchema.result) => r.extraTypes->Array.join("\n")

describe("Plugin_EventQuerySchema.generate", () => {
  testSync("emits one history query per event log, plugin-prefixed", () => {
    let r = Plugin_EventQuerySchema.generate(
      ~plugin="Ordering",
      ~eventLogEntries=[entry(~displayName="Order"), entry(~displayName="Shipment")],
    )
    expect(r.queryFields->Array.length)->toBe(2)
    let joined = r.queryFields->Array.join("\n")
    expect(joined->String.includes("Ordering_OrderEventHistory("))->toBe(true)
    expect(joined->String.includes("Ordering_ShipmentEventHistory("))->toBe(true)
    // Relay connection args + return type, identical in shape to every other
    // list query — existing client pagination applies unchanged.
    expect(joined->String.includes("first: Int, after: String, last: Int, before: String"))->toBe(
      true,
    )
    expect(joined->String.includes(": Ordering_OrderEventRecordConnection!"))->toBe(true)
  })

  testSync("dedupes by display name — one logical stream, one field", () => {
    let r = Plugin_EventQuerySchema.generate(
      ~plugin="Ordering",
      ~eventLogEntries=[entry(~displayName="Order"), entry(~displayName="Order")],
    )
    expect(r.queryFields->Array.length)->toBe(1)
  })

  testSync("record carries the audit-relevant meta subset and nothing else", () => {
    let sdl = allTypes(
      Plugin_EventQuerySchema.generate(
        ~plugin="Ordering",
        ~eventLogEntries=[entry(~displayName="Order")],
      ),
    )
    expect(sdl->String.includes("type EventMeta {"))->toBe(true)
    ["user", "time", "service", "msgId", "correlationId", "causationId"]->Array.forEach(f =>
      expect(sdl->String.includes(f))->toBe(true)
    )
    // Transport / tracing detail and the cross-cutting context bag must not
    // leave the server — see the module comment.
    ["ip:", "traceparent", "schemaVersion", "headers"]->Array.forEach(f =>
      expect(sdl->String.includes(f))->toBe(false)
    )
  })

  testSync("record exposes position, payload, tags and both timestamps", () => {
    let sdl = allTypes(
      Plugin_EventQuerySchema.generate(
        ~plugin="Ordering",
        ~eventLogEntries=[entry(~displayName="Order")],
      ),
    )
    expect(sdl->String.includes("type Ordering_OrderEventRecord {"))->toBe(true)
    ["position: String!", "eventType: String!", "payload: AWSJSON!", "tags: [EventTag!]!", "meta: EventMeta!", "recordedAt: String!"]->Array.forEach(
      f => expect(sdl->String.includes(f))->toBe(true),
    )
  })

  testSync("filter offers the entity shortcut and the precise tag pair", () => {
    let sdl = allTypes(
      Plugin_EventQuerySchema.generate(
        ~plugin="Ordering",
        ~eventLogEntries=[entry(~displayName="Order")],
      ),
    )
    expect(sdl->String.includes("input Ordering_OrderEventHistoryFilter {"))->toBe(true)
    ["entityId: ID", "tagKey: String", "tagValue: String", "eventTypes: [String!]", "user: String", "timeFrom: String", "timeTo: String"]->Array.forEach(
      f => expect(sdl->String.includes(f))->toBe(true),
    )
  })

  testSync("a plugin with no event logs emits nothing at all", () => {
    let r = Plugin_EventQuerySchema.generate(~plugin="Ordering", ~eventLogEntries=[])
    expect(r.queryFields->Array.length)->toBe(0)
    // Not even the shared types — an empty fragment stays byte-identical to
    // what it was before this generator existed.
    expect(r.extraTypes->Array.length)->toBe(0)
  })
})
