# Plan: another plugin's facts come in through the plugin's own log, once

**Date:** 2026-10-28<br/>
**Status:** Not started.<br/>
**Relates to:** [read-side-fed-from-an-extension-point.md](../analysis/read-side-fed-from-an-extension-point.md)
(the analysis; this plan is steps 1 and 2 of [its §8](../analysis/read-side-fed-from-an-extension-point.md#8-recommendation)) ·
[cross-plugin-subscription-leftovers.md](Backlog/cross-plugin-subscription-leftovers.md)
(its [§3](Backlog/cross-plugin-subscription-leftovers.md#3-dcbsources-is-plumbing-with-no-consumer),
decided here as *remove*) ·
[lambda-environment-size-ceiling.md](lambda-environment-size-ceiling.md) (loses the `PRM_*` term) ·
[effect-runtime-dispatch.md](Backlog/effect-runtime-dispatch.md) (its step 4 targets code this
plan deletes)

**Id prefixes.** The steps are numbered RF1 to RF6; RF stands for *remote facts*, facts another
plugin publishes. Open questions are RFQ1 to RFQ6.

---

## Why

In plain words: a plugin learns another plugin's facts in one way. An Extension hears the
other plugin's extension point and sends a command to one of its own slices or aggregates,
which records the fact as its own event, and its read models project that. This plan makes
that the only way, and makes it safe when a fact arrives twice.

**The only way.** Since 2024 the framework has carried code for feeding a read model straight
from another plugin's extension point, skipping the plugin's own log. It never ran in any
example, the local platform never delivered it, and since April 2026 plugin assembly rejects
the one declaration that would switch it on. The analysis decided to drop the feature for now
and delete the code
([its §2](../analysis/read-side-fed-from-an-extension-point.md#2-what-existed),
[its §8](../analysis/read-side-fed-from-an-extension-point.md#8-recommendation)). Until then it
costs upkeep on every refactoring, a HANDLER_CONFIG entry and an environment term on AWS, and it
reads as a feature that works. The index it reads also lives in two module-level dictionaries
([Builder_Helpers.res:121-122](../../reventless/core/src/components/Builder_Helpers.res#L121-L122)),
so on the local platform, which builds every plugin in one process, it would be shared across
plugins. A second piece of dormant cross-plugin plumbing goes with it:
`extensionDefinition.dcbSources`, which subscription management reads but nothing fills
([leftovers plan §3](Backlog/cross-plugin-subscription-leftovers.md#3-dcbsources-is-plumbing-with-no-consumer)).

**Once.** Delivery is at-least-once, and nothing on this route drops a repeat. The shop's
[RecordProductDemand decision](../../examples/online-shop-hybrid/catalog/src/ProductDemand/StateChange/RecordProductDemand_Decision.res)
checks the order id by hand, which is the only reason its view's `orderCount + 1` is right. A
slice written without that check counts a redelivered fact twice. The fix needs two things the
chain doesn't have today:

- **A stable id for the fact.** The extension point publishes each event with a fresh `msgId`
  ([ExtensionPointMapping.res:248-252](../../reventless/infra/src/types/ExtensionPointMapping.res#L248-L252)),
  and the Extension gives each command a fresh one too
  ([ExtensionMapping.res:260-264](../../reventless/infra/src/types/ExtensionMapping.res#L260-L264)).
  If either step runs again for the same input, the repeat carries new ids. Neither sets
  `causationId` to its parent, so the chain also loses who caused what, against what
  `deriveMeta` documents.
- **A handler that knows it has seen the command.** A slice's handler already refuses before
  `decide` when ownership fails
  ([StateChangeSlice_Callback.res:393](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L393));
  a repeat is the same kind of check, answered "accepted, nothing new".

This also makes a pair safe to replay into, which an extension-point replay needs
([analysis §4.4](../analysis/read-side-fed-from-an-extension-point.md#44-ways-to-give-an-extension-point-a-replay)).

## Rules every step keeps

1. **Nothing that runs changes until [RF4](#rf4-a-derived-message-gets-a-stable-id).** The
   forwarding path is unreachable today, so [RF1](#rf1-core-the-forwarding-and-its-index-go) to
   [RF3](#rf3-dcbsources-goes) are deletions with no behavior to preserve. The safety check that
   makes it unreachable stays
   ([ReadModel_Builder.res:97-110](../../reventless/core/src/components/ReadModel/ReadModel_Builder.res#L97-L110)).
2. **What stays:** `EventCollector.enqueueEvent` (side-effect handlers, automations and
   outbound translations use it), the read model's and StateView slice's `operations` (the read
   model's is also the readiness Output `finishReadModels` waits on), and
   `pluginDefinition.dcbEventLog` (it describes the plugin's log to more readers than
   subscription management).
3. **Old stored data keeps decoding.** `dcbSources` is persisted in the Plugin lifecycle
   aggregate's events; their fixtures stay as they are and must still pass. Events stored before
   [RF4](#rf4-a-derived-message-gets-a-stable-id) carry random ids and are never mistaken for a
   repeat.
4. **A command nobody derived pays nothing.** A command from the API or a person keeps a random
   `msgId`, and the handler does no extra read for it.
5. **Goldens move in the commit that moves them** (`pnpm run check:graphql:update`,
   `pnpm run check:dcb-scope:update`).
6. **Zero warnings, fresh outputs.** `pnpm run build`, then `pnpm run check:fresh-outputs` and
   `pnpm run test:projects`.

## Steps

Four commits:

1. [RF1](#rf1-core-the-forwarding-and-its-index-go) and
   [RF2](#rf2-aws-the-handler-config-and-the-queue-urls-go) together: the plugin context record
   they share does not compile apart.
2. [RF3](#rf3-dcbsources-goes): it changes a persisted shape and a published schema.
3. [RF4](#rf4-a-derived-message-gets-a-stable-id): it changes what every derived message's
   envelope says.
4. [RF5](#rf5-a-handler-drops-a-command-it-has-already-handled): it changes what a handler does.

[RF6](#rf6-docs-and-plans-say-so) goes into whichever commit its change belongs to; the plan
moves to `done/` in the last one.

### RF1: core, the forwarding and its index go

- [Extension_Operations.res:14-15](../../reventless/core/src/components/Extension/Extension_Operations.res#L14-L15)
  and [175-189](../../reventless/core/src/components/Extension/Extension_Operations.res#L175-L189):
  the two `Ops` fields and the block after the commands, with its `FIXME`.
- [Extension_Builder.res](../../reventless/core/src/components/Extension/Extension_Builder.res),
  [core Extension.res:20-21](../../reventless/core/src/components/Extension/Extension.res#L20-L21)
  and [infra Extension.res:33-34](../../reventless/infra/src/components/Extension.res#L33-L34):
  `~readModelNamesForSourceName` and `~publishToReadModels` leave `construct` and `make`. The
  infra signature is published, so the commit carries a `!` ([RFQ1](#open-questions)).
- [Builder_Helpers.res:121-122](../../reventless/core/src/components/Builder_Helpers.res#L121-L122)
  and [164-177](../../reventless/core/src/components/Builder_Helpers.res#L164-L177): the two
  global dictionaries and the indexing in `createReadModels`.
- [Plugin_Helpers.res](../../reventless/core/src/plugin/component/Plugin_Helpers.res):
  `extensionEntry.readModelNames` (line 126 on), `eventCollectorContext.readModelQueueUrls` and
  `.readModelNamesForSourceName` (line 145 on), and the parameters of `createExtensions`
  (line 252), `createConnectPluginExtension` (line 373) and the context builder
  (line 522 on).
- [Plugin_Builder.res](../../reventless/core/src/plugin/component/Plugin_Builder.res):
  `publishToReadModels` and its `allDict` (lines 653, 666, 720), `readModelQueueUrls`
  (lines 856-867) and the arguments at lines 880-881, 900-901 and 917-918.
- **The assembly check says where to go instead.** When a `Mapping.sourceName` it rejects is
  dotted, as extension point names are (`Ordering.Orders`), the message adds that another
  plugin's events reach a read model through an Extension and a slice, and names the Extension
  doc's section on targeting a slice. A typo keeps today's message.

**Exit:** the build is clean with zero warnings; core and local tests are green;
[DcbReadModelTypoFailFastTest.res](../../reventless/local/tests/components/readmodel/DcbReadModelTypoFailFastTest.res)
covers both messages.

### RF2: AWS, the handler config and the queue URLs go

- [PluginRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res):
  the admin context's two empty fields (lines 349-350), the `PRM_<readModel>_QUEUE_URL`
  variables (lines 432-440), the per-extension `readModelNames` (around line 544), the
  serialized `readModelNamesForSourceName` (lines 551-568), the `PRM_*` names in the
  environment budget (line 578) and `readModelQueueUrls` in `queueUrls.json` (lines 664-665).
- [EventCollectorEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res):
  the fields of `extensionConfig` and `handlerConfig` (lines 97, 111, 120), their parsing
  (lines 199, 214-239, 718), and `extensionDicts.publishToReadModels` and
  `.readModelNamesForSourceName` (lines 636-669) with the `Ops` that receive them.
- [ForeignReadModel_Builder.res](../../reventless/aws/src/components/ForeignReadModel_Builder.res):
  deleted, with its mention in
  [RuntimeEnvironment_Lambda.res:20](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L20).
- [EventCollectorEntryPoint_OpsTest.res](../../reventless/aws/tests/EventCollectorEntryPoint_OpsTest.res):
  the cases for the removed keys (lines 149, 190, 208-228) go; one case keeps a HANDLER_CONFIG
  that still carries them and asserts it parses, so a configuration written before the change
  is ignored, not refused.

**Exit:** AWS tests green. On alpha after the push: the catalog EventCollector Lambda's
environment has no `PRM_*` variable and its HANDLER_CONFIG no `readModelNamesForSourceName`;
placing an order still raises the product's `orderCount` in `ProductDemand`, which is the
Extension → slice → view route this plan keeps.

### RF3: `dcbSources` goes

- [spec Plugin.res:40](../../reventless/spec/src/components/Plugin.res#L40): the field leaves
  `extensionDefinition`.
- [Plugin_Helpers.res:362-370](../../reventless/core/src/plugin/component/Plugin_Helpers.res#L362-L370)
  and [local Platform.res:1258](../../reventless/local/src/Platform.res#L1258): no longer written.
- [EventCollectorEntryPoint_Ops.res](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res):
  its parsing (line 291) and the two DCB branches of `manageSubscriptions` (lines 456-497), the
  one subscribing this plugin's queue to a peer's DCB topic and the one subscribing peers to
  this plugin's.
- Tests and fixtures written in code:
  [LogFormatTest.res:66](../../reventless/core/tests/logger/LogFormatTest.res#L66),
  [MessageTest.res:37](../../reventless/core/tests/message/MessageTest.res#L37),
  [local Plugin_Fixtures.res:11](../../reventless/local/tests/plugin/Plugin_Fixtures.res#L11),
  [EventCollectorEntryPoint_OpsTest.res:49-62](../../reventless/aws/tests/EventCollectorEntryPoint_OpsTest.res#L49-L62).
- [pluginDefinitionRequiredScalars.txt:44](../../reventless/core/tests/plugin/pluginDefinitionRequiredScalars.txt#L44):
  the line goes. Removing a field is the safe direction of that tripwire: stored payloads carry
  a key the decoder now ignores, and nothing is invented.
- **The stored fixtures stay untouched.** The Plugin lifecycle corpus under
  [tests/fixtures/plugin-lifecycle/](../../reventless/core/tests/fixtures/plugin-lifecycle/)
  carries `dcbSources` in `VersionConnected` and `VersionSuperseded` events; the corpus test
  must stay green on them, which is what proves old events still decode.
- Goldens: [platform-api.graphql:202](../../reventless/spec/schema/platform-api.graphql#L202)
  and [the hybrid domain-api.graphql:1275](../../examples/online-shop-hybrid/schema/domain-api.graphql#L1275)
  lose the field, refreshed with `pnpm run check:graphql:update`. Nothing in this repo selects
  it; check that the UI kit doesn't either before the push ([RFQ2](#open-questions)).

**Exit:** build clean; the corpus test green with the old fixtures; `pnpm run check:graphql`
green after the refresh; on alpha, a plugin connects and its EP subscriptions are created as
before.

### RF4: a derived message gets a stable id

Every place a mapping makes a message from another message derives its envelope the way
`deriveMeta` documents, and makes its `msgId` a function of its input:

- **Where:** the extension point's published events
  ([ExtensionPointMapping.res:192](../../reventless/infra/src/types/ExtensionPointMapping.res#L192),
  [248-252](../../reventless/infra/src/types/ExtensionPointMapping.res#L248-L252) and the async
  arm after it) and the Extension's commands
  ([ExtensionMapping.res:260-264](../../reventless/infra/src/types/ExtensionMapping.res#L260-L264)).
- **`causationId`** is the parent's `msgId`, not the parent's own `causationId`.
- **`msgId`** is a name-based UUID (`Uuid.v5`, already bound in
  [rescript-uuid](../../rescript/uuid/src/Uuid.res)) over the parent's `msgId`, the emitter's
  name and the action's index in the mapping's result. A mapping that runs again on the same
  input produces the same ids; two different inputs or two actions of one input never collide.
- One helper in `Message` does it (`Message.deriveStableMeta(~parent, ~emitter, ~index)` or
  similar), so both mappings and later callers share one rule.

The provider's own event already has a stable `msgId`: the slice and aggregate handlers derive
it once and store it with the event, so a stream redelivery carries the same one. The chain from
the provider's event to the consumer's command is then stable end to end.

**Exit:** a unit test in `MessageTest` for the helper (same input, same id; different index,
different id); a local test that runs an extension point's mapping twice on one stored event and
gets the same published `msgId`, and an Extension's mapping twice on one published event and gets
the same command `msgId`; `causationId` asserted along the chain. Nothing that compares events
by their encoded wire form changes, since GWT compares payloads, not envelopes; run the full
suite to confirm.

### RF5: a handler drops a command it has already handled

A command whose `msgId` was derived ([RF4](#rf4-a-derived-message-gets-a-stable-id)) is checked
before `decide`, next to the ownership refusal: if the target already holds an event caused by
this command, the handler accepts it with no new events and logs the repeat.

- **Which commands:** those the Extension sends. The Extension marks them, so a random-id
  command skips the check (rule 4). A header in `meta.headers` is enough; the exact key is
  settled in the step.
- **Aggregates:** the handler already replays every event of the instance, with its stored
  meta, before deciding
  ([Aggregate_Callback.res:58](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res#L58)
  shows where events get the command as their parent). It collects the `causationId`s while it
  folds and compares. The sequence condition on append already stops two concurrent copies
  from both writing.
- **DCB slices:** the decision read covers only the consumed events, which need not include the
  slice's own. Events appended for a marked command carry a partition-scoped tag holding the
  command's `msgId`; the handler queries that tag in the command's partition before deciding,
  and the append condition includes it, so two concurrent copies can't both append. How the
  tag is stored follows the partition-scoped tag rules ([RFQ5](#open-questions)).
- **A decision that produced nothing** the first time leaves no event to find. The repeat runs
  `decide` again, and an `Ok([])` decision stays `Ok([])`, which is the idempotency rule the
  framework already asks of decisions.
- **The shop's demand decision keeps its own check.** It states a business rule (an order counts
  once per product) beyond redelivery; a new test shows the framework's drop without it.

**Exit:** local tests deliver one extension-point event twice to an Extension whose slice has no
check of its own, and twice to one whose target is an aggregate; each appends once. The same
for two concurrent copies on SQLite. `pnpm run check:dcb-scope` green, its golden refreshed if
the tag shows there. On alpha, an order placed once records one demand, as before.

### RF6: docs and plans say so

- [aggregate-extension-connection.md](../../packages/doc/docs-app/concepts/aggregate-extension-connection.md)
  (its *Step 3: Passing to Extensions*): `~publishToReadModels` leaves the snippet.
- [extension.md](../../packages/doc/docs-app/components/extension.md): under *Targeting a
  StateChangeSlice instead of an Aggregate*, that this is how a view gets another plugin's
  facts, that a read model cannot hear an extension point directly, and that a repeated fact is
  dropped by the framework.
- [messages.md](../../packages/doc/docs-framework/internals/messages.md): derived messages carry
  their parent as `causationId` and a stable `msgId`.
- [effect-runtime-dispatch.md](Backlog/effect-runtime-dispatch.md): its step 4 (the `FIXME` in
  `Extension_Operations`) is struck as removed by [RF1](#rf1-core-the-forwarding-and-its-index-go).
- [lambda-environment-size-ceiling.md](lambda-environment-size-ceiling.md): its step 2 drops
  the `PRM_*` half, which [RF2](#rf2-aws-the-handler-config-and-the-queue-urls-go) removes.
- [cross-plugin-subscription-leftovers.md](Backlog/cross-plugin-subscription-leftovers.md):
  [§3](Backlog/cross-plugin-subscription-leftovers.md#3-dcbsources-is-plumbing-with-no-consumer)
  is decided as *remove* and done by [RF3](#rf3-dcbsources-goes).
- [The analysis](../analysis/read-side-fed-from-an-extension-point.md): its status line notes
  that [§8](../analysis/read-side-fed-from-an-extension-point.md#8-recommendation) steps 1 and 2
  are done, linking this plan in `done/`, and its
  [RSQ3](../analysis/read-side-fed-from-an-extension-point.md#11-open-questions) is answered.
- Done plans that mention the removed names stay as history.

**Exit:** no file outside `docs/plans/done/` and the analysis mentions
`readModelNamesForSourceName`, `publishToReadModels`, `readModelQueueUrls`, `PRM_`,
`ForeignReadModel` or `dcbSources`, checked with `git grep`.

## Out of scope

- An extension-point replay (the analysis's
  [§8](../analysis/read-side-fed-from-an-extension-point.md#8-recommendation) step 3): its own
  analysis when a reason comes up. [RF5](#rf5-a-handler-drops-a-command-it-has-already-handled)
  is what makes a replay into a pair safe.
- Follow-up commands from automations: they have the same repeat problem, and
  [RF4](#rf4-a-derived-message-gets-a-stable-id)'s helper fits them too ([RFQ6](#open-questions)).
- `pluginDefinition.dcbEventLog`: it stays; only its use by the removed DCB branches goes.

## Open questions

**RFQ1. Does anything outside this repo implement or call `ReventlessInfra.Extension.T`'s
`make` with the two arguments [RF1](#rf1-core-the-forwarding-and-its-index-go) removes?**
**Recommendation: treat it as breaking anyway: mark the commit `refactor!` and name the two
arguments in its body.** The builder is internal in practice, but the signature is published,
and the marker costs nothing on alpha. Revisit if a downstream package turns up that calls it;
then give it a release note with the replacement (none: the arguments did nothing).

**RFQ2. Does the UI kit's admin surface select `dcbSources` from the platform API?**
**Recommendation: check before [RF3](#rf3-dcbsources-goes) is pushed, and if it does, drop the
selection there first and release it.** A query that selects a removed field fails as a whole,
so the order matters. Nothing in this repo selects it; this repo can't see the UI kit's
queries.

**RFQ3. Should [RF3](#rf3-dcbsources-goes) also delete subscription management's other reads of
`pluginDefinition.dcbEventLog` (lines 256-272 and 463-489)?**
**Recommendation: delete the reads only the two removed branches used, and keep the field.**
The field describes the plugin's log to other readers; reads nobody acts on are the same kind of
dormant code this plan removes. Revisit if one of those reads turns out to feed a log line or a
status someone uses.

**RFQ4. Does anything rely on a derived `msgId` being random?**
**Recommendation: no change needed, confirmed by running the full suite on both backends in
[RF4](#rf4-a-derived-message-gets-a-stable-id).** The local platform tracks pending appends by
`msgId`, and logs and dead-letter dumps show it; a stable id stays unique per input and is equal
only for a true repeat, which is the point. Revisit if a test or a store keys something on
`msgId` being fresh per delivery attempt.

**RFQ5. For DCB slices, is the repeat found by a dedicated tag holding the causing command's id,
or by folding the slice's own events in the decision read?**
**Recommendation: the tag.** It costs one key per event and one query, but it works for a slice
that doesn't read its own events, and the same tag carries the append condition that stops two
concurrent copies. Revisit if `check:dcb-scope` or the partition-scoped tag rules make an extra
key expensive; then require noting slices to read their own events and fold.

**RFQ6. Should automations' follow-up commands get stable ids and the drop in this plan?**
**Recommendation: not in this plan; after it, reusing both pieces.** The helper and the check fit
them unchanged, but no slice has yet been seen to count a repeated automation command, and the
plan is already four commits. Revisit as soon as one does, or when an extension-point catch-up
is built, since its consumers' automations then see historical facts.
