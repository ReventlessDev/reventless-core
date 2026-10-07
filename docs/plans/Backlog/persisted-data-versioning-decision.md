# Plan: persisted data either carries a version or stops pretending to

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/quality-performance-hardening.md](../done/quality-performance-hardening.md) (its item B5) when it closed. Waits on a decision, not on work: version the data on both axes, or delete the vestigial version fields and keep wiping alpha data instead of migrating it.<br/>
**Relates to:**
- [sury-event-schema-versioning.md](sury-event-schema-versioning.md) — the upcasting mechanism the first axis below would use if the answer is "version".
- [../done/aggregate-snapshotting.md](../done/aggregate-snapshotting.md) — its SQLite `snapshot` table's migration story was left coupled to this decision.

---

## In plain words

Stored data changes shape over time: an event gains a field, a table gains a
column. Either every stored record says which shape it was written in, so the
code can translate old records on read ("migration"), or old data is thrown
away whenever its shape changes ("wipe"). Today the repo does the second in
practice while carrying half-built pieces of the first.

## What is there today (checked 2026-10-07)

- **`schemaVersion` on message meta** — `Message.generateMeta(~schemaVersion=?)`
  accepts it and `deriveMeta` copies it from parent to child
  (`reventless/core/src/Message.res`), and `MetaEnvelopeTest` round-trips it. No
  producer in `reventless/` or `examples/` sets it, and nothing reads it.
- **`ExportMeta.version`** — a frozen constant (`"0.1.0-alpha.0"`) written into
  every `_interopMeta` stack export (`reventless/interop/src/ExportMeta.res`).
  `Compat` never reads it.
- **Storage layout** — no version marker in any backend. The one migration is a
  try/catch `ALTER TABLE … ADD COLUMN expires_at`
  (`reventless/local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res`); Postgres
  uses `ADD COLUMN IF NOT EXISTS` (`reventless/postgres/src/PgSchema.res`).

## The two axes, if the answer is "version"

1. **Data / event-schema version — the same on every backend.** The stamp travels
   in the event or export envelope, and one version-keyed upcast step on read
   serves InMemory, SQLite, DynamoDB and Postgres alike. A SQLite `PRAGMA
   user_version` does nothing for this axis.
2. **Storage-layout version — different per backend, behind one seam.** A small
   `StorageVersion` interface (read current / set / migrate) with per-engine
   implementations: SQLite `PRAGMA user_version`, a DynamoDB sentinel item, a
   Postgres migrations table, nothing for InMemory.

## The other answer: wipe

The maintainers currently prefer wiping alpha data over writing migration code
(snapshots already follow "wipe on fold-logic change"). If that is the policy,
delete `schemaVersion` from `Message.meta` and the `version` field from
`ExportMeta`, so no reader takes them for a working mechanism, and say in the
docs that stored data is not migrated across alpha versions.

## Done when

The decision is written down in this note and one of the two is done: either
both axes exist with a test that reads an old-shape record through the upcast,
or the two fields are gone and the policy is documented.
