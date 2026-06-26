# Plan (Backlog): Infer DCB Tag Scope From Global Usage

**Status:** Backlog (not started)

**Motivation commits:**
`074d4faec` (*feat: verify category exists in AddProduct via cross-partition DCB read*) and
`96660335e` (*feat(gwt): catch unreachable cross-entity reads in per-slice Behavior GWT*) —
the work that exposed the ergonomic problem this plan fixes.

**Touches:** `reventless-spec/src/generator/` (new inference pass),
`reventless-spec/src/components/DcbTag.res` (scope extraction),
`reventless-spec/src/components/DcbValidation.res` (relaxed/repurposed checks),
`reventless-gwt` (harness derives the same inferred scope).

---

## Problem

To make `AddProduct` reject products whose category does not exist — a one-line
business rule — a developer today must reason about DCB **tag scope** across four
different schemas and place three different annotations correctly:

```rescript
// What the dev has to write today (and is easy to get wrong):
type event = ProductAdded({ @partitionTag productId, …, @crossPartition categoryId })   // emitted
type consumedEvent = | ProductAdded({productId}) | CategoryAdded({categoryId}) | …       // read
// + @crossPartition on every Category-slice event that produces categoryId
// + (to avoid sibling fetches) @noTag on the emitted categoryId — see "Sibling leak" below
```

This is too much. The tag annotations (`@partitionTag`, `@crossPartition`,
`@noTag`) are **not local decisions** — they encode how a key is used *across the
whole plugin* — yet the dev has to hand-place them per field, per schema. Evidence
it's a footgun: the first implementation (commit `074d4faec`) got it subtly wrong
twice — first omitting `@crossPartition` (so the decision query AND-ed
`productId`+`categoryId` and *never* saw `CategoryAdded` → `CategoryNotFound`
always, in production), then over-tagging the emitted event (the "sibling leak"
below).

### The two failure modes the dev must avoid by hand

1. **Forgot `@crossPartition`** → the cross-entity reference key is AND-ed with the
   partition into one clause; the foreign event can never reach `decide`. Silent in
   production; now caught by the per-slice reachability guard (commit `96660335e`).
2. **Sibling leak** → tagging `categoryId` on the *emitted* `ProductAdded` puts
   every product into the `categoryId` index, so `AddProduct`'s `categoryId=cat1`
   read sweeps up *all* sibling products in that category. The dev then has to
   carry `productId` on the consumed event and track `addedProductIds` to
   discriminate — extra code to undo an over-tagging they shouldn't have done.

Both failure modes are *derivable* from global usage. The dev should not be the one
deriving them.

---

## Goal

A developer declares **fields and what they consume**; the framework derives all
DCB tag scope. No `@partitionTag` / `@crossPartition` / `@noTag` for the common
"reference another entity" case:

```rescript
// AddProduct.res — the target developer experience (zero scope annotations)
type consumedEvent =
  | ProductAdded                          // my own lifecycle — does this product exist?
  | CategoryAdded({categoryId: string})   // I read the category's lifecycle…
  | CategoryArchived({categoryId: string})
type command = AddProduct({productId: string, name, description, price, categoryId: string})
type event   = ProductAdded({productId: string, name, description, price, categoryId: string})
```

Explicit annotations remain as **escape hatches** for the cases inference can't
resolve (see §"Escape hatches"). The per-slice reachability guard remains the
**safety net** for inference bugs or escape-hatch mistakes.

---

## How scope is determined today (baseline)

- Scope is a **global per-key property**: `DcbTag.crossPartition` sets a
  `dcbCrossPartitionId` metadata flag on the field schema; `extractCrossPartitionTagKeys`
  reads it back. `DcbValidation.validateCrossPartitionScope` *checks* that every
  producer of a key agrees on scope — but the dev still has to *write* the agreeing
  annotations.
