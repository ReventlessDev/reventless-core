// The NDJSON contract between the `reventless-gwt watch/platform --format=vscode`
// CLI and the `reventless-vscode` extension — a single sury `@schema` definition both
// sides use: the CLI *emits* via `toJsonLine` (serialize) and the extension *decodes*
// via `parseStreamEvent` (parse + validate). A `protocolVersion` bump now touches this
// one definition instead of drifting across two hand-written declarations.
//
// `@tag("event")` makes the ReScript variant's runtime representation the flat wire
// shape (`{event:"item", …fields}`), so sury round-trips it exactly as the CLI's
// previous hand-built JSON, and genType renders the `{event:…}` union the extension
// host shell switches on. CommonJS output so the CJS extension consumes it natively
// and the ESM CLI imports it (ESM→CJS is well-supported).

// JSON.t schemas (the `domainEvent` payload) require sury's json support enabled
// before any schema referencing it is built.
let () = S.enableJson()

@genType @schema
type position = {line: int, character: int}

@genType @schema
type vsRange = {start: position, end: position}

@genType @schema
type failLocation = {uri: string, range: vsRange}

@genType @schema
type failMessage = {
  message: string,
  kind?: string,
  expected?: string,
  actual?: string,
  location?: failLocation,
}

@genType @schema
type packageInfo = {name: string, dir: string, build: string}

@genType @schema
type componentMeta = {kind: string, name: string}

@genType @schema
type componentRef = {kind: string, name: string, dir: string, files?: array<string>}

@genType @schema
type deadCodeFinding = {kind: string, plugin: string, component: string, detail: string}

// `to` is a ReScript keyword → `@as` keeps the runtime/wire/TS field name `to`.
@genType @schema
type graphNode = {id: string, kind: string, label: string, plugin: string}
// `label` (optional) annotates the connection — e.g. the payload type crossing a
// translation slice's boundary to/from an external system. Absent on ordinary edges.
// `via` (optional) — the event type(s) that mediate an inferred producer→consumer
// edge; structured + multi-valued, so it can't fold into the single-string `label`.
// Absent on edges that aren't event-mediated.
// `implicit` (optional) — true when the edge was inferred by cross-referencing
// component metadata rather than declared explicitly. Absent ⇒ treated as declared.
@genType @schema
type graphEdge = {
  from: string,
  @as("to") to_: string,
  kind: string,
  label?: string,
  via?: array<string>,
  implicit?: bool,
}

// The watch + platform-runner stream as a flat, internally-tagged variant.
// `discoverStart` carries an optional phantom field so it serialises as an object
// (`{event:"discoverStart"}`) rather than a bare string (a `@tag` nullary).
@genType @schema @tag("event")
type streamEvent =
  | @as("hello") Hello({protocol: int})
  | @as("discoverStart") DiscoverStart({_unused?: bool})
  | @as("item")
  Item({
      id: string,
      parent?: string,
      kind: string,
      label: string,
      description?: string,
      uri?: string,
      range?: vsRange,
      component?: componentMeta,
    })
  | @as("packages") Packages({packages: array<packageInfo>})
  | @as("components") Components({components: array<componentRef>})
  | @as("discoverEnd") DiscoverEnd({total: int})
  | @as("buildStart") BuildStart({package: string})
  | @as("buildOk") BuildOk({package: string, durationMs: float})
  | @as("buildFail") BuildFail({package: string, message: string})
  | @as("buildExternal") BuildExternal({package: string})
  | @as("runStart") RunStart({total: int, filter: array<string>})
  | @as("testStart") TestStart({id: string})
  | @as("testPass") TestPass({id: string, durationMs: float})
  | @as("testFail") TestFail({id: string, durationMs: float, messages: array<failMessage>})
  | @as("testSkip") TestSkip({id: string, reason: string})
  | @as("runEnd") RunEnd({passed: int, failed: int, skipped: int, durationMs: float})
  | @as("deadCode") DeadCode({findings: array<deadCodeFinding>})
  | @as("graph") Graph({nodes: array<graphNode>, edges: array<graphEdge>})
  // Component definitions (Phase 6.3) — one `encodePluginStructureEntry` JSON object
  // per plugin (commands/events with field schemas + read-side state schemas), used
  // to render field rows. Opaque JSON entries (same shape the
  // Platform_ComponentDefinitions GraphQL query returns).
  | @as("definitions") Definitions({entries: array<JSON.t>})
  | @as("platformStart")
  PlatformStart({package: string, dir: string, domainPort: int, platformPort: int})
  | @as("platformReady") PlatformReady({domainEndpoint: string})
  | @as("domainEvent") DomainEvent({seq: int, topic: string, service: string, payload: JSON.t, ts: string})
  | @as("platformLog") PlatformLog({line: string})
  // `code` is a plain OPTIONAL field: an exit code (`code: N`) or absent when the
  // child was killed by a signal. A previous `jsNullable` (required `int | null`)
  // field didn't round-trip — sury's serialize of `None` *omits* the key, but the
  // parser then required it present, so a signal-killed platform's stop event was
  // undecodable. Optional ⇄ absent round-trips cleanly (no `null`/`undefined` in
  // the JSON, so `jsonableValidation` still passes).
  | @as("platformStop") PlatformStop({code?: int})

// Bumped whenever the contract changes (new events, renamed fields). Single source —
// the CLI's `hello` emission and the extension's protocol check both read this.
// `@genType` so the TS consumer imports this constant instead of hand-copying the
// number (which would silently drift from the schema it's meant to gate).
// v7: local platform runner events (platformStart/Ready/Log/Stop + domainEvent).
// v8: component definitions event (field schemas for command/event/read-side state).
// v9: platformStop `code` is now a plain optional (was required `int | null`), so a
//     signal-killed platform's stop event round-trips instead of failing to decode.
// v10: domain-graph edges gained optional `via` (mediating event types) and
//      `implicit` (inferred-vs-declared) — additive, older decoders ignore them.
@genType
let protocolVersion = 10

// Decode + validate one NDJSON line. `None` for a malformed line or an unknown event
// (a version-skewed CLI degrades gracefully — same effect as the old "ignore unknown").
@genType
let parseStreamEvent = (raw: string): option<streamEvent> =>
  switch S.parseJsonStringOrThrow(raw, streamEventSchema) {
  | v => Some(v)
  | exception _ => None
  }

// Serialize one event to its NDJSON line (the CLI emit path). `@tag` + the schema
// reproduce the exact flat wire the CLI previously hand-built. `reverseConvertOrThrow`
// applies the schema's reverse transforms (e.g. `None` code → `null`) without sury's
// strict `jsonableValidation` (which the union's `JSON.t` payload would trip).
let toJsonLine = (e: streamEvent): string =>
  e->S.reverseConvertOrThrow(streamEventSchema)->JSON.stringifyAny->Option.getOr("")
