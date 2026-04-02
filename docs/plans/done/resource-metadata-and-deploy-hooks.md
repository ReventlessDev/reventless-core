# Resource Metadata and Deploy Lifecycle Hooks

## Context

The framework provides hooks that fire during plugin construction (`onPluginBuilt`) but has no hooks for the deploy completion lifecycle — when all Pulumi Outputs have resolved and resource identifiers (IDs, URNs) are available. Additionally, the `Adapter.resource` type uses a catch-all `info: string` field whose semantics vary by service type, and resources lack a `role` field to identify their function within a component.

This plan adds deploy lifecycle hooks, enriches resource metadata, and improves the data available to external consumers (admin tools, monitoring, introspection APIs).

---

## Status

### Required

| Step | Description | Status |
|------|-------------|--------|
| 1 | Add `onPluginDeployed` hook with resolved resource data | done |
| 2 | Add `onPlatformDeployed` hook | done |
| 3 | Enrich `pluginBuiltInfo` with per-component schema details | done |
| 4 | Export admin component resources from `deployPlatform` | done |
| 5 | Add extension wiring metadata to plugin exports | done |
| 6 | Replace `Adapter.resource.info` with typed `resourceInfo` | done |
| 7 | Add `role` field to `Adapter.resource` | done |

### Nice-to-Have

| Step | Description | Status |
|------|-------------|--------|
| 8 | Add Reventless resource tags to AWS resources | done |
| 9 | Add stack metadata export (environment, region, timestamp, actor, git SHA) | done |
| 10 | Add `region` field to `Adapter.resource` | done |
| 11 | Add `resourceType` field to `Adapter.resource` | done |
| 12 | Add `configuration` field to `Adapter.resource` | done |
| 13 | Prefix `service` field values with provider namespace | done |

---

## Step 1 — `onPluginDeployed` hook

**Files:** `Plugin_Helpers.res`, `Plugin_Builder.res` (or `exportPluginOutputs`)

A new hook that fires after all Pulumi Outputs for a plugin's components have resolved. Unlike `onPluginBuilt` (which fires synchronously with plain component names/kinds), `onPluginDeployed` fires inside `Output.apply` with fully resolved resource data.

**Types:**

```rescript
type pluginDeployedComponent = {
  name: string,
  kind: string,
  schema: pluginDeployedSchema,         // per-component schema details (Step 3)
  resources: array<Resource.t>,         // fully resolved (name, id, urn, info, service)
  subComponents: array<{
    role: string,                        // "eventLog", "commandTopic", "queryDb", etc.
    resources: array<Resource.t>,
  }>,
}

type pluginDeployedInfo = {
  name: string,
  version: string,
  environment: string,                  // from Pulumi stack name or config
  stackName: string,                    // full Pulumi stack identifier
  components: array<pluginDeployedComponent>,
}

let onPluginDeployedHook: ref<option<pluginDeployedInfo => unit>> = ref(None)

let registerOnPluginDeployed = (hook: pluginDeployedInfo => unit) => {
  onPluginDeployedHook.contents = Some(hook)
}

let clearOnPluginDeployed = () => {
  onPluginDeployedHook.contents = None
}
```

**Where it fires:** Inside `exportPluginOutputs` (or alongside it) in `Plugin_Helpers.res`. At this point, all component `toResolvedOutputs` conversions have run and the data is plain JSON. The hook receives the same data that gets exported via `Pulumi.export`, plus the environment and stack name.

**Environment resolution:** Read from `Pulumi.getStack()` (returns the stack name like `alpha` or `prod`) or from an explicit config value `Pulumi.Config.make(None)->Pulumi.Config.get("environment")`.

## Step 2 — `onPlatformDeployed` hook

**Files:** `Plugin_Helpers.res`, `Platform.res` (in both reventless-aws and reventless-in-memory)

Fires after `deployPlatform` / `makePlatform` completes, providing platform-level metadata.

```rescript
type platformDeployedInfo = {
  name: string,                         // from Pulumi project name or config
  environment: string,                  // from Pulumi stack name or config
  region: string,                       // from Pulumi config or AWS provider
  apiId: string,                        // AppSync API ID (resolved)
  apiRoleArn: string,                   // AppSync role ARN (resolved)
  splitApiMode: bool,
  adminResources: array<Resource.t>,    // Plugin aggregate + ReadModel tables/Lambdas
}

let onPlatformDeployedHook: ref<option<platformDeployedInfo => unit>> = ref(None)
let registerOnPlatformDeployed = (hook: platformDeployedInfo => unit) => { ... }
let clearOnPlatformDeployed = () => { ... }
```

