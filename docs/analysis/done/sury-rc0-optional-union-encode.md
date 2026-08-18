<!--
Filed upstream as DZakh/sury#347 — https://github.com/DZakh/sury/issues/347
The Body below is what was posted; keep the two in sync if either changes.
Companion analysis: this file also serves as the internal writeup.

STATUS: RESOLVED on our side 2026-08-05 by the maintainer's answer on #347 — the
in-union-optionality workaround below is GONE from the tree. The issue itself is
still open upstream ("I'll improve the case"), but nothing here blocks us and
there is no workaround left to revisit. See "Resolution" at the end of this file
for what replaced it and for the second, unrelated defect the same change fixed.

The reply at the end of this file was POSTED to #347 on 2026-08-05. Its second
finding — `S.jsonString` failing on a *present* declared-union value — is offered
there as possibly out of scope for #347 and has not been filed separately.

FILED 2026-08-04 as #347. Found the same day moving this repo from alpha.11 to
rc.0.

The Body is deliberately domain-neutral so it could be posted as-is. Where it bit
us here: `Offload.optionSchema` in reventless-spec — an optional
`Offload.payload<'a>` field, whose union has one arm for the offloaded reference
form and one for the inline form. Every message with an absent offloadable field
failed to encode (18 tests, 4 suites). The workaround the Body describes is what
was in `reventless/spec/src/semantic/Offload.res` until the Resolution below.

Prior reports from us, all fixed:
  • #284 — nullAsOption reverse transform dropped at depth (fixed in alpha.10)
    ./sury-alpha8-nullasoption-reverse-bug.md
  • #311 — nested `None` optional rejected as non-jsonable on encode (fixed in alpha.11)
    ./sury-alpha10-undefined-optional-in-json.issue.md
  • optional + union leading with a literal (regressed in alpha.11, fixed in rc.0)
    ./sury-alpha11-optional-leading-literal-union.md
-->

# Title

Regression in 11.0.0-rc.0: encoding an absent optional field descends into its wrapped union's serializers with `undefined`

# Body

## Summary

On `11.0.0-rc.0`, encoding a record whose **optional** field holds a
`nullable`-wrapped **union of transforms** invokes the union members' serializers
with a raw `undefined` when the field is **absent**, instead of short-circuiting
to `null`. A serializer that inspects its payload then dereferences `undefined`:

```
TypeError: Cannot read properties of undefined (reading 'TAG')
```

This worked on `11.0.0-alpha.11`; it is a regression.

The failure is a raw `TypeError` rather than a `SuryError`, so it cannot be caught
as a schema error. It also fires on the *absent* case specifically — the value a
schema's tests are least likely to cover, and typically the most common one in
stored data.

## Minimal reproduction

```rescript
@schema
type inner = {name: string}

type payload =
  | Tagged(string)
  | Plain(inner)

let sentinel = "$ref"

// A union of two transforms, each rejecting the other's values.
let taggedArm = S.json->S.transform(s => {
  parser: json =>
    switch json
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get(sentinel))
    ->Option.flatMap(JSON.Decode.string) {
    | Some(r) => Tagged(r)
    | None => s.fail("not tagged")
    },
  serializer: p =>
    switch p {
    | Tagged(r) => Dict.fromArray([(sentinel, JSON.Encode.string(r))])->JSON.Encode.object
    | Plain(_) => s.fail("not tagged")
    },
})

let plainArm = innerSchema->S.transform(s => {
  parser: v => Plain(v),
  serializer: p =>
    switch p {
    | Plain(v) => v
    | Tagged(_) => s.fail("not plain")
    },
})

let field = S.nullAsOption(S.union([taggedArm, plainArm]))

@schema
type record = {f: @s.matches(field) option<payload>}

({f: None}: record)->S.decodeOrThrow(~from=recordSchema, ~to=S.json)
// alpha.11 -> {"f":null}
// rc.0     -> TypeError: Cannot read properties of undefined (reading 'TAG')
```

## What does and does not trigger it

Same schema, three values, encoded to `S.json`:

| value                    | alpha.11        | rc.0      |
| ------------------------ | --------------- | --------- |
| `{f: None}`              | pass `{"f":null}` | **crash** |
| `{f: Some(Tagged(…))}`   | pass            | pass      |
| `{f: Some(Plain(…))}`    | pass            | pass      |

