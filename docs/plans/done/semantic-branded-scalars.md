# Plan: semantic branded scalars — `Email`, `Url`, `Phone`, `Percent`, `Color`, `Bytes`, `Duration`

**Date:** 2026-07-30
**Status:** Complete. All four steps done; two decisions changed on contact with the code and are
recorded in place below (`Bytes` is `float`, not `int`; `Url` allowlists `http`/`https`). Step 4's
`Percent` half had no target — see the note there.
**Repos:** `reventless-core` **only** — see *Why this needs no UI work*, which is not what the
analysis's phasing assumed.
**Analysis:** `autoui-semantic-types.md` §4.3, §5.7, §12 step 3, §16 (in the repo that owns the
cross-repo semantic-type analysis).
**Builds on:** [semantic-type-marker-and-storage-ref.md](./semantic-type-marker-and-storage-ref.md)
— `Semantic.mark` and `StorageRef` are the mechanism and the template; this plan adds vocabulary to
both, and no new machinery.

## Why these seven, and why now

They are the **only** part of the remaining semantic-type library that is safe against a log you
must keep. A branded scalar stays a JSON string or number on the wire and `Semantic.mark` adds a
schema annotation, not a shape — so stored events decode unchanged. The composites (`Money`,
`DateRange`, `GeoPoint`) turn a scalar field into an object, which is the *structural breaking*
category: an upcaster plus a full projection rebuild, against a pipeline that does not exist yet.

That is a better reason to do the scalars first than "they are cheap," and it means this plan has no
dependency on schema-versioning work of any kind.

Four of the seven — `Percent`, `Bytes`, `Duration`, `Color` — have **no name heuristic at all**
today, so they arrive only via an explicit annotation or a deployment hint. For those, a type is not
an upgrade over guessing; it is the first reliable signal there has ever been.

## Why this needs no UI work

The analysis files this as "core (+ui)". Checked against the UI's vocabulary, the `(+ui)` is
unnecessary: `AutoSemantics` already parses `"email"`, `"phone"`, `"url"`, `"percent"`, `"bytes"`,
`"duration"` and `"color"` from the wire, and their renderers already exist — they were built for
the string-annotation path.

This is the marker convergence paying out exactly as designed. The type path emits the *same*
`x-reventless-semantic` key with the *same* vocabulary ids, so a typed field is indistinguishable
from an annotated one at the wire, except that it also carries
`x-reventless-semantic-source: "type"` and therefore outranks an annotation on the provenance ladder.

**Verify this before writing code, not after** — it is the plan's central assumption and it is cheap
to confirm: mark one field, deploy nothing, and check the emitted JSON Schema carries the id the UI
already parses.

**Confirmed, and it held.** All seven ids parse on the consumer side, and every renderer exists. The
emitted shape for the annotated read-model field is exactly:

```json
{ "type": "string", "x-reventless-semantic": "email", "x-reventless-semantic-source": "type" }
```

The unit decisions in D3 were checked against the renderers rather than argued: the gauge does bound
Percent at 0–100, `formatBytes` is 1024-based, and `formatDuration` reads seconds.

## Decisions

### D1. Transparent `type t = string`, attached with `@s.matches` — not a sealed type

The analysis (§5.7) recommends leaning strong: "abstract + factory for the branded scalars." That is
**not implementable via the mechanism these types use**, and the constraint is already documented at
`StorageRef.t`: `@s.matches` requires the schema's type to match the field's, so a sealed type is
unattachable that way. `StorageRef` is transparent for exactly this reason.

The codebase does carry a sealed pattern — `Id.T` with `@schema type t`, used as a field's *declared*
type rather than as a refinement on `string`. It is a real option, and it is a bigger change than it
sounds: the field's ReScript type changes, so every construction site, every GWT fixture and every
boundary conversion moves with it. That is a per-field judgement, not a library-wide default, and
§13's over-typing caution argues against making it one.

**So: transparent now, and the sealed form stays available per field via the `Id.String` /
`Id.StringPure` precedent if a specific field earns it.** Transparent is additionally *source*-neutral
as well as wire-neutral — an existing `email: string` field gains a matcher and nothing else — which
is what makes adoption incremental instead of a migration.

