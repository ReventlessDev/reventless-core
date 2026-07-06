# Plan: deployed-Lambda ESM self-containment (unblock the AWS runtime path)

**Status**: Active (2026-07-06). **Blocking** — the entire `reventless-aws`
deployed-Lambda runtime is non-functional on real AWS until Phase 1 lands.
**Nature**: framework fix (deploy-time bundling + Lambda module resolution),
followed by an optional consistency refactor.

## Motivation — the bug (found via a real-AWS Rung-2 deploy, 2026-07-06)

A throwaway `PgConnection` deploy (the "Rung 2" check from the AWS-Postgres plan)
put the A3 migration Lambda on real AWS for the first time. The
`aws.lambda.Invocation` failed at cold start:

```
ERR_MODULE_NOT_FOUND: Cannot find package '@reventlessdev/reventless-aws'
imported from /var/task/index.mjs
```

**Root cause (confirmed empirically — the layer *contained* the package and was
*attached* to the Function):** Lambda layers expose packages at
`/opt/nodejs/node_modules`. CommonJS `require` finds that path via `NODE_PATH`
(which Lambda sets), but **ESM `import` of bare specifiers does NOT consult
`NODE_PATH` or `/opt`** — it only walks `node_modules` upward from the importing
file (`/var/task`). Every deployed entry point is ESM (`.mjs`), so every
bare-specifier import of a layer-only package fails.

## Scope — this is the whole deployed ESM path, not one Lambda

Confirmed by reading every builder + `Util_Bundle` (see Sources):

- **`Util_Bundle.buildCodeArchive` never bundles transitive deps.**
  `walkDir`/`createFilteredPackageArchive` include only a named package's own
  `*.mjs`/`*.js`/`package.json` and **explicitly skip `node_modules/`**. Only
  `effect` is auto-co-bundled, and only when `reventless-aws` is present. The
  pnpm layout is `node-linker=hoisted`, so packages have no nested
  `node_modules` to walk anyway.
- **Every entry point statically imports at least one layer-only bare
  specifier** — `@reventlessdev/reventless-core` universally, plus `effect`,
  `sury`, `@aws-sdk/*` depending on the entry point:
  - *Empty `packageDirs` (fully layer-only):* `PgMigration`,
    `PgChangeFeedRelay`, `EventCollector*`.
  - *Bundle only user spec/behavior* (still need core/effect/sury from the
    layer): all `Aggregate*` (Single/Async/PerAggregate/Micro), `Automation`,
    `SideEffect`, `ExtensionPoint*`, `Task`, `ReadModel`.
  - *Co-bundle `reventless-core` + `reventless-aws`* (`StateChangeSlice`,
    `StateViewSlice`) — still need `effect`/`sury` from the layer.
- **No git/test evidence the deployed Lambda path ever ran end-to-end on AWS.**
  This squares with the repeated "AWS boundary unvalidated" caveat across the
  B-phase plans: the deployed path (DynamoDB *and* Postgres) has almost certainly
  never resolved its deps on real AWS. The Postgres work (B1/B2/B3) is correct at
  the wiring level but sits on top of this latent, pre-existing gap.

### Two resolution axes any fix must cover
1. **Static closure** — the entry point's own imports (`→ reventless-core`,
   `reventless-aws`, `effect`, `sury`, `@aws-sdk/*`, and for Postgres
   `reventless-postgres` + `pg`).
2. **Dynamic closure** — entry points cold-start-`import()` the user
   spec/behavior modules from runtime paths in `HANDLER_CONFIG`
   (`AggregateEntryPoint.mjs:20`: `import('/var/task/node_modules/' +
   specifier)`). **Those user modules import bare specifiers too** (core, effect,
   sury), so whatever fixes axis 1 must also make axis 2's imports resolvable.

---

## Phase 1 — ESM self-containment (the blocker)

### 1a. Choose the resolution mechanism (spike first)

Three viable approaches; each must handle **both** axes. Recommendation: spike
Option C first (smallest, preserves the layer), fall back to A.

**Option A — esbuild-bundle.** Bundle each entry point's static closure into one
self-contained `index.mjs` (`@aws-sdk/*` left external — the Lambda runtime
provides v3; verify it resolves under ESM, else bundle it too). Bundle each
dynamically-loaded user spec/behavior module into a self-contained file at deploy
time and place it where the entry point imports it. Prior art: `esbuild` is
already a dep and `rescript-pulumi-aws/scripts/bundle-resolvers.mjs` already
esbuild-bundles `.res.mjs`; and `reventless-layer-builder/src/Main.res` notes
esbuild "was used for deploy-time bundling, replaced by compiled EntryPoint
modules" — i.e. removing esbuild is precisely what introduced this bug.
- *Pro:* self-contained, tree-shaken, layer becomes unnecessary for app code,
  standard Lambda practice.
- *Con:* must bundle both entry points and every user module; dynamic-import path
  contract must be re-established; most work.

**Option B — ship the full closure in `/var/task/node_modules`.** Have
`Util_Bundle` copy the complete framework + transitive tree (reventless-core,
-aws, -postgres, effect, sury, @rescript/runtime, rescript-\*, pg, …) into the
archive's `node_modules` — essentially the layer's contents per-Lambda.
- *Pro:* conceptually simple; both axes resolve from `/var/task/node_modules`; no
  esbuild.
- *Con:* bloats every Lambda (~layer size each); risks the 250 MB unzipped limit;
  replicates the layer builder's dependency walk; defeats the layer's purpose.

