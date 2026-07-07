# vscode-protocol hardening: typed kinds (untagged variants, wire-compatible) · bridge drift check · version-compat policy

**Status:** DONE (2026-07-07) — implemented with one deliberate deviation: all kind
vocabularies were **respelled PascalCase on the wire** (protocol v11, a wire break)
instead of keeping the shipped camelCase spellings. Decision by Martin during
implementation: the protocol is alpha, compatibility is not a concern, and a uniform
PascalCase wire removes every `@as` annotation (a nullary constructor's runtime repr
IS its name string). §2/§6's byte-identical-golden constraint is superseded by that
decision; everything else landed as planned. See §7 for the outcome record.
**Scope:** `reventless/reventless-vscode-protocol` (`Protocol.res`, `GraphOps.res`), `reventless-gwt` (`DomainGraph.res` emitter and the other `streamEvent` emitters).
**Relates to:** `Protocol.res` (v10) · the v10 edge-provenance plan (`docs/plans/vscode-protocol-graph-edge-provenance.md`, done) — same additive-evolution philosophy, applied to the *type layer* instead of the wire.

---

## 1. Problem

`graphNode.kind` and `graphEdge.kind` are `string` — and they are not alone. The same stringly-typed-closed-enum pattern appears on **five** protocol fields:

| Field | Vocabulary |
|---|---|
| `graphNode.kind` | ≈13 node kinds tracking the component kinds |
| `graphEdge.kind` | 14 edge kinds: `handles, emits, projects, triggers, publishes, consumes, delegatesTo, routesTo, feeds, reads, readsCrossPartition, translatesIn, translatesOut, extends` |
| `componentMeta.kind` / `componentRef.kind` | component kinds — largely the *same* vocabulary as graph node kinds; typing one but not the other would fork it |
| `deadCodeFinding.kind` | finding kinds (`orphanEvent`, …) |
| `Item.kind` / `failMessage.kind?` | discovery-item kinds (`file`/`test`/…) and assertion kinds (`notEqual`, …) |

The vocabularies are real and closed-ish at any point in time, but nothing enforces them:

- No exhaustiveness: every `switch` over kinds (`GraphOps.isWriteSide`/`isReadSide`/`isLeaf`/`isOwnershipEdge`, downstream renderers' kind→class maps) silently falls through on a typo or a newly added kind.
- No single source: the vocabulary exists only as scattered string literals across the emitter (`DomainGraph.res`), the ops (`GraphOps.res`), and every consumer.
- Refactor hazard: renaming a kind is a repo-wide grep with no compiler support.

The strings are **deliberate on the wire** — the protocol's core property is graceful degradation under version skew (an old consumer must render a graph containing kinds it doesn't know, not fail to decode the whole `graph` event). Any fix must preserve that.

## 2. Design — untagged variants with an `Other` escape

ReScript untagged variants give both properties: typed closed cases *plus* an open catch-all, serializing as the plain string (byte-identical wire):

```rescript
@unboxed
type nodeKind =
  | @as("Aggregate") Aggregate
  | @as("StateChangeSlice") StateChangeSlice
  | @as("StateViewSlice") StateViewSlice
  | @as("StateViewSliceStream") StateViewSliceStream
  | @as("ReadModel") ReadModel
  | @as("ReadModelStream") ReadModelStream
  | @as("Command") Command
  | @as("Event") Event
  | @as("AutomationSlice") AutomationSlice
  | @as("InboundTranslationSlice") InboundTranslationSlice
  | @as("OutboundTranslationSlice") OutboundTranslationSlice
  | @as("Extension") Extension
  | @as("ExtensionPoint") ExtensionPoint
  | @as("ExternalSystem") ExternalSystem
  | OtherKind(string) // forward-compat: unknown kinds decode here, render with default styling

@unboxed
type edgeKind =
  | @as("handles") Handles
  | @as("emits") Emits
  // ... all 14 ...
  | OtherEdgeKind(string)
```

