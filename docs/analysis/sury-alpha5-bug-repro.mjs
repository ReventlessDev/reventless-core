// Minimal repro for a sury 11.0.0-alpha.5 reverse-decoder crash.
//
// Setup (anywhere on disk):
//   mkdir sury-bug && cd sury-bug
//   npm init -y >/dev/null
//   npm install sury@11.0.0-alpha.5
//   cp /path/to/this/file ./sury-repro.mjs
//   node sury-repro.mjs

import * as S from "sury/src/S.res.mjs";

// Crash trigger: an outer Object that contains a nested Object with an
// optional field, alongside a union of record-payload variants.
//
//   outer = { nested: { opt?: string }, variant: A | B }
//
// Either piece alone reverses cleanly. Combined at this nesting,
// `S.reverse` builds but `S.decodeOrThrow` against the reversed schema
// crashes at decoder compilation:
//   TypeError: val.p.a is not a function
//     at Object._notVarAtParent (sury/src/Sury.res.mjs:462:9)
//     ...
//     at Schema.unionDecoder [as decoder] (sury/src/Sury.res.mjs:2633:31)

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