The JS `nullable` wrapper (exported as `nullable` in rc.0, `js_nullable` in
alpha.11) fails on rc.0 in exactly the same way, so the choice of wrapper is not
the cause — `nullAsOption` is used above only because its binding name is stable
across both versions, which keeps the two runs comparing the same construction.

The same union in a **required** field is fine. The trigger is the combination:
**optional field + wrapped union + at least one arm whose serializer inspects its
payload**.

An arm whose serializer ignores its argument will not crash, but it is then
selected for a value that is not present — so the underlying problem (the absent
case reaching the arms at all) is the same either way.

## Why this shape is common

A union of mutually-rejecting transforms is the idiomatic way to express an
**untagged** either-or codec: a field that may hold one of two representations,
where neither is wrapped in a discriminator because the encoded form has to stay
compatible with data written before the second representation existed. Making such
a field optional is then routine — and that combination is what breaks.

## Workaround

Build the optionality *into* the union instead of wrapping it, so the absent case
arrives as a value the arms can match rather than as a raw `undefined`. Every arm
takes `option<payload>`:

```rescript
let noneArm = S.literal(JSON.Null)->S.transform(s => {
  parser: _ => None,
  serializer: payload =>
    switch payload {
    | None => JSON.Null
    | Some(_) => s.fail("not an absent value")
    },
})
S.union([noneArm, taggedArm, plainArm])
```

Two details matter for this to be behaviour-preserving:

- The none-arm must be a genuine **null-typed** schema (`S.literal(JSON.Null)`),
  not a `json`-typed one that merely accepts null. Only a null-typed member makes
  the union advertise `has.null`. Schema walkers read that flag to decide an absent
  field means "no value"; without it, `has` comes out as `{unknown, object}` and a
  walker will instead resolve the field into the first object-typed member.
- The none-arm must encode to an explicit `null` rather than an omitted key, or the
  emitted JSON stops matching data already written.

## Environment

- `sury@11.0.0-rc.0` (works on `11.0.0-alpha.11`), matching `sury-ppx`,
  `rescript@12.3.0`, Node 22.17.1.

---

# Resolution (2026-08-05)

The maintainer's answer on #347:

> I'll improve the case, but for you here `S.shape` or `S.object` would be a
> better fit. And they wouldn't cause such an error.

That is the right read, and it retires the workaround above rather than merely
sidestepping it. **A hand-written `S.transform` arm is opaque to sury**: it cannot
know what the arm accepts, so it must offer every value to the arm's own
serializer and let it reject. A *declared* arm — `S.object` for the reference
form, `S.shape` for the inline form — gives sury the shape, so it discriminates on
structure and never runs user code to find out.

Both arms of the offload codec are now declarative:

```rescript
let offloadedArm = S.object(s => Offloaded(s.field(sentinelKey, offloadedRefSchema)))
let inlineArm = inner->S.shape(value => Inline(value))
S.union([offloadedArm, inlineArm])
```

and `optionSchema` is back to the simple wrapped form,
`S.nullAsOption(schema(inner))`.

## It fixed a second defect we had not found

Measured across all three constructions on rc.0 — the workaround, the original
wrapped-transforms form, and the declarative form:

| encode                       | wrapped transforms | in-union optionality (workaround) | declared arms |
| ---------------------------- | ------------------ | --------------------------------- | ------------- |
| absent → `toJson`            | **TypeError**      | `null`                            | `null`        |
| absent → `toJsonString`      | **TypeError**      | `null`                            | `null`        |
| inline → either              | ok                 | ok                                | ok            |
| offloaded → `toJson`         | ok                 | ok                                | ok            |
| offloaded → `toJsonString`   | **throws**         | **throws**                        | ok            |

