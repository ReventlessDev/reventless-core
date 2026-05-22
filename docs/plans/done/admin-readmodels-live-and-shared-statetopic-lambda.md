# Plan: Admin ReadModels Live-Update + Shared StateTopic Lambda

## Status: Completed

### Implementation notes
- **UIFragmentRegistry deviation**: The plan listed all three admin RMs to swap
  to `ReadModel_Builder_Single_Stream.Make`, but `UIFragmentRegistryReadModel`
  previously used `ReadModel_Builder_NoResolver` because its GraphQL field
  (`Platform_UIFragments`) is served by a dedicated `Platform_UIFragments_Lambda`,
  not an auto-generated resolver. Switching to `_Single_Stream` would have
  attached an unwanted resolver. A new `ReadModel_Builder_NoResolver_Stream`
  variant was added (stream-enabled storage, no resolvers) and used here.
- **Registry key**: `AppSync_EventsApi.t` now carries a static `name: string`
  field (e.g. `"DomainEventsApi"`) — the registry key. Avoided the URN-based
  approach because `Pulumi.Output.t<string>` can't be used as a Map key.
- **`finish` call sites**: Called from three places — `makePlatform` (monolithic
  mode), `deployPlatform` (split-mode platform stack with admin only), and
  `deployPlugin` (each plugin stack). Each Pulumi run drains the in-process
  registry independently, so each stack produces one shared Lambda for its
  stream-enabled tables.
- **Admin DCB streams**: The Phase 1 hook params (`eventLogEntries`) include
  admin DCB entries; no admin DCB `StateViewSliceStream` currently exists,
  so this is exercised only when one is added.

Two coupled changes that together close the "admin lists don't live-update"
gap and reduce per-RM Lambda overhead:

1. Make the framework's built-in admin ReadModels (`Plugins`,
   `Platform_EventGraph`, `UIFragmentRegistry`) emit DynamoDB Streams and
   participate in AppSync Events (Source B) live updates.
2. Consolidate the per-RM `StateTopic_AppSync` Lambda fleet into **one
   shared Lambda per events API** that handles **every** stream-enabled
   QueryDb in the platform — admin RMs, user-plugin `ReadModelStream`s,
   and `StateViewSliceStream`s alike. This is not an admin-only change:
   admin and user streams flow through the same `subscriptionInfraHook`
   funnel and the same registry; the shared Lambda is the union.

Both are in `reventless-aws` + `reventless-core` (admin path). No UI changes
needed — the UI already handles arbitrary Source B channels uniformly.

---

## Why bundle these together

Switching admin RMs to Stream multiplies the number of stream-enabled
QueryDbs by ~3 (one per admin RM), and most platforms also have several
user-plugin streams. The framework currently provisions one Lambda + IAM
role + EventSourceMapping per stream-enabled RM
(`reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res:267`),
so the admin switch alone meaningfully grows the per-platform Lambda
count. Doing the consolidation in the same plan avoids changing the
subscription wiring twice and keeps the cost model honest.

---

## Background

- `StateTopic_AppSync.make` today: creates one IAM role, one policy, one
  Lambda function, and one EventSourceMapping per stream-enabled QueryDb.
  Handler code is generated with `TOPIC_ROOT` baked in at deploy time.
- `subscriptionInfraHook` is invoked from `Plugin_Builder` only. Admin
  read models, constructed via `Platform_Admin.construct`, never fire it.
- Admin read models currently use `ReadModel_Builder_Single` (no stream),
  not `ReadModel_Builder_Single_Stream`. So even if the hook ran, the
  `streamRegistry` would be empty for admin RMs.
- A Lambda invocation event from a DDB stream carries
  `record.eventSourceARN` — the stream ARN — on every record, so a
  shared Lambda can route per-record to the right channel.

