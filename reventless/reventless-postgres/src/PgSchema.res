// Idempotent schema + migration runner for the Postgres backend.
//
// `ensureSchema(pool)` is callable from any deploy-time context or standalone.
// The package depends on no IaC/provider SDK; a platform that embeds this
// storage is responsible for emitting the deploy-time resource that runs it.
//
// It creates:
//   event_log / snapshot      — classic OCC log (Phase A)
//   dcb_event                 — DCB log; positions are a global IDENTITY sequence,
//                               rows stamped with the committing xid8 (Phase B)
//   dcb_scope                 — companion table for the #RowLocks strategy (B4)
//   dcb_subscription          — change-feed checkpoints (Phase D)
//   dcb_condition_where(...)  — compiles a DcbTag.query jsonb AST → SQL WHERE
//   dcb_append(...)           — the concurrency-critical append (B1): scoped
//                               advisory locks + exact check + insert + NOTIFY,
//                               one round trip, transaction-scoped.

// Table / index DDL. Every statement is individually idempotent so ensureSchema
// is safe to run on every startup and concurrently across processes.
let tableStatements = [
  // --- Classic event log (Phase A) ---
  "CREATE TABLE IF NOT EXISTS event_log (
     log_name      text   NOT NULL,
     aggregate_id  text   NOT NULL,
     seq_nr        bigint NOT NULL,
     payload       jsonb  NOT NULL,
     msg_id        text,
     global_seq    bigint GENERATED ALWAYS AS IDENTITY,
     PRIMARY KEY (log_name, aggregate_id, seq_nr)
   )",
  "CREATE TABLE IF NOT EXISTS snapshot (
     log_name      text   NOT NULL,
     aggregate_id  text   NOT NULL,
     seq_nr        bigint NOT NULL,
     state         jsonb  NOT NULL,
     schema_hash   text   NOT NULL,
     PRIMARY KEY (log_name, aggregate_id)
   )",
  // --- DCB event log (Phase B) ---
  "CREATE TABLE IF NOT EXISTS dcb_event (
     log_name        text        NOT NULL,
     position        bigint      GENERATED ALWAYS AS IDENTITY,
     transaction_id  xid8        NOT NULL DEFAULT pg_current_xact_id(),
     event_type      text        NOT NULL,
     tags            text[]      NOT NULL DEFAULT '{}',
     data            jsonb       NOT NULL,
     meta            jsonb       NOT NULL,
     recorded_at     timestamptz NOT NULL DEFAULT now(),
     PRIMARY KEY (log_name, position)
   )",
  "CREATE INDEX IF NOT EXISTS dcb_event_tags_gin ON dcb_event USING gin (tags)",
  "CREATE INDEX IF NOT EXISTS dcb_event_type_pos ON dcb_event (log_name, event_type, position)",
  "CREATE INDEX IF NOT EXISTS dcb_event_tx_pos   ON dcb_event (log_name, transaction_id, position)",
  // --- Row-lock companion (B4) ---
  "CREATE TABLE IF NOT EXISTS dcb_scope (
     log_name    text   NOT NULL,
     scope_hash  bigint NOT NULL,
     PRIMARY KEY (log_name, scope_hash)
   )",
  // --- Change-feed checkpoints (Phase D) ---
  "CREATE TABLE IF NOT EXISTS dcb_subscription (
     subscriber    text   PRIMARY KEY,
     last_tx       xid8   NOT NULL DEFAULT '0'::xid8,
     last_position bigint NOT NULL DEFAULT 0
   )",
]

