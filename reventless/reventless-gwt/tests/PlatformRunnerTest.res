// Unit tests for PlatformRunner.classifyLine — the pure line classifier that turns
// the spawned reventless-local platform's stdout into structured runner events
// (features plan Phase 9). The tap emits sentinel-prefixed JSON; the Domain
// GraphQL "listening" line marks readiness; everything else is a passthrough log.

open AsyncTest
open AsyncTest.Expect

describe("PlatformRunner.classifyLine", () => {
  testPromise("classifies a tap line as Domain with the parsed payload", async () => {
    let line =
      `@@RVLESS_EVT@@ {"event":"domainEvent","seq":1,"topic":"CatalogEventTopic","service":"CatalogDcbEventLog","payload":{"event":{"TAG":"ProductAdded"}},"ts":"2026-06-07T00:00:00.000Z"}`
    switch PlatformRunner.classifyLine(line) {
    | Domain(json) =>
      let topic =
        json
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("topic"))
        ->Option.flatMap(JSON.Decode.string)
      expect(topic)->toEqual(Some("CatalogEventTopic"))
    | _ => expect("not Domain")->toEqual("Domain")
    }
  })

  testPromise("a malformed tap line falls back to Log (never throws)", async () => {
    switch PlatformRunner.classifyLine("@@RVLESS_EVT@@ {not json") {
    | Log(_) => expect(true)->toBe(true)
    | _ => expect("not Log")->toEqual("Log")
    }
  })

  testPromise("classifies the Domain GraphQL listening line as Ready", async () => {
    // Real platform output carries ANSI escapes around the [GraphQL:Domain] tag;
    // the substring checks see through them.
    let line = `12:00:00 [36mI[0m [1m[GraphQL:Domain][0m listening on http://localhost:4100/graphql (SDL: /sdl)`
    switch PlatformRunner.classifyLine(line) {
    | Ready => expect(true)->toBe(true)
    | _ => expect("not Ready")->toEqual("Ready")
    }
  })

  testPromise("the Platform (not Domain) listening line is NOT Ready", async () => {
    let line = `12:00:00 I [GraphQL:Platform] listening on http://localhost:4101/graphql`
    switch PlatformRunner.classifyLine(line) {
    | Log(_) => expect(true)->toBe(true)
    | _ => expect("expected Log")->toEqual("Log")
    }
  })

  testPromise("an arbitrary log line is Log", async () => {
    switch PlatformRunner.classifyLine("12:00:00 I [Catalog][Aggregate(Product)] handling command") {
    | Log(_) => expect(true)->toBe(true)
    | _ => expect("expected Log")->toEqual("Log")
    }
  })

  testPromise("a Log line has its ANSI colour/bold escapes stripped", async () => {
    // The child emits coloured logs even when non-TTY; the Log payload must be
    // plain text for the VS Code output channel. Build real ESC (0x1b) bytes.
    let esc = String.fromCharCode(27)
    let line = `12:00:00 ${esc}[36mI${esc}[0m ${esc}[1m[Catalog][Aggregate(Product)]${esc}[0m handling command`
    switch PlatformRunner.classifyLine(line) {
    | Log(clean) =>
      expect(clean)->toEqual("12:00:00 I [Catalog][Aggregate(Product)] handling command")
    | _ => expect("expected Log")->toEqual("Log")
    }
  })

  testPromise("stripAnsi leaves a plain line untouched", async () => {
    expect(PlatformRunner.stripAnsi("plain text, no escapes"))->toEqual("plain text, no escapes")
  })
})
