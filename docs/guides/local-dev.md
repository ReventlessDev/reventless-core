# Local Dev Setup — Local Platform as Browser-Accessible Backend

This guide explains how to run the local platform locally so a UI dev server can connect to it for live GraphQL queries, mutations, and subscriptions.

---

## How it works

The local platform starts a [graphql-yoga](https://the-guild.dev/graphql/yoga-server) server with full CORS support — no proxy or server changes needed. In the default `splitApi=true` mode two servers start:

| Server | Port | Serves |
|--------|------|--------|
| Domain | 4000 | Plugin queries, mutations, subscriptions |
| Platform / Admin | 4001 | `Admin_*` queries, platform introspection |

For UI domain work (queries/mutations against plugin read models and aggregates), target **port 4000**. For admin or platform tooling, use **port 4001**.

The UI dev server (Vite) proxies all `/graphql` requests to `http://localhost:4000`. The backend must be running before the UI dev server starts.

---

## Quick start — one command

From `examples/online-shop-hybrid/platform-local/` in **reventless-core**
(the same scripts work in `examples/online-shop-aggregates/platform-local/`
and `examples/online-shop-dcb/platform-local/` — see each example's README
for the style-specific overview):

```bash
# Build first (once, or after source changes)
pnpm run build

# Start backend + UI dev server together
pnpm run dev:full
```

`dev:full` uses `concurrently` to run three processes side by side, with colour-coded output prefixed `[rs]` / `[backend]` / `[ui]`:

| Prefix | Process | Purpose |
|--------|---------|---------|
| `rs` | `rescript watch` (workspace root) | recompiles `.res` → `.res.mjs` on save |
| `backend` | `tsx watch` over `Main.res.mjs` (`serve:watch`) | restarts the backend (`:4000`/`:4001`) when any framework/plugin `.res.mjs` changes |
| `ui` | `dev:ui`, started once the admin server is up (`wait-on tcp:4001`) | the UI dev server (`:5173`) |

This gives **live reload**: edit a `.res` source anywhere in the framework or plugins and the backend recompiles and restarts automatically. A restart resets in-memory state — but with the default SQLite backend (below) your data survives the restart.

### How the UI dev server is resolved

`dev:full` internally calls `pnpm run dev:ui`, which picks the UI dev server in this order:

| Priority | Condition | UI dev server | Hot reload |
|----------|-----------|---------------|------------|
| 1 | a local `reventless-ui` directory is present (UI source checked out beside this package) | Vite from the UI source | Yes — UI source changes reflected immediately |
| 2 | no local `reventless-ui` directory (the normal case) | `reventless-host-shell` binary from the installed `@reventlessdev/reventless-host-shell` package | No — published snapshot |

A fresh checkout has **no** `reventless-ui` directory (it is not part of this repo), so `dev:ui` resolves to `reventless-host-shell` by default — no symlink or UI source needed. The local-source path (priority 1) is only for contributors actively developing the UI alongside the backend.

---

## Storage backend (SQLite by default)

The local platform can store events and read models either in process memory (wiped on every restart) or in an on-disk SQLite file (survives restarts — handy with live reload). The backend is chosen by the `REVENTLESS_LOCAL_BACKEND` env var; the run scripts wrap it so you rarely set it by hand:

| Script | Backend | Notes |
|--------|---------|-------|
| `serve` / `serve:watch` / `dev:full` | **SQLite** `./.reventless/local.db` | default; persists across restarts |
| `serve:memory` / `dev:full:memory` | in-memory | wiped on every restart |
| `serve:reset` / `dev:full:reset` | SQLite, **wiped on start** | clean boot, then persists for that run |

The default is SQLite, so `pnpm run dev:full` keeps your data across the automatic live-reload restarts. Use `:memory` for a stateless run, or `:reset` for a one-shot clean boot. The `.reventless/` directory is created automatically and is git-ignored.

Set the env var directly to override:

```bash
REVENTLESS_LOCAL_BACKEND=memory pnpm run serve           # same as serve:memory
REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db?reset pnpm run serve
```

---

## Manual startup (two terminals)

If you want separate control over each process:

**Terminal 1 — reventless-core**
```bash
# Build (once, or after source changes)
pnpm --filter ./examples/online-shop-hybrid/platform-local run build

# Start backend with GraphQL/MCP request logging (SQLite persistence, like serve)
pnpm --filter ./examples/online-shop-hybrid/platform-local run dev
```

`dev` is `serve` plus `GRAPHQL_DEBUG=1 MCP_DEBUG=1` (per-request logging) and is not watch-based — restart it manually after a rebuild. Use `serve:watch` / `dev:full` for live reload.

**Terminal 2 — UI dev server** (from the same `platform-local/` package)
```bash
pnpm run dev:ui
```

This launches `reventless-host-shell` (or the local UI source if present). It starts at `http://localhost:5173` and talks to the backend on `http://localhost:4000`.

---

## Writing your own local dev entry-point

For a plugin that does not yet have a platform-local package, create a minimal entry file alongside its source (in **reventless-core**):

### `src/LocalDev.res`

```rescript
module Platform = ReventlessLocal.Platform.Make()

module MyPlugin = MyPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version="0.0.0-local",
  ~plugins=[module(MyPlugin)],
)

Platform.startServers()
```

Add run scripts to the plugin's `package.json` and add `@reventlessdev/reventless-host-shell` as a `devDependency`. No symlink is needed — the host-shell binary is the default UI:

```json
"devDependencies": {
  "@reventlessdev/reventless-host-shell": "*"
},
"scripts": {
  "dev:local": "REVENTLESS_LOCAL_BACKEND=${REVENTLESS_LOCAL_BACKEND:-sqlite:./.reventless/local.db} tsx watch src/LocalDev.res.mjs",
  "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || reventless-host-shell",
  "dev:full": "concurrently --names rs,backend,ui --prefix-colors blue,cyan,magenta 'rescript watch' 'pnpm run dev:local' 'npx wait-on tcp:4001 && pnpm run dev:ui'"
}
```

The `[ -d reventless-ui ]` branch only matters if you are also developing the UI source locally; otherwise `reventless-host-shell` runs.

`rescript watch` recompiles your sources and `tsx watch` restarts the backend on change (live reload). The `REVENTLESS_LOCAL_BACKEND` default gives you SQLite persistence here too — add `:memory` / `:reset` variants as shown in [Storage backend](#storage-backend-sqlite-by-default) if you want them. The local platform defaults to `LOG_LEVEL=debug` regardless of which entry-point you use.

Then from the **plugin package** in reventless-core:

```bash
pnpm run build
pnpm run dev:full
```

---

## Multi-plugin local dev

Multiple plugins register into the same domain server — add them all to the `plugins` array:

```rescript
module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version="0.0.0-local",
  ~plugins=[module(Catalog), module(Ordering)],
)

Platform.startServers()
```

The stitched schema at `:4000` includes all plugin types. Run schema update once after all plugins are registered.

---

## Single server

To expose everything on a single port:

```rescript
module Platform = ReventlessLocal.Platform.MakeWithConfig({
  let splitApi = false
  let cloner = false
})
```

Both domain and admin queries are served at `http://localhost:4000/graphql`.

---

## Environment variables

| Variable | Effect |
|----------|--------|
| `LOG_LEVEL` | `silent` \| `error` \| `warn` \| `info` \| `debug`. The local platform **defaults to `debug`** (surfaces e.g. the slice/aggregate `deciding on state:` lines); set `LOG_LEVEL=info` to quieten it. Other platforms default to `info`. |
| `REVENTLESS_LOCAL_BACKEND` | Storage backend: `memory`, `sqlite:<path>`, or `sqlite:<path>?reset` (see [Storage backend](#storage-backend-sqlite-by-default)). Defaults to `sqlite:./.reventless/local.db` via the run scripts. |
| `GRAPHQL_DEBUG=1` | Logs every incoming GraphQL request and response |
| `MCP_DEBUG=1` | Logs MCP tool calls |
| `PORT=NNNN` | Override domain server port (default 4000) |
| `ADMIN_PORT=NNNN` | Override admin server port (default 4001) |

---

## GraphQL schema for UI tooling

Point your schema fetch script at the domain server (run from **reventless-ui**):

```bash
GRAPHQL_ENDPOINT=http://localhost:4000/graphql pnpm run gql:update
```

Use port `4001` when you need the admin/platform schema instead.
