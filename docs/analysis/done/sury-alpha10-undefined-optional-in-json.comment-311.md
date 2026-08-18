<!--
OBSOLETE — never needed posting. Upstream #311 is closed and fixed in
sury 11.0.0-alpha.11 (verified 2026-07-28). Kept only as the record of the
data point we had prepared.

Companion writeup: ./sury-alpha10-undefined-optional-in-json.issue.md
Related prior report (fixed in alpha.10): #284 (./sury-alpha8-nullasoption-reverse-bug.md).
-->

Confirming this reproduces on `11.0.0-alpha.10`, and adding a data point + some context.

This is the **encode-direction dual of #284** (the reverse/parse-direction `nullAsOption`-at-depth bug), which was fixed in alpha.10 — closing that one exposed this remaining encode-side gap in the same test suite.

It also reproduces with **plain `option` fields** (no `@s.nullable`), where `None` is meant to serialise as omitted rather than `null`:

```rescript
@schema type inner = {name: string, counter?: string}
@schema type outer = {items?: dict<inner>}

// `counter` omitted -> encoded `inner` carries `counter: undefined`
let value: outer = {items: Dict.fromArray([("a", {name: "x"})])}

let _ = value->S.decodeOrThrow(~from=outerSchema, ~to=S.json)
// SuryError: Failed at ["items"]: Expected undefined | JSON,
//            received { a: { name: "x"; counter: undefined } }
//   - At ["items"]["a"]["counter"]: Expected JSON, received undefined
```

**This is a regression from alpha.4:** `reverseConvertToJsonOrThrow` used to *omit* `undefined` optional fields from the produced JSON, so this exact shape serialised fine. On alpha.10 the only encode-to-JSON route in the ReScript API is `decodeOrThrow(~to=S.json)`, which rejects the nested `undefined` instead of omitting it.

Why it bites in practice: these are forward-compatible cross-stack export shapes — fields are `?`-optional so older producers lacking a field still **decode**. Both obvious fixes fail:

- Switch to `@s.nullable` / `S.nullAsOption` so `None` encodes to `null` → blocked by this very issue on encode at depth, and `nullAsOption` is *present-required on decode*, which breaks the forward-compat the optional markers exist for.
- Keep plain `option` → forward-compatible on decode, but hits this `undefined`-not-jsonable wall on encode.

A tolerant encode that **omits** `undefined` optional fields when targeting JSON (alpha.4 behaviour) would resolve both the plain-`option` and `@s.nullable` cases without the decode-compat tradeoff.

Environment: `sury@11.0.0-alpha.10`, matching `sury-ppx`, `rescript@12.3.0`, Node 22.