- The cross-partition key set is extracted from the **produced event schemas** and
  threaded to `DcbEventLog_Builder` (`~crossPartitionTagKeys`) and the
  `StateChangeSlice` decision-query builder. The **generator does no scope
  derivation today** — it only wires components; the scope lives entirely in the
  hand-written annotations.

The shift this plan proposes: move the *derivation* into the generator (which
already holds the cross-slice picture), so the annotations become outputs, not
inputs.

---

## Inference rules

The generator can build, from every slice's `command` / `consumedEvent` / `event`
specs, a global graph and derive three things. Let an **entity** be the set of
events a slice emits, and a key's **owner** be the slice/entity whose own emitted
events are identified by it.

1. **Partition** of a slice = the key its *own emitted* events are identified by.
   - `AddProduct` emits `ProductAdded` identified by `productId` → partition =
     `productId`. (`categoryId` cannot be its partition: it is owned by Category.)
   - Encodes the rule already in `derivePartitionTag`, but sources the choice from
     ownership instead of a hand-placed `@partitionTag`.

2. **Cross-partition read** = a key that appears on a *consumed foreign* event and
   is *another entity's partition*.
   - `categoryId` is Category's partition (`AddCategory` emits `CategoryAdded`
     keyed by it). `AddProduct` consumes `CategoryAdded` while partitioned by
     `productId` → reading `categoryId` is cross-partition → mark the key
     `@crossPartition` globally (on every producer). No dev annotation.

3. **Index vs payload** for a `*Id` field on an *emitted* event = indexed iff some
   slice's *decision* reads events by that key (the key appears as a read key on a
   consumed event somewhere). Otherwise it is payload → not tagged.
   - `categoryId` on emitted `ProductAdded`: no decision reads products *by
     category* (only read models / views project it) → **payload, not indexed** →
     no sibling leak, and no `@noTag` to write.
   - This is the rule that makes the "sibling leak" structurally impossible.

The "owner" map (entity → partition key) is the linchpin: build it first from each
slice's own emitted events, then rules 2–3 fall out by checking other slices'
consumed keys against it.

---

## Escape hatches (inference can't / shouldn't decide)

Keep the explicit annotations; they override inference where intent is ambiguous:

- **`@compositePartitionTag`** — multi-field partition key; inference can't pick a
  split.
- **`@crossPartition` (explicit)** — the **M:N capacity** read, where you *do* want
  an emitted event indexed by a foreign key because a decision reads "all X for a
  Y" (e.g. "≤ N orders per product", course-subscription capacity). This is the
  one case where the emitted event *should* carry the foreign key as an index —
  inference would mark it payload (rule 3), so the dev opts back in. Inference must
  **not** silently override an explicit `@crossPartition`.
- **`@partitionTag` (explicit)** — when a slice's own events legitimately carry two
  owned keys and ownership is ambiguous.
- **`@noTag` (explicit)** — force payload on a `*Id` that inference would index.

Rule of thumb for the resulting docs: *you only annotate scope when you're doing
something the framework can't see — a composite key or an M:N capacity read.*

---

## Where it lives

> **Correction (superseded by "Phase 1 design" above).** This section originally said
> "a new generator pass… [the generator] already computes the data threaded as
> `crossPartitionTagKeys`." Both halves are wrong: (1) the generator computes **nothing**
> about tags — the derivation lives at **runtime** in
> `reventless-core/.../Dcb/Dcb_Builder.res` (`extractCrossPartitionTagKeys` /
> `mergeTagKeysByEventType` / `derivePartitionTag`); (2) the generator runs in
> `prebuild`, **before `rescript build`**, so it has no compiled `S.t` schemas to
> introspect — only `.res` source. The home is therefore the **runtime adapter** in
> `Dcb_Builder`, calling the shared pure `DcbScopeInference` module. The text below is
> kept for the *rules* it lists; ignore its "generator" framing.

The derivation (wherever invoked) must:

1. Build the entity→partition owner map.
2. Derive per-key scope (partition / cross-partition) and per-(event,field)
   index-ness.