---

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Admin RM stream variant | Swap to `ReadModel_Builder_Single_Stream.Make` | Same builder user plugins use via `Platform.ReadModelStream.Make` (commit `3d816fb50`) |
| Admin hook surface | Reuse existing `Plugin_Helpers.subscriptionInfraParams` / `subscriptionInfraHook` field; thread through `Platform_Admin.Config.hooks` | Symmetric with `Plugin_Builder`; no second mechanism to maintain |
| Lambda consolidation scope | One shared Lambda **per events API** (Domain / Platform in split mode) | Same auth + endpoint per API; mixing across APIs would complicate IAM and env vars |
| Stream-to-topic mapping at runtime | Env var `STATE_TOPIC_MAP` = `{"<tableName>":"<topicName>"}`; handler extracts tableName from `record.eventSourceARN` | Avoids hardcoding stream ARNs (which Pulumi can resolve to long opaque strings); table names are deterministic and stable |
| Lambda creation timing | Lazy register-then-finish: `StateTopic_AppSync.make` appends to a registry; `StateTopic_AppSync.finish(~eventsApi, ~opts)` builds Lambda + IAM + all ESMs after Admin + plugins have wired | Pulumi can't append to an existing policy; one finalize call collects the full set |
| Resource naming | Derive from the events API: `<eventsApi.name>StateTopicLambda` / `Role` / `Policy`; ESMs `<topicName>2<eventsApi.name>StateTopic` | Mirrors `AppSync_EventsApi.make`'s `<apiName>DefaultNS` convention; one consistent set of names per events API; no collision in split-API mode where Domain + Platform each get their own shared Lambda |
| Per-stream ESM | Kept (one ESM per stream, all targeting the shared Lambda) | DDB Stream → Lambda fan-in requires per-stream ESM; no other mechanism |
| In-memory parity | None — in-memory has no streams; `Platform.ReadModelStream` already aliases `Platform.ReadModel` there | Stream-specific infra is AWS-only |
| Update path | Accept the Pulumi delete-and-create churn for the per-RM Lambdas on first deploy | Brief publish gap during the swap; no data loss; alpha-deployable |

---

## File map

### Modified

| Package | File | Change |
|---|---|---|
| `reventless-core` | `src/admin/Platform_Admin.res` | After `allQueryDbs` + `allEventTopics` assembly, fire `Config.hooks.subscriptionInfraHook` with the assembled params (same shape as `Plugin_Builder`) |
| `reventless-aws` | `src/Platform.res` | Swap `PluginReadModel`, `PlatformEventGraphReadModel`, `UIFragmentRegistryReadModel` to `ReadModel_Builder_Single_Stream.Make`; pass `subscriptionInfraHook` into the Admin `Config.hooks` record; call `StateTopic_AppSync.finish` once after plugins + admin run (per active events API) |
| `reventless-aws` | `src/adapter/StateTopic/StateTopic_AppSync.res` | Refactor to register-then-finish. `make` accumulates a per-events-API entry `{tableName, streamArn, topicName, ddbResource, opts}`; new `finish(~eventsApi, ~opts)` constructs the shared Lambda + role + policy + per-stream ESMs. Handler code is parameterised at runtime via `STATE_TOPIC_MAP` env var |
| `reventless-core` | `docs/guides/appsync-events-live-updates.md` | Document the shared-Lambda model; note that admin RM lists now live-update |

### New

| Package | File | Purpose |
|---|---|---|
| — | — | No new modules; this is a refactor + an admin swap |

---

## Phases

### Phase 1 — Admin subscriptionInfraHook plumbing

**`Platform_Admin.res`:**
- `Config` already exposes `hooks: Plugin_Helpers.platformHooks` which includes the optional `subscriptionInfraHook`.
- After `allQueryDbs` is fully assembled (line 244, plus the DCB-slice merges at 248–253) and `allEventTopics` is known, invoke the hook:
  ```rescript
  Config.hooks.subscriptionInfraHook->Option.forEach(hook =>
    hook({allQueryDbs, allEventTopics, eventLogEntries, opts})
  )
  ```
- `eventLogEntries` for admin: the admin Plugin aggregate's EventTopic plus any DCB log built inside admin's `DcbBuilder.construct`. Reuse the same arrays that `Plugin_Builder` builds so the hook receives a consistent shape.
- The hook must run **before** `createResolvers` so a downstream
  StateTopic Lambda creation is part of the resolver-barrier dependency
  graph (the hook itself doesn't block — Pulumi handles ordering — but
  putting it before keeps the construction order intuitive).

**Acceptance**
- Build clean.
- Admin construction still works with no hook installed (in-memory platform).
- A test or smoke run: AWS Platform passes the hook through, log a debug line in the hook showing it received admin's allQueryDbs.

---

### Phase 2 — Switch admin read models to Stream

**`Platform.res`:**
- Swap all three admin RM builders:
  ```rescript
  module PluginReadModel = ReadModel_Builder_Single_Stream.Make(
    ReventlessCore.PluginsReadModelSpec,
    PluginReadModelMappings,
  )
  module PlatformEventGraphReadModel = ReadModel_Builder_Single_Stream.Make(
    ReventlessCore.Platform_EventGraphReadModelSpec,
    PlatformEventGraphMappings,
  )
  module UIFragmentRegistryReadModel = ReadModel_Builder_Single_Stream.Make(
    ReventlessCore.UIFragmentRegistryReadModelSpec,
    UIFragmentRegistryMappings,
  )
  ```
