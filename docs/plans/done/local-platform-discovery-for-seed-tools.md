# Plan: the seed tools address a running platform, not a guessed file

**Status:** Complete

| Item | Status | Notes |
|---|---|---|
| 1 — a running platform publishes itself | ✅ done | `LocalPlatformRegistry`; `.reventless/running/<domainPort>.json`, written by `startServers`, removed on `exit`/`SIGINT`/`SIGTERM` |
| 2 — one selector shared by both tools | ✅ done | `LocalSeedTarget`: none / one / several → default, use, prompt (`SEED_PLATFORM`) |
| 3 — `seed:reset` follows the selection | ✅ done | store comes from the entry; `REVENTLESS_LOCAL_BACKEND` demoted to an explicit override, and its default dropped from all three example scripts |
| 4 — `seed` follows the same selection | ✅ done | `LocalSeedTarget.connect()` replaces `Seed.Connect.local()` in the hybrid example |
| 5 — tests | ✅ done | 8 in `LocalPlatformRegistryTest` — round-trip, two platforms in one directory, dead-pid and unreadable pruning, login-route derivation, each unopenable-store message |

Verified end-to-end on 2026-08-14 against three platforms in one directory
(:4000 sqlite `runner.db`, :4020 sqlite `e2e-a.db`, :4030 memory): each tool
printed the endpoint and store it picked, `SEED_PLATFORM` selected without a
TTY, a `domain` reset of :4020 left :4030's rows untouched, the reset → seed loop
closed on the same store, the memory platform reported *restart it to empty it*
rather than a path, a `SIGTERM`ed platform removed its own entry, and the entry a
`kill -9` left behind was pruned by the next read. 645 `reventless-local` tests
pass.

---

## The failure this removes

Two commands that are supposed to be inverses disagreed about which store they
were operating on, and both reported success:

```
$ pnpm run seed:reset      → "Nothing to do."          (emptied ./.reventless/local.db)
$ pnpm run seed            → "the target store is not empty —
                              Catalog_Categories already holds 8 row(s)"
```

Neither is wrong. They were looking at different databases:

- **`seed:reset`** opens a SQLite file directly, defaulting to
  `${REVENTLESS_LOCAL_BACKEND:-sqlite:./.reventless/local.db}` — an environment
  variable read in the *tool's* process, which says nothing about any platform.
- **`seed`** never opens a file. Its pre-flight counts rows over GraphQL against
  the **running platform** (`Seed_Runner.assertStoreEmpty`), which in this case
  was the VS Code runner's child on `sqlite:./.reventless/runner.db`.

The same mismatch produced a second, more confusing symptom the day before: a
read model's rows had been projected before a field was added to its state, so
the running platform answered `Cannot return null for non-nullable field
Ordering_Customer.customerId` — and every attempt to reset and re-seed those rows
from the shell silently emptied a store nobody was serving.

The separation of stores is not the bug. The VS Code runner deliberately keeps
its own store: it resets on start by default (`platformBackendReset`), so
pointing it at the developer's curated `local.db` would wipe a seeded store on
every launch, and two platforms writing projections into one file would race. The
bug is that **the store a platform serves is invisible from outside it**, so
every tool falls back to guessing, and the guess is wrong exactly when a second
platform is running — the case the tools exist for.

## The shape

An endpoint already identifies a platform: `seed` addresses one through
`REVENTLESS_GRAPHQL_ENDPOINT`, and parallel platforms already differ by port
(`REVENTLESS_DOMAIN_PORT` etc., added for the runner). So:

> **The endpoint identifies the platform; the platform names its store.**

For a tool to offer that as a choice, running platforms have to be discoverable.
A platform writes one entry per run into a registry directory next to the store
it opened, and removes it on the way out.

### 1 — a running platform publishes itself

`LocalPlatformRegistry` (in `reventless-local`), called from `startServers` —
the moment the platform is actually reachable, and the one both unified and split
API modes pass through:

```
<cwd>/.reventless/running/<domainPort>.json
{ "app": "@…/online-shop-hybrid-platform-local",
  "pid": 51055,
  "endpoint": "http://localhost:4000/graphql",
  "loginEndpoint": "http://localhost:4000/__inmemory/login",
  "store": { "kind": "sqlite", "path": "/abs/…/.reventless/runner.db" },
  "startedAt": "2026-08-14T01:05:32.000Z" }
```

