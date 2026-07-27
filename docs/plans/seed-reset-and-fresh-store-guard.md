# Seed re-runs: fresh-store guard now, guarded reset later

**Status:** In progress (2026-07-27).
- **Option 1 — pre-flight fresh-store guard:** implementing now (this plan).
- **Option 2 — guarded reset/wipe for deployed stacks:** designed here, **not**
  implemented. It is dangerous by nature and depends on prerequisites (ideally
  prod in a separate AWS account) that are out of scope for this change.

## Problem

The seed harness (`reventless-seed`) is a **one-shot against a fresh store**. Its
own runner says so: on any failure it prints "the store is now half-seeded …
re-run against a fresh store", i.e. recovery is a reset, not a re-run.

Running `pnpm run seed` a second time against an already-seeded store aborts on
the first command. The example's domain behaviors reject duplicates on purpose:

- [`AddCategory_Behavior.res`](../../examples/online-shop-hybrid/catalog/src/Category/StateChangeSlice/AddCategory_Behavior.res)
  returns `Error(CategoryAlreadyExists)` when the category exists.
- [`AddProduct_Behavior.res`](../../examples/online-shop-hybrid/catalog/src/Product/StateChangeSlice/AddProduct_Behavior.res)
  does the same for products.

The seed sends these via [`Seed.Client.sendAll`](../../reventless/seed/src/Seed_Client.res)
(no `~tolerate`), so a `CommandRejected` throws `Failed` and the run aborts with
the half-seeded message.

## Decision: do not weaken the domain

We deliberately keep the behaviors non-idempotent:

- A duplicate `AddCategory` genuinely *is* a business rejection and is one of the
  example's clearest teaching cases for the rejection path. Making it return
  `Ok([])` would teach that `Add` silently swallows duplicates, which is wrong.
- The framework idempotency convention ("no-op commands return `Ok([])`") is
  about **at-least-once retry dedup** (handled by command id), not about
  re-seeding a populated store. Different concern; not a reason to change `decide`.

So the seed, not the domain, owns re-run behavior.

## Option 1 — pre-flight fresh-store guard (this change)

Before sending any command, count a small set of the data set's own views. If any
already has rows, the store is not fresh: abort **early** via the existing
"did not start — nothing was written" path, with a message telling the operator to
reset first. This is the read-only, always-safe half of the answer:

- It replaces the misleading "half-seeded" abort (which fires on the *first*
  duplicate, when in fact nothing was written on the re-run) with an honest one.
- It is the exact inverse of the post-run `verifyViews` check: seeding refuses to
  start unless the store reads empty, and refuses to finish unless it reads full.

### Shape

- `Seed_Runner.dataSet` gains an **optional** `probeViews: array<string>` field.
  Optional keeps every existing constructor compiling; a data set that omits it
  skips the guard (no behavior change).
- `Seed_Runner` gains `assertStoreEmpty(client, ~probeViews)`: counts each probe
  view, and `throw(Failed(...))` on the first non-empty one. It runs inside the
  pre-connect/pre-seed `try` in `Seed_Runner.seed`, so a non-empty store (or a
  probe-query error) is reported through `abortStartup` — "nothing was written" —
  never through the half-seeded `run` path.
- The hybrid data sets set `probeViews` from their existing `views` list (the
  `Seeded` names), so the guard and `verifyViews` stay in lockstep. Ordered so the
  first-written view (`Catalog_Categories`) is checked first — a populated store
  aborts after one query.

### Non-goals for Option 1

- It does **not** delete anything. It only refuses to start.
- It does not make a partially-failed run (e.g. the earlier `@pulumi/pulumi`
  cold-start crash, which wrote no events, only S3 images) un-seedable: no
  committed events → probe views empty → the guard lets the retry proceed, which
  is correct.

## Option 2 — guarded reset/wipe for deployed stacks (design only, not built)