- Wire the `subscriptionInfraHook` into `Admin = Platform_Admin.Make(...)`'s
  `hooks` record. Phase 3 is what makes that hook actually fan out; Phase
  2's deploy still creates per-RM Lambdas (one per admin RM).

**Acceptance**
- Build clean.
- AWS smoke deploy: each admin RM table has `StreamSpecification` enabled in DynamoDB. Three new `*StateTopicLambda` resources appear in stack outputs.
- Trigger an admin mutation (e.g. Plugin aggregate emitting an event); confirm a descriptor reaches the `Platform-Plugins/*` channel.

---

### Phase 3 — Shared `StateTopic_AppSync` Lambda

**Registry refactor:**

```rescript
// StateTopic_AppSync.res

type streamEntry = {
  tableName: Pulumi.Output.t<string>,
  streamArn: Pulumi.Output.t<string>,
  topicName: string,                    // already-resolved listFieldName
}

// One registry per events API (Domain / Platform — keyed by api ARN or name).
let registry: Map.t<string, array<streamEntry>> = Map.make()

let make = (
  ~readModelName,
  ~topicName,
  ~allQueryDbs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts as _,
) => {
  let streamResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(readModelName)
    ->Util_DynamoDbStream.findResource
  let streamArn = Util_DynamoDbStream.streamArnFromDynamoDbTableResource(streamResource)
  let tableName = streamResource.name->Pulumi.Output.make  // verify exact field
  let entries =
    registry->Map.get(eventsApi.api.apiArn->magicKey)->Option.getOr([])
  registry->Map.set(eventsApi.api.apiArn->magicKey, entries->Array.concat([{tableName, streamArn, topicName}]))
}
```

(`magicKey` is a stable string lookup; one option is to use the events API's
Pulumi resource URN as the registry key — it's resolved to a string after
construction.)

**New finalize:**

```rescript
let finish = (~eventsApi: AppSync_EventsApi.t, ~opts) => {
  let key = eventsApi.api.apiArn->magicKey
  switch registry->Map.get(key) {
  | None | Some([]) => ()
  | Some(entries) =>
    // 1) IAM role
    let lambdaRole = IAM.Role.makeWithDefaultPolicy(
      ~name="<eventsApi.name>StateTopicRole",
      ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
      ~opts,
    )

    // 2) IAM policy — DDB stream resources collected from all entries
    let streamArns = entries->Array.map(e => e.streamArn)->Pulumi.Output.all
    let _ = (streamArns, eventsApi.api.apiArn)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((arns, apiArn)) => {
        IAM.RolePolicy.make(
          ~name="<eventsApi.name>StateTopicPolicy",
          ~args={ /* policy with Resource(arns) on AllowReadDynamoDbStream
                     and Resource(apiArn ++ "/*") on AllowPublishAppSyncEvents */ },
          ~opts,
        )
      })

    // 3) Lambda — handler reads STATE_TOPIC_MAP at cold start
    let topicMapJson =
      entries
      ->Array.map(e => e.tableName->Pulumi.Output.apply(t => (t, e.topicName)))
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(pairs =>
        pairs->Js.Dict.fromArray->Js.Json.object_->Js.Json.stringify
      )

    let lambda = Lambda.Function.make(
      ~name="<eventsApi.name>StateTopicLambda",
      ~args={
        handler: "index.handler"->Pulumi.Input.make,
        runtime: "nodejs22.x"->Pulumi.Input.make,
        code: ..., /* shared handler code, no per-call substitution */
        role: lambdaRole.arn->Pulumi.Output.asInput,
        memorySize: 256->Pulumi.Input.make,
        timeout: 30->Pulumi.Input.make,
        environment: {
          variables: Dict.fromArray([
            ("APPSYNC_ENDPOINT", AppSync_EventsApi.httpEndpoint(eventsApi)->Pulumi.Output.asInput),
            ("STATE_TOPIC_MAP", topicMapJson->Pulumi.Output.asInput),
          ]),
        }->Pulumi.Input.make,
      },
      ~opts,
    )

    // 4) One ESM per stream, all pointing to the shared Lambda
    entries->Array.forEach(e => {
      EventSourceMapping.make(
        ~name=e.topicName ++ "Stream2" ++ eventsApi.api.name ++ "StateTopic",
        ~args={
          functionName: lambda.arn->Pulumi.Output.asInput,
          eventSourceArn: e.streamArn->Pulumi.Output.asInput,
          startingPosition: LATEST,
        },
        ~opts=Some(opts),
      )
    })

    // 5) Clear the registry so a second platform construction in the same
    //    process (tests, dev hot reload) starts fresh.
    registry->Map.set(key, [])
  }
}
```

