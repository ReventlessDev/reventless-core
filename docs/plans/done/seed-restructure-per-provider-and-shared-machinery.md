# Restructure seeding: per-provider scripts, reusable machinery, exportable data sets

## Context

The hybrid example's seed today is one interactive script in `platform-local/` that
makes you *pick* local-vs-AWS (`SeedTarget.res`), with all machinery — prompts,
login, discovery, the run loop — living in the app. Three problems drove this
redesign:

1. **A real bug:** the picker creates and closes a readline interface *per prompt*,
   which leaves stdin paused, so the second/third prompt hangs (you hit it right
   after entering the username).
2. **Wrong seam:** the provider is a runtime *choice* when it should be *where the
   script runs* — a `platform-aws` seed script is unambiguously AWS.
3. **No reuse / no sharing:** selection + login + transport are copied per app and
   can't be reused; and a separate downstream repo deploys an `online-shop` whose
   domain matches this core example — so its deployment should be seedable with
   *this* example's data set, which requires the data set to be a shareable,
   published artifact.

Decisions taken (confirmed):
- **A:** AWS connect (Cognito login + Pulumi/config.json discovery) → a new
  published package **`reventless-seed-aws`** (keeps AWS out of the generic package;
  reusable in both repos).
- **B:** Cross-repo sharing → **extract the hybrid seed data into a small publishable
  package**, exporting the data set(s) as values. (This reinterprets the earlier
  "leave it in platform-local": the data stays *app-owned* in the example, but in a
  dedicated package so both platform scripts — and later any downstream consumer —
  import it.)
- **C:** Scope this pass = **core repo only**. Downstream wiring (install the package,
  register the set) is a deferred follow-up.

Outcome: `pnpm run seed` in `platform-local/` seeds local; `pnpm run seed` in
`platform-aws/` seeds the AWS deployment — no provider picker. If more than one
data set exists, the runner prompts which to seed. Login (username/password) is
always required. All generic machinery lives in `reventless-seed`; AWS specifics in
`reventless-seed-aws`; only the domain data + the run closure live in the app.

## Target architecture

```
reventless-seed (generic, published, stdlib-only)
  Seed_Types      + type connection, type dataSet
  Seed_Prompt     NEW: one shared readline interface (fixes hang) — select + credentials + close
  Seed_Connect    NEW: build a connection from endpoints + a login fn (prompts creds, useToken)
  Seed_Runner     + seed(~sets, ~connect): select set → connect → set.seed(conn), via run()
  Seed_Client / Seed_Upload / Seed_Random  (unchanged; keep useToken + optional config)

reventless-seed-aws (NEW package, published, depends on reventless-seed)
  connect(~projectDir=?, ~stack=?): unit => promise<Seed.connection>
    - resolve stack (env SEED_STACK / arg / prompt across Pulumi.*.yaml or `stack ls --all`)
    - endpoints: hostShellUrl→config.json (hybrid shape) else direct stack outputs
    - login: Cognito USER_PASSWORD_AUTH (plain fetch, no SDK) via Seed_Connect

examples/online-shop-hybrid/seed-data (NEW package, publishable)
  DemoData.res, DemoCommands.res      (moved from platform-local/src)
  HybridSeedData.res                  exports `let dataSets: array<Seed.dataSet>`
                                      (each dataSet.seed = the phases + verifyViews + summary)

examples/online-shop-hybrid/platform-local
  SeedLocal.res (thin)  Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=Seed.Connect.local(...))
  package.json          "seed": "node src/SeedLocal.res.mjs"  (rename of demo-data)

examples/online-shop-hybrid/platform-aws
  SeedAws.res  (thin)   Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=ReventlessSeedAws.connect(...))
  package.json          "seed": "node src/SeedAws.res.mjs"
```

## New generic types (in `reventless-seed/src/Seed_Types.res`, re-exported via `Seed.res`)

```rescript
type connection = { client: Seed_Client.t, uploadEndpoint: string, label: string }
type dataSet    = { name: string, label: string, seed: connection => promise<unit> }
```

`dataSet.seed` owns everything domain-specific: the phases, `Seed.Runner.verifyViews`,
and the summary board. The generic runner never sees domain detail.

## New generic modules

