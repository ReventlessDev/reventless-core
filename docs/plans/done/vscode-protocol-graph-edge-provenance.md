# Domain-graph edge provenance: `via` + `implicit` on the protocol `graphEdge`

**Status:** ✅ **Done (2026-07-06).** `graphEdge` gained optional `via: array<string>` + `implicit: bool`; `protocolVersion` bumped 9 → 10 with the v10 source-comment line. One sample case appended to `ProtocolSamples.res` (kept last, so the golden diff is a clean one-line addition + the expected `hello` `protocol` 9→10 bump); golden regenerated, all 93 round-trip + emit-golden tests green. `Protocol.gen.ts` now exports `via?: string[]` / `implicit?: boolean`. **sury regime confirmed non-strict** (§5 last bullet): a decode of a graph edge carrying an *unknown* extra key parsed successfully and dropped it — so the version bump is a soft floor (older decoders degrade gracefully, they don't reject). Generated artifacts (`Protocol.res.mjs`, `ProtocolSamples.res.mjs`, `fixtures/streamEvents.golden.ndjson`) rebuilt; **not yet committed** (awaiting review) — the `feat(vscode-protocol): …` commit drives the lerna version/changelog on release.
**Owner:** Martin
**Scope:** `reventless/reventless-domain-protocol` (the public NDJSON graph contract) and its emitter/consumers within core (`reventless-gwt` graph emission).
**Relates to:** `reventless/reventless-domain-protocol/src/Protocol.res` (v9) · `reventless-gwt` `--format=vscode` graph events.

---

## 1. Goal

Enrich the domain-graph **edge** model in the public protocol so an edge can carry two facts it currently cannot express:

1. **`via: array<string>`** — the intermediary **event type(s)** that mediate a connection between two components. Today an inferred producer→consumer edge collapses "A emits `X`, `Y`; B consumes `X`, `Y`" into a single edge with no record of *which* event types crossed it.
2. **`implicit: bool`** — whether the edge was **inferred** (derived by cross-referencing component producers/consumers, extension/EP wiring, slice targets) versus **declared** (explicit in a component's spec). A graph mixes both; consumers legitimately want to render or filter inferred edges differently from declared ones.

The current edge type carries only a single free-form `label?: string` (used e.g. for the payload type on a translation-slice boundary). `via` is a distinct **structured multi-value** field and `implicit` a boolean flag; neither is expressible by overloading `label`, and side-channeling them outside the schema defeats the single-source-of-truth the protocol module exists to provide.

Both fields are **optional and additive** — an emitter that omits them produces byte-identical wire output to today, and a consumer that ignores them behaves as before.

### Current shape (`Protocol.res:53`)

```rescript
@genType @schema
type graphEdge = {from: string, @as("to") to_: string, kind: string, label?: string}
```

### Target shape

```rescript
// `label?` — single free-form annotation on the connection (e.g. the payload
//   type crossing a translation slice's boundary). Unchanged.
// `via?`  — the event type(s) that mediate an inferred producer→consumer edge.
//   Structured + multi-valued, so it can't fold into `label`. Absent on edges
//   that aren't event-mediated.
// `implicit?` — true when the edge was inferred by cross-referencing component
//   metadata rather than declared explicitly. Absent ⇒ treated as declared.
@genType @schema
type graphEdge = {
  from: string,
  @as("to") to_: string,
  kind: string,
  label?: string,
  via?: array<string>,
  implicit?: bool,
}
```

---

## 2. Why optional (not required)

- **Wire back-compat:** sury serialises an absent optional by *omitting the key* (same mechanism the `platformStop.code` v9 fix relies on — see the note at `Protocol.res:98`). Every existing `graph` event that sets neither field round-trips to the exact bytes it does today, so the published golden fixture's existing edge lines are unchanged.
- **Emitter back-compat:** call sites that don't compute provenance need no change; they simply omit both fields.
- **Consumer back-compat:** a decoder that doesn't read the new fields is unaffected. sury's object parse ignores keys absent from the schema (non-strict by default) — **verify this holds** for the schema build here (see §5), so a protocol-vN-minus-1 decoder tolerates a vN emitter's extra keys on the graceful-degrade path.

---

## 3. Version bump

`protocolVersion` 9 → **10**. The contract gained fields, and the constant is the single gate the emitter's `hello` and the consumer's protocol check both read (`Protocol.res:106-115`). Add the v10 changelog line in the source comment:

```rescript
// v10: domain-graph edges gained optional `via` (mediating event types) and
//      `implicit` (inferred-vs-declared) — additive, older decoders ignore them.
@genType
let protocolVersion = 10
```

Note on compatibility semantics: because the new fields are additive-optional, a **new emitter / old consumer** pairing does not break parsing — it only loses the new data. The version bump is the honest signal that consumers *may* now observe the fields and should update to use them; it is not a hard wire-break. (Whether a given consumer's version check is strict-equality or `>=` is a consumer concern, out of scope here.)

---

## 4. Test + generated-artifact steps

The protocol package single-sources its test corpus in `tests/ProtocolSamples.res` (`cases`), which drives **both** `ProtocolRoundTripTest` (serialize→parse→equal) and `ProtocolEmitGoldenTest` (emit vs `fixtures/streamEvents.golden.ndjson`). The fixture order mirrors `cases` order.

1. **Add one sample case** exercising the new fields. Because appending a case appends a single golden line while inserting mid-array shifts the following lines, **append at the end of `cases`** (accept that it sits after the `platformStop` cases rather than beside the other `graph` cases — the golden diff stays a clean one-line addition):

   ```rescript
   (
     "graph edge with via + implicit",
     Graph({
       nodes: [],
       edges: [{from: "a", to_: "b", kind: "triggers", via: ["OrderPlaced"], implicit: true}],
     }),
   ),
   ```

   The existing `"graph"` (minimal) and `"graph edge with label"` cases stay as-is and prove the omit-when-absent back-compat.

2. **Regenerate the golden fixture** and review the diff (should be exactly one added line):

   ```
   UPDATE_GOLDEN=1 pnpm --filter @reventlessdev/reventless-domain-protocol test
   ```

3. **Rebuild** so the tracked generated artifacts refresh, then commit them alongside the source:
   - `src/Protocol.gen.ts` — `graphEdge` TS type gains `readonly via?: readonly string[]` and `readonly implicit?: boolean` (genType, no hand-edit).
   - `src/Protocol.res.mjs` and the test `*.res.mjs` — recompiled.
   - `fixtures/streamEvents.golden.ndjson` — one appended line.

4. **Run the suite** (`pnpm --filter … test`) — round-trip + golden both green.

Do **not** hand-edit `CHANGELOG.md`; it is lerna-managed. A conventional-commit `feat(vscode-protocol): …` message drives the version/changelog on release.

---

## 5. Acceptance criteria

- `graphEdge` carries `via?: array<string>` and `implicit?: bool`; `protocolVersion == 10` with the v10 source comment.
- Round-trip test passes for an edge that sets both fields, one that sets neither, and one that sets only `label`.
- Golden fixture diff is a single appended line; every pre-existing line is byte-identical (proves absent-optional omission).
- `Protocol.gen.ts` exports the two new optional fields; a TS consumer type-checks against them.
- Confirmed: a decode using a schema *without* the new fields still parses JSON that *has* them (non-strict object parse) — documents the graceful-degrade guarantee the version note claims.

## 6. Risks / notes

- **Golden ordering:** reordering existing `cases` rewrites many fixture lines; only append. Keep the new case last.
- **sury strictness:** the graceful-degrade claim rests on non-strict object parsing. If the schema build here is (or becomes) strict on excess keys, an old decoder would *reject* a new emitter's edges — in that case the version bump must be treated as a hard floor by consumers. Verify and record which regime applies (§5 last bullet).
- **`label` vs `via` overlap:** these are deliberately separate — `label` is a single free-form annotation, `via` is the structured set of mediating event types. Do not collapse one into the other; a translation-boundary edge may carry `label` (payload type) while an inferred fan-out edge carries `via` (event types) and `implicit: true`.
- **No downstream coupling in this plan:** this change only widens the contract. Which emitters populate the fields, and which consumers read them, are separate follow-ups tracked in their own repos.
