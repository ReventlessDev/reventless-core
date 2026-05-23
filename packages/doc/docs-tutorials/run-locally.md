---
title: Run it locally
sidebar_position: 4
---

# Run the online shop locally

You can run the entire hybrid online shop on your machine — no AWS account, no
cloud resources. The `reventless-in-memory` platform runs the same plugin code
the AWS platform runs, backed by in-memory stores and a local GraphQL server.

Everything in this page happens inside
[`examples/online-shop-hybrid/platform-in-memory/`](https://github.com/ReventlessDev/reventless-core/tree/main/examples/online-shop-hybrid/platform-in-memory).

## Prerequisites

- Node v22.17.1 (see `.node-version`) and pnpm 10 (via `corepack`).
- A checkout of `reventless-core`. You do **not** need the UI source — the local
  UI is provided by the published `reventless-host-shell` package.

## One command

```bash
cd examples/online-shop-hybrid/platform-in-memory

pnpm run build      # once, and after any source change
pnpm run dev:full   # backend + UI together
```

`dev:full` starts two things side by side (colour-coded `[backend]` / `[ui]`):

| Process | What it is | URL |
|---|---|---|
| Backend — domain API | Plugin queries, mutations, subscriptions | `http://localhost:4000/graphql` |
| Backend — admin API | `Admin_*` queries, platform introspection | `http://localhost:4001/graphql` |
| UI dev server | `reventless-host-shell` (the Auto UI shell) | `http://localhost:5173` |

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
| `PORT=NNNN` | Override the domain port (default 4000) |
| `ADMIN_PORT=NNNN` | Override the admin port (default 4001) |

## Optional: persist data between restarts

By default the in-memory platform starts empty every run. If you want events to
survive a restart while developing, the platform supports a file-backed store —
see [local persistence](/infrastructure) in the Infrastructure section.

---

**Next:** [Test it locally →](./test-locally) — log in and run a smoke test
against the running shop.
