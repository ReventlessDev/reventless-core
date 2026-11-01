// A registered sink receives every record that passed its level, as the JSON
// line prints it, and a level set while running decides what passes.

open JestGlobals

type consoleObj = {mutable log: string => unit, mutable error: string => unit}
@val external _console: consoleObj = "console"

let capture = (fn: unit => unit): (array<string>, array<string>) => {
  let out: array<string> = []
  let err: array<string> = []
  let originalLog = _console.log
  let originalError = _console.error
  _console.log = s => out->Array.push(s)
  _console.error = s => err->Array.push(s)
  let result = try {
    fn()
    Ok()
  } catch {
  | e => Error(e)
  }
  _console.log = originalLog
  _console.error = originalError
  switch result {
  | Ok() => (out, err)
  | Error(e) => throw(e)
  }
}

let collecting = (): (array<Logger.record>, unit => unit) => {
  let got = []
  let remove = Logger.addSink(r => got->Array.push(r))
  (got, remove)
}

describe("Logger sinks", () => {
  beforeAll(() => {
    NodeProcess.env->Dict.set("REVENTLESS_LOG_FORMAT", "json")
    Reventless.AnsiStyle.reload()
  })
  afterAll(() => {
    NodeProcess.env->Dict.set("REVENTLESS_LOG_FORMAT", "text")
    Reventless.AnsiStyle.reload()
  })

  testSync("a sink's record has the JSON line's fields, field for field", () => {
    let (got, remove) = collecting()
    let detail = Dict.fromArray([("orderId", JSON.Encode.string("o-1"))])->JSON.Encode.object
    let (lines, _) = capture(
      () =>
        Logger.emit(
          ~level=Warn,
          ~comp="Aggregate(Order)",
          ~plugin="Ordering",
          ~detail,
          ~annotations=Dict.fromArray([("correlationId", "c-1")]),
          "refused",
        ),
    )
    remove()
    expect(got->Array.length)->toBe(1)
    expect(lines->Array.length)->toBe(1)
    let record = got->Array.getUnsafe(0)
    expect(lines->Array.getUnsafe(0)->JSON.parseOrThrow)->toEqual(record->Logger.recordToJson)
    expect(record.plugin)->toEqual(Some("Ordering"))
    expect(record.annotations->Dict.get("correlationId"))->toEqual(Some("c-1"))
  })

  testSync("the record's detail is redacted before a sink sees it", () => {
    let (got, remove) = collecting()
    let detail =
      Dict.fromArray([
        ("name", Dict.fromArray([("$pii", JSON.Encode.string("Ada Secret"))])->JSON.Encode.object),
      ])->JSON.Encode.object
    let _ = capture(() => Logger.emit(~level=Info, ~comp="Platform", ~detail, "joined"))
    remove()
    let printed = got->Array.getUnsafe(0)->Logger.recordToJson->JSON.stringify
    expect(printed->String.includes("Ada Secret"))->toBe(false)
  })

  testSync("a sink that throws is noted once, and the others still get every record", () => {
    let removeBad = Logger.addSink(_ => throw(Failure("boom")))
    let (got, remove) = collecting()
    let (_, errors) = capture(
      () => {
        Logger.emit(~level=Info, ~comp="Platform", "one")
        Logger.emit(~level=Info, ~comp="Platform", "two")
      },
    )
    removeBad()
    remove()
    expect(got->Array.map(r => r.message))->toEqual(["one", "two"])
    expect(errors->Array.filter(e => e->String.includes("log sink"))->Array.length)->toBe(1)
  })

  testSync("a removed sink gets nothing more", () => {
    let (got, remove) = collecting()
    remove()
    let _ = capture(() => Logger.emit(~level=Info, ~comp="Platform", "after"))
    expect(got->Array.length)->toBe(0)
  })
})

