# Online Shop — Hybrid example

A complete, working Reventless application: a small online shop modelled with a
**hybrid** plugin style — aggregates for self-contained entities (Customer) and
DCB slices for entities that take part in cross-slice invariants (Category,
Product + ProductDemand, Order + CatalogProduct). Adding a product verifies —
inside its decision model — that the referenced category exists and is active,
which is exactly why Category is modelled as DCB slices writing to the shared
catalog event log: a DCB slice can read a sibling slice's events, but not an
aggregate's isolated log. It runs locally on the local platform and deploys to
AWS with Pulumi, exercising commands, events, projections, live subscriptions,
and cross-plugin extension points end to end.

This is the package behind the documentation
[Tutorial spine](../../packages/doc/docs-tutorials/get-started.md).

## Packages

| Package | Role |
|---|---|
| `catalog-spec/` | Catalog's public extension-point contract (`Products`) — depended on by Ordering |
| `ordering-spec/` | Ordering's public extension-point contract (`Orders`) — depended on by Catalog |
| `catalog/` | Catalog plugin: Category, Product, and ProductDemand DCB slices (AddProduct verifies the referenced category exists); StateView stream views; task; EP + extension |
| `ordering/` | Ordering plugin: Customer aggregate; Order/CatalogProduct DCB slices; the `Customers` mixed aggregate+DCB read model (profile + order count); automation; outbound email; EP + extension |
| `catalog-aws/`, `ordering-aws/` | AWS deployment entry points for each plugin |
| `platform-local/` | Local dev runtime — GraphQL server + in-memory stores |
| `platform-aws/` | AWS platform: shared AppSync API, admin components, scheduler, host-shell SPA |

`src/Plugin.res` in each plugin is **generated** by `generate-plugin src/` (a
`prebuild` step) — it is committed but never hand-edited.

## Run it locally

On a fresh clone, bootstrap once from the **repo root** (creates the workspace
config, installs, ensures the PPX binary, seeds dev users, builds this example):

```bash
pnpm run setup        # see the root README "Getting Started"
```

Then, from this example:

```bash
cd platform-local
pnpm run serve        # backend only: GraphQL (:4000/:4001) + MCP (:3001/:3002)
# or, with the host-shell UI (requires reventless-host-shell):
pnpm run dev:full     # backend + host-shell UI (:5180), with live reload
```

`dev:full` recompiles and restarts the backend on any `.res` change (live
reload). Stores default to **on-disk SQLite** (`./.reventless/local.db`, persists
across restarts); use `serve:memory` / `dev:full:memory` for stateless runs or
`serve:reset` / `dev:full:reset` for a clean boot. The backend logs at
`LOG_LEVEL=debug` by default (set `LOG_LEVEL=info` to quieten). See
[docs/guides/local-dev.md](../../docs/guides/local-dev.md) for the full matrix.

`pnpm run build` rebuilds after source changes. `setup` seeds four accounts into
`platform-local/.reventless/users.yaml` from the committed
[`users.example.yaml`](platform-local/users.example.yaml), one per role the shop
distinguishes (password = username):

| Account | Groups | What it is for |
| --- | --- | --- |
| `admin` | `Admin`, `Shopper` | Everything, including the platform's own admin surfaces |
| `shopper` | `Shopper` | Browses the catalog, places and cancels its **own** orders |
| `merch` | `Merchandiser`, `Shopper` | Maintains products, categories, prices, images, demand |
| `fulfil` | `Fulfilment`, `Shopper` | Works the order board and ships orders |

`Merchandiser` and `Fulfilment` are both operator roles, and they need different
things: shipping orders means reading rows that belong to customers, while
editing a product reads nothing anybody owns. So `Storefront.elevatedGroups`
names `Fulfilment` and `Admin` and not `Merchandiser` — that list answers one
question only, which of these roles reads across owners.

Each role also gets its own menu rather than a share of one. The shop declares a
storefront for everybody and a journey per operator role, so `merch` and `fulfil`
discover the surfaces their job needs — and, being elevated by something other
than `Admin`, `fulfil` reads its board from its own journey file without ever
approaching the admin API.

The menu says whose rows it is showing, too. `Orders` carries an `@owner` field,
so `ui-hints.json` states both phrasings — `label: "All Orders"` and
`scopedLabel: "My Orders"` — and the shell picks by the scope it already
resolved: `shopper` reads its own rows and sees "My Orders", `fulfil` reads every
customer's and sees "All Orders". Keyed on the scope rather than the role, so it
stays right for whatever `Storefront.elevatedGroups` names next.

That curation covers the pages a shell *builds* as well as the views a plugin
declares. `Orders` carries a status and dated delivery windows, so the shell can
draw a lifecycle diagram and a calendar of the same rows. `Storefront.manifest`
gives those to `Fulfilment` (`derived: ["lifecycles", "canvas"]`) and to nobody
else, which is why a shopper's menu is one group called Shop rather than that
plus one called Ordering — a page built across a plugin's views belongs to no
view, so nothing in `ui-hints.json` could have named it into place.

