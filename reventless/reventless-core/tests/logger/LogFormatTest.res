open JestGlobals
open LogFormat

S.enableJson()

// Sink detection (Reventless.AnsiStyle) defaults a non-TTY stdout — Jest
// included — to JSON, which no-ops `bold`/`fmtComp`. The human-format
// assertions below expect ANSI, so force text mode for this file. The
// "JSON sink" block flips to json and restores text in its own setup.
@val external _processEnv: Dict.t<string> = "process.env"
_processEnv->Dict.set("REVENTLESS_LOG_FORMAT", "text")
Reventless.AnsiStyle.reload()

describe("LogFormat", () => {
  describe("commandJsonsToLogMessages", () => {
    testSync(
      "empty",
      () => {
        let arr: array<Message.commandJson> = []
        expect(commandJsonsToLogMessages(arr))->toEqual([])
      },
    )
    testSync(
      "simple",
      () => {
        let commands: array<PluginSpec.command> = [Heartbeat("0.0.0")]
        let meta: Message.meta = {
          service: "testService",
          time: "testTime",
          ip: "testIp",
          user: "testUser",
          msgId: "testMsgId",
          correlationId: "testCorrelationId",
        }
        let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
        let arr: array<Message.commandJson> = commands->Array.mapWithIndex(
          (command, idx) => {
            {
              Message.id: idx->Int.toString,
              meta,
              commandJson: command->Message.encode(PluginSpec.commandSchema),
            }
          },
        )
        let expected = `1/1: \x1b[1mHeartbeat\x1b[0m(0): {"command":{"TAG":"Heartbeat","_0":"0.0.0"},"meta":${metaStr},"id":"0"}`
        expect(commandJsonsToLogMessages(arr))->toEqual([expected])
      },
    )
    testSync(
      "complex",
      () => {
        let commands: array<PluginSpec.command> = [
          Heartbeat("0.0.0"),
          Connect({
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
            uiFragments: None,
            structure: None,
            dcbEventLog: None,
          }),
        ]
        let meta: Message.meta = {
          service: "testService",
          time: "testTime",
          ip: "testIp",
          user: "testUser",
          msgId: "testMsgId",
          correlationId: "testCorrelationId",
        }
        let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
        let arr: array<Message.commandJson> = commands->Array.mapWithIndex(
          (command, idx) => {
            {
              Message.id: idx->Int.toString,
              meta,
              commandJson: command->Message.encode(PluginSpec.commandSchema),
            }
          },
        )
        let expected1 = `1/2: \x1b[1mHeartbeat\x1b[0m(0): {"command":{"TAG":"Heartbeat","_0":"0.0.0"},"meta":${metaStr},"id":"0"}`
        let expected2 = `2/2: \x1b[1mConnect\x1b[0m(1): {"command":{"TAG":"Connect","_0":{"id":"id","name":"testName","version":"testVersion","extensionPoints":[{"name":"testExtensionPoint","commandTopic":"testCommandTopic","eventTopic":"testEventTopic"}],"extensions":[{"name":"testExtension","extensionPointName":"testExtensionPoint","dcbSources":[]}],"eventCollector":"testEventCollector","extensionProtocols":[],"apiSchemaFragment":null,"apiTarget":null,"uiFragments":null,"structure":null,"dcbEventLog":null}},"meta":${metaStr},"id":"1"}`
        expect(commandJsonsToLogMessages(arr))->toEqual([expected1, expected2])
      },
    )
  })
  describe("event'JsonToLogMessage", () => {
    testSync(
      "simple",
      () => {
        open PluginSpec
        let event': Message.event'<string, event> = {
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
        let eventJson' = event'->Message.encodeEvent'(S.string, eventSchema)
        let msg = event'JsonToLogMessage(eventJson')

        let expected = `\x1b[1mVersionDetected\x1b[0m(testId): {"event":{"TAG":"VersionDetected","_0":"0.0.0"},"meta":{"service":"testService","time":"testTime","ip":"testIp","user":"testUser","msgId":"testMsgId","correlationId":"testCorrelationId"},"id":"testId"}`

        expect(msg)->toEqual(expected)
      },
    )
  })
})

// ─── JSON sink (non-TTY collector: CloudWatch / Datadog / …) ─────────────────
// Regression guard: in a JSON sink every emitted record must parse as JSON and
// must NOT carry any ANSI escape (\x1b) anywhere. This fails the moment a new
// helper inlines an ANSI code into a path that reaches Logger.emit.

