# Sury alpha.5 bug — follow-up to maintainer's question

Companion to [sury-alpha5-bug-report.md](./sury-alpha5-bug-report.md).

## Maintainer's question

> What if you try `S.decodeOrThrow(value, ~from=schema, ~to=S.json)` without `S.reverse`? This will have the same behavior as `reverseConvertToJsonOrThrow`.

## Answer

No — the suggestion does **not** work around the bug. Both forms crash identically at decoder-compile time against a clean install of `sury@11.0.0-alpha.5`.

## Test

```js
// /tmp/sury-bug-test/repro.mjs
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

// Form 1: with S.reverse (original repro)
S.decodeOrThrow(value, S.reverse(outerSchema), S.json);

// Form 2: maintainer's suggestion
S.decodeOrThrow(value, outerSchema, S.json);
```

## Environment

- `sury@11.0.0-alpha.5` (verified in `node_modules/sury/package.json`)
- Node `v22.17.1`
- macOS (darwin 25.4.0)

## Result

Both forms throw the same `TypeError` with structurally identical stacks:

```
TypeError: val.p.a is not a function
    at Object._notVarAtParent (sury/src/Sury.res.mjs:579:9)
    at val.v (sury/src/Sury.res.mjs:989:15)
    at Object._bondVar (sury/src/Sury.res.mjs:552:15)
    at val.v (sury/src/Sury.res.mjs:852:15)
    at val.v (sury/src/Sury.res.mjs:989:15)
    at val.v (sury/src/Sury.res.mjs:989:15)
    at Object._bondVar (sury/src/Sury.res.mjs:552:15)
    at val.v (sury/src/Sury.res.mjs:852:15)
    at merge (sury/src/Sury.res.mjs:797:48)
    at Schema.unionDecoder [as decoder] (sury/src/Sury.res.mjs:2751:31)
```

(Line numbers differ slightly from the original bug report — same frames in the same order. Original report was likely taken against a pre-publish snapshot.)

## Interpretation

The `S.reverse` call in the original repro was just an explicit trigger. `~from=schema, ~to=S.json` lazily reaches the same reverse-compilation path. The bug lives in the reverse-decoder build for the (nested optional) + (sibling record-payload variant union) shape, not in the surface API choice. There is currently no alpha.5 encode-to-JSON path that avoids it for this schema shape.
