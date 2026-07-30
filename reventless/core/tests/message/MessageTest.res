open JestGlobals
open Message

type event = event'<string, PluginSpec.event>

describe("Message should", () => {
  testSync("create a valid sequenceNr", () => {
    let now = 123456789.
    let hrtime = (1, 1)
    expect(hrtimeToString(~hrtime, ~now))->toBe("123456789-000000001")
  })

  testSync("get variant name of json without payload", () => {
    let variant = PluginSpec.Heartbeat("0.0.0")
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    expect(variantName)->toBe("Heartbeat")
  })

  testSync("get variant name of json with payload", () => {
    let variant = PluginSpec.Connect({
      id: "id",
      name: "testName",
      version: "testVersion",
      extensionPoints: [
        {
          name: "testExtensionPoint",
          commandTopic: "testCommandTopic",
          eventTopic: "testEventTopic",
        },
      ],
      extensions: [
        {
          name: "testExtension",
          extensionPointName: "testExtensionPoint",
          dcbSources: [],
        },
      ],
      eventCollector: "testEventCollector",
      extensionProtocols: [],
      apiSchemaFragment: None,
      apiTarget: None,
      structure: None,
      dcbEventLog: None,
      kind: Domain,
    })
    let variantJson = variant->Message.encode(PluginSpec.commandSchema)
    let variantName = variantNameOfJson(variantJson)

    let expected = "Connect"

    expect(variantName)->toBe(expected)
  })

  testSync("get event name of eventJson'", () => {
    open PluginSpec
    let event' = {
      id: "testId",
      meta: {
        service: "testService",
        time: "testTime",
        ip: "testIp",
        user: "testUser",
        msgId: "testMsgId",
        correlationId: "testCorrelationId",
      },
      event: VersionDetected("0.0.0"),
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventName = eventJson'->eventNameOfEvent'Json

    expect(eventName)->toBe("VersionDetected")
  })

  testSync("get id of eventJson'", () => {
    open PluginSpec
    let event' = {
      id: "testId",
      meta: {
        service: "testService",
        time: "testTime",
        ip: "testIp",
        user: "testUser",
        msgId: "testMsgId",
        correlationId: "testCorrelationId",
      },
      event: VersionDetected("0.0.0"),
    }
    let eventJson' = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)
    let eventId = idOfEvent'Json(eventJson')->Option.getOrThrow

    expect(eventId)->toBe("testId")
  })

  // Schema-migration-on-read: a VersionConnected event persisted before `kind` (and
  // before later pluginStructure fields like `events`/`chapter`) existed must still
  // decode — otherwise the one stale event bricks the whole lifecycle aggregate. See
  // docs/plans/platform-infrastructure-in-plugin-list.md (durable fix option 2).
  testSync("tolerantly decode a VersionConnected persisted before kind/structure fields existed", () => {
    open PluginSpec
    let def: Reventless.Plugin.pluginDefinition = {
      id: "id",
      name: "Ordering",
      version: "1.0.0",
      extensionPoints: [],
      extensions: [],
      eventCollector: "arn",
      extensionProtocols: [],
      apiSchemaFragment: None,
      apiTarget: None,
      structure: Some({
        readModels: [],
        stateViewSlices: [],
        stateChangeSlices: [],
        aggregates: [
          {
            name: "Order",
            commands: [],
            producedEventTypes: [],
            consumedEventTypes: [],
            linkedViews: [],
            consistencyRead: None,
            events: [],
            chapter: None,
          },
        ],
        automationSlices: [],
        outboundTranslationSlices: [],
        inboundTranslationSlices: [],
        extensions: [],
        extensionPoints: None,
        requiredStores: None,
        requiredStoreDeclarations: None,
      }),
      dcbEventLog: None,
      kind: Domain,
    }
    let event' = {
      id: "id",
      meta: {
        service: "svc",
        time: "t",
        ip: "ip",
        user: "u",
        msgId: "m",
        correlationId: "c",
      },
      event: VersionConnected(def),
    }
    let json = event'->Message.encodeEvent'(S.string, PluginSpec.eventSchema)

    // Simulate the persisted JSON as written before these fields existed: drop the
    // mandatory enum `kind`, a top-level `T | null` field, and two nested writableDef
    // fields (a mandatory array + a `T | null`).
    let oldJson =
      %raw(`function(j){
        var c = JSON.parse(JSON.stringify(j));
        var d = c.event._0;
        delete d.kind;
        delete d.apiSchemaFragment;
        var agg = d.structure.aggregates[0];
        delete agg.events;
        delete agg.chapter;
        return c;
      }`)(json)

    // Strict decode must reject the stale JSON — the tolerance is what saves it.
    let strictThrew = switch oldJson->S.parseJsonOrThrow(
      Message.toEventSchema'(S.string, PluginSpec.eventSchema),
    ) {
    | _ => false
    | exception _ => true
    }
    expect(strictThrew)->toBe(true)

    // Tolerant decode heals: kind -> Domain (first variant), missing array -> [],
    // missing `T | null` fields -> None.
    let decoded = oldJson->Message.decodeEvent'(S.string, PluginSpec.eventSchema)
    switch decoded.event {
    | VersionConnected(d) =>
      expect(
        switch d.kind {
        | Domain => "Domain"
        | _ => "other"
        },
      )->toBe("Domain")
      expect(d.apiSchemaFragment->Option.isNone)->toBe(true)
      let structure: Reventless.Plugin.pluginStructure = d.structure->Option.getOrThrow
      let agg = structure.aggregates->Array.getUnsafe(0)
      expect(agg.events->Array.length)->toBe(0)
      expect(agg.chapter->Option.isNone)->toBe(true)
    | _ => expect("wrong-variant")->toBe("VersionConnected")
    }
  })

  // The exact aggregate-replay path: EventLog_Operations.decodeEvent reassembles the
  // event variant and calls `Message.decode(Spec.eventSchema)`. This is what actually
  // bricked in production, so assert `Message.decode` itself heals a stale def.
  testSync("Message.decode heals a VersionConnected variant missing kind (the replay path)", () => {
    open PluginSpec
    let def: Reventless.Plugin.pluginDefinition = {
      id: "id",
      name: "Ordering",
      version: "1.0.0",
      extensionPoints: [],
      extensions: [],
      eventCollector: "arn",
      extensionProtocols: [],
      apiSchemaFragment: None,
      apiTarget: None,
      structure: None,
      dcbEventLog: None,
      kind: Domain,
    }
    let variantJson = VersionConnected(def)->Message.encode(PluginSpec.eventSchema)
    let staleJson =
      %raw(`function(j){ var c = JSON.parse(JSON.stringify(j)); delete c._0.kind; return c; }`)(
        variantJson,
      )

    // Strict decode of the stale variant throws (reproduces the production brick).
    let strictThrew = switch staleJson->S.parseJsonOrThrow(PluginSpec.eventSchema) {
    | _ => false
    | exception _ => true
    }
    expect(strictThrew)->toBe(true)

    // The replay decoder heals kind -> Domain.
    switch staleJson->Message.decode(PluginSpec.eventSchema) {
    | VersionConnected(d) =>
      expect(
        switch d.kind {
        | Domain => "Domain"
        | _ => "other"
        },
      )->toBe("Domain")
    | _ => expect("wrong-variant")->toBe("VersionConnected")
    }
  })
})