Every account but `shopper` holds a second group on purpose: they are the logins
where the role switcher has something to show. Acting as `Fulfilment`, `fulfil`
reads every customer's orders and may ship them; acting as `Shopper`, the same
account reads only its own and the API refuses `ShipOrder` outright — the switch
narrows the token, so the menu, the data and what the server accepts all agree.

Via the UI, use the LoginPage; against the backend directly:

```bash
curl -s -X POST http://localhost:4000/__inmemory/login \
  -H 'content-type: application/json' -d '{"username":"admin","password":"admin"}'
```

Walkthrough: [Run it locally](../../packages/doc/docs-tutorials/run-locally.md) ·
[Test it locally](../../packages/doc/docs-tutorials/test-locally.md).

## Seed demo data

Every view starts empty, which makes "the component is broken" and "there is no
data" look identical. `seed` fills them — the `full` set is 8 categories, 64
products, 20 customers and 150 orders — by driving the example's own GraphQL
mutations. The provider is **where you run it**, not a prompt: `pnpm run seed` in
`platform-local/` seeds the local dev platform, and in `platform-aws/` it seeds
the deployed stack.

```bash
cd platform-local
pnpm run serve:reset     # in one shell — a clean store
pnpm run seed            # in another — pick a data set, then an account
```

Two data sets ship, so the run first asks which to seed: `full` (above) and a
compact `sample` (16 products, 8 customers, 40 orders) for a quick check. It then
asks **which account to seed as**, listing the ones in that platform's
`.reventless/users.yaml` in the order the file defines them — Enter takes the
first. The file records the password beside the username, so nothing is typed;
local sends both to the dev `/__inmemory/login` route, AWS to Cognito. A platform
that keeps no such file prompts for a username and password instead.

Which account matters: owner-scoped rows are keyed to whoever seeded them, so the
orders `shopper` creates are the orders `shopper` sees. `SEED_USER` picks by
username or 1-based index, and `SEED_USERS_FILE` points at a file elsewhere.

Generation is deterministic (fixed PRNG seed, fixed literal data), so a reset
plus a re-run reproduces the same rows. There is no idempotence logic: run it
against a fresh store, not on top of an existing one.

For a non-interactive run (CI), set `SEED_SET` (`full` or `sample`) plus
`REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD` to skip every prompt — those
two together bypass the accounts file entirely, so CI needs no copy of it. Add
`SEED_SKIP_UPLOADS=1` to seed the domain data without product images (the
optional `imageUrl` is then simply absent) — handy when a deployment serves no
upload endpoint.

Because it goes through the public command API rather than writing to the store,
it doubles as a smoke test — and it is **domain-coupled by design**. The seed is
built from real plugin command values (`AddProduct.command`,
`PlaceOrder.command`, …), so a renamed or re-shaped command breaks the build
rather than seeding states the domain can no longer reach.

The domain data is a shareable package, [`online-shop-hybrid-seed`](seed-data),
so both platform scripts import the same sets:

| File | Role |
|---|---|
| `seed-data/src/DemoData.res` | *What* to seed — literal data and the deterministic generation that turns it into categories, products, customers and orders |
| `seed-data/src/DemoCommands.res` | The adapter — how this example's command values map onto GraphQL mutation fields and arguments |
| `seed-data/src/HybridSeedData.res` | The data sets — phases, view verification, and the summary, exported as `Seed.dataSet` values |
| `platform-local/src/SeedLocal.res` | Thin entry — `Seed.Runner.seed` with the local connection |
| `platform-aws/src/SeedAws.res` | Thin entry — `Seed.Runner.seed` with the AWS connection |

The transport, prompts, connection, deterministic randomness, view checks and
failure reporting are generic and live in
[`@reventlessdev/reventless-seed`](../../reventless/seed); the AWS connect (stack
discovery + Cognito login) lives in
[`@reventlessdev/reventless-seed-aws`](../../reventless/seed-aws). Neither package
knows about this domain.

The order data is shaped by the shipping method each order is placed with, which
is what makes the lifecycle visible: `Express` orders are auto-shipped by the
`AutoShipOrder` automation, most `Standard` orders are shipped by a batch-dispatch
phase, and the remaining `Standard` and `Pickup` orders stay `Placed` — so a
share of them can then be cancelled. The run prints the resulting
`status` × `shippingMethod` breakdown.

Every queryable view ends the run non-empty, including
`SendOrderConfirmationTodos` — one row per placed order, each `Completed` once
the `SendOrderConfirmation` OutboundTranslationSlice has called `EmailService`.

## Deploy it to AWS

Deploy the platform stack first, then the plugins (Pulumi):

```bash
pnpm install && pnpm run build          # from the repo root

cd platform-aws && pulumi up --stack alpha
cd ../catalog-aws && pulumi up --stack alpha
cd ../ordering-aws && pulumi up --stack alpha   # depends on catalog
```

