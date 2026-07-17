[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-postgres.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-postgres)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-postgres

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **Postgres storage backend** for [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
It implements the core storage adapters (classic and DCB event logs, the query
database, and change feeds) over a plain Postgres connection. It carries **no**
IaC/provider SDK dependency: it connects by connection string, so it runs against
RDS/Aurora, any managed provider, or a local container.

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`:

- **`PgDriver`** — the [`node-postgres`](https://node-postgres.com) (`pg`) binding
  (pool/client). Accepts a full `connectionString` or discrete fields, with SSL
  and rotating-secret (password-provider) support.
- **`PgSchema`** — an idempotent schema + migration runner (`ensureSchema(pool)`),
  safe to run on every startup and concurrently across processes.
- **`EventLogStorage_Postgres`** — the classic optimistic-concurrency event log
  (`event_log` / `snapshot`).
- **`DcbEventLogStorage_Postgres`** — the DCB (Dynamic Consistency Boundary) event
  log with a global position sequence and a concurrency-critical `dcb_append`.
- **`QueryDbStorage_Postgres`** — read-side storage over JSONB `qdb_<name>` tables.
- **`QueryEnginePostgres`** — compiles the core QueryEngine query/scan AST down to
  SQL, pushing filters into the database.
- **`EventLogChangeFeed`** / **`PgChangeFeed`** — checkpointed change feeds for the
  classic and DCB logs, using an `xmin`-fenced read plus `LISTEN`/`NOTIFY`
  (`pg_notify`) for near-real-time wakeup. A documented public consumer surface.

The `*_Ops` modules hold the runtime-pure operations (no Pulumi import) so a
deployed handler's ESM graph stays clean; the wrapper modules add the deploy-time
adapter shape.

## Where it fits

`reventless-postgres` is a storage **adapter** for the Reventless framework.
[`reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
is provider-agnostic; this package supplies the Postgres implementation of its
event-log, query-db, and change-feed interfaces:

- [`@reventlessdev/reventless-aws`](https://www.npmjs.com/package/@reventlessdev/reventless-aws) — AWS (DynamoDB, Lambda, SQS, SNS, S3); can delegate event logs to this package for managed Postgres
- [`@reventlessdev/reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres) — **this package**
- [`@reventlessdev/reventless-local`](https://www.npmjs.com/package/@reventlessdev/reventless-local) — in-memory / SQLite platform that uses this storage against a local Postgres

Because it depends only on `pg` (plus
[`reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core),
[`reventless-infra`](https://www.npmjs.com/package/@reventlessdev/reventless-infra),
and [`reventless-spec`](https://www.npmjs.com/package/@reventlessdev/reventless-spec)),
the platform package that embeds it owns provisioning; this package only needs a
reachable Postgres.

## Install

```bash
pnpm add @reventlessdev/reventless-postgres
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-postgres"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
