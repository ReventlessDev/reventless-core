# Local Dev Setup — In-Memory Platform as Browser-Accessible Backend

This guide explains how to run the in-memory platform locally so a UI dev server can connect to it for live GraphQL queries, mutations, and subscriptions.

---

## How it works

The in-memory platform starts a [graphql-yoga](https://the-guild.dev/graphql/yoga-server) server with full CORS support — no proxy or server changes needed. In the default `splitApi=true` mode two servers start:

| Server | Port | Serves |
|--------|------|--------|
| Domain | 4000 | Plugin queries, mutations, subscriptions |
| Platform / Admin | 4001 | `Admin_*` queries, platform introspection |

For UI domain work (queries/mutations against plugin read models and aggregates), target **port 4000**. For admin or platform tooling, use **port 4001**.

The UI dev server (Vite) proxies all `/graphql` requests to `http://localhost:4000`. The backend must be running before the UI dev server starts.

---

## Quick start — one command

From `examples/online-shop-hybrid/platform-in-memory/` in **reventless-core**:

```bash
# Build first (once, or after source changes)
pnpm run build

# Start backend + UI dev server together
pnpm run dev:full
```

`dev:full` uses `concurrently` to run the backend (`:4000`/`:4001`) and the Vite dev app (`:5173`) side by side, with colour-coded output prefixed `[backend]` / `[ui]`.

### How the UI dev server is resolved

`dev:full` internally calls `pnpm run dev:ui`, which picks the UI dev server in this order:

| Priority | Condition | UI dev server | Hot reload |
|----------|-----------|---------------|------------|
| 1 | `reventless-ui` symlink resolves (source repo checked out) | Vite from source repo | Yes — UI source changes reflected immediately |
| 2 | Symlink dangling / absent | `dev-app` binary from installed `@reventless/dev-app` | No — published snapshot |

`@reventless/dev-app` is a `devDependency` of this package. It is always available without checking out the UI source repo.

---

## Manual startup (two terminals)

If you want separate control over each process:

**Terminal 1 — reventless-core**
```bash
# Build (once, or after source changes)
pnpm --filter ./examples/online-shop-hybrid/platform-in-memory run build

# Start backend with debug logging
pnpm --filter ./examples/online-shop-hybrid/platform-in-memory run dev
```

**Terminal 2 — reventless-ui**
```bash
pnpm run dev:ui
```

Vite starts at `http://localhost:5173` and proxies `/graphql` to `http://localhost:4000`.

---

## Writing your own local dev entry-point

For a plugin that does not yet have a platform-in-memory package, create a minimal entry file alongside its source (in **reventless-core**):

### `src/LocalDev.res`

```rescript
module Platform = ReventlessInMemory.Platform.Make()

module MyPlugin = MyPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version="0.0.0-local",
  ~plugins=[module(MyPlugin)],
)

Platform.startServers()
```

Add run scripts to the plugin's `package.json`, add `@reventless/dev-app` as a `devDependency`, and create a `reventless-ui` symlink the same way:

```bash
ln -s ../../../../reventless-ui reventless-ui
```

```json
"devDependencies": {
  "@reventless/dev-app": "*"
},
"scripts": {
  "dev:local": "tsx src/LocalDev.res.mjs",
  "dev:ui": "[ -d reventless-ui ] && pnpm --filter ./reventless-ui run dev:ui || dev-app",
  "dev:full": "concurrently --names backend,ui --prefix-colors cyan,magenta 'pnpm run dev:local' 'pnpm run dev:ui'"
}
```

Then from the **plugin package** in reventless-core:

```bash
pnpm run build
pnpm run dev:full
```

---

## Multi-plugin local dev

Multiple plugins register into the same domain server — add them all to the `plugins` array:

```rescript
module Platform = ReventlessInMemory.Platform.Make()

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
module Platform = ReventlessInMemory.Platform.MakeWithConfig({
  let splitApi = false
  let cloner = false
})
```

Both domain and admin queries are served at `http://localhost:4000/graphql`.

---

## Environment variables

| Variable | Effect |
|----------|--------|
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
