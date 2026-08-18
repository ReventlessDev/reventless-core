<!--
RESOLVED — kept as the internal writeup; nothing left to post.

Upstream #311 ("Nullable option field fails to encode nested `None` as JSON `null`")
is CLOSED, and the behaviour we needed is FIXED in sury 11.0.0-alpha.11: a nested
`None` optional is omitted on encode again, matching alpha.4's
`reverseConvertToJsonOrThrow`.

Which of the two reproductions below was actually the blocker, established by
running both against alpha.10 and alpha.11 on 2026-07-28:

  • the `@s.nullable` form (#311 as originally filed) — already passed on alpha.10,
    encoding `{a: Some({s: None})}` to `{"a":{"s":null}}`. Presumably carried by the
    #284 fix. It was never what blocked us.
  • the plain-`option` form (the variant we contributed) — the real blocker. On
    alpha.10 it throws `Expected undefined | JSON, received { a: { name: "x";
    counter: undefined; }; }`; on alpha.11 it encodes to `{"items":{"a":{"name":"x"}}}`.

The three `ResolvedOutputsTest` cases this blocked are un-skipped and passing.

Related: #284, the reverse/parse-direction dual of this, reported by us and fixed in
11.0.0-alpha.10 — see ./sury-alpha8-nullasoption-reverse-bug.md.

The original report text is preserved below as the record of what was wrong.
-->

# Title

Encoding to JSON rejects a nested `None` optional field (`undefined`) that alpha.4 used to omit — regression, and the encode-side dual of #284

# Body

> **Related issues.** This is the **encode-direction** counterpart of #284
> (*"`nullAsOption` field inside a variant fails to round-trip when nested in
> array/object"*), which we reported and which is **fixed in 11.0.0-alpha.10**.
> It also looks like the same root cause as the currently-open **#311**
> (*"Nullable option field fails to encode nested `None` as JSON `null`"*) — same
> error signature. Filing this as a companion in case the plain-`option` variant
> and the alpha.4 regression framing are useful; happy to fold it into #311.

## Summary

Encoding a value to JSON with `value->S.decodeOrThrow(~from=schema, ~to=S.json)`
throws when the value contains an **optional field that is `None`** (so it
serialises to `undefined`) nested inside an enclosing field (a `dict<record>`,
or an optional record field). Sury's jsonable validation rejects the `undefined`:

```
Failed at ["a"]: Expected undefined | JSON, received { s: undefined; }
  - At ["a"]["s"]: Expected JSON, received undefined
```

At the **top level**, an omitted optional field is simply absent from the output
object and encodes fine. The failure appears only when the `undefined` is nested
inside a *present* enclosing value that is validated against a `JSON` target.

**Regression:** alpha.4's `reverseConvertToJsonOrThrow` tolerated this — it
**omitted** `undefined` optional fields from the produced JSON. alpha.10 exposes
no tolerant encode path (`decodeOrThrow(~to=S.json)` is the only encode-to-JSON
route in the ReScript API), so the same shape that serialised fine on alpha.4
now throws.

## Minimal reproduction

Plain `option` fields (what our code uses — `None` is meant to be omitted):

```rescript
@schema type inner = {name: string, counter?: string}
@schema type outer = {items?: dict<inner>}

// `counter` omitted -> encoded `inner` carries `counter: undefined`
let value: outer = {items: Dict.fromArray([("a", {name: "x"})])}

let _ = value->S.decodeOrThrow(~from=outerSchema, ~to=S.json)
// THROWS: Failed at ["items"]: Expected undefined | JSON,
//         received { a: { name: "x"; counter: undefined } }
```

The `@s.nullable` variant (per #311) fails the same way — nullable does not turn
the nested `None` into `null` on encode at depth:

```rescript
@schema type a = {s: @s.nullable option<string>}
@schema type b = {a: @s.nullable option<a>}
let _ = S.decodeOrThrow({a: Some({s: None})}, ~from=bSchema, ~to=S.jsonString)
// THROWS: Failed at ["a"]: Expected undefined | JSON, received { s: undefined; }
```

## Why it matters (and why the obvious workaround is blocked)

These fields model forward-compatible cross-stack export shapes: `?`-optional so
that older producers lacking a field still **decode**. Two candidate fixes both
fail:

- Add `@s.nullable`/`S.nullAsOption` so `None` encodes to `null` (jsonable) —
  but (a) per #311 nullable still emits `undefined` at depth on encode, and
  (b) `nullAsOption` is *present-required on decode*, which breaks the
  forward-compat these optional markers exist for.
- Keep plain `option` — forward-compatible on decode, but hits this
  `undefined`-not-jsonable wall on encode.

A tolerant encode that **omits** `undefined` optional fields when targeting JSON
(as alpha.4 did) would resolve this without the decode-compat tradeoff.

## Environment

- `sury@11.0.0-alpha.10`, matching `sury-ppx`, `rescript@12.3.0`, Node 22.17.1.
