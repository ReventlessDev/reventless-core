// Round-trips every `streamEvent` variant through the wire: `toJsonLine`
// (the CLI emit path) → `parseStreamEvent` (the extension decode path) must
// reproduce the original value exactly. This pins the NDJSON contract IN this
// package — previously it was only exercised indirectly by a consumer.

open JestGlobals

module P = Protocol

let roundTrips = (e: P.streamEvent) =>
  expect(P.parseStreamEvent(P.toJsonLine(e)))->toEqual(Some(e))

let sampleRange: P.vsRange = {
  start: {line: 1, character: 2},
  end: {line: 3, character: 4},
}

describe("Protocol round-trip (toJsonLine -> parseStreamEvent)", () => {
  let cases: array<(string, P.streamEvent)> = [
    ("hello", Hello({protocol: P.protocolVersion})),
    ("discoverStart", DiscoverStart({_unused: ?None})),
    ("item minimal", Item({id: "f", kind: "file", label: "Foo"})),
    (
      "item full",
      Item({
        id: "f",
        parent: "p",
        kind: "test",
        label: "Foo",
        description: "a test",
        uri: "file:///x.res",
        range: sampleRange,
        component: {kind: "Aggregate", name: "Product"},
      }),
    ),
    ("packages", Packages({packages: [{name: "p", dir: "/d", build: "rescript"}]})),
    ("components minimal", Components({components: [{kind: "Aggregate", name: "Product", dir: "/d"}]})),
    (
      "components with files",
      Components({components: [{kind: "ReadModel", name: "Products", dir: "/d", files: ["a.res", "b.res"]}]}),
    ),
    ("discoverEnd", DiscoverEnd({total: 5})),
    ("buildStart", BuildStart({package: "/p"})),
    ("buildOk", BuildOk({package: "/p", durationMs: 12.5})),
    ("buildFail", BuildFail({package: "/p", message: "compile error"})),
    ("buildExternal", BuildExternal({package: "/p"})),
    ("runStart", RunStart({total: 3, filter: ["x", "y"]})),
    ("testStart", TestStart({id: "t1"})),
    ("testPass", TestPass({id: "t1", durationMs: 1.0})),
    ("testFail minimal", TestFail({id: "t1", durationMs: 2.0, messages: [{message: "boom"}]})),
    (
      "testFail full",
      TestFail({
        id: "t1",
        durationMs: 2.0,
        messages: [
          {
            message: "not equal",
            kind: "notEqual",
            expected: "1",
            actual: "2",
            location: {uri: "file:///x.res", range: sampleRange},
          },
        ],
      }),
    ),
    ("testSkip", TestSkip({id: "t1", reason: "todo"})),
    ("runEnd", RunEnd({passed: 1, failed: 2, skipped: 3, durationMs: 4.0})),
    (
      "deadCode",
      DeadCode({findings: [{kind: "orphanEvent", plugin: "Catalog", component: "Product", detail: "unused"}]}),
    ),
    (
      "graph",
      Graph({
        nodes: [{id: "n", kind: "Event", label: "N", plugin: "Catalog"}],
        edges: [{from: "a", to_: "b", kind: "emits"}],
      }),
    ),
    (
      "graph edge with label",
      Graph({nodes: [], edges: [{from: "a", to_: "b", kind: "translatesOut", label: "Payload"}]}),
    ),
    ("definitions", Definitions({entries: [JSON.Object(Dict.fromArray([("k", JSON.String("v"))]))]})),
    ("platformStart", PlatformStart({package: "p", dir: "/d", domainPort: 4000, platformPort: 4001})),
    ("platformReady", PlatformReady({domainEndpoint: "http://localhost:4000"})),
    (
      "domainEvent",
      DomainEvent({
        seq: 1,
        topic: "t",
        service: "s",
        payload: JSON.Object(Dict.fromArray([("a", JSON.Number(1.0))])),
        ts: "2026-07-02T00:00:00.000Z",
      }),
    ),
    ("platformLog", PlatformLog({line: "hello"})),
    ("platformStop with exit code", PlatformStop({code: 0})),
    ("platformStop absent (signal-killed)", PlatformStop({code: ?None})),
  ]
  cases->Array.forEach(((name, e)) => testSync(name, () => roundTrips(e)))

  testSync("a malformed line decodes to None", () =>
    expect(P.parseStreamEvent("{not json"))->toEqual(None)
  )
  testSync("an unknown event decodes to None (version-skew tolerance)", () =>
    expect(P.parseStreamEvent(`{"event":"somethingNewer","x":1}`))->toEqual(None)
  )
})
