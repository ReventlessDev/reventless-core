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
| `ui` | `dev:ui`, started once the admin server is up (`wait-on tcp:4001`) | the UI dev server (`:5180`) |

This gives **live reload**: edit a `.res` source anywhere in the framework or plugins and the backend recompiles and restarts automatically. A restart resets in-memory state — but with the default SQLite backend (below) your data survives the restart.

**The backend's logs are human-readable text under every one of these scripts**, colour and all. That is not automatic from the shell's point of view: the framework picks its format from whether stdout is a TTY, and `dev:full`'s `concurrently`, `serve:watch`'s `tsx watch` and the VS Code runner all pipe the platform's output — a pipe that looks exactly like the one a log collector reads. So the local platform *declares* itself human-read at startup rather than being guessed at. A deployed platform declares nothing, keeps the TTY rule, and so still emits structured JSON to CloudWatch. `REVENTLESS_LOG_FORMAT=json` gets the structured form back locally.

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

### One platform per directory

At most one platform serves an app directory, started by whoever gets there
first. A second `pnpm run serve` says where the first one is and stops:

```
$ pnpm run serve
→ already running at :4000  ·  sqlite .reventless/local.db  (pid 51055)
  nothing started — http://localhost:4000/graphql is serving this directory.
```

A second `pnpm run serve:reset` **refuses** rather than starting, because a reset
unlinks the store and wipes the object store beside it at construction, while the
ports are bound at the very end of it — so it used to destroy the running
platform's data and only then discover it could not listen. That one is always
on, for every app:

```
Error: refusing to reset ./.reventless/local.db: it is the store of
@reventlessdev/online-shop-hybrid-platform-local running at :4000 (pid 51055).
Stop that platform first, or start this one without ?reset.
```

Both read `.reventless/running/`, the same registry the seed tools resolve their
target from, so a platform that died without cleaning up is pruned rather than
reported. Both are scoped to the current directory — a `REVENTLESS_LOCAL_BACKEND`
pointing at *another* app's file is not caught.

**Setting `REVENTLESS_DOMAIN_PORT` bypasses the check.** Naming a port is the
statement that this platform is meant to coexist, which is how the e2e suites and
the VS Code runner start several in one directory.

### Reading the event stream from outside

Every local platform serves its domain events as NDJSON — one `@@RVLESS_EVT@@`
line per published event — on a **loopback socket, by default**, and publishes the
port it bound on its registry entry:

```json
{ "port": 4000, "endpoint": "…", "store": {…}, "tapPort": 58954 }
```

So a tool that did not start the platform can still read its live events: read the
entry under `.reventless/running/`, connect to `tapPort`, split on newlines. That
is how the VS Code runner shows a live timeline for a platform *you* started with
`pnpm run serve`.

There is nothing to switch on. The port is ephemeral — the OS picks it and the
entry names the one that actually bound — because the registry is already how a
reader finds this platform, so the port never needed to be well-known.

| `REVENTLESS_EVENT_TAP` | socket | stdout |
|---|---|---|
| *unset* (default) | ✅ ephemeral port | — |
| `ndjson` (or any non-port value) | ✅ ephemeral port | ✅ a line per event |
| `47411` (1024–65535) | ✅ that exact port | ✅ a line per event |
| `off` (or `false` / `none`) | — | — |

**The stdout half stays opt-in** — a JSON line per event would drown `pnpm run
serve`. The socket half is on by default because a listener nobody connects to
costs nothing visible. Set an explicit port only when something needs a fixed one;
`off` when you want no listener at all.

Details worth knowing:

- **Loopback only.** The socket binds `127.0.0.1`, never a routable interface.
- **The line format is identical** on both sinks, so a consumer that parses stdout
  reuses its parser and only changes where the bytes come from.
- **`seq` is the event's ordinal in the store**, seeded at startup from the rows
  already persisted — so a reader that connects late sees real event numbers, not
  a count of its own arrivals.
