# Plan: APPSYNC_JS-compatible per-page sort in `listAllItemsConnection`

## Problem

`AppSync_Resolver_Functions.listAllItemsConnection` emits a per-page sort block in the generated resolver `response` function whenever `sortFields` is non-empty:

```js
items = items.slice().sort((a, b) => {
  const av = a[orderBy.field];
  const bv = b[orderBy.field];
  if (av === bv) return 0;
  if (av === undefined || av === null) return 1;
  if (bv === undefined || bv === null) return -1;
  return av < bv ? -1 * direction : 1 * direction;
});
```

The APPSYNC_JS runtime (1.0.0) rejects this code with:

```
Error: Unsupported Syntax Type: ArrowFunction [code: UNSUPPORTED_SYNTAX_TYPE]
```

A `function` expression in place of the arrow yields the same class of error (`Unsupported Syntax Type: FunctionExpression`). Confirmed via `aws appsync evaluate-code` — the runtime does not allow any callable passed as a `comparator` argument to `Array.prototype.sort`.

The block is gated on `sortFields->Array.length > 0` ([rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:459](../../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L459)), so any `@id`, `@subId`, `@compositeSubId`, `@index`, or `@scanSort` annotation on a state schema causes `CreateResolver`/`UpdateResolver` to fail with `BadRequestException: The code contains one or more errors.` for the connection list field of that view.

This is not catchable by the existing retry/race logic in `AppSync_Resolver_Retrying.res` — the error is a hard validation failure, not a propagation race.

## Scope

- File: [rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:457-479](../../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L457-L479) — the `sortBlock` template literal inside `listAllItemsConnection`.
- Tests: any unit/snapshot test that compares the emitted JS for a state view with non-empty `sortFields`.

No spec/PPX changes; no `deriveServerCapability` changes.

## Approach

**Discarded — insertion sort.** First attempt followed the obvious "inline the comparator as a `for` loop with index swaps." `aws appsync evaluate-code` rejected it: APPSYNC_JS 1.0.0 forbids `for` (`@aws-appsync/no-for`), `while` (`@aws-appsync/no-while`), `++`/`--` (`@aws-appsync/no-disallowed-unary-operators`), AND recursion (`@aws-appsync/no-recursion`). There is no way to write a hand-rolled sort loop in this runtime. Also discarded: arrow comparator on `Array.prototype.sort` (the original failure), recursive sort helper.

**Probed and confirmed allowed.** Arrow callbacks ARE accepted on `Array.prototype.map` / `filter` / `forEach`. `Array.prototype.sort()` with NO comparator (default lex sort) IS accepted. `Array.prototype.reverse` works. `JSON.stringify` / `JSON.parse` work. `typeof` works. `Math.abs` and `String(x)` are NOT implemented; padding via string-prefix-then-`slice(-N)` works; `String.prototype.padStart` is NOT implemented.

**Shipped — schwartzian transform.** Encode each item as `<sortKey>\x01<json>`, run the no-comparator default sort (lexicographic on the prefix), reverse for DESC, and decode. Numeric fields get zero-padded to 22 chars so lex order matches numeric order for non-negative values (typical for IDs, counts, integer timestamps). Negatives sort lexicographically — acceptable since DynamoDB sort keys are rarely signed numbers. Nulls split out and append to the end regardless of direction.

```js
const orderBy = ctx.args.orderBy;
const sortFields = [<literal>];
if (orderBy && orderBy.field && sortFields.indexOf(orderBy.field) >= 0) {
  const field = orderBy.field;
  const nulls = items.filter(it => it[field] === null || it[field] === undefined);
  const nonNulls = items.filter(it => it[field] !== null && it[field] !== undefined);
  const encoded = nonNulls.map(it => {
    const v = it[field];
    const key = (typeof v === 'number')
      ? ('0000000000000000000000' + v).slice(-22)
      : ('' + v);
    return key + '\x01' + JSON.stringify(it);
  });
  encoded.sort();
  if (orderBy.direction === 'DESC') encoded.reverse();
  items = encoded.map(e => JSON.parse(e.split('\x01')[1])).concat(nulls);
}
```

Semantics vs. the old comparator:
- equal sort keys → ties broken by JSON-encoded item bytes (was: stable, no swap)
- nulls always at the end regardless of direction (preserves old semantics; old code dropped to "after non-nulls" via cmp=±1)
- numeric fields with negatives or unusual decimal widths may not sort numerically — best-effort
- payload roundtrips through `JSON.parse(JSON.stringify(it))` — DynamoDB items are JSON-serializable, so no information loss

Drop `items.slice()` from the old code: the new path reassigns `items` from a freshly built array.

## Status

**Done.**

- [rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:459-489](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L459-L489) — sortBlock rewritten to schwartzian transform.
- [rescript-pulumi-aws/tests/AppSync_Resolver_FunctionsTest.mjs](../../rescript/rescript-pulumi-aws/tests/AppSync_Resolver_FunctionsTest.mjs) — added "DESC keeps nulls at end" and "numeric sort" cases. 107/107 tests pass.
- Validated against the real APPSYNC_JS 1.0.0 runtime via `aws appsync evaluate-code` for `sortFields=["timestamp"]` (string ASC, string DESC with nulls) and `sortFields=["count"]` (numeric ASC: 2, 10, 100). No `codeErrors`.
- Stack-deploy smoke: not run here — pick this up before merging by deploying a stack with a `@subId` / `@index` / `@scanSort` state view and confirming `CreateResolver` succeeds.

## Out of scope

- Changing the SDL surface (`OrderBy` input type, `sortFields` enum) — `deriveConnectionOrderByType` continues to emit the same SDL.
- Changing the in-memory adapter's sort semantics — its sort runs in plain Node.js and is unaffected.
- Cross-page (global) ordering — still requires the v1.5 index-promotion path; this plan only restores per-page sort for the existing surface.
