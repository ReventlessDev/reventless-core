# Supabase Local Platform Analysis

## Goal

Create a platform that runs fully locally — using Reventless in-memory transport for all messaging — but persists all event logs to Supabase (PostgreSQL). The platform should have a main entry point runnable with `node`, support configuration via environment variables, and work against both a local Supabase instance (Docker, via the Supabase CLI) and a cloud-hosted Supabase project.

## Core Concept

The local platform splits cleanly into two concerns:

| Concern | In-memory component | Keep / Replace |
|---------|--------------------|----|
| Transport / messaging | `InMemory_Bus`, `CommandTopicChannel_InMemory`, `EventTopicPublisher_InMemory`, `EventCollectorChannel_InMemory`, `RuntimeEnvironment_InMemory` | **Keep** |
| Storage | `EventLogStorage_InMemory`, `DcbEventLogStorage_InMemory`, `QueryDbStorage_InMemory` | **Replace with Supabase** |

The GraphQL server (`GraphQL_Server.start()`) already runs locally — that stays as-is.

## Package Structure

New package: `reventless/supabase/` (follows monorepo folder convention for framework packages).

New ReScript bindings package: `rescript/supabase/` (bindings for `@supabase/supabase-js`).

Dependencies:
- `reventless-core` — adapter interfaces
- `reventless-local` — reused Bus + transport modules
- `reventless-infra` — `Platform.T` module type
- `rescript-supabase` — new Supabase JS bindings

## Storage Adapters to Implement

### 1. `EventLogStorage_Supabase.res`

Must satisfy `ReventlessCore.EventLog_Adapter.Storage`:

```rescript
module type Storage = {
  let make: storageMaker  // (~name, ~opts) => { resources, operations }
}
```

Operations:
- `append(seqNr, id, jsons)` — `INSERT` rows into per-aggregate table
- `replay(id)` — `SELECT ... WHERE id = $1 ORDER BY sequence_nr`
- `replayStream(id)` — streaming cursor version of `replay`
- `appendStream(seqNr, id, stream)` — consume stream items and insert one by one

**PostgreSQL table** (one per aggregate type, created via `CREATE TABLE IF NOT EXISTS` at startup):

```sql
CREATE TABLE IF NOT EXISTS {name}_event_log (
  id          TEXT NOT NULL,
  sequence_nr TEXT NOT NULL,   -- hrtime-based string, lexicographically sortable
  payload     JSONB NOT NULL,  -- full JSON blob including type, data, meta fields
  PRIMARY KEY (id, sequence_nr)
);
```

The `payload` contains everything the framework serialises into `JSON.t` — it is stored and retrieved as-is. The storage adapter has no knowledge of the internal shape.

### 2. `DcbEventLogStorage_Supabase.res`

Must satisfy `ReventlessCore.DcbEventLog_Adapter.Storage`:

```rescript
module type Storage = {
  let make: storageMaker  // (~name, ~indexes, ~opts) => { resources, operations }
}
```

Operations:
- `read(~query, ~after?)` — SELECT with JSONB tag filters and optional cursor
- `append(events, ~condition?)` — optimistic concurrency check then INSERT
- `readStream(~query, ~after?)` — lazy streaming version of `read`

**PostgreSQL table** (one global table per DCB event log instance):

```sql
CREATE TABLE IF NOT EXISTS {name}_dcb_event_log (
  position   TEXT PRIMARY KEY
             DEFAULT (EXTRACT(EPOCH FROM now()) * 1000000)::BIGINT::TEXT
                  || '-' || gen_random_uuid()::TEXT,
  event_type TEXT  NOT NULL,
  data       JSONB NOT NULL,
  tags       JSONB NOT NULL DEFAULT '[]'   -- array of {key, value} objects
);

CREATE INDEX IF NOT EXISTS idx_{name}_dcb_tags
  ON {name}_dcb_event_log USING GIN (tags);
```

The `query` type from DCB (array of `{eventTypes?, tags?}` items — OR across items, AND within tags) maps to a PostgreSQL WHERE clause combining `event_type = ANY($1)` and JSONB containment `tags @> $2`.

**Optimistic concurrency in `append`**: The `condition` check (read-then-write with no new matching events after `condition.after`) must be a serializable transaction or a PostgreSQL stored function to be safe under concurrent access:

```sql
CREATE OR REPLACE FUNCTION dcb_append_with_condition(
  p_table    TEXT,
  p_events   JSONB,
  p_query    JSONB,   -- DCB query structure
  p_after    TEXT     -- position cursor (nullable)
) RETURNS TEXT AS $$
DECLARE
  v_conflict_count INT;
  v_position TEXT;
BEGIN
  -- Check for conflicting events
  SELECT COUNT(*) INTO v_conflict_count
  FROM ... WHERE position > p_after AND <tag filter>;

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION 'conflict';
  END IF;

  -- Insert new events and return first position
  INSERT INTO ... SELECT ... FROM jsonb_array_elements(p_events);
  RETURN v_position;
END;
$$ LANGUAGE plpgsql;
```

