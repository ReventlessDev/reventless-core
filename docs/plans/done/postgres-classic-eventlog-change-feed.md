# Design: classic `event_log` change feed (B2.5)

**Status**: ✅ Implemented (2026-07-05). The "separate small reventless-postgres
sub-plan" that `aws-postgres-change-feed-bridge.md` B2.5 defers to. Unlocks the
**aggregate** deployed path on the same relay bridge the DCB vertical (B2.1–B2.4)
uses. Shipped: schema (`transaction_id` + index + `event_log_subscription` + notify
trigger in `PgSchema`), `EventLogChangeFeed` reader, PG_URL-gated tests green against
Postgres 16 (10/10). The downstream AWS classic relay + backend selection remain
open under the parent `aws-postgres-rds-adapter.md`.

## Why it's needed

On AWS, aggregate event propagation is the DynamoDB stream (same as DCB). Route the
classic EventLog to Postgres and that stream vanishes — projections and cross-plugin
reactions no-op. The DCB log already has a feed (`PgChangeFeed`, `pg_notify` +
`dcb_subscription`); the classic `event_log` has **none** — its only append hook is
the in-process `onAppended` callback, which does not cross the Lambda boundary. This
sub-plan adds the missing feed so the existing `PgChangeFeedRelay` pattern can drain
it too.

## The correctness constraint: commit order, not insert order

`event_log.global_seq` is a `bigint GENERATED ALWAYS AS IDENTITY` — assigned at
**INSERT**, before commit. Two concurrent appends can commit out of IDENTITY order
(txn with `global_seq=5` commits *after* `global_seq=6`). A naive
`global_seq > checkpoint` reader that advances past 6 would **silently skip 5** when
its txn commits late — corrupting every downstream projection.

This is the exact hazard the DCB feed solves with an **xmin read barrier** over a
`transaction_id xid8` column. The classic feed reuses that mechanism verbatim.

## Design (mirrors `PgChangeFeed` / `DcbEventLogStorage_Postgres`)

Purely **additive** — no change to `EventLogStorage_Postgres.append`:

1. **Schema (`PgSchema.res`, idempotent):**
   - `ALTER TABLE event_log ADD COLUMN IF NOT EXISTS transaction_id xid8 NOT NULL
     DEFAULT pg_current_xact_id()` — auto-stamped on every insert; no append change.
   - `CREATE INDEX IF NOT EXISTS event_log_tx_gseq ON event_log
     (log_name, transaction_id, global_seq)` — the feed's keyset order.
   - `event_log_subscription(subscriber text PK, last_tx xid8 DEFAULT '0'::xid8,
     last_global_seq bigint DEFAULT 0)` — classic checkpoints (separate from
     `dcb_subscription`; different cursor columns).
   - A statement-level `AFTER INSERT ON event_log` trigger
     (`REFERENCING NEW TABLE`) → one `pg_notify('evlog_' || log_name, '')` per
     statement per distinct log. `CREATE OR REPLACE TRIGGER` (PG14+; the target is
     PG16). The append code path is untouched — the trigger owns the notify.
   - `truncateAll` extended to include `event_log_subscription`.

2. **Cursor** = `<xid8>:<global_seq>`, both zero-padded to 20 digits (string order ==
   numeric order), identical format to the DCB cursor — reuses
   `DcbEventLogStorage_Postgres.decodeCursor` / `stripZeros`.

3. **Reader (`EventLogChangeFeed.res`)** — a direct analogue of `PgChangeFeed`:
   - `readBatch` — `SELECT … FROM event_log WHERE log_name=$1
     AND transaction_id < pg_snapshot_xmin(pg_current_snapshot())
     [AND (transaction_id, global_seq) > (after)]
     ORDER BY transaction_id ASC, global_seq ASC LIMIT n` → the xmin-fenced page.
   - `loadCheckpoint` / `saveCheckpoint` over `event_log_subscription`.
   - `listen` / `unlisten` on channel `evlog_<logName>`.
   - `drain(pool, ~logName, ~subscriber, ~handle)` — the reference consumer loop
     (readBatch → handle → saveCheckpoint), byte-for-byte the DCB shape.
   - Emits a classic event record: `{cursor, aggregateId, seqNr, payload, msgId}` —
     the faithful stored classic event. (The AWS relay's transform of `payload` →
     the EventCollector `{id, meta, event}` body is a **downstream** step, not B2.5.)

## Out of scope (downstream follow-ups)

- The AWS classic relay (a `PgChangeFeedRelay` variant that drains `event_log` and
  transforms `payload` → `{id: aggregateId, meta, event}` for the EventCollector) —
  the "aggregate deployed path reuses this exact bridge" step.
- Deploy-time selection of the classic EventLog backend (the aggregate analogue of
  B2.3c's `DcbBackend`).

## Validation

`PG_URL`-gated tests in `PostgresIntegrationTest` (skip without `PG_URL`):
- append → `drain` sees all events, in `(tx, global_seq)` order, with correct
  `{aggregateId, seqNr, payload, msgId, cursor}`;
- checkpoint: a second `drain` from the same subscriber sees nothing new;
- **commit-order safety**: interleaved appends across aggregates drain exactly once
  with no skips (the anomaly the xmin fence closes).
Run green against the local Postgres 16 container.