**Handler code change** (parameterised at runtime):

```javascript
// reads STATE_TOPIC_MAP once at cold start
const TOPIC_MAP = JSON.parse(process.env.STATE_TOPIC_MAP || "{}");

function topicRootFromEventSourceArn(arn) {
  // arn:aws:dynamodb:<region>:<acct>:table/<TableName>/stream/<ts>
  const m = arn.match(/:table\/([^/]+)\/stream\//);
  if (!m) return undefined;
  return TOPIC_MAP[m[1]];   // returns the listFieldName already passed in
}

export async function handler(event) {
  const url = new URL(APPSYNC_ENDPOINT);
  for (const record of event.Records) {
    const topicRoot = topicRootFromEventSourceArn(record.eventSourceARN);
    if (!topicRoot) {
      console.warn("StateTopic: unknown table for ARN", record.eventSourceARN);
      continue;
    }
    const TOPIC_ROOT = "/default/" + topicRoot.replaceAll("_", "-");
    // …rest of the existing per-record flow (entityKey, descriptor, fetch)
  }
}
```

**`Platform.res` finalize:**

After `Admin.construct(...)` returns and all plugins are wired, call:

```rescript
domainEventsApiOpt->Option.forEach(api =>
  StateTopic_AppSync.finish(~eventsApi=api, ~opts=customOpts)
)
platformEventsApiOpt->Option.forEach(api =>
  StateTopic_AppSync.finish(~eventsApi=api, ~opts=customOpts)
)
```

(Or one call covering both APIs — whichever shape matches the existing
two-API split. The registry is keyed by API, so the finalize is naturally
per-API.)

**Acceptance**
- Build clean.
- Single `<eventsApi.name>StateTopicLambda` resource per events API (e.g. `DomainEventsApiStateTopicLambda`, and in split mode also `PlatformEventsApiStateTopicLambda`).
- `STATE_TOPIC_MAP` env var on the Lambda has entries for every stream-enabled RM (admin + user plugins).
- One ESM per stream, all pointing at the shared Lambda.
- DDB write on any admin or user RM table → descriptor lands on its channel.
- Pre-existing per-RM Lambdas are destroyed by Pulumi on deploy.

---

### Phase 4 — Documentation

**`docs/guides/appsync-events-live-updates.md`:**

- Update the "Deploy-time wiring" table: the per-read-model StateTopic
  Lambda row becomes a **single platform-wide StateTopic Lambda per
  events API**, with one EventSourceMapping per stream-enabled QueryDb.
- Mention that admin lists (`Platform_Plugins`, `Platform_PlatformEventGraphs`,
  `Platform_UIFragmentRegistries`) now live-update.
- Note the `STATE_TOPIC_MAP` env var and the eventSourceARN-based routing
  for future debuggers.

**Acceptance**
- Guide reflects the new wiring.

---

## Verification plan (manual, on alpha)

1. Deploy the branch to alpha. Confirm in CloudWatch:
   - Exactly one `*<eventsApi.name>StateTopicLambda` resource per events API.
   - `STATE_TOPIC_MAP` env var lists every stream-enabled RM.
2. Open the Platform plugins list in the host-shell admin console.
3. Trigger an admin mutation (Plugin Deactivate via AppSync).
4. Within ~1s the list updates without reload.
5. Repeat for a user-plugin list to confirm regression-free.
6. CloudWatch logs of the shared Lambda show records routed to each topic
   based on `eventSourceARN` lookup.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Cold-start concurrency on the shared Lambda | 256MB memory + `LATEST` startingPosition. Tune ESM `parallelizationFactor` / `batchSize` per-stream if needed. Lambda concurrency is per-account-per-region — the consolidation reduces total provisioned concurrency, not the burst |
