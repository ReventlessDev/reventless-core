# Sury 11.0.0-alpha.5 — reverse-decoder crash on nested optional + sibling variant union

**File at:** <https://github.com/DZakh/sury/issues/new>

---

## Title

`TypeError: val.p.a is not a function` in reverse-decoder when an outer Object has a nested Object with an optional field alongside a sibling variant union

## Body

### Summary

In sury `11.0.0-alpha.5`, building a reverse decoder for an outer Object schema that contains **both**

1. a **nested** Object field whose schema has at least one `S.option(...)` field, **and**
2. a peer field that is a `S.union([...])` of record-payload variants (the sury-ppx shape, i.e. each variant is `S.schema(s => ({ TAG: "X", ... }))`),

crashes during decoder *compilation* (before any data flows through) with:

```
TypeError: val.p.a is not a function
    at Object._notVarAtParent (sury/src/Sury.res.mjs:462:9)
    at val.v (sury/src/Sury.res.mjs:871:15)
    at Object._bondVar (sury/src/Sury.res.mjs:435:15)
    at val.v (sury/src/Sury.res.mjs:734:15)
    at val.v (sury/src/Sury.res.mjs:871:15)
    at val.v (sury/src/Sury.res.mjs:871:15)
    at Object._bondVar (sury/src/Sury.res.mjs:435:15)
    at val.v (sury/src/Sury.res.mjs:734:15)
    at merge (sury/src/Sury.res.mjs:679:48)
    at Schema.unionDecoder [as decoder] (sury/src/Sury.res.mjs:2633:31)
```

Either piece on its own reverses and decodes cleanly. The crash only fires when they are combined at the specific nesting shown below.

### Minimal repro — ReScript

```rescript
// SuryAlpha5BugRepro.res
//
// Deps: rescript@^12.2.0, sury@11.0.0-alpha.5, sury-ppx@11.0.0-alpha.2
// rescript.json: ppx-flags=["sury-ppx/bin"], dependencies=["sury"]
//
//   rescript build
//   node SuryAlpha5BugRepro.res.mjs

@schema
type nested = {opt?: string}

@schema
type variant =
  | A({x: string})
  | B({x: string})

@schema
type outer = {nested: nested, variant: variant}

let value: outer = {
  nested: {opt: "v"},
  variant: A({x: "hello"}),
}

external toUnknown: 'a => unknown = "%identity"

try {
  let json =
    toUnknown(value)->S.decodeOrThrow(~from=outerSchema->S.reverse, ~to=S.json)
  Console.log2("OK:", json->JSON.stringify)
} catch {
| err => Console.error2("FAILED:", err)
}
```

(`toUnknown` is needed because alpha.5's `S.reverse: t<'value> => t<unknown>` erases the value type, forcing the `decodeOrThrow` value-side to be `unknown` too.)

### Minimal repro — pure JS (no sury-ppx, same crash)

```js
// sury-repro.mjs
//
//   mkdir sury-bug && cd sury-bug
//   npm init -y >/dev/null
//   npm install sury@11.0.0-alpha.5
//   cp /path/to/sury-repro.mjs .
//   node sury-repro.mjs

import * as S from "sury/src/S.res.mjs";

const nestedSchema = S.schema(s => ({
  opt: s.m(S.option(S.string)),
}));

const variantSchema = S.union([
  S.schema(s => ({ TAG: "A", x: s.m(S.string) })),
  S.schema(s => ({ TAG: "B", x: s.m(S.string) })),
]);

const outerSchema = S.schema(s => ({
  nested: s.m(nestedSchema),
  variant: s.m(variantSchema),
}));

const value = {
  nested: { opt: "v" },
  variant: { TAG: "A", x: "hello" },
};

try {
  const out = S.decodeOrThrow(value, S.reverse(outerSchema), S.json);
  console.log("OK:", JSON.stringify(out));
} catch (err) {
  console.error("FAILED:");
  console.error(err && err.stack ? err.stack : err);
}
```

(The ReScript above compiles to exactly this schema construction, modulo the try/catch wrapper. The pure-JS form confirms the bug is in sury's runtime, not in sury-ppx's emission.)

### Expected

```
OK: {"nested":{"opt":"v"},"variant":{"TAG":"A","x":"hello"}}
```

### Actual

```
FAILED:
TypeError: val.p.a is not a function
    at Object._notVarAtParent (.../sury/src/Sury.res.mjs:462:9)
    ... [see full stack above]
    at Schema.unionDecoder [as decoder] (.../sury/src/Sury.res.mjs:2633:31)
```

### Each piece in isolation works

- Remove `opt?: string` from `nested` (so `nested` has no optional field) → works.
- Flatten `opt` directly onto `outer` (no nested object) → works.
- Replace `variant` with a non-union schema, or with a union of payload-less literals → works.
- Forward parse (`S.parseOrThrow(value, ~to=outerSchema)`, JSON → typed) → works.

So the crash specifically needs **(optional field inside a nested object) AND (sibling field that is a record-payload variant union)** combined under one outer schema.

### Environment

| | |
|---|---|
| sury | `11.0.0-alpha.5` |
| sury-ppx | `11.0.0-alpha.2` (ReScript form only) |
| ReScript | `12.2.0` |
| Node | `v22.17.1` |
| OS | macOS (darwin 25.4.0) |

### Why it matters

This is the only encode-to-JSON path alpha.5 exposes: alpha.4's `S.reverseConvertToJsonOrThrow` and the rest of the alpha.4 encode helpers were removed, so user code that previously did `value->S.reverseConvertToJsonOrThrow(schema)` now has to call `S.decodeOrThrow(value, ~from=schema->S.reverse, ~to=S.json)`. Any schema matching the trigger shape — common in message envelopes that pair a metadata sub-record (with optional headers / user / etc.) with a domain event/command union — cannot be encoded back to JSON.
