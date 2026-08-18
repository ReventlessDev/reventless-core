<!--
Ready-to-post GitHub issue for https://github.com/DZakh/sury
Paste the "Title" as the issue title and everything under "Body" as the issue body.
Companion analysis: this file also serves as the internal writeup.

STATUS: never filed — fixed upstream before we got to it. Found 2026-07-28 moving
from alpha.10 to alpha.11; confirmed gone on 11.0.0-rc.0 on 2026-08-04. All seven
rows of the matrix below pass on rc.0, and the `@as("*")` arms in
rescript/pulumi-aws/src/IAM/PolicyDocument.res have been moved back to first
position (the workaround this file describes is no longer in the tree). Kept as a
record of the regression and of the schema shapes worth re-testing on a sury bump.

Prior reports from us, both fixed:
  • #284 — nullAsOption reverse transform dropped at depth (fixed in alpha.10)
    ./sury-alpha8-nullasoption-reverse-bug.md
  • #311 — nested `None` optional rejected as non-jsonable on encode (fixed in alpha.11)
    ./sury-alpha10-undefined-optional-in-json.issue.md
-->

# Title

Regression in 11.0.0-alpha.11: encoder compilation crashes for an optional field whose union schema leads with a literal

# Body

## Summary

On `11.0.0-alpha.11`, building the JSON encoder for an **optional** field throws a
raw `TypeError` when that field's schema is a **union that starts with a literal**
and has **two or more further members**:

```
TypeError: Cannot read properties of undefined (reading 'includes')
    at inlinedValueFromString (sury/src/S.mjs:280:14)
    at B_inlineConst           (sury/src/S.mjs:385:12)
```

`inlinedValueFromString` receives `undefined` instead of the literal's string.

This worked on `11.0.0-alpha.10`; it is a regression.

Note it is a crash *inside* schema/encoder compilation, not a validation error — so
it fires regardless of the value being encoded, including when the optional field is
absent, and it cannot be caught as a `SuryError`.

## Minimal reproduction

```js
import * as Sury from "sury";
import * as S from "sury/src/S.res.mjs";

// how sury-ppx compiles an unboxed ReScript variant arm carrying a payload
const w = (schema) => Sury.$res_schema((x) => x.m(schema));

const optionalField = (schema) =>
  Sury.$res_schema((s) => ({ A: s.m(Sury.$res_option(schema)) }));

// FAILS — literal first, two further members
S.decodeOrThrow(
  { A: "x" },
  optionalField(Sury.union([Sury.literal("*"), w(Sury.string), w(Sury.array(Sury.string))])),
  Sury.json,
);
// TypeError: Cannot read properties of undefined (reading 'includes')
```

## What does and does not trigger it

Each row is the same `optionalField(...)` wrapper, encoded to `Sury.json`:

| union members                                    | alpha.10 | alpha.11 | rc.0 |
| ------------------------------------------------ | -------- | -------- | ---- |
| `literal` + 1 wrapped                             | pass     | pass     | pass |
| `literal` + 2 wrapped                             | pass     | **crash** | pass |
| `literal`, `literal` + 2 wrapped                  | pass     | **crash** | pass |
| 2 wrapped, no literal                             | pass     | pass     | pass |
| 3 wrapped, no literal                             | pass     | pass     | pass |
| 2 wrapped + `literal` **last**                    | pass     | pass     | pass |
| 1 wrapped, `literal`, 1 wrapped (literal middle)  | pass     | pass     | pass |

So the trigger is: **optional + union + literal in first position + at least three
members total**. Moving the literal out of first position avoids it, and the same
union in a *required* field is fine. Unwrapped members (`Sury.string` rather than
`w(Sury.string)`) crash identically, so the `$res_schema` wrapper is not the cause.

The encode target does not matter — `Sury.json` and `Sury.jsonString` both crash.

## Where it bit us

This is the natural compilation of an idiomatic ReScript unboxed variant — the
"wildcard, one value, or many values" shape that appears wherever a document format
lets a field be `"*"`, a single string, or a list:

```rescript
@schema @unboxed
type selector = | @as("*") All | One(string) | Many(array<string>)

@schema
type rule = {
  kind: kind,
  selector?: selector,   // optional + the union above
  // ...
}
```

We hit it in a document generator built on exactly that grammar: every document it
produces failed to encode, so this broke a deploy path rather than only a test.

## Workaround

Declare the literal arm last — for an `@unboxed` variant this changes neither the
encoded JSON nor the runtime representation of a decoded `"*"`:

```rescript
@schema @unboxed
type selector = One(string) | Many(array<string>) | @as("*") All
```

## Environment

- `sury@11.0.0-alpha.11` (works on `11.0.0-alpha.10`), matching `sury-ppx`,
  `rescript@12.3.0`, Node 22.17.1.