Three things this must get right:

- **The path is absolute.** Two apps both use `./.reventless/local.db` relative
  to different cwds; a relative path names no store outside the process that
  wrote it. Taken from `BackendState`, which already holds the resolved path,
  rather than re-derived from the env string.
- **One file per port, not one per directory.** The case that broke — a manual
  `serve` and the runner's child, same app, same package directory — is exactly
  the one a single `platform.json` cannot represent.
- **A crash leaves no ghost.** Removal is best-effort (`exit`, `SIGINT`,
  `SIGTERM`), so readers prune independently: an entry whose pid is gone
  (`process.kill(pid, 0)` throws) is deleted on read. Liveness by pid rather than
  by probing the endpoint keeps the reader synchronous and still prunes a wedged
  process that would never answer a probe.

`.reventless/` is already gitignored, and the SQLite driver already creates it.
A Memory-backed platform registers too — it has no file, and that is a fact worth
reporting rather than a reason to be invisible.

### 2 — one selector, shared

`LocalSeedTarget.select()` answers "which platform" once, for both tools:

| running platforms | behaviour |
|---|---|
| explicit `REVENTLESS_GRAPHQL_ENDPOINT` | use it verbatim, no discovery — the documented escape hatch, unchanged |
| 0 | say so, fall back to the `localhost:4000` default so a platform from an older build still works |
| 1 | use it, and **print which** (`→ :4000 · sqlite …/runner.db`) — the line that would have prevented all of this |
| ≥2 | prompt, `Seed.Prompt.select` with `SEED_PLATFORM` as the non-interactive override |

That is the idiom the seed run already uses for every other choice (reset scope /
`SEED_RESET_SCOPE`, data set / `SEED_SET`, credentials / `REVENTLESS_DEMO_*`),
including its no-TTY behaviour. `Seed.Prompt.select` already returns a sole
option without prompting, so the one-platform case costs nothing.

### 3 — `seed:reset` follows the selection

Precedence, replacing the `Backend.fromEnv()` guess:

1. `~dbPath` argument (programmatic callers)
2. `REVENTLESS_LOCAL_BACKEND` **explicitly set in this shell** → open that file
   directly. Keeps the one case discovery cannot serve: resetting a store whose
   platform is not running.
3. the selected platform's store
4. nothing found → today's message, now naming the endpoint it asked

The examples' `seed:reset` script must **drop** its
`${REVENTLESS_LOCAL_BACKEND:-sqlite:./.reventless/local.db}` default — with it,
step 2 always fires and discovery never runs. That default *is* the wrong guess.

A Memory-backed selection reports the truth about a platform it contacted — *the
platform on :4010 keeps its store in memory; restart it to empty it* — instead of
inferring in-memory-ness from the tool's own environment.

### 4 — `seed` follows the same selection

`Seed.Runner.seed`'s `~connect` is a thunk (`unit => promise<connection>`), so
selection happens inside it, already async. The examples change one argument:

```rescript
Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=LocalSeedTarget.connect())
```

`Seed_Connect.local` is untouched and still takes `~graphql` / `~login`;
`LocalSeedTarget` supplies them from the entry. Layering holds: `reventless-seed`
stays transport-only and provider-agnostic (it also serves AWS), while
"where are the local platforms" belongs to `reventless-local`, which already
depends on it.

## Where it lives

`reventless-local`, beside `LocalSeedReset` and for the same reason: it is
knowledge about local platforms, and the package is never layer-bundled.

Split into two modules so the platform does not import a prompt library:

- `LocalPlatformRegistry` — write/read/prune. No `Seed` dependency, so
  `Platform.res` gains no readline import.
- `LocalSeedTarget` — selection, `connect()`, store resolution. Used by the two
  CLI entry points only.

## Out of scope

- **Cross-app discovery.** The registry is per package directory, which is where
  `seed` and `seed:reset` are run from. A machine-wide `~/.reventless/running/`
  would let one shell see every app's platform; nothing needs that yet.
- **Making the runner and the manual platform share a store.** Analysed and
  rejected above.
- **The stale-projection failure itself** (`customerId` null). A re-seed fixes
  it; a read model whose state schema outruns its stored rows is a separate
  question.
