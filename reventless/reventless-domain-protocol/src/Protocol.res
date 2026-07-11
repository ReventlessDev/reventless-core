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

// ── typed kind vocabularies ──────────────────────────────────────────────────
// Every closed-ish `kind` enum on the wire is an @unboxed variant: the known cases
// are typed constructors (serializing as their PascalCase constructor name — no @as
// needed), plus one `Other*(string)` catch-all so a kind from a NEWER emitter decodes
// into a visible, typed case instead of failing the whole event (version-skew
// tolerance). Exhaustive `switch`es over these stay total: adding a kind produces
// compile errors at exactly the sites that need a decision.

// The component/graph-node kind vocabulary — the `Reventless.ComponentKind` folder
// names (single source of the component vocabulary), plus the graph-only kinds
// (`Command` / `Event` / `ExternalSystem`). ONE type for `componentMeta.kind`,
// `componentRef.kind` and `graphNode.kind`: an inventory kind is compared against a
// graph-node kind (inventory→graph-node resolution), so a split type would fork
// the vocabulary and force conversions at that seam.
@genType @schema @unboxed
type componentKind =
  | Aggregate
  | StateChangeSlice
  | StateViewSlice
  | StateViewSliceStream
  | ReadModel
  | ReadModelStream
  | AutomationSlice
  | InboundTranslationSlice
  | OutboundTranslationSlice
  | Extension
  | ExtensionPoint
  | Task
  | Command
  | Event
  | ExternalSystem
  | OtherKind(string)

// Domain-graph edge kinds (`graphEdge.kind`).
@genType @schema @unboxed
type edgeKind =
  | Handles
  | Emits
  | Projects
  | Triggers
  | Publishes
  | Consumes
  | DelegatesTo
  | RoutesTo
  | Feeds
  | Reads
  | ReadsCrossPartition
  | TranslatesIn
  | TranslatesOut
  | Extends
  | OtherEdgeKind(string)

// Discovery-item kinds (`Item.kind`) — the VS Code test-tree node types.
@genType @schema @unboxed
type itemKind =
  | File
  | Suite
  | Test
  | OtherItemKind(string)

// Assertion/mismatch kinds (`failMessage.kind`) — the `Outcome.mismatch` family
// names; a client gates the apply-expected quick-fix on these.
@genType @schema @unboxed
type assertionKind =
  | EventsMismatch
  | ErrorMismatch
  | StateMismatch
  | NoEventExpected
  | TodoMismatch
  | AppendConditionMismatch
  | TranslateError
  | QueryRowsMismatch
  | PublishedActionsMismatch
  | Throw
  | OtherAssertionKind(string)

// Dead-code finding kinds (`deadCodeFinding.kind`).
@genType @schema @unboxed
type deadCodeKind =
  | OrphanEvent
  | OtherDeadCodeKind(string)

// The runtime representation of every kind case IS its wire string (@unboxed +
// nullary-constructor-as-string), so identity is a total, sound conversion: a known
// string pattern-matches its constructor, an unknown one the `Other*` catch-all.
// For emitters sitting on string vocabularies (e.g. `ComponentKind.folderName`,
// `Outcome.kindName`) and for building string keys from typed kinds.
external componentKindOfString: string => componentKind = "%identity"
external assertionKindOfString: string => assertionKind = "%identity"
external edgeKindToString: edgeKind => string = "%identity"
external componentKindToString: componentKind => string = "%identity"

@genType @schema
type position = {line: int, character: int}

@genType @schema
type vsRange = {start: position, end: position}

@genType @schema
type failLocation = {uri: string, range: vsRange}

@genType @schema
type failMessage = {
  message: string,
  kind?: assertionKind,
  expected?: string,
  actual?: string,
  location?: failLocation,
}

@genType @schema
type packageInfo = {name: string, dir: string, build: string}

@genType @schema
type componentMeta = {kind: componentKind, name: string}

@genType @schema
type componentRef = {kind: componentKind, name: string, dir: string, files?: array<string>}

@genType @schema
type deadCodeFinding = {kind: deadCodeKind, plugin: string, component: string, detail: string}

// `to` is a ReScript keyword → `@as` keeps the runtime/wire/TS field name `to`.
@genType @schema
type graphNode = {id: string, kind: componentKind, label: string, plugin: string}
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
  kind: edgeKind,
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
      kind: itemKind,
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
// v11: kind vocabularies are typed @unboxed variants and uniformly PascalCase on the
//      wire (edge kinds `handles`→`Handles` …, item kinds `file`→`File` …) — a
//      deliberate wire break for kind CONSUMERS; the event envelope is unchanged and
//      unknown kinds decode into the `Other*` catch-alls.
@genType
let protocolVersion = 11

// ── version-compat policy ────────────────────────────────────────────────────
// The `hello` protocol number is ADVISORY. Evolution is additive-with-graceful-
// degrade (unknown events → `None`, unknown keys dropped, unknown kinds → `Other*` —
// all pinned by tests), so a consumer should WARN on an incompatible peer and keep
// decoding, not refuse the stream. `minCompatibleProtocol` is the oldest emitter
// this package still renders with full fidelity (v11 respelled every kind, so a
// ≤v10 emitter's kinds all land in `Other*` — degraded, but functional).
@genType
let minCompatibleProtocol = 11

@genType
let isCompatible = (protocol: int): bool => protocol >= minCompatibleProtocol

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