The bottom row is a **separate bug that the workaround did not address and no test
covered**: a `json`-typed union arm cannot chain into a non-JSON target, so an
offloaded value encoded to `S.jsonString` fails while the same value encoded to
`S.json` succeeds (*"Expected JSON string, received {$offload: …}"*). It was latent
rather than live — the only `toJsonString` call sites on this path
(`Offload.prepare`, `Plugin_Builder`'s deploy-time offload) pass the *inner value's*
schema, not the codec — but it would have surfaced the first time a message
carrying an offloaded field was serialized to a string.

Half-measures do not work: leaving *one* arm as a transform (declarative inline
arm, json-transform reference arm) reproduces both failures exactly. Every arm has
to be declared.

## The change that had to come with it

Declaring the reference arm makes it **object-typed**, where the json-transform arm
was typed `unknown` — and `Message.fillMissingDefaults` resolved a plain object
value in an `anyOf` to the *first object-typed member*. So a legacy inline payload
missing a later-added field healed against the reference member instead:

```
{"f":{"name":"legacy"}}
  → {"f":{"name":"legacy","$offload":{"store":"","key":"","hash":"","bytes":0}}}
  → Offloaded({store: "", key: "", ...})
```

which then **decodes cleanly** — silent corruption of replayed history, not an
error. The walker now picks the object member that declares the most of the
value's own keys, ties keeping the earliest (the declared preference order, i.e.
the previous behaviour whenever scoring cannot distinguish). An inline payload
heals as `Inline`, a sentinel-keyed one as `Offloaded`. This was a latent
fragility in the walker for *any* union of two object shapes; the offload codec is
just the first union to have two.

Guarded by `Offload optional field:` and `Offload healing on replay:` in
`reventless/spec/tests/OffloadTest.res`.

## What this says for the next sury bump

The two failures here and the two before them (`HeartbeatEntryPoint.mjs`,
`DcbCommandTopicEntryPoint.mjs`) share a shape: **the compiler cannot see it**.
Add to the bump checklist — alongside grepping `%raw` and hand-written `.mjs` for
schema-shape literals — that a codec built from `S.transform` arms is the same
kind of blind spot, and prefer `S.object`/`S.shape` wherever the shape can be
declared.

---

# Reply posted on #347

<!--
Posted 2026-08-05 as a comment on https://github.com/DZakh/sury/issues/347.
Kept here verbatim; keep the two in sync if either changes.
-->

Thanks — that was the right call, and it removed more than it was aimed at. Both
arms are now declared and the workaround is gone:

```rescript
let taggedArm = S.object(s => Tagged(s.field(sentinel, refSchema)))
let plainArm = innerSchema->S.shape(v => Plain(v))
S.union([taggedArm, plainArm])
// and the field back to the simple wrapped form:
S.nullAsOption(...)
```

Two things I measured on the way that may be useful for the improvement you have
in mind.

**A json-typed arm also can't chain into a non-JSON target.** Same union, encoding
a *present* value:

| encode                          | transform arms | declared arms |
| ------------------------------- | -------------- | ------------- |
| absent → `S.json`               | **TypeError**  | `null`        |
| absent → `S.jsonString`         | **TypeError**  | `null`        |
| `Tagged(…)` → `S.json`          | ok             | ok            |
| `Tagged(…)` → `S.jsonString`    | **throws**     | ok            |
| `Plain(…)` → either             | ok             | ok            |

The `S.jsonString` row is a separate failure from the one I filed — it fires on a
*present* value, and it is a catchable `SuryError`, not a `TypeError`:

```
Expected unknown | unknown | unknown, received { TAG: "Tagged"; _0: {…} }
- Expected JSON string, received { $ref: {…} }
```

So a `S.json->S.transform(…)` arm encodes correctly to `S.json` and fails to
`S.jsonString`. I don't know whether you consider that in scope for #347 or a
separate thing — happy to file it separately if it is useful.

**Mixing the two doesn't work.** Declaring only the inline arm and leaving the
sentinel arm as a `S.json->S.transform` reproduces *both* failures unchanged. It
seems to need every arm declared, which is worth knowing for anyone reading this
issue for a workaround.

One consequence worth flagging for others, not a sury issue: a declared arm is
`type: "object"` where a json transform was `type: "unknown"`, so it becomes
visible to schema walkers that were previously blind to it. Our
schema-migration-on-read walker resolved an object value in an `anyOf` to the
first object-typed member, which after this change was the reference arm — an
older inline payload healed into a reference with an empty key and then decoded
cleanly. Better introspectability, but it does change what walkers see.

No rush on the fix from our side — the declared form is the better expression
anyway and we're not carrying a workaround for it any more.