### D2. No PPX shorthands

`@storageRef("productImages")` earned a PPX pass because it carries an **argument** — the store name
— and no plain sury expression can express "this store" at the field. None of these seven carry
anything: `@s.matches(Email.schema)` is already the whole declaration.

Seven new PPX passes would be seven new `.ml` files on a binary that ships on its **own release
train** — a bump that has to be verified by inspecting the artifact rather than the version number,
which has already caught this program out once. That is a poor trade for saving nine characters.

Revisit only if authoring friction turns out to be real, and then as one decision for all seven.

### D3. Units, settled here rather than at the call site

The three numeric types have a unit question, and it is the same class of question that made `Money`
structural: a number whose unit is a convention is a number that cannot be read.

| Type | Representation | Why |
|---|---|---|
| `Percent` | `float`, **0–100** | Not 0–1. Settled empirically: `AutoDashboard` already gauges a Percent field with `{min: 0.0, max: 100.0}`, so 0–1 would render every value as ~0. Matching the existing renderer costs nothing; disagreeing with it is a silent visual bug. |
| `Bytes` | ~~`int`~~ **`float`**, whole and non-negative | A byte count is discrete and cannot be negative — but `int` is the wrong type to get that from. **Corrected during implementation:** ReScript's `int` is int32 and sury enforces it, so an `int` byte count caps at 2,147,483,647 — under 2 GiB. The original rationale had this backwards; int32 truncates far *below* 2^53, not above it. `float` is exact to 2^53 (9 PB) and the discreteness is recovered by checking it. Wire-identical either way — both are JSON numbers — so this is a source choice, not a format one. |
| `Duration` | `int`, **seconds** | Deliberately a scalar, **not** `{value, unit}`. A `{value, unit}` record is an object — which would make `Duration` a structural-breaking change and move it out of this plan into composite territory. If a richer duration is wanted later it is a *new* type, not a widening of this one. |

`Email` and `Url` use sury's built-in `S.email` / `S.url`. `Phone` is E.164 (`+` then 1–15 digits) and
`Color` is a hex string — both need a pattern, since sury has neither.

### D4. `Url` allowlists `http`/`https` on top of `S.url` — added during implementation

`S.url` is `new URL()`, which accepts every scheme, `javascript:alert(1)` included. The UI renders a
field with this semantic as an anchor whose `href` is the stored value, so "parseable URL" alone
would make this type a way to write a permanent stored XSS into an append-only log — the same hole
`StorageRef` exists to close, arriving through a different field. The grammar is therefore sury's
parse *plus* a two-scheme allowlist.

`mailto:` and `tel:` fall outside it deliberately: those are `Email` and `Phone`, which validate what
they actually hold. `Color` gets the same treatment for the same reason — the swatch sets the value
as a CSS `background`, where `url(…)` is legal CSS, so hex-only is a boundary, not a notation
preference.

## Steps

### 1. Add the seven ids to `Semantic.Id`

Vocabulary only. They must be byte-identical to the strings `AutoSemantics` parses, because the whole
point is that the type path and the annotation path converge on one wire format.

**Verify:** a test asserting each new id against the literal wire string. Cheap, and it is the
contract with a consumer in another repo that cannot be type-checked from here.

### 2. One module per type in `reventless/spec/src/semantic/`

Following `StorageRef` exactly, minus the payload — these are all `Plain`:

```rescript
type t = string                       // transparent; see D1
external unsafe: string => t = "%identity"
external toString: t => string = "%identity"
let fromString: string => result<t, string>   // the single definition of the grammar
let schema: S.t<t>                    // derived from fromString, marked with the id
```

The rule `StorageRef` establishes and this plan inherits: **the schema derives from `fromString`**,
never a second hand-rolled check. One grammar, one place, no drift.

Error strings say what was wrong and show the offending value — `validateInput` surfaces them in
forms, so they are user-facing text, not developer text.

