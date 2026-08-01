# Plugin Definition Schema Evolution — Why a Required Field Wedges a Plugin, Silently

**Scope.** Why adding a required field to a type reachable from `pluginDefinition` freezes a
plugin's lifecycle aggregate, why the existing schema-migration-on-read guard did not catch it,
why nothing surfaced it for two days, and what would stop the next occurrence. Written after the
2026-08-01 incident in which the `Catalog` plugin's registration froze at `1.0.0-alpha.168` while
its deployed code reported `1.0.0-alpha.173`.

**Files reviewed**
- [`Message.res`](../../reventless/spec/src/types/Message.res) — `fillMissingDefaults`, `parseJsonTolerant`, `decode`
- [`Plugin.res`](../../reventless/spec/src/components/Plugin.res) — `pluginDefinition` / `pluginStructure` / `requiredStoreDeclaration`
- [`PluginBehavior.res`](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res) — lifecycle `decide` / `evolve`
- [`EventLog_Operations.res`](../../reventless/core/src/components/EventLog/EventLog_Operations.res) — `decodeEvent`
- [`CommandTopicChannel_SQS_Runtime.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res) — batch delete semantics
- [`Util_DeadLetterQueue.res`](../../reventless/aws/src/util/Util_DeadLetterQueue.res) — dead-letter sink
- [`platform-infrastructure-in-plugin-list.md`](../plans/done/platform-infrastructure-in-plugin-list.md) — the prior occurrence and its chosen fix

---

## 1. The failure

`06fb5d671` added `annotation: string` to `requiredStoreDeclaration`
([Plugin.res:400](../../reventless/spec/src/components/Plugin.res#L400)) as a **required** field.
Events already written into the Plugin lifecycle aggregate's log carried
`{store, component, field}` and no `annotation`.

The lifecycle aggregate rehydrates from that log on every command.
[`decodeEvent`](../../reventless/core/src/components/EventLog/EventLog_Operations.res#L161) →
`Message.decode` → sury throws:

```
SuryError: Failed parsing at ["_0"]["structure"]["requiredStoreDeclarations"]["0"]["annotation"]:
           Expected string, received undefined
```

Because replay precedes every decision, *every* command against that aggregate instance dies —
`Heartbeat`, `Redetect`, `Connect` alike. The plugin can no longer answer the deploy handshake, so
its stored definition is frozen at whatever version last connected before the schema change.

**Reproduction against the real artifacts** (the recovered event at position 69 and the current
`PluginSpec.eventSchema`):

| stored payload | tolerant decode |
|---|---|
| as stored — `annotation` absent | **throws**, at the exact production path |
| same event, `annotation` supplied | ok |
| same event, declarations array emptied | ok |
| same event, declarations array `null` | ok |

## 2. Why the existing guard did not hold

This class of failure has happened before and was addressed on 2026-07-11. `Message.res` carries a
schema-migration-on-read layer
([Message.res:143-217](../../reventless/spec/src/types/Message.res#L143-L217)): strict decode is
the fast path, and on failure `fillMissingDefaults` walks the *target sury schema* alongside the
raw JSON and inserts what each absent field's schema expects, then retries once. Its doc comment
describes precisely the outcome we hit — "a silent lifecycle freeze with no error surfaced near the
operator".

It fills four shapes:

| absent field's schema | filled with |
|---|---|
| `T \| null` union (`has.null`) | `null` → `None` |
| array | `[]` |
| mandatory enum | first variant literal |
| nested object | recursively filled `{}` |

Everything else falls through the `default:` arm and is returned unchanged — i.e. `undefined`. A
**bare required scalar** (`string`, `number`, `boolean`) therefore cannot be healed: there is no
value the walker can defensibly invent. `annotation: string` is exactly that shape.

So the guard's coverage is not "new fields are absorbed"; it is **"new fields are absorbed if and
only if they are nullable, an array, an enum, or an object."** That distinction was never written
down as a rule, and nothing enforces it at the point where a field is declared.

## 3. Why nothing surfaced it for two days

Three independent mechanisms each swallowed the signal.

**The symptom is an absence.** A wedged aggregate produces no new events. The heartbeat Lambda keeps
running every 5 minutes and keeps succeeding — it only sends a message. Dashboards that count
activity see activity; the thing that stopped is a state transition nobody counts.

**The dead-letter sink discards.** Commands that fail are not deleted from the queue
([CommandTopicChannel_SQS_Runtime.res:26-58](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L26-L58)),
so after `maxReceiveCount=5` they reach the DLQ — correct. But the DLQ consumer is
([Util_DeadLetterQueue.res:48](../../reventless/aws/src/util/Util_DeadLetterQueue.res#L48)):

```js
export const handler = async (event) => {
  console.error("DEAD LETTER ITEM:", JSON.stringify(event));
};
```

It returns success, so SQS deletes the message. **DLQ depth is therefore always 0**, and any alarm
on depth — the standard signal for exactly this situation — can never fire. In the 20 hours before
recovery, 217 dead-lettered `Heartbeat` commands passed through that sink and were discarded. The
evidence existed, in a log group nobody reads, at a depth metric pinned to zero.

**The user-visible symptom points elsewhere.** The frozen registration serves a stale JSON Schema to
AutoUI, which generates its list query from it. When an unrelated commit retyped
`price: float` → `Reventless.Money.t`, the stale manifest still described a scalar, so the query
selected `price` as a leaf against an SDL where it had become an object:

```
Validation error of type SubSelectionRequired: Sub selection required for type null of field price
```

An empty product list and a GraphQL validation error on a field the developer *had* just changed —
every arrow pointing at the `Money` migration, none at plugin registration.

## 4. Why it will recur

`pluginDefinition` / `pluginStructure` is **deploy-time derived metadata** — the shape of a plugin's
commands, read models, extension points, store declarations, UI hints. It changes whenever the
framework learns to describe something new. In roughly five weeks:

```
f1c1112e9  command field markers reach the wire
06fb5d671  record the storageRef annotation          ← required scalar → wedge
57a3276a6  emit capabilities.json from the plugin build
699ef8e72  why a read model is named by that field
b5e2a1ec8  provision object stores from the fields that declare them
5fc03741a  declare command target state via @targetState
```

That is a type under active design, persisted as an immutable event payload. The two properties are
in direct tension, and nothing currently mediates them: a contributor adding a descriptive field has
no reason to suspect that choosing `string` over `string | null` is the difference between a no-op
and a two-day production freeze.

Note also that the aggregate does not *need* the structure's internals. `decide` and `evolve`
([PluginBehavior.res:127-233](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res#L127-L233))
only read `def.version`, compare definitions for equality, and carry them forward into later events.
The full typed decode is paid on every replay purely so it can be handed back out again.

## 5. Options

### A. Rule: never add a bare required scalar to a persisted structure type

Declare new fields as `T | null`, array, enum, or object — the shapes the healer already absorbs.

*Cheap, no runtime risk, preserves the healer's honesty about genuine corruption. But it is a
convention with no enforcement, on a type edited by people who are not thinking about the event log.
This already implicitly existed and was already violated.* Necessary, not sufficient.

### B. Extend `fillMissingDefaults` to scalars

Fill absent `string`/`number`/`boolean` with `""`/`0`/`false`.

*Closes the blind spot completely with a few lines, at the existing decode boundary, retaining the
"strict first, heal only on failure" structure. The cost is that the healer stops being shape-driven
and starts fabricating values: an empty string is a plausible `annotation` but a wrong `store`. It
also widens what can be masked — a genuinely truncated payload would now decode. Mitigate by logging
loudly whenever a scalar fill is what rescued a decode, so healing is visible rather than silent.*

### C. Declared healing default per field

A field-level marker the fill reads (`@healsTo("")`), so the author states the migration value at the
declaration site.

*Precise, self-documenting, and it puts the decision where the knowledge is. But it needs a
mechanism (PPX or schema metadata) and still depends on the author remembering — the same failure
mode as A, with more machinery. Worth it only if scalar additions become frequent.*

### D. Decode the definition lazily

Type the definition inside the *event* as opaque `JSON.t`; decode to the typed record only at the
projection and API boundaries, where it is actually read.

*Removes the entire class: replay can never fail on a metadata field, because replay no longer parses
metadata. A decode failure then degrades one plugin's manifest instead of freezing its lifecycle —
recoverable, observable, local. The aggregate keeps working with what it actually uses (`version`,
equality, carry-forward). Cost: the aggregate loses compile-time typing over the definition, and the
boundary code must handle a partial decode. This is the change that matches how the data is really
used.*

*Equality is nearly, but not exactly, preserved — measured 2026-08-01 against the live
`Catalog@1.0.0-alpha.173` event and the corpus fixtures. `Primitive_object.equal` ignores key order,
so a payload written under the current schema compares equal as raw JSON just as it does decoded.
A payload written under an **older** schema does not: the stored form lacks keys that a fresh encode
writes as `null`. The idempotency branch would then emit one redundant `VersionConnected`, whose own
payload is current-shaped, so the next deploy compares equal again — one extra event per plugin per
schema change, self-correcting, and avoidable by decoding both sides at that one branch. Detail in
[plugin-definition-schema-evolution-guards.md](../plans/plugin-definition-schema-evolution-guards.md).*

### E. Stop persisting derived metadata as event payload

Store `VersionConnected({version, structureRef})` and keep the document in a side store written at
deploy time, or re-fetch it through the handshake the plugin already answers.

*The deepest fix — an event log stops carrying a large derived document that was never a domain fact,
and schema evolution of that document stops being an event-versioning problem at all. Also the
largest change: it touches the handshake, the projection, and the history view, and it introduces a
fetch into a path that is currently pure. Right direction, wrong size for a fix under incident
pressure.*

### F. Detect it, whichever of the above is chosen

Two guards, both independent of the decode strategy:

1. **A stored-payload compatibility test.** Keep a corpus of real historical event payloads as
   fixtures and assert in CI that each still decodes against the current schemas. A required-scalar
   addition then fails the build with the field name, before deploy. This is the highest
   value-per-effort item on the list: it converts a silent production wedge into a red test.
2. **A dead-letter sink that actually reports.** The current sink guarantees the standard alarm can
   never fire. Either stop deleting (let depth rise and alarm on it) or emit a metric/alarm from the
   handler. A plugin that dead-letters the same command every 5 minutes for two days should page,
   whatever the cause.

## 6. Recommendation

1. **F.1 and F.2 now** — a fixture-corpus compatibility test and a dead-letter sink that alarms.
   Neither changes runtime behaviour; together they turn this failure from "discovered by a user
   noticing an empty list" into "caught in CI, or paged within minutes".
2. **B, with a loud log on the scalar-fill path** — closes the known blind spot at the known
   boundary, and the log keeps the healing visible so masked corruption is still findable.
3. **A, written into the contributor guidance for `Plugin.res`** — the convention costs nothing and
   would have prevented this.
4. **D as the structural direction** if plugin metadata keeps moving at the current rate. Replay of a
   lifecycle aggregate should not be able to fail because of a descriptive field, and today it can.

E stays documented, unscheduled: it is the correct end state, but the value of D over the status quo
is most of E's benefit for a fraction of its blast radius.

## 7. Recovery, for reference

The alpha stack was recovered by deleting the plugin's partition from `PluginAggrEventLog-*`
(key schema `id` HASH + `position` RANGE) after backing it up. The next heartbeat saw an unknown
plugin, ran `VersionDetected` → `Connect`, and re-registered the current version; the read-model row
re-projected. Total elapsed time under a minute. This works because the lifecycle log is a
registration ledger that the deploy can always reconstruct — it is not domain data, which is the same
observation that motivates D and E.