### `Seed_Prompt.res` — single shared readline interface (fixes the hang)
- `let select: (~title: string, ~options: array<(string, 'a)>, ~env: string=?) => promise<'a>`
  — auto-returns when `options` has one entry; prints a numbered menu otherwise;
  `env` (e.g. `SEED_SET`) preselects by label/index for CI; TTY-guarded.
- `let credentials: (~localDefaults: bool=false) => promise<(string, string)>`
  — username (visible) + password (echo muted); `REVENTLESS_DEMO_USER`/`_PASSWORD`
  override; `localDefaults` lets empty input fall back to `admin`/`admin`.
- `let close: unit => unit`.
- Internals: one `ref<option<rl>>` created lazily, a `muted` ref that gates
  `_writeToOutput`, closed once. Node bindings (`node:readline`, `process.stdin/stdout`)
  declared here as typed externals (stdlib-only rule; no `%raw`).

### `Seed_Connect.res` — endpoints + login → connection
```rescript
let make: (
  ~label: string, ~endpoint: string, ~uploadEndpoint: string,
  ~login: (~username: string, ~password: string) => promise<string>,   // returns a bearer
) => promise<connection>            // prompts credentials, calls login, Client.make + useToken

let viaLoginEndpoint: (~loginEndpoint: string) => (~username: string, ~password: string) => promise<string>
let local: (~graphql: string=?, ~upload: string=?, ~login: string=?) => (unit => promise<connection>)
```
`local` bakes the localhost defaults (`:4000/graphql`, `:4000/__inmemory/upload`,
`:4000/__inmemory/login`) into a ready `connect` thunk. `viaLoginEndpoint` reuses the
existing `Seed_Client.login` POST-shape but returns the token for `useToken`.

### `Seed_Runner.res` — top-level entry
```rescript
let seed: (~sets: array<dataSet>, ~connect: unit => promise<connection>) => unit
// run(async () => { let s = await Prompt.select(...); let c = await connect(); Prompt.close(); await s.seed(c) })
```
Wraps the existing `run` (keeps the half-seeded abort reporting + `exit(1)`).

## `reventless-seed-aws` (new package, `reventless/seed-aws/`)

- `package.json` name `@reventlessdev/reventless-seed-aws`, deps: `reventless-seed`
  (workspace:*). Publishable (not private). `rescript.json` mirrors reventless-seed
  (esmodule, in-source, namespace `ReventlessSeedAws`, stdlib-only).
- `connect(~projectDir=".", ~stack=?): unit => promise<Seed.connection>`:
  1. **Stack** — `SEED_STACK`/arg, else prompt via `Seed_Prompt.select` over configured
     stacks (`Pulumi.*.yaml` names, or `pulumi stack ls --all --json` filtered to
     platform projects). `pulumi` run via `node:child_process` execFileSync in `projectDir`.
  2. **Endpoints** — read `pulumi stack output --stack <s> --json`. If `hostShellUrl`
     present → fetch `<hostShellUrl>/config.json` for `apiEndpoint`/`uploadEndpoint`/
     `region`/`cognitoClientId` (hybrid shape). Else read `domainMergedApiEndpoint`
     (fallback `domainApiEndpoint`), `cognitoRegion`, `cognitoUserPoolClientId`
     directly; `uploadEndpoint` absent → `""` (data set skips uploads).
  3. **Login** — `Seed_Connect.make(~login=cognito(~region, ~clientId))`, where
     `cognito` does USER_PASSWORD_AUTH via plain `fetch` (no SDK, no SigV4; the
     HostUiClient has no secret). Clear errors for challenge / missing IdToken.

## App changes

