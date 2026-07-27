// Guards the typed cold-start core hoisted out of EventCollectorEntryPoint.mjs:
//   - projectPluginRow — the Plugin-RM row projection the admin cross-plugin
//     subscription manager reads; a drift in the decode (a dropped nested
//     field, a mis-defaulted optional) would silently break cross-plugin SNS
//     wiring, invisible until a multi-plugin deploy.
//   - parseHandlerConfig — the HANDLER_CONFIG contract every EventCollector
//     Lambda cold-starts on: named errors for malformed deploys, the former JS
//     normalizer's defaults, and the connectExtension null/absent → None rule.

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

let project = EventCollectorEntryPoint_Ops.projectPluginRow

describe("EventCollectorEntryPoint_Ops.projectPluginRow", () => {
  testSync("rejects a non-object row", () => {
    expect((project(JSON.Encode.string("nope")))->Option.isNone)->toBe(true)
  })

  testSync("rejects a row missing id or status", () => {
    expect(project(obj([("status", str("Connected"))]))->Option.isNone)->toBe(true)
    expect(project(obj([("id", str("Catalog@1"))]))->Option.isNone)->toBe(true)
  })

  testSync("projects the id/status/eventCollector subset with defaults", () => {
    let p = project(obj([("id", str("Catalog@1")), ("status", str("Connected"))]))->Option.getOrThrow
    expect(p.id)->toBe("Catalog@1")
    expect(p.status)->toBe("Connected")
    expect(p.eventCollector)->toBe("") // defaulted when absent
    expect(p.extensions->Array.length)->toBe(0)
    expect(p.extensionPoints->Array.length)->toBe(0)
    expect(p.dcbEventLog->Option.isNone)->toBe(true)
  })

  testSync("decodes extensions, dropping entries without extensionPointName", () => {
    let row = obj([
      ("id", str("Ordering@2")),
      ("status", str("Connected")),
      ("eventCollector", str("ec-arn")),
      (
        "extensions",
        JSON.Encode.array([
          obj([("name", str("OrdersExt")), ("extensionPointName", str("Catalog.Products")), ("dcbSources", JSON.Encode.array([str("prod"), JSON.Encode.int(7)]))]),
          obj([("name", str("Malformed"))]), // no extensionPointName -> dropped
        ]),
      ),
    ])
    let p = project(row)->Option.getOrThrow
    expect(p.eventCollector)->toBe("ec-arn")
    expect(p.extensions->Array.length)->toBe(1)
    let e = p.extensions->Array.getUnsafe(0)
    expect(e.name)->toBe("OrdersExt")
    expect(e.extensionPointName)->toBe("Catalog.Products")
    // Non-string dcbSources elements are filtered out.
    expect(e.dcbSources)->toEqual(["prod"])
  })

  testSync("decodes extensionPoints and dcbEventLog; drops EPs without name/eventTopic", () => {
    let row = obj([
      ("id", str("Catalog@1")),
      ("status", str("Connected")),
      (
        "extensionPoints",
        JSON.Encode.array([
          obj([("name", str("Catalog.Products")), ("eventTopic", str("t-arn"))]),
          obj([("name", str("NoTopic"))]), // no eventTopic -> dropped
        ]),
      ),
      ("dcbEventLog", obj([("name", str("catalog-dcb")), ("eventTopicArn", str("dcb-arn"))])),
    ])
    let p = project(row)->Option.getOrThrow
    expect(p.extensionPoints->Array.length)->toBe(1)
    let ep = p.extensionPoints->Array.getUnsafe(0)
    expect(ep.name)->toBe("Catalog.Products")
    expect(ep.commandTopic)->toBe("") // defaulted
    expect(ep.eventTopic)->toBe("t-arn")
    let dcb = p.dcbEventLog->Option.getOrThrow
    expect(dcb.name)->toBe("catalog-dcb")
    expect(dcb.eventTopicArn)->toBe("dcb-arn")
  })

  testSync("drops a dcbEventLog missing eventTopicArn", () => {
    let row = obj([
      ("id", str("Catalog@1")),
      ("status", str("Connected")),
      ("dcbEventLog", obj([("name", str("catalog-dcb"))])),
    ])
    expect((project(row)->Option.getOrThrow).dcbEventLog->Option.isNone)->toBe(true)
  })
})

// ── parseHandlerConfig ────────────────────────────────────────────────────────

