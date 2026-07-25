# Plan: Fix the `CommandResult` resolution error on InboundTranslationSlice mutations

## Status: Not started

**Date:** 2026-07-25

## Problem

Every `InboundTranslationSlice` mutation returns a GraphQL error even when the
command succeeds. Observed on the local platform against the online-shop-hybrid
example: each `Catalog_ImportProduct` call returns

```
Abstract type "CommandResult" must resolve to an Object type at runtime for
field ... Either the "CommandResult" type should provide a "resolveType"
function or each possible type should provide an "isTypeOf" function.
```

while the import itself succeeds and the audit view records `Success`. The error
is not specific to `ImportProduct` — it affects **every** InboundTranslationSlice
mutation, because they share one resolver shape.

## Root cause

The generated SDL types the mutation field as `CommandResult!` (an abstract
union/interface), but the resolver returns the target-id array shape rather than
a concrete `CommandResult` member, and no `resolveType`/`isTypeOf` is provided —
so GraphQL cannot pick a concrete object type for the abstract return.

The field-type derivation and the resolver return sit together in
[InboundTranslationResolvers_GraphQL.res](../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res):
the field is emitted as `${fieldName}: CommandResult!` (around lines 40–45),
while the resolver (around lines 56–62) returns
`receiveResultToOutcome |> commandOutcomeToJson`. The abstract type has no way to
resolve to a concrete member for this path.

## Decision

Make the InboundTranslationSlice mutation resolve to a concrete `CommandResult`
member. Two candidate fixes, to be chosen during implementation:

1. **Provide `resolveType`/`isTypeOf`** for `CommandResult` on this server path,
   matching what the aggregate/slice command resolvers already do (they return
   `CommandAccepted`/`CommandRejected`/`CommandPending` and resolve cleanly), so
   the InboundTranslation path reuses the same type resolution instead of a bare
   JSON object; **or**
2. **Type the field concretely** if an InboundTranslation mutation always returns
   one known member, avoiding the abstract type on this path entirely.

Prefer whichever keeps the InboundTranslation result shape consistent with the
other command result surfaces rather than introducing a third convention.

## Steps

1. Confirm the exact divergence between this resolver's return and what the other
   command resolvers return that lets *them* resolve `CommandResult` — the fix is
   to make this path match.
2. Apply the chosen fix in
   [InboundTranslationResolvers_GraphQL.res](../../reventless/local/src/adapter/CommandGenerator/InboundTranslationResolvers_GraphQL.res).
3. Verify no over-the-wire GraphQL error on a successful InboundTranslation
   mutation, and that a *rejected* one still returns a well-typed rejection.

## Acceptance

- `Catalog_ImportProduct` (and every other InboundTranslationSlice mutation)
  returns a clean, well-typed `CommandResult` with no `resolveType` error, both
  on success and on rejection.
- The demo-data seeder can drop its carve-out for this exact error
  (`online-shop-hybrid-demo-data` documents a workaround that verifies the
  outcome through the audit view instead of the mutation response — that
  workaround should be deleted once this lands).

## Notes

- Surfaced during AutoUI board verification: AutoUI builds command panels from
  these mutations, so an InboundTranslation command would show a rejection in the
  UI for a command that actually succeeded. The fix is entirely server-side; no
  UI change is needed.
- Affects the local platform path; confirm whether the AWS/AppSync command
  resolver path shares the shape or resolves correctly there, and scope
  accordingly.
