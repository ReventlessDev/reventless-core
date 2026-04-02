open Jest
open Expect

let resource: Resource.t = {
  name: "my-table",
  id: "abc123",
  urn: "urn:pulumi:stack::project::resource",
  resourceInfo: StorageKeys({hashKey: "id", rangeKey: None}),
  service: "dynamodb",
  role: "",
  region: "",
  resourceType: "",
  configuration: Dict.make(),
}

let queryDb: QueryDb.resolvedOutputs = {resources: [resource]}
let readModelQueryDb: ReadModel.queryDb = {resources: [resource]}
let eventTopicOutputs: EventTopic.resolvedOutputs = {resources: [resource]}

describe("DCB interop types — round-trip serialization", () => {
  test("DcbEventLog.resolvedOutputs round-trips", () => {
    let original: DcbEventLog.resolvedOutputs = {
      resources: [resource],
      eventTopic: eventTopicOutputs,
    }
    let json = original->S.reverseConvertToJsonOrThrow(DcbEventLog.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(DcbEventLog.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("StateChangeSlice.resolvedOutputs round-trips", () => {
    let original: StateChangeSlice.resolvedOutputs = {resources: [resource]}
    let json = original->S.reverseConvertToJsonOrThrow(StateChangeSlice.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(StateChangeSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("StateViewSlice.resolvedOutputs round-trips", () => {
    let original: StateViewSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.reverseConvertToJsonOrThrow(StateViewSlice.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(StateViewSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("AutomationSlice.resolvedOutputs round-trips", () => {
    let original: AutomationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.reverseConvertToJsonOrThrow(AutomationSlice.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(AutomationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("OutboundTranslationSlice.resolvedOutputs round-trips", () => {
    let original: OutboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.reverseConvertToJsonOrThrow(OutboundTranslationSlice.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(OutboundTranslationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("InboundTranslationSlice.resolvedOutputs round-trips", () => {
    let original: InboundTranslationSlice.resolvedOutputs = {resources: [resource], queryDb}
    let json = original->S.reverseConvertToJsonOrThrow(InboundTranslationSlice.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(InboundTranslationSlice.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("QueryDb.resolvedOutputs round-trips", () => {
    let original: QueryDb.resolvedOutputs = {resources: [resource]}
    let json = original->S.reverseConvertToJsonOrThrow(QueryDb.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(QueryDb.resolvedOutputsSchema)
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
  test("Aggregate.resolvedOutputs round-trips (without eventMapper)", () => {
    let original: Aggregate.resolvedOutputs = {
      name: "Customer",
      commandGenerator: commandGeneratorOutputs,
      commandTopic: commandTopicOutputs,
      eventLog: eventLogOutputs,
    }
    let json = original->S.reverseConvertToJsonOrThrow(Aggregate.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Aggregate.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("Aggregate.resolvedOutputs round-trips (with eventMapper)", () => {
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
    let json = original->S.reverseConvertToJsonOrThrow(Aggregate.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Aggregate.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("EventLog.resolvedOutputs round-trips", () => {
    let json = eventLogOutputs->S.reverseConvertToJsonOrThrow(EventLog.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(EventLog.resolvedOutputsSchema)
    expect(parsed)->toEqual(eventLogOutputs)
  })

  test("CommandGenerator.resolvedOutputs round-trips", () => {
    let json =
      commandGeneratorOutputs->S.reverseConvertToJsonOrThrow(
        CommandGenerator.resolvedOutputsSchema,
      )
    let parsed = json->S.parseOrThrow(CommandGenerator.resolvedOutputsSchema)
    expect(parsed)->toEqual(commandGeneratorOutputs)
  })
})

describe("Plugin.resolvedOutputs — round-trip with DCB fields", () => {
  test("minimal plugin (no optional fields) round-trips", () => {
    let original: Plugin.resolvedOutputs = {id: "test@1.0", version: "1.0.0"}
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("plugin with readModels round-trips", () => {
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
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("plugin with DCB slices round-trips", () => {
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
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("plugin with aggregates round-trips", () => {
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
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("plugin with all fields round-trips", () => {
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
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })

  test("minimal plugin without optional fields round-trips", () => {
    let original: Plugin.resolvedOutputs = {id: "empty@1.0", version: "1.0.0"}
    let json = original->S.reverseConvertToJsonOrThrow(Plugin.resolvedOutputsSchema)
    let parsed = json->S.parseOrThrow(Plugin.resolvedOutputsSchema)
    expect(parsed)->toEqual(original)
  })
})