**Option C — an ESM resolver hook that falls back to the layer (recommended
spike).** Ship a tiny loader in each archive and set
`NODE_OPTIONS=--import file:///var/task/layerResolver.mjs`; the loader registers
a `resolve` hook that, for a bare specifier Node can't resolve from `/var/task`,
retries against `/opt/nodejs/node_modules/<specifier>`. Wire the loader asset +
env var once in `RuntimeEnvironment_Lambda.makeFromCodeAsset`.
- *Pro:* smallest change; **keeps the layer** (dedup, size); fixes both axes
  uniformly (static and dynamic imports both hit the hook); no per-Lambda bloat;
  no esbuild.
- *Con:* depends on Node 22 loader hooks working under Lambda's `nodejs22.x` with
  `--import` via `NODE_OPTIONS` — must be proven on a real deploy before
  committing. (A symlink `/var/task/node_modules/@reventlessdev →
  /opt/nodejs/node_modules/@reventlessdev` in the archive is a cruder variant;
  Pulumi asset-archive symlink support is uncertain — treat as a last resort.)

**Decision gate:** a one-Lambda spike (reuse the Rung-2 `PgConnection` harness —
it's the cheapest real-AWS check) deploying with Option C. Green → adopt C.
Flaky → fall back to A. Record the outcome here before 1b.

### 1b. Implement across the surface
- Apply the chosen mechanism in the **one** shared seam where possible
  (`RuntimeEnvironment_Lambda.makeFromCodeAsset` for Option C's loader+env; or
  `Util_Bundle.buildCodeArchive` for A/B), so all ~16 entry points inherit it
  without per-builder edits.
- For Option A specifically, add an esbuild step to `buildCodeArchive` and a
  user-module bundling pass; keep `@aws-sdk/*` external.
- Leave the Reventless layer in place (still useful for CJS paths / size) unless
  Option A makes it fully redundant — decide during 1b.

### 1c. Validate on real AWS (the whole point)
- **Rung 2** — re-run the `PgConnection`-only harness; a green `pulumi up` proves
  the migration Lambda fetches the secret and runs `ensureSchema` in-VPC.
- **Rung 3** — deploy one real plugin (an aggregate + a read model, DynamoDB
  backend) and drive command → projection → query end to end. This validates the
  *default* deployed path, not just Postgres.
- Only after both are green is the deployed runtime actually validated for the
  first time.

---

## Phase 2 — entry-point ReScript conversion (optional, sequenced AFTER Phase 1)

Convert the ~16 hand-written `*EntryPoint.mjs` shims (+ `HandlerFactoryHelpers.mjs`,
`StateTopicPublish.mjs`) to `.res`. **Deliberately deferred behind Phase 1** so a
failed post-change deploy can't be ambiguous between a bundling bug and a
translation bug, and so the conversion targets a *known-good* runtime contract.

- **Feasible:** yes — ReScript can express the env parsing, JSON plumbing, and
  op-binding. The one real friction is the runtime-computed dynamic
  `import('/var/task/node_modules/' + specifier)` — needs a `Js.import` /
  `@val external` binding. That binding is the shared design point already settled
  by Phase 1's dynamic-closure handling.
- **Approach:** one entry-point family at a time (Aggregate, DCB, ReadModel,
  Postgres, …), re-validating each against the working deploy path before the
  next. Keep `HandlerFactoryHelpers` semantics byte-identical.
- **Value is modest** (type safety + one-language consistency) and translation
  risk is real for hand-tuned boot glue — hence optional and incremental, not a
  rider on the fix.

---

## Non-goals
- No new Lambda features or runtime behavior — this is dep-resolution + (Phase 2)
  a language port only.
- Not removing the Reventless layer (unless Option A makes it redundant — decided
  in 1b).
- Not changing the dynamic spec/behavior loading architecture; only making its
  imports resolvable.

## Risks / open questions
- **Option C loader viability on `nodejs22.x`** — the load-bearing unknown; the
  1a spike resolves it before any broad change.
- **`@aws-sdk/*` under ESM** — is the Lambda-runtime-provided v3 SDK resolvable
  from `/var/task` ESM, or must it be bundled/hooked too? Verify in the spike.
- **Lambda size limits** (Option B) — 250 MB unzipped; per-Lambda layer-sized
  bundles could breach it with many packages.
- **This invalidates the "deployed" status of B1/B2/B3** (and the DynamoDB path).
  The AWS-Postgres plan is annotated accordingly; the wiring is correct but
  unrunnable until Phase 1.

## Sources
- Rung-2 finding + teardown: this session (2026-07-06);
  memory `reference_esm_lambda_layer_resolution_gap.md`.
- Bundling: `reventless/reventless-aws/src/util/Util_Bundle.res`
  (`buildCodeArchive`, `createFilteredPackageArchive`, `walkDir`).
- Layer attach: `.../adapter/Runtime/RuntimeEnvironment_Lambda.res:167`.
- Dynamic import: `.../adapter/Runtime/AggregateEntryPoint.mjs:20`.
- esbuild prior art: `rescript/rescript-pulumi-aws/scripts/bundle-resolvers.mjs`;
  `reventless/reventless-layer-builder/src/Main.res` (esbuild "replaced by
  compiled EntryPoint modules").
- Layer contents: `reventless/reventless-layer-builder` (52 deps, incl.
  `@reventlessdev/*`, `pg`, `@rescript/runtime`).