describe("Logger levels set while running", () => {
  afterEach(() => Logger.clearLevels())

  // LOG_LEVEL is read live; each case sets the base it needs.
  let withLogLevel = (value: string, fn: unit => unit) => {
    let before = NodeProcess.env->Dict.get("LOG_LEVEL")
    NodeProcess.env->Dict.set("LOG_LEVEL", value)
    fn()
    switch before {
    | Some(v) => NodeProcess.env->Dict.set("LOG_LEVEL", v)
    | None => NodeProcess.env->Dict.delete("LOG_LEVEL")
    }
  }

  testSync(
    "the component's level wins over the plugin's, the plugin's over the default, the default over LOG_LEVEL",
    () =>
      withLogLevel(
        "error",
        () => {
          Reventless.LogPrefix.registerComponentPlugin(
            ~componentName="Order",
            ~pluginName="Ordering",
          )
          let comp = "Aggregate(Order)"
          expect(Logger.minLevelFor(~comp, ()))->toEqual(Some(Logger.Error))
          Logger.setLevel(Some(Logger.Warn))
          expect(Logger.minLevelFor(~comp, ()))->toEqual(Some(Logger.Warn))
          Logger.setLevel(~plugin="Ordering", Some(Logger.Info))
          expect(Logger.minLevelFor(~comp, ()))->toEqual(Some(Logger.Info))
          expect(Logger.minLevelFor(~comp="Aggregate(Unrelated)", ()))->toEqual(Some(Logger.Warn))
          Logger.setLevel(~comp, Some(Logger.Debug))
          expect(Logger.minLevelFor(~comp, ()))->toEqual(Some(Logger.Debug))
          // Cleared, the next wider scope applies again.
          Logger.setLevel(~comp, None)
          expect(Logger.minLevelFor(~comp, ()))->toEqual(Some(Logger.Info))
        },
      ),
  )

  testSync("a component of one plugin wins over the component everywhere", () => {
    Logger.setLevel(~comp="Projection", Some(Logger.Warn))
    Logger.setLevel(~plugin="Ordering", ~comp="Projection", Some(Logger.Debug))
    expect(Logger.minLevelFor(~plugin="Ordering", ~comp="Projection", ()))->toEqual(
      Some(Logger.Debug),
    )
    expect(Logger.minLevelFor(~plugin="Catalog", ~comp="Projection", ()))->toEqual(
      Some(Logger.Warn),
    )
  })

  testSync("a line below its level never reaches a sink; raised, it does", () =>
    withLogLevel(
      "info",
      () => {
        let log = Logger.fromEnv()
        let (got, remove) = collecting()
        let _ = capture(
          () => {
            log.debug(~comp="Quiet", "not yet")
            Logger.setLevel(~comp="Quiet", Some(Logger.Debug))
            log.debug(~comp="Quiet", "now")
            log.debug(~comp="Other", "still not")
            Logger.setLevel(~comp="Loud", Some(Logger.Error))
            log.warn(~comp="Loud", "dropped")
          },
        )
        remove()
        expect(got->Array.map(r => r.message))->toEqual(["now"])
      },
    )
  )

  testSync("the Effect helpers follow a component's level", () =>
    withLogLevel(
      "info",
      () => {
        let (got, remove) = collecting()
        let _ = capture(
          () => {
            EffectLogger.logDebug(~comp="Quiet", "not yet")->Effect.runSync
            Logger.setLevel(~comp="Quiet", Some(Logger.Debug))
            EffectLogger.logDebug(~comp="Quiet", "now")->Effect.runSync
            Logger.setLevel(~comp="Loud", Some(Logger.Error))
            EffectLogger.logWarn(~comp="Loud", "dropped")->Effect.runSync
          },
        )
        remove()
        expect(got->Array.map(r => r.message))->toEqual(["now"])
      },
    )
  )

  testSync("levelSettings lists what was set", () => {
    Logger.setLevel(Some(Logger.Warn))
    Logger.setLevel(~plugin="Ordering", ~comp="Projection", Some(Logger.Debug))
    expect(Logger.levelSettings())->toEqual([
      {Logger.level: Logger.Warn},
      {plugin: "Ordering", comp: "Projection", level: Logger.Debug},
    ])
  })
})
