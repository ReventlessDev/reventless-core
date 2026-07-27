// Guards the typed cold-start core hoisted out of ReadModelEntryPoint.mjs:
//   - parseHandlerConfig — the HANDLER_CONFIG contract every read-model Lambda
//     cold-starts on, incl. the optional attribution (comp/plugin) and backend
//     (pgConnection/stateTopicName) fields.
//   - injectId / withInjectedId — the id-injection wrap on save/saveBatch;
//     query resolvers and the live-update publisher read `id` off the row, so
//     silently dropping the injection would strand every list query.

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

describe("ReadModelEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("empty raw config yields no handlers", () => {
    expect(ReadModelEntryPoint_Ops.parseHandlerConfig("")->Array.length)->toBe(0)
    expect(ReadModelEntryPoint_Ops.parseHandlerConfig(`{"handlers":[]}`)->Array.length)->toBe(0)
  })

  testSync("decodes a full entry incl. attribution and Postgres fields", () => {
    let config = obj([
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("specModule", str("@x/spec/src/ReadModel/Products.res.mjs")),
            ("mappingsModule", str("@x/spec/src/ReadModel/Products_Projections.res.mjs")),
            ("queryDbTableName", str("Products-abc")),
            ("sourceUrn", str("arn:aws:sqs:eu-west-1:1:q")),
            ("comp", str("EventCollector(ProductsEC)")),
            ("plugin", str("Catalog")),
            ("stateTopicName", str("catalogProducts")),
            (
              "pgConnection",
              obj([
                ("host", str("db.local")),
                ("port", JSON.Encode.int(5432)),
                ("database", str("app")),
                ("username", str("master")),
                ("secretArn", str("arn:secret")),
              ]),
            ),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let entries = ReadModelEntryPoint_Ops.parseHandlerConfig(config)
    expect(entries->Array.length)->toBe(1)
    let e = entries->Array.getUnsafe(0)
    expect(e.specModule)->toBe("@x/spec/src/ReadModel/Products.res.mjs")
    expect(e.mappingsModule)->toBe("@x/spec/src/ReadModel/Products_Projections.res.mjs")
    expect(e.queryDbTableName)->toBe("Products-abc")
    expect(e.sourceUrn)->toBe("arn:aws:sqs:eu-west-1:1:q")
    expect(e.comp)->toEqual(Some("EventCollector(ProductsEC)"))
    expect(e.plugin)->toEqual(Some("Catalog"))
    expect(e.stateTopicName)->toEqual(Some("catalogProducts"))
    switch e.pgConnection {
    | Some(cc) => {
        expect(cc.host)->toBe("db.local")
        expect(cc.port)->toBe(5432)
        expect(cc.database)->toBe("app")
      }
    | None => JsError.throwWithMessage("expected Some(pgConnection)")
    }
  })

  testSync("optional fields default to None; null pgConnection maps to None", () => {
    let config = obj([
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("specModule", str("a.res.mjs")),
            ("mappingsModule", str("b.res.mjs")),
            ("queryDbTableName", str("t")),
            ("sourceUrn", str("u")),
            ("pgConnection", JSON.Null),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let e = ReadModelEntryPoint_Ops.parseHandlerConfig(config)->Array.getUnsafe(0)
    expect(e.comp->Option.isNone)->toBe(true)
    expect(e.plugin->Option.isNone)->toBe(true)
    expect(e.stateTopicName->Option.isNone)->toBe(true)
    expect(e.pgConnection->Option.isNone)->toBe(true)
  })
})

describe("ReadModelEntryPoint_Ops.injectId", () => {
  testSync("injects (and overwrites) id on object states", () => {
    expect(ReadModelEntryPoint_Ops.injectId("p-1", obj([("name", str("Widget"))])))->toEqual(
      obj([("name", str("Widget")), ("id", str("p-1"))]),
    )
    expect(ReadModelEntryPoint_Ops.injectId("p-1", obj([("id", str("stale"))])))->toEqual(
      obj([("id", str("p-1"))]),
    )
  })

  testSync("passes non-object states through unchanged", () => {
    expect(ReadModelEntryPoint_Ops.injectId("p-1", str("scalar")))->toEqual(str("scalar"))
    expect(
      ReadModelEntryPoint_Ops.injectId("p-1", JSON.Encode.array([str("a")])),
    )->toEqual(JSON.Encode.array([str("a")]))
    expect(ReadModelEntryPoint_Ops.injectId("p-1", JSON.Null))->toEqual(JSON.Null)
  })
})

describe("ReadModelEntryPoint_Ops.withInjectedId", () => {
  // Capturing stub operation set — only save/saveBatch matter for the wrap.
  let makeStub = (saved: array<(string, JSON.t)>): ReventlessCore.QueryDb_Adapter.operations => {
    load: async _ => Ok([]),
    loadStream: _ => Stream.fromIterable([]),
    save: async (id, state, _mode, _ttl) => {
      saved->Array.push((id, state))
      Ok()
    },
    saveBatch: async items => {
      items->Array.forEach(((id, state, _ttl)) => saved->Array.push((id, state)))
      Ok()
    },
    count: async (_, _, _) => Ok(0),
    delete: async (_, _) => Ok(),
    deleteBatch: async _ => Ok(),
  }

  test("save and saveBatch write id-injected states", async () => {
    let saved = []
    let ops = ReadModelEntryPoint_Ops.withInjectedId(makeStub(saved))
    let _ = await ops.save("p-1", obj([("name", str("A"))]), ReventlessCore.QueryDb.Any, None)
    let _ = await ops.saveBatch([
      ("p-2", obj([("name", str("B"))]), None),
      ("p-3", str("scalar"), None),
    ])
    expect(saved)->toEqual([
      ("p-1", obj([("name", str("A")), ("id", str("p-1"))])),
      ("p-2", obj([("name", str("B")), ("id", str("p-2"))])),
      ("p-3", str("scalar")),
    ])
  })
})