type consoleObj = {mutable log: string => unit}
@val external _console: consoleObj = "console"

let hasAnsi = (s: string): bool => s->String.includes("\x1b")

// Run `fn` with console.log captured; restores the original even if `fn` throws.
// Logger's JSON branch emits every level through Console.log, so this captures
// all of it.
let captureLogs = (fn: unit => unit): array<string> => {
  let captured: array<string> = []
  let original = _console.log
  _console.log = s => captured->Array.push(s)
  let result = try {
    fn()
    Ok()
  } catch {
  | e => Error(e)
  }
  _console.log = original
  switch result {
  | Ok() => captured
  | Error(e) => throw(e)
  }
}

let validLevels = ["DEBUG", "INFO", "WARN", "ERROR"]

// True when a captured line is a clean JSON log record: parses as JSON, carries
// no ANSI escape anywhere, has a string `message` and a known `level`.
let isCleanRecord = (line: string): bool =>
  !hasAnsi(line) &&
  (try {
    switch line->JSON.parseOrThrow->JSON.Decode.object {
    | Some(obj) =>
      let levelOk =
        obj
        ->Dict.get("level")
        ->Option.flatMap(JSON.Decode.string)
        ->Option.mapOr(false, l => validLevels->Array.includes(l))
      let msgOk = obj->Dict.get("message")->Option.flatMap(JSON.Decode.string)->Option.isSome
      levelOk && msgOk
    | None => false
    }
  } catch {
  | _ => false
  })

// Read a top-level string field off a captured JSON record (None if absent).
let fieldOf = (line: string, key: string): option<string> =>
  switch line->JSON.parseOrThrow->JSON.Decode.object {
  | Some(obj) => obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)
  | None => None
  }

