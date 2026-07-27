# Seed re-runs: fresh-store guard now, guarded reset later

**Status:** Complete (2026-07-27). Both options shipped; no code work remains.
- **Option 1 — pre-flight fresh-store guard:** **done** (commit `987613f07`).
- **Option 2 — guarded reset/wipe for deployed stacks:** **done** (commit
  `6e3f5ca15`). Layers 2–4 and 6 (name allowlist, per-stack `wipeable`
  declaration, tag-scoped discovery + per-resource tag re-check, dry-run + typed
  confirm) are implemented. Two **non-code** layers stay deferred by design and
  are tracked under **Still open after this change** below — they are ops /
  deploy-config decisions, not tasks of this plan: Layer 1 (separate AWS accounts
  for prod vs dev, a structural prerequisite) and Layer 5 (resource-level deletion
  protection on prod).

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
[`reventless:platform = <projectName>` and `reventless:environment = <stackName>`](../../reventless/aws/src/adapter/AWS_Tags.res)
(plus `reventless:role`, `reventless:kind`, `reventless:scope`). A wipe discovers
its target set via the **Resource Groups Tagging API** filtered on those tags —
no name globbing, no account-wide scan. The blast radius is defined by tags the
framework stamps, not by a string we assemble.

**Scope on BOTH `platform` and `environment`, not `environment` alone.**
`reventless:environment` is `getStackName()` — the stack *name* only — so two
different Pulumi projects deployed with the same stack name (e.g. `alpha`) in one
account/region share that tag value. Filtering on `environment` alone therefore
sweeps in *every* project's `alpha` resources (observed in practice: the core
hybrid example and a separate platform-inspector deployment both named `alpha`,
their tables interleaved). `reventless:platform` is the Pulumi project name
([`Plugin.res`](../../reventless/aws/src/components/Plugin.res): `platformName =
getProjectName()`), so AND-ing it keeps the wipe inside the one project the
operator is standing in. The reset reads that project name from the target's
`Pulumi.yaml`.

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
   to be touched, assert its `reventless:platform` and `reventless:environment`
   equal the project + stack the operator named. Any mismatch aborts the whole run
   — catches a mis-resolved endpoint or a credential pointing at the wrong account.
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
3. Discovers tables/buckets by `reventless:platform` + `reventless:environment`
   tags; verifies both per resource (layer 4).
4. Dry-runs by default; on confirm, `BatchWriteItem`-deletes the DynamoDB stores and
   empties the buckets.
5. Reuses `verifyViews` — asserting **0** — to prove the store is empty, the exact
   inverse of the post-seed check.

Then production is unreachable at three independent layers (wrong account, not on
the allowlist, never declared `wipeable`), with per-resource tag checks and DynamoDB
deletion protection behind them.

### Prerequisites / open questions for Option 2

- Confirm (or establish) prod-in-separate-account. Until then the allowlist +
  `wipeable` declaration is the in-tool gate, but the structural guarantee is
  missing. **This is the one deferred layer.**
- ~~Decide where the allowlist lives~~ — **decided:** both gates, AND-ed. A
  checked-in name-pattern allowlist (`alpha`, `dev`, `pr-*`) **and** the target's
  own `Pulumi.<stack>.yaml` declaring `reventless:wipeable: "true"` (read via
  `pulumi config get`, not a stack output). A stack must satisfy both.
- IAM: the wipe principal needs tagging-API read + table item-delete + bucket
  empty, scoped by tag condition where possible. (Operator-supplied; not codified
  here.)

## What was built (Option 2, this change)

A guarded reset now ships in **`reventless-seed-aws`** — the same package that
owns the AWS `connect`, so a reset entry point reads like the seed entry point
beside it. It gains a `rescript-aws-sdk` dependency (the connect path stays
SDK-free; the reset path is the AWS-SDK consumer).

- **`ReventlessSeedAws_Reset.run(~stack?, ~backend?, ~targets, ())`** — the caller
  passes the deployment's Pulumi projects as `targets` (each `{projectDir, label,
  group: Domain | Platform}`), because a deployment is several projects sharing a
  stack name (platform + one per domain plugin), each its own `reventless:platform`.
  Flow: resolve the shared stack → gate 1 name allowlist → **scope menu** (`domain`
  = all plugins, first/default; each single plugin; `platform`; `everything`;
  `SEED_RESET_SCOPE` overrides) → for each selected project: gate 2
  `reventless:wipeable` + region → discover by tag → aggregate dry-run report →
  confirm → truncate + empty → verify empty. Wiping `domain` alone leaves the
  platform's plugin registry intact, so the store stays re-seedable.
- **Discovery** via the **Resource Groups Tagging API** (new
  `AwsSdk.ResourceGroupsTaggingApi` binding), filtered on **both**
  `reventless:platform = <project>` and `reventless:environment = <stack>` (see
  the enabling-fact note above on why `environment` alone is insufficient),
  paginated and sorted by name. Each returned resource is re-checked to carry both
  tags before any delete (layer 4); a mismatch aborts the whole run.
- **Truncate** each DynamoDB table: `DescribeTable` (new binding) for the key
  schema → key-only `Scan` → `BatchWrite` deletes in 25s, retrying
  `UnprocessedItems` (capped). **Empty** each S3 bucket: `ListObjectVersions`
  (now also reads `DeleteMarkers`) → `DeleteObjects` (new binding) in 1000s.
- **Dry-run is the default.** Interactively, re-typing the exact stack name at the
  prompt is the confirmation (the allowlist + wipeable + tag checks plus a
  deliberate keystroke are enough — no env var). Without a TTY (CI),
  `REVENTLESS_WIPE_CONFIRM=<stack>` is the equivalent opt-in. Either way, anything
  short of a match deletes nothing. Afterwards it re-counts every store and asserts
  0 — the SDK-native inverse of the post-seed `verifyViews` (the reset has no
  GraphQL connection, so it proves emptiness against the tables/buckets directly).
- **Auth is the ambient AWS credential chain** (env / profile / SSO), the same
  `pulumi` uses — not the Cognito app login `connect` prompts for. A wipe is an
  infrastructure operation on DynamoDB/S3, so there is no username/password.
- **Wired into the hybrid example:** `pnpm run seed:reset` (`src/SeedAwsReset.res`)
  in `examples/online-shop-hybrid/platform-aws` declares its three projects
  (catalog, ordering, platform). All nine example alpha stacks — every project
  (platform + catalog + ordering) across the three examples (aggregates, dcb,
  hybrid) — declare `reventless:wipeable: "true"` in `Pulumi.alpha.yaml` (alpha is
  disposable; `Pulumi.main.yaml` omits it, so main is refused at gate 2 even
  though it also fails gate 1).

### Still open after this change

- Layer 1 (separate prod account) — the deferred structural guarantee.
- Layer 5 (DynamoDB `deletionProtectionEnabled` / S3 without `forceDestroy` on
  prod) — not set; protects table *deletion* (the infra-reset path), complements
  the item-delete guards here.