**Where it fires:** At the end of `deployPlatform` in `Platform.res` (reventless-aws), inside an `Output.apply` that resolves the API ID and admin resource data. In reventless-in-memory, fires at the end of `makePlatform` with mock/in-memory values.

## Step 3 — Enrich `pluginBuiltInfo` with per-component schema

**Files:** `Plugin_Helpers.res`, `Plugin_Builder.res`

Extend the existing `pluginBuiltInfo` (from `onPluginBuilt`) and the new `pluginDeployedComponent` with per-component schema information extracted from the component specs.

```rescript
type pluginDeployedSchema = {
  // Aggregate / StateChangeSlice
  commandTypes?: array<string>,         // variant names from commandSchema
  eventTypes?: array<string>,           // variant names from eventSchema
  errorTypes?: array<string>,           // variant names from errorSchema (Aggregate only)
  // ReadModel / StateViewSlice / AutomationSlice
  stateType?: string,                   // serialized state shape from stateSchema
  sourceNames?: array<string>,          // ReadModel: which aggregates feed this projection
  queryFields?: array<string>,          // GraphQL query field names (single + list)
  // DCB slices
  consumedEventTypes?: array<string>,   // event tags read from the shared DCB log
  producedCommandTypes?: array<string>, // commands dispatched by automation slices
  // DcbEventLog
  sharedBy?: array<string>,             // names of all slices sharing this event log
  // ExtensionPoint / Extension
  extensionPointName?: string,          // which EP this extension connects to
  providerPlugin?: string,              // which plugin provides the EP
  subscriberPlugins?: array<string>,    // which plugins subscribe (ExtensionPoint only)
}
```

**Where the data comes from:** `Plugin_Builder.construct` already has access to all component specs via the module types. The `mcpSchemaRegistrationHook` already extracts `mutationSchemaEntry` (with `commandSchema`), `querySchemaEntry` (with `stateSchema`), and `eventLogSchemaEntry` (with `eventSchema`). The same extraction logic can populate the `pluginDeployedSchema`.

Variant names are extracted from `S.t<command>` / `S.t<event>` schemas using Sury's tag introspection (e.g. `S.tagged(commandSchema)->Array.map(t => t.tag)`).

## Step 4 — Export admin component resources

**Files:** `Platform.res` (reventless-aws), `Platform_Admin.res`

Currently `deployPlatform` creates the admin Plugin aggregate and ReadModel but doesn't export their resources. Add exports for:
- Admin Plugin aggregate EventLog (DynamoDB table)
- Admin Plugin ReadModel QueryDb (DynamoDB table — the Plugin RM table)
- Admin scheduler resource (CloudWatch Events rule)
- Admin heartbeat Lambda

These can be included in the `platformDeployedInfo.adminResources` array from Step 2.

## Step 5 — Extension wiring metadata

**Files:** `Plugin_Builder.res`, `Plugin_Helpers.res`

When a plugin declares extensions (subscriptions to other plugins' extension points), include this wiring information in both `pluginBuiltInfo` and `pluginDeployedInfo`:

```rescript
type extensionWiring = {
  extensionName: string,          // e.g. "Catalog.Products.OrderingDemand"
  extensionPointName: string,     // e.g. "Catalog.Products"
  providerPlugin: string,         // e.g. "Catalog"
  providerVersion: string,        // e.g. "1.0.0"
  subscriberPlugin: string,       // e.g. "Ordering"
  subscriberVersion: string,      // e.g. "1.1.0"
}
```

Currently `Extension.resolvedOutputs` has `extensionPointName` but not the subscribing plugin's name (it's implicit from which plugin declares the extension). The builder knows both — include them in the hook data.

