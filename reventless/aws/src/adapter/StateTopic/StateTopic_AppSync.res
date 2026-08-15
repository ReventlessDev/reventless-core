// StateTopic_AppSync.res
// Source B: state-change subscriptions (QueryDb DynamoDB Stream → AppSync Events API).
//
// One shared Lambda per events API handles every stream-enabled QueryDb in the
// platform (admin RMs, user-plugin `ReadModelStream`s, and `StateViewSliceStream`s
// alike). `make` registers an entry in a per-events-API registry; `finish` is
// called once at the end of platform construction and builds the shared
// Lambda + IAM role/policy + per-stream EventSourceMappings from the
// accumulated registry entries.
//
// Channel layout: /default/{topicName}/{pathSegment(entityKey)}
//   topicName    = plugin-prefixed query LIST field name (e.g. "Catalog-Products").
//                  MUST match the AutoUI manifest's queryableDef.queryField,
//                  which the host-shell's AutoLive subscribes on. Using the
//                  singular return type here would orphan the channel.
//   entityKey    = the table's primary-key value(s) extracted from record.Keys.
//                  Single-key tables: just the `id` attribute value.
//                  Composite-key tables: `{id}-{subIdValue}` where subId is the
//                  table's sort-key attribute.
//   pathSegment  = AppSync Events channel segments allow only [A-Za-z0-9-];
//                  every other char (`@`, `.`, `:`, `_`, `/`, …) collapses to
//                  `-`. The DESCRIPTOR BODY carries the ORIGINAL entityKey so
//                  the UI's inPage / selectedRowId comparisons against the
//                  GraphQL row.id still match — only the URL path is sanitised.
//
// Clients subscribe to one of:
//   {topic}/{entityKey}   detail view (one row)
//   {topic}/*             list view  (all rows in the read model)
//
// Prerequisites:
//   - The QueryDb must use QueryDbStorage_DynamoDbStream so its resource has a
//     streamArn (StreamSource resourceInfo).
//
// Usage in the plugin / admin builder (after allQueryDbs are assembled):
//   StateTopic_AppSync.make(
//     ~readModelName="Products",     // QueryDb key = ReadModel Spec.name
//     ~topicName="Catalog_Products", // AppSync Events channel root = list field name
//     ~allQueryDbs,
//     ~eventsApi,
//     ~opts,
//   )
//
// Usage in Platform.res (once, after admin + plugins have wired):
//   StateTopic_AppSync.finish(~eventsApi, ~opts)
//
// ── Tables that are not read models ──────────────────────────────────────────
//
// Nothing below the registration is read-model-specific: the relay routes per
// record through STATE_TOPIC_MAP and derives the entity channel from the record's
// own `Keys`. `makeForTable` is the front door for a component that provisions
// its own DynamoDB table and wants the same descriptors — state that is a PRIMARY
// record rather than a projection (a ledger accumulated by `ADD` increments,
// say) is not a read model and must not be declared one, but its rows are exactly
// the shape the relay expects.
//
//   StateTopic_AppSync.makeForTable(
//     ~tableName=myTable.name,
//     ~streamArn=myTable.streamArn,
//     ~partitionKeyName=myTable.hashKey,
//     ~topicName="Platform-UsageLedger",
//     ~eventsApi,
//     ~opts,
//   )
//
// Three things a caller has to get right, none of which the type checker can:
//
//   1. TOPIC NAMING IS THE CALLER'S JOB, AND A MISMATCH IS SILENT. A read model
//      derives its topic from the generated plural list field, so publisher and
//      subscriber agree by construction. A self-provisioned table has no such
//      field — the topic passed here is simply believed. Publishing to a channel
//      nobody listens on succeeds, so a typo shows up as "live updates never
//      arrive", not as an error. The topic belongs to whoever READS the data:
//      change the reader and the registration together, in one commit.
//
//   2. THE TABLE MUST BE KEYED ON `id`. Checked at deploy time — see
//      `StateTopic_AppSync_Helpers.checkPartitionKeyName` for why a build error
//      beats the alternative. A sort key is fine (entity key becomes
//      `{id}-{sortValue}`, which the reader must also know).
//
//   3. REGISTRATION IS OPT-IN, PER TABLE, AND NOT FREE UNDER LOAD. Never register
//      a table just because it happens to have a stream. A stream is silent while
//      the table is idle — which is why this beats polling for the common quiet
//      case — but a write burst costs one relay invocation per record batch, and
//      avoiding exactly that per-write work is often why such a table exists in
//      the first place. Measure before enabling it on a write-hot table.

