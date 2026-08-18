open JestGlobals

// FACET 1 — FIXED in sury 11.0.0-alpha.10. A `None` sortKey (encodes to `null`
// via `Resource.stringOptionSchema` = `S.nullAsOption`) now round-trips even when
// nested as `array<Resource.t>` inside a resolvedOutputs object. alpha.8/alpha.9
// dropped the `@s.matches(nullAsOption)` reverse transform at that depth and
// rejected the `null` it had just encoded; alpha.10 applies it symmetrically.
// The fixture below therefore uses `sortKey: None` (the previously-failing case)
// so every nested round-trip exercises it. Original repro + writeup:
// docs/analysis/done/sury-alpha8-nullasoption-reverse-bug.md.
//
// FACET 2 — FIXED in sury 11.0.0-alpha.11. A plain-`None` optional record field
// (`eventMapper?`, `counter?`) serialises to `undefined`, which alpha.8-alpha.10
// rejected as non-jsonable when nested inside a structure encoded to `S.json`
// ("Expected undefined | JSON, received {… undefined …}"). alpha.11 omits those
// fields on encode, as alpha.4's `reverseConvertToJsonOrThrow` did. The three
// tests below that build such a nested `None` optional run again. Writeup:
// docs/analysis/done/sury-alpha10-undefined-optional-in-json.issue.md.
let resource: Resource.t = {
  name: "my-table",
  id: "abc123",
  urn: "urn:pulumi:stack::project::resource",
  resourceInfo: StorageKeys({partitionKey: "id", sortKey: None}),
  service: "dynamodb",
  role: "",
  region: "",
  resourceType: "",
  configuration: Dict.make(),
  tags: Dict.make(),
}

let queryDb: QueryDb.resolvedOutputs = {resources: [resource]}
let readModelQueryDb: ReadModel.queryDb = {resources: [resource]}
let eventTopicOutputs: EventTopic.resolvedOutputs = {resources: [resource]}

