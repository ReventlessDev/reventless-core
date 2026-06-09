---
title: Run it locally
sidebar_position: 4
---

# Run the online shop locally

You can run the entire hybrid online shop on your machine — no AWS account, no
cloud resources. The `reventless-local` platform runs the same plugin code
the AWS platform runs, backed by a local store (SQLite by default, persisted to
`.reventless/local.db`) and a local GraphQL server.

Everything in this page happens inside
[`examples/online-shop-hybrid/platform-local/`](https://github.com/ReventlessDev/reventless-core/tree/main/examples/online-shop-hybrid/platform-local).

## Prerequisites

- Node v22.17.1 (see `.node-version`) and pnpm 10 (via `corepack`).
- A checkout of `reventless-core`. You do **not** need the UI source — the local
  UI is provided by the published `reventless-host-shell` package.
- A GitHub Package Registry token with `read:packages` for `@reventlessdev/*` — the
  first `pnpm install` pulls published packages (e.g. `reventless-host-shell`). See
  [Registry and Tokens](/framework/registry-and-tokens).

## One command

```bash
cd examples/online-shop-hybrid/platform-local

pnpm run build      # once, and after any source change
pnpm run dev:full   # backend + UI together
```

`dev:full` starts three processes side by side (colour-coded `[rs]` / `[backend]` / `[ui]`):
a ReScript watcher that recompiles on change, the backend, and the UI dev server. The backend
exposes two endpoints:

| Process | What it is | URL |
|---|---|---|
| `[rs]` ReScript watch | Recompiles plugin/framework sources on change | — |
| `[backend]` — domain API | Plugin queries, mutations, subscriptions | `http://localhost:4000/graphql` |
| `[backend]` — platform/admin API | `Admin_*` queries, platform introspection | `http://localhost:4001/graphql` |
| `[ui]` dev server | `reventless-host-shell` (the Auto UI shell) | `http://localhost:5173` |

Open **http://localhost:5173** and you have the running shop: create categories
and products, register customers, place orders, and watch read models update
live via subscriptions.

:::info Where does the UI come from?
`dev:ui` (which `dev:full` calls once the backend is up) launches the
`reventless-host-shell` binary by default. A fresh checkout has no local
`reventless-ui` directory, so nothing else is needed. If you are a UI contributor
with the UI source checked out beside the package, `dev:ui` uses that instead.
:::

## Running the pieces separately

If you want each process in its own terminal:

```bash
# Terminal 1 — backend only
pnpm run serve            # or: pnpm run dev   (adds GRAPHQL_DEBUG=1 MCP_DEBUG=1)

# Terminal 2 — UI dev server
pnpm run dev:ui
```

Useful environment variables for the backend:

| Variable | Effect |
|---|---|
| `GRAPHQL_DEBUG=1` | Log every GraphQL request/response |
| `MCP_DEBUG=1` | Log MCP tool calls |
| `REVENTLESS_DOMAIN_PORT=NNNN` | Override the domain API port (default 4000) |
| `REVENTLESS_PLATFORM_PORT=NNNN` | Override the platform/admin API port (default 4001) |
| `REVENTLESS_LOCAL_BACKEND=…` | `memory`, or `sqlite:./path.db` (append `?reset` to start fresh); default `sqlite:./.reventless/local.db` |

(The MCP servers use `REVENTLESS_DOMAIN_MCP_PORT` (default 3001) and
`REVENTLESS_PLATFORM_MCP_PORT` (default 3002).)

## Backends: persistent vs fresh

By default the local platform **persists** to a SQLite file (`.reventless/local.db`), so your
data survives restarts. To start fresh or run fully ephemeral:

```bash
pnpm run serve:reset       # SQLite, wiped on start
pnpm run serve:memory      # in-memory, nothing persisted (dev:full:memory for the full stack)
```

Or set `REVENTLESS_LOCAL_BACKEND` directly (`memory` / `sqlite:./path.db?reset`). See
[local persistence](/infrastructure/local-persistence) for the store format and the
[Local adapters](/infrastructure/local/) for how the runtime is wired.

---

**Next:** [Test it locally →](./test-locally) — log in and run a smoke test
against the running shop.