"Reset" on a deployed, event-sourced platform means **truncate the durable
stores** — EventLog + DcbEventLog + every QueryDb table (DynamoDB), plus
task/served-image buckets (S3) — leaving the infrastructure in place so the stack
is empty and re-seedable. (A full infra reset is `pulumi destroy && pulumi up` on
the stack; heavier, same targeting/safety rules apply.)

### Enabling fact: resources are already environment-tagged

Every framework-created resource carries
[`reventless:environment = <stackName>`](../../reventless/aws/src/adapter/AWS_Tags.res)
(plus `reventless:platform`, `reventless:role`, `reventless:kind`, `reventless:scope`).
A wipe therefore discovers its exact target set via the **Resource Groups Tagging
API** filtered on those tags — it only ever sees resources belonging to the named
stack. No name globbing, no account-wide scan. The blast radius is defined by a tag
the framework stamps, not by a string we assemble.

### Safety — defense in depth, every layer fail-closed

Ordered strongest first; each is independent, and production must be unreachable at
several of them at once.

1. **Separate AWS accounts for prod vs dev/alpha (the only structural guarantee).**
   Dev credentials physically cannot reach prod resources. Everything below is a
   secondary net. If prod is not yet in its own account, that is the highest-value
   prerequisite before any wipe tool ships.
2. **Fail-closed allowlist, never a denylist.** Refuse unless the target stack is on
   an explicit wipeable list (`alpha`, `dev`, `pr-*`). Unknown stack → refuse. A
   denylist ("everything except prod") fails *open* the day a new prod-like stack is
   added and forgotten.
3. **The stack declares its own wipeability at deploy time.** A Pulumi stack config
   (`reventless:wipeable: true`) set on dev stacks only, surfaced as a stack output
   and/or a `reventless:wipeable` tag. The tool reads the *target's own* declaration
   and refuses anything that has not opted in. Production stacks simply never set it,
   so the flag lives with the environment definition and travels with it.
4. **Per-resource tag verification before any delete.** For every table/bucket about
   to be touched, assert its `reventless:environment` equals the stack the operator
   named. Any mismatch aborts the whole run — catches a mis-resolved endpoint or a
   credential pointing at the wrong account.
5. **Resource-level deletion protection on prod** (not currently set; easy to add):
   DynamoDB `deletionProtectionEnabled: true` and S3 without `forceDestroy` on
   production stacks. Guards the infra-reset path (`pulumi destroy` bounces off
   protected tables). Protects table deletion, not item deletion — complements
   layers 1–4, does not replace them.
6. **Dry-run default + typed confirmation.** Default run only lists what it would
   empty (table names, item counts, buckets) and exits. A real wipe requires
   re-typing the stack name and an explicit `REVENTLESS_WIPE_CONFIRM=<stack>` that
   must match the resolved target, or it aborts. No silent default.

### Concrete shape (when built)

A `seed:reset` companion (or a `reventless-seed` reset module mirroring the runner
ergonomics) that:

1. Resolves the target stack name from the seed connection/config.
2. Asserts stack ∈ allowlist **and** the stack's own `wipeable` output is `true`
   (both, not either).
3. Discovers tables/buckets by `reventless:environment` tag; verifies each tag
   matches (layer 4).
4. Dry-runs by default; on confirm, `BatchWriteItem`-deletes the DynamoDB stores and
   empties the buckets.
5. Reuses `verifyViews` — asserting **0** — to prove the store is empty, the exact
   inverse of the post-seed check.

Then production is unreachable at three independent layers (wrong account, not on
the allowlist, never declared `wipeable`), with per-resource tag checks and DynamoDB
deletion protection behind them.

### Prerequisites / open questions for Option 2

- Confirm (or establish) prod-in-separate-account. Until then the allowlist +
  `wipeable` output is the in-tool gate, but the structural guarantee is missing.
- Decide where the allowlist lives (stack config vs a checked-in list) and how
  `reventless:wipeable` is surfaced (stack output vs tag vs both).
- IAM: the wipe principal needs tagging-API read + table item-delete + bucket
  empty, scoped by tag condition where possible.
