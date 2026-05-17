// Minimal repro for a sury 11.0.0-alpha.5 reverse-decoder crash.
//
// Drop into any ReScript v12 project that has these deps:
//   - "rescript": "^12.2.0"
//   - "sury": "11.0.0-alpha.5"
//   - "sury-ppx": "11.0.0-alpha.2"   (as a devDependency)
//
// and these rescript.json entries:
//   "ppx-flags": ["sury-ppx/bin"],
//   "dependencies": ["sury"]
//
// Then `rescript build` and `node SuryAlpha5BugRepro.res.mjs`.

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

// Crash trigger: any encode-to-JSON path through the outer schema.
// `S.reverse(outerSchema)` builds without error, but the resulting reverse
// schema crashes at decoder compilation:
//   TypeError: val.p.a is not a function
//     at Object._notVarAtParent (sury/src/Sury.res.mjs:462:9)
//     ...
//     at Schema.unionDecoder [as decoder] (sury/src/Sury.res.mjs:2633:31)
//
// Either piece on its own reverses cleanly:
//   - Remove `opt?: string` from `nested`            → works
//   - Flatten `opt` onto `outer` (no nested record) → works
//   - Replace `variant` with a non-union schema      → works
//   - Forward parse (`S.parseOrThrow`) on `outer`    → works

external toUnknown: 'a => unknown = "%identity"

try {
  let json =
    toUnknown(value)->S.decodeOrThrow(~from=outerSchema->S.reverse, ~to=S.json)
  Console.log2("OK:", json->JSON.stringify)
} catch {
| err => Console.error2("FAILED:", err)
}