describe("DCB interop types — round-trip serialization", () => {
  testSync("DcbEventLog.resolvedOutputs round-trips", () => {
    let original: DcbEventLog.resolvedOutputs = {
      resources: [resource],
      eventTopic: eventTopicOutputs,
    }
    let json = original->S.decodeOrThrow(~from=DcbEventLog.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=DcbEventLog.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("StateChangeSlice.resolvedOutputs round-trips", () => {
    let original: StateChangeSlice.resolvedOutputs = {resources: [resource]}
    let json = original->S.decodeOrThrow(~from=StateChangeSlice.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=StateChangeSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("StateViewSlice.resolvedOutputs round-trips", () => {
    let original: StateViewSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.decodeOrThrow(~from=StateViewSlice.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=StateViewSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("AutomationSlice.resolvedOutputs round-trips", () => {
    let original: AutomationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.decodeOrThrow(~from=AutomationSlice.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=AutomationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("OutboundTranslationSlice.resolvedOutputs round-trips", () => {
    let original: OutboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.decodeOrThrow(~from=OutboundTranslationSlice.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=OutboundTranslationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("InboundTranslationSlice.resolvedOutputs round-trips", () => {
    let original: InboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.decodeOrThrow(~from=InboundTranslationSlice.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=InboundTranslationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("QueryDb.resolvedOutputs round-trips", () => {
    let original: QueryDb.resolvedOutputs = {resources: [resource]}
    let json = original->S.decodeOrThrow(~from=QueryDb.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=QueryDb.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })
})

let commandTopicOutputs: CommandTopic.resolvedOutputs = {resources: [resource]}
let commandGeneratorOutputs: CommandGenerator.resolvedOutputs = {resources: [resource]}
let eventLogOutputs: EventLog.resolvedOutputs = {
  resources: [resource],
  eventTopic: eventTopicOutputs,
}

describe("Aggregate interop types — round-trip serialization", () => {
  testSync("Aggregate.resolvedOutputs round-trips (without eventMapper)", () => {
    let original: Aggregate.resolvedOutputs = {
      name: "Customer",
      commandGenerator: commandGeneratorOutputs,
      commandTopic: commandTopicOutputs,
      eventLog: eventLogOutputs,
    }
    let json = original->S.decodeOrThrow(~from=Aggregate.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Aggregate.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("Aggregate.resolvedOutputs round-trips (with eventMapper)", () => {
    let em: EventMapper.resolvedOutputs = {
      name: "CustomerMapper",
      eventCollector: {name: "CustomerMapperEC", resources: [resource]},
    }
    let original: Aggregate.resolvedOutputs = {
      name: "Customer",
      commandGenerator: commandGeneratorOutputs,
      commandTopic: commandTopicOutputs,
      eventLog: eventLogOutputs,
      eventMapper: em,
    }
    let json = original->S.decodeOrThrow(~from=Aggregate.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Aggregate.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("EventLog.resolvedOutputs round-trips", () => {
    let json = eventLogOutputs->S.decodeOrThrow(~from=EventLog.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=EventLog.resolvedOutputsSchema)
    expect(parsed)->toEqual(eventLogOutputs)
  })

  testSync("CommandGenerator.resolvedOutputs round-trips", () => {
    let json =
      commandGeneratorOutputs->S.decodeOrThrow(
        ~from=CommandGenerator.resolvedOutputsSchema,
        ~to=S.json,
      )
    let parsed = json->S.parseOrThrow(~to=CommandGenerator.resolvedOutputsSchema)
    expect(parsed)->toEqual(commandGeneratorOutputs)
  })
})

describe("Plugin.resolvedOutputs — round-trip with DCB fields", () => {
  testSync("minimal plugin (no optional fields) round-trips", () => {
    let original: Plugin.resolvedOutputs = {id: "test@1.0", version: "1.0.0"}
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("plugin with readModels round-trips", () => {
    let rm: ReadModel.resolvedOutputs = {
      name: "MyRM",
      queryDb: readModelQueryDb,
      sourceNames: ["Agg1"],
    }
    let original: Plugin.resolvedOutputs = {
      id: "test@1.0",
      version: "1.0.0",
      readModels: Dict.fromArray([("MyRM", rm)]),
    }
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("plugin with DCB slices round-trips", () => {
    let dcbLog: DcbEventLog.resolvedOutputs = {
      resources: [resource],
      eventTopic: eventTopicOutputs,
    }
    let scs: StateChangeSlice.resolvedOutputs = {resources: [resource]}
    let svs: StateViewSlice.resolvedOutputs = {resources: [resource], queryDb}
    let auto: AutomationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let ots: OutboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let its: InboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let original: Plugin.resolvedOutputs = {
      id: "dcb-plugin@1.0",
      version: "1.0.0",
      dcbEventLog: dcbLog,
      stateChangeSlices: Dict.fromArray([("AddItem", scs)]),
      stateViewSlices: Dict.fromArray([("ItemsView", svs)]),
      automationSlices: Dict.fromArray([("ShipOrder", auto)]),
      outboundTranslationSlices: Dict.fromArray([("SendEmail", ots)]),
      inboundTranslationSlices: Dict.fromArray([("PaymentHook", its)]),
    }
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("plugin with aggregates round-trips", () => {
    let agg: Aggregate.resolvedOutputs = {
      name: "Customer",
      commandGenerator: commandGeneratorOutputs,
      commandTopic: commandTopicOutputs,
      eventLog: eventLogOutputs,
    }
    let original: Plugin.resolvedOutputs = {
      id: "agg@1.0",
      version: "1.0.0",
      aggregates: Dict.fromArray([("Customer", agg)]),
    }
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("plugin with all fields round-trips", () => {
    let ep: ExtensionPoint.resolvedOutputs = {
      name: "MyEP",
      commandTopic: {resources: [resource]},
      eventTopic: eventTopicOutputs,
    }
    let rm: ReadModel.resolvedOutputs = {
      name: "RM1",
      queryDb: readModelQueryDb,
      sourceNames: ["Agg1"],
    }
    let agg: Aggregate.resolvedOutputs = {
      name: "Agg1",
      commandGenerator: commandGeneratorOutputs,
      commandTopic: commandTopicOutputs,
      eventLog: eventLogOutputs,
    }
    let dcbLog: DcbEventLog.resolvedOutputs = {
      resources: [resource],
      eventTopic: eventTopicOutputs,
    }
    let scs: StateChangeSlice.resolvedOutputs = {resources: [resource]}
    let svs: StateViewSlice.resolvedOutputs = {resources: [resource], queryDb}
    let auto: AutomationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let ots: OutboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let its: InboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let original: Plugin.resolvedOutputs = {
      id: "full@2.0",
      version: "2.0.0",
      aggregates: Dict.fromArray([("Agg1", agg)]),
      readModels: Dict.fromArray([("RM1", rm)]),
      extensionPoints: Dict.fromArray([("MyEP", ep)]),
      dcbEventLog: dcbLog,
      stateChangeSlices: Dict.fromArray([("SCS1", scs)]),
      stateViewSlices: Dict.fromArray([("SVS1", svs)]),
      automationSlices: Dict.fromArray([("AS1", auto)]),
      outboundTranslationSlices: Dict.fromArray([("OTS1", ots)]),
      inboundTranslationSlices: Dict.fromArray([("ITS1", its)]),
    }
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  testSync("minimal plugin without optional fields round-trips", () => {
    let original: Plugin.resolvedOutputs = {id: "empty@1.0", version: "1.0.0"}
    let json = original->S.decodeOrThrow(~from=Plugin.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  // FACET 1 regression guard: a `StorageKeys` with `sortKey: None` (encodes to
  // `null` via `S.nullAsOption`) nested as `array<Resource.t>` inside a
  // resolvedOutputs object must PARSE back to `None`. This threw on alpha.8/alpha.9
  // (reverse `nullAsOption` transform dropped at depth) and is fixed in alpha.10.
  // Repro + writeup: docs/analysis/done/sury-alpha8-nullasoption-reverse-bug.md.
  testSync("StorageKeys(None) sortKey round-trips through nested resolvedOutputs", () => {
    let noSortKey: Resource.t = {
      ...resource,
      resourceInfo: StorageKeys({partitionKey: "id", sortKey: None}),
    }
    let original: QueryDb.resolvedOutputs = {resources: [noSortKey]}
    let json = original->S.decodeOrThrow(~from=QueryDb.resolvedOutputsSchema, ~to=S.json)
    let parsed = json->S.parseOrThrow(~to=QueryDb.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })
})