### 3. `QueryDbStorage_Supabase.res` *(needed for read models)*

Simple key-value store for read model projections. One table per QueryDb name:

```sql
CREATE TABLE IF NOT EXISTS {name}_query_db (
  key   TEXT PRIMARY KEY,
  value JSONB NOT NULL
);
```

Operations: `get(key)`, `put(key, value)`, `delete(key)`, `scan(prefix?)`.

## Platform Composition (`Platform.res`)

The `Make` functor takes a `Config` module for credentials and mirrors the structure of `reventless-local/src/Platform.res`, swapping only the storage modules:

```rescript
module Make = (Config: {
  let supabaseUrl: string
  let supabaseKey: string   // service role key (bypasses RLS for server-side use)
}) => {
  // All transport stays in-memory
  module Bus = InMemory_Bus.Make()

  // Supabase client singleton
  module Db = SupabaseClient.Make(Config)

  // Storage adapters point at Supabase
  module EventLogStorage    = EventLogStorage_Supabase.Make(Db)
  module DcbEventLogStorage = DcbEventLogStorage_Supabase.Make(Db)

  // All channel / transport pieces identical to reventless-local
  // Plugin_Builder.Make receives Supabase storage modules instead of InMemory ones
  module Plugin = Plugin_Builder_Supabase.Make(Bus, Db)
  module Core   = Core_Builder.Make(Bus)

  // ... Aggregate, ReadModel, DcbEventLog, Counter, Scheduler etc.
  // All wired identically to reventless-local/src/Platform.res
}
```

A `Plugin_Builder_Supabase.Make(Bus, Db)` wrapper passes the Supabase storage adapters into `ReventlessCore.Plugin_Builder.Make` in place of the InMemory ones, keeping all other arguments the same.

## Local vs Cloud Supabase

The storage adapter code is identical for both modes — only the `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` values differ.

### Local instance (Supabase CLI + Docker)

The Supabase CLI runs a full Supabase stack in Docker on the developer's machine. Setup:

```bash
# One-time project initialisation (creates supabase/ directory)
npx supabase init

# Start the local stack (requires Docker)
npx supabase start
```

`supabase start` prints the local credentials:

```
API URL:          http://127.0.0.1:54321
DB URL:           postgresql://postgres:postgres@127.0.0.1:54322/postgres
Studio URL:       http://127.0.0.1:54323
anon key:         eyJ...
service_role key: eyJ...
```

Copy the API URL and service_role key into `.env.local`. Rerun `npx supabase status` at any time to retrieve them again.

Use `npx supabase stop` to shut down the stack and `npx supabase db reset` to wipe and recreate the local database from migrations.

### Cloud instance (Supabase dashboard)

