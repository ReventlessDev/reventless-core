# vscode-protocol hardening: typed kinds (untagged variants, wire-compatible) · bridge drift check · version-compat policy

**Status:** Backlog — not started
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
- A `switch` over any typed kind without a wildcard compiles only when all cases (incl. the catch-all) are handled.
- Round-trip test per typed field: known value → constructor; unknown value → `Other*`; both serialize back to the original string.
- gwt emits the same NDJSON bytes as before the change for an identical platform.
- Bridge drift test fails when a `@genType` type is added without extending both bridges.
- One exported compat predicate/constant; no consumer-side hand-rolled version checks remain in the extension.