Before deploying, point the stack configs at your own Pulumi org and review the
Cognito + host-shell settings — see
[Deploy to your AWS account](../../packages/doc/docs-tutorials/deploy-to-aws.md)
and [Test it on AWS](../../packages/doc/docs-tutorials/test-on-aws.md).

## Seed the deployed shop

Run [`pnpm run seed`](#seed-demo-data) from `platform-aws/` — it targets AWS by
construction. It picks the stack (or `SEED_STACK`), discovers the endpoints from
the stack's published `config.json` (or its stack outputs), and signs in against
Cognito with the account you pick from `platform-aws/.reventless/users.yaml`.
That account must exist in the stack's pool with a permanent password, and the
file is the record of the ones that do — see
[Test it on AWS](../../packages/doc/docs-tutorials/test-on-aws.md). As locally,
the seed is **non-idempotent** — run it against a fresh deployment.

```bash
cd platform-aws
pnpm run seed            # pick a data set and stack, then an account
```

### Reset a deployed stack to re-seed

The seed is one-shot, so re-seeding a deployed stack means emptying it first.
`seed:reset` truncates a project's DynamoDB tables and empties its S3 buckets —
the inverse of seeding — and is deliberately hard to fire by accident.

The hybrid deploys as **three Pulumi projects** sharing a stack name — the
platform plus the `catalog` and `ordering` plugins — so the reset first asks
**which scope** to empty:

```
Reset scope:
  1) domain — catalog, ordering     ← default: the seeded business data
  2) catalog
  3) ordering
  4) platform — platform            ← plugin registry etc.; leave it to re-seed
  5) everything — platform + catalog + ordering
```

Wiping `domain` leaves the platform's plugin registry intact, so a re-seed just
works — that's the normal choice. `SEED_RESET_SCOPE=domain|platform|everything|<plugin>`
picks non-interactively. Each chosen project then passes the same gates:

- it refuses any stack not named `alpha`, `dev`, or `pr-*`, **and** any project
  whose `Pulumi.<stack>.yaml` does not declare `reventless:wipeable: "true"` (the
  example's `alpha` stacks opt in; `main` does not, so it is refused);
- it finds what to empty only through the `reventless:platform` +
  `reventless:environment` tags the framework stamps on every resource — scoped
  to each chosen project's stack, so a same-named stack from another project in
  the account is not touched — and re-checks both per resource before deleting;
- it is **dry-run by default** — it lists the tables and buckets it would empty
  (per project) with their row/object counts, and stops. To actually empty them,
  **re-type the stack name** at the prompt; then it re-counts every store to prove
  it is empty. (Non-interactively — CI, no TTY to type into — set
  `REVENTLESS_WIPE_CONFIRM=<stack>` instead.)

Once confirmed, the reset **holds the stack still** for the length of the wipe.
A truncate is not durable while the runtimes that own the data are running: a
slice runtime keeps its TODO list in memory for the life of its execution
environment and re-saves every row it holds at the end of each invocation —
including the scheduled sweep, which carries no events. So an unheld wipe of such
a table succeeds and is then undone, byte for byte, within a sweep interval.

So the reset reserves **zero concurrency** on every Lambda function in the chosen
scope before the first delete, empties and verifies while nothing can start, and
then **recycles** each function — a marker environment variable added and
immediately removed, which is what makes Lambda discard the execution
environments still holding pre-wipe state. Concurrency and environment are
restored exactly as they were, on the failure path as well as the success path,
so `pulumi preview` reports no drift afterwards.

That needs `lambda:GetFunctionConcurrency`, `lambda:GetFunctionConfiguration`,
`lambda:PutFunctionConcurrency`, `lambda:DeleteFunctionConcurrency` and
`lambda:UpdateFunctionConfiguration` in addition to the DynamoDB, S3 and tagging
permissions. Credentials without them get a refusal that names the missing
actions, before anything is deleted. `SEED_RESET_NO_QUIESCE=1` wipes without the
hold — but a running runtime can then write straight back over an emptied store,
and the reset says so.

```bash
cd platform-aws
pnpm run seed:reset            # pick a scope, see the dry run, type the stack name to confirm
pnpm run seed                  # re-seed the now-empty stack

# non-interactive (CI): scope + confirm come from the environment
SEED_RESET_SCOPE=domain REVENTLESS_WIPE_CONFIRM=alpha pnpm run seed:reset
```

The reset authenticates to AWS with your **ambient credentials** (env / profile /
SSO) — the same ones `pulumi` uses — not the Cognito login `pnpm run seed` prompts
for, so there is no username/password. The region is resolved from `AWS_REGION` or
each stack's `aws:region` config. Every refusal names its cause, so a rejected
reset says exactly why.

## Learn the model

Read the [Hybrid walkthrough](../../packages/doc/docs-tutorials/hybrid-based.md)
for the full domain model — every command, event, read model, slice, and the
cross-plugin extension-point protocol.
