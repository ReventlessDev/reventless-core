// Guards the typed cold-start core hoisted out of StateViewSliceEntryPoint.mjs:
//   - parseHandlerConfig — the compact-v2 HANDLER_CONFIG expansion (shared
//     base / sourceUrn / pgConnection, shortened s/p/q/u/t keys) and the legacy
//     full-key pass-through; a drift here mis-routes or mis-backends every
//     view slice of a plugin at cold start.
//   - decodeEnvelope — the `{event, meta, recordedAt}` envelope rule incl. the
//     bare-event fallback.
//   - makeJsonEventsHandler — the projection stream pipeline: schema parse →
//     project → handleAction, with decode failures logged and skipped instead
//     of wedging the batch.

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

describe("StateViewSliceEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("empty raw config yields no handlers", () => {
    expect(StateViewSliceEntryPoint_Ops.parseHandlerConfig("")->Array.length)->toBe(0)
  })

  testSync("expands compact-v2 entries against shared base/sourceUrn/pgConnection", () => {
    let config = obj([
      ("v", JSON.Encode.int(2)),
      ("base", str("@x/plugin/src/StateViewSlice/")),
      ("sourceUrn", str("arn:shared")),
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
      (
        "handlers",
        JSON.Encode.array([
          obj([("s", str("Carts.res.mjs")), ("p", str("Carts_Projection.res.mjs")), ("q", str("qdb_Carts"))]),
          obj([
            ("s", str("Totals.res.mjs")),
            ("p", str("Totals_Projection.res.mjs")),
            ("q", str("qdb_Totals")),
            ("u", str("arn:override")),
            ("t", str("cartTotals")),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let entries = StateViewSliceEntryPoint_Ops.parseHandlerConfig(config)
    expect(entries->Array.length)->toBe(2)
    let first = entries->Array.getUnsafe(0)
    expect(first.specModule)->toBe("@x/plugin/src/StateViewSlice/Carts.res.mjs")
    expect(first.projectionModule)->toBe("@x/plugin/src/StateViewSlice/Carts_Projection.res.mjs")
    expect(first.queryDbTableName)->toBe("qdb_Carts")
    expect(first.sourceUrn)->toBe("arn:shared")
    expect(first.stateTopicName->Option.isNone)->toBe(true)
    expect(first.pgConnection->Option.map(cc => cc.host))->toEqual(Some("db.local"))
    let second = entries->Array.getUnsafe(1)
    expect(second.sourceUrn)->toBe("arn:override")
    expect(second.stateTopicName)->toEqual(Some("cartTotals"))
  })

  testSync("passes legacy full-key entries through with per-entry fields", () => {
    let config = obj([
      ("base", str("ignored/")),
      ("sourceUrn", str("arn:shared")),
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("specModule", str("full/Carts.res.mjs")),
            ("projectionModule", str("full/Carts_Projection.res.mjs")),
            ("queryDbTableName", str("qdb_Carts")),
            ("sourceUrn", str("arn:own")),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let e = StateViewSliceEntryPoint_Ops.parseHandlerConfig(config)->Array.getUnsafe(0)
    // Legacy entries are NOT base-prefixed and keep their own sourceUrn.
    expect(e.specModule)->toBe("full/Carts.res.mjs")
    expect(e.projectionModule)->toBe("full/Carts_Projection.res.mjs")
    expect(e.sourceUrn)->toBe("arn:own")
    expect(e.pgConnection->Option.isNone)->toBe(true)
  })
})

describe("StateViewSliceEntryPoint_Ops.decodeEnvelope", () => {
  testSync("surfaces event/recordedAt from the envelope", () => {
    let envelope = obj([
      ("id", str("evt-1")),
      ("event", str("payload")),
      ("meta", obj([("service", str("Carts"))])),
      ("recordedAt", str("2026-07-27T00:00:00Z")),
    ])
    let decoded = StateViewSliceEntryPoint_Ops.decodeEnvelope(envelope)
    expect(decoded.event)->toEqual(str("payload"))
    expect(decoded.recordedAt)->toBe("2026-07-27T00:00:00Z")
  })

  testSync("falls back to the whole json for bare / null-event records", () => {
    let bare = obj([("kind", str("CartCreated"))])
    expect(StateViewSliceEntryPoint_Ops.decodeEnvelope(bare).event)->toEqual(bare)
    let nullEvent = obj([("event", JSON.Null), ("recordedAt", str("t"))])
    expect(StateViewSliceEntryPoint_Ops.decodeEnvelope(nullEvent).event)->toEqual(nullEvent)
    expect(StateViewSliceEntryPoint_Ops.decodeEnvelope(bare).recordedAt)->toBe("")
  })
})

describe("StateViewSliceEntryPoint_Ops.makeJsonEventsHandler", () => {
  // Capturing stub operation set — Set actions land as saves.
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

  // String-typed consumed events keep the pipeline test independent of any
  // real slice: each event value becomes the row id, `recordedAt` the state.
  let project = (
    {event, recordedAt, _}: Reventless.StateViewSlice.consumed<string>,
  ): array<Reventless.Projection.action<string, JSON.t>> => [Set(event, str(recordedAt))]

  test("decodes envelopes, projects, and runs actions against the ops", async () => {
    let saved = []
    let handler = StateViewSliceEntryPoint_Ops.makeJsonEventsHandler(
      ~sliceName="TestSlice",
      ~eventSchema=S.string,
      ~project,
      ~queryDbOps=makeStub(saved),
      ~subIdConfig=None,
    )
    let envelope = obj([("event", str("row-1")), ("recordedAt", str("2026-07-27"))])
    let bare = str("row-2")
    await Stream.fromIterable([envelope, bare])->handler->Effect.runPromise
    expect(saved)->toEqual([("row-1", str("2026-07-27")), ("row-2", str(""))])
  })

  test("a decode failure yields no actions and does not wedge the batch", async () => {
    let saved = []
    let handler = StateViewSliceEntryPoint_Ops.makeJsonEventsHandler(
      ~sliceName="TestSlice",
      ~eventSchema=S.string,
      ~project,
      ~queryDbOps=makeStub(saved),
      ~subIdConfig=None,
    )
    // A number cannot parse as S.string → logged and skipped; the following
    // record still projects.
    await Stream.fromIterable([JSON.Encode.int(42), str("row-after")])
    ->handler
    ->Effect.runPromise
    expect(saved)->toEqual([("row-after", str(""))])
  })
})