open PulumiAws

// ── Registry ──────────────────────────────────────────────────────────────────

type streamEntry = {
  tableName: Pulumi.Output.t<string>,
  streamArn: Pulumi.Output.t<string>,
  topicName: string,
  // The read model's `@retired` field, resolved at deploy time because the relay
  // Lambda has no plugin registry in process to resolve it at request time.
  retiredField: option<string>,
  retiredValue: option<string>,
}

// One registry per events API, keyed by `eventsApi.name` (the static Pulumi
// resource name, e.g. "DomainEventsApi"). `make` appends; `finish` drains.
let registry: dict<array<streamEntry>> = Dict.make()

// ── Handler code ─────────────────────────────────────────────────────────────
//
// Processes DynamoDB Stream records → publishes one event per row-change to
// AppSync Events. Channel path: /default/{topicRoot}/{entityKey}.
//
// Topic routing is per-record: `STATE_TOPIC_MAP` is `{ "<ddbTableName>":
// "<topicName>" }`; the handler extracts the table name from
// `record.eventSourceARN` (`…:table/<TableName>/stream/…`) and looks up the
// matching topic. This is what lets a single shared Lambda fan out to every
// stream-enabled RM in the platform.
//
// AppSync Events channel segments allow only [A-Za-z0-9-]. `topicRoot` and the
// channel-path entityKey both run through `pathSegment` (collapses every other
// char to `-`); the descriptor body's `id` keeps the ORIGINAL value so the UI
// can match it against GraphQL row ids.
//
// Payload is a change descriptor (NOT the full row):
//   { changeKind: "Added" | "Updated" | "Removed",
//     id:         <entityKey>,
//     sortKeyValue?: <updatedAt | createdAt if present in the image> }
//
// Uses native Node.js crypto + fetch with SigV4 — no extra SDK packages needed.
// Credentials come from the Lambda execution role via the process.env AWS_* variables.


// ── Registration ──────────────────────────────────────────────────────────────

/** Register any stream-enabled DynamoDB table with the relay. Read-model and
    self-provisioned tables land in the SAME registry, so they share one `finish`,
    one Lambda, one IAM statement and one STATE_TOPIC_MAP — see the module header
    for the three things a self-provisioned caller has to get right. */
let makeForTable = (
  ~tableName: Pulumi.Output.t<string>,
  ~streamArn: Pulumi.Output.t<string>,
  ~partitionKeyName: Pulumi.Output.t<string>,
  ~topicName: string,
  ~retiredField: option<string>=?,
  ~retiredValue: option<string>=?,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts as _: Pulumi.CustomResourceOptions.t,
) => {
  // The check rides ON the tableName that gets registered rather than sitting in
  // an apply of its own, so it cannot rot into dead code: STATE_TOPIC_MAP is built
  // from this Output, so the apply always runs and a violation fails the deploy.
  let checkedTableName =
    (tableName, partitionKeyName)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((tableName, partitionKeyName)) => {
      StateTopic_AppSync_Helpers.checkPartitionKeyName(~tableName, ~partitionKeyName)
      tableName
    })

  let key = eventsApi.name
  let entries = registry->Dict.get(key)->Option.getOr([])
  registry->Dict.set(
    key,
    entries->Array.concat([
      {tableName: checkedTableName, streamArn, topicName, retiredField, retiredValue},
    ]),
  )
}

let make = (
  ~readModelName: string,
  ~topicName: string,
  ~allQueryDbs: ReventlessCore.QueryDb.allOutputs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  // Look up the QueryDb resources by ReadModel Spec.name, then find the
  // DynamoDB stream resource within them. Requires QueryDbStorage_DynamoDbStream.
  let streamResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(readModelName)
    ->Util_DynamoDbStream.findResource

  makeForTable(
    ~tableName=streamResource.name,
    ~streamArn=Util_DynamoDbStream.streamArnFromDynamoDbTableResource(streamResource),
    // QueryDbStorage_DynamoDb* keys every table it provisions on `id`, so here the
    // check restates an invariant the framework already holds. It exists for the
    // tables the framework did NOT create, which reach the registry via
    // `makeForTable` and can be keyed anything.
    ~partitionKeyName=StateTopic_AppSync_Helpers.entityKeyPartitionAttribute->Pulumi.Output.make,
    ~topicName,
    // Resolved here, where the read model's name is known and its spec is
    // registered in this process. The relay Lambda has neither.
    ~retiredField=?ReventlessCore.Plugin_Helpers.stateSchemaRegistry
    ->Dict.get(readModelName)
    ->Option.flatMap(Reventless.StateAnnotations.getSpec)
    ->Option.flatMap(spec => spec.retired)
    ->Option.map(r => r.field),
    ~retiredValue=?ReventlessCore.Plugin_Helpers.stateSchemaRegistry
    ->Dict.get(readModelName)
    ->Option.flatMap(Reventless.StateAnnotations.getSpec)
    ->Option.flatMap(spec => spec.retired)
    ->Option.flatMap(r => r.value),
    ~eventsApi,
    ~opts,
  )
}

