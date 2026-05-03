# Plan: `Platform_UIDefinitions` Resolver for AWS

**Date:** 2026-05-03

---

## Goal

Mirror the in-memory platform's `Platform_UIDefinitions` GraphQL query in `reventless-aws` so AWS-deployed consoles can consume the same plugin metadata (read models, aggregates, command schemas, references, label fields, …) that drives Auto UI page/panel generation.

Today, the query exists only in [reventless-in-memory/src/Platform.res:1283-1376](../../reventless/reventless-in-memory/src/Platform.res#L1283-L1376). AWS deploys do not surface it, so any UI bundle that walks the registry of plugin definitions stalls on AWS until this lands. The gap was originally flagged in [entity-reference-dropdowns.md](./entity-reference-dropdowns.md):

> Only the in-memory platform currently emits `Platform_UIDefinitions`; reventless-aws has no corresponding resolver, so no AWS work is needed until that query is mirrored there.

This plan does the mirroring. It is framework work — the SDL, the read-model storage extension, and the AppSync resolver all live in `reventless-core` and `reventless-aws`. No example app or downstream package needs to change.

---

## Background

### Source-of-truth shape

The query response shape is fixed by [Plugin.res `pluginStructure`](../../reventless/reventless-spec/src/components/Plugin.res#L186-L196) and the SDL in the in-memory implementation at [Platform.res:1284-1295](../../reventless/reventless-in-memory/src/Platform.res#L1284-L1295). Eight nested types and one root list field:

```graphql
type Platform_UIFieldReference { fieldName: String!, entity: String!, plugin: String }
type Platform_UICommandDef { name: String!, schema: String!, level: String!, aggregateIdField: String, mutationField: String!, references: [Platform_UIFieldReference!]! }
type Platform_UIWriteSideDef { name: String!, commands: [Platform_UICommandDef!]!, linkedViews: [String!]!, consistencyRead: String, producedEventTypes: [String!]!, consumedEventTypes: [String!]! }
type Platform_UIReadSideDef { name: String!, queryField: String!, schema: String!, consumedEventTypes: [String!]!, linkedWriteSide: [String!]!, labelField: String!, searchableFields: [String!]! }
type Platform_UIAutomationSliceDef { ... }
type Platform_UIOutboundTranslationSliceDef { ... }
type Platform_UIInboundTranslationSliceDef { ... }
type Platform_UIExtensionDef { ... }
type Platform_UIDefinitionEntry { pluginId: String!, readModels: [...], stateViewSlices: [...], stateChangeSlices: [...], aggregates: [...], automationSlices: [...], outboundTranslationSlices: [...], inboundTranslationSlices: [...], extensions: [...] }

extend type Query {
  Platform_UIDefinitions: [Platform_UIDefinitionEntry!]!
}
```

This SDL must be byte-for-byte identical between in-memory and AWS so a single client query string works against both. The plan extracts it to a shared module so neither half drifts.

### Where the data lives in AWS today

Each plugin's full `pluginStructure` is computed at deploy time inside [Plugin_Builder.res:707](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res#L707) and stored as a Pulumi output on the Plugin component. The structure also rides on the `pluginDefinition` payload that the plugin sends with its `Connect` / `Reconnect` messages — see [Plugin.res:248](../../reventless/reventless-spec/src/components/Plugin.res#L248) (`structure: option<pluginStructure>`).

The Plugin read model in [PluginReadModelSpec.res](../../reventless/reventless-core/src/admin/PluginReadModelSpec.res) currently *drops* the `structure` field on projection — it stores `apiSchemaFragment`, `extensionPoints`, `extensions`, `uiFragments`, but not `structure`. That is the single missing wiring that prevents AWS from answering the query: the data arrives at the platform on every connect, but is not persisted.

### Why a Lambda DataSource (not a VTL template)

The response shape contains nested arrays of objects with deeply embedded JSON Schema strings (`schema: String!` on every queryable / writable). Building this in VTL is possible but unpleasant; a Lambda resolver is straightforward (single DynamoDB scan + a JSON-encode pass) and matches the pattern already used by other admin resolvers (`Platform_PlatformEventGraphs`, `platformCrossPluginEdges` in the in-memory adapter). Cold-start cost is acceptable — the query is invoked once per console boot.

---

## Phase 1 — Extract the shared SDL + encoder

### 1.1 New module `Platform_UIDefinitionsApi.res`

**Location.** `reventless/reventless-core/src/admin/Platform_UIDefinitionsApi.res`.

**Why a new module (not inline in `AdminApi.res`).** The SDL strings and the JSON encoder for `pluginStructure` are 90 lines today, all duplicated if both adapters inline them. Putting them in a single core module gives:
- One source of truth for the SDL strings.
- A reusable `encodePluginStructureEntry: (~pluginId, pluginStructure) => JSON.t` function that both adapters call.
- Test surface: encoder shape can be asserted independently of either runtime.

**Module contents:**

```rescript
// reventless-core/src/admin/Platform_UIDefinitionsApi.res

// SDL types — must remain byte-identical between in-memory and AWS.
let sdlTypes: array<string> = [
  `type Platform_UIFieldReference { ... }`,
  // ... eight more types, lifted verbatim from the current in-memory inline strings
]

// SDL field — single root query.
let sdlQueryField: string = `  Platform_UIDefinitions: [Platform_UIDefinitionEntry!]!`

// Encoder — moved verbatim from in-memory Platform.res:1296-1362.
let encodePluginStructureEntry = (
  ~pluginId: string,
  def: Reventless.Plugin.pluginStructure,
): JSON.t => { ... }
```

### 1.2 Refactor in-memory to consume the shared module

Update [reventless-in-memory/src/Platform.res:1283-1376](../../reventless/reventless-in-memory/src/Platform.res#L1283-L1376) to import `Platform_UIDefinitionsApi` and replace the inline SDL strings + encoder with calls to the shared module. The resolver body stays in-memory (still reads from `pluginStructuresStore.contents`). No behavioural change.

### 1.3 Validation

- Existing in-memory tests pass unchanged (`Platform_UIDefinitions` still returns the same shape).
- A new unit test in `reventless-core/tests/admin/Platform_UIDefinitionsApiTest.res` asserts that `encodePluginStructureEntry` produces the expected JSON shape from a fixture `pluginStructure`.
- Schema inspector test confirms the SDL strings parse cleanly.

---

## Phase 2 — Persist `pluginStructure` in the Plugin read model

### 2.1 Extend `PluginReadModelSpec.state`

Add `structure: option<Reventless.Plugin.pluginStructure>` to both `state` and `queryResult` in [PluginReadModelSpec.res](../../reventless/reventless-core/src/admin/PluginReadModelSpec.res). Use the same `@s.matches(pluginStructureOptionSchema)` annotation pattern already used for `apiSchemaFragment` so sury's union-variant validation accepts the JS-nullable encoding.

### 2.2 Project `structure` from `pluginDefinition`

Update [PluginProjection.res](../../reventless/reventless-core/src/admin/PluginProjection.res) `Connected` / `Reconnected` arms — and the `applyFragAndTarget` helper at line 41 — to copy `pluginDef.structure` onto the projected state alongside `apiSchemaFragment`. Add it to the disconnect-preserving branches too (state shouldn't lose its structure when a plugin disconnects; the data is still useful for the console to show "what was here before").

### 2.3 Validation

- Existing `PluginProjectionTest` cases pass; add one case asserting `structure` round-trips through `Connected` and survives `Disconnected`.
- A SchemaInspector test asserts the new field is part of the projected state JSON Schema (so DynamoDB serialization is unblocked downstream).

---

## Phase 3 — AWS resolver: schema + Lambda DataSource

### 3.1 Extend `AdminApi.baseFragment`

[AdminApi.res:39-48](../../reventless/reventless-core/src/admin/AdminApi.res#L39-L48) builds the admin schema fragment that both in-memory (unified) and AWS (split mode) stitch as the platform-side base. Extend it to include the `Platform_UIDefinitions` SDL types and query field from `Platform_UIDefinitionsApi`:

```rescript
let baseFragment = (~cloner: bool) => {
  let base = GraphQL_FragmentGenerator.generate(...)
  let parts = GraphQL_Stitcher.decode(base)
  GraphQL_Stitcher.encode({
    ...parts,
    types: parts.types
      ->Array.concat(uiFragmentSubscriptionTypes)
      ->Array.concat(Platform_UIDefinitionsApi.sdlTypes),
    queries: Array.concat(parts.queries, [Platform_UIDefinitionsApi.sdlQueryField]),
    mutations: ...,
    subscriptions: ...,
  })
}
```

This single edit gives **both** adapters the SDL field. The in-memory adapter still resolves via `pluginStructuresStore`; AWS resolves via the new Lambda below.

### 3.2 New AWS resolver — Lambda DataSource

**Location.** `reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res`.

**Pattern.** Same shape as other admin Lambda resolvers in `adapter/Api/`. The Lambda:

1. Uses the existing `QueryEngine.DynamoDb` operations (already wired in [Platform.res:879](../../reventless/reventless-aws/src/Platform.res#L879)) to scan the Plugin read model for `status = Connected`.
2. For each row, decodes `state.structure` (now persisted via Phase 2). Skips rows where `structure = None` (older plugin protocol versions).
3. Maps over the rows calling `Platform_UIDefinitionsApi.encodePluginStructureEntry(~pluginId=state.id, structure)` (Phase 1).
4. Returns the JSON array.

**Code outline:**

```rescript
let handler = async (_event, _ctx): JSON.t => {
  open Reventless.QueryEngine.Filter
  let queryEngine = QueryEngine.DynamoDb.makeOperations(~tableName=Config.pluginReadModelTableName)
  let plugins = await queryEngine.scan(
    ~readModelName="Plugin",
    ~filterConfigs=[("status", Contains, String("Connected"))],
    ~limit=1000,
  )
  plugins
  ->Array.filterMap(json =>
    try {
      let state = json->S.parseOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
      state.structure->Option.map(s =>
        ReventlessCore.Platform_UIDefinitionsApi.encodePluginStructureEntry(
          ~pluginId=state.name,
          s,
        )
      )
    } catch {
    | _ => None
    }
  )
  ->JSON.Encode.array
}
```

### 3.3 Wire the resolver into the platform stack

In [Platform.res:1162-1176](../../reventless/reventless-aws/src/Platform.res#L1162-L1176) (`Admin.construct` block), after the admin construction:

1. Create the Lambda function for the resolver via the existing `Util_Bundle.res` packaging (mirror how `Plugin_ExtensionPoint_Builder` builds its handler — same `AssetArchive` pattern, `nodejs20.x` runtime).
2. Create an AppSync DataSource pointing at the Lambda (use the existing helpers in `AppSync_Adapter.res`).
3. Create a `Pulumi.Aws.AppSync.Resolver` for `Query.Platform_UIDefinitions` bound to the new DataSource.
4. The resolver Lambda needs `dynamodb:Scan` on the Plugin read model table — extend the IAM policy attached to the Lambda's execution role.

The resolver attaches to `platformApi` (the admin API) in split mode and to `domainApi` in unified mode, matching the existing `splitApi` branching at [Platform.res:1218-1276](../../reventless/reventless-aws/src/Platform.res#L1218-L1276).

### 3.4 AWS resources created (and why)

A single new Lambda is provisioned per platform deploy: **`PlatformUIDefinitionsLambda`**.

**What the Lambda does** ([Platform_UIDefinitions_Lambda.res:11](../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L11))

- Reads the Plugin read model table name from the `PLUGIN_RM_TABLE` env var.
- Runs a paginated DynamoDB `Scan` with `FilterExpression: contains(#status, :connected)`.
- For each row, returns `{ pluginId: item.name, ...item.structure }`, skipping rows where `structure` is absent (older plugin protocol versions).
- Returns the array as the GraphQL response.

**Why one Lambda — and why a Lambda at all**

- The response type is `[Platform_UIDefinitionEntry!]!` — nested arrays of objects with embedded JSON Schema strings on every queryable / writable. An AppSync DynamoDB-backed resolver would have to reconstruct that shape in VTL or APPSYNC_JS; a Lambda just passes the persisted JSON through.
- The persisted `state.structure` is already in the canonical shape (sury-encoded with the same wire format the in-memory encoder produces — `commandLevel` as literal strings, `option` as `null`), so the handler simply wraps each row with `pluginId`. **No bundling of `reventless-core` into the Lambda is required.**
- The Plugin read model is admin-internal (one per platform). Both deploy paths (`makePlatform` and `deployPlatform`) reuse the same module to attach the resolver — same Lambda type, one instance per stack.
- Cold-start cost is acceptable: this query is invoked at console boot only.

**Surrounding non-Lambda resources created alongside it** (for completeness)

- Lambda execution `Role` + `RolePolicy` granting `logs:*` and `dynamodb:Scan` scoped to `arn:aws:dynamodb:*:*:table/<PluginRM>`.
- AppSync DataSource `Role` + `RolePolicy` granting `lambda:InvokeFunction` on the new Lambda's ARN.
- AppSync `DataSource` (type `AWS_LAMBDA`) and a `Resolver` bound to `Query.Platform_UIDefinitions`.

Wired at [Platform.res:1006](../../reventless/reventless-aws/src/Platform.res#L1006) (`makePlatform`) and [Platform.res:1224](../../reventless/reventless-aws/src/Platform.res#L1224) (`deployPlatform`), attached to `platformApi` (which equals `domainApi` in unified mode).

### 3.5 Validation

- A new integration test in `reventless-aws/tests` deploys a minimal stack, connects two plugins (each with a non-trivial `pluginStructure`), and POSTs `{ Platform_UIDefinitions { pluginId readModels { name labelField } aggregates { name commands { name } } } }` against the platform endpoint. Asserts both pluginIds appear and the nested fields match the structures the plugins were built with.
- A schema-equivalence test parses the in-memory and AWS-deployed `Platform_UIDefinitions` SDL substrings and asserts they are identical (guards against future drift between adapters).
- Manual: bring up a fresh AWS deploy with one plugin connected; query `Platform_UIDefinitions` via the AppSync console and verify the response is non-empty.

---

## Phase 4 — Cross-version safety

The `structure` field on `pluginDefinition` is `option` (added in a later PPX revision). Older plugins that connect with the previous protocol version will send `structure = None`. The plan handles this gracefully:

- Phase 2's projection stores `None` when the plugin doesn't supply one.
- Phase 3.2's resolver skips entries where `structure = None` rather than emitting partial data.

The console-side behaviour for missing entries is "plugin appears in the platform health view but has no inspector pages", which is the correct degraded state for an outdated plugin.

No SDL-level breaking change: the resolver returns an empty array when no plugins have `structure`, which is the same shape clients already expect from in-memory.

---

## Out of scope

- **Performance optimisation.** A 1000-row `scan` on every query is fine for the platform's expected plugin counts (single-digit to low-double-digit). If scale becomes an issue, the right next move is caching the encoded JSON in a SSM parameter that's invalidated on plugin connect/disconnect events — separate plan.
- **Subscription support.** The `onUIFragmentChange` subscription already covers fragment-level changes. A `Platform_UIDefinitions`-shaped subscription would be redundant — clients re-fetch on the existing fragment events.
- **Authorization.** The query inherits the admin API's existing `@aws_auth(cognito_groups: ["Admin"])` injection from `injectAwsAuthAll` at [Platform.res:1222](../../reventless/reventless-aws/src/Platform.res#L1222). No additional auth wiring needed.

---

## Validation — full plan

- All three adapter test suites (`reventless-core`, `reventless-in-memory`, `reventless-aws`) pass.
- `Platform_UIDefinitions` query returns identical shape on in-memory and AWS deployments running the same plugins.
- `pluginStructure` round-trips through Plugin Connect → projection → DynamoDB → resolver → JSON without data loss.

## Commit message

`feat(aws): mirror Platform_UIDefinitions GraphQL query — Lambda DataSource backed by Plugin read model`
