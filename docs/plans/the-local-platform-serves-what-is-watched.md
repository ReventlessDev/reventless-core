# Plan: the local platform serves its logs, events and view changes to whoever watches it

**Date:** 2026-10-31<br/>
**Status:** 📝 Planned 2026-10-31, nothing built.<br/>
**Repos:** `reventless-core` only.<br/>
**Builds on:** [component-logs-detached-from-invocation.md](component-logs-detached-from-invocation.md)
(a component's log line keeps its invocation's ids; [PF9](#pf9-ids-on-every-log-line) needs it) ·
[event-history-query-source-a.md](event-history-query-source-a.md) (the per-plugin history
query, which stays as it is) · [done/mcp-event-history-resource.md](done/mcp-event-history-resource.md).

> **Questions and short answers**
>
> - *What does this plan add?* **What a tool outside the platform needs to watch a running app:**
>   its recent log records, every event across all logs, which view rows each event changed,
>   and the outcome of every command. All of it is filtered at the platform, bounded, and
>   linked by ids that run unbroken from a command to the rows it changed ([§3](#3-steps)).
> - *Can everything be followed for one command, one entity, and every entity of one type?*
>   **Yes.**
>   - A command, by its message id and the causation ids below it.
>   - An entity or a type: its events by entity id, tag or log; the rows they changed by the
>     view-change line's entities; its log lines by the `entityId` and `entityType` on each
>     handling line ([PF9](#pf9-ids-on-every-log-line), [PF10](#pf10-the-view-change-line)).
> - *Who reads it?* **Anything that watches a local platform from outside:** the MCP server
>   (new resources in [PF6](#pf6-mcp-resources-for-recent-logs-and-all-events)), a CLI or editor
>   attached to it, the admin API. Deployed, the same ids reach CloudWatch, where the query guide
>   reads them ([PF12](#pf12-the-cloudwatch-guide-follows-the-chain)).
> - *What is broken today that this fixes?* **Four things.**
>   - The event tap has no bound, so a slow reader makes the platform's memory grow.
>   - The platform API's subscriptions skip the admin check.
>   - A command an automation sends starts a new correlation, so the guide's correlation-id
>     timeline stops there.
>   - Refusals before a command's handler leave no log line
>     ([PF2](#pf2-one-bounded-feed-for-the-tap-and-the-log-feed),
>     [PF11](#pf11-the-feeds-on-the-platform-api-and-its-subscriptions-checked),
>     [PF8](#pf8-automations-and-outbound-translations-carry-the-flow),
>     [PF9](#pf9-ids-on-every-log-line)).
> - *Does the wire change?* **Only by addition:** new optional fields, new admin fields, new
>   lines on the feeds. Nothing existing changes shape ([PFD4](#4-decisions)).

---

## 1. Why

A running local platform can be watched today through three channels.

- **Its stdout:** text by default, JSON when `REVENTLESS_LOG_FORMAT=json`.
- **The event tap:** a loopback socket that sends every published event, named in the registry
  entry as `tapPort`.
- **The per-plugin history query.**

Each channel stops short of what a watcher needs:

| Need | Today | Gap |
|---|---|---|
| The log records of a platform someone else started | stdout belongs to whoever started it | no way to read them |
| Every event of every log, newest first | the history query reads one log; an aggregate log only per entity | no read across logs |
| Live events that cannot hurt the app | the tap writes to every socket with no bound or backpressure | a slow reader grows memory without limit |
| Less noise | `LOG_LEVEL` read at start, one level for all | no level per plugin or component, none while running |
| One flow from command to view | events carry `correlationId` and `causationId`; automations and outbound translations start new ones; component lines lose them | the chain breaks, and log lines cannot be placed in it |
| Which rows an event changed | the projection knows; it logs ids only at debug, without the event | nothing records it |
| What happened to a command | `commandOutcomeHook`, one slot, nothing registers it; refusals before the handler never reach it | no record of rejections |

## 2. Scope

**In:**
- the local platform's feeds, the read across all event logs, the runtime log level, and the
  correlation index;
- the ids carried through automations, outbound translations and log lines;
- the view-change line and the outcome line;
- the MCP resources and the admin API fields that serve them;
- the CloudWatch guide's queries for the new fields.

**Not in:**
- a log store on deployed stacks; CloudWatch stays the store there;
- OpenTelemetry spans;
- a change to the per-plugin history query;
- recording rejected commands in the event log.

## 3. Steps

Two releases. **Feeds** ([PF1](#pf1-log-sinks-and-the-recent-rings) to
[PF6](#pf6-mcp-resources-for-recent-logs-and-all-events)) need nothing else. **The chain**
([PF7](#pf7-the-command-outcome-hook-takes-several-listeners) to
[PF10](#pf10-the-view-change-line)) needs
[component-logs-detached-from-invocation.md](component-logs-detached-from-invocation.md) for
[PF9](#pf9-ids-on-every-log-line). [PF11](#pf11-the-feeds-on-the-platform-api-and-its-subscriptions-checked)
and [PF12](#pf12-the-cloudwatch-guide-follows-the-chain) can come in either release.

### PF1: log sinks and the recent rings

- **[`Logger.emit`](../../reventless/core/src/util/Logger.res)** calls registered sinks with
  the record before it is formatted: `time`, `level`, `message`, `plugin`, `comp`, the
  annotations, and `detail` already passed through `LogRedaction.redactJson` and
  `truncateDetail`. `plugin` is resolved outside the JSON branch, where today it is resolved only
  inside it. A sink that throws is dropped from that call and noted once.
- **The local platform registers two rings:** the most recent records (default 5,000) and,
  separately, the most recent warnings and errors (default 1,000), so problems outlive a busy
  minute. Both are bounded by count and by bytes; `REVENTLESS_LOG_RING` and
  `REVENTLESS_LOG_PROBLEM_RING` set them.
- **Exit:** tests that a record in the ring equals the JSON line's fields, that `detail` is
  redacted in the ring, and that both bounds hold.

### PF2: one bounded feed for the tap and the log feed

- **A `LocalFeed` module** serves a feed on a loopback socket. Each listener gets a bounded queue
  (by count and bytes). When a queue is full, its oldest lines are dropped and one
  `{"kind":"skipped","count":N}` line is sent in their place. Writes honour the socket's
  backpressure (`write` returning false, then `drain`). The publish path never waits.
- **On connect, a listener may send one filter line**: plugins, minimum level, components, event
  types, correlation id. Only matching lines are sent. A listener that sends nothing gets
  everything, so today's tap readers keep working.
- **[`LocalEventTap`](../../reventless/local/src/adapter/LocalEventTap.res) moves onto it.** Its
  line keeps every field and gains `log` and `position` (an aggregate log's row id, a DCB log's
  position), so a reader can join live events to the read of
  [PF4](#pf4-one-read-across-all-event-logs) by a key that survives a restart. `seq` stays.
- **The log feed** is a second `LocalFeed`. On connect it first sends the ring of
  [PF1](#pf1-log-sinks-and-the-recent-rings), filtered, then live records. Its port is
  published in the registry entry as `logPort` (optional, like `tapPort`).
  `REVENTLESS_LOG_FEED=off|<port>` controls it the way `REVENTLESS_EVENT_TAP` controls the tap.
- **Exit:** a test with a listener that never reads, which shows the platform's memory flat and
  a `skipped` line on resume; a test that a filter line narrows both feeds; the existing tap
  tests pass unchanged.

### PF3: the log level while running

- **[`Logger`](../../reventless/core/src/util/Logger.res)** gains an override consulted before
  `LOG_LEVEL`, as a default level plus levels per plugin and per component. `shouldLog` takes
  the component, and `EffectLogger`'s minimum level is resolved per call with it.
- **The platform API** gets `Platform_LogLevels` (query) and `Platform_SetLogLevel(plugin,
  comp, level)` (mutation, admin-checked). A level set this way lasts until the platform stops.
- **Exit:** tests that a level per component wins over the plugin's, which wins over the
  default, which wins over `LOG_LEVEL`; a line below its level never reaches a sink.

### PF4: one read across all event logs

- **`Platform_EventLog(filter, first, after)`** on the platform API, admin-checked. It returns
  the events of every log of the selected plugins, newest first. Each record carries the
  envelope (full meta), the plugin, the log, the position, the event type, the entity or tags,
  and `recordedAt`.
- **Filter:**
  - plugins, logs, event types;
  - entity id, tag key and value;
  - `msgId`, `correlationId`, `causationId`;
  - user, time from and to.
- **Order without a schema change:** each log is read backwards from its own position, and the
  logs are merged by time. The cursor holds every log's position
  ([PFQ1](#5-open-questions)). Aggregate logs need a new storage read:
  - SQLite reads by row id, newest first, across entities;
  - Postgres reads by `global_seq`.
- **Exit:** tests on SQLite, memory and Postgres with two plugins, aggregate and DCB logs: pages
  join without a gap or a double while events are appended; every filter narrows.

### PF5: the correlation index

- **SQLite:** expression indexes on the correlation id inside the stored JSON
  (`json_extract(payload, '$.meta.correlationId')` on `event_log`,
  `json_extract(meta, '$.correlationId')` on `dcb_event`), created with `IF NOT EXISTS` on open,
  so an existing store gains them.
- **Postgres:** the same on `payload->'meta'->>'correlationId'` and `meta->>'correlationId'`
  ([`PgSchema.res`](../../reventless/postgres/src/PgSchema.res)).
- **Exit:** the query plan of a correlation filter in [PF4](#pf4-one-read-across-all-event-logs)
  uses the index, on both stores.

### PF6: MCP resources for recent logs and all events

- The platform MCP server
  ([`MCP_ServerInstance.res`](../../reventless/local/src/adapter/MCP_ServerInstance.res)) offers
  `logs/recent` (from the ring, with the same filter as the feed) and `events` (the read of
  [PF4](#pf4-one-read-across-all-event-logs)), so an assistant connected to the platform can
  read what happened in a flow.
- **Exit:** MCP tests that both resources answer and filter.

### PF7: the command outcome hook takes several listeners

- **[`CommandTopic_Helpers`](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res):**
  `registerCommandOutcome` adds a listener and returns its removal. One listener's error does
  not stop the others.
- **The local platform registers one** that writes an outcome record to the event tap's feed
  (`{"kind":"commandOutcome", component, msgId, accepted or rejected, errorCode, cause}`) and a
  rejection to the problem ring of [PF1](#pf1-log-sinks-and-the-recent-rings).
- **Exit:** tests with two listeners; an accepted and a rejected command each appear once on the
  feed.

### PF8: automations and outbound translations carry the flow

- **[`AutomationSlice_Callback`](../../reventless/core/src/components/AutomationSlice/AutomationSlice_Callback.res):**
  - the to-do row gains an optional `source` holding the triggering event's `msgId`,
    `correlationId`, `user` and `traceparent`, written in phase 1 from the decoded meta;
  - phase 2 and the abandonment command derive their meta from it (`Message.deriveMeta`), and
    fall back to `generateMeta` for rows without it (older rows, clock ticks, rebuilt schedules).
- **[`OutboundTranslationSlice_Callback`](../../reventless/core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Callback.res):**
  the same. Inbound translations keep starting a flow, since their input comes from outside.
- **The field is optional** so stored rows still load.
- **Exit:** tests that an event, the automation's command and that command's events share one
  correlation id, and that the command's causation id is the event's message id; a stored row
  without `source` still runs.

### PF9: ids on every log line

- **Needs** [component-logs-detached-from-invocation.md](component-logs-detached-from-invocation.md)
  built: until then, component lines run outside the invocation that carries the ids.
- **[`Runtime.annotateInvocation`](../../reventless/core/src/adapter/Runtime/Runtime.res)**
  annotates the message's own `msgId` beside `correlationId` and `causationId`, so a line can be
  placed under the message it handled.
- **The command's entry** ([`CommandGenerator_Callback`](../../reventless/core/src/components/CommandGenerator/CommandGenerator_Callback.res))
  annotates the new command's `msgId` and `correlationId` on its `generated command` line.
  Refusals before the handler (owner fields, the interceptor's deny, a decode failure) log one
  warning with those ids and fire the outcome hook as rejected, with cause *access* or
  *caller*.
- **The entity a command is handled for** is annotated on its handling lines: `entityId` and
  `entityType`, as the aggregate id and the aggregate's name, or a DCB slice's entity tag value
  and the entity it decides on. Every line of one entity, or of every entity of one type, can
  then be found by field, not by searching message text.
- **Exit:**
  - a log test in which every line of one command's handling, its events' projections and an
    automation's next command carries the same `correlationId` and its own `msgId`;
  - a test that an aggregate's and a DCB slice's handling lines carry `entityId` and
    `entityType`.

### PF10: the view-change line

- **[`Projection.handleAction`](../../reventless/core/src/Projection.res)** and `handleActions`
  take an optional `onChange`, called per row with the view, the row key, *created*, *changed*
  or *removed*, the row before (where it was loaded) and after, and the message ids and entities
  (`entityId`, `entityType`) of the events that led to it. When several actions on one row are
  merged, the change keeps all their ids and entities. The rows one entity changed are then
  found by its events, also when a row is keyed by something else (a customer's row summing the
  customer's orders).
- **The callers keep each action with its event's meta before flattening:**
  [`ReadModel_Callback`](../../reventless/core/src/components/ReadModel/ReadModel_Callback.res)
  and [`StateViewSlice_Builder`](../../reventless/core/src/components/StateViewSlice/StateViewSlice_Builder.res).
- **Locally**, the change goes to the event tap's feed as `{"kind":"viewChange", …}`, redacted as
  log details are.
- **Everywhere**, an info log line `view changed` carries the view, the key, the kind of change,
  the names of the fields that changed, the message ids and the entities, without the values
  ([PFQ3](#5-open-questions)).
- **Exit:** tests that one event changing two rows in two views produces two changes with its
  message id; a merged update keeps both ids; redacted fields never appear.

### PF11: the feeds on the platform API, and its subscriptions checked

- **The platform API's subscriptions are checked today by no one:**
  - `registerSubscriptions` is not wrapped by the admin check;
  - the WebSocket server is given the schema without the context factory.

  Both are fixed in
  [`PlatformGraphQL_Server`](../../reventless/local/src/adapter/PlatformGraphQL_Server.res) and
  [`GraphQL_ServerInstance`](../../reventless/graphql-server/src/GraphQL_ServerInstance.res),
  which also protects the two existing subscriptions.
- **`Platform_LogAppended(filter)` and `Platform_EventAppended(filter)`**: the two feeds as
  admin-checked subscriptions, for readers that speak only HTTP and WebSocket.
- **Exit:** a test that a subscription without the admin group is refused; both feeds deliver
  filtered records over WebSocket.

### PF12: the CloudWatch guide follows the chain

- [`cloudwatch-logs-insights.md`](../guides/cloudwatch-logs-insights.md) gains:
  - `msgId` in the field list;
  - its *correlation-id timeline* across automations;
  - a query for the `view changed` lines of one flow;
  - a query for refusals by cause.
- **Exit:** each query run once against a stack with the chain release.

## 4. Decisions

The decisions are numbered **PFD1 to PFD6**.

| # | Decision | Decided | Why |
|---|---|---|---|
| PFD1 | Where filtering happens | **in the platform, per listener** | a record not sent costs nothing to the reader or the socket |
| PFD2 | A slow listener | **drops its oldest lines and is told how many** | watching must never change the speed or memory of what is watched |
| PFD3 | The order across logs | **merged by time from each log's own position; no new column** | no migration of existing stores ([PFQ1](#5-open-questions)) |
| PFD4 | Changes to existing wire shapes | **none; only optional fields and new fields or lines** | every existing reader keeps working |
| PFD5 | What an automation's command inherits | **correlation, causation, user and trace parent of the triggering event** | the same as an event mapper's command, so a flow reads the same through both |
| PFD6 | Rejected commands | **an outcome line and a log line, never an event** | the event log records what happened; a rejection did not change the app |

## 5. Open questions

**PFQ1. Merge logs by time, or add a global position to the local stores?** A global column
gives an exact order and a simple cursor. It needs a migration of every existing SQLite store,
and DCB positions stay per log. **Recommendation:** merge by `recordedAt` (aggregate rows: the
envelope's time), ties broken by plugin, log and position, and use a cursor of positions per log.
Revisit if a store with many logs makes the merge slow.

**PFQ2. Feeds on sockets, on subscriptions, or both?** **Recommendation:** both. The loopback
socket costs nothing for local readers and needs no sign-in, like the tap. The subscription
serves readers that cannot open a socket, and only behind the admin check of
[PF11](#pf11-the-feeds-on-the-platform-api-and-its-subscriptions-checked).

**PFQ3. Does the deployed `view changed` line carry the values before and after?** They would
make it complete. They also multiply log volume, and would put row content in CloudWatch.
**Recommendation:** field names only deployed; values only on the local feed, redacted.

**PFQ4. How much of the triggering meta does a to-do row keep?** **Recommendation:** `msgId`,
`correlationId`, `user` and `traceparent`, nothing else. That is all `deriveMeta` needs, and
`user` is an id.

**PFQ5. Should refusals before the handler fire the outcome hook?** They are not handled
commands. **Recommendation:** yes, with their own cause, so the hook sees every command that
was sent, as its callers expect.

## 6. Acceptance

- A platform started in one terminal can be watched from another process:
  - its recent and live log records, filtered;
  - every event of every log, newest first, joined to live ones;
  - its view changes and command outcomes.
- A listener that stops reading does not change the platform's memory or speed.
- One command, through an event mapper and an automation, gives one correlation id from the
  command to the last row it changed, and every log line of it carries that id and its own
  message id.
- For one entity, and for every entity of one type, its events, the rows they changed and its
  handling log lines are found by field.
- The log level of one component can be raised while the platform runs.
- The platform API's subscriptions refuse a caller without the admin group.
- The CloudWatch guide's correlation-id timeline crosses an automation.
- `pnpm test` passes on memory, SQLite and Postgres.