- **`tapPort` is optional and absent means no socket** — a platform from an older
  build, or one started with `off`, is still listed; readers must cope.
- **Diagnostic, never load-bearing.** The listener is `unref`ed so it cannot keep
  the process alive, a reader whose socket dies is dropped without disturbing the
  others, and a port that fails to bind is a warning, not a failed boot. Connect
  defensively: a platform can exit between publishing its entry and your connect.

### Uploaded and offloaded objects

The object store follows the same choice, so bytes never outlive — or fall short of — the events that reference them. Under SQLite it writes beside the database, in the directory the database file sits in:

```
.reventless/
  local.db                            events and read models
  objects/uploads/<uuid>/<file>       uploaded bytes, served at /uploads/*
  object-meta/uploads/<uuid>/<file>.json   {"contentType": …} for that object
  offload/sha256/<hash>               offloaded payloads (large plugin-definition fields)
```

The `objects/` tree mirrors the URL space the dev server serves, so an object is browsable at the path it is fetched from; `object-meta/` is a parallel tree so no sidecar files clutter it. Under `memory` (or a `:memory:` database) the store stays in process, as before. `?reset` wipes these trees along with the database — releasing an upload deletes it either way. On AWS these are two S3 buckets: a served one behind CloudFront and a private one the platform reads through the SDK.

Uploads are rooted at the declaring store — `objects/uploads/{plugin}/{store}/{uuid}/{file}` — so an object carries the plugin that owns it in its own key. That is what lets `seed:reset` empty one plugin's objects without touching another's. A store no connected plugin declared falls back to plain `uploads/{uuid}/{file}`.