// ── Finalize: build the shared Lambda + IAM + ESMs ────────────────────────────

let finish = (
  ~eventsApi: AppSync_EventsApi.t,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  let key = eventsApi.name
  switch registry->Dict.get(key) {
  | None => ()
  | Some([]) => ()
  | Some(entries) =>
    let name = eventsApi.name

    // IAM role for the shared Lambda (Lambda service principal).
    let lambdaRole = IAM.Role.makeWithDefaultPolicy(
      ~name=name ++ "StateTopicRole",
      ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
      ~tags=AWS.Tags.make(
        ~name=name ++ "StateTopicRole",
        ~kind=ReventlessCore.QueryDb.componentType,
        ~role=Identity,
        ~component=name,
      ),
      ~opts,
    )

    // IAM policy: read from every stream + publish to the events API.
    let streamArnsOutput =
      entries->Array.map(e => e.streamArn)->Pulumi.Output.all
    let _ =
      (streamArnsOutput, eventsApi.api.apiArn)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((streamArns, apiArn)) => {
        open PolicyDocument
        let _rolePolicy = IAM.RolePolicy.make(
          ~name=name ++ "StateTopicPolicy",
          ~args={
            IAM.RolePolicy.policy: PolicyDocument.make(
              ~id=name ++ "StateTopicPolicy",
              ~statements=[
                {
                  sid: "AllowLambdaLogging",
                  effect: Allow,
                  actions: Action("logs:*"),
                  resources: Resource("arn:aws:logs:*:*:*"),
                },
                {
                  sid: "AllowReadDynamoDbStream",
                  effect: Allow,
                  actions: Actions([
                    "dynamodb:DescribeStream",
                    "dynamodb:GetRecords",
                    "dynamodb:GetShardIterator",
                    "dynamodb:ListStreams",
                  ]),
                  resources: Resources(streamArns),
                },
                {
                  sid: "AllowPublishAppSyncEvents",
                  effect: Allow,
                  actions: Action("appsync:EventPublish"),
                  resources: Resource(apiArn ++ "/*"),
                },
              ],
            )
            ->PolicyDocument.toJsonString
            ->Pulumi.Input.make,
            role: lambdaRole.id->Pulumi.Output.asInput,
          },
          ~opts,
        )
      })

    // STATE_TOPIC_MAP env var — `{ <tableName>: <topicName> }` JSON object.
    // `topicName` is already a resolved string at deploy time; `tableName`
    // is an Output, so we await all of them and build the JSON inside apply.
    let topicMapJson =
      entries
      ->Array.map(e => e.tableName)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(tableNames => {
        let dict = Dict.make()
        tableNames->Array.forEachWithIndex((tableName, i) => {
          let topicName = (entries->Array.getUnsafe(i)).topicName
          dict->Dict.set(tableName, topicName->JSON.Encode.string)
        })
        dict->JSON.Encode.object->JSON.stringify
      })

    // STATE_RETIRED_MAP env var — `{ <tableName>: {field, value?} }`, carrying
    // only the tables that declare retirement. Built from the same awaited table
    // names as the topic map so the two cannot describe different sets of tables.
    // The whole predicate travels: the relay Lambda has no plugin registry, so a
    // field without its value would leave it unable to tell the two forms apart.
    let retiredMapJson =
      entries
      ->Array.map(e => e.tableName)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(tableNames => {
        let dict = Dict.make()
        tableNames->Array.forEachWithIndex((tableName, i) => {
          let entry = entries->Array.getUnsafe(i)
          entry.retiredField->Option.forEach(f => {
            let obj = Dict.fromArray([("field", f->JSON.Encode.string)])
            entry.retiredValue->Option.forEach(v => obj->Dict.set("value", v->JSON.Encode.string))
            dict->Dict.set(tableName, obj->JSON.Encode.object)
          })
        })
        dict->JSON.Encode.object->JSON.stringify
      })

    // Shared Lambda — the compiled `_Ops` handler is identical for every
    // stream-enabled RM; routing is per-record via STATE_TOPIC_MAP env var.
    // Bundle reventless-aws (the handler + its node:crypto signer + the
    // util-dynamodb unmarshaller live inside it) and re-export its `handler`;
    // buildCodeArchive ships the ESM resolve-hook so `@rescript/runtime` and the
    // handler's bare @aws-sdk/util-dynamodb resolve from layer / managed runtime.
    let packageDirs = Dict.fromArray([
      ("@reventlessdev/reventless-aws", Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
    ])
    let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
      ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync_Ops.res.mjs",
      ~packageDirs,
      ~bundleRuntimeExtensions=false,
    )

    let layers =
      Lambda.reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make

    let appsyncEndpoint = AppSync_EventsApi.httpEndpoint(eventsApi)

    // Created before the function that writes to it — see
    // `Util_LambdaLogging.makeManagedLogGroup` for why the ordering matters.
    let logGroup = Util_LambdaLogging.makeManagedLogGroup(
      ~name=name ++ "StateTopicPublisher",
      ~tags=AWS.Tags.make(
        ~name=name ++ "StateTopicPublisherLogGroup",
        ~kind=ReventlessCore.QueryDb.componentType,
        ~role=Logs,
        ~component=name,
      ),
      ~opts,
      (),
    )

    let lambda = Lambda.Function.make(
      ~name=name ++ "StateTopicPublisher",
      ~args={
        handler: "index.handler"->Pulumi.Input.make,
        runtime: "nodejs22.x"->Pulumi.Input.make,
        code: code->Pulumi.Input.make,
        sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
        role: lambdaRole.arn->Pulumi.Output.asInput,
        memorySize: 256->Pulumi.Input.make,
        timeout: 30->Pulumi.Input.make,
        layers,
        tags: AWS.Tags.make(~name=name ++ "StateTopic", ~kind=ReventlessCore.QueryDb.componentType, ~role=StateTopic, ~component=name),
        environment: (
          {
            Lambda.Function.variables: Dict.fromArray([
              ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
              ("APPSYNC_ENDPOINT", appsyncEndpoint->Pulumi.Output.asInput),
              ("STATE_TOPIC_MAP", topicMapJson->Pulumi.Output.asInput),
              ("STATE_RETIRED_MAP", retiredMapJson->Pulumi.Output.asInput),
              ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
              ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
              Util_LambdaLogging.logLevelEntry(),
            ]),
          }: Lambda.Function.functionEnvironment
        )->Pulumi.Input.make,
        loggingConfig: ?Util_LambdaLogging.loggingConfigFor(logGroup),
      },
      ~opts,
    )

    // One EventSourceMapping per stream, all targeting the shared Lambda.
    // Retry posture: the handler throws on 5xx / network errors and logs-and-
    // continues on 4xx. `maximumRetryAttempts: 3` bounds the per-record
    // retries so a permanently broken record (default DDB stream behaviour is
    // -1 → forever, which would wedge the shard); `bisectBatchOnFunctionError`
    // isolates the bad record across those retries instead of redelivering
    // the whole batch each time.
    entries->Array.forEach(entry => {
      let esmName = entry.topicName ++ "Stream2" ++ name ++ "StateTopic"
      let _esm = EventSourceMapping.make(
        ~name=esmName,
        ~args={
          EventSourceMapping.functionName: lambda.arn->Pulumi.Output.asInput,
          eventSourceArn: entry.streamArn->Pulumi.Output.asInput,
          startingPosition: LATEST,
          maximumRetryAttempts: 3,
          bisectBatchOnFunctionError: true,
          tags: AWS.Tags.make(
            ~name=esmName,
            ~kind=ReventlessCore.QueryDb.componentType,
            ~role=EventSourceMapping,
            ~component=name,
          ),
        },
        ~opts=Some(opts),
      )
    })

    // Clear the registry so a second platform construction in the same process
    // (tests, dev hot reload) starts fresh.
    registry->Dict.set(key, [])
  }
}
