// Guards the typed cold-start core hoisted out of SideEffectEntryPoint.mjs:
//   - parseHandlerConfig — the {handlers:[{sideEffectModules, sourceUrn,
//     comp, plugin}]} shape written by SideEffectHandlerRuntime_Builder_Single;
//     a drift here silently drops a side effect's stream subscription.
//   - makeRegisteredHandler — comp/plugin attribution threading into the
//     shared routed dispatch boundary.

open JestGlobals

let str = JSON.Encode.string
let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

describe("SideEffectEntryPoint_Ops.parseHandlerConfig", () => {
  testSync("empty raw config yields no handlers", () => {
    expect(SideEffectEntryPoint_Ops.parseHandlerConfig("")->Array.length)->toBe(0)
  })

  testSync("decodes handlers incl. attribution fields", () => {
    let config = obj([
      (
        "handlers",
        JSON.Encode.array([
          obj([
            ("sideEffectModules", JSON.Encode.array([str("@x/p/src/A.res.mjs"), str("@x/p/src/B.res.mjs")])),
            ("sourceUrn", str("arn:stream-1")),
            ("comp", str("SideEffectHandler(Mailer)")),
            ("plugin", str("Ordering")),
          ]),
          obj([
            ("sideEffectModules", JSON.Encode.array([str("@x/p/src/C.res.mjs")])),
            ("sourceUrn", str("arn:stream-2")),
          ]),
        ]),
      ),
    ])->JSON.stringify
    let entries = SideEffectEntryPoint_Ops.parseHandlerConfig(config)
    expect(entries->Array.length)->toBe(2)
    let first = entries->Array.getUnsafe(0)
    expect(first.sourceUrn)->toBe("arn:stream-1")
    expect(first.sideEffectModules)->toEqual(["@x/p/src/A.res.mjs", "@x/p/src/B.res.mjs"])
    expect(first.comp)->toEqual(Some("SideEffectHandler(Mailer)"))
    expect(first.plugin)->toEqual(Some("Ordering"))
    let second = entries->Array.getUnsafe(1)
    expect(second.comp->Option.isNone)->toBe(true)
    expect(second.plugin->Option.isNone)->toBe(true)
  })
})

describe("SideEffectEntryPoint_Ops.noopQueryEngine", () => {
  test("returns empty results for scan and query", async () => {
    let scanned = await SideEffectEntryPoint_Ops.noopQueryEngine.scan(
      ~readModelName="X",
      ~filterConfigs=[],
      ~limit=10,
    )
    expect(scanned->Array.length)->toBe(0)
    let queried = await SideEffectEntryPoint_Ops.noopQueryEngine.query(
      ~readModelName="X",
      ~id=Reventless.QueryEngine.String("a"),
    )
    expect(queried->Array.length)->toBe(0)
  })
})

describe("SideEffectEntryPoint_Ops.makeRegisteredHandler", () => {
  testSync("threads comp/plugin onto the registered handler", () => {
    let entry: SideEffectEntryPoint_Ops.handlerEntry = {
      sourceUrn: "arn:stream-1",
      sideEffectModules: [],
      comp: Some("SideEffectHandler(Mailer)"),
      plugin: Some("Ordering"),
    }
    let registered = SideEffectEntryPoint_Ops.makeRegisteredHandler(entry, _stream =>
      Effect.succeed()
    )
    expect(registered.comp)->toEqual(Some("SideEffectHandler(Mailer)"))
    expect(registered.plugin)->toEqual(Some("Ordering"))
  })
})
