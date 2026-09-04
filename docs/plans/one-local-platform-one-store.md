# Plan: one local platform per app, one store

**Status.** Steps 1–2 DONE 2026-09-04 (`LocalPlatformStart`, wired into the
functor's reset arm and into all three examples' `Main.res`). Step 3 is the
extension's, and is now unblocked. Step 4 not started — still worth scoping on
its own. Written 2026-09-04.

**Goal.** At most one local platform running per app directory, serving one store,
started by whoever gets there first — `pnpm run serve` or the VS Code runner — and
addressed by everyone else. Today two starters race for the same ports, keep
separate stores in one directory, and the loser can destroy the winner's data
before it finds out it lost.

**Relates to:**

- [`local-platform-discovery-for-seed-tools.md`](done/local-platform-discovery-for-seed-tools.md)
  — built `LocalPlatformRegistry`, which taught the seed *tools* to ask which
  platform they were addressing. This plan teaches the *starters* to ask.
- [`optional-fields-without-annotations.md`](optional-fields-without-annotations.md)
  — the wire migration whose local arm this would have reduced to one command
- companion in `reventless-tools`:
  `docs/plans/runner-attaches-to-a-running-platform.md` — the extension half of
  steps 2–4

---

## Why — three symptoms of one missing question

**1. A reset wipes before the bind fails.** `Platform.MakeWithConfig`'s functor
body runs `Backend.removeFileIfExists` and then `LocalObjectStore.reset`
([`Platform.res:115-126`](../../reventless/local/src/Platform.res#L115-L126));
`startServers` binds the ports far later
([`Platform.res:1282`](../../reventless/local/src/Platform.res#L1282)). So a second
`pnpm run serve:reset` destroys the running platform's store *and then* discovers
it cannot listen. The `EADDRINUSE` looks like a harmless "already running"; the
data is already gone. Verified 2026-08-05.

**2. Two stores in one directory share one object store.**
`BackendState.getObjectStoreRoot` is `dirname(<sqlite path>)`
([`BackendState.res:48-52`](../../reventless/local/src/adapter/BackendState.res#L48-L52)),
and `ObjectStoreStorage_FileSystem.reset` removes `objects/`, `object-meta/` and
`offload/` wholesale. Upload keys carry a random UUID
(`uploads/Catalog/productImages/<uuid>/prd-013.svg`), so a reseed does not
reproduce the keys the *other* store's rows point at: of two stores in one
`.reventless/`, only one can be reseeded with working image references. Measured
during the optional-encoding migration, which is what made that migration cost an
hour instead of a command.

**3. The tools ask; the starters do not.** `LocalPlatformRegistry` already
publishes `.reventless/running/<domainPort>.json` — app, pid, endpoint, login
endpoint, and the **absolute** store path — with dead-pid pruning on read, and
`list(~cwd)` returns exactly the live entries. `LocalSeedTarget` consumes it.
`serve` does not, and the runner does not: it port-probes and offers to kill
whatever holds the port.

**The store split was deliberate, and only half of its reason survives.** The
runner resets on start, so pointing it at a curated `local.db` would wipe a seeded
store on every launch — real, and answered by the tools plan's step 1 (flip
`reventless.platformBackendReset` to false), not by this one. The other half, "two
platforms writing projections into one file would race", is dissolved by
construction here: there is only ever one.

## Step 1 — refuse a reset that would wipe a served store — DONE

Landed as `LocalPlatformStart.guardReset`, called from the `Backend.Sqlite` arm
before `removeFileIfExists`.

In the `Backend.Sqlite` arm of the functor body, before `removeFileIfExists`:
resolve `path` to an absolute path and check `LocalPlatformRegistry.list()` for a
live entry whose `store.path` matches. If there is one, throw naming the app, port
and pid holding it, rather than unlinking.

**In the functor, and always on**, because this is the data-loss guard and it must
protect an app whose author never opts into step 2. It is safe for tests: a Memory
backend has no path to match, and a test's temp sqlite path matches no registered
entry.

Best-effort by design: `list` is scoped to `<cwd>/.reventless/running/`, so a
`REVENTLESS_LOCAL_BACKEND` pointed at *another* app's file is not caught. That is
the right trade — it covers the collision that actually happens (same app, same
directory, two starters) without pretending to a machine-wide lock.

## Step 2 — start, or address the one already running — DONE

Landed as `LocalPlatformStart.orAddressRunning`, first line of all three
examples' `Main.res`.

**One thing the table missed, found in verification.** `serve:reset` reaches this
helper before it reaches step 1's guard, so the "already running → exit 0" arm
swallowed the reset: the operator asked for a wipe, got a success exit, and a
`serve:reset && seed` would then have run against a store nothing emptied. So
`orAddressRunning` checks the reset FIRST — reading the same `Backend.fromEnv()`
the functor is about to read — and throws step 1's refusal. Exit 0 is for a start
that was merely redundant, never for a destructive one that did not happen.

A helper in `reventless-local` that each example's `Main.res` calls as its first
line, **before** `ReventlessLocal.Platform.Make()`:

| live entries in this cwd | behaviour |
|---|---|
| 0 | return, and the platform starts as it does today |
| 1 | print `→ already running at :4000 · sqlite …/local.db (pid 51055)` and exit 0 |
| ≥2 | print all of them and exit 0 — a state this plan is trying to make impossible, so say so rather than pick |

Deliberately **not** in the functor body, even though that would need no per-app
edit: `Platform.Make` is applied by the test suites too, and a guard that exits the
process on finding a registry entry turns a developer's running dev server into a
red test run. One line in three `Main.res` files is the cheaper mistake. The
per-app opt-in is also what lets an app that genuinely wants two platforms (the
e2e suites, which already run several on distinct ports) keep them.

An explicit `REVENTLESS_DOMAIN_PORT` should bypass this — that is how the e2e
suites and the runner already start deliberate parallel platforms, and it is the
same escape hatch `REVENTLESS_GRAPHQL_ENDPOINT` is for the seed tools.

## Step 3 — one store per app — the extension's, now unblocked on this side

Once steps 1–2 and the tools plan's step 1 have landed, the runner's store becomes
`./.reventless/local.db` — a two-line change in the extension's
`platformBackendArgs()`, which is the only place `runner.db` is named. Nothing in
this repo needs to change; the point of listing it here is the **ordering**:
merging the stores before the reset default flips means every VS Code launch wipes
the developer's seeded store.

After it lands, delete the `runner.db` handling from step 2 of the optional-fields
plan's local arm and from `docs/guides/local-dev.md`'s worked example.

## Step 4 — the event tap over a socket, not only stdout — NOT STARTED

The blocker to the runner *attaching* rather than refusing. Its timeline and
inspector are fed by the child's stdout: `LocalBus.publishEvent` emits
`@@RVLESS_EVT@@ {…}` per event when `REVENTLESS_EVENT_TAP` is set
([`LocalBus.res:64-83`](../../reventless/local/src/adapter/LocalBus.res#L64-L83)),
and `PlatformRunner` line-parses it. A platform the runner did not spawn has no
stdout it can read, so attaching means a dark timeline.

Give the tap a second sink: when `REVENTLESS_EVENT_TAP` names a port rather than
being a bare flag, serve the same NDJSON lines over a local socket (or SSE on the
existing domain server) and publish that port in the registry entry. The line
format does not change, so the runner's parser is reused; `Console.log` stays for
the spawned case.

This is the only step that is genuinely new machinery rather than a check, and it
is worth scoping on its own before committing to it — steps 1–3 stand without it,
and leave the runner refusing-with-a-reason instead of attaching, which is already
better than killing the other process.

## Verification

- `pnpm run build` with zero warnings; `pnpm test` and `pnpm run test:projects` —
  384 suites, 4137 tests, all green ✅
- **Step 1:** start `pnpm run serve`, then run `pnpm run serve:reset` in a second
  shell — the second must refuse with the first's port and pid, and the first
  must still serve every row it had. This is the exact sequence that lost data.
  ✅ Run against `online-shop-hybrid/platform-local`: the second exited 1 with
  `refusing to reset ./.reventless/local.db: it is the store of … running at
  :4000 (pid 54433)`; `local.db` kept its checksum, the uploads tree was intact,
  and the first platform went on answering.
- **Step 2:** the same pair, with `serve` second — it must print the running
  platform's endpoint and store and exit 0. ✅ `→ already running at :4000 ·
  sqlite .reventless/local.db (pid 54433)`.
- **Step 3:** VS Code runner start, then `pnpm run seed` — one store, seeded once,
  visible to both. — the extension's, not run here.
- The e2e suites, which run several platforms in one directory on distinct ports,
  must be unaffected — the sharpest check that step 2's escape hatch is right.
  ✅ `pnpm run check:graphql` starts its own platform on distinct ports with
  `REVENTLESS_DOMAIN_PORT`, and passed *while* the :4000 platform was serving.

## What would stop this

- **A consumer that needs two stores in one directory.** The e2e suites run
  several platforms, but on distinct ports and distinct store files, and they set
  `REVENTLESS_DOMAIN_PORT` — so they take step 2's bypass. If something else
  wants two *default* platforms in one directory, step 2's table is wrong.
- **The event tap turning out to need the child.** If the runner's timeline
  depends on ordering guarantees that only a piped stdout gives, step 4 is a
  bigger change than a second sink and should be split out rather than grown.
