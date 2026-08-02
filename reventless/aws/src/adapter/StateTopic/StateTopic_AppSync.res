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

open PulumiAws

// ── Registry ──────────────────────────────────────────────────────────────────

type streamEntry = {
  tableName: Pulumi.Output.t<string>,
  streamArn: Pulumi.Output.t<string>,
  topicName: string,
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

let make = (
  ~readModelName: string,
  ~topicName: string,
  ~allQueryDbs: ReventlessCore.QueryDb.allOutputs,
  ~eventsApi: AppSync_EventsApi.t,
  ~opts as _: Pulumi.CustomResourceOptions.t,
) => {
  // Look up the QueryDb resources by ReadModel Spec.name, then find the
  // DynamoDB stream resource within them. Requires QueryDbStorage_DynamoDbStream.
  let streamResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(readModelName)
    ->Util_DynamoDbStream.findResource

  let streamArn = Util_DynamoDbStream.streamArnFromDynamoDbTableResource(streamResource)
  let tableName = streamResource.name

  let key = eventsApi.name
  let entries = registry->Dict.get(key)->Option.getOr([])
  registry->Dict.set(key, entries->Array.concat([{tableName, streamArn, topicName}]))
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
    )

    let layers =
      Lambda.reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make

    let appsyncEndpoint = AppSync_EventsApi.httpEndpoint(eventsApi)

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
              ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
              ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
              Util_LambdaLogging.logLevelEntry(),
            ]),
          }: Lambda.Function.functionEnvironment
        )->Pulumi.Input.make,
      },
      ~opts,
    )

    Util_LambdaLogging.makeManagedLogGroup(
      ~name=name ++ "StateTopicPublisher",
      ~lambdaName=lambda.name,
      ~tags=AWS.Tags.make(
        ~name=name ++ "StateTopicPublisherLogGroup",
        ~kind=ReventlessCore.QueryDb.componentType,
        ~role=Logs,
        ~component=name,
      ),
      ~opts,
      (),
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