// A minimal valid HANDLER_CONFIG (every required field present).
let minimalConfig = (extras: array<(string, JSON.t)>): string =>
  Array.concat(
    [
      ("queueUrl", str("q-url")),
      ("pluginExtensionPointCmdTopicUrl", str("ep-url")),
      ("eventTopicArn", str("topic-arn")),
      ("pluginReadModelTableName", str("plugin-rm")),
      ("appSyncApiId", str("NOT_AVAILABLE")),
      ("schedulerRoleArn", str("role-arn")),
      ("schedulerQueueArn", str("")),
      ("schedulerQueueName", str("")),
      ("extensionPoints", JSON.Encode.array([])),
      ("extensions", JSON.Encode.array([])),
      ("publishToAggregates", obj([])),
    ],
    extras,
  )
  ->Dict.fromArray
  ->JSON.Encode.object
  ->JSON.stringify

let throws = (f: unit => 'a): option<string> =>
  try {
    let _ = f()
    None
  } catch {
  | exn => exn->JsExn.fromException->Option.flatMap(JsExn.message)
  }

describe("EventCollectorEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("throws the named errors for empty / malformed / incomplete config", () => {
    let msgOf = raw => throws(() => EventCollectorEntryPoint_Ops.parseHandlerConfig(raw))
    expect(msgOf(""))->toEqual(Some("HANDLER_CONFIG env var is empty"))
    expect(
      msgOf("{nope")->Option.mapOr(false, m => m->String.startsWith("HANDLER_CONFIG JSON parse error:")),
    )->toBe(true)
    expect(msgOf(`{"queueUrl":"q"}`))->toEqual(
      Some("HANDLER_CONFIG missing required field: pluginExtensionPointCmdTopicUrl"),
    )
  })

  testSync("decodes a minimal config with empty-collection defaults", () => {
    let c = EventCollectorEntryPoint_Ops.parseHandlerConfig(minimalConfig([]))
    expect(c.queueUrl)->toBe("q-url")
    expect(c.connectExtension->Option.isNone)->toBe(true) // absent → None
    expect(c.readModelQueueUrls->Dict.keysToArray->Array.length)->toBe(0)
    expect(c.readModelNamesForSourceName->Dict.keysToArray->Array.length)->toBe(0)
  })

  testSync("connectExtension: JSON null (admin) maps to None; a record decodes", () => {
    let asNull = EventCollectorEntryPoint_Ops.parseHandlerConfig(
      minimalConfig([("connectExtension", JSON.Encode.null)]),
    )
    expect(asNull.connectExtension->Option.isNone)->toBe(true)

    let asRecord = EventCollectorEntryPoint_Ops.parseHandlerConfig(
      minimalConfig([
        (
          "connectExtension",
          obj([
            ("specModule", str("spec.mjs")),
            ("mappingsModule", str("map.mjs")),
            ("extensionPointName", str("Platform.Plugin")),
          ]),
        ),
      ]),
    )
    let ce = asRecord.connectExtension->Option.getOrThrow
    expect(ce.extensionPointName)->toBe("Platform.Plugin")
  })

  testSync("extension entries get the former JS normalizer's defaults", () => {
    let c = EventCollectorEntryPoint_Ops.parseHandlerConfig(
      minimalConfig([
        (
          "extensions",
          JSON.Encode.array([
            // no name, no module specifiers, no aggregate/readModel lists
            obj([("extensionPointName", str("Ordering.Orders"))]),
          ]),
        ),
      ]),
    )
    let ext = c.extensions->Array.getUnsafe(0)
    expect(ext.name)->toBe("Ordering.Orders") // name falls back to the EP name
    expect(ext.specModule)->toBe("")
    expect(ext.aggregateNames)->toEqual([])
    expect(ext.readModelNames)->toEqual([])
  })

  testSync("decodes extensionPoints entries and the env-var maps", () => {
    let c = EventCollectorEntryPoint_Ops.parseHandlerConfig(
      minimalConfig([
        (
          "extensionPoints",
          JSON.Encode.array([
            obj([
              ("specModule", str("s.mjs")),
              ("mappingsModule", str("m.mjs")),
              ("eventTopicArn", str("arn:ep")),
              ("aggregateNames", JSON.Encode.array([str("Plugin")])),
            ]),
          ]),
        ),
        ("publishToAggregates", obj([("Plugin", str("PTA_Plugin_QUEUE_URL"))])),
        (
          "readModelNamesForSourceName",
          obj([("Ordering.Orders", JSON.Encode.array([str("ProductDemands")]))]),
        ),
      ]),
    )
    let ep = c.extensionPoints->Array.getUnsafe(0)
    expect(ep.eventTopicArn)->toBe("arn:ep")
    expect(ep.aggregateNames)->toEqual(["Plugin"])
    expect(c.publishToAggregates->Dict.get("Plugin"))->toEqual(Some("PTA_Plugin_QUEUE_URL"))
    expect(c.readModelNamesForSourceName->Dict.get("Ordering.Orders"))->toEqual(
      Some(["ProductDemands"]),
    )
  })
})