(The definitive node-kind list is derived from the emitters at implementation time — the list above is indicative.)

- **Wire:** unchanged bytes. `Aggregate` serializes as `"Aggregate"`; `OtherKind("Foo")` as `"Foo"`. The golden fixture must stay byte-identical apart from any *new* appended sample case.
- **Skew tolerance preserved:** a newer emitter's unknown kind decodes into `OtherKind(s)` — consumers keep their fall-through behavior, but now the fall-through is a *visible, typed case* the compiler makes you handle.
- **Exhaustiveness gained:** every kind `switch` becomes total; adding a kind produces compile errors at exactly the sites that need a decision.
- **Stream-suffix modeling:** keep the flat literal kinds (incl. `…Stream` variants) — re-modeling as `{base, stream: bool}` would change the wire. `GraphOps.baseKind` becomes an exhaustive match instead of a regex.

## 3. Verify first (spike — the plan stands or falls here)

1. **Untagged-variant rules:** confirm the string-literal constructors + one `(string)` catch-all case coexist in a single `@unboxed` variant on the compiler version in use (literal cases must be checked before the general string case in pattern compilation).
2. **sury derivation:** confirm `@schema` on records containing these unboxed variants round-trips (parse + serialize) with byte-identical output, and that an unknown string parses into the catch-all rather than failing (`jsonableValidation` interaction).
3. **genType output:** confirm the emitted TS type is usable for the extension host (expected: a literal union widening to `string`; must not break existing host code that compares strings).

If any of the three fails, record why here and close as rejected — the `string` status quo is acceptable.

## 4. Scope of change

- `Protocol.res`: typed kinds on all five field groups from §1 — `nodeKind`, `edgeKind`, `componentKind` (shared by `componentMeta`/`componentRef`; decide whether node kinds reuse it + graph-only extras like `Command`/`Event`/`ExternalSystem`, or stay a separate type), `deadCodeKind`, `itemKind`/`assertionKind`. Each `@genType @schema`, each with its `Other*(string)` escape.
- `GraphOps.res`: predicates/`baseKind`/`isFqKind` become exhaustive matches; public signatures keep working on the typed kinds.
- `DomainGraph.res` + the other gwt emitters: construct variant values instead of string literals — the single-sourcing payoff.
- Tests: existing samples unchanged (byte-identical golden); add one sample per typed field with an unknown value proving the `Other*` decode path.
- Hand-written genType bridges (root + `src/`): re-export the new types.

**Source-breaking, wire-compatible:** ReScript consumers constructing or matching kinds must migrate when they bump the package (mechanical: string literal → constructor). TS consumers are unaffected. `protocolVersion` stays — the contract on the wire is unchanged; bump only if the spike forces any observable wire difference.

## 5. Companion hardening (same package, independent of the spike — do these even if §3 rejects the variants)

1. **Bridge drift check.** The two hand-written genType bridges (package root + `src/` — the in-package one exists because genType emits `./ReventlessVscodeProtocol.gen` src-relative for in-package namespace references) must be extended whenever a `@genType` type is added; forgetting one surfaces as a broken build in a *consumer* repo. Add a small test that parses the `export type` names out of the generated `src/*.gen.ts` files and asserts both bridges re-export every one of them — moving the failure to where the mistake is made.
2. **Version-compat policy export.** The v10 plan deliberately left "strict-equality vs `>=`" as a consumer concern. Since all evolution is additive-with-graceful-degrade (unknown events → `None`, unknown keys dropped — both now pinned by tests), the honest policy is soft: the `hello` protocol number is advisory, and consumers should warn (not refuse) on mismatch. Export that policy from the package — a documented `minCompatibleProtocol` (or `isCompatible: int => bool`) — so consumers stop inventing their own checks against `Hello({protocol})`.

## 6. Acceptance criteria

- Golden fixture: every pre-existing line byte-identical; appended unknown-value cases only.
  *(Superseded — see status note: the golden was deliberately regenerated for the v11 PascalCase respell.)*
