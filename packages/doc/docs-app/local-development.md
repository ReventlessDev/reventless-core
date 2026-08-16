---
title: Run and deploy
sidebar_label: Run and deploy
---

# Run and deploy your application

The same application code runs in a single local process and on AWS. Develop
against the local platform — it needs no cloud account, starts in seconds, and
behaves like production — then deploy the identical plugins.

## The entry point

A platform root is short. It picks a platform, builds the plugins over it, and
starts the servers:

```rescript
module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)

Platform.startServers()
```

Swapping `ReventlessLocal.Platform` for `ReventlessAws.Platform` is what moves
the same plugins to AWS — see [Deploying to AWS](#deploying-to-aws) below.

## Running it

```bash
pnpm run build      # compile; re-run after source changes
pnpm run serve      # start the platform
```

Add `GRAPHQL_DEBUG=1` and `MCP_DEBUG=1` (or use a `dev` script that sets them) to
log every request. For a watch loop, run the ReScript compiler in watch mode
alongside the server so a saved file restarts it.

### Ports

The local platform serves the **domain** API and the **platform/admin** API
separately by default:

| Service | Default port |
|---|---|
| GraphQL — domain (your plugins) | 4000 |
| GraphQL — platform/admin | 4001 |
| MCP — domain | 3001 |
| MCP — platform/admin | 3002 |

Override with `REVENTLESS_DOMAIN_PORT`, `REVENTLESS_PLATFORM_PORT`,
`REVENTLESS_DOMAIN_MCP_PORT`, and `REVENTLESS_PLATFORM_MCP_PORT`.

### Split versus unified API

Splitting the two APIs keeps administrative operations (activating plugins,
cloning) off the endpoint your application clients talk to. It is worth having
because it gives you a boundary to restrict later, and because an AI assistant
pointed at the domain endpoint sees only domain tools rather than platform
administration.

To serve everything from one endpoint instead:

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
  let silent = false
  let splitApi = false
})
```

In unified mode all schema is served from port 4000, and all MCP tools from 3001.
On AWS, split mode is the default and provisions a dedicated admin API.

## Storage backends

The local platform keeps state in memory by default, which is what you want for
tests — every run starts clean. For development, a SQLite file lets data survive
restarts:

```bash
REVENTLESS_LOCAL_BACKEND=memory                          # nothing persisted
REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db   # persistent
REVENTLESS_LOCAL_BACKEND='sqlite:./.reventless/local.db?reset'  # wiped on start
```

or pick it in code with `Backend.Memory` / `Backend.Sqlite({path, resetOnStart})`
via `MakeWithConfig`. The platform logs which backend it chose at startup. See
[local persistence](/infrastructure/local-persistence) for the on-disk format —
it is an ordinary SQLite file you can open with `sqlite3` and inspect.

Committing a small `local.db` as a fixture is a reasonable way to share a
deterministic demo dataset with collaborators.

## Users and authorization locally

Reventless is authenticated by default: commands and queries expect a caller.
Locally, users come from a YAML file at `.reventless/users.yaml` — gitignored, and
seeded from a committed `users.example.yaml` template:

```yaml
- username: admin
  password: admin
  groups: [Admin, Shopper]
  userId: local-admin

- username: shopper
  password: shopper
  groups: [Shopper]
  userId: local-shopper
```

Each entry needs `username`, `password`, and `groups` (an empty list means
unprivileged); `userId` defaults to the username. The file is read relative to
the process working directory at startup, so restart the server after editing it.

Sign in through the shell's login page to exercise group-based rules. Give
yourself one account per role you have defined — the useful test is not "does
admin work" but "does each role see exactly its own surfaces".

Two shortcuts exist for convenience, and it is worth knowing which is which:

- A request with **no** `X-User` header falls back to an unprivileged
  `defaultUser`, so casual local browsing works without logging in.
- A request **with** an `X-User: admin` header is treated as that user, which is
  what makes `curl` testing practical.

Neither exists on AWS, where Cognito issues the identity. To test what an
administrator sees, log in as one rather than granting the fallback user extra
groups — otherwise you are testing a configuration that will never be deployed.

## Exploring the API

Open `http://localhost:4000/graphql` in a browser for the GraphiQL explorer: it
lists every command as a mutation, every view as a query and a subscription, with
fields prefixed per plugin (`Catalog_…`, `Ordering_…`). It is the fastest way to
discover the exact field names your specs produced.

From the command line:

```bash
curl http://localhost:4000/graphql \
  -H 'content-type: application/json' \
  -H 'X-User: admin' \
  -d '{"query":"mutation { Catalog_AddCategory(categoryId: \"books\", name: \"Books\") { __typename } }"}'
```

Command mutations return a result union, so they need a selection set; view
queries return a Relay-style connection (`edges { node { … } }`). See the
[GraphQL API guide](./graphql-api-guide.md) for the full shape.

Your application also exposes the same commands and views over
[MCP](https://modelcontextprotocol.io/), so an AI assistant can drive the running
application through the same authorization rules a person gets.

## Seeding data

Rather than clicking through the UI after every reset, drive your own seed
through the public command API — the same door a client uses, so seeded data goes
through the same validation and produces the same events. See the
[seeding guide](./seeding-guide.md).

## Deploying to AWS

When you are ready for the cloud, the application code does not change — only the
platform module and a deployment package around it:

- [Deploy the example to your AWS account](/tutorials/deploy-to-aws) — the
  worked, end-to-end version, including cost and teardown
- [AWS provider guide](/infrastructure/aws/) — the `-aws` package structure, the
  Lambda layer, stack configuration
- [Deployment guide](/infrastructure/deployment-guide) — multi-plugin deploys,
  adding and removing plugins, cross-plugin wiring
- [Custom domain](/infrastructure/custom-domain) — serving the UI from your own
  hostname
