// Tests for the opt-in NDJSON domain-event tap (features plan Phase 9 — the VS
// Code local platform runner). The tap lives in LocalBus.publishEvent: when
// REVENTLESS_EVENT_TAP is set it emits one sentinel-prefixed JSON line per
// published event to stdout (console.log), with the event's real topic name and
// payload. Off by default so normal runs stay quiet.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

let defaultMeta: Reventless.Message.meta = {
  service: "test",
  time: "",
  ip: "",
  user: "test",
  msgId: "",
  correlationId: "",
}

@val external processEnv: Dict.t<string> = "process.env"

type consoleObj = {mutable log: string => unit}
@val external console: consoleObj = "console"

let sentinel = "@@RVLESS_EVT@@ "

// Run `fn` with console.log captured; returns every logged line, restoring the
// original console.log even if `fn` throws.
let captureLogs = async (fn: unit => promise<unit>): array<string> => {
  let captured: array<string> = []
  let original = console.log
  console.log = s => captured->Array.push(s)
  let result = try {
    await fn()
    Ok()
  } catch {
  | e => Error(e)
  }
  console.log = original
  switch result {
  | Ok() => captured
  | Error(e) => raise(e)
  }
}

let tapLines = (logs: array<string>): array<string> =>
  logs->Array.filter(l => l->String.startsWith(sentinel))

describe("LocalBus event tap (Phase 9)", () => {
  // Each test owns the env flag; always clear it afterwards so cases don't leak.
  let clearEnv = () => processEnv->Dict.delete("REVENTLESS_EVENT_TAP")

  testPromise("tap off → no sentinel line is emitted", async () => {
    clearEnv()
    module TestBus = LocalBus.MakeSilent()
    let logs = await captureLogs(async () => {
      await TestBus.publishEvent("SomeTopic", "svc", defaultMeta, JSON.parseOrThrow(`{"a":1}`))
    })
    expect(tapLines(logs)->Array.length)->toBe(0)
  })

  testPromise("tap on → one well-formed line per published event", async () => {
    processEnv->Dict.set("REVENTLESS_EVENT_TAP", "ndjson")
    module TestBus = LocalBus.MakeSilent()
    let logs = await captureLogs(async () => {
      await TestBus.publishEvent(
        "CatalogEventTopic",
        "CatalogDcbEventLog",
        defaultMeta,
        JSON.parseOrThrow(`{"event":{"TAG":"ProductAdded","productId":"p-1"}}`),
      )
      await TestBus.publishEvent("OrderingEventTopic", "svc", defaultMeta, JSON.parseOrThrow(`{}`))
    })
    clearEnv()
    let lines = tapLines(logs)
    expect(lines->Array.length)->toBe(2)

    // First line decodes to the expected envelope: event="domainEvent", the real
    // topic name, and the payload passed to publishEvent (no topic-name guessing).
    let first = lines->Array.getUnsafe(0)
    let json = first->String.sliceToEnd(~start=sentinel->String.length)->JSON.parseOrThrow
    let obj = json->JSON.Decode.object->Option.getExn
    expect(obj->Dict.get("event")->Option.flatMap(JSON.Decode.string))->toEqual(Some("domainEvent"))
    expect(obj->Dict.get("topic")->Option.flatMap(JSON.Decode.string))->toEqual(
      Some("CatalogEventTopic"),
    )
    expect(obj->Dict.get("seq")->Option.flatMap(JSON.Decode.float))->toEqual(Some(1.0))
    expect(obj->Dict.get("payload")->Option.isSome)->toBe(true)
  })

  testPromise("tap emits even when the topic has no subscribers", async () => {
    processEnv->Dict.set("REVENTLESS_EVENT_TAP", "ndjson")
    module TestBus = LocalBus.MakeSilent()
    let logs = await captureLogs(async () => {
      // No subscribeToEvents call — the tap fires before the subscriber-count gate.
      await TestBus.publishEvent("Lonely", "svc", defaultMeta, JSON.Null)
    })
    clearEnv()
    expect(tapLines(logs)->Array.length)->toBe(1)
  })
})