describe("JSON sink", () => {
  // Flip to json for the whole block; restore text afterwards so a re-run of the
  // file (or shared module state) keeps the human-format assertions valid.
  beforeAll(() => {
    _processEnv->Dict.set("REVENTLESS_LOG_FORMAT", "json")
    Reventless.AnsiStyle.reload()
  })
  afterAll(() => {
    _processEnv->Dict.set("REVENTLESS_LOG_FORMAT", "text")
    Reventless.AnsiStyle.reload()
  })

  // Logger.t goes Debug+ regardless of LOG_LEVEL via an explicit min level.
  let log = Logger.makeLogger(~minLevel=Debug)

  testSync("Logger.info emits one clean JSON record with comp as a top-level field", () => {
    let lines = captureLogs(() => log.info(~comp="Aggregate(Product)", "handling command"))
    let line = lines->Array.length == 1 ? lines->Array.getUnsafe(0) : ""
    let ok =
      lines->Array.length == 1 &&
      isCleanRecord(line) &&
      // comp is promoted to a top-level key, message stays clean (no [Comp] prefix)
      line->fieldOf("comp") == Some("Aggregate(Product)") &&
      line->fieldOf("message") == Some("handling command")
    expect(ok)->toBe(true)
  })

  testSync("Logger.info resolves plugin to a top-level field when the comp is registered", () => {
    Logger.registerComponentPlugin(~componentName="Product", ~pluginName="Catalog")
    let lines = captureLogs(() => log.info(~comp="Aggregate(Product)", "handling command"))
    let line = lines->Array.length == 1 ? lines->Array.getUnsafe(0) : ""
    expect(lines->Array.length == 1 && line->fieldOf("plugin") == Some("Catalog"))->toBe(true)
  })

  testSync("Logger.warn emits one clean JSON record", () => {
    let lines = captureLogs(() => log.warn(~comp="Platform", "heartbeat skipped"))
    expect(lines->Array.length == 1 && isCleanRecord(lines->Array.getUnsafe(0)))->toBe(true)
  })

  testSync("Logger.error with ~data emits one clean JSON record", () => {
    let lines = captureLogs(() =>
      log.error(
        ~comp="Util_AppSync_Caller",
        ~data=JSON.parseOrThrow(`{"errors":["boom"]}`),
        "query errors",
      )
    )
    expect(lines->Array.length == 1 && isCleanRecord(lines->Array.getUnsafe(0)))->toBe(true)
  })

  testSync("EffectLogger.logInfo emits clean JSON through install()", () => {
    let lines = captureLogs(() =>
      EffectLogger.logInfo(~comp="Aggregate(Product)", "replay done")->Effect.runSync
    )
    let allClean = lines->Array.filter(l => !isCleanRecord(l))->Array.length == 0
    expect(lines->Array.length >= 1 && allClean)->toBe(true)
  })

  testSync("EffectLogger.logInfo carries ~comp + ~detail as structured fields (no \\x00)", () => {
    let lines = captureLogs(() =>
      EffectLogger.logInfo(
        ~comp="Aggregate(Product)",
        ~detail=JSON.parseOrThrow(`{"id":"p-1"}`),
        "added",
      )->Effect.runSync
    )
    let ok = lines->Array.some(line =>
      switch line->JSON.parseOrThrow->JSON.Decode.object {
      | Some(obj) =>
        obj->Dict.get("comp")->Option.flatMap(JSON.Decode.string) == Some("Aggregate(Product)") &&
        obj
        ->Dict.get("detail")
        ->Option.flatMap(JSON.Decode.object)
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(JSON.Decode.string) == Some("p-1")
      | None => false
      }
    )
    expect(ok)->toBe(true)
  })

  testSync("Effect.annotateLogs(correlationId) surfaces as a top-level field", () => {
    let lines = captureLogs(() =>
      EffectLogger.logInfo(~comp="Aggregate(Product)", "handling")
      ->Effect.annotateLogs("correlationId", "c-123")
      ->Effect.runSync
    )
    expect(lines->Array.some(line => line->fieldOf("correlationId") == Some("c-123")))->toBe(true)
  })

  testSync("Effect.annotateLogs(plugin) overrides registry resolution", () => {
    // The component is NOT registered against any plugin; without an explicit
    // ~plugin annotation, resolvePlugin would fall back through transformations
    // and emit no plugin field. With the annotation, plugin wins.
    let lines = captureLogs(() =>
      EffectLogger.logInfo(~comp="Aggregate(Unregistered)", "handling")
      ->Effect.annotateLogs("plugin", "Ordering")
      ->Effect.runSync
    )
    expect(lines->Array.some(line => line->fieldOf("plugin") == Some("Ordering")))->toBe(true)
  })

  testSync("every JSON record carries an RFC 3339 time field", () => {
    let lines = captureLogs(() => log.info(~comp="Platform", "tick"))
    let ok = switch lines->Array.get(0)->Option.flatMap(l => l->fieldOf("time")) {
    | Some(t) => t->String.includes("T") && t->String.endsWith("Z")
    | None => false
    }
    expect(ok)->toBe(true)
  })

  testSync("service field is emitted when REVENTLESS_SERVICE is set", () => {
    _processEnv->Dict.set("REVENTLESS_SERVICE", "TestService")
    let lines = captureLogs(() => log.info(~comp="Platform", "tick"))
    let got = lines->Array.get(0)->Option.flatMap(l => l->fieldOf("service"))
    _processEnv->Dict.delete("REVENTLESS_SERVICE")
    expect(got)->toEqual(Some("TestService"))
  })

  testSync("oversized detail is truncated to a preview stub", () => {
    let big = String.repeat("x", 40000)
    let detail = Dict.fromArray([("blob", JSON.Encode.string(big))])->JSON.Encode.object
    // ~detail flows through emit (Logger.t's ~data goes into the message instead).
    let direct = captureLogs(() => Logger.emit(~level=Info, ~comp="Platform", ~detail, "big"))
    let ok = switch direct->Array.get(0)->Option.flatMap(l => l->JSON.parseOrThrow->JSON.Decode.object) {
    | Some(obj) =>
      switch obj->Dict.get("detail")->Option.flatMap(JSON.Decode.object) {
      | Some(d) =>
        d->Dict.get("truncated")->Option.flatMap(JSON.Decode.bool) == Some(true) &&
          d->Dict.get("preview")->Option.flatMap(JSON.Decode.string)->Option.mapOr(false, p =>
            p->String.length <= 512
          )
      | None => false
      }
    | None => false
    }
    expect(ok)->toBe(true)
  })

  testSync("LogFormat.cmdName carries no ANSI in a JSON sink", () => {
    let meta: Message.meta = {
      service: "testService",
      time: "testTime",
      ip: "testIp",
      user: "testUser",
      msgId: "testMsgId",
      correlationId: "testCorrelationId",
    }
    let cmd: Message.commandJson = {
      Message.id: "0",
      meta,
      commandJson: (Heartbeat("0.0.0"): PluginSpec.command)->Message.encode(PluginSpec.commandSchema),
    }
    let name = cmd->cmdName
    expect(!hasAnsi(name) && name == "Heartbeat")->toBe(true)
  })
})