**Verify:** per type, a valid value, an invalid value with a readable reason, and — for the numeric
three — the boundary cases the unit decision implies (`Percent` accepts 100 and rejects 101;
`Bytes` rejects negatives).

### 3. Confirm the emitted wire shape, once

For one string type and one numeric type, assert the generated JSON Schema carries
`x-reventless-semantic` with the expected id **and** that the underlying `type` is still `string` /
`number`. That second half is the non-breaking claim this whole plan rests on, and it deserves a test
rather than an argument.

### 4. Annotate the example, narrowly

Enough to prove the path end to end and no more — one `Email` and one `Percent` on fields that
already exist as `string`/`float`. Do not sweep the tree: §13's over-typing caution applies, and a
broad retrofit belongs to the later wave that deprecates the string annotation.

**Verify:** the annotated fields' schemas carry the ids; existing tests pass untouched, which is the
acceptance criterion — the same one the marker work used, and for the same reason.

**Done for `Email`; `Percent` had no target.** The `Customer` aggregate's two email-bearing command
variants and the `Customers` read-model field are marked, and both emit the id end to end. The
events are deliberately left as plain `string`: a command is where a value is *accepted*, an event is
a record of what already was, and re-validating history on read is the risk this plan avoids.

There is no percentage field anywhere in the examples — every `float` is a price or a coordinate — so
the `Percent` half would have meant *adding* a field, which is a domain change wearing a
demonstration's clothes. The numeric path is covered instead by step 3, which asserts the same two
facts (`type: "number"`, `x-reventless-semantic: "percent"`) on a Percent-marked field. That is the
evidence step 4 would have produced.

One follow-on: two GWT literals read `"x@y"`, which the type now rejects. They pass regardless — the
GWT DSL builds commands in-process and never parses through the schema, so the refinement bites at
the transport boundary, not in behaviour tests. They were corrected anyway, because an invalid
literal sitting beside a type that forbids it is a trap for the next reader. Worth knowing generally:
**GWT tests give no coverage of these refinements.**

## What this deliberately does not do

- **No composites.** `Money`, `DateRange` and `GeoPoint` are structural-breaking and blocked on
  upcasting or on a wipeable deployment. Different plan, different risk.
- **No `@semantic` deprecation.** The string path keeps working; retiring it is a later wave and
  needs the whole library present first.
- **No capability wiring.** Types feeding `isCapable` is a separate step, and none of these seven
  unlock a high-level component on their own.
- **No sealed types.** Available per field, chosen per field, not decided here.

## Risks

| Risk | Mitigation |
|---|---|
| **A vocabulary id does not match what the consumer parses**, so a typed field silently renders as a plain box — the exact failure the string path already has. | Step 1's literal assertion. A cross-repo string contract that nothing type-checks needs a test on both sides; this is the side that can have one. |
| **`Percent` ships as 0–1** because it is the more common convention in libraries. | Settled in D3 from the existing renderer's own bounds, not from convention. The symptom would be every gauge reading zero, which is visible but easy to attribute to the wrong layer. |
| **`Duration` grows into `{value, unit}` later**, turning a non-breaking type into a breaking one after fields already use it. | D3 forecloses it: a richer duration is a new type. Widening this one would retroactively convert shipped fields into an upcaster obligation. |
| **Over-typing** — a sweep converts every string field and adds friction without value. | Step 4 is deliberately narrow. Semantic types stay opt-in; the heuristic fallback means an untyped `email` field still renders fine. |
| **Core's own unit tests do not run in its default suite.** | Run `jest --selectProjects reventless-core` when judging this change; a green default suite is not evidence. |
| **A refinement rejects a value only at the transport boundary**, so a green GWT suite says nothing about whether a field's real inputs are acceptable to its new type. Found while doing step 4: two GWT literals the type rejects passed anyway. | The grammars are tested directly in `SemanticScalarsTest`, which is where that coverage lives. When retrofitting a *live* field, check the values actually in the log — `Email` and `Phone` are the two most likely to reject production data, and `Phone` will reject any number not already normalised to E.164. |