| Pulumi delete-then-create of old per-RM Lambdas during the deploy | Brief publish gap (seconds). Acceptable on alpha; flag in the deploy notes for prod |
| `STATE_TOPIC_MAP` resolution timing | `topicName` is the resolved `listFieldName` (already a `string` at deploy time, not a Pulumi.Output). `tableName` from the DDB resource is an Output → composed via `Pulumi.Output.all`. The env var is wrapped in an Input |
| Cross-events-API leakage in split mode | The registry is keyed per events API → two separate shared Lambdas, two separate `STATE_TOPIC_MAP` payloads. Admin RMs go to the platform API's Lambda; user-plugin RMs go to the domain API's Lambda (or both if the platform isn't split) |
| Admin DCB streams sneaking in | The same hook fires for admin DCB StateViewSliceStream tables once Phase 1 + the appropriate stream storage is used; they go through the same registry path. Out-of-scope here whether admin DCB slices need to live-update — flag if surfaced |
| Stale stream ARN in IAM policy after a table rename | DynamoDB stream ARNs are stable across renames at the resource level; the Output flows through Pulumi so a recreate cascades to the policy update |
| Tests that import `StateTopic_AppSync.make` directly | The new `make` no longer creates resources — it just registers. Any unit test that asserts on the per-call Lambda will break. Audit during Phase 3 |

---

## Open questions

1. **Lambda layer.** Per-RM Lambdas attach `Lambda.reventlessLayerArn` (the shared reventless aws layer, see existing code lines 259-263). The shared Lambda should attach the same layer; verify no per-RM-specific layer customisations exist.
2. **Memory + timeout tuning.** Current per-RM: 128MB / 30s. Shared Lambda probably wants 256MB / 30s (more concurrent records to process). Confirm via CloudWatch p99 invocation duration after first deploy.
3. **EventSourceMapping name churn.** Today `${name}Stream2${name}StateTopic` (RM-scoped). New naming `${topicName}Stream2${eventsApi.name}StateTopic` (events-API-scoped). Pulumi will see this as new resources and the old ones as removed. Acceptable on alpha; flag for the prod deploy notes.
4. **Should the shared Lambda also publish to the EventLogSubscription channel** (Source A)? Currently Source A is a separate `EventLogSubscription_AppSync` per SNS topic. Keep them separate in this plan — Source A reads from SQS, not DDB streams, so a unified Lambda would mix two trigger types. Revisit only if Source A also grows expensive.

---

## Dependencies

- Builds on commit `3d816fb50` (`ReadModelStream` variant) — already shipped.
- Builds on the Tier 1 reconnect refetch (UI) — already shipped. The two
  together mean: admin lists live-update under normal operation AND
  refetch correctly on reconnect.

---

## Out of scope

- OnPublish coalescer for burst suppression (realtime-change-descriptors §4).
- Position-on-descriptor (realtime-change-descriptors §3).
- Tier 2 server-side change journal (`catchUpChanges`).
- Source A Lambda consolidation (different trigger model).
- Aggregate `EventTopicPublisher_DynamoDbStream` consolidation — that's a
  separate, also-per-stream Lambda fleet; logically similar but different
  payload and downstream.

---

## Checklist

### Phase 1 — Admin hook plumbing
- [ ] `Platform_Admin.res` invokes `Config.hooks.subscriptionInfraHook` after `allQueryDbs` + `allEventTopics` assembly
- [ ] `eventLogEntries` shape matches what `Plugin_Builder` passes
- [ ] In-memory + AWS builds clean

### Phase 2 — Admin RMs to Stream
- [ ] `PluginReadModel` uses `ReadModel_Builder_Single_Stream.Make`
- [ ] `PlatformEventGraphReadModel` uses `ReadModel_Builder_Single_Stream.Make`
- [ ] `UIFragmentRegistryReadModel` uses `ReadModel_Builder_Single_Stream.Make`
- [ ] `subscriptionInfraHook` passed into Admin's `Config.hooks`
- [ ] Smoke deploy: admin RM tables have DDB Streams enabled

### Phase 3 — Shared Lambda
- [ ] `StateTopic_AppSync.make` becomes register-only
- [ ] `StateTopic_AppSync.finish(~eventsApi, ~opts)` builds shared Lambda + IAM + ESMs
- [ ] Handler reads `STATE_TOPIC_MAP` env var; routes by `eventSourceARN`
- [ ] `Platform.res` calls `finish` for each active events API after admin + plugins
- [ ] Per-API registry keying verified (Domain vs Platform in split mode)
- [ ] Build clean

### Phase 4 — Docs
- [ ] `appsync-events-live-updates.md` updated (shared-Lambda model + admin RMs live)
- [ ] Plan moved to `docs/plans/done/`

---

## Verification (manual)

- [ ] Deploy to alpha; confirm exactly one `*<eventsApi.name>StateTopicLambda` per events API
- [ ] `STATE_TOPIC_MAP` env var inspected; one entry per stream-enabled RM
- [ ] Admin Plugin mutation → `Platform_Plugins` AutoUI list refreshes without reload
- [ ] User-plugin mutation → existing live-update behaviour unaffected
- [ ] CloudWatch logs show eventSourceARN-driven topic routing
