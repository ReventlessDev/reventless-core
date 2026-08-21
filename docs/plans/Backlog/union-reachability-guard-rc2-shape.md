# `check:unions` only examines the older codegen shape

**Date:** 2026-08-21
**Status:** Backlog — nothing is broken today; the guard reports more coverage than it has.

## What

[`scripts/check-union-reachability.mjs`](../../../scripts/check-union-reachability.mjs)
detects [DZakh/sury#392](https://github.com/DZakh/sury/issues/392) by matching the
generated parser against `OUTER_DISPATCH = "i=>{for(;;){"` — the prefix sury `rc.0`/`rc.1`
emitted. `rc.2` emits `i=>{if(typeof i==="object"&&…){for(;;){` for a union whose members
are all objects, so `strandedAfterGroup` returns `null` at its first lookup and the schema
is passed without being examined.

Measured on the `rc.2` pin: **40 of 114** TAG-dispatch parsers still match the prefix. The
other 74 are skipped, yet the run prints `ok 114 tagged-union schemas, every constructor
reachable`.

## Why it is not urgent

The 74 skipped parsers are the *fixed* shape — every member's `TAG` is tested inside the
block and the fall-through throw sits inside it too, so there is nothing to strand. The
guard is silent about them because they are correct, not because it lost the ability to
judge them.

## Why it is still worth doing

The guard's stated value is that it is a shape check, not a round-trip: it fails when a
union *could* be broken by the next constructor added, before anyone writes a decode test.
That tripwire now covers roughly a third of the repo's unions, and the success message
does not say so. sury is still a release candidate, so a future codegen change is the case
this exists for.

## Options

1. **Teach it the `rc.2` prefix** — recognise both shapes, restoring all 114. Smallest
   change; still couples the guard to a literal the next release can move again.
2. **Anchor on the group marker instead of the outer prefix** — locate the inner
   `for(;;)` dispatch and check for `TAG` tests after its closing brace, without asserting
   how the parser opens. Fewer literals to go stale.
3. **Report coverage honestly and leave the logic** — print examined-vs-skipped so a
   drop in coverage is visible on the next bump even if detection lags.

Whatever is chosen, the success line should name how many parsers were actually examined.

## Related

- [plugin-command-union-decode-failure.md](../../analysis/done/plugin-command-union-decode-failure.md)
- [sury-union-regression-issue.md](../../analysis/done/sury-union-regression-issue.md)
- Constructor orderings the guard enforces: `PluginSpec.res`,
  `PluginExtensionPointSpec.res`, `Products.res` — wire-compatible, no reason to unwind.