Create a project at [supabase.com](https://supabase.com). Retrieve credentials from **Project Settings → API**:
- **URL**: `https://<project-ref>.supabase.co`
- **service_role key**: under "Project API keys" (never expose this in client-side code)

Copy these into `.env` (or `.env.production`).

### Key differences at a glance

| | Local (CLI) | Cloud |
|---|---|---|
| URL | `http://127.0.0.1:54321` | `https://<ref>.supabase.co` |
| TLS | No | Yes (automatic) |
| Credentials source | `supabase start` output | Dashboard → Settings → API |
| Schema management | `supabase db push` locally or auto-create | `supabase db push --linked` |
| Studio | `http://127.0.0.1:54323` | `https://supabase.com/dashboard` |
| Data isolation | Fully local, reset any time | Shared / persistent |
| Cost | Free (Docker only) | Free tier or paid |

The `@supabase/supabase-js` client handles TLS transparently — no code change needed when switching from local to cloud.

## Configuration

Read from environment variables at module initialisation time (before any components are created):

```rescript
// Config.res
let supabaseUrl = switch Process.env->Dict.get("SUPABASE_URL") {
| Some(url) => url
| None => panic("SUPABASE_URL is required")
}

let supabaseKey = switch Process.env->Dict.get("SUPABASE_SERVICE_ROLE_KEY") {
| Some(key) => key
| None => panic("SUPABASE_SERVICE_ROLE_KEY is required")
}
```

Use separate `.env` files per environment and never commit secrets:

**`.env.local`** — local Supabase instance (safe to commit as a template without secrets):
```env
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_ROLE_KEY=eyJ...   # from: supabase status
```

**`.env`** — cloud Supabase instance (add to `.gitignore`):
```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=eyJ...   # from: Supabase dashboard → Settings → API
```

The `run.mjs` entry point selects which file to load. The recommended pattern is to use `dotenv` with `path` resolution so the user can choose via a `NODE_ENV` variable or an explicit flag:

```js
// run.mjs
import { config } from 'dotenv';

const envFile = process.env.NODE_ENV === 'production' ? '.env' : '.env.local';
config({ path: envFile });

import './main.res.mjs';
```

Run locally: `node run.mjs`
Run against cloud: `NODE_ENV=production node run.mjs`

## Main Entry Point

Two files per application:

**`run.mjs`** — thin JS wrapper, must be the actual Node entry point to ensure `dotenv` runs before any ReScript module initialises:

```js
// run.mjs
import 'dotenv/config';        // loads .env into process.env BEFORE ReScript modules init
import './main.res.mjs';       // ReScript-compiled application
```

Run with: `node run.mjs`

**`main.res`** — domain wiring (user-authored per application):

```rescript
// main.res

// Platform reads SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from process.env
module Platform = ReventlessSupabase.Platform.Make({
  let supabaseUrl = ReventlessSupabase.Config.supabaseUrl
  let supabaseKey = ReventlessSupabase.Config.supabaseKey
})

// Define domain components
module MyAggregate = Platform.Aggregate.Make(MyAggregateSpec, MyBehavior, MyMappings)
module MyReadModel = Platform.ReadModel.Make(MyReadModelSpec, MyMappings)

// Build plugin
module MyPlugin = Platform.Plugin
let plugin = MyPlugin.make(
  ~name="MyApp",
  ~version="1.0.0",
  ~aggregates=[module(MyAggregate)],
  ~readModels=[module(MyReadModel)],
  // ...
)

// Wire core — GraphQL server starts automatically when Output chain resolves
module Core = Platform.Core
let _core = Core.make(~name="MyApp", ~plugins=[plugin])
```

## Schema Initialisation

### Option A — Auto-create on startup (recommended for local development)

Each storage adapter's `make` function runs `CREATE TABLE IF NOT EXISTS` at startup via the Supabase JS client. The first `node run.mjs` creates all tables automatically. No separate migration step is needed.

This works identically against both local and cloud instances because `@supabase/supabase-js` exposes a `rpc` / raw SQL execution path via the `postgres` role.

### Option B — Supabase migrations (recommended for cloud or team environments)

Use the Supabase CLI migration workflow:

```bash
# Create a migration file
npx supabase migration new create_event_log_tables

# Edit supabase/migrations/<timestamp>_create_event_log_tables.sql
# Add your CREATE TABLE statements there

# Apply locally
npx supabase db push

# Apply to cloud (after supabase link --project-ref <ref>)
npx supabase db push --linked
```

Migrations are committed to source control under `supabase/migrations/`, giving a full history of schema changes.

### Recommendation

- **During development** (local CLI instance): use Option A for zero-friction iteration — tables appear on first run and `supabase db reset` wipes them cleanly.
- **When deploying to cloud or sharing with a team**: switch to Option B — disable auto-create in the adapter and manage schema via migrations.

## What Needs Building

| File | Package | Priority |
|------|---------|---------|
| `rescript-supabase` bindings | `rescript/supabase/` | High — needed by all adapters |
| `EventLogStorage_Supabase.res` | `reventless-supabase/src/adapter/EventLog/` | High |
| `QueryDbStorage_Supabase.res` | `reventless-supabase/src/adapter/QueryDb/` | High — needed by read models |
| `DcbEventLogStorage_Supabase.res` | `reventless-supabase/src/adapter/DcbEventLog/` | Medium — only for DCB-based plugins |
| `Platform.res` | `reventless-supabase/src/` | High |
| `Config.res` | `reventless-supabase/src/` | Low — trivial |

The largest implementation effort is `DcbEventLogStorage_Supabase.res`, specifically the tag-filtered queries and the `append` optimistic concurrency check (requires a PostgreSQL transaction or stored function). The classic `EventLogStorage_Supabase.res` is straightforward — per-aggregate keyed appends and replays with no concurrency concern.

## Key Constraints

- Use **service role key** (not anon key) on the server side — it bypasses Row Level Security, which is correct for a backend service with no per-user auth at the database layer.
- `@supabase/supabase-js` must be in `dependencies`, not `devDependencies`, since it runs at runtime.
- The Supabase client is created once as a singleton (`SupabaseClient.Make(Config)`) and shared across all storage adapters — do not create multiple clients.
- `dotenv` must load before any ReScript module initialises — this is why `run.mjs` is a separate JS file and not inline in the ReScript output.
- Never commit `.env` (cloud secrets). Do commit `.env.local` only as a template with placeholder values, or document the required variables in a `.env.example` file.
- The local Supabase service_role key is not sensitive (it only works against `localhost`) but should still not be committed as a habit.