### `examples/online-shop-hybrid/seed-data` (new package)
- Move `DemoData.res` + `DemoCommands.res` from `platform-local/src/` unchanged.
- New `HybridSeedData.res`: fold the phases + `views` + summary from today's
  `DemoSeed.res` into `let dataSets: array<Seed.dataSet>`. Each `seed` closure takes
  a `connection` and threads `conn.client` / `conn.uploadEndpoint`. Ship **two** sets
  to exercise selection: `"full"` (today's 8/64/20/150) and a compact `"sample"`
  (small counts via existing `DemoData` builders) — both reuse the same phases.
- Deps: `reventless-seed`, `catalog`, `catalog-spec`, `ordering`, `ordering-spec`
  (workspace:*) — same domain deps DemoData/DemoCommands already require.

### `platform-local`
- Delete `DemoSeed.res`, `SeedTarget.res`; drop the moved `DemoData.res`/`DemoCommands.res`.
- Add `SeedLocal.res` (thin entry above). Add dep on the seed-data package.
- `package.json`: `"demo-data"` → `"seed": "node src/SeedLocal.res.mjs"`.

### `platform-aws`
- Add `SeedAws.res` (thin entry). Add deps: seed-data package, `reventless-seed`,
  `reventless-seed-aws` (workspace:*).
- `package.json`: add `"seed": "node src/SeedAws.res.mjs"`.

## Reused existing code
- `Seed_Client.login` / `useToken` / optional `config` fields (already added this session).
- `Seed_Runner.run` / `verifyViews` / `report` / `heading` / `warn` / `unfillableWarnings`
  / `view` variant — unchanged; the data set's `seed` calls `verifyViews`.
- `Seed_Upload.uploadAsset` — unchanged; called by the data set when `uploadEndpoint != ""`.
- `Seed_Random` — unchanged; deterministic generation stays in `DemoData`.

## Files to touch (representative)
- Add: `reventless/seed/src/Seed_Prompt.res`, `Seed_Connect.res`; edits to
  `Seed_Types.res`, `Seed.res`, `Seed_Runner.res`.
- Add package: `reventless/seed-aws/` (`package.json`, `rescript.json`, `src/*.res`).
- Add package: `examples/online-shop-hybrid/seed-data/` (`package.json`, `rescript.json`,
  `src/DemoData.res`, `src/DemoCommands.res`, `src/HybridSeedData.res`).
- Edit: `platform-local/{package.json, src/SeedLocal.res}`, remove old seed src.
- Edit: `platform-aws/{package.json, src/SeedAws.res}`.
- Docs: `examples/online-shop-hybrid/README.md`, `packages/doc/docs-app/seeding-guide.md`,
  `packages/doc/docs-tutorials/test-on-aws.md` — reflect the two per-provider `seed`
  commands + data-set selection. Update root `.res.mjs` build-chain notes if a new
  build-root is needed (`CLAUDE.md` §`.res.mjs tracking`).

## Verification
- **Build:** `pnpm install` (new workspace packages) then root `pnpm run build`; grep
  the output for `Warning|error` (zero-warnings rule). Confirm the new packages compile
  and the two app `Seed*.res.mjs` entries emit.
- **Local, end-to-end (real):** `cd platform-local && pnpm run serve:reset` (one shell),
  `pnpm run seed` (another) → set-selection menu appears, prompts user/pass
  (admin/admin), seeds a fresh store green; verify views non-empty and the summary
  board prints. Re-run without reset → the documented non-idempotent abort.
- **Prompt hang:** confirm entering username → password no longer hangs (single
  shared interface).
- **Non-interactive:** `SEED_SET=full REVENTLESS_DEMO_USER=admin REVENTLESS_DEMO_PASSWORD=admin pnpm run seed`
  runs with no prompts.
- **AWS path:** builds and runs `SeedAws.res`; discovery/Cognito unit-exercised against
  a stack via `pulumi stack output`. NOTE: the core hybrid is **not** currently deployed
  to the backend (a separate downstream `online-shop` deployment holds that slot), so a
  full on-AWS core seed can't be exercised this pass — limited to build + discovery wiring.

## Deferred (not this pass)
- Downstream consumer wiring: a separate repository deploys an `online-shop` that
  consumes the **same published `online-shop-hybrid-catalog`/`-ordering` packages** as
  this example — so the core data set's commands match its deployment verbatim — yet
  currently has **zero seeding** (no `seed` script, no reventless-seed dep).
  Follow-up: add `platform-local`/`platform-aws` `seed` scripts there that install the
  published `online-shop-hybrid-seed` + `reventless-seed-aws` and register both any
  consumer-specific sets and the core set. That deployed platform exports no
  `uploadEndpoint`, so the data set's upload phase must no-op when
  `uploadEndpoint == ""` (built for in this pass).
- On publish: `workspace:*` deps in the new packages are rewritten to real versions by
  the release tooling (pnpm/lerna) — standard; nothing special to do now.
- Actually publishing the new packages to npm — build/wire now, publish when releasing.