// Compiles a DcbTag.query jsonb AST to a SQL WHERE fragment against `dcb_event`.
// The AST is `[ {eventTypes: [text]|null, tags: [text]|null}, ... ]` — an OR of
// clauses; within a clause the tags array is `@>`-contained and event types are
// an IN list. All embedded values pass through quote_literal (the values are
// framework-controlled tag/event strings, but escaping is non-negotiable for
// EXECUTE'd SQL). Tags are encoded 'key=value' to match the dcb_event.tags column.
//
// `after` is the two-column cursor decoded to (p_after_tx, p_after_pos); the
// generated fragment is the exact `(transaction_id, position) > (tx, pos)`
// comparison reads use, so read → decide → conditional-append is exact.
let dcbConditionWhereFn = "
CREATE OR REPLACE FUNCTION dcb_after_frag(p_tx xid8, p_pos bigint) RETURNS text
LANGUAGE sql IMMUTABLE AS $af$
  SELECT CASE WHEN p_tx IS NULL THEN NULL ELSE
    '(transaction_id > ' || quote_literal(p_tx::text) || '::xid8 OR (transaction_id = '
    || quote_literal(p_tx::text) || '::xid8 AND position > ' || p_pos::text || '))'
  END;
$af$;

CREATE OR REPLACE FUNCTION dcb_condition_where(
  p_log_name text,
  p_query    jsonb,
  p_after_tx  xid8,
  p_after_pos bigint
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  v_clauses text[] := '{}';
  v_parts   text[];
  v_types   text;
  v_tags    text;
  v_after   text := dcb_after_frag(p_after_tx, p_after_pos);
  qi        jsonb;
BEGIN
  IF p_query IS NULL OR jsonb_array_length(p_query) = 0 THEN
    v_types := 'log_name = ' || quote_literal(p_log_name);
    IF v_after IS NOT NULL THEN
      v_types := v_types || ' AND ' || v_after;
    END IF;
    RETURN v_types;
  END IF;

  FOR qi IN SELECT * FROM jsonb_array_elements(p_query) LOOP
    v_parts := ARRAY['log_name = ' || quote_literal(p_log_name)];
    IF v_after IS NOT NULL THEN
      v_parts := array_append(v_parts, v_after);
    END IF;

    IF jsonb_typeof(qi->'eventTypes') = 'array'
       AND jsonb_array_length(qi->'eventTypes') > 0 THEN
      SELECT string_agg(quote_literal(t), ',')
        INTO v_types
        FROM jsonb_array_elements_text(qi->'eventTypes') t;
      v_parts := array_append(v_parts, 'event_type IN (' || v_types || ')');
    END IF;

    IF jsonb_typeof(qi->'tags') = 'array'
       AND jsonb_array_length(qi->'tags') > 0 THEN
      SELECT string_agg(quote_literal(t), ',')
        INTO v_tags
        FROM jsonb_array_elements_text(qi->'tags') t;
      v_parts := array_append(v_parts, 'tags @> ARRAY[' || v_tags || ']::text[]');
    END IF;

    v_clauses := array_append(v_clauses, '(' || array_to_string(v_parts, ' AND ') || ')');
  END LOOP;

  RETURN array_to_string(v_clauses, ' OR ');
END;
$fn$;
"

// The append. Called as `SELECT dcb_append($1,$2::jsonb,$3::jsonb,$4)` — a single
// simple statement, so the implicit transaction holds every advisory lock until
// the insert commits. Returns the encoded cursor `<xid8>:<position>` (both
// zero-padded to 20 digits so string order == numeric order) of the last event.
//
// Lock scope (advisory strategy): a deterministic hashtextextended() of every
// tag carried by the written events OR referenced in the condition query,
// namespaced per log_name, acquired in sorted order (deadlock-free). Lock scope
// controls only *what serializes*; the check itself is exact, so a coarse scope
// (hash collision) can only delay an append, never wrongly reject it.
let dcbAppendFn = "
CREATE OR REPLACE FUNCTION dcb_append(
  p_log_name      text,
  p_events        jsonb,
  p_condition     jsonb DEFAULT NULL,
  p_lock_strategy text  DEFAULT 'advisory'
) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  v_lock_keys bigint[];
  v_after_raw text;
  v_after_tx  xid8;
  v_after_pos bigint;
  v_where     text;
  v_conflict  boolean;
  v_last_pos  bigint;
  v_key       bigint;
BEGIN
  -- 1. Lock keys: every tag in written events UNION every tag in the condition.
  SELECT array_agg(DISTINCT k ORDER BY k) INTO v_lock_keys
  FROM (
    SELECT hashtextextended(p_log_name || '=' || tag, 0) AS k
      FROM jsonb_array_elements(p_events) ev,
           jsonb_array_elements_text(ev->'tags') tag
    UNION
    SELECT hashtextextended(p_log_name || '=' || tag, 0) AS k
      FROM jsonb_array_elements(COALESCE(p_condition->'query', '[]'::jsonb)) qi,
           jsonb_array_elements_text(COALESCE(qi->'tags', '[]'::jsonb)) tag
  ) s;

  -- 2. Acquire in sorted order.
  IF v_lock_keys IS NOT NULL THEN
    IF p_lock_strategy = 'rows' THEN
      INSERT INTO dcb_scope(log_name, scope_hash)
        SELECT p_log_name, k FROM unnest(v_lock_keys) k
        ON CONFLICT DO NOTHING;
      PERFORM 1 FROM dcb_scope
        WHERE log_name = p_log_name AND scope_hash = ANY(v_lock_keys)
        ORDER BY scope_hash
        FOR UPDATE;
    ELSE
      FOREACH v_key IN ARRAY v_lock_keys LOOP
        PERFORM pg_advisory_xact_lock(v_key);
      END LOOP;
    END IF;
  END IF;

  -- 3. Exact condition check under the held locks (READ COMMITTED is race-free
  --    here: a conflicting concurrent writer is either committed+visible or
  --    blocked on our lock).
  IF p_condition IS NOT NULL THEN
    v_after_raw := NULLIF(p_condition->>'after', '');
    IF v_after_raw IS NOT NULL THEN
      -- Cursor is '<xid8>:<position>', each zero-padded to 20 digits. Strip the
      -- padding before casting (bigint tolerates leading zeros; be explicit for
      -- xid8, guarding the all-zeros case).
      v_after_tx  := COALESCE(NULLIF(ltrim(split_part(v_after_raw, ':', 1), '0'), ''), '0')::xid8;
      v_after_pos := split_part(v_after_raw, ':', 2)::bigint;
    END IF;
    v_where := dcb_condition_where(p_log_name, p_condition->'query', v_after_tx, v_after_pos);
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM dcb_event WHERE ' || v_where || ')'
      INTO v_conflict;
    IF v_conflict THEN
      RAISE EXCEPTION 'dcb_conflict' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- 4. Insert every event in array order; positions come from the IDENTITY seq.
  WITH ins AS (
    INSERT INTO dcb_event(log_name, event_type, tags, data, meta)
    SELECT p_log_name,
           ev->>'event_type',
           ARRAY(SELECT jsonb_array_elements_text(ev->'tags')),
           ev->'data',
           ev->'meta'
      FROM jsonb_array_elements(p_events) WITH ORDINALITY AS t(ev, ord)
     ORDER BY ord
    RETURNING position
  )
  SELECT max(position) INTO v_last_pos FROM ins;

  -- 5. Wake the change feed (Phase D). No-op if nobody is LISTENing.
  PERFORM pg_notify('dcb_' || p_log_name, v_last_pos::text);

  RETURN lpad(pg_current_xact_id()::text, 20, '0') || ':' || lpad(v_last_pos::text, 20, '0');
END;
$fn$;
"

let functionStatements = [dcbConditionWhereFn, dcbAppendFn]

let ensureSchema = async (pool: PgDriver.pool): unit => {
  for i in 0 to tableStatements->Array.length - 1 {
    await pool->PgDriver.exec(tableStatements->Array.getUnsafe(i))
  }
  for i in 0 to functionStatements->Array.length - 1 {
    await pool->PgDriver.exec(functionStatements->Array.getUnsafe(i))
  }
}

// resetOnStart support: TRUNCATE (never DROP) so the schema/functions survive.
// Mirrors the reventless-local contract that reset wipes data, not structure.
let truncateAll = async (pool: PgDriver.pool): unit => {
  await pool->PgDriver.exec(
    "TRUNCATE event_log, snapshot, dcb_event, dcb_scope, dcb_subscription RESTART IDENTITY",
  )
}