3. Emit the derived `crossPartitionTagKeys` / `tagKeysByEventType` into the wiring
   (replacing today's annotation-extraction path), and the per-event tag
   suppression for payload keys.

The PPX stays per-file (it can't see across files) and keeps auto-tagging `*Id`
fields; the runtime adapter becomes the authority that *re-scopes* them globally. The
annotations the PPX honours remain valid as escape-hatch overrides.

---

## Harness parity

The per-slice (`Behavior_GWT`) and flow (`Flow_GWT`) harnesses must derive the same
inferred scope so a test sees the production query. Today they extract
`crossPartitionTagKeys` from the slice's **emitted** schema (which only worked
because the emitted event carried the tag). Under inference the harness must call
the **same shared `DcbScopeInference` module** — building `sliceShape` from the
slice's **consumed** reads plus emitted writes (`consumed ∪ emitted`) — so a test
sees the identical derived query. This is the third consumer of the shared boundary
(runtime adapter, editor adapter, harness adapter). The reachability guard (already
shipped) is unchanged; it keeps catching the cases inference gets wrong.

---

## Phase 1 design — the shared inference boundary (factored)

> Settled before any code: the inference is written **once** as a pure module over a
> schema-agnostic representation, so the runtime *and* the VS Code tooling
> (`reventless-tools`) can reuse it. The runtime-vs-generator "where it lives"
> question (§"Where it lives") collapses to *which adapter feeds the pure module* —
> the rules live in one place either way. This is the concrete answer to "factor the
> shared-module boundary into Phase 1."

### Why a shared module (the tools-repo consequence)

`reventless-tools`' uncommitted plan `vscode-consumed-event-authoring.md` surfaces the
DCB tag annotations in the editor and **explicitly does not re-implement their
semantics** — it treats `DcbTagInference.ml` as source of truth. Once scope is
*inferred*, the editor needs the same derivation to (a) stop teaching now-deprecated
annotations and (b) add the new "explicit annotation contradicts inferred scope"
diagnostic. The editor works **pre-compile, on parsed source** (`pluginDcbEvents` →
`SpecVariant[]`) and imports nothing from core's runtime. So if the inference is
written against compiled `S.t` metadata (the path of least resistance in
`Dcb_Builder`, where `extractCrossPartitionTagKeys` already lives), the editor is
**locked out** and must duplicate the rules — the exact thing that plan forbids.
Factoring a schema-agnostic core avoids the duplication regardless of where the
runtime invokes it.

### The representation (the boundary type)

Deliberately carries **no `S.t` and no tag metadata** — only the structural shape both
sides can produce. The whole point is to derive scope *from this*, not from
`@crossPartition`/`@partitionTag` flags.

```rescript
// reventless-spec/src/components/DcbScopeInference.res  (canonical, pure, no Pulumi/S.t)
type idField = {name: string, isList: bool}          // a *Id / *Ids-shaped field, by name only
type eventShape = {eventType: string, idFields: array<idField>}
type sliceShape = {
  sliceName: string,
  command: array<idField>,        // *Id fields on the command
  consumed: array<eventShape>,    // consumed arms + their *Id fields (the read keys)
  produced: array<eventShape>,    // produced arms + their *Id fields (the write keys)
}

type scope = Partition | CrossPartition | Payload
type derived = {
  partitionBySlice: dict<string>,             // sliceName -> its partition key
  ownerByKey: dict<string>,                   // tagKey -> owning sliceName
  crossPartitionTagKeys: array<string>,       // == today's threaded array
  tagKeysByEventType: dict<array<string>>,    // indexed (non-payload) keys per produced eventType
  ambiguities: array<(string, string)>,       // (sliceName, why) -> caller turns into error / "need @partitionTag"
}

let infer: array<sliceShape> => derived
```

### The rules, over the representation

1. **Owner map (fixpoint).** Seed: a slice whose produced events carry exactly **one**
   `*Id` field owns that key (its partition). Resolve multi-id producers by
   elimination: `ProductAdded({productId, categoryId})` — `categoryId` already owned by
   Category ⇒ `productId` is Product's partition, Product owns `productId`. A producer
   left with ≥2 unowned keys, or 0 own keys (pure join), → `ambiguities` (caller
   requires explicit `@partitionTag`; never guess — Open-questions §1).
2. **Cross-partition** = a key on a *consumed foreign* event that is *another* slice's
   partition (per the owner map). `categoryId` ∈ `AddProduct.consumed` ∧ owned by
   Category ∧ `AddProduct` partitioned by `productId` ⇒ `crossPartitionTagKeys += categoryId`.
3. **Index-vs-payload** for a `*Id` on a *produced* event = indexed **iff** some slice's
   `consumed` carries that key (it is read by somewhere). Else payload → omitted from
   `tagKeysByEventType` ⇒ no GSI write ⇒ sibling-leak structurally impossible.

### The two adapters (the only per-side code)

- **Runtime** — `reventless-core/.../Dcb/Dcb_Builder.res`: build `sliceShape[]` by
  walking each slice's `commandSchema` / `consumedEventSchema` / `eventSchema` variants
  and collecting `*Id`-named fields (a small `S.t`→`idField` walk, reusing the existing
  `toUnknownSchema`/`Union`/`Object` traversal). Replace the four hand-extraction lines
  (`extractCrossPartitionTagKeys`, `extractTagKeysByEventType`+merge, `derivePartitionTag`)
  with `DcbScopeInference.infer(...)` and thread `derived.crossPartitionTagKeys` /
  `derived.tagKeysByEventType` / `derived.partitionBySlice` exactly as today.
- **Editor** — `reventless-tools/.../extension.ts`: build `sliceShape[]` from
  `pluginDcbEvents` + `parseSpecTypes(command/consumedEvent)` (already produces
  `fieldSpec{name,list,isId}`; `*Id` detection is by name). Calls the **same** function.

### Sharing mechanism (decision needed in Phase 1, options ranked)

The tools repo consumes core as **published `@reventlessdev/*`** packages and uses
genType; reventless-spec does **not** emit genType. Options:

1. **(Recommended) Canonical module in `reventless-spec` + checked-in golden vectors.**
   `DcbScopeInference.res` is the one implementation; runtime imports it directly. Ship a
   `DcbScopeInference.fixtures.json` (input `sliceShape[]` → expected `derived`) as the
   cross-repo **contract**. Tools either (a) imports the compiled `.res.mjs` from
   `@reventlessdev/reventless-spec` if a dep is acceptable, or (b) keeps a thin TS port
   **verified in CI against the golden vectors**. No genType change, no build coupling;
   the vectors prevent drift. The vectors double as the runtime's unit tests.
2. **Enable genType on `reventless-spec`** for this module and vendor the `.gen.ts` into
   tools. Cleanest typing, but adds a genType build dep to a core package and a
   vendoring/publish step — heavier than the feature warrants for v1.
3. **Two implementations, no contract.** Rejected — reintroduces exactly the drift the
   tools plan calls out.

### Zero-diff verification (the Phase 1 gate — no behaviour change yet)

`infer` runs **alongside** today's extraction; assert byte-identical output before any
wiring is switched:

- Unit: for every example plugin's slice set, `DcbScopeInference.infer(shapes)` yields
  `crossPartitionTagKeys` / `tagKeysByEventType` / `partitionTag` **equal** to the current
  `extractCrossPartitionTagKeys` / `mergeTagKeysByEventType` / `derivePartitionTag`.
- The headline case: `AddProduct` derives `crossPartitionTagKeys = ["categoryId"]` and
  `categoryId` **payload** on emitted `ProductAdded` — *without reading any annotation*
  (run the adapter on shapes built with the `@crossPartition`/`@partitionTag` flags
  stripped).
- Cross-check `partitionBySlice` against `derivePartitionTag` for every slice; any
  `ambiguities` entry on an existing slice is a Phase-1 bug (today's slices all resolve).

Only once this gate is green do Phases 2–4 switch the wiring, harness, and examples
over to the derived values.

## Phases

1. **Owner map + inference, behind a flag.** ✅ **Done.** Compute the
   entity→partition map and derived scope **in the shared `DcbScopeInference`
   module** (see Phase 1 design above), invoked from `Dcb_Builder`'s runtime
   adapter; log a diff against the hand-written annotations for every example
   plugin. Goal: zero diff where annotations are already correct, and the
   AddProduct case derived *without* any `@crossPartition`.

   **Shipped:**
   - `reventless/reventless-spec/src/components/DcbScopeInference.res` — the pure,
     schema-agnostic core (boundary types + `infer`; the three rules; no `S.t`, no
     Pulumi). Partition resolves without a fixpoint:
     `producedKeys(S) \ foreignConsumedKeys(S)`.
   - `DcbTag.res` — the runtime adapter: `idFieldsOfProperties` /
     `eventShapesOfSchema` / `sliceShapeFromSchemas` (`S.t` → `sliceShape`, by field
     **name**). Schema-coupling lives here; the core stays schema-agnostic.
   - `Dcb_Builder.res` — runs `infer` **alongside** today's annotation extraction
     and `log.info`s every diff (crossPartitionTagKeys, per-eventType dropped tag,
     ambiguities). Pure diagnostics — nothing threaded yet; annotated values still
     drive the wiring.
   - `tests/dcb/DcbScopeInferenceTest.res` — 16 golden-vector + adapter-parity tests
     (full dcb suite 154/154, zero warnings). Confirms: AddProduct derives
     `crossPartitionTagKeys = ["categoryId"]` and `ProductAdded` indexes
     `["productId"]` only (categoryId payload) **from un-annotated structure**; the
     adapter reproduces `extractCrossPartitionTagKeys` on a real annotated fixture.

   **Gate observed against the real compiled catalog** (8 StateChangeSlices, via
   `DcbTag.sliceShapeFromSchemas` + `infer` over the actual `S.t` schemas):
   - `crossPartitionTagKeys`: **zero diff** (`["categoryId"]` both).
   - `tagKeysByEventType`: **one diff only** — `ProductAdded [categoryId,productId]
     → [productId]`, the intended sibling-leak fix. Every other event type
     (Category*, ProductDemand*, Product*Changed) is byte-identical.
   - `partitionBySlice`: all correct; `ambiguities: []`.

   **Two corrections the real data forced into the core** (would have shipped
   wrong without running the gate):
   - **`RecordProductDemand` ambiguity → `@partitionTag` hint.** Its event carries
     two owned-looking keys (`productId`, `orderId`); inference can't pick. Added
     `partitionHint: option<string>` to `sliceShape` (the explicit `@partitionTag`
     escape hatch), extracted by the adapter via `extractPartitionTagFields`. With
     it, the partition resolves to `productId` and the ambiguity disappears.
   - **Generalized rule 3 (own-stream / composite reads).** The first cut indexed
     *only* the partition key, which would have dropped `orderId` from
     `ProductDemandRecorded` and **broken its idempotency read**. Rule 3 now indexes
     a key iff it is the partition **or** some slice reads that event type by it
     (the key rides a consumed arm naming the event). This keeps `orderId` indexed
     (own composite read) and an M:N capacity read indexed *without* a hand
     annotation, while still dropping `categoryId` from `ProductAdded` (nobody reads
     `ProductAdded` by `categoryId`). 19 unit tests pin all of this; full dcb suite
     157/157, zero warnings.

   **Not yet done (Phase 2):** switch the wiring to consume the inferred values.
   The gate shows the only behavioural delta is `ProductAdded` dropping `categoryId`
   — which is coupled to the example still carrying `@crossPartition` on the emitted
   `categoryId` *and* the `addedProductIds` sibling-leak workaround in
   `AddProduct_Behavior`. So the wiring switch and the `AddProduct` migration are
   one unit (Phase 2 ∪ Phase 4 for that slice), not independent steps.
2. **Emit derived scope** into the wiring. ✅ **Done.** `Dcb_Builder` threads
   `inferred.crossPartitionTagKeys` / `inferred.tagKeysByEventType` into the
   decision-query wiring (all-or-nothing per boundary: an ambiguous slice keeps the
   annotated values). The derived `tagKeysByEventType` is the sibling-leak fix.
   ✅ `DcbValidation.validateScopeVsInference` now validates remaining `@crossPartition`
   annotations against the derived scope: a key marked cross-partition that inference
   resolves as the slice's *own* partition is a **contradiction** (`warn`); a key
   inference already derives as cross-partition is **redundant** (`info`, safe to
   delete). Wired into `Dcb_Builder`; 3 unit tests. The original cross-producer
   `validateCrossPartitionScope` stays for the annotated/ambiguous fallback path.
2c. **End-to-end verified.** ✅ `reventless-local`'s
   `DcbCrossPartitionReadTest` builds an AddProduct StateChangeSlice over the real
   in-memory `DcbEventLog`, threaded with the inferred scope. With a sibling product
   preseeded in the same category, the decision read resolves to
   `ProductAdded{productId=p2} OR CategoryAdded{categoryId=cat1}` and returns
   `[CategoryAdded(cat1)]` only — the sibling `ProductAdded(p1)` is **not** read — so
   p2 is added; re-adding an existing product is still rejected via its own
   partition-scoped clause. This closes the gap that nothing exercised the threaded
   storage read (the GWT harness folds events raw).
3. **Harness parity** — ✅ **Done (read path).** `Behavior_GWT` / `Flow_GWT` derive
   `crossPartitionTagKeys` as `extractCrossPartitionTagKeys ∪
   DcbScopeInference.crossPartitionForSlice` and thread `infer([shape])`'s
   `tagKeysByEventType`. Backward-compatible (annotations still honoured), so all 5
   example plugins + reventless-gwt stay green. This is what lets the reachability
   guard pass after `@crossPartition` is removed.
4. **Migrate the examples** — ⚙️ **Partial (hybrid catalog).** Stripped **all
   `@crossPartition`** from `online-shop-hybrid` catalog (AddProduct + the three
   Category slices) and removed the `addedProductIds` sibling-leak workaround in
   `AddProduct_Behavior` (now a plain `exists` flag); updated the AddProduct GWT to
   the production-accurate history. End state verified: zero `@crossPartition`
   remaining, inference derives `["categoryId"]`, `ProductAdded` indexes
   `["productId"]` only, no ambiguities, all tests green.
   *Still annotated:* `@partitionTag` remains on `ProductAdded` / `RecordProductDemand`
   — the **write-side** `derivePartitionTag` / `extractTaggedFields` (storage
   partition + GSI list) still read schema metadata, and the PPX auto-tags every
   `*Id`, so removing `@partitionTag` needs the write-side inference phase (below).
   The dcb example has no `@crossPartition` to strip.
4b. **Write-side inference.** ⚙️ **Part A done; Part B deferred.** (Earlier called
   "PPX-republish-gated" — that was wrong; the write path is all runtime.)
   - ✅ **Part A — per-event-type write-tag filtering (runtime-only).**
     `StateChangeSlice_Callback.encodeEvent` now filters the extracted tags by the
     threaded `tagKeysByEventType` (the effective inferred-or-annotated map), so a
     produced event only carries its *indexed* keys. `categoryId` on `ProductAdded`
     is dropped on write ⇒ the event is **never written to the `tag_categoryId` GSI**
     ⇒ the sibling leak is now impossible at the storage level, not just narrowed
     away at read time. Auto-respects the ambiguity guard (annotated map ⇒ no-op).
     Proven by `DcbCrossPartitionReadTest`: a slice-produced product is queryable by
     `productId` but not by `categoryId`. Full blast radius green (local 419, core
     471, all examples).
   - ⬜ **Part B — drop `@partitionTag`.** Blocked on `derivePartitionTag`, which
     reads `@partitionTag` metadata to pick the **single global storage partition key**
     of a multi-entity DcbEventLog (e.g. `productId` for the catalog). Removing the
     annotation means inferring that global key — a **DynamoDB main-PK** decision
     (`DcbEventLogStorage_DynamoDb_Runtime.derivePartitionKey`) that local storage
     ignores and that I can't validate without a real DynamoDB deploy. Defer until it
     can be validated there; `@partitionTag` stays meanwhile (a small, honest
     annotation — the leak is already fixed read- and write-side without it).
5. **Docs** — ✅ **Done (developer-facing + internals).** Rewrote the tag guidance to
   the new model: cross-entity *reference* reads are inferred (no annotation);
   `@crossPartition` is reserved for **M:N capacity**; `@partitionTag` is still
   required on multi-`*Id` events (write-side partition not yet inferred). Updated
   `docs-app/dcb-usage.md` (new "Cross-entity reference reads (inferred)" section +
   reframed `@crossPartition`), `docs-app/reventless-ppx.md` (the `@crossPartition`
   reference + table), `.claude/rules/app-developer.md` (the PPX-annotation rule —
   this is where the reference lives, *not* CLAUDE.md), and
   `docs-framework/internals/dcb-consistency-checks.md` (the `PlaceOrder`
   counterexample — now correctly handled by inference, see below).

   **Correction surfaced by the docs pass (committed separately):** writing the
   `PlaceOrder` counterexample revealed the inference was **over-eager** — it marked
   *array* foreign references (`productIds`) cross-partition, contradicting that
   plugin's deliberate partition-scoped design and silently changing the dcb-ordering
   storage read path (untestable locally). Fixed: a foreign reference is inferred
   cross-partition **only when the command carries it as a scalar** (scalars must be
   fanned; arrays auto-fan partition-scoped). Rule 2 now gates on `commandScalarKeys`.
   This corrects a latent regression from the Phase 2 threading commit.

---

## Open questions / risks

- **Ownership ambiguity.** A slice whose command carries two keys both owned by
  *other* entities (a pure join with no own entity) has no inferable partition.
  Detect and require an explicit `@partitionTag`; don't guess.
- **A key owned by no slice** (referenced but never produced in-plugin — e.g. an
  external id) — treat as payload unless consumed as a read key, then it's a
  dangling cross-partition read; surface as a generator error (the referenced
  entity isn't in this plugin).
- **Distinguishing "reference exists" from "M:N capacity".** Both read a foreign
  key; rule 3 marks the emitted-event key payload for the former and the dev opts
  into indexing for the latter. Verify the rule's default (payload) is the safe one
  and the capacity case is rare enough to justify an explicit opt-in.
- **Migration blast radius.** Inference must produce byte-identical wiring to the
  current annotations for every existing slice before the examples are stripped
  (Phase 1's zero-diff gate).
- **Fence scope.** `crossPartition` also drives the optimistic-concurrency fence
  (see `dcb-fence-scope-alignment.md`); inferred scope must feed the fence
  identically. Cross-check with that plan.

---

## Definition of done

- `online-shop-hybrid`'s `AddProduct` + Category slices compile and pass (unit +
  flow) with **no** `@partitionTag` / `@crossPartition` / `@noTag` anywhere, and no
  sibling-leak workaround in the behavior.
- The generator emits the same `crossPartitionTagKeys` / `tagKeysByEventType` it
  does today for every example (zero behavioural diff), now derived rather than
  annotated.
- Escape-hatch annotations still work and override inference; a contradicting
  annotation is a clear generator error.
- The reachability guard still reds a deliberately-broken cross-entity read.
