# Plan: `@ref` and `@displayName` refuse what they cannot honour, and the ids read scales

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/entity-reference-dropdowns.md](../done/entity-reference-dropdowns.md) (the deferred lists of its Phases 2 and 5, and its open question 1) when it closed. None of it blocks anything; each item is a hardening to pick up when it next bites or when the area is touched.<br/>
**Relates to:** [searchable-annotation.md](searchable-annotation.md), [dynamodb-batchwriteitem-25-chunking.md](dynamodb-batchwriteitem-25-chunking.md) (the write-side twin of item 4)

---

## In plain words

`@displayName` composes a row's human label from one or more fields; `@ref` says
which entity a field points at. Both shipped and are in daily use. The parent plan
deferred a set of checks and tests around them, and one DynamoDB limit on reading
many rows by id.

## What is left

1. **`@displayName` rejects combinations it cannot honour.**
   `packages/reventless-ppx/src/ppx/DisplayNameInference.ml` refuses only
   non-string fields. Still accepted silently: `@displayName` on the `@id` /
   `@compositeId` field, and on a field that already carries an `@s.matches(...)`
   (sury takes one `@s.matches` per field, so one of the two schemas is lost).
   Both should be compile errors naming the field.
2. **ppx tests for `@displayName`.** `packages/reventless-ppx/test/run.sh` covers
   `@ref` (its "cross-entity reference annotation" section) but has no
   `@displayName` case: single, composite with the default and an explicit
   separator, `option<string>` parts, and the two refusals from item 1.
3. **An `@ref` naming an entity nobody has is refused.** `Plugin_Structure.res`
   now checks identity-typed fields against the plugin's own views (no view keyed
   by the identity, several, or a named view keyed by something else). It does not
   check a target in another plugin, so `@ref("Ordering.Customerrr")` still
   compiles, deploys and points at nothing. The parent's design: once every plugin
   structure is known (platform start, and the deploy gate), resolve each
   `commandDef.references` target against all of them and fail naming the command,
   the field and the spelled target. An end-to-end test (a command with
   `@ref("Customer")` → the expected `references` entry in the component
   definitions) belongs with it.
4. **Reading more than 100 rows by id.** The `{list}ByIds` door is one
   `BatchGetItem` (`batchGetItemsByIds` in
   `rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`). DynamoDB caps
   that call at 100 keys and 16 MB and may return `UnprocessedKeys`; neither is
   handled. The list query's `filter.ids` is a Scan with `#id IN (…)`. The parent
   recommended chunking in the adapter, in parallel, retrying unprocessed keys —
   an AppSync JS resolver makes one request per function, so that likely means a
   pipeline or the Lambda path. Decide when a view preloads labels for more than
   100 ids, or cap the page size instead.

## Dropped, not left

Self-reference (`@ref` with no argument, meaning "this entity"). The ppx now
refuses it with a clear message, and identity-typed fields (`parent: CategoryId.t`)
derive the reference without any `@ref`, which covers the case it was for.

## Done looks like

Items 1–3 are compile-time or start-time errors with tests; item 4 is either
chunked with a test past 100 ids or recorded as a documented cap.
