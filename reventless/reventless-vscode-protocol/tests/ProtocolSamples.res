// One representative value per `streamEvent` variant (minimal + full where a variant
// carries optional fields), single-sourced so the round-trip test and the emit-golden
// test cover the *same* set. The order here is the order of the published golden
// fixture (`fixtures/streamEvents.golden.ndjson`) — appending a case appends a golden
// line; reordering rewrites the fixture. (Not a `*Test.res.mjs` file, so jest doesn't
// run it as a suite — it's a plain helper module.)

module P = Protocol

let sampleRange: P.vsRange = {
  start: {line: 1, character: 2},
  end: {line: 3, character: 4},
}

let cases: array<(string, P.streamEvent)> = [
  ("hello", Hello({protocol: P.protocolVersion})),
  ("discoverStart", DiscoverStart({_unused: ?None})),
  ("item minimal", Item({id: "f", kind: File, label: "Foo"})),
  (
    "item full",
    Item({
      id: "f",
      parent: "p",
      kind: Test,
      label: "Foo",
      description: "a test",
      uri: "file:///x.res",
      range: sampleRange,
      component: {kind: Aggregate, name: "Product"},
    }),
  ),
  ("packages", Packages({packages: [{name: "p", dir: "/d", build: "rescript"}]})),
  ("components minimal", Components({components: [{kind: Aggregate, name: "Product", dir: "/d"}]})),
  (
    "components with files",
    Components({components: [{kind: ReadModel, name: "Products", dir: "/d", files: ["a.res", "b.res"]}]}),
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
          kind: EventsMismatch,
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
    DeadCode({findings: [{kind: OrphanEvent, plugin: "Catalog", component: "Product", detail: "unused"}]}),
  ),
  (
    "graph",
    Graph({
      nodes: [{id: "n", kind: Event, label: "N", plugin: "Catalog"}],
      edges: [{from: "a", to_: "b", kind: Emits}],
    }),
  ),
  (
    "graph edge with label",
    Graph({nodes: [], edges: [{from: "a", to_: "b", kind: TranslatesOut, label: "Payload"}]}),
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
  (
    "graph edge with via + implicit",
    Graph({
      nodes: [],
      edges: [{from: "a", to_: "b", kind: Triggers, via: ["OrderPlaced"], implicit: true}],
    }),
  ),
  // ── unknown-kind samples (one per typed kind field) ─────────────────────────
  // Prove the `Other*` escape: an unknown kind constructs, emits its raw string, and
  // decodes back into the catch-all — the graceful-degrade path a NEWER emitter's
  // vocabulary takes through an older consumer.
  (
    "item with unknown kind",
    Item({id: "w", kind: OtherItemKind("workspace"), label: "W"}),
  ),
  (
    "components with unknown kind",
    Components({components: [{kind: OtherKind("FutureKind"), name: "F", dir: "/d"}]}),
  ),
  (
    "deadCode with unknown kind",
    DeadCode({
      findings: [{kind: OtherDeadCodeKind("OrphanCommand"), plugin: "P", component: "C", detail: "d"}],
    }),
  ),
  (
    "testFail with unknown assertion kind",
    TestFail({
      id: "t1",
      durationMs: 1.0,
      messages: [{message: "boom", kind: OtherAssertionKind("FutureMismatch")}],
    }),
  ),
  (
    "graph with unknown node + edge kinds",
    Graph({
      nodes: [{id: "n", kind: OtherKind("FutureNode"), label: "N", plugin: "P"}],
      edges: [{from: "a", to_: "b", kind: OtherEdgeKind("Annotates")}],
    }),
  ),
]