Similarly, for extension points: include which plugins have subscribed (available from the admin aggregate's heartbeat data, but ideally exported at deploy time too).

## Step 6 — Replace `Adapter.resource.info` with typed `resourceInfo`

**Files:** `Adapter.res` (reventless-infra), all `Util_*.res` builders (reventless-aws), all in-memory adapters, `Util_DynamoDb_Runtime.res`

Replace the catch-all `info: string` with a platform-agnostic variant:

```rescript
type resourceInfo =
  | StorageKeys({hashKey: string, rangeKey: option<string>})
  | StreamSource({sourceUrn: string})
  | ApiResolver({typeName: string, fieldName: string})
  | NoInfo
```

**Breaking change. Migration:**

| File | Current | After |
|------|---------|-------|
| `Util_DynamoDb.res` | `info: hashKey ++ "," ++ rangeKey` | `resourceInfo: StorageKeys({hashKey, rangeKey})` |
| `Util_DynamoDbStream.res` | `info: hashKey ++ "," ++ rangeKey ++ "," ++ streamArn` | `resourceInfo: StreamSource({sourceUrn: streamArn})` + separate `StorageKeys` |
| `Util_AppSync.res` | `info: typeName ++ "." ++ fieldName` | `resourceInfo: ApiResolver({typeName, fieldName})` |
| `Util_Lambda.res` | `info: ""` | `resourceInfo: NoInfo` |
| `Util_SQS*.res` | `info: ""` | `resourceInfo: NoInfo` |
| `Util_SNS*.res` | `info: ""` | `resourceInfo: NoInfo` |
| All other `Util_*.res` | `info: ""` | `resourceInfo: NoInfo` |
| In-memory adapters | `info: ""` | `resourceInfo: NoInfo` |

**Runtime readers to update:**
- `Util_DynamoDb_Runtime.res:121` — `resource.info->String.split(",")` → pattern match on `StorageKeys`
- `Util_DynamoDbStream.res:12` — `tableInfo->String.split(",")` → pattern match on `StreamSource`

**Interop:** `ReventlessInterop.Resource.t` needs a matching `resourceInfo` field (or the variant is serialized to a tagged JSON object).

## Step 7 — Add `role` field to `Adapter.resource`

**Files:** `Adapter.res` (reventless-infra), all component builders that construct resources

Add `role: Pulumi.Output.t<string>` to `Adapter.resource` and `role: string` to `Adapter.resolvedResource`.

The role identifies what function the resource serves within its component:

| Role | Used by | Example |
|------|---------|---------|
| `"eventLog"` | Aggregate, DcbEventLog | DynamoDB table storing events |
| `"commandTopic"` | Aggregate, ExtensionPoint, StateChangeSlice | SQS FIFO queue for commands |
| `"commandGenerator"` | Aggregate | Lambda + AppSync resolver for dispatching commands |
| `"eventTopic"` | Aggregate, DcbEventLog, ExtensionPoint | SNS topic for event distribution |
| `"queryDb"` | ReadModel, StateViewSlice, AutomationSlice | DynamoDB table for projected state |
| `"eventCollector"` | ReadModel, Aggregate, various slices | Lambda collecting events from streams |
| `"handler"` | StateChangeSlice, StateViewSlice, AutomationSlice | Lambda processing commands/events |
| `"deadLetterQueue"` | Various | SQS queue for failed messages |
| `"scheduler"` | Platform | CloudWatch Events rule |
| `"heartbeat"` | Plugin | Lambda for plugin heartbeat |

Each `Util_*.res` builder sets the role when constructing the resource record. The role is set by the component builder that calls the utility, not by the utility itself (the utility doesn't know the component context).

---

## Step 8 (nice-to-have) — Resource tags

**Files:** All `Util_*.res` builders, `PulumiAws.Lambda.Function.make`, `PulumiAws.DynamoDb.Table.make`, etc.

Add AWS resource tags to every taggable resource:

```
reventless:plugin = "Catalog"
reventless:component = "Category"
reventless:role = "eventLog"
reventless:kind = "Aggregate"
```

This enables AWS Resource Groups / Tag Editor queries without parsing Pulumi state. Useful for cost attribution (`@private-consumer/billing`) and compliance auditing.

**Implementation:** Pass tags through from `Plugin_Builder.construct` to each component builder to each `Util_*.res` function. Requires adding `tags?: dict<string>` to all Pulumi resource creation calls.

## Step 9 (nice-to-have) — Stack metadata export

**Files:** `Plugin_Helpers.res` (`exportPluginOutputs`), `Platform.res` (`deployPlatform`)

Export a `deploymentMetadata` output from every stack:

```rescript
let metadata = {
  "environment": Pulumi.getStack(),
  "region": Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region"),
  "timestamp": Date.make()->Date.toISOString,
  "gitSha": processEnv->Dict.get("GITHUB_SHA")->Option.getOr("unknown"),
  "actor": processEnv->Dict.get("GITHUB_ACTOR")->Option.getOr("unknown"),
}
Pulumi.export("deploymentMetadata", metadata->Pulumi.Output.make)
```

CI/CD systems set `GITHUB_SHA` / `GITHUB_ACTOR` (or equivalent). Manual deployments get `"unknown"` which external consumers can override with the user's identity.

---


## Step 13 (nice-to-have) — Prefix `service` field with provider namespace

**Files:** All `Util_*.res` builders (reventless-aws), in-memory adapters

The `service` field currently uses bare names (`"DynamoDb"`, `"Lambda"`, `"SQS_FIFO"`, `"SNS"`, `"S3"`, `"AppSync"`, `"IAM"`, `"CloudwatchEventRule"`, `"DynamoDbStream"`). Prefix them with `"aws:"` to make the provider explicit and enable multi-cloud support in the future:

| Current | After |
|---------|-------|
| `"DynamoDb"` | `"aws:DynamoDb"` |
| `"DynamoDbStream"` | `"aws:DynamoDbStream"` |
| `"Lambda"` | `"aws:Lambda"` |
| `"SQS"` | `"aws:SQS"` |
| `"SQS_FIFO"` | `"aws:SQS_FIFO"` |
| `"SNS"` | `"aws:SNS"` |
| `"SNS_FIFO"` | `"aws:SNS_FIFO"` |
| `"S3"` | `"aws:S3"` |
| `"AppSync"` | `"aws:AppSync"` |
| `"IAM"` | `"aws:IAM"` |
| `"CloudwatchEventRule"` | `"aws:CloudwatchEventRule"` |

In-memory adapters use `"memory:Bus"`, `"memory:Dict"`, etc. Future Azure adapters would use `"azure:CosmosDb"`, `"azure:ServiceBus"`, etc.

**Breaking change** — any code that pattern-matches or compares against the current bare service strings needs updating. The interop layer (`ReventlessInterop.Resource.t`) and any external consumers that parse `service` values are affected.

---

## Dependency Order

## Step 10 (nice-to-have) — Add `region` to `Adapter.resource`

**Files:** `Adapter.res` (reventless-infra), all `Util_*.res` builders (reventless-aws), in-memory adapters

Add `region: Pulumi.Output.t<string>` to `resource` and `region: string` to `resolvedResource`. On AWS, populated from the Pulumi AWS provider config (`aws:region`). On in-memory, set to `"local"`.

This enables correct AWS Console deep link generation without parsing ARNs, and supports multi-region deployment views in external consumers.

**Implementation:** Each `Util_*.res` builder receives the region from the platform's AWS provider config and passes it through. Alternatively, a module-level `currentRegion` ref is set once during platform init and read by all builders.

## Step 11 (nice-to-have) — Add `resourceType` to `Adapter.resource`

**Files:** `Adapter.res` (reventless-infra), all `Util_*.res` builders (reventless-aws)

Add `resourceType: Pulumi.Output.t<string>` to `resource` and `resourceType: string` to `resolvedResource`. Contains the specific cloud resource type (e.g. `"aws:dynamodb:Table"`, `"aws:lambda:Function"`, `"aws:sqs:Queue"`).

The existing `service` field is a coarse grouping (`"DynamoDb"`, `"Lambda"`). The `resourceType` is the full Pulumi provider type, enabling more precise filtering, icon rendering, and documentation links. Extractable from the Pulumi URN but storing it explicitly avoids URN parsing at runtime.

**Implementation:** Each `Util_*.res` builder sets the resource type as a constant string matching the Pulumi resource class name.

## Step 12 (nice-to-have) — Add `configuration` to `Adapter.resource`

**Files:** `Adapter.res` (reventless-infra), selected `Util_*.res` builders (reventless-aws)

Add `configuration: Pulumi.Output.t<dict<string>>` to `resource` and `configuration: dict<string>` to `resolvedResource`. Stores key infrastructure configuration properties as string key-value pairs.

Not all resources have meaningful config. Populate for the most useful ones:

| Resource type | Configuration keys |
|---------------|-------------------|
| DynamoDB Table | `billingMode` (PAY_PER_REQUEST / PROVISIONED), `tableClass` |
| Lambda Function | `runtime`, `memorySize`, `timeout`, `architecture` |
| SQS Queue | `visibilityTimeout`, `retentionPeriod`, `fifo` |
| SNS Topic | `fifo` |

This is a display-only concern — the configuration dict is informational, not used by the framework at runtime. External consumers show it alongside resource details ("this Lambda has 256MB memory and 30s timeout").

**Implementation:** Each `Util_*.res` builder extracts relevant config from the Pulumi resource args and stores it in the dict. Builders for resources without meaningful config set `configuration` to an empty dict.

Steps can be implemented incrementally:

1. **Steps 1 + 2** (hooks) — enable external consumers's automatic data feed. Highest priority.
2. **Step 3** (schema enrichment) — enables schema introspection for external tools. Can ship with Step 1.
3. **Steps 6 + 7** (resource improvements) — breaking change, coordinate with business repo. Can be done independently.
4. **Steps 4 + 5** (admin export, extension wiring) — enables complete deployment tree visibility.
5. **Steps 8 + 9** (tags, metadata) — nice-to-have, no dependencies.
6. **Steps 10 + 11 + 12 + 13** (region, resourceType, configuration, service prefix) — nice-to-have resource enrichment. Step 13 is a breaking change.

## Validation

After each step:
1. Build reventless-core (all packages)
2. Run core test suite
3. Build private-consumer-repo examples (platform, catalog-aws, ordering-aws)
4. Run business test suite (20/20 in-memory tests)
