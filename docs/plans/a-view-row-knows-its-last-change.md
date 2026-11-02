# Plan: a view row knows its last change, and the local platform keeps every change

**Date:** 2026-11-02<br/>
**Status:** 🚧 Built 2026-11-02 ([RC1](#rc1-the-store-stamps-the-change-on-the-row) to
[RC7](#rc7-a-watching-tool-reads-both)), not yet released; the AWS half
([RC3](#rc3-only-an-elevated-caller-reads-it)) is still to be deployed and read on a stack.<br/>
**Repos:** `reventless-core`; [RC7](#rc7-a-watching-tool-reads-both) is a watching tool's.<br/>
**Builds on:**
[the-local-platform-serves-what-is-watched.md](the-local-platform-serves-what-is-watched.md)
(the view-change line on the tap, [PF10](the-local-platform-serves-what-is-watched.md#pf10-the-view-change-line)).

> **Questions and short answers**
>
> - *What does this plan add?* **Two things.** Every view row, on every backend, records the
>   flow and the event of the change that last wrote it
>   ([RC1](#rc1-the-store-stamps-the-change-on-the-row)). The local platform also keeps every
>   row change it makes, and serves them by flow
>   ([RC5](#rc5-the-local-platform-keeps-every-row-change),
>   [RC6](#rc6-the-platform-api-reads-the-change-log)).
> - *Why?* **A trace's Views tab shows only the row changes the editor saw live.** A trace of an
>   older command, or one after a window reload, has no row changes, and a row's *Trace its last
>   change* is offered only for changes seen live.
> - *Who can read a row's last change?* **An elevated caller only** (the deployment's
>   `REVENTLESS_ELEVATED_GROUPS`, as for `@owner` and `@retired`). Anyone else reads `null`
>   ([RCD2](#4-decisions)).
> - *Does the wire change?* **By addition.** Every view type gains a nullable `_change` field of
>   a shared `RowChange` type, and the platform API gains `Platform_ViewChanges`. Both goldens
>   move ([RC4](#rc4-the-goldens-and-the-ui-hints)).
> - *Does a deployed table need a migration?* **No.** A row written before this has no `_change`
>   until it next changes, and reads `null`.

---

## 1. In plain words

A view row is what a projection wrote: an order in *Orders*, a customer in *Customers*. Today
the row holds only its state. Which command's flow changed it last is known for a moment, when
the projection writes it, and then it is gone: a log line says so, and on the local platform a
line on the tap tells whoever is watching.

So a tool that missed that moment cannot say which flow changed a row. This plan keeps that
moment in two places:

- **On the row**, everywhere: the flow id, the event's message id and the time. One small
  object, written with the row. It tells the latest change only.
- **In a log**, on the local platform only, where storage costs nothing: every row change with
  its row before and after. It tells the whole history, so a trace of any flow can list the
  rows that flow changed.

## 2. What is there today

- A projection writes rows through `Projection.handleAction`
  ([Projection.res](../../reventless/core/src/Projection.res)), which knows the events behind
  each action (`~sources`) and reports each change to `ViewChange`
  ([ViewChange.res](../../reventless/core/src/ViewChange.res)).
- Every backend's row passes through one encoder,
  [QueryDb_Operations.res](../../reventless/core/src/components/QueryDb/QueryDb_Operations.res),
  which already adds keys that are not state: `id`, the subId, composite index keys `_pk`/`_sk`,
  `__typename` in unions. A row is decoded through the state schema, which passes over keys it
  does not know, so an added key costs a reader nothing.
- The local platform's tap sends each change as a `viewChange` line
  ([LocalTapLines.res](../../reventless/local/src/adapter/LocalTapLines.res)); nothing keeps it.
- The platform API serves `Platform_EventLog`
  ([LocalPlatformObserve.res](../../reventless/local/src/adapter/LocalPlatformObserve.res));
  AWS has no such API, and needs none here.

## 3. Steps

Numbered RC1 to RC7.

### RC1. The store stamps the change on the row

- `Projection.handleAction` runs each action `during` its change: the last of its sources, as
  `{flow?, msgId, at}` ([RowChange.res](../../reventless/core/src/RowChange.res)), held in an
  `AsyncLocalStorage` ([RCD4](#4-decisions)).
- The two places that turn a row into JSON add it as `_change`: `QueryDb_Operations` (the local
  platform and the tests) and `ProjectionEntryPoint_Ops.withRowChange` (the deployed projection
  Lambdas, which assemble their own operations). Backends store the JSON they are given.
- A save outside a projection, `count` and the deletes do not stamp.

### RC2. Every view type answers `_change`

- The SDL of a view type gains `_change: RowChange`, and the fragment emits the shared
  `type RowChange { flow: String, msgId: String!, at: String! }` once, as
  [Plugin_EventQuerySchema.res](../../reventless/core/src/plugin/component/Plugin_EventQuerySchema.res)
  does `EventMeta`. A `_change` in a state record is refused at build time, like `id`.

### RC3. Only an elevated caller reads it

- **Local:** a field resolver per view type returns the stored `_change` to an elevated caller
  and `null` to anyone else. The local platform now defaults the elevated role to the
  administrator, as the AWS platform already did, so its `admin` reads across owners there too.
- **AWS:** the same as a JS unit resolver on `<Type>._change`, answered from its request step
  (`runtime.earlyReturn`) so the view's data source is never called, with the elevated groups
  baked in as the other view resolvers bake them.
- Being a field resolver, it also covers a row reached through `@resolves` and through a
  subscription's selection.

### RC4. The goldens and the UI hints

- `pnpm run check:graphql:update`: both goldens move in this commit.
- Nothing for the generated UI to skip: it reads the state's JSON Schema, which has no
  `_change`. A state field named `_change` is refused at build time.
- [graphql-api-guide.md §6.1.1](../../packages/doc/docs-app/graphql-api-guide.md#611-a-rows-last-change--_change)
  documents the field.

### RC5. The local platform keeps every row change

- `ViewChangeLogStorage_InMemory` and `ViewChangeLogStorage_Sqlite`, dispatched by
  `LocalViewChangeLog`
  ([LocalViewChangeLog.res](../../reventless/local/src/adapter/ViewChangeLog/LocalViewChangeLog.res)):
  each change as the tap's `viewChange` line (view, key, kind, fields, sources, flow, the row
  before and after, redacted), with its flow, view, key and event ids as columns to read by.
  A Postgres-backed local platform keeps them in memory.
- Kept without a bound, as the store's events are. `seed:reset` leaves them: they name flows,
  which a reset does not reuse.

### RC6. The platform API reads the change log

- `Platform_ViewChanges(filter: {correlationId, msgId, view, key}, first, after)`: a
  connection, newest first, admin only, beside `Platform_EventLog`.

### RC7. A watching tool reads both

- A trace reads its flow's row changes from `Platform_ViewChanges` as it reads its events, so
  the rows of a past flow show as a live one's do.
- A view's rows are read with `_change`, so tracing a row's last change works for a change the
  tool never saw, local or deployed.

## 4. Decisions

| Id | Decision |
|---|---|
| RCD1 | The row carries the latest change only; the history is the local log's. A history per row on DynamoDB would cost a write per change for every app, for a tool's convenience. |
| RCD2 | `_change` is read by elevated callers only, and reads `null` for anyone else rather than an authorization error, so a client selecting it does not fail. |
| RCD3 | A field on the view type rather than an AWS-only admin query: the tools read deployed rows through the app's GraphQL, and one field works the same on both backends. |
| RCD4 | The change reaches the encoder through an `AsyncLocalStorage`, not a parameter: the deployed Lambdas assemble their operations in several layers, and threading a new argument through every `save` would touch some thirty places. Unlike a shared variable it follows each call, so rows a projection writes at the same time each get their own. |