The `{plugin}/{store}` segments are the layout the deployed platform uses as an S3 key prefix; locally they sit **inside** `uploads/` rather than at the root. That nesting is load-bearing: a UI dev server runs on its own port and forwards exactly one path to the platform (`"/uploads": "http://localhost:4000"` in the host shell's Vite config). A ref minted outside that path resolves against the UI server instead, so the image request quietly returns the SPA shell and nothing renders. Keeping every object under `uploads/` means the serve path is a property of the platform, not something each UI dev server has to be reconfigured to know.

---

## Resetting the store (`seed:reset`)

`pnpm run seed:reset` empties a **scope** of the store so it can be re-seeded — the local counterpart of the deployed platform's script of the same name, and the inverse of `pnpm run seed` (which refuses to seed a non-empty store).

```bash
pnpm run seed:reset      # pick a scope, see what it would empty, confirm
pnpm run seed            # in a second shell
```

**It works against a running platform.** Rows are deleted through a second connection to the same database, and the server sees that immediately — its read models read those tables on every query, with no in-process cache. So you do not stop the platform, and nothing needs restarting.

| Scope | Empties |
|---|---|
| `domain` (default) | every read model, event log, checkpoint and object that is not the platform's own — including components no plugin structure lists |
| a plugin name | only that plugin's components and the objects under its declared stores |
| `platform` | the plugin registry, the UI fragment registry, the Plugin aggregate's log, and the offloaded plugin definitions |
| `everything` | both |

`domain` is the default because it leaves the plugin registry intact, so a re-seed just works. `SEED_RESET_SCOPE` picks a scope non-interactively and `SEED_RESET_CONFIRM` answers the y/N — `y`, `yes` or `1`, in any case, and anything else declines rather than falling back to a prompt no CI run has a terminal for. Together they are the deployed script's `SEED_RESET_SCOPE` and typed confirmation, minus the gates that exist because *that* target is remote and irreversible.

:::caution Restart the platform between a reset and a re-seed
`seed:reset` empties the store through its own connection, but a running platform keeps in-memory state that the delete does not invalidate — a DCB slice goes on refusing writes for ids whose decision state it still holds, so a re-seed fails with `…AlreadyExists` against a store that plainly does not contain them. The loop is **`seed:reset` → restart the platform → `seed`**.
:::

**It asks a platform which store to empty.** Both `seed` and `seed:reset` resolve their target the same way — from the platforms actually running in this directory, which each publish their endpoint and store under `.reventless/running/` at startup:

```
→ http://localhost:4000/graphql  ·  sqlite .reventless/local.db  (online-shop-hybrid-platform-local)
```

With one platform up, that line is all you see. With several — a suite that starts a deliberate second one on its own port (`REVENTLESS_DOMAIN_PORT`), say — you get a menu, and `SEED_PLATFORM` (a port, or a menu index) picks one non-interactively:

```
Platform:

  1) :4000  online-shop-hybrid-platform-local  sqlite .reventless/local.db
  2) :4010  online-shop-hybrid-platform-local  memory
```

This matters because those two platforms serve **different databases**. Resolving the store from `REVENTLESS_LOCAL_BACKEND` instead — a variable set in your shell, describing no platform — let a reset empty a store nobody was serving while reporting success, and the `seed` after it then refused because the served store was still full.

Set `REVENTLESS_LOCAL_BACKEND` explicitly and it still wins, for the one case discovery cannot serve: resetting a store whose platform is not running. `REVENTLESS_GRAPHQL_ENDPOINT` does the same for seeding. Do **not** put a default for either in a package script — a default makes the override always fire, which is the guess this replaces.

Three things worth knowing:

- **A plugin scope reports what it left alone.** Components that no structure claims (audit and todo read models, typically) can only be reached by `domain`, and the plan says so rather than leaving you to discover it through a failing seed.
- **It empties, it does not delete.** Tables are cleared, never dropped, so the running platform's prepared statements stay valid. If you want the files gone entirely, that is `serve:reset` (wipes everything as the platform starts) or deleting `.reventless/` by hand — but note that deleting `local.db` while the platform runs does nothing useful: the process keeps the orphaned inode and carries on serving the old rows.

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

This launches `reventless-host-shell` (or the local UI source if present). It starts at `http://localhost:5180` and talks to the backend on `http://localhost:4000`.

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

## Curating the surface a shell sees (`bakedManifest`)

By default the host shell discovers its surfaces from the admin-gated
`Platform_ComponentDefinitions` query, so a caller outside the elevated group
renders nothing at all. Declaring `bakedManifest` writes the same manifest as a
static file the shell can read instead:

```rescript
Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
  ~hostUiBundle={
    bakedManifest: {
      components: [
        {plugin: "Catalog", views: ["Products", "Categories"], commands: []},
        {plugin: "Ordering", views: ["Orders"], commands: ["PlaceOrder", "CancelOrder"]},
      ],
    },
  },
)
```

Keep the include-list in a module shared by every platform root that hosts the
app (the online-shop-hybrid example puts it in its seed package as
`Storefront.res`) and pass it from each root. What the app offers is the same
answer on every platform; only where the file goes is platform-specific.

The file is written to the resolved `@reventlessdev/reventless-host-shell`
`dist/` — where the `config.json` and `ui-hints.json` you already see are served
from — as `component-manifest.json` (override with `key`), on every boot. Point
the shell at it by adding `"manifestUrl": "/component-manifest.json"` to that
same `config.json`; with the key set the shell never contacts the platform API
for discovery.

`views` / `commands` unset means every public component of that kind; commands
are named by command, not by the slice or aggregate carrying them. A name that
matches nothing fails the boot naming it — a curated shell missing a page is a
symptom with no other explanation.

Two things this is **not**. It is not authorization: the server still decides
what any caller may do, per query and per mutation, and a component left out of
the file remains as callable as it was. And it is not a hiding place for
`@@reventless.visibility(Internal)` views — those stay out of the menu but ride
along on `internalQueryables` when an included command `@ref`s one, because a
shell reading a baked file has no admin API to resolve a picker's targets from.

Unset ⇒ no file written, and the platform behaves exactly as it did before.

## Editing UI hints without restarting

`ui-hints.json` is copied into that same `dist/` at boot, so historically a
label change cost a platform restart and a page reload. It no longer does: the
local platform watches the declared `uiHintsFile`, re-serves it on every save,
and says so on the events channel the shell already holds. The menu restacks
where it stands.

```
$ pnpm run serve
… watching …/seed-data/ui-hints.json — edits are served without a restart
# save the file
… ui-hints.json changed — re-served
```

Local only, by design — on AWS the hints are an object a deploy writes once, and
a running deployment must not follow anybody's working copy. The shell gates on
`authMode: "local"`, which is the in-memory platform's own signature in
`config.json`.

Two behaviours worth knowing, both of which follow from what an editor actually
does on save:

- **A save is often two writes**, and the file is briefly not valid JSON. That
  is reported and skipped, never thrown — the last good copy stays in front of
  the browser, and the write that completes the save is itself the event that
  re-serves it. The rule at boot is the opposite and deliberately so: a
  declaration that does not parse fails the boot, because there is no previous
  copy and nothing else to go on.
- **`Storefront.res` is not this.** Editing the manifest, `derived`, or
  `elevatedGroups` is ReScript: rebuild and restart. Only the hints file is
  followed live.

## Staying logged in across restarts

Local tokens are signed with an HMAC secret resolved in three steps: the
`REVENTLESS_INMEMORY_TOKEN_SECRET` env var (≥16 chars) if set, otherwise
`.reventless/token-secret` — minted on the first boot that finds the directory
and reused by every boot after — and failing both, random per process.

That middle step is what keeps a logged-in tab working across a restart, and it
matters more than a manual restart suggests: `tsx watch` re-execs the process on
every ReScript rebuild, so a per-process secret used to sign you out several
times an hour while you worked. The directory is used but never created, so a
unit test — which has no `.reventless/` in its working directory — still gets a
random per-process secret and writes nothing.

These tokens are local-dev only and not security-grade; AWS verifies
Cognito-issued JWTs and never sees them. The file sits in the same gitignored
directory as `users.yaml`, which already holds plaintext dev passwords.

**If a token is refused anyway** — you cleared the file, pinned a different
secret, or the session genuinely expired — the shell now says so rather than
spinning. The events socket closes with 4401, which the client treats as a
refused credential rather than a dropped connection: it stops retrying and the
shell logs out to the login screen. Every other close code, including the 1006
you get while a backend is restarting, still backs off and reconnects.

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
| `REVENTLESS_LOCAL_BACKEND` | Storage backend: `memory`, `sqlite:<path>`, or `sqlite:<path>?reset` (see [Storage backend](#storage-backend-sqlite-by-default)). The `serve` scripts default it to `sqlite:./.reventless/local.db`; `seed:reset` deliberately does not — set it there only to reset a store whose platform is down. |
| `SEED_PLATFORM` | Which running platform `seed` / `seed:reset` act on, by port (`4000`) or menu index. Only consulted when more than one is running (see [Resetting the store](#resetting-the-store-seedreset)). |
| `REVENTLESS_GRAPHQL_ENDPOINT` | Seeds against this endpoint verbatim, skipping platform discovery. `REVENTLESS_LOGIN_ENDPOINT` overrides the login route, which otherwise follows the same host and port. |
| `GRAPHQL_DEBUG=1` | Logs every incoming GraphQL request and response |
| `MCP_DEBUG=1` | Logs MCP tool calls |
| `REVENTLESS_DOMAIN_PORT=NNNN` | Override domain server port (default 4000). Also the port a platform registers itself under. |
| `REVENTLESS_PLATFORM_PORT=NNNN` | Override admin/platform server port (default 4001) |
| `REVENTLESS_DOMAIN_MCP_PORT` / `REVENTLESS_PLATFORM_MCP_PORT` | Override the MCP ports (defaults 3001 / 3002) |

---

## GraphQL schema for UI tooling

Point your schema fetch script at the domain server (run from **reventless-ui**):

```bash
GRAPHQL_ENDPOINT=http://localhost:4000/graphql pnpm run gql:update
```

Use port `4001` when you need the admin/platform schema instead.
