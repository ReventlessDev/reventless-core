# Reading Reventless logs in CloudWatch Logs Insights

Reventless emits **structured JSON** to any non-TTY log sink (Lambda, Fargate,
ECS, CI, piped stdout) and human-readable coloured text in a terminal. The sink
is chosen automatically from `process.stdout.isTTY`; override with
`REVENTLESS_LOG_FORMAT=json|text`.

Every JSON record carries these top-level fields (optional ones are omitted when
empty), so CloudWatch Logs Insights — and any collector that parses top-level
JSON (Datadog, Loki, Azure Monitor, GCP Cloud Logging) — can filter on them
directly instead of substring-matching the message:

| Field | Always? | Meaning |
|-------|---------|---------|
| `time` | yes | RFC 3339 timestamp stamped at emit |
| `level` | yes | `DEBUG` \| `INFO` \| `WARN` \| `ERROR` |
| `message` | yes | Clean human text — no ANSI, no baked-in prefix |
| `service` | when set | `REVENTLESS_SERVICE`, else the Lambda function name |
| `plugin` | when resolved | Owning plugin (e.g. `Catalog`) |
| `comp` | every line in a handler invocation | Component (e.g. `Aggregate(Product)`) — see note below |
| `correlationId` | request scope | Threads one logical flow across Lambdas |
| `causationId` | request scope, when present | The direct-parent `msgId` — reconstructs the parent → child chain within one `correlationId` |
| `requestId` | Lambda | `context.awsRequestId` |
| `detail` | when provided | Structured payload; truncated to a `{truncated, bytes, preview}` stub above `REVENTLESS_LOG_MAX_DETAIL_BYTES` (default 32 KB) |

> CloudWatch automatically discovers these JSON keys — type `fields @timestamp,
> plugin, comp, level, message` and they autocomplete.

**`comp` is annotated on the whole invocation, not just framework lines.** The
dispatch boundary annotates `comp` (and `correlationId` / `causationId`) onto the
handler effect, so an application handler that only calls `Effect.logInfo("…")`
emits `comp` for free — no need to re-log it by hand. This is what makes two
components hosted in one runtime process (e.g. the all-aggregates command
handler) separable purely by the `comp` field.

## Queries

### 1. All errors across all plugins, last 1h

```
fields @timestamp, plugin, comp, message
| filter level = "ERROR"
| sort @timestamp desc
| limit 100
```

### 2. Everything for one plugin (errors + warnings)

```
fields @timestamp, level, comp, message
| filter plugin = "Catalog" and (level = "ERROR" or level = "WARN")
| sort @timestamp desc
```

### 3. Correlation-id timeline — every step of one flow

Paste a correlation id to see the full `CommandTopic → Aggregate → EventLog →
ReadModel` trace in order. Run it across all the deployment's log groups (select
them all in the Insights log-group picker) to follow the flow across Lambdas.

```
fields @timestamp, service, plugin, comp, level, message
| filter correlationId = "PASTE-CORRELATION-ID"
| sort @timestamp asc
```

### 4. Causal chain within one correlation id

`correlationId` groups every line of a flow; `causationId` orders it into the
`parent → child` tree (each message's `causationId` is its direct parent's
`msgId`). Pull one flow and read `causationId` alongside the message to follow
which step triggered which.

```
fields @timestamp, comp, causationId, message
| filter correlationId = "PASTE-CORRELATION-ID"
| sort @timestamp asc
```

### 5. Command-handler activity by request id

Group a single Lambda invocation's log lines (handy for latency: compare the
first and last `@timestamp` of a `requestId`).

```
fields @timestamp, comp, message
| filter requestId = "PASTE-AWS-REQUEST-ID"
| sort @timestamp asc
```

### 6. Busiest components (where is the log volume?)

```
fields plugin, comp
| filter ispresent(comp)
| stats count(*) as lines by plugin, comp
| sort lines desc
| limit 20
```

### 7. Truncated detail payloads (find logs dropping data)

```
fields @timestamp, comp, message, detail.bytes
| filter detail.truncated = 1
| sort detail.bytes desc
```

## Tips

- **Cross-Lambda tracing** is the payoff of `correlationId`: it is set at the
  request boundary (the shared `Runtime.runEffect` / `Runtime.runEffectHandler`
  dispatch helper) and rides every `EffectLogger` line inside that scope
  automatically — along with `comp` and `causationId` — plus every Lambda
  entry-point shim annotates `correlationId`.
- To force JSON locally (e.g. when piping to a file or `tee`), set
  `REVENTLESS_LOG_FORMAT=json`. To force coloured text in a non-TTY, set
  `REVENTLESS_LOG_FORMAT=text`.
- Raise verbosity with `LOG_LEVEL=debug`; silence framework logs entirely with
  `LOG_LEVEL=silent`.
- Tag a deployment with a stable `service` name via `REVENTLESS_SERVICE` when the
  Lambda function name is not descriptive enough.