- A `switch` over any typed kind without a wildcard compiles only when all cases (incl. the catch-all) are handled.
- Round-trip test per typed field: known value → constructor; unknown value → `Other*`; both serialize back to the original string.
- gwt emits the same NDJSON bytes as before the change for an identical platform.
  *(Superseded — kinds respelled; the event envelope is unchanged.)*
- Bridge drift test fails when a `@genType` type is added without extending both bridges.
- One exported compat predicate/constant; no consumer-side hand-rolled version checks remain in the extension.

## 7. Outcome record (2026-07-07)

**§3 spike — GREEN on rescript 12.3.0 / sury 11.0.0-alpha.4 / genType:**
1. Literal constructors + one `(string)` catch-all coexist in a single `@unboxed`
   variant; pattern compilation checks literals first, catch-all last.
2. sury `@schema` derivation round-trips byte-identically; an unknown string parses
   into the catch-all; `Other*("X")` serializes as `"X"`.
3. genType emits `"Aggregate" | … | string` — a literal union widening to `string`,
   so TS consumers comparing plain strings keep compiling.
4. Bonus: `%identity` string→kind conversion is total and sound (every case's runtime
   repr is its wire string) — used at the emitter boundaries instead of hand-written
   mapping switches.

**Shipped (protocol v11):**
- `Protocol.res`: five typed vocabularies — `componentKind` (ONE type shared by
  `componentMeta.kind` / `componentRef.kind` / `graphNode.kind`: the 12
  `Reventless.ComponentKind` folder names + graph-only `Command`/`Event`/
  `ExternalSystem` + `OtherKind(string)`; resolves §4's open question — GraphOps
  compares inventory kinds against node kinds, so a split type would fork the
  vocabulary at that seam), `edgeKind` (14 + `OtherEdgeKind`), `itemKind`
  (`File`/`Suite`/`Test` + `OtherItemKind`), `assertionKind` (the 10
  `Outcome.kindName` spellings + `OtherAssertionKind`), `deadCodeKind`
  (`OrphanEvent` + `OtherDeadCodeKind`). No `@as` anywhere — wire string =
  constructor name. Identity converters exported for emitters.
- `protocolVersion = 11`; §5.2 compat policy exported: `minCompatibleProtocol = 11` +
  `isCompatible` (advisory — consumers warn, never refuse).
- `GraphOps.res`: predicates, `baseKind`, `isFqKind` are exhaustive matches (no
  wildcard); `readEdgesToAdd` constructs `Reads`/`ReadsCrossPartition`.
- Emitters: `DomainGraph.res` constructs node/edge constructors (dedup key via
  `edgeKindToString`); `FormatterVsCode.res` constructs `File`/`Suite`/`Test` and
  converts `ComponentKind.folderName` / `Outcome.kindName` via identity;
  `DomainDeadCode.finding.kind` is typed `deadCodeKind`.
- Two pre-existing sample bugs surfaced by typing: the golden's deadCode kind was
  `"orphanEvent"` (emitter says `OrphanEvent`) and its failMessage kind `"notEqual"`
  (not in the `Outcome.kindName` vocabulary at all) — both fixed to real values.
- Golden regenerated: kind respellings + `protocol:11` + five appended unknown-kind
  (`Other*`) sample lines; round-trip test also pins unknown-kind decode from raw bytes.
- §5.1 bridge drift test (`tests/BridgeDriftTest.res`): parses `export type` names
  from `src/*.gen.ts`, asserts both hand-written bridges re-export every one
  (negative-tested); also surfaced `position`/`failLocation` missing from both
  bridges — added.

**Not done here (consumer repo, reventless-tools):** the extension's kind→style maps
(`DomainGraphD2.res` etc.), test-item kind handling, and the two hand-rolled
`evt.protocol !== protocolVersion` checks in `extension.ts` (should become
`!isCompatible(evt.protocol)`) must follow when the extension bumps to protocol v11.
